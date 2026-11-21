# =============================================================================
# cut_aggregate -- the cutter's PLAN_AGGREGATE arm: a breaker
# =============================================================================
#
# An aggregation ends the open pipeline in a SINK_AGG segment whose AggSinkData
# is the next row of the ParamTable's `agg`, and opens a pipeline that reads
# that segment's output. The sink's `(key_dtype, orientation)` comes from the
# group key: none is KEY_DTYPE_NONE; one INT64, INT32, FLOAT64, FLOAT32 or
# STRING column picks that key dtype, COLUMNAR, except that a string column of
# the pipeline's Parquet scan that every row group stores dictionary encoded is
# DICT_ENCODED; several columns are served only when every one is such a
# dictionary string. Any other key is LOWERING_SINK_UNSERVED.
#
# Refused (LOWERING_UNCUTTABLE_NODE) before the child is walked: an aggregation
# with a UDF or a UDF aggregate function, one with a group top-k, and a partial
# or final aggregation.
#
# A float SUM or AVG is cut with ORDER_NONE: its result is
# not bit-reproducible across worker counts until a segment can carry
# ORDER_ROW_RANGE.
# =============================================================================

from arrow.arrow_types import ArrowType
from arrow.schema import Schema
from lowering.cut_state import _Cutter, _Pipe, _uncuttable
from lowering.lowered_plan import LoweringInputs, LOWERING_SINK_UNSERVED
from lowering.sum_fuse import lowered_agg_expr
from plan_expr.agg_expr import AGG_UDF
from plan_expr.expr import Expr
from plan_ir.logical_plan import (
    LogicalPlan,
    AggExprArray,
    ExprArray,
    copy_expr_array,
)
from plan_ir.plan_decisions import AGG_MODE_UNSET, AGG_MODE_SINGLE
from physical_plan.physical_plan import (
    AggSinkData,
    SINK_AGG,
    SINK_ORIENT_COLUMNAR,
    SINK_ORIENT_DICT_ENCODED,
    SOURCE_PARQUET,
    KEY_DTYPE_NONE,
    KEY_DTYPE_I64,
    KEY_DTYPE_I32,
    KEY_DTYPE_F64,
    KEY_DTYPE_F32,
    KEY_DTYPE_STRING,
)


def _key_dtype_of(arrow_type: ArrowType) -> Int:
    """The `KEY_DTYPE_*` of a group key column of this type, or -1."""
    if arrow_type == ArrowType.INT64:
        return Int(KEY_DTYPE_I64)
    if arrow_type == ArrowType.INT32:
        return Int(KEY_DTYPE_I32)
    if arrow_type == ArrowType.FLOAT64:
        return Int(KEY_DTYPE_F64)
    if arrow_type == ArrowType.FLOAT32:
        return Int(KEY_DTYPE_F32)
    if arrow_type == ArrowType.STRING:
        return Int(KEY_DTYPE_STRING)
    return -1


def _unserved(what: String) -> Error:
    return Error(String(LOWERING_SINK_UNSERVED) + ": " + what)


struct _Triple(Copyable, Movable):
    var key_dtype: UInt8
    var orientation: UInt8

    def __init__(out self, key_dtype: UInt8, orientation: UInt8):
        self.key_dtype = key_dtype
        self.orientation = orientation


def _is_dictionary_key(
    key: Expr, pipe: _Pipe, inputs: LoweringInputs
) -> Bool:
    """True when `key` is a column of the pipeline's Parquet scan that every
    row group of every pinned file stores dictionary encoded. A pipeline with
    a PROJECT in it, or one that reads a breaker's output, is never dictionary
    encoded: the name may no longer mean the scan's column."""
    if pipe.scan_index < 0 or pipe.has_project:
        return False
    if pipe.source_kind != SOURCE_PARQUET:
        return False
    if not key.is_col_ref():
        return False
    var name = key.col_ref_name()
    ref cols = inputs.scans[pipe.scan_index].dict_encoded_columns
    for i in range(len(cols)):
        if cols[i] == name:
            return True
    return False


def _agg_triple(
    group_by: ExprArray,
    out_schema: Schema,
    pipe: _Pipe,
    inputs: LoweringInputs,
) raises -> _Triple:
    """The `(key_dtype, orientation)` of an aggregation's sink. The group key
    columns are the first columns of the node's output schema. `cut_distinct`
    asks the same of a distinct, whose keys are every column."""
    var n = len(group_by)
    if n == 0:
        return _Triple(KEY_DTYPE_NONE, SINK_ORIENT_COLUMNAR)
    var all_dictionary_strings = True
    var first = -1
    for i in range(n):
        var t = out_schema.field_at_unchecked(i).arrow_type
        var d = _key_dtype_of(t)
        if d < 0:
            raise _unserved(
                "a group key column of type " + String(t) + " has no sink row"
            )
        if i == 0:
            first = d
        if d != Int(KEY_DTYPE_STRING) or not _is_dictionary_key(
            group_by[i], pipe, inputs
        ):
            all_dictionary_strings = False
    if n > 1:
        if not all_dictionary_strings:
            raise _unserved(
                "a group key of "
                + String(n)
                + " columns is served only when every column is a dictionary"
                " encoded string"
            )
        return _Triple(KEY_DTYPE_STRING, SINK_ORIENT_DICT_ENCODED)
    if first == Int(KEY_DTYPE_STRING):
        if all_dictionary_strings:
            return _Triple(KEY_DTYPE_STRING, SINK_ORIENT_DICT_ENCODED)
        return _Triple(KEY_DTYPE_STRING, SINK_ORIENT_COLUMNAR)
    return _Triple(UInt8(first), SINK_ORIENT_COLUMNAR)


def _aggregate_exprs(node: LogicalPlan) raises -> AggExprArray:
    """The aggregate expressions a PLAN_AGGREGATE node's sink computes, or its
    refusal. Called before the child is walked."""
    ref ad = node.aggregate_data_ref()
    if ad.has_udf():
        raise _uncuttable(node, "an aggregation with a UDF")
    if ad.group_topk:
        raise _uncuttable(node, "an aggregation with a group top-k")
    if ad.mode != AGG_MODE_UNSET and ad.mode != AGG_MODE_SINGLE:
        raise _uncuttable(node, "a partial or final aggregation")
    var aggs = AggExprArray()
    for i in range(len(ad.agg_exprs)):
        if ad.agg_exprs[i].func == AGG_UDF:
            raise _uncuttable(node, "a UDF aggregate function")
        # SUM(CAST(<signed integer> AS DECIMAL(38, 0))), the SQL integer
        # sum, runs as the integer fold (`sum_fuse`); the declared output
        # type is the node's and stays DECIMAL(38, 0).
        aggs.append(lowered_agg_expr(ad.agg_exprs[i], ad.child[].output_schema))
    return aggs^


def _close_aggregate(
    mut cutter: _Cutter,
    node: LogicalPlan,
    var pipe: _Pipe,
    var aggs: AggExprArray,
    inputs: LoweringInputs,
) raises -> _Pipe:
    """End the aggregation's child pipeline in its sink and open the pipeline
    that reads the sink's output."""
    ref ad = node.aggregate_data_ref()
    var triple = _agg_triple(ad.group_by, node.output_schema, pipe, inputs)
    var pid = len(cutter.params.agg)
    cutter.params.agg.append(
        AggSinkData(
            copy_expr_array(ad.group_by), aggs^, node.output_schema.copy()
        )
    )
    var seg = cutter._close(
        pipe^, SINK_AGG, triple.key_dtype, triple.orientation, pid, inputs
    )
    return cutter._reopen(seg, node.output_schema)
