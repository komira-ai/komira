# =============================================================================
# PhysicalType -- Parquet physical type tag for the StatsProvider trait
# =============================================================================
#
# Format-agnostic physical-type tag used by `StatsProvider.column_physical_type`.
# Mirrors the Parquet `Type` enum (`ParquetType` in
# komira_parquet_api/types.mojo) so a Parquet-backed `StatsProvider`
# implementation (none is in this tree) can return the same numeric tag the
# Parquet footer carries, but lives in `komira_plan_stats` so that plan-time
# consumers can inspect a column's physical layout without importing a Parquet
# package.
#
# Why a separate type rather than re-exporting `ParquetType`:
#   1. The StatsProvider trait is format-agnostic. A JSON or CSV
#      implementation would return a logical physical-type tag without any
#      Parquet dependency.
#   2. The plan packages (`komira_plan_expr`, `komira_plan_ir`,
#      `komira_plan_stats`) do not depend on a Parquet package (its file
#      reader transitively imports `std.io.FileHandle`, which was recorded
#      to hang the compile of a recursive-dispatch module importing the
#      plan). Keeping `PhysicalType` here preserves that layering.
#
# Tag values are chosen to numerically match `ParquetType` so that an
# implementation can `.unsafe_get_value()`-style cast at the boundary
# without a translation table -- but consumers MUST treat them as
# opaque (the trait's contract is the constants on this struct, not the
# integer values).
# =============================================================================


struct PhysicalType(ImplicitlyCopyable, Copyable, Equatable, Movable):
    """Format-agnostic physical-type tag for plan-time stats.

    Mirrors Parquet's `Type` enum. Constants intentionally use the same
    integer encoding as `parquet.types.ParquetType` so source-format
    implementations of `StatsProvider` can dispatch with a single
    integer compare. Consumers should compare against the named
    constants, not the integer values, so the encoding can change later
    without breaking callers.
    """

    var _value: UInt8

    @always_inline
    def __init__(out self, value: UInt8):
        self._value = value

    # Tag constants -- numerically aligned with ParquetType.
    comptime BOOLEAN = PhysicalType(UInt8(0))
    comptime INT32 = PhysicalType(UInt8(1))
    comptime INT64 = PhysicalType(UInt8(2))
    comptime INT96 = PhysicalType(UInt8(3))  # deprecated in Parquet, kept for parity
    comptime FLOAT = PhysicalType(UInt8(4))
    comptime DOUBLE = PhysicalType(UInt8(5))
    comptime BYTE_ARRAY = PhysicalType(UInt8(6))
    comptime FIXED_LEN_BYTE_ARRAY = PhysicalType(UInt8(7))

    @always_inline
    def value(self) -> UInt8:
        """Raw tag value. Prefer named comparisons (`pt == PhysicalType.INT32`)."""
        return self._value

    @always_inline
    def __eq__(self, other: PhysicalType) -> Bool:
        return self._value == other._value

    @always_inline
    def __ne__(self, other: PhysicalType) -> Bool:
        return self._value != other._value

    @always_inline
    def is_int(self) -> Bool:
        """True for INT32 / INT64 (covers the perfect-hash domain check)."""
        return self == PhysicalType.INT32 or self == PhysicalType.INT64

    @always_inline
    def is_float(self) -> Bool:
        """True for FLOAT / DOUBLE."""
        return self == PhysicalType.FLOAT or self == PhysicalType.DOUBLE
