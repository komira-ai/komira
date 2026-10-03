# =============================================================================
# src/kci_publish/workers.mojo -- what one more upload worker needs of the
#   run's seams: its own transport to the same channel, its own sleeper.
# =============================================================================
#
# Contract step 2 uploads the missing members IN PARALLEL, bounded by
# `--concurrency`. Each worker owns its own `RegistrySet` (a transport and a
# copy of the credential resolved once), so nothing a request mutates is
# shared between threads. The two traits below are how `run_publish` makes
# that per-worker state from the run's own, without knowing the concrete
# types:
#
#   `ChannelTransport.for_worker` -- a transport that talks to the SAME
#     channel. `HttpChannelTransport` makes a fresh `HttpPkgTransport` with the
#     same connector factory (every exchange dials its own connection and
#     builds its own blocking runtime, so two of them share nothing);
#     `ScriptedChannel` hands out another handle of its shared in-memory
#     server.
#   `WorkerSleeper.for_worker` -- a sleeper for the worker's backoff and
#     settle polls.
#
# The worker threads are `komira_fork_join`'s: exactly `n` real threads, all
# joined before `fork_join` returns (`upload.mojo`, `upload_members`).
#
# Encapsulation: owned values; the connector factory is an FFI-POD fn-ptr
# field (a code pointer, no heap). No raw pointer, no wildcard origin.
# =============================================================================

from komira_http_core.transport.io_stream import Connector
from komira_retry import Sleeper

from kci_pkg_upload import HttpPkgTransport, PkgRequest, PkgResponse, PkgTransport


comptime MIN_CONCURRENCY: Int = 1
comptime MAX_CONCURRENCY: Int = 16
comptime DEFAULT_CONCURRENCY: Int = 4


trait ChannelTransport(PkgTransport):
    """A channel transport that can make one more, for another worker."""

    def for_worker(mut self) raises -> Self:
        """A transport to the SAME channel that shares no mutable state with
        this one (or only state it serialises itself)."""
        ...


trait WorkerSleeper(Sleeper):
    """A sleeper that can make one more, for another worker."""

    def for_worker(self) -> Self:
        ...


struct HttpChannelTransport[C: Connector](ChannelTransport, Movable):
    """`HttpPkgTransport` plus the factory to make another one.

    Layout: the connector factory (an FFI-POD fn-ptr field, a code pointer,
    no heap) and the transport by value. No other pointer field."""

    var _mk_connector: def (String) thin -> Self.C
    var _inner: HttpPkgTransport[Self.C]

    def __init__(out self, mk_connector: def (String) thin -> Self.C):
        self._mk_connector = mk_connector
        self._inner = HttpPkgTransport[Self.C](mk_connector)

    def for_worker(mut self) raises -> Self:
        return Self(self._mk_connector)

    def exchange(mut self, req: PkgRequest) raises -> PkgResponse:
        return self._inner.exchange(req)
