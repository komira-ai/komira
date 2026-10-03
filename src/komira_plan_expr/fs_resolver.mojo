# =============================================================================
# komira_plan_expr.fs_resolver — the FS-ERASED resolver trait the
# materialize spine threads as `[REG: FsResolver = LocalOnlyResolver]`.
# =============================================================================
#
# THE CRUX: `_resolve_source` lives in `komira_engine_dispatch`,
# which is BELOW `komira_fs_registry` — so the engine spine CANNOT name the
# concrete `FsHandle` union (it lives in the top package). The resolution is a
# TINY trait, FS-ERASED, RESIDENT IN CORE, that the spine threads as ONE
# comptime type param `[REG: FsResolver = LocalOnlyResolver]`:
#   * the spine never names any FS-adjacent concrete type — it calls trait
#     methods on `reg`;
#   * `komira_fs_registry`'s `FsRegistry` conforms to `FsResolver` and holds
#     the live `FsHandle` side table; its conformer method bodies are where the
#     4-arm FS fan-out lives (the `FsHandle` tag ladder) — visible there because
#     all 4 FS packages are below `komira_fs_registry`;
#   * `LocalOnlyResolver` (below) is the defaulted comptime resolver that keeps
#     every local call site on the local default (it resolves any source to
#     the local default — zero config, no registry).
#
# WHY THE TRAIT CANNOT NAME `materialize_parquet_collect`:
#   `materialize_parquet_collect` (`komira_parquet`) takes `LocalDispatcher`,
#   `CancellationToken` and `ParquetMetadataCache` — ALL ABOVE komira_core. A
#   core-resident trait CANNOT spell those types. So the trait carries only the
#   FS-ERASED, core-expressible IDENTITY-RESOLUTION method (`resolve_scheme`).
#   The heavy materialize-driving method (sketched in the docstring below)
#   belongs at the spine seam in `komira_fs_registry` /
#   `komira_engine_dispatch`, where the heavy types are visible.
#
# Pointer discipline: the resolver threads its `self` as a
#   normal trait-method receiver (a lifetime-tracked `ref`), NOT a fn-ptr, NOT a
#   wildcard origin, NOT `unsafe_from_address`. Clean by construction.
# =============================================================================

from komira_plan_expr.fs_descriptor_pod import FsDescriptorPod, FS_SCHEME_FILE


trait FsResolver(Movable, Deinitable):
    """FS-ERASED resolver the materialize spine threads as
    `[REG: FsResolver = LocalOnlyResolver]`.

    This trait defines the FS-erased identity-resolution surface that
    `komira_core` can express. The heavy materialize-driving method has this
    shape:

        # NOT in core — it belongs at the spine seam in komira_fs_registry /
        # komira_engine_dispatch, where the heavy parquet/engine arg types are
        # visible; the trait is then either widened there or the spine calls a
        # registry-resident method directly:
        #
        #   fn materialize_source(
        #       self,
        #       node_id: Int,
        #       mut dispatcher: LocalDispatcher[NoopSink],
        #       var cancel_token: CancellationToken,
        #       pq_data: ParquetSourceData,
        #       operators: Slab[MorselOp],
        #       policy: MorselSizingPolicy,
        #       mut footer_cache: ParquetMetadataCache,
        #       count_only: Bool = False,
        #       ...dyn-filter args...,
        #   ) raises -> RecordBatch
        #
        # The conformer (`FsRegistry`) resolves `registry[node_id] -> FsHandle`
        # and dispatches the 4-arm `FsHandle.materialize_parquet(...)` tag
        # ladder, each arm calling `materialize_parquet_collect[ConcreteFS]`.
        # `LocalOnlyResolver` ignores `node_id` and binds `LocalFs[NoopSink]`.

    The FS-erased, core-expressible surface:
    """

    def resolve_scheme(self, node_id: Int) -> UInt8:
        """Return the `FS_SCHEME_*` code bound to `node_id`, or `FS_SCHEME_FILE`
        if `node_id` has no explicit binding (the local default). This is the
        FS-erased probe the spine uses to decide whether a source needs the
        registry path or the local default — without naming any FS type.

        The conformer (`komira_fs_registry.FsRegistry`) reads its side table;
        `LocalOnlyResolver` returns `FS_SCHEME_FILE` unconditionally."""
        ...

    def has_binding(self, node_id: Int) -> Bool:
        """True if `node_id` carries an explicit FS binding in this resolver.
        `LocalOnlyResolver` is always False (local-default for every node)."""
        ...


@fieldwise_init
struct LocalOnlyResolver(FsResolver, Movable, Deinitable):
    """The DEFAULTED comptime resolver (`[REG: FsResolver = LocalOnlyResolver]`).

    Resolves EVERY source to the local default — zero config, no side table, no
    FS type named. The spine threads this resolver by default: `resolve_scheme`
    always returns `FS_SCHEME_FILE`, `has_binding` is always False, so the
    engine never consults a registry and runs the local `LocalFs[NoopSink]`
    path.

    A zero-field POD (Movable + Deinitable). The `[REG: FsResolver =
    LocalOnlyResolver]` spine monomorphizes twice (this + `FsRegistry`), not
    4x — the 4-way FS fan-out lives in `FsRegistry`'s conformer, not the spine.

    Lives in `komira_core` (NOT `komira_fs_registry`): it binds the LOCAL
    default and names NO cloud FS type, so it is core-expressible. The
    materialize-driving body (binding `LocalFs[NoopSink]`) is added at the spine
    seam where `LocalFs` is reachable; the FS-erased surface here needs no FS
    type at all.
    """

    def resolve_scheme(self, node_id: Int) -> UInt8:
        return FS_SCHEME_FILE

    def has_binding(self, node_id: Int) -> Bool:
        return False
