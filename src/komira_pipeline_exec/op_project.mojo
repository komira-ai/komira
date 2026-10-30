# =============================================================================
# op_project -- OP_PROJECT over the selection mask
# =============================================================================
#
# A projection is `komira_operator_api.MapOp`: it evaluates its expressions
# over the batch and honours an unapplied selection mask (a projection of
# columns alone, or of expressions that cannot raise, runs over the physical
# rows and keeps the mask or compacts its narrow output; any other expression
# sees only the selected rows). This module builds a `MapOp` from the plan's
# `MorselOp`: the expressions are registered once in a pool that the
# per-worker operators share.

from std.memory import ArcPointer

from komira_operator_api.map_op import MapOp
from komira_physical_plan.physical_plan import MorselOp, OP_PROJECT
from komira_plan_expr.expr_id import ExprId
from komira_plan_expr.expr_pool import ExprPool


struct ProjectShared(Movable):
    """What the per-worker projections of one operator share: the registered
    expressions and the output names."""

    var _pool: ArcPointer[ExprPool]
    var _ids: List[ExprId]
    var _names: List[String]

    def __init__(out self, ref spec: MorselOp) raises:
        if spec.tag != OP_PROJECT or not spec.project_exprs:
            raise Error(
                "komira_pipeline_exec: an OP_PROJECT carries no expressions"
            )
        ref exprs = spec.project_exprs.value()
        var names = List[String]()
        if spec.project_names:
            names = spec.project_names.value().copy()
        if len(names) != 0 and len(names) != len(exprs):
            raise Error(
                "komira_pipeline_exec: an OP_PROJECT has "
                + String(len(exprs))
                + " expressions and "
                + String(len(names))
                + " names"
            )
        var pool = ExprPool()
        var ids = List[ExprId]()
        for i in range(len(exprs)):
            ids.append(pool.register(exprs[i].copy()))
        self._pool = ArcPointer[ExprPool](pool^)
        self._ids = ids^
        self._names = names^

    def make(self) raises -> MapOp:
        """A projection for one worker."""
        return MapOp(
            self._ids.copy(), self._names.copy(), ArcPointer(copy=self._pool)
        )
