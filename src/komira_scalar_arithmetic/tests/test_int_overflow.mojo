# =============================================================================
# INTEGER OVERFLOW: the lane-wise add / sub verdict bits, the exact scalar
# predicates for every width, the Float64 multiplication screen, and the
# checked ops with DuckDB's sentence.
#
# Oracle: two's complement. A signed W-bit integer holds [-2^(W-1),
# 2^(W-1) - 1], an unsigned one [0, 2^W - 1]; a sum, difference or product
# overflows exactly when its true integer value leaves that range. Each width
# gets the boundary on both sides (the last value that fits and the first
# that does not). The message is DuckDB 1.5.3's, as `int_overflow.mojo`
# records it: `Out of Range Error: Overflow in <op> of <TYPE> (<a> <sym> <b>)!`.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_scalar_arithmetic.int_overflow import (
    INT_OVERFLOW_ERROR_PREFIX,
    int_type_name,
    int_overflow_message,
    is_int_overflow_error,
    add_overflow_bits,
    sub_overflow_bits,
    top_bit_set,
    mul_screen_limit,
    mul_screen,
    add_overflows,
    sub_overflows,
    mul_overflows,
    checked_add,
    checked_sub,
    checked_mul,
)


# Each product call goes through a @no_inline wrapper: its arguments are then
# runtime values, so the compiler cannot fold an @always_inline body at a
# constant call site and the coverage run sees every arm the test takes.

@no_inline
def _rt_add_overflow_bits[dtype: DType, w: Int](a: SIMD[dtype, w], b: SIMD[dtype, w], r: SIMD[dtype, w]) raises -> SIMD[dtype, w]:
    return add_overflow_bits[dtype, w](a, b, r)


@no_inline
def _rt_sub_overflow_bits[dtype: DType, w: Int](a: SIMD[dtype, w], b: SIMD[dtype, w], r: SIMD[dtype, w]) raises -> SIMD[dtype, w]:
    return sub_overflow_bits[dtype, w](a, b, r)


@no_inline
def _rt_top_bit_set[dtype: DType](bits: Scalar[dtype]) raises -> Bool:
    return top_bit_set[dtype](bits)


@no_inline
def _rt_mul_screen[dtype: DType, w: Int](a: SIMD[dtype, w], b: SIMD[dtype, w]) raises -> SIMD[DType.float64, w]:
    return mul_screen[dtype, w](a, b)


@no_inline
def _rt_add_overflows[dtype: DType](a: Scalar[dtype], b: Scalar[dtype]) raises -> Bool:
    return add_overflows[dtype](a, b)


@no_inline
def _rt_sub_overflows[dtype: DType](a: Scalar[dtype], b: Scalar[dtype]) raises -> Bool:
    return sub_overflows[dtype](a, b)


@no_inline
def _rt_mul_overflows[dtype: DType](a: Scalar[dtype], b: Scalar[dtype]) raises -> Bool:
    # The verdict is consumed by a raise, as `checked_mul` consumes it: the
    # branch classifier refuses a returned `or` (komira-ai/komira#872), and a
    # bare `if v: return True` folds back into one.
    try:
        if mul_overflows[dtype](a, b):
            raise Error("overflow")
    except:
        return True
    return False


@no_inline
def _rt_checked_add[dtype: DType](a: Scalar[dtype], b: Scalar[dtype]) raises -> Scalar[dtype]:
    return checked_add[dtype](a, b)


@no_inline
def _rt_checked_sub[dtype: DType](a: Scalar[dtype], b: Scalar[dtype]) raises -> Scalar[dtype]:
    return checked_sub[dtype](a, b)


@no_inline
def _rt_checked_mul[dtype: DType](a: Scalar[dtype], b: Scalar[dtype]) raises -> Scalar[dtype]:
    return checked_mul[dtype](a, b)


# --- names and the sentence ------------------------------------------------------


def test_type_names() raises:
    """DuckDB's physical spellings; any other dtype falls back to its own name."""
    assert_equal(int_type_name[DType.int64](), "INT64")
    assert_equal(int_type_name[DType.int32](), "INT32")
    assert_equal(int_type_name[DType.int16](), "INT16")
    assert_equal(int_type_name[DType.int8](), "INT8")
    assert_equal(int_type_name[DType.uint64](), "UINT64")
    assert_equal(int_type_name[DType.uint32](), "UINT32")
    assert_equal(int_type_name[DType.uint16](), "UINT16")
    assert_equal(int_type_name[DType.uint8](), "UINT8")
    assert_equal(int_type_name[DType.float32](), String(DType.float32))


def test_overflow_message_and_recogniser() raises:
    var m = int_overflow_message[DType.int64]("addition", Int64.MAX, "+", Int64(1))
    assert_equal(m, "Out of Range Error: Overflow in addition of INT64 (9223372036854775807 + 1)!")
    assert_true(m.startswith(INT_OVERFLOW_ERROR_PREFIX))
    assert_true(is_int_overflow_error(m))
    # Embedded in a longer message, it is still recognised.
    assert_true(is_int_overflow_error("column c: " + m))
    assert_false(is_int_overflow_error(""))
    assert_false(is_int_overflow_error("Decimal128 overflow in add: result exceeds DECIMAL128(38,...) range"))
    assert_false(is_int_overflow_error("Overflow in addition of INT64 (1 + 1)!"))
    var u = int_overflow_message[DType.uint8]("subtraction", UInt8(0), "-", UInt8(1))
    assert_equal(u, "Out of Range Error: Overflow in subtraction of UINT8 (0 - 1)!")


# --- lane-wise bits ------------------------------------------------------------------


def test_signed_add_and_sub_bits_per_lane() raises:
    """INT32 lanes: MAX+1 and MIN+(-1) overflow, 1+1 and -1+(-1) do not;
    MIN-1, 0-MIN and MAX-(-1) overflow, 5-5 does not."""
    var a = SIMD[DType.int32, 4](Int32.MAX, 1, Int32.MIN, -1)
    var b = SIMD[DType.int32, 4](1, 1, -1, -1)
    var bits = _rt_add_overflow_bits[DType.int32, 4](a, b, a + b)
    assert_true(_rt_top_bit_set[DType.int32](bits[0]))
    assert_false(_rt_top_bit_set[DType.int32](bits[1]))
    assert_true(_rt_top_bit_set[DType.int32](bits[2]))
    assert_false(_rt_top_bit_set[DType.int32](bits[3]))
    # OR-accumulated across the lanes, one test answers for the column.
    assert_true(_rt_top_bit_set[DType.int32](bits.reduce_or()))
    var sa = SIMD[DType.int32, 4](Int32.MIN, 0, Int32.MAX, 5)
    var sb = SIMD[DType.int32, 4](1, Int32.MIN, -1, 5)
    var sbits = _rt_sub_overflow_bits[DType.int32, 4](sa, sb, sa - sb)
    assert_true(_rt_top_bit_set[DType.int32](sbits[0]))
    assert_true(_rt_top_bit_set[DType.int32](sbits[1]))
    assert_true(_rt_top_bit_set[DType.int32](sbits[2]))
    assert_false(_rt_top_bit_set[DType.int32](sbits[3]))
    var calm = SIMD[DType.int32, 4](1, 2, -3, 4)
    assert_false(
        _rt_top_bit_set[DType.int32](_rt_add_overflow_bits[DType.int32, 4](calm, calm, calm + calm).reduce_or())
    )


def test_unsigned_add_and_sub_bits_per_lane() raises:
    """UINT16 lanes: 65535+1 and 32768+32768 carry; 1+1 and 32768+32767 do not.
    0-1 and 5-6 borrow; 5-5 and 65535-65535 do not."""
    var a = SIMD[DType.uint16, 4](65535, 1, 32768, 32768)
    var b = SIMD[DType.uint16, 4](1, 1, 32768, 32767)
    var bits = _rt_add_overflow_bits[DType.uint16, 4](a, b, a + b)
    assert_true(_rt_top_bit_set[DType.uint16](bits[0]))
    assert_false(_rt_top_bit_set[DType.uint16](bits[1]))
    assert_true(_rt_top_bit_set[DType.uint16](bits[2]))
    assert_false(_rt_top_bit_set[DType.uint16](bits[3]))
    var sa = SIMD[DType.uint16, 4](0, 5, 5, 65535)
    var sb = SIMD[DType.uint16, 4](1, 5, 6, 65535)
    var sbits = _rt_sub_overflow_bits[DType.uint16, 4](sa, sb, sa - sb)
    assert_true(_rt_top_bit_set[DType.uint16](sbits[0]))
    assert_false(_rt_top_bit_set[DType.uint16](sbits[1]))
    assert_true(_rt_top_bit_set[DType.uint16](sbits[2]))
    assert_false(_rt_top_bit_set[DType.uint16](sbits[3]))


def test_top_bit_set() raises:
    assert_true(_rt_top_bit_set[DType.int8](Int8(-128)))
    assert_true(_rt_top_bit_set[DType.int8](Int8(-1)))
    assert_false(_rt_top_bit_set[DType.int8](Int8(127)))
    assert_false(_rt_top_bit_set[DType.int8](Int8(0)))
    assert_true(_rt_top_bit_set[DType.uint8](UInt8(128)))
    assert_false(_rt_top_bit_set[DType.uint8](UInt8(127)))
    assert_true(_rt_top_bit_set[DType.uint64](UInt64(1) << 63))
    assert_false(_rt_top_bit_set[DType.uint64](UInt64.MAX >> 1))


# --- the multiplication screen ----------------------------------------------------


def test_mul_screen_limits() raises:
    """Up to 32 bits the limit is the type's bound; at 64 bits one binade lower."""
    assert_equal(mul_screen_limit[DType.int8](), 128.0)
    assert_equal(mul_screen_limit[DType.int16](), 32768.0)
    assert_equal(mul_screen_limit[DType.int32](), 2147483648.0)
    assert_equal(mul_screen_limit[DType.int64](), 4611686018427387904.0)
    assert_equal(mul_screen_limit[DType.uint8](), 256.0)
    assert_equal(mul_screen_limit[DType.uint16](), 65536.0)
    assert_equal(mul_screen_limit[DType.uint32](), 4294967296.0)
    assert_equal(mul_screen_limit[DType.uint64](), 9223372036854775808.0)


def test_mul_screen_magnitudes() raises:
    var s = _rt_mul_screen[DType.int32, 4](
        SIMD[DType.int32, 4](-3, 4, Int32.MIN, 0),
        SIMD[DType.int32, 4](5, -6, -1, 7),
    )
    assert_equal(s[0], 15.0)
    assert_equal(s[1], 24.0)
    assert_equal(s[2], 2147483648.0)
    assert_equal(s[3], 0.0)
    # MIN * -1 is the one INT32 product at the limit, and it overflows.
    assert_true(s[2] >= mul_screen_limit[DType.int32]())
    assert_true(_rt_mul_overflows[DType.int32](Int32.MIN, Int32(-1)))


# --- signed predicates, every width -------------------------------------------------


def test_signed_add_sub_predicates() raises:
    assert_true(_rt_add_overflows[DType.int8](Int8.MAX, Int8(1)))
    assert_true(_rt_add_overflows[DType.int8](Int8.MIN, Int8(-1)))
    assert_true(_rt_add_overflows[DType.int8](Int8.MIN, Int8.MIN))
    assert_false(_rt_add_overflows[DType.int8](Int8.MAX, Int8(0)))
    assert_false(_rt_add_overflows[DType.int8](Int8.MAX, Int8.MIN))
    assert_true(_rt_add_overflows[DType.int16](Int16.MAX, Int16(1)))
    assert_false(_rt_add_overflows[DType.int16](Int16(32766), Int16(1)))
    assert_true(_rt_add_overflows[DType.int32](Int32.MIN, Int32(-1)))
    assert_false(_rt_add_overflows[DType.int32](Int32.MIN, Int32(0)))
    assert_true(_rt_add_overflows[DType.int64](Int64.MAX, Int64(1)))
    assert_false(_rt_add_overflows[DType.int64](Int64.MAX, Int64(-1)))
    assert_true(_rt_sub_overflows[DType.int8](Int8.MIN, Int8(1)))
    assert_true(_rt_sub_overflows[DType.int8](Int8(0), Int8.MIN))
    assert_false(_rt_sub_overflows[DType.int8](Int8(-1), Int8.MIN))
    assert_true(_rt_sub_overflows[DType.int16](Int16.MAX, Int16(-1)))
    assert_false(_rt_sub_overflows[DType.int16](Int16.MAX, Int16(0)))
    assert_true(_rt_sub_overflows[DType.int32](Int32.MIN, Int32(1)))
    assert_false(_rt_sub_overflows[DType.int32](Int32.MIN, Int32(-1)))
    assert_true(_rt_sub_overflows[DType.int64](Int64(0), Int64.MIN))
    assert_false(_rt_sub_overflows[DType.int64](Int64(-1), Int64.MIN))


def test_signed_mul_predicates() raises:
    """At the square-root edge and the MIN corners of each width."""
    assert_false(_rt_mul_overflows[DType.int8](Int8(11), Int8(11)))
    assert_true(_rt_mul_overflows[DType.int8](Int8(12), Int8(11)))
    assert_false(_rt_mul_overflows[DType.int8](Int8(-16), Int8(8)))
    assert_true(_rt_mul_overflows[DType.int8](Int8(-16), Int8(-8)))
    assert_true(_rt_mul_overflows[DType.int8](Int8(-16), Int8(9)))
    assert_true(_rt_mul_overflows[DType.int8](Int8.MIN, Int8(-1)))
    assert_false(_rt_mul_overflows[DType.int16](Int16(181), Int16(181)))
    assert_true(_rt_mul_overflows[DType.int16](Int16(182), Int16(181)))
    assert_false(_rt_mul_overflows[DType.int32](Int32(46340), Int32(46340)))
    assert_true(_rt_mul_overflows[DType.int32](Int32(46341), Int32(46341)))
    assert_false(_rt_mul_overflows[DType.int32](Int32(-65536), Int32(32768)))
    assert_true(_rt_mul_overflows[DType.int32](Int32(65536), Int32(32768)))
    assert_false(_rt_mul_overflows[DType.int64](Int64(3037000499), Int64(3037000499)))
    assert_true(_rt_mul_overflows[DType.int64](Int64(3037000500), Int64(3037000500)))
    assert_false(_rt_mul_overflows[DType.int64](Int64(-2147483648), Int64(4294967296)))
    assert_true(_rt_mul_overflows[DType.int64](Int64(2147483648), Int64(4294967296)))
    assert_true(_rt_mul_overflows[DType.int64](Int64.MIN, Int64(-1)))
    # Below MIN, not above MAX: the second half of the range test.
    assert_true(_rt_mul_overflows[DType.int64](Int64(-3037000500), Int64(3037000500)))
    assert_true(_rt_mul_overflows[DType.int64](Int64.MIN, Int64(2)))
    assert_false(_rt_mul_overflows[DType.int64](Int64(-4611686018427387904), Int64(2)))
    assert_false(_rt_mul_overflows[DType.int64](Int64.MAX, Int64(-1)))


# --- unsigned predicates, every width -----------------------------------------------


def test_unsigned_add_sub_predicates() raises:
    assert_true(_rt_add_overflows[DType.uint8](UInt8.MAX, UInt8(1)))
    assert_true(_rt_add_overflows[DType.uint8](UInt8(128), UInt8(128)))
    assert_false(_rt_add_overflows[DType.uint8](UInt8(128), UInt8(127)))
    assert_true(_rt_add_overflows[DType.uint32](UInt32.MAX, UInt32(1)))
    assert_false(_rt_add_overflows[DType.uint32](UInt32.MAX, UInt32(0)))
    assert_true(_rt_add_overflows[DType.uint64](UInt64.MAX, UInt64.MAX))
    assert_false(_rt_add_overflows[DType.uint64](UInt64(1) << 63, (UInt64(1) << 63) - 1))
    assert_true(_rt_sub_overflows[DType.uint8](UInt8(0), UInt8(1)))
    assert_true(_rt_sub_overflows[DType.uint8](UInt8(0), UInt8.MAX))
    assert_false(_rt_sub_overflows[DType.uint8](UInt8.MAX, UInt8.MAX))
    assert_true(_rt_sub_overflows[DType.uint32](UInt32(5), UInt32(6)))
    assert_false(_rt_sub_overflows[DType.uint32](UInt32(6), UInt32(5)))
    assert_true(_rt_sub_overflows[DType.uint64](UInt64(0), UInt64(1)))
    assert_false(_rt_sub_overflows[DType.uint64](UInt64.MAX, UInt64(1)))


def test_unsigned_mul_predicates() raises:
    """15 * 17 = 255 fits UINT8, 16 * 16 = 256 does not; (2^32-1)(2^32+1) =
    2^64 - 1 fits UINT64, 2^32 * 2^32 does not."""
    assert_false(_rt_mul_overflows[DType.uint8](UInt8(15), UInt8(17)))
    assert_true(_rt_mul_overflows[DType.uint8](UInt8(16), UInt8(16)))
    assert_false(_rt_mul_overflows[DType.uint16](UInt16(255), UInt16(257)))
    assert_true(_rt_mul_overflows[DType.uint16](UInt16(256), UInt16(256)))
    assert_false(_rt_mul_overflows[DType.uint32](UInt32(65535), UInt32(65537)))
    assert_true(_rt_mul_overflows[DType.uint32](UInt32(65536), UInt32(65536)))
    assert_false(_rt_mul_overflows[DType.uint64](UInt64(4294967295), UInt64(4294967297)))
    assert_true(_rt_mul_overflows[DType.uint64](UInt64(4294967296), UInt64(4294967296)))
    assert_false(_rt_mul_overflows[DType.uint64](UInt64.MAX, UInt64(1)))
    assert_false(_rt_mul_overflows[DType.uint64](UInt64.MAX, UInt64(0)))


def test_float_predicates_never_overflow() raises:
    """A float operation is IEEE: the integer predicates answer False."""
    assert_false(_rt_add_overflows[DType.float64](Float64(1.0e308), Float64(1.0e308)))
    assert_false(_rt_sub_overflows[DType.float64](Float64(-1.0e308), Float64(1.0e308)))
    assert_false(_rt_mul_overflows[DType.float64](Float64(1.0e200), Float64(1.0e200)))


# --- checked ops ------------------------------------------------------------------


def test_checked_ops_return_exact_values() raises:
    assert_equal(_rt_checked_add[DType.int64](Int64(2), Int64(3)), Int64(5))
    assert_equal(_rt_checked_sub[DType.int32](Int32(2), Int32(5)), Int32(-3))
    assert_equal(_rt_checked_mul[DType.int16](Int16(-181), Int16(181)), Int16(-32761))
    assert_equal(_rt_checked_add[DType.uint8](UInt8(200), UInt8(55)), UInt8(255))
    assert_equal(_rt_checked_sub[DType.uint64](UInt64(7), UInt64(7)), UInt64(0))
    assert_equal(_rt_checked_mul[DType.uint32](UInt32(65535), UInt32(65537)), UInt32.MAX)
    assert_equal(_rt_checked_mul[DType.int8](Int8(-16), Int8(8)), Int8.MIN)


def test_checked_ops_raise_duckdb_sentences() raises:
    var add_msg = String("")
    try:
        _ = _rt_checked_add[DType.int64](Int64.MAX, Int64(1))
    except e:
        add_msg = String(e)
    assert_equal(add_msg, "Out of Range Error: Overflow in addition of INT64 (9223372036854775807 + 1)!")
    var sub_msg = String("")
    try:
        _ = _rt_checked_sub[DType.int32](Int32.MIN, Int32(1))
    except e:
        sub_msg = String(e)
    assert_equal(sub_msg, "Out of Range Error: Overflow in subtraction of INT32 (-2147483648 - 1)!")
    var mul_msg = String("")
    try:
        _ = _rt_checked_mul[DType.int8](Int8(12), Int8(11))
    except e:
        mul_msg = String(e)
    assert_equal(mul_msg, "Out of Range Error: Overflow in multiplication of INT8 (12 * 11)!")
    var umul = String("")
    try:
        _ = _rt_checked_mul[DType.uint64](UInt64(4294967296), UInt64(4294967296))
    except e:
        umul = String(e)
    assert_equal(
        umul,
        "Out of Range Error: Overflow in multiplication of UINT64 (4294967296 * 4294967296)!",
    )
    var usub = String("")
    try:
        _ = _rt_checked_sub[DType.uint16](UInt16(0), UInt16(1))
    except e:
        usub = String(e)
    assert_equal(usub, "Out of Range Error: Overflow in subtraction of UINT16 (0 - 1)!")
    assert_true(is_int_overflow_error(add_msg))
    assert_true(is_int_overflow_error(umul))


def test_checked_float_ops_are_ieee() raises:
    """No raise; 1e308 + 1e308 is +inf, 1e308 - (-1e308) is +inf, 0.5 * 4 = 2."""
    var inf = Float64(1.0) / Float64(0.0)
    assert_equal(_rt_checked_add[DType.float64](Float64(1.0e308), Float64(1.0e308)), inf)
    assert_equal(_rt_checked_sub[DType.float64](Float64(1.0e308), Float64(-1.0e308)), inf)
    assert_equal(_rt_checked_mul[DType.float64](Float64(0.5), Float64(4.0)), Float64(2.0))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
