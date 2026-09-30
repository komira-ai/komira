# =============================================================================
# core.plan -- plan types (Expr, AggExpr, LogicalPlan, etc.)
#
# Re-exports here are kept narrow on purpose: only the trait-level / IR-
# level surfaces that cross pkg boundaries (`StatsProvider`,
# `PhysicalType`, `PHYSICAL_PLAN_IR_VERSION`). Concrete plan / expr
# structs continue to be imported from their module files directly.
# =============================================================================

from .physical_type import PhysicalType
from .stats_provider import StatsProvider
from .physical_plan import PHYSICAL_PLAN_IR_VERSION
