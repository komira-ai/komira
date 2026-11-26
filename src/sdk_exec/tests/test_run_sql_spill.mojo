# =============================================================================
# run_sql: a GROUP BY over the memory budget spills to the spill directory
# =============================================================================
#
# Covers: A GROUP BY of 60,001 groups (two rows each, a NULL key, NULL values)
# on a context whose memory budget the group tables outgrow and which has a
# spill directory answers an oracle computed in the test (count, exact sum,
# min, max, NULL where a group has no value) on one and two workers, as the
# same query with no budget does; the spill directory exists afterwards and is
# empty; the same budget with no spill directory is refused at execute; an
# ungrouped count and a GROUP BY of ten groups under the budget (a query that
# fits) do not create the directory; an empty spill_directory is
# ENGINE_OPTIONS_INVALID; a directory that cannot be created fails the spilling
# query at execute and the context runs the next one.
#
# The table t(k BIGINT, v BIGINT) has ROWS rows; row i has k = i % GROUPS
# (NULL where i % 997 == 3) and v = 3 * i - 50000 (NULL where i % 7 == 2), so
# there are GROUPS groups of up to two rows (a row whose k is NULL leaves its
# group) and one group of the NULL key: 60,001 groups. It is
# written to Parquet in row groups of 10,000 rows, and
#
#   SELECT k, count(*), sum(v), min(v), max(v) FROM t GROUP BY k
#
# runs on contexts of one and of two workers. The expected groups are computed
# HERE from the row formula, in 128-bit integers, never from the engine. The
# grouped sink's tables for that many groups need far more than BUDGET bytes,
# and the output rows plus one partition of the groups need far less.
#
# What each test proves:
#   * test_a_group_by_over_the_budget_spills_and_answers_as_without_one: with
#     memory_budget_bytes = BUDGET and a spill directory the query answers the
#     oracle, as the same query on a context with no budget does: every group
#     once, its count, its exact sum (DECIMAL(38, 0)), min and max, NULL where
#     a group has no value, the NULL key's group. The spill directory exists
#     afterwards (a spill creates it; a query that does not spill never does)
#     and holds nothing.
#   * test_the_same_budget_without_a_spill_directory_is_refused_at_execute:
#     the same budget with no spill directory is refused at step `execute` by
#     the grouped sink, so the answer above needed the spill.
#   * test_a_query_that_fits_the_budget_writes_nothing: an ungrouped count and
#     a GROUP BY of ten groups fit the budget and do not create the spill
#     directory.
#   * test_an_empty_spill_directory_is_refused_when_the_context_is_made: by
#     its exact message, ENGINE_OPTIONS_INVALID.
#   * test_a_spill_directory_that_cannot_be_made_fails_the_query_at_execute:
#     a spill directory under a regular file fails the spilling query at step
#     `execute`, and the context runs the next query.

from std.os import listdir
from std.os.path import exists
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.primitive_array import PrimitiveArray
from arrow.schema import Field, RecordBatch, RecordBatchBuilder, SchemaBuilder
from parquet_writer.record_batch_writer import (
    write_record_batch_to_parquet_bytes,
)
from runtime_paths import test_tmpdir
from scalar_arithmetic.decimal_arith import I128
from sdk_exec.engine_catalog import register_parquet
from sdk_exec.engine_context import EngineContext
from sdk_exec.engine_options import EngineOptions
from sdk_exec.engine_sql import STEP_EXECUTE, run_sql

comptime GROUPS = 60_000
comptime ROWS = 2 * GROUPS
comptime BUDGET = 8 * 1024 * 1024
comptime QUERY = "select k, count(*), sum(v), min(v), max(v) from t group by k"


def _k_null(i: Int) -> Bool:
    return i % 997 == 3


def _v_null(i: Int) -> Bool:
    return i % 7 == 2


def _v(i: Int) -> Int:
    return 3 * i - 50000


def _table_path(name: String) raises -> String:
    """The table, written to a file of the caller's own."""
    var path = test_tmpdir() + "/sql_spill_" + name + ".parquet"
    var k = PrimitiveArray[DType.int64].allocate_nullable(ROWS)
    var v = PrimitiveArray[DType.int64].allocate_nullable(ROWS)
    for i in range(ROWS):
        k.set(i, Int64(i % GROUPS))
        v.set(i, Int64(_v(i)))
    for i in range(ROWS):
        if _k_null(i):
            k._set_null(i)
        if _v_null(i):
            v._set_null(i)
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, True))
    sb.add_field(Field("v", ArrowType.INT64, True))
    var rb = RecordBatchBuilder()
    rb.add_column(Column.from_primitive[DType.int64](k^))
    rb.add_column(Column.from_primitive[DType.int64](v^))
    var bytes = write_record_batch_to_parquet_bytes(
        rb.build(sb.build()), max_rows_per_rg=10_000
    )
    var fh = open(path, "w")
    fh.write_bytes(Span(bytes))
    fh.close()
    return path^


def _context(
    name: String,
    workers: Int,
    budget: Optional[Int],
    spill_dir: Optional[String],
) raises -> EngineContext:
    var ctx = EngineContext(
        EngineOptions(
            worker_count=workers,
            memory_budget_bytes=budget,
            spill_directory=spill_dir,
        )
    )
    register_parquet(ctx, "t", _table_path(name))
    return ctx^


struct _Oracle(Movable):
    """Per group (index GROUPS is the NULL key): rows, values, sum, min, max."""

    var rows: List[Int]
    var values: List[Int]
    var sums: List[I128]
    var mins: List[Int]
    var maxs: List[Int]

    def __init__(out self):
        self.rows = List[Int](length=GROUPS + 1, fill=0)
        self.values = List[Int](length=GROUPS + 1, fill=0)
        self.sums = List[I128](length=GROUPS + 1, fill=I128(0))
        self.mins = List[Int](length=GROUPS + 1, fill=0)
        self.maxs = List[Int](length=GROUPS + 1, fill=0)
        for i in range(ROWS):
            var g = GROUPS if _k_null(i) else i % GROUPS
            self.rows[g] += 1
            if _v_null(i):
                continue
            var v = _v(i)
            if self.values[g] == 0:
                self.mins[g] = v
                self.maxs[g] = v
            else:
                self.mins[g] = min(self.mins[g], v)
                self.maxs[g] = max(self.maxs[g], v)
            self.values[g] += 1
            self.sums[g] += Scalar[DType.int64](v).cast[DType.int128]()

    def groups(self) -> Int:
        var n = 0
        for g in range(GROUPS + 1):
            if self.rows[g] > 0:
                n += 1
        return n


def _check(ref out: RecordBatch, ref want: _Oracle) raises:
    assert_equal(out.num_rows(), want.groups(), "number of groups")
    assert_true(out.schema.field_arrow_type(2) == ArrowType.DECIMAL128)
    var seen = List[Bool](length=GROUPS + 1, fill=False)
    var keys = out.column_at(0).as_primitive[DType.int64]()
    var counts = out.column_at(1).as_primitive[DType.int64]()
    var sums = out.column_at(2).as_decimal128()
    var mins = out.column_at(3).as_primitive[DType.int64]()
    var maxs = out.column_at(4).as_primitive[DType.int64]()
    for r in range(out.num_rows()):
        var g = GROUPS
        if not out.column_at(0).is_null_at(r):
            g = Int(keys.get(r))
            assert_true(g >= 0 and g < GROUPS, "unexpected key " + String(g))
        assert_false(seen[g], "group " + String(g) + " twice")
        seen[g] = True
        assert_equal(Int(counts.get(r)), want.rows[g], "count of " + String(g))
        var none = want.values[g] == 0
        for c in range(2, 5):
            assert_equal(out.column_at(c).is_null_at(r), none, "NULL-ness")
        if not none:
            assert_true(sums.get_i128(r) == want.sums[g], "sum of " + String(g))
            assert_equal(Int(mins.get(r)), want.mins[g], "min of " + String(g))
            assert_equal(Int(maxs.get(r)), want.maxs[g], "max of " + String(g))


def _answer(mut ctx: EngineContext, sql: String) raises -> RecordBatch:
    var out = run_sql(ctx, sql)
    if out.refusal:
        assert_true(
            False,
            "refused at "
            + out.refusal.value().step
            + ": "
            + out.refusal.value().reason,
        )
    assert_equal(len(out.batches), 1)
    return out.batches.pop(0)


def test_a_group_by_over_the_budget_spills_and_answers_as_without_one() raises:
    var want = _Oracle()
    assert_true(want.rows[GROUPS] > 0, "the table has no NULL key")
    for workers in range(1, 3):
        var unbounded = _context("unbounded", workers, None, None)
        _check(_answer(unbounded, QUERY), want)
        var dir = test_tmpdir() + "/sql_spill_w" + String(workers)
        var spilling = _context("spilling", workers, BUDGET, dir)
        _check(_answer(spilling, QUERY), want)
        assert_true(exists(dir), "the query did not spill")
        assert_equal(len(listdir(dir)), 0, "spill files left behind")


def test_the_same_budget_without_a_spill_directory_is_refused_at_execute() raises:
    var ctx = _context("no_dir", 1, BUDGET, None)
    var out = run_sql(ctx, QUERY)
    assert_true(out.refusal, "the query fit the budget without a spill")
    assert_equal(out.refusal.value().step, String(STEP_EXECUTE))
    assert_true(
        out.refusal.value().reason.find(
            "the grouped aggregation sink of segment"
        )
        >= 0,
        out.refusal.value().reason,
    )
    assert_true(out.refusal.value().reason.find("was denied") >= 0)
    assert_true(
        out.refusal.value().reason.startswith(
            "[Processor] MEMORY_BUDGET_EXCEEDED: "
        ),
        out.refusal.value().reason,
    )


def test_a_query_that_fits_the_budget_writes_nothing() raises:
    var dir = test_tmpdir() + "/sql_spill_unused"
    var ctx = _context("fits", 2, BUDGET, dir)
    var out = _answer(ctx, "select count(*) from t")
    assert_equal(
        Int(out.column_at(0).as_primitive[DType.int64]().get(0)), ROWS
    )
    var few = _answer(ctx, "select k, count(*) from t where k < 10 group by k")
    assert_equal(few.num_rows(), 10)
    assert_false(exists(dir), "a query that fits created the spill directory")


def test_an_empty_spill_directory_is_refused_when_the_context_is_made() raises:
    var said = String("")
    try:
        _ = EngineContext(EngineOptions(spill_directory=String("")))
    except e:
        said = String(e)
    assert_equal(said, "ENGINE_OPTIONS_INVALID: spill_directory must not be empty")


def test_a_spill_directory_that_cannot_be_made_fails_the_query_at_execute() raises:
    var file = test_tmpdir() + "/sql_spill_a_file"
    var fh = open(file, "w")
    fh.write("not a directory")
    fh.close()
    var ctx = _context("bad_dir", 1, BUDGET, file + "/spill")
    var out = run_sql(ctx, QUERY)
    assert_true(out.refusal, "a spill under a regular file succeeded")
    assert_equal(out.refusal.value().step, String(STEP_EXECUTE))
    var next = _answer(ctx, "select count(*) from t")
    assert_equal(
        Int(next.column_at(0).as_primitive[DType.int64]().get(0)), ROWS
    )


def main() raises:
    var suite = TestSuite()
    suite.test[test_a_group_by_over_the_budget_spills_and_answers_as_without_one]()
    suite.test[test_the_same_budget_without_a_spill_directory_is_refused_at_execute]()
    suite.test[test_a_query_that_fits_the_budget_writes_nothing]()
    suite.test[test_an_empty_spill_directory_is_refused_when_the_context_is_made]()
    suite.test[test_a_spill_directory_that_cannot_be_made_fails_the_query_at_execute]()
    suite^.run()
