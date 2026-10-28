# =============================================================================
# MorselSizingPolicy unit tests (MORSEL-SIZE-HARDWARE-AUTO-DERIVE SS2)
# =============================================================================
#
# Slot dispatch: <date>, SS2 of MORSEL-SIZE-HARDWARE-AUTO-DERIVE.
# maintainer-ratified design memo: an internal agent note
#  ().
#
# Test plan (5 cases):
#   1. Formula correctness — synthetic HardwareProfile (L2-per-worker share
#      128 KiB -> a 64 KiB budget) + synthetic Schema (Int64-only, 8 bytes/row)
#      -> expected morsel rows per tier.
#   2. Tier multipliers — AGG = 1x, DEFAULT = 2x, BULK_SCAN = 8x; JOIN_PROBE
#      has stricter clamp.
#   3. Clamp boundaries — wide row (~800 B/row) hits MIN clamp; narrow row
#      (4 B/row) with bulk-scan tier hits MAX clamp.
#   4. Schema-driven adjustment — Int64 schema vs String-heavy schema
#      produce different morsel sizes.
#   5. EngineContext accessor wiring — `ctx.default_morsel_rows(schema)`
#      equals direct policy call (covered via direct policy invocation
#      since EngineContext spawns workers and is heavyweight; the wiring
#      is mechanical and tested at integration level via merge-gate).
#
# Style mirrors an internal test — TestSuite.discover_tests
# + per-case `def test_*() raises:` functions.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_host_profile.hardware import HardwareProfile
from komira_host_profile.morsel_sizing_policy import (
    MorselSizingPolicy,
    MORSEL_TIER_AGG,
    MORSEL_TIER_JOIN_PROBE,
    MORSEL_TIER_DEFAULT,
    MORSEL_TIER_BULK_SCAN,
    MIN_MORSEL_ROWS_DEFAULT,
    MIN_MORSEL_ROWS_JOIN_PROBE,
    MAX_MORSEL_ROWS_DEFAULT,
    MAX_MORSEL_ROWS_BULK_SCAN,
)


# -----------------------------------------------------------------------------
# Helpers -- schema factories + synthetic HardwareProfile builders.
# -----------------------------------------------------------------------------


def _narrow_i64_schema() -> Schema:
    """Single Int64 column (row_width = 8)."""
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, False))
    return sb.build()


def _narrow_i32_schema() -> Schema:
    """Single Int32 column (row_width = 4) — used for MAX-clamp edge case."""
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT32, False))
    return sb.build()


def _wide_100_i64_schema() -> Schema:
    """100 Int64 columns (row_width = 800) — used for MIN-clamp edge case."""
    var sb = SchemaBuilder()
    for i in range(100):
        sb.add_field(Field("c" + String(i), ArrowType.INT64, False))
    return sb.build()


def _string_heavy_schema() -> Schema:
    """5 String columns (row_width = 5 * 32 = 160)."""
    var sb = SchemaBuilder()
    for i in range(5):
        sb.add_field(Field("s" + String(i), ArrowType.STRING, False))
    return sb.build()


# ⚠ EVERY PROFILE BELOW SETS `l1d_cache_bytes` TO A VALUE THAT WOULD GIVE A
# DIFFERENT ANSWER THAN ITS L2 SHARE, AND THAT IS DELIBERATE. The sizing input
# is `effective_e_core_l2_per_worker()` and nothing else (the L1d arm and its
# `KOMIRA_HW_MORSEL_L2` gate were deleted when the L2 budget became
# the default). A fixture whose L1d and L2 share happen to agree would let that
# arm come back with every assertion here still green — so they are pinned
# apart, and a revert reds this file at the first `assert_equal`.


def _l2pw_128kb_profile() -> HardwareProfile:
    """L2 share = 512 KiB / 4 = 128 KiB per worker -> x0.5 -> 64 KiB budget.

    On an 8 B/row schema that is base = 8192. Its L1d (32 KiB) would have
    given 2048 under the deleted formula.
    """
    return HardwareProfile(
        4,                   # physical_cores
        4,                   # logical_cores
        32 * 1024,           # l1d_cache_bytes (NOT the sizing input)
        512 * 1024,          # l2_cache_bytes
        0,                   # l3_cache_bytes (Apple Silicon shape)
        64,                  # cache_line_bytes
        1 << 30,             # total_ram_bytes (1 GB)
        1 << 29,             # available_ram_bytes (512 MB)
        1,                   # numa_nodes
        0,                   # l1d_min_bytes (0 -> mirrors l1d_cache_bytes)
        512 * 1024,          # e_core_l2_bytes  <- THE sizing input
        4,                   # e_cores_per_l2   <- divided by this
    )


def _l2pw_32kb_profile() -> HardwareProfile:
    """L2 share = 128 KiB / 4 = 32 KiB per worker -> 16 KiB budget -> base 2048
    at 8 B/row. Its L1d (128 KiB) would have given 8192."""
    return HardwareProfile(
        4, 4, 128 * 1024, 128 * 1024, 0, 64, 1 << 30, 1 << 29, 1,
        0, 128 * 1024, 4,
    )


def _l2pw_huge_profile() -> HardwareProfile:
    """L2 share = 4 MiB / 1 -> 2 MiB budget — forces the MAX clamps.

    base = 524288 at 4 B/row, 262144 at 8 B/row. Its L1d (32 KiB) would have
    given 2048 and 1024."""
    return HardwareProfile(
        4, 4, 32 * 1024, 4 * 1024 * 1024, 0, 64, 1 << 30, 1 << 29, 1,
        0, 4 * 1024 * 1024, 1,
    )


# =============================================================================
# Test 1 -- formula correctness on l1d=128KB + i64 (8 B/row) schema
# =============================================================================
#
# Formula: morsel_rows(schema, tier) = clamp(
#     (l2_per_worker_bytes * 0.5) / row_width * tier_mult,
#     tier_min,
#     tier_max,
# )
#
# With l2_per_worker=128 KiB (budget 64 KiB), row_width=8 B:
#     base = (128*1024 / 2) / 8 = 8192 rows
#
# Per tier:
#     AGG        = 8192 * 1.0 = 8192 (within [1024, 131072])
#     JOIN_PROBE = 8192 * 1.0 = 8192 (within [4096, 131072])
#     DEFAULT    = 8192 * 2.0 = 16384 (within [1024, 131072])
#     BULK_SCAN  = 8192 * 8.0 = 65536 (within [1024, 524288])


def test_formula_agg_tier_l2pw_128kb_i64() raises:
    """AGG tier on l2pw=128 KiB + i64 = 8192 rows (base, no clamp engaged)."""
    var pol = MorselSizingPolicy(_l2pw_128kb_profile())
    var s = _narrow_i64_schema()
    assert_equal(pol.agg_morsel_rows(s), 8192)
    assert_equal(pol.morsel_rows(s, MORSEL_TIER_AGG), 8192)


def test_formula_join_probe_tier_l2pw_128kb_i64() raises:
    """JOIN_PROBE on l2pw=128 KiB + i64 = 8192 rows (above 4096 MIN clamp)."""
    var pol = MorselSizingPolicy(_l2pw_128kb_profile())
    var s = _narrow_i64_schema()
    assert_equal(pol.join_probe_morsel_rows(s), 8192)


def test_formula_default_tier_l2pw_128kb_i64() raises:
    """DEFAULT tier on l2pw=128 KiB + i64 = 8192 * 2 = 16384 rows."""
    var pol = MorselSizingPolicy(_l2pw_128kb_profile())
    var s = _narrow_i64_schema()
    assert_equal(pol.default_morsel_rows(s), 16384)


def test_formula_bulk_scan_tier_l2pw_128kb_i64() raises:
    """BULK_SCAN on l2pw=128 KiB + i64 = 8192 * 8 = 65536 rows."""
    var pol = MorselSizingPolicy(_l2pw_128kb_profile())
    var s = _narrow_i64_schema()
    assert_equal(pol.bulk_scan_morsel_rows(s), 65536)


# =============================================================================
# Test 2 -- tier multipliers visible across tiers
# =============================================================================
#
# Validates the multiplier ratios (1x : 1x : 2x : 8x) on a profile + schema
# combo that keeps every tier away from the clamp boundaries. With an L2 share
# of 128 KiB and i64 (8 B), base = 8192 — every tier is within bounds.


def test_tier_multiplier_ratios() raises:
    """AGG : DEFAULT = 1 : 2; AGG : BULK_SCAN = 1 : 8; AGG == JOIN_PROBE."""
    var pol = MorselSizingPolicy(_l2pw_128kb_profile())
    var s = _narrow_i64_schema()
    var agg = pol.agg_morsel_rows(s)
    var join = pol.join_probe_morsel_rows(s)
    var default = pol.default_morsel_rows(s)
    var bulk = pol.bulk_scan_morsel_rows(s)
    # AGG and JOIN_PROBE share the same base multiplier (1.0x); the
    # stricter MIN clamp only kicks in for tiny/wide schemas. Here both
    # are above the 4096 MIN_JOIN_PROBE floor.
    assert_equal(agg, join)
    assert_equal(default, agg * 2)
    assert_equal(bulk, agg * 8)


def test_join_probe_stricter_min_clamp() raises:
    """JOIN_PROBE has MIN=4096 vs DEFAULT/AGG MIN=1024 — visible on wide rows.

    100 i64 = 800 B/row + a 64 KiB budget:
        base = (128*1024 / 2) / 800 = 81 rows.
    AGG (mult 1.0): max(81, 1024) = 1024.
    JOIN_PROBE (mult 1.0): max(81, 4096) = 4096.
    """
    var pol = MorselSizingPolicy(_l2pw_128kb_profile())
    var wide = _wide_100_i64_schema()
    assert_equal(pol.agg_morsel_rows(wide), MIN_MORSEL_ROWS_DEFAULT)
    assert_equal(pol.join_probe_morsel_rows(wide), MIN_MORSEL_ROWS_JOIN_PROBE)


# =============================================================================
# Test 3 -- clamp boundaries (MIN engaged on wide row, MAX engaged on narrow)
# =============================================================================


def test_min_clamp_engages_on_wide_row() raises:
    """100 i64 = 800 B/row on a 64 KiB budget clamps to MIN at every tier.

    base = (128*1024/2) / 800 = 81 rows; multiplied by 1x/2x/8x stays
    well under 1024 so MIN clamp engages for AGG/DEFAULT/BULK_SCAN.
    JOIN_PROBE clamps to its stricter 4096 MIN.
    """
    var pol = MorselSizingPolicy(_l2pw_128kb_profile())
    var wide = _wide_100_i64_schema()
    assert_equal(pol.agg_morsel_rows(wide), MIN_MORSEL_ROWS_DEFAULT)
    assert_equal(pol.default_morsel_rows(wide), MIN_MORSEL_ROWS_DEFAULT)
    assert_equal(pol.bulk_scan_morsel_rows(wide), MIN_MORSEL_ROWS_DEFAULT)
    assert_equal(pol.join_probe_morsel_rows(wide), MIN_MORSEL_ROWS_JOIN_PROBE)


def test_max_clamp_engages_on_narrow_row_bulk_scan() raises:
    """l2pw=4 MiB + i32 (4 B/row) at BULK_SCAN tier clamps to MAX_BULK_SCAN.

    base = (4*1024*1024/2) / 4 = 524288 rows;
    BULK_SCAN (8x) = 4194304 rows -> clamps to MAX_MORSEL_ROWS_BULK_SCAN=524288.
    DEFAULT (2x) = 1048576 -> clamps to MAX_MORSEL_ROWS_DEFAULT=131072.
    """
    var pol = MorselSizingPolicy(_l2pw_huge_profile())
    var s = _narrow_i32_schema()
    assert_equal(pol.bulk_scan_morsel_rows(s), MAX_MORSEL_ROWS_BULK_SCAN)
    assert_equal(pol.default_morsel_rows(s), MAX_MORSEL_ROWS_DEFAULT)
    assert_equal(pol.agg_morsel_rows(s), MAX_MORSEL_ROWS_DEFAULT)


def test_max_clamp_default_tier_huge_l2pw_i64() raises:
    """l2pw=4 MiB + i64 (8 B/row) at DEFAULT tier clamps to MAX_DEFAULT.

    base = (4*1024*1024/2) / 8 = 262144;
    DEFAULT (2x) = 524288 -> clamps to MAX_MORSEL_ROWS_DEFAULT=131072.
    BULK_SCAN (8x) = 2097152 -> clamps to MAX_MORSEL_ROWS_BULK_SCAN=524288.
    """
    var pol = MorselSizingPolicy(_l2pw_huge_profile())
    var s = _narrow_i64_schema()
    assert_equal(pol.default_morsel_rows(s), MAX_MORSEL_ROWS_DEFAULT)
    assert_equal(pol.bulk_scan_morsel_rows(s), MAX_MORSEL_ROWS_BULK_SCAN)


# =============================================================================
# Test 4 -- schema-driven adjustment
# =============================================================================
#
# A narrow Int64 schema produces a larger morsel size than a string-heavy
# schema on the same hardware. This is the canonical win path the slot
# unlocks — currently every call site hardcodes a single value regardless
# of schema row-width.


def test_schema_driven_int64_vs_string_heavy() raises:
    """i64 (8 B) vs 5x String (160 B) on a 64 KiB budget, DEFAULT tier.

    i64:    base = 8192; DEFAULT = 16384.
    string: base = (128*1024/2) / 160 = 409 -> clamps to 1024 (MIN).
    """
    var pol = MorselSizingPolicy(_l2pw_128kb_profile())
    var narrow = _narrow_i64_schema()
    var wide_strs = _string_heavy_schema()
    var narrow_rows = pol.default_morsel_rows(narrow)
    var wide_rows = pol.default_morsel_rows(wide_strs)
    # narrow schema must produce a STRICTLY larger morsel
    assert_true(narrow_rows > wide_rows)
    # specific expected values
    assert_equal(narrow_rows, 16384)
    assert_equal(wide_rows, MIN_MORSEL_ROWS_DEFAULT)


def test_small_l2_share_narrow_i64() raises:
    """A 32 KiB L2 share (16 KiB budget) + i64 — the tight-share shape.

    base = (32*1024/2) / 8 = 2048; AGG = 2048; DEFAULT = 4096;
    BULK_SCAN = 16384; JOIN_PROBE = 4096 (MIN_JOIN_PROBE).
    """
    var pol = MorselSizingPolicy(_l2pw_32kb_profile())
    var s = _narrow_i64_schema()
    assert_equal(pol.agg_morsel_rows(s), 2048)
    assert_equal(pol.default_morsel_rows(s), 4096)
    assert_equal(pol.bulk_scan_morsel_rows(s), 16384)
    assert_equal(
        pol.join_probe_morsel_rows(s), MIN_MORSEL_ROWS_JOIN_PROBE
    )


# =============================================================================
# Test 5 -- factory constructors + direct policy invocation parity
# =============================================================================
#
# `MorselSizingPolicy.for_host` reads only the host profile it is given. The
# policy of a detected profile and of the fallback profile are tested in
# `komira_engine_runtime` (`test_host_detect`).


def test_morsel_rows_via_tier_constant_matches_accessor() raises:
    """`policy.morsel_rows(schema, MORSEL_TIER_X)` == per-tier accessor."""
    var pol = MorselSizingPolicy(_l2pw_128kb_profile())
    var s = _narrow_i64_schema()
    assert_equal(
        pol.morsel_rows(s, MORSEL_TIER_AGG), pol.agg_morsel_rows(s)
    )
    assert_equal(
        pol.morsel_rows(s, MORSEL_TIER_JOIN_PROBE),
        pol.join_probe_morsel_rows(s),
    )
    assert_equal(
        pol.morsel_rows(s, MORSEL_TIER_DEFAULT), pol.default_morsel_rows(s)
    )
    assert_equal(
        pol.morsel_rows(s, MORSEL_TIER_BULK_SCAN),
        pol.bulk_scan_morsel_rows(s),
    )


def test_unknown_tier_falls_back_to_default() raises:
    """An unrecognized tier value (255) falls back to DEFAULT (memo §4).

    Defensive behavior: the per-tier multiplier dispatch returns
    `TIER_MULT_DEFAULT` on any tag not in the known set.
    """
    var pol = MorselSizingPolicy(_l2pw_128kb_profile())
    var s = _narrow_i64_schema()
    var unknown_tag: UInt8 = 255
    assert_equal(
        pol.morsel_rows(s, unknown_tag), pol.default_morsel_rows(s)
    )


# =============================================================================
# Empty-schema defensive edge case
# =============================================================================


def test_empty_schema_does_not_divide_by_zero() raises:
    """Empty schema -> row_width_bytes() returns max(1, sum)=1; formula stays
    deterministic. With a 64 KiB budget and width=1: base = 65536; DEFAULT (2x)
    = 131072 -> hits MAX clamp.
    """
    var pol = MorselSizingPolicy(_l2pw_128kb_profile())
    var s = Schema()
    assert_equal(s.row_width_bytes(), 1)
    # base = 65536, DEFAULT (2x) = 131072, AGG (1x) = 65536.
    assert_equal(pol.agg_morsel_rows(s), 65536)
    assert_equal(pol.default_morsel_rows(s), MAX_MORSEL_ROWS_DEFAULT)


# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
