# =============================================================================
# komira_plan_conformance/cases_sort_topn_limit.mojo -- shard sort_topn_limit.
# =============================================================================
#
# Sort order, query semantics §4.1 to §4.4, §4.7 and §4.8, over dataset
# sort_rows (a = 3, NULL, 1, 3, NULL, 2, 3 by id 1 to 7; b with one NULL;
# f = 1.5, 0.0, -0.0, -2.5, NULL, 0.0, 0.5). Explicit NULLS FIRST and NULLS
# LAST in both directions; the default placement (NULLS LAST in both
# directions, §4.1); two keys of mixed direction; -0.0 tying with 0.0; TOPN;
# LIMIT 0 and a LIMIT above the row count. Every expectation is HAND, its
# derivation in the .tsv.
#
# Order: a case whose root is a SORT or TOPN compares rows in order. Where
# rows tie on every sort key their order is not promised (§4.7), and the
# case uses `order: keys=<sort keys>`, which compares the key column in order
# and each tie group as a multiset; where the keys are total it uses
# `order: total`. A LIMIT root promises no order (§4.8): `order: none`.
#
# The default-placement cases build the plan with no `nulls_first`; the
# others pass it explicitly. komira_plan_ir resolves the default when the
# node is built, so default_asc carries the same flags as asc_nulls_last.
#
# NaN (§4.3) and infinities are not here: JSON has no spelling for them, so
# a JSON Lines dataset cannot hold them. They wait for a generated dataset.
#
# The defect each case would catch once it executes:
#   asc_nulls_first       NULLS FIRST ignored on an ascending key
#   asc_nulls_last        NULLS LAST ignored on an ascending key
#   desc_nulls_first      NULLS FIRST ignored on a descending key
#   desc_nulls_last       DESC flipping NULLs to the front
#   default_asc           a default of NULLS FIRST ascending
#   default_desc          the PostgreSQL default (NULLS FIRST on DESC)
#   multi_key_mixed       the second key's direction or placement ignored,
#                         or the first key's placement applied to both
#   neg_zero_ties_zero    -0.0 ordered below 0.0 (IEEE totalOrder or raw
#                         bits) instead of tying, so id 3 before id 2
#   topn_asc_nulls_last   TOPN keeping NULL rows, or the wrong end
#   topn_asc_nulls_first  TOPN ignoring its placement flag
#   topn_two_keys         TOPN ignoring its second key at the boundary
#   limit_zero            LIMIT 0 read as "no limit"
#   limit_above_rows      a LIMIT above the row count padding or failing
#   limit_over_sort       LIMIT over a SORT taking rows not first in order
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
    """SORT BY a ASC NULLS FIRST, b DESC NULLS FIRST."""
    return LogicalPlan.sort(
        [String("a"), String("b")], [False, True], scan(sort_rows()),
        _flags(True, True),
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
    """TOPN 2 BY a DESC, id ASC, default placement."""
    return LogicalPlan.topn(
        [String("a"), String("id")], [True, False], 2, scan(sort_rows())
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
