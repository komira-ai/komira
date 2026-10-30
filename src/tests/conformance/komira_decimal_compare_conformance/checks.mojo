"""The checks of the decimal compare tests: each reads DuckDB's answers from
the .tsv files its test declares and runs the SQL through `run_sql`. The tests
are separate files so the farm runs them as separate actions."""

from std.pathlib import Path
from std.testing import assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import RecordBatch
from komira_lowering.render import render_lowered_plan
from komira_optimizer.optimizer_config import OptimizerConfig
from komira_optimizer.optimizer_driver import optimize
from komira_optimizer.optimizer_scalar_deps import ScalarDepTable
from komira_runtime_paths import data_path
from komira_sdk_exec.engine_catalog import register_parquet
from komira_sdk_exec.engine_context import EngineContext
from komira_sdk_exec.engine_lower import lower_for_context
from komira_sdk_exec.engine_options import EngineOptions
from komira_sdk_exec.engine_sql import SqlOutcome, run_sql
from komira_sql.sql_binder import bind_statement
from komira_sql.sql_parser import parse_sql
from komira_sql.sql_token import tokenize


# The comparison operators, in the order compare_<col>.tsv lists them, with
# the operator that reads the same comparison with its operands swapped.
comptime _OPS = 6


def _op(i: Int) -> String:
    if i == 0:
        return "<"
    if i == 1:
        return "<="
    if i == 2:
        return ">"
    if i == 3:
        return ">="
    if i == 4:
        return "="
    return "<>"


def _flipped(i: Int) -> String:
    if i == 0:
        return ">"
    if i == 1:
        return ">="
    if i == 2:
        return "<"
    if i == 3:
        return "<="
    if i == 4:
        return "="
    return "<>"


def _rows(rel: String) raises -> List[List[String]]:
    """The data rows of a DuckDB TSV (the header dropped), cell by cell."""
    var text = Path(data_path(rel)).read_text()
    var out = List[List[String]]()
    var lines = text.split("\n")
    for i in range(1, len(lines)):
        var line = String(lines[i])
        if line.byte_length() == 0:
            continue
        var cells = List[String]()
        var parts = line.split("\t")
        for j in range(len(parts)):
            cells.append(String(parts[j]))
        out.append(cells^)
    return out^


def _new_context() raises -> EngineContext:
    var ctx = EngineContext(EngineOptions(worker_count=2))
    register_parquet(ctx, "t", data_path("t.parquet"))
    return ctx^


struct _Answer(Movable):
    var rows: Int
    var id_sum: Int
    var refusal: String

    def __init__(out self):
        self.rows = 0
        self.id_sum = 0
        self.refusal = String("")


def _read_sum(ref batch: RecordBatch) raises -> Int:
    ref col = batch.column_at(1)
    if col.is_null_at(0):
        return 0
    if col.arrow_type == ArrowType.INT64:
        return Int(col.as_primitive[DType.int64]().get(0))
    if col.arrow_type == ArrowType.DECIMAL128:
        return Int(col.as_decimal128().get_i128(0).cast[DType.int64]())
    raise Error("sum(id) came back as " + String(col.arrow_type))


def _ask(mut ctx: EngineContext, where_text: String) -> _Answer:
    var a = _Answer()
    var outcome = run_sql(
        ctx, "select count(*), sum(id) from t where " + where_text
    )
    if outcome.refusal:
        a.refusal = (
            "refused at "
            + outcome.refusal.value().step
            + ": "
            + outcome.refusal.value().reason
        )
        return a^
    try:
        ref batch = outcome.batches[0]
        a.rows = Int(batch.column_at(0).as_primitive[DType.int64]().get(0))
        a.id_sum = _read_sum(batch)
    except e:
        a.refusal = "unreadable answer: " + String(e)
    return a^


def _check(
    mut ctx: EngineContext,
    where_text: String,
    want_rows: Int,
    want_sum: Int,
    mut problems: List[String],
):
    var got = _ask(ctx, where_text)
    if got.refusal.byte_length() > 0:
        problems.append(where_text + ": " + got.refusal)
    elif got.rows != want_rows or got.id_sum != want_sum:
        problems.append(
            where_text
            + ": DuckDB keeps "
            + String(want_rows)
            + " rows (id sum "
            + String(want_sum)
            + "), komira keeps "
            + String(got.rows)
            + " (id sum "
            + String(got.id_sum)
            + ")"
        )


def _assert_no_problems(problems: List[String]) raises:
    if len(problems) == 0:
        return
    var text = String(len(problems)) + " answers differ from DuckDB:\n"
    for i in range(min(len(problems), 40)):
        text += "  " + problems[i] + "\n"
    assert_true(False, text)


def check_compare_column(col: String) raises:
    """For every literal of compare_<col>.tsv and each operator, the rows
    `<col> <op> <literal>` keeps are DuckDB's; and for each literal one
    operator, rotating through the six across the literals, is also asked in
    the reversed spelling `<literal> <flipped op> <col>`."""
    var rows = _rows("compare_" + col + ".tsv")
    assert_true(len(rows) >= 25, "compare_" + col + ".tsv holds too few literals")
    var ctx = _new_context()
    var problems = List[String]()
    for r in range(len(rows)):
        ref cells = rows[r]
        # n, col, lit, then (rows, id sum) for each operator.
        assert_equal(len(cells), 3 + 2 * _OPS)
        assert_equal(cells[1], col)
        var lit = cells[2]
        for i in range(_OPS):
            var want_rows = Int(atol(cells[3 + 2 * i]))
            var want_sum = Int(atol(cells[4 + 2 * i]))
            _check(
                ctx,
                col + " " + _op(i) + " " + lit,
                want_rows,
                want_sum,
                problems,
            )
            if i == r % _OPS:
                _check(
                    ctx,
                    lit + " " + _flipped(i) + " " + col,
                    want_rows,
                    want_sum,
                    problems,
                )
    _assert_no_problems(problems)


def check_where_texts() raises:
    var rows = _rows("where.tsv")
    assert_true(len(rows) >= 25, "where.tsv holds too few predicates")
    var ctx = _new_context()
    var problems = List[String]()
    for r in range(len(rows)):
        ref cells = rows[r]
        assert_equal(len(cells), 4)
        _check(
            ctx,
            cells[1],
            Int(atol(cells[2])),
            Int(atol(cells[3])),
            problems,
        )
    _assert_no_problems(problems)


def _lowered_plan(mut ctx: EngineContext, where_text: String) raises -> String:
    """The plan `select count(*) from t where <where_text>` lowers to, as the
    text the plan render prints."""
    ctx.begin_query()
    var stmt = parse_sql(
        tokenize("select count(*) from t where " + where_text)
    )
    var bound = bind_statement(stmt, ctx.catalog, ctx.footers)
    var plan = bound.take_plan()
    var deps = ScalarDepTable()
    var optimized = optimize(plan^, OptimizerConfig(), deps)
    var lowered = lower_for_context(optimized, ctx)
    return render_lowered_plan(lowered)


def _filter_of(plan: String) -> String:
    """The `filter=` text of the plan's source line, or the whole plan."""
    var at = plan.find("filter=")
    if at < 0:
        return plan
    var end = plan.find("\n", at)
    if end < 0:
        end = plan.byte_length()
    return String(plan[byte=at:end])


def _unscaled_literal(value: String) -> String:
    """`ScalarValue`'s text for a decimal whose digits are `value` (DuckDB
    writes exactly its scale's digits): `hi=<..>, lo=<..>`. The values this
    test folds fit in 63 bits, so `hi` is the sign extension."""
    var negative = value.startswith("-")
    var n: Int = 0
    for b in value.as_bytes():
        if b >= UInt8(ord("0")) and b <= UInt8(ord("9")):
            n = n * 10 + Int(b - UInt8(ord("0")))
    if negative:
        return "hi=-1, lo=" + String(-n)
    return "hi=0, lo=" + String(n)


def _scale_of(type_name: String) raises -> String:
    """`DECIMAL(w,s)` -> `w,s`."""
    var open = type_name.find("(")
    var close = type_name.find(")")
    assert_true(
        open >= 0 and close > open, type_name + " is not a DECIMAL(w,s) type"
    )
    return String(type_name[byte = open + 1 : close])


def check_folded_constants() raises:
    var rows = _rows("types.tsv")
    assert_true(len(rows) >= 15, "types.tsv holds too few constants")
    var ctx = _new_context()
    var problems = List[String]()
    for r in range(len(rows)):
        ref cells = rows[r]
        assert_equal(len(cells), 4)
        var expr = cells[1]
        var type_name = cells[2]
        var want = (
            "ScalarValue(decimal128("
            + _scale_of(type_name).replace(", ", ",")
            + "), "
            + _unscaled_literal(cells[3])
            + ")"
        )
        try:
            var plan = _lowered_plan(ctx, "a = " + expr)
            if plan.find(want) < 0:
                problems.append(
                    expr
                    + ": DuckDB gives "
                    + type_name
                    + " "
                    + cells[3]
                    + ", so the plan should hold "
                    + want
                    + "; it is: "
                    + _filter_of(plan)
                )
        except e:
            problems.append(expr + ": " + String(e))
    _assert_no_problems(problems)


def check_q6_bounds() raises:
    var ctx = _new_context()
    var plan = _lowered_plan(
        ctx,
        "a >= 0.06 - 0.01 and a <= 0.06 + 0.01 and b < 24",
    )
    # 0.06 - 0.01 and 0.06 + 0.01 are DECIMAL(4, 2) in DuckDB: 0.05 and 0.07.
    assert_true(
        plan.find("ScalarValue(decimal128(4,2), hi=0, lo=5)") >= 0,
        "the lower bound is not the DECIMAL(4,2) 0.05: " + _filter_of(plan),
    )
    assert_true(
        plan.find("ScalarValue(decimal128(4,2), hi=0, lo=7)") >= 0,
        "the upper bound is not the DECIMAL(4,2) 0.07: " + _filter_of(plan),
    )
    assert_true(
        plan.find("float64") < 0,
        "the plan still holds a float literal: " + _filter_of(plan),
    )


