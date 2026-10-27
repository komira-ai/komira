# =============================================================================
# DistinctState[*Keys] — feed, dedup, drain and combine, against an oracle
# =============================================================================
#
# `DistinctState` dedups rows by their key columns and drains each distinct
# key combination once, in first-seen order. What each test proves:
#   * an INT64 key: a duplicate across batches is emitted once, every distinct
#     value is kept, and the drain is in first-seen order (the oracle is a
#     linear scan of the raw values);
#   * a composite (INT64, STRING) key: rows that share one key column stay
#     apart (`(1, "a")` vs `(1, "b")`), and the empty string and multi-byte
#     UTF-8 are kept as distinct values;
#   * a FLOAT64 key: DuckDB's DISTINCT treats every NaN as one value and
#     `-0.0` as `0.0`. NaNs with different bit patterns collapse to one row,
#     and the two zeros to one row, the first-seen spelling kept;
#   * keys whose combined hashes are identical stay distinct rows: the dedup
#     decides by comparing the keys, not the hash;
#   * `combine`: the union of two states with disjoint and overlapping key
#     sets, each key once, the first state's order followed by the second's
#     new keys in the second's order;
#   * NULL keys: `feed_row` raises on a NULL in any key column, while a
#     validity bitmap with no NULL set is accepted;
#   * a state with spilled rows refuses to drain, and refuses to be combined
#     in, until it is restored (see `test_spill_distinct_state`).
# =============================================================================

from std.collections import List, Set
from std.math import isnan
from std.memory import bitcast
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.batch_view import BatchView
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field, RecordBatch, RecordBatchBuilder, SchemaBuilder,
)
from komira_arrow.string_array import StringArray

from komira_op_agg_distinct.distinct_key_column import (
    DISTINCT_FNV_OFFSET,
    DISTINCT_FNV_PRIME,
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
comptime _I64I64 = DistinctState[
    DistinctKeyColumn_Typed[DType.int64, 0],
    DistinctKeyColumn_Typed[DType.int64, 1],
]


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


def _stepped(lo: Int, hi: Int, step: Int) -> List[Int64]:
    var out = List[Int64]()
    var v = lo
    while v < hi:
        out.append(Int64(v))
        v += step
    return out^


def _combine_matches_single_feed(
    imm ka: List[Int64], imm kb: List[Int64]
) raises:
    """Combining the states of `ka` and `kb` drains what feeding `ka` then
    `kb` into one state drains: the union, in first-seen order."""
    var a = _I64()
    var b = _I64()
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


def test_combine_disjoint_key_sets() raises:
    # Evens then odds: no key in common, so every key of `b` is new.
    _combine_matches_single_feed(_stepped(0, 6_000, 2), _stepped(1, 6_000, 2))


def test_combine_overlapping_key_sets() raises:
    # Multiples of 2 and of 3: a third of `b` is already in `a`, the rest is
    # new, and `b` lists its keys in a different order than `a` would.
    var kb = _stepped(0, 6_000, 3)
    var rev = List[Int64]()
    for i in range(len(kb)):
        rev.append(kb[len(kb) - 1 - i])
    _combine_matches_single_feed(_stepped(0, 6_000, 2), rev)


def test_combine_key_repeated_only_inside_the_second_state() raises:
    # 7 and 9 occur only in `b`, several times each: they appear once, after
    # `a`'s keys, in `b`'s first-seen order.
    var ka: List[Int64] = [5, 3, 5]
    var kb: List[Int64] = [9, 3, 7, 9, 7, 5, 9]
    var a = _I64()
    var b = _I64()
    _feed_i64(a, _i64_batch(ka))
    _feed_i64(b, _i64_batch(kb))
    a.combine(b^)
    var got = _drained_i64(a)
    var want: List[Int64] = [5, 3, 9, 7]
    assert_equal(len(got), len(want), "union size")
    for i in range(len(want)):
        assert_equal(got[i], want[i], "row " + String(i))


def test_combine_with_an_empty_side() raises:
    var ks: List[Int64] = [4, 4, 2]
    _combine_matches_single_feed(ks, List[Int64]())
    _combine_matches_single_feed(List[Int64](), ks)


def test_an_empty_state_drains_nothing() raises:
    var st = _I64()
    assert_equal(st.size(), 0)
    var got = _drained_i64(st)
    assert_equal(len(got), 0, "no rows")


def _bits(v: Int64) -> UInt64:
    return bitcast[DType.uint64, 1](SIMD[DType.int64, 1](v))[0]


def _colliding_second_key(a: Int64, b: Int64, a2: Int64) -> Int64:
    """The `b2` for which the composite key `(a2, b2)` has the same combined
    FNV-1a hash as `(a, b)`: the hash of `(x, y)` is
    `((OFFSET ^ x) * PRIME ^ y) * PRIME`, so equal hashes need
    `y2 = y ^ (OFFSET ^ x) * PRIME ^ (OFFSET ^ x2) * PRIME`."""
    var inner = (DISTINCT_FNV_OFFSET ^ _bits(a)) * DISTINCT_FNV_PRIME
    var inner2 = (DISTINCT_FNV_OFFSET ^ _bits(a2)) * DISTINCT_FNV_PRIME
    var u = inner ^ _bits(b) ^ inner2
    return bitcast[DType.int64, 1](SIMD[DType.uint64, 1](u))[0]


def _i64_i64_batch(
    imm k0: List[Int64], imm k1: List[Int64]
) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field("k0", ArrowType.INT64, False))
    sb.add_field(Field("k1", ArrowType.INT64, False))
    var rb = RecordBatchBuilder()
    rb.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(k0)
        )
    )
    rb.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(k1)
        )
    )
    return rb.build(sb.build())


def test_keys_with_identical_hashes_stay_distinct() raises:
    var b1 = _colliding_second_key(1, 2, 3)
    var b2 = _colliding_second_key(1, 2, -40)
    assert_true(b1 != 2 and b2 != 2 and b1 != b2, "three different keys")
    # (1,2), (3,b1) and (-40,b2) share one combined hash. Each is fed twice.
    var k0: List[Int64] = [1, 3, -40, 3, 1, -40]
    var k1: List[Int64] = [2, b1, b2, b1, 2, b2]
    var st = _I64I64()
    var b = _i64_i64_batch(k0, k1)
    var bv = BatchView(b)
    for r in range(b.num_rows()):
        st.feed_row(bv, r)
    assert_equal(st.size(), 3, "three distinct keys with one hash")
    var maybe = st.drain_to_record_batch()
    var c0 = maybe.value().column_at(0).as_primitive[DType.int64]()
    var c1 = maybe.value().column_at(1).as_primitive[DType.int64]()
    assert_equal(c0.get(0), 1)
    assert_equal(c1.get(0), 2)
    assert_equal(c0.get(1), 3)
    assert_equal(c1.get(1), b1)
    assert_equal(c0.get(2), -40)
    assert_equal(c1.get(2), b2)


def test_combine_keeps_keys_with_identical_hashes_apart() raises:
    var b1 = _colliding_second_key(1, 2, 3)
    var ka0: List[Int64] = [1]
    var ka1: List[Int64] = [2]
    var kb0: List[Int64] = [3, 1]
    var kb1: List[Int64] = [b1, 2]
    var a = _I64I64()
    var b = _I64I64()
    var ba = _i64_i64_batch(ka0, ka1)
    var bb = _i64_i64_batch(kb0, kb1)
    var bva = BatchView(ba)
    var bvb = BatchView(bb)
    a.feed_row(bva, 0)
    for r in range(2):
        b.feed_row(bvb, r)
    a.combine(b^)
    assert_equal(a.size(), 2, "(1,2) and (3,b1) are two keys")


def _batch_with_null_int(null_row: Int) raises -> RecordBatch:
    var a = PrimitiveArray[DType.int64].allocate_nullable(3)
    for i in range(3):
        a.set(i, Int64(i * 5))
    if null_row >= 0:
        a._set_null(null_row)
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, True))
    var rb = RecordBatchBuilder()
    rb.add_column(Column.from_primitive[DType.int64](a^))
    return rb.build(sb.build())


def _feed_raises_i64(mut st: _I64, imm b: RecordBatch) -> Bool:
    var bv = BatchView(b)
    try:
        for r in range(b.num_rows()):
            st.feed_row(bv, r)
    except:
        return True
    return False


def test_null_int_key_is_rejected() raises:
    # Values 0, 5, 10 with row 1 NULL: the NULL slot holds 5, which a
    # validity-blind state would take for a real key.
    var st = _I64()
    assert_true(_feed_raises_i64(st, _batch_with_null_int(1)), "raises")
    assert_equal(st.size(), 1, "the row before the NULL was kept")


def test_null_zero_slot_is_not_taken_for_zero() raises:
    # Row 0 holds the raw value 0 and is NULL: it must raise, not dedup
    # against a stored 0.
    var st = _I64()
    var zeros: List[Int64] = [0]
    _feed_i64(st, _i64_batch(zeros))
    assert_true(_feed_raises_i64(st, _batch_with_null_int(0)), "raises")
    assert_equal(st.size(), 1, "no new row")


def test_validity_bitmap_without_nulls_is_accepted() raises:
    var st = _I64()
    assert_false(_feed_raises_i64(st, _batch_with_null_int(-1)), "no raise")
    assert_equal(st.size(), 3, "three distinct keys")


def test_null_string_key_in_a_composite_is_rejected() raises:
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, False))
    sb.add_field(Field("s", ArrowType.STRING, True))
    var rb = RecordBatchBuilder()
    var ks: List[Int64] = [1, 1]
    rb.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(ks)
        )
    )
    var vals: List[String] = ["", "x"]
    var valid: List[Bool] = [False, True]
    rb.add_column(
        Column.from_string(StringArray.from_strings_with_validity(vals, valid))
    )
    var b = rb.build(sb.build())
    var st = _I64Str()
    var bv = BatchView(b)
    var raised = False
    try:
        st.feed_row(bv, 0)
    except:
        raised = True
    assert_true(raised, "a NULL string key raises")
    assert_equal(st.size(), 0, "nothing stored")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
