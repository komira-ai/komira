# =============================================================================
# query_spec -- the request of the query routes.
# =============================================================================
#
# `POST /query` and `POST /query-federated` take one JSON object:
#
#   {
#     "q": "<text>",              required, non-empty
#     "k": 16,                    optional node cap, 1 to the configured maximum
#     "as_of": 0,                 optional; only edges live at this event time
#     "partition": "<id>",        /query: the partition to read
#     "partitions": ["<id>"],     /query-federated: the partitions to read
#     "facet": "<label>",         optional; only entities of exactly this facet
#     "synthesize": true          optional; see below
#   }
#
# `?partition=`, `?partitions=a,b,c` (comma separated) and `?facet=` on the
# query string take precedence over the body's member of the same name; a
# federated query takes the union of both lists. A /query that names no
# partition reads the server's default partition, as the write routes do; a
# federated query that names none reads the default partition too. A query
# reads exactly the partitions it names: asking for "everything" means listing
# the partitions.
#
# `synthesize` absent means "answer with the model if the server has one"; false
# never asks the model; true asks, and is refused when the server has no model
# able to answer.
#
# A member that is present with the wrong type is refused, not defaulted.
# =============================================================================

from komira_json import JsonValue, parse_json_bytes, refuse_duplicate_keys

from .http_util import check_label, query_value
from .query_config import QueryConfig


struct QuerySpec(Copyable, Movable):
    """A parsed query request.

    Fields:
        text: The query text.
        k: The node cap, already defaulted and bounded.
        partitions: The partitions to read; never empty, no repeats, in the
            order given.
        facet: The facet to match exactly, "" for none.
        as_of: The event time to read edges at, if the request gave one.
        synthesize: Whether the request asked for, or against, an answer.
        federated: Whether this is a federated query.
    """

    var text: String
    var k: Int
    var partitions: List[String]
    var facet: String
    var as_of: Optional[Int64]
    var synthesize: Optional[Bool]
    var federated: Bool

    def __init__(
        out self,
        var text: String,
        k: Int,
        var partitions: List[String],
        var facet: String,
        as_of: Optional[Int64],
        synthesize: Optional[Bool],
        federated: Bool,
    ):
        self.text = text^
        self.k = k
        self.partitions = partitions^
        self.facet = facet^
        self.as_of = as_of
        self.synthesize = synthesize
        self.federated = federated


def _push_unique(mut out: List[String], var value: String):
    for i in range(len(out)):
        if out[i] == value:
            return
    out.append(value^)


def _split_csv(text: String, mut out: List[String]):
    var b = text.as_bytes()
    var start = 0
    for i in range(len(b) + 1):
        if i == len(b) or b[i] == 0x2C:  # ','
            if i > start:
                # SAFETY: `text` is valid UTF-8 and the cut points are ASCII
                # commas or the ends, so each piece is valid UTF-8.
                _push_unique(out, String(unsafe_from_utf8=b[start:i]))
            start = i + 1


def parse_query_request(
    body: List[UInt8],
    query_string: String,
    federated: Bool,
    default_partition: String,
    config: QueryConfig,
) raises -> QuerySpec:
    """Read a query request (the format is in the file header).

    Args:
        body: The request body.
        query_string: The request's query string, without the '?'.
        federated: Whether the request is for the federated route.
        default_partition: The partition read when the request names none.
        config: The query limits.

    Returns:
        The request.

    Raises:
        If the body is empty, not valid JSON or not an object; a member has the
        wrong type; `q` is missing or empty; `k` is outside 1 to `max_k`; a
        partition or the facet holds a control byte or is too long; the
        federated list is over `max_partitions`; or the query string is
        malformed.
    """
    if len(body) == 0:
        raise Error('the body must be a JSON object holding "q"')
    var root = parse_json_bytes(body)
    if not root.is_object():
        raise Error("the body must be a JSON object")
    refuse_duplicate_keys(root)

    if not root.has(String("q")):
        raise Error("'q' is required")
    var q = root.get(String("q"))
    if not q.is_string():
        raise Error("'q' must be a string")
    var text = q.as_string()
    if len(text.as_bytes()) == 0:
        raise Error("'q' must not be empty")

    var k = config.default_k
    if root.has(String("k")):
        var kv = root.get(String("k"))
        if not kv.is_integral_number():
            raise Error("'k' must be an integer")
        var n = kv.as_int64()
        if n < Int64(1) or n > Int64(config.max_k):
            raise Error("'k' must be from 1 to " + String(config.max_k))
        k = Int(n)

    var as_of = Optional[Int64]()
    if root.has(String("as_of")):
        var av = root.get(String("as_of"))
        if not av.is_integral_number():
            raise Error("'as_of' must be an integer")
        as_of = Optional[Int64](av.as_int64())

    var synthesize = Optional[Bool]()
    if root.has(String("synthesize")):
        var sv = root.get(String("synthesize"))
        if not sv.is_bool():
            raise Error("'synthesize' must be true or false")
        synthesize = Optional[Bool](sv.as_bool())

    var facet = query_value(query_string, String("facet"))
    if len(facet.as_bytes()) == 0 and root.has(String("facet")):
        var fv = root.get(String("facet"))
        if not fv.is_string():
            raise Error("'facet' must be a string")
        facet = fv.as_string()
    if len(facet.as_bytes()) > 0:
        check_label("facet", facet)

    var partitions = List[String]()
    if federated:
        _split_csv(query_value(query_string, String("partitions")), partitions)
        if root.has(String("partitions")):
            var arr = root.get(String("partitions"))
            if not arr.is_array():
                raise Error("'partitions' must be an array of strings")
            for i in range(arr.array_len()):
                var pv = arr.element_at(i)
                if not pv.is_string():
                    raise Error("'partitions' must be an array of strings")
                var p = pv.as_string()
                if len(p.as_bytes()) > 0:
                    _push_unique(partitions, p^)
    else:
        var one = query_value(query_string, String("partition"))
        if len(one.as_bytes()) == 0 and root.has(String("partition")):
            var pv = root.get(String("partition"))
            if not pv.is_string():
                raise Error("'partition' must be a string")
            one = pv.as_string()
        if len(one.as_bytes()) > 0:
            partitions.append(one^)
    if len(partitions) == 0:
        partitions.append(default_partition.copy())
    if len(partitions) > config.max_partitions:
        raise Error(
            "the query names " + String(len(partitions))
            + " partitions; the most allowed is " + String(config.max_partitions)
        )
    for i in range(len(partitions)):
        check_label("partition", partitions[i])

    return QuerySpec(
        text^, k, partitions^, facet^, as_of, synthesize, federated
    )
