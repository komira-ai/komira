# =============================================================================
# komira_gcp_core/tests/test_token_info.mojo
# =============================================================================
#
# The token-information read (token_info.mojo): the request it builds (a
# POST whose form body carries the token, never the URL), the principal it
# reads from an answer (the email, else the subject, else the authorized
# party), and every refusal (a non-200 naming only its status and OAuth
# error word, a 200 naming nobody, a member of the wrong kind). The wire
# cases send through GcpConnectorTransport over komira_http_core's
# ScriptedConnector to an IP literal, so no DNS and no socket.
# =============================================================================

from std.memory import ArcPointer
from std.testing import assert_equal, assert_false, assert_true

from komira_gcp_core import (
    TOKEN_INFO_HOST,
    TOKEN_INFO_PATH,
    GcpConnectorTransport,
    TokenHttpResponse,
    TokenInfo,
    fetch_token_info,
    parse_token_info,
    token_info_request,
)
from komira_http_client.client import HttpClientConfig
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream


comptime Transport = GcpConnectorTransport[ScriptedConnector]
comptime _TOKEN = "ya29.a/b+c"
comptime _EMAIL = "deployer@demo-project.example"


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _answer(status: Int, reason: String, body: String) -> List[UInt8]:
    return _bytes(
        String("HTTP/1.1 ")
        + String(status)
        + " "
        + reason
        + "\r\nContent-Type: application/json\r\nContent-Length: "
        + String(body.byte_length())
        + "\r\nConnection: close\r\n\r\n"
        + body
    )


def _tls(var script: List[UInt8], capture: ArcPointer[List[UInt8]]) raises -> Transport:
    var c = ScriptedConnector.with_stream_tls(ScriptedStream.from_read_script_with_capture(script^, capture))
    return Transport(HttpClientConfig.defaults(), c^)


def _res(status: Int, body: String) -> TokenHttpResponse:
    return TokenHttpResponse(status, _bytes(body))


def _raises(status: Int, body: String) -> String:
    try:
        _ = parse_token_info(_res(status, body))
    except e:
        return String(e)
    return String("(no error)")


def test_the_request_carries_the_token_in_the_body() raises:
    var req = token_info_request(String(_TOKEN))
    assert_equal(req.method, "POST")
    assert_equal(req.scheme, "https")
    assert_equal(req.host, String(TOKEN_INFO_HOST))
    assert_equal(req.port, 443)
    assert_equal(req.target, String(TOKEN_INFO_PATH))
    assert_equal(req.header(String("Host")), "oauth2.googleapis.com")
    assert_equal(req.header(String("Content-Type")), "application/x-www-form-urlencoded")
    # Form-encoded: `/` and `+` are escaped, so the token reads back whole.
    assert_equal(req.body_text(), "access_token=ya29.a%2Fb%2Bc")
    assert_true(req.target.find("ya29") < 0, "the token is never in the URL")


def test_a_port_other_than_the_scheme_default_is_in_the_host_header() raises:
    var req = token_info_request(String(_TOKEN), String("http"), String("127.0.0.1"), 8081)
    assert_equal(req.header(String("Host")), "127.0.0.1:8081")
    var std = token_info_request(String(_TOKEN), String("http"), String("127.0.0.1"), 80)
    assert_equal(std.header(String("Host")), "127.0.0.1")


def test_fetch_over_the_wire_reads_the_email() raises:
    var capture = ArcPointer(List[UInt8]())
    var body = (
        String('{"azp":"1122","aud":"1122","scope":"https://www.googleapis.com/auth/cloud-platform",')
        + '"expires_in":"3599","email":"' + _EMAIL + '","email_verified":"true","sub":"9988"}'
    )
    var t = _tls(_answer(200, "OK", body), capture)
    var info = fetch_token_info(t, String(_TOKEN), String("https"), String("127.0.0.1"), 443)
    assert_equal(info.principal(), _EMAIL)
    assert_equal(info.email, _EMAIL)
    assert_equal(info.subject, "9988")
    assert_equal(info.authorized_party, "1122")
    assert_equal(info.expires_in, 3599)
    var wire = String(unsafe_from_utf8=Span(capture[]))
    assert_true(wire.startswith("POST /tokeninfo HTTP/1.1\r\n"), wire)
    assert_true(wire.endswith("\r\n\r\naccess_token=ya29.a%2Fb%2Bc"), "the form body is the request's")


def test_the_principal_is_the_email_then_the_subject_then_the_client() raises:
    assert_equal(
        parse_token_info(_res(200, '{"email":"a@demo-project.example","sub":"1","azp":"2"}')).principal(),
        "a@demo-project.example",
    )
    assert_equal(parse_token_info(_res(200, '{"sub":"1","azp":"2"}')).principal(), "1")
    assert_equal(parse_token_info(_res(200, '{"azp":"2"}')).principal(), "2")
    assert_equal(parse_token_info(_res(200, '{"azp":"2"}')).expires_in, -1)


def test_expires_in_as_a_number_or_digits() raises:
    assert_equal(parse_token_info(_res(200, '{"sub":"1","expires_in":42}')).expires_in, 42)
    assert_equal(parse_token_info(_res(200, '{"sub":"1","expires_in":"7"}')).expires_in, 7)
    assert_true(_raises(200, '{"sub":"1","expires_in":"7s"}').find("expires_in") >= 0)
    assert_true(_raises(200, '{"sub":"1","expires_in":true}').find("expires_in") >= 0)


def test_a_200_naming_nobody_is_refused() raises:
    assert_true(_raises(200, '{"scope":"x","expires_in":"10"}').find("naming no principal") >= 0)
    assert_true(_raises(200, '{"email":"","sub":""}').find("naming no principal") >= 0)


def test_a_member_of_the_wrong_kind_is_refused() raises:
    assert_true(_raises(200, '{"email":7,"sub":"1"}').find("email that is not a string") >= 0)
    assert_true(_raises(200, "[]").find("not a JSON object") >= 0)
    assert_true(_raises(200, "not json").find("not JSON") >= 0)


def test_a_refusal_names_the_status_and_the_oauth_word_only() raises:
    var msg = _raises(400, '{"error":"invalid_token","error_description":"Invalid Value ya29.a/b+c"}')
    assert_equal(msg, "token info refused: HTTP 400 (invalid_token)")
    assert_false(msg.find("ya29") >= 0, "a refusal never repeats the body")
    # A body that is not an OAuth error object adds nothing.
    assert_equal(_raises(500, "<html>ya29.a/b+c</html>"), "token info refused: HTTP 500")
    # An `error` that is not a plain word is not repeated either.
    assert_equal(_raises(401, '{"error":"ya29.a/b+c"}'), "token info refused: HTTP 401")


def main() raises:
    test_the_request_carries_the_token_in_the_body()
    test_a_port_other_than_the_scheme_default_is_in_the_host_header()
    test_fetch_over_the_wire_reads_the_email()
    test_the_principal_is_the_email_then_the_subject_then_the_client()
    test_expires_in_as_a_number_or_digits()
    test_a_200_naming_nobody_is_refused()
    test_a_member_of_the_wrong_kind_is_refused()
    test_a_refusal_names_the_status_and_the_oauth_word_only()
    print("OK")
