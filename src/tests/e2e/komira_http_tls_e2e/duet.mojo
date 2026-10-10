# =============================================================================
# duet.mojo -- a real server and a real client in one process, two threads
# =============================================================================
#
# `HttpClient` blocks its thread until its request completes, and `HttpServer`
# only makes progress when something calls its serve loop, so the two cannot
# share a thread. `serve_while` runs them on two `komira_fork_join` threads:
#
#   thread 0  steps the server (`ServeStep.step`) until the client is done;
#   thread 1  runs the client leg (`ClientLeg.run`) once, then raises the stop
#             flag, whether the leg returned or raised.
#
# Each side is touched by exactly one thread while the duet runs; the only
# state both threads read is the stop flag, an atomic. After the join, the
# caller owns both again and may read what either recorded.
#
# Failure: `fork_join` joins both threads and rethrows the lowest tid's error,
# so a server step that raises is reported ahead of the client failure it
# causes. The client side bounds itself (the connectors' handshake deadline and
# the client's request timeout), so a dead server ends the duet with the
# client's timeout rather than a hang. The server side bounds itself too: it
# stops stepping and raises after `SERVE_DEADLINE_NS` without the stop flag,
# so a client thread that never started (fork_join starts thread 0 first and
# stops at the first failed `pthread_create`) fails the duet instead of
# hanging the join.
# =============================================================================

from std.memory import Pointer

from komira_atomic_alias import AtomicI64
from komira_clock import now_ns
from komira_fork_join import ForkJoinBody, fork_join

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_http_server.dispatch import RequestDispatcher
from komira_http_core.transport.grpc_emit import NoopGrpcDispatch
from komira_http_server.server import HttpServer


# One server poll waits at most this long, so the stop flag is seen within it.
comptime SERVE_POLL_TIMEOUT_US: Int32 = 5_000
# The server gives up if the client has not finished within this long. Well
# above the longest leg (three dials with a 10 s request timeout each).
comptime SERVE_DEADLINE_NS: UInt64 = 120_000_000_000


trait ServeStep(Movable):
    """A server the duet can step: one bounded poll cycle per call."""

    def step(mut self) raises:
        ...


trait ClientLeg(Movable):
    """The client half of a duet: run once, to completion, on its own thread."""

    def run(mut self) raises:
        ...


struct TlsServeLoop(ServeStep):
    """An `HttpServer` built with a `TlsConfig`, stepped by
    `serve_one_iteration`: the TLS accept path, the handshake driver, the
    ALPN pivot to h2, and the h1-over-TLS read round."""

    var server: HttpServer[NoopGrpcDispatch]

    def __init__(out self, var server: HttpServer[NoopGrpcDispatch]):
        self.server = server^

    def step(mut self) raises:
        _ = self.server.serve_one_iteration(SERVE_POLL_TIMEOUT_US)


struct DispatchServeLoop[D: RequestDispatcher](ServeStep):
    """A plaintext `HttpServer` stepped by `serve_one_iteration_dispatch`, so
    each parsed request reaches `dispatcher` and its response is written by
    the server's buffered-write path."""

    var server: HttpServer[NoopGrpcDispatch]
    var dispatcher: Self.D

    def __init__(
        out self,
        var server: HttpServer[NoopGrpcDispatch],
        var dispatcher: Self.D,
    ):
        self.server = server^
        self.dispatcher = dispatcher^

    def step(mut self) raises:
        _ = self.server.serve_one_iteration_dispatch[
            Self.D, BlockingRuntime[NoopSink]
        ](self.dispatcher, SERVE_POLL_TIMEOUT_US)


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
    """The fork-join body. Every field is a borrow with a concrete origin into
    `serve_while`'s frame, which outlives both threads (the join is inside
    it)."""

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
            # Only thread 0 touches the server.
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
        # Only thread 1 touches the client; the flag is raised on every exit.
        try:
            self.client[].run()
        finally:
            _ = self.flag[].stop.fetch_add(Int64(1))


def serve_while[S: ServeStep, C: ClientLeg](mut server: S, mut client: C) raises:
    """Step `server` on one thread while `client.run()` runs on another;
    return when both have finished. Rethrows the server's error if its step
    raised (or it hit `SERVE_DEADLINE_NS`), otherwise the client's."""
    var flag = _StopFlag()
    var duet = _Duet(Pointer(to=server), Pointer(to=client), Pointer(to=flag))
    fork_join(duet, 2)
    _ = duet^
    _ = flag^
