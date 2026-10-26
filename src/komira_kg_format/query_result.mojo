# =============================================================================
# query_result -- the structured result of a graph query, and its JSON wire.
# =============================================================================
#
# A query result is a subgraph plus the analysis layered over it:
#   * nodes       -- id / label / type / score          (the rendered vertices)
#   * edges       -- src / dst / predicate / valid_at / doc_id  (the arcs)
#   * findings    -- locus / severity / kind / rationale  (the analysis overlay)
#   * provenance  -- doc_id -> source                    (where a fact came from)
#   * loci        -- doc_id + section + offset           (jump-link anchors)
#   * scores      -- named relevance scores              (the ranking)
#
# Both query modes return this one type: an analysis query is findings-heavy
# with a small focus subgraph; a retain-and-query lookup is subgraph-heavy with
# few or no findings. `mode` records which produced it and is descriptive only.
# `answer` carries a natural-language answer synthesized from the retrieved
# subgraph; it is "" when no synthesis ran.
#
# The value types own their heap (`String`, `List`) and are built, returned and
# consumed as ordinary values. No pointer appears in any signature.
#
# WIRE: `serialize` writes one self-describing JSON object, `deserialize` reads
# it back, and serialize -> deserialize -> serialize is byte-stable.
#   * `v` is the format version (`KG_QUERY_RESULT_FORMAT_VERSION`). A reader
#     refuses a version above its own and a version below 1; a missing `v` is
#     read as version 1.
#   * Strings are escaped byte by byte, so multi-byte UTF-8 passes through
#     unchanged. `"`, `\`, newline, return and tab use their short escapes and
#     every other control character below 0x20 is written `\u00XX`, because the
#     reader refuses a raw control character.
#   * Numbers ride as JSON numbers; a Float64 is written in its shortest
#     round-trip form. JSON has no NaN or infinity, so a non-finite score or
#     value is written as 0.0.
#   * A missing sub-collection key reads as an empty list, and a missing
#     `answer` as "". `provenance` keeps the first entry for each `doc_id`.
# =============================================================================

from std.math import isfinite

from .json_value import JsonDoc


# Severity tags for `ResultFinding.severity`, least to most severe.
comptime SEV_INFO: Int = 0
comptime SEV_WARN: Int = 1
comptime SEV_ERROR: Int = 2

# The wire format version `serialize` stamps and `deserialize` accepts up to.
# Version 1 is the JSON object described above.
comptime KG_QUERY_RESULT_FORMAT_VERSION: Int = 1



def _json_str(s: String) -> String:
    """Quote `s` as a JSON string, escaping at the byte level.

    The bytes of a multi-byte UTF-8 character are all at or above 0x80 and pass
    through unchanged.
    """
    var buf = List[UInt8]()
    buf.append(UInt8(0x22))
    var src = s.as_bytes()
    var hex_digits = String("0123456789abcdef")
    var hex = hex_digits.as_bytes()
    for i in range(len(src)):
        var b = src[i]
        if b == UInt8(0x22):
            buf.append(UInt8(0x5C))
            buf.append(UInt8(0x22))
        elif b == UInt8(0x5C):
            buf.append(UInt8(0x5C))
            buf.append(UInt8(0x5C))
        elif b == UInt8(0x0A):
            buf.append(UInt8(0x5C))
            buf.append(UInt8(0x6E))
        elif b == UInt8(0x0D):
            buf.append(UInt8(0x5C))
            buf.append(UInt8(0x72))
        elif b == UInt8(0x09):
            buf.append(UInt8(0x5C))
            buf.append(UInt8(0x74))
        elif b < UInt8(0x20):
            # \u00XX
            buf.append(UInt8(0x5C))
            buf.append(UInt8(0x75))
            buf.append(UInt8(0x30))
            buf.append(UInt8(0x30))
            buf.append(hex[Int(b >> 4)])
            buf.append(hex[Int(b & 0x0F)])
        else:
            buf.append(b)
    buf.append(UInt8(0x22))
    return String(unsafe_from_utf8=buf)


def _json_num(x: Float64) -> String:
    """A Float64 as a JSON number; a NaN or infinity (not JSON) is 0.0."""
    if not isfinite(x):
        return String(Float64(0.0))
    return String(x)


@fieldwise_init
struct ResultNode(Copyable, Movable):
    """A rendered graph vertex.

    Fields:
        id: The dense adjacency node id (the entities `nid`).
        label: The surface name shown on the vertex.
        type: The caller-defined node type ("term", "section", ...).
        score: The relevance score that brought the node in (cosine, rank
            fusion, hop weight); 0.0 if structural.
    """

    var id: Int64
    var label: String
    var type: String
    var score: Float64


@fieldwise_init
struct ResultEdge(Copyable, Movable):
    """A rendered graph arc.

    Fields:
        src: The source node id.
        dst: The destination node id.
        predicate: The relation label or fact text.
        valid_at: The bi-temporal event-time start, for an as-of timeline.
        doc_id: The provenance id this edge's fact came from.
    """

    var src: Int64
    var dst: Int64
    var predicate: String
    var valid_at: Int64
    var doc_id: String


@fieldwise_init
struct ResultFinding(Copyable, Movable):
    """An anomaly an analysis query found.

    Fields:
        locus: Where the defect is (a section id, term or locator).
        severity: `SEV_INFO`, `SEV_WARN` or `SEV_ERROR`.
        kind: What kind of defect ("dangling_xref", "undefined_term", ...).
        rationale: A human-readable explanation.
    """

    var locus: String
    var severity: Int
    var kind: String
    var rationale: String


@fieldwise_init
struct ProvenanceEntry(Copyable, Movable):
    """A `doc_id` to source mapping.

    Fields:
        doc_id: The provenance id that edges and loci refer to.
        source: The human-readable source (a file name or episode title).
    """

    var doc_id: String
    var source: String


@fieldwise_init
struct Locus(Copyable, Movable):
    """A jump-link anchor a viewer turns into a deep link.

    Fields:
        doc_id: The provenance id (matches a `ProvenanceEntry`).
        section: The section or anchor label within the document.
        offset: The character offset within the document; -1 if unknown.
    """

    var doc_id: String
    var section: String
    var offset: Int64


@fieldwise_init
struct ScoreEntry(Copyable, Movable):
    """A named relevance score.

    Fields:
        name: The score name ("cosine", "rrf", "fulltext_tf", ...).
        target_id: The node id it applies to, or -1 for a query-global score.
        value: The score.
    """

    var name: String
    var target_id: Int64
    var value: Float64


struct KgQueryResult(Copyable, Movable):
    """The structured result of a graph query: a subgraph, the analysis over
    it, provenance, jump-link loci and named scores. See the module header.
    """

    var mode: String  # "analyze" or "retain_and_query"
    var query_label: String  # human description of the query
    var answer: String  # synthesized answer, "" when none
    var nodes: List[ResultNode]
    var edges: List[ResultEdge]
    var findings: List[ResultFinding]
    var provenance: List[ProvenanceEntry]
    var loci: List[Locus]
    var scores: List[ScoreEntry]

    def __init__(out self, var mode: String, var query_label: String):
        self.mode = mode^
        self.query_label = query_label^
        self.answer = String("")
        self.nodes = List[ResultNode]()
        self.edges = List[ResultEdge]()
        self.findings = List[ResultFinding]()
        self.provenance = List[ProvenanceEntry]()
        self.loci = List[Locus]()
        self.scores = List[ScoreEntry]()

    def set_answer(mut self, var answer: String):
        """Attach the synthesized answer; empty means a structured-only result.
        """
        self.answer = answer^

    def add_node(mut self, var n: ResultNode):
        self.nodes.append(n^)

    def add_edge(mut self, var e: ResultEdge):
        self.edges.append(e^)

    def add_finding(mut self, var f: ResultFinding):
        self.findings.append(f^)

    def add_provenance(mut self, var p: ProvenanceEntry):
        """Add a source row, keeping one per `doc_id`: a repeat is dropped."""
        for i in range(len(self.provenance)):
            if self.provenance[i].doc_id == p.doc_id:
                return
        self.provenance.append(p^)

    def add_locus(mut self, var l: Locus):
        self.loci.append(l^)

    def add_score(mut self, var s: ScoreEntry):
        self.scores.append(s^)

    def has_node(self, id: Int64) -> Bool:
        for i in range(len(self.nodes)):
            if self.nodes[i].id == id:
                return True
        return False

    def is_non_trivial(self) -> Bool:
        """True when a viewer can render something from the result: at least
        one node or finding, and at least one score or provenance entry."""
        var has_content = len(self.nodes) > 0 or len(self.findings) > 0
        var has_context = len(self.scores) > 0 or len(self.provenance) > 0
        return has_content and has_context

    def serialize(self) -> String:
        """Encode this result as the version-1 JSON wire (see the module
        header). Pairs with `deserialize`.

        Returns:
            One JSON object: `v`, `mode`, `query_label`, `answer` and the six
            sub-collections, in that order.
        """
        var out = String("{")
        out += _json_str("v") + ":" + String(KG_QUERY_RESULT_FORMAT_VERSION) + ","
        out += _json_str("mode") + ":" + _json_str(self.mode) + ","
        out += _json_str("query_label") + ":" + _json_str(self.query_label) + ","
        out += _json_str("answer") + ":" + _json_str(self.answer) + ","

        out += _json_str("nodes") + ":["
        for i in range(len(self.nodes)):
            if i > 0:
                out += ","
            ref n = self.nodes[i]
            out += "{"
            out += _json_str("id") + ":" + String(n.id) + ","
            out += _json_str("label") + ":" + _json_str(n.label) + ","
            out += _json_str("type") + ":" + _json_str(n.type) + ","
            out += _json_str("score") + ":" + _json_num(n.score)
            out += "}"
        out += "],"

        out += _json_str("edges") + ":["
        for i in range(len(self.edges)):
            if i > 0:
                out += ","
            ref e = self.edges[i]
            out += "{"
            out += _json_str("src") + ":" + String(e.src) + ","
            out += _json_str("dst") + ":" + String(e.dst) + ","
            out += _json_str("predicate") + ":" + _json_str(e.predicate) + ","
            out += _json_str("valid_at") + ":" + String(e.valid_at) + ","
            out += _json_str("doc_id") + ":" + _json_str(e.doc_id)
            out += "}"
        out += "],"

        out += _json_str("findings") + ":["
        for i in range(len(self.findings)):
            if i > 0:
                out += ","
            ref f = self.findings[i]
            out += "{"
            out += _json_str("locus") + ":" + _json_str(f.locus) + ","
            out += _json_str("severity") + ":" + String(f.severity) + ","
            out += _json_str("kind") + ":" + _json_str(f.kind) + ","
            out += _json_str("rationale") + ":" + _json_str(f.rationale)
            out += "}"
        out += "],"

        out += _json_str("provenance") + ":["
        for i in range(len(self.provenance)):
            if i > 0:
                out += ","
            ref p = self.provenance[i]
            out += "{"
            out += _json_str("doc_id") + ":" + _json_str(p.doc_id) + ","
            out += _json_str("source") + ":" + _json_str(p.source)
            out += "}"
        out += "],"

        out += _json_str("loci") + ":["
        for i in range(len(self.loci)):
            if i > 0:
                out += ","
            ref l = self.loci[i]
            out += "{"
            out += _json_str("doc_id") + ":" + _json_str(l.doc_id) + ","
            out += _json_str("section") + ":" + _json_str(l.section) + ","
            out += _json_str("offset") + ":" + String(l.offset)
            out += "}"
        out += "],"

        out += _json_str("scores") + ":["
        for i in range(len(self.scores)):
            if i > 0:
                out += ","
            ref s = self.scores[i]
            out += "{"
            out += _json_str("name") + ":" + _json_str(s.name) + ","
            out += _json_str("target_id") + ":" + String(s.target_id) + ","
            out += _json_str("value") + ":" + _json_num(s.value)
            out += "}"
        out += "]"

        out += "}"
        return out^

    @staticmethod
    def deserialize(wire: String) raises -> KgQueryResult:
        """Decode the version-1 JSON wire into a `KgQueryResult`.

        Args:
            wire: The text `serialize` wrote.

        Returns:
            The decoded result.

        Raises:
            On malformed JSON, a root that is not an object, a missing `mode` or
            `query_label`, a version above `KG_QUERY_RESULT_FORMAT_VERSION` or
            below 1, or an element of a sub-collection that lacks a field.
        """
        var doc = JsonDoc.parse(wire)
        var root = doc.root()
        if not root.is_object():
            raise Error("KgQueryResult.deserialize: root is not a JSON object")

        if root.has(String("v")):
            var ver = root.get(String("v")).as_int()
            if ver > KG_QUERY_RESULT_FORMAT_VERSION:
                raise Error(
                    "KgQueryResult.deserialize: wire format version "
                    + String(ver)
                    + " > reader-supported "
                    + String(KG_QUERY_RESULT_FORMAT_VERSION)
                    + " (this build cannot read a future structured-result"
                    " wire; rebuild with an updated reader)"
                )
            if ver < 1:
                raise Error(
                    "KgQueryResult.deserialize: wire format version "
                    + String(ver)
                    + " is not a version (the first is 1)"
                )

        var mode = root.get(String("mode")).as_string()
        var query_label = root.get(String("query_label")).as_string()
        var out = KgQueryResult(mode^, query_label^)

        if root.has(String("answer")):
            out.set_answer(root.get(String("answer")).as_string_or(String("")))

        if root.has(String("nodes")):
            var arr = root.get(String("nodes"))
            for i in range(arr.len()):
                var n = arr.at(i)
                out.add_node(
                    ResultNode(
                        Int64(n.get(String("id")).as_int()),
                        n.get(String("label")).as_string(),
                        n.get(String("type")).as_string(),
                        n.get(String("score")).as_float(),
                    )
                )

        if root.has(String("edges")):
            var arr = root.get(String("edges"))
            for i in range(arr.len()):
                var e = arr.at(i)
                out.add_edge(
                    ResultEdge(
                        Int64(e.get(String("src")).as_int()),
                        Int64(e.get(String("dst")).as_int()),
                        e.get(String("predicate")).as_string(),
                        Int64(e.get(String("valid_at")).as_int()),
                        e.get(String("doc_id")).as_string(),
                    )
                )

        if root.has(String("findings")):
            var arr = root.get(String("findings"))
            for i in range(arr.len()):
                var f = arr.at(i)
                out.add_finding(
                    ResultFinding(
                        f.get(String("locus")).as_string(),
                        f.get(String("severity")).as_int(),
                        f.get(String("kind")).as_string(),
                        f.get(String("rationale")).as_string(),
                    )
                )

        if root.has(String("provenance")):
            var arr = root.get(String("provenance"))
            for i in range(arr.len()):
                var p = arr.at(i)
                out.add_provenance(
                    ProvenanceEntry(
                        p.get(String("doc_id")).as_string(),
                        p.get(String("source")).as_string(),
                    )
                )

        if root.has(String("loci")):
            var arr = root.get(String("loci"))
            for i in range(arr.len()):
                var l = arr.at(i)
                out.add_locus(
                    Locus(
                        l.get(String("doc_id")).as_string(),
                        l.get(String("section")).as_string(),
                        Int64(l.get(String("offset")).as_int()),
                    )
                )

        if root.has(String("scores")):
            var arr = root.get(String("scores"))
            for i in range(arr.len()):
                var s = arr.at(i)
                out.add_score(
                    ScoreEntry(
                        s.get(String("name")).as_string(),
                        Int64(s.get(String("target_id")).as_int()),
                        s.get(String("value")).as_float(),
                    )
                )

        return out^
