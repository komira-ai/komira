# =============================================================================
# tests/test_serverless_entry.mojo — the ServerlessEntry gate.
# =============================================================================
#
# The focused unit for the MULTICLOUD PHASE 1 per-cloud serving seam
# (serving/serverless_entry.mojo). It proves the load-bearing b2 invariants the
# abstraction rests on, WITHOUT standing up an infinite serve loop:
#
#   * The `trait ServerlessEntry` shape COMPILES on Mojo 1.0.0b2 — a trait with
#     a trait-bounded comptime associated member (`comptime RT: Runtime`) AND a
#     generic method (`serve[R: RequestDispatcher]`). A `GcpServerlessEntry`
#     conformer that binds `RT = GcpCloudRunRuntime[NoopSink]` is constructible.
#   * The Entry binds the Cloud Run runtime as a COMPTIME TYPE (the HttpServer
#     owns the live reactor), so `GcpServerlessEntry.RT.RUNTIME_MODEL` is
#     MODEL_CLOUD_RUN — the Cloud-Run identity survives the seam.
#   * A trivial `RequestDispatcher` is driven through `dispatch[Entry.RT]` (the
#     exact leaf `serve_one_iteration_dispatch` calls per request) bound to the
#     Entry's runtime — proving the `RT`-threading compiles + routes.
#   * The one-iteration serve SEAM (`serve_one_iteration_over[R, RT]`, factored
#     out of the infinite `serve` loop so it is testable) steps a REAL
#     `HttpServer` bound to `RT = GcpCloudRunRuntime` — proving the server's
#     `serve_one_iteration_dispatch[D, RT]` machinery elaborates with the Cloud
#     Run runtime exactly as a serving binary threads it.
#
# ⚠ This hermetic seam-shape unit — no listener client, no flakiness — does
# not drive the full socket round trip (GET /healthz -> 200, POST /echo) of
# `GcpServerlessEntry().serve(...)`, which never returns; that belongs to a
# serving binary's own smoke test.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import Reactor
from komira_async.runtime.gcp_cloud_run_runtime import GcpCloudRunRuntime
from komira_async.runtime.runtime_trait import (
    MODEL_CLOUD_RUN,
    Runtime,
)

from komira_http_core.codec.types import (
    HttpMethod,
    HttpRequest,
    HttpResponse,
)
from komira_http_server.routing.router import Router
from komira_http_server.server import HttpServer, HttpServerConfig
from komira_http_server.dispatch import RequestDispatcher
from komira_http_server.serving.serverless_entry import (
    DEFAULT_SERVE_PORT,
    ServerlessEntry,
    GcpServerlessEntry,
    parse_serve_port,
    serve_one_iteration_over,
)


# =============================================================================
# §1 — a trivial RequestDispatcher: GET /ping -> 200 "pong"; else 404.
# =============================================================================
# A zero-field dispatcher — the SIMPLEST possible RequestDispatcher conformer.
# It proves the Entry seam drives ANY dispatcher (the `serve[R]` generic), not
# just the AppRouter pack. Its distinct body ("pong") falsifies a mis-route.


struct PingDispatcher(Movable, Deinitable, RequestDispatcher):
    """GET /ping -> 200 "pong"; anything else -> 404. The minimal
    RequestDispatcher conformer used to prove the Entry serve seam."""

    def __init__(out self):
        pass

    def dispatch[
        RT: Runtime,
    ](
        mut self, mut reactor: Reactor[RT.Sink], var req: HttpRequest
    ) raises -> HttpResponse:
        _ = reactor
        if req.method == HttpMethod.get() and req.path == String("/ping"):
            _ = req^
            return HttpResponse.ok(String("pong"))
        _ = req^
        return HttpResponse.not_found()


def _cloud_run_rt() raises -> GcpServerlessEntry.RT:
    """Build a live GcpCloudRunRuntime[NoopSink] (the Entry's RT) for the
    direct-dispatch path. The host-appropriate reactor backend is comptime-
    selected by `.new`."""
    return GcpServerlessEntry.RT.new(NoopSink(_placeholder=UInt8(0)))


def _req(var method: HttpMethod, var path: String) -> HttpRequest:
    var r = HttpRequest()
    r.method = method
    r.path = path^
    return r^


def _body_str(ref resp: HttpResponse) -> String:
    var s = String("")
    var i = 0
    var n = len(resp.body)
    while i < n:
        s = s + chr(Int(resp.body[i]))
        i = i + 1
    return s^


# =============================================================================
# 1. GcpServerlessEntry constructs + binds RT = GcpCloudRunRuntime (Cloud-Run
#    identity preserved: Entry.RT.RUNTIME_MODEL == MODEL_CLOUD_RUN).
# =============================================================================
def test_gcp_entry_binds_cloud_run_runtime() raises:
    var entry = GcpServerlessEntry()
    _ = entry^

    # The Entry's associated runtime TYPE is the Cloud Run runtime. Read the
    # comptime members off the TYPE (Self.RT-style access at the call site).
    assert_true(
        GcpServerlessEntry.RT.RUNTIME_MODEL == MODEL_CLOUD_RUN,
        "GcpServerlessEntry.RT is the Cloud Run runtime (MODEL_CLOUD_RUN)",
    )
    assert_true(
        not GcpServerlessEntry.RT.TASKS_ARE_THREAD_PINNED,
        "Cloud Run tasks are not thread-pinned",
    )


# =============================================================================
# 2. A trivial RequestDispatcher is driven through dispatch[Entry.RT] — the
#    exact per-request leaf, bound to the Entry's Cloud Run runtime.
# =============================================================================
# This is the routing falsifier: the request is dispatched through the Entry's
# `RT` (GcpCloudRunRuntime as a comptime TYPE); the live reactor comes from a
# GcpCloudRunRuntime instance (mirroring how the HttpServer owns its reactor).
# If the seam did not thread `RT` correctly, this would fail to compile; if it
# mis-routed, the body would not be "pong".
def test_dispatch_through_entry_runtime() raises:
    var rt = _cloud_run_rt()
    ref reactor = rt.reactor()
    var dispatcher = PingDispatcher()

    var r0 = dispatcher.dispatch[GcpServerlessEntry.RT](
        reactor, _req(HttpMethod.get(), String("/ping"))
    )
    assert_equal(Int(r0.status), 200, "GET /ping -> 200")
    assert_equal(_body_str(r0), String("pong"), "GET /ping body is 'pong'")

    var r1 = dispatcher.dispatch[GcpServerlessEntry.RT](
        reactor, _req(HttpMethod.get(), String("/nope"))
    )
    assert_equal(Int(r1.status), 404, "unknown path -> 404")

    _ = dispatcher^
    _ = rt^


# =============================================================================
# 3. The one-iteration serve SEAM steps a REAL HttpServer bound to
#    RT = GcpCloudRunRuntime — proving serve_one_iteration_dispatch[D, RT]
#    elaborates with the Cloud Run runtime (the exact machinery a serving
#    binary's serve loop drives).
# =============================================================================
def test_serve_seam_steps_server_with_cloud_run_rt() raises:
    var cfg = HttpServerConfig.with_port(UInt16(0))  # ephemeral loopback port
    var server = HttpServer(config=cfg, router=Router())
    var port = server.local_port()
    assert_true(Int(port) > 0, "server bound an ephemeral port")

    var dispatcher = PingDispatcher()

    # Step the Entry's one-iteration seam a few cycles with NO client connected
    # — it drives one poll cycle per call (0 events, no busy-spin) and proves
    # `serve_one_iteration_over[PingDispatcher, GcpServerlessEntry.RT]`
    # elaborates against a live server bound to the Cloud Run runtime.
    var i = 0
    while i < 3:
        var n = serve_one_iteration_over[
            PingDispatcher, GcpServerlessEntry.RT
        ](server, dispatcher, Int32(1_000))
        assert_equal(n, 0, "no client connected -> zero events this cycle")
        i = i + 1

    _ = dispatcher^
    _ = server^


# =============================================================================
# 4. Trait-generality: the `ServerlessEntry` trait binds any conformer by TYPE.
#    A generic helper reads `E.RT` off an arbitrary ServerlessEntry — proving
#    the trait's comptime associated member is usable at a generic call site.
# =============================================================================
def _entry_runtime_model[E: ServerlessEntry]() -> UInt8:
    return E.RT.RUNTIME_MODEL


def test_trait_generic_reads_associated_runtime() raises:
    assert_true(
        _entry_runtime_model[GcpServerlessEntry]() == MODEL_CLOUD_RUN,
        "generic [E: ServerlessEntry] reads E.RT.RUNTIME_MODEL",
    )


def test_listen_port_comes_from_the_caller() raises:
    """The port is the deployer's value, parsed by the binary and handed to the
    entry: empty or unparseable -> 8080, `0` -> ephemeral, an out-of-range
    value -> 8080, anything else verbatim."""
    assert_equal(Int(parse_serve_port(String(""))), Int(DEFAULT_SERVE_PORT))
    assert_equal(Int(parse_serve_port(String("9090"))), 9090)
    assert_equal(Int(parse_serve_port(String("0"))), 0)
    assert_equal(Int(parse_serve_port(String("65536"))), 8080)
    assert_equal(Int(parse_serve_port(String("-1"))), 8080)
    assert_equal(Int(parse_serve_port(String("http"))), 8080)
    assert_equal(Int(GcpServerlessEntry().port), 8080)
    assert_equal(Int(GcpServerlessEntry(UInt16(9090)).port), 9090)


def main() raises:
    test_listen_port_comes_from_the_caller()
    test_gcp_entry_binds_cloud_run_runtime()
    test_dispatch_through_entry_runtime()
    test_serve_seam_steps_server_with_cloud_run_rt()
    test_trait_generic_reads_associated_runtime()
    print("PASS test_serverless_entry")
