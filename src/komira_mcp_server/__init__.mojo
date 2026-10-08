"""`komira_mcp_server`: a Model Context Protocol (MCP) server library.

It speaks the MCP revisions `mcp_supported_protocol_versions()` lists (the
newest is `MCP_LATEST_PROTOCOL_VERSION`), the ones that open a session with
an `initialize` handshake. It does no I/O: `McpServer.handle` takes one
JSON-RPC message as text and returns the reply text, or None when no reply
is due, so any transport (stdio lines, an HTTP handler) can carry it.

Modules:
  - jsonrpc.mojo  : JSON-RPC 2.0 framing: `parse_jsonrpc_message` classifies
                    one message (request, notification, response, or
                    invalid with the error to send) and the reply writers
                    `encode_jsonrpc_result` / `encode_jsonrpc_error`; the
                    standard error codes.
  - protocol.mojo : the revisions spoken, `MCP_RESOURCE_NOT_FOUND`, and the
                    result values `ServerInfo`, `Tool`, `ToolResult`,
                    `Resource`, `ResourceContents`.
  - provider.mojo : the `ToolProvider` and `ResourceProvider` traits a
                    server's tools and resources implement, and the empty
                    `NoTools` / `NoResources`.
  - server.mojo   : `McpServer[T, R]`: the lifecycle (`initialize`, version
                    negotiation, `notifications/initialized`), `ping`,
                    `tools/list`, `tools/call`, `resources/list`,
                    `resources/templates/list` and `resources/read`.

Not here: prompts, completions, logging, subscriptions, list-changed
notifications, pagination, tasks, requests from the server to the client,
JSON Schema validation of tool arguments, and the per-request-metadata
revisions that have no `initialize` handshake.

Encapsulation: the public API takes and returns owned values (`String`,
`JsonValue`, `List`, the result structs) and a `ref` to a provider. No
pointers.
"""

from .jsonrpc import (
    JSONRPC_PARSE_ERROR,
    JSONRPC_INVALID_REQUEST,
    JSONRPC_METHOD_NOT_FOUND,
    JSONRPC_INVALID_PARAMS,
    JSONRPC_INTERNAL_ERROR,
    JSONRPC_REQUEST,
    JSONRPC_NOTIFICATION,
    JSONRPC_RESPONSE,
    JSONRPC_INVALID,
    JsonRpcMessage,
    parse_jsonrpc_message,
    encode_jsonrpc_result,
    encode_jsonrpc_error,
)
from .protocol import (
    MCP_LATEST_PROTOCOL_VERSION,
    MCP_PREVIOUS_PROTOCOL_VERSION,
    MCP_RESOURCE_NOT_FOUND,
    mcp_supported_protocol_versions,
    ServerInfo,
    Tool,
    ToolResult,
    Resource,
    ResourceContents,
)
from .provider import ToolProvider, ResourceProvider, NoTools, NoResources
from .server import McpServer
