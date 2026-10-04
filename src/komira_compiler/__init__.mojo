"""`komira_compiler` -- LogicalPlan -> PhysicalPlan compilation.

The compiler tier depends ONLY on:
  - komira_core   (PhysicalPlan IR, StatsProvider trait, ScalarValue,
                    LogicalPlan, Expr, AggExpr, helpers)
  - komira_kernels (scalar/SIMD primitives reached through
                    compiler_eval_predicate._eval_predicate; selection
                    vectors come from komira_core.eval)

The compiler MUST NOT depend on the engine, komira_parquet, or
komira_sdk (direct or transitive); its BUCK `deps` enforce this.

Public API (re-exported here so callers may write `from komira_compiler
import ...` without naming the inner module):
  - plan_cse_eliminate, plan_cse_eliminate_forest  (plan_cse)
- estimate_groups  (cardinality_estimator; the Parquet-concrete
    `estimate_groups_from_parquet_metadata` / `ParquetStatsCache` /
    `precompute_*` live in komira_parquet.parquet_cardinality, so the
    compiler never depends on parquet)
  - check_perfect_hash_eligible, check_perfect_hash_composite_eligible,
    detect_perfect_hash_agg, detect_perfect_hash_agg_shape
    (optimizer_perfect_hash) and compute_int_key_domain (stats_helpers):
    a statistics-driven perfect-hash detector that NO planner path consults.
    Do not read them as the perfect-hash gate; the live perfect-hash
    aggregation is `PerfectHashAggUntyped` in `komira_engine_operators`.
  - ExprId, ProjectionSpec  (expr_id; engine + parquet consume these)
  - ExprPool  (expr_pool; engine + parquet consume these)

The LogicalPlan -> runtime lowering lives in the SDK (`lower_untyped`,
which emits a StageRuntimeProgram); this package holds no plan compiler.

Internal modules (no public re-export — engine consumers reach in via
fully-qualified path `komira_compiler.X` when they need them):
  - conjunction  (evaluate_filter_narrowed; engine.morsel_executor uses it)
  - compiler_eval_predicate  (_eval_predicate / lower_filter_predicate;
                    engine runtime path uses these for OP_FILTER)
  - compiler_eval_column  (_eval_column_expr; engine runtime OP_PROJECT)
  - compiler_eval_case  (CASE/WHEN overlays; called from compiler_eval_column)
  - compiler_eval_dict  (_materialize_dict_to_string; dict string-op fallback)
  - plan_budget  (per_operator_budget; only the compiler itself calls it)
"""

from .plan_cse import plan_cse_eliminate, plan_cse_eliminate_forest
from .cardinality_estimator import estimate_groups
from .optimizer_perfect_hash import (
    check_perfect_hash_eligible,
    check_perfect_hash_composite_eligible,
    detect_perfect_hash_agg,
    detect_perfect_hash_agg_shape,
    PerfectHashStrategy,
)
from .stats_helpers import compute_int_key_domain
from .expr_id import ExprId, ProjectionSpec
from .expr_pool import ExprPool

