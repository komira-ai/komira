# =============================================================================
# erased_box — a DEEP-COPYABLE, type-erased, heap-owning box
# =============================================================================
#
# ⭐ WHY THIS EXISTS: `Expr` MUST NOT NAME `LogicalPlan`, AND SQL SAYS IT MUST
# HOLD ONE.
#
# `WHERE x > (SELECT max(y) FROM t2)` genuinely nests a plan inside an
# expression, so `Expr` tag 14 (`EXPR_CORRELATED_SUBQUERY`) carries a whole
# `LogicalPlan`. Naming that type in the field would put `plan/expr.mojo`
# inside a large strongly-connected component and pull most of the core packages
# into its translation-unit closure — and `Expr` could not be a foundation
# type.
#
# ⛔ AND THERE IS NO CHEAPER SHAPE. Mojo 1.0.0 has NO existential / `dyn Trait`
# storage — every `trait` in this tree is used as a comptime BOUND, never as a
# stored type — and generics propagate (`CorrelatedSubqueryData[P]` forces
# `Expr[P]`, and `Expr` has hundreds of importers). So a field a LEAF module can declare
# is exactly one of: an INDEX into a side table, opaque BYTES, or this — an
# owned home plus a manual vtable. The first needs a registry with a lifetime,
# an eviction policy, an ABA generation and a thread story; the second makes the
# correctness of every correlated query depend on the plan-wire codec being
# lossless. This one needs none of that, and it is the only one of the three
# that preserves `Expr.copy()`'s DEEP-CLONE semantics exactly.
#
# ⚠ THAT LAST POINT IS LOAD-BEARING, NOT AESTHETIC. `scan_binding_bind_pass.
# bind_plan_inmem_payloads(registry, mut plan)` MUTATES a subquery's inner plan
# IN PLACE. A design where two `Expr` copies share one registered plan would let
# binding one bind the other — so "share the plan behind a handle, it is
# immutable anyway" is FALSE here: it would be a silent cross-query mutation.
#
# ── RELATIONSHIP TO `komira_async.runtime.shared_erasure` ────────────────────
# That module is the blessed `ErasedHandle` shape and this one deliberately
# copies its teardown VERBATIM (see `single_consume_drop` below). It is NOT
# reusable here for two independent reasons:
#   1. its closure INCLUDES THE REACTOR (`komira_async.reactor.*`,
#      `epoll_subsystem`, `kqueue_subsystem`). Importing it from under `Expr`
#      would trade plan modules for the async runtime — a worse closure and a
#      much worse layering.
#   2. its payloads are MOVE-ONLY work items; it has no COPY thunk. `Expr.copy()`
#      is a deep clone, so a copy thunk is the whole requirement.
# ⇒ Two erasure sites, one FINDING, zero duplicated teardown logic.
#
# ★★ THE DUAL-STEP-DROP FINDING IS CARRIED HERE VERBATIM. `__del__`
# RELINQUISHES the home's own free (`unsafe_leak()`) and hands the raw bytes to
# `_destroy`, which reconstructs ONE `OwnedPointer[W]` and `.into_inner()`s it —
# destroy + free as a SINGLE tracked consume. The naive two-step
# (`destroy_pointee` then a separate byte-free) DOUBLE-FREES a `W` with a nested
# heap-owning field, and `LogicalPlan` — `String` schema field names, `List`
# children, `OwnedPointer` variant payloads — is exactly that shape.
# ⛔ Do NOT "simplify" it back.
#
# ── THE VTABLE IS DERIVED FROM `W`, NEVER HAND-WRITTEN ──────────────────────
# `make_erased_box[W]` takes the ADDRESS of `erased_box_destroy_for[W]` and
# `erased_box_copy_for[W]`, both monomorphized from `W` alone. A caller cannot
# supply a mismatched pair, which is the failure this shape is most exposed to.
# `W: DeepCopyable` is what makes the copy thunk derivable — a bound, not a
# stored type, so nothing here is dynamic dispatch on a stored trait.
#
# ── THE TYPE TAG IS A GUARD, NOT A DISPATCH KEY ─────────────────────────────
# The bytes carry no type. `unsafe_as[T]` cannot check anything, so the CALLER
# proves `T` by comparing `type_tag()` against the tag it minted with, and
# RAISES on a mismatch. One tag per boxed type, declared next to the boxing
# function — see `corr_subquery_data.CORR_SUBQ_PLAN_TYPE_TAG`.
#
# ⚠ POINTER RULES. `UnsafePointer` never crosses a module boundary as a public
# API here: the two thunk aliases and the two `unsafe_origin_cast` bodies are
# the only wildcard-origin sites, they live in fn-ptr aliases and cast bodies —
# never a struct FIELD. `_home` is a concrete-origin `OwnedPointer`, the
# fn-ptr fields are FFI-POD code pointers (no heap), and `unsafe_as[T]`
# returns a `ref` whose origin is tied to
# `_home`, not a raw pointer.
#
# ⛔ THIS MODULE MUST IMPORT NOTHING BUT `std.memory`. Its whole reason to exist
# is that `expr.mojo` can reach it for free. An import added here is an import
# added to `Expr`.
# =============================================================================

from std.memory import OwnedPointer, UnsafePointer, alloc


comptime _RawHome = UnsafePointer[UInt8, MutUntrackedOrigin]
"""The erased home, mutable. Wildcard origin confined to fn-ptr aliases + casts."""

comptime _ConstHome = UnsafePointer[UInt8, ImmUntrackedOrigin]
"""The erased home, READ-ONLY — what the copy thunk gets. A copy reads its
source; giving it a mutable view would be a wider claim than it needs."""

comptime _DestroyFn = def (_RawHome) thin -> None
comptime _CopyFn = def (_ConstHome) thin -> _RawHome


trait DeepCopyable(Movable, Deinitable):
    """A type with an EXPLICIT deep clone — Mojo's `Copyable` means IMPLICIT
    copy, which `LogicalPlan` deliberately is not.

    This is a comptime BOUND used to derive `erased_box_copy_for[W]`. It is
    never stored, so conforming costs a struct nothing at runtime."""

    def copy(self) -> Self:
        ...


struct ErasedBox(Movable):
    """One heap-owning, type-erased, DEEP-COPYABLE value plus its vtable.

    Fields:
        _home: the value's byte home. CONCRETE origin (`OwnedPointer`), single
            owner. Its free is RELINQUISHED in `__del__` before `_destroy` runs.
        _destroy / _copy: FFI-POD code pointers monomorphized from `W` by
            `make_erased_box[W]`. Never supplied by hand.
        _type_tag: the caller's proof obligation for `unsafe_as[T]`.
    """

    var _home: OwnedPointer[UInt8]
    var _destroy: _DestroyFn
    var _copy: _CopyFn
    var _type_tag: UInt32

    def __init__(
        out self,
        var home: OwnedPointer[UInt8],
        destroy: _DestroyFn,
        copy_fn: _CopyFn,
        type_tag: UInt32,
    ):
        self._home = home^
        self._destroy = destroy
        self._copy = copy_fn
        self._type_tag = type_tag

    def copy(self) -> Self:
        """Deep-clone the boxed value into a FRESH home.

        # SAFETY: `_copy` is `erased_box_copy_for[W]` for the `W` in `_home`
        # (paired at mint time, not by the caller); it reads through a read-only
        # view of our bytes and returns the raw home of an independent clone,
        # which we immediately place under a single-owner `OwnedPointer`. The
        # borrowed view never escapes this body."""
        var src = self._home.unsafe_ptr().unsafe_origin_cast[ImmUntrackedOrigin]()
        var fresh = self._copy(src)
        return Self(
            OwnedPointer[UInt8](unsafe_from_raw_pointer=fresh),
            self._destroy,
            self._copy,
            self._type_tag,
        )

    @always_inline
    def type_tag(self) -> UInt32:
        """The tag minted with this box. Compare it before `unsafe_as[T]`."""
        return self._type_tag

    @always_inline
    def unsafe_as[T: AnyType](ref self) -> ref [origin_of(self._home)] T:
        """Borrow the boxed value as `T`.

        ⚠ THE BYTES CARRY NO TYPE. This cannot verify `T`; the caller must have
        compared `type_tag()` first. Wrap it — do not call it from a site that
        has not raised on a mismatch.

        # SAFETY: `_home` owns a valid `T` for this box's lifetime when the tag
        # matches. The returned `ref` is origin-tied to `_home`, so it cannot
        # outlive the box, and no pointer leaves this body."""
        return self._home.unsafe_ptr().bitcast[T]()[]

    def __deinit__(deinit self):
        """Destroy the value AND free its home in ONE tracked consume.

        # SAFETY: `unsafe_leak()` RELINQUISHES `_home`'s own free so the buffer
        # is not freed twice, then `_destroy` reconstructs ONE `OwnedPointer[W]`
        # and destroys+frees atomically. This is the dual-step-drop finding —
        # the naive two-step DOUBLE-FREES a `W` with a nested heap-owning field,
        # and `LogicalPlan` is exactly that shape. Runs exactly once per box."""
        var raw = self._home^.unsafe_take_allocation().unsafe_leak().unsafe_origin_cast[
            MutUntrackedOrigin
        ]()
        self._destroy(raw)


@always_inline
def single_consume_drop[W: Movable & Deinitable](p: _RawHome):
    """THE single-consume teardown primitive (the `shared_erasure` finding).

    Destroy a concrete `W` AND free its home in ONE shot by reconstructing an
    `OwnedPointer[W]` over the home bytes and `.into_inner()`-ing it, so `W`'s
    destructor and the buffer free are a SINGLE tracked consume.

    # SAFETY: `p` is the raw home of a valid `W` placed by `make_erased_box[W]`,
    # whose `OwnedPointer` free `ErasedBox.__del__` already RELINQUISHED via
    # `unsafe_leak()` — this helper is the SOLE owner of the bytes for teardown.
    # The raw pointer never escapes this body."""
    var owned = OwnedPointer[W](unsafe_from_raw_pointer=p.bitcast[W]())
    var work = owned^.into_inner()
    _ = work^


def erased_box_destroy_for[W: Movable & Deinitable](p: _RawHome):
    """Per-`W` destroy trampoline; its ADDRESS is taken by `make_erased_box[W]`.

    SAFETY: see `single_consume_drop`."""
    single_consume_drop[W](p)


def erased_box_copy_for[W: DeepCopyable](p: _ConstHome) -> _RawHome:
    """Per-`W` deep-copy trampoline; its ADDRESS is taken by `make_erased_box[W]`.

    # SAFETY: `p` is the raw home of a live `W` owned by the SOURCE box, read
    # only. `W.copy()` produces an INDEPENDENT value, which is moved into a
    # fresh `alloc[W](1)` (no double-init). The returned home is owned by
    # nobody until `ErasedBox.copy` wraps it, on the next statement."""
    var src = p.bitcast[W]()
    var clone = src[].copy()
    var home = alloc[W](1)
    UnsafePointer(to=home[]).unsafe_write(clone^)
    return home.bitcast[UInt8]().unsafe_origin_cast[MutUntrackedOrigin]()


def make_erased_box[W: DeepCopyable](var value: W, type_tag: UInt32) -> ErasedBox:
    """Erase a concrete `W` into an `ErasedBox`.

    PUBLIC signature is pointer-free: takes `var value: W`, returns `ErasedBox`.
    Both thunks are derived from `W` here, so a mismatched vtable cannot be
    constructed by a caller.

    # SAFETY: `alloc[W](1)` is a fresh allocation we own; `init_pointee_move`
    # consumes `value` into it (no double-init); the bitcast home is wrapped in
    # a single-owner `OwnedPointer[UInt8]`. `W`'s destructor runs via
    # `erased_box_destroy_for[W]` in `ErasedBox.__del__`. Identical shape to
    # `shared_erasure.make_erased` and `udf_registry.make_udf_box`."""
    var home_typed = alloc[W](1)
    UnsafePointer(to=home_typed[]).unsafe_write(value^)
    var home = OwnedPointer[UInt8](
        unsafe_from_raw_pointer=home_typed.bitcast[UInt8]()
    )
    return ErasedBox(
        home^, erased_box_destroy_for[W], erased_box_copy_for[W], type_tag
    )
