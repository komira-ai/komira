# =============================================================================
# komira_hash/tests/test_fnv1a.mojo -- known-answer vectors for FNV-1a.
# =============================================================================
#
# The expected values are the published FNV-1a test vectors (empty, "a",
# "foobar") plus "foo" and a 16-byte key, each cross-checked against an
# independent implementation. Inputs of 17, 31 and 64 bytes catch a hash that
# stops after a fixed prefix; inputs with bytes >= 0x80 catch a byte widened
# with sign extension instead of zero extension.
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


def _repeat_hex_digits(times: Int) -> List[UInt8]:
    # "0123456789abcdef" repeated `times` times, as bytes.
    var digits = String("0123456789abcdef").as_bytes()
    var out = List[UInt8]()
    for _ in range(times):
        for i in range(len(digits)):
            out.append(digits[i])
    return out^


def test_inputs_longer_than_16_bytes() raises:
    # Each expected value depends on every byte; a hash that reads only the
    # first 16 bytes returns the "sixteen_byte_key" value for the first case.
    var seventeen = String("sixteen_byte_key!")
    assert_equal(len(seventeen.as_bytes()), 17)
    assert_equal(fnv1a_32(seventeen.as_bytes()), UInt32(0x7206D249))
    assert_equal(fnv1a_64(seventeen.as_bytes()), UInt64(0x7FABC1341BB424E9))

    var thirty_one = String("thirty_one_bytes_of_input_text.")
    assert_equal(len(thirty_one.as_bytes()), 31)
    assert_equal(fnv1a_32(thirty_one.as_bytes()), UInt32(0xBD4FE695))
    assert_equal(fnv1a_64(thirty_one.as_bytes()), UInt64(0x635E818965E95075))

    var sixty_four = _repeat_hex_digits(4)
    assert_equal(len(sixty_four), 64)
    assert_equal(fnv1a_32(Span(sixty_four)), UInt32(0xDF1F5865))
    assert_equal(fnv1a_64(Span(sixty_four)), UInt64(0xEC631990456E2F45))


def test_high_bit_bytes_are_zero_extended() raises:
    # A byte >= 0x80 is XORed in as 0x00..0xFF; sign extension would flip the
    # upper bits of the state and change every value below.
    var b80 = List[UInt8]()
    b80.append(UInt8(0x80))
    assert_equal(fnv1a_32(Span(b80)), UInt32(0x850B939F))
    assert_equal(fnv1a_64(Span(b80)), UInt64(0xAF643D4C8602915F))

    var bff = List[UInt8]()
    bff.append(UInt8(0xFF))
    assert_equal(fnv1a_32(Span(bff)), UInt32(0x7A0B824E))
    assert_equal(fnv1a_64(Span(bff)), UInt64(0xAF64724C8602EB6E))

    # Every high-bit byte, 0x80 through 0xFF in order (128 bytes).
    var high = List[UInt8]()
    for v in range(0x80, 0x100):
        high.append(UInt8(v))
    assert_equal(len(high), 128)
    assert_equal(fnv1a_32(Span(high)), UInt32(0x5FDA0245))
    assert_equal(fnv1a_64(Span(high)), UInt64(0xC1F831BCB21CE4A5))


def main() raises:
    test_constants()
    test_empty_is_the_offset_basis()
    test_32_known_answers()
    test_64_known_answers()
    test_zero_byte_is_input()
    test_inputs_longer_than_16_bytes()
    test_high_bit_bytes_are_zero_extended()
    print("all FNV-1a tests passed")
