# =============================================================================
# plan_wire_optimized.mojo — what the OPTIMIZED context does with the fields an
# optimizer fills in.
# =============================================================================
#
# docs/design/optimized_plan.md §5.2. A `WirePlan` is decoded in one of two
# contexts (`_DecodeCtx.optimized` in plan_wire_codec.mojo): RAW, the plan a
# user's SQL front end built, in an envelope; and OPTIMIZED, the plan of an
# `OptimizedPlanBody`, which a producer's optimizer has already finished. Three
# groups of fields differ between them, and this file holds each rule once:
#
#   WireJoinNode.build_side (field 9)
#       RAW      encode: a recorded `JoinData.build_side` is refused
#                (`PLAN_WIRE_UNSUPPORTED_OPTIMIZER_DECISION`); UNSET writes the
#                unspecified value. decode: any value but the unspecified one
#                is refused with the same token. A raw plan has no build side.
#       OPTIMIZED encode: LEFT / RIGHT are written as wire 1 / 2; UNSET is
#                refused (`OPTIMIZED_JOIN_BUILD_SIDE_MISSING`), because the
#                optimizer records a side on every join it plans.
#                decode: wire 1 / 2 set `JoinData.build_side`; the unspecified
#                value is refused with the same token; a number the
#                vocabulary does not declare is refused by the vocabulary
#                (`JoinBuildSide: wire value N is unknown to this reader`).
#
#   WireAggregateNode.estimated_groups, WireDistinctNode.estimated_groups
#       RAW      refused on decode (`PLAN_WIRE_UNSUPPORTED_ESTIMATED_GROUPS`);
#                a plan taken before `optimize()` carries none.
#       OPTIMIZED admitted on decode and restored on the node
#                (`LogicalPlan.set_estimated_groups`); written on encode. A
#                negative value is refused on decode (`PLAN_WIRE_NEGATIVE_COUNT`).
#
#   WireScanNode.row_count and the scan's table statistics
#       RAW      `row_count` is admitted and round-trips; statistics are
#                refused (`PLAN_WIRE_UNSUPPORTED_TABLE_STATS`).
#       OPTIMIZED a scan carries neither (`OPTIMIZED_FIELD_UNSUPPORTED`): the
#                statistics a producer measured live in the header's advice,
#                outside the digest, and no host decision reads one from the
#                plan. The encoder refuses a scan that still holds them, so a
#                producer strips them first; the decoder refuses `row_count`
#                on a scan, so a body cannot smuggle one back into the digest.
#
# `JoinData.adaptive_allowed`, `AggregateData.mode` and a non-BOUNDED
# `ScanData.boundedness` have no wire field yet and stay refused in both
# contexts, as plan_wire_codec.mojo's ledger says.
# =============================================================================

from plan_ir.logical_plan import JOIN_BUILD_SIDE_UNSET
from plan_ir.logical_plan_variants import ScanData
from plan_wire.plan_wire_values import PLAN_WIRE_NEGATIVE_COUNT
from plan_wire.plan_wire_vocabulary import (
    join_build_side_from_wire,
    join_build_side_to_wire,
)

comptime OPTIMIZED_JOIN_BUILD_SIDE_MISSING: String = "OPTIMIZED_JOIN_BUILD_SIDE_MISSING"
comptime OPTIMIZED_FIELD_UNSUPPORTED: String = "OPTIMIZED_FIELD_UNSUPPORTED"


def optimized_join_build_side_to_wire(engine_side: UInt8) raises -> Int32:
    """The wire number of a join's recorded build side, for the OPTIMIZED
    encoder: 1 for LEFT, 2 for RIGHT. UNSET is `OPTIMIZED_JOIN_BUILD_SIDE_MISSING`
    and any other engine value is refused by the vocabulary."""
    if engine_side == JOIN_BUILD_SIDE_UNSET:
        raise Error(
            OPTIMIZED_JOIN_BUILD_SIDE_MISSING + ": a join in an optimized plan"
            + " records which side builds its hash table, and this one records"
            + " none (JoinData.build_side is UNSET). The producer's optimizer"
            + " (select_join_build_side) records it on every join; a plan that"
            + " skipped it is not an optimized plan"
        )
    return join_build_side_to_wire(engine_side)


def optimized_join_build_side_from_wire(wire_side: Int) raises -> UInt8:
    """The engine build side of a decoded `WireJoinNode.build_side` in the
    OPTIMIZED context: LEFT or RIGHT. The unspecified value is
    `OPTIMIZED_JOIN_BUILD_SIDE_MISSING`; a number the vocabulary does not
    declare is refused by it."""
    if wire_side == 0:
        raise Error(
            OPTIMIZED_JOIN_BUILD_SIDE_MISSING + ": a WireJoinNode in an"
            + " optimized plan states no build_side (field 9 is absent or"
            + " JOIN_BUILD_SIDE_WIRE_UNSPECIFIED). The host builds on the side"
            + " the plan names; it does not choose one"
        )
    return join_build_side_from_wire(Int32(wire_side))


def optimized_scan_statistics_refusal(d: ScanData) raises:
    """Raise `OPTIMIZED_FIELD_UNSUPPORTED` when the scan still holds a
    producer statistic (`row_count`, `table_stats`). OPTIMIZED encode only."""
    if d.row_count:
        raise Error(
            OPTIMIZED_FIELD_UNSUPPORTED + ": ScanData.row_count for '"
            + d.source_path + "' is a producer statistic. An optimized plan"
            + " carries statistics only in the header's advice, outside the"
            + " digest; strip it before serializing"
        )
    if d.table_stats:
        raise Error(
            OPTIMIZED_FIELD_UNSUPPORTED + ": ScanData.table_stats for '"
            + d.source_path + "' are producer statistics. An optimized plan"
            + " carries statistics only in the header's advice, outside the"
            + " digest; strip them before serializing"
        )


def optimized_scan_row_count_refusal() -> Error:
    """`OPTIMIZED_FIELD_UNSUPPORTED` for a decoded `WireScanNode.row_count`."""
    return Error(
        OPTIMIZED_FIELD_UNSUPPORTED + ": a WireScanNode in an optimized plan"
        + " carries row_count. Statistics live only in the header's advice,"
        + " outside the digest, and no host decision reads a producer"
        + " statistic from the plan"
    )


def optimized_estimated_groups_from_wire(groups: Int64, where: String) raises -> Optional[Int]:
    """The group-count estimate of a decoded aggregate or distinct in the
    OPTIMIZED context. A count of groups cannot be negative; a body that
    carries one is refused (`PLAN_WIRE_NEGATIVE_COUNT`) rather than handing a
    negative cardinality to the planner."""
    if groups < 0:
        raise Error(
            PLAN_WIRE_NEGATIVE_COUNT + ": " + where + " declares"
            + " estimated_groups = " + String(Int(groups)) + ". A count of"
            + " groups cannot be negative"
        )
    return Optional(Int(groups))
