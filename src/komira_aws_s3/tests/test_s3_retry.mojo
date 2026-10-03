# The send the generated S3 client makes, over seams a test controls: the
# request built by komira_aws_s3, resolved by S3's ruleset to a local
# endpoint (path style), and sent by komira_aws_core's
# `send_sigv4_signed_request_with` over komira_http_client and a scripted
# connector, with a signing clock that moves on each read, a manual
# monotonic clock and a sleeper that records. A recording transport keeps
# each attempt's signed request as it reached the HTTP client.
#
# `Wire.send` does what the generated client's `send` does with a resolved
# target, `s3_200_error` included: the client passes it for the operations
# that can answer a 200 with an <Error> (aws-client-gen's s3
# customization), here CopyObject and CompleteMultipartUpload.
# test_s3_client drives the generated client itself.
#
# Rows: a PutObject retried after a 503 SlowDown is signed again at a later
# X-Amz-Date for the same path-style target; a GetObject that keeps getting
# 503 SlowDown gives up after the standard mode's three sends and returns
# the last answer, which raises as SlowDown; a CopyObject 200-with-<Error>
# is retried; a CompleteMultipartUpload (a POST, not idempotent) is resent,
# as botocore's standard mode resends every operation: after a
# 200-with-<Error> InternalError, and after a 500 and a 503, each resend
# signed again, until the third send, whose answer its parser raises; a 500
# on CreateMultipartUpload (a POST) is resent too. A PutObject with
# If-None-Match: * (a conditional write) is sent once after a 500, the 500
# returned, and resent after a throttle.
from komira_aws_s3.komira_aws_s3 import (
    S3CompleteMultipartUploadRequest,
    S3CopyObjectRequest,
    S3CreateMultipartUploadRequest,
    S3EndpointConfig,
    S3GetObjectRequest,
    S3PutObjectRequest,
    build_complete_multipart_upload_request,
    build_copy_object_request,
    build_create_multipart_upload_request,
    build_get_object_request,
    build_put_object_request,
    komira_aws_s3_endpoint_rules,
    parse_complete_multipart_upload_response,
    parse_copy_object_response,
    resolve_complete_multipart_upload_endpoint,
    resolve_copy_object_endpoint,
    resolve_create_multipart_upload_endpoint,
    resolve_get_object_endpoint,
    resolve_put_object_endpoint,
)
from komira_aws_core import (
    AwsClock,
    AwsConnectorTransport,
    AwsCredential,
    AwsHttpTransport,
    AwsRequest,
    AwsSigningTarget,
    CredentialHttpRequest,
    Header,
    HttpResult,
    aws_rest_xml_error,
    aws_signing_target,
    aws_standard_retry_policy,
    s3_copy_source,
    send_sigv4_signed_request_with,
)
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_retry import ManualClock, NoBudget, RecordingSleeper, RetryLoop, SplitMix64Rng
from std.testing import assert_equal, assert_raises, assert_true


comptime _T0 = 1_790_000_000  # 2026-09-21T14:13:20Z


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _answer(status: Int, reason: String, body: String) -> ScriptedStream:
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


def _slow_down() -> ScriptedStream:
    return _answer(
        503,
        "Slow Down",
        "<Error><Code>SlowDown</Code><Message>Please reduce your request"
        " rate.</Message></Error>",
    )


def _internal_200() -> ScriptedStream:
    return _answer(
        200,
        "OK",
        "<Error><Code>InternalError</Code><Message>We encountered an internal"
        " error. Please try again.</Message></Error>",
    )


struct SteppingClock(AwsClock, Movable):
    var now: Int
    var step: Int

    def __init__(out self, start: Int, step: Int):
        self.now = start
        self.step = step

    def now_unix_seconds(mut self) -> Int:
        var t = self.now
        self.now += self.step
        return t


struct Recording[X: AwsHttpTransport](AwsHttpTransport, Movable, Deinitable):
    var inner: Self.X
    var sent: List[CredentialHttpRequest]

    def __init__(out self, var inner: Self.X):
        self.inner = inner^
        self.sent = List[CredentialHttpRequest]()

    def send(mut self, req: CredentialHttpRequest) raises -> HttpResult:
        self.sent.append(req.copy())
        return self.inner.send(req)


struct Wire(Movable):
    """One call's seams: the recording transport, the clocks, the loop."""

    var t: Recording[AwsConnectorTransport[ScriptedConnector]]
    var clock: SteppingClock
    var loop: RetryLoop[ManualClock, RecordingSleeper, SplitMix64Rng]

    def __init__(out self, var c: ScriptedConnector) raises:
        self.t = Recording(AwsConnectorTransport[ScriptedConnector](c^))
        self.clock = SteppingClock(_T0, 5)
        self.loop = RetryLoop[ManualClock, RecordingSleeper, SplitMix64Rng](
            aws_standard_retry_policy(), ManualClock(), RecordingSleeper(), SplitMix64Rng(11)
        )

    def send(
        mut self, req: AwsRequest, target: AwsSigningTarget, s3_200_error: Bool = False
    ) raises -> HttpResult:
        """What the generated client's `send` does with a resolved target."""
        var extra = List[Header]()
        for i in range(len(target.header_names)):
            extra.append(Header(target.header_names[i].copy(), target.header_values[i].copy()))
        var content_type = String("")
        for i in range(len(req.header_names)):
            if req.header_names[i].lower() == "content-type":
                content_type = req.header_values[i].copy()
            else:
                extra.append(Header(req.header_names[i].copy(), req.header_values[i].copy()))
        var budget = NoBudget()
        return send_sigv4_signed_request_with(
            self.t,
            self.clock,
            self.loop,
            budget,
            req.method,
            AwsCredential(
                String("AKIDEXAMPLE"),
                String("wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"),
                String(""),
            ),
            target.signing_region,
            target.signing_name,
            target.endpoint,
            req.uri,
            content_type,
            req.body,
            extra,
            s3_200_error=s3_200_error,
        )

    def slept(self) -> Int:
        return len(self.loop.sleeper().slept)


def _config() -> S3EndpointConfig:
    var config = S3EndpointConfig(String("us-east-1"))
    config.endpoint = Optional[String](String("http://127.0.0.1:9000"))
    config.force_path_style = Optional[Bool](True)
    return config^


def _header(req: CredentialHttpRequest, name: String) -> String:
    var want = name.lower()
    for i in range(len(req.headers)):
        if req.headers[i].name.lower() == want:
            return req.headers[i].value.copy()
    return String("")


def test_a_retry_is_signed_again() raises:
    var input = S3PutObjectRequest(String("lake"), String("data/a.parquet"))
    input.set_body(_bytes(String("PAR1")))
    var target = aws_signing_target(
        resolve_put_object_endpoint(komira_aws_s3_endpoint_rules(), _config(), input),
        String("us-east-1"),
        String("s3"),
    )
    var c = ScriptedConnector.with_stream(_slow_down())
    c.arm_next(_answer(200, "OK", ""))
    var w = Wire(c^)
    var res = w.send(build_put_object_request(input), target)
    assert_equal(res.status, 200)
    assert_equal(len(w.t.sent), 2)
    assert_equal(w.slept(), 1)
    for i in range(2):
        ref r = w.t.sent[i]
        assert_equal(r.method, "PUT")
        assert_equal(r.host, "127.0.0.1")
        assert_equal(r.target, "/lake/data/a.parquet")
        assert_equal(_header(r, "Host"), "127.0.0.1:9000")
        assert_equal(_header(r, "x-amz-checksum-crc32"), _header(w.t.sent[0], "x-amz-checksum-crc32"))
        assert_true(_header(r, "Authorization").find("/us-east-1/s3/aws4_request") > 0)
    assert_equal(_header(w.t.sent[0], "X-Amz-Date"), "20260921T141320Z")
    assert_equal(_header(w.t.sent[1], "X-Amz-Date"), "20260921T141325Z")
    assert_true(
        _header(w.t.sent[0], "Authorization") != _header(w.t.sent[1], "Authorization")
    )


def test_gives_up_after_three_sends() raises:
    var input = S3GetObjectRequest(String("lake"), String("hot.bin"))
    var target = aws_signing_target(
        resolve_get_object_endpoint(komira_aws_s3_endpoint_rules(), _config(), input),
        String("us-east-1"),
        String("s3"),
    )
    var c = ScriptedConnector.with_stream(_slow_down())
    c.arm_next(_slow_down())
    c.arm_next(_slow_down())
    c.arm_next(_answer(200, "OK", "never asked for"))
    var w = Wire(c^)
    var res = w.send(build_get_object_request(input), target)
    assert_equal(res.status, 503)
    assert_equal(len(w.t.sent), 3)
    assert_equal(w.slept(), 2)
    assert_equal(aws_rest_xml_error(res.to_response()).code, "SlowDown")


def test_copy_200_with_error_is_retried() raises:
    var input = S3CopyObjectRequest(
        String("lake"), s3_copy_source(String("lake"), String("a")), String("b")
    )
    var target = aws_signing_target(
        resolve_copy_object_endpoint(komira_aws_s3_endpoint_rules(), _config(), input),
        String("us-east-1"),
        String("s3"),
    )
    var c = ScriptedConnector.with_stream(_internal_200())
    c.arm_next(
        _answer(
            200,
            "OK",
            "<CopyObjectResult><ETag>&quot;9b2c&quot;</ETag></CopyObjectResult>",
        )
    )
    var w = Wire(c^)
    var res = w.send(build_copy_object_request(input), target, s3_200_error=True)
    assert_equal(len(w.t.sent), 2)
    var out = parse_copy_object_response(res^.into_response())
    assert_equal(out.copy_object_result.value().e_tag.value(), '"9b2c"')


def _complete_target(input: S3CompleteMultipartUploadRequest) raises -> AwsSigningTarget:
    return aws_signing_target(
        resolve_complete_multipart_upload_endpoint(
            komira_aws_s3_endpoint_rules(), _config(), input
        ),
        String("us-east-1"),
        String("s3"),
    )


def test_complete_200_with_error_is_resent() raises:
    var input = S3CompleteMultipartUploadRequest(
        String("lake"), String("big.bin"), String("u1")
    )
    var target = _complete_target(input)
    var c = ScriptedConnector.with_stream(_internal_200())
    c.arm_next(
        _answer(
            200,
            "OK",
            "<CompleteMultipartUploadResult><ETag>&quot;e-2&quot;</ETag>"
            "</CompleteMultipartUploadResult>",
        )
    )
    var w = Wire(c^)
    var res = w.send(
        build_complete_multipart_upload_request(input), target, s3_200_error=True
    )
    # A POST, resent as the 500 botocore makes of the answer.
    assert_equal(len(w.t.sent), 2)
    assert_equal(w.slept(), 1)
    for i in range(2):
        assert_equal(w.t.sent[i].method, "POST")
        assert_equal(w.t.sent[i].target, "/lake/big.bin?uploadId=u1")
    assert_equal(_header(w.t.sent[0], "X-Amz-Date"), "20260921T141320Z")
    assert_equal(_header(w.t.sent[1], "X-Amz-Date"), "20260921T141325Z")
    var out = parse_complete_multipart_upload_response(res^.into_response())
    assert_equal(out.e_tag.value(), '"e-2"')


def test_complete_is_resent_until_the_third_send() raises:
    var input = S3CompleteMultipartUploadRequest(
        String("lake"), String("big.bin"), String("u1")
    )
    var target = _complete_target(input)
    var c = ScriptedConnector.with_stream(
        _answer(500, "Internal Server Error", "<Error><Code>InternalError</Code></Error>")
    )
    c.arm_next(
        _answer(503, "Service Unavailable", "<Error><Code>ServiceUnavailable</Code></Error>")
    )
    c.arm_next(_internal_200())
    c.arm_next(_answer(200, "OK", "<CompleteMultipartUploadResult/>"))
    var w = Wire(c^)
    var res = w.send(
        build_complete_multipart_upload_request(input), target, s3_200_error=True
    )
    assert_equal(len(w.t.sent), 3)
    assert_equal(w.slept(), 2)
    assert_equal(_header(w.t.sent[0], "X-Amz-Date"), "20260921T141320Z")
    assert_equal(_header(w.t.sent[1], "X-Amz-Date"), "20260921T141325Z")
    assert_equal(_header(w.t.sent[2], "X-Amz-Date"), "20260921T141330Z")
    assert_true(
        _header(w.t.sent[1], "Authorization") != _header(w.t.sent[2], "Authorization")
    )
    with assert_raises(contains="CompleteMultipartUpload failed: HTTP 500 InternalError"):
        _ = parse_complete_multipart_upload_response(res^.into_response())


def test_a_500_on_a_post_is_resent() raises:
    var input = S3CreateMultipartUploadRequest(String("lake"), String("big.bin"))
    var target = aws_signing_target(
        resolve_create_multipart_upload_endpoint(
            komira_aws_s3_endpoint_rules(), _config(), input
        ),
        String("us-east-1"),
        String("s3"),
    )
    var c = ScriptedConnector.with_stream(
        _answer(500, "Internal Server Error", "<Error><Code>InternalError</Code></Error>")
    )
    c.arm_next(_answer(200, "OK", ""))
    var w = Wire(c^)
    var res = w.send(build_create_multipart_upload_request(input), target)
    assert_equal(res.status, 200)
    assert_equal(len(w.t.sent), 2)
    assert_equal(w.t.sent[1].target, "/lake/big.bin?uploads")


def _put_if_none_match() raises -> S3PutObjectRequest:
    var input = S3PutObjectRequest(String("lake"), String("manifest.json"))
    input.set_body(_bytes(String("{}")))
    input.set_if_none_match(String("*"))
    return input^


def _put_target(input: S3PutObjectRequest) raises -> AwsSigningTarget:
    return aws_signing_target(
        resolve_put_object_endpoint(komira_aws_s3_endpoint_rules(), _config(), input),
        String("us-east-1"),
        String("s3"),
    )


def test_a_conditional_put_is_not_resent_after_a_500() raises:
    # A create-if-absent PutObject the service may have applied: a resend
    # would be answered 412, read as another writer's object. One send, and
    # the 500 is returned.
    var input = _put_if_none_match()
    var c = ScriptedConnector.with_stream(
        _answer(500, "Internal Server Error", "<Error><Code>InternalError</Code></Error>")
    )
    c.arm_next(
        _answer(412, "Precondition Failed", "<Error><Code>PreconditionFailed</Code></Error>")
    )
    var w = Wire(c^)
    var res = w.send(build_put_object_request(input), _put_target(input))
    assert_equal(res.status, 500)
    assert_equal(len(w.t.sent), 1)
    assert_equal(w.slept(), 0)
    assert_equal(_header(w.t.sent[0], "If-None-Match"), "*")


def test_a_conditional_put_is_resent_after_a_throttle() raises:
    var input = _put_if_none_match()
    var c = ScriptedConnector.with_stream(_slow_down())
    c.arm_next(_answer(200, "OK", ""))
    var w = Wire(c^)
    var res = w.send(build_put_object_request(input), _put_target(input))
    assert_equal(res.status, 200)
    assert_equal(len(w.t.sent), 2)
    assert_equal(_header(w.t.sent[1], "If-None-Match"), "*")
    assert_equal(_header(w.t.sent[1], "X-Amz-Date"), "20260921T141325Z")


def main() raises:
    test_a_retry_is_signed_again()
    test_gives_up_after_three_sends()
    test_copy_200_with_error_is_retried()
    test_complete_200_with_error_is_resent()
    test_complete_is_resent_until_the_third_send()
    test_a_500_on_a_post_is_resent()
    test_a_conditional_put_is_not_resent_after_a_500()
    test_a_conditional_put_is_resent_after_a_throttle()
    print("OK")
