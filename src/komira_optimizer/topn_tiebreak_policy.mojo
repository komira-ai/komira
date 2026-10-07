# =============================================================================
# topn_tiebreak_policy.mojo — THE TOP-N DETERMINISM TIE-BREAK, AS THE OPTIMIZER
# READS IT
# =============================================================================
#
# A TopN over a BREAKER (an aggregate, a join, a distinct) receives its input in
# an order that changes run to run. Where the ORDER BY keys leave ties straddling
# the K-cut, which of the tied rows survive would then change too. So the engine
# WIDENS the ORDER BY before the cut: every INT64 / INT32 / FLOAT64 column of the
# TopN's INPUT schema that is not already a key, in schema order, ASCENDING
# (as the engine does). That widened list is what decides a tie.
#
# ⭐ THE OPTIMIZER MUST DERIVE THE SAME LIST THE EXECUTOR DERIVES.
#
#   EXECUTOR   the TopN over a breaker child widens its keys with this list
#              before the cut, and a bounded aggregate top-K drain below it
#              receives the same list, so both pick the same K groups on a tie
#   OPTIMIZER  `optimizer_misc.push_topn_below_project` (Rule 14b) — moving a
#              TopN below a Project changes the TopN's INPUT schema, and so
#              changes this list. The rule computes the list over BOTH schemas
#              to prove the move leaves the answer on ties unchanged.
#
# `komira_optimizer` does not import the executor, so this module is the
# optimizer's own reading of the rule. A change to the rule changes this module
# and the executor's reading together; the test in
# `tests/test_topn_tiebreak_policy.mojo` pins the list this module derives.
#
# ⚠ THE TYPE FILTER IS A PERFORMANCE BOUND, NOT A CAPABILITY ONE.
# `_execute_topn_sink` orders a STRING key fine, but appending one would divert
# every groupby -> TopN over a string-keyed group from the bounded O(N log K)
# heap to a full O(N log N) sort, to break ties most queries do not have.
# ⛔ RESIDUAL: a TopN whose only remaining output column is a STRING still has no
# total order.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Schema


def tiebreak_admits_type(at: ArrowType) -> Bool:
    """True iff a column of type `at` is appended as a tie-break key.

    Factored out so a caller that must REASON about the list (the optimizer's
    TopN below Project proof) asks the same question the list builder asks,
    instead of restating the three types."""
    return (
        at == ArrowType.INT64
        or at == ArrowType.INT32
        or at == ArrowType.FLOAT64
    )


def append_deterministic_tiebreak_schema(
    sch: Schema,
    mut keys: List[String],
    mut descending: List[Bool],
) raises:
    """Append every column of `sch` that is NOT already a key and whose type
    `tiebreak_admits_type`, in schema order, as an ASCENDING secondary key.

    The SCHEMA-only spelling, so a caller can compute the list before any batch
    exists. Must produce exactly what `sort_topn_sink.
    append_deterministic_tiebreak_schema` produces for the same inputs — see the
    file header for the test that enforces it."""
    for c in range(sch.num_columns()):
        var name = sch.field_name(c)
        var already = False
        for k in range(len(keys)):
            if keys[k] == name:
                already = True
                break
        if already:
            continue
        if tiebreak_admits_type(sch.field_arrow_type(c)):
            keys.append(name)
            descending.append(False)  # ASC tie-break
