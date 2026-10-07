# =============================================================================
# komira_async.spawner.local_spawner — LocalSpawner[S]
# =============================================================================
# The spawner behind PerCoreAsyncRuntime's `spawner()` accessor.
#
# Cross-pthread enqueue onto the per-worker MPSC task queue.
# `spawn[Task]` heap-allocates the Task, builds the per-Task monomorphized
# `_run_task_for[Task]` trampoline, and publishes a `_TaskEntry` onto the
# selected worker's MPSC queue (round-robin via an Atomic counter on the
# spawner). The trampoline runs on the worker's pthread when its
# `Worker.run_one_iteration` drains the queue. `spawn()` returns
# IMMEDIATELY — the JoinHandle's slot wake-word delivers the result
# asynchronously.
#
# spawn() does not block the calling thread; results
# arrive via the slot wake-word; JoinHandle.join() parks on it via
# wait_on_address.
#
# Drain semantics: `drain()` waits for true quiescence — every
# enqueued task has either completed (slot transitioned out of PENDING)
# or observed cancellation. Returns the cumulative spawn count.
#
# Why MPSC (vs the spec's nominal SPSC):
#   The same per-worker queue is shared between LocalDispatcher and
#   LocalSpawner producers; SPSC would corrupt the queue under concurrent
#   producer access. MPSC's Vyukov ring is the safer choice — see
#   `komira_async/runtime/worker.mojo` header.
#
# Pointer discipline:
#   - ZERO `UnsafePointer` in any LocalSpawner public method signature.
#   - ZERO new `unsafe_from_address=Int(...)` sites.
#   - The wildcard origins live ONLY on the per-spawn `_TaskEntry`
#     (FFI-POD shape: byte ptr + fn-ptrs).
#   - The ONE legitimate ArcPointer in the package is the JoinHandle's
#     `_slot: ArcPointer[_SpawnSlot[T]]`.
#
# Structure:
#   - LocalSpawner owns `_worker_senders: List[MpscSender[_TaskEntry]]`
#     populated at runtime attach time via `_register_worker_handle`.
#   - `_spawn_impl` pushes the entry onto a worker queue. `spawn()` returns
#     once the entry is enqueued.
#   - `_in_flight` tracks live enqueued entries; the trampoline decrements
#     it on completion (success / err / cancel).
#   - `drain()` waits for `_in_flight == 0`.
#   - `__del__` walks any un-drained entries and cancels their tokens
#     to unblock pending joiners.
#
# Per-T slot/token drop trampolines. The run trampoline
# (`_run_task_for[Task]`) frees the spawner-allocated `slot_home` and
# `token_home` heap allocations on its way out (no per-spawn leak).
# Per-entry `drop_slot_fnptr` / `drop_token_fnptr` fields
# carry the matching destructors for the un-drained-entry safety-net.
# =============================================================================

from std.memory import (
    ArcPointer,
    OwnedPointer,
    UnsafePointer,
    alloc,
)
from komira_atomic_alias import AtomicI64

from komira_async.cancellation.token import CancellationToken
from komira_async.channel.mpsc import (
    MpscSender,
    TRY_SEND_OK,
    TRY_SEND_FULL,
    TRY_SEND_CLOSED,
)
from komira_async.ops.waker_sink import WakerSink
from komira_async.runtime.shared_erasure import (
    ErasableWork,
    ErasedHandle,
    STEP_DONE,
    make_erased,
)
from komira_async.runtime.wake_primitives import (
    WorkerWakeHandle,
    cpu_pause,
    wait_on_address,
)
from komira_async.spawner.join_handle import (
    JoinHandle,
    _SLOT_CANCELLED,
    _SpawnSlot,
    cancel_slot,
    complete_slot,
    complete_slot_err,
    make_spawn_slot,
)
from komira_async.spawner.spawner import (
    SpawnableTask,
)
from komira_collections.slab import Slab


# =============================================================================
# Per-Task monomorphized trampolines.
# =============================================================================
#
# `_run_task_for[Task]` runs ONE task: reconstructs the Task via
# OwnedPointer, checks the cancellation token, runs `task.run()`,
# publishes via `complete_slot` / `complete_slot_err` / `cancel_slot`.
# After publishing, decrements the spawner's `_in_flight` counter via
# the trampoline's pinned _in_flight pointer carried inside the
# `_SpawnedTaskHeader` payload that wraps the Task.
#
# The Task storage is freed by OwnedPointer.__del__ at scope exit —
# verified by a dedicated repro.
#
# `_drop_task_for[Task]` reconstructs OwnedPointer just to drop it; used
# by the spawner's __del__ for un-drained entries (Drop=Cancel cascade).
# only triggers if the Spawner is dropped while the worker has
# not yet drained the entry; the trampoline handles the slot/token
# cleanup separately via the `_drop_payload` path inside the spawner.


# Per-spawn payload — wraps the Task plus the spawner-scoped pointers
# the trampoline needs to access from the worker thread. The Task is
# moved IN at spawn time (the spawner owns this allocation until the
# trampoline drops it via OwnedPointer).


# =============================================================================
# _InflightCounter — Movable wrapper around Atomic[int64]
# =============================================================================
# The in-flight count is NOT a wildcard-origin pointer field on
# `_SpawnedTaskHeader` (the pointer rules ban that shape); it is an
# ArcPointer<_InflightCounter>
# field shared between the spawner and every in-flight header. The Arc
# refcount semantics give the compiler full lifetime visibility, and the
# spawner's _in_flight Arc + each header's clone are dropped via the
# standard ArcPointer destructor cascade — no UAF window during teardown.
#
# Cost vs a raw pointer: +1 atomic refcount inc on spawn (clone),
# +1 atomic refcount dec on trampoline drop (header destructor). The
# dominant cost is alloc/free RATE, not atomic
# count; ArcPointer.clone is just an atomic inc on an existing alloc, no
# fresh heap activity. A spawn cycle on epoll stays well under 5 µs.


struct _InflightCounter(Movable, Deinitable):
    """Movable wrapper around Atomic[int64] for use inside ArcPointer.

    Mirrors `_SpawnSlot[T]`'s shape (which wraps Atomic[int32] in an
    OwnedPointer for the same reason — Atomic is non-Movable on Mojo
    0.26.3, so we wrap it in a Movable struct that owns a heap-stable
    OwnedPointer to the Atomic).
    """

    var _value: OwnedPointer[AtomicI64]

    def __init__(out self):
        var raw = alloc[AtomicI64](1)
        # SAFETY: fresh allocation we own; in-place init via Scalar ctor.
        raw[] = AtomicI64(Int64(0))
        self._value = OwnedPointer[AtomicI64](
            unsafe_from_raw_pointer=raw,
        )

    def fetch_add(mut self, x: Int64) -> Int64:
        return self._value[].fetch_add(x)

    def fetch_sub(mut self, x: Int64) -> Int64:
        return self._value[].fetch_sub(x)

    def load(self) -> Int64:
        return self._value[].load()


struct _SpawnedTaskHeader[
    Task: SpawnableTask & Movable & Deinitable,
](Movable, Deinitable, ErasableWork):
    """Per-spawn heap-allocated payload — the OWNING member of the
    `ErasedHandle` family.

    Carries EVERYTHING the run trampoline needs in ONE heap allocation:
      - `task`: the Task itself (consumed by `task.run()` then dropped).
      - `slot_arc`: the spawner-side ArcPointer to _SpawnSlot[Task.T];
        producer-side completion channel (refcount shared with JoinHandle).
      - `token`: the per-spawn CancellationToken (clone of the spawn-time
        token; the JoinHandle holds the other clone).
      - `in_flight`: clone of the spawner's `_in_flight` Arc; decremented
        EXACTLY ONCE (see the `_done` guard below) via `in_flight[].
        fetch_sub(1)`. The Arc keeps the InflightCounter alive until ALL
        in-flight headers AND the spawner have dropped — eliminates the
        field-drop-ordering UAF window a raw `in_flight_ptr` shape
        would expose (a RAII drop stress test of 200×10 spawns crashes
        every time with it).
      - `_done`: the idempotent in_flight-decrement guard (HAZARD a
        fix — see below).

    This struct is now an `ErasableWork` member of the
    `ErasedHandle` family (shared_erasure.mojo). The spawner heap-boxes it via
    `make_erased` (OWNING mode — the home is freed on handle drop), retiring the
    bespoke `_TaskEntry` POD + its `_run_task_for` / `_drop_task_for`
    trampolines. The body that used to live in `_run_task_for` is now `run()`
    below; the un-drained safety-net that used to live in `_drop_task_for` is now
    `__del__` below.

    ── HAZARD (a) FIX — the idempotent `_done` guard ────────────────────────────
    The old model ran `in_flight.fetch_sub(1)` in EITHER `_run_task_for` (the
    RUN path) XOR `_drop_task_for` (the un-drained DROP path) — mutually
    exclusive, exactly once. `ErasedHandle`'s model is DIFFERENT: `run()` uses
    the work IN-PLACE (no consume) AND `__del__` ALWAYS runs (frees the home).
    So a DRAINED handle would fire the decrement in `run()` AND AGAIN in
    `__del__` → DOUBLE-decrement → `drain()` underflows. The `_done` guard makes
    the decrement fire EXACTLY ONCE: `run()` does the work + publish + decrement
    + sets `_done=True`; `__del__` decrements ONLY when `_done` is still False
    (the un-drained case — the SAME single decrement the old `_drop_task_for`
    did). Single-threaded per-header: the run path and the drop path never race
    (a header is either drained by exactly one worker's `run`, or never drained
    and dropped by the channel Slab teardown — never both concurrently).

    One heap allocation per spawn: the header carries `task`, the slot
    Arc and the token as fields (rather than three separate heap homes),
    and the in-flight count is a typed `ArcPointer[_InflightCounter]`
    rather than a wildcard pointer. `_TaskEntry` keeps the same
    1-alloc-per-spawn shape.
    """

    var task: Self.Task
    var slot_arc: ArcPointer[_SpawnSlot[Self.Task.T]]
    var token: CancellationToken
    # The typed
    # ArcPointer<_InflightCounter> mirror of the spawner's `_in_flight`
    # field (not a wildcard-origin pointer, which the pointer rules ban on
    # a destroy-recreate struct lifecycle). The Arc refcount keeps the inner
    # InflightCounter alive across teardown.
    var in_flight: ArcPointer[_InflightCounter]
    # HAZARD (a) guard: True once `run()` has decremented
    # in_flight. `__del__` only decrements when this is still False (the
    # un-drained case). Ensures the in_flight decrement fires EXACTLY ONCE
    # regardless of whether the header was drained (run) or abandoned (drop).
    var _done: Bool

    def __init__(
        out self,
        var task: Self.Task,
        var slot_arc: ArcPointer[_SpawnSlot[Self.Task.T]],
        var token: CancellationToken,
        var in_flight: ArcPointer[_InflightCounter],
    ):
        self.task = task^
        self.slot_arc = slot_arc^
        self.token = token^
        self.in_flight = in_flight^
        self._done = False

    def run(mut self) raises -> None:
        """The OWNING family member's run arm — runs ONE task on the worker's
        pthread IN-PLACE (the `ErasedHandle.run` contract). The body that used to
        live in `_run_task_for`. Publishes via complete_slot / complete_slot_err
        / cancel_slot, then decrements in_flight EXACTLY ONCE (the `_done`
        guard).

        HAZARD (a): `ErasedHandle.run` does NOT consume the work; the home
        is freed later by `ErasedHandle.__del__`. So `run` must NOT free the
        header here — it just runs the task body in-place. The in_flight
        decrement is guarded by `_done` so it never double-fires with `__del__`.
        """
        if self._done:
            return
        # Watch-out #2 — cancellation check before task.run() so the slot is
        # published (cancelled) even when we skip run().
        if self.token.is_cancelled():
            cancel_slot[Self.Task.T](self.slot_arc)
        else:
            try:
                var result = self.task.run()
                complete_slot[Self.Task.T](self.slot_arc, value=result)
            except e:
                complete_slot_err[Self.Task.T](
                    self.slot_arc,
                    err=String("LocalSpawner: ") + String(e),
                )
        # Decrement the in-flight counter via the typed Arc. Must happen AFTER
        # complete_slot publishes (so a joiner blocked in drain() sees the slot
        # result before the counter goes to zero). Set `_done` so `__del__` does
        # NOT decrement again (HAZARD a).
        _ = self.in_flight[].fetch_sub(Int64(1))
        self._done = True

    def step(mut self) raises -> Int:
        """Result arm — not the spawner's arm (it is a void-`run` task), so it
        explicitly signals DONE. REQUIRED for the `ErasableWork` dispatch reason
        (no trait default to statically shadow `run`)."""
        return STEP_DONE

    def __deinit__(deinit self):
        """Un-drained safety-net — the body that used to live in `_drop_task_for`.
        Runs when the header's home is freed: by `ErasedHandle.__del__` (always,
        after `run`), or by the channel Slab teardown for an entry the worker
        never drained (shutdown / abandoned). Decrements in_flight ONLY when
        `_done` is still False (HAZARD a — the un-drained case); a drained header
        already decremented in `run()`.

        After this body, the fields (task / slot_arc / token / in_flight Arc)
        auto-drop in declaration order (the SAME cascade the old `_run_task_for`
        / `_drop_task_for` OwnedPointer drop performed): task drops, slot_arc
        decrements (if last → free _SpawnSlot), token drops, in_flight Arc
        decrements.
        """
        if not self._done:
            _ = self.in_flight[].fetch_sub(Int64(1))


# =============================================================================
# LocalSpawner[S] — public façade.
# =============================================================================


struct LocalSpawner[
    S: WakerSink & Movable & Deinitable,
](Movable, Deinitable):
    """trait-surface façade for the
    engine's spawn-and-join shape.

    spawn() pushes the entry onto a worker's
    MPSC queue (round-robin via the spawner's `_next_worker` Atomic
    counter). The trampoline runs on the worker pthread at the next
    drain step. drain() waits for true quiescence (in_flight == 0).

    Stored as a field on PerCoreAsyncRuntime[S]; reached via
    `rt.spawner()`. Senders are populated at attach time via
    `_register_worker_handle`.

    Bench gate:
      * cb_spawn (1024 spawn+join cycles) ≤ 5 µs/cycle absolute on M2.
        Cross-pthread enqueue cost may push the floor up vs inline
        execution; the gate remains at 5 µs/cycle.
    """

    # MpscSender is Movable but not Copyable, so a `List[MpscSender]`
    # rejects the trait bound. Wrap each sender in an OwnedPointer
    # (POD 8-byte handle) and store in a Slab — safe across destroy-recreate shape.
    var _worker_senders: Slab[OwnedPointer[MpscSender[ErasedHandle]]]
    # eventfd spin-park: per-worker wake handles populated at
    # attach time alongside the sender slab. WorkerWakeHandle is POD;
    # Slab[WorkerWakeHandle] is safe across destroy-recreate directly. Index matches
    # _worker_senders.
    var _worker_wake_handles: Slab[WorkerWakeHandle]
    var _next_worker: OwnedPointer[AtomicI64]   # round-robin
    # _in_flight is an
    # ArcPointer<_InflightCounter> shared with every in-flight header.
    # A raw pointer mirror on the header struct would violate the pointer
    # rules under a destroy-recreate
    # lifecycle). Arc shape has the compiler's full lifetime view; clones
    # cost 1 atomic inc each, no extra heap activity.
    var _in_flight: ArcPointer[_InflightCounter]
    var _spawned_count: Int

    def __init__(out self):
        """Construct an empty LocalSpawner. Sender list is populated by
        PerCoreAsyncRuntime.attach_worker[s] via
        `_register_worker_handle`.
        """
        self._worker_senders = Slab[OwnedPointer[MpscSender[ErasedHandle]]]()
        self._worker_wake_handles = Slab[WorkerWakeHandle]()
        var next_raw = alloc[AtomicI64](1)
        # SAFETY: fresh allocation; init via Atomic ctor + raw assignment.
        next_raw[] = AtomicI64(Int64(0))
        self._next_worker = OwnedPointer[AtomicI64](
            unsafe_from_raw_pointer=next_raw,
        )
        # ArcPointer-wrapped
        # InflightCounter. The ArcPointer's inner
        # InflightCounter heap-allocates and owns the Atomic.
        self._in_flight = ArcPointer[_InflightCounter](_InflightCounter())
        self._spawned_count = 0

    def _register_worker_handle(
        mut self,
        var sender: MpscSender[ErasedHandle],
        var wake_handle: WorkerWakeHandle,
    ):
        """Step 5 — 2-arg form. Called by PerCoreAsyncRuntime
        attach_worker[s] to seed one MpscSender clone + one
        WorkerWakeHandle per attached worker. The wake_handle is the
        spawner's own clone (refcount-bumped at the call site via
        WorkerWakeHandle.copy()) carrying its own
        ArcPointer<_SleepingFlag> clone for typed wake elision per


        `wake_handle` is `var`
        (consumed); the caller produces a per-producer clone via
        `WorkerWakeHandle.copy()`.
        """
        var owned = OwnedPointer[MpscSender[ErasedHandle]](value=sender^)
        self._worker_senders.append(owned^)
        self._worker_wake_handles.append(wake_handle^)

    def worker_count(self) -> Int:
        """Diagnostic accessor — number of worker queues the spawner
        can target. Equal to the number of attached workers on the
        runtime that owns this spawner.
        """
        return self._worker_senders.len()

    def spawn[
        Task: SpawnableTask & Movable & Deinitable,
    ](mut self, var task: Task) raises -> JoinHandle[Task.T]:
        """spawn a task; returns a JoinHandle bound to
        the spawning worker.

        Cross-pthread enqueue. The Task is
        heap-allocated, wrapped in a `_SpawnedTaskHeader[Task]`, and
        published onto the round-robin-selected worker's MPSC queue.
        `spawn()` returns IMMEDIATELY — the trampoline runs on the
        worker's pthread when its `Worker.run_one_iteration` drains
        the queue. The JoinHandle's slot wake-word delivers the result
        asynchronously; JoinHandle.join() parks on it via
        wait_on_address.

        Raises:
          - "LocalSpawner.spawn: no workers attached" if no workers
            have been registered with the spawner.
          - "LocalSpawner.spawn: queue closed" / "queue persistently
            FULL" on enqueue failure (rare; receiver-closed +
            persistent-back-pressure cases).
        """
        var token = CancellationToken.new()
        return self._spawn_impl[Task](task^, token^)

    def spawn_with_token[
        Task: SpawnableTask & Movable & Deinitable,
    ](
        mut self, var task: Task, var token: CancellationToken,
    ) raises -> JoinHandle[Task.T]:
        """Tier 2 — explicit token. Token consumed; child observability
        is the caller's responsibility. Same execution model as `spawn`.
        """
        return self._spawn_impl[Task](task^, token^)

    def _spawn_impl[
        Task: SpawnableTask & Movable & Deinitable,
    ](
        mut self, var task: Task, var token: CancellationToken,
    ) raises -> JoinHandle[Task.T]:
        """Internal trampoline — cross-pthread enqueue.

        Step-by-step:
          1. Validate ≥1 worker registered.
          2. Allocate the slot Arc + heap home; clone for JoinHandle.
          3. Allocate the per-spawn CancellationToken heap home; clone
             for JoinHandle.
          4. Build the _SpawnedTaskHeader[Task] payload (Task + in_flight
             pointer); heap-allocate; init_pointee_move.
          5. Capture the per-Task trampolines.
          6. Build the _TaskEntry; pick target worker via round-robin
             (_next_worker.fetch_add).
          7. Bump _in_flight (do this BEFORE try_send so that drain()
             sees a positive count even if the worker drains the entry
             between try_send and a second-thread drain() call).
          8. try_send onto the worker's queue; retry on FULL with
             cpu_pause; on CLOSED unwind heap allocations + raise.
          9. Build + return the JoinHandle.

        On enqueue failure the function unwinds heap allocations to
        avoid leaks: the slot/token homes are dropped via OwnedPointer
        reconstruction; the header is dropped similarly; in_flight is
        decremented.
        """
        if self._worker_senders.len() == 0:
            _ = task^
            _ = token^
            raise Error(
                "LocalSpawner.spawn: no workers attached. Call"
                " PerCoreAsyncRuntime.attach_worker[s] + start() before"
                " spawn()."
            )

        # Collapse slot_home + token_home
        # + header into ONE heap allocation. The Arc + Token live on the
        # _SpawnedTaskHeader[Task] as fields. JoinHandle gets clones
        # BEFORE the header is built (move semantics: original token + slot
        # arc are moved into the header).

        # Step 2 — slot Arc + JoinHandle clone.
        var slot_arc = make_spawn_slot[Task.T]()
        # Clone for the JoinHandle BEFORE moving the original into the
        # header (the original consumed by init_pointee_move below).
        var slot_for_handle = ArcPointer[_SpawnSlot[Task.T]](copy=slot_arc)

        # Step 3 — token clone for the JoinHandle (before token^ is
        # moved into the header).
        var token_for_handle = token.clone()

        # Step 4 — single header allocation (Task + slot Arc + Token +
        # in_flight Arc). One alloc per spawn (header), plus the Arc
        # refcount inc on _in_flight clone (no fresh heap activity).
        # in_flight is an
        # ArcPointer field on the header. The compiler
        # tracks lifetime via Arc semantics; no wildcard origin needed.
        var inflight_clone = ArcPointer[_InflightCounter](
            copy=self._in_flight,
        )

        # Step 4 — build the header + heap-box it into ONE
        # `ErasedHandle` (OWNING family member) via `make_erased`. `make_erased`
        # allocates the single header home (the SAME 1-alloc-per-spawn shape) and
        # binds the per-`_SpawnedTaskHeader[Task]` run/step/drop trampolines. The
        # `_TaskEntry` POD + `_run_task_for` / `_drop_task_for` are RETIRED: the
        # run body now lives in `_SpawnedTaskHeader.run()` (with the `_done`
        # in_flight guard), and the un-drained safety-net lives in its `__del__`.
        var handle = make_erased(
            _SpawnedTaskHeader[Task](
                task=task^,
                slot_arc=slot_arc^,
                token=token^,
                in_flight=inflight_clone^,
            )
        )

        var n_workers = self._worker_senders.len()
        var rr = self._next_worker[].fetch_add(Int64(1))
        var wid = Int(rr) % n_workers
        if wid < 0:
            wid = wid + n_workers  # defensive against modulo signedness

        # Step 7 — bump in_flight BEFORE try_send. Goes through the typed
        # Arc; no wildcard pointer.
        _ = self._in_flight[].fetch_add(Int64(1))

        # Step 8 — try_send_back with retry on FULL. `ErasedHandle` is
        # Movable-only, so we use `try_send_back` (returns the handle BACK on
        # non-OK) instead of the value-dropping `try_send`. On FULL we re-send
        # the SAME handle next attempt; on CLOSED we drop it — `ErasedHandle.
        # __del__` frees the header home AND its `__del__` decrements in_flight
        # (the `_done` guard: un-drained, so it decrements). NO manual
        # `leaked_header` reconstruction is needed any more — the handle owns it.
        var send_attempts = 0
        var max_send_attempts = 1_000_000
        var pending = Optional[ErasedHandle](handle^)
        while send_attempts < max_send_attempts:
            var outcome = self._worker_senders[wid][].try_send_back(
                pending.take()
            )
            if outcome.status == TRY_SEND_OK:
                # +: send THEN wake.
                # Spawner round-robin spreads wakes across workers
                # (per-eventfd write rate ≈ rate/N per dataplane-PE
                # Issue 3.C). wake_with_elision() reads the typed
                # _SleepingFlag through the cloned ArcPointer; on hot
                # paths where workers are spinning through pending tasks
                # the flag reads 0 → no syscall fires. Worker park-bracket
                # (worker.mojo:680-715) closes the lost-wakeup race by
                # re-checking the MPSC queue AFTER setting _sleeping=1.
                _ = self._worker_wake_handles[wid].wake_with_elision()
                break
            if outcome.status == TRY_SEND_CLOSED:
                # Receiver closed — drop the un-sent handle. Its `__del__` frees
                # the header home; the header's own `__del__` decrements in_flight
                # (un-drained: `_done` is False), so the in_flight bump above is
                # balanced. Drop the JoinHandle-side clones too.
                _ = outcome^
                _ = slot_for_handle^
                _ = token_for_handle^
                raise Error(
                    "LocalSpawner.spawn: worker"
                    + String(wid)
                    + " queue closed (worker shut down)"
                )
            # FULL — take the handle back for the next attempt.
            pending = Optional[ErasedHandle](outcome.take_value())
            cpu_pause()
            send_attempts = send_attempts + 1
        if send_attempts >= max_send_attempts:
            # Persistent FULL — drop the still-pending handle (its `__del__`
            # frees the header + decrements in_flight via the un-drained guard).
            _ = pending.take()
            _ = slot_for_handle^
            _ = token_for_handle^
            raise Error(
                "LocalSpawner.spawn: worker"
                + String(wid)
                + " queue persistently FULL (worker not draining;"
                " check that start() was called)"
            )

        self._spawned_count = self._spawned_count + 1

        # Step 9 — build the JoinHandle (post-refactor: clones built
        # before the header was constructed; header owns the producer-
        # side originals).
        return JoinHandle[Task.T](
            slot=slot_for_handle^,
            op_id=Int64(self._spawned_count),
            token=token_for_handle^,
        )

    def drain(mut self) raises -> Int:
        """wait for true quiescence: every previously-
        enqueued entry has either completed (success / error) or been
        cancelled (slot transitioned out of PENDING). Returns the
        cumulative spawn count.

        Blocks the calling thread until
        `_in_flight == 0`. Polls with a short timeout so a pathological
        wake-loss doesn't deadlock. The trampoline's
        `_in_flight.fetch_sub(1)` happens AFTER the slot's
        complete_slot publish, so when in_flight reaches zero, every
        slot is in a terminal state and joiners can read results
        without further parking.
        """
        var spin_budget = 1024
        var spins = 0
        while self._in_flight[].load() != Int64(0):
            if spins < spin_budget:
                cpu_pause()
                spins = spins + 1
            else:
                # Park briefly on the in_flight pointer (compare-fails
                # if it already changed). The wait_on_address shim
                # operates on Atomic[int32], not int64; we use a
                # short polling loop instead.
                spins = 0
        return self._spawned_count

    def pending_count(self) -> Int:
        """Diagnostic accessor — number of in-flight (enqueued, not yet
        drained) tasks. Equal to the difference between cumulative
        spawns and completions.
        """
        return Int(self._in_flight[].load())

    def _in_flight_load(self) -> Int64:
        # Helper — abstracts the Arc deref so callers don't need to know
        # _in_flight is an ArcPointer. Used by drain() and tests.
        return self._in_flight[].load()

    def __deinit__(deinit self):
        """Drop=Cancel cascade for un-drained entries.

        Drop ordering: the spawner's MpscSender clones go out of scope
        here; each sender's Drop reduces the channel's Arc refcount but
        does NOT close the channel (the worker still holds the receiver
        side). Any entries already enqueued continue to be drained by
        their target worker.

        Heap-home cleanup contract:
          - For entries the worker DID drain, `_run_task_for[Task]`
            frees all three heap homes (task / slot / token) on its way
            out. This is the steady-state path; closes the per-spawn
            per-spawn leak.
          - For entries the worker DID NOT drain (e.g., Spawner dropped
            before worker drained, or worker pthread crashed), the
            entry's `drop_fnptr`, `drop_slot_fnptr`, `drop_token_fnptr`
            trampolines are the safety-net invocations. Today the
            spawner does not own a receiver handle (receivers live on
            Worker[S] inside the runtime), so the spawner __del__ path
            CANNOT walk un-drained entries directly. The cleanup
            happens via Worker.run_until_shutdown's final unbounded
            drain, which calls `run_fnptr` on every remaining entry —
            the run path then drops all three homes. The drop_*_fnptr
            trampolines are positioned on the entry for any future
            architecture where the spawner can drain its own producer
            queues directly (e.g., reactor-driven cancellation cascade).
        """
        # No active body — fields drop via Deinitable.
        # MpscSender clones drop without closing; in_flight Atomic is
        # heap-freed via OwnedPointer.__del__; sender list drops
        # element-wise.
        pass
