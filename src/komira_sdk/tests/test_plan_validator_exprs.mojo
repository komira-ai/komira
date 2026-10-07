# =============================================================================
# plan_validator, the expression half: every arm of `_validate_expr_columns`.
# =============================================================================
#
# For each expression kind the walk descends, a test puts the unknown column
# `nope` in each operand slot and requires validation to raise naming it. An
# arm that stops descending, or that descends only one of its operands,
# reports the plan valid and fails here. The same shape with known columns
# must pass, so an arm that raises on everything fails too. The kinds the walk
# cannot resolve (a correlated subquery, the two payload-less tags, a tag it
# has no arm for) must be NOTED in the report, never passed silently.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.agg_expr import AGG_SUM
from komira_plan_expr.corr_subquery_data import CORR_KIND_EXISTS
from komira_plan_expr.expr import (
    Expr,
    WhenCaseData,
    BIN_ADD,
    BIN_GT,
    EXPR_BETWEEN,
    EXPR_SORT_KEY,
    STR_CONTAINS,
    UN_NOT,
)
from komira_plan_expr.partition_expr import PF_COUNT, PF_SUM
from komira_plan_expr.partition_frame import PartitionFrame
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import ExprArray, LogicalPlan, SOURCE_PARQUET

from komira_sdk.plan_validator import validate_plan, validate_plan_report


def _schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, False))
    sb.add_field(Field("b", ArrowType.INT64, False))
    sb.add_field(Field("s", ArrowType.STRING, True))
    return sb.build()


def _plan(var e: Expr) -> LogicalPlan:
    var ex = ExprArray()
    ex.append(e^)
    return LogicalPlan.project(ex^, LogicalPlan.scan("t.parquet", SOURCE_PARQUET, _schema()))


def _ok(var e: Expr, what: String) raises:
    var r = validate_plan_report(_plan(e^))
    assert_true(r.fully_validated(), what + ": fully validated, got " + r.summary())


def _bad(var e: Expr, what: String) raises:
    var raised = False
    try:
        validate_plan(_plan(e^))
    except err:
        raised = True
        assert_true(
            String(err).find("Project expression 0: column 'nope' not found") != -1,
            what + ": " + String(err),
        )
    assert_true(raised, what + ": the unknown column is found")


def _noted(var e: Expr, want: String, what: String) raises:
    var r = validate_plan_report(_plan(e^))
    assert_equal(r.num_unvalidated(), 1, what + ": one note")
    assert_true(r.note(0).find(want) != -1, what + ": " + r.note(0))


def _c(n: String) -> Expr:
    return Expr.col_ref(n)


def _one() -> Expr:
    return Expr.literal(ScalarValue.from_int(1))


def test_leaves() raises:
    _ok(_c("a"), "a column")
    _bad(_c("nope"), "a column")
    _ok(_one(), "a literal")
    _ok(Expr.col_idx(99), "a positional reference is not bounds-checked")


def test_one_child_kinds() raises:
    _bad(Expr.unary(UN_NOT, _c("nope")), "unary")
    _bad(Expr.cast(_c("nope"), DType.float64), "cast")
    _bad(Expr.alias(_c("nope"), "x"), "alias")
    _bad(Expr.string_op(STR_CONTAINS, _c("nope"), "q"), "string_op")
    _bad(Expr.regexp_like(_c("nope"), "q+"), "regexp")
    _bad(Expr.substring(_c("nope"), 1, 2), "substring")
    _bad(Expr.upper(_c("nope")), "string_fn")
    _bad(Expr.year(_c("nope")), "extract")
    _bad(Expr.sqrt(_c("nope")), "math_fn")
    var vals = List[ScalarValue]()
    vals.append(ScalarValue.from_int(1))
    _bad(Expr.in_list_node(_c("nope"), vals^), "in_list")
    _bad(Expr.agg_fn(AGG_SUM, _c("nope")), "aggregate as expression")
    _bad(Expr.struct_field(_c("nope"), "f"), "struct_field")
    _bad(Expr.struct_field_idx(_c("nope"), 0), "struct_field_idx")
    _bad(Expr.json_extract_string(_c("nope"), "$.k"), "json_extract")
    _bad(
        Expr.udf_call("f", None, ArrowType.INT64, ArrowType.INT64, _c("nope")),
        "udf_call",
    )
    _ok(Expr.upper(_c("s")), "string_fn over a known column")
    _ok(Expr.alias(Expr.sqrt(_c("a")), "r"), "nested one-child kinds")


def test_n_argument_string_fn_checks_every_argument() raises:
    var ok = List[Expr]()
    ok.append(_c("s"))
    ok.append(_c("s"))
    _ok(Expr.concat(ok^), "concat")
    var bad = List[Expr]()
    bad.append(_c("s"))
    bad.append(_c("nope"))
    _bad(Expr.concat(bad^), "concat's second argument")


def test_two_child_kinds_check_both_sides() raises:
    _bad(Expr.binary(BIN_ADD, _c("nope"), _c("a")), "binary left")
    _bad(Expr.binary(BIN_ADD, _c("a"), _c("nope")), "binary right")
    _ok(Expr.binary(BIN_ADD, _c("a"), _c("b")), "binary")
    _bad(Expr.atan2(_c("nope"), _c("a")), "math_fn2 left")
    _bad(Expr.atan2(_c("a"), _c("nope")), "math_fn2 right")
    _bad(Expr.map_get(_c("nope"), _c("s")), "map_get parent")
    _bad(Expr.map_get(_c("s"), _c("nope")), "map_get key")
    _ok(Expr.map_get(_c("s"), _one()), "map_get")


def _case(var cond: Expr, var result: Expr, var default: Expr) -> Expr:
    var cases = List[WhenCaseData]()
    cases.append(WhenCaseData(Expr.binary(BIN_GT, _c("a"), _one()), _c("b")))
    cases.append(WhenCaseData(cond^, result^))
    return Expr.when(cases^, default^)


def test_case_checks_every_branch_and_the_default() raises:
    _ok(_case(Expr.binary(BIN_GT, _c("b"), _one()), _c("a"), _one()), "case")
    _bad(_case(_c("nope"), _c("a"), _one()), "case condition")
    _bad(_case(_c("a"), _c("nope"), _one()), "case result")
    _bad(_case(_c("a"), _c("b"), _c("nope")), "case default")


def _window(arg: String, var pby: List[String], var oby: List[String]) -> Expr:
    var f = PF_SUM
    if arg.byte_length() == 0:
        f = PF_COUNT
    return Expr.window_fn(f, arg, 0, PartitionFrame.default_unordered()).over(
        pby^, oby^
    )


def test_window_names() raises:
    var s: List[String] = ["s"]
    var a: List[String] = ["a"]
    var n: List[String] = ["nope"]
    _ok(_window("b", s.copy(), a.copy()), "window")
    _ok(_window("", s.copy(), a.copy()), "a COUNT(*) window carries no argument")
    var err = String()
    try:
        validate_plan(_plan(_window("nope", s.copy(), a.copy())))
    except e:
        err = String(e)
    assert_true(err.find("(window arg): column 'nope'") != -1, err)
    err = String()
    try:
        validate_plan(_plan(_window("b", n.copy(), a.copy())))
    except e:
        err = String(e)
    assert_true(err.find("(window PARTITION BY): column 'nope'") != -1, err)
    err = String()
    try:
        validate_plan(_plan(_window("b", s.copy(), n.copy())))
    except e:
        err = String(e)
    assert_true(err.find("(window ORDER BY): column 'nope'") != -1, err)


def test_unresolvable_kinds_are_noted() raises:
    var inner = LogicalPlan.scan("u.parquet", SOURCE_PARQUET, _schema())
    var refs: List[String] = ["a"]
    _noted(
        Expr.correlated_subquery(inner^, refs^, CORR_KIND_EXISTS),
        "EXPR_CORRELATED_SUBQUERY (tag 14)",
        "a correlated subquery",
    )
    var between = _one()
    between.tag = EXPR_BETWEEN
    _noted(between^, "expression tag 10 has no payload field", "BETWEEN")
    var sort_key = _one()
    sort_key.tag = EXPR_SORT_KEY
    _noted(sort_key^, "expression tag 11 has no payload field", "SORT_KEY")
    var unknown = _one()
    unknown.tag = 200
    _noted(unknown^, "expression tag 200 is not modeled", "a tag with no arm")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
