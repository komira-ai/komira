# =============================================================================
# cut_scan_avro -- the cutter's source arm for an Avro scan
# =============================================================================
#
# A scan of one local Avro object container file (`SOURCE_VARIANT_AVRO`, the
# leaf `read_avro('path')` binds to) opens a SOURCE_AVRO pipeline. The spec
# names the file and the columns the segment delivers: the scan's projection,
# in its order, at the types the plan was bound at (the ones the file's header
# gives). A pushed filter becomes an operator (the Avro kind declares no
# pushdown, so only a hand-built plan carries one): the spec then delivers
# every column, the filter runs over them, and the projection follows as an
# operator. The cut is the JSON arm's (`cut_scan_jsonl._open_file_scan`): the
# two bindings have the same shape, a `path` and the bound schema.
#
# Lowering opens no file, so the file's types are checked where it is read
# (`pipeline_exec.source_avro`), not here.
#
# Refused (LOWERING_UNCUTTABLE_NODE): a projection that names a column the
# scan's schema does not hold, which no reader can deliver.
# =============================================================================

from lowering.cut_scan_jsonl import _open_file_scan
from lowering.cut_state import _Pipe
from plan_expr.expr import Expr
from plan_ir.logical_plan import LogicalPlan
from physical_plan.physical_plan import SOURCE_AVRO


def _open_avro_scan(
    node: LogicalPlan,
    idx: Int,
    var proj: Optional[List[String]],
    var pushed: Optional[Expr],
) raises -> _Pipe:
    """The pipeline a PLAN_SCAN node over an Avro source opens."""
    return _open_file_scan(node, idx, proj^, pushed^, SOURCE_AVRO, "an Avro scan")
