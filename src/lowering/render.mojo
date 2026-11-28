# =============================================================================
# render -- the deterministic text of a LoweredPlan
# =============================================================================
#
# One line per fact, in a fixed order, so equal plans render byte-equal and a
# difference shows on the line that differs. Nothing in it comes from a clock,
# an address or the iteration order of a map.
# =============================================================================

from lowering.lowered_plan import LoweredPlan
from lowering.sink_capability import triple_name
from physical_plan.iceberg_scan_spec import IcebergScanSpec
from physical_plan.udf_call_spec import UdfCallSpec
from plan_expr.null_order_policy import derived_nulls_first
from plan_ir.logical_plan import ASOF_BACKWARD, ASOF_FORWARD
from plan_ir.udf_ref import udf_ref_kind_name
from physical_plan.physical_plan import (
    AsofJoinSinkData,
    SegmentDescPod,
    MorselOp,
    SOURCE_PARQUET,
    SOURCE_BATCH,
    SOURCE_SINK_OUTPUT,
    SOURCE_CONCAT,
    SOURCE_CSV,
    SOURCE_UDF_STEP,
    SOURCE_ICEBERG,
    SOURCE_JSONL,
    OP_FILTER,
    OP_PROJECT,
    OP_LIMIT,
    OP_JOIN_PROBE,
    OP_UDF_APPLY,
    OP_UDF_FRAME,
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
    if kind == SOURCE_CSV:
        return "SOURCE_CSV"
    if kind == SOURCE_UDF_STEP:
        return "SOURCE_UDF_STEP"
    if kind == SOURCE_ICEBERG:
        return "SOURCE_ICEBERG"
    if kind == SOURCE_JSONL:
        return "SOURCE_JSONL"
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


def _ints(items: List[Int]) -> String:
    var out = String("[")
    for i in range(len(items)):
        if i > 0:
            out += ", "
        out += String(items[i])
    out += "]"
    return out^


def _iceberg_text(spec: IcebergScanSpec) -> String:
    """` columns=[name:TYPE#field_id, ...] files=[...] deletes=[...]`: each
    file with the path it opens, the path its manifest stores and the indices
    of the delete files that apply; each delete file with its content, format
    and equality columns."""
    var out = String(" columns=[")
    for i in range(len(spec.column_names)):
        if i > 0:
            out += ", "
        out += (
            spec.column_names[i]
            + ":"
            + String(spec.column_types[i])
            + "#"
            + String(spec.column_field_ids[i])
        )
    out += "] files=["
    for f in range(len(spec.data_files)):
        if f > 0:
            out += ", "
        ref df = spec.data_files[f]
        out += (
            df.path
            + " (stored="
            + df.stored_path
            + " position_deletes="
            + _ints(df.position_deletes)
            + " equality_deletes="
            + _ints(df.equality_deletes)
            + ")"
        )
    out += "] deletes=["
    for d in range(len(spec.deletes)):
        if d > 0:
            out += ", "
        ref dl = spec.deletes[d]
        out += (
            dl.path
            + " (content="
            + String(dl.content)
            + " format="
            + dl.file_format
            + " equality_columns="
            + _names(dl.equality_columns)
            + ")"
        )
    out += "]"
    return out^


def _call_text(spec: UdfCallSpec) -> String:
    """`udf=<index> <KIND>`, then whichever of reads, args, literals and out
    the call carries."""
    var out = (
        "udf=" + String(spec.udf_index) + " " + udf_ref_kind_name(spec.kind)
    )
    if len(spec.reads) > 0:
        out += " reads=" + _names(spec.reads)
    if len(spec.args) > 0:
        out += " args=["
        for i in range(len(spec.args)):
            if i > 0:
                out += ", "
            out += String(spec.args[i])
        out += "]"
    if len(spec.literals) > 0:
        out += " literals=["
        for i in range(len(spec.literals)):
            if i > 0:
                out += ", "
            out += String(spec.literals[i])
        out += "]"
    return out + " out=" + _names(spec.out_names)


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
        var text = "JOIN_PROBE build_seg=" + String(op.probe_build_seg) + " on=["
        for k in range(len(op.probe_left_keys)):
            if k > 0:
                text += ", "
            text += op.probe_left_keys[k] + "=" + op.probe_right_keys[k]
        return text + "]"
    if op.tag == OP_UDF_APPLY:
        return "UDF_APPLY " + _call_text(op.udf.value())
    if op.tag == OP_UDF_FRAME:
        return "UDF_FRAME " + _call_text(op.udf.value())
    return "OP_" + String(Int(op.tag))


def _segment_text(seg: SegmentDescPod) -> String:
    var out = String("segment ") + String(seg.seg_id) + "\n"
    out += "  source: " + _source_name(seg.source_kind)
    if seg.source_kind == SOURCE_PARQUET:
        ref s = seg.source_spec
        out += " path=" + s.parquet_path
        out += " total=" + String(s.parquet_spec_is_total)
        if not s.parquet_fs.is_local():
            out += " fs=" + s.parquet_fs.url_prefix()
        if len(s.parquet_paths) > 0:
            out += " files=" + _names(s.parquet_paths)
            if len(s.parquet_partition_cols) > 0:
                var cols = List[String]()
                for i in range(len(s.parquet_partition_cols)):
                    cols.append(String(s.parquet_partition_cols[i].name))
                out += " partitions=" + _names(cols)
                out += " partition_values=["
                for f in range(len(s.parquet_partition_values)):
                    if f > 0:
                        out += ", "
                    out += _names(s.parquet_partition_values[f])
                out += "]"
        if s.parquet_projection:
            out += " projection=" + _names(s.parquet_projection.value())
        if s.parquet_filter:
            out += " filter=" + String(s.parquet_filter.value())
    elif seg.source_kind == SOURCE_BATCH:
        out += " batch=" + String(seg.source_spec.batch_handle_id)
    elif seg.source_kind == SOURCE_CSV:
        ref s = seg.source_spec
        out += " path=" + s.csv_spec.path
        out += " delimiter=" + String(Int(s.csv_spec.delimiter))
        out += " header=" + String(s.csv_spec.has_header)
        out += " quote_style=" + String(s.csv_spec.quote_style_tag)
        out += " columns=["
        for i in range(len(s.csv_spec.column_names)):
            if i > 0:
                out += ", "
            out += s.csv_spec.column_names[i] + ":" + String(s.csv_spec.column_types[i])
        out += "]"
    elif seg.source_kind == SOURCE_ICEBERG:
        out += _iceberg_text(seg.source_spec.iceberg_spec)
    elif seg.source_kind == SOURCE_UDF_STEP:
        out += " " + _call_text(seg.source_spec.udf_step.value())
    elif seg.source_kind == SOURCE_JSONL:
        ref s = seg.source_spec
        out += " path=" + s.jsonl_path + " columns=["
        for i in range(s.jsonl_schema.num_columns()):
            if i > 0:
                out += ", "
            out += s.jsonl_schema.field_name(i) + ":"
            out += String(s.jsonl_schema.field_arrow_type(i))
        out += "]"
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


def _asof_strategy_name(strategy: UInt8) -> String:
    if strategy == ASOF_BACKWARD:
        return "backward"
    if strategy == ASOF_FORWARD:
        return "forward"
    return "nearest"


def _asof_line(i: Int, a: AsofJoinSinkData) -> String:
    """One `asof` row: the key pairs, the ASOF column pair, the strategy, the
    storage the walker reads, the tolerance, which sides the plan calls
    sorted, and the segment of the right side."""
    var out = String("  asof ") + String(i) + ": keys=["
    for k in range(len(a.left_keys)):
        if k > 0:
            out += ", "
        out += a.left_keys[k] + "=" + a.right_keys[k]
    out += "] on=" + a.left_asof + "~" + a.right_asof
    out += " strategy=" + _asof_strategy_name(a.strategy)
    out += " dtype=" + String(a.asof_dtype)
    if a.tolerance.is_int64():
        out += " tolerance=" + String(a.tolerance.int_val)
    elif a.tolerance.is_float64():
        out += " tolerance=" + String(a.tolerance.float_val)
    else:
        out += " tolerance=none"
    if len(a.left_sort_keys) > 0:
        out += " left_sorted"
    if len(a.right_sort_keys) > 0:
        out += " right_sorted"
    out += " right_seg=" + String(a.right_seg_id) + "\n"
    return out^


def render_lowered_plan(plan: LoweredPlan) -> String:
    """The text of `plan`: its segments, its parameter table (a `params:`
    header counting the agg, sort, top-n, window and batch rows, then a line
    for each aggregation, sort, top-n, window and as-of join and a `udf` line
    for each `UdfRef`) and its result."""
    var out = String("ir_version ") + String(plan.segments[0].ir_version) + "\n"
    for i in range(len(plan.segments)):
        out += _segment_text(plan.segments[i])
    ref p = plan.params
    out += (
        "params: agg="
        + String(len(p.agg))
        + " sort="
        + String(len(p.sort))
        + " topn="
        + String(len(p.topn))
        + " window="
        + String(len(p.window))
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
    for i in range(len(p.topn)):
        ref t = p.topn[i]
        out += "  topn " + String(i) + ": keys="
        for k in range(len(t.sort_keys)):
            if k > 0:
                out += ", "
            out += t.sort_keys[k]
            out += " desc" if t.descending[k] else " asc"
            out += " nulls_first" if t.nulls_first[k] else " nulls_last"
        out += " offset=" + String(t.offset) + " n=" + String(t.n) + "\n"
    for i in range(len(p.window)):
        ref w = p.window[i]
        out += "  window " + String(i) + ": partition=" + _names(w.partition_keys)
        out += " order=["
        for k in range(len(w.order_keys)):
            if k > 0:
                out += ", "
            out += w.order_keys[k]
            out += " desc" if w.descending[k] else " asc"
            # The placement is written only when it is not the derived one.
            if k < len(w.nulls_first) and w.nulls_first[k] != derived_nulls_first(
                w.descending[k]
            ):
                out += " nulls_first" if w.nulls_first[k] else " nulls_last"
        out += "] exprs=["
        for k in range(len(w.partition_exprs)):
            if k > 0:
                out += ", "
            out += String(w.partition_exprs[k])
        out += "]\n"
    for i in range(len(p.asof)):
        out += _asof_line(i, p.asof[i])
    for i in range(len(p.udfs)):
        ref u = p.udfs[i]
        out += (
            "  udf "
            + String(i)
            + ": "
            + udf_ref_kind_name(u.kind)
            + " runtime="
            + u.code.runtime
            + " entry="
            + u.code.entry
            + "\n"
        )
    out += "result: segment " + String(plan.result_seg_id) + "\n"
    return out^
