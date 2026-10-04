# The awsQuery / ec2Query runtime (aws_query.mojo): the form body, the
# parameter names, the result element and the error documents. Each row is
# derived from the rule it cites:
#
#   [BS]  botocore/serialize.py QuerySerializer: Action and Version first,
#         then the parameters; Content-Type
#         `application/x-www-form-urlencoded; charset=utf-8`; a flattened
#         list whose member has a locationName replaces the last segment
#   [PE]  botocore/utils.py percent_encode_sequence: Python `quote` with
#         safe='-._~' over the UTF-8 bytes, uppercase hex
#   [BP]  botocore/parsers.py QueryParser: the resultWrapper element of the
#         root (`_find_result_wrapped_shape`, a KeyError when absent)
#   [QE]  https://smithy.io/2.0/aws/protocols/aws-query-protocol.html,
#         "Error response serialization"
#   [EE]  https://smithy.io/2.0/aws/protocols/aws-ec2-query-protocol.html,
#         "Error response serialization"; botocore EC2QueryParser (RequestID)
#   [GE]  botocore ResponseParser `_do_generic_error_parsing`: the status is
#         the code of an empty or non-XML error body, and of a 5xx whose
#         body starts `<html>` (`_is_generic_error_response`)
#   [TS]  botocore Serializer `_timestamp_iso8601` (six fraction digits) and
#         `_timestamp_unixtimestamp` (whole seconds); komira writes a
#         fraction as milliseconds in both (aws_query.mojo's header)

from std.testing import assert_equal, assert_raises, assert_true

from komira_aws_core import (
    AWS_QUERY_CONTENT_TYPE,
    AWS_TS_ISO8601,
    AWS_TS_UNIX,
    AwsQueryWriter,
    AwsRequest,
    AwsResponse,
    HttpResult,
    aws_query_error,
    aws_query_key,
    aws_query_rename_last,
    aws_query_result,
    aws_query_set_body,
    aws_response_error_code,
    aws_text_ts,
    aws_xml_child,
    aws_xml_string_of,
)


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def test_action_and_version_come_first() raises:
    # [BS]
    var w = AwsQueryWriter(String("ListQueues"), String("2026-10-02"))
    assert_equal(w.text(), "Action=ListQueues&Version=2026-10-02")
    w.add(String("QueueNamePrefix"), String("a"))
    w.add(String("MaxResults"), String("5"))
    assert_equal(
        w.text(),
        "Action=ListQueues&Version=2026-10-02&QueueNamePrefix=a&MaxResults=5",
    )


def test_keys_and_values_are_percent_encoded() raises:
    # [PE] the unreserved set passes; a space is %20, never '+'; '/' and
    # ':' are encoded; a non-ASCII character is its UTF-8 bytes.
    var w = AwsQueryWriter(String("A"), String("v"))
    w.add(String("K.member.1"), String("a-b_c.d~e"))
    w.add(String("T"), String("2026-09-15T12:00:00Z"))
    w.add(String("S"), String("a b/c+d=e&f"))
    w.add(String("U"), String("é"))
    w.add(String("B"), String("dmFsdWU="))
    assert_equal(
        w.text(),
        "Action=A&Version=v&K.member.1=a-b_c.d~e&T=2026-09-15T12%3A00%3A00Z"
        + "&S=a%20b%2Fc%2Bd%3De%26f&U=%C3%A9&B=dmFsdWU%3D",
    )


def test_an_empty_value_is_key_equals() raises:
    # [BS] an empty awsQuery list is `Name=`.
    var w = AwsQueryWriter(String("QueryLists"), String("2026-10-02"))
    w.add(String("ListArg"), String(""))
    assert_equal(w.text(), "Action=QueryLists&Version=2026-10-02&ListArg=")


def test_parameter_names() raises:
    assert_equal(aws_query_key(String(""), String("Foo")), "Foo")
    assert_equal(aws_query_key(String("Nested"), String("Foo")), "Nested.Foo")
    assert_equal(
        aws_query_key(String("A.member.1"), String("hi")), "A.member.1.hi"
    )
    # [BS] '.'.join(prefix.split('.')[:-1] + [name])
    assert_equal(aws_query_rename_last(String("Hi"), String("item")), "item")
    assert_equal(
        aws_query_rename_last(String("A.B.Hi"), String("item")), "A.B.item"
    )


def test_set_body_sets_the_form_and_its_content_type() raises:
    # [BS]
    var req = AwsRequest(String("POST"), String("/"))
    var w = AwsQueryWriter(String("Op"), String("1"))
    w.add(String("X"), String("y"))
    aws_query_set_body(req, w)
    assert_equal(req.body_text(), "Action=Op&Version=1&X=y")
    assert_equal(req.header(String("Content-Type")), AWS_QUERY_CONTENT_TYPE)
    assert_equal(
        String(AWS_QUERY_CONTENT_TYPE),
        "application/x-www-form-urlencoded; charset=utf-8",
    )


def test_the_result_element_is_handed_over() raises:
    # [BP]
    var body = _bytes(
        '<GetQueueUrlResponse xmlns="http://queue.amazonaws.com/doc/2026-10-02/">'
        + "<GetQueueUrlResult><QueueUrl>https://q/1</QueueUrl></GetQueueUrlResult>"
        + "<ResponseMetadata><RequestId>r</RequestId></ResponseMetadata>"
        + "</GetQueueUrlResponse>"
    )
    var node = aws_query_result(body, String("GetQueueUrlResult"))
    assert_equal(node.local, "GetQueueUrlResult")
    var i = aws_xml_child(node, String("QueueUrl"))
    assert_true(i >= 0)
    assert_equal(aws_xml_string_of(node.children[i]), "https://q/1")


def test_an_empty_body_is_an_empty_result() raises:
    var node = aws_query_result(List[UInt8](), String("OpResult"))
    assert_equal(len(node.children), 0)


def test_a_missing_result_element_is_refused() raises:
    # [BP] botocore raises (a KeyError) rather than read nothing.
    var body = _bytes("<OpResponse><Other/></OpResponse>")
    with assert_raises(contains="holds no <OpResult> element"):
        _ = aws_query_result(body, String("OpResult"))


def test_a_body_that_is_not_utf8_or_xml_is_refused() raises:
    var bad: List[UInt8] = [UInt8(0x3C), UInt8(0x61), UInt8(0xFF), UInt8(0x3E)]
    with assert_raises(contains="UTF-8"):
        _ = aws_query_result(bad, String("OpResult"))
    with assert_raises(contains="not well-formed XML"):
        _ = aws_query_result(_bytes("<OpResponse>"), String("OpResult"))


def _err(
    var resp: AwsResponse, code: String, message: String, request_id: String
) raises:
    var e = aws_query_error(resp)
    assert_equal(e.status, resp.status)
    assert_equal(e.code, code)
    assert_equal(e.message, message)
    assert_equal(e.request_id, request_id)


def test_query_error_document() raises:
    # [QE] pretty-printed, as the corpus's QueryInvalidGreetingError.
    var r = AwsResponse.of_text(
        400,
        "<ErrorResponse>\n   <Error>\n      <Type>Sender</Type>\n"
        + "      <Code>InvalidGreeting</Code>\n      <Message>Hi</Message>\n"
        + "   </Error>\n   <RequestId>foo-id</RequestId>\n</ErrorResponse>\n",
    )
    _err(r^, "InvalidGreeting", "Hi", "foo-id")


def test_ec2_error_document() raises:
    # [EE] <Errors> holds the <Error>; the request id is <RequestID>.
    var r = AwsResponse.of_text(
        400,
        "<Response><Errors><Error><Code>InvalidInstanceID.Malformed</Code>"
        + "<Message>Invalid id</Message></Error></Errors>"
        + "<RequestID>ec2-req</RequestID></Response>",
    )
    _err(r^, "InvalidInstanceID.Malformed", "Invalid id", "ec2-req")


def test_a_bare_error_root() raises:
    # Read as the shared XML reader reads restXml's bare <Error>; botocore's
    # QueryParser does not read it, and no awsQuery service sends one.
    var r = AwsResponse.of_text(
        400, "<Error><Code>Echo</Code><Message>post / http/1.1</Message></Error>"
    )
    _err(r^, "Echo", "post / http/1.1", "")


def test_the_request_id_header_wins() raises:
    var r = AwsResponse.of_text(
        400,
        "<ErrorResponse><Error><Code>C</Code></Error>"
        + "<RequestId>body-id</RequestId></ErrorResponse>",
    )
    r.add_header(String("x-amzn-RequestId"), String("hdr-id"))
    _err(r^, "C", "", "hdr-id")


def test_an_empty_or_non_xml_body_takes_the_status() raises:
    # [GE]
    _err(AwsResponse.of_text(503, String("")), "503", "", "")
    _err(AwsResponse.of_text(502, String("<html>bad gateway")), "502", "", "")
    # A well-formed 5xx <html> page (a load balancer's) is generic too.
    _err(
        AwsResponse.of_text(503, String("<html><body>busy</body></html>")),
        "503",
        "",
        "",
    )


def test_xml_naming_no_code_has_an_empty_code() raises:
    _err(AwsResponse.of_text(400, String("<Oops/>")), "", "", "")
    # A 4xx <html> page is XML naming no code, not a generic error.
    _err(AwsResponse.of_text(403, String("<html/>")), "", "", "")


def test_the_retry_classifier_reads_an_ec2_code() raises:
    # [EE] the retry path reads the same reader, so an ec2 throttling code
    # is not "".
    var res = HttpResult(
        503,
        _bytes(
            "<Response><Errors><Error><Code>RequestLimitExceeded</Code>"
            + "<Message>slow down</Message></Error></Errors>"
            + "<RequestID>r</RequestID></Response>"
        ),
    )
    assert_equal(aws_response_error_code(res), "RequestLimitExceeded")


def test_a_fraction_of_a_second() raises:
    # [TS] pinned: milliseconds, trailing zeros cut, in date-time and in
    # epoch-seconds (botocore: `.500000Z` and `1789473600`). A whole second
    # is written as botocore writes it.
    var w = AwsQueryWriter(String("Op"), String("1"))
    w.add(String("T"), aws_text_ts(1789473600.5, AWS_TS_ISO8601))
    w.add(String("E"), aws_text_ts(1789473600.5, AWS_TS_UNIX))
    w.add(String("W"), aws_text_ts(1789473600.0, AWS_TS_ISO8601))
    w.add(String("V"), aws_text_ts(1789473600.0, AWS_TS_UNIX))
    assert_equal(
        w.text(),
        "Action=Op&Version=1&T=2026-09-15T12%3A00%3A00.5Z&E=1789473600.5"
        + "&W=2026-09-15T12%3A00%3A00Z&V=1789473600",
    )


def test_the_message_is_cleaned_and_nothing_else_is_read() raises:
    # A control character in the message (a TAB, which XML allows) is a
    # space, and members of the error other than Code and Message are not
    # read.
    var r = AwsResponse.of_text(
        400,
        "<ErrorResponse><Error><Code>C</Code><Message>a\tb</Message>"
        + "<Secret>s</Secret></Error></ErrorResponse>",
    )
    _err(r^, "C", "a b", "")


def main() raises:
    test_action_and_version_come_first()
    test_keys_and_values_are_percent_encoded()
    test_an_empty_value_is_key_equals()
    test_parameter_names()
    test_set_body_sets_the_form_and_its_content_type()
    test_the_result_element_is_handed_over()
    test_an_empty_body_is_an_empty_result()
    test_a_missing_result_element_is_refused()
    test_a_body_that_is_not_utf8_or_xml_is_refused()
    test_query_error_document()
    test_ec2_error_document()
    test_a_bare_error_root()
    test_the_request_id_header_wins()
    test_an_empty_or_non_xml_body_takes_the_status()
    test_xml_naming_no_code_has_an_empty_code()
    test_the_retry_classifier_reads_an_ec2_code()
    test_a_fraction_of_a_second()
    test_the_message_is_cleaned_and_nothing_else_is_read()
    print("OK")
