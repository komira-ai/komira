# =============================================================================
# DistinctState[*Keys] — feed, dedup, drain and combine, against an oracle
# =============================================================================
#
# `DistinctState` dedups rows by their key columns and drains each distinct
# key combination once, in first-seen order. What each test kills:
#   * an INT64 key: a duplicate across batches emitted twice, a distinct value
#     dropped, or the drain out of first-seen order (the oracle is a linear
#     scan of the raw values);
#   * a composite (INT64, STRING) key: two rows that share one key column
#     merged (`(1, "a")` vs `(1, "b")`), and the empty string or multi-byte
#     UTF-8 mishandled;
#   * a FLOAT64 key: DuckDB's DISTINCT treats every NaN as one value and
#     `-0.0` as `0.0`. NaNs with different bit patterns must collapse to one
#     row, and the two zeros to one row, the first-seen spelling kept;
#   * `combine`: the union of two workers' states, each key once, the first
#     state's order followed by the second's new keys.
# =============================================================================

from std.collections import List, Set
from std.math import isnan
from std.memory import bitcast
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.batch_view import BatchView
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field, RecordBatch, RecordBatchBuilder, SchemaBuilder,
)
from komira_arrow.string_array import StringArray

from komira_op_agg_distinct.distinct_key_column import (
    DistinctKeyColumn_Typed,
)
from komira_op_agg_distinct.distinct_key_column_string import (
    DistinctKeyColumn_String,
)
from komira_op_agg_distinct.distinct_state import DistinctState


comptime _I64 = DistinctState[DistinctKeyColumn_Typed[DType.int64, 0]]
comptime _I64Str = DistinctState[
    DistinctKeyColumn_Typed[DType.int64, 0], DistinctKeyColumn_String[1]
]
comptime _F64 = DistinctState[DistinctKeyColumn_Typed[DType.float64, 0]]


def _i64_batch(imm keys: List[Int64]) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, False))
    var rb = RecordBatchBuilder()
    rb.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(keys)
        )
    )
    return rb.build(sb.build())


def _f64_batch(imm keys: List[Float64]) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.FLOAT64, False))
    var rb = RecordBatchBuilder()
    rb.add_column(
        Column.from_primitive[DType.float64](
            PrimitiveArray[DType.float64].from_list(keys)
        )
    )
    return rb.build(sb.build())


def _i64_str_batch(
    imm k: List[Int64], imm s: List[String]
) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, False))
    sb.add_field(Field("s", ArrowType.STRING, False))
    var rb = RecordBatchBuilder()
    rb.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(k)
        )
    )
    rb.add_column(Column.from_string(StringArray.from_strings(s)))
    return rb.build(sb.build())


def _feed_i64(mut st: _I64, imm b: RecordBatch) raises:
    var bv = BatchView(b)
    for r in range(b.num_rows()):
        st.feed_row(bv, r)


def _feed_f64(mut st: _F64, imm b: RecordBatch) raises:
    var bv = BatchView(b)
    for r in range(b.num_rows()):
        st.feed_row(bv, r)


def _feed_i64_str(mut st: _I64Str, imm b: RecordBatch) raises:
    var bv = BatchView(b)
    for r in range(b.num_rows()):
        st.feed_row(bv, r)


def _drained_i64(imm st: _I64) raises -> List[Int64]:
    var out = List[Int64]()
    var maybe = st.drain_to_record_batch()
    if not maybe:
        return out^
    var n = maybe.value().num_rows()
    var arr = maybe.value().column_at(0).as_primitive[DType.int64]()
    for i in range(n):
        out.append(arr.get(i))
    return out^


def _first_seen(imm keys: List[Int64]) -> List[Int64]:
    var seen = Set[Int64]()
    var out = List[Int64]()
    for i in range(len(keys)):
        if keys[i] not in seen:
            seen.add(keys[i])
            out.append(keys[i])
    return out^


def _keys(n: Int, salt: Int) -> List[Int64]:
    var out = List[Int64](capacity=n)
    for i in range(n):
        out.append(Int64(((i * 7_919 + salt * 104_729) % 3_001) - 1_500))
    return out^


def test_int_key_first_seen_order_across_batches() raises:
    var st = _I64()
    var all = List[Int64]()
    for b in range(3):
        var k = _keys(5_000, b)
        for i in range(len(k)):
            all.append(k[i])
        _feed_i64(st, _i64_batch(k))
    var want = _first_seen(all)
    assert_equal(st.size(), len(want), "distinct count")
    var got = _drained_i64(st)
    assert_equal(len(got), len(want), "drained rows")
    for i in range(len(want)):
        if got[i] != want[i]:
            assert_equal(got[i], want[i], "row " + String(i))


def test_composite_int_string_key() raises:
    var k: List[Int64] = [1, 1, 1, 2, 1, 2, 3, 3, 3, 1]
    var s: List[String] = [
        "a", "b", "a", "a", "", "a", "ÄÖÜ", "ÄÖ", "ÄÖÜ", "",
    ]
    var st = _I64Str()
    _feed_i64_str(st, _i64_str_batch(k, s))
    # First-seen distinct pairs: (1,a) (1,b) (2,a) (1,"") (3,ÄÖÜ) (3,ÄÖ).
    assert_equal(st.size(), 6, "six distinct (k, s) pairs")
    var maybe = st.drain_to_record_batch()
    assert_true(Bool(maybe), "a non-empty state drains a batch")
    var kk = maybe.value().column_at(0).as_primitive[DType.int64]()
    var ss = maybe.value().column_at(1).as_string()
    var wk: List[Int64] = [1, 1, 2, 1, 3, 3]
    var ws: List[String] = ["a", "b", "a", "", "ÄÖÜ", "ÄÖ"]
    for i in range(6):
        assert_equal(kk.get(i), wk[i], "k of row " + String(i))
        assert_equal(ss.get(i), ws[i], "s of row " + String(i))


def test_float_key_nans_collapse_and_zeros_collapse() raises:
    var nan_a = bitcast[DType.float64](UInt64(0x7FF8000000000000))
    var nan_b = bitcast[DType.float64](UInt64(0x7FF8000000000123))
    var nan_c = bitcast[DType.float64](UInt64(0xFFF8000000000000))
    var vals: List[Float64] = [
        1.5, nan_a, -0.0, nan_b, 0.0, 1.5, nan_c, -2.25, 0.0,
    ]
    var st = _F64()
    _feed_f64(st, _f64_batch(vals))
    assert_equal(st.size(), 4, "1.5, NaN, -0.0 (== 0.0), -2.25")
    var maybe = st.drain_to_record_batch()
    var arr = maybe.value().column_at(0).as_primitive[DType.float64]()
    assert_equal(arr.get(0), 1.5, "row 0")
    assert_true(isnan(arr.get(1)), "row 1 is the one NaN")
    assert_true(arr.get(2) == 0.0, "row 2 is the one zero")
    assert_equal(arr.get(3), -2.25, "row 3")


def test_combine_is_the_union_in_order() raises:
    var a = _I64()
    var b = _I64()
    var ka = _keys(4_000, 1)
    var kb = _keys(4_000, 2)
    _feed_i64(a, _i64_batch(ka))
    _feed_i64(b, _i64_batch(kb))
    var all = ka.copy()
    for i in range(len(kb)):
        all.append(kb[i])
    var want = _first_seen(all)
    a.combine(b^)
    assert_equal(a.size(), len(want), "union size")
    var got = _drained_i64(a)
    assert_equal(len(got), len(want), "drained rows")
    for i in range(len(want)):
        if got[i] != want[i]:
            assert_equal(got[i], want[i], "row " + String(i))


def test_an_empty_state_drains_nothing() raises:
    var st = _I64()
    assert_equal(st.size(), 0)
    var got = _drained_i64(st)
    assert_equal(len(got), 0, "no rows")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
