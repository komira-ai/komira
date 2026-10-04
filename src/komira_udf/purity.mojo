# =============================================================================
# purity.mojo — the UDF purity / pushdown-eligibility marker
# =============================================================================
#
# `Purity` is the comptime marker every unified-trait conformer
# (`Predicate` / `RowTransform` / `Aggregator`) carries via a
# `comptime PURITY: Purity` member. It is the metadata an optimizer
# reads to decide whether a UDF leaf is safe to push down past a
# pipeline-break or constant-fold (the optimizer rule itself is
# not implemented; the declaration ships forward-compatibly).
#
# The three levels mirror DuckDB's FunctionStability (the existing
# `udf_descriptor.FunctionStability` enum is the runtime-snapshot side of
# the same concept; `Purity` is the comptime-trait-member side):
#   * PURE      ≈ DuckDB CONSISTENT             — same input -> same output
#                 always; no observable state; safe to push down + fold.
#   * STATELESS ≈ DuckDB CONSISTENT_WITHIN_QUERY — deterministic within one
#                 query run but may read query-scoped context; pushdown is
#                 safe within a query, folding across queries is not.
#   * STATEFUL  ≈ DuckDB VOLATILE               — may differ per call (RNG,
#                 per-row mutable `self`); never pushable, never foldable.
#
# Canonical enum shape: `@fieldwise_init`-free tagged struct with a
# `var _tag: UInt8` discriminator + named `comptime` constants — the exact
# pattern `FunctionStability` / `NullHandling` use in `udf_descriptor.mojo`.
# No heap fields; trivially `Copyable & Movable & Deinitable`,
# so it is legal as a `comptime` trait member.
# =============================================================================


struct Purity(ImplicitlyCopyable, Movable, Copyable, Deinitable):
    """UDF purity level — controls optimizer pushdown + constant folding.

    Carried as a `comptime PURITY: Purity` member on the three unified
    trait surfaces (`Predicate` / `RowTransform` / `Aggregator`). The
    optimizer-rule integration is not implemented; ships the
    declaration so conformers do not need a retrofit when the rule lands.

    Three levels (mirroring DuckDB FunctionStability):
        PURE      : same input -> same output always. Pushable + foldable.
        STATELESS : deterministic within one query. Pushable within a query;
                    not foldable across queries.
        STATEFUL  : may differ per call (RNG, mutable per-row `self`).
                    Never pushable, never foldable.
    """

    var _tag: UInt8

    def __init__(out self, tag: UInt8):
        self._tag = tag

    def __init__(out self, tag: Int):
        self._tag = UInt8(tag)

    comptime PURE = Purity(0)
    comptime STATELESS = Purity(1)
    comptime STATEFUL = Purity(2)

    def tag(self) -> UInt8:
        """The runtime-snapshotable discriminator (0=PURE, 1=STATELESS,
        2=STATEFUL)."""
        return self._tag

    def __eq__(self, other: Self) -> Bool:
        return self._tag == other._tag

    def __ne__(self, other: Self) -> Bool:
        return self._tag != other._tag

    def is_pure(self) -> Bool:
        """True iff the UDF is safe to constant-fold and push down freely."""
        return self._tag == 0

    def is_pushable(self) -> Bool:
        """True iff the UDF is safe to push down within a single query
        (PURE or STATELESS — everything except STATEFUL)."""
        return self._tag != 2
