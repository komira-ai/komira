# =============================================================================
# Unit tests for HardwareProfile — v0.3 port (task #55, commit (ii))
# =============================================================================
#
# Mirrors the regression cases in `komira-engine-traits/src/hardware.rs`
# (tests module, lines 729-988). Only the formulas, fallback-shaped profiles
# and the width table are covered here; wiring into materialize_* and bench
# validation is in the (iii) follow-up. The fallback profile and detection
# are tested in `komira_engine_runtime` (`test_host_detect`).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_host_profile.hardware import (
    HardwareProfile,
    MAX_AGG_MORSEL_ROWS,
    MAX_MORSEL_ROWS,
    MIN_AGG_MORSEL_ROWS,
    MIN_MORSEL_ROWS,
    L3_FALLBACK_ROWS,
    DEFAULT_AVAILABLE_RAM,
    DEFAULT_CACHE_LINE,
    DEFAULT_E_CORE_L2_BYTES,
    DEFAULT_E_CORES_PER_L2,
    DEFAULT_L1D_BYTES,
    DEFAULT_L2_BYTES,
    DEFAULT_L3_BYTES,
    DEFAULT_P_CORE_L2_BYTES,
    DEFAULT_P_CORES_PER_L2,
    DEFAULT_TOTAL_RAM,
)


# -----------------------------------------------------------------------------
# Helpers -- local schema factories that mirror the shapes used in v0.3 tests.
# -----------------------------------------------------------------------------


def _narrow_i64_schema() -> Schema:
    """Single Int64 column (row_width = 8). Mirrors v0.3's `narrow`."""
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, False))
    return sb.build()


def _wide_100_i64_schema() -> Schema:
    """100 Int64 columns (row_width = 800). Mirrors v0.3's `wide`."""
    var sb = SchemaBuilder()
    for i in range(100):
        sb.add_field(Field("c" + String(i), ArrowType.INT64, False))
    return sb.build()


def _b2_schema() -> Schema:
    """BM-2 shape: 1 Int64 key + 1 Float64 measure (row_width = 16)."""
    var sb = SchemaBuilder()
    sb.add_field(Field("key", ArrowType.INT64, False))
    sb.add_field(Field("val", ArrowType.FLOAT64, False))
    return sb.build()


def _mixed_schema() -> Schema:
    """i64 + f64 + utf8. Mirrors v0.3's `test_row_width_bytes` case.

    Expected width: 8 + 8 + 32 = 48.
    """
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, False))
    sb.add_field(Field("b", ArrowType.FLOAT64, False))
    sb.add_field(Field("c", ArrowType.STRING, False))
    return sb.build()


# -----------------------------------------------------------------------------
# Width table -- mirrors `test_row_width_bytes` (hardware.rs:793-806).
# -----------------------------------------------------------------------------


def test_row_width_mixed_schema() raises:
    """Int64 + Float64 + Utf8 = 8 + 8 + 32 = 48."""
    var s = _mixed_schema()
    assert_equal(s.row_width_bytes(), 48)


def test_row_width_empty_schema_is_one() raises:
    """An empty schema clamps to `max(1, sum) = 1` -- no divide-by-zero."""
    var s = Schema()
    assert_equal(s.row_width_bytes(), 1)


def test_row_width_small_ints() raises:
    """Bool=1, Int8=1, Int16=2 -- small-int widths."""
    var sb = SchemaBuilder()
    sb.add_field(Field("b", ArrowType.BOOL, False))
    sb.add_field(Field("i8", ArrowType.INT8, False))
    sb.add_field(Field("i16", ArrowType.INT16, False))
    var s = sb.build()
    assert_equal(s.row_width_bytes(), 1 + 1 + 2)


def test_row_width_wide_fixed() raises:
    """Int32=4, Int64=8, Decimal128=16 -- wide fixed types."""
    var sb = SchemaBuilder()
    sb.add_field(Field("i32", ArrowType.INT32, False))
    sb.add_field(Field("i64", ArrowType.INT64, False))
    sb.add_field(Field("d128", ArrowType.DECIMAL128, False))
    var s = sb.build()
    assert_equal(s.row_width_bytes(), 4 + 8 + 16)


def test_row_width_varlen_all_32() raises:
    """Utf8, Binary, LargeUtf8, LargeBinary all cost 32 bytes each."""
    var sb = SchemaBuilder()
    sb.add_field(Field("s", ArrowType.STRING, False))
    sb.add_field(Field("b", ArrowType.BINARY, False))
    sb.add_field(Field("ls", ArrowType.LARGE_STRING, False))
    sb.add_field(Field("lb", ArrowType.LARGE_BINARY, False))
    var s = sb.build()
    assert_equal(s.row_width_bytes(), 32 * 4)


def test_row_width_dates_and_timestamps() raises:
    """Date32=4, Date64=8, Timestamp variants=8 each."""
    var sb = SchemaBuilder()
    sb.add_field(Field("d32", ArrowType.DATE32, False))
    sb.add_field(Field("d64", ArrowType.DATE64, False))
    sb.add_field(Field("ts", ArrowType.TIMESTAMP, False))
    sb.add_field(Field("ts_s", ArrowType.TIMESTAMP_S, False))
    sb.add_field(Field("ts_ms", ArrowType.TIMESTAMP_MS, False))
    sb.add_field(Field("ts_us", ArrowType.TIMESTAMP_US, False))
    sb.add_field(Field("ts_ns", ArrowType.TIMESTAMP_NS, False))
    var s = sb.build()
    # 4 + 8*6 = 52
    assert_equal(s.row_width_bytes(), 4 + 8 * 6)


# -----------------------------------------------------------------------------
# The fallback-shaped profile the formula tests read. It holds the DEFAULT_*
# constants of `hardware.mojo` and four cores; building it here keeps this
# package free of the probe that `komira_engine_runtime` runs.
# -----------------------------------------------------------------------------


def _fallback_profile() -> HardwareProfile:
    return HardwareProfile(
        4,
        4,
        DEFAULT_L1D_BYTES,
        DEFAULT_L2_BYTES,
        DEFAULT_L3_BYTES,
        DEFAULT_CACHE_LINE,
        DEFAULT_TOTAL_RAM,
        DEFAULT_AVAILABLE_RAM,
        1,
        DEFAULT_L1D_BYTES,
        DEFAULT_E_CORE_L2_BYTES,
        DEFAULT_E_CORES_PER_L2,
        DEFAULT_P_CORE_L2_BYTES,
        DEFAULT_P_CORES_PER_L2,
    )


def test_compute_threads_uses_all_cores() raises:
    """Mirrors hardware.rs:777-791 (edge cases)."""
    var hw = _fallback_profile()
    # physical_cores field is mutable via re-construction (struct is Copyable).
    var hw_one = HardwareProfile(
        1, 1, hw.l1d_cache_bytes, hw.l2_cache_bytes, hw.l3_cache_bytes,
        hw.cache_line_bytes, hw.total_ram_bytes, hw.available_ram_bytes, 1,
    )
    assert_equal(hw_one.compute_threads(), 1)
    var hw_four = HardwareProfile(
        4, 4, hw.l1d_cache_bytes, hw.l2_cache_bytes, hw.l3_cache_bytes,
        hw.cache_line_bytes, hw.total_ram_bytes, hw.available_ram_bytes, 1,
    )
    assert_equal(hw_four.compute_threads(), 4)
    var hw_sixteen = HardwareProfile(
        16, 16, hw.l1d_cache_bytes, hw.l2_cache_bytes, hw.l3_cache_bytes,
        hw.cache_line_bytes, hw.total_ram_bytes, hw.available_ram_bytes, 1,
    )
    assert_equal(hw_sixteen.compute_threads(), 16)
    # Zero cores -> clamps to 1.
    var hw_zero = HardwareProfile(
        0, 0, hw.l1d_cache_bytes, hw.l2_cache_bytes, hw.l3_cache_bytes,
        hw.cache_line_bytes, hw.total_ram_bytes, hw.available_ram_bytes, 1,
    )
    assert_equal(hw_zero.compute_threads(), 1)


# -----------------------------------------------------------------------------
# optimal_morsel_rows -- mirrors hardware.rs:809-834.
# -----------------------------------------------------------------------------


def test_optimal_morsel_rows_narrow_on_fallback_shaped_profile() raises:
    """256KB L2, 8-byte row: 128KB / 8 = 16384 rows (within clamp)."""
    var hw = _fallback_profile()
    var narrow = _narrow_i64_schema()
    assert_equal(hw.optimal_morsel_rows(narrow), 16384)


def test_optimal_morsel_rows_wide_clamps_min() raises:
    """100 i64 = 800 B/row: 128KB/800 = 163 -> clamped to MIN_MORSEL_ROWS."""
    var hw = _fallback_profile()
    var wide = _wide_100_i64_schema()
    assert_equal(hw.optimal_morsel_rows(wide), MIN_MORSEL_ROWS)


def test_optimal_morsel_rows_tiny_l2_clamps_min() raises:
    """Pathologically small L2 -> clamps to MIN_MORSEL_ROWS."""
    var hw = HardwareProfile(
        4, 4, 32 * 1024, 64, 0, 64, 1 << 30, 1 << 29, 1,
    )
    var narrow = _narrow_i64_schema()
    assert_equal(hw.optimal_morsel_rows(narrow), MIN_MORSEL_ROWS)


def test_optimal_morsel_rows_huge_l2_clamps_max() raises:
    """64MB L2 -> target = 32MB / 8 = 4M; clamps to MAX_MORSEL_ROWS."""
    var hw = HardwareProfile(
        4, 4, 32 * 1024, 64 * 1024 * 1024, 0, 64, 1 << 30, 1 << 29, 1,
    )
    var narrow = _narrow_i64_schema()
    assert_equal(hw.optimal_morsel_rows(narrow), MAX_MORSEL_ROWS)


# -----------------------------------------------------------------------------
# optimal_agg_morsel_rows -- mirrors hardware.rs:849-876.
# -----------------------------------------------------------------------------


def test_optimal_agg_morsel_rows_fallback_shaped_profile_clamp_min() raises:
    """L1d=32KB, 8-byte row: 16KB/8 = 2048 rows (exactly MIN_AGG_MORSEL_ROWS)."""
    var hw = _fallback_profile()
    var narrow = _narrow_i64_schema()
    assert_equal(hw.optimal_agg_morsel_rows(narrow), MIN_AGG_MORSEL_ROWS)


def test_optimal_agg_morsel_rows_m2_max_shape() raises:
    """L1d=128KB (M2 Max), 16-byte row: 64KB/16 = 4096 rows."""
    var hw = HardwareProfile(
        4, 4, 128 * 1024, 256 * 1024, 0, 64, 1 << 30, 1 << 29, 1,
    )
    var b2 = _b2_schema()
    assert_equal(hw.optimal_agg_morsel_rows(b2), 4096)


def test_optimal_agg_morsel_rows_wide_clamps_min() raises:
    """Wide schema (800 B/row) on default L1d: clamps to MIN_AGG_MORSEL_ROWS."""
    var hw = _fallback_profile()
    var wide = _wide_100_i64_schema()
    assert_equal(hw.optimal_agg_morsel_rows(wide), MIN_AGG_MORSEL_ROWS)


def test_optimal_agg_morsel_rows_huge_l1d_clamps_max() raises:
    """1MB L1d, 8-byte row: 512K/8 = 65536 -> clamps to MAX_AGG_MORSEL_ROWS."""
    var hw = HardwareProfile(
        4, 4, 1024 * 1024, 256 * 1024, 0, 64, 1 << 30, 1 << 29, 1,
    )
    var narrow = _narrow_i64_schema()
    assert_equal(hw.optimal_agg_morsel_rows(narrow), MAX_AGG_MORSEL_ROWS)


# -----------------------------------------------------------------------------
# l3_resident_rows -- mirrors hardware.rs:837-846.
# -----------------------------------------------------------------------------


def test_l3_resident_rows_fallback_shaped_profile() raises:
    """8MB L3, 60% = 4.8MB, 64-byte entries = 78643 (v0.3 test case)."""
    var hw = _fallback_profile()
    assert_equal(hw.l3_resident_rows(64), 78643)


def test_l3_resident_rows_no_l3_fallback() raises:
    """Apple Silicon (L3=0) -> L3_FALLBACK_ROWS regardless of entry size."""
    var hw = HardwareProfile(
        4, 4, 32 * 1024, 256 * 1024, 0, 64, 1 << 30, 1 << 29, 1,
    )
    assert_equal(hw.l3_resident_rows(64), L3_FALLBACK_ROWS)
    assert_equal(hw.l3_resident_rows(16), L3_FALLBACK_ROWS)


def test_l3_resident_rows_zero_entry_size_clamped() raises:
    """Defensive: entry_bytes=0 must not divide-by-zero."""
    var hw = _fallback_profile()
    # 8MB * 0.6 = 4.8MB / 1 = 5033164
    assert_equal(hw.l3_resident_rows(0), 8 * 1024 * 1024 * 6 // 10)


# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
