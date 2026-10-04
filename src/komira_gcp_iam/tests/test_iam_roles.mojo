# The role methods of the generated `IAMClient`: GetRole, CreateRole,
# UpdateRole and DeleteRole, each sent through komira_http_core's
# ScriptedConnector with a shared write capture (no socket).
#
# Each of these methods has more than one HTTP binding in iam.proto, one per
# form of role name. GetRole has three: a predefined role `roles/<id>`, then
# `organizations/<org>/roles/<id>` and `projects/<project>/roles/<id>`.
# CreateRole, UpdateRole and DeleteRole have two, organization then project,
# and none for a predefined role. The generated method sends to the first
# binding whose path variables the request's values match, in the order
# iam.proto declares them, and refuses a name matching none before the
# token source or the connector is used. The forms are written here from
# the IAM v1 REST reference: `roles.get` / `projects.roles.get` (GET on the
# name), `projects.roles.create` (POST .../roles, a `CreateRoleRequest`
# body: `roleId` and the `role`), `projects.roles.patch` (PATCH on the name,
# the `Role` itself as the body, `updateMask` in the query) and
# `projects.roles.delete` (DELETE on the name, `etag` in the query, the
# deleted role in the answer).
#
# Default-valued body keys are the codec's (see test_iam_service_accounts).
# Every client is pointed at `localhost`, so no test needs DNS.
from std.memory import ArcPointer
from std.testing import assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_core import StaticTokenSource
from komira_gcp_iam.iam import (
    CreateRoleRequest,
    DeleteRoleRequest,
    GetRoleRequest,
    IAMClient,
    Role,
    Role_RoleLaunchStage,
    UpdateRoleRequest,
)
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_wkt import FieldMask


comptime _RT = BlockingRuntime[NoopSink]
comptime _ROLE = "projects/demo-project/roles/deployer"


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


def _role_json(deleted: Bool) -> String:
    return (
        String('{"name":"')
        + _ROLE
        + '","title":"Deployer","description":"deploys the services",'
        + '"includedPermissions":["run.services.get","run.services.update"],'
        + '"stage":"GA","etag":"BwXhqDuVJ8g="'
        + (String(',"deleted":true}') if deleted else String("}"))
    )


def _deployer() -> Role:
    var perms = List[String]()
    perms.append(String("run.services.get"))
    perms.append(String("run.services.update"))
    return Role(
        String(""),
        String("Deployer"),
        String("deploys the services"),
        perms^,
        Role_RoleLaunchStage(Role_RoleLaunchStage.GA),
        List[UInt8](),
        False,
    )


def _get_line(name: String) raises -> String:
    """The request line `get_role` sends for `name`."""
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(capture, _role_json(False))
    var rt = _rt()
    ref reactor = rt.reactor()
    _ = c.get_role[_RT](GetRoleRequest(name.copy()), reactor)
    return _request_line(_wire(capture))


def test_get_goes_to_the_binding_the_name_matches() raises:
    assert_equal(_get_line(String("roles/run.invoker")), "GET /v1/roles/run.invoker HTTP/1.1")
    assert_equal(
        _get_line(String("organizations/123456/roles/auditor")),
        "GET /v1/organizations/123456/roles/auditor HTTP/1.1",
    )
    assert_equal(
        _get_line(String(_ROLE)),
        "GET /v1/projects/demo-project/roles/deployer HTTP/1.1",
    )


def test_get_reads_the_role() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(capture, _role_json(False))
    var rt = _rt()
    ref reactor = rt.reactor()
    var r = c.get_role[_RT](GetRoleRequest(String(_ROLE)), reactor)
    assert_equal(r.name, _ROLE)
    assert_equal(r.title, "Deployer")
    assert_equal(len(r.included_permissions), 2)
    assert_equal(r.included_permissions[1], "run.services.update")
    assert_true(r.stage == Role_RoleLaunchStage(Role_RoleLaunchStage.GA))
    assert_equal(len(r.etag), 8)
    assert_false(r.deleted)


def test_a_name_matching_no_binding_is_refused_before_the_dial() raises:
    # A folder has no roles: none of the three paths takes the name. The
    # error names the paths, never the value.
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(capture, _role_json(False))
    var rt = _rt()
    ref reactor = rt.reactor()
    var raised = String("")
    try:
        _ = c.get_role[_RT](GetRoleRequest(String("folders/777/roles/secret-x")), reactor)
    except e:
        raised = String(e)
    assert_equal(
        raised,
        "REST method GetRole: the request matches none of its paths:"
        " /v1/{name=roles/*}, /v1/{name=organizations/*/roles/*},"
        " /v1/{name=projects/*/roles/*}",
    )
    assert_false("secret-x" in raised)
    assert_equal(c._client._connector.connect_call_count(), 0)


def test_a_dot_segment_is_refused_rather_than_sent() raises:
    # `projects/demo-project/roles/..` would be normalized into another
    # resource on the way; no binding takes it.
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(capture, _role_json(False))
    var rt = _rt()
    ref reactor = rt.reactor()
    var raised = False
    try:
        _ = c.delete_role[_RT](
            DeleteRoleRequest(String("projects/demo-project/roles/.."), List[UInt8]()),
            reactor,
        )
    except:
        raised = True
    assert_true(raised)
    assert_equal(c._client._connector.connect_call_count(), 0)


def test_create_sends_the_role_id_and_the_role() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(capture, _role_json(False))
    var rt = _rt()
    ref reactor = rt.reactor()
    var created = c.create_role[_RT](
        CreateRoleRequest(String("projects/demo-project"), String("deployer"), _deployer()),
        reactor,
    )
    var wire = _wire(capture)
    assert_equal(_request_line(wire), "POST /v1/projects/demo-project/roles HTTP/1.1")
    assert_true(_has_header(wire, "content-type"))
    assert_equal(
        _body(wire),
        '{"parent":"projects/demo-project","roleId":"deployer","role":{"name":"",'
        + '"title":"Deployer","description":"deploys the services",'
        + '"includedPermissions":["run.services.get","run.services.update"],'
        + '"stage":"GA","etag":"","deleted":false}}',
    )
    assert_equal(created.name, _ROLE)


def test_create_in_an_organization_takes_the_organization_path() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(capture, _role_json(False))
    var rt = _rt()
    ref reactor = rt.reactor()
    _ = c.create_role[_RT](
        CreateRoleRequest(String("organizations/123456"), String("auditor"), _deployer()),
        reactor,
    )
    assert_equal(
        _request_line(_wire(capture)), "POST /v1/organizations/123456/roles HTTP/1.1"
    )


def test_update_sends_the_role_as_the_body_with_no_mask() raises:
    # No mask: the role sent replaces the stored one whole.
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(capture, _role_json(False))
    var rt = _rt()
    ref reactor = rt.reactor()
    _ = c.update_role[_RT](
        UpdateRoleRequest(String(_ROLE), _deployer(), None), reactor
    )
    var wire = _wire(capture)
    assert_equal(
        _request_line(wire), "PATCH /v1/projects/demo-project/roles/deployer HTTP/1.1"
    )
    assert_equal(
        _body(wire),
        '{"name":"","title":"Deployer","description":"deploys the services",'
        + '"includedPermissions":["run.services.get","run.services.update"],'
        + '"stage":"GA","etag":"","deleted":false}',
    )


def test_update_and_delete_take_each_of_their_two_bindings() raises:
    # The organization binding is the first of UpdateRole's and DeleteRole's,
    # the project one (the tests above) the second.
    var org_role = String("organizations/123456/roles/auditor")
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(capture, _role_json(False))
    var rt = _rt()
    ref reactor = rt.reactor()
    _ = c.update_role[_RT](UpdateRoleRequest(org_role.copy(), _deployer(), None), reactor)
    assert_equal(
        _request_line(_wire(capture)),
        "PATCH /v1/organizations/123456/roles/auditor HTTP/1.1",
    )

    var del_capture = ArcPointer[List[UInt8]](List[UInt8]())
    var d = _client(del_capture, _role_json(True))
    _ = d.delete_role[_RT](DeleteRoleRequest(org_role.copy(), List[UInt8]()), reactor)
    assert_equal(
        _request_line(_wire(del_capture)),
        "DELETE /v1/organizations/123456/roles/auditor HTTP/1.1",
    )


def test_a_predefined_role_cannot_be_updated_or_deleted() raises:
    # UpdateRole and DeleteRole have no `roles/<id>` binding, so a predefined
    # role's name matches neither of their two paths and is refused before
    # the dial.
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(capture, _role_json(False))
    var rt = _rt()
    ref reactor = rt.reactor()
    var update_raised = String("")
    try:
        _ = c.update_role[_RT](
            UpdateRoleRequest(String("roles/run.invoker"), _deployer(), None), reactor
        )
    except e:
        update_raised = String(e)
    assert_equal(
        update_raised,
        "REST method UpdateRole: the request matches none of its paths:"
        " /v1/{name=organizations/*/roles/*}, /v1/{name=projects/*/roles/*}",
    )
    var delete_raised = String("")
    try:
        _ = c.delete_role[_RT](
            DeleteRoleRequest(String("roles/run.invoker"), List[UInt8]()), reactor
        )
    except e:
        delete_raised = String(e)
    assert_equal(
        delete_raised,
        "REST method DeleteRole: the request matches none of its paths:"
        " /v1/{name=organizations/*/roles/*}, /v1/{name=projects/*/roles/*}",
    )
    assert_equal(c._client._connector.connect_call_count(), 0)


def test_update_with_a_mask_sends_it_in_the_query() raises:
    # The mask's JSON form: camelCase paths joined by `,` (sent as %2C).
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(capture, _role_json(False))
    var rt = _rt()
    ref reactor = rt.reactor()
    var paths = List[String]()
    paths.append(String("included_permissions"))
    paths.append(String("title"))
    _ = c.update_role[_RT](
        UpdateRoleRequest(String(_ROLE), _deployer(), FieldMask(paths^)), reactor
    )
    assert_equal(
        _request_line(_wire(capture)),
        "PATCH /v1/projects/demo-project/roles/deployer"
        "?updateMask=includedPermissions%2Ctitle HTTP/1.1",
    )


def test_delete_without_an_etag_sends_no_query() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(capture, _role_json(True))
    var rt = _rt()
    ref reactor = rt.reactor()
    var gone = c.delete_role[_RT](
        DeleteRoleRequest(String(_ROLE), List[UInt8]()), reactor
    )
    var wire = _wire(capture)
    assert_equal(
        _request_line(wire), "DELETE /v1/projects/demo-project/roles/deployer HTTP/1.1"
    )
    assert_false(_has_header(wire, "content-type"))
    assert_equal(_body(wire), "")
    # A deleted custom role is answered with `deleted` set; it can be
    # undeleted for a while, which this client does not do.
    assert_true(gone.deleted)


def test_delete_with_an_etag_sends_it_base64_in_the_query() raises:
    # The role's etag as read (base64 "BwXhqDuVJ8g=" in JSON) goes back
    # as the same base64 text, percent-encoded as a query value.
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(capture, _role_json(True))
    var rt = _rt()
    ref reactor = rt.reactor()
    var etag: List[UInt8] = [0x07, 0x05, 0xE1, 0xA8, 0x3B, 0x95, 0x27, 0xC8]
    _ = c.delete_role[_RT](DeleteRoleRequest(String(_ROLE), etag^), reactor)
    assert_equal(
        _request_line(_wire(capture)),
        "DELETE /v1/projects/demo-project/roles/deployer?etag=BwXhqDuVJ8g%3D HTTP/1.1",
    )


def main() raises:
    test_get_goes_to_the_binding_the_name_matches()
    test_get_reads_the_role()
    test_a_name_matching_no_binding_is_refused_before_the_dial()
    test_a_dot_segment_is_refused_rather_than_sent()
    test_create_sends_the_role_id_and_the_role()
    test_create_in_an_organization_takes_the_organization_path()
    test_update_sends_the_role_as_the_body_with_no_mask()
    test_update_and_delete_take_each_of_their_two_bindings()
    test_a_predefined_role_cannot_be_updated_or_deleted()
    test_update_with_a_mask_sends_it_in_the_query()
    test_delete_without_an_etag_sends_no_query()
    test_delete_with_an_etag_sends_it_base64_in_the_query()
    print("OK")
