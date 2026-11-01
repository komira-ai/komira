# =============================================================================
# Optimizer DPccp -- connected-subgraph / complement pair DP join enumeration
# =============================================================================
#
# Literal port of v0.3 `solve_dpccp` and its five companions in
# v0.3's join-order planner. DPccp is the classical
# Moerkotte/Neumann dynamic-programming join enumerator: it enumerates every
# connected subgraph (csg) of the join graph, then for each csg every
# connected complement (cmp), and memoizes the best join tree per relation
# subset. This port is not the canonical enumerator: it grows a csg or a
# complement one neighbour at a time and excludes only that neighbour, so
# on dense graphs the same csg-cmp pair is emitted many times (a clique of
# n relations: 40, 236, 1,541, 11,327, 93,528, 860,736 emits for n = 4..9,
# against the canonical (3^n - 2^(n+1) + 1) / 2 = 25..9,330). Plans stay
# optimal (the DP table keeps the cheaper entry, and of two equal-cost
# entries the one `dp_pair_beats` orders first, whatever the emission order);
# the cost is time. The
# relation bound (more than 12 relations fall back to greedy) and the
# iteration cap keep it bounded; a 9-relation clique already exceeds the
# cap and falls back to greedy. komira-ai/komira#1176 tracks the fix.
#
# Selection (no feature flag; the row-count fallback relaxes it):
#   `should_use_dpccp(chain)` decides DPccp vs greedy based on intrinsic
#   chain shape. The rule (defined below):
#     - chain length in [DPCCP_MIN_RELATIONS, DPCCP_MAX_RELATIONS], AND
#     - at least one relation carries EITHER (a) writer-emitted NDV
#       stats (`table_stats`) OR (b) a populated `row_count` on its
#       underlying scan (the row-count fallback for a scan that carries
#       `row_count` while its relation has no `table_stats`).
#   Outside those bounds `reorder_joins_with_dp` uses `greedy_join_order`.
#   Greedy also remains the fallback when DPccp returns None (iteration
#   overflow, or a plan whose top join is a synthesized cross product).
#
# Cost model:
#   `solve_dpccp_with_cost` builds a TDOM graph for the chain, and
#   `_cost_for_pair` prices every pair with `estimate_cardinality_with_set`
#   over the combined relation set. Without a TDOM graph (direct callers of
#   the enumerators), it calls `estimate_join_cardinality_with_ndv`
#   (NDV-aware FK-PK formula) with the `table_stats` of whichever side is a
#   singleton base relation; for composite subsets it leaves stats None so
#   the helper falls through to the conservative `max(l, r)`.
#   Row-count fallback (no-TDOM path only): when a singleton lacks
#   `table_stats` but its leaf carries `row_count`, the helper synthesizes
#   a single-key TableStats with NDV ~= row_count // ESTIMATED_DISTINCT_RATIO_DEN
#   (with NUM=1, DEN=10 -> NDV ~= row_count / 10, at least 1) so the FK-PK
#   formula has a divisor. See `_synth_row_count_table_stats` for the shape.
#
# Test-only cost injection:
#   To exercise DPccp with a biased cost function in unit tests,
#   `solve_dpccp_with_cost` accepts a
#   `cost_override: Dict[UInt64, Int]` keyed by
#   `combined.bits` (left_set.union(right_set).bits). When the dict has an
#   entry for a given pair, `_cost_for_pair` returns it as the join
#   cardinality in place of its own estimate. `solve_dpccp` passes an
#   empty dict. Tests pass a hand-built dict to steer DPccp towards a known
#   optimum on synthetic chains.
#
# Observation:
#   The enumerators and `solve_dpccp_observed` report each pass and every
#   scored pair to a `DPccpObserver` (`optimizer_dpccp_observer`). The
#   solver passes `NoDPccpObserver`, whose methods are empty;
#   `optimizer_dpccp_diagnostic` passes one that records a trace.
#
# v0.3 divergences:
#
#   (1) Cost model: v0.3 calls `estimate_join_cardinality_for_reorder`
#       with (left_card, right_card, left_plan, right_plan, &lk, &rk)
#       which does per-key NDV lookup. Here `_cost_for_pair` uses the TDOM
#       set estimator `estimate_cardinality_with_set`, and
#       `estimate_join_cardinality_with_ndv` when no TDOM graph is set.
#       The `find_representative_plan` helper is still ported
#       (returns the leaf that owns the first bit of the set) because the
#       DP-table reconstruction step needs it to recover leaf plans.
#
#   (2) Iteration counting: v0.3 increments `iterations` by the return
#       value of each recursive call. v0.4 passes one `_IterCounter`
#       struct by `mut` reference through the recursion instead of
#       "return the delta" plumbing. Cap check identical: bail with None
#       on overflow.
#
#   (3) RelationSet API: v0.4's `RelationSet` already exists (see
#       optimizer_reorder.mojo) with singleton/union/contains. We use it
#       unchanged. The `iter()` helper returns a small `List[Int]` rather
#       than a Rust-style iterator.
#
#   (4) DP table: v0.3 uses `HashMap<u64, DPNode>`; v0.4 uses Mojo stdlib
#       `Dict[UInt64, DPNode]`. Same semantics (insertion-order preserving
#       in Mojo, which we do not rely on).
#
#   (5) `or_insert` / entry pattern: v0.3 uses the HashMap entry API.
#       `emit_pair` does a manual "lookup-then-update-or-insert", which is
#       slightly less efficient (two hash probes on the update path) but
#       semantically identical.
#
# Layout. This module holds the selection rule (`should_use_dpccp`) and the
# reorder driver (`reorder_joins_with_dp`); the rest lives in four sibling
# modules, and every name they define is re-exported here, so
# `komira_optimizer.optimizer_dpccp` names everything it named before the
# split:
#   `optimizer_dpccp_cost`   the bounds, `DPNode`, the iteration counter,
#                            `_cost_for_pair` and the row-count fallback;
#   `optimizer_dpccp_graph`  the adjacency list, connectivity and the
#                            cross-product augmentation;
#   `optimizer_dpccp_enum`   `emit_pair`, the three enumerators and the
#                            DP-table reconstruction;
#   `optimizer_dpccp_solve`  the passes, `solve_dpccp*` and the top-level
#                            synthesized-cross guard.
#
# =============================================================================

from std.collections import Dict
from komira_async.runtime.sched_trace import join_reorder_fire_inc

from std.memory import OwnedPointer

from komira_plan_expr.expr import Expr
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    JOIN_INNER,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_AGGREGATE,
    PLAN_JOIN,
    PLAN_SORT,
    PLAN_LIMIT,
    PLAN_DISTINCT,
    PLAN_TOPN,
    ExprArray,
)
from .optimizer_reorder import (
    _is_rename_free_passthrough_project,
    JoinChain,
    extract_join_chain,
    greedy_join_order,
)
from .optimizer_transitive_edges import derive_transitive_edges
from .optimizer_join import (
    join_reorder_output_names,
    narrow_reordered_join_to_declared_columns,
    restore_join_reorder_output_columns,
)
from komira_plan_ir.plan_helpers import (
    _copy_plan,
    _take_join_left,
    _take_join_right,
)

# Every name the sibling modules define, re-exported (see Layout above).
from .optimizer_dpccp_cost import (
    DPCCP_MAX_RELATIONS,
    DPCCP_MIN_RELATIONS,
    DPCCP_MAX_ITERATIONS,
    ESTIMATED_DISTINCT_RATIO_NUM,
    ESTIMATED_DISTINCT_RATIO_DEN,
    _leaf_has_row_count,
    DPNode,
    _IterCounter,
    _row_count_ndv_estimate,
    _cost_for_pair,
    _synth_row_count_table_stats,
)
from .optimizer_dpccp_graph import (
    _build_neighbors,
    _compute_relation_components,
    _relation_graph_is_connected,
    _should_trigger_cross_product_augmentation,
    _augment_neighbors_with_cross_products,
    _has_real_connecting_edge,
)
from .optimizer_dpccp_enum import (
    emit_pair,
    emit_csg_complements,
    enumerate_csg_rec,
    enumerate_complement_rec,
    find_representative_plan,
    reconstruct_plan_from_dp,
)
from .optimizer_dpccp_solve import (
    _empty_cost_override,
    solve_dpccp,
    _seed_dp_base_relations,
    _run_dpccp_passes,
    _plan_has_synthesized_cross,
    _plan_top_join_is_synthesized_cross,
    solve_dpccp_with_cost,
    solve_dpccp_observed,
)


# =============================================================================
# Intrinsic selection: should the optimizer use DPccp for this chain?
# =============================================================================

def should_use_dpccp(chain: JoinChain) -> Bool:
    """Decide DPccp vs greedy based on chain shape, not a feature flag.

    Selection rule (the row-count fallback relaxes the original
    NDV-required clause):
      1. chain length must be in [DPCCP_MIN_RELATIONS, DPCCP_MAX_RELATIONS], AND
      2. at least one relation must carry EITHER (a) writer-emitted NDV
         stats (`table_stats`), OR (b) a populated `row_count` on its
         underlying scan (a scan that carries `row_count` while its
         relation has no `table_stats`).

    Returns False otherwise -- the caller should fall through to
    `greedy_join_order`. Keeps DPccp's CPU cost (exponential in n, and
    above canonical on dense graphs: komira-ai/komira#1176) bounded
    to chains where the cost model has SOME signal to work with.

    Row-count fallback rationale:
      A relation whose scan carries only `row_count` has
      `table_stats=None`. Under an NDV-required gate, a chain of such
      relations would never activate DPccp and would always fall back to
      greedy. The solver still has a cost signal for it:
      `solve_dpccp_with_cost` prices pairs through the TDOM graph, whose
      `DefaultColumnStatsProvider` falls back to each relation's
      cardinality, and without a TDOM graph `_cost_for_pair` synthesizes
      NDV from `row_count` via the `ESTIMATED_DISTINCT_RATIO_*` constants.

    Limits (locked in by test_optimizer_dpccp.mojo and
    test_optimizer_dpccp_row_count_fallback.mojo):
      * 1-rel / 2-rel / 3-rel chains: always False (below
        DPCCP_MIN_RELATIONS).
      * Above the relation cap: always False (the pair count is
        exponential in n).
      * Chain at [4, 12] with neither table_stats nor row_count: False
        (no stats signal).
      * Chain at [4, 12] with row_count only (row-count path): True.
      * Chain at [4, 12] with table_stats: True (legacy NDV path).
    """
    var n = len(chain.relations)
    if n < DPCCP_MIN_RELATIONS:
        return False
    if n > DPCCP_MAX_RELATIONS:
        return False
    for i in range(n):
        if chain.relations[i].table_stats:
            return True
        if _leaf_has_row_count(chain.relations[i].plan[]):
            return True
    return False


# =============================================================================
# ⛔ A REORDER MUST PRESERVE THE SUBTREE'S OUTPUT SCHEMA — RESTORE THE NARROW.
#
# `_extract_join_chain_inner` PIERCES a rename-free col-ref Project on a join
# side and drops the node, on a written assumption: "the greedy rebuild produces
# a superset schema (all leaf columns concatenated at every join level), which
# preserves all referenced names." That is true of NAME REFERENCES and false of
# the SUBTREE'S OWN OUTPUT. A `Project([pk, pv])` on a join input is not a
# downstream name reference — it is a statement about WHICH COLUMNS THE RESULT
# CARRIES — so piercing it silently WIDENS the answer.
#
# Example: `Join(Project([pk, pv])(Filter(pflag == 1)(Scan L)), Scan R)` on
# pk == bk, with L = [pk, pv, pflag] and R = [bk, bval]:
#
#   BOUND      output = [pk, pv, bk, bval]
#   REORDERED  the pierce drops the Project, so the rebuilt join carries
#              every leaf column: [pk, pv, pflag, bk, bval] in some order.
#              `pflag`, the column the Project dropped, is back in the
#              output: one column too many.
#
# The pierce is worth keeping — it is what lets a chain reorder through an
# intermediate column-narrowing Project — so the fix is not to stop piercing, it is to put the
# narrow back: a rewrite that changes the shape restores the user-visible
# columns above it.
#
# ⚠ BY NAME IS EXACT HERE, AND ONLY HERE. In general an operand exchange
# MIGRATES the `_right` collision suffix, so a by-name projection cannot undo
# it; a restore would have to be derived POSITIONALLY. This site is
# downstream of the `_chain_relations_share_column_name` barrier — a chain whose
# relations share ANY column name is NOT reordered at all — so within a
# reorderable chain every leaf column name is unique, `LogicalPlan.join` never
# appended `_right`, and the original subtree's names denote exactly one column
# each in the rebuilt superset.
#
# DECLINES rather than guesses: if any original output name is absent from the
# reordered schema the reorder is ABANDONED and the un-reordered rebuild is
# returned. A reorder that cannot be shown to preserve the answer is not worth
# the plan it produces.
# =============================================================================


def _restore_chain_output_schema(
    var reordered: LogicalPlan, var unreordered: LogicalPlan,
) raises -> LogicalPlan:
    """Return `reordered` presenting `unreordered`'s output schema.

    ⛔ WIDENING ONLY. A pure PERMUTATION is deliberately left alone — that is
    what `optimizer_join.restore_join_reorder_output_columns` restores, and
    duplicating it
    here would put a `Project` on top of every reordered chain. Plan-SHAPE
    consumers walk only JOIN/SCAN (`test_q5_plan_shape._plan_leaf_scan_paths`
    is the worked example — a `Project` root makes it report ZERO leaves), so a
    node added on the common path is a behaviour change with no correctness
    story. The widening case is different in kind:
    `restore_join_reorder_output_columns` DECLINES it outright
    (`if n != len(want): return plan^`), so this function and
    `narrow_reordered_join_to_declared_columns` are what repair it.

    Returns `reordered` unchanged when the schemas agree name-for-name in order,
    and when they are permutations of one another. Wraps `reordered` in a
    by-name `LogicalPlan.project` when the subtree's names are a strict SUBSET
    of the rebuilt ones. Returns `unreordered` — i.e. DECLINES the reorder —
    when the restore cannot be expressed by name.

    ⚠ THE DECLINE PATH LEAVES `_join_reorder_fire()` ALREADY BUMPED, so the
    process-global reorder counter over-reports by one there. Stated rather than
    plumbed around: the chain extractor's own superset contract says the path is
    unreachable, and moving the fire would put the counter's meaning
    ("the reorderer emitted a chain") behind a restore decision it does not
    describe.
    """
    # Snapshot both name lists FIRST so neither plan stays borrowed while the
    # other is moved out below.
    var want = List[String]()
    for i in range(unreordered.output_schema.num_columns()):
        want.append(String(unreordered.output_schema.field_name(i)))
    var got = List[String]()
    for i in range(reordered.output_schema.num_columns()):
        got.append(String(reordered.output_schema.field_name(i)))

    if len(got) == len(want):
        var same = True
        for i in range(len(want)):
            if got[i] != want[i]:
                same = False
                break
        if same:
            _ = unreordered^
            return reordered^
        # Same arity, different order: a PERMUTATION iff the name multisets
        # agree. Leave it entirely alone — see the docstring's WIDENING ONLY
        # block. (Checked as a multiset, not a set, so a rebuild that turned two
        # distinct names into two copies of one name is NOT mistaken for a
        # permutation and falls through to the distinctness refusal below.)
        var perm = True
        for i in range(len(want)):
            var c_want = 0
            var c_got = 0
            for j in range(len(want)):
                if want[j] == want[i]:
                    c_want += 1
                if got[j] == want[i]:
                    c_got += 1
            if c_want != c_got:
                perm = False
                break
        if perm:
            _ = unreordered^
            return reordered^

    # Every name the subtree promised must denote EXACTLY ONE column of the
    # rebuilt superset. Present-once, not merely present: a name carried twice
    # makes the by-name projection ambiguous, and picking either occurrence
    # would convert a schema-widening defect into a wrong ANSWER. Same
    # distinctness test `restore_join_reorder_output_columns` applies for the
    # same reason.
    for i in range(len(want)):
        var hits = 0
        for j in range(len(got)):
            if got[j] == want[i]:
                hits += 1
        if hits != 1:
            _ = reordered^
            return unreordered^

    var exprs = ExprArray()
    for i in range(len(want)):
        exprs.append(Expr.col_ref(want[i]))
    _ = unreordered^
    return LogicalPlan.project(exprs^, reordered^)


def _join_reorder_fire():
    """Bump the process-global
    join-reorder fire counter — the test-observable decision pin that the
    reorderer emitted a reordered INNER-join chain. Calls
    `komira_async.runtime.sched_trace.join_reorder_fire_inc`, the safe wrapper
    over the `_posix_shim.c` TU-static relaxed atomic. ZERO overhead on any
    path that does not emit a chain."""
    join_reorder_fire_inc()


# =============================================================================
# reorder_joins_with_dp -- top-level driver with intrinsic DPccp/greedy split
# =============================================================================
#
# Sibling of `optimizer_reorder.reorder_joins` (greedy-only). This variant
# inspects each chain and picks DPccp or greedy via `should_use_dpccp`.
# Lives here (not in optimizer_reorder.mojo) because it imports
# `solve_dpccp` -- importing dpccp from reorder would create a cycle.

# ⛔ THIS BARRIER IS CHAIN-WIDE, NOT TWO-OPERAND.
# Asking whether the JOIN NODE's own two operands collide is a strictly
# weaker question than the one the barrier needs, and is bypassed by every
# chain of three or more relations — see
# `_chain_relations_share_column_name` below for the counterexample.
# `optimizer_join.join_operands_share_column_name` answers the two-operand
# form; do not use it to arm this barrier.


def _collect_chain_relation_names(
    plan: LogicalPlan, mut acc: List[List[String]]
) raises:
    """Append the output column names of every relation `extract_join_chain`
    would flatten this subtree into.

    ⛔ MIRRORS `_extract_join_chain_inner`'S OWN RECURSION, ARM FOR ARM: pierce
    a rename-free passthrough Project, descend through a residual-free
    JOIN_INNER, treat everything else as a leaf. It has to, because the
    question is what the SOLVER will be handed — a barrier derived from a
    different traversal than the one it guards is a barrier with holes in it,
    which is precisely the defect this function exists to close."""
    if _is_rename_free_passthrough_project(plan):
        _collect_chain_relation_names(plan._project.value()[].child[], acc)
        return
    if (
        plan.tag == PLAN_JOIN
        and plan._join.value()[].join_type == JOIN_INNER
        and not plan._join.value()[].has_residual()
    ):
        ref jd = plan._join.value()[]
        _collect_chain_relation_names(jd.left[], acc)
        _collect_chain_relation_names(jd.right[], acc)
        return
    var names = List[String]()
    for i in range(plan.output_schema.num_columns()):
        names.append(plan.output_schema.field_name(i))
    acc.append(names^)


def _chain_relations_share_column_name(plan: LogicalPlan) raises -> Bool:
    """True if ANY TWO relations in this join chain share a column name.

    ⛔ THE BARRIER'S REAL QUESTION, AND THE TWO-OPERAND FORM ABOVE IS NOT IT.
    `_extract_join_chain_inner` recurses through nested JOIN_INNER nodes with
    no collision check of its own, so a barrier evaluated only at the node it
    is written on is BYPASSED by any ancestor that flattens through it.

    Counterexample for a two-operand barrier: three-way chain
    `(A JOIN B) JOIN C` where A and B carry IDENTICAL schemas `(skey, val)`
    and C is disjoint. The TOP join's operands are `(A JOIN B)` and `C`, which
    share NO name, so a two-operand predicate is False there and the barrier
    does not arm — while the solver then re-plans {A, B, C} and may emit B
    before A. Provenance per output column:

        before  [A, A, B, B, C, C]
        after   [B, B, A, A, C, C]      <- A and B EXCHANGED

    with the output NAMES `[skey, val, skey_right, val_right, ckey, cval]`
    IDENTICAL in both — so `restore_join_reorder_output_columns` compares equal
    and declines, and the wrong relation is served under every name. It
    takes a reorder that exchanges the two colliding relations with each
    other; a two-relation join is covered by the two-operand question.

    ⚠ ANY pairwise collision is disqualifying, not just one between the two
    immediate operands: whichever of the two colliding relations the rebuild
    places FIRST keeps the bare name and the other takes `_right`, so their
    relative order alone decides which relation each name denotes. The chain
    rebuild carries no provenance map to restore that from (DuckDB's
    `left/right_projection_map`, which our IR does not have), so the only
    sound answer here is to decline — exactly as a residual-carrying join
    declines."""
    var rels = List[List[String]]()
    _collect_chain_relation_names(plan, rels)
    for i in range(len(rels)):
        for j in range(i + 1, len(rels)):
            var seen = Dict[String, Bool]()
            for a in range(len(rels[i])):
                seen[rels[i][a]] = True
            for b in range(len(rels[j])):
                if rels[j][b] in seen:
                    return True
    return False


def reorder_joins_with_dp(var plan: LogicalPlan) raises -> LogicalPlan:
    """Walk the plan tree and reorder each maximal INNER-join subtree.

    Per-chain solver selection (no feature flag):
      - DPccp when `should_use_dpccp(chain)` returns True (chain length
        in [4, 12] AND at least one leaf has NDV stats or a row count).
      - Greedy otherwise (or as fallback when DPccp returns None:
        iteration overflow, or a plan whose top join is a synthesized
        cross).

    For non-INNER joins (LEFT / RIGHT / FULL / SEMI / ANTI / CROSS),
    residual-carrying INNER joins and INNER joins whose chain relations
    share a column name, we only recurse -- they're reorder barriers.
    """
    var tag = plan.tag

    if tag == PLAN_JOIN:
        var jt = plan._join.value()[].join_type
        # A residual-carrying join (`predicate=` non-equi /
        # range / complex) is NOT reorderable — flattening it into a join
        # chain would lose the residual condition. Recurse into the
        # children and rebuild PRESERVING the residual.
        var has_resid = plan._join.value()[].has_residual()
        # ⛔ A NAME-COLLIDING *CHAIN* IS A REORDER BARRIER.
        # ⚠ CHAIN, NOT OPERANDS. The two-operand question is bypassed by
        # every chain of three or more — see
        # `_chain_relations_share_column_name` for the three-way
        # counterexample that is silent in both the names and the verdict.
        # `LogicalPlan.join` appends `_right` to a colliding RIGHT name, so for
        # such a join the output schema depends on operand ORDER for more than
        # order: after an exchange the bare name denotes the OTHER relation.
        # This solver rebuilds a chain from scratch and has no provenance map
        # to restore from (DuckDB's `left/right_projection_map`, which our IR
        # does not carry), so reordering here would silently REASSIGN names:
        # in an INNER join whose sides both carry `val`, putting the right
        # side first makes `val` name the right side's column.
        # Treat it as a barrier, the same way a residual-carrying join is one.
        # `select_join_build_side` still records a build side on such a join;
        # it moves no operand, so no name is reassigned.
        var _shares = _chain_relations_share_column_name(plan)
        if jt == JOIN_INNER and not has_resid and not _shares:
            var left = _take_join_left(plan)
            var right = _take_join_right(plan)
            var new_left = reorder_joins_with_dp(left^)
            var new_right = reorder_joins_with_dp(right^)
            var lk = plan._join.value()[].left_on.copy()
            var rk = plan._join.value()[].right_on.copy()
            var rebuilt = LogicalPlan.join(
                new_left^, new_right^, lk^, rk^, JOIN_INNER
            )

            var rebuilt_copy = _copy_plan(rebuilt)
            # ⛔ THE CHAIN EXTRACTOR MAY WIDEN THIS NODE'S OUTPUT. Its Project
            # pierce flattens through a column-narrowing projection and drops
            # it, so the rebuilt chain can carry leaf columns this node had
            # projected away. Capture what THIS node declares, before the
            # extractor sees it, and narrow the rebuild back to it. Full
            # argument:
            # `optimizer_join.narrow_reordered_join_to_declared_columns`.
            var declared_out = join_reorder_output_names(rebuilt_copy)
            var maybe_chain = extract_join_chain(rebuilt^)
            if maybe_chain:
                var chain = maybe_chain.take()
                # Densify the chain
                # graph with transitive equi-join edges derived from join-
                # key equivalence classes. Faithful port of DuckDB's
                # `filter_combiner.cpp:GenerateFilters` O(N**2) closure.
                # Lets DPccp's neighbor traversal form CSGs like Q9's
                # {ps, s, n} that depend on a derived
                # `partsupp <-> supplier` edge from the suppkey class
                # {l_suppkey, s_suppkey, ps_suppkey}. The densification is
                # purely connectivity-level — cost / TDOM machinery is
                # unchanged.
                _ = derive_transitive_edges(chain)
                # Intrinsic selection: DPccp vs greedy.
                var use_dp = should_use_dpccp(chain)
                if use_dp:
                    var dp_result = solve_dpccp(chain)
                    if dp_result:
                        var out = dp_result.take()
                        _join_reorder_fire()
                        # ⚠ TWO LAYERS FOR THE SAME PIERCE DEFECT, COMPOSED.
                        # The inner call
                        # restores the pierced narrow (and DECLINES the reorder
                        # entirely if it cannot); the outer fires only on a
                        # STRICTLY WIDER output (`n <= len(declared)` returns
                        # untouched), so after the inner has run it is a
                        # no-op — a second layer, not a second rewrite.
                        return narrow_reordered_join_to_declared_columns(
                            _restore_chain_output_schema(
                                out^, rebuilt_copy^
                            ),
                            declared_out.copy(),
                        )
                    # Fall through to greedy when DPccp returns None.
                var greedy_out = greedy_join_order(chain^)
                _join_reorder_fire()
                # Same composition as the dpccp arm above — the
                # widening-only outer layer a no-op once the inner
                # restore has succeeded.
                return narrow_reordered_join_to_declared_columns(
                    _restore_chain_output_schema(
                        greedy_out^, rebuilt_copy^
                    ),
                    declared_out^,
                )
            return rebuilt_copy^

        # Non-INNER (or residual-carrying) join: recurse into children
        # and rebuild, preserving the residual.
        var algo = plan._join.value()[].algo_hint
        var residual: Optional[OwnedPointer[Expr]] = None
        if has_resid:
            residual = OwnedPointer(plan._join.value()[].residual.value()[].copy())
        var left = _take_join_left(plan)
        var right = _take_join_right(plan)
        var new_left = reorder_joins_with_dp(left^)
        var new_right = reorder_joins_with_dp(right^)
        var lk = plan._join.value()[].left_on.copy()
        var rk = plan._join.value()[].right_on.copy()
        return LogicalPlan.join(
            new_left^, new_right^, lk^, rk^, jt, algo, residual^,
        )

    elif tag == PLAN_FILTER:
        var child_in = _copy_plan(plan._filter.value()[].child[])
        var new_child = _reorder_joins_with_dp_keeping_order(child_in^)
        plan._filter.value()[].child = OwnedPointer(new_child^)

    elif tag == PLAN_PROJECT:
        var child_in = _copy_plan(plan._project.value()[].child[])
        var new_child = reorder_joins_with_dp(child_in^)
        plan._project.value()[].child = OwnedPointer(new_child^)

    elif tag == PLAN_AGGREGATE:
        var child_in = _copy_plan(plan._aggregate.value()[].child[])
        var new_child = reorder_joins_with_dp(child_in^)
        plan._aggregate.value()[].child = OwnedPointer(new_child^)

    elif tag == PLAN_SORT:
        var child_in = _copy_plan(plan._sort.value()[].child[])
        var new_child = _reorder_joins_with_dp_keeping_order(child_in^)
        plan._sort.value()[].child = OwnedPointer(new_child^)

    elif tag == PLAN_LIMIT:
        var child_in = _copy_plan(plan._limit.value()[].child[])
        var new_child = _reorder_joins_with_dp_keeping_order(child_in^)
        plan._limit.value()[].child = OwnedPointer(new_child^)

    elif tag == PLAN_DISTINCT:
        var child_in = _copy_plan(plan._distinct.value()[].child[])
        var new_child = _reorder_joins_with_dp_keeping_order(child_in^)
        plan._distinct.value()[].child = OwnedPointer(new_child^)

    elif tag == PLAN_TOPN:
        var child_in = _copy_plan(plan._topn.value()[].child[])
        var new_child = _reorder_joins_with_dp_keeping_order(child_in^)
        plan._topn.value()[].child = OwnedPointer(new_child^)

    return plan^


def _reorder_joins_with_dp_keeping_order(
    var child: LogicalPlan,
) raises -> LogicalPlan:
    """Reorder `child` for a parent that emits its child's columns in the
    child's order (Filter, Sort, Limit, Distinct, TopN), and put back the
    order `child` had before the walk.

    The walker replaces such a parent's child without recomputing the
    parent's cached schema, so the parent keeps reporting the old order. The
    driver's guard around the reorder reads only the root's cached schema and
    cannot see a permutation below one of these parents; this restores it at
    the boundary, where the old order is still known. A Project or Aggregate
    parent reads its child by name and needs no restore; a join parent is
    rebuilt with a recomputed schema, so its order moves up to here or to the
    root guard. `restore_join_reorder_output_columns` adds a Project only for
    a permutation and declines anything else."""
    var before = join_reorder_output_names(child)
    return restore_join_reorder_output_columns(
        reorder_joins_with_dp(child^), before^
    )
