# =============================================================================
# test_auth_limits.mojo -- who may call, how large, by which method.
# =============================================================================
#
# One server with the two built-in write routes and a host's routes. The
# dispatcher is called directly.
#
#   token     a request with no token to every route but health -- the built-in
#             routes, the host's, a path nobody serves and "/" -- by any method is
#             401 with a challenge and the same message, and neither the store
#             nor the host's code is touched; a token that is a prefix, an
#             extension, a different case, another scheme or empty is refused too
#             and never echoed.
#   health    open, GET only, a fixed body, no store access.
#   size      a body over the configured limit is 413 on each write route, one at
#             the limit is not; without the token the oversize request is 401.
#   method    a built-in path by the wrong method is 405 with Allow, but only
#             after the token has been checked.
#   malformed a body that is not JSON is 400 and writes nothing.
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


def _valid_for(path: String) -> String:
    """A body the route would accept, so only the missing token can refuse it."""
    if path == "/capture":
        return "A\n" + TEXT1
    if path == "/ingest-structured":
        return '{"entities":[],"edges":[{"subject":"A","predicate":"p","object":"B"}]}'
    return ""


def _query_for(path: String) -> String:
    if path == "/capture":
        return "surface=test.card"
    return ""


def _routes() -> List[String]:
    var out = List[String]()
    out.append("/capture")
    out.append("/ingest-structured")
    out.append("/graph/size")  # a host's
    out.append("/graph/boom")  # a host's
    out.append("/nothing-here")  # nobody's
    out.append("/")
    return out^


def test_every_route_but_health_refuses_a_request_with_no_token() raises:
    var server = _server()
    var routes = _routes()
    for i in range(len(routes)):
        var path = routes[i]
        for m in range(3):
            var method = HttpMethod.get()
            if m == 1:
                method = HttpMethod.post()
            if m == 2:
                method = HttpMethod.put()
            var req = _request(method, path, _query_for(path), _valid_for(path), "")
            var r = _call(server, req^)
            assert_equal(Int(r.status), 401)
            assert_equal(r.headers["www-authenticate"], "Bearer")
            assert_equal(_json(r).get("error").as_string(), "authentication is required")
    # Nothing was written and the host's code never ran.
    assert_equal(server.store_ref().latest_snapshot_id(), Int64(-1))
    assert_equal(_json(_call(server, _get("/graph/size"))).get("calls").as_int64(), Int64(1))


def test_a_wrong_token_is_refused_in_every_shape() raises:
    var server = _server()
    var heads = List[String]()
    heads.append("Bearer tok-test-")  # a prefix
    heads.append("Bearer tok-test-12")  # an extension
    heads.append("Bearer tok-test-2")  # the same length
    heads.append("Bearer TOK-TEST-1")
    heads.append("Basic tok-test-1")
    heads.append("tok-test-1")
    heads.append("Bearer")
    heads.append("Bearer ")
    heads.append("")
    for i in range(len(heads)):
        for p in range(2):
            var path = String("/capture") if p == 0 else String("/graph/size")
            var req = _request(HttpMethod.post(), path, "surface=test.card", "A\n" + TEXT1, "")
            req.headers["authorization"] = heads[i]
            var r = _call(server, req^)
            assert_equal(Int(r.status), 401)
            assert_false("tok-test-1" in _text(r))  # the token is never echoed
    assert_equal(server.store_ref().latest_snapshot_id(), Int64(-1))
    # The right token, once, reaches the route.
    assert_equal(Int(_call(server, _post("/capture", "surface=test.card", "A\n" + TEXT1)).status), 200)


def test_health_is_open_and_touches_nothing() raises:
    var server = _server()
    var r = _call(server, _get("/health", ""))
    assert_equal(Int(r.status), 200)
    assert_equal(r.headers["content-type"], "application/json")
    assert_equal(_text(r), '{"status":"ok"}')
    # A token that is wrong changes nothing: health does not look at it.
    var wrong = _call(server, _get("/health", "wrong"))
    assert_equal(Int(wrong.status), 200)
    # Only GET: another method is 405 and says so, token or not.
    var post = _call(server, _request(HttpMethod.post(), "/health", "", "", ""))
    assert_equal(Int(post.status), 405)
    assert_equal(post.headers["allow"], "GET")
    assert_equal(server.store_ref().latest_snapshot_id(), Int64(-1))


def test_an_oversize_body_is_refused_and_one_at_the_limit_is_not() raises:
    var server = _server(5000, 64)
    var at_limit = String("")
    for _ in range(64):
        at_limit += "x"
    var over = at_limit + "x"
    # An authenticated request over the limit is 413 on both write routes.
    var write_routes = List[String]()
    write_routes.append("/capture")
    write_routes.append("/ingest-structured")
    for path in write_routes:
        var big = _call(server, _post(path, _query_for(path), over))
        assert_equal(Int(big.status), 413)
        assert_equal(_json(big).get("error").as_string(), "the request body is over 64 bytes")
        # At the limit the size check passes: the route refuses the content instead.
        var edge = _call(server, _post(path, _query_for(path), at_limit))
        assert_true(Int(edge.status) != 413)
    # An unauthenticated oversize request learns only that it is unauthenticated.
    var anon = _call(server, _request(HttpMethod.post(), "/capture", "surface=test.card", over, ""))
    assert_equal(Int(anon.status), 401)
    assert_equal(server.store_ref().latest_snapshot_id(), Int64(-1))


def test_a_known_path_by_the_wrong_method_is_405_after_authentication() raises:
    var server = _server()
    var capture = _call(server, _get("/capture"))
    assert_equal(Int(capture.status), 405)
    assert_equal(capture.headers["allow"], "POST")
    var structured = _call(server, _get("/ingest-structured"))
    assert_equal(Int(structured.status), 405)
    assert_equal(structured.headers["allow"], "POST")
    # Without the token the same requests say nothing about the method.
    assert_equal(Int(_call(server, _get("/capture", "")).status), 401)
    assert_equal(Int(_call(server, _get("/nothing-here")).status), 404)


def test_malformed_json_is_refused_on_the_structured_route() raises:
    var server = _server()
    var r = _call(server, _post("/ingest-structured", "", "{not json"))
    assert_equal(Int(r.status), 400)
    assert_true("malformed body" in _json(r).get("error").as_string())
    assert_equal(server.store_ref().latest_snapshot_id(), Int64(-1))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
