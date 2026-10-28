# =============================================================================
# structured -- the body of the structured-ingest route.
# =============================================================================
#
# A caller that already knows its entities and relations posts them as JSON, and
# nothing is extracted from text. The body is one object:
#
#   {
#     "entities": [ {"name": "...", "type": "...", "summary": "..."}, ... ],
#     "edges":    [ {"subject": "...", "predicate": "...", "object": "...",
#                    "fact": "...", "valid_at": 0, "invalid_at": 0}, ... ],
#     "uuid": "...", "partition": "...", "valid_at": 0, "body": "...",
#     "source": "...", "facet": "...", "facet_source": "..."
#   }
#
# `entities` and `edges` are required (either may be empty). An entity needs a
# `name`; `type` and `summary` default to "". An edge needs a `subject` and an
# `object`; `predicate` defaults to "", `fact` to "<subject> <predicate>
# <object>", `valid_at` and `invalid_at` to the open sentinel (an edge with no
# `valid_at` takes the episode's). The rest are the episode's envelope: `uuid`
# defaults to "structured", `partition` and `valid_at` to nothing (the route
# fills in its default partition and the server's clock), the others to "".
#
# A field that is present with the wrong type is refused, not defaulted: a body
# the caller got wrong is an error the caller sees. Times are integers.
# =============================================================================

from komira_json import JsonValue, parse_json_bytes
from komira_kg_format import EntityMention, Extraction, TS_OPEN_SENTINEL, Triple


struct StructuredRequest(Movable):
    """A parsed structured-ingest body.

    Fields:
        extraction: The entities and edges, held in an `Optional` so the route
            can move them out (`take_extraction`).
        num_entities: How many entities the body listed.
        num_edges: How many edges the body listed.
        uuid: The episode's id.
        partition_id: The body's partition, "" if it named none.
        valid_at: The body's event time, if it gave one.
        note: A provenance note for the episode row (never extracted from).
        source: The source the facts replace, "" for none.
        facet: The facet label, "" for none.
        facet_source: The source the facet is attributed to, "" for none.
    """

    var extraction: Optional[Extraction]
    var num_entities: Int
    var num_edges: Int
    var uuid: String
    var partition_id: String
    var valid_at: Optional[Int64]
    var note: String
    var source: String
    var facet: String
    var facet_source: String

    def __init__(
        out self,
        var extraction: Extraction,
        var uuid: String,
        var partition_id: String,
        valid_at: Optional[Int64],
        var note: String,
        var source: String,
        var facet: String,
        var facet_source: String,
    ):
        self.num_entities = extraction.num_entities()
        self.num_edges = extraction.num_triples()
        self.extraction = Optional[Extraction](extraction^)
        self.uuid = uuid^
        self.partition_id = partition_id^
        self.valid_at = valid_at
        self.note = note^
        self.source = source^
        self.facet = facet^
        self.facet_source = facet_source^

    def take_extraction(mut self) raises -> Extraction:
        """Move the extraction out, leaving none.

        Raises:
            If it was already taken.
        """
        if not self.extraction:
            raise Error("StructuredRequest: the extraction was already taken")
        return self.extraction.take()


def _string_or(obj: JsonValue, key: String, default: String) raises -> String:
    if not obj.has(key):
        return default
    var v = obj.get(key)
    if not v.is_string():
        raise Error("'" + key + "' must be a string")
    return v.as_string()


def _int_or(obj: JsonValue, key: String, default: Int64) raises -> Int64:
    if not obj.has(key):
        return default
    var v = obj.get(key)
    if not v.is_number() or not v.is_integral_number():
        raise Error("'" + key + "' must be an integer")
    return v.as_int64()


def _array_of(root: JsonValue, key: String) raises -> JsonValue:
    if not root.has(key):
        raise Error("'" + key + "' is required")
    var v = root.get(key)
    if not v.is_array():
        raise Error("'" + key + "' must be an array")
    return v^


def parse_structured_request(body: List[UInt8]) raises -> StructuredRequest:
    """Read a structured-ingest body (the format is in the file header).

    Args:
        body: The request body.

    Returns:
        The parsed request.

    Raises:
        If the body is not valid JSON or an object, a required field is
        missing, or a field has the wrong type.
    """
    var root = parse_json_bytes(body)
    if not root.is_object():
        raise Error("the body must be a JSON object")

    var mentions = List[EntityMention]()
    var entities = _array_of(root, String("entities"))
    for i in range(entities.array_len()):
        var e = entities.element_at(i)
        if not e.is_object():
            raise Error("entities[" + String(i) + "] must be an object")
        var name = _string_or(e, String("name"), String(""))
        if len(name.as_bytes()) == 0:
            raise Error("entities[" + String(i) + "] needs a non-empty 'name'")
        mentions.append(
            EntityMention(
                name^,
                _string_or(e, String("type"), String("")),
                _string_or(e, String("summary"), String("")),
            )
        )

    var triples = List[Triple]()
    var edges = _array_of(root, String("edges"))
    for i in range(edges.array_len()):
        var e = edges.element_at(i)
        if not e.is_object():
            raise Error("edges[" + String(i) + "] must be an object")
        var subject = _string_or(e, String("subject"), String(""))
        var obj = _string_or(e, String("object"), String(""))
        if len(subject.as_bytes()) == 0 or len(obj.as_bytes()) == 0:
            raise Error(
                "edges[" + String(i) + "] needs a non-empty 'subject' and"
                " 'object'"
            )
        var predicate = _string_or(e, String("predicate"), String(""))
        var fact = _string_or(e, String("fact"), String(""))
        if len(fact.as_bytes()) == 0:
            fact = subject + " " + predicate + " " + obj
        triples.append(
            Triple(
                subject^,
                predicate^,
                obj^,
                fact^,
                _int_or(e, String("valid_at"), TS_OPEN_SENTINEL),
                _int_or(e, String("invalid_at"), TS_OPEN_SENTINEL),
            )
        )

    var valid_at = Optional[Int64]()
    if root.has(String("valid_at")):
        valid_at = Optional[Int64](_int_or(root, String("valid_at"), Int64(0)))
    return StructuredRequest(
        Extraction(mentions^, triples^),
        _string_or(root, String("uuid"), String("structured")),
        _string_or(root, String("partition"), String("")),
        valid_at,
        _string_or(root, String("body"), String("")),
        _string_or(root, String("source"), String("")),
        _string_or(root, String("facet"), String("")),
        _string_or(root, String("facet_source"), String("")),
    )
