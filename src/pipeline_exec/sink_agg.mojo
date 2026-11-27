# =============================================================================
# sink_agg -- (SINK_AGG, KEY_DTYPE_NONE, SINK_ORIENT_COLUMNAR)
# =============================================================================
#
# The ungrouped aggregation sink: SUM, COUNT, COUNT(*), COUNT(DISTINCT), MIN,
# MAX, AVG, STDDEV_SAMP, STDDEV_POP, VAR_SAMP, VAR_POP, MEDIAN and
# QUANTILE_CONT over a morsel stream, one output row. The plan's aggregate
# arguments are expressions (`AggSinkData.agg_exprs`); the sink registers them
# once and each worker runs them as a projection (`MapOp`) over every morsel it is handed, under the
# morsel's selection mask: a projection of expressions that can raise sees only
# the selected rows. COUNT(*) needs no argument and counts the selected rows of
# the morsel.
#
# The state of a worker is one `AggCell` per aggregate (`agg_fold`), kept in
# the worker's own slot; `consume` writes only the caller's slot. `combine`,
# which runs once after the workers joined, merges the slots in worker order.
# A fold over integers, DECIMAL128 or DATE32 is exact, and so is a MIN or MAX
# of floats, so their answer does not depend on which worker took which
# morsel. A float SUM or AVG is a double sum, whose last bits depend on the
# order of the additions. `agg_output` builds the one output row in the
# schema the plan declared.
#
# By position (the segment's order key is ORDER_ROW_RANGE, `by_position`): a
# worker keeps one set of cells per source position instead, a position being
# the (`partition_id`, `origin_hint`) its source stamped on the morsel
# (`position_order`). Each position's cells fold its rows from +0.0 in row
# order; the chunks of one morsel an operator cut (they carry its position
# and reach the sink one after the other on one worker) fold into the same
# cells. `combine` sorts every worker's positions into source order and merges
# them in that order. Which worker held a position no longer matters, so a
# float SUM or AVG is the same bits on every worker count and schedule, given
# the same morsels: the sources cut a morsel from the input and the segment's
# morsel size alone. Two morsels at one position (a source that stamps no
# position) are refused by name at `combine`. Each position's cells are drawn
# from the segment pool when the position is first seen.
#
# COUNT(DISTINCT x) keeps the distinct non-NULL values of x a worker saw
# (`count_distinct`, all under group 0) instead of a cell; `combine` merges
# them and the merged cell's count is the number of distinct values. MEDIAN
# and QUANTILE_CONT keep every non-NULL value beside their cell
# (`agg_values`, under group 0, charged as they are kept); `combine` merges
# them and writes the answer into the merged cell. The variance family folds
# into its cell (`agg_fold`).
#
# The cells are fixed in size, so a worker draws them from the segment pool
# once (`segment_pool`), when it takes its first morsel, and gives them back at
# `combine`; a denied draw fails the query by name. The distinct values of a
# COUNT(DISTINCT) are charged to the same reservation as they grow.
#
# Refused when the sink is built: group-by expressions (this is the sink of
# the key-less row), an aggregate this sink does not serve (anything but SUM,
# COUNT, COUNT(DISTINCT), MIN, MAX, AVG, STDDEV_SAMP, STDDEV_POP, VAR_SAMP,
# VAR_POP, MEDIAN and QUANTILE_CONT), an aggregate without the arguments it
# needs (a QUANTILE_CONT's fraction a FLOAT64 constant in [0, 1]), an
# output schema that does not list one column per aggregate, and an output
# column of a type the aggregate cannot produce. `AggSinkData.presorted` and
# `estimated_groups` are for grouped sinks and are ignored.

from std.memory import ArcPointer
from std.sys import size_of

from arrow.schema import RecordBatch, RecordBatchBuilder, Schema
from column_kernels.compiler_helpers import (
    materialize_selection_if_present,
)
from morsel.morsel import Morsel
from morsel.morsel_sink import MorselSinkImpl
from morsel.pipeline_execution import PipelineExecution
from operator_api.map_op import MapOp
from phase_timers.phase_timers import (
    PH_SINK_FOLD,
    PH_SINK_MAP,
    pt_now,
    pt_record,
)
from physical_plan.physical_plan import AggSinkData
from plan_expr.agg_expr import AGG_COUNT_DISTINCT
from plan_expr.expr_id import ExprId
from plan_expr.expr_pool import ExprPool

from .agg_fold import AggCell, agg_name, fold_column, keeps_values, merge_cell
from .agg_values import (
    ValueMerge,
    ValueSlot,
    check_agg_args,
    keep_column_values,
)
from .agg_output import agg_result_column, check_declared_type
from .position_order import position_order
from .count_distinct import (
    DistinctMerge,
    DistinctSlot,
    admit_distinct,
    read_distinct_column,
)
from .segment_pool import MEMORY_BUDGET_EXCEEDED, SegmentPool, WorkerReservation


def _fresh_cells(n_aggs: Int) -> List[AggCell]:
    var cells = List[AggCell](capacity=n_aggs)
    for _ in range(n_aggs):
        cells.append(AggCell())
    return cells^


struct _Grain(Movable):
    """The cells of the morsels of one source position."""

    var partition_id: Int
    var origin_hint: Int
    var cells: List[AggCell]

    def __init__(out self, partition_id: Int, origin_hint: Int, n_aggs: Int):
        self.partition_id = partition_id
        self.origin_hint = origin_hint
        self.cells = _fresh_cells(n_aggs)


struct _AggSlot(Movable):
    var cells: List[AggCell]
    # By position: one entry per position this worker folded, in the order
    # it met them.
    var grains: List[_Grain]
    var map: Optional[MapOp]
    var reservation: WorkerReservation
    var distinct: DistinctSlot
    var values: ValueSlot
    var started: Bool

    def __init__(out self, n_aggs: Int, var reservation: WorkerReservation):
        self.cells = _fresh_cells(n_aggs)
        self.grains = List[_Grain]()
        self.map = None
        self.reservation = reservation^
        self.distinct = DistinctSlot(n_aggs)
        self.values = ValueSlot(n_aggs)
        self.started = False


def _draw(
    mut slot: _AggSlot, bytes: Int, seg_id: Int, ref pool: SegmentPool
) raises:
    """Draw one set of cells (`bytes`) from the segment pool for `slot`, or
    fail the query by name."""
    if not slot.reservation.try_grow(bytes):
        raise Error(
            String(MEMORY_BUDGET_EXCEEDED)
            + ": pipeline_exec: the aggregation sink of segment "
            + String(seg_id)
            + " was denied "
            + String(bytes)
            + " bytes of the segment's memory pool (budget "
            + String(pool.budget())
            + ", granted "
            + String(pool.granted())
            + ")"
        )


def _grain_for(
    mut slot: _AggSlot,
    partition_id: Int,
    origin_hint: Int,
    n_aggs: Int,
    bytes: Int,
    seg_id: Int,
    ref pool: SegmentPool,
) raises -> Int:
    """The index in `slot.grains` of the cells of position (`partition_id`,
    `origin_hint`): the last entry when the worker's previous morsel had this
    position (a chunk of the same morsel), else a new entry, drawn from the
    pool."""
    var n = len(slot.grains)
    if n > 0:
        if (
            slot.grains[n - 1].partition_id == partition_id
            and slot.grains[n - 1].origin_hint == origin_hint
        ):
            return n - 1
    _draw(slot, bytes, seg_id, pool)
    slot.grains.append(_Grain(partition_id, origin_hint, n_aggs))
    return n


struct AggSink(MorselSinkImpl):
    """Folds the morsels of a segment into one row of aggregates."""

    var _seg_id: Int
    var _where: String
    var _funcs: List[UInt8]
    # The fraction of each MEDIAN or QUANTILE_CONT (0.0 for the others).
    var _fractions: List[Float64]
    var _arg_col: List[Int]
    var _labels: List[String]
    var _schema: Schema
    var _exprs: ArcPointer[ExprPool]
    var _expr_ids: List[ExprId]
    var _arg_names: List[String]
    var _state_bytes: Int
    var _pool: SegmentPool
    # One slot per worker, each behind its own ArcPointer in a List: a slot
    # holds heap, so it is never kept in a Slab mutated through
    # get_mut_interior. A worker touches only the slot of its own task id.
    var _slots: List[ArcPointer[_AggSlot]]
    var _merged: List[AggCell]
    var _combined: Bool
    var _by_position: Bool

    def __init__(
        out self,
        ref data: AggSinkData,
        var pool: SegmentPool,
        seg_id: Int,
        by_position: Bool = False,
    ) raises:
        """The sink of segment `seg_id` for `data`, drawing its state from
        `pool`. `by_position` folds each source position on its own and merges
        them in position order (the segment is ORDER_ROW_RANGE); otherwise
        each worker folds what it was handed and the workers merge in worker
        order."""
        var where_ = (
            "pipeline_exec: the aggregation sink of segment "
            + String(seg_id)
        )
        if len(data.group_by_exprs) != 0:
            raise Error(
                where_
                + " has group-by expressions; this sink is the ungrouped row"
            )
        var n = len(data.agg_exprs)
        if n == 0:
            raise Error(where_ + " has no aggregate")
        if data.output_schema.num_columns() != n:
            raise Error(
                where_
                + " declares "
                + String(data.output_schema.num_columns())
                + " output columns for "
                + String(n)
                + " aggregates"
            )
        self._seg_id = seg_id
        self._where = where_
        self._funcs = List[UInt8]()
        self._fractions = List[Float64]()
        self._arg_col = List[Int]()
        self._labels = List[String]()
        self._expr_ids = List[ExprId]()
        self._arg_names = List[String]()
        var expr_pool = ExprPool()
        for i in range(n):
            ref agg = data.agg_exprs[i]
            var func = agg.func
            var label = agg_name(func) + " (output column " + String(i) + ")"
            self._fractions.append(check_agg_args(agg, where_, label))
            if not agg.child:
                self._arg_col.append(-1)
            else:
                self._arg_col.append(len(self._expr_ids))
                self._arg_names.append("agg_arg_" + String(i))
                self._expr_ids.append(
                    expr_pool.register(agg.child.value().copy())
                )
            check_declared_type(func, data.output_schema, i, label)
            self._funcs.append(func)
            self._labels.append(label^)
        self._schema = data.output_schema.copy()
        self._exprs = ArcPointer[ExprPool](expr_pool^)
        self._state_bytes = n * size_of[AggCell]()
        self._pool = pool^
        self._slots = List[ArcPointer[_AggSlot]]()
        self._merged = List[AggCell]()
        self._combined = False
        self._by_position = by_position

    def resize_worker_state(mut self, num_workers: Int) -> None:
        self._slots = List[ArcPointer[_AggSlot]](capacity=num_workers)
        for _ in range(num_workers):
            self._slots.append(
                ArcPointer[_AggSlot](
                    _AggSlot(
                        len(self._funcs),
                        WorkerReservation(self._pool.share()),
                    )
                )
            )

    def consume(self, worker_id: Int, var morsel: Morsel) raises:
        if worker_id < 0 or worker_id >= len(self._slots):
            raise Error(
                "pipeline_exec: the aggregation sink holds "
                + String(len(self._slots))
                + " worker slots, got worker "
                + String(worker_id)
            )
        ref slot = self._slots[worker_id][]
        if not slot.started:
            _draw(slot, self._state_bytes, self._seg_id, self._pool)
            if len(self._expr_ids) > 0:
                slot.map = Optional(
                    MapOp(
                        self._expr_ids.copy(),
                        self._arg_names.copy(),
                        ArcPointer(copy=self._exprs),
                    )
                )
            slot.started = True
        var selected = morsel.num_rows()
        if morsel.batch.has_selection_mask():
            selected = morsel.batch.selection_mask_true_count()
        if selected == 0:
            return
        # The cells this morsel folds into: its position's (g >= 0) or the
        # worker's.
        var g = -1
        if self._by_position:
            g = _grain_for(
                slot,
                morsel.partition_id,
                morsel.origin_hint,
                len(self._funcs),
                self._state_bytes,
                self._seg_id,
                self._pool,
            )
        if len(self._expr_ids) == 0:
            for i in range(len(self._funcs)):
                if g >= 0:
                    slot.grains[g].cells[i].count += selected
                else:
                    slot.cells[i].count += selected
            return
        var t_map = pt_now()
        _ = slot.map.value().execute(morsel)
        var dense = materialize_selection_if_present(morsel^.take_batch())
        pt_record[PH_SINK_MAP](t_map)
        var t_fold = pt_now()
        for i in range(len(self._funcs)):
            if self._arg_col[i] < 0:
                if g >= 0:
                    slot.grains[g].cells[i].count += selected
                else:
                    slot.cells[i].count += selected
            elif self._funcs[i] == AGG_COUNT_DISTINCT:
                var col = read_distinct_column(
                    slot.distinct,
                    i,
                    dense,
                    self._arg_col[i],
                    selected,
                    self._where,
                    self._labels[i],
                    self._pool,
                    slot.reservation,
                )
                for r in range(selected):
                    admit_distinct(
                        slot.distinct,
                        i,
                        0,
                        col,
                        r,
                        self._where,
                        self._pool,
                        slot.reservation,
                    )
            else:
                if g >= 0:
                    fold_column(
                        slot.grains[g].cells[i],
                        self._funcs[i],
                        dense,
                        self._arg_col[i],
                        selected,
                        self._labels[i],
                    )
                else:
                    fold_column(
                        slot.cells[i],
                        self._funcs[i],
                        dense,
                        self._arg_col[i],
                        selected,
                        self._labels[i],
                    )
                if keeps_values(self._funcs[i]):
                    keep_column_values(
                        slot.values,
                        i,
                        0,
                        dense,
                        self._arg_col[i],
                        selected,
                        slot.reservation,
                        self._where,
                        self._pool,
                    )
        pt_record[PH_SINK_FOLD](t_fold)

    def combine(mut self, mut pipeline: PipelineExecution) raises -> None:
        var n = len(self._funcs)
        var merged = List[AggCell]()
        for _ in range(n):
            merged.append(AggCell())
        var distinct = DistinctMerge(n, WorkerReservation(self._pool.share()))
        var values = ValueMerge(n, WorkerReservation(self._pool.share()))
        var only_group = List[Int]()
        only_group.append(0)
        if self._by_position:
            self._merge_positions(merged)
        for w in range(len(self._slots)):
            ref slot = self._slots[w][]
            for i in range(n):
                merge_cell(
                    merged[i],
                    slot.cells[i],
                    self._funcs[i],
                    self._labels[i],
                )
            distinct.merge_worker(
                slot.distinct,
                only_group,
                merged,
                n,
                self._where,
                self._labels,
                self._pool,
            )
            values.merge_worker(slot.values, only_group, self._where, self._pool)
            # This worker is merged: free its distinct and kept values and
            # return its memory.
            slot.distinct = DistinctSlot(n)
            slot.values = ValueSlot(n)
            slot.grains = List[_Grain]()
            slot.reservation.give_back_all()
        distinct.finish()
        values.finish(
            merged, self._funcs, self._fractions, 1, self._where, self._pool
        )
        self._merged = merged^
        self._combined = True

    def _merge_positions(self, mut merged: List[AggCell]) raises:
        """Merge the cells of every worker's positions into `merged`, in
        source position order. Raises, naming the position, when two morsels
        carried one position."""
        var parts = List[Int]()
        var hints = List[Int]()
        var at_worker = List[Int]()
        var at_index = List[Int]()
        for w in range(len(self._slots)):
            ref slot = self._slots[w][]
            for k in range(len(slot.grains)):
                parts.append(slot.grains[k].partition_id)
                hints.append(slot.grains[k].origin_hint)
                at_worker.append(w)
                at_index.append(k)
        var order = position_order(parts, hints)
        for k in range(len(order)):
            var at = order[k]
            if k > 0:
                var before = order[k - 1]
                if parts[before] == parts[at] and hints[before] == hints[at]:
                    raise Error(
                        self._where
                        + " folds by source position, and two morsels carried"
                        " position (partition "
                        + String(parts[at])
                        + ", origin "
                        + String(hints[at])
                        + "); its source does not stamp one position per"
                        " morsel"
                    )
            ref grain = self._slots[at_worker[at]][].grains[at_index[at]]
            for i in range(len(self._funcs)):
                merge_cell(
                    merged[i], grain.cells[i], self._funcs[i], self._labels[i]
                )

    def finalize(mut self) raises:
        pass

    def take_output(mut self) raises -> RecordBatch:
        if not self._combined:
            raise Error(
                "pipeline_exec: the aggregation sink was read before it"
                " was combined"
            )
        var builder = RecordBatchBuilder()
        for i in range(len(self._funcs)):
            builder.add_column(
                agg_result_column(
                    self._funcs[i],
                    self._merged[i],
                    self._schema,
                    i,
                    self._labels[i],
                )
            )
        return builder.build(self._schema.copy())
