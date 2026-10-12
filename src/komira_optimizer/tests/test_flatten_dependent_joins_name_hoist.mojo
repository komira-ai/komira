"""`flatten_dependent_joins`: no conjunct that reads an outer column stays in
the inner Filter, on either hoist path.

A correlated subquery whose inner plan is a Filter has its conjuncts split
between the inner side, the join keys and the join residual. A conjunct left
on the inner side is evaluated over the inner scan alone, where an outer
column does not exist, and the correlation is silently dropped from the join
(komira-ai/komira#1354). These tests build each shape that once took that
route and check where the conjunct lands, or that the shape is refused:

  * the plain-name (`Expr.col_ref`) path: a non-equality correlation becomes
    the residual (EXISTS, NOT EXISTS, and through `optimize`); an equality of
    two outer columns is a residual, not a key; with no equality the join has
    no keys; a name both sides produce is refused (also after an outer-only
    name in the same conjunct); an outer reference inside a CASE is marked
    LEFT in the residual; a correlation under an expression kind the hoist
    does not descend is refused; a scalar subquery with a non-equality
    correlation is refused;
  * the side-qualified (`Expr.left`) path: an outer reference under a CASE
    becomes the residual (with and without a side-qualified sibling), and one
    under a kind the hoist does not descend is refused.

Each test names the defect it catches.
"""

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.expr import (
    Expr,
    WhenCaseData,
    BIN_EQ,
    BIN_NE,
    BIN_GT,
    BIN_AND,
    MATH_SQRT,
    COL_SIDE_LEFT,
    COL_SIDE_RIGHT,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    SOURCE_PARQUET,
    CORR_KIND_EXISTS,
    CORR_KIND_NOT_EXISTS,
    CORR_KIND_SCALAR,
    PLAN_SCAN,
    PLAN_JOIN,
    JOIN_SEMI,
    JOIN_ANTI,
)
from komira_optimizer.flatten_dependent_joins import flatten_dependent_joins
from komira_optimizer.optimizer_config import OptimizerConfig
from komira_optimizer.optimizer_scalar_deps import ScalarDepTable
from komira_optimizer.optimizer_driver import optimize


# -----------------------------------------------------------------------------
# Fixtures
# -----------------------------------------------------------------------------


def _schema(names: List[String]) -> Schema:
    var sb = SchemaBuilder()
    for i in range(len(names)):
        sb.add_field(Field(names[i], ArrowType.INT64, False))
    return sb.build()


def _scan(path: String, names: List[String], rows: Int) -> LogicalPlan:
    return LogicalPlan.scan(path, SOURCE_PARQUET, _schema(names), None, None, rows)


def _customer() -> LogicalPlan:
    var cn: List[String] = ["c_custkey", "c_v"]
    return _scan("customer.parquet", cn, 10)


def _orders() -> LogicalPlan:
    var on: List[String] = ["o_orderkey", "o_custkey", "o_v"]
    return _scan("orders.parquet", on, 100000)


def _c(n: String) -> Expr:
    return Expr.col_ref(n)


def _lit(v: Int) -> Expr:
    return Expr.literal(ScalarValue.from_int(v))


def _and(var a: Expr, var b: Expr) -> Expr:
    return Expr.binary(BIN_AND, a^, b^)


def _both_refs() -> List[String]:
    var r: List[String] = ["c_custkey", "c_v"]
    return r^


def _exists_over_customer(var pred: Expr, kind: UInt8, var refs: List[String]) -> LogicalPlan:
    """`Filter(<kind> (Filter(pred, orders)), customer)`."""
    var inner = LogicalPlan.filter(pred^, _orders())
    var corr = Expr.correlated_subquery(inner^, refs^, kind)
    return LogicalPlan.filter(corr^, _customer())


def _plain_key_and_gt() -> Expr:
    """`o_custkey = c_custkey AND o_v > c_v`, every ref a plain name."""
    return _and(
        Expr.binary(BIN_EQ, _c("o_custkey"), _c("c_custkey")),
        Expr.binary(BIN_GT, _c("o_v"), _c("c_v")),
    )


def _case_on_left_c_v() -> Expr:
    """`CASE WHEN left.c_v > 0 THEN o_v ELSE 0 END > 1`: the outer
    reference sits only inside the CASE condition."""
    var cases = List[WhenCaseData]()
    cases.append(WhenCaseData(Expr.binary(BIN_GT, Expr.left("c_v"), _lit(0)), _c("o_v")))
    return Expr.binary(BIN_GT, Expr.when(cases^, _lit(0)), _lit(1))


def _render(p: LogicalPlan) -> String:
    var s = String("")
    p.write_to(s)
    return s^


def _raises_with(var plan: LogicalPlan, needle: String) raises -> Bool:
    try:
        _ = flatten_dependent_joins(plan^)
    except e:
        return String(e).find(needle) >= 0
    return False


def _assert_gt_residual_o_v_c_v(j: LogicalPlan) raises:
    """The join's residual is `right.o_v > left.c_v` and its right child is
    the bare orders scan (no Filter left on the inner side)."""
    ref jn = j._join.value()[]
    assert_equal(jn.right[].tag, PLAN_SCAN)
    assert_true(jn.has_residual())
    ref r = jn.residual.value()[]
    assert_equal(r.binary_op(), BIN_GT)
    assert_equal(r.binary_left_ref().col_ref_name(), String("o_v"))
    assert_equal(r.binary_left_ref().col_ref_side(), COL_SIDE_RIGHT)
    assert_equal(r.binary_right_ref().col_ref_name(), String("c_v"))
    assert_equal(r.binary_right_ref().col_ref_side(), COL_SIDE_LEFT)


# -----------------------------------------------------------------------------
# The plain-name path
# -----------------------------------------------------------------------------


def test_plain_name_non_equi_correlation_becomes_the_residual() raises:
    """The komira-ai/komira#1354 reproducer: `o_custkey = c_custkey AND
    o_v > c_v` with plain names. The equality is the SEMI key; `o_v > c_v`
    is the residual with `c_v` LEFT and `o_v` RIGHT; the orders scan has no
    Filter. The NOT EXISTS form gives the same ANTI join.

    Catches: the non-equality left in a Filter over orders, which names
    `c_v`, a customer column (the correlation dropped from the join); the
    outer name marked RIGHT, so the residual reads the inner side twice."""
    var out = flatten_dependent_joins(
        _exists_over_customer(_plain_key_and_gt(), CORR_KIND_EXISTS, _both_refs())
    )
    assert_equal(out.tag, PLAN_JOIN)
    assert_equal(out._join.value()[].join_type, JOIN_SEMI)
    assert_equal(len(out._join.value()[].left_on), 1)
    assert_equal(out._join.value()[].left_on[0], String("c_custkey"))
    assert_equal(out._join.value()[].right_on[0], String("o_custkey"))
    _assert_gt_residual_o_v_c_v(out)

    var anti = flatten_dependent_joins(
        _exists_over_customer(_plain_key_and_gt(), CORR_KIND_NOT_EXISTS, _both_refs())
    )
    assert_equal(anti._join.value()[].join_type, JOIN_ANTI)
    _assert_gt_residual_o_v_c_v(anti)


def test_plain_name_correlation_through_optimize_matches_the_side_qualified_plan() raises:
    """`optimize` (default config) on the reproducer gives the plan the same
    query written with `Expr.left` outer refs gives: a SEMI join with the
    `o_v > c_v` residual over a pruned orders scan.

    Catches: `Filter(o_v > c_v)` over `orders.parquet` with projection
    `[o_custkey, o_v]` (the plan the issue reports)."""
    var want: List[String] = [
        "Join(type=SEMI, on=[c_custkey=o_custkey], residual=BinaryOp(GT, ColRef(o_v), ColRef(c_v)))",
        "  Scan(path=\"customer.parquet\", type=PARQUET, source_kind=COLUMNAR)",
        "  Scan(path=\"orders.parquet\", type=PARQUET, source_kind=COLUMNAR, projection=[o_custkey, o_v])",
    ]
    var s = String("")
    for i in range(len(want)):
        s += want[i] + "\n"
    var deps = ScalarDepTable()
    var plan = _exists_over_customer(_plain_key_and_gt(), CORR_KIND_EXISTS, _both_refs())
    assert_equal(_render(optimize(plan^, OptimizerConfig(), deps)), s)


def test_plain_name_equality_of_two_outer_columns_is_not_a_key() raises:
    """`o_custkey = c_custkey AND c_custkey = c_v`: only the first is a key;
    `c_custkey = c_v` reads no inner column and becomes the residual with
    both refs LEFT.

    Catches: `c_custkey = c_v` hoisted as the key pair (c_custkey, c_v),
    which joins on `c_v`, a column the orders side does not produce."""
    var pred = _and(
        Expr.binary(BIN_EQ, _c("o_custkey"), _c("c_custkey")),
        Expr.binary(BIN_EQ, _c("c_custkey"), _c("c_v")),
    )
    var out = flatten_dependent_joins(_exists_over_customer(pred^, CORR_KIND_EXISTS, _both_refs()))
    ref j = out._join.value()[]
    assert_equal(len(j.left_on), 1)
    assert_equal(j.left_on[0], String("c_custkey"))
    assert_equal(j.right_on[0], String("o_custkey"))
    assert_equal(j.right[].tag, PLAN_SCAN)
    assert_true(j.has_residual())
    ref r = j.residual.value()[]
    assert_equal(r.binary_op(), BIN_EQ)
    assert_equal(r.binary_left_ref().col_ref_side(), COL_SIDE_LEFT)
    assert_equal(r.binary_right_ref().col_ref_side(), COL_SIDE_LEFT)


def test_plain_name_correlation_without_an_equality_has_no_keys() raises:
    """`o_v > c_v` alone, correlated on `c_v`: no key, the residual carries
    the correlation.

    Catches: the keys defaulted to the outer refs (`c_v = c_v`), a key on a
    column orders does not produce, with the correlation kept in the inner
    Filter."""
    var refs: List[String] = ["c_v"]
    var out = flatten_dependent_joins(
        _exists_over_customer(Expr.binary(BIN_GT, _c("o_v"), _c("c_v")), CORR_KIND_EXISTS, refs^)
    )
    assert_equal(len(out._join.value()[].left_on), 0)
    assert_equal(len(out._join.value()[].right_on), 0)
    _assert_gt_residual_o_v_c_v(out)


def test_plain_name_on_both_sides_is_refused() raises:
    """lineitem EXISTS (lineitem WHERE l_suppkey <> l_suppkey) correlated on
    `l_suppkey`: both sides produce `l_suppkey`, so a plain name cannot say
    which one each operand reads. Refused with FlattenAmbiguousOuterRef.

    Catches: the conjunct kept on the inner side, where both operands read
    the inner column (`l_suppkey <> l_suppkey`, never true for a non-null
    row) and the correlation is dropped (the TPC-H Q21 shape)."""
    var ln: List[String] = ["l_orderkey", "l_suppkey"]
    var inner = LogicalPlan.filter(
        _and(
            Expr.binary(BIN_EQ, _c("l_orderkey"), _c("l_orderkey")),
            Expr.binary(BIN_NE, _c("l_suppkey"), _c("l_suppkey")),
        ),
        _scan("l3.parquet", ln, 100),
    )
    var refs: List[String] = ["l_suppkey"]
    var corr = Expr.correlated_subquery(inner^, refs^, CORR_KIND_EXISTS)
    var plan = LogicalPlan.filter(corr^, _scan("l1.parquet", ln, 100))
    assert_true(_raises_with(plan^, "FlattenAmbiguousOuterRef: l_suppkey"))


def test_plain_name_ambiguous_after_an_outer_only_name_is_refused() raises:
    """`c_v > o_custkey` correlated on [c_v, o_custkey], with the outer side
    also producing `o_custkey`: `c_v` is outer-only, `o_custkey` is produced
    by both sides. The conjunct reads the outer-only name first and the
    ambiguous one second; it is refused with FlattenAmbiguousOuterRef.

    Catches: the name scan stopping at the first outer-only name, so the
    conjunct reaches the residual with `o_custkey` guessed RIGHT (the guess
    the refusal exists to prevent). `l_suppkey <> l_suppkey` above reads the
    ambiguous name first and cannot see this."""
    var cn: List[String] = ["c_custkey", "c_v", "o_custkey"]
    var inner = LogicalPlan.filter(Expr.binary(BIN_GT, _c("c_v"), _c("o_custkey")), _orders())
    var refs: List[String] = ["c_v", "o_custkey"]
    var corr = Expr.correlated_subquery(inner^, refs^, CORR_KIND_EXISTS)
    var plan = LogicalPlan.filter(corr^, _scan("customer.parquet", cn, 10))
    assert_true(_raises_with(plan^, "FlattenAmbiguousOuterRef: o_custkey"))


def test_plain_name_outer_ref_in_a_case_condition_is_marked_left() raises:
    """`o_custkey = c_custkey AND CASE WHEN c_v > 0 THEN o_v ELSE c_v END >
    1` with plain names: the CASE conjunct becomes the residual with `c_v`
    LEFT in the condition and the default and `o_v` RIGHT in the result;
    the orders scan has no Filter.

    Catches: the CASE arm of `_rewrite_sides` dropping the outer names for a
    slot, which marks `c_v` RIGHT and has the residual read a column the
    orders side does not produce (komira-ai/komira#1354 on the residual
    instead of the inner Filter)."""
    var cases = List[WhenCaseData]()
    cases.append(WhenCaseData(Expr.binary(BIN_GT, _c("c_v"), _lit(0)), _c("o_v")))
    var pred = _and(
        Expr.binary(BIN_EQ, _c("o_custkey"), _c("c_custkey")),
        Expr.binary(BIN_GT, Expr.when(cases^, _c("c_v")), _lit(1)),
    )
    var out = flatten_dependent_joins(_exists_over_customer(pred^, CORR_KIND_EXISTS, _both_refs()))
    ref j = out._join.value()[]
    assert_equal(len(j.left_on), 1)
    assert_equal(j.left_on[0], String("c_custkey"))
    assert_equal(j.right[].tag, PLAN_SCAN)
    assert_true(j.has_residual())
    ref r = j.residual.value()[]
    assert_equal(r.binary_op(), BIN_GT)
    ref wd = r.binary_left_ref()._when.value()
    ref cond = wd.cases[0].condition[]
    assert_equal(cond.binary_left_ref().col_ref_name(), String("c_v"))
    assert_equal(cond.binary_left_ref().col_ref_side(), COL_SIDE_LEFT)
    assert_equal(wd.cases[0].result[].col_ref_name(), String("o_v"))
    assert_equal(wd.cases[0].result[].col_ref_side(), COL_SIDE_RIGHT)
    assert_equal(wd.default[].col_ref_name(), String("c_v"))
    assert_equal(wd.default[].col_ref_side(), COL_SIDE_LEFT)


def test_plain_name_correlation_under_an_undescended_kind_is_refused() raises:
    """`o_custkey = c_custkey AND sqrt(c_v) > o_v` with plain names: the
    outer `c_v` sits under a math function the hoist does not descend.
    Refused with FlattenOpaqueCorrelation.

    Catches: the conjunct kept in the inner Filter naming `c_v`; or moved to
    the residual with `o_v` left unmarked."""
    var pred = _and(
        Expr.binary(BIN_EQ, _c("o_custkey"), _c("c_custkey")),
        Expr.binary(BIN_GT, Expr.math_fn(MATH_SQRT, _c("c_v")), _c("o_v")),
    )
    assert_true(_raises_with(
        _exists_over_customer(pred^, CORR_KIND_EXISTS, _both_refs()), "FlattenOpaqueCorrelation"
    ))


def test_scalar_subquery_with_a_plain_name_non_equi_correlation_is_refused() raises:
    """`c_v > (SELECT mean(..) FROM orders WHERE o_custkey = c_custkey AND
    o_v > c_v)` with plain names: the scalar lowering carries no residual,
    so the non-equality correlation is refused.

    Catches: `o_v > c_v` kept in the Filter under the aggregate sink, naming
    a customer column over orders."""
    var inner = LogicalPlan.filter(_plain_key_and_gt(), _orders())
    var corr = Expr.correlated_subquery(inner^, _both_refs(), CORR_KIND_SCALAR)
    var plan = LogicalPlan.filter(Expr.binary(BIN_GT, _c("c_v"), corr^), _customer())
    assert_true(_raises_with(plan^, "non-equi correlation in a scalar"))


# -----------------------------------------------------------------------------
# The side-qualified path
# -----------------------------------------------------------------------------


def test_side_outer_ref_under_a_case_becomes_the_residual() raises:
    """`o_custkey = left.c_custkey AND CASE WHEN left.c_v > 0 THEN o_v ELSE
    0 END > 1`: the CASE conjunct reads the outer `c_v` and becomes the
    residual; the orders scan has no Filter.

    Catches: the side walk not descending a CASE, so the conjunct counts as
    inner-only and stays in a Filter over orders with a LEFT ref in it."""
    var pred = _and(
        Expr.binary(BIN_EQ, _c("o_custkey"), Expr.left("c_custkey")), _case_on_left_c_v()
    )
    var out = flatten_dependent_joins(_exists_over_customer(pred^, CORR_KIND_EXISTS, _both_refs()))
    ref j = out._join.value()[]
    assert_equal(j.left_on[0], String("c_custkey"))
    assert_equal(j.right[].tag, PLAN_SCAN)
    assert_true(j.has_residual())


def test_side_qualifier_only_under_a_case_selects_the_side_aware_path() raises:
    """The CASE conjunct alone, correlated on `c_v`: its only side-qualified
    ref is inside the CASE. The side-aware path takes it: no key, the
    conjunct is the residual.

    Catches: the side-qualifier scan not descending a CASE, so the plain-name
    path runs, keeps the conjunct (with its LEFT ref) in the inner Filter
    and keys the join on `c_v = c_v`."""
    var refs: List[String] = ["c_v"]
    var out = flatten_dependent_joins(_exists_over_customer(_case_on_left_c_v(), CORR_KIND_EXISTS, refs^))
    ref j = out._join.value()[]
    assert_equal(len(j.left_on), 0)
    assert_equal(j.right[].tag, PLAN_SCAN)
    assert_true(j.has_residual())


def test_side_correlation_under_an_undescended_kind_is_refused() raises:
    """`o_custkey = left.c_custkey AND sqrt(left.c_v) > o_v`: the outer ref
    sits under a math function. Refused with FlattenOpaqueCorrelation.

    Catches: the conjunct counted as inner-only (the side walk does not
    descend the math function) and kept in a Filter over orders."""
    var pred = _and(
        Expr.binary(BIN_EQ, _c("o_custkey"), Expr.left("c_custkey")),
        Expr.binary(BIN_GT, Expr.math_fn(MATH_SQRT, Expr.left("c_v")), _c("o_v")),
    )
    assert_true(_raises_with(
        _exists_over_customer(pred^, CORR_KIND_EXISTS, _both_refs()), "FlattenOpaqueCorrelation"
    ))


def test_inner_only_conjunct_under_an_undescended_kind_stays_inner() raises:
    """`o_custkey = left.c_custkey AND sqrt(o_v) > 1`: the math function reads
    only an inner column, so it stays in the inner Filter and nothing is
    refused.

    Catches: the opaque-kind refusal applied to a conjunct naming no outer
    reference."""
    var pred = _and(
        Expr.binary(BIN_EQ, _c("o_custkey"), Expr.left("c_custkey")),
        Expr.binary(BIN_GT, Expr.math_fn(MATH_SQRT, _c("o_v")), _lit(1)),
    )
    var out = flatten_dependent_joins(_exists_over_customer(pred^, CORR_KIND_EXISTS, _both_refs()))
    ref j = out._join.value()[]
    assert_false(j.has_residual())
    assert_false(j.right[].tag == PLAN_SCAN)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
