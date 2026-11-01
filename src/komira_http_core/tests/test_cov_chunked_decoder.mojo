# =============================================================================
# src/komira_http_core/tests/test_cov_chunked_decoder.mojo
# =============================================================================
#
# The refusals and resumption points of the chunked decoder
# (codec/h1/chunked.mojo) its happy-path test does not reach:
#
#   * chunk-size lines: the bytes on each side of every hex-digit range
#     (refused), whitespace before the end or a ';' (accepted) and
#     before anything else (refused), a 2^62 + 1 size, a line over the
#     256-byte cap with and without its CRLF in hand;
#   * the cumulative chunk-extension budget;
#   * resumption exactly at a chunk-data boundary and inside the CRLF after
#     the data;
#   * the trailer section: a partial line over the per-line and the section
#     budget, a complete line over each of the three ceilings, a field octet
#     that is no field octet (bare CR, NUL-class control, DEL), a TAB and
#     obs-text that are;
#   * a decoder called again once DONE or ERROR, and one in no known state.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_http_core.codec.h1.chunked import (
    CHUNKED_RES_DONE,
    CHUNKED_RES_ERROR,
    CHUNKED_RES_NEED_MORE,
    ChunkedDecoder,
    _hex_value,
    decode_block,
)
from komira_http_core.codec.h1.limits import (
    DEFAULT_MAX_CHUNK_SIZE_LINE_BYTES,
    DEFAULT_MAX_TOTAL_CHUNK_EXT_BYTES,
    PARSE_ERR_CHUNK_EXT_TOO_LARGE,
    PARSE_ERR_CHUNK_SIZE_INVALID,
    PARSE_ERR_CHUNK_TRAILER_INVALID,
    PARSE_ERR_CHUNK_TRAILER_TOO_LARGE,
    ParseLimits,
)


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var r = s.as_bytes()
    for i in range(len(r)):
        out.append(r[i])
    return out^


def _repeat(c: String, n: Int) -> String:
    var s = String()
    for _ in range(n):
        s += c
    return s^


def _run(text: String, limits: ParseLimits) -> Tuple[UInt8, Int, UInt8, Int, Int]:
    """Decode `text` in one call: (outcome, consumed, err kind, err offset,
    body length)."""
    var buf = _b(text)
    var dec = ChunkedDecoder.init()
    var body = List[UInt8]()
    var res = decode_block(dec, Span[UInt8](buf), limits, body)
    return (res.outcome, res.consumed, dec.err.kind, dec.err.offset, len(body))


def _label(text: String) -> String:
    """`text` itself when short, else its length: an assertion message, not
    a 60 KB dump."""
    if text.byte_length() <= 48:
        return text
    return String("<") + String(text.byte_length()) + String(" bytes>")


def _expect_error(text: String, limits: ParseLimits, kind: UInt8, offset: Int) raises:
    var r = _run(text, limits)
    assert_equal(Int(r[0]), Int(CHUNKED_RES_ERROR), _label(text))
    assert_equal(Int(r[2]), Int(kind), _label(text))
    assert_equal(r[3], offset, _label(text))


def test_size_line_whitespace() raises:
    """BWS before CRLF or before ';' is tolerated; BWS then anything else
    (Go's chunked reader rejects `2 junk`) is refused at the line start."""
    var d = ParseLimits.defaults()
    var ok1 = _run(String("3 \t \r\nabc\r\n0\r\n\r\n"), d)
    assert_equal(Int(ok1[0]), Int(CHUNKED_RES_DONE))
    assert_equal(ok1[4], 3)
    var ok2 = _run(String("3 ; spaced = yes \r\nabc\r\n0\r\n\r\n"), d)
    assert_equal(Int(ok2[0]), Int(CHUNKED_RES_DONE))
    assert_equal(ok2[4], 3)
    _expect_error(String("2 junk\r\nab\r\n0\r\n\r\n"), d, PARSE_ERR_CHUNK_SIZE_INVALID, 0)
    _expect_error(String("2\t3\r\nab\r\n0\r\n\r\n"), d, PARSE_ERR_CHUNK_SIZE_INVALID, 0)
    # A size line holding only whitespace has no digit.
    _expect_error(String(" \r\n\r\n"), d, PARSE_ERR_CHUNK_SIZE_INVALID, 0)


def test_size_above_two_to_the_62() raises:
    """2^62 is the ceiling: 0x4000000000000000 + 1 passes the pre-multiply
    guard (v = 2^58 before the last digit) and is refused after it."""
    var d = ParseLimits.defaults()
    _expect_error(String("4000000000000001\r\n"), d, PARSE_ERR_CHUNK_SIZE_INVALID, 0)
    # 2^62 exactly is a legal size: the decoder asks for its data, and the
    # body cap refuses it rather than the size check.
    var at = _run(String("4000000000000000\r\n"), d)
    assert_equal(Int(at[0]), Int(CHUNKED_RES_ERROR))
    assert_true(Int(at[2]) != Int(PARSE_ERR_CHUNK_SIZE_INVALID))


def test_size_line_over_cap() raises:
    """A size line of more than 256 bytes is refused whether or not its CRLF
    has arrived; exactly 256 bytes without a CRLF is still NEED_MORE."""
    var d = ParseLimits.defaults()
    var cap = DEFAULT_MAX_CHUNK_SIZE_LINE_BYTES
    var at_cap = _run(String("1;") + _repeat(String("e"), cap - 2), d)
    assert_equal(Int(at_cap[0]), Int(CHUNKED_RES_NEED_MORE))
    assert_equal(at_cap[1], 0)
    _expect_error(
        String("1;") + _repeat(String("e"), cap - 1), d,
        PARSE_ERR_CHUNK_SIZE_INVALID, 0,
    )
    # With the CRLF in hand: 256 bytes before it pass, 257 are refused.
    var ok = _run(String("1;") + _repeat(String("e"), cap - 2) + String("\r\nX\r\n0\r\n\r\n"), d)
    assert_equal(Int(ok[0]), Int(CHUNKED_RES_DONE))
    # The second chunk's line is the long one: the error names its offset.
    var first = String("1\r\nX\r\n")
    _expect_error(
        first + String("1;") + _repeat(String("e"), cap - 1) + String("\r\nX\r\n"), d,
        PARSE_ERR_CHUNK_SIZE_INVALID, first.byte_length(),
    )


def test_chunk_ext_budget() raises:
    """Extension bytes add up across lines and the total is held to
    DEFAULT_MAX_TOTAL_CHUNK_EXT_BYTES; the chunk that crosses it is refused
    at its own line."""
    var d = ParseLimits.defaults()
    var ext = String(";") + _repeat(String("e"), 199)  # 200 extension bytes
    var line = String("1") + ext + String("\r\nX\r\n")
    var fits = DEFAULT_MAX_TOTAL_CHUNK_EXT_BYTES // 200
    var text = String()
    for _ in range(fits):
        text += line
    var under = _run(text + String("0\r\n\r\n"), d)
    assert_equal(Int(under[0]), Int(CHUNKED_RES_DONE))
    assert_equal(under[4], fits)
    var over = text + line
    _expect_error(
        over, d, PARSE_ERR_CHUNK_EXT_TOO_LARGE, text.byte_length(),
    )


def test_resume_at_data_boundaries() raises:
    """A block ending right after the size line (no data byte yet) and one
    ending between the data's CR and LF both ask for more and lose nothing."""
    var d = ParseLimits.defaults()
    var dec = ChunkedDecoder.init()
    var body = List[UInt8]()
    var p1 = _b(String("3\r\n"))
    var r1 = decode_block(dec, Span[UInt8](p1), d, body)
    assert_equal(Int(r1.outcome), Int(CHUNKED_RES_NEED_MORE))
    assert_equal(r1.consumed, 3)
    var p2 = _b(String("abc\r"))
    var r2 = decode_block(dec, Span[UInt8](p2), d, body)
    assert_equal(Int(r2.outcome), Int(CHUNKED_RES_NEED_MORE))
    assert_equal(r2.consumed, 3)
    assert_equal(len(body), 3)
    var p3 = _b(String("\r\n0\r\n\r\n"))
    var r3 = decode_block(dec, Span[UInt8](p3), d, body)
    assert_equal(Int(r3.outcome), Int(CHUNKED_RES_DONE))
    assert_equal(r3.consumed, 7)
    assert_true(dec.is_done())
    assert_false(dec.is_error())


def test_trailer_partial_line_bounds() raises:
    """With no CRLF in hand the tail is one partial trailer line: over the
    per-line cap it is refused; within it but over what is left of the
    section budget it is refused; within both it is NEED_MORE."""
    var lim = ParseLimits.defaults()
    lim.max_header_bytes = 10
    lim.max_total_header_bytes = 20
    var pre = String("0\r\n")
    _expect_error(
        pre + String("a:34567890X"), lim,
        PARSE_ERR_CHUNK_TRAILER_TOO_LARGE, pre.byte_length(),
    )
    var w = _run(pre + String("a:34567890"), lim)
    assert_equal(Int(w[0]), Int(CHUNKED_RES_NEED_MORE))
    assert_equal(w[1], pre.byte_length())
    # One complete 10-byte line (12 with its CRLF) leaves 8 of the section:
    # a 9-byte partial is over it although under the per-line cap.
    var one = pre + String("a:34567890\r\n")
    _expect_error(
        one + String("b:3456789"), lim,
        PARSE_ERR_CHUNK_TRAILER_TOO_LARGE, one.byte_length(),
    )
    var w2 = _run(one + String("b:345678"), lim)
    assert_equal(Int(w2[0]), Int(CHUNKED_RES_NEED_MORE))
    assert_equal(w2[1], one.byte_length())


def test_trailer_complete_line_ceilings() raises:
    """A complete trailer line is held to the per-line cap, the field count
    and the section byte budget, each refusal at the line's start."""
    var pre = String("0\r\n")
    var lim = ParseLimits.defaults()
    lim.max_header_bytes = 10
    _expect_error(
        pre + String("a:34567890X\r\n\r\n"), lim,
        PARSE_ERR_CHUNK_TRAILER_TOO_LARGE, pre.byte_length(),
    )
    var ok = _run(pre + String("a:34567890\r\n\r\n"), lim)
    assert_equal(Int(ok[0]), Int(CHUNKED_RES_DONE))

    var lim2 = ParseLimits.defaults()
    lim2.max_headers = 2
    var two = pre + String("a:1\r\nb:2\r\n")
    var ok2 = _run(two + String("\r\n"), lim2)
    assert_equal(Int(ok2[0]), Int(CHUNKED_RES_DONE))
    _expect_error(
        two + String("c:3\r\n\r\n"), lim2,
        PARSE_ERR_CHUNK_TRAILER_TOO_LARGE, two.byte_length(),
    )

    var lim3 = ParseLimits.defaults()
    lim3.max_total_header_bytes = 10
    var first = pre + String("a:1\r\n")  # 5 bytes of section
    var ok3 = _run(first + String("b:2\r\n\r\n"), lim3)  # exactly 10
    assert_equal(Int(ok3[0]), Int(CHUNKED_RES_DONE))
    _expect_error(
        first + String("b:23\r\n\r\n"), lim3,
        PARSE_ERR_CHUNK_TRAILER_TOO_LARGE, first.byte_length(),
    )


def test_trailer_field_octets() raises:
    """HTAB, SP, VCHAR and obs-text are field octets; a bare CR, a C0
    control and DEL are not, and the error names the offending byte."""
    var d = ParseLimits.defaults()
    var pre = String("0\r\n")
    var ok = _run(pre + String("x-a:\tv \xa0\xff\r\n\r\n"), d)
    assert_equal(Int(ok[0]), Int(CHUNKED_RES_DONE))
    _expect_error(
        pre + String("x-a: v\rw\r\n\r\n"), d,
        PARSE_ERR_CHUNK_TRAILER_INVALID, pre.byte_length() + 6,
    )
    _expect_error(
        pre + String("x-a: \x01\r\n\r\n"), d,
        PARSE_ERR_CHUNK_TRAILER_INVALID, pre.byte_length() + 5,
    )
    _expect_error(
        pre + String("x\x7f: v\r\n\r\n"), d,
        PARSE_ERR_CHUNK_TRAILER_INVALID, pre.byte_length() + 1,
    )


def test_called_again_after_done_and_error() raises:
    """DONE and ERROR are terminal: another call consumes nothing and
    repeats the outcome; a decoder in a state of no known value bails out
    with ERROR."""
    var d = ParseLimits.defaults()
    var dec = ChunkedDecoder.init()
    var body = List[UInt8]()
    var all = _b(String("0\r\n\r\n"))
    var r = decode_block(dec, Span[UInt8](all), d, body)
    assert_equal(Int(r.outcome), Int(CHUNKED_RES_DONE))
    var more = _b(String("5\r\nhello\r\n"))
    var again = decode_block(dec, Span[UInt8](more), d, body)
    assert_equal(Int(again.outcome), Int(CHUNKED_RES_DONE))
    assert_equal(again.consumed, 0)
    assert_equal(len(body), 0)

    var bad = ChunkedDecoder.init()
    var junk = _b(String("Z\r\n"))
    var e1 = decode_block(bad, Span[UInt8](junk), d, body)
    assert_equal(Int(e1.outcome), Int(CHUNKED_RES_ERROR))
    assert_true(bad.is_error())
    var e2 = decode_block(bad, Span[UInt8](more), d, body)
    assert_equal(Int(e2.outcome), Int(CHUNKED_RES_ERROR))
    assert_equal(e2.consumed, 0)
    assert_equal(len(body), 0)

    var odd = ChunkedDecoder.init()
    odd.state = UInt8(77)
    var e3 = decode_block(odd, Span[UInt8](more), d, body)
    assert_equal(Int(e3.outcome), Int(CHUNKED_RES_ERROR))
    assert_equal(e3.consumed, 0)
    # odd.err is deliberately not checked: decode_block's docstring promises
    # a ParseError on every ERROR outcome, and this bail leaves none
    # (komira-ai/komira#1369).
    assert_equal(len(body), 0)


def test_size_digit_range_edges() raises:
    """The bytes on each side of every hex-digit range are no chunk-size
    digit, alone or after a real digit. The second form is the one that
    tells: a digit test that let `@` through would read "1@" as
    16 + _hex_value(`@`) = 15 and ask for 15 bytes of data."""
    var d = ParseLimits.defaults()
    var edges = List[String]()
    edges.append(String("/"))
    edges.append(String(":"))
    edges.append(String("@"))
    edges.append(String("G"))
    edges.append(String("`"))
    edges.append(String("g"))
    for k in range(len(edges)):
        _expect_error(edges[k] + String("\r\n"), d, PARSE_ERR_CHUNK_SIZE_INVALID, 0)
        _expect_error(String("1") + edges[k] + String("\r\n"), d, PARSE_ERR_CHUNK_SIZE_INVALID, 0)
    # The range ends themselves are digits: "Ff" is 255 bytes of data.
    var r = _run(String("Ff\r\n") + _repeat(String("x"), 255) + String("\r\n0\r\n\r\n"), d)
    assert_equal(Int(r[0]), Int(CHUNKED_RES_DONE))
    assert_equal(r[4], 255)


def test_hex_value() raises:
    """Digit values of all three ranges and -1 outside them (the bytes just
    past each range end included)."""
    assert_equal(_hex_value(UInt8(ord("0"))), 0)
    assert_equal(_hex_value(UInt8(ord("9"))), 9)
    assert_equal(_hex_value(UInt8(ord("a"))), 10)
    assert_equal(_hex_value(UInt8(ord("f"))), 15)
    assert_equal(_hex_value(UInt8(ord("A"))), 10)
    assert_equal(_hex_value(UInt8(ord("F"))), 15)
    assert_equal(_hex_value(UInt8(ord("g"))), -1)
    assert_equal(_hex_value(UInt8(ord("G"))), -1)
    assert_equal(_hex_value(UInt8(ord("/"))), -1)
    assert_equal(_hex_value(UInt8(ord(":"))), -1)
    assert_equal(_hex_value(UInt8(ord("@"))), -1)
    assert_equal(_hex_value(UInt8(ord("`"))), -1)
    assert_equal(_hex_value(UInt8(0xFF)), -1)


def main() raises:
    test_size_line_whitespace()
    test_size_above_two_to_the_62()
    test_size_line_over_cap()
    test_chunk_ext_budget()
    test_resume_at_data_boundaries()
    test_trailer_partial_line_bounds()
    test_trailer_complete_line_ceilings()
    test_trailer_field_octets()
    test_called_again_after_done_and_error()
    test_size_digit_range_edges()
    test_hex_value()
    print("PASS test_cov_chunked_decoder")
