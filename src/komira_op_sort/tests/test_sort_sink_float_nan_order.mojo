# =============================================================================
# The sort and top-N sinks put NaN above +inf
# =============================================================================
#
# DuckDB orders a DOUBLE key with NaN greater than +inf: `ORDER BY x` ends
# with the NaN rows, `ORDER BY x DESC` starts with them, and so does
# `ORDER BY x DESC LIMIT k`. Two routes are checked against that:
#
#   * `_execute_sort_sink`, single FLOAT64 key (the merge sort);
#   * `_execute_topn_sink` in the HEAP regime (`num_rows > k *
#     TOPN_HEAP_RATIO`, asserted below), single key and FLOAT64 + INT64.
#
# A comparator using the IEEE `<` / `>` would never let a NaN beat the heap
# top, so DESC LIMIT k would return +inf rows and drop every NaN; these
# tests fail on that.
# =============================================================================

from std.math import inf, isnan
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.batch_view import BatchView
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_physical_plan.physical_plan import SortSinkData, TopNSinkData
from komira_op_sort.sort_topn_sink import (
    TOPN_HEAP_RATIO,
    _execute_sort_sink,
    _execute_topn_sink,
)


comptime _N: Int = 120


def _nan() -> Float64:
    return Float64(0.0) / Float64(0.0)


def _x_at(i: Int) -> Float64:
    """Row i's key: NaN every 10th row (12 NaNs), +inf every 15th that is
    not NaN, else a number in [-60, 60)."""
    if i % 10 == 7:
        return _nan()
    if i % 15 == 4:
        return inf[DType.float64]()
    return Float64((i * 37) % 120) - 60.0


def _fixture() raises -> RecordBatch:
    """Columns `x: FLOAT64` (the key) and `id: INT64` (= row number)."""
    var sb = SchemaBuilder()
    sb.add_field(Field(String("x"), ArrowType.FLOAT64, False))
    sb.add_field(Field(String("id"), ArrowType.INT64, False))
    var schema = sb.build()
    var xs = List[Scalar[DType.float64]]()
    var ids = List[Scalar[DType.int64]]()
    for i in range(_N):
        xs.append(_x_at(i))
        ids.append(Int64(i))
    var rbb = RecordBatchBuilder.with_capacity(2)
    rbb.add_column(Column.from_primitive[DType.float64](
        PrimitiveArray[DType.float64].from_list(xs)
    ))
    rbb.add_column(Column.from_primitive[DType.int64](
        PrimitiveArray[DType.int64].from_list(ids)
    ))
    return rbb.build(schema^)


def _xs(rb: RecordBatch) raises -> List[Float64]:
    var arr = rb.column_as_primitive_float64(0)
    var out = List[Float64]()
    for i in range(rb.num_rows()):
        out.append(Float64(arr.get(i)))
    return out^


def _ids(rb: RecordBatch) raises -> List[Int]:
    var arr = rb.column_as_primitive_int64(1)
    var out = List[Int]()
    for i in range(rb.num_rows()):
        out.append(Int(arr.get(i)))
    return out^


def test_fixture_is_in_the_heap_regime() raises:
    assert_true(_N > 10 * TOPN_HEAP_RATIO, "k=10 takes the heap")


def test_sort_sink_nan_last_ascending() raises:
    var keys: List[String] = ["x"]
    var desc: List[Bool] = [False]
    var out = _xs(_execute_sort_sink(_fixture(), SortSinkData(keys^, desc^)))
    assert_equal(len(out), _N)
    for i in range(_N - 12):
        assert_true(not isnan(out[i]), "no NaN before the last 12 rows")
    for i in range(_N - 12, _N):
        assert_true(isnan(out[i]), "the last 12 rows are the NaNs")
    assert_equal(out[_N - 13], inf[DType.float64]())
    for i in range(1, _N - 12):
        assert_true(out[i - 1] <= out[i], "ascending")


def test_topn_heap_desc_takes_nans_first() raises:
    var keys: List[String] = ["x"]
    var desc: List[Bool] = [True]
    var out = _xs(_execute_topn_sink(_fixture(), TopNSinkData(keys^, desc^, 10)))
    assert_equal(len(out), 10)
    for i in range(10):
        assert_true(isnan(out[i]), "DESC LIMIT 10 is ten NaN rows")


def test_topn_heap_desc_cut_below_the_nans() raises:
    # 12 NaNs, then the +inf rows: LIMIT 14 is all 12 NaNs and two +inf.
    var keys: List[String] = ["x", "id"]
    var desc: List[Bool] = [True, False]
    var rb = _execute_topn_sink(_fixture(), TopNSinkData(keys^, desc^, 14))
    var out = _xs(rb)
    var ids = _ids(rb)
    assert_equal(len(out), 14)
    for i in range(12):
        assert_true(isnan(out[i]), "rows 0..11 are NaN")
    # NaNs tie, so `id` ASC orders them: rows 7, 17, ..., 117.
    for i in range(12):
        assert_equal(ids[i], 7 + 10 * i, "NaN rows by id")
    assert_equal(out[12], inf[DType.float64]())
    assert_equal(out[13], inf[DType.float64]())
    assert_equal(ids[12], 4)
    assert_equal(ids[13], 19)


def test_topn_heap_asc_never_takes_nan() raises:
    var keys: List[String] = ["x"]
    var desc: List[Bool] = [False]
    var out = _xs(_execute_topn_sink(_fixture(), TopNSinkData(keys^, desc^, 10)))
    # Expected: the ten smallest non-NaN keys, by a plain insertion sort.
    var finite = List[Float64]()
    for i in range(_N):
        var x = _x_at(i)
        if isnan(x):
            continue
        var j = len(finite)
        finite.append(x)
        while j > 0 and finite[j - 1] > x:
            finite[j] = finite[j - 1]
            j -= 1
        finite[j] = x
    assert_equal(len(out), 10)
    for i in range(10):
        assert_equal(out[i], finite[i], "the ten smallest keys")




def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
