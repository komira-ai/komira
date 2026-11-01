# =============================================================================
# topn_rg_bounds — per-row-group key bounds for a running top-N boundary, and
# the claim order that makes the boundary converge
# =============================================================================
#
# The consumer half of `komira_morsel.topn_boundary.TopNBoundary`. Derived
# once, from the footer, before any worker runs, and immutable after: the
# scan's per-claim question ("can this row group still hold a top-N row?") is
# two array reads and one compare.
#
# The claim order matters: a boundary tightens from what the scan decodes
# first. Claiming in ascending `min(key)` (descending `max(key)` for a
# descending top-N) draws the first wave from the row groups most likely to
# survive the final boundary. The order is a permutation: every row group is
# still claimable, so a scan that never publishes a boundary decodes what it
# would have decoded in file order.
#
# Every doubt is a decline (None: the mechanism is off). A bound wrong in the
# ADMITTING direction prunes a row group holding a top-N row, a wrong answer
# no later check can see. So: the key must resolve to a top-level leaf; its
# physical type must be INT64 or INT32; an INT64 annotated UINT_64 (unsigned
# stat order) and a DECIMAL (unscaled statistics) decline; an INT32 annotated
# UINT_32 is zero-extended (its statistics are in unsigned order, and a value
# at or above 2**31 read signed would be negative); every row group must have
# min and max of the right width, and a null count of 0 (statistics exclude
# nulls, so with nulls first a row group whose top-N rows are NULL would be
# pruned by its non-null min).
# =============================================================================

from std.memory import bitcast

from komira_parquet.rg_pruner import (
    _converted_type,
    _decode_le_i32,
    _decode_le_i64,
    _is_decimal,
    _leaf_by_name,
)
from komira_parquet_api.metadata import FileMetaData, RowGroup
from komira_parquet_api.types import CONVERTED_TYPE_UINT_32, CONVERTED_TYPE_UINT_64, ParquetType


@fieldwise_init
struct TopNRgPrunePlan(Copyable, Movable):
    """Per-row-group key bounds and the claim order.

    Fields:
        key_min: The key's minimum, per row group of the file.
        key_max: The key's maximum, per row group.
        claim_order: A permutation of the row groups: ascending `key_min`
            (descending `key_max` when `descending`), ties in file order.
        descending: The top-N keeps the largest keys.
    """

    var key_min: List[Int64]
    var key_max: List[Int64]
    var claim_order: List[Int]
    var descending: Bool

    @always_inline
    def num_units(self) -> Int:
        """How many row groups the plan covers."""
        return len(self.key_min)


def _rg_int_key_bounds(rg: RowGroup, col_idx: Int, is_int64: Bool, unsigned32: Bool) -> Optional[Tuple[Int64, Int64]]:
    """The (min, max) of leaf `col_idx` in `rg` as Int64, or None on any
    doubt (see the module header)."""
    if col_idx < 0 or col_idx >= len(rg.columns):
        return None
    ref cmeta = rg.columns[col_idx].meta_data
    if not cmeta.statistics:
        return None
    ref stats = cmeta.statistics.value()
    if not stats.null_count or stats.null_count.value() != 0:
        return None
    if not stats.min_value or not stats.max_value:
        return None
    if is_int64:
        var mn = _decode_le_i64(stats.min_value.value())
        var mx = _decode_le_i64(stats.max_value.value())
        if not mn or not mx:
            return None
        return Optional(Tuple[Int64, Int64](mn.value(), mx.value()))
    var mn32 = _decode_le_i32(stats.min_value.value())
    var mx32 = _decode_le_i32(stats.max_value.value())
    if not mn32 or not mx32:
        return None
    if unsigned32:
        return Optional(
            Tuple[Int64, Int64](
                Int64(Int(bitcast[DType.uint32](mn32.value()))),
                Int64(Int(bitcast[DType.uint32](mx32.value()))),
            )
        )
    return Optional(Tuple[Int64, Int64](Int64(mn32.value()), Int64(mx32.value())))


def build_topn_rg_prune_plan(metadata: FileMetaData, key_name: String, descending: Bool) raises -> Optional[TopNRgPrunePlan]:
    """The plan for `key_name` over every row group of one file, or None
    when any decline of the module header applies. Footer only."""
    var leaf = _leaf_by_name(metadata, key_name)
    var col_idx = leaf.leaf
    if col_idx < 0:
        return None
    var n_rgs = len(metadata.row_groups)
    if n_rgs == 0:
        return None
    if col_idx >= len(metadata.row_groups[0].columns):
        return None
    var physical = metadata.row_groups[0].columns[col_idx].meta_data.type
    var is_int64 = physical == ParquetType.INT64
    if not is_int64 and physical != ParquetType.INT32:
        return None
    var conv = _converted_type(metadata, leaf.element)
    if is_int64 and conv == CONVERTED_TYPE_UINT_64:
        return None
    if _is_decimal(metadata, leaf.element):
        return None
    var unsigned32 = (not is_int64) and conv == CONVERTED_TYPE_UINT_32
    var key_min = List[Int64](capacity=n_rgs)
    var key_max = List[Int64](capacity=n_rgs)
    for r in range(n_rgs):
        ref rg = metadata.row_groups[r]
        if col_idx >= len(rg.columns) or rg.columns[col_idx].meta_data.type != physical:
            return None
        var b = _rg_int_key_bounds(rg, col_idx, is_int64, unsigned32)
        if not b:
            return None
        key_min.append(b.value()[0])
        key_max.append(b.value()[1])
    # Stable insertion sort: equal keys keep file order.
    var order = List[Int](capacity=n_rgs)
    for r in range(n_rgs):
        order.append(r)
    for i in range(1, n_rgs):
        var cur = order[i]
        var cur_key = key_max[cur] if descending else key_min[cur]
        var j = i - 1
        while j >= 0:
            var prev = order[j]
            var prev_key = key_max[prev] if descending else key_min[prev]
            var out_of_order = prev_key < cur_key if descending else prev_key > cur_key
            if not out_of_order:
                break
            order[j + 1] = prev
            j -= 1
        order[j + 1] = cur
    return Optional(TopNRgPrunePlan(key_min=key_min^, key_max=key_max^, claim_order=order^, descending=descending))
