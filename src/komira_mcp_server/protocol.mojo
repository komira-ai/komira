# =============================================================================
# komira_mcp_server/protocol.mojo: the MCP values a server sends.
# =============================================================================
#
# The protocol revisions this package speaks, the MCP-specific error code,
# and the value types of the `initialize`, `tools/*` and `resources/*`
# results: `ServerInfo` (the `Implementation` object), `Tool`,
# `ToolResult`, `Resource` and `ResourceContents`. Each turns itself into a
# `JsonValue` with `to_json`; the member names are the spec's.
#
# Every type owns its storage (`String`, `JsonValue`, `List`). A JSON Schema
# (`inputSchema`, `outputSchema`) is carried as a `JsonValue` and written
# verbatim: this package does not validate schemas or tool arguments
# against them. Members a type has no field for (`icons`, `annotations`,
# `execution`, `_meta`, ...) go in its `extra` object, whose members are
# appended verbatim after the typed ones.
# =============================================================================

from komira_encoding import base64_encode
from komira_json import JsonValue


# The protocol revisions this server speaks, newest first. An `initialize`
# naming one of them gets that revision back; any other gets the newest
# (version negotiation, the "Lifecycle" page of the specification).
comptime MCP_LATEST_PROTOCOL_VERSION = "2025-11-25"
comptime MCP_PREVIOUS_PROTOCOL_VERSION = "2025-06-18"

# The MCP error code for an unknown resource URI ("Resources", "Error
# Handling").
comptime MCP_RESOURCE_NOT_FOUND: Int = -32002


def mcp_supported_protocol_versions() -> List[String]:
    """The revisions this server speaks, newest first."""
    var v = List[String]()
    v.append(String(MCP_LATEST_PROTOCOL_VERSION))
    v.append(String(MCP_PREVIOUS_PROTOCOL_VERSION))
    return v^


def _append_extra(mut obj: JsonValue, extra: JsonValue) raises:
    for i in range(extra.num_members()):
        obj.set_member(extra.key_at(i), extra.value_at(i))


def _require_object(v: JsonValue, what: String) raises:
    if not v.is_object():
        raise Error(String("McpError: ") + what + " must be a JSON object")


# =============================================================================
# ServerInfo: the `serverInfo` member of the `initialize` result.
# =============================================================================


struct ServerInfo(Copyable, Movable):
    """The server's `Implementation` object: `name` and `version` are
    required; `title`, `description` and `website_url` are written when set;
    `extra` (an object) carries any other member, such as `icons`."""

    var name: String
    var version: String
    var title: Optional[String]
    var description: Optional[String]
    var website_url: Optional[String]
    var extra: JsonValue

    def __init__(out self, var name: String, var version: String):
        self.name = name^
        self.version = version^
        self.title = None
        self.description = None
        self.website_url = None
        self.extra = JsonValue.empty_object()

    def to_json(self) raises -> JsonValue:
        _require_object(self.extra, "ServerInfo.extra")
        var o = JsonValue.empty_object()
        o.set_member("name", JsonValue.from_string(self.name))
        if self.title:
            o.set_member("title", JsonValue.from_string(self.title.value()))
        o.set_member("version", JsonValue.from_string(self.version))
        if self.description:
            o.set_member(
                "description", JsonValue.from_string(self.description.value())
            )
        if self.website_url:
            o.set_member(
                "websiteUrl", JsonValue.from_string(self.website_url.value())
            )
        _append_extra(o, self.extra)
        return o^


# =============================================================================
# Tools.
# =============================================================================


struct Tool(Copyable, Movable):
    """One entry of a `tools/list` result.

    `input_schema` must be a JSON object (the spec forbids null); the
    constructor refuses anything else. `output_schema`, when set, must be
    an object too. `extra` carries `icons`, `annotations`, `execution` and
    any other member."""

    var name: String
    var title: Optional[String]
    var description: Optional[String]
    var input_schema: JsonValue
    var output_schema: Optional[JsonValue]
    var extra: JsonValue

    def __init__(out self, var name: String, var input_schema: JsonValue) raises:
        _require_object(input_schema, "Tool.input_schema")
        self.name = name^
        self.title = None
        self.description = None
        self.input_schema = input_schema^
        self.output_schema = None
        self.extra = JsonValue.empty_object()

    def to_json(self) raises -> JsonValue:
        _require_object(self.input_schema, "Tool.input_schema")
        _require_object(self.extra, "Tool.extra")
        var o = JsonValue.empty_object()
        o.set_member("name", JsonValue.from_string(self.name))
        if self.title:
            o.set_member("title", JsonValue.from_string(self.title.value()))
        if self.description:
            o.set_member(
                "description", JsonValue.from_string(self.description.value())
            )
        o.set_member("inputSchema", self.input_schema.copy())
        if self.output_schema:
            _require_object(self.output_schema.value(), "Tool.output_schema")
            o.set_member("outputSchema", self.output_schema.value().copy())
        _append_extra(o, self.extra)
        return o^


struct ToolResult(Copyable, Movable):
    """A `tools/call` result: `content` (an array of content blocks),
    `structuredContent` when set, and `isError` when set.

    A tool reports its own failure (bad input, a failed call it made) as a
    result with `isError: true`, not as a JSON-RPC error: `ToolResult.error`
    builds one. `is_error` left unset omits the member, which the spec reads
    as false."""

    var content: JsonValue
    var structured_content: Optional[JsonValue]
    var is_error: Optional[Bool]

    def __init__(out self):
        self.content = JsonValue.empty_array()
        self.structured_content = None
        self.is_error = None

    @staticmethod
    def text(var s: String) raises -> ToolResult:
        """One text block; `isError` omitted."""
        var r = ToolResult()
        r.add_text(s^)
        return r^

    @staticmethod
    def error(var s: String) raises -> ToolResult:
        """One text block and `isError: true`."""
        var r = ToolResult()
        r.add_text(s^)
        r.is_error = True
        return r^

    def add_text(mut self, var s: String) raises:
        """Append `{"type":"text","text":s}`."""
        var b = JsonValue.empty_object()
        b.set_member("type", JsonValue.from_string("text"))
        b.set_member("text", JsonValue.from_string(s^))
        self.content.push(b^)

    def add_block(mut self, var block: JsonValue) raises:
        """Append any other content block (image, audio, resource_link,
        resource). It must be an object whose `type` is a string."""
        _require_object(block, "a content block")
        if not block.has("type") or not block.get("type").is_string():
            raise Error("McpError: a content block needs a string 'type'")
        self.content.push(block^)

    def set_structured_content(mut self, var value: JsonValue) raises:
        """Set `structuredContent`, which must be an object. The spec asks a
        tool that sets it to also return the serialized JSON as a text
        block; that block is the caller's to add."""
        _require_object(value, "structuredContent")
        self.structured_content = value^

    def to_json(self) raises -> JsonValue:
        var o = JsonValue.empty_object()
        o.set_member("content", self.content.copy())
        if self.structured_content:
            o.set_member(
                "structuredContent", self.structured_content.value().copy()
            )
        if self.is_error:
            o.set_member("isError", JsonValue.from_bool(self.is_error.value()))
        return o^


# =============================================================================
# Resources.
# =============================================================================


struct Resource(Copyable, Movable):
    """One entry of a `resources/list` result: `uri` and `name` required;
    `title`, `description`, `mime_type` and `size` written when set; `extra`
    carries `icons`, `annotations` and any other member."""

    var uri: String
    var name: String
    var title: Optional[String]
    var description: Optional[String]
    var mime_type: Optional[String]
    var size: Optional[Int]
    var extra: JsonValue

    def __init__(out self, var uri: String, var name: String):
        self.uri = uri^
        self.name = name^
        self.title = None
        self.description = None
        self.mime_type = None
        self.size = None
        self.extra = JsonValue.empty_object()

    def to_json(self) raises -> JsonValue:
        _require_object(self.extra, "Resource.extra")
        var o = JsonValue.empty_object()
        o.set_member("uri", JsonValue.from_string(self.uri))
        o.set_member("name", JsonValue.from_string(self.name))
        if self.title:
            o.set_member("title", JsonValue.from_string(self.title.value()))
        if self.description:
            o.set_member(
                "description", JsonValue.from_string(self.description.value())
            )
        if self.mime_type:
            o.set_member(
                "mimeType", JsonValue.from_string(self.mime_type.value())
            )
        if self.size:
            o.set_member("size", JsonValue.from_i64(Int64(self.size.value())))
        _append_extra(o, self.extra)
        return o^


struct ResourceContents(Copyable, Movable):
    """One element of a `resources/read` result's `contents`: text
    (`{uri, mimeType?, text}`) or binary (`{uri, mimeType?, blob}`, the
    bytes in base64). Build one with `ResourceContents.text` or
    `ResourceContents.binary`."""

    var uri: String
    var mime_type: Optional[String]
    var body: String
    var is_blob: Bool

    def __init__(
        out self,
        var uri: String,
        var mime_type: Optional[String],
        var body: String,
        is_blob: Bool,
    ):
        self.uri = uri^
        self.mime_type = mime_type^
        self.body = body^
        self.is_blob = is_blob

    @staticmethod
    def text(
        var uri: String, var mime_type: Optional[String], var text: String
    ) -> ResourceContents:
        """Text contents."""
        return ResourceContents(uri^, mime_type^, text^, False)

    @staticmethod
    def binary(
        var uri: String, var mime_type: Optional[String], data: List[UInt8]
    ) -> ResourceContents:
        """Binary contents: `data` is written as base64 in `blob`."""
        return ResourceContents(uri^, mime_type^, base64_encode(Span(data)), True)

    def to_json(self) raises -> JsonValue:
        var o = JsonValue.empty_object()
        o.set_member("uri", JsonValue.from_string(self.uri))
        if self.mime_type:
            o.set_member(
                "mimeType", JsonValue.from_string(self.mime_type.value())
            )
        if self.is_blob:
            o.set_member("blob", JsonValue.from_string(self.body))
        else:
            o.set_member("text", JsonValue.from_string(self.body))
        return o^
