# =============================================================================
# test_localmodel_chat.mojo
#   One server hosting an embedding model AND a chat model. Binds an HttpServer
#   on a loopback ephemeral port with the ControlApiDispatcher over a
#   BackendSupervisor hosting both (STUB backends + a STUB forwarder + a
#   VIRTUAL clock), drives a same-process raw-socket HTTP client, and asserts:
#
#   (a) ONE PORT, TWO MODELS — GET /models advertises BOTH the embedder and the
#       chat model, each rated GREEN; the rich list carries each model's
#       admission cap / in-flight / queued.
#   (b) CHAT PASSTHROUGH — POST /v1/chat/completions {"model":"<chat>",...}
#       loads the chat model + forwards the body to its /v1/chat/completions
#       endpoint (the STUB forwarder records the base_url + the PATH it was
#       handed, proving the path-generic forwarder routes the CHAT route, not
#       the embeddings route, on the SAME port).
#   (c) PER-MODEL KEEP-ALIVE — the embedder is registered with a VERY LONG TTL
#       (always resident) and the chat model with a SHORT TTL; after both are
#       SERVING, advancing virtual time past the CHAT TTL (but within the
#       embedder's) + ticking unloads ONLY the chat model.
#   (d) ADMISSION CAP on chat — the chat model's per-model concurrency cap is
#       the N derived from the fit budget.
#
# The backends and forwarder are in-process stubs; the clock is virtual, so the
# per-model keep-alive assertion needs no sleep.
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
    HostMemoryProfile,
    PLATFORM_MACOS,
    fit,
    fit_concurrent,
    derive_concurrency_cap,
    ModelVariant,
    LM_SERVING,
    LM_REGISTERED,
)


# =============================================================================
# §0 — a STUB backend (serves both the embedder + chat roles), a STUB forwarder
# (records base_url + path), and a VIRTUAL clock.
# =============================================================================
struct StubBackend(LocalBackend, Movable, Deinitable):
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


struct StubForwarder(OpenAiForwarder, Movable, Deinitable):
    """Records the (base_url, path) it was last handed + returns a canned OpenAI
    response shaped by the path (embeddings vs chat) so the passthrough route is
    testable with no live engine."""

    var last_base_url: String
    var last_path: String
    var forward_count: Int

    def __init__(out self):
        self.last_base_url = String("")
        self.last_path = String("")
        self.forward_count = 0

    def forward(
        mut self, base_url: String, path: String, request_body: String
    ) raises -> String:
        self.last_base_url = base_url
        self.last_path = path
        self.forward_count += 1
        _ = request_body
        if path == "/v1/chat/completions":
            return String(
                '{"object":"chat.completion","model":"qwen2.5-coder:7b",'
                + '"choices":[{"index":0,"message":{"role":"assistant",'
                + '"content":"hello"}}]}'
            )
        return String(
            '{"object":"list","model":"bge-small-en-v1.5","data":['
            + '{"object":"embedding","index":0,"embedding":[0.1,0.2]}]}'
        )


struct MockClock(MonotonicClock, Movable, Deinitable):
    var _now_ms: Int

    def __init__(out self, start_ms: Int):
        self._now_ms = start_ms

    def now_ms(mut self) -> Int:
        return self._now_ms

    def advance_ms(mut self, delta_ms: Int):
        self._now_ms = self._now_ms + delta_ms


comptime _Rt = BlockingRuntime[NoopSink]
comptime _Dispatcher = ControlApiDispatcher[StubBackend, MockClock, StubForwarder]

comptime _EMBED_ID: String = "bge-small-en-v1.5"
comptime _CHAT_ID: String = "qwen2.5-coder:7b"
comptime _EMBED_KEEPALIVE_MS: Int = 1_000_000_000  # "always-resident" long TTL.
comptime _CHAT_KEEPALIVE_MS: Int = 5000             # the chat idle-unload TTL.
comptime _NUM_PARALLEL: Int = 4


def _hw() -> HostMemoryProfile:
    # A 96 GB unified Mac so BOTH the embedder + a 5 GiB chat model fit resident.
    return HostMemoryProfile(
        total_ram_bytes=96 * 1024 * 1024 * 1024,
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
    """Assemble a dispatcher hosting BOTH the embedder AND the chat model —
    max_resident=2 so both coexist, each with its own per-model keep_alive TTL
    + admission cap."""
    var hw = _hw()
    # max_resident=2: the always-resident embedder + a JIT-loaded chat model.
    var sm = BackendSupervisor[StubBackend, MockClock](
        MockClock(1000), hw, _gib(80), _CHAT_KEEPALIVE_MS, 2
    )

    # The embedder — KV=0 ("embed" family), a VERY LONG per-model keep_alive TTL.
    var embed_variant = ModelVariant(
        _EMBED_ID, String("embed"), 96 * 1024 * 1024, String("bf16")
    )
    var embed_fit = fit_concurrent(embed_variant, hw, 0, _NUM_PARALLEL)
    var embed_cap = derive_concurrency_cap(embed_fit.headroom_bytes, _NUM_PARALLEL)
    _ = sm.register_full(
        _EMBED_ID,
        StubBackend(String("http://127.0.0.1:8082")),
        embed_fit.resident_bytes,
        embed_cap,
        _EMBED_KEEPALIVE_MS,
    )

    # The chat model — a 7B-class model, a SHORT per-model TTL, the
    # concurrency-aware admission cap (chat is where concurrency bites).
    var chat_variant = ModelVariant(
        _CHAT_ID, String("qwen-7b"), 5 * 1024 * 1024 * 1024, String("4bit")
    )
    var chat_fit = fit_concurrent(chat_variant, hw, 0, _NUM_PARALLEL)
    var chat_cap = derive_concurrency_cap(chat_fit.headroom_bytes, _NUM_PARALLEL)
    _ = sm.register_full(
        _CHAT_ID,
        StubBackend(String("http://127.0.0.1:8081")),
        chat_fit.resident_bytes,
        chat_cap,
        _CHAT_KEEPALIVE_MS,
    )

    var d = _Dispatcher(sm^, StubForwarder())
    d.set_fit(_EMBED_ID, embed_fit)
    d.set_fit(_CHAT_ID, chat_fit)
    return d^


# =============================================================================
# §1 — Same-process raw-socket client helpers (the same as
# test_localmodel_server_daemon).
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
# Test (a) — ONE PORT, TWO MODELS: the rich list advertises both, each GREEN,
# each carrying its admission cap.
# =============================================================================
def test_one_port_two_models() raises:
    var server = _make_server()
    var dispatcher = _make_dispatcher()
    var port = server.local_port()
    assert_true(Int(port) > 0, "loopback ephemeral control-API port bound")

    var r_list = _round_trip(
        server, dispatcher, port, String("GET"), String("/models"), String("")
    )
    assert_true(_bytes_contain(r_list, String("HTTP/1.1 200")), "list 200")
    # Both models advertised.
    assert_true(
        _bytes_contain(r_list, String('"id":"bge-small-en-v1.5"')),
        "the list advertises the embedder",
    )
    assert_true(
        _bytes_contain(r_list, String('"id":"qwen2.5-coder:7b"')),
        "the list advertises the chat model on the SAME port",
    )
    # Both rated GREEN (96 GB host fits the embedder + a 5 GiB chat model).
    assert_true(
        _bytes_contain(r_list, String('"fit":"green"')),
        "the models are rated GREEN",
    )
    # The admission cap surfaces (cap/inflight/queued in the rich list).
    assert_true(
        _bytes_contain(r_list, String('"max_concurrent":4')),
        "the per-model admission cap surfaces in /models",
    )
    assert_true(
        _bytes_contain(r_list, String('"inflight":0')),
        "in-flight starts at 0",
    )
    _ = server^
    _ = dispatcher^


# =============================================================================
# Test (b) — CHAT PASSTHROUGH: POST /v1/chat/completions loads the chat model
# + forwards the body to its /v1/chat/completions endpoint (not the embed route).
# =============================================================================
def test_chat_passthrough() raises:
    var server = _make_server()
    var dispatcher = _make_dispatcher()
    var port = server.local_port()

    var body = String(
        '{"model":"qwen2.5-coder:7b","messages":[{"role":"user",'
        + '"content":"hi"}]}'
    )
    var resp = _round_trip(
        server, dispatcher, port, String("POST"),
        String("/v1/chat/completions"), body,
    )
    assert_true(
        _bytes_contain(resp, String("HTTP/1.1 200")),
        "the /v1/chat/completions passthrough returned 200",
    )
    assert_true(
        _bytes_contain(resp, String('"object":"chat.completion"')),
        "the passthrough returned the forwarder's chat response",
    )
    # The load left the CHAT model SERVING (and the embedder untouched —
    # still REGISTERED until its own first request).
    assert_true(
        dispatcher.sm_ref().state_of(_CHAT_ID) == LM_SERVING,
        "the chat call loaded the chat model to SERVING",
    )
    assert_true(
        dispatcher.sm_ref().state_of(_EMBED_ID) == LM_REGISTERED,
        "the embedder is untouched by a chat-only request",
    )
    # The forwarder was handed the CHAT base_url + the chat PATH.
    assert_equal(
        dispatcher.forwarder_ref().last_base_url,
        String("http://127.0.0.1:8081"),
        "the passthrough forwarded to the loaded chat model's base_url",
    )
    assert_equal(
        dispatcher.forwarder_ref().last_path,
        String("/v1/chat/completions"),
        "the passthrough preserved the /v1/chat/completions path",
    )
    _ = server^
    _ = dispatcher^


# =============================================================================
# Test (c) — PER-MODEL KEEP-ALIVE: a tick past the CHAT TTL (within the embedder's
# long TTL) idle-unloads ONLY the chat model; the embedder stays resident.
# =============================================================================
def test_per_model_keepalive() raises:
    var server = _make_server()
    var dispatcher = _make_dispatcher()
    var port = server.local_port()

    # Load BOTH: an embed call + a chat call (both SERVING, last_request at 1000).
    _ = _round_trip(
        server, dispatcher, port, String("POST"),
        String("/v1/embeddings"),
        String('{"model":"bge-small-en-v1.5","input":["x"]}'),
    )
    _ = _round_trip(
        server, dispatcher, port, String("POST"),
        String("/v1/chat/completions"),
        String('{"model":"qwen2.5-coder:7b","messages":[{"role":"user","content":"x"}]}'),
    )
    assert_true(
        dispatcher.sm_ref().state_of(_EMBED_ID) == LM_SERVING,
        "embedder SERVING",
    )
    assert_true(
        dispatcher.sm_ref().state_of(_CHAT_ID) == LM_SERVING,
        "chat SERVING",
    )

    # Advance past the CHAT TTL (5000) but FAR within the embedder's long TTL +
    # tick -> ONLY the chat model idle-unloads.
    dispatcher.clock_mut().clock_mut().advance_ms(_CHAT_KEEPALIVE_MS + 1000)
    var unloaded = dispatcher.tick_idle_unload()
    assert_equal(
        unloaded, 1, "the tick idle-unloads ONLY the chat model (its TTL passed)"
    )
    assert_true(
        dispatcher.sm_ref().state_of(_CHAT_ID) == LM_REGISTERED,
        "the chat model idle-unloaded past its short TTL",
    )
    assert_true(
        dispatcher.sm_ref().state_of(_EMBED_ID) == LM_SERVING,
        "the always-resident embedder is held by its long per-model TTL",
    )
    _ = server^
    _ = dispatcher^


# =============================================================================
# Test (d) — the chat model carries the concurrency-aware admission cap.
# =============================================================================
def test_chat_admission_cap() raises:
    var dispatcher = _make_dispatcher()
    # The chat model's cap is the num_parallel (96 GB host -> generous headroom ->
    # the full requested concurrency).
    assert_equal(
        dispatcher.sm_ref().max_concurrent_of(_CHAT_ID),
        _NUM_PARALLEL,
        "the chat model carries the concurrency-aware admission cap",
    )
    # The embedder also carries a cap (its KV=0 fit is concurrency-invariant, so
    # the cap is the full num_parallel — admission still bounds in-flight).
    assert_equal(
        dispatcher.sm_ref().max_concurrent_of(_EMBED_ID),
        _NUM_PARALLEL,
        "the embedder carries an admission cap too",
    )
    _ = dispatcher^


def main() raises:
    test_one_port_two_models()
    test_chat_passthrough()
    test_per_model_keepalive()
    test_chat_admission_cap()
    print(
        "PASS test_localmodel_chat (one port hosts BOTH the embedder + the chat"
        " model; /models advertises both GREEN with admission caps;"
        " /v1/chat/completions loads the chat model + forwards to its chat"
        " endpoint; per-model keep-alive unloads ONLY the short-TTL chat model"
        " while the always-resident embedder is held; the chat model carries the"
        " concurrency-aware admission cap)"
    )
