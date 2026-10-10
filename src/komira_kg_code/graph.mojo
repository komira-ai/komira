"""The code graph: nodes, edges, their canonical order, and their Arrow
record batches.

A node is a build target, a source file, a Markdown document or a declared
symbol. An edge is a directed, typed relation between two nodes. A
`CodeGraph` holds each node once (by id) and each edge once (by source,
kind and destination), nodes sorted by id and edges by (source, kind,
destination), comparing bytes. As the deriver keeps every edge and refuses
an input added again with other content or a node another input would
replace, the same inputs give the same graph in the same order, whatever
order they were added in.
"""

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion

# Node kinds.
comptime NODE_TARGET = "target"
"""A build target (a library, a binary or a test)."""
comptime NODE_FILE = "file"
"""A source file a target lists."""
comptime NODE_DOC = "doc"
"""A Markdown document."""
comptime NODE_STRUCT = "struct"
comptime NODE_TRAIT = "trait"
comptime NODE_FUNCTION = "function"
"""A module-level function (its overloads are one node)."""
comptime NODE_METHOD = "method"
"""A function of a struct or trait (its overloads are one node)."""
comptime NODE_ALIAS = "alias"
"""A module-level `comptime` declaration."""

# Edge kinds.
comptime EDGE_DEPS = "deps"
"""target -> target it lists in `deps`."""
comptime EDGE_SRCS = "srcs"
"""target -> file it lists in `srcs`."""
comptime EDGE_TESTS = "tests"
"""library -> its welded test file (`test_srcs`), and library -> a test
target that lists it in `deps`."""
comptime EDGE_IMPORTS = "imports"
"""file -> library target whose package the file imports."""
comptime EDGE_DECLARES = "declares"
"""file -> symbol declared in it; struct or trait -> its method."""
comptime EDGE_CONFORMS = "conforms"
"""struct or trait -> trait it conforms to or refines."""
comptime EDGE_GOVERNS = "governs"
"""doc -> target or file its front matter names under `governs:`."""


@fieldwise_init
struct KgNode(Copyable, Movable):
    """One node.

    `id` is unique in a graph: a target's label, a file's label
    (`cell//path`), a document's path, or a symbol's dotted path from its
    package (`pkg.module.Name`, `pkg.module.Struct.method`). `path` is the
    file the node lives in, relative to its cell (a target's package
    directory). `line` is 1-based, 0 when unknown. `text` is what full-text
    search reads: a symbol's signature and summary, a target's rule kind and
    name, a document's title.
    """

    var id: String
    var kind: String
    var label: String
    var path: String
    var line: Int
    var text: String


@fieldwise_init
struct KgEdge(Copyable, Movable):
    """One directed edge `src -[kind]-> dst` between two node ids."""

    var src: String
    var kind: String
    var dst: String


def bytes_less(a: String, b: String) -> Bool:
    """Whether `a` sorts before `b`, comparing bytes (a prefix sorts
    first)."""
    var x = a.as_bytes()
    var y = b.as_bytes()
    var n = min(len(x), len(y))
    for i in range(n):
        if x[i] != y[i]:
            return x[i] < y[i]
    return len(x) < len(y)


def sorted_order(keys: List[String]) -> List[Int]:
    """The indices of `keys` in byte order of the keys; equal keys keep
    their order (a stable merge sort)."""
    var n = len(keys)
    var idx = List[Int](capacity=n)
    for i in range(n):
        idx.append(i)
    var tmp = List[Int](length=n, fill=0)
    var width = 1
    while width < n:
        var lo = 0
        while lo < n:
            var mid = min(lo + width, n)
            var hi = min(lo + 2 * width, n)
            var i = lo
            var j = mid
            var k = lo
            while i < mid and j < hi:
                if bytes_less(keys[idx[j]], keys[idx[i]]):
                    tmp[k] = idx[j]
                    j += 1
                else:
                    tmp[k] = idx[i]
                    i += 1
                k += 1
            while i < mid:
                tmp[k] = idx[i]
                i += 1
                k += 1
            while j < hi:
                tmp[k] = idx[j]
                j += 1
                k += 1
            lo += 2 * width
        for t in range(n):
            idx[t] = tmp[t]
        width *= 2
    return idx^


def _escape(s: String) -> String:
    """`s` with backslash, tab and newline written as `\\\\`, `\\t` and
    `\\n`, so one value stays on one line of `CodeGraph.dump`."""
    var out = String("")
    var b = s.as_bytes()
    var seg = 0
    for i in range(len(b)):
        var c = b[i]
        if c == UInt8(ord("\\")) or c == UInt8(ord("\t")) or c == UInt8(ord("\n")):
            out += String(s[byte=seg:i])
            if c == UInt8(ord("\\")):
                out += "\\\\"
            elif c == UInt8(ord("\t")):
                out += "\\t"
            else:
                out += "\\n"
            seg = i + 1
    out += String(s[byte=seg : len(b)])
    return out^


def node_schema() raises -> Schema:
    """The schema of `CodeGraph.node_batch`: `id`, `kind`, `label`, `path`,
    `text` (strings) and `line` (int64), none nullable."""
    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.STRING, False))
    sb.add_field(Field("kind", ArrowType.STRING, False))
    sb.add_field(Field("label", ArrowType.STRING, False))
    sb.add_field(Field("path", ArrowType.STRING, False))
    sb.add_field(Field("line", DType.int64, False))
    sb.add_field(Field("text", ArrowType.STRING, False))
    return sb.build()


def edge_schema() raises -> Schema:
    """The schema of `CodeGraph.edge_batch`: `src`, `kind`, `dst`, all
    strings, none nullable."""
    var sb = SchemaBuilder()
    sb.add_field(Field("src", ArrowType.STRING, False))
    sb.add_field(Field("kind", ArrowType.STRING, False))
    sb.add_field(Field("dst", ArrowType.STRING, False))
    return sb.build()


def _str_col(values: List[String]) raises -> Column[HeapRegion]:
    return Column.from_string(StringArray.from_strings(values))


struct CodeGraph(Movable):
    """A derived code graph, in canonical order (see the module header)."""

    var nodes: List[KgNode]
    var edges: List[KgEdge]

    def __init__(out self, var nodes: List[KgNode], var edges: List[KgEdge]):
        """Takes nodes with distinct ids and edges with distinct
        (src, kind, dst) and puts both in canonical order."""
        var nkeys = List[String](capacity=len(nodes))
        for i in range(len(nodes)):
            nkeys.append(nodes[i].id)
        var norder = sorted_order(nkeys)
        self.nodes = List[KgNode](capacity=len(nodes))
        for i in range(len(norder)):
            self.nodes.append(nodes[norder[i]].copy())
        var ekeys = List[String](capacity=len(edges))
        for i in range(len(edges)):
            ekeys.append(edges[i].src + "\x00" + edges[i].kind + "\x00" + edges[i].dst)
        var eorder = sorted_order(ekeys)
        self.edges = List[KgEdge](capacity=len(edges))
        for i in range(len(eorder)):
            self.edges.append(edges[eorder[i]].copy())

    def node_index(self, id: String) -> Int:
        """The index of the node `id`, or -1 (a binary search)."""
        var lo = 0
        var hi = len(self.nodes)
        while lo < hi:
            var mid = (lo + hi) // 2
            if bytes_less(self.nodes[mid].id, id):
                lo = mid + 1
            else:
                hi = mid
        if lo < len(self.nodes) and self.nodes[lo].id == id:
            return lo
        return -1

    def has_edge(self, src: String, kind: String, dst: String) -> Bool:
        """Whether the edge `src -[kind]-> dst` is in the graph."""
        for i in range(len(self.edges)):
            ref e = self.edges[i]
            if e.src == src and e.kind == kind and e.dst == dst:
                return True
        return False

    def sources_of(self, kind: String, dst: String) -> List[String]:
        """The sources of the `kind` edges into `dst`, in order."""
        var out = List[String]()
        for i in range(len(self.edges)):
            ref e = self.edges[i]
            if e.kind == kind and e.dst == dst:
                out.append(e.src)
        return out^

    def targets_of(self, src: String, kind: String) -> List[String]:
        """The destinations of the `kind` edges out of `src`, in order."""
        var out = List[String]()
        for i in range(len(self.edges)):
            ref e = self.edges[i]
            if e.kind == kind and e.src == src:
                out.append(e.dst)
        return out^

    def dump(self) -> String:
        """The graph as text, one line per node then one per edge:
        `N<TAB>id<TAB>kind<TAB>label<TAB>path<TAB>line<TAB>text` and
        `E<TAB>src<TAB>kind<TAB>dst`, each value escaped (`\\\\`, `\\t`,
        `\\n`), each line ending in a newline. The goldens are this text."""
        var out = String("")
        for i in range(len(self.nodes)):
            ref n = self.nodes[i]
            out += "N\t" + _escape(n.id) + "\t" + _escape(n.kind) + "\t"
            out += _escape(n.label) + "\t" + _escape(n.path) + "\t"
            out += String(n.line) + "\t" + _escape(n.text) + "\n"
        for i in range(len(self.edges)):
            ref e = self.edges[i]
            out += "E\t" + _escape(e.src) + "\t" + _escape(e.kind) + "\t"
            out += _escape(e.dst) + "\n"
        return out^

    def node_batch(self) raises -> RecordBatch:
        """The nodes as one record batch of `node_schema()`, in order."""
        var ids = List[String](capacity=len(self.nodes))
        var kinds = List[String](capacity=len(self.nodes))
        var labels = List[String](capacity=len(self.nodes))
        var paths = List[String](capacity=len(self.nodes))
        var lines = List[Int64](capacity=len(self.nodes))
        var texts = List[String](capacity=len(self.nodes))
        for i in range(len(self.nodes)):
            ref n = self.nodes[i]
            ids.append(n.id)
            kinds.append(n.kind)
            labels.append(n.label)
            paths.append(n.path)
            lines.append(Int64(n.line))
            texts.append(n.text)
        var rb = RecordBatchBuilder.with_capacity(6)
        rb.add_column(_str_col(ids))
        rb.add_column(_str_col(kinds))
        rb.add_column(_str_col(labels))
        rb.add_column(_str_col(paths))
        rb.add_column(Column.from_primitive(PrimitiveArray[DType.int64].from_list(lines)))
        rb.add_column(_str_col(texts))
        return rb.build(node_schema())

    def edge_batch(self) raises -> RecordBatch:
        """The edges as one record batch of `edge_schema()`, in order."""
        var srcs = List[String](capacity=len(self.edges))
        var kinds = List[String](capacity=len(self.edges))
        var dsts = List[String](capacity=len(self.edges))
        for i in range(len(self.edges)):
            ref e = self.edges[i]
            srcs.append(e.src)
            kinds.append(e.kind)
            dsts.append(e.dst)
        var rb = RecordBatchBuilder.with_capacity(3)
        rb.add_column(_str_col(srcs))
        rb.add_column(_str_col(kinds))
        rb.add_column(_str_col(dsts))
        return rb.build(edge_schema())
