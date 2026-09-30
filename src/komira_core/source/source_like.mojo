# =============================================================================
# SourceLike trait — abstract source identity for LogicalPlan Scan nodes
# =============================================================================
#
# Every concrete source implements:
#   - schema()        -> Schema        : structural schema (eager at ctor).
#   - estimate_rows() -> Int           : row-count hint for the cardinality
#                                        estimator; -1 means "unknown" (e.g.
#                                        parquet before footer read; some
#                                        streaming sources).
#   - fingerprint()   -> UInt64        : source-identity hash for plan-cache
#                                        discrimination. MUST be stable across
#                                        `source^.copy()` moves — the cache
#                                        contract is cardinality-replay safety.
#
# `to_dataframe()` is INTENTIONALLY NOT part of the trait — putting it in the
# trait creates a cyclic type dependency:
#
#     DataFrame -> ScanPlan -> SourceVariant -> SourceLike -> DataFrame
#
# Each concrete source declares its own `def to_dataframe(var self) ->
# DataFrame` inline (~3 LOC). Ergonomically equivalent
# (`src.to_dataframe()` still works).
#
# `supports_filter_pushdown(predicate: Expr) -> Bool`: a per-predicate
# pushdown query modeled after DataFusion's
# `TableProvider::supports_filters_pushdown`. The current form is `Bool` (a
# predicate is either pushable into this source or not); the tri-state
# `Unsupported`/`Inexact`/`Exact` form (where `Inexact` means "pushed but
# the source may return false positives, so re-evaluate above") is a
# possible refinement. The trait default is `False` — a source that does
# not override gets NO pushdown, which is the safe degradation (the
# predicate stays as a `Filter` node above the scan). A source answers
# per-conjunct, so `Filter(p1 AND p2)` over a source that pushes `p1` but
# not `p2` becomes `Filter(p2)` over `Scan(pushed_filter=p1)`.
# =============================================================================

from komira_core.arrow.schema import Schema
from komira_core.plan.expr import Expr


trait SourceLike(Movable, Copyable, Deinitable):
    """Trait every concrete source implements. The trait does NOT include
    `to_dataframe` — that would create a circular type dependency
    (DataFrame -> ScanPlan -> SourceVariant -> concrete source). Each
    concrete source declares its own
    `to_dataframe(var self) -> DataFrame` inline (~3 LOC); user-facing
    ergonomics (`src.to_dataframe()`) are unchanged.
    """

    def schema(self) -> Schema:
        """Structural schema of the source's output. Eagerly computed at
        construction so this method is a pure copy of cached state (no I/O).
        """
        ...

    def estimate_rows(self) -> Int:
        """Row-count hint for the cardinality estimator. Returns -1 for
        "unknown" (parquet pre-footer-read; some streaming sources)."""
        ...

    def fingerprint(self) -> UInt64:
        """Stable identity used for cache discrimination. Same source
        (same path / same Arc payload) -> same fingerprint. Must be
        stable across `value^` moves.
        """
        ...

    def supports_filter_pushdown(self, predicate: Expr) -> Bool:
        """Per-predicate pushdown query.

        Returns `True` if this source can usefully absorb `predicate`
        into its scan (e.g. a ParquetSource enabling row-group zonemap
        pruning, or a partition-column predicate that prunes file paths);
        `False` if `predicate` should stay as a `Filter` node above the
        scan. The contract is two-way: if this method returns `True`, the
        optimizer WILL fold `predicate` into the scan's `pushed_filter`
        AND the engine WILL apply it correctly — a source must never
        claim pushability the engine cannot honor.

        DEFAULT: `False` — a source that does not override gets no
        pushdown (the conservative / safe degradation). The optimizer
        queries this per-conjunct so a source can push some conjuncts of
        an AND-tree and reject others.

        A possible refinement is a tri-state return
        (`Unsupported` / `Inexact` / `Exact`) modeled after
        `TableProviderFilterPushDown` — `Inexact` lets a source push a
        best-effort approximation while the optimizer keeps a re-checking
        `Filter` above. The current form is the strict `Bool` (push and
        trust, or don't push).
        """
        return False
