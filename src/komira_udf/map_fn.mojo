# =============================================================================
# map_fn.mojo — the typed user-defined map trait (MapFn)
# =============================================================================
#
# A `MapFn` is a typed user-defined map: N input columns -> 1 output column
# (the projection / `with_column` UDF). The struct's fields ARE the closure's
# "captures" (a `var scale: Float64` field is the `move |x, y| x*y*scale`).
# Each worker gets its own copy via `Copyable`; the engine never shares an
# instance across workers.
#
# The OPTIONAL SIMD fast path is the engine-internal `_MapFnFusedKernel`
# sub-trait (in `komira_engine_operators._internal.map_fn_fused_kernel`),
# carrying `@staticmethod eval[W]` / `eval_row` with SimdOf-typed input rows.
# A UDF that wants the SIMD path opts into `_MapFnFusedKernel` explicitly
# (or `_MapFnManualFusedKernel` for MANUAL null handling); the engine driver
# dispatches `comptime if conforms_to(F, _MapFnFusedKernel)`.
#
# `comptime InputSchema: SchemaDescriptor = _derive_schema[Self.InRow]()` is a
# trait default, as on AggFn: it auto-derives the schema from the `InRow`
# struct's `@fieldwise_init`-exposed fields via comptime reflection.
# Conformers may override by declaring `comptime InputSchema =
# schema_of[...]()` directly (the explicit value wins — useful when column
# names differ from field names).
# =============================================================================

from komira_udf.schema_descriptor import SchemaDescriptor, _derive_schema
from komira_udf.udf_descriptor import NullHandling
from komira_udf.stateful_contract import StatefulContract


trait MapFn(Movable, Copyable, Deinitable):
    """A typed user-defined map: N input columns -> 1 output column.

    Conformers MUST provide:
      - `InRow`        : a plain `@fieldwise_init struct` of typed fields, one
                          per input column this UDF reads (field names should
                          match the source column names; types match the
                          column dtypes). `Copyable & Movable`. `row.field`
                          is then a bare comptime-typed field access — the
                          ergonomic surface (no `__getattr__` magic; it works
                          *because* it's a normal struct field).
      - `InputSchema`  : a `comptime SchemaDescriptor` matching `InRow`'s
                          fields (name + dtype tag, in order). The engine
                          comptime-asserts the two agree, uses it to resolve
                          the projection map against the child schema at
                          materialize-time, AND uses it to know each het-pack
                          element's concrete dtype (struct-field reflection
                          over `InRow` does not work here, so
                          `InputSchema` is the source of truth for arity+dtypes).
      - `OutputSchema` : a `comptime SchemaDescriptor` naming + typing the
                          (one) output column.
      - `OutType`      : `= OutputSchema.cols[0]`'s dtype as a stdlib `DType`
                          (the engine `comptime assert`s consistency).
      - `UDF_ID`       : a user-declared `comptime UInt32` — the
                          operator-factory selector. `UdfData.operator_factory_id`
                          snapshots it; the operator-build driver matches it
                          against the threaded comptime UDF pack; it folds
                          into the plan structural_hash so plan_cse never
                          shares two distinct UDF nodes. No `__type_of`-hash /
                          `__builtin_LINE` in 1.0.0b1 — this is the only
                          mechanism. (The SDK MAY auto-assign via a comptime
                          counter; a required member is the simplest GREEN form.)
      - `run_row`      : REQUIRED — and the ONLY oracle. The
                          engine's per-row path calls THIS: it builds an
                          `InRow` from the bound input column via
                          `row_builder._build_row[Self.InRow]` and hands it
                          over. Put the actual logic here.
                          (There is no positional het-pack `run_scalar`
                          oracle — see the note below the method
                          declarations.)
    Conformers MAY ALSO conform to `_MapFnFusedKernel` (in
    `komira_engine_operators._internal.map_fn_fused_kernel`) to provide
    `@staticmethod eval[W]` / `eval_row` — the explicit-SIMD fast path
    used by the engine's fused-chain templates.
    """

    # `& Deinitable` is load-bearing. The engine builds `InRow`
    # itself (`row_builder._build_row[R]`) in an `InlineArray[R, 1]`
    # slot, and Mojo will not let that slot be dropped unless R is
    # Deinitable. A plain `@fieldwise_init struct(Copyable, Movable)`
    # satisfies this implicitly, so no conformer had to change.
    comptime InRow: Copyable & Movable & Deinitable   # a @fieldwise_init struct of typed input fields
    # Trait default — auto-derive from InRow via
    # comptime reflection. Mirrors `AggFn.InputSchema` and
    # `FilterFn.InputSchema`. The default fires per-conformer at the call site
    # (NOT at trait-decl time against an unbound abstract member). Conformers
    # may override by declaring `comptime InputSchema = schema_of[...]()`
    # directly (the explicit value wins) — useful when field names differ
    # from column names. Conformers that declare the line explicitly
    # make this default a no-op.
    comptime InputSchema: SchemaDescriptor = _derive_schema[Self.InRow]()
                                                # name+dtype of InRow's fields, in order (= the engine's arity+dtype source)
    comptime OutputSchema: SchemaDescriptor     # name+dtype of the (one) output column
    comptime OutType: DType                     # = OutputSchema.cols[0].dtype (the engine asserts)
    comptime null_mode: NullHandling = NullHandling.PROPAGATE   # PROPAGATE / SKIP_NULL_FAST_PATH / MANUAL
    comptime parallelism: StatefulContract = StatefulContract.stateless   # default = stateless
    comptime UDF_ID: UInt32                     # the operator-factory selector
    # NORMATIVE RULE (compile-time gate at trait elaboration in the map operator):
    #   a MANUAL-mode map MUST conform to `_MapFnManualFusedKernel` (the engine-internal
    #   SIMD-typed surface) — run_scalar/run_row never carry validity, so a MANUAL-mode UDF
    #   is by construction never per-lane-fallback'd. String-input maps are exempt
    #   (no vector path).

    # ---- REQUIRED: the ergonomic scalar oracle (named row struct) ----
    # `mut self` ALWAYS in the trait (free when unused; a
    #   stateless conformer may declare `self` instead and still conforms).
    def run_row(mut self, row: Self.InRow) raises -> Scalar[Self.OutType]:
        """One input row -> one output value. Arbitrary Mojo. The correctness
        contract: `_MapFnFusedKernel.eval[W=1]` (if the conformer opts into
        the engine-internal fused-kernel surface) MUST produce lane-for-lane
        the same result. Slow at scale (row-at-a-time). Normally the whole
        body: `return row.col_a * (1.0 - row.col_b)`.

        `raises` so a customer UDF may FAIL -- divide, parse, index,
        or refuse a value -- and have its own error surface to the caller
        instead of being swallowed. A NON-raising conformer still conforms:
        this method is non-variadic, and a `raises` non-variadic trait method
        admits a non-raising implementation (pinned by
        `tests/test_typed_udf_raises_variance.mojo` FACT 1). No existing
        conformer changed."""
        ...

    # ---- no `run_scalar` ----
    #
    # The positional het-pack oracle
    #   `def run_scalar[*Ts: Copyable & Movable](mut self, *vals: *Ts)`
    # is NOT part of this trait. `run_row` above is the ONE oracle; the
    # engine builds `Self.InRow` itself via `row_builder._build_row[R]`
    # and calls it directly.
    #
    # ⛔ DO NOT ADD IT. It would only be needed if the engine could not
    # construct an opaque `Self.InRow` through trait dispatch; comptime
    # reflection over the row's field offsets does that. Keeping
    # both would be a parallel API with two answers to "which one is
    # authoritative", and it actively BLOCKS three things: a `raises`
    # variadic het-pack method CRASHES the 1.0.0 compiler (so fallible
    # UDFs would be impossible while it exists), its
    # `-> Scalar[Self.OutType]` return pins the output to one scalar
    # column, and the row-oriented user surface needs the engine
    # to speak rows.
    #
    # Conformers may still carry a private `run_scalar` helper and have
    # `run_row` delegate to it — an orphaned method on a struct is not a
    # trait member and costs nothing. The trait no longer knows about it,
    # which is the point.


# =============================================================================
# No user-facing SIMD opt-in sub-traits
# =============================================================================
#
# There is no user-facing SIMD opt-in sub-trait (one carrying
# `run_chunk[W, *Ts]`) and no MANUAL-null extension of one on the user
# surface; vectorized conformers are plain MapFn, and MANUAL null handling
# is the internal `_MapFnManualFusedKernel`.
#
# The OPTIONAL SIMD fast-path is exclusively the engine-internal
# `_MapFnFusedKernel` (in `komira_engine_operators._internal.map_fn_fused_kernel`)
# with `@staticmethod eval[W]` / `eval_row` SimdOf-typed signatures.
# End users should write `MapFn` (per-row) or `ExprScalarFn` (Eigen-tree
# SIMD UDF) — both with explicit column flow at call site.
# `_MapFnFusedKernel` is engine-internal scaffolding for chain-fusion
# templates only.
#
# See `komira_engine_operators._internal.map_fn_fused_kernel` for the kernel
# trait body.
# =============================================================================
