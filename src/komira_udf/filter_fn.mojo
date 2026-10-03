# =============================================================================
# filter_fn.mojo — typed user-defined predicate trait (FilterFn).
# =============================================================================
#
# The user-facing predicate UDF trait:
#  - `comptime InRow: AnyType & Copyable & Movable & AutoKomiraSchema` —
#    the `AutoKomiraSchema` marker trait gives a user-facing contract for row
#    structs (each field maps to one column; @fieldwise_init for the
#    positional constructor).
#  - `comptime InputSchema: SchemaDescriptor = _derive_schema[Self.InRow]()`
#    — trait default; auto-derives via comptime reflection on the row
#    struct's fields. Conformers may still override explicitly when field
#    names need to differ from column names.
#  - `keep_row` is the ONE oracle.
#
# The SIMD fast path is the engine-internal `_FilterFnFusedKernel`
# (`komira_engine_operators._internal.filter_fn_fused_kernel`); it is not part
# of the user-facing surface. End users write `FilterFn` (per-row) or
# `ExprScalarFn` (SIMD UDF in the expression tree).
#
# Why there is no positional `keep_scalar`
# ------------------------------------------------------
# Mojo cannot reach a struct's `@fieldwise_init`-synthesized positional
# constructor through a generic trait member, so an engine driver parametric
# over `F: FilterFn` cannot build `F.InRow(c0.get(i), ...)` positionally. It
# does not need to: comptime reflection over `InRow`
# (`reflect[R].field_offset`) gives it the field layout, so it builds the row
# itself — `row_builder._build_row[R]` — and calls `keep_row` directly.
#
# A positional het-pack oracle would also be harmful: a `raises` variadic
# het-pack method CRASHES the Mojo 1.0.0 compiler, so a fallible UDF would be
# unreachable while such an oracle was on the trait.
#
# The trait-default `comptime InputSchema = _derive_schema[Self.InRow]()`
# fires per-conformer at the call site. The trait member constraint must
# REPEAT `AnyType & Copyable & Movable & Deinitable & AutoKomiraSchema` —
# Mojo doesn't auto-propagate it from the trait header.
# =============================================================================

from komira_udf.schema_descriptor import SchemaDescriptor, _derive_schema
from komira_udf.auto_komira_schema import AutoKomiraSchema
from komira_udf.udf_descriptor import NullHandling
from komira_udf.stateful_contract import StatefulContract
from komira_udf.predicate import Predicate


trait FilterFn(Predicate, Movable, Copyable, Deinitable):
    """A typed user-defined predicate: takes one row -> Bool.

    `FilterFn` refines the
    unified `Predicate` surface via trait inheritance — every `FilterFn`
    conformer transitively conforms to `Predicate`, so the variadic Stage
    substrate's `Pred: Predicate` slot accepts a `FilterFn` directly with
    NO adapter struct and NO wrapper. A `FilterFn` conformer implements
    `Predicate.eval_scalar(batch, i)` as a one-line delegate that reads its
    input columns off the `BatchView` and forwards to `keep_row`; it
    picks up the Pattern B default-body `eval[W]` for free. The
    `keep_row` surface is the ergonomic user-facing form — and the only
    one.

    Required user-supplied members:
      - `comptime InRow: AutoKomiraSchema` — the row struct. Each field maps
        to one input column (the engine builds per-row instances from
        per-column primitive arrays). `InRow` must be `@fieldwise_init`
        for the positional constructor; conforming to `AutoKomiraSchema`
        formalises the row-struct contract.
      - `comptime UDF_ID: UInt32` — the operator-factory selector. Choose
        a value in [7000, 9999] (the registered UDF range). Mojo 1.0.0b1
        has no `_type_hash[T]()`; once a stable type-identity API lands,
        a future revision can derive this automatically.
      - `fn keep_row(mut self, row: Self.InRow) -> Bool` — REQUIRED, and
        the ONLY oracle. The engine's per-row dispatch calls
        THIS for each row in the morsel: it builds an `InRow` from the
        bound input column via `row_builder._build_row[Self.InRow]` and
        hands it over. Put the actual logic here. (There is no positional
        `keep_scalar` — see the header section above.)

    Trait-default members (auto-derived, override per-conformer if needed):
      - `comptime InputSchema: SchemaDescriptor = _derive_schema[Self.InRow]()`
        — derives schema from `InRow`'s `@fieldwise_init`-exposed fields
        via comptime reflection. A conformer can declare
        `comptime InputSchema = schema_of["col_name", DT_X, ...]()` to
        override — useful when field names need to differ from column names.
      - `comptime null_mode: NullHandling = NullHandling.PROPAGATE`
      - `comptime parallelism: StatefulContract = StatefulContract.stateless`
    """

    # `& Deinitable` is load-bearing — the engine builds
    # `InRow` itself (`row_builder._build_row[R]`) in an
    # `InlineArray[R, 1]` slot, which Mojo will not let it drop unless R
    # is Deinitable. Implicit for a plain `@fieldwise_init` row struct.
    comptime InRow: AnyType & Copyable & Movable & Deinitable & AutoKomiraSchema
    comptime InputSchema: SchemaDescriptor = _derive_schema[Self.InRow]()
    comptime null_mode: NullHandling = NullHandling.PROPAGATE
    comptime parallelism: StatefulContract = StatefulContract.stateless
    comptime UDF_ID: UInt32

    def keep_row(mut self, row: Self.InRow) raises -> Bool:
        """REQUIRED — true => keep the row. The readable user-facing form.
        Normally the whole body: `return row.col_a > self.threshold`.

        `raises` so a customer predicate may FAIL and surface its own
        error. A NON-raising conformer still conforms — non-variadic trait
        method, FACT 1 in `tests/test_typed_udf_raises_variance.mojo`."""
        ...

    # ---- no `keep_scalar` ----
    #
    # The positional het-pack oracle
    #   `def keep_scalar[*Ts: Copyable & Movable](mut self, *vals: *Ts)`
    # is NOT part of this trait. `keep_row` above is the ONE oracle; the
    # engine builds `Self.InRow` itself via `row_builder._build_row[R]`
    # and calls it directly.
    #
    # ⛔ DO NOT ADD IT — the full argument is in the header section
    # "Why there is no positional `keep_scalar`", and the mirror note is in `map_fn.mojo`.
    #
    # A conformer may keep a PRIVATE `keep_scalar` helper and delegate to
    # it from `keep_row`; an orphaned method on a struct is not a trait
    # member and costs nothing. The trait simply no longer knows about it.


# =============================================================================
# The SimdOf-typed fast path
# =============================================================================
#
# The SimdOf-typed sub-trait is
# `komira_engine_operators._internal.filter_fn_fused_kernel._FilterFnFusedKernel`.
# It is engine-internal only; not exported from any user-facing
# `__init__.mojo`. Engine call sites import it directly:
#
#   from komira_engine_operators._internal.filter_fn_fused_kernel import (
#       _FilterFnFusedKernel,
#   )
#
# End users keep writing `FilterFn` (per-row form) or `ExprScalarFn`
# (Eigen-tree SIMD UDF, see `komira_udf.expr_scalar_fn`).
# =============================================================================
