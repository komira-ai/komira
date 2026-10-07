# =============================================================================
# test_e2e_live_socket.mojo -- GrpcClient against a live ConnectService server
# over TLS + h2 on a loopback socket
# =============================================================================
#
# A real `HttpServer[ConnectService]` holding komira_http_core's fixture leaf
# (ALPN `h2`, `http/1.1`) on 127.0.0.1:0, stepped through its TLS accept path,
# its ALPN pivot to h2 and `serve_read_round_h2`, which routes every RPC
# content-type to the `GrpcDispatch` seam and writes the answer with
# `komira_http_core.transport.grpc_emit`. On the other thread a real
# `GrpcClient[TlsConnector[KernelTcpConnector]]` (trusting only the fixture
# root, SNI `localhost`, ALPN `h2` first) drives it over the pooled h2 path.
#
# WHAT IS NEW HERE, against the tests that already exist:
#   * komira_grpc `test_e2e_full_loop` calls `ConnectService.handle_request`
#     directly: no transport at all.
#   * komira_grpc `test_e2e_grpc_client` drives `GrpcClient` over a
#     `ScriptedConnector` replaying a canned HTTP/1.1 response whose body the
#     test built from `handle_request`: no socket, no TLS, no h2, no trailer
#     frame, no server serve loop.
#   * komira_connect `test_e2e_*` run the server-side codecs and dispatch
#     in-process: no client, no wire.
#   * komira_http_server `test_e2e_fault_attribution_socket` is a real socket,
#     but plaintext HTTP/1.1 against a raw-socket client, with no gRPC.
# This file is the first to put both halves on a real TLS connection: the
# handshake, ALPN, h2 framing and HPACK both ways across several RPCs, the
# trailing HEADERS frame that carries `grpc-status`, and a server stream's
# messages followed by its trailer. It does NOT assert how many connections
# the client opened or how the stream's messages were split into DATA frames.
#
# The legs, all against ONE server:
#   A. unary Echo over classic gRPC: the echo bytes come back through
#      `GrpcClient.unary_call`.
#   B. a failing handler: `[grpc:9]` FAILED_PRECONDITION reaches the caller
#      with its message intact; the message carries non-ASCII text, a
#      literal `%` and a TAB, so it round-trips through percent-encoding.
#   C. the server stays usable: Echo again with the same client.
#   D. server streaming: N messages arrive in order.
#   E. unary Echo and the failing handler over Connect (application/json),
#      as the GrpcClient sees them.
#   F. the raw response sections, read with a second plain `HttpClient` (the
#      `GrpcClient` does not expose them): `grpc-status` is in the TRAILING
#      HEADERS block and not in the initial one, `grpc-message` is the exact
#      percent-encoded text (written out by hand here, not computed by the
#      encoder under test), the stream's N messages are followed by the
#      trailer (`ServerStreamDecoder` fed the trailer block yields END_OK after
#      exactly N messages), a Connect-JSON response carries no trailer, and
#      a failing Connect-JSON call answers the Connect HTTP status for
#      FAILED_PRECONDITION (400) with the JSON error body written out by hand
#      (the GrpcClient takes the code from the body, so only this sub-leg
#      pins the server's status-to-HTTP table on the wire).
#   G. the server's own counter: exactly one response per RPC sent.
#
# NOT COVERED: `grpc-timeout`. No layer honours it today: the server's
# `GrpcDispatch` seam receives (path, content-type, body) and no headers, and
# the client turns `CallOptions.deadline_micros` into the `grpc-timeout`
# header only (no local timer trips its cancellation token). A 1 ms
# `grpc-timeout` against a slow handler therefore returns OK; that leg is
# left out rather than asserted green over the gap.
#
# NOT COVERED: the Router's Connect wildcard route (the HTTP/1.1 path).
# `register_connect_wildcard` is mounted as a server would mount it, but ALPN
# selects h2 and the h2 serve loop hands RPC content-types to the service
# directly, so deleting that line would not fail this test.
#
# THE THREADS: `GrpcClient` blocks its thread until a call completes and
# `HttpServer` only progresses when its serve loop is stepped, so they run on
# two `komira_fork_join` threads (`_serve_while`): the server is stepped on
# thread 0 until an atomic stop flag flips, the client runs on thread 1 and
# sets that flag in a `finally`, and the server gives up after 120 s.
#
# MUTANTS PLANTED (product code, reverted), each red in this test when this
# test is the only gate in the way:
#   1. grpc_emit.mojo: drop the trailer on a successful unary call (END_STREAM
#      on the DATA frame, no trailing HEADERS): leg F reds at F1 (no
#      `grpc-status` trailer). Legs A to E stay green under this mutant:
#      `GrpcClient.unary_call` reads a missing `grpc-status` as success. On a
#      normal tree komira_connect's test_L5_grpc_trailer_emit fails first and
#      gates this library out of the build; this test reds at F1 with that
#      upstream test unwelded for the probe.
#   2. grpc_emit.mojo: swap a status on the wire (9 <-> 3 in
#      `_emit_grpc_trailer`): leg B reds (`[grpc:3]` where 9 was raised). No
#      upstream welded test catches it.
#   3. komira_connect status.mojo: `grpc_status_to_http_status` answers 500
#      for FAILED_PRECONDITION: leg F5 reds (the GrpcClient legs stay green,
#      they read the code from the JSON body).
#   4. komira_connect codec_connect_json.mojo: write a TAB in an error message
#      raw instead of as `\t`: leg F5 reds on the body bytes (leg E stays
#      green: the client's tolerant scanner reads the raw TAB back).
#   Mutant 3 is also caught by komira_connect's test_L5_status and
#   test_L5_conformance_code_mapping, which gate this library out; this test
#   reds at F5 with those two unwelded for the probe. Mutant 4 is caught by no
#   upstream welded test.
#
# HERMETIC: in-process server, loopback socket, throwaway certificates staged
# by `test_data`, no network beyond 127.0.0.1.
# =============================================================================

from std.memory import Pointer
from std.pathlib import Path
from std.testing import assert_equal, assert_false, assert_true

from komira_atomic_alias import AtomicI64
from komira_clock import now_ns
from komira_fork_join import ForkJoinBody, fork_join

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import Reactor
from komira_async.runtime.blocking_runtime import BlockingRuntime

from komira_http_client.body import BytesBody
from komira_http_client.client import HttpClient, build_streaming_request
from komira_http_client.header_map import HeaderMap
from komira_http_client.pool import VERIFY_PEER
from komira_http_client.request_writer import method_post
from komira_http_client.response_body import collect_body
from komira_http_client.tls_connector import TlsConnector
from komira_http_client.url import Url
from komira_http_core.tls import TlsConfig, tls_init
from komira_http_core.transport.kernel_tcp import KernelTcpConnector
from komira_http_server.routing import Router
from komira_http_server.server import HttpServer, HttpServerConfig

from komira_connect import (
    ConnectService,
    format_connect_error,
    register_connect_wildcard,
)

from komira_grpc import (
    CallOptions,
    GRPC_STATUS_FAILED_PRECONDITION,
    GRPC_STATUS_INVALID_ARGUMENT,
    GrpcClient,
    ProtocolConnectJson,
    ProtocolGrpcProto,
    STREAM_OUTCOME_END_OK,
    STREAM_OUTCOME_MESSAGE,
    STREAM_OUTCOME_PENDING,
    ServerStreamDecoder,
    build_stream_request_headers,
    build_unary_request_headers,
    decode_unary_response,
    encode_stream_message,
    encode_unary_request,
    parse_grpc_error_message,
)

comptime _Rt = BlockingRuntime[NoopSink]
comptime _Tls = TlsConnector[KernelTcpConnector]

comptime _ECHO = "/komira.e2e.v1.Probe/Echo"
comptime _FAIL = "/komira.e2e.v1.Probe/Fail"
comptime _COUNT = "/komira.e2e.v1.Probe/Count"

# The failing handler's message: non-ASCII text (U+00E9, two UTF-8 bytes, and
# U+2014, three), a literal percent sign and a control byte (TAB): every case
# of the gRPC percent-encoding. Before the non-ASCII fix in komira_connect and
# komira_grpc, this message aborted the server process.
comptime _FAIL_TEXT = "café — 100% sure\tor not"
# Its percent-encoding per the gRPC HTTP/2 spec, written out by hand: each
# UTF-8 byte outside 0x20..0x7e and `%` itself become `%XX`.
comptime _FAIL_TEXT_WIRE = "caf%C3%A9 %E2%80%94 100%25 sure%09or not"

# The Connect-JSON error body for it, written out by hand: the Connect name
# of code 9 and the message as raw UTF-8 with its TAB as the JSON escape `\t`.
comptime _FAIL_JSON_WIRE = '{"code":"failed_precondition","message":"café — 100% sure\\tor not"}'

comptime _STREAM_N = 12

comptime _LEAF_CERT = "src/komira_http_core/tests/fixtures/tls/leaf_cert.pem"
comptime _LEAF_KEY = "src/komira_http_core/tests/fixtures/tls/leaf_key.pem"
comptime _ROOT_CA = "src/komira_http_core/tests/fixtures/tls/root_ca.pem"

comptime _HANDSHAKE_DEADLINE_US: Int64 = 10_000_000
comptime _REQUEST_TIMEOUT_US = 10_000_000
comptime _SERVE_POLL_TIMEOUT_US: Int32 = 5_000
comptime _SERVE_DEADLINE_NS: UInt64 = 120_000_000_000


# =============================================================================
# §1 -- the handlers the server registers
# =============================================================================


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _echo_handler(codec_id: UInt8, req_body: List[UInt8]) raises -> List[UInt8]:
    """Answers `echo:` followed by the request bytes, so a reply that merely
    reflects the request cannot pass."""
    var out = _bytes(String("echo:"))
    for i in range(len(req_body)):
        out.append(req_body[i])
    return out^


def _fail_handler(codec_id: UInt8, req_body: List[UInt8]) raises -> List[UInt8]:
    raise Error(format_connect_error(GRPC_STATUS_FAILED_PRECONDITION, _FAIL_TEXT))


def _count_handler(
    codec_id: UInt8, kind: UInt8, req_messages: List[List[UInt8]]
) raises -> List[List[UInt8]]:
    """Server streaming: the one request message is a single byte N; answers
    N messages `frame-0` .. `frame-<N-1>`."""
    if len(req_messages) != 1 or len(req_messages[0]) != 1:
        raise Error(
            format_connect_error(
                GRPC_STATUS_INVALID_ARGUMENT, String("want one 1-byte message")
            )
        )
    var n = Int(req_messages[0][0])
    var out = List[List[UInt8]]()
    for i in range(n):
        out.append(_bytes(String("frame-") + String(i)))
    return out^


def _service() -> ConnectService:
    var svc = ConnectService(String("komira.e2e.v1.Probe"))
    svc.register_method(String(_ECHO), _echo_handler)
    svc.register_method(String(_FAIL), _fail_handler)
    svc.register_server_stream(String(_COUNT), _count_handler)
    return svc^


# =============================================================================
# §2 -- TLS material (komira_http_core's fixtures, staged by test_data)
# =============================================================================


def _read_fixture(path: StaticString) raises -> String:
    return Path(String(path)).read_text()


def _server_tls_config() raises -> TlsConfig:
    var config = TlsConfig()
    config.set_cipher_preferences(String("default_tls13"))
    config.load_cert(_read_fixture(_LEAF_CERT), _read_fixture(_LEAF_KEY))
    var alpn = List[String]()
    alpn.append(String("h2"))
    alpn.append(String("http/1.1"))
    config.set_alpn_protocols(alpn)
    return config^


def _client_connector() raises -> _Tls:
    """Trusts only the fixture root, pins SNI `localhost`, offers h2 first."""
    var config = TlsConfig()
    config.set_cipher_preferences(String("default_tls13"))
    config.wipe_trust()
    config.add_trust_pem(_read_fixture(_ROOT_CA))
    config.enable_verify_default()
    var alpn = List[String]()
    alpn.append(String("h2"))
    alpn.append(String("http/1.1"))
    config.set_alpn_protocols(alpn)
    var connector = _Tls(config^, KernelTcpConnector.new(), VERIFY_PEER)
    connector.set_server_name_for_next_connect(String("localhost"))
    connector.set_handshake_deadline_us(_HANDSHAKE_DEADLINE_US)
    return connector^


def _http_client() raises -> HttpClient[_Tls]:
    return HttpClient[_Tls].with_request_timeout_us(
        _client_connector(), _REQUEST_TIMEOUT_US
    )


# =============================================================================
# §3 -- one server and one client on two threads (the duet pattern, copied)
# =============================================================================


trait _ClientLeg(Movable):
    def run(mut self) raises:
        ...


struct _GrpcServeLoop(Movable):
    """The server, stepped one bounded poll at a time by thread 0 only."""

    var server: HttpServer[ConnectService]

    def __init__(out self, var server: HttpServer[ConnectService]):
        self.server = server^

    def step(mut self) raises:
        _ = self.server.serve_one_iteration(_SERVE_POLL_TIMEOUT_US)


struct _StopFlag(Movable):
    var stop: AtomicI64

    def __init__(out self):
        self.stop = AtomicI64(Int64(0))


struct _Duet[
    C: _ClientLeg, so: MutOrigin, co: MutOrigin, fo: MutOrigin
](ForkJoinBody):
    """The two-thread body of `_serve_while`."""

    # SAFETY: the three fields borrow `_serve_while`'s locals with concrete
    # origins; that frame outlives both threads because `fork_join` joins
    # inside it. `run` mutates through an immutably borrowed `self`, which is
    # sound because tid 0 alone dereferences `server`, tid 1 alone
    # dereferences `client`, and `flag` is only touched through its AtomicI64.
    var server: Pointer[_GrpcServeLoop, Self.so]
    var client: Pointer[Self.C, Self.co]
    var flag: Pointer[_StopFlag, Self.fo]

    def __init__(
        out self,
        server: Pointer[_GrpcServeLoop, Self.so],
        client: Pointer[Self.C, Self.co],
        flag: Pointer[_StopFlag, Self.fo],
    ):
        self.server = server
        self.client = client
        self.flag = flag

    def run(self, tid: Int) raises:
        if tid == 0:
            var give_up = now_ns() + _SERVE_DEADLINE_NS
            while self.flag[].stop.load() == Int64(0):
                if now_ns() >= give_up:
                    raise Error("serve_while: the client did not finish in time")
                self.server[].step()
            return
        try:
            self.client[].run()
        finally:
            _ = self.flag[].stop.fetch_add(Int64(1))


def _serve_while[C: _ClientLeg](mut server: _GrpcServeLoop, mut client: C) raises:
    """Step `server` on one thread while `client.run()` runs on another. On a
    failure `fork_join` rethrows the lowest tid's error: the server's if its
    step raised, else the client's."""
    var flag = _StopFlag()
    var duet = _Duet(Pointer(to=server), Pointer(to=client), Pointer(to=flag))
    fork_join(duet, 2)
    _ = duet^
    _ = flag^


# =============================================================================
# §4 -- helpers the client leg asserts with
# =============================================================================


def _now_us() -> Int:
    return Int(now_ns() // 1000)


def _same(got: List[UInt8], want: String) -> Bool:
    var w = want.as_bytes()
    if len(got) != len(w):
        return False
    for i in range(len(w)):
        if got[i] != w[i]:
            return False
    return True


def _show(b: List[UInt8]) -> String:
    """Printable form of `b` for an assertion message (bytes outside ASCII
    as `<decimal>`)."""
    var s = String()
    for i in range(len(b)):
        var c = Int(b[i])
        if c >= 0x20 and c < 0x7F:
            s += chr(c)
        else:
            s += String("<") + String(c) + String(">")
    return s^


def _header_or(value: Optional[String]) -> String:
    if value:
        return value.value()
    return String("<absent>")


@fieldwise_init
struct _RawCall(Movable):
    """What the raw `HttpClient` saw of one RPC: the status, the two header
    sections kept apart, and the body bytes."""

    var status: Int32
    var content_type: String
    var head_has_grpc_status: Bool
    var trailer_count: Int
    var trailer_status: String
    var trailer_message: String
    var body: List[UInt8]


def _raw_send(
    mut http: HttpClient[_Tls],
    port: UInt16,
    path: StaticString,
    var hdrs: HeaderMap,
    var body: List[UInt8],
) raises -> _RawCall:
    var rt = _Rt.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var req = build_streaming_request[BytesBody](
        method_post(),
        Url.https(String("127.0.0.1"), port, String(path)),
        hdrs^,
        BytesBody.from_bytes(body^),
    )
    var resp = http.send_grpc_pooled[_Rt, BytesBody](req^, reactor)
    var token = CancellationToken.new()
    var bytes = collect_body[_Rt](resp.body, reactor, token)
    return _RawCall(
        status=resp.status,
        content_type=_header_or(resp.headers.get(String("content-type"))),
        head_has_grpc_status=resp.headers.contains(String("grpc-status")),
        trailer_count=resp.trailers.len(),
        trailer_status=_header_or(resp.trailers.get(String("grpc-status"))),
        trailer_message=_header_or(resp.trailers.get(String("grpc-message"))),
        body=bytes^,
    )


# =============================================================================
# §5 -- the client leg
# =============================================================================


struct _AllLegs(_ClientLeg):
    var port: UInt16
    var calls: Int

    def __init__(out self, port: UInt16):
        self.port = port
        self.calls = 0

    def run(mut self) raises:
        var rt = _Rt.new(NoopSink(_placeholder=UInt8(0)))
        ref reactor = rt.reactor()
        var token = CancellationToken.new()
        var client = GrpcClient[_Tls](
            _http_client(), Url.https(String("127.0.0.1"), self.port, String("/"))
        )
        self._leg_a_unary_echo(client, reactor, token)
        self._leg_b_failing_handler(client, reactor, token)
        # C. The failing call left the connection and the server usable.
        self._leg_a_unary_echo(client, reactor, token)
        self._leg_d_server_stream(client, reactor, token)
        self._leg_e_connect_json(client, reactor, token)
        self._leg_f_raw_sections()

    def _leg_a_unary_echo(
        mut self,
        mut client: GrpcClient[_Tls],
        mut reactor: Reactor[NoopSink],
        ref token: CancellationToken,
    ) raises:
        var msg = _bytes(String("ping"))
        var res = client.unary_call[_Rt, ProtocolGrpcProto](
            String(_ECHO), Span(msg), CallOptions(), _now_us(), reactor, token
        )
        self.calls += 1
        assert_equal(Int(res.http_status), 200, "A: HTTP status")
        assert_true(
            _same(res.message_bytes, String("echo:ping")),
            String("A: echo bytes, got ") + _show(res.message_bytes),
        )
        print("  A unary echo over gRPC PASS")

    def _leg_b_failing_handler(
        mut self,
        mut client: GrpcClient[_Tls],
        mut reactor: Reactor[NoopSink],
        ref token: CancellationToken,
    ) raises:
        var msg = _bytes(String("x"))
        var caught = String("")
        try:
            _ = client.unary_call[_Rt, ProtocolGrpcProto](
                String(_FAIL), Span(msg), CallOptions(), _now_us(), reactor, token
            )
        except e:
            caught = String(e)
        self.calls += 1
        assert_true(caught.byte_length() > 0, "B: a failing handler must raise")
        var parsed = parse_grpc_error_message(caught)
        assert_equal(
            Int(parsed[0]),
            Int(GRPC_STATUS_FAILED_PRECONDITION),
            String("B: [grpc:N] code, raised: ") + caught,
        )
        assert_equal(parsed[1], String(_FAIL_TEXT), "B: grpc-message round trip")
        print("  B failing handler -> [grpc:9] with its message PASS")

    def _leg_d_server_stream(
        mut self,
        mut client: GrpcClient[_Tls],
        mut reactor: Reactor[NoopSink],
        ref token: CancellationToken,
    ) raises:
        var req = List[UInt8]()
        req.append(UInt8(_STREAM_N))
        var decoder = client.server_stream[_Rt, ProtocolGrpcProto](
            String(_COUNT), Span(req), CallOptions(), _now_us(), reactor, token
        )
        self.calls += 1
        var got = 0
        while True:
            var outcome = decoder.try_next_message()
            if outcome.kind == STREAM_OUTCOME_MESSAGE:
                assert_true(
                    _same(outcome.message_bytes, String("frame-") + String(got)),
                    String("D: message ") + String(got) + " out of order: "
                    + _show(outcome.message_bytes),
                )
                got += 1
                continue
            # `server_stream` checks the trailer's grpc-status itself (a
            # non-OK close raises above) but does not feed the trailer block
            # to the decoder it returns, so the buffered stream ends PENDING
            # (or END_OK). Leg F3 checks the trailer bytes.
            assert_true(
                outcome.kind == STREAM_OUTCOME_PENDING
                or outcome.kind == STREAM_OUTCOME_END_OK,
                String("D: unexpected outcome kind ") + String(Int(outcome.kind)),
            )
            break
        assert_equal(got, _STREAM_N, "D: streamed message count")
        print("  D server stream: N messages in order PASS")

    def _leg_e_connect_json(
        mut self,
        mut client: GrpcClient[_Tls],
        mut reactor: Reactor[NoopSink],
        ref token: CancellationToken,
    ) raises:
        var msg = _bytes(String('{"q":"json"}'))
        var res = client.unary_call[_Rt, ProtocolConnectJson](
            String(_ECHO), Span(msg), CallOptions(), _now_us(), reactor, token
        )
        self.calls += 1
        assert_equal(Int(res.http_status), 200, "E: Connect HTTP status")
        assert_true(
            _same(res.message_bytes, String('echo:{"q":"json"}')),
            String("E: Connect echo bytes, got ") + _show(res.message_bytes),
        )
        var caught = String("")
        try:
            _ = client.unary_call[_Rt, ProtocolConnectJson](
                String(_FAIL), Span(msg), CallOptions(), _now_us(), reactor, token
            )
        except e:
            caught = String(e)
        self.calls += 1
        assert_true(
            caught.byte_length() > 0,
            "E: a failing handler over Connect-JSON must raise",
        )
        var parsed = parse_grpc_error_message(caught)
        assert_equal(
            Int(parsed[0]),
            Int(GRPC_STATUS_FAILED_PRECONDITION),
            String("E: Connect error code, raised: ") + caught,
        )
        assert_equal(parsed[1], String(_FAIL_TEXT), "E: Connect error message")
        print("  E unary echo + failing handler over Connect-JSON PASS")

    def _leg_f_raw_sections(mut self) raises:
        var http = _http_client()

        # F1. Unary success: status 200, grpc-status only in the trailer.
        var raw_msg = _bytes(String("raw"))
        var u = _raw_send(
            http,
            self.port,
            _ECHO,
            build_unary_request_headers[ProtocolGrpcProto](CallOptions(), _now_us()),
            encode_unary_request[ProtocolGrpcProto](Span(raw_msg)),
        )
        self.calls += 1
        assert_equal(Int(u.status), 200, "F1: :status")
        assert_equal(u.content_type, String("application/grpc+proto"), "F1: content-type")
        assert_false(u.head_has_grpc_status, "F1: grpc-status leaked into the initial HEADERS")
        assert_equal(u.trailer_status, String("0"), "F1: grpc-status in the trailing HEADERS")
        assert_equal(u.trailer_message, String("<absent>"), "F1: no grpc-message on OK")
        # The body is one envelope: flag 0, big-endian length 8, `echo:raw`.
        assert_equal(len(u.body), 13, String("F1: body length, got ") + _show(u.body))
        assert_equal(Int(u.body[0]), 0, "F1: envelope flag")
        assert_equal(Int(u.body[4]), 8, "F1: envelope length")
        var inner = decode_unary_response[ProtocolGrpcProto](Span(u.body), UInt16(200))
        var inner_copy = List[UInt8]()
        for i in range(len(inner)):
            inner_copy.append(inner[i])
        assert_true(_same(inner_copy, String("echo:raw")), "F1: payload")

        var x_msg = _bytes(String("x"))
        # F2. Unary failure: 200, no body, trailer status 9 + the exact
        # percent-encoded message.
        var f = _raw_send(
            http,
            self.port,
            _FAIL,
            build_unary_request_headers[ProtocolGrpcProto](CallOptions(), _now_us()),
            encode_unary_request[ProtocolGrpcProto](Span(x_msg)),
        )
        self.calls += 1
        assert_equal(Int(f.status), 200, "F2: a failing RPC still answers :status 200")
        assert_false(f.head_has_grpc_status, "F2: not a trailers-only reply")
        assert_equal(f.trailer_status, String("9"), "F2: grpc-status trailer")
        assert_equal(f.trailer_message, String(_FAIL_TEXT_WIRE), "F2: grpc-message on the wire")
        assert_equal(len(f.body), 0, "F2: no DATA on a failed unary call")

        # F3. Server stream: N envelopes, then the trailer; a decoder fed both
        # yields exactly N messages and then END_OK.
        var sbody = List[UInt8]()
        var one = List[UInt8]()
        one.append(UInt8(_STREAM_N))
        encode_stream_message[ProtocolGrpcProto](sbody, Span(one))
        var s = _raw_send(
            http,
            self.port,
            _COUNT,
            build_stream_request_headers[ProtocolGrpcProto](CallOptions(), _now_us()),
            sbody^,
        )
        self.calls += 1
        assert_equal(Int(s.status), 200, "F3: :status")
        assert_false(s.head_has_grpc_status, "F3: grpc-status leaked into the initial HEADERS")
        assert_equal(s.trailer_status, String("0"), "F3: stream closes with grpc-status 0")
        var decoder = ServerStreamDecoder[ProtocolGrpcProto].new()
        decoder.feed(Span(s.body))
        var trailers = HeaderMap()
        trailers.insert(String("grpc-status"), s.trailer_status.copy())
        decoder.feed_trailers(trailers)
        var n = 0
        while True:
            var outcome = decoder.try_next_message()
            if outcome.kind != STREAM_OUTCOME_MESSAGE:
                assert_equal(
                    Int(outcome.kind),
                    Int(STREAM_OUTCOME_END_OK),
                    "F3: after the messages, the trailer ends the stream OK",
                )
                break
            assert_true(
                _same(outcome.message_bytes, String("frame-") + String(n)),
                String("F3: message ") + String(n),
            )
            n += 1
        assert_equal(n, _STREAM_N, "F3: messages before the trailer")

        var empty_json = _bytes(String("{}"))
        # F4. Connect-JSON: an ordinary h2 close, no trailer block at all.
        var c = _raw_send(
            http,
            self.port,
            _ECHO,
            build_unary_request_headers[ProtocolConnectJson](CallOptions(), _now_us()),
            encode_unary_request[ProtocolConnectJson](Span(empty_json)),
        )
        self.calls += 1
        assert_equal(Int(c.status), 200, "F4: :status")
        assert_equal(c.content_type, String("application/json"), "F4: content-type")
        assert_equal(c.trailer_count, 0, "F4: Connect unary carries no trailer")
        assert_true(_same(c.body, String("echo:{}")), String("F4: body ") + _show(c.body))

        # F5. Connect-JSON failure: the Connect HTTP status for
        # FAILED_PRECONDITION is 400, the body is the JSON error envelope
        # (non-ASCII as raw UTF-8, TAB escaped as `\t`), and there is no
        # trailer block.
        var e = _raw_send(
            http,
            self.port,
            _FAIL,
            build_unary_request_headers[ProtocolConnectJson](CallOptions(), _now_us()),
            encode_unary_request[ProtocolConnectJson](Span(empty_json)),
        )
        self.calls += 1
        assert_equal(Int(e.status), 400, "F5: Connect :status for failed_precondition")
        assert_equal(e.content_type, String("application/json"), "F5: content-type")
        assert_equal(e.trailer_count, 0, "F5: Connect error carries no trailer")
        assert_true(
            _same(e.body, _FAIL_JSON_WIRE),
            String("F5: error body ") + _show(e.body),
        )
        print("  F raw sections: trailer status/message, stream close, Connect PASS")


# =============================================================================
# §6 -- the test
# =============================================================================


def test_grpc_client_against_live_tls_h2_server() raises:
    var router = Router()
    # Mounted as a server would; not exercised here (see the header, NOT
    # COVERED: the h2 serve loop routes RPC content-types to the service).
    _ = register_connect_wildcard(router)
    var server = HttpServer[ConnectService](
        config=HttpServerConfig.default_ephemeral(),
        router=router^,
        tls_config=_server_tls_config(),
        grpc=_service(),
    )
    var port = server.local_port()
    var loop = _GrpcServeLoop(server^)
    var legs = _AllLegs(port)
    _serve_while(loop, legs)

    # G. One response per RPC sent: no retry, no duplicate, none lost.
    var stats = loop.server.serve_for_iterations(0, Int32(0))
    assert_equal(legs.calls, 11, "RPCs the client sent")
    assert_equal(Int(stats.reqs_handled), legs.calls, "G: responses the server wrote")
    print("  G server wrote one response per RPC PASS")


def main() raises:
    tls_init()
    test_grpc_client_against_live_tls_h2_server()
    print("PASS komira_grpc test_e2e_live_socket")
