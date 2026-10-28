# =============================================================================
# CountDistinctAggSink — the streaming COUNT(DISTINCT) aggregation sink
# =============================================================================
#
# A `komira_operator_api.MorselSink` for an aggregate whose COUNT(DISTINCT)
# aggregates are grouped by at most one INT32 / INT64 key, optionally mixed
# with SUM / COUNT / MIN / MAX / AVG. It keeps the exact cardinality: no
# sketch.
#
#   * `Local` (`CountDistinctAggLocal`) is one worker's `WorkerCDState`;
#     `consume` applies the segment's filters to a batch and folds it in.
#   * `combine` moves every worker's Local into the `Global`
#     (`CountDistinctAggGlobal.locals`).
#   * `finalize` builds the output batch:
#       - ungrouped: the per-partition union of every worker's dedup sets
#         (`agg_count_distinct_kernel`), one row;
#       - grouped: one global group directory over every worker's group ids
#         (`cd_global_dir`), each worker's value buffers MOVED (no copy) into
#         `radix_distinct_count_grouped` per COUNT(DISTINCT), and the fixed
#         aggregates' cells merged onto the same directory. Output columns
#         are in the plan's own order: the key, then each aggregate.
#   * `num_partitions` is `PARTITIONS_UNREVIEWED`: `combine` is one
#     driver-serial move per worker; the heavy work runs in `finalize`, on
#     the dispatcher.
# =============================================================================

from komira_udf.float_quotient_order import (
    float_quotient_gt_f64,
    float_quotient_lt_f64,
)
from std.memory import OwnedPointer
from komira_atomic_alias import AtomicI64

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import RecordBatch
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import Field, RecordBatchBuilder, SchemaBuilder
from komira_collections.slab import Slab

from komira_column_kernels.compiler_helpers import (
    resolve_col_index, gather_batch, materialize_selection_if_present,
)
from komira_column_kernels.comparison import filter_to_indices

from komira_batch_eval.eval_predicate import _eval_predicate
from komira_plan_expr.agg_expr import (
    AGG_COUNT, AGG_COUNT_DISTINCT, AGG_MAX, AGG_MEAN, AGG_MIN, AGG_SUM,
)
from komira_physical_plan.physical_plan import (
    AggSinkData,
    MorselOp,
    OP_FILTER,
    ParquetSourceData,
)
from komira_op_agg_distinct.streaming_agg_count_distinct import (
    FixedAggCell,
    WorkerCDState,
    _CD_VALUE_NUM_PARTITIONS,
)
from komira_op_agg_distinct.cd_passenger_lane_counter import cd_grouped_route_note
from komira_op_agg_distinct.cd_global_dir import CdGlobalDir
from komira_op_agg_distinct.agg_cd_fixed_emit import (
    _empty_column,
    _fixed_float_column,
    _fixed_int_column,
)
from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.local_dispatcher import LocalDispatcher
from komira_operator_api.memory_reservation import MemoryReservation
from komira_async_api.worker_pool_traits import KeepAlive

from komira_op_agg_distinct.agg_count_distinct_kernel import _cd_union_count_parallel
from komira_op_agg_state.growable_hash_set_i64 import (
    GrowableHashSetI64,
)
from komira_op_agg_distinct.cd_radix_grouped import radix_distinct_count_grouped
from komira_operator_api.morsel_sink import (
    FinalizeOutput,
    MorselSink,
    NeverMorselSource,
    PARTITIONS_UNREVIEWED,
    SinkCapabilities,
)



# =============================================================================
# CountDistinctAggLocal — per-worker WorkerCDState wrapper (Movable)
# =============================================================================


struct CountDistinctAggLocal(Movable, Deinitable):
    """Per-worker COUNT(DISTINCT) state.

    Wraps a `WorkerCDState` (per-group `List[Int]` value buffers + group
    map). `combine` moves every worker's Local into the Global, whether or
    not it saw a row.

    The wid-disjointness invariant comes from the executor (one Local per
    worker); `consume` writes this Local directly without a Slab indexing
    layer.
    """

    var state: WorkerCDState

    def __init__(out self, num_aggs: Int):
        self.state = WorkerCDState(num_aggs)


# =============================================================================
# CountDistinctAggGlobal — shared state (KeepAlive, non-Movable)
# =============================================================================


struct CountDistinctAggGlobal(KeepAlive):
    """Shared sink state: collected per-worker Locals + finalize claim atomic.

    NON-MOVABLE (inline `Atomic[Int64]`). Construct via `init_global`
    out-param.

    `combine(global, var local)` appends each worker's complete
    `CountDistinctAggLocal` into `locals` via `Slab.append(local^)` —
    moving the whole Local in one go avoids a partial move out of it.
    `finalize` then drains
    `Slab[CountDistinctAggLocal]` into a single merged worker-0
    `WorkerCDState`, runs the dedup helpers, and emits the output
    RecordBatch.

    `claim` is an atomic placeholder that keeps the Global non-Movable (a
    KeepAlive Global is constructed in place); nothing reads it.
    """

    var locals: Slab[CountDistinctAggLocal]
    var claim: AtomicI64

    def __init__(out self):
        self.locals = Slab[CountDistinctAggLocal]()
        self.claim = AtomicI64(Int64(0))

    def __keep_alive(mut self):
        # Default pass body — TYPED trampoline call site is what the
        # AOT compiler observes (worker_pool.mojo:182-185). Mirrors
        # `ColumnarAggGlobal.__keep_alive`.
        pass


# =============================================================================
# CountDistinctAggSink — the MorselSink
# =============================================================================


struct CountDistinctAggSink(MorselSink):
    """COUNT_DISTINCT aggregation sink (grouped + ungrouped).

    Per-worker `WorkerCDState` on Local; `combine` appends Local into
    Global.locals; `finalize` folds them into worker-0, runs per-group
    dedup, and emits the result batch.

    Construction: `CountDistinctAggSink.new(agg_data, pq_data, operators)`.
    `init_local` checks the shape and raises on anything outside it:
    at most one group key, whose declared output type is INT32 or INT64;
    aggregates only COUNT_DISTINCT, SUM, COUNT, MIN, MAX and MEAN; no
    fixed aggregate without a group key; an output schema with one field per
    key and aggregate; and SUM / COUNT / MIN / MAX / MEAN output types the
    sink can emit.

    Output schema layout (mirrors SchemaBuilder in schema_propagation.mojo):
      * ungrouped: fields = [agg_0, ..., agg_{K-1}], all COUNT_DISTINCT
      * one key:   fields = [key, agg_0, ..., agg_{K-1}]
    """

    comptime Local = CountDistinctAggLocal
    comptime Global = CountDistinctAggGlobal
    comptime Output = RecordBatch
    # The result is one batch built in `finalize`; there is no morsel source.
    comptime Source = NeverMorselSource

    # Shared config — read-only after construction.
    var _agg_data: AggSinkData
    var _pq_data: ParquetSourceData
    var _operators: Slab[MorselOp]

    var _num_aggs: Int
    var _num_keys: Int
    # THE OUTPUT-POSITION MAP.
    #
    # `_agg_data.agg_exprs` is in the PLAN's order, which is the order
    # `output_schema` declares, and a MIXED node interleaves COUNT(DISTINCT)
    # aggregates with ordinary ones in whatever order the user wrote them. The
    # CD machinery below (`WorkerCDState.cd_bufs[a]`, the radix driver) is
    # indexed by a DENSE CD slot, so the two index spaces are different and the
    # map between them has to be explicit. Every entry is derived ONCE, here:
    #
    #   `_pos_is_cd[i]`  — output agg position `i` is a COUNT(DISTINCT)
    #   `_pos_slot[i]`   — its index in the CD space, or in the fixed space
    #   `_fx_func[f]`    — the plan `AGG_*` tag of fixed slot `f`
    #   `_fx_src[f]`     — that slot's input col_ref, or "" for a bare COUNT(*)
    #
    # NOTE: `_num_aggs` STAYS THE **CD** COUNT. It is what `WorkerCDState` is
    # constructed with and what every `cd_bufs[a]` index means; re-pointing it
    # at the full agg list would silently mis-size the CD cell space.
    var _pos_is_cd: List[Bool]
    var _pos_slot: List[Int]
    var _fx_func: List[UInt8]
    var _fx_src: List[String]
    var _num_fixed: Int
    var _n_out_aggs: Int

    def __init__(
        out self,
        var agg_data: AggSinkData,
        var pq_data: ParquetSourceData,
        var operators: Slab[MorselOp],
    ):
        self._num_keys = len(agg_data.group_by_exprs)
        self._pos_is_cd = List[Bool]()
        self._pos_slot = List[Int]()
        self._fx_func = List[UInt8]()
        self._fx_src = List[String]()
        var n_cd = 0
        var n_fx = 0
        for i in range(len(agg_data.agg_exprs)):
            ref ae = agg_data.agg_exprs[i]
            if ae.func == AGG_COUNT_DISTINCT:
                self._pos_is_cd.append(True)
                self._pos_slot.append(n_cd)
                n_cd += 1
            else:
                self._pos_is_cd.append(False)
                self._pos_slot.append(n_fx)
                self._fx_func.append(ae.func)
                if ae.child:
                    self._fx_src.append(
                        String(ae.child.value().col_ref_name())
                    )
                else:
                    self._fx_src.append(String(""))
                n_fx += 1
        self._num_aggs = n_cd
        self._num_fixed = n_fx
        self._n_out_aggs = len(agg_data.agg_exprs)
        self._agg_data = agg_data^
        self._pq_data = pq_data^
        self._operators = operators^

    def _validate_shape(self) raises:
        """Raise unless the plan is inside the shape this sink computes."""
        if self._num_keys > 1:
            raise Error(
                "CountDistinctAggSink: at most one group key is supported, got "
                + String(self._num_keys)
            )
        ref out_schema = self._agg_data.output_schema
        if out_schema.num_columns() != self._num_keys + self._n_out_aggs:
            raise Error(
                "CountDistinctAggSink: the output schema has "
                + String(out_schema.num_columns()) + " fields for "
                + String(self._num_keys) + " key(s) and "
                + String(self._n_out_aggs) + " aggregate(s)"
            )
        if self._num_keys == 0 and self._num_fixed > 0:
            raise Error(
                "CountDistinctAggSink: SUM / COUNT / MIN / MAX / MEAN beside"
                " COUNT(DISTINCT) need a group key"
            )
        if self._num_keys == 1:
            var kt = out_schema.field_arrow_type(0)
            if kt != ArrowType.INT32 and kt != ArrowType.INT64:
                raise Error(
                    "CountDistinctAggSink: the group key must be INT32 or"
                    " INT64"
                )
        for i in range(self._n_out_aggs):
            if self._pos_is_cd[i]:
                continue
            var fn_tag = self._fx_func[self._pos_slot[i]]
            var ot = out_schema.field_arrow_type(self._num_keys + i)
            var is_int = ot == ArrowType.INT32 or ot == ArrowType.INT64
            var is_flt = ot == ArrowType.FLOAT32 or ot == ArrowType.FLOAT64
            if fn_tag == AGG_COUNT:
                if ot != ArrowType.INT64:
                    raise Error(
                        "CountDistinctAggSink: COUNT must be declared INT64"
                    )
            elif fn_tag == AGG_SUM:
                if ot != ArrowType.INT64 and ot != ArrowType.FLOAT64:
                    raise Error(
                        "CountDistinctAggSink: SUM must be declared INT64 or"
                        " FLOAT64"
                    )
            elif fn_tag == AGG_MEAN:
                if ot != ArrowType.FLOAT64:
                    raise Error(
                        "CountDistinctAggSink: MEAN must be declared FLOAT64"
                    )
            elif fn_tag == AGG_MIN or fn_tag == AGG_MAX:
                if not (is_int or is_flt):
                    raise Error(
                        "CountDistinctAggSink: MIN / MAX must be declared"
                        " INT32, INT64, FLOAT32 or FLOAT64"
                    )
            else:
                raise Error(
                    "CountDistinctAggSink: unsupported aggregate function "
                    + String(Int(fn_tag))
                )

    @staticmethod
    def new(
        var agg_data: AggSinkData,
        var pq_data: ParquetSourceData,
        var operators: Slab[MorselOp],
    ) -> Self:
        """Construct a sink for grouped/ungrouped COUNT(DISTINCT) aggregation."""
        return CountDistinctAggSink(agg_data^, pq_data^, operators^)

    # ---- MorselSink trait surface ----------------------------------

    def init_local(self) raises -> Self.Local:
        self._validate_shape()
        return CountDistinctAggLocal(self._num_aggs)

    def init_global(self, out sink_global: Self.Global) raises:
        # Return-slot form: the non-Movable Global can only be constructed
        # in place (it cannot be returned by value).
        sink_global = CountDistinctAggGlobal()

    def consume[
        o_local: Origin[mut=True], o_global: Origin[mut=True],
    ](
        self,
        worker_id: Int,
        ref [o_local] local: Self.Local,
        ref [o_global] sink_global: Self.Global,
        var batch: RecordBatch,
    ) raises:
        """Per-morsel consume — applies OP_FILTER + pushed_filter then
        delegates to `WorkerCDState.consume_batch{,_ungrouped}`.

        SAFETY: per-worker Local writes only — wid-partitioned invariant
        from the new MorselSink contract (no Slab[T] layer needed; the
        executor enforces wid-disjointness on Local).
        """
        if batch.num_rows() == 0:
            _ = batch^
            return

        # Materialize a selection mask carried by the batch, if any.
        batch = materialize_selection_if_present(batch^)

        # CORRECTNESS: the segment's OP_FILTER operators and the source's
        # pushed filter are applied before the fold; without them the count
        # would be over the unfiltered rows.
        var current = batch^

        for i in range(len(self._operators)):
            if current.num_rows() == 0:
                _ = current^
                return
            if (
                self._operators[i].tag == OP_FILTER
                and self._operators[i].filter_predicate
            ):
                var mask = _eval_predicate(
                    self._operators[i].filter_predicate.value(), current
                )
                var true_count = mask.true_count()
                if true_count == 0:
                    _ = current^
                    return
                if true_count != current.num_rows():
                    var indices = filter_to_indices(mask)
                    current = gather_batch(current, indices)

        if self._pq_data.pushed_filter and current.num_rows() > 0:
            var mask2 = _eval_predicate(
                self._pq_data.pushed_filter.value(), current
            )
            var true_count2 = mask2.true_count()
            if true_count2 == 0:
                _ = current^
                return
            if true_count2 != current.num_rows():
                var indices2 = filter_to_indices(mask2)
                current = gather_batch(current, indices2)

        if current.num_rows() == 0:
            _ = current^
            return

        # Per-batch column-index resolution. Cheap relative to per-row
        # consume (O(num_aggs * schema_cols) vs O(num_rows * num_aggs)).
        #
        # `val_idx` covers the CD slots ONLY (it is indexed by
        # the CD space `WorkerCDState.cd_bufs` uses); `fx_idx` covers the fixed
        # slots. Walking `_pos_is_cd` is what keeps the two apart when the plan
        # interleaves them.
        var val_idx = List[Int]()
        var fx_idx = List[Int]()
        var fx_is_int = List[Bool]()
        for i in range(self._n_out_aggs):
            if self._pos_is_cd[i]:
                if self._agg_data.agg_exprs[i].child:
                    val_idx.append(
                        resolve_col_index(
                            self._agg_data.agg_exprs[i].child.value(),
                            current.schema,
                        )
                    )
                else:
                    val_idx.append(-1)
                continue
            if not self._agg_data.agg_exprs[i].child:
                # A bare COUNT(*): no input column, and no type to classify.
                fx_idx.append(-1)
                fx_is_int.append(True)
                continue
            var ci = resolve_col_index(
                self._agg_data.agg_exprs[i].child.value(), current.schema
            )
            fx_idx.append(ci)
            # THE ACCUMULATOR LANE IS CHOSEN FROM THE **INPUT** TYPE, NOT THE
            # OUTPUT TYPE, AND THE DISTINCTION IS NOT COSMETIC. `avg(<bigint>)`
            # declares FLOAT64 output but `agg_mixed_cd_fold` — this lane's
            # oracle — sums it EXACTLY in an Int64 and divides once at emit.
            # Choosing the float lane off the output type would sum 100M
            # integers in double and answer a few ulps away from the arm that
            # serves the same SQL when the fuse declines.
            var at = ArrowType.INT64
            if ci >= 0:
                at = current.column_arrow_type(ci)
            fx_is_int.append(
                not (at == ArrowType.FLOAT64 or at == ArrowType.FLOAT32)
            )

        # ARM THE PASSENGER LANE ON FIRST CONSUME, not at `init_local`. The
        # lane's accumulator choice needs the DECODED batch's column types, and
        # `init_local` runs before any batch exists. `configure_fixed` REFUSES
        # once groups exist, so this can only ever run on a state that has
        # consumed nothing — which is exactly the first non-empty morsel.
        if self._num_fixed > 0 and local.state.num_fixed != self._num_fixed:
            local.state.configure_fixed(self._fx_func, fx_is_int)

        if self._num_keys == 0:
            # Ungrouped fast path -- no key load, no Dict lookup in
            # the row loop. All rows land in group 0.
            local.state.consume_batch_ungrouped(
                current,
                val_idx,
            )
        else:
            var key_idx = resolve_col_index(
                self._agg_data.group_by_exprs[0], current.schema
            )
            # Pick the INSTANTIATION. An all-COUNT(DISTINCT) node has no
            # fixed slot, and runs the `has_fixed=False` row loop in which the
            # passenger lane does not exist (the fused body with an empty fixed
            # list measured +4.32%).
            if self._num_fixed > 0:
                local.state.consume_batch[has_fixed=True](
                    current,
                    key_idx,
                    val_idx,
                    fx_idx,
                )
            else:
                local.state.consume_batch[has_fixed=False](
                    current,
                    key_idx,
                    val_idx,
                    fx_idx,
                )

        _ = current^

    def combine[
        o_global: Origin[mut=True], o_mem: Origin[mut=True],
    ](
        self,
        ref [o_global] sink_global: Self.Global,
        var states: Slab[OwnedPointer[Self.Local]],
        ref [o_mem] reservation: MemoryReservation,
    ) raises:
        """Whole-segment combine — append every worker's Local into Global.locals.

        Heavy merge work (per-group bulk-extend + dedup) lives in
        `finalize` so Global is the single source of truth for the
        merged state.
        """
        var n = len(states)
        var states_owned = states^
        for w in range(n):
            var owned_ptr = states_owned.take_slot_unchecked(w)
            var local = owned_ptr^.into_inner()
            sink_global.locals.append(local^)
        states_owned.set_len_unchecked(0)
        _ = states_owned^

    def num_partitions[o: Origin](
        self, ref [o] sink_global: Self.Global
    ) -> Int:
        return PARTITIONS_UNREVIEWED

    def finalize[disp_o: Origin[mut=True]](
        self,
        var sink_global: Self.Global,
        dispatcher_ptr: Pointer[LocalDispatcher[NoopSink], disp_o],
        cancel_token: CancellationToken,
    ) raises -> FinalizeOutput[Self]:
        """Delegates to `_finalize_batch`, which runs the union and the
        radix driver on the executor's dispatcher, and wraps its batch."""
        var batch = self._finalize_batch[disp_o=disp_o](
            sink_global^, dispatcher_ptr, cancel_token,
        )
        var out_slab = Slab[Self.Output].create(1)
        out_slab.append(batch^)
        return FinalizeOutput[Self](
            out_slab^,
        )

    def _finalize_batch[disp_o: Origin[mut=True]](
        self,
        var sink_global: Self.Global,
        dispatcher_ptr: Pointer[LocalDispatcher[NoopSink], disp_o],
        cancel_token: CancellationToken,
    ) raises -> RecordBatch:
        """Materialise the final RecordBatch from Global.locals.

        1. Drain `sink_global.locals` into a `Slab[CountDistinctAggLocal]`
           we own.
        2. UNGROUPED (num_keys==0): per-value-partition UNION of the
           per-worker dedup-on-scan `cd_sets`, 8-way parallel — one row.
        3. GROUPED (num_keys==1): build a
           global group directory, MOVE the per-(group, worker) value buffers
           directly into `radix_distinct_count_grouped` (NO serial bulk-extend
           fold, NO serial radix partition pass) — the driver parallelizes both
           the value-hash scatter and the per-cell dedup.
        4. Emit the output RecordBatch (key column when grouped, then N
           COUNT_DISTINCT result columns).
        """
        # `sink_global` is non-Movable (KeepAlive); we operate on the
        # `var` binding in-place. The closing `_ = sink_global^` at the
        # bottom of each return path is the destruction transfer-out
        # (mirrors the columnar finalize_helper shape).

        # Drain Global.locals into a local Slab so we can mutate freely.
        var workers = Slab[CountDistinctAggLocal]()
        var n = len(sink_global.locals)
        for i in range(n):
            workers.append(sink_global.locals.take_slot_unchecked(i))
        sink_global.locals.set_len_unchecked(0)

        var num_workers = len(workers)
        var num_aggs = self._num_aggs
        var num_keys = self._num_keys
        ref out_schema = self._agg_data.output_schema

        if num_workers == 0:
            # No data at all -- emit empty RecordBatch matching output
            # schema.
            _ = workers^
            _ = sink_global^
            if num_keys == 0:
                return self._build_empty_ungrouped_output()
            else:
                return self._build_empty_output()

        # =====================================================================
        # UNGROUPED (num_keys == 0) — per-value-partition UNION.
        # Each worker dedup-on-inserted during scan into per-value-partition
        # `cd_sets`; the union runs per-partition, 8-way parallel — no
        # bulk-extend, no raw value buffer materialised.
        # =====================================================================
        if num_keys == 0:
            ref dst = workers.get_mut_interior(0).state
            # Ensure worker-0's `cd_sets` are initialised so the 1-row output is
            # emitted whenever ANY worker saw data (worker 0 may never have seen
            # a batch while worker 1+ did).
            if len(dst.group_keys) == 0:
                for w in range(1, num_workers):
                    ref src = workers.get_mut_interior(w).state
                    if len(src.group_keys) > 0:
                        dst.group_keys.append(0)
                        dst.group_map[0] = 0
                        for a in range(num_aggs):
                            for _ in range(_CD_VALUE_NUM_PARTITIONS):
                                dst.cd_sets[a].append(GrowableHashSetI64())
                        break
            # Zero data across all workers -- emit 1-row empty.
            if len(dst.group_keys) == 0:
                _ = workers^
                _ = sink_global^
                return self._build_empty_ungrouped_output()

            var ub = RecordBatchBuilder()
            var usb = SchemaBuilder()
            for a in range(num_aggs):
                usb.add_field(out_schema.field_at(a))
                var uarr = PrimitiveArray[DType.int64].allocate(1)
                var worker_sets = List[List[GrowableHashSetI64]]()
                for w in range(num_workers):
                    ref ws = workers.get_mut_interior(w).state
                    if len(ws.cd_sets[a]) == _CD_VALUE_NUM_PARTITIONS:
                        # MOVE each set out (no copy): the union below
                        # folds into worker 0's sets and owns them from here.
                        var parts = List[GrowableHashSetI64]()
                        for p in range(_CD_VALUE_NUM_PARTITIONS):
                            var moved = GrowableHashSetI64()
                            swap(ws.cd_sets[a][p], moved)
                            parts.append(moved^)
                        worker_sets.append(parts^)
                var distinct_count = 0
                if len(worker_sets) > 0:
                    # Worker 0's sets (or the first worker's that has any)
                    # are the accumulator; the rest are folded into it.
                    var acc = worker_sets.pop(0)
                    distinct_count = _cd_union_count_parallel(
                        acc^, worker_sets, dispatcher_ptr[],
                        cancel_token.clone(),
                    )
                uarr.store[1](0, Scalar[DType.int64](distinct_count))
                _ = worker_sets^
                ub.add_column(Column.from_primitive[DType.int64](uarr^))
            var uresult = ub.build(usb.build())
            _ = workers^
            _ = sink_global^
            return uresult^

        # =====================================================================
        # GROUPED (num_keys == 1).
        #
        # Build a global group directory and MOVE the per-(group, worker)
        # value buffers DIRECTLY into `radix_distinct_count_grouped` — NO fold,
        # NO copy (each buffer move is an O(1) swap). That driver parallelizes
        # BOTH the value-hash counting-sort scatter AND the per-cell dedup,
        # cache-sizing every dedup cell to be L2-resident, and is BYTE-IDENTICAL
        # per group to the independent serial oracle (the distinct count is
        # invariant to value-hash partitioning + which worker deduped it).
        # A few huge groups take the driver's per-group internal-parallel
        # path; many groups take its across-group path.
        # =====================================================================
        # 1. Global group directory (worker-0-first registration order).
        #
        # Built ONCE as a
        # per-worker gid map `wgid[w][g]` (the Dict asked once per cell), which the
        # fixed-cell merge and every CD agg's drain below index instead of
        # re-probing the Dict per cell. Groups are numbered in first-seen order. See
        # `cd_global_dir.mojo`.
        #
        # The NULL group crosses the worker merge
        # OUTSIDE any key index, for the same reason it stays out of each
        # worker's `group_map`: there is no Int64 that means NULL, and any
        # sentinel collides with the real key equal to it.
        var gdir = CdGlobalDir()
        var wgid = List[List[Int]](capacity=num_workers)
        for w in range(num_workers):
            ref st = workers.get_mut_interior(w).state
            # Route witness — once per worker per query, off
            # the row path. See `cd_passenger_lane_counter`.
            cd_grouped_route_note(st.stat_batches, st.stat_fx_batches)
            wgid.append(gdir.map_worker(st.group_keys, st.group_key_null))
        var global_keys = gdir.keys.copy()
        var global_null_gid = gdir.null_gid
        var num_groups = len(global_keys)

        var builder = RecordBatchBuilder()
        var sb = SchemaBuilder()

        # 2. Key column.
        var key_at = out_schema.field_arrow_type(0)
        # The NULL group has to READ BACK as NULL.
        # Emitting it with no validity renders it as `0`, which is a DIFFERENT
        # wrong answer: the row set would be right and the key a lie — and on a
        # column that also holds a real `0` the two rows would be
        # indistinguishable. The output FIELD is re-stamped nullable in that
        # case too: a schema saying `not null` over a column carrying nulls is
        # an Arrow contract violation the C Data Interface export trips on.
        #
        # VALIDITY ONLY WHEN A NULL GROUP EXISTS — a null-free input takes the
        # plain `allocate` and the unmodified field.
        var key_has_null = global_null_gid >= 0
        if key_has_null:
            var kf = out_schema.field_at(0)
            kf.nullable = True
            sb.add_field(kf)
        else:
            sb.add_field(out_schema.field_at(0))
        if key_at == ArrowType.INT32:
            if key_has_null:
                var knarr = PrimitiveArray[DType.int32].allocate_nullable(
                    num_groups
                )
                for g in range(num_groups):
                    knarr.store[1](g, Scalar[DType.int32](global_keys[g]))
                # Values FIRST, then the null: a store marks its index VALID.
                knarr._set_null(global_null_gid)
                builder.add_column(Column.from_primitive[DType.int32](knarr^))
            else:
                var karr = PrimitiveArray[DType.int32].allocate(num_groups)
                for g in range(num_groups):
                    karr.store[1](g, Scalar[DType.int32](global_keys[g]))
                builder.add_column(Column.from_primitive[DType.int32](karr^))
        else:
            if key_has_null:
                var knarr = PrimitiveArray[DType.int64].allocate_nullable(
                    num_groups
                )
                for g in range(num_groups):
                    knarr.store[1](g, Scalar[DType.int64](global_keys[g]))
                knarr._set_null(global_null_gid)
                builder.add_column(Column.from_primitive[DType.int64](knarr^))
            else:
                var karr = PrimitiveArray[DType.int64].allocate(num_groups)
                for g in range(num_groups):
                    karr.store[1](g, Scalar[DType.int64](global_keys[g]))
                builder.add_column(Column.from_primitive[DType.int64](karr^))

        # 2b. MERGE THE FIXED CELLS onto the SAME global group
        # directory the CD runs use, before anything is emitted. Every worker
        # folded against its OWN gid space; `wgid` is the one
        # mapping that reconciles them, and reusing it (rather than
        # rebuilding one) is what guarantees the fixed columns and the CD
        # columns describe the same rows.
        #
        # MIN/MAX merge on `n == 0` meaning "this side contributed nothing", the
        # same sentinel-free rule the per-row seed uses. SUM/MEAN/COUNT are
        # additive and need no special case.
        var fx_merged = List[List[FixedAggCell]]()
        var fx_is_int_f = List[Bool]()
        if self._num_fixed > 0:
            for f in range(self._num_fixed):
                var col = List[FixedAggCell]()
                for _ in range(num_groups):
                    col.append(FixedAggCell(Int64(0), Float64(0.0), Int64(0)))
                fx_merged.append(col^)
                fx_is_int_f.append(True)
            # The accumulator lane was classified from the decoded batch at
            # consume time and recorded on the worker state; read it back from
            # the first worker that actually armed. A run where NO worker saw a
            # row leaves the default, and every cell is then `n == 0` (NULL).
            for w in range(num_workers):
                ref stw = workers.get_mut_interior(w).state
                if stw.num_fixed == self._num_fixed:
                    for f in range(self._num_fixed):
                        fx_is_int_f[f] = stw.fx_is_int[f]
                    break
            for w in range(num_workers):
                ref st = workers.get_mut_interior(w).state
                if st.num_fixed != self._num_fixed:
                    continue
                ref wmap = wgid[w]
                for g in range(len(st.group_keys)):
                    var gg = wmap[g]
                    for f in range(self._num_fixed):
                        if g >= len(st.fx_cells[f]):
                            continue
                        ref src = st.fx_cells[f][g]
                        if src.n == Int64(0):
                            continue
                        ref dst = fx_merged[f][gg]
                        var afn = self._fx_func[f]
                        if afn == AGG_MIN:
                            if fx_is_int_f[f]:
                                if dst.n == Int64(0) or src.i_acc < dst.i_acc:
                                    dst.i_acc = src.i_acc
                            else:
                                # Quotient order, not a bare `<`: IEEE compares false
                                # against a NaN, so a held NaN would never be
                                # replaced by 0.1; NaN sorts above +inf, so the
                                # minimum is the smallest number.
                                if dst.n == Int64(0) or float_quotient_lt_f64(src.f_acc, dst.f_acc):
                                    dst.f_acc = src.f_acc
                        elif afn == AGG_MAX:
                            if fx_is_int_f[f]:
                                if dst.n == Int64(0) or src.i_acc > dst.i_acc:
                                    dst.i_acc = src.i_acc
                            else:
                                # Quotient order, not a bare `>`: IEEE compares false
                                # against a NaN, so `max{0.1, NaN}` would answer 0.1;
                                # NaN sorts above +inf, so the maximum is NaN.
                                if dst.n == Int64(0) or float_quotient_gt_f64(src.f_acc, dst.f_acc):
                                    dst.f_acc = src.f_acc
                        else:
                            dst.i_acc += src.i_acc
                            dst.f_acc += src.f_acc
                        dst.n += src.n

        # 3. Per-agg output columns, IN THE PLAN'S OWN ORDER. A COUNT(DISTINCT)
        # position runs the parallel across-groups radix driver; a fixed
        # position drains the merged cells above. `_pos_slot` is what maps
        # an output position onto the dense slot of whichever space serves it.
        for _i_pos in range(self._n_out_aggs):
            if not self._pos_is_cd[_i_pos]:
                var f = self._pos_slot[_i_pos]
                var ffn = self._fx_func[f]
                var ffield = out_schema.field_at(num_keys + _i_pos)
                if ffn == AGG_COUNT:
                    # COUNT(*) -> every row of the group; COUNT(col) -> non-null
                    # rows. Both are non-null INT64 — 0 is a real answer here,
                    # never NULL.
                    var carr2 = PrimitiveArray[DType.int64].allocate(num_groups)
                    for g in range(num_groups):
                        carr2.store[1](
                            g, Scalar[DType.int64](fx_merged[f][g].n)
                        )
                    sb.add_field(ffield)
                    builder.add_column(
                        Column.from_primitive[DType.int64](carr2^)
                    )
                    continue
                # ZERO CONTRIBUTING ROWS -> NULL, for SUM / MIN / MAX / MEAN.
                var anynull = False
                for g in range(num_groups):
                    if fx_merged[f][g].n == Int64(0):
                        anynull = True
                        break
                if anynull:
                    ffield.nullable = True
                # The column is emitted at the DECLARED type; the values come
                # from whichever lane the input type selected.
                var oat = ffield.arrow_type
                sb.add_field(ffield)
                if oat == ArrowType.FLOAT64:
                    builder.add_column(
                        _fixed_float_column[DType.float64](
                            fx_merged[f], num_groups, anynull, ffn,
                            fx_is_int_f[f],
                        )
                    )
                elif oat == ArrowType.FLOAT32:
                    builder.add_column(
                        _fixed_float_column[DType.float32](
                            fx_merged[f], num_groups, anynull, ffn,
                            fx_is_int_f[f],
                        )
                    )
                else:
                    if not fx_is_int_f[f]:
                        raise Error(
                            "CountDistinctAggSink: an integer aggregate is"
                            " declared over a floating-point input"
                        )
                    if oat == ArrowType.INT32:
                        builder.add_column(
                            _fixed_int_column[DType.int32](
                                fx_merged[f], num_groups, anynull
                            )
                        )
                    else:
                        builder.add_column(
                            _fixed_int_column[DType.int64](
                                fx_merged[f], num_groups, anynull
                            )
                        )
                continue
            var a = self._pos_slot[_i_pos]
            sb.add_field(out_schema.field_at(num_keys + _i_pos))
            # groups_runs[gg] = each worker's (moved) value runs for group gg.
            # Every move here is O(1) — no bulk-extend copy, no concat into
            # worker 0.
            #
            # A (worker, group) cell contributes EITHER its raw append buffer (cell never promoted)
            # OR one already-deduped run per value partition (cell promoted
            # during scan). `into_keys()` MOVES each promoted partition set's
            # dense key column out, so converting a set back into a run costs
            # nothing — no drain loop, no copy, no allocation.
            #
            # The driver below needs no knowledge of which
            # kind a run is: `radix_distinct_count_grouped` returns the
            # distinct count of the UNION of a group's runs, and pre-deduping
            # a run does not change that union's distinct set. Feeding it
            # fewer, deduped values is a pure input-size reduction.
            # Each group's run list is sized ONCE from the exact count
            # of worker cells that map onto it (plus the promoted-set runs, which
            # can only exist on the opt-in scan-dedup arm and simply grow).
            var groups_runs = List[List[List[Int64]]](capacity=num_groups)
            for gg0 in range(num_groups):
                groups_runs.append(List[List[Int64]](capacity=gdir.runs[gg0]))
            for w in range(num_workers):
                ref st = workers.get_mut_interior(w).state
                ref wmap = wgid[w]
                for g in range(len(st.group_keys)):
                    # The NULL group is `global_null_gid`, which
                    # `wgid` already carries (its stored key is a placeholder
                    # and would alias a real key through any key index).
                    var gg = wmap[g]
                    # Promoted partition sets, if any. Consumed by `pop()` +
                    # `into_keys(var self)` so a half-drained set is not
                    # reachable. Partition order is irrelevant — a distinct
                    # count does not depend on which run a value arrives in.
                    while len(st.cd_gsets[a][g]) > 0:
                        var keys = st.cd_gsets[a][g].pop().into_keys()
                        if len(keys) > 0:
                            groups_runs[gg].append(keys^)
                        else:
                            _ = keys^
                    # Raw append buffer (empty for a promoted cell).
                    var buf = List[Int64]()
                    swap(st.cd_bufs[a][g], buf)
                    if len(buf) > 0:
                        groups_runs[gg].append(buf^)
                    else:
                        _ = buf^

            var carr = PrimitiveArray[DType.int64].allocate(num_groups)
            var counts = radix_distinct_count_grouped(
                groups_runs^, dispatcher_ptr[], cancel_token.clone()
            )
            for g in range(num_groups):
                carr.store[1](g, Scalar[DType.int64](counts[g]))
            builder.add_column(Column.from_primitive[DType.int64](carr^))

        var result = builder.build(sb.build())
        # Keepalive — force the workers Slab + sink_global to live to exit.
        _ = workers^
        _ = sink_global^
        return result^

    def combine_trace_label(self) -> StaticString:
        """This sink's own name, for the executor's combine trace.
        Diagnostic only -- it decides nothing."""
        return "CountDistinctAggSink"

    def capabilities(self) -> SinkCapabilities:
        var caps = SinkCapabilities()
        caps.output_is_batch = True
        return caps

    # -------------------------------------------------------------------------
    # Empty-output builders (shared between "no workers" and "no groups")
    # -------------------------------------------------------------------------

    def _build_empty_output(self) raises -> RecordBatch:
        """Emit an empty RecordBatch that matches the declared agg output
        schema (key + N COUNT_DISTINCT columns). Grouped path only.
        """
        ref out_schema = self._agg_data.output_schema
        var builder = RecordBatchBuilder()
        var sb = SchemaBuilder()

        sb.add_field(out_schema.field_at(0))
        builder.add_column(_empty_column(out_schema.field_arrow_type(0)))

        # An EMPTY result still has to carry every declared
        # column at its DECLARED type. `_n_out_aggs` (not `_num_aggs`, the CD
        # count) is the number of agg columns the plan promised, and a FLOAT64
        # `avg` column emitted as INT64 is a schema mismatch a consumer sees
        # long after this function returns.
        for i in range(self._n_out_aggs):
            sb.add_field(out_schema.field_at(1 + i))
            builder.add_column(_empty_column(out_schema.field_arrow_type(1 + i)))

        return builder.build(sb.build())

    def _build_empty_ungrouped_output(self) raises -> RecordBatch:
        """Emit a 1-row RecordBatch for ungrouped COUNT_DISTINCT over empty
        input. SQL standard: ungrouped aggregate MUST produce exactly 1 row
        even on empty input. COUNT returns 0 (never NULL).
        """
        ref out_schema = self._agg_data.output_schema
        var builder = RecordBatchBuilder()
        var sb = SchemaBuilder()

        for a in range(self._num_aggs):
            sb.add_field(out_schema.field_at(a))
            var arr = PrimitiveArray[DType.int64].allocate(1)
            arr.store[1](0, Scalar[DType.int64](0))
            builder.add_column(Column.from_primitive[DType.int64](arr^))

        return builder.build(sb.build())
