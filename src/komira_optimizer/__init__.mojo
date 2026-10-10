"""`komira_optimizer` -- logical-plan rewrite rules and the estimates they use.

Join rules (inner-to-semi conversion, build-side selection, the SEMI/ANTI
reducer pushdown, the join-reorder output-order guard, absorbing a projection
into an aggregate); filter, predicate and OR rewrites (fusion, decomposition,
pushdown, cross-join elimination, OR factoring, symmetric-OR inference);
expression rules (constant
folding, predicate simplification, CSE, IN-list rewrite); view resolution,
partition pruning and attaching the partition predicate to lazy Hive scans;
projection pushdown, project merge, identity-project elimination and late
materialization; materializing derived aggregate inputs; subquery
decorrelation and scalar-subquery resolution through a `ScalarDepTable`
of engine-supplied bindings; join-predicate decomposition,
transitive edges, greedy and DPccp join reordering with TDOM-based
cardinality and per-column NDV providers; aggregate rewrites (functionally dependent group keys,
eager and partial aggregation below joins, the SUM-of-offset rewrite,
duplicate aggregate folding and common-aggregate dedup); join payload
narrowing; limit and TopN rules, partition TopN fusion and window rewrites;
scan-share planning; the `OptimizerConfig` options value; and the non-raising
`OptimizeResult`. Every rule takes a `LogicalPlan` and returns the rewritten
plan (the duplicate-aggregate collect and find walks return hash counts and a
subtree copy, and scan-share planning returns a `ScanSharePlan` descriptor);
none executes anything. komira_optimizer has no driver that orders its passes.

It depends on `komira_plan_ir`, `komira_plan_expr`, `komira_plan_stats`,
`komira_arrow`, `komira_kernels`, `komira_collections`, `komira_exec_types`,
`komira_scan_source`, `komira_scan_planning`, `komira_counters`, `komira_libc`
and `komira_async` (the join-reorder fire counter).

Public API: import directly from sub-modules. No facade.
"""
