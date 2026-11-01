# =============================================================================
# logical_plan_udf — the payloads of the user-code plan nodes
# =============================================================================
#
# `PLAN_MAP_BATCHES` and `PLAN_STEP` (optimized_plan_udfs.md §10.2, §10.4)
# call a user function named by its index in the `UdfRef` list beside the
# plan (`udf_ref.mojo`). Each node's output schema is the children of that
# `UdfRef`'s `return_type` (a struct): the node is built with it, and the
# plan-wire decoder holds it to the list. Nothing in this tree lowers or runs
# either node yet: lowering and the UDF runtimes are later stages.
#
# Kept out of `logical_plan_variants.mojo` only for size. Like the variants,
# this module and `logical_plan.mojo` import each other; the recursive edge
# goes through `OwnedPointer[LogicalPlan]`.
# =============================================================================

from std.memory import OwnedPointer

from komira_plan_expr.expr import Expr
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import LogicalPlan


struct MapBatchesData(Movable):
    """Payload for `LogicalPlan` tag `PLAN_MAP_BATCHES`: a MAP_BATCHES_FRAME
    UDF over `child`, called once per batch, or once per group when
    `group_by` is non-empty. It may return any number of rows.

    Fields:
        child: the input.
        udf_index: the `UdfRef` index; its kind is MAP_BATCHES_FRAME.
        group_by: the grouping expressions over the child's columns; empty
            for one call per batch.
    """

    var child: OwnedPointer[LogicalPlan]
    var udf_index: Int
    var group_by: List[Expr]

    def __init__(
        out self, var child: LogicalPlan, udf_index: Int, var group_by: List[Expr]
    ):
        self.child = OwnedPointer(child^)
        self.udf_index = udf_index
        self.group_by = group_by^

    def copy(self) -> Self:
        """Deep-clone (recurses into the child plan and the expressions)."""
        var g = List[Expr](capacity=len(self.group_by))
        for i in range(len(self.group_by)):
            g.append(self.group_by[i].copy())
        return Self(self.child[].copy(), self.udf_index, g^)

    # PORT(1.0.0): explicit destructor breaks the non-co-inductive
    # Deinitable check on this struct's recursive self-reference.
    def __deinit__(deinit self):
        pass


struct StepData(Movable):
    """Payload for `LogicalPlan` tag `PLAN_STEP`: a STEP UDF, a source with no
    child that runs exactly once per run.

    Fields:
        udf_index: the `UdfRef` index; its kind is STEP.
        args: the literal arguments, in call order.
    """

    var udf_index: Int
    var args: List[ScalarValue]

    def __init__(out self, udf_index: Int, var args: List[ScalarValue]):
        self.udf_index = udf_index
        self.args = args^

    def copy(self) -> Self:
        var a = List[ScalarValue](capacity=len(self.args))
        for i in range(len(self.args)):
            a.append(self.args[i].copy())
        return Self(self.udf_index, a^)
