# =============================================================================
# CteScope -- transient, statement-scoped CTE bindings for `df.with_cte[...]`.
# =============================================================================
#
# v4.2:
#   `df.with_cte["name"](inner_df^)` records `inner_df`'s LogicalPlan under
#   `name` for the duration of `self`'s `optimize()` call only (unlike
#   `ctx.create_view` which is persistent until `drop_view`). This module
#   holds the storage container for those bindings.
#
# Design (mirrors B.j.1's eager-inline shape):
#   * `CteScope` is a small Movable container — a parallel `List[String]`
#     (names) + `Slab[LogicalPlan]` (plans). `LogicalPlan` is Movable-only
#     (it has `.copy()` but is not `Copyable`), so a `List[LogicalPlan]`
#     does not compile — `Slab[LogicalPlan]` is the codebase idiom for a
#     growable array of Movable-only `LogicalPlan` (cf. B.j.1's
#     `Slab[Optional[LogicalPlan]]` view registry).
#   * The scope lives on the `DataFrame` returned by `with_cte`; the
#     execution entry points (`ctx.materialize` / `materialize_limit` /
#     `materialize_paginated` / `to_parquet`) move it out of the DataFrame
#     and thread it into `optimize(plan^, ctx, reg, cte_scope^)`, which
#     consumes it by value — so the binding is "registered for the duration
#     of `optimize()` only" and dropped when `optimize()` returns.
#   * B.j.3 ships the storage layer + the `with_cte` API + the threading
#     hook. The *resolution* step (a `PLAN_VIEW_REF` LogicalPlan variant
#     that `optimize()` rewrites to the bound plan, enabling
#     reference-by-name inside `self`) is the B.j.4 follow-up — exactly
#     parallel to B.j.1, which shipped the view registry + handle but
#     deferred the `LogicalViewRef` compiler sub-pass to B.j.4.
#
# Encapsulation: no `UnsafePointer` in any signature here. `Slab[LogicalPlan]`
# encapsulates its own byte-backed storage internally.
# =============================================================================

from komira_collections.slab import Slab
from komira_plan_ir.logical_plan import LogicalPlan


struct CteScope(Movable, Sized):
    """Transient, statement-scoped CTE name -> LogicalPlan bindings.

    Empty by default (the no-bindings state). `add(name, plan)` appends a
    binding; `has(name)` checks for presence; `get_copy(name)` returns a
    deep `LogicalPlan.copy()` of the named binding's plan.
    """

    var _names: List[String]
    var _plans: Slab[LogicalPlan]

    def __init__(out self):
        """Create an empty scope (no bindings)."""
        self._names = List[String]()
        self._plans = Slab[LogicalPlan]()

    # __moveinit__ / __del__ are compiler-synthesized (List[String] + Slab
    # both auto-synth move/drop).

    @always_inline
    def __len__(self) -> Int:
        """Number of bindings in this scope."""
        return len(self._names)

    @always_inline
    def is_empty(self) -> Bool:
        """True iff this scope has no bindings."""
        return len(self._names) == 0

    def has(self, name: String) -> Bool:
        """True iff `name` is bound in this scope."""
        for i in range(len(self._names)):
            if self._names[i] == name:
                return True
        return False

    def name_at(self, idx: Int) -> String:
        """Return the binding name at `idx` (0 <= idx < len(self))."""
        return self._names[idx]

    def add(mut self, var name: String, var plan: LogicalPlan) raises:
        """Bind `name` -> `plan` in this scope.

        Raises:
          * empty `name` (malformed CTE name).
          * `name` already bound in this scope (a SQL `WITH a AS (...), a
            AS (...)` is a name collision; we reject it eagerly so the
            second `with_cte["a"]` call doesn't silently shadow the first).
        """
        if name.byte_length() == 0:
            raise Error("with_cte: CTE name cannot be empty")
        if self.has(name):
            raise Error(
                "with_cte: CTE name '" + name + "' is already bound in this"
                + " statement scope (duplicate WITH binding)"
            )
        self._names.append(name^)
        self._plans.append(plan^)

    def get_copy(self, name: String) raises -> LogicalPlan:
        """Return a deep `LogicalPlan.copy()` of the plan bound to `name`.

        Raises if `name` is not bound. The deep copy is intentional —
        callers (e.g. `cte_ref["name"]()` / the `view_resolution_pass`
        compiler sub-pass) must each get an independent plan subtree; the
        scope's master copy stays usable for further resolutions within
        the same statement (mirrors B.j.1's `ctx.view(handle)`
        deep-clone-on-resolve).
        """
        for i in range(len(self._names)):
            if self._names[i] == name:
                return self._plans[i].copy()
        raise Error(
            "with_cte: no CTE named '" + name + "' in this statement scope"
        )

    # -------------------------------------------------------------------------
    # Accessors for `view_resolution_pass` + nested `with_cte`.
    # -------------------------------------------------------------------------

    @always_inline
    def names_ref(ref self) -> ref [self._names] List[String]:
        """Return a `ref` to the internal names list.

        Used by `komira_sdk.optimizer.optimize()` to thread the CTE
        scope's storage into `komira_compiler.view_resolution_pass`
        (which resolves `PLAN_VIEW_REF` nodes against both the ctx view
        registry AND this scope). The pass takes the names list + the
        plans slab by `ref` — both `komira_collections` / stdlib container
        types, so the compiler stays `komira_sdk`-free (the standalone
        `komira_compiler` build still holds, mirroring how
        B.j.4 threads the view registry's `Slab[Optional[LogicalPlan]]` +
        `Dict[String, Int]`).
        """
        return self._names

    @always_inline
    def plans_ref(ref self) -> ref [self._plans] Slab[LogicalPlan]:
        """Return a `ref` to the internal plans slab. See `names_ref`."""
        return self._plans

    def merge_from(mut self, other: Self) raises:
        """Absorb every binding in `other` into `self`.

        Used by `df.with_cte["name"](self^, inner_df^)` for the NESTED
        `with_cte` case: when `inner_df` itself carries `_cte_bindings`
        (a `with_cte` whose inner DataFrame is the result of another
        `with_cte`), those inner bindings must be visible to the OUTER
        `optimize()` so a `cte_ref` reachable from `inner_df`'s plan
        resolves. `with_cte` is statement-scoped (like SQL `WITH`), so
        all bindings — outer and inner — live in one flat scope.

        Name-collision handling: ERROR. If `other` binds a name already
        bound in `self`, raise (do NOT shadow). Rationale: shadowing a
        CTE name across nesting levels is ambiguous; erroring is the safe
        v0.4 choice (matches the eager dup-reject in `add`). The error
        message names the collision. On a collision the merge is aborted
        mid-way — `self` is left with the bindings absorbed so far; that
        is acceptable because the caller (`with_cte`) propagates the
        raise (the whole statement fails).
        """
        for i in range(len(other._names)):
            var nm = other._names[i].copy()
            if self.has(nm):
                raise Error(
                    "with_cte: nested CTE name '" + nm + "' collides with an"
                    + " outer binding of the same name (shadowing is not"
                    + " allowed); rename one of them"
                )
            self._names.append(nm^)
            # Deep-clone the bound plan (cheap relative to materialize;
            # `other` may be dropped or reused independently). Mirrors
            # `get_copy`'s deep-clone-on-resolve discipline.
            self._plans.append(other._plans[i].copy())
