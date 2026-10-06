# =============================================================================
# komira_hash/tests/test_fnv1a.mojo -- known-answer vectors for FNV-1a.
# =============================================================================
#
# The expected values are the published FNV-1a test vectors (empty, "a",
# "foobar") plus "foo" and a metric-style name, each cross-checked against an
# independent implementation.
# =============================================================================

from std.testing import assert_equal

from komira_hash import (
    FNV1A_32_OFFSET_BASIS,
    FNV1A_32_PRIME,
    FNV1A_64_OFFSET_BASIS,
    FNV1A_64_PRIME,
    fnv1a_32,
    fnv1a_64,
)


def test_constants() raises:
    assert_equal(FNV1A_32_OFFSET_BASIS, UInt32(0x811C9DC5))
    assert_equal(FNV1A_32_PRIME, UInt32(0x01000193))
    assert_equal(FNV1A_64_OFFSET_BASIS, UInt64(0xCBF29CE484222325))
    assert_equal(FNV1A_64_PRIME, UInt64(0x00000100000001B3))


def test_empty_is_the_offset_basis() raises:
    var s = String("")
    assert_equal(fnv1a_32(s.as_bytes()), FNV1A_32_OFFSET_BASIS)
    assert_equal(fnv1a_64(s.as_bytes()), FNV1A_64_OFFSET_BASIS)


def test_32_known_answers() raises:
    assert_equal(fnv1a_32(String("a").as_bytes()), UInt32(0xE40C292C))
    assert_equal(fnv1a_32(String("foo").as_bytes()), UInt32(0xA9F37ED7))
    assert_equal(fnv1a_32(String("foobar").as_bytes()), UInt32(0xBF9CF968))
    assert_equal(
        fnv1a_32(String("sixteen_byte_key").as_bytes()), UInt32(0x1B78B612)
    )


def test_64_known_answers() raises:
    assert_equal(fnv1a_64(String("a").as_bytes()), UInt64(0xAF63DC4C8601EC8C))
    assert_equal(fnv1a_64(String("foo").as_bytes()), UInt64(0xDCB27518FED9D577))
    assert_equal(
        fnv1a_64(String("foobar").as_bytes()), UInt64(0x85944171F73967E8)
    )
    assert_equal(
        fnv1a_64(String("sixteen_byte_key").as_bytes()),
        UInt64(0x6A4347AEE7EF58D2),
    )


def test_zero_byte_is_input() raises:
    # A zero byte is an input byte, not a terminator.
    var zero = List[UInt8]()
    zero.append(UInt8(0))
    assert_equal(fnv1a_32(Span(zero)), UInt32(0x050C5D1F))
    assert_equal(fnv1a_64(Span(zero)), UInt64(0xAF63BD4C8601B7DF))


def main() raises:
    test_constants()
    test_empty_is_the_offset_basis()
    test_32_known_answers()
    test_64_known_answers()
    test_zero_byte_is_input()
    print("all FNV-1a tests passed")
