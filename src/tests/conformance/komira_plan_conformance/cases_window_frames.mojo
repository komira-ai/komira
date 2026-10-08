# =============================================================================
# komira_plan_conformance/cases_window_frames.mojo -- shard window_frames.
# =============================================================================
#
# Windowed aggregates and value functions over explicit ROWS frames, citing
# query semantics §9.1 (every plan window function carries its frame), §9.7
# (a ROWS frame's bounds count physical rows), §2.1 and §2.2 (NULL inputs
# skipped; only NULLs give NULL), with result types from §8.25 to §8.27 and
# their notes. One dataset, frame_rows: g = 1 ids 1 to 5 (v = 3, NULL, 5, 1,
# 4), g = 2 ids 6, 7 (v NULL on both), g = 3 id 8 (v = 9); w = 10 * id and
# non-nullable; u = id, nullable with no NULL. Every window orders by id,
# which has no ties within a partition, so every ROWS frame has one answer
# (§9.3's caveat about peers does not arise). Three frame shapes:
#   running   ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
#   sliding   ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING
#   empty     frames wholly after (or before) the current row, empty at a
#             partition's end (or start): ROWS 2 FOLLOWING .. 3 FOLLOWING,
#             1 FOLLOWING .. 2 FOLLOWING, 2 PRECEDING .. 1 PRECEDING
# Every expectation is HAND, its derivation in the .tsv. A PARTITION_BY root
# is not a SORT, so every case compares its rows as a multiset (§4.8).
#
# Types. §8.27: windowed COUNT is INT64, non-nullable, 0 over an empty frame.
# §8.26: windowed MIN and MAX have the input's type and are always nullable;
# the cases take MIN and MAX of the nullable v, where the plan's declaration
# (the input's nullability) agrees. §8.25: FIRST_VALUE and LAST_VALUE have
# the input's type, non-nullable only for a non-nullable input under a frame
# that always holds the current row: so w under running, sliding and
# whole-partition frames, and the nullable u under the empty-capable frame.
#
# Not here, each because the plan's declared type contradicts the document
# ("Code that does not follow", item 13), so the case's schema would differ
# from the plan's and test_corpus would be red:
#   - windowed SUM and AVG under any frame: the plan declares them
#     non-nullable, where §8.26 makes them nullable (an all-NULL frame such
#     as g = 2's, or an empty one, answers NULL);
#   - FIRST_VALUE or LAST_VALUE of the non-nullable w under a frame that can
#     be empty: the plan declares w's non-nullability, where §8.25 makes the
#     result nullable;
#   - MIN or MAX of the non-nullable w under any frame: the plan declares it
#     non-nullable, where §8.26 says always nullable.
# Also not here: NTH_VALUE (§8.25 gives its type, but no item says how n
# counts within the frame); RANGE frames with offsets (§9.8, UNDECIDED);
# value functions over a frame holding a NULL value (no item says whether
# FIRST_VALUE and LAST_VALUE skip it; §9.5 speaks of LAG and LEAD only).
#
# The defect each case would catch once a plan executes (nothing executes
# one here yet, so "catch" means the expected rows differ from the rows the
# defect would give):
#   count_running_rows            COUNT(v) counting NULLs (id 2 as 2), or
#                                 COUNT(*) skipping them; the frame not
#                                 restarting per partition (id 6 as 6)
#   count_sliding_rows            the frame read as running (id 1's cnt_all
#                                 1, id 5's 5); the following row dropped
#                                 (id 1 as 1); a frame crossing into the
#                                 next partition (id 5 as 3)
#   count_empty_frames            an empty frame answering NULL, or a
#                                 FOLLOWING frame running past the partition
#                                 end into the next partition (id 4 reading
#                                 id 6); a PRECEDING frame crossing the start
#   min_max_running_rows          a NULL taken as smallest (id 2's MIN NULL);
#                                 an all-NULL frame answering 0 (g = 2)
#   min_max_sliding_rows          the frame read as running (id 2's MAX 3,
#                                 not 5; id 5's MAX 5, not 4)
#   min_max_empty_frame           the current row included (id 5 as 4); an
#                                 empty frame answering 0
#   first_last_value_running_rows LAST_VALUE read over the whole partition
#                                 (id 1 as 50) instead of the frame
#   first_last_value_sliding_rows FIRST_VALUE read from the partition start
#                                 (id 3 as 10) instead of the frame start
#   first_last_value_whole_partition  LAST_VALUE stopping at the current row
#   first_last_value_empty_frame  an empty frame answering the current row's
#                                 value, or reading across the partition end
# =============================================================================

from komira_plan_expr.partition_expr import (
    FRAME_BOUND_CURRENT_ROW,
    FRAME_BOUND_FOLLOWING,
    FRAME_BOUND_PRECEDING,
    FRAME_BOUND_UNBOUNDED_FOLLOWING,
    FRAME_BOUND_UNBOUNDED_PRECEDING,
    FRAME_UNITS_ROWS,
    PF_COUNT,
    PF_MAX,
    PF_MIN,
    PartitionExpr,
    PartitionFrame,
)
from komira_plan_harness import CanonPolicy
from komira_plan_ir.logical_plan import LogicalPlan

from .plan_case import Case
from .datasets import frame_rows, scan

comptime SHARD = "window_frames"


def _rows(start_tag: UInt8, start_off: Int, end_tag: UInt8, end_off: Int) -> PartitionFrame:
    return PartitionFrame(
        FRAME_UNITS_ROWS, start_tag, Int64(start_off), end_tag, Int64(end_off)
    )


def _running() -> PartitionFrame:
    """ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW."""
    return _rows(FRAME_BOUND_UNBOUNDED_PRECEDING, 0, FRAME_BOUND_CURRENT_ROW, 0)


def _sliding() -> PartitionFrame:
    """ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING."""
    return _rows(FRAME_BOUND_PRECEDING, 1, FRAME_BOUND_FOLLOWING, 1)


def _whole() -> PartitionFrame:
    """ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING."""
    return _rows(
        FRAME_BOUND_UNBOUNDED_PRECEDING, 0, FRAME_BOUND_UNBOUNDED_FOLLOWING, 0
    )


def _following(lo: Int, hi: Int) -> PartitionFrame:
    """ROWS BETWEEN lo FOLLOWING AND hi FOLLOWING."""
    return _rows(FRAME_BOUND_FOLLOWING, lo, FRAME_BOUND_FOLLOWING, hi)


def _preceding(lo: Int, hi: Int) -> PartitionFrame:
    """ROWS BETWEEN lo PRECEDING AND hi PRECEDING."""
    return _rows(FRAME_BOUND_PRECEDING, lo, FRAME_BOUND_PRECEDING, hi)


def _over_g_by_id(var fns: List[PartitionExpr]) raises -> LogicalPlan:
    """frame_rows with `fns` OVER (PARTITION BY g ORDER BY id ...)."""
    return LogicalPlan.partition_by(
        [String("g")], [String("id")], [False], fns^, scan(frame_rows())
    )


def _agg(func: UInt8, column: String, var frame: PartitionFrame, out_name: String) -> PartitionExpr:
    return PartitionExpr.agg_with_frame(func, column, frame^).with_alias(out_name)


def _count_running_rows() raises -> LogicalPlan:
    """COUNT(*) AS cnt_all, COUNT(v) AS cnt_v, running."""
    return _over_g_by_id(
        [
            _agg(PF_COUNT, String(""), _running(), "cnt_all"),
            _agg(PF_COUNT, String("v"), _running(), "cnt_v"),
        ]
    )


def _count_sliding_rows() raises -> LogicalPlan:
    """COUNT(*) AS cnt_all, COUNT(v) AS cnt_v, ROWS 1 PRECEDING .. 1 FOLLOWING."""
    return _over_g_by_id(
        [
            _agg(PF_COUNT, String(""), _sliding(), "cnt_all"),
            _agg(PF_COUNT, String("v"), _sliding(), "cnt_v"),
        ]
    )


def _count_empty_frames() raises -> LogicalPlan:
    """COUNT(*) AS cnt_ahead and COUNT(v) AS cnt_v_ahead over ROWS 2
    FOLLOWING .. 3 FOLLOWING; COUNT(*) AS cnt_behind over ROWS 2 PRECEDING
    .. 1 PRECEDING."""
    return _over_g_by_id(
        [
            _agg(PF_COUNT, String(""), _following(2, 3), "cnt_ahead"),
            _agg(PF_COUNT, String("v"), _following(2, 3), "cnt_v_ahead"),
            _agg(PF_COUNT, String(""), _preceding(2, 1), "cnt_behind"),
        ]
    )


def _min_max_running_rows() raises -> LogicalPlan:
    """MIN(v) AS min_v, MAX(v) AS max_v, running."""
    return _over_g_by_id(
        [
            _agg(PF_MIN, String("v"), _running(), "min_v"),
            _agg(PF_MAX, String("v"), _running(), "max_v"),
        ]
    )


def _min_max_sliding_rows() raises -> LogicalPlan:
    """MIN(v) AS min_v, MAX(v) AS max_v, ROWS 1 PRECEDING .. 1 FOLLOWING."""
    return _over_g_by_id(
        [
            _agg(PF_MIN, String("v"), _sliding(), "min_v"),
            _agg(PF_MAX, String("v"), _sliding(), "max_v"),
        ]
    )


def _min_max_empty_frame() raises -> LogicalPlan:
    """MIN(v) AS min_v, MAX(v) AS max_v, ROWS 1 FOLLOWING .. 2 FOLLOWING."""
    return _over_g_by_id(
        [
            _agg(PF_MIN, String("v"), _following(1, 2), "min_v"),
            _agg(PF_MAX, String("v"), _following(1, 2), "max_v"),
        ]
    )


def _first_last(column: String, var frame: PartitionFrame) raises -> LogicalPlan:
    """FIRST_VALUE(column) AS first_x, LAST_VALUE(column) AS last_x over
    `frame`."""
    var f2 = frame.copy()
    return _over_g_by_id(
        [
            PartitionExpr.first_value(column).with_frame(frame^).with_alias("first_x"),
            PartitionExpr.last_value(column).with_frame(f2^).with_alias("last_x"),
        ]
    )


def _first_last_value_running_rows() raises -> LogicalPlan:
    return _first_last(String("w"), _running())


def _first_last_value_sliding_rows() raises -> LogicalPlan:
    return _first_last(String("w"), _sliding())


def _first_last_value_whole_partition() raises -> LogicalPlan:
    return _first_last(String("w"), _whole())


def _first_last_value_empty_frame() raises -> LogicalPlan:
    return _first_last(String("u"), _following(1, 2))


def cases() -> List[Case]:
    return [
        Case.hand("count_running_rows", SHARD, _count_running_rows, CanonPolicy.unordered()),
        Case.hand("count_sliding_rows", SHARD, _count_sliding_rows, CanonPolicy.unordered()),
        Case.hand("count_empty_frames", SHARD, _count_empty_frames, CanonPolicy.unordered()),
        Case.hand("min_max_running_rows", SHARD, _min_max_running_rows, CanonPolicy.unordered()),
        Case.hand("min_max_sliding_rows", SHARD, _min_max_sliding_rows, CanonPolicy.unordered()),
        Case.hand("min_max_empty_frame", SHARD, _min_max_empty_frame, CanonPolicy.unordered()),
        Case.hand("first_last_value_running_rows", SHARD, _first_last_value_running_rows, CanonPolicy.unordered()),
        Case.hand("first_last_value_sliding_rows", SHARD, _first_last_value_sliding_rows, CanonPolicy.unordered()),
        Case.hand("first_last_value_whole_partition", SHARD, _first_last_value_whole_partition, CanonPolicy.unordered()),
        Case.hand("first_last_value_empty_frame", SHARD, _first_last_value_empty_frame, CanonPolicy.unordered()),
    ]
