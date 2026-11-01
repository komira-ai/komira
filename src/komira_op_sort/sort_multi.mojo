# =============================================================================
# Multi-key (lexicographic) sort of a RecordBatch
# =============================================================================
#
# Stable multi-column sort implemented via the classic "sort by the last key
# first, then stable-sort by earlier keys in reverse" trick. Each pass is a
# stable single-column sort on a numeric key column; because the sort is
# stable, rows that compare equal on a later key keep the order established
# by earlier passes. Total cost: O(K * N log N) for K keys.
#
# Both the PartitionBy sink and the sort sink use it.
#
# When there are two or more keys and every key is INT32 / INT64 / STRING,
# the K passes are replaced by one lexicographic pass (`sort_lex`).
# =============================================================================

from std.sys import size_of

from komira_arrow.record_batch import RecordBatch
from komira_arrow.column import Column
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_arrow.bitmap import Bitmap, read_bit_aligned_buffer
from komira_buffer.heap_region import HeapRegion
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.arrow_types import ArrowType
from komira_column_kernels.compiler_helpers import gather_batch_by_sort_indices

from .sort import sort_indices_int32, sort_indices_int64, sort_indices_float64
from .sort_string import sort_indices_string
from .sort_lex import sort_batch_lex
from .sort_nested import sort_indices_nested


def _dict_column_indices_as_int32(col: Column) raises -> PrimitiveArray[DType.int32]:
    """Build an Int32 PrimitiveArray view of a DICTIONARY Column's indices.

    PERF-CRITICAL: Dictionary columns store their int32 indices buffer
    directly in `_data` (see Column.from_dictionary). Sorting by those
    indices is semantically equivalent to grouping rows by dictionary
    entry, which is what the PartitionBy sink needs — and is ~10-20x
    faster than decoding to strings then comparing lexicographically.
    """
    comptime int32_size = size_of[Int32]()
    var total_elems = col._offset + col._length
    var data_bytes = total_elems * int32_size
    var data_buf = OwnedAlignedBuffer(max(data_bytes, 1))
    if data_bytes > 0:
        # Z.4c: bulk byte copy via origin-preserving view.
        data_buf.copy_from_view(col._data.view_range_ro(0, data_bytes))
    else:
        data_buf.set_length(0)

    return PrimitiveArray[DType.int32](
        data_buf^, col._length, Optional[Bitmap[HeapRegion]](None), 0, col._offset
    )


def sort_batch_by_keys(
    var batch: RecordBatch,
    key_names: List[String],
    descending: List[Bool],
) raises -> RecordBatch:
    """Stable multi-column sort of a RecordBatch.

    Sorts `batch` lexicographically by `key_names` (primary key first), with
    per-key ascending/descending direction from `descending`. Equal rows
    retain their original order (stable).

    Implementation: stable-sort by the LAST key first, then by the
    second-last, etc. Because each single-column pass is stable, rows that
    compare equal on a later key keep the order established by earlier
    passes. This yields a lexicographic order by (key_0, key_1, ..., key_{K-1})
    in O(K * N log N) time, the same order Arrow's `lexsort_to_indices`
    produces.

    Supported key column types: INT32, INT64, FLOAT64, BOOL, DICTIONARY,
    numeric-dict, STRING/BINARY and the nested types. Raises on unsupported
    types so the error surfaces at the sort site instead of producing silently
    wrong output.

    Args:
        batch: The input RecordBatch (consumed).
        key_names: Column names to sort by, primary key first.
        descending: Per-key sort direction flags. Must match len(key_names).

    Returns:
        The sorted RecordBatch.
    """
    if len(key_names) == 0 or batch.num_rows() <= 1:
        return batch^

    # PERF-CRITICAL: when there are 2+
    # sort keys and every key column is INT32 / INT64 / STRING, do the sort
    # in ONE lexicographic pass instead of K stable single-column passes (K
    # `as_primitive` deep copies + K sort allocations + K full-batch gathers
    # + per-comparison string memcmp on each STRING pass). STRING keys are
    # dict-rank encoded so the row comparison is pure Int64; when the encoded
    # ranks bit-pack into one Int64 (the common TPC-H ORDER BY shape) the
    # final sort is an O(N) radix sweep. DICTIONARY keys are deliberately
    # excluded: `sort_batch_by_keys` sorts DICTIONARY keys by their int32
    # indices (dict-order, not lex-order) to satisfy the PartitionBy
    # boundary-detection contract — routing them through the lex path would
    # change that observable order.
    if len(key_names) >= 2:
        var _all_lex_int_or_str = True
        for k in range(len(key_names)):
            var ki = batch.schema.column_index(key_names[k])
            var kt = batch.schema.field_arrow_type(ki)
            if not (
                kt == ArrowType.INT64
                or kt == ArrowType.INT32
                or kt == ArrowType.STRING
            ):
                _all_lex_int_or_str = False
                break
        if _all_lex_int_or_str:
            return sort_batch_lex(batch^, key_names, descending)

    var current = batch^
    # Iterate keys from last to first so the final pass is on the primary
    # key and its ordering dominates.
    for k in range(len(key_names) - 1, -1, -1):
        var key_name = key_names[k]
        var desc = descending[k]
        var key_idx = current.schema.column_index(key_name)
        ref key_col = current.column_at(key_idx)
        var sort_idx: PrimitiveArray[DType.int32]
        if (
            key_col.arrow_type == ArrowType.INT64
            # ⭐ THE TIMESTAMP UNITS, over the SAME signed-int64 comparator —
            # the multi-key twin of the arm in `sort_topn_sink`, which carries
            # the measured account. Fixed together because which sort runs is a
            # shape decision (one key vs several, TOP-N vs full), so closing one
            # leaves the same ORDER BY refusing under a different plan.
            or key_col.arrow_type == ArrowType.TIMESTAMP
            or key_col.arrow_type == ArrowType.TIMESTAMP_S
            or key_col.arrow_type == ArrowType.TIMESTAMP_MS
            or key_col.arrow_type == ArrowType.TIMESTAMP_US
            or key_col.arrow_type == ArrowType.TIMESTAMP_NS
        ):
            var arr = key_col.as_primitive[DType.int64]()
            sort_idx = sort_indices_int64(arr, desc)
        elif key_col.arrow_type == ArrowType.FLOAT64:
            var arr = key_col.as_primitive[DType.float64]()
            sort_idx = sort_indices_float64(arr, desc)
        elif key_col.arrow_type == ArrowType.INT32:
            var arr = key_col.as_primitive[DType.int32]()
            sort_idx = sort_indices_int32(arr, desc)
        elif key_col.is_numeric_dict():
            # A NUMERIC dict sort key must order by VALUE, not
            # code — the string-dict int32-index shortcut below is sound only
            # because equal string-dict codes group together and the dict order
            # is user-invisible for partition-by. A numeric key is value-ordered
            # (codes are NOT monotone in value, and may be int64-wide → the
            # int32 read MISREADS), so resolve to the flat logical column first
            # and sort by its real dtype.
            var flat = key_col.resolve_numeric_dict_to_flat()
            if flat.arrow_type == ArrowType.INT64:
                sort_idx = sort_indices_int64(
                    flat.as_primitive[DType.int64](), desc
                )
            elif flat.arrow_type == ArrowType.INT32:
                sort_idx = sort_indices_int32(
                    flat.as_primitive[DType.int32](), desc
                )
            elif flat.arrow_type == ArrowType.FLOAT64:
                sort_idx = sort_indices_float64(
                    flat.as_primitive[DType.float64](), desc
                )
            else:
                # FLOAT32 numeric-dict sort key: no `sort_indices_float32`
                # kernel exists — defined raise (out of scope), NOT a silent
                # misread. The numeric-dict producer (parquet sub-RG agg
                # decode) does not emit FLOAT32 sort keys today.
                raise Error(
                    "sort_multi: unsupported numeric-dict value dtype "
                    + String(flat.arrow_type)
                    + " for sort key '"
                    + key_name
                    + "'"
                )
        elif key_col.arrow_type == ArrowType.DICTIONARY:
            # PERF-CRITICAL: sort STRING dict columns (numeric dict handled
            # above) by their int32 indices rather than decoding to strings.
            # Rows with the same dictionary index are grouped together, which
            # is exactly what the PartitionBy sink needs for boundary
            # detection. The order of distinct dictionary entries is
            # implementation-defined (dict order rather than lex order),
            # matching the partition-by contract that only within-partition
            # ordering is user-visible.
            var arr = _dict_column_indices_as_int32(key_col)
            sort_idx = sort_indices_int32(arr, desc)
        elif key_col.arrow_type == ArrowType.BOOL:
            # BOOL: bit-packed, so no fixed-width comparator reads it. The
            # key is materialised as an Int32 rank and sorted by the stable
            # `sort_indices_int32`:
            #
            #     NULL -> -1      false -> 0      true -> 1
            #
            # The NULL rank puts NULLs first ASC and last DESC: the engine's
            # derived default placement (`nulls_first = not descending`),
            # the one a nullable STRING key gets from `sort_indices_string`.
            # `read_bit_aligned_buffer` takes a BIT index, `_offset + row`;
            # the validity bitmap is indexed the same way. The single-pass
            # lex path admits INT64/INT32/STRING only, so a BOOL key always
            # comes here.
            var n_rows = key_col._length
            var rank = PrimitiveArray[DType.int32].allocate(n_rows)
            var bit_base = key_col._offset
            for r in range(n_rows):
                var bi = bit_base + r
                if key_col._validity and not key_col._validity.value().test(bi):
                    rank.set(r, Int32(-1))
                elif read_bit_aligned_buffer(key_col._data, bi):
                    rank.set(r, Int32(1))
                # else: `allocate` zero-inits, so `false` is already 0.
            sort_idx = sort_indices_int32(rank, desc)
        elif key_col.arrow_type == ArrowType.STRING or key_col.arrow_type == ArrowType.BINARY:
            # STRING / BINARY: byte-wise lex-sort kernel from sort_string.
            # Operates on the Column directly so `_offset` is honored on
            # sliced batches (post-join, post-concat).
            sort_idx = sort_indices_string(key_col, desc)
        elif (
            key_col.arrow_type == ArrowType.STRUCT
            or key_col.arrow_type == ArrowType.LIST
            or key_col.arrow_type == ArrowType.UNION_SPARSE
            or key_col.arrow_type == ArrowType.UNION_DENSE
        ):
            # Nested-type sort key.  Dispatches to the type-erased nested kernel
            # in `sort_nested.mojo`.  MAP is intentionally NOT included
            # here -- `sort_indices_nested` raises with a clear message
            # for MAP (Arrow spec leaves Map ordering undefined).
            sort_idx = sort_indices_nested(key_col, desc)
        else:
            raise Error(
                "sort_batch_by_keys: unsupported sort key type "
                + String(key_col.arrow_type)
                + " for column '" + key_name + "'"
            )
        current = gather_batch_by_sort_indices(current, sort_idx)

    return current^
