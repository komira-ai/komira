# =============================================================================
# cut_partition_topn -- the cutter's PLAN_PARTITION_TOPN arm: a breaker
# =============================================================================
#
# A partition top-n (the optimizer's fusion of `WHERE rn <= K` over a
# ROW_NUMBER or RANK window, `optimizer_partition_topn`) ends the open pipeline
# in a SINK_PARTITION_TOPN segment (key NONE, COLUMNAR) whose
# PartitionTopNSinkData is the next row of the ParamTable's `partition_topn`,
# and opens a pipeline that reads that segment's output over an E3 edge. The
# sink keeps, per partition, the rows whose ROW_NUMBER or RANK over the sort
# keys is at most `k` (every row tied within `k` for RANK), and appends that
# number as an INT64 column when the node names one (`output_rank_col_name`).
# The keys stay column names.
#
# The sink's output schema is the child pipeline's, plus that column. Like a
# window's, the rows come out in no order the plan states but grouped by key,
# so when the node has a partition or a sort key the reopened pipeline is
# marked as a sorted stream: a LIMIT above it is refused as a LIMIT above the
# unfused window is (`cut_limit`), and the fused and unfused plans are cut
# alike.
#
# Refused before the child is walked, the first failing check in this order:
#
#   1. a negative `k` (LOWERING_UNCUTTABLE_NODE, as a top-n with a negative
#      count is);
#   2. a descending list whose length is not the sort keys'
#      (LOWERING_WINDOW_UNSERVED);
#   3. a function that is neither ROW_NUMBER nor RANK
#      (LOWERING_WINDOW_UNSERVED, naming it);
#   4. a partition or sort key that is not a column of the child, or whose
#      type the window's sort does not order (LOWERING_WINDOW_UNSERVED, the
#      window arm's own check and words, `cut_window`).
# =============================================================================

from arrow.arrow_types import ArrowType
from arrow.schema import Field, Schema, SchemaBuilder
from lowering.cut_state import _Cutter, _Pipe, _uncuttable
from lowering.cut_window import _check_keys, _unserved
from lowering.lowered_plan import LoweringInputs
from plan_expr.partition_expr import PF_RANK, PF_ROW_NUMBER, partition_fn_name
from plan_ir.logical_plan import LogicalPlan
from physical_plan.physical_plan import (
    PartitionTopNSinkData,
    SINK_PARTITION_TOPN,
    SINK_ORIENT_COLUMNAR,
    KEY_DTYPE_NONE,
)


def _check_partition_topn(node: LogicalPlan) raises:
    """Refuse a partition top-n the sink does not serve. Called before the
    child is walked."""
    ref pd = node.partition_topn_data_ref()
    if pd.k < 0:
        raise _uncuttable(node, "a partition top-n with a negative count")
    if len(pd.descending) != len(pd.sort_keys):
        raise _unserved(
            "the partition top-n has "
            + String(len(pd.sort_keys))
            + " sort keys and "
            + String(len(pd.descending))
            + " descending flags"
        )
    if pd.func != PF_ROW_NUMBER and pd.func != PF_RANK:
        raise _unserved(
            "the partition top-n numbers its rows with "
            + partition_fn_name(pd.func)
            + "; only ROW_NUMBER and RANK are served"
        )
    ref child = pd.child[].output_schema
    _check_keys(child, pd.partition_keys, "PARTITION BY")
    _check_keys(child, pd.sort_keys, "ORDER BY")


def _sink_schema(rows: Schema, rank_col: Optional[String]) -> Schema:
    """`rows`, with a non-NULL INT64 column `rank_col` appended when there is
    one: the schema the sink's output batch has."""
    if not rank_col:
        return rows.copy()
    var sb = SchemaBuilder()
    for i in range(rows.num_columns()):
        sb.add_field(rows.field_at_unchecked(i))
    sb.add_field(Field(rank_col.value(), ArrowType.INT64, False))
    return sb.build()


def _close_partition_topn(
    mut cutter: _Cutter,
    node: LogicalPlan,
    var pipe: _Pipe,
    inputs: LoweringInputs,
) -> _Pipe:
    """End the node's child pipeline in its sink and open the pipeline that
    reads the sink's output."""
    ref pd = node.partition_topn_data_ref()
    var schema = _sink_schema(pipe.schema, pd.output_rank_col_name)
    var keyed = len(pd.partition_keys) + len(pd.sort_keys) > 0
    var pid = len(cutter.params.partition_topn)
    cutter.params.partition_topn.append(
        PartitionTopNSinkData(
            pd.partition_keys.copy(),
            pd.sort_keys.copy(),
            pd.descending.copy(),
            pd.k,
            schema.copy(),
            func=pd.func,
            over_fetch_k=pd.over_fetch_k,
            output_rank_col_name=pd.output_rank_col_name.copy(),
        )
    )
    var seg = cutter._close(
        pipe^,
        SINK_PARTITION_TOPN,
        KEY_DTYPE_NONE,
        SINK_ORIENT_COLUMNAR,
        pid,
        inputs,
    )
    var reopened = cutter._reopen(seg, schema)
    reopened.sorted_input = keyed
    return reopened^
