# =============================================================================
# MaterializedViewHandle — opaque, ctx-back-reference-free handle for
# REGISTERED-AND-MATERIALIZED views (single-eval RecordBatch caching).
# =============================================================================
#
# MaterializedViewHandle carries ONLY `name: String + generation: UInt64`,
# mirroring `ViewHandle`, and holds no context back-reference. The caller passes
# `ctx` explicitly to every `ctx.materialized_view(handle)` /
# `ctx.drop_materialized_view(handle)` / `ctx.refresh_materialized_view(handle, df^)`
# call.
#
# Distinct from `ViewHandle`:
#   * `ViewHandle` registers the *plan* (LogicalPlan deep-clone). Every
#     `ctx.view(handle)` re-runs the plan via `ctx.materialize(df^)` — the
#     plan-compile cache makes the second-and-later resolutions cheap
#     in the OPTIMIZE+COMPILE phase, but the EXECUTION phase still runs.
#   * `MaterializedViewHandle` registers the *result* — a stored
#     RecordBatch wrapped in an InMemorySource. Every
#     `ctx.materialized_view(handle)` returns a fresh DataFrame whose
#     plan is a one-node Scan over the cached batch (zero re-eval; the
#     underlying batches are refcount-shared via `ArcPointer[Slab[RB]]`
#     inside InMemorySource).
#
# Generation semantics (same shape as ViewHandle):
#   * `create_materialized_view(name, df^)`: materializes df NOW; stores
#     the result; returns handle with monotonically-bumped generation.
#   * `refresh_materialized_view(handle, df^)`: re-materializes df NOW;
#     replaces the stored batches; bumps the generation; returns a
#     NEW handle. The OLD handle becomes stale.
#   * `drop_materialized_view(handle)`: removes the registration; the
#     generation counter is RETAINED across the drop so any
#     subsequent `create_materialized_view(<same name>, ...)` produces
#     strictly higher generation (stale-handle detection).
#
# Movable + Copyable so users can pass + store the handle freely.
# =============================================================================


@fieldwise_init
struct MaterializedViewHandle(Movable, Copyable, Deinitable):
    """Opaque handle returned by `ctx.create_materialized_view(name, df^)`.

    Mirrors B.j.1's `ViewHandle` shape: `name + generation: UInt64` ONLY,
    NO ctx back-reference. The caller threads `ctx` explicitly to every
    `ctx.materialized_view(handle)` / `ctx.drop_materialized_view(handle)`
    / `ctx.refresh_materialized_view(handle, df^)` call.

    Resolution semantics (`ctx.materialized_view(handle)`):
        * Look up `handle.name` in the materialized-view registry. If
          absent: raise `MaterializedViewNotFound`.
        * Compare `handle.generation` to the registry's current
          per-name generation. If mismatch: raise
          `StaleMaterializedViewHandle` (the view was refreshed,
          dropped, or dropped-and-recreated since this handle was
          issued).
        * On match: return a fresh `DataFrame` whose plan is a
          single-node `Scan(InMemorySource(cached_batches))` — zero
          re-evaluation; the cached batches are refcount-shared via
          `ArcPointer[Slab[RecordBatch]]`.

    Movable + Copyable so users can store the handle in collections /
    closures / multi-step pipelines. No heap state of its own — copying
    is cheap (`name.copy() + generation`).
    """

    var name: String
    """The user-chosen materialized-view name. Used as the registry key."""

    var generation: UInt64
    """Snapshot of the per-name generation at `create_materialized_view` or
    `refresh_materialized_view` time.

    Bumped monotonically on every `create_materialized_view(name, ...)` call
    that re-registers an existing name AND on every
    `refresh_materialized_view(handle, ...)` call. The registry retains
    the prior generation counter even after `drop_materialized_view` (no
    removal of the counter entry) so a re-`create_materialized_view` of
    the same name produces a strictly higher generation, ensuring old
    handles raise `StaleMaterializedViewHandle` on resolution.
    """

    @always_inline
    def copy(self) -> Self:
        """Explicit deep-clone (cheap — `name` is a String).

        Equivalent to the Mojo-synthesized copy under the @fieldwise_init
        + Copyable conformance; provided as a deliberately-public method
        so call sites can read as `handle.copy()` for readability vs.
        relying on implicit-copy.
        """
        return MaterializedViewHandle(self.name, self.generation)
