# =============================================================================
# group_spill -- a worker's group table written to disk, by hash partition
# =============================================================================
#
# The spill of the grouped aggregation sink (`sink_group_agg`). When a
# worker's `GroupTable` cannot grow because the segment pool denies the step,
# and the sink was given a spill directory, the worker hands its table to its
# `GroupSpill`: every group goes to one of `SPILL_PARTITIONS` partitions by
# the top bits of its key hash (`spill_partition`; the table's slot directory
# reads the low bits), each non-empty partition is written as one chunk, and
# the worker starts a new, empty table. `combine` then builds the result one
# partition at a time, from the groups of that partition still in the
# workers' tables and from every chunk written for it, so the merge holds the
# groups of one partition, not of the whole result.
#
# A chunk is a batch of one row per group, written with `engine_runtime`'s
# THSPLC column codec (`native_column_write_chunk`) to a
# `LocalDiskSpillStorage` (the `SpillStorage` of the local disk) and read back
# with `native_column_read_chunk`. Its columns, all non-nullable:
#
#   h            INT64    the key hash (the bits of the UInt64)
#   k<c>         INT64    key cell c (cells as `group_keys` lays them out)
#   n<c>         INT32    the NULL flag of key cell c
#   for each aggregate i, the `AggCell`:
#   count<i>     INT64    the rows the cell folded
#   lo<i>, hi<i> INT64    the low and high 64 bits of the 128-bit value
#   f<i>         FLOAT64  the double fold
#   meta<i>      INT64    kind (bits 0-7), arrow type id (8-15), precision
#                         (16-31), scale as a signed 32-bit value (32-63)
#   mean<i>      FLOAT64  the mean of a variance aggregate's values
#   m2<i>        FLOAT64  their sum of squared distances from the mean
#
# The format lives only between a write and a read of one process: it is not
# a file format of any release, and a chunk is never read by another build.
#
# Each worker's storage is created on its first spill (a worker that never
# spills never touches the filesystem), rooted at a new sub-directory of the
# spill directory made by `op_spill_rows.spill_root.create_spill_root`
# (`thsplc_groupagg_<pid>_<counter>`, created exclusively, so sinks, queries
# and processes may share one spill directory). `cleanup` deletes the files
# and the sub-directory; a `GroupSpill` dropped without it (a failed query)
# deletes them in its destructor.

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.primitive_array import PrimitiveArray
from byte_buffer.heap_region import HeapRegion
from arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    Schema,
    SchemaBuilder,
)
from column_kernels.compiler_helpers import batch_buffer_bytes
from engine_runtime.spill.local_disk import LocalDiskSpillStorage
from engine_runtime.spill.native_spill import (
    native_column_read_chunk,
    native_column_write_chunk,
)
from engine_runtime.spill.spill_storage import ChunkId
from op_spill_rows.spill_root import create_spill_root
from scalar_arithmetic.decimal_arith import I128

from .agg_fold import AggCell
from .group_table import GroupTable

comptime SPILL_PARTITIONS: Int = 16
"""The partitions a spilled group table is split into by key hash."""

comptime _PARTITION_SHIFT: UInt64 = 60
"""`spill_partition` reads the top 4 bits of the hash: 2^4 partitions."""

comptime _CELL_COLUMNS: Int = 7
"""The columns of one aggregate's cell in a chunk."""

comptime _LOW_64: I128 = (I128(1) << 64) - 1


@always_inline
def spill_partition(h: UInt64) -> Int:
    """The spill partition of a group whose key hashes to `h`."""
    return Int(h >> _PARTITION_SHIFT)


def _run_schema(nc: Int, na: Int) -> Schema:
    """The schema of a chunk of groups with `nc` key cells and `na`
    aggregates."""
    var sb = SchemaBuilder()
    sb.add_field(Field("h", ArrowType.INT64, False))
    for c in range(nc):
        sb.add_field(Field("k" + String(c), ArrowType.INT64, False))
    for c in range(nc):
        sb.add_field(Field("n" + String(c), ArrowType.INT32, False))
    for i in range(na):
        var s = String(i)
        sb.add_field(Field("count" + s, ArrowType.INT64, False))
        sb.add_field(Field("lo" + s, ArrowType.INT64, False))
        sb.add_field(Field("hi" + s, ArrowType.INT64, False))
        sb.add_field(Field("f" + s, ArrowType.FLOAT64, False))
        sb.add_field(Field("meta" + s, ArrowType.INT64, False))
        sb.add_field(Field("mean" + s, ArrowType.FLOAT64, False))
        sb.add_field(Field("m2" + s, ArrowType.FLOAT64, False))
    return sb.build()


def _float64_column(var values: List[Float64]) -> Column[HeapRegion]:
    return Column.from_primitive[DType.float64](
        PrimitiveArray[DType.float64].from_list(values)
    )


def _int64_column(var values: List[Int64]) -> Column[HeapRegion]:
    return Column.from_primitive[DType.int64](
        PrimitiveArray[DType.int64].from_list(values)
    )


def _cell_meta(ref cell: AggCell) -> Int64:
    """The kind, arrow type id, precision and scale of `cell` in one Int64."""
    var scale_bits = Int64(cell.scale) & 0xFFFFFFFF
    return (
        cell.kind.cast[DType.int64]()
        | (cell.arrow.type_id.cast[DType.int64]() << 8)
        | ((Int64(cell.precision) & 0xFFFF) << 16)
        | (scale_bits << 32)
    )


def partition_batch(
    ref table: GroupTable, partition: Int
) raises -> Optional[RecordBatch]:
    """The groups of `table` in spill partition `partition` as one chunk
    batch (the layout in the header), or None when it has none."""
    var nc = table.nk
    var na = table.na
    var rows = List[Int]()
    for g in range(table.n):
        if spill_partition(table.hashes[g]) == partition:
            rows.append(g)
    var n = len(rows)
    if n == 0:
        return None
    var hashes = List[Int64](capacity=n)
    for r in range(n):
        hashes.append(table.hashes[rows[r]].cast[DType.int64]())
    var builder = RecordBatchBuilder()
    builder.add_column(_int64_column(hashes^))
    for c in range(nc):
        var cells = List[Int64](capacity=n)
        for r in range(n):
            cells.append(table.keys[rows[r] * nc + c])
        builder.add_column(_int64_column(cells^))
    for c in range(nc):
        var flags = List[Int32](capacity=n)
        for r in range(n):
            flags.append(table.nulls[rows[r] * nc + c].cast[DType.int32]())
        builder.add_column(
            Column.from_primitive[DType.int32](
                PrimitiveArray[DType.int32].from_list(flags)
            )
        )
    for i in range(na):
        var counts = List[Int64](capacity=n)
        var lows = List[Int64](capacity=n)
        var highs = List[Int64](capacity=n)
        var floats = List[Float64](capacity=n)
        var metas = List[Int64](capacity=n)
        var means = List[Float64](capacity=n)
        var m2s = List[Float64](capacity=n)
        for r in range(n):
            ref cell = table.cells[rows[r] * na + i]
            counts.append(Int64(cell.count))
            lows.append((cell.value & _LOW_64).cast[DType.int64]())
            highs.append((cell.value >> 64).cast[DType.int64]())
            floats.append(cell.fvalue)
            metas.append(_cell_meta(cell))
            means.append(cell.mean)
            m2s.append(cell.m2)
        builder.add_column(_int64_column(counts^))
        builder.add_column(_int64_column(lows^))
        builder.add_column(_int64_column(highs^))
        builder.add_column(_float64_column(floats^))
        builder.add_column(_int64_column(metas^))
        builder.add_column(_float64_column(means^))
        builder.add_column(_float64_column(m2s^))
    return builder.build(_run_schema(nc, na))


struct SpilledGroups(Movable):
    """The groups of a chunk read back: the columns of a chunk batch as the
    lists a `GroupTable` holds, one row per group."""

    var n: Int
    var hashes: List[UInt64]
    var keys: List[Int64]
    var nulls: List[UInt8]
    var cells: List[AggCell]

    def __init__(out self, ref batch: RecordBatch, nc: Int, na: Int) raises:
        var expected = 1 + 2 * nc + _CELL_COLUMNS * na
        if batch.num_columns() != expected:
            raise Error(
                "pipeline_exec: a spilled group chunk has "
                + String(batch.num_columns())
                + " columns, and its sink writes "
                + String(expected)
            )
        var n = batch.num_rows()
        self.n = n
        self.hashes = List[UInt64](capacity=n)
        self.keys = List[Int64](capacity=n * nc)
        self.nulls = List[UInt8](capacity=n * nc)
        self.cells = List[AggCell](capacity=n * na)
        var h = batch.column_at(0).as_primitive[DType.int64]()
        for r in range(n):
            self.hashes.append(h.get(r).cast[DType.uint64]())
        var key_cols = List[PrimitiveArray[DType.int64]]()
        var null_cols = List[PrimitiveArray[DType.int32]]()
        for c in range(nc):
            key_cols.append(batch.column_at(1 + c).as_primitive[DType.int64]())
            null_cols.append(
                batch.column_at(1 + nc + c).as_primitive[DType.int32]()
            )
        for r in range(n):
            for c in range(nc):
                self.keys.append(key_cols[c].get(r))
                self.nulls.append(null_cols[c].get(r).cast[DType.uint8]())
        var counts = List[PrimitiveArray[DType.int64]]()
        var lows = List[PrimitiveArray[DType.int64]]()
        var highs = List[PrimitiveArray[DType.int64]]()
        var floats = List[PrimitiveArray[DType.float64]]()
        var metas = List[PrimitiveArray[DType.int64]]()
        var means = List[PrimitiveArray[DType.float64]]()
        var m2s = List[PrimitiveArray[DType.float64]]()
        for i in range(na):
            var at = 1 + 2 * nc + _CELL_COLUMNS * i
            counts.append(batch.column_at(at).as_primitive[DType.int64]())
            lows.append(batch.column_at(at + 1).as_primitive[DType.int64]())
            highs.append(batch.column_at(at + 2).as_primitive[DType.int64]())
            floats.append(
                batch.column_at(at + 3).as_primitive[DType.float64]()
            )
            metas.append(batch.column_at(at + 4).as_primitive[DType.int64]())
            means.append(batch.column_at(at + 5).as_primitive[DType.float64]())
            m2s.append(batch.column_at(at + 6).as_primitive[DType.float64]())
        for r in range(n):
            for i in range(na):
                var cell = AggCell()
                cell.count = Int(counts[i].get(r))
                var low = (
                    lows[i].get(r).cast[DType.uint64]().cast[DType.int128]()
                )
                var high = highs[i].get(r).cast[DType.int128]()
                cell.value = (high << 64) | low
                cell.fvalue = floats[i].get(r)
                var meta = metas[i].get(r)
                cell.kind = (meta & 0xFF).cast[DType.uint8]()
                var type_id = ((meta >> 8) & 0xFF).cast[DType.uint8]()
                cell.arrow = ArrowType(type_id)
                cell.precision = Int((meta >> 16) & 0xFFFF)
                var scale = ((meta >> 32) & 0xFFFFFFFF).cast[DType.int32]()
                cell.scale = Int(scale)
                cell.mean = means[i].get(r)
                cell.m2 = m2s[i].get(r)
                self.cells.append(cell^)


struct SpilledRun(Copyable, Movable):
    """One chunk a worker wrote: its partition, its chunk id and the buffer
    bytes of its batch."""

    var partition: Int
    var chunk: ChunkId
    var bytes: Int

    def __init__(out self, partition: Int, chunk: ChunkId, bytes: Int):
        self.partition = partition
        self.chunk = chunk
        self.bytes = bytes


struct GroupSpill(Movable, Deinitable):
    """The spilled groups of one worker of a grouped aggregation sink."""

    var _dir: String
    var _storage: Optional[LocalDiskSpillStorage]
    var runs: List[SpilledRun]
    var _nc: Int
    var _na: Int

    def __init__(out self, var spill_dir: String, nc: Int, na: Int):
        self._dir = spill_dir^
        self._storage = None
        self.runs = List[SpilledRun]()
        self._nc = nc
        self._na = na

    def __del__(deinit self):
        """Delete the files of a spill dropped before `cleanup` (a failed
        query). Best-effort: a destructor cannot raise."""
        if self._storage:
            try:
                self._storage.value().cleanup()
            except:
                pass

    def has_spilled(self) -> Bool:
        return len(self.runs) > 0

    def spill_table(
        mut self, ref table: GroupTable, first_partition: Int
    ) raises:
        """Write the groups of `table` in the partitions from
        `first_partition` on (the ones before it are already merged), one
        chunk per non-empty partition. The caller then drops the table."""
        if not self._storage:
            self._storage = Optional[LocalDiskSpillStorage](
                LocalDiskSpillStorage.with_unlimited(
                    create_spill_root(self._dir, "groupagg")
                )
            )
        ref storage = self._storage.value()
        for p in range(first_partition, SPILL_PARTITIONS):
            var batch = partition_batch(table, p)
            if not batch:
                continue
            var b = batch.take()
            var bytes = batch_buffer_bytes(b)
            var cid = native_column_write_chunk(storage, b^)
            self.runs.append(SpilledRun(p, cid, bytes))
        storage.sync()

    def read(self, ref run: SpilledRun) raises -> SpilledGroups:
        """The groups of `run`, read back from disk."""
        if not self._storage:
            raise Error(
                "pipeline_exec: a grouped aggregation spill was read before"
                " it wrote a chunk"
            )
        var batch = native_column_read_chunk(
            self._storage.value(), run.chunk, _run_schema(self._nc, self._na)
        )
        return SpilledGroups(batch, self._nc, self._na)

    def cleanup(mut self) raises:
        """Delete every chunk and the spill's sub-directory."""
        if self._storage:
            self._storage.value().cleanup()
            self._storage = None
        self.runs = List[SpilledRun]()
