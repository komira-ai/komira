# =============================================================================
# ⭐ CDPPARB — PHASE B OF THE STRING-KEY ENCODE ON P SHARDS, NUMBERING PRESERVED
# =============================================================================
#
# Companion to `agg_count_distinct_strenc.mojo` (Phase A, the serial Phase B,
# routing and the public entry point). This module is the PARALLEL Phase B.
#
# Phase B turns 13,172,392 rows of `search_phrase` into 6,019,102 dict ids on
# cbq13. An id is minted "when a byte value is FIRST SEEN", and first-seen is a
# sequential notion — which is why this phase stayed serial until CDPPARB.
#
# ⛔ THE OBVIOUS PARALLELISATION IS THE ONE THAT CHANGES THE ANSWER'S SHAPE.
# Sharding by hash and letting each shard number its own values from zero, then
# offsetting by a prefix sum, is four lines and is WRONG for this engine: the
# ids feed a hash table whose ITERATION ORDER is the output group order, so a
# different numbering emits the same groups in a different ROW ORDER. The
# numbering is preserved instead.
#
# HOW, in one line: each shard mints its ids IN ROW ORDER, so each shard's list
# of first-appearance rows comes out ALREADY SORTED, and the global first-seen
# order is a P-way MERGE of P sorted lists.
#
#   1. PARTITION on the hash's HIGH bits (the intra-shard probe uses the LOW
#      bits, so the two uses do not correlate). Shard `p` scans every row and
#      processes only its own.
#   2. Each shard builds its OWN open-addressed table, writes a LOCAL id into
#      `encoded[row]` (disjoint rows), and appends the minting row index to
#      `first_row` (ascending by construction). The per-shard table is
#      `num_rows/P` slots, not `num_rows` — 6.3 MB instead of 201 MB on cbq13,
#      so part of CDPPARB's win was LOCALITY, not cores.
#   3. MERGE the P ascending `first_row` lists into the global first-seen order.
#   4. PARALLEL remap of `encoded[row]` from local id to global id.
#
# =============================================================================
# ⭐ L2 (2026-09-24, cbq13) — STEP 3 RUNS ON W TASKS, AND THE ORDER IS UNCHANGED
# =============================================================================
#
# Step 3 was a single-threaded P-way merge over every distinct value: measured
# **335.5 ms** of cbq13's wall (30 warm reps, K=20) — the largest serial item
# left in the encode.
#
# It is split by RANK, merge-path style. The first-appearance rows of all P
# lists are DISTINCT row indices (every row belongs to exactly one shard), so
# the number of them below a row bound R, `count_below(R)`, climbs from 0 to
# `total` in steps of 0 or 1 as R climbs. For each task boundary
# `target_w = total * w / W` the driver binary-searches the smallest R_w with
# `count_below(R_w) >= target_w` — and the unit step makes that count EXACTLY
# `target_w`. Task w then owns rows [R_w, R_{w+1}): in each shard p the slice
# `[lower_bound(first_row[p], R_w), lower_bound(first_row[p], R_{w+1}))`, and
# the global ids `[target_w, target_{w+1})`. It merges only its slices and
# numbers from `target_w`.
#
# WHY IT IS THE SAME NUMBERING, not merely the same set: global id g is by
# definition the number of first-appearance rows (over all shards) that lie
# below g's own first-appearance row. Every row below R_w is counted by the
# `target_w` ids of the earlier tasks, and inside [R_w, R_{w+1}) task w's merge
# emits its rows in ascending order — the same order the serial merge visits
# them. `test_cd_parb_parallel_merge_and_source_keys.mojo` pins it against the
# serial Phase B on a fixture whose first appearances interleave the shards,
# at W in {1, 2, 3, 7} (an uneven W catches an off-by-one at a split).
#
# The split costs W x log2(N) x P binary searches of a shard list — ~10^5
# steps on cbq13, under a millisecond, serial.
#
# =============================================================================
# ⭐ L3 (2026-09-24, cbq13) — NO ARENA: A DICT ID'S BYTES ARE THE SOURCE'S
# =============================================================================
#
# Each shard used to copy every value it minted into its own byte arena (for
# verify-on-hit), and the driver then concatenated the P arenas into one
# 392,611,228-byte arena, serially: PARB `arenacat` measured **93.1 ms warm and
# 293.7 ms cold** (first-touch page faults on a fresh 392 MB `resize`) on
# cbq13. That arena exists to answer "what are dict id d's bytes", and the
# source column already answers it: the value was minted AT a row, and that
# row's span in the source value buffer IS the value.
#
# So a shard records `starts[lid] = offs[row]` — an offset into the SOURCE
# buffer `data_ptr` addresses — and verify-on-hit compares the probing row's
# bytes against the minting row's bytes, both in the source. No arena is
# written, none is concatenated, and `out_rev_starts[d]` indexes the caller's
# own value buffer.
#
# ⭐ THE VERIFY CACHE — WHAT THE ARENA WAS STILL GOOD FOR. Measured, deleting
# the arena outright moved cbq13's
# shard pass 527 -> 423 ms but cost cbq10 / cbq11 +3.5 ms of shard time (+1.3%
# / +1.7% wall, cbq11 DISJOINT): 165 / 302 values verified 5.5M times, each
# verify now touching the minting row's page of a ~100 MB source buffer
# instead of a 3 KB arena. So each shard keeps a BOUNDED copy of its EARLIEST
# minted values (`_PARB_VCACHE_BYTES`, L2-sized) purely as a verify-on-hit
# source, and nothing else: the reverse map still points at the source, there
# is still no concat, and past the bound a shard simply stops caching. A
# low-cardinality key lives in the cache entirely; on a high-cardinality one
# the earliest values are also the frequent ones, so the hot verifies stay hot.
# `_parb_vcache_admit` / `_parb_verify` are the one spelling both shard bodies
# (this file's and `agg_cd_strkey_fused.mojo`'s) use.
#
# ⚠ THE CONTRACT CHANGE THIS IS, stated where it is made: after
# `_assign_dict_ids_parallel` there IS no byte arena. `out_rev_starts[d]` /
# `out_rev_lens[d]` describe dict id d's span INSIDE THE BUFFER `data_ptr`
# POINTS AT, so a reader must read that buffer, and that buffer must outlive
# the reader. `agg_count_distinct_parallel` reads it at KEYOUT through the
# batch it was handed (borrowed for the whole call, `_ = batch` at its end);
# `_encode_string_key_parallel` returns True exactly when this arm ran, so its
# caller knows which buffer to read. The SERIAL Phase B keeps its arena (its
# verify-on-hit reads a compact arena instead of a 201 MB table's worth of
# scattered source, and nothing measured says otherwise), and so does the
# DICTIONARY arm.
#
# ⛔ P IS NOT `worker_count`. P is capped at `_PHASEB_MAX_SHARDS` and is a
# power of two because the shard index is a mask of the hash's high bits.
#
# Safety
# ------
# * `data_ptr` / `offs_ptr` / `hashes_ptr` are concrete-origin pointers into
#   buffers the caller keeps alive across every dispatch (batch-rooted, or the
#   Phase-A state). No wildcard origins; State fields are OwnedPointer-wrapped.
# * Every `run_with_state` site carries the PARALLELIZE-BOUNDARY block.
# =============================================================================

from komira_async.runtime.sched_trace import SITE_CD_STRENC
from komira_counters.keyeq_census import keyeq_record
from komira_atomic_alias import AtomicI8
from std.builtin.swap import swap
from std.memory import alloc, OwnedPointer, UnsafePointer, unsafe_memcpy

from komira_async_api.worker_pool_traits import KeepAlive, Segment

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.local_dispatcher import LocalDispatcher


# =============================================================================
# Open-address table sizing — shared by the serial and the sharded Phase B
# =============================================================================


def _strenc_ht_initial_cap(num_rows: Int) -> Int:
    """Initial power-of-two slot count for a Phase-B dict-id table.

    Sized from the ROW count because the DISTINCT count is exactly what this
    pass is computing and so is not knowable up front. `num_rows` is the tight
    upper bound on it. The clamp bounds the up-front allocation of a
    many-rows/few-values input (12 bytes per slot, so the ceiling is ~201 MB);
    above the clamp the table simply rehashes its way up, which is linear and
    tombstone-free.
    """
    comptime MIN_CAP = 1024
    comptime MAX_INITIAL_CAP = 1 << 24
    if num_rows <= MIN_CAP:
        return MIN_CAP
    var cap = MIN_CAP
    while cap < num_rows and cap < MAX_INITIAL_CAP:
        cap *= 2
    return cap


def _strenc_ht_limit(cap: Int) -> Int:
    """Live-slot ceiling before rehash: 0.75 of capacity, shift-only."""
    return (cap >> 1) + (cap >> 2)


# =============================================================================
# Shard count / selector
# =============================================================================

# Power-of-two shard ceiling.
comptime _PHASEB_MAX_SHARDS: Int = 16

# Below this many rows the SERIAL Phase B wins — the dispatch, the P tables and
# the merge are all fixed costs that a small input cannot amortise.
comptime _PHASEB_MIN_ROWS: Int = 1_048_576

# L2: fewest distinct values one merge task is worth. Below it the task count
# shrinks (to ONE task for a few-thousand-value dictionary — cbq10 has 165), so
# a low-cardinality key pays one dispatch, not W.
comptime _PARB_MERGE_MIN_PER_TASK: Int = 16_384

# L3's verify cache: per shard, the bytes of the EARLIEST minted values, up to
# this many — one Broadwell L2. See the header.
comptime _PARB_VCACHE_BYTES: Int = 262_144

# Task modes for `_PhaseBTask`. One Segment type, three passes, because
# `run_with_state` borrows the State and can therefore be called repeatedly on
# it — which is what lets the driver fill the merge plan and `gid_of` BETWEEN
# dispatches over one set of buffers.
comptime _PHASEB_MODE_SHARD: Int32 = 0
comptime _PHASEB_MODE_REMAP: Int32 = 1
comptime _PHASEB_MODE_MERGE: Int32 = 2


def _phaseb_shard_count(num_rows: Int, worker_count: Int) -> Int:
    """Shard count P for the parallel Phase B: the largest power of two that is
    <= min(worker_count, _PHASEB_MAX_SHARDS). Returns 1 to mean "run the SERIAL
    Phase B" — which is the answer for one worker and for a small input."""
    if worker_count <= 1:
        return 1
    if num_rows < _PHASEB_MIN_ROWS:
        return 1
    var cap = worker_count
    if cap > _PHASEB_MAX_SHARDS:
        cap = _PHASEB_MAX_SHARDS
    var p = 1
    while p * 2 <= cap:
        p = p * 2
    return p


@always_inline
def _phaseb_shard_of(h: Int64, mask: Int) -> Int:
    """Shard index, taken from the hash's HIGH bits.

    The intra-shard probe uses `Int(h) & ht_mask` — the LOW bits — so taking
    the shard from the top of the word keeps the two independent. A shard
    chosen from the low bits would land every value of a shard in the same
    probe region of that shard's table.
    """
    return Int(h >> 48) & mask


# =============================================================================
# L3 — the verify cache (one spelling for both shard bodies)
# =============================================================================


@always_inline
def _parb_vcache_admit[
    data_origin: ImmOrigin
](
    mut vcache: List[UInt8],
    mut vstart: List[Int],
    lid: Int,
    data_ptr: UnsafePointer[UInt8, data_origin],
    start: Int,
    str_len: Int,
):
    """Cache local id `lid`'s bytes for verify-on-hit if the cache still
    covers every id below it and the bytes fit; otherwise stop caching (so
    `vstart` always covers exactly the ids `[0, len(vstart))`)."""
    if len(vstart) != lid:
        return
    var base = len(vcache)
    if base + str_len > _PARB_VCACHE_BYTES:
        return
    if str_len > 0:
        vcache.resize(unsafe_uninit_length=base + str_len)
        # SAFETY: `vcache` was just grown to `base + str_len`, so
        # `[base, base+str_len)` is in bounds and owned by this List; its
        # capacity was reserved up front, so the pointer taken after the resize
        # is the final buffer. `data_ptr` is batch-rooted, read-only, and
        # cannot alias this shard-local List's allocation.
        unsafe_memcpy(
            dest=UnsafePointer(to=vcache[base]),
            src=data_ptr + start,
            count=str_len,
        )
    vstart.append(base)


@always_inline
def _parb_verify[
    data_origin: ImmOrigin
](
    imm vcache: List[UInt8],
    imm vstart: List[Int],
    cand: Int,
    cand_src: Int,
    data_ptr: UnsafePointer[UInt8, data_origin],
    start: Int,
    str_len: Int,
    census_site: Int,
) -> Bool:
    """Do the probing row's bytes (`data_ptr[start : +str_len]`) equal
    candidate `cand`'s? Its cached copy when the verify cache holds it, else
    its minting row's bytes in the source (`cand_src`). Lengths are already
    known equal and non-zero."""
    var i = 0
    var ok = True
    if cand < len(vstart):
        var cs = vstart[cand]
        while i < str_len:
            if (data_ptr + start + i)[] != vcache[cs + i]:
                ok = False
                break
            i += 1
    else:
        while i < str_len:
            if (data_ptr + start + i)[] != (data_ptr + cand_src + i)[]:
                ok = False
                break
            i += 1
    keyeq_record(census_site, str_len, i, ok)
    return ok


# =============================================================================
# L2 — the merge plan (pure; the driver computes it between two dispatches)
# =============================================================================


@always_inline
def _parb_lower_bound(imm lst: List[Int], x: Int) -> Int:
    """First index `i` with `lst[i] >= x` (`len(lst)` if none). `lst` is
    ascending — a shard's first-appearance rows are minted in row order."""
    var a = 0
    var b = len(lst)
    while a < b:
        var mid = (a + b) >> 1
        if lst[mid] < x:
            a = mid + 1
        else:
            b = mid
    return a


def _parb_count_below(imm first_rows: List[List[Int]], r: Int) -> Int:
    """How many first-appearance rows, over every shard, lie below row `r`.
    Because the rows are DISTINCT across shards, this climbs by 0 or 1 when `r`
    climbs by 1 — the property the split below is built on."""
    var c = 0
    for p in range(len(first_rows)):
        c += _parb_lower_bound(first_rows[p], r)
    return c


def _parb_merge_plan(
    imm first_rows: List[List[Int]],
    total: Int,
    num_rows: Int,
    n_tasks: Int,
    mut split_lo: List[Int],
    mut split_g0: List[Int],
) raises:
    """L2 — split the global first-seen order into `n_tasks` contiguous RANK
    ranges and say, for each, where it starts in every shard's list.

    Fills (both are REPLACED):
      * `split_g0[w]` — the first global id task `w` assigns
        (`split_g0[0] == 0`, `split_g0[n_tasks] == total`);
      * `split_lo[w * P + p]` — the first index of shard `p`'s list task `w`
        owns (row `n_tasks` holds each list's length).

    Task `w` owns exactly `split_g0[w+1] - split_g0[w]` entries, summed over
    its P slices — the identity `test_cd_parb_parallel_merge_and_source_keys`
    asserts for every task. The rank targets are `total * w / n_tasks`, so
    the tasks are balanced by VALUES, not by rows: first appearances crowd the
    early rows of a table, and a row-even split would hand task 0 most of them.
    """
    var P = len(first_rows)
    var W = n_tasks
    split_lo = List[Int](length=(W + 1) * P, fill=0)
    split_g0 = List[Int](length=W + 1, fill=0)
    for p in range(P):
        split_lo[W * P + p] = len(first_rows[p])
    split_g0[W] = total
    var r_floor = 0
    for w in range(1, W):
        var target = (total * w) // W
        # The smallest row bound R with count_below(R) >= target. The unit
        # step makes count_below(R) == target there, so `split_g0[w]` below is
        # exactly `target` — asserted, because a wrong count here is a
        # duplicated or skipped global id.
        var a = r_floor
        var b = num_rows
        while a < b:
            var mid = (a + b) >> 1
            if _parb_count_below(first_rows, mid) >= target:
                b = mid
            else:
                a = mid + 1
        r_floor = a
        var c = 0
        for p in range(P):
            var i = _parb_lower_bound(first_rows[p], a)
            split_lo[w * P + p] = i
            c += i
        if c != target:
            raise Error(
                "CDPPARB merge plan: rank split "
                + String(w)
                + " counts "
                + String(c)
                + " first appearances below row "
                + String(a)
                + ", expected "
                + String(target)
                + " -- the shards' first-appearance rows are not distinct"
                " and ascending"
            )
        split_g0[w] = c


def _parb_merge_tasks(total: Int, max_tasks: Int, min_per_task: Int) -> Int:
    """How many merge tasks: at most `max_tasks`, and none with fewer than
    `min_per_task` values (at least one task)."""
    var w = max_tasks
    if w < 1:
        w = 1
    var per = min_per_task
    if per < 1:
        per = 1
    var by_size = total // per
    if by_size < 1:
        by_size = 1
    if w > by_size:
        w = by_size
    return w


# =============================================================================
# Dispatch state + task
# =============================================================================


struct _PhaseBState[
    OffsetType: DType,
    data_origin: ImmOrigin,
    offs_origin: ImmOrigin,
    hash_origin: ImmOrigin,
](KeepAlive):
    """Per-dispatch state for CDPPARB, shared by all three passes.

    Disjointness:
      * MODE_SHARD — task `p` writes `encoded[row]` only for rows whose hash
        selects shard `p` (the shards PARTITION the row space, so no two tasks
        write one row) and only element `p` of each per-shard out-List.
      * MODE_MERGE — task `w` writes `gid_of[p][i]` only for `i` in its own
        slice `[split_lo[w*P+p], split_lo[(w+1)*P+p])` of each shard, and
        `rev_starts[g]` / `rev_lens[g]` only for `g` in
        `[split_g0[w], split_g0[w+1])`. The plan partitions both.
      * MODE_REMAP — task `w` rewrites only `encoded[row_starts[w] ..
        row_starts[w+1])`.

    Liveness: the State lives on the driver stack across every
    `run_with_state` call, whose fork-join barrier returns only after every
    worker has finished. `data_ptr` / `offs_ptr` are batch-rooted;
    `hashes_ptr` points into the Phase-A state, which outlives this call.

    No-realloc: the OUTER per-shard Lists are pre-sized to P and are never
    appended to DURING a dispatch; each INNER List grows only in MODE_SHARD
    and only under its one task. `gid_of`, `rev_starts`, `rev_lens`,
    `split_lo`, `split_g0` and `row_starts` are sized by the DRIVER between
    dispatches and only written in place (never resized) by a worker.
    """

    var sh_starts: OwnedPointer[List[List[Int]]]  # L3: SOURCE offsets
    var sh_lens: OwnedPointer[List[List[Int]]]
    var sh_first_row: OwnedPointer[List[List[Int]]]

    var gid_of: OwnedPointer[List[List[Int]]]
    var row_starts: OwnedPointer[List[Int]]
    var split_lo: OwnedPointer[List[Int]]
    var split_g0: OwnedPointer[List[Int]]
    var rev_starts: OwnedPointer[List[Int]]
    var rev_lens: OwnedPointer[List[Int]]

    var err_flag: OwnedPointer[AtomicI8]
    var err_msg: OwnedPointer[String]

    var data_ptr: UnsafePointer[UInt8, Self.data_origin]
    var offs_ptr: UnsafePointer[Scalar[Self.OffsetType], Self.offs_origin]
    var hashes_ptr: UnsafePointer[Int64, Self.hash_origin]
    var encoded: OwnedPointer[List[Int]]

    var num_rows: Int
    var shard_mask: Int
    var census_site: Int

    def __init__(
        out self,
        p_shards: Int,
        data_ptr: UnsafePointer[UInt8, Self.data_origin],
        offs_ptr: UnsafePointer[Scalar[Self.OffsetType], Self.offs_origin],
        hashes_ptr: UnsafePointer[Int64, Self.hash_origin],
        var encoded: List[Int],
        num_rows: Int,
        census_site: Int,
    ):
        var sh_starts = List[List[Int]](capacity=p_shards)
        var sh_lens = List[List[Int]](capacity=p_shards)
        var sh_first_row = List[List[Int]](capacity=p_shards)
        for _ in range(p_shards):
            sh_starts.append(List[Int]())
            sh_lens.append(List[Int]())
            sh_first_row.append(List[Int]())
        self.sh_starts = _owned_lli(sh_starts^)
        self.sh_lens = _owned_lli(sh_lens^)
        self.sh_first_row = _owned_lli(sh_first_row^)
        self.gid_of = _owned_lli(List[List[Int]]())
        self.row_starts = _owned_li(List[Int]())
        self.split_lo = _owned_li(List[Int]())
        self.split_g0 = _owned_li(List[Int]())
        self.rev_starts = _owned_li(List[Int]())
        self.rev_lens = _owned_li(List[Int]())

        var fraw = alloc[AtomicI8](1)
        fraw.unsafe_bitcast[Scalar[DType.int8]]().unsafe_write(
            Scalar[DType.int8](0)
        )
        self.err_flag = OwnedPointer[AtomicI8](unsafe_from_raw_pointer=fraw)

        var smsg = alloc[String](1)
        smsg.unsafe_write(String(""))
        self.err_msg = OwnedPointer[String](unsafe_from_raw_pointer=smsg)

        self.data_ptr = data_ptr
        self.offs_ptr = offs_ptr
        self.hashes_ptr = hashes_ptr
        self.encoded = _owned_li(encoded^)
        self.num_rows = num_rows
        self.shard_mask = p_shards - 1
        self.census_site = census_site


def _owned_li(var v: List[Int]) -> OwnedPointer[List[Int]]:
    """Heap-stable home for a `List[Int]` State field."""
    var raw = alloc[List[Int]](1)
    raw.unsafe_write(v^)
    return OwnedPointer[List[Int]](unsafe_from_raw_pointer=raw)


def _owned_lli(var v: List[List[Int]]) -> OwnedPointer[List[List[Int]]]:
    """Heap-stable home for a `List[List[Int]]` State field."""
    var raw = alloc[List[List[Int]]](1)
    raw.unsafe_write(v^)
    return OwnedPointer[List[List[Int]]](unsafe_from_raw_pointer=raw)


@fieldwise_init
struct _PhaseBTask[
    OffsetType: DType,
    data_origin: ImmOrigin,
    offs_origin: ImmOrigin,
    hash_origin: ImmOrigin,
](Segment):
    """POD Segment for `_PhaseBState`. `mode` selects the pass."""

    var mode: Int32

    def execute[State: KeepAlive](
        mut self,
        mut state: State,
        worker_id: Int32,
        task_id: Int64,
    ) raises:
        # SAFETY (PARALLELIZE-BOUNDARY):
        #   * Disjointness: MODE_SHARD task `p` owns shard `p` — the rows whose
        #     hash selects `p` (a partition of the row space) and element `p` of
        #     each per-shard List. MODE_MERGE task `w` owns its plan slice of
        #     every shard list and the global ids [split_g0[w], split_g0[w+1]).
        #     MODE_REMAP task `w` owns row range [row_starts[w],
        #     row_starts[w+1]).
        #   * Liveness: State is on the driver stack across the fork-join
        #     barrier. `data_ptr`/`offs_ptr` are batch-rooted; `hashes_ptr`
        #     borrows the Phase-A state.
        #   * No-realloc: the OUTER per-shard Lists are pre-sized to P and are
        #     not appended to during a dispatch, so no inner List ever moves;
        #     every List a MERGE or REMAP task writes was sized by the driver
        #     BEFORE that dispatch and is written in place.
        var sp = UnsafePointer(to=state).bitcast[
            _PhaseBState[
                Self.OffsetType,
                Self.data_origin,
                Self.offs_origin,
                Self.hash_origin,
            ]
        ]()

        try:
            if sp[].err_flag[].load() != Int8(0):
                return
            if self.mode == _PHASEB_MODE_REMAP:
                self._remap(sp[], Int(task_id))
            elif self.mode == _PHASEB_MODE_MERGE:
                self._merge(sp[], Int(task_id))
            else:
                self._shard(sp[], Int(task_id))
        except e:
            var expected = Int8(0)
            if sp[].err_flag[].compare_exchange(expected, Int8(1)):
                sp[].err_msg[] = String(e)
            return

    def _shard(
        mut self,
        mut st: _PhaseBState[
            Self.OffsetType,
            Self.data_origin,
            Self.offs_origin,
            Self.hash_origin,
        ],
        p: Int,
    ) raises:
        """Step 1 — build shard `p`'s local dictionary.

        L3: a minted value is recorded as its SOURCE span (`offs[row]`,
        length), and verify-on-hit compares the probing row against the
        minting row IN THE SOURCE. Nothing is copied.
        """
        var num_rows = st.num_rows
        var shard_mask = st.shard_mask
        var census_site = st.census_site
        var data_ptr = st.data_ptr
        var offs_ptr = st.offs_ptr
        var hashes_ptr = st.hashes_ptr
        ref enc_list = st.encoded[]
        var enc_ptr = enc_list.unsafe_ptr()

        ref starts = st.sh_starts[][p]
        ref lens = st.sh_lens[][p]
        ref first_row = st.sh_first_row[][p]

        # This shard's own open-addressed table. `num_rows / P` is the tight
        # upper bound on the shard's distinct count, and it is what keeps the
        # table CACHE-sized rather than DRAM-sized.
        var ht_cap = _strenc_ht_initial_cap((num_rows // (shard_mask + 1)) + 1)
        var ht_mask = ht_cap - 1
        var ht_hash = List[Int64](length=ht_cap, fill=Int64(0))
        var ht_idx = List[Int32](length=ht_cap, fill=Int32(-1))
        var ht_live = 0
        var ht_limit = _strenc_ht_limit(ht_cap)
        var vcache = List[UInt8](capacity=_PARB_VCACHE_BYTES)
        var vstart = List[Int]()

        for row in range(num_rows):
            var h = (hashes_ptr + row)[]
            if _phaseb_shard_of(h, shard_mask) != p:
                continue
            var start = Int((offs_ptr + row)[])
            var end = Int((offs_ptr + row + 1)[])
            var str_len = end - start
            var slot = Int(h) & ht_mask
            while True:
                var gid = ht_idx[slot]
                if gid < Int32(0):
                    var new_idx = len(starts)
                    starts.append(start)
                    lens.append(str_len)
                    first_row.append(row)
                    _parb_vcache_admit(
                        vcache, vstart, new_idx, data_ptr, start, str_len
                    )
                    ht_hash[slot] = h
                    ht_idx[slot] = Int32(new_idx)
                    ht_live += 1
                    # SAFETY: `row < num_rows == len(encoded)`, and only this
                    # shard's rows are written by this task (disjointness in
                    # the State docstring).
                    (enc_ptr + row)[] = new_idx
                    if ht_live > ht_limit:
                        # Rehash into a table twice the size. Linear probing
                        # has no tombstones, so a straight re-insert of every
                        # live slot rebuilds every probe chain.
                        var new_cap = ht_cap * 2
                        var new_mask = new_cap - 1
                        var nh = List[Int64](length=new_cap, fill=Int64(0))
                        var ni = List[Int32](length=new_cap, fill=Int32(-1))
                        for sx in range(ht_cap):
                            var g2 = ht_idx[sx]
                            if g2 < Int32(0):
                                continue
                            var h2 = ht_hash[sx]
                            var ns = Int(h2) & new_mask
                            while ni[ns] >= Int32(0):
                                ns = (ns + 1) & new_mask
                            nh[ns] = h2
                            ni[ns] = g2
                        ht_hash = nh^
                        ht_idx = ni^
                        ht_cap = new_cap
                        ht_mask = new_mask
                        ht_limit = _strenc_ht_limit(ht_cap)
                    break
                if ht_hash[slot] == h:
                    var cand_idx = Int(gid)
                    # Verify-on-hit against the candidate's cached bytes, or
                    # its MINTING row's bytes in the source (L3).
                    var ok = (lens[cand_idx] == str_len)
                    if ok and str_len > 0:
                        ok = _parb_verify(
                            vcache,
                            vstart,
                            cand_idx,
                            starts[cand_idx],
                            data_ptr,
                            start,
                            str_len,
                            census_site,
                        )
                    if ok:
                        (enc_ptr + row)[] = cand_idx
                        break
                    # Same 64-bit hash, DIFFERENT bytes: not this value's
                    # slot. Keep probing.
                slot = (slot + 1) & ht_mask

    def _merge(
        mut self,
        mut st: _PhaseBState[
            Self.OffsetType,
            Self.data_origin,
            Self.offs_origin,
            Self.hash_origin,
        ],
        w: Int,
    ) raises:
        """Step 3 (L2) — merge this task's slice of every shard's ascending
        first-appearance list, numbering from `split_g0[w]`."""
        ref g0 = st.split_g0[]
        if w + 1 >= len(g0):
            return
        var g_lo = g0[w]
        var g_hi = g0[w + 1]
        if g_lo >= g_hi:
            return
        var P = st.shard_mask + 1
        ref lo = st.split_lo[]
        ref first_r = st.sh_first_row[]
        ref starts_r = st.sh_starts[]
        ref lens_r = st.sh_lens[]
        ref gid_of = st.gid_of[]
        ref rev_starts = st.rev_starts[]
        ref rev_lens = st.rev_lens[]

        # `head_row[p]` is shard p's next unmerged first-appearance row in this
        # task's slice, or a sentinel ABOVE every row index once the slice is
        # exhausted. The P heads sit in one flat List, so the min-scan is
        # L1-resident.
        var exhausted = st.num_rows + 1
        var heads = List[Int](length=P, fill=0)
        var ends = List[Int](length=P, fill=0)
        var head_row = List[Int](length=P, fill=0)
        for p in range(P):
            var a = lo[w * P + p]
            var b = lo[(w + 1) * P + p]
            heads[p] = a
            ends[p] = b
            head_row[p] = first_r[p][a] if a < b else exhausted

        for g in range(g_lo, g_hi):
            var best_p = 0
            var best_row = head_row[0]
            for p in range(1, P):
                var r = head_row[p]
                if r < best_row:
                    best_row = r
                    best_p = p
            var hb = heads[best_p]
            gid_of[best_p][hb] = g
            rev_starts[g] = starts_r[best_p][hb]
            rev_lens[g] = lens_r[best_p][hb]
            hb += 1
            heads[best_p] = hb
            head_row[best_p] = (
                first_r[best_p][hb] if hb < ends[best_p] else exhausted
            )

    def _remap(
        mut self,
        mut st: _PhaseBState[
            Self.OffsetType,
            Self.data_origin,
            Self.offs_origin,
            Self.hash_origin,
        ],
        w: Int,
    ) raises:
        """Step 4 — rewrite this worker's row range from LOCAL to GLOBAL id."""
        ref row_starts = st.row_starts[]
        if w + 1 >= len(row_starts):
            return
        var row_lo = row_starts[w]
        var row_hi = row_starts[w + 1]
        if row_lo >= row_hi:
            return
        var shard_mask = st.shard_mask
        var hashes_ptr = st.hashes_ptr
        ref enc_list = st.encoded[]
        var enc_ptr = enc_list.unsafe_ptr()
        ref gid_of = st.gid_of[]
        for row in range(row_lo, row_hi):
            var p = _phaseb_shard_of((hashes_ptr + row)[], shard_mask)
            (enc_ptr + row)[] = gid_of[p][(enc_ptr + row)[]]


def _assign_dict_ids_parallel[
    OffsetType: DType,
    data_origin: ImmOrigin,
    offs_origin: ImmOrigin,
](
    mut dispatcher: LocalDispatcher[NoopSink],
    imm hashes: List[Int64],
    mut out_encoded: List[Int],
    data_ptr: UnsafePointer[UInt8, data_origin],
    offs_ptr: UnsafePointer[Scalar[OffsetType], offs_origin],
    num_rows: Int,
    census_site: Int,
    p_shards: Int,
    remap_workers: Int,
    mut out_rev_starts: List[Int],
    mut out_rev_lens: List[Int],
    merge_min_per_task: Int = _PARB_MERGE_MIN_PER_TASK,
) raises:
    """CDPPARB — Phase B across `p_shards` shards, numbering PRESERVED.

    `out_encoded` is REPLACED with a fresh `num_rows`-long List (it is swapped
    out of the dispatch State, which owns it for the dispatches).
    `out_rev_starts` / `out_rev_lens` must be empty on entry and are REPLACED.

    ⚠ L3: THERE IS NO ARENA. `out_rev_starts[d]` is an offset into the byte
    buffer `data_ptr` addresses — the source column's own value buffer — so
    dict id `d`'s bytes are `data_ptr[out_rev_starts[d] : + out_rev_lens[d]]`
    and the caller must read them there, while that buffer is alive.

    `merge_min_per_task` exists for the tests: a welded-gate fixture has a few
    thousand values, which the production floor would merge on ONE task, so
    the split itself would go unexercised.

    Emits the SAME `out_encoded` and the same per-id byte VALUES as
    `_assign_dict_ids_from_hashes` over the same input — that equivalence is
    the whole point of the merge. `test_cd_phaseb_parallel_equals_serial.mojo`
    and `test_cd_parb_parallel_merge_and_source_keys.mojo` pin it.
    """

    # The State OWNS `encoded` for the duration of the dispatches and it is
    # swapped back into the caller's buffer at the end. It cannot BORROW the
    # caller's List: a MUTABLE origin parameter would be named by the Task type
    # as well as the State type, and `run_with_state` takes both `mut` — which
    # the compiler correctly rejects as aliasing. The same holds for the two
    # reverse-map Lists the merge fills.
    # UNINITIALISED on purpose: every row belongs to exactly one shard and
    # that shard writes its `encoded[row]` (mint or hit), so the shard pass
    # writes all `num_rows` slots — and its tasks, not this thread, take the
    # first-touch page faults.
    var enc_buf = List[Int]()
    enc_buf.resize(unsafe_uninit_length=num_rows)

    var state = _PhaseBState[
        OffsetType, data_origin, offs_origin, origin_of(hashes)
    ](
        p_shards,
        data_ptr,
        offs_ptr,
        hashes.unsafe_ptr(),
        enc_buf^,
        num_rows,
        census_site,
    )

    # ---- step 1: build each shard's local dictionary, in parallel ----
    var shard_task = _PhaseBTask[
        OffsetType, data_origin, offs_origin, origin_of(hashes)
    ](_PHASEB_MODE_SHARD)
    var back1 = dispatcher.run_with_state[
        _PhaseBState[OffsetType, data_origin, offs_origin, origin_of(hashes)],
        _PhaseBTask[OffsetType, data_origin, offs_origin, origin_of(hashes)],
    ](
        state,
        shard_task^,
        p_shards,
        CancellationToken.never(),
        site_id=SITE_CD_STRENC,
    )
    _ = back1^
    if state.err_flag[].load() != Int8(0):
        raise Error(String(state.err_msg[]))

    # ---- step 2 (L2): the merge PLAN, and every buffer the merge writes,
    # sized here — between dispatches, on the driver ----
    var total = 0
    for p in range(p_shards):
        total += len(state.sh_starts[][p])
    var n_tasks = _parb_merge_tasks(total, remap_workers, merge_min_per_task)
    var split_lo = List[Int]()
    var split_g0 = List[Int]()
    _parb_merge_plan(
        state.sh_first_row[], total, num_rows, n_tasks, split_lo, split_g0
    )
    # UNINITIALISED on purpose (measured: a zero-fill here was 21-99 ms of
    # serial first-touch on cbq13): the plan's slices PARTITION every shard
    # list and its id ranges tile [0, total), so the merge writes every
    # `gid_of[p][i]` and every `rev_starts[g]` / `rev_lens[g]` exactly once.
    var gid_of = List[List[Int]](capacity=p_shards)
    for p in range(p_shards):
        var go = List[Int]()
        go.resize(unsafe_uninit_length=len(state.sh_starts[][p]))
        gid_of.append(go^)
    state.gid_of[] = gid_of^
    state.split_lo[] = split_lo^
    state.split_g0[] = split_g0^
    state.rev_starts[].resize(unsafe_uninit_length=total)
    state.rev_lens[].resize(unsafe_uninit_length=total)

    # ---- step 3 (L2): merge on `n_tasks` tasks, numbering preserved ----
    var merge_task = _PhaseBTask[
        OffsetType, data_origin, offs_origin, origin_of(hashes)
    ](_PHASEB_MODE_MERGE)
    var back2 = dispatcher.run_with_state[
        _PhaseBState[OffsetType, data_origin, offs_origin, origin_of(hashes)],
        _PhaseBTask[OffsetType, data_origin, offs_origin, origin_of(hashes)],
    ](
        state,
        merge_task^,
        n_tasks,
        CancellationToken.never(),
        site_id=SITE_CD_STRENC,
    )
    _ = back2^
    if state.err_flag[].load() != Int8(0):
        raise Error(String(state.err_msg[]))

    # ---- step 4: local id -> global id, in parallel ----
    var rw = remap_workers
    if rw < 1:
        rw = 1
    var row_starts = List[Int](capacity=rw + 1)
    row_starts.append(0)
    for w in range(1, rw):
        row_starts.append((num_rows * w) // rw)
    row_starts.append(num_rows)
    state.row_starts[] = row_starts^

    var remap_task = _PhaseBTask[
        OffsetType, data_origin, offs_origin, origin_of(hashes)
    ](_PHASEB_MODE_REMAP)
    var back3 = dispatcher.run_with_state[
        _PhaseBState[OffsetType, data_origin, offs_origin, origin_of(hashes)],
        _PhaseBTask[OffsetType, data_origin, offs_origin, origin_of(hashes)],
    ](
        state,
        remap_task^,
        rw,
        CancellationToken.never(),
        site_id=SITE_CD_STRENC,
    )
    _ = back3^
    if state.err_flag[].load() != Int8(0):
        raise Error(String(state.err_msg[]))

    swap(state.encoded[], out_encoded)
    swap(state.rev_starts[], out_rev_starts)
    swap(state.rev_lens[], out_rev_lens)

    _ = state^
