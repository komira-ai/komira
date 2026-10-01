# =============================================================================
# komira_async.runtime.blocking_runtime — BlockingRuntime[S] + block_on
# =============================================================================
# A current-thread / synchronous
# conformer of the `komira_async` `Runtime` trait, plus a `block_on`
# entrypoint, so SYNCHRONOUS callers can drive async-stack I/O to completion
# WITHOUT standing up a full async runtime (no pthreads, no scheduler, no
# work-stealing).
#
# This is the tokio `Runtime::new_current_thread()` + `block_on(fut)` model.
#
# Why this is cheap to build
# ----------------------------------------------------------------------------
# The komira_async I/O stack is ALREADY runtime-agnostic at the bottom: the
# user-facing wrappers (`TcpStream.read[S]` / `.write[S]` / `.connect[S]`,
# `TcpListener.accept[S]`, and — transitively — `HttpClient.send[RT]`,
# `TlsConnector.connect[RT]`) all drive I/O by taking a `mut reactor:
# Reactor[S]` and running a spin-then-park loop:
#
#     while True:
#         r = try_io_read(fd, buf)       # non-blocking syscall fast path
#         if r.is_ready(): return r.value()
#         if r.is_error(): raise ...
#         ensure_registered(reactor, ...) # lazy EPOLL_CTL_ADD / kevent
#         _ = reactor.poll_completions(timeout_us=-1)  # <-- BLOCK on ONE fd
#         # loop back, re-try the syscall (EPOLLET drain-to-EAGAIN)
#
# `reactor.poll_completions(timeout_us=-1)` is a single epoll_wait(-1) /
# kevent(NULL-timeout) on the worker's ONE multiplexer fd. For a runtime
# with exactly one in-flight op (the BlockingRuntime invariant), that wait
# IS "block the calling thread until this fd is ready" — precisely the
# tokio current-thread park. There is no task multiplexing to do because
# there is only one task.
#
# So the BlockingRuntime needs only:
#   1. Own exactly ONE Reactor[S] on the calling thread (no pthreads).
#   2. Conform to `Runtime` (so `[RT: Runtime]`-generic libraries pick it).
#   3. Hand out `ref [self._reactor] Reactor[S]` so a caller (or `block_on`)
#      can drive the existing spin-then-park I/O methods with it.
#
# `poll_completions(worker_idx, timeout_us)` (the TRAIT method, distinct from
# `Reactor.poll_completions`) is forwarded to the single reactor — there is
# exactly one "worker" (the calling thread); `worker_idx` must be 0.
#
# block_on(rt, work) — the entrypoint
# ----------------------------------------------------------------------------
# Mojo 1.0.0b1 does not have ergonomic async/await for user code, and the
# I/O stack is already synchronous (spin-then-park), so a "future" here is
# just a closure that drives I/O against the reactor and returns a value.
# `block_on` runs ONE such closure to completion on the BlockingRuntime's
# reactor and returns its result — the synchronous equivalent of
# `rt.block_on(async { ... }.await)`.
#
#     fn _do_get(mut reactor: Reactor[NoopSink]) raises -> ClientResponse[...]:
#         return http_client.send[BlockingRuntime[NoopSink]](req^, reactor)
#
#     var rt = BlockingRuntime[NoopSink].new(NoopSink(_placeholder=UInt8(0)))
#     var resp = block_on[NoopSink, ClientResponse[...]](rt, _do_get)
#
# Pointer discipline
# ----------------------------------------------------------------------------
# - ZERO UnsafePointer in any public signature on this file.
# - ZERO wildcard origins (MutAnyOrigin / ImmutAnyOrigin / MutExternalOrigin).
# - ZERO `unsafe_from_address=Int(...)`.
# - ZERO `take_pointee`.
# - ZERO ArcPointer.
# - The reactor accessor returns `ref [self._reactor] Reactor[Self.S]` — the
#   narrow concrete-field origin form, the
#   SAME shape `IoSubsystem.reactor()` uses. NOT `ref [self]` (compiler
#   rejects with "incompatible origin").
# - BlockingRuntime is safe across destroy-recreate: its only field is a Movable Reactor[S]
#   (no List/String/wildcard-origin field in a byte-slab; it is not stored
#   in a byte-slab at all). The Reactor's own heap-owning fields (List
#   _wakers / _pending_completions, OwnedPointer _next_op_id) live behind
#   the Reactor's own value, tracked normally.
# =============================================================================

from std.sys.info import CompilationTarget

from komira_async.ops.waker_sink import WakerSink
from komira_async.reactor.reactor import (
    BACKEND_EPOLL,
    BACKEND_KQUEUE,
    Reactor,
)
from komira_async.runtime.runtime_trait import (
    MODEL_CURRENT_THREAD_BLOCKING,
    Runtime,
)


# =============================================================================
# BlockingRuntime[S] — the current-thread / synchronous Runtime conformer.
# =============================================================================


struct BlockingRuntime[
    S: WakerSink & Movable & Deinitable,
](Runtime, Movable, Deinitable):
    """Current-thread, synchronous, single-task `Runtime` conformer.

    Owns exactly ONE `Reactor[S]` and drives it on the CALLING thread. No
    pthreads are launched; no scheduler runs; no work-stealing happens.
    When the single in-flight op parks on the reactor (EINPROGRESS on
    connect, EWOULDBLOCK on read/write), the calling thread blocks on the
    reactor's ONE multiplexer fd via `Reactor.poll_completions(-1)` until
    the fd is ready, then resumes. This is tokio's `current_thread` +
    `block_on` model.

    `[RT: Runtime]`-generic libraries (`HttpClient[RT]`, `TlsConnector`,
    and the runtime-parametric `komira_pg` / k8s clients) pick
    `BlockingRuntime[S]` as their `RT` for single-shot synchronous calls
    (a k8s pod GET, a one-row query) and for tests, where standing up a
    full `PerCoreAsyncRuntime` (N pinned pthreads) is unwarranted. In
    PRODUCTION the same libraries pick `PerCoreAsyncRuntime` for async
    parallelism (concurrent / pipelined reads); BlockingRuntime is the
    SYNC ESCAPE.

    Runtime trait conformance — comptime associated members:
      * `Sink = S`            — the waker-sink the single reactor uses.
      * `RUNTIME_MODEL`       — MODEL_CURRENT_THREAD_BLOCKING.
      * `TASKS_ARE_THREAD_PINNED = True` — there is one "worker" (the
        calling thread) and the single task never migrates.

    Field set:
      var _reactor: Reactor[Self.S]   — the one reactor, current-thread.

    Movable: Reactor[S] is Movable (its Atomic state is wrapped in an
    OwnedPointer). The BlockingRuntime handle is therefore Movable; it
    must NOT be concurrently moved while a caller is driving its reactor
    (the borrow checker enforces single-`mut`-borrow per `mut self`).

    Construction:
      var rt = BlockingRuntime[NoopSink].new()            # comptime backend
      var rt = BlockingRuntime[NoopSink](backend=...)     # explicit backend

    `.new()` comptime-selects BACKEND_KQUEUE on macOS / BACKEND_EPOLL on
    Linux — the same selection the HTTP server's `_build_reactor` makes.
    """

    comptime Sink = Self.S
    comptime RUNTIME_MODEL: UInt8 = MODEL_CURRENT_THREAD_BLOCKING
    comptime TASKS_ARE_THREAD_PINNED: Bool = True

    var _reactor: Reactor[Self.S]

    def __init__(out self, var sink: Self.S, backend: UInt8) raises:
        """Construct a BlockingRuntime owning one Reactor[S] on `backend`.

        `sink` is consumed (one reactor owns one sink). `backend` is one of
        BACKEND_EPOLL (Linux) / BACKEND_KQUEUE (macOS) / BACKEND_MOCK
        (tests with no real fd). Mismatching the backend to the host OS
        raises (Reactor's ctor enforces "BACKEND_EPOLL requires Linux" /
        "BACKEND_KQUEUE requires macOS"). Prefer the `.new(sink)` factory
        which comptime-selects the right backend for the host.
        """
        self._reactor = Reactor[Self.S](sink^, backend)

    @staticmethod
    def new(var sink: Self.S) raises -> BlockingRuntime[Self.S]:
        """Build a BlockingRuntime with the host-appropriate reactor backend
        comptime-selected (BACKEND_KQUEUE on macOS, BACKEND_EPOLL on Linux).

        This is the canonical user/test factory — mirrors the HTTP server's
        `_build_reactor` comptime selection so callers don't hardcode a
        backend per OS.
        """
        comptime if CompilationTarget.is_macos():
            return BlockingRuntime[Self.S](sink^, BACKEND_KQUEUE)
        else:
            return BlockingRuntime[Self.S](sink^, BACKEND_EPOLL)

    # -------------------------------------------------------------------------
    # The reactor accessor — how a caller / block_on drives I/O.
    # -------------------------------------------------------------------------
    def reactor(mut self) -> ref [self._reactor] Reactor[Self.S]:
        """Return a mutable ref to the owned reactor.

        The caller threads this into the existing spin-then-park I/O methods
        (`TcpStream.read[S](reactor, buf)`, `HttpClient.send[RT](req,
        reactor)`, etc.). Those methods block the calling thread on the
        reactor's ONE fd via `Reactor.poll_completions(-1)` when the op
        parks — which, for a single-task runtime, IS "block until ready".

        Origin form: `ref [self._reactor]`, the concrete-field origin —
        the SAME shape `IoSubsystem.
        reactor()` uses. `ref [self]` is rejected by Mojo 1.0.0b1 with
        "incompatible origin". Caller binds via `ref r = rt.reactor()`
        (NOT `var r = rt.reactor()` — Reactor[S] is Movable-only and `var`
        would trigger an implicit move/copy).
        """
        return self._reactor

    # -------------------------------------------------------------------------
    # Runtime trait surface.
    # -------------------------------------------------------------------------
    def worker_count(self) -> Int:
        """Runtime trait. BlockingRuntime has exactly ONE "worker" — the
        calling thread that drives the single reactor. Always returns 1.

        `[RT]`-generic code that sizes per-worker connection sub-pools sees
        1 sub-pool under BlockingRuntime (one conn per single-shot call —
        the expected shape for a sync escape).
        """
        return 1

    def poll_completions(
        mut self, worker_idx: Int, timeout_us: Int32,
    ) raises -> Int:
        """Runtime trait. Drive ONE pass of the single reactor's I/O loop;
        return the number of completions drained.

        Forwards to `Reactor.poll_completions(timeout_us)` and returns the
        length of the decoded completion list. There is exactly one worker,
        so `worker_idx` MUST be 0 — any other value raises (mirrors
        PerCoreAsyncRuntime.poll_completions's bounds-check contract).

        `timeout_us = -1` blocks the calling thread on the reactor's ONE fd
        until ready (the single-fd park). `timeout_us = 0` is a non-blocking
        poll. This is the trait-method side-channel; the typical drive path
        is the inline `reactor.poll_completions(-1)` inside the I/O
        wrappers, reached via `rt.reactor()`.
        """
        if worker_idx != 0:
            raise Error(
                "BlockingRuntime.poll_completions: worker_idx must be 0 "
                "(single-worker current-thread runtime); got "
                + String(worker_idx)
            )
        var completions = self._reactor.poll_completions(timeout_us)
        return len(completions)

    def timer_advance(
        mut self, worker_idx: Int, now_ns: Int64,
    ) raises:
        """Runtime trait. v0.4 stub — same shape as PerCoreAsyncRuntime's:
        Reactor does not yet own a TimerWheel. The
        surface exists so `[RT]`-generic retry/timeout layers compile; the
        no-op is documented + harmless. `worker_idx` MUST be 0.
        """
        if worker_idx != 0:
            raise Error(
                "BlockingRuntime.timer_advance: worker_idx must be 0; got "
                + String(worker_idx)
            )
        _ = now_ns

    def timer_now_ns(self, worker_idx: Int) -> Int64:
        """Runtime trait. v0.4 stub — returns 0 until Reactor.TimerWheel is
        wired (matches PerCoreAsyncRuntime). Out-of-range `worker_idx`
        returns 0 (no raise — same contract as PerCoreAsync's stub).
        Callers fall back to a wall-clock read until the wiring lands.
        """
        _ = worker_idx
        return Int64(0)

    def signal_shutdown_all(mut self):
        """Runtime trait. No-op for BlockingRuntime: there are no worker
        pthreads to signal. The single reactor is driven synchronously on
        the calling thread, so "shutdown" is simply the runtime value going
        out of scope (its `__del__` closes the multiplexer fd). Present so
        the trait surface is uniform across conformers.
        """
        pass


# =============================================================================
# block_on — run one "future" (a reactor-driving closure) to completion.
# =============================================================================


def block_on[
    S: WakerSink & Movable & Deinitable,
    T: Movable & Deinitable,
](
    mut rt: BlockingRuntime[S],
    work: def (mut reactor: Reactor[S]) raises thin -> T,
) raises -> T:
    """Run ONE reactor-driving closure to completion on `rt` and return its
    result. The synchronous equivalent of tokio's
    `rt.block_on(async { ... })`.

    `work` is the "future": a closure that performs the I/O (connect / read
    / write / an `HttpClient.send`) against the runtime's reactor and
    returns a value. It is driven on the CALLING thread; whenever its inner
    I/O parks (via the spin-then-park loop's `reactor.poll_completions(-1)`),
    the calling thread blocks on the reactor's ONE fd until ready, then the
    closure resumes. No async runtime is spun up; no pthread is launched.

    `block_on` simply binds the runtime's reactor and invokes `work` with
    it — the spin-then-park loops INSIDE the I/O wrappers do the parking.
    The single-task invariant means there is nothing to multiplex: the one
    closure either runs the syscall fast path or blocks the calling thread
    on its one fd.

    Returns `work`'s result by move (`T: Movable`). Re-raises any error the
    closure raises (connect refused, I/O error, parse error, ...).

    Pointer discipline: `work` takes `mut reactor: Reactor[S]` — a typed
    reference, no UnsafePointer crosses the boundary. The reactor is owned
    by `rt` for the call's duration; the closure borrows it.
    """
    # SAFETY/LIVENESS: `ref r` borrows rt's reactor for the duration of the
    # `work` call. rt (and thus its reactor) outlives this scope — it's a
    # `mut`-borrowed parameter the caller owns. The closure cannot retain
    # the ref past its own return (the fn signature borrows, doesn't move).
    ref r = rt.reactor()
    return work(r)
