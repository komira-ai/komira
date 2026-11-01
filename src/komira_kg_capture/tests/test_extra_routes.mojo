# =============================================================================
# test_extra_routes.mojo -- a host's routes through CaptureRoutes.
# =============================================================================
#
# The routes here (a size read over the working set, one that raises, and one that
# claims the server's own paths) are made up for the test.
#
#   served      a registered route is answered from the working set the server
#               lends it: empty, of the embedder's width, before the first
#               write, and current after each write; the server's clock reaches
#               it.
#   unregistered a path no route claims, and a registered path by another
#               method, is 404 and never reaches the host.
#   guarded     a host route needs the token and respects the body limit before
#               the host sees the request.
#   precedence  /health and /capture stay the server's even when a host claims
#               them.
#   failure     a host route that raises is a fixed 500.
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
    StubLlmClient,
)
from komira_kg_capture import (
    CaptureConfig,
    CaptureDispatcher,
    FixedClock,
    CaptureRoutes,
    NoRoutes,
    StepClock,
    json_response,
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


struct HostRoutes(CaptureRoutes):
    """A host's routes: GET /graph/size answers from the working set it is lent,
    /graph/boom raises, and /capture and /health are claimed too (the server's
    own routes must win)."""

    var calls: Int

    def __init__(out self):
        self.calls = 0

    def handles(self, method: HttpMethod, path: String) -> Bool:
        if path == "/graph/size":
            return method == HttpMethod.get()
        return path == "/graph/boom" or path == "/capture" or path == "/health"

    def handle(
        mut self,
        var request: HttpRequest,
        working_set: SnapshotWorkingSet,
        now_ms: Int64,
    ) raises -> HttpResponse:
        self.calls += 1
        if request.path == "/graph/boom":
            raise Error("host failure: SECRET-DETAIL")
        var out = JsonValue.empty_object()
        out.set_member("route", JsonValue.from_string("host"))
        out.set_member("entities", JsonValue.from_i64(Int64(working_set.num_entities())))
        out.set_member("dimension", JsonValue.from_i64(Int64(working_set.embedding_dim)))
        out.set_member("now", JsonValue.from_i64(now_ms))
        out.set_member("calls", JsonValue.from_i64(Int64(self.calls)))
        return json_response(Int32(200), out^)


comptime Server = CaptureDispatcher[
    Backend, StubLlmClient, StubEmbedder, Registry, HostRoutes, FixedClock
]


def _server(now: Int64 = 5000, max_body: Int = 4096) raises -> Server:
    return Server(
        Kg(Backend(), "g"),
        _llm(),
        _emb(),
        _registry(),
        HostRoutes(),
        FixedClock(now),
        CaptureConfig(TOKEN, "default-p", max_body, 100, IngestConfig.default()),
    )


def _get(path: String, token: String = TOKEN) -> HttpRequest:
    return _request(HttpMethod.get(), path, "", "", token)


def test_a_registered_route_is_served_over_the_loaded_working_set() raises:
    var server = _server(5000)
    # Nothing written yet: the route is lent an empty set of the embedder's width.
    var empty = _json(_call(server, _get("/graph/size")))
    assert_equal(empty.get("route").as_string(), "host")
    assert_equal(empty.get("entities").as_int64(), Int64(0))
    assert_equal(empty.get("dimension").as_int64(), Int64(DIM))
    assert_equal(empty.get("now").as_int64(), Int64(5000))
    assert_equal(empty.get("calls").as_int64(), Int64(1))

    _ = _call(server, _post("/capture", "surface=test.card", "A\n" + TEXT1))
    var one = _json(_call(server, _get("/graph/size")))
    assert_equal(one.get("entities").as_int64(), Int64(2))
    assert_equal(one.get("dimension").as_int64(), Int64(DIM))
    _ = _call(server, _post("/capture", "surface=test.card", "B\n" + TEXT2))
    var two = _json(_call(server, _get("/graph/size")))
    assert_equal(two.get("entities").as_int64(), Int64(3))  # sees the latest write
    assert_equal(two.get("calls").as_int64(), Int64(3))
    # Reading does not disturb the writes that follow.
    var more = _call(server, _post("/capture", "surface=test.card", "C\n" + TEXT1 + "!"))
    assert_equal(Int(more.status), 200)


def test_a_route_nobody_registered_is_not_there() raises:
    var server = _server()
    var r = _call(server, _get("/graph/other"))
    assert_equal(Int(r.status), 404)
    assert_equal(_json(r).get("error").as_string(), "no such route")
    # The route is registered for GET only: the same path by POST is not served.
    var post = _call(server, _post("/graph/size", "", ""))
    assert_equal(Int(post.status), 404)
    var counted = _json(_call(server, _get("/graph/size")))
    assert_equal(counted.get("calls").as_int64(), Int64(1))  # neither reached the host


def test_a_host_route_needs_the_token_and_the_body_limit() raises:
    var server = _server(5000, 8)
    assert_equal(Int(_call(server, _get("/graph/size", "")).status), 401)
    assert_equal(Int(_call(server, _get("/graph/size", "wrong")).status), 401)
    var big = _request(HttpMethod.get(), "/graph/size", "", "123456789", TOKEN)
    assert_equal(Int(_call(server, big^).status), 413)
    var fits = _request(HttpMethod.get(), "/graph/size", "", "12345678", TOKEN)
    var ok = _call(server, fits^)
    assert_equal(Int(ok.status), 200)
    # Only the one request that passed both checks reached the host.
    assert_equal(_json(ok).get("calls").as_int64(), Int64(1))


def test_the_servers_own_routes_win_over_a_host_that_claims_them() raises:
    var server = _server()
    var health = _call(server, _get("/health", ""))
    assert_equal(Int(health.status), 200)
    assert_equal(_json(health).get("status").as_string(), "ok")
    var capture = _call(server, _get("/capture"))  # the host claims /capture too
    assert_equal(Int(capture.status), 405)
    var counted = _json(_call(server, _get("/graph/size")))
    assert_equal(counted.get("calls").as_int64(), Int64(1))


def test_a_failing_host_route_is_a_fixed_500() raises:
    var server = _server()
    var r = _call(server, _get("/graph/boom"))
    assert_equal(Int(r.status), 500)
    assert_equal(_json(r).get("error").as_string(), "the request could not be completed")
    assert_false("SECRET-DETAIL" in _text(r))
    # The server still serves after it.
    assert_equal(Int(_call(server, _get("/graph/size")).status), 200)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
