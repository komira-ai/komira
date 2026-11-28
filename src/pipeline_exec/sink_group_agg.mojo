# =============================================================================
# sink_group_agg -- (SINK_AGG, KEY_DTYPE_I64 | I32 | F64 | F32 | DATE32 | BOOL
#                   | DECIMAL128, COLUMNAR)
# =============================================================================
#
# The grouped aggregation sink over fixed-width keys: GROUP BY one or more
# integer columns (rows I64 and I32), float columns (rows F64 and F32), DATE32
# columns (row DATE32), BOOL columns (row BOOL) or DECIMAL128 columns (row
# DECIMAL128), with SUM, COUNT, COUNT(*), COUNT(DISTINCT), MIN, MAX, AVG,
# STDDEV_SAMP, STDDEV_POP, VAR_SAMP, VAR_POP, MEDIAN and QUANTILE_CONT, the
# aggregates and their folds being those of the ungrouped sink (`agg_fold`,
# `count_distinct`, `agg_values`: a MEDIAN's values are kept per worker group
# and moved under the merged group at `combine`, as COUNT(DISTINCT)'s are). A key column takes one 64-bit cell of the
# group key, a DECIMAL128 column two (`group_keys`). With no aggregate the
# output is one row per distinct key, which is how `lowering` cuts SELECT
# DISTINCT.
#
# The plan's group-by expressions and aggregate arguments are registered once
# and run by each worker as one projection (`MapOp`) over every morsel, under
# the morsel's selection mask. The projection's first columns are the keys, the
# rest the arguments. The output schema lists the key columns, then one column
# per aggregate; a key column is declared in the type of its input column.
#
# Each worker folds its rows into a `GroupTable` of its own slot (`group_table`;
# key cells in `group_keys`). A NULL key is a group of its own; equal floats,
# every NaN, and 0.0 with -0.0, are one group; decimals of one column are
# equal when their unscaled values are, the scale being the declared one.
# `combine`, which runs once after the workers joined, merges the tables into
# one in worker order with `merge_cell`, so the exact-overflow rule of the
# ungrouped sink holds per group, and a sum that overflows only when the
# workers' partials are added is refused there. A COUNT(DISTINCT) keeps a
# worker's (group, value) entries apart from the cells; `combine` moves them
# under the merged group of their worker group, and an entry new there adds one
# to the group's count. The order of the output groups is unspecified: a plan
# that needs an order sorts.
#
# A FLOAT32 or FLOAT64 argument folds as in the ungrouped sink: SUM and AVG a
# double sum from +0.0, MIN and MAX in DuckDB's order of floats (`agg_fold`).
# Merged in worker order, a group's float SUM or AVG depends in its last bits
# on which worker took which morsel. By position (the segment is
# ORDER_ROW_RANGE, `by_position`; `lowering` cuts a grouped float SUM or AVG
# so) each worker folds its float SUM, AVG, MIN and MAX per source position
# and group instead (`group_positions`), and `combine` merges those cells into
# the merged groups in source position order, so a group's answer is the same
# bits on every worker count and schedule. The other aggregates fold into the
# worker's table as above.
#
# Memory is charged as the tables grow, not once: every doubling of a table's
# capacity is charged to the worker's reservation before it is made
# (`segment_pool`), and the merged table is charged to the sink's own
# reservation. A denial fails the query by name, unless the sink spills
# (below). A worker's table is freed and
# its reservation returned as soon as it is merged, and every reservation is
# returned when the sink is dropped, whether or not the query succeeded.
#
# Memory the pool does not see, and its bound. The pool is charged for the
# tables. Not charged: the buffers of the morsel being folded (each key column
# as 8 bytes and a flag per row, each aggregate argument as 16 bytes and a flag
# per row, plus the projected batch), freed when `consume` returns; and the old
# arrays of a table while it doubles, which live beside the new ones until the
# copy is done (half the charged bytes of that table at most). So a worker
# holds at most its charge plus 1.5 times the doubling table plus
# rows x (9 x key cells + 17 x aggregate arguments) bytes of one morsel.
#
# Spill. A sink given a spill directory (`spill_dir`, from the builder: the
# engine's caller passes it as a flag; empty means none) does not refuse a
# table that cannot grow. The worker whose table step the pool denies writes
# its whole table to disk (`group_spill`: one chunk per hash partition of the
# groups), returns the table's memory and folds on into a new, empty table. It
# still refuses, by name, when even the first step of that new table is denied,
# and when its table was empty (nothing to write).
#
# With a spill directory, `combine` builds the result one partition of
# `SPILL_PARTITIONS` at a time: it merges the partition's groups from every
# worker's table and from every chunk written for it into a table of that
# partition alone (charged to the pool), turns that table into a batch of
# output rows (the batch is charged and kept until `take_output`, the table
# freed) and moves to the next partition. So the merge holds the groups of one
# partition at a time, not all of them. When the pool denies the merge of a
# partition, the workers' tables still in memory are written to disk (the
# partitions not merged yet), freed with their reservations, and the partition
# is merged again from disk; a denial with no table left to write is refused
# by name. The integer folds are exact and merge in any order to the same
# cell, as do float MIN and MAX up to which of -0.0 and 0.0 is kept, so the
# rows are the rows without a spill (their order is unspecified either way),
# a float SUM or AVG differing at most in the last bits, as between worker
# counts; and the overflow rule is the one above: a sum that leaves 128 bits
# only when partials are added is refused at that add.
#
# Not charged to the pool: writing a chunk builds its batch and its encoding,
# and reading one back the bytes read and the decoded batch, each at most
# twice the bytes of the groups of one partition of one table; both are freed
# before the next chunk. The spill files are deleted when `combine` is done,
# or when the sink is dropped. A sink with a COUNT(DISTINCT), MEDIAN or
# QUANTILE_CONT aggregate does not spill (its per-group values are kept apart
# from the table), nor does
# a sink that folds by position (its grains name the groups of the worker's
# table): either refuses as without a spill directory and says why.
#
# Refused when the sink is built: no group-by expression, an aggregate the
# sink does not serve, an aggregate without its argument, an output schema
# that does not list the keys and aggregates, and a declared key column of a
# type the row does not key. Refused when rows arrive: a key column of a type
# the row does not key, or a type that changes between morsels, and a decimal
# key column whose scale is not the declared one or whose precision is wider;
# at `combine`, a declared key type that is not the input's.

from std.builtin.swap import swap
from std.memory import ArcPointer

from arrow.arrow_types import ArrowType
from arrow.concat import concat_record_batches_nway
from arrow.schema import RecordBatch, RecordBatchBuilder, Schema
from containers.slab import Slab
from column_kernels.compiler_helpers import (
    batch_buffer_bytes,
    empty_batch_like_schema,
    materialize_selection_if_present,
)
from morsel.morsel import Morsel
from morsel.morsel_sink import MorselSinkImpl
from morsel.pipeline_execution import PipelineExecution
from operator_api.map_op import MapOp
from physical_plan.physical_plan import AggSinkData
from plan_expr.agg_expr import AGG_COUNT_DISTINCT
from plan_expr.expr_id import ExprId
from plan_expr.expr_pool import ExprPool

from .agg_fold import (
    AggCell,
    WideColumn,
    agg_name,
    fold_wide,
    keeps_values,
    merge_cell,
    widen_column,
)
from .agg_values import (
    ValueMerge,
    ValueSlot,
    check_agg_args,
    keep_wide,
    reserve_wide,
)
from .agg_output import agg_result_column_rows, check_declared_type
from .count_distinct import (
    DistinctColumn,
    DistinctMerge,
    DistinctSlot,
    admit_distinct,
    read_distinct_column,
)
from .group_positions import GroupPositions, merge_positions
from .group_keys import (
    KeyColumn,
    key_output_column,
    key_width,
    read_key_column,
    row_keys_type,
)
from .group_spill import GroupSpill, SPILL_PARTITIONS, spill_partition
from .group_table import GroupTable, MAX_GROUP_CAPACITY, hash_key
from .segment_pool import MEMORY_BUDGET_EXCEEDED, SegmentPool, WorkerReservation


struct _GroupSlot(Movable):
    var table: GroupTable
    var map: Optional[MapOp]
    var reservation: WorkerReservation
    var distinct: DistinctSlot
    var values: ValueSlot
    var key_arrows: List[ArrowType]
    var scratch_cells: List[Int64]
    var scratch_nulls: List[UInt8]
    var started: Bool
    var spill: GroupSpill
    var positions: GroupPositions

    def __init__(
        out self,
        nk: Int,
        nc: Int,
        na: Int,
        max_groups: Int,
        var reservation: WorkerReservation,
        var position_reservation: WorkerReservation,
        spill_dir: String,
    ):
        self.table = GroupTable(nc, na, max_groups)
        self.positions = GroupPositions(position_reservation^)
        self.spill = GroupSpill(spill_dir, nc, na)
        self.map = None
        self.reservation = reservation^
        self.distinct = DistinctSlot(na)
        self.values = ValueSlot(na)
        self.key_arrows = List[ArrowType]()
        self.scratch_cells = List[Int64]()
        self.scratch_nulls = List[UInt8]()
        for _ in range(nk):
            self.key_arrows.append(ArrowType.NULL)
        for _ in range(nc):
            self.scratch_cells.append(0)
            self.scratch_nulls.append(0)
        self.started = False


struct GroupAggSink(MorselSinkImpl):
    """Folds the morsels of a segment into one row of aggregates per group."""

    var _seg_id: Int
    var _key_dtype: UInt8
    var _where: String
    var _nk: Int
    # The key cells of a group: one per key column, two per DECIMAL128 key
    # column; `_cell_at[k]` is the first cell of key column `k`.
    var _nc: Int
    var _cell_at: List[Int]
    var _max_groups: Int
    var _funcs: List[UInt8]
    # The fraction of each MEDIAN or QUANTILE_CONT (0.0 for the others).
    var _fractions: List[Float64]
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
    # The spill directory ("" when the sink does not spill) and, when one was
    # given but the sink cannot use it, why (else "").
    var _spill_dir: String
    var _spill_off: String
    # The output rows of a partitioned combine, one batch per partition with
    # groups, charged to `_merge_reservation`.
    var _parts: List[RecordBatch]
    var _partitioned: Bool
    # What the pool last denied a partitioned combine, for its refusal.
    var _denied_bytes: Int
    var _denied_what: String
    # Fold the float aggregates by source position (ORDER_ROW_RANGE).
    var _by_position: Bool

    def __init__(
        out self,
        ref data: AggSinkData,
        key_dtype: UInt8,
        var pool: SegmentPool,
        seg_id: Int,
        max_groups: Int = MAX_GROUP_CAPACITY,
        spill_dir: String = "",
        by_position: Bool = False,
    ) raises:
        var where_ = (
            "pipeline_exec: the grouped aggregation sink of segment "
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
        self._key_dtype = key_dtype
        self._where = where_
        self._nk = nk
        self._nc = 0
        self._cell_at = List[Int]()
        self._max_groups = max_groups
        self._funcs = List[UInt8]()
        self._fractions = List[Float64]()
        self._arg_col = List[Int]()
        self._labels = List[String]()
        self._key_labels = List[String]()
        self._expr_ids = List[ExprId]()
        self._names = List[String]()
        var expr_pool = ExprPool()
        for k in range(nk):
            var t = data.output_schema.field_arrow_type(k)
            if not row_keys_type(key_dtype, t):
                raise Error(
                    where_
                    + " declares output column "
                    + String(k)
                    + " (a key) as "
                    + String(t)
                    + ", which its row does not key"
                )
            self._cell_at.append(self._nc)
            self._nc += key_width(t)
            self._key_labels.append("group key " + String(k))
            self._names.append("group_key_" + String(k))
            self._expr_ids.append(
                expr_pool.register(data.group_by_exprs[k].copy())
            )
        for i in range(na):
            ref agg = data.agg_exprs[i]
            var func = agg.func
            var label = (
                agg_name(func) + " (output column " + String(nk + i) + ")"
            )
            self._fractions.append(check_agg_args(agg, where_, label))
            if not agg.child:
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
        self._merged = GroupTable(self._nc, na, max_groups)
        self._merged_arrows = List[ArrowType]()
        for _ in range(nk):
            self._merged_arrows.append(ArrowType.NULL)
        self._combined = False
        self._by_position = by_position
        self._spill_dir = String("")
        self._spill_off = String("")
        if spill_dir != "":
            for i in range(na):
                if self._funcs[i] == AGG_COUNT_DISTINCT:
                    self._spill_off = (
                        "a COUNT(DISTINCT) aggregate does not spill"
                    )
                elif keeps_values(self._funcs[i]):
                    self._spill_off = (
                        "a MEDIAN or QUANTILE_CONT aggregate does not spill"
                    )
            if self._spill_off == "" and by_position:
                self._spill_off = (
                    "a sink that folds its float aggregates by source"
                    " position does not spill"
                )
            if self._spill_off == "":
                self._spill_dir = spill_dir
        self._parts = List[RecordBatch]()
        self._partitioned = False
        self._denied_bytes = 0
        self._denied_what = String("")

    def _refused(self, too_many: Bool, denied_bytes: Int) -> Error:
        if too_many:
            return Error(
                "pipeline_exec: the grouped aggregation sink of"
                " segment "
                + String(self._seg_id)
                + " has more groups than a group table holds ("
                + String(self._max_groups)
                + ")"
            )
        return self._denied(denied_bytes)

    def _denied(self, bytes: Int, what: String = "its group table") -> Error:
        var tail = String("")
        if self._spill_off != "":
            tail = "; a spill directory is set, and " + self._spill_off
        return Error(
            String(MEMORY_BUDGET_EXCEEDED)
            + ": pipeline_exec: the grouped aggregation sink of segment "
            + String(self._seg_id)
            + " was denied "
            + String(bytes)
            + " bytes of the segment's memory pool for "
            + what
            + " (budget "
            + String(self._pool.budget())
            + ", granted "
            + String(self._pool.granted())
            + ")"
            + tail
        )

    def resize_worker_state(mut self, num_workers: Int) -> None:
        self._slots = List[ArcPointer[_GroupSlot]](capacity=num_workers)
        for _ in range(num_workers):
            self._slots.append(
                ArcPointer[_GroupSlot](
                    _GroupSlot(
                        self._nk,
                        self._nc,
                        len(self._funcs),
                        self._max_groups,
                        WorkerReservation(self._pool.share()),
                        WorkerReservation(self._pool.share()),
                        self._spill_dir,
                    )
                )
            )

    def consume(self, worker_id: Int, var morsel: Morsel) raises:
        if worker_id < 0 or worker_id >= len(self._slots):
            raise Error(
                "pipeline_exec: the grouped aggregation sink holds "
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
        var partition_id = morsel.partition_id
        var origin_hint = morsel.origin_hint
        _ = slot.map.value().execute(morsel)
        var dense = materialize_selection_if_present(morsel^.take_batch())
        var nk = self._nk
        var na = len(self._funcs)
        var keys = List[KeyColumn]()
        for k in range(nk):
            var kc = read_key_column(
                dense,
                k,
                selected,
                self._key_dtype,
                self._schema,
                k,
                self._key_labels[k],
            )
            if slot.key_arrows[k] == ArrowType.NULL:
                slot.key_arrows[k] = kc.arrow
            elif slot.key_arrows[k] != kc.arrow:
                raise Error(
                    "pipeline_exec: "
                    + self._key_labels[k]
                    + " saw a column of another type than the morsels before"
                    " it"
                )
            keys.append(kc^)
        var args = List[WideColumn]()
        var distinct_args = List[DistinctColumn]()
        for i in range(na):
            if self._funcs[i] == AGG_COUNT_DISTINCT:
                args.append(WideColumn())
                distinct_args.append(
                    read_distinct_column(
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
                )
                continue
            distinct_args.append(DistinctColumn())
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
                if keeps_values(self._funcs[i]):
                    reserve_wide(
                        slot.reservation,
                        args[i],
                        selected,
                        self._where,
                        self._pool,
                    )
        if self._by_position:
            if not slot.positions.begin(
                self._funcs, args, self._labels, partition_id, origin_hint
            ):
                raise self._denied(
                    slot.positions.denied_bytes,
                    "its float folds by source position",
                )
        for r in range(selected):
            for k in range(nk):
                var at = self._cell_at[k]
                var w = keys[k].width
                var null: UInt8 = 0
                if len(keys[k].null) > 0 and keys[k].null[r] != 0:
                    null = 1
                for j in range(w):
                    slot.scratch_nulls[at + j] = null
                    slot.scratch_cells[at + j] = (
                        Int64(0) if null != 0 else keys[k].cells[r * w + j]
                    )
            var h = hash_key(slot.scratch_cells, slot.scratch_nulls)
            var g = slot.table.find_or_insert(
                h, slot.scratch_cells, slot.scratch_nulls, slot.reservation
            )
            if (
                g < 0
                and self._spill_dir != ""
                and not slot.table.too_many
                and slot.table.n > 0
            ):
                # Write the table to disk, return its memory and fold on into
                # an empty table; the groups meet again in `combine`.
                slot.spill.spill_table(slot.table, 0)
                slot.table = GroupTable(self._nc, na, self._max_groups)
                slot.reservation.give_back_all()
                g = slot.table.find_or_insert(
                    h, slot.scratch_cells, slot.scratch_nulls, slot.reservation
                )
            if g < 0:
                raise self._refused(
                    slot.table.too_many, slot.table.denied_bytes
                )
            # The first of the group's cells in this morsel's grain, when the
            # sink folds floats by position.
            var base = -1
            if slot.positions.np > 0:
                base = slot.positions.row_for(g)
                if base < 0:
                    raise self._denied(
                        slot.positions.denied_bytes,
                        "its float folds by source position",
                    )
            for i in range(na):
                if base >= 0 and slot.positions.slot_of[i] >= 0:
                    slot.positions.fold(base, i, self._funcs[i], args[i], r)
                elif self._funcs[i] == AGG_COUNT_DISTINCT:
                    admit_distinct(
                        slot.distinct,
                        i,
                        g,
                        distinct_args[i],
                        r,
                        self._where,
                        self._pool,
                        slot.reservation,
                    )
                elif self._arg_col[i] < 0:
                    slot.table.cells[g * na + i].count += 1
                else:
                    fold_wide(
                        slot.table.cells[g * na + i],
                        self._funcs[i],
                        args[i],
                        r,
                        self._labels[i],
                    )
                    if keeps_values(self._funcs[i]):
                        keep_wide(slot.values, i, g, args[i], r)

    def _merge_key_types(mut self, w: Int) raises:
        """Fold worker `w`'s key column types into the merged ones; refuse a
        key whose type differs between workers."""
        ref slot = self._slots[w][]
        for k in range(self._nk):
            var a = slot.key_arrows[k]
            if a == ArrowType.NULL:
                continue
            if self._merged_arrows[k] == ArrowType.NULL:
                self._merged_arrows[k] = a
            elif self._merged_arrows[k] != a:
                raise Error(
                    "pipeline_exec: "
                    + self._key_labels[k]
                    + " saw columns of different types on different"
                    " workers"
                )

    def _merge_group(
        self,
        mut into: GroupTable,
        mut res: WorkerReservation,
        h: UInt64,
        ref keys: List[Int64],
        ref nulls: List[UInt8],
        ref cells: List[AggCell],
        g: Int,
        mut scratch_cells: List[Int64],
        mut scratch_nulls: List[UInt8],
    ) raises -> Bool:
        """Merge group `g` of the lists (`keys`, `nulls`, `cells`, laid out
        as a `GroupTable` holds them) into `into`. False, with nothing
        merged, when the pool denies `into` a step (`into.denied_bytes`);
        a table past its group limit is refused by name."""
        var nc = self._nc
        var na = len(self._funcs)
        for c in range(nc):
            scratch_cells[c] = keys[g * nc + c]
            scratch_nulls[c] = nulls[g * nc + c]
        var mg = into.find_or_insert(h, scratch_cells, scratch_nulls, res)
        if mg < 0:
            if into.too_many:
                raise self._refused(True, 0)
            return False
        for i in range(na):
            merge_cell(
                into.cells[mg * na + i],
                cells[g * na + i],
                self._funcs[i],
                self._labels[i],
            )
        return True

    def _merge_partition(
        mut self,
        p: Int,
        mut scratch_cells: List[Int64],
        mut scratch_nulls: List[UInt8],
    ) raises -> Bool:
        """Merge spill partition `p` from the workers' tables and chunks and
        keep its output rows. False, with nothing kept and `_denied_bytes`
        and `_denied_what` saying what was refused, when the pool denies a
        draw; the partition's table and reservation are freed either way."""
        var nc = self._nc
        var na = len(self._funcs)
        var part = GroupTable(nc, na, self._max_groups)
        var res = WorkerReservation(self._pool.share())
        for w in range(len(self._slots)):
            # A handle of our own on the slot, so the table read below is
            # not a borrow of `self` while `self` is called and assigned.
            var slot = ArcPointer(copy=self._slots[w])
            ref t = slot[].table
            for g in range(t.n):
                if spill_partition(t.hashes[g]) != p:
                    continue
                if not self._merge_group(
                    part,
                    res,
                    t.hashes[g],
                    t.keys,
                    t.nulls,
                    t.cells,
                    g,
                    scratch_cells,
                    scratch_nulls,
                ):
                    self._denied_bytes = part.denied_bytes
                    self._denied_what = String("its group table")
                    return False
        for w in range(len(self._slots)):
            var slot = ArcPointer(copy=self._slots[w])
            ref spill = slot[].spill
            for r in range(len(spill.runs)):
                if spill.runs[r].partition != p:
                    continue
                var groups = spill.read(spill.runs[r])
                for g in range(groups.n):
                    if not self._merge_group(
                        part,
                        res,
                        groups.hashes[g],
                        groups.keys,
                        groups.nulls,
                        groups.cells,
                        g,
                        scratch_cells,
                        scratch_nulls,
                    ):
                        self._denied_bytes = part.denied_bytes
                        self._denied_what = String("its group table")
                        return False
        if part.n > 0:
            var out = self._output_batch(part)
            var out_bytes = batch_buffer_bytes(out)
            if not self._merge_reservation.try_grow(out_bytes):
                self._denied_bytes = out_bytes
                self._denied_what = String(
                    "the output rows of a spill partition"
                )
                return False
            self._parts.append(out^)
        res.give_back_all()
        return True

    def _tables_hold_groups(self) -> Bool:
        for w in range(len(self._slots)):
            if self._slots[w][].table.n > 0:
                return True
        return False

    def _spill_tables(mut self, first_partition: Int) raises:
        """Write the partitions from `first_partition` on of every worker's
        table to disk, then free the tables and return their memory."""
        for w in range(len(self._slots)):
            ref slot = self._slots[w][]
            if slot.table.n == 0:
                continue
            slot.spill.spill_table(slot.table, first_partition)
            slot.table = GroupTable(
                self._nc, len(self._funcs), self._max_groups
            )
            slot.reservation.give_back_all()

    def _combine_partitioned(mut self) raises:
        """Build the output one spill partition at a time (the header's
        Spill paragraph)."""
        var nc = self._nc
        var na = len(self._funcs)
        var scratch_cells = List[Int64]()
        var scratch_nulls = List[UInt8]()
        for _ in range(nc):
            scratch_cells.append(0)
            scratch_nulls.append(0)
        for w in range(len(self._slots)):
            self._merge_key_types(w)
        var p = 0
        while p < SPILL_PARTITIONS:
            if self._merge_partition(p, scratch_cells, scratch_nulls):
                p += 1
                continue
            # Denied: once the workers' tables are on disk there is nothing
            # left to free, and the refusal stands.
            if not self._tables_hold_groups():
                raise self._denied(self._denied_bytes, self._denied_what)
            self._spill_tables(p)
        # Every partition is merged: free the workers' tables, return their
        # memory and delete their spill files.
        for w in range(len(self._slots)):
            ref slot = self._slots[w][]
            slot.table = GroupTable(nc, na, self._max_groups)
            slot.reservation.give_back_all()
            slot.spill.cleanup()
        self._partitioned = True
        self._combined = True

    def combine(mut self, mut pipeline: PipelineExecution) raises -> None:
        if self._spill_dir != "":
            self._combine_partitioned()
            return
        var nc = self._nc
        var na = len(self._funcs)
        var scratch_cells = List[Int64]()
        var scratch_nulls = List[UInt8]()
        for _ in range(nc):
            scratch_cells.append(0)
            scratch_nulls.append(0)
        var distinct = DistinctMerge(na, WorkerReservation(self._pool.share()))
        var values = ValueMerge(na, WorkerReservation(self._pool.share()))
        # By position: each worker's grains and the merged group of each of
        # its groups, merged after every worker's table.
        var positions = List[GroupPositions]()
        var group_maps = List[List[Int]]()
        for w in range(len(self._slots)):
            self._merge_key_types(w)
            ref slot = self._slots[w][]
            ref t = slot.table
            # The merged group of each of this worker's groups.
            var group_map = List[Int](capacity=t.n)
            for g in range(t.n):
                for c in range(nc):
                    scratch_cells[c] = t.keys[g * nc + c]
                    scratch_nulls[c] = t.nulls[g * nc + c]
                var mg = self._merged.find_or_insert(
                    t.hashes[g],
                    scratch_cells,
                    scratch_nulls,
                    self._merge_reservation,
                )
                if mg < 0:
                    raise self._refused(
                        self._merged.too_many, self._merged.denied_bytes
                    )
                group_map.append(mg)
                for i in range(na):
                    merge_cell(
                        self._merged.cells[mg * na + i],
                        t.cells[g * na + i],
                        self._funcs[i],
                        self._labels[i],
                    )
            distinct.merge_worker(
                slot.distinct,
                group_map,
                self._merged.cells,
                na,
                self._where,
                self._labels,
                self._pool,
            )
            values.merge_worker(slot.values, group_map, self._where, self._pool)
            # This worker is merged: free its tables and return its memory.
            # Its grains move out with their own reservation.
            slot.table = GroupTable(nc, na, self._max_groups)
            slot.distinct = DistinctSlot(na)
            slot.values = ValueSlot(na)
            slot.reservation.give_back_all()
            if self._by_position:
                var moved = GroupPositions(WorkerReservation(self._pool.share()))
                swap(moved, slot.positions)
                positions.append(moved^)
                group_maps.append(group_map^)
        if self._by_position:
            merge_positions(
                positions,
                group_maps,
                self._merged.cells,
                self._funcs,
                self._labels,
                self._where,
            )
            for w in range(len(positions)):
                positions[w].reservation.give_back_all()
        distinct.finish()
        values.finish(
            self._merged.cells,
            self._funcs,
            self._fractions,
            self._merged.n,
            self._where,
            self._pool,
        )
        self._combined = True

    def finalize(mut self) raises:
        pass

    def take_output(mut self) raises -> RecordBatch:
        if not self._combined:
            raise Error(
                "pipeline_exec: the grouped aggregation sink was read"
                " before it was combined"
            )
        var na = len(self._funcs)
        if self._partitioned:
            var parts = Slab[RecordBatch]()
            while len(self._parts) > 0:
                parts.append(self._parts.pop())
            if len(parts) == 0:
                self._merge_reservation.give_back_all()
                return empty_batch_like_schema(self._schema)
            var joined = concat_record_batches_nway(parts^)
            self._merge_reservation.give_back_all()
            return joined^
        if self._merged.n == 0:
            self._merge_reservation.give_back_all()
            return empty_batch_like_schema(self._schema)
        # Take the merged table out of the sink (an empty one stays), so the
        # output is built from a value of our own and the table is freed after.
        var merged = GroupTable(self._nc, na, self._max_groups)
        swap(merged, self._merged)
        var out = self._output_batch(merged)
        _ = merged^
        self._merge_reservation.give_back_all()
        return out^

    def _output_batch(self, ref table: GroupTable) raises -> RecordBatch:
        """The output rows of the groups of `table`: the key columns, then
        one column per aggregate."""
        var n = table.n
        var nk = self._nk
        var na = len(self._funcs)
        var builder = RecordBatchBuilder()
        for k in range(nk):
            var t = self._schema.field_arrow_type(k)
            if self._merged_arrows[k] != t:
                raise Error(
                    "pipeline_exec: "
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
                    table.keys,
                    table.nulls,
                    self._nc,
                    self._cell_at[k],
                    n,
                    self._schema,
                    k,
                )
            )
        for i in range(na):
            builder.add_column(
                agg_result_column_rows(
                    self._funcs[i],
                    table.cells,
                    i,
                    na,
                    n,
                    self._schema,
                    nk + i,
                    self._labels[i],
                )
            )
        return builder.build(self._schema.copy())
