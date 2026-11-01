# =============================================================================
# test_query_loopback.mojo -- the query routes over a socket on an ephemeral port.
# =============================================================================
#
# An `HttpServer` on 127.0.0.1 with the capture dispatcher, and a blocking client
# on libc sockets in the same thread. The client sends a request, then the test
# steps the server (a poll with a zero timeout) and reads without waiting until
# the whole reply is in; the bound is a number of steps. No sleep, no clock.
#
#   query      a write over the wire, then a query and a federated query over
#              the wire answer with the stored graph and the model's answer; a
#              query without the token is 401 and one with an oversize text 413.
# =============================================================================

from std.ffi import external_call

from std.sys.info import CompilationTarget
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_http_core.transport.grpc_emit import NoopGrpcDispatch
from komira_http_server.dispatch import RequestDispatcher
from komira_http_server.routing import Router
from komira_http_server.server import HttpServer, HttpServerConfig
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
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)

comptime Backend = SharedInMemoryConditionalStore
comptime Kg = KgSnapshotStore[SharedInMemoryConditionalStore]
comptime DIM = 4
comptime TOKEN = "tok-test-1"
comptime Server = CaptureDispatcher[
    Backend, StubLlmClient, StubEmbedder, EmptyAdapterRegistry, NoRoutes, FixedClock
]


def _vec(a: Float64, b: Float64, c: Float64, d: Float64) -> List[Float64]:
    var v = List[Float64]()
    v.append(a)
    v.append(b)
    v.append(c)
    v.append(d)
    return v^


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(s.as_bytes())
    return out^


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


def _server() raises -> Server:
    var emb = StubEmbedder(DIM)
    emb.add_vector("Ada Lovelace", _vec(1.0, 0.0, 0.0, 0.0))
    emb.add_vector("Acme Labs", _vec(0.0, 1.0, 0.0, 0.0))
    emb.add_vector("alpha", _vec(1.0, 0.0, 0.0, 0.0))
    var llm = StubLlmClient()
    llm.add_synthesis(
        DEFAULT_SYNTHESIS_PROMPT,
        "QUESTION: alpha\n\nEVIDENCE PACK\nEntities:\n- Ada Lovelace (entity)\n"
        "- Acme Labs (entity)\nRelations:\n"
        "- Ada Lovelace -> Acme Labs: Ada Lovelace works_at Acme Labs\n",
        "the answer",
    )
    return Server(
        Kg(Backend(), "g"),
        llm^,
        emb^,
        EmptyAdapterRegistry(),
        NoRoutes(),
        FixedClock(Int64(5000)),
        CaptureConfig(TOKEN, "default-p", 4096, 100, IngestConfig.default()),
        QueryConfig(String(DEFAULT_SYNTHESIS_PROMPT), 16, 100, 64, 32, 64, 0.5),
    )


def test_over_a_socket_a_write_then_a_query_and_a_federated_query() raises:
    var http = _listening()
    var app = _server()
    var write = _exchange(
        http,
        app,
        _wire(
            "POST",
            "/ingest-structured",
            '{"entities":[{"name":"Ada Lovelace"},{"name":"Acme Labs"}],'
            '"edges":[{"subject":"Ada Lovelace","predicate":"works_at","object":"Acme Labs"}],'
            '"partition":"p1","facet":"fa"}',
            TOKEN,
        ),
    )
    assert_equal(write.status, 200)

    var one = _exchange(
        http, app, _wire("POST", "/query?partition=p1", '{"q":"alpha"}', TOKEN)
    )
    assert_equal(one.status, 200)
    var doc = parse_json_bytes(_bytes(one.body))
    assert_equal(doc.get("answer").as_string(), "the answer")
    assert_equal(doc.get("nodes").array_len(), 2)
    assert_equal(doc.get("nodes").element_at(0).get("label").as_string(), "Ada Lovelace")
    assert_equal(doc.get("edges").array_len(), 1)

    var fed = _exchange(
        http,
        app,
        _wire("POST", "/query-federated", '{"q":"alpha","partitions":["p1"],"facet":"fa"}', TOKEN),
    )
    assert_equal(fed.status, 200)
    var fdoc = parse_json_bytes(_bytes(fed.body))
    assert_equal(fdoc.get("mode").as_string(), "federated_query")
    assert_equal(fdoc.get("provenance").array_len(), 2)

    var none = _exchange(http, app, _wire("POST", "/query?partition=p1", '{"q":"alpha"}', ""))
    assert_equal(none.status, 401)
    assert_false("Ada" in none.body)
    var other = _exchange(http, app, _wire("POST", "/query?partition=p1", '{"q":"alpha"}', "tok-test-2"))
    assert_equal(other.status, 401)

    var text = String("")
    for _ in range(65):
        text += "x"
    var long = _exchange(http, app, _wire("POST", "/query", '{"q":"' + text + '"}', TOKEN))
    assert_equal(long.status, 413)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
