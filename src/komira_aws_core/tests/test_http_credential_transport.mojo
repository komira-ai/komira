# SchemeSplitCredentialTransport sends an `http` credential request over its
# plain transport and an `https` one over its TLS transport, returns the
# response's status and body as the chain reads them, and refuses any other
# scheme (the chain's providers only build http and https requests, so a
# third is a bug that must not be sent anywhere). Two scripted
# AwsHttpTransports stand in for the connectors: no socket.

from std.testing import assert_equal, assert_true

from komira_aws_core import (
    AwsHttpTransport,
    CredentialHttpRequest,
    CredentialTransport,
    HttpResult,
    SchemeSplitCredentialTransport,
)


struct _Answers(AwsHttpTransport, Movable, Deinitable):
    """Answers every request with `status` and `body`, and remembers the last
    host it was asked for."""

    var status: Int
    var body: String
    var calls: Int
    var last_host: String

    def __init__(out self, status: Int, body: String):
        self.status = status
        self.body = body
        self.calls = 0
        self.last_host = String("")

    def send(mut self, req: CredentialHttpRequest) raises -> HttpResult:
        self.calls += 1
        self.last_host = req.host.copy()
        var bytes = List[UInt8]()
        bytes.extend(Span(self.body.as_bytes()))
        return HttpResult(self.status, bytes^)


def _request(scheme: String, host: String) -> CredentialHttpRequest:
    return CredentialHttpRequest("GET", scheme, host, 80, "/latest/meta-data/")


def test_the_scheme_picks_the_transport() raises:
    var t = SchemeSplitCredentialTransport[_Answers, _Answers](
        _Answers(200, "plain-body"), _Answers(201, "tls-body")
    )
    var plain = t.send(_request("http", "169.254.169.254"))
    assert_equal(plain.status, 200)
    assert_equal(plain.body, "plain-body")
    var tls = t.send(_request("https", "sts.us-east-1.amazonaws.com"))
    assert_equal(tls.status, 201)
    assert_equal(tls.body, "tls-body")
    assert_equal(t._plain.calls, 1)
    assert_equal(t._plain.last_host, "169.254.169.254")
    assert_equal(t._tls.calls, 1)
    assert_equal(t._tls.last_host, "sts.us-east-1.amazonaws.com")


def test_another_scheme_is_refused_and_sent_nowhere() raises:
    var t = SchemeSplitCredentialTransport[_Answers, _Answers](
        _Answers(200, "a"), _Answers(200, "b")
    )
    var raised = False
    try:
        _ = t.send(_request("ftp", "example.com"))
    except e:
        raised = True
        assert_true(String(e).find("neither http nor https") >= 0, String(e))
    assert_true(raised, "a request with another scheme was sent")
    assert_equal(t._plain.calls + t._tls.calls, 0)


def main() raises:
    test_the_scheme_picks_the_transport()
    test_another_scheme_is_refused_and_sent_nowhere()
    print("OK")
