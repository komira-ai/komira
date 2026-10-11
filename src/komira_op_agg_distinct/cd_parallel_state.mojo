# =============================================================================
# cd_parallel_state -- the worker side of the grouped COUNT(DISTINCT) driver:
# the partition function, the per-worker state, the dispatch state and the
# task that runs the OWNER and AGG passes
# =============================================================================
#
# The driver (`agg_count_distinct_parallel`) hands EVERY worker the whole row
# range; a row belongs to the worker its composite group-key hash buckets to.
#
# THE GLOBAL-CORRECTNESS INVARIANT the design rests on:
#   `_cd_partition_bucket` is a pure function of (group key hash, K)
#   => every row of a group is claimed by exactly one worker
#   => a group never spans workers
#   => one distinct-pair set per WORKER is globally correct, and the merge is
#      a concatenation with no lookup.
# Under a row-range split every line is false: a group would be emitted once
# per worker, each copy with a partial distinct count.
#
# The one deliberate exception is a HEAVY group (a sampled share above 1/(4K),
# `agg_cd_heavy_split`), admitted only when every aggregate is
# COUNT(DISTINCT): its (row, aggregate) is owned by
# `cd_pair_bucket(hash, value, K)`, a pure function of the distinct PAIR, so
# the per-worker pair sets stay disjoint, partial counts add, and the driver
# folds a heavy group's partials by FULL key.
#
# Two passes over one state (`_CDParallelState`):
#   * OWNER: task t decides, once per row of its contiguous 1/K of the rows,
#     which worker owns the row, and writes it as one byte;
#   * AGG: every worker reads one byte per row and keys, hashes and
#     aggregates only the rows it owns.
#
# Group keys: an INT32 / INT64 column, or a string key already encoded to
# dense first-seen dict ids by the driver. When any key column has a validity
# bitmap, a NULL key reads as 0 and the row's NULL MASK (bit k set when key k
# is NULL) is one more component of the key and of its hash, so every NULL of
# a key is one group, apart from a real 0 / '' / first-seen string.
#
# Aggregates: COUNT(DISTINCT) admits (aggregate, group, value) into the
# worker's `CdDistinctSet` and counts the admits; a NULL value admits nothing.
# SUM / COUNT / MIN / MAX / AVG fold into a `FixedAggCell` per (aggregate,
# group): NULL values are skipped (COUNT(*) counts every row), integer inputs
# accumulate as Int64, MIN / MAX seed from the first value and compare floats
# in DuckDB's order (NaN above +inf).
# =============================================================================

from std.memory import alloc, OwnedPointer, UnsafePointer
from std.time import perf_counter_ns

from komira_agg_api.agg_column_ptrs import (
    TypedColumnPtrs,
    ValidityLanes,
    AGG_KIND_COUNT,
    AGG_KIND_I32,
    AGG_KIND_I64,
)
from komira_async_api.worker_pool_traits import KeepAlive, Segment
from komira_atomic_alias import AtomicI8
from komira_collections.slab import Slab
from komira_plan_expr.agg_expr import AGG_COUNT, AGG_MAX, AGG_MIN
from komira_udf.float_quotient_order import (
    float_quotient_gt_f64,
    float_quotient_lt_f64,
)

from komira_op_agg_distinct.agg_cd_distinct_set import (
    CdDistinctSet,
    _cd_distinct_value_at,
    cd_pair_tag,
)
from komira_op_agg_distinct.agg_cd_dictkey_encode import _owned_i8
from komira_op_agg_distinct.agg_cd_heavy_split import CD_HEAVY_MAX, cd_pair_bucket
from komira_op_agg_distinct.streaming_agg_count_distinct import FixedAggCell


comptime _PARALLEL_CD_MIN_ROWS_PER_WORKER: Int = 16_384
"""Rows per worker below which the dispatch and merge cost more than the split
saves."""

comptime _PARALLEL_CD_MIN_ROWS: Int = 65_536
"""Rows below which the parallel driver is not worth starting."""

comptime _PARALLEL_CD_MAX_K: Int = 32
"""Cap on the dispatch width; also bounds every owner byte below 255."""

comptime _CDP_OWNER_EVERY: Int = 255
"""The owner byte of a heavy group's row under several aggregates: each
aggregate has its own pair owner, so every worker examines the row."""

comptime _CDP_PASS_OWNER: Int = 0
comptime _CDP_PASS_AGG: Int = 1


# =============================================================================
# The partition function
# =============================================================================


@always_inline
def _cd_partition_mix(group_key_hash: Int) -> Int:
    """The secondary mix: a Fibonacci multiply xor-folded with `hash >> 17`
    (an arithmetic shift). The group table's slot is the hash's LOW bits, so
    bucketing on them directly would correlate partition and slot."""
    return (group_key_hash * 0x9E3779B97F4A7C15) ^ (group_key_hash >> 17)


@always_inline
def _cd_partition_bucket(group_key_hash: Int, num_workers: Int) -> Int:
    """The worker that owns the rows carrying `group_key_hash`, in
    `[0, num_workers)`.

    A pure function of its two arguments (no row index, no worker id, no
    state): that is the invariant in the module header. The range reduction is
    Lemire's multiply-shift over the mix's HIGH 32 bits, read unsigned (a
    signed `>>` would go negative for half of all mixes); it is a multiply,
    not a 64-bit division every worker would pay for every row. The product
    cannot overflow: `p >> 32 < 2^32` and `num_workers <= _PARALLEL_CD_MAX_K`.
    """
    var p = UInt(_cd_partition_mix(group_key_hash))
    return Int(((p >> 32) * UInt(num_workers)) >> 32)


# =============================================================================
# Per-worker state
# =============================================================================


struct _PerWorkerCDState(Movable):
    """One worker's partial result: its own open-addressed group table, the
    per-group key values, its distinct-pair set and counts, and its fixed
    aggregate cells. Worker `wid` is the only writer.

    The driver records the table's first capacity (`init`); the worker
    allocates it on entry (`ensure_ht`) and doubles it at load 0.5
    (`grow_ht`), so the first touch of every page is parallel."""

    var ht_keys: List[Int64]
    """Composite hash per slot."""
    var ht_gids: List[Int32]
    """Group id per slot; -1 is empty."""
    var ht_cap: Int
    var ht_mask: Int
    var ht_cap_hint: Int
    var ht_slots_alloc: Int
    """Every slot this worker allocated (first table and each doubling)."""
    var ht_resizes: Int
    var num_groups: Int
    var wk_rows: Int
    """Rows this worker owned in the AGG pass."""
    var wk_ns: Int
    var wk_scanned: Int
    """Rows whose keys this worker read and hashed in the AGG pass."""
    var group_key_arrays: List[List[Int]]
    """`[k][gid]`: key k's value (a string key's dict id; 0 for NULL)."""
    var group_null_masks: List[Int]
    """`[gid]`: the group's NULL mask; filled only when a key is nullable."""
    var cd_counts: List[List[Int]]
    """`[a][gid]`: distinct values admitted for COUNT(DISTINCT) `a`."""
    var cd_pairs: CdDistinctSet
    var fx: List[List[FixedAggCell]]
    """`[a][gid]`: the cell of fixed aggregate `a`."""

    def __init__(out self):
        self.ht_keys = List[Int64]()
        self.ht_gids = List[Int32]()
        self.ht_cap = 0
        self.ht_mask = 0
        self.ht_cap_hint = 0
        self.ht_slots_alloc = 0
        self.ht_resizes = 0
        self.num_groups = 0
        self.wk_rows = 0
        self.wk_ns = 0
        self.wk_scanned = 0
        self.group_key_arrays = List[List[Int]]()
        self.group_null_masks = List[Int]()
        self.cd_counts = List[List[Int]]()
        self.cd_pairs = CdDistinctSet()
        self.fx = List[List[FixedAggCell]]()

    def init(
        mut self,
        num_keys: Int,
        num_aggs: Int,
        ht_cap_hint: Int,
        cd_rows_hint: Int = 0,
    ):
        """Size the per-key and per-aggregate lists and RECORD the first
        capacities; allocates no table (the worker does).

        Args:
            num_keys: Group-by keys.
            num_aggs: Aggregates.
            ht_cap_hint: First group-table capacity (a power of two), from
                `cd_group_ht_initial_cap`.
            cd_rows_hint: Rows this worker may see; records the pair set's
                first capacity only.
        """
        self.ht_cap_hint = ht_cap_hint
        for _ in range(num_keys):
            self.group_key_arrays.append(List[Int]())
        self.cd_pairs.reserve_hint(cd_rows_hint)
        for _ in range(num_aggs):
            self.cd_counts.append(List[Int]())
            self.fx.append(List[FixedAggCell]())

    def ensure_ht(mut self):
        """Allocate the group table at `ht_cap_hint`, inside the worker."""
        if self.ht_cap != 0:
            return
        var cap = self.ht_cap_hint
        self.ht_keys = List[Int64](length=cap, fill=Int64(0))
        self.ht_gids = List[Int32](length=cap, fill=Int32(-1))
        self.ht_cap = cap
        self.ht_mask = cap - 1
        self.ht_slots_alloc += cap

    def grow_ht(mut self):
        """Double the group table and re-insert every occupied slot. Group ids
        do not change (only slots move), and no row changes owner: the
        partition reads no capacity."""
        var new_cap = self.ht_cap * 2
        var new_mask = new_cap - 1
        var new_keys = List[Int64](length=new_cap, fill=Int64(0))
        var new_gids = List[Int32](length=new_cap, fill=Int32(-1))
        for old_slot in range(self.ht_cap):
            var g = self.ht_gids[old_slot]
            if Int(g) != -1:
                var oh = self.ht_keys[old_slot]
                var ns = Int(oh) & new_mask
                while Int(new_gids[ns]) != -1:
                    ns = (ns + 1) & new_mask
                new_keys[ns] = oh
                new_gids[ns] = g
        self.ht_keys = new_keys^
        self.ht_gids = new_gids^
        self.ht_cap = new_cap
        self.ht_mask = new_mask
        self.ht_slots_alloc += new_cap
        self.ht_resizes += 1


# =============================================================================
# Dispatch state
# =============================================================================


def _owned[T: Movable](var v: T) -> OwnedPointer[T]:
    """`v` moved behind an `OwnedPointer`, so its address is stable while the
    dispatch state that holds it is passed around."""
    var raw = alloc[T](1)
    raw.unsafe_write(v^)
    return OwnedPointer[T](unsafe_from_raw_pointer=raw)


struct _CDParallelState[batch_origin: ImmOrigin](KeepAlive):
    """Per-dispatch state of the driver.

    Disjointness: in the AGG pass worker `wid` writes only
    `worker_states[wid]`; in the OWNER pass task `t` writes only its own
    contiguous range of `owner`. Every other field is read-only during a
    dispatch.

    Liveness: the state lives on the driver's stack across both
    `run_with_state` calls, whose fork-join barrier returns only after every
    task; the key and value pointers borrow the batch (`batch_origin`), which
    the driver borrows for its whole body.

    No realloc: `worker_states` is pre-sized to K and `owner` to the row
    count before the first dispatch; each worker's own lists grow only under
    that worker.
    """

    var worker_states: OwnedPointer[Slab[_PerWorkerCDState]]
    var num_rows: Int
    var key_str_encoded: OwnedPointer[List[List[Int]]]
    var key_is_string: OwnedPointer[List[Bool]]
    var key_is_i32: OwnedPointer[List[Bool]]
    var key_offsets: OwnedPointer[List[Int]]
    var key_ptrs_i32: OwnedPointer[
        List[UnsafePointer[Scalar[DType.int32], Self.batch_origin]]
    ]
    var key_ptrs_i64: OwnedPointer[
        List[UnsafePointer[Scalar[DType.int64], Self.batch_origin]]
    ]
    var key_valid: OwnedPointer[ValidityLanes[Self.batch_origin]]
    var keys_nullable: Bool
    """True when any key column has a validity bitmap: the NULL mask is then
    part of every key."""
    var val_ptrs: OwnedPointer[TypedColumnPtrs[Self.batch_origin]]
    var is_cd: OwnedPointer[List[Bool]]
    var funcs: OwnedPointer[List[UInt8]]
    var err_flag: OwnedPointer[AtomicI8]
    var err_msg: OwnedPointer[String]
    var heavy_hashes: OwnedPointer[List[Int]]
    """The heavy groups' composite hashes (at most `CD_HEAVY_MAX`), set by the
    driver before the first dispatch."""
    var owner: OwnedPointer[List[UInt8]]
    """One byte per row: the owning worker, or `_CDP_OWNER_EVERY`."""
    var num_keys: Int
    var num_aggs: Int
    var num_workers: Int
    var n_heavy: Int
    var pass_id: Int

    def __init__(
        out self,
        var worker_states: Slab[_PerWorkerCDState],
        num_rows: Int,
        var key_str_encoded: List[List[Int]],
        var key_is_string: List[Bool],
        var key_is_i32: List[Bool],
        var key_offsets: List[Int],
        var key_ptrs_i32: List[UnsafePointer[Scalar[DType.int32], Self.batch_origin]],
        var key_ptrs_i64: List[UnsafePointer[Scalar[DType.int64], Self.batch_origin]],
        var key_valid: ValidityLanes[Self.batch_origin],
        var val_ptrs: TypedColumnPtrs[Self.batch_origin],
        var is_cd: List[Bool],
        var funcs: List[UInt8],
        var owner: List[UInt8],
        num_keys: Int,
        num_aggs: Int,
        num_workers: Int,
    ):
        self.worker_states = _owned(worker_states^)
        self.num_rows = num_rows
        self.key_str_encoded = _owned(key_str_encoded^)
        self.key_is_string = _owned(key_is_string^)
        self.key_is_i32 = _owned(key_is_i32^)
        self.key_offsets = _owned(key_offsets^)
        self.key_ptrs_i32 = _owned(key_ptrs_i32^)
        self.key_ptrs_i64 = _owned(key_ptrs_i64^)
        self.keys_nullable = key_valid.any_nullable()
        self.key_valid = _owned(key_valid^)
        self.val_ptrs = _owned(val_ptrs^)
        self.is_cd = _owned(is_cd^)
        self.funcs = _owned(funcs^)
        self.err_flag = _owned_i8()
        self.err_msg = _owned(String(""))
        self.heavy_hashes = _owned(List[Int]())
        self.owner = _owned(owner^)
        self.num_keys = num_keys
        self.num_aggs = num_aggs
        self.num_workers = num_workers
        self.n_heavy = 0
        self.pass_id = _CDP_PASS_OWNER


@always_inline
def _cd_key_at[o: ImmOrigin](st: _CDParallelState[o], k: Int, row: Int) -> Int:
    """Key `k`'s value at `row`: the dict id of a string key, else the integer
    (read at the column's offset). A NULL key reads 0 under the NULL mask."""
    if st.keys_nullable and st.key_valid[].is_null_at(k, row):
        return 0
    if st.key_is_string[][k]:
        return st.key_str_encoded[][k][row]
    if st.key_is_i32[][k]:
        return Int((st.key_ptrs_i32[][k] + st.key_offsets[][k] + row)[])
    return Int((st.key_ptrs_i64[][k] + st.key_offsets[][k] + row)[])


@always_inline
def _cd_null_mask_at[o: ImmOrigin](st: _CDParallelState[o], row: Int) -> Int:
    """Bit k set when key k is NULL at `row`; 0 when no key is nullable."""
    if not st.keys_nullable:
        return 0
    var m = 0
    for k in range(st.num_keys):
        if st.key_valid[].is_null_at(k, row):
            m |= 1 << k
    return m


@always_inline
def _cd_group_hash_at[o: ImmOrigin](st: _CDParallelState[o], row: Int) -> Int:
    """The composite group hash of `row`: FNV-1a (basis 0x811C9DC5, prime
    0x01000193) over the key values in order, then the NULL mask when a key is
    nullable; 0 with no key. The OWNER pass, the heavy sample and the AGG pass
    all hash here, so a row is owned and grouped under one hash."""
    var num_keys = st.num_keys
    if num_keys == 0:
        return 0
    var h: Int = 0x811C9DC5
    for k in range(num_keys):
        h = (h ^ _cd_key_at(st, k, row)) * 0x01000193
    if st.keys_nullable:
        h = (h ^ _cd_null_mask_at(st, row)) * 0x01000193
    return h


def _cdp_owner_pass[o: ImmOrigin](mut st: _CDParallelState[o], t: Int):
    """The OWNER pass for task `t`: one owner byte per row of
    `[t*N/K, (t+1)*N/K)`.

    The rule:
      * a group that is not heavy: `_cd_partition_bucket(hash, K)`;
      * a heavy group, one aggregate: the group's bucket if the value is NULL
        (the group must still be created somewhere), else
        `cd_pair_bucket(hash, value, K)`;
      * a heavy group, several aggregates: `_CDP_OWNER_EVERY`.

    # SAFETY (PARALLELIZE-BOUNDARY): task `t` writes ONLY bytes
    # [t*N/K, (t+1)*N/K) of `st.owner[]`, which the driver sized to N before
    # the dispatch and never resizes; the K ranges partition [0, N). The
    # pointer is taken from the List after sizing and dies with this call.
    """
    comptime assert CD_HEAVY_MAX == 4, (
        "the heavy-hash test below unrolls exactly four locals;"
        " widen it together with CD_HEAVY_MAX"
    )
    var n = st.num_rows
    var kk = st.num_workers
    var lo = (t * n) // kk
    var hi = ((t + 1) * n) // kk
    var n_heavy = st.n_heavy
    var hv0 = st.heavy_hashes[][0] if n_heavy > 0 else 0
    var hv1 = st.heavy_hashes[][1] if n_heavy > 1 else 0
    var hv2 = st.heavy_hashes[][2] if n_heavy > 2 else 0
    var hv3 = st.heavy_hashes[][3] if n_heavy > 3 else 0
    var single = st.num_aggs == 1
    var optr = st.owner[].unsafe_ptr()
    for row in range(lo, hi):
        var h = _cd_group_hash_at(st, row)
        var owner = _cd_partition_bucket(h, kk)
        if n_heavy > 0 and (
            h == hv0
            or (n_heavy > 1 and h == hv1)
            or (n_heavy > 2 and h == hv2)
            or (n_heavy > 3 and h == hv3)
        ):
            if not single:
                owner = _CDP_OWNER_EVERY
            elif not st.val_ptrs[].is_null_at(0, row):
                owner = cd_pair_bucket(
                    h, _cd_distinct_value_at(st.val_ptrs[], 0, row), kk
                )
        (optr + row)[] = UInt8(owner)


@always_inline
def _fx_fold(
    mut cell: FixedAggCell, func: UInt8, d: UInt8, v: Int64, f: Float64
):
    """Fold one non-NULL input into `cell`: `v` for an INT32 / INT64 lane,
    `f` for a FLOAT64 lane (`d` is the lane kind). COUNT(*) has no value and
    counts the row."""
    cell.n += 1
    if d == AGG_KIND_COUNT or func == AGG_COUNT:
        return
    if d == AGG_KIND_I32 or d == AGG_KIND_I64:
        if func == AGG_MIN:
            if cell.n == 1 or v < cell.i_acc:
                cell.i_acc = v
        elif func == AGG_MAX:
            if cell.n == 1 or v > cell.i_acc:
                cell.i_acc = v
        else:
            cell.i_acc += v
        return
    # MIN / MAX in DuckDB's order: NaN sorts above +inf. A bare `<` / `>` is
    # false against a NaN, so `max{0.1, NaN}` would answer 0.1.
    if func == AGG_MIN:
        if cell.n == 1 or float_quotient_lt_f64(f, cell.f_acc):
            cell.f_acc = f
    elif func == AGG_MAX:
        if cell.n == 1 or float_quotient_gt_f64(f, cell.f_acc):
            cell.f_acc = f
    else:
        cell.f_acc += f


def _cd_agg_rows[o: ImmOrigin](mut st: _CDParallelState[o], wid: Int) raises:
    """The AGG pass for worker `wid`: every row it owns, keyed into its own
    group table and folded into its own aggregates."""
    var num_rows = st.num_rows
    if num_rows <= 0:
        return
    ref ws = st.worker_states[].get_mut_interior(wid)
    var t0 = Int(perf_counter_ns())
    var owned = 0
    var scanned = 0
    ws.ensure_ht()
    var num_keys = st.num_keys
    var num_aggs = st.num_aggs
    var kk = st.num_workers
    var nullable = st.keys_nullable
    ref val_ptrs = st.val_ptrs[]
    ref is_cd = st.is_cd[]
    ref funcs = st.funcs[]
    # SAFETY: read-only here; sized to num_rows by the driver before the
    # OWNER pass, whose fork-join completed before this dispatch began.
    var own_ptr = st.owner[].unsafe_ptr()
    for row in range(num_rows):
        var own_b = Int((own_ptr + row)[])
        if own_b != wid and own_b != _CDP_OWNER_EVERY:
            continue
        scanned += 1
        var h = _cd_group_hash_at(st, row)
        var nmask = _cd_null_mask_at(st, row)
        # A heavy row under several aggregates: bit `a` says whether this
        # worker owns aggregate `a`'s pair. A NULL value is owned by the
        # group's bucket, so an all-NULL heavy group is still created.
        var own_mask = -1
        if own_b == _CDP_OWNER_EVERY:
            own_mask = 0
            for a in range(num_aggs):
                var ow: Int
                if val_ptrs.is_null_at(a, row):
                    ow = _cd_partition_bucket(h, kk)
                else:
                    ow = cd_pair_bucket(h, _cd_distinct_value_at(val_ptrs, a, row), kk)
                if ow == wid:
                    own_mask |= 1 << a
            if own_mask == 0:
                continue
        owned += 1

        var slot = h & ws.ht_mask
        var gid: Int
        var inserted = False
        while True:
            var sg = Int(ws.ht_gids[slot])
            if sg == -1:
                inserted = True
                gid = ws.num_groups
                ws.num_groups += 1
                ws.ht_keys[slot] = Int64(h)
                ws.ht_gids[slot] = Int32(gid)
                for k in range(num_keys):
                    ws.group_key_arrays[k].append(_cd_key_at(st, k, row))
                if nullable:
                    ws.group_null_masks.append(nmask)
                for a in range(num_aggs):
                    ws.cd_counts[a].append(0)
                    ws.fx[a].append(FixedAggCell(Int64(0), Float64(0.0), Int64(0)))
                break
            if Int(ws.ht_keys[slot]) == h:
                var same = not nullable or ws.group_null_masks[sg] == nmask
                var k = 0
                while same and k < num_keys:
                    if ws.group_key_arrays[k][sg] != _cd_key_at(st, k, row):
                        same = False
                    k += 1
                if same:
                    gid = sg
                    break
            slot = (slot + 1) & ws.ht_mask
        if inserted and ws.num_groups * 2 > ws.ht_cap:
            ws.grow_ht()

        for a in range(num_aggs):
            if is_cd[a]:
                if ((own_mask >> a) & 1) == 0:
                    continue
                # A NULL value is not a distinct value. A group whose values
                # are all NULL keeps the 0 it was created with and is still
                # emitted (it has rows).
                if val_ptrs.is_null_at(a, row):
                    continue
                var v = _cd_distinct_value_at(val_ptrs, a, row)
                if ws.cd_pairs.admit(cd_pair_tag(a, gid), Int64(v)):
                    ws.cd_counts[a][gid] = ws.cd_counts[a][gid] + 1
            else:
                if val_ptrs.kind_at(a) != AGG_KIND_COUNT and val_ptrs.is_null_at(a, row):
                    continue
                var d = val_ptrs.kind_at(a)
                var off = val_ptrs.offset_at(a)
                var iv = Int64(0)
                var fv = Float64(0.0)
                if d == AGG_KIND_I32:
                    iv = Int64(Int((val_ptrs._i32_ptr(a) + off + row)[]))
                elif d == AGG_KIND_I64:
                    iv = (val_ptrs._i64_ptr(a) + off + row)[]
                elif d != AGG_KIND_COUNT:
                    fv = Float64((val_ptrs._f64_ptr(a) + off + row)[])
                var fa = funcs[a]
                _fx_fold(ws.fx[a][gid], fa, d, iv, fv)
    ws.wk_rows = owned
    ws.wk_scanned = scanned
    ws.wk_ns = Int(perf_counter_ns()) - t0


@fieldwise_init
struct _CDParallelTask[batch_origin: ImmOrigin](Segment):
    """The `Segment` of both passes; `task_id` is the task / worker index."""

    var _pad: Int32

    def execute[State: KeepAlive](
        mut self,
        mut state: State,
        worker_id: Int32,
        task_id: Int64,
    ) raises:
        # SAFETY (PARALLELIZE-BOUNDARY): the driver binds
        # `run_with_state[_CDParallelState[bo], _CDParallelTask[bo]]`, so the
        # bitcast recovers the concrete state type; disjointness and liveness
        # are the state's docstring.
        var sp = UnsafePointer(to=state).bitcast[
            _CDParallelState[Self.batch_origin]
        ]()
        try:
            if sp[].err_flag[].load() != Int8(0):
                return
            if sp[].pass_id == _CDP_PASS_OWNER:
                _cdp_owner_pass(sp[], Int(task_id))
            else:
                _cd_agg_rows(sp[], Int(task_id))
        except e:
            var expected = Int8(0)
            if sp[].err_flag[].compare_exchange(expected, Int8(1)):
                sp[].err_msg[] = String(e)
