# =============================================================================
# partition_pred_bridge round-trip tests.
#
# Asserts the PartitionPredicatePod <-> PartitionPredicate mapping
# (`komira_parquet.partition_pred_bridge`) is LOSSLESS across the full
# op matrix (EQ / IN / LT/LE/GT/GE/NE / OTHER), plus the empty-predicate
# degenerate case (the un-filtered Hive read).
#
# The mapping itself is pure data, so these tests run at the POD/bridge
# boundary only.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_plan_expr.partition_pred_pod import (
    PartitionConstraintPod,
    PartitionPredicatePod,
    PART_OP_EQ,
    PART_OP_IN,
    PART_OP_LT,
    PART_OP_LE,
    PART_OP_GT,
    PART_OP_GE,
    PART_OP_NE,
    PART_OP_OTHER,
)
from komira_fs.pruned_hive_discovery import (
    PartitionConstraint,
    PartitionPredicate,
    _OP_EQ,
    _OP_IN,
    _OP_LT,
    _OP_LE,
    _OP_GT,
    _OP_GE,
    _OP_NE,
    _OP_OTHER,
)
from komira_parquet.partition_pred_bridge import (
    pod_from_predicate,
    predicate_from_pod,
)


# =============================================================================
# Op-code byte-identity — the foundation the bridge relies on.
# =============================================================================


def test_op_codes_are_byte_identical() raises:
    """PART_OP_* (UInt8) must equal the async _OP_* (Int) constants byte-for-
    byte, so the bridge is a flat cast with no remap."""
    assert_equal(Int(PART_OP_EQ), _OP_EQ)
    assert_equal(Int(PART_OP_IN), _OP_IN)
    assert_equal(Int(PART_OP_LT), _OP_LT)
    assert_equal(Int(PART_OP_LE), _OP_LE)
    assert_equal(Int(PART_OP_GT), _OP_GT)
    assert_equal(Int(PART_OP_GE), _OP_GE)
    assert_equal(Int(PART_OP_NE), _OP_NE)
    assert_equal(Int(PART_OP_OTHER), _OP_OTHER)


# =============================================================================
# Helpers — assert two constraints are field-for-field equal.
# =============================================================================


def _assert_async_constraint_eq(
    c: PartitionConstraint, col: String, op: Int, n_vals: Int
) raises:
    assert_equal(c.col, col)
    assert_equal(c.op, op)
    assert_equal(len(c.values), n_vals)


def _assert_pod_constraint_eq(
    c: PartitionConstraintPod, col: String, op: UInt8, n_vals: Int
) raises:
    assert_equal(c.col, col)
    assert_equal(Int(c.op), Int(op))
    assert_equal(len(c.values), n_vals)


# =============================================================================
# Full op matrix — build an async predicate with ONE constraint of each shape,
# round-trip async -> pod -> async, assert lossless.
# =============================================================================


def _full_matrix_predicate() -> PartitionPredicate:
    """One constraint of every op shape: EQ / IN(3) / LT/LE/GT/GE/NE / OTHER."""
    var cons = List[PartitionConstraint]()
    cons.append(PartitionConstraint.eq("dt", "2026-10-04", ArrowType.DATE32))
    var in_vals = List[String]()
    in_vals.append(String("a"))
    in_vals.append(String("b"))
    in_vals.append(String("c"))
    cons.append(PartitionConstraint.in_list("region", in_vals, ArrowType.STRING))
    cons.append(PartitionConstraint.compare("lo", _OP_LT, "10", ArrowType.INT64))
    cons.append(PartitionConstraint.compare("le", _OP_LE, "20", ArrowType.INT64))
    cons.append(PartitionConstraint.compare("gt", _OP_GT, "30", ArrowType.INT64))
    cons.append(PartitionConstraint.compare("ge", _OP_GE, "40", ArrowType.INT64))
    cons.append(PartitionConstraint.compare("ne", _OP_NE, "50", ArrowType.INT64))
    cons.append(PartitionConstraint.other("opaque"))
    return PartitionPredicate(constraints=cons^)


def test_pod_from_predicate_preserves_full_matrix() raises:
    """async -> pod: every field preserved, op cast Int->UInt8 byte-identical."""
    var p = _full_matrix_predicate()
    var pod = pod_from_predicate(p)

    assert_equal(pod.num_constraints(), 8)
    _assert_pod_constraint_eq(pod.constraints[0], "dt", PART_OP_EQ, 1)
    assert_equal(pod.constraints[0].values[0], "2026-10-04")
    assert_true(pod.constraints[0].arrow_type == ArrowType.DATE32)
    _assert_pod_constraint_eq(pod.constraints[1], "region", PART_OP_IN, 3)
    assert_equal(pod.constraints[1].values[0], "a")
    assert_equal(pod.constraints[1].values[2], "c")
    assert_true(pod.constraints[1].arrow_type == ArrowType.STRING)
    _assert_pod_constraint_eq(pod.constraints[2], "lo", PART_OP_LT, 1)
    _assert_pod_constraint_eq(pod.constraints[3], "le", PART_OP_LE, 1)
    _assert_pod_constraint_eq(pod.constraints[4], "gt", PART_OP_GT, 1)
    _assert_pod_constraint_eq(pod.constraints[5], "ge", PART_OP_GE, 1)
    _assert_pod_constraint_eq(pod.constraints[6], "ne", PART_OP_NE, 1)
    _assert_pod_constraint_eq(pod.constraints[7], "opaque", PART_OP_OTHER, 0)
    assert_true(pod.constraints[7].arrow_type == ArrowType.STRING)


def test_full_matrix_round_trips_losslessly() raises:
    """async -> pod -> async: every (col, op, values, arrow_type) preserved."""
    var original = _full_matrix_predicate()
    var pod = pod_from_predicate(original)
    var back = predicate_from_pod(pod)

    assert_equal(back.num_constraints(), 8)
    _assert_async_constraint_eq(back.constraints[0], "dt", _OP_EQ, 1)
    assert_equal(back.constraints[0].values[0], "2026-10-04")
    assert_true(back.constraints[0].arrow_type == ArrowType.DATE32)
    _assert_async_constraint_eq(back.constraints[1], "region", _OP_IN, 3)
    assert_equal(back.constraints[1].values[0], "a")
    assert_equal(back.constraints[1].values[1], "b")
    assert_equal(back.constraints[1].values[2], "c")
    assert_true(back.constraints[1].arrow_type == ArrowType.STRING)
    _assert_async_constraint_eq(back.constraints[2], "lo", _OP_LT, 1)
    assert_equal(back.constraints[2].values[0], "10")
    _assert_async_constraint_eq(back.constraints[3], "le", _OP_LE, 1)
    _assert_async_constraint_eq(back.constraints[4], "gt", _OP_GT, 1)
    _assert_async_constraint_eq(back.constraints[5], "ge", _OP_GE, 1)
    _assert_async_constraint_eq(back.constraints[6], "ne", _OP_NE, 1)
    assert_equal(back.constraints[6].values[0], "50")
    _assert_async_constraint_eq(back.constraints[7], "opaque", _OP_OTHER, 0)
    assert_true(back.constraints[7].arrow_type == ArrowType.STRING)


def test_pod_round_trips_through_async() raises:
    """The reverse direction seed: pod -> async -> pod preserves everything."""
    var seed_cons = List[PartitionConstraintPod]()
    seed_cons.append(
        PartitionConstraintPod.eq("y", "2027", ArrowType.INT64)
    )
    var in_vals = List[String]()
    in_vals.append(String("x"))
    in_vals.append(String("z"))
    seed_cons.append(
        PartitionConstraintPod.in_list("m", in_vals^, ArrowType.STRING)
    )
    seed_cons.append(PartitionConstraintPod.other("opq"))
    var seed = PartitionPredicatePod(constraints=seed_cons^)

    var roundtripped = pod_from_predicate(predicate_from_pod(seed))
    assert_equal(roundtripped.num_constraints(), 3)
    _assert_pod_constraint_eq(roundtripped.constraints[0], "y", PART_OP_EQ, 1)
    assert_equal(roundtripped.constraints[0].values[0], "2027")
    assert_true(roundtripped.constraints[0].arrow_type == ArrowType.INT64)
    _assert_pod_constraint_eq(roundtripped.constraints[1], "m", PART_OP_IN, 2)
    assert_equal(roundtripped.constraints[1].values[1], "z")
    _assert_pod_constraint_eq(roundtripped.constraints[2], "opq", PART_OP_OTHER, 0)


# =============================================================================
# The empty (un-filtered Hive read) degenerate case.
# =============================================================================


def test_empty_predicate_round_trips() raises:
    """PartitionPredicatePod.empty() <-> empty PartitionPredicate — the
    un-filtered Hive read. Prunes nothing; carries zero constraints both
    sides."""
    var empty_pod = PartitionPredicatePod.empty()
    assert_equal(empty_pod.num_constraints(), 0)

    var to_async = predicate_from_pod(empty_pod)
    assert_equal(to_async.num_constraints(), 0)

    var back = pod_from_predicate(to_async)
    assert_equal(back.num_constraints(), 0)

    var empty_async = PartitionPredicate.empty()
    var async_to_pod = pod_from_predicate(empty_async)
    assert_equal(async_to_pod.num_constraints(), 0)


def main() raises:
    var suite = TestSuite()
    suite.test[test_op_codes_are_byte_identical]()
    suite.test[test_pod_from_predicate_preserves_full_matrix]()
    suite.test[test_full_matrix_round_trips_losslessly]()
    suite.test[test_pod_round_trips_through_async]()
    suite.test[test_empty_predicate_round_trips]()
    suite^.run()
