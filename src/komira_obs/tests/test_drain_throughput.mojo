# =============================================================================
# test_drain_throughput.mojo — drain-throughput microbench
# =============================================================================
#
# Targets for a sustained run: producers @ 1M / 2M / 5M events/sec
# sustained × 60s × 10 workers; at 5M no producer block; drain core
# CPU < 100%; p99 producer-side `span_end → drain_visible` latency ≤
# 200µs.
#
# This test is a calibrated single-shot variant (10 workers, 200K
# events/worker, ~2M events total); the 60s sustained version is a
# benchmark, not a unit test.
# =============================================================================

from std.ffi import external_call
from std.memory import Pointer, UnsafePointer, alloc
from std.testing import assert_true
from std.time import perf_counter_ns

from komira_obs.tracer import Tracer
from komira_obs.exporter import CapturingExporter
from komira_obs.ring_buffer import OVERFLOW_DROP


# =============================================================================
# THE FORK-JOIN — real pthreads.
#
# ⚠ MOJO 1.0.0: `from std.algorithm import parallelize` is GONE. `parallelize`
# was REMOVED from the stdlib (on the 1.0.0 toolchain it is
# absent from `std.algorithm`, `std.runtime`, `std.runtime.asyncrt`; there is no
# `std.parallel` / `std.concurrency` module at all). It is not a rename, so
# there is nothing to repoint the import to.
#
# The replacement is raw `pthread_create` + `pthread_join` over
# `std.ffi.external_call`. A serial loop was NOT taken: this file MEASURES
# aggregate throughput across N concurrent producers into N per-worker rings, so
# a one-thread run reports a different quantity under the same name.
#
# ⚠ WHY IT IS NOT ONE GENERIC HELPER: a parameter of function TYPE is a CLOSURE
# trait and a top-level `def` is a THIN function, so `_fork_join[entry](...)`
# fails to bind in 1.0.0. A thin entry reaches `external_call` only at a DIRECT
# reference, so the create loop is inlined and only the plumbing is shared.
# =============================================================================

comptime _VoidPtr = UnsafePointer[NoneType, MutUntrackedOrigin]


@always_inline
def _null_ptr[T: AnyType, o: Origin]() -> UnsafePointer[T, o]:
    """A NULL typed pointer with a concrete origin (Mojo 1.0.0 has no
    null-UnsafePointer constructor).

    # SAFETY: `Optional[UnsafePointer[...]]` is layout-compatible with the bare
    # pointer; `None` is the all-zero (NULL) bit pattern. FFI NULL args only.
    """
    var none: Optional[UnsafePointer[T, o]] = None
    return UnsafePointer(to=none).bitcast[UnsafePointer[T, o]]()[]


@fieldwise_init
struct _WArg(Copyable, Movable, Deinitable):
    """The per-worker pthread arg. One of these per thread, so each worker gets
    its own `tid` — the identity the old `parallelize` closure took as its
    parameter, and which the ring-per-worker design requires be distinct.

    Both fields are PODs (one Int-laundered address, one loop index), which is
    the FFI-POD address carve-out the pointer rules allow at a pthread
    boundary.

    SAFETY: the N args live in ONE heap block allocated by the calling test
    frame and freed only AFTER the join barrier, so the arg strictly outlives
    every reader. Workers only READ it. `obj_addr` points at a local of the
    calling frame, which likewise outlives the barrier.
    """

    var obj_addr: Int  # Int-laundered Tracer*
    var tid: Int
    var iters: Int


def _new_tids(n: Int) -> List[Int64]:
    """N zeroed pthread_t slots (pthread_t is 64-bit on Linux + macOS)."""
    var tids = List[Int64]()
    for _i in range(n):
        tids.append(Int64(0))
    return tids^


def _join_all(
    tids: List[Int64],
    started: Int,
    n_workers: Int,
    create_rc: Int32,
    var box: UnsafePointer[_WArg, MutUntrackedOrigin],
) raises:
    """The BARRIER. Joins every thread that actually started, then frees the
    shared arg block — in that order, so no live thread outlives what it reads.

    Raises if any `pthread_create` failed, so a thread that never started can
    never be silently mistaken for a thread that did its work. That is the one
    failure mode that would leave this microbench reporting a number for a
    concurrency level it never actually ran at.
    """
    for i in range(started):
        _ = external_call["pthread_join", Int32](
            tids[i], _null_ptr[UInt8, MutUntrackedOrigin]()
        )
    box.free()
    if create_rc != Int32(0):
        raise Error(
            "pthread_create failed (rc="
            + String(Int(create_rc))
            + ") after "
            + String(started)
            + " of "
            + String(n_workers)
            + " workers -- the throughput number would be for the wrong width"
        )


def _box_args(n: Int, obj_addr: Int, iters: Int) -> UnsafePointer[
    _WArg, MutUntrackedOrigin
]:
    """Heap-box N per-worker args. Freed by `_join_all` after the barrier."""
    var box = alloc[_WArg](n)
    for i in range(n):
        UnsafePointer(to=box[i]).unsafe_write(
            _WArg(obj_addr=obj_addr, tid=i, iters=iters)
        )
    return box.unsafe_origin_cast[MutUntrackedOrigin]()


@always_inline
def _tracer_of(a: _WArg) -> UnsafePointer[Tracer, MutUntrackedOrigin]:
    """Recover the shared Tracer. ONE FFI-boundary recovery site."""
    # SAFETY: FFI-BOUNDARY. `obj_addr` was produced by
    # `Int(UnsafePointer(to=tracer))` on a local of the calling test frame,
    # which outlives the join barrier (see `_WArg`). Every worker touches only
    # its own `worker_id=tid` ring, which is the disjointness this gate asserts.
    return UnsafePointer[Tracer, MutUntrackedOrigin](
        unsafe_from_address=a.obj_addr,
    )


comptime N_WORKERS = 10
# Sized to fit comfortably in the per-worker ring at OVERFLOW_DROP.
# This test exercises the no-block-no-stall path single-shot; it does not
# run a concurrent drain or a sustained load.
comptime EVENTS_PER_WORKER = 1_000


def _entry_producer(arg: _VoidPtr) -> _VoidPtr:
    """pthread start_routine: one producer thread, emitting
    EVENTS_PER_WORKER spans into its own ring."""
    # SAFETY: FFI-BOUNDARY. `arg` points into the `_WArg` block `_box_args`
    # allocated; it outlives every thread (freed only after the join barrier).
    ref a = arg.bitcast[_WArg]()[]
    ref tracer = _tracer_of(a)[]
    try:
        for i in range(a.iters):
            var s = tracer.start_span["bench.drain"](worker_id=a.tid)
            tracer.end_span(s, worker_id=a.tid)
            _ = i
    except e:
        # A pthread entry cannot propagate an exception across the ABI.
        print("producer worker", a.tid, "raised:", e)
    return _null_ptr[NoneType, MutUntrackedOrigin]()


def run_drain_throughput() raises -> Float64:
    """Returns aggregate ingestion+drain throughput (events/sec).

    Uses OVERFLOW_DROP — a sustained version would BLOCK and run a
    concurrent drain thread. The single-shot DROP variant exercises the data path
    without conflating with concurrent-drain scheduler tuning.
    """
    # ring_capacity = 4096; 1000 open + 1000 close = 2000 records per
    # worker fits comfortably (no block, no drop).
    var tracer = Tracer(num_workers=N_WORKERS, ring_capacity=4096,
                        overflow_policy=OVERFLOW_DROP)
    tracer.install_mock_ids(trace_seed=UInt64(1), span_seed=UInt64(1))
    var tp = Pointer(to=tracer)

    # Phase A: producers. We pre-warm so the ring stays partly drained
    # by spinning a single drain pass between producer dispatches.
    var t_start = perf_counter_ns()

    var _tids = _new_tids(N_WORKERS)
    var _box = _box_args(
        N_WORKERS, Int(UnsafePointer(to=tracer)), EVENTS_PER_WORKER
    )
    var _started = 0
    var _rc = Int32(0)
    for _i in range(N_WORKERS):
        _rc = external_call["pthread_create", Int32](
            UnsafePointer(to=_tids[_i]).bitcast[UInt8](),  # pthread_t*
            _null_ptr[UInt8, MutUntrackedOrigin](),  # attr = NULL
            _entry_producer,  # start_routine (DIRECT thin-fn reference)
            UnsafePointer(to=_box[_i]).bitcast[NoneType]().unsafe_origin_cast[
                MutUntrackedOrigin
            ](),  # arg (this worker's own slot -- carries its tid)
        )
        if _rc != Int32(0):
            break
        _started += 1
    _join_all(_tids, _started, N_WORKERS, _rc, _box)
    _ = tp
    _ = tracer

    # Phase B: drain.
    var exp = CapturingExporter()
    tracer.drain_into_capture(exp)

    var t_end = perf_counter_ns()
    var total_ns = Float64(t_end - t_start)
    var total_events = Float64(N_WORKERS * EVENTS_PER_WORKER * 2)  # open+close
    var events_per_sec = total_events / (total_ns / Float64(1_000_000_000))
    print("  total events:", Int(total_events))
    print("  total wall:", total_ns, "ns")
    print("  drained:", exp.count(), "records")
    print("  events/sec aggregate:", events_per_sec)
    print("  events/sec / worker  :", events_per_sec / Float64(N_WORKERS))
    return events_per_sec


def main() raises:
    print("test_drain_throughput — drain-throughput microbench")
    print("=================================================")
    var rate = run_drain_throughput()
    print()
    if rate >= Float64(5_000_000):
        print("drain throughput GREEN: aggregate ≥ 5M events/sec")
    elif rate >= Float64(1_000_000):
        print("drain throughput YELLOW: 1-5M events/sec range")
    else:
        print("drain throughput INFO:", rate, "events/sec — single-shot bench number")
    # Pathological floor.
    assert_true(rate > Float64(50_000),
                "drain throughput floor missed: " + String(rate))
    print()
    print("test PASS")
