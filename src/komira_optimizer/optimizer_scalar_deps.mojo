# =============================================================================
# optimizer_scalar_deps -- the PLAN DEPENDENCY channel
# =============================================================================
#
# THE RULE THIS REALISES:
#
#   "Optimizer's job is just to convert a logical plan to a physical plan, and
#    the physical plan allows for some level of runtime adaptation."
#
# The optimizer is a PURE function. It executes nothing, opens nothing, and
# calls back into no engine. Where it previously EXECUTED an inner sub-plan to
# constant-fold an uncorrelated scalar subquery, it now emits a DEPENDENCY --
# "evaluate this sub-plan, bind its result" -- and the ENGINE resolves it.
#
# ⛔ WHAT THIS REPLACES. `trait SubqueryExecutor.execute_subplan(...) raises ->
# RecordBatch`, called from three optimizer pass sites
# (`optimizer_resolve_scalar_subqueries.mojo`, `optimizer_scalar_broadcast.mojo`
# x2). That callback is what made the optimizer impure, and it is also what made
# the whole pipeline PARAMETRIC on a trait conformer -- which is the
# blocker for an `@extern` boundary, because `@export` refuses a
# parametric function. Removing it is a purity fix AND the compile prerequisite;
# they are the same work.
#
# =============================================================================
# THE PROTOCOL -- two-pass, and it terminates in exactly two
# =============================================================================
#
# `ScalarDepTable` is a bidirectional channel threaded through the optimizer:
#
#   * BINDINGS (engine -> optimizer): resolved values, keyed by the inner
#     plan's `structural_hash()`. EMPTY on the first pass.
#   * REQUESTS (optimizer -> engine): the dependencies the optimizer could not
#     satisfy from `bindings`. Filled on a MISS; the pass then leaves the plan
#     site UNTOUCHED and continues.
#
# The engine drives:
#
#     var deps = ScalarDepTable()
#     var opt  = _optimize_pipeline_core(plan^, deps)     # PURE
#     if deps.has_requests():
#         <engine executes each request, appends a binding>
#         deps.clear_requests()
#         opt = _optimize_pipeline_core(original^, deps)  # PURE, re-plan
#
# ★ WHY THE SECOND PASS RUNS THE WHOLE PIPELINE FROM THE ORIGINAL PLAN, rather
# than binding into the once-optimized output. The two folding passes sit at
# FIXED POSITIONS mid-pipeline -- `resolve_scalar_subqueries_rewrite`
# (BEFORE `flatten_dependent_joins`, `fold_constants`, `push_predicates_down`)
# and `scalar_broadcast_rewrite` (BEFORE projection pushdown,
# `prune_columns`, join reorder, limit pushdown). Every one of those passes sees
# the FOLDED plan today. Re-running from the original with the bindings in hand
# makes the fold happen at the ORIGINAL POSITION with the ORIGINAL VALUE, so the
# second pass's output is byte-identical to what the impure optimizer produced.
# Binding into the already-optimized plan instead would be a cheaper-looking
# shortcut that silently changes the plan shape.
#
# ★ WHY IT TERMINATES IN TWO. Both passes are FIXPOINTS once bound: after
# `resolve_scalar_subqueries` folds, no `EXPR_CORRELATED_SUBQUERY` remains for
# Phase 1 to collect; after `scalar_broadcast` folds, the predicate holds a
# literal and no `EXPR_AGG_FN` remains. So the second pass emits no requests. The
# driver still LOOPS with a cap rather than asserting two, because a chained
# dependency (a subquery whose inner itself contains one) is a shape the cap
# must survive; exceeding it is a REFUSAL, never a silent partial fold.
#
# =============================================================================
# WHAT IS AND IS NOT LOST -- the capability cost, measured against the tree
# =============================================================================
#
# A fold-by-execution lets LATER optimizer passes see the actual value. Under a
# dependency that value arrives at bind time. Because the engine re-invokes the
# PURE optimizer with the value in hand (above), the answer is: NOTHING is lost.
# Enumerated against the real pass list in `optimizer.mojo`:
#
#   * `partition_prune_scans` and `propagate_statistics` DO route on a
#     literal's value -- and both run BEFORE the subquery fold, so the
#     folded scalar has never been visible to them. No capability is lost
#     because none was ever exercised.
#   * `fold_constants` / `simplify_predicates` run AFTER the subquery fold and
#     can see its literal. The re-plan preserves this exactly.
#   * `compute_selectivity` (`optimizer_filter_selectivity.mojo`), which feeds
#     join reordering and the DP cost model, reads a literal's VALUE only when
#     it is a BOOLEAN. Range predicates return a flat `DEFAULT_RANGE_SELECTIVITY`
#     and equality routes on the column's NDV, not the constant. So "knowing the
#     scalar is 5" buys the cost model nothing today even when it is visible.
#   * The parquet pruners (`rg_pruner`, `page_pruner`, `bloom_pruner`) DO route
#     on the value, and they all require the shape `EXPR_COL_REF <op>
#     EXPR_LITERAL`. They run in the ENGINE at scan time, AFTER binding -- so
#     they see a real `EXPR_LITERAL` and prune exactly as before. ⚠ THIS IS THE
#     ONE THAT WOULD HAVE REGRESSED had the design left an unbound parameter
#     node in the predicate instead of substituting a literal at bind time.
#     Row-group, page and bloom pruning would all have gone silently dead.
#
# ⇒ The cost is PLAN TIME: one extra `_optimize_pipeline_core` run for a query
# that actually carries an uncorrelated scalar subquery. A query with none emits
# no requests and runs the pipeline exactly once, unchanged.
# =============================================================================

from std.collections import List, Optional

from komira_collections.slab import Slab

from komira_arrow.schema import Schema
from komira_plan_ir.logical_plan import LogicalPlan
from komira_plan_expr.scalar_value import ScalarValue
from komira_scan_source.in_memory_source import InMemorySource

from komira_plan_ir.plan_helpers import _copy_plan


# =============================================================================
# Dependency kinds
# =============================================================================

# An uncorrelated SCALAR subquery site (`WHERE x > (SELECT AVG(y) FROM s)`).
# Resolution = execute the inner plan, validate 1 column / <= 1 row, extract the
# typed scalar. The binding carries ONLY a `ScalarValue`.
comptime DEP_SCALAR_SUBQUERY: UInt8 = 0

# A scalar-BROADCAST site (`Filter(<pred with EXPR_AGG_FN>) over Aggregate`).
# Resolution is TWO chained executions and the binding is correspondingly
# richer: the group-by Aggregate's MULTI-ROW batch (wrapped as an
# `InMemorySource` the rewrite splices in place of the Aggregate subtree, so the
# outer plan does not re-run the scan + group-by), plus the ungrouped reduction
# of that batch to the scalar the predicate needs.
comptime DEP_SCALAR_BROADCAST: UInt8 = 1


# =============================================================================
# ScalarDepTable -- bindings IN, requests OUT
# =============================================================================


struct ScalarDepTable(Movable):
    """The optimizer's dependency channel. Pure data: no executor, no engine
    handle, no origin parameters -- which is what lets the whole
    pipeline stop being parametric.

    Storage: parallel arrays keyed by list position, with `Slab`
    for the Movable-only `LogicalPlan`. `Schema`, `ScalarValue` and
    `InMemorySource` are all `Copyable`, so they live in plain `List`s.

    ⚠ REQUESTS AND BINDINGS ARE INDEXED DIFFERENTLY ON PURPOSE. A binding is
    found by KEY (the inner plan's structural hash), because the same subquery
    appearing N times in a query is ONE dependency -- that is the Q15-shape
    "same scalar subquery appears N times" win the pre-existing per-call cache bought,
    and keying by hash preserves it across the engine boundary for free. A
    request is appended in ENCOUNTER order and de-duplicated by the same key, so
    the engine executes each distinct inner plan exactly once.
    """

    # ---- REQUESTS: what the optimizer could not satisfy -----------------
    var req_kinds: List[UInt8]
    var req_keys: List[UInt64]
    var req_plans: Slab[LogicalPlan]
    # DEP_SCALAR_BROADCAST only -- the agg op + input column the engine needs to
    # build the ungrouped reduction sub-plan. Unused (0 / "") for
    # DEP_SCALAR_SUBQUERY, whose inner plan is executed as-is.
    var req_ops: List[UInt8]
    var req_cols: List[String]

    # ---- BINDINGS: what the engine resolved ------------------------------
    var bnd_kinds: List[UInt8]
    var bnd_keys: List[UInt64]
    var bnd_scalars: List[ScalarValue]
    # DEP_SCALAR_BROADCAST only, parallel to each other and reached through
    # `bnd_aux_idx[i]`; -1 for a DEP_SCALAR_SUBQUERY row, which has no batch.
    var bnd_aux_idx: List[Int]
    var aux_sources: List[InMemorySource]
    var aux_schemas: List[Schema]
    var aux_names: List[String]

    def __init__(out self):
        self.req_kinds = List[UInt8]()
        self.req_keys = List[UInt64]()
        self.req_plans = Slab[LogicalPlan]()
        self.req_ops = List[UInt8]()
        self.req_cols = List[String]()
        self.bnd_kinds = List[UInt8]()
        self.bnd_keys = List[UInt64]()
        self.bnd_scalars = List[ScalarValue]()
        self.bnd_aux_idx = List[Int]()
        self.aux_sources = List[InMemorySource]()
        self.aux_schemas = List[Schema]()
        self.aux_names = List[String]()

    # ---- request side (written by the optimizer, read by the engine) -----

    @always_inline
    def num_requests(self) -> Int:
        return len(self.req_keys)

    @always_inline
    def has_requests(self) -> Bool:
        return len(self.req_keys) > 0

    def request(
        mut self,
        kind: UInt8,
        key: UInt64,
        var inner_plan: LogicalPlan,
        agg_op: UInt8 = 0,
        var agg_col: String = String(""),
    ):
        """Record an unresolved dependency, de-duplicated by `(kind, key)`.

        A duplicate is DROPPED, not appended: N occurrences of one subquery are
        one execution. The caller does not need to pre-check -- that keeps the
        de-dup rule in ONE place rather than at each of the pass sites."""
        for i in range(len(self.req_keys)):
            if self.req_keys[i] == key and self.req_kinds[i] == kind:
                _ = inner_plan^
                _ = agg_col^
                return
        self.req_kinds.append(kind)
        self.req_keys.append(key)
        self.req_plans.append(inner_plan^)
        self.req_ops.append(agg_op)
        self.req_cols.append(agg_col^)

    def request_kind(self, i: Int) -> UInt8:
        return self.req_kinds[i]

    def request_key(self, i: Int) -> UInt64:
        return self.req_keys[i]

    def request_op(self, i: Int) -> UInt8:
        return self.req_ops[i]

    def request_col(self, i: Int) -> String:
        return self.req_cols[i].copy()

    def request_plan(self, i: Int) raises -> LogicalPlan:
        """A COPY of the i-th requested inner plan, for the engine to execute.

        ⚠ A COPY, NOT A BORROW, AND DELIBERATELY SO. Executing a plan CONSUMES
        it, so the engine needs its own; and `Slab.__getitem__` hands back a
        wildcard-origin reference, which this repo's pointer rules forbid
        crossing a module boundary. `_copy_plan` is the same deep copy the
        optimizer passes use, and it REFUSES a corrupt / partially-moved node
        rather than propagating one."""
        return _copy_plan(self.req_plans[i])

    def clear_requests(mut self):
        """Drop every recorded request, keeping the bindings.

        Called by the engine between optimizer passes: the requests of pass N
        have been resolved into bindings, and pass N+1 must start from an empty
        request list so `has_requests()` reports only what pass N+1 could not
        satisfy."""
        self.req_kinds = List[UInt8]()
        self.req_keys = List[UInt64]()
        self.req_plans = Slab[LogicalPlan]()
        self.req_ops = List[UInt8]()
        self.req_cols = List[String]()

    # ---- binding side (written by the engine, read by the optimizer) -----

    def bind_scalar(mut self, key: UInt64, var value: ScalarValue):
        """Bind a DEP_SCALAR_SUBQUERY dependency to its folded scalar."""
        self.bnd_kinds.append(DEP_SCALAR_SUBQUERY)
        self.bnd_keys.append(key)
        self.bnd_scalars.append(value^)
        self.bnd_aux_idx.append(-1)

    def bind_broadcast(
        mut self,
        key: UInt64,
        var value: ScalarValue,
        var source: InMemorySource,
        var schema: Schema,
        var name: String,
    ):
        """Bind a DEP_SCALAR_BROADCAST dependency to its scalar AND the
        materialized multi-row batch the rewrite splices in place of the
        Aggregate subtree."""
        var aux = len(self.aux_sources)
        self.aux_sources.append(source^)
        self.aux_schemas.append(schema^)
        self.aux_names.append(name^)
        self.bnd_kinds.append(DEP_SCALAR_BROADCAST)
        self.bnd_keys.append(key)
        self.bnd_scalars.append(value^)
        self.bnd_aux_idx.append(aux)

    def binding_index(self, kind: UInt8, key: UInt64) -> Int:
        """Index of the binding for `(kind, key)`, or -1 on a MISS.

        A MISS is the NORMAL first-pass outcome and is never an error: the pass
        records a request and leaves the site alone."""
        for i in range(len(self.bnd_keys)):
            if self.bnd_keys[i] == key and self.bnd_kinds[i] == kind:
                return i
        return -1

    def bound_scalar(self, i: Int) -> ScalarValue:
        return self.bnd_scalars[i].copy()

    def bound_source(self, i: Int) -> InMemorySource:
        """The multi-row `InMemorySource` for a DEP_SCALAR_BROADCAST binding.

        `.copy()` on `InMemorySource` is an `ArcPointer` refcount bump over the
        inner `Slab[RecordBatch]` -- no batch bytes are copied."""
        return self.aux_sources[self.bnd_aux_idx[i]].copy()

    def bound_schema(self, i: Int) -> Schema:
        return self.aux_schemas[self.bnd_aux_idx[i]].copy()

    def bound_name(self, i: Int) -> String:
        return self.aux_names[self.bnd_aux_idx[i]].copy()

    @always_inline
    def num_bindings(self) -> Int:
        return len(self.bnd_keys)
