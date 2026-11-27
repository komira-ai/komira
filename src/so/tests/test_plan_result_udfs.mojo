# plan_result for an envelope that carries UDFs: what komira_plan_stream does
# with a plan whose projection calls a user function (`y = f(k)`, one
# `UdfRef`), and komira_udf_runtime_set (`set_udf_runtime`) on values.
#
# The UDFs are fixtures of komira-test/echo, the reference runtime of the
# conformance suite, staged as echo.so: `double` answers 2 * k (NULL for
# NULL), `raise_on_row_3` raises on the value 3 naming its row,
# `lost_on_call` loses its context on any call, as a runtime whose worker died
# does. The file holds k = 1, NULL, 3, 4.
#
# What each test proves:
#   * test_without_a_runtime_the_door_refuses_by_name: on a session with no
#     UDF runtime the envelope is refused at `bind` with
#     OPTIMIZED_ENV_RUNTIME_MISSING, naming the UDF and its runtime, step
#     KOMIRA_STEP_BIND and that code; with a write target too, writing no
#     file; then the session runs a plan with no UDF. Catches a door that
#     drops the UDF list, or runs the plan without its UDFs.
#   * test_with_a_runtime_the_door_runs_the_udf: after set_udf_runtime the
#     same envelope answers k and y = 2 * k row for row, NULL where k is
#     NULL; a second run on the session answers the same; with a write target
#     it writes the four rows (Count 4). Catches a door that refuses an
#     admitted envelope, a UDF index lost through optimize and lower, and a
#     runtime that does not survive its first run.
#   * test_a_udf_failure_is_a_named_error_at_execute: a raise is
#     `execute: UDF_RAISED: ...` with the runtime's message and its row (the
#     value 3 is row 2 of the batch), step KOMIRA_STEP_EXECUTE and code
#     UDF_RAISED; a lost worker is `execute: UDF_WORKER_CRASHED: ...`; after
#     each the session runs the doubling plan. Catches a failure reported
#     without its code, and a session left unusable by one.
#   * test_the_runtime_refuses_a_udf_at_bind: a UDF the runtime cannot load
#     (no fixture has its entry) is refused at `bind`, before any row is
#     read, with OPTIMIZED_UDF_CODE_UNLOADABLE and the runtime's message.
#   * test_setting_a_runtime_refuses_by_name: a library that is not there is
#     UDF_RUNTIME_OPEN_FAILED, a negative deadline or an empty code root
#     UDF_RUNTIME_CONFIG_INVALID, and after either the session holds the
#     runtime it held; the option text's lines are the options, empty lines
#     skipped.
from std.os.path import exists
from std.testing import TestSuite, assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.column_builder import ColumnBuilder
from arrow.schema import Field, RecordBatchBuilder, SchemaBuilder
from arrow.write_target import WCOMP_UNCOMPRESSED, WFMT_PARQUET, WriteTarget
from parquet_writer.record_batch_writer import write_record_batch_to_parquet_bytes
from plan_expr.expr import Expr
from plan_ir.logical_plan import ExprArray, LogicalPlan
from plan_ir.udf_ref import UDF_REF_KIND_MAP_BATCHES_COLUMN, UdfRef
from plan_proto.plan import WirePlanEnvelope
from plan_wire import plan_to_bytes, plan_to_bytes_with_udfs, plan_to_bytes_with_write_target
from proto_codec import decode_proto, encode_proto
from runtime_paths import test_tmpdir
from sdk_exec.arrow_result import ArrowResult

from komira_test_udf_host.echo_udfs import ECHO_LIBRARY, echo_ref
from so import KOMIRA_STEP_BIND, KOMIRA_STEP_EXECUTE, Session, plan_result
from so.udf_runtime import runtime_options, set_udf_runtime


def _file(name: String) raises -> String:
    """A Parquet file of one nullable INT64 column `k`: 1, NULL, 3, 4."""
    var b = ColumnBuilder[DType.int64].with_capacity(0)
    b.append(1)
    b.append_null()
    b.append(3)
    b.append(4)
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k"), ArrowType.INT64, True))
    var rbb = RecordBatchBuilder()
    rbb.add_column(b^.materialize())
    var bytes = write_record_batch_to_parquet_bytes(rbb.build(sb.build()))
    var path = test_tmpdir() + "/" + name
    var fh = open(path, "w")
    fh.write_bytes(Span(bytes))
    fh.close()
    return path^


def _scan(path: String) -> LogicalPlan:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k"), ArrowType.INT64, True))
    return LogicalPlan.scan(
        path, 0, sb.build(), Optional[List[String]](None), Optional[Expr](None), Optional[Int](None)
    )


def _udf_plan(path: String, var u: UdfRef) raises -> List[UInt8]:
    """`select k, f(k) as y` over the file, with `u` the one UdfRef."""
    var cols = List[Expr]()
    cols.append(Expr.col_ref(String("k")))
    var exprs = ExprArray()
    exprs.append(Expr.col_ref(String("k")))
    exprs.append(Expr.alias(Expr.udf_apply(0, u.return_type.value().copy(), cols^), String("y")))
    var plan = LogicalPlan.project(exprs^, _scan(path))
    var refs = List[UdfRef]()
    refs.append(u^)
    return plan_to_bytes_with_udfs(plan, refs)


def _with_target(var bytes: List[UInt8], path: String, dest: String) raises -> List[UInt8]:
    """`bytes`' envelope with a Parquet write target at `dest`."""
    var target_env = decode_proto[WirePlanEnvelope](
        plan_to_bytes_with_write_target(_scan(path), WriteTarget(dest, WFMT_PARQUET, WCOMP_UNCOMPRESSED))
    )
    var env = decode_proto[WirePlanEnvelope](bytes^)
    env.format_version = target_env.format_version
    env.write_target = target_env.write_target.copy()
    return encode_proto(env)


def _rows(result: ArrowResult) raises -> String:
    """Every row of an INT64 answer, `[1 2, NULL NULL]`."""
    var out = String("[")
    for b in range(len(result.batches)):
        ref batch = result.batches[b]
        for r in range(batch.num_rows()):
            if out != "[":
                out += ", "
            for c in range(batch.num_columns()):
                if c > 0:
                    out += " "
                ref col = batch.column_at(c)
                out += "NULL" if col.is_null_at(r) else String(col.as_primitive[DType.int64]().get(r))
    return out + "]"


def _message_of(mut s: Session, var bytes: List[UInt8]) -> String:
    try:
        _ = plan_result(s, bytes^)
    except e:
        return String(e)
    return String()


def _plain(path: String) raises -> List[UInt8]:
    return plan_to_bytes(_scan(path))


def _with_echo(mut s: Session) raises:
    set_udf_runtime(s, String(ECHO_LIBRARY), test_tmpdir(), 0, String(""))


def test_without_a_runtime_the_door_refuses_by_name() raises:
    var path = _file("udf_door_none.parquet")
    var s = Session()
    var want = String(
        "bind: OPTIMIZED_ENV_RUNTIME_MISSING: UDF 0 (double, komira-test/echo) needs the runtime"
        " komira-test/echo, and this session holds no UDF runtime (komira_udf_runtime_set gives it one)"
    )
    assert_equal(_message_of(s, _udf_plan(path, echo_ref("double", 1))), want)
    assert_equal(s.last_error(), want)
    assert_equal(s.last_error_step(), KOMIRA_STEP_BIND)
    assert_equal(s.last_error_code(), String("OPTIMIZED_ENV_RUNTIME_MISSING"))
    var dest = test_tmpdir() + "/udf_door_never_written.parquet"
    assert_equal(_message_of(s, _with_target(_udf_plan(path, echo_ref("double", 1)), path, dest)), want)
    assert_true(not exists(dest), "a refused envelope with UDFs wrote its file")
    assert_equal(_rows(plan_result(s, _plain(path))), "[1, NULL, 3, 4]")


def test_with_a_runtime_the_door_runs_the_udf() raises:
    var path = _file("udf_door_runs.parquet")
    var s = Session()
    _with_echo(s)
    var result = plan_result(s, _udf_plan(path, echo_ref("double", 1)))
    assert_equal(result.schema.field_name(0), String("k"))
    assert_equal(result.schema.field_name(1), String("y"))
    assert_equal(_rows(result), "[1 2, NULL NULL, 3 6, 4 8]")
    assert_equal(_rows(plan_result(s, _udf_plan(path, echo_ref("double", 1)))), "[1 2, NULL NULL, 3 6, 4 8]")
    var dest = test_tmpdir() + "/udf_door_written.parquet"
    var count = plan_result(s, _with_target(_udf_plan(path, echo_ref("double", 1)), path, dest))
    assert_equal(_rows(count), "[4]")
    assert_true(exists(dest))


def test_a_udf_failure_is_a_named_error_at_execute() raises:
    var path = _file("udf_door_fails.parquet")
    var s = Session()
    _with_echo(s)
    var raised = _message_of(s, _udf_plan(path, echo_ref("raise_on_row_3", 1)))
    assert_equal(
        raised,
        "execute: UDF_RAISED: UDF 0 (raise_on_row_3, komira-test/echo) (ERR_RAISED): raise_on_row_3: the value 3"
        " (row 2 of the batch)",
    )
    assert_equal(s.last_error_step(), KOMIRA_STEP_EXECUTE)
    assert_equal(s.last_error_code(), String("UDF_RAISED"))
    assert_equal(_rows(plan_result(s, _udf_plan(path, echo_ref("double", 1)))), "[1 2, NULL NULL, 3 6, 4 8]")
    var lost = _message_of(
        s, _udf_plan(path, echo_ref("lost_on_call", 1, kind=UDF_REF_KIND_MAP_BATCHES_COLUMN))
    )
    assert_true(
        lost.startswith("execute: UDF_WORKER_CRASHED: UDF 0 (lost_on_call, komira-test/echo) (ERR_INSTANCE_LOST): "),
        lost,
    )
    assert_equal(s.last_error_code(), String("UDF_WORKER_CRASHED"))
    assert_equal(_rows(plan_result(s, _udf_plan(path, echo_ref("double", 1)))), "[1 2, NULL NULL, 3 6, 4 8]")


def test_the_runtime_refuses_a_udf_at_bind() raises:
    var path = _file("udf_door_unloadable.parquet")
    var s = Session()
    _with_echo(s)
    assert_equal(
        _message_of(s, _udf_plan(path, echo_ref("no_such_fixture", 1))),
        "bind: OPTIMIZED_UDF_CODE_UNLOADABLE: UDF 0 (no_such_fixture, komira-test/echo) did not load (ERR_LOAD):"
        " no code object holds the entry 'no_such_fixture'",
    )
    assert_equal(s.last_error_step(), KOMIRA_STEP_BIND)


def test_setting_a_runtime_refuses_by_name() raises:
    var s = Session()
    var got = String("set")
    try:
        set_udf_runtime(s, String("./no_such_runtime.so"), test_tmpdir(), 0, String(""))
    except e:
        got = String(e)
    assert_true(got.startswith("UDF_RUNTIME_OPEN_FAILED: ./no_such_runtime.so: "), got)
    assert_true(not s.udf_runtime, "a refused runtime was kept")
    _with_echo(s)
    var want = String(
        "UDF_RUNTIME_CONFIG_INVALID: komira_udf_runtime_set needs a library, a code root and a deadline of 0 or"
        " more milliseconds"
    )
    for case in range(2):
        got = String("set")
        try:
            if case == 0:
                set_udf_runtime(s, String(ECHO_LIBRARY), test_tmpdir(), -1, String(""))
            else:
                set_udf_runtime(s, String(ECHO_LIBRARY), String(""), 0, String(""))
        except e:
            got = String(e)
        assert_equal(got, want)
    assert_equal(s.udf_runtime.value()[].runtime_id, String("komira-test/echo"))
    var opts = runtime_options(String("a=1\n\nb=2\n"))
    assert_equal(len(opts), 2)
    assert_equal(opts[0], String("a=1"))
    assert_equal(opts[1], String("b=2"))


def main() raises:
    var suite = TestSuite()
    suite.test[test_without_a_runtime_the_door_refuses_by_name]()
    suite.test[test_with_a_runtime_the_door_runs_the_udf]()
    suite.test[test_a_udf_failure_is_a_named_error_at_execute]()
    suite.test[test_the_runtime_refuses_a_udf_at_bind]()
    suite.test[test_setting_a_runtime_refuses_by_name]()
    suite^.run()
