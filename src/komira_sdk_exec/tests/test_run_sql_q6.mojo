# =============================================================================
# run_sql over an EngineContext: TPC-H Q6 from its SQL text
# =============================================================================
#
# The query is the text of komira_bench_corpus (`tpch/q6`), unedited. The table
# is a lineitem-shaped Parquet file written here (DECIMAL(15,2) money and
# quantity, DATE32 ship date, several row groups) from
# `komira_pipeline_exec.tpch_q6`'s generator, whose first rows sit on each side
# of every predicate. The expected answers are integers computed in this file,
# row by row, from the same table (cents x cents), never from the engine.
#
# What each test proves, and the defect it catches:
#   * test_q6_text_gives_the_exact_decimal: run_sql(Q6) over the table gives one
#     batch, one row, a DECIMAL(38,4) column `revenue` equal to the integer
#     oracle; the oracle's table has rows rejected by each conjunct alone.
#     Catches a wrong bound for the DATE/INTERVAL or BETWEEN arithmetic, an
#     off-by-one on any boundary, and a float or truncated sum.
#   * test_a_join_is_refused_by_lowering: a self-join is a refusal at step
#     `lower` with the cutter's token LOWERING_UNCUTTABLE_NODE, not a crash and
#     not a wrong answer.
#   * test_a_syntax_error_is_refused_by_the_parser: step `parse`, "SQL syntax
#     error".
#   * test_an_unknown_table_and_a_missing_file_are_refused_at_bind: step
#     `bind`, naming the table / the file.
#   * test_a_statement_that_is_not_a_query_is_refused: CREATE TABLE AS stops at
#     step `bind` with STATEMENT_NOT_A_QUERY.
#   * test_the_footer_is_read_once_across_bind_and_lower: after one run_sql the
#     context's cache read the file once and served more lookups than binding
#     alone makes, for a registered table and for read_parquet. Catches
#     lowering reading its own copy of the footer.
#   * test_two_queries_on_one_context: Q6, a count(*) and Q6 again on one
#     context give the oracle's answers; every query reads the footer once.
#   * test_a_file_replaced_between_queries_is_read_again: the file is replaced
#     by one of the same schema and different rows; the next query gives the
#     new answer (not the old one), and a replacement whose schema differs from
#     the registered table is refused at step `lower`, naming the table.
#   * test_a_tiny_memory_budget_is_refused_at_execute: a budget of 1 byte denies
#     the sink its state ("was denied"), as a refusal at step `execute`.
#   * test_a_sum_past_int64_is_answered_exactly_and_the_context_runs_on: SUM of
#     three INT64 values of 2^62 is the DECIMAL(38, 0) 3 * 2^62, and Q6 then
#     runs on the same context.
#   * test_a_scalar_subquery_is_refused_by_lowering: the optimizer leaves the
#     subquery in the plan, so it is LOWERING_UNCUTTABLE_NODE at `lower`, and
#     Q6 then runs on the same context.
#   * test_a_select_without_from_is_refused_at_execute: the in-memory scan is
#     EXECUTE_UNSUPPORTED_PARAM, reached through run_sql.
#   * test_a_refusal_leaves_the_context_usable: a bind and a parse refusal, then
#     Q6 gives the oracle.
#   * test_options_are_validated: a worker count or memory budget below 1 is
#     refused; the options reach the host profile.
#   * test_contexts_can_be_created_and_dropped_repeatedly: six contexts, each
#     running Q6 three times, then dropped (the worker runtime is destroyed and
#     recreated each time). run_lowered_plan refuses a run that leaves the
#     segment pool not whole (EXECUTE_POOL_NOT_RELEASED), so each ok answer
#     here is also a pool returned to zero.

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    SchemaBuilder,
)
from komira_bench_corpus.catalog import find_query
from komira_parquet_writer.record_batch_writer import (
    write_record_batch_to_parquet_bytes,
)
from komira_pipeline_exec.tpch_q6 import (
    LineitemTable,
    Q6_DATE_FROM,
    Q6_DATE_TO,
    lineitem_batch,
    q6_table,
)
from komira_runtime_paths import test_tmpdir
from komira_scalar_arithmetic.decimal_arith import I128
from komira_parquet_footers.parquet_footers import ParquetFooters
from komira_sdk_exec.engine_catalog import register_parquet
from komira_sdk_exec.engine_context import EngineContext
from komira_sdk_exec.engine_options import EngineOptions
from komira_sdk_exec.engine_sql import (
    STATEMENT_NOT_A_QUERY,
    STEP_BIND,
    STEP_EXECUTE,
    STEP_LOWER,
    STEP_PARSE,
    SqlOutcome,
    run_sql,
)

from komira_sql.sql_binder import bind_statement
from komira_sql.sql_parser import parse_sql
from komira_sql.sql_token import tokenize


def _w(v: Int) -> I128:
    return Scalar[DType.int64](v).cast[DType.int128]()


def _write(name: String, ref t: LineitemTable) raises -> String:
    var path = test_tmpdir() + "/" + name + ".parquet"
    var bytes = write_record_batch_to_parquet_bytes(
        lineitem_batch(t, 0, t.rows()), max_rows_per_rg=100
    )
    var fh = open(path, "w")
    fh.write_bytes(Span(bytes))
    fh.close()
    return path^


struct _Oracle(Movable):
    var revenue: Int
    var by_date: Int
    var by_discount: Int
    var by_quantity: Int

    def __init__(out self):
        self.revenue = 0
        self.by_date = 0
        self.by_discount = 0
        self.by_quantity = 0


def _oracle(ref t: LineitemTable) -> _Oracle:
    """Q6 row by row. A NULL discount makes the predicate UNKNOWN (row out); a
    NULL price leaves the product NULL, which SUM skips."""
    var o = _Oracle()
    for r in range(t.rows()):
        if t.discount_null[r]:
            continue
        var date_ok = (
            t.shipdate[r] >= Q6_DATE_FROM and t.shipdate[r] < Q6_DATE_TO
        )
        var disc_ok = t.discount[r] >= 5 and t.discount[r] <= 7
        var qty_ok = t.quantity[r] < 2400
        if not date_ok and disc_ok and qty_ok:
            o.by_date += 1
        if not disc_ok and date_ok and qty_ok:
            o.by_discount += 1
        if not qty_ok and date_ok and disc_ok:
            o.by_quantity += 1
        if date_ok and disc_ok and qty_ok and not t.price_null[r]:
            o.revenue += t.price[r] * t.discount[r]
    return o^


def _keys_only(rows: Int) raises -> RecordBatch:
    """A one-column batch: l_orderkey, so a lineitem table registered with five
    columns no longer matches the file."""
    var values = List[Int]()
    for i in range(rows):
        values.append(i)
    return _keys(values)


def _keys(values: List[Int]) raises -> RecordBatch:
    var rows = len(values)
    var key = PrimitiveArray[DType.int64].allocate(rows)
    for i in range(rows):
        key.set(i, Int64(values[i]))
    var sb = SchemaBuilder()
    var builder = RecordBatchBuilder()
    sb.add_field(Field("l_orderkey", ArrowType.INT64, False))
    builder.add_column(Column.from_primitive[DType.int64](key^))
    return builder.build(sb.build())


def _q6() raises -> String:
    return find_query(String("tpch/q6")).text


def _new_context() raises -> EngineContext:
    return EngineContext(EngineOptions(worker_count=2))


def _expect_revenue(ref outcome: SqlOutcome, want: Int) raises:
    if outcome.refusal:
        assert_true(
            False,
            "refused at "
            + outcome.refusal.value().step
            + ": "
            + outcome.refusal.value().reason,
        )
    assert_equal(len(outcome.batches), 1)
    ref batch = outcome.batches[0]
    assert_equal(batch.num_rows(), 1)
    assert_equal(batch.num_columns(), 1)
    assert_equal(batch.schema.field_name(0), "revenue")
    ref col = batch.column_at(0)
    assert_equal(col.decimal_precision(), 38)
    assert_equal(col.decimal_scale(), 4)
    assert_false(col.is_null_at(0))
    assert_true(
        col.as_decimal128().get_i128(0) == _w(want),
        "revenue differs from the integer oracle",
    )


def _expect_refusal(
    ref outcome: SqlOutcome, step: String, reason_starts: String
) raises:
    assert_false(outcome.ok(), "expected a refusal")
    assert_equal(outcome.refusal.value().step, step)
    var reason = outcome.refusal.value().reason
    assert_true(
        reason.startswith(reason_starts),
        "reason '" + reason + "' does not start with '" + reason_starts + "'",
    )
    assert_equal(len(outcome.batches), 0)


def test_q6_text_gives_the_exact_decimal() raises:
    var t = q6_table(600)
    var o = _oracle(t)
    assert_true(o.revenue > 0)
    assert_true(o.by_date > 0 and o.by_discount > 0 and o.by_quantity > 0)
    var ctx = _new_context()
    register_parquet(ctx, "lineitem", _write("sql_q6", t))
    _expect_revenue(run_sql(ctx, _q6()), o.revenue)


def test_a_join_is_refused_by_lowering() raises:
    var t = q6_table(50)
    var ctx = _new_context()
    register_parquet(ctx, "lineitem", _write("sql_join", t))
    var out = run_sql(
        ctx,
        "select count(*) from lineitem a join lineitem b on a.l_orderkey ="
        " b.l_orderkey",
    )
    _expect_refusal(out, String(STEP_LOWER), "LOWERING_UNCUTTABLE_NODE")


def test_a_syntax_error_is_refused_by_the_parser() raises:
    var ctx = _new_context()
    _expect_refusal(
        run_sql(ctx, "selec sum(x) frm t"), String(STEP_PARSE), "SQL syntax error"
    )
    _expect_refusal(
        run_sql(ctx, "select 'unterminated"),
        String(STEP_PARSE),
        "SQL syntax error",
    )


def test_an_unknown_table_and_a_missing_file_are_refused_at_bind() raises:
    var ctx = _new_context()
    var out = run_sql(ctx, "select count(*) from nowhere")
    _expect_refusal(out, String(STEP_BIND), "")
    assert_true(out.refusal.value().reason.find("nowhere") >= 0)
    var missing = test_tmpdir() + "/sql_no_such_file.parquet"
    var out2 = run_sql(ctx, "select count(*) from read_parquet('" + missing + "')")
    _expect_refusal(out2, String(STEP_BIND), "")
    assert_true(out2.refusal.value().reason.find("sql_no_such_file") >= 0)


def test_a_statement_that_is_not_a_query_is_refused() raises:
    var t = q6_table(20)
    var ctx = _new_context()
    register_parquet(ctx, "lineitem", _write("sql_ctas", t))
    _expect_refusal(
        run_sql(ctx, "create table copy_of as select l_orderkey from lineitem"),
        String(STEP_BIND),
        String(STATEMENT_NOT_A_QUERY),
    )


def _bind_only_lookups(ctx: EngineContext, text: String, path: String) raises -> Int:
    """The cache lookups of `path` that binding `text` alone makes, on a reader
    of its own."""
    var footers = ParquetFooters()
    _ = bind_statement(parse_sql(tokenize(text)), ctx.catalog, footers)
    return footers.cache().lookup_count(path)


def _check_one_read_shared(
    mut ctx: EngineContext, text: String, path: String, want: Int
) raises:
    var by_bind = _bind_only_lookups(ctx, text, path)
    _expect_revenue(run_sql(ctx, text), want)
    # One read from storage in all, and more lookups than the binder makes:
    # the rest are lowering's, served by the binder's cache.
    assert_equal(ctx.footers.cache().read_count(), 1)
    assert_true(ctx.footers.cache().lookup_count(path) > by_bind)


def test_the_footer_is_read_once_across_bind_and_lower() raises:
    var t = q6_table(300)
    var o = _oracle(t)
    var path = _write("sql_once", t)
    var ctx = _new_context()
    register_parquet(ctx, "lineitem", path)
    _check_one_read_shared(ctx, _q6(), path, o.revenue)
    # read_parquet: the binder reads the footer, lowering reuses it.
    var text = _q6().replace("lineitem", "read_parquet('" + path + "')")
    var ctx2 = _new_context()
    _check_one_read_shared(ctx2, text, path, o.revenue)


def test_two_queries_on_one_context() raises:
    var t = q6_table(400)
    var o = _oracle(t)
    var ctx = _new_context()
    register_parquet(ctx, "lineitem", _write("sql_two", t))
    _expect_revenue(run_sql(ctx, _q6()), o.revenue)
    assert_equal(ctx.footers.cache().read_count(), 1)
    var counted = run_sql(ctx, "select count(*) from lineitem")
    assert_true(counted.ok())
    assert_equal(
        Int(counted.batches[0].column_at(0).as_primitive[DType.int64]().get(0)),
        t.rows(),
    )
    assert_equal(ctx.footers.cache().read_count(), 1)
    _expect_revenue(run_sql(ctx, _q6()), o.revenue)
    assert_equal(ctx.footers.cache().read_count(), 1)


def test_a_file_replaced_between_queries_is_read_again() raises:
    var first = q6_table(300)
    var second = q6_table(150)
    var want_first = _oracle(first).revenue
    var want_second = _oracle(second).revenue
    assert_true(want_first != want_second)
    var path = _write("sql_replaced", first)
    var ctx = _new_context()
    register_parquet(ctx, "lineitem", path)
    _expect_revenue(run_sql(ctx, _q6()), want_first)
    # Same schema, different rows: the next query reads the new file.
    _ = _write("sql_replaced", second)
    _expect_revenue(run_sql(ctx, _q6()), want_second)
    assert_equal(ctx.footers.cache().read_count(), 1)
    # A different schema: refused, naming the table, before anything runs.
    var narrow = test_tmpdir() + "/sql_replaced.parquet"
    var bytes = write_record_batch_to_parquet_bytes(
        _keys_only(second.rows()), max_rows_per_rg=100
    )
    var fh = open(narrow, "w")
    fh.write_bytes(Span(bytes))
    fh.close()
    var out = run_sql(ctx, _q6())
    _expect_refusal(out, String(STEP_LOWER), "")
    assert_true(out.refusal.value().reason.find("lineitem") >= 0)


def test_a_tiny_memory_budget_is_refused_at_execute() raises:
    var t = q6_table(100)
    var ctx = EngineContext(
        EngineOptions(worker_count=2, memory_budget_bytes=1)
    )
    register_parquet(ctx, "lineitem", _write("sql_budget", t))
    var out = run_sql(ctx, _q6())
    _expect_refusal(out, String(STEP_EXECUTE), "")
    assert_true(out.refusal.value().reason.find("was denied") >= 0)


def test_a_sum_past_int64_is_answered_exactly_and_the_context_runs_on() raises:
    var t = q6_table(200)
    var o = _oracle(t)
    var ctx = _new_context()
    register_parquet(ctx, "lineitem", _write("sql_over_q6", t))
    # Three INT64 values of 2^62 sum past 2^63: the sum is DECIMAL(38, 0).
    var big = List[Int]()
    for _ in range(3):
        big.append(1 << 62)
    var path = test_tmpdir() + "/sql_over_big.parquet"
    var bytes = write_record_batch_to_parquet_bytes(_keys(big))
    var fh = open(path, "w")
    fh.write_bytes(Span(bytes))
    fh.close()
    register_parquet(ctx, "big", path)
    var out = run_sql(ctx, "select sum(l_orderkey) from big")
    assert_true(out.ok(), "the sum was refused")
    assert_equal(len(out.batches), 1)
    ref col = out.batches[0].column_at(0)
    assert_equal(col.decimal_precision(), 38)
    assert_equal(col.decimal_scale(), 0)
    assert_false(col.is_null_at(0))
    # 3 * 2^62 = 13835058055282163712.
    assert_true(
        col.as_decimal128().get_i128(0) == _w(1 << 62) * _w(3),
        "the sum differs from 3 * 2^62",
    )
    _expect_revenue(run_sql(ctx, _q6()), o.revenue)


def test_a_scalar_subquery_is_refused_by_lowering() raises:
    var t = q6_table(100)
    var o = _oracle(t)
    var ctx = _new_context()
    register_parquet(ctx, "lineitem", _write("sql_scalar", t))
    var out = run_sql(
        ctx,
        "select count(*) from lineitem where l_quantity < (select"
        " max(l_quantity) from lineitem)",
    )
    _expect_refusal(out, String(STEP_LOWER), "LOWERING_UNCUTTABLE_NODE")
    _expect_revenue(run_sql(ctx, _q6()), o.revenue)


def test_a_select_without_from_is_refused_at_execute() raises:
    var ctx = _new_context()
    _expect_refusal(
        run_sql(ctx, "select 1 + 1"),
        String(STEP_EXECUTE),
        "EXECUTE_UNSUPPORTED_PARAM",
    )


def test_a_refusal_leaves_the_context_usable() raises:
    var t = q6_table(120)
    var o = _oracle(t)
    var ctx = _new_context()
    register_parquet(ctx, "lineitem", _write("sql_after", t))
    assert_false(run_sql(ctx, "select * from nowhere").ok())
    assert_false(run_sql(ctx, "selec").ok())
    _expect_revenue(run_sql(ctx, _q6()), o.revenue)


def test_options_are_validated() raises:
    var refused = False
    try:
        _ = EngineContext(EngineOptions(worker_count=0))
    except e:
        refused = String(e).startswith("ENGINE_OPTIONS_INVALID")
    assert_true(refused)
    refused = False
    try:
        _ = EngineContext(EngineOptions(memory_budget_bytes=0))
    except e:
        refused = String(e).startswith("ENGINE_OPTIONS_INVALID")
    assert_true(refused)
    var ctx = EngineContext(
        EngineOptions(worker_count=3, memory_budget_bytes=1 << 30)
    )
    assert_equal(ctx.host_profile.thread_count, 3)
    assert_equal(ctx.host_profile.memory_budget_bytes, 1 << 30)


def test_contexts_can_be_created_and_dropped_repeatedly() raises:
    var t = q6_table(250)
    var o = _oracle(t)
    var path = _write("sql_cycles", t)
    for _ in range(6):
        var ctx = _new_context()
        register_parquet(ctx, "lineitem", path)
        for _ in range(3):
            _expect_revenue(run_sql(ctx, _q6()), o.revenue)


def main() raises:
    var suite = TestSuite()
    suite.test[test_q6_text_gives_the_exact_decimal]()
    suite.test[test_a_join_is_refused_by_lowering]()
    suite.test[test_a_syntax_error_is_refused_by_the_parser]()
    suite.test[test_an_unknown_table_and_a_missing_file_are_refused_at_bind]()
    suite.test[test_a_statement_that_is_not_a_query_is_refused]()
    suite.test[test_the_footer_is_read_once_across_bind_and_lower]()
    suite.test[test_two_queries_on_one_context]()
    suite.test[test_a_file_replaced_between_queries_is_read_again]()
    suite.test[test_a_tiny_memory_budget_is_refused_at_execute]()
    suite.test[test_a_sum_past_int64_is_answered_exactly_and_the_context_runs_on]()
    suite.test[test_a_scalar_subquery_is_refused_by_lowering]()
    suite.test[test_a_select_without_from_is_refused_at_execute]()
    suite.test[test_a_refusal_leaves_the_context_usable]()
    suite.test[test_options_are_validated]()
    suite.test[test_contexts_can_be_created_and_dropped_repeatedly]()
    suite^.run()
