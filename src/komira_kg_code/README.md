# komira_kg_code

The code graph deriver: what the build already knows about Mojo code, as
graph nodes and edges.

`CodeGraphBuilder` takes four inputs, in any order, and `build()` returns
a `CodeGraph`:

- `add_uquery_json(text)`: the output of `buck2 uquery <targets> --json
  --output-attribute '^(buck\.type|deps|srcs|test_srcs|import_name)$'`. Each
  `mojo_library_rule`, `mojo_binary_rule` and `mojo_test_rule` is a `target`
  node, each `srcs` and `test_srcs` entry a `file` node, with `deps`, `srcs`
  and `tests` edges. A test target is a `tests` edge from each library it
  depends on, so a library's tests are its welded tests and its standalone
  test targets together.
- `add_mojo_doc_json(label, text)`: a library's `mojo doc` JSON, as the
  [`mojo_doc_json`](../../tools/build/mojo/doc.md) rule makes it. Each
  struct, trait, module-level function, `comptime` and method is a node
  (overloads are one), with `declares` edges from its file (or its struct)
  and `conforms` edges to the traits of the graph it conforms to.
- `add_source(file_id, text)`: a listed Mojo source. Its import lines give
  `imports` edges to the libraries it imports, and it gives each
  declaration in it its line (the JSON has none).
- `add_markdown(path, text)`: a document, a `doc` node with `governs`
  edges to the targets and files its front matter lists.

The graph holds each node once and each edge once, nodes sorted by id and
edges by source, kind and destination, so equal inputs give equal bytes.
An input added twice counts once. An input added again with other content
is refused: a document, a source or a label's doc JSON with other text
(byte for byte), a target with another rule (any `buck.type`, also one
the deriver reads nothing from), `srcs`, `test_srcs`, `deps`
or import name. So is a symbol two libraries declare in two files. Every
edge any input gives is kept, so the order of adding never decides.
`dump()` writes it as text, one line per node and edge; `node_batch()` and
`edge_batch()` give it as Arrow record batches (`node_schema()`,
`edge_schema()`). An input the deriver cannot place raises an error that
names it, for example `komira_kg_code: source c//p/z.mojo is in no
target's srcs or test_srcs`.

The line scans are public too: `imported_modules(text)`,
`declaration_line(lines, keyword, name, indent, after)` and
`read_front_matter(path, text)`, which returns a `FrontMatter`.

```mojo
from komira_kg_code import CodeGraphBuilder, FrontMatter, KgEdge, KgNode
from komira_kg_code import EDGE_CONFORMS, EDGE_DECLARES, EDGE_DEPS, EDGE_GOVERNS
from komira_kg_code import EDGE_IMPORTS, EDGE_SRCS, EDGE_TESTS
from komira_kg_code import NODE_ALIAS, NODE_DOC, NODE_FILE, NODE_FUNCTION
from komira_kg_code import NODE_METHOD, NODE_STRUCT, NODE_TARGET, NODE_TRAIT
from komira_kg_code import declaration_line, imported_modules, read_front_matter
from komira_kg_code import edge_schema, node_schema
from std.testing import assert_equal, assert_true

var b = CodeGraphBuilder()
b.add_uquery_json(
    '{"c//p:app": {"buck.type": "mojo_binary_rule", "deps": ["c//q:lib"], "srcs": ["c//p/main.mojo"]}}'
)
b.add_source("c//p/main.mojo", "from lib.util import helper\n")
b.add_markdown("docs/app.md", "---\ntitle: App\ngoverns: [//p:app]\n---\n")
var g = b.build()
assert_true(g.has_edge("c//p/main.mojo", EDGE_IMPORTS, "c//q:lib"))
assert_true(g.has_edge("c//p:app", EDGE_DEPS, "c//q:lib"))
assert_true(g.has_edge("c//p:app", EDGE_SRCS, "c//p/main.mojo"))
assert_equal(g.targets_of("docs/app.md", EDGE_GOVERNS)[0], "c//p:app")
assert_equal(g.sources_of(EDGE_GOVERNS, "c//p:app")[0], "docs/app.md")
var node: KgNode = g.nodes[g.node_index("c//p/main.mojo")].copy()
assert_equal(node.kind, NODE_FILE)
assert_equal(g.nodes[g.node_index("c//q:lib")].kind, NODE_TARGET)
assert_equal(g.nodes[g.node_index("docs/app.md")].kind, NODE_DOC)
var first: KgEdge = g.edges[0].copy()
assert_equal(first.kind, EDGE_IMPORTS)
assert_equal(g.node_batch().num_rows(), len(g.nodes))
assert_equal(g.edge_batch().num_rows(), len(g.edges))
assert_equal(node_schema().num_columns(), 6)
assert_equal(edge_schema().num_columns(), 3)
assert_true(g.dump().startswith("N\tc//p/main.mojo\tfile\tmain.mojo\tp/main.mojo\t0\t\n"))

# The kinds a library's doc JSON and tests add.
var kinds = [NODE_STRUCT, NODE_TRAIT, NODE_FUNCTION, NODE_METHOD, NODE_ALIAS]
assert_equal(len(kinds), 5)
assert_equal(EDGE_DECLARES + " " + EDGE_CONFORMS + " " + EDGE_TESTS, "declares conforms tests")

assert_equal(imported_modules("import a.b as c\n")[0], "a.b")
assert_equal(declaration_line(["def f():", "    pass"], "def", "f", 0, 0), 1)
var fm: FrontMatter = read_front_matter("d.md", "---\ngoverns: [x]\n---\n")
assert_equal(fm.governs[0], "x")

# A library's declarations come from its `mojo doc` JSON.
var lb = CodeGraphBuilder()
lb.add_uquery_json('{"c//q:lib": {"buck.type": "mojo_library_rule", "srcs": ["c//q/lib/__init__.mojo"]}}')
lb.add_mojo_doc_json(
    "c//q:lib",
    '{"decl": {"kind": "package", "name": "lib", "packages": [], "modules": [{"kind": "module", "name": "__init__",'
    + ' "functions": [{"kind": "function", "name": "helper", "overloads": [{"signature": "def helper()", "summary": "Helps."}]}]}]}}',
)
var lg = lb.build()
assert_equal(lg.nodes[lg.node_index("lib.helper")].text, "def helper()\nHelps.")
assert_true(lg.has_edge("c//q/lib/__init__.mojo", EDGE_DECLARES, "lib.helper"))
```
