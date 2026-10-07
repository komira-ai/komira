# =============================================================================
# duet.mojo -- step a server on one thread while a client leg runs on another
# =============================================================================
#
# `HttpServer` only makes progress when something calls its serve loop, and
# the client side here (h2spec, then a komira_http_client request) blocks its
# thread, so the two run on two `komira_fork_join` threads:
#
#   thread 0  steps the server (`serve_one_iteration`) until the leg is done;
#   thread 1  runs the leg (`ClientLeg.run`) once, then raises the stop flag,
#             whether the leg returned or raised.
#
# The server is stepped by exactly one thread while the duet runs; the only
# state both threads read is the stop flag, an atomic. After the join the
# caller owns both again.
#
# Failure: `fork_join` joins both threads and rethrows the lowest tid's error,
# so a server step that raises is reported ahead of the client failure it
# causes. The server thread gives up after `deadline_s` without the stop flag,
# so a leg that never started cannot hang the join; the leg bounds itself.
# =============================================================================

from std.memory import Pointer

from komira_atomic_alias import AtomicI64
from komira_clock import now_ns
from komira_fork_join import ForkJoinBody, fork_join

from komira_http_core.transport.grpc_emit import NoopGrpcDispatch
from komira_http_server.server import HttpServer


# One server poll waits at most this long, so the stop flag is seen within it.
comptime SERVE_POLL_TIMEOUT_US: Int32 = 5_000


trait ClientLeg(Movable):
    """The client half of a duet: run once, to completion, on its own thread."""

    def run(mut self) raises:
        ...


struct _StopFlag(Movable):
    var stop: AtomicI64

    def __init__(out self):
        self.stop = AtomicI64(Int64(0))


struct _Duet[
    C: ClientLeg,
    so: MutOrigin,
    co: MutOrigin,
    fo: MutOrigin,
](ForkJoinBody):
    """The fork-join body. Every field is a borrow with a concrete origin into
    `serve_while`'s frame, which outlives both threads (the join is inside
    it)."""

    var server: Pointer[HttpServer[NoopGrpcDispatch], Self.so]
    var client: Pointer[Self.C, Self.co]
    var flag: Pointer[_StopFlag, Self.fo]
    var deadline_s: Int

    def __init__(
        out self,
        server: Pointer[HttpServer[NoopGrpcDispatch], Self.so],
        client: Pointer[Self.C, Self.co],
        flag: Pointer[_StopFlag, Self.fo],
        deadline_s: Int,
    ):
        self.server = server
        self.client = client
        self.flag = flag
        self.deadline_s = deadline_s

    def run(self, tid: Int) raises:
        if tid == 0:
            # Only thread 0 touches the server.
            var give_up = now_ns() + UInt64(self.deadline_s) * 1_000_000_000
            while self.flag[].stop.load() == Int64(0):
                if now_ns() >= give_up:
                    raise Error(
                        "serve_while: the client leg did not finish within "
                        + String(self.deadline_s) + " s"
                    )
                _ = self.server[].serve_one_iteration(SERVE_POLL_TIMEOUT_US)
            return
        # Only thread 1 touches the client; the flag is raised on every exit.
        try:
            self.client[].run()
        finally:
            _ = self.flag[].stop.fetch_add(Int64(1))


def serve_while[C: ClientLeg](
    mut server: HttpServer[NoopGrpcDispatch], mut client: C, deadline_s: Int
) raises:
    """Step `server` on one thread while `client.run()` runs on another;
    return when both have finished. Rethrows the server's error if a step
    raised (or it hit `deadline_s`), otherwise the client's."""
    var flag = _StopFlag()
    var duet = _Duet(Pointer(to=server), Pointer(to=client), Pointer(to=flag), deadline_s)
    fork_join(duet, 2)
    _ = duet^
    _ = flag^
