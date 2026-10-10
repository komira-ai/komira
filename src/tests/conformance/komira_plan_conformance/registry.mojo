# =============================================================================
# komira_plan_conformance/registry.mojo -- the shards and their cases.
# =============================================================================
#
# A shard is one capability family and, once plans execute, one welded test.
# `shard_names()` lists them; `shard_cases(name)` is the list a shard
# registers. A case is registered through exactly one shard's list, and that
# shard is the one the case names (test_corpus's partition check), so a case
# copied into a second shard's list is refused rather than run twice.
#
# Adding a shard: a cases_<shard>.mojo with a `cases()` function, one name in
# `shard_names()`, one arm in `shard_cases()`, and its expect/<shard>/ files.
# =============================================================================

from .plan_case import Case
from .cases_agg_grouping import cases as agg_grouping_cases
from .cases_filter_3vl import cases as filter_3vl_cases


def shard_names() -> List[String]:
    return [String("filter_3vl"), String("agg_grouping")]


def shard_cases(name: String) raises -> List[Case]:
    if name == "filter_3vl":
        return filter_3vl_cases()
    if name == "agg_grouping":
        return agg_grouping_cases()
    raise Error("plan_conformance: no shard named '" + name + "'")


struct Registered(Copyable, Movable):
    """A case together with the shard list that registered it."""

    var registered_in: String
    var entry: Case

    def __init__(out self, registered_in: String, var entry: Case):
        self.registered_in = registered_in
        self.entry = entry^


def registered_cases() raises -> List[Registered]:
    """Every registration, in shard order. A case registered twice appears
    twice: the partition check needs to see it."""
    var res = List[Registered]()
    for name in shard_names():
        for c in shard_cases(name):
            res.append(Registered(name, c.copy()))
    return res^
