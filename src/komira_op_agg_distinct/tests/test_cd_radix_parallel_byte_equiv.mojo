# =============================================================================
# test_cd_radix_parallel_byte_equiv.mojo
#   — the radix-per-value-partition parallel COUNT(DISTINCT)
#     (`cd_radix_parallel.radix_distinct_count[_multi]`) is EXACT against a
#     serial one-hash-set dedup, on both of its arms, and is guarded against
#     DOUBLE-UNION inflation (the disjoint-partition-sum invariant).
# =============================================================================
#
# WHAT THIS PROVES:
#   The driver partitions the values by a value HASH into P disjoint
#   partitions, dedups each partition IN PARALLEL, and SUMS the per-partition
#   distinct counts. Correctness rests on DISJOINTNESS: equal values hash
#   identically, so they land in the SAME partition and the per-partition
#   distinct sets never overlap.
#
#   FAILS ON A BROKEN PARTITIONER: if the hash split let a value straddle two
#   partitions (or a task double-counted), the sum would be INFLATED above the
#   true distinct count. The `all_same` (N copies of ONE value -> must be 1, not
#   N) and `heavy_dup` (each distinct repeated K times -> must be D, not D*K)
#   cases are the checks for this. A dropped partition or slice DEFLATES the count,
#   which the exact comparisons catch from the other side.
#
#   Both arms are driven through `CdRadixOptions`: the serial-scatter arm
#   (below `scatter_min`) and the parallel-scatter arm (at or above it), each
#   with buffer release on the worker on and off. Every case compares to an
#   independent serial count EXACTLY.
#
# The parallel-across-groups driver is tested in
# `test_cd_radix_grouped_byte_equiv`.
# =============================================================================

from std.collections import List
from std.testing import TestSuite, assert_equal, assert_true

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime
from komira_op_agg_distinct.cd_radix_parallel import (
    CdRadixOptions,
    radix_distinct_count,
    radix_distinct_count_multi,
    _cd_dedup_count_serial,
    _cd_dedup_count_serial_multi,
    _cd_partition_divfree,
    _CD_RADIX_MIN_ROWS,
    _CD_RADIX_PARALLEL_SCATTER_MIN,
)


comptime _N = 300_000  # > _CD_RADIX_PARALLEL_SCATTER_MIN: the parallel-scatter arm
# A size the DEFAULT options route to the serial-scatter arm: the band
# [_CD_RADIX_MIN_ROWS, _CD_RADIX_PARALLEL_SCATTER_MIN).
comptime _LEGACY_N = 100_000
# `scatter_min` above every fixture here: pins the serial-scatter arm.
comptime _PIN_SERIAL_SCATTER = 32_000_000


def _make_noop_sink() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _make_runtime(n_workers: Int) raises -> PerCoreAsyncRuntime[NoopSink]:
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(n_workers, _make_noop_sink, BACKEND_MOCK)
    rt.start()
    return rt^


def _options(scatter_min: Int, freepar: Bool) -> CdRadixOptions:
    var o = CdRadixOptions()
    o.scatter_min = scatter_min
    o.freepar = freepar
    return o^


def _parallel_count(
    imm vals: List[Int64],
    options: CdRadixOptions = CdRadixOptions(),
    workers: Int = 8,
) raises -> Int64:
    """Drive `radix_distinct_count` over a real multi-worker dispatcher."""
    var rt = _make_runtime(workers)
    ref disp = rt.dispatcher()
    return radix_distinct_count(
        vals.copy(), disp, CancellationToken.new(), options
    )


def _parallel_count_multi(
    imm runs: List[List[Int64]],
    options: CdRadixOptions = CdRadixOptions(),
    workers: Int = 8,
) raises -> Int64:
    """Drive `radix_distinct_count_multi` over a real multi-worker dispatcher:
    the several buffers are scattered together, with no prior concatenation."""
    var rt = _make_runtime(workers)
    ref disp = rt.dispatcher()
    var runs_copy = List[List[Int64]]()
    for r in range(len(runs)):
        runs_copy.append(runs[r].copy())
    return radix_distinct_count_multi(
        runs_copy^, disp, CancellationToken.new(), options
    )

def test_radix_distinct_byte_exact_vs_serial() raises:
    """Mixed dups: parallel radix count == serial one-set count, EXACTLY. The
    value pattern spans many hash partitions with a non-trivial distinct set."""
    var vals = List[Int64](capacity=_N)
    for i in range(_N):
        # ~50K distinct values (i % 50000), each repeated ~6x across the buffer.
        vals.append(Int64(i % 50_000))
    var serial = _cd_dedup_count_serial(vals)
    var parallel = _parallel_count(vals)
    assert_equal(serial, Int64(50_000))
    assert_equal(parallel, serial)


def test_radix_distinct_all_unique() raises:
    """N unique values -> count == N (no partition can drop a value)."""
    var vals = List[Int64](capacity=_N)
    for i in range(_N):
        vals.append(Int64(i) * Int64(1_000_003))  # spread across partitions
    var parallel = _parallel_count(vals)
    assert_equal(parallel, Int64(_N))
    assert_equal(parallel, _cd_dedup_count_serial(vals))


def test_radix_distinct_all_same_no_inflation() raises:
    """N copies of ONE value -> count MUST be 1. A double-union bug (a value
    straddling two partitions, or a re-counted partition) would inflate this
    toward N — the strictest double-union check."""
    var vals = List[Int64](capacity=_N)
    for _ in range(_N):
        vals.append(Int64(42))
    var parallel = _parallel_count(vals)
    assert_equal(parallel, Int64(1))
    assert_equal(parallel, _cd_dedup_count_serial(vals))


def test_radix_distinct_heavy_dup_no_inflation() raises:
    """Each of D distinct values repeated K times (interleaved, as a cross-worker
    concat would produce) -> count MUST be D, not D*K. Guards the disjoint-
    partition SUM against double-union inflation permanently."""
    comptime D = 20_000
    comptime K = 15
    var vals = List[Int64](capacity=D * K)
    for k in range(K):
        for d in range(D):
            _ = k
            vals.append(Int64(d) * Int64(7))  # same D values, K interleaved passes
    var serial = _cd_dedup_count_serial(vals)
    var parallel = _parallel_count(vals)
    assert_equal(serial, Int64(D))
    assert_equal(parallel, serial)


def test_radix_distinct_empty() raises:
    """Empty buffer -> 0 (COUNT(DISTINCT) of nothing is 0)."""
    var vals = List[Int64]()
    assert_equal(_parallel_count(vals), Int64(0))


# =============================================================================
# PERF-CD-PARALLEL-COMBINE: the MULTI-BUFFER concat-free scatter.
#
# The per-worker CD value buffers are NO LONGER concatenated into worker-0 before
# the radix dedup — they are scattered TOGETHER by `radix_distinct_count_multi`.
# The disjoint-partition-sum + no-double-union invariants from the single-buffer
# cases above MUST extend to the multi-buffer scatter: a value present in TWO
# workers' buffers hashes identically → lands in ONE partition → is deduped ONCE
# (NOT counted per-buffer). These overlapping-per-worker fixtures are the explicit
# cross-buffer dedup checks.
# =============================================================================


def test_multi_single_run_equals_single_buffer() raises:
    """A ONE-run list == the single-buffer driver, EXACTLY (the delegation path is
    byte-identical — `radix_distinct_count` wraps `radix_distinct_count_multi`)."""
    var vals = List[Int64](capacity=_N)
    for i in range(_N):
        vals.append(Int64(i % 50_000))
    var runs = List[List[Int64]]()
    runs.append(vals.copy())
    assert_equal(_parallel_count_multi(runs), _parallel_count(vals))
    assert_equal(_parallel_count_multi(runs), Int64(50_000))


def test_multi_cross_buffer_value_counts_once() raises:
    """THE cross-buffer dedup heart: the SAME 40K distinct values placed in THREE
    separate per-worker buffers -> count MUST be 40K, NOT 120K. A per-buffer count
    (no cross-buffer dedup) would inflate this 3x — the strictest check that the
    concat-free scatter still dedups equal values across buffers."""
    comptime D = 40_000
    var runs = List[List[Int64]]()
    for _w in range(3):
        var buf = List[Int64](capacity=D)
        for d in range(D):
            buf.append(Int64(d) * Int64(11))  # identical value set in every buffer
        runs.append(buf^)
    # Independent serial-across-runs oracle: also 40K.
    assert_equal(_cd_dedup_count_serial_multi(runs), Int64(D))
    assert_equal(_parallel_count_multi(runs), Int64(D))


def test_multi_disjoint_buffers_sum() raises:
    """Buffers with DISJOINT value ranges -> count == sum of per-buffer distinct
    (nothing to dedup across buffers, but the union must still be exact)."""
    comptime PER = 60_000
    var runs = List[List[Int64]]()
    for w in range(4):
        var buf = List[Int64](capacity=PER)
        for d in range(PER):
            # disjoint blocks: worker w owns [w*PER, (w+1)*PER)
            buf.append(Int64(w * PER + d))
        runs.append(buf^)
    assert_equal(_parallel_count_multi(runs), Int64(4 * PER))
    assert_equal(_parallel_count_multi(runs), _cd_dedup_count_serial_multi(runs))


def test_multi_partial_overlap_vs_serial() raises:
    """Partially-overlapping per-worker buffers (adjacent workers share half their
    value range) -> parallel multi count == serial-across-runs oracle, EXACTLY.
    The overlap straddles buffers, so a value in two buffers must count once."""
    comptime PER = 80_000
    comptime STRIDE = 40_000  # worker w and w+1 share [w*STRIDE+... ] overlap
    var runs = List[List[Int64]]()
    for w in range(4):
        var buf = List[Int64](capacity=PER)
        for d in range(PER):
            buf.append(Int64(w * STRIDE + d))  # overlaps the next worker's range
        runs.append(buf^)
    # Union of [0,80k) ∪ [40k,120k) ∪ [80k,160k) ∪ [120k,200k) = [0, 200k) = 200k.
    var serial = _cd_dedup_count_serial_multi(runs)
    assert_equal(serial, Int64(200_000))
    assert_equal(_parallel_count_multi(runs), serial)


def test_multi_all_same_across_buffers_no_inflation() raises:
    """Every one of several buffers is full of the SAME single value -> count MUST
    be 1, not (n_buffers * copies). The multi-buffer double-union check."""
    var runs = List[List[Int64]]()
    for _w in range(5):
        var buf = List[Int64](capacity=_N)
        for _ in range(_N):
            buf.append(Int64(42))
        runs.append(buf^)
    assert_equal(_parallel_count_multi(runs), Int64(1))
    assert_equal(_parallel_count_multi(runs), _cd_dedup_count_serial_multi(runs))


def test_multi_empty_and_mixed_runs() raises:
    """Empty runs interleaved with non-empty runs (a worker that received no rows)
    -> count over the non-empty union, exact. Empty runs contribute nothing."""
    var runs = List[List[Int64]]()
    runs.append(List[Int64]())  # empty worker
    var b1 = List[Int64](capacity=_N)
    for i in range(_N):
        b1.append(Int64(i % 30_000))
    runs.append(b1^)
    runs.append(List[Int64]())  # another empty worker
    var b2 = List[Int64](capacity=_N)
    for i in range(_N):
        b2.append(Int64((i % 30_000) + 15_000))  # overlaps b1 on [15k,30k)
    runs.append(b2^)
    # b1 covers [0,30k), b2 covers [15k,45k) -> union [0,45k) = 45k distinct.
    var serial = _cd_dedup_count_serial_multi(runs)
    assert_equal(serial, Int64(45_000))
    assert_equal(_parallel_count_multi(runs), serial)


# =============================================================================
# PERF-CB-COUNTDISTINCT-CACHEPART: the LARGE-n cache-sized-partition
# + PARALLEL-scatter path.
#
# For n >= _CD_RADIX_PARALLEL_SCATTER_MIN the driver decouples the partition
# count P from the worker count (sizing P so each partition's dedup table is
# L2-resident) AND scatters in PARALLEL into a [slice][partition] matrix (each
# scatter task writes only its own row). The exact distinct count is INVARIANT to
# P and to scatter parallelism (partitions are disjoint by value-hash; the sets
# are exact) — these fixtures cross the threshold on EITHER value to exercise
# that path and
# prove it is byte-exact to the independent serial-across-runs oracle. The small-n
# fixtures above never engage it, so without these the new path would be UNTESTED.
# =============================================================================


comptime _NBIG = 2_500_000  # far above _CD_RADIX_PARALLEL_SCATTER_MIN


def test_large_n_cache_partition_byte_exact_vs_serial() raises:
    """LARGE-n mixed dups (n=2.5M > 2M) -> parallel radix count == serial oracle,
    EXACTLY. ~1.25M distinct values (i % 1_250_000) each repeated ~2x, spread
    across the (now many) partitions. FAILS ON a broken parallel scatter (a value
    scattered to two partitions, or a matrix column double-read) — the count would
    diverge from the serial one-set oracle."""
    var vals = List[Int64](capacity=_NBIG)
    for i in range(_NBIG):
        vals.append(Int64(i % 1_250_000))
    var serial = _cd_dedup_count_serial(vals)
    assert_equal(serial, Int64(1_250_000))
    assert_equal(_parallel_count(vals), serial)


def test_large_n_all_unique() raises:
    """LARGE-n all-unique (n=2.5M > 2M) -> count == n (no partition drops a
    value under the parallel scatter / cache-sized P)."""
    var vals = List[Int64](capacity=_NBIG)
    for i in range(_NBIG):
        vals.append(Int64(i) * Int64(2_654_435_761))  # spread across partitions
    assert_equal(_parallel_count(vals), Int64(_NBIG))
    assert_equal(_parallel_count(vals), _cd_dedup_count_serial(vals))


def test_large_n_all_same_no_inflation() raises:
    """LARGE-n all-same (n=2.5M > 2M) -> count MUST be 1. The strictest new-path
    double-union check: a value duplicated into two matrix partitions, or a
    partition column counted twice, would inflate this toward n."""
    var vals = List[Int64](capacity=_NBIG)
    for _ in range(_NBIG):
        vals.append(Int64(42))
    assert_equal(_parallel_count(vals), Int64(1))


def test_large_n_multi_cross_buffer_counts_once() raises:
    """LARGE-n cross-buffer dedup (total n=3M > 2M): the SAME 1.5M distinct values
    in TWO separate per-worker runs -> count MUST be 1.5M, NOT 3M. The parallel
    scatter must place a value from EITHER run into the SAME partition so the
    cross-buffer dedup still collapses it."""
    comptime D = 1_500_000
    var runs = List[List[Int64]]()
    for _w in range(2):
        var buf = List[Int64](capacity=D)
        for d in range(D):
            buf.append(Int64(d) * Int64(2_654_435_761))
        runs.append(buf^)
    assert_equal(_cd_dedup_count_serial_multi(runs), Int64(D))
    assert_equal(_parallel_count_multi(runs), Int64(D))


def test_large_n_multi_disjoint_runs_sum() raises:
    """LARGE-n disjoint runs (total n=3M > 2M): 3 runs of 1M disjoint values ->
    count == 3M (nothing to dedup across runs, but the parallel-scattered union
    must still be exact)."""
    comptime PER = 1_000_000
    var runs = List[List[Int64]]()
    for w in range(3):
        var buf = List[Int64](capacity=PER)
        for d in range(PER):
            buf.append(Int64(w * PER + d))  # disjoint blocks
        runs.append(buf^)
    assert_equal(_parallel_count_multi(runs), Int64(3 * PER))
    assert_equal(_parallel_count_multi(runs), _cd_dedup_count_serial_multi(runs))

# =============================================================================
# The LEGACY arm's partition map.
#
# The serial scatter (64K <= n < `scatter_min`) maps a value to its partition
# with `_cd_partition_divfree`, a multiply-shift, instead of
# `_cd_mix_hash(v) % UInt64(nw)` (a 64-bit HARDWARE DIVISION; still selectable with `CdRadixOptions.divfree = False`).
#
# The map is a PURE FUNCTION and its two load-bearing properties are checkable
# directly, which is what these guards do. Nothing else about it is observable:
# the driver's result is invariant to WHICH partition a value lands in, so a map
# with both properties cannot change any count.
#
# The end-to-end coverage pins the serial-scatter arm through
# `CdRadixOptions.scatter_min` (`test_divfree_disjointness_survives_heavy_dup`),
# and `test_serial_scatter_arm_is_reachable_by_default_and_exact` runs the
# driver at `_LEGACY_N` with the default options.
#
#   RANGE       p in [0, nw). An out-of-range p indexes `parts` out of bounds.
#   DETERMINISM equal values -> equal p. THIS IS DISJOINTNESS. If it fails, one
#               value reaches two partitions, each counts it once, and the sum
#               INFLATES above the true distinct count.
#
# FAILS ON: `>> 31` instead of `>> 32` in the final shift (RANGE — at nw=22 it
# returns up to 43); any position- or call-order-dependent term (DETERMINISM);
# and `test_divfree_disjointness_survives_heavy_dup` re-proves the consequence
# end-to-end through the real driver, where a broken map inflates the count by
# the repetition factor rather than merely disagreeing with a formula.
#
# ⚠ NON-POWER-OF-TWO `nw` IS THE CASE THAT MATTERS, and the rest of this file
# does not cover it: `_make_runtime(8)` is a power of two and production runs 22
# workers. Every fixture below uses non-power-of-two worker counts.
# =============================================================================


def test_divfree_partition_in_range() raises:
    """`_cd_partition_divfree(v, nw)` lands in [0, nw) for every worker count we
    dispatch at, over values spanning the Int64 range including negatives and the
    sign-bit boundary (the mix hash bitcasts, so a negative value has the high
    bit set and a sloppy shift surfaces here first).

    FAILS ON a `>> 31` final shift: at nw=22 it returns up to 43, which indexes
    `parts` out of bounds in the driver."""
    var nws = List[Int]()
    nws.append(1); nws.append(2); nws.append(3); nws.append(5)
    nws.append(7); nws.append(8); nws.append(22); nws.append(23)
    nws.append(64); nws.append(88)
    for wi in range(len(nws)):
        var nw = nws[wi]
        for i in range(-2_000, 2_000):
            var p = _cd_partition_divfree(Int64(i), nw)
            assert_true(p >= 0)
            assert_true(p < nw)
        var edge = List[Int64]()
        edge.append(Int64.MIN)
        edge.append(Int64.MAX)
        edge.append(Int64(0))
        edge.append(Int64(-1))
        edge.append(Int64(1) << 62)
        edge.append(-(Int64(1) << 62))
        edge.append(Int64(1) << 32)
        for ei in range(len(edge)):
            var pe = _cd_partition_divfree(edge[ei], nw)
            assert_true(pe >= 0)
            assert_true(pe < nw)


def test_divfree_partition_is_deterministic() raises:
    """Equal values map to equal partitions — the DISJOINTNESS invariant stated
    as a property of the map itself. The value is reached by three different
    routes (a copy out of a List, a fresh recomputation, and arithmetic that
    lands back on it) so the check cannot be satisfied by memoisation.

    FAILS ON any map that mixes in a position, a counter, or a worker id."""
    var nw = 22
    var vals = List[Int64]()
    for i in range(5_000):
        vals.append(Int64(i * 7919 - 3_000))
    for i in range(len(vals)):
        var v = vals[i]
        var a = _cd_partition_divfree(v, nw)
        var b = _cd_partition_divfree(Int64(i * 7919 - 3_000), nw)
        var c = _cd_partition_divfree(vals[i] + Int64(1) - Int64(1), nw)
        assert_equal(a, b)
        assert_equal(a, c)


def test_divfree_partition_uses_every_partition() raises:
    """A NON-DEGENERATE map: with 22 partitions and 220K values, every partition
    is non-empty and none holds more than 4x the mean.

    Not a uniformity proof and not meant to be one — it is the floor that catches
    a map which COLLAPSES (entropy shifted away, wrong multiply operand), which
    would silently serialise the dedup onto one worker rather than return a wrong
    answer. A wrong ANSWER is what the oracles above are for; this catches the
    wrong SHAPE."""
    var nw = 22
    var counts = List[Int]()
    for _ in range(nw):
        counts.append(0)
    comptime NV = 220_000
    for i in range(NV):
        counts[_cd_partition_divfree(Int64(i), nw)] += 1
    var mean = NV // nw
    for p in range(nw):
        assert_true(counts[p] > 0)
        assert_true(counts[p] < 4 * mean)


def test_divfree_disjointness_survives_heavy_dup() raises:
    """END-TO-END consequence of the two properties, through the real driver on
    the SERIAL-SCATTER arm (the only user of this map, pinned through
    `scatter_min`) with a NON-power-of-two worker count, under both maps.

    Each of 25,000 distinct values is repeated 12x. A map that let one value
    reach two partitions inflates the count toward 25,000*k; the assertion is the
    exact 25,000. Negative values are included because both maps hash the same
    bitcast value, so sign handling has to match."""
    comptime D = 25_000
    comptime K = 12
    var vals = List[Int64](capacity=D * K)
    for _k in range(K):
        for d in range(D):
            vals.append(Int64(d) - Int64(D // 2))  # spans negative + positive
    assert_equal(len(vals), D * K)
    var serial = _cd_dedup_count_serial(vals)
    assert_equal(serial, Int64(D))
    for divfree in [True, False]:
        var o = _options(_PIN_SERIAL_SCATTER, True)
        o.divfree = divfree
        assert_equal(_parallel_count(vals, o, 7), serial)

# =============================================================================
# `freepar` — the dedup tasks release the buffers they consumed
# =============================================================================
#
# With `freepar` each dedup task frees a buffer on its worker right after
# reading it, instead of the driver freeing every buffer after the barrier. It
# cannot change a count, so the fixtures are written against the way it
# BREAKS: a release that lands before, rather than after, the read. That break
# is DETERMINISTIC: `swap` + drop leaves an EMPTY List in the slot, so a release
# hoisted above its read makes the task insert nothing and the count falls far
# below the exact one. The release has two call sites (`_CDDedupTask` on the
# serial-scatter arm, `_CDDedupMultiTask` on the parallel-scatter arm), so each
# arm has its own fixture, and the `freepar = False` control must stay green
# when the release path is wrong.


def test_freepar_serial_scatter_arm_matches_serial_oracle() raises:
    """SERIAL-SCATTER arm (pinned), `freepar` on, non-power-of-two workers.
    30,000 distinct values each repeated 10x, so a partition whose buffer was
    released before it was read contributes 0 and the total lands far below
    the exact 30,000."""
    comptime D = 30_000
    comptime K = 10
    var vals = List[Int64](capacity=D * K)
    for _k in range(K):
        for d in range(D):
            vals.append(Int64(d) - Int64(D // 2))
    var serial = _cd_dedup_count_serial(vals)
    assert_equal(serial, Int64(D))
    assert_equal(
        _parallel_count(vals, _options(_PIN_SERIAL_SCATTER, True), 7), serial
    )


def test_freepar_parallel_arm_matches_serial_oracle() raises:
    """PARALLEL-SCATTER arm (2.5M values), `freepar` on: the release runs
    inside the per-scatter-task loop, so it must be ordered against EACH
    scatter task's buffer and not merely once per dedup task."""
    var vals = List[Int64](capacity=_NBIG)
    for i in range(_NBIG):
        vals.append(Int64(i % 1_250_000))
    var serial = _cd_dedup_count_serial(vals)
    assert_equal(serial, Int64(1_250_000))
    assert_equal(
        _parallel_count(vals, _options(_CD_RADIX_PARALLEL_SCATTER_MIN, True)),
        serial,
    )


def test_freepar_parallel_arm_multi_run_cross_buffer() raises:
    """PARALLEL-SCATTER arm, SIX runs, `freepar` on. A value present in several
    runs must still be counted ONCE, and a premature release drops whole
    scatter-task columns, so the count falls BELOW the oracle (the opposite
    direction to a disjointness break, which inflates)."""
    var runs = List[List[Int64]]()
    for r in range(6):
        var run = List[Int64](capacity=525_000)
        # 450,000 values SHARED by every run ...
        for i in range(450_000):
            run.append(Int64(i))
        # ... plus 75,000 private to run r, so the exact union is 900,000.
        for i in range(75_000):
            run.append(Int64(450_000 + r * 75_000 + i))
        runs.append(run^)
    var serial = _cd_dedup_count_serial_multi(runs)
    assert_equal(serial, Int64(900_000))
    assert_equal(
        _parallel_count_multi(
            runs, _options(_CD_RADIX_PARALLEL_SCATTER_MIN, True)
        ),
        serial,
    )


def test_freepar_off_is_still_exact_on_both_arms() raises:
    """THE CONTROL: the same fixtures with `freepar` off. The release path is
    not exercised here, so these hold whether or not it is correct."""
    var vals = List[Int64](capacity=_NBIG)
    for i in range(_NBIG):
        vals.append(Int64(i % 1_250_000))
    assert_equal(
        _parallel_count(vals, _options(_CD_RADIX_PARALLEL_SCATTER_MIN, False)),
        Int64(1_250_000),
    )
    var small = List[Int64](capacity=_LEGACY_N)
    for i in range(_LEGACY_N):
        small.append(Int64(i % 20_000))
    assert_equal(
        _parallel_count(small, _options(_PIN_SERIAL_SCATTER, False), 7),
        Int64(20_000),
    )


# =============================================================================
# The arm threshold (`scatter_min`)
# =============================================================================
#
# Below `scatter_min` values the driver scatters SERIALLY on itself; at or
# above it the scatter runs in parallel into cache-sized partitions. The two
# arms must return the same count for the same input (otherwise a wall-time
# difference between them would be a different answer, not a faster one), and
# the default threshold must leave the serial-scatter arm reachable: a
# threshold at or below `_CD_RADIX_MIN_ROWS` would make it dead code that every
# oracle written against it keeps passing over.


def test_both_arms_agree_on_the_same_input() raises:
    """The same multi-run input through the serial-scatter arm (pinned) and the
    parallel-scatter arm (`scatter_min` at the minimum) returns the same exact
    count. Every run carries the SAME 40,000 values: a run counted twice
    inflates, one dropped deflates."""
    comptime D = 40_000
    var runs = List[List[Int64]]()
    for _r in range(4):
        var buf = List[Int64](capacity=D)
        for d in range(D):
            buf.append(Int64(d) * Int64(7) - Int64(11))
        runs.append(buf^)
    var serial_scatter = _parallel_count_multi(
        runs, _options(_PIN_SERIAL_SCATTER, True), 7
    )
    var parallel_scatter = _parallel_count_multi(
        runs, _options(_CD_RADIX_MIN_ROWS, True), 7
    )
    assert_equal(serial_scatter, Int64(D))
    assert_equal(parallel_scatter, serial_scatter)


def test_serial_scatter_arm_is_reachable_by_default_and_exact() raises:
    """The default threshold is 125,000 and the serial-scatter band
    [_CD_RADIX_MIN_ROWS, 125,000) is non-empty; a fixture inside it, with the
    DEFAULT options, is exact. (At a default of 62,500, below
    `_CD_RADIX_MIN_ROWS`, the band would be empty and the first assertions
    red.)"""
    var default_min = CdRadixOptions().scatter_min
    assert_equal(default_min, 125_000)
    assert_equal(default_min, _CD_RADIX_PARALLEL_SCATTER_MIN)
    assert_true(default_min > _CD_RADIX_MIN_ROWS)
    assert_true(_LEGACY_N >= _CD_RADIX_MIN_ROWS)
    assert_true(_LEGACY_N < default_min)
    comptime D = 20_000
    comptime K = 5
    var vals = List[Int64](capacity=D * K)
    for _k in range(K):
        for d in range(D):
            vals.append(Int64(d) - Int64(D // 2))
    assert_equal(len(vals), _LEGACY_N)
    var serial = _cd_dedup_count_serial(vals)
    assert_equal(serial, Int64(D))
    assert_equal(_parallel_count(vals, CdRadixOptions(), 7), serial)


def test_parallel_scatter_arm_exact_in_the_mid_band() raises:
    """300,000 values on 7 workers: at or above the default threshold, so the
    parallel-scatter arm runs. 30,000 distinct values each repeated 10x: a
    value-hash partition that was mis-assigned, or a slice dropped at a run
    boundary, lands the total below the exact 30,000."""
    comptime D = 30_000
    comptime K = 10
    var vals = List[Int64](capacity=D * K)
    for _k in range(K):
        for d in range(D):
            vals.append(Int64(d) - Int64(D // 2))
    assert_true(len(vals) >= _CD_RADIX_PARALLEL_SCATTER_MIN)
    var serial = _cd_dedup_count_serial(vals)
    assert_equal(serial, Int64(D))
    assert_equal(_parallel_count(vals, CdRadixOptions(), 7), serial)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
