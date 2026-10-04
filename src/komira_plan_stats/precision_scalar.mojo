# =============================================================================
# PrecisionScalar — three-valued statistic lattice
# =============================================================================
#
# Convergent with DataFusion's
# `Precision<T>` lattice (Exact/Inexact/Absent):
#   - EXACT  : value is known precisely (e.g. parquet footer min/max with a
#              row-group spanning the whole column; or a `count(*)` after
#              full materialization).
#   - INEXACT: value is an estimate (e.g. HLL-derived NDV; sampled min/max;
#              cardinality after a join with stats-DEP rules).
#   - ABSENT : stat not computed or not available (e.g. user opted out via
#              `compute_stats=False`; column type doesn't support the stat).
#
# Used by ColumnStats and the cardinality
# estimator. Pass-2 stats-DEP optimizer rules read the lattice tag before
# acting on the inner value to decide whether to optimize confidently
# (EXACT) vs heuristically (INEXACT) vs fall back to defaults (ABSENT).
# =============================================================================

from komira_plan_expr.scalar_value import ScalarValue


# Tag constants for the three-valued lattice.
comptime PRECISION_EXACT: UInt8 = 0
comptime PRECISION_INEXACT: UInt8 = 1
comptime PRECISION_ABSENT: UInt8 = 2


struct PrecisionScalar(Movable, Copyable, Deinitable):
    """Three-valued statistic lattice over `ScalarValue`.

    Convergent with DataFusion's `Precision<T>` enum. Wraps an
    `Optional[ScalarValue]` payload plus a `tag: UInt8` discriminator.

    Construction is via the three static factories `exact()`, `inexact()`,
    `absent()`. Inspection is via `is_exact()` / `is_inexact()` /
    `is_absent()` / `is_present()` predicates and `.value()` (only valid
    when present).
    """

    var tag: UInt8
    var value: Optional[ScalarValue]

    def __init__(out self, tag: UInt8, var value: Optional[ScalarValue]):
        self.tag = tag
        self.value = value^

    def copy(self) -> Self:
        # Optional.copy() deep-copies the inner ScalarValue (which has
        # its own explicit `.copy()`); ScalarValue.copy() handles the
        # owned String field.
        var v_copy: Optional[ScalarValue] = None
        if self.value:
            v_copy = Optional(self.value.value().copy())
        return Self(self.tag, v_copy^)

    @staticmethod
    def exact(var v: ScalarValue) -> PrecisionScalar:
        """Construct a precision-EXACT scalar."""
        return PrecisionScalar(PRECISION_EXACT, Optional(v^))

    @staticmethod
    def inexact(var v: ScalarValue) -> PrecisionScalar:
        """Construct a precision-INEXACT (estimate) scalar."""
        return PrecisionScalar(PRECISION_INEXACT, Optional(v^))

    @staticmethod
    def absent() -> PrecisionScalar:
        """Construct an ABSENT lattice point (stat unavailable)."""
        var none_v: Optional[ScalarValue] = None
        return PrecisionScalar(PRECISION_ABSENT, none_v^)

    @always_inline
    def is_exact(self) -> Bool:
        return self.tag == PRECISION_EXACT

    @always_inline
    def is_inexact(self) -> Bool:
        return self.tag == PRECISION_INEXACT

    @always_inline
    def is_absent(self) -> Bool:
        return self.tag == PRECISION_ABSENT

    @always_inline
    def is_present(self) -> Bool:
        """True if this is EXACT or INEXACT (i.e. has a value)."""
        return self.tag != PRECISION_ABSENT
