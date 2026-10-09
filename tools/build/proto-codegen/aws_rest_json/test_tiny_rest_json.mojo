# The caller's test of a generated pure-mode restJson1 client
# (tiny_rest_json.json): the requests it builds (method, target, headers and
# body) and the responses it reads (headers, prefix headers present and
# absent, status, a JSON body, a streaming blob payload), each compared
# exactly.
from komira_aws_tiny_rest.komira_aws_tiny_rest import (
    TinyRestConfig,
    TinyRestGetThingRequest,
    TinyRestPutThingRequest,
    TinyRestSetConfigRequest,
    build_get_thing_request,
    build_put_thing_request,
    build_set_config_request,
    parse_get_thing_head,
    parse_get_thing_response,
    parse_put_thing_response,
)
from komira_aws_core import AwsResponse
from std.testing import assert_equal, assert_false, assert_raises, assert_true


def test_put_thing_request() raises:
    var input = TinyRestPutThingRequest(String("a b"), String("dir/../x.txt"))
    input.set_version(Int32(3))
    var labels: List[String] = ["x", "y"]
    input.set_labels(labels^)
    var extra = Dict[String, String]()
    extra["version"] = "9"
    extra["z"] = "1"
    input.set_extra(extra^)
    input.set_since(Float64(1789473600.0))
    var tags: List[String] = ["a,b", "c"]
    input.set_tags(tags^)
    var meta = Dict[String, String]()
    meta["Color"] = "red"
    input.set_meta(meta^)
    input.set_note(String("hi"))
    input.set_size(Int32(2))
    var req = build_put_thing_request(input)
    assert_equal(req.method, "PUT")
    # The literal query first; a plain label encodes ' ', a greedy one keeps
    # '/' and is not normalized; the named `version` member takes precedence
    # over the map's entry of that key.
    assert_equal(
        req.uri,
        "/things/a%20b/dir/../x.txt?tagging&version=3&label=x&label=y&z=1",
    )
    assert_equal(req.header(String("X-Since")), "Tue, 15 Sep 2026 12:00:00 GMT")
    assert_equal(req.header(String("X-Tags")), '"a,b", c')
    assert_equal(req.header(String("x-meta-Color")), "red")
    assert_equal(req.header(String("Content-Type")), "application/json")
    # Only the members with no location, under their wire names.
    assert_equal(req.body_text(), '{"note":"hi","Size":2}')


def test_put_thing_request_with_no_body_member_set() raises:
    var req = build_put_thing_request(
        TinyRestPutThingRequest(String("t"), String("k"))
    )
    assert_equal(req.uri, "/things/t/k?tagging")
    assert_equal(req.body_text(), "{}")
    assert_false(req.has_header(String("X-Tags")))


def test_get_thing_request() raises:
    var input = TinyRestGetThingRequest(String("t1"))
    input.set_range_(String("bytes=0-9"))
    var req = build_get_thing_request(input)
    assert_equal(req.method, "GET")
    assert_equal(req.uri, "/things/t1")
    assert_equal(req.header(String("Range")), "bytes=0-9")
    # No body member: no body and no Content-Type.
    assert_equal(len(req.body), 0)
    assert_false(req.has_header(String("Content-Type")))


def test_an_empty_label_is_refused() raises:
    with assert_raises(contains="the AWS URI label Id is empty"):
        _ = build_get_thing_request(TinyRestGetThingRequest(String("")))


def test_structure_payload() raises:
    var req = build_set_config_request(TinyRestSetConfigRequest())
    assert_equal(req.body_text(), "{}")
    assert_equal(req.header(String("Content-Type")), "application/json")
    var input = TinyRestSetConfigRequest()
    var config = TinyRestConfig()
    config.set_mode(String("fast"))
    input.set_config(config^)
    req = build_set_config_request(input)
    assert_equal(req.uri, "/config")
    assert_equal(req.body_text(), '{"mode":"fast"}')


def _get_thing_response() -> AwsResponse:
    var resp = AwsResponse.of_text(206, String("0123456789"))
    resp.add_header(String("Content-Length"), String("10"))
    resp.add_header(String("x-meta-Color"), String("red"))
    resp.add_header(String("X-Meta-Size"), String(" big "))
    resp.add_header(String("Content-Range"), String("bytes 0-9/20"))
    return resp^


def test_get_thing_head_reads_no_body() raises:
    var out = parse_get_thing_head(_get_thing_response())
    assert_equal(out.length.value(), Int64(10))
    var meta = out.meta.value().copy()
    assert_equal(len(meta), 2)
    assert_equal(meta[String("Color")], "red")
    assert_equal(meta[String("Size")], "big")
    assert_false(Bool(out.body))


def test_no_prefix_header_reads_as_an_empty_map() raises:
    # botocore sets a prefix-header map whether or not a header carries the
    # prefix: an empty map, not an unset member.
    var resp = AwsResponse.of_text(200, String(""))
    resp.add_header(String("Content-Length"), String("0"))
    var out = parse_get_thing_head(resp)
    assert_true(Bool(out.meta))
    assert_equal(len(out.meta.value()), 0)


def test_get_thing_response() raises:
    var out = parse_get_thing_response(_get_thing_response())
    assert_equal(out.length.value(), Int64(10))
    var body = out.body.value().copy()
    assert_equal(len(body), 10)
    assert_equal(body[0], UInt8(0x30))
    assert_equal(body[9], UInt8(0x39))
    # An empty body leaves the payload unset.
    var empty = parse_get_thing_response(AwsResponse.of_text(200, String("")))
    assert_false(Bool(empty.body))
    assert_false(Bool(empty.length))


def test_put_thing_response() raises:
    var resp = AwsResponse.of_text(201, String('{"Created": 1789473600}'))
    resp.add_header(String("ETag"), String('"abc"'))
    var out = parse_put_thing_response(resp)
    assert_equal(out.status.value(), Int32(201))
    assert_equal(out.e_tag.value(), '"abc"')
    assert_equal(out.created.value(), Float64(1789473600.0))
    var bare = parse_put_thing_response(AwsResponse.of_text(200, String("")))
    assert_equal(bare.status.value(), Int32(200))
    assert_false(Bool(bare.created))
    assert_false(Bool(bare.e_tag))


def test_a_bad_header_value_is_refused() raises:
    var resp = AwsResponse.of_text(200, String(""))
    resp.add_header(String("Content-Length"), String("ten"))
    with assert_raises(contains="digit"):
        _ = parse_get_thing_head(resp)


def main() raises:
    test_put_thing_request()
    test_put_thing_request_with_no_body_member_set()
    test_get_thing_request()
    test_an_empty_label_is_refused()
    test_structure_payload()
    test_get_thing_head_reads_no_body()
    test_no_prefix_header_reads_as_an_empty_map()
    test_get_thing_response()
    test_put_thing_response()
    test_a_bad_header_value_is_refused()
