# plan_result: what komira_plan_stream does on values.
#
# Each plan is built the way a client builds one, then serialized as a
# `WirePlanEnvelope` (`plan_to_bytes`): from SQL bound on one session
# (`plan_from_sql`, which runs no session's SQL door), then decoded and run by
# `plan_result` on a second, fresh session that has no table registered.
#
# What each test proves:
#   * test_a_plan_answers_what_its_sql_answers: a filter and a sort, and an
#     aggregate (count, min, max), over a three-row Parquet file: the plan's
#     answer on the fresh session has the SQL answer's column names, rows and
#     values, and the fresh session parsed no SQL statement while the SQL
#     door's session parsed one per query. Catches a plan door that renders
#     the plan to SQL and runs it through the SQL door, and one that needs the
#     table registered.
#   * test_a_plan_of_no_rows_keeps_the_schema: a scan of the no-row fixture is
#     one batch of no rows with the file's two columns.
#   * test_a_plan_result_outlives_its_session: the batches are whole after the
#     session that ran the plan is dropped.
#   * test_sql_text_is_not_a_plan: the bytes of `SELECT 1 AS n` are refused at
#     `decode` and parse no statement: the door never falls back to SQL.
#   * test_refusals_name_their_step: garbage bytes and an envelope with a
#     write target (`PLAN_WIRE_WRITE_TARGET_DROPPED`) are refused at
#     `decode`; a plan whose file was removed after it was built is refused at
#     `lower`, naming the file; after each the session runs a good plan.
from std.os import remove
from std.testing import TestSuite, assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.primitive_array import PrimitiveArray
from arrow.schema import Field, RecordBatchBuilder, SchemaBuilder
from arrow.write_target import WCOMP_UNCOMPRESSED, WFMT_PARQUET, WriteTarget
from parquet_writer.record_batch_writer import (
    write_record_batch_to_parquet_bytes,
)
from plan_wire import (
    PLAN_WIRE_WRITE_TARGET_DROPPED,
    plan_to_bytes,
    plan_to_bytes_with_write_target,
)
from runtime_paths import test_tmpdir
from sdk_exec.arrow_result import ArrowResult
from sql.sql_frontend import plan_from_sql

from so import STEP_DECODE, Session, plan_result, register_parquet, sql_result

comptime PARQUET = "src/so/tests/fixtures/two_columns.parquet"


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


def _plan_bytes(mut s: Session, sql: String) raises -> List[UInt8]:
    """The `WirePlanEnvelope` of `sql` bound against `s`'s catalog."""
    var plan = plan_from_sql(sql, s.engine.catalog, s.engine.footers)
    return plan_to_bytes(plan)


def _int64_rows(result: ArrowResult) raises -> List[List[Int64]]:
    """Every row of `result` as its INT64 values, in answer order."""
    var rows = List[List[Int64]]()
    for b in range(len(result.batches)):
        ref batch = result.batches[b]
        for r in range(batch.num_rows()):
            var row = List[Int64]()
            for c in range(batch.num_columns()):
                row.append(batch.column_at(c).as_primitive[DType.int64]().get(r))
            rows.append(row^)
    return rows^


def _assert_same_answer(plan: ArrowResult, sql: ArrowResult) raises:
    assert_equal(plan.schema.num_columns(), sql.schema.num_columns())
    for c in range(sql.schema.num_columns()):
        assert_equal(plan.schema.field_name(c), sql.schema.field_name(c))
    var got = _int64_rows(plan)
    var want = _int64_rows(sql)
    assert_equal(len(got), len(want))
    for r in range(len(want)):
        assert_equal(len(got[r]), len(want[r]))
        for c in range(len(want[r])):
            assert_equal(got[r][c], want[r][c])


def _message_of(mut s: Session, var bytes: List[UInt8]) -> String:
    """The message `plan_result` raises for `bytes`, or empty when it answers."""
    try:
        _ = plan_result(s, bytes^)
    except e:
        return String(e)
    return String()


def test_a_plan_answers_what_its_sql_answers() raises:
    var authoring = Session()
    register_parquet(
        authoring,
        String("three"),
        _three_row_parquet(test_tmpdir() + "/plan_three.parquet"),
    )
    var fresh = Session()
    var queries = List[String]()
    queries.append(String("select k from three where k >= 2 order by k desc"))
    queries.append(
        String("select count(*) as n, min(k) as lo, max(k) as hi from three")
    )
    for i in range(len(queries)):
        var by_plan = plan_result(fresh, _plan_bytes(authoring, queries[i]))
        var by_sql = sql_result(authoring, queries[i])
        _assert_same_answer(by_plan, by_sql)
        assert_equal(fresh.engine.statements_parsed, 0)
        assert_equal(authoring.engine.statements_parsed, i + 1)
    # The answers themselves, so two equal wrong answers do not pass.
    var sorted = _int64_rows(plan_result(fresh, _plan_bytes(authoring, queries[0])))
    assert_equal(len(sorted), 2)
    assert_equal(sorted[0][0], Int64(3))
    assert_equal(sorted[1][0], Int64(2))
    var agg = _int64_rows(plan_result(fresh, _plan_bytes(authoring, queries[1])))
    assert_equal(len(agg), 1)
    assert_equal(agg[0][0], Int64(3))
    assert_equal(agg[0][1], Int64(1))
    assert_equal(agg[0][2], Int64(3))
    assert_equal(len(fresh.engine.tables), 0)


def test_a_plan_of_no_rows_keeps_the_schema() raises:
    var authoring = Session()
    var bytes = _plan_bytes(
        authoring,
        String("select i64, s from read_parquet('") + PARQUET + String("')"),
    )
    var fresh = Session()
    var result = plan_result(fresh, bytes^)
    assert_equal(result.schema.num_columns(), 2)
    assert_equal(result.schema.field_name(0), String("i64"))
    assert_equal(result.schema.field_name(1), String("s"))
    assert_equal(len(result.batches), 1)
    assert_equal(result.batches[0].num_rows(), 0)


def _run_on_a_dropped_session(var bytes: List[UInt8]) raises -> ArrowResult:
    """`plan_result` on a session that is dropped when this returns."""
    var fresh = Session()
    var result = plan_result(fresh, bytes^)
    _ = fresh^
    return result^


def test_a_plan_result_outlives_its_session() raises:
    var authoring = Session()
    register_parquet(
        authoring,
        String("three"),
        _three_row_parquet(test_tmpdir() + "/plan_outlives.parquet"),
    )
    var bytes = _plan_bytes(authoring, String("select k from three order by k"))
    var result = _run_on_a_dropped_session(bytes^)
    var rows = _int64_rows(result)
    assert_equal(len(rows), 3)
    for i in range(3):
        assert_equal(rows[i][0], Int64(i + 1))


def test_sql_text_is_not_a_plan() raises:
    var s = Session()
    var text = String("SELECT 1 AS n")
    var bytes = List[UInt8]()
    for b in text.as_bytes():
        bytes.append(b)
    var message = _message_of(s, bytes^)
    assert_true(
        message.startswith(String(STEP_DECODE) + ": "),
        "SQL text as plan bytes reads: " + message,
    )
    assert_equal(s.engine.statements_parsed, 0)


def test_refusals_name_their_step() raises:
    var authoring = Session()
    var path = _three_row_parquet(test_tmpdir() + "/plan_removed.parquet")
    register_parquet(authoring, String("gone"), path)
    var good = _plan_bytes(authoring, String("select k from gone"))
    var s = Session()

    var garbage = List[UInt8]()
    garbage.append(UInt8(0xFF))
    garbage.append(UInt8(0x00))
    var decode = _message_of(s, garbage^)
    assert_true(decode.startswith("decode: "), "garbage bytes read: " + decode)

    var plan = plan_from_sql(
        String("select k from gone"), authoring.engine.catalog, authoring.engine.footers
    )
    var write = plan_to_bytes_with_write_target(
        plan,
        WriteTarget(
            test_tmpdir() + "/never_written.parquet", WFMT_PARQUET, WCOMP_UNCOMPRESSED
        ),
    )
    var dropped = _message_of(s, write^)
    assert_true(
        dropped.startswith(
            String("decode: ") + String(PLAN_WIRE_WRITE_TARGET_DROPPED)
        ),
        "a write envelope reads: " + dropped,
    )

    # The session runs a good plan after each refusal.
    assert_equal(len(_int64_rows(plan_result(s, good.copy()))), 3)

    remove(path)
    var lower = _message_of(s, good^)
    assert_true(lower.startswith("lower: "), "a removed file reads: " + lower)
    assert_true("plan_removed.parquet" in lower, "the refusal does not name the file: " + lower)
    assert_equal(s.engine.statements_parsed, 0)


def main() raises:
    var suite = TestSuite()
    suite.test[test_a_plan_answers_what_its_sql_answers]()
    suite.test[test_a_plan_of_no_rows_keeps_the_schema]()
    suite.test[test_a_plan_result_outlives_its_session]()
    suite.test[test_sql_text_is_not_a_plan]()
    suite.test[test_refusals_name_their_step]()
    suite^.run()
