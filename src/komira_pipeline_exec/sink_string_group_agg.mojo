# =============================================================================
# sink_string_group_agg -- (SINK_AGG, KEY_DTYPE_STRING, DICT_ENCODED | COLUMNAR)
# =============================================================================
#
# The grouped aggregation sink over string keys: GROUP BY one or more STRING
# columns, with SUM, COUNT, COUNT(*), MIN, MAX and AVG exactly as the fixed-width
# sink (`sink_group_agg`) serves them: the same `GroupTable`, the same exact
# folds (`agg_fold`), the same merge rule, the same refusals and the same
# charging of the segment pool. What differs is the key.
#
# A worker keeps an `InternTable` (`string_keys`) beside its `GroupTable`: each
# distinct key string is stored once with its content hash, and the group table
# is keyed by the string's id in that table, one 64-bit cell per key column. A
# group's hash is a mix of the content hashes of its key strings, so it is the
# same in every worker. The two rows differ in how a dictionary column reaches
# the intern table:
#
#   DICT_ENCODED   a dictionary column is interned by code: a code is hashed,
#                  probed and byte compared once per morsel however many rows
#                  carry it.
#   COLUMNAR       every row's string is hashed and interned, whatever the
#                  column's encoding.
#
# Either row accepts a flat STRING column, which is interned per row, so a
# Parquet chunk that fell back to plain encoding gives the answer a dictionary
# chunk does. The planner picks DICT_ENCODED only when it can prove every row
# group of the scan is dictionary encoded; the sink does not need that proof
# for correctness, only for speed.
#
# A group exists when a selected row reached it. The sink's groups are the
# rows of its `GroupTable`; its intern table only names their strings. A
# string no selected row used is never interned (the sink interns a dictionary
# code on first use, not the whole dictionary), and was it interned it would
# still be no group.
#
# NULL is a key of its own (a flag, no id) and the empty string is a string:
# they are two groups.
#
# `combine` merges the workers' groups in worker order by VALUE. A worker's
# group holds ids of that worker's table, which mean nothing to another; the
# merge interns each such string (its carried hash and its bytes) into a merge
# table of its own, gets a merge id, and probes the merged `GroupTable` with
# the group's hash and the merge ids. The same string met as id 3 in one worker
# and 9 in another is one entry in the merge table and so one merged group. No
# string is re-hashed. The merge is serial, like slice 5's (D8's partitioned
# merge is slice 5b).
#
# Memory is charged to the segment pool before it is used (`group_table`,
# `string_keys`): each worker's group table and intern table to the worker's
# reservation, the merge's two tables to the sink's own. A denial fails the
# query by name. A worker's tables are freed and its reservation returned as
# soon as it is merged, and every reservation is returned when the sink is
# dropped, whether or not the query succeeded.
#
# Memory the pool does not see: the buffers of the morsel being folded (per
# key column 17 bytes a row, per aggregate argument 16 bytes and a flag a row,
# the projected batch, a flat STRING key column copied once, a dictionary's
# code-to-id array), freed when `consume` returns; the old arrays of a table
# while it doubles; the worker-to-merge id array of `combine` (4 bytes per
# entry of the worker); and the output batch.
#
# Refused when the sink is built: no group-by expression, an aggregate the sink
# does not serve, an aggregate without its argument, an output schema that does
# not list the keys and aggregates, and a declared key column that is not
# STRING (a key of a fixed-width type beside a string key is not served: the
# rows of `komira_lowering` never ask for one). Refused when rows arrive: a key
# column that is neither STRING nor a string DICTIONARY, a dictionary code
# outside its dictionary.

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

from .agg_fold import WideColumn, agg_name, fold_wide, merge_cell, widen_column
from .agg_output import agg_result_column_rows, check_declared_type
from .group_table import GroupTable, MAX_GROUP_CAPACITY, mix64
from .segment_pool import SegmentPool, WorkerReservation
from .string_keys import (
    InternTable,
    MAX_INTERN_ENTRIES,
    STRING_KEY_SEED,
    StrKeyRows,
    read_string_keys,
    string_key_column,
)


struct _StringSlot(Movable):
    var table: GroupTable
    var intern: InternTable
    var map: Optional[MapOp]
    var reservation: WorkerReservation
    var scratch_cells: List[Int64]
    var scratch_nulls: List[UInt8]
    var started: Bool

    def __init__(
        out self,
        nk: Int,
        na: Int,
        max_groups: Int,
        max_strings: Int,
        var reservation: WorkerReservation,
    ):
        self.table = GroupTable(nk, na, max_groups)
        self.intern = InternTable(max_strings)
        self.map = None
        self.reservation = reservation^
        self.scratch_cells = List[Int64]()
        self.scratch_nulls = List[UInt8]()
        for _ in range(nk):
            self.scratch_cells.append(0)
            self.scratch_nulls.append(0)
        self.started = False


struct StringGroupAggSink(MorselSinkImpl):
    """Folds the morsels of a segment into one row of aggregates per group of
    string keys."""

    var _seg_id: Int
    var _by_code: Bool
    var _nk: Int
    var _max_groups: Int
    var _max_strings: Int
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
    # holds heap (the tables), so it is never kept in a Slab mutated through
    # get_mut_interior. A worker touches only the slot of its own task id.
    var _slots: List[ArcPointer[_StringSlot]]
    var _merge_reservation: WorkerReservation
    var _merge_intern: InternTable
    var _merged: GroupTable
    var _combined: Bool

    def __init__(
        out self,
        ref data: AggSinkData,
        by_code: Bool,
        var pool: SegmentPool,
        seg_id: Int,
        max_groups: Int = MAX_GROUP_CAPACITY,
        max_strings: Int = MAX_INTERN_ENTRIES,
    ) raises:
        var where_ = (
            "komira_pipeline_exec: the string-keyed aggregation sink of"
            " segment "
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
        self._by_code = by_code
        self._nk = nk
        self._max_groups = max_groups
        self._max_strings = max_strings
        self._funcs = List[UInt8]()
        self._arg_col = List[Int]()
        self._labels = List[String]()
        self._key_labels = List[String]()
        self._expr_ids = List[ExprId]()
        self._names = List[String]()
        var expr_pool = ExprPool()
        for k in range(nk):
            var t = data.output_schema.field_arrow_type(k)
            if t != ArrowType.STRING:
                raise Error(
                    where_
                    + " declares output column "
                    + String(k)
                    + " (a key) as "
                    + String(t)
                    + "; the string rows key STRING columns, and a key of"
                    " another type beside a string key is not served"
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
        self._slots = List[ArcPointer[_StringSlot]]()
        self._merge_reservation = WorkerReservation(self._pool.share())
        self._merge_intern = InternTable(max_strings)
        self._merged = GroupTable(nk, na, max_groups)
        self._combined = False

    def _refused(
        self, too_many: Bool, what: String, denied_bytes: Int
    ) -> Error:
        if too_many:
            return Error(
                "komira_pipeline_exec: the string-keyed aggregation sink of"
                " segment "
                + String(self._seg_id)
                + " has more "
                + what
                + " than it holds ("
                + String(self._max_groups)
                + " groups, "
                + String(self._max_strings)
                + " distinct strings, or a string over 2 GiB)"
            )
        return Error(
            "komira_pipeline_exec: the string-keyed aggregation sink of"
            " segment "
            + String(self._seg_id)
            + " was denied "
            + String(denied_bytes)
            + " bytes of the segment's memory pool for its "
            + what
            + " (budget "
            + String(self._pool.budget())
            + ", granted "
            + String(self._pool.granted())
            + ")"
        )

    def resize_worker_state(mut self, num_workers: Int) -> None:
        self._slots = List[ArcPointer[_StringSlot]](capacity=num_workers)
        for _ in range(num_workers):
            self._slots.append(
                ArcPointer[_StringSlot](
                    _StringSlot(
                        self._nk,
                        len(self._funcs),
                        self._max_groups,
                        self._max_strings,
                        WorkerReservation(self._pool.share()),
                    )
                )
            )

    def consume(self, worker_id: Int, var morsel: Morsel) raises:
        if worker_id < 0 or worker_id >= len(self._slots):
            raise Error(
                "komira_pipeline_exec: the string-keyed aggregation sink"
                " holds "
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
        var keys = List[StrKeyRows]()
        for k in range(nk):
            var rows = StrKeyRows()
            if not read_string_keys(
                rows,
                dense,
                k,
                selected,
                self._by_code,
                self._key_labels[k],
                slot.intern,
                slot.reservation,
            ):
                raise self._refused(
                    slot.intern.too_many,
                    "distinct key strings",
                    slot.intern.denied_bytes,
                )
            keys.append(rows^)
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
            var h = STRING_KEY_SEED
            for k in range(nk):
                if keys[k].null[r] != 0:
                    slot.scratch_nulls[k] = 1
                    slot.scratch_cells[k] = 0
                else:
                    slot.scratch_nulls[k] = 0
                    slot.scratch_cells[k] = keys[k].ids[r]
                h = mix64(h ^ keys[k].hashes[r])
            var g = slot.table.find_or_insert(
                h, slot.scratch_cells, slot.scratch_nulls, slot.reservation
            )
            if g < 0:
                raise self._refused(
                    slot.table.too_many,
                    "groups",
                    slot.table.denied_bytes,
                )
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
            ref t = slot.table
            # The merge id of each string of this worker, -1 until a group
            # uses it.
            var remap = List[Int32](length=slot.intern.n, fill=-1)
            for g in range(t.n):
                for k in range(nk):
                    if t.nulls[g * nk + k] != 0:
                        scratch_nulls[k] = 1
                        scratch_cells[k] = 0
                        continue
                    scratch_nulls[k] = 0
                    var id = Int(t.keys[g * nk + k])
                    var mid = Int(remap[id])
                    if mid < 0:
                        mid = self._merge_intern.intern(
                            slot.intern.value(id),
                            slot.intern.hashes[id],
                            self._merge_reservation,
                        )
                        if mid < 0:
                            raise self._refused(
                                self._merge_intern.too_many,
                                "distinct key strings",
                                self._merge_intern.denied_bytes,
                            )
                        remap[id] = Int32(mid)
                    scratch_cells[k] = Int64(mid)
                var mg = self._merged.find_or_insert(
                    t.hashes[g],
                    scratch_cells,
                    scratch_nulls,
                    self._merge_reservation,
                )
                if mg < 0:
                    raise self._refused(
                        self._merged.too_many,
                        "groups",
                        self._merged.denied_bytes,
                    )
                for i in range(na):
                    merge_cell(
                        self._merged.cells[mg * na + i],
                        t.cells[g * na + i],
                        self._funcs[i],
                        self._labels[i],
                    )
            # This worker is merged: free its tables and return its memory.
            slot.table = GroupTable(nk, na, self._max_groups)
            slot.intern = InternTable(self._max_strings)
            slot.reservation.give_back_all()
        self._combined = True

    def finalize(mut self) raises:
        pass

    def take_output(mut self) raises -> RecordBatch:
        if not self._combined:
            raise Error(
                "komira_pipeline_exec: the string-keyed aggregation sink was"
                " read before it was combined"
            )
        var n = self._merged.n
        var nk = self._nk
        var na = len(self._funcs)
        if n == 0:
            self._merge_reservation.give_back_all()
            return empty_batch_like_schema(self._schema)
        var builder = RecordBatchBuilder()
        for k in range(nk):
            builder.add_column(
                string_key_column(
                    self._merge_intern,
                    self._merged.keys,
                    self._merged.nulls,
                    nk,
                    k,
                    n,
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
        self._merged = GroupTable(nk, na, self._max_groups)
        self._merge_intern = InternTable(self._max_strings)
        self._merge_reservation.give_back_all()
        return out^
