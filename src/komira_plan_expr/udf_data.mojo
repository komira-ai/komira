# =============================================================================
# udf_data.mojo — the type-erased UDF payload that rides on LogicalPlan nodes
# =============================================================================
#
# When the SDK's `df.map[F: MapFn](f)` / `.filter[F:
# FilterFn](f)` / `.agg[F: AggFn](f)` is called, the call site emits a
# `UdfData` snapshot into the `LogicalPlan` (a `ProjectData.udf` /
# `FilterData.udf` / `AggregateData.udf_aggs[i]`). The payload is fully
# TYPE-ERASED: it carries only what the optimizer + plan-CSE walker + the
# operator-build driver need WITHOUT having `F` in hand:
#
#   - the human-readable name (EXPLAIN / error messages),
#   - the input-column projection map (name + dtype tag, in order) so
#     materialize-time can resolve `F.InputSchema` against the child schema
#     and error early on a mismatch,
#   - the output column(s) (name + dtype tag),
#   - the null-handling / volatility / parallelism TAGS (the strongly-typed
#     `NullHandling` / `FunctionStability` / `StatefulContract` types live on
#     `F` in `komira_eval`; the IR only needs the `UInt8` tag for optimizer
#     reasoning — a `comptime KeyList` cannot live on a runtime field, so
#     the IR carries a RUNTIME `partition_keys` / `order_keys` snapshot the
#     plan compiler emits at SDK-call-site time, NOT the comptime view),
#   - `has_vector_path` — whether `F` conforms to a fused-kernel sub-trait (the SDK
#     stamps this so the operator-build driver / EXPLAIN can see it),
#   - `is_restartable` — computed `= (parallelism_tag == stateless)`; the
#     marker the FUTURE spill/retry machinery reads to know which morsels it
#     may speculatively re-execute,
#   - `operator_factory_id: UInt32` — the conformer's user-declared
#     `comptime UDF_ID`. The operator-build driver matches it against the
#     comptime UDF pack threaded down from the SDK call site to re-monomorphize
#     `MapFnOp[F_k]` / `FilterFnOp[F_k]` / `AggFnAcc[F_k]`. ALSO folded into
#     the plan `structural_hash` so plan-CSE never shares two distinct
#     UDF nodes — even of the same `F` at two different SDK call sites
#     (disambiguated by `call_site_salt`).
#   - `call_site_salt: UInt32` — a per-SDK-call-site value the SDK assigns
#     from a monotonic counter. Two `df.map(SameFn())` calls in the same
#     query get the SAME `operator_factory_id` (it's `SameFn.UDF_ID`) but
#     DIFFERENT `call_site_salt`s, so their `structural_hash`es differ and
#     plan-CSE keeps them separate (a UDF conformer may carry mutable state;
#     sharing execution across two call sites is wrong even when the type is
#     identical — there is no plan-level CSE for UDFs).
#
# This struct lives in `komira_core/plan/` (the leaf pkg) and stores only
# `String` / `List` / `UInt8` / `UInt32` / `Bool` — no dependency on
# `komira_eval`'s typed `NullHandling` / `StatefulContract` (which would be
# a layering inversion: `komira_eval -> komira_core`, not the reverse). The
# `.tag` snapshot is the only thing the IR needs.
#
# Mojo discipline: zero `UnsafePointer` anywhere (the struct is plain
# value-and-`List` fields); `Movable` + `Copyable` (the fields are all
# `Copyable` — `String`, `List[Tuple[String, UInt8]]`, `List[String]`,
# `UInt8`, `UInt32`, `Bool` — so the compiler synthesizes `__copyinit__`,
# but we also provide an explicit `.copy()` mirroring the other `*Data`
# structs for symmetry with `LogicalPlan.copy()`'s deep-clone path).
# =============================================================================


from komira_arrow.arrow_types import ArrowType


# =============================================================================
# Dtype tags — mirror of `komira_eval/schema_descriptor.mojo:DT_*`
# =============================================================================
#
# `UdfData.input_columns` / `.output_columns` store these as the column dtype
# (snapshotted from `F.InputSchema` / `F.OutputSchema`'s `ColDescriptor.dtype`,
# which is itself one of `komira_eval`'s `DT_*` Int constants). They live here
# AS WELL (not just in `komira_eval`) because `komira_core` is the leaf pkg
# and cannot import `komira_eval` (`komira_eval -> komira_core`, not the
# reverse) — same documented-sync-mirror discipline as `UDF_NULL_*` above /
# below. Numeric values are kept in lockstep with
# `komira_eval/schema_descriptor.mojo`.

comptime DTAG_UNKNOWN: UInt8 = 255  # = DT_UNKNOWN (-1 there; 255 here since we store UInt8)
comptime DTAG_I8: UInt8 = 0
comptime DTAG_I16: UInt8 = 1
comptime DTAG_I32: UInt8 = 2
comptime DTAG_I64: UInt8 = 3
comptime DTAG_U8: UInt8 = 4
comptime DTAG_U16: UInt8 = 5
comptime DTAG_U32: UInt8 = 6
comptime DTAG_U64: UInt8 = 7
comptime DTAG_F32: UInt8 = 8
comptime DTAG_F64: UInt8 = 9
comptime DTAG_BOOL: UInt8 = 10
comptime DTAG_STRING: UInt8 = 11
comptime DTAG_DATE32: UInt8 = 12
comptime DTAG_DATE64: UInt8 = 13
comptime DTAG_TIMESTAMP: UInt8 = 14


def arrow_type_of_dtag(t: UInt8) -> ArrowType:
    """Map a `DTAG_*` dtype tag to the corresponding `ArrowType`.

    Mirrors `komira_eval/schema_descriptor.mojo:dtag_to_arrow_type_id` (that
    one returns the bare `type_id`; this one returns the `ArrowType` value
    directly — what `LogicalPlan.aggregate`'s schema builder needs). DATE32 /
    DATE64 / TIMESTAMP are physical-typed as INT32 / INT64 / INT64 (matches
    the existing `dtag_to_arrow_type_id` behavior — the engine has no dedicated
    date/timestamp Arrow types yet). An unknown tag maps to INT64 (defensive
    default — the operator-build-time `comptime assert` against `F.OutputSchema`
    is the real correctness gate)."""
    if t == DTAG_I8:
        return ArrowType.INT8
    if t == DTAG_I16:
        return ArrowType.INT16
    if t == DTAG_I32:
        return ArrowType.INT32
    if t == DTAG_I64:
        return ArrowType.INT64
    if t == DTAG_U8:
        return ArrowType.UINT8
    if t == DTAG_U16:
        return ArrowType.UINT16
    if t == DTAG_U32:
        return ArrowType.UINT32
    if t == DTAG_U64:
        return ArrowType.UINT64
    if t == DTAG_F32:
        return ArrowType.FLOAT32
    if t == DTAG_F64:
        return ArrowType.FLOAT64
    if t == DTAG_BOOL:
        return ArrowType.BOOL
    if t == DTAG_STRING:
        return ArrowType.STRING
    if t == DTAG_DATE32:
        return ArrowType.INT32
    if t == DTAG_DATE64:
        return ArrowType.INT64
    if t == DTAG_TIMESTAMP:
        return ArrowType.INT64
    return ArrowType.INT64


# =============================================================================
# UDF kind tags — discriminates which trait family `F` conforms to
# =============================================================================
#
# Mirrors the three operator forks in `plan_compiler` (PLAN_PROJECT ->
# MapFnOp, PLAN_FILTER -> FilterFnOp, PLAN_AGGREGATE -> AggFnAcc).

comptime UDF_KIND_MAP: UInt8 = 0       # MapFn — N input cols -> 1 output col (project / with_column)
comptime UDF_KIND_FILTER: UInt8 = 1    # FilterFn — N input cols -> Bool (filter predicate)
comptime UDF_KIND_AGG: UInt8 = 2       # AggFn — N input cols -> 1 aggregated output col


# =============================================================================
# Null-handling tags — snapshot of `komira_eval.NullHandling._tag`
# =============================================================================
#
# Kept in numeric sync with `komira_eval/udf_descriptor.mojo:NullHandling`.

comptime UDF_NULL_MANUAL: UInt8 = 0
comptime UDF_NULL_PROPAGATE: UInt8 = 1
comptime UDF_NULL_SKIP_NULL_FAST_PATH: UInt8 = 2


# =============================================================================
# Volatility tags — snapshot of `komira_eval.FunctionStability._tag`
# =============================================================================
#
# Kept in numeric sync with `komira_eval/udf_descriptor.mojo:FunctionStability`.

comptime UDF_STABILITY_IMMUTABLE: UInt8 = 0
comptime UDF_STABILITY_STABLE: UInt8 = 1
comptime UDF_STABILITY_VOLATILE: UInt8 = 2


# =============================================================================
# Parallelism (stateful-contract) tags — snapshot of
# `komira_eval.StatefulContract.tag`
# =============================================================================
#
# Kept in numeric sync with `komira_eval/stateful_contract.mojo:StatefulContract`.
#   stateless      = the common case (default): freely parallel, freely
#                    retryable/spillable (`is_restartable = True`).
#   serial_ordered = the stateful-with-row-order case: the operator must
#                    see rows in order (not retryable across morsels).
#   mergeable      = stateful but the partial states merge (an `AggFn` is
#                    intrinsically mergeable; this tag is for the rare
#                    mergeable-`MapFn` case).
#   partition_local = the window-fn-ish case: state is per-partition; shares
#                    the partition-sort machinery.

comptime UDF_PAR_STATELESS: UInt8 = 0
comptime UDF_PAR_SERIAL_ORDERED: UInt8 = 1
comptime UDF_PAR_MERGEABLE: UInt8 = 2
comptime UDF_PAR_PARTITION_LOCAL: UInt8 = 3


# FNV-1a 64-bit constants (mirrors the values in `logical_plan.mojo` /
# `logical_plan_variants.mojo`).
comptime _FNV1A_OFFSET: UInt64 = 14695981039346656037
comptime _FNV1A_PRIME: UInt64 = 1099511628211


@always_inline
def _fnv_mix_bytes(mut h: UInt64, s: String):
    """Fold a String's bytes into `h` (FNV-1a). No `UnsafePointer` —
    walks via `as_bytes()`."""
    var b = s.as_bytes()
    for i in range(len(b)):
        h = (h ^ UInt64(b[i])) * _FNV1A_PRIME


@always_inline
def _fnv_mix_u64(mut h: UInt64, v: UInt64):
    h = (h ^ v) * _FNV1A_PRIME


# =============================================================================
# UdfData — the type-erased UDF payload struct
# =============================================================================

struct UdfData(Movable, Copyable, Deinitable, Writable):
    """Type-erased snapshot of a typed UDF, riding on a `LogicalPlan` node.

    See the module docstring for the field-by-field rationale. This struct is
    deliberately `F`-free: the optimizer + plan-CSE walker only see this; the
    operator-build driver re-recovers `F` by matching `operator_factory_id`
    against the comptime UDF pack threaded down from the SDK call site.

    Fields:
        kind: `UDF_KIND_{MAP,FILTER,AGG}` — which trait family `F` conforms
            to (also redundantly implied by which `LogicalPlan` node carries
            this — a `ProjectData.udf` is always `UDF_KIND_MAP` etc. — but
            stamped explicitly for EXPLAIN / sanity-assert).
        name: human-readable UDF name (EXPLAIN output, error messages).
        input_columns: the input projection map — `(column_name, dtype_tag)`
            in `F.InputSchema` order. Materialize-time resolves these against
            the child node's output schema (name lookup + dtype check) and
            errors early on a mismatch. The `dtype_tag` is the `DT_*` tag from
            `komira_eval/schema_descriptor.mojo` (snapshotted as a `UInt8`).
        output_columns: `(column_name, dtype_tag)` for the output column(s).
            A single output for MAP / AGG; FILTER is always Bool so its
            `output_columns` is `[("<name>_pred", DT_BOOL)]` (the engine
            ignores it for the filter path but keeps it for EXPLAIN
            uniformity).
        null_mode: `UDF_NULL_{MANUAL,PROPAGATE,SKIP_NULL_FAST_PATH}` —
            snapshot of `F.null_mode._tag`.
        stability: `UDF_STABILITY_{IMMUTABLE,STABLE,VOLATILE}` — snapshot of
            `F`'s volatility (the SDK derives it; defaults to IMMUTABLE for a
            pure `MapFn` / `FilterFn`, STABLE/VOLATILE for stateful UDFs).
        parallelism_tag: `UDF_PAR_{STATELESS,SERIAL_ORDERED,MERGEABLE,
            PARTITION_LOCAL}` — snapshot of `F.parallelism.tag`.
        partition_keys: the RUNTIME snapshot of `F.parallelism.partition_keys`
            (the comptime `KeyList` can't live on a runtime field). Column
            names the partition-local / serial-ordered operator partitions
            on. Empty for `stateless` / `mergeable`. The optimizer reads this
            without needing `F` (e.g. to reason about whether a partitioning
            rewrite is safe).
        order_keys: the RUNTIME snapshot of `F.parallelism.order_keys`.
            Column names the serial-ordered / partition-local operator
            requires the rows sorted by. Empty for `stateless` / `mergeable`.
        has_vector_path: whether `F` conforms to the engine-internal SIMD
            fast-path sub-trait (the SDK stamps `conforms_to(F,
            _MapFnFusedKernel)` / `conforms_to(F, _AggFnFusedKernel)` /
            `conforms_to(F, _FilterFnFusedKernel)`). Lets the operator-build
            driver / EXPLAIN see the SIMD-fast-path availability without
            instantiating the operator. The stamping reads the
            engine-internal fused-kernel sub-traits.
        is_restartable: `= (parallelism_tag == UDF_PAR_STATELESS)`. The
            marker for the future spill / fault-tolerance / adaptive-re-execution
            machinery: a stateless-UDF stage's morsels may be speculatively
            re-executed; a stateful one's may not. Computed by the constructor
            (not separately settable) so it can never disagree with
            `parallelism_tag`.
        operator_factory_id: `F.UDF_ID`. The operator-build driver
            matches this against the comptime UDF pack to re-monomorphize the
            right operator. Folded into `structural_hash`.
        call_site_salt: a per-SDK-call-site value (SDK monotonic counter). Two
            calls of the same `F` get the same `operator_factory_id` but
            different `call_site_salt`s -> different `structural_hash`es ->
            plan-CSE keeps them separate (a UDF may carry mutable state;
            sharing execution across call sites is wrong). Folded into
            `structural_hash`.
    """

    var kind: UInt8
    var name: String
    var input_columns: List[Tuple[String, UInt8]]
    var output_columns: List[Tuple[String, UInt8]]
    var null_mode: UInt8
    var stability: UInt8
    var parallelism_tag: UInt8
    var partition_keys: List[String]
    var order_keys: List[String]
    var has_vector_path: Bool
    var is_restartable: Bool
    var operator_factory_id: UInt32
    var call_site_salt: UInt32
    var registered_handle_id: Optional[Int]
    """The `UdfRegistry` handle for the INSTANCE this node calls, or None.

    ★★★ THIS IS AN `Int`, NOT A `UInt32`, AND THE FOUR EXTRA BYTES ARE
    LOAD-BEARING TWICE OVER. It carries `UdfRegistry`'s packed handle — **31 slot
    bits + 32 generation bits** (`komira_engine_operators.udf_registry`)
    — not a bare slot index. A bare slot index is ABA by construction, and
    it has TWO distinct victims here:

      1. **RESOLUTION.** register A -> node holds slot 3 -> A evicted ->
         B takes slot 3 -> the node SILENTLY EXECUTES B. Closed by the
         registry's generation check (`UDF_REGISTRY_HANDLE_EVICTED`).

      2. ★ **THE PLAN-COMPILE CACHE KEY**, which is the one you cannot see by
         reading the registry. `LogicalPlan.structural_hash` is a hash OF THE
         RENDER — "⚠⚠ THE RENDER IS THE HASH. THERE IS NO SECOND SOURCE OF
         IDENTITY" (`logical_plan.mojo`) — and `write_to` below renders this
         field. With a bare slot, the plan for A and the plan for B render
         `registered_handle_id=3` IDENTICALLY, so the cache hands back A's
         COMPILED PLAN for a query that now means B. That is a silent wrong
         answer, and it is the FOURTH instance of the render-is-the-hash class
         `logical_plan.structural_hash` already lists three of.

    ⚠ AND THIS IS WHY THE FIELD IS RENDERED AT ALL, WHICH LOOKS WRONG AT FIRST.
    A handle is PROCESS-LOCAL, so rendering it makes the same logical plan hash
    differently in two processes, or after a re-mint. That costs plan-compile
    cache MISSES. Not rendering it costs a false HIT — two distinct UDFs with
    the same name, columns and `call_site_salt` colliding. A miss is a
    performance bug; a hit is a wrong answer. **Render it.**

    ⛔ AND DO NOT REACH FOR `operator_factory_id` AS THE DISCRIMINATOR INSTEAD.
    It is not an identity: `UInt32(9301)` is declared by FIVE distinct
    conformers, and the `Map1`/`Map2` sugar derives its id from the COLUMN
    NAMES, so `Map1[f=twice, out_name="y", in0="a"]` and `Map1[f=thrice, ...]`
    both derive `1635047856`. It cannot be fixed by a better hash — the two
    functions have the same Mojo type.

    ⚠ IT IS NOT FOLDED INTO `UdfData.structural_hash` (the numeric one), only
    into the TEXT hash via `write_to`. That asymmetry is deliberate and it is
    why both are documented here: the numeric hash answers "are these the same
    UDF DESCRIPTION", the text hash answers "is this the same COMPILED PLAN".
    """

    def __init__(
        out self,
        kind: UInt8,
        var name: String,
        var input_columns: List[Tuple[String, UInt8]],
        var output_columns: List[Tuple[String, UInt8]],
        operator_factory_id: UInt32,
        call_site_salt: UInt32,
        null_mode: UInt8 = UDF_NULL_PROPAGATE,
        stability: UInt8 = UDF_STABILITY_IMMUTABLE,
        parallelism_tag: UInt8 = UDF_PAR_STATELESS,
        var partition_keys: List[String] = List[String](),
        var order_keys: List[String] = List[String](),
        has_vector_path: Bool = False,
        registered_handle_id: Optional[Int] = None,
    ):
        """Construct a `UdfData` snapshot. `is_restartable` is derived from
        `parallelism_tag` so the two can never disagree.

        Args:
            kind: `UDF_KIND_{MAP,FILTER,AGG}`.
            name: Human-readable UDF name.
            input_columns: `(col_name, dtype_tag)` in `F.InputSchema` order.
            output_columns: `(col_name, dtype_tag)` for the output column(s).
            operator_factory_id: `F.UDF_ID`.
            call_site_salt: Per-SDK-call-site monotonic counter value.
            null_mode: `UDF_NULL_*` (default PROPAGATE — matches
                `MapFn.null_mode`'s default).
            stability: `UDF_STABILITY_*` (default IMMUTABLE).
            parallelism_tag: `UDF_PAR_*` (default STATELESS — matches
                `MapFn.parallelism`'s default).
            partition_keys: Runtime snapshot of `F.parallelism.partition_keys`.
            order_keys: Runtime snapshot of `F.parallelism.order_keys`.
            has_vector_path: Whether `F` conforms to `*Vectorized`.
        """
        self.kind = kind
        self.name = name^
        self.input_columns = input_columns^
        self.output_columns = output_columns^
        self.null_mode = null_mode
        self.stability = stability
        self.parallelism_tag = parallelism_tag
        self.partition_keys = partition_keys^
        self.order_keys = order_keys^
        self.has_vector_path = has_vector_path
        self.is_restartable = parallelism_tag == UDF_PAR_STATELESS
        self.operator_factory_id = operator_factory_id
        self.call_site_salt = call_site_salt
        self.registered_handle_id = registered_handle_id

    def copy(self) -> Self:
        """Deep-clone the `UdfData` (all fields are `Copyable`; explicit
        `.copy()` mirrors the other `*Data` structs for `LogicalPlan.copy()`
        symmetry)."""
        var ic = List[Tuple[String, UInt8]]()
        for i in range(len(self.input_columns)):
            ic.append((self.input_columns[i][0], self.input_columns[i][1]))
        var oc = List[Tuple[String, UInt8]]()
        for i in range(len(self.output_columns)):
            oc.append((self.output_columns[i][0], self.output_columns[i][1]))
        var pk = List[String]()
        for i in range(len(self.partition_keys)):
            pk.append(self.partition_keys[i])
        var ok = List[String]()
        for i in range(len(self.order_keys)):
            ok.append(self.order_keys[i])
        var rh_copy: Optional[Int] = None
        if self.registered_handle_id:
            rh_copy = Optional(self.registered_handle_id.value())
        return Self(
            kind=self.kind,
            name=self.name,
            input_columns=ic^,
            output_columns=oc^,
            operator_factory_id=self.operator_factory_id,
            call_site_salt=self.call_site_salt,
            null_mode=self.null_mode,
            stability=self.stability,
            parallelism_tag=self.parallelism_tag,
            partition_keys=pk^,
            order_keys=ok^,
            has_vector_path=self.has_vector_path,
            registered_handle_id=rh_copy,
        )

    @always_inline
    def is_map(self) -> Bool:
        return self.kind == UDF_KIND_MAP

    @always_inline
    def is_filter(self) -> Bool:
        return self.kind == UDF_KIND_FILTER

    @always_inline
    def is_agg(self) -> Bool:
        return self.kind == UDF_KIND_AGG

    @always_inline
    def is_stateless(self) -> Bool:
        return self.parallelism_tag == UDF_PAR_STATELESS

    @always_inline
    def is_describable(self) -> Bool:
        """Can a PEER re-mint this UDF from what the plan carries?

        ★ DERIVED, NEVER ASSERTED — a producer cannot flag its live closure as
        describable, for the same reason `MorselOp.project_reorders_only` is
        derived: the property is a fact about the node, so deriving it covers
        whichever site emits the next one. A UDF registered under a stable
        `name` that both processes' registries know is describable; one minted
        from a LIVE CLOSURE has no such name.

        ★ THIS IS THE WIRE TIER, AND THE TIERING IS ESTABLISHED PRECEDENT, NOT
        A NEW DECISION. `InMemorySource` — live heap data inside the IR — is
        already REFUSED at the wire (`PLAN_WIRE_UNSUPPORTED_SOURCE_IN_MEMORY`)
        while remaining fully usable in-process. A live closure is live CODE
        inside the IR: the same shape, the same answer.

        ⛔ THE HANDLE ITSELF MUST NEVER CROSS THE WIRE, describable or not. It
        is a process-local slot+generation. What crosses is the DESCRIPTION;
        the far side re-mints its OWN handle by resolving that description
        against ITS OWN registry — which is the `ScanBinding` rule, and is
        exactly what `plan_wire_codec.mojo`'s own ledger already names as the
        answer for UDFs."""
        return self.name.byte_length() > 0

    @always_inline
    def has_registered_handle(self) -> Bool:
        """True when this UdfData has been
        post-registered with a EngineContext FusedChainHandle id.
        Mirrors the variant-side `has_udf_chain()` helper."""
        return Bool(self.registered_handle_id)

    def structural_hash(self) -> UInt64:
        """FNV-1a fold of this UDF's identity for the plan structural hash.

        MUST distinguish two separate SDK call sites even of the same
        `F`: `operator_factory_id` AND `call_site_salt` are both folded in.
        Two `df.map(SameFn())` calls -> same `operator_factory_id` but
        different `call_site_salt`s -> different hashes -> plan-CSE never
        shares them. Also folds `kind` / `name` / the column maps / the
        mode+stability+parallelism tags / `partition_keys` / `order_keys` /
        `has_vector_path` so a hand-built plan that references a structurally
        identical UDF (same id+salt) hashes identically (factory-cache
        stability) — though in practice the `(id, salt)` pair is already a
        unique key, the rest is folded for defense-in-depth.

        Called from `ProjectData.structural_hash` / `FilterData.structural_hash`
        / `AggregateData.structural_hash` (the `*Data` structs mix this into
        their own hash; `LogicalPlan.structural_hash` is text-based and picks
        it up via `write_to`'s rendering of the UDF — see `plan_display.mojo`).
        """
        var h = _FNV1A_OFFSET
        _fnv_mix_u64(h, UInt64(self.kind))
        _fnv_mix_bytes(h, self.name)
        for i in range(len(self.input_columns)):
            _fnv_mix_bytes(h, self.input_columns[i][0])
            _fnv_mix_u64(h, UInt64(self.input_columns[i][1]))
        for i in range(len(self.output_columns)):
            _fnv_mix_bytes(h, self.output_columns[i][0])
            _fnv_mix_u64(h, UInt64(self.output_columns[i][1]))
        _fnv_mix_u64(h, UInt64(self.null_mode))
        _fnv_mix_u64(h, UInt64(self.stability))
        _fnv_mix_u64(h, UInt64(self.parallelism_tag))
        for i in range(len(self.partition_keys)):
            _fnv_mix_bytes(h, self.partition_keys[i])
        for i in range(len(self.order_keys)):
            _fnv_mix_bytes(h, self.order_keys[i])
        _fnv_mix_u64(h, UInt64(1) if self.has_vector_path else UInt64(0))
        _fnv_mix_u64(h, UInt64(self.operator_factory_id))
        _fnv_mix_u64(h, UInt64(self.call_site_salt))
        return h

    def write_to[W: Writer](self, mut writer: W):
        """Compact one-line render for EXPLAIN / `LogicalPlan.write_to`.

        Shape: `udf<MAP> "name" in=[a:i64,b:f64] out=[r:f64] null=PROPAGATE
        par=stateless id=7 salt=1` (vector path appended as `vec` when set;
        partition/order keys appended as `part=[...]`/`order=[...]` when
        non-empty). The text feeds `LogicalPlan.structural_hash` (which is
        text-based) so it implicitly captures the same axes as
        `structural_hash` above.
        """
        writer.write("udf<")
        if self.kind == UDF_KIND_MAP:
            writer.write("MAP")
        elif self.kind == UDF_KIND_FILTER:
            writer.write("FILTER")
        elif self.kind == UDF_KIND_AGG:
            writer.write("AGG")
        else:
            writer.write("?")
        writer.write('> "')
        writer.write(self.name)
        writer.write('" in=[')
        for i in range(len(self.input_columns)):
            if i > 0:
                writer.write(",")
            writer.write(self.input_columns[i][0])
            writer.write(":")
            writer.write(self.input_columns[i][1])
        writer.write("] out=[")
        for i in range(len(self.output_columns)):
            if i > 0:
                writer.write(",")
            writer.write(self.output_columns[i][0])
            writer.write(":")
            writer.write(self.output_columns[i][1])
        writer.write("] null=")
        if self.null_mode == UDF_NULL_MANUAL:
            writer.write("MANUAL")
        elif self.null_mode == UDF_NULL_PROPAGATE:
            writer.write("PROPAGATE")
        elif self.null_mode == UDF_NULL_SKIP_NULL_FAST_PATH:
            writer.write("SKIP_NULL")
        else:
            writer.write("?")
        writer.write(" par=")
        if self.parallelism_tag == UDF_PAR_STATELESS:
            writer.write("stateless")
        elif self.parallelism_tag == UDF_PAR_SERIAL_ORDERED:
            writer.write("serial_ordered")
        elif self.parallelism_tag == UDF_PAR_MERGEABLE:
            writer.write("mergeable")
        elif self.parallelism_tag == UDF_PAR_PARTITION_LOCAL:
            writer.write("partition_local")
        else:
            writer.write("?")
        if len(self.partition_keys) > 0:
            writer.write(" part=[")
            for i in range(len(self.partition_keys)):
                if i > 0:
                    writer.write(",")
                writer.write(self.partition_keys[i])
            writer.write("]")
        if len(self.order_keys) > 0:
            writer.write(" order=[")
            for i in range(len(self.order_keys)):
                if i > 0:
                    writer.write(",")
                writer.write(self.order_keys[i])
            writer.write("]")
        if self.has_vector_path:
            writer.write(" vec")
        writer.write(" id=")
        writer.write(self.operator_factory_id)
        writer.write(" salt=")
        writer.write(self.call_site_salt)
        # Render the post-register
        # FusedChainHandle id when populated. Suppressed when None so a plan
        # with no registered chain renders without it.
        if self.registered_handle_id:
            writer.write(" registered_handle_id=")
            writer.write(self.registered_handle_id.value())
