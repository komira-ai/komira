# =============================================================================
# optimizer_agg_cse: every walk arm, the cheap-key pre-grouping, the fold
# rebuild, and common-aggregate dedup
# =============================================================================
#
# The agg-CSE fold is a correctness fix (q15's two copies of one grouped
# aggregate must read the SAME bytes), so a node kind dropped from one of its
# walks is a silent wrong answer, not a missed optimization. The cheap-key
# path must reach exactly the verdict of the exact-hash path while hashing
# less. Common-aggregate dedup must never collapse two aggregates that compute
# different values. Each test names the defect it catches.
# =============================================================================

from std.collections import Dict, Optional
from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field,
    RecordBatchBuilder,
    Schema,
    SchemaBuilder,
)
from komira_counters.planner_scale_counter import (
    planner_scale_agg_cse_cheap_calls,
    planner_scale_agg_cse_hash_calls,
    reset_planner_scale_counters,
)
from komira_plan_expr.agg_expr import AggExpr, AGG_SUM, AGG_MAX, AGG_COUNT
from komira_plan_expr.expr import (
    Expr,
    BIN_ADD,
    BIN_SUB,
    BIN_GT,
    UN_NOT,
    UN_NEGATE,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_expr.udf_data import UdfData, UDF_KIND_AGG, DTAG_I64
from komira_plan_ir.logical_plan import (
    AggExprArray,
    AggGroupTopK,
    AsofTolerance,
    ExprArray,
    LogicalPlan,
    ASOF_BACKWARD,
    JOIN_CROSS,
    JOIN_INNER,
    PLAN_AGGREGATE,
    PLAN_DISTINCT,
    PLAN_FILTER,
    PLAN_JOIN,
    PLAN_LIMIT,
    PLAN_PROJECT,
    PLAN_SCAN,
    PLAN_SORT,
    PLAN_TOPN,
    PLAN_UNION,
    SOURCE_PARQUET,
)
from komira_plan_ir.logical_plan_variants import SourceVariant
from komira_scan_source.in_memory_source import InMemorySource

from komira_optimizer.optimizer_agg_cse import (
    _acse_agg_equal,
    _acse_expr_equal,
    _acse_slot_equal,
    collect_agg_subtree_cheap_keys,
    collect_agg_subtree_hashes,
    collect_agg_subtree_hashes_in_groups,
    count_grouped_aggregate_nodes,
    dedup_common_aggregates,
    find_agg_subtree_by_hash,
    replace_agg_subtree_with_source,
)


# -----------------------------------------------------------------------------
# fixtures
# -----------------------------------------------------------------------------


def _schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("key", ArrowType.INT64, False))
    sb.add_field(Field("value", ArrowType.FLOAT64, False))
    return sb.build()


def _scan(path: String = "lineitem.parquet") -> LogicalPlan:
    return LogicalPlan.scan(path, SOURCE_PARQUET, _schema())


def _rv(var child: LogicalPlan) -> LogicalPlan:
    """`Aggregate(sum(value) GROUP BY key)` over `child`."""
    var gb = ExprArray()
    gb.append(Expr.col_ref("key"))
    var c: Optional[Expr] = Optional(Expr.col_ref("value"))
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_SUM, c^, Optional(String("total"))))
    return LogicalPlan.aggregate(gb^, aggs^, child^)


def _rv_scan() -> LogicalPlan:
    return _rv(_scan())


def _ungrouped(var child: LogicalPlan) -> LogicalPlan:
    var c: Optional[Expr] = Optional(Expr.col_ref("total"))
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_MAX, c^, Optional(String("m"))))
    return LogicalPlan.aggregate(ExprArray(), aggs^, child^)


def _l1(s: String) -> List[String]:
    var out = List[String]()
    out.append(s)
    return out^


def _cross(var a: LogicalPlan, var b: LogicalPlan) -> LogicalPlan:
    return LogicalPlan.join(a^, b^, List[String](), List[String](), JOIN_CROSS)


def _union(var a: LogicalPlan, var b: LogicalPlan) -> LogicalPlan:
    var schema = a.output_schema.copy()
    var kids = List[OwnedPointer[LogicalPlan]]()
    kids.append(OwnedPointer(a^))
    kids.append(OwnedPointer(b^))
    return LogicalPlan.union(kids^, schema^)


def _asof(var a: LogicalPlan, var b: LogicalPlan) -> LogicalPlan:
    return LogicalPlan.asof_join(
        a^, b^, List[String](), List[String](), String("key"), String("key"),
        ASOF_BACKWARD, AsofTolerance.none(),
    )


comptime N_KINDS = 7
"""Wrapper kinds: 0 Filter, 1 Project, 2 Aggregate (ungrouped), 3 Sort,
4 Limit, 5 Distinct, 6 TopN."""


def _wrap(kind: Int, var child: LogicalPlan) -> LogicalPlan:
    if kind == 0:
        return LogicalPlan.filter(
            Expr.binary(
                BIN_GT, Expr.col_ref("key"), Expr.literal(ScalarValue.from_int(0))
            ),
            child^,
        )
    if kind == 1:
        var ex = ExprArray()
        ex.append(Expr.col_ref("key"))
        ex.append(Expr.col_ref("total"))
        return LogicalPlan.project(ex^, child^)
    if kind == 2:
        return _ungrouped(child^)
    if kind == 3:
        var d = List[Bool]()
        d.append(True)
        var nf = List[Bool]()
        nf.append(True)
        return LogicalPlan.sort(_l1("key"), d^, child^, Optional(nf^))
    if kind == 4:
        return LogicalPlan.limit(4, child^, offset=2)
    if kind == 5:
        return LogicalPlan.distinct(Optional(_l1("key")), child^)
    var d = List[Bool]()
    d.append(True)
    var nf = List[Bool]()
    nf.append(True)
    return LogicalPlan.topn(_l1("key"), d^, 3, child^, Optional(nf^))


def _source(v: Float64) raises -> InMemorySource:
    """A one-row (key, total) batch; `v` makes the content distinct."""
    var kb = PrimitiveArray[DType.int64].allocate(1)
    var tb = PrimitiveArray[DType.float64].allocate(1)
    kb._typed_ptr_mut()[0] = Scalar[DType.int64](2)
    tb._typed_ptr_mut()[0] = Scalar[DType.float64](v)
    var sb = SchemaBuilder()
    sb.add_field(Field("key", ArrowType.INT64, False))
    sb.add_field(Field("value", ArrowType.FLOAT64, False))
    var bb = RecordBatchBuilder()
    bb.add_column(Column.from_primitive[DType.int64](kb^))
    bb.add_column(Column.from_primitive[DType.float64](tb^))
    var batch = bb.build(sb.build())
    return InMemorySource.from_record_batch(
        batch^, Optional[String](String("__agg_cse_paths"))
    )


def _mem_scan(v: Float64) raises -> LogicalPlan:
    return LogicalPlan.scan_from_source(SourceVariant(_source(v)), _schema())


def _hashes(plan: LogicalPlan) raises -> Dict[UInt64, Int]:
    var counts = Dict[UInt64, Int]()
    collect_agg_subtree_hashes(plan, counts)
    return counts^


# -----------------------------------------------------------------------------
# the shared walk
# -----------------------------------------------------------------------------


def test_every_walked_kind_reaches_the_aggregate() raises:
    """A grouped aggregate under each walked kind, under either side of a Join
    and an AsofJoin, and under a Union's second branch, is counted, hashed,
    cheap-keyed and found. Catches a kind added to one walk and not the
    others (a duplicate that the node count or the fold cannot see)."""
    var h = _rv_scan().structural_hash()
    var plans = List[LogicalPlan]()
    for kind in range(N_KINDS):
        plans.append(_wrap(kind, _rv_scan()))
    plans.append(_cross(_rv_scan(), _scan("b.parquet")))
    plans.append(_cross(_scan("b.parquet"), _rv_scan()))
    plans.append(_asof(_rv_scan(), _scan("b.parquet")))
    plans.append(_asof(_scan("b.parquet"), _rv_scan()))
    plans.append(_union(_scan("b.parquet"), _rv_scan()))
    for i in range(len(plans)):
        ref p = plans[i]
        var what = "plan " + String(i)
        assert_equal(count_grouped_aggregate_nodes(p), 1, what)
        var counts = _hashes(p)
        assert_equal(counts[h], 1, what)
        var cheap = Dict[UInt64, Int]()
        assert_equal(collect_agg_subtree_cheap_keys(p, cheap), 1, what)
        assert_equal(len(cheap), 1, what)
        var found = find_agg_subtree_by_hash(p, h)
        assert_true(Bool(found), what)
        assert_equal(found.value().structural_hash(), h, what)


def test_unwalked_kinds_and_misses() raises:
    """A bare scan, an ungrouped aggregate alone, a Union with no aggregate
    and a hash that matches nothing find nothing. Catches the fold target
    widened to ungrouped aggregates (see the module SCOPE note) or a find
    that returns a subtree for a hash nothing matches."""
    var h = _rv_scan().structural_hash()
    assert_equal(count_grouped_aggregate_nodes(_scan()), 0)
    assert_equal(count_grouped_aggregate_nodes(_ungrouped(_scan())), 0)
    assert_false(Bool(find_agg_subtree_by_hash(_scan(), h)))
    assert_false(Bool(find_agg_subtree_by_hash(_union(_scan(), _scan()), h)))
    var other = _rv(_scan("other.parquet"))
    assert_false(Bool(find_agg_subtree_by_hash(other, h)))
    assert_false(
        Bool(find_agg_subtree_by_hash(_cross(_scan(), _scan("b.parquet")), h))
    )
    assert_false(
        Bool(find_agg_subtree_by_hash(_asof(_scan(), _scan("b.parquet")), h))
    )


def test_cheap_keys_group_before_exact_hashing() raises:
    """Two aggregates over DIFFERENT in-memory content share a cheap key but
    not an exact hash: the cheap walk counts 2, the grouped exact walk hashes
    both (the group is hot) and finds no duplicate. With an empty hot set the
    grouped walk hashes nothing; the ungated walk hashes every node. Catches
    the cheap key used as the fold decision (a fold of different data) and a
    pre-grouping that hashes cold nodes."""
    var plan = _cross(_rv(_mem_scan(1.0)), _rv(_mem_scan(2.0)))
    var cheap = Dict[UInt64, Int]()
    reset_planner_scale_counters()
    assert_equal(collect_agg_subtree_cheap_keys(plan, cheap), 2)
    assert_equal(len(cheap), 1)
    assert_equal(planner_scale_agg_cse_cheap_calls(), 2)
    assert_equal(planner_scale_agg_cse_hash_calls(), 0)

    var hot = Dict[UInt64, Int]()
    for item in cheap.items():
        if item.value >= 2:
            hot[item.key] = item.value
    var exact = Dict[UInt64, Int]()
    collect_agg_subtree_hashes_in_groups(plan, hot, exact)
    assert_equal(planner_scale_agg_cse_hash_calls(), 2)
    assert_equal(len(exact), 2)

    reset_planner_scale_counters()
    var empty_hot = Dict[UInt64, Int]()
    var none = Dict[UInt64, Int]()
    collect_agg_subtree_hashes_in_groups(plan, empty_hot, none)
    assert_equal(len(none), 0)
    assert_equal(planner_scale_agg_cse_hash_calls(), 0)
    assert_equal(planner_scale_agg_cse_cheap_calls(), 2)

    reset_planner_scale_counters()
    var all_counts = _hashes(plan)
    assert_equal(len(all_counts), 2)
    assert_equal(planner_scale_agg_cse_hash_calls(), 2)
    assert_equal(planner_scale_agg_cse_cheap_calls(), 0)


def test_grouped_exact_walk_agrees_on_a_true_duplicate() raises:
    """Identical in-memory content: the pre-grouped exact walk counts the
    duplicate twice, the same verdict as the ungated walk. Catches the two
    paths disagreeing on a fold."""
    var plan = _cross(_rv(_mem_scan(1.0)), _rv(_mem_scan(1.0)))
    var cheap = Dict[UInt64, Int]()
    _ = collect_agg_subtree_cheap_keys(plan, cheap)
    var exact = Dict[UInt64, Int]()
    collect_agg_subtree_hashes_in_groups(plan, cheap, exact)
    var ungated = _hashes(plan)
    assert_equal(len(exact), 1)
    for item in exact.items():
        assert_equal(item.value, 2)
        assert_equal(ungated[item.key], 2)


# -----------------------------------------------------------------------------
# the fold rebuild
# -----------------------------------------------------------------------------


def test_replace_rebuilds_every_kind_around_the_leaf() raises:
    """The fold replaces the aggregate under each walked kind and keeps the
    node above it: Filter, Project, ungrouped Aggregate, Sort (direction,
    explicit null placement), Limit (n and offset), Distinct (columns), TopN
    (n, null placement), and a Join with a residual. Catches a rebuild that
    drops a Sort's null placement or a Limit's offset, or a Join's residual."""
    var h = _rv_scan().structural_hash()
    var src = _source(5.0)
    for kind in range(N_KINDS):
        var before = _wrap(kind, _rv_scan())
        var tag = before.tag
        var out = replace_agg_subtree_with_source(before^, h, src)
        assert_equal(Int(out.tag), Int(tag), "kind " + String(kind))
        assert_false(h in _hashes(out), "kind " + String(kind))
        if tag == PLAN_SORT:
            assert_true(out._sort.value()[].nulls_first[0])
            assert_true(out._sort.value()[].descending[0])
        elif tag == PLAN_LIMIT:
            assert_equal(out._limit.value()[].n, 4)
            assert_equal(out._limit.value()[].offset, 2)
        elif tag == PLAN_DISTINCT:
            assert_equal(out._distinct.value()[].columns.value()[0], "key")
        elif tag == PLAN_TOPN:
            assert_equal(out._topn.value()[].n, 3)
            assert_true(out._topn.value()[].nulls_first[0])

    var resid = Optional[OwnedPointer[Expr]](
        OwnedPointer(
            Expr.binary(
                BIN_GT, Expr.col_ref("key"), Expr.literal(ScalarValue.from_int(1))
            )
        )
    )
    var j = LogicalPlan.join(
        _rv_scan(), _rv_scan(), _l1("key"), _l1("key"), JOIN_INNER,
        residual=resid^,
    )
    var jo = replace_agg_subtree_with_source(j^, h, src)
    assert_equal(jo.tag, PLAN_JOIN)
    assert_true(jo._join.value()[].has_residual())
    assert_equal(jo._join.value()[].left[].tag, PLAN_SCAN)
    assert_equal(jo._join.value()[].right[].tag, PLAN_SCAN)

    var nd: Optional[List[String]] = None
    var d = replace_agg_subtree_with_source(
        LogicalPlan.distinct(nd^, _rv_scan()), h, src
    )
    assert_false(Bool(d._distinct.value()[].columns))


def test_replace_leaves_unwalked_kinds_alone() raises:
    """A Union, an AsofJoin and a bare scan come back unchanged (no fold
    beneath them). Catches a rebuild that mangles a node it does not walk."""
    var h = _rv_scan().structural_hash()
    var src = _source(5.0)
    var u = _union(_rv_scan(), _rv_scan())
    var uh = u.structural_hash()
    var uo = replace_agg_subtree_with_source(u^, h, src)
    assert_equal(uo.tag, PLAN_UNION)
    assert_equal(uo.structural_hash(), uh)
    var a = _asof(_rv_scan(), _scan("b.parquet"))
    var ah = a.structural_hash()
    assert_equal(replace_agg_subtree_with_source(a^, h, src).structural_hash(), ah)
    var s = _scan()
    var sh = s.structural_hash()
    assert_equal(replace_agg_subtree_with_source(s^, h, src).structural_hash(), sh)


# -----------------------------------------------------------------------------
# common-aggregate dedup
# -----------------------------------------------------------------------------


def _lit(v: Int) -> Expr:
    return Expr.literal(ScalarValue.from_int(v))


def test_expr_equality_is_strict_and_closed() raises:
    """Column refs by name AND side, literals by value, binary/unary ops by op
    and operands, an alias on either side transparent, a cast (outside the
    set) False.
    Catches two different aggregands judged equal (one aggregate silently
    answering for another)."""
    assert_true(_acse_expr_equal(Expr.col_ref("a"), Expr.col_ref("a")))
    assert_false(_acse_expr_equal(Expr.col_ref("a"), Expr.col_ref("b")))
    assert_false(_acse_expr_equal(Expr.left("a"), Expr.right("a")))
    assert_true(_acse_expr_equal(_lit(1), _lit(1)))
    assert_false(_acse_expr_equal(_lit(1), _lit(2)))
    assert_false(_acse_expr_equal(_lit(1), Expr.col_ref("a")))
    var add = Expr.binary(BIN_ADD, Expr.col_ref("a"), _lit(1))
    assert_true(_acse_expr_equal(add, Expr.binary(BIN_ADD, Expr.col_ref("a"), _lit(1))))
    assert_false(_acse_expr_equal(add, Expr.binary(BIN_SUB, Expr.col_ref("a"), _lit(1))))
    assert_false(_acse_expr_equal(add, Expr.binary(BIN_ADD, Expr.col_ref("b"), _lit(1))))
    assert_false(_acse_expr_equal(add, Expr.binary(BIN_ADD, Expr.col_ref("a"), _lit(2))))
    var neg = Expr.unary(UN_NEGATE, Expr.col_ref("a"))
    assert_true(_acse_expr_equal(neg, Expr.unary(UN_NEGATE, Expr.col_ref("a"))))
    assert_false(_acse_expr_equal(neg, Expr.unary(UN_NOT, Expr.col_ref("a"))))
    assert_false(_acse_expr_equal(neg, Expr.unary(UN_NEGATE, Expr.col_ref("b"))))
    assert_true(_acse_expr_equal(Expr.alias(Expr.col_ref("a"), "n"), Expr.col_ref("a")))
    assert_true(_acse_expr_equal(Expr.col_ref("a"), Expr.alias(Expr.col_ref("a"), "n")))
    var c1 = Expr.cast(Expr.col_ref("a"), DType.float64)
    var c2 = Expr.cast(Expr.col_ref("a"), DType.float64)
    assert_false(_acse_expr_equal(c1, c2))


def _sum(name: String) -> AggExpr:
    return AggExpr(AGG_SUM, Optional(Expr.col_ref("a")), Optional(name))


def test_slot_and_aggregate_equality() raises:
    """Slots: both empty equal, one empty unequal either way. Aggregates: the
    function and all four child slots must match; the output alias is
    ignored. Catches a bivariate aggregate deduped across a different second
    argument, or SUM collapsed into COUNT."""
    var none: Optional[Expr] = None
    assert_true(_acse_slot_equal(none, none))
    assert_false(_acse_slot_equal(none, Optional(Expr.col_ref("a"))))
    assert_false(_acse_slot_equal(Optional(Expr.col_ref("a")), none))
    assert_true(
        _acse_slot_equal(Optional(Expr.col_ref("a")), Optional(Expr.col_ref("a")))
    )
    assert_true(_acse_agg_equal(_sum("x"), _sum("y")))
    var cnt = AggExpr(AGG_COUNT, Optional(Expr.col_ref("a")), Optional(String("c")))
    assert_false(_acse_agg_equal(_sum("x"), cnt))
    var other = AggExpr(AGG_SUM, Optional(Expr.col_ref("b")), Optional(String("x")))
    assert_false(_acse_agg_equal(_sum("x"), other))
    var c1 = _sum("x")
    c1.child1 = Optional(Expr.col_ref("p"))
    assert_false(_acse_agg_equal(c1, _sum("x")))
    var c2 = _sum("x")
    c2.child2 = Optional(Expr.col_ref("p"))
    assert_false(_acse_agg_equal(c2, _sum("x")))
    var c3 = _sum("x")
    c3.child3 = Optional(Expr.col_ref("p"))
    assert_false(_acse_agg_equal(c3, _sum("x")))


def _dup_agg(var gb: ExprArray, var child: LogicalPlan) -> LogicalPlan:
    """`sum(value), sum(value), sum(value), max(value)` -- two duplicates of the
    first and a distinct fourth."""
    var aggs = AggExprArray()
    for i in range(3):
        aggs.append(
            AggExpr(AGG_SUM, Optional(Expr.col_ref("value")), Optional("s" + String(i)))
        )
    aggs.append(AggExpr(AGG_MAX, Optional(Expr.col_ref("value")), Optional(String("m"))))
    return LogicalPlan.aggregate(gb^, aggs^, child^)


def _first_agg_width(plan: LogicalPlan) raises -> Int:
    if plan.tag == PLAN_AGGREGATE:
        return len(plan._aggregate.value()[].agg_exprs)
    if plan.tag == PLAN_PROJECT:
        return _first_agg_width(plan._project.value()[].child[])
    if plan.tag == PLAN_JOIN:
        return _first_agg_width(plan._join.value()[].left[])
    if plan.tag == PLAN_FILTER:
        return _first_agg_width(plan._filter.value()[].child[])
    if plan.tag == PLAN_SORT:
        return _first_agg_width(plan._sort.value()[].child[])
    if plan.tag == PLAN_LIMIT:
        return _first_agg_width(plan._limit.value()[].child[])
    if plan.tag == PLAN_DISTINCT:
        return _first_agg_width(plan._distinct.value()[].child[])
    if plan.tag == PLAN_TOPN:
        return _first_agg_width(plan._topn.value()[].child[])
    return -1


def test_grouped_dedup_keeps_keys_names_and_estimate() raises:
    """A GROUPED node with three equal SUMs keeps one (the third compares
    only against representatives), keeps the group key first, publishes the
    original names in order, and carries `estimated_groups`. Catches a
    renumbered output, a lost group key or a dropped group estimate."""
    var gb = ExprArray()
    gb.append(Expr.col_ref("key"))
    var plan = _dup_agg(gb^, _scan())
    plan._aggregate.value()[].estimated_groups = Optional(42)
    var names = List[String]()
    for i in range(plan.output_schema.num_columns()):
        names.append(plan.output_schema.field_name(i))
    var out = dedup_common_aggregates(plan^)
    assert_equal(out.tag, PLAN_PROJECT)
    ref inner = out._project.value()[].child[]
    assert_equal(len(inner._aggregate.value()[].agg_exprs), 2)
    assert_equal(len(inner._aggregate.value()[].group_by), 1)
    assert_equal(inner._aggregate.value()[].estimated_groups.value(), 42)
    assert_equal(out.output_schema.num_columns(), len(names))
    for i in range(len(names)):
        assert_equal(out.output_schema.field_name(i), names[i])

    var gb2 = ExprArray()
    gb2.append(Expr.col_ref("key"))
    var no_est = dedup_common_aggregates(_dup_agg(gb2^, _scan()))
    assert_false(
        Bool(no_est._project.value()[].child[]._aggregate.value()[].estimated_groups)
    )


def test_dedup_declines() raises:
    """A UDF aggregate, a node carrying a group-TopK stamp, and a single
    aggregate are left untouched. Catches a rebuild that drops the UDF or the
    TopK stamp (`LogicalPlan.aggregate` carries neither)."""
    var in_cols = List[Tuple[String, UInt8]]()
    in_cols.append((String("value"), DTAG_I64))
    var out_cols = List[Tuple[String, UInt8]]()
    out_cols.append((String("u"), DTAG_I64))
    var udf = OwnedPointer(
        UdfData(UDF_KIND_AGG, String("my_agg"), in_cols^, out_cols^, 1, 1)
    )
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_SUM, Optional(Expr.col_ref("value")), Optional(String("a"))))
    aggs.append(AggExpr(AGG_SUM, Optional(Expr.col_ref("value")), Optional(String("b"))))
    var with_udf = LogicalPlan.aggregate_with_udf(ExprArray(), aggs^, _scan(), udf^)
    assert_equal(dedup_common_aggregates(with_udf^).tag, PLAN_AGGREGATE)

    var tk = _dup_agg(ExprArray(), _scan())
    var order = List[String]()
    order.append(String("s0"))
    var desc = List[Bool]()
    desc.append(True)
    tk._aggregate.value()[].group_topk = Optional(AggGroupTopK(order^, desc^, 3))
    assert_equal(dedup_common_aggregates(tk^).tag, PLAN_AGGREGATE)

    var one = AggExprArray()
    one.append(AggExpr(AGG_SUM, Optional(Expr.col_ref("value")), Optional(String("a"))))
    var single = LogicalPlan.aggregate(ExprArray(), one^, _scan())
    assert_equal(dedup_common_aggregates(single^).tag, PLAN_AGGREGATE)


def test_dedup_walks_every_kind() raises:
    """The duplicated aggregate is deduped under a Filter, Project, Sort,
    Limit, Distinct, TopN, either side of a Join, and beneath another
    Aggregate; a Union is not walked. Catches a kind that hides duplicates
    from the dedup."""
    for kind in [0, 3, 4, 5, 6]:
        var p = _wrap(kind, _dup_agg(ExprArray(), _scan()))
        assert_equal(
            _first_agg_width(dedup_common_aggregates(p^)), 2, "kind " + String(kind)
        )
    var ex = ExprArray()
    ex.append(Expr.col_ref("s0"))
    var proj = LogicalPlan.project(ex^, _dup_agg(ExprArray(), _scan()))
    assert_equal(_first_agg_width(dedup_common_aggregates(proj^)), 2)
    var jl = _cross(_dup_agg(ExprArray(), _scan()), _scan("b.parquet"))
    assert_equal(_first_agg_width(dedup_common_aggregates(jl^)), 2)
    var jr = _cross(_scan("b.parquet"), _dup_agg(ExprArray(), _scan()))
    var jro = dedup_common_aggregates(jr^)
    assert_equal(_first_agg_width(jro._join.value()[].right[]), 2)
    # Beneath another aggregate: the inner one is deduped first.
    var c: Optional[Expr] = Optional(Expr.col_ref("s0"))
    var outer_aggs = AggExprArray()
    outer_aggs.append(AggExpr(AGG_MAX, c^, Optional(String("mm"))))
    var nested = LogicalPlan.aggregate(
        ExprArray(), outer_aggs^, _dup_agg(ExprArray(), _scan())
    )
    var no = dedup_common_aggregates(nested^)
    assert_equal(no.tag, PLAN_AGGREGATE)
    assert_equal(_first_agg_width(no._aggregate.value()[].child[]), 2)
    # A Union is not walked: its branch keeps all four aggregates.
    var u = _union(_dup_agg(ExprArray(), _scan()), _dup_agg(ExprArray(), _scan()))
    var uo = dedup_common_aggregates(u^)
    assert_equal(uo.tag, PLAN_UNION)
    assert_equal(len(uo._union.value()[].children[0][]._aggregate.value()[].agg_exprs), 4)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
