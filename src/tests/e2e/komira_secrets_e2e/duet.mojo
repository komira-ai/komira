# =============================================================================
# duet.mojo -- the fake on a real server, a real client, one process
# =============================================================================
#
# The generated client blocks its thread until its call completes, and
# `HttpServer` only makes progress when something steps it, so the two run
# on two `komira_fork_join` threads (the shape of komira_http_tls_e2e's
# duet). The server side is any `ServeStep`: `FakeServer` here, a plaintext
# server whose requests reach `FakeSecretsManager`, or `GcpFakeServer`
# (gcp_server.mojo), the GCP fake behind its TLS front.
#
#   thread 0  steps the server (`ServeStep.step`) until the client is done,
#             so every parsed request reaches the fake;
#   thread 1  runs the client leg once, then raises the stop flag, whether
#             the leg returned or raised.
#
# Each side is touched by one thread while the duet runs; the only state both
# read is the stop flag, an atomic. After the join the caller owns both and
# reads what each recorded. `fork_join` rethrows the lowest tid's error, so a
# server step that raised is reported ahead of the client failure it caused.
# The server gives up after `SERVE_DEADLINE_NS` (120 s) without the stop
# flag, so a client thread that never started fails the duet instead of
# hanging it. The client bounds itself: each attempt times out after
# `LOOPBACK_REQUEST_TIMEOUT_US` (client.mojo), so one call that gets no
# answer (the server stopped stepping; its listener still accepts) raises
# within about 93 s, and `fork_join` then reports the server's error. A leg
# of several such calls can take longer; the happy path takes seconds.
#
# The listener binds 127.0.0.1 on an ephemeral port (`FakeServer.port()`).
# =============================================================================

from std.memory import Pointer

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_atomic_alias import AtomicI64
from komira_clock import now_ns
from komira_fork_join import ForkJoinBody, fork_join
from komira_http_core.codec import HttpMethod
from komira_http_core.transport.grpc_emit import NoopGrpcDispatch
from komira_http_server.routing import Router
from komira_http_server.server import HttpServer, HttpServerConfig

from .fake_service import FakeSecretsManager

# One server poll waits at most this long, so the stop flag is seen within it.
comptime SERVE_POLL_TIMEOUT_US: Int32 = 5_000
# Well above the longest leg (a dozen calls, one retried after a backoff of
# at most a second).
comptime SERVE_DEADLINE_NS: UInt64 = 120_000_000_000


trait ServeStep(Movable):
    """A server the duet can step: one bounded poll cycle per call."""

    def step(mut self) raises:
        ...


trait ClientLeg(Movable):
    """The client half of a duet: run once, to completion, on its own
    thread."""

    def run(mut self) raises:
        ...


struct FakeServer(ServeStep):
    """A plaintext `HttpServer` on 127.0.0.1 whose every request is answered
    by `fake`."""

    var server: HttpServer[NoopGrpcDispatch]
    var fake: FakeSecretsManager

    def __init__(out self, var fake: FakeSecretsManager) raises:
        var router = Router()
        router.add(HttpMethod.post(), "/", 0)
        self.server = HttpServer(
            config=HttpServerConfig.default_ephemeral(), router=router^
        )
        self.fake = fake^

    def port(self) raises -> UInt16:
        return self.server.local_port()

    def step(mut self) raises:
        _ = self.server.serve_one_iteration_dispatch[
            FakeSecretsManager, BlockingRuntime[NoopSink]
        ](self.fake, SERVE_POLL_TIMEOUT_US)


struct _StopFlag(Movable):
    var stop: AtomicI64

    def __init__(out self):
        self.stop = AtomicI64(Int64(0))


struct _Duet[
    S: ServeStep,
    C: ClientLeg,
    so: MutOrigin,
    co: MutOrigin,
    fo: MutOrigin,
](ForkJoinBody):
    """The fork-join body. Every field borrows, with a concrete origin, from
    `serve_while`'s frame, which outlives both threads (the join is inside
    it)."""

    # SAFETY: each pointer is built in `serve_while` from a local or a
    # `mut` argument of that frame (concrete origins, no wildcard), and the
    # `fork_join` that runs both threads returns inside that frame, so every
    # pointee outlives every dereference. Thread 0 alone dereferences
    # `server`, thread 1 alone `client`; `flag` is read and written only
    # through its atomic (`load`, `fetch_add`), from both threads.
    var server: Pointer[Self.S, Self.so]
    var client: Pointer[Self.C, Self.co]
    var flag: Pointer[_StopFlag, Self.fo]

    def __init__(
        out self,
        server: Pointer[Self.S, Self.so],
        client: Pointer[Self.C, Self.co],
        flag: Pointer[_StopFlag, Self.fo],
    ):
        self.server = server
        self.client = client
        self.flag = flag

    def run(self, tid: Int) raises:
        if tid == 0:
            var give_up = now_ns() + SERVE_DEADLINE_NS
            while self.flag[].stop.load() == Int64(0):
                if now_ns() >= give_up:
                    raise Error(
                        "serve_while: the client did not finish within "
                        + String(SERVE_DEADLINE_NS // 1_000_000_000)
                        + " s"
                    )
                self.server[].step()
            return
        try:
            self.client[].run()
        finally:
            _ = self.flag[].stop.fetch_add(Int64(1))


def serve_while[
    S: ServeStep, C: ClientLeg
](mut server: S, mut client: C) raises:
    """Step `server` on one thread while `client.run()` runs on another;
    return when both have finished. Rethrows the server's error if its step
    raised, otherwise the client's."""
    var flag = _StopFlag()
    # SAFETY: `server`, `client` and `flag` live in this frame past the join
    # below (and `duet^`/`flag^` keep the last two alive to that point);
    # see `_Duet` for which thread dereferences which.
    var duet = _Duet(Pointer(to=server), Pointer(to=client), Pointer(to=flag))
    fork_join(duet, 2)
    _ = duet^
    _ = flag^
