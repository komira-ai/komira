# =============================================================================
# query_result -- the structured result of a graph query, and its JSON wire.
# =============================================================================
#
# A query result is a subgraph plus what is layered over it:
#   * nodes        -- id / label / type / score         (the vertices)
#   * edges        -- src / dst / predicate / valid_at / source_id  (the arcs)
#   * annotations  -- locus / severity / kind / rationale  (notes on the result)
#   * provenance   -- source_id -> source               (where a fact came from)
#   * loci         -- source_id + anchor + offset       (jump-link targets)
#   * scores       -- named relevance scores            (the ranking)
#
# `mode` is an opaque label the producer sets and the consumer may branch on;
# this package gives it no values. `kind` of an annotation, `type` of a node and
# `anchor` of a locus are opaque strings too, and `severity` is an integer rank
# (a larger number is more severe). `answer` carries a natural-language answer
# synthesized from the retrieved subgraph; it is "" when no synthesis ran.
#
# The value types own their heap (`String`, `List`) and are built, returned and
# consumed as ordinary values. No pointer appears in any signature.
#
# WIRE: `serialize` writes one self-describing JSON object with `komira_json`,
# `deserialize` reads it back, and serialize -> deserialize -> serialize is
# byte-stable.
#   * `v` is the format version (`KG_QUERY_RESULT_FORMAT_VERSION`). A reader
#     refuses any other version, older or newer; a missing `v` is read as the
#     current version.
#   * Strings are escaped by `komira_json`: multi-byte UTF-8 passes through
#     unchanged and every control character below 0x20 is escaped.
#   * Numbers ride as JSON numbers; a Float64 is written in its shortest
#     round-trip form. JSON has no NaN or infinity, so a non-finite score or
#     value is written as 0.0.
#   * A missing sub-collection key reads as an empty list, and a missing
#     `answer` as "". `provenance` keeps the first entry for each `source_id`.
# =============================================================================

from std.math import isfinite

from komira_json import JsonValue, parse_json_value


# The wire format version `serialize` stamps and `deserialize` requires.
# Version 2 names the source of a fact `source_id`, the notes `annotations` and
# a locus target `anchor`.
comptime KG_QUERY_RESULT_FORMAT_VERSION: Int = 2


def _num(x: Float64) -> JsonValue:
    """A Float64 as a JSON number; a NaN or infinity (not JSON) is 0.0."""
    if not isfinite(x):
        return JsonValue.from_f64(0.0)
    return JsonValue.from_f64(x)


@fieldwise_init
struct ResultNode(Copyable, Movable):
    """A graph vertex of a result.

    Fields:
        id: The dense adjacency node id (the entities `nid`).
        label: The surface name shown on the vertex.
        type: The caller-defined node type, an opaque string.
        score: The relevance score that brought the node in (cosine, rank
            fusion, hop weight); 0.0 if structural.
    """

    var id: Int64
    var label: String
    var type: String
    var score: Float64


@fieldwise_init
struct ResultEdge(Copyable, Movable):
    """A graph arc of a result.

    Fields:
        src: The source node id.
        dst: The destination node id.
        predicate: The relation label or fact text.
        valid_at: The bi-temporal event-time start, for an as-of timeline.
        source_id: The provenance id this edge's fact came from.
    """

    var src: Int64
    var dst: Int64
    var predicate: String
    var valid_at: Int64
    var source_id: String


@fieldwise_init
struct ResultAnnotation(Copyable, Movable):
    """A note a query attaches to its result.

    Fields:
        locus: What the note is about (a node label, a locator), opaque.
        severity: An integer rank; a larger number is more severe.
        kind: The caller-defined kind of note, an opaque string.
        rationale: A human-readable explanation.
    """

    var locus: String
    var severity: Int
    var kind: String
    var rationale: String


@fieldwise_init
struct ProvenanceEntry(Copyable, Movable):
    """A `source_id` to source mapping.

    Fields:
        source_id: The provenance id that edges and loci refer to.
        source: The human-readable source (a name or title).
    """

    var source_id: String
    var source: String


@fieldwise_init
struct Locus(Copyable, Movable):
    """A jump-link target: a position inside a source.

    Fields:
        source_id: The provenance id (matches a `ProvenanceEntry`).
        anchor: An opaque anchor within the source; "" for the whole source.
        offset: The character offset within the source; -1 if unknown.
    """

    var source_id: String
    var anchor: String
    var offset: Int64


@fieldwise_init
struct ScoreEntry(Copyable, Movable):
    """A named relevance score.

    Fields:
        name: The score name ("cosine", "rrf", ...).
        target_id: The node id it applies to, or -1 for a query-global score.
        value: The score.
    """

    var name: String
    var target_id: Int64
    var value: Float64


struct KgQueryResult(Copyable, Movable):
    """The structured result of a graph query: a subgraph, annotations,
    provenance, jump-link loci and named scores. See the module header.
    """

    var mode: String  # an opaque label set by the producer
    var query_label: String  # human description of the query
    var answer: String  # synthesized answer, "" when none
    var nodes: List[ResultNode]
    var edges: List[ResultEdge]
    var annotations: List[ResultAnnotation]
    var provenance: List[ProvenanceEntry]
    var loci: List[Locus]
    var scores: List[ScoreEntry]

    def __init__(out self, var mode: String, var query_label: String):
        self.mode = mode^
        self.query_label = query_label^
        self.answer = String("")
        self.nodes = List[ResultNode]()
        self.edges = List[ResultEdge]()
        self.annotations = List[ResultAnnotation]()
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

    def add_annotation(mut self, var a: ResultAnnotation):
        self.annotations.append(a^)

    def add_provenance(mut self, var p: ProvenanceEntry):
        """Add a source row, keeping one per `source_id`: a repeat is dropped."""
        for i in range(len(self.provenance)):
            if self.provenance[i].source_id == p.source_id:
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
        """True when a consumer can render something from the result: at least
        one node or annotation, and at least one score or provenance entry."""
        var has_content = len(self.nodes) > 0 or len(self.annotations) > 0
        var has_context = len(self.scores) > 0 or len(self.provenance) > 0
        return has_content and has_context

    def serialize(self) raises -> String:
        """Encode this result as the JSON wire (see the module header). Pairs
        with `deserialize`.

        Returns:
            One JSON object: `v`, `mode`, `query_label`, `answer` and the six
            sub-collections, in that order.
        """
        var root = JsonValue.empty_object()
        root.set_member("v", JsonValue.from_i64(Int64(KG_QUERY_RESULT_FORMAT_VERSION)))
        root.set_member("mode", JsonValue.from_string(self.mode))
        root.set_member("query_label", JsonValue.from_string(self.query_label))
        root.set_member("answer", JsonValue.from_string(self.answer))

        var nodes = JsonValue.empty_array()
        for i in range(len(self.nodes)):
            ref n = self.nodes[i]
            var o = JsonValue.empty_object()
            o.set_member("id", JsonValue.from_i64(n.id))
            o.set_member("label", JsonValue.from_string(n.label))
            o.set_member("type", JsonValue.from_string(n.type))
            o.set_member("score", _num(n.score))
            nodes.push(o^)
        root.set_member("nodes", nodes^)

        var edges = JsonValue.empty_array()
        for i in range(len(self.edges)):
            ref e = self.edges[i]
            var o = JsonValue.empty_object()
            o.set_member("src", JsonValue.from_i64(e.src))
            o.set_member("dst", JsonValue.from_i64(e.dst))
            o.set_member("predicate", JsonValue.from_string(e.predicate))
            o.set_member("valid_at", JsonValue.from_i64(e.valid_at))
            o.set_member("source_id", JsonValue.from_string(e.source_id))
            edges.push(o^)
        root.set_member("edges", edges^)

        var annotations = JsonValue.empty_array()
        for i in range(len(self.annotations)):
            ref a = self.annotations[i]
            var o = JsonValue.empty_object()
            o.set_member("locus", JsonValue.from_string(a.locus))
            o.set_member("severity", JsonValue.from_i64(Int64(a.severity)))
            o.set_member("kind", JsonValue.from_string(a.kind))
            o.set_member("rationale", JsonValue.from_string(a.rationale))
            annotations.push(o^)
        root.set_member("annotations", annotations^)

        var provenance = JsonValue.empty_array()
        for i in range(len(self.provenance)):
            ref p = self.provenance[i]
            var o = JsonValue.empty_object()
            o.set_member("source_id", JsonValue.from_string(p.source_id))
            o.set_member("source", JsonValue.from_string(p.source))
            provenance.push(o^)
        root.set_member("provenance", provenance^)

        var loci = JsonValue.empty_array()
        for i in range(len(self.loci)):
            ref l = self.loci[i]
            var o = JsonValue.empty_object()
            o.set_member("source_id", JsonValue.from_string(l.source_id))
            o.set_member("anchor", JsonValue.from_string(l.anchor))
            o.set_member("offset", JsonValue.from_i64(l.offset))
            loci.push(o^)
        root.set_member("loci", loci^)

        var scores = JsonValue.empty_array()
        for i in range(len(self.scores)):
            ref s = self.scores[i]
            var o = JsonValue.empty_object()
            o.set_member("name", JsonValue.from_string(s.name))
            o.set_member("target_id", JsonValue.from_i64(s.target_id))
            o.set_member("value", _num(s.value))
            scores.push(o^)
        root.set_member("scores", scores^)

        return root.serialize()

    @staticmethod
    def deserialize(wire: String) raises -> KgQueryResult:
        """Decode the JSON wire into a `KgQueryResult`.

        Args:
            wire: The text `serialize` wrote.

        Returns:
            The decoded result.

        Raises:
            On malformed JSON, a root that is not an object, a missing `mode` or
            `query_label`, a version other than `KG_QUERY_RESULT_FORMAT_VERSION`,
            or an element of a sub-collection that lacks a field or holds the
            wrong kind of value.
        """
        var root = parse_json_value(wire)
        if not root.is_object():
            raise Error("KgQueryResult.deserialize: root is not a JSON object")

        if root.has("v"):
            var ver = Int(root.get("v").as_int64())
            if ver > KG_QUERY_RESULT_FORMAT_VERSION:
                raise Error(
                    "KgQueryResult.deserialize: wire format version "
                    + String(ver)
                    + " > reader-supported "
                    + String(KG_QUERY_RESULT_FORMAT_VERSION)
                    + " (this build cannot read a future wire)"
                )
            if ver < KG_QUERY_RESULT_FORMAT_VERSION:
                raise Error(
                    "KgQueryResult.deserialize: wire format version "
                    + String(ver)
                    + " < "
                    + String(KG_QUERY_RESULT_FORMAT_VERSION)
                    + " (an older layout with other key names is not read)"
                )

        var out = KgQueryResult(
            root.get("mode").as_string(), root.get("query_label").as_string()
        )

        if root.has("answer"):
            var a = root.get("answer")
            if a.is_string():
                out.set_answer(a.as_string())

        if root.has("nodes"):
            var arr = root.get("nodes")
            for i in range(arr.array_len()):
                var n = arr.element_at(i)
                out.add_node(
                    ResultNode(
                        n.get("id").as_int64(),
                        n.get("label").as_string(),
                        n.get("type").as_string(),
                        _number(n.get("score")),
                    )
                )

        if root.has("edges"):
            var arr = root.get("edges")
            for i in range(arr.array_len()):
                var e = arr.element_at(i)
                out.add_edge(
                    ResultEdge(
                        e.get("src").as_int64(),
                        e.get("dst").as_int64(),
                        e.get("predicate").as_string(),
                        e.get("valid_at").as_int64(),
                        e.get("source_id").as_string(),
                    )
                )

        if root.has("annotations"):
            var arr = root.get("annotations")
            for i in range(arr.array_len()):
                var a = arr.element_at(i)
                out.add_annotation(
                    ResultAnnotation(
                        a.get("locus").as_string(),
                        Int(a.get("severity").as_int64()),
                        a.get("kind").as_string(),
                        a.get("rationale").as_string(),
                    )
                )

        if root.has("provenance"):
            var arr = root.get("provenance")
            for i in range(arr.array_len()):
                var p = arr.element_at(i)
                out.add_provenance(
                    ProvenanceEntry(
                        p.get("source_id").as_string(),
                        p.get("source").as_string(),
                    )
                )

        if root.has("loci"):
            var arr = root.get("loci")
            for i in range(arr.array_len()):
                var l = arr.element_at(i)
                out.add_locus(
                    Locus(
                        l.get("source_id").as_string(),
                        l.get("anchor").as_string(),
                        l.get("offset").as_int64(),
                    )
                )

        if root.has("scores"):
            var arr = root.get("scores")
            for i in range(arr.array_len()):
                var s = arr.element_at(i)
                out.add_score(
                    ScoreEntry(
                        s.get("name").as_string(),
                        s.get("target_id").as_int64(),
                        _number(s.get("value")),
                    )
                )

        return out^


def _number(v: JsonValue) raises -> Float64:
    """The Float64 of a JSON number; a string or other kind is refused (the
    reader of `JsonValue.as_float64` would also take a string)."""
    if not v.is_number():
        raise Error("KgQueryResult.deserialize: expected a number")
    return v.as_float64()
