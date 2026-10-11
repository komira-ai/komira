# =============================================================================
# agg_cd_strkey_fused -- one STRING key, every aggregate COUNT(DISTINCT): the
# sharded dictionary pass IS the group-by
# =============================================================================
#
# Shape served: `SELECT k, count(DISTINCT v1) [, count(DISTINCT v2) ...]
# FROM t GROUP BY k` with exactly one group key, a STRING / LARGE_STRING
# column with no NULL, over enough rows for the sharded Phase B
# (`_phaseb_shard_count > 1`), and no key holding a large share of the rows.
#
# The general driver (`agg_count_distinct_parallel`) would encode the key to
# dense dict ids (the sharded Phase B already sees every row of every key a
# shard owns), then re-key, re-hash and re-group the rows into K per-worker
# tables, then concatenate them. For ONE key the dict id already IS a dense
# group id, so here the pair admits move into the shard pass: shard p owns
# every row of its keys, so its `CdDistinctSet` is globally correct (the
# argument the driver makes for a hash-partitioned worker), each shard keeps a
# distinct count per LOCAL id, and the order-preserving merge that numbers the
# ids in first-seen order carries the counts along. No second pass, no group
# table, no concatenation, no per-row id array.
#
# The invariant: `cd_fused_shard_of` is a pure function of the row's key hash,
# and a key's bytes determine its hash, so every row of a key lands in one
# shard and no other shard sees any of its pairs.
#
# Output order: first-seen order of the key. A GROUP BY without ORDER BY
# promises none; under a top-k hint the group index is this order.
#
# It DECLINES (returns None; the general driver serves the shape) for more
# than one key, a non-STRING key, a key column with a NULL (the general
# driver's NULL group), a non-COUNT(DISTINCT) aggregate, more than 62
# aggregates, one worker or too few rows, and a HEAVY key (a sampled share
# above 2/P): ownership is by key, so one key with most of the rows would put
# all its pair admits on one shard, where the general driver splits that group
# by pair.
#
# Safety: the public entry takes the `RecordBatch` and returns an
# `Optional[RecordBatch]`; no `UnsafePointer` crosses it. Inside, the key
# buffers are cast to `origin_of(batch)` and the batch outlives every
# dispatch. Every `run_with_state` carries the PARALLELIZE-BOUNDARY block.
# =============================================================================

from komira_async.runtime.sched_trace import SITE_CD_STRENC
from komira_counters.keyeq_census import KEYEQ_AGGCD_STRENC
from komira_atomic_alias import AtomicI8, AtomicI64
from std.ffi import _Global
from std.math import min
from std.builtin.swap import swap
from std.memory import alloc, OwnedPointer, UnsafePointer

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import RecordBatch, RecordBatchBuilder, SchemaBuilder
from komira_arrow.varlen_width_guard import offset_width_bytes_or_raise
from komira_collections.slab import Slab
from komira_buffer.heap_region import HeapRegion
from komira_plan_expr.agg_expr import AGG_COUNT_DISTINCT
from komira_physical_plan.physical_plan import AggSinkData
from komira_column_kernels.compiler_helpers import resolve_col_index
from komira_async_api.worker_pool_traits import KeepAlive, Segment
from komira_agg_api.agg_column_ptrs import TypedColumnPtrs
from komira_counters.strdrain_counter import (
    strdrain_note_cdp_builder,
    strdrain_note_cdp_call,
    strdrain_note_owner,
    strdrain_note_site,
)

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.local_dispatcher import LocalDispatcher

from komira_op_agg_distinct.agg_cd_distinct_set import (
    CdDistinctSet,
    _cd_distinct_value_at,
    cd_pair_tag,
)
from komira_op_agg_distinct.agg_cd_group_topk import (
    CdGroupTopKHint,
    cd_group_topk_admits,
    cd_group_topk_gids,
    cd_group_topk_index_field,
    cd_group_topk_select,
)
from komira_op_agg_distinct.agg_cd_heavy_split import cd_heavy_groups
from komira_op_agg_distinct.agg_cd_key_emit import cd_emit_string_key_column
from komira_op_agg_distinct.agg_cd_strenc_parb import (
    _PARB_MERGE_MIN_PER_TASK,
    _PARB_VCACHE_BYTES,
    _parb_merge_plan,
    _parb_merge_tasks,
    _parb_vcache_admit,
    _parb_verify,
    _phaseb_shard_count,
    _strenc_ht_initial_cap,
    _strenc_ht_limit,
)
from komira_op_agg_distinct.agg_cd_strenc_rowdict import _strenc_fnv_row
from komira_op_agg_distinct.agg_count_distinct_strenc import (
    _hash_string_rows_parallel,
)


comptime CD_FUSED_SAMPLE_ROWS: Int = 4_096
"""Rows sampled for the heavy-key test: FNV hashes of evenly strided rows, the
hash Phase A computes, so a heavy key found here is the key that would pin a
shard."""

comptime CD_FUSED_MAX_AGGS: Int = 62
"""Aggregate slots a pair tag can carry; the driver's heavy split uses the
same bound."""

comptime _FUSED_MODE_SHARD: Int32 = 0
comptime _FUSED_MODE_MERGE: Int32 = 1

comptime CD_FUSED_MAX_SHARDS: Int = 32
"""P is the worker count, capped here. The merge is parallel, so a smaller P
would only idle workers."""
def cd_fused_shard_count(worker_count: Int) -> Int:
    """Shards for the fused pass: one per worker, capped."""
    var p = worker_count
    if p > CD_FUSED_MAX_SHARDS:
        p = CD_FUSED_MAX_SHARDS
    if p < 1:
        p = 1
    return p


@always_inline
def cd_fused_shard_of(h: Int64, p_shards: Int) -> Int:
    """Shard of a row whose key hash is `h`: Lemire's multiply-shift over the
    hash's HIGH 32 bits, so any P works (no power-of-two mask) and the result
    is independent of the LOW bits the shard's own table probes with. A pure
    function of the key hash — the fused route's global-correctness argument
    (file header) rests on exactly that."""
    return Int(((UInt64(h) >> 32) * UInt64(p_shards)) >> 32)


# =============================================================================
# Route witness — process-wide: queries SERVED, and shape-admitted queries
# handed back because the sample found a heavy key
# =============================================================================


def _init_fused_counter() -> OwnedPointer[AtomicI64]:
    """`_Global` init_fn for the two counters below."""
    var raw = alloc[AtomicI64](1)
    raw.unsafe_bitcast[Scalar[DType.int64]]().unsafe_write(Scalar[DType.int64](0))
    return OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


comptime _CD_STRKEY_FUSED_SERVED = _Global[
    "komira_cd_strkey_fused_served", _init_fused_counter,
]
comptime _CD_STRKEY_FUSED_HEAVY = _Global[
    "komira_cd_strkey_fused_heavy_declines", _init_fused_counter,
]


def cd_strkey_fused_served_count() raises -> Int:
    """Queries the fused route has served, process-wide."""
    # SAFETY: §6 FFI carve-out — `get_or_create_ptr` targets KGEN-runtime static
    # storage (process-lifetime); the wildcard is the stdlib `_Global` API's own
    # return type, confined to these helpers.
    var g = _CD_STRKEY_FUSED_SERVED.get_or_create_ptr()
    return Int(g[][].load())


def cd_strkey_fused_heavy_decline_count() raises -> Int:
    """Shape-admitted queries handed back for a heavy key, process-wide."""
    # SAFETY: §6 FFI carve-out (see `cd_strkey_fused_served_count`).
    var g = _CD_STRKEY_FUSED_HEAVY.get_or_create_ptr()
    return Int(g[][].load())


def reset_cd_strkey_fused_counters() raises:
    """Reset both counters to 0 (test setup)."""
    # SAFETY: §6 FFI carve-out (see `cd_strkey_fused_served_count`).
    var g = _CD_STRKEY_FUSED_SERVED.get_or_create_ptr()
    g[][].store(Scalar[DType.int64](0))
    var h = _CD_STRKEY_FUSED_HEAVY.get_or_create_ptr()
    h[][].store(Scalar[DType.int64](0))


def _fused_note(counter_heavy: Bool) raises:
    # SAFETY: §6 FFI carve-out (see `cd_strkey_fused_served_count`).
    if counter_heavy:
        var h = _CD_STRKEY_FUSED_HEAVY.get_or_create_ptr()
        _ = h[][].fetch_add(Int64(1))
    else:
        var g = _CD_STRKEY_FUSED_SERVED.get_or_create_ptr()
        _ = g[][].fetch_add(Int64(1))


# =============================================================================
# Admission
# =============================================================================


def cd_strkey_fused_shape_admits(
    num_keys: Int,
    key_type: ArrowType,
    imm agg_data: AggSinkData,
    num_aggs: Int,
    num_rows: Int,
    worker_count: Int,
) -> Bool:
    """The SHAPE half of admission — everything but the heavy-key sample.

    Args:
        num_keys: Group-by key count; must be 1.
        key_type: The key COLUMN's arrow type; STRING or LARGE_STRING.
        agg_data: Every aggregate must be COUNT(DISTINCT).
        num_aggs: 1 .. `CD_FUSED_MAX_AGGS`.
        num_rows: Rows in the batch.
        worker_count: The dispatcher's workers.

    Returns:
        True when the fused route may be tried (the sample may still decline).
    """
    if num_keys != 1:
        return False
    if not (key_type == ArrowType.STRING or key_type == ArrowType.LARGE_STRING):
        return False
    if num_aggs < 1 or num_aggs > CD_FUSED_MAX_AGGS:
        return False
    for a in range(num_aggs):
        if agg_data.agg_exprs[a].func != AGG_COUNT_DISTINCT:
            return False
    return _phaseb_shard_count(num_rows, worker_count) > 1


# =============================================================================
# Per-shard state, dispatch state, task
# =============================================================================


struct _FusedShard(Movable):
    """Shard p's dictionary AND its distinct counts. Written only by task p in
    the shard pass; read (never written) by the merge tasks afterwards."""

    var starts: List[Int]  # SOURCE offset of each local id's minting row
    var lens: List[Int]
    var first_row: List[Int]  # ascending — minted in row order
    var counts: List[List[Int]]  # [agg][local id] distinct count
    var pairs: CdDistinctSet
    var n_pairs: Int  # witness: pairs admitted (the set is freed in-task)
    var rows: Int  # witness: rows this shard owned

    def __init__(out self, num_aggs: Int, rows_hint: Int):
        self.starts = List[Int]()
        self.lens = List[Int]()
        self.first_row = List[Int]()
        self.counts = List[List[Int]]()
        for _ in range(num_aggs):
            self.counts.append(List[Int]())
        self.pairs = CdDistinctSet()
        # Records a first capacity only (capped); the set allocates on its
        # first admit, inside the shard task, and doubles as it fills.
        self.pairs.reserve_hint(rows_hint)
        self.n_pairs = 0
        self.rows = 0


struct _FusedState[
    OffsetType: DType, bo: ImmOrigin, hash_origin: ImmOrigin
](KeepAlive):
    """Per-dispatch state for the fused route; two passes over one State.

    Disjointness:
      * MODE_SHARD — task `p` writes only `shards[p]` (the shards PARTITION
        the rows by key hash).
      * MODE_MERGE — task `w` writes `out_starts[g]`, `out_lens[g]` and
        element `g` of every `out_arrs` buffer only for `g` in
        `[split_g0[w], split_g0[w+1])`, which the plan partitions; it only
        READS the shards.

    Liveness: the State lives on the driver stack across both
    `run_with_state` calls (fork-join). `data_ptr` / `offs_ptr` / `val_ptrs`
    borrow the batch (`bo`), which the caller holds for the whole call;
    `hashes_ptr` borrows the caller's hash List, alive across both passes.

    No-realloc: `shards` is pre-sized to P and never grows; each shard's
    inner Lists grow only under its own task. Every `out_*`, `split_*` and
    `first_rows` List, and every `out_arrs` buffer, is sized by the DRIVER
    between the passes and written in place.
    """

    var shards: OwnedPointer[Slab[_FusedShard]]
    var first_rows: OwnedPointer[List[List[Int]]]
    var split_lo: OwnedPointer[List[Int]]
    var split_g0: OwnedPointer[List[Int]]
    var out_starts: OwnedPointer[List[Int]]
    var out_lens: OwnedPointer[List[Int]]
    # The OUTPUT columns' buffers, written by the merge in place: one INT64
    # distinct count per aggregate, then (only when the top-k arm will select) the
    # `__cdp_topk_gidx` column. Sized by the driver, uninitialised — the
    # merge's id ranges tile [0, total), so every element is written once.
    var out_arrs: OwnedPointer[Slab[PrimitiveArray[DType.int64]]]
    var val_ptrs: OwnedPointer[TypedColumnPtrs[Self.bo]]

    var err_flag: OwnedPointer[AtomicI8]
    var err_msg: OwnedPointer[String]

    var data_ptr: UnsafePointer[UInt8, Self.bo]
    var offs_ptr: UnsafePointer[Scalar[Self.OffsetType], Self.bo]
    var hashes_ptr: UnsafePointer[Int64, Self.hash_origin]

    var num_rows: Int
    var p_shards: Int
    var num_aggs: Int
    var with_index: Bool

    def __init__(
        out self,
        var shards: Slab[_FusedShard],
        var val_ptrs: TypedColumnPtrs[Self.bo],
        data_ptr: UnsafePointer[UInt8, Self.bo],
        offs_ptr: UnsafePointer[Scalar[Self.OffsetType], Self.bo],
        hashes_ptr: UnsafePointer[Int64, Self.hash_origin],
        num_rows: Int,
        p_shards: Int,
        num_aggs: Int,
    ):
        var sraw = alloc[Slab[_FusedShard]](1)
        sraw.unsafe_write(shards^)
        self.shards = OwnedPointer[Slab[_FusedShard]](unsafe_from_raw_pointer=sraw)
        self.first_rows = _owned_lli(List[List[Int]]())
        self.split_lo = _owned_li(List[Int]())
        self.split_g0 = _owned_li(List[Int]())
        self.out_starts = _owned_li(List[Int]())
        self.out_lens = _owned_li(List[Int]())
        var araw = alloc[Slab[PrimitiveArray[DType.int64]]](1)
        araw.unsafe_write(Slab[PrimitiveArray[DType.int64]]())
        self.out_arrs = OwnedPointer[Slab[PrimitiveArray[DType.int64]]](
            unsafe_from_raw_pointer=araw
        )
        var vraw = alloc[TypedColumnPtrs[Self.bo]](1)
        vraw.unsafe_write(val_ptrs^)
        self.val_ptrs = OwnedPointer[TypedColumnPtrs[Self.bo]](
            unsafe_from_raw_pointer=vraw
        )
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
        self.num_rows = num_rows
        self.p_shards = p_shards
        self.num_aggs = num_aggs
        self.with_index = False


def _owned_li(var v: List[Int]) -> OwnedPointer[List[Int]]:
    var raw = alloc[List[Int]](1)
    raw.unsafe_write(v^)
    return OwnedPointer[List[Int]](unsafe_from_raw_pointer=raw)


def _owned_lli(var v: List[List[Int]]) -> OwnedPointer[List[List[Int]]]:
    var raw = alloc[List[List[Int]]](1)
    raw.unsafe_write(v^)
    return OwnedPointer[List[List[Int]]](unsafe_from_raw_pointer=raw)


def _fused_shard[
    OffsetType: DType, bo: ImmOrigin, ho: ImmOrigin
](mut st: _FusedState[OffsetType, bo, ho], p: Int) raises:
    """Shard p: mint local ids for the keys it owns (the sharded Phase B body,
    spans pointing into the source buffer) and admit every owned row's
    (local id, value) pairs into its own distinct set right here."""
    ref sh = st.shards[].get_mut_interior(p)
    var num_rows = st.num_rows
    var p_shards = st.p_shards
    var num_aggs = st.num_aggs
    var data_ptr = st.data_ptr
    var offs_ptr = st.offs_ptr
    var hashes_ptr = st.hashes_ptr
    ref val_ptrs = st.val_ptrs[]

    var ht_cap = _strenc_ht_initial_cap((num_rows // p_shards) + 1)
    var ht_mask = ht_cap - 1
    var ht_hash = List[Int64](length=ht_cap, fill=Int64(0))
    var ht_idx = List[Int32](length=ht_cap, fill=Int32(-1))
    var ht_live = 0
    var ht_limit = _strenc_ht_limit(ht_cap)
    var owned = 0
    # The verify cache of `agg_cd_strenc_parb`: the earliest minted
    # values' bytes, bounded, for verify-on-hit only.
    var vcache = List[UInt8](capacity=_PARB_VCACHE_BYTES)
    var vstart = List[Int]()

    for row in range(num_rows):
        var h = (hashes_ptr + row)[]
        if cd_fused_shard_of(h, p_shards) != p:
            continue
        owned += 1
        var start = Int((offs_ptr + row)[])
        var end = Int((offs_ptr + row + 1)[])
        var str_len = end - start
        var slot = Int(h) & ht_mask
        var lid = 0
        while True:
            var gid = ht_idx[slot]
            if gid < Int32(0):
                lid = len(sh.starts)
                sh.starts.append(start)
                sh.lens.append(str_len)
                sh.first_row.append(row)
                _parb_vcache_admit(vcache, vstart, lid, data_ptr, start, str_len)
                for a in range(num_aggs):
                    sh.counts[a].append(0)
                ht_hash[slot] = h
                ht_idx[slot] = Int32(lid)
                ht_live += 1
                if ht_live > ht_limit:
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
                var cand = Int(gid)
                var ok = (sh.lens[cand] == str_len)
                if ok and str_len > 0:
                    ok = _parb_verify(
                        vcache,
                        vstart,
                        cand,
                        sh.starts[cand],
                        data_ptr,
                        start,
                        str_len,
                        KEYEQ_AGGCD_STRENC,
                    )
                if ok:
                    lid = cand
                    break
            slot = (slot + 1) & ht_mask

        # The driver's pair admits, where the row already is. The NULL
        # skip and the value key are the general driver's own
        # (`_cd_distinct_value_at` is ONE function for both routes), so a
        # value counts identically on either.
        for a in range(num_aggs):
            if val_ptrs.is_null_at(a, row):
                continue
            var v = _cd_distinct_value_at(val_ptrs, a, row)
            if sh.pairs.admit(cd_pair_tag(a, lid), Int64(v)):
                sh.counts[a][lid] = sh.counts[a][lid] + 1

    # The pair set's only product is the counts above: record its size and
    # FREE it here, in parallel, rather than at the driver's serial teardown.
    sh.n_pairs = sh.pairs.count()
    sh.pairs = CdDistinctSet()
    sh.rows = owned


def _fused_merge[
    OffsetType: DType, bo: ImmOrigin, ho: ImmOrigin
](mut st: _FusedState[OffsetType, bo, ho], w: Int) raises:
    """The order-preserving merge of this task's rank range, carrying each
    id's source span AND its distinct counts to its global position."""
    ref g0 = st.split_g0[]
    if w + 1 >= len(g0):
        return
    var g_lo = g0[w]
    var g_hi = g0[w + 1]
    if g_lo >= g_hi:
        return
    var P = st.p_shards
    var num_aggs = st.num_aggs
    var with_index = st.with_index
    ref lo = st.split_lo[]
    ref first_r = st.first_rows[]
    ref shards = st.shards[]
    ref out_starts = st.out_starts[]
    ref out_lens = st.out_lens[]
    ref out_arrs = st.out_arrs[]

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
        ref sh = shards[best_p]
        out_starts[g] = sh.starts[hb]
        out_lens[g] = sh.lens[hb]
        for a in range(num_aggs):
            out_arrs.get_mut_interior(a).store[1](
                g, Scalar[DType.int64](sh.counts[a][hb])
            )
        if with_index:
            out_arrs.get_mut_interior(num_aggs).store[1](
                g, Scalar[DType.int64](g)
            )
        hb += 1
        heads[best_p] = hb
        head_row[best_p] = first_r[best_p][hb] if hb < ends[best_p] else exhausted


@fieldwise_init
struct _FusedTask[OffsetType: DType, bo: ImmOrigin, hash_origin: ImmOrigin](
    Segment
):
    """POD Segment for `_FusedState`. `mode` selects the pass."""

    var mode: Int32

    def execute[State: KeepAlive](
        mut self,
        mut state: State,
        worker_id: Int32,
        task_id: Int64,
    ) raises:
        # SAFETY (PARALLELIZE-BOUNDARY):
        #   * Disjointness: MODE_SHARD task `p` writes only `shards[p]`;
        #     MODE_MERGE task `w` writes only global ids in its plan range and
        #     reads the shards. (State docstring.)
        #   * Liveness: State on the driver stack across the fork-join barrier;
        #     the batch and the hash List outlive both dispatches.
        #   * No-realloc: `shards` pre-sized to P; every List a merge task
        #     writes was sized by the driver before the dispatch.
        var sp = UnsafePointer(to=state).bitcast[
            _FusedState[Self.OffsetType, Self.bo, Self.hash_origin]
        ]()
        try:
            if sp[].err_flag[].load() != Int8(0):
                return
            if self.mode == _FUSED_MODE_MERGE:
                _fused_merge(sp[], Int(task_id))
            else:
                _fused_shard(sp[], Int(task_id))
        except e:
            var expected = Int8(0)
            if sp[].err_flag[].compare_exchange(expected, Int8(1)):
                sp[].err_msg[] = String(e)
            return


# =============================================================================
# Driver
# =============================================================================



# =============================================================================
# Driver
# =============================================================================


def cd_strkey_fused_try(
    mut dispatcher: LocalDispatcher[NoopSink],
    batch: RecordBatch,
    agg_data: AggSinkData,
    num_keys: Int,
    num_aggs: Int,
    num_rows: Int,
    topk_hint: Optional[CdGroupTopKHint],
) raises -> Optional[RecordBatch]:
    """Serve the shape with the fused route, or DECLINE (None) having changed
    nothing, so the caller runs the general driver.

    Args:
        dispatcher: The caller's dispatcher (borrowed for the dispatches).
        batch: The input batch; borrowed for the whole call.
        agg_data: Group key, aggregates, output schema.
        num_keys: Group-by key count.
        num_aggs: Aggregate count.
        num_rows: `batch.num_rows()`.
        topk_hint: The top-N above this aggregate (changes cost only).

    Returns:
        The aggregate's output batch, or None when the route declines.
    """
    if num_keys != 1:
        return None
    var ki = resolve_col_index(agg_data.group_by_exprs[0], batch.schema)
    ref kcol = batch.column_at(ki)
    if kcol.null_count() > 0:
        return None
    var kt = kcol.arrow_type
    if not cd_strkey_fused_shape_admits(
        num_keys, kt, agg_data, num_aggs, num_rows, dispatcher.worker_count()
    ):
        return None
    if offset_width_bytes_or_raise("agg_cd_strkey_fused(key)", kt) == 8:
        return _fused_run[DType.int64](
            dispatcher, batch, agg_data, ki, num_aggs, num_rows, topk_hint
        )
    return _fused_run[DType.int32](
        dispatcher, batch, agg_data, ki, num_aggs, num_rows, topk_hint
    )


def _fused_run[
    OffsetType: DType
](
    mut dispatcher: LocalDispatcher[NoopSink],
    batch: RecordBatch,
    agg_data: AggSinkData,
    ki: Int,
    num_aggs: Int,
    num_rows: Int,
    topk_hint: Optional[CdGroupTopKHint],
) raises -> Optional[RecordBatch]:
    comptime bo = origin_of(batch)
    var p_shards = cd_fused_shard_count(dispatcher.worker_count())

    # SAFETY: the key buffers belong to `batch` (origin `bo`, a concrete
    # origin), which this call borrows for its whole body, so both pointers
    # outlive every dispatch below. The offsets are read at the column's own
    # offset.
    ref kcol = batch.column_at(ki)
    var data_ptr = (
        kcol._data.view_ro()
        ._unsafe_ptr()
        .bitcast[Scalar[DType.uint8]]()
        .unsafe_mut_cast[bo.mut]()
        .unsafe_origin_cast[bo]()
    )
    var offs_ptr = (
        kcol._offsets.value()
        .view_ro()
        ._unsafe_ptr()
        .bitcast[Scalar[OffsetType]]()
        .unsafe_mut_cast[bo.mut]()
        .unsafe_origin_cast[bo]()
    ) + kcol._offset

    # ---- heavy-key sample: DECLINE before any parallel work is paid ----
    # `cd_heavy_groups` is the driver's own heavy test (a sampled share above
    # 2/K), asked with K = the shard count.
    var n_sample = min(num_rows, CD_FUSED_SAMPLE_ROWS)
    var sample = List[Int](capacity=n_sample)
    for i in range(n_sample):
        var r = (i * num_rows) // n_sample
        sample.append(Int(_strenc_fnv_row(data_ptr, offs_ptr, r)))
    if len(cd_heavy_groups(sample, p_shards)) > 0:
        _fused_note(True)
        return None

    # ---- Phase A: the parallel FNV every string encode runs ----
    var hashes = _hash_string_rows_parallel[OffsetType](
        dispatcher, CancellationToken.never(), data_ptr, offs_ptr, num_rows
    )
    var val_ptrs = TypedColumnPtrs[bo].from_batch_padded(
        batch, agg_data.agg_exprs, num_aggs
    )
    var rows_hint = num_rows // p_shards
    var shards = Slab[_FusedShard](p_shards)
    for _ in range(p_shards):
        shards.append(_FusedShard(num_aggs, rows_hint))
    var state = _FusedState[OffsetType, bo, origin_of(hashes)](
        shards^,
        val_ptrs^,
        data_ptr,
        offs_ptr,
        hashes.unsafe_ptr(),
        num_rows,
        p_shards,
        num_aggs,
    )

    # ---- pass 1: shard = dictionary + distinct pairs, in parallel ----
    var back1 = dispatcher.run_with_state[
        _FusedState[OffsetType, bo, origin_of(hashes)],
        _FusedTask[OffsetType, bo, origin_of(hashes)],
    ](
        state,
        _FusedTask[OffsetType, bo, origin_of(hashes)](_FUSED_MODE_SHARD),
        p_shards,
        CancellationToken.never(),
        site_id=SITE_CD_STRENC,
    )
    _ = back1^
    if state.err_flag[].load() != Int8(0):
        raise Error(String(state.err_msg[]))

    # ---- the merge plan, and every buffer the merge writes ----
    var total = 0
    var first_rows = List[List[Int]](capacity=p_shards)
    for p in range(p_shards):
        ref sh = state.shards[].get_mut_interior(p)
        total += len(sh.starts)
        var fr = List[Int]()
        swap(fr, sh.first_row)
        first_rows.append(fr^)
    var n_tasks = _parb_merge_tasks(
        total, dispatcher.worker_count(), _PARB_MERGE_MIN_PER_TASK
    )
    var split_lo = List[Int]()
    var split_g0 = List[Int]()
    _parb_merge_plan(first_rows, total, num_rows, n_tasks, split_lo, split_g0)
    state.first_rows[] = first_rows^
    state.split_lo[] = split_lo^
    state.split_g0[] = split_g0^
    # The top-k admission needs only the group count, so the merge can write
    # the group-index column too when it will be read.
    var num_groups = total
    var topk_admit = cd_group_topk_admits(
        agg_data.output_schema, 1, num_groups, True, topk_hint
    )
    # UNINITIALISED on purpose: the merge's id ranges tile [0, total), so it
    # writes every element of every buffer below exactly once.
    state.out_starts[].resize(unsafe_uninit_length=total)
    state.out_lens[].resize(unsafe_uninit_length=total)
    var n_arrs = num_aggs + (1 if topk_admit else 0)
    var arrs = Slab[PrimitiveArray[DType.int64]](n_arrs)
    for _ in range(n_arrs):
        arrs.append(PrimitiveArray[DType.int64].allocate_uninitialized(total))
    state.out_arrs[] = arrs^
    state.with_index = topk_admit

    # ---- pass 2: order-preserving merge, counts carried ----
    var back2 = dispatcher.run_with_state[
        _FusedState[OffsetType, bo, origin_of(hashes)],
        _FusedTask[OffsetType, bo, origin_of(hashes)],
    ](
        state,
        _FusedTask[OffsetType, bo, origin_of(hashes)](_FUSED_MODE_MERGE),
        n_tasks,
        CancellationToken.never(),
        site_id=SITE_CD_STRENC,
    )
    _ = back2^
    if state.err_flag[].load() != Int8(0):
        raise Error(String(state.err_msg[]))

    # ---- the merge wrote one INT64 column per aggregate, in id order ----
    var agg_cols = List[Column[HeapRegion]]()
    for a in range(num_aggs):
        var arr = state.out_arrs[].replace(
            a, PrimitiveArray[DType.int64].allocate_uninitialized(0)
        )
        agg_cols.append(Column.from_primitive[DType.int64](arr^))

    # ---- top-k: the caller's own kernel and comparator, as in the driver ----
    var emit_gids = List[Int]()
    var topk_fired = False
    if topk_admit:
        var pre_b = RecordBatchBuilder.with_capacity(num_aggs + 1)
        var pre_sb = SchemaBuilder()
        for a in range(num_aggs):
            pre_sb.add_field(agg_data.output_schema.field_at(1 + a))
            pre_b.add_column(agg_cols[a].share())
        pre_sb.add_field(cd_group_topk_index_field())
        var idx_arr = state.out_arrs[].replace(
            num_aggs, PrimitiveArray[DType.int64].allocate_uninitialized(0)
        )
        pre_b.add_column(Column.from_primitive[DType.int64](idx_arr^))
        var sel = cd_group_topk_select(
            pre_b.build(pre_sb.build()), topk_hint.value().copy()
        )
        emit_gids = cd_group_topk_gids(sel)
        var gathered = List[Column[HeapRegion]](capacity=num_aggs)
        for a in range(num_aggs):
            gathered.append(sel.column_at(a).share())
        agg_cols = gathered^
        topk_fired = True
    var n_emit = len(emit_gids) if topk_fired else num_groups

    # ---- the key bytes are the SOURCE spans, in id order ----
    strdrain_note_cdp_call()
    var no_gk = List[Int]()
    # No prefetch: in id order the source spans ascend (ids are minted in row
    # order), so the full emit is a sequential read.
    var key_col = cd_emit_string_key_column(
        kcol._data.view_ro().into_span(),
        no_gk,
        state.out_starts[],
        state.out_lens[],
        emit_gids,
        topk_fired,
        num_groups,
        False,
        gk_identity=True,
    )
    strdrain_note_site(6, n_emit)
    strdrain_note_owner(3, n_emit)
    strdrain_note_cdp_builder(n_emit)
    var builder = RecordBatchBuilder.with_capacity(1 + num_aggs)
    var sb = SchemaBuilder()
    sb.add_field(agg_data.output_schema.field_at(0))
    builder.add_column(key_col^)
    for a in range(num_aggs):
        sb.add_field(agg_data.output_schema.field_at(1 + a))
        builder.add_column(agg_cols[a].share())
    var result = builder.build(sb.build())
    _ = hashes^
    _ = state^
    _ = batch
    _fused_note(False)
    return Optional[RecordBatch](result^)
