# =============================================================================
# test_mcp_spec_examples.mojo: the JSON examples of the MCP specification
# (the revision `MCP_LATEST_PROTOCOL_VERSION` names), pages "Lifecycle",
# "Ping", "Tools" and "Resources", against McpServer.
# =============================================================================
#
# Each request is the specification's example text, escaped for a Mojo
# string literal. The test providers are configured to hold what the
# examples show (the weather tool, the main.rs resource), and each reply is
# compared, as JSON with member order ignored, with the specification's
# response. Where a vector is changed, the comment says how and why:
#   - list requests drop `cursor` and list replies drop `nextCursor`, since
#     this server does not paginate (a cursor it never issued is refused,
#     test_mcp_lifecycle.mojo);
#   - the error examples give only the reply; the request is written here
#     with the example's id;
#   - the structured-content example gives only the reply, so its request
#     is written here with id 5;
#   - resources/templates/list answers an empty list rather than the
#     example's one template, since there is no template seam.
#   - initialize: the reply is checked member by member, and its
#     capabilities are {"tools": {}, "resources": {}} (what this server
#     serves) rather than the example's logging, prompts, resource
#     subscribe/listChanged, tools listChanged and tasks.

from std.testing import assert_equal, assert_true, assert_false

from komira_json import JsonValue, parse_json_value
from komira_mcp_server import (
    MCP_LATEST_PROTOCOL_VERSION,
    McpServer,
    Resource,
    ResourceContents,
    ResourceProvider,
    ServerInfo,
    Tool,
    ToolProvider,
    ToolResult,
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


def assert_same(got: JsonValue, expected: String, what: String) raises:
    var e = parse_json_value(expected)
    if not _same(got, e):
        raise Error(
            what + ": differs\n  got:      " + got.serialize()
            + "\n  expected: " + e.serialize()
        )


def assert_reply(got: Optional[String], expected: String, what: String) raises:
    assert_true(Bool(got), what + ": expected a reply, got none")
    assert_same(parse_json_value(got.value()), expected, what)


# The examples' tool and resource.
comptime WEATHER_TEXT = "Current weather in New York:\nTemperature: 72°F\nConditions: Partly cloudy"
comptime DEPARTURE_ERROR = "Invalid departure date: must be in the future. Current date is 08/08/2025."
comptime MAIN_RS = 'fn main() {\n    println!("Hello world!");\n}'


struct ExampleTools(ToolProvider):
    def __init__(out self):
        pass

    def advertises_tools(self) -> Bool:
        return True

    def list_tools(self) raises -> List[Tool]:
        var t = Tool(
            "get_weather",
            parse_json_value(
                '{"type": "object", "properties": {"location": {"type":'
                ' "string", "description": "City name or zip code"}},'
                ' "required": ["location"]}'
            ),
        )
        t.title = String("Weather Information Provider")
        t.description = String("Get current weather information for a location")
        t.extra = parse_json_value(
            '{"icons": [{"src": "https://example.com/weather-icon.png",'
            ' "mimeType": "image/png", "sizes": ["48x48"]}], "execution":'
            ' {"taskSupport": "optional"}}'
        )
        var tools = List[Tool]()
        tools.append(t^)
        return tools^

    def call_tool(
        mut self, name: String, arguments: JsonValue
    ) raises -> Optional[ToolResult]:
        if name == "get_weather":
            assert_equal(arguments.get("location").as_string(), "New York")
            var r = ToolResult.text(String(WEATHER_TEXT))
            r.is_error = False
            return r^
        if name == "get_weather_data":
            var r = ToolResult.text(
                '{"temperature": 22.5, "conditions": "Partly cloudy",'
                ' "humidity": 65}'
            )
            r.set_structured_content(
                parse_json_value(
                    '{"temperature": 22.5, "conditions": "Partly cloudy",'
                    ' "humidity": 65}'
                )
            )
            return r^
        if name == "book_flight":
            return ToolResult.error(String(DEPARTURE_ERROR))
        return None


struct ExampleResources(ResourceProvider):
    def __init__(out self):
        pass

    def advertises_resources(self) -> Bool:
        return True

    def list_resources(self) raises -> List[Resource]:
        var r = Resource("file:///project/src/main.rs", "main.rs")
        r.title = String("Rust Software Application Main File")
        r.description = String("Primary application entry point")
        r.mime_type = String("text/x-rust")
        r.extra = parse_json_value(
            '{"icons": [{"src": "https://example.com/rust-file-icon.png",'
            ' "mimeType": "image/png", "sizes": ["48x48"]}]}'
        )
        var out = List[Resource]()
        out.append(r^)
        return out^

    def read_resource(
        mut self, uri: String
    ) raises -> Optional[List[ResourceContents]]:
        if uri != "file:///project/src/main.rs":
            return None
        var out = List[ResourceContents]()
        out.append(
            ResourceContents.text(uri, String("text/x-rust"), String(MAIN_RS))
        )
        return out^


def _example_server() raises -> McpServer[ExampleTools, ExampleResources]:
    var info = ServerInfo("ExampleServer", "1.0.0")
    info.title = String("Example Server Display Name")
    info.description = String(
        "An example MCP server providing tools and resources"
    )
    info.website_url = String("https://example.com/server")
    info.extra = parse_json_value(
        '{"icons": [{"src": "https://example.com/server-icon.svg", "mimeType":'
        ' "image/svg+xml", "sizes": ["any"]}]}'
    )
    var s = McpServer(info^, ExampleTools(), ExampleResources())
    s.set_instructions("Optional instructions for the client")
    return s^


# Lifecycle: the initialize request, verbatim.
comptime INITIALIZE = """{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "initialize",
  "params": {
    "protocolVersion": "2025-11-25",
    "capabilities": {
      "roots": {
        "listChanged": true
      },
      "sampling": {},
      "elicitation": {
        "form": {},
        "url": {}
      },
      "tasks": {
        "requests": {
          "elicitation": {
            "create": {}
          },
          "sampling": {
            "createMessage": {}
          }
        }
      }
    },
    "clientInfo": {
      "name": "ExampleClient",
      "title": "Example Client Display Name",
      "version": "1.0.0",
      "description": "An example MCP client application",
      "icons": [
        {
          "src": "https://example.com/icon.png",
          "mimeType": "image/png",
          "sizes": ["48x48"]
        }
      ],
      "websiteUrl": "https://example.com"
    }
  }
}"""


def _initialized_server() raises -> McpServer[ExampleTools, ExampleResources]:
    var s = _example_server()
    assert_true(Bool(s.handle(INITIALIZE)), "initialize answered")
    assert_false(
        Bool(s.handle('{"jsonrpc": "2.0", "method": "notifications/initialized"}')),
        "initialized notification answered",
    )
    return s^


def test_lifecycle_initialize() raises:
    var s = _example_server()
    var got = s.handle(INITIALIZE)
    assert_true(Bool(got), "initialize: no reply")
    var reply = parse_json_value(got.value())
    assert_equal(reply.get("jsonrpc").as_string(), "2.0")
    assert_equal(reply.get("id").serialize(), "1")
    var result = reply.get("result")
    # The client asked for the revision this server speaks: the same comes
    # back ("If the server supports the requested protocol version, it MUST
    # respond with the same version").
    assert_equal(
        result.get("protocolVersion").as_string(), MCP_LATEST_PROTOCOL_VERSION
    )
    # The example's serverInfo and instructions, exactly.
    assert_same(
        result.get("serverInfo"),
        """{
      "name": "ExampleServer",
      "title": "Example Server Display Name",
      "version": "1.0.0",
      "description": "An example MCP server providing tools and resources",
      "icons": [
        {
          "src": "https://example.com/server-icon.svg",
          "mimeType": "image/svg+xml",
          "sizes": ["any"]
        }
      ],
      "websiteUrl": "https://example.com/server"
    }""",
        "serverInfo",
    )
    assert_equal(
        result.get("instructions").as_string(),
        "Optional instructions for the client",
    )
    # Capabilities: the example server also offers logging, prompts, tasks
    # and notifications; this one declares exactly what it serves.
    assert_same(
        result.get("capabilities"), '{"tools": {}, "resources": {}}', "capabilities"
    )
    assert_equal(result.num_members(), 4)
    assert_true(s.is_initialized())
    assert_false(s.client_ready())
    # The initialized notification, verbatim: no reply, and recorded.
    assert_false(
        Bool(s.handle('{\n  "jsonrpc": "2.0",\n  "method": "notifications/initialized"\n}')),
        "initialized notification answered",
    )
    assert_true(s.client_ready())
    assert_equal(s.protocol_version(), MCP_LATEST_PROTOCOL_VERSION)
    print("  test_lifecycle_initialize: PASS")


def test_ping() raises:
    # Ping is served before initialize too.
    var s = _example_server()
    assert_reply(
        s.handle('{\n  "jsonrpc": "2.0",\n  "id": "123",\n  "method": "ping"\n}'),
        '{\n  "jsonrpc": "2.0",\n  "id": "123",\n  "result": {}\n}',
        "ping",
    )
    print("  test_ping: PASS")


def test_tools_list() raises:
    var s = _initialized_server()
    # Request without "cursor"; reply without "nextCursor".
    assert_reply(
        s.handle('{"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {}}'),
        """{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "tools": [
      {
        "name": "get_weather",
        "title": "Weather Information Provider",
        "description": "Get current weather information for a location",
        "inputSchema": {
          "type": "object",
          "properties": {
            "location": {
              "type": "string",
              "description": "City name or zip code"
            }
          },
          "required": ["location"]
        },
        "icons": [
          {
            "src": "https://example.com/weather-icon.png",
            "mimeType": "image/png",
            "sizes": ["48x48"]
          }
        ],
        "execution": {
          "taskSupport": "optional"
        }
      }
    ]
  }
}""",
        "tools/list",
    )
    print("  test_tools_list: PASS")


def test_tools_call() raises:
    var s = _initialized_server()
    assert_reply(
        s.handle(
            """{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "tools/call",
  "params": {
    "name": "get_weather",
    "arguments": {
      "location": "New York"
    }
  }
}"""
        ),
        """{
  "jsonrpc": "2.0",
  "id": 2,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "Current weather in New York:\\nTemperature: 72°F\\nConditions: Partly cloudy"
      }
    ],
    "isError": false
  }
}""",
        "tools/call",
    )
    print("  test_tools_call: PASS")


def test_tools_call_structured_content() raises:
    # The specification gives only the reply; the request is written here
    # with the reply's id.
    var s = _initialized_server()
    assert_reply(
        s.handle(
            '{"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params":'
            ' {"name": "get_weather_data", "arguments": {"location": "New'
            ' York"}}}'
        ),
        """{
  "jsonrpc": "2.0",
  "id": 5,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "{\\"temperature\\": 22.5, \\"conditions\\": \\"Partly cloudy\\", \\"humidity\\": 65}"
      }
    ],
    "structuredContent": {
      "temperature": 22.5,
      "conditions": "Partly cloudy",
      "humidity": 65
    }
  }
}""",
        "structured content",
    )
    print("  test_tools_call_structured_content: PASS")


def test_tools_protocol_error_unknown_tool() raises:
    var s = _initialized_server()
    assert_reply(
        s.handle(
            '{"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params":'
            ' {"name": "invalid_tool_name", "arguments": {}}}'
        ),
        """{
  "jsonrpc": "2.0",
  "id": 3,
  "error": {
    "code": -32602,
    "message": "Unknown tool: invalid_tool_name"
  }
}""",
        "unknown tool",
    )
    print("  test_tools_protocol_error_unknown_tool: PASS")


def test_tools_execution_error() raises:
    var s = _initialized_server()
    assert_reply(
        s.handle(
            '{"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params":'
            ' {"name": "book_flight", "arguments": {}}}'
        ),
        """{
  "jsonrpc": "2.0",
  "id": 4,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "Invalid departure date: must be in the future. Current date is 08/08/2025."
      }
    ],
    "isError": true
  }
}""",
        "tool execution error",
    )
    print("  test_tools_execution_error: PASS")


def test_resources_list() raises:
    var s = _initialized_server()
    # Request without "cursor"; reply without "nextCursor".
    assert_reply(
        s.handle('{"jsonrpc": "2.0", "id": 1, "method": "resources/list", "params": {}}'),
        """{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "resources": [
      {
        "uri": "file:///project/src/main.rs",
        "name": "main.rs",
        "title": "Rust Software Application Main File",
        "description": "Primary application entry point",
        "mimeType": "text/x-rust",
        "icons": [
          {
            "src": "https://example.com/rust-file-icon.png",
            "mimeType": "image/png",
            "sizes": ["48x48"]
          }
        ]
      }
    ]
  }
}""",
        "resources/list",
    )
    print("  test_resources_list: PASS")


def test_resources_read() raises:
    var s = _initialized_server()
    assert_reply(
        s.handle(
            """{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "resources/read",
  "params": {
    "uri": "file:///project/src/main.rs"
  }
}"""
        ),
        """{
  "jsonrpc": "2.0",
  "id": 2,
  "result": {
    "contents": [
      {
        "uri": "file:///project/src/main.rs",
        "mimeType": "text/x-rust",
        "text": "fn main() {\\n    println!(\\"Hello world!\\");\\n}"
      }
    ]
  }
}""",
        "resources/read",
    )
    print("  test_resources_read: PASS")


def test_resource_templates_list_is_empty() raises:
    # The request is verbatim; this server has no templates, so the list is
    # empty rather than the example's one template.
    var s = _initialized_server()
    assert_reply(
        s.handle(
            '{\n  "jsonrpc": "2.0",\n  "id": 3,\n  "method":'
            ' "resources/templates/list"\n}'
        ),
        '{"jsonrpc": "2.0", "id": 3, "result": {"resourceTemplates": []}}',
        "resources/templates/list",
    )
    print("  test_resource_templates_list_is_empty: PASS")


def test_resource_not_found() raises:
    var s = _initialized_server()
    assert_reply(
        s.handle(
            '{"jsonrpc": "2.0", "id": 5, "method": "resources/read", "params":'
            ' {"uri": "file:///nonexistent.txt"}}'
        ),
        """{
  "jsonrpc": "2.0",
  "id": 5,
  "error": {
    "code": -32002,
    "message": "Resource not found",
    "data": {
      "uri": "file:///nonexistent.txt"
    }
  }
}""",
        "resource not found",
    )
    print("  test_resource_not_found: PASS")


def main() raises:
    print("test_mcp_spec_examples")
    test_lifecycle_initialize()
    test_ping()
    test_tools_list()
    test_tools_call()
    test_tools_call_structured_content()
    test_tools_protocol_error_unknown_tool()
    test_tools_execution_error()
    test_resources_list()
    test_resources_read()
    test_resource_templates_list_is_empty()
    test_resource_not_found()
    print("test_mcp_spec_examples: ALL PASS")
