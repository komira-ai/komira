# =============================================================================
# komira_scan_planning.partition_pred_bridge — the
# PartitionPredicatePod <-> PartitionPredicate mapping.
# =============================================================================
#
# WHERE THIS LIVES + WHY (dep direction):
#   The mapping must live in a package that deps BOTH `komira_plan_expr` (the
#   POD, `PartitionPredicatePod` / `PartitionConstraintPod`) AND `komira_fs`
#   (the real `PartitionPredicate` / `PartitionConstraint`). That package is
#   `komira_scan_planning`: it deps both, and neither deps it, so the dep
#   graph stays ACYCLIC (plan_expr <- scan_planning; fs <- scan_planning).
#
#   The bridge is reachable from the SDK (the build/attach direction):
#   `pod_from_predicate` is callable from the SDK after it calls
#   `split_partition_predicate`. The engine (the consume direction) calls
#   `predicate_from_pod` at the materialize site to feed
#   `PrunedHiveDiscovery.open_pruned`.
#
# OP-CODE IDENTITY: the POD's PART_OP_* (UInt8) byte
# constants are BYTE-IDENTICAL to the async `_OP_*` (Int) constants. The bridge
# is therefore a flat per-field copy with the ONLY transform being the
# Int<->UInt8 cast on `op`. This round-trips ALL predicate shapes
# (EQ / IN / LT/LE/GT/GE/NE / OTHER) losslessly:
#   * OTHER  -> 0 values both sides.
#   * IN     -> N values both sides.
#   * EQ/cmp -> 1 value both sides.
#   * `col` / `arrow_type` copy verbatim.
#
# Pointer discipline: pure value functions;
# no UnsafePointer in any signature; no pointer crosses a module boundary.
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
# pod_from_predicate — async PartitionPredicate -> komira_plan_expr POD.
# =============================================================================
# The SDK-side direction: `split_partition_predicate`
# produces an async `PartitionPredicate`; the SDK lowers it into the POD on the
# scan node.
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
    """Map a komira_fs `PartitionPredicate` to the komira_plan_expr
    `PartitionPredicatePod`. Round-trips losslessly across the full op matrix
    (EQ / IN / LT/LE/GT/GE/NE / OTHER)."""
    var out_cons = List[PartitionConstraintPod]()
    for i in range(len(p.constraints)):
        out_cons.append(_pod_constraint_from_async(p.constraints[i]))
    return PartitionPredicatePod(constraints=out_cons^)


# =============================================================================
# predicate_from_pod — komira_plan_expr POD -> async PartitionPredicate.
# =============================================================================
# The runtime/engine direction: the POD rides on the plan node;
# the materialize site maps it back to the async predicate for
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
    """Map a komira_plan_expr `PartitionPredicatePod` back to the komira_fs
    `PartitionPredicate`. The inverse of `pod_from_predicate`; round-trips
    losslessly across the full op matrix."""
    var out_cons = List[PartitionConstraint]()
    for i in range(len(p.constraints)):
        out_cons.append(_async_constraint_from_pod(p.constraints[i]))
    return PartitionPredicate(constraints=out_cons^)
