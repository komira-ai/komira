# =============================================================================
# optimizer_shared_relation_cse: fingerprint, detect walk, install walk
# =============================================================================
#
# The direct q11 cases live in test_optimizer_shared_relation_cse_detect. This
# file reaches the rest of the module: every arm of the projection-insensitive
# fingerprint, every wrapper `_extract_agg_relation` looks through, every node
# kind the detector recurses into, and every node kind
# `install_shared_cross_source` rebuilds. Each test names the defect it catches.
# =============================================================================

from std.memory import ArcPointer, OwnedPointer
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_collections.slab import Slab
from komira_plan_expr.agg_expr import AggExpr, sum as agg_sum, max as agg_max
from komira_plan_expr.col_expr import col
from komira_plan_expr.expr import Expr, BIN_ADD, BIN_GT, BIN_EQ
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import (
    AggExprArray,
    AsofTolerance,
    ExprArray,
    LogicalPlan,
    SOURCE_PARQUET,
    ASOF_BACKWARD,
    JOIN_CROSS,
    JOIN_INNER,
    JOIN_LEFT,
    JOIN_ALGO_HASH,
    PLAN_AGGREGATE,
    PLAN_DISTINCT,
    PLAN_FILTER,
    PLAN_JOIN,
    PLAN_LIMIT,
    PLAN_PROJECT,
    PLAN_SCAN,
    PLAN_SORT,
    PLAN_TOPN,
)
from komira_scan_source.in_memory_source import InMemorySource
from komira_scan_source.source_variant import (
    SOURCE_VARIANT_IN_MEMORY,
    SOURCE_VARIANT_PARQUET,
)
from komira_optimizer.optimizer_shared_relation_cse import (
    _extract_agg_relation,
    _relation_fingerprint,
    detect_shared_cross_canonical,
    install_shared_cross_source,
)


# -----------------------------------------------------------------------------
# fixtures
# -----------------------------------------------------------------------------


def _t_schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("pk", ArrowType.INT64, False))
    sb.add_field(Field("v", ArrowType.INT64, False))
    sb.add_field(Field("w", ArrowType.INT64, False))
    return sb.build()


def _pk_v_schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("pk", ArrowType.INT64, False))
    sb.add_field(Field("v", ArrowType.INT64, False))
    return sb.build()


def _l1(a: String) -> List[String]:
    var out = List[String]()
    out.append(a)
    return out^


def _l2(a: String, b: String) -> List[String]:
    var out = List[String]()
    out.append(a)
    out.append(b)
    return out^


def _lit(k: Int) -> Expr:
    return Expr.literal(ScalarValue.from_int(k))


def _scan(var proj: List[String], var filter: Optional[Expr] = None) -> LogicalPlan:
    return LogicalPlan.scan(
        String("t.parquet"),
        SOURCE_PARQUET,
        _t_schema(),
        projection=Optional(proj^),
        filter=filter^,
    )


def _scan_pk_v() -> LogicalPlan:
    return _scan(_l2("pk", "v"))


def _grouped() -> LogicalPlan:
    var gb = ExprArray()
    gb.append(Expr.col_ref("pk"))
    var aggs = AggExprArray()
    aggs.append(agg_sum(col("v")).alias("pv"))
    return LogicalPlan.aggregate(gb^, aggs^, _scan_pk_v())


def _total() -> LogicalPlan:
    var gb = ExprArray()
    var aggs = AggExprArray()
    aggs.append(agg_sum(col("v")).alias("tot"))
    return LogicalPlan.aggregate(gb^, aggs^, _scan(_l1("v")))


def _cross() -> LogicalPlan:
    return LogicalPlan.join(
        _grouped(), _total(), List[String](), List[String](), JOIN_CROSS
    )


def _project_cols(var names: List[String], var child: LogicalPlan) -> LogicalPlan:
    var exprs = ExprArray()
    for i in range(len(names)):
        exprs.append(Expr.col_ref(names[i]))
    return LogicalPlan.project(exprs^, child^)


def _sort(var child: LogicalPlan, key: String) -> LogicalPlan:
    var desc = List[Bool]()
    desc.append(True)
    var nf = List[Bool]()
    nf.append(True)
    return LogicalPlan.sort(_l1(key), desc^, child^, Optional(nf^))


def _topn(var child: LogicalPlan, key: String, n: Int) -> LogicalPlan:
    var desc = List[Bool]()
    desc.append(False)
    var nf = List[Bool]()
    nf.append(True)
    return LogicalPlan.topn(_l1(key), desc^, n, child^, Optional(nf^))


def _union_of(var a: LogicalPlan, var b: LogicalPlan) -> LogicalPlan:
    var schema = a.output_schema.copy()
    var kids = List[OwnedPointer[LogicalPlan]]()
    kids.append(OwnedPointer(a^))
    kids.append(OwnedPointer(b^))
    return LogicalPlan.union(kids^, schema^)


def _shared_source() raises -> InMemorySource:
    return InMemorySource.from_shared_batches(
        ArcPointer(Slab[RecordBatch].create(0)), _pk_v_schema()
    )


def _fp(plan: LogicalPlan) raises -> UInt64:
    return _relation_fingerprint(plan)


# -----------------------------------------------------------------------------
# fingerprint arms
# -----------------------------------------------------------------------------


def test_fingerprint_scan_ignores_projection_but_not_filter() raises:
    """Catches a scan arm that hashes the projection (q11 never folds) or one
    that drops the pushed-down filter (different rows fold together)."""
    assert_equal(_fp(_scan(_l1("v"))), _fp(_scan(_l2("pk", "v"))))
    var gt1 = Expr.binary(BIN_GT, Expr.col_ref("v"), _lit(1))
    assert_true(_fp(_scan(_l1("v"), Optional(gt1^))) != _fp(_scan(_l1("v"))))


def test_fingerprint_project_skips_pure_selects_only() raises:
    """Catches a Project arm that hashes bare col-refs (a pure select changes
    no row) or one that skips a computed expr (a derived column does)."""
    var a = _project_cols(_l1("pk"), _scan_pk_v())
    var b = _project_cols(_l1("v"), _scan_pk_v())
    assert_equal(_fp(a), _fp(b))
    var e1 = ExprArray()
    e1.append(Expr.alias(Expr.binary(BIN_ADD, Expr.col_ref("v"), _lit(1)), "x"))
    var e2 = ExprArray()
    e2.append(Expr.alias(Expr.binary(BIN_ADD, Expr.col_ref("v"), _lit(2)), "x"))
    var c = LogicalPlan.project(e1^, _scan_pk_v())
    var d = LogicalPlan.project(e2^, _scan_pk_v())
    assert_true(_fp(c) != _fp(d))


def test_fingerprint_filter_hashes_predicate_and_child() raises:
    """Catches a Filter arm that ignores its predicate."""
    var p1 = Expr.binary(BIN_GT, Expr.col_ref("v"), _lit(1))
    var p2 = Expr.binary(BIN_GT, Expr.col_ref("v"), _lit(2))
    var a = LogicalPlan.filter(p1^, _scan_pk_v())
    var b = LogicalPlan.filter(p2^, _scan_pk_v())
    assert_true(_fp(a) != _fp(b))


def test_fingerprint_join_hashes_type_keys_and_residual() raises:
    """Catches a Join arm that ignores the join type, the key lists, or the
    residual predicate (each changes the joined rows)."""
    var inner = LogicalPlan.join(
        _scan_pk_v(), _scan_pk_v(), _l1("pk"), _l1("pk"), JOIN_INNER
    )
    var left = LogicalPlan.join(
        _scan_pk_v(), _scan_pk_v(), _l1("pk"), _l1("pk"), JOIN_LEFT
    )
    var other_keys = LogicalPlan.join(
        _scan_pk_v(), _scan_pk_v(), _l1("v"), _l1("v"), JOIN_INNER
    )
    var other_right_key = LogicalPlan.join(
        _scan_pk_v(), _scan_pk_v(), _l1("pk"), _l1("v"), JOIN_INNER
    )
    var resid: Optional[OwnedPointer[Expr]] = OwnedPointer(
        Expr.binary(BIN_GT, Expr.col_ref("v"), _lit(3))
    )
    var with_resid = LogicalPlan.join(
        _scan_pk_v(), _scan_pk_v(), _l1("pk"), _l1("pk"), JOIN_INNER,
        JOIN_ALGO_HASH, resid^,
    )
    var base = _fp(inner)
    assert_true(base != _fp(left), "join type")
    assert_true(base != _fp(other_keys), "left keys")
    assert_true(base != _fp(other_right_key), "right keys")
    assert_true(base != _fp(with_resid), "residual")


def test_fingerprint_aggregate_hashes_group_by_and_aggs() raises:
    """Catches an Aggregate arm that ignores the group keys or the aggs."""
    var gb1 = ExprArray()
    gb1.append(Expr.col_ref("pk"))
    var a1 = AggExprArray()
    a1.append(agg_sum(col("v")).alias("s"))
    var by_pk = LogicalPlan.aggregate(gb1^, a1^, _scan_pk_v())
    var gb2 = ExprArray()
    gb2.append(Expr.col_ref("v"))
    var a2 = AggExprArray()
    a2.append(agg_sum(col("v")).alias("s"))
    var by_v = LogicalPlan.aggregate(gb2^, a2^, _scan_pk_v())
    var gb3 = ExprArray()
    gb3.append(Expr.col_ref("pk"))
    var a3 = AggExprArray()
    a3.append(agg_max(col("v")).alias("s"))
    var max_v = LogicalPlan.aggregate(gb3^, a3^, _scan_pk_v())
    assert_true(_fp(by_pk) != _fp(by_v), "group keys")
    assert_true(_fp(by_pk) != _fp(max_v), "aggregate functions")


def test_fingerprint_sort_limit_distinct_topn_recurse() raises:
    """Catches a wrapper arm that does not recurse into its child (two
    wrappers over differently-filtered scans would hash equal), a Sort arm
    that ignores its keys, and a Limit arm that ignores `n`."""
    var gt = Expr.binary(BIN_GT, Expr.col_ref("v"), _lit(1))
    assert_true(_fp(_sort(_scan_pk_v(), "pk")) != _fp(_sort(_scan_pk_v(), "v")))
    assert_true(
        _fp(_sort(_scan_pk_v(), "pk"))
        != _fp(_sort(_scan(_l2("pk", "v"), Optional(gt.copy())), "pk"))
    )
    assert_true(
        _fp(LogicalPlan.limit(5, _scan_pk_v()))
        != _fp(LogicalPlan.limit(6, _scan_pk_v()))
    )
    assert_true(
        _fp(LogicalPlan.limit(5, _scan_pk_v()))
        != _fp(LogicalPlan.limit(5, _scan(_l2("pk", "v"), Optional(gt.copy()))))
    )
    var none_cols: Optional[List[String]] = None
    var none_cols2: Optional[List[String]] = None
    assert_true(
        _fp(LogicalPlan.distinct(none_cols^, _scan_pk_v()))
        != _fp(
            LogicalPlan.distinct(
                none_cols2^, _scan(_l2("pk", "v"), Optional(gt.copy()))
            )
        )
    )
    assert_equal(
        _fp(_topn(_scan(_l1("v")), "v", 3)), _fp(_topn(_scan_pk_v(), "v", 3))
    )
    assert_true(
        _fp(_topn(_scan_pk_v(), "v", 3))
        != _fp(_topn(_scan(_l2("pk", "v"), Optional(gt.copy())), "v", 3))
    )


def test_fingerprint_fallback_hashes_the_subtree() raises:
    """An un-handled kind (a Union) folds in the plan's `structural_hash`.
    Catches a fallback that returns the bare tag hash: every Union would
    fingerprint equal, so two Unions over different rows would fold."""
    var gt = Expr.binary(BIN_GT, Expr.col_ref("v"), _lit(4))
    var u1 = _union_of(_scan_pk_v(), _scan_pk_v())
    var u2 = _union_of(
        _scan(_l2("pk", "v"), Optional(gt.copy())),
        _scan(_l2("pk", "v"), Optional(gt.copy())),
    )
    assert_true(_fp(u1) != _fp(u2))
    var u3 = _union_of(_scan_pk_v(), _scan_pk_v())
    assert_equal(_fp(u1), _fp(u3), "the fallback is deterministic")


# -----------------------------------------------------------------------------
# _extract_agg_relation
# -----------------------------------------------------------------------------


def _extracted_is_scan(plan: LogicalPlan) raises -> Bool:
    var rel = _extract_agg_relation(plan)
    if not rel:
        return False
    return rel.value().tag == PLAN_SCAN


def test_extract_looks_through_every_single_child_wrapper() raises:
    """Catches a wrapper arm that stops early (the detector then never sees a
    q11 branch wrapped by that node kind)."""
    assert_true(_extracted_is_scan(_grouped()), "aggregate")
    assert_true(_extracted_is_scan(_project_cols(_l1("pv"), _grouped())), "project")
    var p = Expr.binary(BIN_GT, Expr.col_ref("pv"), _lit(0))
    assert_true(_extracted_is_scan(LogicalPlan.filter(p^, _grouped())), "filter")
    assert_true(_extracted_is_scan(_sort(_grouped(), "pk")), "sort")
    assert_true(_extracted_is_scan(LogicalPlan.limit(3, _grouped())), "limit")
    var nc: Optional[List[String]] = None
    assert_true(_extracted_is_scan(LogicalPlan.distinct(nc^, _grouped())), "distinct")
    assert_true(_extracted_is_scan(_topn(_grouped(), "pk", 2)), "topn")
    assert_false(Bool(_extract_agg_relation(_scan_pk_v())), "no aggregate: None")


# -----------------------------------------------------------------------------
# detect: declines and the recursion over every node kind
# -----------------------------------------------------------------------------


def test_detect_declines_when_a_branch_has_no_aggregate() raises:
    """Catches a detector that dereferences a missing relation on either side."""
    var l_scan = LogicalPlan.join(
        _scan_pk_v(), _total(), List[String](), List[String](), JOIN_CROSS
    )
    assert_false(Bool(detect_shared_cross_canonical(l_scan)))
    var r_scan = LogicalPlan.join(
        _grouped(), _scan_pk_v(), List[String](), List[String](), JOIN_CROSS
    )
    assert_false(Bool(detect_shared_cross_canonical(r_scan)))


def test_detect_declines_when_neither_side_is_a_superset() raises:
    """[pk, v] against [v, w]: same relation, but no one batch serves both.
    Catches a detector that materializes a side lacking a needed column."""
    var gb = ExprArray()
    var aggs = AggExprArray()
    aggs.append(agg_sum(col("w")).alias("tw"))
    var right = LogicalPlan.aggregate(gb^, aggs^, _scan(_l2("v", "w")))
    var plan = LogicalPlan.join(
        _grouped(), right^, List[String](), List[String](), JOIN_CROSS
    )
    assert_false(Bool(detect_shared_cross_canonical(plan)))


def _found(plan: LogicalPlan) raises -> Bool:
    return Bool(detect_shared_cross_canonical(plan))


def test_detect_recurses_through_every_node_kind() raises:
    """Catches a recursion arm that is missing or descends the wrong child:
    the q11 CROSS is buried under each node kind in turn."""
    assert_true(_found(_project_cols(_l2("pk", "pv"), _cross())), "project")
    var gb = ExprArray()
    gb.append(Expr.col_ref("pk"))
    var aggs = AggExprArray()
    aggs.append(agg_sum(col("pv")).alias("s"))
    assert_true(_found(LogicalPlan.aggregate(gb^, aggs^, _cross())), "aggregate")
    var in_left = LogicalPlan.join(
        _cross(), _scan_pk_v(), _l1("pk"), _l1("pk"), JOIN_INNER
    )
    assert_true(_found(in_left), "join, left child")
    var in_right = LogicalPlan.join(
        _scan_pk_v(), _cross(), _l1("pk"), _l1("pk"), JOIN_INNER
    )
    assert_true(_found(in_right), "join, right child")
    assert_true(_found(_sort(_cross(), "pk")), "sort")
    assert_true(_found(LogicalPlan.limit(4, _cross())), "limit")
    var nc: Optional[List[String]] = None
    assert_true(_found(LogicalPlan.distinct(nc^, _cross())), "distinct")
    assert_true(_found(_topn(_cross(), "pk", 4)), "topn")
    var asof_l = LogicalPlan.asof_join(
        _cross(), _scan_pk_v(), List[String](), List[String](),
        String("pk"), String("pk"), ASOF_BACKWARD, AsofTolerance.none(),
    )
    assert_true(_found(asof_l), "asof join, left child")
    var asof_r = LogicalPlan.asof_join(
        _scan_pk_v(), _cross(), List[String](), List[String](),
        String("pk"), String("pk"), ASOF_BACKWARD, AsofTolerance.none(),
    )
    assert_true(_found(asof_r), "asof join, right child")
    assert_true(_found(_union_of(_scan_pk_v(), _cross())), "union, second child")
    assert_false(_found(_union_of(_scan_pk_v(), _scan_pk_v())), "union, no CROSS")
    assert_false(_found(_scan_pk_v()), "scan leaf")


# -----------------------------------------------------------------------------
# install_shared_cross_source
# -----------------------------------------------------------------------------


def _is_shared_leaf(plan: LogicalPlan) -> Bool:
    return (
        plan.tag == PLAN_SCAN
        and plan._scan.value()[].source.tag == SOURCE_VARIANT_IN_MEMORY
        and plan.output_schema.num_columns() == 2
    )


def _install(var plan: LogicalPlan) raises -> LogicalPlan:
    var target = _fp(_scan_pk_v())
    return install_shared_cross_source(
        plan^, target, _shared_source(), _pk_v_schema()
    )


def test_install_replaces_both_q11_relations() raises:
    """Filter(CROSS(Aggregate, Project(Aggregate))): both aggregate children
    become the shared in-memory leaf. Catches an install that stops at the
    first match, skips the Project or Filter arm, or drops the join keys."""
    var pred = Expr.binary(BIN_GT, Expr.col_ref("pv"), Expr.col_ref("tot"))
    var join = LogicalPlan.join(
        _grouped(),
        _project_cols(_l1("tot"), _total()),
        List[String](),
        List[String](),
        JOIN_CROSS,
    )
    var out = _install(LogicalPlan.filter(pred^, join^))
    assert_equal(Int(out.tag), Int(PLAN_FILTER))
    ref j = out._filter.value()[].child[]
    assert_equal(Int(j.tag), Int(PLAN_JOIN))
    assert_equal(Int(j._join.value()[].join_type), Int(JOIN_CROSS))
    ref l = j._join.value()[].left[]
    assert_equal(Int(l.tag), Int(PLAN_AGGREGATE))
    assert_true(_is_shared_leaf(l._aggregate.value()[].child[]), "left leaf")
    ref r = j._join.value()[].right[]
    assert_equal(Int(r.tag), Int(PLAN_PROJECT))
    ref ra = r._project.value()[].child[]
    assert_true(_is_shared_leaf(ra._aggregate.value()[].child[]), "right leaf")
    assert_equal(ra.output_schema.field_name(0), String("tot"))


def test_install_leaves_a_non_matching_relation_alone() raises:
    """An aggregate over a filtered scan does not fingerprint equal to the
    target. Catches an install that replaces every aggregate child."""
    var gt = Expr.binary(BIN_GT, Expr.col_ref("v"), _lit(9))
    var gb = ExprArray()
    var aggs = AggExprArray()
    aggs.append(agg_sum(col("v")).alias("s"))
    var p = Expr.binary(BIN_EQ, Expr.col_ref("pk"), _lit(1))
    var child = LogicalPlan.filter(p^, _scan(_l2("pk", "v"), Optional(gt^)))
    var out = _install(LogicalPlan.aggregate(gb^, aggs^, child^))
    ref c = out._aggregate.value()[].child[]
    assert_equal(Int(c.tag), Int(PLAN_FILTER))
    ref leaf = c._filter.value()[].child[]
    assert_equal(Int(leaf._scan.value()[].source.tag), Int(SOURCE_VARIANT_PARQUET))


def test_install_rebuilds_every_wrapper_with_its_fields() raises:
    """Catches a rebuild that loses a wrapper's own fields: sort NULL
    placement, limit offset, distinct columns, TopN n, join residual and
    algorithm hint."""
    var s = _install(_sort(_grouped(), "pk"))
    assert_equal(Int(s.tag), Int(PLAN_SORT))
    assert_true(s._sort.value()[].nulls_first[0], "sort keeps NULLS FIRST")
    assert_true(s._sort.value()[].descending[0], "sort keeps DESC")
    assert_true(_is_shared_leaf(s._sort.value()[].child[]._aggregate.value()[].child[]))

    var l = _install(LogicalPlan.limit(7, _grouped(), offset=2))
    assert_equal(Int(l.tag), Int(PLAN_LIMIT))
    assert_equal(l._limit.value()[].n, 7)
    assert_equal(l._limit.value()[].offset, 2)
    assert_true(_is_shared_leaf(l._limit.value()[].child[]._aggregate.value()[].child[]))

    var d = _install(LogicalPlan.distinct(Optional(_l1("pk")), _grouped()))
    assert_equal(Int(d.tag), Int(PLAN_DISTINCT))
    assert_equal(d._distinct.value()[].columns.value()[0], String("pk"))
    var nc: Optional[List[String]] = None
    var d2 = _install(LogicalPlan.distinct(nc^, _grouped()))
    assert_false(Bool(d2._distinct.value()[].columns), "no columns stays None")

    var t = _install(_topn(_grouped(), "pk", 5))
    assert_equal(Int(t.tag), Int(PLAN_TOPN))
    assert_equal(t._topn.value()[].n, 5)
    assert_true(t._topn.value()[].nulls_first[0], "topn keeps NULLS FIRST")
    assert_true(_is_shared_leaf(t._topn.value()[].child[]._aggregate.value()[].child[]))

    var resid: Optional[OwnedPointer[Expr]] = OwnedPointer(
        Expr.binary(BIN_GT, Expr.col_ref("pv"), _lit(0))
    )
    var j = _install(
        LogicalPlan.join(
            _grouped(), _scan_pk_v(), _l1("pk"), _l1("pk"), JOIN_INNER,
            JOIN_ALGO_HASH, resid^,
        )
    )
    ref jd = j._join.value()[]
    assert_true(jd.has_residual(), "join keeps its residual")
    assert_equal(Int(jd.algo_hint), Int(JOIN_ALGO_HASH))
    assert_equal(jd.left_on[0], String("pk"))
    assert_true(_is_shared_leaf(jd.left[]._aggregate.value()[].child[]))
    # A bare scan is a leaf the install does not touch, even when it matches.
    assert_equal(Int(jd.right[].tag), Int(PLAN_SCAN))
    assert_equal(
        Int(jd.right[]._scan.value()[].source.tag), Int(SOURCE_VARIANT_PARQUET)
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
