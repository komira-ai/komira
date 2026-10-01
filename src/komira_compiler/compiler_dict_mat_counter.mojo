# =============================================================================
# compiler_dict_mat_counter — process-global reach counter for
#                             `_materialize_dict_to_string`
# =============================================================================
#
# WHY THIS EXISTS.
#   `_materialize_dict_to_string` (compiler_eval_dict.mojo) is the DICTIONARY ->
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
# Mechanism: the same name-keyed, init-once, cross-compile-unit process-global
# `Atomic[int64]` via the stdlib `_Global` runtime slot that
# `komira_parquet/dict_mat_counter.mojo` uses — no env var, no
# `unsafe_from_address` laundering. One RELAXED
# atomic add per CALL (i.e. per predicate-eval per batch, never per row), so the
# always-on cost is a few nanoseconds against a function that already does two
# full passes over the batch plus a heap allocation.
# =============================================================================

from komira_atomic_alias import AtomicI64
from std.ffi import _Global
from std.memory import OwnedPointer, UnsafePointer, alloc


def _init_compiler_dict_mat_counter() -> OwnedPointer[AtomicI64]:
    """`_Global` init_fn (non-raising): allocate the counter Atomic once per
    process, initialised to 0. Mirrors `dict_mat_counter._init_dict_mat_counter`
    (`alloc` + `init_pointee_move` + `OwnedPointer(unsafe_from_raw_pointer=)`)
    since `Atomic` is not movable-by-value."""
    var raw = alloc[AtomicI64](1)
    raw.unsafe_bitcast[Scalar[DType.int64]]().unsafe_write(Scalar[DType.int64](0))
    return OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


comptime _COMPILER_DICT_MAT_COUNTER = _Global[
    "komira_compiler_materialize_dict_to_string_calls",
    _init_compiler_dict_mat_counter,
]


@always_inline
def compiler_dict_mat_counter_incr() raises:
    """Record one `_materialize_dict_to_string` call (any caller). `raises` only
    to propagate the stdlib `_Global.get_or_create_ptr` signature — never raises
    at runtime."""
    # SAFETY: FFI carve-out. `get_or_create_ptr` targets KGEN-runtime-managed
    # static storage (process-lifetime); `MutUntrackedOrigin` is the stdlib
    # `_Global` API's own return type, confined to this helper. The outer deref
    # yields the process-global `OwnedPointer`; the inner deref the `Atomic`.
    var gp = _COMPILER_DICT_MAT_COUNTER.get_or_create_ptr()
    _ = gp[][].fetch_add(Int64(1))


def materialize_dict_to_string_call_count() raises -> Int:
    """Read the process-wide `_materialize_dict_to_string` invocation count."""
    # SAFETY: FFI carve-out (see `compiler_dict_mat_counter_incr`).
    var gp = _COMPILER_DICT_MAT_COUNTER.get_or_create_ptr()
    return Int(gp[][].load())


def reset_materialize_dict_to_string_call_count() raises:
    """Reset the process-wide invocation count to 0 (test setup)."""
    # SAFETY: FFI carve-out (see `compiler_dict_mat_counter_incr`).
    var gp = _COMPILER_DICT_MAT_COUNTER.get_or_create_ptr()
    gp[][].store(Scalar[DType.int64](0))
