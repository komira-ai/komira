# =============================================================================
# test_mcp_lifecycle.mojo: McpServer's lifecycle gate, version negotiation,
# request-id rules, params checks and provider error mapping.
# =============================================================================
#
# Every error reply is compared whole (code, message, data, id), so a
# changed message or code fails here.

from std.testing import assert_equal, assert_true, assert_false

from komira_json import JsonValue, parse_json_value
from komira_mcp_server import (
    MCP_LATEST_PROTOCOL_VERSION,
    MCP_PREVIOUS_PROTOCOL_VERSION,
    McpServer,
    NoResources,
    NoTools,
    Resource,
    ResourceContents,
    ResourceProvider,
    ServerInfo,
    Tool,
    ToolProvider,
    ToolResult,
    mcp_supported_protocol_versions,
)


def _init_request(version: String) -> String:
    return (
        String('{"jsonrpc":"2.0","id":1,"method":"initialize","params":')
        + '{"protocolVersion":"' + version + '","capabilities":{},'
        + '"clientInfo":{"name":"c","version":"0"}}}'
    )


struct CountingTools(ToolProvider):
    """`echo` returns its `text` argument; `fail` raises."""

    var calls: Int

    def __init__(out self):
        self.calls = 0

    def advertises_tools(self) -> Bool:
        return True

    def list_tools(self) raises -> List[Tool]:
        var out = List[Tool]()
        out.append(Tool("echo", parse_json_value('{"type":"object"}')))
        return out^

    def call_tool(
        mut self, name: String, arguments: JsonValue
    ) raises -> Optional[ToolResult]:
        self.calls += 1
        if name == "echo":
            var text = String("")
            if arguments.has("text"):
                text = arguments.get("text").as_string()
            return ToolResult.text(text^)
        if name == "fail":
            raise Error("backend unavailable")
        return None


struct FailingResources(ResourceProvider):
    """`mem://hi` reads as the bytes "hi"; `mem://boom` raises."""

    def __init__(out self):
        pass

    def advertises_resources(self) -> Bool:
        return True

    def list_resources(self) raises -> List[Resource]:
        return List[Resource]()

    def read_resource(
        mut self, uri: String
    ) raises -> Optional[List[ResourceContents]]:
        if uri == "mem://boom":
            raise Error("disk on fire: /secret/path")
        if uri != "mem://hi":
            return None
        var bytes = List[UInt8]()
        bytes.append(0x68)
        bytes.append(0x69)
        var out = List[ResourceContents]()
        out.append(
            ResourceContents.binary(String(uri), String("application/octet-stream"), bytes)
        )
        return out^


def _server() -> McpServer[CountingTools, FailingResources]:
    return McpServer(ServerInfo("t", "1"), CountingTools(), FailingResources())


def _ready() raises -> McpServer[CountingTools, FailingResources]:
    var s = _server()
    assert_true(Bool(s.handle(_init_request(MCP_LATEST_PROTOCOL_VERSION))))
    return s^


def _expect(got: Optional[String], expected: String, what: String) raises:
    assert_true(Bool(got), what + ": expected a reply, got none")
    # Compare as compact JSON: the server writes members in a fixed order.
    assert_equal(got.value(), parse_json_value(expected).serialize(), what)


def test_gate_before_initialize() raises:
    var s = _server()
    _expect(
        s.handle('{"jsonrpc":"2.0","id":7,"method":"tools/list"}'),
        '{"jsonrpc":"2.0","id":7,"error":{"code":-32600,"message":"Server not initialized"}}',
        "tools/list before initialize",
    )
    assert_equal(s.tools().calls, 0)
    _expect(
        s.handle('{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"echo"}}'),
        '{"jsonrpc":"2.0","id":8,"error":{"code":-32600,"message":"Server not initialized"}}',
        "tools/call before initialize",
    )
    assert_equal(s.tools().calls, 0)
    # An initialized notification before initialize is dropped, not recorded.
    assert_false(Bool(s.handle('{"jsonrpc":"2.0","method":"notifications/initialized"}')))
    assert_false(s.client_ready())
    assert_false(s.is_initialized())
    assert_equal(s.protocol_version(), "")
    print("  test_gate_before_initialize: PASS")


def test_second_initialize_refused() raises:
    var s = _ready()
    _expect(
        s.handle(_init_request(MCP_PREVIOUS_PROTOCOL_VERSION)),
        '{"jsonrpc":"2.0","id":1,"error":{"code":-32600,"message":"Server already initialized"}}',
        "second initialize",
    )
    assert_equal(s.protocol_version(), MCP_LATEST_PROTOCOL_VERSION)
    print("  test_second_initialize_refused: PASS")


def test_version_negotiation() raises:
    var supported = mcp_supported_protocol_versions()
    assert_equal(len(supported), 2)
    assert_equal(supported[0], MCP_LATEST_PROTOCOL_VERSION)
    assert_equal(supported[1], MCP_PREVIOUS_PROTOCOL_VERSION)
    # A supported revision comes back unchanged.
    var a = _server()
    var ra = parse_json_value(a.handle(_init_request(MCP_PREVIOUS_PROTOCOL_VERSION)).value())
    assert_equal(
        ra.get("result").get("protocolVersion").as_string(),
        MCP_PREVIOUS_PROTOCOL_VERSION,
    )
    assert_equal(a.protocol_version(), MCP_PREVIOUS_PROTOCOL_VERSION)
    # Any other gets the newest this server speaks (not an error).
    var b = _server()
    var rb = parse_json_value(b.handle(_init_request("1.0.0")).value())
    assert_equal(
        rb.get("result").get("protocolVersion").as_string(),
        MCP_LATEST_PROTOCOL_VERSION,
    )
    print("  test_version_negotiation: PASS")


def test_initialize_params_checked() raises:
    var s = _server()
    _expect(
        s.handle('{"jsonrpc":"2.0","id":1,"method":"initialize"}'),
        '{"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"Invalid params","data":"initialize requires a params object"}}',
        "initialize without params",
    )
    _expect(
        s.handle('{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"capabilities":{},"clientInfo":{"name":"c","version":"0"}}}'),
        '{"jsonrpc":"2.0","id":2,"error":{"code":-32602,"message":"Invalid params","data":"initialize requires params.protocolVersion, a string"}}',
        "initialize without protocolVersion",
    )
    _expect(
        s.handle('{"jsonrpc":"2.0","id":3,"method":"initialize","params":{"protocolVersion":"x","clientInfo":{"name":"c","version":"0"}}}'),
        '{"jsonrpc":"2.0","id":3,"error":{"code":-32602,"message":"Invalid params","data":"initialize requires params.capabilities, an object"}}',
        "initialize without capabilities",
    )
    _expect(
        s.handle('{"jsonrpc":"2.0","id":4,"method":"initialize","params":{"protocolVersion":"x","capabilities":{}}}'),
        '{"jsonrpc":"2.0","id":4,"error":{"code":-32602,"message":"Invalid params","data":"initialize requires params.clientInfo, an object"}}',
        "initialize without clientInfo",
    )
    _expect(
        s.handle('{"jsonrpc":"2.0","id":5,"method":"initialize","params":{"protocolVersion":"x","capabilities":{},"clientInfo":{"name":"c"}}}'),
        '{"jsonrpc":"2.0","id":5,"error":{"code":-32602,"message":"Invalid params","data":"initialize requires params.clientInfo.name and params.clientInfo.version, strings"}}',
        "initialize without clientInfo.version",
    )
    # Each member present with the wrong type is refused like a missing one.
    _expect(
        s.handle('{"jsonrpc":"2.0","id":6,"method":"initialize","params":{"protocolVersion":7,"capabilities":{},"clientInfo":{"name":"c","version":"0"}}}'),
        '{"jsonrpc":"2.0","id":6,"error":{"code":-32602,"message":"Invalid params","data":"initialize requires params.protocolVersion, a string"}}',
        "initialize with a non-string protocolVersion",
    )
    _expect(
        s.handle('{"jsonrpc":"2.0","id":7,"method":"initialize","params":{"protocolVersion":"x","capabilities":1,"clientInfo":{"name":"c","version":"0"}}}'),
        '{"jsonrpc":"2.0","id":7,"error":{"code":-32602,"message":"Invalid params","data":"initialize requires params.capabilities, an object"}}',
        "initialize with a non-object capabilities",
    )
    _expect(
        s.handle('{"jsonrpc":"2.0","id":8,"method":"initialize","params":{"protocolVersion":"x","capabilities":{},"clientInfo":"c"}}'),
        '{"jsonrpc":"2.0","id":8,"error":{"code":-32602,"message":"Invalid params","data":"initialize requires params.clientInfo, an object"}}',
        "initialize with a non-object clientInfo",
    )
    # None of those initialized the session.
    assert_false(s.is_initialized())
    print("  test_initialize_params_checked: PASS")


def test_request_id_rules() raises:
    var s = _ready()
    var invalid = '{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"Invalid Request"}}'
    # MCP: an id MUST be a string or an integer, never null.
    _expect(s.handle('{"jsonrpc":"2.0","id":null,"method":"ping"}'), invalid, "null id")
    _expect(s.handle('{"jsonrpc":"2.0","id":1.5,"method":"ping"}'), invalid, "fractional id")
    _expect(s.handle('{"jsonrpc":"2.0","id":true,"method":"ping"}'), invalid, "bool id")
    _expect(s.handle('{"jsonrpc":"2.0","id":[1],"method":"ping"}'), invalid, "array id")
    # A valid id is echoed even when the rest of the request is invalid.
    _expect(
        s.handle('{"jsonrpc":"1.0","id":9,"method":"ping"}'),
        '{"jsonrpc":"2.0","id":9,"error":{"code":-32600,"message":"Invalid Request"}}',
        "wrong jsonrpc version",
    )
    _expect(
        s.handle('{"id":"x","method":"ping"}'),
        '{"jsonrpc":"2.0","id":"x","error":{"code":-32600,"message":"Invalid Request"}}',
        "missing jsonrpc",
    )
    # JSON-RPC 4.2: params, when present, MUST be an object or an array.
    _expect(
        s.handle('{"jsonrpc":"2.0","id":1,"method":"ping","params":"bar"}'),
        '{"jsonrpc":"2.0","id":1,"error":{"code":-32600,"message":"Invalid Request"}}',
        "string params",
    )
    _expect(
        s.handle('{"jsonrpc":"2.0","id":2,"method":"ping","params":3}'),
        '{"jsonrpc":"2.0","id":2,"error":{"code":-32600,"message":"Invalid Request"}}',
        "number params",
    )
    # A null params is present and not structured, so it is refused too.
    _expect(
        s.handle('{"jsonrpc":"2.0","id":3,"method":"ping","params":null}'),
        '{"jsonrpc":"2.0","id":3,"error":{"code":-32600,"message":"Invalid Request"}}',
        "null params",
    )
    # A boolean params is the last non-structured JSON type; refused too.
    _expect(
        s.handle('{"jsonrpc":"2.0","id":4,"method":"ping","params":true}'),
        '{"jsonrpc":"2.0","id":4,"error":{"code":-32600,"message":"Invalid Request"}}',
        "bool params",
    )
    # The rule holds for a notification as well: scalar params make it an
    # invalid request, answered with a null id.
    _expect(
        s.handle('{"jsonrpc":"2.0","method":"notifications/initialized","params":"bar"}'),
        invalid,
        "notification with string params",
    )
    # Integer and string ids are echoed with their type.
    _expect(s.handle('{"jsonrpc":"2.0","id":-12,"method":"ping"}'), '{"jsonrpc":"2.0","id":-12,"result":{}}', "negative integer id")
    _expect(s.handle('{"jsonrpc":"2.0","id":"12","method":"ping"}'), '{"jsonrpc":"2.0","id":"12","result":{}}', "string id")
    print("  test_request_id_rules: PASS")


def test_tools_call_params_and_errors() raises:
    var s = _ready()
    _expect(
        s.handle('{"jsonrpc":"2.0","id":1,"method":"tools/call"}'),
        '{"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"Invalid params","data":"tools/call requires a params object"}}',
        "tools/call without params",
    )
    _expect(
        s.handle('{"jsonrpc":"2.0","id":2,"method":"tools/call","params":["echo"]}'),
        '{"jsonrpc":"2.0","id":2,"error":{"code":-32602,"message":"Invalid params","data":"tools/call requires a params object"}}',
        "tools/call with array params",
    )
    _expect(
        s.handle('{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":7}}'),
        '{"jsonrpc":"2.0","id":3,"error":{"code":-32602,"message":"Invalid params","data":"tools/call requires params.name, a string"}}',
        "tools/call with a numeric name",
    )
    _expect(
        s.handle('{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"echo","arguments":"hi"}}'),
        '{"jsonrpc":"2.0","id":4,"error":{"code":-32602,"message":"Invalid params","data":"tools/call params.arguments must be an object"}}',
        "tools/call with string arguments",
    )
    assert_equal(s.tools().calls, 0)
    # No arguments: the tool sees {}.
    _expect(
        s.handle('{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"echo"}}'),
        '{"jsonrpc":"2.0","id":5,"result":{"content":[{"type":"text","text":""}]}}',
        "tools/call without arguments",
    )
    _expect(
        s.handle('{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"echo","arguments":{"text":"a\\"b"}}}'),
        '{"jsonrpc":"2.0","id":6,"result":{"content":[{"type":"text","text":"a\\"b"}]}}',
        "tools/call echo",
    )
    # A raise out of the tool is a tool execution error, not a protocol one.
    _expect(
        s.handle('{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"fail"}}'),
        '{"jsonrpc":"2.0","id":7,"result":{"content":[{"type":"text","text":"backend unavailable"}],"isError":true}}',
        "tools/call of a raising tool",
    )
    assert_equal(s.tools().calls, 3)
    print("  test_tools_call_params_and_errors: PASS")


def test_lists_refuse_a_cursor() raises:
    var s = _ready()
    var refused = '{"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"Invalid params","data":"unknown cursor: this server does not paginate"}}'
    _expect(s.handle('{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"cursor":"c"}}'), refused, "tools/list cursor")
    _expect(s.handle('{"jsonrpc":"2.0","id":1,"method":"resources/list","params":{"cursor":"c"}}'), refused, "resources/list cursor")
    _expect(s.handle('{"jsonrpc":"2.0","id":1,"method":"resources/templates/list","params":{"cursor":"c"}}'), refused, "templates cursor")
    # No params at all is a plain list.
    _expect(
        s.handle('{"jsonrpc":"2.0","id":2,"method":"tools/list"}'),
        '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"echo","inputSchema":{"type":"object"}}]}}',
        "tools/list without params",
    )
    print("  test_lists_refuse_a_cursor: PASS")


def test_resource_errors_and_blob() raises:
    var s = _ready()
    _expect(
        s.handle('{"jsonrpc":"2.0","id":1,"method":"resources/read","params":{}}'),
        '{"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"Invalid params","data":"resources/read requires params.uri, a string"}}',
        "resources/read without uri",
    )
    # A raise in the provider is Internal error, and its text is not sent.
    _expect(
        s.handle('{"jsonrpc":"2.0","id":2,"method":"resources/read","params":{"uri":"mem://boom"}}'),
        '{"jsonrpc":"2.0","id":2,"error":{"code":-32603,"message":"Internal error"}}',
        "resources/read of a raising provider",
    )
    _expect(
        s.handle('{"jsonrpc":"2.0","id":3,"method":"resources/read","params":{"uri":"mem://hi"}}'),
        '{"jsonrpc":"2.0","id":3,"result":{"contents":[{"uri":"mem://hi","mimeType":"application/octet-stream","blob":"aGk="}]}}',
        "binary contents",
    )
    print("  test_resource_errors_and_blob: PASS")


def test_unadvertised_capability_is_method_not_found() raises:
    var s = McpServer(ServerInfo("bare", "0"), NoTools(), NoResources())
    var got = parse_json_value(s.handle(_init_request("1.0.0")).value())
    assert_equal(got.get("result").get("capabilities").serialize(), "{}")
    var nf = '{"jsonrpc":"2.0","id":4,"error":{"code":-32601,"message":"Method not found"}}'
    _expect(s.handle('{"jsonrpc":"2.0","id":4,"method":"tools/list"}'), nf, "tools/list on NoTools")
    _expect(s.handle('{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"x"}}'), nf, "tools/call on NoTools")
    _expect(s.handle('{"jsonrpc":"2.0","id":4,"method":"resources/list"}'), nf, "resources/list on NoResources")
    _expect(s.handle('{"jsonrpc":"2.0","id":4,"method":"resources/read","params":{"uri":"x"}}'), nf, "resources/read on NoResources")
    _expect(s.handle('{"jsonrpc":"2.0","id":4,"method":"prompts/list"}'), nf, "prompts/list")
    # A request named like the notification is still a request: unknown.
    _expect(s.handle('{"jsonrpc":"2.0","id":4,"method":"notifications/initialized"}'), nf, "notification name with an id")
    print("  test_unadvertised_capability_is_method_not_found: PASS")


def test_value_checks() raises:
    var msg = String("")
    try:
        _ = Tool("t", JsonValue.null())
    except e:
        msg = String(e)
    assert_equal(msg, "McpError: Tool.input_schema must be a JSON object")
    var r = ToolResult()
    msg = String("")
    try:
        r.add_block(parse_json_value('{"data":"x"}'))
    except e:
        msg = String(e)
    assert_equal(msg, "McpError: a content block needs a string 'type'")
    msg = String("")
    try:
        r.set_structured_content(parse_json_value("[1]"))
    except e:
        msg = String(e)
    assert_equal(msg, "McpError: structuredContent must be a JSON object")
    r.add_block(parse_json_value('{"type":"image","data":"AA==","mimeType":"image/png"}'))
    assert_equal(
        r.to_json().serialize(),
        '{"content":[{"type":"image","data":"AA==","mimeType":"image/png"}]}',
    )
    var res = Resource("u", "n")
    res.size = 3
    assert_equal(res.to_json().serialize(), '{"uri":"u","name":"n","size":3}')
    print("  test_value_checks: PASS")


def main() raises:
    print("test_mcp_lifecycle")
    test_gate_before_initialize()
    test_second_initialize_refused()
    test_version_negotiation()
    test_initialize_params_checked()
    test_request_id_rules()
    test_tools_call_params_and_errors()
    test_lists_refuse_a_cursor()
    test_resource_errors_and_blob()
    test_unadvertised_capability_is_method_not_found()
    test_value_checks()
    print("test_mcp_lifecycle: ALL PASS")
