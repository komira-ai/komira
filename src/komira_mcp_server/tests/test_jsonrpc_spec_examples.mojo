# =============================================================================
# test_jsonrpc_spec_examples.mojo: the examples of the JSON-RPC 2.0
# specification (section 7), fed to the framing layer and to an
# initialized McpServer.
# =============================================================================
#
# Every request below is the specification's example text (only escaped
# for a Mojo string literal). Where the server answers, the reply is
# compared, as JSON (member order ignored), with the specification's
# response. Where MCP narrows JSON-RPC (no batches), the test says so and
# asserts the MCP behaviour.

from std.testing import assert_equal, assert_true, assert_false

from komira_json import JsonValue, parse_json_value
from komira_mcp_server import (
    JSONRPC_REQUEST,
    JSONRPC_NOTIFICATION,
    JSONRPC_RESPONSE,
    JSONRPC_INVALID,
    JSONRPC_PARSE_ERROR,
    JSONRPC_INVALID_REQUEST,
    McpServer,
    NoResources,
    NoTools,
    ServerInfo,
    parse_jsonrpc_message,
)


def _same(a: JsonValue, b: JsonValue) raises -> Bool:
    """JSON equality: object members compared by key, in any order."""
    if a.kind_tag() != b.kind_tag():
        return False
    if a.is_object():
        if a.num_members() != b.num_members():
            return False
        for i in range(a.num_members()):
            var k = a.key_at(i)
            if not b.has(k) or not _same(a.value_at(i), b.get(k)):
                return False
        return True
    if a.is_array():
        if a.array_len() != b.array_len():
            return False
        for i in range(a.array_len()):
            if not _same(a.element_at(i), b.element_at(i)):
                return False
        return True
    if a.is_bool():
        return a.as_bool() == b.as_bool()
    return a.text == b.text


def assert_reply(got: Optional[String], expected: String, what: String) raises:
    assert_true(Bool(got), what + ": expected a reply, got none")
    var g = parse_json_value(got.value())
    var e = parse_json_value(expected)
    if not _same(g, e):
        raise Error(
            what + ": reply differs\n  got:      " + got.value()
            + "\n  expected: " + e.serialize()
        )


def _server() raises -> McpServer[NoTools, NoResources]:
    var s = McpServer(ServerInfo("jsonrpc-examples", "0"), NoTools(), NoResources())
    var init = s.handle(
        '{"jsonrpc":"2.0","id":0,"method":"initialize","params":'
        '{"protocolVersion":"x","capabilities":{},'
        '"clientInfo":{"name":"c","version":"0"}}}'
    )
    assert_true(Bool(init), "initialize answered")
    return s^


def test_positional_and_named_params_frame_as_requests() raises:
    # 7: rpc call with positional parameters / named parameters.
    var m = parse_jsonrpc_message(
        '{"jsonrpc": "2.0", "method": "subtract", "params": [42, 23], "id": 1}'
    )
    assert_equal(m.kind, JSONRPC_REQUEST)
    assert_equal(m.method, "subtract")
    assert_equal(m.id.serialize(), "1")
    assert_equal(m.params.serialize(), "[42,23]")
    var n = parse_jsonrpc_message(
        '{"jsonrpc": "2.0", "method": "subtract", "params": {"subtrahend": 23,'
        ' "minuend": 42}, "id": 3}'
    )
    assert_equal(n.kind, JSONRPC_REQUEST)
    assert_equal(n.id.serialize(), "3")
    assert_true(n.params.is_object())
    # A string id is kept a string, so it is echoed with its type.
    var s = parse_jsonrpc_message(
        '{"jsonrpc": "2.0", "method": "foobar", "id": "1"}'
    )
    assert_equal(s.id.serialize(), '"1"')
    print("  test_positional_and_named_params_frame_as_requests: PASS")


def test_notifications_get_no_reply() raises:
    # 7: a Notification / non-existent method notification.
    var s = _server()
    var a = '{"jsonrpc": "2.0", "method": "update", "params": [1,2,3,4,5]}'
    assert_equal(parse_jsonrpc_message(a).kind, JSONRPC_NOTIFICATION)
    assert_false(Bool(s.handle(a)), "update notification answered")
    var b = '{"jsonrpc": "2.0", "method": "foobar"}'
    assert_equal(parse_jsonrpc_message(b).kind, JSONRPC_NOTIFICATION)
    assert_false(Bool(s.handle(b)), "foobar notification answered")
    print("  test_notifications_get_no_reply: PASS")


def test_non_existent_method() raises:
    # 7: rpc call of non-existent method.
    var s = _server()
    assert_reply(
        s.handle('{"jsonrpc": "2.0", "method": "foobar", "id": "1"}'),
        '{"jsonrpc": "2.0", "error": {"code": -32601, "message": "Method not'
        ' found"}, "id": "1"}',
        "non-existent method",
    )
    print("  test_non_existent_method: PASS")


def test_invalid_json() raises:
    # 7: rpc call with invalid JSON.
    var s = _server()
    var req = '{"jsonrpc": "2.0", "method": "foobar, "params": "bar", "baz]'
    var m = parse_jsonrpc_message(req)
    assert_equal(m.kind, JSONRPC_INVALID)
    assert_equal(m.error_code, JSONRPC_PARSE_ERROR)
    assert_reply(
        s.handle(req),
        '{"jsonrpc": "2.0", "error": {"code": -32700, "message": "Parse'
        ' error"}, "id": null}',
        "invalid JSON",
    )
    print("  test_invalid_json: PASS")


def test_invalid_request_object() raises:
    # 7: rpc call with invalid Request object.
    var s = _server()
    var req = '{"jsonrpc": "2.0", "method": 1, "params": "bar"}'
    var m = parse_jsonrpc_message(req)
    assert_equal(m.kind, JSONRPC_INVALID)
    assert_equal(m.error_code, JSONRPC_INVALID_REQUEST)
    assert_reply(
        s.handle(req),
        '{"jsonrpc": "2.0", "error": {"code": -32600, "message": "Invalid'
        ' Request"}, "id": null}',
        "invalid Request object",
    )
    print("  test_invalid_request_object: PASS")


def test_batch_invalid_json() raises:
    # 7: rpc call Batch, invalid JSON.
    var s = _server()
    assert_reply(
        s.handle(
            '[\n  {"jsonrpc": "2.0", "method": "sum", "params": [1,2,4], "id":'
            ' "1"},\n  {"jsonrpc": "2.0", "method"\n]'
        ),
        '{"jsonrpc": "2.0", "error": {"code": -32700, "message": "Parse'
        ' error"}, "id": null}',
        "batch, invalid JSON",
    )
    print("  test_batch_invalid_json: PASS")


def test_empty_array() raises:
    # 7: rpc call with an empty Array.
    var s = _server()
    assert_reply(
        s.handle("[]"),
        '{"jsonrpc": "2.0", "error": {"code": -32600, "message": "Invalid'
        ' Request"}, "id": null}',
        "empty array",
    )
    print("  test_empty_array: PASS")


def test_batches_are_one_invalid_request() raises:
    # 7: an invalid Batch ([1], [1,2,3]) and a mixed Batch. JSON-RPC answers
    # those with an array of replies; MCP has no batches, so each is one
    # message that is not an object: one Invalid Request with a null id.
    var s = _server()
    var expected = (
        '{"jsonrpc": "2.0", "error": {"code": -32600, "message": "Invalid'
        ' Request"}, "id": null}'
    )
    assert_reply(s.handle("[1]"), expected, "batch [1]")
    assert_reply(s.handle("[1,2,3]"), expected, "batch [1,2,3]")
    assert_reply(
        s.handle(
            '[\n        {"jsonrpc": "2.0", "method": "sum", "params": [1,2,4],'
            ' "id": "1"},\n        {"jsonrpc": "2.0", "method":'
            ' "notify_hello", "params": [7]}\n    ]'
        ),
        expected,
        "mixed batch",
    )
    print("  test_batches_are_one_invalid_request: PASS")


def test_response_from_peer_is_not_answered() raises:
    # 7: the specification's response objects, sent to the server, are
    # replies it does not answer.
    var s = _server()
    var r = '{"jsonrpc": "2.0", "result": 19, "id": 1}'
    assert_equal(parse_jsonrpc_message(r).kind, JSONRPC_RESPONSE)
    assert_false(Bool(s.handle(r)), "a result was answered")
    var e = (
        '{"jsonrpc": "2.0", "error": {"code": -32601, "message": "Method not'
        ' found"}, "id": "1"}'
    )
    assert_equal(parse_jsonrpc_message(e).kind, JSONRPC_RESPONSE)
    assert_false(Bool(s.handle(e)), "an error was answered")
    print("  test_response_from_peer_is_not_answered: PASS")


def main() raises:
    print("test_jsonrpc_spec_examples")
    test_positional_and_named_params_frame_as_requests()
    test_notifications_get_no_reply()
    test_non_existent_method()
    test_invalid_json()
    test_invalid_request_object()
    test_batch_invalid_json()
    test_empty_array()
    test_batches_are_one_invalid_request()
    test_response_from_peer_is_not_answered()
    print("test_jsonrpc_spec_examples: ALL PASS")
