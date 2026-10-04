# A service account's IAM policy through the generated `IAMClient`:
# GetIamPolicy and SetIamPolicy, sent through komira_http_core's
# ScriptedConnector with a shared write capture (no socket).
#
# The forms are written here from the IAM v1 REST reference for
# `projects.serviceAccounts.getIamPolicy` and `setIamPolicy`. getIamPolicy
# is a POST with NO body in iam.proto's binding, so its
# `GetPolicyOptions` rides the query as `options.requestedPolicyVersion`;
# setIamPolicy's body is the `SetIamPolicyRequest` less the `resource` its
# path carries (`policy`, and `updateMask` when given).
#
# A policy change is a read-modify-write: the caller reads the policy,
# changes its bindings and sends it back with the etag it read. The etag is
# what makes the write conditional: the server refuses it (409 ABORTED)
# when the policy changed since the read, and the caller reads again. The
# client neither strips nor invents an etag: the bytes it decodes from the
# read (base64 in JSON) are the bytes it encodes into the write, which
# test_read_modify_write_sends_back_the_etag_it_read holds byte for byte;
# the refusal is test_iam_errors'.
#
# Every client is pointed at `localhost`, so no test needs DNS.
from std.memory import ArcPointer
from std.testing import assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_core import StaticTokenSource
from komira_gcp_iam.iam import IAMClient
from komira_gcp_iam.iam_policy import GetIamPolicyRequest, SetIamPolicyRequest
from komira_gcp_iam.options import GetPolicyOptions
from komira_gcp_iam.policy import AuditConfig, Binding, Policy
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream


comptime _RT = BlockingRuntime[NoopSink]
comptime _SA = "projects/demo-project/serviceAccounts/runner@demo-project.iam.gserviceaccount.com"
comptime _SA_PATH = "/v1/projects/demo-project/serviceAccounts/runner%40demo-project.iam.gserviceaccount.com"

# The policy a read answers with: version 3, one plain binding, one
# conditional binding, and the etag "BwXhqDuVJ8g=".
comptime _READ = (
    '{"version":3,"etag":"BwXhqDuVJ8g=","bindings":['
    + '{"role":"roles/iam.serviceAccountUser",'
    + '"members":["serviceAccount:deployer@demo-project.iam.gserviceaccount.com"]},'
    + '{"role":"roles/iam.serviceAccountTokenCreator",'
    + '"members":["group:oncall@example.com"],'
    + '"condition":{"title":"business hours","expression":'
    + '"request.time.getHours(\\"UTC\\") < 18"}}]}'
)


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _ok(body: String) -> List[UInt8]:
    return _bytes(
        String("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n")
        + "Content-Length: "
        + String(body.byte_length())
        + "\r\nConnection: close\r\n\r\n"
        + body
    )


def _client(
    capture: ArcPointer[List[UInt8]], answer: String
) raises -> IAMClient[ScriptedConnector, StaticTokenSource]:
    var c = IAMClient[ScriptedConnector, StaticTokenSource](
        HttpClient[ScriptedConnector].with_defaults(
            ScriptedConnector.with_stream_tls(
                ScriptedStream.from_read_script_with_capture(_ok(answer), capture)
            )
        ),
        StaticTokenSource(String("test-access-token")),
    )
    c.set_rest_host(String("localhost"))
    return c^


def _wire(capture: ArcPointer[List[UInt8]]) -> String:
    return String(unsafe_from_utf8=Span(capture[]))


def _request_line(wire: String) -> String:
    return String(wire[byte = 0 : wire.find("\r\n")])


def _body(wire: String) -> String:
    return String(wire[byte = wire.find("\r\n\r\n") + 4 :])


def _has_header(wire: String, name: String) -> Bool:
    var head = String(wire[byte = 0 : wire.find("\r\n\r\n")]).lower()
    return (String("\r\n") + name.lower() + ":") in head


def _rt() raises -> _RT:
    return _RT.new(NoopSink(_placeholder=UInt8(0)))


def _read(capture: ArcPointer[List[UInt8]], version: Int32) raises -> Policy:
    var c = _client(capture, String(_READ))
    var rt = _rt()
    ref reactor = rt.reactor()
    var options = Optional[GetPolicyOptions](None)
    if version != 0:
        options = GetPolicyOptions(version)
    return c.get_iam_policy[_RT](GetIamPolicyRequest(String(_SA), options^), reactor)


def test_get_asks_for_version_3_in_the_query() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    _ = _read(capture, Int32(3))
    var wire = _wire(capture)
    assert_equal(
        _request_line(wire),
        String("POST ")
        + _SA_PATH
        + ":getIamPolicy?options.requestedPolicyVersion=3 HTTP/1.1",
    )
    assert_equal(_body(wire), "")
    assert_false(_has_header(wire, "content-type"))


def test_get_without_options_sends_no_query() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    _ = _read(capture, Int32(0))
    assert_equal(
        _request_line(_wire(capture)),
        String("POST ") + _SA_PATH + ":getIamPolicy HTTP/1.1",
    )


def test_get_reads_the_policy() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var p = _read(capture, Int32(3))
    assert_equal(p.version, 3)
    assert_equal(len(p.bindings), 2)
    assert_equal(p.bindings[0].role, "roles/iam.serviceAccountUser")
    assert_equal(len(p.bindings[0].members), 1)
    assert_false(Bool(p.bindings[0].condition))
    assert_true(Bool(p.bindings[1].condition))
    ref cond = p.bindings[1].condition.value()
    assert_equal(cond.title, "business hours")
    assert_equal(cond.expression, 'request.time.getHours("UTC") < 18')
    var etag: List[UInt8] = [0x07, 0x05, 0xE1, 0xA8, 0x3B, 0x95, 0x27, 0xC8]
    assert_true(p.etag == etag)


def test_read_modify_write_sends_back_the_etag_it_read() raises:
    # Read, add a member to the first binding, write: the write carries the
    # etag of the read, unchanged, and every binding, the condition
    # included, at the version read.
    var read_capture = ArcPointer[List[UInt8]](List[UInt8]())
    var p = _read(read_capture, Int32(3))
    p.bindings[0].members.append(
        String("serviceAccount:ci@demo-project.iam.gserviceaccount.com")
    )

    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(capture, String(_READ))
    var rt = _rt()
    ref reactor = rt.reactor()
    _ = c.set_iam_policy[_RT](
        SetIamPolicyRequest(String(_SA), p^, None), reactor
    )
    var wire = _wire(capture)
    assert_equal(
        _request_line(wire), String("POST ") + _SA_PATH + ":setIamPolicy HTTP/1.1"
    )
    assert_true(_has_header(wire, "content-type"))
    var body = _body(wire)
    assert_equal(
        body,
        String('{"policy":{"version":3,"bindings":[')
        + '{"role":"roles/iam.serviceAccountUser","members":['
        + '"serviceAccount:deployer@demo-project.iam.gserviceaccount.com",'
        + '"serviceAccount:ci@demo-project.iam.gserviceaccount.com"]},'
        + '{"role":"roles/iam.serviceAccountTokenCreator",'
        + '"members":["group:oncall@example.com"],'
        + '"condition":{"expression":"request.time.getHours(\\"UTC\\") < 18",'
        + '"title":"business hours","description":"","location":""}}],'
        + '"auditConfigs":[],"etag":"BwXhqDuVJ8g="}}',
    )
    # The etag text sent is the etag text read.
    assert_equal(body.count('"etag":"BwXhqDuVJ8g="'), 1)


def test_set_with_no_etag_sends_none() raises:
    # A policy built from nothing has no etag, and none is invented: the
    # write is then unconditional, which the caller chose by not reading.
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(capture, String(_READ))
    var rt = _rt()
    ref reactor = rt.reactor()
    var members = List[String]()
    members.append(String("user:owner@example.com"))
    var bindings = List[Binding]()
    bindings.append(Binding(String("roles/iam.serviceAccountUser"), members^, None))
    var p = Policy(Int32(1), bindings^, List[AuditConfig](), List[UInt8]())
    _ = c.set_iam_policy[_RT](SetIamPolicyRequest(String(_SA), p^, None), reactor)
    var body = _body(_wire(capture))
    assert_true(body.endswith('"auditConfigs":[],"etag":""}}'), body)


def main() raises:
    test_get_asks_for_version_3_in_the_query()
    test_get_without_options_sends_no_query()
    test_get_reads_the_policy()
    test_read_modify_write_sends_back_the_etag_it_read()
    test_set_with_no_etag_sends_none()
    print("OK")
