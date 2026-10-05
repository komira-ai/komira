# =============================================================================
# string_eq_arm_counter — process-global falsifier for the string ==/!= kernel
#                         taking the RUNTIME-WIDTH LADDER arm
# =============================================================================
#
# WHY THIS EXISTS.
#   `_string_eq_kernel` / `_string_ne_kernel` reject a row on length and then
#   compare exactly `val_len` bytes — and `val_len` is LOOP-INVARIANT. Without
#   the needle-width hoist they reach the comparison through `bytes_equal`'s
#   RUNTIME width ladder (`i + W <= n`, then `rem >= 16 / 8 / 4 / 2`), so FOUR
#   compare-and-branch pairs are walked PER ROW to land on the same block
#   width every single time — several times DuckDB's instruction count per
#   row for the same predicate.
#
#   The hoist is invisible to any value test — the two arms are
#   value-identical by construction, which is exactly why a value test cannot
#   pin it. Without an instrument, a later refactor that drops the specialized
#   arms is a silent, unattributable regression: the same answers, at the
#   runtime-ladder instruction count, with nothing red. This counter makes the ARM CHOICE
#   assertable from a test, the same way `komira_parquet/dict_mat_counter.mojo`
#   makes the dict-preserving decode's route assertable.
#
# WHAT IT COUNTS.
#   One increment per KERNEL CALL — i.e. per predicate evaluation per batch,
#   NEVER per row — and ONLY on the generic runtime-ladder arm. A call that
#   takes a hoisted comptime-width arm does not touch the counter at all, so
#   the instrumented build and the shipped build are the same code on the hot
#   path.
#
#   ⛔ It is NOT an assertion that the ladder arm is globally unreached. The
#   ladder is the correct and permanent answer for an empty needle and for a
#   needle wider than `_EQ_HOIST_MAX_NEEDLE` bytes; a test asserting `> 0`
#   for those is as load-bearing as one asserting `== 0` for a short needle.
#
# Mechanism: `GlobalCounter` (`global_counter.mojo`), the name-keyed, init-once,
# cross-compile-unit process-global atomic counter that every counter in this
# package shares — no env var, no `unsafe_from_address` laundering.
# =============================================================================

from komira_counters.global_counter import GlobalCounter


comptime _STRING_EQ_LADDER_COUNTER = GlobalCounter[
    "komira_core_string_eq_runtime_ladder_calls"
]


@always_inline
def string_eq_ladder_counter_incr() -> None:
    """Record one string ==/!= kernel call that took the RUNTIME-WIDTH ladder
    arm. One relaxed atomic add per kernel call, never per row.

    ⚠ NON-RAISING ON PURPOSE, AND THE SWALLOWED ERROR IS NOT A LOST COUNT IN
    PRACTICE. `eval_string_eq` and the kernels below it are non-raising `def`s
    and their whole call chain (`compiler_eval_predicate`, the row walkers)
    depends on that; a `raises` here would ripple through every one of them for
    an instrument. The stdlib `_Global` slot under `GlobalCounter` is declared
    `raises` only to allocate its process-lifetime cell and never raises at
    runtime.

    ⭐ AND A LOST INCREMENT CANNOT PRODUCE A VACUOUS PASS. The test asserts
    the counter in BOTH directions — 0 for a needle the hoist covers, 1 for a
    needle it does not — so an increment that never happened reds the second
    leg rather than silently satisfying the first.
    """
    _STRING_EQ_LADDER_COUNTER.try_incr()


def string_eq_ladder_call_count() raises -> Int:
    """Read the process-wide runtime-ladder-arm call count."""
    return _STRING_EQ_LADDER_COUNTER.read()


def reset_string_eq_ladder_call_count() raises:
    """Reset the process-wide count to 0 (test setup)."""
    _STRING_EQ_LADDER_COUNTER.reset()
