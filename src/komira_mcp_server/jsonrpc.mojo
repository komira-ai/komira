# =============================================================================
# komira_mcp_server/jsonrpc.mojo: JSON-RPC 2.0 framing for one MCP message.
# =============================================================================
#
# MCP messages are JSON-RPC 2.0 messages, with the restrictions of the MCP
# base protocol (the "Messages" section of the revision this package
# implements, `MCP_LATEST_PROTOCOL_VERSION`):
#
#   request      {"jsonrpc":"2.0","id":<string|integer>,"method":<string>,"params"?:<object>}
#   notification {"jsonrpc":"2.0","method":<string>,"params"?:<object>}  (no id; no reply)
#   response     {"jsonrpc":"2.0","id":<id>,"result":<object>}
#                {"jsonrpc":"2.0","id":<id|null>,"error":{"code","message","data"?}}
#
# A request id MUST be a string or an integer and MUST NOT be null (MCP
# narrows JSON-RPC here). A batch (a JSON array) is not an MCP message: the
# revisions this package speaks removed batching, so an array is answered
# with one Invalid Request error.
#
# `parse_jsonrpc_message` never raises: anything malformed comes back as a
# `JsonRpcMessage` of kind `JSONRPC_INVALID` that carries the error to send
# (code, message, and the id when it could be read). The writers build the
# reply text byte by byte, so they never raise either.
# =============================================================================

from komira_json import (
    JsonValue,
    parse_json_value,
    write_json_string,
    write_i64_dec,
)


# JSON-RPC 2.0 error codes (JSON-RPC 2.0 specification, section 5.1) and the
# message text that specification's examples use for each.
comptime JSONRPC_PARSE_ERROR: Int = -32700
comptime JSONRPC_INVALID_REQUEST: Int = -32600
comptime JSONRPC_METHOD_NOT_FOUND: Int = -32601
comptime JSONRPC_INVALID_PARAMS: Int = -32602
comptime JSONRPC_INTERNAL_ERROR: Int = -32603

comptime JSONRPC_PARSE_ERROR_MESSAGE = "Parse error"
comptime JSONRPC_INVALID_REQUEST_MESSAGE = "Invalid Request"
comptime JSONRPC_METHOD_NOT_FOUND_MESSAGE = "Method not found"
comptime JSONRPC_INVALID_PARAMS_MESSAGE = "Invalid params"
comptime JSONRPC_INTERNAL_ERROR_MESSAGE = "Internal error"

# What `parse_jsonrpc_message` found.
comptime JSONRPC_REQUEST: Int = 1
comptime JSONRPC_NOTIFICATION: Int = 2
comptime JSONRPC_RESPONSE: Int = 3
comptime JSONRPC_INVALID: Int = 4


struct JsonRpcMessage(Movable):
    """One classified JSON-RPC message.

    `kind` is one of `JSONRPC_REQUEST`, `JSONRPC_NOTIFICATION`,
    `JSONRPC_RESPONSE` (a reply from the peer, which a server answers with
    nothing) or `JSONRPC_INVALID`.

    - `method`: the method name (request and notification).
    - `id`: the request id, a JSON string or integer, kept as parsed so it is
      echoed back with its type; JSON null when there is none or it could
      not be read.
    - `params`: the `params` member, JSON null when absent; `has_params`
      says whether it was present. Framing accepts an object or an array;
      a method that needs an object refuses an array itself.
    - `error_code`, `error_message`: for `JSONRPC_INVALID`, the error to
      reply with (`id` is then the id to reply to, or null).
    """

    var kind: Int
    var method: String
    var id: JsonValue
    var params: JsonValue
    var has_params: Bool
    var error_code: Int
    var error_message: String

    def __init__(out self):
        self.kind = JSONRPC_INVALID
        self.method = String("")
        self.id = JsonValue.null()
        self.params = JsonValue.null()
        self.has_params = False
        self.error_code = 0
        self.error_message = String("")


def _invalid(code: Int, var message: String, var id: JsonValue) -> JsonRpcMessage:
    var m = JsonRpcMessage()
    m.kind = JSONRPC_INVALID
    m.error_code = code
    m.error_message = message^
    m.id = id^
    return m^


def _is_valid_id(v: JsonValue) -> Bool:
    """A request id MCP allows: a string or an integer (never null)."""
    return v.is_string() or v.is_integral_number()


def parse_jsonrpc_message(text: String) -> JsonRpcMessage:
    """Parse and classify one JSON-RPC message. Never raises.

    - Text that is not JSON: `JSONRPC_INVALID`, Parse error, id null.
    - An array (a batch) or any non-object: `JSONRPC_INVALID`, Invalid
      Request, id null.
    - An object with `method`: a request when it has an `id`, else a
      notification. It is `JSONRPC_INVALID` (Invalid Request) when
      `jsonrpc` is not the string "2.0", `method` is not a string, `params`
      is present but neither an object nor an array, or `id` is present but
      neither a string nor an integer. The error carries the id when the id
      itself is valid, else null.
    - An object without `method` that has an `id` and exactly one of
      `result` / `error`, with `jsonrpc` "2.0": `JSONRPC_RESPONSE`.
    - Anything else: `JSONRPC_INVALID`, Invalid Request.
    """
    var doc: JsonValue
    try:
        doc = parse_json_value(text)
    except:
        return _invalid(
            JSONRPC_PARSE_ERROR,
            String(JSONRPC_PARSE_ERROR_MESSAGE),
            JsonValue.null(),
        )
    if not doc.is_object():
        return _invalid(
            JSONRPC_INVALID_REQUEST,
            String(JSONRPC_INVALID_REQUEST_MESSAGE),
            JsonValue.null(),
        )

    try:
        # The id to echo in an error: the request's own when it is valid.
        var reply_id = JsonValue.null()
        var has_id = doc.has("id")
        var id_ok = False
        if has_id:
            var idv = doc.get("id")
            id_ok = _is_valid_id(idv)
            if id_ok:
                reply_id = idv^

        var version_ok = False
        if doc.has("jsonrpc"):
            var ver = doc.get("jsonrpc")
            version_ok = ver.is_string() and ver.as_string() == "2.0"

        if not doc.has("method"):
            var has_result = doc.has("result")
            var has_error = doc.has("error")
            if version_ok and has_id and (has_result != has_error):
                var r = JsonRpcMessage()
                r.kind = JSONRPC_RESPONSE
                r.id = reply_id^
                return r^
            return _invalid(
                JSONRPC_INVALID_REQUEST,
                String(JSONRPC_INVALID_REQUEST_MESSAGE),
                reply_id^,
            )

        var method_v = doc.get("method")
        var has_params = doc.has("params")
        var params_ok = True
        if has_params:
            var p = doc.get("params")
            params_ok = p.is_object() or p.is_array()
        if (
            not version_ok
            or not method_v.is_string()
            or not params_ok
            or (has_id and not id_ok)
        ):
            return _invalid(
                JSONRPC_INVALID_REQUEST,
                String(JSONRPC_INVALID_REQUEST_MESSAGE),
                reply_id^,
            )

        var m = JsonRpcMessage()
        m.kind = JSONRPC_REQUEST if has_id else JSONRPC_NOTIFICATION
        m.method = method_v.as_string()
        m.id = reply_id^
        if has_params:
            m.params = doc.get("params")
            m.has_params = True
        return m^
    except:
        # Every accessor above is guarded by a kind or presence check, so
        # this is not reached; it keeps the function total.
        return _invalid(
            JSONRPC_INVALID_REQUEST,
            String(JSONRPC_INVALID_REQUEST_MESSAGE),
            JsonValue.null(),
        )


# =============================================================================
# Writers.
# =============================================================================


def _append(mut buf: List[UInt8], s: String):
    buf.extend(Span(s.as_bytes()))


def _finish(var buf: List[UInt8]) -> String:
    return String(unsafe_from_utf8=Span(buf))


def encode_jsonrpc_result(id: JsonValue, result: JsonValue) -> String:
    """`{"jsonrpc":"2.0","id":<id>,"result":<result>}` as compact JSON."""
    var buf = List[UInt8]()
    _append(buf, '{"jsonrpc":"2.0","id":')
    id.write_to(buf)
    _append(buf, ',"result":')
    result.write_to(buf)
    buf.append(0x7D)  # '}'
    return _finish(buf^)


def encode_jsonrpc_error(
    id: JsonValue,
    code: Int,
    message: String,
    data: Optional[JsonValue] = None,
) -> String:
    """`{"jsonrpc":"2.0","id":<id|null>,"error":{"code","message","data"?}}`
    as compact JSON. `id` is JSON null when the request's id could not be
    read."""
    var buf = List[UInt8]()
    _append(buf, '{"jsonrpc":"2.0","id":')
    id.write_to(buf)
    _append(buf, ',"error":{"code":')
    write_i64_dec(buf, Int64(code))
    _append(buf, ',"message":')
    write_json_string(buf, message)
    if data:
        _append(buf, ',"data":')
        data.value().write_to(buf)
    _append(buf, "}}")
    return _finish(buf^)
