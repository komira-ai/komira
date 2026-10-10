# =============================================================================
# tests/test_L2_codec_malformed_fuzz.mojo
# =============================================================================
#
# table-driven malformed-input tests
# (L2 codec "Malformed input" +
# functional malformed-input tests).
#
# Each row: (bytes, expected_kind, expected_status, label).
#
# This is a "fuzz" suite only in the sense of broad coverage of
# realistic attacker shapes (CRLF injection, header smuggling, bare LF,
# request-smuggling chains); inputs are static. Mojo 1.0.0b1's test
# framework doesn't have property-based fuzzing primitives — we'd port
# the corpus over but it's still table-driven.
#
# Also verifies:
#   * Error response bytes never contain client input (XSS / log-injection
#     defense). The serializer emits static strings only.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_http_core.codec import (
    PARSE_ERR_BODY_TOO_LARGE,
    PARSE_ERR_CONTENT_LENGTH_AND_CHUNKED,
    PARSE_ERR_CONTENT_LENGTH_CONFLICT,
    PARSE_ERR_CONTENT_LENGTH_INVALID,
    PARSE_ERR_HEADER_NAME_INVALID,
    PARSE_ERR_HEADER_NO_COLON,
    PARSE_ERR_HEADER_OBS_FOLD,
    PARSE_ERR_HEADER_VALUE_CONTROL_CHAR,
    PARSE_ERR_HTTP_09_REJECTED,
    PARSE_ERR_HTTP_VERSION_BAD,
    PARSE_ERR_HTTP_VERSION_UNSUPPORTED,
    PARSE_ERR_METHOD_LOWERCASE,
    PARSE_ERR_METHOD_UNKNOWN,
    PARSE_ERR_REQUEST_LINE_MALFORMED,
    PARSE_ERR_TRANSFER_ENCODING_UNSUPPORTED,
    ParseLimits,
    build_error_response_bytes,
    parse_request_head,
)


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var bytes_ref = s.as_bytes()
    var n = len(bytes_ref)
    var i = 0
    while i < n:
        out.append(bytes_ref[i])
        i = i + 1
    return out^


def _assert_rejected(
    label: String,
    bytes: List[UInt8],
    expected_kind: UInt8,
    expected_status: UInt16,
) raises:
    var span = Span[UInt8](bytes)
    var outcome = parse_request_head(span, ParseLimits.defaults())
    if outcome.err.is_ok():
        # Use the label in the assertion message for easier debugging.
        print("FAIL ", label, " — expected rejection, got OK")
        assert_false(True)
    assert_equal(Int(outcome.err.kind), Int(expected_kind))
    assert_equal(Int(outcome.err.status), Int(expected_status))


def test_fuzz_lowercase_method() raises:
    _assert_rejected(
        String("lowercase-method"),
        _bytes(String("post / HTTP/1.1\r\n\r\n")),
        PARSE_ERR_METHOD_LOWERCASE,
        UInt16(501),
    )


def test_fuzz_unknown_method() raises:
    _assert_rejected(
        String("unknown-method"),
        _bytes(String("CONNECT_FOO / HTTP/1.1\r\n\r\n")),
        PARSE_ERR_METHOD_UNKNOWN,
        UInt16(501),
    )


def test_fuzz_http_09_simple() raises:
    _assert_rejected(
        String("http-09-simple"),
        _bytes(String("GET /\r\n\r\n")),
        PARSE_ERR_HTTP_09_REJECTED,
        UInt16(400),
    )


def test_fuzz_http_2_unsupported() raises:
    _assert_rejected(
        String("http-2-unsupported"),
        _bytes(String("GET / HTTP/2.0\r\n\r\n")),
        PARSE_ERR_HTTP_VERSION_UNSUPPORTED,
        UInt16(505),
    )


def test_fuzz_version_bad_string() raises:
    _assert_rejected(
        String("version-bad-string"),
        _bytes(String("GET / HTTQ/1.1\r\n\r\n")),
        PARSE_ERR_HTTP_VERSION_BAD,
        UInt16(400),
    )


def test_fuzz_double_space() raises:
    """METHOD  TARGET (two spaces) → empty TARGET → malformed."""
    _assert_rejected(
        String("double-space"),
        _bytes(String("GET  HTTP/1.1\r\n\r\n")),
        PARSE_ERR_REQUEST_LINE_MALFORMED,
        UInt16(400),
    )


def test_fuzz_header_no_colon() raises:
    _assert_rejected(
        String("header-no-colon"),
        _bytes(String("GET / HTTP/1.1\r\nNoColonHere\r\n\r\n")),
        PARSE_ERR_HEADER_NO_COLON,
        UInt16(400),
    )


def test_fuzz_header_obs_fold() raises:
    _assert_rejected(
        String("header-obs-fold"),
        _bytes(String(
            "GET / HTTP/1.1\r\nX-A: foo\r\n bar\r\n\r\n"
        )),
        PARSE_ERR_HEADER_OBS_FOLD,
        UInt16(400),
    )


def test_fuzz_header_name_invalid() raises:
    """Header name with invalid char (':'-less + non-token) → 400.

    Use ' :' (space before colon) which we reject as name-invalid."""
    _assert_rejected(
        String("header-name-invalid"),
        _bytes(String("GET / HTTP/1.1\r\nBad Name: value\r\n\r\n")),
        PARSE_ERR_HEADER_NAME_INVALID,
        UInt16(400),
    )


def test_fuzz_content_length_smuggling() raises:
    """CL + TE: chunked together → 400 (smuggling defense)."""
    _assert_rejected(
        String("cl-te-smuggling"),
        _bytes(String(
            "POST / HTTP/1.1\r\nContent-Length: 5\r\n"
            "Transfer-Encoding: chunked\r\n\r\n"
        )),
        PARSE_ERR_CONTENT_LENGTH_AND_CHUNKED,
        UInt16(400),
    )


def test_fuzz_content_length_dupe_conflict() raises:
    """Two Content-Length values that disagree → 400."""
    _assert_rejected(
        String("cl-dupe-conflict"),
        _bytes(String(
            "POST / HTTP/1.1\r\nContent-Length: 5\r\n"
            "Content-Length: 7\r\n\r\n"
        )),
        PARSE_ERR_CONTENT_LENGTH_CONFLICT,
        UInt16(400),
    )


def test_fuzz_content_length_garbage() raises:
    _assert_rejected(
        String("cl-garbage"),
        _bytes(String(
            "POST / HTTP/1.1\r\nContent-Length: not-a-number\r\n\r\n"
        )),
        PARSE_ERR_CONTENT_LENGTH_INVALID,
        UInt16(400),
    )


def test_fuzz_te_gzip_unsupported() raises:
    _assert_rejected(
        String("te-gzip-unsupported"),
        _bytes(String(
            "POST / HTTP/1.1\r\nTransfer-Encoding: gzip\r\n\r\n"
        )),
        PARSE_ERR_TRANSFER_ENCODING_UNSUPPORTED,
        UInt16(400),
    )


def test_fuzz_header_value_control_char() raises:
    """Header value containing CR (0x0D) inside the line — CR is the
    line-end marker; a CR followed by anything other than LF + valid
    continuation is rejected.

    This shape exercises the validator path. The CR is in the value
    portion, but the parser's _find_crlf sees CR/LF at the wrong
    spot or rejects the control char.

    NOTE: building a CR inside a String value byte-by-byte.
    """
    var buf = List[UInt8]()
    var s = String("GET / HTTP/1.1\r\nX-Foo: ")
    var sb = s.as_bytes()
    var k = 0
    while k < len(sb):
        buf.append(sb[k])
        k = k + 1
    # NUL — banned control char inside value.
    buf.append(UInt8(0x00))
    buf.append(UInt8(ord("X")))
    # CRLF + CRLF terminator.
    buf.append(UInt8(0x0D))
    buf.append(UInt8(0x0A))
    buf.append(UInt8(0x0D))
    buf.append(UInt8(0x0A))
    var span = Span[UInt8](buf)
    var outcome = parse_request_head(span, ParseLimits.defaults())
    assert_false(outcome.err.is_ok())
    assert_equal(
        Int(outcome.err.kind), Int(PARSE_ERR_HEADER_VALUE_CONTROL_CHAR),
    )


def test_error_response_no_client_input() raises:
    """build_error_response_bytes emits ONLY static content. Even
    when a 'malicious' request was the input, the response body
    contains a static error string per status.

    This is the XSS / log-injection defense check.
    """
    var out = List[UInt8]()
    build_error_response_bytes(UInt16(400), out)
    var s = String()
    var i = 0
    while i < len(out):
        s = s + chr(Int(out[i]))
        i = i + 1
    # Response is "HTTP/1.1 400 Bad Request\r\n...Bad Request\n".
    # Should NOT contain any input-controlled bytes (e.g., "<script>").
    # Trivially we just verify the response is exactly what we expect.
    assert_true(s.startswith(String("HTTP/1.1 400 Bad Request\r\n")))
    # And the body — find content past CRLFCRLF.
    var crlfcrlf_idx = -1
    var k = 0
    while k + 3 < len(out):
        if (
            out[k] == UInt8(0x0D)
            and out[k + 1] == UInt8(0x0A)
            and out[k + 2] == UInt8(0x0D)
            and out[k + 3] == UInt8(0x0A)
        ):
            crlfcrlf_idx = k
            break
        k = k + 1
    assert_true(crlfcrlf_idx > 0)
    var body = String()
    var j = crlfcrlf_idx + 4
    while j < len(out):
        body = body + chr(Int(out[j]))
        j = j + 1
    assert_equal(body, String("Bad Request\n"))


def test_error_response_status_codes_well_formed() raises:
    """Error responses for 400/413/417/431/505 each have the right
    status line + body."""
    var test_cases = List[Tuple[UInt16, String]]()
    test_cases.append((UInt16(400), String("Bad Request")))
    test_cases.append((UInt16(413), String("Payload Too Large")))
    test_cases.append((UInt16(417), String("Expectation Failed")))
    test_cases.append((UInt16(431), String("Request Header Fields Too Large")))
    test_cases.append((UInt16(505), String("HTTP Version Not Supported")))
    var ti = 0
    while ti < len(test_cases):
        var t = test_cases[ti]
        var status = t[0]
        var reason = t[1]
        var out = List[UInt8]()
        build_error_response_bytes(status, out)
        var s = String()
        var i = 0
        while i < len(out):
            s = s + chr(Int(out[i]))
            i = i + 1
        var expected_prefix = (
            String("HTTP/1.1 ") + String(Int(status)) + String(" ") + reason
        )
        assert_true(s.startswith(expected_prefix))
        ti = ti + 1


def main() raises:
    test_fuzz_lowercase_method()
    test_fuzz_unknown_method()
    test_fuzz_http_09_simple()
    test_fuzz_http_2_unsupported()
    test_fuzz_version_bad_string()
    test_fuzz_double_space()
    test_fuzz_header_no_colon()
    test_fuzz_header_obs_fold()
    test_fuzz_header_name_invalid()
    test_fuzz_content_length_smuggling()
    test_fuzz_content_length_dupe_conflict()
    test_fuzz_content_length_garbage()
    test_fuzz_te_gzip_unsupported()
    test_fuzz_header_value_control_char()
    test_error_response_no_client_input()
    test_error_response_status_codes_well_formed()
    print("PASS L2 codec malformed-input fuzz tests")
