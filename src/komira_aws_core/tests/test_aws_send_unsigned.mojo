# =============================================================================
# komira_aws_core/tests/test_aws_send_unsigned.mojo
# =============================================================================
#
# The unsigned request and send, for an operation the model marks anonymous
# (`authtype` `none`, `auth` `smithy.api#noAuth`), which botocore sends with
# no signature.
#
# Rows: `build_unsigned_request` sends exactly the headers the signed builder
# sends before its signature (Host, Content-Type, the extra headers,
# Content-Length) and nothing after them, with the same target and body;
# it refuses what the signed builder refuses before signing, and CR/LF in an
# extra header. `send_unsigned_request_with` over a scripted connector
# retries a 503 as the signed send does, every attempt unsigned and the
# same; the free `send_unsigned_request` sends through a connector factory.
# No socket is opened.
# =============================================================================

from std.testing import assert_equal, assert_raises, assert_true

from komira_aws_core import (
    AwsClock,
    AwsConnectorTransport,
    AwsCredential,
    AwsEndpoint,
    AwsHttpTransport,
    AwsRetryQuota,
    CredentialHttpRequest,
    Header,
    HttpResult,
    aws_standard_retry_policy,
    build_sigv4_signed_request,
    build_unsigned_request,
    send_unsigned_request,
    send_unsigned_request_with,
)
from komira_http_client.client import HttpClientConfig
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_retry import (
    ManualClock,
    NoBudget,
    RecordingSleeper,
    RetryLoop,
    SplitMix64Rng,
)


comptime _T0 = 1_790_000_000  # 2026-09-21T14:13:20Z


struct _FixedClock(AwsClock, Movable):
    var now: Int

    def __init__(out self, now: Int):
        self.now = now

    def now_unix_seconds(mut self) -> Int:
        return self.now


struct _Recording[X: AwsHttpTransport](AwsHttpTransport, Movable, Deinitable):
    """Keeps every request it is asked to send, then sends it."""

    var inner: Self.X
    var sent: List[CredentialHttpRequest]

    def __init__(out self, var inner: Self.X):
        self.inner = inner^
        self.sent = List[CredentialHttpRequest]()

    def send(mut self, req: CredentialHttpRequest) raises -> HttpResult:
        self.sent.append(req.copy())
        return self.inner.send(req)


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _response(status: Int, reason: String, body: String) -> ScriptedStream:
    return ScriptedStream.from_read_script(
        _bytes(
            String("HTTP/1.1 ")
            + String(status)
            + " "
            + reason
            + "\r\nContent-Length: "
            + String(body.byte_length())
            + "\r\nConnection: close\r\n\r\n"
            + body
        )
    )


def _endpoint() raises -> AwsEndpoint:
    return AwsEndpoint.parse(String("http://127.0.0.1:9000"), String("test"))


def _target() -> List[Header]:
    var extra = List[Header]()
    extra.append(Header(String("X-Amz-Target"), String("Tiny.Anon")))
    return extra^


def _has(req: CredentialHttpRequest, name: String) -> Bool:
    var want = name.lower()
    for i in range(len(req.headers)):
        if req.headers[i].name.lower() == want:
            return True
    return False


def _assert_unsigned(req: CredentialHttpRequest) raises:
    for name in [
        "Authorization",
        "X-Amz-Date",
        "X-Amz-Content-Sha256",
        "X-Amz-Security-Token",
    ]:
        assert_true(not _has(req, name), String(name) + " was sent")


def test_the_unsigned_request_is_the_signed_one_before_its_signature() raises:
    var body = String('{"A":1}')
    var unsigned = build_unsigned_request(
        String("POST"),
        _endpoint(),
        String("/x?y=1"),
        String("application/x-amz-json-1.1"),
        Span(body.as_bytes()),
        _target(),
    )
    _assert_unsigned(unsigned)
    assert_equal(len(unsigned.headers), 4)
    assert_equal(unsigned.headers[0].name, "Host")
    assert_equal(unsigned.headers[0].value, "127.0.0.1:9000")
    assert_equal(unsigned.headers[1].name, "Content-Type")
    assert_equal(unsigned.headers[2].name, "X-Amz-Target")
    assert_equal(unsigned.headers[3].name, "Content-Length")
    assert_equal(unsigned.headers[3].value, "7")
    # The signed request of the same inputs starts with the same headers,
    # and adds only its signature after them.
    var clock = _FixedClock(_T0)
    var signed = build_sigv4_signed_request(
        String("POST"),
        AwsCredential(String("AKIDEXAMPLE"), String("secret"), String("")),
        String("us-east-1"),
        String("tiny"),
        _endpoint(),
        String("/x?y=1"),
        String("application/x-amz-json-1.1"),
        Span(body.as_bytes()),
        _target(),
        clock,
    )
    assert_true(len(signed.headers) > len(unsigned.headers))
    for i in range(len(unsigned.headers)):
        assert_equal(signed.headers[i].name, unsigned.headers[i].name)
        assert_equal(signed.headers[i].value, unsigned.headers[i].value)
    assert_equal(unsigned.method, signed.method)
    assert_equal(unsigned.target, signed.target)
    assert_equal(unsigned.host, signed.host)
    assert_equal(unsigned.port, signed.port)
    assert_equal(len(unsigned.body), 7)
    assert_equal(len(signed.body), 7)
    for i in range(len(unsigned.body)):
        assert_equal(unsigned.body[i], signed.body[i])


def test_the_unsigned_request_refuses_what_the_signed_one_refuses() raises:
    var empty = List[UInt8]()
    with assert_raises(contains="does not start with '/'"):
        _ = build_unsigned_request(
            String("GET"), _endpoint(), String("x"), String(""), Span(empty), List[Header]()
        )
    with assert_raises(contains="not letters only"):
        _ = build_unsigned_request(
            String("G T"), _endpoint(), String("/"), String(""), Span(empty), List[Header]()
        )
    var host = List[Header]()
    host.append(Header(String("host"), String("elsewhere")))
    with assert_raises(contains="is set by the request builder"):
        _ = build_unsigned_request(
            String("GET"), _endpoint(), String("/"), String(""), Span(empty), host
        )
    var crlf = List[Header]()
    crlf.append(Header(String("X-Amz-Target"), String("a\r\nInjected: 1")))
    with assert_raises(contains="holds CR or LF"):
        _ = build_unsigned_request(
            String("GET"), _endpoint(), String("/"), String(""), Span(empty), crlf
        )
    # A header the signer owns, in any case, is refused unsigned too: an
    # anonymous request must not carry a caller-supplied signature or token.
    for name in ["Authorization", "x-AMZ-Security-Token", "X-Amz-Date", "x-amz-content-sha256"]:
        var owned = List[Header]()
        owned.append(Header(String(name), String("v")))
        with assert_raises(contains="the signer writes it"):
            _ = build_unsigned_request(
                String("GET"), _endpoint(), String("/"), String(""), Span(empty), owned
            )
    var unnamed = List[Header]()
    unnamed.append(Header(String(""), String("v")))
    with assert_raises(contains="empty name"):
        _ = build_unsigned_request(
            String("GET"), _endpoint(), String("/"), String(""), Span(empty), unnamed
        )


def test_an_unsigned_send_is_retried_unsigned() raises:
    var c = ScriptedConnector.with_stream(_response(503, "Service Unavailable", ""))
    c.arm_next(_response(200, "OK", "{}"))
    var t = _Recording(AwsConnectorTransport[ScriptedConnector](c^))
    var loop = RetryLoop[ManualClock, RecordingSleeper, SplitMix64Rng](
        aws_standard_retry_policy(), ManualClock(), RecordingSleeper(), SplitMix64Rng(7)
    )
    var budget = NoBudget()
    var res = send_unsigned_request_with(
        t,
        loop,
        budget,
        String("POST"),
        String("tiny"),
        _endpoint(),
        String("/"),
        String("application/x-amz-json-1.1"),
        _bytes(String("{}")),
        _target(),
    )
    assert_equal(res.status, 200)
    assert_equal(len(t.sent), 2)
    assert_equal(len(loop.sleeper().slept), 1)
    for i in range(len(t.sent)):
        _assert_unsigned(t.sent[i])
        assert_equal(len(t.sent[i].headers), 4)
        assert_equal(t.sent[i].target, "/")
    for i in range(len(t.sent[0].headers)):
        assert_equal(t.sent[1].headers[i].value, t.sent[0].headers[i].value)


def _mk_ok() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(_response(200, "OK", "{}"))


def test_the_free_unsigned_send_through_a_factory() raises:
    var quota = AwsRetryQuota()
    var res = send_unsigned_request[ScriptedConnector](
        _mk_ok,
        HttpClientConfig.defaults(),
        quota,
        String("GET"),
        String("tiny"),
        _endpoint(),
        String("/thing"),
        String(""),
        List[UInt8](),
        List[Header](),
    )
    assert_equal(res.status, 200)
    assert_equal(String(unsafe_from_utf8=Span(res.body)), "{}")


def main() raises:
    test_the_unsigned_request_is_the_signed_one_before_its_signature()
    test_the_unsigned_request_refuses_what_the_signed_one_refuses()
    test_an_unsigned_send_is_retried_unsigned()
    test_the_free_unsigned_send_through_a_factory()
    print("OK")
