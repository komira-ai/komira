# =============================================================================
# test_loopback.mojo -- the same server over a socket on an ephemeral loopback port.
# =============================================================================
#
# An `HttpServer` on 127.0.0.1 with the capture dispatcher, and a blocking client
# on libc sockets in the same thread. The client sends a request, then the test
# steps the server (a poll with a zero timeout) and reads without waiting until
# the whole reply is in; the bound is a number of steps. No sleep, no clock.
#
#   push       health is open; a capture without the token is 401 and writes
#              nothing; with it, a record becomes an episode stamped with the
#              server's clock; an unregistered surface is 422.
#   routes     a structured ingest, a host route that sees what was written,
#              a host route without the token (401), an oversize body (413) and
#              malformed JSON (400), each over the wire.
# =============================================================================

from std.ffi import external_call

from std.sys.info import CompilationTarget
from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_KQUEUE, Reactor
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_http_core.codec import HttpMethod, HttpRequest, HttpResponse
from komira_http_core.transport.grpc_emit import NoopGrpcDispatch
from komira_http_server.dispatch import RequestDispatcher
from komira_http_server.routing import Router
from komira_http_server.server import HttpServer, HttpServerConfig
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


# --- a blocking client on libc sockets, stepped with the server --------------

comptime _AF_INET: Int32 = 2
comptime _SOCK_STREAM: Int32 = 1
comptime _MAX_STEPS = 20000


def _dont_wait() -> Int32:
    comptime if CompilationTarget.is_macos():
        return Int32(0x80)
    return Int32(0x40)


def _sockaddr_loopback(port: UInt16) -> List[UInt8]:
    var addr = List[UInt8](length=16, fill=UInt8(0))
    comptime if CompilationTarget.is_macos():
        addr[0] = UInt8(16)
        addr[1] = UInt8(_AF_INET)
    else:
        addr[0] = UInt8(_AF_INET)
    addr[2] = UInt8(Int(port >> 8) & 0xFF)
    addr[3] = UInt8(Int(port) & 0xFF)
    addr[4] = UInt8(127)
    addr[7] = UInt8(1)
    return addr^


def _connect(port: UInt16) raises -> Int32:
    var fd = external_call["socket", Int32](_AF_INET, _SOCK_STREAM, Int32(0))
    if fd < Int32(0):
        raise Error("socket() failed")
    var addr = _sockaddr_loopback(port)
    # SAFETY: `addr` lives to the end of this function and connect(2) reads
    # 16 bytes from it.
    var rc = external_call["connect", Int32](fd, addr.unsafe_ptr(), UInt32(16))
    if rc < Int32(0):
        _ = external_call["close", Int32](fd)
        raise Error("connect() failed")
    return fd


def _send_all(fd: Int32, data: List[UInt8]) raises:
    var sent = 0
    while sent < len(data):
        # SAFETY: the pointer addresses `data`, alive for this call, and the
        # length is what remains of it.
        var n = external_call["send", Int64](
            fd, Span(data)[sent:].unsafe_ptr(), UInt64(len(data) - sent), Int32(0)
        )
        if n <= Int64(0):
            raise Error("send() failed")
        sent += Int(n)


def _find(hay: List[UInt8], needle: String) -> Int:
    var nb = needle.as_bytes()
    var i = 0
    while i + len(nb) <= len(hay):
        var same = True
        for j in range(len(nb)):
            if hay[i + j] != nb[j]:
                same = False
                break
        if same:
            return i
        i += 1
    return -1


def _content_length(head: String) -> Int:
    var key = "content-length: "
    var at = head.lower().find(key)
    if at < 0:
        return 0
    var b = head.as_bytes()
    var i = at + key.byte_length()
    var n = 0
    while i < len(b) and b[i] >= 0x30 and b[i] <= 0x39:
        n = n * 10 + Int(b[i]) - 0x30
        i += 1
    return n


struct Reply(Movable):
    var status: Int
    var body: String

    def __init__(out self, status: Int, var body: String):
        self.status = status
        self.body = body^


def _exchange[
    D: RequestDispatcher
](
    mut server: HttpServer[NoopGrpcDispatch], mut dispatcher: D, raw_request: String
) raises -> Reply:
    """Send one request and step the server until the whole reply is in. The
    bound is a count of server steps, not a time."""
    var fd = _connect(server.local_port())
    _send_all(fd, _bytes(raw_request))
    var got = List[UInt8]()
    var buf = List[UInt8](length=4096, fill=UInt8(0))
    var done = False
    for _ in range(_MAX_STEPS):
        _ = server.serve_one_iteration_dispatch[D, BlockingRuntime[NoopSink]](
            dispatcher, Int32(0)
        )
        # SAFETY: `buf` is alive for the call and the length is its size.
        var n = external_call["recv", Int64](
            fd, buf.unsafe_ptr(), UInt64(len(buf)), _dont_wait()
        )
        if n > Int64(0):
            got.extend(Span(buf)[0 : Int(n)])
        var head_end = _find(got, "\r\n\r\n")
        if head_end >= 0:
            var head = String(from_utf8_lossy=Span(got)[0:head_end])
            if len(got) >= head_end + 4 + _content_length(head):
                done = True
                break
        if n == Int64(0):
            break
    _ = external_call["close", Int32](fd)
    assert_true(done, "the reply did not arrive in full")
    var head_end = _find(got, "\r\n\r\n")
    var status = Int(String(from_utf8_lossy=Span(got)[9:12]))
    return Reply(status, String(from_utf8_lossy=Span(got)[head_end + 4 :]))


def _wire(
    method: String, target: String, body: String, token: String
) -> String:
    var out = method + " " + target + " HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n"
    if len(token.as_bytes()) > 0:
        out += "Authorization: Bearer " + token + "\r\n"
    out += "Content-Length: " + String(len(body.as_bytes())) + "\r\n\r\n" + body
    return out^


def _listening() raises -> HttpServer[NoopGrpcDispatch]:
    return HttpServer(HttpServerConfig.default_ephemeral(), Router())


def test_over_a_socket_a_push_becomes_an_episode_and_unauthenticated_is_refused() raises:
    var http = _listening()
    var app = _server(7000)

    var health = _exchange(http, app, _wire("GET", "/health", "", ""))
    assert_equal(health.status, 200)
    assert_equal(health.body, '{"status":"ok"}')

    var denied = _exchange(
        http, app, _wire("POST", "/capture?surface=test.card", "A\n" + TEXT1, "")
    )
    assert_equal(denied.status, 401)
    assert_equal(app.store_ref().latest_snapshot_id(), Int64(-1))

    var pushed = _exchange(
        http, app, _wire("POST", "/capture?surface=test.card&partition=p1", "A\n" + TEXT1, TOKEN)
    )
    assert_equal(pushed.status, 200)
    var doc = parse_json_bytes(_bytes(pushed.body))
    assert_equal(doc.get("episodes_ingested").as_int64(), Int64(1))
    var ws = SnapshotWorkingSet.load_latest(app.store_ref())
    assert_equal(ws.episodes[0].uuid, "card:A")
    assert_equal(ws.episodes[0].partition_id, "p1")
    assert_equal(ws.episodes[0].ts, Int64(7000))

    var unknown = _exchange(
        http, app, _wire("POST", "/capture?surface=nobody", "A\n" + TEXT1, TOKEN)
    )
    assert_equal(unknown.status, 422)


def test_over_a_socket_structured_ingest_a_host_route_and_the_body_limit() raises:
    var http = _listening()
    var app = _server(7000, 200)

    var structured = _exchange(
        http,
        app,
        _wire(
            "POST",
            "/ingest-structured",
            '{"entities":[],"edges":[{"subject":"A","predicate":"p","object":"B"}]}',
            TOKEN,
        ),
    )
    assert_equal(structured.status, 200)
    var size = _exchange(http, app, _wire("GET", "/graph/size", "", TOKEN))
    assert_equal(size.status, 200)
    assert_equal(parse_json_bytes(_bytes(size.body)).get("entities").as_int64(), Int64(2))
    var no_token = _exchange(http, app, _wire("GET", "/graph/size", "", ""))
    assert_equal(no_token.status, 401)

    var big = String("")
    for _ in range(201):
        big += "x"
    var over = _exchange(http, app, _wire("POST", "/ingest-structured", big, TOKEN))
    assert_equal(over.status, 413)

    var bad = _exchange(http, app, _wire("POST", "/ingest-structured", "{not json", TOKEN))
    assert_equal(bad.status, 400)
    assert_true("malformed body" in bad.body)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
