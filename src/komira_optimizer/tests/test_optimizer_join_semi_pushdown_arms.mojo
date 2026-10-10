# =============================================================================
# Rule 11b, `push_semi_reducers_down`: the OptimizerConfig switch, both
# rewrites (R-A through a Filter, R-B into an INNER join) and every guard G1-G5.
# =============================================================================
#
# Fixture: the q20 shape `SEMI(INNER(A, B), C)` with the semi keyed on a column
# of A, C (10 rows) smaller than the sibling B (1000 rows) and every leaf a
# Parquet scan. The rule moves the semi below the join:
# `INNER(SEMI(A, C), B)`. Moving it wrongly is a silent wrong answer (a
# straddling predicate, a lost residual column, a changed output schema) or a
# side G5 does not admit; every guard is a decline. Each test names
# the defect it catches.
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.expr import Expr, BIN_ADD, BIN_LT
from komira_plan_expr.udf_data import UdfData, UDF_KIND_MAP, UDF_KIND_FILTER
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
    SOURCE_CSV,
    JOIN_INNER,
    JOIN_LEFT,
    JOIN_SEMI,
    JOIN_ANTI,
    JOIN_ALGO_AUTO,
)
from komira_optimizer.optimizer_config import OptimizerConfig
from komira_optimizer.optimizer_join import (
    push_semi_reducers_down,
    _try_push_one_semi_reducer,
    _push_semi_into,
    _semi_target_side,
    _schema_fields_identical,
    _pure_colref_project,
    _filter_chain_bottoms_in_parquet_scan,
    _side_is_parquet_leaf_shape,
)


# -----------------------------------------------------------------------------
# Fixtures
# -----------------------------------------------------------------------------


def _schema(names: List[String]) -> Schema:
    var sb = SchemaBuilder()
    for i in range(len(names)):
        sb.add_field(Field(names[i], ArrowType.INT64, True))
    return sb.build()


def _scan(path: String, names: List[String], rows: Int, src: UInt8 = SOURCE_PARQUET) -> LogicalPlan:
    return LogicalPlan.scan(path, src, _schema(names), None, None, Optional[Int](rows))


def _a() -> LogicalPlan:
    var n: List[String] = ["ak", "av"]
    return _scan("a", n, 1000)


def _b() -> LogicalPlan:
    var n: List[String] = ["bk", "bv"]
    return _scan("b", n, 1000)


def _c() -> LogicalPlan:
    var n: List[String] = ["ck", "cv"]
    return _scan("c", n, 10)


def _join(
    var l: LogicalPlan, var r: LogicalPlan, lk: String, rk: String, jt: UInt8
) -> LogicalPlan:
    var lo: List[String] = [lk]
    var ro: List[String] = [rk]
    return LogicalPlan.join(l^, r^, lo^, ro^, jt)


def _carrier() -> LogicalPlan:
    return _join(_a(), _b(), "ak", "bk", JOIN_INNER)


def _semi_over(var left: LogicalPlan, key: String, jt: UInt8 = JOIN_SEMI) -> LogicalPlan:
    return _join(left^, _c(), key, "ck", jt)


def _q20() -> LogicalPlan:
    """SEMI(INNER(A, B), C) on ak = ck."""
    return _semi_over(_carrier(), "ak")


def _semi_with_residual(var right: LogicalPlan, col: String) -> LogicalPlan:
    var lo: List[String] = ["ak"]
    var ro: List[String] = ["ck"]
    var res = Optional[OwnedPointer[Expr]](
        OwnedPointer(Expr.binary(BIN_LT, Expr.col_ref(col), Expr.col_ref("ck")))
    )
    return LogicalPlan.join(_carrier(), right^, lo^, ro^, JOIN_SEMI, JOIN_ALGO_AUTO, res^)


def _render(p: LogicalPlan) -> String:
    var s = String("")
    p.write_to(s)
    return s


def _on() -> OptimizerConfig:
    return OptimizerConfig()


def _udf(kind: UInt8) -> UdfData:
    var ic = List[Tuple[String, UInt8]]()
    ic.append(("ak", UInt8(2)))
    var oc = List[Tuple[String, UInt8]]()
    oc.append(("ak", UInt8(2)))
    return UdfData(
        kind=kind,
        name=String("f"),
        input_columns=ic^,
        output_columns=oc^,
        operator_factory_id=UInt32(1),
        call_site_salt=UInt32(1),
        registered_handle_id=Optional(Int(1)),
    )


def _is_pushed(p: LogicalPlan, semi_side: Int) -> Bool:
    """`p` is INNER with a SEMI/ANTI on `semi_side` (0 left, 1 right)."""
    if p.tag != PLAN_JOIN or p._join.value()[].join_type != JOIN_INNER:
        return False
    if semi_side == 0:
        return p._join.value()[].left[].tag == PLAN_JOIN
    return p._join.value()[].right[].tag == PLAN_JOIN


# -----------------------------------------------------------------------------
# The OptimizerConfig switch and the rewrite
# -----------------------------------------------------------------------------


def test_semi_pushdown_off_returns_the_input_plan_unchanged() raises:
    """`semi_pushdown=False` is the OFF arm: the plan comes back byte-identical
    on the q20 shape that the default rewrites. Catches the config read being
    ignored (the `if not gate.enabled` return removed)."""
    var before = _render(_q20())
    var cfg = OptimizerConfig()
    cfg.semi_pushdown = False
    var out = push_semi_reducers_down(_q20(), cfg)
    assert_equal(_render(out), before)
    assert_equal(Int(out._join.value()[].join_type), Int(JOIN_SEMI))


def test_default_moves_the_semi_below_the_inner_join() raises:
    """The default (on) rewrites SEMI(INNER(A, B), C) into INNER(SEMI(A, C), B)
    with the semi's keys and the carrier's keys kept, and the output schema
    unchanged. Catches the rule not firing and a rebuild that swaps keys."""
    var before = _q20()
    var out = push_semi_reducers_down(_q20(), _on())
    assert_true(_is_pushed(out, 0))
    ref semi = out._join.value()[].left[]
    assert_equal(Int(semi._join.value()[].join_type), Int(JOIN_SEMI))
    assert_equal(semi._join.value()[].left[]._scan.value()[].source_path, "a")
    assert_equal(semi._join.value()[].right[]._scan.value()[].source_path, "c")
    assert_equal(semi._join.value()[].left_on[0], "ak")
    assert_equal(semi._join.value()[].right_on[0], "ck")
    assert_equal(out._join.value()[].left_on[0], "ak")
    assert_equal(out._join.value()[].right_on[0], "bk")
    assert_true(_schema_fields_identical(before.output_schema, out.output_schema))


def test_semi_keyed_on_the_right_child_moves_into_the_right_child() raises:
    """Keyed on `bv` (a column of B): INNER(A, SEMI(B, C)). Catches the mirror
    (side 1) arm building the join with the children exchanged."""
    var out = push_semi_reducers_down(_semi_over(_carrier(), "bv"), _on())
    assert_true(_is_pushed(out, 1))
    assert_equal(out._join.value()[].left[]._scan.value()[].source_path, "a")
    ref semi = out._join.value()[].right[]
    assert_equal(semi._join.value()[].left[]._scan.value()[].source_path, "b")


def test_anti_join_is_pushed_and_stays_anti() raises:
    """ANTI is a per-row filter too; the pushed node keeps JOIN_ANTI. Catches
    the join type being rebuilt as SEMI."""
    var out = push_semi_reducers_down(_semi_over(_carrier(), "ak", JOIN_ANTI), _on())
    assert_true(_is_pushed(out, 0))
    assert_equal(Int(out._join.value()[].left[]._join.value()[].join_type), Int(JOIN_ANTI))


def test_r_a_moves_the_semi_below_a_filter() raises:
    """SEMI(Filter(A), C) becomes Filter(SEMI(A, C)) with the predicate kept.
    Catches the R-A arm dropped."""
    var f = LogicalPlan.filter(Expr.col_ref("av"), _a())
    var out = push_semi_reducers_down(_semi_over(f^, "ak"), _on())
    assert_equal(Int(out.tag), Int(PLAN_FILTER))
    assert_equal(out._filter.value()[].predicate.col_ref_name(), "av")
    ref semi = out._filter.value()[].child[]
    assert_equal(Int(semi._join.value()[].join_type), Int(JOIN_SEMI))
    assert_equal(Int(semi._join.value()[].left[].tag), Int(PLAN_SCAN))


def test_r_a_refuses_a_udf_filter() raises:
    """Rebuilding a typed-UDF filter would drop the UDF. Catches the UDF
    refusal dropped."""
    var f = LogicalPlan.filter_with_udf(
        Expr.col_ref("av"), _a(), OwnedPointer[UdfData](_udf(UDF_KIND_FILTER))
    )
    var out = push_semi_reducers_down(_semi_over(f^, "ak"), _on())
    assert_equal(Int(out.tag), Int(PLAN_JOIN))
    assert_equal(Int(out._join.value()[].join_type), Int(JOIN_SEMI))


def test_r_a_declines_when_the_push_below_it_declines() raises:
    """SEMI(Filter(CSV scan), C): the landing site fails G5, so nothing moves.
    Catches a partial push being adopted."""
    var n: List[String] = ["ak", "av"]
    var f = LogicalPlan.filter(Expr.col_ref("av"), _scan("a", n, 1000, SOURCE_CSV))
    var out = push_semi_reducers_down(_semi_over(f^, "ak"), _on())
    assert_equal(Int(out.tag), Int(PLAN_JOIN))
    assert_equal(Int(out._join.value()[].left[].tag), Int(PLAN_FILTER))


# -----------------------------------------------------------------------------
# The guards
# -----------------------------------------------------------------------------


def test_g1_refuses_a_non_inner_carrier() raises:
    """SEMI(Filter(LEFT(A, B)), C): pushing into a null-extending join changes
    the answer. Catches G1 dropped (R-A reaches the LEFT join)."""
    var lj = _join(_a(), _b(), "ak", "bk", JOIN_LEFT)
    var f = LogicalPlan.filter(Expr.col_ref("av"), lj^)
    var out = push_semi_reducers_down(_semi_over(f^, "ak"), _on())
    assert_equal(Int(out._join.value()[].join_type), Int(JOIN_SEMI))
    assert_equal(Int(out._join.value()[].left[].tag), Int(PLAN_FILTER))


def test_g2_refuses_an_ambiguous_a_renamed_or_a_straddling_key() raises:
    """A key in both children, a `_right` collision name in neither, and two
    keys on different children all decline. Catches each G2 refusal."""
    var an: List[String] = ["k", "av"]
    var bn: List[String] = ["k", "bv"]
    var both = _semi_over(_join(_scan("a", an, 1000), _scan("b", bn, 1000), "k", "k", JOIN_INNER), "k")
    assert_equal(Int(push_semi_reducers_down(both^, _on())._join.value()[].join_type), Int(JOIN_SEMI))

    var renamed = _semi_over(_join(_scan("a", an, 1000), _scan("b", bn, 1000), "k", "k", JOIN_INNER), "k_right")
    assert_equal(Int(push_semi_reducers_down(renamed^, _on())._join.value()[].join_type), Int(JOIN_SEMI))

    var cn: List[String] = ["c1", "c2"]
    var lo: List[String] = ["av", "bv"]
    var ro: List[String] = ["c1", "c2"]
    var straddle = LogicalPlan.join(_carrier(), _scan("c", cn, 10), lo^, ro^, JOIN_SEMI)
    assert_equal(Int(push_semi_reducers_down(straddle^, _on())._join.value()[].join_type), Int(JOIN_SEMI))


def test_g2_residual_columns() raises:
    """The semi's residual may read the target child (`av`) or the semi's own
    right side (`cv`) and is carried down; reading the sibling (`bv`, also a
    column of the right side so that no other check refuses it), a column in
    both the target and the right side, or no column at all declines. Each
    refusal is the only one that applies to its case. Catches each residual
    refusal and a residual lost by the rebuild."""
    var ok_c = push_semi_reducers_down(_semi_with_residual(_c(), "cv"), _on())
    assert_true(_is_pushed(ok_c, 0))
    assert_true(ok_c._join.value()[].left[]._join.value()[].has_residual())
    var ok_a = push_semi_reducers_down(_semi_with_residual(_c(), "av"), _on())
    assert_true(_is_pushed(ok_a, 0))

    var cb: List[String] = ["ck", "bv"]
    var sib = push_semi_reducers_down(_semi_with_residual(_scan("c", cb, 10), "bv"), _on())
    assert_equal(Int(sib._join.value()[].join_type), Int(JOIN_SEMI))
    var none = push_semi_reducers_down(_semi_with_residual(_c(), "zz"), _on())
    assert_equal(Int(none._join.value()[].join_type), Int(JOIN_SEMI))
    var cn: List[String] = ["ck", "av"]
    var amb = push_semi_reducers_down(_semi_with_residual(_scan("c", cn, 10), "av"), _on())
    assert_equal(Int(amb._join.value()[].join_type), Int(JOIN_SEMI))


def test_g4_refuses_a_reducer_not_smaller_than_the_sibling() raises:
    """C with 1000 rows against a 1000-row sibling: moving it first is no win.
    Catches `>=` weakened to `>` (equal cards would fire)."""
    var cn: List[String] = ["ck", "cv"]
    var semi = _join(_carrier(), _scan("c", cn, 1000), "ak", "ck", JOIN_SEMI)
    var out = push_semi_reducers_down(semi^, _on())
    assert_equal(Int(out._join.value()[].join_type), Int(JOIN_SEMI))


def test_g5_refuses_a_landing_site_outside_the_leaf_shape() raises:
    """The target child is an Aggregate (not a scan-leaf shape), or the semi's
    right side is: both decline. Catches either G5 check dropped."""
    var keys = ExprArray()
    keys.append(Expr.col_ref("ak"))
    var agg_a = LogicalPlan.aggregate(keys^, AggExprArray(), _a())
    var c1 = _semi_over(_join(agg_a^, _b(), "ak", "bk", JOIN_INNER), "ak")
    assert_equal(Int(push_semi_reducers_down(c1^, _on())._join.value()[].join_type), Int(JOIN_SEMI))

    var ck = ExprArray()
    ck.append(Expr.col_ref("ck"))
    var agg_c = LogicalPlan.aggregate(ck^, AggExprArray(), _c())
    var c2 = _join(_carrier(), agg_c^, "ak", "ck", JOIN_SEMI)
    assert_equal(Int(push_semi_reducers_down(c2^, _on())._join.value()[].join_type), Int(JOIN_SEMI))


def test_g3_refuses_a_carrier_whose_cached_schema_differs() raises:
    """A carrier whose cached schema is stale cannot be rebuilt to the same
    schema: decline. Called on `_push_semi_into` directly: through the entry
    point the walk hands down a copy of each child, whose schema is
    recomputed, so this per-level check is a second line behind that copy.
    The fresh carrier is the control. Catches the per-level G3 check
    dropped."""
    var lo: List[String] = ["ak"]
    var ro: List[String] = ["ck"]
    var fresh = _push_semi_into(
        _carrier(), _c(), lo.copy(), ro.copy(), JOIN_SEMI, JOIN_ALGO_AUTO, None, 0
    )
    assert_true(Bool(fresh))
    var carrier = _carrier()
    var stale: List[String] = ["ak", "av", "bk", "bv", "extra"]
    carrier.output_schema = _schema(stale)
    var r = _push_semi_into(
        carrier^, _c(), lo^, ro^, JOIN_SEMI, JOIN_ALGO_AUTO, None, 0
    )
    assert_false(Bool(r))


def test_g3_refuses_when_the_root_schema_would_change() raises:
    """The semi's own cached schema disagrees with the rewritten subtree's: the
    rewrite is not adopted. Catches the top-level G3 check dropped."""
    var semi = _q20()
    var other: List[String] = ["ak", "av"]
    semi.output_schema = _schema(other)
    var out = push_semi_reducers_down(semi^, _on())
    assert_equal(Int(out._join.value()[].join_type), Int(JOIN_SEMI))


def test_schema_fields_identical_compares_count_name_type_and_nullability() raises:
    """Catches any one of the four comparisons dropped (a set or name-only
    comparison would pass a reordered or retyped schema)."""
    var n: List[String] = ["x", "y"]
    assert_true(_schema_fields_identical(_schema(n), _schema(n)))
    var one: List[String] = ["x"]
    assert_false(_schema_fields_identical(_schema(n), _schema(one)))
    var swapped: List[String] = ["y", "x"]
    assert_false(_schema_fields_identical(_schema(n), _schema(swapped)))
    var sb = SchemaBuilder()
    sb.add_field(Field("x", ArrowType.INT64, True))
    sb.add_field(Field("y", ArrowType.FLOAT64, True))
    assert_false(_schema_fields_identical(_schema(n), sb.build()))
    var sb2 = SchemaBuilder()
    sb2.add_field(Field("x", ArrowType.INT64, True))
    sb2.add_field(Field("y", ArrowType.INT64, False))
    assert_false(_schema_fields_identical(_schema(n), sb2.build()))


# -----------------------------------------------------------------------------
# The entry pre-checks and the walk
# -----------------------------------------------------------------------------


def test_nothing_to_descend_through_is_declined_without_a_rebuild() raises:
    """SEMI(scan, C), SEMI(LEFT(A, B), C), a zero-key semi, an INNER root and a
    non-join all come back unchanged. Catches each pre-check dropped."""
    var plain = push_semi_reducers_down(_semi_over(_a(), "ak"), _on())
    assert_equal(Int(plain._join.value()[].left[].tag), Int(PLAN_SCAN))

    var lj = _semi_over(_join(_a(), _b(), "ak", "bk", JOIN_LEFT), "ak")
    var out = push_semi_reducers_down(lj^, _on())
    assert_equal(Int(out._join.value()[].join_type), Int(JOIN_SEMI))

    var keyless = LogicalPlan.join(_carrier(), _c(), List[String](), List[String](), JOIN_SEMI)
    assert_equal(Int(push_semi_reducers_down(keyless^, _on())._join.value()[].join_type), Int(JOIN_SEMI))

    var inner = push_semi_reducers_down(_carrier(), _on())
    assert_equal(Int(inner._join.value()[].left[].tag), Int(PLAN_SCAN))

    var leaf = _try_push_one_semi_reducer(_a())
    assert_equal(Int(leaf.tag), Int(PLAN_SCAN))


def test_every_wrapper_and_both_join_sides_are_walked() raises:
    """The rewrite fires under Filter, Project, Aggregate, Sort, Limit,
    Distinct, TopN and on both sides of a join. Catches a walk arm dropped."""
    var f = push_semi_reducers_down(LogicalPlan.filter(Expr.col_ref("ak"), _q20()), _on())
    assert_true(_is_pushed(f._filter.value()[].child[], 0))

    var pe = ExprArray()
    pe.append(Expr.col_ref("ak"))
    var p = push_semi_reducers_down(LogicalPlan.project(pe^, _q20()), _on())
    assert_true(_is_pushed(p._project.value()[].child[], 0))

    var keys = ExprArray()
    keys.append(Expr.col_ref("ak"))
    var a = push_semi_reducers_down(LogicalPlan.aggregate(keys^, AggExprArray(), _q20()), _on())
    assert_true(_is_pushed(a._aggregate.value()[].child[], 0))

    var sk: List[String] = ["ak"]
    var sd: List[Bool] = [False]
    var s = push_semi_reducers_down(LogicalPlan.sort(sk^, sd^, _q20()), _on())
    assert_true(_is_pushed(s._sort.value()[].child[], 0))

    var l = push_semi_reducers_down(LogicalPlan.limit(2, _q20()), _on())
    assert_true(_is_pushed(l._limit.value()[].child[], 0))

    var d = push_semi_reducers_down(LogicalPlan.distinct(None, _q20()), _on())
    assert_true(_is_pushed(d._distinct.value()[].child[], 0))

    var tk: List[String] = ["ak"]
    var td: List[Bool] = [False]
    var t = push_semi_reducers_down(LogicalPlan.topn(tk^, td^, 2, _q20()), _on())
    assert_true(_is_pushed(t._topn.value()[].child[], 0))

    var j = push_semi_reducers_down(_join(_q20(), _q20(), "ak", "ak", JOIN_INNER), _on())
    assert_true(_is_pushed(j._join.value()[].left[], 0))
    assert_true(_is_pushed(j._join.value()[].right[], 0))


def test_a_node_whose_tag_has_no_payload_is_returned_as_is() raises:
    """Each walk arm also checks the node's payload is present; a bare tag is
    returned unchanged (and a bare JOIN under a semi admits nothing). Catches a
    payload check dropped, which would read an empty Optional."""
    var tags: List[UInt8] = [
        PLAN_FILTER, PLAN_PROJECT, PLAN_AGGREGATE, PLAN_SORT, PLAN_LIMIT,
        PLAN_DISTINCT, PLAN_TOPN, PLAN_JOIN,
    ]
    var n: List[String] = ["ak"]
    for i in range(len(tags)):
        var out = push_semi_reducers_down(LogicalPlan(tags[i], _schema(n)), _on())
        assert_equal(Int(out.tag), Int(tags[i]))
    # A semi over a bare JOIN tag admits nothing. Called on the per-node step
    # directly: the walk's copy of the children refuses a bare node first.
    var semi = _semi_over(LogicalPlan(PLAN_JOIN, _schema(n)), "ak")
    var out2 = _try_push_one_semi_reducer(semi^)
    assert_equal(Int(out2._join.value()[].join_type), Int(JOIN_SEMI))
    assert_equal(Int(out2._join.value()[].left[].tag), Int(PLAN_JOIN))
    var bare = _try_push_one_semi_reducer(LogicalPlan(PLAN_JOIN, _schema(n)))
    assert_equal(Int(bare.tag), Int(PLAN_JOIN))


# -----------------------------------------------------------------------------
# The helpers, called directly for the arms the entry never reaches
# -----------------------------------------------------------------------------


def test_push_at_depth_zero_with_nothing_descended_declines() raises:
    """The base case at depth 0 would rebuild its own input: it answers None.
    Catches the depth-0 check dropped (a pointless rebuild)."""
    var lo: List[String] = ["ak"]
    var ro: List[String] = ["ck"]
    var r = _push_semi_into(_a(), _c(), lo^, ro^, JOIN_SEMI, JOIN_ALGO_AUTO, None, 0)
    assert_false(Bool(r))


def test_target_side_declines_a_non_join_carrier_and_no_keys() raises:
    """Catches the carrier and empty-key checks dropped."""
    var lo: List[String] = ["ak"]
    assert_equal(_semi_target_side(_a(), lo, _c(), None), -1)
    var n: List[String] = ["ak"]
    assert_equal(_semi_target_side(LogicalPlan(PLAN_JOIN, _schema(n)), lo, _c(), None), -1)
    assert_equal(_semi_target_side(_carrier(), List[String](), _c(), None), -1)
    assert_equal(_semi_target_side(_carrier(), lo, _c(), None), 0)


def test_pure_colref_project() raises:
    """Col-refs and aliases of col-refs are pure; a computed column, a UDF
    project, an empty project, a bare PROJECT tag and a non-project are not.
    Catches each refusal dropped and the alias arm dropped."""
    var e = ExprArray()
    e.append(Expr.col_ref("ak"))
    e.append(Expr.alias(Expr.col_ref("av"), "x"))
    assert_true(_pure_colref_project(LogicalPlan.project(e^, _a())))

    var c = ExprArray()
    c.append(Expr.binary(BIN_ADD, Expr.col_ref("ak"), Expr.col_ref("av")))
    assert_false(_pure_colref_project(LogicalPlan.project(c^, _a())))

    var ce = ExprArray()
    ce.append(Expr.alias(Expr.binary(BIN_ADD, Expr.col_ref("ak"), Expr.col_ref("av")), "s"))
    assert_false(_pure_colref_project(LogicalPlan.project(ce^, _a())))

    var u = ExprArray()
    u.append(Expr.col_ref("ak"))
    var up = LogicalPlan.project_with_udf(u^, _a(), OwnedPointer[UdfData](_udf(UDF_KIND_MAP)))
    assert_false(_pure_colref_project(up))

    assert_false(_pure_colref_project(LogicalPlan.project(ExprArray(), _a())))
    var n: List[String] = ["ak"]
    assert_false(_pure_colref_project(LogicalPlan(PLAN_PROJECT, _schema(n))))
    assert_false(_pure_colref_project(_a()))


def test_filter_chain_and_leaf_shape() raises:
    """FILTER* -> parquet SCAN is a leaf; a UDF filter, a CSV scan, a bare tag
    and any other node are not. PROJECT? on top must be pure. Catches each
    shape refusal dropped and the source-type check inverted."""
    var two = LogicalPlan.filter(Expr.col_ref("ak"), LogicalPlan.filter(Expr.col_ref("av"), _a()))
    assert_true(_filter_chain_bottoms_in_parquet_scan(two))

    var uf = LogicalPlan.filter_with_udf(
        Expr.col_ref("ak"), _a(), OwnedPointer[UdfData](_udf(UDF_KIND_FILTER))
    )
    assert_false(_filter_chain_bottoms_in_parquet_scan(uf))
    var n: List[String] = ["ak"]
    assert_false(_filter_chain_bottoms_in_parquet_scan(_scan("x", n, 5, SOURCE_CSV)))
    assert_false(_filter_chain_bottoms_in_parquet_scan(LogicalPlan(PLAN_FILTER, _schema(n))))
    assert_false(_filter_chain_bottoms_in_parquet_scan(LogicalPlan(PLAN_SCAN, _schema(n))))
    assert_false(_filter_chain_bottoms_in_parquet_scan(_carrier()))

    var pe = ExprArray()
    pe.append(Expr.col_ref("ak"))
    var pure = LogicalPlan.project(pe^, LogicalPlan.filter(Expr.col_ref("av"), _a()))
    assert_true(_side_is_parquet_leaf_shape(pure))
    var ce = ExprArray()
    ce.append(Expr.binary(BIN_ADD, Expr.col_ref("ak"), Expr.col_ref("av")))
    assert_false(_side_is_parquet_leaf_shape(LogicalPlan.project(ce^, _a())))
    assert_true(_side_is_parquet_leaf_shape(_a()))


def test_a_pure_project_leaf_is_an_accepted_landing_site() raises:
    """The semi's right side as PROJECT(col-ref) over a parquet scan passes G5
    and the rule fires. Catches the project arm of the leaf shape dropped."""
    var pe = ExprArray()
    pe.append(Expr.col_ref("ck"))
    var cp = LogicalPlan.project(pe^, _c())
    var semi = _join(_carrier(), cp^, "ak", "ck", JOIN_SEMI)
    assert_true(_is_pushed(push_semi_reducers_down(semi^, _on()), 0))


def test_r_b_carries_the_carrier_residual_onto_the_rebuilt_join() raises:
    """The INNER carrier has its own residual (`av < bv`): the push leaves both
    children's schemas unchanged, so the rebuilt INNER keeps that residual,
    rendered identically. Catches the carrier residual dropped by the rebuild
    (the rewritten join would match rows the original rejected)."""
    var lo: List[String] = ["ak"]
    var ro: List[String] = ["bk"]
    var res = Optional[OwnedPointer[Expr]](
        OwnedPointer(Expr.binary(BIN_LT, Expr.col_ref("av"), Expr.col_ref("bv")))
    )
    var carrier = LogicalPlan.join(
        _a(), _b(), lo^, ro^, JOIN_INNER, JOIN_ALGO_AUTO, res^
    )
    var want = String("")
    carrier._join.value()[].residual.value()[].write_to(want)
    var out = push_semi_reducers_down(_semi_over(carrier^, "ak"), _on())
    assert_true(_is_pushed(out, 0))
    assert_true(out._join.value()[].has_residual())
    var got = String("")
    out._join.value()[].residual.value()[].write_to(got)
    assert_equal(got, want)
    assert_false(out._join.value()[].left[]._join.value()[].has_residual())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
