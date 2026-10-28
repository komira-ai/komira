# =============================================================================
# QueryContext — per-query execution settings
# =============================================================================
#
# Carries query-scoped configuration that plan compilation and execution
# need but that live logically above a single LogicalPlan (memory budget,
# session scratch dir, plan-level flags, etc.).
#
# The budget is carried on a value rather than as an extra positional
# argument so that the user has one surface to override the auto-computed
# budget (`with_memory_budget(bytes)`), and so that later session-scoped
# fields (scratch dir, plan-level flags) have a natural home. Internally the
# plan compiler still threads an `op_budget: Int` scalar through node
# compilation.
#
# Design: Movable + ImplicitlyCopyable. All fields are plain Int — no
# owning pointers — so default copy/move semantics are safe and cheap.
# =============================================================================


# =============================================================================
# Public constants
# =============================================================================

# memory_budget sentinel meaning "no user override — derive from hardware
# at compile time, or leave unlimited if derivation is disabled."
comptime QUERY_BUDGET_UNLIMITED: Int = 0


@fieldwise_init
struct QueryContext(ImplicitlyCopyable, Movable):
    """Per-query execution settings.

    Fields:
        memory_budget: Total bytes available to memory-intensive operators
            across the whole query. Divided evenly across
            memory-intensive operators via
            the plan compiler's per-operator budget split.
            Value `0` = `QUERY_BUDGET_UNLIMITED` = no spill (legacy
            concat-then-sort path for Sort; no spill for Aggregate/Join).
            Set via `QueryContext.with_memory_budget(bytes)`.

    Possible future fields (not implemented):
        scratch_dir: Override for the spill directory.
        plan_flags: UInt64 bitfield for plan-level toggles (e.g.,
            force-legacy-sort, disable-scan-dedup). Currently all
            plan-level flags are comptime booleans.

    Semantics:
        QueryContext is Movable + ImplicitlyCopyable. Callers treat it as
        a value type — copy freely, no lifetime concerns.
    """

    var memory_budget: Int

    @staticmethod
    def default() -> QueryContext:
        """Construct a QueryContext with no user overrides.

        `memory_budget = QUERY_BUDGET_UNLIMITED` — the engine falls back
        to the no-spill path for memory-intensive operators.
        """
        return QueryContext(memory_budget=QUERY_BUDGET_UNLIMITED)

    @staticmethod
    def with_memory_budget(bytes: Int) -> QueryContext:
        """Construct a QueryContext with an explicit memory budget override.

        Args:
            bytes: Total bytes across all memory-intensive operators.
                Must be >= 0. Zero means unlimited (= default).

        Returns:
            A new QueryContext with `memory_budget = bytes`.
        """
        return QueryContext(memory_budget=bytes)

    def is_unlimited(self) -> Bool:
        """True when no user override is set (spill disabled)."""
        return self.memory_budget <= QUERY_BUDGET_UNLIMITED
