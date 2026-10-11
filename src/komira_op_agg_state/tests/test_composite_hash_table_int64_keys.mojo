# =============================================================================
# test_composite_hash_table_int64_keys.mojo — Int64 key components compare
# exactly in CompositeHashTable{2,3}F64 (komira-ai/komira#1055)
# =============================================================================
#
# An Int64 key component is stored in the component's Float64 arm. It used to
# be stored by VALUE (an int -> float conversion), so every Int64 with
# |v| > 2^53 came back rounded: the same key inserted twice opened a second
# group, two keys that differ collapsed, and `key_at` reported a key that is
# not in the data. When the insert of such a key crossed the grow threshold,
# the post-grow lookup of that key (`_lookup_existing`) never found it and
# probed forever, so the two grow tests below hung before the fix rather than
# failing. These tests pin the exact contract: one group per distinct
# Int64, and `key_at` returns the inserted value bit for bit.
#
#   2^53 + 1 inserted twice     one group, SUM 2.0, key_at == 2^53 + 1
#                               (the issue's reproduction).
#   2^53 and 2^53 + 1           two groups with their own sums: the rounded
#                               store made them the same stored key.
#   Int64.MIN / Int64.MAX       the conversion back from 2^63 overflows Int64;
#                               both extremes must round-trip.
#   NaN-shaped bit patterns     Int64 values whose bits read as a quiet or a
#                               signaling Float64 NaN survive store, load and
#                               a grow (a bit-preserving store must not let
#                               the Float64 arm canonicalize them).
#   big keys through a grow     40 keys above 2^53, each differing by 1,
#                               re-found after several rehashes.
#   arity 3                     the 3-component store shares the same arm.
# =============================================================================

from std.testing import TestSuite, assert_equal

from komira_op_agg_state.composite_hash_table import (
    CompositeHashTable2F64,
    CompositeHashTable3F64,
)
from komira_op_agg_state.agg_state_slab import (
    SumF64,
    KeyHashFnv2,
    KeyEqElementwise2,
    KeyHashFnv3,
    KeyEqElementwise3,
)
from komira_expr.composite_key import (
    ColumnValue,
    KeyValue2,
    KeyValue3,
    CVT_INT64,
)

comptime _T2 = CompositeHashTable2F64[SumF64, KeyHashFnv2, KeyEqElementwise2]
comptime _T3 = CompositeHashTable3F64[SumF64, KeyHashFnv3, KeyEqElementwise3]

comptime _P53: Int64 = Int64(1) << 53


def _k2(a: Int64) -> KeyValue2:
    return KeyValue2(ColumnValue(a), ColumnValue(Int64(0)))


def _sum_of(t: _T2, key: Int64) raises -> Float64:
    """The SUM of the one occupied slot whose first component is `key`;
    raises when no slot or more than one slot holds it."""
    var found = 0
    var total = Float64(0)
    for slot in range(t.capacity_of()):
        if not t.is_occupied(slot):
            continue
        var k = t.key_at(slot)
        assert_equal(k.c0.kind(), CVT_INT64)
        if k.c0.as_i64() == key:
            found += 1
            total = t.finalize_at(slot)
    assert_equal(found, 1, String("slots holding key ") + String(key))
    return total


def test_key_past_2p53_inserted_twice_is_one_group() raises:
    var t = _T2.new(16)
    var big = _P53 + 1
    t.update_scalar(_k2(big), 1.0)
    t.update_scalar(_k2(big), 1.0)
    assert_equal(t.n_used, 1)
    assert_equal(_sum_of(t, big), Float64(2.0))


def test_neighbouring_keys_past_2p53_stay_apart() raises:
    var t = _T2.new(16)
    for _ in range(3):
        t.update_scalar(_k2(_P53), 1.0)
        t.update_scalar(_k2(_P53 + 1), 10.0)
        t.update_scalar(_k2(-_P53 - 1), 100.0)
    assert_equal(t.n_used, 3)
    assert_equal(_sum_of(t, _P53), Float64(3.0))
    assert_equal(_sum_of(t, _P53 + 1), Float64(30.0))
    assert_equal(_sum_of(t, -_P53 - 1), Float64(300.0))


def test_int64_extremes_round_trip() raises:
    var t = _T2.new(16)
    for _ in range(2):
        t.update_scalar(_k2(Int64.MAX), 1.0)
        t.update_scalar(_k2(Int64.MIN), 2.0)
        t.update_scalar(_k2(Int64.MAX - 1), 4.0)
    assert_equal(t.n_used, 3)
    assert_equal(_sum_of(t, Int64.MAX), Float64(2.0))
    assert_equal(_sum_of(t, Int64.MIN), Float64(4.0))
    assert_equal(_sum_of(t, Int64.MAX - 1), Float64(8.0))


def test_nan_shaped_int64_bit_patterns_round_trip_through_a_grow() raises:
    # 0x7FF0000000000001: a signaling NaN's bits; 0x7FF8000000000000: the
    # canonical quiet NaN; 0xFFF0000000000001: a negative signaling NaN.
    var keys = List[Int64]()
    keys.append(Int64(0x7FF0000000000001))
    keys.append(Int64(0x7FF8000000000000))
    keys.append(Int64(0x7FF8000000000001))
    keys.append(Int64(-0x000FFFFFFFFFFFFF))
    var t = _T2.new(4)
    for rep in range(2):
        for i in range(len(keys)):
            t.update_scalar(_k2(keys[i]), Float64(i + 1))
        # Filler past 2^53 forces grows between the two passes.
        if rep == 0:
            for j in range(20):
                t.update_scalar(_k2(_P53 * 4 + Int64(j)), 0.5)
    assert_equal(t.n_used, len(keys) + 20)
    for i in range(len(keys)):
        assert_equal(_sum_of(t, keys[i]), Float64(2 * (i + 1)))
    for j in range(20):
        assert_equal(_sum_of(t, _P53 * 4 + Int64(j)), Float64(0.5))


def test_consecutive_big_keys_refind_their_bucket_after_grows() raises:
    var t = _T2.new(4)
    for rep in range(3):
        for i in range(40):
            t.update_scalar(_k2(_P53 + Int64(i)), Float64(i))
    assert_equal(t.n_used, 40)
    for i in range(40):
        assert_equal(_sum_of(t, _P53 + Int64(i)), Float64(3 * i))


def test_arity3_int64_components_compare_exactly() raises:
    var t = _T3.new(16)
    for _ in range(2):
        t.update_scalar(
            KeyValue3(
                ColumnValue(Int64(7)),
                ColumnValue(_P53 + 1),
                ColumnValue(Int64.MAX),
            ),
            1.0,
        )
        t.update_scalar(
            KeyValue3(
                ColumnValue(Int64(7)),
                ColumnValue(_P53),
                ColumnValue(Int64.MAX),
            ),
            5.0,
        )
    assert_equal(t.n_used, 2)
    var seen = 0
    for slot in range(t.capacity_of()):
        if not t.is_occupied(slot):
            continue
        var k = t.key_at(slot)
        assert_equal(k.c0.as_i64(), Int64(7))
        assert_equal(k.c2.as_i64(), Int64.MAX)
        if k.c1.as_i64() == _P53 + 1:
            assert_equal(t.finalize_at(slot), Float64(2.0))
        else:
            assert_equal(k.c1.as_i64(), _P53)
            assert_equal(t.finalize_at(slot), Float64(10.0))
        seen += 1
    assert_equal(seen, 2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
