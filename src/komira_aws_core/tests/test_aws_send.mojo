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
# at a later X-Amz-Date), the attempt limit and its exact backoff for a
# fixed seed, a throttle and a dial failure resent for a POST, an SQS
# SendMessage (a POST) resent after a 500 and a 503, each resend signed
# again, and given up on after the third send, a dropped response resent
# for a POST, a conditional PUT (If-None-Match or If-Match, in any case)
# sent once after a 500 or a dropped response and resent after a throttle
# or a failed dial, a conditional GET resent, S3's 200-with-<Error>
# retried for an operation that can answer one and read as a 200 for one
# that cannot, a DynamoDB 200 whose x-amz-crc32 is wrong retried, a 4xx
# returned as it is, the budget and a client's retry quota across calls,
# the request as it reached the wire (komira_aws_core's AwsEchoConnector),
# and the free `send_sigv4_signed_request` through a connector factory,
# with four sends to DynamoDB and three to any other service (it sleeps for
# real there).
#
# One row opens a socket: a POST to a closed loopback port through
# komira_http_core's KernelTcpConnector, the production dial, so the
# classifier is held to the text that dial raises. It is refused at once
# (no wait: the sleeper records), and resent.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_raises, assert_true

from komira_async.runtime.tcp_stream import TcpListener
from komira_aws_core import (
    AWS_ECHO_CODE,
    AwsClock,
    AwsConnectorTransport,
    AwsCredential,
    AwsEchoConnector,
    AwsEndpoint,
    AwsHttpTransport,
    AwsRetryQuota,
    CredentialHttpRequest,
    Header,
    HttpResult,
    aws_json_error_info,
    aws_response_error_code,
    aws_standard_retry_policy,
    send_sigv4_signed_request,
    send_sigv4_signed_request_with,
)
from komira_http_core.transport.kernel_tcp import KernelTcpConnector
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
    s3_200_error: Bool = False,
    extra: List[Header] = List[Header](),
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
        extra,
        s3_200_error=s3_200_error,
    )


# An SQS SendMessage as its client sends it: an awsJson POST, which is not
# idempotent.
comptime _SEND_MESSAGE = '{"QueueUrl":"http://127.0.0.1:9000/queue/q","MessageBody":"m"}'


def _send_message_target() -> List[Header]:
    var extra = List[Header]()
    extra.append(Header(String("X-Amz-Target"), String("AmazonSQS.SendMessage")))
    return extra^


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
    # Full jitter under the first retry's 1 s cap, drawn from the seed.
    assert_equal(loop.sleeper().slept[0], Int64(390))


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
    # The waits SplitMix64Rng(7) draws under caps of 1 s and then 2 s:
    # uniform in [0, cap] (komira_retry's Backoff.delay_ms). A cap that did
    # not double, or a first cap other than 1 s, draws other values.
    assert_equal(len(loop.sleeper().slept), 2)
    assert_equal(loop.sleeper().slept[0], Int64(390))
    assert_equal(loop.sleeper().slept[1], Int64(33))


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


def test_a_post_is_resent_after_a_500_and_a_503() raises:
    # botocore's standard mode resends every operation after a 5xx, a POST
    # that may have reached the service included.
    var c = ScriptedConnector.with_stream(
        _response(500, "Internal Server Error", '{"__type":"InternalFailure"}')
    )
    c.arm_next(_response(503, "Service Unavailable", '{"__type":"ServiceUnavailable"}'))
    c.arm_next(_response(200, "OK", '{"MessageId":"m-1"}'))
    var t = _transport(c^)
    var clock = SteppingClock(_T0, 7)
    var loop = _loop()
    var res = _send(
        t,
        clock,
        loop,
        String("POST"),
        String("sqs"),
        String("/"),
        _SEND_MESSAGE,
        extra=_send_message_target(),
    )
    assert_equal(res.status, 200)
    assert_equal(String(unsafe_from_utf8=Span(res.body)), '{"MessageId":"m-1"}')
    assert_equal(len(t.sent), 3)
    assert_equal(len(loop.sleeper().slept), 2)
    # Each resend is signed again at a later X-Amz-Date, for the same
    # operation and body.
    assert_equal(clock.reads, 3)
    assert_equal(_header(t.sent[0], "X-Amz-Date"), "20260921T141320Z")
    assert_equal(_header(t.sent[1], "X-Amz-Date"), "20260921T141327Z")
    assert_equal(_header(t.sent[2], "X-Amz-Date"), "20260921T141334Z")
    for i in range(3):
        assert_equal(t.sent[i].method, "POST")
        assert_equal(_header(t.sent[i], "X-Amz-Target"), "AmazonSQS.SendMessage")
        assert_equal(String(unsafe_from_utf8=Span(t.sent[i].body)), _SEND_MESSAGE)
    assert_true(_header(t.sent[0], "Authorization") != _header(t.sent[1], "Authorization"))
    assert_true(_header(t.sent[1], "Authorization") != _header(t.sent[2], "Authorization"))


def test_a_post_gives_up_after_max_attempts() raises:
    # A 500, a 503 and a throttle: three sends, the standard mode's two
    # waits, and the last answer returned for the client's error builder.
    var c = ScriptedConnector.with_stream(
        _response(500, "Internal Server Error", '{"__type":"InternalFailure"}')
    )
    c.arm_next(_response(503, "Service Unavailable", '{"__type":"ServiceUnavailable"}'))
    c.arm_next(
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
    var res = _send(
        t,
        clock,
        loop,
        String("POST"),
        String("sqs"),
        String("/"),
        _SEND_MESSAGE,
        extra=_send_message_target(),
    )
    assert_equal(res.status, 400)
    assert_equal(aws_response_error_code(res), "ThrottlingException")
    assert_equal(len(t.sent), 3)
    assert_equal(len(loop.sleeper().slept), 2)
    assert_equal(loop.sleeper().slept[0], Int64(390))
    assert_equal(loop.sleeper().slept[1], Int64(33))
    assert_equal(_header(t.sent[2], "X-Amz-Date"), "20260921T141322Z")


def test_a_dropped_response_is_resent() raises:
    # The response broke off after the request was sent: a POST is resent
    # as any other request is (botocore retries every HTTPClientError).
    var c = ScriptedConnector.with_stream(_truncated())
    c.arm_next(_response(200, "OK", "{}"))
    var t = _transport(c^)
    var clock = SteppingClock(_T0, 1)
    var loop = _loop()
    var res = _send(
        t,
        clock,
        loop,
        String("POST"),
        String("sqs"),
        String("/"),
        _SEND_MESSAGE,
        extra=_send_message_target(),
    )
    assert_equal(res.status, 200)
    assert_equal(len(t.sent), 2)
    assert_equal(len(loop.sleeper().slept), 1)
    # Three dropped responses: the error of the last one is raised.
    var c2 = ScriptedConnector.with_stream(_truncated())
    c2.arm_next(_truncated())
    c2.arm_next(_truncated())
    var t2 = _transport(c2^)
    var loop2 = _loop()
    var raised = String("")
    try:
        _ = _send(t2, clock, loop2, String("POST"), String("sqs"), String("/"), "{}")
    except e:
        raised = String(e)
    assert_equal(len(t2.sent), 3, raised)
    assert_true(raised.find("(3 attempts)") >= 0, raised)
    assert_true(raised.find("HttpError[") >= 0, raised)


def _precondition(name: String, value: String) -> List[Header]:
    var extra = List[Header]()
    extra.append(Header(name, value))
    return extra^


def _internal_error() -> ScriptedStream:
    return _response(
        500, "Internal Server Error", "<Error><Code>InternalError</Code></Error>"
    )


def _precondition_failed() -> ScriptedStream:
    return _response(
        412, "Precondition Failed", "<Error><Code>PreconditionFailed</Code></Error>"
    )


def test_a_conditional_put_is_not_resent_after_a_500() raises:
    # A create-if-absent and a compare-and-swap: had the service applied
    # either before its 500, the resend would be answered 412, and the
    # caller would take its own write for a lost race. One send, and the
    # 500 is returned.
    var names: List[String] = ["If-None-Match", "If-Match", "if-none-match"]
    var values: List[String] = ["*", '"e1"', "*"]
    for i in range(len(names)):
        var c = ScriptedConnector.with_stream(_internal_error())
        c.arm_next(_precondition_failed())
        var t = _transport(c^)
        var clock = SteppingClock(_T0, 1)
        var loop = _loop()
        var res = _send(
            t,
            clock,
            loop,
            String("PUT"),
            String("s3"),
            String("/b/k"),
            "data",
            extra=_precondition(names[i], values[i]),
        )
        assert_equal(res.status, 500, names[i])
        assert_equal(aws_response_error_code(res), "InternalError")
        assert_equal(len(t.sent), 1, names[i])
        assert_equal(len(loop.sleeper().slept), 0, names[i])
        assert_equal(_header(t.sent[0], names[i]), values[i])


def test_a_conditional_put_is_resent_after_a_throttle() raises:
    # A throttle says the service refused the request: resent, signed
    # again, the precondition with it.
    var c = ScriptedConnector.with_stream(
        _response(503, "Slow Down", "<Error><Code>SlowDown</Code></Error>")
    )
    c.arm_next(_response(200, "OK", ""))
    var t = _transport(c^)
    var clock = SteppingClock(_T0, 7)
    var loop = _loop()
    var res = _send(
        t,
        clock,
        loop,
        String("PUT"),
        String("s3"),
        String("/b/k"),
        "data",
        extra=_precondition(String("If-None-Match"), String("*")),
    )
    assert_equal(res.status, 200)
    assert_equal(len(t.sent), 2)
    assert_equal(len(loop.sleeper().slept), 1)
    assert_equal(_header(t.sent[1], "If-None-Match"), "*")
    assert_equal(_header(t.sent[0], "X-Amz-Date"), "20260921T141320Z")
    assert_equal(_header(t.sent[1], "X-Amz-Date"), "20260921T141327Z")


def test_a_conditional_put_is_resent_after_a_failed_dial() raises:
    # No request byte was written: the service cannot have acted on it.
    var c = ScriptedConnector()
    c.arm_connect_error(111)
    c.arm(_response(200, "OK", ""))
    var t = _transport(c^)
    var clock = SteppingClock(_T0, 1)
    var loop = _loop()
    var res = _send(
        t,
        clock,
        loop,
        String("PUT"),
        String("s3"),
        String("/b/k"),
        "data",
        extra=_precondition(String("If-Match"), String('"e1"')),
    )
    assert_equal(res.status, 200)
    assert_equal(len(t.sent), 2)


def test_a_conditional_put_is_not_resent_after_a_dropped_response() raises:
    # The response broke off once the request was sent: the write may have
    # landed, so the transport's error is raised after one send.
    var c = ScriptedConnector.with_stream(_truncated())
    c.arm_next(_precondition_failed())
    var t = _transport(c^)
    var clock = SteppingClock(_T0, 1)
    var loop = _loop()
    var raised = String("")
    try:
        _ = _send(
            t,
            clock,
            loop,
            String("PUT"),
            String("s3"),
            String("/b/k"),
            "data",
            extra=_precondition(String("If-None-Match"), String("*")),
        )
    except e:
        raised = String(e)
    assert_equal(len(t.sent), 1, raised)
    assert_equal(len(loop.sleeper().slept), 0, raised)
    assert_true(raised.find("conditional write") >= 0, raised)
    assert_true(raised.find("HttpError[") >= 0, raised)


def test_a_conditional_get_is_resent() raises:
    # A read with a precondition changes nothing: resent after a 500.
    var c = ScriptedConnector.with_stream(_internal_error())
    c.arm_next(_response(200, "OK", "x"))
    var t = _transport(c^)
    var clock = SteppingClock(_T0, 1)
    var loop = _loop()
    var res = _send(
        t,
        clock,
        loop,
        String("GET"),
        String("s3"),
        String("/b/k"),
        extra=_precondition(String("If-Match"), String('"e1"')),
    )
    assert_equal(res.status, 200)
    assert_equal(len(t.sent), 2)
    # And a PUT without a precondition, after the same 500.
    var c2 = ScriptedConnector.with_stream(_internal_error())
    c2.arm_next(_response(200, "OK", ""))
    var t2 = _transport(c2^)
    var loop2 = _loop()
    var res2 = _send(t2, clock, loop2, String("PUT"), String("s3"), String("/b/k"), "data")
    assert_equal(res2.status, 200)
    assert_equal(len(t2.sent), 2)


def _mk_five_500s() raises -> ScriptedConnector:
    """Five 500s, the n-th one's body `n`, so a caller reads which send's
    answer it was given."""
    var c = ScriptedConnector.with_stream(_response(500, "Internal Server Error", "1"))
    for n in range(2, 6):
        c.arm_next(_response(500, "Internal Server Error", String(n)))
    return c^


def _free_send_of(service: String) raises -> HttpResult:
    var quota = AwsRetryQuota()
    return send_sigv4_signed_request[ScriptedConnector](
        _mk_five_500s,
        quota,
        String("POST"),
        _cred(),
        String("us-east-1"),
        service,
        _endpoint(),
        String("/"),
        String("application/x-amz-json-1.0"),
        _bytes(String("{}")),
        List[Header](),
    )


def test_the_free_send_makes_the_services_attempts() raises:
    # botocore's `_SERVICE_MAX_ATTEMPTS`: four sends to DynamoDB, three to
    # any other service; the last answer is returned.
    var ddb = _free_send_of(String("dynamodb"))
    assert_equal(ddb.status, 500)
    assert_equal(String(unsafe_from_utf8=Span(ddb.body)), "4")
    var sqs = _free_send_of(String("sqs"))
    assert_equal(sqs.status, 500)
    assert_equal(String(unsafe_from_utf8=Span(sqs.body)), "3")


def test_s3_200_with_error_is_retried() raises:
    var err = String(
        '<?xml version="1.0" encoding="UTF-8"?>\n<Error><Code>InternalError</Code>'
        "<Message>We encountered an internal error. Please try again.</Message>"
        "</Error>"
    )
    var ok = String(
        "<CopyObjectResult><ETag>&quot;e&quot;</ETag></CopyObjectResult>"
    )
    # An operation whose client says it can answer one (CopyObject).
    var c = ScriptedConnector.with_stream(_response(200, "OK", err))
    c.arm_next(_response(200, "OK", ok))
    var t = _transport(c^)
    var clock = SteppingClock(_T0, 1)
    var loop = _loop()
    var res = _send(
        t, clock, loop, String("PUT"), String("s3"), String("/b/k2"), s3_200_error=True
    )
    assert_equal(res.status, 200)
    assert_equal(String(unsafe_from_utf8=Span(res.body)), ok)
    assert_equal(len(t.sent), 2)


def test_a_200_is_a_200_unless_the_operation_says_otherwise() raises:
    # GetObject's body may be an object that is an XML document with an
    # <Error> root: its client does not say S3 can answer an error so.
    var body = String("<Error><Code>Mine</Code></Error>")
    var c = ScriptedConnector.with_stream(_response(200, "OK", body))
    var t = _transport(c^)
    var clock = SteppingClock(_T0, 1)
    var loop = _loop()
    var res = _send(t, clock, loop, String("GET"), String("s3"), String("/b/doc.xml"))
    assert_equal(res.status, 200)
    assert_equal(String(unsafe_from_utf8=Span(res.body)), body)
    assert_equal(len(t.sent), 1)


def test_a_dynamodb_checksum_mismatch_is_retried() raises:
    # zlib.crc32(b'{"Item":{}}') == 49613676. A 200 whose x-amz-crc32 names
    # another number is resent (botocore's RetryDDBChecksumError), and the
    # last one is returned as it is once no retry follows.
    var body = String('{"Item":{}}')
    var c = ScriptedConnector.with_stream(
        _response(200, "OK", body, "x-amz-crc32: 1\r\n")
    )
    c.arm_next(_response(200, "OK", body, "x-amz-crc32: 49613676\r\n"))
    var t = _transport(c^)
    var clock = SteppingClock(_T0, 1)
    var loop = _loop()
    var res = _send(t, clock, loop, String("POST"), String("dynamodb"), String("/"), "{}")
    assert_equal(res.status, 200)
    assert_equal(res.header(String("x-amz-crc32")), "49613676")
    assert_equal(len(t.sent), 2)
    # Another service's x-amz-crc32 is not read.
    var c2 = ScriptedConnector.with_stream(
        _response(200, "OK", body, "x-amz-crc32: 1\r\n")
    )
    var t2 = _transport(c2^)
    var loop2 = _loop()
    var res2 = _send(t2, clock, loop2, String("POST"), String("sqs"), String("/"), "{}")
    assert_equal(res2.status, 200)
    assert_equal(len(t2.sent), 1)
    # Wrong three times: the third 200 is returned.
    var c3 = ScriptedConnector.with_stream(
        _response(200, "OK", body, "x-amz-crc32: 1\r\n")
    )
    c3.arm_next(_response(200, "OK", body, "x-amz-crc32: 2\r\n"))
    c3.arm_next(_response(200, "OK", body, "x-amz-crc32: 3\r\n"))
    var t3 = _transport(c3^)
    var loop3 = _loop()
    var res3 = _send(t3, clock, loop3, String("POST"), String("dynamodb"), String("/"), "{}")
    assert_equal(res3.status, 200)
    assert_equal(res3.header(String("x-amz-crc32")), "3")
    assert_equal(len(t3.sent), 3)


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


def _quota_send(
    mut quota: AwsRetryQuota, var c: ScriptedConnector
) raises -> HttpResult:
    """One call of a client holding `quota`."""
    var t = _transport(c^)
    var clock = SteppingClock(_T0, 1)
    var loop = _loop()
    return send_sigv4_signed_request_with(
        t,
        clock,
        loop,
        quota,
        String("POST"),
        _cred(),
        String("us-east-1"),
        String("sqs"),
        _endpoint(),
        String("/"),
        String("application/x-amz-json-1.0"),
        _bytes(String(_SEND_MESSAGE)),
        _send_message_target(),
    )


def test_a_client_retry_quota() raises:
    # botocore's quota, kept across a client's calls: a retry spends 5 of
    # 500, a success puts back what its last retry cost (or 1, never over
    # 500), and a call that gives up puts nothing back.
    var quota = AwsRetryQuota()
    var c = ScriptedConnector.with_stream(_response(503, "Service Unavailable", ""))
    c.arm_next(_response(200, "OK", "{}"))
    assert_equal(_quota_send(quota, c^).status, 200)
    assert_equal(quota.available(), 500)
    var c2 = ScriptedConnector.with_stream(_response(500, "Internal Server Error", ""))
    c2.arm_next(_response(500, "Internal Server Error", ""))
    c2.arm_next(_response(500, "Internal Server Error", ""))
    assert_equal(_quota_send(quota, c2^).status, 500)
    assert_equal(quota.available(), 490)
    # An empty quota: the call is not retried.
    while quota.try_spend(5):
        pass
    var c3 = ScriptedConnector.with_stream(_response(503, "Service Unavailable", ""))
    c3.arm_next(_response(200, "OK", "{}"))
    var t3 = _transport(c3^)
    var clock = SteppingClock(_T0, 1)
    var loop = _loop()
    var res = send_sigv4_signed_request_with(
        t3,
        clock,
        loop,
        quota,
        String("POST"),
        _cred(),
        String("us-east-1"),
        String("sqs"),
        _endpoint(),
        String("/"),
        String("application/x-amz-json-1.0"),
        _bytes(String(_SEND_MESSAGE)),
        _send_message_target(),
    )
    assert_equal(res.status, 503)
    assert_equal(len(t3.sent), 1)
    assert_equal(quota.available(), 0)
    # A call that succeeds first time puts back 1.
    assert_equal(_quota_send(quota, ScriptedConnector.with_stream(_response(200, "OK", "{}"))).status, 200)
    assert_equal(quota.available(), 1)


def _mk_ok() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _response(200, "OK", "{}", "x-amzn-RequestId: r-1\r\n")
    )


def test_the_free_send_through_a_factory() raises:
    var extra = List[Header]()
    extra.append(Header(String("X-Amz-Target"), String("AmazonSQS.ListQueues")))
    var quota = AwsRetryQuota()
    var res = send_sigv4_signed_request[ScriptedConnector](
        _mk_ok,
        quota,
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
    assert_equal(quota.available(), 500)


def test_the_request_on_the_wire() raises:
    var extra = List[Header]()
    extra.append(Header(String("X-Amz-Target"), String("AmazonSQS.ListQueues")))
    var t = Recording(AwsConnectorTransport[AwsEchoConnector](AwsEchoConnector.json()))
    var clock = SteppingClock(_T0, 1)
    var loop = _loop()
    var budget = NoBudget()
    var res = send_sigv4_signed_request_with(
        t,
        clock,
        loop,
        budget,
        String("POST"),
        _cred(),
        String("us-east-1"),
        String("sqs"),
        _endpoint(),
        String("/q?a=1&b=2"),
        String("application/x-amz-json-1.0"),
        _bytes(String("{}")),
        extra,
    )
    # The echo's answer is a 400 naming no code a retry fixes: one send.
    assert_equal(res.status, 400)
    assert_equal(aws_response_error_code(res), AWS_ECHO_CODE)
    assert_equal(len(t.sent), 1)
    var wire = aws_json_error_info(res.to_response()).message.lower()
    assert_true(wire.startswith("post /q?a=1&b=2 http/1.1 | "), wire)
    for want in [
        "host: 127.0.0.1:9000",
        "x-amz-target: amazonsqs.listqueues",
        "content-type: application/x-amz-json-1.0",
        "x-amz-date: 20260921t141320z",
        "credential=akidexample/20260921/us-east-1/sqs/aws4_request",
    ]:
        assert_true(wire.find(want) >= 0, String(want) + " not in " + wire)
    # The signed headers are what went out: the recorded request's
    # Authorization is on the wire as it is.
    assert_true(wire.find(_header(t.sent[0], "Authorization").lower()) >= 0, wire)


def test_a_refused_kernel_dial_is_resent() raises:
    # Bind, read the port, then drop the listener so nothing listens.
    var l = TcpListener.bind_loopback(port=UInt16(0), backlog=Int32(1))
    var closed_port = l.local_port()
    _ = l^
    var t = Recording(
        AwsConnectorTransport[KernelTcpConnector](KernelTcpConnector.new())
    )
    var clock = SteppingClock(_T0, 1)
    var loop = _loop()
    var budget = NoBudget()
    var raised = String("")
    try:
        _ = send_sigv4_signed_request_with(
            t,
            clock,
            loop,
            budget,
            String("POST"),
            _cred(),
            String("us-east-1"),
            String("sqs"),
            AwsEndpoint.parse(
                String("http://127.0.0.1:") + String(Int(closed_port)), String("test")
            ),
            String("/"),
            String("application/x-amz-json-1.0"),
            _bytes(String("{}")),
            List[Header](),
        )
    except e:
        raised = String(e)
    # A POST, resent as any request is after a failed send: three dials,
    # the standard mode's two waits, then the dial's own text.
    assert_equal(len(t.sent), 3, raised)
    assert_equal(len(loop.sleeper().slept), 2, raised)
    assert_true(raised.find("(3 attempts)") >= 0, raised)
    assert_true(raised.find("TcpStream.connect: ") >= 0, raised)


def main() raises:
    test_one_success()
    test_503_retried_and_re_signed()
    test_gives_up_after_max_attempts()
    test_a_post_is_resent_after_a_throttle()
    test_a_post_is_resent_after_a_failed_dial()
    test_a_post_is_resent_after_a_500_and_a_503()
    test_a_post_gives_up_after_max_attempts()
    test_a_dropped_response_is_resent()
    test_a_conditional_put_is_not_resent_after_a_500()
    test_a_conditional_put_is_resent_after_a_throttle()
    test_a_conditional_put_is_resent_after_a_failed_dial()
    test_a_conditional_put_is_not_resent_after_a_dropped_response()
    test_a_conditional_get_is_resent()
    test_s3_200_with_error_is_retried()
    test_a_200_is_a_200_unless_the_operation_says_otherwise()
    test_a_dynamodb_checksum_mismatch_is_retried()
    test_a_client_error_is_returned_as_it_is()
    test_a_budget_ends_retries()
    test_a_client_retry_quota()
    test_the_free_send_through_a_factory()
    test_the_free_send_makes_the_services_attempts()
    test_the_request_on_the_wire()
    test_a_refused_kernel_dial_is_resent()
    print("OK")
