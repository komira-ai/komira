# The caller's test of a generated pure-mode ec2Query client
# (tiny_ec2.json): the requests it builds (method, target, Content-Type and
# the form body) and the responses it reads (the members of the root
# element), each compared exactly, and the error document a client reads
# through komira_aws_core. The parameter names follow botocore's
# EC2Serializer (botocore/serialize.py): a member's queryName, else its
# locationName with the first letter capitalized, else its member name as
# declared; a list is `<name>.<i>` from 1, never wrapped, whatever its
# member's locationName, and an empty one writes nothing.
from komira_aws_tiny_ec2.komira_aws_tiny_ec2 import (
    TinyEc2DescribeThingsRequest,
    TinyEc2Filter,
    TinyEc2PingRequest,
    build_describe_things_request,
    build_ping_request,
    parse_describe_things_response,
    parse_ping_response,
)
from komira_aws_core import AwsResponse, aws_query_error
from std.testing import assert_equal, assert_false, assert_true


def test_describe_things_request() raises:
    var input = TinyEc2DescribeThingsRequest()
    var ids: List[String] = ["i-1", "i-2"]
    input.set_thing_ids(ids^)
    input.set_dry_run(True)
    var env = TinyEc2Filter()
    env.set_name(String("tag:Env"))
    var values: List[String] = ["a", "b c"]
    env.set_values(values^)
    var only_name = TinyEc2Filter()
    only_name.set_name(String("x"))
    var filters = List[TinyEc2Filter]()
    filters.append(env^)
    filters.append(only_name^)
    input.set_filters(filters^)
    input.set_owner(String("self"))
    input.set_max_results(Int32(5))
    var req = build_describe_things_request(input)
    assert_equal(req.method, "POST")
    assert_equal(req.uri, "/")
    assert_equal(
        req.header(String("Content-Type")),
        "application/x-www-form-urlencoded; charset=utf-8",
    )
    # `ThingId` (locationName ThingId), `DryRun` (dryRun capitalized), the
    # list of structures `Filter.<i>` whose members are capitalized too
    # (`name` becomes `Name`) and hold a list (`Value.<i>`, its member's
    # locationName `item` unused), `OwnerAlias` (the queryName wins over
    # the locationName `owner`), and `maxResults` (no locationName: the
    # member name as declared).
    assert_equal(
        req.body_text(),
        "Action=DescribeThings&Version=2026-10-02&ThingId.1=i-1&ThingId.2=i-2"
        + "&DryRun=true&Filter.1.Name=tag%3AEnv&Filter.1.Value.1=a"
        + "&Filter.1.Value.2=b%20c&Filter.2.Name=x&OwnerAlias=self"
        + "&maxResults=5",
    )


def test_an_empty_list_writes_nothing() raises:
    var input = TinyEc2DescribeThingsRequest()
    input.set_thing_ids(List[String]())
    input.set_filters(List[TinyEc2Filter]())
    var req = build_describe_things_request(input)
    assert_equal(req.body_text(), "Action=DescribeThings&Version=2026-10-02")


def test_an_operation_with_no_input() raises:
    var req = build_ping_request(TinyEc2PingRequest())
    assert_equal(req.method, "POST")
    assert_equal(req.body_text(), "Action=Ping&Version=2026-10-02")


def test_describe_things_response() raises:
    # No result wrapper: the members are the root's children; each list is
    # wrapped, its items named `item`.
    var resp = AwsResponse.of_text(
        200,
        '<DescribeThingsResponse xmlns="http://ec2.amazonaws.com/doc/2026-10-02/">\n'
        + "  <requestId>r-1</requestId>\n"
        + "  <thingSet>\n"
        + "    <item><thingId>i-1</thingId><size>42</size>\n"
        + "      <tagSet><item><key>Env</key><value>prod</value></item>"
        + "<item><key>Team</key><value>db</value></item></tagSet>\n"
        + "    </item>\n"
        + "    <item><thingId>i-2</thingId><tagSet/></item>\n"
        + "  </thingSet>\n"
        + "  <unknown>ignored</unknown>\n"
        + "</DescribeThingsResponse>\n",
    )
    var out = parse_describe_things_response(resp)
    assert_equal(out.request_id.value(), "r-1")
    assert_false(Bool(out.next_token))
    var things = out.things.value().copy()
    assert_equal(len(things), 2)
    assert_equal(things[0].thing_id.value(), "i-1")
    assert_equal(things[0].size.value(), Int64(42))
    var tags = things[0].tags.value().copy()
    assert_equal(len(tags), 2)
    assert_equal(tags[0].key.value(), "Env")
    assert_equal(tags[0].value.value(), "prod")
    assert_equal(tags[1].key.value(), "Team")
    assert_equal(tags[1].value.value(), "db")
    assert_equal(things[1].thing_id.value(), "i-2")
    assert_false(Bool(things[1].size))
    assert_equal(len(things[1].tags.value()), 0)


def test_an_empty_body_sets_nothing() raises:
    var out = parse_describe_things_response(AwsResponse.of_text(200, String("")))
    assert_false(Bool(out.request_id))
    assert_false(Bool(out.things))


def test_an_operation_with_no_output_reads_nothing() raises:
    _ = parse_ping_response(AwsResponse.of_text(200, String("")))
    _ = parse_ping_response(
        AwsResponse.of_text(200, "<PingResponse><requestId>r</requestId></PingResponse>")
    )


def test_the_error_document() raises:
    # The ec2Query form: <Errors> holds the <Error>, and the request id is
    # the root's <RequestID>.
    var resp = AwsResponse.of_text(
        400,
        "<Response><Errors><Error><Code>InvalidThingID.NotFound</Code>"
        + "<Message>no such thing</Message></Error></Errors>"
        + "<RequestID>r-2</RequestID></Response>",
    )
    var e = aws_query_error(resp)
    assert_equal(e.status, 400)
    assert_equal(e.code, "InvalidThingID.NotFound")
    assert_equal(e.message, "no such thing")
    assert_equal(e.request_id, "r-2")
    assert_true(String(e.to_error(String("TinyEc2.DescribeThings"))).find("r-2") > 0)


def main() raises:
    test_describe_things_request()
    test_an_empty_list_writes_nothing()
    test_an_operation_with_no_input()
    test_describe_things_response()
    test_an_empty_body_sets_nothing()
    test_an_operation_with_no_output_reads_nothing()
    test_the_error_document()
    print("OK")
