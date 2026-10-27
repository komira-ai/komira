# =============================================================================
# ViewHandle — opaque, ctx-back-reference-free handle for registered views
# =============================================================================
#
# ViewHandle carries ONLY `name: String + generation: UInt64`. A handle holds
# no back-reference to the context: the caller passes `ctx` explicitly to every
# `ctx.view(handle)` / `ctx.drop_view(handle)` call (the DuckDB convention).
# A context back-reference (`ArcPointer[EngineContext]`) is not possible
# anyway: `ArcPointer` requires a movable payload, and the engine context is
# not movable (it owns a Slab, a worker pool and a Dict of non-movable values).
#
# `generation` is the monotonic per-name version snapshot taken at
# `create_view`. On `ctx.view(handle)`, the registry's CURRENT generation
# is compared; mismatch raises StaleViewHandle. Same-name re-registration
# BUMPS the generation, invalidating previously-issued handles.
#
# Movable + Copyable so users can pass + store the handle freely (collections,
# closures, multi-step pipelines).
#
# Prior art: DuckDB `Connection::CreateView(name, query)` registers a view in
# the catalog under a STRING name and resolves it at planning time; there is no
# opaque handle, the user re-references the view by name in SQL. Our ViewHandle
# carries the name directly + a generation snapshot for stale-handle detection.
# =============================================================================


@fieldwise_init
struct ViewHandle(Movable, Copyable, Deinitable):
    """Opaque handle returned by `ctx.create_view(name, df)`.

    Shape: `name + generation: UInt64` ONLY.
    NO ctx back-reference. The caller threads `ctx` explicitly to every
    `ctx.view(handle)` / `ctx.drop_view(handle)` call.

    Resolution semantics (`ctx.view(handle)`):
        * Look up `handle.name` in the registry. If absent: raise
          `ViewNotFound`.
        * Compare `handle.generation` to the registry's current
          per-name generation. If mismatch: raise `StaleViewHandle`
          (the view was dropped + recreated since this handle was
          issued, or was dropped outright).
        * On match: return a fresh `DataFrame` whose plan is a deep
          clone of the registered plan.

    Movable + Copyable so users can pass + store the handle in
    collections / closures / multi-step pipelines. No heap state
    of its own — copying is cheap (`name.copy() + generation`).
    """

    var name: String
    """The user-chosen view name. Used as the registry key."""

    var generation: UInt64
    """Snapshot of the per-name generation at `create_view` time.

    Bumped monotonically on every `create_view(name, ...)` call that
    re-registers an existing name. The registry retains the prior
    generation counter even after `drop_view` (no removal of the
    counter entry) so a re-`create_view` of the same name produces
    a strictly higher generation, ensuring old handles raise
    StaleViewHandle on resolution.
    """

    @always_inline
    def copy(self) -> Self:
        """Explicit deep-clone (cheap — `name` is a String).

        Equivalent to the Mojo-synthesized copy under the
        @fieldwise_init + Copyable conformance; provided as a
        deliberately-public method so call sites can read as
        `handle.copy()` for readability vs. relying on implicit-copy.
        """
        return ViewHandle(self.name, self.generation)
