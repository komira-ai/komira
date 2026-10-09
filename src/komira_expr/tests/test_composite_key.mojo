# =============================================================================
# Unit tests for composite_key.mojo: ColumnValue, KeyValue1..4, the FNV-1a
# hash helpers and the element-wise equality helpers
# =============================================================================
#
# Oracle: FNV-1a 64-bit (offset 0xcbf29ce484222325, prime 0x100000001b3).
# The String expectations are the published FNV-1a 64 test vectors
# ("" -> 0xcbf29ce484222325, "a" -> 0xaf63dc4c8601ec8c,
# "foobar" -> 0x85944171f73967e8). Int64 components hash their eight bytes
# little-endian, Bool one byte 0x00 / 0x01, as the `_hash_column_value`
# docstring states; those expectations were folded by hand with the same
# step (offset, then `(h ^ byte) * prime mod 2^64` per byte).
#
# Float64: the docstring says "the 8 bytes of the IEEE-754 bit pattern", the
# body converts the value to Int64 (`cast[DType.int64]`), which truncates
# (1.5 and 1.0 fold the same bytes). The two readings agree only at +0.0, so
# that is the one Float64 hash pinned exactly; elsewhere this file asserts
# only what both readings give. The disagreement is reported, not pinned.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_expr.composite_key import (
    CVT_INT64,
    CVT_FLOAT64,
    CVT_STRING,
    CVT_BOOL,
    FNV_OFFSET,
    FNV_PRIME,
    ColumnValue,
    KeyValue1,
    KeyValue2,
    KeyValue3,
    KeyValue4,
    hash_key_value1,
    hash_key_value2,
    hash_key_value3,
    hash_key_value4,
    eq_key_value1,
    eq_key_value2,
    eq_key_value3,
    eq_key_value4,
)


def _i(v: Int) -> ColumnValue:
    return ColumnValue(Int64(v))


def _f(v: Float64) -> ColumnValue:
    return ColumnValue(v)


def _s(v: String) -> ColumnValue:
    return ColumnValue(v)


def _b(v: Bool) -> ColumnValue:
    return ColumnValue(v)


# =============================================================================
# ColumnValue
# =============================================================================


def test_tags_and_fnv_constants() raises:
    assert_equal(CVT_INT64, UInt8(8))
    assert_equal(CVT_FLOAT64, UInt8(12))
    assert_equal(CVT_STRING, UInt8(14))
    assert_equal(CVT_BOOL, UInt8(3))
    assert_equal(FNV_OFFSET, UInt64(0xCBF29CE484222325))
    assert_equal(FNV_PRIME, UInt64(0x100000001B3))


def test_column_value_each_arm_reads_back() raises:
    """Each ctor sets its tag and its own payload."""
    var i = _i(-42)
    assert_equal(i.kind(), CVT_INT64)
    assert_equal(i.as_i64(), Int64(-42))
    var f = _f(2.5)
    assert_equal(f.kind(), CVT_FLOAT64)
    assert_equal(f.as_f64(), 2.5)
    var s = _s("key")
    assert_equal(s.kind(), CVT_STRING)
    assert_equal(s.as_str(), "key")
    var b = _b(True)
    assert_equal(b.kind(), CVT_BOOL)
    assert_true(b.as_bool())


def test_column_value_wrong_arm_reads_fallback() raises:
    """The documented fallback: reading an arm that is not active gives the
    zero value (0, 0.0, "", False), never the other arm's payload."""
    var i = _i(7)
    assert_equal(i.as_f64(), 0.0)
    assert_equal(i.as_str(), "")
    assert_false(i.as_bool())
    var f = _f(7.0)
    assert_equal(f.as_i64(), Int64(0))
    var s = _s("7")
    assert_equal(s.as_i64(), Int64(0))
    var b = _b(True)
    assert_equal(b.as_i64(), Int64(0))
    assert_equal(b.as_str(), "")


# =============================================================================
# Hash
# =============================================================================


def test_hash_string_published_vectors() raises:
    assert_equal(hash_key_value1(KeyValue1(_s(""))), UInt64(0xCBF29CE484222325))
    assert_equal(hash_key_value1(KeyValue1(_s("a"))), UInt64(0xAF63DC4C8601EC8C))
    assert_equal(
        hash_key_value1(KeyValue1(_s("foobar"))), UInt64(0x85944171F73967E8)
    )


def test_hash_int64_little_endian_bytes() raises:
    assert_equal(hash_key_value1(KeyValue1(_i(1))), UInt64(0x89CD31291D2AEFA4))
    assert_equal(hash_key_value1(KeyValue1(_i(-1))), UInt64(0x8CF51A8BFCA3883D))
    # Distinct bytes in every position: catches a shift or byte-order slip.
    assert_equal(
        hash_key_value1(KeyValue1(ColumnValue(Int64(0x0102030405060708)))),
        UInt64(0x0C6D4496E17859D5),
    )
    assert_equal(hash_key_value1(KeyValue1(_i(0))), UInt64(0xA8C7F832281A39C5))


def test_hash_bool_one_byte() raises:
    assert_equal(hash_key_value1(KeyValue1(_b(True))), UInt64(0xAF63BC4C8601B62C))
    assert_equal(
        hash_key_value1(KeyValue1(_b(False))), UInt64(0xAF63BD4C8601B7DF)
    )


def test_hash_float64_zero_and_consistency() raises:
    """+0.0 is eight zero bytes under both readings (bit pattern and value
    conversion); 2.0 and 3.0 differ under both; equal values hash equal."""
    assert_equal(hash_key_value1(KeyValue1(_f(0.0))), UInt64(0xA8C7F832281A39C5))
    var h2 = hash_key_value1(KeyValue1(_f(2.0)))
    assert_equal(h2, hash_key_value1(KeyValue1(_f(2.0))))
    assert_true(h2 != hash_key_value1(KeyValue1(_f(3.0))))
    assert_true(h2 != hash_key_value1(KeyValue1(_f(0.0))))


def test_hash_unknown_tag_folds_nothing() raises:
    """A tag outside the four arms adds no byte: the hash is the offset."""
    var cv = _i(5)
    cv.tag = UInt8(99)
    assert_equal(hash_key_value1(KeyValue1(cv^)), FNV_OFFSET)


def test_hash_multi_component_order_matters() raises:
    """Components fold left to right into one running state."""
    assert_equal(
        hash_key_value2(KeyValue2(_s("a"), _i(1))), UInt64(0xDEDF9F982E43402D)
    )
    assert_equal(
        hash_key_value2(KeyValue2(_i(1), _s("a"))), UInt64(0x529A4DDC8FF56BBF)
    )
    assert_equal(
        hash_key_value3(KeyValue3(_s("a"), _i(1), _b(True))),
        UInt64(0xF93C5B969C460AC4),
    )
    assert_equal(
        hash_key_value4(KeyValue4(_s("a"), _i(1), _b(True), _f(0.0))),
        UInt64(0x6334B64A19200B44),
    )


# =============================================================================
# Equality
# =============================================================================


def test_eq_each_arm() raises:
    assert_true(eq_key_value1(KeyValue1(_i(3)), KeyValue1(_i(3))))
    assert_false(eq_key_value1(KeyValue1(_i(3)), KeyValue1(_i(4))))
    assert_true(eq_key_value1(KeyValue1(_f(1.5)), KeyValue1(_f(1.5))))
    assert_false(eq_key_value1(KeyValue1(_f(1.5)), KeyValue1(_f(1.25))))
    assert_true(eq_key_value1(KeyValue1(_s("x")), KeyValue1(_s("x"))))
    assert_false(eq_key_value1(KeyValue1(_s("x")), KeyValue1(_s("xy"))))
    assert_true(eq_key_value1(KeyValue1(_b(False)), KeyValue1(_b(False))))
    assert_false(eq_key_value1(KeyValue1(_b(False)), KeyValue1(_b(True))))


def test_eq_tag_mismatch_is_false() raises:
    """Int64 0 and Bool False have equal zero payloads; different tags are
    still unequal (the docstring's heterogeneous rule)."""
    assert_false(eq_key_value1(KeyValue1(_i(0)), KeyValue1(_b(False))))
    assert_false(eq_key_value1(KeyValue1(_i(1)), KeyValue1(_f(1.0))))


def test_eq_unknown_tag_is_false() raises:
    """Two cells with the same tag outside the four arms are unequal."""
    var a = _i(5)
    var b = _i(5)
    a.tag = UInt8(99)
    b.tag = UInt8(99)
    assert_false(eq_key_value1(KeyValue1(a^), KeyValue1(b^)))


def test_eq_multi_component_each_position_decides() raises:
    """Equal tuples are equal; a difference at any one position makes them
    unequal (each early return and the final component are exercised)."""
    assert_true(eq_key_value2(KeyValue2(_i(1), _s("a")), KeyValue2(_i(1), _s("a"))))
    assert_false(
        eq_key_value2(KeyValue2(_i(2), _s("a")), KeyValue2(_i(1), _s("a")))
    )
    assert_false(
        eq_key_value2(KeyValue2(_i(1), _s("b")), KeyValue2(_i(1), _s("a")))
    )

    assert_true(
        eq_key_value3(
            KeyValue3(_i(1), _s("a"), _b(True)),
            KeyValue3(_i(1), _s("a"), _b(True)),
        )
    )
    assert_false(
        eq_key_value3(
            KeyValue3(_i(9), _s("a"), _b(True)),
            KeyValue3(_i(1), _s("a"), _b(True)),
        )
    )
    assert_false(
        eq_key_value3(
            KeyValue3(_i(1), _s("z"), _b(True)),
            KeyValue3(_i(1), _s("a"), _b(True)),
        )
    )
    assert_false(
        eq_key_value3(
            KeyValue3(_i(1), _s("a"), _b(False)),
            KeyValue3(_i(1), _s("a"), _b(True)),
        )
    )

    assert_true(
        eq_key_value4(
            KeyValue4(_i(1), _s("a"), _b(True), _f(0.5)),
            KeyValue4(_i(1), _s("a"), _b(True), _f(0.5)),
        )
    )
    assert_false(
        eq_key_value4(
            KeyValue4(_i(9), _s("a"), _b(True), _f(0.5)),
            KeyValue4(_i(1), _s("a"), _b(True), _f(0.5)),
        )
    )
    assert_false(
        eq_key_value4(
            KeyValue4(_i(1), _s("z"), _b(True), _f(0.5)),
            KeyValue4(_i(1), _s("a"), _b(True), _f(0.5)),
        )
    )
    assert_false(
        eq_key_value4(
            KeyValue4(_i(1), _s("a"), _b(False), _f(0.5)),
            KeyValue4(_i(1), _s("a"), _b(True), _f(0.5)),
        )
    )
    assert_false(
        eq_key_value4(
            KeyValue4(_i(1), _s("a"), _b(True), _f(0.75)),
            KeyValue4(_i(1), _s("a"), _b(True), _f(0.5)),
        )
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
