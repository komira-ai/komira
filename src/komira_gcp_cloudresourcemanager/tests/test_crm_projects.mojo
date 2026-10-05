# The generated `ProjectsClient` (Resource Manager v3): GetProject,
# GetIamPolicy, SetIamPolicy and TestIamPermissions, each sent through
# komira_http_core's ScriptedConnector with a shared write capture (no
# socket): the request line, the headers that carry meaning and the JSON
# body, and the answer read back.
#
# The forms are written here from the Resource Manager v3 REST reference:
# `projects.get` (GET /v3/projects/<id or number>, answering a `Project`
# whose `name` is `projects/<number>`), and `projects.getIamPolicy`,
# `setIamPolicy` and `testIamPermissions` (POST
# /v3/projects/<project>:<verb>, the request message as the body, less
# the `resource` the path carries). Unlike
# IAM's service-account binding, getIamPolicy here takes a body, so its
# `options` ride in it.
#
# A policy change is a read-modify-write: the etag the read answers with is
# sent back with the write, unchanged, which makes the write conditional
# (a policy changed since the read is refused, 409 ABORTED: test_crm_errors).
#
# Default-valued body keys are komira_proto_codec's JsonEncoder writing
# defaults, not the API (the server reads each as unset). Every client is
# pointed at `localhost`, so no test needs DNS; the default host is
# test_crm_default_host's.
from std.memory import ArcPointer
from std.testing import assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_cloudresourcemanager.iam_policy import (
    GetIamPolicyRequest,
    SetIamPolicyRequest,
    TestIamPermissionsRequest,
)
from komira_gcp_cloudresourcemanager.options import GetPolicyOptions
from komira_gcp_cloudresourcemanager.policy import Policy
from komira_gcp_cloudresourcemanager.projects import (
    GetProjectRequest,
    Project_State,
    ProjectsClient,
)
from komira_gcp_core import StaticTokenSource
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream


comptime _RT = BlockingRuntime[NoopSink]

comptime _PROJECT = (
    '{"name":"projects/123456789012","parent":"organizations/123456",'
    + '"projectId":"demo-project","state":"ACTIVE","displayName":"Demo",'
    + '"createTime":"2026-09-12T10:00:00.000Z","updateTime":"2026-09-12T10:00:01Z",'
    + '"etag":"W/\\"5cbc0bfe\\"","labels":{"env":"test","team":"data"}}'
)

comptime _POLICY = (
    '{"version":1,"etag":"BwXhqDuVJ8g=","bindings":['
    + '{"role":"roles/run.invoker","members":["serviceAccount:caller@demo-project.iam.gserviceaccount.com"]},'
    + '{"role":"roles/viewer","members":["group:readers@example.com"]}]}'
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
) raises -> ProjectsClient[ScriptedConnector, StaticTokenSource]:
    var c = ProjectsClient[ScriptedConnector, StaticTokenSource](
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


def test_get_project_reads_its_number() raises:
    # A project named by its id answers with its number in `name`: the
    # number is what a workload identity audience names.
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(capture, String(_PROJECT))
    var rt = _rt()
    ref reactor = rt.reactor()
    var p = c.get_project[_RT](GetProjectRequest(String("projects/demo-project")), reactor)
    var wire = _wire(capture)
    assert_equal(_request_line(wire), "GET /v3/projects/demo-project HTTP/1.1")
    assert_equal(_body(wire), "")
    assert_false(_has_header(wire, "content-type"))
    assert_true("\r\nauthorization: Bearer test-access-token\r\n" in wire, wire)

    assert_equal(p.name, "projects/123456789012")
    assert_equal(p.project_id, "demo-project")
    assert_equal(p.parent, "organizations/123456")
    assert_true(p.state == Project_State(Project_State.ACTIVE))
    assert_equal(p.display_name, "Demo")
    assert_equal(p.etag, 'W/"5cbc0bfe"')
    assert_equal(p.labels["team"], "data")
    assert_equal(len(p.labels), 2)
    # 2026-09-12T10:00:00Z in Unix seconds.
    assert_equal(p.create_time.value().seconds, 1789207200)
    assert_false(Bool(p.delete_time))


def test_get_project_by_number() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(capture, String(_PROJECT))
    var rt = _rt()
    ref reactor = rt.reactor()
    _ = c.get_project[_RT](GetProjectRequest(String("projects/123456789012")), reactor)
    assert_equal(_request_line(_wire(capture)), "GET /v3/projects/123456789012 HTTP/1.1")


def test_a_bare_project_id_is_refused_before_the_dial() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(capture, String(_PROJECT))
    var rt = _rt()
    ref reactor = rt.reactor()
    var raised = String("")
    try:
        _ = c.get_project[_RT](GetProjectRequest(String("demo-project")), reactor)
    except e:
        raised = String(e)
    assert_equal(raised, "path variable `name` does not match `projects/*`")
    assert_equal(c._client._connector.connect_call_count(), 0)


def test_get_iam_policy_sends_its_options_in_the_body() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(capture, String(_POLICY))
    var rt = _rt()
    ref reactor = rt.reactor()
    var p = c.get_iam_policy[_RT](
        GetIamPolicyRequest(String("projects/demo-project"), GetPolicyOptions(Int32(3))),
        reactor,
    )
    var wire = _wire(capture)
    assert_equal(
        _request_line(wire), "POST /v3/projects/demo-project:getIamPolicy HTTP/1.1"
    )
    assert_true(_has_header(wire, "content-type"))
    # The body is every field the path does not bind: `resource` is in the
    # URL, so it is not in the body.
    assert_equal(_body(wire), '{"options":{"requestedPolicyVersion":3}}')
    assert_equal(p.version, 1)
    assert_equal(len(p.bindings), 2)
    assert_equal(p.bindings[1].members[0], "group:readers@example.com")


def test_get_iam_policy_without_options() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(capture, String(_POLICY))
    var rt = _rt()
    ref reactor = rt.reactor()
    _ = c.get_iam_policy[_RT](
        GetIamPolicyRequest(String("projects/demo-project"), None), reactor
    )
    assert_equal(_body(_wire(capture)), "{}")


def test_read_modify_write_sends_back_the_etag_it_read() raises:
    # Read the policy, drop a member (here: the whole run.invoker binding
    # goes), write it back: the write carries the etag the read gave.
    var read_capture = ArcPointer[List[UInt8]](List[UInt8]())
    var reader = _client(read_capture, String(_POLICY))
    var rt = _rt()
    ref reactor = rt.reactor()
    var p = reader.get_iam_policy[_RT](
        GetIamPolicyRequest(String("projects/demo-project"), GetPolicyOptions(Int32(3))),
        reactor,
    )
    _ = p.bindings.pop(0)

    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(capture, String(_POLICY))
    var written = c.set_iam_policy[_RT](
        SetIamPolicyRequest(String("projects/demo-project"), p^, None), reactor
    )
    var wire = _wire(capture)
    assert_equal(
        _request_line(wire), "POST /v3/projects/demo-project:setIamPolicy HTTP/1.1"
    )
    assert_equal(
        _body(wire),
        '{"policy":{"version":1,"bindings":['
        + '{"role":"roles/viewer","members":["group:readers@example.com"]}],'
        + '"etag":"BwXhqDuVJ8g="}}',
    )
    # The answer is the policy as stored (here the script's).
    assert_equal(len(written.bindings), 2)


def test_test_iam_permissions() raises:
    # The permissions the caller holds out of those asked about; a caller
    # holding none is answered with an empty object.
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(capture, String('{"permissions":["run.jobs.run"]}'))
    var rt = _rt()
    ref reactor = rt.reactor()
    var asked = List[String]()
    asked.append(String("run.jobs.run"))
    asked.append(String("iam.serviceAccounts.actAs"))
    var held = c.test_iam_permissions[_RT](
        TestIamPermissionsRequest(String("projects/demo-project"), asked.copy()),
        reactor,
    )
    var wire = _wire(capture)
    assert_equal(
        _request_line(wire),
        "POST /v3/projects/demo-project:testIamPermissions HTTP/1.1",
    )
    assert_equal(
        _body(wire),
        '{"permissions":["run.jobs.run","iam.serviceAccounts.actAs"]}',
    )
    assert_equal(len(held.permissions), 1)
    assert_equal(held.permissions[0], "run.jobs.run")

    var none_capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c2 = _client(none_capture, String("{}"))
    var none = c2.test_iam_permissions[_RT](
        TestIamPermissionsRequest(String("projects/demo-project"), asked^), reactor
    )
    assert_equal(len(none.permissions), 0)


def main() raises:
    test_get_project_reads_its_number()
    test_get_project_by_number()
    test_a_bare_project_id_is_refused_before_the_dial()
    test_get_iam_policy_sends_its_options_in_the_body()
    test_get_iam_policy_without_options()
    test_read_modify_write_sends_back_the_etag_it_read()
    test_test_iam_permissions()
    print("OK")
