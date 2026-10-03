# The signing half of a send, byte for byte: each request below is built by
# `build_sigv4_signed_request` with fake keys at a fixed clock and compared
# with tests/fixtures/<name>.request, recorded from an independent SigV4
# implementation over the same inputs. Also: the refusals, that an
# AwsRequest from a generated builder signs its X-Amz-Target, and each
# payload-signing arm.
#
# The payload arms are checked against signatures this package did not
# compute: AWS's published S3 "PUT Object" example (Signature Version 4,
# "Signature Calculations for the Authorization Header: Transferring Payload
# in a Single Chunk", examplebucket / test$file.text), which `.hashed()` and
# `.precomputed()` must both reproduce, and the same request with
# UNSIGNED-PAYLOAD, signed with openssl HMAC-SHA256 over the canonical
# request. The aws-c-auth get-vanilla-query* cases (staged at aws_c_auth/,
# the archive //third_party/aws_c_auth pins) go through the builder too, each
# signed with its own context.json: the query in the uri is signed as it
# stands (s3_get_object.request carries a key with no value, `acl`). The
# suite's post-x-www-form-urlencoded cases do not: they sign Content-Length,
# which this builder never signs, so they are covered by
# test_sigv4_test_suite alone.

from std.testing import assert_equal, assert_true

from komira_aws_core import (
    AwsCredential,
    AwsEndpoint,
    AwsPayloadSigning,
    AwsRequest,
    CredentialHttpRequest,
    EMPTY_PAYLOAD_SHA256,
    FixedClock,
    Header,
    SigV4SigningContext,
    amz_date_from_unix,
    aws_token_string,
    aws_ts_from_token,
    build_sigv4_signed_request,
    is_s3_signing_name,
    resolve_endpoint,
    sigv4_sign_payload_hash,
)


comptime _FIX = "src/komira_aws_core/tests/fixtures/"
comptime _KEY = "AKIDEXAMPLE"
comptime _SECRET = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
# 2026-09-19T12:00:00Z
comptime _NOW = 1789819200


def _wire(req: CredentialHttpRequest) -> String:
    """The request bytes as text (every request here has a text body)."""
    return String(unsafe_from_utf8=Span(req.to_wire()))


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _golden(req: CredentialHttpRequest, name: String) raises:
    var want: String
    with open(String(_FIX) + name, "r") as f:
        want = f.read()
    assert_true(want.find("\r\n") >= 0, name + " lost its CRLF line ends")
    var got = _wire(req)
    if got != want:
        raise Error(
            "request differs from " + name + "\n--- got ---\n" + got
            + "\n--- want ---\n" + want
        )


def _cut(s: String, i: Int, j: Int) -> String:
    return String(StringSlice(unsafe_from_utf8=s.as_bytes()[i:j]))


def _cred() -> AwsCredential:
    return AwsCredential(String(_KEY), String(_SECRET), String(""))


def test_aws_json_sqs() raises:
    # Built the way a generated client's `send` builds it: the operation's
    # AwsRequest, Content-Type split off, every other header passed as extra.
    var op = AwsRequest(String("POST"), String("/"))
    op.set_header(String("X-Amz-Target"), String("AmazonSQS.ListQueues"))
    op.set_header(String("Content-Type"), String("application/x-amz-json-1.0"))
    op.set_body_text(String('{"QueueNamePrefix":"komira"}'))
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
        Span(op.body),
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
    assert_true(_wire(req).find(_SECRET) < 0, "the secret is on the wire")


def test_localstack_temporary_credential() raises:
    var clock = FixedClock(_NOW)
    var extra: List[Header] = [
        Header(String("X-Amz-Target"), String("Logs_20140328.DescribeLogGroups"))
    ]
    var body = _bytes(String('{"limit":5}'))
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
        Span(body),
        extra,
        clock,
    )
    _golden(req, "aws_json_logs_localstack_session.request")
    assert_equal(req.scheme, "http")
    assert_equal(req.port, 4566)


def test_s3_get() raises:
    var clock = FixedClock(_NOW)
    var none = List[UInt8]()
    var req = build_sigv4_signed_request(
        String("GET"),
        _cred(),
        String("us-west-2"),
        String("s3"),
        AwsEndpoint.https("my-bucket.s3.us-west-2.amazonaws.com"),
        String("/photos/2026/a%20b.jpg?versionId=v1&acl"),
        String(""),
        Span(none),
        List[Header](),
        clock,
    )
    _golden(req, "s3_get_object.request")


def _path_signature(service: String, uri: String, s3_rules: Bool) raises -> String:
    """The Authorization of a body-less GET of `uri` signed directly, with
    the S3 rules (path as sent, payload header) or the default ones."""
    var headers = List[Header]()
    headers.append(Header(String("Host"), String("b.example.com")))
    var ctx = SigV4SigningContext(
        _cred(),
        String("us-west-2"),
        service,
        amz_date_from_unix(_NOW),
        sign_payload_header=s3_rules,
        normalize_path=not s3_rules,
        uri_encode_path=not s3_rules,
    )
    return sigv4_sign_payload_hash(
        String("GET"), uri, headers, String(EMPTY_PAYLOAD_SHA256), ctx
    ).authorization


def test_s3_signing_names() raises:
    # botocore's S3_SIGNING_NAMES all sign with S3's rules: the path as
    # sent (`a%20b` and the `./` neither re-encoded nor removed) and
    # x-amz-content-sha256. Any other name encodes the path again.
    var uri = String("/k/./a%20b.txt")
    var names: List[String] = ["s3", "s3-outposts", "s3-object-lambda", "s3express", "logs"]
    for i in range(len(names)):
        var clock = FixedClock(_NOW)
        var none = List[UInt8]()
        var req = build_sigv4_signed_request(
            String("GET"),
            _cred(),
            String("us-west-2"),
            names[i],
            AwsEndpoint.https("b.example.com"),
            uri,
            String(""),
            Span(none),
            List[Header](),
            clock,
        )
        var s3 = names[i] != "logs"
        assert_equal(is_s3_signing_name(names[i]), s3)
        assert_equal(
            req.header("Authorization"), _path_signature(names[i], uri, s3), names[i]
        )
        assert_equal(
            req.header("x-amz-content-sha256"),
            String(EMPTY_PAYLOAD_SHA256) if s3 else String(""),
            names[i],
        )
    # The two rules give different signatures for this path.
    assert_true(
        _path_signature(String("s3"), uri, True)
        != _path_signature(String("s3"), uri, False)
    )


def test_base_path_endpoint() raises:
    var clock = FixedClock(_NOW)
    var extra: List[Header] = [
        Header(String("X-Amz-Target"), String("DynamoDB_20120810.ListTables")),
        Header(String("x-amzn-query-mode"), String("true")),
    ]
    var body = _bytes(String("{}"))
    var req = build_sigv4_signed_request(
        String("POST"),
        _cred(),
        String("us-west-2"),
        String("dynamodb"),
        AwsEndpoint.parse("https://proxy.example.com:8443/aws/", "T"),
        String("/"),
        String("application/x-amz-json-1.0"),
        Span(body),
        extra,
        clock,
    )
    _golden(req, "aws_json_proxy_base_path.request")
    assert_equal(req.target, "/aws/")


def _signed(method: String, body: String) raises -> String:
    var clock = FixedClock(_NOW)
    var b = _bytes(body)
    return _wire(
        build_sigv4_signed_request(
            method,
            _cred(),
            String("us-east-1"),
            String("sqs"),
            AwsEndpoint.https("sqs.us-east-1.amazonaws.com"),
            String("/"),
            String(""),
            Span(b),
            List[Header](),
            clock,
        )
    )


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


# ---- payload signing ---------------------------------------------------------

# AWS's S3 SigV4 documentation example (see the header): every value below
# and the Date header in `_s3_put_example` are that example's, and its
# published signature depends on each of them.
comptime _S3_EXAMPLE_KEY = "AKIAIOSFODNN7EXAMPLE"
comptime _S3_EXAMPLE_SECRET = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
# The example's signing time (its x-amz-date).
comptime _S3_EXAMPLE_NOW = 1369353600
comptime _S3_EXAMPLE_BODY = "Welcome to Amazon S3."
comptime _S3_EXAMPLE_SHA256 = (
    "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072"
)
comptime _S3_EXAMPLE_SIGNED = (
    "SignedHeaders=date;host;x-amz-content-sha256;x-amz-date;x-amz-storage-class,"
)
# AWS's published signature of the example.
comptime _S3_EXAMPLE_SIGNATURE = (
    "98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd"
)
# The same request with UNSIGNED-PAYLOAD, signed with openssl.
comptime _S3_EXAMPLE_UNSIGNED_SIGNATURE = (
    "91c6efc02b5801e55e03b4a83a22d6b4f85a6010fa94d5a87f88e41c5ee1bf46"
)


def _s3_put_example(
    body: List[UInt8], payload: AwsPayloadSigning
) raises -> CredentialHttpRequest:
    var clock = FixedClock(_S3_EXAMPLE_NOW)
    var extra: List[Header] = [
        Header(String("Date"), String("Fri, 24 May 2013 00:00:00 GMT")),
        Header(String("x-amz-storage-class"), String("REDUCED_REDUNDANCY")),
    ]
    return build_sigv4_signed_request(
        String("PUT"),
        AwsCredential(
            String(_S3_EXAMPLE_KEY), String(_S3_EXAMPLE_SECRET), String("")
        ),
        String("us-east-1"),
        String("s3"),
        AwsEndpoint.https("examplebucket.s3.amazonaws.com"),
        String("/test%24file.text"),
        String(""),
        Span(body),
        extra,
        clock,
        payload,
    )


def _expect_signature(req: CredentialHttpRequest, sig: String) raises:
    var auth = req.header("Authorization")
    assert_true(auth.find(_S3_EXAMPLE_SIGNED) > 0, auth)
    assert_true(auth.endswith("Signature=" + sig), auth)


def test_payload_hashed() raises:
    # The default arm hashes the body: AWS's published signature.
    var body = _bytes(String(_S3_EXAMPLE_BODY))
    var req = _s3_put_example(body, AwsPayloadSigning.hashed())
    _expect_signature(req, String(_S3_EXAMPLE_SIGNATURE))
    assert_equal(req.header("x-amz-content-sha256"), String(_S3_EXAMPLE_SHA256))
    assert_equal(req.header("Content-Length"), "21")
    assert_true(_wire(req).endswith("\r\n\r\n" + String(_S3_EXAMPLE_BODY)))


def test_payload_precomputed() raises:
    # A caller-computed hash signs as the computed one does.
    var body = _bytes(String(_S3_EXAMPLE_BODY))
    var req = _s3_put_example(
        body, AwsPayloadSigning.precomputed(String(_S3_EXAMPLE_SHA256))
    )
    _expect_signature(req, String(_S3_EXAMPLE_SIGNATURE))
    # The builder does not re-hash: a hash of other bytes is what is signed
    # and sent, and the body still goes as given.
    var other = AwsPayloadSigning.precomputed(
        String("0000000000000000000000000000000000000000000000000000000000000000")
    )
    var req2 = _s3_put_example(body, other)
    assert_equal(
        req2.header("x-amz-content-sha256"),
        "0000000000000000000000000000000000000000000000000000000000000000",
    )
    assert_true(
        not req2.header("Authorization").endswith(String(_S3_EXAMPLE_SIGNATURE))
    )
    # Exactly 64 lowercase hex digits, or refused.
    var bad: List[String] = [
        String(""),
        _cut(String(_S3_EXAMPLE_SHA256), 0, 63),
        String(_S3_EXAMPLE_SHA256) + "0",
        String(_S3_EXAMPLE_SHA256).upper(),
        String("UNSIGNED-PAYLOAD"),
        String("g") + _cut(String(_S3_EXAMPLE_SHA256), 1, 64),
    ]
    for i in range(len(bad)):
        try:
            _ = AwsPayloadSigning.precomputed(bad[i])
            raise Error("precomputed accepted: " + bad[i])
        except e:
            assert_true(
                String(e).find("not 64 lowercase hex digits") >= 0, String(e)
            )
    # A value built directly, past `precomputed`, is checked by the builder:
    # a kind that is none of the three, or a hash that does not fit its kind.
    var direct: List[AwsPayloadSigning] = [
        AwsPayloadSigning(2, String("abc")),
        AwsPayloadSigning(7, String("")),
        AwsPayloadSigning(1, String(_S3_EXAMPLE_SHA256)),
        AwsPayloadSigning(0, String(_S3_EXAMPLE_SHA256)),
    ]
    var why: List[String] = [
        "not 64 lowercase hex digits",
        "none of hashed, unsigned, precomputed",
        "is not UNSIGNED-PAYLOAD",
        "carries a hash of its own",
    ]
    for i in range(len(direct)):
        try:
            _ = _s3_put_example(body, direct[i])
            raise Error("the builder accepted payload " + String(i))
        except e:
            assert_true(String(e).find(why[i]) >= 0, String(e))


def test_payload_unsigned() raises:
    var body = _bytes(String(_S3_EXAMPLE_BODY))
    var req = _s3_put_example(body, AwsPayloadSigning.unsigned())
    _expect_signature(req, String(_S3_EXAMPLE_UNSIGNED_SIGNATURE))
    assert_equal(req.header("x-amz-content-sha256"), "UNSIGNED-PAYLOAD")
    assert_true(_wire(req).endswith("\r\n\r\n" + String(_S3_EXAMPLE_BODY)))


def test_payload_header_outside_s3() raises:
    # Outside S3 a hashed payload sends no x-amz-content-sha256 (the
    # service hashes the body itself); an unsigned or precomputed one is
    # sent and signed, since the header is the only place it can be read.
    var clock = FixedClock(_NOW)
    var body = _bytes(String("{}"))
    var arms: List[AwsPayloadSigning] = [
        AwsPayloadSigning.hashed(),
        AwsPayloadSigning.unsigned(),
        AwsPayloadSigning.precomputed(
            String("44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a")
        ),
    ]
    var want: List[String] = [
        "",
        "UNSIGNED-PAYLOAD",
        "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a",
    ]
    for i in range(len(arms)):
        var req = build_sigv4_signed_request(
            String("POST"),
            _cred(),
            String("us-east-1"),
            String("sqs"),
            AwsEndpoint.https("sqs.us-east-1.amazonaws.com"),
            String("/"),
            String("application/x-amz-json-1.0"),
            Span(body),
            List[Header](),
            clock,
            arms[i],
        )
        assert_equal(req.header("x-amz-content-sha256"), want[i])
        var auth = req.header("Authorization")
        if i == 0:
            assert_true(auth.find("x-amz-content-sha256") < 0, auth)
        else:
            assert_true(
                auth.find(
                    "SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date,"
                )
                > 0,
                auth,
            )


def test_binary_body() raises:
    # A body that is not text goes on the wire byte for byte: its length is
    # the byte count and its hash is of those bytes.
    var body: List[UInt8] = [UInt8(0x00), UInt8(0xFF), UInt8(0xC3), UInt8(0x28)]
    var clock = FixedClock(_NOW)
    var req = build_sigv4_signed_request(
        String("PUT"),
        _cred(),
        String("us-west-2"),
        String("s3"),
        AwsEndpoint.https("my-bucket.s3.us-west-2.amazonaws.com"),
        String("/blob"),
        String("application/octet-stream"),
        Span(body),
        List[Header](),
        clock,
    )
    assert_equal(req.header("Content-Length"), "4")
    assert_equal(
        req.header("x-amz-content-sha256"),
        "964f2654baa736d82bff0a92bf9e0fb6aab491d2ffe26d33d162c1f975e07457",
    )
    var w = req.to_wire()
    assert_true(len(w) > 4)
    for i in range(4):
        assert_equal(w[len(w) - 4 + i], body[i])
    assert_equal(len(req.body), 4)
    try:
        _ = req.body_text()
        raise Error("body_text accepted bytes that are not UTF-8")
    except e:
        assert_true(String(e).find("not well-formed UTF-8") >= 0, String(e))


# ---- aws-c-auth query vectors through the builder ----------------------------

comptime _SUITE = "aws_c_auth/tests/aws-signing-test-suite/v4/"


def _read_text(path: String) raises -> String:
    with open(path, "r") as f:
        return f.read()


def _context_string(text: String, key: String) raises -> String:
    """The string value of `"key":` in a case's context.json (flat reading:
    each key the cases use is unique in the file, and no value is
    escaped)."""
    var at = text.find('"' + key + '"')
    if at < 0:
        raise Error("context.json has no " + key)
    var b = text.as_bytes()
    var i = at + key.byte_length() + 2
    while i < len(b) and (b[i] == UInt8(0x20) or b[i] == UInt8(0x0A)):
        i += 1
    if i >= len(b) or b[i] != UInt8(0x3A):
        raise Error("context.json: no ':' after " + key)
    i += 1
    while i < len(b) and (b[i] == UInt8(0x20) or b[i] == UInt8(0x0A)):
        i += 1
    if i >= len(b) or b[i] != UInt8(0x22):
        raise Error("context.json: " + key + " is not a string")
    var j = i + 1
    while j < len(b) and b[j] != UInt8(0x22):
        if b[j] == UInt8(0x5C):
            raise Error("context.json: escaped string in " + key)
        j += 1
    return String(StringSlice(unsafe_from_utf8=b[i + 1 : j]))


def _request_target(request_txt: String) raises -> String:
    var nl = request_txt.find("\n")
    var first = String(StringSlice(unsafe_from_utf8=request_txt.as_bytes()[0:nl]))
    if not first.startswith("GET ") or not first.endswith(" HTTP/1.1"):
        raise Error("unexpected request line: " + first)
    var b = first.as_bytes()
    return String(StringSlice(unsafe_from_utf8=b[4 : len(b) - 9]))


def _authorization(signed_txt: String) raises -> String:
    var lines = signed_txt.split("\n")
    for i in range(len(lines)):
        var line = String(lines[i])
        if line.startswith("Authorization:"):
            var b = line.as_bytes()
            return String(StringSlice(unsafe_from_utf8=b[14 : len(b)]))
    raise Error("no Authorization line")


def test_query_vectors_through_the_builder() raises:
    var cases: List[String] = [
        "get-vanilla-query",
        "get-vanilla-query-order-encoded",
        "get-vanilla-query-order-key-case",
        "get-vanilla-query-unreserved",
    ]
    var none = List[UInt8]()
    for i in range(len(cases)):
        var dir = String(_SUITE) + cases[i] + "/"
        var target = _request_target(_read_text(dir + "request.txt"))
        var context = _read_text(dir + "context.json")
        assert_true(context.find('"token"') < 0, cases[i])
        var clock = FixedClock(
            Int(aws_ts_from_token(aws_token_string(
                _context_string(context, "timestamp")
            )))
        )
        var req = build_sigv4_signed_request(
            String("GET"),
            AwsCredential(
                _context_string(context, "access_key_id"),
                _context_string(context, "secret_access_key"),
                String(""),
            ),
            _context_string(context, "region"),
            _context_string(context, "service"),
            AwsEndpoint.https("example.amazonaws.com"),
            target,
            String(""),
            Span(none),
            List[Header](),
            clock,
        )
        assert_equal(req.target, target)
        assert_equal(
            req.header("Authorization"),
            _authorization(_read_text(dir + "header-signed-request.txt")),
            cases[i],
        )


def _refused(extra: List[Header], method: String, uri: String, want: String) raises:
    var clock = FixedClock(_NOW)
    var body = _bytes(String("{}"))
    try:
        _ = build_sigv4_signed_request(
            method,
            _cred(),
            String("us-east-1"),
            String("sqs"),
            AwsEndpoint.https("sqs.us-east-1.amazonaws.com"),
            uri,
            String("application/x-amz-json-1.0"),
            Span(body),
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
    test_s3_signing_names()
    test_base_path_endpoint()
    test_content_length_on_bodyless_requests()
    test_payload_hashed()
    test_payload_precomputed()
    test_payload_unsigned()
    test_payload_header_outside_s3()
    test_binary_body()
    test_query_vectors_through_the_builder()
    test_refusals()
    print("OK")
