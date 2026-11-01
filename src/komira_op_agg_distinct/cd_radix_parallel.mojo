# =============================================================================
# cd_radix_parallel.mojo — radix-per-value-partition parallel COUNT(DISTINCT)
# of Int64 values
# =============================================================================
#
# The typed-stage COUNT(DISTINCT) buffers every fed value per group and counts
# the distinct ones at finalize. A serial dedup of one large buffer is the whole
# wall of a scalar `count(DISTINCT <integer column>)` over a very large column. This primitive
# partitions the values by a value HASH into P disjoint partitions, dedups each
# partition in PARALLEL (`run_with_state`, one task per partition) and SUMS the
# per-partition distinct counts. Equal values hash identically, so they land in
# the SAME partition: the per-partition distinct sets never overlap and their
# sizes sum to the exact global distinct count.
#
# INTEGER inputs ONLY — the caller gates on the integer family, so the Int64
# widening is exact and a value-hash partition is an equality partition (a float
# `-0.0 == 0.0` or NaN would diverge).
#
# `radix_distinct_count_multi` scatters DIRECTLY from several buffers (the
# per-worker value buffers of one group), so a value present in two buffers is
# deduped once without concatenating them first; `radix_distinct_count` is the
# one-buffer case. Two arms, by value count `n`:
#
#   * below `CdRadixOptions.scatter_min` (125,000 by default; and at least
#     `_CD_RADIX_MIN_ROWS`): the driver scatters SERIALLY into P == nw
#     partitions, then dedups them in parallel;
#   * at or above it: P is sized so each partition's dedup table stays
#     L2-resident (~`_CD_RADIX_TARGET_PART_VALUES` values), and the scatter
#     runs in parallel too: scatter task `s` writes its own row of a
#     [slice][partition] matrix, and dedup task `p` unions column `p`.
#
# Below `_CD_RADIX_MIN_ROWS` values, or with one worker, one serial hash set
# counts everything. Every arm returns the same count; the options only move
# work.
#
# The parallel-across-groups driver of a grouped drain is
# `cd_radix_grouped.radix_distinct_count_grouped`.
#
# Pointer rules: no pointer in a public signature (the dispatcher is borrowed
# `mut`). A dispatch State OWNS every buffer the tasks write (OwnedPointer) and
# the driver swaps it back after the barrier; the buffers the tasks only read
# are borrowed through `Pointer`s whose immutable origins the Task type also
# carries, so each Task's bitcast restores the exact State type and names no
# wildcard origin. (A borrowed MUTABLE origin named by both the State and the
# Task is refused as aliasing, because `run_with_state` takes both `mut`.)
# =============================================================================

from komira_async.runtime.sched_trace import SITE_CD_RADIX
from std.builtin.swap import swap
from std.collections import List
from std.memory import bitcast, OwnedPointer, Pointer, UnsafePointer

from komira_async_api.worker_pool_traits import KeepAlive, Segment

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.local_dispatcher import LocalDispatcher

from komira_op_agg_state.growable_hash_set_i64 import GrowableHashSetI64


# Below this value count the scatter + dispatch overhead is not worth it —
# dedup the whole input serially in one hash set.
comptime _CD_RADIX_MIN_ROWS: Int = 64_000
# Target values per value-hash partition of the parallel-scatter arm. Sized so
# the per-partition dedup table (directory, key and cached hash at ~0.67 load)
# fits in L2 (~1 MB): the per-value probe is an L2 hit, not a DRAM miss.
comptime _CD_RADIX_TARGET_PART_VALUES: Int = 65536
# Ceiling so a huge input does not over-partition (the scatter keeps one live
# append cursor per partition: write-stream and TLB pressure). 4096 partitions
# keep each table L2-resident up to ~256M values.
comptime _CD_RADIX_MAX_PARTITIONS: Int = 4096
# The default arm threshold: at or above this value count the parallel-scatter
# arm runs. The parallel scatter costs one extra fork wave but a much smaller
# per-value cost than the serial scatter on the driver, so it only pays off
# above some value count. 125,000 sits in the middle of the plausible
# break-even band, and it keeps the serial-scatter arm reachable (from
# `_CD_RADIX_MIN_ROWS`).
comptime _CD_RADIX_PARALLEL_SCATTER_MIN: Int = 125_000


@fieldwise_init
struct CdRadixOptions(Copyable, Movable):
    """Which arm the radix drivers take and how they hold memory. The defaults
    are the tuned configuration; every setting returns the same count, so the
    fields exist to let a test drive each arm.

    Fields:
        scatter_min: Value count at or above which the parallel-scatter arm
            runs (below it, the serial-scatter arm, from `_CD_RADIX_MIN_ROWS`).
        divfree: The serial-scatter arm maps a value to its partition by a
            multiply-shift of the hash's top 32 bits (True) or by `hash % nw`
            (False). A runtime-divisor modulo is a real division per value.
        freepar: Each dedup task frees the buffers it consumed, on its worker
            (True), instead of the driver freeing every buffer after the
            barrier (False).
        presize: Each dedup table is created at its partition's exact value
            count (True) instead of growing from the default size (False).
    """

    var scatter_min: Int
    var divfree: Bool
    var freepar: Bool
    var presize: Bool

    def __init__(out self):
        self.scatter_min = _CD_RADIX_PARALLEL_SCATTER_MIN
        self.divfree = True
        self.freepar = True
        self.presize = False


@always_inline
def _cd_mix_hash(v: Int64) -> UInt64:
    """Fibonacci multiplicative hash of `v`'s bits (equal values hash
    identically); its mixing is in the HIGH bits."""
    var b = bitcast[DType.uint64, 1](SIMD[DType.int64, 1](v))[0]
    return b * UInt64(0x9E3779B97F4A7C15)


@always_inline
def _cd_partition_divfree(v: Int64, nw: Int) -> Int:
    """Division-free map of `v`'s mix hash into `[0, nw)`.

    `h >> 32` is uniform on `[0, 2^32)` for a well-mixed `h`, so
    `((h >> 32) * nw) >> 32` is uniform on `[0, nw)` to within a 2^-32 bias
    (Lemire's multiply-shift range reduction). The product cannot overflow:
    `h >> 32 < 2^32` and `nw` is a worker count. It reads the TOP bits, where a
    multiplicative hash carries its mixing (bit 0 of the product is bit 0 of
    `v`).

    A deterministic function of `v` ALONE, so equal values land in the same
    partition — the invariant the driver's sum rests on."""
    var h = _cd_mix_hash(v)
    return Int(((h >> UInt64(32)) * UInt64(nw)) >> UInt64(32))


@always_inline
def _cd_partition_count(n: Int, nw: Int, target_values: Int = 0) -> Int:
    """Power-of-2 value-hash partition count P: sized so each partition holds
    ~`target_values` values (`_CD_RADIX_TARGET_PART_VALUES` when 0), and
    P >= nw so every worker gets at least one partition. Capped at
    `_CD_RADIX_MAX_PARTITIONS`."""
    var tv = (
        target_values if target_values > 0 else _CD_RADIX_TARGET_PART_VALUES
    )
    var target = n // tv
    var p = 1
    while p < target or p < nw:
        p <<= 1
    if p > _CD_RADIX_MAX_PARTITIONS:
        p = _CD_RADIX_MAX_PARTITIONS
    return p


@always_inline
def _cd_presize_hint(n_values: Int, presize: Bool) -> Int:
    """`n_values` when pre-sizing, else 0 (= "no hint", which makes
    `GrowableHashSetI64.with_expected` the default constructor)."""
    return n_values if presize else 0


def _cd_dedup_count_serial(
    imm vals: List[Int64], presize: Bool = False
) -> Int64:
    """Serial exact distinct count of `vals` via one hash set."""
    var s = GrowableHashSetI64.with_expected(
        _cd_presize_hint(len(vals), presize)
    )
    for i in range(len(vals)):
        _ = s.insert(vals[i])
    return Int64(s.size())


def _cd_dedup_count_serial_multi(
    imm runs: List[List[Int64]], presize: Bool = False
) -> Int64:
    """Serial exact distinct count ACROSS several buffers via ONE hash set. A
    value present in two runs is inserted twice into the same set and counted
    once."""
    var n_total = 0
    if presize:
        for r in range(len(runs)):
            n_total += len(runs[r])
    var s = GrowableHashSetI64.with_expected(
        _cd_presize_hint(n_total, presize)
    )
    for r in range(len(runs)):
        for i in range(len(runs[r])):
            _ = s.insert(runs[r][i])
    return Int64(s.size())


# =============================================================================
# Serial-scatter arm: one dedup task per partition.
# =============================================================================


struct _CDDedupState(KeepAlive):
    """Task `p` dedups `parts[p]` and writes `counts[p]`. Both are owned by the
    State for the dispatch."""

    var parts: OwnedPointer[List[List[Int64]]]
    var counts: OwnedPointer[List[Int64]]
    var presize: Bool
    var freepar: Bool

    def __init__(
        out self,
        var parts: List[List[Int64]],
        var counts: List[Int64],
        presize: Bool,
        freepar: Bool,
    ):
        self.parts = OwnedPointer(parts^)
        self.counts = OwnedPointer(counts^)
        self.presize = presize
        self.freepar = freepar

    def __keep_alive(mut self):
        pass


@fieldwise_init
struct _CDDedupTask(Segment):
    """POD discriminator; `execute` dedups this task's value partition."""

    var _pad: Int32

    def execute[State: KeepAlive](
        mut self, mut state: State, worker_id: Int32, task_id: Int64,
    ) raises:
        # SAFETY: the bitcast restores the exact State type the driver passed
        # to `run_with_state`. Partition `p == task_id` is read (and, with
        # `freepar`, released) by exactly this task, and `counts[p]` is
        # written by exactly this task; both outer Lists were sized before the
        # dispatch and are only element-assigned here.
        var sp = UnsafePointer(to=state).bitcast[_CDDedupState]()
        var p = Int(task_id)
        var cnt = _cd_dedup_count_serial(sp[].parts[][p], sp[].presize)
        sp[].counts[][p] = cnt
        if sp[].freepar:
            var dead = List[Int64]()
            swap(sp[].parts[][p], dead)
            _ = dead^

    def __keep_alive(mut self):
        pass


# =============================================================================
# Parallel-scatter arm: a [slice][partition] matrix, then one dedup task per
# partition column.
# =============================================================================


@fieldwise_init
struct _CdSlice(Copyable, Movable):
    """A contiguous [lo, hi) slice of `runs[run]` for one scatter task."""

    var run: Int
    var lo: Int
    var hi: Int


struct _CDScatterState[
    ro: Origin[mut=False],
    slo: Origin[mut=False],
](KeepAlive):
    """Scatter task `s` reads its slice `slices[s]` of `runs`, computes each
    value's partition (the top `log2(np)` bits of the mix hash) and appends
    into its OWN row `matrix[s]`. `runs` and `slices` are borrowed read-only;
    `matrix` is owned by the State for the dispatch."""

    var runs: Pointer[List[List[Int64]], Self.ro]
    var slices: Pointer[List[_CdSlice], Self.slo]
    var matrix: OwnedPointer[List[List[List[Int64]]]]
    var np: Int
    var shift: Int

    def __init__(
        out self,
        ref [Self.ro] runs: List[List[Int64]],
        ref [Self.slo] slices: List[_CdSlice],
        var matrix: List[List[List[Int64]]],
        np: Int,
        shift: Int,
    ):
        self.runs = Pointer(to=runs)
        self.slices = Pointer(to=slices)
        self.matrix = OwnedPointer(matrix^)
        self.np = np
        self.shift = shift

    def __keep_alive(mut self):
        pass


@fieldwise_init
struct _CDScatterTask[
    ro: Origin[mut=False],
    slo: Origin[mut=False],
](Segment):
    """POD discriminator; `execute` scatters this task's input slice into its
    own row of the [slice][partition] matrix."""

    var _pad: Int32

    def execute[State: KeepAlive](
        mut self, mut state: State, worker_id: Int32, task_id: Int64,
    ) raises:
        # SAFETY: the bitcast restores the exact State type (the Task carries
        # the State's two read-only origins). Task `s == task_id` writes ONLY
        # `matrix[s]`, a slot of an outer List sized before the dispatch;
        # `runs` / `slices` are read-only shared borrows.
        var sp = UnsafePointer(to=state).bitcast[
            _CDScatterState[Self.ro, Self.slo]
        ]()
        var s = Int(task_id)
        ref slc = sp[].slices[][s]
        var np = sp[].np
        var shift = sp[].shift
        # Private per-partition buffers, pre-sized to the expected fill.
        var slice_len = slc.hi - slc.lo
        var cap = slice_len // np + 8
        var local = List[List[Int64]](capacity=np)
        for _ in range(np):
            local.append(List[Int64](capacity=cap))
        ref run = sp[].runs[][slc.run]
        for i in range(slc.lo, slc.hi):
            var v = run[i]
            var p = Int(_cd_mix_hash(v) >> UInt64(shift))
            local[p].append(v)
        sp[].matrix[][s] = local^

    def __keep_alive(mut self):
        pass


struct _CDDedupMultiState(KeepAlive):
    """Dedup task `p` unions column `matrix[0..ns][p]` (every scatter task's
    partition-p buffer) into one hash set and writes `counts[p]`. Both are
    owned by the State for the dispatch."""

    var matrix: OwnedPointer[List[List[List[Int64]]]]
    var counts: OwnedPointer[List[Int64]]
    var ns: Int
    var presize: Bool
    var freepar: Bool

    def __init__(
        out self,
        var matrix: List[List[List[Int64]]],
        var counts: List[Int64],
        ns: Int,
        presize: Bool,
        freepar: Bool,
    ):
        self.matrix = OwnedPointer(matrix^)
        self.counts = OwnedPointer(counts^)
        self.ns = ns
        self.presize = presize
        self.freepar = freepar

    def __keep_alive(mut self):
        pass


@fieldwise_init
struct _CDDedupMultiTask(Segment):
    """POD discriminator; `execute` dedups this task's partition column."""

    var _pad: Int32

    def execute[State: KeepAlive](
        mut self, mut state: State, worker_id: Int32, task_id: Int64,
    ) raises:
        # SAFETY: the bitcast restores the exact State type. Task
        # `p == task_id` touches only column `matrix[*][p]` and `counts[p]`,
        # including the `freepar` release (a slot swap, never an append); the
        # outer and inner Lists were fully populated before the dispatch.
        var sp = UnsafePointer(to=state).bitcast[_CDDedupMultiState]()
        var p = Int(task_id)
        var ns = sp[].ns
        var freepar = sp[].freepar
        var n_vals = 0
        if sp[].presize:
            for s in range(ns):
                n_vals += len(sp[].matrix[][s][p])
        var acc = GrowableHashSetI64.with_expected(n_vals)
        for s in range(ns):
            ref buf = sp[].matrix[][s][p]
            for i in range(len(buf)):
                _ = acc.insert(buf[i])
            # Release the consumed buffer here, on this worker, instead of
            # leaving all `ns * np` of them to the driver after the barrier.
            if freepar:
                var dead = List[Int64]()
                swap(sp[].matrix[][s][p], dead)
                _ = dead^
        sp[].counts[][p] = Int64(acc.size())

    def __keep_alive(mut self):
        pass


# =============================================================================
# The drivers.
# =============================================================================


def radix_distinct_count(
    var vals: List[Int64],
    mut dispatcher: LocalDispatcher[NoopSink],
    var cancel_token: CancellationToken,
    options: CdRadixOptions = CdRadixOptions(),
) raises -> Int64:
    """Exact COUNT(DISTINCT) of the Int64 `vals` buffer, radix-parallel: the
    one-run case of `radix_distinct_count_multi`. Consumes `vals`."""
    var runs = List[List[Int64]]()
    runs.append(vals^)
    return radix_distinct_count_multi(
        runs^, dispatcher, cancel_token^, options
    )


def _scatter_serial(
    imm runs: List[List[Int64]], n: Int, nw: Int, divfree: Bool
) -> List[List[Int64]]:
    """The serial-scatter arm's partitioning into `nw` value-hash buckets."""
    var parts = List[List[Int64]]()
    var per = n // nw + 16
    for _ in range(nw):
        parts.append(List[Int64](capacity=per))
    # The two maps are separate loops so neither loop body branches per value.
    if divfree:
        for r in range(len(runs)):
            for i in range(len(runs[r])):
                var v = runs[r][i]
                parts[_cd_partition_divfree(v, nw)].append(v)
    else:
        for r in range(len(runs)):
            for i in range(len(runs[r])):
                var v = runs[r][i]
                parts[Int(_cd_mix_hash(v) % UInt64(nw))].append(v)
    return parts^


def radix_distinct_count_multi(
    var runs: List[List[Int64]],
    mut dispatcher: LocalDispatcher[NoopSink],
    var cancel_token: CancellationToken,
    options: CdRadixOptions = CdRadixOptions(),
) raises -> Int64:
    """Exact COUNT(DISTINCT) over the UNION of several Int64 buffers (`runs`),
    radix-parallel. Every value of every run is placed into a value-hash
    partition, so a value present in two runs lands in the same partition and
    is counted once; the per-partition counts are disjoint and sum to the
    exact distinct count of the concatenation. Consumes `runs`."""
    var n = 0
    for r in range(len(runs)):
        n += len(runs[r])
    if n == 0:
        _ = cancel_token^
        _ = runs^
        return Int64(0)

    var nw = dispatcher.worker_count()
    if nw < 1:
        nw = 1
    if n < _CD_RADIX_MIN_ROWS or nw == 1:
        var c = _cd_dedup_count_serial_multi(runs, options.presize)
        _ = cancel_token^
        _ = runs^
        return c

    if n < options.scatter_min:
        # -- Serial scatter into P == nw buckets, parallel dedup. --
        var parts = _scatter_serial(runs, n, nw, options.divfree)
        _ = runs^
        var counts = List[Int64](length=nw, fill=Int64(0))
        # PARALLELIZE-BOUNDARY (per-partition dedup).
        # Disjointness: task `p` reads (and with `freepar` releases) `parts[p]`
        #   and writes `counts[p]`, one partition index per task.
        # Liveness: the State owns `parts` and `counts` across the barrier.
        # No-realloc: both outer Lists are sized to `nw` before the dispatch
        #   and only element-assigned (a slot swap).
        var st = _CDDedupState(
            parts^, counts^, options.presize, options.freepar
        )
        var task = _CDDedupTask(_pad=Int32(0))
        var _back = dispatcher.run_with_state[_CDDedupState, _CDDedupTask](
            st, task^, nw, cancel_token^, site_id=SITE_CD_RADIX,
        )
        _ = _back^
        var total = Int64(0)
        for p in range(nw):
            total += st.counts[][p]
        _ = st^
        return total

    # -- Cache-sized partitions P (L2-resident dedup tables) + parallel
    # scatter. --
    var np = _cd_partition_count(n, nw)
    var k = 0
    var tmp = np
    while tmp > 1:
        k += 1
        tmp >>= 1
    var shift = 64 - k  # the top k bits of the 64-bit mix hash select the partition

    # ~nw balanced scatter slices, each a contiguous [lo, hi) within one run (a
    # run larger than `chunk` splits into several slices; run boundaries are
    # never crossed).
    var chunk = (n + nw - 1) // nw
    if chunk < 1:
        chunk = 1
    var slices = List[_CdSlice]()
    for r in range(len(runs)):
        var rn = len(runs[r])
        var off = 0
        while off < rn:
            var hi = off + chunk
            if hi > rn:
                hi = rn
            slices.append(_CdSlice(r, off, hi))
            off = hi
    var ns = len(slices)

    var matrix = List[List[List[Int64]]]()
    for _ in range(ns):
        matrix.append(List[List[Int64]]())

    # PARALLELIZE-BOUNDARY (phase 1: value-hash scatter).
    # Disjointness: scatter task `s` writes ONLY `matrix[s]`; it reads `runs`
    #   and `slices` (read-only borrows).
    # Liveness: `runs` and `slices` are driver locals that outlive the
    #   barrier; the State owns `matrix`.
    # No-realloc: `matrix` is sized to `ns` before the dispatch (each task's
    #   write is a slot move); each task's buffers are pre-sized.
    comptime ScatT = _CDScatterState[origin_of(runs), origin_of(slices)]
    comptime ScatTaskT = _CDScatterTask[origin_of(runs), origin_of(slices)]
    var sstate = ScatT(runs, slices, matrix^, np, shift)
    var stask = ScatTaskT(_pad=Int32(0))
    var _sb = dispatcher.run_with_state[ScatT, ScatTaskT](
        sstate, stask^, ns, cancel_token.clone(), site_id=SITE_CD_RADIX,
    )
    _ = _sb^
    var scattered = List[List[List[Int64]]]()
    swap(sstate.matrix[], scattered)
    _ = sstate^
    _ = runs^

    # PARALLELIZE-BOUNDARY (phase 2: per-partition dedup).
    # Disjointness: dedup task `p` touches column `matrix[*][p]` and ONLY
    #   `counts[p]`. Value partitions are disjoint by hash, so the
    #   per-partition sets never overlap.
    # Liveness: the State owns `matrix` and `counts` across the barrier.
    # No-realloc: `matrix`'s outer and inner Lists are fully populated before
    #   the dispatch and only element-assigned (a slot swap at index `p`);
    #   `counts` is sized to `np`.
    var counts = List[Int64](length=np, fill=Int64(0))
    var dstate = _CDDedupMultiState(
        scattered^, counts^, ns, options.presize, options.freepar
    )
    var dtask = _CDDedupMultiTask(_pad=Int32(0))
    var _db = dispatcher.run_with_state[_CDDedupMultiState, _CDDedupMultiTask](
        dstate, dtask^, np, cancel_token^, site_id=SITE_CD_RADIX,
    )
    _ = _db^

    var total = Int64(0)
    for p in range(np):
        total += dstate.counts[][p]
    _ = dstate^
    return total
