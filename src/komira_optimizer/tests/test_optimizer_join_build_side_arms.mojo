# =============================================================================
# Rule 17, `select_join_build_side`: every swap decision, the STRING-payload
# override, the HAVING selectivity heuristic and the restoring projection.
# =============================================================================
#
# The build side is the RIGHT child. The rule swaps an INNER join whose left
# (probe) side is cheaper, a SEMI whose left side is an aggressive HAVING, and a
# RIGHT join into a LEFT one; it never swaps a residual-carrying join. An INNER
# or outer swap adds a Project that restores the user's column names and
# order: without it, the bare name `val` would denote the other relation's
# column after the exchange. Each test names the defect it catches.
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.expr import (
    Expr, BIN_EQ, BIN_NE, BIN_LT, BIN_LE, BIN_GT, BIN_GE, BIN_AND, BIN_OR,
    BIN_ADD,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_AGGREGATE,
    PLAN_JOIN,
    PLAN_SORT,
    PLAN_LIMIT,
    PLAN_DISTINCT,
    PLAN_TOPN,
    PLAN_SCAN,
    SOURCE_PARQUET,
    JOIN_INNER,
    JOIN_LEFT,
    JOIN_RIGHT,
    JOIN_SEMI,
    JOIN_ANTI,
    JOIN_ALGO_AUTO,
)
from komira_optimizer.optimizer_join import (
    select_join_build_side,
    _side_has_wide_string_build_payload,
    _estimate_having_selectivity,
    _estimate_predicate_selectivity_from_plan,
)


# -----------------------------------------------------------------------------
# Fixtures
# -----------------------------------------------------------------------------


def _int_schema(names: List[String]) -> Schema:
    var sb = SchemaBuilder()
    for i in range(len(names)):
        sb.add_field(Field(names[i], ArrowType.INT64, True))
    return sb.build()


def _scan_rows(path: String, var schema: Schema, rows: Int) -> LogicalPlan:
    return LogicalPlan.scan(
        path, SOURCE_PARQUET, schema^, None, None, Optional[Int](rows)
    )


def _ints(path: String, names: List[String], rows: Int) -> LogicalPlan:
    return _scan_rows(path, _int_schema(names), rows)


def _wide_string(path: String, key: String, rows: Int) -> LogicalPlan:
    """A key plus four payload columns, one of them STRING."""
    var sb = SchemaBuilder()
    sb.add_field(Field(key, ArrowType.INT64, True))
    sb.add_field(Field(path + "_s", ArrowType.STRING, True))
    sb.add_field(Field(path + "_a", ArrowType.INT64, True))
    sb.add_field(Field(path + "_b", ArrowType.INT64, True))
    sb.add_field(Field(path + "_c", ArrowType.INT64, True))
    return _scan_rows(path, sb.build(), rows)


def _join(
    var l: LogicalPlan, var r: LogicalPlan, lk: String, rk: String, jt: UInt8
) -> LogicalPlan:
    var lo: List[String] = [lk]
    var ro: List[String] = [rk]
    return LogicalPlan.join(l^, r^, lo^, ro^, jt)


def _small_left_inner() -> LogicalPlan:
    """INNER(L 10 rows, R 1000 rows): the probe side is the cheap one, so the
    rule swaps."""
    var ln: List[String] = ["a", "lv"]
    var rn: List[String] = ["b", "rv"]
    return _join(_ints("l", ln, 10), _ints("r", rn, 1000), "a", "b", JOIN_INNER)


def _scan_path(p: LogicalPlan) -> String:
    return p._scan.value()[].source_path


def _names(p: LogicalPlan) -> List[String]:
    var out = List[String]()
    for i in range(p.output_schema.num_columns()):
        out.append(p.output_schema.field_name(i))
    return out^


def _render(e: Expr) -> String:
    var s = String("")
    e.write_to(s)
    return s


def _having(op: UInt8) -> LogicalPlan:
    """Filter(<col> op 1) over Aggregate(g) over a scan: a HAVING shape."""
    var n: List[String] = ["g", "x"]
    var keys = ExprArray()
    keys.append(Expr.col_ref("g"))
    var agg = LogicalPlan.aggregate(keys^, AggExprArray(), _ints("h", n, 1000))
    var pred = Expr.binary(op, Expr.col_ref("g"), Expr.literal(ScalarValue.from_int64(Int64(1))))
    return LogicalPlan.filter(pred^, agg^)


# -----------------------------------------------------------------------------
# INNER
# -----------------------------------------------------------------------------


def test_inner_swaps_when_the_probe_side_is_cheaper() raises:
    """L (10 rows) on the probe side and R (1000) on build: swap so R probes.
    The result is a restoring Project over INNER(R, L) and the user-visible
    names are unchanged. Catches the cost comparison inverted and the INNER
    swap losing its restoring projection."""
    var out = select_join_build_side(_small_left_inner())
    assert_equal(Int(out.tag), Int(PLAN_PROJECT))
    ref j = out._project.value()[].child[]
    assert_equal(Int(j.tag), Int(PLAN_JOIN))
    assert_equal(Int(j._join.value()[].join_type), Int(JOIN_INNER))
    assert_equal(_scan_path(j._join.value()[].left[]), "r")
    assert_equal(_scan_path(j._join.value()[].right[]), "l")
    assert_equal(j._join.value()[].left_on[0], "b")
    assert_equal(j._join.value()[].right_on[0], "a")
    var got = _names(out)
    assert_equal(len(got), 4)
    assert_equal(got[0], "a")
    assert_equal(got[1], "lv")
    assert_equal(got[2], "b")
    assert_equal(got[3], "rv")
    # No name collision: every restoring expression is a bare col-ref.
    for i in range(4):
        assert_true(out._project.value()[].exprs[i].is_col_ref())


def test_inner_swap_with_colliding_names_restores_by_position() raises:
    """Both sides have `k` and `val`. After the exchange the bare `k` is the
    OTHER relation's column, so the projection must alias `k_right` back to
    `k` (and `k` to `k_right`). Catches a by-name restore, which returns the
    right relation's values under the left relation's names."""
    var n: List[String] = ["k", "val"]
    var j = _join(_ints("l", n, 10), _ints("r", n, 1000), "k", "k", JOIN_INNER)
    var out = select_join_build_side(j^)
    assert_equal(Int(out.tag), Int(PLAN_PROJECT))
    var got = _names(out)
    assert_equal(got[0], "k")
    assert_equal(got[1], "val")
    assert_equal(got[2], "k_right")
    assert_equal(got[3], "val_right")
    ref ex = out._project.value()[].exprs
    assert_true(ex[0].is_alias())
    assert_equal(ex[0].alias_child_ref().col_ref_name(), "k_right")
    assert_true(ex[2].is_alias())
    assert_equal(ex[2].alias_child_ref().col_ref_name(), "k")


def test_inner_keeps_the_order_when_the_build_side_is_cheaper() raises:
    """L (1000) probes, R (10) builds: no swap, no added node. Catches a swap
    on the wrong side of the comparison."""
    var ln: List[String] = ["a", "lv"]
    var rn: List[String] = ["b", "rv"]
    var j = _join(_ints("l", ln, 1000), _ints("r", rn, 10), "a", "b", JOIN_INNER)
    var out = select_join_build_side(j^)
    assert_equal(Int(out.tag), Int(PLAN_JOIN))
    assert_equal(_scan_path(out._join.value()[].left[]), "l")


def test_a_residual_join_is_never_swapped() raises:
    """The residual's col-refs are named against the joined layout; a swap
    would re-point them. Catches the residual guard dropped."""
    var ln: List[String] = ["a", "lv"]
    var rn: List[String] = ["b", "rv"]
    var lo: List[String] = ["a"]
    var ro: List[String] = ["b"]
    var res = Optional[OwnedPointer[Expr]](
        OwnedPointer(Expr.binary(BIN_LT, Expr.col_ref("lv"), Expr.col_ref("rv")))
    )
    var j = LogicalPlan.join(
        _ints("l", ln, 10), _ints("r", rn, 1000), lo^, ro^, JOIN_INNER,
        JOIN_ALGO_AUTO, res^,
    )
    var out = select_join_build_side(j^)
    assert_equal(Int(out.tag), Int(PLAN_JOIN))
    assert_equal(_scan_path(out._join.value()[].left[]), "l")


# -----------------------------------------------------------------------------
# The single-key STRING-payload override
# -----------------------------------------------------------------------------


def test_wide_string_payload_predicate() raises:
    """True only for MORE THAN 3 non-key payload columns with a STRING among
    them; key columns are not payload. Catches `> 3` weakened to `>= 3`, the
    STRING test dropped and keys counted as payload."""
    var keys: List[String] = ["k"]
    var none: List[String] = []
    assert_true(_side_has_wide_string_build_payload(_wide_string("w", "k", 1), keys))
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, True))
    sb.add_field(Field("s", ArrowType.STRING, True))
    sb.add_field(Field("a", ArrowType.INT64, True))
    sb.add_field(Field("b", ArrowType.INT64, True))
    var three = _scan_rows("t", sb.build(), 1)
    assert_false(_side_has_wide_string_build_payload(three, keys))
    # The same side with no key named: k becomes a fourth payload column.
    assert_true(_side_has_wide_string_build_payload(three, none))
    var n: List[String] = ["k", "a", "b", "c", "d"]
    assert_false(_side_has_wide_string_build_payload(_ints("i", n, 1), keys))


def test_wide_string_build_side_is_moved_to_probe_against_the_cost() raises:
    """R (10 rows) is cheaper and would build, but carries a wide STRING
    payload: the rule swaps anyway. Catches the override arm dropped."""
    var ln: List[String] = ["a", "lv"]
    var j = _join(_ints("l", ln, 1000), _wide_string("r", "b", 10), "a", "b", JOIN_INNER)
    var out = select_join_build_side(j^)
    assert_equal(Int(out.tag), Int(PLAN_PROJECT))
    assert_equal(_scan_path(out._project.value()[].child[]._join.value()[].right[]), "l")


def test_wide_string_probe_side_stays_on_probe_against_the_cost() raises:
    """L (10 rows) is cheaper so the cost says swap, but L carries a wide
    STRING payload and would become the build side: no swap. Catches the
    keep arm dropped."""
    var rn: List[String] = ["b", "rv"]
    var j = _join(_wide_string("l", "a", 10), _ints("r", rn, 1000), "a", "b", JOIN_INNER)
    var out = select_join_build_side(j^)
    assert_equal(Int(out.tag), Int(PLAN_JOIN))
    assert_equal(_scan_path(out._join.value()[].left[]), "l")


def test_both_sides_wide_string_leaves_the_cost_decision() raises:
    """Swapping cannot help when both sides are wide-STRING: the cost decides
    (L is cheaper, so swap). Catches either override firing when both are wide."""
    var j = _join(_wide_string("l", "a", 10), _wide_string("r", "b", 1000), "a", "b", JOIN_INNER)
    var out = select_join_build_side(j^)
    assert_equal(Int(out.tag), Int(PLAN_PROJECT))


def test_multi_key_join_skips_the_string_override() raises:
    """The STRING override is single-key only, so a two-key join keeps the
    cost decision (L is costlier: no swap) even with a wide STRING build
    side. Catches the `len(left_on) == 1` guard dropped."""
    var ln: List[String] = ["a", "a2", "lv"]
    var sb = SchemaBuilder()
    sb.add_field(Field("b", ArrowType.INT64, True))
    sb.add_field(Field("b2", ArrowType.INT64, True))
    sb.add_field(Field("s", ArrowType.STRING, True))
    sb.add_field(Field("x", ArrowType.INT64, True))
    sb.add_field(Field("y", ArrowType.INT64, True))
    sb.add_field(Field("z", ArrowType.INT64, True))
    var lo: List[String] = ["a", "a2"]
    var ro: List[String] = ["b", "b2"]
    var j = LogicalPlan.join(
        _ints("l", ln, 1000), _scan_rows("r", sb.build(), 10), lo^, ro^, JOIN_INNER
    )
    var out = select_join_build_side(j^)
    assert_equal(Int(out.tag), Int(PLAN_JOIN))
    assert_equal(_scan_path(out._join.value()[].left[]), "l")


# -----------------------------------------------------------------------------
# SEMI, ANTI, LEFT, RIGHT
# -----------------------------------------------------------------------------


def test_semi_with_an_aggressive_having_on_the_left_swaps() raises:
    """A HAVING on the left (5%) and none on the right: the HAVING side builds.
    The SEMI swap is a bare rebuild with the keys exchanged (no projection: a
    SEMI's output is not `left ++ right`). Catches the SEMI arm dropped and a
    restoring Project added over a SEMI."""
    var rn: List[String] = ["b", "rv"]
    var j = _join(_having(BIN_GT), _ints("r", rn, 10), "g", "b", JOIN_SEMI)
    var out = select_join_build_side(j^)
    assert_equal(Int(out.tag), Int(PLAN_JOIN))
    assert_equal(Int(out._join.value()[].join_type), Int(JOIN_SEMI))
    assert_equal(_scan_path(out._join.value()[].left[]), "r")
    assert_equal(Int(out._join.value()[].right[].tag), Int(PLAN_FILTER))
    assert_equal(out._join.value()[].left_on[0], "b")
    assert_equal(out._join.value()[].right_on[0], "g")


def test_semi_with_having_on_both_sides_does_not_swap() raises:
    """Both sides at 5%: the right side is not `>= 0.10`, so no swap. Catches
    the second half of the SEMI condition dropped."""
    var j = _join(_having(BIN_GT), _having(BIN_LT), "g", "g", JOIN_SEMI)
    var out = select_join_build_side(j^)
    assert_equal(Int(out.tag), Int(PLAN_JOIN))
    assert_equal(Int(out._join.value()[].left[].tag), Int(PLAN_FILTER))
    assert_equal(Int(out._join.value()[].right[].tag), Int(PLAN_FILTER))
    assert_equal(Int(out._join.value()[].left[]._filter.value()[].predicate._binary.value().op), Int(BIN_GT))


def test_right_join_with_a_cheaper_probe_becomes_a_left_join() raises:
    """RIGHT(L 10, R 1000) becomes Project(LEFT(R, L)) with the names restored.
    Catches the RIGHT->LEFT canonical swap dropped."""
    var ln: List[String] = ["a", "lv"]
    var rn: List[String] = ["b", "rv"]
    var j = _join(_ints("l", ln, 10), _ints("r", rn, 1000), "a", "b", JOIN_RIGHT)
    var out = select_join_build_side(j^)
    assert_equal(Int(out.tag), Int(PLAN_PROJECT))
    ref inner = out._project.value()[].child[]
    assert_equal(Int(inner._join.value()[].join_type), Int(JOIN_LEFT))
    assert_equal(_scan_path(inner._join.value()[].left[]), "r")
    var got = _names(out)
    assert_equal(got[0], "a")
    assert_equal(got[3], "rv")


def test_left_join_is_never_turned_into_a_right_join() raises:
    """LEFT(L 10, R 1000): the cost says swap, but the rule emits no RIGHT
    join, so the LEFT join stays. Catches the LEFT->RIGHT gate
    dropped."""
    var ln: List[String] = ["a", "lv"]
    var rn: List[String] = ["b", "rv"]
    var j = _join(_ints("l", ln, 10), _ints("r", rn, 1000), "a", "b", JOIN_LEFT)
    var out = select_join_build_side(j^)
    assert_equal(Int(out.tag), Int(PLAN_JOIN))
    assert_equal(Int(out._join.value()[].join_type), Int(JOIN_LEFT))
    assert_equal(_scan_path(out._join.value()[].left[]), "l")


def test_right_join_with_a_cheaper_build_and_anti_join_are_untouched() raises:
    """RIGHT(L 1000, R 10): no cost reason to swap. ANTI(L 10, R 1000): ANTI is
    asymmetric and never swapped. Catches the outer cost test inverted and
    ANTI admitted to a swap arm."""
    var ln: List[String] = ["a", "lv"]
    var rn: List[String] = ["b", "rv"]
    var rj = _join(_ints("l", ln, 1000), _ints("r", rn, 10), "a", "b", JOIN_RIGHT)
    var out = select_join_build_side(rj^)
    assert_equal(Int(out.tag), Int(PLAN_JOIN))
    assert_equal(Int(out._join.value()[].join_type), Int(JOIN_RIGHT))
    var aj = _join(_ints("l", ln, 10), _ints("r", rn, 1000), "a", "b", JOIN_ANTI)
    var out2 = select_join_build_side(aj^)
    assert_equal(Int(out2.tag), Int(PLAN_JOIN))
    assert_equal(_scan_path(out2._join.value()[].left[]), "l")


# -----------------------------------------------------------------------------
# The recursion arms
# -----------------------------------------------------------------------------


def test_every_wrapper_reaches_a_swappable_join_below_it() raises:
    """Filter, Project, Aggregate, Sort, Limit, Distinct and TopN each recurse
    into their child. Catches a recursion arm dropped."""
    var f = select_join_build_side(LogicalPlan.filter(Expr.col_ref("a"), _small_left_inner()))
    assert_equal(Int(f._filter.value()[].child[].tag), Int(PLAN_PROJECT))

    var pe = ExprArray()
    pe.append(Expr.col_ref("a"))
    var p = select_join_build_side(LogicalPlan.project(pe^, _small_left_inner()))
    assert_equal(Int(p._project.value()[].child[].tag), Int(PLAN_PROJECT))

    var keys = ExprArray()
    keys.append(Expr.col_ref("a"))
    var a = select_join_build_side(LogicalPlan.aggregate(keys^, AggExprArray(), _small_left_inner()))
    assert_equal(Int(a._aggregate.value()[].child[].tag), Int(PLAN_PROJECT))

    var sk: List[String] = ["a"]
    var sd: List[Bool] = [False]
    var s = select_join_build_side(LogicalPlan.sort(sk^, sd^, _small_left_inner()))
    assert_equal(Int(s._sort.value()[].child[].tag), Int(PLAN_PROJECT))

    var l = select_join_build_side(LogicalPlan.limit(4, _small_left_inner()))
    assert_equal(Int(l._limit.value()[].child[].tag), Int(PLAN_PROJECT))

    var d = select_join_build_side(LogicalPlan.distinct(None, _small_left_inner()))
    assert_equal(Int(d._distinct.value()[].child[].tag), Int(PLAN_PROJECT))

    var tk: List[String] = ["a"]
    var td: List[Bool] = [False]
    var t = select_join_build_side(LogicalPlan.topn(tk^, td^, 2, _small_left_inner()))
    assert_equal(Int(t._topn.value()[].child[].tag), Int(PLAN_PROJECT))


def test_join_children_are_rewritten_before_the_parent_decides() raises:
    """A residual parent (never swapped itself) still has both swappable
    children rewritten. Catches the child recursion moved below the residual
    early return."""
    var lo: List[String] = ["a"]
    var ro: List[String] = ["a"]
    var res = Optional[OwnedPointer[Expr]](OwnedPointer(Expr.col_ref("lv")))
    var j = LogicalPlan.join(
        _small_left_inner(), _small_left_inner(), lo^, ro^, JOIN_INNER,
        JOIN_ALGO_AUTO, res^,
    )
    var out = select_join_build_side(j^)
    assert_equal(Int(out.tag), Int(PLAN_JOIN))
    assert_equal(Int(out._join.value()[].left[].tag), Int(PLAN_PROJECT))
    assert_equal(Int(out._join.value()[].right[].tag), Int(PLAN_PROJECT))


def test_a_scan_root_is_returned_unchanged() raises:
    """Catches a walk that raises on a leaf or turns it into another node."""
    var n: List[String] = ["a"]
    var out = select_join_build_side(_ints("l", n, 5))
    assert_equal(Int(out.tag), Int(PLAN_SCAN))


# -----------------------------------------------------------------------------
# The HAVING selectivity heuristic
# -----------------------------------------------------------------------------


def test_having_selectivity_needs_a_filter_over_an_aggregate() raises:
    """A scan and a filter over a scan are not HAVING: 1.0. Catches either
    shape test dropped (a WHERE filter would then count as a HAVING)."""
    var n: List[String] = ["g"]
    assert_equal(_estimate_having_selectivity(_ints("s", n, 5)), 1.0)
    var f = LogicalPlan.filter(
        Expr.binary(BIN_GT, Expr.col_ref("g"), Expr.literal(ScalarValue.from_int64(Int64(1)))),
        _ints("s", n, 5),
    )
    assert_equal(_estimate_having_selectivity(f), 1.0)


def test_having_selectivity_per_operator() raises:
    """Each comparison is 0.05, AND 0.0025, OR 0.10, another binary op 0.5.
    Catches a comparison operator missing from the list and the AND/OR values
    exchanged."""
    var cmp_ops: List[UInt8] = [BIN_EQ, BIN_NE, BIN_LT, BIN_LE, BIN_GT, BIN_GE]
    for i in range(len(cmp_ops)):
        assert_equal(_estimate_having_selectivity(_having(cmp_ops[i])), 0.05)
    assert_equal(_estimate_having_selectivity(_having(BIN_AND)), 0.05 * 0.05)
    assert_equal(_estimate_having_selectivity(_having(BIN_OR)), 0.10)
    assert_equal(_estimate_having_selectivity(_having(BIN_ADD)), 0.5)


def test_having_selectivity_of_a_non_binary_predicate_and_a_non_filter() raises:
    """A bare column predicate gives no signal: 0.5. The predicate estimator
    called on a non-filter answers 1.0. Catches both fallbacks."""
    var n: List[String] = ["g", "x"]
    var keys = ExprArray()
    keys.append(Expr.col_ref("g"))
    var agg = LogicalPlan.aggregate(keys^, AggExprArray(), _ints("h", n, 10))
    var f = LogicalPlan.filter(Expr.col_ref("g"), agg^)
    assert_equal(_estimate_having_selectivity(f), 0.5)
    assert_equal(_estimate_predicate_selectivity_from_plan(_ints("h", n, 10)), 1.0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
