# =============================================================================
# komira_async.runtime.worker — Worker[S] per-pinned-thread state
# =============================================================================
# per-worker state (one Worker per pinned
# thread).
#
# Each Worker owns its `_stall_detector: ReactorStallDetector` (per-worker watchdog,
# owns its `_stall_detector: ReactorStallDetector` (per-worker watchdog,
# 20ms threshold) and `_imbalance_metrics: HotShardMetrics` (per-worker
# work-completed counter for hot-shard CV alerting).
#
# Per-worker task queue.
#   Each Worker now owns a `_task_queue: MpscReceiver[_TaskEntry]`.
#   `run_one_iteration` drains up to `MAX_DRAIN_PER_ITER` (16) entries from
#   the queue BEFORE calling `_io_subsystem.run_once`. The 16-entry bound
#   matches Seastar's cross-shard SPSC queues, which batch 16 at a time.
#
#   MPSC vs SPSC: the architecture uses MPSC because two distinct producers
#   (LocalDispatcher and LocalSpawner) push to the same per-worker queue.
#   The dispatch impl plan / spec calls for SPSC; using MPSC instead is the
#   safer choice (correctness without external mutual exclusion between
#   dispatcher + spawner producer threads). The MPSC implementation is
#   Vyukov-MPMC and offers similar lock-free hot-path throughput.
#
# There is no separate `_task_wake` field: the producer wake mechanism is
# the per-worker eventfd inside the Reactor (the
# `WorkerWakeHandle.wake()` POD primitive). A plain wake-word with
# no consumer-side park would only duplicate HotShardMetrics.work_completed.
#
# Field set (with eventfd spin-park and typed wake
# elision):
#   var _worker_id: UInt16
#   var _io_subsystem: IoSubsystem[Self.S]                  (Movable)
#   var _shutdown_flag: OwnedPointer[Atomic[DType.int32]]   (heap-stable)
#   var _stall_detector: ReactorStallDetector
#   var _imbalance_metrics: HotShardMetrics
#   var _iter_count: UInt64                                 (Class G; task-id)
#   var _task_queue: MpscReceiver[_TaskEntry]
#   var _ready_cache: OwnedPointer[Slab[OpHandle]]          (state-machine track)
#   var _sleeping_arc: ArcPointer[_SleepingFlag]
#
# Worker[S] IS Movable. ReactorStallDetector, HotShardMetrics, and
# MpscReceiver are all Movable, so the field set preserves Movable.
# ArcPointer requires `T: Movable`; _SleepingFlag is Movable (its single
# OwnedPointer field is a POD 8-byte handle).
#
# Completion dispatch: EVERY completion routes to the state-machine
# ready-cache (there is one completion table, so op_id partitioning is
# vacuous).
#
# Typed wake elision:
#   - `_sleeping_arc: ArcPointer<_SleepingFlag>` (typed, refcount-tracked)
#     holds the sleeping flag; there is no Int-laundered address field.
#   - The Worker holds the "primary" arc; producers receive clones via
#     `wake_handle()`. The `_SleepingFlag` survives until the last clone
#     drops, so Worker-outlives-producer is not required.
# =============================================================================

from komira_atomic_alias import AtomicI32
from std.memory import ArcPointer, OwnedPointer, alloc
from std.time import perf_counter_ns

from komira_async.channel.mpsc import (
    MpscReceiver,
    TRY_RECV_OK,
    channel as mpsc_channel,
)
from komira_async.observability.hot_shard_metrics import HotShardMetrics
from komira_async.observability.reactor_stall_detector import (
    ReactorStallDetector,
)
from komira_async.ops.waker_sink import WakerSink
from komira_async.reactor.completion_queue import (
    Completion,
    OpHandle,
    OP_ERR,
    OP_PENDING,
    OP_READY,
)
from komira_async.reactor.reactor import IoSubsystem
from komira_async.runtime.idle_hook import _IdleHookSlot
from komira_async.runtime.shared_erasure import ErasedHandle
from komira_async.runtime.sched_trace import (
    _SchedWorkerAccum,
    sched_trace_pool_depth,
)
from komira_async.runtime.wake_primitives import (
    WorkerWakeHandle,
    _SleepingFlag,
    pause_intrinsic,
)
from komira_collections.slab import Slab

# komira_log P2b — the per-core log drain. The worker drains its OWN log ring
# (SPSC: this worker is the sole consumer of ring[worker_id]) at the cooperative
# idle hook, bounded so it can NEVER starve query work. Reached via the
# process-static engine handle (resolved by address; no cycle — komira_log
# sits below komira_async in the DAG).


# Bounded per-iteration log-drain budget. Far smaller than the query-task drain
# (MAX_DRAIN_PER_ITER=16) — the log drain decodes + formats + write(2)s each
# record, which is heavier per item, so we cap it tight to keep the idle path
# responsive. A worker that backed up more than this many log records in one
# idle window drains the rest on the next idle window (the ring is bounded +
# DROP, so it can never grow unboundedly anyway).
comptime MAX_LOG_DRAIN_PER_IDLE: Int = 32


# Bounded per-idle native-index hook budget. The installable idle hook
# fires AFTER `_drain_log_ring`, in the
# same empty-spin window — by definition out of query/IO work, so it can NEVER
# starve query work. It is bounded so it never runs an unbounded backlog flush
# in one visit: the HIGH-side hook body drains at most ONE cheap L0 build's
# worth of records per call (a granularity knob, ~16-24 docs <= ~50µs,
# below one reactor-poll-starvation window), and the worker fires the hook at
# most `MAX_IDLE_HOOK_FIRINGS_PER_IDLE` times per idle window. Remaining records
# ride the next idle window (or the HIGH-side byte/time flush ceiling on a busy
# worker). The bound is the worker-side NO-STARVE guarantee the
# e2e asserts: a single idle visit does a bounded amount of index work.
comptime MAX_IDLE_HOOK_FIRINGS_PER_IDLE: Int = 1


# Bounded per-iteration drain count. Matches Seastar smp.hh's batched-16
# default. Capping the drain keeps IO responsive — a worker that
# drains 1024 backlogged compute tasks before polling epoll would starve
# inbound socket activity. 16 strikes the canonical Seastar balance.
comptime MAX_DRAIN_PER_ITER: Int = 16


# Ready-cache initial capacity. State-machine track's `_register_for_ready_cache`
# inserts one slot per concurrently-pending IoOp on this worker; typical
# state-machine workloads have <100 concurrent IoOps per worker
# — single-task-per-worker) so this is conservative. Grows geometrically.
#
# The PENDING_COROS_* aliases for the
# async/await `_pending_coros` table are gone with the track itself.
comptime READY_CACHE_INITIAL_CAPACITY: Int = 64


# Bounded spin-then-park constants.
# SPIN_LIMIT: number of spin iterations before parking on epoll_wait. The
# tokio/glommio canonical starting point was 64; with the kevent(0) syscall
# inside `Reactor.poll_completions(0)` on every iteration, a spin iter
# costs ~12µs on an Apple M3 Ultra
# (dominated by the kevent(0) syscall inside `Reactor.poll_completions(0)`,
# NOT the ~5 ns x86 PAUSE / ~90 ns aarch64 sched_yield as the original cost
# model assumed). With the conditional-kevent guard below (kevent fires
# every 64th iter only), per-iter steady-state cost drops to ~2 ns (atomic
# load) + ~190 ns amortized (kevent 1/64 iters), so a SPIN_LIMIT of 8192
# costs ~16-32 µs of idle CPU per parked spin window — well within budget
# and covers up to ~1.5 ms of inter-dispatch gap before the worker parks.
# The point of raising SPIN_LIMIT (now that the guard has made each iter cheap)
# is to keep workers awake across the IO-class ~390 µs inter-dispatch
# gap so `wake_with_elision` elides the eventfd syscall — saving the
# ~50-70 µs wake-syscall cost per dispatch.
#
# A spin window that is too long has the opposite failure: on an HTTP
# single-connection serve loop a profile showed
# 75% scheduler self-time at SPIN_LIMIT=8192 on the HTTP
# single-conn shape. Root cause: with HTTP single-conn at ~12K RPS,
# inter-spawn gap per worker is ~336µs which is JUST larger than the
# ~270µs spin window — workers burn near-max CPU spinning between
# every request without ever amortizing the park. Keeping the connection
# within one task removes that gap entirely (a ~3x single-connection
# speedup).
#
# Adaptive
# park-on-empty heuristic. `SPIN_LIMIT` is the
# INITIAL/MAXIMUM bound; each Worker carries a mutable `_spin_limit`
# field that adapts based on observed inter-dispatch gap. The constant
# below (`SPIN_LIMIT_MAX`) preserves the IO-class 390 µs cover at
# cold start; the adaptive heuristic only LOWERS it when the per-worker
# observed gap signals a different workload class (compute-class →
# SPIN_LIMIT_MIN=256; mid-class → SPIN_LIMIT_MID=2048; IO-class →
# SPIN_LIMIT_MAX=8192). See `_spin_limit` field doc on Worker[S] below
# and the EWMA / consecutive-empty-window update sites in
# `run_until_shutdown`.
comptime SPIN_LIMIT_MAX: Int = 8192
comptime SPIN_LIMIT_MID: Int = 2048
comptime SPIN_LIMIT_MIN: Int = 256
# Hard floor — even after K consecutive empty windows the spin must
# cover enough iters to avoid thrash (the eventfd wake itself takes
# ~50-70 µs on the next dispatch; with sub-floor spin the worker would
# park-wake-park-wake on every dispatch). 64 iters × ~2 ns steady-state
# (with the guard) = ~128 ns minimum spin window — safe floor.
comptime SPIN_LIMIT_FLOOR: Int = 64
# Initial EWMA seed — IO-class ~390 µs spin-wall. Preserves the IO-class
# spin window at cold start until the first observation overrides it.
# Semantic: "expected time-spent-spinning before catching work". For
# a 390 µs inter-dispatch gap, an awake worker spins ~390 µs
# before the next dispatch arrives (assuming kevent guard amortizes
# the per-iter cost to ~2 ns).
comptime INITIAL_AVG_SPIN_NS: Int64 = Int64(400_000)
# Spin-wall thresholds for 3-tier classification.
# < 1 µs           = COMPUTE (back-to-back batched dispatch like parquet
#                             write per-col fanout — work arrives within
#                             a microsecond of spin start)
# < 100 µs         = MID     (mixed compute/IO dispatch)
# >= 100 µs        = IO      (IO-bound scans / HTTP)
comptime SPIN_THRESHOLD_FAST_NS: Int64 = Int64(1_000)
comptime SPIN_THRESHOLD_MID_NS: Int64 = Int64(100_000)
# EWMA window — N=8 gives ~3 samples worth of effective memory, fast
# adaptation. New = (Old*(N-1) + Sample) / N.
comptime EWMA_N: Int64 = Int64(8)
# Consecutive-empty-window force-tier-down threshold. Idle
# workers in a narrow fan-out never observe work via the spin → drain
# path, so the EWMA never updates. After K consecutive empty spin
# windows (~K * 16 µs idle CPU at SPIN_LIMIT_MAX), force tier down to
# SPIN_LIMIT_MIN so the next park happens ~32x faster. The first
# observed work resets this counter.
comptime EMPTY_WINDOW_K: UInt32 = UInt32(3)

# Legacy alias — kept for any test/observability code that still
# imports the original constant name. SPIN_LIMIT now means "initial
# and maximum bound" — the production spin loop reads `self._spin_limit`
# (the adaptive per-worker field) instead of this constant.
comptime SPIN_LIMIT: Int = SPIN_LIMIT_MAX

# PARK_TIMEOUT_US: blocking timeout for the post-spin epoll_wait. -1
# means block forever (the eventfd is the wake mechanism). By design
# there is no 1-second backstop; eventfd-on-shutdown via
# Worker.signal_shutdown is sufficient.
comptime PARK_TIMEOUT_US: Int32 = -1


struct Worker[S: WakerSink & Movable & Deinitable](
    Movable, Deinitable
):
    """Per-worker state, with eventfd spin-park.

    The Worker owns its task queue (consumer end
    of an MPSC channel; producers are the runtime's LocalDispatcher and
    LocalSpawner). Producer wake goes through the Reactor's eventfd (registered
    with the worker's epoll set), accessed via the wake_handle()
    accessor chain.

    The worker_main loop's run_one_iteration drains up to
    MAX_DRAIN_PER_ITER entries before calling _io_subsystem.run_once.
    """

    var _worker_id: UInt16
    var _io_subsystem: IoSubsystem[Self.S]
    var _shutdown_flag: OwnedPointer[AtomicI32]
    var _stall_detector: ReactorStallDetector
    var _imbalance_metrics: HotShardMetrics
    var _iter_count: UInt64
    var _task_queue: MpscReceiver[ErasedHandle]
    # Per-worker ready-cache table.
    # The Worker (NOT the Reactor) owns this table so the Reactor stays
    # track-agnostic. Slab[T] is non-Movable on Mojo 0.26.3, so the
    # Repro 1b OwnedPointer wrap keeps the slab at a stable heap address
    # for the worker's lifetime while preserving Worker[S] Movability.
    #
    # There is one completion table: every completion routes here.
    var _ready_cache: OwnedPointer[Slab[OpHandle]]          # state-machine track
    # — wake elision Seastar `_sleeping` flag.
    # Set to 1 immediately BEFORE epoll_wait + cleared to 0 immediately AFTER.
    # Producers (LocalDispatcher / LocalSpawner) load this flag via
    # WorkerWakeHandle.wake_with_elision() (typed deref through their own
    # ArcPointer clone) and SKIP the eventfd write when it's 0 (worker
    # awake).
    #
    # The Worker holds the "primary" ArcPointer; producers hold their own
    # clones via wake_handle(). Refcount tracks lifetime — the inner
    # _SleepingFlag (and its OwnedPointer-wrapped Atomic) survives until
    # the last clone drops.
    var _sleeping_arc: ArcPointer[_SleepingFlag]
    # Redesigned spin-path observability counter for the regression test
    # `test_worker_spin_kevent_frequency.mojo`. Counts how
    # many times the spin-phase `poll_completions(Int32(0))` actually
    # fires the kevent / epoll_wait syscall. Without the guard: increments once
    # per spin iter (~12µs / call on an Apple M3 Ultra, ~64 per spin window).
    # With the guard: increments every 64th iter (1/64 of the unguarded rate).
    # Plain `UInt64` — single-threaded (only the Worker's own thread
    # mutates), no atomic needed; the test sleeps the Worker before
    # reading. ~zero overhead on hot path.
    var _spin_kevent_call_count: UInt64

    # ---- Adaptive spin ----
    # Adaptive park-on-empty heuristic — per-worker spin tuning.
    #
    # `_spin_limit`: mutable per-worker spin-window cap. The production
    # spin loop reads `self._spin_limit` (not the comptime constant) on
    # entry to each window, so the value can change between windows
    # without disturbing in-flight iterations. Initial value is
    # SPIN_LIMIT_MAX (8192) so cold-start workers cover the IO-class
    # ~390 µs inter-dispatch gap before any adaptation kicks in.
    #
    # `_avg_spin_ns`: EWMA of observed spin-window wall (time from spin
    # start to either "found work" or "spin out"). Updated ONLY on
    # observed-work spin paths; park wakes do NOT contribute. The
    # measure captures "how long did the worker spin before catching
    # work" — short spin = arrivals are fast = COMPUTE; long spin =
    # arrivals are slow = IO. The 3-tier classifier maps:
    #   < 1 µs    → SPIN_LIMIT_MIN  (parquet write per-col fanout,
    #                                back-to-back batched dispatch)
    #   < 100 µs  → SPIN_LIMIT_MID  (mixed compute/IO)
    #   >= 100 µs → SPIN_LIMIT_MAX  (IO-bound scans / HTTP)
    #
    # `_spin_started_ns`: timestamp captured at the start of the current
    # spin window. Used to compute `now - _spin_started_ns` = spin wall.
    #
    # `_consecutive_empty_windows`: counter of full SPIN-WINDOW iterations
    # that completed with zero observed work (worker spun out the entire
    # window, then parked). The EWMA never updates in this path because
    # no work was observed — so for workers that NEVER see work (e.g. the
    # 11 idle workers during parquet-write's 21-worker fanout), the EWMA
    # path alone cannot tier them down. After EMPTY_WINDOW_K consecutive
    # empty windows, the worker FORCE-tiers-down to SPIN_LIMIT_MIN so the
    # next park happens ~32x faster. Reset on any observed work.
    #
    # All four fields are single-threaded (Worker pthread is the only
    # mutator); plain (non-atomic) scalars are sufficient.
    var _spin_limit: Int
    var _avg_spin_ns: Int64
    var _spin_started_ns: Int64
    var _consecutive_empty_windows: UInt32

    # -------------------------------------------------------------------------
    # Installable idle-hook slot (idle_hook.mojo. The HIGH layer
    # (EngineContext) installs ONE POD `_IdleHookSlot` at setup; the worker
    # fires it in the empty-spin idle window (run_until_shutdown, sibling to
    # `_drain_log_ring`). `None` until installed — the steady state for a tool
    # with no EngineContext.
    #
    # THIS FIELD OWNS NO HEAP:
    # `_IdleHookSlot` is POD (a BORROWED byte-ptr + two FFI-POD code pointers),
    # so `Optional[_IdleHookSlot]` is POD. The worker BORROWS the forever-root
    # context; the EngineContext OWNS + frees it (after join). On a destroy-
    # recreate cycle the field is re-initialized to `None` by `__init__` and
    # re-installed against the FRESH context — no stale heap byte is owned, so
    # the destroy-recreate reuse hazard cannot fire. The wildcard origin
    # lives ONLY on the slot's `ctx_raw` (the blessed _TaskEntry-style erasure
    # handle); this field declaration itself is `Optional[<POD struct>]`, NOT a
    # wildcard-origin field.
    var _idle_hook: Optional[_IdleHookSlot]

    # the per-context log engine's pthread TLS key, threaded in at
    # runtime construction so the pthread entry can bind THIS thread's worker_id
    # into TLS WITHOUT the ambient `log_engine_ref()` launder. POD `UInt64`; 0
    # means "no engine / no binding" (a standalone async tool). destroy-recreate-N/A.
    var _log_tls_key: UInt64

    # SCHED-TRACE: per-worker wall accumulators for the a/b/c/d
    # split. POD scalars (trivially safe across destroy-recreate); `enabled` is cached ONCE at construction
    # so the worker hot loop gates on a cold Bool field — ZERO external_call when
    # scheduler tracing is off.
    var _sched_accum: _SchedWorkerAccum

    def __init__(
        out self,
        worker_id: UInt16,
        var sink: Self.S,
        backend: UInt8,
    ) raises:
        """Standalone-Worker convenience constructor — synthesizes its
        own MPSC channel pair (sender immediately dropped). Used by
        unit tests that construct a Worker directly without the runtime
        attaching it to a producer (LocalDispatcher / LocalSpawner).
        """
        var pair = mpsc_channel[ErasedHandle](UInt(1024))
        var receiver = pair.take_receiver()
        var sender = pair.take_sender()
        # Drop the sender — nothing will produce to this queue.
        _ = sender^
        self._worker_id = worker_id
        self._io_subsystem = IoSubsystem[Self.S](sink^, backend)
        var sf_ptr = alloc[AtomicI32](1)
        # SAFETY: fresh allocation we own.
        sf_ptr[] = AtomicI32(Int32(0))
        self._shutdown_flag = OwnedPointer[AtomicI32](
            unsafe_from_raw_pointer=sf_ptr,
        )
        self._stall_detector = ReactorStallDetector()
        self._imbalance_metrics = HotShardMetrics(worker_id=worker_id)
        self._iter_count = UInt64(0)
        self._task_queue = receiver^
        # — pre-allocate the ready-cache table.
        # (The only completion table.)
        self._ready_cache = OwnedPointer[Slab[OpHandle]](
            value=Slab[OpHandle](capacity=READY_CACHE_INITIAL_CAPACITY),
        )
        # wake elision sleeping arc init (0=awake).
        # _SleepingFlag's __init__ allocates the inner Atomic on heap;
        # ArcPointer wraps for shared-lifetime cross-pthread access.
        self._sleeping_arc = ArcPointer[_SleepingFlag](_SleepingFlag())
        # redesigned spin-path — observability counter init.
        self._spin_kevent_call_count = UInt64(0)
        # Adaptive park-on-empty heuristic init.
        # Start at SPIN_LIMIT_MAX so cold-start covers IO-class gaps;
        # seed EWMA at INITIAL_AVG_SPIN_NS (IO-class ~390µs) so the first
        # observation overrides it cleanly. Spin-started seeded at
        # ctor wall-clock; the production spin loop overwrites it on
        # entry to each window (this seed is just defensive).
        self._spin_limit = SPIN_LIMIT_MAX
        self._avg_spin_ns = INITIAL_AVG_SPIN_NS
        self._spin_started_ns = Int64(perf_counter_ns())
        self._consecutive_empty_windows = UInt32(0)
        # Idle-hook slot — None until a EngineContext installs it.
        self._idle_hook = None
        # Standalone worker (tests) — no engine, so no TLS binding.
        self._log_tls_key = UInt64(0)
        # SCHED-TRACE: cache the env-gated trace flag once.
        self._sched_accum = _SchedWorkerAccum()

    def __init__(
        out self,
        worker_id: UInt16,
        var sink: Self.S,
        backend: UInt8,
        var task_queue: MpscReceiver[ErasedHandle],
        log_tls_key: UInt64 = UInt64(0),
    ) raises:
        """`sink` consumed; `backend` selects the
        reactor backend kind (BACKEND_EPOLL / BACKEND_MOCK / BACKEND_KQUEUE).
        `task_queue` consumed — the receiver end of the per-worker MPSC
        channel; the matching senders are stored on the runtime
        (PerCoreAsyncRuntime._worker_senders) for the dispatcher /
        spawner to clone from.

        Atomic[DType.int32] is non-Movable on 0.26.3, so the shutdown flag
        is heap-allocated via OwnedPointer (Repro 7 pattern). Stall
        detector + imbalance metrics are constructed with their own
        OwnedPointer[Atomic[..]] inner fields.
        """
        self._worker_id = worker_id
        self._io_subsystem = IoSubsystem[Self.S](sink^, backend)
        var flag_ptr = alloc[AtomicI32](1)
        # SAFETY: flag_ptr is a fresh allocation we own; we initialize via
        # direct field-style assignment (Repro 7 pattern) since the
        # Atomic ctor accepts a Scalar value. Ownership transfers to
        # OwnedPointer; __del__ runs free.
        flag_ptr[] = AtomicI32(Int32(0))
        self._shutdown_flag = OwnedPointer[AtomicI32](
            unsafe_from_raw_pointer=flag_ptr
        )
        # Observability primitives. Defaults: 20ms stall threshold.
        self._stall_detector = ReactorStallDetector()
        self._imbalance_metrics = HotShardMetrics(worker_id=worker_id)
        self._iter_count = UInt64(0)
        self._task_queue = task_queue^
        # — pre-allocate the ready-cache table.
        # (The only completion table.)
        self._ready_cache = OwnedPointer[Slab[OpHandle]](
            value=Slab[OpHandle](capacity=READY_CACHE_INITIAL_CAPACITY),
        )
        # wake elision sleeping arc init (0=awake).
        self._sleeping_arc = ArcPointer[_SleepingFlag](_SleepingFlag())
        # redesigned spin-path — observability counter init.
        self._spin_kevent_call_count = UInt64(0)
        # Adaptive park-on-empty heuristic init.
        self._spin_limit = SPIN_LIMIT_MAX
        self._avg_spin_ns = INITIAL_AVG_SPIN_NS
        self._spin_started_ns = Int64(perf_counter_ns())
        self._consecutive_empty_windows = UInt32(0)
        # Idle-hook slot — None until a EngineContext installs it.
        self._idle_hook = None
        # the per-context engine's TLS key, threaded from the runtime
        # so the pthread entry binds worker_id WITHOUT `log_engine_ref()`.
        self._log_tls_key = log_tls_key
        # SCHED-TRACE: cache the env-gated trace flag once.
        self._sched_accum = _SchedWorkerAccum()

    @always_inline
    def log_tls_key(self) -> UInt64:
        """the per-context log engine's pthread TLS key (0 if none).
        Read by the pthread entry to bind worker_id into TLS without the ambient
        `log_engine_ref()` launder."""
        return self._log_tls_key

    def worker_id(self) -> UInt16:
        """"""
        return self._worker_id

    def io_subsystem(mut self) -> ref [self._io_subsystem] IoSubsystem[Self.S]:
        """IoSubsystem accessor.
        finding 5: ref-return through inner field uses
        `ref [self._io_subsystem]`."""
        return self._io_subsystem

    def stall_detector(mut self) -> ref [self._stall_detector] ReactorStallDetector:
        """accessor.

        Returns a mutable ref to the per-worker ReactorStallDetector so
        callers (test code, structured-log emitters) can read counters
        and clear the need_preempt flag at task-yield boundaries.
        """
        return self._stall_detector

    def imbalance_metrics(mut self) -> ref [self._imbalance_metrics] HotShardMetrics:
        """accessor.

        Returns a mutable ref to the per-worker HotShardMetrics. The
        aggregator pattern (CV across workers) lives at the caller —
        materialize List[Int64] from each worker's work_completed() and
        feed to compute_cv / is_imbalanced. See
        `observability/hot_shard_metrics.mojo` aggregator block.
        """
        return self._imbalance_metrics

    def signal_shutdown(mut self):
        """Set the shutdown flag + wake the worker via its eventfd.
        Lock-free; safe to call from any thread.

 (eventfd-spin-park): with PARK_TIMEOUT_US=-1, signaling
        the flag alone does NOT wake a parked epoll_wait. The eventfd
        write via Reactor.wake_self() unblocks the worker so it observes
        the flag on its next loop top.

        Order is load-bearing:
          1. Set the shutdown flag (release).
          2. Write the eventfd (kernel-side HB carries liveness).
        Reverse causes a lost wake (worker observes empty wake, re-parks,
        flag set with no further wake).
        """
        # Step 1: set the flag.
        AtomicI32.store(
            UnsafePointer(to=self._shutdown_flag[]).unsafe_bitcast[Scalar[DType.int32]](), Int32(1),
        )
        # Step 2: wake the eventfd via the Reactor's public wake_self.
        # Best-effort; eventfd write surface is no-raise (EBADF/EAGAIN
        # silently swallowed; -1 sentinel is no-op).
        self._io_subsystem.reactor().wake_self()

    def is_shutdown_signaled(self) -> Bool:
        return self._shutdown_flag[].load() != Int32(0)

    def wake_handle(self) -> WorkerWakeHandle:
        """Wake handle accessor.

        Returns a producer-facing WorkerWakeHandle that carries:
          - the eventfd (from this worker's Reactor), AND
          - a clone of this worker's `_sleeping_arc` (typed
            ArcPointer<_SleepingFlag>; refcount-bumped).

        Used by PerCoreAsyncRuntime._attach_one_worker to seed the
        producer-side wake handle slabs on LocalDispatcher /
        LocalSpawner.

        The typed ArcPointer (rather than an Int-laundered address)
        keeps the _SleepingFlag (and its
        OwnedPointer-wrapped Atomic) alive for the lifetime of every
        clone — Worker-outlives-producer is not required.

        SAFETY: typed deref through ArcPointer; no wildcard origins, no
        Int laundering. The ArcPointer clone is the canonical Mojo 0.26.3
        shared-ownership idiom (`ArcPointer[T](copy=existing)`
        is the stdlib idiom; not `existing.clone()`).
        """
        # Get a baseline handle from the Reactor (carries the eventfd +
        # ident; the Reactor uses a "disconnected" dummy sleeping_arc
        # placeholder).
        var base = self._io_subsystem.wake_handle()
        # Splice in the real Worker-owned sleeping arc clone. Refcount
        # bump on this Worker's arc; the producer's clone keeps the
        # _SleepingFlag alive for the producer's lifetime.
        return WorkerWakeHandle.from_parts(
            base^,
            ArcPointer[_SleepingFlag](copy=self._sleeping_arc),
        )

    def sleeping_flag_load(self) -> Int32:
        """Test/observability accessor — returns the current value of the
        Worker's sleeping flag via the typed ArcPointer deref. Used by
        tests to verify the park-bracket transitions without going
        through any wildcard / Int-laundered path."""
        return self._sleeping_arc[].load()

    def spin_kevent_call_count(self) -> UInt64:
        """Test/observability accessor — returns how many times the
        spin-phase `poll_completions(Int32(0))` has fired the kevent /
        epoll_wait syscall over the Worker's lifetime. Used by
        `tests/unit/test_worker_spin_kevent_frequency.mojo` to verify
        the conditional-kevent guard.

        Without the guard: increments once per spin iter (i.e. up to SPIN_LIMIT
        per spin window if no work arrives).
        With the guard: increments only on every 64th spin iter (mask
        `(spun & 0x3F) == 0`).
        """
        return self._spin_kevent_call_count

    # =========================================================================
    # Adaptive spin —
    # adaptive park-on-empty heuristic accessors + state mutators.
    # =========================================================================

    def spin_limit_current(self) -> Int:
        """Test/observability accessor — current per-worker spin window
        cap. Initially SPIN_LIMIT_MAX (8192); adapts down to
        SPIN_LIMIT_MID (2048) or SPIN_LIMIT_MIN (256) based on observed
        inter-dispatch gap (EWMA) and consecutive-empty-window counter.
        """
        return self._spin_limit

    def avg_spin_ns(self) -> Int64:
        """Test/observability accessor — current EWMA of observed
        spin-window walls (ns from spin start to "found work"). Updated
        only on observed-work spin paths; park wakes do NOT update.
        """
        return self._avg_spin_ns

    def consecutive_empty_windows(self) -> UInt32:
        """Test/observability accessor — number of consecutive full spin
        windows that completed with zero observed work. Reset on any
        observed work. Used by the force-tier-down path to handle the
        parquet-write-style scenario where some workers never see work
        and the EWMA can't update.
        """
        return self._consecutive_empty_windows

    @always_inline
    def _tier_for_spin(self, spin_ns: Int64) -> Int:
        """3-tier classifier: map an observed spin wall (ns) to a spin
        window cap. Mirrors the dispatch design:
          < 1 µs           → SPIN_LIMIT_MIN  (back-to-back compute)
          < 100 µs         → SPIN_LIMIT_MID  (mixed)
          >= 100 µs        → SPIN_LIMIT_MAX  (IO-bound scans / HTTP)
        """
        if spin_ns < SPIN_THRESHOLD_FAST_NS:
            return SPIN_LIMIT_MIN
        elif spin_ns < SPIN_THRESHOLD_MID_NS:
            return SPIN_LIMIT_MID
        else:
            return SPIN_LIMIT_MAX

    @always_inline
    def _on_spin_window_start(mut self):
        """Adaptive spin — spin-window start hook. Called at the top of each
        spin-window iteration in `run_until_shutdown` to mark
        `_spin_started_ns = perf_counter_ns()`. The
        `_on_found_work_in_spin` mutator reads this to compute the
        spin wall = now - _spin_started_ns.
        """
        self._spin_started_ns = Int64(perf_counter_ns())

    def _on_found_work_in_spin(mut self):
        """Adaptive spin — observed-work sample point. Called after the spin loop
        exits with found_work_in_spin=True. Computes the spin wall =
        now - _spin_started_ns (set by _on_spin_window_start), clamps it
        to a sane upper bound (defensive against clock skew or a long
        warm-up pause), updates the EWMA, recomputes spin_limit from
        the new EWMA, and resets the consecutive-empty-window counter
        (this window was NOT empty).

        EWMA: new = (old * (N-1) + sample) / N, with N=8.

        Sample clamp: caps spin_ns at SPIN_LIMIT_MAX * ~200ns budget
        (worst-case spin window wall = 8192 iters * ~190ns amortized
        kevent cost ≈ 1.6 ms; clamp at 2_000_000 ns = 2 ms for safety
        margin). Without the clamp, a worker that took the full park
        timeout before being woken would skew the EWMA into IO tier
        permanently.
        """
        var now = Int64(perf_counter_ns())
        var spin_ns = now - self._spin_started_ns
        # Clamp pathological negative spans (perf_counter_ns is
        # monotonic but defensive — a non-monotonic clock would
        # corrupt the EWMA).
        if spin_ns < Int64(0):
            spin_ns = Int64(0)
        # Sample clamp — bounded by the maximum legitimate spin wall.
        # 2 ms accommodates the SPIN_LIMIT_MAX * worst-case per-iter cost
        # without letting a stalled-clock outlier permanently skew the
        # EWMA.
        var clamp_max_ns = Int64(2_000_000)
        if spin_ns > clamp_max_ns:
            spin_ns = clamp_max_ns
        # EWMA update — weighted average favoring recent observations.
        var n_minus_1 = EWMA_N - Int64(1)
        self._avg_spin_ns = (
            self._avg_spin_ns * n_minus_1 + spin_ns
        ) // EWMA_N
        # Recompute spin_limit from the new EWMA tier.
        self._spin_limit = self._tier_for_spin(self._avg_spin_ns)
        # Reset empty-window counter — this window observed work.
        self._consecutive_empty_windows = UInt32(0)

    def _on_empty_spin_window(mut self):
        """Adaptive spin — empty-window sample point. Called after the spin loop
        exits with found_work_in_spin=False (i.e. spun out the full
        window without observing any work). Increments the
        consecutive-empty-window counter; once it reaches
        EMPTY_WINDOW_K, FORCES tier-down to SPIN_LIMIT_MIN regardless
        of the current EWMA. The EWMA is NOT updated (no work
        observed).

        Why force tier-down: workers that NEVER see work in a run
        (e.g. the idle workers in a narrow
        fan-out) cannot adapt via the EWMA path alone — they have no
        sample to feed it. Without this force path the idle workers
        would each burn SPIN_LIMIT_MAX*~2ns + 128*~12µs of sched_yield
        / kevent per window for the duration of the run. The
        force tier-down caps that at K windows of waste, then drops to
        SPIN_LIMIT_MIN so the next park happens ~32x faster.

        Safety floor: tier-down never drops below SPIN_LIMIT_FLOOR (64),
        even if a future tuning change adds tighter tiers.
        """
        self._consecutive_empty_windows = (
            self._consecutive_empty_windows + UInt32(1)
        )
        if self._consecutive_empty_windows >= EMPTY_WINDOW_K:
            var floor_limit = SPIN_LIMIT_MIN
            if floor_limit < SPIN_LIMIT_FLOOR:
                floor_limit = SPIN_LIMIT_FLOOR
            self._spin_limit = floor_limit

    # `_drain_log_ring` (the ambient `log_engine_ref()` idle-drain of
    # the per-context engine) is DELETED. The env-var launder is gone; the
    # per-context engine's rings are drained by (a) the native-index idle hook
    # (`_fire_idle_hook`, carried-handle) when installed, and (b)
    # `EngineContext.flush_log_engine` at query boundaries otherwise. Nothing on
    # the worker path reaches the engine by laundered address anymore.

    def set_idle_hook(mut self, slot: _IdleHookSlot):
        """Install the standing idle-hook slot. Called ONCE by the
        EngineContext at setup, via `PerCoreAsyncRuntime.install_idle_hook`.
        The slot is POD — the worker BORROWS the forever-root context it points
        at (`slot.ctx_raw`); the EngineContext OWNS it. Setting this field
        copies 3 machine words; it allocates nothing."""
        self._idle_hook = Optional(slot)

    def has_idle_hook(self) -> Bool:
        """True iff a EngineContext has installed the native-index idle hook on
        this worker. Test/observability accessor."""
        return Bool(self._idle_hook)

    def _fire_idle_hook(mut self):
        """Native-index idle hook — fire the installed `_IdleHookSlot` BLIND
        (type-erased) in the empty-spin idle window, BOUNDED so it can NEVER
        starve query/IO work.

        Called at the cooperative idle hook (worker.mojo idle window), sibling to
        `_drain_log_ring` — i.e. only when this worker found no query/IO work
        this window, so the drain+transpose+build+publish cost lands on a thread
        that is otherwise about to park.

        BOUNDED (no-starve): the hook fires at most `MAX_IDLE_HOOK_FIRINGS_PER_IDLE`
        times per idle visit; the HIGH-side body itself drains at most one cheap
        L0 build's worth of records per call. A
        worker that backed up more records than one visit can index drains the
        rest on the next idle window (or via the HIGH-side byte/time flush
        ceiling —). We are by definition out of work here, so this can NEVER
        starve query work.

        BLIND (acyclic): the worker calls `slot.fire(wid)` (the `ErasedHook`
        encapsulated API) without naming the concrete store/metastore/index
        types — the body is monomorphized HIGH-side on the producer side of the
        erasure boundary. `worker_id` is passed
        directly (the SPSC drain key the body uses on `drain_worker_to_records`).

        FAIL-SAFE (at-most-once): the run trampoline `raises`; a single bad idle
        build (e.g. a transient publish failure) MUST NOT crash the worker loop,
        so we swallow the error here. The HIGH-side body already surfaces the
        loss to a loud counter (the contract) before raising.

        SAFETY: `slot.ctx_raw` targets the forever-root EngineContext-owned
        `OwnedPointer[C]`, which outlives every worker (the runtime joins all
        workers in its __del__ BEFORE the EngineContext drops the context — the
        SAME join-before-drop the engine relies on). `self` is borrowed
        mut (the hook body mutates the engine ring + the HIGH-owned store, not
        the Worker)."""
        if not self._idle_hook:
            return
        var slot = self._idle_hook.value()
        var wid = self._worker_id
        var fired = 0
        while fired < MAX_IDLE_HOOK_FIRINGS_PER_IDLE:
            try:
                slot.fire(wid)
            except e:
                # FAIL-SAFE: surface (HIGH-side already counted) but never crash
                # the worker loop on one bad idle build.
                print("ERROR idle-index hook: build/publish raised:", String(e))
                break
            fired = fired + 1

    # ---- Plan C test-only helpers ----
    # These drive the adaptive state mutators directly without requiring
    # the spin loop to actually run. Used by
    # `tests/unit/test_worker_adaptive_spin_tuning.mojo` to verify EWMA
    # convergence + force-tier-down behavior. Production paths do NOT
    # call these.

    def _test_simulate_found_work_with_spin(mut self, spin_ns: Int64):
        """Test-only — simulate one "found work in spin" event with a
        SPECIFIC observed spin wall (instead of using wall-clock). Sets
        `_spin_started_ns` so the computed `now - _spin_started_ns`
        delta inside `_on_found_work_in_spin` equals exactly `spin_ns`.

        Tolerates the small wall-clock delta between the setup and the
        `perf_counter_ns()` call inside the mutator by reading `now`
        here and adjusting `_spin_started_ns` to `now - spin_ns`
        before calling the mutator.
        """
        var now = Int64(perf_counter_ns())
        self._spin_started_ns = now - spin_ns
        self._on_found_work_in_spin()

    def _test_simulate_empty_window(mut self):
        """Test-only — simulate one "spin window completed empty" event."""
        self._on_empty_spin_window()

    def _test_run_spin_iters(mut self, n_iters: Int) raises -> Int:
        """Test-only — run exactly `n_iters` iterations of the spin-phase
        body (the same body as `run_until_shutdown`'s inner spin loop)
        without parking, without entering the outer park bracket, and
        without bumping the stall-detector / imbalance-metrics.

        Returns the number of spin iters actually executed (== n_iters
        unless an MPSC entry arrived mid-test or shutdown was signaled).

        Used exclusively by
        `tests/unit/test_worker_spin_kevent_frequency.mojo` to assert
        the conditional-kevent guard's frequency: with the guard in
        place, after `n_iters` spins the `spin_kevent_call_count()`
        should be `ceil(n_iters / 64)` ± 1 (it increments on
        `(spun & 0x3F) == 0`, fired on iters 0, 64, 128, …).

        Mirrors the production spin body EXACTLY (same guard, same
        increment placement, same pause-intrinsic platform gate) — if
        the production body changes, this helper must change in lockstep.
        Production paths do NOT call this method.
        """
        var spun: Int = 0
        while spun < n_iters:
            if self.is_shutdown_signaled():
                break
            var n_drained = self.drain_task_queue(MAX_DRAIN_PER_ITER)
            if n_drained > 0:
                break
            if (spun & 0x3F) == 0:
                self._spin_kevent_call_count = (
                    self._spin_kevent_call_count + UInt64(1)
                )
                var completions = self._io_subsystem.reactor().poll_completions(
                    Int32(0),
                )
                if len(completions) > 0:
                    var n_c = len(completions)
                    for i in range(n_c):
                        self._dispatch_completion(completions[i])
                    break
            pause_intrinsic()
            spun = spun + 1
        return spun

    # =========================================================================
    # Ready-cache table + completion dispatch.
    # =========================================================================
    #
    # There is ONE completion table: every completion routes to
    # `_ready_cache` (state-machine
    # track). so an op_id-partitioning invariant is vacuous
    # (one table only).
    #
    #   - State-machine track: IoOp.for_read/... calls submit + then
    #     `_register_for_ready_cache(op_id)`. Park loop polls
    #     `_is_in_ready_cache + _take_ready` to detect completion.
    #
    # The ready-cache lives on the Worker (NOT the Reactor) so the Reactor
    # stays track-agnostic — the Reactor's poll_completions returns a list
    # of Completion records and the Worker dispatches.

    def _register_for_ready_cache(mut self, op_id: Int64):
        """State-machine track register. Insert an
        OP_PENDING OpHandle into _ready_cache keyed by op_id. The IoOp's
        `wait()` park loop polls `_is_in_ready_cache(op_id)` to detect
        when the dispatch path has marked the slot ready.

        Called by `IoOp.for_read/for_write/...` immediately after
        Reactor.submit returns OP_PENDING (the slow path). Fast-path
        OP_READY / OP_ERR results never go through the ready cache —
        the IoOp wrapper short-circuits.
        """
        self._ready_cache[].append(
            OpHandle(_op_id=op_id, _state=OP_PENDING, _result=Int64(0)),
        )

    def _is_in_ready_cache(self, op_id: Int64) -> Bool:
        """Dispatch helper — true if the op_id has a slot in
        _ready_cache (regardless of _state). The dispatch path uses this
        to decide which track owns the completion.
        """
        var n = self._ready_cache[].len()
        for i in range(n):
            if self._ready_cache[][i]._op_id == op_id:
                return True
        return False

    def _mark_ready_in_cache(mut self, c: Completion):
        """State-machine track dispatch. Find the slot
        for c.op_id and update its state + result based on the completion.

        Maps Completion fields → OpHandle fields:
          - bytes >= 0 + err_code == 0  → OP_READY  (_result = bytes)
          - err_code != 0               → OP_ERR    (_result = errno)
          - hangup (no err_code)        → OP_READY  (_result = 0; EOF)

        Best-effort: if no slot matches, no-op (the IoOp may have been
        dropped between submit and completion; benign).
        """
        var n = self._ready_cache[].len()
        for i in range(n):
            if self._ready_cache[][i]._op_id == c.op_id:
                if c.err_code != Int32(0):
                    self._ready_cache[][i] = OpHandle(
                        _op_id=c.op_id, _state=OP_ERR,
                        _result=Int64(c.err_code),
                    )
                else:
                    self._ready_cache[][i] = OpHandle(
                        _op_id=c.op_id, _state=OP_READY,
                        _result=c.bytes,
                    )
                return

    def _take_ready_op(mut self, op_id: Int64) -> Optional[OpHandle]:
        """State-machine track take. IoOp.wait()'s park loop
        polls `_is_in_ready_cache`; once ready, it calls this to extract
        the completed OpHandle. Returns None if the slot was never
        registered or already taken.
        """
        var n = self._ready_cache[].len()
        for i in range(n):
            if self._ready_cache[][i]._op_id == op_id:
                return self._ready_cache[].take_at(i)
        return None

    def _free_ready_cache_slot(mut self, op_id: Int64):
        """IoOp.__del__ helper. Remove the slot for op_id from
        _ready_cache. Best-effort: missing slot is benign (already drained
        via _take_ready_op, or never registered)."""
        _ = self._take_ready_op(op_id)

    def _ready_cache_len(self) -> Int:
        """Test / observability accessor — number of state-machine slots."""
        return self._ready_cache[].len()

    def _dispatch_completion(mut self, c: Completion):
        """Per-completion dispatch. Routes EVERY completion
        to the state-machine ready-cache; if no slot matches the op_id, the
        completion belongs to a cancelled / dropped op and is benignly
        ignored.

        There is one completion table, so an
        op_id-partitioning invariant is vacuous.
        """
        if self._is_in_ready_cache(c.op_id):
            self._mark_ready_in_cache(c)
            return
        # No match: completion belongs to a cancelled / dropped op. No-op.

    def flush_pending_submissions(mut self):
        """Placeholder for the kqueue changelist flush
        path. On epoll, submissions are issued inline by Reactor.submit /
        register_long_lived (no batching needed). On kqueue, the
        per-worker submit-queue would batch into a single kevent change-
        list; that batching layer is a future optimization.

        Currently a no-op. Documented for the worker_loop new-shape
        completeness; retained as an explicit step so the loop body
        matches pseudocode.
        """
        pass

    def drain_task_queue(mut self, max_drain: Int = MAX_DRAIN_PER_ITER) raises -> Int:
        """Drain up to `max_drain` entries from
        the per-worker MPSC task queue, invoking each entry's run_fnptr.

        Returns the number of entries drained.

        Bound `max_drain` matches Seastar smp.hh's batched-16 default
        — a worker that drains the entire queue
        per iteration would starve inbound IO under load. The remaining
        entries are picked up on the next iteration.

        Errors raised inside an entry's run_fnptr propagate up; the
        producer's trampoline contract is to catch task-body raises and
        publish via complete_slot_err so the trampoline itself does not
        raise outward in normal operation. A raise here therefore
        signals an internal-trampoline bug and bubbles up to the
        worker_main loop (which prints and shuts down).
        """
        # SCHED-TRACE: `_sched_on` is the cached Bool field — the
        # OFF path is a single cold branch (no perf_counter_ns, no external_call).
        # When ON: bucket (c) drain-pop overhead (try_recv + take_value) vs the
        # useful handle.run() wall, plus the task count.
        var _sched_on = self._sched_accum.enabled
        var drained = 0
        while drained < max_drain:
            var _pop_t0: UInt64 = UInt64(0)
            if _sched_on:
                _pop_t0 = UInt64(perf_counter_ns())
            var outcome = self._task_queue.try_recv()
            if outcome.status != TRY_RECV_OK:
                break
            # the queue now carries the Movable-only
            # `ErasedHandle` family member (retiring the bespoke `_TaskEntry`
            # POD). Move the handle OUT (`take_value`, not the Copyable-only
            # `value()`), run it BLIND (`handle.run()` — the family's void
            # task/queue arm dispatches to the concrete `_SpawnedTaskHeader.run`
            # for the spawner OR `_DispatchShard`'s run for the dispatcher), then
            # drop it. The handle's `__del__` is the teardown: OWNING (spawner)
            # frees the heap header home; BORROWED (dispatcher) no-ops (the
            # `_shard_buf` pool owns the bytes). Run contract: the concrete `run`
            # catches task-body raises + publishes via complete_slot_err; an
            # outward raise here is an internal-trampoline bug.
            var handle = outcome.take_value()
            if _sched_on:
                var _run_t0 = UInt64(perf_counter_ns())
                self._sched_accum.pop_ns += (_run_t0 - _pop_t0)
                handle.run()
                self._sched_accum.run_ns += (UInt64(perf_counter_ns()) - _run_t0)
                self._sched_accum.tasks += UInt64(1)
            else:
                handle.run()
            _ = handle^
            drained = drained + 1
        return drained

    def run_one_iteration(mut self, timeout_us: Int32) raises -> Int:
        """Worker loop. Drives
        the reactor for one cycle in the canonical drain → flush → poll →
        dispatch order:

          1. Drain MPSC up to MAX_DRAIN_PER_ITER (cross-pthread spawn
             requests).
          2. Flush pending submissions (kqueue changelist; epoll no-op).
          3. Poll reactor for completions (single epoll_wait / kevent).
             Wake-channel events are decoded internally by
             poll_completions and not surfaced.
          4. Dispatch each Completion to the state-machine ready-cache.

        Returns the total work units processed (drained + dispatched).

        observability preserved: brackets the iter with
        the stall-detector task_started / task_finished hooks; records
        work-completed against the imbalance metrics when n_total > 0.

        Backward compat with the prior signature: same
        `(mut self, timeout_us)` shape; same return type. Existing test
        / bench callers are unaffected. The shape change is purely
        internal — same outer contract of "drive one iteration; return
        work count".

        An op_id-partitioning
        invariant is vacuous (one table only).
        Every completion routes to `_ready_cache`.
        """
        var iter_id = Int64(self._iter_count)
        var started_ns = Int64(perf_counter_ns())
        self._stall_detector.task_started(iter_id, started_ns)

        # Step 1 — Drain MPSC. State-machine track trampolines land here
        # (the entry's run_fnptr is monomorphized per-Task by the
        # producer; Worker stays type-erased).
        var n_drained = self.drain_task_queue(MAX_DRAIN_PER_ITER)

        # Step 2 — Flush pending submissions (kqueue changelist batching
        # surface; epoll no-op since Reactor.submit /
        # register_long_lived issue inline EPOLL_CTL_ADD/MOD).
        self.flush_pending_submissions()

        # Step 3 — Poll reactor for completions.
        # transition shape: poll_completions returns a List
        # WITHOUT firing per-completion dispatch (the dispatch is the
        # Worker's job per the per-worker-pending-ops design). The
        # sink-fire path inside poll_completions remains a benign
        # backward-compat shim (existing callers that read
        # Reactor.is_ready see the same readiness signal).
        var completions = self._io_subsystem.reactor().poll_completions(
            timeout_us,
        )

        # Step 4 — Per-completion dispatch to the state-machine ready-cache.
        var n_completions = len(completions)
        for i in range(n_completions):
            self._dispatch_completion(completions[i])

        var n_total = n_drained + n_completions
        var finished_ns = Int64(perf_counter_ns())
        self._stall_detector.task_finished(iter_id, finished_ns)
        if n_total > 0:
            self._imbalance_metrics.record_n_tasks_completed(Int64(n_total))
        self._iter_count = self._iter_count + UInt64(1)
        return n_total

    def run_until_shutdown(mut self) raises:
        """Worker_main loop body (eventfd spin-park). Runs
        synchronously until signal_shutdown() is called.

        Per-iteration shape:

          1. **Spin phase (bounded)** — up to SPIN_LIMIT iterations of:
             - Drain up to MAX_DRAIN_PER_ITER MPSC entries.
             - Non-blocking IO poll via run_once(Int32(0)) — picks up
               any short-lived IO ops without sleeping.
             - On any work observed: short-circuit (skip park).
             - Otherwise: pause_intrinsic() (CPU hint; no syscall on x86,
               sched_yield fallback on aarch64).

          2. **Park phase** — blocking epoll_wait(timeout=-1). Wakes on:
             - Eventfd write from any producer (MPSC enqueue) via the
               OP_ID_WAKE_EVENTFD-routed event in Reactor.run_once.
             - Any registered IO fd becoming ready.
             - Shutdown signal (which writes to our own eventfd via
               Worker.signal_shutdown's call to reactor().wake_self()).

          3. **Post-park drain** — pick up any MPSC entries that landed
             since the last drain; the eventfd was drained inside
             run_once.

        Self-wake fallback: if the post-park drain returns
        MAX_DRAIN_PER_ITER (saturated), self-wake via reactor().wake_self()
        so the next iteration's epoll_wait returns immediately. Belt-and-
        suspenders for the burst-then-pause case where the eventfd
        counter has been drained but more entries are still in the ring.

        On shutdown: drain any remaining enqueued task entries before
        exiting (semantics: shutdown waits for in-flight to settle).
        """
        # Bracket each iteration with the stall detector hooks
        # (observability). Iter id == _iter_count.
        #
        # The spin + park phases use the
        # completion-queue shape. Both phases call poll_completions
        # (timeout_us=0 in spin, PARK_TIMEOUT_US in park) and dispatch
        # each Completion via _dispatch_completion → state-machine
        # _ready_cache.
        # SCHED-TRACE: cached Bool — the OFF loop pays one cold
        # branch per iteration, no perf_counter_ns / external_call.
        var _sched_on = self._sched_accum.enabled
        while not self.is_shutdown_signaled():
            # Flush this worker's absolute accumulators to the process-global C
            # slot at the TOP of each iteration (captures the prior iteration
            # regardless of the `continue` fast-paths below); a final flush after
            # the loop captures the last iteration.
            if _sched_on:
                self._sched_accum.store(UInt64(self._worker_id))
            var iter_id = Int64(self._iter_count)
            var started_ns = Int64(perf_counter_ns())
            self._stall_detector.task_started(iter_id, started_ns)

            # --- Spin phase (bounded) ---
            #
            # Redesigned: the per-iter `Reactor.poll_completions(0)`
            # call dominates wall on an Apple M3 Ultra (~12 µs / call for the
            # kevent(0) syscall; ~1-3 µs on Linux x86 epoll_wait(0)).
            # At SPIN_LIMIT=64 × 12 µs/iter = ~770 µs of wall (entirely
            # syscall) — far in excess of IO-class 390 µs inter-
            # dispatch gaps, so workers parked between dispatches and
            # `wake_with_elision` missed every time.
            #
            # kevent guard: fire kevent / epoll_wait only on every 64th
            # iter (`(spun & 0x3F) == 0`, mod-64 via cheap power-of-2
            # mask — must NOT use `%`, which lowers to udiv on aarch64).
            # Worst-case observation latency of an IO completion bumps
            # from ~12 µs (1 spin iter) to ~64 × ~2 ns (atomic loads) +
            # 1 × ~12 µs (the next kevent) ≈ ~12.13 µs. Practically
            # indistinguishable. SPIN_LIMIT was bumped 64 → 8192 in
            # tandem (see comment on the constant above): per-iter cost
            # is now ~2 ns steady-state, so the spin window covers up
            # to ~16 µs CPU per parked window + amortized ~190 ns/iter
            # of kevent — total ~1.5 ms of inter-dispatch coverage at
            # negligible idle-CPU floor.
            #
            # `pause_intrinsic()` on aarch64 calls `sched_yield`
            # (~90 ns syscall, verified empirically) — not what we want
            # in a 2 ns/iter spin window. Skipped on aarch64; kept on
            # x86 where it lowers to a 5 ns `_mm_pause` CPU hint.
            var spun: Int = 0
            var n_drained: Int = 0
            var n_completions_spin: Int = 0
            var found_work_in_spin: Bool = False
            # Adaptive spin — snapshot the per-worker adaptive cap
            # ONCE at window entry so the in-flight window sees a stable
            # bound. The cap may have been adjusted by the prior window's
            # _on_found_work_in_spin / _on_empty_spin_window call.
            var spin_limit_this_window = self._spin_limit
            # Adaptive spin — mark spin window start. Used by
            # _on_found_work_in_spin to compute the spin wall (=
            # how long did we spin before catching work?). Lower spin
            # wall = COMPUTE tier; higher wall = IO tier.
            self._on_spin_window_start()
            # SCHED-TRACE: bracket the spin-window wall. An EMPTY
            # window (no work found) is bucket (d) CPU-burn; attributed at the
            # `_on_empty_spin_window` site below.
            #
            # PRODUCTIVE-SPIN BLIND SPOT:
            # a window that runs and THEN catches work used to fall through the
            # `continue` below WITHOUT touching any accumulator, so its burn was
            # invisible in every bucket. `_spin_busy0` snapshots the busy
            # accumulators at window entry; the found-work arm subtracts the delta
            # so bucket (e) records only the SPIN residue, never the drain-pop /
            # handle.run wall that buckets (c) / useful already own.
            var _spin_w0: UInt64 = UInt64(0)
            var _spin_busy0: UInt64 = UInt64(0)
            if _sched_on:
                _spin_w0 = UInt64(perf_counter_ns())
                _spin_busy0 = (
                    self._sched_accum.pop_ns + self._sched_accum.run_ns
                )
            while spun < spin_limit_this_window:
                # Check shutdown inside the spin too — tight latency.
                if self.is_shutdown_signaled():
                    break
                n_drained = self.drain_task_queue(MAX_DRAIN_PER_ITER)
                if n_drained > 0:
                    found_work_in_spin = True
                    break
                # conditional kevent guard: kevent every 64th iter.
                # The `& 0x3F` mask is mod-64 via power-of-2 trick
                # (UInt-equivalent on Int; spun is non-negative).
                if (spun & 0x3F) == 0:
                    self._spin_kevent_call_count = (
                        self._spin_kevent_call_count + UInt64(1)
                    )
                    var completions = self._io_subsystem.reactor().poll_completions(
                        Int32(0),
                    )
                    n_completions_spin = len(completions)
                    if n_completions_spin > 0:
                        for i in range(n_completions_spin):
                            self._dispatch_completion(completions[i])
                        found_work_in_spin = True
                        break
                # CPU pause hint. On x86 this is `_mm_pause` (~5 ns hint).
                # On aarch64 the fallback is `sched_yield` (~90 ns syscall) —
                # despite the syscall cost, the cooperative yield IS useful
                # under heavy contention (32 workers spinning on shared
                # CPU resources) where tight uncooperative spinning
                # causes wall regressions on heavy benches like Q5.
                # Empirical sweep dropping the aarch64
                # branch caused a +6.7% wall regression on an M3 Ultra;
                # keeping the yield restored the baseline.
                pause_intrinsic()
                spun = spun + 1

            if found_work_in_spin:
                # Adaptive spin — observed-work sample point.
                # Update EWMA + reset empty-window counter + recompute
                # spin_limit for the next window. Called BEFORE
                # observability bookkeeping so the EWMA captures
                # dispatch-to-dispatch wall, not wall-after-bookkeeping.
                self._on_found_work_in_spin()
                # Drained from spin path; record observability + loop
                # back into spin without parking.
                var n_total = n_drained + n_completions_spin
                var finished_ns = Int64(perf_counter_ns())
                self._stall_detector.task_finished(iter_id, finished_ns)
                if n_total > 0:
                    self._imbalance_metrics.record_n_tasks_completed(
                        Int64(n_total),
                    )
                # close the productive-spin blind spot. Window wall minus
                # the busy (drain-pop + handle.run) wall that advanced inside it =
                # the SPIN burn that preceded the catch. Saturating subtract: the
                # busy delta can nominally exceed the window wall by a counter tick
                # since `finished_ns` is sampled after the accumulators.
                if _sched_on:
                    var _spin_w = UInt64(finished_ns) - _spin_w0
                    var _spin_busy = (
                        self._sched_accum.pop_ns + self._sched_accum.run_ns
                    ) - _spin_busy0
                    if _spin_w > _spin_busy:
                        self._sched_accum.spin_found_ns += (
                            _spin_w - _spin_busy
                        )
                    self._sched_accum.found_windows += UInt64(1)
                self._iter_count = self._iter_count + UInt64(1)
                continue

            # Adaptive spin — empty-window sample point. The spin
            # loop ran to completion without observing any work; bump
            # the consecutive-empty-window counter and force tier-down
            # if it hits EMPTY_WINDOW_K. This is the ONLY adaptation
            # path that fires for workers that never see work in a
            # run (e.g. the idle workers of a narrow fan-out).
            self._on_empty_spin_window()
            # SCHED-TRACE: this spin window found NO work — its wall
            # is bucket (d) spin-poll CPU-burn.
            if _sched_on:
                self._sched_accum.spin_ns += (
                    UInt64(perf_counter_ns()) - _spin_w0
                )
                self._sched_accum.empty_windows += UInt64(1)
                # EMPTY-WINDOW CAUSALITY. Sample the on-pool
                # dispatch depth at window CLOSE and partition the count by it —
                # the same (a)/(b) discriminator the park below already applies to
                # the park WALL, so the count and wall views are directly
                # comparable. depth==0: nothing is dispatched anywhere, so this
                # worker is starved by the single-threaded DRIVER's serial region
                # (real starvation, fix upstream). depth>0: a fork IS live, so
                # work exists in the system but not in THIS worker's queue — the
                # spin loop drains only its own queue and never steals.
                # Cost: one relaxed C load per EMPTY window, trace-ON only, on the
                # about-to-park path — the park immediately below makes the same
                # call. Zero on the OFF path (the `_sched_on` field gate).
                if sched_trace_pool_depth() > Int64(0):
                    self._sched_accum.empty_intra_w += UInt64(1)
                else:
                    self._sched_accum.empty_inter_w += UInt64(1)

            # komira_log P2b + — cooperative per-core log drain.
            # We just spun out a full window with NO query/IO work, so this
            # worker is idle and about to park: the right moment to drain its
            # OWN per-core ring (the SPSC consumer side). The ring has EXACTLY
            # ONE consumer (this worker's thread), so the text-render drain and
            # the native-index hook are MUTUALLY EXCLUSIVE — whichever is wired
            # consumes the records; running both would split/lose records across
            # two consumers of the same SPSC ring.
            #
            # When a EngineContext has installed the native-index hook, the
            # INDEX path IS the drain consumer (drain -> transpose -> build cheap
            # L0 -> CAS-publish, so drained logs become searchable AS THEY LAND),
            # reached through the carried handle (NO launder). the
            # else-branch `_drain_log_ring()` (the `log_engine_ref()` env-var
            # idle-drain) is DELETED — with no native-index hook the per-context
            # engine drains at `flush_log_engine` instead of per-idle.
            if self._idle_hook:
                self._fire_idle_hook()

            # --- Park phase ---
            # Re-check shutdown one more time before parking (spin loop
            # could have completed without setting found_work_in_spin
            # if shutdown was signaled mid-spin).
            if self.is_shutdown_signaled():
                break

            # + wake elision park-bracket:
            # SET _sleeping=1 BEFORE epoll_wait so producers can read the
            # flag and skip the wake when we're awake. Drepper-style
            # lost-wakeup-safe: AFTER setting _sleeping=1, RE-CHECK both
            # pending sources (MPSC + reactor non-blocking poll). If
            # either has work, CLEAR _sleeping=0 and skip the park.
            #
            # Bare-form atomic store via the typed _SleepingFlag.store()
            # (maps to seq_cst on x86 / STLR on ARM — sufficient for the
            # release-publish ordering this step needs).
            self._sleeping_arc[].store(Int32(1))
            # Re-check MPSC non-destructively (a quick non-blocking poll
            # of the queue's empty status would be ideal; for now we
            # do a single-entry try_recv and re-enqueue if hit — but
            # MpscReceiver lacks peek. Practical alternative: do a
            # bounded drain pass; if any drained, clear the flag and
            # spin instead of parking).
            var post_set_drain = self.drain_task_queue(MAX_DRAIN_PER_ITER)
            var post_set_completions = self._io_subsystem.reactor().poll_completions(
                Int32(0),  # non-blocking
            )
            var n_post_set = len(post_set_completions)
            for i in range(n_post_set):
                self._dispatch_completion(post_set_completions[i])
            # --- THE LOST-WAKEUP HOLE ---
            #
            # `poll_completions` DRAINS the wake-eventfd channel and does NOT
            # surface it as a completion (reactor.mojo: "eventfd wake event —
            # drain only"). So the non-blocking poll above is a TOKEN EATER, and
            # it runs AFTER the MPSC re-check. That leaves a window:
            #
            #   1. worker: _sleeping = 1
            #   2. worker: drain_task_queue()      -> empty
            #   3. producer: enqueue shard; fence; load _sleeping == 1
            #               -> issues the eventfd_write (correctly! no elision)
            #   4. worker: poll_completions(0)     -> EATS that token, surfaces 0
            #   5. worker: post_set_drain == 0 and n_post_set == 0
            #               -> PARKS on PARK_TIMEOUT_US == -1, i.e. FOREVER,
            #                  with a task sitting in its MPSC queue
            #
            # The Drepper re-check was there, but the token eater was ordered
            # after it, so the protocol's back-stop did not actually back-stop.
            #
            # Consequence, and why this is the dispatch-ctx bug's root: that
            # shard's `in_flight` charge is never released, so
            # `LocalDispatcher._drain_in_flight_barrier` waits forever. Before
            # the generation guard, a spurious decrement from an unrelated leaked handle could
            # release that stuck barrier — letting the driver return and pop the
            # frame while the never-woken shard was still queued, to run later
            # against a recycled `_shard_buf` slot. That is exactly the
            # 19-of-20-slots-live / 1-slot-stale core dump. One defect, two
            # faces: a HANG when nothing unsticks the barrier, a UAF SIGSEGV
            # when something does.
            #
            # Fix: re-drain the MPSC AFTER the token eater. Nothing between this
            # drain and the blocking park can consume a wake token, so a producer
            # that enqueues past this point either is seen here or lands its
            # eventfd write on the blocking poll. Costs one extra `try_recv` on
            # the park path only. Do NOT reorder this above `poll_completions`.
            var post_poll_drain = self.drain_task_queue(MAX_DRAIN_PER_ITER)
            if post_set_drain > 0 or n_post_set > 0 or post_poll_drain > 0:
                # Found work after the flag set: clear flag, do NOT park.
                self._sleeping_arc[].store(Int32(0))
                var n_total_recheck = post_set_drain + n_post_set + post_poll_drain
                var finished_recheck_ns = Int64(perf_counter_ns())
                self._stall_detector.task_finished(iter_id, finished_recheck_ns)
                if n_total_recheck > 0:
                    self._imbalance_metrics.record_n_tasks_completed(
                        Int64(n_total_recheck),
                    )
                self._iter_count = self._iter_count + UInt64(1)
                continue

            # The same hole for the shutdown flag. `signal_shutdown` stores
            # the flag, then writes the eventfd. A signal that lands between
            # the flag check above (before `_sleeping = 1`) and the
            # non-blocking poll has its eventfd write eaten by that poll, so
            # nothing would wake the blocking park below: the worker would
            # park FOREVER with the flag set, and the runtime's shutdown /
            # destructor would hang in pthread_join. The flag store precedes
            # the write that the poll consumed, so it is visible here; a
            # signal after this check lands its write on the blocking poll.
            # Do NOT move this check above `poll_completions(0)`.
            # (tests/test_worker_shutdown_park_race.mojo aims at the window;
            # under a coverage run, test_epoll_cycle_regression hung here.)
            if self.is_shutdown_signaled():
                self._sleeping_arc[].store(Int32(0))
                break

            # SCHED-TRACE: the blocking park is the idle wall. Read
            # the on-pool dispatch depth at park entry as the (a)/(b)
            # discriminator: depth==0 -> inter-segment barrier (a); depth>0 ->
            # intra-segment straggler (b).
            var _park_t0: UInt64 = UInt64(0)
            var _park_depth: Int64 = Int64(0)
            if _sched_on:
                _park_t0 = UInt64(perf_counter_ns())
                _park_depth = sched_trace_pool_depth()

            # Blocking poll. Wakes on eventfd, IO event, or EINTR.
            # poll_completions internally drains the wake-eventfd channel
            # and surfaces only IO/timer/etc completions to dispatch.
            var park_completions = self._io_subsystem.reactor().poll_completions(
                PARK_TIMEOUT_US,
            )
            if _sched_on:
                var _park_dt = UInt64(perf_counter_ns()) - _park_t0
                if _park_depth > Int64(0):
                    self._sched_accum.park_intra_ns += _park_dt
                else:
                    self._sched_accum.park_inter_ns += _park_dt
            # step 5: CLEAR _sleeping=0 IMMEDIATELY after
            # epoll_wait returns. Order: clear flag BEFORE dispatching
            # completions so any nested producer wake during dispatch
            # will fall through to the awake path (no elision); we don't
            # want to be marked sleeping while we're processing.
            self._sleeping_arc[].store(Int32(0))
            var n_woke = len(park_completions)
            for i in range(n_woke):
                self._dispatch_completion(park_completions[i])

            # Post-park drain: pick up any MPSC entries enqueued just
            # before the producer's eventfd write (or any dispatch-side
            # follow-up enqueues from completed coros).
            var n_post = self.drain_task_queue(MAX_DRAIN_PER_ITER)

            # self-wake fallback: if drain saturated at
            # MAX_DRAIN_PER_ITER, more entries may be pending. Self-wake
            # so the next iter's epoll_wait returns immediately. Cheap
            # (one eventfd_write); covers burst-then-pause edge case.
            if n_post == MAX_DRAIN_PER_ITER:
                self._io_subsystem.reactor().wake_self()

            # Observability: count this park-iteration's work.
            var n_total_park = n_woke + n_post
            var finished_park_ns = Int64(perf_counter_ns())
            self._stall_detector.task_finished(iter_id, finished_park_ns)
            if n_total_park > 0:
                self._imbalance_metrics.record_n_tasks_completed(
                    Int64(n_total_park),
                )
            self._iter_count = self._iter_count + UInt64(1)

        # Final drain: pick up any entries enqueued just before the
        # shutdown flag was observed. We pass a large bound so the loop
        # exits when the queue empties (vs after MAX_DRAIN_PER_ITER).
        _ = self.drain_task_queue(max_drain=Int(0x7FFFFFFF))
        # SCHED-TRACE: final flush of this worker's accumulators.
        if _sched_on:
            self._sched_accum.store(UInt64(self._worker_id))
