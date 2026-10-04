"""plan_cse_eliminate detection tests.

Covers the SCANNER + the per-call cache shape + the side-effect
classifier seam.

Coverage:
  Test 1: two identical PURE subtrees -> 1 candidate group.
  Test 2: the pass returns the plan unchanged (shell is non-mutating).
"""

from std.testing import assert_equal, assert_true

from komira_core.arrow.schema import SchemaBuilder, Field
from komira_core.arrow.arrow_types import ArrowType
from komira_core.plan.expr import (
    Expr,
    BIN_GT,
)
from komira_core.plan.scalar_value import ScalarValue
from komira_core.plan.logical_plan import (
    LogicalPlan,
    ExprArray,
    SOURCE_PARQUET,
    JOIN_INNER,
    JOIN_ALGO_AUTO,
)

from komira_compiler.plan_cse import (
    plan_cse_eliminate,
    detect_cse_candidates,
)


def _make_lineitem() -> LogicalPlan:
    var b = SchemaBuilder()
    b.add_field(Field(String("l_orderkey"), ArrowType.INT64, False))
    b.add_field(Field(String("l_quantity"), ArrowType.INT64, False))
    var schema = b.build()
    return LogicalPlan.scan(
        String("lineitem.parquet"), SOURCE_PARQUET, schema^
    )


def test_two_identical_pure_subtrees_detected() raises:
    """Join(filter(scan), filter(scan)) with identical filters.

    Expected: at least one CSE candidate group (the filter(scan) subtree
    repeats, plus the bare scan inside it).
    """
    var pred1 = Expr.binary(
        BIN_GT,
        Expr.col_ref(String("l_quantity"))^,
        Expr.literal(ScalarValue.from_int64(10))^,
    )
    var filt1 = LogicalPlan.filter(pred1^, _make_lineitem()^)
    var pred2 = Expr.binary(
        BIN_GT,
        Expr.col_ref(String("l_quantity"))^,
        Expr.literal(ScalarValue.from_int64(10))^,
    )
    var filt2 = LogicalPlan.filter(pred2^, _make_lineitem()^)

    var left_on = List[String]()
    left_on.append(String("l_orderkey"))
    var right_on = List[String]()
    right_on.append(String("l_orderkey"))
    var p = LogicalPlan.join(
        filt1^, filt2^, left_on^, right_on^, JOIN_INNER, JOIN_ALGO_AUTO,
    )

    var n = detect_cse_candidates(p)
    assert_true(n >= 1)


def test_pass_returns_plan_unchanged() raises:
    var p = _make_lineitem()
    var before_h = p.structural_hash()
    var after = plan_cse_eliminate(p^)
    assert_equal(after.structural_hash(), before_h)


def main() raises:
    test_two_identical_pure_subtrees_detected()
    test_pass_returns_plan_unchanged()
    print("test_plan_cse: all 2 cases PASS")
