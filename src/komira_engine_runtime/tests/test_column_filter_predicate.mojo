# =============================================================================
# test_column_filter_predicate.mojo: filter_record_batch_via_predicate and
# filter_column_native_via_predicate.
# =============================================================================
#
# What each test proves, and the defect it catches:
#
#   * test_keeps_matching_rows_in_order: an int64 + string batch filtered by
#     `a > 3` keeps exactly rows 3..5, every column gathered by the same
#     indices, in input order, schema unchanged. Catches a gather of the wrong
#     rows, a column gathered by another column's indices, or a reordered
#     schema.
#   * test_all_rows_pass and test_no_rows_pass: the all-survive short-circuit
#     returns every row unchanged; a predicate nothing satisfies returns a
#     zero-row batch with the input schema. Catches an off-by-one in the
#     short-circuit (for example `is_all` misread as "any").
#   * test_null_rows_are_dropped: NULL rows of a nullable column never pass
#     `a > 0`, even though their data slot holds a value that would. Catches a
#     filter that reads raw data bytes and ignores validity.
#   * test_numeric_dictionary_is_resolved: a numeric DICTIONARY column is
#     filtered on its values (not its codes) and comes back flat INT64.
#     Planted mutant: deleting `_resolve_numeric_dict_cols_to_flat` from
#     `filter_record_batch_via_predicate` makes the bridge refuse the column
#     and this test raise.
#   * test_string_dictionary_is_refused_by_name: a string DICTIONARY column is
#     refused with an error naming the column. Catches a silent misread of the
#     codes as values.
#   * test_nested_column_is_refused_by_name: a LIST column is refused by the
#     bridge with an error naming the column. Catches a bridge that wraps a
#     nested column THSPLC has no layout for.
#   * test_column_native_entry_point: the ColumnNativeBatch entry point returns
#     a dense batch (no selection vector) of the surviving rows.
#   * test_nullable_columns_gathered_at_scattered_rows: nullable string and
#     float64 columns and a boolean column, none of them the predicate column,
#     are gathered at non-contiguous surviving rows with values and NULL
#     positions intact. Catches a gather that drops or shifts a validity bit
#     or a string offset when survivors are not a prefix or a run.
#   * test_sliced_input_is_filtered_by_logical_rows: columns that are zero-copy
#     slices (non-zero offset) filter on their logical rows. Catches a gather
#     that reads from the buffer start instead of the slice offset.
#   * test_all_pass_native_batch_keeps_nulls: the all-survive result of the
#     ColumnNativeBatch entry point keeps the validity of its columns.
# =============================================================================

from std.sys import size_of
from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.column import Column
from komira_arrow.list_array import ListArray
from komira_arrow.dictionary_array import StringDictionaryArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_collections.slab import Slab
from komira_plan_expr.col_expr import col

from komira_engine_runtime.column_filter_predicate import (
    filter_column_native_via_predicate,
    filter_record_batch_via_predicate,
)
from komira_engine_runtime.spill.column_native_shims import (
    column_native_from_record_batch,
    record_batch_from_column_native,
)


# -----------------------------------------------------------------------------
# Fixtures
# -----------------------------------------------------------------------------


def _i64(values: List[Int]) -> PrimitiveArray[DType.int64]:
    var l = List[Scalar[DType.int64]]()
    for i in range(len(values)):
        l.append(Int64(values[i]))
    return PrimitiveArray[DType.int64].from_list(l)


def _i32(values: List[Int]) -> PrimitiveArray[DType.int32]:
    var l = List[Scalar[DType.int32]]()
    for i in range(len(values)):
        l.append(Int32(values[i]))
    return PrimitiveArray[DType.int32].from_list(l)


def _strings(values: List[String]) raises -> StringArray[HeapRegion]:
    return StringArray.from_strings(values)


def _schema(names: List[String], types: List[ArrowType], nullable: Bool) -> Schema:
    var sb = SchemaBuilder()
    for i in range(len(names)):
        sb.add_field(Field(names[i], types[i], nullable))
    return sb.build()


def _int_string_batch() raises -> RecordBatch:
    """a: 1..6; s: "r0".."r5"."""
    var cols = Slab[Column[HeapRegion]].create(2)
    cols.append(Column.from_primitive[DType.int64](_i64([1, 2, 3, 4, 5, 6])))
    cols.append(
        Column.from_string(
            _strings(["r0", "r1", "r2", "r3", "r4", "r5"])
        )
    )
    return RecordBatch.from_typed_columns_slab(
        _schema(["a", "s"], [ArrowType.INT64, ArrowType.STRING], False), cols^
    )


def _nullable_i64(values: List[Int], null_rows: List[Int]) raises -> PrimitiveArray[DType.int64]:
    """A nullable int64 array; the data slot of a NULL row still holds its
    value from `values`."""
    var n = len(values)
    var buf = OwnedAlignedBuffer(max(n * size_of[Int64](), 1))
    var p = buf.view_typed_ro[DType.int64]()
    for i in range(n):
        p[i] = Int64(values[i])
    buf.set_length(Int64(n * size_of[Int64]()))
    var bm = Bitmap.create_all_valid(n)
    for k in range(len(null_rows)):
        bm.clear(null_rows[k])
    return PrimitiveArray[DType.int64](buf^, n, Optional(bm^), len(null_rows), 0)


def _ints_of(batch: RecordBatch, c: Int) raises -> List[Int]:
    var arr = batch.column_at(c).as_primitive[DType.int64]()
    var out = List[Int]()
    for i in range(arr.length):
        out.append(Int(arr.get(i)))
    return out^


def _strings_of(batch: RecordBatch, c: Int) raises -> List[String]:
    var arr = batch.column_at(c).as_string()
    var out = List[String]()
    for i in range(arr.length):
        out.append(arr.get(i))
    return out^


def _assert_ints(got: List[Int], want: List[Int], label: String) raises:
    assert_equal(len(got), len(want), label + ": length")
    for i in range(len(want)):
        assert_equal(got[i], want[i], label + ": row " + String(i))


def _assert_strings(got: List[String], want: List[String], label: String) raises:
    assert_equal(len(got), len(want), label + ": length")
    for i in range(len(want)):
        assert_equal(got[i], want[i], label + ": row " + String(i))


# -----------------------------------------------------------------------------
# Tests
# -----------------------------------------------------------------------------


def test_keeps_matching_rows_in_order() raises:
    var out = filter_record_batch_via_predicate(_int_string_batch(), col("a") > 3)
    assert_equal(out.num_rows(), 3)
    assert_equal(out.num_columns(), 2)
    assert_equal(out.schema.field_at(0).name, "a")
    assert_equal(out.schema.field_at(1).name, "s")
    _assert_ints(_ints_of(out, 0), [4, 5, 6], "a")
    _assert_strings(_strings_of(out, 1), ["r3", "r4", "r5"], "s")


def test_all_rows_pass() raises:
    var out = filter_record_batch_via_predicate(_int_string_batch(), col("a") >= 1)
    assert_equal(out.num_rows(), 6)
    _assert_ints(_ints_of(out, 0), [1, 2, 3, 4, 5, 6], "a")
    _assert_strings(
        _strings_of(out, 1), ["r0", "r1", "r2", "r3", "r4", "r5"], "s"
    )


def test_no_rows_pass() raises:
    var out = filter_record_batch_via_predicate(_int_string_batch(), col("a") > 6)
    assert_equal(out.num_rows(), 0)
    assert_equal(out.num_columns(), 2)
    assert_true(out.schema.field_arrow_type(0) == ArrowType.INT64)
    assert_true(out.schema.field_arrow_type(1) == ArrowType.STRING)


def test_null_rows_are_dropped() raises:
    # Rows 1 and 3 are NULL; their data slots hold 50 and 70, which pass > 0.
    var cols = Slab[Column[HeapRegion]].create(1)
    cols.append(
        Column.from_primitive[DType.int64](
            _nullable_i64([10, 50, -5, 70, 20], [1, 3])
        )
    )
    var batch = RecordBatch.from_typed_columns_slab(
        _schema(["a"], [ArrowType.INT64], True), cols^
    )
    var out = filter_record_batch_via_predicate(batch^, col("a") > 0)
    _assert_ints(_ints_of(out, 0), [10, 20], "a")


def test_numeric_dictionary_is_resolved() raises:
    # Codes [0, 1, 2, 1, 0] over the dictionary [100, 5, 42]: values
    # 100, 5, 42, 5, 100. `x > 10` keeps rows 0, 2, 4. Filtering the codes
    # instead of the values would keep none (every code is <= 2).
    var entries = List[Int64]()
    entries.append(100)
    entries.append(5)
    entries.append(42)
    var cols = Slab[Column[HeapRegion]].create(1)
    cols.append(
        Column.from_numeric_dict[DType.int32, DType.int64](
            _i32([0, 1, 2, 1, 0]), entries^
        )
    )
    var batch = RecordBatch.from_typed_columns_slab(
        _schema(["x"], [ArrowType.INT64], False), cols^
    )
    assert_true(batch.column_at(0).is_numeric_dict())
    var out = filter_record_batch_via_predicate(batch^, col("x") > 10)
    assert_false(out.column_at(0).arrow_type == ArrowType.DICTIONARY)
    _assert_ints(_ints_of(out, 0), [100, 42, 100], "x")


def test_string_dictionary_is_refused_by_name() raises:
    var dict_values = _strings(["lo", "hi"])
    var sda = StringDictionaryArray.from_parts(_i32([0, 1, 1]), dict_values^)
    var cols = Slab[Column[HeapRegion]].create(2)
    cols.append(Column.from_primitive[DType.int64](_i64([1, 2, 3])))
    cols.append(Column.from_dictionary(sda))
    var batch = RecordBatch.from_typed_columns_slab(
        _schema(["a", "d"], [ArrowType.INT64, ArrowType.STRING], False), cols^
    )
    with assert_raises(contains="column 1 has type"):
        _ = filter_record_batch_via_predicate(batch^, col("a") > 1)


def test_nested_column_is_refused_by_name() raises:
    var lists = List[List[Int]]()
    lists.append([1])
    lists.append([2, 3])
    lists.append([])
    var cols = Slab[Column[HeapRegion]].create(2)
    cols.append(Column.from_primitive[DType.int64](_i64([1, 2, 3])))
    cols.append(Column.from_list(ListArray.from_int_lists(lists)))
    var batch = RecordBatch.from_typed_columns_slab(
        _schema(["a", "l"], [ArrowType.INT64, ArrowType.LIST], False), cols^
    )
    with assert_raises(contains="column 1 has type"):
        _ = column_native_from_record_batch(batch^)


def test_column_native_entry_point() raises:
    var native = column_native_from_record_batch(_int_string_batch())
    var filtered = filter_column_native_via_predicate(native^, col("a") <= 2)
    assert_false(filtered.has_selection())
    assert_equal(filtered.num_rows(), 2)
    var back = record_batch_from_column_native(filtered^)
    _assert_ints(_ints_of(back, 0), [1, 2], "a")
    _assert_strings(_strings_of(back, 1), ["r0", "r1"], "s")


def _f64(values: List[Float64]) -> PrimitiveArray[DType.float64]:
    var l = List[Scalar[DType.float64]]()
    for i in range(len(values)):
        l.append(values[i])
    return PrimitiveArray[DType.float64].from_list(l)


def _nullable_f64(
    values: List[Float64], null_rows: List[Int]
) raises -> PrimitiveArray[DType.float64]:
    var n = len(values)
    var buf = OwnedAlignedBuffer(max(n * size_of[Float64](), 1))
    var p = buf.view_typed_ro[DType.float64]()
    for i in range(n):
        p[i] = values[i]
    buf.set_length(Int64(n * size_of[Float64]()))
    var bm = Bitmap.create_all_valid(n)
    for k in range(len(null_rows)):
        bm.clear(null_rows[k])
    return PrimitiveArray[DType.float64](buf^, n, Optional(bm^), len(null_rows), 0)


def _bools(values: List[Bool]) raises -> BooleanArray:
    var bm = Bitmap.create_all_valid(len(values))
    for i in range(len(values)):
        if not values[i]:
            bm.clear(i)
    return BooleanArray.from_bitmap(bm^)


def _mixed_batch() raises -> RecordBatch:
    """a: int64 [5,1,7,2,9,3,8,4]; s: nullable string "s0".."s7" with NULL at
    rows 2, 3, 6; f: nullable float64 0.5.. with NULL at rows 0, 4; b: bool
    [T,F,F,T,T,F,F,T]."""
    var names = List[String]()
    var valid = List[Bool]()
    for i in range(8):
        names.append("s" + String(i))
        valid.append(not (i == 2 or i == 3 or i == 6))
    var fv = List[Float64]()
    for i in range(8):
        fv.append(Float64(i) + 0.5)
    var cols = Slab[Column[HeapRegion]].create(4)
    cols.append(Column.from_primitive[DType.int64](_i64([5, 1, 7, 2, 9, 3, 8, 4])))
    cols.append(Column.from_string(StringArray.from_strings_with_validity(names, valid)))
    cols.append(Column.from_primitive[DType.float64](_nullable_f64(fv, [0, 4])))
    cols.append(
        Column.from_boolean(
            _bools([True, False, False, True, True, False, False, True])
        )
    )
    return RecordBatch.from_typed_columns_slab(
        _schema(
            ["a", "s", "f", "b"],
            [ArrowType.INT64, ArrowType.STRING, ArrowType.FLOAT64, ArrowType.BOOL],
            True,
        ),
        cols^,
    )


def _assert_mixed_survivors(got: RecordBatch) raises:
    """Rows 0, 2, 4, 6 of `_mixed_batch` (a > 4)."""
    assert_equal(got.num_rows(), 4)
    _assert_ints(_ints_of(got, 0), [5, 7, 9, 8], "a")
    ref s = got.column_at(1)
    var s_arr = s.as_string()
    assert_false(s.is_null_at(0))
    assert_true(s.is_null_at(1))
    assert_false(s.is_null_at(2))
    assert_true(s.is_null_at(3))
    assert_equal(s_arr.get(0), "s0")
    assert_equal(s_arr.get(2), "s4")
    ref f = got.column_at(2)
    var f_arr = f.as_primitive[DType.float64]()
    assert_true(f.is_null_at(0))
    assert_false(f.is_null_at(1))
    assert_true(f.is_null_at(2))
    assert_false(f.is_null_at(3))
    assert_equal(f_arr.get(1), 2.5)
    assert_equal(f_arr.get(3), 6.5)
    var b = got.column_at(3).as_boolean()
    assert_true(b.get(0))
    assert_false(b.get(1))
    assert_true(b.get(2))
    assert_false(b.get(3))


def test_nullable_columns_gathered_at_scattered_rows() raises:
    var out = filter_record_batch_via_predicate(_mixed_batch(), col("a") > 4)
    _assert_mixed_survivors(out)


def test_sliced_input_is_filtered_by_logical_rows() raises:
    # Logical rows are 2..6 of each column: a = [7,2,9,3,8], f = [12..16];
    # a > 4 keeps logical rows 0, 2, 4. (Only fixed-width columns slice
    # zero-copy; Column.slice refuses string and boolean.)
    var fv = List[Float64]()
    for i in range(8):
        fv.append(Float64(10 + i))
    var cols = Slab[Column[HeapRegion]].create(2)
    cols.append(
        Column.from_primitive[DType.int64](_i64([5, 1, 7, 2, 9, 3, 8, 4])).slice(2, 5)
    )
    cols.append(Column.from_primitive[DType.float64](_f64(fv)).slice(2, 5))
    var batch = RecordBatch.from_typed_columns_slab(
        _schema(
            ["a", "f"], [ArrowType.INT64, ArrowType.FLOAT64], False,
        ),
        cols^,
    )
    var out = filter_record_batch_via_predicate(batch^, col("a") > 4)
    assert_equal(out.num_rows(), 3)
    _assert_ints(_ints_of(out, 0), [7, 9, 8], "a")
    var f_arr = out.column_at(1).as_primitive[DType.float64]()
    assert_equal(f_arr.get(0), 12.0)
    assert_equal(f_arr.get(1), 14.0)
    assert_equal(f_arr.get(2), 16.0)


def test_all_pass_native_batch_keeps_nulls() raises:
    var native = column_native_from_record_batch(_mixed_batch())
    var filtered = filter_column_native_via_predicate(native^, col("a") >= 1)
    var back = record_batch_from_column_native(filtered^)
    assert_equal(back.num_rows(), 8)
    assert_equal(back.column_at(1).null_count(), 3)
    assert_equal(back.column_at(2).null_count(), 2)
    assert_true(back.column_at(1).is_null_at(2))
    assert_true(back.column_at(2).is_null_at(4))


def main() raises:
    var suite = TestSuite()
    suite.test[test_keeps_matching_rows_in_order]()
    suite.test[test_all_rows_pass]()
    suite.test[test_no_rows_pass]()
    suite.test[test_null_rows_are_dropped]()
    suite.test[test_numeric_dictionary_is_resolved]()
    suite.test[test_string_dictionary_is_refused_by_name]()
    suite.test[test_nested_column_is_refused_by_name]()
    suite.test[test_column_native_entry_point]()
    suite.test[test_nullable_columns_gathered_at_scattered_rows]()
    suite.test[test_sliced_input_is_filtered_by_logical_rows]()
    suite.test[test_all_pass_native_batch_keeps_nulls]()
    suite^.run()
