# =============================================================================
# udf_call_spec -- one user-function call of a segment, as inert data
# =============================================================================
#
# The payload of the three UDF arms of the IR (version 17):
#
#   OP_UDF_APPLY     a call of a SCALAR, ROW or MAP_BATCHES_COLUMN function:
#                    `args` are evaluated over the morsel and the result is
#                    appended to it as one column, `out_names[0]`.
#   OP_UDF_FRAME     a call of a MAP_BATCHES_FRAME function once per morsel:
#                    it receives exactly the columns `reads` names, in that
#                    order, and its output replaces the morsel, columns
#                    `out_names`. A grouped frame is not an operator.
#   SOURCE_UDF_STEP  a call of a STEP function once per run with the literal
#                    `literals`; its output, columns `out_names`, is the
#                    segment's source.
#
# The function itself is named by `udf_index`, its index in the `UdfRef` list
# the lowered plan carries beside its segments (`lowering.ParamTable.udfs`),
# which is the list the logical plan named it by. `reads` is the read set the
# function declared, for a ROW and a frame: what the engine passes it, and
# nothing else. No runtime handle, worker or context is recorded here: a host
# binds those when it runs the segment.
# =============================================================================

from plan_expr.expr import Expr
from plan_expr.scalar_value import ScalarValue


struct UdfCallSpec(Movable):
    """One user-function call (see the module header for each arm's use of
    the fields)."""

    var udf_index: Int
    """The function's index in the lowered plan's `UdfRef` list."""
    var kind: UInt8
    """The function's call shape, a `plan_ir.udf_ref.UDF_REF_KIND_*` value."""
    var reads: List[String]
    """ROW and MAP_BATCHES_FRAME: the columns the function receives, its read
    set, in the order it declares them. Empty for every other kind."""
    var args: List[Expr]
    """OP_UDF_APPLY: the call's arguments, in call order, over the morsel's
    columns. Empty otherwise."""
    var out_names: List[String]
    """The columns the call writes: the one appended column of an
    OP_UDF_APPLY, every output column of a frame or a step."""
    var literals: List[ScalarValue]
    """SOURCE_UDF_STEP: the literal arguments, in call order. Empty
    otherwise."""

    def __init__(
        out self,
        udf_index: Int,
        kind: UInt8,
        var reads: List[String],
        var args: List[Expr],
        var out_names: List[String],
        var literals: List[ScalarValue] = List[ScalarValue](),
    ):
        self.udf_index = udf_index
        self.kind = kind
        self.reads = reads^
        self.args = args^
        self.out_names = out_names^
        self.literals = literals^

    def copy(self) -> Self:
        """A deep copy (the argument expressions and literals included)."""
        var args = List[Expr](capacity=len(self.args))
        for i in range(len(self.args)):
            args.append(self.args[i].copy())
        var lits = List[ScalarValue](capacity=len(self.literals))
        for i in range(len(self.literals)):
            lits.append(self.literals[i].copy())
        return Self(
            self.udf_index,
            self.kind,
            self.reads.copy(),
            args^,
            self.out_names.copy(),
            lits^,
        )
