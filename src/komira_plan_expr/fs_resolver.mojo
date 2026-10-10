# =============================================================================
# komira_plan_expr.fs_resolver — the FS-ERASED resolver trait: which scheme
# a plan's scan node is bound to, without naming a file system.
# =============================================================================
#
# The logical plan names the exact source each scan reads (its
# `FsDescriptorPod`; a surface maps the source URL's prefix to the scheme
# code with komira_source_url before it builds the plan). A compiled plan
# reads with the one file system that code names, so no table of live file
# systems is threaded anywhere: what code below the file-system packages
# needs is the FS-erased answer to "is this node bound, and to which
# scheme", and that is this trait.
#
#   * `FsBindings` (fs_bindings.mojo) conforms: the per-query
#     `node_id -> scheme` table a plan carries.
#   * `LocalOnlyResolver` (below) conforms: it resolves every node to the
#     local default, with no table at all.
#
# The trait carries identity resolution only (`resolve_scheme`,
# `has_binding`). It cannot carry a materialize-driving method: the
# Parquet reader's dispatcher, cancellation token and footer cache are all
# above the core packages, so a core-resident trait cannot spell them.
#
# Pointer discipline: the resolver threads its `self` as a
#   normal trait-method receiver (a lifetime-tracked `ref`), NOT a fn-ptr, NOT a
#   wildcard origin, NOT `unsafe_from_address`. Clean by construction.
# =============================================================================

from komira_plan_expr.fs_descriptor_pod import FsDescriptorPod, FS_SCHEME_FILE


trait FsResolver(Movable, Deinitable):
    """FS-ERASED resolver: the `FS_SCHEME_*` code a plan's scan node is
    bound to, and whether it is bound at all, with no file system named."""

    def resolve_scheme(self, node_id: Int) -> UInt8:
        """Return the `FS_SCHEME_*` code bound to `node_id`, or `FS_SCHEME_FILE`
        if `node_id` has no explicit binding (the local default), without
        naming any FS type.

        `FsBindings` reads its table; `LocalOnlyResolver` returns
        `FS_SCHEME_FILE` unconditionally."""
        ...

    def has_binding(self, node_id: Int) -> Bool:
        """True if `node_id` carries an explicit FS binding in this resolver.
        `LocalOnlyResolver` is always False (local-default for every node)."""
        ...


@fieldwise_init
struct LocalOnlyResolver(FsResolver, Movable, Deinitable):
    """The resolver that binds nothing: every source resolves to the local
    default. `resolve_scheme` always returns `FS_SCHEME_FILE` and
    `has_binding` is always False; no table, no FS type named.

    A zero-field POD (Movable + Deinitable). It lives in `komira_plan_expr`
    because it names no file system at all, so the core packages can
    express it.
    """

    def resolve_scheme(self, node_id: Int) -> UInt8:
        return FS_SCHEME_FILE

    def has_binding(self, node_id: Int) -> Bool:
        return False
