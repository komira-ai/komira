# =============================================================================
# The grouped aggregation sink with a spill directory, fed morsels directly
# =============================================================================
#
# The rows are `group_batch` rows (`group_harness` says what each cell of row
# r holds), dealt to the workers in morsels, and the expected groups come from
# a plain loop over the row numbers with a `Dict` from the key's text to a
# running tally, never from the engine. The keys are (k1, id): k1 is NULL in
# one row of 13 and id is the row number, so there is a group per row number;
# every row number is fed `PASSES` times, in passes that go to the workers in
# turn, so each group's rows are folded by different workers and, once a
# worker spilled, partly from disk. What the tests prove:
#
#   * Under a budget the tables outgrow, a sink with a spill directory writes
#     its tables to disk (the directory holds a spill while the rows are fed)
#     and its groups are the oracle's: COUNT(*), COUNT, SUM, MIN, MAX, AVG
#     (bit for bit) and DECIMAL SUM, a NULL k1 kept in the key, on one to four
#     workers and with the rows dealt in order and in reverse. The spill files
#     are gone after `combine` and the pool is whole after `take_output`.
#   * The same budget without a spill directory is refused by name, so the
#     answer above needed the spill.
#   * With a pool that has room for the tables, a spill directory changes no
#     answer and writes nothing (the directory is never created), for keys
#     with few groups (so most partitions are empty) and for no row at all.
#   * A pool too small for the output rows of the partitions is refused by
#     name once every table is on disk, and the files and the pool are freed
#     when the sink is dropped.
#   * A table whose very first step the pool denies is refused, not spilled
#     (there is nothing to write), and nothing is written.
#   * A sink with COUNT(DISTINCT) does not spill: it is refused as without a
#     spill directory, and the refusal says why. So does a sink with a MEDIAN.
#   * A VAR_POP keeps its Welford state (count, mean, m2) through the spill:
#     each group's equal values give 0.0 only if every partial's mean came
#     back from disk.
#   * The group limit holds: a worker table past it is refused, not spilled,
#     and a partition of the merge past it is refused by name.
#   * The partition of a group is the top four bits of its hash.
#   * The chunk format (`group_spill`): a table's groups, NULL flags,
#     128-bit values (negative ones included), doubles bit for bit (a NaN,
#     -0.0, an infinity; the fold's double and the variance mean and m2),
#     decimal precision and
#     a negative scale come back from disk as they went in; a partition with
#     no group writes no chunk; `spill_table` writes only the partitions from
#     the one it is given; a chunk of the wrong shape and a read before any
#     write are refused by name; `cleanup` and a drop delete the files.

from std.collections import Dict
from std.memory import bitcast
from std.os import listdir
from std.os.path import exists
from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import Field, RecordBatch, Schema, SchemaBuilder
from containers.slab import Slab
from engine_runtime.spill.spill_storage import ChunkId
from morsel.morsel import Morsel
from morsel.pipeline_execution import PipelineExecution
from physical_plan.physical_plan import AggSinkData, KEY_DTYPE_I64
from pipeline_exec.agg_fold import IN_DECIMAL
from pipeline_exec.group_harness import (
    d_null,
    d_unscaled,
    group_batch,
    k1_null,
    k1_value,
    v_null,
    v_value,
)
from pipeline_exec.group_spill import (
    GroupSpill,
    SPILL_PARTITIONS,
    SpilledGroups,
    SpilledRun,
    partition_batch,
    spill_partition,
)
from pipeline_exec.group_table import GroupTable, hash_key
from pipeline_exec.plan_harness import grouped_agg_data
from pipeline_exec.segment_pool import SegmentPool, WorkerReservation
from pipeline_exec.sink_group_agg import GroupAggSink
from plan_expr.agg_expr import (
    AGG_COUNT,
    AGG_COUNT_DISTINCT,
    AGG_MAX,
    AGG_MEAN,
    AGG_MIN,
    AGG_MEDIAN,
    AGG_SUM,
    AGG_VAR_POP,
    AggExpr,
)
from plan_expr.expr import Expr
from runtime_paths import test_tmpdir
from scalar_arithmetic.decimal_arith import I128

comptime PASSES = 2
comptime ROWS = 1500
# 25 morsels a pass: a count that 2, 3 and 4 do not divide, so a row number
# goes to another worker in each pass.
comptime MORSEL = 60
# Room for a few small tables and for the output rows of every partition,
# far from room for a table of all ROWS groups (about 0.7 MB).
comptime TIGHT = 384 * 1024


def _dir(name: String) raises -> String:
    return test_tmpdir() + "/" + name


def _entries(dir: String) raises -> Int:
    """The entries of `dir`, 0 when it does not exist."""
    if not exists(dir):
        return 0
    return len(listdir(dir))


def _agg(func: UInt8, col: String) -> AggExpr:
    return AggExpr(func, Optional(Expr.col_ref(col)), None)


def _data(distinct: Bool = False) raises -> AggSinkData:
    var keys = Slab[Expr]()
    keys.append(Expr.col_ref("k1"))
    keys.append(Expr.col_ref("id"))
    var aggs = Slab[AggExpr]()
    aggs.append(AggExpr(AGG_COUNT, None, None))
    aggs.append(_agg(AGG_COUNT, "v"))
    aggs.append(_agg(AGG_SUM, "v"))
    aggs.append(_agg(AGG_MIN, "v"))
    aggs.append(_agg(AGG_MAX, "v"))
    aggs.append(_agg(AGG_MEAN, "v"))
    aggs.append(_agg(AGG_SUM, "d"))
    aggs.append(_agg(AGG_VAR_POP, "v"))
    var sb = SchemaBuilder()
    sb.add_field(Field("k1", ArrowType.INT64, True))
    sb.add_field(Field("id", ArrowType.INT64, True))
    sb.add_field(Field("cs", ArrowType.INT64, False))
    sb.add_field(Field("cv", ArrowType.INT64, False))
    sb.add_field(Field("sv", ArrowType.INT64, True))
    sb.add_field(Field("mn", ArrowType.INT64, True))
    sb.add_field(Field("mx", ArrowType.INT64, True))
    sb.add_field(Field("av", ArrowType.FLOAT64, True))
    sb.add_field(Field.decimal128("sd", 38, 2, True))
    sb.add_field(Field("vp", ArrowType.FLOAT64, True))
    if distinct:
        aggs.append(_agg(AGG_COUNT_DISTINCT, "v"))
        sb.add_field(Field("dv", ArrowType.INT64, False))
    return grouped_agg_data(keys^, aggs^, sb.build())


def _sink(
    var pool: SegmentPool,
    spill_dir: String,
    distinct: Bool = False,
) raises -> GroupAggSink:
    return GroupAggSink(
        _data(distinct), KEY_DTYPE_I64, pool^, 0, spill_dir=spill_dir
    )


def _feed(
    mut sink: GroupAggSink, rows: Int, workers: Int, reverse: Bool
) raises:
    """Rows 0 .. rows - 1, PASSES times, in morsels of MORSEL; morsel m goes
    to worker m % workers (workers - 1 - m % workers when `reverse`)."""
    sink.resize_worker_state(workers)
    var m = 0
    for _ in range(PASSES):
        var start = 0
        while start < rows:
            var n = min(MORSEL, rows - start)
            var w = m % workers
            if reverse:
                w = workers - 1 - w
            sink.consume(w, Morsel(group_batch(start, n), m, 0))
            m += 1
            start += n


def _combine_and_take(mut sink: GroupAggSink, workers: Int) raises -> RecordBatch:
    var pipeline = PipelineExecution(workers, 0)
    sink.combine(pipeline)
    sink.finalize()
    return sink.take_output()


def _key_text(r: Int) -> String:
    var k1 = String("N") if k1_null(r) else String(k1_value(r))
    return k1 + "|" + String(r)


def _check(ref out: RecordBatch, rows: Int) raises:
    """Every row number r is one group (k1 of r, r) of PASSES rows."""
    assert_equal(out.num_rows(), rows, "number of groups")
    assert_equal(out.num_columns(), 10)
    var seen = Dict[String, Bool]()
    var k1 = out.column_at(0).as_primitive[DType.int64]()
    var ids = out.column_at(1).as_primitive[DType.int64]()
    var cs = out.column_at(2).as_primitive[DType.int64]()
    var cv = out.column_at(3).as_primitive[DType.int64]()
    var sv = out.column_at(4).as_primitive[DType.int64]()
    var mn = out.column_at(5).as_primitive[DType.int64]()
    var mx = out.column_at(6).as_primitive[DType.int64]()
    var av = out.column_at(7).as_primitive[DType.float64]()
    var sd = out.column_at(8).as_decimal128()
    var vp = out.column_at(9).as_primitive[DType.float64]()
    for i in range(out.num_rows()):
        var r = Int(ids.get(i))
        assert_true(r >= 0 and r < rows, "unexpected id " + String(r))
        var key = (
            String("N") if out.column_at(0).is_null_at(i) else String(
                Int(k1.get(i))
            )
        ) + "|" + String(r)
        assert_equal(key, _key_text(r), "the key of id " + String(r))
        assert_true(key not in seen, "group " + key + " twice")
        seen[key] = True
        assert_equal(Int(cs.get(i)), PASSES, "COUNT(*) of " + key)
        var valid = not v_null(r)
        assert_equal(Int(cv.get(i)), PASSES if valid else 0, "COUNT(v)")
        for c in range(4, 8):
            assert_equal(out.column_at(c).is_null_at(i), not valid)
        if valid:
            var v = v_value(r)
            assert_equal(Int(sv.get(i)), PASSES * v, "SUM(v) of " + key)
            assert_equal(Int(mn.get(i)), v, "MIN(v) of " + key)
            assert_equal(Int(mx.get(i)), v, "MAX(v) of " + key)
            assert_equal(av.get(i), Float64(v), "AVG(v) of " + key)
        assert_equal(out.column_at(8).is_null_at(i), d_null(r), "SUM(d)")
        if not d_null(r):
            assert_true(
                sd.get_i128(i) == I128(PASSES * d_unscaled(r)),
                "SUM(d) of " + key,
            )
        # The PASSES values of a group are equal, so VAR_POP is 0.0 only when
        # each partial's mean came back from disk with it.
        assert_equal(out.column_at(9).is_null_at(i), not valid, "VAR_POP(v)")
        if valid:
            assert_equal(vp.get(i), 0.0, "VAR_POP(v) of " + key)


def test_spilled_tables_give_the_oracles_groups_on_any_worker_count() raises:
    for workers in range(1, 5):
        for reverse in range(2):
            var name = (
                "spill_w" + String(workers) + "_r" + String(reverse)
            )
            var dir = _dir(name)
            var pool = SegmentPool(TIGHT)
            var sink = _sink(pool.share(), dir)
            _feed(sink, ROWS, workers, reverse == 1)
            assert_equal(_entries(dir), workers, "one spill per worker")
            var out = _combine_and_take(sink, workers)
            _check(out, ROWS)
            assert_equal(_entries(dir), 0, "spill files left behind")
            assert_equal(pool.granted(), 0)


def test_the_same_budget_without_a_spill_directory_is_refused() raises:
    var pool = SegmentPool(TIGHT)
    var sink = _sink(pool.share(), "")
    with assert_raises(contains="for its group table (budget 393216"):
        _feed(sink, ROWS, 2, False)
    _ = sink^
    assert_equal(pool.granted(), 0)


def test_with_room_for_the_tables_a_spill_directory_changes_nothing() raises:
    var dir = _dir("spill_roomy")
    # Many groups: one per row number.
    var pool = SegmentPool()
    var sink = _sink(pool.share(), dir)
    _feed(sink, 300, 3, False)
    _check(_combine_and_take(sink, 3), 300)
    # Few groups: rows 0 and 1 only, so most partitions are empty.
    var few = _sink(pool.share(), dir)
    _feed(few, 2, 2, True)
    _check(_combine_and_take(few, 2), 2)
    # No row at all: no group, and the declared columns.
    var none = _sink(pool.share(), dir)
    none.resize_worker_state(2)
    var empty = _combine_and_take(none, 2)
    assert_equal(empty.num_rows(), 0)
    assert_equal(empty.num_columns(), 10)
    assert_true(not exists(dir), "a spill that was not needed wrote files")
    assert_equal(pool.granted(), 0)


def test_output_rows_the_pool_cannot_hold_are_refused_once_tables_are_on_disk() raises:
    # Room for the two workers' first tables and, once they are on disk, for
    # a partition's table of up to 128 groups (61,696 bytes), but not for that
    # and the partition's output rows besides.
    var dir = _dir("spill_output_refused")
    var pool = SegmentPool(65_000)
    var sink = _sink(pool.share(), dir)
    _feed(sink, ROWS, 2, False)
    with assert_raises(
        contains="for the output rows of a spill partition (budget 65000"
    ):
        _ = _combine_and_take(sink, 2)
    _ = sink^
    assert_equal(_entries(dir), 0, "a dropped sink left spill files")
    assert_equal(pool.granted(), 0)


def test_a_first_table_step_the_pool_denies_is_refused_and_writes_nothing() raises:
    var dir = _dir("spill_first_step")
    var pool = SegmentPool(1000)
    var sink = _sink(pool.share(), dir)
    with assert_raises(contains="for its group table (budget 1000, granted"):
        _feed(sink, ROWS, 1, False)
    _ = sink^
    assert_true(not exists(dir), "an empty table was spilled")
    assert_equal(pool.granted(), 0)


def test_count_distinct_does_not_spill_and_the_refusal_says_why() raises:
    var tail = (
        "; a spill directory is set, and a COUNT(DISTINCT) aggregate does not"
        " spill"
    )
    var dir = _dir("spill_distinct")
    var pool = SegmentPool(1000)
    var sink = _sink(pool.share(), dir, distinct=True)
    var said = String("")
    try:
        _feed(sink, ROWS, 1, False)
    except e:
        said = String(e)
    assert_true(said.endswith(tail), "the refusal was: " + said)
    assert_true(not exists(dir))
    # Without a spill directory the same refusal has no such tail.
    var plain = _sink(SegmentPool(1000), "", distinct=True)
    var plain_said = String("")
    try:
        _feed(plain, ROWS, 1, False)
    except e:
        plain_said = String(e)
    assert_true(plain_said.find("was denied") >= 0, plain_said)
    assert_true(plain_said.find("spill") < 0, plain_said)


def test_a_median_does_not_spill_and_the_refusal_says_why() raises:
    var keys = Slab[Expr]()
    keys.append(Expr.col_ref("id"))
    var aggs = Slab[AggExpr]()
    aggs.append(_agg(AGG_MEDIAN, "v"))
    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, False))
    sb.add_field(Field("m", ArrowType.FLOAT64, True))
    var dir = _dir("spill_median")
    var sink = GroupAggSink(
        grouped_agg_data(keys^, aggs^, sb.build()),
        KEY_DTYPE_I64,
        SegmentPool(1000),
        0,
        spill_dir=dir,
    )
    sink.resize_worker_state(1)
    var said = String("")
    # One row a morsel, so the group table outgrows the pool before the kept
    # values do.
    try:
        for r in range(ROWS):
            sink.consume(0, Morsel(group_batch(r, 1), r, 0))
    except e:
        said = String(e)
    assert_true(said.find("for its group table") >= 0, said)
    assert_true(
        said.endswith(
            "; a spill directory is set, and a MEDIAN or QUANTILE_CONT"
            " aggregate does not spill"
        ),
        "the refusal was: " + said,
    )
    assert_true(not exists(dir))


def _capped(max_groups: Int, dir: String) raises -> GroupAggSink:
    var keys = Slab[Expr]()
    keys.append(Expr.col_ref("id"))
    var aggs = Slab[AggExpr]()
    aggs.append(AggExpr(AGG_COUNT, None, None))
    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, False))
    sb.add_field(Field("n", ArrowType.INT64, False))
    return GroupAggSink(
        grouped_agg_data(keys^, aggs^, sb.build()),
        KEY_DTYPE_I64,
        SegmentPool(),
        0,
        max_groups,
        spill_dir=dir,
    )


def test_the_group_limit_holds_in_a_worker_and_in_a_partition() raises:
    var dir = _dir("spill_capped")
    var worker = _capped(64, dir)
    worker.resize_worker_state(1)
    worker.consume(0, Morsel(group_batch(0, 64), 0, 0))
    with assert_raises(contains="more groups than a group table holds (64)"):
        worker.consume(0, Morsel(group_batch(64, 1), 1, 0))
    _ = worker^
    # Forty workers of 64 groups each fit alone; 2,560 groups over 16
    # partitions put far more than 64 into one.
    var merge = _capped(64, dir)
    merge.resize_worker_state(40)
    for w in range(40):
        merge.consume(w, Morsel(group_batch(64 * w, 64), w, 0))
    with assert_raises(contains="more groups than a group table holds (64)"):
        _ = _combine_and_take(merge, 40)
    _ = merge^
    assert_equal(_entries(dir), 0)


# --- the chunk format ----------------------------------------------------------


def _table() raises -> GroupTable:
    """Two key cells and two aggregates; five groups, one with a NULL key
    cell, cells holding negative 128-bit values, doubles and decimal types."""
    var t = GroupTable(2, 2)
    var res = WorkerReservation(SegmentPool())
    var cells = List[Int64](length=2, fill=0)
    var nulls = List[UInt8](length=2, fill=0)
    for g in range(5):
        cells[0] = Int64(g * 1000 - 2500)
        cells[1] = Int64(-g)
        nulls[0] = 1 if g == 3 else 0
        if g == 3:
            cells[0] = 0
        var at = t.find_or_insert(hash_key(cells, nulls), cells, nulls, res)
        assert_equal(at, g)
        ref a = t.cells[g * 2]
        a.count = g + 1
        var big = I128(-7)
        for _ in range(30):
            big = big * I128(10)
        a.value = big - I128(g)
        a.kind = IN_DECIMAL
        a.arrow = ArrowType.DECIMAL128
        a.precision = 38
        a.scale = -3 if g == 2 else 2
        ref b = t.cells[g * 2 + 1]
        b.count = 3 * g
        b.value = I128(g) << 100
        # Doubles the codec must keep bit for bit: a NaN, -0.0, an infinity.
        var doubles: List[Float64] = [-1.5, -0.0, Float64.MAX, 0.0, 2.25]
        b.fvalue = doubles[g]
        if g == 3:
            b.fvalue = Float64(0) / Float64(0)
        if g == 4:
            b.fvalue = Float64.MAX * 2.0
        # The variance state, bit for bit as well.
        b.mean = doubles[(g + 1) % 5]
        b.m2 = doubles[(g + 2) % 5]
    return t^


def _assert_groups_equal(
    ref t: GroupTable, ref rows: List[Int], ref back: SpilledGroups
) raises:
    assert_equal(back.n, len(rows))
    for i in range(len(rows)):
        var g = rows[i]
        assert_true(back.hashes[i] == t.hashes[g], "hash")
        for c in range(2):
            assert_equal(back.keys[i * 2 + c], t.keys[g * 2 + c], "key cell")
            assert_equal(back.nulls[i * 2 + c], t.nulls[g * 2 + c], "flag")
        for a in range(2):
            ref want = t.cells[g * 2 + a]
            ref got = back.cells[i * 2 + a]
            assert_equal(got.count, want.count, "count")
            assert_true(got.value == want.value, "128-bit value")
            assert_true(
                bitcast[DType.uint64](got.fvalue)
                == bitcast[DType.uint64](want.fvalue),
                "double bits",
            )
            assert_true(
                bitcast[DType.uint64](got.mean)
                == bitcast[DType.uint64](want.mean),
                "mean bits",
            )
            assert_true(
                bitcast[DType.uint64](got.m2)
                == bitcast[DType.uint64](want.m2),
                "m2 bits",
            )
            assert_equal(got.kind, want.kind, "kind")
            assert_true(got.arrow == want.arrow, "arrow type")
            assert_equal(got.precision, want.precision, "precision")
            assert_equal(got.scale, want.scale, "scale")


def _rows_of(ref t: GroupTable, p: Int) -> List[Int]:
    var rows = List[Int]()
    for g in range(t.n):
        if spill_partition(t.hashes[g]) == p:
            rows.append(g)
    return rows^


def test_the_partition_is_the_top_four_bits_of_the_hash() raises:
    assert_equal(spill_partition(UInt64(0)), 0)
    assert_equal(spill_partition((UInt64(1) << 60) - 1), 0)
    assert_equal(spill_partition(UInt64(1) << 60), 1)
    assert_equal(spill_partition(UInt64(0xFFFFFFFFFFFFFFFF)), 15)
    assert_equal(SPILL_PARTITIONS, 16)


def test_a_partition_batch_round_trips_every_field_of_its_groups() raises:
    var t = _table()
    var with_groups = 0
    for p in range(SPILL_PARTITIONS):
        var rows = _rows_of(t, p)
        var batch = partition_batch(t, p)
        if len(rows) == 0:
            assert_true(not batch, "a partition with no group made a batch")
            continue
        with_groups += 1
        var b = batch.take()
        _assert_groups_equal(t, rows, SpilledGroups(b, 2, 2))
    assert_true(with_groups > 0)
    assert_true(with_groups < SPILL_PARTITIONS, "no partition is empty")


def test_a_spill_writes_reads_and_deletes_its_chunks() raises:
    var t = _table()
    var dir = _dir("group_spill_chunks")
    var spill = GroupSpill(dir, 2, 2)
    assert_true(not spill.has_spilled())
    spill.spill_table(t, 0)
    assert_true(spill.has_spilled())
    assert_equal(_entries(dir), 1, "one sub-directory per spill")
    var total = 0
    for r in range(len(spill.runs)):
        ref run = spill.runs[r]
        var rows = _rows_of(t, run.partition)
        _assert_groups_equal(t, rows, spill.read(run))
        total += len(rows)
    assert_equal(total, t.n, "every group was written once")
    # From a later partition on, the partitions before it are not written.
    var first = spill.runs[0].partition
    var later = GroupSpill(dir, 2, 2)
    later.spill_table(t, first + 1)
    for r in range(len(later.runs)):
        assert_true(later.runs[r].partition > first)
    spill.cleanup()
    assert_true(not spill.has_spilled())
    assert_equal(_entries(dir), 1, "cleanup did not delete its sub-directory")
    _ = later^
    assert_equal(_entries(dir), 0, "a dropped spill left its files")
    spill.cleanup()  # a spill with no storage cleans up nothing


def test_a_wrong_chunk_and_a_read_before_a_write_are_refused() raises:
    var t = _table()
    var p = spill_partition(t.hashes[0])
    var batch = partition_batch(t, p)
    var b = batch.take()
    # Two key cells and two aggregates make 15 columns; three aggregates
    # would make 20.
    with assert_raises(contains="a spilled group chunk has 15 columns"):
        _ = SpilledGroups(b, 2, 3)
    var spill = GroupSpill(_dir("group_spill_unread"), 2, 2)
    with assert_raises(contains="read before it wrote a chunk"):
        _ = spill.read(SpilledRun(0, ChunkId(UInt64(0)), 0))


def main() raises:
    var suite = TestSuite()
    suite.test[test_spilled_tables_give_the_oracles_groups_on_any_worker_count]()
    suite.test[test_the_same_budget_without_a_spill_directory_is_refused]()
    suite.test[test_with_room_for_the_tables_a_spill_directory_changes_nothing]()
    suite.test[test_output_rows_the_pool_cannot_hold_are_refused_once_tables_are_on_disk]()
    suite.test[test_a_first_table_step_the_pool_denies_is_refused_and_writes_nothing]()
    suite.test[test_count_distinct_does_not_spill_and_the_refusal_says_why]()
    suite.test[test_the_group_limit_holds_in_a_worker_and_in_a_partition]()
    suite.test[test_the_partition_is_the_top_four_bits_of_the_hash]()
    suite.test[test_a_partition_batch_round_trips_every_field_of_its_groups]()
    suite.test[test_a_spill_writes_reads_and_deletes_its_chunks]()
    suite.test[test_a_wrong_chunk_and_a_read_before_a_write_are_refused]()
    suite^.run()
