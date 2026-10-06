# =============================================================================
# MorselSourceImpl -- Rev 4.1 trait for source extensibility
# =============================================================================
#
# Per an internal doc §4.2.1. The primary
# extensibility mechanism in v0.4 is Mojo traits + `@parameter` generics:
# source types are chosen at the USER's AOT compile time, plumbed through
# DataFrame[S] as a type parameter, and monomorphized into a concrete
# executor by the Mojo compiler.
#
# There is NO vtable, NO bitcast, NO UnsafePointer in the user-facing path.
# Dispatch cost is zero -- every call is a direct, inlinable function call
# after monomorphization. Rev 3.4's MorselSourceVTable / MorselSource /
# wrap[T] apparatus has been pruned in favor of this trait.
#
# Verified pattern: an internal doc
# Mojo supports trait default methods with non-None return types
# (verified via an out-of-tree probe), so every capability hook
# below ships with a trait-level no-op default. Concrete sources override
# only the hooks they advertise through `capabilities()`.
# =============================================================================

# =============================================================================
# CLUSTER-Z STATUS: FULLY MIGRATED.
# =============================================================================
# No runtime wildcard-origin sites remain. (Historical-note mentions of the old
# wildcard type preserved in inline code comments for archaeology.)
# =============================================================================

from komira_atomic_alias import AtomicI8

from komira_core.arrow.schema import Schema
from komira_core.traits.source_capabilities import SourceCapabilities
from .dynamic_join_filter import DynamicJoinFilter
from komira_core.traits.expr_id import ExprId
from komira_core.plan.expr_pool import ExprPool
from .morsel import Morsel
from komira_core.traits.source_statistics import SourceStatistics


trait MorselSourceImpl(Movable, Deinitable):
    """Per §4.2.1. Every v0.4 source struct implements this trait.

    Monomorphized at the USER's compile time when flowed through
    DataFrame[S] -> execute[S, K]. No trait-object / dyn dispatch exists
    in Mojo and none is required here.

    Concurrent-pull contract (§4.2.5.1, Phase 1d.4.1 revision)
    ----------------------------------------------------------
    `next_morsel` takes `self` (immutable borrow), NOT `mut self`. The
    generic executor binds the source to a local `var` once, then every
    parallel worker calls `source.next_morsel(wid)` through a shared
    immutable borrow -- there is no per-worker `source.copy()`, and no
    `ArcPointer` wrapping is required.

    Concrete sources push mutable shared state (e.g. the RG cursor)
    behind `Atomic[...]` so the immutable borrow is sound -- Atomic
    read-modify-write is the only mutation allowed through `self`.
    `ParquetMorselSource` owns a heap `_Counters` slab reached through
    an `UnsafePointer` field; `alloc`+`free` keeps the source Movable
    without making Atomic itself Movable (Mojo disallows that).

    Single-pass contract (§4.3): `next_morsel` returns each row exactly
    once across the source's lifetime. Returns `None` at EOF (Rev 4.1
    convention); the scheduler must never call next_morsel after seeing
    `None`. Re-scan goes through `as_source()` which rewrite rules add in
    Phase 5.

    Capability hooks (`set_projection`, `set_decode_filter`,
    `set_pushed_predicate`, `set_bypass_columns`, `set_dict_preservation`,
    `set_cancel_flag`) take `mut self` -- they run ONCE during
    `apply_source_hooks` BEFORE the first `next_morsel` call, so they
    do not race with worker pulls. The optimizer consults `capabilities()`
    BEFORE calling any hook -- a setter reached through a source that
    returns `supports_X == False` is a planner bug. Defaults let sources
    opt into any subset without boilerplate.

    Hook consumption mode (Phase 2.2)
    ---------------------------------------------
    The compile-time alias `HOOKS_CONSUMED_AT_CONSTRUCTION: Bool` selects
    one of two hook-application shapes:

      * False (default — legacy `ParquetMorselSource`, every Mock /
        BatchSource impl): hooks flow through `apply_source_hooks(src,
        hooks)` which calls each `set_*` method in §4.3 ordering. This
        is the historical shape and remains supported.

      * True (Phase 2.2 — `ParquetMultiConsumerSource_Single` / `_Known`
        and any future construction-time-consumed sources): the source
        consumes its capability bundle at __init__ time via a
        `caps: SourceCapabilityConfig` ctor arg. `apply_source_hooks`
        becomes a no-op for these sources, because their setters are
        either advisory (mutating `_caps` after the fact has no
        downstream effect — production migrates to ctor-time) or
        deliberately not overridden (the 3 banned-pointer-payload
        setters). The ENGINE callsite is responsible
        for converting `LoweredSourceHooks` to `SourceCapabilityConfig`
        BEFORE constructing the source — see
        `lowered_hooks_to_source_caps` in source_hooks.mojo.

    During the Phase 2.2 → 2.3 migration both shapes coexist:
    `apply_source_hooks` checks `S.HOOKS_CONSUMED_AT_CONSTRUCTION` via a
    `@parameter if` and either drives setters or no-ops. Phase 2.3
    flips the production callsites to construction-time consumption
    against the `True` sources; Phase 2.4 deletes the legacy source
    and the `False` arm becomes dead code that future cleanup can
    elide.
    """

    # Hook consumption mode (Phase 2.2).
    #
    # False (default) → `apply_source_hooks` calls each setter in §4.3
    # ordering. Used by legacy `ParquetMorselSource` and every Mock /
    # BatchSource impl.
    #
    # True → source consumed `SourceCapabilityConfig` at __init__ time;
    # `apply_source_hooks` is a no-op. Used by
    # `ParquetMultiConsumerSource_Single` / `_Known` (Phase 2.1+).
    comptime HOOKS_CONSUMED_AT_CONSTRUCTION: Bool = False

    # Hot path + schema/stats (every source must implement).
    # Immutable-borrow: safe for concurrent worker calls; shared mutable
    # state must live behind Atomic.
    def next_morsel(self, worker_id: Int) raises -> Optional[Morsel]: ...
    def output_schema(self) -> Schema: ...
    def partition_hint(self) -> Int: ...
    def row_count_hint(self) -> Int: ...
    def capabilities(self) -> SourceCapabilities: ...

    # Stats: default returns an empty SourceStatistics (all Optional fields
    # None, empty per_column). Sources with real stats override.
    def statistics(self) -> SourceStatistics:
        return SourceStatistics()

    # Capability hooks -- no-op defaults. Only sources advertising the
    # corresponding bit in `capabilities()` override.

    # F4 migration: `flag` is now an origin-parameterized
    # reference, not a wildcard `UnsafePointer[_, MutExternalOrigin]`. The
    # trait method signature carries the concrete origin through
    # monomorphization; concrete source impls widen once at the stash
    # field boundary (private, with `# SAFETY:` comment per safety model
    # §5.1 "one legitimate UnsafePointer in a PRIVATE field"). Callers
    # no longer need to widen — they pass a `ref [caller_origin] Atomic[int8]`
    # and the trait binds `origin` to the caller's concrete origin.
    # Lifetime contract (caller MUST uphold):
    #   - `flag` refers to a long-lived Atomic[int8] owned by the
    #     generic_executor / pipeline_compiler test harness. It remains
    #     valid from `apply_source_hooks` through the last `next_morsel`
    #     and `combine()` -- the framework owns the flag for the whole
    #     execution window.
    #   - Caller MUST NOT free the flag before the source is dropped;
    #     the concrete source may poll the pointer at any point during
    #     `next_morsel`.
    # Implementation contract:
    #   - Implementors may stash the pointer on `self` (production sources
    #     do this). The SAFETY comment on the stash field MUST state that
    #     lifetime is delegated to the framework invariant above.
    def set_cancel_flag[
        origin: Origin[mut=True]
    ](
        mut self,
        flag: UnsafePointer[AtomicI8, origin],
    ) -> None:
        """Install a cooperative cancel-flag pointer.

        SAFETY: origin carries the caller's concrete lifetime through
        monomorphization. `flag` must refer to a long-lived Atomic[int8]
        that outlives every subsequent next_morsel call, and is zero
        until the caller requests cancellation.

        The cancel flag is Atomic[int8] (0 == run, !=0 == cancel) rather
        than Atomic[bool] -- Mojo's LLVM backend refuses atomic
        loads on i1 ("atomic memory access' size must be byte-sized").
        Semantics match Rust's AtomicU8-as-bool idiom.
        """
        pass

    def set_projection(mut self, cols: List[Int]) -> None:
        pass

    def set_decode_filter(mut self, stages: List[ExprId]) -> None:
        pass

    def set_pushed_predicate(mut self, expr: ExprId) -> None:
        pass

    def set_bypass_columns(mut self, cols: List[Int]) -> None:
        pass

    def set_dict_preservation(mut self, on: Bool) -> None:
        pass

    # F4 migration: origin-parameterized trait method. The
    # ExprPool is owned by the plan compiler (or the test harness's
    # stack) and outlives every source / sink / worker by construction
    # -- a non-owning pointer is sound under that framework-level
    # invariant, and the origin parameter makes the lifetime explicit
    # at the call site (no more wildcard cast).
    # Lifetime contract (caller MUST uphold):
    #   - `pool` points to an ExprPool owned by the caller's enclosing
    #     scope (plan compiler stack frame or test harness).
    #   - Pool MUST outlive every subsequent `next_morsel` call reachable
    #     from this source AND every sink's `combine()` that resolves
    #     ExprIds stashed by this source.
    #   - Caller MUST NOT move / relocate the pool after calling this
    #     hook: ExprPool owns interior heap nodes that `pool.resolve(...)`
    #     dereferences.
    # Implementation contract:
    #   - Implementors may stash the pointer on `self`. The stash field
    #     MUST carry a SAFETY comment pointing back here for the
    #     lifetime proof.
    def set_expr_pool[
        origin: Origin[mut=True]
    ](
        mut self,
        pool: UnsafePointer[ExprPool, origin],
    ) -> None:
        """Install a non-owning ExprPool pointer.

        SAFETY: origin carries the caller's concrete lifetime.
        Phase 1e.1: non-owning pool pointer. Default is no-op for sources
        that do not consume ExprId handles. Sources that do (late-mat
        filter stages, pushed predicates) override to stash the pointer;
        they MUST document the lifetime invariant (pool outlives the
        source's `next_morsel` calls) in a SAFETY comment on the stash
        field.
        """
        pass

    # Phase 1g tuning knobs (PE review): the intra-RG split (opt #6) and
    # prefetch (opt #7) knobs were previously reachable only on the
    # concrete ParquetMorselSource -- not via LoweredSourceHooks -- so
    # production callers (materialize_parquet_collect) never exercised
    # them. Trait defaults are no-ops; concrete sources that expose the
    # knobs override. See source_hooks.mojo for wiring.
    def set_morsel_rows(mut self, rows: Int) -> None:
        pass

    def set_prefetch_enabled(mut self, on: Bool) -> None:
        pass

    # Stream AQ (CB-02/CB-03): count-only late-mat hook. When enabled,
    # the source's late-mat path skips `filter_to_indices` +
    # `gather_batch` and returns a synthetic zero-column batch carrying
    # only `num_rows = surviving`. Default impl is a no-op; Parquet
    # source overrides. See source_hooks.mojo + parquet_morsel_source.mojo.
    def set_count_only(mut self, on: Bool) -> None:
        pass

    # Phase 3.6 (bloom-pushdown): dynamic-filter hook. When set, the
    # source applies the build-side DynamicJoinFilter's bloom mask to
    # the named INT64 key column on every row group, AND-combined with
    # any pre-existing decode-filter mask. Default impl is a no-op;
    # ParquetMorselSource overrides.
    #
    # v0.3 source: morsel_join.rs::ColumnarBuildSink::probe_side_filter_stages
    # (lines 740-813) which builds FilterStage objects keyed by probe
    # column index and pushes them into the scan source via
    # `set_decode_filter` -- analogous shape, different surface (Mojo
    # uses one aggregate hook, not per-tier stages).
    #
    # SAFETY: caller-supplied `df` pointer must outlive every subsequent
    # `next_morsel` call. The `materialize_parquet_join` driver
    # guarantees this by holding the underlying ArcPointer through the
    # probe-segment execution window. `key_name` is owned by the source
    # for lookup purposes (cheap String copy).
    def set_dynamic_filter[
        origin: Origin[mut=True]
    ](
        mut self,
        df: UnsafePointer[DynamicJoinFilter, origin],
        key_name: String,
    ) -> None:
        """Install a dynamic join filter for probe-side scan reduction.

        SAFETY: origin carries the caller's concrete lifetime;
        `df` must point to a DynamicJoinFilter whose lifetime exceeds
        every `next_morsel` call reachable from this source. Mojo
        cannot express the cross-segment lifetime, so the trait
        method is origin-parameterized and the source's stash field
        widens once at the private boundary per safety model §5.1.
        """
        pass

    # v0.3 mirror (perf campaign #5): query whether a
    # decode-filter is already installed on this source. The
    # compiler-level dyn-filter pass (`_install_dynamic_filter_on_probe`
    # in `morsel_executor.mojo`) consults this so it does NOT install a
    # decode-stage filter that would target wrong column indices when
    # intermediate operators sit between the scan and the join (multi-
    # way join chains, OP_FILTER / OP_PROJECT prefixes). The RG-prune
    # tier (set via `set_dynamic_filter`) is always safe because it
    # operates on the build-side key column the source can resolve
    # by name.
    #
    # v0.3 source: pipeline_compiler.rs:1905 (`source.has_decode_filter()`
    # OnceLock check). v0.4 default returns False; concrete sources
    # override to report the cached state.
    def has_decode_filter(self) -> Bool:
        """Query whether a decode-filter has been installed.

        Default impl returns False (no filter). Sources that support
        `set_decode_filter` should override to return True after the
        stages have been stashed.
        """
        return False
