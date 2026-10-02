# restXml errors (aws_xml.mojo): `aws_rest_xml_error`, `aws_xml_error_info`
# and S3's 200-with-<Error> check `aws_xml_body_is_error`. Each row is
# derived from the rule it cites:
#
#   [RX]  https://smithy.io/2.0/aws/protocols/aws-restxml-protocol.html,
#         "Error response serialization" (<ErrorResponse><Error>, and the
#         bare <Error> of @awsQueryError / S3)
#   [S3]  https://docs.aws.amazon.com/AmazonS3/latest/API/ErrorResponses.html
#         (the <Error> document; x-amz-request-id; a HEAD error has no
#         body)
#   [200] https://docs.aws.amazon.com/AmazonS3/latest/API/API_CopyObject.html
#         and API_CompleteMultipartUpload.html (an error after the 200 OK
#         is sent is embedded in its body), and botocore's handlers.py
#         `_looks_like_special_case_error` (a 200 body that is not XML is
#         treated the same way: it was cut short)
#   [BC]  botocore's RestXMLParser `_do_error_parse`: the status is the code
#         of an empty or non-XML body

from std.testing import assert_equal, assert_false, assert_true

from komira_aws_core import (
    AWS_ERROR_MESSAGE_MAX_BYTES,
    AwsResponse,
    aws_rest_xml_error,
    aws_xml_body_is_error,
    aws_xml_error_info,
)


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _err(
    var resp: AwsResponse, code: String, message: String, request_id: String
) raises:
    var e = aws_rest_xml_error(resp)
    assert_equal(e.status, resp.status)
    assert_equal(e.code, code)
    assert_equal(e.message, message)
    assert_equal(e.request_id, request_id)


def test_error_response_form() raises:
    # [RX] <ErrorResponse><Error>...</Error><RequestId/></ErrorResponse>,
    # as Route 53 and CloudFront answer; the request id from the body when
    # no header carries one.
    var r = AwsResponse.of_text(
        400,
        '<ErrorResponse xmlns="https://route53.amazonaws.com/doc/2013-04-01/">'
        + "<Error><Type>Sender</Type><Code>InvalidInput</Code>"
        + "<Message>Invalid resource type: foo</Message></Error>"
        + "<RequestId>req-1</RequestId></ErrorResponse>",
    )
    _err(r^, "InvalidInput", "Invalid resource type: foo", "req-1")
    # Pretty-printed: the text of Code and Message is trimmed.
    var p = AwsResponse.of_text(
        403,
        "<?xml version=\"1.0\"?>\n<ErrorResponse>\n  <Error>\n"
        + "    <Code>\n      AccessDenied\n    </Code>\n"
        + "    <Message> denied </Message>\n  </Error>\n</ErrorResponse>\n",
    )
    _err(p^, "AccessDenied", "denied", "")


def test_bare_error_form() raises:
    # [S3] the bare <Error> document; the request id is the
    # x-amz-request-id header, which the body's copy does not override.
    var r = AwsResponse.of_text(
        404,
        "<Error><Code>NoSuchKey</Code>"
        + "<Message>The specified key does not exist.</Message>"
        + "<Key>k</Key><RequestId>body-id</RequestId>"
        + "<HostId>host</HostId></Error>",
    )
    r.add_header("x-amz-request-id", "hdr-id")
    _err(r^, "NoSuchKey", "The specified key does not exist.", "hdr-id")
    # No header: the body's <RequestId>.
    var b = AwsResponse.of_text(
        409,
        "<Error><Code>BucketNotEmpty</Code><Message>m</Message>"
        + "<RequestId>body-id</RequestId></Error>",
    )
    _err(b^, "BucketNotEmpty", "m", "body-id")
    # x-amzn-RequestId comes before x-amz-request-id.
    var h = AwsResponse.of_text(412, "<Error><Code>PreconditionFailed</Code></Error>")
    h.add_header("X-Amz-Request-Id", "s3-id")
    h.add_header("x-amzn-requestid", "amzn-id")
    _err(h^, "PreconditionFailed", "", "amzn-id")
    # The document in S3's namespace reads the same.
    var ns = AwsResponse.of_text(
        403,
        '<Error xmlns="http://s3.amazonaws.com/doc/2006-03-01/">'
        + "<Code>AccessDenied</Code><Message>Access Denied</Message></Error>",
    )
    _err(ns^, "AccessDenied", "Access Denied", "")


def test_status_as_code() raises:
    # [S3] [BC] a HEAD error has no body: the code is the status.
    var head = AwsResponse(404, List[UInt8]())
    head.add_header("x-amz-request-id", "head-id")
    _err(head^, "404", "", "head-id")
    # [BC] a body that is not XML (a proxy's page, a cut-short body).
    _err(AwsResponse.of_text(503, "<html><body>busy"), "503", "", "")
    _err(AwsResponse.of_text(502, "Bad Gateway"), "502", "", "")
    var notutf8: List[UInt8] = [UInt8(0x3C), UInt8(0xFF), UInt8(0x3E)]
    _err(AwsResponse(500, notutf8^), "500", "", "")
    # XML that names no error: code "".
    _err(AwsResponse.of_text(400, "<Other><Code>X</Code></Other>"), "", "", "")
    _err(AwsResponse.of_text(400, "<Error/>"), "", "", "")


def test_cleaning() raises:
    # The code keeps [A-Za-z0-9_.-] only; a message has control bytes as
    # spaces and is capped; a request id with a space is dropped.
    var r = AwsResponse.of_text(
        400,
        "<Error><Code>Bad Code!</Code><Message>line1&#10;line2</Message>"
        + "<RequestId>has space</RequestId></Error>",
    )
    _err(r^, "BadCode", "line1 line2", "")
    var long = String("")
    for _ in range(AWS_ERROR_MESSAGE_MAX_BYTES + 10):
        long += "m"
    var l = aws_rest_xml_error(
        AwsResponse.of_text(400, "<Error><Message>" + long + "</Message></Error>")
    )
    assert_equal(l.message.byte_length(), AWS_ERROR_MESSAGE_MAX_BYTES)
    # A code or message element holding elements is no text.
    _err(
        AwsResponse.of_text(400, "<Error><Code><x/></Code></Error>"), "", "", ""
    )
    # Only the code, message and request id are read from the body.
    var leak = aws_rest_xml_error(
        AwsResponse.of_text(
            400, "<Error><Code>C</Code><Secret>s3cr3t</Secret></Error>"
        )
    )
    assert_equal(String(leak.to_error("Op")).find("s3cr3t"), -1)


def test_error_info_from_bytes() raises:
    # The form a non-REST caller (the STS query response) reads: an
    # explicit request id wins over the body's.
    var body = _bytes(
        '<ErrorResponse xmlns="https://sts.amazonaws.com/doc/2011-06-15/">'
        + "<Error><Type>Sender</Type><Code>ExpiredTokenException</Code>"
        + "<Message>Token expired</Message></Error>"
        + "<RequestId>sts-body</RequestId></ErrorResponse>"
    )
    var e = aws_xml_error_info(400, body, "")
    assert_equal(e.code, "ExpiredTokenException")
    assert_equal(e.message, "Token expired")
    assert_equal(e.request_id, "sts-body")
    var e2 = aws_xml_error_info(400, body, "given")
    assert_equal(e2.request_id, "given")


def _is_error(status: Int, body: String) -> Bool:
    return aws_xml_body_is_error(AwsResponse.of_text(status, body))


def test_200_with_error() raises:
    # [200] a 200 whose document is <Error> is an error.
    assert_true(
        _is_error(
            200,
            "<Error><Code>InternalError</Code>"
            + "<Message>We encountered an internal error.</Message></Error>",
        )
    )
    assert_true(
        _is_error(
            200,
            '<?xml version="1.0" encoding="UTF-8"?>\n\n<Error>'
            + "<Code>SlowDown</Code></Error>",
        )
    )
    # [200] a 200 body cut short is not XML: an error too.
    assert_true(
        _is_error(200, "<CompleteMultipartUploadResult><Location>http")
    )
    # A 200 with the operation's own document, or with no body, is not.
    assert_false(
        _is_error(
            200,
            "<CopyObjectResult><ETag>&quot;e&quot;</ETag></CopyObjectResult>",
        )
    )
    assert_false(_is_error(200, ""))
    # The root must be <Error> in no namespace, as botocore compares it.
    assert_false(_is_error(200, '<Error xmlns="urn:x"><Code>C</Code></Error>'))
    # An <Error> deeper in the document is not the root.
    assert_false(_is_error(200, "<Result><Error>none</Error></Result>"))
    # Only a 200: other statuses are already errors, or are not this case.
    assert_false(_is_error(500, "<Error><Code>InternalError</Code></Error>"))
    assert_false(_is_error(206, "<Error><Code>InternalError</Code></Error>"))
    assert_false(_is_error(204, "not xml"))


def main() raises:
    test_error_response_form()
    test_bare_error_form()
    test_status_as_code()
    test_cleaning()
    test_error_info_from_bytes()
    test_200_with_error()
    print("OK")
