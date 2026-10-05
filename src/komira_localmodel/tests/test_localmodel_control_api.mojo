# =============================================================================
# test_localmodel_control_api.mojo
#   The loopback CONTROL API. Binds an HttpServer on a loopback ephemeral port
#   with the ControlApiDispatcher over a BackendSupervisor (STUB backend + STUB
#   forwarder), drives a same-process raw-socket HTTP client, and asserts the
#   lifecycle verbs and the /v1 passthrough end to end over real HTTP.
# =============================================================================
#
# WHAT THIS PROVES:
#   (a) GET  /models               -> the RICH list: each model with its
#       lifecycle state + per-model fit green/yellow/red.
#   (b) GET  /status?id=<id>       -> one model's status snapshot.
#   (c) POST /select {"id":...}    -> load (REGISTERED -> SERVING) + the
#       base_url; a re-GET /status confirms the transition.
#   (d) POST /stop   {"id":...}    -> unload (-> REGISTERED).
#   (e) POST /v1/chat/completions {..., "model":"<id>"} -> the PASSTHROUGH:
#       loads the model + forwards the body to its endpoint (the STUB
#       forwarder records the base_url it was handed + returns a canned
#       completion); the response carries the completion.
#   (f) GET  /v1/models            -> the OpenAI model-list shape.
#   (g) a select of an absent id   -> 404; a /v1 body with no "model" -> 400;
#       an unknown route -> 404.
#
# Same-process design: a synchronous blocking libc client (socket / connect /
# send / recv) interleaved with bounded server event-loop slices, so the test
# is a sequential script with no subprocess. The STUB backend and STUB
# forwarder are in-process (no engine, no spawn).
# =============================================================================

from std.ffi import external_call
from std.memory import UnsafePointer
from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_true, assert_false

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime

from komira_http import HttpServer, HttpServerConfig, Router, NoopGrpcDispatch

from komira_localmodel import (
    BackendSupervisor,
    LocalBackend,
    SystemClock,
    ControlApiDispatcher,
    OpenAiForwarder,
    HostMemoryProfile,
    PLATFORM_MACOS,
    fit,
    ModelVariant,
)


# =============================================================================
# §0 — The STUB backend + STUB forwarder (in-process, no engine / no spawn).
# =============================================================================
struct StubBackend(LocalBackend, Movable, Deinitable):
    """A fake LocalBackend: launch() flips an internal up-flag + returns the
    configured base_url; teardown() flips it down. No real process / HTTP."""

    var _base_url: String
    var _up: Bool

    def __init__(out self, base_url: String):
        self._base_url = base_url
        self._up = False

    def launch(mut self) raises -> String:
        self._up = True
        return self._base_url

    def health(self) -> Bool:
        return self._up

    def teardown(mut self):
        self._up = False

    def base_url(self) -> String:
        return self._base_url


struct StubForwarder(OpenAiForwarder, Movable, Deinitable):
    """A fake OpenAiForwarder: records the (base_url, path) it was last handed
    + returns a canned OpenAI completion. So the /v1 passthrough route is fully
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
        # A canned OpenAI chat-completion response body.
        return String(
            '{"id":"chatcmpl-stub","object":"chat.completion",'
            + '"choices":[{"index":0,"message":{"role":"assistant",'
            + '"content":"stub-reply"}}]}'
        )


comptime _Rt = BlockingRuntime[NoopSink]
comptime _Dispatcher = ControlApiDispatcher[StubBackend, SystemClock, StubForwarder]


def _hw() -> HostMemoryProfile:
    # 16 GB unified Mac for the FIT rating: qwen-7b (~6.5 GiB resident) lands
    # GREEN, the Llama-70B (~58.5 GiB resident) lands RED — so the list verb
    # renders BOTH a green AND a red, proving the fit rating surfaces. The SM's
    # EVICTION budget is a SEPARATE explicit 64 GiB (see _make_dispatcher), so
    # the lifecycle verbs are not perturbed by this small fit host (eviction is
    # tested in test_localmodel_state_machine).
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
    var hw = _hw()
    # max_resident = 4, generous budget (no eviction in the contract scenarios).
    var sm = BackendSupervisor[StubBackend, SystemClock](
        SystemClock.new(), hw, _gib(64), 5 * 60 * 1000, 4
    )
    # Register two models with their chosen variants + fit results.
    var qwen_variant = ModelVariant(
        String("qwen-7b-4bit"), String("qwen-7b"), _gib(4), String("4bit")
    )
    var qwen_fit = fit(qwen_variant, hw)
    _ = sm.register(
        String("qwen-7b"),
        StubBackend(String("http://127.0.0.1:8090")),
        qwen_fit.resident_bytes,
    )

    var llama_variant = ModelVariant(
        String("llama-3.3-70b-Q6"), String("llama-3.3-70b"), _gib(50), String("Q6")
    )
    var llama_fit = fit(llama_variant, hw)
    _ = sm.register(
        String("llama-70b"),
        StubBackend(String("http://127.0.0.1:8091")),
        llama_fit.resident_bytes,
    )

    var d = _Dispatcher(sm^, StubForwarder())
    d.set_fit(String("qwen-7b"), qwen_fit)
    d.set_fit(String("llama-70b"), llama_fit)
    return d^


# =============================================================================
# §1 — Same-process raw-socket client helpers.
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
# Test (a-d) — the lifecycle verbs over ONE live server: list -> status ->
# select (load) -> status -> stop.
# =============================================================================
def test_list_select_stop() raises:
    var server = _make_server()
    var dispatcher = _make_dispatcher()
    var port = server.local_port()
    assert_true(Int(port) > 0, "loopback ephemeral port bound")

    # (a) GET /models -> the rich list with state + fit.
    var r_list = _round_trip(
        server, dispatcher, port, String("GET"), String("/models"), String("")
    )
    assert_true(_bytes_contain(r_list, String("HTTP/1.1 200")), "list 200")
    assert_true(
        _bytes_contain(r_list, String('"id":"qwen-7b"')),
        "list advertises qwen-7b",
    )
    assert_true(
        _bytes_contain(r_list, String('"id":"llama-70b"')),
        "list advertises llama-70b",
    )
    # Both start REGISTERED (not loaded).
    assert_true(
        _bytes_contain(r_list, String('"state":"registered"')),
        "models start REGISTERED",
    )
    # qwen-7b (6.5 GiB resident) is GREEN on the 16 GB fit host; the 70B is RED.
    assert_true(_bytes_contain(r_list, String('"fit":"green"')), "qwen fit green")
    assert_true(_bytes_contain(r_list, String('"fit":"red"')), "llama fit red")

    # (b) GET /status?id=qwen-7b -> REGISTERED snapshot.
    var r_status = _round_trip(
        server, dispatcher, port, String("GET"),
        String("/status?id=qwen-7b"), String(""),
    )
    assert_true(_bytes_contain(r_status, String("HTTP/1.1 200")), "status 200")
    assert_true(
        _bytes_contain(r_status, String('"state":"registered"')),
        "qwen-7b is REGISTERED before select",
    )

    # (c) POST /select {"id":"qwen-7b"} -> load -> SERVING + base_url.
    var r_select = _round_trip(
        server, dispatcher, port, String("POST"), String("/select"),
        String('{"id":"qwen-7b"}'),
    )
    assert_true(_bytes_contain(r_select, String("HTTP/1.1 200")), "select 200")
    assert_true(
        _bytes_contain(r_select, String('"state":"serving"')),
        "select drove qwen-7b to SERVING",
    )
    assert_true(
        _bytes_contain(r_select, String('"base_url":"http://127.0.0.1:8090"')),
        "select returned the backend base_url",
    )
    # The SM itself reflects the transition.
    assert_true(
        dispatcher.sm_ref().state_of(String("qwen-7b")) == 2,  # LM_SERVING
        "the SM flipped qwen-7b to SERVING",
    )

    # (d) re-GET /status?id=qwen-7b -> now SERVING.
    var r_status2 = _round_trip(
        server, dispatcher, port, String("GET"),
        String("/status?id=qwen-7b"), String(""),
    )
    assert_true(
        _bytes_contain(r_status2, String('"state":"serving"')),
        "qwen-7b status is SERVING after select",
    )

    # (e) POST /stop {"id":"qwen-7b"} -> unload -> REGISTERED.
    var r_stop = _round_trip(
        server, dispatcher, port, String("POST"), String("/stop"),
        String('{"id":"qwen-7b"}'),
    )
    assert_true(_bytes_contain(r_stop, String("HTTP/1.1 200")), "stop 200")
    assert_true(
        _bytes_contain(r_stop, String('"stopped":true')),
        "stop unloaded the resident qwen-7b",
    )
    assert_true(
        _bytes_contain(r_stop, String('"state":"registered"')),
        "qwen-7b back to REGISTERED after stop",
    )
    _ = server^
    _ = dispatcher^


# =============================================================================
# Test (e) — the OpenAI /v1 passthrough: a chat/completions POST loads the
# named model + forwards to its endpoint (the stub forwarder records + replies).
# =============================================================================
def test_v1_passthrough() raises:
    var server = _make_server()
    var dispatcher = _make_dispatcher()
    var port = server.local_port()

    var body = String(
        '{"model":"qwen-7b","messages":[{"role":"user","content":"hi"}]}'
    )
    var resp = _round_trip(
        server, dispatcher, port, String("POST"),
        String("/v1/chat/completions"), body,
    )
    assert_true(_bytes_contain(resp, String("HTTP/1.1 200")), "passthrough 200")
    assert_true(
        _bytes_contain(resp, String('"content":"stub-reply"')),
        "the passthrough returned the forwarder's completion",
    )
    # The forwarder was handed the loaded model's base_url + the /v1 path.
    assert_equal(
        dispatcher.forwarder_ref().last_base_url,
        String("http://127.0.0.1:8090"),
        "the passthrough forwarded to the loaded model's base_url",
    )
    assert_equal(
        dispatcher.forwarder_ref().last_path,
        String("/v1/chat/completions"),
        "the passthrough preserved the OpenAI path",
    )
    assert_equal(dispatcher.forwarder_ref().forward_count, 1)
    # The load left the model SERVING.
    assert_true(dispatcher.sm_ref().state_of(String("qwen-7b")) == 2)  # SERVING
    _ = server^
    _ = dispatcher^


# =============================================================================
# Test (f) — GET /v1/models returns the OpenAI model-list shape.
# =============================================================================
def test_v1_models_list() raises:
    var server = _make_server()
    var dispatcher = _make_dispatcher()
    var port = server.local_port()

    var resp = _round_trip(
        server, dispatcher, port, String("GET"), String("/v1/models"), String("")
    )
    assert_true(_bytes_contain(resp, String("HTTP/1.1 200")), "v1/models 200")
    assert_true(
        _bytes_contain(resp, String('"object":"list"')),
        "the OpenAI list envelope",
    )
    assert_true(
        _bytes_contain(resp, String('"id":"qwen-7b"')),
        "v1/models lists qwen-7b",
    )
    assert_true(
        _bytes_contain(resp, String('"object":"model"')),
        "each entry is an OpenAI model object",
    )
    _ = server^
    _ = dispatcher^


# =============================================================================
# Test (g) — error paths: an absent id -> 404; a /v1 body with no model -> 400.
# =============================================================================
def test_error_paths() raises:
    var server = _make_server()
    var dispatcher = _make_dispatcher()
    var port = server.local_port()

    # select an unregistered id -> 404.
    var r_404 = _round_trip(
        server, dispatcher, port, String("POST"), String("/select"),
        String('{"id":"does-not-exist"}'),
    )
    assert_true(
        _bytes_contain(r_404, String("HTTP/1.1 404")),
        "select of an absent id -> 404",
    )

    # a /v1 body that names no model -> 400.
    var r_400 = _round_trip(
        server, dispatcher, port, String("POST"),
        String("/v1/chat/completions"),
        String('{"messages":[{"role":"user","content":"hi"}]}'),
    )
    assert_true(
        _bytes_contain(r_400, String("HTTP/1.1 400")),
        "a /v1 body with no model -> 400",
    )

    # an unknown route -> 404.
    var r_unknown = _round_trip(
        server, dispatcher, port, String("GET"), String("/nope"), String("")
    )
    assert_true(
        _bytes_contain(r_unknown, String("HTTP/1.1 404")),
        "an unknown route -> 404",
    )
    _ = server^
    _ = dispatcher^


def main() raises:
    test_list_select_stop()
    test_v1_passthrough()
    test_v1_models_list()
    test_error_paths()
    print(
        "PASS test_localmodel_control_api (list / status / select-load /"
        " stop / v1-passthrough / v1-models / error-paths — all over a live"
        " loopback-bound HttpServer + ControlApiDispatcher with a STUB backend"
        " + STUB forwarder)"
    )
