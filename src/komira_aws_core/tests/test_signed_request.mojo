# The signing half of a send, byte for byte: each request below is built by
# `build_sigv4_signed_request` with fake keys at a fixed clock and compared
# with tests/fixtures/<name>.request, recorded from an independent SigV4
# implementation over the same inputs. Also: the refusals, and that an
# AwsRequest from a generated builder signs its X-Amz-Target.

from std.testing import assert_equal, assert_true

from komira_aws_core import (
    AwsCredential,
    AwsEndpoint,
    AwsRequest,
    CredentialHttpRequest,
    FixedClock,
    Header,
    build_sigv4_signed_request,
    resolve_endpoint,
)


comptime _FIX = "src/komira_aws_core/tests/fixtures/"
comptime _KEY = "AKIDEXAMPLE"
comptime _SECRET = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
# 2026-09-19T12:00:00Z
comptime _NOW = 1789819200


def _golden(req: CredentialHttpRequest, name: String) raises:
    var want: String
    with open(String(_FIX) + name, "r") as f:
        want = f.read()
    assert_true(want.find("\r\n") >= 0, name + " lost its CRLF line ends")
    var got = req.to_wire()
    if got != want:
        raise Error(
            "request differs from " + name + "\n--- got ---\n" + got
            + "\n--- want ---\n" + want
        )


def _cred() -> AwsCredential:
    return AwsCredential(String(_KEY), String(_SECRET), String(""))


def test_aws_json_sqs() raises:
    # Built the way a generated client's `send` builds it: the operation's
    # AwsRequest, Content-Type split off, every other header passed as extra.
    var op = AwsRequest(String("POST"), String("/"))
    op.set_header(String("X-Amz-Target"), String("AmazonSQS.ListQueues"))
    op.set_header(String("Content-Type"), String("application/x-amz-json-1.0"))
    op.body = String('{"QueueNamePrefix":"komira"}')
    var content_type = String("")
    var extra = List[Header]()
    for i in range(len(op.header_names)):
        var n = op.header_names[i].copy()
        if n == String("Content-Type"):
            content_type = op.header_values[i].copy()
        else:
            extra.append(Header(n^, op.header_values[i].copy()))
    var clock = FixedClock(_NOW)
    var req = build_sigv4_signed_request(
        op.method,
        _cred(),
        String("us-east-1"),
        String("sqs"),
        resolve_endpoint(Optional[AwsEndpoint](), "sqs.us-east-1.amazonaws.com"),
        op.uri,
        content_type,
        op.body,
        extra,
        clock,
    )
    _golden(req, "aws_json_sqs_list_queues.request")
    assert_equal(req.scheme, "https")
    assert_equal(req.port, 443)
    var auth = req.header("Authorization")
    assert_true(
        auth.find("SignedHeaders=content-type;host;x-amz-date;x-amz-target,") > 0,
        "X-Amz-Target is not signed: " + auth,
    )
    assert_true(req.to_wire().find(_SECRET) < 0, "the secret is on the wire")


def test_localstack_temporary_credential() raises:
    var clock = FixedClock(_NOW)
    var extra: List[Header] = [
        Header(String("X-Amz-Target"), String("Logs_20140328.DescribeLogGroups"))
    ]
    var req = build_sigv4_signed_request(
        String("POST"),
        AwsCredential(
            String("ASIAEXAMPLETEMPKEY01"),
            String("FAKEtemporarySecretKey/EXAMPLEKEY000000"),
            String("FAKE-SESSION-TOKEN//example=="),
        ),
        String("eu-west-1"),
        String("logs"),
        AwsEndpoint.parse("http://localhost:4566", "AWS_ENDPOINT_URL"),
        String("/"),
        String("application/x-amz-json-1.1"),
        String('{"limit":5}'),
        extra,
        clock,
    )
    _golden(req, "aws_json_logs_localstack_session.request")
    assert_equal(req.scheme, "http")
    assert_equal(req.port, 4566)


def test_s3_get() raises:
    var clock = FixedClock(_NOW)
    var req = build_sigv4_signed_request(
        String("GET"),
        _cred(),
        String("us-west-2"),
        String("s3"),
        AwsEndpoint.https("my-bucket.s3.us-west-2.amazonaws.com"),
        String("/photos/2026/a%20b.jpg?versionId=v1&acl"),
        String(""),
        String(""),
        List[Header](),
        clock,
    )
    _golden(req, "s3_get_object.request")


def test_base_path_endpoint() raises:
    var clock = FixedClock(_NOW)
    var extra: List[Header] = [
        Header(String("X-Amz-Target"), String("DynamoDB_20120810.ListTables")),
        Header(String("x-amzn-query-mode"), String("true")),
    ]
    var req = build_sigv4_signed_request(
        String("POST"),
        _cred(),
        String("us-west-2"),
        String("dynamodb"),
        AwsEndpoint.parse("https://proxy.example.com:8443/aws/", "T"),
        String("/"),
        String("application/x-amz-json-1.0"),
        String("{}"),
        extra,
        clock,
    )
    _golden(req, "aws_json_proxy_base_path.request")
    assert_equal(req.target, "/aws/")


def _signed(method: String, body: String) raises -> String:
    var clock = FixedClock(_NOW)
    return build_sigv4_signed_request(
        method,
        _cred(),
        String("us-east-1"),
        String("sqs"),
        AwsEndpoint.https("sqs.us-east-1.amazonaws.com"),
        String("/"),
        String(""),
        body,
        List[Header](),
        clock,
    ).to_wire()


def test_content_length_on_bodyless_requests() raises:
    # A body-less POST / PUT / PATCH still says Content-Length: 0 (an HTTP/1.1
    # server may otherwise answer 411); a body-less GET / DELETE says nothing.
    # Content-Length is never a signed header.
    var with_zero: List[String] = ["POST", "PUT", "PATCH"]
    for i in range(len(with_zero)):
        var w = _signed(with_zero[i], String(""))
        assert_true(w.find("\r\nContent-Length: 0\r\n") >= 0, w)
        assert_true(w.find("content-length;") < 0, w)
    var without: List[String] = ["GET", "DELETE", "HEAD"]
    for i in range(len(without)):
        var w = _signed(without[i], String(""))
        assert_true(w.find("Content-Length") < 0, w)
    # A body on any method carries its length.
    var w = _signed(String("DELETE"), String("{}"))
    assert_true(w.find("\r\nContent-Length: 2\r\n") >= 0, w)


def _refused(extra: List[Header], method: String, uri: String, want: String) raises:
    var clock = FixedClock(_NOW)
    try:
        _ = build_sigv4_signed_request(
            method,
            _cred(),
            String("us-east-1"),
            String("sqs"),
            AwsEndpoint.https("sqs.us-east-1.amazonaws.com"),
            uri,
            String("application/x-amz-json-1.0"),
            String("{}"),
            extra,
            clock,
        )
    except e:
        assert_true(String(e).find(want) >= 0, String(e))
        return
    raise Error("not refused: " + want)


def test_refusals() raises:
    var none = List[Header]()
    _refused(none, String("PO ST"), String("/"), "letters only")
    _refused(none, String(""), String("/"), "empty method")
    _refused(none, String("POST"), String("q"), "does not start with '/'")
    _refused(none, String("POST"), String("/\r\nX: y"), "CR or LF")
    var names: List[String] = ["Host", "content-type", "Content-Length"]
    for i in range(len(names)):
        var e: List[Header] = [Header(names[i], String("x"))]
        _refused(e, String("POST"), String("/"), "set by the request builder")
    var signer: List[Header] = [Header(String("Authorization"), String("x"))]
    _refused(signer, String("POST"), String("/"), "the signer writes it")
    var crlf: List[Header] = [Header(String("X-Amz-Target"), String("a\r\nb"))]
    _refused(crlf, String("POST"), String("/"), "CR")
    # AwsRequest refuses a header with CR/LF when it is set.
    var op = AwsRequest(String("POST"), String("/"))
    try:
        op.set_header(String("X-Amz-Target"), String("a\nb"))
        raise Error("AwsRequest accepted LF")
    except e:
        assert_true(String(e).find("CR or LF") >= 0, String(e))
    # set_header replaces case-insensitively.
    op.set_header(String("x-amz-target"), String("one"))
    op.set_header(String("X-Amz-Target"), String("two"))
    assert_equal(len(op.header_names), 1)
    assert_equal(op.header("X-AMZ-TARGET"), "two")


def main() raises:
    test_aws_json_sqs()
    test_localstack_temporary_credential()
    test_s3_get()
    test_base_path_endpoint()
    test_content_length_on_bodyless_requests()
    test_refusals()
    print("OK")
