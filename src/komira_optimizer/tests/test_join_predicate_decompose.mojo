"""Direct tests of `komira_optimizer.join_predicate_decompose`.

The pass rewrites a join `residual` written with side-qualified col-refs
(`Expr.left(..)` / `Expr.right(..)`): bare `left = right` equalities move into
`left_on` / `right_on`; every other conjunct stays in the residual with its
refs rewritten to plain col-refs over the joined schema (a right-side name that
collides with a left column becomes `<name>_right`). Each test names the defect
it catches.
"""

from std.memory import OwnedPointer
from std.testing import assert_equal, assert_true, assert_false

from komira_arrow.schema import SchemaBuilder, Field, Schema
from komira_arrow.arrow_types import ArrowType
from komira_plan_expr.expr import (
    Expr,
    WhenCaseData,
    EXPR_COL_REF,
    EXPR_COL_IDX,
    EXPR_LITERAL,
    EXPR_BINARY_OP,
    EXPR_UNARY_OP,
    EXPR_CAST,
    EXPR_ALIAS,
    EXPR_STRING_OP,
    EXPR_WHEN,
    EXPR_IN_LIST,
    EXPR_AGG_FN,
    BIN_EQ,
    BIN_NE,
    BIN_LT,
    BIN_GT,
    BIN_AND,
    UN_NOT,
    STR_CONTAINS,
    COL_SIDE_NONE,
)
from komira_plan_expr.agg_expr import AGG_SUM
from komira_plan_expr.partition_expr import PartitionExpr
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    PLAN_SCAN,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_AGGREGATE,
    PLAN_JOIN,
    PLAN_SORT,
    PLAN_LIMIT,
    PLAN_DISTINCT,
    PLAN_TOPN,
    PLAN_PARTITION_BY,
    PLAN_PARTITION_TOPN,
    PLAN_UNION,
    SOURCE_PARQUET,
    JOIN_INNER,
    JOIN_LEFT,
    JOIN_ALGO_AUTO,
    JOIN_ALGO_HASH,
)

from komira_optimizer.join_predicate_decompose import (
    join_predicate_decompose,
    join_predicate_decompose_inplace,
    _maybe_decompose_join,
    _rewrite_strip_sides,
    _residual_needs_decompose,
)


# =============================================================================
# Fixtures
# =============================================================================


def _scan2(path: String, a: String, b: String) -> LogicalPlan:
    var sb = SchemaBuilder()
    sb.add_field(Field(a, ArrowType.INT64, False))
    sb.add_field(Field(b, ArrowType.INT64, False))
    return LogicalPlan.scan(path, SOURCE_PARQUET, sb.build())


def _names(a: String, b: String) -> List[String]:
    var out = List[String]()
    out.append(a)
    if b.byte_length() > 0:
        out.append(b)
    return out^


def _raw_join(residual: Expr) -> LogicalPlan:
    """L(k, v) JOIN R(k, w), no keys, a raw side-qualified residual."""
    return LogicalPlan.join(
        _scan2("l.parquet", "k", "v"), _scan2("r.parquet", "k", "w"),
        List[String](), List[String](), JOIN_INNER, JOIN_ALGO_AUTO,
        Optional(OwnedPointer(residual.copy())),
    )


def _key_eq() -> Expr:
    return Expr.binary(BIN_EQ, Expr.left("k"), Expr.right("k"))


def _assert_lifted_k(plan: LogicalPlan) raises:
    """`plan` is a join whose raw `left.k = right.k` residual was lifted."""
    assert_equal(plan.tag, PLAN_JOIN)
    ref j = plan._join.value()[]
    assert_equal(len(j.left_on), 1)
    assert_equal(j.left_on[0], String("k"))
    assert_equal(j.right_on[0], String("k"))
    assert_false(j.has_residual())


def _collect_refs(e: Expr, mut names: List[String], mut sides: List[UInt8]):
    """Every col-ref (name, side) under `e`, in walk order."""
    if e.tag == EXPR_COL_REF:
        names.append(e.col_ref_name())
        sides.append(e.col_ref_side())
    elif e.tag == EXPR_BINARY_OP:
        _collect_refs(e.binary_left_ref(), names, sides)
        _collect_refs(e.binary_right_ref(), names, sides)
    elif e.tag == EXPR_UNARY_OP:
        _collect_refs(e.unary_child_ref(), names, sides)
    elif e.tag == EXPR_CAST:
        _collect_refs(e.cast_child_ref(), names, sides)
    elif e.tag == EXPR_ALIAS:
        _collect_refs(e.alias_child_ref(), names, sides)
    elif e.tag == EXPR_STRING_OP:
        _collect_refs(e.string_op_child_ref(), names, sides)
    elif e.tag == EXPR_WHEN:
        ref wd = e._when.value()
        for i in range(len(wd.cases)):
            _collect_refs(wd.cases[i].condition[], names, sides)
            _collect_refs(wd.cases[i].result[], names, sides)
        _collect_refs(wd.default[], names, sides)
    elif e.tag == EXPR_IN_LIST:
        _collect_refs(e._in_list.value().child[], names, sides)
    elif e.tag == EXPR_AGG_FN:
        _collect_refs(e.agg_fn_child_ref(), names, sides)


# =============================================================================
# Lifting equi-keys
# =============================================================================


def test_lifts_both_orientations_and_keeps_existing_keys() raises:
    """`left.k = right.k AND right.w = left.v` over a join that already has
    key (k, k): both conjuncts lift, the swapped one with its operands put
    back in (left, right) order, after the existing key; the residual becomes
    None; join type and algorithm hint survive the rebuild.

    Catches: the swapped-form branch dropped or appending in operand order
    (right_on gets `k` where `w` belongs); the rebuild starting from empty key
    lists (the existing key is lost); a residual kept when every conjunct
    lifted; join_type / algo_hint reset by the rebuild."""
    var res = Expr.binary(
        BIN_AND,
        Expr.binary(BIN_EQ, Expr.left("k"), Expr.right("k")),
        Expr.binary(BIN_EQ, Expr.right("w"), Expr.left("v")),
    )
    var plan = LogicalPlan.join(
        _scan2("l.parquet", "k", "v"), _scan2("r.parquet", "k", "w"),
        _names("k", ""), _names("k", ""), JOIN_LEFT, JOIN_ALGO_HASH,
        Optional(OwnedPointer(res^)),
    )
    var out = join_predicate_decompose(plan^)
    assert_equal(out.tag, PLAN_JOIN)
    ref j = out._join.value()[]
    assert_equal(len(j.left_on), 3)
    assert_equal(j.left_on[0], String("k"))
    assert_equal(j.left_on[1], String("k"))
    assert_equal(j.left_on[2], String("v"))
    assert_equal(j.right_on[0], String("k"))
    assert_equal(j.right_on[1], String("k"))
    assert_equal(j.right_on[2], String("w"))
    assert_false(j.has_residual())
    assert_equal(j.join_type, JOIN_LEFT)
    assert_equal(j.algo_hint, JOIN_ALGO_HASH)


def test_non_liftable_conjuncts_stay_with_plain_refs() raises:
    """Over L(k, v) JOIN R(k, w), the residual
    `left.k = right.k AND left.v < right.k AND left.v = 5 AND
     left.v = left.k AND right.w <> left.v`
    lifts only the first conjunct. The other four stay, AND-ed in order, with
    plain refs: `right.k` collides with the left `k` and becomes `k_right`;
    `right.w` does not collide and stays `w`.

    Catches: a non-EQ, a literal operand or a same-side EQ lifted as a key;
    the `_right` collision rename dropped or applied to a non-colliding name;
    side qualifiers left on the surviving refs (which a re-run would then
    try to decompose again); surviving conjuncts dropped or reordered."""
    var res = Expr.binary(
        BIN_AND,
        Expr.binary(
            BIN_AND,
            Expr.binary(
                BIN_AND,
                Expr.binary(
                    BIN_AND,
                    _key_eq(),
                    Expr.binary(BIN_LT, Expr.left("v"), Expr.right("k")),
                ),
                Expr.binary(
                    BIN_EQ, Expr.left("v"), Expr.literal(ScalarValue.from_int(5))
                ),
            ),
            Expr.binary(BIN_EQ, Expr.left("v"), Expr.left("k")),
        ),
        Expr.binary(BIN_NE, Expr.right("w"), Expr.left("v")),
    )
    var out = join_predicate_decompose(_raw_join(res))
    ref j = out._join.value()[]
    assert_equal(len(j.left_on), 1)
    assert_equal(j.left_on[0], String("k"))
    assert_equal(j.right_on[0], String("k"))
    assert_true(j.has_residual())
    var names = List[String]()
    var sides = List[UInt8]()
    _collect_refs(j.residual.value()[], names, sides)
    # v < k_right, v = 5, v = k, w <> v: seven refs in walk order.
    assert_equal(len(names), 7)
    assert_equal(names[0], String("v"))
    assert_equal(names[1], String("k_right"))
    assert_equal(names[2], String("v"))
    assert_equal(names[3], String("v"))
    assert_equal(names[4], String("k"))
    assert_equal(names[5], String("w"))
    assert_equal(names[6], String("v"))
    for i in range(len(sides)):
        assert_equal(sides[i], COL_SIDE_NONE)
    assert_false(_residual_needs_decompose(j.residual.value()[]))

    # Idempotent: the rewritten residual is plain, so a second run keeps it.
    var again = join_predicate_decompose(out^)
    ref j2 = again._join.value()[]
    assert_equal(len(j2.left_on), 1)
    assert_true(j2.has_residual())


def test_join_without_raw_residual_is_left_alone() raises:
    """A join with no residual, and a join whose residual has only plain
    refs, come back with their keys and residual unchanged; a non-join node
    handed to `_maybe_decompose_join` is not touched.

    Catches: the `has_residual` guard removed (the residual-less join reads
    an empty Optional); the PLAN_JOIN guard removed (the scan is read as a
    join). Reaches the early return of the `_residual_needs_decompose` guard;
    removing that guard is an equivalent mutant here (a plain residual is
    re-split into the same plain residual), so this case proves the branch
    runs, not that the guard is needed."""
    var plain = LogicalPlan.join(
        _scan2("l.parquet", "k", "v"), _scan2("r.parquet", "k", "w"),
        _names("k", ""), _names("k", ""), JOIN_INNER,
    )
    var out = join_predicate_decompose(plain^)
    assert_equal(len(out._join.value()[].left_on), 1)
    assert_false(out._join.value()[].has_residual())

    var plain_res = Expr.binary(BIN_EQ, Expr.col_ref("v"), Expr.col_ref("w"))
    var out2 = join_predicate_decompose(_raw_join(plain_res))
    ref j = out2._join.value()[]
    assert_equal(len(j.left_on), 0)
    assert_true(j.has_residual())
    assert_equal(j.residual.value()[].tag, EXPR_BINARY_OP)

    var scan = _scan2("l.parquet", "k", "v")
    _maybe_decompose_join(scan)
    assert_equal(scan.tag, PLAN_SCAN)


def test_a_non_comparison_conjunct_stays_in_the_residual() raises:
    """A residual that is only `NOT(left.v)` lifts nothing: the join keeps
    no keys and the residual becomes plain `NOT(v)`.

    Catches: the non-binary guard of the equi-key check removed (a unary
    conjunct would be read as a binary one)."""
    var out = join_predicate_decompose(_raw_join(Expr.unary(UN_NOT, Expr.left("v"))))
    ref j = out._join.value()[]
    assert_equal(len(j.left_on), 0)
    ref r = j.residual.value()[]
    assert_equal(r.tag, EXPR_UNARY_OP)
    _assert_plain(r.unary_child_ref(), "v")


# =============================================================================
# The plan walk
# =============================================================================


def _wrap(kind: Int, var child: LogicalPlan) raises -> LogicalPlan:
    """`child` under one node of the kind numbered `kind`."""
    if kind == 0:
        return LogicalPlan.filter(
            Expr.binary(BIN_GT, Expr.col_ref("v"), Expr.literal(ScalarValue.from_int(0))),
            child^,
        )
    if kind == 1:
        var exprs = ExprArray()
        exprs.append(Expr.col_ref("v"))
        return LogicalPlan.project(exprs^, child^)
    if kind == 2:
        var gb = ExprArray()
        gb.append(Expr.col_ref("v"))
        return LogicalPlan.aggregate(gb^, AggExprArray(), child^)
    if kind == 3:
        var desc = List[Bool]()
        desc.append(False)
        return LogicalPlan.sort(_names("v", ""), desc^, child^)
    if kind == 4:
        return LogicalPlan.limit(3, child^)
    if kind == 5:
        return LogicalPlan.distinct(None, child^)
    if kind == 6:
        var desc = List[Bool]()
        desc.append(False)
        return LogicalPlan.topn(_names("v", ""), desc^, 3, child^)
    if kind == 7:
        var desc = List[Bool]()
        desc.append(False)
        return LogicalPlan.partition_by(
            _names("v", ""), _names("v", ""), desc^, List[PartitionExpr](), child^
        )
    if kind == 8:
        var desc = List[Bool]()
        desc.append(False)
        return LogicalPlan.partition_topn(
            _names("v", ""), _names("v", ""), desc^, 1, child^
        )
    if kind == 9:
        var schema = child.output_schema.copy()
        var kids = List[OwnedPointer[LogicalPlan]]()
        kids.append(OwnedPointer(_scan2("u.parquet", "k", "v")))
        kids.append(OwnedPointer(child^))
        return LogicalPlan.union(kids^, schema^)
    raise Error("test: unknown wrapper kind " + String(kind))


def _child_of(plan: LogicalPlan, kind: Int) raises -> LogicalPlan:
    """The wrapped child `_wrap(kind, ..)` put under `plan`."""
    if kind == 0:
        return plan._filter.value()[].child[].copy()
    if kind == 1:
        return plan._project.value()[].child[].copy()
    if kind == 2:
        return plan._aggregate.value()[].child[].copy()
    if kind == 3:
        return plan._sort.value()[].child[].copy()
    if kind == 4:
        return plan._limit.value()[].child[].copy()
    if kind == 5:
        return plan._distinct.value()[].child[].copy()
    if kind == 6:
        return plan._topn.value()[].child[].copy()
    if kind == 7:
        return plan._partition_by.value()[].child[].copy()
    if kind == 8:
        return plan._partition_topn.value()[].child[].copy()
    return plan._union.value()[].children[1][].copy()


def test_walk_reaches_a_join_under_every_node_kind() raises:
    """A raw-residual join under each of Filter, Project, Aggregate, Sort,
    Limit, Distinct, TopN, PartitionBy, PartitionTopN and Union (second
    branch) is decomposed, and the wrapper keeps its kind.

    Catches: any one recursion arm removed or recursing into the wrong
    child (that join keeps its raw residual and an empty `left_on`); the
    Union loop stopping after the first branch."""
    var tags = List[UInt8]()
    tags.append(PLAN_FILTER)
    tags.append(PLAN_PROJECT)
    tags.append(PLAN_AGGREGATE)
    tags.append(PLAN_SORT)
    tags.append(PLAN_LIMIT)
    tags.append(PLAN_DISTINCT)
    tags.append(PLAN_TOPN)
    tags.append(PLAN_PARTITION_BY)
    tags.append(PLAN_PARTITION_TOPN)
    tags.append(PLAN_UNION)
    for kind in range(10):
        var plan = _wrap(kind, _raw_join(_key_eq()))
        join_predicate_decompose_inplace(plan)
        assert_equal(plan.tag, tags[kind])
        _assert_lifted_k(_child_of(plan, kind))


def test_walk_reaches_joins_on_both_sides_of_a_join() raises:
    """A join whose left and right inputs are each raw-residual joins:
    both inputs and the outer join (its own raw residual) are decomposed.

    Catches: the join arm recursing into only one input, or decomposing the
    outer join without recursing first."""
    var outer_res = Expr.binary(BIN_EQ, Expr.left("v"), Expr.right("w"))
    var plan = LogicalPlan.join(
        _raw_join(_key_eq()), _raw_join(_key_eq()),
        List[String](), List[String](), JOIN_INNER, JOIN_ALGO_AUTO,
        Optional(OwnedPointer(outer_res^)),
    )
    var out = join_predicate_decompose(plan^)
    ref j = out._join.value()[]
    assert_equal(j.left_on[0], String("v"))
    assert_equal(j.right_on[0], String("w"))
    _assert_lifted_k(j.left[])
    _assert_lifted_k(j.right[])


# =============================================================================
# The residual rewrite, per expression kind
# =============================================================================


def _left_cols() -> List[String]:
    return _names("k", "v")


def _assert_plain(e: Expr, want: String) raises:
    assert_equal(e.tag, EXPR_COL_REF)
    assert_equal(e.col_ref_name(), want)
    assert_equal(e.col_ref_side(), COL_SIDE_NONE)


def test_strip_sides_rewrites_inside_every_expression_kind() raises:
    """`_rewrite_strip_sides` rewrites `right.k` to plain `k_right` (left
    columns k, v) inside a unary, a cast, an alias, a string op, a CASE
    (condition, result and default), an IN list and an aggregate, and keeps
    each wrapper's own payload; `left.v` becomes plain `v`; a plain ref and a
    literal copy through unchanged.

    Catches: any one arm removed (its right ref keeps its side, or the
    wrapper is copied unrewritten); a wrapper rebuilt with a wrong op, cast
    target, alias name, pattern or IN values."""
    var cols = _left_cols()
    var rk = Expr.right("k")

    var un = _rewrite_strip_sides(Expr.unary(UN_NOT, rk.copy()), cols)
    assert_equal(un.tag, EXPR_UNARY_OP)
    assert_equal(un.unary_op(), UN_NOT)
    _assert_plain(un.unary_child_ref(), "k_right")

    var ca = _rewrite_strip_sides(Expr.cast(rk.copy(), DType.float64), cols)
    assert_equal(ca.tag, EXPR_CAST)
    assert_true(ca.cast_target() == DType.float64)
    _assert_plain(ca.cast_child_ref(), "k_right")

    var al = _rewrite_strip_sides(Expr.alias(rk.copy(), "x"), cols)
    assert_equal(al.tag, EXPR_ALIAS)
    assert_equal(al.alias_name(), String("x"))
    _assert_plain(al.alias_child_ref(), "k_right")

    var so = _rewrite_strip_sides(Expr.string_op(STR_CONTAINS, rk.copy(), "ab"), cols)
    assert_equal(so.tag, EXPR_STRING_OP)
    assert_equal(so.string_op_type(), STR_CONTAINS)
    assert_equal(so.string_op_pattern(), String("ab"))
    _assert_plain(so.string_op_child_ref(), "k_right")

    var cases = List[WhenCaseData]()
    cases.append(WhenCaseData(Expr.left("v"), rk.copy()))
    var wh = _rewrite_strip_sides(Expr.when(cases^, rk.copy()), cols)
    assert_equal(wh.tag, EXPR_WHEN)
    ref wd = wh._when.value()
    assert_equal(len(wd.cases), 1)
    _assert_plain(wd.cases[0].condition[], "v")
    _assert_plain(wd.cases[0].result[], "k_right")
    _assert_plain(wd.default[], "k_right")

    var vals = List[ScalarValue]()
    vals.append(ScalarValue.from_int(1))
    vals.append(ScalarValue.from_int(2))
    var il = _rewrite_strip_sides(Expr.in_list_node(rk.copy(), vals^), cols)
    assert_equal(il.tag, EXPR_IN_LIST)
    assert_equal(len(il._in_list.value().values), 2)
    _assert_plain(il._in_list.value().child[], "k_right")

    var ag = _rewrite_strip_sides(Expr.agg_fn(AGG_SUM, rk.copy()), cols)
    assert_equal(ag.tag, EXPR_AGG_FN)
    assert_equal(ag.agg_fn_op(), AGG_SUM)
    _assert_plain(ag.agg_fn_child_ref(), "k_right")

    _assert_plain(_rewrite_strip_sides(Expr.col_ref("k"), cols), "k")
    _assert_plain(_rewrite_strip_sides(Expr.right("w"), cols), "w")
    var lit = _rewrite_strip_sides(Expr.literal(ScalarValue.from_int(7)), cols)
    assert_equal(lit.tag, EXPR_LITERAL)
    assert_equal(lit.literal_value().int_val, Int64(7))


def test_needs_decompose_finds_a_side_ref_in_every_expression_kind() raises:
    """`_residual_needs_decompose` is True for a side-qualified ref under a
    binary (either operand), unary, cast, alias, string op, CASE (condition,
    result or default), IN list and aggregate, and False for the same shapes
    over plain refs, for a literal and for a col-idx.

    Catches: any arm removed (its residual is never decomposed, so it
    keeps side-qualified refs); a CASE that checks only its first
    part; the binary arm checking only one operand."""
    var r = Expr.right("k")
    var p = Expr.col_ref("k")
    assert_true(_residual_needs_decompose(r))
    assert_false(_residual_needs_decompose(p))
    assert_true(_residual_needs_decompose(Expr.binary(BIN_LT, p.copy(), r.copy())))
    assert_true(_residual_needs_decompose(Expr.binary(BIN_LT, r.copy(), p.copy())))
    assert_false(_residual_needs_decompose(Expr.binary(BIN_LT, p.copy(), p.copy())))
    assert_true(_residual_needs_decompose(Expr.unary(UN_NOT, r.copy())))
    assert_false(_residual_needs_decompose(Expr.unary(UN_NOT, p.copy())))
    assert_true(_residual_needs_decompose(Expr.cast(r.copy(), DType.float64)))
    assert_false(_residual_needs_decompose(Expr.cast(p.copy(), DType.float64)))
    assert_true(_residual_needs_decompose(Expr.alias(r.copy(), "x")))
    assert_false(_residual_needs_decompose(Expr.alias(p.copy(), "x")))
    assert_true(_residual_needs_decompose(Expr.string_op(STR_CONTAINS, r.copy(), "a")))
    assert_false(_residual_needs_decompose(Expr.string_op(STR_CONTAINS, p.copy(), "a")))
    assert_true(_residual_needs_decompose(Expr.agg_fn(AGG_SUM, r.copy())))
    assert_false(_residual_needs_decompose(Expr.agg_fn(AGG_SUM, p.copy())))
    var vals = List[ScalarValue]()
    vals.append(ScalarValue.from_int(1))
    assert_true(_residual_needs_decompose(Expr.in_list_node(r.copy(), vals.copy())))
    assert_false(_residual_needs_decompose(Expr.in_list_node(p.copy(), vals.copy())))

    # CASE: a side ref in the condition, in the result, in the default, none.
    var c1 = List[WhenCaseData]()
    c1.append(WhenCaseData(r.copy(), p.copy()))
    assert_true(_residual_needs_decompose(Expr.when(c1^, p.copy())))
    var c2 = List[WhenCaseData]()
    c2.append(WhenCaseData(p.copy(), r.copy()))
    assert_true(_residual_needs_decompose(Expr.when(c2^, p.copy())))
    var c3 = List[WhenCaseData]()
    c3.append(WhenCaseData(p.copy(), p.copy()))
    assert_true(_residual_needs_decompose(Expr.when(c3^, r.copy())))
    var c4 = List[WhenCaseData]()
    c4.append(WhenCaseData(p.copy(), p.copy()))
    assert_false(_residual_needs_decompose(Expr.when(c4^, p.copy())))

    assert_false(_residual_needs_decompose(Expr.literal(ScalarValue.from_int(1))))
    var ci = Expr.col_idx(0)
    assert_equal(ci.tag, EXPR_COL_IDX)
    assert_false(_residual_needs_decompose(ci))


def test_case_walks_reach_every_when_case() raises:
    """Both walkers visit every WHEN case, not only the first: with case 0
    holding `left.v` and a literal result and case 1 holding `right.k` as
    condition and result, `_rewrite_strip_sides` keeps both cases, strips
    case 0's `left.v` to plain `v` and keeps its literal result, and
    rewrites case 1's condition and result to plain `k_right`; and
    `_residual_needs_decompose` is True when the only side ref is in case
    1's condition, or only in case 1's result, and False when no case has one.

    Catches: either WHEN loop bounded to the first case (case 1 dropped from
    the rebuilt CASE, or copied with `right.k` raw so the residual keeps a
    side-qualified ref; or a raw `predicate=` residual whose only side ref
    is in a later case is never decomposed)."""
    var cols = _left_cols()
    var r = Expr.right("k")
    var p = Expr.col_ref("k")

    var cases = List[WhenCaseData]()
    cases.append(WhenCaseData(Expr.left("v"), Expr.literal(ScalarValue.from_int(1))))
    cases.append(WhenCaseData(r.copy(), r.copy()))
    var wh = _rewrite_strip_sides(Expr.when(cases^, p.copy()), cols)
    assert_equal(wh.tag, EXPR_WHEN)
    ref wd = wh._when.value()
    assert_equal(len(wd.cases), 2)
    _assert_plain(wd.cases[0].condition[], "v")
    assert_equal(wd.cases[0].result[].tag, EXPR_LITERAL)
    assert_equal(wd.cases[0].result[].literal_value().int_val, Int64(1))
    _assert_plain(wd.cases[1].condition[], "k_right")
    _assert_plain(wd.cases[1].result[], "k_right")
    _assert_plain(wd.default[], "k")

    var c1 = List[WhenCaseData]()
    c1.append(WhenCaseData(p.copy(), p.copy()))
    c1.append(WhenCaseData(r.copy(), p.copy()))
    assert_true(_residual_needs_decompose(Expr.when(c1^, p.copy())))
    var c2 = List[WhenCaseData]()
    c2.append(WhenCaseData(p.copy(), p.copy()))
    c2.append(WhenCaseData(p.copy(), r.copy()))
    assert_true(_residual_needs_decompose(Expr.when(c2^, p.copy())))
    var c3 = List[WhenCaseData]()
    c3.append(WhenCaseData(p.copy(), p.copy()))
    c3.append(WhenCaseData(p.copy(), p.copy()))
    assert_false(_residual_needs_decompose(Expr.when(c3^, p.copy())))


def main() raises:
    test_lifts_both_orientations_and_keeps_existing_keys()
    test_non_liftable_conjuncts_stay_with_plain_refs()
    test_join_without_raw_residual_is_left_alone()
    test_a_non_comparison_conjunct_stays_in_the_residual()
    test_walk_reaches_a_join_under_every_node_kind()
    test_walk_reaches_joins_on_both_sides_of_a_join()
    test_strip_sides_rewrites_inside_every_expression_kind()
    test_needs_decompose_finds_a_side_ref_in_every_expression_kind()
    test_case_walks_reach_every_when_case()
    print("All join_predicate_decompose tests passed.")
