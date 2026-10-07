"""`komira_optimizer` -- logical-plan rewrite rules.

Filter fusion, decomposition and predicate pushdown; cross-join elimination
and equi-filter folding into joins; pushing a join's single-side ON residual
to the owning child; the Project-merge substitution and its safety check;
limit pushdown, sort + limit fusion into TopN, TopN below a Project, and the
row-count estimate. Every rule takes a `LogicalPlan` and returns the rewritten
plan; none executes anything.

It depends on `komira_plan_ir`, `komira_plan_expr`, `komira_plan_stats`,
`komira_arrow` and `komira_kernels` (the join-key envelope) and on no engine
package.

Public API: import directly from sub-modules. No facade.
"""
