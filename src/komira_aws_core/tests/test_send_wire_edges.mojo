# =============================================================================
# komira_aws_core/tests/test_send_wire_edges.mojo
# =============================================================================
#
# The transport half of a send at the edges test_aws_send does not reach:
# every HTTP method an AWS operation uses mapped to komira_http_client's,
# an unknown one refused; the request URL of an IPv6-literal host (no
# brackets, which komira_http_client's Url holds bare); a request sent
# over the restXml echo (method, target and an escaped header back in the
# <Error> answer); an error body with leading XML whitespace read as XML;
# and the echo stream's own IoStream surface (unread replays, no fd).
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK, Reactor
from komira_async.runtime.runtime import PerCoreAsyncRuntime
from komira_http_core.codec.types import HttpMethod
from komira_http_core.transport.io_stream import TRANSPORT_KIND_KERNEL_TCP

from komira_aws_core import (
    AWS_ECHO_CODE,
    AwsConnectorTransport,
    AwsEchoConnector,
    AwsEchoStream,
    CredentialHttpRequest,
    Header,
    HttpResult,
    aws_response_error_code,
    aws_xml_error_info,
)
from komira_aws_core.aws_send import _http_method, _url_of


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def test_methods() raises:
    assert_equal(_http_method("GET").code, HttpMethod.get().code)
    assert_equal(_http_method("PUT").code, HttpMethod.put().code)
    assert_equal(_http_method("POST").code, HttpMethod.post().code)
    assert_equal(_http_method("DELETE").code, HttpMethod.delete().code)
    assert_equal(_http_method("HEAD").code, HttpMethod.head().code)
    assert_equal(_http_method("PATCH").code, HttpMethod.patch().code)
    assert_equal(_http_method("OPTIONS").code, HttpMethod.options().code)
    # Seven distinct codes: no two methods share one.
    var codes = List[Int]()
    for m in ["GET", "PUT", "POST", "DELETE", "HEAD", "PATCH", "OPTIONS"]:
        var c = Int(_http_method(m).code)
        for k in range(len(codes)):
            assert_true(codes[k] != c, "two methods share a code: " + m)
        codes.append(c)
    for bad in ["TRACE", "get", ""]:
        try:
            _ = _http_method(bad)
            raise Error("method accepted: " + bad)
        except e:
            assert_equal(
                String(e), "an AWS request method is not one HTTP sends: " + bad
            )


def test_url_of_ipv6_host() raises:
    var u = _url_of(CredentialHttpRequest("GET", "http", "[::1]", 8080, "/p?q=1"))
    assert_equal(u.host, "::1")
    assert_equal(u.port, UInt16(8080))
    assert_equal(u.path, "/p")
    assert_equal(u.query, "q=1")
    var v = _url_of(CredentialHttpRequest("GET", "https", "example.com", 443, "/"))
    assert_equal(v.host, "example.com")
    assert_equal(v.query, "")


def test_xml_echo() raises:
    var t = AwsConnectorTransport[AwsEchoConnector](AwsEchoConnector.xml())
    var req = CredentialHttpRequest("DELETE", "http", "127.0.0.1", 9000, "/k?x=1")
    req.headers.append(Header(String("Host"), String("127.0.0.1:9000")))
    req.headers.append(Header(String("X-Probe"), String("a<b&c>")))
    var res = t.send(req)
    assert_equal(res.status, 400)
    assert_equal(res.header(String("content-type")), "application/xml")
    # The XML reading: the code is the echo's, the message the request head
    # with '<', '&' and '>' escaped on the wire and read back as text.
    assert_equal(aws_response_error_code(res), AWS_ECHO_CODE)
    var msg = aws_xml_error_info(res.status, res.body, String("")).message
    assert_true(msg.startswith("DELETE /k?x=1 HTTP/1.1 | "), msg)
    assert_true(msg.find("a<b&c>") >= 0, msg)
    var c = AwsEchoConnector.xml()
    assert_equal(Int(c.transport_kind()), Int(TRANSPORT_KIND_KERNEL_TCP))
    assert_true(not c.is_tls())


def test_error_code_after_whitespace() raises:
    # XML whitespace (SP, TAB, LF, CR) before '<' still reads as XML.
    var res = HttpResult(400, _bytes(" \t\r\n<Error><Code>Busy</Code></Error>"))
    assert_equal(aws_response_error_code(res), "Busy")
    var json = HttpResult(400, _bytes(' {"__type":"Busy"}'))
    assert_equal(aws_response_error_code(json), "Busy")


def test_echo_stream_surface() raises:
    var reactor = Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
    var s = AwsEchoStream(False)
    assert_equal(Int(s.fd()), -1)
    var head = _bytes("GET / HTTP/1.1\r\nHost: h\r\n\r\n")
    var w = s.try_write[PerCoreAsyncRuntime[NoopSink]](reactor, Span(head))
    assert_true(w.is_ready())
    var buf = Array[UInt8, 8](fill=UInt8(0))
    var r = s.try_read[PerCoreAsyncRuntime[NoopSink]](reactor=reactor, dst=Span[UInt8](buf))
    assert_equal(r.n_bytes(), Int64(8))
    var first = String("")
    for i in range(8):
        first += chr(Int(buf[i]))
    assert_equal(first, "HTTP/1.1")
    # Pushed back, the same bytes are read again, then the rest follows.
    var back = List[UInt8]()
    for i in range(8):
        back.append(buf[i])
    s.unread(Span(back))
    var buf2 = Array[UInt8, 8](fill=UInt8(0))
    var r2 = s.try_read[PerCoreAsyncRuntime[NoopSink]](reactor=reactor, dst=Span[UInt8](buf2))
    assert_equal(r2.n_bytes(), Int64(8))
    var again = String("")
    for i in range(8):
        again += chr(Int(buf2[i]))
    assert_equal(again, "HTTP/1.1")
    var r3 = s.try_read[PerCoreAsyncRuntime[NoopSink]](reactor=reactor, dst=Span[UInt8](buf2))
    assert_equal(r3.n_bytes(), Int64(8))
    assert_equal(chr(Int(buf2[0])) + chr(Int(buf2[1])) + chr(Int(buf2[2])), " 40")


def main() raises:
    var failed = 0
    try:
        test_methods()
    except e:
        print("FAIL test_methods:", e)
        failed += 1
    try:
        test_url_of_ipv6_host()
    except e:
        print("FAIL test_url_of_ipv6_host:", e)
        failed += 1
    try:
        test_xml_echo()
    except e:
        print("FAIL test_xml_echo:", e)
        failed += 1
    try:
        test_error_code_after_whitespace()
    except e:
        print("FAIL test_error_code_after_whitespace:", e)
        failed += 1
    try:
        test_echo_stream_surface()
    except e:
        print("FAIL test_echo_stream_surface:", e)
        failed += 1
    if failed > 0:
        raise Error(String(failed) + " test(s) failed")
    print("OK")
