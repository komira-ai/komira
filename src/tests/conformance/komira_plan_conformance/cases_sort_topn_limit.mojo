# =============================================================================
# komira_plan_conformance/cases_sort_topn_limit.mojo -- shard sort_topn_limit.
# =============================================================================
#
# Sort order over dataset sort_rows (a = 3, NULL, 1, 3, NULL, 2, 3 by id 1
# to 7; b = 1, 2, 2, NULL, 1, 1, 1; f = 1.5, 0.0, -0.0, -2.5, NULL, 0.0, 0.5),
# citing query semantics §4.1, §4.2, §4.4, §4.7 and §4.8. Explicit NULLS
# FIRST and NULLS LAST in both directions; the default placement (NULLS LAST
# in both directions, §4.1); two keys of mixed direction and placement; -0.0
# tying with 0.0; TOPN; LIMIT 0, a LIMIT above the row count and a LIMIT over
# a sort. Every expectation is HAND, its derivation in the .tsv.
#
# Order: a case whose root is a SORT or TOPN compares rows in order. Where
# rows tie on every sort key their order is not promised (§4.7), and the
# case uses `order: keys=<sort keys>`, which compares the key column in order
# and each tie group as a multiset; where the keys are total it uses
# `order: total`. A LIMIT root promises no order (§4.8): `order: none`.
#
# The default-placement cases build the plan with no `nulls_first`; the
# others pass it explicitly. komira_plan_ir resolves the default when the
# node is built, so default_asc is the same plan as asc_nulls_last, and
# default_desc the same plan as desc_nulls_last: on the wire the pairs are
# identical, and they differ only in what they would catch if the builder's
# default were wrong.
#
# NaN (§4.3) and infinities are not here: JSON has no spelling for them, so
# a JSON Lines dataset cannot hold them. They wait for a generated dataset.
#
# What each case would catch once a plan executes. Nothing executes a plan
# in this repository yet, so no case can go red on these defects today:
# "catches" means the expected rows differ from the rows the defect would
# give, so the defect is distinguishable. A flag that is ignored falls back
# to something; each line says which fallback the case tells apart, and
# which it cannot.
#   asc_nulls_first       NULLS FIRST ignored, fallback NULLS LAST (the
#                         default): the NULLs move to the end.
#   asc_nulls_last        NULLS LAST ignored, fallback NULLS FIRST (a kernel
#                         with a fixed placement). The default fallback
#                         gives the same rows. Same plan as default_asc.
#   desc_nulls_first      NULLS FIRST ignored, fallback NULLS LAST; or the
#                         direction ignored (ascending).
#   desc_nulls_last       NULLS LAST ignored, fallback NULLS FIRST on DESC
#                         (PostgreSQL's rule). Same plan as default_desc.
#   default_asc           the builder's default NULLS FIRST for ASC
#                         (derived_nulls_first returning True).
#   default_desc          the builder's default NULLS FIRST for DESC
#                         (PostgreSQL's default).
#   multi_key_mixed       a ASC NULLS FIRST, b DESC NULLS LAST: the first
#                         key's placement applied to both (id 4 before 1
#                         and 7); b's direction ignored (id 5 before 2); a's
#                         flag ignored with the default fallback (NULLs at
#                         the end). Not caught: b's flag ignored with the
#                         default fallback, which is also NULLS LAST.
#   neg_zero_ties_zero    -0.0 ordered below 0.0 (IEEE totalOrder or raw
#                         bits) instead of tying, so id 3 before id 2.
#   topn_asc_nulls_last   the flag ignored, fallback NULLS FIRST: TOPN 2
#                         would return the NULL rows.
#   topn_asc_nulls_first  the flag ignored, fallback NULLS LAST: TOPN 3
#                         would return no NULL row.
#   topn_two_keys         a DESC, id DESC: the second key ignored, where a
#                         stable sort on a alone keeps input (id ascending)
#                         order and returns id 1, 4 instead of 7, 4; or the
#                         second key's direction ignored (also 1, 4). An
#                         unstable sort that ignores id may return 7, 4 by
#                         chance, so this case does not rule that out.
#   limit_zero            LIMIT 0 read as "no limit".
#   limit_above_rows      a LIMIT above the row count padding or failing.
#   limit_over_sort       LIMIT over a SORT taking rows not first in order.
# =============================================================================

from komira_plan_harness import CanonPolicy
from komira_plan_ir.logical_plan import LogicalPlan

from .plan_case import Case
from .datasets import scan, sort_rows

comptime SHARD = "sort_topn_limit"


def _flags(*values: Bool) -> Optional[List[Bool]]:
    """An explicit per-key `nulls_first` list."""
    var res = List[Bool]()
    for v in values:
        res.append(v)
    return Optional(res^)


def _sort_a(desc: Bool, nulls_first: Optional[Bool]) raises -> LogicalPlan:
    """SORT BY a, with an explicit placement or (None) the default."""
    var nf: Optional[List[Bool]] = None
    if nulls_first:
        nf = _flags(nulls_first.value())
    return LogicalPlan.sort([String("a")], [desc], scan(sort_rows()), nf^)


def _asc_nulls_first() raises -> LogicalPlan:
    return _sort_a(False, Optional(True))


def _asc_nulls_last() raises -> LogicalPlan:
    return _sort_a(False, Optional(False))


def _desc_nulls_first() raises -> LogicalPlan:
    return _sort_a(True, Optional(True))


def _desc_nulls_last() raises -> LogicalPlan:
    return _sort_a(True, Optional(False))


def _default_asc() raises -> LogicalPlan:
    return _sort_a(False, None)


def _default_desc() raises -> LogicalPlan:
    return _sort_a(True, None)


def _multi_key_mixed() raises -> LogicalPlan:
    """SORT BY a ASC NULLS FIRST, b DESC NULLS LAST."""
    return LogicalPlan.sort(
        [String("a"), String("b")], [False, True], scan(sort_rows()),
        _flags(True, False),
    )


def _neg_zero_ties_zero() raises -> LogicalPlan:
    """SORT BY f ASC, id ASC, default placement."""
    return LogicalPlan.sort(
        [String("f"), String("id")], [False, False], scan(sort_rows())
    )


def _topn_asc_nulls_last() raises -> LogicalPlan:
    return LogicalPlan.topn(
        [String("a")], [False], 2, scan(sort_rows()), _flags(False)
    )


def _topn_asc_nulls_first() raises -> LogicalPlan:
    return LogicalPlan.topn(
        [String("a")], [False], 3, scan(sort_rows()), _flags(True)
    )


def _topn_two_keys() raises -> LogicalPlan:
    """TOPN 2 BY a DESC, id DESC, default placement. id descending is the
    reverse of the input order, so a sort that drops the second key gives
    different rows."""
    return LogicalPlan.topn(
        [String("a"), String("id")], [True, True], 2, scan(sort_rows())
    )


def _limit_zero() raises -> LogicalPlan:
    return LogicalPlan.limit(0, scan(sort_rows()))


def _limit_above_rows() raises -> LogicalPlan:
    return LogicalPlan.limit(100, scan(sort_rows()))


def _limit_over_sort() raises -> LogicalPlan:
    return LogicalPlan.limit(2, _sort_a(False, Optional(False)))


def _by_a() -> CanonPolicy:
    return CanonPolicy.keyed([String("a")])


def cases() -> List[Case]:
    return [
        Case.hand("asc_nulls_first", SHARD, _asc_nulls_first, _by_a()),
        Case.hand("asc_nulls_last", SHARD, _asc_nulls_last, _by_a()),
        Case.hand("desc_nulls_first", SHARD, _desc_nulls_first, _by_a()),
        Case.hand("desc_nulls_last", SHARD, _desc_nulls_last, _by_a()),
        Case.hand("default_asc", SHARD, _default_asc, _by_a()),
        Case.hand("default_desc", SHARD, _default_desc, _by_a()),
        Case.hand("multi_key_mixed", SHARD, _multi_key_mixed, CanonPolicy.keyed([String("a"), String("b")])),
        Case.hand("neg_zero_ties_zero", SHARD, _neg_zero_ties_zero, CanonPolicy.total()),
        Case.hand("topn_asc_nulls_last", SHARD, _topn_asc_nulls_last, CanonPolicy.total()),
        Case.hand("topn_asc_nulls_first", SHARD, _topn_asc_nulls_first, _by_a()),
        Case.hand("topn_two_keys", SHARD, _topn_two_keys, CanonPolicy.total()),
        Case.hand("limit_zero", SHARD, _limit_zero, CanonPolicy.unordered()),
        Case.hand("limit_above_rows", SHARD, _limit_above_rows, CanonPolicy.unordered()),
        Case.hand("limit_over_sort", SHARD, _limit_over_sort, CanonPolicy.unordered()),
    ]
