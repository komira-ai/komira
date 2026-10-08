"""`komira_optimizer` -- logical-plan rewrite rules.

Filter, predicate and OR rewrites (fusion, decomposition, pushdown, cross-join
elimination, OR factoring, symmetric-OR inference); expression rules (constant
folding, predicate simplification, CSE, IN-list rewrite); view resolution and
partition pruning; subquery decorrelation and scalar-subquery resolution through
a `ScalarDepTable` of engine-supplied bindings; join-predicate decomposition,
transitive edges and greedy join reordering with TDOM-based cardinality and
per-column NDV providers; aggregate rewrites (functionally dependent group keys,
eager and partial aggregation below joins, the SUM-of-offset rewrite); join
payload narrowing; limit and TopN rules, partition TopN fusion and window
rewrites; and the non-raising `OptimizeResult`. Every rule takes a
`LogicalPlan` and returns the rewritten plan; none executes anything.

It depends on `komira_plan_ir`, `komira_plan_expr`, `komira_plan_stats`,
`komira_arrow`, `komira_kernels`, `komira_collections`, `komira_exec_types`,
`komira_scan_source` and `komira_libc`.

Public API: import directly from sub-modules. No facade.
"""
