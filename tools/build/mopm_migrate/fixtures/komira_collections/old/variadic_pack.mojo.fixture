# =============================================================================
# variadic_pack.mojo — the canonical `Tuple[*Self.Ts]` variadic-storage shape
# =============================================================================
#
# This file is the PRODUCTION REFERENCE for the variadic-parametric storage
# pattern: a family of arity-exploded structs (one per arity) collapses into
# ONE variadic-parametric struct. Every downstream variadic struct (hash
# aggregation, join build, sort buffer, project list, stages) builds on the
# shape documented here.
#
# -----------------------------------------------------------------------------
# THE CANONICAL SHAPE
# -----------------------------------------------------------------------------
#
# To store a comptime variadic pack of trait conformers as a struct field:
#
#     trait SomeTrait(Copyable, Movable, Deinitable):
#         fn process(self, ...) -> ...: ...
#
#     struct Foo[*Ts: SomeTrait]:
#         var items: Tuple[*Self.Ts]            # canonical storage
#
#         fn __init__(out self, var *items: *Self.Ts):
#             self.items = Tuple(*items^)       # positional *pack unpack
#
#         fn run(self, ...):
#             comptime for k in range(Self.Ts.__len__()):  # comptime fan-out
#                 ... self.items[k].process(...) ...
#
# Three load-bearing details:
#
#   1. The conformer trait MUST carry `Deinitable`. Without it,
#      Mojo 1.0.0b1 errors at struct compile ("'self' abandoned without
#      being explicitly destroyed").
#   2. The field type is `Tuple[*Self.Ts]`, NOT bare `*Self.Ts`. A bare
#      starred-expression as a field type is RED ("can't use starred
#      expression here"). `SomeTypeList[Trait]` as a regular type parameter
#      is ALSO RED ("expected a type, not a value") — SomeTypeList is
#      value-only at the function-signature unpack position.
#   3. Constructor forwarding uses `Tuple(*items^)` (positional unpack). The
#      keyword variants (`Tuple(take=...)`, `Tuple(storage=...)`) fail
#      type-binding in 1.0.0b1.
#
# Inside a parametric struct, ALWAYS qualify `Self.Ts` — bare `Ts` is RED
# ("unqualified access to struct parameter 'Ts'"). Same for `Self.Ts.__len__()`.
#
# -----------------------------------------------------------------------------
# CRITICAL: HOW DOWNSTREAM VARIADIC STRUCTS USE THIS SHAPE
# -----------------------------------------------------------------------------
# A downstream variadic struct embeds the canonical `Tuple[*Self.<Pack>]` shape
# DIRECTLY as a field of its own variadic-parametric struct — it does NOT
# embed the `VariadicPack` container type below. This is a deliberate design
# decision forced by a Mojo 1.0.0b1 capability limit, verified empirically:
#
#   Mojo 1.0.0b1 CANNOT unpack a variadic pack of a more-refined trait bound
#   (e.g. `*Ps: Predicate`) into a function/ctor expecting a pack of a
#   less-refined bound (e.g. `*Ts: Movable & Copyable & Deinitable`),
#   EVEN THOUGH `Predicate` refines exactly that intersection. The diagnostic
#   is "cannot unpack a pack of type 'Predicate' into a call that expects a
#   pack of type 'Movable & Copyable & Deinitable'". Pack
#   forwarding requires the bound on BOTH sides to be SYNTACTICALLY identical.
#
# Consequence: a `VariadicPack[*Ts: <FixedBound>]` cannot be a field of an
# outer struct whose own pack `*Outs: RowTransform` (or `Predicate` /
# `Aggregator`) has a different bound — the `VariadicPack[*Self.Outs](*outs^)`
# forwarding fails to type-bind. So the canonical primitive every downstream
# variadic struct embeds is the raw `Tuple[*Self.<Pack>]`, NOT this `VariadicPack` wrapper:
#
#     struct Stage_GroupAgg[Pred: Predicate, *Aggs: Aggregator](...):
#         var pred: Pred
#         var aggs: Tuple[*Self.Aggs]              # <-- raw Tuple, the shape
#         fn __init__(out self, var pred: Pred, var *aggs: *Self.Aggs):
#             self.pred = pred^
#             self.aggs = Tuple(*aggs^)            # <-- direct *pack forward
#
# `Tuple` is the wrapper. `VariadicPack` below is
# the SELF-CONTAINED reference container (usable directly when the caller's
# pack bound is exactly `VariadicElement`) and the documentation artifact for
# the shape — it is NOT a generic embeddable container across trait bounds.
#
# -----------------------------------------------------------------------------
# PERFORMANCE & SAFETY
# -----------------------------------------------------------------------------
#
# - The variadic-parametric form compiles to the SAME SoA storage as a
#   hand-written N-field struct. The `comptime for` fan-out monomorphizes
#   each slot's method call into a DIRECT inlined call — no indirect
#   branch in the inner loop.
# - It introduces NO new stale-pointer surface — `Tuple[*Self.Ts]` fields
#   behave exactly as any other Movable field. If element types carry
#   heap-owning inner fields, the usual ownership review applies; the
#   variadic container itself is inert.
#
# Encapsulation invariants:
#   - NO `UnsafePointer` in any signature — the pack is a typed value.
#   - NO wildcard origins.
#   - NO byte-erased fn-ptr dispatch — the `comptime for` fan-out is a
#     comptime-unrolled direct dispatch.
#
# Cross-references:
#   - multi_column_builder.mojo — the builder primitive that consumes this
#     shape (one `ColumnBuilder[DT]` per output slot).
# =============================================================================


trait VariadicElement(Copyable, Movable, Deinitable):
    """The bound a type must satisfy to be stored in a `VariadicPack`.

    `Deinitable` is load-bearing —
    without it Mojo 1.0.0b1 rejects any struct that stores a variadic pack
    of the trait ("'self' abandoned without being explicitly destroyed").

    `variadic_tag` — VERIFIED-FINDING: comptime-for dispatch is TRAIT-ONLY.
    -------------------------------------------------------------------------
    `VariadicElement` declares ONE abstract method, `variadic_tag()`. This is
    not decoration — it encodes a verified Mojo 1.0.0b1 capability limit:

      Inside a `comptime for k in range(arity())` over a variadic pack, a
      per-slot call `pack[k].some_method()` resolves ONLY for methods
      declared on the pack's TRAIT BOUND. A method that exists solely on the
      concrete element struct does NOT resolve — the element type indexed by
      a non-literal comptime `k` (`Self.Ts[k]`) stays an unresolved
      pack-element-type expression; only the trait's witness table is
      reachable. A LITERAL index (`pack[0]`, `pack[3]`) DOES pin the concrete
      type and reaches concrete methods.

    This is exactly why the variadic-Stage pattern is sound: every per-slot
    call a downstream variadic struct makes inside its `comptime for` is a
    TRAIT method — `Predicate.eval_scalar`, `RowTransform.write_one`,
    `Aggregator.update_scalar`. The trait surface IS the dispatch contract;
    a marker trait with no methods would be un-exercisable in a comptime-for.
    `variadic_tag` gives `VariadicPack` a trait method so the reference
    primitive is itself testable in a `comptime for`.

    The three unified UDF trait surfaces (`Predicate` / `RowTransform` /
    `Aggregator` in the eval layer) all carry `(Movable, Copyable,
    Deinitable)` — the SAME parents as `VariadicElement`. But
    Mojo 1.0.0b1 pack-forwarding requires the bound to be SYNTACTICALLY
    identical on both sides, so a `*Outs: RowTransform` pack cannot be
    forwarded into a `*Ts: VariadicElement` ctor. A downstream variadic struct
    therefore parameterizes its variadic struct directly on its own trait
    (`*Outs: RowTransform` etc.) and embeds the raw `Tuple[*Self.Outs]`, not
    a `VariadicPack`. `VariadicElement` + `VariadicPack` exist as the
    self-contained reference primitive — testable in isolation without
    dragging in the whole eval-layer trait graph — and as the canonical
    documented shape.
    """

    def variadic_tag(self) -> Int:
        """A per-element identifying tag. Exists so a `comptime for` over a
        `VariadicPack` has a TRAIT method to dispatch — see the trait doc's
        VERIFIED-FINDING note on comptime-for trait-only dispatch."""
        ...


struct VariadicPack[*Ts: VariadicElement](Movable):
    """A self-contained variadic-pack container — `Tuple[*Self.Ts]` storage
    behind a safe accessor surface.

    `VariadicPack` is the SELF-CONTAINED reference container for the
    canonical shape. It is directly usable when the caller's pack bound is
    exactly `VariadicElement`. It is NOT the type a downstream variadic struct
    embeds — those slots embed the raw `Tuple[*Self.<Pack>]` directly, because
    Mojo 1.0.0b1 cannot forward a `Predicate` / `RowTransform` / `Aggregator`
    -bounded pack into a `VariadicElement`-bounded one (see the module-doc
    "CRITICAL" section). The shape `VariadicPack` demonstrates — `Tuple`
    field, `Tuple(*items^)` ctor, `comptime for` fan-out — IS the shape
    every downstream variadic struct mirrors with its own trait-bounded pack.

    Parameters:
        Ts: The comptime variadic pack of element types. Each must satisfy
            `VariadicElement` (Copyable + Movable + Deinitable).

    Storage:
        _items: `Tuple[*Self.Ts]` — the monomorphized SoA record. Compiles
            to the identical layout a hand-written N-field struct would.

    Usage — comptime-for fan-out (the canonical shape):

        var pack = VariadicPack[A, B, C](A(), B(), C())
        comptime for k in range(VariadicPack[A, B, C].arity()):
            total += pack.get[k]().variadic_tag()   # TRAIT method — resolves

    Inside the `comptime for`, only TRAIT methods of the pack bound
    (`VariadicElement.variadic_tag` here) resolve on `pack.get[k]()` — a
    concrete-element-only method does not (see the `VariadicElement` doc's
    VERIFIED-FINDING note). `get[k]` with a LITERAL `k` pins the concrete
    type and reaches concrete methods.
    """

    var _items: Tuple[*Self.Ts]

    def __init__(out self, var *items: *Self.Ts):
        """Construct by forwarding the variadic `*pack` into `Tuple`.

        `Tuple(*items^)` is the ONLY constructor-forwarding shape that
        type-binds in Mojo 1.0.0b1 (the `take=` / `storage=` keyword forms
        fail). `var *items` (owned) — NOT `read` / `mut` — is required.
        """
        self._items = Tuple(*items^)

    @staticmethod
    def arity() -> Int:
        """The comptime element count of the pack."""
        return Self.Ts.__len__()

    @always_inline
    def get[k: Int](self) -> ref [self._items] Self.Ts[k]:
        """Borrow element `k` of the pack (k in [0, arity())).

        Returns a `ref` into `self._items` — the borrow's lifetime is bound
        to the pack. The comptime index `k` makes the dispatch a direct
        access; there is no runtime indirection.
        """
        return self._items[k]

    @always_inline
    def get_mut[k: Int](mut self) -> ref [self._items] Self.Ts[k]:
        """Mutably borrow element `k` of the pack (k in [0, arity()))."""
        return self._items[k]
