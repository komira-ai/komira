# The service-account methods of the generated `IAMClient`, each sent
# through komira_http_core's ScriptedConnector with a shared write capture
# (no socket): the request line, the headers that carry meaning and the
# JSON body a call writes, and the answer it reads back.
#
# The forms are written here from the IAM v1 REST reference:
# `projects.serviceAccounts.list` (GET .../serviceAccounts, `pageSize` and
# `pageToken` in the query), `get` (GET on the account's name), `create`
# (POST .../serviceAccounts, a `CreateServiceAccountRequest` body: the
# `accountId` and the `serviceAccount` to create, its `name` being the
# path's) and `delete` (DELETE on
# the name, answering an empty JSON object). An account is named
# `projects/<project>/serviceAccounts/<email or unique id>`; the `@` of an
# email is percent-encoded in the path, which the API reads as the same
# name.
#
# A body holds only the fields the caller set: a plain field left at its
# default (`name`, `disabled`, ...) is omitted, as the proto3 JSON mapping
# omits it, and the server reads it as unset. Every client here is pointed
# at `localhost` so no test
# needs DNS; that a fresh client starts at iam.googleapis.com is
# test_iam_default_host's.
from std.memory import ArcPointer
from std.testing import assert_equal, assert_false

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_core import StaticTokenSource
from komira_gcp_iam.iam import (
    CreateServiceAccountRequest,
    DeleteServiceAccountRequest,
    GetServiceAccountRequest,
    IAMClient,
    ListServiceAccountsRequest,
    ServiceAccount,
)
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream


comptime _RT = BlockingRuntime[NoopSink]
comptime _EMAIL = "runner@demo-project.iam.gserviceaccount.com"
comptime _NAME = "projects/demo-project/serviceAccounts/" + _EMAIL
comptime _PATH = "/v1/projects/demo-project/serviceAccounts/runner%40demo-project.iam.gserviceaccount.com"


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


def _header(wire: String, name: String) -> String:
    """The value of the one header `name` (case-insensitive), or "" when
    the request has none; a header given twice fails the test."""
    var head = String(wire[byte = 0 : wire.find("\r\n\r\n")])
    var lines = head.split("\r\n")
    var found = String("")
    var n = 0
    for i in range(1, len(lines)):
        var line = String(lines[i])
        var colon = line.find(":")
        if String(line[byte=0:colon]).lower() == name.lower():
            found = String(String(line[byte = colon + 1 :]).strip())
            n += 1
    if n > 1:
        found = String("<header ") + name + String(" given twice>")
    return found^


def _rt() raises -> _RT:
    return _RT.new(NoopSink(_placeholder=UInt8(0)))


def _account() -> String:
    return (
        String('{"name":"')
        + _NAME
        + '","projectId":"demo-project","uniqueId":"112233445566778899000",'
        + '"email":"'
        + _EMAIL
        + '","displayName":"Runner","etag":"MDEwMjE5MjA=",'
        + '"description":"runs the nightly jobs",'
        + '"oauth2ClientId":"112233445566778899000"}'
    )


def test_list_first_page() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(
        capture, String('{"accounts":[') + _account() + '],"nextPageToken":"Cg5x+/="}'
    )
    var rt = _rt()
    ref reactor = rt.reactor()
    var page = c.list_service_accounts[_RT](
        ListServiceAccountsRequest(
            String("projects/demo-project"), Int32(100), String("")
        ),
        reactor,
    )
    var wire = _wire(capture)
    assert_equal(
        _request_line(wire),
        "GET /v1/projects/demo-project/serviceAccounts?pageSize=100 HTTP/1.1",
    )
    assert_equal(_header(wire, "host"), "localhost")
    assert_equal(_header(wire, "authorization"), "Bearer test-access-token")
    assert_equal(_header(wire, "content-type"), "")
    assert_equal(_body(wire), "")

    assert_equal(len(page.accounts), 1)
    ref a = page.accounts[0]
    assert_equal(a.name, _NAME)
    assert_equal(a.project_id, "demo-project")
    assert_equal(a.unique_id, "112233445566778899000")
    assert_equal(a.email, _EMAIL)
    assert_equal(a.display_name, "Runner")
    assert_equal(a.description, "runs the nightly jobs")
    assert_equal(a.oauth2_client_id, "112233445566778899000")
    assert_false(a.disabled)
    # The etag is bytes, base64 in JSON: "MDEwMjE5MjA=" is "01021920".
    assert_equal(String(unsafe_from_utf8=Span(a.etag)), "01021920")
    assert_equal(page.next_page_token, "Cg5x+/=")


def test_list_next_page_sends_the_token_back() raises:
    # The token goes back verbatim, percent-encoded as a query value.
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(capture, String("{}"))
    var rt = _rt()
    ref reactor = rt.reactor()
    var page = c.list_service_accounts[_RT](
        ListServiceAccountsRequest(
            String("projects/demo-project"), Int32(100), String("Cg5x+/=")
        ),
        reactor,
    )
    assert_equal(
        _request_line(_wire(capture)),
        "GET /v1/projects/demo-project/serviceAccounts"
        "?pageSize=100&pageToken=Cg5x%2B%2F%3D HTTP/1.1",
    )
    # The last page: no accounts key and no token.
    assert_equal(len(page.accounts), 0)
    assert_equal(page.next_page_token, "")


def test_get() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(capture, _account())
    var rt = _rt()
    ref reactor = rt.reactor()
    var a = c.get_service_account[_RT](
        GetServiceAccountRequest(String(_NAME)), reactor
    )
    var wire = _wire(capture)
    assert_equal(_request_line(wire), String("GET ") + _PATH + " HTTP/1.1")
    assert_equal(_body(wire), "")
    assert_equal(a.email, _EMAIL)


def test_get_by_unique_id_under_any_project() raises:
    # `projects/-` with the account's unique id is the form the reference
    # gives for an account whose project the caller does not know.
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(capture, _account())
    var rt = _rt()
    ref reactor = rt.reactor()
    _ = c.get_service_account[_RT](
        GetServiceAccountRequest(
            String("projects/-/serviceAccounts/112233445566778899000")
        ),
        reactor,
    )
    assert_equal(
        _request_line(_wire(capture)),
        "GET /v1/projects/-/serviceAccounts/112233445566778899000 HTTP/1.1",
    )


def test_create() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(capture, _account())
    var rt = _rt()
    ref reactor = rt.reactor()
    var account = ServiceAccount(
        String(""),
        String(""),
        String(""),
        String(""),
        String("Runner"),
        List[UInt8](),
        String("runs the nightly jobs"),
        String(""),
        False,
    )
    var created = c.create_service_account[_RT](
        CreateServiceAccountRequest(
            String("projects/demo-project"), String("runner"), account^
        ),
        reactor,
    )
    var wire = _wire(capture)
    assert_equal(
        _request_line(wire), "POST /v1/projects/demo-project/serviceAccounts HTTP/1.1"
    )
    assert_equal(_header(wire, "content-type"), "application/json")
    assert_equal(
        _body(wire),
        '{"accountId":"runner",'
        + '"serviceAccount":{"displayName":"Runner",'
        + '"description":"runs the nightly jobs"}}',
    )
    assert_equal(_header(wire, "content-length"), String(_body(wire).byte_length()))
    assert_equal(created.name, _NAME)


def test_delete() raises:
    # DELETE carries no body; the answer is an empty JSON object.
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(capture, String("{}"))
    var rt = _rt()
    ref reactor = rt.reactor()
    _ = c.delete_service_account[_RT](
        DeleteServiceAccountRequest(String(_NAME)), reactor
    )
    var wire = _wire(capture)
    assert_equal(_request_line(wire), String("DELETE ") + _PATH + " HTTP/1.1")
    assert_equal(_header(wire, "content-type"), "")
    assert_equal(_body(wire), "")


def test_delete_by_email_under_any_project() raises:
    # `projects/-` with the account's email: the form a deploy uses, knowing
    # the email and not the project. The `@` is percent-encoded like any
    # byte outside the unreserved set; the `-` is unreserved and stays.
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(capture, String("{}"))
    var rt = _rt()
    ref reactor = rt.reactor()
    _ = c.delete_service_account[_RT](
        DeleteServiceAccountRequest(String("projects/-/serviceAccounts/") + _EMAIL),
        reactor,
    )
    assert_equal(
        _request_line(_wire(capture)),
        "DELETE /v1/projects/-/serviceAccounts/"
        "runner%40demo-project.iam.gserviceaccount.com HTTP/1.1",
    )


def test_a_name_outside_the_pattern_is_refused_before_the_dial() raises:
    # `projects/*/serviceAccounts/*`: a bare email is not an account name.
    # Refused naming the field and the pattern, never the value, and before
    # the token source or the connector is used.
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(capture, _account())
    var rt = _rt()
    ref reactor = rt.reactor()
    var raised = String("")
    try:
        _ = c.get_service_account[_RT](
            GetServiceAccountRequest(String(_EMAIL)), reactor
        )
    except e:
        raised = String(e)
    assert_equal(
        raised,
        "path variable `name` does not match `projects/*/serviceAccounts/*`",
    )
    assert_equal(c._client._connector.connect_call_count(), 0)
    assert_false("runner" in raised)


def main() raises:
    test_list_first_page()
    test_list_next_page_sends_the_token_back()
    test_get()
    test_get_by_unique_id_under_any_project()
    test_create()
    test_delete()
    test_delete_by_email_under_any_project()
    test_a_name_outside_the_pattern_is_refused_before_the_dial()
    print("OK")
