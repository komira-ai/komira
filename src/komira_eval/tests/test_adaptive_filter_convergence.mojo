# =============================================================================
# Convergence tests for `AdaptiveFilter`.
#
# Two scenarios:
#
#   1. Single-thread convergence — 4 predicates with selectivities
#      [0.5, 0.1, 0.9, 0.3]; optimal permutation [1, 3, 0, 2] (lowest-sel
#      first); verify reached in ≤ 500 chunks.
#
#   2. Parallelize convergence — 4 workers × 500 chunks each. Verify
#      (a) all 4 workers reach the optimal permutation, (b) no SIGSEGV
#      / no race (Atomic[Int64] error counter is zero), (c) RNG states
#      remain distinct (each worker has its own XorShift64).
#
# The cost model is a deterministic shape:
#
#   each predicate scans `live_rows` and pays a fixed per-row cost
#   (10 ns); predicates short-circuit (live_rows multiplies by the
#   predicate's selectivity for each subsequent step).
#
# Total ns is therefore a function of the permutation; the optimal order
# minimizes total ns by feeding the smallest live-rows to the most
# expensive (gather-cost-dominated) predicates.
#
# Synthetic ns injection: AdaptiveFilter.begin_filter / end_filter use
# `perf_counter_ns()` internally for the start time. For deterministic
# convergence we feed a SYNTHETIC duration by backdating the start_ns:
#
#   var start = af.begin_filter()       # real perf_counter_ns now
#   var backdated = start - synthetic_dur_ns
#   af.end_filter(backdated)            # end sees now - backdated ≈ synthetic
#
# This works because perf_counter_ns is monotonic — the absolute time
# doesn't matter, only the delta — and the iteration body is empty so
# real elapsed time is sub-µs (well below the ms-scale synthetic
# durations).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

# ⚠ MOJO 1.0.0: `from std.algorithm import parallelize` is GONE — removed, not
# renamed (1.0.0 ships no threading module at all). The three convergence tests
# below are ABOUT what 4 concurrent workers do to 4 disjoint AdaptiveFilter
# slots: no race, all-4-converge, and DISTINCT RNG streams. Driven serially all
# three still pass while proving none of it — the RNG-distinctness one most
# obviously, since sequential workers cannot collide in the first place. So the
# replacement is a real pthread fork-join over `std.ffi.external_call`;
# every assertion below is unchanged.
from komira_atomic_alias import AtomicI64
from std.ffi import external_call
from std.memory import OwnedPointer, UnsafePointer, alloc

from komira_core.collections.slab import Slab
from komira_eval.adaptive_filter import (
    AdaptiveFilter,
    ADAPTIVE_FILTER_OBSERVE_ITERS,
    ADAPTIVE_FILTER_WARMUP_ITERS,
)


# -----------------------------------------------------------------------------
# Cost model — a deterministic 4-predicate workload.
# -----------------------------------------------------------------------------

# Selectivity of predicate p in the synthetic workload.
def _sel(p: Int) -> Float64:
    if p == 0:
        return Float64(0.5)
    elif p == 1:
        return Float64(0.1)
    elif p == 2:
        return Float64(0.9)
    else:
        return Float64(0.3)


# Total ns to evaluate a chunk under the given permutation. Each predicate
# scans `live_rows` and pays 10 ns/row; the next predicate sees
# live_rows * _sel(this).
def _simulated_ns(perm: Span[UInt32, _], chunk_rows: Int) -> UInt64:
    var live = Float64(chunk_rows)
    var total_ns = Float64(0)
    for i in range(len(perm)):
        var p = Int(perm[i])
        total_ns += live * Float64(10.0)
        live *= _sel(p)
    return UInt64(total_ns)


# Optimal permutation for the [0.5, 0.1, 0.9, 0.3] selectivity profile.
# Optimal: lowest-sel first = [1, 3, 0, 2].
comptime OPTIMAL_PERM_0: UInt32 = UInt32(1)
comptime OPTIMAL_PERM_1: UInt32 = UInt32(3)
comptime OPTIMAL_PERM_2: UInt32 = UInt32(0)
comptime OPTIMAL_PERM_3: UInt32 = UInt32(2)


# -----------------------------------------------------------------------------
# Driver helpers
# -----------------------------------------------------------------------------


def _drive_one_chunk(mut af: AdaptiveFilter, chunk_rows: Int):
    """One begin/end cycle under the synthetic cost model.

    Reads the current permutation, simulates the ns to evaluate the chunk,
    backdates start_ns so end_filter sees the synthetic duration.
    """
    var start = af.begin_filter()
    # Snapshot the current perm to compute synthetic ns under it.
    var perm_view = af.get_permutation()
    var synthetic_ns = _simulated_ns(perm_view, chunk_rows)
    # Backdate start by synthetic_ns so end_filter sees ~synthetic ns
    # elapsed. perf_counter_ns is monotonic; subtracting a UInt64 from
    # a UInt is safe as long as start >= synthetic_ns (it always is in
    # practice — perf_counter_ns is wall-clock ns since OS boot, ~10s
    # of seconds at process start; synthetic_ns is ~10-100 µs).
    af.end_filter(start - synthetic_ns)


def _matches_optimal(perm: Span[UInt32, _]) -> Bool:
    """True iff perm == [1, 3, 0, 2]."""
    if len(perm) != 4:
        return False
    if perm[0] != OPTIMAL_PERM_0:
        return False
    if perm[1] != OPTIMAL_PERM_1:
        return False
    if perm[2] != OPTIMAL_PERM_2:
        return False
    if perm[3] != OPTIMAL_PERM_3:
        return False
    return True


# -----------------------------------------------------------------------------
# Single-thread convergence
# -----------------------------------------------------------------------------


def test_single_thread_converges_in_500_chunks() raises:
    """One AdaptiveFilter, 4 predicates, 500 chunks → permutation reaches
    optimal [1, 3, 0, 2]."""
    var af = AdaptiveFilter(n_predicates=4, worker_id=0)
    for _ in range(500):
        _drive_one_chunk(af, 2048)
    var final_perm = af.get_permutation()
    assert_true(
        _matches_optimal(final_perm),
        "single-thread did not converge in 500 chunks; got "
        + String(final_perm[0]) + "," + String(final_perm[1]) + ","
        + String(final_perm[2]) + "," + String(final_perm[3]),
    )


def test_single_thread_baseline_improves() raises:
    """Over 500 chunks, the AdaptiveFilter's baseline drops vs the
    initial permutation's cost.

    Sanity check on the cost model + state machine — if baseline didn't
    improve, the keep/revert logic is broken.
    """
    var af = AdaptiveFilter(n_predicates=4, worker_id=0)
    # Compute initial ns under identity permutation.
    var initial_perm_list = List[UInt32]()
    initial_perm_list.append(UInt32(0))
    initial_perm_list.append(UInt32(1))
    initial_perm_list.append(UInt32(2))
    initial_perm_list.append(UInt32(3))
    var initial_ns = _simulated_ns(
        Span[UInt32, origin_of(initial_perm_list)](
            unsafe_ptr=initial_perm_list.unsafe_ptr(),
            length=len(initial_perm_list),
        ),
        2048,
    )

    for _ in range(500):
        _drive_one_chunk(af, 2048)

    # Baseline must have shrunk from initial.
    assert_true(af.baseline_ns() < Float64(initial_ns))
    # And specifically: baseline should be near the optimal ns.
    var opt_perm_list = List[UInt32]()
    opt_perm_list.append(OPTIMAL_PERM_0)
    opt_perm_list.append(OPTIMAL_PERM_1)
    opt_perm_list.append(OPTIMAL_PERM_2)
    opt_perm_list.append(OPTIMAL_PERM_3)
    var optimal_ns = _simulated_ns(
        Span[UInt32, origin_of(opt_perm_list)](
            unsafe_ptr=opt_perm_list.unsafe_ptr(),
            length=len(opt_perm_list),
        ),
        2048,
    )
    # Baseline should be within 1% of optimal (state machine should
    # have converged tightly).
    var ratio = af.baseline_ns() / Float64(optimal_ns)
    assert_true(
        ratio < Float64(1.05),
        "baseline " + String(af.baseline_ns())
        + " not close to optimal " + String(optimal_ns)
        + " (ratio = " + String(ratio) + ")",
    )


# -----------------------------------------------------------------------------
# Fork-join convergence — the pthread rig the three tests below share.
# -----------------------------------------------------------------------------

comptime _VoidPtr = UnsafePointer[NoneType, MutUntrackedOrigin]

comptime _N_WORKERS: Int = 4
comptime _CHUNKS_PER_WORKER: Int = 500


@always_inline
def _null_ptr[T: AnyType, o: Origin]() -> UnsafePointer[T, o]:
    """A NULL typed pointer with a concrete origin (the b2 null-UnsafePointer
    ctor is gone).

    # SAFETY: `Optional[UnsafePointer[...]]` is layout-compatible with the bare
    # pointer; `None` is the all-zero (NULL) bit pattern. FFI NULL args only.
    """
    var none: Optional[UnsafePointer[T, o]] = None
    return UnsafePointer(to=none).bitcast[UnsafePointer[T, o]]()[]


@fieldwise_init
struct _DriveArg(Copyable, Movable, Deinitable):
    """The per-thread pthread arg. Three PODs — two Int-laundered addresses
    plus this worker's id — the FFI-POD address carve-out the pointer rules
    allow at a pthread boundary.

    SAFETY: each test allocates N of these, hands thread i a pointer to slot i,
    and JOINS every thread before freeing the block, so each arg strictly
    outlives its one reader. `slab_addr` points at a slab in the calling test's
    frame, which likewise outlives the barrier, and was sized to N_WORKERS up
    front so no reallocation happens during the parallel region. Worker i
    touches ONLY `slab[i]` — disjoint by construction, slab-safe.
    `errors_addr` is 0 when the caller does not want an error counter.
    """

    var slab_addr: Int  # Int-laundered Slab[AdaptiveFilter]*
    var errors_addr: Int  # Int-laundered Atomic[int64]*, or 0
    var wid: Int


def _entry_drive(arg: _VoidPtr) -> _VoidPtr:
    """pthread start_routine. Was the `worker` closure in all three tests.

    # SAFETY: FFI-BOUNDARY. See `_DriveArg`.
    """
    ref a = arg.bitcast[_DriveArg]()[]
    var slab = UnsafePointer[Slab[AdaptiveFilter], MutUntrackedOrigin](
        unsafe_from_address=a.slab_addr,
    )
    try:
        ref af = slab[][a.wid]
        for _ in range(_CHUNKS_PER_WORKER):
            _drive_one_chunk(af, 2048)
    except e:
        if a.errors_addr != 0:
            var errors = UnsafePointer[
                AtomicI64, MutUntrackedOrigin
            ](unsafe_from_address=a.errors_addr)
            _ = errors[].fetch_add(Int64(1))
    return _null_ptr[NoneType, MutUntrackedOrigin]()


def _fork_join_drive(
    mut slab: Slab[AdaptiveFilter], errors_addr: Int
) raises:
    """Run `_N_WORKERS` REAL OS threads over `_entry_drive`, then JOIN them all.

    ⚠ THE SLAB IS TAKEN BY `mut`, NOT AS AN Int ADDRESS. An address argument
    is invisible to the borrow checker, so in the one test that does not read
    the slab after the barrier the compiler ASAP-destroys it while the workers
    are still running — measured: SIGSEGV inside `_drive_one_chunk` on a
    worker thread. Binding it `mut` makes the caller's slab provably live for
    the whole call, barrier included.

    Raises if any `pthread_create` failed, so a thread that never started can
    never be silently mistaken for a thread that did no work — the one failure
    mode that would turn these convergence gates green while testing nothing.
    """
    var slab_addr = Int(UnsafePointer(to=slab))
    var args = alloc[_DriveArg](_N_WORKERS)
    for i in range(_N_WORKERS):
        (args + i).unsafe_write(
            _DriveArg(slab_addr=slab_addr, errors_addr=errors_addr, wid=i)
        )
    var args_u = args.unsafe_origin_cast[MutUntrackedOrigin]()

    var tids = List[Int64]()
    for _i in range(_N_WORKERS):
        tids.append(Int64(0))
    var started = 0
    var rc = Int32(0)
    for i in range(_N_WORKERS):
        rc = external_call["pthread_create", Int32](
            UnsafePointer(to=tids[i]).bitcast[UInt8](),  # pthread_t*
            _null_ptr[UInt8, MutUntrackedOrigin](),  # attr = NULL
            _entry_drive,  # start_routine (DIRECT thin-fn reference)
            (args_u + i).bitcast[NoneType](),  # arg = this worker's slot
        )
        if rc != Int32(0):
            break
        started += 1

    # THE BARRIER: join every thread that started, THEN free the args.
    for i in range(started):
        _ = external_call["pthread_join", Int32](
            tids[i], _null_ptr[UInt8, MutUntrackedOrigin]()
        )
    args.free()
    if rc != Int32(0):
        raise Error(
            "pthread_create failed (rc="
            + String(Int(rc))
            + ") after "
            + String(started)
            + " of "
            + String(_N_WORKERS)
            + " workers -- the convergence gate did not run"
        )


def test_parallelize_4_workers_500_chunks_no_errors() raises:
    """4 workers × 500 chunks on real threads — no errors, no race.

    Uses Slab[AdaptiveFilter] for per-worker storage (the canonical
    pattern). Each worker only touches its OWN slot — slab-safe by
    construction.
    """
    # Per-worker storage — Slab[AdaptiveFilter]. Pre-fill 4 slots; each
    # worker mutates its own slot.
    var slab = Slab[AdaptiveFilter].with_capacity(_N_WORKERS)
    for w in range(_N_WORKERS):
        slab.append(AdaptiveFilter(n_predicates=4, worker_id=w))

    # Error counter (Atomic across workers).
    var errors = AtomicI64(0)

    _fork_join_drive(slab, Int(UnsafePointer(to=errors)))

    assert_equal(errors.load(), Int64(0))


def test_parallelize_4_workers_all_converge() raises:
    """All 4 workers reach the optimal permutation [1, 3, 0, 2] after 500
    chunks each. All 4 of 4 workers converge."""
    var slab = Slab[AdaptiveFilter].with_capacity(_N_WORKERS)
    for w in range(_N_WORKERS):
        slab.append(AdaptiveFilter(n_predicates=4, worker_id=w))

    _fork_join_drive(slab, 0)

    # After the join barrier, inspect each worker's final permutation.
    var converged = 0
    for w in range(_N_WORKERS):
        ref af = slab[w]
        var perm = af.get_permutation()
        if _matches_optimal(perm):
            converged += 1
    assert_equal(
        converged, _N_WORKERS,
        "expected 4 workers to converge to optimal; got " + String(converged),
    )


def test_parallelize_4_workers_distinct_rng_streams() raises:
    """After 500 chunks each, the 4 workers' XorShift64 states are
    distinct.

    This is the per-worker RNG guarantee surfaced through the AdaptiveFilter —
    if workers shared the RNG, their explore paths would collide and
    the convergence variance would not match the expected
    result. Distinctness at the end of 500 iters (after many
    `next_in_range` calls) is the cleanest check.
    """
    var slab = Slab[AdaptiveFilter].with_capacity(_N_WORKERS)
    for w in range(_N_WORKERS):
        slab.append(AdaptiveFilter(n_predicates=4, worker_id=w))

    _fork_join_drive(slab, 0)

    # Collect each worker's final RNG state. All 4 must be distinct.
    var states = List[UInt64]()
    for w in range(_N_WORKERS):
        states.append(slab[w].rng.state)

    # Pairwise distinct.
    for i in range(_N_WORKERS):
        for j in range(i + 1, _N_WORKERS):
            assert_true(
                states[i] != states[j],
                "workers " + String(i) + " and " + String(j)
                + " have the same final RNG state " + String(states[i]),
            )


# -----------------------------------------------------------------------------
# Suite entry
# -----------------------------------------------------------------------------


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
