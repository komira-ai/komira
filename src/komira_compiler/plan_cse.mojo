# =============================================================================
# plan_cse.mojo
# Plan-level Common Subexpression Elimination.
# =============================================================================
#
# Plan-level CSE on identical subtrees within one LogicalPlan. This is
# BROADER than expression-level CSE: if two siblings of a plan both contain
# `Scan(t) -> Filter(p) -> Project(c)`, that whole subtree should
# materialize ONCE and the second occurrence should reference the first
# occurrence's result — not run twice. This is the lever behind the
# Q11 / Q17 / Q22 "single-materialize" shapes (TPC-H).
#
# Two-layer module:
#   1. DETECTION — `_collect_pure_subtree_hashes`
#      walks the plan, hashes every PURE scan-bearing subtree keyed on
#      `LogicalPlan.structural_hash` (FNV-1a of the display string), and
#      counts collisions. A structural_hash count >= 2 is a CSE-candidate
#      group. Per-call cache discipline: the `Dict[UInt64, Int]` lives on the
#      function stack frame and drops at return; a planner-scope cache would
#      outlive the plans it describes (a cross-call use-after-free).
#
#   2. ACTIVE REWRITE — given a PURE
#      duplicated subtree with `structural_hash` H appearing at occurrences
#      O1 (CANONICAL — the first one visited in COMPILE-ORDER DFS) .. On,
#      rewrite the plan so O1 keeps the full subtree and O2..On become
#      `PLAN_CSE_REF(canonical_hash=H)` leaf nodes (see
#      `logical_plan.CseRefData`). The IR stays a TREE (not a DAG): a
#      leaf-ref node expresses sharing without OwnedPointer-aliased
#      children. `plan_compiler._compile_node`'s `PLAN_CSE_REF` arm
#      resolves it to a fragment sourced from the segment that computed
#      the canonical subtree's result (the scan-dedup mechanism
#      generalized to any subtree).
#
# Design notes:
#   - The scan-dedup pass `optimizer_scan_dedup.deduplicate_scans` uses an
#     EXECUTION-TIME `(source_path, filter_fingerprint)` keyed session cache
#     that drives EAGER materialization (it reads the file once and rewrites
#     duplicate bare-scans to in-memory `Values`/registry scans) — NOT an
#     IR-level ref node. `scan_dedup_compile.scan_dedup_at_materialize` is
#     detection-only. Plan-node-level CSE is strictly broader than bare-scan
#     dedup, and uses an IR-level shape: a `PLAN_CSE_REF` LEAF node carrying
#     `canonical_hash` (a UInt64) + an output-schema snapshot. No
#     OwnedPointer-aliased shared subtrees (the IR stays a tree); no
#     `unsafe_from_address`; no wildcard origins; `CseRefData` is a plain value.
#   - The side-effect classifier `_subtree_is_pure` returns `False` (== "do
#     not CSE") for any tag NOT in the known-pure allowlist, so a future
#     side-effect-bearing node defaults to "not a CSE candidate" until it is
#     explicitly whitelisted.
#   - `PLAN_UNION` children are walked (`ud.children[i][]` recursion) in both
#     the purity walk and the rewrite walk. `PLAN_VIEW_REF` is resolved away by
#     `view_resolution_pass` BEFORE CSE runs; it gets a defensive arm here
#     (an opaque pure leaf — never a CSE candidate because it has no scan).
#   - DuckDB's `cse_optimizer` does expression-level CSE on a bound logical
#     operator tree (PROJECT / FILTER expressions) using raw pointer
#     equality; plan-node-level subtree CSE is strictly broader, and uses
#     structural_hash because the SDK's call paths build subtrees through
#     independent factories — pointer identity is not stable. DataFusion's
#     `common_subexpr_eliminate` is expression-level too.
# =============================================================================

from std.collections import Optional, Dict
from komira_core.collections.slab import Slab

from komira_core.plan.logical_plan import (
    LogicalPlan,
    PLAN_SCAN,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_AGGREGATE,
    PLAN_JOIN,
    PLAN_SORT,
    PLAN_LIMIT,
    PLAN_DISTINCT,
    PLAN_TOPN,
    PLAN_PARTITION_BY,
    PLAN_PARTITION_TOPN,
    PLAN_ASOF_JOIN,
    PLAN_UNION,
    PLAN_VIEW_REF,
    PLAN_CSE_REF,
)


# =============================================================================
# Rewrite gate
# =============================================================================
#
# ON. `morsel_executor` keeps a per-seg CONSUMER COUNTER
# (`morsel_executor.execute_segments` / `_take_or_copy_seg_output`): a segment
# output consumed once is MOVE-taken (zero-copy fast path, the common case); a
# segment output consumed N>1 times (the CSE canonical case) is `copy_batch`
# deep-cloned for the first N-1 consumers and MOVE-taken by the last.
# `plan_compiler._compile_node` lowers each `PLAN_CSE_REF` to a fragment sourced
# from the canonical subtree's SINK_COLLECT segment (it pre-scans for ref
# targets and materializes the canonical the first time the compile-order DFS
# reaches it).
#
# `optimize` calls `plan_cse_eliminate(plan)` with this gate as

comptime _ENABLE_CSE_REWRITE: Bool = True


# =============================================================================
# Side-effect classifier (the HALT-condition seam)
# =============================================================================
#
# A subtree is a CSE candidate only if it (and every descendant) is PURE:
# re-evaluating it must have no observable side effect. This function is the
# SEAM for side-effect-bearing primitives (UDFs, sink nodes): they are
# blacklisted HERE.
#
# Hardening: the function now returns `False` (==
# "not pure / do not CSE") for any tag NOT in the known-pure allowlist
# below. A new side-effect-bearing node added later defaults to "not a CSE
# candidate" until it is explicitly whitelisted — fail-closed, not
# fail-open.
#
# ⚠⚠ THE UDF BLACKLIST.
#
# The FILTER / PROJECT / AGGREGATE arms ask `has_udf`: a UDF-bearing node is NOT
# a CSE candidate (there is no plan-level CSE for UDFs).
#
# ⚠ AND THE ARGUMENT "BUT `call_site_salt` MAKES THEIR HASHES DIFFER" IS NOT A
# DEFENCE, IT IS THE MASK. `structural_hash` is FNV-1a over the plan's RENDER,
# `UdfData.write_to` emits `salt=`, and the salt is minted per SDK call — so
# two UDF nodes usually hash apart and never meet. That is an incidental
# property of one field's VALUE, not a property of this classifier:
#
#   * a `plan.copy` deep-clones the salt, so any rewrite that DUPLICATES a
#     UDF-bearing subtree hands CSE two nodes with identical salts;
#   * a UDF conformer may carry mutable state, so sharing execution across two
#     occurrences is wrong even when the type AND the salt agree — which is
#     exactly the case the salt cannot distinguish;
#   * nothing tests the salt's uniqueness as a CSE precondition, so the day it
#     becomes deterministic (a reproducible-plan requirement would do it) this
#     silently starts sharing.
#
# The classifier is the right place for the rule because it is the one that
# claims to know what is safe to re-evaluate. A UDF is opaque to it — it
# cannot see the body — so it must answer NOT PURE, and now does.
#
# Falsifier: `test_udf_bearing_nodes_are_not_cse_candidates` (in the SDK's
# row-UDF identity tests), which builds two UDF filter nodes carrying the SAME
# id AND the SAME salt (the case the mask cannot cover) and asserts they are
# not shared.

def _subtree_is_pure(plan: LogicalPlan) -> Bool:
    """True iff `plan` (and every descendant) is PURE — no observable
    side effect from re-evaluation.

    The function is the SEAM for side-effect-bearing primitives; they are
    blacklisted here. Fail-closed: a tag NOT in the allowlist returns `False`.
    """
    if plan.tag == PLAN_SCAN:
        # A bare scan is pure (a re-read returns the same data). Note: a
        # SOURCE_IN_MEMORY scan's underlying registry/Arc is immutable
        # post-registration, so it is pure too.
        return True
    if plan.tag == PLAN_FILTER:
        # a UDF-bearing node is NOT a CSE candidate. See the
        # UDF BLACKLIST note above this function.
        if plan._filter.value()[].has_udf():
            return False
        return _subtree_is_pure(plan._filter.value()[].child[])
    if plan.tag == PLAN_PROJECT:
        if plan._project.value()[].has_udf():
            return False
        return _subtree_is_pure(plan._project.value()[].child[])
    if plan.tag == PLAN_AGGREGATE:
        if plan._aggregate.value()[].has_udf():
            return False
        return _subtree_is_pure(plan._aggregate.value()[].child[])
    if plan.tag == PLAN_JOIN:
        if not _subtree_is_pure(plan._join.value()[].left[]):
            return False
        return _subtree_is_pure(plan._join.value()[].right[])
    if plan.tag == PLAN_SORT:
        return _subtree_is_pure(plan._sort.value()[].child[])
    if plan.tag == PLAN_LIMIT:
        return _subtree_is_pure(plan._limit.value()[].child[])
    if plan.tag == PLAN_DISTINCT:
        return _subtree_is_pure(plan._distinct.value()[].child[])
    if plan.tag == PLAN_TOPN:
        return _subtree_is_pure(plan._topn.value()[].child[])
    if plan.tag == PLAN_PARTITION_BY:
        return _subtree_is_pure(plan._partition_by.value()[].child[])
    if plan.tag == PLAN_PARTITION_TOPN:
        return _subtree_is_pure(plan._partition_topn.value()[].child[])
    if plan.tag == PLAN_ASOF_JOIN:
        if not _subtree_is_pure(plan._asof_join.value()[].left[]):
            return False
        return _subtree_is_pure(plan._asof_join.value()[].right[])
    if plan.tag == PLAN_UNION:
        # A variadic UNION ALL — pure iff every branch is pure.
        # The CSE walker MUST recurse through union children.
        ref ud = plan._union.value()[]
        for i in range(len(ud.children)):
            if not _subtree_is_pure(ud.children[i][]):
                return False
        return True
    if plan.tag == PLAN_VIEW_REF:
        # B.j.4: a lazy view ref. Resolved away by `view_resolution_pass`
        # at `optimize` Phase -1 BEFORE CSE runs, so this should never
        # be reached. Defensive arm: treat as an opaque pure leaf (it has
        # no scan, so it is never a CSE candidate anyway).
        return True
    if plan.tag == PLAN_CSE_REF:
        # A CSE ref points at an already-deduplicated PURE canonical
        # subtree — itself pure (re-CSE idempotence). Never a candidate
        # again because `_has_scan` returns False for a CSE ref.
        return True
    # Fail-closed: an unknown tag (a future side-effect-bearing primitive
    # that has not been explicitly classified) is treated as NOT pure.
    return False


# =============================================================================
# Scan-presence walk — a subtree with no scan has nothing to CSE for
# =============================================================================


def _has_scan(plan: LogicalPlan) -> Bool:
    """True iff `plan` or any descendant has a PLAN_SCAN node."""
    if plan.tag == PLAN_SCAN:
        return True
    if plan.tag == PLAN_FILTER:
        return _has_scan(plan._filter.value()[].child[])
    if plan.tag == PLAN_PROJECT:
        return _has_scan(plan._project.value()[].child[])
    if plan.tag == PLAN_AGGREGATE:
        return _has_scan(plan._aggregate.value()[].child[])
    if plan.tag == PLAN_JOIN:
        if _has_scan(plan._join.value()[].left[]):
            return True
        return _has_scan(plan._join.value()[].right[])
    if plan.tag == PLAN_SORT:
        return _has_scan(plan._sort.value()[].child[])
    if plan.tag == PLAN_LIMIT:
        return _has_scan(plan._limit.value()[].child[])
    if plan.tag == PLAN_DISTINCT:
        return _has_scan(plan._distinct.value()[].child[])
    if plan.tag == PLAN_TOPN:
        return _has_scan(plan._topn.value()[].child[])
    if plan.tag == PLAN_PARTITION_BY:
        return _has_scan(plan._partition_by.value()[].child[])
    if plan.tag == PLAN_PARTITION_TOPN:
        return _has_scan(plan._partition_topn.value()[].child[])
    if plan.tag == PLAN_ASOF_JOIN:
        if _has_scan(plan._asof_join.value()[].left[]):
            return True
        return _has_scan(plan._asof_join.value()[].right[])
    if plan.tag == PLAN_UNION:
        ref ud = plan._union.value()[]
        for i in range(len(ud.children)):
            if _has_scan(ud.children[i][]):
                return True
        return False
    # PLAN_VIEW_REF / PLAN_CSE_REF are leaves with no scan.
    return False


# =============================================================================
# Detection: count occurrences of each PURE scan-bearing subtree
# =============================================================================
#
# `_collect_pure_subtree_hashes` populates `counts[structural_hash(subtree)]
# += 1` for every PURE subtree that contains at least one scan. We hash THIS
# node first, then recurse children, so the enclosing parent is visible to
# the outer caller before the walk descends.


def _collect_pure_subtree_hashes(
    plan: LogicalPlan,
    mut counts: Dict[UInt64, Int],
) raises:
    """Populate `counts[structural_hash(subtree)] += 1` for every PURE
    scan-bearing subtree. Recurses into children (including PLAN_UNION
    branches)."""
    if not _subtree_is_pure(plan):
        return
    if not _has_scan(plan):
        return

    var h = plan.structural_hash()
    if h in counts:
        counts[h] = counts[h] + 1
    else:
        counts[h] = 1

    if plan.tag == PLAN_FILTER:
        _collect_pure_subtree_hashes(plan._filter.value()[].child[], counts)
    elif plan.tag == PLAN_PROJECT:
        _collect_pure_subtree_hashes(plan._project.value()[].child[], counts)
    elif plan.tag == PLAN_AGGREGATE:
        _collect_pure_subtree_hashes(plan._aggregate.value()[].child[], counts)
    elif plan.tag == PLAN_JOIN:
        _collect_pure_subtree_hashes(plan._join.value()[].left[], counts)
        _collect_pure_subtree_hashes(plan._join.value()[].right[], counts)
    elif plan.tag == PLAN_SORT:
        _collect_pure_subtree_hashes(plan._sort.value()[].child[], counts)
    elif plan.tag == PLAN_LIMIT:
        _collect_pure_subtree_hashes(plan._limit.value()[].child[], counts)
    elif plan.tag == PLAN_DISTINCT:
        _collect_pure_subtree_hashes(plan._distinct.value()[].child[], counts)
    elif plan.tag == PLAN_TOPN:
        _collect_pure_subtree_hashes(plan._topn.value()[].child[], counts)
    elif plan.tag == PLAN_PARTITION_BY:
        _collect_pure_subtree_hashes(plan._partition_by.value()[].child[], counts)
    elif plan.tag == PLAN_PARTITION_TOPN:
        _collect_pure_subtree_hashes(plan._partition_topn.value()[].child[], counts)
    elif plan.tag == PLAN_ASOF_JOIN:
        _collect_pure_subtree_hashes(plan._asof_join.value()[].left[], counts)
        _collect_pure_subtree_hashes(plan._asof_join.value()[].right[], counts)
    elif plan.tag == PLAN_UNION:
        # The CSE walker MUST recurse through union children.
        ref ud = plan._union.value()[]
        for i in range(len(ud.children)):
            _collect_pure_subtree_hashes(ud.children[i][], counts)
    # PLAN_VIEW_REF / PLAN_CSE_REF are leaves — no children to recurse.


# =============================================================================
# The active rewrite
# =============================================================================
#
# `_rewrite_node` walks the plan TOP-DOWN in COMPILE-ORDER DFS. The walk's
# child-visit order MIRRORS `plan_compiler._compile_node`'s traversal so the
# CANONICAL occurrence (the first one visited here) is also the first one
# `_compile_node` would visit (and thus the one whose SINK_COLLECT segment
# is finalized before any CSE-ref's fragment is built):
#   - PLAN_JOIN / PLAN_ASOF_JOIN: visit `right` (the build side, finalized
#     first by `_compile_join` / `_compile_asof_join`) BEFORE `left`.
#   - PLAN_UNION: visit children left-to-right (`_compile_union` order).
#   - everything else: the single child.
#
# At each node:
#   - if the node's `structural_hash` is in `dup_groups` (count >= 2) AND
#     not yet `claimed`: this is the CANONICAL occurrence — `claim` the
#     hash, keep the full subtree, and RECURSE into children (so nested
#     CSE works — a duplicated subtree inside the canonical can have its
#     own canonical + refs);
#   - if the hash IS `claimed`: replace this node with a
#     `PLAN_CSE_REF(canonical_hash=H)` leaf — do NOT recurse;
#   - otherwise: recurse into children, rebuilding the node.
#
# `dup_groups` is the set of structural_hashes with count >= 2 (PURE,
# scan-bearing). `claimed` is the running set of hashes whose canonical
# occurrence has already been seen.
#
# NB on the per-call cache discipline: both
# `dup_groups` and `claimed` are stack-local `Dict`s in `plan_cse_eliminate`;
# they drop at function return — no cross-call state leaks.


def _cse_rewrite_inplace(
    mut plan: LogicalPlan,
    dup_groups: Dict[UInt64, Int],
    mut claimed: Dict[UInt64, Int],
) raises:
    """Rewrite one plan node (and its subtree) IN PLACE per the CSE rules
    above. Mirrors the in-place style of `view_resolution_pass`
    (`mut LogicalPlan` ref-mutation through `OwnedPointer[T]`, no
    rebuild-tree — the post-H1 in-place-optimizer-rule convention).

    Args:
        plan: the node to rewrite (mutated in place).
        dup_groups: structural_hash -> count, restricted to PURE
            scan-bearing subtrees with count >= 2.
        claimed: running set of hashes whose canonical occurrence has
            already been visited (value is unused; only membership matters).
    """
    var h = plan.structural_hash()

    if h in dup_groups and _subtree_is_pure(plan) and _has_scan(plan):
        if h in claimed:
            # 2nd..Nth occurrence → replace this node with a CSE ref leaf.
            var schema_snap = plan.output_schema.copy()
            plan = LogicalPlan.cse_ref(h, schema_snap^)
            return
        # Canonical (first-in-compile-order) occurrence → keep the full
        # subtree, mark the hash claimed, and recurse so nested CSE works.
        claimed[h] = 1

    # Recurse into children, mirroring `_compile_node`'s traversal order.
    if plan.tag == PLAN_FILTER:
        _cse_rewrite_inplace(plan._filter.value()[].child[], dup_groups, claimed)
    elif plan.tag == PLAN_PROJECT:
        _cse_rewrite_inplace(plan._project.value()[].child[], dup_groups, claimed)
    elif plan.tag == PLAN_AGGREGATE:
        _cse_rewrite_inplace(plan._aggregate.value()[].child[], dup_groups, claimed)
    elif plan.tag == PLAN_JOIN:
        # `_compile_join` finalizes `right` (build) FIRST, then `left`
        # (probe) — visit in that order so the canonical occurrence is the
        # one whose SINK_COLLECT segment would be finalized first.
        _cse_rewrite_inplace(plan._join.value()[].right[], dup_groups, claimed)
        _cse_rewrite_inplace(plan._join.value()[].left[], dup_groups, claimed)
    elif plan.tag == PLAN_SORT:
        _cse_rewrite_inplace(plan._sort.value()[].child[], dup_groups, claimed)
    elif plan.tag == PLAN_LIMIT:
        _cse_rewrite_inplace(plan._limit.value()[].child[], dup_groups, claimed)
    elif plan.tag == PLAN_DISTINCT:
        _cse_rewrite_inplace(plan._distinct.value()[].child[], dup_groups, claimed)
    elif plan.tag == PLAN_TOPN:
        _cse_rewrite_inplace(plan._topn.value()[].child[], dup_groups, claimed)
    elif plan.tag == PLAN_PARTITION_BY:
        _cse_rewrite_inplace(plan._partition_by.value()[].child[], dup_groups, claimed)
    elif plan.tag == PLAN_PARTITION_TOPN:
        _cse_rewrite_inplace(plan._partition_topn.value()[].child[], dup_groups, claimed)
    elif plan.tag == PLAN_ASOF_JOIN:
        # `_compile_asof_join` finalizes `right` first, then `left`.
        _cse_rewrite_inplace(plan._asof_join.value()[].right[], dup_groups, claimed)
        _cse_rewrite_inplace(plan._asof_join.value()[].left[], dup_groups, claimed)
    elif plan.tag == PLAN_UNION:
        # The CSE walker MUST recurse through union children.
        # `_compile_union` visits branches left-to-right.
        var n = len(plan._union.value()[].children)
        for i in range(n):
            _cse_rewrite_inplace(plan._union.value()[].children[i][], dup_groups, claimed)
    # PLAN_SCAN / PLAN_VIEW_REF / PLAN_CSE_REF — leaves, nothing to recurse.


# =============================================================================
# Public API
# =============================================================================


def detect_cse_candidates(plan: LogicalPlan) raises -> Int:
    """Return the number of CSE-candidate groups: PURE scan-bearing
    subtrees whose structural_hash count is >= 2.

    Pure observability helper — consumed by tests and by
    `plan_cse_eliminate`. Per-call cache discipline:
    `var counts = Dict[UInt64, Int]` is stack-local and
    drops at return.
    """
    var counts = Dict[UInt64, Int]()
    _collect_pure_subtree_hashes(plan, counts)
    var n = 0
    for kv in counts.items():
        if kv.value > 1:
            n += 1
    return n


def count_subtree_occurrences(plan: LogicalPlan, target_hash: UInt64) raises -> Int:
    """Return the count of PURE scan-bearing subtrees with
    `structural_hash == target_hash`. Test/observability helper."""
    var counts = Dict[UInt64, Int]()
    _collect_pure_subtree_hashes(plan, counts)
    if target_hash in counts:
        return counts[target_hash]
    return 0


def plan_cse_eliminate(
    var plan: LogicalPlan,
    force_rewrite: Bool = _ENABLE_CSE_REWRITE,
) raises -> LogicalPlan:
    """Plan-level CSE: replace each PURE duplicated subtree's 2nd..Nth
    occurrence with a `PLAN_CSE_REF(canonical_hash)` leaf pointing at the
    first (compile-order) occurrence.

    Args:
        plan: The plan to rewrite (consumed).
        force_rewrite: When `False`, this is a NO-OP: the plan is returned
            unchanged. Defaults to `_ENABLE_CSE_REWRITE` (ON). Tests pass
            `force_rewrite=True` to exercise the IR-level rewrite.

    Per-call cache discipline: `dup_groups` and
    `claimed` are stack-local `Dict`s; they drop at function return.

    Returns:
        The (possibly CSE-rewritten) plan.
    """
    if not force_rewrite:
        # Gate OFF: detection-only is not even worth a walk on every
        # compile — return the plan untouched.
        return plan^

    var dup_groups = Dict[UInt64, Int]()
    _collect_pure_subtree_hashes(plan, dup_groups)
    # Restrict to groups with count >= 2 (the others are not candidates).
    var candidates = Dict[UInt64, Int]()
    for kv in dup_groups.items():
        if kv.value > 1:
            candidates[kv.key] = kv.value
    if len(candidates) == 0:
        return plan^

    var claimed = Dict[UInt64, Int]()
    _cse_rewrite_inplace(plan, candidates, claimed)
    return plan^


def plan_cse_eliminate_forest(
    var plans: Slab[LogicalPlan],
    force_rewrite: Bool = _ENABLE_CSE_REWRITE,
) raises -> Slab[LogicalPlan]:
    """Forest-scoped plan-level CSE.

    Generalizes `plan_cse_eliminate` from "one plan" to "a list of N plans
    compiled together by `plan_compiler.compile_forest_with_registry`": a
    PURE scan-bearing subtree that occurs >= 2 times across the *whole*
    forest (including once in plan A and once in plan B) is kept canonical
    at its FIRST occurrence in SUBMISSION ORDER, and every other occurrence
    — later in the same plan OR in any later plan — becomes a
    `PLAN_CSE_REF(canonical_hash)` leaf.

    Because `PLAN_CSE_REF` is hash-keyed (a `canonical_hash: UInt64`,
    carrying NO plan identity — see `logical_plan.CseRefData`), the IR
    stays a TREE across plans: a ref in plan B simply names a hash that
    `compile_forest_with_registry`'s shared `CseCompileCtx.seg_map`
    resolves to the SINK_COLLECT segment compiled from plan A's canonical.
    Compile-order MUST equal this rewrite/submission order — that
    precondition is documented + debug-asserted in
    `plan_compiler.compile_forest_with_registry`.

    Two-pass shape (mirrors `plan_cse_eliminate`, but the two `Dict`s span
    the N-plan walk):
      Pass 1: `for p in plans: _collect_pure_subtree_hashes(p, dup_groups)`
              — counts every PURE scan-bearing subtree's structural_hash
              across all N. (NB the per-call cache discipline still holds:
              `dup_groups` / `claimed` are stack-local to THIS function and
              drop at return — no cross-call state leaks.)
      Pass 2: restrict to count >= 2, then
              `for p in plans: _cse_rewrite_inplace(p, candidates, claimed)`
              — `claimed` is SHARED across the N rewrites, so plan[0] is
              fully rewritten first (its first occurrence claimed as
              canonical), then plan[1] (whose occurrences of an
              already-claimed hash become refs), etc.

    Scan-dedup note (dispatch decision): `optimizer_scan_dedup.deduplicate_scans`
    ("Pass A", run by `pipeline_compiler`) stays PER-PLAN — cross-plan scan
    sharing is the job of THIS forest-CSE pass (a `structural_hash` match is
    strictly stronger than Pass A's `(source_path, filter_fingerprint)`
    key, so any scan subtree Pass A would dedup across plans is also a
    forest-CSE candidate, and one with a *different* pushed predicate is
    correctly NOT shared by either pass — different filtered row sets).

    Args:
        plans: The N plans (consumed). Returned in the same order, each
            possibly rewritten with `PLAN_CSE_REF` leaves.
        force_rewrite: When `False`, this is a NO-OP — the plans are
            returned unchanged. Defaults to `_ENABLE_CSE_REWRITE` (ON). Tests
            pass `force_rewrite=True`.

    Returns:
        The (possibly CSE-rewritten) plans, in submission order.
    """
    if not force_rewrite:
        return plans^

    var dup_groups = Dict[UInt64, Int]()
    for i in range(len(plans)):
        _collect_pure_subtree_hashes(plans[i], dup_groups)
    # Restrict to groups with count >= 2 (the others are not candidates).
    var candidates = Dict[UInt64, Int]()
    for kv in dup_groups.items():
        if kv.value > 1:
            candidates[kv.key] = kv.value
    if len(candidates) == 0:
        return plans^

    var claimed = Dict[UInt64, Int]()
    for i in range(len(plans)):
        _cse_rewrite_inplace(plans[i], candidates, claimed)
    return plans^
