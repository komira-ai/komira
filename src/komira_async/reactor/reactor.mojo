# =============================================================================
# komira_async.reactor.reactor — Reactor[S] + IoSubsystem[S]
# =============================================================================
#
# Each Worker owns its own Reactor[S] via _io_subsystem.reactor() (the
# per-worker architecture). Cross-worker reactor sharing is structurally
# impossible — a Worker cannot reach another Worker's Reactor by construction.
# Mojo's borrow checker enforces single-call per Reactor instance
# per Worker via `mut self`.
#
# IoSubsystem[S] owns one Reactor[S]; constructed once per WORKER. The
# `S` cascade stops at IoSubsystem[S].
#
# Surface:
#   - Reactor[S] gets the full field set (epoll_fd, wakers, sink, op_id).
#   - register_read / register_write / deregister / run_once / is_ready are
#     all functional against the Linux epoll backend (or raise on wrong OS).
#   - IoSubsystem[S] is the thin Reactor[S]-owning wrapper; reactor() returns
#     `ref [self._reactor] Reactor[Self.S]` (a ref-return through the inner field).
#
# `WakerSlot` is the internal-to-this-module bookkeeping POD: maps op_id to
# (fd, mode, ready). We use a List[WakerSlot] as a Movable slab equivalent —
# the engine has a Slab[T] primitive that we'd use for production scale, but
# keeps komira_async self-contained.
#
# Demux scaling: the slot table was
# scoped "typically <100 ops per worker", and `_find_slot_idx` LINEAR-SCANNED
# it. The streaming gap — thousands of idle parked streams, each with a
# MODE_TIMER WakerSlot — makes every completion an O(n) scan and a wake STORM
# O(n^2). The Class-B "op_id -> idx hashmap" the prior comment flagged is now
# warranted and shipped: `_slot_index` (an `OpIdIndexMap`, ALL POD) maps op_id
# -> the dense `_wakers` index so `_find_slot_idx` is O(1) amortized. `_wakers`
# stays DENSE via the existing swap-remove in `deregister`; the map is patched
# in lock-step (tombstone the removed op_id; the swapped-in element's entry is
# repointed to the freed index).
# =============================================================================

from komira_atomic_alias import AtomicI64
from std.memory import OwnedPointer, alloc
from std.sys.info import CompilationTarget

from komira_async.ops.waker_sink import WakerSink
from komira_async.reactor.completion_queue import (
    Completion,
    INTEREST_READ,
    INTEREST_WRITE,
    OP_ACCEPT,
    OP_CONNECT,
    OP_ERR,
    OP_PENDING,
    OP_READ,
    OP_READY,
    OP_TIMER,
    OP_WRITE,
    OpHandle,
    RegistrationHandle,
)
from komira_async.reactor.epoll_subsystem import (
    EpollEvent,
    EPOLLERR,
    EPOLLET,
    EPOLLHUP,
    EPOLLIN,
    EPOLLOUT,
    MODE_READ,
    MODE_WRITE,
    close_timerfd,
    drain_timerfd,
    epoll_close,
    epoll_create_v1,
    epoll_ctl_add,
    epoll_ctl_del,
    epoll_ctl_mod,
    epoll_wait_decode,
    timerfd_arm_relative,
    timerfd_create_monotonic,
)
from komira_async.reactor.kqueue_subsystem import (
    EVFILT_READ,
    EVFILT_TIMER,
    EVFILT_WRITE,
    EV_EOF,
    EV_ERROR,
    KEvent,
    OP_ID_WAKE_USER,
    kevent_deregister,
    kevent_deregister_timer,
    kevent_register,
    kevent_register_timer,
    kevent_register_user_wake,
    kevent_user_wake,
    kevent_wait_decode,
    kqueue_close,
    kqueue_create,
)
from komira_async.reactor.socket_io import (
    TRY_IO_ERROR,
    TRY_IO_IN_PROGRESS,
    TRY_IO_READY,
    TRY_IO_WOULD_BLOCK,
    TryIoResult,
    errno_is_in_progress,
    errno_is_would_block,
    try_io_read,
    try_io_write,
    try_recv,
    try_send,
)
from std.ffi import external_call

from komira_async.runtime.op_id_index_map import OpIdIndexMap
from komira_async.runtime.wake_primitives import (
    OP_ID_IO_PARK,
    OP_ID_WAKE_EVENTFD,
    WorkerWakeHandle,
    close_eventfd,
    create_eventfd,
    drain_eventfd,
    write_eventfd,
)


@always_inline
def _null_ptr[T: AnyType, o: Origin]() -> UnsafePointer[T, o]:
    """A NULL typed pointer with a concrete origin (replaces the b2-removed
    `UnsafePointer[T, o](_unsafe_null=())` null ctor).

    # SAFETY: `Optional[UnsafePointer[...]]` is layout-compatible with the bare
    # pointer (modular/mojo/proposals/non-null-pointer.md); `None` is the all-zero
    # (NULL) bit pattern. Used only for NULL syscall arguments below.
    """
    var none: Optional[UnsafePointer[T, o]] = None
    return UnsafePointer(to=none).bitcast[UnsafePointer[T, o]]()[]


# BackendKind enum: UInt8 sentinel
# stand-in (0 = Mock, 1 = Epoll, 2 = Kqueue, 3 = IoUring, 4 = Dpdk).
# A later step may replace this with a proper variant + IoUringConfig / DpdkConfig
# payloads.
comptime BACKEND_MOCK: UInt8 = 0
comptime BACKEND_EPOLL: UInt8 = 1
comptime BACKEND_KQUEUE: UInt8 = 2
comptime BACKEND_IO_URING: UInt8 = 3
comptime BACKEND_DPDK: UInt8 = 4


# op_id/fd demux disjointness bias. `alloc_op_id`
# offsets every dynamically-allocated op_id by this base so it is structurally
# above any process file descriptor (RLIMIT_NOFILE is hard-capped well under
# 2^40 on any system). A `Completion.op_id < OP_ID_ALLOC_BASE` is therefore an
# fd-cookie (a listener / long-lived conn registration); one `>=
# OP_ID_ALLOC_BASE` is a dynamically-registered op. See `alloc_op_id`'s
# docstring + `komira_async.runtime.suspendable_handler.HANDLER_OP_ID_BIAS`
# (which aliases this value for the server-seam demux predicate).
comptime OP_ID_ALLOC_BASE: Int64 = Int64(1) << 40


# 3 — WakerSlot.mode sentinel for a
# reactor-OWNED timer registration. Distinct from MODE_READ / MODE_WRITE
# (which park on a fd the CALLER owns): a MODE_TIMER slot's fd is a timerfd the
# REACTOR created (Linux) and must close on deregister; on macOS the slot's fd
# is -1 (EVFILT_TIMER's ident is the op_id, not an fd) and deregister tears the
# timer down via kevent_deregister_timer keyed on the op_id.
comptime MODE_TIMER: UInt8 = 3


# -----------------------------------------------------------------------------
# Free-function helpers (module-private).
# -----------------------------------------------------------------------------


@always_inline
def _op_id_in_list(op_id: Int64, op_ids: List[Int64]) -> Bool:
    """Linear membership check for the bulk-parallel pattern's
    `try_pop_any_completion(op_ids)` primitive. M = len(op_ids) is typically
    <=64; the
    linear scan stays in L1 and dominates over any indexed-lookup overhead
    until M >> 64, which is unrealistic for the
    in-flight-per-worker scale.
    """
    var n = len(op_ids)
    for i in range(n):
        if op_ids[i] == op_id:
            return True
    return False


# -----------------------------------------------------------------------------
# WakerSlot — internal POD per-op state.
# -----------------------------------------------------------------------------

@fieldwise_init
struct WakerSlot(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    """Per-op record in the reactor's waker table. POD.

    `op_id`: monotone-allocated by Reactor.alloc_op_id().
    `fd`: the file descriptor this op is parked on. -1 = sentinel (slot
          allocated but not yet bound; deregistered slot may also have fd=-1
          before the slot is freed).
    `mode`: MODE_READ / MODE_WRITE.
    `consumer_id`: optional caller-supplied tag (unused;
                  uses for cross-worker SPSC dispatch).
    `ready`: set True when epoll_wait reports readiness for this op.
    """

    var op_id: Int64
    var fd: Int32
    var mode: UInt8
    var consumer_id: UInt16
    var ready: Bool


# -----------------------------------------------------------------------------
# Reactor[S] — per-worker reactor.
# -----------------------------------------------------------------------------


struct Reactor[S: WakerSink & Movable & Deinitable](
    Movable, Deinitable
):
    """Per-worker reactor. Each Worker owns its own Reactor[S] via IoSubsystem[S].

    Movable: the heap-owning Atomic field is wrapped in OwnedPointer so the
    Reactor handle itself is composed of Movable parts (Int32 + List + S +
    OwnedPointer + ...). The reactor still must NOT be CONCURRENTLY moved
    while a worker is driving it — the borrow checker enforces this via
    `mut self`.

    Field set:
      var _epoll_fd: Int32                          # owned epoll fd (Linux); -1 elsewhere
      var _wakers: List[WakerSlot]                  # op_id -> WakerSlot
      var _sink: Self.S                             # worker waker sink
      var _next_op_id: OwnedPointer[Atomic[DType.int64]]   # monotone op-id allocator
      var _pending_completions: List[Completion]    # buffer for try_pop_any_completion non-matches

    Scope: Linux epoll backend; the macOS kqueue backend; the mock
    backend is the always-available test fixture.

    `_pending_completions` buffer added for the bulk-parallel
    pattern's `try_pop_any_completion(op_ids)` primitive. When
    `try_pop_any_completion` does its non-blocking poll, any
    completions that don't match the supplied op_id set are stashed here
    so they aren't lost; the next `poll_completions` call drains the buffer
    first (prepended to the returned list). The buffer is bounded by
    in-flight depth (typically <100; never grows unbounded since each
    completion gets consumed eventually by either a try_pop_any_completion
    match or a poll_completions drain).
    """

    var _epoll_fd: Int32
    var _wake_eventfd: Int32
    var _wakers: List[WakerSlot]
    # op_id -> dense index into _wakers. O(1) demux.
    # ALL POD; safe across destroy-recreate. Kept in lock-step with _wakers (register appends +
    # inserts; deregister swap-removes + patches).
    var _slot_index: OpIdIndexMap
    var _sink: Self.S
    var _next_op_id: OwnedPointer[AtomicI64]
    var _pending_completions: List[Completion]

    def __init__(out self, var sink: Self.S, backend: UInt8) raises:
        """+ (eventfd). `sink` is consumed
        (one reactor owns one sink). `backend` selects the underlying
        syscall surface.

: under BACKEND_EPOLL (Linux), allocates a per-Reactor
        eventfd and registers it with the epoll set under sentinel
        OP_ID_WAKE_EVENTFD. The eventfd is the producer-wake mechanism
        (write here from another thread → consumer's epoll_wait returns).

        Under BACKEND_MOCK, _wake_eventfd remains the -1 sentinel
        (write_eventfd / drain_eventfd are no-ops on -1).
        """
        self._sink = sink^
        self._wakers = List[WakerSlot]()
        self._slot_index = OpIdIndexMap()
        # buffer for try_pop_any_completion non-matches.
        # Empty at construction; populated only when a try_pop call's
        # non-blocking poll returns completions that don't match the
        # supplied op_id set. Drained by the next poll_completions call.
        self._pending_completions = List[Completion]()
        # Atomic is non-Movable on 0.26.3; wrap in OwnedPointer so the
        # Reactor handle remains Movable. The OwnedPointer ctor accepts
        # `value=Atomic(...)` because Atomic itself can be constructed
        # in-place via the OwnedPointer's heap allocation path.
        var op_id_ptr = alloc[AtomicI64](1)
        # SAFETY: op_id_ptr is fresh; we initialize the slot with an
        # in-place Atomic ctor via direct field-style assignment (per
        # Repro 7 pattern: `rawA[].c = Atomic(...)`). Then transfer
        # ownership to OwnedPointer.
        op_id_ptr[] = AtomicI64(Int64(0))
        self._next_op_id = OwnedPointer[AtomicI64](
            unsafe_from_raw_pointer=op_id_ptr
        )
        if backend == BACKEND_EPOLL:
            comptime if CompilationTarget.is_linux():
                self._epoll_fd = epoll_create_v1()
                # Create eventfd + register with epoll under
                # OP_ID_WAKE_EVENTFD sentinel.
                self._wake_eventfd = create_eventfd()
                epoll_ctl_add(
                    self._epoll_fd, self._wake_eventfd,
                    EPOLLIN, UInt64(OP_ID_WAKE_EVENTFD),
                )
            else:
                self._epoll_fd = Int32(-1)
                self._wake_eventfd = Int32(-1)
                raise Error("BACKEND_EPOLL requires Linux")
        elif backend == BACKEND_MOCK:
            # Mock backend: no kernel fd; `_epoll_fd = -1` is the sentinel.
            # 7 wires MockSubsystem with deterministic readiness
            # injection; until then, Reactor with backend=MOCK is a no-op
            # reactor whose run_once returns 0. _wake_eventfd is also -1;
            # write_eventfd / drain_eventfd are no-ops on -1.
            self._epoll_fd = Int32(-1)
            self._wake_eventfd = Int32(-1)
        elif backend == BACKEND_KQUEUE:
            # KQueueSubsystem.
            # We reuse the Linux-historical `_epoll_fd` field name as the
            # multiplexer-fd field; on macOS it holds the kq_fd. Field
            # rename to `_mux_fd` is a possible later cleanup.
            #
            # On Linux build: this branch raises (the wrong-OS guard in
            # kqueue_create + kevent_register_user_wake makes this branch
            # unreachable in practice on Linux ELF builds — the FFI is
            # elided at codegen).
            comptime if CompilationTarget.is_macos():
                var kq = kqueue_create()
                kevent_register_user_wake(
                    kq, UInt64(0), UInt64(OP_ID_WAKE_USER),
                )
                self._epoll_fd = kq           # repurpose as kq_fd
                self._wake_eventfd = Int32(0) # ident=0 sentinel "user wake live"
            else:
                self._epoll_fd = Int32(-1)
                self._wake_eventfd = Int32(-1)
                raise Error("BACKEND_KQUEUE requires macOS")
        else:
            self._epoll_fd = Int32(-1)
            self._wake_eventfd = Int32(-1)
            raise Error("Unknown backend kind")

    def __deinit__(deinit self):
        """Close the multiplexer fd (epoll on Linux / kqueue on Mac) +
        wake fd (eventfd on Linux / EVFILT_USER auto-tied-to-kq on Mac);
        MOCK backend has -1 sentinels which the close helpers skip.

        Teardown discipline: the close path is a
        sequence of free-fn calls (no `mut self` re-entry).

        Per the `_runtime_teardown_join` discipline, this destructor
        runs AFTER every worker pthread has joined, so no consumer is
        racing the close. Per field-drop ordering, the
        producer-side WorkerWakeHandle slabs are deallocated BEFORE
        this destructor runs, so no producer is racing either.

        added Mac branch — `_epoll_fd` is
        repurposed as the kq_fd on macOS, so `epoll_close` (Linux-only
        guarded) was a no-op pre-fix → Reactor leaked the kq_fd on
        every drop. `kqueue_close` correctly closes the fd; closing
        the kqueue fd tears down all registrations (including the
        EVFILT_USER wake channel) atomically, so no
        `kevent_deregister` of the user channel is needed.
        """
        comptime if CompilationTarget.is_macos():
            # On Mac, _epoll_fd holds the kq_fd. kqueue_close is a no-op
            # on negative fd. EVFILT_USER + EVFILT_TIMER registrations are
            # auto-torn-down when the kq_fd closes — no explicit deregister
            # needed (timer idents are not fds).
            kqueue_close(self._epoll_fd)
        else:
            # 3: close any REACTOR-OWNED timerfds still in the
            # waker table (a parked stream dropped without an explicit
            # deregister would otherwise leak its timerfd). MODE_TIMER slots own
            # their fd; MODE_READ/MODE_WRITE fds belong to the caller and are
            # left untouched. Best-effort; close on -1 is a no-op.
            for i in range(len(self._wakers)):
                if self._wakers[i].mode == MODE_TIMER:
                    close_timerfd(self._wakers[i].fd)
            # epoll_ctl_del raises on syscall failure but ENOENT is the
            # only expected failure mode here (eventfd never registered,
            # e.g. on MOCK backend); swallow via try/except per
            # destructor contract.
            if self._epoll_fd >= 0 and self._wake_eventfd >= 0:
                try:
                    epoll_ctl_del(self._epoll_fd, self._wake_eventfd)
                except:
                    pass
            close_eventfd(self._wake_eventfd)
            epoll_close(self._epoll_fd)

    def alloc_op_id(mut self) -> Int64:
        """Monotone op-id allocator.

        op_id/fd demux disjointness: the allocator is
        BIASED by `OP_ID_ALLOC_BASE` (2^40) so every dynamically-allocated
        op_id is structurally ABOVE any possible file descriptor. This makes
        the HttpServer's op_id demux unambiguous: a `Completion.op_id` that
        falls in the fd-cookie space (a listener / long-lived conn registration
        uses `UInt64(fd)` as its kernel cookie — `register_long_lived`) is a
        connection event, while one >= OP_ID_ALLOC_BASE is a
        dynamically-registered op (a suspendable handler's awaited PG read,
        registered under this allocator). Without the bias the two sub-spaces
        OVERLAP — after a handful of `register_read`s the monotone counter
        passes through live conn fd values (>=3), and the reactor would alias
        two distinct fds under the same kernel cookie, mis-routing completions
        and corrupting the parked handler state machine.

        The bias is invisible to every existing consumer: op_ids are opaque
        keys (registered, matched in completions, deregistered) — nothing reads
        their numeric magnitude — and the allocator stays strictly monotone, so
        the reactor / mock-subsystem monotonicity contracts are preserved. The
        negative wake/park sentinels (`OP_ID_WAKE_EVENTFD = -1`,
        `OP_ID_IO_PARK = -2`) remain disjoint (they are negative; biased values
        are large positive). `fetch_add` still starts the counter at 0 so the
        first op_id is `OP_ID_ALLOC_BASE + 1`."""
        return self._next_op_id[].fetch_add(1) + OP_ID_ALLOC_BASE + Int64(1)

    def _find_slot_idx(self, op_id: Int64) -> Int:
        """Return the index of the slot for `op_id`, or -1 if not found.

        O(1) amortized via `_slot_index` (a linear scan
        does not scale to thousands of idle timer-parked streams)."""
        return self._slot_index.lookup(op_id)

    def register_read(
        mut self, fd: Int32, op_id: Int64, consumer_id: UInt16
    ) raises:
        """Register `fd` for read-readiness
        notifications under the given op_id.

        Mac branch added — calls
        `kevent_register(EVFILT_READ, edge_triggered=False)` against
        the kq_fd repurposed in `_epoll_fd`.
        """
        if self._epoll_fd >= 0:
            comptime if CompilationTarget.is_macos():
                kevent_register(
                    self._epoll_fd, fd, EVFILT_READ, UInt64(op_id),
                    edge_triggered=False,
                )
            else:
                epoll_ctl_add(self._epoll_fd, fd, EPOLLIN, UInt64(op_id))
        self._slot_index.insert(op_id, len(self._wakers))
        self._wakers.append(
            WakerSlot(
                op_id=op_id,
                fd=fd,
                mode=MODE_READ,
                consumer_id=consumer_id,
                ready=False,
            )
        )

    def register_write(
        mut self, fd: Int32, op_id: Int64, consumer_id: UInt16
    ) raises:
        """Register `fd` for write-readiness.

        Mac branch added — `EVFILT_WRITE`
        on the kq_fd.
        """
        if self._epoll_fd >= 0:
            comptime if CompilationTarget.is_macos():
                kevent_register(
                    self._epoll_fd, fd, EVFILT_WRITE, UInt64(op_id),
                    edge_triggered=False,
                )
            else:
                epoll_ctl_add(self._epoll_fd, fd, EPOLLOUT, UInt64(op_id))
        self._slot_index.insert(op_id, len(self._wakers))
        self._wakers.append(
            WakerSlot(
                op_id=op_id,
                fd=fd,
                mode=MODE_WRITE,
                consumer_id=consumer_id,
                ready=False,
            )
        )

    def register_timer(mut self, deadline_ns: Int64) raises -> Int64:
        """Register a ONE-SHOT
        deadline timer and return a BIASED, parkable op_id (>= OP_ID_ALLOC_BASE)
        that resumes the parked frame EXACTLY like a register_read completion.

        The deadline fires as an ordinary fd-readiness completion routed through
        the SAME `run_once` / `poll_completions` demux as a socket read:
          * Linux: `timerfd_create(CLOCK_MONOTONIC)` + arm it for `deadline_ns`
            relative + `epoll_ctl_add` under the biased op_id cookie. When the
            deadline elapses the timerfd becomes EPOLLIN-readable -> run_once
            marks the WakerSlot.ready + fires `_sink.wake(op_id)`, identical to a
            register_read fd. The slot is MODE_TIMER so `deregister` knows to
            CLOSE the reactor-owned timerfd (the caller never sees the fd).
          * macOS: a one-shot `EVFILT_TIMER` (kevent_register_timer) keyed on the
            same biased op_id in udata; EV_ONESHOT auto-deregisters after firing.
            The slot's fd is -1 (EVFILT_TIMER's ident is the op_id, not an fd).

        Because the op_id is biased (>= OP_ID_ALLOC_BASE == HANDLER_OP_ID_BIAS),
        a SuspendableHandlerDriver keyed on this op_id in its ParkedMorselSlab
        routes the completion to `driver.resume()` like ANY parked PG read — ZERO
        driver change. The op_id source is intentionally GENERIC (a plain biased
        op_id, no timer-specific tagging in its numeric value) so a future shared
        condition / Notify-demux is a drop-in replacement.

        HAZARD (one timerfd per parked stream): each parked idle stream consumes
        ONE fd on Linux (the timerfd) until its deadline fires or it is
        deregistered. RLIMIT_NOFILE (typically 1024 soft / 1M+ hard, raisable)
        is therefore the new ceiling on CONCURRENT idle streams — much higher
        than the PG pool ceiling we are relieving, but it IS a ceiling. A future
        shared-timer / TimerWheel-backed variant (many cheap in-process timers
        on one fd) removes the per-stream fd; this primitive deliberately picks
        the simple one-fd-per-stream shape because a long-lived idle park wants
        an independent kernel-armed deadline, not a wheel tick.

        `deadline_ns <= 0` arms a near-immediate fire (a zero-delay idle wake).

        On the MOCK / non-multiplexer backend (`_epoll_fd < 0`): allocates +
        returns the biased op_id and records a MODE_TIMER slot with fd=-1, but
        does NOT arm a kernel timer (there is none). The slot never becomes
        ready on its own under MOCK — a test drives readiness via a MockSubsystem
        analog or the MockIdleWakeOp poll-counter seam. This keeps the op_id
        contract uniform across backends.
        """
        var op_id = self.alloc_op_id()
        if self._epoll_fd < 0:
            # MOCK / no-multiplexer backend: record the slot but arm no kernel
            # timer. fd=-1 so deregister's close path is a no-op.
            self._slot_index.insert(op_id, len(self._wakers))
            self._wakers.append(
                WakerSlot(
                    op_id=op_id, fd=Int32(-1), mode=MODE_TIMER,
                    consumer_id=UInt16(0), ready=False,
                )
            )
            return op_id
        comptime if CompilationTarget.is_macos():
            # macOS: one-shot EVFILT_TIMER keyed on the biased op_id. The slot's
            # fd is -1 (EVFILT_TIMER's ident is the op_id itself, not a kernel
            # fd). The kqueue fd is in self._epoll_fd (field-repurposing).
            kevent_register_timer(
                self._epoll_fd, UInt64(op_id), deadline_ns, UInt64(op_id),
            )
            self._slot_index.insert(op_id, len(self._wakers))
            self._wakers.append(
                WakerSlot(
                    op_id=op_id, fd=Int32(-1), mode=MODE_TIMER,
                    consumer_id=UInt16(0), ready=False,
                )
            )
        else:
            # Linux: a CLOCK_MONOTONIC timerfd armed for `deadline_ns`, added to
            # epoll under the biased op_id cookie. The timerfd is REACTOR-OWNED
            # (closed on deregister); the caller never sees the fd.
            var tfd = timerfd_create_monotonic()
            timerfd_arm_relative(tfd, deadline_ns)
            epoll_ctl_add(self._epoll_fd, tfd, EPOLLIN, UInt64(op_id))
            self._slot_index.insert(op_id, len(self._wakers))
            self._wakers.append(
                WakerSlot(
                    op_id=op_id, fd=tfd, mode=MODE_TIMER,
                    consumer_id=UInt16(0), ready=False,
                )
            )
        return op_id

    def deregister(mut self, op_id: Int64) raises:
        """Remove the op from the reactor's
        tracking + multiplexer set. Best-effort: missing slot is benign
        (already drained or never registered).

        3: a MODE_TIMER slot owns its
        registration differently — on Linux the slot's fd is a REACTOR-OWNED
        timerfd that must be epoll-removed AND closed (else the fd leaks); on
        macOS the timer is an EVFILT_TIMER keyed on the op_id (no fd) torn down
        via kevent_deregister_timer.

        Mac branch added — `kevent_deregister`
        on the (fd, filter) pair stored in the WakerSlot. kqueue requires
        per-filter deregister; the slot's `mode` records which filter
        was registered.
        """
        var idx = self._find_slot_idx(op_id)
        if idx < 0:
            return
        var fd = self._wakers[idx].fd
        var mode = self._wakers[idx].mode
        if self._epoll_fd >= 0:
            comptime if CompilationTarget.is_macos():
                # Pick filter from mode. The mode is set at register
                # time so this is unambiguous.
                if mode == MODE_TIMER:
                    # EVFILT_TIMER keyed on the op_id (no fd). EV_ONESHOT may
                    # already have auto-deregistered; this is best-effort.
                    kevent_deregister_timer(self._epoll_fd, UInt64(op_id))
                elif fd >= 0 and mode == MODE_READ:
                    kevent_deregister(self._epoll_fd, fd, EVFILT_READ)
                elif fd >= 0:
                    kevent_deregister(self._epoll_fd, fd, EVFILT_WRITE)
            else:
                if mode == MODE_TIMER and fd >= 0:
                    # Reactor-owned timerfd: remove from epoll AND close it
                    # (else the fd leaks). epoll_ctl_del is best-effort.
                    epoll_ctl_del(self._epoll_fd, fd)
                    close_timerfd(fd)
                elif fd >= 0:
                    epoll_ctl_del(self._epoll_fd, fd)
        # Compact: swap-remove with last element. Patch the index map in
        # lock-step: tombstone the removed op_id, and if
        # the swap moved the last element into `idx`, repoint its map entry.
        var last = len(self._wakers) - 1
        if idx != last:
            var moved_op_id = self._wakers[last].op_id
            self._wakers[idx] = self._wakers[last]
            self._slot_index.update(moved_op_id, idx)
        _ = self._wakers.pop()
        _ = self._slot_index.remove(op_id)

    def run_once(mut self, timeout_us: Int32) raises -> Int:
        """+ (eventfd routing).

        Drive the reactor for one cycle: epoll_wait up to `timeout_us`,
        decode ready events, route per-event:
          - if event op_id == OP_ID_WAKE_EVENTFD: drain the eventfd
            (do NOT touch _wakers; do NOT fire _sink.wake — this is a
            wake-only event, not an IO event).
          - otherwise: mark the WakerSlot.ready + invoke _sink.wake(op_id).

        Returns the number of ready events (including any eventfd wake
        events).

        timeout_us is in microseconds; epoll_wait takes ms; we
        convert at the boundary. timeout_us=0 means non-blocking poll;
        timeout_us=-1 (passed through epoll_wait as -1 ms) means block
        indefinitely (the spin-then-park design's PARK_TIMEOUT_US=-1).
        Otherwise we round UP to the nearest ms.

: per-event handling, NOT strict eventfd-first ordering.
        The kernel batch order is undefined; both paths converge.
        """
        if self._epoll_fd < 0:
            # Mock / uninitialized backend — nothing to drive.
            #
            # H1 fix: when the worker calls
            # run_once(timeout_us=-1) under MOCK, it intends to PARK
            # (the spin-then-park loop's park phase). Without an epoll
            # fd to actually park on, returning 0 instantly means the
            # worker tightly busy-spins in run_until_shutdown. Under
            # the spawn+join hot path this denies CPU to the producer
            # pthread (calling thread) — the producer's join-spin
            # eventually drops cooperative control to the worker, the
            # JoinHandle.join wait_on_address timeout (1ms) fires
            # without the worker having executed the trampoline,
            # then the producer races to drop+rebuild — under enough
            # repetition this surfaces as the CancelledError flake +
            # tcmalloc heap state corruption.
            #
            # Yielding the CPU on the "park" intent restores fair
            # scheduling between worker pthread + producer thread.
            # No-op when timeout_us=0 (the spin phase's non-blocking
            # poll); only fires on the "block forever" intent.
            if timeout_us < Int32(0):
                # Use nanosleep for ~10us pause to actually yield CPU
                # and avoid busy-spinning. struct timespec is {tv_sec,
                # tv_nsec} = 16 bytes on Linux x86_64.
                var ts_sec: Int64 = 0
                var ts_nsec: Int64 = 10_000  # 10 microseconds
                var ts = SIMD[DType.int64, 2](ts_sec, ts_nsec)
                _ = external_call["nanosleep", Int32](
                    UnsafePointer(to=ts).bitcast[UInt8](),
                    # SAFETY: arg1 points at
                    # stack-local `ts` (lives across the call); arg2 (`rem`
                    # out-param) is NULL — we don't restart on EINTR and don't
                    # need the remaining time, libc tolerates NULL here.
                    _null_ptr[UInt8, MutUntrackedOrigin](),
                )
            return 0
        # branch on platform. On Linux the
        # `_epoll_fd` field holds the epoll fd; on Mac under
        # BACKEND_KQUEUE it holds the kq_fd (existing field-repurposing
        # pattern from `__init__`). The two backends decode
        # different event structs (EpollEvent: events/data; KEvent:
        # flags/udata) but converge on the same Completion shape via
        # the per-event handler.
        comptime if CompilationTarget.is_macos():
            # kqueue path. timeout_us in microseconds maps directly to
            # kevent's struct timespec; Linux epoll takes ms.
            var kevents = List[KEvent]()
            var n = kevent_wait_decode(
                self._epoll_fd, kevents, Int64(timeout_us),
            )
            for i in range(n):
                var ev = kevents[i]
                var op_id = Int64(ev.udata)
                if op_id == OP_ID_WAKE_USER:
                    # EVFILT_USER wake event — auto-cleared by EV_CLEAR
                    # in `kevent_register_user_wake`. No drain required
                    # (kqueue's analog of eventfd is self-resetting).
                    continue
                # Find the slot and mark ready.
                var idx = self._find_slot_idx(op_id)
                if idx >= 0:
                    self._wakers[idx].ready = True
                    try:
                        self._sink.wake(op_id)
                    except:
                        pass
            return n
        else:
            # Linux epoll path.
            var timeout_ms: Int32
            if timeout_us < Int32(0):
                timeout_ms = Int32(-1)
            elif timeout_us == Int32(0):
                timeout_ms = Int32(0)
            else:
                # Round UP: 1us..999us -> 1ms; 1000us -> 1ms; 1500us -> 2ms.
                timeout_ms = (timeout_us + Int32(999)) // Int32(1000)
            var events = List[EpollEvent]()
            var n = epoll_wait_decode(self._epoll_fd, events, timeout_ms)
            for i in range(n):
                var ev = events[i]
                var op_id = Int64(ev.data)
                if op_id == OP_ID_WAKE_EVENTFD:
                    # Eventfd wake event — drain only; level-
                    # triggered so we MUST drain to avoid spinning on a
                    # ready-but-undrained eventfd on the next epoll_wait.
                    # Do NOT touch _wakers; do NOT fire _sink.wake.
                    drain_eventfd(self._wake_eventfd)
                    continue
                # Find the slot and mark ready.
                var idx = self._find_slot_idx(op_id)
                if idx >= 0:
                    # 3: a MODE_TIMER slot's timerfd is
                    # LEVEL-TRIGGERED EPOLLIN — drain it (read the 8-byte
                    # expiration count) so the next epoll_wait does not spin on
                    # a ready-but-undrained timerfd. The op_id still marks ready
                    # + fires the sink, identical to a read completion (the
                    # parked frame resumes through the existing path).
                    if self._wakers[idx].mode == MODE_TIMER:
                        drain_timerfd(self._wakers[idx].fd)
                    self._wakers[idx].ready = True
                    # Fire the sink (best-effort; sink failure shouldn't
                    # poison reactor state).
                    try:
                        self._sink.wake(op_id)
                    except:
                        pass
            return n

    # =========================================================================
    # transient fd park for the streaming
    # round-robin drain (the reactor-driven park the local_io_block header
    # describes).
    #
    # The cloud-read / cloud-write streaming drains (`s3_fs.read_ranges_prefetched`,
    # `_drain_inflight_round_robin`, `collect_body`, `drain_bodies_round_robin`)
    # busy-spin a non-blocking `try_read`→EWOULDBLOCK round-robin. That spin is
    # sub-µs-cheap for local NVMe/mmap (resolves within the spin) but burns the
    # entire RTT for network I/O. `park_on_fds` lets the drain, after a small
    # bounded spin budget with NO progress, PARK on epoll until ANY of the K
    # in-flight fds becomes readable — reclaiming the network-wait CPU.
    #
    # This is a SELF-CONTAINED park: it does NOT touch `_wakers` (the op_id
    # slot table the worker's task scheduler owns) and does NOT fire `_sink`.
    # It transiently EPOLL_CTL_ADDs each fd, epoll_waits once, then
    # EPOLL_CTL_DELs each fd it added. The caller re-checks every stream via
    # its own non-blocking poll after this returns — so the park carries no
    # readiness state across the call.
    #
    # LOST-WAKEUP SAFETY: the caller only reaches here AFTER a full
    # no-progress pass, where every in-flight stream returned WouldBlock from
    # a real non-blocking syscall. epoll is LEVEL-TRIGGERED here (we register
    # plain EPOLLIN, no EPOLLET): if a fd became readable in the window
    # between the caller's last try_read and this EPOLL_CTL_ADD, epoll_wait
    # returns it IMMEDIATELY (the kernel reports current readiness on ADD, not
    # only edges). So there is no window in which a byte can arrive unobserved
    # and leave us blocked forever. A timeout (timeout_us >= 0) is an
    # additional belt-and-suspenders bound; the caller resumes the round-robin
    # and re-polls regardless of why park returned.
    # =========================================================================
    def park_on_fds(
        mut self,
        ref fds: List[Int32],
        timeout_us: Int32,
        want_write: Bool = False,
    ) raises -> Int:
        """Park until ANY fd in `fds` is ready, or until `timeout_us`
        elapses (timeout_us=-1 blocks indefinitely; on this path callers
        pass a finite bound as a belt-and-suspenders cap).

        `want_write` selects the readiness interest:
          * False (default, the READ drain): EPOLLIN only. A TCP stream
            socket is almost always WRITE-ready (send buffer has space),
            so arming EPOLLOUT here would make the park return instantly
            every time and defeat the whole point — the read drain parks
            until BYTES ARRIVE (read-readiness), nothing else.
          * True (the WRITE / upload drain, when a slot is mid-send):
            EPOLLIN | EPOLLOUT. The PUT send+head path can be waiting on
            the kernel send buffer to drain (write-readiness) OR on the
            response head (read-readiness); arming both wakes promptly on
            either instead of waiting out the timeout.

        Transiently registers each fd (>= 0) for the chosen interest, runs
        ONE epoll_wait, then deregisters each fd it added. Returns the
        number of ready events (0 on timeout). Does NOT mutate `_wakers`
        or fire `_sink` — this is an isolated I/O park, orthogonal to the
        worker's task-completion routing.

        fds with value < 0 (conformers with no pollable kernel fd, e.g.
        ScriptedStream) are skipped: they are not registered and do not
        contribute to the park. If EVERY fd is < 0, this returns
        immediately with 0 (caller falls back to spin — byte-for-byte the
        prior behavior for those conformers).

        Linux-only park; on the mock / non-epoll backend (`_epoll_fd < 0`)
        it yields ~10µs via nanosleep (same fair-scheduling intent as
        run_once's mock branch) and returns 0, so the caller's spin loop
        does not pin a core under test fixtures.
        """
        if self._epoll_fd < 0:
            # Mock / uninitialized backend — no epoll fd to park on. Yield
            # ~10µs so the caller's drain loop doesn't busy-pin under the
            # test fixture (mirrors run_once's mock-park branch).
            var ts_sec: Int64 = 0
            var ts_nsec: Int64 = 10_000  # 10 microseconds
            var ts = SIMD[DType.int64, 2](ts_sec, ts_nsec)
            _ = external_call["nanosleep", Int32](
                UnsafePointer(to=ts).bitcast[UInt8](),
                # SAFETY: arg1 points at
                # stack-local `ts` (lives across the call); arg2 (`rem`
                # out-param) is NULL — we don't restart on EINTR and don't
                # need the remaining time, libc tolerates NULL here.
                _null_ptr[UInt8, MutUntrackedOrigin](),
            )
            return 0

        # --- Register every pollable fd transiently. We use a sentinel
        # cookie (OP_ID_IO_PARK) for the data field so a stray event here
        # is never mis-decoded as a _wakers op_id by a concurrent run_once
        # (there is none — per-pthread reactor, single drain in flight —
        # but the distinct cookie keeps the contract explicit). We track
        # which fds we actually added so deregister is exact + best-effort.
        var registered = List[Int32]()
        var epoll_interest = EPOLLIN
        if want_write:
            epoll_interest = EPOLLIN | EPOLLOUT
        var k = len(fds)
        var i = 0
        while i < k:
            var fd = fds[i]
            if fd >= Int32(0):
                comptime if CompilationTarget.is_macos():
                    # On Mac, _epoll_fd repurposed as kq_fd; register an
                    # EVFILT_READ (+ EVFILT_WRITE when want_write) with the
                    # park sentinel udata.
                    try:
                        kevent_register(
                            self._epoll_fd, fd, EVFILT_READ,
                            UInt64(OP_ID_IO_PARK), edge_triggered=False,
                        )
                        if want_write:
                            kevent_register(
                                self._epoll_fd, fd, EVFILT_WRITE,
                                UInt64(OP_ID_IO_PARK), edge_triggered=False,
                            )
                        registered.append(fd)
                    except:
                        # Already registered or transient failure — skip;
                        # park still proceeds on the others.
                        pass
                else:
                    try:
                        # EPOLLIN (read drain: park until bytes arrive) or
                        # EPOLLIN|EPOLLOUT (write drain: also wake on send-
                        # buffer-drained). Level-triggered, so a fd already
                        # ready for the armed interest at ADD time returns
                        # epoll_wait immediately (lost-wakeup-safe).
                        epoll_ctl_add(
                            self._epoll_fd, fd, epoll_interest,
                            UInt64(OP_ID_IO_PARK),
                        )
                        registered.append(fd)
                    except:
                        # EEXIST (fd already in the set) or transient
                        # failure — skip adding it; we will NOT deregister
                        # an fd we did not add. Park proceeds on the rest.
                        pass
            i = i + 1

        if len(registered) == 0:
            # No pollable fd was registered (all -1, or all already-in-set).
            # Yield ~10µs to avoid a hot caller spin and return — the caller
            # re-polls.
            var ts_sec2: Int64 = 0
            var ts_nsec2: Int64 = 10_000
            var ts2 = SIMD[DType.int64, 2](ts_sec2, ts_nsec2)
            _ = external_call["nanosleep", Int32](
                UnsafePointer(to=ts2).bitcast[UInt8](),
                # SAFETY: arg1 points at
                # stack-local `ts2` (lives across the call); arg2 (`rem`
                # out-param) is NULL — we don't restart on EINTR and don't
                # need the remaining time, libc tolerates NULL here.
                _null_ptr[UInt8, MutUntrackedOrigin](),
            )
            return 0

        # --- One epoll_wait. LEVEL-TRIGGERED EPOLLIN: if any fd is already
        # readable at ADD time the kernel reports it now, so a byte that
        # arrived between the caller's last WouldBlock and this register is
        # observed (no lost wakeup). We do NOT route events into _wakers or
        # _sink — the caller's own non-blocking re-poll after we return is
        # the source of truth for which stream advanced.
        var ready: Int
        comptime if CompilationTarget.is_macos():
            var kevents = List[KEvent]()
            ready = kevent_wait_decode(
                self._epoll_fd, kevents, Int64(timeout_us),
            )
        else:
            var timeout_ms: Int32
            if timeout_us < Int32(0):
                timeout_ms = Int32(-1)
            elif timeout_us == Int32(0):
                timeout_ms = Int32(0)
            else:
                timeout_ms = (timeout_us + Int32(999)) // Int32(1000)
            var events = List[EpollEvent]()
            ready = epoll_wait_decode(self._epoll_fd, events, timeout_ms)

        # --- Deregister exactly the fds we added (best-effort; ENOENT
        # benign). Leaving a transient fd in the set would let a later
        # run_once mis-handle it, and would also leak interest after the
        # stream's fd is closed/reused.
        var j = 0
        var rn = len(registered)
        while j < rn:
            var rfd = registered[j]
            comptime if CompilationTarget.is_macos():
                kevent_deregister(self._epoll_fd, rfd, EVFILT_READ)
                if want_write:
                    kevent_deregister(self._epoll_fd, rfd, EVFILT_WRITE)
            else:
                try:
                    epoll_ctl_del(self._epoll_fd, rfd)
                except:
                    pass
            j = j + 1

        return ready

    # =========================================================================
    # NIC-style completion-queue API.
    #
    # Five methods complement the per-call register_read / run_once / is_ready
    # surface. The per-call methods (above) remain for
    # the Worker.run_one_iteration path; run_once
    # delegates to
    # poll_completions.
    # =========================================================================

    def submit(
        mut self,
        op_kind: UInt8,
        fd: Int32,
        buf: Span[UInt8, _],
    ) raises -> OpHandle:
        """Try_io fast path then EWOULDBLOCK fallback.

        Two paths:
          1. **Fast path**: try the syscall directly with MSG_DONTWAIT.
             On success, return a Ready OpHandle with `_result = bytes`.
             Zero multiplexer touches.
          2. **Slow path**: on EAGAIN/EWOULDBLOCK, register interest with
             the multiplexer (per-IO ADD; long-lived MOD is separate)
             and return a Pending OpHandle. Caller parks via
             `poll_completions` until the matching op_id arrives.

        On non-recoverable error (ECONNRESET, EBADF, etc.): return an Err
        OpHandle with `_result = errno`; caller raises.

        OP_CONNECT / OP_ACCEPT: no inline fast path; the body
        falls through to the slow-path register (via register_read for
        ACCEPT — listener fd readability — and via register_write for
        CONNECT — outbound writability per nonblocking-connect semantics).
        A higher layer provides
        the full ACCEPT/CONNECT shape via `accept_async` / `connect_async`
        awaitables.

        OP_TIMER: not supported here (timers go through `register_timer`).
        """
        var op_id = self.alloc_op_id()

        # The try_io fast path lives in
        # standalone fns in socket_io.mojo. submit() calls try_io_read /
        # try_io_write and dispatches the four-state result. Other call
        # sites (TcpStream / awaitables) use the standalone fns directly
        # without going through submit's op-id allocator.
        if op_kind == OP_READ:
            var r = try_io_read(fd, buf)
            if r.is_ready():
                return OpHandle(
                    _op_id=op_id, _state=OP_READY, _result=r.value(),
                )
            if r.is_error():
                return OpHandle(
                    _op_id=op_id, _state=OP_ERR, _result=r.value(),
                )
            # WouldBlock — register interest + park.
            self.register_read(fd, op_id, UInt16(0))
            return OpHandle(
                _op_id=op_id, _state=OP_PENDING, _result=Int64(0),
            )
        elif op_kind == OP_WRITE:
            var r = try_io_write(fd, buf)
            if r.is_ready():
                return OpHandle(
                    _op_id=op_id, _state=OP_READY, _result=r.value(),
                )
            if r.is_error():
                return OpHandle(
                    _op_id=op_id, _state=OP_ERR, _result=r.value(),
                )
            self.register_write(fd, op_id, UInt16(0))
            return OpHandle(
                _op_id=op_id, _state=OP_PENDING, _result=Int64(0),
            )
        elif op_kind == OP_ACCEPT:
            # Listener fd readability is the trigger; register and park
            # (accept4 runs on the resume path).
            self.register_read(fd, op_id, UInt16(0))
            return OpHandle(
                _op_id=op_id, _state=OP_PENDING, _result=Int64(0),
            )
        elif op_kind == OP_CONNECT:
            # Outbound writability is the trigger for nonblocking connect.
            self.register_write(fd, op_id, UInt16(0))
            return OpHandle(
                _op_id=op_id, _state=OP_PENDING, _result=Int64(0),
            )
        else:
            # OP_TIMER and unknowns.
            raise Error("Reactor.submit: unsupported op_kind")

    def register_long_lived(
        mut self,
        fd: Int32,
        interest_set: UInt8,
    ) raises -> RegistrationHandle:
        """Register an fd for the lifetime of a TcpStream
        (or equivalent long-lived consumer). Replaces per-IO
        register/deregister.

        On epoll: one EPOLL_CTL_ADD with EPOLLIN | EPOLLOUT | EPOLLET
        based on the interest_set bitmask.
        On kqueue: one or two `kevent_register` calls (one per filter),
        edge-triggered via EV_CLEAR (the kqueue analog of EPOLLET).

        Returns a RegistrationHandle whose drop calls
        `_deregister_long_lived(fd)`.

        Edge-triggered (EPOLLET / EV_CLEAR) is set because the
        long-lived path is paired with try_io's drain-to-EAGAIN
        discipline.

        Mac branch added.
        Pre-fix this hardcoded `epoll_ctl_add` and raised "Linux only"
        on Mac BACKEND_KQUEUE workers; every per-core HTTP server worker
        thread crashed at boot with a Linux-only error before serving
        a single byte. Mirrors the per-IO `register_read` / `register_write`
        pattern at / 378.
        """
        if self._epoll_fd < 0:
            # Mock backend or wrong-OS: no multiplexer to touch. Return
            # a synthetic handle (drop is a no-op).
            return RegistrationHandle(_fd=fd, _interest_set=interest_set)

        comptime if CompilationTarget.is_macos():
            # kqueue: per-filter EV_ADD with EV_CLEAR (edge-triggered).
            # The cookie is the fd itself, mirroring the epoll branch.
            if (interest_set & INTEREST_READ) != UInt8(0):
                kevent_register(
                    self._epoll_fd, fd, EVFILT_READ, UInt64(fd),
                    edge_triggered=True,
                )
            if (interest_set & INTEREST_WRITE) != UInt8(0):
                kevent_register(
                    self._epoll_fd, fd, EVFILT_WRITE, UInt64(fd),
                    edge_triggered=True,
                )
            return RegistrationHandle(_fd=fd, _interest_set=interest_set)
        else:
            # Build the epoll events bitmask from the interest set.
            var events = UInt32(0)
            if (interest_set & INTEREST_READ) != UInt8(0):
                events = events | EPOLLIN
            if (interest_set & INTEREST_WRITE) != UInt8(0):
                events = events | EPOLLOUT
            # EPOLLET: paired with try_io fast path drain-to-EAGAIN per
            # Long-lived registrations always use edge-triggered.
            events = events | EPOLLET

            # Use the fd itself as the cookie — for long-lived registrations,
            # the per-IO op_id mapping happens at submit time via
            # _register_for_ready_cache. The cookie carried in the kernel
            # event is the fd; a per-registration token is a possible refinement.
            epoll_ctl_add(self._epoll_fd, fd, events, UInt64(fd))
            return RegistrationHandle(_fd=fd, _interest_set=interest_set)

    def modify(
        mut self,
        reg_handle: RegistrationHandle,
        new_interest_set: UInt8,
    ) raises:
        """Switch the interest set of a long-lived
        registration.

        On epoll: one EPOLL_CTL_MOD with the new EPOLLIN/EPOLLOUT bitmask.
        On kqueue: per-filter add/delete delta against the prior interest
        set. epoll's atomic interest-set swap doesn't have a one-shot
        kqueue analog; the equivalent is the change-set of (filter,
        op) pairs:
          - filter present in BOTH old AND new: re-register with EV_ADD
            (EV_ADD on an already-registered (fd, filter) updates flags,
            the kqueue idiomatic in-place modify); cheaper than del+add.
          - filter present ONLY in old: EV_DELETE (`kevent_deregister`).
          - filter present ONLY in new: EV_ADD (`kevent_register`).

        If `new_interest_set == reg_handle.interest_set()`, this is a
        no-op (avoids the syscall when the caller's IO doesn't change
        interest direction).

        Mac branch added.
        Pre-fix this hardcoded `epoll_ctl_mod` and raised "Linux only"
        on Mac BACKEND_KQUEUE workers when an HTTP TcpStream's interest
        set flipped between read-only and read+write. Mirrors the
        per-IO `register_read` / `register_write` / `deregister`
        pattern at / 378 / 405.

        kqueue note: the kernel docs (`man kevent`) explicitly state
        that EV_ADD is idempotent on (ident, filter) and updates the
        existing registration in-place. We use that to avoid a
        delete-then-add window where an event fired between the two
        kevents would be lost. delete+add is only used for filters
        being entirely dropped from the interest set.
        """
        if reg_handle.interest_set() == new_interest_set:
            return  # No-op fast path: nothing changed.
        if self._epoll_fd < 0:
            return  # Mock backend: no multiplexer.

        comptime if CompilationTarget.is_macos():
            var fd = reg_handle.fd()
            var old_set = reg_handle.interest_set()
            var old_read = (old_set & INTEREST_READ) != UInt8(0)
            var old_write = (old_set & INTEREST_WRITE) != UInt8(0)
            var new_read = (new_interest_set & INTEREST_READ) != UInt8(0)
            var new_write = (new_interest_set & INTEREST_WRITE) != UInt8(0)

            # READ filter delta.
            if new_read:
                # Add OR re-arm. EV_ADD is idempotent for in-place modify
                # on kqueue (man kevent: "Adding an event which is
                # already attached to the kqueue replaces the existing
                # event"). Edge-triggered for parity with epoll EPOLLET.
                kevent_register(
                    self._epoll_fd, fd, EVFILT_READ, UInt64(fd),
                    edge_triggered=True,
                )
            elif old_read:
                # READ was set, now dropped. Best-effort delete.
                kevent_deregister(self._epoll_fd, fd, EVFILT_READ)

            # WRITE filter delta.
            if new_write:
                kevent_register(
                    self._epoll_fd, fd, EVFILT_WRITE, UInt64(fd),
                    edge_triggered=True,
                )
            elif old_write:
                kevent_deregister(self._epoll_fd, fd, EVFILT_WRITE)
        else:
            var events = UInt32(0)
            if (new_interest_set & INTEREST_READ) != UInt8(0):
                events = events | EPOLLIN
            if (new_interest_set & INTEREST_WRITE) != UInt8(0):
                events = events | EPOLLOUT
            events = events | EPOLLET
            epoll_ctl_mod(
                self._epoll_fd, reg_handle.fd(), events,
                UInt64(reg_handle.fd()),
            )

    def _deregister_long_lived(mut self, fd: Int32):
        """Remove a long-lived registration from the multiplexer.
        Called by the RegistrationHandle.__del__ body.

        Best-effort: ENOENT is benign. epoll_ctl_del swallows internally
        per the existing waker-slot contract.

        Mac branch added.
        kqueue's `EV_DELETE` is per-(fd, filter); epoll's
        `EPOLL_CTL_DEL` is per-fd. Without knowledge of which filters
        were registered (the long-lived path doesn't track it on
        Reactor), call `kevent_deregister` for both EVFILT_READ and
        EVFILT_WRITE; both are best-effort (kevent_deregister already
        swallows errors internally — no `try` needed).
        """
        if self._epoll_fd < 0 or fd < 0:
            return
        comptime if CompilationTarget.is_macos():
            # Best-effort per-filter delete. kevent_deregister itself
            # is best-effort (no raise on ENOENT) so an unregistered
            # filter is benign — equivalent to epoll's "EPOLL_CTL_DEL
            # raises ENOENT but we swallow" pattern below.
            kevent_deregister(self._epoll_fd, fd, EVFILT_READ)
            kevent_deregister(self._epoll_fd, fd, EVFILT_WRITE)
        else:
            try:
                epoll_ctl_del(self._epoll_fd, fd)
            except:
                pass

    def poll_completions(
        mut self, timeout_us: Int32,
    ) raises -> List[Completion]:
        """Block on the multiplexer until at least one completion
        arrives or `timeout_us` elapses; return the list of decoded
        Completions.

        Wake-channel completions (eventfd_write / EVFILT_USER) are decoded
        internally and consumed (eventfd drained) — they do NOT appear in
        the returned list per docstring. They cause the syscall to
        return early with whatever non-wake completions also arrived.

        For each non-wake completion, this body ALSO marks the matching
        WakerSlot.ready=True in the existing `_wakers` table (if the
        op_id is in the per-IO submit table), so existing readiness-polling callers
        (Worker.run_one_iteration via IoSubsystem.run_once / Reactor.is_ready)
        observe the readiness on their next park-loop iteration. This dual
        bookkeeping keeps both paths observing the same body.

        Builds Completion records from the decoded epoll events. The returned
        list does NOT include the wake-channel event (drained internally).
        The worker loop walks the list and dispatches via `_pending_coros` /
        `_ready_cache`; tests inspect the list directly.

        buffer drain. Any completions stashed in
        `_pending_completions` by a prior `try_pop_any_completion` call
        (non-matches that the bulk-parallel pattern parked on a different
        op_id set) are PREPENDED to the returned list. They are drained
        in arrival order; subsequent epoll_wait events are appended after
        them. This keeps the existing `Worker.run_one_iteration` /
        `run_until_shutdown` loop semantics unchanged: every completion
        eventually gets dispatched, regardless of whether it transited
        the pending buffer.
        """
        var out = List[Completion]()
        # First — drain any completions stashed by prior try_pop_any_completion
        # calls. These are non-matches that we held back to avoid losing them
        # while letting try_pop_any_completion return only matches.
        var n_pending = len(self._pending_completions)
        for i in range(n_pending):
            out.append(self._pending_completions[i])
        # Best-effort: clear the buffer. List.clear is the canonical primitive;
        # if it isn't available on this stdlib version we fall back to
        # re-assigning. We use the re-assign for forward portability.
        self._pending_completions = List[Completion]()
        if self._epoll_fd < 0:
            # Mock / uninitialized: nothing to drive. Mirror run_once's
            # H1-fix nanosleep on the "block forever" intent so a worker
            # that calls poll_completions(-1) under MOCK doesn't tightly
            # busy-spin (matches the run_once contract).
            if timeout_us < Int32(0):
                var ts_sec: Int64 = 0
                var ts_nsec: Int64 = 10_000  # 10us
                var ts = SIMD[DType.int64, 2](ts_sec, ts_nsec)
                _ = external_call["nanosleep", Int32](
                    UnsafePointer(to=ts).bitcast[UInt8](),
                    # SAFETY: arg1 points at
                    # stack-local `ts` (lives across the call); arg2 (`rem`
                    # out-param) is NULL — we don't restart on EINTR and don't
                    # need the remaining time, libc tolerates NULL here.
                    _null_ptr[UInt8, MutUntrackedOrigin](),
                )
            return out^

        # branch on platform. See run_once's
        # platform-branch comment for the rationale.
        comptime if CompilationTarget.is_macos():
            var kevents = List[KEvent]()
            var n = kevent_wait_decode(
                self._epoll_fd, kevents, Int64(timeout_us),
            )
            for i in range(n):
                var ev = kevents[i]
                var op_id = Int64(ev.udata)
                if op_id == OP_ID_WAKE_USER:
                    # Wake-channel: EVFILT_USER auto-clears via EV_CLEAR;
                    # no drain required.
                    continue
                # Decode error / hangup bits (kqueue analogues of EPOLL*).
                var err_code: Int32 = Int32(0)
                var hangup = (ev.flags & EV_EOF) != UInt16(0)
                if (ev.flags & EV_ERROR) != UInt16(0):
                    # ev.data carries the errno on EV_ERROR.
                    err_code = Int32(ev.data) if ev.data != Int64(0) else Int32(-1)
                out.append(Completion(
                    op_id=op_id, bytes=Int64(0),
                    err_code=err_code, hangup=hangup,
                ))
                var idx = self._find_slot_idx(op_id)
                if idx >= 0:
                    self._wakers[idx].ready = True
                    try:
                        self._sink.wake(op_id)
                    except:
                        pass
            return out^
        else:
            # Convert microseconds to milliseconds (epoll_wait takes ms).
            var timeout_ms: Int32
            if timeout_us < Int32(0):
                timeout_ms = Int32(-1)
            elif timeout_us == Int32(0):
                timeout_ms = Int32(0)
            else:
                timeout_ms = (timeout_us + Int32(999)) // Int32(1000)

            var events = List[EpollEvent]()
            var n = epoll_wait_decode(self._epoll_fd, events, timeout_ms)
            for i in range(n):
                var ev = events[i]
                var op_id = Int64(ev.data)
                if op_id == OP_ID_WAKE_EVENTFD:
                    # Wake-channel: drain + skip.
                    drain_eventfd(self._wake_eventfd)
                    continue

                # Decode error / hangup bits.
                var err_code: Int32 = Int32(0)
                var hangup = (ev.events & EPOLLHUP) != UInt32(0)
                if (ev.events & EPOLLERR) != UInt32(0):
                    # We don't have per-fd errno without an extra getsockopt
                    # call; record EPOLLERR sentinel as -1 so callers can
                    # distinguish from success+hangup.
                    err_code = Int32(-1)

                # Build the Completion record. `bytes=0` here — the record
                # only carries the readiness signal; the actual
                # byte count is resolved by the IoOp/Awaitable wrapper
                # layer.
                out.append(Completion(
                    op_id=op_id, bytes=Int64(0),
                    err_code=err_code, hangup=hangup,
                ))

                # Backward-compat: also mark the matching WakerSlot
                # ready so existing run_once / is_ready paths observe
                # the event.
                var idx = self._find_slot_idx(op_id)
                if idx >= 0:
                    # 3: drain a MODE_TIMER timerfd (level-
                    # triggered EPOLLIN) so it does not re-fire on the next
                    # poll. Mirrors run_once.
                    if self._wakers[idx].mode == MODE_TIMER:
                        drain_timerfd(self._wakers[idx].fd)
                    self._wakers[idx].ready = True
                    # Fire the sink (best-effort; sink failure shouldn't
                    # poison reactor state). Mirrors run_once.
                    try:
                        self._sink.wake(op_id)
                    except:
                        pass
            return out^

    def try_pop_any_completion(
        mut self, op_ids: List[Int64],
    ) raises -> Optional[Completion]:
        """Bulk-parallel substrate primitive.
        Non-blocking poll: if ANY op_id in `op_ids` has a completion ready,
        consume it from the reactor's completion stream and return it;
        otherwise return None.

        Behavior:
          1. Run a single non-blocking epoll_wait(0) (or drain the pending
             buffer if it already holds completions from a prior call).
          2. For each completion observed:
             - If `op_id in op_ids`: return Some(completion). Any later
               completions in this batch are stashed into
               `_pending_completions` so they're not lost — the next
               `poll_completions` (or `try_pop_any_completion`) call drains
               them in arrival order.
             - Otherwise: stash into `_pending_completions`.
          3. Returns None if no in-flight completion matches any id in
             `op_ids` AND no pending buffer entry matches.

        Cost model:
          * O(N + M) where N = completions seen this call, M = len(op_ids).
            Both are typically <100 (per-worker in-flight depth bound).
            For the depth=1 sugar `try_io`, M=1 and the inner loop is
            single-iteration.
          * Linear scan; no indexed lookup. Optimized for the small-N case
            documented (worst case <100 in-flight per
            worker). If the bench gate later shows this hot, swap in a
            Dict[Int64, Int] op_id-to-buffer-idx map.

        Wake-channel events (eventfd) are drained internally and never
        returned (mirrors `poll_completions`'s contract).

        SAFETY: `op_ids` is taken by VALUE (Int64 List is Copyable so the
        caller can share); the reactor doesn't retain it. No
        UnsafePointer / wildcard origin in the public signature.
        """
        # walk the existing pending buffer for an early match.
        # This is the fast path when a prior `try_pop_any_completion`
        # stashed a non-match that this call's op_id set DOES match.
        var n_pending = len(self._pending_completions)
        for i in range(n_pending):
            var c = self._pending_completions[i]
            if _op_id_in_list(c.op_id, op_ids):
                # Match — extract this entry, shift the tail down.
                var matched = c
                for j in range(i, n_pending - 1):
                    self._pending_completions[j] = self._pending_completions[j + 1]
                _ = self._pending_completions.pop()
                return Optional[Completion](matched)

        # no buffer match. Run a non-blocking epoll_wait(0) to
        # surface any newly-ready completions. We can't reuse
        # `poll_completions` here because that would drain the existing
        # buffer (which we just walked) and could return non-matches as
        # the head element — destroying the "pop only matches" invariant.
        if self._epoll_fd < 0:
            # Mock / uninitialized: no kernel multiplexer to poll. Return
            # None — caller's spin loop will pause + retry.
            return Optional[Completion]()

        var matched_completion: Optional[Completion] = Optional[Completion]()
        # branch on platform.
        comptime if CompilationTarget.is_macos():
            var kevents = List[KEvent]()
            var n = kevent_wait_decode(
                self._epoll_fd, kevents, Int64(0),  # non-blocking
            )
            for i in range(n):
                var ev = kevents[i]
                var op_id = Int64(ev.udata)
                if op_id == OP_ID_WAKE_USER:
                    # EVFILT_USER auto-clears via EV_CLEAR; no drain.
                    continue
                var err_code: Int32 = Int32(0)
                var hangup = (ev.flags & EV_EOF) != UInt16(0)
                if (ev.flags & EV_ERROR) != UInt16(0):
                    err_code = Int32(ev.data) if ev.data != Int64(0) else Int32(-1)
                var c = Completion(
                    op_id=op_id, bytes=Int64(0),
                    err_code=err_code, hangup=hangup,
                )
                var idx = self._find_slot_idx(op_id)
                if idx >= 0:
                    self._wakers[idx].ready = True
                    try:
                        self._sink.wake(op_id)
                    except:
                        pass
                if not matched_completion.__bool__() and _op_id_in_list(op_id, op_ids):
                    matched_completion = Optional[Completion](c)
                else:
                    self._pending_completions.append(c)
        else:
            var events = List[EpollEvent]()
            var n = epoll_wait_decode(self._epoll_fd, events, Int32(0))
            for i in range(n):
                var ev = events[i]
                var op_id = Int64(ev.data)
                if op_id == OP_ID_WAKE_EVENTFD:
                    # Wake-channel: drain + skip.
                    drain_eventfd(self._wake_eventfd)
                    continue

                # Decode error / hangup bits (same as poll_completions).
                var err_code: Int32 = Int32(0)
                var hangup = (ev.events & EPOLLHUP) != UInt32(0)
                if (ev.events & EPOLLERR) != UInt32(0):
                    err_code = Int32(-1)

                var c = Completion(
                    op_id=op_id, bytes=Int64(0),
                    err_code=err_code, hangup=hangup,
                )

                # Mirror the WakerSlot bookkeeping for this op_id
                # (existing poll_completions does the same; keeping
                # is_ready / sink-fire paths observe events even when
                # try_pop_any_completion is the one that drained them).
                var idx = self._find_slot_idx(op_id)
                if idx >= 0:
                    self._wakers[idx].ready = True
                    try:
                        self._sink.wake(op_id)
                    except:
                        pass

                # Match against op_ids. The FIRST match wins; later
                # matches (or non-matches) get buffered.
                if not matched_completion.__bool__() and _op_id_in_list(op_id, op_ids):
                    matched_completion = Optional[Completion](c)
                else:
                    self._pending_completions.append(c)

        return matched_completion^

    @always_inline
    def wake_handle(self) -> WorkerWakeHandle:
        """Wake handle for cross-thread producer wake.

        Returns a WorkerWakeHandle holding the per-platform wake target
        (or -1 sentinel on MOCK backend, in which case wake() is a
        no-op). Called once at attach time; the handle is cloned into
        producer-side slabs.

        Backend dispatch:
          - Linux (BACKEND_EPOLL): wake_fd=self._wake_eventfd (the
            eventfd registered with the epoll set under
            OP_ID_WAKE_EVENTFD). ident is unused.
          - macOS (BACKEND_KQUEUE): wake_fd=self._epoll_fd (the kq_fd;
            field repurposed per `__init__`'s comment). ident=
            UInt64(self._wake_eventfd) (the EVFILT_USER ident, which
            we set to 0 at construction). Pre-fix, this factory passed
            `wake_fd=self._wake_eventfd` (which on Mac is the ident, NOT
            an fd) and `ident=UInt64(0)` (hardcoded). The producer-side
            `WorkerWakeHandle.wake()` would then call
            `kevent_user_wake(0, 0)` → kernel returns EBADF on the bogus
            fd → silent no-op → every cross-thread producer wake LOST.
          - MOCK / sentinel: both branches return -1 / 0 sentinels;
            wake() is a no-op anyway.

        The handle now carries a typed
        ArcPointer<_SleepingFlag> instead of the BANNED `_sleeping_addr:
        Int` Int-laundered shape. The Reactor doesn't own the worker's
        sleeping flag, so this factory installs a "disconnected" handle
        with a dummy sleeping arc (always reports awake=0 → all elision
        elides the wake — safe for a Reactor-only handle that has no
        worker behind it). `Worker.wake_handle()` splices in the real
        Worker-owned sleeping arc via `WorkerWakeHandle.from_parts(...)`.
        """
        comptime if CompilationTarget.is_macos():
            return WorkerWakeHandle.make_disconnected(
                wake_fd=self._epoll_fd,                  # kq_fd
                ident=UInt64(self._wake_eventfd),        # EVFILT_USER ident
            )
        else:
            return WorkerWakeHandle.make_disconnected(
                wake_fd=self._wake_eventfd,
                ident=UInt64(0),                         # unused on Linux
            )

    def wake_self(self):
        """Public method that does the cross-thread
        wake internally. Used by Worker.signal_shutdown to unblock
        epoll_wait(-1) on its own thread, and by the self-wake fallback
 (post-saturated-drain belt-and-suspenders).

        Best-effort: EBADF/EAGAIN silently ignored.
        `read self` (no mutable state).

        Backend dispatch:
          - Linux (BACKEND_EPOLL): write_eventfd(self._wake_eventfd) —
            the eventfd is registered with the epoll set under
            OP_ID_WAKE_EVENTFD and will fire on the next epoll_wait.
          - macOS (BACKEND_KQUEUE): kevent_user_wake(self._epoll_fd,
            UInt64(self._wake_eventfd)) — `_epoll_fd` is repurposed as
            the kq_fd (see `__init__`); `_wake_eventfd` is repurposed
            as the EVFILT_USER ident (registered at construction).
            pre-fix this branch wrote to
            `write_eventfd(self._wake_eventfd)` — on Mac that's
            `write_eventfd(0)` which is a no-op (the function is
            `@parameter if is_linux()` guarded), so a parked Worker
            on `kevent` would never be woken by `signal_shutdown` →
            test driver hangs at RAII teardown.
          - MOCK / sentinel: both branches no-op when fd < 0.

        No raises: the wake surface does not raise; if the fd is the
        -1 sentinel (MOCK backend), the underlying helpers no-op.
        """
        comptime if CompilationTarget.is_macos():
            # `_wake_eventfd` carries the EVFILT_USER ident on darwin;
            # `_epoll_fd` carries the kq_fd. The kqueue free-fn already
            # guards on `kq_fd < 0` (sentinel returns silently).
            kevent_user_wake(self._epoll_fd, UInt64(self._wake_eventfd))
        else:
            write_eventfd(self._wake_eventfd)

    def is_ready(self, op_id: Int64) -> Bool:
        """Predicate: has the reactor seen this
        op's readiness on a prior run_once call?"""
        var idx = self._find_slot_idx(op_id)
        if idx < 0:
            return False
        return self._wakers[idx].ready

    def epoll_fd(self) -> Int32:
        """Underlying epoll fd. Internal-to-this-module accessor (e.g., for
        FdWaker to attach an eventfd or for tests to inspect). Typed-scalar
        return preserves the encapsulation rule.
        """
        return self._epoll_fd

    # ---- demux sub-linearity instruments ----

    def probe_find_slot_idx(mut self, op_id: Int64) -> Int:
        """Like `_find_slot_idx` but counts the map probe steps into the internal
        instrument (drained via `probe_steps`). The sub-linearity scaling test
        drives N demux lookups through this and asserts the total probe count
        stays O(N), not O(N^2). Production uses the un-instrumented path."""
        return self._slot_index.probe_lookup(op_id)

    def reset_probe_counter(mut self):
        """Zero the slot-index map's cumulative probe counter (test instrument)."""
        self._slot_index.reset_probe_counter()

    def probe_steps(self) -> Int:
        """Cumulative slot-index probe steps since construction / last reset
        (test instrument)."""
        return self._slot_index.probe_steps()


# -----------------------------------------------------------------------------
# IoSubsystem[S] — Reactor-owning wrapper..
# -----------------------------------------------------------------------------


struct IoSubsystem[S: WakerSink & Movable & Deinitable](
    Movable, Deinitable
):
    """Owns a Reactor[S]. Constructed once
    per WORKER (not per-session). Each pinned worker owns its
    own IoSubsystem; no cross-thread access to the reactor — the worker
    thread that runs worker_main is the only thread that touches its
    reactor.

    Lives in `komira_async` (NOT `komira_engine_runtime`) so that
    standalone consumers can construct one without depending on engine
    internals.

    NOT Movable — Reactor[S] holds Atomic state.

    3 field set:
      var _reactor: Reactor[Self.S]
    """

    var _reactor: Reactor[Self.S]

    def __init__(out self, var sink: Self.S, backend: UInt8) raises:
        """"""
        self._reactor = Reactor[Self.S](sink^, backend)

    def alloc_op_id(mut self) -> Int64:
        """"""
        return self._reactor.alloc_op_id()

    def run_once(mut self, timeout_us: Int32) raises -> Int:
        """"""
        return self._reactor.run_once(timeout_us)

    def register_timer(mut self, deadline_ns: Int64) raises -> Int64:
        """Forward to Reactor.register_timer. Returns a
        biased, parkable op_id that resumes the parked frame on the deadline,
        routed identically to a register_read completion."""
        return self._reactor.register_timer(deadline_ns)

    def reactor(mut self) -> ref [self._reactor] Reactor[Self.S]:
        """Worker accesses the reactor exclusively via this
        accessor; Reactor[S] is owned by IoSubsystem[S], not by Worker.

        A ref-return through an inner field
        must be `ref [self._reactor]`, NOT `ref [self]` — the latter fails
        to type-check on Mojo 0.26.3.
        """
        return self._reactor

    @always_inline
    def wake_handle(self) -> WorkerWakeHandle:
        """Forward to Reactor.wake_handle(). POD return."""
        return self._reactor.wake_handle()

    def wake_self(self):
        """Forward to Reactor.wake_self(). Best-effort."""
        self._reactor.wake_self()

    def try_pop_any_completion(
        mut self, op_ids: List[Int64],
    ) raises -> Optional[Completion]:
        """Forward to Reactor.try_pop_any_completion. Bulk-parallel
        primitive. Non-blocking poll for any
        of the supplied op_ids; returns the first match or None."""
        return self._reactor.try_pop_any_completion(op_ids)
