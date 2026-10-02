# =============================================================================
# komira_xl_plan: an Excel formula to a `LogicalPlan`, with no engine and no
# evaluator. The half of the Excel surface a host can afford to link.
# =============================================================================
#
# The package is severed from the evaluator by PACKAGE, because the unit a
# build gate welds tests to is the package: a consumer inherits the tests of
# every library it links, whichever file it imported. Keeping the plan builder
# in its own library keeps its closure small (it depends on `komira_core` only).
#
#   xl_fn_table        the authoritative Excel function census: one row per
#                      name, the reach bitmask saying which surface recognises
#                      it, and the absence list. Imports nothing.
#   formula_ast        the parsed-formula arena AST
#   formula_parser     the precedence-climbing `=FORMULA(...)` parser
#   formula_value      the number/text/logical/blank/error scalar
#   bound_relation     what an Excel name is bound to (named table | resident)
#   agg_memo           pre-resolved aggregate bindings
#   formula_bindings   `FormulaBindings`: what an Excel name means
#   fn_rel_args        the AST-shaped argument reading the relation verbs share
#   rel_agg_build      SCAN -> AGGREGATE, ctx-free
#   rel_filter_build   SCAN -> FILTER -> PROJECT?, ctx-free
#   rel_condagg_build  SCAN -> FILTER -> AGGREGATE (SUMIF / COUNTIF /
#                      AVERAGEIF). It assembles from the two builders above and
#                      owns only the criteria parse.
#   xl_plan_build      `build_xl_plan`, the entry point
#   xl_scalar_*, xl_*  the scalar kernels (date, text, math, statistics,
#                      financial, engineering) and their shared helpers
#
# Not in here: anything that answers a formula with an execution context in its
# signature. That stays with the evaluator, which imports this package.
#
# It is one set of types and one lowering, not a fork: the evaluator imports
# these modules and does not re-declare them, so the evaluator and the builder
# cannot disagree about what a name means.
#
# The envelope is small on purpose: `build_xl_plan` dispatches only to
# `build_*_plan` functions the executing lowerings also call. The function
# census, `xl_fn_table.xl_function_table()`, is the authority on which names
# are in it: every row carrying `XLR_PLAN` is.
#
# Dependency direction (cycle-free):
#   komira_xl_plan -> komira_core   (LogicalPlan, AggExpr, Schema)
#   evaluators and hosts -> komira_xl_plan
#
# Encapsulation rule: values only throughout. No `UnsafePointer` in any
# signature, no wildcard origins, no `unsafe_from_address`.
# =============================================================================
