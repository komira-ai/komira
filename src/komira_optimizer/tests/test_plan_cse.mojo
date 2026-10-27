# =============================================================================
# test_plan_cse.mojo -- plan-level CSE: which repeated subtrees are replaced by
# a CSE reference, which one stays, and which repeats are left alone.
#
# Each test builds a small plan, runs `plan_cse_eliminate` (or the forest
# form) and checks the rewritten shape node by node. Detection counts are
# checked against `structural_hash()` of an independently built copy of the
# repeated subtree. Nothing here executes a plan.
# =============================================================================

from std.collections import Optional
from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.agg_expr import AggExpr, AGG_COUNT
from komira_plan_expr.expr import Expr, BIN_GT
from komira_plan_expr.partition_expr import PartitionExpr
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_expr.udf_data import (
    UdfData,
    UDF_KIND_AGG,
    UDF_KIND_FILTER,
    UDF_KIND_MAP,
)
from komira_plan_ir.logical_plan import (
    AggExprArray,
    AsofTolerance,
    ExprArray,
    LogicalPlan,
    ASOF_BACKWARD,
    JOIN_INNER,
    PLAN_AGGREGATE,
    PLAN_ASOF_JOIN,
    PLAN_CSE_REF,
    PLAN_DISTINCT,
    PLAN_FILTER,
    PLAN_JOIN,
    PLAN_LIMIT,
    PLAN_PARTITION_BY,
    PLAN_PARTITION_TOPN,
    PLAN_PROJECT,
    PLAN_SCAN,
    PLAN_SORT,
    PLAN_TOPN,
    PLAN_UNION,
    SOURCE_PARQUET,
)

from komira_optimizer.plan_cse import (
    plan_cse_eliminate,
    plan_cse_eliminate_forest,
    detect_cse_candidates,
    count_subtree_occurrences,
)
from komira_optimizer.subtree_hash_walk import plan_is_pure, plan_has_scan


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


def _schema() -> Schema:
    var b = SchemaBuilder()
    b.add_field(Field(String("k"), ArrowType.INT64, False))
    b.add_field(Field(String("v"), ArrowType.INT64, False))
    return b.build()


def _scan(path: String = String("t.parquet")) -> LogicalPlan:
    return LogicalPlan.scan(path, SOURCE_PARQUET, _schema())


def _gt(n: Int) -> Expr:
    return Expr.binary(
        BIN_GT, Expr.col_ref("v"), Expr.literal(ScalarValue.from_int(n))
    )


def _filt(n: Int = 10, path: String = String("t.parquet")) -> LogicalPlan:
    """`Filter(v > n, Scan(path))`, the usual repeated subtree."""
    return LogicalPlan.filter(_gt(n), _scan(path))


def _proj(var child: LogicalPlan) -> LogicalPlan:
    var ex = ExprArray()
    ex.append(Expr.col_ref("k"))
    return LogicalPlan.project(ex^, child^)


def _one(s: String) -> List[String]:
    var out = List[String]()
    out.append(s)
    return out^


def _desc() -> List[Bool]:
    var d = List[Bool]()
    d.append(False)
    return d^


def _join(var a: LogicalPlan, var b: LogicalPlan) -> LogicalPlan:
    return LogicalPlan.join(a^, b^, _one("k"), _one("k"), JOIN_INNER)


def _union(var a: LogicalPlan, var b: LogicalPlan) -> LogicalPlan:
    var schema = a.output_schema.copy()
    var kids = List[OwnedPointer[LogicalPlan]]()
    kids.append(OwnedPointer(a^))
    kids.append(OwnedPointer(b^))
    return LogicalPlan.union(kids^, schema^)


def _union3(
    var a: LogicalPlan, var b: LogicalPlan, var c: LogicalPlan
) -> LogicalPlan:
    var schema = a.output_schema.copy()
    var kids = List[OwnedPointer[LogicalPlan]]()
    kids.append(OwnedPointer(a^))
    kids.append(OwnedPointer(b^))
    kids.append(OwnedPointer(c^))
    return LogicalPlan.union(kids^, schema^)


def _asof(var a: LogicalPlan, var b: LogicalPlan) -> LogicalPlan:
    return LogicalPlan.asof_join(
        a^,
        b^,
        List[String](),
        List[String](),
        String("k"),
        String("k"),
        ASOF_BACKWARD,
        AsofTolerance.none(),
    )


def _udf(kind: UInt8) -> OwnedPointer[UdfData]:
    """The same function id and call-site salt every time, so two nodes built
    from it render identically."""
    var ic = List[Tuple[String, UInt8]]()
    ic.append((String("v"), UInt8(2)))
    var oc = List[Tuple[String, UInt8]]()
    oc.append((String("y"), UInt8(2)))
    return OwnedPointer(UdfData(kind, String("f"), ic^, oc^, 7101, 3))


def _udf_filter() -> LogicalPlan:
    return LogicalPlan.filter_with_udf(
        Expr.literal(ScalarValue.from_bool(True)),
        _scan(),
        _udf(UDF_KIND_FILTER),
    )


def _udf_project() -> LogicalPlan:
    var ex = ExprArray()
    ex.append(Expr.col_ref("k"))
    return LogicalPlan.project_with_udf(ex^, _scan(), _udf(UDF_KIND_MAP))


def _udf_aggregate() -> LogicalPlan:
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_COUNT, None, Optional(String("n"))))
    return LogicalPlan.aggregate_with_udf(
        ExprArray(), aggs^, _scan(), _udf(UDF_KIND_AGG)
    )


def _children(plan: LogicalPlan) -> List[LogicalPlan]:
    """Copies of `plan`'s children in the order the node stores them."""
    var out = List[LogicalPlan]()
    if plan.tag == PLAN_FILTER:
        out.append(plan._filter.value()[].child[].copy())
    elif plan.tag == PLAN_PROJECT:
        out.append(plan._project.value()[].child[].copy())
    elif plan.tag == PLAN_AGGREGATE:
        out.append(plan._aggregate.value()[].child[].copy())
    elif plan.tag == PLAN_JOIN:
        out.append(plan._join.value()[].left[].copy())
        out.append(plan._join.value()[].right[].copy())
    elif plan.tag == PLAN_SORT:
        out.append(plan._sort.value()[].child[].copy())
    elif plan.tag == PLAN_LIMIT:
        out.append(plan._limit.value()[].child[].copy())
    elif plan.tag == PLAN_DISTINCT:
        out.append(plan._distinct.value()[].child[].copy())
    elif plan.tag == PLAN_TOPN:
        out.append(plan._topn.value()[].child[].copy())
    elif plan.tag == PLAN_PARTITION_BY:
        out.append(plan._partition_by.value()[].child[].copy())
    elif plan.tag == PLAN_PARTITION_TOPN:
        out.append(plan._partition_topn.value()[].child[].copy())
    elif plan.tag == PLAN_ASOF_JOIN:
        out.append(plan._asof_join.value()[].left[].copy())
        out.append(plan._asof_join.value()[].right[].copy())
    elif plan.tag == PLAN_UNION:
        ref ud = plan._union.value()[]
        for i in range(len(ud.children)):
            out.append(ud.children[i][].copy())
    return out^


def _count_tag(plan: LogicalPlan, tag: UInt8) -> Int:
    var n = 0
    if plan.tag == tag:
        n += 1
    for c in _children(plan):
        n += _count_tag(c, tag)
    return n


def _ref_hashes(plan: LogicalPlan) -> List[UInt64]:
    """The canonical hash of every CSE reference, in storage order."""
    var out = List[UInt64]()
    if plan.tag == PLAN_CSE_REF:
        out.append(plan._cse_ref.value()[].canonical_hash)
    for c in _children(plan):
        for h in _ref_hashes(c):
            out.append(h)
    return out^


# ---------------------------------------------------------------------------
# What the rewrite does
# ---------------------------------------------------------------------------


def test_self_join_keeps_the_build_side_and_references_it() raises:
    """Join(F, F): the right (build) side keeps the Filter subtree, the left
    side becomes a reference naming its hash and carrying its schema. Pins
    the visit order, one canonical, and the schema snapshot.

    Defects caught: a rewrite that keeps the left occurrence instead of the
    build side, a reference that names the wrong hash, a reference without
    the replaced node's schema."""
    var sub_h = _filt().structural_hash()
    var out = plan_cse_eliminate(_join(_filt(), _filt()))
    var kids = _children(out)
    assert_equal(Int(out.tag), Int(PLAN_JOIN))
    assert_equal(Int(kids[0].tag), Int(PLAN_CSE_REF))
    assert_equal(Int(kids[1].tag), Int(PLAN_FILTER))
    assert_equal(kids[0]._cse_ref.value()[].canonical_hash, sub_h)
    assert_equal(kids[0].structural_hash(), sub_h)
    assert_equal(kids[0].output_schema.num_columns(), 2)
    assert_equal(kids[0].output_schema.field_at_unchecked(0).name, String("k"))
    assert_equal(kids[0].output_schema.field_at_unchecked(1).name, String("v"))
    assert_equal(_count_tag(out, PLAN_SCAN), 1)


def test_duplicate_nested_in_the_probe_side_is_referenced() raises:
    """Join(Project(F), F): F occurs once on the build side and once under
    the left Project. The build side is canonical; the Project stays and its
    child becomes the reference.

    Defects caught: replacing the whole Project, or keeping the nested copy
    and referencing the build side from the wrong direction."""
    var out = plan_cse_eliminate(_join(_proj(_filt()), _filt()))
    var kids = _children(out)
    assert_equal(Int(kids[0].tag), Int(PLAN_PROJECT))
    assert_equal(Int(_children(kids[0])[0].tag), Int(PLAN_CSE_REF))
    assert_equal(Int(kids[1].tag), Int(PLAN_FILTER))
    assert_equal(_count_tag(out, PLAN_PROJECT), 1)


def test_a_whole_duplicated_branch_becomes_one_reference() raises:
    """Join(Project(F), Project(F)): the larger subtree repeats, so the left
    Project is replaced as one node and nothing below it is visited.

    Defects caught: referencing the inner Filter and leaving two Projects."""
    var big_h = _proj(_filt()).structural_hash()
    var out = plan_cse_eliminate(_join(_proj(_filt()), _proj(_filt())))
    var kids = _children(out)
    assert_equal(Int(kids[0].tag), Int(PLAN_CSE_REF))
    assert_equal(Int(kids[1].tag), Int(PLAN_PROJECT))
    assert_equal(_count_tag(out, PLAN_PROJECT), 1)
    assert_equal(_count_tag(out, PLAN_FILTER), 1)
    assert_equal(_count_tag(out, PLAN_SCAN), 1)
    var refs = _ref_hashes(out)
    assert_equal(len(refs), 1)
    assert_equal(refs[0], big_h)


def test_union_branches_first_stays_and_the_rest_reference_it() raises:
    """Union(F, F, F): branches are visited left to right, so the first
    stays and the second and third are references to it.

    Defects caught: a union walk that skips branches, a rewrite that keeps
    the last occurrence, one reference per group instead of one per extra
    occurrence."""
    var sub_h = _filt().structural_hash()
    var out = plan_cse_eliminate(_union3(_filt(), _filt(), _filt()))
    var kids = _children(out)
    assert_equal(Int(kids[0].tag), Int(PLAN_FILTER))
    assert_equal(Int(kids[1].tag), Int(PLAN_CSE_REF))
    assert_equal(Int(kids[2].tag), Int(PLAN_CSE_REF))
    var refs = _ref_hashes(out)
    assert_equal(len(refs), 2)
    assert_equal(refs[0], sub_h)
    assert_equal(refs[1], sub_h)


def test_a_duplicate_inside_the_canonical_subtree_is_shared_too() raises:
    """Union(X, X) with X = Join(F, F): the first X stays and, inside it, one
    F stays and the other is a reference; the second X is one reference.

    Defects caught: a walk that stops at the canonical occurrence and leaves
    its own repeats unshared."""
    var x_h = _join(_filt(), _filt()).structural_hash()
    var out = plan_cse_eliminate(
        _union(_join(_filt(), _filt()), _join(_filt(), _filt()))
    )
    assert_equal(_count_tag(out, PLAN_FILTER), 1)
    assert_equal(_count_tag(out, PLAN_SCAN), 1)
    var kids = _children(out)
    assert_equal(Int(kids[0].tag), Int(PLAN_JOIN))
    assert_equal(Int(kids[1].tag), Int(PLAN_CSE_REF))
    assert_equal(kids[1]._cse_ref.value()[].canonical_hash, x_h)
    assert_equal(len(_ref_hashes(out)), 2)


def test_rewriting_twice_changes_nothing_the_second_time() raises:
    """A reference is a leaf with no scan, so a second pass finds no
    candidate and the plan hashes the same.

    Defects caught: a reference counted as a scan-bearing subtree, which
    would wrap a reference in a reference."""
    var once = plan_cse_eliminate(_join(_filt(), _filt()))
    var h = once.structural_hash()
    var twice = plan_cse_eliminate(once^)
    assert_equal(twice.structural_hash(), h)
    assert_equal(len(_ref_hashes(twice)), 1)
    assert_equal(_count_tag(twice, PLAN_FILTER), 1)


# ---------------------------------------------------------------------------
# What it must leave alone
# ---------------------------------------------------------------------------


def test_a_plan_with_no_repeat_is_returned_unchanged() raises:
    var p = _join(_filt(10, "a.parquet"), _filt(20, "b.parquet"))
    var h = p.structural_hash()
    var out = plan_cse_eliminate(p^)
    assert_equal(out.structural_hash(), h)
    assert_equal(len(_ref_hashes(out)), 0)
    assert_equal(_count_tag(out, PLAN_SCAN), 2)


def test_different_predicates_share_only_the_scan() raises:
    """Join(Filter(v>10, S), Filter(v>50, S)): the two Filters render
    differently and both stay; only the identical bare scan below them is
    shared.

    Defects caught: merging two filters whose predicates differ."""
    var out = plan_cse_eliminate(_join(_filt(10), _filt(50)))
    assert_equal(_count_tag(out, PLAN_FILTER), 2)
    assert_equal(_count_tag(out, PLAN_SCAN), 1)
    assert_equal(len(_ref_hashes(out)), 1)
    assert_equal(
        _ref_hashes(out)[0], _scan().structural_hash()
    )


def test_udf_nodes_with_identical_text_are_not_shared() raises:
    """Two UDF Filters over the same scan with the same function id and the
    same call-site salt render identically, and still are not shared; neither
    is the scan under them, because an impure subtree is not walked.

    Defects caught: dropping the `has_udf` check, which would reference one
    UDF execution from the place of another."""
    var p = _join(_udf_filter(), _udf_filter())
    var h = p.structural_hash()
    assert_equal(detect_cse_candidates(p), 0)
    var out = plan_cse_eliminate(p^)
    assert_equal(out.structural_hash(), h)
    assert_equal(len(_ref_hashes(out)), 0)
    assert_equal(_count_tag(out, PLAN_FILTER), 2)
    assert_equal(_count_tag(out, PLAN_SCAN), 2)


def test_udf_project_and_aggregate_pairs_are_not_shared() raises:
    var pp = _join(_udf_project(), _udf_project())
    var ph = pp.structural_hash()
    assert_equal(plan_cse_eliminate(pp^).structural_hash(), ph)
    var ap = _join(_udf_aggregate(), _udf_aggregate())
    var ah = ap.structural_hash()
    assert_equal(plan_cse_eliminate(ap^).structural_hash(), ah)


def test_repeats_with_no_scan_are_not_shared() raises:
    """Two view references have no scan to read twice, so a repeat of them is
    left alone.

    Defects caught: counting scan-free subtrees as candidates."""
    var a = LogicalPlan.view_ref(String("vw"), _schema())
    var b = LogicalPlan.view_ref(String("vw"), _schema())
    var p = _join(a^, b^)
    var h = p.structural_hash()
    assert_equal(detect_cse_candidates(p), 0)
    var out = plan_cse_eliminate(p^)
    assert_equal(out.structural_hash(), h)
    assert_equal(len(_ref_hashes(out)), 0)
    assert_false(plan_has_scan(LogicalPlan.view_ref(String("vw"), _schema())))
    assert_false(plan_has_scan(_union(
        LogicalPlan.view_ref(String("vw"), _schema()),
        LogicalPlan.view_ref(String("vw"), _schema()),
    )))


# ---------------------------------------------------------------------------
# Purity classifier
# ---------------------------------------------------------------------------


def test_purity_refuses_udf_nodes_wherever_they_sit() raises:
    """Every node kind that holds a child answers from its children, and a
    UDF Filter, Project or Aggregate answers False on its own.

    Defects caught: a join, as-of join or union arm that checks only one
    side; a UDF kind missing from the classifier."""
    assert_true(plan_is_pure(_filt()))
    assert_false(plan_is_pure(_udf_filter()))
    assert_false(plan_is_pure(_udf_project()))
    assert_false(plan_is_pure(_udf_aggregate()))
    assert_false(plan_is_pure(_join(_udf_filter(), _filt())))
    assert_false(plan_is_pure(_join(_filt(), _udf_filter())))
    assert_false(plan_is_pure(_asof(_udf_filter(), _filt())))
    assert_false(plan_is_pure(_asof(_filt(), _udf_filter())))
    assert_false(plan_is_pure(_union(_filt(), _udf_filter())))
    assert_false(plan_is_pure(_proj(_udf_filter())))
    assert_true(plan_is_pure(_union(_filt(), _filt())))
    assert_true(plan_is_pure(LogicalPlan.view_ref(String("vw"), _schema())))


def test_purity_refuses_a_node_kind_it_does_not_know() raises:
    """A tag that is not on the allowlist is not pure, so a kind added later
    is not shared until it is listed.

    Defects caught: a classifier that answers True by default."""
    var unknown = LogicalPlan(UInt8(200), _schema())
    assert_false(plan_is_pure(unknown))
    assert_false(plan_has_scan(unknown))


# ---------------------------------------------------------------------------
# Detection counts
# ---------------------------------------------------------------------------


def test_detection_counts_groups_and_occurrences() raises:
    """Join(F, F) holds two repeated groups, the Filter subtree and the bare
    scan inside it; the Filter subtree occurs twice, an unrelated hash zero
    times, and the whole Join once.

    Defects caught: counting a subtree once per parent, missing the nested
    scan group."""
    var p = _join(_filt(), _filt())
    assert_equal(detect_cse_candidates(p), 2)
    assert_equal(count_subtree_occurrences(p, _filt().structural_hash()), 2)
    assert_equal(count_subtree_occurrences(p, _scan().structural_hash()), 2)
    assert_equal(count_subtree_occurrences(p, p.structural_hash()), 1)
    assert_equal(count_subtree_occurrences(p, UInt64(12345)), 0)


# ---------------------------------------------------------------------------
# Every node kind that carries children
# ---------------------------------------------------------------------------

comptime N_KINDS = 12


def _wrap(kind: Int, var child: LogicalPlan) raises -> LogicalPlan:
    """Kinds: 0 Filter, 1 Project, 2 Aggregate, 3 Sort, 4 Limit, 5 Distinct,
    6 TopN, 7 PartitionBy, 8 PartitionTopN, 9 Join, 10 AsofJoin, 11 Union."""
    if kind == 0:
        return LogicalPlan.filter(_gt(1), child^)
    if kind == 1:
        return _proj(child^)
    if kind == 2:
        var aggs = AggExprArray()
        aggs.append(AggExpr(AGG_COUNT, None, Optional(String("n"))))
        return LogicalPlan.aggregate(ExprArray(), aggs^, child^)
    if kind == 3:
        return LogicalPlan.sort(_one("k"), _desc(), child^)
    if kind == 4:
        return LogicalPlan.limit(5, child^)
    if kind == 5:
        return LogicalPlan.distinct(Optional(_one("k")), child^)
    if kind == 6:
        return LogicalPlan.topn(_one("k"), _desc(), 3, child^)
    if kind == 7:
        return LogicalPlan.partition_by(
            _one("k"), _one("v"), _desc(), List[PartitionExpr](), child^
        )
    if kind == 8:
        return LogicalPlan.partition_topn(
            _one("k"), _one("v"), _desc(), 1, child^
        )
    if kind == 9:
        return _join(child^, _scan("u.parquet"))
    if kind == 10:
        return _asof(child^, _scan("u.parquet"))
    return _union(child^, _scan("u.parquet"))


def _kind_tag(kind: Int) -> UInt8:
    if kind == 0:
        return PLAN_FILTER
    if kind == 1:
        return PLAN_PROJECT
    if kind == 2:
        return PLAN_AGGREGATE
    if kind == 3:
        return PLAN_SORT
    if kind == 4:
        return PLAN_LIMIT
    if kind == 5:
        return PLAN_DISTINCT
    if kind == 6:
        return PLAN_TOPN
    if kind == 7:
        return PLAN_PARTITION_BY
    if kind == 8:
        return PLAN_PARTITION_TOPN
    if kind == 9:
        return PLAN_JOIN
    if kind == 10:
        return PLAN_ASOF_JOIN
    return PLAN_UNION


def test_every_node_kind_is_walked_counted_and_replaced() raises:
    """For each node kind W, Union(W(F), W(F)) keeps the first W(F) whole and
    turns the second into one reference naming W(F)'s hash. That takes the
    scan test, the purity test, the count and the rewrite through W.

    Defects caught: a node kind missing from any of those walks, which would
    leave both copies in place (or, in the count, never see them)."""
    for kind in range(N_KINDS):
        var want_h = _wrap(kind, _filt()).structural_hash()
        var p = _union(_wrap(kind, _filt()), _wrap(kind, _filt()))
        assert_true(plan_is_pure(p))
        assert_equal(
            count_subtree_occurrences(p, want_h),
            2,
            msg="occurrences, kind " + String(kind),
        )
        var out = plan_cse_eliminate(p^)
        var kids = _children(out)
        assert_equal(
            Int(kids[0].tag),
            Int(_kind_tag(kind)),
            msg="first, kind " + String(kind),
        )
        assert_equal(
            Int(kids[1].tag),
            Int(PLAN_CSE_REF),
            msg="second, kind " + String(kind),
        )
        var refs = _ref_hashes(out)
        assert_equal(len(refs), 1, msg="refs, kind " + String(kind))
        assert_equal(refs[0], want_h, msg="hash, kind " + String(kind))


def test_a_repeat_below_each_node_kind_is_shared() raises:
    """For each node kind W, Union(W(F), W(G)) with F = Filter(v>10, S) and G
    = Filter(v>99, S): the Ws differ, so both stay, and the rewrite reaches
    the bare scan S below each, keeping one and referencing the other. The
    walk therefore descends through W to a repeat below it.

    Defects caught: a rewrite arm that does not descend into W's child."""
    for kind in range(N_KINDS):
        var p = _union(_wrap(kind, _filt(10)), _wrap(kind, _filt(99)))
        var out = plan_cse_eliminate(p^)
        var kids = _children(out)
        assert_equal(Int(kids[0].tag), Int(_kind_tag(kind)))
        assert_equal(Int(kids[1].tag), Int(_kind_tag(kind)))
        var refs = _ref_hashes(out)
        assert_true(len(refs) >= 1, msg="no reference, kind " + String(kind))
        assert_equal(refs[0], _scan().structural_hash())
        # F and G both stay; a Filter wrapper adds two more Filters.
        var want_filters = 2
        if kind == 0:
            want_filters = 4
        assert_equal(_count_tag(out, PLAN_FILTER), want_filters)


# ---------------------------------------------------------------------------
# Forest form
# ---------------------------------------------------------------------------


def test_forest_keeps_the_first_plans_occurrence() raises:
    """Plans [F, Project(F)]: the Filter stays in plan 0, and plan 1 keeps its
    Project over a reference to it.

    Defects caught: a claimed set that restarts per plan, which would keep an
    occurrence in every plan."""
    var plans = List[LogicalPlan]()
    plans.append(_filt())
    plans.append(_proj(_filt()))
    var sub_h = _filt().structural_hash()
    plan_cse_eliminate_forest(plans)
    assert_equal(Int(plans[0].tag), Int(PLAN_FILTER))
    assert_equal(Int(plans[1].tag), Int(PLAN_PROJECT))
    var inner = _children(plans[1])[0].copy()
    assert_equal(Int(inner.tag), Int(PLAN_CSE_REF))
    assert_equal(inner._cse_ref.value()[].canonical_hash, sub_h)


def test_forest_with_no_shared_subtree_is_unchanged() raises:
    var plans = List[LogicalPlan]()
    plans.append(_filt(10, "a.parquet"))
    plans.append(_filt(10, "b.parquet"))
    var h0 = plans[0].structural_hash()
    var h1 = plans[1].structural_hash()
    plan_cse_eliminate_forest(plans)
    assert_equal(plans[0].structural_hash(), h0)
    assert_equal(plans[1].structural_hash(), h1)
    assert_equal(len(_ref_hashes(plans[0])) + len(_ref_hashes(plans[1])), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
