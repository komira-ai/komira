# =============================================================================
# komira_async.observability.reactor_stall_detector — per-worker stall watchdog
# =============================================================================
#
#
# Per-worker watchdog. Default threshold: 20ms.
# On stall, increments a counter, records last-stall info, sets the
# need_preempt flag. Observability only — runtime takes no auto action.
# Mitigation is a developer responsibility (chunk the long task; insert
# yield_if_needed(); use with_no_preempt(...) only if task is provably short).
#
# 25 scope:
#   - Standalone struct + 10 unit tests.
#   - task_started / task_finished bookkeeping; on elapsed > threshold,
#     stall counter + last_stall info + need_preempt flag set.
#   - Worker integration (`_stall_detector` field +
#     worker_main step 2 hook) lives in the Worker. This is the
#     standalone primitive the Worker
#     uses.
#   - The need_preempt() method on this struct is a per-detector flag.
#     The global komira_async.primitives.need_preempt free fn
#     still returns False; will read it from
#     `worker._stall_detector.need_preempt() OR <quota check>`.
#
# Pointer discipline:
#   - ZERO UnsafePointer in any public method signature.
#   - ZERO ArcPointer in any field — single-owner
#   - ZERO wildcard origins on public surface.
#   - ZERO unsafe_from_address.
#   - need_preempt flag heap-allocated via OwnedPointer[Atomic[int32]]
#     (Repro 7 pattern — Atomic non-Movable on 0.26.3, OwnedPointer
#     indirection makes the struct Movable; matches Worker._shutdown_flag).
# =============================================================================

from std.memory import OwnedPointer, alloc
from komira_atomic_alias import AtomicI32


# Default threshold: 20ms = 20_000_000 nanoseconds. Seastar's setting;
# audit Public so test code +
# integrators can verify.
comptime DEFAULT_STALL_THRESHOLD_NS: Int64 = 20_000_000


struct ReactorStallDetector(Movable, Deinitable):
    """Per-worker watchdog.

    Hooked at task_started / task_finished per worker_main loop iteration.
    If elapsed_ns > threshold at task_finished, emit event:
    increment stall_count, record last-stall (task_id, elapsed), set
    need_preempt flag.

    A minimum-viable standalone primitive (the Worker
    integrates it).

    Field set:
      - _threshold_ns: configurable; default 20ms.
      - _stall_count: incremented on each stall.
      - _last_stall_task_id, _last_stall_elapsed_ns: most recent stall info.
      - _has_recorded: True once any stall has been recorded.
      - _current_task_id, _current_task_start_ns: task_started bookkeeping.
      - _need_preempt_flag: OwnedPointer[Atomic[int32]] — set on stall;
        read via need_preempt(); cleared via clear_need_preempt().
        OwnedPointer because Atomic is non-Movable on 0.26.3.
    """

    var _threshold_ns: Int64
    var _stall_count: Int64
    var _last_stall_task_id: Int64
    var _last_stall_elapsed_ns: Int64
    var _has_recorded: Bool
    var _current_task_id: Int64
    var _current_task_start_ns: Int64
    var _need_preempt_flag: OwnedPointer[AtomicI32]

    def __init__(out self, threshold_ns: Int64 = DEFAULT_STALL_THRESHOLD_NS) raises:
        """Construct a fresh detector. threshold_ns defaults to 20ms.

        Pass threshold_ns=0 for an "every-task-stalls" diagnostic mode
        (forced-stall harness for testing the wire-up).
        """
        self._threshold_ns = threshold_ns
        self._stall_count = Int64(0)
        self._last_stall_task_id = Int64(0)
        self._last_stall_elapsed_ns = Int64(0)
        self._has_recorded = False
        self._current_task_id = Int64(0)
        self._current_task_start_ns = Int64(0)
        var raw = alloc[AtomicI32](1)
        # SAFETY: raw is a fresh allocation we own; Atomic ctor accepts a
        # Scalar value; ownership transfers to OwnedPointer; __del__ runs
        # free. Pattern matches Worker._shutdown_flag (worker.mojo:71-79).
        raw[] = AtomicI32(Int32(0))
        self._need_preempt_flag = OwnedPointer[AtomicI32](
            unsafe_from_raw_pointer=raw
        )

    def threshold_ns(self) -> Int64:
        return self._threshold_ns

    def stall_count(self) -> Int64:
        return self._stall_count

    def has_recorded_stall(self) -> Bool:
        return self._has_recorded

    def last_stall_task_id(self) -> Int64:
        """Returns the task_id of the most recent stalling task. Caller
        should check has_recorded_stall() first; returns 0 if no stall
        has been recorded."""
        return self._last_stall_task_id

    def last_stall_elapsed_ns(self) -> Int64:
        """Returns elapsed_ns of the most recent stalling task. Caller
        should check has_recorded_stall() first; returns 0 if no stall
        has been recorded."""
        return self._last_stall_elapsed_ns

    def task_started(mut self, task_id: Int64, started_ns: Int64):
        """Record the start of a task. step 2 hook.

        25 single-task-at-a-time model — the worker runs tasks
        run-to-completion, so there's never overlap. with a real
        task queue may need a stack of (task_id, started_ns) if nested
        spawns are allowed; for now this single-slot bookkeeping is
        sufficient.
        """
        self._current_task_id = task_id
        self._current_task_start_ns = started_ns

    def task_finished(mut self, task_id: Int64, finished_ns: Int64):
        """Record the end of a task. If elapsed > threshold, emit a stall
        event: increment counter, record last-stall info, set
        need_preempt flag.

        "if elapsed > threshold at task_finished,
        emit event."
        """
        var elapsed = finished_ns - self._current_task_start_ns
        if elapsed > self._threshold_ns:
            self._stall_count = self._stall_count + Int64(1)
            self._last_stall_task_id = task_id
            self._last_stall_elapsed_ns = elapsed
            self._has_recorded = True
            # Set the need_preempt flag (relaxed store — the read side
            # is also relaxed; no synchronization beyond visibility).
            AtomicI32.store(
                UnsafePointer(to=self._need_preempt_flag[]).unsafe_bitcast[Scalar[DType.int32]](), Int32(1)
            )

    def need_preempt(self) -> Bool:
        """Returns True if a stall has been detected and the flag has not
        yet been cleared. cooperative-scheduling discipline:
        the global komira_async.primitives.need_preempt() free fn will
        OR this with the task-quota check (wire-up)."""
        return self._need_preempt_flag[].load() != Int32(0)

    def clear_need_preempt(mut self):
        """Clear the need_preempt flag. The stall counter is preserved.
        Worker calls this at task-yield boundaries to acknowledge that
        the preempt signal has been honored."""
        AtomicI32.store(
            UnsafePointer(to=self._need_preempt_flag[]).unsafe_bitcast[Scalar[DType.int32]](), Int32(0)
        )
