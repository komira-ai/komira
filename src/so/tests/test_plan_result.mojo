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
#   * test_refusals_name_their_step: garbage bytes are refused at `decode`; a
#     plan whose file was removed after it was built is refused at `lower`,
#     naming the file; after each the session runs a good plan. Each refusal
#     is the session's last error, word for word, with its step
#     (`KOMIRA_STEP_NONE` at `decode`, `KOMIRA_STEP_LOWER` at `lower`).
#   * test_a_write_envelope_writes_parquet: an envelope with a write target,
#     Parquet uncompressed and Parquet snappy, answers one batch of one NOT
#     NULL INT64 column `Count` holding the rows written; the file read back
#     on a fresh session has the plan's rows and column name.
#   * test_a_plan_write_writes_the_bytes_copy_writes: CSV (uncompressed and
#     gzip) and JSON lines (uncompressed): the file the plan door writes is
#     byte-equal to the file the SQL door's `COPY (...) TO` writes for the
#     same query, format and compression.
#   * test_a_refused_write_touches_no_file: a destination URL is refused at
#     `bind` (`STORAGE_URL_REFUSED`) and a destination in a directory that
#     does not exist at `execute` (`STORAGE_NOT_FOUND`), each recorded on the
#     session with its step and code; CSV with lz4 is refused at `bind`
#     (`COPY_COMPRESSION_UNSUPPORTED`) and the existing file at its
#     destination keeps its bytes; after each the session runs a good plan.
#     JSON lines with lz4 is refused at `bind` the same way; a write whose
#     plan is refused at `lower` (its file removed after the plan was built)
#     also leaves the destination's bytes; neither the URL nor the missing
#     directory is created.
#   * test_a_write_replaces_its_destination: a second write to one path
#     replaces the first file with the second plan's rows.
#   * test_an_envelope_with_udfs_is_refused_at_decode: an envelope with one
#     `UdfRef` is refused at `decode` with `PLAN_WIRE_UDFS_DROPPED`, word for
#     word, step `KOMIRA_STEP_NONE`; the same envelope with a write target is
#     refused the same way and writes no file; the session then runs a good
#     plan.
from std.os import remove
from std.os.path import exists
from std.testing import TestSuite, assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.primitive_array import PrimitiveArray
from arrow.schema import Field, RecordBatchBuilder, SchemaBuilder
from arrow.write_target import (
    WCOMP_GZIP,
    WCOMP_LZ4,
    WCOMP_SNAPPY,
    WCOMP_UNCOMPRESSED,
    WFMT_CSV,
    WFMT_JSONL,
    WFMT_PARQUET,
    WriteTarget,
)
from fs.atomic_write import STORAGE_NOT_FOUND
from parquet_writer.record_batch_writer import (
    write_record_batch_to_parquet_bytes,
)
from plan_expr.expr import Expr
from plan_expr.udf_data import UDF_NULL_PROPAGATE, UDF_STABILITY_STABLE
from plan_expr.udf_type import UdfType
from plan_ir.logical_plan import ExprArray, LogicalPlan
from plan_ir.udf_ref import (
    CODE_FORM_VALUE,
    UDF_REF_KIND_SCALAR,
    CodeDigest,
    UdfCode,
    UdfRef,
)
from plan_proto.plan import WirePlanEnvelope
from plan_wire import (
    PLAN_WIRE_UDFS_DROPPED,
    plan_to_bytes,
    plan_to_bytes_with_udfs,
    plan_to_bytes_with_write_target,
)
from proto_codec import decode_proto, encode_proto
from runtime_paths import test_tmpdir
from sdk_exec.arrow_result import ArrowResult
from sdk_exec.engine_write import (
    COPY_COMPRESSION_UNSUPPORTED,
    STORAGE_URL_REFUSED,
)
from sql.sql_frontend import plan_from_sql

from so import (
    KOMIRA_STEP_BIND,
    KOMIRA_STEP_EXECUTE,
    KOMIRA_STEP_LOWER,
    KOMIRA_STEP_NONE,
    STEP_DECODE,
    Session,
    plan_result,
    register_parquet,
    sql_result,
)

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
    assert_equal(s.last_error(), decode)
    assert_equal(s.last_error_step(), KOMIRA_STEP_NONE)

    # The session runs a good plan after the refusal.
    assert_equal(len(_int64_rows(plan_result(s, good.copy()))), 3)

    remove(path)
    var lower = _message_of(s, good^)
    assert_true(lower.startswith("lower: "), "a removed file reads: " + lower)
    assert_true("plan_removed.parquet" in lower, "the refusal does not name the file: " + lower)
    assert_equal(s.last_error(), lower)
    assert_equal(s.last_error_step(), KOMIRA_STEP_LOWER)
    assert_equal(s.engine.statements_parsed, 0)


def _write_bytes(
    mut s: Session, sql: String, path: String, fmt: UInt8, codec: UInt8
) raises -> List[UInt8]:
    """The `WirePlanEnvelope` of `sql` bound against `s`'s catalog, with the
    destination `path` in format `fmt` and compression `codec`."""
    var plan = plan_from_sql(sql, s.engine.catalog, s.engine.footers)
    return plan_to_bytes_with_write_target(
        plan, WriteTarget(path, fmt, codec)
    )


def _three(mut s: Session, name: String) raises:
    """Register the three-row file as the table `three` on `s`."""
    register_parquet(
        s, String("three"), _three_row_parquet(test_tmpdir() + "/" + name)
    )


def _assert_count(result: ArrowResult, rows: Int) raises:
    """`result` is one batch of one row: the NOT NULL INT64 `Count`."""
    assert_equal(len(result.batches), 1)
    assert_equal(result.schema.num_columns(), 1)
    assert_equal(result.schema.field_name(0), String("Count"))
    assert_true(not result.schema.field_nullable(0), "Count is NOT NULL")
    var got = _int64_rows(result)
    assert_equal(len(got), 1)
    assert_equal(got[0][0], Int64(rows))


def _read(path: String) raises -> List[UInt8]:
    var fh = open(path, "r")
    var bytes = fh.read_bytes()
    fh.close()
    return bytes^


def _assert_k_rows(path: String, want: List[Int64]) raises:
    """The Parquet file at `path`, read on a fresh session, holds the column
    `k` with exactly `want`, in order."""
    var reader = Session()
    register_parquet(reader, String("back"), path)
    var result = sql_result(reader, String("select k from back order by k"))
    assert_equal(result.schema.field_name(0), String("k"))
    var got = _int64_rows(result)
    assert_equal(len(got), len(want))
    for i in range(len(want)):
        assert_equal(got[i][0], want[i])


def test_a_write_envelope_writes_parquet() raises:
    var authoring = Session()
    _three(authoring, String("plan_write_src.parquet"))
    var fresh = Session()
    var codecs = List[UInt8]()
    codecs.append(WCOMP_UNCOMPRESSED)
    codecs.append(WCOMP_SNAPPY)
    for i in range(len(codecs)):
        var path = test_tmpdir() + "/plan_write_out_" + String(i) + ".parquet"
        var bytes = _write_bytes(
            authoring,
            String("select k from three where k >= 2"),
            path,
            WFMT_PARQUET,
            codecs[i],
        )
        _assert_count(plan_result(fresh, bytes^), 2)
        var want = List[Int64]()
        want.append(2)
        want.append(3)
        _assert_k_rows(path, want)
        assert_equal(fresh.engine.statements_parsed, 0)


def test_a_plan_write_writes_the_bytes_copy_writes() raises:
    var authoring = Session()
    _three(authoring, String("plan_write_bytes_src.parquet"))
    var query = String("select k from three where k >= 2 order by k")
    var fmts = List[UInt8]()
    var codecs = List[UInt8]()
    var names = List[String]()
    var options = List[String]()
    fmts.append(WFMT_CSV)
    codecs.append(WCOMP_UNCOMPRESSED)
    names.append(String("csv"))
    options.append(String("(FORMAT csv)"))
    fmts.append(WFMT_CSV)
    codecs.append(WCOMP_GZIP)
    names.append(String("csv_gz"))
    options.append(String("(FORMAT csv, COMPRESSION gzip)"))
    fmts.append(WFMT_JSONL)
    codecs.append(WCOMP_UNCOMPRESSED)
    names.append(String("jsonl"))
    options.append(String("(FORMAT json)"))
    for i in range(len(names)):
        var by_plan = test_tmpdir() + "/plan_write_by_plan_" + names[i]
        var by_sql = test_tmpdir() + "/plan_write_by_sql_" + names[i]
        var fresh = Session()
        var bytes = _write_bytes(authoring, query, by_plan, fmts[i], codecs[i])
        _assert_count(plan_result(fresh, bytes^), 2)
        _assert_count(
            sql_result(
                authoring,
                "COPY (" + query + ") TO '" + by_sql + "' " + options[i],
            ),
            2,
        )
        var got = _read(by_plan)
        assert_true(len(got) > 0, "the plan door wrote nothing: " + names[i])
        assert_true(got == _read(by_sql), "bytes differ: " + names[i])


def test_a_refused_write_touches_no_file() raises:
    var authoring = Session()
    _three(authoring, String("plan_refused_src.parquet"))
    var good = _plan_bytes(authoring, String("select k from three"))
    var query = String("select k from three")
    var s = Session()

    var url = _message_of(
        s,
        _write_bytes(
            authoring,
            query,
            String("s3://bucket/o.parquet"),
            WFMT_PARQUET,
            WCOMP_SNAPPY,
        ),
    )
    assert_true(url.startswith("bind: " + String(STORAGE_URL_REFUSED)), url)
    assert_equal(s.last_error(), url)
    assert_equal(s.last_error_step(), KOMIRA_STEP_BIND)
    assert_equal(s.last_error_code(), String(STORAGE_URL_REFUSED))
    assert_true(not exists(String("s3:")), "a refused URL made a directory")
    assert_equal(len(_int64_rows(plan_result(s, good.copy()))), 3)

    var missing = test_tmpdir() + "/plan_no_such_dir/o.parquet"
    var gone = _message_of(
        s,
        _write_bytes(authoring, query, missing, WFMT_PARQUET, WCOMP_SNAPPY),
    )
    assert_true(
        gone.startswith("execute: " + String(STORAGE_NOT_FOUND)), gone
    )
    assert_equal(s.last_error(), gone)
    assert_equal(s.last_error_step(), KOMIRA_STEP_EXECUTE)
    assert_equal(s.last_error_code(), String(STORAGE_NOT_FOUND))
    assert_true(
        not exists(test_tmpdir() + "/plan_no_such_dir"),
        "a refused write made the missing directory",
    )
    assert_equal(len(_int64_rows(plan_result(s, good.copy()))), 3)

    var existing = test_tmpdir() + "/plan_refused_existing.csv"
    var fh = open(existing, "w")
    fh.write(String("keep me\n"))
    fh.close()
    var before = _read(existing)
    var lz4 = _message_of(
        s, _write_bytes(authoring, query, existing, WFMT_CSV, WCOMP_LZ4)
    )
    assert_true(
        lz4.startswith("bind: " + String(COPY_COMPRESSION_UNSUPPORTED)), lz4
    )
    assert_equal(s.last_error_step(), KOMIRA_STEP_BIND)
    assert_equal(s.last_error_code(), String(COPY_COMPRESSION_UNSUPPORTED))
    assert_true(_read(existing) == before, "a refused write changed the file")
    var lz4_json = _message_of(
        s, _write_bytes(authoring, query, existing, WFMT_JSONL, WCOMP_LZ4)
    )
    assert_true(
        lz4_json.startswith("bind: " + String(COPY_COMPRESSION_UNSUPPORTED)),
        lz4_json,
    )
    assert_true(_read(existing) == before, "a refused JSON write changed the file")
    assert_equal(len(_int64_rows(plan_result(s, good.copy()))), 3)

    # A plan refused after `bind` (its file removed once it was built, so
    # `lower` refuses) leaves the destination as it was.
    var src = _three_row_parquet(test_tmpdir() + "/plan_refused_late_src.parquet")
    var late = Session()
    register_parquet(late, String("late"), src)
    var doomed = _write_bytes(late, String("select k from late"), existing, WFMT_CSV, WCOMP_UNCOMPRESSED)
    remove(src)
    var lowered = _message_of(s, doomed^)
    assert_true(lowered.startswith("lower: "), lowered)
    assert_equal(s.last_error_step(), KOMIRA_STEP_LOWER)
    assert_true(_read(existing) == before, "a write refused at lower changed the file")
    assert_equal(len(_int64_rows(plan_result(s, good^))), 3)


def test_a_write_replaces_its_destination() raises:
    var authoring = Session()
    _three(authoring, String("plan_replace_src.parquet"))
    var path = test_tmpdir() + "/plan_replace_out.parquet"
    var fresh = Session()
    _assert_count(
        plan_result(
            fresh,
            _write_bytes(
                authoring,
                String("select k from three"),
                path,
                WFMT_PARQUET,
                WCOMP_SNAPPY,
            ),
        ),
        3,
    )
    _assert_count(
        plan_result(
            fresh,
            _write_bytes(
                authoring,
                String("select k from three where k = 2"),
                path,
                WFMT_PARQUET,
                WCOMP_SNAPPY,
            ),
        ),
        1,
    )
    var want = List[Int64]()
    want.append(2)
    _assert_k_rows(path, want)


def _udf_plan_bytes() raises -> List[UInt8]:
    """An envelope whose plan calls one scalar user function: `y = f(b)`
    over a scan of a file that does not exist, with its one `UdfRef`. The
    plan door refuses it at `decode`, before the file is read."""
    var sb = SchemaBuilder()
    sb.add_field(Field(String("a"), ArrowType.INT64, True))
    sb.add_field(Field(String("b"), ArrowType.FLOAT64, True))
    var scan = LogicalPlan.scan(
        String("/nonexistent/udf.parquet"), 0, sb.build(),
        Optional[List[String]](None), Optional[Expr](None), Optional[Int](None),
    )
    var arg = UdfType(String("x"), ArrowType.FLOAT64, Field(String("x"), ArrowType.FLOAT64, True).dtype, True)
    var ret = UdfType(String("y"), ArrowType.FLOAT64, Field(String("y"), ArrowType.FLOAT64, True).dtype, True)
    var args = List[UdfType]()
    args.append(arg^)
    var sha = List[UInt8]()
    for _ in range(32):
        sha.append(0x5A)
    var digests = List[CodeDigest]()
    digests.append(CodeDigest("payload", sha^))
    var ref = UdfRef(
        UDF_REF_KIND_SCALAR,
        UdfCode("komira/python", CODE_FORM_VALUE, "", digests^),
        args^,
        Optional(ret.copy()),
        UDF_STABILITY_STABLE,
        UDF_NULL_PROPAGATE,
        Optional[List[String]](None),
    )
    var cols = List[Expr]()
    cols.append(Expr.col_ref(String("b")))
    var exprs = ExprArray()
    exprs.append(Expr.alias(Expr.udf_apply(0, ret^, cols^), String("y")))
    var plan = LogicalPlan.project(exprs^, scan^)
    var refs = List[UdfRef]()
    refs.append(ref^)
    return plan_to_bytes_with_udfs(plan, refs)


def test_an_envelope_with_udfs_is_refused_at_decode() raises:
    var authoring = Session()
    _three(authoring, String("plan_udf_src.parquet"))
    var good = _plan_bytes(authoring, String("select k from three"))
    var s = Session()
    var want = (
        String("decode: ") + String(PLAN_WIRE_UDFS_DROPPED)
        + ": these bytes carry 1 UdfRef entries (`WirePlanEnvelope.udfs`),"
        + " and the plan door runs no user function yet"
    )
    assert_equal(_message_of(s, _udf_plan_bytes()), want)
    assert_equal(s.last_error(), want)
    assert_equal(s.last_error_step(), KOMIRA_STEP_NONE)
    assert_equal(s.last_error_code(), String(PLAN_WIRE_UDFS_DROPPED))
    assert_equal(len(_int64_rows(plan_result(s, good.copy()))), 3)

    # The same envelope with a write target is refused the same way, and
    # writes nothing.
    var dest = test_tmpdir() + "/plan_udf_never_written.csv"
    var target_env = decode_proto[WirePlanEnvelope](
        plan_to_bytes_with_write_target(
            plan_from_sql(String("select k from three"), authoring.engine.catalog, authoring.engine.footers),
            WriteTarget(dest, WFMT_CSV, WCOMP_UNCOMPRESSED),
        )
    )
    var env = decode_proto[WirePlanEnvelope](_udf_plan_bytes())
    env.format_version = target_env.format_version
    env.write_target = target_env.write_target.copy()
    assert_equal(_message_of(s, encode_proto(env)), want)
    assert_true(not exists(dest), "an envelope with UDFs wrote its file")
    assert_equal(len(_int64_rows(plan_result(s, good^))), 3)


def main() raises:
    var suite = TestSuite()
    suite.test[test_a_plan_answers_what_its_sql_answers]()
    suite.test[test_a_plan_of_no_rows_keeps_the_schema]()
    suite.test[test_a_plan_result_outlives_its_session]()
    suite.test[test_sql_text_is_not_a_plan]()
    suite.test[test_refusals_name_their_step]()
    suite.test[test_a_write_envelope_writes_parquet]()
    suite.test[test_a_plan_write_writes_the_bytes_copy_writes]()
    suite.test[test_a_refused_write_touches_no_file]()
    suite.test[test_a_write_replaces_its_destination]()
    suite.test[test_an_envelope_with_udfs_is_refused_at_decode]()
    suite^.run()
