# =============================================================================
# test_L2_h2_hpack_hostile_input.mojo -- HPACK input a hostile peer controls
# is refused by our own checks, with a named error
# =============================================================================
#
# Every byte HPACK decodes comes off the wire. These tests assert that OUR
# code refuses the hostile shapes, as a decode result or a named error, so
# they hold whatever the assert mode (a stdlib bounds check that happens to
# abort is not a defence once asserts are compiled out).
#
# 1. `decode_integer` (RFC 7541 §5.1) into a UInt32. RFC 7541: "a decoder MUST
#    treat a value that exceeds the implementation limit as a decoding error".
#    Two independent ways a hostile encoder exceeds 2^32 - 1:
#      * the sum wraps: `FF FF FF FF FF 0F` is 127 + 0x0FFFFFFF + 0xF0000000,
#        one past 2^32 - 1 by 127; an unchecked `value + addend` wraps to a
#        small value the caller treats as validated (a length, a table index);
#      * the fifth continuation octet carries bits above bit 31:
#        `FF 80 80 80 80 10` puts 0x10 at shift 28, i.e. bit 32, which a
#        UInt32 shift silently drops, leaving 127; the sum does not wrap, so
#        only the shift-out-of-the-top check sees it.
#    Boundaries that must stay accepted: five continuation octets (the widest
#    legal encoding) and exactly 2^32 - 1 (`FF 80 FF FF FF 0F`).
# 2. `HpackDecoder.decode_block`, header-list amplification. An indexed
#    representation is ONE octet (`0x82` = static entry 2, `:method: GET`) and
#    yields a heap-owning (name, value) pair, so without accounting N input
#    octets mint N headers. The decoder charges the RFC 9113 §6.5.2 unit
#    (`len(name) + len(value) + 32`, 42 octets for `:method: GET`) per field
#    against `max_header_list_size` and raises a named error past it.
#
# `decode_integer` is a module-level function the decoder uses internally; it
# is imported on purpose, to pin its guards directly.
#
# Defects it catches: deleting the sum-wrap check (`summed < value`), the
# shift-28 top-bits check, or the header-list budget in decode_block; an
# off-by-one in that budget (the 84-octet boundary below); a ceiling that
# rejects legal encodings.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_http_core.codec.h2.hpack import HpackDecoder, decode_integer


def _octets(*values: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for v in values:
        out.append(UInt8(v))
    return out^


# -----------------------------------------------------------------------------
# 1. decode_integer
# -----------------------------------------------------------------------------


def test_integer_five_continuation_octets_still_decodes() raises:
    """The widest legal 32-bit encoding (shifts 0/7/14/21/28) decodes."""
    var buf = _octets(0xFF, 0x80, 0x80, 0x80, 0x80, 0x01)
    var res = decode_integer(Span(buf), 0, 7)
    assert_true(res.ok)
    assert_equal(res.consumed, 6)
    assert_equal(Int(res.value), 127 + (1 << 28))


def test_integer_exactly_u32_max_decodes() raises:
    """127 + 0 + 0x7f<<7 + 0x7f<<14 + 0x7f<<21 + 0x0f<<28 == 2^32 - 1."""
    var buf = _octets(0xFF, 0x80, 0xFF, 0xFF, 0xFF, 0x0F)
    var res = decode_integer(Span(buf), 0, 7)
    assert_true(res.ok)
    assert_equal(res.consumed, 6)
    assert_equal(Int(res.value), 0xFFFFFFFF)


def test_integer_sum_wrap_is_a_decode_error() raises:
    """2^32 - 1 + 127: the sum wraps a UInt32 unless it is checked."""
    var buf = _octets(0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F)
    var res = decode_integer(Span(buf), 0, 7)
    assert_false(res.ok, "an integer past 2^32-1 must not decode")


def test_integer_bits_above_31_are_a_decode_error() raises:
    """0x10 at shift 28 is bit 32: dropped by the shift, so the sum stays 127
    and only the top-bits check refuses it."""
    var buf = _octets(0xFF, 0x80, 0x80, 0x80, 0x80, 0x10)
    var res = decode_integer(Span(buf), 0, 7)
    assert_false(res.ok, "bit 32 must not be silently dropped")


def test_integer_all_ones_fifth_octet_is_a_decode_error() raises:
    var buf = _octets(0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F)
    var res = decode_integer(Span(buf), 0, 7)
    assert_false(res.ok)


# -----------------------------------------------------------------------------
# 2. decode_block header-list budget
# -----------------------------------------------------------------------------


def _decode_error(mut decoder: HpackDecoder, block: List[UInt8]) -> String:
    """The decode error's message, or "" when the block decoded."""
    try:
        var got = decoder.decode_block(Span(block))
        _ = len(got)
    except e:
        return String(e)
    return String("")


def _indexed_get(n: Int) -> List[UInt8]:
    var block = List[UInt8]()
    for _ in range(n):
        block.append(UInt8(0x82))  # indexed: :method GET
    return block^


def test_header_list_flood_is_refused_by_the_default_budget() raises:
    """4096 one-octet fields ask for 4096 * 42 = 172032 octets, over the
    default budget."""
    var decoder = HpackDecoder(max_table_size=4096)
    var msg = _decode_error(decoder, _indexed_get(4096))
    assert_true(msg.find("header list size") >= 0, "got: '" + msg + "'")
    assert_true(msg.find("SETTINGS_MAX_HEADER_LIST_SIZE") >= 0, msg)


def test_header_list_budget_boundary() raises:
    """Two `:method: GET` fields cost exactly 84 octets: at an 84-octet budget
    two decode and three are refused."""
    var decoder = HpackDecoder(max_table_size=4096)
    decoder.max_header_list_size = 84
    assert_equal(_decode_error(decoder, _indexed_get(2)), String(""))
    var decoder3 = HpackDecoder(max_table_size=4096)
    decoder3.max_header_list_size = 84
    var msg = _decode_error(decoder3, _indexed_get(3))
    assert_true(msg.find("header list size 126") >= 0, "got: '" + msg + "'")


def test_ordinary_header_list_decodes() raises:
    var decoder = HpackDecoder(max_table_size=4096)
    var block = _indexed_get(4)
    var got = decoder.decode_block(Span(block))
    assert_equal(len(got), 4)
    assert_equal(got[0].name, String(":method"))
    assert_equal(got[0].value, String("GET"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
