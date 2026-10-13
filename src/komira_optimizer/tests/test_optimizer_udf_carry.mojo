"""UDF-carrying nodes through every optimizer rule outside
`optimizer_projection` that rebuilds a Filter, Project or Aggregate, splits or
deletes one, or decides what one reads (komira#1462, the boundary sweep).

A typed UDF rides on a Filter, Project or Aggregate as a `UdfData` payload; the
node's own expressions are placeholders. `LogicalPlan.filter`, `.project` and
`.aggregate` build a node with no UDF, so a rule that rebuilds a node with
them deletes the customer's function. `UdfData.input_columns` are the
columns the UDF reads, which the placeholders do not name.

Each test names the rule site it pins and the defect it catches. The last
group runs whole plans through `optimize()`.
"""

from std.collections import Set
from std.memory import OwnedPointer, ArcPointer
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.schema import SchemaBuilder, Field, Schema
from komira_arrow.record_batch import RecordBatch
from komira_arrow.arrow_types import ArrowType
from komira_collections.slab import Slab
from komira_plan_expr.expr import Expr, BIN_ADD, BIN_GT, BIN_LE
from komira_plan_expr.agg_expr import AggExpr, AGG_SUM, AGG_MAX
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_expr.partition_expr import PartitionExpr
from komira_plan_expr.udf_data import (
    UdfData,
    UDF_KIND_MAP,
    UDF_KIND_FILTER,
    UDF_KIND_AGG,
)
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    PLAN_SCAN,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_AGGREGATE,
    PLAN_JOIN,
    PLAN_LIMIT,
    PLAN_PARTITION_BY,
    PLAN_PARTITION_TOPN,
    SOURCE_PARQUET,
    JOIN_INNER,
)
from komira_scan_source.in_memory_source import InMemorySource

from komira_optimizer.optimizer_udf_carry import (
    filter_like,
    project_like,
    aggregate_like,
)
from komira_optimizer.optimizer_window_rewrite import optimize_window_rewrite
from komira_optimizer.optimizer_misc import push_limit_down
from komira_optimizer.optimizer_eager_agg import eager_aggregate_pushdown
from komira_optimizer.optimizer_partial_agg import (
    push_aggregate_below_join,
    push_aggregate_below_join_force,
)
from komira_optimizer.optimizer_agg_cse import replace_agg_subtree_with_source
from komira_optimizer.optimizer_shared_relation_cse import (
    install_shared_cross_source,
    _relation_fingerprint,
)
from komira_optimizer.resolve_scalar_subqueries import _rewrite_scalar_subquery_sites
from komira_optimizer.optimizer_scalar_broadcast import (
    ScalarBroadcastSite,
    _rewrite_scalar_broadcast_sites,
)
from komira_optimizer.optimizer_filter import push_predicates_down, fuse_filters
from komira_optimizer.flatten_dependent_joins import _hoist_outer_eq_predicates
from komira_optimizer.optimizer_expr import eliminate_common_subexpressions
from komira_optimizer.optimizer_join import (
    absorb_expression_into_aggregate,
    convert_inner_to_semi,
)
from komira_optimizer.optimizer_materialize_agg_input import materialize_agg_input
from komira_optimizer.optimizer_partition_topn import fuse_partition_topn
from komira_optimizer.optimizer_config import OptimizerConfig
from komira_optimizer.optimizer_scalar_deps import ScalarDepTable
from komira_optimizer.optimizer_driver import optimize


# =============================================================================
# Fixtures
# =============================================================================


def _schema(csv: String) raises -> Schema:
    var sb = SchemaBuilder()
    for part in csv.split(","):
        sb.add_field(Field(String(part), ArrowType.INT64, nullable=False))
    return sb.build()


def _scan(csv: String, path: String = "t.parquet") raises -> LogicalPlan:
    return LogicalPlan.scan(path, SOURCE_PARQUET, _schema(csv))


def _cols(*names: String) -> ExprArray:
    var e = ExprArray()
    for n in names:
        e.append(Expr.col_ref(n))
    return e^


def _keys(*names: String) -> List[String]:
    var out = List[String]()
    for n in names:
        out.append(String(n))
    return out^


def _udf(kind: UInt8, *reads: String) -> OwnedPointer[UdfData]:
    var ic = List[Tuple[String, UInt8]]()
    for r in reads:
        ic.append((String(r), UInt8(2)))
    var oc = List[Tuple[String, UInt8]]()
    oc.append(("y", UInt8(2)))
    return OwnedPointer(
        UdfData(
            kind=kind,
            name=String("f"),
            input_columns=ic^,
            output_columns=oc^,
            operator_factory_id=UInt32(7102),
            call_site_salt=UInt32(5),
            registered_handle_id=Optional(Int(6)),
        )
    )


def _udf_one(kind: UInt8, col: String) -> OwnedPointer[UdfData]:
    """A UDF reading the one column `col`. A caller that holds the column
    name in a variable uses this, not `_udf`."""
    var ic = List[Tuple[String, UInt8]]()
    ic.append((col.copy(), UInt8(2)))
    var oc = List[Tuple[String, UInt8]]()
    oc.append(("y", UInt8(2)))
    return OwnedPointer(
        UdfData(
            kind=kind,
            name=String("f"),
            input_columns=ic^,
            output_columns=oc^,
            operator_factory_id=UInt32(7102),
            call_site_salt=UInt32(5),
            registered_handle_id=Optional(Int(6)),
        )
    )


def _true() -> Expr:
    return Expr.literal(ScalarValue.from_bool(True))


def _gt(col: String, v: Int) -> Expr:
    return Expr.binary(BIN_GT, Expr.col_ref(col), Expr.literal(ScalarValue.from_int(v)))


def _udf_filter(var child: LogicalPlan, reads: String) -> LogicalPlan:
    """Filter[udf reads `reads`](lit(true)) over `child`."""
    return LogicalPlan.filter_with_udf(_true(), child^, _udf_one(UDF_KIND_FILTER, reads))


def _sum(col: String, name: String) -> AggExpr:
    return AggExpr(AGG_SUM, Optional[Expr](Expr.col_ref(col)), Optional[String](name))


def _aggs1(col: String, name: String) -> AggExprArray:
    var a = AggExprArray()
    a.append(_sum(col, name))
    return a^


def _count_udfs(plan: LogicalPlan) raises -> Int:
    """UDF-carrying nodes anywhere in a tree of the node kinds these tests
    build."""
    var n = 1 if plan.has_udf() else 0
    if plan.tag == PLAN_FILTER:
        n += _count_udfs(plan._filter.value()[].child[])
    elif plan.tag == PLAN_PROJECT:
        n += _count_udfs(plan._project.value()[].child[])
    elif plan.tag == PLAN_AGGREGATE:
        n += _count_udfs(plan._aggregate.value()[].child[])
    elif plan.tag == PLAN_JOIN:
        n += _count_udfs(plan._join.value()[].left[])
        n += _count_udfs(plan._join.value()[].right[])
    elif plan.tag == PLAN_LIMIT:
        n += _count_udfs(plan._limit.value()[].child[])
    elif plan.tag == PLAN_PARTITION_BY:
        n += _count_udfs(plan._partition_by.value()[].child[])
    elif plan.tag == PLAN_PARTITION_TOPN:
        n += _count_udfs(plan._partition_topn.value()[].child[])
    return n


def _shared_source() raises -> InMemorySource:
    return InMemorySource.from_shared_batches(
        ArcPointer(Slab[RecordBatch].create(0)), _schema("k,v")
    )


comptime _F = 0
comptime _P = 1
comptime _A = 2


def _udf_node(which: Int) raises -> LogicalPlan:
    """One UDF node over Scan(k,v): Filter[udf](lit(true)) for `_F`,
    Project[udf](k, v) for `_P`, Aggregate[udf](k; sum v) for `_A`."""
    if which == _F:
        return _udf_filter(_scan("k,v"), "v")
    if which == _P:
        return LogicalPlan.project_with_udf(_cols("k", "v"), _scan("k,v"), _udf(UDF_KIND_MAP, "v"))
    return LogicalPlan.aggregate_with_udf(_cols("k"), _aggs1("v", "s"), _scan("k,v"), _udf(UDF_KIND_AGG, "v"))


# =============================================================================
# The rebuild helpers
# =============================================================================


def test_rebuild_helpers_carry_the_payload() raises:
    """`filter_like`, `project_like` and `aggregate_like` rebuild a node with
    the UDF of the node they replace; a source with no UDF gives a node with
    none.

    Catches: a helper that drops the UDF, or invents one."""
    var f = _udf_filter(_scan("k,v"), "v")
    assert_true(filter_like(f._filter.value()[], _true(), _scan("k,v")).has_udf())
    var p = LogicalPlan.project_with_udf(_cols("k"), _scan("k,v"), _udf(UDF_KIND_MAP, "v"))
    assert_true(project_like(p._project.value()[], _cols("k"), _scan("k,v")).has_udf())
    var a = LogicalPlan.aggregate_with_udf(_cols("k"), AggExprArray(), _scan("k,v"), _udf(UDF_KIND_AGG, "v"))
    assert_true(aggregate_like(a._aggregate.value()[], _cols("k"), AggExprArray(), _scan("k,v")).has_udf())
    var plain_p = LogicalPlan.project(_cols("k"), _scan("k,v"))
    assert_false(project_like(plain_p._project.value()[], _cols("k"), _scan("k,v")).has_udf())
    var plain = LogicalPlan.filter(_true(), _scan("k,v"))
    assert_false(filter_like(plain._filter.value()[], _true(), _scan("k,v")).has_udf())


# =============================================================================
# Structural walks that rebuild every node they pass
# =============================================================================


def test_window_rewrite_keeps_a_udf_filter() raises:
    """optimize_window_rewrite._recurse_into_children, Filter arm.
    Catches: the arm rebuilding with `LogicalPlan.filter`."""
    var out = optimize_window_rewrite(_udf_filter(_scan("k,v"), "v"))
    assert_equal(_count_udfs(out), 1, "window_rewrite dropped the Filter's UDF")


def test_window_rewrite_keeps_a_udf_project() raises:
    """optimize_window_rewrite._recurse_into_children, Project arm.
    Catches: the arm rebuilding with `LogicalPlan.project`."""
    var plan = LogicalPlan.project_with_udf(_cols("k"), _scan("k,v"), _udf(UDF_KIND_MAP, "v"))
    var out = optimize_window_rewrite(plan^)
    assert_equal(_count_udfs(out), 1, "window_rewrite dropped the Project's UDF")


def _eager(which: Int) raises -> Int:
    return _count_udfs(eager_aggregate_pushdown(_udf_node(which)))


def test_eager_walk_keeps_a_udf_filter() raises:
    """optimizer_eager_agg._eager_rec, Filter arm. Catches: the rebuild with
    `LogicalPlan.filter`."""
    assert_equal(_eager(_F), 1)


def test_eager_walk_keeps_a_udf_project() raises:
    """optimizer_eager_agg._eager_rec, Project arm."""
    assert_equal(_eager(_P), 1)


def test_eager_walk_keeps_a_udf_aggregate() raises:
    """optimizer_eager_agg._eager_rec, the Aggregate fall-through rebuild."""
    assert_equal(_eager(_A), 1)


def _partial(which: Int, force: Bool) raises -> Int:
    if force:
        return _count_udfs(push_aggregate_below_join_force(_udf_node(which)))
    return _count_udfs(push_aggregate_below_join(_udf_node(which)))


def test_partial_agg_walk_keeps_a_udf_filter() raises:
    """optimizer_partial_agg.push_aggregate_below_join, Filter arm. Catches:
    the rebuild with `LogicalPlan.filter`."""
    assert_equal(_partial(_F, False), 1)


def test_partial_agg_walk_keeps_a_udf_project() raises:
    """push_aggregate_below_join, Project arm."""
    assert_equal(_partial(_P, False), 1)


def test_partial_agg_walk_keeps_a_udf_aggregate() raises:
    """push_aggregate_below_join, the Aggregate fall-through rebuild."""
    assert_equal(_partial(_A, False), 1)


def test_force_partial_agg_walk_keeps_a_udf_filter() raises:
    """push_aggregate_below_join_force, Filter arm."""
    assert_equal(_partial(_F, True), 1)


def test_force_partial_agg_walk_keeps_a_udf_project() raises:
    """push_aggregate_below_join_force, Project arm."""
    assert_equal(_partial(_P, True), 1)


def test_force_partial_agg_walk_keeps_a_udf_aggregate() raises:
    """push_aggregate_below_join_force, the Aggregate fall-through rebuild."""
    assert_equal(_partial(_A, True), 1)


def _replace(which: Int) raises -> Int:
    """optimizer_agg_cse.replace_agg_subtree_with_source with a target no
    subtree matches: the walk rebuilds every node it passes."""
    return _count_udfs(replace_agg_subtree_with_source(_udf_node(which), UInt64(1), _shared_source()))


def test_agg_cse_replace_walk_keeps_a_udf_filter() raises:
    """replace_agg_subtree_with_source, Filter arm. Catches: the rebuild with
    `LogicalPlan.filter`."""
    assert_equal(_replace(_F), 1)


def test_agg_cse_replace_walk_keeps_a_udf_project() raises:
    """replace_agg_subtree_with_source, Project arm."""
    assert_equal(_replace(_P), 1)


def test_agg_cse_replace_walk_keeps_a_udf_aggregate() raises:
    """replace_agg_subtree_with_source, Aggregate arm."""
    assert_equal(_replace(_A), 1)


def _install(which: Int) raises -> Int:
    """optimizer_shared_relation_cse.install_shared_cross_source with a
    target no relation matches."""
    return _count_udfs(
        install_shared_cross_source(_udf_node(which), UInt64(1), _shared_source(), _schema("k,v"))
    )


def test_shared_relation_install_walk_keeps_a_udf_filter() raises:
    """install_shared_cross_source, Filter arm. Catches: the rebuild with
    `LogicalPlan.filter`."""
    assert_equal(_install(_F), 1)


def test_shared_relation_install_walk_keeps_a_udf_project() raises:
    """install_shared_cross_source, Project arm."""
    assert_equal(_install(_P), 1)


def test_shared_relation_install_walk_keeps_a_udf_aggregate() raises:
    """install_shared_cross_source, the Aggregate recursion rebuild."""
    assert_equal(_install(_A), 1)


def test_shared_relation_leaf_install_keeps_the_aggregate_udf() raises:
    """install_shared_cross_source, the Aggregate whose child matches the
    target: the leaf is installed and the Aggregate keeps its UDF. Catches:
    the leaf rebuild with `LogicalPlan.aggregate`."""
    var plan = _udf_node(_A)
    var target = _relation_fingerprint(plan._aggregate.value()[].child[])
    var hit = install_shared_cross_source(plan^, target, _shared_source(), _schema("k,v"))
    assert_true(
        hit._aggregate.value()[].child[]._scan.value()[].source_path != "t.parquet",
        "VACUOUS: no leaf installed",
    )
    assert_true(hit.has_udf(), "the leaf install dropped the Aggregate's UDF")


def _subq(which: Int) raises -> Int:
    var next_idx = 0
    return _count_udfs(_rewrite_scalar_subquery_sites(_udf_node(which), List[ScalarValue](), next_idx))


def test_scalar_subquery_rewrite_walk_keeps_a_udf_filter() raises:
    """resolve_scalar_subqueries._rewrite_scalar_subquery_sites, Filter arm.
    Catches: the rebuild with `LogicalPlan.filter`."""
    assert_equal(_subq(_F), 1)


def test_scalar_subquery_rewrite_walk_keeps_a_udf_project() raises:
    """_rewrite_scalar_subquery_sites, Project arm."""
    assert_equal(_subq(_P), 1)


def _broadcast(var plan: LogicalPlan) raises -> Int:
    var sites = Slab[ScalarBroadcastSite]()
    var next_idx = 0
    var out = _rewrite_scalar_broadcast_sites(
        plan^, sites, List[ScalarValue](), List[String](), Slab[Schema](),
        Slab[InMemorySource](), next_idx,
    )
    return _count_udfs(out)


def test_scalar_broadcast_walk_keeps_a_udf_filter_over_an_aggregate() raises:
    """optimizer_scalar_broadcast._rewrite_scalar_broadcast_sites, the
    Filter-over-Aggregate arm with no aggregate function in the predicate.
    Catches: the rebuild with `LogicalPlan.filter`."""
    assert_equal(_broadcast(_udf_filter(_udf_node(_A), "s")), 2)


def test_scalar_broadcast_walk_keeps_a_udf_filter() raises:
    """_rewrite_scalar_broadcast_sites, the plain Filter arm."""
    assert_equal(_broadcast(_udf_node(_F)), 1)


# =============================================================================
# Rules that move, split, fuse or delete a node
# =============================================================================


def test_limit_stays_above_a_udf_project() raises:
    """push_limit_down: Limit(3) over Project[udf](k) over Scan stays as it
    is. Catches: the Limit pushed below the UDF Project (the UDF then sees
    three rows, not every row)."""
    var p = LogicalPlan.project_with_udf(_cols("k"), _scan("k,v"), _udf(UDF_KIND_MAP, "v"))
    var out = push_limit_down(LogicalPlan.limit(3, p^))
    assert_equal(out.tag, PLAN_LIMIT, "the Limit moved below a UDF Project")
    assert_equal(_count_udfs(out), 1)


def _fact_dim_join() raises -> LogicalPlan:
    return LogicalPlan.join(
        _scan("fk_id,measure", "fact.parquet"),
        _scan("dim_id,dim_attr", "dim.parquet"),
        _keys("fk_id"),
        _keys("dim_id"),
        JOIN_INNER,
    )


def test_eager_does_not_split_a_udf_aggregate() raises:
    """optimizer_eager_agg._classify_eager_push: a UDF Aggregate(dim_attr;
    sum measure) over a fireable fact JOIN dim is left whole. Catches: the
    classifier firing, which rebuilds the Aggregate as partial and merge
    aggregates without the UDF."""
    var plan = LogicalPlan.aggregate_with_udf(
        _cols("dim_attr"), _aggs1("measure", "total"), _fact_dim_join(), _udf(UDF_KIND_AGG, "measure")
    )
    var out = eager_aggregate_pushdown(plan^)
    assert_equal(_count_udfs(out), 1, "eager pushdown split the UDF Aggregate")
    ref j = out._aggregate.value()[].child[]
    assert_equal(j.tag, PLAN_JOIN)
    assert_equal(j._join.value()[].left[].tag, PLAN_SCAN)


def test_eager_does_not_peel_a_udf_project() raises:
    """optimizer_eager_agg._is_pure_narrowing_project: Aggregate over
    Project[udf](fk_id, measure, dim_attr) over the fireable join keeps the
    Project. Catches: the col-ref placeholders read as a narrowing Project and
    peeled away with the UDF."""
    var p = LogicalPlan.project_with_udf(
        _cols("fk_id", "measure", "dim_attr"), _fact_dim_join(), _udf(UDF_KIND_MAP, "measure")
    )
    var plan = LogicalPlan.aggregate(_cols("dim_attr"), _aggs1("measure", "total"), p^)
    var out = eager_aggregate_pushdown(plan^)
    assert_equal(_count_udfs(out), 1, "eager pushdown peeled the UDF Project")
    assert_equal(out._aggregate.value()[].child[].tag, PLAN_PROJECT)


def test_force_partial_agg_does_not_split_a_udf_aggregate() raises:
    """optimizer_partial_agg._classify_push_unchecked: a UDF
    Aggregate(customer_id; sum price) over orders JOIN customers is left
    whole. Catches: the classifier firing and rebuilding the Aggregate
    without the UDF."""
    var join = LogicalPlan.join(
        _scan("order_id,customer_id,price", "orders.parquet"),
        _scan("customer_id,country", "customers.parquet"),
        _keys("customer_id"),
        _keys("customer_id"),
        JOIN_INNER,
    )
    var plan = LogicalPlan.aggregate_with_udf(
        _cols("customer_id"), _aggs1("price", "total"), join^, _udf(UDF_KIND_AGG, "price")
    )
    var out = push_aggregate_below_join_force(plan^)
    assert_equal(_count_udfs(out), 1, "the force rewrite split the UDF Aggregate")
    assert_equal(out._aggregate.value()[].child[]._join.value()[].left[].tag, PLAN_SCAN)


def test_predicate_stays_above_a_udf_filter() raises:
    """push_predicates_down, the Filter-over-Filter arm: Filter(k > 1) over
    Filter[udf](lit(true)) over Scan keeps both nodes and the UDF. Catches:
    the trial swap rebuilding the inner Filter with the non-UDF factory."""
    var plan = LogicalPlan.filter(_gt("k", 1), _udf_filter(_scan("k,v"), "v"))
    var out = push_predicates_down(plan^)
    assert_equal(_count_udfs(out), 1, "pushdown dropped the inner Filter's UDF")
    assert_false(out.has_udf(), "the plain predicate moved below the UDF Filter")


def test_plain_filter_over_a_udf_filter_is_not_fused() raises:
    """fuse_filters: Filter(k > 1) over Filter[udf] over Scan keeps two
    nodes. Catches: fusion deleting the inner UDF Filter."""
    var plan = LogicalPlan.filter(_gt("k", 1), _udf_filter(_scan("k,v"), "v"))
    var out = fuse_filters(plan^)
    assert_equal(_count_udfs(out), 1, "fusion deleted the inner UDF Filter")
    assert_equal(out._filter.value()[].child[].tag, PLAN_FILTER)


def test_udf_filter_over_a_plain_filter_is_not_fused() raises:
    """fuse_filters: Filter[udf] over Filter(k > 1) over Scan keeps two
    nodes. Catches: fusion moving `k > 1` into the UDF Filter's placeholder
    predicate, where the UDF path does not evaluate it."""
    var plan = _udf_filter(LogicalPlan.filter(_gt("k", 1), _scan("k,v")), "v")
    var out = fuse_filters(plan^)
    assert_true(out.has_udf())
    assert_equal(out._filter.value()[].child[].tag, PLAN_FILTER, "fusion folded a Filter into the UDF Filter")


def test_hoist_leaves_a_udf_inner_filter_whole() raises:
    """flatten_dependent_joins._hoist_outer_eq_predicates: a correlated
    inner plan topped by Filter[udf](lit(true)) comes back with its UDF.
    Catches: the placeholder split into conjuncts and the Filter rebuilt with
    the non-UDF factory."""
    var left_on = List[String]()
    var right_on = List[String]()
    var residual = ExprArray()
    var out = _hoist_outer_eq_predicates(
        _udf_filter(_scan("k,v"), "v"), _keys("k"), left_on, right_on, residual
    )
    assert_equal(_count_udfs(out), 1, "the hoist dropped the inner Filter's UDF")
    assert_equal(left_on[0], "k", "the default keys were not used")


def test_cse_leaves_a_udf_aggregate_alone() raises:
    """eliminate_common_subexpressions, Axis 3: a UDF Aggregate with
    sum(a + b) and max(a + b) keeps its UDF and gets no synthetic Project.
    Catches: the Axis 3 rebuild with `LogicalPlan.aggregate`."""
    var aggs = AggExprArray()
    var ab = Expr.binary(BIN_ADD, Expr.col_ref("a"), Expr.col_ref("b"))
    aggs.append(AggExpr(AGG_SUM, Optional[Expr](ab.copy()), Optional[String](String("s"))))
    aggs.append(AggExpr(AGG_MAX, Optional[Expr](ab^), Optional[String](String("m"))))
    var plan = LogicalPlan.aggregate_with_udf(ExprArray(), aggs^, _scan("a,b,c"), _udf(UDF_KIND_AGG, "c"))
    var out = eliminate_common_subexpressions(plan^)
    assert_equal(_count_udfs(out), 1, "CSE dropped the Aggregate's UDF")
    assert_equal(out._aggregate.value()[].child[].tag, PLAN_SCAN)


def test_cse_axis3_still_fires_on_a_plain_aggregate() raises:
    """The same aggregate with no UDF gets the synthetic Project. Proves the
    test above is not vacuous: Axis 3 fires on this shape."""
    var aggs = AggExprArray()
    var ab = Expr.binary(BIN_ADD, Expr.col_ref("a"), Expr.col_ref("b"))
    aggs.append(AggExpr(AGG_SUM, Optional[Expr](ab.copy()), Optional[String](String("s"))))
    aggs.append(AggExpr(AGG_MAX, Optional[Expr](ab^), Optional[String](String("m"))))
    var out = eliminate_common_subexpressions(LogicalPlan.aggregate(ExprArray(), aggs^, _scan("a,b,c")))
    assert_equal(out._aggregate.value()[].child[].tag, PLAN_PROJECT)


def test_absorb_keeps_a_udf_project_below_an_aggregate() raises:
    """absorb_expression_into_aggregate: Aggregate(sum a) over Project[udf](a,
    b) over Scan keeps the Project. Catches: the absorb deleting the UDF
    Project."""
    var p = LogicalPlan.project_with_udf(_cols("a", "b"), _scan("a,b,c"), _udf(UDF_KIND_MAP, "c"))
    var out = absorb_expression_into_aggregate(LogicalPlan.aggregate(ExprArray(), _aggs1("a", "s"), p^))
    assert_equal(_count_udfs(out), 1, "absorb deleted the UDF Project")


def test_absorb_keeps_the_project_a_udf_aggregate_reads() raises:
    """absorb_expression_into_aggregate: Aggregate[udf reads s](sum a) over
    Project(a, a + b AS s) over Scan keeps the Project. Catches: the absorb
    deleting the Project that computes the UDF's input column `s`."""
    var exprs = _cols("a")
    exprs.append(Expr.alias(Expr.binary(BIN_ADD, Expr.col_ref("a"), Expr.col_ref("b")), "s"))
    var p = LogicalPlan.project(exprs^, _scan("a,b"))
    var plan = LogicalPlan.aggregate_with_udf(ExprArray(), _aggs1("a", "t"), p^, _udf(UDF_KIND_AGG, "s"))
    var out = absorb_expression_into_aggregate(plan^)
    assert_equal(out._aggregate.value()[].child[].tag, PLAN_PROJECT, "absorb deleted the Project the UDF reads")


# =============================================================================
# Rules that decide what a node reads
# =============================================================================


def test_materialized_agg_input_keeps_the_udf_read_columns() raises:
    """materialize_agg_input: Aggregate[udf reads c](a; sum(a + b)) over
    Scan(a,b,c,d): the inserted Project passes `c` through. Catches: the
    passthrough list built from group keys and builtin aggregands alone."""
    var aggs = AggExprArray()
    aggs.append(AggExpr(
        AGG_SUM,
        Optional[Expr](Expr.binary(BIN_ADD, Expr.col_ref("a"), Expr.col_ref("b"))),
        Optional[String](String("s")),
    ))
    var plan = LogicalPlan.aggregate_with_udf(_cols("a"), aggs^, _scan("a,b,c,d"), _udf(UDF_KIND_AGG, "c"))
    var out = materialize_agg_input(plan^)
    ref p = out._aggregate.value()[].child[]
    assert_equal(p.tag, PLAN_PROJECT, "VACUOUS: no Project was inserted")
    var names = Set[String]()
    for i in range(p.output_schema.num_columns()):
        names.add(p.output_schema.field_name(i))
    assert_true("c" in names, "the inserted Project pruned the UDF's input column")
    assert_false("d" in names, "VACUOUS: the passthrough list did not narrow")


def _grouped_right() raises -> LogicalPlan:
    """Aggregate(rk; sum rv AS s) over Scan(rk, rv): unique on rk."""
    return LogicalPlan.aggregate(_cols("rk"), _aggs1("rv", "s"), _scan("rk,rv", "r.parquet"))


def test_semi_conversion_counts_the_udf_read_columns() raises:
    """convert_inner_to_semi: Project[udf reads s](lk, lv) over INNER(L,
    Aggregate grouped on rk) stays INNER. Catches: the UDF's right-side read
    `s` left out, so the join turns SEMI and `s` is gone."""
    var join = LogicalPlan.join(
        _scan("lk,lv", "l.parquet"), _grouped_right(), _keys("lk"), _keys("rk"), JOIN_INNER
    )
    var plan = LogicalPlan.project_with_udf(_cols("lk", "lv"), join^, _udf(UDF_KIND_MAP, "s"))
    var out = convert_inner_to_semi(plan^)
    assert_equal(out._project.value()[].child[]._join.value()[].join_type, JOIN_INNER)


def test_semi_conversion_still_fires_without_the_udf() raises:
    """The same plan with a plain Project turns SEMI: proves the test above is
    not vacuous."""
    var join = LogicalPlan.join(
        _scan("lk,lv", "l.parquet"), _grouped_right(), _keys("lk"), _keys("rk"), JOIN_INNER
    )
    var out = convert_inner_to_semi(LogicalPlan.project(_cols("lk", "lv"), join^))
    assert_true(out._project.value()[].child[]._join.value()[].join_type != JOIN_INNER)


def _rank_pb() raises -> LogicalPlan:
    """PartitionBy(RANK by pid, order score desc) over Scan(pid,score,val)."""
    var exprs = List[PartitionExpr]()
    exprs.append(PartitionExpr.rank())
    var desc: List[Bool] = [True]
    return LogicalPlan.partition_by(_keys("pid"), _keys("score"), desc^, exprs^, _scan("pid,score,val"))


def _win(plan: LogicalPlan) -> String:
    """The window column a PartitionBy appends (its last column)."""
    return plan.output_schema.field_name(plan.output_schema.num_columns() - 1)


def _fusable(rk: String, var pb: LogicalPlan) -> LogicalPlan:
    """Filter(rk <= 3) over `pb`."""
    return LogicalPlan.filter(
        Expr.binary(BIN_LE, Expr.col_ref(rk), Expr.literal(ScalarValue.from_int(3))), pb^
    )


def _assert_emits_rank(plan: LogicalPlan, rk: String) raises:
    assert_equal(plan.tag, PLAN_PARTITION_TOPN, "VACUOUS: no fusion")
    ref name = plan._partition_topn.value()[].output_rank_col_name
    assert_true(Bool(name), "the fused node drops the rank column a UDF reads")
    assert_equal(name.value(), rk)


def test_topn_fusion_keeps_the_rank_a_udf_project_reads() raises:
    """fuse_partition_topn, the Project arm of the ancestor walk:
    Project[udf reads rk](pid) over the fusable Filter. Catches: the UDF's
    read of the rank column left out of the ancestor set."""
    var pb = _rank_pb()
    var rk = _win(pb)
    var plan = LogicalPlan.project_with_udf(_cols("pid"), _fusable(rk, pb^), _udf_one(UDF_KIND_MAP, rk))
    var out = fuse_partition_topn(plan^)
    _assert_emits_rank(out._project.value()[].child[], rk)


def test_topn_fusion_keeps_the_rank_a_udf_filter_reads() raises:
    """fuse_partition_topn, the Filter arm: Project(pid) over Filter[udf
    reads rk] over the fusable Filter. Catches: the Filter arm adding only
    its predicate's columns."""
    var pb = _rank_pb()
    var rk = _win(pb)
    # Project(pid) on top: the plan's output does not carry rk, so only the
    # UDF Filter's read can make the fused node emit it.
    var plan = LogicalPlan.project(_cols("pid"), _udf_filter(_fusable(rk, pb^), rk))
    var out = fuse_partition_topn(plan^)
    _assert_emits_rank(out._project.value()[].child[]._filter.value()[].child[], rk)


def test_topn_fusion_keeps_the_rank_a_udf_aggregate_reads() raises:
    """fuse_partition_topn, the Aggregate arm: Aggregate[udf reads rk](pid)
    over the fusable Filter. Catches: the Aggregate arm adding only group
    keys and builtin aggregands."""
    var pb = _rank_pb()
    var rk = _win(pb)
    var plan = LogicalPlan.aggregate_with_udf(_cols("pid"), AggExprArray(), _fusable(rk, pb^), _udf_one(UDF_KIND_AGG, rk))
    var out = fuse_partition_topn(plan^)
    _assert_emits_rank(out._aggregate.value()[].child[], rk)


# =============================================================================
# Whole plans through optimize()
# =============================================================================


def _optimize(var plan: LogicalPlan) raises -> LogicalPlan:
    var deps = ScalarDepTable()
    return optimize(plan^, OptimizerConfig(), deps)


def test_optimize_keeps_a_udf_project_under_a_project() raises:
    """Project(a) over Project[udf reads d](a, b) over Scan(a..e) keeps its
    UDF Project with both exprs. Catches: any pass of the driver dropping
    the UDF (window_rewrite did before this sweep)."""
    var inner = LogicalPlan.project_with_udf(_cols("a", "b"), _scan("a,b,c,d,e"), _udf(UDF_KIND_MAP, "d"))
    var out = _optimize(LogicalPlan.project(_cols("a"), inner^))
    assert_equal(_count_udfs(out), 1, "optimize dropped the UDF")


def test_optimize_keeps_a_udf_project_under_a_limit() raises:
    """Limit(3) over Project[udf reads c](a) over Scan: the UDF survives and
    the Limit stays above it. Catches: push_limit_down or a later pass
    dropping or reordering the UDF Project."""
    var p = LogicalPlan.project_with_udf(_cols("a"), _scan("a,b,c"), _udf(UDF_KIND_MAP, "c"))
    var out = _optimize(LogicalPlan.limit(3, p^))
    assert_equal(_count_udfs(out), 1, "optimize dropped the UDF")
    assert_equal(out.tag, PLAN_LIMIT)


def test_optimize_keeps_a_udf_filter_under_a_filter_and_a_project() raises:
    """Project(b) over Filter(a > 1) over Filter[udf reads c](lit(true)) over
    Scan(a,b,c,d): the UDF survives. Catches: predicate pushdown, filter
    fusion or window_rewrite dropping the UDF Filter."""
    var f = LogicalPlan.filter(_gt("a", 1), _udf_filter(_scan("a,b,c,d"), "c"))
    var out = _optimize(LogicalPlan.project(_cols("b"), f^))
    assert_equal(_count_udfs(out), 1, "optimize dropped the UDF")


def main() raises:
    var suite = TestSuite()
    suite.test[test_rebuild_helpers_carry_the_payload]()
    suite.test[test_window_rewrite_keeps_a_udf_filter]()
    suite.test[test_window_rewrite_keeps_a_udf_project]()
    suite.test[test_eager_walk_keeps_a_udf_filter]()
    suite.test[test_eager_walk_keeps_a_udf_project]()
    suite.test[test_eager_walk_keeps_a_udf_aggregate]()
    suite.test[test_partial_agg_walk_keeps_a_udf_filter]()
    suite.test[test_partial_agg_walk_keeps_a_udf_project]()
    suite.test[test_partial_agg_walk_keeps_a_udf_aggregate]()
    suite.test[test_force_partial_agg_walk_keeps_a_udf_filter]()
    suite.test[test_force_partial_agg_walk_keeps_a_udf_project]()
    suite.test[test_force_partial_agg_walk_keeps_a_udf_aggregate]()
    suite.test[test_agg_cse_replace_walk_keeps_a_udf_filter]()
    suite.test[test_agg_cse_replace_walk_keeps_a_udf_project]()
    suite.test[test_agg_cse_replace_walk_keeps_a_udf_aggregate]()
    suite.test[test_shared_relation_install_walk_keeps_a_udf_filter]()
    suite.test[test_shared_relation_install_walk_keeps_a_udf_project]()
    suite.test[test_shared_relation_install_walk_keeps_a_udf_aggregate]()
    suite.test[test_shared_relation_leaf_install_keeps_the_aggregate_udf]()
    suite.test[test_scalar_subquery_rewrite_walk_keeps_a_udf_filter]()
    suite.test[test_scalar_subquery_rewrite_walk_keeps_a_udf_project]()
    suite.test[test_scalar_broadcast_walk_keeps_a_udf_filter_over_an_aggregate]()
    suite.test[test_scalar_broadcast_walk_keeps_a_udf_filter]()
    suite.test[test_limit_stays_above_a_udf_project]()
    suite.test[test_eager_does_not_split_a_udf_aggregate]()
    suite.test[test_eager_does_not_peel_a_udf_project]()
    suite.test[test_force_partial_agg_does_not_split_a_udf_aggregate]()
    suite.test[test_predicate_stays_above_a_udf_filter]()
    suite.test[test_plain_filter_over_a_udf_filter_is_not_fused]()
    suite.test[test_udf_filter_over_a_plain_filter_is_not_fused]()
    suite.test[test_hoist_leaves_a_udf_inner_filter_whole]()
    suite.test[test_cse_leaves_a_udf_aggregate_alone]()
    suite.test[test_cse_axis3_still_fires_on_a_plain_aggregate]()
    suite.test[test_absorb_keeps_a_udf_project_below_an_aggregate]()
    suite.test[test_absorb_keeps_the_project_a_udf_aggregate_reads]()
    suite.test[test_materialized_agg_input_keeps_the_udf_read_columns]()
    suite.test[test_semi_conversion_counts_the_udf_read_columns]()
    suite.test[test_semi_conversion_still_fires_without_the_udf]()
    suite.test[test_topn_fusion_keeps_the_rank_a_udf_project_reads]()
    suite.test[test_topn_fusion_keeps_the_rank_a_udf_filter_reads]()
    suite.test[test_topn_fusion_keeps_the_rank_a_udf_aggregate_reads]()
    suite.test[test_optimize_keeps_a_udf_project_under_a_project]()
    suite.test[test_optimize_keeps_a_udf_project_under_a_limit]()
    suite.test[test_optimize_keeps_a_udf_filter_under_a_filter_and_a_project]()
    suite^.run()
