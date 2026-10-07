# =============================================================================
# test_gcs_grpc_trust.mojo — which server certificates a StorageGrpcBackend
#   accepts: the default trusts public roots only; the caller's TlsConfig
#   reaches a private one.
# =============================================================================
#
# A real `HttpServer[ConnectService]` on 127.0.0.1:0 holds komira_http_core's
# fixture leaf (signed by the fixture root `root_ca.pem`, naming `localhost`
# and `127.0.0.1`; ALPN `h2`, `http/1.1`) and answers
# `/google.storage.v2.Storage/GetObject` with an Object built from the request
# it decoded. On the other thread a real `StorageGrpcBackend` dials it,
# `https://127.0.0.1:<port>`, SNI `localhost`.
#
#   1. test_default_connector_refuses_a_private_root: over
#      `build_gcs_tls_connector("localhost")`, the default, GetObject raises
#      `StoreError[TRANSPORT] ... detail=TlsConnector.connect`: the TLS
#      handshake failed, so the chain was refused (no public root signs the
#      fixture leaf). Nothing reached the handler (its counter stays 0).
#   2. test_trusting_connector_accepts_its_root: over
#      `build_gcs_tls_connector_with_config(gcs_tls_config_trusting_only(
#      root_ca.pem), "localhost")`, the handshake completes, ALPN selects h2,
#      and one unary GetObject round-trips: the handler saw the bucket's
#      resource name and the key, and the backend maps the handler's Object
#      (generation 7, size 3, etag) onto ObjectMetaRaw. The handler ran once.
#
# The two tests run the same server set-up and differ only in the client's
# connector, so test 2 is the control that the set-up can succeed: test 1
# fails for its trust, not for the harness. The detail class in test 1 says
# the TCP connection was made and the TLS handshake is what failed (or timed
# out: the deadline error carries the same class); the backend drops s2n's
# text, so "verification" as the cause rests on test 2, where the same server
# with the root trusted completes the handshake.
#
# WHAT IS NOT PROVEN HERE: a server stream (ReadObject) or a client stream
# (WriteObject) over this connection; test_gcs_grpc_backend covers both verbs'
# wire over a scripted connector. Which text s2n gives for the refusal (the
# backend keeps only the error's class).
#
# MUTANTS (product code, each alone, reverted):
#   * build_gcs_tls_connector disables verification: test 1 reds ("the
#     default connector must refuse a certificate no public root signs").
#   * build_gcs_tls_connector_with_config drops its config and returns the
#     public-CA connector: test 2 reds on the handshake.
#
# THE THREADS: the backend blocks its thread for a call and the server only
# progresses when stepped, so the server is stepped on thread 0 of a
# komira_fork_join pair until thread 1 (the client) sets a stop flag in a
# `finally` (the duet pattern of komira_grpc test_e2e_live_socket, copied).
#
# HERMETIC: in-process server, loopback socket, throwaway certificates staged
# by `test_data`, a static token. No network beyond 127.0.0.1.
# =============================================================================

from std.memory import Pointer
from std.pathlib import Path
from std.testing import assert_equal, assert_true

from komira_atomic_alias import AtomicI64
from komira_clock import now_ns
from komira_fork_join import ForkJoinBody, fork_join

from komira_connect import ConnectService
from komira_gcp_core import StaticTokenSource
from komira_gcp_storage.storage import GetObjectRequest, Object
from komira_http_client.client import HttpClientConfig
from komira_http_core.tls import TlsConfig, tls_init
from komira_http_server.routing import Router
from komira_http_server.server import HttpServer, HttpServerConfig
from komira_proto_codec.proto_binary import PbDecoder, PbEncoder
from komira_retry import SystemClock

from komira_objectstore_gcs import (
    GcsTlsConnector,
    StorageGrpcBackend,
    build_gcs_tls_connector,
    build_gcs_tls_connector_with_config,
    gcs_tls_config_trusting_only,
)

comptime _Backend = StorageGrpcBackend[GcsTlsConnector, StaticTokenSource, SystemClock]

comptime _GET_OBJECT = "/google.storage.v2.Storage/GetObject"
comptime _BUCKET = "trust-probe"
comptime _KEY = "logs/a.parquet"

comptime _LEAF_CERT = "src/komira_http_core/tests/fixtures/tls/leaf_cert.pem"
comptime _LEAF_KEY = "src/komira_http_core/tests/fixtures/tls/leaf_key.pem"
comptime _ROOT_CA = "src/komira_http_core/tests/fixtures/tls/root_ca.pem"

comptime _SERVER_NAME = "localhost"
comptime _HANDSHAKE_DEADLINE_US: Int64 = 10_000_000
comptime _REQUEST_TIMEOUT_US = 10_000_000
comptime _SERVE_POLL_TIMEOUT_US: Int32 = 5_000
comptime _SERVE_DEADLINE_NS: UInt64 = 120_000_000_000


# =============================================================================
# §1 — the stub GetObject handler
# =============================================================================


def _get_object_handler(codec_id: UInt8, req_body: List[UInt8]) raises -> List[UInt8]:
    """Decodes the GetObjectRequest and answers an Object naming what was
    asked for: name = the request's object, generation 7, size 3, and etag
    `CAE=` when the request named the bucket as `projects/_/buckets/<bucket>`
    (else `bucket?<what it named>`, which the test refuses)."""
    var dec = PbDecoder(req_body.copy())
    var req = GetObjectRequest.decode(dec)
    var empty = PbDecoder(List[UInt8]())
    var obj = Object.decode(empty)
    obj.name = req.object
    obj.bucket = req.bucket
    obj.generation = Int64(7)
    obj.size = Int64(3)
    if req.bucket == String("projects/_/buckets/") + _BUCKET:
        obj.etag = String("CAE=")
    else:
        obj.etag = String("bucket?") + req.bucket
    var enc = PbEncoder()
    obj.encode(enc)
    return enc.into_buf()


def _service() -> ConnectService:
    var svc = ConnectService(String("google.storage.v2.Storage"))
    svc.register_method(String(_GET_OBJECT), _get_object_handler)
    return svc^


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


def _server() raises -> HttpServer[ConnectService]:
    return HttpServer[ConnectService](
        config=HttpServerConfig.default_ephemeral(),
        router=Router(),
        tls_config=_server_tls_config(),
        grpc=_service(),
    )


def _backend(var connector: GcsTlsConnector, port: UInt16) raises -> _Backend:
    connector.set_handshake_deadline_us(_HANDSHAKE_DEADLINE_US)
    var cfg = HttpClientConfig.defaults()
    cfg.request_timeout_us = _REQUEST_TIMEOUT_US
    return _Backend(
        connector^,
        StaticTokenSource(String("probe-token")),
        SystemClock(),
        cfg,
        host=String("127.0.0.1"),
        port=port,
    )


# =============================================================================
# §2 — one server and one client on two threads (the duet pattern, copied)
# =============================================================================


trait _ClientLeg(Movable):
    def run(mut self) raises:
        ...


struct _ServeLoop(Movable):
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


struct _Duet[C: _ClientLeg, so: MutOrigin, co: MutOrigin, fo: MutOrigin](ForkJoinBody):
    """The two-thread body of `_serve_while`."""

    # SAFETY: the three fields borrow `_serve_while`'s locals with concrete
    # origins; that frame outlives both threads because `fork_join` joins
    # inside it. `run` mutates through an immutably borrowed `self`, which is
    # sound because tid 0 alone dereferences `server`, tid 1 alone
    # dereferences `client`, and `flag` is only touched through its AtomicI64.
    var server: Pointer[_ServeLoop, Self.so]
    var client: Pointer[Self.C, Self.co]
    var flag: Pointer[_StopFlag, Self.fo]

    def __init__(
        out self,
        server: Pointer[_ServeLoop, Self.so],
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


def _serve_while[C: _ClientLeg](mut server: _ServeLoop, mut client: C) raises:
    """Step `server` on one thread while `client.run()` runs on another. On a
    failure `fork_join` rethrows the lowest tid's error: the server's if its
    step raised, else the client's."""
    var flag = _StopFlag()
    var duet = _Duet(Pointer(to=server), Pointer(to=client), Pointer(to=flag))
    fork_join(duet, 2)
    _ = duet^
    _ = flag^


# =============================================================================
# §3 — the client legs
# =============================================================================


struct _DefaultRefuses(_ClientLeg):
    var port: UInt16
    var raised: String
    var answered: Bool

    def __init__(out self, port: UInt16):
        self.port = port
        self.raised = String("")
        self.answered = False

    def run(mut self) raises:
        var backend = _backend(build_gcs_tls_connector(String(_SERVER_NAME)), self.port)
        try:
            _ = backend.get_object(String(_BUCKET), String(_KEY))
            self.answered = True
        except e:
            self.raised = String(e)


struct _TrustingAccepts(_ClientLeg):
    var port: UInt16
    var key: String
    var size: Int64
    var generation: Int64
    var etag: String

    def __init__(out self, port: UInt16):
        self.port = port
        self.key = String("")
        self.size = Int64(-1)
        self.generation = Int64(-1)
        self.etag = String("")

    def run(mut self) raises:
        var config = gcs_tls_config_trusting_only(_read_fixture(_ROOT_CA))
        var connector = build_gcs_tls_connector_with_config(config^, String(_SERVER_NAME))
        var backend = _backend(connector^, self.port)
        var meta = backend.get_object(String(_BUCKET), String(_KEY))
        self.key = meta.key
        self.size = meta.size
        self.generation = meta.generation
        self.etag = meta.etag


# =============================================================================
# §4 — the tests
# =============================================================================


def test_default_connector_refuses_a_private_root() raises:
    var loop = _ServeLoop(_server())
    var leg = _DefaultRefuses(loop.server.local_port())
    _serve_while(loop, leg)
    var stats = loop.server.serve_for_iterations(0, Int32(0))
    print("  default connector raised: " + leg.raised)
    assert_true(
        not leg.answered,
        "the default connector must refuse a certificate no public root signs",
    )
    assert_true(
        leg.raised.startswith(String("StoreError[TRANSPORT] GetObject gs://") + _BUCKET + "/" + _KEY),
        String("the refusal is a TRANSPORT StoreError, raised: ") + leg.raised,
    )
    assert_true(
        String(" detail=TlsConnector.connect, ") in leg.raised,
        String("the refusal is the TLS handshake's, raised: ") + leg.raised,
    )
    assert_equal(Int(stats.reqs_handled), 0, "no RPC may reach the handler")
    print("  default connector refuses the private root PASS")


def test_trusting_connector_accepts_its_root() raises:
    var loop = _ServeLoop(_server())
    var leg = _TrustingAccepts(loop.server.local_port())
    _serve_while(loop, leg)
    var stats = loop.server.serve_for_iterations(0, Int32(0))
    assert_equal(leg.key, String(_KEY), "Object.name: the handler saw the key")
    assert_equal(leg.generation, Int64(7), "Object.generation")
    assert_equal(leg.size, Int64(3), "Object.size")
    assert_equal(leg.etag, String("CAE="), "Object.etag: the handler saw the bucket")
    assert_equal(Int(stats.reqs_handled), 1, "one RPC reached the handler")
    print("  trusting connector: handshake + GetObject round trip PASS")


def main() raises:
    tls_init()
    test_default_connector_refuses_a_private_root()
    test_trusting_connector_accepts_its_root()
    print("PASS komira_objectstore_gcs test_gcs_grpc_trust")
