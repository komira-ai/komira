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
# Mechanism: the same name-keyed, init-once, cross-compile-unit process-global
# `Atomic[int64]` via the stdlib `_Global` runtime slot that
# `komira_arrow/dict_interner.mojo` and `komira_parquet/dict_mat_counter.
# mojo` use — no env var, no `unsafe_from_address` laundering.
# =============================================================================

from komira_atomic_alias import AtomicI64
from std.ffi import _Global
from std.memory import OwnedPointer, UnsafePointer, alloc


def _init_string_eq_ladder_counter() -> OwnedPointer[AtomicI64]:
    """`_Global` init_fn (non-raising): allocate the counter Atomic once per
    process, initialised to 0. Mirrors `dict_interner._init_dict_merge_probe_
    counter` (`alloc` + `init_pointee_move` + `OwnedPointer(unsafe_from_raw_
    pointer=)`) since `Atomic` is not movable-by-value."""
    var raw = alloc[AtomicI64](1)
    raw.unsafe_bitcast[Scalar[DType.int64]]().unsafe_write(Scalar[DType.int64](0))
    return OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


comptime _STRING_EQ_LADDER_COUNTER = _Global[
    "komira_core_string_eq_runtime_ladder_calls",
    _init_string_eq_ladder_counter,
]


@always_inline
def string_eq_ladder_counter_incr() -> None:
    """Record one string ==/!= kernel call that took the RUNTIME-WIDTH ladder
    arm. One relaxed atomic add per kernel call, never per row.

    ⚠ NON-RAISING ON PURPOSE, AND THE `except` IS NOT A SWALLOWED ERROR.
    `eval_string_eq` and the kernels below it are non-raising `def`s and their
    whole call chain (`compiler_eval_predicate`, the row walkers) depends on
    that; a `raises` here would ripple through every one of them for an
    instrument. `_Global.get_or_create_ptr` is declared `raises` only to
    allocate its process-lifetime slot and never raises at runtime — the same
    statement `komira_parquet/dict_mat_counter.mojo` and
    `komira_arrow/dict_interner.mojo` make about the identical call.

    ⭐ AND A LOST INCREMENT CANNOT PRODUCE A VACUOUS PASS. The test asserts
    the counter in BOTH directions — 0 for a needle the hoist covers, 1 for a
    needle it does not — so an increment that never happened reds the second
    leg rather than silently satisfying the first.
    """
    # SAFETY: FFI boundary. `get_or_create_ptr` targets KGEN-runtime-managed
    # static storage (process-lifetime); `MutUntrackedOrigin` is the stdlib
    # `_Global` API's own return type, confined to this helper. The outer deref
    # yields the process-global `OwnedPointer`; the inner deref the `Atomic`.
    try:
        var gp = _STRING_EQ_LADDER_COUNTER.get_or_create_ptr()
        _ = gp[][].fetch_add(Int64(1))
    except:
        pass


def string_eq_ladder_call_count() raises -> Int:
    """Read the process-wide runtime-ladder-arm call count."""
    # SAFETY: FFI boundary (see `string_eq_ladder_counter_incr`).
    var gp = _STRING_EQ_LADDER_COUNTER.get_or_create_ptr()
    return Int(gp[][].load())


def reset_string_eq_ladder_call_count() raises:
    """Reset the process-wide count to 0 (test setup)."""
    # SAFETY: FFI boundary (see `string_eq_ladder_counter_incr`).
    var gp = _STRING_EQ_LADDER_COUNTER.get_or_create_ptr()
    gp[][].store(Scalar[DType.int64](0))
