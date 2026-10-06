# =============================================================================
# duet.mojo -- a real HttpServer and a supervisor run in one process, on two
# threads
# =============================================================================
#
# `run_job_supervisor` blocks its thread until the job ends, and `HttpServer`
# only makes progress when something calls its serve loop, so the two cannot
# share a thread. `serve_while` runs them on two `komira_fork_join` threads:
#
#   thread 0  steps the server (`DispatchServeLoop.step`) until the client is
#             done;
#   thread 1  runs the client leg (`ClientLeg.run`) once, then raises the stop
#             flag, whether the leg returned or raised.
#
# Each side is touched by exactly one thread while the duet runs; the only
# state both threads read is the stop flag, an atomic. After the join, the
# caller owns both again and may read what either recorded (the receiver's
# state, the phase the supervisor returned).
#
# Failure: `fork_join` joins both threads and rethrows the lowest tid's error,
# so a server step that raises is reported ahead of the client failure it
# causes. The server side bounds itself: it raises after `SERVE_DEADLINE_NS`
# without the stop flag. Whenever thread 0 stops on an error it first DROPS
# the server (`DispatchServeLoop.close`), closing the listener and every
# accepted connection, so the client's next beat fails at once (connection
# refused, or the connection closed under it) instead of sitting on a socket
# nobody serves until the HTTP client's own timeout. The join still waits for
# the client leg: a red duet ends when the job ends, not before.
# =============================================================================

from std.memory import Pointer

from komira_atomic_alias import AtomicI64
from komira_clock import now_ns
from komira_fork_join import ForkJoinBody, fork_join

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_http_core.transport.grpc_emit import NoopGrpcDispatch
from komira_http_server.dispatch import RequestDispatcher
from komira_http_server.server import HttpServer


# One server poll waits at most this long, so the stop flag is seen within it.
comptime SERVE_POLL_TIMEOUT_US: Int32 = 5_000
# The server gives up if the client has not finished within this long. Well
# above the longest leg (a job the receiver cancels, or one that sleeps 2 s).
comptime SERVE_DEADLINE_NS: UInt64 = 120_000_000_000


trait ClientLeg(Movable):
    """The client half of a duet: run once, to completion, on its own thread."""

    def run(mut self) raises:
        ...


struct DispatchServeLoop[D: RequestDispatcher](Movable):
    """A plaintext `HttpServer` stepped by `serve_one_iteration_dispatch`, so
    each parsed request reaches `dispatcher` and its response is written by
    the server's buffered-write path."""

    var server: Optional[HttpServer[NoopGrpcDispatch]]
    var dispatcher: Self.D

    def __init__(
        out self,
        var server: HttpServer[NoopGrpcDispatch],
        var dispatcher: Self.D,
    ):
        self.server = Optional(server^)
        self.dispatcher = dispatcher^

    def step(mut self) raises:
        if not self.server:
            raise Error("DispatchServeLoop: the server was closed")
        _ = self.server.value().serve_one_iteration_dispatch[
            Self.D, BlockingRuntime[NoopSink]
        ](self.dispatcher, SERVE_POLL_TIMEOUT_US)

    def close(mut self):
        """Drop the server: its listener and connections close. The
        dispatcher stays, so what it recorded can still be read."""
        self.server = None


struct _StopFlag(Movable):
    var stop: AtomicI64

    def __init__(out self):
        self.stop = AtomicI64(Int64(0))


struct _Duet[
    D: RequestDispatcher,
    C: ClientLeg,
    so: MutOrigin,
    co: MutOrigin,
    fo: MutOrigin,
](ForkJoinBody):
    """The fork-join body. Every field is a borrow with a concrete origin into
    `serve_while`'s frame, which outlives both threads (the join is inside
    it)."""

    var server: Pointer[DispatchServeLoop[Self.D], Self.so]
    var client: Pointer[Self.C, Self.co]
    var flag: Pointer[_StopFlag, Self.fo]

    def __init__(
        out self,
        server: Pointer[DispatchServeLoop[Self.D], Self.so],
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
            try:
                while self.flag[].stop.load() == Int64(0):
                    if now_ns() >= give_up:
                        raise Error(
                            "serve_while: the client did not finish within "
                            + String(SERVE_DEADLINE_NS // 1_000_000_000)
                            + " s"
                        )
                    self.server[].step()
            except e:
                # Fail the client fast (module header), then report.
                self.server[].close()
                raise e^
            return
        # Only thread 1 touches the client; the flag is raised on every exit.
        try:
            self.client[].run()
        finally:
            _ = self.flag[].stop.fetch_add(Int64(1))


def serve_while[
    D: RequestDispatcher, C: ClientLeg
](mut server: DispatchServeLoop[D], mut client: C) raises:
    """Step `server` on one thread while `client.run()` runs on another;
    return when both have finished. Rethrows the server's error if its step
    raised (or it hit `SERVE_DEADLINE_NS`), otherwise the client's."""
    var flag = _StopFlag()
    var duet = _Duet(Pointer(to=server), Pointer(to=client), Pointer(to=flag))
    fork_join(duet, 2)
    _ = duet^
    _ = flag^
