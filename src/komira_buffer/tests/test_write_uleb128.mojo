# =============================================================================
# test_write_uleb128.mojo
#   The ULEB128 encoders: exact bytes for non-negative values, and a refusal of
#   a negative one.
# =============================================================================
#
# Defects caught:
#   - `write_uleb128` shifted arithmetically and stopped only at zero, so a
#     negative value appended bytes until the process ran out of memory. A
#     negative value must raise, append nothing and name the value. Each such
#     call arms a SIGALRM watchdog, so the old behaviour ends the process in
#     seconds (exit 142) instead of exhausting memory.
#   - A "fix" that cast a negative Int to UInt64 would write a ten-byte varint
#     that decodes to a different number; the raise tests and the exact-bytes
#     tests together rule that out.
#   - Any change of the byte layout: the expected bytes below are computed by
#     hand (seven payload bits per byte, low group first, high bit set on every
#     byte but the last), and they are the same for the Int and UInt64 forms.
# =============================================================================

from std.ffi import external_call
from std.testing import TestSuite, assert_equal, assert_true

from komira_buffer.byte_buffer import (
    ByteBuffer,
    write_uleb128,
    write_uleb128_u64,
)

comptime _WATCHDOG_S = 5
comptime _MAX_I64: Int = 9223372036854775807
comptime _MIN_I64: Int = -9223372036854775807 - 1
comptime _MAX_U64: UInt64 = 18446744073709551615


def _b(*bytes: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for b in bytes:
        out.append(UInt8(b))
    return out^


def _encode(value: Int) raises -> List[UInt8]:
    var out = List[UInt8]()
    write_uleb128(value, out)
    return out^


def _encode_u64(value: UInt64) -> List[UInt8]:
    var out = List[UInt8]()
    write_uleb128_u64(value, out)
    return out^


def _check(value: Int, expected: List[UInt8]) raises:
    assert_equal(_encode(value), expected, "write_uleb128(" + String(value) + ")")
    assert_equal(
        _encode_u64(UInt64(value)),
        expected,
        "write_uleb128_u64(" + String(value) + ")",
    )


def test_exact_bytes() raises:
    _check(0, _b(0x00))
    _check(1, _b(0x01))
    _check(127, _b(0x7F))
    _check(128, _b(0x80, 0x01))
    _check(300, _b(0xAC, 0x02))
    _check(16383, _b(0xFF, 0x7F))
    _check(16384, _b(0x80, 0x80, 0x01))
    _check(2147483647, _b(0xFF, 0xFF, 0xFF, 0xFF, 0x07))
    _check(2147483648, _b(0x80, 0x80, 0x80, 0x80, 0x08))
    _check(4294967295, _b(0xFF, 0xFF, 0xFF, 0xFF, 0x0F))
    _check(4294967296, _b(0x80, 0x80, 0x80, 0x80, 0x10))
    # 2^28 - 1 is four bytes, 2^28 is five; 2^56 is nine bytes.
    _check(268435455, _b(0xFF, 0xFF, 0xFF, 0x7F))
    _check(268435456, _b(0x80, 0x80, 0x80, 0x80, 0x01))
    _check(
        72057594037927936,
        _b(0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01),
    )
    _check(
        _MAX_I64,
        _b(0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F),
    )


def test_exact_bytes_u64_top_bit() raises:
    # 2^64 - 1 needs all ten bytes: nine of 0xFF, then the single top bit.
    assert_equal(
        _encode_u64(_MAX_U64),
        _b(0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01),
    )
    # 2^63: seven zero groups of payload, nine bytes, then 0x01.
    assert_equal(
        _encode_u64(UInt64(1) << UInt64(63)),
        _b(0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01),
    )


def test_appends_after_existing_bytes() raises:
    var out = _b(0xEE, 0xDD)
    write_uleb128(128, out)
    write_uleb128_u64(UInt64(5), out)
    assert_equal(out, _b(0xEE, 0xDD, 0x80, 0x01, 0x05))


def test_round_trips_through_the_reader() raises:
    var values = List[Int]()
    values.append(0)
    values.append(127)
    values.append(128)
    values.append(16384)
    values.append(2147483647)
    values.append(_MAX_I64)
    for i in range(len(values)):
        var bb = ByteBuffer(_encode(values[i]))
        assert_equal(bb.read_uleb128(), values[i])
        assert_equal(bb.remaining(), 0)


def _expect_negative_refused(value: Int) raises:
    var out = _b(0x42)
    var refused = False
    var message = String("")
    _ = external_call["alarm", UInt32](UInt32(_WATCHDOG_S))
    try:
        write_uleb128(value, out)
    except e:
        refused = True
        message = String(e)
    _ = external_call["alarm", UInt32](UInt32(0))
    assert_true(refused, "write_uleb128(" + String(value) + ") must raise")
    assert_true(
        message.startswith("write_uleb128: negative value " + String(value)),
        "the error must name the value " + String(value) + ": " + message,
    )
    assert_equal(out, _b(0x42), "a refused value appends nothing")


def test_minus_one_raises() raises:
    _expect_negative_refused(-1)


def test_int_min_raises() raises:
    _expect_negative_refused(_MIN_I64)


def test_zero_is_not_refused() raises:
    assert_equal(_encode(0), _b(0x00))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
