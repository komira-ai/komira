# =============================================================================
# pod_state_gate.mojo — the REAL compile-time PodState gate (the slab-safety gate)
# =============================================================================
#
# `trait PodState(Copyable,
# Movable, Deinitable)` (agg_fn.mojo) is a NO-OP marker: a `State`
# with a `String` / `List` / `Set` field CONFORMS (those types are all
# Copyable + Movable + Deinitable), so it compiles — but the raw
# `State` slab is bytewise-dumped / merged across workers at
# `AggFnAcc.flush_partial_to_column` / `merge_aligned`, which corrupts the
# inner heap buffer (the classic stale-slab hazard: tcmalloc byte reuse
# reinterprets stale bytes under a new lifetime).
#
# This file turns the DOCUMENTED contract into an ENFORCED comptime gate.
# `assert_pod_state[S]()` reflects over `S`'s fields and `constrained[]`-fails
# the build if any field is not slab-safe. It composes the EXISTING comptime
# primitives (`reflect[S]()` + `_type_is_eq` scalar allowlist, the same shape
# as `comptime_field_validation.mojo`) — no new infra.
#
# The gate is FORCED from `AggFnAcc[F].__init__` (agg_fn_acc.mojo): a
# `constrained[]` in an uninstantiated generic never fires, so the assertion
# is anchored in a method that is monomorphized PER-CONFORMER. Exactly the
# same forcing model as `simd_of.mojo`'s typed accessors calling
# `comptime_field_validation` per-`F`.
#
# The DOCUMENTED contract: an `AggFn.State` field is legal
# iff it is
#   (a) a flat `PodScalar` — Int8..Int64, UInt8..UInt64, Float32, Float64,
#       Bool (the same allowlist `comptime_field_validation._dtype_matches`
#       blesses), OR
#   (b) an `InlineArray[T: PodScalar, N]` — the HLL workaround
#       (`agg_fn.mojo:~40`; same shape the engine's statistical accumulators
#       use after the AggLayout -> InlineArray migration).
# Anything else (String / List / Set / OwnedPointer / a nested struct field)
# is rejected. Nested @fieldwise_init struct-of-PodScalars is NOT accepted —
# the design implies flat fields, and no existing conformer needs nesting
# (verified against every conformer in `builtin_agg_fns_states.mojo`); keeping
# it flat avoids scope-creep and keeps the gate auditable.
#
# Mojo 1.0.0b1 idioms this gate relies on:
#   - `reflect[S]().field_types()` returns a `TypeList` of `AnyType`-erased
#     field types; `(ts[i] == U)` discriminates them.
#   - An `InlineArray[Elem, N]` field reflects to a single internal field
#     named `_array` whose element type is an opaque `__mlir_type` that does
#     NOT round-trip through `_type_is_eq` against `Elem`. So we CANNOT
#     recover the element type by reflecting one level deeper. Instead we
#     detect the InlineArray AND validate its element in one step: sweep
#     `(FieldT == InlineArray[Elem, n])` over each PodScalar `Elem`
#     and `n in [1, MAX_INLINE_ARRAY_N]`. A hit confirms BOTH "is InlineArray"
#     AND "element is a blessed PodScalar" — so `InlineArray[String, N]` is
#     correctly REJECTED (String is not on the Elem allowlist), which the
#     naive structural "single field named `_array`" check would miss.
#   - `InlineArray[Elem, n]` requires `Elem: Copyable & Movable`, so the
#     sweep helper bounds `Elem` accordingly (every PodScalar satisfies it).
# =============================================================================

from std.collections import Array


# The bounded support window for an `InlineArray[PodScalar, N]` State field.
# The whole-type `(FieldT == InlineArray[Elem, n])` comparison
# needs a concrete `n`, and `n` is not recoverable from reflection — so we
# sweep `n in [1, MAX_INLINE_ARRAY_N]`. 256 covers every realistic AggFn.State
# InlineArray (the in-tree HLL / HashSet workarounds use N <= 16; an HLL with
# precision p uses 2^p registers — p<=8 => N<=256). An InlineArray State field
# wider than this cap is rejected with the gate message (raise the cap here if
# a real conformer ever needs it; the sweep is comptime-only, run once per
# distinct field type, so the cost is negligible).
comptime MAX_INLINE_ARRAY_N: Int = 256


def _is_pod_scalar[FieldT: AnyType]() -> Bool:
    """True iff `FieldT` is one of the blessed PodScalar dtypes — the
    int/float/bool families. Mirrors `comptime_field_validation._dtype_matches`'s
    allowlist (the closed set the engine blesses). No heap-owning type can be
    on this list."""
    comptime if (FieldT == Int8):
        return True
    elif (FieldT == Int16):
        return True
    elif (FieldT == Int32):
        return True
    elif (FieldT == Int64):
        return True
    elif (FieldT == UInt8):
        return True
    elif (FieldT == UInt16):
        return True
    elif (FieldT == UInt32):
        return True
    elif (FieldT == UInt64):
        return True
    elif (FieldT == Float32):
        return True
    elif (FieldT == Float64):
        return True
    elif (FieldT == Bool):
        return True
    return False


def _is_inline_array_of_elem[
    FieldT: AnyType, Elem: Copyable & Movable
]() -> Bool:
    """True iff `FieldT` is `InlineArray[Elem, n]` for some `n` in
    `[1, MAX_INLINE_ARRAY_N]`. Whole-type comparison, so a hit confirms BOTH
    the InlineArray shape AND the exact element type — `n` itself is not
    recoverable from reflection, hence the bounded sweep."""
    var hit = False
    comptime for n in range(1, MAX_INLINE_ARRAY_N + 1):
        comptime if (FieldT == Array[Elem, n]):
            hit = True
    return hit


def _is_pod_inline_array[FieldT: AnyType]() -> Bool:
    """True iff `FieldT` is `InlineArray[PodScalar, N]` — the HLL workaround
    carve-out. Sweeps the PodScalar element allowlist; `InlineArray[String,
    N]` / `InlineArray[<heap-owning>, N]` is NOT on the list and is rejected.
    """
    comptime if _is_inline_array_of_elem[FieldT, Int8]():
        return True
    elif _is_inline_array_of_elem[FieldT, Int16]():
        return True
    elif _is_inline_array_of_elem[FieldT, Int32]():
        return True
    elif _is_inline_array_of_elem[FieldT, Int64]():
        return True
    elif _is_inline_array_of_elem[FieldT, UInt8]():
        return True
    elif _is_inline_array_of_elem[FieldT, UInt16]():
        return True
    elif _is_inline_array_of_elem[FieldT, UInt32]():
        return True
    elif _is_inline_array_of_elem[FieldT, UInt64]():
        return True
    elif _is_inline_array_of_elem[FieldT, Float32]():
        return True
    elif _is_inline_array_of_elem[FieldT, Float64]():
        return True
    elif _is_inline_array_of_elem[FieldT, Bool]():
        return True
    return False


def _is_pod_field[FieldT: AnyType]() -> Bool:
    """True iff a `State` field of type `FieldT` is slab-safe: a flat
    PodScalar OR an `InlineArray[PodScalar, N]`. Everything else
    (String / List / Set / OwnedPointer / nested struct) returns False."""
    comptime if _is_pod_scalar[FieldT]():
        return True
    return _is_pod_inline_array[FieldT]()


def assert_pod_state[S: AnyType & Copyable & Movable]():
    """THE slab-safety gate. Comptime-asserts that every field of `S` is slab-safe
    (a flat PodScalar or `InlineArray[PodScalar, N]`). A heap-owning field
    (`String` / `List` / `Set` / `OwnedPointer` / a nested struct) emits a
    compile error — the raw `State` slab is bytewise dumped / merged across
    workers in `AggFnAcc.flush_partial_to_column` / `merge_aligned`, so a
    heap-owning field corrupts memory at parallel-merge time.

    Pure comptime — zero runtime cost on success (the asserts compile out
    entirely). Must be FORCED from a per-conformer-monomorphized method (see
    `AggFnAcc[F].__init__`) — a `constrained[]` in an uninstantiated generic
    never fires.
    """
    comptime r = reflect[S]
    comptime ts = r.field_types()
    comptime for i in range(r.field_count()):
        comptime assert _is_pod_field[ts[i]](), ("AggFn.State has a heap-owning field (String/List/Set/OwnedPointer"
            "/nested struct) — not PodState/slab-safe. The raw State slab is"
            " bytewise dumped + cross-worker merged at flush-partial, which"
            " corrupts the inner heap buffer (a stale-slab hazard). Use a flat PodScalar"
            " (Int8..Int64/UInt8..UInt64/Float32/Float64/Bool) or"
            " InlineArray[PodScalar, N] State field instead.")
