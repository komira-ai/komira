# =============================================================================
# dict_mat_counter — process-global reach counter for
#                             `_materialize_dict_to_string`
# =============================================================================
#
# WHY THIS EXISTS.
#   `_materialize_dict_to_string` (eval_dict.mojo) is the DICTIONARY ->
#   dense-StringArray fallback for the pattern predicates (LIKE / CONTAINS /
#   STARTS_WITH / ENDS_WITH) and the regexp predicates, and the function where
#   a dictionary-offset defect is most likely to live (a sliced dictionary's
#   `_offset` window).
#
#   An end-to-end dictionary differential can pass without ever reaching it
#   (planting `raise Error(...)` at its top is a one-off way to prove the
#   reach, not a durable guarantee: reshape the scenarios and the coverage can
#   silently go back to zero).
#
#   This counter makes the reach claim ASSERTABLE from a test, so the coverage
#   is pinned rather than believed. A scenario that is supposed to drive the
#   dict string-op fallback asserts `> 0`; a scenario that is supposed to stay
#   code-native asserts `== 0`. Both directions are checkable in one process.
#   want (decode == 0, eval > 0): the group key stayed dict-encoded through the
#   decode, and the predicate then materialized it for the pattern kernel.
#
# Mechanism: a named `GlobalCounter` from `komira_counters`, so every module of
# the process that names `komira_batch_eval_materialize_dict_to_string_calls`
# reaches the same cell. One relaxed atomic add per CALL (per predicate
# evaluation per batch, never per row), so the always-on cost is a few
# nanoseconds against a function that already makes two full passes over the
# batch plus a heap allocation.
# =============================================================================

from komira_counters.global_counter import GlobalCounter

comptime _DictMatCalls = GlobalCounter[
    "komira_batch_eval_materialize_dict_to_string_calls"
]


@always_inline
def dict_mat_counter_incr() raises:
    """Record one `_materialize_dict_to_string` call (any caller)."""
    _DictMatCalls.incr()


def materialize_dict_to_string_call_count() raises -> Int:
    """Read the process-wide `_materialize_dict_to_string` invocation count."""
    return _DictMatCalls.read()


def reset_materialize_dict_to_string_call_count() raises:
    """Reset the process-wide invocation count to 0 (test setup)."""
    _DictMatCalls.reset()
