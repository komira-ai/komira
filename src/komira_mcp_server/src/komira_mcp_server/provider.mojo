# =============================================================================
# komira_mcp_server/provider.mojo: the seams a server's tools and resources
# plug into.
# =============================================================================
#
# `McpServer[T, R]` is generic over one `ToolProvider` and one
# `ResourceProvider`, resolved at compile time. A provider owns whatever
# state it needs by value and dispatches by name or URI at run time.
# `NoTools` and `NoResources` are the providers of a server that offers
# none: the server then advertises no such capability and answers that
# capability's methods with Method not found.
#
# The error contract (the "Error Handling" sections of "Tools" and
# "Resources"):
#   - `call_tool` returns None for a tool name it does not know: the server
#     answers with the protocol error Invalid params, "Unknown tool: <name>".
#     A tool's own failure is a `ToolResult` with `isError: true`, which the
#     tool may return itself; a raise out of `call_tool` becomes one too,
#     carrying the error text.
#   - `read_resource` returns None for a URI it does not know: the server
#     answers with Resource not found (-32002) and the URI in `data`. A
#     raise becomes Internal error (-32603), with no detail sent to the
#     client.
# =============================================================================

from komira_json import JsonValue

from .protocol import Tool, ToolResult, Resource, ResourceContents


trait ToolProvider(Movable, Deinitable):
    """The tools a server offers."""

    def advertises_tools(self) -> Bool:
        """Whether the server declares the `tools` capability."""
        ...

    def list_tools(self) raises -> List[Tool]:
        """Every tool, in the order `tools/list` returns them."""
        ...

    def call_tool(
        mut self, name: String, arguments: JsonValue
    ) raises -> Optional[ToolResult]:
        """Run tool `name` with `arguments` (an object; `{}` when the
        request had none). None means no tool has that name."""
        ...


trait ResourceProvider(Movable, Deinitable):
    """The resources a server offers."""

    def advertises_resources(self) -> Bool:
        """Whether the server declares the `resources` capability."""
        ...

    def list_resources(self) raises -> List[Resource]:
        """Every resource, in the order `resources/list` returns them."""
        ...

    def read_resource(
        mut self, uri: String
    ) raises -> Optional[List[ResourceContents]]:
        """The contents of `uri`. None means no resource has that URI."""
        ...


struct NoTools(ToolProvider):
    """A server with no tools."""

    def __init__(out self):
        pass

    def advertises_tools(self) -> Bool:
        return False

    def list_tools(self) raises -> List[Tool]:
        return List[Tool]()

    def call_tool(
        mut self, name: String, arguments: JsonValue
    ) raises -> Optional[ToolResult]:
        return None


struct NoResources(ResourceProvider):
    """A server with no resources."""

    def __init__(out self):
        pass

    def advertises_resources(self) -> Bool:
        return False

    def list_resources(self) raises -> List[Resource]:
        return List[Resource]()

    def read_resource(
        mut self, uri: String
    ) raises -> Optional[List[ResourceContents]]:
        return None
