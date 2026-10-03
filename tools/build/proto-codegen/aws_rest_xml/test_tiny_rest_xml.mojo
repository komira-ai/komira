# The caller's test of a generated pure-mode restXml client
# (tiny_rest_xml.json, generated with the `s3` customization): the requests
# it builds (target, headers and XML body) and the responses it reads
# (headers, a wrapped and a flattened list, a structure), each compared
# exactly, and the two `s3` behaviors: a 200 whose body is an <Error> is
# raised as an HTTP 500 is, unless the output payload is a blob or a string
# or the operation has no output, and an Expires header that is not a date
# is left unset.
from komira_aws_tiny_xml.komira_aws_tiny_xml import (
    S3Config,
    S3GetBlobRequest,
    S3Part,
    S3PutThingRequest,
    S3SetConfigRequest,
    build_put_thing_request,
    build_set_config_request,
    parse_get_blob_response,
    parse_get_bytes_response,
    parse_get_policy_response,
    parse_put_thing_response,
    parse_set_config_response,
)
from komira_aws_core import AwsResponse
from std.testing import assert_equal, assert_false, assert_raises, assert_true


def test_put_thing_request() raises:
    var input = S3PutThingRequest(String("a b"))
    input.set_token(String("t"))
    input.set_size(Int64(5))
    var tags: List[String] = ["x", "y & z"]
    input.set_tags(tags^)
    var part = S3Part()
    part.set_number(Int32(1))
    var digest: List[UInt8] = [UInt8(0x68), UInt8(0x69)]
    part.set_digest(digest^)
    var parts = List[S3Part]()
    parts.append(part^)
    parts.append(S3Part())
    input.set_parts(parts^)
    var req = build_put_thing_request(input)
    assert_equal(req.method, "PUT")
    assert_equal(req.uri, "/things/a%20b?thing")
    assert_equal(req.header(String("x-tiny-token")), "t")
    assert_equal(req.header(String("Content-Type")), "application/xml")
    # The input's root element in its namespace; members in declared order;
    # a wrapped list with renamed items; a flattened list of structures, an
    # empty one written as an empty element.
    assert_equal(
        req.body_text(),
        '<PutThingRequest xmlns="https://tiny.example.com/doc/">'
        + "<Size>5</Size>"
        + "<Tags><Tag>x</Tag><Tag>y &amp; z</Tag></Tags>"
        + "<Part><Number>1</Number><Digest>aGk=</Digest></Part>"
        + "<Part/>"
        + "</PutThingRequest>",
    )


def test_put_thing_request_with_no_body_member_set() raises:
    var req = build_put_thing_request(S3PutThingRequest(String("n")))
    assert_equal(req.uri, "/things/n?thing")
    # No body member set: no document and no Content-Type.
    assert_equal(len(req.body), 0)
    assert_false(req.has_header(String("Content-Type")))


def test_an_empty_list_is_its_empty_wrapper() raises:
    var input = S3PutThingRequest(String("n"))
    input.set_tags(List[String]())
    var req = build_put_thing_request(input)
    assert_equal(
        req.body_text(),
        '<PutThingRequest xmlns="https://tiny.example.com/doc/"><Tags/>'
        + "</PutThingRequest>",
    )


def test_structure_payload() raises:
    var config = S3Config()
    config.set_enabled(True)
    config.set_ratio(Float64(0.5))
    var req = build_set_config_request(S3SetConfigRequest(config^))
    assert_equal(req.uri, "/config")
    assert_equal(req.header(String("Content-Type")), "application/xml")
    assert_equal(
        req.body_text(),
        '<Config xmlns="https://tiny.example.com/doc/">'
        + "<Enabled>true</Enabled><Ratio>0.5</Ratio></Config>",
    )


def test_put_thing_response() raises:
    var resp = AwsResponse.of_text(
        200,
        String(
            '<PutThingResponse xmlns="https://tiny.example.com/doc/">\n'
            + "  <Size> 7 </Size>\n"
            + "  <Tags><Tag>a</Tag><Other>ignored</Other><Tag>b</Tag></Tags>\n"
            + "  <Part><Number>2</Number></Part>\n"
            + "  <Unknown/>\n"
            + "  <Part><Number>3</Number><Digest>aGk=</Digest></Part>\n"
            + "</PutThingResponse>"
        ),
    )
    resp.add_header(String("ETag"), String('"abc"'))
    resp.add_header(String("Expires"), String("Thu, 01 Oct 2026 00:00:00 GMT"))
    var out = parse_put_thing_response(resp)
    assert_equal(out.e_tag.value(), '"abc"')
    assert_equal(out.expires.value(), Float64(1790812800.0))
    assert_equal(out.size.value(), Int64(7))
    var tags = out.tags.value().copy()
    assert_equal(len(tags), 2)
    assert_equal(tags[0], "a")
    assert_equal(tags[1], "b")
    var parts = out.parts.value().copy()
    assert_equal(len(parts), 2)
    assert_equal(parts[0].number.value(), Int32(2))
    assert_false(Bool(parts[0].digest))
    assert_equal(parts[1].number.value(), Int32(3))
    assert_equal(len(parts[1].digest.value()), 2)


def test_an_empty_response_sets_nothing() raises:
    var out = parse_put_thing_response(AwsResponse.of_text(200, String("")))
    assert_false(Bool(out.size))
    assert_false(Bool(out.tags))
    assert_false(Bool(out.parts))
    assert_false(Bool(out.expires))


def test_s3_an_expires_that_is_not_a_date_is_left_unset() raises:
    var resp = AwsResponse.of_text(
        200, String("<PutThingResponse><Size>1</Size></PutThingResponse>")
    )
    resp.add_header(String("Expires"), String("not a date"))
    var out = parse_put_thing_response(resp)
    assert_false(Bool(out.expires))
    assert_equal(out.size.value(), Int64(1))


def test_s3_a_200_error_body_is_raised() raises:
    var body = String(
        "<Error><Code>InternalError</Code><Message>try again</Message></Error>"
    )
    # In the client's text for an HTTP 500 with that code and message.
    with assert_raises(
        contains="PutThing failed: HTTP 500 InternalError try again"
    ):
        _ = parse_put_thing_response(AwsResponse.of_text(200, body))
    # A body cut short in transit is not XML, and is raised too.
    with assert_raises(contains="PutThing failed: HTTP 500 "):
        _ = parse_put_thing_response(
            AwsResponse.of_text(200, String("<PutThingResponse><Si"))
        )


def test_s3_a_blob_payload_is_never_an_error_body() raises:
    var body = String("<Error><Code>InternalError</Code></Error>")
    # Streaming (read by its head parser) and not.
    var out = parse_get_blob_response(AwsResponse.of_text(200, body))
    assert_equal(len(out.body.value()), body.byte_length())
    var got = parse_get_bytes_response(AwsResponse.of_text(200, body))
    var bytes = got.body.value().copy()
    assert_equal(len(bytes), body.byte_length())
    for i in range(len(bytes)):
        assert_equal(bytes[i], body.as_bytes()[i])
    _ = S3GetBlobRequest()


def test_s3_a_string_payload_is_never_an_error_body() raises:
    var body = String("<Error><Code>InternalError</Code></Error>")
    var out = parse_get_policy_response(AwsResponse.of_text(200, body))
    assert_equal(out.policy.value(), body)


def test_s3_an_operation_with_no_output_never_reads_an_error_body() raises:
    var body = String("<Error><Code>InternalError</Code></Error>")
    _ = parse_set_config_response(AwsResponse.of_text(200, body))


def test_a_body_that_is_not_utf8_is_refused() raises:
    var bad: List[UInt8] = [UInt8(0x3C), UInt8(0x61), UInt8(0x3E), UInt8(0xFF)]
    with assert_raises(contains="UTF-8"):
        _ = parse_put_thing_response(AwsResponse(201, bad^))


def main() raises:
    test_put_thing_request()
    test_put_thing_request_with_no_body_member_set()
    test_an_empty_list_is_its_empty_wrapper()
    test_structure_payload()
    test_put_thing_response()
    test_an_empty_response_sets_nothing()
    test_s3_an_expires_that_is_not_a_date_is_left_unset()
    test_s3_a_200_error_body_is_raised()
    test_s3_a_blob_payload_is_never_an_error_body()
    test_s3_a_string_payload_is_never_an_error_body()
    test_s3_an_operation_with_no_output_never_reads_an_error_body()
    test_a_body_that_is_not_utf8_is_refused()
