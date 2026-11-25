# =============================================================================
# run_plan: a logical plan run with no SQL front end
# =============================================================================
#
# Each plan is bound from SQL on one context (`plan_from_sql`, which is not the
# SQL door and counts nothing) and run by `run_plan` on a second, fresh
# context with no table registered; `run_sql` runs the same text on the first.
#
# What each test proves:
#   * test_run_plan_answers_what_run_sql_answers: a filter with a sort and an
#     aggregate over a three-row Parquet file give the rows `run_sql` gives,
#     the fresh context's `statements_parsed` stays 0 and the SQL door's goes
#     up by one per query. Catches a `run_plan` that goes through the SQL door
#     and one that needs the table registered.
#   * test_a_decoded_plan_runs: the same plan through `plan_to_bytes` and
#     `plan_from_bytes` (the envelope a client sends) gives the same rows.
#   * test_run_plan_refusal_names_its_step: a plan whose file was removed after
#     binding is refused at `lower` naming the file, and the context then
#     runs a good plan.
#   * test_a_refused_statement_is_counted: a statement the parser refuses
#     still counts as parsed, and a plan run after it does not.
from std.os import remove
from std.testing import TestSuite, assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.primitive_array import PrimitiveArray
from arrow.schema import Field, RecordBatchBuilder, SchemaBuilder
from parquet_writer.record_batch_writer import (
    write_record_batch_to_parquet_bytes,
)
from plan_ir.logical_plan import LogicalPlan
from plan_wire import plan_from_bytes, plan_to_bytes
from runtime_paths import test_tmpdir
from sdk_exec.engine_catalog import register_parquet
from sdk_exec.engine_context import EngineContext
from sdk_exec.engine_options import EngineOptions
from sdk_exec.engine_plan import STEP_LOWER, SqlOutcome, run_plan
from sdk_exec.engine_sql import STEP_PARSE, run_sql
from sql.sql_frontend import plan_from_sql


def _options() -> EngineOptions:
    return EngineOptions(worker_count=2)


def _three_row_parquet(path: String) raises -> String:
    """A Parquet file at `path` of one INT64 column `k` holding 1, 2 and 3."""
    var arr = PrimitiveArray[DType.int64].allocate(3)
    for i in range(3):
        arr.set(i, Scalar[DType.int64](i + 1))
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k"), ArrowType.INT64, False))
    var rbb = RecordBatchBuilder()
    rbb.add_column(Column.from_primitive[DType.int64](arr^))
    var bytes = write_record_batch_to_parquet_bytes(rbb.build(sb.build()))
    var fh = open(path, "w")
    fh.write_bytes(Span(bytes))
    fh.close()
    return path


def _plan(ctx: EngineContext, sql: String) raises -> LogicalPlan:
    return plan_from_sql(sql, ctx.catalog, ctx.footers)


def _rows(outcome: SqlOutcome) raises -> List[List[Int64]]:
    """Every row of `outcome` as its INT64 values; raises on a refusal."""
    if outcome.refusal:
        ref r = outcome.refusal.value()
        raise Error("refused at " + r.step + ": " + r.reason)
    var rows = List[List[Int64]]()
    for b in range(len(outcome.batches)):
        ref batch = outcome.batches[b]
        for i in range(batch.num_rows()):
            var row = List[Int64]()
            for c in range(batch.num_columns()):
                row.append(batch.column_at(c).as_primitive[DType.int64]().get(i))
            rows.append(row^)
    return rows^


def _assert_rows(got: List[List[Int64]], want: List[List[Int64]]) raises:
    assert_equal(len(got), len(want))
    for r in range(len(want)):
        assert_equal(len(got[r]), len(want[r]))
        for c in range(len(want[r])):
            assert_equal(got[r][c], want[r][c])


def test_run_plan_answers_what_run_sql_answers() raises:
    var authoring = EngineContext(_options())
    register_parquet(
        authoring, "three", _three_row_parquet(test_tmpdir() + "/run_plan_three.parquet")
    )
    var fresh = EngineContext(_options())
    var queries = List[String]()
    queries.append(String("select k from three where k >= 2 order by k desc"))
    queries.append(
        String("select count(*) as n, min(k) as lo, max(k) as hi from three")
    )
    for i in range(len(queries)):
        var by_plan = _rows(run_plan(fresh, _plan(authoring, queries[i])))
        var by_sql = _rows(run_sql(authoring, queries[i]))
        _assert_rows(by_plan, by_sql)
        assert_equal(fresh.statements_parsed, 0)
        assert_equal(authoring.statements_parsed, i + 1)
    var sorted = _rows(run_plan(fresh, _plan(authoring, queries[0])))
    assert_equal(len(sorted), 2)
    assert_equal(sorted[0][0], Int64(3))
    assert_equal(sorted[1][0], Int64(2))
    var agg = _rows(run_plan(fresh, _plan(authoring, queries[1])))
    assert_equal(len(agg), 1)
    assert_equal(agg[0][0], Int64(3))
    assert_equal(agg[0][1], Int64(1))
    assert_equal(agg[0][2], Int64(3))


def test_a_decoded_plan_runs() raises:
    var authoring = EngineContext(_options())
    register_parquet(
        authoring, "three", _three_row_parquet(test_tmpdir() + "/run_plan_wire.parquet")
    )
    var sql = String("select k from three where k <> 2 order by k")
    var bytes = plan_to_bytes(_plan(authoring, sql))
    var fresh = EngineContext(_options())
    var by_plan = _rows(run_plan(fresh, plan_from_bytes(bytes^)))
    var want = List[List[Int64]]()
    want.append([Int64(1)])
    want.append([Int64(3)])
    _assert_rows(by_plan, want)
    assert_equal(fresh.statements_parsed, 0)


def test_run_plan_refusal_names_its_step() raises:
    var authoring = EngineContext(_options())
    var path = _three_row_parquet(test_tmpdir() + "/run_plan_removed.parquet")
    register_parquet(authoring, "gone", path)
    var sql = String("select k from gone")
    var kept = _plan(authoring, sql)
    var removed = _plan(authoring, sql)
    var ctx = EngineContext(_options())
    assert_equal(len(_rows(run_plan(ctx, kept^))), 3)
    remove(path)
    var refused = run_plan(ctx, removed^)
    assert_true(not refused.ok(), "a plan over a removed file ran")
    ref r = refused.refusal.value()
    assert_equal(r.step, String(STEP_LOWER))
    assert_true("run_plan_removed.parquet" in r.reason, "the refusal does not name the file: " + r.reason)
    # The context runs a good plan after the refusal.
    var good = _three_row_parquet(test_tmpdir() + "/run_plan_after.parquet")
    register_parquet(authoring, "after", good)
    assert_equal(len(_rows(run_plan(ctx, _plan(authoring, String("select k from after"))))), 3)
    assert_equal(ctx.statements_parsed, 0)


def test_a_refused_statement_is_counted() raises:
    var ctx = EngineContext(_options())
    var refused = run_sql(ctx, String("selec 1"))
    assert_true(not refused.ok(), "a misspelt statement ran")
    assert_equal(refused.refusal.value().step, String(STEP_PARSE))
    assert_equal(ctx.statements_parsed, 1)
    register_parquet(
        ctx, "three", _three_row_parquet(test_tmpdir() + "/run_plan_counted.parquet")
    )
    assert_equal(len(_rows(run_plan(ctx, _plan(ctx, String("select k from three"))))), 3)
    assert_equal(ctx.statements_parsed, 1)


def main() raises:
    var suite = TestSuite()
    suite.test[test_run_plan_answers_what_run_sql_answers]()
    suite.test[test_a_decoded_plan_runs]()
    suite.test[test_run_plan_refusal_names_its_step]()
    suite.test[test_a_refused_statement_is_counted]()
    suite^.run()
