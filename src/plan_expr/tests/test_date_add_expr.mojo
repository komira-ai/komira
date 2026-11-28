# =============================================================================
# test_date_add_expr.mojo — the `EXPR_DATE_ADD` node: a DATE32 moved by a
# constant (months, days) pair
# =============================================================================
#
# The render matters beyond display: an expression's render is plan identity
# (`structural_hash` is FNV-1a over it), so a constant the render leaves out
# lets two different shifts share a compiled plan.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from arrow.arrow_types import ArrowType
from arrow.schema import Field, SchemaBuilder
from plan_expr.expr import Expr, EXPR_DATE_ADD, EXPR_TAG_COUNT, expr_tag_name
from plan_expr.expr_walk import (
    PlanColRefFields,
    ordered_name_sink,
    walk_expr_column_refs,
    walk_expr_field,
)


def _text(e: Expr) -> String:
    var out = String()
    e.write_to(out)
    return out^


def test_date_add_is_named_and_counted() raises:
    """The tag is inside the counted space and has its own name."""
    assert_equal(Int(EXPR_DATE_ADD), 28, "the engine tag")
    assert_true(Int(EXPR_DATE_ADD) < EXPR_TAG_COUNT, "inside the count")
    assert_equal(expr_tag_name(EXPR_DATE_ADD), "EXPR_DATE_ADD", "its name")


def test_date_add_accessors_and_copy_keep_both_constants() raises:
    """A copy keeps the months, the days (negative ones too) and the child."""
    var e = Expr.date_add(Int32(-14), Int32(-3), Expr.col_ref("d"))
    assert_true(e.is_date_add(), "is_date_add")
    var c = e.copy()
    assert_equal(Int(c.tag), Int(EXPR_DATE_ADD), "tag")
    assert_equal(Int(c.date_add_months()), -14, "months")
    assert_equal(Int(c.date_add_days()), -3, "days")
    assert_equal(c.date_add_child_ref().col_ref_name(), "d", "child")
    assert_false(Expr.col_ref("d").is_date_add(), "a column is not one")


def test_date_add_render_carries_both_constants() raises:
    """The render names the months, the days and the child, so shifts that
    differ in either constant never render (and hash) alike."""
    var a = Expr.date_add(Int32(1), Int32(0), Expr.col_ref("d"))
    var b = Expr.date_add(Int32(0), Int32(1), Expr.col_ref("d"))
    var c = Expr.date_add(Int32(1), Int32(0), Expr.col_ref("e"))
    assert_equal(_text(a), _text(a.copy()), "a copy renders alike")
    assert_true(_text(a) != _text(b), "months vs days")
    assert_true(_text(a) != _text(c), "a different child")
    assert_true(
        _text(Expr.date_add(Int32(2), Int32(-5), Expr.col_ref("d")))
        .startswith("DateAdd(months=2, days=-5, "),
        "both constants in the render",
    )


def test_walks_reach_the_date_and_type_it_date32() raises:
    """The column walk reaches the date under the node (a scan would prune a
    column only the shift reads) and the field walk types it DATE32 (the
    output column would be typed null)."""
    var names = List[String]()
    var sink = ordered_name_sink(names)
    walk_expr_column_refs(Expr.date_add(Int32(1), Int32(7), Expr.col_ref("d")), sink)
    assert_equal(len(names), 1, "one column")
    assert_equal(names[0], "d", "the date column")
    var sb = SchemaBuilder()
    sb.add_field(Field("d", ArrowType.DATE32, True))
    var missing = String()
    var f = walk_expr_field[PlanColRefFields](
        Expr.date_add(Int32(1), Int32(7), Expr.col_ref("d")), sb.build(), missing
    )
    assert_equal(missing, "", "no missing column")
    assert_equal(Int(f.arrow_type.type_id), Int(ArrowType.DATE32.type_id), "DATE32")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
