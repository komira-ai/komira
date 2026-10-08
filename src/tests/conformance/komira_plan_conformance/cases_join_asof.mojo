# =============================================================================
# komira_plan_conformance/cases_join_asof.mojo -- shard join_asof.
# =============================================================================
#
# ASOF joins, citing query semantics §3.6 (BACKWARD and FORWARD), §3.7
# (NEAREST), §3.8 (tolerance, inclusive), §3.17 (the equality keys are
# equi-keys: a NULL key matches nothing), §3.18 (no equality keys is one
# group), §3.4 and §3.13 (padding and output columns). The plan's ASOF node is a
# LEFT ASOF join: every left row appears once, with the right columns NULL
# where nothing matches (§3.8's "LEFT ASOF join", §3.4). Datasets, joined on
# lg = rg (the equality group) and ordered by lt against rt:
#   asof_left   lid 1 to 9: lg = 1 with lt = 20, 24, 25, 5, 35; lg = 2 lt 7;
#               lg NULL lt 15; lg = 1 lt NULL; lg = 3 lt 10.
#   asof_right  rg = 1: rt = 10 (rid 1), 20 (rid 2), 30 (rid 3), NULL
#               (rid 6); rg = 2: rt 5 (rid 4); rg NULL: rt 15 (rid 5).
# No two right rows of one group share an rt, so no case asks which of two
# tied right rows matches (§3.19, undecided).
# Every expectation is HAND, its derivation in the .tsv. No case's root is
# a SORT, so every case compares its rows as a multiset (§4.8).
#
# Types. §3.13: the left columns then the right, both in input order, the
# names distinct (so no §3.14 rename). The left side is never padded, so it
# keeps its input nullability (lid non-nullable); the right side is padded,
# so every right column is nullable whatever its input (rid, rv).
#
# Marks. §3.6 is MATCHES. §3.8 (tolerance) and §3.7 (NEAREST, ties to the
# earlier row) are DEPARTS, komira extensions pending their rulings in
# "Rulings needed"; the tolerance and NEAREST cases are derived from those
# items' rules and change if a ruling does.
#
# lid 7 (NULL lg) does not join rid 5, whose rg is also NULL (§3.17); a
# candidate at exactly the tolerance matches (§3.8); with no equality keys
# every right row is in one group (§3.18).
#
# Not here: a FLOAT64 ordering column (no float item is at stake); a
# tolerance with NEAREST; strict `<` and `>` forms, which the plan cannot
# express (§3.8).
#
# The defect each case would catch once a plan executes (nothing executes
# one here yet, so "catch" means the expected rows differ from the rows the
# defect would give):
#   asof_backward              a strict `<` (lid 1 matching rid 1, not
#                              rid 2); the least rt rather than the greatest
#                              (lid 5 matching rid 1); a NULL rt taken as
#                              smallest (lid 4 matching rid 6); NULL lg
#                              matching NULL rg (lid 7 with rid 5); a left
#                              row dropped where nothing matches
#   asof_forward               a strict `>` (lid 1 matching rid 3); the
#                              direction ignored (lid 2 matching rid 2)
#   asof_backward_tolerance    the tolerance ignored (lid 3 matching rid 2)
#                              or made strict (lid 2 losing rid 2 at
#                              exactly 4)
#   asof_forward_tolerance     the same, forward: lid 2 (6 > 5) unmatched,
#                              lid 3 and 4 matched at exactly 5
#   asof_nearest               a tie broken to the later row (lid 3
#                              matching rid 3); NEAREST read as BACKWARD
#                              (lid 4 unmatched)
#   asof_backward_no_keys      an empty key list matching nothing, or
#                              still grouping by a column (lid 7 unmatched)
# =============================================================================

from komira_plan_harness import CanonPolicy
from komira_plan_ir.logical_plan import (
    ASOF_BACKWARD,
    ASOF_FORWARD,
    ASOF_NEAREST,
    AsofTolerance,
    LogicalPlan,
)

from .plan_case import Case
from .datasets import asof_left, asof_right, scan

comptime SHARD = "join_asof"


def _asof(strategy: UInt8, tolerance: AsofTolerance) raises -> LogicalPlan:
    """asof_left ASOF LEFT JOIN asof_right ON lg = rg, lt against rt."""
    return LogicalPlan.asof_join(
        scan(asof_left()), scan(asof_right()), [String("lg")], [String("rg")],
        String("lt"), String("rt"), strategy, tolerance,
    )


def _asof_backward() raises -> LogicalPlan:
    return _asof(ASOF_BACKWARD, AsofTolerance.none())


def _asof_forward() raises -> LogicalPlan:
    return _asof(ASOF_FORWARD, AsofTolerance.none())


def _asof_backward_tolerance() raises -> LogicalPlan:
    """BACKWARD within 4."""
    return _asof(ASOF_BACKWARD, AsofTolerance.int64(Int64(4)))


def _asof_forward_tolerance() raises -> LogicalPlan:
    """FORWARD within 5."""
    return _asof(ASOF_FORWARD, AsofTolerance.int64(Int64(5)))


def _asof_nearest() raises -> LogicalPlan:
    return _asof(ASOF_NEAREST, AsofTolerance.none())


def _asof_backward_no_keys() raises -> LogicalPlan:
    """BACKWARD with no equality keys: one group of every right row."""
    return LogicalPlan.asof_join(
        scan(asof_left()), scan(asof_right()), List[String](), List[String](),
        String("lt"), String("rt"), ASOF_BACKWARD, AsofTolerance.none(),
    )


def cases() -> List[Case]:
    """The shard's cases. A join promises no row order (§4.8), so every case
    compares its rows as a multiset."""
    return [
        Case.hand("asof_backward", SHARD, _asof_backward, CanonPolicy.unordered()),
        Case.hand("asof_forward", SHARD, _asof_forward, CanonPolicy.unordered()),
        Case.hand("asof_backward_tolerance", SHARD, _asof_backward_tolerance, CanonPolicy.unordered()),
        Case.hand("asof_forward_tolerance", SHARD, _asof_forward_tolerance, CanonPolicy.unordered()),
        Case.hand("asof_nearest", SHARD, _asof_nearest, CanonPolicy.unordered()),
        Case.hand("asof_backward_no_keys", SHARD, _asof_backward_no_keys, CanonPolicy.unordered()),
    ]
