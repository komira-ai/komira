# =============================================================================
# Rule 17, `select_join_build_side`: every build-side decision, the
# STRING-payload override and the HAVING selectivity heuristic.
# =============================================================================
#
# The rule RECORDS its decision in `JoinData.build_side` and changes nothing
# else: it builds LEFT on an INNER join whose left side is cheaper, a SEMI
# whose left side is an aggressive HAVING, and a RIGHT join whose left side is
# cheaper; every other join it reaches builds RIGHT. The operands, join type,
# keys and output schema stay as they came in.
#
# THE NO-REWRITE PIN. `_assert_only_build_side_changed` clears `build_side`
# on the rule's output and requires the result to hash exactly like the
# input, so any operand exchange, added Project or join-type flip goes red.
# Mutant: restore the old exchange (swap the operands and re-project) in
# `select_join_build_side_inplace` — every test that records LEFT fails, on the
# tag (a Project), the left scan path, or the hash pin. Each test names the
# defect it catches.
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
from komira_plan_expr.partition_expr import PartitionExpr
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    AsofTolerance,
    ASOF_BACKWARD,
    EXCHANGE_KIND_GATHER,
    PLAN_PARTITION_BY,
    PLAN_PARTITION_TOPN,
    PLAN_ASOF_JOIN,
    PLAN_UNION,
    PLAN_VIEW_REF,
    PLAN_CSE_REF,
    PLAN_CAST_TO_VARCHAR,
    PLAN_EXCHANGE,
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
    JOIN_BUILD_SIDE_LEFT,
    JOIN_BUILD_SIDE_RIGHT,
    JOIN_BUILD_SIDE_UNSET,
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


def _side(p: LogicalPlan) -> Int:
    return Int(p._join.value()[].build_side)


def _assert_only_build_side_changed(
    var out: LogicalPlan, before: UInt64, want_side: UInt8
) raises:
    """`out` is a join carrying `want_side`, and with every join's build side
    cleared it hashes exactly like the input did (`before`). Catches the rule
    exchanging operands, adding a Project, flipping a join type or rebuilding
    a child in any way the render can see."""
    assert_equal(Int(out.tag), Int(PLAN_JOIN))
    assert_equal(_side(out), Int(want_side))
    _assert_every_join_decided(out, "rule output")
    _clear_build_sides(out)
    assert_equal(out.structural_hash(), before)


def _count_undecided_joins(p: LogicalPlan) raises -> Int:
    """How many PLAN_JOIN nodes in `p` still carry `JOIN_BUILD_SIDE_UNSET`.
    Walks every node kind that has children, and RAISES on a tag it has no
    arm for, so a fixture that grows a new node kind cannot hide a join from
    the check."""
    if p.tag == PLAN_JOIN:
        var n = 0
        if p._join.value()[].build_side == JOIN_BUILD_SIDE_UNSET:
            n = 1
        return (
            n
            + _count_undecided_joins(p._join.value()[].left[])
            + _count_undecided_joins(p._join.value()[].right[])
        )
    if p.tag == PLAN_SCAN:
        return 0
    if p.tag == PLAN_FILTER:
        return _count_undecided_joins(p._filter.value()[].child[])
    if p.tag == PLAN_PROJECT:
        return _count_undecided_joins(p._project.value()[].child[])
    if p.tag == PLAN_AGGREGATE:
        return _count_undecided_joins(p._aggregate.value()[].child[])
    if p.tag == PLAN_SORT:
        return _count_undecided_joins(p._sort.value()[].child[])
    if p.tag == PLAN_LIMIT:
        return _count_undecided_joins(p._limit.value()[].child[])
    if p.tag == PLAN_DISTINCT:
        return _count_undecided_joins(p._distinct.value()[].child[])
    if p.tag == PLAN_TOPN:
        return _count_undecided_joins(p._topn.value()[].child[])
    if p.tag == PLAN_PARTITION_BY:
        return _count_undecided_joins(p._partition_by.value()[].child[])
    if p.tag == PLAN_PARTITION_TOPN:
        return _count_undecided_joins(p._partition_topn.value()[].child[])
    if p.tag == PLAN_ASOF_JOIN:
        return (
            _count_undecided_joins(p._asof_join.value()[].left[])
            + _count_undecided_joins(p._asof_join.value()[].right[])
        )
    if p.tag == PLAN_UNION:
        var n = 0
        for i in range(p._union.value()[].num_children()):
            n += _count_undecided_joins(p._union.value()[].children[i][])
        return n
    if p.tag == PLAN_CAST_TO_VARCHAR:
        return _count_undecided_joins(p._cast_to_varchar.value()[].child[])
    if p.tag == PLAN_EXCHANGE:
        return _count_undecided_joins(p._exchange.value()[].child[])
    if p.tag == PLAN_VIEW_REF or p.tag == PLAN_CSE_REF:
        return 0
    raise Error("_count_undecided_joins: no arm for plan tag " + String(Int(p.tag)))


def _assert_every_join_decided(p: LogicalPlan, what: String) raises:
    """EVERY JOIN HAS A BUILD SIDE AFTER RULE 17. UNSET is acceptable only in
    a RAW plan; an OPTIMIZED plan must carry a decision on every join
    (docs/design/optimized_plan.md §5.2: `build_side` is required). This is
    the fixture-level form of that check; the post-optimize form over the
    driver's corpus is in `test_optimizer_driver_corpus`."""
    var n = _count_undecided_joins(p)
    assert_equal(n, 0, what + ": " + String(n) + " join(s) left UNSET")


def _clear_build_sides(mut p: LogicalPlan):
    if p.tag == PLAN_JOIN:
        p._join.value()[].build_side = JOIN_BUILD_SIDE_UNSET
        _clear_build_sides(p._join.value()[].left[])
        _clear_build_sides(p._join.value()[].right[])
    elif p.tag == PLAN_FILTER:
        _clear_build_sides(p._filter.value()[].child[])
    elif p.tag == PLAN_PROJECT:
        _clear_build_sides(p._project.value()[].child[])


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


def test_inner_builds_left_when_the_left_side_is_cheaper() raises:
    """L (10 rows) and R (1000): build on L. The join is left in place: L is
    still the left child, the keys and the output names are unchanged, and no
    Project is added. Catches the cost comparison inverted and the old operand
    exchange restored."""
    var j = _small_left_inner()
    var before = j.structural_hash()
    var out = select_join_build_side(j^)
    assert_equal(_scan_path(out._join.value()[].left[]), "l")
    assert_equal(_scan_path(out._join.value()[].right[]), "r")
    assert_equal(out._join.value()[].left_on[0], "a")
    assert_equal(out._join.value()[].right_on[0], "b")
    var got = _names(out)
    assert_equal(len(got), 4)
    assert_equal(got[0], "a")
    assert_equal(got[1], "lv")
    assert_equal(got[2], "b")
    assert_equal(got[3], "rv")
    _assert_only_build_side_changed(out^, before, JOIN_BUILD_SIDE_LEFT)


def test_inner_with_colliding_names_keeps_every_name_on_its_relation() raises:
    """Both sides have `k` and `val`. Recording the build side moves no
    column: `k` and `val` stay the left relation's, `k_right` and `val_right`
    the right one's, with no aliasing Project. Catches an exchange, which
    migrates the `_right` suffix to the other relation."""
    var n: List[String] = ["k", "val"]
    var j = _join(_ints("l", n, 10), _ints("r", n, 1000), "k", "k", JOIN_INNER)
    var before = j.structural_hash()
    var out = select_join_build_side(j^)
    var got = _names(out)
    assert_equal(got[0], "k")
    assert_equal(got[1], "val")
    assert_equal(got[2], "k_right")
    assert_equal(got[3], "val_right")
    assert_equal(_scan_path(out._join.value()[].left[]), "l")
    _assert_only_build_side_changed(out^, before, JOIN_BUILD_SIDE_LEFT)


def test_inner_builds_right_when_the_right_side_is_cheaper() raises:
    """L (1000) and R (10): build on R, recorded. Catches a decision on the
    wrong side of the comparison and an undecided (UNSET) join left behind."""
    var ln: List[String] = ["a", "lv"]
    var rn: List[String] = ["b", "rv"]
    var j = _join(_ints("l", ln, 1000), _ints("r", rn, 10), "a", "b", JOIN_INNER)
    var before = j.structural_hash()
    var out = select_join_build_side(j^)
    _assert_only_build_side_changed(out^, before, JOIN_BUILD_SIDE_RIGHT)


def test_a_residual_join_builds_right() raises:
    """The residual guard keeps the convention even where the cost would say
    LEFT. Catches the residual guard dropped."""
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
    var before = j.structural_hash()
    var out = select_join_build_side(j^)
    _assert_only_build_side_changed(out^, before, JOIN_BUILD_SIDE_RIGHT)


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


def test_wide_string_right_side_does_not_build_against_the_cost() raises:
    """R (10 rows) is cheaper and would build, but carries a wide STRING
    payload: build LEFT anyway. Catches the override arm dropped."""
    var ln: List[String] = ["a", "lv"]
    var j = _join(_ints("l", ln, 1000), _wide_string("r", "b", 10), "a", "b", JOIN_INNER)
    var before = j.structural_hash()
    var out = select_join_build_side(j^)
    _assert_only_build_side_changed(out^, before, JOIN_BUILD_SIDE_LEFT)


def test_wide_string_left_side_does_not_build_against_the_cost() raises:
    """L (10 rows) is cheaper so the cost says LEFT, but L carries a wide
    STRING payload: build RIGHT. Catches the keep arm dropped."""
    var rn: List[String] = ["b", "rv"]
    var j = _join(_wide_string("l", "a", 10), _ints("r", rn, 1000), "a", "b", JOIN_INNER)
    var before = j.structural_hash()
    var out = select_join_build_side(j^)
    _assert_only_build_side_changed(out^, before, JOIN_BUILD_SIDE_RIGHT)


def test_both_sides_wide_string_leaves_the_cost_decision() raises:
    """The override cannot help when both sides are wide-STRING: the cost
    decides (L is cheaper: LEFT). Catches either override firing when both
    are wide."""
    var j = _join(_wide_string("l", "a", 10), _wide_string("r", "b", 1000), "a", "b", JOIN_INNER)
    var before = j.structural_hash()
    var out = select_join_build_side(j^)
    _assert_only_build_side_changed(out^, before, JOIN_BUILD_SIDE_LEFT)


def test_multi_key_join_skips_the_string_override() raises:
    """The STRING override is single-key only, so a two-key join keeps the
    cost decision (L is costlier: RIGHT) even with a wide STRING right side.
    Catches the `len(left_on) == 1` guard dropped."""
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
    var before = j.structural_hash()
    var out = select_join_build_side(j^)
    _assert_only_build_side_changed(out^, before, JOIN_BUILD_SIDE_RIGHT)


# -----------------------------------------------------------------------------
# SEMI, ANTI, LEFT, RIGHT
# -----------------------------------------------------------------------------


def test_semi_with_an_aggressive_having_on_the_left_builds_left() raises:
    """A HAVING on the left (5%) and none on the right: the HAVING side
    builds. The node stays SEMI(having, r) and still emits the having side's
    columns. Catches the SEMI arm dropped, and the old exchange, which turned
    SEMI(A, B) into SEMI(B, A) and so emitted B's columns instead of A's."""
    var rn: List[String] = ["b", "rv"]
    var j = _join(_having(BIN_GT), _ints("r", rn, 10), "g", "b", JOIN_SEMI)
    var before = j.structural_hash()
    var out = select_join_build_side(j^)
    assert_equal(Int(out._join.value()[].join_type), Int(JOIN_SEMI))
    assert_equal(Int(out._join.value()[].left[].tag), Int(PLAN_FILTER))
    assert_equal(_scan_path(out._join.value()[].right[]), "r")
    assert_equal(_names(out)[0], "g")
    _assert_only_build_side_changed(out^, before, JOIN_BUILD_SIDE_LEFT)


def test_semi_with_having_on_both_sides_builds_right() raises:
    """Both sides at 5%: the right side is not `>= 0.10`, so RIGHT. Catches
    the second half of the SEMI condition dropped."""
    var j = _join(_having(BIN_GT), _having(BIN_LT), "g", "g", JOIN_SEMI)
    var before = j.structural_hash()
    var out = select_join_build_side(j^)
    _assert_only_build_side_changed(out^, before, JOIN_BUILD_SIDE_RIGHT)


def test_right_join_with_a_cheaper_left_side_builds_left() raises:
    """RIGHT(L 10, R 1000) stays a RIGHT join over (L, R) and builds on L,
    the NULL-supplying side. Catches the RIGHT arm dropped and the old
    RIGHT->LEFT flip (a LEFT join over (R, L) under a restoring Project)."""
    var ln: List[String] = ["a", "lv"]
    var rn: List[String] = ["b", "rv"]
    var j = _join(_ints("l", ln, 10), _ints("r", rn, 1000), "a", "b", JOIN_RIGHT)
    var before = j.structural_hash()
    var out = select_join_build_side(j^)
    assert_equal(Int(out._join.value()[].join_type), Int(JOIN_RIGHT))
    assert_equal(_scan_path(out._join.value()[].left[]), "l")
    _assert_only_build_side_changed(out^, before, JOIN_BUILD_SIDE_LEFT)


def test_left_join_never_builds_its_preserved_side() raises:
    """LEFT(L 10, R 1000): the cost favours L, but the rule never builds a
    LEFT join's preserved side, so RIGHT. Catches the RIGHT-only gate
    widened to LEFT joins."""
    var ln: List[String] = ["a", "lv"]
    var rn: List[String] = ["b", "rv"]
    var j = _join(_ints("l", ln, 10), _ints("r", rn, 1000), "a", "b", JOIN_LEFT)
    var before = j.structural_hash()
    var out = select_join_build_side(j^)
    _assert_only_build_side_changed(out^, before, JOIN_BUILD_SIDE_RIGHT)


def test_right_join_with_a_cheaper_right_side_and_anti_join_build_right() raises:
    """RIGHT(L 1000, R 10): no cost reason to build left. ANTI(L 10, R 1000):
    ANTI always builds right. Catches the outer cost test inverted and ANTI
    admitted to a LEFT arm."""
    var ln: List[String] = ["a", "lv"]
    var rn: List[String] = ["b", "rv"]
    var rj = _join(_ints("l", ln, 1000), _ints("r", rn, 10), "a", "b", JOIN_RIGHT)
    var rb = rj.structural_hash()
    _assert_only_build_side_changed(select_join_build_side(rj^), rb, JOIN_BUILD_SIDE_RIGHT)
    var aj = _join(_ints("l", ln, 10), _ints("r", rn, 1000), "a", "b", JOIN_ANTI)
    var ab = aj.structural_hash()
    _assert_only_build_side_changed(select_join_build_side(aj^), ab, JOIN_BUILD_SIDE_RIGHT)


def test_the_rule_is_idempotent() raises:
    """A second run records the same sides and changes nothing. Catches a rule
    that reads its own previous decision as a reason to flip."""
    var once = select_join_build_side(_small_left_inner())
    var h = once.structural_hash()
    var twice = select_join_build_side(once^)
    assert_equal(twice.structural_hash(), h)
    assert_equal(_side(twice), Int(JOIN_BUILD_SIDE_LEFT))


# -----------------------------------------------------------------------------
# The recursion arms
# -----------------------------------------------------------------------------


def test_every_wrapper_reaches_a_join_below_it() raises:
    """Filter, Project, Aggregate, Sort, Limit, Distinct and TopN each recurse
    into their child, whose join gets LEFT recorded and stays a join. Catches
    a recursion arm dropped."""
    var f = select_join_build_side(LogicalPlan.filter(Expr.col_ref("a"), _small_left_inner()))
    assert_equal(_side(f._filter.value()[].child[]), Int(JOIN_BUILD_SIDE_LEFT))
    _assert_every_join_decided(f, "filter")

    var pe = ExprArray()
    pe.append(Expr.col_ref("a"))
    var p = select_join_build_side(LogicalPlan.project(pe^, _small_left_inner()))
    assert_equal(_side(p._project.value()[].child[]), Int(JOIN_BUILD_SIDE_LEFT))

    var keys = ExprArray()
    keys.append(Expr.col_ref("a"))
    var a = select_join_build_side(LogicalPlan.aggregate(keys^, AggExprArray(), _small_left_inner()))
    assert_equal(_side(a._aggregate.value()[].child[]), Int(JOIN_BUILD_SIDE_LEFT))

    var sk: List[String] = ["a"]
    var sd: List[Bool] = [False]
    var s = select_join_build_side(LogicalPlan.sort(sk^, sd^, _small_left_inner()))
    assert_equal(_side(s._sort.value()[].child[]), Int(JOIN_BUILD_SIDE_LEFT))

    var l = select_join_build_side(LogicalPlan.limit(4, _small_left_inner()))
    assert_equal(_side(l._limit.value()[].child[]), Int(JOIN_BUILD_SIDE_LEFT))

    var d = select_join_build_side(LogicalPlan.distinct(None, _small_left_inner()))
    assert_equal(_side(d._distinct.value()[].child[]), Int(JOIN_BUILD_SIDE_LEFT))

    var tk: List[String] = ["a"]
    var td: List[Bool] = [False]
    var t = select_join_build_side(LogicalPlan.topn(tk^, td^, 2, _small_left_inner()))
    assert_equal(_side(t._topn.value()[].child[]), Int(JOIN_BUILD_SIDE_LEFT))
    _assert_every_join_decided(p, "project")
    _assert_every_join_decided(a, "aggregate")
    _assert_every_join_decided(s, "sort")
    _assert_every_join_decided(l, "limit")
    _assert_every_join_decided(d, "distinct")
    _assert_every_join_decided(t, "topn")


def _two_joins_union() -> LogicalPlan:
    var a = _small_left_inner()
    var schema = a.output_schema.copy()
    var kids = List[OwnedPointer[LogicalPlan]]()
    kids.append(OwnedPointer(a^))
    kids.append(OwnedPointer(_small_left_inner()))
    return LogicalPlan.union(kids^, schema^)


def test_every_node_with_children_reaches_a_join_below_it() raises:
    """PartitionBy, PartitionTopN, an as-of join (both inputs), a Union (every
    branch), CastToVarchar and an Exchange each recurse into their children,
    whose joins get LEFT recorded. Catches a recursion arm missing: the join
    below it keeps UNSET, which an OPTIMIZED plan may not carry (the walk
    reached none of these six before this arm list; a window over a join was
    left undecided)."""
    var pk: List[String] = ["a"]
    var ok: List[String] = ["a"]
    var desc: List[Bool] = [False]
    var pe = List[PartitionExpr]()
    pe.append(PartitionExpr.row_number())
    var pb = select_join_build_side(
        LogicalPlan.partition_by(pk^, ok^, desc^, pe^, _small_left_inner())
    )
    assert_equal(Int(pb.tag), Int(PLAN_PARTITION_BY))
    assert_equal(_side(pb._partition_by.value()[].child[]), Int(JOIN_BUILD_SIDE_LEFT))
    _assert_every_join_decided(pb, "partition_by")

    var tpk: List[String] = ["a"]
    var tsk: List[String] = ["a"]
    var tdesc: List[Bool] = [False]
    var pt = select_join_build_side(
        LogicalPlan.partition_topn(tpk^, tsk^, tdesc^, 1, _small_left_inner())
    )
    assert_equal(_side(pt._partition_topn.value()[].child[]), Int(JOIN_BUILD_SIDE_LEFT))
    _assert_every_join_decided(pt, "partition_topn")

    var aj = select_join_build_side(
        LogicalPlan.asof_join(
            _small_left_inner(), _small_left_inner(), List[String](),
            List[String](), String("a"), String("a"), ASOF_BACKWARD,
            AsofTolerance.none(),
        )
    )
    assert_equal(Int(aj.tag), Int(PLAN_ASOF_JOIN))
    assert_equal(_side(aj._asof_join.value()[].left[]), Int(JOIN_BUILD_SIDE_LEFT))
    assert_equal(_side(aj._asof_join.value()[].right[]), Int(JOIN_BUILD_SIDE_LEFT))
    _assert_every_join_decided(aj, "asof_join")

    var u = select_join_build_side(_two_joins_union())
    assert_equal(_side(u._union.value()[].children[0][]), Int(JOIN_BUILD_SIDE_LEFT))
    assert_equal(_side(u._union.value()[].children[1][]), Int(JOIN_BUILD_SIDE_LEFT))
    _assert_every_join_decided(u, "union")

    var c = select_join_build_side(LogicalPlan.cast_to_varchar(_small_left_inner()))
    assert_equal(_side(c._cast_to_varchar.value()[].child[]), Int(JOIN_BUILD_SIDE_LEFT))
    _assert_every_join_decided(c, "cast_to_varchar")

    var x = select_join_build_side(
        LogicalPlan.exchange(_small_left_inner(), EXCHANGE_KIND_GATHER)
    )
    assert_equal(_side(x._exchange.value()[].child[]), Int(JOIN_BUILD_SIDE_LEFT))
    _assert_every_join_decided(x, "exchange")


def test_leaves_pass_and_an_unknown_tag_is_refused() raises:
    """A view reference and a CSE reference are leaves: returned with their
    tag. A tag with no arm (the retired id 16) raises, naming the tag, rather
    than being passed over. Catches the leaf arm dropped (the leaves would
    raise) and a fall-through `else` (a join below an unknown node would be
    silently left UNSET)."""
    var n: List[String] = ["a"]
    var v = select_join_build_side(LogicalPlan(PLAN_VIEW_REF, _int_schema(n)))
    assert_equal(Int(v.tag), Int(PLAN_VIEW_REF))
    var c = select_join_build_side(LogicalPlan(PLAN_CSE_REF, _int_schema(n)))
    assert_equal(Int(c.tag), Int(PLAN_CSE_REF))
    var msg = String("")
    try:
        _ = select_join_build_side(LogicalPlan(UInt8(16), _int_schema(n)))
    except e:
        msg = String(e)
    assert_equal(msg, "select_join_build_side: no arm for plan tag 16")


def test_join_children_are_decided_as_well_as_the_parent() raises:
    """A residual parent (RIGHT) still has both child joins decided (LEFT
    each), and nothing moves. Catches the child recursion moved below the
    parent's decision or dropped."""
    var lo: List[String] = ["a"]
    var ro: List[String] = ["a"]
    var res = Optional[OwnedPointer[Expr]](OwnedPointer(Expr.col_ref("lv")))
    var j = LogicalPlan.join(
        _small_left_inner(), _small_left_inner(), lo^, ro^, JOIN_INNER,
        JOIN_ALGO_AUTO, res^,
    )
    var before = j.structural_hash()
    var out = select_join_build_side(j^)
    assert_equal(_side(out._join.value()[].left[]), Int(JOIN_BUILD_SIDE_LEFT))
    assert_equal(_side(out._join.value()[].right[]), Int(JOIN_BUILD_SIDE_LEFT))
    _assert_only_build_side_changed(out^, before, JOIN_BUILD_SIDE_RIGHT)


def test_the_decided_check_can_fail() raises:
    """The check is not vacuous: before the rule, a two-level join tree has
    three UNSET joins and the count says so; after it, none. Catches a
    `_count_undecided_joins` that stops at the root or never counts."""
    var lo: List[String] = ["a"]
    var ro: List[String] = ["a"]
    var j = LogicalPlan.join(
        _small_left_inner(), _small_left_inner(), lo^, ro^, JOIN_INNER
    )
    assert_equal(_count_undecided_joins(j), 3)
    var out = select_join_build_side(j^)
    assert_equal(_count_undecided_joins(out), 0)


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
