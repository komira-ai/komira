# =============================================================================
# LoweredSourceHooks -- consolidated capability-hook payload + applier
# =============================================================================
#
# Per an internal doc Rev 4.2 §4.3 ("hook
# ordering") and §4.2.5.1 ("ExprPool handoff from plan to source is made
# explicit -- apply_source_hooks passes an UnsafePointer[ExprPool] alongside
# List[ExprId]").
#
# Phase 1e.1 revision (ExprPool architectural fix)
# ------------------------------------------------
# Phase 1d.1 held the ExprPool through `ArcPointer[ExprPool]`. That was
# a carryover from the pre-Rev-4 design where the source had to keep
# the pool alive itself. In Rev 4.2 the pool is owned by the PIPELINE
# COMPILER (or the test harness's stack), and it outlives every source,
# every sink, and every worker by construction -- so refcounting is
# pure overhead. We switch to a non-owning raw `UnsafePointer[ExprPool,
# _]` threaded through the hooks and the source trait via the new
# `set_expr_pool` hook. The framework-level invariant (pool outlives
# apply -> next_morsel -> combine) is what makes this sound; concrete
# sources store the pointer with a SAFETY comment documenting the
# invariant.
#
# Why this type exists
# --------------------
# A v0.4 source has ~6 capability setters (`set_projection`,
# `set_decode_filter`, `set_pushed_predicate`, `set_bypass_columns`,
# `set_dict_preservation`, `set_cancel_flag`). The plan compiler previously
# had to know the correct call order; scattering that knowledge across every
# future executor/rewrite-rule was a structural liability. `LoweredSourceHooks`
# is the single place that:
#
#   1. Owns the payload the plan compiler computed (projection column list,
#      filter stage handles, etc.) plus the `ArcPointer[ExprPool]` that
#      `ExprId` handles resolve against.
#   2. Knows the `apply_source_hooks` ordering contract.
#
# Sources that consume hooks at construction time (e.g. `ParquetMorselSource`
# via a future `with_hooks()` overload) are not harmed by the generic applier:
# their `set_*` methods are no-ops in that arrangement, and the applier's
# calls become dead stores that the optimizer removes. The generic path here
# is what makes any future MorselSourceImpl work out-of-the-box.
#
# Not wired up this phase
# -----------------------
# No executor, no sink, no ParquetMorselSource call site imports this file.
# That integration is Phases 1d.2 - 1d.5.
# =============================================================================

# =============================================================================
# CLUSTER-Z TODO: scheduled migration per an internal doc
# =============================================================================
# Each remaining MutExternalOrigin in this file is either (a) a load-bearing
# interior pointer awaiting redesign onto a tight origin, or (b) a temporary
# shim into a primitive that will be removed in Cluster Z (e.g. Slab /
# Slab / Slab / AtomicSlab _mut_ptr / _unsafe_base_ptr helpers
# preserved for migration source callers).
#
# Remediation: replace each wildcard with one of
#   * a typed `ref [origin] T` return / parameter,
#   * a private `UnsafePointer[T, concrete_origin]` field + `# SAFETY:`
#     comment (inside a single struct only),
#   * a byte-view (`ByteView` / `ByteViewMut`) + typed scalar reads/writes.
#
# See an internal doc §5 for canonical API shapes
# and an internal doc §8 for the Cluster Z schedule.
# The baseline at scripts/mut_external_origin_allowlist.txt is
# monotonic-shrinking; do NOT add new wildcard sites to this file.
# =============================================================================

from komira_atomic_alias import AtomicI8

from komira_morsel.dynamic_join_filter import DynamicJoinFilter
from komira_core.traits.expr_id import ExprId
from komira_core.plan.expr_pool import ExprPool
from komira_morsel.morsel_source import MorselSourceImpl, SourceCapabilities


struct LoweredSourceHooks(Copyable, Movable):
    """Lowered, per-source hook payload produced by the plan compiler.

    Empty defaults mean "no hook" for every field -- an empty list for
    projection/decode_filter/bypass_columns, `None` for optional handles
    and the cancel flag, `False` for dict preservation, and no `ExprPool`.
    The builder methods below return a new value with one field filled in;
    prefer those over mutating the struct directly.

    Fields
    ------
    projection: per §4.2.1 `ProjectionSpec` = `List[Int]` (column indices
        into the source's pre-projection schema). Empty = no projection.
    decode_filter: ordered stages of late-materialization filters, each an
        `ExprId` resolvable against `expr_pool`. Empty = no filter stages.
    pushed_predicate: single AND-chained predicate pushed into the source.
        `None` = no predicate pushed.
    bypass_columns: columns that skip the decoder's common path. Empty = no
        bypass.
    dict_preservation: if True, the source preserves Parquet dictionary
        encoding across morsel boundaries (B-1 fast path). False = decode
        normally.
    cancel_flag_ptr: shared `Atomic[int8]` (0 = run, !=0 = cancel). See the
        note in `MorselSourceImpl.set_cancel_flag` on why it is int8 and
        not bool. `None` = source is uncancellable.
    expr_pool: REQUIRED if any `ExprId`-valued field above is set, otherwise
        optional. Non-owning `UnsafePointer[ExprPool]` -- the pool is
        owned by the caller (plan compiler / test harness) whose stack
        frame outlives every `apply_source_hooks` -> `next_morsel` ->
        `combine` cycle. No refcounting; the framework-level lifetime
        invariant is what makes the pointer sound.
    """

    var projection: List[Int]
    var decode_filter: List[ExprId]
    var pushed_predicate: Optional[ExprId]
    var bypass_columns: List[Int]
    var dict_preservation: Bool
    # SAFETY: non-owning pointer to a long-lived Atomic[int8] cancel
    # flag. The hooks payload is a transient staging struct used only
    # inside `apply_source_hooks`; the caller owns the flag on an
    # enclosing stack frame that strictly outlives the hook's lifetime
    # and every next_morsel / combine cycle reachable from it. F4
    #: the trait method `set_cancel_flag` is now
    # origin-parameterized, but `LoweredSourceHooks` is Copyable and a
    # Copyable struct cannot carry per-instance origins on its fields
    # -- this is the one legitimate UnsafePointer private field per
    # safety model §5.1. Public-API narrowing lives at the trait
    # boundary.
    var cancel_flag_ptr: Optional[
        UnsafePointer[AtomicI8, MutUntrackedOrigin]
    ]
    # SAFETY: same rationale as `cancel_flag_ptr`. Non-owning pointer
    # to an ExprPool the caller guarantees outlives every
    # source/sink/worker reachable from the hooks. Phase 1e.1 contract;
    # see module header.
    var expr_pool: Optional[UnsafePointer[ExprPool, MutUntrackedOrigin]]
    # Phase 1g: intra-RG split target rows per sub-morsel (opt #6).
    # 0 = disabled (one morsel per RG, default).
    var morsel_rows: Int
    # Phase 1g: kernel-level readahead hint for the next RG (opt #7).
    # False = disabled (default).
    var prefetch_enabled: Bool
    # Stream AQ: count-only late-mat mode for ungrouped COUNT(*) shapes
    # (CB-02 / CB-03). When True and `decode_filter` is non-empty, the
    # source returns a synthetic zero-column RecordBatch carrying only
    # `num_rows = surviving` — skipping `filter_to_indices` +
    # `gather_batch` + column-level concat. The downstream collect sink
    # and ungrouped-count agg sink both accept `num_columns() == 0`
    # batches. Only safe when the *final* consumer of the batch is a
    # COUNT(*)-only agg sink; the planner must assert this before
    # setting the flag.
    var count_only: Bool

    # Phase 3.6 (bloom-pushdown): dynamic-filter handle.
    # SAFETY: non-owning pointer to a DynamicJoinFilter that the
    # `materialize_parquet_join` driver guarantees outlives every
    # `next_morsel` call reachable from the probe-segment scan via an
    # ArcPointer kept alive on the driver's stack. Same widen-once
    # rationale as `expr_pool` / `cancel_flag_ptr`: `LoweredSourceHooks`
    # is Copyable and cannot parameterize per-instance origins on its
    # fields. v0.3 source: `morsel_join.rs::ColumnarBuildSink::
    # probe_side_filter_stages` (the cross-segment filter handoff).
    var dynamic_filter_ptr: Optional[
        UnsafePointer[DynamicJoinFilter, MutUntrackedOrigin]
    ]
    var dynamic_filter_key_name: String

    # Phase I-A (Wave 9 v4.1.3): decode-fused hash agg cap.
    # Forwarded 1:1 to `SourceCapabilityConfig.hash_agg_key_col_idx` /
    # `SourceCapabilityConfig.hash_agg_agg_col_indices` by
    # `lowered_hooks_to_source_caps` in
    # `komira_parquet/parquet_source.mojo`.
    #
    # When the planner emits a SOURCE_PARQUET → SLAB-FORCED agg pattern
    # (single-Int64-key + agg subset), it sets these fields on the
    # hooks payload. The parquet source's `next_morsel` then takes the
    # decode-fused branch (precompute hash + fingerprint + partition_id
    # over the L1-cached key bytes) instead of the plain decode path.
    #
    # `None` for every non-hash-agg query — the source falls through to
    # `decode_columns_subset`. Setters below handle the wiring.
    var hash_agg_key_col_idx: Optional[Int]
    var hash_agg_agg_col_indices: Optional[List[Int]]

    def __init__(out self):
        """Build an empty hook payload -- every field in its "no hook" state."""
        self.projection = List[Int]()
        self.decode_filter = List[ExprId]()
        self.pushed_predicate = None
        self.bypass_columns = List[Int]()
        self.dict_preservation = False
        self.cancel_flag_ptr = None
        self.expr_pool = None
        self.morsel_rows = 0
        self.prefetch_enabled = False
        self.count_only = False
        self.dynamic_filter_ptr = None
        self.dynamic_filter_key_name = String("")
        self.hash_agg_key_col_idx = None
        self.hash_agg_agg_col_indices = None

    @staticmethod
    def default() -> Self:
        """Convenience constructor equivalent to `LoweredSourceHooks()`."""
        return LoweredSourceHooks()

    # -------------------------------------------------------------------------
    # Mutating setters. `LoweredSourceHooks` is Copyable so chained-builder
    # patterns (`h = h.with_projection(...)`) also work, but calling these
    # directly avoids the copies for the common plan-compiler path that holds
    # a single owned value.
    # -------------------------------------------------------------------------

    def set_projection(mut self, var cols: List[Int]) -> None:
        """Install projection column indices. Empty list = no projection."""
        self.projection = cols^

    def set_decode_filter(mut self, var stages: List[ExprId]) -> None:
        """Install late-materialization filter stages. Requires `expr_pool`."""
        self.decode_filter = stages^

    def set_pushed_predicate(mut self, expr: ExprId) -> None:
        """Install a pushed predicate handle. Requires `expr_pool`."""
        self.pushed_predicate = expr

    def set_bypass_columns(mut self, var cols: List[Int]) -> None:
        """Install bypass columns list. Empty list = no bypass."""
        self.bypass_columns = cols^

    def set_dict_preservation(mut self, on: Bool) -> None:
        """Enable/disable dictionary-encoding preservation."""
        self.dict_preservation = on

    def set_cancel_flag[
        origin: Origin[mut=True]
    ](
        mut self,
        flag: UnsafePointer[AtomicI8, origin],
    ) -> None:
        """Install shared cancel-flag pointer (heap-allocated Atomic[int8]).

        SAFETY: caller-supplied `flag` carries its own concrete origin,
        but `LoweredSourceHooks` is Copyable and cannot parameterize on
        a per-instance origin, so the pointer widens at the
        hook-staging boundary (see field-level SAFETY comment). This
        is the one legitimate UnsafePointer in a private field per
        safety model §5.1. `apply_source_hooks` re-binds the trait
        method's origin parameter when it forwards to the concrete
        source.
        """
        self.cancel_flag_ptr = flag.unsafe_origin_cast[MutUntrackedOrigin]()

    def set_morsel_rows(mut self, rows: Int) -> None:
        """Phase 1g opt #6: configure intra-RG split target row count."""
        self.morsel_rows = rows

    def set_prefetch_enabled(mut self, on: Bool) -> None:
        """Phase 1g opt #7: enable kernel-level readahead hint."""
        self.prefetch_enabled = on

    def set_count_only(mut self, on: Bool) -> None:
        """Stream AQ: enable count-only late-mat. See `count_only` field."""
        self.count_only = on

    def set_dynamic_filter[
        origin: Origin[mut=True]
    ](
        mut self,
        df_ptr: UnsafePointer[DynamicJoinFilter, origin],
        var key_name: String,
    ) -> None:
        """Phase 3.6 (bloom-pushdown): install a dynamic join filter.

        SAFETY: caller-supplied `df_ptr` carries its own concrete
        origin; widens once at the field level for the Copyable struct
        boundary (see field-level SAFETY comment). The pointer must
        outlive every subsequent next_morsel call -- the production
        driver upholds this by holding an ArcPointer[DynamicJoinFilter]
        that owns the underlying T for the probe-segment lifetime.

        `key_name` identifies the probe-side INT64 column to test
        against the build's bloom set.
        """
        self.dynamic_filter_ptr = df_ptr.unsafe_origin_cast[MutUntrackedOrigin]()
        self.dynamic_filter_key_name = key_name^

    def set_hash_agg_decode_fused(
        mut self,
        key_col_idx: Int,
        var agg_col_indices: List[Int],
    ) -> None:
        """Phase I-A: configure the parquet decode-fused hash-agg path.

        After this call, the parquet source's `next_morsel` branches
        into `decode_for_hash_agg(rg, key_col_idx, agg_col_indices, ...)`
        when the v1-gate conditions hold (no pushed predicate, no
        sub-morsel split). The agg sink's `consume()` body reads the
        precomputed hashes / fingerprints / partition_ids from the
        morsel's `hash_agg_decoded` field instead of recomputing
        per-row.

        Caller contract (planner-side):
          * `key_col_idx` is the single Int64 group-by key column index
            in the source's pre-projection schema (the planner has
            already verified the SLAB-FORCED single-Int64-key shape).
          * `agg_col_indices` lists the agg-input column indices the
            sink will consume. Order is preserved through to the
            morsel's `agg_input_columns` field.
        """
        self.hash_agg_key_col_idx = Optional(key_col_idx)
        self.hash_agg_agg_col_indices = Optional(agg_col_indices^)

    def set_expr_pool[
        origin: Origin[mut=True]
    ](
        mut self,
        pool: UnsafePointer[ExprPool, origin],
    ) -> None:
        """Install a non-owning ExprPool pointer for ExprId resolution.

        SAFETY: `pool` must outlive every subsequent hook application,
        `next_morsel` call, and sink `combine()` reachable from this
        hooks payload. See module header; framework-level lifetime
        guarantees this in the production path (plan compiler owns the
        pool) and tests carry their own stack-allocated ExprPool. The
        origin parameter lets callers pass a tight-origin pointer
        directly -- no wildcard cast at the call site. The hook field
        widens once here (Copyable struct constraint; see field-level
        SAFETY comment).
        """
        self.expr_pool = pool.unsafe_origin_cast[MutUntrackedOrigin]()


# =============================================================================
# apply_source_hooks
# =============================================================================


def apply_source_hooks[
    S: MorselSourceImpl
](mut source: S, hooks: LoweredSourceHooks) -> None:
    """Drive `source`'s capability setters in the order documented in
    §4.3 "Hook ordering".

    Ordering rationale (normative in §4.3):

      0. `set_expr_pool` FIRST when present -- every ExprId-valued hook
         below resolves against the pool; setters may choose to pre-resolve
         handles at hook time rather than defer to next_morsel, so the
         pointer must be in place before any such setter runs.
      1. `set_cancel_flag` -- downstream setters may spawn threads
         that must see the flag immediately if a race happens.
      2. `set_projection` -- changes the source's effective schema, which
         everything below may depend on.
      3. `set_bypass_columns` -- refines the projected schema's decode
         strategy without changing it.
      4. `set_pushed_predicate` -- runs *before* `set_decode_filter` because
         pushed predicates may reduce the rows that reach late-mat stages.
      5. `set_dict_preservation` -- pure flag; order relative to #1-4 is
         irrelevant but we fix it for determinism.
      6. `set_decode_filter` last -- it references the pool-resolved handles
         and assumes projection / bypass / predicate have already been
         installed.

    Generic-over-S so every `MorselSourceImpl` benefits, including future
    CSV / NDJSON / Arrow IPC sources. For sources whose `set_*` methods are
    no-ops (e.g. `ParquetMorselSource` which will consume hooks at
    construction via a future `with_hooks()` call), the dead stores
    vaporize under Mojo's monomorphization + LLVM DCE.

    Phase 2.2 — hook consumption mode
    -----------------------------------------------
    Sources that advertise `HOOKS_CONSUMED_AT_CONSTRUCTION = True`
    (e.g. `ParquetMultiConsumerSource_Single` / `_Known`) consumed
    their `SourceCapabilityConfig` bundle at __init__ time. For those
    sources the engine callsite is responsible for converting
    `LoweredSourceHooks` to the bundle BEFORE source construction (via
    `lowered_hooks_to_source_caps` below) — at this driver site the
    apply call is a no-op. The `@parameter if` selects exactly one arm
    at monomorphization, so the legacy ordering loop below is dead
    code for the new sources.

    Args:
        source: The source being configured. Mutated in place.
        hooks: The payload to install. Borrowed; not consumed.
    """
    # Phase 2.2 — short-circuit for sources that consumed
    # their capability bundle at construction time. The compile-time
    # alias is set to True on `ParquetMultiConsumerSource_Single` /
    # `_Known` (Phase 2.1); the legacy `ParquetMorselSource` and every
    # Mock / BatchSource impl inherits the trait default of False and
    # falls through to the setter loop below.
    comptime if S.HOOKS_CONSUMED_AT_CONSTRUCTION:
        # Caller built `SourceCapabilityConfig` from `hooks` before
        # construction. The setter loop below would either be redundant
        # (mutating `_caps` after the fact has no downstream effect for
        # these sources, since `next_morsel` already captured the
        # construction-time view) or wrong-shape (the 3 banned-pointer-
        # payload setters are deliberately not overridden). Borrow `hooks` to keep the parameter live
        # for the no-op arm.
        _ = hooks.morsel_rows  # keepalive; setter-loop arm is dead.
        return

    # 0. ExprPool pointer (Phase 1e.1): set before any ExprId-resolving
    #    setter below so the source can choose to pre-resolve handles
    #    inside set_pushed_predicate / set_decode_filter.
    # F4: the trait method is origin-parameterized; at this bridge we
    # pass the wildcard-origin pointer stored on the hooks struct and
    # let the compiler bind the trait method's `origin` parameter to
    # the hook field's origin. Downstream concrete-source impls that
    # stash the pointer stay wildcard-typed in their field
    # (SAFETY-commented, per §5.1) but the trait method signature no
    # longer advertises a wildcard as public API.
    if hooks.expr_pool:
        source.set_expr_pool(hooks.expr_pool.value())

    # 1. Cancel flag (same origin-binding rationale as step 0).
    if hooks.cancel_flag_ptr:
        source.set_cancel_flag(hooks.cancel_flag_ptr.value())

    # 2. Projection (skip the call entirely when empty -- keeps mock sources
    # that never override the default from having to treat an empty list
    # specially).
    if len(hooks.projection) > 0:
        source.set_projection(hooks.projection)

    # 3. Bypass columns
    if len(hooks.bypass_columns) > 0:
        source.set_bypass_columns(hooks.bypass_columns)

    # 4. Pushed predicate
    if hooks.pushed_predicate:
        source.set_pushed_predicate(hooks.pushed_predicate.value())

    # 5. Dict preservation -- always forward the flag; the default impl is
    # a no-op in `MorselSourceImpl` and the value is scalar.
    source.set_dict_preservation(hooks.dict_preservation)

    # 6. Decode filter. `expr_pool` MUST be set if the stage list is
    # non-empty -- Phase 1e.1 wires the pool handoff via step 0 above,
    # so concrete sources have the pointer stashed by the time this
    # forwards the stages.
    if len(hooks.decode_filter) > 0:
        source.set_decode_filter(hooks.decode_filter)

    # 7. Phase 1g: intra-RG split + prefetch. Order relative to #1-6 is
    # irrelevant (both are pure source-local tuning knobs that do not
    # interact with ExprPool or projection), so we fix them last for
    # determinism. Non-default values only -- trait defaults are no-ops
    # for sources that don't implement these knobs.
    if hooks.morsel_rows > 0:
        source.set_morsel_rows(hooks.morsel_rows)
    if hooks.prefetch_enabled:
        source.set_prefetch_enabled(True)

    # 8. Stream AQ count-only late-mat (CB-02/CB-03). Strictly scoped:
    # planner sets it only when the segment is Parquet -> [Filter] ->
    # SINK_AGG with num_keys==0 and every agg is COUNT(*)-no-child.
    if hooks.count_only:
        source.set_count_only(True)

    # 9. Phase 3.6 (bloom-pushdown): install the dynamic join filter.
    # Order: AFTER set_decode_filter so the source has a stable
    # filter-stage list before the bloom mask is added on top. Sources
    # that don't support pushdown ignore the call (default no-op).
    if hooks.dynamic_filter_ptr:
        source.set_dynamic_filter(
            hooks.dynamic_filter_ptr.value(),
            hooks.dynamic_filter_key_name,
        )
