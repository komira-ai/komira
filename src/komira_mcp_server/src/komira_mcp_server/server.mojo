# =============================================================================
# komira_mcp_server/server.mojo: McpServer[T, R], one MCP session.
# =============================================================================
#
# `McpServer.handle` takes one JSON-RPC message as text and returns the
# reply text, or None when no reply is due (a notification, or a response
# from the client). It does no I/O: a transport (stdio lines, an HTTP
# handler) reads a message, calls `handle`, and writes what it returns. One
# `McpServer` value is one session; it holds the lifecycle state.
#
# Lifecycle (the "Lifecycle" page of the specification):
#   - Before `initialize` has been answered, only `initialize` and `ping`
#     are served. Any other request gets Invalid Request (-32600) with the
#     message "Server not initialized"; a notification is dropped.
#   - `initialize` checks its params (an object with `protocolVersion`, a
#     string; `capabilities`, an object; `clientInfo`, an object with string
#     `name` and `version`), negotiates the revision (the client's when this
#     server speaks it, else `MCP_LATEST_PROTOCOL_VERSION`), and answers with
#     the revision, the capabilities and `serverInfo`. A second `initialize`
#     gets Invalid Request, "Server already initialized".
#   - `notifications/initialized` is recorded (`client_ready`); requests
#     are served from the `initialize` answer on.
#
# Methods: `initialize`, `ping`, and, when the provider advertises the
# capability, `tools/list`, `tools/call`, `resources/list`,
# `resources/templates/list` (always empty: there is no template seam) and
# `resources/read`. Any other request gets Method not found (-32601); any
# notification other than `notifications/initialized` is dropped.
#
# A capability is advertised as `{}`: this server sends no list-changed
# notifications and takes no subscriptions. Lists are not paginated, so a
# `cursor` in a list request is one this server never issued, and is
# refused with Invalid params ("Pagination", which asks for -32602 on an
# invalid cursor).
#
# `handle` never raises: an unexpected raise while answering a request
# becomes Internal error (-32603) without detail.
# =============================================================================

from komira_json import JsonValue

from .jsonrpc import (
    JsonRpcMessage,
    parse_jsonrpc_message,
    encode_jsonrpc_result,
    encode_jsonrpc_error,
    JSONRPC_REQUEST,
    JSONRPC_NOTIFICATION,
    JSONRPC_INVALID,
    JSONRPC_INVALID_REQUEST,
    JSONRPC_METHOD_NOT_FOUND,
    JSONRPC_INVALID_PARAMS,
    JSONRPC_INTERNAL_ERROR,
    JSONRPC_INVALID_REQUEST_MESSAGE,
    JSONRPC_METHOD_NOT_FOUND_MESSAGE,
    JSONRPC_INVALID_PARAMS_MESSAGE,
    JSONRPC_INTERNAL_ERROR_MESSAGE,
)
from .protocol import (
    MCP_LATEST_PROTOCOL_VERSION,
    MCP_RESOURCE_NOT_FOUND,
    ServerInfo,
    ToolResult,
    mcp_supported_protocol_versions,
)
from .provider import ToolProvider, ResourceProvider


struct _Reply(Movable):
    """What one request is answered with: a result, or an error."""

    var is_error: Bool
    var result: JsonValue
    var code: Int
    var message: String
    var data: Optional[JsonValue]

    def __init__(out self, var result: JsonValue):
        self.is_error = False
        self.result = result^
        self.code = 0
        self.message = String("")
        self.data = None

    def __init__(
        out self, code: Int, var message: String, var data: Optional[JsonValue]
    ):
        self.is_error = True
        self.result = JsonValue.null()
        self.code = code
        self.message = message^
        self.data = data^


def _error(code: Int, var message: String) -> _Reply:
    return _Reply(code, message^, None)


def _invalid_params(var why: String) -> _Reply:
    """Invalid params, with `why` as the error's `data` string."""
    return _Reply(
        JSONRPC_INVALID_PARAMS,
        String(JSONRPC_INVALID_PARAMS_MESSAGE),
        JsonValue.from_string(why^),
    )


def _params_object(msg: JsonRpcMessage) -> Optional[JsonValue]:
    """The request's params as an object (`{}` when absent), or None when
    they are present but not an object."""
    if not msg.has_params:
        return JsonValue.empty_object()
    if not msg.params.is_object():
        return None
    return msg.params.copy()


def _string_member(obj: JsonValue, key: String) raises -> Optional[String]:
    """`obj[key]` when it is a string, else None."""
    if not obj.has(key):
        return None
    var v = obj.get(key)
    if not v.is_string():
        return None
    return v.as_string()


struct McpServer[T: ToolProvider, R: ResourceProvider](Movable):
    """One MCP session over a tool provider and a resource provider."""

    var _tools: Self.T
    var _resources: Self.R
    var _info: ServerInfo
    var _instructions: Optional[String]
    var _initialized: Bool
    var _client_ready: Bool
    var _protocol_version: String

    def __init__(
        out self, var info: ServerInfo, var tools: Self.T, var resources: Self.R
    ):
        self._tools = tools^
        self._resources = resources^
        self._info = info^
        self._instructions = None
        self._initialized = False
        self._client_ready = False
        self._protocol_version = String("")

    def set_instructions(mut self, var instructions: String):
        """Text sent as `instructions` in the `initialize` result."""
        self._instructions = instructions^

    def is_initialized(self) -> Bool:
        """Whether `initialize` has been answered."""
        return self._initialized

    def client_ready(self) -> Bool:
        """Whether the client has sent `notifications/initialized`."""
        return self._client_ready

    def protocol_version(self) -> String:
        """The negotiated revision; empty before `initialize`."""
        return self._protocol_version

    def tools(mut self) -> ref [self._tools] Self.T:
        """The tool provider."""
        return self._tools

    def resources(mut self) -> ref [self._resources] Self.R:
        """The resource provider."""
        return self._resources

    def handle(mut self, message: String) -> Optional[String]:
        """Answer one JSON-RPC message. Returns the reply text, or None when
        no reply is due. Never raises."""
        var msg = parse_jsonrpc_message(message)
        if msg.kind == JSONRPC_INVALID:
            return encode_jsonrpc_error(msg.id, msg.error_code, msg.error_message)
        if msg.kind == JSONRPC_NOTIFICATION:
            if msg.method == "notifications/initialized" and self._initialized:
                self._client_ready = True
            return None
        if msg.kind != JSONRPC_REQUEST:
            return None  # a response from the client: nothing to answer
        var reply: _Reply
        try:
            reply = self._dispatch(msg)
        except:
            reply = _error(
                JSONRPC_INTERNAL_ERROR, String(JSONRPC_INTERNAL_ERROR_MESSAGE)
            )
        if reply.is_error:
            return encode_jsonrpc_error(
                msg.id, reply.code, reply.message, reply.data
            )
        return encode_jsonrpc_result(msg.id, reply.result)

    def _dispatch(mut self, msg: JsonRpcMessage) raises -> _Reply:
        ref method = msg.method
        if method == "ping":
            return _Reply(JsonValue.empty_object())
        if method == "initialize":
            return self._initialize(msg)
        if not self._initialized:
            return _error(JSONRPC_INVALID_REQUEST, "Server not initialized")

        if self._tools.advertises_tools():
            if method == "tools/list":
                return self._tools_list(msg)
            if method == "tools/call":
                return self._tools_call(msg)
        if self._resources.advertises_resources():
            if method == "resources/list":
                return self._resources_list(msg)
            if method == "resources/templates/list":
                return self._templates_list(msg)
            if method == "resources/read":
                return self._resources_read(msg)
        return _error(
            JSONRPC_METHOD_NOT_FOUND, String(JSONRPC_METHOD_NOT_FOUND_MESSAGE)
        )

    def _initialize(mut self, msg: JsonRpcMessage) raises -> _Reply:
        if self._initialized:
            return _error(JSONRPC_INVALID_REQUEST, "Server already initialized")
        var p = _params_object(msg)
        if not p or not msg.has_params:
            return _invalid_params("initialize requires a params object")
        ref params = p.value()
        var requested = _string_member(params, "protocolVersion")
        if not requested:
            return _invalid_params(
                "initialize requires params.protocolVersion, a string"
            )
        if not params.has("capabilities") or not params.get(
            "capabilities"
        ).is_object():
            return _invalid_params(
                "initialize requires params.capabilities, an object"
            )
        if not params.has("clientInfo") or not params.get(
            "clientInfo"
        ).is_object():
            return _invalid_params(
                "initialize requires params.clientInfo, an object"
            )
        var client = params.get("clientInfo")
        if not _string_member(client, "name") or not _string_member(
            client, "version"
        ):
            return _invalid_params(
                "initialize requires params.clientInfo.name and"
                " params.clientInfo.version, strings"
            )

        var chosen = String(MCP_LATEST_PROTOCOL_VERSION)
        var supported = mcp_supported_protocol_versions()
        for i in range(len(supported)):
            if supported[i] == requested.value():
                chosen = supported[i]

        var caps = JsonValue.empty_object()
        if self._tools.advertises_tools():
            caps.set_member("tools", JsonValue.empty_object())
        if self._resources.advertises_resources():
            caps.set_member("resources", JsonValue.empty_object())

        var result = JsonValue.empty_object()
        result.set_member("protocolVersion", JsonValue.from_string(chosen))
        result.set_member("capabilities", caps^)
        result.set_member("serverInfo", self._info.to_json())
        if self._instructions:
            result.set_member(
                "instructions",
                JsonValue.from_string(self._instructions.value()),
            )
        self._initialized = True
        self._protocol_version = chosen^
        return _Reply(result^)

    def _list_params_ok(self, msg: JsonRpcMessage) raises -> Optional[_Reply]:
        """None when a list request's params are acceptable, else the
        error to answer with."""
        var p = _params_object(msg)
        if not p:
            return _invalid_params("params must be an object")
        if p.value().has("cursor"):
            return _invalid_params(
                "unknown cursor: this server does not paginate"
            )
        return None

    def _tools_list(mut self, msg: JsonRpcMessage) raises -> _Reply:
        var bad = self._list_params_ok(msg)
        if bad:
            return bad.take()
        var tools = self._tools.list_tools()
        var arr = JsonValue.empty_array()
        for i in range(len(tools)):
            arr.push(tools[i].to_json())
        var result = JsonValue.empty_object()
        result.set_member("tools", arr^)
        return _Reply(result^)

    def _tools_call(mut self, msg: JsonRpcMessage) raises -> _Reply:
        var p = _params_object(msg)
        if not p or not msg.has_params:
            return _invalid_params("tools/call requires a params object")
        ref params = p.value()
        var name = _string_member(params, "name")
        if not name:
            return _invalid_params("tools/call requires params.name, a string")
        var arguments = JsonValue.empty_object()
        if params.has("arguments"):
            arguments = params.get("arguments")
            if not arguments.is_object():
                return _invalid_params(
                    "tools/call params.arguments must be an object"
                )
        var outcome: Optional[ToolResult]
        try:
            outcome = self._tools.call_tool(name.value(), arguments)
        except e:
            outcome = ToolResult.error(String(e))
        if not outcome:
            return _error(
                JSONRPC_INVALID_PARAMS, String("Unknown tool: ") + name.value()
            )
        return _Reply(outcome.value().to_json())

    def _resources_list(mut self, msg: JsonRpcMessage) raises -> _Reply:
        var bad = self._list_params_ok(msg)
        if bad:
            return bad.take()
        var resources = self._resources.list_resources()
        var arr = JsonValue.empty_array()
        for i in range(len(resources)):
            arr.push(resources[i].to_json())
        var result = JsonValue.empty_object()
        result.set_member("resources", arr^)
        return _Reply(result^)

    def _templates_list(mut self, msg: JsonRpcMessage) raises -> _Reply:
        var bad = self._list_params_ok(msg)
        if bad:
            return bad.take()
        var result = JsonValue.empty_object()
        result.set_member("resourceTemplates", JsonValue.empty_array())
        return _Reply(result^)

    def _resources_read(mut self, msg: JsonRpcMessage) raises -> _Reply:
        var p = _params_object(msg)
        if not p or not msg.has_params:
            return _invalid_params("resources/read requires a params object")
        var uri = _string_member(p.value(), "uri")
        if not uri:
            return _invalid_params(
                "resources/read requires params.uri, a string"
            )
        var contents = self._resources.read_resource(uri.value())
        if not contents:
            var data = JsonValue.empty_object()
            data.set_member("uri", JsonValue.from_string(uri.value()))
            return _Reply(
                MCP_RESOURCE_NOT_FOUND, String("Resource not found"), data^
            )
        var arr = JsonValue.empty_array()
        ref items = contents.value()
        for i in range(len(items)):
            arr.push(items[i].to_json())
        var result = JsonValue.empty_object()
        result.set_member("contents", arr^)
        return _Reply(result^)
