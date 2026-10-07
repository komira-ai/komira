# komira_optimizer

Logical-plan rewrite rules. Each rule takes a `LogicalPlan` and returns the
rewritten plan; nothing here executes a plan.

| module | rules |
|---|---|
| `optimizer_filter` | filter fusion, filter decomposition, predicate pushdown, cross-join elimination and equi-filter folding, join residual to side |
| `optimizer_project_merge_guard` | substituting an outer expression through an inner Project, and whether that is safe; the predicate that means the same below a Project |
| `optimizer_misc` | limit pushdown, sort + limit fusion into TopN, TopN below a Project, row-count estimate |
| `topn_tiebreak_policy` | the deterministic TopN tie-break list as the optimizer reads it |

Public API: import directly from the modules. There is no facade.

Tests live in `tests/` and are welded into the library build.
