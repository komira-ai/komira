# =============================================================================
# test_structured_route.mojo -- POST /ingest-structured.
# =============================================================================
#
# Known entities and edges as JSON, ingested with no extraction: the server's
# model client here fails if it is ever asked to extract. The dispatcher is
# called directly, over a stub embedder and an in-memory store.
#
#   ingest      the entities and edges become the graph, the response counts
#               what was supplied, what the graph holds and what was added.
#   time        the server's clock is the ingest time, whatever the body says;
#               a body without a time takes the clock as the event time and an
#               edge without one the episode's.
#   partition   query first, then body, then the server's default.
#   envelope    uuid, note and facet reach the episode row.
#   repeat      the same body twice adds nothing; a source that stops stating an
#               edge closes it.
#   refusals    an empty body, malformed JSON, a missing or mistyped field, a
#               bad partition or uuid: 400, and nothing written.
# =============================================================================

from std.sys.info import CompilationTarget
from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_KQUEUE, Reactor
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_http_core.codec import HttpMethod, HttpRequest, HttpResponse
from komira_http_server.dispatch import RequestDispatcher
from komira_json import JsonValue, parse_json_bytes
from komira_kg import (
    EpisodeInput,
    IngestConfig,
    SnapshotWorkingSet,
    StubEmbedder,
    LlmClient,
    StubLlmClient,
)
from komira_kg_capture import (
    CaptureConfig,
    CaptureDispatcher,
    FixedClock,
    NoRoutes,
    StepClock,
)
from komira_kg_format import (
    EntityMention,
    Extraction,
    KgSnapshotStore,
    TS_OPEN_SENTINEL,
    Triple,
)
from komira_kg_sources import (
    EmptyAdapterRegistry,
    RawSurfaceAdapter,
    RegisteredAdapter,
    register,
)
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)

comptime Backend = SharedInMemoryConditionalStore
comptime Kg = KgSnapshotStore[SharedInMemoryConditionalStore]
comptime DIM = 4
comptime TOKEN = "tok-test-1"
comptime TEXT1 = "Ada Lovelace works at Acme Labs."
comptime TEXT2 = "Ada Lovelace hired Bolt Co."
comptime ADA = "Ada Lovelace"
comptime ACME = "Acme Labs"
comptime BOLT = "Bolt Co"


@fieldwise_init
struct JournalEntry(Copyable, Movable):
    """One line of a made-up journal: the time it describes and its text."""

    var time: Int64
    var text: String


@fieldwise_init
struct Journal(Movable):
    """A made-up record: an id and dated entries."""

    var id: String
    var entries: List[JournalEntry]


@fieldwise_init
struct Card(Movable):
    """A second made-up record: a title and free text."""

    var title: String
    var text: String


def _lines(raw: List[UInt8]) -> List[String]:
    var out = List[String]()
    var cur = List[UInt8]()
    for i in range(len(raw)):
        if raw[i] == UInt8(10):
            out.append(String(unsafe_from_utf8=Span(cur)))
            cur.clear()
        else:
            cur.append(raw[i])
    out.append(String(unsafe_from_utf8=Span(cur)))
    return out^


def _entry(line: String) raises -> JournalEntry:
    var b = line.as_bytes()
    var time = Int64(0)
    var at = 0
    while at < len(b) and b[at] != UInt8(124):
        var d = Int(b[at]) - 48
        if d < 0 or d > 9:
            raise Error("journal entry SECRET-DETAIL has no numeric time")
        time = time * Int64(10) + Int64(d)
        at += 1
    if at == len(b) or at == 0:
        raise Error("journal entry SECRET-DETAIL is not time|text")
    var text = List[UInt8]()
    for i in range(at + 1, len(b)):
        text.append(b[i])
    return JournalEntry(time, String(unsafe_from_utf8=Span(text)))


struct JournalAdapter(RawSurfaceAdapter):
    """Reads `id`, then one `time|text` line per entry; one episode per entry."""

    comptime Source = Journal

    def __init__(out self):
        pass

    def surface_tag(self) -> String:
        return "test.journal"

    def parse(self, raw: List[UInt8]) raises -> Journal:
        var lines = _lines(raw)
        if len(lines[0].as_bytes()) == 0:
            raise Error("journal has no id")
        var entries = List[JournalEntry]()
        for i in range(1, len(lines)):
            entries.append(_entry(lines[i]))
        return Journal(lines[0].copy(), entries^)

    def lower(
        self, var source: Journal, partition_id: String
    ) raises -> List[EpisodeInput]:
        var out = List[EpisodeInput]()
        for i in range(len(source.entries)):
            out.append(
                EpisodeInput(
                    source.id + "#" + String(i),
                    partition_id,
                    source.entries[i].text.copy(),
                    Int64(1),
                    source.entries[i].time,
                    "journal",
                    source.id,
                )
            )
        return out^


struct CardAdapter(RawSurfaceAdapter):
    """Reads a title line and then the text; one episode holding the text."""

    comptime Source = Card

    def __init__(out self):
        pass

    def surface_tag(self) -> String:
        return "test.card"

    def parse(self, raw: List[UInt8]) raises -> Card:
        var lines = _lines(raw)
        if len(lines) < 2:
            raise Error("card has no text")
        var text = String("")
        for i in range(1, len(lines)):
            if i > 1:
                text += "\n"
            text += lines[i]
        return Card(lines[0].copy(), text^)

    def lower(
        self, var source: Card, partition_id: String
    ) raises -> List[EpisodeInput]:
        var out = List[EpisodeInput]()
        out.append(
            EpisodeInput(
                "card:" + source.title,
                partition_id,
                source.text.copy(),
                Int64(1),
                Int64(7),
            )
        )
        return out^


comptime Registry = RegisteredAdapter[
    CardAdapter, RegisteredAdapter[JournalAdapter, EmptyAdapterRegistry]
]


def _registry() raises -> Registry:
    return register(
        register(EmptyAdapterRegistry(), JournalAdapter()), CardAdapter()
    )


def _vec(a: Float64, b: Float64, c: Float64, d: Float64) -> List[Float64]:
    var v = List[Float64]()
    v.append(a)
    v.append(b)
    v.append(c)
    v.append(d)
    return v^


def _emb() raises -> StubEmbedder:
    var emb = StubEmbedder(DIM)
    emb.add_vector(ADA, _vec(1.0, 0.0, 0.0, 0.0))
    emb.add_vector(ACME, _vec(0.0, 1.0, 0.0, 0.0))
    emb.add_vector(BOLT, _vec(0.0, 0.0, 1.0, 0.0))
    return emb^


def _ext1() -> Extraction:
    var ms = List[EntityMention]()
    ms.append(EntityMention(ADA, "person", "an analyst"))
    ms.append(EntityMention(ACME, "org", ""))
    var ts = List[Triple]()
    ts.append(Triple(ADA, "works_at", ACME, "Ada Lovelace works at Acme Labs", Int64(100), TS_OPEN_SENTINEL))
    return Extraction(ms^, ts^)


def _ext2() -> Extraction:
    var ms = List[EntityMention]()
    ms.append(EntityMention(BOLT, "org", ""))
    var ts = List[Triple]()
    ts.append(Triple(ADA, "hired", BOLT, "Ada Lovelace hired Bolt Co", Int64(200), TS_OPEN_SENTINEL))
    return Extraction(ms^, ts^)


def _llm() -> StubLlmClient:
    var llm = StubLlmClient()
    llm.add_extraction_any_context(TEXT1, _ext1())
    llm.add_extraction_any_context(TEXT2, _ext2())
    return llm^


def _config(fold: Int = 100) raises -> CaptureConfig:
    return CaptureConfig(TOKEN, "default-p", 4096, fold, IngestConfig.default())


def _backend() -> UInt8:
    comptime if CompilationTarget.is_linux():
        return BACKEND_EPOLL
    return BACKEND_KQUEUE


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(s.as_bytes())
    return out^


def _request(
    method: HttpMethod, path: String, query: String, body: String, token: String
) -> HttpRequest:
    var r = HttpRequest(method, path)
    r.query_string = query
    r.body = _bytes(body)
    if len(token.as_bytes()) > 0:
        r.headers["authorization"] = "Bearer " + token
    return r^


def _post(path: String, query: String, body: String) -> HttpRequest:
    return _request(HttpMethod.post(), path, query, body, TOKEN)


def _call[D: RequestDispatcher](mut server: D, var req: HttpRequest) raises -> HttpResponse:
    var reactor = Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), _backend())
    return server.dispatch[BlockingRuntime[NoopSink]](reactor, req^)


def _json(r: HttpResponse) raises -> JsonValue:
    return parse_json_bytes(r.body)


def _text(r: HttpResponse) -> String:
    return String(from_utf8_lossy=Span(r.body))


struct TrapLlm(LlmClient):
    """A model client that fails if the server ever asks it to extract."""

    def __init__(out self):
        pass

    def extract(
        self, text: String, already_found: List[EntityMention]
    ) raises -> Extraction:
        raise Error("the extractor must not run on a structured ingest")

    def judge_contradiction(self, new_fact: String, old_fact: String) raises -> Bool:
        return False

    def judge_same_entity(
        self, name_a: String, summary_a: String, name_b: String, summary_b: String
    ) raises -> Bool:
        return False

    def has_synthesis(self) -> Bool:
        return False

    def synthesize(self, system_prompt: String, user_prompt: String) raises -> String:
        raise Error("no synthesis")


comptime Server = CaptureDispatcher[
    Backend, TrapLlm, StubEmbedder, Registry, NoRoutes, FixedClock
]


def _server(now: Int64 = 5000) raises -> Server:
    return Server(
        Kg(Backend(), "g"), TrapLlm(), _emb(), _registry(), NoRoutes(), FixedClock(now), _config()
    )


def _push(mut server: Server, query: String, body: String) raises -> HttpResponse:
    return _call(server, _post("/ingest-structured", query, body))


comptime BODY = (
    '{"entities":[{"name":"Ada Lovelace","type":"person","summary":"an analyst"},'
    '{"name":"Acme Labs","type":"org"}],'
    '"edges":[{"subject":"Ada Lovelace","predicate":"works_at","object":"Acme Labs"}]}'
)


def test_known_entities_and_edges_are_ingested_without_the_extractor() raises:
    var server = _server(5000)
    var r = _push(server, "", BODY)
    assert_equal(Int(r.status), 200)
    var doc = _json(r)
    assert_equal(doc.get("mode").as_string(), "structured")
    assert_equal(doc.get("partition_id").as_string(), "default-p")
    assert_equal(doc.get("entities_supplied").as_int64(), Int64(2))
    assert_equal(doc.get("edges_supplied").as_int64(), Int64(1))
    assert_equal(doc.get("entities_total").as_int64(), Int64(2))
    assert_equal(doc.get("entities_added").as_int64(), Int64(2))
    assert_equal(doc.get("edges_total").as_int64(), Int64(1))
    assert_equal(doc.get("edges_added").as_int64(), Int64(1))
    assert_equal(doc.get("snapshot_id").as_int64(), server.store_ref().latest_snapshot_id())

    var ws = SnapshotWorkingSet.load_latest(server.store_ref())
    assert_equal(ws.entities[0].name, "Ada Lovelace")
    assert_equal(ws.entities[0].summary, "an analyst")
    assert_equal(ws.entities[1].name, "Acme Labs")
    assert_equal(ws.edges[0].fact, "Ada Lovelace works_at Acme Labs")
    assert_equal(ws.num_episodes(), 1)
    assert_equal(ws.episodes[0].uuid, "structured")
    assert_equal(ws.episodes[0].partition_id, "default-p")


def test_the_clock_stamps_the_ingest_time_and_the_default_event_time() raises:
    var server = _server(5000)
    _ = _push(server, "", BODY)
    var ws = SnapshotWorkingSet.load_latest(server.store_ref())
    assert_equal(ws.episodes[0].ts, Int64(5000))
    assert_equal(ws.episodes[0].valid_at, Int64(5000))  # no valid_at in the body
    assert_equal(ws.edges[0].created_at, Int64(5000))
    assert_equal(ws.edges[0].valid_at, Int64(5000))  # the edge took the episode's

    var dated = _server(5000)
    _ = _push(
        dated,
        "",
        '{"entities":[],"edges":[{"subject":"A","predicate":"p","object":"B","valid_at":70},'
        '{"subject":"A","predicate":"q","object":"C"}],"valid_at":60}',
    )
    var ws2 = SnapshotWorkingSet.load_latest(dated.store_ref())
    assert_equal(ws2.episodes[0].ts, Int64(5000))  # a body cannot set the ingest time
    assert_equal(ws2.episodes[0].valid_at, Int64(60))
    assert_equal(ws2.edges[0].valid_at, Int64(70))  # its own
    assert_equal(ws2.edges[1].valid_at, Int64(60))  # the episode's


def test_the_partition_comes_from_the_query_then_the_body_then_the_default() raises:
    var server = _server()
    _ = _push(server, "partition=from-query", '{"entities":[],"edges":[{"subject":"A","predicate":"p","object":"B"}],"partition":"from-body","uuid":"u1"}')
    _ = _push(server, "", '{"entities":[],"edges":[{"subject":"A","predicate":"p","object":"C"}],"partition":"from-body","uuid":"u2"}')
    _ = _push(server, "", '{"entities":[],"edges":[{"subject":"A","predicate":"p","object":"D"}],"uuid":"u3"}')
    var ws = SnapshotWorkingSet.load_latest(server.store_ref())
    assert_equal(ws.episodes[0].partition_id, "from-query")
    assert_equal(ws.episodes[1].partition_id, "from-body")
    assert_equal(ws.episodes[2].partition_id, "default-p")


def test_the_envelope_reaches_the_episode_row() raises:
    var server = _server()
    _ = _push(
        server,
        "",
        '{"entities":[],"edges":[{"subject":"A","predicate":"p","object":"B"}],'
        '"uuid":"u-7","body":"a provenance note","facet":"f-1","facet_source":"fs-1"}',
    )
    var ws = SnapshotWorkingSet.load_latest(server.store_ref())
    assert_equal(ws.episodes[0].uuid, "u-7")
    assert_equal(ws.episodes[0].body, "a provenance note")
    assert_equal(ws.episodes[0].facet, "f-1")


def test_a_repeat_adds_nothing_and_a_source_replaces_what_it_held() raises:
    var server = _server()
    _ = _push(server, "", BODY)
    var again = _json(_push(server, "", BODY))
    assert_equal(again.get("entities_added").as_int64(), Int64(0))
    assert_equal(again.get("edges_added").as_int64(), Int64(0))

    var two = _server()
    _ = _push(
        two,
        "",
        '{"entities":[],"edges":[{"subject":"A","predicate":"p","object":"B"},'
        '{"subject":"A","predicate":"p","object":"C"}],"source":"s1","uuid":"u1"}',
    )
    _ = _push(
        two,
        "",
        '{"entities":[],"edges":[{"subject":"A","predicate":"p","object":"B"}],'
        '"source":"s1","uuid":"u2"}',
    )
    var ws = SnapshotWorkingSet.load_latest(two.store_ref())
    var open_edges = 0
    for i in range(ws.num_edges()):
        if ws.edges[i].invalid_at == TS_OPEN_SENTINEL and ws.edges[i].expired_at == TS_OPEN_SENTINEL:
            open_edges += 1
            assert_equal(ws.edges[i].fact, "A p B")
    assert_equal(open_edges, 1)  # the edge to C, which the source stopped stating, is closed


def test_a_bad_body_is_refused_with_a_description_of_the_body() raises:
    var server = _server()
    var r = _push(server, "", "")
    assert_equal(Int(r.status), 400)
    assert_equal(_json(r).get("error").as_string(), "the body must hold a JSON object")
    var bodies = List[String]()
    var parts = List[String]()
    bodies.append('{"entities":[')
    parts.append("malformed body: JsonError")
    bodies.append('{"edges":[]}')
    parts.append("malformed body: 'entities' is required")
    bodies.append('{"entities":[],"edges":[{"subject":"A"}]}')
    parts.append("malformed body: edges[0] needs")
    bodies.append('{"entities":[],"edges":[],"valid_at":"7"}')
    parts.append("malformed body: 'valid_at' must be an integer")
    for i in range(len(bodies)):
        var bad = _push(server, "", bodies[i])
        assert_equal(Int(bad.status), 400)
        assert_true(parts[i] in _json(bad).get("error").as_string())
    assert_equal(server.store_ref().latest_snapshot_id(), Int64(-1))


def test_a_bad_partition_or_uuid_is_refused() raises:
    var server = _server()
    var q = _push(server, "partition=%FF", BODY)
    assert_equal(Int(q.status), 400)
    assert_equal(_json(q).get("error").as_string(), "the query string is malformed")
    var p = _push(server, "partition=a%0Ab", BODY)
    assert_equal(Int(p.status), 400)
    assert_equal(_json(p).get("error").as_string(), "partition must not hold a control byte")
    var u = _push(server, "", '{"entities":[],"edges":[],"uuid":""}')
    assert_equal(Int(u.status), 400)
    assert_equal(_json(u).get("error").as_string(), "uuid must not be empty")
    assert_equal(server.store_ref().latest_snapshot_id(), Int64(-1))


def test_a_server_with_no_host_routes_serves_nothing_else() raises:
    var server = _server()
    var r = _call(server, _request(HttpMethod.get(), "/anything", "", "", TOKEN))
    assert_equal(Int(r.status), 404)
    assert_equal(_json(r).get("error").as_string(), "no such route")
    var none = NoRoutes()
    assert_false(none.handles(HttpMethod.get(), "/anything"))
    with assert_raises(contains="no route"):
        _ = none.handle(HttpRequest(HttpMethod.get(), "/anything"), SnapshotWorkingSet(DIM), Int64(0))


def test_a_body_with_no_entities_and_no_edges_is_accepted() raises:
    var server = _server()
    var r = _push(server, "", '{"entities":[],"edges":[]}')
    assert_equal(Int(r.status), 200)
    var doc = _json(r)
    assert_equal(doc.get("entities_supplied").as_int64(), Int64(0))
    assert_equal(doc.get("edges_supplied").as_int64(), Int64(0))
    assert_equal(doc.get("entities_total").as_int64(), Int64(0))
    assert_equal(doc.get("edges_total").as_int64(), Int64(0))
    # The server still takes a real push after it.
    assert_equal(Int(_push(server, "", BODY).status), 200)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
