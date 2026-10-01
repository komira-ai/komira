# =============================================================================
# test_cross_pthread_happens_before.mojo
# =============================================================================
# closure stress test.
#
# Validates the cross-pthread happens-before contract on the LocalSpawner /
# LocalDispatcher per-worker MPSC queue path:
#
#   1. spawn 1024 tasks across 4 workers via round-robin.
#   2. Each task records its tid + the calling pthread_self() into a
#      shared atomic counter array.
#   3. JoinHandle.join on every handle in order.
#   4. Assert: every task ran (counter == 1024).
#   5. Assert: at least 2 distinct pthread_self() values were recorded
#      (proves cross-pthread execution; the trampoline runs on a worker
#      pthread, NOT the main thread that called spawn()).
#   6. Spawn 256 dependent-task pairs (Task A writes value V; Task B
#      reads V); assert every B reads A's V (proves the happens-before
#      edge from complete_slot's release-store on _SLOT_READY to join's
#      acquire-load).
#
# This is the load-bearing functional check on the cross-
# pthread model. If the trampoline ran on the calling thread (an inline
# fallback), the pthread_self() distinct-count would be 1 and the test
# would fail loudly.
# =============================================================================

from std.ffi import external_call
from std.memory import OwnedPointer, alloc
from komira_atomic_alias import AtomicI64
from std.testing import assert_equal, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import (
    PLACEMENT_FIXED,
    PerCoreAsyncRuntime,
)
from komira_async.spawner.spawner import SpawnableTask


# Per-task probe: records pthread_self() and increments a shared
# counter when run. The counter + the per-task pthread-id slot both
# live as borrowed pointers (laundered via Int address) — the
# usual task-test convention.


@fieldwise_init
struct _ProbeTask(SpawnableTask, Movable, Deinitable):
    """Records pthread_self() at run time + increments a shared
    counter. Returns the recorded pthread_self() so the caller can
    inspect the distinct-count."""

    comptime T = Int

    var counter_addr: Int
    var tid: Int

    def run(mut self) raises -> Self.T:
        # SAFETY (TEST-ONLY): counter_addr was Int(UnsafePointer(to=...))
        # by the spawn-site; we recover the typed pointer via FFI
        # laundering.  The pointee
        # outlives every spawn (the test scope owns it).
        var counter_ptr = UnsafePointer[
            AtomicI64, MutUntrackedOrigin,
        ](unsafe_from_address=self.counter_addr)
        _ = counter_ptr[].fetch_add(Int64(1))
        # pthread_self returns the calling pthread's handle. On Linux
        # glibc this is a uintptr-sized opaque value. We cast through
        # Int — close enough for distinct-set comparison.
        var pth = Int(external_call["pthread_self", UInt64]())
        _ = self.tid
        return pth


# Dependent-pair task: reads a shared value, returns it. Used to verify
# happens-before from a previous task's write.


@fieldwise_init
struct _ReadTask(SpawnableTask, Movable, Deinitable):
    comptime T = Int64

    var value_addr: Int

    def run(mut self) raises -> Self.T:
        # SAFETY (TEST-ONLY): value_addr was Int(UnsafePointer(to=...))
        # by the spawn-site.
        var value_ptr = UnsafePointer[
            AtomicI64, MutUntrackedOrigin,
        ](unsafe_from_address=self.value_addr)
        return value_ptr[].load()


@fieldwise_init
struct _WriteTask(SpawnableTask, Movable, Deinitable):
    comptime T = Int

    var value_addr: Int
    var value_to_write: Int64

    def run(mut self) raises -> Self.T:
        var value_ptr = UnsafePointer[
            AtomicI64, MutUntrackedOrigin,
        ](unsafe_from_address=self.value_addr)
        AtomicI64.store(
            UnsafePointer(to=value_ptr[]).unsafe_bitcast[Scalar[DType.int64]](), self.value_to_write,
        )
        return 1


def _make_noop_sink() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def test_1024_tasks_4_workers_run_on_worker_pthreads() raises:
    """closure stress — 1024 tasks across 4 workers.

    Validates:
      * Every task ran (counter reaches 1024).
      * At least 2 distinct pthread_self() values were recorded
        (proves cross-pthread execution; an inline-exec model
        would give exactly 1 distinct value = the main thread).
    """
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(4, _make_noop_sink, BACKEND_MOCK)
    rt.start()

    # Shared counter.
    var counter_owned = OwnedPointer[AtomicI64](
        unsafe_from_raw_pointer=alloc[AtomicI64](1),
    )
    AtomicI64.store(
        UnsafePointer(to=counter_owned[]).unsafe_bitcast[Scalar[DType.int64]](), Int64(0),
    )
    var counter_addr = Int(UnsafePointer(to=counter_owned[]))

    # Thread-id collector (last-seen-by-worker; sample-based since we
    # only need to confirm distinct pthread set has > 1 element).
    var tid_set = List[Int]()

    ref s = rt.spawner()
    var i = 0
    while i < 1024:
        var h = s.spawn[_ProbeTask](
            _ProbeTask(counter_addr=counter_addr, tid=i)
        )
        var pth = h^.join()
        # Record distinct pthread ids.
        var found = False
        var j = 0
        while j < len(tid_set):
            if tid_set[j] == pth:
                found = True
                break
            j = j + 1
        if not found:
            tid_set.append(pth)
        i = i + 1

    # Drain: counter == 1024.
    assert_equal(counter_owned[].load(), Int64(1024))

    # Distinct pthread count > 1 (cross-pthread execution).
    assert_true(
        len(tid_set) >= 2,
        String("expected >= 2 distinct pthreads, observed ")
        + String(len(tid_set)),
    )

    rt.shutdown()


def test_dependent_pair_happens_before() raises:
    """closure stress — write→read happens-before
    via complete_slot's release + join's acquire.

    For each pair: spawn _WriteTask(V); join (which acquires the slot's
    READY state); then spawn _ReadTask; join; assert _ReadTask returned V.

    If the happens-before edge were broken (e.g., relaxed ordering), we
    would observe stale values across the join boundary.
    """
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(4, _make_noop_sink, BACKEND_MOCK)
    rt.start()

    ref s = rt.spawner()

    var i = 0
    while i < 256:
        var v_owned = OwnedPointer[AtomicI64](
            unsafe_from_raw_pointer=alloc[AtomicI64](1),
        )
        AtomicI64.store(
            UnsafePointer(to=v_owned[]).unsafe_bitcast[Scalar[DType.int64]](), Int64(0),
        )
        var v_addr = Int(UnsafePointer(to=v_owned[]))
        var written = Int64(0xDEADBEEF) + Int64(i)
        var w_h = s.spawn[_WriteTask](
            _WriteTask(value_addr=v_addr, value_to_write=written)
        )
        _ = w_h^.join()  # acquire on Writer's complete_slot READY
        var r_h = s.spawn[_ReadTask](_ReadTask(value_addr=v_addr))
        var read = r_h^.join()  # acquire on Reader's complete_slot READY
        # Keepalive: Mojo's ASAP destruction would otherwise drop
        # `v_owned` immediately after `v_addr` is computed (the only
        # use of v_owned is the Int laundering); the slot would be
        # reused by spawner heap allocations and the Reader would read
        # garbage. Holding v_owned across the join keeps the Atomic
        # alive for the whole pair. (closure deferral #3
        # tightened the slot/token home cleanup in `_run_task_for`,
        # which made the heap reuse aggressive enough to expose this
        # latent test bug — `v_owned`'s ASAP drop point moved earlier
        # than the publish-then-Reader-spawn window.)
        _ = v_owned^
        assert_equal(read, written)
        i = i + 1

    rt.shutdown()


def main() raises:
    test_1024_tasks_4_workers_run_on_worker_pthreads()
    test_dependent_pair_happens_before()
    print(
        "PASS komira_async.stress.cross_pthread_happens_before"
    )
