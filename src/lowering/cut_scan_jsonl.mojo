# =============================================================================
# cut_scan_jsonl -- the cutter's source arm for a JSON scan
# =============================================================================
#
# A scan of one newline-delimited JSON file (`SOURCE_VARIANT_JSON`, the leaf
# `read_json`, `read_ndjson` and `read_json_auto` bind to) opens a
# SOURCE_JSONL pipeline. The spec names the file and the schema it is read at:
# the scan's projection, in its order, at the types the plan was bound at, so
# the keys the query does not read are skipped by the reader and the file is
# never inferred again. A pushed filter becomes an operator (the JSON kind
# declares no pushdown, so only a hand-built plan carries one): the file is
# then read at its full schema, the filter runs over it, and the projection
# follows as an operator.
#
# Refused (LOWERING_UNCUTTABLE_NODE): a projection that names a column the
# scan's schema does not hold, which no reader can deliver.
# =============================================================================

from arrow.schema import Schema, SchemaBuilder
from containers.slab import Slab
from lowering.cut_state import _Pipe, _uncuttable
from plan_expr.expr import Expr
from plan_ir.logical_plan import LogicalPlan
from physical_plan.physical_plan import SourceSpecPod, MorselOp, SOURCE_JSONL


def _projected(
    node: LogicalPlan,
    full: Schema,
    ref names: List[String],
    scan: StaticString,
) raises -> Schema:
    """The fields of `full` that `names` name, in the order of `names`.
    `scan` describes the scan ("a JSON scan") in the refusal for a name `full`
    lacks."""
    var sb = SchemaBuilder()
    for i in range(len(names)):
        var found = False
        for j in range(full.num_columns()):
            if full.field_name(j) == names[i]:
                sb.add_field(full.field_at_unchecked(j))
                found = True
                break
        if not found:
            raise _uncuttable(
                node,
                String(scan)
                + " that projects '"
                + names[i]
                + "', a column its schema does not hold",
            )
    return sb.build()


def _open_jsonl_scan(
    node: LogicalPlan,
    idx: Int,
    var proj: Optional[List[String]],
    var pushed: Optional[Expr],
) raises -> _Pipe:
    """The pipeline a PLAN_SCAN node over a JSON source opens."""
    ref binding = node.scan_data_ref().source.binding_ref()
    var path = binding.params.get_str(String("path"))
    var full = binding.source_schema()
    if not pushed:
        var read = full.copy()
        if proj:
            read = _projected(node, full, proj.value(), "a JSON scan")
        return _Pipe(
            SOURCE_JSONL, SourceSpecPod.jsonl(path^, read.copy()), read^, idx
        )
    # A pushed filter reads the columns of the whole file: it may name a
    # column the projection leaves out.
    var pipe = _Pipe(
        SOURCE_JSONL, SourceSpecPod.jsonl(path^, full.copy()), full.copy(), idx
    )
    pipe.append_op(MorselOp.filter(pushed.take()))
    if proj:
        ref cols = proj.value()
        var exprs = Slab[Expr]()
        var names = List[String]()
        for i in range(len(cols)):
            exprs.append(Expr.col_ref(cols[i]))
            names.append(String(cols[i]))
        pipe.schema = _projected(node, full, cols, "a JSON scan")
        pipe.append_op(MorselOp.project(exprs^, names^))
        pipe.has_project = True
    return pipe^
