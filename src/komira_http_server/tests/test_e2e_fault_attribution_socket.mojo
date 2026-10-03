# =============================================================================
# tests/test_e2e_fault_attribution_socket.mojo
# =============================================================================
#
# THE GATE THAT BINDS THE HALF THE PAIRED GATE CANNOT.
#
# `tests/test_fault_attribution.mojo` proves the fault-attribution
# BEHAVIOUR — both directions, three mutations RED. It drives `MiddlewareChain`
# and the `fault_report` functions directly, and that is its limit:
#
#   ⚠ A service deployed on the single-port serve path never runs a
#     middleware chain: it serves every surface through ONE dispatcher on
#     `serve_one_iteration_dispatch` — the CHAIN-LESS round.
#
# So reverting the TRANSPORT call sites in `serve_read_round_dispatch` would
# leave the paired gate GREEN while removing the behaviour from that
# configuration. Behaviour proven on a chain nothing runs is not a gate.
#
# ★ THIS TEST DRIVES `serve_one_iteration_dispatch` OVER A REAL LOOPBACK SOCKET
# — the exact round such a binary runs — and asserts on the WIRE BYTES: a
# dispatcher test would not catch a revert.
#
# It proves the transport ANSWERS correctly on that round, and proves nothing
# about which binary mounts which dispatcher.
#
# WHAT A REVERT LOOKS LIKE HERE (the mutation table this extends):
#   revert `report_fault` at the `except` arm  -> §A RED (empty body, no code)
#   revert `observe_error_response`            -> §C RED (no log line at all)
#   make `observe_error_response` rewrite      -> §B RED (the refusal is stamped)
#
# HERMETIC: in-process dispatcher, loopback socket, no network, no cloud, no
# fixtures.
# =============================================================================

from std.ffi import external_call
from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import Reactor
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_async.runtime.runtime_trait import Runtime

from komira_http_server.server import HttpServer, HttpServerConfig
from komira_http_core.transport.grpc_emit import NoopGrpcDispatch
from komira_http_server.routing import Router
from komira_http_core.codec.types import HttpRequest, HttpResponse
from komira_http_server.middleware import FAULT_CODE_TRANSPORT, FAULT_SOURCE_RESPONSE
from komira_http_server.dispatch import RequestDispatcher
from komira_runtime_paths import test_tmpdir


# ---------------------------------------------------------------------------
# The runner's per-run scratch directory, NOT A HARD-CODED `/tmp` PATH: a fixed
# path is shared by every concurrent run of this test on one machine.
# ---------------------------------------------------------------------------
def _scratch_dir() raises -> String:
    """The directory THIS execution may write scratch files into."""
    return test_tmpdir()


comptime _Rt = BlockingRuntime[NoopSink]

# The deliberate refusal's own vocabulary — a 503 whose text names the
# configuration an operator must set. That text is the actionable half and must survive the
# boundary byte-for-byte.
comptime _REFUSAL_CODE: String = "store_unconfigured"
comptime _REFUSAL_TEXT: String = (
    "no durable content store on this deployment — set"
    " EXAMPLE_STORE_ROOT to a bucket URL"
)

# The raise text. Carries an injection payload AND a tenant email so the two
# disclosure invariants are tested against bytes that would be visible if they
# leaked: the response must not echo ANY of it, and the LOG must redact the
# address while keeping the diagnosis.
comptime _FAULT_TEXT: String = (
    "firestore: missing composite index for tenant_secrets"
    " <script>pwn</script> Key (email)=(alice@customer.example)"
)


# =============================================================================
# §1 — the dispatcher under test. Three routes, three outcomes.
# =============================================================================


struct _FaultDispatcher(RequestDispatcher, Movable, Deinitable):
    """RAISES on `/fault`, RETURNS a deliberate 503 on `/refusal`, plain 200 on
    `/ok`. The three populations the transport round must keep distinct."""

    var calls: Int

    @staticmethod
    def new() -> _FaultDispatcher:
        return _FaultDispatcher(calls=0)

    def __init__(out self, calls: Int):
        self.calls = calls

    def dispatch[
        RT: Runtime,
    ](
        mut self, mut reactor: Reactor[RT.Sink], var req: HttpRequest
    ) raises -> HttpResponse:
        self.calls = self.calls + 1
        var path = String(req.path)
        if path == String("/fault"):
            # An UNCAUGHT raise — the fault population.
            raise Error(_FAULT_TEXT)
        if path == String("/refusal"):
            # A DELIBERATE fail-closed refusal the handler CHOSE. It RETURNS,
            # so it never reaches the `except` arm — which is exactly why
            # nothing logged it before arm 2.
            var body = String('{"error":{"code":"') + _REFUSAL_CODE
            body += String('","message":"') + _REFUSAL_TEXT + String('"}}')
            var r = HttpResponse(status=Int32(503))
            r.headers[String("content-type")] = String("application/json")
            var b = body.as_bytes()
            for i in range(len(b)):
                r.body.append(b[i])
            r.headers[String("content-length")] = String(len(b))
            return r^
        return HttpResponse.ok(String("fine"))


# =============================================================================
# §2 — same-process raw-socket client (the `test_e2e_bring_up`
#      precedent).
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


def _client_socket() raises -> Int32:
    var fd = external_call["socket", Int32](
        Int32(_AF_INET), Int32(_SOCK_STREAM), Int32(0)
    )
    if fd < Int32(0):
        raise Error("socket() failed")
    return fd


def _connect(fd: Int32, port: UInt16) raises:
    var addr = _build_sockaddr_in_loopback(port)
    var addr_ptr = UnsafePointer(to=addr).bitcast[UInt8]()
    var rc = external_call["connect", Int32](fd, addr_ptr, UInt32(16))
    if rc < Int32(0):
        _ = external_call["close", Int32](fd)
        raise Error("connect() failed")


def _send_all(fd: Int32, bytes: List[UInt8]) raises:
    var total = len(bytes)
    var sent = 0
    var raw = bytes.unsafe_ptr()
    while sent < total:
        var rc = external_call["send", Int64](
            fd, raw + sent, UInt64(total - sent), Int32(0)
        )
        if rc <= Int64(0):
            raise Error("send() failed")
        sent = sent + Int(rc)


def _recv_some(fd: Int32, max_bytes: Int) raises -> List[UInt8]:
    var buf = List[UInt8]()
    buf.resize(unsafe_uninit_length=max_bytes)
    var raw = buf.unsafe_ptr()
    var n = external_call["recv", Int64](fd, raw, UInt64(max_bytes), Int32(0))
    if n < Int64(0):
        raise Error("recv() failed")
    var out = List[UInt8]()
    for i in range(Int(n)):
        out.append(buf[i])
    return out^


def _close(fd: Int32):
    _ = external_call["close", Int32](fd)


def _make_server() raises -> HttpServer[NoopGrpcDispatch]:
    return HttpServer(
        config=HttpServerConfig.default_ephemeral(), router=Router()
    )


def _drive(
    mut server: HttpServer[NoopGrpcDispatch],
    mut dispatcher: _FaultDispatcher,
    iters: Int,
    timeout_us: Int32,
) raises:
    for _ in range(iters):
        # ★ THE DEPLOYED ROUND. `serve_one_iteration_dispatch` — chain-less,
        # exactly what `_single_port_enabled()` selects on Cloud Run.
        _ = server.serve_one_iteration_dispatch[_FaultDispatcher, _Rt](
            dispatcher, timeout_us
        )


def _round_trip(
    mut server: HttpServer[NoopGrpcDispatch],
    mut dispatcher: _FaultDispatcher,
    path: String,
) raises -> String:
    """Send `GET <path>` on a fresh conn, drive the server, read the reply.

    ONE recv, deliberately: the client socket is BLOCKING, so a second recv
    after the reply is consumed would block forever. Every reply here is well
    under a loopback segment."""
    var port = server.local_port()
    var fd = _client_socket()
    _connect(fd, port)
    _drive(server, dispatcher, 4, Int32(300_000))
    var req = String("GET ") + path + String(" HTTP/1.1\r\n")
    req += String("Host: localhost\r\n")
    # A trace header, so the log line's join field is exercised on the wire
    # path too — that field is what makes the stdout entry findable from the
    # request entry, and it is read off the REQUEST, not synthesised.
    req += String("X-Cloud-Trace-Context: SOCKETTRACE001/7;o=1\r\n")
    req += String("Connection: close\r\n\r\n")
    _send_all(fd, _str_bytes(req))
    _drive(server, dispatcher, 24, Int32(100_000))
    var wire = _recv_some(fd, 1 << 20)
    _close(fd)
    return _to_str(wire)


def _str_bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _to_str(b: List[UInt8]) -> String:
    """Decode the wire bytes as UTF-8.

    ⚠ NOT a per-byte `chr(Int(b[i]))` loop, which is the obvious spelling and
    is WRONG here: `chr` maps a byte value to a CODEPOINT, so a 3-byte UTF-8
    character on the wire comes back as three separate characters and no
    comparison against a source literal containing it can ever match — the
    refusal text carries an em-dash, so the assertion would fail against a
    response that is byte-perfect. A gate that
    fails for a reason unrelated to its subject is worse than no gate: this one
    would have been "fixed" by weakening the assertion."""
    return String(StringSlice(unsafe_from_utf8=Span(b)))


# =============================================================================
# §3 — stdout capture. The log IS the deliverable, so the gate must read it.
# =============================================================================
# The response deliberately carries only a code + an incident id; the CAUSE
# goes to stdout. A gate that asserts only on the wire would therefore pass on
# a tree where the log line was deleted — and the log line is the half an
# operator actually reads. So this redirects fd 1 to a temp file for the
# duration of a round trip and asserts on what was written.
#
# NO FLUSH IS NEEDED, AND THAT IS A PROPERTY OF THE EMITTER, NOT AN OVERSIGHT:
# `fault_report._emit_line` writes each line with ONE unbuffered `write(2)` to
# fd 1 rather than `print`, so there is no userspace buffer that could be
# flushed to the RESTORED fd after the capture ends. Were it `print`, this
# capture would read empty and the gate would lie in the RED direction.


def _capture_path() raises -> String:
    """PID-qualified: concurrent test runs may share a scratch dir, and two
    captures on one path would interleave into a line neither test wrote."""
    var pid = external_call["getpid", Int32]()
    return (_scratch_dir() + String("/komira_fault_socket_capture.")) + String(Int(pid)) + String(".log")


def _begin_capture() raises -> Int32:
    var saved = external_call["dup", Int32](Int32(1))
    if saved < Int32(0):
        raise Error("dup(1) failed")
    var p = _capture_path()
    var pbytes = p.as_bytes()
    var cpath = List[UInt8]()
    for i in range(len(pbytes)):
        cpath.append(pbytes[i])
    cpath.append(UInt8(0))
    # `creat(path, mode)` is POSIX-defined as exactly
    # `open(path, O_WRONLY|O_CREAT|O_TRUNC, mode)` — the same syscall with the
    # same three flags, under a DIFFERENT C symbol. That matters under 1.0.0:
    # a hand-rolled `external_call["open"]` collides with the stdlib's own `open`
    # declaration (2 fixed args + varargs) once both are in one TU, and this file
    # already uses stdlib `open()` in `_end_capture`. The collision fails to
    # lower — "existing function with conflicting signature" — rather than
    # miscompiling. `k8s_config.mojo` documents the same class and takes the
    # same way out.
    var fd = external_call["creat", Int32](
        cpath.unsafe_ptr(), Int32(0o644)
    )
    if fd < Int32(0):
        raise Error("open(capture) failed")
    _ = external_call["dup2", Int32](fd, Int32(1))
    _ = external_call["close", Int32](fd)
    return saved


def _end_capture(saved: Int32) raises -> String:
    _ = external_call["dup2", Int32](saved, Int32(1))
    _ = external_call["close", Int32](saved)
    with open(_capture_path(), "r") as f:
        return f.read()


# =============================================================================
# §A — A FAULT IS ATTRIBUTED ON THE DEPLOYED ROUND.
# =============================================================================


def test_socket_fault_carries_code_and_incident() raises:
    """⭐ THE BINDING ASSERTION. A raise on the CHAIN-LESS round answers a 500
    that names its own cause.

    RED when the transport's `except` arm is reverted to `_ = e` +
    `HttpResponse.internal_error()` — because that
    answers `content-length: 0` and this asserts on a non-empty code and a
    non-empty incident id."""
    var server = _make_server()
    var d = _FaultDispatcher.new()
    var wire = _round_trip(server, d, String("/fault"))

    assert_true(
        _contains(wire, String("500")),
        String("expected a 500 status line, got: ") + _head_of(wire),
    )
    # THE CAUSE CODE — present and non-empty on the wire.
    assert_true(
        _contains(wire, String('"code":"') + FAULT_CODE_TRANSPORT + String('"')),
        String("a 500 reached the wire with NO cause code: ") + wire,
    )
    # THE INCIDENT ID — in the body AND the header, and non-trivial.
    assert_true(
        _contains(wire, String('"incidentId":"')),
        String("a 500 reached the wire with NO incident id: ") + wire,
    )
    assert_true(
        _contains(wire, String("x-incident-id:")),
        String("a 500 reached the wire with no x-incident-id header: ") + wire,
    )
    var incident = _json_field(wire, String("incidentId"))
    assert_equal(incident.byte_length(), 16)
    # The header and the body must name the SAME incident. Correlation that
    # disagrees sends an operator to the wrong log line.
    assert_true(_contains(_lower(wire), String("x-incident-id: ") + incident))

    # DISCLOSURE INVARIANT survives on the wire: no part of the raise text.
    assert_false(
        _contains(wire, String("tenant_secrets")),
        String("the raise text leaked onto the wire"),
    )
    assert_false(_contains(wire, String("<script>")))
    assert_false(
        _contains(wire, String("alice@customer.example")),
        String("a tenant email leaked onto the wire"),
    )
    _ = server^
    _ = d^


# =============================================================================
# §B — A REFUSAL SURVIVES THE DEPLOYED ROUND UNCHANGED.
# =============================================================================


def test_socket_refusal_is_not_laundered_into_a_fault() raises:
    """DIRECTION 2, ON THE WIRE. A deliberate 503 reaches the client with its
    own status, its own code and its own operator text — and is NOT stamped.

    RED when `observe_error_response` is made to rewrite (mutation 3), and RED
    for any implementation that "guarantees" §A by mapping every 5xx into the
    fault envelope."""
    var server = _make_server()
    var d = _FaultDispatcher.new()
    var wire = _round_trip(server, d, String("/refusal"))

    assert_true(
        _contains(wire, String("503")),
        String("a deliberate 503 was rewritten: ") + _head_of(wire),
    )
    assert_equal(_json_field(wire, String("code")), _REFUSAL_CODE)
    assert_true(
        _contains(wire, _REFUSAL_TEXT),
        String("the refusal lost its operator-actionable text: ") + wire,
    )
    assert_false(
        _contains(wire, FAULT_CODE_TRANSPORT),
        String("a refusal was laundered into a fault envelope"),
    )
    # NOT STAMPED — the boundary did not create this response.
    assert_false(
        _contains(_lower(wire), String("x-incident-id")),
        String("the transport stamped a response it did not create"),
    )
    _ = server^
    _ = d^


# =============================================================================
# §C — BOTH ARMS REACH THE LOG, ON THE DEPLOYED ROUND.
# =============================================================================


def test_socket_both_arms_emit_their_log_line() raises:
    """⭐ THE OTHER BINDING ASSERTION, and the one the wire cannot make.

    A fault's response deliberately withholds the cause, so §A stays green on a
    tree where the LOG LINE was deleted — and the log line is what an operator
    reads. A refusal's response is deliberately untouched, so NOTHING on the
    wire can witness `observe_error_response` at all.

    This captures fd 1 across both round trips and asserts each arm wrote its
    line, with the `source` field that tells them apart and the trace id that
    joins them to the request entry.

    RED when either transport call site is deleted."""
    var server = _make_server()
    var d = _FaultDispatcher.new()

    var saved = _begin_capture()
    var captured: String
    try:
        _ = _round_trip(server, d, String("/fault"))
        _ = _round_trip(server, d, String("/refusal"))
        captured = _end_capture(saved)
    except e:
        # Never leave fd 1 pointing at a temp file — a failure here would make
        # every later test's output vanish and look like a different defect.
        captured = _end_capture(saved)
        raise Error(String(e))

    # --- the FAULT arm reached the log, WITH the cause ---
    assert_true(
        _contains(captured, String('"severity":"ERROR"')),
        String("no ERROR-severity line was emitted: ") + captured,
    )
    assert_true(
        _contains(captured, String('"cause_code":"') + FAULT_CODE_TRANSPORT),
        String("the fault arm emitted no log line: ") + captured,
    )
    assert_true(
        _contains(captured, String("missing composite index")),
        String("the raise's CAUSE never reached the log: ") + captured,
    )
    assert_true(_contains(captured, String('"route":"/fault"')))
    # The trace join, read off the request header.
    assert_true(
        _contains(captured, String('"trace_id":"SOCKETTRACE001"')),
        String("the log line carries no trace join: ") + captured,
    )
    # Redaction holds on the deployed path too.
    assert_false(
        _contains(captured, String("alice@customer.example")),
        String("a tenant email reached the log: ") + captured,
    )

    # --- the REFUSAL arm reached the log, marked as RETURNED ---
    assert_true(
        _contains(captured, String('"source":"') + FAULT_SOURCE_RESPONSE),
        String("the returned-5xx arm emitted no log line: ") + captured,
    )
    assert_true(
        _contains(captured, String('"route":"/refusal"')),
        String("the refusal's route is not in the log: ") + captured,
    )
    assert_true(_contains(captured, String('"status":503')))
    _ = server^
    _ = d^


# =============================================================================
# §D — A 2xx IS NEITHER ATTRIBUTED NOR LOGGED.
# =============================================================================


def test_socket_success_is_untouched_and_unlogged() raises:
    """ANTI-VACUITY. If every response were stamped and every response logged,
    §A and §C would pass while saying nothing. A 200 must come back clean and
    must NOT appear at ERROR severity — a 2xx body is customer content and has
    no business in a retained log."""
    var server = _make_server()
    var d = _FaultDispatcher.new()

    var saved = _begin_capture()
    var captured: String
    var wire: String
    try:
        wire = _round_trip(server, d, String("/ok"))
        captured = _end_capture(saved)
    except e:
        captured = _end_capture(saved)
        raise Error(String(e))

    assert_true(_contains(wire, String("200")))
    assert_true(_contains(wire, String("fine")))
    assert_false(
        _contains(_lower(wire), String("x-incident-id")),
        String("a 200 was stamped with an incident id"),
    )
    assert_false(
        _contains(captured, String('"severity":"ERROR"')),
        String("a 200 produced an ERROR log line: ") + captured,
    )
    assert_false(
        _contains(captured, String("fine")),
        String("a 2xx body reached the log: ") + captured,
    )
    _ = server^
    _ = d^


# -----------------------------------------------------------------------------
# helpers
# -----------------------------------------------------------------------------


def _head_of(wire: String) -> String:
    var b = wire.as_bytes()
    var n = len(b)
    if n > 120:
        n = 120
    var s = String("")
    for i in range(n):
        s += chr(Int(b[i]))
    return s^


def _lower(s: String) -> String:
    var out = String("")
    var b = s.as_bytes()
    for i in range(len(b)):
        var c = b[i]
        if c >= UInt8(65) and c <= UInt8(90):
            out += chr(Int(c) + 32)
        else:
            out += chr(Int(c))
    return out^


def _contains(haystack: String, needle: String) -> Bool:
    var h = haystack.as_bytes()
    var n = needle.as_bytes()
    var hn = len(h)
    var nn = len(n)
    if nn == 0:
        return True
    if nn > hn:
        return False
    var i = 0
    while i + nn <= hn:
        var matched = True
        var j = 0
        while j < nn:
            if h[i + j] != n[j]:
                matched = False
                break
            j = j + 1
        if matched:
            return True
        i = i + 1
    return False


def _json_field(body: String, key: String) -> String:
    """Extract `"<key>":"<value>"` from the wire. Deliberately tiny and NOT
    shared with the emitter — a shared serializer would make the gate agree
    with a broken emitter by construction."""
    var pat = String('"') + key + String('":"')
    var h = body.as_bytes()
    var p = pat.as_bytes()
    var hn = len(h)
    var pn = len(p)
    var i = 0
    while i + pn <= hn:
        var matched = True
        var j = 0
        while j < pn:
            if h[i + j] != p[j]:
                matched = False
                break
            j = j + 1
        if matched:
            var out = String("")
            var k = i + pn
            while k < hn:
                if h[k] == UInt8(34):
                    return out^
                out += chr(Int(h[k]))
                k = k + 1
            return out^
        i = i + 1
    return String("")


def main() raises:
    test_socket_fault_carries_code_and_incident()
    test_socket_refusal_is_not_laundered_into_a_fault()
    test_socket_both_arms_emit_their_log_line()
    test_socket_success_is_untouched_and_unlogged()
    print("test_e2e_fault_attribution_socket: OK")
