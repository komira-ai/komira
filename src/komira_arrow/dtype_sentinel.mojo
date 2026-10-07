# =============================================================================
# DTYPE_NONE -- the "this value carries no DType" discriminant
# =============================================================================
#
# This is a PLACEHOLDER for an open data-model decision, not the final
# design. Read this whole header before building on it.
#
# ---------------------------------------------------------------------------
# WHAT IT IS FOR
# ---------------------------------------------------------------------------
# Mojo 1.0 has no `DType.invalid` and the stdlib offers no replacement, so
# the absent-DType sentinel comes from this package. It serves three jobs,
# all of which are the same underlying thing -- an ABSENT DType:
#   1. `ScalarValue.dtype` / `.null_dtype` -- the NULL discriminant.
#      `is_null()` IS `dtype == DTYPE_NONE`.
#   2. `Column._dict_value_dtype` -- "this dictionary column is not numeric".
#   3. `Expr.cast_target()` -- "this Arrow logical type has no DType peer"
#      (DECIMAL128, and friends).
#
# ---------------------------------------------------------------------------
# WHAT THE RIGHT ANSWER PROBABLY IS
# ---------------------------------------------------------------------------
# All three jobs are `Optional[DType]` written by hand. That is very likely
# the correct end state. It is not what this file does because:
#
#   * It changes a FIELD TYPE, so it ripples to every reader, across several
#     packages that depend on the core packages.
#   * `is_null()` is on the hot path of every scalar comparison.
#
# So the sentinel is one named constant, which keeps the representation
# question open and VISIBLE.
#
# ---------------------------------------------------------------------------
# WHY THIS IS SAFE ON THE WIRE
# ---------------------------------------------------------------------------
# A serialized plan does NOT depend on the in-memory choice. `DType` has no
# stable numeric identity in the Mojo stdlib, so a plan codec must keep its
# own hand-written DType table, with its own code for "no dtype". Changing
# the in-memory spelling changes one comparison in such a codec and leaves
# every encoded byte identical.
#
# ---------------------------------------------------------------------------
# WHY float8_e5m2
# ---------------------------------------------------------------------------
# A sentinel drawn from the real DType space is a lie the type system cannot
# catch: the day someone stores an actual float8_e5m2 column, every
# `== DTYPE_NONE` silently reads it as NULL/absent. `float8_e5m2` is the
# sentinel because it is the furthest thing from a value this engine
# handles.
#
# THE SENTINEL MUST BE THE ONLY USE OF float8_e5m2. Any other code that
# names `float8_e5m2` -- including a second "unused DType" sentinel with a
# DIFFERENT meaning -- aliases this one: two meanings sharing one byte is
# invisible until one of them changes, and then an unrelated check starts
# answering the null question. If a real fp8 column type is ever needed,
# the answer is the `Optional[DType]` migration, NOT a different fp8 type.
# =============================================================================


comptime DTYPE_NONE: DType = DType.float8_e5m2
"""The absent-DType discriminant (Mojo 1.0 has no `DType.invalid`).

PLACEHOLDER, NOT THE FINAL DESIGN -- see this module's header. The intended
end state is `Optional[DType]`. No other code may name `float8_e5m2`.
"""
