# =============================================================================
# test_localmodel_server_daemon.mojo
#   A server assembled around one EMBEDDING model. Binds an HttpServer on a
#   loopback ephemeral port with the ControlApiDispatcher over a
#   BackendSupervisor (STUB embedder backend + STUB forwarder + a VIRTUAL
#   clock), drives a same-process raw-socket HTTP client, and asserts that the
#   /v1/embeddings passthrough loads and forwards, that the rich list rates the
#   embedder GREEN, and that the per-iteration idle-unload tick fires (in
#   virtual time).
# =============================================================================
#
# WHAT THIS PROVES:
#   (a) GET  /models                 -> the embedder advertised + rated GREEN.
#   (b) POST /v1/embeddings {"model":"<embed>","input":[...]}  -> the
#       PASSTHROUGH: loads the embedder (REGISTERED -> SERVING) + forwards the
#       body to its /v1/embeddings endpoint (the STUB forwarder records the
#       base_url + PATH it was handed + returns a canned embeddings response),
#       on the same loopback port as the control verbs.
#   (c) the FORWARDER was handed the /v1/embeddings PATH (not
#       /v1/chat/completions): the forwarder is path-generic.
#   (d) THE IDLE-UNLOAD TICK: after the embedder is SERVING, advancing the
#       virtual clock past the keep_alive TTL + calling
#       dispatcher.tick_idle_unload() (what a serve loop calls each iteration)
#       unloads the embedder (SERVING -> REGISTERED, teardown ran). A tick
#       WITHIN the TTL leaves it SERVING (the tick is a real sweep, not a blind
#       unload), and a later request loads it again.
#   (e) error paths: no model -> 400; an absent model -> 404.
#
# The backend and forwarder are in-process stubs; the clock is virtual, so the
# idle-unload assertion needs no sleep.
# =============================================================================

from std.ffi import external_call
from std.memory import UnsafePointer
from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_true, assert_false

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime

from komira_http_core.transport import NoopGrpcDispatch
from komira_http_server.routing import Router
from komira_http_server.server import HttpServer, HttpServerConfig

from komira_localmodel import (
    BackendSupervisor,
    LocalBackend,
    MonotonicClock,
    ControlApiDispatcher,
    OpenAiForwarder,
    ForwardedResponse,
    HostMemoryProfile,
    PLATFORM_MACOS,
    fit,
    ModelVariant,
    LM_SERVING,
    LM_REGISTERED,
)


# =============================================================================
# §0 — STUB embedder backend + STUB embeddings forwarder + a VIRTUAL clock.
# =============================================================================
struct StubEmbedBackend(LocalBackend, Movable, Deinitable):
    """A fake embedder LocalBackend: launch() flips an up-flag + returns the
    configured base_url; teardown() flips it down + counts. No real process."""

    var _base_url: String
    var _up: Bool
    var launch_count: Int
    var teardown_count: Int

    def __init__(out self, base_url: String):
        self._base_url = base_url
        self._up = False
        self.launch_count = 0
        self.teardown_count = 0

    def launch(mut self) raises -> String:
        self._up = True
        self.launch_count += 1
        return self._base_url

    def health(self) -> Bool:
        return self._up

    def teardown(mut self):
        self._up = False
        self.teardown_count += 1

    def base_url(self) -> String:
        return self._base_url


struct StubEmbedForwarder(OpenAiForwarder, Movable, Deinitable):
    """A fake OpenAiForwarder: records the (base_url, path) it was last handed +
    returns a canned OpenAI EMBEDDINGS response. So the /v1/embeddings passthrough
    is fully testable with no live engine."""

    var last_base_url: String
    var last_path: String
    var forward_count: Int

    def __init__(out self):
        self.last_base_url = String("")
        self.last_path = String("")
        self.forward_count = 0

    def forward(
        mut self, base_url: String, path: String, request_body: String
    ) raises -> ForwardedResponse:
        self.last_base_url = base_url
        self.last_path = path
        self.forward_count += 1
        _ = request_body
        # A canned OpenAI embeddings response body.
        return ForwardedResponse.json(
            200,
            String(
                '{"object":"list","model":"bge-small-en-v1.5","data":['
                + '{"object":"embedding","index":0,"embedding":[0.1,0.2,0.3]}]}'
            ),
        )


struct MockClock(MonotonicClock, Movable, Deinitable):
    """A virtual clock: starts at `start_ms`, only advances via advance_ms (so
    the idle-unload tick assertion steps deterministic virtual time, no sleep)."""

    var _now_ms: Int

    def __init__(out self, start_ms: Int):
        self._now_ms = start_ms

    def now_ms(mut self) -> Int:
        return self._now_ms

    def advance_ms(mut self, delta_ms: Int):
        self._now_ms = self._now_ms + delta_ms


comptime _Rt = BlockingRuntime[NoopSink]
comptime _Dispatcher = ControlApiDispatcher[
    StubEmbedBackend, MockClock, StubEmbedForwarder
]

# The embedder served-model id (== the wire `model` value, the SM id).
comptime _EMBED_ID: String = "bge-small-en-v1.5"
# A short keep_alive TTL for the idle-unload assertion (a real server would
# give an always-resident embedder a long TTL; this test uses a short one to
# PROVE the tick fires).
comptime _KEEPALIVE_MS: Int = 5000


def _hw() -> HostMemoryProfile:
    # A 16 GB unified Mac — the ~96 MB embedder lands trivially GREEN.
    return HostMemoryProfile(
        total_ram_bytes=16 * 1024 * 1024 * 1024,
        vram_bytes=0,
        unified_memory=True,
        platform=PLATFORM_MACOS,
    )


def _gib(n: Int) -> Int:
    return n * 1024 * 1024 * 1024


def _make_server() raises -> HttpServer[NoopGrpcDispatch]:
    return HttpServer(
        config=HttpServerConfig.default_ephemeral(), router=Router()
    )


def _make_dispatcher() -> _Dispatcher:
    """Assemble the dispatcher the way a server would: host profile (a fixture
    here) -> rate the embedder -> register it in the SM (max_resident=1, the
    short test TTL) -> wrap in the ControlApiDispatcher with a (stub)
    forwarder."""
    var hw = _hw()
    var sm = BackendSupervisor[StubEmbedBackend, MockClock](
        MockClock(1000), hw, _gib(8), _KEEPALIVE_MS, 1
    )
    var embed_variant = ModelVariant(
        _EMBED_ID, String("embed"), 96 * 1024 * 1024, String("bf16")
    )
    var embed_fit = fit(embed_variant, hw)
    _ = sm.register(
        _EMBED_ID,
        StubEmbedBackend(String("http://127.0.0.1:8082")),
        embed_fit.resident_bytes,
    )

    var d = _Dispatcher(sm^, StubEmbedForwarder())
    d.set_fit(_EMBED_ID, embed_fit)
    return d^


# =============================================================================
# §1 — Same-process raw-socket client helpers (the same as
# test_localmodel_control_api).
# =============================================================================
comptime _AF_INET: Int32 = 2
comptime _SOCK_STREAM: Int32 = 1


def _build_sockaddr_in_loopback(port: UInt16) -> Array[UInt8, 16]:
    var addr = Array[UInt8, 16](fill=UInt8(0))
    comptime if CompilationTarget.is_macos():
        addr[0] = UInt8(16)
        addr[1] = UInt8(_AF_INET)
    else:
        addr[0] = UInt8(_AF_INET)
        addr[1] = UInt8(0)
    addr[2] = UInt8(Int(port >> 8) & 0xFF)
    addr[3] = UInt8(Int(port) & 0xFF)
    addr[4] = UInt8(127)
    addr[5] = UInt8(0)
    addr[6] = UInt8(0)
    addr[7] = UInt8(1)
    return addr^


def _create_blocking_client_socket() raises -> Int32:
    var fd = external_call["socket", Int32](
        Int32(_AF_INET), Int32(_SOCK_STREAM), Int32(0),
    )
    if fd < Int32(0):
        raise Error("test: socket() failed")
    return fd


def _connect_blocking(fd: Int32, port: UInt16) raises:
    var addr = _build_sockaddr_in_loopback(port)
    var addr_ptr = UnsafePointer(to=addr).bitcast[UInt8]()
    var rc = external_call["connect", Int32](fd, addr_ptr, UInt32(16))
    if rc < Int32(0):
        _ = external_call["close", Int32](fd)
        raise Error("test: connect() failed")


def _send_all(fd: Int32, bytes: List[UInt8]) raises:
    var total = len(bytes)
    var sent = 0
    var raw = bytes.unsafe_ptr()
    while sent < total:
        var rc = external_call["send", Int64](
            fd, raw + sent, UInt64(total - sent), Int32(0),
        )
        if rc <= Int64(0):
            raise Error("test: send() failed")
        sent = sent + Int(rc)


def _recv_some(fd: Int32, max_bytes: Int) raises -> List[UInt8]:
    var buf = List[UInt8]()
    buf.resize(unsafe_uninit_length=max_bytes)
    var raw = buf.unsafe_ptr()
    var n = external_call["recv", Int64](
        fd, raw, UInt64(max_bytes), Int32(0),
    )
    if n < Int64(0):
        raise Error("test: recv() failed")
    var out = List[UInt8]()
    var i = 0
    while i < Int(n):
        out.append(buf[i])
        i = i + 1
    return out^


def _close_socket(fd: Int32):
    _ = external_call["close", Int32](fd)


def _build_request(method: String, path: String, body: String) -> List[UInt8]:
    var s = method + String(" ") + path + String(" HTTP/1.1\r\n")
    s += String("Host: localhost\r\n")
    if body.byte_length() > 0:
        s += String("Content-Type: application/json\r\n")
        s += String("Content-Length: ") + String(len(body.as_bytes())) + String(
            "\r\n"
        )
    s += String("\r\n")
    s += body
    var bytes = s.as_bytes()
    var out = List[UInt8]()
    var i = 0
    while i < len(bytes):
        out.append(bytes[i])
        i = i + 1
    return out^


def _bytes_contain(haystack: List[UInt8], needle: String) -> Bool:
    var nbytes = needle.as_bytes()
    var hn = len(haystack)
    var nn = len(nbytes)
    if nn == 0 or nn > hn:
        return nn == 0
    var i = 0
    while i + nn <= hn:
        var matched = True
        var j = 0
        while j < nn:
            if haystack[i + j] != nbytes[j]:
                matched = False
                break
            j = j + 1
        if matched:
            return True
        i = i + 1
    return False


def _drive(
    mut server: HttpServer[NoopGrpcDispatch],
    mut dispatcher: _Dispatcher,
    iters: Int,
    timeout_us: Int32,
) raises:
    var i = 0
    while i < iters:
        _ = server.serve_one_iteration_dispatch[_Dispatcher, _Rt](
            dispatcher, timeout_us
        )
        i = i + 1


def _round_trip(
    mut server: HttpServer[NoopGrpcDispatch],
    mut dispatcher: _Dispatcher,
    port: UInt16,
    method: String,
    path: String,
    body: String,
) raises -> List[UInt8]:
    var client_fd = _create_blocking_client_socket()
    _connect_blocking(client_fd, port)
    _drive(server, dispatcher, 4, Int32(300_000))
    _send_all(client_fd, _build_request(method, path, body))
    _drive(server, dispatcher, 8, Int32(50_000))
    var resp = _recv_some(client_fd, 8192)
    _close_socket(client_fd)
    return resp^


# =============================================================================
# Test (a-c) — one live server: the rich list rates the embedder GREEN, and
# POST /v1/embeddings loads + forwards to it.
# =============================================================================
def test_embedder_list_and_passthrough() raises:
    var server = _make_server()
    var dispatcher = _make_dispatcher()
    var port = server.local_port()
    assert_true(Int(port) > 0, "loopback ephemeral control-API port bound")

    # (a) GET /models -> the embedder advertised + rated GREEN, REGISTERED.
    var r_list = _round_trip(
        server, dispatcher, port, String("GET"), String("/models"), String("")
    )
    assert_true(_bytes_contain(r_list, String("HTTP/1.1 200")), "list 200")
    assert_true(
        _bytes_contain(r_list, String('"id":"bge-small-en-v1.5"')),
        "the list advertises the embedder",
    )
    assert_true(
        _bytes_contain(r_list, String('"state":"registered"')),
        "the embedder starts REGISTERED (not loaded)",
    )
    assert_true(
        _bytes_contain(r_list, String('"fit":"green"')),
        "the ~96 MB embedder is rated GREEN",
    )

    # (b) POST /v1/embeddings {"model":"<embed>","input":[...]} -> the PASSTHROUGH:
    # load the embedder + forward the body to its /v1/embeddings endpoint.
    var body = String(
        '{"model":"bge-small-en-v1.5","input":["user login credentials"]}'
    )
    var resp = _round_trip(
        server, dispatcher, port, String("POST"),
        String("/v1/embeddings"), body,
    )
    assert_true(
        _bytes_contain(resp, String("HTTP/1.1 200")),
        "the /v1/embeddings passthrough returned 200",
    )
    assert_true(
        _bytes_contain(resp, String('"object":"embedding"')),
        "the passthrough returned the forwarder's embeddings response",
    )
    # The load left the embedder SERVING.
    assert_true(
        dispatcher.sm_ref().state_of(_EMBED_ID) == LM_SERVING,
        "the /v1/embeddings call loaded the embedder to SERVING",
    )

    # (c) the forwarder was handed the embedder's base_url + the /v1/embeddings
    # PATH (NOT /v1/chat/completions — the path-generic forwarder routes it).
    assert_equal(
        dispatcher.forwarder_ref().last_base_url,
        String("http://127.0.0.1:8082"),
        "the passthrough forwarded to the loaded embedder's base_url",
    )
    assert_equal(
        dispatcher.forwarder_ref().last_path,
        String("/v1/embeddings"),
        "the passthrough preserved the /v1/embeddings path",
    )
    assert_equal(dispatcher.forwarder_ref().forward_count, 1)
    _ = server^
    _ = dispatcher^


# =============================================================================
# Test (d) — the IDLE-UNLOAD TICK (what a serve loop calls each iteration).
# After the embedder is SERVING, a tick within the TTL leaves it SERVING;
# advancing virtual time past the TTL + ticking unloads it.
# =============================================================================
def test_idle_unload_tick_driver() raises:
    var server = _make_server()
    var dispatcher = _make_dispatcher()
    var port = server.local_port()

    # Load the embedder via a /v1/embeddings call (now SERVING, last_request
    # stamped at the MockClock's current time = 1000).
    var body = String('{"model":"bge-small-en-v1.5","input":["x"]}')
    _ = _round_trip(
        server, dispatcher, port, String("POST"),
        String("/v1/embeddings"), body,
    )
    assert_true(
        dispatcher.sm_ref().state_of(_EMBED_ID) == LM_SERVING,
        "embedder SERVING after the first embed call",
    )

    # Tick WITHIN the TTL (advance < keep_alive) -> NOT unloaded (the tick is a
    # real keep_alive sweep, not a blind unload).
    dispatcher.clock_mut().clock_mut().advance_ms(_KEEPALIVE_MS - 1000)
    var unloaded_within = dispatcher.tick_idle_unload()
    assert_equal(
        unloaded_within, 0, "within the TTL, the tick unloads nothing"
    )
    assert_true(
        dispatcher.sm_ref().state_of(_EMBED_ID) == LM_SERVING,
        "embedder still SERVING within the keep_alive TTL",
    )

    # Advance PAST the TTL + tick -> the tick idle-unloads the embedder
    # (SERVING -> REGISTERED).
    dispatcher.clock_mut().clock_mut().advance_ms(2000)  # now idle > TTL.
    var unloaded_past = dispatcher.tick_idle_unload()
    assert_equal(
        unloaded_past, 1, "past the TTL, the tick idle-unloads the embedder"
    )
    assert_true(
        dispatcher.sm_ref().state_of(_EMBED_ID) == LM_REGISTERED,
        "the idle-unload tick drove the embedder back to REGISTERED",
    )

    # A subsequent embed call loads it again (the lifecycle is reusable).
    _ = _round_trip(
        server, dispatcher, port, String("POST"),
        String("/v1/embeddings"), body,
    )
    assert_true(
        dispatcher.sm_ref().state_of(_EMBED_ID) == LM_SERVING,
        "a fresh embed call reloads the idle-unloaded embedder",
    )
    _ = server^
    _ = dispatcher^


# =============================================================================
# Test (e) — error paths: a /v1/embeddings body with no model -> 400; an absent
# model -> 404.
# =============================================================================
def test_error_paths() raises:
    var server = _make_server()
    var dispatcher = _make_dispatcher()
    var port = server.local_port()

    # a /v1/embeddings body that names no model -> 400.
    var r_400 = _round_trip(
        server, dispatcher, port, String("POST"),
        String("/v1/embeddings"), String('{"input":["x"]}'),
    )
    assert_true(
        _bytes_contain(r_400, String("HTTP/1.1 400")),
        "a /v1/embeddings body with no model -> 400",
    )

    # a /v1/embeddings naming an unregistered model -> 404.
    var r_404 = _round_trip(
        server, dispatcher, port, String("POST"),
        String("/v1/embeddings"),
        String('{"model":"not-registered","input":["x"]}'),
    )
    assert_true(
        _bytes_contain(r_404, String("HTTP/1.1 404")),
        "a /v1/embeddings naming an absent model -> 404",
    )
    _ = server^
    _ = dispatcher^


def main() raises:
    test_embedder_list_and_passthrough()
    test_idle_unload_tick_driver()
    test_error_paths()
    print(
        "PASS test_localmodel_server_daemon (embedder list+fit-green /"
        " /v1/embeddings passthrough load+forward / idle-unload tick fires past"
        " the TTL + holds within it + reload / error paths, over a live"
        " loopback HttpServer + ControlApiDispatcher with a STUB embedder"
        " backend + STUB forwarder + virtual clock)"
    )
