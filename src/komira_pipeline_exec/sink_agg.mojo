# =============================================================================
# sink_agg -- (SINK_AGG, KEY_DTYPE_NONE, SINK_ORIENT_COLUMNAR)
# =============================================================================
#
# The ungrouped aggregation sink: SUM, COUNT, COUNT(*), MIN, MAX and AVG over a
# morsel stream, one output row. The plan's aggregate arguments are expressions
# (`AggSinkData.agg_exprs`); the sink registers them once and each worker runs
# them as a projection (`MapOp`) over every morsel it is handed, under the
# morsel's selection mask: a projection of expressions that can raise sees only
# the selected rows. COUNT(*) needs no argument and counts the selected rows of
# the morsel.
#
# The state of a worker is one `AggCell` per aggregate (`agg_fold`), kept in
# the worker's own slot of a slab; `consume` writes only the caller's slot.
# Every fold is an exact integer fold, so `combine`, which runs once after the
# workers joined, merges the slots in worker order and the answer does not
# depend on which worker took which morsel. `agg_output` builds the one output
# row in the schema the plan declared.
#
# The state is fixed in size, so a worker draws it from the segment pool once
# (`segment_pool`), when it takes its first morsel, and gives it back at
# `combine`; a denied draw fails the query by name.
#
# Refused when the sink is built: group-by expressions (this is the sink of
# the key-less row), an aggregate this sink does not serve (anything but SUM,
# COUNT, MIN, MAX and AVG), an aggregate without the argument it needs, an
# output schema that does not list one column per aggregate, and an output
# column of a type the aggregate cannot produce. `AggSinkData.presorted` and
# `estimated_groups` are for grouped sinks and are ignored.

from std.memory import ArcPointer
from std.sys import size_of

from komira_arrow.schema import RecordBatch, RecordBatchBuilder, Schema
from komira_column_kernels.compiler_helpers import (
    materialize_selection_if_present,
)
from komira_morsel.morsel import Morsel
from komira_morsel.morsel_sink import MorselSinkImpl
from komira_morsel.pipeline_execution import PipelineExecution
from komira_operator_api.map_op import MapOp
from komira_phase_timers.phase_timers import (
    PH_SINK_FOLD,
    PH_SINK_MAP,
    pt_now,
    pt_record,
)
from komira_physical_plan.physical_plan import AggSinkData
from komira_plan_expr.agg_expr import (
    AGG_COUNT,
    AGG_MAX,
    AGG_MEAN,
    AGG_MIN,
    AGG_SUM,
)
from komira_plan_expr.expr_id import ExprId
from komira_plan_expr.expr_pool import ExprPool

from .agg_fold import AggCell, agg_name, fold_column, merge_cell
from .agg_output import agg_result_column, check_declared_type
from .segment_pool import SegmentPool, WorkerReservation


struct _AggSlot(Movable):
    var cells: List[AggCell]
    var map: Optional[MapOp]
    var reservation: WorkerReservation
    var started: Bool

    def __init__(out self, n_aggs: Int, var reservation: WorkerReservation):
        self.cells = List[AggCell]()
        for _ in range(n_aggs):
            self.cells.append(AggCell())
        self.map = None
        self.reservation = reservation^
        self.started = False


struct AggSink(MorselSinkImpl):
    """Folds the morsels of a segment into one row of aggregates."""

    var _seg_id: Int
    var _funcs: List[UInt8]
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

    def __init__(
        out self,
        ref data: AggSinkData,
        var pool: SegmentPool,
        seg_id: Int,
    ) raises:
        var where_ = (
            "komira_pipeline_exec: the aggregation sink of segment "
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
        self._funcs = List[UInt8]()
        self._arg_col = List[Int]()
        self._labels = List[String]()
        self._expr_ids = List[ExprId]()
        self._arg_names = List[String]()
        var expr_pool = ExprPool()
        for i in range(n):
            ref agg = data.agg_exprs[i]
            var func = agg.func
            if (
                func != AGG_SUM
                and func != AGG_COUNT
                and func != AGG_MIN
                and func != AGG_MAX
                and func != AGG_MEAN
            ):
                raise Error(
                    where_
                    + " does not serve aggregate tag "
                    + String(Int(func))
                    + " (SUM, COUNT, MIN, MAX and AVG are)"
                )
            var label = agg_name(func) + " (output column " + String(i) + ")"
            if agg.num_children() > 1:
                raise Error(where_ + ": " + label + " takes one argument")
            if not agg.child:
                if func != AGG_COUNT:
                    raise Error(where_ + ": " + label + " has no argument")
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
                "komira_pipeline_exec: the aggregation sink holds "
                + String(len(self._slots))
                + " worker slots, got worker "
                + String(worker_id)
            )
        ref slot = self._slots[worker_id][]
        if not slot.started:
            if not slot.reservation.try_grow(self._state_bytes):
                raise Error(
                    "komira_pipeline_exec: the aggregation sink of segment "
                    + String(self._seg_id)
                    + " was denied "
                    + String(self._state_bytes)
                    + " bytes of the segment's memory pool (budget "
                    + String(self._pool.budget())
                    + ", granted "
                    + String(self._pool.granted())
                    + ")"
                )
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
        if len(self._expr_ids) == 0:
            for i in range(len(self._funcs)):
                slot.cells[i].count += selected
            return
        var t_map = pt_now()
        _ = slot.map.value().execute(morsel)
        var dense = materialize_selection_if_present(morsel^.take_batch())
        pt_record[PH_SINK_MAP](t_map)
        var t_fold = pt_now()
        for i in range(len(self._funcs)):
            if self._arg_col[i] < 0:
                slot.cells[i].count += selected
            else:
                fold_column(
                    slot.cells[i],
                    self._funcs[i],
                    dense,
                    self._arg_col[i],
                    selected,
                    self._labels[i],
                )
        pt_record[PH_SINK_FOLD](t_fold)

    def combine(mut self, mut pipeline: PipelineExecution) raises -> None:
        var merged = List[AggCell]()
        for _ in range(len(self._funcs)):
            merged.append(AggCell())
        for w in range(len(self._slots)):
            ref slot = self._slots[w][]
            for i in range(len(self._funcs)):
                merge_cell(
                    merged[i],
                    slot.cells[i],
                    self._funcs[i],
                    self._labels[i],
                )
            slot.reservation.give_back_all()
        self._merged = merged^
        self._combined = True

    def finalize(mut self) raises:
        pass

    def take_output(mut self) raises -> RecordBatch:
        if not self._combined:
            raise Error(
                "komira_pipeline_exec: the aggregation sink was read before it"
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
