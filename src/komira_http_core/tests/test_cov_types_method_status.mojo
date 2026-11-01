# =============================================================================
# src/komira_http_core/tests/test_cov_types_method_status.mojo
# =============================================================================
#
# The name tables of codec/types.mojo and the status mapping of
# codec/h1/limits.mojo, every arm:
#
#   * HttpMethod.parse and HttpMethod.name are inverses over all fourteen
#     method names (the seven RFC 9110 verbs and the seven WebDAV / CalDAV
#     ones), each name parses to its own code, and anything else is UNKNOWN.
#   * status_text names every status it has an arm for, and "Unknown" for
#     one it does not.
#   * the HttpResponse constructors set the status and the empty-body
#     headers they document.
#   * ParseError.make fills the status of each kind (0 for NONE and
#     NEED_MORE, 431 for an oversized trailer section).
#   * sanitize_for_log replaces control bytes (and no byte at or above
#     0x80) with '?', and truncates.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_http_core.codec.types import (
    HTTP_METHOD_COPY,
    HTTP_METHOD_DELETE,
    HTTP_METHOD_GET,
    HTTP_METHOD_HEAD,
    HTTP_METHOD_MKCALENDAR,
    HTTP_METHOD_MKCOL,
    HTTP_METHOD_MOVE,
    HTTP_METHOD_OPTIONS,
    HTTP_METHOD_PATCH,
    HTTP_METHOD_POST,
    HTTP_METHOD_PROPFIND,
    HTTP_METHOD_PROPPATCH,
    HTTP_METHOD_PUT,
    HTTP_METHOD_REPORT,
    HTTP_METHOD_UNKNOWN,
    HttpMethod,
    HttpResponse,
    status_text,
)
from komira_http_core.codec.h1.limits import (
    PARSE_ERR_CHUNK_TRAILER_TOO_LARGE,
    PARSE_ERR_NEED_MORE,
    PARSE_ERR_NONE,
    ParseError,
    sanitize_for_log,
)


def _method_names() -> List[String]:
    var names = List[String]()
    names.append(String("GET"))
    names.append(String("POST"))
    names.append(String("PUT"))
    names.append(String("DELETE"))
    names.append(String("PATCH"))
    names.append(String("HEAD"))
    names.append(String("OPTIONS"))
    names.append(String("PROPFIND"))
    names.append(String("PROPPATCH"))
    names.append(String("MKCOL"))
    names.append(String("COPY"))
    names.append(String("MOVE"))
    names.append(String("REPORT"))
    names.append(String("MKCALENDAR"))
    return names^


def _method_codes() -> List[UInt8]:
    var codes = List[UInt8]()
    codes.append(HTTP_METHOD_GET)
    codes.append(HTTP_METHOD_POST)
    codes.append(HTTP_METHOD_PUT)
    codes.append(HTTP_METHOD_DELETE)
    codes.append(HTTP_METHOD_PATCH)
    codes.append(HTTP_METHOD_HEAD)
    codes.append(HTTP_METHOD_OPTIONS)
    codes.append(HTTP_METHOD_PROPFIND)
    codes.append(HTTP_METHOD_PROPPATCH)
    codes.append(HTTP_METHOD_MKCOL)
    codes.append(HTTP_METHOD_COPY)
    codes.append(HTTP_METHOD_MOVE)
    codes.append(HTTP_METHOD_REPORT)
    codes.append(HTTP_METHOD_MKCALENDAR)
    return codes^


def test_method_parse_and_name_round_trip() raises:
    """Each of the fourteen names parses to its own code and writes back as
    itself; the codes are pairwise distinct (a parse arm returning a
    neighbour's constructor would collide two of them)."""
    var names = _method_names()
    var codes = _method_codes()
    assert_equal(len(names), len(codes))
    for i in range(len(names)):
        var m = HttpMethod.parse(names[i])
        assert_equal(Int(m.code), Int(codes[i]), names[i])
        assert_equal(m.name(), names[i])
        assert_true(m == HttpMethod(code=codes[i]))
        assert_false(m != HttpMethod(code=codes[i]))
        for j in range(len(names)):
            if j != i:
                assert_true(m != HttpMethod.parse(names[j]), names[i] + " vs " + names[j])


def test_method_unknown_spellings() raises:
    """A lowercase verb, an empty name and an unlisted token are UNKNOWN, and
    UNKNOWN writes as "UNKNOWN" (RFC 9110 §9.1: names are case-sensitive)."""
    var bad = List[String]()
    bad.append(String("get"))
    bad.append(String(""))
    bad.append(String("PATCHX"))
    bad.append(String("LOCK"))
    for i in range(len(bad)):
        var m = HttpMethod.parse(bad[i])
        assert_equal(Int(m.code), Int(HTTP_METHOD_UNKNOWN), bad[i])
        assert_equal(m.name(), String("UNKNOWN"))
    assert_equal(HttpMethod(code=UInt8(200)).name(), String("UNKNOWN"))


def _row(mut codes: List[Int], mut texts: List[String], code: Int, var text: String):
    codes.append(code)
    texts.append(text^)


def test_status_text_every_arm() raises:
    """Each status with an arm gets its phrase; the RFC 9110 / 4918 / 6585 /
    7232 phrases are compared exactly."""
    var codes = List[Int]()
    var texts = List[String]()
    _row(codes, texts, 200, String("OK"))
    _row(codes, texts, 201, String("Created"))
    _row(codes, texts, 202, String("Accepted"))
    _row(codes, texts, 204, String("No Content"))
    _row(codes, texts, 207, String("Multi-Status"))
    _row(codes, texts, 301, String("Moved Permanently"))
    _row(codes, texts, 302, String("Found"))
    _row(codes, texts, 304, String("Not Modified"))
    _row(codes, texts, 400, String("Bad Request"))
    _row(codes, texts, 401, String("Unauthorized"))
    _row(codes, texts, 403, String("Forbidden"))
    _row(codes, texts, 404, String("Not Found"))
    _row(codes, texts, 405, String("Method Not Allowed"))
    _row(codes, texts, 409, String("Conflict"))
    _row(codes, texts, 411, String("Length Required"))
    _row(codes, texts, 412, String("Precondition Failed"))
    _row(codes, texts, 415, String("Unsupported Media Type"))
    _row(codes, texts, 431, String("Request Header Fields Too Large"))
    _row(codes, texts, 500, String("Internal Server Error"))
    _row(codes, texts, 501, String("Not Implemented"))
    _row(codes, texts, 502, String("Bad Gateway"))
    _row(codes, texts, 503, String("Service Unavailable"))
    for i in range(len(codes)):
        assert_equal(status_text(Int32(codes[i])), texts[i], String(codes[i]))
    # 413 has an arm; its phrase is not compared here (RFC 9110 §15.5.14
    # names it "Content Too Large", the arm writes RFC 7231's older name:
    # komira-ai/komira#1331), only that the arm answers, not the fallback.
    assert_true(status_text(Int32(413)) != String("Unknown"))
    assert_true(status_text(Int32(413)).byte_length() > 0)
    # No arm: the fallback, for a code beside a listed one and out of range.
    assert_equal(status_text(Int32(203)), String("Unknown"))
    assert_equal(status_text(Int32(418)), String("Unknown"))
    assert_equal(status_text(Int32(-1)), String("Unknown"))


def test_response_constructors() raises:
    """HttpResponse() is a 200 and the empty-body helpers carry their status,
    a text/plain type and a zero content-length."""
    var r = HttpResponse()
    assert_equal(Int(r.status), 200)
    assert_equal(len(r.body), 0)
    assert_false(r.wants_chunked())
    var nf = HttpResponse.not_found()
    assert_equal(Int(nf.status), 404)
    assert_equal(nf.headers[String("content-length")], String("0"))
    assert_equal(nf.headers[String("content-type")], String("text/plain"))
    var br = HttpResponse.bad_request()
    assert_equal(Int(br.status), 400)
    assert_equal(br.headers[String("content-length")], String("0"))
    assert_equal(br.headers[String("content-type")], String("text/plain"))
    var ie = HttpResponse.internal_error()
    assert_equal(Int(ie.status), 500)
    assert_equal(ie.headers[String("content-length")], String("0"))
    assert_equal(ie.headers[String("content-type")], String("text/plain"))


def test_parse_error_status_of_kind() raises:
    """NONE and NEED_MORE carry no status (0); an oversized trailer section is
    the 431 an oversized header section is (RFC 9110 §6.5)."""
    assert_equal(Int(ParseError.make(PARSE_ERR_NONE, 0).status), 0)
    assert_equal(Int(ParseError.make(PARSE_ERR_NEED_MORE, 3).status), 0)
    var t = ParseError.make(PARSE_ERR_CHUNK_TRAILER_TOO_LARGE, 7)
    assert_equal(Int(t.status), 431)
    assert_equal(t.offset, 7)


def _question_marks(s: String) -> Int:
    var n = 0
    var r = s.as_bytes()
    for i in range(len(r)):
        if r[i] == UInt8(ord("?")):
            n += 1
    return n


def test_sanitize_for_log() raises:
    """Every byte under 0x20 and 0x7F becomes '?', printable ASCII is kept,
    and a source longer than max_len is cut there and marked "..."."""
    assert_equal(sanitize_for_log(String("a\r\nb\x01c\x7fd\te"), 64), String("a??b?c?d?e"))
    assert_equal(sanitize_for_log(String("abcdef"), 6), String("abcdef"))
    assert_equal(sanitize_for_log(String("abcdefg"), 6), String("abcdef..."))
    assert_equal(sanitize_for_log(String("x\x1f "), 2), String("x?..."))
    assert_equal(sanitize_for_log(String(""), 4), String(""))
    # A byte at or above 0x80 is neither under 0x20 nor 0x7F, so it must
    # not become '?'. Only that is checked: how such a byte is written out
    # is open (komira-ai/komira#1368).
    var hi = sanitize_for_log(String("aé\x01b"), 64)
    assert_equal(_question_marks(hi), 1, hi)
    assert_true(hi.startswith("a"), hi)
    assert_true(hi.endswith("?b"), hi)


def main() raises:
    test_method_parse_and_name_round_trip()
    test_method_unknown_spellings()
    test_status_text_every_arm()
    test_response_constructors()
    test_parse_error_status_of_kind()
    test_sanitize_for_log()
    print("PASS test_cov_types_method_status")
