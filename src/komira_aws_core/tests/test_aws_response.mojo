# Request and response bodies as bytes, the pure AwsResponse a generated
# parser reads, and AwsErrorInfo: header lookup is case-insensitive, a
# prefix lookup names each header by the rest of its name, body_text refuses
# bytes that are not well-formed UTF-8 (and never quotes them), and an error
# carries the status, code, message and request id and nothing else of the
# body. A credential response built from bytes refuses ill-formed UTF-8.

from std.testing import assert_equal, assert_false, assert_true

from komira_aws_core import (
    aws_client_error_code,
    AWS_REQUEST_ID_MAX_BYTES,
    AwsErrorInfo,
    AwsRequest,
    AwsResponse,
    CredentialHttpResponse,
    HttpResult,
    aws_error_code_from_body,
    aws_error_message_from_body,
    aws_json_error_info,
    aws_query_error_code,
)


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _refuses_text(var body: List[UInt8], what: String) raises:
    var r = AwsResponse(200, body^)
    try:
        _ = r.body_text()
    except e:
        assert_true(String(e).find("not well-formed UTF-8") >= 0, String(e))
        return
    raise Error("body_text accepted " + what)


def test_request_body() raises:
    var req = AwsRequest(String("PUT"), String("/k?x-id=PutObject"))
    assert_equal(len(req.body), 0)
    assert_equal(req.body_text(), "")
    req.set_body_text(String("héllo"))
    assert_equal(len(req.body), 6)
    assert_equal(req.body_text(), "héllo")
    req.body = [UInt8(0x80)]
    try:
        _ = req.body_text()
        raise Error("AwsRequest.body_text accepted a lone continuation byte")
    except e:
        assert_true(String(e).find("the AWS request body") >= 0, String(e))


def test_response_headers() raises:
    var r = AwsResponse.of_text(200, String("{}"))
    r.add_header(String("Content-Type"), String("application/json"))
    r.add_header(String("x-amz-meta-Color"), String("red"))
    r.add_header(String("X-AMZ-META-size"), String("10"))
    r.add_header(String("x-amz-meta-"), String("nameless"))
    r.add_header(String("x-amz-metadata-directive"), String("COPY"))
    r.add_header(String("x-amzn-RequestId"), String(""))
    assert_equal(r.header("content-type"), "application/json")
    assert_equal(r.header("CONTENT-TYPE"), "application/json")
    assert_equal(r.header("absent"), "")
    # Present with an empty value is not absent.
    assert_true(r.has_header("X-Amzn-RequestId"))
    assert_false(r.has_header("absent"))
    var meta = r.headers_with_prefix(String("X-Amz-Meta-"))
    assert_equal(len(meta), 2)
    assert_equal(meta[0].name, "Color")
    assert_equal(meta[0].value, "red")
    assert_equal(meta[1].name, "size")
    assert_equal(meta[1].value, "10")
    assert_equal(len(r.headers_with_prefix(String("x-amz-nothing-"))), 0)
    # A name or prefix holding a byte at or above 0x80 is no header name: it
    # matches nothing, so no name is cut inside a character.
    var odd = AwsResponse.of_text(200, String(""))
    odd.add_header(String("x-amz-meta-é"), String("1"))
    odd.add_header(String("éx-amz-meta-a"), String("2"))
    odd.add_header(String("x-amz-meta-b"), String("3"))
    var got = odd.headers_with_prefix(String("x-amz-meta-"))
    assert_equal(len(got), 1)
    assert_equal(got[0].name, "b")
    assert_equal(len(odd.headers_with_prefix(String("é"))), 0)


def test_response_body_text() raises:
    var r = AwsResponse(200, _bytes(String("ok €")))
    assert_equal(r.body_text(), "ok €")
    assert_equal(AwsResponse(204, List[UInt8]()).body_text(), "")
    # Each is malformed UTF-8: a lone continuation byte, a truncated
    # sequence, an overlong '/', a UTF-16 surrogate, above U+10FFFF, and a
    # byte that never appears in UTF-8.
    _refuses_text([UInt8(0x80)], "a lone continuation byte")
    _refuses_text([UInt8(0x61), UInt8(0xE2), UInt8(0x82)], "a truncated sequence")
    _refuses_text([UInt8(0xC0), UInt8(0xAF)], "an overlong '/'")
    _refuses_text([UInt8(0xE0), UInt8(0x80), UInt8(0xAF)], "an overlong 3-byte form")
    _refuses_text([UInt8(0xED), UInt8(0xA0), UInt8(0x80)], "a surrogate")
    _refuses_text(
        [UInt8(0xF4), UInt8(0x90), UInt8(0x80), UInt8(0x80)], "U+110000"
    )
    _refuses_text([UInt8(0xFF)], "0xFF")
    # The largest code point and the last before the surrogates are fine.
    var ok = AwsResponse(
        200,
        [
            UInt8(0xF4), UInt8(0x8F), UInt8(0xBF), UInt8(0xBF),
            UInt8(0xED), UInt8(0x9F), UInt8(0xBF),
        ],
    )
    assert_equal(len(ok.body_text().as_bytes()), 7)


def test_http_result_to_response() raises:
    var h = HttpResult(404, _bytes(String('{"__type":"NotFound"}')))
    h.add_header(String("x-amzn-RequestId"), String("req-1"))
    var r = h.to_response()
    assert_equal(r.status, 404)
    assert_equal(r.header("X-Amzn-RequestId"), "req-1")
    assert_equal(r.body_text(), '{"__type":"NotFound"}')
    assert_equal(h.body_text(), '{"__type":"NotFound"}')
    # into_response moves the same status, headers and body.
    var m = h^.into_response()
    assert_equal(m.status, 404)
    assert_equal(len(m.header_names), 1)
    assert_equal(m.header("x-amzn-requestid"), "req-1")
    assert_equal(m.body_text(), '{"__type":"NotFound"}')


def test_error_readers_on_bytes() raises:
    var body = _bytes(
        String('{"__type":"com.amazon#ThrottlingException","message":"slow down"}')
    )
    assert_equal(aws_error_code_from_body(body), "ThrottlingException")
    assert_equal(aws_error_message_from_body(body), "slow down")
    # Bytes that are not UTF-8 are no error body: nothing is read from them.
    var bad: List[UInt8] = [UInt8(0x7B), UInt8(0xFF), UInt8(0x7D)]
    assert_equal(aws_error_code_from_body(bad), "")
    assert_equal(aws_error_message_from_body(bad), "")


def test_json_error_info() raises:
    var r = AwsResponse.of_text(
        400,
        String(
            '{"__type":"aws.protocoltests.json10#ComplexError:http://x",'
            + '"message":"bad\\nthing","Secret":"hunter2"}'
        ),
    )
    r.add_header(String("x-amzn-RequestId"), String("6c1e9b5c-0f1a-4e3e-9d7e"))
    var info = aws_json_error_info(r)
    assert_equal(info.status, 400)
    assert_equal(info.code, "ComplexError")
    assert_equal(info.message, "bad thing")
    assert_equal(info.request_id, "6c1e9b5c-0f1a-4e3e-9d7e")
    var text = String(info.to_error(String("Json10.Op")))
    assert_equal(
        text,
        "Json10.Op failed: HTTP 400 ComplexError: bad thing"
        + " (request id 6c1e9b5c-0f1a-4e3e-9d7e)",
    )
    assert_true(text.find("hunter2") < 0, text)
    # A body that names nothing: only the status.
    var bare = aws_json_error_info(AwsResponse.of_text(503, String("<html/>")))
    assert_equal(bare.code, "")
    assert_equal(bare.message, "")
    assert_equal(bare.request_id, "")
    assert_equal(String(bare.to_error(String("Op"))), "Op failed: HTTP 503")
    # A request id that is too long or holds a space or control byte is not
    # carried.
    var long_id = String("")
    for _ in range(AWS_REQUEST_ID_MAX_BYTES + 1):
        long_id += "a"
    var ids: List[String] = [long_id, String("a b"), String("a\tb")]
    for i in range(len(ids)):
        var e = AwsResponse.of_text(500, String("{}"))
        e.add_header(String("x-amzn-requestid"), ids[i])
        assert_equal(aws_json_error_info(e).request_id, "")
    # The X-Amzn-Errortype header names the code before the body does, and
    # is cleaned the same way; a header that cleans to nothing falls back to
    # the body.
    var hdr = AwsResponse.of_text(400, String('{"__type":"FromBody"}'))
    hdr.add_header(
        String("x-amzn-errortype"),
        String("aws.protocoltests#FooError:http://internal.amazon.com/"),
    )
    assert_equal(aws_json_error_info(hdr).code, "FooError")
    var hdr_only = AwsResponse.of_text(400, String(""))
    hdr_only.add_header(String("X-Amzn-Errortype"), String("BarError"))
    assert_equal(aws_json_error_info(hdr_only).code, "BarError")
    var hdr_junk = AwsResponse.of_text(400, String('{"code":"FromCode"}'))
    hdr_junk.add_header(String("X-Amzn-Errortype"), String("!!"))
    assert_equal(aws_json_error_info(hdr_junk).code, "FromCode")
    # A response that names no code leaves it "" (botocore would use the
    # status); the status stays in `status`.
    var nameless = aws_json_error_info(AwsResponse.of_text(500, String("{}")))
    assert_equal(nameless.code, "")
    assert_equal(nameless.status, 500)
    # An awsQueryCompatible error's `x-amzn-query-error` code, the text
    # before its one `;`, wins over X-Amzn-Errortype and the body; a header
    # of another form is not read.
    var qc = AwsResponse.of_text(
        400, String('{"__type":"com.amazonaws.sqs#QueueDoesNotExist"}')
    )
    qc.add_header(String("X-Amzn-Errortype"), String("QueueDoesNotExist"))
    qc.add_header(
        String("x-amzn-query-error"),
        String("AWS.SimpleQueueService.NonExistentQueue;Sender"),
    )
    assert_equal(
        aws_json_error_info(qc).code, "AWS.SimpleQueueService.NonExistentQueue"
    )
    assert_equal(aws_query_error_code(qc), "AWS.SimpleQueueService.NonExistentQueue")
    var malformed: List[String] = [
        String("NoType"),
        String(";Sender"),
        String("A;B;C"),
        String("!!;Sender"),
    ]
    for i in range(len(malformed)):
        var m = AwsResponse.of_text(
            400, String('{"__type":"com.amazonaws.sqs#QueueDoesNotExist"}')
        )
        m.add_header(String("x-amzn-query-error"), malformed[i])
        assert_equal(aws_query_error_code(m), "")
        assert_equal(aws_json_error_info(m).code, "QueueDoesNotExist")
    var direct = AwsErrorInfo(409, String("Conflict"), String(""), String(""))
    assert_equal(String(direct.to_error(String("Op"))), "Op failed: HTTP 409 Conflict")


def test_credential_response_of_bytes() raises:
    var ok = CredentialHttpResponse.of_bytes(200, Span(_bytes(String("rôle\n"))))
    assert_equal(ok.status, 200)
    assert_equal(ok.body, "rôle\n")
    var bad: List[UInt8] = [UInt8(0x61), UInt8(0xC3)]
    try:
        _ = CredentialHttpResponse.of_bytes(200, Span(bad))
        raise Error("of_bytes accepted a truncated sequence")
    except e:
        assert_true(String(e).find("not well-formed UTF-8") >= 0, String(e))


def test_client_error_code() raises:
    # The generated client's raised form: `<Service>.<Op> failed: HTTP
    # <status> <code> <message>`. Catches a code read with the message
    # glued on, a match on another operation's error, and a transport
    # failure or a code-less answer read as a code.
    var op = String("SecretsManager.PutSecretValue")
    assert_equal(
        aws_client_error_code(
            op,
            String(
                "SecretsManager.PutSecretValue failed: HTTP 400"
                " ResourceNotFoundException Secrets Manager can't find the"
                " specified secret."
            ),
        ),
        "ResourceNotFoundException",
    )
    assert_equal(
        aws_client_error_code(op, String("SecretsManager.PutSecretValue failed: HTTP 400 ResourceExistsException ")),
        "ResourceExistsException",
    )
    var not_codes: List[String] = [
        "SecretsManager.CreateSecret failed: HTTP 400 ResourceExistsException x",
        "SecretsManager.PutSecretValue failed: HTTP  ResourceExistsException x",
        "SecretsManager.PutSecretValue failed: HTTP 400",
        "SecretsManager.PutSecretValue failed: HTTP 400  a message only",
        "SecretsManager.PutSecretValue: connection refused",
        "HttpError[CONNECT_FAILED] errno 111",
    ]
    for i in range(len(not_codes)):
        assert_equal(aws_client_error_code(op, not_codes[i]), "", not_codes[i])


def main() raises:
    test_request_body()
    test_response_headers()
    test_response_body_text()
    test_http_result_to_response()
    test_error_readers_on_bytes()
    test_json_error_info()
    test_credential_response_of_bytes()
    test_client_error_code()
    print("OK")
