# =============================================================================
# ExprPool -- owning pool that resolves ExprId -> Expr
# =============================================================================
#
# The ExprPool handoff from plan to source is explicit: source hooks receive
# a non-owning reference to the ExprPool alongside the list of ExprIds.
#
# The pool is owned by
# the plan compiler (or the test harness's stack); it outlives every source,
# sink, and worker by construction. Hooks carry a non-owning
# `UnsafePointer[ExprPool]`. Refcounting is pure overhead.
#
# Storage: `Slab[Expr]` because `Expr` is Movable-only (owns
# OwnedPointer children). `List[Expr]` will not compile against Mojo's
# Copyable bound on List's T, which is why the rest of the plan layer uses
# the ExprArray alias around Slab.
#
# ExprPool itself is Movable only (Slab propagates the Movable-only
# bound). ArcPointer wraps Movable-only types fine.
# =============================================================================

from komira_collections.slab import Slab
from komira_plan_expr.expr_id import ExprId
from komira_plan_expr.expr import Expr


struct ExprPool(Movable, Sized):
    """Append-only registry mapping ExprId -> Expr.

    Built once by the plan compiler, then shared read-only across workers
    through a non-owning `UnsafePointer[ExprPool]` threaded through
    `LoweredSourceHooks`. The append-only invariant is what makes the
    read-only sharing safe -- ExprIds never become stale once handed
    out, and no slot is ever mutated or destroyed except by pool teardown.

    NOT Copyable (Expr is Movable-only, so element-wise copy is impossible
    even in principle). The owning stack frame (plan compiler / test
    harness) must outlive every source that received a pointer to it.
    """

    var _exprs: Slab[Expr]

    def __init__(out self):
        """Construct an empty pool."""
        self._exprs = Slab[Expr]()

    @staticmethod
    def empty() -> ExprPool:
        """Construct an empty (sentinel) pool.

        Callers that origin-parameterize a
        struct on `ImmutOrigin` for an Optional ExprPool field must bind
        the origin at construction time even when no real predicate is
        installed (Mojo cannot infer a default-origin for a None
        Optional). The sentinel-pool pattern gives the
        binding a target without forcing every callsite to wrap the
        struct in two variants.

        Semantics: an empty ExprPool registers no predicates; any caller
        that ALSO passes `pushed_predicate=None` will skip the RG-prune
        branch entirely. Calling `pool.resolve(id)` on the sentinel is a
        programmer error (no ExprIds were ever issued by it); the
        prune-site guard checks for `pushed_predicate.__bool__()` BEFORE
        resolve, so the sentinel is never resolved on the hot path.

        Returns:
            An ExprPool with zero registered expressions.
        """
        return ExprPool()

    def register(mut self, var expr: Expr) -> ExprId:
        """Append `expr` and return its handle.

        ExprId is a UInt32 index into the pool's internal array. Handles
        are stable for the lifetime of the pool (append-only).

        Args:
            expr: The expression to take ownership of.

        Returns:
            An `ExprId` whose `id` field is the 0-based insertion index.
        """
        var idx = len(self._exprs)
        self._exprs.append(expr^)
        return ExprId(UInt32(idx))

    def resolve(self, id: ExprId) -> ref [self._exprs._bytes] Expr:
        """Return a reference to the expression for `id`.

        The reference's lifetime is tied to the pool. Callers must not
        retain the reference past the pool's lifetime; in the normal path
        the pool is pinned alive by framework-level ownership (plan
        compiler / test harness) that outlives the source.

        Args:
            id: Handle previously returned by `register`.

        Returns:
            A reference to the stored `Expr`. NOT a copy, NOT a move.
        """
        # SAFETY: ExprId is append-only; any id ever issued is still in
        # range. debug_assert inside Slab.__getitem__ catches
        # programmer error (e.g. ids from a different pool).
        return self._exprs[Int(id.id)]

    def __len__(self) -> Int:
        """Return the number of registered expressions."""
        return len(self._exprs)
