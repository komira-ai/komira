# =============================================================================
# cut_scan_orc -- the cutter's source arm for an ORC scan
# =============================================================================
#
# A scan of one ORC file (`SOURCE_VARIANT_ORC`, the leaf `read_orc` binds to)
# opens a SOURCE_ORC pipeline. The spec names the file and the schema it is
# read at: the scan's projection, in its order, at the types the plan was bound
# at (the file's footer), so the columns the query does not read are skipped by
# the reader and the footer is never read again to decide them. A pushed filter
# becomes an operator (the ORC kind declares no pushdown, so only a hand-built
# plan carries one): the file is then read at its full schema, the filter runs
# over it, and the projection follows as an operator.
#
# The spec names the columns by the names the file gives them; a binding's
# `projection.N` index parameters (an `OrcSource` built with a projection) are
# not read, since the bound schema already names every column the scan yields.
#
# Refused (LOWERING_UNCUTTABLE_NODE): a scan whose bound schema has no column,
# which was never bound from the file's footer and would answer the file's row
# count instead of its columns; and a projection that names a column the scan's
# schema does not hold.
# =============================================================================

from containers.slab import Slab
from lowering.cut_scan_jsonl import _projected
from lowering.cut_state import _Pipe, _uncuttable
from plan_expr.expr import Expr
from plan_ir.logical_plan import LogicalPlan
from physical_plan.physical_plan import SourceSpecPod, MorselOp, SOURCE_ORC

comptime _ORC_SCAN: StaticString = "an ORC scan"


def _open_orc_scan(
    node: LogicalPlan,
    idx: Int,
    var proj: Optional[List[String]],
    var pushed: Optional[Expr],
) raises -> _Pipe:
    """The pipeline a PLAN_SCAN node over an ORC source opens."""
    ref binding = node.scan_data_ref().source.binding_ref()
    var path = binding.params.get_str(String("path"))
    var full = binding.source_schema()
    if full.num_columns() == 0:
        raise _uncuttable(
            node,
            "an ORC scan bound with no column (its schema was never read from"
            " the file's footer)",
        )
    if not pushed:
        var read = full.copy()
        if proj:
            read = _projected(node, full, proj.value(), _ORC_SCAN)
        return _Pipe(
            SOURCE_ORC, SourceSpecPod.orc(path^, read.copy()), read^, idx
        )
    # A pushed filter reads the columns of the whole file: it may name a
    # column the projection leaves out.
    var pipe = _Pipe(
        SOURCE_ORC, SourceSpecPod.orc(path^, full.copy()), full.copy(), idx
    )
    pipe.append_op(MorselOp.filter(pushed.take()))
    if proj:
        ref cols = proj.value()
        var exprs = Slab[Expr]()
        var names = List[String]()
        for i in range(len(cols)):
            exprs.append(Expr.col_ref(cols[i]))
            names.append(String(cols[i]))
        pipe.schema = _projected(node, full, cols, _ORC_SCAN)
        pipe.append_op(MorselOp.project(exprs^, names^))
        pipe.has_project = True
    return pipe^
