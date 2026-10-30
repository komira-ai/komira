# =============================================================================
# sort_nulls -- a stable multi-key sort that honours NULLS FIRST / NULLS LAST
# =============================================================================
#
# `komira_op_sort.sort_batch_by_keys` is the sort of this package, but it does
# not do what the plan states for every key:
#
#   * its kernels do not read a NULL placement: a numeric key is ordered by the
#     value stored under a NULL slot, and a string key places its NULLs by
#     direction;
#   * a DICTIONARY key is ordered by dictionary INDEX, not by value, which is
#     wrong whenever a dictionary is not sorted;
#   * it raises for a key type it does not order (DECIMAL, DATE, FLOAT32 ...).
#
# So the sort hands the kernel a batch of its own making, the key batch, whose
# columns carry internal names ("r0", "v0", "r1", ... and "row"; the key batch
# holds nothing else, so no user column name can collide), one or two columns
# for each distinct key:
#
#   * a STRING dictionary key is decoded into a flat STRING column, a numeric
#     dictionary key into its flat values;
#   * a key column without NULL goes in as a value column;
#   * a key column with NULL goes in as an INT32 rank, ascending, 0 for the
#     rows that sort first (the NULLs when NULLS FIRST, the valid rows when
#     NULLS LAST) and 1 for the others, then the value column with every NULL
#     slot overwritten by one valid value of the column (a gather whose NULL
#     rows read the first valid row), in the key's direction. The NULLs of one
#     key all carry the same value, so they tie among themselves and keep the
#     input order (the kernel is stable);
#   * a key column that is all NULL carries no information and is dropped; a
#     key named twice is read once.
#
# The kernel sorts the key batch together with a row-number column (not a key);
# the sorted row numbers are the permutation, and the caller's batch is
# gathered by it. A batch with no NULL and no dictionary in its key columns
# goes straight to the kernel.
#
# `check_sort_keys` names the keys that cannot be sorted (a key that is not a
# column, a type outside `sort_key_supported`) from a schema alone, so a sink
# refuses them when it is built. `sort_scratch_bytes` is the bound the sink
# draws from the memory pool for the key batch and the kernel's temporaries.

from std.collections import Optional

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    Schema,
    SchemaBuilder,
)
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_column_kernels.compiler_helpers import (
    column_buffer_bytes,
    copy_column,
    gather_batch,
)
from komira_op_sort.sort_multi import sort_batch_by_keys
from komira_plan_expr.null_order_policy import derived_nulls_first


def sort_key_supported(t: ArrowType) -> Bool:
    """Whether a column of type `t` can be a sort key: the types the kernel
    orders by value, and DICTIONARY (decoded first)."""
    return (
        t == ArrowType.INT32
        or t == ArrowType.INT64
        or t == ArrowType.FLOAT64
        or t == ArrowType.BOOL
        or t == ArrowType.STRING
        or t == ArrowType.BINARY
        or t == ArrowType.TIMESTAMP
        or t == ArrowType.TIMESTAMP_S
        or t == ArrowType.TIMESTAMP_MS
        or t == ArrowType.TIMESTAMP_US
        or t == ArrowType.TIMESTAMP_NS
        or t == ArrowType.DICTIONARY
    )


def check_sort_keys(
    ref schema: Schema, keys: List[String], where_: String
) raises:
    """Refuse, by name, a key that is not a column of `schema` or whose type
    cannot be sorted."""
    for k in range(len(keys)):
        var found = -1
        for c in range(schema.num_columns()):
            if schema.field_name(c) == keys[k]:
                found = c
        if found < 0:
            raise Error(
                where_
                + " sorts by '"
                + keys[k]
                + "', which is not a column of its input"
            )
        var t = schema.field_arrow_type(found)
        if not sort_key_supported(t):
            raise Error(
                where_
                + " sorts by '"
                + keys[k]
                + "', of unsupported sort key type "
                + String(t)
            )


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


def sort_scratch_bytes(ref batch: RecordBatch, keys: List[String]) raises -> Int:
    """An upper bound on the memory the sort holds besides the batch and its
    sorted copy: the key batch, which the kernel gathers once per pass (two
    copies live at once), a row number (8 bytes), the sort indices (4) and the
    two index lists of the gathers (8 each) per row. A key column counts its
    buffers once, twice when it has NULLs (the overwritten copy), plus a
    4-byte rank per row; a dictionary key counts its decoded size at the
    longest entry. A bound, not a measurement."""
    var n = batch.num_rows()
    var key_batch = 8 * n
    var seen = List[String]()
    for k in range(len(keys)):
        var dup = False
        for j in range(len(seen)):
            if seen[j] == keys[k]:
                dup = True
        if dup:
            continue
        seen.append(keys[k])
        var idx = batch.schema.column_index(keys[k])
        ref col = batch.column_at(idx)
        var bytes = column_buffer_bytes(batch, idx)
        if col.arrow_type == ArrowType.DICTIONARY and col.is_string_dict():
            var longest = 0
            for c in range(col.dict_size()):
                longest = max(longest, col.string_dict_value_at(c).len())
            bytes = n * (longest + 4) + 4
        elif col.arrow_type == ArrowType.DICTIONARY:
            bytes = n * 8
        key_batch += bytes
        if col.null_count() > 0:
            key_batch += bytes + 4 * n
    return 2 * key_batch + 20 * n


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


def _decode_string_dict(ref col: Column[HeapRegion]) raises -> Column[HeapRegion]:
    """The values of a STRING dictionary column as a flat STRING column. A
    NULL row reads as the empty string (its code is never read); the caller
    carries the NULLs in a rank column."""
    var n = col.length()
    var values = List[List[UInt8]](capacity=n)
    for r in range(n):
        var bytes = List[UInt8]()
        if not col.is_null_at(r):
            var view = col.string_dict_value_at(col.string_dict_code_at(r))
            for i in range(view.len()):
                bytes.append(view.read_u8_at(i))
        values.append(bytes^)
    return Column.from_string(StringArray.from_byte_lists(values))


def _value_column(
    ref batch: RecordBatch, idx: Int
) raises -> Column[HeapRegion]:
    """The column to order by for key column `idx`: a dictionary decoded,
    anything else copied."""
    ref col = batch.column_at(idx)
    if col.arrow_type == ArrowType.DICTIONARY:
        if col.is_numeric_dict():
            return col.resolve_numeric_dict_to_flat()
        return _decode_string_dict(col)
    return copy_column(batch, idx)


def sort_batch_with_null_placement(
    var batch: RecordBatch,
    keys: List[String],
    descending: List[Bool],
    nulls_first: List[Bool],
) raises -> RecordBatch:
    """`batch` sorted by `keys` (primary first), stable among ties, each key's
    NULLs placed by `nulls_first` (one flag per key)."""
    check_sort_keys(batch.schema, keys, "komira_pipeline_exec: the sort")
    var plain = True
    for k in range(len(keys)):
        ref col = batch.column_at(batch.schema.column_index(keys[k]))
        if col.null_count() > 0 or col.arrow_type == ArrowType.DICTIONARY:
            plain = False
    if plain or batch.num_rows() <= 1:
        return sort_batch_by_keys(batch^, keys, descending)

    var n = batch.num_rows()
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    var key_names = List[String]()
    var key_desc = List[Bool]()
    var seen = List[String]()
    var width = 0  # columns added to the key batch so far
    for k in range(len(keys)):
        var dup = False
        for j in range(len(seen)):
            if seen[j] == keys[k]:
                dup = True
        if dup:
            continue
        seen.append(keys[k])
        var idx = batch.schema.column_index(keys[k])
        var has_nulls = batch.column_at(idx).null_count() > 0
        var first_valid = -1
        if has_nulls:
            for r in range(n):
                if not batch.column_at(idx).is_null_at(r):
                    first_valid = r
                    break
            if first_valid < 0:
                continue  # all NULL: no row is ordered before another by it
        var vname = String("v") + String(k)
        var vcol = _value_column(batch, idx)
        var vfield: Field
        if batch.column_at(idx).arrow_type == ArrowType.DICTIONARY:
            vfield = Field(vname, vcol.arrow_type, True)
        else:
            vfield = batch.schema.field_at(idx)
            vfield.name = vname
        if has_nulls:
            var rname = String("r") + String(k)
            sb.add_field(Field(rname, ArrowType.INT32, False))
            rb.add_column(_rank_column(batch, idx, nulls_first[k]))
            key_names.append(rname)
            key_desc.append(False)
            width += 1
            # One valid value for every NULL slot: gather the value column
            # with the NULL rows reading `first_valid`.
            var fill = List[Int](capacity=n)
            for r in range(n):
                if batch.column_at(idx).is_null_at(r):
                    fill.append(first_valid)
                else:
                    fill.append(r)
            var one = RecordBatchBuilder()
            var one_schema = SchemaBuilder()
            one_schema.add_field(vfield)
            one.add_column(vcol^)
            var filled = gather_batch(one.build(one_schema.build()), fill)
            sb.add_field(filled.schema.field_at(0))
            rb.add_column(copy_column(filled, 0))
        else:
            sb.add_field(vfield)
            rb.add_column(vcol^)
        key_names.append(vname)
        key_desc.append(descending[k])
        width += 1
    if len(key_names) == 0:
        return batch^  # every key is all NULL: every row ties
    var rows = PrimitiveArray[DType.int64].allocate(n)
    for r in range(n):
        rows.set(r, Int64(r))
    sb.add_field(Field("row", ArrowType.INT64, False))
    rb.add_column(Column.from_primitive[DType.int64](rows^))
    var sorted_keys = sort_batch_by_keys(
        rb.build(sb.build()), key_names, key_desc
    )
    var order = List[Int](capacity=n)
    var sorted_rows = sorted_keys.column_at(width).as_primitive[DType.int64]()
    for i in range(n):
        order.append(Int(sorted_rows.get(i)))
    return gather_batch(batch, order)
