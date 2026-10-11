# =============================================================================
# residual_semi_anti_parallel -- the parallel SEMI / ANTI join with a residual
# predicate (an EXISTS / NOT EXISTS with a correlated non-equi condition) over
# one non-NULL INT64 key: the "mark join".
# =============================================================================
#
# Every probe row gets one mark byte, set when any of its equi-key candidates
# passes the residual; SEMI keeps the marked rows and ANTI the unmarked ones.
# Only membership matters, so the build's chain order is free and a Treiber
# push per row needs no ordering. Its levers are process settings
# (`join_probe_settings.residual_mark_configure`); its witnesses are in
# `residual_mark_counter`.
# =============================================================================

from std.atomic import Atomic
from std.io import FileDescriptor
from std.memory import alloc, UnsafePointer, OwnedPointer
from std.sys.intrinsics import prefetch, PrefetchOptions

from komira_async.runtime.sched_trace import (
    SITE_RESIDUAL_MARK_BUILD,
    SITE_RESIDUAL_MARK_PREPARE,
    SITE_RESIDUAL_MARK_STREAM,
    sched_trace_enabled,
)

from komira_arrow.record_batch import RecordBatch
from komira_arrow.primitive_array import PrimitiveArray
from komira_plan_expr.expr import Expr
from komira_plan_ir.logical_plan import JOIN_SEMI, JOIN_ANTI
from komira_column_kernels.compiler_helpers import gather_batch, share_batch
from komira_async_api.worker_pool_traits import KeepAlive, Segment

from komira_async_api.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.local_dispatcher import LocalDispatcher

from komira_engine_runtime.grain_geometry import grain_geometry_record
from komira_engine_runtime.fan_out_grain import parallel_fork_grain

from komira_op_join_build.join import _hash_join_key, _CHAIN_END
from .join_probe_settings import (
    residual_mark_cap_nearest_on,
    residual_mark_chain_fill_elide_on,
    residual_mark_fill_morsel,
    residual_mark_force_on,
    residual_mark_key_share_on,
    residual_mark_prepare_parallel_on,
)
from .residual_mask_eval import _compute_residual_pass_mask
from .residual_mark_counter import (
    residual_mark_build_span_record,
    residual_mark_geometry_record,
    residual_mark_stream_span_record,
    residual_mark_fire_incr,
    residual_mark_prepare_record,
)


comptime _MARK_PARALLEL_THRESHOLD: Int = 100_000

comptime _MARK_PF_DIST: Int = 8

# fd 2: a query's stdout is its result stream.
comptime _RM_STDERR: FileDescriptor = FileDescriptor(2)


struct _ResidualMarkCtx(Movable):
    """The read-only inputs every worker shares during the mark-join. OWNS Arc-
    shared (zero-copy) views of the probe/build batches, owned copies of the two
    INT64 key columns, and the residual `Expr`. Held (moved-in) by the single
    owned `_ResidualMarkState`.
    """

    var probe_batch: RecordBatch
    var build_batch: RecordBatch
    var probe_key: PrimitiveArray[DType.int64]
    var build_key: PrimitiveArray[DType.int64]
    var residual: Expr

    def __init__(
        out self,
        var probe_batch: RecordBatch,
        var build_batch: RecordBatch,
        var probe_key: PrimitiveArray[DType.int64],
        var build_key: PrimitiveArray[DType.int64],
        var residual: Expr,
    ):
        self.probe_batch = probe_batch^
        self.build_batch = build_batch^
        self.probe_key = probe_key^
        self.build_key = build_key^
        self.residual = residual^


def _residual_mark_parallel_eligible(
    probe_batch: RecordBatch,
    build_batch: RecordBatch,
    left_key_name: String,
    right_key_name: String,
    join_type: UInt8,
    has_equi: Bool,
) raises -> Bool:
    """True iff the parallel SEMI/ANTI residual mark-join should serve this probe:
    SEMI/ANTI join, a SINGLE INT64 equi-key, NON-NULL key columns on both sides,
    non-empty both sides, and either FORCE is set or the combined row count
    clears the parallel threshold. A decline routes to the serial
    `execute_residual_join_probe`, which gives the same rows.
    """
    if join_type != JOIN_SEMI and join_type != JOIN_ANTI:
        return False
    if not has_equi:
        return False
    var n_probe = probe_batch.num_rows()
    var n_build = build_batch.num_rows()
    if n_probe == 0 or n_build == 0:
        return False
    var lk_idx = probe_batch.schema.column_index(left_key_name)
    var rk_idx = build_batch.schema.column_index(right_key_name)
    if probe_batch.column_at(lk_idx).null_count() != 0:
        return False
    if build_batch.column_at(rk_idx).null_count() != 0:
        return False
    if residual_mark_force_on():
        return True
    return (n_probe + n_build) >= _MARK_PARALLEL_THRESHOLD


struct _ResidualMarkState(KeepAlive):
    """The one state both dispatch phases run over. OWNS the ctx bundle, the `ht`
    chain-head array, the `next_chain` link array, the `has_pass` mark byte array,
    the atomic morsel counter, and the `workers_active` fire-witness.
    """

    var build_morsel_size: Int
    var probe_morsel_size: Int
    var num_build_morsels: Int
    var num_build_rows: Int
    var num_probe_morsels: Int
    var num_probe_rows: Int
    var fill_morsel: Int
    var chain_fill_rows: Int
    var cap: Int
    var mask: UInt64
    var ctx: _ResidualMarkCtx
    var ht: List[Int64]
    var next_chain: List[Int64]
    var has_pass: List[UInt8]
    var morsel_counter: OwnedPointer[Atomic[DType.int64]]
    var workers_active: OwnedPointer[Atomic[DType.int64]]

    def __init__(
        out self,
        build_morsel_size: Int,
        probe_morsel_size: Int,
        num_build_morsels: Int,
        num_build_rows: Int,
        num_probe_morsels: Int,
        num_probe_rows: Int,
        fill_morsel: Int,
        chain_fill_rows: Int,
        cap: Int,
        mask: UInt64,
        var ctx: _ResidualMarkCtx,
        var ht: List[Int64],
        var next_chain: List[Int64],
        var has_pass: List[UInt8],
    ):
        self.build_morsel_size = build_morsel_size
        self.probe_morsel_size = probe_morsel_size
        self.num_build_morsels = num_build_morsels
        self.num_build_rows = num_build_rows
        self.num_probe_morsels = num_probe_morsels
        self.num_probe_rows = num_probe_rows
        self.fill_morsel = fill_morsel
        self.chain_fill_rows = chain_fill_rows
        self.cap = cap
        self.mask = mask
        self.ctx = ctx^
        self.ht = ht^
        self.next_chain = next_chain^
        self.has_pass = has_pass^
        var raw = alloc[Atomic[DType.int64]](1)
        UnsafePointer(to=raw[].value).unsafe_write(Scalar[DType.int64](0))
        self.morsel_counter = OwnedPointer[Atomic[DType.int64]](
            unsafe_from_raw_pointer=raw
        )
        var raw2 = alloc[Atomic[DType.int64]](1)
        UnsafePointer(to=raw2[].value).unsafe_write(Scalar[DType.int64](0))
        self.workers_active = OwnedPointer[Atomic[DType.int64]](
            unsafe_from_raw_pointer=raw2
        )

    def reset_phase(mut self):
        """Reset the morsel counter + worker-span witness to 0 between phases."""
        self.morsel_counter[].store(Scalar[DType.int64](0))
        self.workers_active[].store(Scalar[DType.int64](0))


@fieldwise_init
struct _ResidualPrepareTask(Segment):
    """Segment for the parallel buffer fill. Claims morsels over ONE flattened
    index space covering all three buffers in order — `ht`, then `next_chain`,
    then `has_pass` — so a single dispatch (one barrier) fills all of them and a
    worker that finishes a short region immediately picks up work in a long one.
    """

    var _pad: Int32

    def execute[State: KeepAlive](
        mut self, mut state: State, worker_id: Int32, task_id: Int64
    ) raises:
        var sp = UnsafePointer(to=state).bitcast[_ResidualMarkState]()
        var M = sp[].fill_morsel
        var cap = sp[].cap
        var nb = sp[].chain_fill_rows
        var np = sp[].num_probe_rows
        var n_ht = (cap + M - 1) // M
        var n_nc = (nb + M - 1) // M
        var n_hp = (np + M - 1) // M
        var n_total = n_ht + n_nc + n_hp

        var ht_ptr = sp[].ht.unsafe_ptr()
        var nc_ptr = sp[].next_chain.unsafe_ptr()
        var hp_ptr = sp[].has_pass.unsafe_ptr()

        var did_work = False
        while True:
            var morsel_idx = Int(sp[].morsel_counter[].fetch_add(Int64(1)))
            if morsel_idx >= n_total:
                break
            if not did_work:
                did_work = True
                _ = sp[].workers_active[].fetch_add(Int64(1))

            if morsel_idx < n_ht:
                var hs = morsel_idx * M
                var he = min(hs + M, cap)
                for i in range(hs, he):
                    (ht_ptr + i)[] = Int64(_CHAIN_END)
            elif morsel_idx < n_ht + n_nc:
                var cs = (morsel_idx - n_ht) * M
                var ce = min(cs + M, nb)
                for i in range(cs, ce):
                    (nc_ptr + i)[] = Int64(0)
            else:
                var ps = (morsel_idx - n_ht - n_nc) * M
                var pe = min(ps + M, np)
                for i in range(ps, pe):
                    (hp_ptr + i)[] = UInt8(0)


@fieldwise_init
struct _ResidualBuildTask(Segment):
    """Segment for the parallel build. Each task claims build-row morsels via the
    atomic counter and does a lock-free Treiber push of each build row index into
    its hash bucket (chain order is irrelevant for SEMI/ANTI).
    """

    var _pad: Int32

    def execute[State: KeepAlive](
        mut self, mut state: State, worker_id: Int32, task_id: Int64
    ) raises:
        var sp = UnsafePointer(to=state).bitcast[_ResidualMarkState]()
        var num_morsels = sp[].num_build_morsels
        var morsel_size = sp[].build_morsel_size
        var num_build_rows = sp[].num_build_rows
        var mask = sp[].mask

        ref bk = sp[].ctx.build_key
        var bk_view = bk.data.view_ro()
        # SAFETY: build_key is owned by the borrowed state, alive across the
        # fork-join barrier. `bk_view` keepalive holds the buffer for the loop.
        # INT64 storage; `bk.offset` folds any array slice offset.
        var bk_ptr = bk_view._unsafe_ptr().bitcast[Scalar[DType.int64]]() + bk.offset
        var ht_ptr = sp[].ht.unsafe_ptr()
        var nc_ptr = sp[].next_chain.unsafe_ptr()

        var did_work = False
        while True:
            var morsel_idx = Int(sp[].morsel_counter[].fetch_add(Int64(1)))
            if morsel_idx >= num_morsels:
                break
            if not did_work:
                did_work = True
                _ = sp[].workers_active[].fetch_add(Int64(1))

            var start = morsel_idx * morsel_size
            var end = min(start + morsel_size, num_build_rows)

            for i in range(start, end):
                if i + _MARK_PF_DIST < end:
                    var fk = Int64((bk_ptr + i + _MARK_PF_DIST)[])
                    var fslot = Int(_hash_join_key(fk) & mask)
                    prefetch[params = PrefetchOptions().for_write().high_locality()](
                        (ht_ptr + fslot).bitcast[Scalar[DType.int64]]()
                    )

                var key = Int64((bk_ptr + i)[])
                var slot = Int(_hash_join_key(key) & mask)

                # Lock-free Treiber push: read the current chain head, point this
                # entry's next-link at it, then CAS the head to this entry. Retry
                # on a lost race (another worker pushed to the same bucket first).
                # SAFETY: `ht_ptr + slot` is an owned-state buffer slot. An aligned
                # INT64 read is atomic on the hardware; the CAS validates staleness,
                # so a torn/stale `old` simply retries. The `next_chain[i]` write
                # targets a disjoint slot (this worker owns build row i).
                while True:
                    var old = Int64((ht_ptr + slot)[])
                    (nc_ptr + i)[] = old
                    if Atomic[DType.int64].compare_exchange(
                        ht_ptr + slot, old, Int64(i)
                    ):
                        break

        _ = bk_view


@fieldwise_init
struct _ResidualProbeTask(Segment):
    """Segment for the parallel probe+residual+mark. Each task claims disjoint
    probe-row morsels, collects its candidate (probe, build) pairs, evaluates the
    residual over them via the SAME byte-exact `_compute_residual_pass_mask`, and
    marks `has_pass` for its own probe rows.
    """

    var _pad: Int32

    def execute[State: KeepAlive](
        mut self, mut state: State, worker_id: Int32, task_id: Int64
    ) raises:
        var sp = UnsafePointer(to=state).bitcast[_ResidualMarkState]()
        var num_morsels = sp[].num_probe_morsels
        var morsel_size = sp[].probe_morsel_size
        var num_probe_rows = sp[].num_probe_rows
        var mask = sp[].mask

        ref pk = sp[].ctx.probe_key
        ref bkk = sp[].ctx.build_key
        var pk_view = pk.data.view_ro()
        var bk_view = bkk.data.view_ro()
        # SAFETY: probe_key/build_key owned by the borrowed state across the
        # barrier; the `*_view` keepalives hold the buffers. INT64 storage.
        var pk_ptr = pk_view._unsafe_ptr().bitcast[Scalar[DType.int64]]() + pk.offset
        var bk_ptr = bk_view._unsafe_ptr().bitcast[Scalar[DType.int64]]() + bkk.offset
        var ht_ptr = sp[].ht.unsafe_ptr()
        var nc_ptr = sp[].next_chain.unsafe_ptr()
        var hp_ptr = sp[].has_pass.unsafe_ptr()

        var cand_probe = List[Int]()
        var cand_build = List[Int]()

        var did_work = False
        while True:
            var morsel_idx = Int(sp[].morsel_counter[].fetch_add(Int64(1)))
            if morsel_idx >= num_morsels:
                break
            if not did_work:
                did_work = True
                _ = sp[].workers_active[].fetch_add(Int64(1))

            var start = morsel_idx * morsel_size
            var end = min(start + morsel_size, num_probe_rows)

            for p in range(start, end):
                if p + _MARK_PF_DIST < end:
                    var fk = Int64((pk_ptr + p + _MARK_PF_DIST)[])
                    var fslot = Int(_hash_join_key(fk) & mask)
                    prefetch[params = PrefetchOptions().for_read().high_locality()](
                        (ht_ptr + fslot).bitcast[Scalar[DType.int64]]()
                    )

                var key = Int64((pk_ptr + p)[])
                var slot = Int(_hash_join_key(key) & mask)
                var chain_idx = Int((ht_ptr + slot)[])
                while chain_idx != _CHAIN_END:
                    if Int64((bk_ptr + chain_idx)[]) == key:
                        cand_probe.append(p)
                        cand_build.append(chain_idx)
                    chain_idx = Int((nc_ptr + chain_idx)[])

        if len(cand_probe) != 0:
            var mask_bits = _compute_residual_pass_mask(
                sp[].ctx.probe_batch,
                sp[].ctx.build_batch,
                cand_probe,
                cand_build,
                sp[].ctx.residual,
            )
            for i in range(len(mask_bits)):
                if mask_bits[i]:
                    (hp_ptr + cand_probe[i])[] = UInt8(1)

        _ = pk_view
        _ = bk_view
        _ = cand_probe
        _ = cand_build


def parallel_residual_semi_anti_mark(
    mut dispatcher: LocalDispatcher[NoopSink],
    var cancel_token: CancellationToken,
    imm probe_batch: RecordBatch,
    imm build_batch: RecordBatch,
    left_key_name: String,
    right_key_name: String,
    join_type: UInt8,
    imm residual: Expr,
) raises -> RecordBatch:
    """Parallel SEMI/ANTI residual mark join over two resident batches, in
    three fanned waves: PREPARE fills the chain heads, links and per-probe-row
    marks; BUILD pushes every build row onto its bucket's chain with an atomic
    compare-exchange; PROBE walks each probe row's chain, evaluates the
    residual over its candidates (`_compute_residual_pass_mask`) and marks the
    rows with a passing candidate. Returns the kept probe rows in probe order,
    unprojected, the same rows as `execute_residual_join_probe`'s SEMI/ANTI.
    The caller has checked `_residual_mark_parallel_eligible` (non-NULL INT64
    keys).
    """
    residual_mark_fire_incr()

    var lk_idx = probe_batch.schema.column_index(left_key_name)
    var rk_idx = build_batch.schema.column_index(right_key_name)
    ref pcol = probe_batch.column_at(lk_idx)
    ref bcol = build_batch.column_at(rk_idx)
    var share_keys = residual_mark_key_share_on()
    var probe_key = (
        pcol.share_as_primitive[DType.int64]()
        if share_keys and pcol.can_share_as_primitive[DType.int64]()
        else pcol.as_primitive[DType.int64]()
    )
    var build_key = (
        bcol.share_as_primitive[DType.int64]()
        if share_keys and bcol.can_share_as_primitive[DType.int64]()
        else bcol.as_primitive[DType.int64]()
    )

    var num_probe_rows = probe_key.length
    var num_build_rows = build_key.length

    var ctx = _ResidualMarkCtx(
        share_batch(probe_batch),
        share_batch(build_batch),
        probe_key^,
        build_key^,
        residual.copy(),
    )

    var min_cap = max(Int(Float64(num_build_rows) * 1.4) + 1, 16)
    var cap = 1
    while cap < min_cap:
        cap *= 2
    if residual_mark_cap_nearest_on() and cap > 16:
        var lower = cap // 2
        if min_cap <= lower + (lower >> 6):
            cap = lower
    var mask = UInt64(cap - 1)

    residual_mark_geometry_record(num_build_rows, num_probe_rows, cap)
    if sched_trace_enabled():
        print(
            "[RESIDUAL_MARK_GEOM] build_rows=", num_build_rows,
            " probe_rows=", num_probe_rows,
            " min_cap=", min_cap,
            " cap=", cap,
            " cap_over_rows=", Float64(cap) / Float64(max(num_build_rows, 1)),
            " ht_bytes=", cap * 8,
            " next_chain_bytes=", num_build_rows * 8,
            " has_pass_bytes=", num_probe_rows,
            file=_RM_STDERR,
        )

    var prepare_parallel = residual_mark_prepare_parallel_on()
    var elide_chain_fill = residual_mark_chain_fill_elide_on()
    var chain_fill_rows = 0 if elide_chain_fill else num_build_rows
    var ht = List[Int64](capacity=max(cap, 1))
    var next_chain = List[Int64](capacity=max(num_build_rows, 1))
    var has_pass = List[UInt8](capacity=max(num_probe_rows, 1))
    if prepare_parallel:
        ht.resize(unsafe_uninit_length=cap)
        next_chain.resize(unsafe_uninit_length=num_build_rows)
        has_pass.resize(unsafe_uninit_length=num_probe_rows)
    else:
        ht.resize(cap, Int64(_CHAIN_END))
        if elide_chain_fill:
            next_chain.resize(unsafe_uninit_length=num_build_rows)
        else:
            next_chain.resize(num_build_rows, Int64(0))
        has_pass.resize(num_probe_rows, UInt8(0))

    var forced = residual_mark_force_on()

    var pool_n = dispatcher.worker_count()
    if pool_n < 1:
        pool_n = 1

    var build_morsel_size = 1 if forced else parallel_fork_grain(
        num_build_rows, pool_n
    )
    var probe_morsel_size = 1 if forced else parallel_fork_grain(
        num_probe_rows, pool_n
    )

    var num_build_morsels = (
        num_build_rows + build_morsel_size - 1
    ) // build_morsel_size
    var num_probe_morsels = (
        num_probe_rows + probe_morsel_size - 1
    ) // probe_morsel_size

    var fill_morsel = residual_mark_fill_morsel()

    var state = _ResidualMarkState(
        build_morsel_size,
        probe_morsel_size,
        num_build_morsels,
        num_build_rows,
        num_probe_morsels,
        num_probe_rows,
        fill_morsel,
        chain_fill_rows,
        cap,
        mask,
        ctx^,
        ht^,
        next_chain^,
        has_pass^,
    )

    # PARALLELIZE-BOUNDARY 0: the PREPARE fill. One flattened index space
    # over ht | next_chain | has_pass; a morsel owns an element range of
    # exactly one buffer and the ranges partition each, so the fill is
    # claim-order independent and leaves the same bytes as the serial fills
    # above. The state owns all three buffers, pre-sized and never grown, and
    # is borrowed for the dispatch; the barrier outlives every worker.
    #
    # SAFETY: under this setting the buffers were sized with
    # `resize(unsafe_uninit_length=)`, so this wave is a memory-safety
    # precondition of BUILD and PROBE, which read what it writes: they must
    # not start before its barrier returns.
    if prepare_parallel:
        var FM = fill_morsel
        var n_prep_morsels = (
            (cap + FM - 1) // FM
            + (chain_fill_rows + FM - 1) // FM
            + (num_probe_rows + FM - 1) // FM
        )
        var n_prep_workers = min(n_prep_morsels, pool_n)
        if n_prep_workers < 1:
            n_prep_workers = 1
        var prep_task = _ResidualPrepareTask(Int32(0))
        _ = dispatcher.run_with_state[_ResidualMarkState, _ResidualPrepareTask](
            state, prep_task^, n_prep_workers, cancel_token.clone(),
            site_id=SITE_RESIDUAL_MARK_PREPARE,
        )
        residual_mark_prepare_record(
            n_prep_morsels, Int(state.workers_active[].load())
        )
        state.reset_phase()

    var n_build_workers = min(num_build_morsels, pool_n)
    if n_build_workers < 1:
        n_build_workers = 1
    grain_geometry_record(
        SITE_RESIDUAL_MARK_BUILD,
        num_build_rows,
        build_morsel_size,
        num_build_morsels,
        n_build_workers,
    )
    var build_task = _ResidualBuildTask(Int32(0))
    _ = dispatcher.run_with_state[_ResidualMarkState, _ResidualBuildTask](
        state, build_task^, n_build_workers, cancel_token.clone(),
        site_id=SITE_RESIDUAL_MARK_BUILD,
    )
    residual_mark_build_span_record(Int(state.workers_active[].load()))
    state.reset_phase()

    var n_probe_workers = min(num_probe_morsels, pool_n)
    if n_probe_workers < 1:
        n_probe_workers = 1
    grain_geometry_record(
        SITE_RESIDUAL_MARK_STREAM,
        num_probe_rows,
        probe_morsel_size,
        num_probe_morsels,
        n_probe_workers,
    )
    var probe_task = _ResidualProbeTask(Int32(0))
    _ = dispatcher.run_with_state[_ResidualMarkState, _ResidualProbeTask](
        state, probe_task^, n_probe_workers, cancel_token^,
        site_id=SITE_RESIDUAL_MARK_STREAM,
    )
    residual_mark_stream_span_record(Int(state.workers_active[].load()))

    var want: UInt8 = UInt8(1) if join_type == JOIN_SEMI else UInt8(0)
    var keep = List[Int]()
    var hp_ro = state.has_pass.unsafe_ptr()
    for p in range(num_probe_rows):
        if (hp_ro + p)[] == want:
            keep.append(p)

    var probe_kept = gather_batch(probe_batch, keep)
    _ = state^
    return probe_kept^
