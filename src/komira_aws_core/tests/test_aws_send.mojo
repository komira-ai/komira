# =============================================================================
# komira_aws_core/tests/test_aws_send.mojo
# =============================================================================
#
# The transport half of a send, end to end over komira_http_client and a
# scripted connector (komira_http_core's ScriptedConnector): no socket, no
# network. Each test arms the connector with the responses a service would
# give, one stream per dial, and drives `send_sigv4_signed_request_with`
# with a stepping signing clock, a manual monotonic clock and a sleeper
# that records. A recording transport wraps the real one, so every attempt
# that reached the HTTP client is kept as the exact signed request.
#
# Rows: one success, a 503 retried then answered (and its retry re-signed
# at a later X-Amz-Date), the attempt limit, a throttle and a dial failure
# resent for a POST, a 500 and a dropped response not resent for a POST
# (and resent for a PUT), S3's 200-with-<Error> on a PUT retried, a GET's
# not read as an error, a 4xx returned as it is, and the free
# `send_sigv4_signed_request` through a connector factory.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_raises, assert_true

from komira_aws_core import (
    AwsClock,
    AwsConnectorTransport,
    AwsCredential,
    AwsEndpoint,
    AwsHttpTransport,
    CredentialHttpRequest,
    Header,
    HttpResult,
    aws_response_error_code,
    aws_standard_retry_policy,
    send_sigv4_signed_request,
    send_sigv4_signed_request_with,
)
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_retry import (
    ManualClock,
    NoBudget,
    RecordingSleeper,
    RetryLoop,
    SplitMix64Rng,
    TokenBucket,
)


comptime _T0 = 1_790_000_000  # 2026-09-21T14:13:20Z


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _response(status: Int, reason: String, body: String, extra: String = "") -> ScriptedStream:
    """A scripted server answer, closing the connection after it."""
    var head = (
        String("HTTP/1.1 ")
        + String(status)
        + " "
        + reason
        + "\r\nContent-Length: "
        + String(body.byte_length())
        + "\r\nConnection: close\r\n"
        + extra
        + "\r\n"
    )
    return ScriptedStream.from_read_script(_bytes(head + body))


def _truncated() -> ScriptedStream:
    """A response that promises 100 body bytes and delivers 3."""
    return ScriptedStream.from_read_script(
        _bytes(String("HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nabc"))
    )


struct SteppingClock(AwsClock, Movable):
    """A wall clock that moves `step` seconds every time it is read."""

    var now: Int
    var step: Int
    var reads: Int

    def __init__(out self, start: Int, step: Int):
        self.now = start
        self.step = step
        self.reads = 0

    def now_unix_seconds(mut self) -> Int:
        var t = self.now
        self.now += self.step
        self.reads += 1
        return t


struct Recording[X: AwsHttpTransport](AwsHttpTransport, Movable, Deinitable):
    """Keeps every request it is asked to send, then sends it."""

    var inner: Self.X
    var sent: List[CredentialHttpRequest]

    def __init__(out self, var inner: Self.X):
        self.inner = inner^
        self.sent = List[CredentialHttpRequest]()

    def send(mut self, req: CredentialHttpRequest) raises -> HttpResult:
        self.sent.append(req.copy())
        return self.inner.send(req)


def _transport(var c: ScriptedConnector) raises -> Recording[AwsConnectorTransport[ScriptedConnector]]:
    return Recording(AwsConnectorTransport[ScriptedConnector](c^))


def _loop() raises -> RetryLoop[ManualClock, RecordingSleeper, SplitMix64Rng]:
    return RetryLoop[ManualClock, RecordingSleeper, SplitMix64Rng](
        aws_standard_retry_policy(), ManualClock(), RecordingSleeper(), SplitMix64Rng(7)
    )


def _cred() -> AwsCredential:
    return AwsCredential(
        String("AKIDEXAMPLE"),
        String("wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"),
        String(""),
    )


def _endpoint() raises -> AwsEndpoint:
    return AwsEndpoint.parse(String("http://127.0.0.1:9000"), String("test"))


def _header(req: CredentialHttpRequest, name: String) -> String:
    var want = name.lower()
    for i in range(len(req.headers)):
        if req.headers[i].name.lower() == want:
            return req.headers[i].value.copy()
    return String("")


def _send[X: AwsHttpTransport](
    mut t: X,
    mut clock: SteppingClock,
    mut loop: RetryLoop[ManualClock, RecordingSleeper, SplitMix64Rng],
    method: String,
    service: String,
    uri: String,
    body: String = "",
) raises -> HttpResult:
    var budget = NoBudget()
    return send_sigv4_signed_request_with(
        t,
        clock,
        loop,
        budget,
        method,
        _cred(),
        String("us-east-1"),
        service,
        _endpoint(),
        uri,
        String("application/x-amz-json-1.0") if service == "sqs" else String(""),
        _bytes(body),
        List[Header](),
    )


def test_one_success() raises:
    var c = ScriptedConnector.with_stream(_response(200, "OK", "{}"))
    var t = _transport(c^)
    var clock = SteppingClock(_T0, 1)
    var loop = _loop()
    var res = _send(t, clock, loop, String("GET"), String("s3"), String("/b/k?x=1"))
    assert_equal(res.status, 200)
    assert_equal(String(unsafe_from_utf8=Span(res.body)), "{}")
    assert_equal(len(t.sent), 1)
    assert_equal(clock.reads, 1)
    assert_equal(len(loop.sleeper().slept), 0)
    # What reached the HTTP client is the signed request, for the target
    # the endpoint and path name.
    assert_equal(t.sent[0].method, "GET")
    assert_equal(t.sent[0].target, "/b/k?x=1")
    assert_equal(t.sent[0].host, "127.0.0.1")
    assert_equal(t.sent[0].port, 9000)
    assert_equal(_header(t.sent[0], "X-Amz-Date"), "20260921T141320Z")
    assert_true(_header(t.sent[0], "Authorization").startswith("AWS4-HMAC-SHA256 "))
    # The response's headers come back, names lower-cased by the client.
    assert_equal(res.header(String("connection")), "close")


def test_503_retried_and_re_signed() raises:
    var c = ScriptedConnector.with_stream(
        _response(503, "Service Unavailable", "<Error><Code>ServiceUnavailable</Code></Error>")
    )
    c.arm_next(_response(200, "OK", ""))
    var t = _transport(c^)
    var clock = SteppingClock(_T0, 7)
    var loop = _loop()
    var res = _send(t, clock, loop, String("PUT"), String("s3"), String("/b/k"), "data")
    assert_equal(res.status, 200)
    assert_equal(len(t.sent), 2)
    assert_equal(len(loop.sleeper().slept), 1)
    # Each attempt read the clock and was signed again: a later date, a
    # different signature, the same request otherwise.
    assert_equal(clock.reads, 2)
    assert_equal(_header(t.sent[0], "X-Amz-Date"), "20260921T141320Z")
    assert_equal(_header(t.sent[1], "X-Amz-Date"), "20260921T141327Z")
    assert_true(
        _header(t.sent[0], "Authorization") != _header(t.sent[1], "Authorization")
    )
    assert_equal(t.sent[1].target, t.sent[0].target)
    assert_equal(len(t.sent[1].body), 4)
    # Full jitter under the first retry's 1 s cap.
    assert_true(loop.sleeper().slept[0] >= 0 and loop.sleeper().slept[0] <= 1000)


def test_gives_up_after_max_attempts() raises:
    var c = ScriptedConnector.with_stream(_response(500, "Internal Server Error", ""))
    c.arm_next(_response(502, "Bad Gateway", ""))
    c.arm_next(_response(504, "Gateway Timeout", ""))
    c.arm_next(_response(200, "OK", ""))
    var t = _transport(c^)
    var clock = SteppingClock(_T0, 1)
    var loop = _loop()
    var res = _send(t, clock, loop, String("GET"), String("s3"), String("/b/k"))
    # Three sends, two waits; the last failed response is returned for the
    # caller's error builder, and the fourth answer is never asked for.
    assert_equal(res.status, 504)
    assert_equal(len(t.sent), 3)
    assert_equal(len(loop.sleeper().slept), 2)
    assert_true(loop.sleeper().slept[1] <= 2000)


def test_a_post_is_resent_after_a_throttle() raises:
    var c = ScriptedConnector.with_stream(
        _response(
            400,
            "Bad Request",
            '{"__type":"com.amazonaws.sqs#ThrottlingException","message":"slow"}',
        )
    )
    c.arm_next(_response(200, "OK", "{}"))
    var t = _transport(c^)
    var clock = SteppingClock(_T0, 1)
    var loop = _loop()
    var res = _send(t, clock, loop, String("POST"), String("sqs"), String("/"), "{}")
    assert_equal(res.status, 200)
    assert_equal(len(t.sent), 2)


def test_a_post_is_resent_after_a_failed_dial() raises:
    var c = ScriptedConnector()
    c.arm_connect_error(111)
    c.arm(_response(200, "OK", "{}"))
    var t = _transport(c^)
    var clock = SteppingClock(_T0, 1)
    var loop = _loop()
    var res = _send(t, clock, loop, String("POST"), String("sqs"), String("/"), "{}")
    assert_equal(res.status, 200)
    assert_equal(len(t.sent), 2)
    assert_equal(len(loop.sleeper().slept), 1)


def test_a_post_is_not_resent_after_a_500() raises:
    var c = ScriptedConnector.with_stream(
        _response(500, "Internal Server Error", '{"__type":"InternalFailure"}')
    )
    c.arm_next(_response(200, "OK", "{}"))
    var t = _transport(c^)
    var clock = SteppingClock(_T0, 1)
    var loop = _loop()
    var res = _send(t, clock, loop, String("POST"), String("sqs"), String("/"), "{}")
    assert_equal(res.status, 500)
    assert_equal(aws_response_error_code(res), "InternalFailure")
    assert_equal(len(t.sent), 1)
    assert_equal(len(loop.sleeper().slept), 0)


def test_a_dropped_response() raises:
    # A POST: the service may have acted, so the error is raised.
    var c = ScriptedConnector.with_stream(_truncated())
    c.arm_next(_response(200, "OK", "{}"))
    var t = _transport(c^)
    var clock = SteppingClock(_T0, 1)
    var loop = _loop()
    var raised = False
    try:
        _ = _send(t, clock, loop, String("POST"), String("sqs"), String("/"), "{}")
    except e:
        raised = True
        assert_true(String(e).find("HttpError[") >= 0, String(e))
        assert_true(String(e).find("not retry-safe") >= 0, String(e))
    assert_true(raised)
    assert_equal(len(t.sent), 1)
    # A PUT: resent.
    var c2 = ScriptedConnector.with_stream(_truncated())
    c2.arm_next(_response(200, "OK", ""))
    var t2 = _transport(c2^)
    var loop2 = _loop()
    var res = _send(t2, clock, loop2, String("PUT"), String("s3"), String("/b/k"), "x")
    assert_equal(res.status, 200)
    assert_equal(len(t2.sent), 2)


def test_s3_200_with_error_is_retried() raises:
    var err = String(
        '<?xml version="1.0" encoding="UTF-8"?>\n<Error><Code>InternalError</Code>'
        "<Message>We encountered an internal error. Please try again.</Message>"
        "</Error>"
    )
    var ok = String(
        "<CopyObjectResult><ETag>&quot;e&quot;</ETag></CopyObjectResult>"
    )
    var c = ScriptedConnector.with_stream(_response(200, "OK", err))
    c.arm_next(_response(200, "OK", ok))
    var t = _transport(c^)
    var clock = SteppingClock(_T0, 1)
    var loop = _loop()
    var res = _send(t, clock, loop, String("PUT"), String("s3"), String("/b/k2"))
    assert_equal(res.status, 200)
    assert_equal(String(unsafe_from_utf8=Span(res.body)), ok)
    assert_equal(len(t.sent), 2)
    # Not S3: a 200 is a 200.
    var c2 = ScriptedConnector.with_stream(_response(200, "OK", err))
    var t2 = _transport(c2^)
    var loop2 = _loop()
    var res2 = _send(t2, clock, loop2, String("PUT"), String("sqs"), String("/"))
    assert_equal(res2.status, 200)
    assert_equal(len(t2.sent), 1)


def test_an_s3_get_body_is_not_read_as_an_error() raises:
    # An object may be an XML document with an <Error> root.
    var body = String("<Error><Code>Mine</Code></Error>")
    var c = ScriptedConnector.with_stream(_response(200, "OK", body))
    var t = _transport(c^)
    var clock = SteppingClock(_T0, 1)
    var loop = _loop()
    var res = _send(t, clock, loop, String("GET"), String("s3"), String("/b/doc.xml"))
    assert_equal(res.status, 200)
    assert_equal(len(t.sent), 1)


def test_a_client_error_is_returned_as_it_is() raises:
    var c = ScriptedConnector.with_stream(
        _response(
            412,
            "Precondition Failed",
            "<Error><Code>PreconditionFailed</Code><Message>At least one of the"
            " pre-conditions you specified did not hold</Message></Error>",
        )
    )
    var t = _transport(c^)
    var clock = SteppingClock(_T0, 1)
    var loop = _loop()
    var res = _send(t, clock, loop, String("PUT"), String("s3"), String("/b/k"), "x")
    assert_equal(res.status, 412)
    assert_equal(aws_response_error_code(res), "PreconditionFailed")
    assert_equal(len(t.sent), 1)


def test_a_budget_ends_retries() raises:
    var c = ScriptedConnector.with_stream(_response(503, "Service Unavailable", ""))
    c.arm_next(_response(200, "OK", ""))
    var t = _transport(c^)
    var clock = SteppingClock(_T0, 1)
    var loop = _loop()
    var budget = TokenBucket(capacity=4)
    var res = send_sigv4_signed_request_with(
        t,
        clock,
        loop,
        budget,
        String("GET"),
        _cred(),
        String("us-east-1"),
        String("s3"),
        _endpoint(),
        String("/b/k"),
        String(""),
        List[UInt8](),
        List[Header](),
    )
    # A retry costs 5 and the bucket holds 4: no retry.
    assert_equal(res.status, 503)
    assert_equal(len(t.sent), 1)


def _mk_ok() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _response(200, "OK", "{}", "x-amzn-RequestId: r-1\r\n")
    )


def _mk_refused() raises -> ScriptedConnector:
    var c = ScriptedConnector()
    c.arm_connect_error(111)
    c.arm_next(_response(200, "OK", "{}"))
    return c^


def test_the_free_send_through_a_factory() raises:
    var extra = List[Header]()
    extra.append(Header(String("X-Amz-Target"), String("AmazonSQS.ListQueues")))
    var res = send_sigv4_signed_request[ScriptedConnector](
        _mk_ok,
        String("POST"),
        _cred(),
        String("us-east-1"),
        String("sqs"),
        _endpoint(),
        String("/"),
        String("application/x-amz-json-1.0"),
        _bytes(String("{}")),
        extra^,
    )
    assert_equal(res.status, 200)
    assert_equal(res.header(String("x-amzn-RequestId")), "r-1")
    # A refused dial is retried, after a real (short) wait.
    var res2 = send_sigv4_signed_request[ScriptedConnector](
        _mk_refused,
        String("POST"),
        _cred(),
        String("us-east-1"),
        String("sqs"),
        _endpoint(),
        String("/"),
        String("application/x-amz-json-1.0"),
        _bytes(String("{}")),
        List[Header](),
    )
    assert_equal(res2.status, 200)


def main() raises:
    test_one_success()
    test_503_retried_and_re_signed()
    test_gives_up_after_max_attempts()
    test_a_post_is_resent_after_a_throttle()
    test_a_post_is_resent_after_a_failed_dial()
    test_a_post_is_not_resent_after_a_500()
    test_a_dropped_response()
    test_s3_200_with_error_is_retried()
    test_an_s3_get_body_is_not_read_as_an_error()
    test_a_client_error_is_returned_as_it_is()
    test_a_budget_ends_retries()
    test_the_free_send_through_a_factory()
    print("OK")
