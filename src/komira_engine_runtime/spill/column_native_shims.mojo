# =============================================================================
# column_native_shims.mojo — P-2.A column-native foundation: boundary shims
# between Column-world (RecordBatch) and ColumnNativeBatch.
# =============================================================================
#
# These are the source / sink / spill boundary bridges used during the C.1/C.2
# cutover. P-2 CONSUMES THSPLC; it does NOT rebuild the column codec. The
# round-trip is therefore:
#
#   column_native_from_record_batch:  RecordBatch -> THSPLCEncoder.encode
#       -> THSPLC body bytes -> parse descriptors -> ColumnNativeBatch
#   record_batch_from_column_native:  ColumnNativeBatch._body (+ _schema)
#       -> THSPLCDecoder.decode_copy -> RecordBatch
#
# Because the ColumnNativeBatch body IS a THSPLC chunk, the round-trip is
# byte-identical to a spill/restore cycle through THSPLC. No codec duplication.
#
# Why this lives here: the shim imports the THSPLC codec, which is in this
# package; the ColumnNativeBatch types it bridges are in `komira_arrow`, which
# cannot depend on the engine runtime. Callers import
# `from komira_engine_runtime.spill.column_native_shims import ...`.
#
# THSPLC integration: P-2.A bridges via these shims. A direct
# `THSPLCEncoder.encode_column_native` overload is a P-2.C option (measure the
# shim cost first); the foundation keeps the
# RecordBatch shim so zero codec work happens in P-2.A.
# =============================================================================

from std.collections import Optional

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.column_native import (
    ColumnDescriptor,
    ColumnNativeBatch,
    ColumnNativeBatchHeader,
)
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_collections.slab import Slab
from komira_buffer.heap_region import HeapRegion

from komira_engine_runtime.spill.thsplc import THSPLCEncoder, THSPLCDecoder


# THSPLC on-wire layout constants (mirror thsplc.mojo; the body IS a THSPLC
# chunk). The descriptor section starts at byte 96; each descriptor is 48 B.
comptime _THSPLC_HEADER_SIZE: Int = 96
comptime _THSPLC_DESCRIPTOR_SIZE: Int = 48

# THSPLC header field offset used to recover the foundation header.
comptime _HDR_FP_OFF: Int = 24  # UInt64 schema_fingerprint

# THSPLC _ColumnDescriptor on-wire field offsets (relative to the descriptor's
# own 48 B start; see thsplc.mojo _ColumnDescriptor docstring).
comptime _D_ARROW_TYPE_OFF: Int = 0  # UInt32 arrow_type_id
comptime _D_FLAGS_OFF: Int = 4  # UInt32 flags
comptime _D_NULL_COUNT_OFF: Int = 16  # UInt64 null_count
comptime _D_REGION_OFF: Int = 24  # UInt64 region_offset (absolute)
comptime _D_VALIDITY_LEN_OFF: Int = 32  # UInt32 validity_len
comptime _D_OFFSETS_LEN_OFF: Int = 36  # UInt32 offsets_len
comptime _D_VALUES_LEN_OFF: Int = 40  # UInt64 values_len

# THSPLC descriptor flag bits.
comptime _D_FLAG_HAS_VALIDITY: UInt32 = 1
comptime _D_FLAG_HAS_OFFSETS: UInt32 = 2


def _parse_descriptors_from_thsplc(
    body: SharedAlignedBuffer[HeapRegion], n_cols: Int
) -> Slab[ColumnDescriptor]:
    """Recover the foundation `ColumnDescriptor` slab from a THSPLC body's
    descriptor section. Each THSPLC region is `[validity][offsets][values]`
    starting at `region_offset`; the foundation descriptor records the absolute
    body byte offsets of each sub-region (validity_off / offsets_off / data_off)
    so `column_unified` / nested accessors address cells without re-deriving
    sizes."""
    var view = body.as_view()
    var out = Slab[ColumnDescriptor].create(max(n_cols, 1))
    for i in range(n_cols):
        var base = _THSPLC_HEADER_SIZE + i * _THSPLC_DESCRIPTOR_SIZE
        var arrow_type = view.read_u32_le_at(base + _D_ARROW_TYPE_OFF)
        var flags = view.read_u32_le_at(base + _D_FLAGS_OFF)
        var null_count = view.read_u64_le_at(base + _D_NULL_COUNT_OFF)
        var region_off = Int(view.read_u64_le_at(base + _D_REGION_OFF))
        var validity_len = Int(view.read_u32_le_at(base + _D_VALIDITY_LEN_OFF))
        var offsets_len = Int(view.read_u32_le_at(base + _D_OFFSETS_LEN_OFF))
        var values_len = Int(view.read_u64_le_at(base + _D_VALUES_LEN_OFF))

        # Region layout: [validity (validity_len)] [offsets (offsets_len)]
        # [values (values_len)] in that order.
        var validity_off: UInt32 = 0
        var offsets_off: UInt32 = 0
        var cursor = region_off
        if (flags & _D_FLAG_HAS_VALIDITY) != 0:
            validity_off = UInt32(cursor)
            cursor += validity_len
        if (flags & _D_FLAG_HAS_OFFSETS) != 0:
            offsets_off = UInt32(cursor)
            cursor += offsets_len
        var data_off = UInt32(cursor)

        out.append(
            ColumnDescriptor(
                arrow_type=UInt16(Int(arrow_type)),
                data_off=data_off,
                data_len=UInt32(values_len),
                offsets_off=offsets_off,
                validity_off=validity_off,
                null_count=UInt32(Int(null_count)),
            )
        )
    return out^


def _batch_is_wrap_eligible(batch: RecordBatch) raises -> Bool:
    """A RecordBatch is zero-copy-WRAP-eligible iff none of its columns are
    DICTIONARY or nested (LIST/STRUCT/MAP/...). Those are exactly the shapes the
    THSPLC encoder rejects in v0.4, so the wrapped (no-encode) path must reject
    them too — preserving the prior raise-on-unsupported behavior."""
    for i in range(batch.num_columns()):
        var t = batch.column_at(i).arrow_type
        if t == ArrowType.DICTIONARY or t.is_nested():
            return False
    return True


def column_native_from_record_batch(
    var batch: RecordBatch,
) raises -> ColumnNativeBatch:
    """Bridge a RecordBatch into a ColumnNativeBatch.

    P-2.D.ZC ZERO-COPY: for the supported flat (non-dictionary, non-nested)
    column shape this produces a WRAPPED ColumnNativeBatch that holds the
    RecordBatch's columns DIRECTLY — a `take_columns()` move, NO THSPLC encode,
    NO buffer copy. The reverse bridge moves the columns straight back into a
    RecordBatch (also zero-copy). The contiguous THSPLC body is built lazily ONLY
    when the spill/shuffle path needs it (`THSPLCEncoder.encode_column_native`).

    Raises on DICTIONARY / nested columns (the THSPLC encoder restriction in
    v0.4 — the planner dictionary-decodes / flattens upstream of spill). Those
    shapes still route through the contiguous-body THSPLC encode path so the
    raise / fingerprint semantics are unchanged.
    """
    var schema = batch.schema.copy()
    var n_cols = batch.num_columns()
    var row_count = batch.num_rows()

    if _batch_is_wrap_eligible(batch):
        # Zero-copy: move the columns out of the RecordBatch into a wrapped
        # ColumnNativeBatch. No encode, no per-buffer copy. The fingerprint is
        # not needed in wrapped mode (it is recomputed when a contiguous body is
        # materialized for spill); leave it 0.
        var header = ColumnNativeBatchHeader(
            n_cols=UInt32(n_cols),
            row_count=UInt64(row_count),
            schema_fingerprint=0,
            has_selection_vector=0,
            flags=0,
        )
        var columns = batch.take_columns()
        _ = batch^
        return ColumnNativeBatch.wrap_columns(header^, columns^, schema^)

    # Fallback: DICTIONARY / nested — preserve the THSPLC-encode contiguous-body
    # path (this raises, matching the prior behavior for unsupported shapes).
    var body = THSPLCEncoder.encode(batch^)
    var view = body.as_view()
    var fingerprint = view.read_u64_le_at(_HDR_FP_OFF)
    var descriptors = _parse_descriptors_from_thsplc(body, n_cols)
    var hdr = ColumnNativeBatchHeader(
        n_cols=UInt32(n_cols),
        row_count=UInt64(row_count),
        schema_fingerprint=fingerprint,
        has_selection_vector=0,
        flags=0,
    )
    var sel: Optional[SharedAlignedBuffer[HeapRegion]] = None
    return ColumnNativeBatch(hdr^, descriptors^, body^, sel^, None, schema^)


def _record_batch_from_wrapped(
    var batch: ColumnNativeBatch,
) raises -> RecordBatch:
    """Move a WRAPPED batch's columns back into a RecordBatch (zero-copy)."""
    var schema = batch.schema_copy()
    var row_count = batch.physical_row_count()
    var columns = batch^.take_columns_wrapped()
    # Reconstruct preserving the batch's own row count (handles the all-columns-
    # empty / zero-row edge case that `from_typed_columns_slab` would derive as
    # the column length anyway — identical for the common case).
    var rb = RecordBatch.from_typed_columns_slab(schema^, columns^)
    _ = row_count
    return rb^


def record_batch_from_column_native(
    var batch: ColumnNativeBatch,
) raises -> RecordBatch:
    """Decode a ColumnNativeBatch back to a RecordBatch.

    Inverse of `column_native_from_record_batch`. P-2.D.ZC: a WRAPPED batch
    moves its columns straight back into a RecordBatch (zero-copy). A
    contiguous-body batch is restored via `THSPLCDecoder.decode_zerocopy` — the
    restored columns are Arc-clone borrowed slices over the body bytes (no
    memcpy), keeping the body pinned via the cloned Arc refcounts.

    A selection-bearing batch must be densified first (P-2.D); raises if a
    selection vector is present.
    """
    if batch.has_selection():
        raise Error(
            "record_batch_from_column_native: selection-vector batch must be"
            " densified first (materialize_dense) — densify is a P-2.D"
            " deliverable"
        )
    if batch.is_wrapped():
        return _record_batch_from_wrapped(batch^)
    # Contiguous-body (THSPLC) restore — ZERO-COPY: borrowed Arc-clone slices.
    var schema = batch.schema_copy()
    var body = batch^.take_body()
    return THSPLCDecoder.decode_zerocopy(body^, schema^)


def record_batch_from_column_native_unfiltered(
    var batch: ColumnNativeBatch,
) raises -> RecordBatch:
    """Decode the UN-FILTERED columns of a ColumnNativeBatch to a RecordBatch,
    IGNORING any selection vector.

    Unlike `record_batch_from_column_native` (which refuses a selection-bearing
    batch), this returns the physical (un-filtered) columns — every row the
    buffers hold, in physical order — and DROPS the selection vector. It is the
    densify substrate: the engine densify path
    (`column_pipeline.materialize_dense_native`) takes the un-filtered batch
    here, then `gather_batch`es it through the selection indices.

    P-2.D.ZC: WRAPPED batches move their columns out (zero-copy); contiguous-body
    batches restore via `decode_zerocopy` (borrowed Arc-clone slices, no memcpy).
    For a dense batch (no selection) this is identical to
    `record_batch_from_column_native`.
    """
    if batch.is_wrapped():
        return _record_batch_from_wrapped(batch^)
    var schema = batch.schema_copy()
    var body = batch^.take_body()
    return THSPLCDecoder.decode_zerocopy(body^, schema^)
