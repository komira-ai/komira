"""The checks of the decimal compare tests: each reads DuckDB's answers from
the .tsv files its test declares and runs the SQL through `run_sql`. The tests
are separate files so the farm runs them as separate actions."""

from std.pathlib import Path
from std.testing import assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_jsonl.value_parsers.parse_float import parse_float_f64
from komira_arrow.schema import RecordBatch
from komira_lowering.render import render_lowered_plan
from komira_optimizer.optimizer_config import OptimizerConfig
from komira_optimizer.optimizer_driver import optimize
from komira_optimizer.optimizer_scalar_deps import ScalarDepTable
from komira_plan_expr.scalar_value import ScalarValue
from komira_runtime_paths import data_path
from komira_scalar_arithmetic.decimal_arith import I128
from komira_scalar_arithmetic.decimal_cast import decimal_to_float64
from komira_sdk_exec.engine_catalog import register_parquet
from komira_sdk_exec.engine_context import EngineContext
from komira_sdk_exec.engine_lower import lower_for_context
from komira_sdk_exec.engine_options import EngineOptions
from komira_sdk_exec.engine_sql import SqlOutcome, run_sql
from komira_sql.sql_binder import bind_statement
from komira_sql.sql_parser import parse_sql
from komira_sql.sql_token import TK_FLOAT, signed_decimal_f64, tokenize


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


def _new_context(table: String) raises -> EngineContext:
    """A context with the Parquet file `<table>.parquet` registered as
    `table`."""
    var ctx = EngineContext(EngineOptions(worker_count=2))
    register_parquet(ctx, table, data_path(table + ".parquet"))
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


def _ask(
    mut ctx: EngineContext, table: String, where_text: String
) -> _Answer:
    var a = _Answer()
    var outcome = run_sql(
        ctx, "select count(*), sum(id) from " + table + " where " + where_text
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
    table: String,
    where_text: String,
    want_rows: Int,
    want_sum: Int,
    want_errors: Int,
    mut problems: List[String],
):
    """DuckDB keeps `want_rows` rows (id sum `want_sum`) for `where_text`, or,
    when `want_errors` is above 0, raises a conversion error for that many
    rows: then the query must be refused, with a reason that names the
    type DuckDB's message names too (DECIMAL(38, s), or INT32 for an integer
    overflow)."""
    var got = _ask(ctx, table, where_text)
    if want_errors > 0:
        if got.refusal.byte_length() == 0:
            problems.append(
                where_text
                + ": DuckDB raises a conversion error ("
                + String(want_errors)
                + " rows), komira answers "
                + String(got.rows)
                + " rows (id sum "
                + String(got.id_sum)
                + ")"
            )
        elif (
            got.refusal.find("DECIMAL(") < 0
            and got.refusal.find("INT") < 0
            and got.refusal.find("Overflow") < 0
        ):
            problems.append(
                where_text
                + ": DuckDB raises an error, komira refuses with a reason that"
                " names no DECIMAL or INT type: "
                + got.refusal
            )
        return
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


def check_compare_column(
    table: String, col: String, part: Int, parts: Int
) raises:
    """For every literal of compare_<col>.tsv whose row number leaves `part`
    modulo `parts` and each operator, the rows `<col> <op> <literal>` keeps are
    DuckDB's, and so are the rows of the reversed spelling `<literal> <flipped
    op> <col>`, for all six operators; where DuckDB raises a conversion error
    for the comparison, `run_sql` refuses it."""
    var rows = _rows("compare_" + col + ".tsv")
    assert_true(len(rows) >= 8, "compare_" + col + ".tsv holds too few literals")
    var ctx = _new_context(table)
    var problems = List[String]()
    var asked = 0
    for r in range(len(rows)):
        if r % parts != part:
            continue
        ref cells = rows[r]
        # n, col, lit, then (rows, id sum, error rows) for each operator.
        assert_equal(len(cells), 3 + 3 * _OPS)
        assert_equal(cells[1], col)
        var lit = cells[2]
        for i in range(_OPS):
            var want_rows = Int(atol(cells[3 + 3 * i]))
            var want_sum = Int(atol(cells[4 + 3 * i]))
            var want_errors = Int(atol(cells[5 + 3 * i]))
            _check(
                ctx,
                table,
                col + " " + _op(i) + " " + lit,
                want_rows,
                want_sum,
                want_errors,
                problems,
            )
            _check(
                ctx,
                table,
                lit + " " + _flipped(i) + " " + col,
                want_rows,
                want_sum,
                want_errors,
                problems,
            )
            asked += 2
    assert_true(asked > 0, "no literal of compare_" + col + ".tsv was asked")
    _assert_no_problems(problems)


def check_where_texts() raises:
    var rows = _rows("where.tsv")
    assert_true(len(rows) >= 25, "where.tsv holds too few predicates")
    var ctx = _new_context("t")
    var problems = List[String]()
    for r in range(len(rows)):
        ref cells = rows[r]
        assert_equal(len(cells), 4)
        _check(
            ctx,
            "t",
            cells[1],
            Int(atol(cells[2])),
            Int(atol(cells[3])),
            0,
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


def _decimal_literal(value: String, type_name: String) raises -> String:
    """`ScalarValue`'s text for the decimal DuckDB prints as `value` (exactly
    its scale's digits) with the type `type_name`: the unscaled integer split
    into its high and low 64-bit words."""
    var negative = value.startswith("-")
    var n = I128(0)
    for b in value.as_bytes():
        if b >= UInt8(ord("0")) and b <= UInt8(ord("9")):
            n = n * I128(10) + I128(Int(b - UInt8(ord("0"))))
    if negative:
        n = -n
    var pair = _scale_of(type_name).replace(" ", "").split(",")
    return String(
        ScalarValue.decimal128_i128(n, Int(atol(pair[0])), Int(atol(pair[1])))
    )


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
    var ctx = _new_context("t")
    var problems = List[String]()
    for r in range(len(rows)):
        ref cells = rows[r]
        assert_equal(len(cells), 4)
        var expr = cells[1]
        var type_name = cells[2]
        var want = _decimal_literal(cells[3], type_name)
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


def check_fold_refusals() raises:
    """Each constant of errors.tsv that DuckDB cannot fold (an overflow, or a
    scale past 38) is refused where it faces a DECIMAL column; the others fold
    as they did."""
    var rows = _rows("errors.tsv")
    assert_true(len(rows) >= 6, "errors.tsv holds too few constants")
    var ctx = _new_context("t")
    var problems = List[String]()
    var refused = 0
    for r in range(len(rows)):
        ref cells = rows[r]
        assert_equal(len(cells), 3)
        var expr = cells[1]
        var duckdb_raises = cells[2] == "true"
        var komira_raises = False
        var message = String("")
        try:
            _ = _lowered_plan(ctx, "a = " + expr)
        except e:
            komira_raises = True
            message = String(e)
        if duckdb_raises:
            refused += 1
            if not komira_raises:
                problems.append(
                    expr + ": DuckDB raises an error, komira folds it"
                )
            elif (
                message.find("DECIMAL(") < 0
                and message.find("scale") < 0
                and message.find("INT") < 0
                and message.find("Overflow") < 0
            ):
                problems.append(
                    expr
                    + ": DuckDB raises an error, komira's message names no"
                    " DECIMAL or INT type or scale: "
                    + message
                )
        elif komira_raises:
            problems.append(
                expr + ": DuckDB folds it, komira raises: " + message
            )
    assert_true(refused >= 5, "errors.tsv holds too few raising constants")
    _assert_no_problems(problems)


def check_q6_bounds() raises:
    var ctx = _new_context("t")
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




def _i128_of(digits: String) -> I128:
    var negative = digits.startswith("-")
    var n = I128(0)
    for b in digits.as_bytes():
        if b >= UInt8(ord("0")) and b <= UInt8(ord("9")):
            n = n * I128(10) + I128(Int(b - UInt8(ord("0"))))
    if negative:
        n = -n
    return n


def check_double_conversion_of_columns() raises:
    """`decimal_to_float64` of every stored value of double_sweep.tsv is the
    double DuckDB casts it to (the text DuckDB prints reads back exactly)."""
    var rows = _rows("double_sweep.tsv")
    assert_true(len(rows) >= 1000, "double_sweep.tsv holds too few values")
    var problems = List[String]()
    for r in range(len(rows)):
        ref cells = rows[r]
        assert_equal(len(cells), 5)
        var scale = Int(atol(cells[1]))
        var want = parse_float_f64(cells[4].as_bytes(), 0, cells[4].byte_length())
        var got = decimal_to_float64(_i128_of(cells[2]), scale)
        if got != want:
            problems.append(
                cells[3]
                + " (scale "
                + String(scale)
                + "): DuckDB gives "
                + cells[4]
                + ", komira "
                + String(got)
            )
    _assert_no_problems(problems)


def check_double_conversion_of_literals() raises:
    """The double the SQL front end makes of the decimal text of every value of
    scale 1 and up of double_sweep.tsv (the tokenizer for its magnitude, the
    signed conversion for a negative literal) is the double DuckDB casts the
    value to."""
    var rows = _rows("double_sweep.tsv")
    var problems = List[String]()
    var checked = 0
    for r in range(len(rows)):
        ref cells = rows[r]
        var scale = Int(atol(cells[1]))
        if scale < 1:
            continue
        var want = parse_float_f64(cells[4].as_bytes(), 0, cells[4].byte_length())
        var negative = cells[3].startswith("-")
        var got = signed_decimal_f64(cells[3], 0.0)
        if not negative:
            var toks = tokenize(cells[3])
            if toks[0].kind != TK_FLOAT or toks[0].float_val != got:
                problems.append(
                    cells[3] + ": the tokenizer disagrees with the signed conversion"
                )
        checked += 1
        if got != want:
            problems.append(
                cells[3]
                + ": DuckDB gives "
                + cells[4]
                + ", the front end "
                + String(got)
            )
    assert_true(checked > 400, "too few decimal literals were checked")
    _assert_no_problems(problems)
