# =============================================================================
# sink_group_agg -- (SINK_AGG, KEY_DTYPE_I64 | I32 | F64 | F32, COLUMNAR)
# =============================================================================
#
# The grouped aggregation sink over fixed-width keys: GROUP BY one or more
# integer columns (rows I64 and I32) or float columns (rows F64 and F32), with
# SUM, COUNT, COUNT(*), MIN, MAX and AVG, the aggregates and their exact
# folds being those of the ungrouped sink (`agg_fold`).
#
# The plan's group-by expressions and aggregate arguments are registered once
# and run by each worker as one projection (`MapOp`) over every morsel, under
# the morsel's selection mask. The projection's first columns are the keys, the
# rest the arguments. The output schema lists the key columns, then one column
# per aggregate; a key column is declared in the type of its input column.
#
# Each worker folds its rows into a `GroupTable` of its own slot (`group_table`;
# key cells in `group_keys`). A NULL key is a group of its own; equal floats,
# every NaN, and 0.0 with -0.0, are one group. `combine`, which runs once after
# the workers joined, merges the tables into one in worker order with
# `merge_cell`, so the exact-overflow rule of the ungrouped sink holds per
# group, and a sum that overflows only when the workers' partials are added is
# refused there. The order of the output groups is unspecified: a plan that
# needs an order sorts.
#
# Memory is charged as the tables grow, not once: every doubling of a table's
# capacity is charged to the worker's reservation before it is made
# (`segment_pool`), and the merged table is charged to the sink's own
# reservation. A denial fails the query by name. A worker's table is freed and
# its reservation returned as soon as it is merged, and every reservation is
# returned when the sink is dropped, whether or not the query succeeded.
#
# Refused when the sink is built: no group-by expression, an aggregate the
# sink does not serve, an aggregate without its argument, an output schema
# that does not list the keys and aggregates, and a declared key column of a
# type the row does not key. Refused when rows arrive: a key column of a type
# the row does not key, or a type that changes between morsels; at `combine`,
# a declared key type that is not the input's.

from std.memory import ArcPointer

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import RecordBatch, RecordBatchBuilder, Schema
from komira_column_kernels.compiler_helpers import (
    empty_batch_like_schema,
    materialize_selection_if_present,
)
from komira_morsel.morsel import Morsel
from komira_morsel.morsel_sink import MorselSinkImpl
from komira_morsel.pipeline_execution import PipelineExecution
from komira_operator_api.map_op import MapOp
from komira_physical_plan.physical_plan import (
    AggSinkData,
    KEY_DTYPE_F32,
    KEY_DTYPE_F64,
)
from komira_plan_expr.agg_expr import (
    AGG_COUNT,
    AGG_MAX,
    AGG_MEAN,
    AGG_MIN,
    AGG_SUM,
)
from komira_plan_expr.expr_id import ExprId
from komira_plan_expr.expr_pool import ExprPool

from .agg_fold import WideColumn, agg_name, fold_wide, merge_cell, widen_column
from .agg_output import agg_result_column_rows, check_declared_type
from .group_keys import (
    KeyColumn,
    is_float_key_type,
    is_int_key_type,
    key_output_column,
    read_key_column,
)
from .group_table import GroupTable, hash_key
from .segment_pool import SegmentPool, WorkerReservation


struct _GroupSlot(Movable):
    var table: GroupTable
    var map: Optional[MapOp]
    var reservation: WorkerReservation
    var key_arrows: List[ArrowType]
    var scratch_cells: List[Int64]
    var scratch_nulls: List[UInt8]
    var started: Bool

    def __init__(
        out self, nk: Int, na: Int, var reservation: WorkerReservation
    ):
        self.table = GroupTable(nk, na)
        self.map = None
        self.reservation = reservation^
        self.key_arrows = List[ArrowType]()
        self.scratch_cells = List[Int64]()
        self.scratch_nulls = List[UInt8]()
        for _ in range(nk):
            self.key_arrows.append(ArrowType.NULL)
            self.scratch_cells.append(0)
            self.scratch_nulls.append(0)
        self.started = False


struct GroupAggSink(MorselSinkImpl):
    """Folds the morsels of a segment into one row of aggregates per group."""

    var _seg_id: Int
    var _floats: Bool
    var _nk: Int
    var _funcs: List[UInt8]
    var _arg_col: List[Int]
    var _labels: List[String]
    var _key_labels: List[String]
    var _schema: Schema
    var _exprs: ArcPointer[ExprPool]
    var _expr_ids: List[ExprId]
    var _names: List[String]
    var _pool: SegmentPool
    # One slot per worker, each behind its own ArcPointer in a List: a slot
    # holds heap (the table), so it is never kept in a Slab mutated through
    # get_mut_interior. A worker touches only the slot of its own task id.
    var _slots: List[ArcPointer[_GroupSlot]]
    var _merge_reservation: WorkerReservation
    var _merged: GroupTable
    var _merged_arrows: List[ArrowType]
    var _combined: Bool

    def __init__(
        out self,
        ref data: AggSinkData,
        key_dtype: UInt8,
        var pool: SegmentPool,
        seg_id: Int,
    ) raises:
        var where_ = (
            "komira_pipeline_exec: the grouped aggregation sink of segment "
            + String(seg_id)
        )
        var nk = len(data.group_by_exprs)
        var na = len(data.agg_exprs)
        if nk == 0:
            raise Error(
                where_ + " has no group-by expression; this sink is the keyed"
                " rows"
            )
        if data.output_schema.num_columns() != nk + na:
            raise Error(
                where_
                + " declares "
                + String(data.output_schema.num_columns())
                + " output columns for "
                + String(nk)
                + " keys and "
                + String(na)
                + " aggregates"
            )
        self._seg_id = seg_id
        self._floats = key_dtype == KEY_DTYPE_F64 or key_dtype == KEY_DTYPE_F32
        self._nk = nk
        self._funcs = List[UInt8]()
        self._arg_col = List[Int]()
        self._labels = List[String]()
        self._key_labels = List[String]()
        self._expr_ids = List[ExprId]()
        self._names = List[String]()
        var expr_pool = ExprPool()
        for k in range(nk):
            var t = data.output_schema.field_arrow_type(k)
            var ok = is_float_key_type(t) if self._floats else is_int_key_type(
                t
            )
            if not ok:
                raise Error(
                    where_
                    + " declares output column "
                    + String(k)
                    + " (a key) as "
                    + String(t)
                    + ", which its row does not key"
                )
            self._key_labels.append("group key " + String(k))
            self._names.append("group_key_" + String(k))
            self._expr_ids.append(
                expr_pool.register(data.group_by_exprs[k].copy())
            )
        for i in range(na):
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
            var label = (
                agg_name(func) + " (output column " + String(nk + i) + ")"
            )
            if agg.num_children() > 1:
                raise Error(where_ + ": " + label + " takes one argument")
            if not agg.child:
                if func != AGG_COUNT:
                    raise Error(where_ + ": " + label + " has no argument")
                self._arg_col.append(-1)
            else:
                self._arg_col.append(len(self._expr_ids))
                self._names.append("agg_arg_" + String(i))
                self._expr_ids.append(
                    expr_pool.register(agg.child.value().copy())
                )
            check_declared_type(func, data.output_schema, nk + i, label)
            self._funcs.append(func)
            self._labels.append(label^)
        self._schema = data.output_schema.copy()
        self._exprs = ArcPointer[ExprPool](expr_pool^)
        self._pool = pool^
        self._slots = List[ArcPointer[_GroupSlot]]()
        self._merge_reservation = WorkerReservation(self._pool.share())
        self._merged = GroupTable(nk, na)
        self._merged_arrows = List[ArrowType]()
        for _ in range(nk):
            self._merged_arrows.append(ArrowType.NULL)
        self._combined = False

    def _denied(self, bytes: Int) -> Error:
        return Error(
            "komira_pipeline_exec: the grouped aggregation sink of segment "
            + String(self._seg_id)
            + " was denied "
            + String(bytes)
            + " bytes of the segment's memory pool for its group table"
            " (budget "
            + String(self._pool.budget())
            + ", granted "
            + String(self._pool.granted())
            + ")"
        )

    def resize_worker_state(mut self, num_workers: Int) -> None:
        self._slots = List[ArcPointer[_GroupSlot]](capacity=num_workers)
        for _ in range(num_workers):
            self._slots.append(
                ArcPointer[_GroupSlot](
                    _GroupSlot(
                        self._nk,
                        len(self._funcs),
                        WorkerReservation(self._pool.share()),
                    )
                )
            )

    def consume(self, worker_id: Int, var morsel: Morsel) raises:
        if worker_id < 0 or worker_id >= len(self._slots):
            raise Error(
                "komira_pipeline_exec: the grouped aggregation sink holds "
                + String(len(self._slots))
                + " worker slots, got worker "
                + String(worker_id)
            )
        ref slot = self._slots[worker_id][]
        if not slot.started:
            slot.map = Optional(
                MapOp(
                    self._expr_ids.copy(),
                    self._names.copy(),
                    ArcPointer(copy=self._exprs),
                )
            )
            slot.started = True
        var selected = morsel.num_rows()
        if morsel.batch.has_selection_mask():
            selected = morsel.batch.selection_mask_true_count()
        if selected == 0:
            return
        _ = slot.map.value().execute(morsel)
        var dense = materialize_selection_if_present(morsel^.take_batch())
        var nk = self._nk
        var na = len(self._funcs)
        var keys = List[KeyColumn]()
        for k in range(nk):
            var kc = read_key_column(
                dense, k, selected, self._floats, self._key_labels[k]
            )
            if slot.key_arrows[k] == ArrowType.NULL:
                slot.key_arrows[k] = kc.arrow
            elif slot.key_arrows[k] != kc.arrow:
                raise Error(
                    "komira_pipeline_exec: "
                    + self._key_labels[k]
                    + " saw a column of another type than the morsels before"
                    " it"
                )
            keys.append(kc^)
        var args = List[WideColumn]()
        for i in range(na):
            if self._arg_col[i] < 0:
                args.append(WideColumn())
            else:
                args.append(
                    widen_column(
                        self._funcs[i],
                        dense,
                        self._arg_col[i],
                        selected,
                        self._labels[i],
                    )
                )
        for r in range(selected):
            for k in range(nk):
                if len(keys[k].null) > 0 and keys[k].null[r] != 0:
                    slot.scratch_nulls[k] = 1
                    slot.scratch_cells[k] = 0
                else:
                    slot.scratch_nulls[k] = 0
                    slot.scratch_cells[k] = keys[k].cells[r]
            var h = hash_key(slot.scratch_cells, slot.scratch_nulls)
            var g = slot.table.find_or_insert(
                h, slot.scratch_cells, slot.scratch_nulls, slot.reservation
            )
            if g < 0:
                raise self._denied(slot.table.denied_bytes)
            for i in range(na):
                if self._arg_col[i] < 0:
                    slot.table.cells[g * na + i].count += 1
                else:
                    fold_wide(
                        slot.table.cells[g * na + i],
                        self._funcs[i],
                        args[i],
                        r,
                        self._labels[i],
                    )

    def combine(mut self, mut pipeline: PipelineExecution) raises -> None:
        var nk = self._nk
        var na = len(self._funcs)
        var scratch_cells = List[Int64]()
        var scratch_nulls = List[UInt8]()
        for _ in range(nk):
            scratch_cells.append(0)
            scratch_nulls.append(0)
        for w in range(len(self._slots)):
            ref slot = self._slots[w][]
            for k in range(nk):
                var a = slot.key_arrows[k]
                if a == ArrowType.NULL:
                    continue
                if self._merged_arrows[k] == ArrowType.NULL:
                    self._merged_arrows[k] = a
                elif self._merged_arrows[k] != a:
                    raise Error(
                        "komira_pipeline_exec: "
                        + self._key_labels[k]
                        + " saw columns of different types on different"
                        " workers"
                    )
            ref t = slot.table
            for g in range(t.n):
                for k in range(nk):
                    scratch_cells[k] = t.keys[g * nk + k]
                    scratch_nulls[k] = t.nulls[g * nk + k]
                var mg = self._merged.find_or_insert(
                    t.hashes[g],
                    scratch_cells,
                    scratch_nulls,
                    self._merge_reservation,
                )
                if mg < 0:
                    raise self._denied(self._merged.denied_bytes)
                for i in range(na):
                    merge_cell(
                        self._merged.cells[mg * na + i],
                        t.cells[g * na + i],
                        self._funcs[i],
                        self._labels[i],
                    )
            # This worker is merged: free its table and return its memory.
            slot.table = GroupTable(nk, na)
            slot.reservation.give_back_all()
        self._combined = True

    def finalize(mut self) raises:
        pass

    def take_output(mut self) raises -> RecordBatch:
        if not self._combined:
            raise Error(
                "komira_pipeline_exec: the grouped aggregation sink was read"
                " before it was combined"
            )
        var n = self._merged.n
        var nk = self._nk
        var na = len(self._funcs)
        if n == 0:
            self._merge_reservation.give_back_all()
            return empty_batch_like_schema(self._schema)
        var builder = RecordBatchBuilder()
        for k in range(nk):
            var t = self._schema.field_arrow_type(k)
            if self._merged_arrows[k] != t:
                raise Error(
                    "komira_pipeline_exec: "
                    + self._key_labels[k]
                    + " over a column of type "
                    + String(self._merged_arrows[k])
                    + " cannot fill the declared output type "
                    + String(t)
                    + " of column "
                    + String(k)
                )
            builder.add_column(
                key_output_column(
                    self._merged.keys, self._merged.nulls, nk, k, n, t
                )
            )
        for i in range(na):
            builder.add_column(
                agg_result_column_rows(
                    self._funcs[i],
                    self._merged.cells,
                    i,
                    na,
                    n,
                    self._schema,
                    nk + i,
                    self._labels[i],
                )
            )
        var out = builder.build(self._schema.copy())
        self._merged = GroupTable(nk, na)
        self._merge_reservation.give_back_all()
        return out^
