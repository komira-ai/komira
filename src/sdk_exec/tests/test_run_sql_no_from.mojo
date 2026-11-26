# =============================================================================
# run_sql: a SELECT with no FROM, and plans that scan an in-memory batch
# =============================================================================
#
# Covers: SELECT 1 AS n is one row, an INT32 column n holding 1, as in DuckDB;
# a result literal is INT32 from -2147483647 to 2147483647 and INT64 past
# either bound and at -2147483648, as DuckDB types it; one past BIGINT is
# refused at bind; a literal a derived table holds stays INT64 (n + 5000000000
# over a derived `1 AS n` is the INT64 5000000001) and a UNION ALL of literals
# (SELECT 1 AS n UNION ALL SELECT 2) binds to INT32; FROM-less expressions (7 /
# 2), count(*) and a false WHERE run; SELECT 1 FROM a Parquet table; in-memory
# sources: one of two batches is read whole and one of none gives no rows with
# its schema.
#
# A FROM-less SELECT reads the binder's one-row in-memory relation, so its plan
# carries the batch in `params.batches` and `run_lowered_plan` hands it to the
# builder as a resident batch. The expected answers are DuckDB's for the
# same SQL: `SELECT 1 AS n` is one row, a column `n` of type INTEGER holding 1.
#
# What each test proves:
#   * test_select_1_as_n_is_one_int32_row: one batch, one row, one column `n`,
#     INT32, value 1, not NULL. Catches the in-memory scan being refused at
#     execute, and the result literal being typed BIGINT.
#   * test_int32_range_bounds_of_a_result_literal: 2147483647, -1 and
#     -2147483647 are INT32; 2147483648, -2147483648 (DuckDB negates the
#     BIGINT 2147483648) and -2147483649 are INT64 with their exact values. A
#     literal past BIGINT is still refused at bind. Catches an off-by-one on
#     either bound and a truncated value.
#   * test_a_from_less_expression_and_count: `SELECT 7 / 2` is the DOUBLE 3.5
#     and `SELECT count(*)` is the BIGINT 1: the one-row relation feeds a
#     project and an aggregate sink.
#   * test_a_false_where_gives_no_rows: `SELECT 1 AS n WHERE 1 = 0` is a batch
#     of no rows whose column is still the INT32 `n`.
#   * test_a_derived_literal_stays_bigint: in
#     `SELECT n + 5000000000 AS s FROM (SELECT 1 AS n) d` the inner literal is
#     not the result, so it stays BIGINT and the sum is the BIGINT 5000000001.
#     Catches the INT32 type leaking into a literal another expression reads
#     (a binary operator takes its left operand's type, which would wrap).
#   * test_union_all_of_literals_still_binds: `SELECT 1 AS n UNION ALL
#     SELECT 2` binds to one INT32 column `n`, DuckDB's INTEGER. Catches the
#     branches' literals taking INT64.
#   * test_a_literal_over_a_parquet_table: `SELECT 1 AS one FROM t` over a
#     five-row Parquet file is five INT32 ones.
#   * test_the_context_runs_on_after_from_less_queries: a FROM-less query, a
#     Parquet query and a FROM-less query again on one context.
#   * test_a_multi_batch_in_memory_scan_is_read_whole: a scan of an in-memory
#     source of two batches (2 and 3 rows), lowered and run with
#     run_lowered_plan, gives all five rows. Catches reading only the first
#     batch of a source.
#   * test_an_empty_in_memory_scan_gives_no_rows: a source of no batches gives
#     a batch of no rows with the source's schema.

from std.memory import ArcPointer
from std.testing import TestSuite, assert_equal, assert_true, assert_false

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
from containers.slab import Slab
from lowering.lower import lower
from lowering.lowered_plan import LoweringInputs
from parquet_writer.record_batch_writer import (
    write_record_batch_to_parquet_bytes,
)
from plan_ir.logical_plan import LogicalPlan
from runtime_paths import test_tmpdir
from scan_source.in_memory_source import InMemorySource
from scan_source.source_variant import SourceVariant
from sdk_exec.engine_catalog import register_parquet
from sdk_exec.engine_context import EngineContext
from sdk_exec.engine_execute import run_lowered_plan
from sdk_exec.engine_options import EngineOptions
from sdk_exec.engine_sql import run_sql
from sql.sql_binder import bind_statement
from sql.sql_parser import parse_sql
from sql.sql_token import tokenize


def _new_context() raises -> EngineContext:
    return EngineContext(EngineOptions(worker_count=2))


def _run(mut ctx: EngineContext, sql: String) raises -> RecordBatch:
    var out = run_sql(ctx, sql)
    if out.refusal:
        assert_true(
            False,
            "refused at "
            + out.refusal.value().step
            + ": "
            + out.refusal.value().reason
            + " -- "
            + sql,
        )
    assert_equal(len(out.batches), 1)
    return out.batches.pop(0)


def _i64_schema(name: String) -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(name, ArrowType.INT64, False))
    return sb.build()


def _i64_batch(name: String, values: List[Int]) raises -> RecordBatch:
    var arr = PrimitiveArray[DType.int64].allocate(len(values))
    for i in range(len(values)):
        arr.set(i, Scalar[DType.int64](values[i]))
    var rbb = RecordBatchBuilder()
    rbb.add_column(Column.from_primitive[DType.int64](arr^))
    return rbb.build(_i64_schema(name))


def _expect_int32(ref batch: RecordBatch, col: Int, name: String, want: Int32) raises:
    assert_equal(batch.schema.field_name(col), name)
    assert_true(
        batch.schema.field_arrow_type(col) == ArrowType.INT32,
        "column " + name + " is not INT32",
    )
    assert_false(batch.column_at(col).is_null_at(0))
    assert_equal(batch.column_at(col).as_primitive[DType.int32]().get(0), want)


def _expect_int64(ref batch: RecordBatch, col: Int, name: String, want: Int64) raises:
    assert_equal(batch.schema.field_name(col), name)
    assert_true(
        batch.schema.field_arrow_type(col) == ArrowType.INT64,
        "column " + name + " is not INT64",
    )
    assert_false(batch.column_at(col).is_null_at(0))
    assert_equal(batch.column_at(col).as_primitive[DType.int64]().get(0), want)


def _sum_i64(ref batch: RecordBatch, col: Int) raises -> Int64:
    var total = Int64(0)
    var arr = batch.column_at(col).as_primitive[DType.int64]()
    for r in range(batch.num_rows()):
        total += arr.get(r)
    return total


def test_select_1_as_n_is_one_int32_row() raises:
    var ctx = _new_context()
    var batch = _run(ctx, "SELECT 1 AS n")
    assert_equal(batch.num_rows(), 1)
    assert_equal(batch.num_columns(), 1)
    _expect_int32(batch, 0, "n", 1)


def test_int32_range_bounds_of_a_result_literal() raises:
    var ctx = _new_context()
    var batch = _run(
        ctx,
        "select 2147483647 as hi, -1 as neg, -2147483647 as lo,"
        " 2147483648 as past_hi, -2147483648 as int32_min,"
        " -2147483649 as past_lo",
    )
    assert_equal(batch.num_rows(), 1)
    assert_equal(batch.num_columns(), 6)
    _expect_int32(batch, 0, "hi", Int32.MAX)
    _expect_int32(batch, 1, "neg", -1)
    _expect_int32(batch, 2, "lo", Int32(-2147483647))
    _expect_int64(batch, 3, "past_hi", Int64(2147483648))
    _expect_int64(batch, 4, "int32_min", Int64(-2147483648))
    _expect_int64(batch, 5, "past_lo", Int64(-2147483649))
    var big = run_sql(ctx, "select 18446744073709551615 as b")
    assert_false(big.ok())
    assert_equal(big.refusal.value().step, "bind")
    assert_true(big.refusal.value().reason.find("past BIGINT") >= 0)


def test_a_from_less_expression_and_count() raises:
    var ctx = _new_context()
    var half = _run(ctx, "select 7 / 2 as q")
    assert_equal(half.num_rows(), 1)
    assert_true(half.schema.field_arrow_type(0) == ArrowType.FLOAT64)
    assert_equal(half.column_at(0).as_primitive[DType.float64]().get(0), 3.5)
    var count = _run(ctx, "select count(*) as c")
    assert_equal(count.num_rows(), 1)
    _expect_int64(count, 0, "c", 1)


def test_a_false_where_gives_no_rows() raises:
    var ctx = _new_context()
    var batch = _run(ctx, "select 1 as n where 1 = 0")
    assert_equal(batch.num_rows(), 0)
    assert_equal(batch.num_columns(), 1)
    assert_equal(batch.schema.field_name(0), "n")
    assert_true(batch.schema.field_arrow_type(0) == ArrowType.INT32)


def test_a_derived_literal_stays_bigint() raises:
    var ctx = _new_context()
    var batch = _run(ctx, "select n + 5000000000 as s from (select 1 as n) d")
    assert_equal(batch.num_rows(), 1)
    _expect_int64(batch, 0, "s", Int64(5000000001))


def test_union_all_of_literals_still_binds() raises:
    var ctx = _new_context()
    var bound = bind_statement(
        parse_sql(tokenize("select 1 as n union all select 2")),
        ctx.catalog,
        ctx.footers,
    )
    var plan = bound.take_plan()
    assert_equal(plan.output_schema.num_columns(), 1)
    assert_equal(plan.output_schema.field_name(0), "n")
    assert_true(plan.output_schema.field_arrow_type(0) == ArrowType.INT32)


def test_a_literal_over_a_parquet_table() raises:
    var ctx = _new_context()
    var values: List[Int] = [10, 20, 30, 40, 50]
    var path = test_tmpdir() + "/sql_no_from_literal.parquet"
    var bytes = write_record_batch_to_parquet_bytes(
        _i64_batch("k", values), max_rows_per_rg=2
    )
    var fh = open(path, "w")
    fh.write_bytes(Span(bytes))
    fh.close()
    register_parquet(ctx, "t", path)
    var batch = _run(ctx, "select 1 as one from t")
    assert_equal(batch.num_rows(), 5)
    assert_equal(batch.num_columns(), 1)
    assert_true(batch.schema.field_arrow_type(0) == ArrowType.INT32)
    var ones = batch.column_at(0).as_primitive[DType.int32]()
    for r in range(5):
        assert_equal(ones.get(r), Int32(1))


def test_the_context_runs_on_after_from_less_queries() raises:
    var ctx = _new_context()
    var values: List[Int] = [1, 2, 3]
    var path = test_tmpdir() + "/sql_no_from_mixed.parquet"
    var bytes = write_record_batch_to_parquet_bytes(_i64_batch("k", values))
    var fh = open(path, "w")
    fh.write_bytes(Span(bytes))
    fh.close()
    register_parquet(ctx, "t", path)
    _expect_int32(_run(ctx, "select 1 as n"), 0, "n", 1)
    var count = _run(ctx, "select count(*) as c from t")
    _expect_int64(count, 0, "c", 3)
    _expect_int32(_run(ctx, "select 2 as n"), 0, "n", 2)


def _run_scan(mut ctx: EngineContext, var src: InMemorySource) raises -> RecordBatch:
    var schema = src.schema()
    var plan = LogicalPlan.scan_from_source(SourceVariant(src^), schema^)
    var inputs = LoweringInputs()
    inputs.add_scan()
    var lowered = lower(plan, ctx.host_profile, inputs)
    assert_equal(len(lowered.params.batches), 1)
    return run_lowered_plan(ctx, lowered^)


def test_a_multi_batch_in_memory_scan_is_read_whole() raises:
    var ctx = _new_context()
    var first: List[Int] = [1, 2]
    var second: List[Int] = [30, 40, 50]
    var batches = Slab[RecordBatch]()
    batches.append(_i64_batch("v", first))
    batches.append(_i64_batch("v", second))
    var batch = _run_scan(ctx, InMemorySource.from_record_batches(batches^))
    assert_equal(batch.num_rows(), 5)
    assert_equal(batch.schema.field_name(0), "v")
    assert_equal(_sum_i64(batch, 0), Int64(123))


def test_an_empty_in_memory_scan_gives_no_rows() raises:
    var ctx = _new_context()
    var src = InMemorySource.from_shared_batches(
        ArcPointer(Slab[RecordBatch]()), _i64_schema("v")
    )
    var batch = _run_scan(ctx, src^)
    assert_equal(batch.num_rows(), 0)
    assert_equal(batch.num_columns(), 1)
    assert_equal(batch.schema.field_name(0), "v")
    assert_true(batch.schema.field_arrow_type(0) == ArrowType.INT64)


def main() raises:
    var suite = TestSuite()
    suite.test[test_select_1_as_n_is_one_int32_row]()
    suite.test[test_int32_range_bounds_of_a_result_literal]()
    suite.test[test_a_from_less_expression_and_count]()
    suite.test[test_a_false_where_gives_no_rows]()
    suite.test[test_a_derived_literal_stays_bigint]()
    suite.test[test_union_all_of_literals_still_binds]()
    suite.test[test_a_literal_over_a_parquet_table]()
    suite.test[test_the_context_runs_on_after_from_less_queries]()
    suite.test[test_a_multi_batch_in_memory_scan_is_read_whole]()
    suite.test[test_an_empty_in_memory_scan_gives_no_rows]()
    suite^.run()
