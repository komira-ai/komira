# Re-export shim: ExprPool lifted DOWN to komira_core.plan.expr_pool.
#
# ExprPool depends only on core + collections
# (Slab[Expr] over komira_core.collections.slab, ExprId from
# komira_core.traits.expr_id, Expr from komira_core.plan.expr), so it
# lifts cleanly to core. The lift lets komira_morsel import ExprPool from
# the CORE path directly, severing the morsel->compiler feedback edge of the
# 26-pkg engine import-cycle SCC blocking RBE.
#
# This file is retained as a thin re-export shim so the existing
# `from komira_compiler.expr_pool import ExprPool` consumers
# (engine_runtime / parquet / engine_dispatch / engine_operators + tests)
# keep working unchanged.
from komira_core.plan.expr_pool import ExprPool
