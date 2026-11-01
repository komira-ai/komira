# =============================================================================
# render -- the deterministic text of a LoweredPlan
# =============================================================================
#
# One line per fact, in a fixed order, so equal plans render byte-equal and a
# difference shows on the line that differs. Nothing in it comes from a clock,
# an address or the iteration order of a map.
# =============================================================================

from komira_lowering.lowered_plan import LoweredPlan
from komira_lowering.sink_capability import triple_name
from komira_physical_plan.physical_plan import (
    SegmentDescPod,
    MorselOp,
    SOURCE_PARQUET,
    SOURCE_BATCH,
    SOURCE_SINK_OUTPUT,
    SOURCE_CONCAT,
    OP_FILTER,
    OP_PROJECT,
    OP_LIMIT,
    OP_JOIN_PROBE,
    EDGE_E1_MORSEL_STREAM,
    EDGE_E2_INGEST_STREAM,
    EDGE_E3_PUBLISH_WAIT,
    EDGE_E4_PARTITION_WISE,
    EDGE_E5_INDEPENDENT,
    ORDER_NONE,
    ORDER_PARTITION_ID,
    ORDER_ROW_RANGE,
)


def _source_name(kind: UInt8) -> String:
    if kind == SOURCE_PARQUET:
        return "SOURCE_PARQUET"
    if kind == SOURCE_BATCH:
        return "SOURCE_BATCH"
    if kind == SOURCE_SINK_OUTPUT:
        return "SOURCE_SINK_OUTPUT"
    if kind == SOURCE_CONCAT:
        return "SOURCE_CONCAT"
    return "SOURCE_" + String(Int(kind))


def _edge_name(tag: UInt8) -> String:
    if tag == EDGE_E1_MORSEL_STREAM:
        return "E1"
    if tag == EDGE_E2_INGEST_STREAM:
        return "E2"
    if tag == EDGE_E3_PUBLISH_WAIT:
        return "E3"
    if tag == EDGE_E4_PARTITION_WISE:
        return "E4"
    if tag == EDGE_E5_INDEPENDENT:
        return "E5"
    return "E" + String(Int(tag))


def _order_name(kind: UInt8) -> String:
    if kind == ORDER_NONE:
        return "ORDER_NONE"
    if kind == ORDER_PARTITION_ID:
        return "ORDER_PARTITION_ID"
    if kind == ORDER_ROW_RANGE:
        return "ORDER_ROW_RANGE"
    return "ORDER_" + String(Int(kind))


def _names(items: List[String]) -> String:
    var out = String("[")
    for i in range(len(items)):
        if i > 0:
            out += ", "
        out += items[i]
    out += "]"
    return out^


def _op_line(op: MorselOp) -> String:
    if op.tag == OP_FILTER:
        return "FILTER " + String(op.filter_predicate.value())
    if op.tag == OP_PROJECT:
        var out = String("PROJECT ")
        ref exprs = op.project_exprs.value()
        ref names = op.project_names.value()
        for i in range(len(exprs)):
            if i > 0:
                out += ", "
            out += names[i] + " := " + String(exprs[i])
        return out^
    if op.tag == OP_LIMIT:
        return "LIMIT " + String(op.limit_count)
    if op.tag == OP_JOIN_PROBE:
        return "JOIN_PROBE build_seg=" + String(op.probe_build_seg)
    return "OP_" + String(Int(op.tag))


def _segment_text(seg: SegmentDescPod) -> String:
    var out = String("segment ") + String(seg.seg_id) + "\n"
    out += "  source: " + _source_name(seg.source_kind)
    if seg.source_kind == SOURCE_PARQUET:
        ref s = seg.source_spec
        out += " path=" + s.parquet_path
        out += " total=" + String(s.parquet_spec_is_total)
        if s.parquet_projection:
            out += " projection=" + _names(s.parquet_projection.value())
        if s.parquet_filter:
            out += " filter=" + String(s.parquet_filter.value())
    elif seg.source_kind == SOURCE_BATCH:
        out += " batch=" + String(seg.source_spec.batch_handle_id)
    else:
        out += " from="
        for i in range(len(seg.source_spec.dep_seg_ids)):
            if i > 0:
                out += ","
            out += String(seg.source_spec.dep_seg_ids[i])
    out += "\n"
    for i in range(len(seg.ops)):
        out += "  op " + String(i) + ": " + _op_line(seg.ops[i]) + "\n"
    out += (
        "  sink: "
        + triple_name(seg.sink_kind, seg.sink_key_dtype, seg.sink_orientation)
        + " param="
        + String(seg.sink_param_id)
        + " state="
        + String(seg.sink_state_id)
        + "\n"
    )
    out += "  deps:"
    if len(seg.deps) == 0:
        out += " none"
    for i in range(len(seg.deps)):
        out += " " + String(seg.deps[i]) + "/" + _edge_name(seg.edge_tags[i])
    out += "\n"
    out += (
        "  order: "
        + _order_name(seg.order_key_kind)
        + " partitions="
        + String(seg.partition_count)
        + "\n"
    )
    out += (
        "  estimates: morsel_rows="
        + String(seg.morsel_rows)
        + " card_rows="
        + String(seg.card_estimate_rows)
        + " mem_bytes="
        + String(seg.mem_estimate_bytes)
        + "\n"
    )
    return out^


def render_lowered_plan(plan: LoweredPlan) -> String:
    """The text of `plan`: its segments, its parameter table and its result."""
    var out = String("ir_version ") + String(plan.segments[0].ir_version) + "\n"
    for i in range(len(plan.segments)):
        out += _segment_text(plan.segments[i])
    ref p = plan.params
    out += (
        "params: agg="
        + String(len(p.agg))
        + " sort="
        + String(len(p.sort))
        + " batches="
        + String(len(p.batches))
        + "\n"
    )
    for i in range(len(p.agg)):
        ref a = p.agg[i]
        out += "  agg " + String(i) + ": group_by=["
        for k in range(len(a.group_by_exprs)):
            if k > 0:
                out += ", "
            out += String(a.group_by_exprs[k])
        out += "] aggs=["
        for k in range(len(a.agg_exprs)):
            if k > 0:
                out += ", "
            out += String(a.agg_exprs[k])
        out += "]\n"
    for i in range(len(p.sort)):
        ref s = p.sort[i]
        out += "  sort " + String(i) + ": keys="
        for k in range(len(s.sort_keys)):
            if k > 0:
                out += ", "
            out += s.sort_keys[k]
            out += " desc" if s.descending[k] else " asc"
            out += " nulls_first" if s.nulls_first[k] else " nulls_last"
        out += "\n"
    out += "result: segment " + String(plan.result_seg_id) + "\n"
    return out^
