# The deriver over a real library, komira_mcp_server: its `mojo doc` JSON as
# the build makes it (the mcp_server_doc target) and its sources as the
# build stages them (the library's [src] sub-target, staged whole at
# mcp_src/). The uquery JSON is written here from the staged file list, so
# nothing in this test lists the library's files: a module added to it is
# read the next time this test runs.
#
# The checks are facts each read without the deriver: the two provider
# traits and the one struct conforming to each (provider.mojo), the line a
# declaration's node gives holds that declaration's header in the source
# (a dunder method the JSON lists from a parent trait has no header and no
# line), and a file imports komira_json exactly when one of its lines
# starts with `from komira_json`.
from std.os import listdir
from std.testing import assert_equal, assert_true

from komira_kg_code import (
    CodeGraph,
    CodeGraphBuilder,
    EDGE_CONFORMS,
    EDGE_DECLARES,
    EDGE_IMPORTS,
    NODE_ALIAS,
    NODE_FUNCTION,
    NODE_METHOD,
    NODE_STRUCT,
    NODE_TRAIT,
)
from komira_kg_code.text_scan import split_lines

comptime _LABEL = "komira//src/komira_mcp_server:komira_mcp_server"
comptime _JSON_LABEL = "komira//src/komira_json:komira_json"
comptime _FILE = "komira//src/komira_mcp_server/"
comptime _STAGED = "mcp_src/"


def _read(path: String) raises -> String:
    with open(path, "r") as f:
        return f.read()


def _files() raises -> List[String]:
    """The staged source files: a flat package, so no subdirectory.
    Refuses a staging without the modules this test names."""
    var names = listdir(String(_STAGED))
    var out = List[String]()
    for i in range(len(names)):
        if names[i].endswith(".mojo"):
            out.append(names[i])
    var has_provider = False
    for i in range(len(out)):
        if out[i] == "provider.mojo":
            has_provider = True
    assert_true(len(out) >= 5 and has_provider, "mcp_src/ is not komira_mcp_server's sources")
    return out^


def _uquery(files: List[String]) -> String:
    var srcs = String("")
    for i in range(len(files)):
        if i > 0:
            srcs += ", "
        srcs += '"' + String(_FILE) + files[i] + '"'
    return (
        '{"'
        + String(_LABEL)
        + '": {"buck.type": "mojo_library_rule", "deps": ["komira//src/komira_encoding:komira_encoding", "'
        + String(_JSON_LABEL)
        + '"], "import_name": null, "srcs": ['
        + srcs
        + '], "test_srcs": []}}'
    )


def _derive() raises -> CodeGraph:
    var files = _files()
    var b = CodeGraphBuilder()
    b.add_uquery_json(_uquery(files))
    b.add_mojo_doc_json(String(_LABEL), _read("mcp_server_doc.json"))
    for i in range(len(files)):
        b.add_source(String(_FILE) + files[i], _read(String(_STAGED) + files[i]))
    return b.build()


def test_the_provider_traits_and_their_conformers() raises:
    var g = _derive()
    var t = g.node_index("komira_mcp_server.provider.ToolProvider")
    var r = g.node_index("komira_mcp_server.provider.ResourceProvider")
    assert_true(t >= 0 and r >= 0, "a provider trait is missing")
    assert_equal(g.nodes[t].kind, NODE_TRAIT)
    assert_equal(g.nodes[r].kind, NODE_TRAIT)
    var tc = g.sources_of(EDGE_CONFORMS, "komira_mcp_server.provider.ToolProvider")
    assert_equal(len(tc), 1)
    assert_equal(tc[0], "komira_mcp_server.provider.NoTools")
    var rc = g.sources_of(EDGE_CONFORMS, "komira_mcp_server.provider.ResourceProvider")
    assert_equal(len(rc), 1)
    assert_equal(rc[0], "komira_mcp_server.provider.NoResources")
    var methods = g.targets_of("komira_mcp_server.provider.ToolProvider", EDGE_DECLARES)
    assert_true(len(methods) >= 3, "ToolProvider declares fewer than three methods")


def test_every_declaration_line_holds_its_header() raises:
    var g = _derive()
    var checked = 0
    var inherited = 0
    for i in range(len(g.nodes)):
        ref n = g.nodes[i]
        var keyword = String("")
        var indent = String("")
        if n.kind == NODE_STRUCT or n.kind == NODE_TRAIT:
            keyword = n.kind
        elif n.kind == NODE_FUNCTION:
            keyword = "def"
        elif n.kind == NODE_ALIAS:
            keyword = "comptime"
        elif n.kind == NODE_METHOD:
            keyword = "def"
            indent = "    "
        else:
            continue
        if n.line == 0 and n.kind == NODE_METHOD and n.label.startswith("__") and n.label.endswith("__"):
            # A lifecycle method the JSON lists from a parent trait
            # (`__init__` of Movable on ToolProvider) has no header here.
            inherited += 1
            continue
        assert_true(n.line > 0, n.id + " has no line")
        var file = n.path[byte = String("src/komira_mcp_server/").byte_length() : n.path.byte_length()]
        var lines = split_lines(_read(String(_STAGED) + String(file)))
        var head = indent + keyword + " " + n.label
        assert_true(lines[n.line - 1].startswith(head), n.id + ": line " + String(n.line) + " is `" + lines[n.line - 1] + "`")
        checked += 1
    assert_true(checked >= 20, "fewer than 20 declarations were checked")


def test_imports_of_komira_json_match_the_import_lines() raises:
    var g = _derive()
    var files = _files()
    var importers = g.sources_of(EDGE_IMPORTS, _JSON_LABEL)
    var expected = 0
    for i in range(len(files)):
        var lines = split_lines(_read(String(_STAGED) + files[i]))
        var imports = False
        for l in range(len(lines)):
            if lines[l].startswith("from komira_json"):
                imports = True
        var edge = False
        for k in range(len(importers)):
            if importers[k] == String(_FILE) + files[i]:
                edge = True
        assert_equal(edge, imports, files[i])
        if imports:
            expected += 1
    assert_true(expected > 0, "no source of komira_mcp_server imports komira_json")
    assert_equal(len(importers), expected)


def test_derivation_is_deterministic() raises:
    assert_equal(_derive().dump(), _derive().dump())


def main() raises:
    test_the_provider_traits_and_their_conformers()
    test_every_declaration_line_holds_its_header()
    test_imports_of_komira_json_match_the_import_lines()
    test_derivation_is_deterministic()
    print("OK")
