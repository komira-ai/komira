# =============================================================================
# test_capture_route.mojo -- POST /capture over two made-up record types.
# =============================================================================
#
# The package ships no adapter; the two here (a journal of dated lines and a card
# of free text) live in the test, with a stub model and embedder and an in-memory
# store. The dispatcher is called directly; test_loopback sends the same requests
# over a socket. No clock or sleep: the server is given a fixed or stepping clock.
#
#   episode      a push to a registered surface becomes the episodes, entities,
#                edges and provenance row its adapter lowers it to, the text
#                verbatim, the partition as asked.
#   dispatch     the surface tag chooses the adapter: the same bytes lower to
#                different episodes under the two tags; a tag nobody registered
#                (near misses included) is refused with 422 and nothing is
#                written.
#   clock        the server's clock, not the adapter's, stamps the ingest time;
#                it is read once per write and not for a refused request.
#   partition    the default partition when none is asked, a decoded one when
#                asked, an invalid one refused.
#   refusals     a missing surface, a broken query string, an empty body, an
#                adapter that cannot read the record, a record with no episodes:
#                each a fixed message that repeats nothing the adapter said.
#   growth       a second push joins the first's entities, a repeat adds nothing,
#                the chain folds at the configured number of deltas.
#   failure      a model failure is a fixed 500 with no detail, and the next
#                request still works.
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


comptime Server = CaptureDispatcher[
    Backend, StubLlmClient, StubEmbedder, Registry, NoRoutes, FixedClock
]
comptime SteppingServer = CaptureDispatcher[
    Backend, StubLlmClient, StubEmbedder, Registry, NoRoutes, StepClock
]


def _server(now: Int64 = 5000, fold: Int = 100) raises -> Server:
    return Server(
        Kg(Backend(), "g"), _llm(), _emb(), _registry(), NoRoutes(), FixedClock(now), _config(fold)
    )


def _card(title: String, text: String) -> String:
    return title + "\n" + text


def _journal() -> String:
    return "j1\n100|" + TEXT1 + "\n200|" + TEXT2


# --- a failing model client: the error text must not reach the caller --------


struct FlakyLlm(LlmClient):
    """A stub that fails, with a message the server must not repeat, on one text."""

    var inner: StubLlmClient
    var fail_on: String

    def __init__(out self, var inner: StubLlmClient, var fail_on: String):
        self.inner = inner^
        self.fail_on = fail_on^

    def extract(
        self, text: String, already_found: List[EntityMention]
    ) raises -> Extraction:
        if text == self.fail_on:
            raise Error("model endpoint failed: SECRET-DETAIL")
        return self.inner.extract(text, already_found)

    def judge_contradiction(self, new_fact: String, old_fact: String) raises -> Bool:
        return self.inner.judge_contradiction(new_fact, old_fact)

    def judge_same_entity(
        self, name_a: String, summary_a: String, name_b: String, summary_b: String
    ) raises -> Bool:
        return self.inner.judge_same_entity(name_a, summary_a, name_b, summary_b)

    def has_synthesis(self) -> Bool:
        return False

    def synthesize(self, system_prompt: String, user_prompt: String) raises -> String:
        raise Error("no synthesis")


comptime FlakyServer = CaptureDispatcher[
    Backend, FlakyLlm, StubEmbedder, Registry, NoRoutes, FixedClock
]


def test_a_push_to_a_registered_surface_becomes_an_episode() raises:
    var server = _server(5000)
    var r = _call(server, _post("/capture", "surface=test.card&partition=p1", _card("Ada", TEXT1)))
    assert_equal(Int(r.status), 200)
    assert_equal(r.headers["content-type"], "application/json")
    var doc = _json(r)
    assert_equal(doc.get("surface").as_string(), "test.card")
    assert_equal(doc.get("partition_id").as_string(), "p1")
    assert_equal(doc.get("episodes_ingested").as_int64(), Int64(1))
    assert_equal(doc.get("entities_total").as_int64(), Int64(2))
    assert_equal(doc.get("entities_added").as_int64(), Int64(2))
    assert_equal(doc.get("edges_total").as_int64(), Int64(1))
    assert_equal(doc.get("edges_added").as_int64(), Int64(1))
    assert_equal(doc.get("snapshot_id").as_int64(), server.store_ref().latest_snapshot_id())

    var ws = SnapshotWorkingSet.load_latest(server.store_ref())
    assert_equal(ws.num_entities(), 2)
    assert_equal(ws.entities[0].name, ADA)
    assert_equal(ws.entities[0].partition_id, "p1")
    assert_equal(ws.entities[1].name, ACME)
    assert_equal(ws.num_edges(), 1)
    assert_equal(ws.edges[0].fact, "Ada Lovelace works at Acme Labs")
    assert_equal(ws.num_episodes(), 1)
    ref row = ws.episodes[0]
    assert_equal(row.uuid, "card:Ada")
    assert_equal(row.partition_id, "p1")
    assert_equal(row.body, TEXT1)  # the record's text, verbatim
    assert_equal(row.valid_at, Int64(7))  # the adapter's own event time kept


def test_the_servers_clock_stamps_the_ingest_time() raises:
    var server = _server(5000)
    _ = _call(server, _post("/capture", "surface=test.card", _card("Ada", TEXT1)))
    var ws = SnapshotWorkingSet.load_latest(server.store_ref())
    assert_equal(ws.episodes[0].ts, Int64(5000))  # not the adapter's 1
    assert_equal(ws.edges[0].created_at, Int64(5000))

    var other = _server(9123)
    _ = _call(other, _post("/capture", "surface=test.card", _card("Ada", TEXT1)))
    assert_equal(SnapshotWorkingSet.load_latest(other.store_ref()).episodes[0].ts, Int64(9123))


def test_the_clock_is_read_once_per_write_and_not_for_a_refused_request() raises:
    var server = SteppingServer(
        Kg(Backend(), "g"), _llm(), _emb(), _registry(), NoRoutes(), StepClock(Int64(1000), Int64(10)), _config()
    )
    # Refused before any write: no reading is spent.
    assert_equal(Int(_call(server, _post("/capture", "surface=nobody", _card("A", TEXT1))).status), 422)
    assert_equal(Int(_call(server, _post("/capture", "", _card("A", TEXT1))).status), 400)
    _ = _call(server, _post("/capture", "surface=test.card", _card("A", TEXT1)))
    _ = _call(server, _post("/capture", "surface=test.card", _card("B", TEXT2)))
    var ws = SnapshotWorkingSet.load_latest(server.store_ref())
    assert_equal(ws.episodes[0].ts, Int64(1000))
    assert_equal(ws.episodes[1].ts, Int64(1010))


def test_an_unregistered_surface_is_refused_and_nothing_is_written() raises:
    var server = _server()
    var tags = List[String]()
    tags.append("nobody")
    tags.append("test.Card")
    tags.append("test.card ")
    tags.append("test.")
    tags.append("TEST.CARD")
    for tag in tags:
        var r = _call(server, _post("/capture", "surface=" + tag.replace(" ", "%20"), _card("Ada", TEXT1)))
        assert_equal(Int(r.status), 422)
        assert_equal(_json(r).get("error").as_string(), "no adapter is registered for this surface")
    assert_equal(server.store_ref().latest_snapshot_id(), Int64(-1))


def test_the_surface_tag_chooses_the_adapter() raises:
    var server = _server()
    var r = _call(server, _post("/capture", "surface=test.journal&partition=p1", _journal()))
    assert_equal(Int(r.status), 200)
    assert_equal(_json(r).get("episodes_ingested").as_int64(), Int64(2))
    var ws = SnapshotWorkingSet.load_latest(server.store_ref())
    assert_equal(ws.num_episodes(), 2)
    assert_equal(ws.episodes[0].uuid, "j1#0")
    assert_equal(ws.episodes[0].body, TEXT1)
    assert_equal(ws.episodes[0].valid_at, Int64(100))
    assert_equal(ws.episodes[0].facet, "journal")
    assert_equal(ws.episodes[1].uuid, "j1#1")
    assert_equal(ws.episodes[1].valid_at, Int64(200))
    assert_equal(ws.num_entities(), 3)  # Ada resolved across the two episodes

    # The same bytes under the other tag are read by the other adapter: one
    # episode holding the whole text after the first line, none of the first's.
    var other = _server()
    var r2 = _call(other, _post("/capture", "surface=test.card", _journal()))
    assert_equal(Int(r2.status), 200)
    assert_equal(_json(r2).get("episodes_ingested").as_int64(), Int64(1))
    var ws2 = SnapshotWorkingSet.load_latest(other.store_ref())
    assert_equal(ws2.num_episodes(), 1)
    assert_equal(ws2.episodes[0].uuid, "card:j1")
    assert_equal(ws2.episodes[0].body, "100|" + TEXT1 + "\n200|" + TEXT2)
    assert_equal(ws2.episodes[0].facet, "")


def test_the_default_partition_and_a_given_one() raises:
    var server = _server()
    _ = _call(server, _post("/capture", "surface=test.card", _card("Ada", TEXT1)))
    var ws = SnapshotWorkingSet.load_latest(server.store_ref())
    assert_equal(ws.episodes[0].partition_id, "default-p")
    var r = _call(server, _post("/capture", "partition=%C3%A9&surface=test.card", _card("B", TEXT2)))
    assert_equal(Int(r.status), 200)
    assert_equal(_json(r).get("partition_id").as_string(), "é")
    ws = SnapshotWorkingSet.load_latest(server.store_ref())
    assert_equal(ws.episodes[1].partition_id, "é")


def test_a_bad_request_is_refused_without_writing() raises:
    var server = _server()
    var queries = List[String]()
    var bodies = List[String]()
    var messages = List[String]()
    queries.append("surface=")
    bodies.append(_card("A", TEXT1))
    messages.append("the 'surface' query parameter is required")
    queries.append("partition=p")
    bodies.append(_card("A", TEXT1))
    messages.append("the 'surface' query parameter is required")
    queries.append("surface=test.card%")
    bodies.append(_card("A", TEXT1))
    messages.append("the query string is malformed")
    queries.append("surface=test.card&partition=%FF")
    bodies.append(_card("A", TEXT1))
    messages.append("the query string is malformed")
    queries.append("surface=test.card&partition=a%0Ab")
    bodies.append(_card("A", TEXT1))
    messages.append("partition must not hold a control byte")
    queries.append("surface=test.card")
    bodies.append("")
    messages.append("the body must hold one record")
    for i in range(len(queries)):
        var r = _call(server, _post("/capture", queries[i], bodies[i]))
        assert_equal(Int(r.status), 400)
        assert_equal(_json(r).get("error").as_string(), messages[i])
    assert_equal(server.store_ref().latest_snapshot_id(), Int64(-1))


def test_an_adapter_failure_is_a_fixed_400_and_a_record_with_no_episodes_a_422() raises:
    var server = _server()
    var r = _call(server, _post("/capture", "surface=test.journal", "j1\nx|bad"))
    assert_equal(Int(r.status), 400)
    assert_equal(_json(r).get("error").as_string(), "the adapter for this surface could not read the record")
    assert_false("SECRET-DETAIL" in _text(r))  # the adapter's own text stays inside
    var empty = _call(server, _post("/capture", "surface=test.journal", "j1"))
    assert_equal(Int(empty.status), 422)
    assert_equal(_json(empty).get("error").as_string(), "the record lowered to no episodes")
    assert_equal(server.store_ref().latest_snapshot_id(), Int64(-1))


def test_later_pushes_add_to_the_graph_and_a_repeat_adds_nothing() raises:
    var server = _server()
    var first = _json(_call(server, _post("/capture", "surface=test.card&partition=p1", _card("A", TEXT1))))
    var second = _json(_call(server, _post("/capture", "surface=test.card&partition=p1", _card("B", TEXT2))))
    assert_equal(second.get("entities_total").as_int64(), Int64(3))
    assert_equal(second.get("entities_added").as_int64(), Int64(1))  # Ada resolved to the first push's
    assert_equal(second.get("edges_total").as_int64(), Int64(2))
    assert_equal(second.get("edges_added").as_int64(), Int64(1))
    assert_true(second.get("snapshot_id").as_int64() > first.get("snapshot_id").as_int64())

    var again = _json(_call(server, _post("/capture", "surface=test.card&partition=p1", _card("B", TEXT2))))
    assert_equal(again.get("entities_added").as_int64(), Int64(0))
    assert_equal(again.get("edges_added").as_int64(), Int64(0))
    assert_equal(again.get("snapshot_id").as_int64(), second.get("snapshot_id").as_int64())
    var ws = SnapshotWorkingSet.load_latest(server.store_ref())
    assert_equal(ws.num_entities(), 3)
    assert_equal(ws.num_episodes(), 2)


def test_the_chain_is_folded_once_it_holds_the_configured_number_of_deltas() raises:
    var folding = _server(5000, 2)
    var plain = _server(5000, 100)
    for i in range(4):
        var title = String("t") + String(i)
        var text = TEXT1 if i % 2 == 0 else TEXT2
        _ = _call(folding, _post("/capture", "surface=test.card", _card(title, text)))
        _ = _call(plain, _post("/capture", "surface=test.card", _card(title, text)))
    var folded_deltas = folding.store_ref().resolve_head_chain().num_deltas()
    var plain_deltas = plain.store_ref().resolve_head_chain().num_deltas()
    assert_true(folded_deltas < plain_deltas)
    assert_true(folded_deltas < 2 + 1)
    # The same graph either way, and the folding server still answers a push.
    var a = SnapshotWorkingSet.load_latest(folding.store_ref())
    var b = SnapshotWorkingSet.load_latest(plain.store_ref())
    assert_equal(a.num_entities(), b.num_entities())
    assert_equal(a.num_edges(), b.num_edges())
    assert_equal(a.num_episodes(), 4)
    var more = _call(folding, _post("/capture", "surface=test.card", _card("t9", TEXT2)))
    assert_equal(Int(more.status), 200)


def test_a_failed_ingest_is_a_fixed_500_and_the_server_recovers() raises:
    var llm = FlakyLlm(_llm(), "BOOM")
    var server = FlakyServer(
        Kg(Backend(), "g"), llm^, _emb(), _registry(), NoRoutes(), FixedClock(Int64(5000)), _config()
    )
    _ = _call(server, _post("/capture", "surface=test.card", _card("A", TEXT1)))
    # The first episode of the journal is stored before the second fails.
    var r = _call(server, _post("/capture", "surface=test.journal", "j9\n1|" + TEXT2 + "\n2|BOOM"))
    assert_equal(Int(r.status), 500)
    assert_equal(_json(r).get("error").as_string(), "the request could not be completed")
    assert_false("SECRET-DETAIL" in _text(r))
    # The next request merges what the store holds and carries on.
    var ok = _call(server, _post("/capture", "surface=test.card", _card("C", TEXT1 + " ")))
    assert_equal(Int(ok.status), 200)
    var ws = SnapshotWorkingSet.load_latest(server.store_ref())
    assert_equal(ws.num_entities(), 3)
    var doc = _json(ok)
    assert_equal(doc.get("entities_total").as_int64(), Int64(3))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
