# =============================================================================
# thsplc.mojo — THSPLC (Komira-Spill-Column) encoder + decoder for RecordBatch.
# =============================================================================
#
# THSPLC is the COLUMN sibling of THSPILL2 (the row codec in
# `thspill2.mojo`): it serializes a `RecordBatch` (SoA / columnar) into
# contiguous bytes and restores it back, with a true 0-copy restore path.
#
# Where THSPILL2 transposes rows into a fixed-stride AoS body, THSPLC keeps
# columns columnar — there is ZERO AoS<->SoA transpose. Each column's
# `[validity?][offsets?][values]` buffers are copied (or, on restore, viewed)
# contiguously. That's the whole point vs the row grain: the in-memory
# per-column `SharedAlignedBuffer` payload IS the on-disk/on-wire body (§12.2
# "Body bytes byte-identical to in-memory storage: Yes").
#
# # On-wire layout (§12.1 + native_shuffle_format_v04 §2.2)
#
#   ┌──────────────────────────────────────────────────────────────┐
#   │ THSPLC header (96 B; thsplc_header.mojo)                       │
#   ├──────────────────────────────────────────────────────────────┤
#   │ Column descriptor section (n_cols × ColumnDescriptor, 48 B ea) │
#   ├──────────────────────────────────────────────────────────────┤
#   │ Per-column buffer 0:  [validity?][offsets?][values]            │
#   │ Per-column buffer 1:  ...                                      │
#   │ ...                                                            │
#   │ Per-column buffer N-1: ...                                     │
#   ├──────────────────────────────────────────────────────────────┤
#   │ Trailing magic (8 B = "THSPLC\x01\x00\x00")                    │
#   └──────────────────────────────────────────────────────────────┘
#
# Each per-column buffer region begins on an 8-byte boundary so that the
# 0-copy restore's borrowed view over the values buffer is directly castable
# (Int32 offsets / Int64 offsets / 8-byte-wide primitives all want >= 8-byte
# alignment for an aligned typed load). The header is 96 B (8-aligned) and
# the descriptor section is a whole number of 48-byte records, so the first
# column region is naturally 8-aligned; each subsequent region is padded up.
#
# # 0-copy restore eligibility (be honest — this drives the benchmark)
#
# A buffer is TRUE-0-copy-restore-eligible when its required alignment is met
# by the on-wire layout AND no value transform is needed:
#
#   * Fixed-width primitives (INT8..INT64, UINT8..UINT64, FLOAT16..FLOAT64,
#     DATE32/64, TIME*, TIMESTAMP*, DURATION*, DECIMAL128/256,
#     FIXED_SIZE_BINARY) — 0-copy. Each region is 8-aligned; the widest
#     element is 16 B (DECIMAL128) / 32 B (DECIMAL256) but the values are
#     read element-by-element (no whole-buffer SIMD-aligned demand at the
#     codec layer), and the 8-byte region alignment satisfies the typed
#     loads the engine performs.
#   * Variable-width STRING / BINARY (Int32 offsets) + LARGE_STRING /
#     LARGE_BINARY (Int64 offsets) — 0-copy. Offsets region is 8-aligned
#     (Int32/Int64 both castable); values region is raw bytes (alignment 1).
#   * BOOLEAN — 0-copy. Data is an LSB-packed bitmap (alignment 1).
#   * Validity bitmaps (any type) — 0-copy. LSB-packed, alignment 1.
#
# COPY-FALLBACK (NOT 0-copy):
#   * DICTIONARY columns — carry an extra `_dict_data` buffer + index-width
#     metadata the v0.4 THSPLC body does not yet lay out (the shuffle
#     format defers dictionary on the wire too). decode_zerocopy raises for these;
#     decode_copy handles them only if they were encoded (encode raises on
#     DICTIONARY in v0.4 — the planner dictionary-decodes upstream of spill).
#   * Nested types (LIST / STRUCT / MAP / UNION / FIXED_SIZE_LIST) — multi-
#     buffer / child-column layouts deferred to a follow-up slot. encode
#     raises.
#
# # Spillable relationship
#
# `Spillable` (thspill2.mojo) is shaped for the ROW body: `as_byte_view` +
# `from_bytes(bytes, row_count, fingerprint)`. THSPLC's restore needs the
# caller's expected `Schema` (the operator knows its output shape), so the
# public surface here is RecordBatch-specific rather than going through the
# opaque-body `Spillable` trait. The encoder still produces a single
# `SharedAlignedBuffer[HeapRegion]` that a `SpillStorage.write_chunk` consumes
# unchanged, and the decoders consume a `SharedAlignedBuffer[HeapRegion]` that
# `SpillStorage.read_chunk` produces — so the storage substrate is shared with
# THSPILL2 byte-for-byte (§12.2 "Network shuffle frame envelope: Same").
#
# # Encapsulation rule
#
# NO `UnsafePointer` on any public surface. Bytes flow via
# `SharedAlignedBuffer[HeapRegion]` and `ByteView[origin]`. The descriptor
# pack/parse uses OAB/SAB scalar `write_*_le_at` / `read_*_le_at` accessors —
# no raw pointer arithmetic escapes this module.
# =============================================================================

from std.collections import Optional

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap, bytes_for_bits
from komira_arrow.column import Column
from komira_arrow.column_native import ColumnNativeBatch
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_collections.slab import Slab
from komira_buffer.heap_region import HeapRegion

from .fnv1a import fnv1a_64_partition_fingerprint
from .thsplc_header import (
    THSPLC_HEADER_SIZE,
    THSPLC_TRAILER_SIZE,
    THSPLC_MAGIC_0,
    THSPLC_MAGIC_1,
    THSPLC_MAGIC_2,
    THSPLC_MAGIC_3,
    THSPLC_MAGIC_4,
    THSPLC_MAGIC_5,
    THSPLC_MAGIC_6,
    THSPLC_MAGIC_7,
    THSPLCHeader,
    pack_thsplc_header,
    parse_thsplc_header,
)


# =============================================================================
# ColumnDescriptor — per-column 48-byte record in the descriptor section.
# =============================================================================

comptime THSPLC_DESCRIPTOR_SIZE: Int = 48


struct _ColumnDescriptor(
    Copyable, ImplicitlyCopyable, Movable, Deinitable
):
    """Per-column descriptor (48 bytes on wire). Lets the decoder slice each
    column's buffers from the body without re-deriving sizes from the schema.

    On-wire layout (little-endian; 48 bytes):
        bytes  0.. 3 : arrow_type_id            (UInt32; ArrowType.type_id)
        bytes  4.. 7 : flags                    (UInt32; bit0=has_validity,
                                                 bit1=has_offsets,
                                                 bit2=offsets_are_int64)
        bytes  8..15 : length                   (UInt64; logical row count)
        bytes 16..23 : null_count               (UInt64)
        bytes 24..31 : region_offset            (UInt64; byte offset of this
                                                 column's buffer region from
                                                 the START of the chunk —
                                                 i.e. absolute, incl. header +
                                                 descriptors)
        bytes 32..35 : validity_len             (UInt32; bytes; 0 if absent)
        bytes 36..39 : offsets_len              (UInt32; bytes; 0 if absent)
        bytes 40..47 : values_len               (UInt64; bytes)

    Region layout within `[region_offset, region_offset + total_len)`:
        [validity (validity_len)] [offsets (offsets_len)] [values (values_len)]
    in that order (matches native_shuffle_format_v04 §2.2 nullable var-width
    layout `[validity][offsets][data]`).
    """

    comptime FLAG_HAS_VALIDITY: UInt32 = 1
    comptime FLAG_HAS_OFFSETS: UInt32 = 2
    comptime FLAG_OFFSETS_INT64: UInt32 = 4

    var arrow_type_id: UInt32
    var flags: UInt32
    var length: UInt64
    var null_count: UInt64
    var region_offset: UInt64
    var validity_len: UInt32
    var offsets_len: UInt32
    var values_len: UInt64

    def __init__(
        out self,
        arrow_type_id: UInt32,
        flags: UInt32,
        length: UInt64,
        null_count: UInt64,
        region_offset: UInt64,
        validity_len: UInt32,
        offsets_len: UInt32,
        values_len: UInt64,
    ):
        self.arrow_type_id = arrow_type_id
        self.flags = flags
        self.length = length
        self.null_count = null_count
        self.region_offset = region_offset
        self.validity_len = validity_len
        self.offsets_len = offsets_len
        self.values_len = values_len

    def has_validity(self) -> Bool:
        return (self.flags & Self.FLAG_HAS_VALIDITY) != 0

    def has_offsets(self) -> Bool:
        return (self.flags & Self.FLAG_HAS_OFFSETS) != 0

    def offsets_are_int64(self) -> Bool:
        return (self.flags & Self.FLAG_OFFSETS_INT64) != 0

    def pack_into(self, mut oab: OwnedAlignedBuffer, at: Int):
        """Write this descriptor's 48 bytes into `oab` starting at `at`.
        Caller guarantees `[at, at+48)` is in bounds."""
        oab.write_u32_le_at(at + 0, self.arrow_type_id)
        oab.write_u32_le_at(at + 4, self.flags)
        oab.write_u64_le_at(at + 8, self.length)
        oab.write_u64_le_at(at + 16, self.null_count)
        oab.write_u64_le_at(at + 24, self.region_offset)
        oab.write_u32_le_at(at + 32, self.validity_len)
        oab.write_u32_le_at(at + 36, self.offsets_len)
        oab.write_u64_le_at(at + 40, self.values_len)

    @staticmethod
    def unpack_from(
        buf: SharedAlignedBuffer[HeapRegion], at: Int
    ) -> _ColumnDescriptor:
        """Read a descriptor's 48 bytes from `buf` starting at `at`. Caller
        guarantees `[at, at+48)` is in bounds."""
        return _ColumnDescriptor(
            arrow_type_id=buf.read_u32_le_at(at + 0),
            flags=buf.read_u32_le_at(at + 4),
            length=buf.read_u64_le_at(at + 8),
            null_count=buf.read_u64_le_at(at + 16),
            region_offset=buf.read_u64_le_at(at + 24),
            validity_len=buf.read_u32_le_at(at + 32),
            offsets_len=buf.read_u32_le_at(at + 36),
            values_len=buf.read_u64_le_at(at + 40),
        )


# =============================================================================
# Type-shape helpers
# =============================================================================


def _fixed_width_bytes(t: ArrowType) raises -> Int:
    """Bytes-per-element for a fixed-width Arrow type. Raises for variable-
    width / nested / dictionary types (handled by the var-width path or
    rejected). BOOL is special-cased by the caller (LSB-packed bitmap)."""
    if t == ArrowType.INT8 or t == ArrowType.UINT8:
        return 1
    if (
        t == ArrowType.INT16
        or t == ArrowType.UINT16
        or t == ArrowType.FLOAT16
    ):
        return 2
    if (
        t == ArrowType.INT32
        or t == ArrowType.UINT32
        or t == ArrowType.FLOAT32
        or t == ArrowType.DATE32
        or t == ArrowType.TIME32_S
        or t == ArrowType.TIME32_MS
    ):
        return 4
    if (
        t == ArrowType.INT64
        or t == ArrowType.UINT64
        or t == ArrowType.FLOAT64
        or t == ArrowType.DATE64
        or t == ArrowType.TIMESTAMP
        or t == ArrowType.TIMESTAMP_S
        or t == ArrowType.TIMESTAMP_MS
        or t == ArrowType.TIMESTAMP_US
        or t == ArrowType.TIMESTAMP_NS
        or t == ArrowType.TIME64_US
        or t == ArrowType.TIME64_NS
        or t == ArrowType.DURATION_S
        or t == ArrowType.DURATION_MS
        or t == ArrowType.DURATION_US
        or t == ArrowType.DURATION_NS
    ):
        return 8
    if t == ArrowType.DECIMAL128:
        return 16
    if t == ArrowType.DECIMAL256:
        return 32
    raise Error(
        "THSPLC: _fixed_width_bytes: type "
        + String(t)
        + " is not a supported fixed-width type"
    )


def _is_varlen(t: ArrowType) -> Bool:
    return (
        t == ArrowType.STRING
        or t == ArrowType.BINARY
        or t == ArrowType.LARGE_STRING
        or t == ArrowType.LARGE_BINARY
    )


def _offsets_are_int64(t: ArrowType) -> Bool:
    return t == ArrowType.LARGE_STRING or t == ArrowType.LARGE_BINARY


def _align_up_8(n: Int) -> Int:
    return ((n + 7) // 8) * 8


comptime THSPLC_WIRE_U32_MAX: Int = 0xFFFFFFFF
"""Largest `validity_len` / `offsets_len` a THSPLC descriptor can carry.

⭐ VARHEAP-OFFSET-CEILING's spill-format sibling (2026-09-23). Both fields are
UInt32 on the wire while every other length and offset in the descriptor is
UInt64, and the encoder narrowed them with a bare `UInt32(...)`. Worse, pass 2
copies `Int(d.offsets_len)` -- the NARROWED value -- so a wrapped field is not
merely mis-recorded: the offsets region is written TRUNCATED and the values land
early, and the decoder, reading the same narrowed field, rebuilds the column
from the wrong bytes without failing a single bounds check. Reachable by ONE
spilled batch of >= 2**30 STRING rows (Int32 offsets) or >= 2**29 LARGE_STRING
rows -- `SortBuffer.spill_to_storage` encodes its whole buffered run as one
batch. Refused in pass 1, before the chunk is allocated."""


def _thsplc_wire_u32(
    n: Int, field: StaticString, col: Int
) raises -> UInt32:
    """Narrow a descriptor length to its UInt32 wire field, REFUSING rather
    than wrapping when it does not fit."""
    if n < 0 or n > THSPLC_WIRE_U32_MAX:
        raise Error(
            "THSPLCEncoder: column " + String(col) + " " + String(field)
            + "=" + String(n) + " does not fit the descriptor's 32-bit field"
            " (max " + String(THSPLC_WIRE_U32_MAX) + "). Refused rather than"
            " truncated: the region would be written short and decoded from"
            " the wrong bytes."
        )
    return UInt32(n)


# =============================================================================
# THSPLCEncoder — RecordBatch -> contiguous THSPLC bytes.
# =============================================================================


struct THSPLCEncoder:
    """Engine-side encoder for THSPLC column chunks. Static, no per-call
    state — callers write `THSPLCEncoder.encode(batch)`.

    Produces ONE `SharedAlignedBuffer[HeapRegion]` holding header + descriptor
    section + per-column buffers + trailing magic. The buffer is ready to hand
    to `SpillStorage.write_chunk` unchanged (same substrate as THSPILL2)."""

    @staticmethod
    def encode(var batch: RecordBatch) raises -> SharedAlignedBuffer[HeapRegion]:
        """Serialize `batch` into contiguous THSPLC bytes.

        Body shape: `[96 B header][n_cols × 48 B descriptors][per-column
        buffers, 8-aligned each][8 B trailing magic]`. Columns stay columnar
        — no AoS<->SoA transpose.

        Raises on DICTIONARY / nested columns (deferred to a follow-up slot;
        the planner dictionary-decodes / flattens upstream of spill in v0.4).

        Args:
            batch: The RecordBatch to serialize. Consumed.

        Returns:
            A `SharedAlignedBuffer[HeapRegion]` over the THSPLC bytes.
        """
        var n_cols = batch.num_columns()
        var row_count = batch.num_rows()

        # --- Pass 1: compute per-column sizes + total layout ---
        var descriptors = List[_ColumnDescriptor]()
        var descriptors_bytes = n_cols * THSPLC_DESCRIPTOR_SIZE
        # First column region begins right after the (8-aligned) descriptor
        # section. Header (96) + descriptors_bytes is already 8-aligned
        # because 96 % 8 == 0 and 48 % 8 == 0.
        var cursor = THSPLC_HEADER_SIZE + descriptors_bytes

        for i in range(n_cols):
            ref col = batch.column_at(i)
            var t = col.arrow_type

            if t == ArrowType.DICTIONARY:
                raise Error(
                    "THSPLCEncoder.encode: DICTIONARY column "
                    + String(i)
                    + " is not supported in v0.4 (planner must dictionary-"
                    "decode upstream of spill)"
                )

            var flags = UInt32(0)
            var validity_len = 0
            var offsets_len = 0
            var values_len: Int

            # validity (any nullable type, if a bitmap is materialized)
            if col._validity:
                flags |= _ColumnDescriptor.FLAG_HAS_VALIDITY
                validity_len = bytes_for_bits(col._length)

            if t == ArrowType.BOOL:
                # LSB-packed data bitmap.
                values_len = bytes_for_bits(col._length)
            elif _is_varlen(t):
                flags |= _ColumnDescriptor.FLAG_HAS_OFFSETS
                var is64 = _offsets_are_int64(t)
                if is64:
                    flags |= _ColumnDescriptor.FLAG_OFFSETS_INT64
                var off_width = 8 if is64 else 4
                offsets_len = (col._length + 1) * off_width
                # values byte count = the actual data buffer length the
                # column carries (offsets[length] worth of bytes).
                values_len = col._data.len()
            else:
                # Fixed-width primitive.
                var w = _fixed_width_bytes(t)
                values_len = col._length * w

            # The region begins 8-aligned.
            var region_offset = _align_up_8(cursor)

            descriptors.append(
                _ColumnDescriptor(
                    arrow_type_id=UInt32(Int(t.type_id)),
                    flags=flags,
                    length=UInt64(col._length),
                    null_count=UInt64(col._null_count),
                    region_offset=UInt64(region_offset),
                    validity_len=_thsplc_wire_u32(
                        validity_len, "validity_len", i
                    ),
                    offsets_len=_thsplc_wire_u32(offsets_len, "offsets_len", i),
                    values_len=UInt64(values_len),
                )
            )

            var region_total = validity_len + offsets_len + values_len
            cursor = region_offset + region_total

        # body_length = everything after the 96 B header, EXCLUDING the
        # trailing magic. Pad the body end to 8 so the trailing magic is
        # 8-aligned (cosmetic; keeps the whole chunk 8-aligned).
        var body_end = _align_up_8(cursor)
        var body_length = body_end - THSPLC_HEADER_SIZE
        var total = body_end + THSPLC_TRAILER_SIZE

        # Fingerprint over the (type_id, nullable) per column — a stable
        # schema identity for restore-side mismatch detection.
        var fingerprint = _schema_fingerprint(batch.schema, n_cols)

        # --- Pass 2: allocate + fill ---
        var oab = OwnedAlignedBuffer(capacity=total)
        oab.set_length(Int64(total))
        # Zero the whole buffer so inter-region pad bytes + the final tail
        # are deterministic (reproducible on-disk image).
        oab.zero()

        # Header.
        var header = THSPLCHeader.for_uncompressed(
            n_cols=UInt32(n_cols),
            body_length=UInt64(body_length),
            row_count=UInt64(row_count),
            schema_fingerprint=fingerprint,
            descriptors_byte_len=UInt32(descriptors_bytes),
        )
        # SAFETY: `oab.view_mut().into_span()` yields a Span tied to the local
        # `oab`; pack_thsplc_header bounds-checks `>= 96`. The span does not
        # escape; `oab` is held alive across the call by this frame.
        pack_thsplc_header(header, oab.view_mut().into_span())

        # Descriptor section.
        for i in range(n_cols):
            descriptors[i].pack_into(
                oab, THSPLC_HEADER_SIZE + i * THSPLC_DESCRIPTOR_SIZE
            )

        # Per-column buffers.
        for i in range(n_cols):
            ref col = batch.column_at(i)
            var d = descriptors[i]
            var off = Int(d.region_offset)

            # [validity]
            if d.has_validity():
                var vlen = Int(d.validity_len)
                # SAFETY: validity bitmap bytes live in
                # `col._validity.value().buffer`; copy `vlen` bytes into the
                # destination region. Bounds: region was sized to hold vlen.
                oab.copy_from_view_at(
                    off,
                    col._validity.value().buffer.view_range_ro(0, vlen),
                )
                off += vlen

            # [offsets]
            if d.has_offsets():
                var olen = Int(d.offsets_len)
                # SAFETY: offsets buffer present for varlen types.
                oab.copy_from_view_at(
                    off, col._offsets.value().view_range_ro(0, olen)
                )
                off += olen

            # [values]
            var vallen = Int(d.values_len)
            if vallen > 0:
                # SAFETY: values bytes are `col._data[0 : vallen]`. For
                # fixed-width with a slice offset, honor `col._offset`.
                var src_byte_off = 0
                if (
                    not d.has_offsets()
                    and d.arrow_type_id != UInt32(Int(ArrowType.BOOL.type_id))
                ):
                    var w = _fixed_width_bytes(ArrowType(Int(d.arrow_type_id)))
                    src_byte_off = col._offset * w
                oab.copy_from_view_at(
                    off, col._data.view_range_ro(src_byte_off, vallen)
                )

        # Trailing magic.
        var tmag = body_end
        oab.write_u8_at(tmag + 0, THSPLC_MAGIC_0)
        oab.write_u8_at(tmag + 1, THSPLC_MAGIC_1)
        oab.write_u8_at(tmag + 2, THSPLC_MAGIC_2)
        oab.write_u8_at(tmag + 3, THSPLC_MAGIC_3)
        oab.write_u8_at(tmag + 4, THSPLC_MAGIC_4)
        oab.write_u8_at(tmag + 5, THSPLC_MAGIC_5)
        oab.write_u8_at(tmag + 6, THSPLC_MAGIC_6)
        oab.write_u8_at(tmag + 7, THSPLC_MAGIC_7)

        _ = batch^
        return SharedAlignedBuffer[HeapRegion].from_owned(oab^)

    @staticmethod
    def encode_column_native(
        var batch: ColumnNativeBatch,
    ) raises -> SharedAlignedBuffer[HeapRegion]:
        """P-2.D.ZC spill/shuffle path: produce the contiguous THSPLC body bytes
        FROM a (zero-copy) ColumnNativeBatch.

        The pipeline path keeps the zero-copy per-column handles and never builds
        a contiguous body; ONLY the spill / network-shuffle path needs the
        contiguous THSPLC chunk. This overload materializes that chunk on demand:

          * WRAPPED batch — move its columns into a RecordBatch (zero-copy) and
            run the existing byte-exact `encode(RecordBatch)`. The produced body
            is byte-identical to encoding the source RecordBatch directly.
          * CONTIGUOUS-BODY batch — the body IS already a THSPLC chunk; return it
            unchanged (a `take_body` move, no re-encode).

        Selection-bearing batches MUST be densified first (the spill body is the
        physical un-filtered columns); raises if a selection is present.
        """
        if batch.has_selection():
            raise Error(
                "THSPLCEncoder.encode_column_native: a selection-bearing batch"
                " must be densified (materialize_dense) before spill — the"
                " contiguous THSPLC body holds physical un-filtered columns"
            )
        if batch.is_wrapped():
            var schema = batch.schema_copy()
            var columns = batch^.take_columns_wrapped()
            var rb = RecordBatch.from_typed_columns_slab(schema^, columns^)
            return THSPLCEncoder.encode(rb^)
        # Already a contiguous THSPLC chunk — hand it back unchanged.
        return batch^.take_body()


# =============================================================================
# THSPLCDecoder — bytes -> RecordBatch, copy + 0-copy paths.
# =============================================================================


struct THSPLCDecoder:
    """Engine-side decoder for THSPLC column chunks (static, two paths).

    Static, no per-call state. Two restore paths:

      * `decode_copy(bytes, schema)`   — memcpy each buffer into fresh OABs.
        The honest baseline; restored buffers are independent of `bytes`.
      * `decode_zerocopy(bytes, schema)` — each column buffer is a
        `SharedAlignedBuffer.from_borrowed_view(bytes, off, len)` Arc-clone
        slice over `bytes`. NO memcpy; the restored batch keeps `bytes` alive
        via the cloned Arc refcount.

    Both take the caller's expected `Schema` (the operator knows its output
    shape) — mirrors THSPILL2's `from_bytes(bytes, row_count, fingerprint)`
    contract where the operator supplies the schema identity."""

    @staticmethod
    def _parse_header(
        bytes: SharedAlignedBuffer[HeapRegion],
    ) raises -> THSPLCHeader:
        """Parse + validate the header (incl. total-length cross-check).
        Descriptors are parsed inline by each decode path (cheap, 48 B each).

        RELEASE-BUILD GUARANTEE: every check here is a real `raise` (NOT a
        `debug_assert`), so a truncated / corrupt header is rejected with a
        typed error in release builds — not silently mis-parsed into an
        out-of-bounds descriptor walk. `parse_thsplc_header` already raises on
        bad magic / unknown version / `< 96 B` short. This adds:
          * sane `n_cols` (non-negative when read as Int; bounded so the
            descriptor section itself cannot overflow the declared body),
          * declared total length (header + body + trailer) <= actual chunk
            length,
          * the descriptor section fits inside the declared body.
        """
        var view = bytes.as_view()
        var header = parse_thsplc_header(view.into_span())

        var declared_total = (
            Int64(THSPLC_HEADER_SIZE)
            + Int64(header.body_length)
            + Int64(THSPLC_TRAILER_SIZE)
        )
        if bytes.length() < declared_total:
            raise Error(
                "THSPLCDecoder: chunk has "
                + String(Int(bytes.length()))
                + " bytes but header declares "
                + String(Int(declared_total))
            )

        # n_cols sanity. UInt32 -> Int is always non-negative on 64-bit, but
        # an absurdly large n_cols would make the descriptor section overflow
        # the chunk. Bound it by what the chunk can physically hold so the
        # per-column descriptor walk below cannot read past the buffer.
        var n_cols = Int(header.n_cols)
        var descriptors_bytes = n_cols * THSPLC_DESCRIPTOR_SIZE
        var descriptors_end = THSPLC_HEADER_SIZE + descriptors_bytes
        if Int64(descriptors_end) > bytes.length():
            raise Error(
                "THSPLCDecoder: n_cols="
                + String(n_cols)
                + " implies a "
                + String(descriptors_bytes)
                + "-byte descriptor section ending at "
                + String(descriptors_end)
                + " but chunk is only "
                + String(Int(bytes.length()))
                + " bytes — corrupt header"
            )
        return header

    @staticmethod
    def _validate_descriptor(
        d: _ColumnDescriptor,
        chunk_len: Int64,
        i: Int,
    ) raises:
        """RELEASE-BUILD descriptor bounds check (was `debug_assert`-only in
        `_rebuild_column_*`). Rejects a corrupt / truncated descriptor whose
        buffer region — or any of its `[validity][offsets][values]`
        sub-regions — would read past the chunk end.

        This is the zerocopy UAF-prevention point: it MUST be called BEFORE
        any `from_borrowed_view` / `view_range_ro` constructs a buffer or
        borrowed view over the chunk bytes (those primitives only
        `debug_assert` their own bounds, so in release a corrupt
        `region_offset` / `*_len` would alias PAST the chunk — a latent UAF).

        Checks (all O(1)):
          * `region_offset >= 0` and within the chunk,
          * each sub-region length non-negative,
          * `region_offset + validity_len + offsets_len + values_len`
            does not exceed `chunk_len`, with no integer overflow.
        """
        # Promote the unsigned on-wire fields to signed Int64 so an
        # absurd (near-2^64) value reads as a huge positive that overruns
        # chunk_len rather than wrapping. region_offset is UInt64; the
        # sub-lengths are UInt32/UInt64.
        var region_offset = Int64(d.region_offset)
        var validity_len = Int64(d.validity_len)
        var offsets_len = Int64(d.offsets_len)
        var values_len = Int64(d.values_len)

        if (
            region_offset < 0
            or validity_len < 0
            or offsets_len < 0
            or values_len < 0
        ):
            raise Error(
                "THSPLCDecoder: column "
                + String(i)
                + " descriptor has a negative offset/length"
                + " (region_offset="
                + String(Int(region_offset))
                + ", validity_len="
                + String(Int(validity_len))
                + ", offsets_len="
                + String(Int(offsets_len))
                + ", values_len="
                + String(Int(values_len))
                + ") — corrupt chunk"
            )

        # The buffer region begins inside the chunk.
        if region_offset > chunk_len:
            raise Error(
                "THSPLCDecoder: column "
                + String(i)
                + " region_offset="
                + String(Int(region_offset))
                + " is past the chunk end ("
                + String(Int(chunk_len))
                + " bytes) — corrupt chunk"
            )

        # The full region [validity][offsets][values] fits within the chunk.
        # Accumulate in Int64; each addend is already proven non-negative, so
        # the sum is monotonic and cannot wrap a 64-bit signed for any
        # realistic chunk (< 2^62 bytes).
        var region_total = validity_len + offsets_len + values_len
        var region_end = region_offset + region_total
        if region_end > chunk_len:
            raise Error(
                "THSPLCDecoder: column "
                + String(i)
                + " region [offset="
                + String(Int(region_offset))
                + ", validity="
                + String(Int(validity_len))
                + ", offsets="
                + String(Int(offsets_len))
                + ", values="
                + String(Int(values_len))
                + "] ends at "
                + String(Int(region_end))
                + " but chunk is only "
                + String(Int(chunk_len))
                + " bytes — descriptor points out of bounds"
            )

    @staticmethod
    def _descriptor_at(
        bytes: SharedAlignedBuffer[HeapRegion], i: Int
    ) -> _ColumnDescriptor:
        """Read the i-th 48-byte column descriptor from the descriptor
        section that immediately follows the header."""
        return _ColumnDescriptor.unpack_from(
            bytes, THSPLC_HEADER_SIZE + i * THSPLC_DESCRIPTOR_SIZE
        )

    @staticmethod
    def _check_fingerprint(
        header: THSPLCHeader,
        schema: Schema,
        n_cols: Int,
        path: StringLiteral,
    ) raises:
        """Reject a wrong-schema restore: recompute the fingerprint of the
        caller's expected `schema` and compare against the header's
        `schema_fingerprint` (written by the encoder over the SOURCE schema).

        Col-count is checked separately by the caller; this catches the
        subtler same-col-count / different-types case (e.g. restoring an
        `[INT64, INT64]` chunk into an `[INT64, FLOAT64]` schema), which would
        otherwise reinterpret the bytes and silently produce garbage."""
        var expected = _schema_fingerprint(schema, n_cols)
        if header.schema_fingerprint != expected:
            raise Error(
                "THSPLCDecoder."
                + String(path)
                + ": schema fingerprint mismatch — chunk header declares "
                + String(header.schema_fingerprint)
                + " but the caller's schema fingerprints to "
                + String(expected)
                + " (same column count, incompatible field types/nullability)"
            )

    @staticmethod
    def decode_copy(
        var bytes: SharedAlignedBuffer[HeapRegion],
        var schema: Schema,
    ) raises -> RecordBatch:
        """Restore a RecordBatch, memcpy-ing each buffer into fresh owning
        `OwnedAlignedBuffer`s. The restored batch is fully independent of
        `bytes` (which is dropped at the end of this call)."""
        var header = Self._parse_header(bytes)
        var n_cols = Int(header.n_cols)

        if schema.num_columns() != n_cols:
            raise Error(
                "THSPLCDecoder.decode_copy: schema has "
                + String(schema.num_columns())
                + " fields but chunk has "
                + String(n_cols)
                + " columns"
            )

        # Fingerprint enforcement: a same-col-count / wrong-types schema would
        # otherwise silently produce garbage. The decoder OWNS the expected
        # Schema, so it can recompute the expected fingerprint and reject a
        # mismatch with a typed error.
        Self._check_fingerprint(header, schema, n_cols, "decode_copy")

        var chunk_len = bytes.length()
        var columns = Slab[Column[HeapRegion]].create(max(n_cols, 1))
        for i in range(n_cols):
            var d = Self._descriptor_at(bytes, i)
            # RELEASE-BUILD bounds gate BEFORE any buffer is built.
            Self._validate_descriptor(d, chunk_len, i)
            columns.append(Self._rebuild_column_copy(bytes, d))

        var batch = RecordBatch()
        batch.schema = schema^
        batch._columns = columns^
        batch._num_rows = Int(header.row_count)
        _ = bytes^
        return batch^

    @staticmethod
    def decode_zerocopy(
        var bytes: SharedAlignedBuffer[HeapRegion],
        var schema: Schema,
    ) raises -> RecordBatch:
        """Restore a RecordBatch with NO memcpy: each column buffer is a
        borrowed Arc-clone slice over `bytes`. The restored batch keeps
        `bytes` alive (the cloned Arc refcounts the source storage).

        Raises on DICTIONARY / nested columns (copy-fallback only)."""
        var header = Self._parse_header(bytes)
        var n_cols = Int(header.n_cols)

        if schema.num_columns() != n_cols:
            raise Error(
                "THSPLCDecoder.decode_zerocopy: schema has "
                + String(schema.num_columns())
                + " fields but chunk has "
                + String(n_cols)
                + " columns"
            )

        # Fingerprint enforcement (see decode_copy): reject a same-col-count /
        # wrong-types schema before any borrowed view is built.
        Self._check_fingerprint(header, schema, n_cols, "decode_zerocopy")

        var chunk_len = bytes.length()
        var columns = Slab[Column[HeapRegion]].create(max(n_cols, 1))
        for i in range(n_cols):
            var d = Self._descriptor_at(bytes, i)
            # UAF-PREVENTION POINT: validate the descriptor's region + every
            # sub-region against the chunk length BEFORE _rebuild_column_zerocopy
            # calls from_borrowed_view (which only debug_asserts its bounds, so
            # in release a corrupt region_offset/len would alias PAST the chunk).
            Self._validate_descriptor(d, chunk_len, i)
            columns.append(Self._rebuild_column_zerocopy(bytes, d))

        var batch = RecordBatch()
        batch.schema = schema^
        batch._columns = columns^
        batch._num_rows = Int(header.row_count)
        # NOTE: `bytes` is consumed here — the per-column borrowed SABs each
        # hold their own Arc clone of `bytes`'s region, so the source storage
        # stays pinned for as long as any restored column is alive.
        _ = bytes^
        return batch^

    # ----------------------------------------------------------------------
    # Per-column rebuild helpers
    # ----------------------------------------------------------------------

    @staticmethod
    def _rebuild_column_copy(
        bytes: SharedAlignedBuffer[HeapRegion], d: _ColumnDescriptor
    ) raises -> Column[HeapRegion]:
        """Rebuild one Column by memcpy-ing its buffers into fresh OABs."""
        var t = ArrowType(Int(d.arrow_type_id))
        var off = Int(d.region_offset)
        var length = Int(d.length)
        var null_count = Int(d.null_count)

        # validity
        var validity = Optional[Bitmap[HeapRegion]](None)
        if d.has_validity():
            var vlen = Int(d.validity_len)
            var bm = Bitmap[HeapRegion].create(length)
            # SAFETY: copy vlen bytes of bitmap from the chunk into the
            # freshly-allocated bitmap buffer.
            bm.buffer.copy_from_view(bytes.view_range_ro(off, vlen))
            validity = bm^
            off += vlen

        # offsets
        var offsets = Optional[SharedAlignedBuffer[HeapRegion]](None)
        if d.has_offsets():
            var olen = Int(d.offsets_len)
            var ooab = OwnedAlignedBuffer(capacity=max(olen, 1))
            ooab.set_length(Int64(olen))
            ooab.copy_from_view(bytes.view_range_ro(off, olen))
            offsets = SharedAlignedBuffer[HeapRegion].from_owned(ooab^)
            off += olen

        # values
        var vallen = Int(d.values_len)
        var voab = OwnedAlignedBuffer(capacity=max(vallen, 1))
        voab.set_length(Int64(vallen))
        if vallen > 0:
            voab.copy_from_view(bytes.view_range_ro(off, vallen))
        var data = SharedAlignedBuffer[HeapRegion].from_owned(voab^)

        return Column[HeapRegion](
            arrow_type=t,
            data=data^,
            offsets=offsets^,
            validity=validity^,
            length=length,
            null_count=null_count,
            offset=0,
        )

    @staticmethod
    def _rebuild_column_zerocopy(
        bytes: SharedAlignedBuffer[HeapRegion], d: _ColumnDescriptor
    ) raises -> Column[HeapRegion]:
        """Rebuild one Column with NO memcpy — each buffer is a borrowed
        Arc-clone slice over `bytes`."""
        var t = ArrowType(Int(d.arrow_type_id))
        if t == ArrowType.DICTIONARY:
            raise Error(
                "THSPLCDecoder.decode_zerocopy: DICTIONARY columns are"
                " copy-fallback only (use decode_copy)"
            )
        var off = Int(d.region_offset)
        var length = Int(d.length)
        var null_count = Int(d.null_count)

        # validity — borrowed slice
        var validity = Optional[Bitmap[HeapRegion]](None)
        if d.has_validity():
            var vlen = Int(d.validity_len)
            var bm = Bitmap[HeapRegion]()
            # SAFETY: Arc-clone slice over `bytes`; the borrow holds its own
            # ref to the source region (from_borrowed_view(owner, off, len)).
            bm.buffer = SharedAlignedBuffer[HeapRegion].from_borrowed_view(
                bytes, Int64(off), Int64(vlen)
            )
            bm.length = length
            validity = bm^
            off += vlen

        # offsets — borrowed slice
        var offsets = Optional[SharedAlignedBuffer[HeapRegion]](None)
        if d.has_offsets():
            var olen = Int(d.offsets_len)
            offsets = SharedAlignedBuffer[HeapRegion].from_borrowed_view(
                bytes, Int64(off), Int64(olen)
            )
            off += olen

        # values — borrowed slice
        var vallen = Int(d.values_len)
        var data = SharedAlignedBuffer[HeapRegion].from_borrowed_view(
            bytes, Int64(off), Int64(max(vallen, 0))
        )

        return Column[HeapRegion](
            arrow_type=t,
            data=data^,
            offsets=offsets^,
            validity=validity^,
            length=length,
            null_count=null_count,
            offset=0,
        )


# =============================================================================
# Schema fingerprint
# =============================================================================


def _schema_fingerprint(schema: Schema, n_cols: Int) raises -> UInt64:
    """FNV-1a-64 over per-column `(type_id, nullable)` — a stable schema
    identity for restore-side mismatch detection. Matches THSPLC header
    `schema_fingerprint` (UInt64; §12.2)."""
    var bytes = List[UInt8]()
    for i in range(n_cols):
        bytes.append(schema.field_arrow_type(i).type_id)
        bytes.append(UInt8(1) if schema.field_nullable(i) else UInt8(0))
    # `entry_stride` is the canonical first 8 LE bytes folded by the helper;
    # use n_cols as the column-grain analogue of the row-grain entry stride.
    return fnv1a_64_partition_fingerprint(n_cols, bytes)
