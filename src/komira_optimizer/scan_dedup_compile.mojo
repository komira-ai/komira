# =============================================================================
# scan_dedup_compile.mojo -- detecting identical scan-bearing subtrees within
# one LogicalPlan, keyed on `LogicalPlan.structural_hash()`.
#
# DETECTION ONLY. Nothing here rewrites a plan. Each function walks the plan
# once, counts every subtree that holds a scan (the root and every descendant,
# union branches included), and returns a number. The counts live in a
# `Dict` local to the call and are dropped on return, so two calls never share
# state.
#
# It counts impure subtrees as well (a UDF-bearing Filter over a scan counts
# like any other), because it reports what the plan repeats, not what may be
# shared. `plan_cse.detect_cse_candidates` counts only the pure subtrees, which
# are the ones `plan_cse_eliminate` replaces. A plan on which this module
# reports more groups than `detect_cse_candidates` repeats a subtree that
# carries a UDF or another node kind `plan_is_pure` refuses.
#
# Because the key is the rendered text, a subtree that differs from another in
# anything the render shows (a predicate literal, a projection, a source path)
# is a different group, and one scan filtered two different ways is two
# subtrees, not a duplicate.
# =============================================================================

from std.collections import Dict

from komira_plan_ir.logical_plan import LogicalPlan

from komira_optimizer.subtree_hash_walk import (
    count_scan_subtrees,
    count_duplicate_groups,
)


def detect_duplicate_subtree_groups(plan: LogicalPlan) raises -> Int:
    """The number of distinct scan-bearing subtrees of `plan` that occur at
    least twice. A bare scan repeated twice is one group; a Filter over that
    scan repeated twice is a second group, because the Filter subtree repeats
    as well."""
    var counts = Dict[UInt64, Int]()
    count_scan_subtrees(plan, counts, False)
    return count_duplicate_groups(counts)


def count_subtree_occurrences(
    plan: LogicalPlan, target_hash: UInt64
) raises -> Int:
    """How many scan-bearing subtrees of `plan` have `structural_hash() ==
    target_hash`; zero when none does."""
    var counts = Dict[UInt64, Int]()
    count_scan_subtrees(plan, counts, False)
    if target_hash in counts:
        return counts[target_hash]
    return 0
