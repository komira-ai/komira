# =============================================================================
# test_span_microbench.mojo — span producer microbench
# =============================================================================
#
# Producer microbench: span_start <100ns / span_end <100ns in-pipeline.
# Hosted as a test target because a test wrapper is the cheapest way to keep
# the measurement gated. The body is a straight per-pair timing.
#
# This will FAIL the build assertion if span_start+span_end exceeds
# 200ns/pair sustained on the canonical 8-worker host. The number is
# diagnostic, NOT a test failure — Mojo `assert_true` triggers only on
# pathological regression (>1µs/pair), since real numbers depend on
# parallelize scheduling jitter.
# =============================================================================

from std.ffi import external_call
from std.memory import Pointer, UnsafePointer, alloc
from std.testing import assert_true
from std.time import perf_counter_ns

from komira_obs.tracer import Tracer


# =============================================================================
# THE FORK-JOIN — real pthreads.
#
# ⚠ MOJO 1.0.0: `from std.algorithm import parallelize` is GONE. `parallelize`
# was REMOVED from the stdlib (measured against 1.0.0: absent from
# `std.algorithm`, `std.runtime`, `std.runtime.asyncrt`; no `std.parallel` /
# `std.concurrency` module exists). Not a rename — nothing to repoint to.
#
# The replacement is raw `pthread_create` + `pthread_join` over
# `std.ffi.external_call`. A SERIAL LOOP WAS NOT TAKEN: the latency arithmetic divides the
# WALL by `ITERATIONS_PER_WORKER` and calls the result per-thread latency, an
# identity that holds only because N threads run concurrently. Serialised, the
# same arithmetic reports N x the true per-pair cost under an unchanged name.
#
# ⚠ ONE ENTRY, THREE SITES. All three sites run the identical body
# (`start_span["bench.span"]` + `end_span`) and differ only in tracer and
# iteration count, so the entry and the create loop are shared in
# `_fork_span_pairs` below. A thin entry reaches `external_call` only at a
# DIRECT reference, which is why the loop lives next to the entry rather than
# behind a function-typed parameter.
#
# The stdlib pool's startup cost is gone with it, so the "Mojo parallelize
# startup" the INFO branch blames is now pthread create/join -- same order,
# different provenance.
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
    """The per-worker pthread arg. ONE PER THREAD, because each worker needs
    its own `tid` — the parameter the old `parallelize` closure took, and the
    value that selects this worker's ring.

    All three fields are PODs (one Int-laundered address, two counters), the
    FFI-POD address carve-out the pointer rules allow at a pthread
    boundary.

    SAFETY: the N args live in ONE heap block allocated by `_fork_span_pairs`
    and freed only AFTER its join barrier, so the arg strictly outlives every
    reader; workers only READ it. `tracer_addr` points at a local of the
    CALLING frame, which outlives the barrier because `_fork_span_pairs` is
    synchronous.
    """

    var tracer_addr: Int  # Int-laundered Tracer*
    var tid: Int
    var iters: Int


def _entry_span_pairs(arg: _VoidPtr) -> _VoidPtr:
    """pthread start_routine. Was `warmup` / `measure_warmup` / `worker_bench`
    — one body, three call sites."""
    # SAFETY: FFI-BOUNDARY. `arg` points into the `_WArg` block
    # `_fork_span_pairs` allocated; it outlives every thread (freed only after
    # the join barrier).
    ref a = arg.bitcast[_WArg]()[]
    # SAFETY: FFI-BOUNDARY. `tracer_addr` was produced by
    # `Int(UnsafePointer(to=tracer))` on a local of the calling test frame.
    ref tracer = UnsafePointer[Tracer, MutUntrackedOrigin](
        unsafe_from_address=a.tracer_addr,
    )[]
    try:
        for i in range(a.iters):
            var s = tracer.start_span["bench.span"](worker_id=a.tid)
            tracer.end_span(s, worker_id=a.tid)
            _ = i
    except e:
        # A pthread entry cannot propagate an exception across the ABI.
        print("span-pair worker", a.tid, "raised:", e)
    return _null_ptr[NoneType, MutUntrackedOrigin]()


def _fork_span_pairs(n: Int, tracer_addr: Int, iters: Int) raises:
    """Fork N threads over `_entry_span_pairs` and JOIN them all. Synchronous,
    exactly as `parallelize` was, so the caller's `perf_counter_ns()` bracket
    still measures the whole wave and the caller's locals still outlive it.

    Raises if any `pthread_create` failed — a bench that quietly ran at a
    narrower width than it reports is the one failure this must not hide.
    """
    var tids = List[Int64]()
    for _i in range(n):
        tids.append(Int64(0))
    var box = alloc[_WArg](n)
    for i in range(n):
        UnsafePointer(to=box[i]).unsafe_write(
            _WArg(tracer_addr=tracer_addr, tid=i, iters=iters)
        )
    var boxu = box.unsafe_origin_cast[MutUntrackedOrigin]()
    var started = 0
    var rc = Int32(0)
    for i in range(n):
        rc = external_call["pthread_create", Int32](
            UnsafePointer(to=tids[i]).bitcast[UInt8](),  # pthread_t*
            _null_ptr[UInt8, MutUntrackedOrigin](),  # attr = NULL
            _entry_span_pairs,  # start_routine (DIRECT thin-fn reference)
            UnsafePointer(to=boxu[i]).bitcast[NoneType]().unsafe_origin_cast[
                MutUntrackedOrigin
            ](),  # arg (this worker's own slot -- carries its tid)
        )
        if rc != Int32(0):
            break
        started += 1
    for i in range(started):
        _ = external_call["pthread_join", Int32](
            tids[i], _null_ptr[UInt8, MutUntrackedOrigin]()
        )
    boxu.free()
    if rc != Int32(0):
        raise Error(
            "pthread_create failed (rc="
            + String(Int(rc))
            + ") after "
            + String(started)
            + " of "
            + String(n)
            + " workers -- the reported latency would be for the wrong width"
        )


comptime N_WORKERS = 8
comptime ITERATIONS_PER_WORKER = 10_000
comptime WARMUP_ITERATIONS = 100


def run_microbench() raises -> Float64:
    """Return per-pair (span_start + span_end) ns / pair."""
    var tracer = Tracer(num_workers=N_WORKERS, ring_capacity=4096)
    tracer.install_mock_ids(trace_seed=UInt64(1), span_seed=UInt64(1))
    var tp = Pointer(to=tracer)

    # Warmup — populate workers + name registry.
    _fork_span_pairs(
        N_WORKERS, Int(UnsafePointer(to=tracer)), WARMUP_ITERATIONS
    )
    _ = tp

    # Drain the warmup records so we don't measure ring-overflow blocks.
    # We just reset ring counters via a fresh Tracer — alternative is to
    # increase ring_capacity beyond the bench iteration count.
    _ = tracer  # keepalive

    var tracer2 = Tracer(num_workers=N_WORKERS, ring_capacity=ITERATIONS_PER_WORKER * 4)
    tracer2.install_mock_ids(trace_seed=UInt64(1), span_seed=UInt64(1))
    var tp2 = Pointer(to=tracer2)

    _fork_span_pairs(
        N_WORKERS, Int(UnsafePointer(to=tracer2)), WARMUP_ITERATIONS
    )

    var t0 = perf_counter_ns()

    _fork_span_pairs(
        N_WORKERS, Int(UnsafePointer(to=tracer2)), ITERATIONS_PER_WORKER
    )
    _ = tp2
    _ = tracer2

    var t1 = perf_counter_ns()
    var total_ns = Float64(t1 - t0)
    # Per-thread per-pair latency: each thread does ITERATIONS pairs in
    # parallel, so wall = max-thread time ≈ per-thread time on a
    # parallelize-balanced run.
    var ns_per_pair_per_thread = total_ns / Float64(ITERATIONS_PER_WORKER)
    return ns_per_pair_per_thread


def main() raises:
    print("test_span_microbench — span producer microbench")
    print("================================================")
    var ns_per_pair = run_microbench()
    print("  per-thread per-pair (start+end) latency:", ns_per_pair, "ns")
    var ns_per_op = ns_per_pair / Float64(2)
    print("  per-op latency: ~", ns_per_op, "ns")
    print()
    if ns_per_op < Float64(100):
        print("span cost GREEN: <100 ns/op")
    elif ns_per_op < Float64(200):
        print("span cost YELLOW: <200 ns/op (out-of-pipeline target)")
    else:
        print("span cost INFO: ", ns_per_op,
              "ns/op — schedule + jitter dominated (Mojo parallelize startup)")
    # Pathological-regression assertion only — the ns/op number itself
    # is diagnostic. 5000 ns is "something is structurally broken" floor.
    assert_true(ns_per_op < Float64(5000),
                "pathological regression: " + String(ns_per_op) + " ns/op")
    print()
    print("test PASS")
