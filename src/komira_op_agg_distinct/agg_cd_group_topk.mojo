# =============================================================================
# agg_cd_group_topk -- the bounded top-k selection of the grouped
# COUNT(DISTINCT) drain
# =============================================================================
#
# A `TOPN(k)` over a grouped COUNT(DISTINCT) (`... GROUP BY s ORDER BY
# count(DISTINCT u) DESC LIMIT 10`) orders by AGGREGATE-OUTPUT columns, which
# are fixed-width. So the driver can emit the aggregate columns of every group,
# let the ordinary top-N kernel choose the k surviving GROUPS, and materialise
# the variable-width group key for those k groups only, instead of building
# every group's key string and discarding all but k of them.
#
# It changes cost, never the answer: the k survivors are chosen by the same
# `_execute_topn_sink` kernel, under the same comparator (the hint's, copied
# unchanged, NULL placement included), over the same rows in the same order as
# the full drain's top-N would see. Nothing is appended to the comparator: the
# heap keeps an incumbent unless a candidate is strictly better, so an extra
# tie-break key would change which of several TIED groups survive and the
# order they come back in. The group-index column below is a payload that
# carries each survivor's identity back, never a sort key.
#
# The arm declines (the caller emits every group) when, in this order:
#   * there is no hint, `k <= 0`, or the hint's lists disagree in length;
#   * there is no group key (one output row already);
#   * no group key is variable-width (nothing to save);
#   * `n_groups <= k * CDP_TOPK_MIN_RATIO` (the pre-pass is not free);
#   * an ORDER BY column is not an aggregate-output column (the pre-pass
#     batch deliberately carries no key column).
# Every question is answered from the schema and three integers, so a
# declined shape walks no group.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import Field, RecordBatch, Schema
from komira_buffer.heap_region import HeapRegion
from komira_physical_plan.physical_plan import TopNSinkData
from komira_op_sort.sort_topn_sink import _execute_topn_sink


comptime CDP_TOPK_GIDX_COL: StaticString = "__cdp_topk_gidx"
"""The group-index payload column of the pre-pass batch: each group's output
row index, in the order the driver's merge produced the groups."""

comptime CDP_TOPK_MIN_RATIO: Int = 8
"""The pre-pass is worth taking only when the groups outnumber k by this
factor; the top-N kernel uses the same ratio to choose its bounded heap."""


struct CdGroupTopKHint(Copyable, Movable):
    """The top-N above a grouped COUNT(DISTINCT), carried to the operator.

    An annotation, never a semantic: dropping it changes only cost.

    Fields:
        order_cols: The ORDER BY columns, named in the aggregate's own output
            schema, tie-breaks already expanded by the planner.
        descending: Per-column direction, same length as `order_cols`.
        k: The LIMIT; the arm declines unless it is > 0.
        nulls_first: Per-column NULL placement, as the top-N above uses it
            (empty: the top-N sink's default).
    """

    var order_cols: List[String]
    var descending: List[Bool]
    var k: Int
    var nulls_first: List[Bool]

    def __init__(
        out self,
        var order_cols: List[String],
        var descending: List[Bool],
        k: Int,
        var nulls_first: List[Bool] = List[Bool](),
    ):
        self.order_cols = order_cols^
        self.descending = descending^
        self.k = k
        self.nulls_first = nulls_first^

    def copy(self) -> Self:
        return Self(
            self.order_cols.copy(),
            self.descending.copy(),
            self.k,
            self.nulls_first.copy(),
        )


def _field_index_or_absent(sch: Schema, name: String) raises -> Int:
    """`sch`'s index for `name`, or -1. An unknown name means the hint is not
    about this aggregate: a decline, never a raise."""
    for i in range(sch.num_columns()):
        if sch.field_name(i) == name:
            return i
    return -1


def cd_group_topk_admits(
    output_schema: Schema,
    num_keys: Int,
    num_groups: Int,
    has_string_key: Bool,
    hint: Optional[CdGroupTopKHint],
) raises -> Bool:
    """Whether the bounded arm serves `hint` for this aggregate; see the module
    header for the questions, asked in order. Touches no group."""
    if not hint:
        return False
    ref h = hint.value()
    if h.k <= 0:
        return False
    if len(h.order_cols) == 0 or len(h.order_cols) != len(h.descending):
        return False
    if len(h.nulls_first) != 0 and len(h.nulls_first) != len(h.order_cols):
        return False
    if num_keys < 1:
        return False
    if not has_string_key:
        return False
    if num_groups <= h.k * CDP_TOPK_MIN_RATIO:
        return False
    for i in range(len(h.order_cols)):
        if _field_index_or_absent(output_schema, h.order_cols[i]) < num_keys:
            return False
    return True


def cd_group_topk_index_column(num_groups: Int) raises -> Column[HeapRegion]:
    """The `__cdp_topk_gidx` column: INT64 `0 .. num_groups - 1`."""
    var arr = PrimitiveArray[DType.int64].allocate(num_groups)
    for g in range(num_groups):
        arr.set(g, Int64(g))
    return Column.from_primitive[DType.int64](arr^)


def cd_group_topk_index_field() raises -> Field:
    """The field of `cd_group_topk_index_column`."""
    return Field(String(CDP_TOPK_GIDX_COL), ArrowType.INT64, False)


def cd_group_topk_select(
    var pre: RecordBatch, hint: CdGroupTopKHint
) raises -> RecordBatch:
    """The <= k rows of `pre` the top-N above would keep, in its order, with
    the group-index column carried along. The comparator is the hint's,
    unextended."""
    return _execute_topn_sink(
        pre^,
        TopNSinkData(
            hint.order_cols.copy(),
            hint.descending.copy(),
            hint.k,
            hint.nulls_first.copy(),
        ),
    )


def cd_group_topk_gids(sel: RecordBatch) raises -> List[Int]:
    """The surviving group indices, in the order `sel` holds them. The column
    is found by name (a payload has no fixed position); its absence means the
    pre-pass contract broke, so it raises."""
    var ci = _field_index_or_absent(sel.schema, String(CDP_TOPK_GIDX_COL))
    if ci < 0:
        raise Error(
            "cd_group_topk_gids: the pre-pass group-index column is missing"
            " from the selection result"
        )
    var arr = sel.column_at(ci).as_primitive[DType.int64]()
    var rows = List[Int](capacity=sel.num_rows())
    for r in range(sel.num_rows()):
        rows.append(Int(arr.get(r)))
    return rows^
