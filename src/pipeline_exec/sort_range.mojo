# =============================================================================
# sort_range -- what the sort sink needs to keep a range of its order in
# bounded memory: the rows' positions as hidden columns
# =============================================================================
#
# A top-N (SINK_TOPN) answers rows [offset, offset + n) of the sort's order. It
# never needs more than the first `offset + n` rows of that order, so a worker
# that holds many more sorts what it holds and keeps only those (`SortSink`).
#
# Which rows tie is not the question that makes this hard; WHICH of the tied
# rows survive is. The full sort (SINK_SORT) is stable over the rows as
# `CollectSink` concatenates them: by the position the source stamped on each
# morsel, (partition id, origin hint), then by the worker that held it, the
# order it arrived in and the row's place in it. A worker's rows, sorted and
# cut on their own, lose that order unless it travels with them. So every row
# a top-N keeps carries its position in three INT64 columns appended to its
# batch (`tag_batch`):
#
#   * the morsel's partition id;
#   * the morsel's origin hint;
#   * `worker * 2^40 + i`, where `i` counts the rows that worker has tagged
#     so far, so it orders by worker, then arrival, then row.
#
# Sorting by the plan's keys and then by these three, ascending, is a total
# order and it is the full sort's order. A row of the first `k` rows of all
# the input is among the first `k` of any subset holding it, so cutting each
# worker's rows to its first `k` and then sorting what is left gives exactly
# the full sort's first `k` rows, in its order, whatever the schedule.
#
# The hidden columns are named so that no column of the input has their name
# (`TagNames`), and are dropped from the answer (`drop_tags`).

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.primitive_array import PrimitiveArray
from arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    Schema,
    SchemaBuilder,
)
from byte_buffer.heap_region import HeapRegion

comptime TAG_COLUMNS: Int = 3
"""The hidden columns a kept row carries."""

comptime _SEQ_WORKER_SHIFT: Int = 40
"""A worker's row count lives in the low 40 bits of its sequence tag."""

comptime COMPACT_MIN_ROWS: Int = 2048
"""A worker sorts and cuts what it holds once it holds at least
`max(2 * keep, COMPACT_MIN_ROWS)` rows: the cut then removes at least half of
them, and a small top-N does not sort a few rows at every morsel."""


def rows_to_keep(offset: Int, count: Int) -> Int:
    """The rows of the order a range [offset, offset + count) needs: their
    sum, or `Int.MAX` where it does not fit. Both are at least zero."""
    if offset > Int.MAX - count:
        return Int.MAX
    return offset + count


def compact_at(keep: Int) -> Int:
    """The rows a worker holds before it sorts them and keeps `keep`."""
    if keep > Int.MAX // 2:
        return Int.MAX
    return max(2 * keep, COMPACT_MIN_ROWS)


def _has_column(ref schema: Schema, name: String) -> Bool:
    for c in range(schema.num_columns()):
        if schema.field_name(c) == name:
            return True
    return False


def _unused_name(ref schema: Schema, base: String) -> String:
    """`base`, or `base` followed by as many `_` as it takes for no column of
    `schema` to have the name."""
    var name = base
    while _has_column(schema, name):
        name += "_"
    return name^


@fieldwise_init
struct TagNames(Copyable, Movable):
    """The names of the three hidden columns."""

    var partition: String
    var hint: String
    var seq: String

    @staticmethod
    def for_input(ref schema: Schema) -> TagNames:
        """Names that are not a column of `schema`, the rows to be tagged."""
        return TagNames(
            _unused_name(schema, "__topn_partition"),
            _unused_name(schema, "__topn_hint"),
            _unused_name(schema, "__topn_seq"),
        )

    @staticmethod
    def of_tagged(ref schema: Schema) -> TagNames:
        """The names a tagged batch's hidden columns have: its last three."""
        var n = schema.num_columns()
        return TagNames(
            schema.field_name(n - 3),
            schema.field_name(n - 2),
            schema.field_name(n - 1),
        )

    def keys(self, keys: List[String]) -> List[String]:
        """The plan's keys followed by the three hidden columns."""
        var out = keys.copy()
        out.append(self.partition)
        out.append(self.hint)
        out.append(self.seq)
        return out^


def with_tag_order(flags: List[Bool]) -> List[Bool]:
    """`flags` (directions or NULL placements) followed by False for each
    hidden column: ascending, and no hidden column has a NULL."""
    var out = flags.copy()
    for _ in range(TAG_COLUMNS):
        out.append(False)
    return out^


def _constant(rows: Int, value: Int) raises -> Column[HeapRegion]:
    var a = PrimitiveArray[DType.int64].allocate(rows)
    for r in range(rows):
        a.set(r, Int64(value))
    return Column.from_primitive[DType.int64](a^)


def tag_batch(
    var batch: RecordBatch,
    ref names: TagNames,
    partition_id: Int,
    origin_hint: Int,
    worker_id: Int,
    first_row: Int,
) raises -> RecordBatch:
    """`batch` with the three hidden columns appended: its morsel's partition
    id and origin hint, and the sequence `worker_id * 2^40 + first_row + r` of
    its row `r`."""
    var rows = batch.num_rows()
    var seq = PrimitiveArray[DType.int64].allocate(rows)
    var base = (worker_id << _SEQ_WORKER_SHIFT) + first_row
    for r in range(rows):
        seq.set(r, Int64(base + r))
    batch.append_column(
        Field(names.partition, ArrowType.INT64, False),
        _constant(rows, partition_id),
    )
    batch.append_column(
        Field(names.hint, ArrowType.INT64, False), _constant(rows, origin_hint)
    )
    batch.append_column(
        Field(names.seq, ArrowType.INT64, False),
        Column.from_primitive[DType.int64](seq^),
    )
    return batch^


def drop_tags(ref batch: RecordBatch) raises -> RecordBatch:
    """`batch` without its last three columns, the hidden ones. The columns
    kept are shared with `batch`, not copied."""
    var keep = batch.num_columns() - TAG_COLUMNS
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    for c in range(keep):
        sb.add_field(batch.schema.field_at(c))
        rb.add_column(batch.column_at(c).share())
    return rb.build(sb.build())
