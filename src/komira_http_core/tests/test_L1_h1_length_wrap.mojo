# =============================================================================
# test_L1_h1_length_wrap.mojo -- the h1 length accumulators reject a value
# that wraps Int64, they do not believe it
# =============================================================================
#
# Two parsers here turn untrusted digits into a framing length:
#   * `codec/h1/parser.mojo:_parse_decimal`, a request's Content-Length on the
#     server; `parse_request_head` frames the body on its result and only
#     rejects a NEGATIVE one;
#   * `codec/h1/chunked.mojo:_parse_chunk_size_line`, the hex chunk size of
#     every chunked body, either direction.
#
# Both accumulate `v = v * base + digit`. The guard against overflow must run
# BEFORE the multiply: tested after it, the multiply that wraps has already
# happened, Int wrap is two's-complement, and the wrapped value can land small
# and POSITIVE, inside the accepted range. The input class that does it is one
# that carries the accumulator across a multiple of 2^64 while every prefix
# stays under the 2^62 ceiling: decimal `18446744073709551621` and hex
# `10000000000000005` are both 2^64 + 5 and, behind a post-multiply guard,
# parse to 5. A peer (or a proxy in front of us) reading the same digits
# correctly sees 2^64 + 5; we would frame a 5-byte body and read the rest as
# the next message. That is request smuggling, and it does not depend on the
# assert mode: nothing on these paths is a bounds check.
#
# An over-ceiling probe such as 25 nines does NOT catch the defect: it lands
# in the band the post-multiply guard rejects anyway. The wrap values above
# are the falsifiers; the boundary tests keep the fix from narrowing the
# accepted range.
#
# The client's twins (`komira_http_client.response_parser._parse_decimal` and
# `_parse_decimal_bytes`) are pinned in that package's
# test_L2_response_framing_precedence.mojo.
#
# It imports the two private parsers on purpose, to pin each guard directly
# rather than through a whole request, as the client's twin test does.
#
# Defect it catches: removing or moving after the multiply the pre-multiply
# guard (`v > _MAX_PARSED_DECIMAL_DIV10`, `v > _MAX_CHUNK_SIZE_DIV16`) in
# either parser; a ceiling tightened below 2^62.
# =============================================================================

from std.testing import TestSuite, assert_equal

from komira_http_core.codec.h1.chunked import _parse_chunk_size_line
from komira_http_core.codec.h1.parser import _parse_decimal


comptime _WRAP_TO_FIVE_DEC = "18446744073709551621"
"""2^64 + 5. Every prefix stays below 2^62, so a post-multiply guard admits
all 20 digits and the accumulator wraps to 5."""

comptime _WRAP_TO_ZERO_DEC = "18446744073709551616"
"""2^64. Behind a post-multiply guard it wraps to 0: a request that claims
no body while the peer sent one."""

comptime _WRAP_TO_FIVE_HEX = "10000000000000005"
"""2^64 + 5 in hex: 17 characters, far inside the chunk-size line cap, so no
other bound on that path fires."""

comptime _CEILING_DEC = "4611686018427387904"
"""Exactly 1 << 62, the documented ceiling, which stays accepted."""


def _bytes_of(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _chunk_size(s: String) -> Int:
    var line = _bytes_of(s)
    return _parse_chunk_size_line(Span(line), 0, len(line))


# -----------------------------------------------------------------------------
# The server's request Content-Length.
# -----------------------------------------------------------------------------


def test_content_length_wrap_to_five_is_rejected() raises:
    assert_equal(
        _parse_decimal(String(_WRAP_TO_FIVE_DEC)),
        -1,
        "Content-Length 2^64+5 must be rejected, not believed as 5",
    )


def test_content_length_wrap_to_zero_is_rejected() raises:
    assert_equal(
        _parse_decimal(String(_WRAP_TO_ZERO_DEC)),
        -1,
        "Content-Length 2^64 must be rejected, not believed as 0",
    )


def test_content_length_ceiling_and_ordinary_values_accepted() raises:
    """The guard is a ceiling, not a narrowing: 1 << 62 stays legal."""
    assert_equal(_parse_decimal(String(_CEILING_DEC)), 1 << 62)
    assert_equal(_parse_decimal(String("0")), 0)
    assert_equal(_parse_decimal(String("1048576")), 1048576)


def test_content_length_over_ceiling_rejected() raises:
    assert_equal(_parse_decimal(String("4611686018427387905")), -1)
    assert_equal(_parse_decimal(String("9999999999999999999999999")), -1)


# -----------------------------------------------------------------------------
# The chunk-size line.
# -----------------------------------------------------------------------------


def test_chunk_size_hex_wrap_is_rejected() raises:
    """Base 16 crosses 2^64 in 17 characters, well inside the line cap."""
    assert_equal(
        _chunk_size(String(_WRAP_TO_FIVE_HEX)),
        -1,
        "a chunk size of 2^64+5 must be rejected, not believed as 5",
    )


def test_chunk_size_ordinary_values_accepted() raises:
    assert_equal(_chunk_size(String("5")), 5)
    assert_equal(_chunk_size(String("0")), 0)
    assert_equal(_chunk_size(String("100000")), 0x100000)
    # 1 << 62 in hex is the ceiling and stays legal.
    assert_equal(_chunk_size(String("4000000000000000")), 1 << 62)
    # A chunk extension after ';' is parsed and ignored.
    assert_equal(_chunk_size(String("1a;name=value")), 0x1A)
    # A value over the ceiling that does not wrap stays rejected.
    assert_equal(_chunk_size(String("ffffffffffffffffff")), -1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
