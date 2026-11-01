# =============================================================================
# test_format_project_decline_census.mojo: the lines a projection refusal
# reports
# =============================================================================
#
# SUBJECT: `project_decline_census.format_project_decline_census`.
#
# The oracle is the census text: each case asserts the lines it must hold
# (the header counts, one line per expression with its tag, declared type and
# source, one line per input column) and the two declines the evaluator takes
# before any expression. Each test names the mutant that turns it red.
# =============================================================================

from std.testing import TestSuite, assert_true, assert_equal, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_plan_expr.expr import Expr, BIN_ADD
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import ExprArray

from komira_dispatch_project.project_decline_census import (
    format_project_decline_census,
)


def _in_schema() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("url"), ArrowType.LARGE_STRING, True))
    sb.add_field(Field(String("c"), ArrowType.INT64, False))
    return sb.build()


def _has(text: String, want: String) raises:
    assert_true(text.find(want) >= 0, "the census holds `" + want + "`:\n" + text)


def test_each_expression_and_input_column_has_its_line() raises:
    """A column reference, an aliased column reference, a reference to an
    absent column and a computed expression, over a two-column input. Mutant:
    the `src_type` of a present column printed from the declared type."""
    var exprs = ExprArray()
    exprs.append(Expr.col_ref(String("url")))
    exprs.append(Expr.alias(Expr.col_ref(String("c")), String("n")))
    exprs.append(Expr.col_ref(String("gone")))
    exprs.append(
        Expr.alias(
            Expr.binary(BIN_ADD, Expr.col_ref(String("c")), Expr.literal(ScalarValue.from_int(1))),
            String("p"),
        )
    )
    var sb = SchemaBuilder()
    sb.add_field(Field(String("url"), ArrowType.STRING, True))
    sb.add_field(Field(String("n"), ArrowType.INT64, False))
    sb.add_field(Field(String("gone"), ArrowType.INT64, True))
    sb.add_field(Field(String("p"), ArrowType.INT64, True))
    var text = format_project_decline_census(_in_schema(), exprs, sb.build())
    _has(text, "[project-decline] CENSUS out_exprs=4 out_schema_cols=4 in_batch_cols=2")
    _has(text, "expr[0] tag=EXPR_COL_REF out_name='url' declared=string(id=13)")
    _has(text, "src='url'@in[0] src_type=large_string(id=26) src_nullable=1")
    _has(text, "expr[1] tag=EXPR_ALIAS>EXPR_COL_REF out_name='n'")
    _has(text, "src='c'@in[1] src_type=int64(id=5) src_nullable=0")
    _has(text, "src='gone' ⚠ ABSENT FROM THE INCOMING BATCH")
    _has(text, "expr[3] tag=EXPR_ALIAS>EXPR_BINARY_OP")
    _has(text, "src=<computed>")
    _has(text, "in_batch[0] name='url' type=large_string(id=26) nullable=1")
    _has(text, "in_batch[1] name='c' type=int64(id=5) nullable=0")
    assert_false(text.find("ARITY MISMATCH") >= 0)
    assert_false(text.find("EMPTY EXPR LIST") >= 0)


def test_a_column_under_nested_aliases_is_reported_as_its_source() raises:
    """A column reference under two aliases is the shape the copy route
    serves, so its line names the source column like a single alias does.
    Mutant: `_colref_name` unwrapping one alias only (the line then reads
    `src=<computed>`)."""
    var exprs = ExprArray()
    exprs.append(
        Expr.alias(Expr.alias(Expr.col_ref(String("c")), String("m")), String("n"))
    )
    var sb = SchemaBuilder()
    sb.add_field(Field(String("n"), ArrowType.INT64, False))
    var text = format_project_decline_census(_in_schema(), exprs, sb.build())
    _has(text, "expr[0] tag=EXPR_ALIAS>EXPR_ALIAS out_name='n'")
    _has(text, "src='c'@in[1] src_type=int64(id=5) src_nullable=0")
    assert_false(text.find("src=<computed>") >= 0)


def test_the_two_declines_before_any_expression_are_named() raises:
    """An empty list, and more expressions than declared columns (the extra
    one says it has no column). Mutant: the arity line's test made
    `n_out > n_exprs` (the two-expressions-one-column case then has no
    line)."""
    var empty = format_project_decline_census(_in_schema(), ExprArray(), _in_schema())
    _has(empty, "EMPTY EXPR LIST")
    _has(empty, "ARITY MISMATCH — out_schema declares 2 column(s) for 0 expr(s)")
    var exprs = ExprArray()
    exprs.append(Expr.col_ref(String("url")))
    exprs.append(Expr.col_ref(String("c")))
    var sb = SchemaBuilder()
    sb.add_field(Field(String("url"), ArrowType.STRING, True))
    var text = format_project_decline_census(_in_schema(), exprs, sb.build())
    _has(text, "ARITY MISMATCH — out_schema declares 1 column(s) for 2 expr(s)")
    _has(text, "expr[1] tag=EXPR_COL_REF out_name=<NO out_schema COLUMN AT THIS INDEX>")


def test_a_long_expression_is_reported_by_its_length() raises:
    """An expression whose rendering exceeds 512 bytes is replaced by its
    byte count; a short one is rendered. Mutant: `<= _MAX_EXPR_RENDER` made
    `>= _MAX_EXPR_RENDER` (the long one is then rendered)."""
    var e = Expr.col_ref(String("c"))
    for _ in range(80):
        e = Expr.binary(BIN_ADD, e^, Expr.col_ref(String("c")))
    var exprs = ExprArray()
    exprs.append(e^)
    exprs.append(Expr.col_ref(String("c")))
    var sb = SchemaBuilder()
    sb.add_field(Field(String("p"), ArrowType.INT64, True))
    sb.add_field(Field(String("c"), ArrowType.INT64, False))
    var text = format_project_decline_census(_in_schema(), exprs, sb.build())
    var line1 = text.find("expr[1]")
    assert_true(line1 >= 0)
    var omitted = text.find(" bytes, omitted>")
    assert_true(
        omitted >= 0 and omitted < line1, "the long expression (expr[0]) is omitted"
    )
    assert_true(
        text.find(" bytes, omitted>", line1) < 0, "the short expression (expr[1]) is rendered"
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
