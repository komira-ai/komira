# =============================================================================
# test_tables_edges.mojo — probe and storage edges of the byte-keyed tables,
# the composite-key table, the parametric hash sets and the 3-span packer
# =============================================================================
#
#   ByteHashAggTableF64   two keys of DIFFERENT lengths whose FNV-1a hashes
#                         share both the 15-bit salt and the start slot
#                         ("k0048974", 8 bytes, and "k00061100", 9 bytes, at
#                         the 2048-slot initial capacity): the probe must
#                         compare lengths and keep them apart.
#   ByteHashSet           a caller-supplied hash shared by rows of different
#                         lengths: insert and contains keep them distinct.
#   CompositeHashTable2F64  Float64, String and Bool key components survive
#                         the store/load round trip, through a grow, and
#                         re-find their bucket.
#   HashSet2..HashSet8    every arity counts distinct tuples, refuses a
#                         duplicate, and misses a tuple differing only in the
#                         LAST component (HashSet5 and HashSet7 had no test).
#   pack_3_byte_spans_u64 two-byte middle and last components round-trip.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_op_agg_state.byte_hash_agg_table import ByteHashAggTableF64
from komira_op_agg_state.byte_hashset import ByteHashSet
from komira_op_agg_state.composite_hash_table import CompositeHashTable2F64
from komira_op_agg_state.agg_state_slab import (
    SumF64, KeyHashFnv2, KeyEqElementwise2,
)
from komira_expr.composite_key import (
    ColumnValue, KeyValue2, CVT_BOOL, CVT_FLOAT64, CVT_STRING,
)
from komira_op_agg_state.hashset_parametric import (
    HashSet2, HashSet3, HashSet4, HashSet5, HashSet6, HashSet7, HashSet8,
)
from komira_op_agg_state.pack_byte_spans import (
    pack_3_byte_spans_u64,
    unpack_3_byte_spans_u64,
)


def _bytes_of(s: String) -> List[UInt8]:
    var sb = s.as_bytes()
    var out = List[UInt8](capacity=len(sb))
    for k in range(len(sb)):
        out.append(sb[k])
    return out^


def _fnv(b: List[UInt8]) -> UInt64:
    var s = UInt64(14695981039346656037)
    for i in range(len(b)):
        s = (s ^ UInt64(b[i])) * UInt64(1099511628211)
    return s


# =============================================================================
# ByteHashAggTableF64: same salt and slot, different lengths
# =============================================================================


def test_byte_table_keeps_salt_colliding_keys_of_different_lengths_apart() raises:
    var a = _bytes_of("k0048974")
    var b = _bytes_of("k00061100")
    # The fixture is only a fixture if the two keys really collide: same start
    # slot at 2048 slots and same high-16-bit salt (bit 15 forced on).
    var ha = _fnv(a)
    var hb = _fnv(b)
    assert_equal(ha & UInt64(2047), hb & UInt64(2047))
    assert_equal((ha >> 48) | UInt64(0x8000), (hb >> 48) | UInt64(0x8000))
    assert_true(ha != hb)

    var t = ByteHashAggTableF64[SumF64]()
    assert_equal(t.capacity(), 2048)
    t.update_scalar(Span(a), 1.0)
    t.update_scalar(Span(b), 10.0)
    t.update_scalar(Span(a), 2.0)
    t.update_scalar(Span(b), 20.0)
    assert_equal(t.size(), 2)
    assert_equal(t.finalize_at(0), Float64(3.0))
    assert_equal(t.finalize_at(1), Float64(30.0))
    assert_equal(len(t.key_at(1)), 9)


# =============================================================================
# ByteHashSet: one hash, rows of different lengths
# =============================================================================


def test_byte_hashset_shared_hash_different_lengths() raises:
    var s = ByteHashSet()
    var short = _bytes_of("ab")
    var long = _bytes_of("abc")
    var other = _bytes_of("ab!")
    var h = UInt64(77)
    assert_true(s.insert_serialized(h, Span(short)))
    assert_false(s.contains_serialized(h, Span(long)))
    assert_true(s.insert_serialized(h, Span(long)))
    assert_false(s.insert_serialized(h, Span(long)))
    assert_true(s.contains_serialized(h, Span(short)))
    assert_true(s.contains_serialized(h, Span(long)))
    # Same hash and length, different bytes: still a miss.
    assert_false(s.contains_serialized(h, Span(other)))
    assert_equal(s.size(), 2)
    assert_equal(s.row_byte_len(1), 3)


# =============================================================================
# CompositeHashTable2F64: non-Int64 key components
# =============================================================================


def _fkey(i: Int) -> KeyValue2:
    # Float64 component then String component.
    return KeyValue2(
        ColumnValue(Float64(i) + 0.25), ColumnValue(String("s") + String(i))
    )


def test_composite_float_and_string_keys_round_trip_through_a_grow() raises:
    var t = CompositeHashTable2F64[SumF64, KeyHashFnv2, KeyEqElementwise2].new(4)
    for i in range(20):
        t.update_scalar(_fkey(i), Float64(i))
    for i in range(20):
        t.update_scalar(_fkey(i), Float64(100))
    assert_equal(t.n_used, 20)
    assert_true(t.capacity_of() > 4)
    var seen = 0
    for slot in range(t.capacity_of()):
        if not t.is_occupied(slot):
            continue
        var k = t.key_at(slot)
        assert_equal(k.c0.kind(), CVT_FLOAT64)
        assert_equal(k.c1.kind(), CVT_STRING)
        var i = Int(k.c0.as_f64() - 0.25)
        assert_equal(k.c0.as_f64(), Float64(i) + 0.25)
        assert_equal(k.c1.as_str(), String("s") + String(i))
        assert_equal(t.finalize_at(slot), Float64(i + 100))
        seen += 1
    assert_equal(seen, 20)


def test_composite_float_and_string_keys_refind_their_bucket() raises:
    """No grow (3 keys in 64 slots): a key whose stored components do not
    load back equal would open a new bucket on every update."""
    var t = CompositeHashTable2F64[SumF64, KeyHashFnv2, KeyEqElementwise2].new(64)
    for rep in range(4):
        for i in range(3):
            t.update_scalar(_fkey(i), Float64(rep))
    assert_equal(t.n_used, 3)
    for slot in range(t.capacity_of()):
        if t.is_occupied(slot):
            assert_equal(t.finalize_at(slot), Float64(6.0))


def test_composite_bool_keys_round_trip() raises:
    var t = CompositeHashTable2F64[SumF64, KeyHashFnv2, KeyEqElementwise2].new(16)
    for rep in range(3):
        t.update_scalar(KeyValue2(ColumnValue(True), ColumnValue(String("x"))), 1.0)
        t.update_scalar(KeyValue2(ColumnValue(False), ColumnValue(String("x"))), 5.0)
    assert_equal(t.n_used, 2)
    var n_true = 0
    var n_false = 0
    for slot in range(t.capacity_of()):
        if not t.is_occupied(slot):
            continue
        var k = t.key_at(slot)
        assert_equal(k.c0.kind(), CVT_BOOL)
        if k.c0.as_bool():
            n_true += 1
            assert_equal(t.finalize_at(slot), Float64(3.0))
        else:
            n_false += 1
            assert_equal(t.finalize_at(slot), Float64(15.0))
    assert_equal(n_true, 1)
    assert_equal(n_false, 1)


# =============================================================================
# Parametric hash sets, arities 2..8
# =============================================================================


def test_hashset2_to_4_size_and_last_component_miss() raises:
    var s2 = HashSet2[DType.int64, DType.int32]()
    assert_true(s2.insert(1, 2))
    assert_true(s2.insert(1, 3))
    assert_false(s2.insert(1, 2))
    assert_equal(s2.size(), 2)
    assert_false(s2.contains(1, 4))

    var s3 = HashSet3[DType.int64, DType.int64, DType.int8]()
    assert_true(s3.insert(1, 2, 3))
    assert_false(s3.insert(1, 2, 3))
    assert_true(s3.insert(1, 2, 4))
    assert_equal(s3.size(), 2)
    assert_false(s3.contains(1, 2, 5))

    var s4 = HashSet4[DType.int64, DType.int64, DType.int64, DType.float64]()
    assert_true(s4.insert(1, 2, 3, 0.5))
    assert_false(s4.insert(1, 2, 3, 0.5))
    assert_true(s4.insert(1, 2, 3, 1.5))
    assert_equal(s4.size(), 2)
    assert_false(s4.contains(1, 2, 3, 2.5))


def test_hashset5_insert_duplicate_contains() raises:
    var s = HashSet5[DType.int64, DType.int64, DType.int64, DType.int64, DType.int16]()
    assert_equal(s.size(), 0)
    assert_true(s.insert(1, 2, 3, 4, 5))
    assert_true(s.insert(1, 2, 3, 4, 6))
    assert_false(s.insert(1, 2, 3, 4, 5))
    assert_equal(s.size(), 2)
    assert_true(s.contains(1, 2, 3, 4, 5))
    assert_true(s.contains(1, 2, 3, 4, 6))
    assert_false(s.contains(1, 2, 3, 4, 7))
    assert_false(s.contains(9, 2, 3, 4, 5))


def test_hashset6_size_and_miss() raises:
    var s = HashSet6[
        DType.int64, DType.int64, DType.int64, DType.int64, DType.int64, DType.int64,
    ]()
    assert_true(s.insert(1, 2, 3, 4, 5, 6))
    assert_false(s.insert(1, 2, 3, 4, 5, 6))
    assert_equal(s.size(), 1)
    assert_true(s.contains(1, 2, 3, 4, 5, 6))
    assert_false(s.contains(1, 2, 3, 4, 5, 7))


def test_hashset7_insert_duplicate_contains() raises:
    var s = HashSet7[
        DType.int64, DType.int64, DType.int64, DType.int64, DType.int64,
        DType.int64, DType.uint8,
    ]()
    assert_equal(s.size(), 0)
    assert_true(s.insert(1, 2, 3, 4, 5, 6, 7))
    assert_true(s.insert(1, 2, 3, 4, 5, 6, 8))
    assert_false(s.insert(1, 2, 3, 4, 5, 6, 7))
    assert_equal(s.size(), 2)
    assert_true(s.contains(1, 2, 3, 4, 5, 6, 7))
    assert_true(s.contains(1, 2, 3, 4, 5, 6, 8))
    assert_false(s.contains(1, 2, 3, 4, 5, 6, 9))
    assert_false(s.contains(0, 2, 3, 4, 5, 6, 7))


def test_hashset8_size() raises:
    var s = HashSet8[
        DType.int64, DType.int64, DType.int64, DType.int64,
        DType.int64, DType.int64, DType.int64, DType.int64,
    ]()
    assert_true(s.insert(1, 2, 3, 4, 5, 6, 7, 8))
    assert_true(s.insert(1, 2, 3, 4, 5, 6, 7, 9))
    assert_false(s.insert(1, 2, 3, 4, 5, 6, 7, 8))
    assert_equal(s.size(), 2)


# =============================================================================
# pack_3_byte_spans_u64: two-byte components in every position
# =============================================================================


def test_pack3_two_byte_components_round_trip() raises:
    var c0: List[UInt8] = [UInt8(0x01), UInt8(0xFE)]
    var c1: List[UInt8] = [UInt8(0x80), UInt8(0x7F)]
    var c2: List[UInt8] = [UInt8(0xFF), UInt8(0x00)]
    var p = pack_3_byte_spans_u64(Span(c0), Span(c1), Span(c2))
    assert_true(Bool(p))
    var u = unpack_3_byte_spans_u64(p.value())
    assert_equal(len(u[0]), 2)
    assert_equal(len(u[1]), 2)
    assert_equal(len(u[2]), 2)
    assert_equal(u[0][1], UInt8(0xFE))
    assert_equal(u[1][0], UInt8(0x80))
    assert_equal(u[1][1], UInt8(0x7F))
    assert_equal(u[2][0], UInt8(0xFF))
    assert_equal(u[2][1], UInt8(0x00))
    # A two-byte middle component that differs only in its second byte packs
    # to a different key.
    var c1b: List[UInt8] = [UInt8(0x80), UInt8(0x7E)]
    var q = pack_3_byte_spans_u64(Span(c0), Span(c1b), Span(c2))
    assert_true(p.value() != q.value())
    var c2b: List[UInt8] = [UInt8(0xFF), UInt8(0x01)]
    var r = pack_3_byte_spans_u64(Span(c0), Span(c1), Span(c2b))
    assert_true(p.value() != r.value())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
