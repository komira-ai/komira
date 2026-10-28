# `komira_kg_capture`

## Responsibility

The capture server of
[the knowledge graph port](https://github.com/komira-ai/komira/blob/main/docs/design/knowledge_graph_port.md),
core half: a `komira_http_server` dispatcher over one snapshot store that takes
records from a push and writes them to the graph. It knows no kind of record,
service or vocabulary: which adapter reads a record is chosen by an opaque
surface tag the caller sends, and anything beyond the routes below is a
`CaptureRoutes` conformer the host supplies. Reading the graph back is the query
routes below.

| route | what it does |
|---|---|
| `GET /health` | open; `{"status":"ok"}`, no store access |
| `POST /capture?surface=<tag>[&partition=<id>]` | the body is one raw record; the adapter registered under `<tag>` parses and lowers it, each episode is ingested; a tag nobody registered is 422 and no adapter runs |
| `POST /ingest-structured[?partition=<id>]` | known entities and edges as JSON (format in `structured.mojo`); ingested with no extraction |
| `POST /query[?partition=<id>][&facet=<f>]` | the subgraph around what a text matches in one partition, with the model's answer when the server has a model; body `{"q": "...", "k"?, "as_of"?, "partition"?, "facet"?, "synthesize"?}` |
| `POST /query-federated[?partitions=a,b,c]` | the same over a list of partitions, merged and ranked together; each node carries its partition as provenance; body as above with `"partitions": [...]` |
| a host's | whatever a `CaptureRoutes` conformer claims, over the loaded working set |

Every route except health needs `Authorization: Bearer <token>`, the token the
host gives `CaptureConfig`. The check comes first, so a request without it learns
nothing about which routes or surfaces exist (401 for any path and method). Then
the body is held to `max_body_bytes` (413). Set `HttpServerConfig.max_body_bytes`
to the same limit or higher, so the server's own limit does not pre-empt this
one's message.

## API

Everything is exported from `komira_kg_capture`:

- `CaptureDispatcher[Store, Llm, Emb, Registry, Routes, Clock]`: the dispatcher
  (`store_ref` borrows the store to read back what was written).
- `CaptureConfig(token, default_partition, max_body_bytes, compact_after_deltas,
  ingest)`: nothing has a default; each argument is checked.
- `CaptureClock` (trait), `FixedClock`, `StepClock`.
- `QueryConfig(synthesis_prompt, default_k, max_k, max_query_bytes, max_partitions,
  per_partition_cap, similarity_floor)` and `QueryConfig.default()`: the host's
  synthesis prompt (`DEFAULT_SYNTHESIS_PROMPT` is the neutral default) and the
  query limits; the dispatcher takes it as its last, optional argument.
- `build_query_result`, `QuerySpec`, `parse_query_request`: the read, a pure
  function of a working set; `evidence_pack`, `synthesize_answer`: the model step.
- `CaptureRoutes` (trait), `NoRoutes`.
- `parse_structured_request`, `StructuredRequest`.
- `json_response`, `error_response`, `query_value`, `bearer_matches`,
  `check_token`, `check_label`: the helpers a host's routes can reuse.

## Behaviour worth knowing

- **The clock is an argument.** The server reads no clock. The reading taken for a
  request is the ingest time (`ts`) of every episode it writes (an adapter's own
  `ts` is replaced), the event time of a structured body that names none, and the
  time a compaction fold marks retired chunks with. A refused request spends no
  reading.
- **The graph stays warm.** The merged working set is kept between requests
  (`WarmMergedCache`). A write takes it, ingests in place, folds the delta chain
  once it holds `compact_after_deltas` deltas, and puts it back keyed at the new
  head. A write that fails part way drops it, so the next request merges the
  stored state again. A delta another writer appended is picked up the same way.
- **Errors are fixed messages.** A failure of an adapter, of the ingest or of a
  host route says what failed in words of the server's own and repeats nothing
  the lower layer said, so no path, endpoint or model message leaves the
  process. A malformed structured body is described, because the description is
  about the caller's own bytes. A failed ingest is 500 (the server cannot tell
  bad input from a failed store).
- **A query reads what it names.** A query that names no partition reads the
  server's default partition (the one the write routes use); a federated query
  that names none reads it too. Asking for "everything" means listing the
  partitions. Nothing outside the named partitions is returned: not a seed, and
  not a neighbour across an edge from one (a federated query naming only `p1`
  gets no `p2` node and no edge into `p2`). A federated query names at most
  `max_partitions` distinct partitions; a longer list is refused while it is
  read, and each name is checked as it is read. The facet is a plain string compared for equality with the
  entity's stored facet; an entity with no facet never passes a non-empty filter.
- **Seeds and order.** An entity seeds a query when the cosine of its name
  embedding with the embedded query is at least `similarity_floor`, or when its
  name contains the query text (ASCII case folded). Semantic seeds come first,
  strongest first (equal scores by node id), then text-only seeds, then their
  neighbours in the named partitions, up to `k`. A federated result does not depend on the order the
  partitions are listed in. If the embedder fails or returns a wrong-sized or
  non-finite vector, the text match still answers.
- **Warm and cold agree.** The read is a function of the merged graph at the
  head, so the warm set, a cold server over the same store and a set loaded by
  hand give the same bytes. A query writes nothing and reads no clock.
- **The model.** `LlmClient.synthesize` gets the host's prompt unchanged as the
  system text and an evidence pack (the question, up to 32 entities and 48
  relations) as the user text. A model failure is 502 with a fixed message;
  `"synthesize": false` skips the model, `true` on a server with none is 501.
  The query text is limited to `max_query_bytes` (413) and the body to
  `max_body_bytes` (413).
- **Host routes** are asked only after authentication and the size check, and
  only for a path the server does not serve itself (`/health`, `/capture` and
  `/ingest-structured` stay the server's). A route is lent the working set merged
  at the head, read-only, or an empty one of the embedder's width when nothing has
  been written.
- **One writer.** The server is single-threaded and the single writer of its
  store handle.

## Examples

A server over an in-memory store, one made-up adapter, a stub model and embedder:
a push becomes an episode, and a request without the token is refused.

```mojo module
from std.sys.info import CompilationTarget
from std.testing import assert_equal

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_KQUEUE, Reactor
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_http_core.codec import HttpMethod, HttpRequest
from komira_kg import EpisodeInput, IngestConfig, SnapshotWorkingSet, StubEmbedder, StubLlmClient
from komira_kg_capture import CaptureConfig, CaptureDispatcher, FixedClock, NoRoutes
from komira_kg_format import KgSnapshotStore
from komira_kg_sources import EmptyAdapterRegistry, RawSurfaceAdapter, register
from komira_objectstore.shared_in_memory_conditional_store import SharedInMemoryConditionalStore


@fieldwise_init
struct Note(Movable):
    var text: String


struct NoteAdapter(RawSurfaceAdapter):
    comptime Source = Note

    def __init__(out self):
        pass

    def surface_tag(self) -> String:
        return "notes"

    def parse(self, raw: List[UInt8]) raises -> Note:
        return Note(String(from_utf8_lossy=Span(raw)))

    def lower(self, var source: Note, partition_id: String) raises -> List[EpisodeInput]:
        var out = List[EpisodeInput]()
        out.append(EpisodeInput("note-1", partition_id, source.text.copy(), Int64(0), Int64(0)))
        return out^


def backend() -> UInt8:
    comptime if CompilationTarget.is_linux():
        return BACKEND_EPOLL
    return BACKEND_KQUEUE


def main() raises:
    var config = CaptureConfig("a-long-random-token", "default", 4096, 32, IngestConfig.default())
    var server = CaptureDispatcher(
        KgSnapshotStore[SharedInMemoryConditionalStore](SharedInMemoryConditionalStore(), "graph"),
        StubLlmClient(),
        StubEmbedder(4),
        register(EmptyAdapterRegistry(), NoteAdapter()),
        NoRoutes(),
        FixedClock(Int64(1_000)),
        config^,
    )
    var reactor = Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), backend())

    var push = HttpRequest(HttpMethod.post(), "/capture")
    push.query_string = "surface=notes"
    push.headers["authorization"] = "Bearer a-long-random-token"
    push.body.extend("remember this".as_bytes())
    var ok = server.dispatch[BlockingRuntime[NoopSink]](reactor, push^)
    assert_equal(Int(ok.status), 200)
    var ws = SnapshotWorkingSet.load_latest(server.store_ref())
    assert_equal(ws.episodes[0].body, "remember this")
    assert_equal(ws.episodes[0].ts, Int64(1_000))  # the server's clock

    var anonymous = HttpRequest(HttpMethod.post(), "/capture")
    anonymous.query_string = "surface=notes"
    anonymous.body.extend("remember this too".as_bytes())
    var refused = server.dispatch[BlockingRuntime[NoopSink]](reactor, anonymous^)
    assert_equal(Int(refused.status), 401)
```

A query over what was written, answered by a model:

```mojo module
from std.sys.info import CompilationTarget
from std.testing import assert_equal

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_KQUEUE, Reactor
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_http_core.codec import HttpMethod, HttpRequest
from komira_json import parse_json_bytes
from komira_kg import IngestConfig, StubEmbedder, StubLlmClient
from komira_kg_capture import (
    CaptureConfig,
    CaptureDispatcher,
    DEFAULT_SYNTHESIS_PROMPT,
    FixedClock,
    NoRoutes,
    QueryConfig,
)
from komira_kg_format import KgSnapshotStore
from komira_kg_sources import EmptyAdapterRegistry
from komira_objectstore.shared_in_memory_conditional_store import SharedInMemoryConditionalStore


def backend() -> UInt8:
    comptime if CompilationTarget.is_linux():
        return BACKEND_EPOLL
    return BACKEND_KQUEUE


def post(path: String, body: String) -> HttpRequest:
    var r = HttpRequest(HttpMethod.post(), path)
    r.headers["authorization"] = "Bearer a-long-random-token"
    r.body.extend(body.as_bytes())
    return r^


def vec(a: Float64, b: Float64) -> List[Float64]:
    var v = List[Float64]()
    v.append(a)
    v.append(b)
    v.append(0.0)
    v.append(0.0)
    return v^


def main() raises:
    var emb = StubEmbedder(4)
    emb.add_vector("Ada Lovelace", vec(1.0, 0.0))
    emb.add_vector("Acme Labs", vec(0.0, 1.0))
    emb.add_vector("Ada", vec(1.0, 0.0))
    var llm = StubLlmClient()
    llm.add_synthesis(
        DEFAULT_SYNTHESIS_PROMPT,
        "QUESTION: Ada\n\nEVIDENCE PACK\nEntities:\n- Ada Lovelace (entity)\n"
        "- Acme Labs (entity)\nRelations:\n"
        "- Ada Lovelace -> Acme Labs: Ada Lovelace works_at Acme Labs\n",
        "Ada works at Acme Labs.",
    )
    var server = CaptureDispatcher(
        KgSnapshotStore[SharedInMemoryConditionalStore](SharedInMemoryConditionalStore(), "graph"),
        llm^,
        emb^,
        EmptyAdapterRegistry(),
        NoRoutes(),
        FixedClock(Int64(1_000)),
        CaptureConfig("a-long-random-token", "default", 4096, 32, IngestConfig.default()),
        QueryConfig.default(),
    )
    var reactor = Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), backend())

    var written = server.dispatch[BlockingRuntime[NoopSink]](
        reactor,
        post(
            "/ingest-structured",
            '{"entities":[{"name":"Ada Lovelace"},{"name":"Acme Labs"}],'
            '"edges":[{"subject":"Ada Lovelace","predicate":"works_at","object":"Acme Labs"}]}',
        ),
    )
    assert_equal(Int(written.status), 200)

    # The partition is the server's default; "Ada" is found in an entity's name.
    var found = server.dispatch[BlockingRuntime[NoopSink]](reactor, post("/query", '{"q":"Ada"}'))
    assert_equal(Int(found.status), 200)
    var doc = parse_json_bytes(found.body)
    assert_equal(doc.get("answer").as_string(), "Ada works at Acme Labs.")
    assert_equal(doc.get("nodes").array_len(), 2)
    assert_equal(doc.get("edges").array_len(), 1)
```

A host's route over the loaded working set:

```mojo module
from std.testing import assert_equal

from komira_http_core.codec import HttpMethod, HttpRequest, HttpResponse
from komira_json import JsonValue
from komira_kg import SnapshotWorkingSet
from komira_kg_capture import CaptureRoutes, json_response


struct SizeRoute(CaptureRoutes):
    def __init__(out self):
        pass

    def handles(self, method: HttpMethod, path: String) -> Bool:
        return method == HttpMethod.get() and path == "/graph/size"

    def handle(
        mut self,
        var request: HttpRequest,
        working_set: SnapshotWorkingSet,
        now_ms: Int64,
    ) raises -> HttpResponse:
        var out = JsonValue.empty_object()
        out.set_member("entities", JsonValue.from_i64(Int64(working_set.num_entities())))
        return json_response(Int32(200), out^)


def main() raises:
    var route = SizeRoute()
    assert_equal(route.handles(HttpMethod.get(), "/graph/size"), True)
    assert_equal(route.handles(HttpMethod.post(), "/graph/size"), False)
    var empty = SnapshotWorkingSet(4)
    var reply = route.handle(HttpRequest(HttpMethod.get(), "/graph/size"), empty, Int64(0))
    assert_equal(String(from_utf8_lossy=Span(reply.body)), '{"entities":0}')
```

A wall-clock `CaptureClock` is the host's to write, over `komira_clock`. The
server is given it like any other; a test gives it a fixed or stepping one.

```mojo module
from std.testing import assert_equal

from komira_clock import now_unix_ms
from komira_kg_capture import CaptureClock, FixedClock, StepClock


struct WallClock(CaptureClock):
    def __init__(out self):
        pass

    def now_ms(mut self) -> Int64:
        return now_unix_ms()


def main() raises:
    var wall = WallClock()  # built and handed to a server; never read here
    _ = wall^
    var step = StepClock(Int64(10), Int64(5))
    assert_equal(step.now_ms(), Int64(10))
    assert_equal(step.now_ms(), Int64(15))
    var fixed = FixedClock(Int64(3))
    assert_equal(fixed.now_ms(), Int64(3))
```
