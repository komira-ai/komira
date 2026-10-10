# =============================================================================
# duet.mojo -- the fake Blob service and the Azure client in one process
# =============================================================================
#
# `AzureFs` blocks its thread until each request completes, and `HttpServer`
# only makes progress when something steps its serve loop, so the two cannot
# share a thread. `serve_while` runs them on two `komira_fork_join` threads:
#
#   thread 0  steps the server (`serve_one_iteration_dispatch`) until the
#             client is done;
#   thread 1  runs the client leg (`ClientLeg.run`) once, then raises the stop
#             flag, whether the leg returned or raised.
#
# Each side is touched by exactly one thread while the duet runs; the only
# state both threads read is the stop flag, an atomic. After the join the
# caller owns both again and reads what either recorded (the fake service's
# request log, the leg's results).
#
# The same shape as komira_http_tls_e2e's runner, restricted to the plaintext
# dispatch loop; an end-to-end package depends on no other one, so it is not
# imported from there.
#
# Failure, and what bounds a hang. `fork_join` joins both threads and
# rethrows the lowest tid's error, so a server failure is reported ahead of
# the client failure it causes -- but only once the client thread has
# returned. AzureClient builds its HttpClient with `with_defaults` (600 s per
# request, and AzureConfig carries no shorter timeout), so a client left
# waiting on a server that stopped answering would hold the join for up to
# 600 s per remaining request. To keep that from happening, thread 0 SHUTS
# THE SERVER DOWN whenever it stops stepping without the stop flag: a step
# that raised, or `SERVE_DEADLINE_NS` (120 s) passed. Dropping the
# `HttpServer` closes its listener and every accepted connection, so the
# client's read in flight sees EOF and each later connect is refused at
# once; the leg fails within milliseconds and the join returns the server's
# error. What this does not bound: a client stuck in its own code (not on
# the socket) after the deadline; nothing in-process can stop that thread,
# and the build action's timeout is the backstop.
# =============================================================================

from std.memory import Pointer

from komira_atomic_alias import AtomicI64
from komira_clock import now_ns
from komira_fork_join import ForkJoinBody, fork_join

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_http_core.transport.grpc_emit import NoopGrpcDispatch
from komira_http_server.server import HttpServer, HttpServerConfig
from komira_http_server.routing import Router

from .fake_blob_service import FakeBlobService


# One server poll waits at most this long, so the stop flag is seen within it.
comptime SERVE_POLL_TIMEOUT_US: Int32 = 5_000
# The server gives up if the client has not finished within this long.
comptime SERVE_DEADLINE_NS: UInt64 = 120_000_000_000


trait ClientLeg(Movable):
    """The client half of a duet: run once, to completion, on its own thread."""

    def run(mut self) raises:
        ...


struct BlobServeLoop(Movable):
    """A plaintext `HttpServer` on 127.0.0.1:0 whose parsed requests reach a
    `FakeBlobService`. `shut_down` drops the server (listener and
    connections closed); the service and its log stay readable."""

    var server: Optional[HttpServer[NoopGrpcDispatch]]
    var service: FakeBlobService
    var _port: UInt16

    def __init__(out self, var service: FakeBlobService) raises:
        var server = HttpServer(
            config=HttpServerConfig.default_ephemeral(), router=Router()
        )
        self._port = server.local_port()
        self.server = Optional[HttpServer[NoopGrpcDispatch]](server^)
        self.service = service^

    def port(self) -> UInt16:
        return self._port

    def step(mut self) raises:
        if not self.server:
            raise Error("BlobServeLoop: stepped after shut_down")
        _ = self.server.value().serve_one_iteration_dispatch[
            FakeBlobService, BlockingRuntime[NoopSink]
        ](self.service, SERVE_POLL_TIMEOUT_US)

    def shut_down(mut self):
        """Close the listener and every accepted connection now, so a client
        waiting on this server fails at once instead of at its timeout."""
        if self.server:
            _ = self.server.take()


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

    var server: Pointer[BlobServeLoop, Self.so]
    var client: Pointer[Self.C, Self.co]
    var flag: Pointer[_StopFlag, Self.fo]

    def __init__(
        out self,
        server: Pointer[BlobServeLoop, Self.so],
        client: Pointer[Self.C, Self.co],
        flag: Pointer[_StopFlag, Self.fo],
    ):
        self.server = server
        self.client = client
        self.flag = flag

    def run(self, tid: Int) raises:
        if tid == 0:
            # Only thread 0 touches the server. Any exit other than the stop
            # flag shuts it down first, so the client cannot wait it out.
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
                self.server[].shut_down()
                raise e^
            return
        # Only thread 1 touches the client; the flag is raised on every exit.
        try:
            self.client[].run()
        finally:
            _ = self.flag[].stop.fetch_add(Int64(1))


def serve_while[C: ClientLeg](mut server: BlobServeLoop, mut client: C) raises:
    """Step `server` on one thread while `client.run()` runs on another;
    return when both have finished. Rethrows the server's error if its step
    raised (or it hit `SERVE_DEADLINE_NS`), otherwise the client's."""
    var flag = _StopFlag()
    # SAFETY: the three pointers borrow `server`, `client` and `flag`, which
    # live in this frame until after `fork_join` has joined both threads; the
    # server is touched only by thread 0, the client only by thread 1, and the
    # flag only through its atomic.
    var duet = _Duet(Pointer(to=server), Pointer(to=client), Pointer(to=flag))
    fork_join(duet, 2)
    _ = duet^
    _ = flag^
