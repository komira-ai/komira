# =============================================================================
# cd_radix_grouped.mojo — COUNT(DISTINCT) of every group of a grouped drain,
# parallel ACROSS groups
# =============================================================================
#
# A grouped typed-stage COUNT(DISTINCT) drain holds one list of value runs per
# group. Calling `radix_distinct_count_multi` once per group parallelizes each
# group WITHIN itself, but the loop over groups runs on one core: thousands of
# small and mid groups deduped serially (measured: ~65% of the wall of a
# 6,506-group query). Each group's dedup is independent, so this driver fans
# the loop across the pool:
#
#   1. A group of at most `_CD_GROUPED_TARGET_CELL_VALUES` values is ONE cell
#      over its own runs (no copy). A bigger group is split into P (a power of
#      two, so each sub-cell holds ~target values) value-hash sub-cells by a
#      PARALLEL counting-sort scatter: equal values hash to the same sub-cell,
#      so the sub-cells' distinct counts are disjoint and sum to the group's.
#   2. ONE parallel dispatch with ONE task per cell (the dispatcher's shared
#      claim cursor balances the cells): task `c` dedups cell `c` into its own
#      hash set.
#   3. Each group's count is the sum of its cells' counts.
#
# The result is the same as the per-group loop: a group's distinct count does
# not depend on how its values are partitioned or which worker counted them.
# With one worker, fewer than `_CD_GROUPED_MIN_GROUPS` groups or fewer than
# `_CD_GROUPED_MIN_TOTAL` values in all, the driver runs the per-group
# `radix_distinct_count_multi` loop instead (few groups are already
# parallelized within themselves).
#
# Pointer rules: as in `cd_radix_parallel` — no pointer in a public signature;
# each dispatch State owns the buffers its tasks write and borrows the ones they
# read through `Pointer`s whose immutable origins the Task type carries.
# =============================================================================

from komira_async.runtime.sched_trace import SITE_CD_RADIX
from std.builtin.swap import swap
from std.collections import List
from std.memory import OwnedPointer, Pointer, UnsafePointer

from komira_async_api.worker_pool_traits import KeepAlive, Segment

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.local_dispatcher import LocalDispatcher

from komira_op_agg_state.growable_hash_set_i64 import GrowableHashSetI64

from komira_op_agg_distinct.cd_radix_parallel import (
    CdRadixOptions,
    _cd_mix_hash,
    radix_distinct_count_multi,
)


# Below this TOTAL value count (over all groups) the across-group fork-join is
# not worth it: the per-group loop runs.
comptime _CD_GROUPED_MIN_TOTAL: Int = 200_000
# Below this GROUP count the across-group dispatch does not pay: the per-group
# loop already parallelizes each big group within itself, so the loop over a
# few groups is short. The win is many small and mid groups.
comptime _CD_GROUPED_MIN_GROUPS: Int = 256
# Target values per dedup CELL, so each cell's hash table is L2-resident (an
# L2 hit per probe, not a DRAM miss). A bigger group is split into
# ceil-pow2(size / target) value-hash sub-cells.
comptime _CD_GROUPED_TARGET_CELL_VALUES: Int = 65536
# Cap on one group's sub-cell count (scatter write-stream / TLB pressure).
comptime _CD_GROUPED_MAX_PARTS: Int = 4096


def _cd_grouped_count_serial(
    imm groups_runs: List[List[List[Int64]]]
) -> List[Int64]:
    """Per-group serial distinct count, one hash set per group (no
    partitioning, no dispatch): the independent reference for
    `radix_distinct_count_grouped`."""
    var out = List[Int64](capacity=len(groups_runs))
    for g in range(len(groups_runs)):
        var s = GrowableHashSetI64()
        ref runs = groups_runs[g]
        for r in range(len(runs)):
            for i in range(len(runs[r])):
                _ = s.insert(runs[r][i])
        out.append(Int64(s.size()))
    return out^


@fieldwise_init
struct _CdGroupSlice(Copyable, Movable):
    """A contiguous [lo, hi) slice of `big_runs[bg][run]` for one scatter task.
    `bg` indexes the big-group list (not the global group id)."""

    var bg: Int
    var run: Int
    var lo: Int
    var hi: Int


@fieldwise_init
struct _CellRange(Copyable, Movable):
    """A [lo, hi) slice of `pool[idx]`, one value source of a dedup cell."""

    var idx: Int
    var lo: Int
    var hi: Int


struct _CDGroupScatterState[
    br_o: Origin[mut=False],
    sl_o: Origin[mut=False],
    pt_o: Origin[mut=False],
    sh_o: Origin[mut=False],
](KeepAlive):
    """Scatter task `s` counting-sorts its slice `slices[s]` (a [lo, hi) range
    of one run of big group `bg`) by value-hash partition (the top
    `log2(parts[bg])` bits of the mix hash, via `shifts[bg]`) into ONE flat
    buffer `flats[s]` with `parts[bg] + 1` partition offsets `offs[s]`: one
    allocation per slice, not one List per partition. Partition p's values are
    `flats[s][offs[s][p] : offs[s][p + 1]]`. The inputs are borrowed read-only;
    `flats` and `offs` are owned by the State for the dispatch."""

    var big_runs: Pointer[List[List[List[Int64]]], Self.br_o]
    var slices: Pointer[List[_CdGroupSlice], Self.sl_o]
    var parts: Pointer[List[Int], Self.pt_o]
    var shifts: Pointer[List[Int], Self.sh_o]
    var flats: OwnedPointer[List[List[Int64]]]
    var offs: OwnedPointer[List[List[Int]]]

    def __init__(
        out self,
        ref [Self.br_o] big_runs: List[List[List[Int64]]],
        ref [Self.sl_o] slices: List[_CdGroupSlice],
        ref [Self.pt_o] parts: List[Int],
        ref [Self.sh_o] shifts: List[Int],
        var flats: List[List[Int64]],
        var offs: List[List[Int]],
    ):
        self.big_runs = Pointer(to=big_runs)
        self.slices = Pointer(to=slices)
        self.parts = Pointer(to=parts)
        self.shifts = Pointer(to=shifts)
        self.flats = OwnedPointer(flats^)
        self.offs = OwnedPointer(offs^)

    def __keep_alive(mut self):
        pass


@fieldwise_init
struct _CDGroupScatterTask[
    br_o: Origin[mut=False],
    sl_o: Origin[mut=False],
    pt_o: Origin[mut=False],
    sh_o: Origin[mut=False],
](Segment):
    """POD discriminator; `execute` counting-sorts this task's input slice."""

    var _pad: Int32

    def execute[State: KeepAlive](
        mut self, mut state: State, worker_id: Int32, task_id: Int64,
    ) raises:
        # SAFETY: the bitcast restores the exact State type (the Task carries
        # the State's four read-only origins). Task `s == task_id` writes ONLY
        # `flats[s]` / `offs[s]`, slots of outer Lists sized before the
        # dispatch; every other field is a read-only shared borrow.
        var sp = UnsafePointer(to=state).bitcast[
            _CDGroupScatterState[Self.br_o, Self.sl_o, Self.pt_o, Self.sh_o]
        ]()
        var s = Int(task_id)
        ref slc = sp[].slices[][s]
        var np = sp[].parts[][slc.bg]
        var shift = sp[].shifts[][slc.bg]
        ref run = sp[].big_runs[][slc.bg][slc.run]
        # Pass 1: count per partition.
        var cnt = List[Int](length=np, fill=0)
        for i in range(slc.lo, slc.hi):
            var p = Int(_cd_mix_hash(run[i]) >> UInt64(shift))
            cnt[p] += 1
        # Prefix sum -> partition offsets (length np + 1).
        var off = List[Int](capacity=np + 1)
        off.append(0)
        var run_acc = 0
        for p in range(np):
            run_acc += cnt[p]
            off.append(run_acc)
        # Pass 2: place each value at its partition's rolling cursor.
        var slice_len = slc.hi - slc.lo
        var flat = List[Int64](length=slice_len, fill=Int64(0))
        var cursor = List[Int](capacity=np)
        for p in range(np):
            cursor.append(off[p])
        for i in range(slc.lo, slc.hi):
            var v = run[i]
            var p = Int(_cd_mix_hash(v) >> UInt64(shift))
            flat[cursor[p]] = v
            cursor[p] += 1
        sp[].flats[][s] = flat^
        sp[].offs[][s] = off^

    def __keep_alive(mut self):
        pass


struct _CDGroupedState[
    po_o: Origin[mut=False],
    ce_o: Origin[mut=False],
](KeepAlive):
    """ONE TASK PER CELL: task `c` dedups cell `c`, whose ranges index the
    shared value `pool`, and writes ONLY `counts[c]`. `pool` and `cells` are
    borrowed read-only; `counts` is owned by the State for the dispatch."""

    var pool: Pointer[List[List[Int64]], Self.po_o]
    var cells: Pointer[List[List[_CellRange]], Self.ce_o]
    var counts: OwnedPointer[List[Int64]]
    var presize: Bool

    def __init__(
        out self,
        ref [Self.po_o] pool: List[List[Int64]],
        ref [Self.ce_o] cells: List[List[_CellRange]],
        var counts: List[Int64],
        presize: Bool,
    ):
        self.pool = Pointer(to=pool)
        self.cells = Pointer(to=cells)
        self.counts = OwnedPointer(counts^)
        self.presize = presize

    def __keep_alive(mut self):
        pass


@fieldwise_init
struct _CDGroupedTask[
    po_o: Origin[mut=False],
    ce_o: Origin[mut=False],
](Segment):
    """POD discriminator; `execute` dedups the single cell `task_id`."""

    var _pad: Int32

    def execute[State: KeepAlive](
        mut self, mut state: State, worker_id: Int32, task_id: Int64,
    ) raises:
        # SAFETY: the bitcast restores the exact State type (the Task carries
        # the State's two read-only origins). Task `c == task_id` writes ONLY
        # `counts[c]`; `pool` / `cells` are read-only shared borrows.
        var sp = UnsafePointer(to=state).bitcast[
            _CDGroupedState[Self.po_o, Self.ce_o]
        ]()
        var c = Int(task_id)
        ref ranges = sp[].cells[][c]
        var n_vals = 0
        if sp[].presize:
            for r in range(len(ranges)):
                n_vals += ranges[r].hi - ranges[r].lo
        var acc = GrowableHashSetI64.with_expected(n_vals)
        for r in range(len(ranges)):
            ref rg = ranges[r]
            ref buf = sp[].pool[][rg.idx]
            for i in range(rg.lo, rg.hi):
                _ = acc.insert(buf[i])
        sp[].counts[][c] = Int64(acc.size())

    def __keep_alive(mut self):
        pass


def radix_distinct_count_grouped(
    var groups_runs: List[List[List[Int64]]],
    mut dispatcher: LocalDispatcher[NoopSink],
    var cancel_token: CancellationToken,
    options: CdRadixOptions = CdRadixOptions(),
) raises -> List[Int64]:
    """Exact COUNT(DISTINCT) of EACH group's value runs, parallel ACROSS
    groups. Returns one count per group, in the order of `groups_runs`; the
    same counts as a per-group `radix_distinct_count_multi` loop. `options`
    reaches that loop when it runs, and the dedup tables' pre-sizing.
    Consumes `groups_runs`."""
    var ng = len(groups_runs)
    var out = List[Int64](length=ng, fill=Int64(0))
    if ng == 0:
        _ = cancel_token^
        _ = groups_runs^
        return out^

    var nw = dispatcher.worker_count()
    if nw < 1:
        nw = 1

    var sizes = List[Int](capacity=ng)
    var total = 0
    for g in range(ng):
        var sz = 0
        ref runs = groups_runs[g]
        for r in range(len(runs)):
            sz += len(runs[r])
        sizes.append(sz)
        total += sz

    if (
        nw == 1
        or ng < _CD_GROUPED_MIN_GROUPS
        or total < _CD_GROUPED_MIN_TOTAL
    ):
        for g in range(ng):
            var grun = List[List[Int64]]()
            swap(groups_runs[g], grun)
            out[g] = radix_distinct_count_multi(
                grun^, dispatcher, cancel_token.clone(), options
            )
        _ = cancel_token^
        _ = groups_runs^
        return out^

    # ---- Cells over a shared value-buffer POOL. A small group's runs move into
    # the pool and its one cell references them; a big group's runs are
    # scattered (phase 1) and its sub-cells reference the scatter's flat
    # buffers. ----
    comptime target = _CD_GROUPED_TARGET_CELL_VALUES
    var pool = List[List[Int64]]()
    var cells = List[List[_CellRange]]()
    var cell_group = List[Int]()

    var big_runs = List[List[List[Int64]]]()  # per big group: its moved runs
    var big_gid = List[Int]()                 # per big group: global group id
    var big_parts = List[Int]()               # per big group: P (pow2 sub-cells)
    var big_shift = List[Int]()               # per big group: 64 - log2(P)
    var slices = List[_CdGroupSlice]()
    var big_slice_lo = List[Int]()            # per big group: first slice index
    var chunk = (total + nw * 4 - 1) // (nw * 4)  # ~4 slices per worker
    if chunk < 1:
        chunk = 1

    for g in range(ng):
        var grun = List[List[Int64]]()
        swap(groups_runs[g], grun)
        if sizes[g] <= target:
            var cell = List[_CellRange]()
            for r in range(len(grun)):
                var buf = List[Int64]()
                swap(grun[r], buf)
                var n = len(buf)
                if n > 0:
                    var idx = len(pool)
                    pool.append(buf^)
                    cell.append(_CellRange(idx, 0, n))
                else:
                    _ = buf^
            _ = grun^
            cells.append(cell^)
            cell_group.append(g)
        else:
            var p = 1
            var tgt = sizes[g] // target
            while p < tgt:
                p <<= 1
            if p < 2:
                p = 2
            if p > _CD_GROUPED_MAX_PARTS:
                p = _CD_GROUPED_MAX_PARTS
            var k = 0
            var tmp = p
            while tmp > 1:
                k += 1
                tmp >>= 1
            var bg = len(big_runs)
            big_gid.append(g)
            big_parts.append(p)
            big_shift.append(64 - k)  # the top k bits of the mix hash select p
            big_slice_lo.append(len(slices))
            for r in range(len(grun)):
                var rn = len(grun[r])
                var off = 0
                while off < rn:
                    var hi = off + chunk
                    if hi > rn:
                        hi = rn
                    slices.append(_CdGroupSlice(bg, r, off, hi))
                    off = hi
            big_runs.append(grun^)
    _ = groups_runs^
    var nbig = len(big_runs)
    big_slice_lo.append(len(slices))  # sentinel: end of the last big group
    var ns = len(slices)

    # ---- Phase 1: parallel counting-sort scatter of the big groups. ----
    var flats = List[List[Int64]]()
    var offs = List[List[Int]]()
    for _ in range(ns):
        flats.append(List[Int64]())
        offs.append(List[Int]())
    if nbig > 0 and ns > 0:
        # PARALLELIZE-BOUNDARY (phase 1: big-group counting-sort scatter).
        # Disjointness: task s writes ONLY flats[s] / offs[s]; it reads
        #   big_runs / slices / parts / shifts (read-only borrows).
        # Liveness: the borrowed inputs are driver locals that outlive the
        #   barrier; the State owns flats / offs.
        # No-realloc: flats / offs are sized to ns before the dispatch; each
        #   task's flat buffer is sized to its slice.
        comptime ScatT = _CDGroupScatterState[
            origin_of(big_runs), origin_of(slices), origin_of(big_parts),
            origin_of(big_shift),
        ]
        comptime ScatTaskT = _CDGroupScatterTask[
            origin_of(big_runs), origin_of(slices), origin_of(big_parts),
            origin_of(big_shift),
        ]
        var sstate = ScatT(
            big_runs, slices, big_parts, big_shift, flats^, offs^
        )
        var stask = ScatTaskT(_pad=Int32(0))
        var _sb = dispatcher.run_with_state[ScatT, ScatTaskT](
            sstate, stask^, ns, cancel_token.clone(), site_id=SITE_CD_RADIX,
        )
        _ = _sb^
        flats = List[List[Int64]]()
        offs = List[List[Int]]()
        swap(sstate.flats[], flats)
        swap(sstate.offs[], offs)
        _ = sstate^

    # ---- Each flat buffer moves into the pool; a big group's sub-cell p
    # references every one of its slices' [off[p], off[p + 1]) ranges. ----
    var flat_pool_idx = List[Int](capacity=ns)
    for s in range(ns):
        var buf = List[Int64]()
        swap(flats[s], buf)
        var idx = len(pool)
        pool.append(buf^)
        flat_pool_idx.append(idx)
    _ = flats^
    _ = big_runs^

    for bg in range(nbig):
        var lo = big_slice_lo[bg]
        var hi = big_slice_lo[bg + 1]
        var p = big_parts[bg]
        for pp in range(p):
            var cell = List[_CellRange](capacity=hi - lo)
            for s in range(lo, hi):
                var a = offs[s][pp]
                var b = offs[s][pp + 1]
                if b > a:
                    cell.append(_CellRange(flat_pool_idx[s], a, b))
            cells.append(cell^)
            cell_group.append(big_gid[bg])
    _ = offs^

    var n_cells = len(cells)

    # ---- Phase 2: parallel per-cell dedup. ----
    # PARALLELIZE-BOUNDARY (phase 2: across-group cell dedup).
    # Disjointness: task `c` writes ONLY `counts[c]`.
    # Liveness: `pool` and `cells` are driver locals that outlive the barrier;
    #   the State owns `counts`.
    # No-realloc: `pool` / `cells` are read-only here; `counts` is sized to
    #   the cell count.
    # One task per cell: `run_with_state` takes an arbitrary task count and
    # caps its shards at the worker count, so the surplus task ids are claimed
    # off the shared cursor.
    comptime StateT = _CDGroupedState[origin_of(pool), origin_of(cells)]
    comptime TaskT = _CDGroupedTask[origin_of(pool), origin_of(cells)]
    var st = StateT(
        pool, cells, List[Int64](length=n_cells, fill=Int64(0)),
        options.presize,
    )
    var task = TaskT(_pad=Int32(0))
    var _back = dispatcher.run_with_state[StateT, TaskT](
        st, task^, n_cells, cancel_token^, site_id=SITE_CD_RADIX,
    )
    _ = _back^

    # A big group's sub-cells are disjoint by value hash, so their counts sum
    # to the group's; a small group has exactly one cell.
    for c in range(n_cells):
        out[cell_group[c]] += st.counts[][c]
    _ = st^
    return out^
