# =============================================================================
# The entry-time bind walk: `bind_plan_inmem_payloads` / `bind_expr_inmem_payloads`
# =============================================================================
#
# The walk is driven here directly over the IR, with no engine context and no
# executor: a `ScanRegistry` and hand-built plans and expressions.
#
# THE ORACLES, and why there are three:
#
#   * THE RETURN VALUE is the number of fresh handles minted. The walk's caller
#     releases exactly that range, so an arm that skips a child (or counts a
#     leaf twice) is visible in the number.
#   * RESIDENT ROWS. Every in-memory leaf built here has a distinct power-of-two
#     row count, so `ScanRegistry.resident_payload_rows()` after a walk is the
#     bit set of the leaves that were actually bound. A walk that descends the
#     wrong child of a node returns the right count and the wrong rows.
#   * A SECOND WALK RETURNS 0. The walk binds in place: a leaf it stamped is
#     validly bound against the same registry, so walking it again mints
#     nothing. An arm that bound a copy of a subtree, or counted a leaf without
#     stamping it, mints again.
#
# Test groups:
#   1. The scan leaf's predicate: unbound, validly bound, stale (same registry,
#      released slot), foreign (another registry), a non-in-memory source, a
#      payload-less node, and the pushed-down filter.
#   2. Every plan tag: each node over in-memory children, both children of a
#      join, the join residual, every agg-expression slot, the union's
#      children, the genuine leaves, every payload-less node, and the refusal of
#      a tag with no arm.
#   3. Every expression tag: each one-, two- and N-child shape over a
#      correlated subquery holding an in-memory scan, the genuine leaves,
#      every payload-less node, nested subqueries, and the refusal of a tag
#      with no arm.
# =============================================================================

from std.memory import OwnedPointer
from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

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
from komira_plan_ir.corr_subquery import corr_subq_inner_plan_ref
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
from komira_plan_ir.scan_binding_bind_pass import (
    bind_expr_inmem_payloads,
    bind_plan_inmem_payloads,
    SCAN_BIND_PASS_UNMODELLED_EXPR_TAG,
    SCAN_BIND_PASS_UNMODELLED_TAG,
)
from komira_scan_source.in_memory_source import InMemorySource
from komira_scan_source.scan_binding import SCAN_STRUCTURAL_ID_UNRESOLVED
from komira_scan_source.scan_registry import ScanRegistry
from komira_scan_source.source_variant import SourceVariant


# =============================================================================
# Fixtures
# =============================================================================


def _schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, nullable=False))
    return sb.build()


def _inmem(rows: Int) raises -> LogicalPlan:
    """An unbound in-memory scan of `rows` rows of column `a`. Each test gives
    every leaf a distinct power-of-two `rows`, so resident rows name the leaves
    that were bound."""
    var vals = List[Int64]()
    for i in range(rows):
        vals.append(Int64(i))
    var rb = RecordBatch.from_columns_1(
        _schema(), PrimitiveArray[DType.int64].from_list(vals)
    )
    return LogicalPlan.scan_from_source(
        SourceVariant(InMemorySource.from_record_batch(rb^)), _schema()
    )


def _parquet() -> LogicalPlan:
    return LogicalPlan.scan(String("t.parquet"), SOURCE_PARQUET, _schema())


def _subq(rows: Int) raises -> Expr:
    """EXISTS over an in-memory scan: the one expression that holds a plan."""
    var refs = List[String]()
    refs.append(String("a"))
    return Expr.correlated_subquery(_inmem(rows), refs^, CORR_KIND_EXISTS)


def _col() -> Expr:
    return Expr.col_ref(String("a"))


def _is_bound_here(plan: LogicalPlan, registry: ScanRegistry) -> Bool:
    """The scan node carries a handle this registry minted and still holds."""
    ref src = plan.scan_data_ref().source
    if not src.has_carrier_binding():
        return False
    ref b = src.carrier_binding_ref()
    return b.registry_epoch == registry.epoch() and registry.is_bound(
        b.kind_id, b.handle
    )


def _walk_plan(
    mut plan: LogicalPlan, minted: Int, rows: Int
) raises:
    """Walk `plan` with a fresh registry. Asserts the three oracles: `minted`
    fresh handles, `rows` resident rows, and a second walk minting nothing."""
    var reg = ScanRegistry()
    assert_equal(bind_plan_inmem_payloads(reg, plan), minted)
    assert_equal(Int(reg.total_mints()), minted)
    assert_equal(reg.resident_payload_rows(), rows)
    assert_equal(bind_plan_inmem_payloads(reg, plan), 0)
    assert_equal(Int(reg.total_mints()), minted)


def _walk_expr(mut expr: Expr, minted: Int, rows: Int) raises:
    """`_walk_plan` for an expression."""
    var reg = ScanRegistry()
    assert_equal(bind_expr_inmem_payloads(reg, expr), minted)
    assert_equal(Int(reg.total_mints()), minted)
    assert_equal(reg.resident_payload_rows(), rows)
    assert_equal(bind_expr_inmem_payloads(reg, expr), 0)
    assert_equal(Int(reg.total_mints()), minted)


# =============================================================================
# 1. The scan leaf
# =============================================================================


def test_an_unbound_inmem_scan_is_bound_and_stamped() raises:
    var reg = ScanRegistry()
    var plan = _inmem(5)
    assert_false(plan.scan_data_ref().source.has_carrier_binding())
    assert_equal(bind_plan_inmem_payloads(reg, plan), 1)
    assert_true(_is_bound_here(plan, reg))
    assert_equal(Int(reg.total_mints()), 1)
    assert_equal(reg.num_bound(), 1)
    # The registry holds the node's own five rows.
    assert_equal(reg.resident_payload_rows(), 5)
    # A resolution token, not an identity: no content fold on this path.
    assert_equal(
        plan.scan_data_ref().source.carrier_binding_ref().structural_id,
        SCAN_STRUCTURAL_ID_UNRESOLVED,
    )


def test_a_validly_bound_scan_keeps_its_handle() raises:
    var reg = ScanRegistry()
    var plan = _inmem(3)
    _ = bind_plan_inmem_payloads(reg, plan)
    var h = plan.scan_data_ref().source.carrier_binding_ref().handle
    assert_equal(bind_plan_inmem_payloads(reg, plan), 0)
    assert_equal(plan.scan_data_ref().source.carrier_binding_ref().handle, h)
    assert_equal(Int(reg.total_mints()), 1)
    assert_equal(reg.num_slots(), 1)


def test_a_stale_handle_from_this_registry_is_replaced() raises:
    """Same epoch, released slot: the `is_bound` half of the predicate."""
    var reg = ScanRegistry()
    var plan = _inmem(4)
    var scope = reg.open_scan_bind_scope()
    assert_equal(bind_plan_inmem_payloads(reg, plan), 1)
    var first_handle = plan.scan_data_ref().source.carrier_binding_ref().handle
    _ = scope^  # releases and reclaims the slot
    ref b = plan.scan_data_ref().source.carrier_binding_ref()
    assert_equal(b.registry_epoch, reg.epoch())
    assert_false(reg.is_bound(b.kind_id, b.handle))
    assert_equal(reg.resident_payload_rows(), 0)

    assert_equal(bind_plan_inmem_payloads(reg, plan), 1)
    assert_true(_is_bound_here(plan, reg))
    assert_equal(Int(reg.total_mints()), 2)
    assert_equal(reg.resident_payload_rows(), 4)
    # Reclaim bumped the mint generation, so the new handle differs.
    assert_true(
        plan.scan_data_ref().source.carrier_binding_ref().handle != first_handle
    )


def test_a_handle_from_another_registry_is_replaced() raises:
    """Another epoch: the epoch half of the predicate."""
    var a = ScanRegistry()
    var b = ScanRegistry()
    # B holds a live in-memory slot at the same index and generation as the
    # one A is about to mint, so A's handle passes B's `is_bound`: only the
    # epoch tells them apart.
    var other = _inmem(16)
    assert_equal(bind_plan_inmem_payloads(b, other), 1)
    var plan = _inmem(2)
    assert_equal(bind_plan_inmem_payloads(a, plan), 1)
    ref ab = plan.scan_data_ref().source.carrier_binding_ref()
    assert_true(b.is_bound(ab.kind_id, ab.handle))
    assert_true(_is_bound_here(plan, a))
    assert_equal(bind_plan_inmem_payloads(b, plan), 1)
    assert_true(_is_bound_here(plan, b))
    assert_false(_is_bound_here(plan, a))
    assert_equal(
        plan.scan_data_ref().source.carrier_binding_ref().registry_epoch,
        b.epoch(),
    )
    # The pass binds; it releases nothing. A's slot is A's to release.
    assert_equal(a.resident_payload_rows(), 2)
    assert_equal(b.resident_payload_rows(), 18)


def test_a_non_inmem_scan_is_left_unbound() raises:
    var reg = ScanRegistry()
    var plan = _parquet()
    assert_equal(bind_plan_inmem_payloads(reg, plan), 0)
    assert_false(plan.scan_data_ref().source.has_carrier_binding())
    assert_equal(Int(reg.total_mints()), 0)


def test_a_payloadless_scan_binds_nothing() raises:
    var reg = ScanRegistry()
    var plan = LogicalPlan(PLAN_SCAN, _schema())
    assert_equal(bind_plan_inmem_payloads(reg, plan), 0)
    assert_equal(Int(reg.total_mints()), 0)


def test_a_scan_filter_is_walked() raises:
    """The pushed-down predicate can hold a subquery: a scan is not a leaf."""
    var rows = List[Int64]()
    for i in range(8):
        rows.append(Int64(i))
    var rb = RecordBatch.from_columns_1(
        _schema(), PrimitiveArray[DType.int64].from_list(rows)
    )
    var plan = LogicalPlan.scan_from_source(
        SourceVariant(InMemorySource.from_record_batch(rb^)),
        _schema(),
        filter=Optional[Expr](_subq(1)),
    )
    _walk_plan(plan, 2, 9)
    # A non-in-memory scan's filter is walked too.
    var pq = LogicalPlan.scan(
        String("t.parquet"),
        SOURCE_PARQUET,
        _schema(),
        filter=Optional[Expr](_subq(2)),
    )
    var reg = ScanRegistry()
    assert_equal(bind_plan_inmem_payloads(reg, pq), 1)
    assert_true(
        _is_bound_here(
            corr_subq_inner_plan_ref(pq.scan_data_ref().filter.value()), reg
        )
    )
    # A filter without a subquery mints nothing.
    var plain = LogicalPlan.scan(
        String("t.parquet"),
        SOURCE_PARQUET,
        _schema(),
        filter=Optional[Expr](_col()),
    )
    _walk_plan(plain, 0, 0)


# =============================================================================
# 2. Plan tags
# =============================================================================


def test_view_ref_and_cse_ref_are_leaves() raises:
    var v = LogicalPlan.view_ref(String("v"), _schema())
    _walk_plan(v, 0, 0)
    var c = LogicalPlan.cse_ref(UInt64(7), _schema())
    _walk_plan(c, 0, 0)


def test_filter_walks_predicate_and_child() raises:
    var plan = LogicalPlan.filter(_subq(1), _inmem(2))
    _walk_plan(plan, 2, 3)
    var reg = ScanRegistry()
    var p2 = LogicalPlan.filter(_col(), _inmem(4))
    assert_equal(bind_plan_inmem_payloads(reg, p2), 1)
    assert_true(_is_bound_here(p2.filter_data_ref().child[], reg))


def test_project_walks_every_expr_and_child() raises:
    var exprs = Slab[Expr].create(3)
    exprs.append(_subq(1))
    exprs.append(_col())
    exprs.append(Expr.alias(_subq(2), String("s")))
    var plan = LogicalPlan.project(exprs^, _inmem(4))
    _walk_plan(plan, 3, 7)


def test_aggregate_walks_group_keys_every_agg_slot_and_child() raises:
    var group_by = Slab[Expr].create(2)
    group_by.append(_subq(1))
    group_by.append(_col())
    var aggs = Slab[AggExpr].create(3)
    # COUNT(*): no child at all.
    aggs.append(AggExpr(AGG_COUNT, Optional[Expr](), Optional[String]()))
    # One slot.
    aggs.append(
        AggExpr(AGG_SUM, Optional[Expr](_subq(2)), Optional[String]("s"))
    )
    # All four slots, set directly: the walk reads every slot, not
    # `num_children()`.
    var four = AggExpr(AGG_SUM, Optional[Expr](_subq(4)), Optional[String]("f"))
    four.child1 = Optional[Expr](_subq(8))
    four.child2 = Optional[Expr](_subq(16))
    four.child3 = Optional[Expr](_subq(32))
    aggs.append(four^)
    var plan = LogicalPlan.aggregate(group_by^, aggs^, _inmem(64))
    _walk_plan(plan, 7, 127)


def test_a_sparse_agg_expr_is_walked_past_its_empty_slot() raises:
    """Slot 0 empty, slot 3 full: `num_children()` reads 0 here."""
    var group_by = Slab[Expr].create(1)
    var aggs = Slab[AggExpr].create(1)
    var sparse = AggExpr(AGG_SUM, Optional[Expr](), Optional[String]("x"))
    sparse.child3 = Optional[Expr](_subq(1))
    aggs.append(sparse^)
    var plan = LogicalPlan.aggregate(group_by^, aggs^, _parquet())
    _walk_plan(plan, 1, 1)


def test_single_child_nodes_without_expressions() raises:
    var keys = List[String]()
    keys.append(String("a"))
    var desc = List[Bool]()
    desc.append(False)
    var sort = LogicalPlan.sort(keys.copy(), desc.copy(), _inmem(1))
    _walk_plan(sort, 1, 1)
    var limit = LogicalPlan.limit(3, _inmem(2))
    _walk_plan(limit, 1, 2)
    var distinct = LogicalPlan.distinct(None, _inmem(4))
    _walk_plan(distinct, 1, 4)
    var topn = LogicalPlan.topn(keys.copy(), desc.copy(), 2, _inmem(8))
    _walk_plan(topn, 1, 8)
    var pby = LogicalPlan.partition_by(
        keys.copy(), keys.copy(), desc.copy(), List[PartitionExpr](), _inmem(16)
    )
    _walk_plan(pby, 1, 16)
    var ptopn = LogicalPlan.partition_topn(
        keys.copy(), keys.copy(), desc.copy(), 1, _inmem(32)
    )
    _walk_plan(ptopn, 1, 32)
    var cast = LogicalPlan.cast_to_varchar(_inmem(64))
    _walk_plan(cast, 1, 64)


def test_join_walks_both_sides_and_the_residual() raises:
    var on = List[String]()
    on.append(String("a"))
    var plan = LogicalPlan.join(
        _inmem(1),
        _inmem(2),
        on.copy(),
        on.copy(),
        JOIN_INNER,
        residual=Optional[OwnedPointer[Expr]](OwnedPointer(_subq(4))),
    )
    _walk_plan(plan, 3, 7)
    # No residual; the in-memory side is the right (build) side only.
    var reg = ScanRegistry()
    var right_only = LogicalPlan.join(
        _parquet(), _inmem(8), on.copy(), on.copy(), JOIN_INNER
    )
    assert_equal(bind_plan_inmem_payloads(reg, right_only), 1)
    assert_true(_is_bound_here(right_only.join_data_ref().right[], reg))
    assert_equal(reg.resident_payload_rows(), 8)


def test_asof_join_walks_both_sides() raises:
    var keys = List[String]()
    var plan = LogicalPlan.asof_join(
        _inmem(1),
        _inmem(2),
        keys.copy(),
        keys.copy(),
        String("a"),
        String("a"),
        ASOF_BACKWARD,
        AsofTolerance.none(),
    )
    _walk_plan(plan, 2, 3)


def test_union_walks_every_child() raises:
    var children = List[OwnedPointer[LogicalPlan]]()
    children.append(OwnedPointer(_inmem(1)))
    children.append(OwnedPointer(_parquet()))
    children.append(OwnedPointer(_inmem(4)))
    var plan = LogicalPlan.union(children^, _schema())
    _walk_plan(plan, 2, 5)


def test_a_deep_tree_is_walked_end_to_end() raises:
    """limit(sort(filter(join(scan, union(scan, scan)))))."""
    var keys = List[String]()
    keys.append(String("a"))
    var desc = List[Bool]()
    desc.append(True)
    var children = List[OwnedPointer[LogicalPlan]]()
    children.append(OwnedPointer(_inmem(2)))
    children.append(OwnedPointer(_inmem(4)))
    var u = LogicalPlan.union(children^, _schema())
    var j = LogicalPlan.join(_inmem(1), u^, keys.copy(), keys.copy(), JOIN_INNER)
    var f = LogicalPlan.filter(_subq(8), j^)
    var s = LogicalPlan.sort(keys.copy(), desc.copy(), f^)
    var plan = LogicalPlan.limit(1, s^)
    _walk_plan(plan, 4, 15)


def test_every_payloadless_plan_node_binds_nothing() raises:
    """A node whose tag has an arm but whose payload is absent is answered 0,
    not dereferenced. Every tag below `PLAN_TAG_COUNT`."""
    for t in range(PLAN_TAG_COUNT):
        var reg = ScanRegistry()
        var plan = LogicalPlan(UInt8(t), _schema())
        assert_equal(bind_plan_inmem_payloads(reg, plan), 0, String(t))
        assert_equal(Int(reg.total_mints()), 0)


def test_a_plan_tag_with_no_arm_is_refused_by_name() raises:
    var reg = ScanRegistry()
    var plan = LogicalPlan(UInt8(PLAN_TAG_COUNT), _schema())
    with assert_raises(
        contains=String(SCAN_BIND_PASS_UNMODELLED_TAG)
        + ": the in-memory bind walk has no arm for plan tag 16 (tag#16)."
    ):
        _ = bind_plan_inmem_payloads(reg, plan)
    var far = LogicalPlan(UInt8(255), _schema())
    with assert_raises(contains="plan tag 255 (tag#255). A tag with no arm"):
        _ = bind_plan_inmem_payloads(reg, far)


def test_view_and_cse_tags_are_the_two_leaf_tags() raises:
    """The `or` of the leaf arm, each operand alone (payload-less nodes)."""
    var reg = ScanRegistry()
    var v = LogicalPlan(PLAN_VIEW_REF, _schema())
    assert_equal(bind_plan_inmem_payloads(reg, v), 0)
    var c = LogicalPlan(PLAN_CSE_REF, _schema())
    assert_equal(bind_plan_inmem_payloads(reg, c), 0)


# =============================================================================
# 3. Expression tags
# =============================================================================


def test_a_correlated_subquery_binds_its_inner_plan_in_place() raises:
    var reg = ScanRegistry()
    var e = _subq(4)
    assert_equal(bind_expr_inmem_payloads(reg, e), 1)
    assert_true(_is_bound_here(corr_subq_inner_plan_ref(e), reg))
    assert_equal(reg.resident_payload_rows(), 4)


def test_nested_subqueries_are_walked() raises:
    """EXISTS(filter(EXISTS(scan 1), scan 2)): plan -> expr -> plan -> expr."""
    var refs = List[String]()
    refs.append(String("a"))
    var inner = LogicalPlan.filter(_subq(1), _inmem(2))
    var e = Expr.correlated_subquery(inner^, refs^, CORR_KIND_EXISTS)
    _walk_expr(e, 2, 3)


def test_expression_leaves_bind_nothing() raises:
    var c = _col()
    _walk_expr(c, 0, 0)
    var i = Expr.col_idx(0)
    _walk_expr(i, 0, 0)
    var l = Expr.literal(ScalarValue.from_int(1))
    _walk_expr(l, 0, 0)
    var frame = PartitionFrame(0, 0, 0, 0, 0)
    var w = Expr.window_fn(0, String("a"), 0, frame^)
    _walk_expr(w, 0, 0)


def test_one_child_expressions_descend_their_child() raises:
    var e0 = Expr.unary(UN_NOT, _subq(1))
    _walk_expr(e0, 1, 1)
    var e1 = Expr.cast(_subq(2), DType.int64)
    _walk_expr(e1, 1, 2)
    var e2 = Expr.alias(_subq(4), String("x"))
    _walk_expr(e2, 1, 4)
    var e3 = Expr.string_op(STR_CONTAINS, _subq(8), String("p"))
    _walk_expr(e3, 1, 8)
    var vals = List[ScalarValue]()
    vals.append(ScalarValue.from_int(1))
    var e4 = Expr.in_list_node(_subq(16), vals^)
    _walk_expr(e4, 1, 16)
    var e5 = Expr.agg_fn(AGG_SUM, _subq(32))
    _walk_expr(e5, 1, 32)
    var e6 = Expr.regexp_like(_subq(64), String("a.*"))
    _walk_expr(e6, 1, 64)
    var e7 = Expr.struct_field(_subq(128), String("f"))
    _walk_expr(e7, 1, 128)
    var e8 = Expr.struct_field_idx(_subq(256), 0)
    _walk_expr(e8, 1, 256)
    var e9 = Expr.json_extract_json(_subq(1), String("$.k"))
    _walk_expr(e9, 1, 1)
    var e10 = Expr.extract(EXTRACT_YEAR, _subq(2))
    _walk_expr(e10, 1, 2)
    var e11 = Expr.sqrt(_subq(4))
    _walk_expr(e11, 1, 4)
    var e12 = Expr.substring(_subq(8), 1, 2)
    _walk_expr(e12, 1, 8)
    var e13 = Expr.upper(_subq(16))
    _walk_expr(e13, 1, 16)
    var e14 = Expr.udf_call(
        String("f"), Optional[Int](0), ArrowType.INT64, ArrowType.INT64,
        _subq(32),
    )
    _walk_expr(e14, 1, 32)


def test_n_child_string_fn_walks_every_argument() raises:
    var args = List[Expr]()
    args.append(_subq(1))
    args.append(_col())
    args.append(_subq(4))
    var e = Expr.concat(args^)
    _walk_expr(e, 2, 5)


def test_two_child_expressions_descend_both_sides() raises:
    var b = Expr.binary(BIN_AND, _subq(1), _subq(2))
    _walk_expr(b, 2, 3)
    var m = Expr.atan2(_subq(4), _subq(8))
    _walk_expr(m, 2, 12)
    var g = Expr.map_get(_subq(16), _subq(32))
    _walk_expr(g, 2, 48)


def test_when_walks_every_condition_result_and_default() raises:
    var cases = List[WhenCaseData]()
    cases.append(WhenCaseData(_subq(1), _subq(2)))
    cases.append(WhenCaseData(_subq(4), _subq(8)))
    var e = Expr.when(cases^, _subq(16))
    _walk_expr(e, 5, 31)


def test_every_payloadless_expression_binds_nothing() raises:
    for t in range(EXPR_TAG_COUNT):
        var reg = ScanRegistry()
        var e = Expr(UInt8(t))
        assert_equal(bind_expr_inmem_payloads(reg, e), 0, String(t))
        assert_equal(Int(reg.total_mints()), 0)


def test_an_expression_tag_with_no_arm_is_refused_by_name() raises:
    var reg = ScanRegistry()
    var e = Expr(UInt8(EXPR_TAG_COUNT))
    with assert_raises(
        contains=String(SCAN_BIND_PASS_UNMODELLED_EXPR_TAG)
        + ": the in-memory bind walk has no arm for expression tag 27 (tag#27)."
    ):
        _ = bind_expr_inmem_payloads(reg, e)
    # The refusal reaches the caller of the PLAN walk through a filter.
    var plan = LogicalPlan.filter(Expr(UInt8(200)), _parquet())
    with assert_raises(contains="expression tag 200 (tag#200). EXPR_CORRELATED"):
        _ = bind_plan_inmem_payloads(reg, plan)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
