# =============================================================================
# test_expr_walk_refs.mojo: the column-reference walk and its two name sinks.
#
# `walk_expr_column_refs` is a ladder whose fall-through is a no-op, so an arm
# that is missing, or that walks only some of its children, reports fewer
# names instead of failing. Every test here walks one tag with a DISTINCT
# column in each child slot and checks the exact ordered list, so a dropped
# arm, a dropped child or a reordered pair of children reads a different list.
# The leaves (column by index, literal, BETWEEN, sort key) must report none.
# =============================================================================

from std.collections import Set, Optional
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_expr.agg_expr import AGG_SUM
from komira_plan_expr.partition_expr import PF_ROW_NUMBER
from komira_plan_expr.partition_frame import (
    PartitionFrame,
    FRAME_UNITS_ROWS,
    FRAME_BOUND_UNBOUNDED_PRECEDING,
    FRAME_BOUND_CURRENT_ROW,
)
from komira_plan_expr.corr_subquery_data import BoxablePlan, CORR_KIND_EXISTS
from komira_plan_expr.expr import (
    Expr,
    WhenCaseData,
    EXPR_BETWEEN,
    EXPR_SORT_KEY,
    BIN_ADD,
    BIN_GT,
    UN_NOT,
    STR_LIKE,
    REGEXP_LIKE,
    EXTRACT_YEAR,
)
from komira_plan_expr.expr_walk import (
    NameSinkKind,
    ExprNameSink,
    ordered_name_sink,
    unique_name_sink,
    walk_expr_column_refs,
)


@fieldwise_init
struct _FakePlan(BoxablePlan):
    """A stand-in inner plan: the walk reads only the payload's column names,
    never the plan."""

    var n: Int

    def copy(self) -> Self:
        return Self(self.n)

    def plan_tag(self) -> UInt8:
        return 7

    def erased_type_tag(self) -> UInt32:
        return 0x7E57F00D


def _kind[S: ExprNameSink](s: S) -> NameSinkKind:
    return S.KIND


def _ordered(e: Expr) -> List[String]:
    var out = List[String]()
    var sink = ordered_name_sink(out)
    walk_expr_column_refs(e, sink)
    return out^


def _unique(e: Expr) -> Set[String]:
    var cols = Set[String]()
    var sink = unique_name_sink(cols)
    walk_expr_column_refs(e, sink)
    return cols^


def _joined(names: List[String]) -> String:
    var s = String("")
    for i in range(len(names)):
        if i > 0:
            s += ","
        s += names[i]
    return s^


def _refs(e: Expr) -> String:
    return _joined(_ordered(e))


def _c(name: String) -> Expr:
    return Expr.col_ref(name)


def _frame() -> PartitionFrame:
    return PartitionFrame(
        FRAME_UNITS_ROWS, FRAME_BOUND_UNBOUNDED_PRECEDING, Int64(0),
        FRAME_BOUND_CURRENT_ROW, Int64(0),
    )


def test_name_sink_kind_values() raises:
    """ORDERED is tag 0, UNIQUE tag 1, the two compare unequal, the Int and
    UInt8 constructors agree, and each sink declares its own kind."""
    assert_equal(NameSinkKind.ORDERED.tag(), 0)
    assert_equal(NameSinkKind.UNIQUE.tag(), 1)
    assert_true(NameSinkKind.ORDERED != NameSinkKind.UNIQUE)
    assert_false(NameSinkKind.ORDERED == NameSinkKind.UNIQUE)
    assert_true(NameSinkKind(1) == NameSinkKind(UInt8(1)))
    assert_false(NameSinkKind(0) != NameSinkKind(UInt8(0)))
    var out = List[String]()
    assert_true(_kind(ordered_name_sink(out)) == NameSinkKind.ORDERED)
    var cols = Set[String]()
    assert_true(_kind(unique_name_sink(cols)) == NameSinkKind.UNIQUE)


def test_ordered_sink_keeps_order_and_duplicates() raises:
    """The ORDERED sink appends every reference in walk order, duplicates
    kept; the UNIQUE sink folds them."""
    var e = Expr.binary(BIN_ADD, _c("b"), Expr.binary(BIN_ADD, _c("a"), _c("b")))
    assert_equal(_refs(e), "b,a,b")
    var u = _unique(e)
    assert_equal(len(u), 2)
    assert_true("a" in u)
    assert_true("b" in u)


def test_leaves_report_no_name() raises:
    """A column by index, a literal, BETWEEN and a sort key carry no name."""
    assert_equal(len(_ordered(Expr.col_idx(0))), 0)
    assert_equal(len(_ordered(Expr.literal(ScalarValue.from_int(7)))), 0)
    assert_equal(len(_ordered(Expr(EXPR_BETWEEN))), 0)
    assert_equal(len(_ordered(Expr(EXPR_SORT_KEY))), 0)
    assert_equal(len(_unique(Expr.col_idx(3))), 0)


def test_single_child_arms() raises:
    """Each one-child tag reports its child's column."""
    assert_equal(_refs(_c("a")), "a")
    assert_equal(_refs(Expr.unary(UN_NOT, _c("flag"))), "flag")
    assert_equal(_refs(Expr.cast(_c("k"), DType.float64)), "k")
    assert_equal(_refs(Expr.alias(_c("al"), "renamed")), "al")
    assert_equal(_refs(Expr.string_op(STR_LIKE, _c("s"), "p%")), "s")
    var vals: List[ScalarValue] = [ScalarValue.from_int(1), ScalarValue.from_int(2)]
    assert_equal(_refs(Expr.in_list_node(_c("il"), vals^)), "il")
    assert_equal(_refs(Expr.json_extract_string(_c("j"), "$.a")), "j")
    assert_equal(_refs(Expr.struct_field(_c("st"), "f")), "st")
    assert_equal(_refs(Expr.struct_field_idx(_c("sti"), 0)), "sti")
    assert_equal(_refs(Expr.agg_fn(AGG_SUM, _c("ag"))), "ag")
    assert_equal(_refs(Expr.regexp(REGEXP_LIKE, _c("rx"), "p")), "rx")
    assert_equal(_refs(Expr.sqrt(_c("mf"))), "mf")
    assert_equal(_refs(Expr.substring(_c("sub"), 1, 2)), "sub")
    assert_equal(_refs(Expr.upper(_c("up"))), "up")
    assert_equal(
        _refs(Expr.udf_call(String("f"), Optional[Int](None), ArrowType.INT64, ArrowType.INT64, _c("u"))),
        "u",
    )
    assert_equal(_refs(Expr.extract(EXTRACT_YEAR, _c("dt"))), "dt")


def test_two_child_arms_left_then_right() raises:
    """Binary, map-get and the two-argument math function report the left
    (or parent) child's column, then the right (or key) child's."""
    assert_equal(_refs(Expr.binary(BIN_ADD, _c("l"), _c("r"))), "l,r")
    assert_equal(_refs(Expr.map_get(_c("m"), _c("key"))), "m,key")
    assert_equal(
        _refs(Expr.map_get(_c("m"), Expr.literal(ScalarValue.from_string("k")))), "m",
    )
    assert_equal(_refs(Expr.atan2(_c("y"), _c("x"))), "y,x")


def test_variadic_string_fn_every_argument() raises:
    """All three arguments of a three-argument string function, in order."""
    var args: List[Expr] = [_c("s"), _c("t"), _c("u")]
    assert_equal(_refs(Expr.concat(args^)), "s,t,u")


def test_when_every_case_then_default() raises:
    """Each case's condition then result, in case order, then the default."""
    var cases = List[WhenCaseData]()
    cases.append(WhenCaseData(Expr.binary(BIN_GT, _c("c1"), Expr.literal(ScalarValue.from_int(0))), _c("r1")))
    cases.append(WhenCaseData(_c("c2"), _c("r2")))
    assert_equal(_refs(Expr.when(cases^, _c("dflt"))), "c1,r1,c2,r2,dflt")


def test_window_fn_arg_partition_order_columns() raises:
    """The argument column, then every PARTITION BY column, then every ORDER
    BY column; no argument column when it is empty."""
    var pb: List[String] = ["p1", "p2"]
    var ob: List[String] = ["o1"]
    var desc: List[Bool] = [False]
    var w = Expr.window_fn(PF_ROW_NUMBER, String("arg"), 0, _frame()).over(pb^, ob^, desc^)
    assert_equal(_refs(w), "arg,p1,p2,o1")
    var pb2: List[String] = ["p1"]
    var w2 = Expr.window_fn(PF_ROW_NUMBER, String(""), 0, _frame()).over(pb2^)
    assert_equal(_refs(w2), "p1")


def test_correlated_subquery_outer_refs_and_in_lhs() raises:
    """Every outer reference, in order; an IN subquery adds its left-hand
    outer column after them; the inner column is not an outer reference."""
    var refs: List[String] = ["o1", "o2"]
    assert_equal(_refs(Expr.correlated_subquery(_FakePlan(1), refs^, CORR_KIND_EXISTS)), "o1,o2")
    var refs2: List[String] = ["o1"]
    assert_equal(
        _refs(Expr.in_correlated_subquery(_FakePlan(2), refs2^, String("lhs"), String("inner_rhs"))),
        "o1,lhs",
    )
    assert_equal(
        _refs(Expr.in_correlated_subquery(_FakePlan(3), List[String](), String("lhs"), String("inner_rhs"))),
        "lhs",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
