"""`komira_optimizer` -- logical-plan rewrite rules and the estimates they use.

Filter fusion, decomposition, OR factoring, symmetric-OR decomposition and
predicate pushdown; cross-join elimination, equi-filter folding into joins,
transitive join edges and non-equi join predicate decomposition; pushing a
join's single-side ON residual to the owning child; greedy join reordering,
TDOM equivalence classes, and cardinality and selectivity estimates;
correlated-subquery flattening, scalar-subquery decorrelation and resolution,
and the scalar broadcast; eager and partial aggregation, the SUM rewrite and
group-key elision; the Project-merge substitution and its safety check; limit
pushdown, sort + limit fusion into TopN, TopN below a Project and the TopN
tie-break; partition pruning, view resolution, payload narrowing and
shared-relation CSE; and the row-count estimate. A rule takes a `LogicalPlan`
and returns or rewrites it; none executes anything. komira_optimizer has no
driver that orders its passes.

It depends on `komira_plan_ir`, `komira_plan_expr`, `komira_plan_stats`,
`komira_arrow`, `komira_kernels` (the join-key envelope), `komira_collections`
and `komira_scan_source`, and on no engine package.

Public API: import directly from sub-modules. No facade.
"""
