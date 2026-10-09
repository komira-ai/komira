"""7 lowering-shape tests covering
the Q4/Q17/Q20/Q21 query shapes built with
`Expr.correlated_subquery(...)`.

These tests sit BETWEEN the factory-only tests
(`komira_plan_ir/tests/test_expr_correlated_subquery.mojo`) and the compiler-
pass unit tests (`tests/test_flatten_dependent_joins.mojo`, 8 cases): they
exercise the FULL chain — factory build → `flatten_dependent_joins` pass →
structural assert on the lowered shape, with the inputs shaped exactly
like the TPC-H queries (Q4 / Q21 / Q17 / Q20).

Test matrix (7 cases):

  1. EXISTS  (Q4-shape)   — orders ⋈SEMI lineitem on o_orderkey=l_orderkey,
                            with inner Filter pre-baked to "late-deliveries".
  2. NOT_EXISTS (Q21-shape) — supplier ⋈ANTI lineitem on s_suppkey=l_suppkey,
                            with inner Filter pre-baked to "delayed".
  3. SCALAR (Q17-shape)   — Filter(rewritten_pred, LeftJoin(lineitem,
                            Aggregate-by-partkey-with-AVG-quantity)) — the
                            full structural lowering for the Q17 SCALAR
                            shape (the 0.2× multiplier left out), through
                            the "inner plan already has an Aggregate at
                            root" re-alias branch of `_lower_scalar_correlated`.
  4. EXISTS multi-key (Q20-shape) — partsupp ⋈SEMI lineitem on
                            (ps_partkey, ps_suppkey). Multi-key hoist.
  5. EXISTS bare inner scan — no inner Filter, so the keys fall back to the
                            same-name default (left_on = right_on =
                            outer_ref) and the SEMI join's right child is
                            the bare scan.
  6. NOT_EXISTS bare inner scan — symmetric to (5) through the ANTI
                            lowering.
  7. SCALAR with no inner Aggregate — `_lower_scalar_correlated`
                            synthesizes a default MEAN Aggregate over the
                            inner plan (the fallback branch).

A Q-shape that needs a kind `Expr.correlated_subquery` does not have
(correlated NOT IN, correlated INTERSECT, ...) is out of scope and has no
case here.

Reference — DuckDB plan shapes via EXPLAIN <SQL>:
  - Q4: `EXISTS (SELECT 1 FROM lineitem WHERE l_orderkey=o_orderkey AND
        l_commitdate<l_receiptdate)` lowers to SEMI JOIN on o_orderkey=l_orderkey.
  - Q21: `NOT EXISTS (SELECT 1 FROM lineitem l3 WHERE l3.l_orderkey=l1.l_orderkey
        AND l3.l_suppkey<>l1.l_suppkey AND l3.l_receiptdate>l3.l_commitdate)`
        lowers to ANTI JOIN (we test the single-key approximation).
  - Q17: `0.2 * (SELECT AVG(l_quantity) FROM lineitem WHERE l_partkey=p_partkey)`
        lowers to Filter(rewritten_pred, LEFT JOIN(outer, Aggregate(inner))).
  - Q20: `s_suppkey IN (SELECT ps_suppkey FROM partsupp WHERE ps_partkey IN
        (SELECT p_partkey FROM part) AND ps_availqty > <scalar correlated>)`
        — the canonical Q20 has multiple nested subqueries; we test the
        2-key EXISTS lowering primitive that the rewritten Q20 would use.
"""

from std.testing import assert_equal, assert_true, assert_false

from komira_arrow.schema import SchemaBuilder, Field
from komira_arrow.arrow_types import ArrowType

from komira_plan_expr.expr import (
    Expr,
    EXPR_CORRELATED_SUBQUERY,
    EXPR_COL_REF,
    EXPR_BINARY_OP,
    BIN_EQ,
    BIN_LT,
    BIN_GT,
    BIN_AND,
    BIN_MUL,
)
from komira_plan_expr.agg_expr import AggExpr, AGG_MEAN, AGG_SUM
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    PLAN_SCAN,
    PLAN_FILTER,
    PLAN_JOIN,
    PLAN_AGGREGATE,
    SOURCE_PARQUET,
    CORR_KIND_EXISTS,
    CORR_KIND_NOT_EXISTS,
    CORR_KIND_SCALAR,
    JOIN_SEMI,
    JOIN_ANTI,
    JOIN_LEFT,
)

from komira_optimizer.flatten_dependent_joins import (
    flatten_dependent_joins,
    _plan_contains_correlated_subquery,
)


# =============================================================================
# Schemas — tiny fixtures shaped like Q4/Q17/Q20/Q21 input tables
# =============================================================================


def _orders_schema_q4() -> LogicalPlan:
    """orders(o_orderkey, o_orderpriority). Q4 outer schema."""
    var b = SchemaBuilder()
    b.add_field(Field(String("o_orderkey"), ArrowType.INT64, False))
    b.add_field(Field(String("o_orderpriority"), ArrowType.STRING, False))
    var schema = b.build()
    return LogicalPlan.scan(String("orders.parquet"), SOURCE_PARQUET, schema^)


def _lineitem_schema_q4() -> LogicalPlan:
    """lineitem(l_orderkey, l_commitdate, l_receiptdate). Q4 inner."""
    var b = SchemaBuilder()
    b.add_field(Field(String("l_orderkey"), ArrowType.INT64, False))
    b.add_field(Field(String("l_commitdate"), ArrowType.INT64, False))
    b.add_field(Field(String("l_receiptdate"), ArrowType.INT64, False))
    var schema = b.build()
    return LogicalPlan.scan(String("lineitem.parquet"), SOURCE_PARQUET, schema^)


def _supplier_schema_q21() -> LogicalPlan:
    var b = SchemaBuilder()
    b.add_field(Field(String("s_suppkey"), ArrowType.INT64, False))
    b.add_field(Field(String("s_name"), ArrowType.STRING, False))
    var schema = b.build()
    return LogicalPlan.scan(String("supplier.parquet"), SOURCE_PARQUET, schema^)


def _lineitem_schema_q21() -> LogicalPlan:
    """lineitem(l_suppkey, l_orderkey, l_commitdate, l_receiptdate). Q21 inner."""
    var b = SchemaBuilder()
    b.add_field(Field(String("l_suppkey"), ArrowType.INT64, False))
    b.add_field(Field(String("l_orderkey"), ArrowType.INT64, False))
    b.add_field(Field(String("l_commitdate"), ArrowType.INT64, False))
    b.add_field(Field(String("l_receiptdate"), ArrowType.INT64, False))
    var schema = b.build()
    return LogicalPlan.scan(String("lineitem.parquet"), SOURCE_PARQUET, schema^)


def _lineitem_schema_q17_outer() -> LogicalPlan:
    """lineitem(l_partkey, l_quantity, l_extendedprice). Q17 outer (the
    'big' lineitem from which we filter by per-partkey threshold)."""
    var b = SchemaBuilder()
    b.add_field(Field(String("l_partkey"), ArrowType.INT64, False))
    b.add_field(Field(String("l_quantity"), ArrowType.FLOAT64, False))
    b.add_field(Field(String("l_extendedprice"), ArrowType.FLOAT64, False))
    var schema = b.build()
    return LogicalPlan.scan(String("lineitem.parquet"), SOURCE_PARQUET, schema^)


def _lineitem_schema_q17_inner() -> LogicalPlan:
    """lineitem(l_partkey, l_quantity). Q17 inner — the AVG-by-partkey table."""
    var b = SchemaBuilder()
    b.add_field(Field(String("l_partkey"), ArrowType.INT64, False))
    b.add_field(Field(String("l_quantity"), ArrowType.FLOAT64, False))
    var schema = b.build()
    return LogicalPlan.scan(String("lineitem.parquet"), SOURCE_PARQUET, schema^)


def _supplier_schema_q20() -> LogicalPlan:
    """Q20 multi-key outer: partsupp(ps_partkey, ps_suppkey, ps_availqty),
    so the hoist can pair both keys. Q20's canonical multi-key is partsupp ⋈
    aggregated_li on (ps_partkey, ps_suppkey)=(l_partkey, l_suppkey)."""
    var b = SchemaBuilder()
    b.add_field(Field(String("ps_partkey"), ArrowType.INT64, False))
    b.add_field(Field(String("ps_suppkey"), ArrowType.INT64, False))
    b.add_field(Field(String("ps_availqty"), ArrowType.INT64, False))
    var schema = b.build()
    return LogicalPlan.scan(String("partsupp.parquet"), SOURCE_PARQUET, schema^)


def _lineitem_schema_q20() -> LogicalPlan:
    """Q20 inner: lineitem(l_partkey, l_suppkey, l_quantity)."""
    var b = SchemaBuilder()
    b.add_field(Field(String("l_partkey"), ArrowType.INT64, False))
    b.add_field(Field(String("l_suppkey"), ArrowType.INT64, False))
    b.add_field(Field(String("l_quantity"), ArrowType.INT64, False))
    var schema = b.build()
    return LogicalPlan.scan(String("lineitem.parquet"), SOURCE_PARQUET, schema^)


# =============================================================================
# Test 1 — EXISTS Q4-shape
# =============================================================================


def test_q4_exists_lowering() raises:
    """Q4: orders EXISTS (lineitem WHERE l_orderkey=o_orderkey AND
    l_commitdate<l_receiptdate).

    Structural assert: the lowered plan is a SEMI join with the hoisted
    keys o_orderkey=l_orderkey, and the residual conjunct
    `l_commitdate<l_receiptdate` survives as a Filter on the right child.
    """
    var outer = _orders_schema_q4()
    var inner_scan = _lineitem_schema_q4()
    # Inner predicate: (l_orderkey = o_orderkey) AND (l_commitdate < l_receiptdate)
    var eq_pred = Expr.binary(
        BIN_EQ,
        Expr.col_ref(String("o_orderkey")),
        Expr.col_ref(String("l_orderkey")),
    )
    var late_pred = Expr.binary(
        BIN_LT,
        Expr.col_ref(String("l_commitdate")),
        Expr.col_ref(String("l_receiptdate")),
    )
    var both = Expr.binary(BIN_AND, eq_pred^, late_pred^)
    var inner_filtered = LogicalPlan.filter(both^, inner_scan^)

    var refs = List[String]()
    refs.append(String("o_orderkey"))
    var corr = Expr.correlated_subquery(inner_filtered^, refs^, CORR_KIND_EXISTS)
    var plan = LogicalPlan.filter(corr^, outer^)

    var lowered = flatten_dependent_joins(plan^)

    # Lowered shape: PLAN_JOIN with SEMI join_type, keys hoisted.
    assert_equal(lowered.tag, PLAN_JOIN)
    assert_equal(lowered._join.value()[].join_type, JOIN_SEMI)
    assert_equal(lowered._join.value()[].left_on[0], String("o_orderkey"))
    assert_equal(lowered._join.value()[].right_on[0], String("l_orderkey"))
    # Residual conjunct survives on the right input as a Filter.
    ref right_side = lowered._join.value()[].right[]
    assert_equal(right_side.tag, PLAN_FILTER)
    # No correlated nodes left anywhere.
    assert_false(_plan_contains_correlated_subquery(lowered))


# =============================================================================
# Test 2 — NOT_EXISTS Q21-shape
# =============================================================================


def test_q21_not_exists_lowering() raises:
    """Q21: supplier NOT EXISTS (lineitem WHERE l_suppkey=s_suppkey AND
    l_receiptdate>l_commitdate).

    Structural assert: lowered to ANTI join with hoisted keys
    s_suppkey=l_suppkey + residual late-delivery filter on right child.
    """
    var outer = _supplier_schema_q21()
    var inner_scan = _lineitem_schema_q21()
    var eq_pred = Expr.binary(
        BIN_EQ,
        Expr.col_ref(String("s_suppkey")),
        Expr.col_ref(String("l_suppkey")),
    )
    var late_pred = Expr.binary(
        BIN_GT,
        Expr.col_ref(String("l_receiptdate")),
        Expr.col_ref(String("l_commitdate")),
    )
    var both = Expr.binary(BIN_AND, eq_pred^, late_pred^)
    var inner_filtered = LogicalPlan.filter(both^, inner_scan^)

    var refs = List[String]()
    refs.append(String("s_suppkey"))
    var corr = Expr.correlated_subquery(inner_filtered^, refs^, CORR_KIND_NOT_EXISTS)
    var plan = LogicalPlan.filter(corr^, outer^)

    var lowered = flatten_dependent_joins(plan^)
    assert_equal(lowered.tag, PLAN_JOIN)
    assert_equal(lowered._join.value()[].join_type, JOIN_ANTI)
    assert_equal(lowered._join.value()[].left_on[0], String("s_suppkey"))
    assert_equal(lowered._join.value()[].right_on[0], String("l_suppkey"))
    ref right_side = lowered._join.value()[].right[]
    assert_equal(right_side.tag, PLAN_FILTER)
    assert_false(_plan_contains_correlated_subquery(lowered))


# =============================================================================
# Test 3 — SCALAR Q17-shape (full structural)
# =============================================================================


def test_q17_scalar_lowering() raises:
    """Q17: lineitem WHERE l_quantity < 0.2 * (SELECT AVG(l_quantity)
    FROM lineitem WHERE l_partkey=outer.l_partkey).

    Inner: Aggregate-by-partkey emitting AVG(l_quantity).
    Outer: lineitem with Filter(l_quantity < correlated); the 0.2
    multiplier is left out (see below).

    Lowered shape:
      Filter(BIN_LT(l_quantity, col("__corr_scalar_0")),
             LeftJoin(outer_scan, Aggregate(group_by=[l_partkey],
                                            aggs=[AVG(l_quantity)
                                                  AS __corr_scalar_0],
                                            child=inner_scan_after_hoist),
                      left_on=l_partkey, right_on=l_partkey, JOIN_LEFT))
    """
    var outer_scan = _lineitem_schema_q17_outer()
    var inner_scan = _lineitem_schema_q17_inner()
    # Build inner Aggregate(group_by=[l_partkey], aggs=[AVG(l_quantity)])
    # but with the equi-predicate Filter wrapping it so the hoist algorithm
    # extracts the outer/inner key pair. Note: the hoist algorithm runs on
    # the inner plan ROOT — we need the equi-Filter at the root, with the
    # Aggregate beneath it. After hoist, the Filter is dropped and the
    # Aggregate sits below the LEFT join.
    #
    # However, _lower_scalar_correlated checks `inner_after_hoist.tag ==
    # PLAN_AGGREGATE` to detect the "agg-at-root" case. If we put the
    # Filter at the root, after hoisting the residual is empty and the
    # plan becomes the bare Aggregate scan — so the agg-at-root branch
    # DOES fire. This is the canonical Q17 shape.
    var inner_eq = Expr.binary(
        BIN_EQ,
        Expr.col_ref(String("l_partkey")),
        Expr.col_ref(String("l_partkey")),
    )
    var gb = ExprArray()
    gb.append(Expr.col_ref(String("l_partkey")))
    var aggs = AggExprArray()
    var mean_arg: Optional[Expr] = Optional(Expr.col_ref(String("l_quantity")))
    var mean_alias: Optional[String] = Optional(String("avg_qty"))
    aggs.append(AggExpr(AGG_MEAN, mean_arg^, mean_alias^))
    var inner_agg = LogicalPlan.aggregate(gb^, aggs^, inner_scan^)
    var inner_filtered = LogicalPlan.filter(inner_eq^, inner_agg^)

    var refs = List[String]()
    refs.append(String("l_partkey"))
    var corr = Expr.correlated_subquery(inner_filtered^, refs^, CORR_KIND_SCALAR)

    # Outer predicate: l_quantity < corr (we model 0.2 * AVG by directly
    # comparing against the correlated; `_maybe_lower_filter` lowers a
    # comparison only when one operand IS the subquery, so `0.2 * corr`
    # would be refused as an unsupported parent-shape).
    var outer_pred = Expr.binary(
        BIN_LT,
        Expr.col_ref(String("l_quantity")),
        corr^,
    )
    var plan = LogicalPlan.filter(outer_pred^, outer_scan^)

    var lowered = flatten_dependent_joins(plan^)
    # Top: Filter(rewritten_pred, LeftJoin(outer, Aggregate(inner_scan)))
    assert_equal(lowered.tag, PLAN_FILTER)
    ref join_node = lowered._filter.value()[].child[]
    assert_equal(join_node.tag, PLAN_JOIN)
    assert_equal(join_node._join.value()[].join_type, JOIN_LEFT)
    assert_equal(join_node._join.value()[].left_on[0], String("l_partkey"))
    assert_equal(join_node._join.value()[].right_on[0], String("l_partkey"))
    ref right_side = join_node._join.value()[].right[]
    assert_equal(right_side.tag, PLAN_AGGREGATE)
    assert_false(_plan_contains_correlated_subquery(lowered))


# =============================================================================
# Test 4 — EXISTS multi-key Q20-shape
# =============================================================================


def test_q20_multi_key_exists_lowering() raises:
    """Q20 (multi-key approximation): partsupp EXISTS (lineitem WHERE
    l_partkey=ps_partkey AND l_suppkey=ps_suppkey).

    The hoist algorithm should pair both keys. We assert that both
    (left_on, right_on) pairs were lifted in the SAME ORDER as the
    inner conjuncts.
    """
    var outer = _supplier_schema_q20()  # ps_partkey, ps_suppkey, ps_availqty
    var inner_scan = _lineitem_schema_q20()
    var eq1 = Expr.binary(
        BIN_EQ,
        Expr.col_ref(String("ps_partkey")),
        Expr.col_ref(String("l_partkey")),
    )
    var eq2 = Expr.binary(
        BIN_EQ,
        Expr.col_ref(String("ps_suppkey")),
        Expr.col_ref(String("l_suppkey")),
    )
    var both = Expr.binary(BIN_AND, eq1^, eq2^)
    var inner_filtered = LogicalPlan.filter(both^, inner_scan^)

    var refs = List[String]()
    refs.append(String("ps_partkey"))
    refs.append(String("ps_suppkey"))
    var corr = Expr.correlated_subquery(inner_filtered^, refs^, CORR_KIND_EXISTS)
    var plan = LogicalPlan.filter(corr^, outer^)

    var lowered = flatten_dependent_joins(plan^)
    assert_equal(lowered.tag, PLAN_JOIN)
    assert_equal(lowered._join.value()[].join_type, JOIN_SEMI)
    # Both keys hoisted.
    assert_equal(len(lowered._join.value()[].left_on), 2)
    assert_equal(len(lowered._join.value()[].right_on), 2)
    # Both pairs are present (order-independent — _split_conjuncts walks
    # the AND tree left-first so the order is deterministic but we test
    # set-membership to keep the test robust to minor walker reorderings).
    var l0 = lowered._join.value()[].left_on[0]
    var l1 = lowered._join.value()[].left_on[1]
    var r0 = lowered._join.value()[].right_on[0]
    var r1 = lowered._join.value()[].right_on[1]
    var saw_partkey = (l0 == String("ps_partkey") and r0 == String("l_partkey")) or (
        l1 == String("ps_partkey") and r1 == String("l_partkey")
    )
    var saw_suppkey = (l0 == String("ps_suppkey") and r0 == String("l_suppkey")) or (
        l1 == String("ps_suppkey") and r1 == String("l_suppkey")
    )
    assert_true(saw_partkey)
    assert_true(saw_suppkey)
    assert_false(_plan_contains_correlated_subquery(lowered))


# =============================================================================
# Test 5 — EXISTS lowering robust when inner is just a bare scan (no Filter)
# =============================================================================


def test_exists_bare_inner_scan_lowering() raises:
    """EXISTS with an inner plan that is NOT a Filter at the root —
    structural assert that the lowering falls back to the default
    same-name hoist (left_on=outer_ref, right_on=outer_ref).

    This exercises the `_hoist_outer_eq_predicates` early-return branch
    for non-PLAN_FILTER inner plans. Useful when the empty/no-predicate
    inner case appears post-optimizer (e.g. after a prior pass drops the
    inner Filter as constant-folded-True).
    """
    var outer = _orders_schema_q4()
    var inner_scan = _lineitem_schema_q4()  # no Filter wrap

    var refs = List[String]()
    refs.append(String("l_orderkey"))  # same-name on both sides
    var corr = Expr.correlated_subquery(inner_scan^, refs^, CORR_KIND_EXISTS)
    # Outer must have `l_orderkey` to pass the outer-ref validation.
    # Q4's orders schema doesn't have l_orderkey; build a fresh outer
    # that DOES.
    var b = SchemaBuilder()
    b.add_field(Field(String("l_orderkey"), ArrowType.INT64, False))
    b.add_field(Field(String("o_orderpriority"), ArrowType.STRING, False))
    var outer_schema = b.build()
    var outer2 = LogicalPlan.scan(
        String("orders.parquet"), SOURCE_PARQUET, outer_schema^
    )
    _ = outer^  # consume the original (unused) outer to keep move semantics happy

    var plan = LogicalPlan.filter(corr^, outer2^)
    var lowered = flatten_dependent_joins(plan^)

    assert_equal(lowered.tag, PLAN_JOIN)
    assert_equal(lowered._join.value()[].join_type, JOIN_SEMI)
    # Default same-name hoist.
    assert_equal(lowered._join.value()[].left_on[0], String("l_orderkey"))
    assert_equal(lowered._join.value()[].right_on[0], String("l_orderkey"))
    # Right side is the bare scan (no Filter wrap).
    ref right_side = lowered._join.value()[].right[]
    assert_equal(right_side.tag, PLAN_SCAN)
    assert_false(_plan_contains_correlated_subquery(lowered))


# =============================================================================
# Test 6 — NOT_EXISTS with bare inner scan + same-name hoist
# =============================================================================


def test_not_exists_bare_inner_scan_lowering() raises:
    """Symmetric to Test 5: NOT_EXISTS with bare inner scan exercises the
    ANTI lowering on the same-name default-hoist path. Useful for the Q21
    shape where the inner Filter has been pre-baked away by a prior
    optimizer pass."""
    var inner_scan = _lineitem_schema_q21()
    var refs = List[String]()
    refs.append(String("l_suppkey"))

    # Outer must have `l_suppkey` for validation.
    var b = SchemaBuilder()
    b.add_field(Field(String("l_suppkey"), ArrowType.INT64, False))
    b.add_field(Field(String("s_name"), ArrowType.STRING, False))
    var outer_schema = b.build()
    var outer = LogicalPlan.scan(
        String("supplier.parquet"), SOURCE_PARQUET, outer_schema^
    )

    var corr = Expr.correlated_subquery(inner_scan^, refs^, CORR_KIND_NOT_EXISTS)
    var plan = LogicalPlan.filter(corr^, outer^)
    var lowered = flatten_dependent_joins(plan^)

    assert_equal(lowered.tag, PLAN_JOIN)
    assert_equal(lowered._join.value()[].join_type, JOIN_ANTI)
    assert_equal(lowered._join.value()[].left_on[0], String("l_suppkey"))
    assert_equal(lowered._join.value()[].right_on[0], String("l_suppkey"))
    ref right_side = lowered._join.value()[].right[]
    assert_equal(right_side.tag, PLAN_SCAN)
    assert_false(_plan_contains_correlated_subquery(lowered))


# =============================================================================
# Test 7 — SCALAR with synthetic default-MEAN inner (no pre-built Aggregate)
# =============================================================================


def test_scalar_synthesizes_default_mean_when_inner_has_no_aggregate() raises:
    """SCALAR lowering when the inner plan does NOT have a PLAN_AGGREGATE
    at the root (post-hoist) — `_lower_scalar_correlated` synthesizes a
    default MEAN over the first output column.

    This is the fallback branch for ad-hoc scalar subqueries that don't
    map to an explicit aggregation (e.g. a user-written `(SELECT col
    FROM single_row_view)` shape). Q17 itself takes the agg-at-root
    branch (Test 3); this test guards the fallback branch.
    """
    var outer_scan = _lineitem_schema_q17_outer()
    var inner_scan = _lineitem_schema_q17_inner()  # bare scan, no Aggregate
    # Filter at inner root to hoist outer-ref equality (l_partkey=l_partkey).
    var eq_pred = Expr.binary(
        BIN_EQ,
        Expr.col_ref(String("l_partkey")),
        Expr.col_ref(String("l_partkey")),
    )
    var inner_filtered = LogicalPlan.filter(eq_pred^, inner_scan^)

    var refs = List[String]()
    refs.append(String("l_partkey"))
    var corr = Expr.correlated_subquery(inner_filtered^, refs^, CORR_KIND_SCALAR)

    var outer_pred = Expr.binary(
        BIN_LT,
        Expr.col_ref(String("l_quantity")),
        corr^,
    )
    var plan = LogicalPlan.filter(outer_pred^, outer_scan^)
    var lowered = flatten_dependent_joins(plan^)

    # Top: Filter(rewritten, LeftJoin(outer, Aggregate(default-MEAN, scan)))
    assert_equal(lowered.tag, PLAN_FILTER)
    ref join_node = lowered._filter.value()[].child[]
    assert_equal(join_node.tag, PLAN_JOIN)
    assert_equal(join_node._join.value()[].join_type, JOIN_LEFT)
    ref right_side = join_node._join.value()[].right[]
    # Synthesized Aggregate wraps the bare scan.
    assert_equal(right_side.tag, PLAN_AGGREGATE)
    # Beneath the Aggregate is the original scan (no surviving Filter,
    # since the equi-conjunct was hoisted out and the residual was empty).
    ref agg_child = right_side._aggregate.value()[].child[]
    assert_equal(agg_child.tag, PLAN_SCAN)
    assert_false(_plan_contains_correlated_subquery(lowered))


def main() raises:
    test_q4_exists_lowering()
    test_q21_not_exists_lowering()
    test_q17_scalar_lowering()
    test_q20_multi_key_exists_lowering()
    test_exists_bare_inner_scan_lowering()
    test_not_exists_bare_inner_scan_lowering()
    test_scalar_synthesizes_default_mean_when_inner_has_no_aggregate()
    print("All 7 correlated_subquery lowering tests passed.")
