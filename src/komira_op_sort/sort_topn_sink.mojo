# =============================================================================
# The sort and top-N sink kernels: sort one batch, optionally keep N rows
# =============================================================================
#
#   * `_execute_sort_sink`: full sort of a batch by `SortSinkData`.
#   * `_execute_topn_sink`: the first N rows in sort order, by
#     `TopNSinkData`. A bounded heap (`sort_topn_heap`, O(N log K)) when N is
#     much smaller than the batch and every key is one the heap compares;
#     otherwise a full sort and a slice.
#
# Single-key sorts go to the typed kernels directly; multi-key sorts go to
# `sort_multi.sort_batch_by_keys`. Both kernels refuse an empty key list.
#
# Null placement: these kernels do not read `nulls_first`. The routes they
# reach place nulls as `sort_multi` / `sort_string` do (first ascending, last
# descending, for the key types that read validity); the caller routes an
# explicit `nulls_first` request elsewhere.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema
from komira_column_kernels.batch_slice import _slice_batch_first_n
from komira_column_kernels.compiler_helpers import (
    gather_batch,
    gather_batch_by_sort_indices,
)
from komira_physical_plan.physical_plan import SortSinkData, TopNSinkData

from .sort import (
    sort_indices_float64,
    sort_indices_int128,
    sort_indices_int32,
    sort_indices_int64,
)
from .sort_multi import sort_batch_by_keys
from .sort_radix import radix_sort_int64
from .sort_string import sort_indices_string
from .sort_topn_heap import topn_heap_select


# The heap path runs when `limit < input_rows / TOPN_HEAP_RATIO`.
comptime TOPN_HEAP_RATIO: Int = 8

# PERF-CRITICAL: a single INT64 key at or above this many rows is radix-sorted
# (O(n)) instead of merge-sorted (O(n log n)): from here the radix's fixed
# 8-pass cost and sign-flip prologue are amortized.
comptime RADIX_SORT_ROW_THRESHOLD: Int = 500_000

# More sort keys than this skip the heap and take the full sort + slice.
comptime _MAX_HEAP_KEYS: Int = 8


def _sort_batch_single_key(
    var batch: RecordBatch,
    key_name: String,
    descending: Bool,
) raises -> RecordBatch:
    """Sort `batch` by one key column and gather it.

    Key types: INT32, INT64 and the TIMESTAMP units (signed int64 storage),
    FLOAT64 (NaN above +inf), STRING/BINARY, DECIMAL128. Another type
    raises."""
    var key_idx = batch.schema.column_index(key_name)
    ref key_col = batch.column_at(key_idx)

    var sort_idx: PrimitiveArray[DType.int32]
    if key_col.arrow_type == ArrowType.FLOAT64:
        sort_idx = sort_indices_float64(
            key_col.as_primitive[DType.float64](), descending
        )
    elif key_col.arrow_type == ArrowType.INT32:
        sort_idx = sort_indices_int32(
            key_col.as_primitive[DType.int32](), descending
        )
    elif (
        key_col.arrow_type == ArrowType.INT64
        # The TIMESTAMP units sort as the signed int64 they are stored as:
        # within one column every cell has the same unit, so tick order is
        # instant order. SIGNED order is what puts 1969 before 1970.
        or key_col.arrow_type == ArrowType.TIMESTAMP
        or key_col.arrow_type == ArrowType.TIMESTAMP_S
        or key_col.arrow_type == ArrowType.TIMESTAMP_MS
        or key_col.arrow_type == ArrowType.TIMESTAMP_US
        or key_col.arrow_type == ArrowType.TIMESTAMP_NS
    ):
        var arr = key_col.as_primitive[DType.int64]()
        if arr.length >= RADIX_SORT_ROW_THRESHOLD:
            # The radix sort is ascending only; DESC reverses it.
            sort_idx = radix_sort_int64(arr)
            if descending:
                _reverse_int32_indices(sort_idx)
        else:
            sort_idx = sort_indices_int64(arr, descending)
    elif (
        key_col.arrow_type == ArrowType.STRING
        or key_col.arrow_type == ArrowType.BINARY
    ):
        sort_idx = sort_indices_string(key_col, descending)
    elif key_col.arrow_type == ArrowType.DECIMAL128:
        # Signed int128 order of the unscaled values is decimal order within
        # one (uniform-scale) column.
        var darr = key_col.as_decimal128()
        var vals = List[Scalar[DType.int128]](capacity=darr.length)
        for r in range(darr.length):
            vals.append(darr.get_i128(r))
        sort_idx = sort_indices_int128(
            PrimitiveArray[DType.int128].from_list(vals), descending
        )
    else:
        raise Error(
            "_sort_batch_single_key: unsupported sort key type "
            + String(key_col.arrow_type)
            + " for column '" + key_name + "'"
        )

    return gather_batch_by_sort_indices(batch, sort_idx)


@always_inline
def _reverse_int32_indices(mut indices: PrimitiveArray[DType.int32]):
    """In-place reverse of an Int32 permutation index array."""
    var lo = 0
    var hi = indices.length - 1
    while lo < hi:
        var tmp = indices.get_typed[Scalar[DType.int32]](lo)
        indices.set_typed[Scalar[DType.int32]](
            lo, indices.get_typed[Scalar[DType.int32]](hi)
        )
        indices.set_typed[Scalar[DType.int32]](hi, tmp)
        lo += 1
        hi -= 1


def _refuse_zero_sort_keys(num_keys: Int, node: String) raises:
    """A sort with no keys has no answer: raise a catchable `Error`.

    Both kernels pick their multi-key arm with `len(keys) > 1`, so zero keys
    would fall to the single-key arm's `keys[0]`, which aborts the process
    rather than raising. It is checked before any early return: "nothing to
    order by" is a property of the plan, not of how many rows arrived.
    A plan arriving as bytes cannot get here (the plan wire refuses empty
    sort keys at admission, `PLAN_WIRE_EMPTY_SORT_KEYS`); this protects an
    in-process caller."""
    if num_keys != 0:
        return
    raise Error(
        "sort_topn_sink: " + node + " was given ZERO sort keys. An ordering"
        " with nothing to order by has no answer to return, so this kernel"
        " refuses rather than guessing one. A plan that arrived as bytes is"
        " refused at admission as PLAN_WIRE_EMPTY_SORT_KEYS; reaching this"
        " means a plan built in this process carries an empty key list."
    )


def _execute_sort_sink(
    var batch: RecordBatch,
    sort_data: SortSinkData,
) raises -> RecordBatch:
    """Full sort of `batch` by `sort_data`'s keys and directions.

    PERF-CRITICAL -- DO NOT DELETE: the serial full-sort kernel the sort sink
    ends in. Single key: the typed kernels. Several keys:
    `sort_batch_by_keys`."""
    _refuse_zero_sort_keys(len(sort_data.sort_keys), String("SORT"))
    if batch.num_rows() <= 1:
        return batch^
    if len(sort_data.sort_keys) > 1:
        return sort_batch_by_keys(
            batch^, sort_data.sort_keys, sort_data.descending
        )
    return _sort_batch_single_key(
        batch^, sort_data.sort_keys[0], sort_data.descending[0]
    )


def _heap_can_order_key_type(at: ArrowType) -> Bool:
    """Has `sort_topn_heap` a comparator arm for a key of type `at`?

    This set is a READ of `_HeapKeys`: INT64, FLOAT64, INT32, STRING. Widen
    both together or neither. BINARY would compare correctly with the STRING
    arm but has no top-K test against an oracle, so it takes the full-sort
    arm."""
    return (
        at == ArrowType.INT64
        or at == ArrowType.FLOAT64
        or at == ArrowType.INT32
        or at == ArrowType.STRING
    )


def _heap_can_order_all_keys(
    batch: RecordBatch, sort_keys: List[String]
) raises -> Bool:
    """True iff EVERY sort key is one the heap can compare (the comparator is
    lexicographic over all keys, so one unsupported key anywhere
    disqualifies), and every STRING key is heap-safe
    (`_string_key_is_heap_safe`)."""
    for i in range(len(sort_keys)):
        var col_idx = batch.schema.column_index(sort_keys[i])
        var kt = batch.schema.field_arrow_type(col_idx)
        if not _heap_can_order_key_type(kt):
            return False
        if kt == ArrowType.STRING and not _string_key_is_heap_safe(
            batch, col_idx
        ):
            return False
    return True


def _string_key_is_heap_safe(batch: RecordBatch, col_idx: Int) raises -> Bool:
    """True iff this STRING key may go to the heap's STRING arm.

    (1) The column's PHYSICAL type must be STRING, not just the schema's: a
        DICTIONARY column under a STRING field has (indices, dict data), not
        (offsets, data), and the heap would read the wrong buffers.
    (2) No NULLs. The heap reads values, not validity, and a NULL STRING slot
        is an empty byte range: it would sort as `''` instead of where
        `sort_indices_string` puts NULLs (and on DESC those two differ).

    The NULL test is a recount, not `null_count()` (that field can be stale
    after some Column constructions). It runs only in the heap regime."""
    ref col = batch.column_at(col_idx)
    if col.arrow_type != ArrowType.STRING:
        return False
    if not col.has_validity_buffer():
        return True
    for r in range(col.length()):
        if col.is_null_at(r):
            return False
    return True


# =============================================================================
# The deterministic tie-break: one definition, shared by every caller
# =============================================================================
#
# A TopN over a parallel hash aggregate sees the groups in a different order
# on each run. When the ORDER BY keys tie across the LIMIT cut, which rows
# survive then changes between runs. Appending the remaining output columns
# as ascending keys makes the order total. Two selections that must agree on
# the same K rows (a bounded aggregate pre-pass and the TopN above it) must
# derive this list the same way, so it is defined once, here.


def append_deterministic_tiebreak_schema(
    sch: Schema,
    mut keys: List[String],
    mut descending: List[Bool],
) raises:
    """Append every INT64 / INT32 / FLOAT64 column of `sch` that is not
    already a key, in schema order, as an ascending key. Needs no batch, so a
    plan can derive the list before the data exists.

    Only those three types are appended, and that is a performance bound:
    a STRING key would move a top-K off the bounded heap to a full sort just
    to break ties most queries do not have. A top-K whose only remaining
    column is a STRING therefore still has no total order."""
    for c in range(sch.num_columns()):
        var name = sch.field_name(c)
        var already = False
        for k in range(len(keys)):
            if keys[k] == name:
                already = True
                break
        if already:
            continue
        var at = sch.field_arrow_type(c)
        if (
            at == ArrowType.INT64
            or at == ArrowType.INT32
            or at == ArrowType.FLOAT64
        ):
            keys.append(name)
            descending.append(False)


def append_deterministic_tiebreak(
    batch: RecordBatch,
    mut keys: List[String],
    mut descending: List[Bool],
) raises:
    """`append_deterministic_tiebreak_schema` over `batch.schema`."""
    append_deterministic_tiebreak_schema(batch.schema, keys, descending)


def _execute_topn_sink(
    var batch: RecordBatch,
    topn_data: TopNSinkData,
) raises -> RecordBatch:
    """The first `topn_data.n` rows of `batch` in sort order.

    PERF-CRITICAL -- DO NOT DELETE: the top-N kernel the top-N sink ends in.

    `n == 0` (LIMIT 0) has a defined answer, the empty batch with the input
    schema, and gets it. (An empty key list has none and is refused.) The
    bounded heap runs when `n` is much smaller than the batch and every key
    is heap-comparable; otherwise the batch is fully sorted and sliced."""
    _refuse_zero_sort_keys(len(topn_data.sort_keys), String("TOP N"))

    var num_rows = batch.num_rows()
    var k = topn_data.n
    if k <= 0:
        return _slice_batch_first_n(batch, 0)
    if num_rows <= 1:
        return batch^

    if k >= num_rows:
        if len(topn_data.sort_keys) > 1:
            return sort_batch_by_keys(
                batch^, topn_data.sort_keys, topn_data.descending
            )
        return _sort_batch_single_key(
            batch^, topn_data.sort_keys[0], topn_data.descending[0]
        )

    # PERF-CRITICAL: the heap is O(N log K). A composite key with a STRING in
    # it (`ORDER BY user_id, search_phrase LIMIT 10`) on the full-sort arm
    # does not finish at ClickBench scale.
    if (
        num_rows > k * TOPN_HEAP_RATIO
        and len(topn_data.sort_keys) <= _MAX_HEAP_KEYS
        and _heap_can_order_all_keys(batch, topn_data.sort_keys)
    ):
        var rows = topn_heap_select(batch, topn_data)
        return gather_batch(batch, rows)

    var sorted_batch: RecordBatch
    if len(topn_data.sort_keys) > 1:
        sorted_batch = sort_batch_by_keys(
            batch^, topn_data.sort_keys, topn_data.descending
        )
    else:
        sorted_batch = _sort_batch_single_key(
            batch^, topn_data.sort_keys[0], topn_data.descending[0]
        )
    return _slice_batch_first_n(sorted_batch, k)
