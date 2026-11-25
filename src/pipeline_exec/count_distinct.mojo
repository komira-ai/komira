# =============================================================================
# count_distinct -- the exact COUNT(DISTINCT x) of the aggregation sinks
# =============================================================================
#
# COUNT(DISTINCT x) is the number of distinct non-NULL values of x in a group.
# The three aggregation sinks (`sink_agg`, `sink_group_agg`,
# `sink_string_group_agg`) serve it beside their other aggregates with the
# state kept here, the way DuckDB keeps a distinct aggregate: a hash table of
# (aggregate, group, value) entries, one entry per distinct value a group saw.
#
# A worker's state is a `DistinctSlot`: one `GroupTable` (`group_table`, with
# no aggregate cells) whose key is four 64-bit cells,
#
#   [aggregate index, worker group index, value cell 0, value cell 1]
#
# and an `InternTable` (`string_keys`) for string values. A row whose value is
# NULL adds nothing: COUNT(DISTINCT) does not count NULL, so a group whose
# values are all NULL counts 0. The value cells are
#
#   INT8 .. INT64, DATE32   the value as a signed 64-bit integer, then 0
#   FLOAT32, FLOAT64        the value's bits as a FLOAT64 with every NaN one
#                           value and -0.0 equal to 0.0 (`group_keys.float_cell`,
#                           the rule the grouped sinks key floats by), then 0
#   DECIMAL128              the low and the high 64 bits of the unscaled value
#                           (one column has one scale)
#   STRING, DICTIONARY      the id of the string in the worker's intern table,
#                           then 0; a string dictionary is read by value (a
#                           numeric dictionary is refused)
#
# Any other argument type is refused by name, as is a column whose type changes
# between the morsels of one worker or between workers.
#
# `combine` (`DistinctMerge`) runs once after the workers joined. Each worker
# entry is moved into one merged table under the merged group index of its
# worker group (the caller's `group_map`, made as the sink merged the worker's
# groups) and, for a string, under the id of the string in the merge's own
# intern table, found by the hash and bytes the worker kept. An entry that is
# new in the merged table adds one to its group's count: two workers that saw
# the same value in the same group count it once. The count is the cell's
# `count`, which `agg_output` writes as COUNT's INT64. The merged table is
# freed when the merge ends; only the counts are kept.
#
# Memory is charged before it is used: a worker's table and intern table to
# the worker's reservation (which the sink returns once the worker is merged),
# the merge's two tables to a reservation of their own, returned at the end of
# the merge. A denial fails the query by name. A table holds at most
# `MAX_GROUP_CAPACITY` entries and refuses more by name. Not charged: the value
# cells of the morsel being read (17 bytes a row), freed when `consume` returns.

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.schema import RecordBatch
from byte_buffer.heap_region import HeapRegion

from .agg_fold import AggCell
from .group_keys import float_cell
from .group_table import GroupTable, MAX_GROUP_CAPACITY, hash_key
from .segment_pool import MEMORY_BUDGET_EXCEEDED, SegmentPool, WorkerReservation
from .string_keys import (
    InternTable,
    MAX_INTERN_ENTRIES,
    StrKeyRows,
    read_string_keys,
)

comptime _PAIR_CELLS: Int = 4


def is_distinct_value_type(t: ArrowType) -> Bool:
    """Whether COUNT(DISTINCT) serves an argument column of type `t`."""
    return (
        t == ArrowType.INT8
        or t == ArrowType.INT16
        or t == ArrowType.INT32
        or t == ArrowType.INT64
        or t == ArrowType.DATE32
        or t == ArrowType.FLOAT32
        or t == ArrowType.FLOAT64
        or t == ArrowType.DECIMAL128
        or t == ArrowType.STRING
        or t == ArrowType.DICTIONARY
    )


def _value_class(t: ArrowType) -> ArrowType:
    """The type a worker records for an argument column: a dictionary is read
    by value, so it is the same argument as a STRING column."""
    if t == ArrowType.DICTIONARY:
        return ArrowType.STRING
    return t


def distinct_denied(
    ref where_: String, bytes: Int, ref pool: SegmentPool
) -> Error:
    """The refusal of a sink whose COUNT(DISTINCT) state the pool denied."""
    return Error(
        String(MEMORY_BUDGET_EXCEEDED)
        + ": "
        + where_
        + " was denied "
        + String(bytes)
        + " bytes of the segment's memory pool for its COUNT(DISTINCT)"
        " values (budget "
        + String(pool.budget())
        + ", granted "
        + String(pool.granted())
        + ")"
    )


def distinct_too_many(ref where_: String, max_entries: Int) -> Error:
    """The refusal of a sink whose COUNT(DISTINCT) state is full."""
    return Error(
        where_
        + " has more COUNT(DISTINCT) values than it holds ("
        + String(max_entries)
        + " distinct values, distinct strings, or a string over 2 GiB)"
    )


struct DistinctColumn(Movable):
    """One COUNT(DISTINCT) argument of a morsel as value cells: two cells and
    a NULL flag per row (the cells of a NULL row are 0)."""

    var cells: List[Int64]
    var null: List[UInt8]

    def __init__(out self):
        self.cells = List[Int64]()
        self.null = List[UInt8]()


struct DistinctSlot(Movable):
    """A worker's COUNT(DISTINCT) state: its (aggregate, group, value)
    entries, the strings they name, and the argument type each aggregate
    saw."""

    var pairs: GroupTable
    var values: InternTable
    var arrows: List[ArrowType]
    var scratch_cells: List[Int64]
    var scratch_nulls: List[UInt8]

    def __init__(
        out self,
        num_aggs: Int,
        max_entries: Int = MAX_GROUP_CAPACITY,
        max_strings: Int = MAX_INTERN_ENTRIES,
    ):
        self.pairs = GroupTable(_PAIR_CELLS, 0, max_entries)
        self.values = InternTable(max_strings)
        self.arrows = List[ArrowType]()
        for _ in range(num_aggs):
            self.arrows.append(ArrowType.NULL)
        self.scratch_cells = List[Int64]()
        self.scratch_nulls = List[UInt8]()
        for _ in range(_PAIR_CELLS):
            self.scratch_cells.append(0)
            self.scratch_nulls.append(0)


def _read_signed[
    dtype: DType
](mut out: DistinctColumn, ref col: Column[HeapRegion], rows: Int) raises:
    var arr = col.as_primitive[dtype]()
    var has_nulls = col.null_count() > 0
    for r in range(rows):
        if has_nulls and arr.is_null(r):
            out.null.append(1)
            out.cells.append(0)
        else:
            out.null.append(0)
            out.cells.append(Int64(arr.get(r).cast[DType.int64]()))
        out.cells.append(0)


def _read_float[
    dtype: DType
](mut out: DistinctColumn, ref col: Column[HeapRegion], rows: Int) raises:
    var arr = col.as_primitive[dtype]()
    var has_nulls = col.null_count() > 0
    for r in range(rows):
        if has_nulls and arr.is_null(r):
            out.null.append(1)
            out.cells.append(0)
        else:
            out.null.append(0)
            out.cells.append(float_cell(arr.get(r).cast[DType.float64]()))
        out.cells.append(0)


def _read_decimal(
    mut out: DistinctColumn, ref col: Column[HeapRegion], rows: Int
) raises:
    var arr = col.as_decimal128()
    var has_nulls = col.null_count() > 0
    for r in range(rows):
        if has_nulls and arr.is_null(r):
            out.null.append(1)
            out.cells.append(0)
            out.cells.append(0)
        else:
            var v = arr.get_i128(r)
            out.null.append(0)
            out.cells.append(v.cast[DType.int64]())
            var hi = v >> SIMD[DType.int128, 1](64)
            out.cells.append(hi.cast[DType.int64]())


def read_distinct_column(
    mut slot: DistinctSlot,
    agg: Int,
    ref batch: RecordBatch,
    col_idx: Int,
    rows: Int,
    ref where_: String,
    ref label: String,
    ref pool: SegmentPool,
    mut res: WorkerReservation,
) raises -> DistinctColumn:
    """Column `col_idx` (`rows` rows) of `batch`, the argument of aggregate
    `agg`, as value cells; a string is interned into the worker's table.

    Raises:
        A column of a type `is_distinct_value_type` refuses, of a type other
        than the one this worker's earlier morsels gave the aggregate, of
        other than `rows` rows; an intern table the pool denied or that is
        full."""
    ref col = batch.column_at(col_idx)
    if col.length() != rows:
        raise Error(
            "pipeline_exec: "
            + label
            + " got a column of "
            + String(col.length())
            + " rows for "
            + String(rows)
            + " selected rows"
        )
    var at = col.arrow_type
    if batch.schema.field_arrow_type(col_idx) == ArrowType.DATE32:
        at = ArrowType.DATE32
    # A dictionary is served only when it holds strings: a numeric
    # dictionary is not a type this reader reads.
    if not is_distinct_value_type(at) or (
        at == ArrowType.DICTIONARY and not col.is_string_dict()
    ):
        raise Error(
            "pipeline_exec: "
            + label
            + " is not served over this column type ("
            + String(at)
            + "): COUNT(DISTINCT) takes INT8 to INT64, DATE32, FLOAT32,"
            " FLOAT64, DECIMAL128 and strings"
        )
    var cls = _value_class(at)
    if slot.arrows[agg] == ArrowType.NULL:
        slot.arrows[agg] = cls
    elif slot.arrows[agg] != cls:
        raise Error(
            "pipeline_exec: "
            + label
            + " saw a column of another type than the morsels before it"
        )
    var out = DistinctColumn()
    out.cells.reserve(2 * rows)
    out.null.reserve(rows)
    if cls == ArrowType.STRING:
        var keys = StrKeyRows()
        if not read_string_keys(
            keys, batch, col_idx, rows, False, label, slot.values, res
        ):
            if slot.values.too_many:
                raise distinct_too_many(where_, slot.values.max_entries)
            raise distinct_denied(where_, slot.values.denied_bytes, pool)
        for r in range(rows):
            out.null.append(keys.null[r])
            out.cells.append(keys.ids[r])
            out.cells.append(0)
    elif cls == ArrowType.DECIMAL128:
        _read_decimal(out, col, rows)
    elif cls == ArrowType.FLOAT64:
        _read_float[DType.float64](out, col, rows)
    elif cls == ArrowType.FLOAT32:
        _read_float[DType.float32](out, col, rows)
    elif cls == ArrowType.INT64:
        _read_signed[DType.int64](out, col, rows)
    elif cls == ArrowType.INT16:
        _read_signed[DType.int16](out, col, rows)
    elif cls == ArrowType.INT8:
        _read_signed[DType.int8](out, col, rows)
    else:
        # INT32, and DATE32 whose storage is the same 32-bit day number.
        _read_signed[DType.int32](out, col, rows)
    return out^


def admit_distinct(
    mut slot: DistinctSlot,
    agg: Int,
    group: Int,
    ref col: DistinctColumn,
    row: Int,
    ref where_: String,
    ref pool: SegmentPool,
    mut res: WorkerReservation,
) raises:
    """Record that worker group `group` saw row `row` of `col` under aggregate
    `agg`. A NULL value records nothing.

    Raises:
        A table the pool denied or that is full."""
    if col.null[row] != 0:
        return
    slot.scratch_cells[0] = Int64(agg)
    slot.scratch_cells[1] = Int64(group)
    slot.scratch_cells[2] = col.cells[2 * row]
    slot.scratch_cells[3] = col.cells[2 * row + 1]
    var h = hash_key(slot.scratch_cells, slot.scratch_nulls)
    var p = slot.pairs.find_or_insert(
        h, slot.scratch_cells, slot.scratch_nulls, res
    )
    if p < 0:
        if slot.pairs.too_many:
            raise distinct_too_many(where_, slot.pairs.max_capacity)
        raise distinct_denied(where_, slot.pairs.denied_bytes, pool)


struct DistinctMerge(Movable):
    """The merge of the workers' COUNT(DISTINCT) entries into the counts of
    the merged groups."""

    var pairs: GroupTable
    var values: InternTable
    var arrows: List[ArrowType]
    var reservation: WorkerReservation
    var _max_entries: Int
    var _max_strings: Int

    def __init__(
        out self,
        num_aggs: Int,
        var reservation: WorkerReservation,
        max_entries: Int = MAX_GROUP_CAPACITY,
        max_strings: Int = MAX_INTERN_ENTRIES,
    ):
        self.pairs = GroupTable(_PAIR_CELLS, 0, max_entries)
        self.values = InternTable(max_strings)
        self.arrows = List[ArrowType]()
        for _ in range(num_aggs):
            self.arrows.append(ArrowType.NULL)
        self.reservation = reservation^
        self._max_entries = max_entries
        self._max_strings = max_strings

    def merge_worker(
        mut self,
        ref slot: DistinctSlot,
        ref group_map: List[Int],
        mut cells: List[AggCell],
        num_aggs: Int,
        ref where_: String,
        ref labels: List[String],
        ref pool: SegmentPool,
    ) raises:
        """Move the entries of `slot` into the merged table; each that is new
        there adds one to `cells[merged group * num_aggs + aggregate].count`.
        `group_map[g]` is the merged group of the worker's group `g`.

        Raises:
            An aggregate whose argument had another type on another worker; a
            merged table the pool denied or that is full."""
        for i in range(num_aggs):
            var a = slot.arrows[i]
            if a == ArrowType.NULL:
                continue
            if self.arrows[i] == ArrowType.NULL:
                self.arrows[i] = a
            elif self.arrows[i] != a:
                raise Error(
                    "pipeline_exec: "
                    + labels[i]
                    + " saw columns of different types on different workers"
                )
        var cells4 = List[Int64]()
        var nulls4 = List[UInt8]()
        for _ in range(_PAIR_CELLS):
            cells4.append(0)
            nulls4.append(0)
        ref t = slot.pairs
        for p in range(t.n):
            var agg = Int(t.keys[p * _PAIR_CELLS])
            var mg = group_map[Int(t.keys[p * _PAIR_CELLS + 1])]
            var v0 = t.keys[p * _PAIR_CELLS + 2]
            if self.arrows[agg] == ArrowType.STRING:
                var id = Int(v0)
                var mid = self.values.intern(
                    slot.values.value(id),
                    slot.values.hashes[id],
                    self.reservation,
                )
                if mid < 0:
                    if self.values.too_many:
                        raise distinct_too_many(where_, self._max_strings)
                    raise distinct_denied(
                        where_, self.values.denied_bytes, pool
                    )
                v0 = Int64(mid)
            cells4[0] = Int64(agg)
            cells4[1] = Int64(mg)
            cells4[2] = v0
            cells4[3] = t.keys[p * _PAIR_CELLS + 3]
            var before = self.pairs.n
            var m = self.pairs.find_or_insert(
                hash_key(cells4, nulls4), cells4, nulls4, self.reservation
            )
            if m < 0:
                if self.pairs.too_many:
                    raise distinct_too_many(where_, self._max_entries)
                raise distinct_denied(where_, self.pairs.denied_bytes, pool)
            if self.pairs.n > before:
                cells[mg * num_aggs + agg].count += 1

    def finish(mut self):
        """Free the merged table and the merge's strings and return their
        memory; the counts are already in the sink's cells."""
        self.pairs = GroupTable(_PAIR_CELLS, 0, self._max_entries)
        self.values = InternTable(self._max_strings)
        self.reservation.give_back_all()

