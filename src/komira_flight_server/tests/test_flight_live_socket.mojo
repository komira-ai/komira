# =============================================================================
# test_flight_live_socket.mojo: the Flight service over a real TLS + h2 socket
# =============================================================================
#
# A real `HttpServer[FlightBrokerService]` holding komira_http_core's fixture
# leaf (ALPN `h2`) on a loopback port, stepped through its TLS accept, its ALPN
# pivot to h2 and the gRPC dispatch seams. On the other thread a real
# `GrpcClient` (trusting only the fixture root, SNI `localhost`) drives it with
# the three Flight RPCs over one pooled h2 connection:
#
#   A. DoPut  (client stream): schema + two batches to topic "t1" -> PutResult.
#   B. GetFlightInfo (unary): the schema, one endpoint, total_records 6.
#   C. DoGet  (server stream): the ticket from B returns the schema message and
#      the two batches, whose values come back in the order they were put.
#   D. partitions: a DoPut to partition 2 of "orders" (path[1] = "2") creates
#      three partitions; GetFlightInfo lists three endpoints; DoGet on the
#      endpoint of partition 2 returns the rows, on partition 1 none.
#   E. refusals reach the client as their gRPC status: DoGet of an unknown
#      topic is `[grpc:5]`, a DoPut to partition "abc" is `[grpc:3]`.
#   F. the server's own counter: exactly one response per RPC sent.
#
# This proves the wire framing (envelopes, the trailing `grpc-status`, the
# schema-first stream) over a real transport against komira's own gRPC client.
# It is not an interoperability test against another Flight implementation: no
# third-party Flight client runs here.
#
# THE THREADS: `GrpcClient` blocks its thread until a call completes and
# `HttpServer` only progresses when its serve loop is stepped, so they run on
# two `komira_fork_join` threads (`_serve_while`): the server is stepped on
# thread 0 until an atomic stop flag flips, the client runs on thread 1 and sets
# that flag in a `finally`. The serve loop has no deadline of its own; the
# client leg is bounded by the client's handshake deadline and request timeout
# (below), and an event that nothing bounds is stopped by the build gate's hang
# limit (`test_hang_limit_s`), which fails the test.
#
# HERMETIC: in-process server, loopback socket, throwaway certificates staged
# by `test_data`, no network beyond the loopback address.
# =============================================================================

from std.memory import Pointer
from std.pathlib import Path
from std.testing import assert_equal, assert_true

from komira_atomic_alias import AtomicI64
from komira_clock import now_ns
from komira_fork_join import ForkJoinBody, fork_join

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import Reactor
from komira_async.runtime.blocking_runtime import BlockingRuntime

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema

from komira_http_client.client import HttpClient
from komira_http_client.pool import VERIFY_PEER
from komira_http_client.tls_connector import TlsConnector
from komira_http_client.url import Url
from komira_http_core.tls import TlsConfig, tls_init
from komira_http_core.transport.kernel_tcp import KernelTcpConnector
from komira_http_server.routing import Router
from komira_http_server.server import HttpServer, HttpServerConfig

from komira_grpc import (
    CallOptions,
    ClientStreamEncoder,
    GrpcClient,
    ProtocolGrpcProto,
    STREAM_OUTCOME_END_OK,
    STREAM_OUTCOME_MESSAGE,
    STREAM_OUTCOME_PENDING,
    ServerStreamDecoder,
    parse_grpc_error_message,
)

from komira_flight import (
    BrokerTicket,
    FlightData,
    FlightDescriptor,
    FlightInfo,
    Ticket,
    encode_batch_flight_data,
    encode_schema_flight_data,
    flight_data_to_record_batch,
)
from komira_flight_server import (
    FLIGHT_DO_GET_PATH,
    FLIGHT_DO_PUT_PATH,
    FLIGHT_GET_INFO_PATH,
    FlightBrokerData,
    FlightBrokerService,
)

comptime _Rt = BlockingRuntime[NoopSink]
comptime _Tls = TlsConnector[KernelTcpConnector]

comptime _LEAF_CERT = "src/komira_http_core/tests/fixtures/tls/leaf_cert.pem"
comptime _LEAF_KEY = "src/komira_http_core/tests/fixtures/tls/leaf_key.pem"
comptime _ROOT_CA = "src/komira_http_core/tests/fixtures/tls/root_ca.pem"

comptime _HANDSHAKE_DEADLINE_US: Int64 = 10_000_000
comptime _REQUEST_TIMEOUT_US = 10_000_000
comptime _SERVE_POLL_TIMEOUT_US: Int32 = 5_000


# =============================================================================
# §1 -- TLS material (komira_http_core's fixtures, staged by test_data)
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
# §2 -- one server and one client on two threads
# =============================================================================


trait _ClientLeg(Movable):
    def run(mut self) raises:
        ...


struct _FlightServeLoop(Movable):
    """The server, stepped one bounded poll at a time by thread 0 only."""

    var server: HttpServer[FlightBrokerService]

    def __init__(out self, var server: HttpServer[FlightBrokerService]):
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
    var server: Pointer[_FlightServeLoop, Self.so]
    var client: Pointer[Self.C, Self.co]
    var flag: Pointer[_StopFlag, Self.fo]

    def __init__(
        out self,
        server: Pointer[_FlightServeLoop, Self.so],
        client: Pointer[Self.C, Self.co],
        flag: Pointer[_StopFlag, Self.fo],
    ):
        self.server = server
        self.client = client
        self.flag = flag

    def run(self, tid: Int) raises:
        if tid == 0:
            while self.flag[].stop.load() == Int64(0):
                self.server[].step()
            return
        try:
            self.client[].run()
        finally:
            _ = self.flag[].stop.fetch_add(Int64(1))


def _serve_while[C: _ClientLeg](mut server: _FlightServeLoop, mut client: C) raises:
    """Step `server` on one thread while `client.run()` runs on another. On a
    failure `fork_join` rethrows the lowest tid's error: the server's if its
    step raised, else the client's."""
    var flag = _StopFlag()
    var duet = _Duet(Pointer(to=server), Pointer(to=client), Pointer(to=flag))
    fork_join(duet, 2)
    _ = duet^
    _ = flag^


# =============================================================================
# §3 -- helpers the client leg asserts with
# =============================================================================


def _now_us() -> Int:
    return Int(now_ns() // 1000)


def _schema() -> Schema:
    return Schema(
        names=[String("val")],
        arrow_types=[ArrowType.INT64.type_id],
        dtypes=[DType.int64],
        nullables=[False],
    )


def _batch(base: Int64, n: Int) raises -> RecordBatch:
    var values = List[Int64]()
    for i in range(n):
        values.append(base + Int64(i))
    var arr = PrimitiveArray[DType.int64].from_list(values)
    var col = Column.from_primitive[DType.int64](arr^)
    return RecordBatch.from_typed_columns_1(_schema(), col^)


# =============================================================================
# §4 -- the client leg
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
        self._leg_a_to_c_round_trip(client, reactor, token)
        self._leg_d_partitions(client, reactor, token)
        self._leg_e_refusals(client, reactor, token)

    def _put(
        mut self,
        mut client: GrpcClient[_Tls],
        mut reactor: Reactor[NoopSink],
        ref token: CancellationToken,
        var descriptor: FlightDescriptor,
        base: Int64,
        n_batches: Int,
    ) raises:
        """DoPut: the schema message carrying the descriptor, then batches."""
        var encoder = ClientStreamEncoder[ProtocolGrpcProto].new()
        var first = FlightData.decode(Span(encode_schema_flight_data(_schema())))
        first.flight_descriptor = descriptor^
        first.has_descriptor = True
        encoder.encode_message(Span(first.encode()))
        for b in range(n_batches):
            encoder.encode_message(
                Span(encode_batch_flight_data(_batch(base + Int64(10 * b), 3)))
            )
        encoder.mark_close()
        self.calls += 1  # counted before the call: a refused call is a response too
        _ = client.client_stream[_Rt, ProtocolGrpcProto](
            String(FLIGHT_DO_PUT_PATH), encoder^, CallOptions(), _now_us(), reactor, token
        )

    def _info(
        mut self,
        mut client: GrpcClient[_Tls],
        mut reactor: Reactor[NoopSink],
        ref token: CancellationToken,
        topic: String,
    ) raises -> FlightInfo:
        var req = FlightDescriptor.for_path(topic.copy()).encode()
        var res = client.unary_call[_Rt, ProtocolGrpcProto](
            String(FLIGHT_GET_INFO_PATH), Span(req), CallOptions(), _now_us(), reactor, token
        )
        self.calls += 1
        return FlightInfo.decode(Span(res.message_bytes))

    def _get(
        mut self,
        mut client: GrpcClient[_Tls],
        mut reactor: Reactor[NoopSink],
        ref token: CancellationToken,
        ticket: List[UInt8],
    ) raises -> List[Int64]:
        """DoGet: the schema message first, then one message per batch."""
        var req = Ticket(ticket.copy()).encode()
        self.calls += 1  # counted before the call: a refused call is a response too
        var decoder = client.server_stream[_Rt, ProtocolGrpcProto](
            String(FLIGHT_DO_GET_PATH), Span(req), CallOptions(), _now_us(), reactor, token
        )
        var messages = List[FlightData]()
        while True:
            var outcome = decoder.try_next_message()
            if outcome.kind == STREAM_OUTCOME_MESSAGE:
                messages.append(FlightData.decode(Span(outcome.message_bytes)))
                continue
            assert_true(
                outcome.kind == STREAM_OUTCOME_PENDING
                or outcome.kind == STREAM_OUTCOME_END_OK,
                String("unexpected outcome kind ") + String(Int(outcome.kind)),
            )
            break
        var out = List[Int64]()
        if len(messages) == 0:
            return out^
        assert_equal(len(messages[0].data_body), 0, "the first message is the schema")
        for i in range(1, len(messages)):
            var rb = flight_data_to_record_batch(
                messages[0].data_header.copy(),
                messages[i].data_header.copy(),
                messages[i].data_body.copy(),
            )
            var col = rb.column_as_primitive_int64(0)
            for r in range(rb.num_rows()):
                out.append(col.get(r))
        return out^

    def _leg_a_to_c_round_trip(
        mut self,
        mut client: GrpcClient[_Tls],
        mut reactor: Reactor[NoopSink],
        ref token: CancellationToken,
    ) raises:
        self._put(client, reactor, token, FlightDescriptor.for_path(String("t1")), Int64(10), 2)
        print("  A DoPut of two batches PASS")
        var info = self._info(client, reactor, token, String("t1"))
        assert_equal(info.total_records, Int64(6), "B: total_records")
        assert_true(len(info.schema) > 0, "B: schema present")
        assert_equal(len(info.endpoint), 1, "B: one endpoint")
        print("  B GetFlightInfo PASS")
        var vals = self._get(client, reactor, token, info.endpoint[0].ticket.ticket)
        var want: List[Int64] = [10, 11, 12, 20, 21, 22]
        assert_equal(len(vals), 6, "C: row count")
        for i in range(6):
            assert_equal(vals[i], want[i], "C: value order")
        print("  C DoGet returns the rows in order PASS")

    def _leg_d_partitions(
        mut self,
        mut client: GrpcClient[_Tls],
        mut reactor: Reactor[NoopSink],
        ref token: CancellationToken,
    ) raises:
        var d = FlightDescriptor.for_path(String("orders"))
        d.path.append(String("2"))
        self._put(client, reactor, token, d^, Int64(200), 1)
        var info = self._info(client, reactor, token, String("orders"))
        assert_equal(len(info.endpoint), 3, "D: one endpoint per partition")
        for p in range(3):
            var bt = BrokerTicket.decode(Span(info.endpoint[p].ticket.ticket))
            assert_equal(bt.partition, Int64(p), "D: ticket partition")
        var v1 = self._get(client, reactor, token, info.endpoint[1].ticket.ticket)
        var v2 = self._get(client, reactor, token, info.endpoint[2].ticket.ticket)
        assert_equal(len(v1), 0, "D: partition 1 is empty")
        assert_equal(len(v2), 3, "D: partition 2 rows")
        assert_equal(v2[0], Int64(200), "D: partition 2 first value")
        print("  D partition routing over the wire PASS")

    def _leg_e_refusals(
        mut self,
        mut client: GrpcClient[_Tls],
        mut reactor: Reactor[NoopSink],
        ref token: CancellationToken,
    ) raises:
        var caught = String("")
        try:
            _ = self._get(
                client, reactor, token, BrokerTicket(String("nope"), Int64(0)).encode()
            )
        except e:
            caught = String(e)
        assert_true(caught.byte_length() > 0, "E: DoGet of an unknown topic must raise")
        assert_equal(Int(parse_grpc_error_message(caught)[0]), 5, String("E: NOT_FOUND, raised: ") + caught)

        caught = String("")
        var d = FlightDescriptor.for_path(String("bad"))
        d.path.append(String("abc"))
        try:
            self._put(client, reactor, token, d^, Int64(0), 1)
        except e:
            caught = String(e)
        assert_true(caught.byte_length() > 0, "E: DoPut to partition 'abc' must raise")
        assert_equal(Int(parse_grpc_error_message(caught)[0]), 3, String("E: INVALID_ARGUMENT, raised: ") + caught)
        print("  E refusals reach the client as their gRPC status PASS")


def test_flight_over_live_tls_h2_server() raises:
    var svc = FlightBrokerService(
        FlightBrokerData(String("flight-live")), String("grpc+tls://broker.example:8815")
    )
    var server = HttpServer[FlightBrokerService](
        config=HttpServerConfig.default_ephemeral(),
        router=Router(),
        tls_config=_server_tls_config(),
        grpc=svc^,
    )
    var port = server.local_port()
    var loop = _FlightServeLoop(server^)
    var legs = _AllLegs(port)
    _serve_while(loop, legs)

    # F. One response per RPC sent: no retry, no duplicate, none lost.
    var stats = loop.server.serve_for_iterations(0, Int32(0))
    assert_equal(Int(stats.reqs_handled), legs.calls, "F: responses the server wrote")
    print("  F server wrote one response per RPC PASS")


def main() raises:
    tls_init()
    test_flight_over_live_tls_h2_server()
    print("PASS komira_flight_server test_flight_live_socket")
