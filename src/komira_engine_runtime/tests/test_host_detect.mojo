# =============================================================================
# test_host_detect -- measuring a host: the fallback profile, the probe and
# the host profile built from it
# =============================================================================
#
# What each test proves, and the defect it catches:
#   * the fallback profile carries the documented Apple-Silicon-shaped
#     constants and a core count of at least 1 (a fallback that sized work for
#     a machine with no cores);
#   * a policy over the fallback profile sizes off the 1 MiB per-worker L2
#     share the fallback records (a fallback that lost the E-cluster fields);
#   * the probe returns values that satisfy the basic invariants, and two
#     probes on one machine agree (a probe that kept state or returned a
#     nonsensical shape);
#   * `detect_host_profile` takes the thread count, memory budget and spill
#     tiers it is given, derives the first two from the hardware when they are
#     0, and two profiles detected on one machine size morsels identically.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_engine_runtime.hardware_detect import (
    default_hardware_profile,
    detect_hardware_profile,
)
from komira_engine_runtime.host_detect import detect_host_profile
from komira_host_profile.host_profile import SPILL_TIER_ALL
from komira_host_profile.morsel_sizing_policy import (
    MAX_MORSEL_ROWS_DEFAULT,
    MorselSizingPolicy,
)


def _narrow_i64_schema() -> Schema:
    """Single Int64 column (row_width = 8)."""
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, False))
    return sb.build()


# -----------------------------------------------------------------------------
# The fallback profile.
# -----------------------------------------------------------------------------


def test_default_profile_exact_values() raises:
    """The fallback profile carries each DEFAULT_* constant field for field."""
    var hw = default_hardware_profile()
    assert_true(hw.physical_cores >= 1)
    assert_true(hw.logical_cores >= hw.physical_cores)
    assert_equal(hw.l1d_cache_bytes, 32 * 1024)
    assert_equal(hw.l2_cache_bytes, 256 * 1024)
    assert_equal(hw.l3_cache_bytes, 8 * 1024 * 1024)
    assert_equal(hw.cache_line_bytes, 64)
    assert_true(hw.total_ram_bytes > 0)
    assert_true(hw.available_ram_bytes > 0)
    assert_equal(hw.numa_nodes, 1)




# -----------------------------------------------------------------------------
# Detection sanity.
# -----------------------------------------------------------------------------


def test_detect_returns_sane_values() raises:
    """On any supported platform, detected values must satisfy basic invariants."""
    var hw = detect_hardware_profile()
    assert_true(hw.physical_cores >= 1)
    assert_true(hw.logical_cores >= 1)
    assert_true(hw.l1d_cache_bytes > 0)
    assert_true(hw.l2_cache_bytes > 0)
    assert_true(hw.cache_line_bytes > 0)
    assert_true(hw.total_ram_bytes > 0)
    assert_true(hw.available_ram_bytes > 0)
    assert_true(hw.numa_nodes >= 1)
    # Available RAM must not exceed total RAM.
    assert_true(hw.available_ram_bytes <= hw.total_ram_bytes)


def test_detect_is_stable_across_calls() raises:
    """`detect_hardware_profile()` keeps no state, so two calls on one machine
    must yield the same field values: a host profile built from either is the
    same profile."""
    var a = detect_hardware_profile()
    var b = detect_hardware_profile()
    assert_equal(a.physical_cores, b.physical_cores)
    assert_equal(a.l1d_cache_bytes, b.l1d_cache_bytes)
    assert_equal(a.l2_cache_bytes, b.l2_cache_bytes)
    assert_equal(a.l3_cache_bytes, b.l3_cache_bytes)
    assert_equal(a.total_ram_bytes, b.total_ram_bytes)


def test_detect_honours_flags_and_derives_zero() raises:
    var fixed = detect_host_profile("b", 3, 12345, SPILL_TIER_ALL)
    assert_equal(fixed.thread_count, 3)
    assert_equal(fixed.memory_budget_bytes, 12345)
    assert_equal(fixed.spill_tiers, SPILL_TIER_ALL)
    var derived = detect_host_profile("b")
    assert_equal(derived.thread_count, derived.hardware.compute_threads())
    assert_true(derived.thread_count >= 1)
    assert_true(derived.memory_budget_bytes >= 1)


def test_policy_of_default_profile_sizes_off_the_fallback_share() raises:
    """A policy over `default_hardware_profile()` sizes off the Apple-Silicon-shaped E-cluster share.

    `default_hardware_profile()` carries DEFAULT_E_CORE_L2_BYTES = 4 MiB over
    DEFAULT_E_CORES_PER_L2 = 4 -> 1 MiB per worker -> 512 KiB budget -> base
    65536 at 8 B/row. AGG (1.0x) = 65536; DEFAULT (2.0x) = 131072, which is
    exactly MAX_MORSEL_ROWS_DEFAULT.
    """
    var pol = MorselSizingPolicy(default_hardware_profile())
    var s = _narrow_i64_schema()
    assert_equal(pol.agg_morsel_rows(s), 65536)
    assert_equal(pol.default_morsel_rows(s), MAX_MORSEL_ROWS_DEFAULT)


def test_for_host_detected_returns_stable_values() raises:
    """Policies of two host profiles detected on the same machine produce
    identical morsel sizes for the same schema: detection is read-only."""
    var pol_a = MorselSizingPolicy.for_host(detect_host_profile("b"))
    var pol_b = MorselSizingPolicy.for_host(detect_host_profile("b"))
    var s = _narrow_i64_schema()
    assert_equal(pol_a.agg_morsel_rows(s), pol_b.agg_morsel_rows(s))
    assert_equal(pol_a.default_morsel_rows(s), pol_b.default_morsel_rows(s))
    assert_equal(
        pol_a.bulk_scan_morsel_rows(s), pol_b.bulk_scan_morsel_rows(s)
    )
    assert_equal(
        pol_a.join_probe_morsel_rows(s), pol_b.join_probe_morsel_rows(s)
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
