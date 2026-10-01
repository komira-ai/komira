# =============================================================================
# komira_async.runtime.gcp_cloud_run_runtime — GcpCloudRunRuntime[S]
# =============================================================================
#
#
# A `Runtime` conformer (NOT a config of PerCoreAsyncRuntime) that configures
# the serving stack for Google Cloud Run.
# Cloud Run request concurrency is 1 and the service scales by INSTANCES, not
# by cores — so the serving runtime needs exactly ONE reactor driven INLINE on
# the serve thread, NOT a per-core worker-pthread pool.
#
# A single INLINE reactor
# ----------------------------------------------------------------------------
# Under instance-based serving with concurrency=1 the instance handles one
# request at a time, so N worker pthreads + N reactors would be wasted
# topology. This conformer mirrors BlockingRuntime's INTERNALS — it owns
# exactly ONE `Reactor[S]` and drives it INLINE on the CURRENT (serve) thread,
# spawning NO pthreads. `poll_completions(0, timeout_us)` drives the single
# reactor. It is the tokio `current_thread` reactor, BUT it keeps its
# Cloud-Run identity at the trait seam (see below), so request-flush gating
# that reads `RT.RUNTIME_MODEL == MODEL_CLOUD_RUN` still fires.
#
# WHAT IT KEEPS (the Cloud-Run identity; LOAD-BEARING)
# ----------------------------------------------------------------------------
#   * `RUNTIME_MODEL = MODEL_CLOUD_RUN` — request-driven CPU availability
#     (throttled between requests under default billing), NOT
#     current-thread-blocking. This MUST stay MODEL_CLOUD_RUN (NOT
#     MODEL_CURRENT_THREAD_BLOCKING): a serving binary's per-request
#     flush-before-freeze is GATED
#     on this comptime sentinel. Flipping it to BlockingRuntime's model would
#     silently disable the per-request log flush and strand buffered records on
#     a freeze/scale-to-zero.
#   * `TASKS_ARE_THREAD_PINNED = False` — a task may resume on any worker
#     (Cloud Run does not promise a task stays on the core it started on). This
#     is the OTHER distinction from BlockingRuntime (which pins True): the
#     single inline reactor is not a per-core-pinned task.
#   * `worker_count() = 1` — one inline reactor driven on the serve thread.
#
# WHAT IT DOES NOT HAVE
# ----------------------------------------------------------------------------
#   * A worker set, worker-set lifecycle (`attach_*` / `start` /
#     `shutdown`), or pthread launch/join — the reactor is constructed in the
#     ctor and driven inline. The RAII `__del__` is the default field-drop
#     (the Reactor's own `__del__` closes its multiplexer fd).
#   * cgroup-derived worker-count sizing: `worker_count()` is 1.
#
# SIGTERM drain
# ----------------------------------------------------------------------------
# `signal_shutdown_all()` is TRIVIAL — there are no worker pthreads to
# drain. The REAL serving shutdown is the binary's SIGTERM handler +
# `final_flush`: the serve loop
# polls the async-signal-safe shutdown flag, breaks, runs the final log flush,
# and exits cleanly within the Cloud Run 10s grace. That logic is the binary's;
# this method is present only so the trait surface is uniform across conformers.
#
# Pointer discipline
# ----------------------------------------------------------------------------
#   * Public API: ZERO `UnsafePointer`, ZERO wildcard origins on any signature.
#   * Internal: a single `Reactor[S]` owned BY VALUE — no Slab, no OwnedPointer
#     worker set, no `unsafe_from_address=Int`, no `take_pointee`, no
#     ArcPointer. safe across destroy-recreate: the only field is a Movable `Reactor[S]` (its own
#     heap-owning inner fields live behind its value, tracked normally); it is
#     not stored in a byte-slab.
#   * The reactor accessor returns `ref [self._reactor] Reactor[Self.S]` — the
#     narrow concrete-field origin form, the
#     SAME shape BlockingRuntime.reactor() / IoSubsystem.reactor() use. NOT
#     `ref [self]` (the compiler rejects that with "incompatible origin").
# =============================================================================

from std.sys.info import CompilationTarget

from komira_async.ops.waker_sink import WakerSink
from komira_async.reactor.reactor import (
    BACKEND_EPOLL,
    BACKEND_KQUEUE,
    Reactor,
)
from komira_async.runtime.runtime_trait import (
    MODEL_CLOUD_RUN,
    Runtime,
)


# =============================================================================
# GcpCloudRunRuntime[S] — the Cloud Run `Runtime` conformer (single inline reactor).
# =============================================================================
struct GcpCloudRunRuntime[
    S: WakerSink & Movable & Deinitable,
](Runtime, Movable, Deinitable):
    """A `Runtime` conformer configured for Google Cloud Run.

    Owns exactly ONE `Reactor[S]` and drives it INLINE on the CALLING (serve)
    thread. No pthreads are launched; no worker pool is sized; no scheduler
    runs. Cloud Run request concurrency is 1 (the service scales by INSTANCES),
    so a single inline reactor IS the correct serving topology. This mirrors
    BlockingRuntime's internals while keeping the Cloud-Run identity at the
    trait seam.

    The HTTP server is `[RT: Runtime]`-GENERIC and stores NO runtime field, so
    this conformer is a drop-in at the server `[RT]` seam: a serving binary binds it
    as the comptime `_ServeRt` (a build-time TYPE) and threads it into
    `serve_one_iteration_dispatch[D, RT]` for handler async-DB I/O. In that
    binary the runtime is used as a COMPTIME TYPE only — the module's own
    `HttpServer` owns the live reactor — so the collapse changes ZERO serve
    behavior.

    Runtime trait conformance — comptime associated members:
      * `Sink = S`                        — the waker-sink the reactor uses.
      * `RUNTIME_MODEL = MODEL_CLOUD_RUN` — request-driven CPU (LOAD-BEARING:
        a serving binary's per-request flush-before-freeze gates on this comptime
        sentinel; must NOT be MODEL_CURRENT_THREAD_BLOCKING).
      * `TASKS_ARE_THREAD_PINNED = False` — a task may resume on any worker
        (the distinction from BlockingRuntime, which pins True).

    Field set:
      var _reactor: Reactor[Self.S]   — the one reactor, current-thread.

    Construction:
      var rt = GcpCloudRunRuntime[NoopSink].new(NoopSink(...))  # comptime backend
      var rt = GcpCloudRunRuntime[NoopSink](sink, backend)      # explicit backend

    `.new(sink)` comptime-selects BACKEND_KQUEUE on macOS / BACKEND_EPOLL on
    Linux — the same selection BlockingRuntime.new / the HTTP server's
    `_build_reactor` make.

    SIGTERM drain: `signal_shutdown_all()` is a TRIVIAL no-op (no worker
    pthreads to signal). The real serving shutdown is the binary's SIGTERM
    handler + final_flush, driven by the serve loop, not by
    this runtime.

    Movable: Reactor[S] is Movable (its Atomic state is wrapped in an
    OwnedPointer). The handle is therefore Movable; it must NOT be concurrently
    moved while a caller is driving its reactor (the borrow checker enforces
    single-`mut`-borrow per `mut self`).
    """

    comptime Sink = Self.S
    comptime RUNTIME_MODEL: UInt8 = MODEL_CLOUD_RUN
    comptime TASKS_ARE_THREAD_PINNED: Bool = False

    var _reactor: Reactor[Self.S]

    def __init__(out self, var sink: Self.S, backend: UInt8) raises:
        """Construct a GcpCloudRunRuntime owning one Reactor[S] on `backend`.

        `sink` is consumed (one reactor owns one sink). `backend` is one of
        BACKEND_EPOLL (Linux) / BACKEND_KQUEUE (macOS) / BACKEND_MOCK (tests
        with no real fd). Mismatching the backend to the host OS raises
        (Reactor's ctor enforces "BACKEND_EPOLL requires Linux" /
        "BACKEND_KQUEUE requires macOS"). Prefer the `.new(sink)` factory which
        comptime-selects the right backend for the host.
        """
        self._reactor = Reactor[Self.S](sink^, backend)

    @staticmethod
    def new(var sink: Self.S) raises -> GcpCloudRunRuntime[Self.S]:
        """Build a GcpCloudRunRuntime with the host-appropriate reactor backend
        comptime-selected (BACKEND_KQUEUE on macOS, BACKEND_EPOLL on Linux).

        The canonical factory — mirrors BlockingRuntime.new / the HTTP server's
        `_build_reactor` comptime selection so callers don't hardcode a backend
        per OS.
        """
        comptime if CompilationTarget.is_macos():
            return GcpCloudRunRuntime[Self.S](sink^, BACKEND_KQUEUE)
        else:
            return GcpCloudRunRuntime[Self.S](sink^, BACKEND_EPOLL)

    # -------------------------------------------------------------------------
    # The reactor accessor — how a caller / serve loop drives I/O.
    # -------------------------------------------------------------------------
    def reactor(mut self) -> ref [self._reactor] Reactor[Self.S]:
        """Return a mutable ref to the owned reactor.

        The caller threads this into the existing spin-then-park I/O methods
        (`HttpClient.send[RT](req, reactor)`, etc.). Those methods drive the
        single inline reactor on the calling thread.

        Origin form: `ref [self._reactor]`, the concrete-field origin —
        the SAME shape BlockingRuntime.reactor() uses.
        `ref [self]` is rejected by Mojo 1.0.0b1 with "incompatible origin".
        Caller binds via `ref r = rt.reactor()` (NOT `var r = rt.reactor()` —
        Reactor[S] is Movable-only and `var` would trigger an implicit
        move/copy).
        """
        return self._reactor

    # -------------------------------------------------------------------------
    # Runtime trait surface.
    # -------------------------------------------------------------------------
    def worker_count(self) -> Int:
        """Runtime trait. The GcpCloudRunRuntime has exactly ONE inline reactor
        driven on the serve thread (Cloud Run concurrency=1; scale by
        instances), so this always returns 1.

        `[RT]`-generic code that sizes per-worker connection sub-pools sees 1
        sub-pool — the expected shape for a single-request-at-a-time serving
        instance.
        """
        return 1

    def poll_completions(
        mut self, worker_idx: Int, timeout_us: Int32,
    ) raises -> Int:
        """Runtime trait. Drive ONE pass of the single inline reactor's I/O
        loop on the current thread; return the number of completions drained.

        Forwards to `Reactor.poll_completions(timeout_us)`. There is exactly
        one worker (the serve thread), so `worker_idx` MUST be 0 — any other
        value raises (the single-worker bounds-check contract, mirrors
        BlockingRuntime.poll_completions).

        `timeout_us = -1` blocks the calling thread on the reactor's ONE fd
        until ready (the single-fd park). `timeout_us = 0` is a non-blocking
        poll.
        """
        if worker_idx != 0:
            raise Error(
                "GcpCloudRunRuntime.poll_completions: worker_idx must be 0 "
                "(single inline-reactor runtime); got "
                + String(worker_idx)
            )
        var completions = self._reactor.poll_completions(timeout_us)
        return len(completions)

    def timer_advance(
        mut self, worker_idx: Int, now_ns: Int64,
    ) raises:
        """Runtime trait. v0.4 stub — Reactor does not yet own a TimerWheel
        (wires it), same as BlockingRuntime / PerCoreAsyncRuntime.
        The surface exists so `[RT]`-generic retry/timeout layers compile; the
        no-op is documented + harmless. `worker_idx` MUST be 0.
        """
        if worker_idx != 0:
            raise Error(
                "GcpCloudRunRuntime.timer_advance: worker_idx must be 0; got "
                + String(worker_idx)
            )
        _ = now_ns

    def timer_now_ns(self, worker_idx: Int) -> Int64:
        """Runtime trait. v0.4 stub — returns 0 until Reactor.TimerWheel is
        wired (matches BlockingRuntime / PerCoreAsyncRuntime). Out-of-range
        `worker_idx` returns 0 (no raise — same contract as the sibling stubs).
        """
        _ = worker_idx
        return Int64(0)

    def signal_shutdown_all(mut self):
        """Runtime trait + SIGTERM drain hook. TRIVIAL no-op for the inline
        GcpCloudRunRuntime: there are NO worker pthreads to signal. The single
        reactor is driven synchronously on the serve thread, so "shutdown" is
        simply the runtime value going out of scope (its `__del__` closes the
        multiplexer fd).

        The REAL serving shutdown — the no-loss guarantee — is the binary's
        SIGTERM handler + `final_flush` (in the serving
        binary's main): the serve loop polls the async-signal-safe
        shutdown flag, breaks, runs the final log flush, and exits cleanly
        within the Cloud Run 10s SIGTERM->SIGKILL grace. That logic is NOT
        driven from here. Present so the trait surface is uniform across
        conformers.
        """
        pass
