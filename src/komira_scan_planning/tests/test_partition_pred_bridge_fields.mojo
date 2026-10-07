# =============================================================================
# partition_pred_bridge direct field tests.
#
# The round-trip tests check `predicate_from_pod` mostly through a round
# trip and only with the defined op codes 0..7. These tests check:
#   * `predicate_from_pod` field by field from a POD built on the POD side,
#     with a distinct arrow type and value per comparison constraint;
#   * an op code outside the defined set passes through both casts
#     unchanged (the bridge copies the code; it does not remap or clamp
#     it to OTHER).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_plan_expr.partition_pred_pod import (
    PartitionConstraintPod,
    PartitionPredicatePod,
    PART_OP_LT,
    PART_OP_GE,
    PART_OP_NE,
)
from komira_fs.pruned_hive_discovery import (
    PartitionConstraint,
    PartitionPredicate,
    _OP_LT,
    _OP_GE,
    _OP_NE,
)
from komira_scan_planning.partition_pred_bridge import (
    pod_from_predicate,
    predicate_from_pod,
)


def test_predicate_from_pod_copies_each_field() raises:
    """POD -> async with no round trip: col, op, value and arrow type of
    each constraint land on the constraint at the same index."""
    var cons = List[PartitionConstraintPod]()
    cons.append(PartitionConstraintPod.compare("a", PART_OP_LT, "1", ArrowType.BOOL))
    cons.append(PartitionConstraintPod.compare("b", PART_OP_GE, "2", ArrowType.INT32))
    cons.append(PartitionConstraintPod.compare("c", PART_OP_NE, "", ArrowType.DATE32))
    var p = predicate_from_pod(PartitionPredicatePod(constraints=cons^))

    assert_equal(p.num_constraints(), 3)
    assert_equal(p.constraints[0].col, "a")
    assert_equal(p.constraints[0].op, _OP_LT)
    assert_equal(p.constraints[0].values[0], "1")
    assert_true(p.constraints[0].arrow_type == ArrowType.BOOL)
    assert_equal(p.constraints[1].col, "b")
    assert_equal(p.constraints[1].op, _OP_GE)
    assert_equal(p.constraints[1].values[0], "2")
    assert_true(p.constraints[1].arrow_type == ArrowType.INT32)
    assert_equal(p.constraints[2].col, "c")
    assert_equal(p.constraints[2].op, _OP_NE)
    assert_equal(len(p.constraints[2].values), 1)
    assert_equal(p.constraints[2].values[0], "")
    assert_true(p.constraints[2].arrow_type == ArrowType.DATE32)


def test_undefined_op_code_passes_through_unchanged() raises:
    """An op code past the defined set (255, the top of UInt8) survives
    async -> POD -> async as the same number: no remap, no clamp to OTHER."""
    var cons = List[PartitionConstraint]()
    cons.append(PartitionConstraint.compare("x", 255, "v", ArrowType.INT64))
    var pod = pod_from_predicate(PartitionPredicate(constraints=cons^))
    assert_equal(Int(pod.constraints[0].op), 255)

    var back = predicate_from_pod(pod)
    assert_equal(back.constraints[0].op, 255)
    assert_equal(back.constraints[0].values[0], "v")


def main() raises:
    var suite = TestSuite()
    suite.test[test_predicate_from_pod_copies_each_field]()
    suite.test[test_undefined_op_code_passes_through_unchanged]()
    suite^.run()
