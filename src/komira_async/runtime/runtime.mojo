# =============================================================================
# komira_async.runtime.runtime — PerCoreAsyncRuntime[S]
# =============================================================================
#
#
# N pinned per-core workers, each a complete async universe. No worker
# migration. No work-stealing. No AIMD K-control. Each worker owns its own
# reactor, task queue, timer wheel, connection set, and cancellation tree.
# Cross-worker is rare, explicit, via SPSC channels (audit findings 1, 3).
#
# Audit references: Seastar threading; settled-law primitives;
# recommendations 1-2 (per-core threading + per-core reactor).
#
# multi-worker storage:
#   * `_workers: Slab[OwnedPointer[Worker[Self.S]]]` — N workers, each at a
#     stable heap address (OwnedPointer wrap), held in the destroy-recreate-safe Slab
#     primitive. Capacity bounded by `MAX_WORKERS_PHASE_1A = 4` for a
#     bench gate; the implementation does NOT hard-cap (callers may pass a
#     larger N, in which case the slab grows geometrically).
#   * `_thread_ids: Slab[Int64]` — parallel POD slab holding the
#     pthread_t handle for each worker. Slab[Int64] is destroy-recreate-safe (Int64
#     is POD; no heap-owning inner field).
#   * `attach_workers(n, sink_factory, backend)` — push N
#     OwnedPointer[Worker[S]] entries, one per call to sink_factory.
#   * `attach_worker(var sink, backend)` — convenience shim that pushes a
#     single Worker (n=1 case), used by much of the
#     existing test/leak/integration corpus.
#   * `start()` — launches N pthreads via existing `launch_worker_pthread`
#     (the heap-arg laundering pattern). Each worker's heap-stable
#     address is extracted from the `OwnedPointer` slot; the pthread
#     holds an FFI-laundered Int(addr) for its lifetime. Drop ordering
#     guarantees the Worker outlives the pthread (shutdown signals all +
#     joins all BEFORE the slab drops).
#   * `shutdown()` — signal_shutdown_all + join all N pthreads. Idempotent.
#
# follow-on (NOT in this commit) — the four trait
# accessors stay as stubs that raise:
#   * dispatcher() — LocalDispatcher façade
#   * spawner() — LocalSpawner façade
#   * io_block() — LocalIoBlock façade
#   * shutdown_token() — CancellationToken
#
# Pointer discipline:
#   * Public API: ZERO `UnsafePointer`, ZERO wildcard origins.
#   * Internal: `OwnedPointer[Worker[S]]` for stable heap address;
#     `Slab[OwnedPointer[Worker[S]]]` for multi-worker storage (safe across destroy-recreate
#     per `lint_byteslab_heap_inner.sh` rules — OwnedPointer is the
#     POD 8-byte handle wrap that makes the slab safe).
#   * The single FFI carve-out (`unsafe_from_address=Int` in
#     `pthread_worker.mojo`) stays untouched (audited; documented in
#     `pthread_worker.mojo`'s SAFETY block).
# =============================================================================

from std.memory import OwnedPointer

from komira_async.cancellation.token import CancellationToken
from komira_async.channel.mpsc import (
    MpscReceiver,
    MpscSender,
    channel as mpsc_channel,
)
from komira_async.ops.waker_sink import WakerSink
from komira_async.runtime.runtime_trait import (
    MODEL_SHARE_NOTHING_PER_CORE,
    Runtime,
)
from komira_async.runtime.local_dispatcher import LocalDispatcher
from komira_async.runtime.local_io_block import LocalIoBlock
from komira_async.runtime.pthread_worker import (
    ROLE_COMPUTE,
    ROLE_IO,
    join_worker_pthread,
    launch_worker_pthread,
)
from komira_async.runtime.idle_hook import _IdleHookSlot
from komira_async.runtime.shared_erasure import ErasedHandle
from komira_async.runtime.worker import Worker
from komira_async.spawner.local_spawner import LocalSpawner
from komira_core.collections.slab import Slab
from komira_core.runtime.engine_placement import EnginePlacement


# Default per-worker MPSC channel capacity. Power of 2 (Vyukov ring index
# masking requirement). 1024 entries gives generous headroom for burst
# enqueues from the dispatcher's per-shard fan-out (≤ N_WORKERS) plus the
# spawner's typical batch-spawn cardinality. Producers observe TRY_SEND_FULL
# on overflow and are expected to back off + retry — the dispatcher's
# enqueue path retries with cpu_pause + the spawner's path raises
# a typed Error so the call site can implement its own back-pressure.
comptime TASK_QUEUE_CAPACITY: UInt = 1024


# Placement policy.
# UInt8 sentinel; a later step may promote it to a proper variant struct.
comptime PLACEMENT_FIXED: UInt8 = 0
comptime PLACEMENT_MAX_SPREAD: UInt8 = 1
comptime PLACEMENT_MAX_PACK: UInt8 = 2


comptime MAX_WORKERS_PHASE_1A: Int = 4


# Compute/IO hyperthread split — the "no IO lane attached" sentinel for
# `_io_lane_start`. A very large value means every attached worker is a COMPUTE
# worker (the pre-Part-B single-lane shape). `attach_io_workers` overwrites it
# with the compute-lane size at the moment the IO lane is first attached.
comptime NO_IO_LANE: Int = (1 << 62)


def _runtime_teardown_join[
    S: WakerSink & Movable & Deinitable,
](
    mut workers: Slab[OwnedPointer[Worker[S]]],
    mut thread_ids: Slab[Int64],
):
    """Teardown helper — out-of-line helper for the
    `__del__` shutdown path.

    Signals shutdown to every worker, then pthread_joins every thread.
    Refactored into a free function (NOT a `mut self` method) so that
    `__del__(deinit self)` can drive teardown without re-entering a
    `mut self` method on `self`. Empirically this eliminates the EPOLL
    teardown-cycle tcmalloc corruption that fired when the same logic
    was inlined into `__del__` (see commentary in
    `PerCoreAsyncRuntime.__del__`).

    Both arguments are taken `mut` (not `var` — we do NOT consume the
    slabs; the caller's destructor still runs the field-drops afterward
    in declaration order).

    Errors are SWALLOWED: this is a destructor helper that cannot raise.
    pthread_join rc is ignored (ESRCH on already-exited threads is
    benign; matches the explicit `shutdown()` contract).
    """
    var nw = workers.len()
    var wi = 0
    while wi < nw:
        workers[wi][].signal_shutdown()
        wi = wi + 1
    var nt = thread_ids.len()
    var ti = 0
    while ti < nt:
        var rc = join_worker_pthread(thread_ids[ti])
        _ = rc
        ti = ti + 1


struct PerCoreAsyncRuntime[
    S: WakerSink & Movable & Deinitable,
](Runtime, Movable, Deinitable):
    """N pinned per-core workers, each a
    complete async universe.

    multi-worker storage:
      * `_workers: Slab[OwnedPointer[Worker[Self.S]]]` — N OwnedPointer
        slots, each pointing at a heap-stable Worker. Slab[OwnedPointer[T]]
        is safe across destroy-recreate (the slab element is a POD 8-byte handle; the
        Worker's heap-owning inner fields live BEHIND the OwnedPointer,
        not in the slab's bitcast'd byte buffer).
      * `_thread_ids: Slab[Int64]` — parallel slab of pthread_t handles
        (one per worker; written by `launch_worker_pthread`, consumed by
        `join_worker_pthread`). Slab[Int64] is POD; no destroy-recreate hazard.
      * `_placement: UInt8` — placement policy (FIXED / MAX_SPREAD /
        MAX_PACK).
      * `_started: Bool` — runtime-wide flag; True between `start()` and
        `shutdown()`.
      * `_shutdown_done: Bool` — set True by `shutdown()` after a
        successful join cycle. The RAII `__del__` consults this flag so
        a caller's explicit `shutdown()` is not double-shut at scope
        exit. Also set False by `start()` on a fresh dispatch cycle so
        `shutdown()` is exactly once per `start()`.

    Single-worker (n=1) is a special case of multi-worker; the Phase
    1.9.4 `attach_worker` shim stays for back-compat with the existing
    test / leak / integration corpus.

    Two construction modes:
      1. **RAII (default user path)**:

         ```mojo
         var rt = PerCoreAsyncRuntime[NoopSink](
             num_workers=4,
             sink_factory=_my_sink_factory,
             backend=BACKEND_EPOLL,
             placement=PLACEMENT_FIXED,
         )
         # ...use rt.dispatcher() / rt.spawner() / rt.io_block()...
         # rt drops at scope exit -> __del__ signals shutdown + joins all
         # pthreads automatically.
         ```

         Mirrors tokio's `Runtime::new()` ergonomics: construction
         starts the workers and scope exit stops them (RAII).

      2. **Deferred-start (advanced placement / lifecycle tests)**:

         ```mojo
         var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
         rt.attach_workers(N, factory, backend)
         rt.start()
         # ...
         rt.shutdown()
         ```

         Use this mode when you need to interpose between
         `attach_workers` and `start` (e.g. lifecycle-correctness
         tests that verify `start()` raises with zero workers, or
         placement strategies that pick affinity per-worker after
         attach). Existing tests and the bench harness still use this
         mode — it remains supported indefinitely.

    Both modes share the same `__del__` contract: dropping the runtime
    at any point is safe and idempotent. If `_started == False` (never
    started, or already cleanly shut down) the destructor is a no-op
    over the worker storage. If `_started == True` and `_shutdown_done
    == False`, the destructor signals shutdown to every worker and
    joins every pthread before the slabs drop (which would otherwise
    deallocate the Workers out from under the still-running pthreads).
    """

    # Field-drop ordering (prevents an fd-reuse race).
    # Producers (_dispatcher, _spawner, _io_block) MUST drop BEFORE
    # _workers so the WorkerWakeHandle slabs are deallocated BEFORE
    # any Reactor's eventfd is closed. Otherwise a stale producer-side
    # WorkerWakeHandle could write to a closed fd that has been reused
    # for an unrelated file. Mojo's field-drop order is REVERSE
    # declaration order, so producers are declared FIRST.
    #
    # IMPORTANT: pthread join (via _runtime_teardown_join) runs in
    # __del__ BEFORE any field drop, so worker pthreads are already
    # joined when this drop sequence starts; the reorder is purely
    # about eliminating the producer→consumer fd-reuse race window.
    # Runtime trait conformance — comptime associated members.
    # The Sink is the type parameter S; PerCoreAsync is the share-nothing
    # per-core runtime; its workers are thread-pinned (no migration).
    comptime Sink = Self.S
    comptime RUNTIME_MODEL: UInt8 = MODEL_SHARE_NOTHING_PER_CORE
    comptime TASKS_ARE_THREAD_PINNED: Bool = True

    var _dispatcher: LocalDispatcher[Self.S]
    var _spawner: LocalSpawner[Self.S]
    var _io_block: LocalIoBlock[Self.S]
    var _worker_senders: Slab[OwnedPointer[MpscSender[ErasedHandle]]]
    # the IO-lane senders.
    # Distinct from `_worker_senders` (the COMPUTE lane registered with the
    # dispatcher / spawner): IO-lane senders are NOT registered with the
    # dispatcher, so the fork-join `run_with_state` shard set is COMPUTE-only
    # (the load-bearing 4-path-independence + barrier-accounting invariant —
    # design). Declared AFTER `_worker_senders` so it drops in the
    # same producer-before-_workers window (the WorkerWakeHandle fd-reuse race
    # guard) — both producer-side sender slabs drop before _workers.
    var _io_worker_senders: Slab[OwnedPointer[MpscSender[ErasedHandle]]]
    var _thread_ids: Slab[Int64]
    var _workers: Slab[OwnedPointer[Worker[Self.S]]]
    var _placement: UInt8
    # slab index at which the IO lane begins. Workers [0, _io_lane_start)
    # are the COMPUTE lane (pinned to engine_compute_cpus()[i], sharded by
    # run_with_state); workers [_io_lane_start, len) are the IO lane (pinned to
    # engine_io_cpus()[i - _io_lane_start], NOT in the fork-join shard set).
    # Defaults to a large sentinel meaning "no IO lane" (all workers compute);
    # set to the current compute count by `attach_io_workers`.
    var _io_lane_start: Int
    var _started: Bool
    var _shutdown_done: Bool
    # the per-context log engine's pthread TLS key (0 == none),
    # threaded into every Worker at attach so the pthread entry binds worker_id
    # WITHOUT the `log_engine_ref()` launder. Set at construction (before
    # attach + pthread launch). POD scalar.
    var _log_tls_key: UInt64
    # Worker CPU placement (pin / NUMA confinement), handed to every worker
    # pthread at `start()`. The default `EnginePlacement()` pins nothing.
    var _engine_placement: EnginePlacement

    def __init__(
        out self,
        placement: UInt8,
        log_tls_key: UInt64 = UInt64(0),
        engine_placement: EnginePlacement = EnginePlacement(),
    ):
        """Deferred-start runtime — empty constructor.

        Primarily for tests + advanced placement scenarios. Default
        users should prefer the
        `__init__(num_workers, sink_factory, backend, placement)`
        overload for RAII semantics (no manual `attach_workers + start
        + shutdown` ceremony required).

        Use attach_worker / attach_workers to install workers; then
        start() to launch their pthreads.

        `_dispatcher`, `_spawner`, and `_io_block` are stored façades per
        the parametric-origin-return pattern. Their accessors return
        `ref [self._dispatcher] LocalDispatcher[Self.S]`,
        `ref [self._spawner] LocalSpawner[Self.S]`, and
        `ref [self._io_block] LocalIoBlock[Self.S]` respectively.
        Storing the façades gives them stable heap addresses (via their
        internal OwnedPointer[Atomic[..]] state on dispatcher/io_block
        and the per-spawn slot/token heap homes inside the spawner's
        slab) for the runtime's lifetime — required for any future
        reactor-driven wake-word signaling, for the LocalDispatcher's
        per-dispatch wake-word, and for the LocalSpawner's cross-pthread
        enqueue/drain wake-word.

        It also owns `_worker_senders` — one
        MpscSender per attached worker, used by the dispatcher /
        spawner enqueue paths. The senders are produced at attach time
        (the matching MpscReceiver is moved into the Worker's
        `_task_queue`); the dispatcher / spawner clone senders into
        their own per-call enqueue helpers.
        """
        self._workers = Slab[OwnedPointer[Worker[Self.S]]]()
        self._thread_ids = Slab[Int64]()
        self._worker_senders = Slab[OwnedPointer[MpscSender[ErasedHandle]]]()
        self._io_worker_senders = Slab[
            OwnedPointer[MpscSender[ErasedHandle]]
        ]()
        self._dispatcher = LocalDispatcher[Self.S]()
        self._spawner = LocalSpawner[Self.S]()
        self._io_block = LocalIoBlock[Self.S]()
        self._placement = placement
        self._io_lane_start = NO_IO_LANE
        self._started = False
        self._shutdown_done = False
        self._log_tls_key = log_tls_key
        self._engine_placement = engine_placement

    def __init__(
        out self,
        num_workers: Int,
        sink_factory: def () thin -> Self.S,
        backend: UInt8,
        placement: UInt8 = PLACEMENT_FIXED,
        log_tls_key: UInt64 = UInt64(0),
        engine_placement: EnginePlacement = EnginePlacement(),
    ) raises:
        """RAII constructor — builds a fully-initialized + running
        runtime in one call.

        Equivalent to:

            var rt = PerCoreAsyncRuntime[S](placement=placement)
            rt.attach_workers(num_workers, sink_factory, backend)
            rt.start()

        Workers are attached and their pthreads launched before this
        returns. On scope exit the destructor signals shutdown +
        joins every pthread (no explicit `shutdown()` required).

        This mirrors tokio's `Runtime::new()` ergonomics (RAII).

        Construction-failure safety:
          * If `attach_workers` raises (e.g. malloc fail mid-loop), the
            partially-built runtime drops: `_started` is False, so
            `__del__` skips the join cycle; the slabs drop the workers
            already attached (no pthreads launched, no FFI lifetime
            hazard).
          * If `start()` raises (e.g. pthread_create fails for worker
            i, partial-launch case), `start()` already does best-effort
            rollback: it signals shutdown to the i-1 pthreads launched
            so far and joins them BEFORE re-raising. `_started` stays
            False through the failure (the assignment is the last line
            of `start()`); `__del__` therefore sees a fully cleaned-up
            runtime and is a no-op over the worker join cycle.

        Args:
          num_workers: N (≥ 0). N=0 builds a runtime with no workers
            (start() raises later if dispatch is attempted; matches
            the deferred-start path's contract). N=1 is a single-worker
            runtime; N ≥ 2 is multi-worker.
          sink_factory: Nullary fn () -> S returning a fresh sink per
            worker. Each worker gets its own sink (no sharing).
          backend: BACKEND_EPOLL / BACKEND_KQUEUE / BACKEND_MOCK
            (epoll fd allocation per worker on Linux; mock for tests
            avoids the fd allocation).
          placement: PLACEMENT_FIXED / PLACEMENT_MAX_SPREAD /
            PLACEMENT_MAX_PACK. Default FIXED (stable affinity).
        """
        # Initialize storage in the same shape as the empty ctor —
        # the field assignments must complete BEFORE attach_workers
        # so `__del__` is safe to run even if attach_workers raises
        # mid-loop.
        self._workers = Slab[OwnedPointer[Worker[Self.S]]]()
        self._thread_ids = Slab[Int64]()
        self._worker_senders = Slab[OwnedPointer[MpscSender[ErasedHandle]]]()
        self._io_worker_senders = Slab[
            OwnedPointer[MpscSender[ErasedHandle]]
        ]()
        self._dispatcher = LocalDispatcher[Self.S]()
        self._spawner = LocalSpawner[Self.S]()
        self._io_block = LocalIoBlock[Self.S]()
        self._placement = placement
        self._io_lane_start = NO_IO_LANE
        self._started = False
        self._shutdown_done = False
        # set BEFORE attach_workers so each Worker is built with the
        # engine's TLS key and the pthread entry binds without the launder.
        self._log_tls_key = log_tls_key
        self._engine_placement = engine_placement
        # Attach + start. If attach_workers raises, the partially-built
        # slab drops cleanly via __del__ (no pthreads launched yet;
        # _started=False, so no join cycle).
        if num_workers > 0:
            self.attach_workers(num_workers, sink_factory, backend)
            # Launch pthreads. start() does its own best-effort rollback
            # on partial-launch failures; on success _started is set
            # True and __del__ will signal+join on scope exit.
            self.start()

    def __deinit__(deinit self):
        """RAII shutdown — auto-signal + join on scope exit.

        Idempotent. Three states:
          1. `_started == False` (never started, or empty runtime):
             no pthreads to join; slabs drop cleanly. No-op.
          2. `_started == True` AND `_shutdown_done == True` (caller
             explicitly called `shutdown()` already): no-op. Avoids
             double-join (pthread_join on an already-joined handle is
             undefined behavior in some pthread impls; ESRCH on Linux
             but not portable).
          3. `_started == True` AND `_shutdown_done == False`: signal
             shutdown to every worker, join every pthread. This is the
             RAII fast path — caller went out of scope without an
             explicit shutdown.

        Ordering invariant: pthreads MUST be joined before the
        `_workers` / `_worker_senders` slabs drop. Otherwise the
        worker pthreads could observe their Worker[S] memory free'd
        mid-iteration (the FFI-laundered `Int(addr)` they hold becomes
        stale). The destructor drops fields in declaration order; we
        complete the join cycle here BEFORE the slab fields' implicit
        drops fire.

        Cannot raise (Mojo destructors are noexcept). pthread_join
        rc is ignored — same contract as the explicit `shutdown()`
        method (ESRCH on already-exited threads is benign).
        """
        # Teardown:
        # ----------------------------------------------------------------
        # Empirically, doing the shutdown signal + pthread_join inline in
        # `__del__(deinit self)` triggers a non-deterministic tcmalloc heap
        # corruption on subsequent process-level allocations under
        # BACKEND_EPOLL with N>=2 workers. The crash signature is a tcmalloc
        # delete-path abort during a later `alloc()` call (typically the
        # `_PthreadArg` heap-alloc inside the next runtime's `start()`).
        #
        # Empirical evidence (a RAII cycle probe):
        #   * BACKEND_MOCK + RAII teardown:                 100/100 cycles.
        #   * BACKEND_EPOLL + N=1 + RAII teardown:          100/100 cycles.
        #   * BACKEND_EPOLL + N>=2 + INLINED RAII teardown: 2-3 cycles
        #                                                   before crash.
        #   * BACKEND_EPOLL + N>=2 + explicit shutdown()
        #     before drop:                                  100/100 cycles.
        #   * BACKEND_EPOLL + N>=2 + this fix
        #     (out-of-line free-fn helper):                 100/100 cycles.
        #
        # Symptom: the worker pthreads' `epoll_wait()` raises (the WARN
        # line `_worker_pthread_entry: run_until_shutdown raised:
        # epoll_wait() failed` is the diagnostic). The exception-unwind
        # path in the worker thread corrupts tcmalloc's per-thread cache,
        # and the corruption surfaces on the next process-level
        # allocation in the SECOND or THIRD ctor cycle.
        #
        # Mechanism (best understanding without compiler-internals
        # inspection): when `mut self` methods are dispatched on `self`
        # from inside `deinit self`, Mojo's destructor lowering appears
        # to interact differently with the optimizer's view of field
        # liveness vs. an equivalent `mut self`-method call from a
        # normal `mut self` site. The worker side observes a transient
        # state where `_shutdown_flag` reads zero (so the loop continues)
        # AND the underlying `epoll_fd` returns a wait-error — both at
        # the SAME moment as the destructor body is signaling+joining.
        # Pulling the signal+join logic out into a free function whose
        # arguments are explicit Slab references (NOT `mut self`)
        # eliminates whatever interaction `deinit self` has with
        # `mut self` method dispatch on `self` — and makes the test
        # deterministically green across all worker counts.
        #
        # Note: the explicit `shutdown(mut self)` API does NOT exhibit
        # the bug because it is invoked from a normal `mut self` site,
        # not from `deinit self`. By the time the destructor sees the
        # runtime, `_shutdown_done == True` and the body short-circuits.
        if self._started and not self._shutdown_done:
            _runtime_teardown_join(self._workers, self._thread_ids)
            # State updates are technically dead stores in `deinit self`
            # (no one reads them after this point) — `_ =` reads suppress
            # the dead-store warning without changing semantics.
            self._started = False
            self._shutdown_done = True
            _ = self._started
            _ = self._shutdown_done

    def _attach_one_worker(
        mut self, var sink: Self.S, backend: UInt8
    ) raises:
        """closure + eventfd spin-park — internal
        helper. Builds one channel pair, hands the receiver to a fresh
        Worker, stores the sender on the runtime, and pushes the new
        Worker into the slab. also extracts the worker's wake_handle
        (POD) and threads it through to the dispatcher / spawner via the
        new 2-arg `_register_worker_handle`.

        Called by both `attach_worker` and `attach_workers` so the
        channel-pair + wake-handle provisioning is in exactly one place.
        """
        var idx = self._workers.len()
        var pair = mpsc_channel[ErasedHandle](TASK_QUEUE_CAPACITY)
        var receiver = pair.take_receiver()
        var sender = pair.take_sender()
        # Worker takes the receiver; the sender is stored runtime-side
        # for the dispatcher / spawner to clone from.
        var worker = Worker[Self.S](
            UInt16(idx), sink^, backend, receiver^,
            log_tls_key=self._log_tls_key,
        )
        # step 5: extract the wake handle BEFORE moving the
        # worker into its OwnedPointer slot. wake_handle returns by
        # value; the underlying eventfd is owned by the worker's Reactor
        # (lifetime tied to the OwnedPointer slot below). The handle
        # carries a clone of the worker's `_sleeping_arc`.
        var wake_handle = worker.wake_handle()
        var owned_worker = OwnedPointer[Worker[Self.S]](value=worker^)
        self._workers.append(owned_worker^)
        self._thread_ids.append(Int64(0))
        var owned_sender = OwnedPointer[MpscSender[ErasedHandle]](
            value=sender^
        )
        self._worker_senders.append(owned_sender^)
        # step 5: wire a sender clone + a per-producer wake
        # handle clone into the dispatcher's and spawner's enqueue
        # handles. Each subsystem gets its OWN clone of the wake handle
        # (refcount-bumps the underlying ArcPointer<_SleepingFlag> per
        #) plus an independent sender clone (MpscSender.clone()
        # shares the underlying _MpscShared via ArcPointer).
        self._dispatcher._register_worker_handle(
            self._worker_senders[idx][].clone(),
            wake_handle.copy(),
        )
        self._spawner._register_worker_handle(
            self._worker_senders[idx][].clone(),
            wake_handle^,
        )

    def _attach_one_io_worker(
        mut self, var sink: Self.S, backend: UInt8
    ) raises:
        """Compute/IO hyperthread split — attach ONE IO-lane worker.

        Mirrors `_attach_one_worker` EXCEPT it does NOT register the worker's
        sender / wake handle with the dispatcher or spawner. This is the
        load-bearing firewall: the fork-join `run_with_state` shards across the
        dispatcher's `_worker_senders` ONLY (the COMPUTE lane), so an IO-lane
        worker that is absent from that set is NEVER handed a compute shard.
        The IO worker still:
          * goes into `_workers` + `_thread_ids` (so `start()` launches its
            pthread and `shutdown()` joins it — same lifecycle as a compute
            worker), and
          * has its sender stored in `_io_worker_senders` so a future
            prefetch-offload producer can post blocking-read tasks to it
            (the prefetch offload). Until that producer is wired the IO worker
            simply parks in its reactor loop (zero compute contention; it is
            pinned to a sibling hyperthread under `EnginePlacement.pin_workers`).

        Called only by `attach_io_workers`.
        """
        var idx = self._workers.len()
        var pair = mpsc_channel[ErasedHandle](TASK_QUEUE_CAPACITY)
        var receiver = pair.take_receiver()
        var sender = pair.take_sender()
        var worker = Worker[Self.S](
            UInt16(idx), sink^, backend, receiver^,
            log_tls_key=self._log_tls_key,
        )
        # The IO worker's wake handle IS taken and registered with
        # the dispatcher's IO-lane slab. It used to be DROPPED here, on the
        # premise that "the IO worker's own park/poll loop drains the queue" —
        # which is false: the park is `poll_completions(-1)`, i.e. INDEFINITE,
        # and `MpscSender.try_send*` signals nothing, so a posted prefetch was
        # not observed until `shutdown()`'s final drain. The producer still never
        # WAITS on the IO lane; it only SIGNALS it, exactly as the compute lane
        # does. See `LocalDispatcher._register_io_worker_handle`.
        var io_wake_handle = worker.wake_handle()
        var owned_worker = OwnedPointer[Worker[Self.S]](value=worker^)
        self._workers.append(owned_worker^)
        self._thread_ids.append(Int64(0))
        # IO-lane prefetch-offload: register a CLONE of the
        # IO sender into the dispatcher's SEPARATE `_io_senders` slab (NOT
        # `_worker_senders` — the firewall holds: `worker_count()` /
        # `run_with_state` shard ONLY across the compute lane). The clone lets
        # the spill/scan prefetch producer POST fire-and-forget blocking-read
        # tasks to the IO lane via `dispatcher.prefetch_to_io_lane` (design
        # the prefetch offload). The dispatcher's slab is the producer-reachable IO
        # surface; the runtime's `_io_worker_senders` retains the canonical
        # owner so the IO worker still gets its pthread + is joined on shutdown.
        self._dispatcher._register_io_worker_handle(
            sender.clone(), io_wake_handle^
        )
        var owned_sender = OwnedPointer[MpscSender[ErasedHandle]](
            value=sender^
        )
        # IO senders live in their OWN slab — NOT the dispatcher's shard set.
        self._io_worker_senders.append(owned_sender^)

    def attach_io_workers(
        mut self,
        n: Int,
        sink_factory: def () thin -> Self.S,
        backend: UInt8,
    ) raises:
        """Compute/IO hyperthread split — attach N IO-lane workers.

        The IO lane is a SEPARATE, smaller pool pinned (under
        `EnginePlacement.pin_workers`) to the sibling hyperthreads (`engine_io_cpus()`),
        to which blocking continuations (parquet prefetch faults / S3 GETs /
        spill IO) are steered so they do not stall a physical core's compute
        thread.

        Contract:
          * MUST be called AFTER all compute workers are attached and BEFORE
            `start()` (the IO lane is a tail of the worker slab; the compute
            count is frozen at the first IO attach).
          * Raises if called after `start()` (cannot grow the worker set once
            pthreads are launched — would invalidate launched workers' FFI
            addresses), or if no compute workers were attached first.
          * `n == 0` is a no-op (the non-SMT / IO-lane-disabled degenerate
            case — `engine_io_cpus()` empty -> caller passes 0 -> identical to
            today's single-lane behavior).

        The IO workers are NOT registered with the dispatcher / spawner, so
        `worker_count()` (the fork-join shard count) is UNCHANGED — it still
        returns the COMPUTE count. `io_worker_count()` reports the IO lane size.
        """
        if self._started:
            raise Error(
                "PerCoreAsyncRuntime.attach_io_workers: cannot attach after"
                " start()"
            )
        if n < 0:
            raise Error("PerCoreAsyncRuntime.attach_io_workers: n < 0")
        if n == 0:
            return
        if self._workers.len() == 0:
            raise Error(
                "PerCoreAsyncRuntime.attach_io_workers: attach compute workers"
                " (attach_workers) before the IO lane"
            )
        # Freeze the compute count: workers attached so far are the compute
        # lane; everything from here on is the IO lane. Idempotent across
        # multiple attach_io_workers calls (only the FIRST sets the boundary).
        if self._io_lane_start == NO_IO_LANE:
            self._io_lane_start = self._workers.len()
        var i = 0
        while i < n:
            var sink = sink_factory()
            self._attach_one_io_worker(sink^, backend)
            i = i + 1

    def io_worker_count(self) -> Int:
        """the IO-lane worker count (0 when no IO lane is attached).

        Distinct from `worker_count()` (the COMPUTE lane / fork-join shard
        count). The sum `worker_count() + io_worker_count()` equals the total
        pthread count the runtime launches + joins.
        """
        return self._io_worker_senders.len()

    def attach_worker(mut self, var sink: Self.S, backend: UInt8) raises:
        """4 back-compat shim: push a single Worker into the
        slab.

        Equivalent to `attach_workers(n=1, sink_factory=...)` but takes
        the sink by value, matching the existing call sites. Calling
        twice is permitted — the
        second call appends a second Worker. The legacy "single-worker
        only" raise on duplicate-attach is REMOVED at this layer; the
        single-worker contract is now expressed by the caller passing
        n=1 and not re-attaching.

        Worker.id is `len(self._workers)` at the time of attach.

        also creates the per-worker MPSC
        channel pair + stores the sender on the runtime. The worker
        receives the matching receiver inside its `_task_queue` field.
        """
        if self._started:
            raise Error(
                "PerCoreAsyncRuntime.attach_worker: cannot attach after start()"
            )
        self._attach_one_worker(sink^, backend)

    def attach_workers(
        mut self,
        n: Int,
        sink_factory: def () thin -> Self.S,
        backend: UInt8,
    ) raises:
        """5 multi-worker attach. Pushes N Worker entries into
        the slab; each worker constructed with a fresh sink from
        `sink_factory()` and the same `backend` byte.

        Worker.id is `len(self._workers) + i` at the time of each push;
        i.e. consecutive attach_workers calls produce monotonically-
        increasing worker IDs across the runtime.

        Calling after `start()` raises (cannot grow the worker set after
        pthreads are launched — would invalidate the launched pthreads'
        worker addresses).

        each worker gets a fresh MPSC channel
        pair (cap=TASK_QUEUE_CAPACITY). The receiver is moved into the
        worker's `_task_queue` field; the sender is stored on the
        runtime in `_worker_senders` and clones are registered with the
        dispatcher / spawner.
        """
        if self._started:
            raise Error(
                "PerCoreAsyncRuntime.attach_workers: cannot attach after start()"
            )
        if n < 0:
            raise Error("PerCoreAsyncRuntime.attach_workers: n < 0")
        var i = 0
        while i < n:
            var sink = sink_factory()
            self._attach_one_worker(sink^, backend)
            i = i + 1

    def worker_count(self) -> Int:
        """N — number of COMPUTE workers.

        Runtime trait method. Per HTTP client, the client uses this
        to size per-worker connection sub-pools under PerCoreAsync. The
        return value is also surfaced via the conformance.

        Compute/IO split: this returns the COMPUTE-lane size, NOT the
        total pthread count. When an IO lane is attached, the IO workers are a
        tail of `_workers` starting at `_io_lane_start`; they are excluded here
        so the fork-join shard count (which mirrors this value via the
        dispatcher's `_worker_senders`) stays compute-only. With no IO lane
        (`_io_lane_start == NO_IO_LANE`) this is exactly `_workers.len()` —
        byte-for-byte the pre-Part-B value.
        """
        var total = self._workers.len()
        if self._io_lane_start < total:
            return self._io_lane_start
        return total

    # ----------------------------------------------------------------------
    # Runtime trait — delegating methods
    # ----------------------------------------------------------------------
    # These satisfy the `Runtime` trait surface from
    # `komira_async.runtime.runtime_trait`. Each forwards to the i-th
    # worker. Bounds-checking is delegated to the underlying slab (panic on
    # out-of-bounds). Typical use:
    #   * PerCoreAsync — `worker_idx` selects the per-core reactor (one per
    #     attached worker; thread-pinned).
    #   * The future work-stealing runtime — `worker_idx` selects the
    #     calling thread's worker-thread slot.
    # The HTTP client codes against this surface; the conformer's choice of
    # routing is encapsulated here.
    def poll_completions(
        mut self, worker_idx: Int, timeout_us: Int32,
    ) raises -> Int:
        """Drive one I/O iteration on worker `worker_idx`'s reactor.

        Forwards to `Worker.run_one_iteration(timeout_us)` which: drains
        the MPSC, flushes pending submissions, polls the reactor, and
        dispatches completions to the ready-cache. Returns the total
        work units processed.

        Under PerCoreAsync the worker's own pthread normally drives this
        loop; the trait method is a side-channel for tests + single-
        worker setups where the calling thread IS the worker. Drive at
        most ONE worker from the outside per the share-nothing
        invariant: do not call poll_completions(0, ...) and
        poll_completions(1, ...) concurrently from different threads
        unless you accept that worker 0 and worker 1 are independent
        async universes (which they are under PerCoreAsync).
        """
        if worker_idx < 0 or worker_idx >= self._workers.len():
            raise Error(
                "PerCoreAsyncRuntime.poll_completions: worker_idx out of range",
            )
        return self._workers[worker_idx][].run_one_iteration(timeout_us)

    def timer_advance(
        mut self, worker_idx: Int, now_ns: Int64,
    ) raises:
        """Advance the worker's timer wheel to `now_ns`.

        v0.4 stub — `Worker[S]` does not yet own a `TimerWheel` field
        (the timer-wheel implementation lives at `komira_async.timer.
        timer_wheel` but is not yet wired into the Worker's main loop;
        23 wires it). The Runtime trait declares the surface so
        downstream code (HTTP client retry / timeout layers, HTTP client
) can call it; the no-op semantics on PerCoreAsync are
        documented + harmless. When the timer wheel is wired, this
        forwards to `self._workers[worker_idx][].timer_wheel().
        advance(now_ns)`.
        """
        if worker_idx < 0 or worker_idx >= self._workers.len():
            raise Error(
                "PerCoreAsyncRuntime.timer_advance: worker_idx out of range",
            )
        # v0.4 stub — Worker.TimerWheel integration pending.
        _ = now_ns

    def timer_now_ns(self, worker_idx: Int) -> Int64:
        """Read the worker's timer wheel current-time.

        v0.4 stub — see `timer_advance` for the wiring story. Returns 0
        until Worker.TimerWheel is integrated. The trait surface is
        present so HTTP client code can compile against it; production
        callers should treat the 0 return as "timer wheel not yet
        operational" and fall back to a wall-clock read (`perf_counter_
        ns`) until the wiring lands.
        """
        if worker_idx < 0 or worker_idx >= self._workers.len():
            return Int64(0)
        # v0.4 stub — Worker.TimerWheel integration pending.
        return Int64(0)

    def worker_at(
        mut self, i: Int
    ) -> ref [origin_of(self._workers[i][])] Worker[Self.S]:
        """Multi-worker accessor. Returns a ref to the i-th worker.

        Origin form: Slab.__getitem__ returns
        `ref [self._bytes] T`, so the parametric origin must propagate to
        `self._workers._bytes`. The `[i]` returns
        `ref [self._workers._bytes] OwnedPointer[Worker[S]]`; the trailing
        `[]` derefs the OwnedPointer to give `Worker[S]`. The compound
        origin chain elaborates to `ref [self._workers._bytes] Worker[S]`.

        PANICS (via Slab.__getitem__) if `i` is out of bounds. Use
        `worker_count()` first.
        """
        return self._workers[i][]

    def worker(mut self) raises -> ref [origin_of(self._workers[0][])] Worker[Self.S]:
        """4 back-compat accessor: returns the (single) attached
        worker. Raises if no worker is attached. Equivalent to
        `worker_at(0)` modulo the bounds-check semantics (this method
        raises a typed Error, `worker_at` debug_asserts).

        Existing tests under `tests/` and the
        `PerCoreAsyncRuntimeAdapter` integration suite call this; do not
        delete without migrating those callers.
        """
        if self._workers.len() == 0:
            raise Error("PerCoreAsyncRuntime.worker: no worker attached")
        return self._workers[0][]

    def signal_shutdown_all(mut self):
        """Broadcast the shutdown flag to every attached worker.

        Iterates the slab and calls `signal_shutdown` on each Worker.
        `signal_shutdown` is lock-free (atomic store on the worker's
        shutdown_flag) so this method is safe to call from any thread.
        """
        var i = 0
        var n = self._workers.len()
        while i < n:
            self._workers[i][].signal_shutdown()
            i = i + 1

    def install_idle_hook(mut self, slot: _IdleHookSlot):
        """Install the standing native-index idle-hook slot onto EVERY attached
        worker. Called ONCE by the EngineContext at setup,
        AFTER `attach_workers` (so every worker exists) and typically BEFORE
        `start()` (so the hook is live from the first idle window) — though it is
        safe to call after start() too (the field is set under the worker's own
        mutation; the worker reads it on its next idle window).

        The slot is POD (a BORROWED byte-ptr into the forever-root context the
        EngineContext owns + two FFI-POD code pointers); pushing it copies 3
        machine words per worker and allocates nothing. The EngineContext keeps
        the `OwnedPointer[C]` the slot points at and drops it AFTER teardown
        joins every worker."""
        var i = 0
        var n = self._workers.len()
        while i < n:
            self._workers[i][].set_idle_hook(slot)
            i = i + 1

    # The trio of accessors return
    # `ref [self._dispatcher] LocalDispatcher[S]` etc.
    @always_inline
    def dispatcher(mut self) -> ref [self._dispatcher] LocalDispatcher[Self.S]:
        """The stored
        LocalDispatcher façade.

        Returns a mutable ref to the stored `_dispatcher` field per the
        parametric-origin-return pattern (`ref [self._dispatcher]` is the
        narrow-most form Mojo 0.26.3 accepts; bare `ref [self]` fails
        to type-check). Caller binds via `ref d = rt.dispatcher()`
        (NOT `var d = rt.dispatcher()` — LocalDispatcher is Movable-only
        and `var` triggers an implicit copy).

        Public surface:
          ref d = rt.dispatcher()
          var seg_back = d.run_with_state[State, Segment](state, seg^, n)
        """
        return self._dispatcher

    @always_inline
    def spawner(mut self) -> ref [self._spawner] LocalSpawner[Self.S]:
        """The stored LocalSpawner
        façade.

        Returns a mutable ref to the stored `_spawner` field per the
        parametric-origin-return pattern (`ref [self._spawner]` is the
        narrow-most form Mojo 0.26.3 accepts; bare `ref [self]` fails
        to type-check). Caller binds via `ref s = rt.spawner()`
        (NOT `var s = rt.spawner()` — LocalSpawner is Movable-only and
        `var` triggers an implicit copy).

        Public surface:
          ref s = rt.spawner()
          var h = s.spawn[MyTask](MyTask(...))
          var result = h^.join()
        """
        return self._spawner

    @always_inline
    def io_block(mut self) -> ref [self._io_block] LocalIoBlock[Self.S]:
        """The stored LocalIoBlock
        façade.

        Returns a mutable ref to the stored `_io_block` field per the
        parametric-origin-return pattern (`ref [self._io_block]` is the
        narrow-most form Mojo 0.26.3 accepts; bare `ref [self]` fails
        to type-check). Caller binds via `ref io = rt.io_block()`
        (NOT `var io = rt.io_block()` — LocalIoBlock is Movable-only and
        `var` triggers an implicit copy).

        Public surface:
          ref io = rt.io_block()
          var result = io.block_on(my_op^)
        """
        return self._io_block

    def shutdown_token(mut self) raises -> CancellationToken:
        """Not implemented: the runtime has no shutdown token."""
        raise Error("PerCoreAsyncRuntime.shutdown_token: not implemented")

    def set_engine_placement(mut self, placement: EnginePlacement) raises:
        """Set the worker CPU placement used by the next `start()`.

        Raises once the workers are running: a placement applies at pthread
        launch, so changing it afterwards would not move any worker."""
        if self._started:
            raise Error(
                "PerCoreAsyncRuntime.set_engine_placement: already started"
            )
        self._engine_placement = placement

    def engine_placement(self) -> EnginePlacement:
        """The worker CPU placement this runtime launches its workers with."""
        return self._engine_placement

    def set_fork_join_claim(mut self, on: Bool):
        """Select the fork-join task assignment of this runtime's dispatcher.

        True (the default) lets workers claim task ids from a shared cursor;
        False gives each worker a fixed contiguous range. Both arms run every
        task exactly once. See `LocalDispatcher.set_claim_enabled`."""
        self._dispatcher.set_claim_enabled(on)

    def start(mut self) raises:
        """launch N pthreads,
        one per attached worker. Each pthread runs the worker's
        `run_until_shutdown` loop.

        Implementation: iterate `_workers` and call
        `launch_worker_pthread` per slot, writing the resulting pthread_t
        handle into the parallel `_thread_ids` slot. The pthread launch
        is synchronous (no thread fan-out parallelism — N is small,
        pthread_create returns within microseconds).

        Worker addresses are stable for the slab's lifetime: each
        Worker lives behind an `OwnedPointer` (heap-stable). The
        OwnedPointer slot is held in `_workers` (Slab[OwnedPointer[T]] is
        movable, but the pointee — Worker — is not moved when the slab
        grows; only the 8-byte OwnedPointer handles are memcpy'd).

        Calling start() twice raises. start() with zero workers raises.
        """
        if self._workers.len() == 0:
            raise Error(
                "PerCoreAsyncRuntime.start: no worker attached (call attach_worker / attach_workers first)"
            )
        if self._started:
            raise Error("PerCoreAsyncRuntime.start: already started")
        var n = self._workers.len()
        var i = 0
        while i < n:
            # SAFETY: `self._workers[i][]` is a borrow of the Worker[S]
            # behind the i-th OwnedPointer slot. The pthread launched by
            # `launch_worker_pthread` extracts the address via
            # `Int(UnsafePointer(to=worker))` and holds it for the
            # pthread's lifetime. Drop ordering on this struct's
            # `shutdown()` joins the pthread BEFORE the slab drops, so
            # the FFI-laundered address remains valid for the pthread's
            # entire lifetime.
            #
            # Compute/IO split — lane-aware pin metadata. Workers
            # [0, _io_lane_start) are the COMPUTE lane (ROLE_COMPUTE, lane
            # index == slab index i -> pins to engine_compute_cpus()[i]);
            # workers [_io_lane_start, n) are the IO lane (ROLE_IO, lane index
            # == i - _io_lane_start -> pins to engine_io_cpus()[that]). With no
            # IO lane (_io_lane_start == NO_IO_LANE > n) every worker is
            # ROLE_COMPUTE with lane index i — the pre-Part-B single-lane shape.
            # worker_id stays the GLOBAL slab index i (unique across both lanes,
            # used by the per-core log TLS binding).
            var role = ROLE_COMPUTE
            var lane_index = i
            if i >= self._io_lane_start:
                role = ROLE_IO
                lane_index = i - self._io_lane_start
            var rc = launch_worker_pthread[Self.S](
                self._workers[i][],
                UInt16(i),
                self._thread_ids[i],
                role,
                UInt16(lane_index),
                self._engine_placement,
            )
            if rc != Int32(0):
                # Best-effort cleanup: signal shutdown on already-launched
                # workers and join them. If join fails (rare ESRCH on
                # already-exited pthread), leave the runtime in an
                # inconsistent state; the caller should drop+abort.
                var j = 0
                while j < i:
                    self._workers[j][].signal_shutdown()
                    j = j + 1
                var k = 0
                while k < i:
                    _ = join_worker_pthread(self._thread_ids[k])
                    k = k + 1
                raise Error(
                    "PerCoreAsyncRuntime.start: pthread_create failed at i="
                    + String(i)
                    + " rc="
                    + String(rc)
                )
            i = i + 1
        self._started = True
        # Fresh dispatch cycle: explicit shutdown() (or RAII __del__)
        # must complete the join exactly once for THIS start cycle.
        # Reset the flag so a runtime that's been start/shutdown/start
        # cycled (lifecycle test pattern) gets a clean shutdown the
        # second time around.
        self._shutdown_done = False

    def shutdown(mut self) raises:
        """signal shutdown +
        pthread_join every attached worker. Idempotent.

        Order:
          1. signal_shutdown_all → every worker.signal_shutdown sets its
             atomic flag.
          2. for each worker i: pthread_join(_thread_ids[i]) → blocks
             until that pthread returns.

        ESRCH return from pthread_join (thread already exited) is benign
        and ignored — the same single-worker semantics.

        Sets `_shutdown_done = True` on a successful join cycle so the
        RAII `__del__` can short-circuit when the caller went out of
        their way to call shutdown() explicitly.
        """
        if not self._started:
            return
        if self._shutdown_done:
            # Double-shutdown without an intervening start() — already
            # joined, slabs already in clean state. No-op (matches the
            # idempotency contract documented for both lifecycle modes).
            return
        self.signal_shutdown_all()
        var n = self._thread_ids.len()
        var i = 0
        while i < n:
            var rc = join_worker_pthread(self._thread_ids[i])
            # Don't raise on join rc != 0 (pthread_join can return ESRCH if
            # the thread already exited; benign).
            _ = rc
            i = i + 1
        self._started = False
        self._shutdown_done = True
