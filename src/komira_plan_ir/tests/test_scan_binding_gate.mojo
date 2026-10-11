# =============================================================================
# The scan-binding epoch gate: `check_plan_scan_bindings` /
# `check_expr_scan_bindings`
# =============================================================================
#
# The walk is driven here directly over the IR: a small resolver defined in
# this file and hand-built plans and expressions. No engine context, no
# executor, no registry.
#
# THE RESOLVER. `_Resolver(ep, evicted)` answers epoch `ep`, and says every
# handle is bound except `evicted`. Every binding built here carries epoch
# `GOOD` and a handle unique within its tree, named `leaf<handle>`.
#
# THE ORACLES, and why there are two:
#
#   * THE RETURN VALUE is the number of scan leaves inspected. An arm that
#     skips a child, or counts a leaf it did not inspect, is visible in it.
#   * EVERY LEAF, POISONED IN TURN. For each handle `h` of a tree, a walk
#     against `_Resolver(GOOD, h)` must raise `SCAN_BINDING_HANDLE_NOT_BOUND`
#     naming `leaf<h>` and `h`. That is the proof the walk REACHED that leaf
#     and ran the epoch check on its binding: a walk that counts a leaf
#     without checking it, or checks the wrong binding, stays silent here.
#     A clean walk (nothing evicted) must raise nothing.
#
# Test groups:
#   1. The scan leaf: a binding-backed leaf, an in-memory leaf carrying a
#      handle, an unbound binding (counted, legal), an unbound in-memory leaf
#      and a parquet leaf (not counted), a payload-less node, a handle from
#      another epoch, and the pushed-down filter on every kind of leaf.
#   2. Every plan tag: each node over checked children, both sides of a join,
#      the join residual, every agg-expression slot, every union child, the
#      genuine leaves, every payload-less node, and the refusal of a tag with
#      no arm.
#   3. Every expression tag: each one-, two- and N-child shape over a
#      correlated subquery holding a checked leaf, the genuine leaves, every
#      payload-less node, nested subqueries, and the refusal of a tag with no
#      arm, also through a plan walk.
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_raises

from komira_arrow.arrow_types import ArrowType
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import Field, RecordBatch, Schema, SchemaBuilder
from komira_collections.slab import Slab
from komira_plan_expr.agg_expr import AggExpr, AGG_COUNT, AGG_SUM
from komira_plan_expr.corr_subquery_data import CORR_KIND_EXISTS
from komira_plan_expr.expr import (
    Expr,
    WhenCaseData,
    BIN_AND,
    EXTRACT_YEAR,
    STR_CONTAINS,
    UN_NOT,
    EXPR_TAG_COUNT,
)
from komira_plan_expr.partition_expr import PartitionExpr
from komira_plan_expr.partition_frame import PartitionFrame
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import (
    AsofTolerance,
    LogicalPlan,
    ASOF_BACKWARD,
    JOIN_INNER,
    PLAN_SCAN,
    PLAN_TAG_COUNT,
    PLAN_VIEW_REF,
    PLAN_CSE_REF,
    SOURCE_PARQUET,
)
from komira_plan_ir.scan_binding_gate import (
    check_expr_scan_bindings,
    check_plan_scan_bindings,
    SCAN_BINDING_GATE_UNMODELLED_EXPR_TAG,
    SCAN_BINDING_GATE_UNMODELLED_TAG,
)
from komira_scan_source.in_memory_source import InMemorySource
from komira_scan_source.pushdown_gate import PushdownGate
from komira_scan_source.scan_binding import (
    ScanBinding,
    scan_kind_id,
    SCAN_HANDLE_UNBOUND,
)
from komira_scan_source.scan_params import ScanParams
from komira_scan_source.scan_resolver import (
    ScanResolver,
    UnboundScanResolver,
    SCAN_BINDING_EPOCH_MISMATCH,
    SCAN_BINDING_HANDLE_NOT_BOUND,
)
from komira_scan_source.source_variant import SourceVariant


# =============================================================================
# Fixtures
# =============================================================================


comptime GOOD: UInt64 = 7
"""The epoch every binding here is minted under, and the resolver answers."""

comptime NONE_EVICTED: Int = -1000
"""An `evicted` value no binding here carries: a clean resolver."""


@fieldwise_init
struct _Resolver(ScanResolver, Movable, Deinitable):
    """Epoch `ep`; every handle is bound except `evicted`."""

    var ep: UInt64
    var evicted: Int

    def epoch(self) -> UInt64:
        return self.ep

    def is_bound(self, kind_id: UInt32, handle: Int) -> Bool:
        return handle != self.evicted

    def resolve_snapshot(self, binding: ScanBinding) raises -> UInt64:
        return binding.snapshot_token


def _clean() -> _Resolver:
    return _Resolver(GOOD, NONE_EVICTED)


def _schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, nullable=False))
    return sb.build()


def _binding(h: Int, epoch: UInt64) -> ScanBinding:
    return ScanBinding(
        kind_id=scan_kind_id(String("example.gate.kind")),
        kind_name=String("example.gate.kind"),
        name=String("leaf") + String(h),
        params=ScanParams(),
        schema=_schema(),
        fingerprint=UInt64(h),
        structural_id=UInt64(h),
        gate=PushdownGate.reject_all(),
        handle=h,
        registry_epoch=epoch,
    )


def _bscan(
    h: Int, epoch: UInt64 = GOOD, var filter: Optional[Expr] = None
) raises -> LogicalPlan:
    """A binding-backed scan leaf (`SourceVariant.from_binding`) holding
    handle `h`."""
    return LogicalPlan.scan_from_source(
        SourceVariant.from_binding(_binding(h, epoch)), _schema(), filter=filter^
    )


def _inmem_source() raises -> SourceVariant:
    var vals = List[Int64]()
    vals.append(Int64(1))
    var rb = RecordBatch.from_columns_1(
        _schema(), PrimitiveArray[DType.int64].from_list(vals)
    )
    return SourceVariant(InMemorySource.from_record_batch(rb^))


def _cscan(
    h: Int, epoch: UInt64 = GOOD, var filter: Optional[Expr] = None
) raises -> LogicalPlan:
    """An in-memory scan leaf whose carrier holds handle `h`: the arm
    `is_binding_backed()` is false for."""
    var sv = _inmem_source()
    sv.attach_carrier_binding(_binding(h, epoch))
    return LogicalPlan.scan_from_source(sv^, _schema(), filter=filter^)


def _parquet(var filter: Optional[Expr] = None) -> LogicalPlan:
    return LogicalPlan.scan(
        String("t.parquet"), SOURCE_PARQUET, _schema(), filter=filter^
    )


def _subq(h: Int) raises -> Expr:
    """EXISTS over a checked leaf: the one expression that holds a plan."""
    var refs = List[String]()
    refs.append(String("a"))
    return Expr.correlated_subquery(_bscan(h), refs^, CORR_KIND_EXISTS)


def _col() -> Expr:
    return Expr.col_ref(String("a"))


def _not_bound(h: Int) -> String:
    return (
        String(SCAN_BINDING_HANDLE_NOT_BOUND)
        + String(": ScanBinding 'leaf")
        + String(h)
        + String("' handle ")
        + String(h)
        + String(" is not bound in this registry")
    )


def _hs(*hs: Int) -> List[Int]:
    var out = List[Int]()
    for h in hs:
        out.append(h)
    return out^


def _gate_plan(plan: LogicalPlan, count: Int, handles: List[Int]) raises:
    """The two oracles over a plan: `count` leaves inspected by a clean walk,
    and every handle in `handles` reached and checked."""
    assert_equal(check_plan_scan_bindings(_clean(), plan), count)
    for i in range(len(handles)):
        var h = handles[i]
        with assert_raises(contains=_not_bound(h)):
            _ = check_plan_scan_bindings(_Resolver(GOOD, h), plan)


def _gate_expr(expr: Expr, count: Int, handles: List[Int]) raises:
    """`_gate_plan` for an expression."""
    assert_equal(check_expr_scan_bindings(_clean(), expr), count)
    for i in range(len(handles)):
        var h = handles[i]
        with assert_raises(contains=_not_bound(h)):
            _ = check_expr_scan_bindings(_Resolver(GOOD, h), expr)


# =============================================================================
# 1. The scan leaf
# =============================================================================


def test_a_binding_backed_leaf_is_checked_and_counted() raises:
    var plan = _bscan(3)
    _gate_plan(plan, 1, _hs(3))
    # Another handle evicted: this leaf is still clean.
    assert_equal(check_plan_scan_bindings(_Resolver(GOOD, 4), plan), 1)


def test_a_carrier_bound_inmem_leaf_is_checked_and_counted() raises:
    """The tag-keyed predicate is false for the in-memory arm; the carrier
    handle is what the gate must check."""
    var plan = _cscan(5)
    _gate_plan(plan, 1, _hs(5))


def test_a_handle_from_another_epoch_is_refused_on_both_arms() raises:
    var b = _bscan(2, epoch=UInt64(9))
    with assert_raises(
        contains=String(SCAN_BINDING_EPOCH_MISMATCH)
        + ": ScanBinding 'leaf2' carries a handle minted by registry epoch 9"
        + " but is being resolved against epoch 7"
    ):
        _ = check_plan_scan_bindings(_clean(), b)
    var c = _cscan(6, epoch=UInt64(11))
    with assert_raises(
        contains=String(SCAN_BINDING_EPOCH_MISMATCH)
        + ": ScanBinding 'leaf6' carries a handle minted by registry epoch 11"
        + " but is being resolved against epoch 7"
    ):
        _ = check_plan_scan_bindings(_clean(), c)
    # The same leaves under a resolver of their own epoch pass.
    assert_equal(check_plan_scan_bindings(_Resolver(UInt64(9), -5), b), 1)
    assert_equal(check_plan_scan_bindings(_Resolver(UInt64(11), -5), c), 1)


def test_an_unbound_binding_is_counted_and_legal() raises:
    """A binding-backed leaf with no handle is inspected (counted) and is not
    an error, whatever the resolver: even one that calls the unbound handle
    value itself evicted, and the resolver that binds nothing."""
    var plan = _bscan(SCAN_HANDLE_UNBOUND)
    assert_equal(check_plan_scan_bindings(_clean(), plan), 1)
    assert_equal(
        check_plan_scan_bindings(_Resolver(GOOD, SCAN_HANDLE_UNBOUND), plan), 1
    )
    assert_equal(check_plan_scan_bindings(UnboundScanResolver(), plan), 1)


def test_leaves_with_no_handle_are_not_counted() raises:
    """An in-memory leaf never bound, and a parquet leaf: nothing to check,
    and counting them would overstate the gate's coverage."""
    var inmem = LogicalPlan.scan_from_source(_inmem_source(), _schema())
    assert_equal(check_plan_scan_bindings(_clean(), inmem), 0)
    assert_equal(check_plan_scan_bindings(UnboundScanResolver(), inmem), 0)
    var pq = _parquet()
    assert_equal(check_plan_scan_bindings(_clean(), pq), 0)


def test_a_payloadless_scan_is_not_counted() raises:
    var plan = LogicalPlan(PLAN_SCAN, _schema())
    assert_equal(check_plan_scan_bindings(_clean(), plan), 0)


def test_the_pushed_down_filter_is_walked_on_every_leaf_kind() raises:
    """A scan is not a leaf of this walk: its filter can hold a subquery."""
    var b = _bscan(1, filter=Optional[Expr](_subq(2)))
    _gate_plan(b, 2, _hs(1, 2))
    var c = _cscan(3, filter=Optional[Expr](_subq(4)))
    _gate_plan(c, 2, _hs(3, 4))
    var pq = _parquet(Optional[Expr](_subq(5)))
    _gate_plan(pq, 1, _hs(5))
    var unbound = LogicalPlan.scan_from_source(
        _inmem_source(), _schema(), filter=Optional[Expr](_subq(6))
    )
    _gate_plan(unbound, 1, _hs(6))
    # A filter with no subquery adds nothing.
    var plain = _bscan(7, filter=Optional[Expr](_col()))
    _gate_plan(plain, 1, _hs(7))


# =============================================================================
# 2. Plan tags
# =============================================================================


def test_view_ref_and_cse_ref_are_leaves() raises:
    var v = LogicalPlan.view_ref(String("v"), _schema())
    assert_equal(check_plan_scan_bindings(_clean(), v), 0)
    var c = LogicalPlan.cse_ref(UInt64(7), _schema())
    assert_equal(check_plan_scan_bindings(_clean(), c), 0)
    # The `or` of the leaf arm, each operand alone (payload-less nodes).
    var pv = LogicalPlan(PLAN_VIEW_REF, _schema())
    assert_equal(check_plan_scan_bindings(_clean(), pv), 0)
    var pc = LogicalPlan(PLAN_CSE_REF, _schema())
    assert_equal(check_plan_scan_bindings(_clean(), pc), 0)


def test_filter_walks_predicate_and_child() raises:
    var plan = LogicalPlan.filter(_subq(1), _bscan(2))
    _gate_plan(plan, 2, _hs(1, 2))
    var plain = LogicalPlan.filter(_col(), _cscan(3))
    _gate_plan(plain, 1, _hs(3))


def test_project_walks_every_expr_and_child() raises:
    var exprs = Slab[Expr].create(3)
    exprs.append(_subq(1))
    exprs.append(_col())
    exprs.append(Expr.alias(_subq(2), String("s")))
    var plan = LogicalPlan.project(exprs^, _bscan(3))
    _gate_plan(plan, 3, _hs(1, 2, 3))


def test_aggregate_walks_group_keys_every_agg_slot_and_child() raises:
    # A subquery in the first and the LAST group key.
    var group_by = Slab[Expr].create(3)
    group_by.append(_subq(1))
    group_by.append(_col())
    group_by.append(_subq(8))
    var aggs = Slab[AggExpr].create(3)
    # COUNT(*): no child at all.
    aggs.append(AggExpr(AGG_COUNT, Optional[Expr](), Optional[String]()))
    # One slot.
    aggs.append(
        AggExpr(AGG_SUM, Optional[Expr](_subq(2)), Optional[String]("s"))
    )
    # All four slots, set directly: the walk reads every slot, not
    # `num_children()`.
    var four = AggExpr(AGG_SUM, Optional[Expr](_subq(3)), Optional[String]("f"))
    four.child1 = Optional[Expr](_subq(4))
    four.child2 = Optional[Expr](_subq(5))
    four.child3 = Optional[Expr](_subq(6))
    aggs.append(four^)
    var plan = LogicalPlan.aggregate(group_by^, aggs^, _bscan(7))
    _gate_plan(plan, 8, _hs(1, 2, 3, 4, 5, 6, 7, 8))


def test_a_sparse_agg_expr_is_walked_past_its_empty_slot() raises:
    """Slot 0 empty, slot 3 full: `num_children()` reads 0 here."""
    var group_by = Slab[Expr].create(1)
    var aggs = Slab[AggExpr].create(1)
    var sparse = AggExpr(AGG_SUM, Optional[Expr](), Optional[String]("x"))
    sparse.child3 = Optional[Expr](_subq(1))
    aggs.append(sparse^)
    var plan = LogicalPlan.aggregate(group_by^, aggs^, _parquet())
    _gate_plan(plan, 1, _hs(1))


def test_single_child_nodes_without_expressions() raises:
    var keys = List[String]()
    keys.append(String("a"))
    var desc = List[Bool]()
    desc.append(False)
    var sort = LogicalPlan.sort(keys.copy(), desc.copy(), _bscan(1))
    _gate_plan(sort, 1, _hs(1))
    var limit = LogicalPlan.limit(3, _bscan(2))
    _gate_plan(limit, 1, _hs(2))
    var distinct = LogicalPlan.distinct(None, _bscan(3))
    _gate_plan(distinct, 1, _hs(3))
    var topn = LogicalPlan.topn(keys.copy(), desc.copy(), 2, _bscan(4))
    _gate_plan(topn, 1, _hs(4))
    var pby = LogicalPlan.partition_by(
        keys.copy(), keys.copy(), desc.copy(), List[PartitionExpr](), _bscan(5)
    )
    _gate_plan(pby, 1, _hs(5))
    var ptopn = LogicalPlan.partition_topn(
        keys.copy(), keys.copy(), desc.copy(), 1, _bscan(6)
    )
    _gate_plan(ptopn, 1, _hs(6))
    var cast = LogicalPlan.cast_to_varchar(_bscan(7))
    _gate_plan(cast, 1, _hs(7))


def test_join_walks_both_sides_and_the_residual() raises:
    var on = List[String]()
    on.append(String("a"))
    var plan = LogicalPlan.join(
        _bscan(1),
        _cscan(2),
        on.copy(),
        on.copy(),
        JOIN_INNER,
        residual=Optional[OwnedPointer[Expr]](OwnedPointer(_subq(3))),
    )
    _gate_plan(plan, 3, _hs(1, 2, 3))
    # No residual; the checked leaf is on the right (build) side only.
    var right_only = LogicalPlan.join(
        _parquet(), _cscan(4), on.copy(), on.copy(), JOIN_INNER
    )
    _gate_plan(right_only, 1, _hs(4))


def test_asof_join_walks_both_sides() raises:
    var keys = List[String]()
    var plan = LogicalPlan.asof_join(
        _bscan(1),
        _bscan(2),
        keys.copy(),
        keys.copy(),
        String("a"),
        String("a"),
        ASOF_BACKWARD,
        AsofTolerance.none(),
    )
    _gate_plan(plan, 2, _hs(1, 2))


def test_union_walks_every_child() raises:
    var children = List[OwnedPointer[LogicalPlan]]()
    children.append(OwnedPointer(_bscan(1)))
    children.append(OwnedPointer(_parquet()))
    children.append(OwnedPointer(_cscan(3)))
    var plan = LogicalPlan.union(children^, _schema())
    _gate_plan(plan, 2, _hs(1, 3))


def test_a_deep_tree_is_walked_end_to_end() raises:
    """limit(sort(filter(join(scan, union(scan, scan))))), the filter
    predicate a subquery."""
    var keys = List[String]()
    keys.append(String("a"))
    var desc = List[Bool]()
    desc.append(True)
    var children = List[OwnedPointer[LogicalPlan]]()
    children.append(OwnedPointer(_bscan(2)))
    children.append(OwnedPointer(_cscan(3)))
    var u = LogicalPlan.union(children^, _schema())
    var j = LogicalPlan.join(_bscan(1), u^, keys.copy(), keys.copy(), JOIN_INNER)
    var f = LogicalPlan.filter(_subq(4), j^)
    var s = LogicalPlan.sort(keys.copy(), desc.copy(), f^)
    var plan = LogicalPlan.limit(1, s^)
    _gate_plan(plan, 4, _hs(1, 2, 3, 4))


def test_every_payloadless_plan_node_is_answered_zero() raises:
    """A node whose tag has an arm but whose payload is absent is answered 0,
    not dereferenced. Every tag below `PLAN_TAG_COUNT`."""
    for t in range(PLAN_TAG_COUNT):
        var plan = LogicalPlan(UInt8(t), _schema())
        assert_equal(check_plan_scan_bindings(_clean(), plan), 0, String(t))


def test_a_plan_tag_with_no_arm_is_refused_by_name() raises:
    var plan = LogicalPlan(UInt8(PLAN_TAG_COUNT), _schema())
    with assert_raises(
        contains=String(SCAN_BINDING_GATE_UNMODELLED_TAG)
        + ": the scan-binding epoch walk has no arm for plan tag "
        + String(PLAN_TAG_COUNT)
        + " (tag#"
        + String(PLAN_TAG_COUNT)
        + ")."
        + " A tag with no arm here is a HOLE IN A SAFETY CHECK"
    ):
        _ = check_plan_scan_bindings(_clean(), plan)
    var far = LogicalPlan(UInt8(255), _schema())
    with assert_raises(contains="plan tag 255 (tag#255). A tag with no arm"):
        _ = check_plan_scan_bindings(_clean(), far)
    # Under a filter, the refusal reaches the caller of the outer walk.
    var under = LogicalPlan.filter(_col(), LogicalPlan(UInt8(200), _schema()))
    with assert_raises(contains="plan tag 200 (tag#200)."):
        _ = check_plan_scan_bindings(_clean(), under)


# =============================================================================
# 3. Expression tags
# =============================================================================


def test_a_correlated_subquery_checks_its_inner_plan() raises:
    var e = _subq(4)
    _gate_expr(e, 1, _hs(4))


def test_nested_subqueries_are_walked() raises:
    """EXISTS(filter(EXISTS(scan 1), scan 2)): plan -> expr -> plan -> expr."""
    var refs = List[String]()
    refs.append(String("a"))
    var inner = LogicalPlan.filter(_subq(1), _bscan(2))
    var e = Expr.correlated_subquery(inner^, refs^, CORR_KIND_EXISTS)
    _gate_expr(e, 2, _hs(1, 2))


def test_expression_leaves_are_answered_zero() raises:
    var c = _col()
    assert_equal(check_expr_scan_bindings(_clean(), c), 0)
    var i = Expr.col_idx(0)
    assert_equal(check_expr_scan_bindings(_clean(), i), 0)
    var l = Expr.literal(ScalarValue.from_int(1))
    assert_equal(check_expr_scan_bindings(_clean(), l), 0)
    var frame = PartitionFrame(0, 0, 0, 0, 0)
    var w = Expr.window_fn(0, String("a"), 0, frame^)
    assert_equal(check_expr_scan_bindings(_clean(), w), 0)


def test_one_child_expressions_descend_their_child() raises:
    _gate_expr(Expr.unary(UN_NOT, _subq(1)), 1, _hs(1))
    _gate_expr(Expr.cast(_subq(2), DType.int64), 1, _hs(2))
    _gate_expr(Expr.alias(_subq(3), String("x")), 1, _hs(3))
    _gate_expr(Expr.string_op(STR_CONTAINS, _subq(4), String("p")), 1, _hs(4))
    var vals = List[ScalarValue]()
    vals.append(ScalarValue.from_int(1))
    _gate_expr(Expr.in_list_node(_subq(5), vals^), 1, _hs(5))
    _gate_expr(Expr.agg_fn(AGG_SUM, _subq(6)), 1, _hs(6))
    _gate_expr(Expr.regexp_like(_subq(7), String("a.*")), 1, _hs(7))
    _gate_expr(Expr.struct_field(_subq(8), String("f")), 1, _hs(8))
    _gate_expr(Expr.struct_field_idx(_subq(9), 0), 1, _hs(9))
    _gate_expr(Expr.json_extract_json(_subq(10), String("$.k")), 1, _hs(10))
    _gate_expr(Expr.extract(EXTRACT_YEAR, _subq(11)), 1, _hs(11))
    _gate_expr(Expr.sqrt(_subq(12)), 1, _hs(12))
    _gate_expr(Expr.substring(_subq(13), 1, 2), 1, _hs(13))
    _gate_expr(Expr.upper(_subq(14)), 1, _hs(14))
    _gate_expr(
        Expr.udf_call(
            String("f"),
            Optional[Int](0),
            ArrowType.INT64,
            ArrowType.INT64,
            _subq(15),
        ),
        1,
        _hs(15),
    )


def test_n_child_string_fn_walks_every_argument() raises:
    """A subquery behind the first and the last argument, a plain column
    between them."""
    var args = List[Expr]()
    args.append(_subq(1))
    args.append(_col())
    args.append(_subq(3))
    _gate_expr(Expr.concat(args^), 2, _hs(1, 3))


def test_two_child_expressions_descend_both_sides() raises:
    _gate_expr(Expr.binary(BIN_AND, _subq(1), _subq(2)), 2, _hs(1, 2))
    _gate_expr(Expr.atan2(_subq(3), _subq(4)), 2, _hs(3, 4))
    _gate_expr(Expr.map_get(_subq(5), _subq(6)), 2, _hs(5, 6))


def test_when_walks_every_condition_result_and_default() raises:
    var cases = List[WhenCaseData]()
    cases.append(WhenCaseData(_subq(1), _subq(2)))
    cases.append(WhenCaseData(_subq(3), _subq(4)))
    _gate_expr(Expr.when(cases^, _subq(5)), 5, _hs(1, 2, 3, 4, 5))


def test_every_payloadless_expression_is_answered_zero() raises:
    for t in range(EXPR_TAG_COUNT):
        var e = Expr(UInt8(t))
        assert_equal(check_expr_scan_bindings(_clean(), e), 0, String(t))


def test_an_expression_tag_with_no_arm_is_refused_by_name() raises:
    var e = Expr(UInt8(EXPR_TAG_COUNT))
    with assert_raises(
        contains=String(SCAN_BINDING_GATE_UNMODELLED_EXPR_TAG)
        + ": the scan-binding epoch walk has no arm for expression tag "
        + String(EXPR_TAG_COUNT)
        + " (tag#"
        + String(EXPR_TAG_COUNT)
        + "). An expression tag with no arm here is a HOLE IN A SAFETY"
        + " CHECK"
    ):
        _ = check_expr_scan_bindings(_clean(), e)
    # The refusal reaches the caller of the PLAN walk through a filter.
    var plan = LogicalPlan.filter(Expr(UInt8(200)), _parquet())
    with assert_raises(
        contains="expression tag 200 (tag#200). An expression tag with no arm"
    ):
        _ = check_plan_scan_bindings(_clean(), plan)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
