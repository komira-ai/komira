# =============================================================================
# row_transform.mojo — the unified `RowTransform` trait surface
# =============================================================================
#
# `RowTransform` is one of three unified trait surfaces (with `Predicate`
# and `Aggregator`) that bridge:
#   - the comptime SIMD-fused ExprX trees (`ExprXI64` / `ExprXF64` / etc.,
#     single-output),
#   - the user-facing per-row map UDF trait (`MapFn`, multi-output struct),
#   - the catalog primitives.
#
# It is the broad "row -> row" slot type the variadic Stage substrate's
# output pack (`Stage_FilterProject[Pred, *Outs: RowTransform]`) is
# parameterized on. A single-output Expr lands with `ARITY = 1`; a
# multi-output `MapFn` lands with `ARITY = N`. The variadic pack absorbs
# arbitrary output arity.
#
# write_one is the unifying method.
# -----------------------------------------------------------------------------
# A parametric SIMD method `eval[W, bo, k]() -> SIMD[Self.dtype_at[k](), W]`
# is NOT implementable in Mojo: a trait method whose return type depends on a
# trait associated method (`Scalar[Self.dtype_at[k]()]`) cannot be resolved
# through the trait witness — the compiler fails with "failed to locate
# witness entry" from ANY parametric caller, not just a default body. This is
# the same limitation that makes `trait T[D: DType]` unusable, which is why the
# ExprX family is split into per-DType `ExprXI64` / `ExprXF64` / ... traits
# rather than one parametric trait.
#
# So `RowTransform`'s unifying method is `write_one` — it writes ALL `ARITY`
# output columns for one input row into a `MultiColumnBuilder` and `raises`;
# its signature carries NO parametric return type, so it resolves cleanly
# through the trait witness. Per-column SIMD fast paths stay a per-conformer
# concern: `ExprXI64` keeps its own static `eval[W, bo]` (a concrete
# `SIMD[DType.int64, W]` return — no associated-method dependency), and the
# expression tree composes through `ExprXI64` unchanged. The unified
# `RowTransform` view the Stage sees needs only `write_one` + `ARITY` +
# `dtype_at` + `PURITY`.
#
# write_one + the MultiColumnSink dependency.
# -----------------------------------------------------------------------------
# `write_one`'s builder parameter is bounded on the `MultiColumnSink` trait
# (below), NOT on `AnyType`.
#
#     fn write_one[bo, MCB: MultiColumnSink](mut self, batch, i,
#                                            mut builders: MCB)
#
# An `AnyType`-bounded method parameter exposes ZERO methods — a `write_one`
# body (default OR conformer) cannot call `builders.append_at[...]` on an
# `AnyType` builder (`"'MCB' value has no attribute 'append_at'"`). That would
# make `RowTransform.write_one[MCB: AnyType]` an UNIMPLEMENTABLE surface: the
# only way to drive an `AnyType` builder is an un-generalizable
# `rebind[ConcreteBuilder]` hack hand-naming a specific builder type.
#
# `MultiColumnSink` (below) is the minimal builder-trait bound — it exposes
# the one method a `RowTransform` body needs, `append_at[k, DT]`. The
# production `MultiColumnBuilder[*Bs]` carries `append_at[k, DT]` (verbatim
# signature match) and conforms to `MultiColumnSink` directly. `MCB` stays a
# METHOD-level type parameter so the builder's concrete pack arity is
# monomorphized per call site; the trait bound just makes the builder's
# surface visible inside `write_one`. No `UnsafePointer`, no wildcard origin
# — the builder is a typed value passed by `mut` reference.
#
# Encapsulation invariants:
#   - NO `UnsafePointer` in any method signature.
#   - NO wildcard origins — `bo: Origin[mut=False]` threads the per-batch
#     lifetime witness.
#
# Cross-references:
#   - `komira_arrow.multi_column_builder` — `MultiColumnBuilder`.
#   - expr_x.mojo — `ExprXI64` / `ExprXF64` (refine `RowTransform`; keep
#     their own per-DType static `eval[W]`).
#   - map_fn.mojo — `MapFn` (refines `RowTransform`).
# =============================================================================

from komira_arrow.batch_view import BatchView
from komira_arrow.multi_column_builder import (
    MultiColumnSink,
    SinkKind,
)
from komira_udf.column_resolver import ColumnResolver
from komira_udf.purity import Purity


# =============================================================================
# MultiColumnSink — the minimal builder-trait bound for `RowTransform.write_one`
# =============================================================================
#
# `MultiColumnSink` is declared in `komira_arrow.multi_column_builder`
# (next to `MultiColumnBuilder`) and re-imported here. It MUST live in
# `komira_core` rather than `komira_udf`: the production builder
# `MultiColumnBuilder[*Bs]` lives in `komira_core`, and a struct can only
# declare conformance to a trait that is importable at its own layer —
# `komira_core` cannot import from `komira_udf` (the layering runs
# `komira_udf` -> `komira_core`, never the reverse). `MultiColumnSink` is a
# builder-surface trait; it belongs with the builder.
#
# `MultiColumnSink` exposes the one method a `RowTransform.write_one` body
# needs — the comptime-indexed `append_at[k, DT]`. `MCB` stays a method-level
# type parameter on `write_one` so the builder's concrete pack arity is
# monomorphized per call site; the bound just makes `append_at` visible
# inside the body.
# =============================================================================


trait RowTransform(Movable, Copyable, Deinitable):
    """Unified "row -> row" trait — bridges single-output `ExprX*` Exprs
    and the multi-output `MapFn`.

    Conformers MUST provide `write_one` (write all `ARITY` output columns
    for one input row into the multi-column builder) and `dtype_at` (the
    output DType of each of the `ARITY` output slots).

    Members:
      - `PURITY`  : optimizer pushdown / fold marker. Default
                    `STATELESS`.
      - `ARITY`   : the output-column count. 1 for a single-Expr transform;
                    N for an N-output `MapFn`.
      - `dtype_at[k]` : the output DType of output slot `k` (k in [0, ARITY)).

    Per-column SIMD fast paths are NOT part of this trait surface (a
    parametric-return SIMD trait method is not resolvable through the
    Mojo 1.0.0b1 witness — see the module doc). Conformers that want a
    SIMD fast path keep their own concrete per-DType `eval[W]` (the
    existing `ExprXI64` / `ExprXF64` shape); the Stage's per-column SIMD
    path binds to that concrete trait, while the unified `RowTransform`
    view drives the multi-column `write_one` path.
    """

    comptime PURITY: Purity = Purity.STATELESS
    comptime ARITY: Int = 1
    """The output-column count. Defaults to 1 (single-output Expr — the
    common case). A multi-output `MapFn` conformer overrides this with `N`.

    The default lives on this PARENT trait deliberately: re-declaring a
    `comptime` member with a default value on a REFINING trait crashes the
    Mojo 1.0.0b1 compiler. Refining traits
    (`ExprX{numeric}`) inherit this default; conformers needing N>1 declare
    `comptime ARITY = N` directly."""

    @staticmethod
    def dtype_at[k: Int]() -> DType:
        """The output DType of output slot `k` (k in [0, ARITY)).

        ⚠ MEANINGFUL ONLY WHEN `out_kind_at[k]()` IS `NUMERIC`. A STRING
        output slot has no value-channel DType and Mojo 1.0.0 removed
        `DType.invalid`, so a String-producing conformer returns a
        documented placeholder here. Read `out_kind_at[k]()` FIRST; every
        in-tree dispatcher does (`ProjectList.emit_projected` is the worked
        example).
        """
        ...

    @staticmethod
    def out_kind_at[k: Int]() -> SinkKind:
        """WHICH value channel output slot `k` writes through.

        The default is `NUMERIC`, so every pre-existing conformer keeps
        conforming with NO edit; `ExprXString` overrides it to `STRING`.

        This is the ONE fact a caller needs before it can choose the sink
        type for slot `k` — a numeric `ColumnSlot[dtype_at[k]()]` or a
        `StringColumnSlot` — and before it can choose which append method
        to drive. It is deliberately a separate accessor rather than a
        widened `dtype_at`, because there is no DType that means "String"
        and inventing one is what would put a plausible-looking lie in the
        output Schema.

        ⚠ REQUIRED, NOT DEFAULTED — structurally identical to `dtype_at`,
        and for the same reason. A `SinkKind.NUMERIC` default here would be
        cheaper for the 6 numeric conformers and it does not compile:
        Mojo 1.0.0b1 rejects conflicting default impls on a parent and a
        refining trait, so `ExprXString` could not
        then declare STRING. Making it required also means every conformer
        STATES its output channel, exactly as it states its output DType,
        instead of inheriting a channel it never thought about.
        """
        ...

    def write_one[
        bo: Origin[mut=False], MCB: MultiColumnSink
    ](mut self, batch: BatchView[bo], i: Int, mut builders: MCB) raises:
        """REQUIRED — write all `ARITY` output column values for the single
        input row at logical index `i`.

        `builders` is a multi-column builder (one `ColumnBuilder[DT]` per
        output slot). It is a METHOD-level type parameter `MCB` bounded on
        `MultiColumnSink` — the bound exposes
        `append_at[k, DT]` so the body can land one value per output slot.
        The production `MultiColumnBuilder[*Bs]` conforms to `MultiColumnSink`
        directly, so callers instantiate `write_one` with
        `MCB = MultiColumnBuilder[...]` at the call site.
        """
        ...

    def bind(mut self, resolver: ColumnResolver) raises:
        """Bind walker entry on
        the unified RowTransform trait surface.

        Default body is no-op: the in-tree refining traits (`ExprXI64` /
        `ExprXF64` / `ExprXI32` / `ExprXF32` / `ExprXString`) already declare
        their own no-op `bind` default (see `expr_x.mojo`) and the leaf + binop conformers override it to thread
        the resolver through their children. Adding `bind` to RowTransform
        lets `ProjectList[*Outs: RowTransform]` walk `self._outs[k].bind(
        resolver)` over the variadic Out pack via the unified trait surface
        without needing a tighter per-DType bound — every refining trait /
        directly-conforming struct satisfies the requirement via the
        no-op default.

        Non-ExprX RowTransform conformers (`MapFnRT`, `IdentityI64` test
        fixture) inherit this no-op default — they have no name-keyed leaves
        to bind. If a future MapFn variant carries name-keyed inputs, it
        overrides `bind` to thread the resolver to its column lookup state.
        """
        pass

    def project_one[
        bo: Origin[mut=False], dst_k: Int, MCB: MultiColumnSink
    ](mut self, batch: BatchView[bo], i: Int, mut builders: MCB) raises:
        """INSTANCE variant of `write_one` for the Stage project emit.
        Writes this transform's output value for input row `i` into output
        slot `dst_k` of `builders`.

        `mut self`, not `@staticmethod`: the leaf conformers (`ColXI64[name]`)
        carry a runtime `_idx = -1` populated by `bind(resolver)`, and a
        static body constructing `var inst = Self()` per call would read
        `_idx == -1` → SIGSEGV on `batch.col_i64(-1)`. So `ProjectsLike` is
        `(Movable, Deinitable)`, `ProjectList` has a `Tuple[*Self.Outs]`
        instance field, and `project_one` is `mut self` so `ProjectList.emit_projected` can call
        `self._outs[k].project_one[...]` instance dispatch (the bound `_idx`
        in `self.eval_scalar_s` is consulted, not an unbound stack temp).

        `dst_k` is the OUTPUT slot index in the builder (the project's column
        k); a single-output transform (`ARITY == 1`) writes its lone value
        there. Multi-output transforms (`MapFn`, `ARITY > 1`) override
        with their own multi-slot body (the UDF-map executor path).

        The refining ExprX numeric traits (`ExprXI64` / `ExprXF64` / `ExprXI32`
        / `ExprXF32`) carry the delegating default body (forward to
        `self.eval_scalar_s` -> `builders.append_at[dst_k, dtype]`);
        conformers inherit it for free. As a bonus, `MapFnRT` can now
        implement `project_one` properly (it has access to `self._udf` via
        `mut self`), instead of the prior `constrained[False]`
        compile-time-reject stub.
        """
        ...
