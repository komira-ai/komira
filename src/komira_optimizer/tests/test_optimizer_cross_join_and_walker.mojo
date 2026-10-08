# =============================================================================
# test_optimizer_cross_join_and_walker.mojo -- Rule 19 (eliminate cross join
# and fold equi-filters into joins), the filter-pushdown column walker, and the
# branches of the residual-to-side rule the welded tests do not reach.
# =============================================================================
#
# `eliminate_cross_join` has three fold sites (Filter over CROSS, Filter over
# INNER, Filter over a CSE Project over CROSS), each with a "residual left" and
# an "all folded" outcome, and one key extractor that must classify a
# conjunct's two columns by side (direct, swapped, `_right`-renamed) and admit
# only key types the join-key envelope serves. `_predicate_refs_in_schema`
# decides which side a predicate belongs to; a missing arm makes a predicate
# look like it references EVERY schema and parks it above the join.
#
# Schemas: t(a, b, c INT64, u UINT32), r(ra, rb INT64, ru UINT32), and
# q(a INT64, qb INT64) whose `a` collides with t's (renamed `a_right` above
# the join). UINT32 is outside the join-key envelope.
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.agg_expr import AggExpr, AGG_COUNT
from komira_plan_expr.expr import (
    Expr,
    BIN_AND,
    BIN_EQ,
    BIN_GT,
    BIN_LT,
    UN_NOT,
    STR_LIKE,
    STRFN_UPPER,
    STRFNN_CONCAT,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    PLAN_SCAN,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_JOIN,
    JOIN_INNER,
    JOIN_CROSS,
    JOIN_LEFT,
    JOIN_RIGHT,
    JOIN_FULL,
    JOIN_ALGO_AUTO,
    SOURCE_PARQUET,
)
from komira_optimizer.optimizer_filter import (
    eliminate_cross_join,
    push_join_residual_to_side,
    _column_is_supported_key,
    _predicate_refs_in_schema,
)


# -----------------------------------------------------------------------------
# fixtures
# -----------------------------------------------------------------------------


def _schema3(n0: String, n1: String, n2: String, t2: ArrowType) -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(n0, ArrowType.INT64, True))
    sb.add_field(Field(n1, ArrowType.INT64, True))
    sb.add_field(Field(n2, t2, True))
    return sb.build()


def _t() -> LogicalPlan:
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, True))
    sb.add_field(Field("b", ArrowType.INT64, True))
    sb.add_field(Field("c", ArrowType.INT64, True))
    sb.add_field(Field("u", ArrowType.UINT32, True))
    return LogicalPlan.scan("t.parquet", SOURCE_PARQUET, sb.build())


def _r() -> LogicalPlan:
    return LogicalPlan.scan(
        "r.parquet", SOURCE_PARQUET, _schema3("ra", "rb", "ru", ArrowType.UINT32)
    )


def _q() -> LogicalPlan:
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, True))
    sb.add_field(Field("qb", ArrowType.INT64, True))
    return LogicalPlan.scan("q.parquet", SOURCE_PARQUET, sb.build())


def _lit(n: Int) -> Expr:
    return Expr.literal(ScalarValue.from_int64(Int64(n)))


def _gt(name: String, n: Int) -> Expr:
    return Expr.binary(BIN_GT, Expr.col_ref(name), _lit(n))


def _eq(l: String, r: String) -> Expr:
    return Expr.binary(BIN_EQ, Expr.col_ref(l), Expr.col_ref(r))


def _and(var l: Expr, var r: Expr) -> Expr:
    return Expr.binary(BIN_AND, l^, r^)


def _render(e: Expr) -> String:
    var s = String("")
    e.write_to(s)
    return s


def _cross(var l: LogicalPlan, var r: LogicalPlan) -> LogicalPlan:
    return LogicalPlan.join(l^, r^, List[String](), List[String](), JOIN_CROSS)


def _inner_a_ra() -> LogicalPlan:
    var lk = List[String]()
    lk.append("a")
    var rk = List[String]()
    rk.append("ra")
    return LogicalPlan.join(_t(), _r(), lk^, rk^, JOIN_INNER)


def _keys(p: LogicalPlan) -> String:
    """`left_on|right_on` of a join, comma-joined, e.g. "a,b|ra,rb"."""
    ref jd = p._join.value()[]
    var s = String("")
    for i in range(len(jd.left_on)):
        if i > 0:
            s += ","
        s += jd.left_on[i]
    s += "|"
    for i in range(len(jd.right_on)):
        if i > 0:
            s += ","
        s += jd.right_on[i]
    return s


def _folded_join(p: LogicalPlan, keys: String) -> Bool:
    """`p` is an INNER join with exactly `keys` (the Filter was dropped)."""
    return (
        p.tag == PLAN_JOIN
        and p._join.value()[].join_type == JOIN_INNER
        and _keys(p) == keys
    )


def _ecj(var pred: Expr, var child: LogicalPlan) raises -> LogicalPlan:
    return eliminate_cross_join(LogicalPlan.filter(pred^, child^))


# -----------------------------------------------------------------------------
# Filter over CROSS
# -----------------------------------------------------------------------------


def test_cross_with_only_equi_keys_becomes_inner_and_drops_the_filter() raises:
    # Defect: no fold (a Cartesian product), or the empty Filter left behind.
    var out = _ecj(_eq("a", "ra"), _cross(_t(), _r()))
    assert_true(_folded_join(out, "a|ra"), _keys(out) if out.tag == PLAN_JOIN else String(""))


def test_cross_with_a_residual_keeps_only_the_residual_above() raises:
    # Defect: the residual dropped, or the equi-key kept in it too.
    var out = _ecj(_and(_eq("a", "ra"), _gt("b", 1)), _cross(_t(), _r()))
    assert_equal(Int(out.tag), Int(PLAN_FILTER))
    var r = _render(out._filter.value()[].predicate)
    assert_true(r.find("ColRef(b)") >= 0 and r.find("ColRef(ra)") < 0, r)
    assert_true(_folded_join(out._filter.value()[].child[], "a|ra"))


def test_cross_without_an_equi_key_is_left_alone() raises:
    # `b > 1` and `a = 1` (a literal operand) are not keys; `a = b` names the
    # left side twice. Defect: a non-key conjunct folded, or the join type
    # changed with no keys.
    var pred = _and(_and(_gt("b", 1), Expr.binary(BIN_EQ, Expr.col_ref("a"), _lit(1))), _eq("a", "b"))
    var out = _ecj(pred^, _cross(_t(), _r()))
    assert_equal(Int(out.tag), Int(PLAN_FILTER))
    ref j = out._filter.value()[].child[]
    assert_equal(Int(j._join.value()[].join_type), Int(JOIN_CROSS))
    assert_equal(len(j._join.value()[].left_on), 0)


def test_swapped_operands_are_classified_by_side() raises:
    # `ra = a`: the left operand is the right key. Defect: keys emitted in
    # operand order (left_on would name a right column).
    var out = _ecj(_eq("ra", "a"), _cross(_t(), _r()))
    assert_true(_folded_join(out, "a|ra"))


def test_right_renamed_and_colliding_names_map_to_the_right_child() raises:
    # Over t x q the right `a` is output as `a_right`. `b = a_right` must key
    # on q's own `a`; so must the hand-built `a = a`. Defect: the rename not
    # reversed (`a_right` is in neither child: no fold, a Cartesian product),
    # or the direct-name fallback removed.
    var o1 = _ecj(_eq("b", "a_right"), _cross(_t(), _q()))
    assert_true(_folded_join(o1, "b|a"), _keys(o1) if o1.tag == PLAN_JOIN else String(""))
    var o2 = _ecj(_eq("a", "a"), _cross(_t(), _q()))
    assert_true(_folded_join(o2, "a|a"))
    var o3 = _ecj(_eq("a_right", "b"), _cross(_t(), _q()))
    assert_true(_folded_join(o3, "b|a"), "renamed key on the swapped side")


def test_key_types_outside_the_envelope_are_not_folded() raises:
    # UINT32 is not a join-key type: folding it would key a join on a type
    # `join_key_envelope` does not admit. Defect: the check removed on
    # either side or in either operand order. Each of the four checks has a
    # case where it is the ONLY one that refuses (the other key is INT64), so
    # removing any one of them folds that case.
    var o1 = _ecj(_eq("u", "ru"), _cross(_t(), _r()))
    assert_equal(Int(o1.tag), Int(PLAN_FILTER))
    assert_equal(Int(o1._filter.value()[].child[]._join.value()[].join_type), Int(JOIN_CROSS))
    # Left operand on the left side: the left-key check alone refuses.
    var o4 = _ecj(_eq("u", "ra"), _cross(_t(), _r()))
    assert_equal(Int(o4.tag), Int(PLAN_FILTER), "left key unsupported")
    # Left operand on the left side: the right-key check alone refuses.
    var o2 = _ecj(_eq("a", "ru"), _cross(_t(), _r()))
    assert_equal(Int(o2.tag), Int(PLAN_FILTER), "right key unsupported")
    var o3 = _ecj(_eq("ru", "u"), _cross(_t(), _r()))
    assert_equal(Int(o3.tag), Int(PLAN_FILTER), "swapped, unsupported")
    # Swapped operands: the left-key check alone refuses.
    var o5 = _ecj(_eq("ra", "u"), _cross(_t(), _r()))
    assert_equal(Int(o5.tag), Int(PLAN_FILTER), "swapped, left key unsupported")
    # Swapped operands: the right-key check alone refuses.
    var o6 = _ecj(_eq("ru", "a"), _cross(_t(), _r()))
    assert_equal(Int(o6.tag), Int(PLAN_FILTER), "swapped, right key unsupported")
    # Control: the same shapes with two INT64 keys fold, in both operand
    # orders, so the refusals above are the envelope's and not the shape's.
    assert_true(_folded_join(_ecj(_eq("a", "ra"), _cross(_t(), _r())), "a|ra"))
    assert_true(_folded_join(_ecj(_eq("ra", "a"), _cross(_t(), _r())), "a|ra"))


def test_supported_key_refuses_a_missing_name() raises:
    # Its callers only ask about names they found in the schema, so the final
    # `return False` is reached only by a direct call. Defect: a missing name
    # admitted as a key (the loop's fall-through returning True).
    var s = _schema3("x", "y", "z", ArrowType.UINT32)
    assert_true(_column_is_supported_key("x", s), "INT64 is a key type")
    assert_false(_column_is_supported_key("z", s), "UINT32 is not")
    assert_false(_column_is_supported_key("missing", s), "absent name")


# -----------------------------------------------------------------------------
# Filter over INNER
# -----------------------------------------------------------------------------


def test_inner_join_gains_the_extra_equi_key() raises:
    # Defect: the bridging key not appended (a single-key probe plus a
    # post-join filter), or appended to only one side's list.
    var out = _ecj(_eq("b", "rb"), _inner_a_ra())
    assert_true(_folded_join(out, "a,b|ra,rb"))


def test_inner_join_fold_keeps_a_residual() raises:
    var out = _ecj(_and(_eq("b", "rb"), _gt("c", 1)), _inner_a_ra())
    assert_equal(Int(out.tag), Int(PLAN_FILTER))
    assert_true(_render(out._filter.value()[].predicate).find("ColRef(c)") >= 0)
    assert_true(_folded_join(out._filter.value()[].child[], "a,b|ra,rb"))


def test_inner_join_without_a_new_key_is_left_alone() raises:
    var out = _ecj(_gt("c", 1), _inner_a_ra())
    assert_equal(Int(out.tag), Int(PLAN_FILTER))
    assert_equal(_keys(out._filter.value()[].child[]), "a|ra")


# -----------------------------------------------------------------------------
# Filter over a CSE Project over CROSS
# -----------------------------------------------------------------------------


def _cse_over_cross(cse: Bool) -> LogicalPlan:
    var e = ExprArray()
    e.append(Expr.col_ref("a"))
    e.append(Expr.col_ref("b"))
    e.append(Expr.col_ref("ra"))
    e.append(Expr.col_ref("rb"))
    e.append(Expr.alias(_gt("b", 0), "_cse_0"))
    return LogicalPlan.project(e^, _cross(_t(), _r()), cse)


def test_fold_through_a_cse_project_drops_the_filter() raises:
    # The CSE Project is a barrier to pushdown, so the bridging key sits above
    # it. Defect: no fold through it (a Cartesian product under the Project),
    # or the Project lost when the Filter is dropped.
    var out = _ecj(_eq("a", "ra"), _cse_over_cross(True))
    assert_equal(Int(out.tag), Int(PLAN_PROJECT))
    assert_true(out._project.value()[].is_cse_introduced)
    assert_true(_folded_join(out._project.value()[].child[], "a|ra"))


def test_fold_through_a_cse_project_keeps_the_residual_above_it() raises:
    var out = _ecj(_and(_eq("a", "ra"), Expr.col_ref("_cse_0")), _cse_over_cross(True))
    assert_equal(Int(out.tag), Int(PLAN_FILTER))
    assert_true(_render(out._filter.value()[].predicate).find("_cse_0") >= 0)
    ref p = out._filter.value()[].child[]
    assert_true(_folded_join(p._project.value()[].child[], "a|ra"))


def test_cse_project_without_a_key_and_a_plain_project_are_left_alone() raises:
    # Defect: a fold with no key, or the fold applied through a non-CSE
    # Project (whose names need not pass through).
    var o1 = _ecj(_gt("b", 1), _cse_over_cross(True))
    ref p1 = o1._filter.value()[].child[]
    assert_equal(Int(p1._project.value()[].child[]._join.value()[].join_type), Int(JOIN_CROSS))
    var o2 = _ecj(_eq("a", "ra"), _cse_over_cross(False))
    ref p2 = o2._filter.value()[].child[]
    assert_equal(Int(p2._project.value()[].child[]._join.value()[].join_type), Int(JOIN_CROSS))


# -----------------------------------------------------------------------------
# the walk
# -----------------------------------------------------------------------------


def _site() -> LogicalPlan:
    return LogicalPlan.filter(_eq("a", "ra"), _cross(_t(), _r()))


def test_elimination_walks_every_parent_kind() raises:
    # Defect: a parent arm (or the Filter arm's own child) not recursed.
    var e = ExprArray()
    e.append(Expr.col_ref("a"))
    var p = eliminate_cross_join(LogicalPlan.project(e^, _site()))
    assert_true(_folded_join(p._project.value()[].child[], "a|ra"), "Project arm")
    var gb = ExprArray()
    gb.append(Expr.col_ref("a"))
    var a = eliminate_cross_join(LogicalPlan.aggregate(gb^, AggExprArray(), _site()))
    assert_true(_folded_join(a._aggregate.value()[].child[], "a|ra"), "Aggregate arm")
    var lk = List[String]()
    lk.append("a")
    var rk = List[String]()
    rk.append("a")
    var j = eliminate_cross_join(LogicalPlan.join(_site(), _site(), lk^, rk^, JOIN_INNER))
    assert_true(_folded_join(j._join.value()[].left[], "a|ra"), "Join left")
    assert_true(_folded_join(j._join.value()[].right[], "a|ra"), "Join right")
    var keys = List[String]()
    keys.append("a")
    var desc = List[Bool]()
    desc.append(False)
    var s = eliminate_cross_join(LogicalPlan.sort(keys.copy(), desc.copy(), _site()))
    assert_true(_folded_join(s._sort.value()[].child[], "a|ra"), "Sort arm")
    var l = eliminate_cross_join(LogicalPlan.limit(3, _site()))
    assert_true(_folded_join(l._limit.value()[].child[], "a|ra"), "Limit arm")
    var none: Optional[List[String]] = None
    var d = eliminate_cross_join(LogicalPlan.distinct(none^, _site()))
    assert_true(_folded_join(d._distinct.value()[].child[], "a|ra"), "Distinct arm")
    var t = eliminate_cross_join(LogicalPlan.topn(keys^, desc^, 2, _site()))
    assert_true(_folded_join(t._topn.value()[].child[], "a|ra"), "TopN arm")
    var f = eliminate_cross_join(LogicalPlan.filter(_gt("c", 1), _site()))
    assert_equal(Int(f.tag), Int(PLAN_FILTER), "Filter arm recurses first")
    assert_true(_folded_join(f._filter.value()[].child[], "a|ra"))
    var sc = eliminate_cross_join(LogicalPlan.filter(_gt("c", 1), _t()))
    assert_equal(Int(sc._filter.value()[].child[].tag), Int(PLAN_SCAN))


# -----------------------------------------------------------------------------
# _predicate_refs_in_schema
# -----------------------------------------------------------------------------


def _ab() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, True))
    sb.add_field(Field("b", ArrowType.STRING, True))
    return sb.build()


def _in(e: Expr) -> Bool:
    return _predicate_refs_in_schema(e, _ab())


def test_walker_col_ref_and_binary() raises:
    # Defect: a missing column reported present, or a binary that checks only
    # one side.
    assert_true(_in(Expr.col_ref("a")))
    assert_false(_in(Expr.col_ref("z")))
    assert_true(_in(_eq("a", "b")))
    assert_false(_in(_eq("a", "z")))
    assert_false(_in(_eq("z", "a")))


def test_walker_single_child_arms_recurse() raises:
    # Each arm must look at its child: over a missing column it answers
    # False. Defect: an arm deleted (the fallback answers True, the predicate
    # reads as spanning both join sides and parks above the join).
    var z = Expr.col_ref("z")
    assert_false(_in(Expr.unary(UN_NOT, z.copy())), "unary")
    assert_false(_in(Expr.cast(z.copy(), DType.int64)), "cast")
    assert_false(_in(Expr.alias(z.copy(), "q")), "alias")
    var vals = List[ScalarValue]()
    vals.append(ScalarValue.from_int64(Int64(1)))
    assert_false(_in(Expr.in_list_node(z.copy(), vals^)), "in list")
    assert_false(_in(Expr.string_op(STR_LIKE, z.copy(), "%x%")), "string op")
    assert_false(_in(Expr.regexp_like(z.copy(), "^x")), "regexp")
    assert_false(_in(Expr.string_fn(STRFN_UPPER, z.copy())), "string fn")
    assert_false(
        _in(Expr.udf_call(String("f"), Optional(Int(1)), ArrowType.INT64, ArrowType.INT64, z.copy())),
        "udf call",
    )
    assert_true(_in(Expr.string_op(STR_LIKE, Expr.col_ref("b"), "%x%")), "present child")


def test_walker_string_fn_n_folds_every_argument() raises:
    # Defect: only the first argument checked, or the empty node refused.
    var ok = List[Expr]()
    ok.append(Expr.col_ref("a"))
    ok.append(Expr.col_ref("b"))
    assert_true(_in(Expr.string_fn_n(STRFNN_CONCAT, ok^)))
    var bad = List[Expr]()
    bad.append(Expr.col_ref("a"))
    bad.append(Expr.col_ref("z"))
    assert_false(_in(Expr.string_fn_n(STRFNN_CONCAT, bad^)))
    assert_true(_in(Expr.string_fn_n(STRFNN_CONCAT, List[Expr]())))


def test_walker_fallback_answers_true() raises:
    # Literals, positional refs and tags the walker does not list answer True
    # (correctness-safe: it only prevents a push). Defect: the fallback turned
    # into False, which would push a predicate whose columns were never
    # checked.
    assert_true(_in(_lit(1)))
    assert_true(_in(Expr.col_idx(0)))
    assert_true(_in(Expr.sqrt(Expr.col_ref("z"))))


# -----------------------------------------------------------------------------
# push_join_residual_to_side: the branches the welded tests do not reach
# -----------------------------------------------------------------------------


def _residual_join(var residual: Expr, jt: UInt8, keyed: Bool = True) -> LogicalPlan:
    var lk = List[String]()
    var rk = List[String]()
    if keyed:
        lk.append("a")
        rk.append("ra")
    var res = Optional[OwnedPointer[Expr]](OwnedPointer(residual^))
    return LogicalPlan.join(_t(), _r(), lk^, rk^, jt, JOIN_ALGO_AUTO, res^)


def _right_pushed(p: LogicalPlan) -> Bool:
    return (
        p.tag == PLAN_JOIN
        and p._join.value()[].right[].tag == PLAN_FILTER
        and not p._join.value()[].has_residual()
    )


def test_residual_split_keeps_both_sides_conjuncts_on_the_residual() raises:
    # (rb > 0 AND ra > 9) AND b < rb on an INNER join: the two right-only
    # conjuncts become one right Filter; `b < rb` stays the residual. Defect:
    # the kept conjunct dropped, or only the first right-only one pushed.
    var both = Expr.binary(BIN_LT, Expr.col_ref("b"), Expr.col_ref("rb"))
    var res = _and(_and(_gt("rb", 0), _gt("ra", 9)), both^)
    var out = push_join_residual_to_side(_residual_join(res^, JOIN_INNER))
    ref jd = out._join.value()[]
    assert_true(jd.has_residual())
    var kept = _render(jd.residual.value()[])
    assert_true(kept.find("ColRef(b)") >= 0, kept)
    assert_equal(Int(jd.right[].tag), Int(PLAN_FILTER))
    var pushed = _render(jd.right[]._filter.value()[].predicate)
    assert_true(pushed.find("ColRef(ra)") >= 0 and pushed.find("ColRef(rb)") >= 0, pushed)
    assert_equal(Int(jd.left[].tag), Int(PLAN_SCAN))
    assert_equal(_keys(out), "a|ra")


def test_residual_left_unchanged_when_nothing_is_single_sided() raises:
    # Defect: a both-sides residual pushed, or the join rebuilt for nothing.
    var both = Expr.binary(BIN_LT, Expr.col_ref("b"), Expr.col_ref("rb"))
    var out = push_join_residual_to_side(_residual_join(both^, JOIN_INNER))
    assert_true(out._join.value()[].has_residual())
    assert_equal(Int(out._join.value()[].right[].tag), Int(PLAN_SCAN))


def test_residual_left_unchanged_for_right_full_and_unkeyed_joins() raises:
    # RIGHT / FULL have other null-supplying sides; an unkeyed residual is a
    # pure nested-loop shape. Defect: any of the three guards removed.
    var o1 = push_join_residual_to_side(_residual_join(_gt("rb", 0), JOIN_RIGHT))
    assert_true(o1._join.value()[].has_residual(), "RIGHT")
    var o2 = push_join_residual_to_side(_residual_join(_gt("rb", 0), JOIN_FULL))
    assert_true(o2._join.value()[].has_residual(), "FULL")
    var o3 = push_join_residual_to_side(_residual_join(_gt("rb", 0), JOIN_INNER, False))
    assert_true(o3._join.value()[].has_residual(), "no equi-key")
    var lk = List[String]()
    lk.append("a")
    var rk = List[String]()
    rk.append("ra")
    var plain = LogicalPlan.join(_t(), _r(), lk^, rk^, JOIN_LEFT)
    var o4 = push_join_residual_to_side(plain^)
    assert_false(o4._join.value()[].has_residual(), "no residual at all")
    assert_equal(Int(o4._join.value()[].right[].tag), Int(PLAN_SCAN))


def _rsite() -> LogicalPlan:
    return _residual_join(_gt("rb", 0), JOIN_LEFT)


def test_residual_rule_walks_every_parent_kind() raises:
    # Defect: a parent arm that does not recurse to the join below it.
    var f = push_join_residual_to_side(LogicalPlan.filter(_gt("a", 1), _rsite()))
    assert_true(_right_pushed(f._filter.value()[].child[]), "Filter arm")
    var e = ExprArray()
    e.append(Expr.col_ref("a"))
    var p = push_join_residual_to_side(LogicalPlan.project(e^, _rsite()))
    assert_true(_right_pushed(p._project.value()[].child[]), "Project arm")
    var gb = ExprArray()
    gb.append(Expr.col_ref("a"))
    var aggs = AggExprArray()
    var none_e: Optional[Expr] = None
    aggs.append(AggExpr(AGG_COUNT, none_e^, Optional(String("n"))))
    var a = push_join_residual_to_side(LogicalPlan.aggregate(gb^, aggs^, _rsite()))
    assert_true(_right_pushed(a._aggregate.value()[].child[]), "Aggregate arm")
    var keys = List[String]()
    keys.append("a")
    var desc = List[Bool]()
    desc.append(False)
    var s = push_join_residual_to_side(LogicalPlan.sort(keys.copy(), desc.copy(), _rsite()))
    assert_true(_right_pushed(s._sort.value()[].child[]), "Sort arm")
    var l = push_join_residual_to_side(LogicalPlan.limit(3, _rsite()))
    assert_true(_right_pushed(l._limit.value()[].child[]), "Limit arm")
    var none: Optional[List[String]] = None
    var d = push_join_residual_to_side(LogicalPlan.distinct(none^, _rsite()))
    assert_true(_right_pushed(d._distinct.value()[].child[]), "Distinct arm")
    var t = push_join_residual_to_side(LogicalPlan.topn(keys^, desc^, 2, _rsite()))
    assert_true(_right_pushed(t._topn.value()[].child[]), "TopN arm")
    var lk = List[String]()
    lk.append("a")
    var rk = List[String]()
    rk.append("a")
    var j = push_join_residual_to_side(LogicalPlan.join(_rsite(), _rsite(), lk^, rk^, JOIN_INNER))
    assert_true(_right_pushed(j._join.value()[].left[]), "Join left")
    assert_true(_right_pushed(j._join.value()[].right[]), "Join right")
    var sc = push_join_residual_to_side(_t())
    assert_equal(Int(sc.tag), Int(PLAN_SCAN))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
