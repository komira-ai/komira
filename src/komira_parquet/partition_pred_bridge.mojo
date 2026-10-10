# =============================================================================
# partition_pred_bridge: the PartitionPredicatePod <-> PartitionPredicate
# mapping.
# =============================================================================
#
# A partition predicate has two spellings: the plain-data
# `PartitionPredicatePod` (`komira_plan_expr.partition_pred_pod`) that rides
# on a plan node, and the `PartitionPredicate` (`komira_fs.pruned_hive_discovery`)
# that the Hive discovery prunes directories with. This module maps one to
# the other; it lives here because this package depends on both.
#
# The POD's PART_OP_* (UInt8) codes are byte-identical to the discovery's
# `_OP_*` (Int) codes, so the mapping is a flat per-field copy whose only
# transform is the Int<->UInt8 cast on `op`. It round-trips every predicate
# shape (EQ / IN / LT/LE/GT/GE/NE / OTHER) losslessly:
#   * OTHER  -> 0 values both sides.
#   * IN     -> N values both sides.
#   * EQ/cmp -> 1 value both sides.
#   * `col` / `arrow_type` copy verbatim.
#
# Pure value functions; no pointer in any signature.
# =============================================================================

from komira_plan_expr.partition_pred_pod import (
    PartitionConstraintPod,
    PartitionPredicatePod,
)
from komira_fs.pruned_hive_discovery import (
    PartitionConstraint,
    PartitionPredicate,
)


# =============================================================================
# pod_from_predicate — PartitionPredicate -> POD.
# =============================================================================
# A planner that splits a partition predicate out of a filter lowers it into
# the POD on the scan node.
# =============================================================================


def _pod_constraint_from_async(c: PartitionConstraint) -> PartitionConstraintPod:
    """Flat per-field copy with the Int->UInt8 `op` cast (codes are identical,
    tiny constants — loss-free)."""
    return PartitionConstraintPod(
        col=c.col,
        op=UInt8(c.op),
        values=c.values.copy(),
        arrow_type=c.arrow_type,
    )


def pod_from_predicate(p: PartitionPredicate) -> PartitionPredicatePod:
    """Map a `PartitionPredicate` to the `PartitionPredicatePod`.
    Round-trips losslessly across the full op matrix
    (EQ / IN / LT/LE/GT/GE/NE / OTHER)."""
    var out_cons = List[PartitionConstraintPod]()
    for i in range(len(p.constraints)):
        out_cons.append(_pod_constraint_from_async(p.constraints[i]))
    return PartitionPredicatePod(constraints=out_cons^)


# =============================================================================
# predicate_from_pod — POD -> PartitionPredicate.
# =============================================================================
# The POD rides on the plan node; the scan maps it back to the predicate for
# `PrunedHiveDiscovery.open_pruned`.
# =============================================================================


def _async_constraint_from_pod(c: PartitionConstraintPod) -> PartitionConstraint:
    """Flat per-field copy with the UInt8->Int `op` cast."""
    return PartitionConstraint(
        col=c.col,
        op=Int(c.op),
        values=c.values.copy(),
        arrow_type=c.arrow_type,
    )


def predicate_from_pod(p: PartitionPredicatePod) -> PartitionPredicate:
    """Map a `PartitionPredicatePod` back to the `PartitionPredicate`. The
    inverse of `pod_from_predicate`; round-trips losslessly across the full
    op matrix."""
    var out_cons = List[PartitionConstraint]()
    for i in range(len(p.constraints)):
        out_cons.append(_async_constraint_from_pod(p.constraints[i]))
    return PartitionPredicate(constraints=out_cons^)
