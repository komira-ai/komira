# komira_optimizer

Logical-plan rewrite rules, plus the cardinality and cost estimates the
join-reorder and aggregate rules read. Each rule takes a `LogicalPlan` and
returns the rewritten plan (most also have an `_inplace` form;
`plan_scan_shares` returns a `ScanSharePlan` descriptor instead); nothing
here executes a plan.

| module | what it holds |
|---|---|
| `optimizer_filter` | filter fusion, filter decomposition, predicate pushdown, cross-join elimination and equi-filter folding, join residual to side |
| `optimizer_filter_selectivity` | predicate-aware filter selectivity estimates and the scaling of table stats by a selectivity |
| `optimizer_or_factoring` | hoisting conjuncts common to every branch of an OR above the OR |
| `optimizer_symmetric_or` | inferring single-column IN predicates from a symmetric swap OR (`(A=x AND B=y) OR (A=y AND B=x)`) |
| `optimizer_project_merge_guard` | substituting an outer expression through an inner Project, and whether that is safe; the predicate that means the same below a Project |
| `optimizer_projection` | projection pushdown to scans and column pruning, project merge, identity-project elimination, late materialization of a Filter's scan |
| `optimizer_materialize_agg_input` | lifting computed aggregate inputs into a Project spliced under the Aggregate |
| `optimizer_join` | inner-to-semi conversion, join build-side selection, the SEMI/ANTI reducer pushdown (`OptimizerConfig.semi_pushdown`), the join-reorder output-order guard and absorbing a projection into an aggregate |
| `optimizer_misc` | limit pushdown, sort + limit fusion into TopN, TopN below a Project, row-count estimate |
| `topn_tiebreak_policy` | the deterministic TopN tie-break list as the optimizer reads it |
| `optimizer_expr` | constant folding, predicate simplification, common subexpression elimination, OR-of-equalities to IN-list rewrite |
| `view_resolution_pass` | inlining registered views in place of view-reference leaves (depth limit, cycle detection) |
| `partition_prune_scans` | Hive-partition pruning of a partitioned scan's path list from Filter conjuncts on partition columns |
| `attach_hive_predicate` | attaching the partition predicate of a Filter (or an empty one) to a lazy dir-scanning Hive scan, leaving the data residual on the Filter |
| `flatten_dependent_joins` | lowering correlated subquery expressions into joins |
| `join_predicate_decompose` | splitting a raw join predicate into equi keys and a residual |
| `scalar_subquery_decorrelate` | lowering an uncorrelated scalar subquery with a provably single-row inner plan into a broadcast cross join |
| `resolve_scalar_subqueries` | finding uncorrelated scalar subqueries and inlining bound values as literals |
| `optimizer_resolve_scalar_subqueries` | the driver for that pass: fold on a binding, record a request on a miss |
| `optimizer_scalar_broadcast` | rewriting a Filter comparing against an aggregate of its own grouped input with a bound scalar value |
| `optimizer_scalar_deps` | `ScalarDepTable`: the bindings and requests through which the engine supplies sub-plan results the optimizer does not execute |
| `optimizer_shared_relation_cse` | detecting a base relation shared by both sides of a decorrelated scalar-subquery cross join, and installing it once for both consumers |
| `optimizer_result` | `OptimizeResult` and the status codes of the non-raising optimizer return channel |
| `optimizer_stats` | cardinality and row-width estimates |
| `optimizer_column_stats_provider` | per-column NDV providers (Parquet-metadata tier, row-count heuristic tier) |
| `optimizer_reorder` | join-chain extraction and greedy cost-based reordering of inner joins |
| `optimizer_transitive_edges` | deriving transitive equi-join edges from column equivalence classes in a join chain |
| `optimizer_tdom` | the TDOM equivalence-class graph and composite NDV |
| `optimizer_tdom_cost` | join cardinality from TDOMs over the bridging edges of a (left, right) split |
| `optimizer_tdom_card` | order-independent cardinality of a combined relation set |
| `optimizer_dpccp` | DPccp join enumeration over a join chain (with a cross-product fallback for disconnected graphs) and `reorder_joins_with_dp`, the inner-join reorder driver that picks DPccp or greedy per chain |
| `optimizer_agg_group_fd` | eliding GROUP BY keys that are deterministic functions of other keys and recomputing them above the aggregate |
| `optimizer_eager_agg` | cross-side eager aggregation: a partial aggregate below an inner join, merged above it |
| `optimizer_partial_agg` | same-side partial aggregate pushdown below an inner join (off by default, behind `ENABLE_AGG_PUSHDOWN_BELOW_JOIN`) |
| `optimizer_sum_rewrite` | `SUM(x + C)` to `SUM(x) + C * COUNT(x)` |
| `optimizer_agg_cse` | finding a duplicated grouped aggregate subtree and replacing it with one shared in-memory source, and collapsing identical aggregate expressions within one Aggregate |
| `optimizer_scan_share` | deciding which Parquet scans share one read (`plan_scan_shares`), the dynamic-filter slot, and which scans stay Parquet sources |
| `optimizer_config` | `OptimizerConfig`: the optimizer's options and their defaults, as one value |
| `optimizer_payload_narrow` | stamping narrow integer payload widths on an equi-join's scans from column min/max stats |
| `optimizer_partition_topn` | fusing a row_number / rank, a `<= K` filter and the column drop into one PartitionTopN |
| `optimizer_window_rewrite` | window co-location and fusion of matching PartitionBy nodes, and eliding a Sort the PartitionBy already satisfies |

It depends on `komira_plan_ir`, `komira_plan_expr`, `komira_plan_stats`,
`komira_arrow`, `komira_kernels`, `komira_collections`, `komira_exec_types`,
`komira_scan_source`, `komira_scan_planning`, `komira_counters`, `komira_libc`
and `komira_async` (the join-reorder fire counter).

Public API: import directly from the modules. There is no facade.

Tests live in `tests/` and are welded into the library build.
