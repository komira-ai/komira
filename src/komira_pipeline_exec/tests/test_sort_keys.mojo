# =============================================================================
# SINK_SORT: what a key may hold and which keys are refused
# =============================================================================
#
# `SortSink` driven by hand over small batches built for one key type each.
# What these tests prove:
#
#   * FLOAT64 with NaN, +-infinity and +-0.0: -inf first, NaN after +inf, the
#     zeros together, NaN rows tied in input order, ascending and descending,
#     with a NULL placed first or last.
#   * The empty string sorts before every other string and is not a NULL.
#   * A STRING dictionary whose entries are not in sorted order sorts by the
#     strings, not by the codes: ascending and descending, as the second key
#     behind a tie, and with a NULL code placed by the plan.
#   * A key whose type cannot be sorted (DECIMAL, DATE32) is refused by name
#     when the sink is built over a known schema; over an unknown schema it is
#     refused by name at combine, the output is then not readable, and the pool
#     holds nothing once the sink is dropped.

from std.math import inf, nan
from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.column_builder import ColumnBuilder
from komira_arrow.dictionary_array import StringDictionaryArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    SchemaBuilder,
)
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_morsel.morsel import Morsel
from komira_morsel.pipeline_execution import PipelineExecution
from komira_physical_plan.physical_plan import SortSinkData
from komira_pipeline_exec.plan_harness import int64_column
from komira_pipeline_exec.segment_pool import SegmentPool
from komira_pipeline_exec.sink_sort import SortSink


def _ids(n: Int) raises -> Column[HeapRegion]:
    var ids = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        ids.set(i, Int64(i))
    return Column.from_primitive[DType.int64](ids^)


def _sort(
    var batch: RecordBatch,
    keys: List[String],
    desc: List[Bool],
    nulls_first: List[Bool],
) raises -> List[Int]:
    var pool = SegmentPool()
    var data = SortSinkData(keys.copy(), desc.copy(), 0, nulls_first.copy())
    var sink = SortSink(data, pool.share(), 3, Optional(batch.schema.copy()))
    sink.resize_worker_state(1)
    sink.consume(0, Morsel(batch^, 0, 0))
    var pipeline = PipelineExecution(1, 0)
    sink.combine(pipeline)
    sink.finalize()
    var out = sink.take_output()
    _ = sink^
    assert_equal(pool.granted(), 0)
    return int64_column(out, 0)


def _k(a: String, b: String = "") -> List[String]:
    var out = List[String]()
    out.append(a)
    if b != "":
        out.append(b)
    return out^


def _f(a: Bool, b: Bool = False, n: Int = 1) -> List[Bool]:
    var out = List[Bool]()
    out.append(a)
    if n > 1:
        out.append(b)
    return out^


def _expect(got: List[Int], want: List[Int]) raises:
    assert_equal(len(got), len(want))
    for i in range(len(want)):
        assert_equal(got[i], want[i], "position " + String(i))


def _expect_at(got: List[Int], start: Int, want: List[Int]) raises:
    for i in range(len(want)):
        assert_equal(got[start + i], want[i], "position " + String(start + i))


def _floats() raises -> RecordBatch:
    var f = ColumnBuilder[DType.float64].with_capacity(10)
    f.append(3.0)
    f.append(nan[DType.float64]())
    f.append(-inf[DType.float64]())
    f.append(0.0)
    f.append(-0.0)
    f.append(inf[DType.float64]())
    f.append(-1.5)
    f.append(nan[DType.float64]())
    f.append(0.0)
    f.append_null()
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("id", ArrowType.INT64, False))
    rb.add_column(_ids(10))
    sb.add_field(Field("f", ArrowType.FLOAT64, True))
    rb.add_column(f^.materialize())
    return rb.build(sb.build())


def _in_set(got: List[Int], start: Int, members: List[Int]) -> Bool:
    """Whether got[start .. start + len(members)) is `members`, any order."""
    for m in members:
        var found = False
        for i in range(len(members)):
            if got[start + i] == m:
                found = True
        if not found:
            return False
    return True


def test_float_special_values_and_a_null() raises:
    var zeros = List[Int]()
    zeros.append(3)
    zeros.append(4)
    zeros.append(8)
    # Ascending, NULLs last: -inf, -1.5, the zeros, 3.0, +inf, the NaNs in
    # input order, the NULL.
    var asc = _sort(_floats(), _k("f"), _f(False), _f(False))
    assert_equal(asc[0], 2)
    assert_equal(asc[1], 6)
    assert_true(_in_set(asc, 2, zeros), "the zeros are together")
    _expect_at(asc, 5, [0, 5, 1, 7, 9])
    # Descending, NULLs first: the NULL, the NaNs, +inf, 3.0, the zeros, -1.5,
    # -inf.
    var desc = _sort(_floats(), _k("f"), _f(True), _f(True))
    _expect_at(desc, 0, [9, 1, 7, 5, 0])
    assert_true(_in_set(desc, 5, zeros), "the zeros are together")
    assert_equal(desc[8], 6)
    assert_equal(desc[9], 2)


def _strings() raises -> RecordBatch:
    var values = List[String]()
    var valid = List[Bool]()
    for v in ["b", "", "a", "", "ab", "x"]:
        values.append(String(v))
        valid.append(True)
    valid[5] = False  # row 5 is NULL
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("id", ArrowType.INT64, False))
    rb.add_column(_ids(6))
    sb.add_field(Field("s", ArrowType.STRING, True))
    rb.add_column(
        Column.from_string(StringArray.from_strings_with_validity(values, valid))
    )
    return rb.build(sb.build())


def test_the_empty_string_is_the_least_string_and_not_a_null() raises:
    _expect(_sort(_strings(), _k("s"), _f(False), _f(False)), [1, 3, 2, 4, 0, 5])
    _expect(_sort(_strings(), _k("s"), _f(True), _f(True)), [5, 0, 4, 2, 1, 3])


def _dict_batch(with_null: Bool) raises -> RecordBatch:
    # Entries in unsorted order: code 0 "pear", 1 "apple", 2 "fig".
    var entries = List[String]()
    entries.append("pear")
    entries.append("apple")
    entries.append("fig")
    var codes = PrimitiveArray[DType.int32].allocate_nullable(7)
    var want = [0, 1, 2, 1, 0, 2, 1]
    for i in range(7):
        codes.set(i, Int32(want[i]))
    if with_null:
        # SAFETY-free but private: the only way to mark a code NULL.
        codes._set_null(3)
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("id", ArrowType.INT64, False))
    rb.add_column(_ids(7))
    sb.add_field(Field.dictionary("d", ArrowType.INT32, with_null))
    rb.add_column(
        Column.from_dictionary(
            StringDictionaryArray.from_parts(codes^, StringArray.from_strings(entries))
        )
    )
    return rb.build(sb.build())


def test_a_dictionary_sorts_by_its_strings_and_not_its_codes() raises:
    # apple (ids 1, 3, 6), fig (2, 5), pear (0, 4): the codes alone would put
    # pear first.
    _expect(_sort(_dict_batch(False), _k("d"), _f(False), _f(False)), [1, 3, 6, 2, 5, 0, 4])
    _expect(_sort(_dict_batch(False), _k("d"), _f(True), _f(False)), [0, 4, 2, 5, 1, 3, 6])
    # d descending, then id descending.
    _expect(
        _sort(_dict_batch(False), _k("d", "id"), _f(True, True, 2), _f(False, False, 2)),
        [4, 0, 5, 2, 6, 3, 1],
    )


def test_a_null_dictionary_code_is_placed_by_the_plan() raises:
    # Row 3 is NULL; the rest as above.
    _expect(_sort(_dict_batch(True), _k("d"), _f(False), _f(True)), [3, 1, 6, 2, 5, 0, 4])
    _expect(_sort(_dict_batch(True), _k("d"), _f(False), _f(False)), [1, 6, 2, 5, 0, 4, 3])


def test_a_key_that_cannot_be_sorted_is_refused_when_the_sink_is_built() raises:
    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, False))
    sb.add_field(Field.decimal128("price", 10, 2, False))
    sb.add_field(Field("day", ArrowType.DATE32, False))
    var schema = sb.build()
    var pool = SegmentPool()
    with assert_raises(contains="sorts by 'price', of unsupported sort key type"):
        _ = SortSink(SortSinkData(_k("price"), _f(False)), pool.share(), 3, Optional(schema.copy()))
    with assert_raises(contains="sorts by 'day', of unsupported sort key type"):
        _ = SortSink(SortSinkData(_k("id", "day"), _f(False, False, 2)), pool.share(), 3, Optional(schema.copy()))
    # A sortable key over the same schema is accepted.
    _ = SortSink(SortSinkData(_k("id"), _f(False)), pool.share(), 3, Optional(schema.copy()))


def test_over_an_unknown_schema_the_refusal_comes_at_combine_with_no_output() raises:
    var f32 = PrimitiveArray[DType.float32].allocate(3)
    for i in range(3):
        f32.set(i, Float32(3 - i))
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("id", ArrowType.INT64, False))
    rb.add_column(_ids(3))
    sb.add_field(Field("x", ArrowType.FLOAT32, False))
    rb.add_column(Column.from_primitive[DType.float32](f32^))
    var pool = SegmentPool()
    var sink = SortSink(SortSinkData(_k("x"), _f(False)), pool.share(), 3, None)
    sink.resize_worker_state(1)
    sink.consume(0, Morsel(rb.build(sb.build()), 0, 0))
    var pipeline = PipelineExecution(1, 0)
    with assert_raises(contains="of unsupported sort key type"):
        sink.combine(pipeline)
    with assert_raises(contains="read before it was combined"):
        _ = sink.take_output()
    _ = sink^
    assert_equal(pool.granted(), 0)


def main() raises:
    var suite = TestSuite()
    suite.test[test_float_special_values_and_a_null]()
    suite.test[test_the_empty_string_is_the_least_string_and_not_a_null]()
    suite.test[test_a_dictionary_sorts_by_its_strings_and_not_its_codes]()
    suite.test[test_a_null_dictionary_code_is_placed_by_the_plan]()
    suite.test[test_a_key_that_cannot_be_sorted_is_refused_when_the_sink_is_built]()
    suite.test[test_over_an_unknown_schema_the_refusal_comes_at_combine_with_no_output]()
    suite^.run()
