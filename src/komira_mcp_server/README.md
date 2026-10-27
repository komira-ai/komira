# komira_mcp_server

A Model Context Protocol (MCP) server library. It speaks the MCP revisions
that open a session with an `initialize` handshake
(`mcp_supported_protocol_versions()`, newest first): JSON-RPC 2.0 framing,
the lifecycle (`initialize`, version negotiation,
`notifications/initialized`), `ping`, tools (`tools/list`, `tools/call`) and
resources (`resources/list`, `resources/templates/list`, `resources/read`).

It does no I/O. `McpServer.handle` takes one JSON-RPC message as text and
returns the reply text, or `None` when no reply is due (a notification, or a
response from the client), so a stdio loop or an HTTP handler can carry it.
One `McpServer` value is one session. A server's tools and resources are a
`ToolProvider` and a `ResourceProvider`; `NoTools` and `NoResources` stand in
for a server that offers none, and it then advertises no such capability.

Errors follow the specification: an unknown tool is the protocol error
Invalid params (`Unknown tool: <name>`); a tool's own failure, returned or
raised, is a result with `isError: true`; an unknown resource is
`MCP_RESOURCE_NOT_FOUND` (-32002) with the URI in `data`. Every request but
`initialize` and `ping` is refused until `initialize` has been answered.

## Examples

A server with one tool:

<!-- mojo-hidden from std.testing import assert_equal, assert_true, assert_false -->
```mojo module
from komira_json import JsonValue, parse_json_value
from komira_mcp_server import McpServer, NoResources, ServerInfo, Tool, ToolProvider, ToolResult
from komira_mcp_server import MCP_LATEST_PROTOCOL_VERSION


struct Greeter(ToolProvider):
    def __init__(out self):
        pass

    def advertises_tools(self) -> Bool:
        return True

    def list_tools(self) raises -> List[Tool]:
        var greet = Tool(
            "greet",
            parse_json_value(
                '{"type":"object","properties":{"who":{"type":"string"}},"required":["who"]}'
            ),
        )
        greet.description = String("Say hello")
        var tools = List[Tool]()
        tools.append(greet^)
        return tools^

    def call_tool(
        mut self, name: String, arguments: JsonValue
    ) raises -> Optional[ToolResult]:
        if name != "greet":
            return None  # the server answers "Unknown tool: <name>"
        if not arguments.has("who"):
            return ToolResult.error("greet needs who")
        return ToolResult.text("hello, " + arguments.get("who").as_string())


def main() raises:
    var server = McpServer(ServerInfo("greeter", "1.0.0"), Greeter(), NoResources())
    var init = server.handle(
        '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"1.0",'
        + '"capabilities":{},"clientInfo":{"name":"demo","version":"0"}}}'
    )
    assert_true(server.is_initialized())
    # An unknown revision was asked for, so the newest one comes back.
    assert_equal(server.protocol_version(), MCP_LATEST_PROTOCOL_VERSION)
    assert_equal(
        parse_json_value(init.value()).get("result").get("capabilities").serialize(),
        '{"tools":{}}',
    )
    assert_false(Bool(server.handle('{"jsonrpc":"2.0","method":"notifications/initialized"}')))

    var reply = server.handle(
        '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"greet","arguments":{"who":"ada"}}}'
    )
    assert_equal(
        reply.value(),
        '{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"hello, ada"}]}}',
    )
```

The negotiated revision, and the protocol errors:

<!-- mojo-hidden
from std.testing import assert_equal
from komira_json import JsonValue, parse_json_value
from komira_mcp_server import Tool, ToolProvider, ToolResult


struct Greeter(ToolProvider):
    def __init__(out self):
        pass

    def advertises_tools(self) -> Bool:
        return True

    def list_tools(self) raises -> List[Tool]:
        var greet = Tool(
            "greet",
            parse_json_value(
                '{"type":"object","properties":{"who":{"type":"string"}},"required":["who"]}'
            ),
        )
        greet.description = String("Say hello")
        var tools = List[Tool]()
        tools.append(greet^)
        return tools^

    def call_tool(
        mut self, name: String, arguments: JsonValue
    ) raises -> Optional[ToolResult]:
        if name != "greet":
            return None  # the server answers "Unknown tool: <name>"
        if not arguments.has("who"):
            return ToolResult.error("greet needs who")
        return ToolResult.text("hello, " + arguments.get("who").as_string())
-->
```mojo module
from komira_mcp_server import MCP_LATEST_PROTOCOL_VERSION, McpServer, NoResources, ServerInfo


def main() raises:
    var s = McpServer(ServerInfo("greeter", "1.0.0"), Greeter(), NoResources())
    assert_equal(
        s.handle('{"jsonrpc":"2.0","id":1,"method":"tools/list"}').value(),
        '{"jsonrpc":"2.0","id":1,"error":{"code":-32600,"message":"Server not initialized"}}',
    )
    _ = s.handle(
        '{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"'
        + MCP_LATEST_PROTOCOL_VERSION
        + '","capabilities":{},"clientInfo":{"name":"demo","version":"0"}}}'
    )
    assert_equal(s.protocol_version(), MCP_LATEST_PROTOCOL_VERSION)
    assert_equal(
        s.handle('{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"nope"}}').value(),
        '{"jsonrpc":"2.0","id":3,"error":{"code":-32602,"message":"Unknown tool: nope"}}',
    )
    assert_equal(
        s.handle('{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"greet"}}').value(),
        '{"jsonrpc":"2.0","id":4,"result":{"content":[{"type":"text","text":"greet needs who"}],"isError":true}}',
    )
    assert_equal(
        s.handle("not json").value(),
        '{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}',
    )
```

Classifying a message without a server:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_mcp_server import JSONRPC_NOTIFICATION, parse_jsonrpc_message

var m = parse_jsonrpc_message('{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":3}}')
assert_equal(m.kind, JSONRPC_NOTIFICATION)
assert_equal(m.method, "notifications/cancelled")
```

## Not here

Prompts, completions, logging, resource subscriptions, list-changed
notifications, pagination (a list request carrying a `cursor` is refused
with Invalid params), tasks, requests from the server to the client, JSON
Schema validation of tool arguments, and the revisions that carry the
protocol version in per-request metadata instead of an `initialize`
handshake.

## Tests

Welded (`test_srcs`), so they run whenever the library is built:

- `tests/test_mcp_spec_examples.mojo`: the specification's JSON examples
  (lifecycle, ping, tools, resources and their error examples) fed to a
  server holding the examples' tool and resource; each reply must equal the
  example's response. Stated deviations: list requests drop `cursor` and
  list replies drop `nextCursor` (no pagination); the error examples and
  the structured-content example give only the reply, so their requests are
  written in the test with the example's id; resources/templates/list
  answers an empty list rather than the example's one template, since there
  is no template seam; the initialize reply is checked member by member,
  and its capabilities are `{"tools": {}, "resources": {}}` (what this
  server serves) rather than the example's logging, prompts, resource
  subscribe/listChanged, tools listChanged and tasks.
- `tests/test_jsonrpc_spec_examples.mojo`: the JSON-RPC 2.0 specification's
  examples (section 7): parse error, invalid request, unknown method,
  notifications, batches (one Invalid Request under MCP) and responses.
- `tests/test_mcp_lifecycle.mojo`: the initialize gate, version negotiation,
  request-id rules (including string, number, boolean and null `params`, on requests and notifications), initialize
  params checks (each member missing and of the wrong type), the cursor
  refusal, and how provider raises map to replies, each error reply
  compared whole.

## Build files

This package is built with buildrules' `mojo_package` and packaged for mopm as `komira_mcp_server`, version 0.1.0
(`mopm.toml`). The library is `src/komira_mcp_server/`, its tests are `tests/`. It depends on two packages,
`komira_encoding` and `komira_json`, sibling directories (`[dependencies]` of `mopm.toml`: `{ path = "../komira_json",
version = "0.1" }` and the same for `komira_encoding`), so the `.conda` of this package records
`mojo-komira_encoding >=0.1,<0.2` and `mojo-komira_json >=0.1,<0.2` as dependencies and holds none of their files:
installing `komira_mcp_server` installs both with it. The files that are not sources:

| file | what |
|---|---|
| `mopm.toml` | the mopm manifest: name, version, the Mojo version, the dependencies and where the library and its tests are |
| `mopm.lock` | the toolchain pins and the path dependencies (no registry is reached: both are siblings) |
| `mopm-toolchain.toml` | the exact mopm and Mojo versions the build uses (written by hand) |
| `coverage_floor.txt` | `lines NN.NN` and `branches NN.NN`: the least line and branch coverage `:coverage` may measure; `:coverage_floor` fails when either falls below, and above it passes and prints a hint to raise the figure |
| `buildrules.mojo.lock.bzl`, `buildrules.mojo.bzl` | written by `buildrules mojo sync` from the files above and from the manifests of the siblings; `buildrules mojo check` fails when they are stale |

`:lib` is the library file, built from the `:lib` of the two siblings, and exists only once the tests have passed.
After any change to a source, a test, a manifest of this package or of a sibling, run `buildrules mojo sync` with the
three packages staged, commit what it writes, and build `komira//src/komira_mcp_server:lib` on the farm.

`:conda` is buildrules' `mojo_conda` over `:lib`: the `.conda` of the mopm package
(`mojo-komira_mcp_server-0.1.0-mojo1.0.0_0.conda`), packed with the siblings' manifests beside its own (`members`),
which therefore exists only once the tests have passed. Publishing it (`mopm publish`) uploads, so it is a step of a
CI job that takes that file, not a build action.

`:komira_mcp_server` is `:lib` as komira's Mojo rules take it (`mojo_adopted_library`): its `deps` are the adopted
target of each package in `[dependencies]`, and the rule refuses a list that is not the closure `:lib` was built
from. It also compiles and runs the README's examples above (`[tests][readme]`) against `:lib`; the tests are not run
again.
