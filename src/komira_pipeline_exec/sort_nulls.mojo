# =============================================================================
# sort_nulls -- a stable multi-key sort that honours NULLS FIRST / NULLS LAST
# =============================================================================
#
# `komira_op_sort.sort_batch_by_keys` is the sort of this package, but its
# kernels do not read a NULL placement: a numeric key is ordered by the value
# stored under a NULL slot, and a string key places its NULLs by direction.
# The plan states the placement of every key (`SortSinkData.nulls_first`, or
# nothing, which asks for the engine's default in `null_order_policy`), so this
# module hands the kernel a batch in which placement cannot matter:
#
#   * a key column without NULL goes in as it is;
#   * a key column with NULL goes in as two columns: an INT32 rank, ascending,
#     0 for the rows that sort first (the NULLs when NULLS FIRST, the valid
#     rows when NULLS LAST) and 1 for the others; then the key itself with
#     every NULL slot overwritten by one valid value of the column (a gather
#     whose NULL rows read the first valid row), in the key's direction. The
#     NULLs of one key all carry the same value, so they tie among themselves
#     and keep the input order (the kernel is stable);
#   * a key column that is all NULL carries no information and is dropped; a
#     key named twice is read once.
#
# The kernel sorts that key batch together with a row-number column (not a
# key); the sorted row numbers are the permutation, and the caller's batch is
# gathered by it. A batch with no NULL in any key column goes straight to the
# kernel.

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    SchemaBuilder,
)
from komira_buffer.heap_region import HeapRegion
from komira_column_kernels.compiler_helpers import (
    copy_column,
    gather_batch,
    project_batch_by_names,
)
from komira_op_sort.sort_multi import sort_batch_by_keys
from komira_plan_expr.null_order_policy import derived_nulls_first

comptime _ROW_COLUMN: String = "__komira_sort_row"


def resolve_nulls_first(
    n_keys: Int, nulls_first: List[Bool], descending: List[Bool], where_: String
) raises -> List[Bool]:
    """The placement of each key's NULLs: the plan's request verbatim, or the
    engine's default for every key when the plan asked for none. A request
    that does not list one flag per key is refused."""
    var out = List[Bool]()
    if len(nulls_first) == 0:
        for i in range(n_keys):
            out.append(derived_nulls_first(descending[i]))
        return out^
    if len(nulls_first) != n_keys:
        raise Error(
            where_
            + " lists "
            + String(len(nulls_first))
            + " NULL placements for "
            + String(n_keys)
            + " sort keys"
        )
    return nulls_first.copy()


def _rank_column(
    ref batch: RecordBatch, idx: Int, first_is_null: Bool
) raises -> Column[HeapRegion]:
    var n = batch.num_rows()
    var rank = PrimitiveArray[DType.int32].allocate(n)
    ref col = batch.column_at(idx)
    for r in range(n):
        var is_null = col.is_null_at(r)
        rank.set(r, Int32(0) if is_null == first_is_null else Int32(1))
    return Column.from_primitive[DType.int32](rank^)


def sort_batch_with_null_placement(
    var batch: RecordBatch,
    keys: List[String],
    descending: List[Bool],
    nulls_first: List[Bool],
) raises -> RecordBatch:
    """`batch` sorted by `keys` (primary first), stable among ties, each key's
    NULLs placed by `nulls_first` (one flag per key)."""
    var any_null = False
    for k in range(len(keys)):
        if batch.column_at(batch.schema.column_index(keys[k])).null_count() > 0:
            any_null = True
    if not any_null or batch.num_rows() <= 1:
        return sort_batch_by_keys(batch^, keys, descending)

    var n = batch.num_rows()
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    var key_names = List[String]()
    var key_desc = List[Bool]()
    var seen = List[String]()
    for k in range(len(keys)):
        var name = keys[k]
        var dup = False
        for j in range(len(seen)):
            if seen[j] == name:
                dup = True
        if dup:
            continue
        seen.append(name)
        var idx = batch.schema.column_index(name)
        if batch.column_at(idx).null_count() == 0:
            sb.add_field(batch.schema.field_at(idx))
            rb.add_column(copy_column(batch, idx))
            key_names.append(name)
            key_desc.append(descending[k])
            continue
        var first_valid = -1
        for r in range(n):
            if not batch.column_at(idx).is_null_at(r):
                first_valid = r
                break
        if first_valid < 0:
            continue  # all NULL: no row is ordered before another by it
        var rank_name = String("__komira_sort_nulls_") + String(k)
        sb.add_field(Field(rank_name, ArrowType.INT32, False))
        rb.add_column(_rank_column(batch, idx, nulls_first[k]))
        key_names.append(rank_name)
        key_desc.append(False)
        var fill = List[Int](capacity=n)
        for r in range(n):
            if batch.column_at(idx).is_null_at(r):
                fill.append(first_valid)
            else:
                fill.append(r)
        var names = List[String]()
        names.append(name)
        var filled = gather_batch(project_batch_by_names(batch, names), fill)
        sb.add_field(filled.schema.field_at(0))
        rb.add_column(copy_column(filled, 0))
        key_names.append(name)
        key_desc.append(descending[k])
    if len(key_names) == 0:
        return batch^  # every key is all NULL: every row ties
    var rows = PrimitiveArray[DType.int64].allocate(n)
    for r in range(n):
        rows.set(r, Int64(r))
    sb.add_field(Field(_ROW_COLUMN, ArrowType.INT64, False))
    rb.add_column(Column.from_primitive[DType.int64](rows^))
    var sorted_keys = sort_batch_by_keys(
        rb.build(sb.build()), key_names, key_desc
    )
    var order = List[Int](capacity=n)
    var sorted_rows = sorted_keys.column_at(
        sorted_keys.num_columns() - 1
    ).as_primitive[DType.int64]()
    for i in range(n):
        order.append(Int(sorted_rows.get(i)))
    return gather_batch(batch, order)
