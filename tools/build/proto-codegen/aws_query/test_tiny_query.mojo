# The caller's test of a generated pure-mode awsQuery client
# (tiny_query.json): the requests it builds (method, target, Content-Type
# and the form body) and the responses it reads (the members of the
# <SendThingResult> element, and a 200 with no body as an empty result),
# each compared exactly, and the error document
# a client reads through komira_aws_core.
from komira_aws_tiny_query.komira_aws_tiny_query import (
    TinyQueryDetail,
    TinyQueryPart,
    TinyQueryPingRequest,
    TinyQuerySendThingRequest,
    build_ping_request,
    build_send_thing_request,
    parse_ping_response,
    parse_send_thing_response,
)
from komira_aws_core import AwsResponse, aws_query_error
from std.testing import assert_equal, assert_false, assert_raises, assert_true


def test_send_thing_request() raises:
    var input = TinyQuerySendThingRequest(String("a b"))
    input.set_count(Int32(3))
    input.set_enabled(True)
    input.set_ratio(Float64(0.5))
    var payload: List[UInt8] = [UInt8(0x68), UInt8(0x69)]
    input.set_payload(payload^)
    input.set_at(Float64(1789473600.0))
    var tags: List[String] = ["x", "y & z"]
    input.set_tags(tags^)
    var ids: List[String] = ["i1", "i2"]
    input.set_ids(ids^)
    var attributes = Dict[String, String]()
    attributes["Color"] = "red"
    input.set_attributes(attributes^)
    var labels = Dict[String, String]()
    labels["k"] = "v"
    labels["k2"] = "v2"
    input.set_labels(labels^)
    var part = TinyQueryPart()
    part.set_number(Int32(1))
    var digest: List[UInt8] = [UInt8(0x68), UInt8(0x69)]
    part.set_digest(digest^)
    var parts = List[TinyQueryPart]()
    parts.append(part^)
    parts.append(TinyQueryPart())
    var detail = TinyQueryDetail()
    detail.set_note(String("n"))
    detail.set_parts(parts^)
    input.set_detail(detail^)
    var req = build_send_thing_request(input)
    assert_equal(req.method, "POST")
    assert_equal(req.uri, "/")
    assert_equal(
        req.header(String("Content-Type")),
        "application/x-www-form-urlencoded; charset=utf-8",
    )
    # Action and Version first, then the members in declared order: a
    # wrapped list (`member`), a flattened list whose member is renamed
    # (`Ids` becomes `Id`), a flattened map named by its member and its
    # key and value names, a wrapped map (`entry`), and a nested structure
    # holding a wrapped list of structures; a structure with no member set
    # writes nothing.
    assert_equal(
        req.body_text(),
        "Action=SendThing&Version=2026-10-02&Name=a%20b&Count=3&Enabled=true"
        + "&Ratio=0.5&Payload=aGk%3D&At=2026-09-15T12%3A00%3A00Z"
        + "&Tags.member.1=x&Tags.member.2=y%20%26%20z&Id.1=i1&Id.2=i2"
        + "&Attribute.1.Name=Color&Attribute.1.Value=red"
        + "&Labels.entry.1.key=k&Labels.entry.1.value=v"
        + "&Labels.entry.2.key=k2&Labels.entry.2.value=v2"
        + "&Detail.Note=n&Detail.Parts.member.1.Number=1"
        + "&Detail.Parts.member.1.Digest=aGk%3D",
    )


def test_only_the_required_member() raises:
    var req = build_send_thing_request(TinyQuerySendThingRequest(String("n")))
    assert_equal(req.body_text(), "Action=SendThing&Version=2026-10-02&Name=n")


def test_an_empty_list_is_one_empty_parameter_and_an_empty_map_none() raises:
    var input = TinyQuerySendThingRequest(String("n"))
    input.set_tags(List[String]())
    input.set_labels(Dict[String, String]())
    var req = build_send_thing_request(input)
    assert_equal(
        req.body_text(), "Action=SendThing&Version=2026-10-02&Name=n&Tags="
    )


def test_an_operation_with_no_input() raises:
    var req = build_ping_request(TinyQueryPingRequest())
    assert_equal(req.method, "POST")
    assert_equal(req.body_text(), "Action=Ping&Version=2026-10-02")
    assert_equal(
        req.header(String("Content-Type")),
        "application/x-www-form-urlencoded; charset=utf-8",
    )


def test_send_thing_response() raises:
    var resp = AwsResponse.of_text(
        200,
        '<SendThingResponse xmlns="https://tinyquery.amazonaws.com/doc/2026-10-02/">\n'
        + "  <SendThingResult>\n"
        + "    <MessageId>m-1</MessageId>\n"
        + "    <Sizes><Size>1</Size><Size>2</Size></Sizes>\n"
        + "    <Attribute><Name>Color</Name><Value>red</Value></Attribute>\n"
        + "    <Attribute><Name>Shape</Name><Value>round</Value></Attribute>\n"
        + "    <Labels><entry><key>k</key><value>v</value></entry></Labels>\n"
        + "    <Detail><Note>n</Note><Parts><member><Number>7</Number>"
        + "<Digest>aGk=</Digest></member><member/></Parts></Detail>\n"
        + "    <Created>2026-09-15T12:00:00Z</Created>\n"
        + "    <Unknown>ignored</Unknown>\n"
        + "  </SendThingResult>\n"
        + "  <ResponseMetadata><RequestId>r-1</RequestId></ResponseMetadata>\n"
        + "</SendThingResponse>\n",
    )
    var out = parse_send_thing_response(resp)
    assert_equal(out.message_id, "m-1")
    var sizes = out.sizes.value().copy()
    assert_equal(len(sizes), 2)
    assert_equal(sizes[0], Int64(1))
    assert_equal(sizes[1], Int64(2))
    var attributes = out.attributes.value().copy()
    assert_equal(len(attributes), 2)
    assert_equal(attributes[String("Color")], "red")
    assert_equal(attributes[String("Shape")], "round")
    var labels = out.labels.value().copy()
    assert_equal(len(labels), 1)
    assert_equal(labels[String("k")], "v")
    var detail = out.detail.value().copy()
    assert_equal(detail.note.value(), "n")
    var parts = detail.parts.value().copy()
    assert_equal(len(parts), 2)
    assert_equal(parts[0].number.value(), Int32(7))
    assert_equal(len(parts[0].digest.value()), 2)
    assert_false(Bool(parts[1].number))
    assert_equal(out.created.value(), Float64(1789473600.0))


def test_an_empty_result_sets_nothing() raises:
    var out = parse_send_thing_response(
        AwsResponse.of_text(
            200,
            "<SendThingResponse><SendThingResult/></SendThingResponse>",
        )
    )
    assert_equal(out.message_id, "")
    assert_false(Bool(out.sizes))
    assert_false(Bool(out.attributes))
    assert_false(Bool(out.labels))
    assert_false(Bool(out.detail))


def test_a_200_with_an_empty_body_is_an_empty_result() raises:
    # The awsQuery protocol tests QueryEmptyInputAndEmptyOutput and
    # QueryNoInputAndOutput answer an operation that has an output shape
    # with a 200 and no body, and expect an empty result.
    var out = parse_send_thing_response(AwsResponse.of_text(200, String("")))
    assert_equal(out.message_id, "")
    assert_false(Bool(out.sizes))
    assert_false(Bool(out.attributes))
    assert_false(Bool(out.labels))
    assert_false(Bool(out.detail))


def test_a_response_without_its_result_element_is_refused() raises:
    with assert_raises(contains="holds no <SendThingResult> element"):
        _ = parse_send_thing_response(
            AwsResponse.of_text(200, "<SendThingResponse><Other/></SendThingResponse>")
        )


def test_an_operation_with_no_output_reads_nothing() raises:
    _ = parse_ping_response(AwsResponse.of_text(200, String("")))
    _ = parse_ping_response(
        AwsResponse.of_text(200, "<PingResponse><ResponseMetadata/></PingResponse>")
    )


def test_the_error_document() raises:
    var resp = AwsResponse.of_text(
        400,
        "<ErrorResponse><Error><Type>Sender</Type>"
        + "<Code>Tiny.ThingNotFound</Code><Message>no such thing</Message>"
        + "</Error><RequestId>r-2</RequestId></ErrorResponse>",
    )
    var e = aws_query_error(resp)
    assert_equal(e.status, 400)
    assert_equal(e.code, "Tiny.ThingNotFound")
    assert_equal(e.message, "no such thing")
    assert_equal(e.request_id, "r-2")
    assert_true(String(e.to_error(String("TinyQuery.SendThing"))).find("r-2") > 0)


def main() raises:
    test_send_thing_request()
    test_only_the_required_member()
    test_an_empty_list_is_one_empty_parameter_and_an_empty_map_none()
    test_an_operation_with_no_input()
    test_send_thing_response()
    test_an_empty_result_sets_nothing()
    test_a_200_with_an_empty_body_is_an_empty_result()
    test_a_response_without_its_result_element_is_refused()
    test_an_operation_with_no_output_reads_nothing()
    test_the_error_document()
