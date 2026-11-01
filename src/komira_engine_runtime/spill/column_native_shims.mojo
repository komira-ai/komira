# =============================================================================
# column_native_shims.mojo: the bridges between RecordBatch and
# ColumnNativeBatch.
# =============================================================================
#
#   column_native_from_record_batch: a flat batch (no DICTIONARY, no nested
#       column) is WRAPPED: its columns move into the ColumnNativeBatch with no
#       encode and no copy. A DICTIONARY or nested column is refused by name.
#   record_batch_from_column_native: a wrapped batch moves its columns back; a
#       contiguous-body batch (a THSPLC chunk) is restored by
#       THSPLCDecoder.decode_zerocopy as slices that share the body buffer.
#
# A contiguous ColumnNativeBatch body is a THSPLC chunk, so restoring one is
# byte-identical to a spill restore. The shims live here, beside the THSPLC
# codec, because komira_arrow (which owns ColumnNativeBatch) sits below the
# engine runtime and cannot import the codec.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column_native import ColumnNativeBatch, ColumnNativeBatchHeader
from komira_arrow.record_batch import RecordBatch

from komira_engine_runtime.spill.thsplc import THSPLCDecoder


def _refuse_unwrappable_columns(batch: RecordBatch) raises:
    """Raise, naming the column, if `batch` holds a DICTIONARY or nested
    (LIST/STRUCT/MAP/...) column: THSPLC has no layout for those shapes."""
    for i in range(batch.num_columns()):
        var t = batch.column_at(i).arrow_type
        if t == ArrowType.DICTIONARY or t.is_nested():
            raise Error(
                "column_native_from_record_batch: column "
                + String(i)
                + " has type "
                + String(t)
                + ", which this bridge does not support (DICTIONARY and"
                " nested columns have no THSPLC layout)"
            )


def column_native_from_record_batch(
    var batch: RecordBatch,
) raises -> ColumnNativeBatch:
    """Bridge a RecordBatch into a ColumnNativeBatch.

    Zero-copy: for the supported flat (non-dictionary, non-nested)
    column shape this produces a WRAPPED ColumnNativeBatch that holds the
    RecordBatch's columns DIRECTLY — a `take_columns()` move, NO THSPLC encode,
    NO buffer copy. The reverse bridge moves the columns straight back into a
    RecordBatch (also zero-copy). A contiguous THSPLC body is built only when a
    caller asks for one (`THSPLCEncoder.encode_column_native`).

    Raises on a DICTIONARY or nested column, naming it: THSPLC has no layout
    for those shapes, so this bridge does not take them.
    """
    _refuse_unwrappable_columns(batch)
    # Zero-copy: move the columns out of the RecordBatch into a wrapped
    # ColumnNativeBatch. No encode, no per-buffer copy. The fingerprint is not
    # needed in wrapped mode (it is recomputed when a contiguous body is
    # materialized); leave it 0.
    var schema = batch.schema.copy()
    var header = ColumnNativeBatchHeader(
        n_cols=UInt32(batch.num_columns()),
        row_count=UInt64(batch.num_rows()),
        schema_fingerprint=0,
        has_selection_vector=0,
        flags=0,
    )
    var columns = batch.take_columns()
    _ = batch^
    return ColumnNativeBatch.wrap_columns(header^, columns^, schema^)


def _record_batch_from_wrapped(
    var batch: ColumnNativeBatch,
) raises -> RecordBatch:
    """Move a WRAPPED batch's columns back into a RecordBatch (zero-copy)."""
    var schema = batch.schema_copy()
    var columns = batch^.take_columns_wrapped()
    # The row count is the columns' length, as `from_typed_columns_slab`
    # derives it.
    return RecordBatch.from_typed_columns_slab(schema^, columns^)


def record_batch_from_column_native(
    var batch: ColumnNativeBatch,
) raises -> RecordBatch:
    """Decode a ColumnNativeBatch back to a RecordBatch.

    Inverse of `column_native_from_record_batch`. A WRAPPED batch
    moves its columns straight back into a RecordBatch (zero-copy). A
    contiguous-body batch is restored via `THSPLCDecoder.decode_zerocopy` — the
    restored columns are Arc-clone borrowed slices over the body bytes (no
    memcpy), keeping the body pinned via the cloned Arc refcounts.

    A selection-bearing batch must be densified first
    (`ColumnNativeBatch.materialize_dense`); raises if a selection vector is
    present.
    """
    if batch.has_selection():
        raise Error(
            "record_batch_from_column_native: selection-vector batch must be"
            " densified first (materialize_dense)"
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
    densify substrate: a caller takes the un-filtered batch here, then gathers
    it through the selection indices.

    WRAPPED batches move their columns out (zero-copy); contiguous-body
    batches restore via `decode_zerocopy` (borrowed Arc-clone slices, no memcpy).
    For a dense batch (no selection) this is identical to
    `record_batch_from_column_native`.
    """
    if batch.is_wrapped():
        return _record_batch_from_wrapped(batch^)
    var schema = batch.schema_copy()
    var body = batch^.take_body()
    return THSPLCDecoder.decode_zerocopy(body^, schema^)
