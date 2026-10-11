# =============================================================================
# E-CORE-L2 HW MORSEL SIZING unit tests
# =============================================================================
#
# PERF-PRIMITIVE + PERF-READ-6.
# maintainer decision (FINAL): size the morsel for the E-CORE
# L2-per-worker budget (perflevel1.l2cachesize / perflevel1.cpusperl2 x 0.5)
# so the morsel is residency-safe on EVERY core (macOS cannot pin threads).
#
# Design: an internal doc
#
# Covers:
#   1. HardwareProfile carries the four new E/P L2 topology fields; the
#      backward-compatible ctor defaults them to 0 ("unread").
#   2. `effective_e_core_l2_per_worker()` = e_core_l2_bytes / cpusperl2 with
#      the conservative fallback chain (0 -> l2_cache_bytes -> default;
#      divisor < 1 -> 1).
#   3. `defaults()` populates the new fields with the Apple-Silicon-shaped
#      E-cluster shape (4 MiB / 4 -> 1 MiB per worker).
#   4. `detect()` on this macOS host reads sane (>0) E-core L2 + cpusperl2
#      and the budget accessor returns a positive per-worker byte share.
#   5. The budget ARITHMETIC: the E-core L2 budget is much larger than the
#      E-core-L1d one for narrow-key agg schemas, pinned against a fixed
#      M3-Ultra-shaped profile so it cannot regress.
#   6. THE SHIPPED DEFAULT: `MorselSizingPolicy.agg_morsel_rows` actually
#      RETURNS the L2-derived number, with no environment in play. Test 5 is
#      arithmetic on the profile; test 6 is the policy, and it is the one that
#      goes red if the deleted `KOMIRA_HW_MORSEL_L2` L1d arm comes back.
# (the L2 formula was behind that env gate, default OFF,
#      and nothing in this file could tell which arm shipped.)
#
# Style mirrors tests/unit/test_hardware_profile_detect.mojo +
# tests/unit/test_morsel_sizing_policy.mojo.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_engine_runtime.hardware_detect import detect_hardware_profile
from komira_engine_runtime.hardware import (
    HardwareProfile,
    DEFAULT_E_CORE_L2_BYTES,
    DEFAULT_E_CORES_PER_L2,
    E_CORE_L2_BUDGET_NUM,
    E_CORE_L2_BUDGET_DEN,
)
from komira_engine_runtime.morsel_sizing_policy import (
    MorselSizingPolicy,
    MAX_MORSEL_ROWS_DEFAULT,
)


# -----------------------------------------------------------------------------
# Helpers — synthetic profiles + schema factories.
# -----------------------------------------------------------------------------


def _narrow_i64_schema() -> Schema:
    """Single Int64 column (row_width = 8)."""
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, False))
    return sb.build()


def _m3_ultra_profile() -> HardwareProfile:
    """M3-Ultra-shaped profile with the REAL sysctl values.

    l1d homogeneous = 64 KiB (E-core, the trap the OFF formula hits);
    E-core L2 = 4 MiB shared by 4 E-cores; P-core L2 = 16 MiB shared by 6.
    """
    return HardwareProfile(
        32,                # physical_cores
        32,                # logical_cores
        65536,             # l1d_cache_bytes (homogeneous = E-core 64 KiB)
        4 * 1024 * 1024,   # l2_cache_bytes (homogeneous = E-core 4 MiB)
        0,                 # l3_cache_bytes (no L3 on Apple Silicon)
        128,               # cache_line_bytes
        1 << 35,           # total_ram_bytes
        1 << 34,           # available_ram_bytes
        1,                 # numa_nodes
        65536,             # l1d_min_bytes (E-core)
        4 * 1024 * 1024,   # e_core_l2_bytes (perflevel1.l2cachesize)
        4,                 # e_cores_per_l2  (perflevel1.cpusperl2)
        16 * 1024 * 1024,  # p_core_l2_bytes (perflevel0.l2cachesize)
        6,                 # p_cores_per_l2  (perflevel0.cpusperl2)
    )


# =============================================================================
# Test 1 — backward-compatible ctor defaults the new fields to 0
# =============================================================================


def test_ctor_back_compat_defaults_new_fields_to_zero() raises:
    """The pre-E-core ctor (10-arg, up to l1d_min_bytes) leaves the four new
    L2 topology fields at 0 ("unread") — so every existing positional
    callsite compiles unchanged and the budget accessor falls back."""
    var hw = HardwareProfile(
        4, 4, 65536, 4 * 1024 * 1024, 0, 128, 1 << 30, 1 << 29, 1, 65536,
    )
    assert_equal(hw.e_core_l2_bytes, 0)
    assert_equal(hw.e_cores_per_l2, 0)
    assert_equal(hw.p_core_l2_bytes, 0)
    assert_equal(hw.p_cores_per_l2, 0)


# =============================================================================
# Test 2 — effective_e_core_l2_per_worker() arithmetic + fallback chain
# =============================================================================


def test_budget_accessor_m3_ultra_values() raises:
    """E-core L2 = 4 MiB / cpusperl2 = 4 -> 1 MiB per worker."""
    var hw = _m3_ultra_profile()
    assert_equal(hw.effective_e_core_l2_per_worker(), 1024 * 1024)


def test_budget_accessor_falls_back_to_homogeneous_l2_when_ecore_absent(
) raises:
    """When `e_core_l2_bytes == 0` (perflevel key absent), the accessor falls
    back to `l2_cache_bytes` (itself the E-core value on Apple Silicon).
    With cpusperl2 == 0 the divisor falls back to 1 -> whole-L2 budget."""
    var hw = HardwareProfile(
        4, 4, 65536, 4 * 1024 * 1024, 0, 128, 1 << 30, 1 << 29, 1, 65536,
    )
    # e_core_l2_bytes == 0 -> use l2_cache_bytes (4 MiB); divisor 0 -> 1.
    assert_equal(hw.effective_e_core_l2_per_worker(), 4 * 1024 * 1024)


def test_budget_accessor_divisor_clamps_to_one() raises:
    """A degenerate cpusperl2 (0 or negative) is treated as 1 — never a
    divide-by-zero, never a negative budget."""
    var hw = HardwareProfile(
        4, 4, 65536, 4 * 1024 * 1024, 0, 128, 1 << 30, 1 << 29, 1, 65536,
        8 * 1024 * 1024,  # e_core_l2_bytes
        0,                # e_cores_per_l2 (degenerate)
    )
    assert_equal(hw.effective_e_core_l2_per_worker(), 8 * 1024 * 1024)


def test_budget_accessor_pathological_zero_l2_uses_default() raises:
    """If both e_core_l2_bytes AND l2_cache_bytes are 0 (pathological), the
    accessor uses DEFAULT_E_CORE_L2_BYTES so the budget is never 0."""
    var hw = HardwareProfile(
        4, 4, 65536, 0, 0, 128, 1 << 30, 1 << 29, 1, 65536,
    )
    # e_core_l2 == 0 -> l2 == 0 -> DEFAULT_E_CORE_L2_BYTES; divisor 0 -> 1.
    assert_equal(
        hw.effective_e_core_l2_per_worker(), DEFAULT_E_CORE_L2_BYTES
    )


# =============================================================================
# Test 3 — defaults() populates the Apple-Silicon E-cluster shape
# =============================================================================


def test_defaults_populates_ecore_l2_fields() raises:
    """`defaults()` carries the E-cluster shape: 4 MiB / 4 -> 1 MiB per
    worker, so the budget accessor is sane even on the fall-back path."""
    var fb = HardwareProfile.defaults()
    assert_equal(fb.e_core_l2_bytes, DEFAULT_E_CORE_L2_BYTES)
    assert_equal(fb.e_cores_per_l2, DEFAULT_E_CORES_PER_L2)
    assert_equal(
        fb.effective_e_core_l2_per_worker(),
        DEFAULT_E_CORE_L2_BYTES // DEFAULT_E_CORES_PER_L2,
    )


# =============================================================================
# Test 4 — detect() reads sane real values on this macOS host
# =============================================================================


def test_detect_reads_sane_ecore_l2_on_host() raises:
    """On a healthy macOS host, detect() must read a positive E-core L2 and
    cpusperl2, and the budget accessor must return a positive per-worker
    byte share. On a homogeneous host (Intel Mac) the perflevel keys are
    absent (0) and the accessor falls back to l2_cache_bytes — still > 0."""
    var hw = detect_hardware_profile()
    # The budget is always > 0 (fallback chain guarantees it).
    assert_true(hw.effective_e_core_l2_per_worker() > 0)
    # On heterogeneous Apple Silicon the perflevel1 keys are present (> 0).
    # We do NOT hard-assert the exact value (machine-portable test) but the
    # budget must be at least 256 KiB (DEFAULT_L2_BYTES floor) on any host.
    assert_true(hw.effective_e_core_l2_per_worker() >= 256 * 1024)


# =============================================================================
# Test 5 — budget math feeds a larger morsel than the E-core-L1d OFF path
# =============================================================================


def test_ecore_l2_budget_exceeds_l1d_budget_for_narrow_key() raises:
    """The E-core L2 budget yields a larger base than the retired L1d one.

    For a narrow i64 agg key (8 B/row) on M3 Ultra:
      retired:  (l1d 64 KiB / 2) / 8     = 4096 rows  (base)
      shipped:  (e-L2pw 1 MiB x 0.5) / 8 = 65536 rows (base)

    A ~16x larger base for the narrow key — the cache-residency headroom the
    dict-vector working set needs. This pins the budget ARITHMETIC only;
    `test_shipped_policy_uses_the_l2_budget` pins which one the policy
    actually returns."""
    var hw = _m3_ultra_profile()
    var s = _narrow_i64_schema()
    var row_w = s.row_width_bytes()
    assert_equal(row_w, 8)

    # OFF-path base (the original L1d formula).
    var off_base = (hw.l1d_cache_bytes // 2) // row_w
    assert_equal(off_base, 4096)

    # ON-path base (E-core L2 budget x 0.5).
    var l2pw = hw.effective_e_core_l2_per_worker()
    var budget = (l2pw * E_CORE_L2_BUDGET_NUM) // E_CORE_L2_BUDGET_DEN
    var on_base = budget // row_w
    assert_equal(on_base, 65536)

    assert_true(on_base > off_base)


# =============================================================================
# Test 6 — THE SHIPPED DEFAULT. No environment; the policy itself.
# =============================================================================


def test_shipped_policy_uses_the_l2_budget() raises:
    """`MorselSizingPolicy` returns the L2-derived rows, not the L1d-derived
    ones, with NO env var involved.

    This is the falsifier for the default: `KOMIRA_HW_MORSEL_L2`
    and the L1d arm are DELETED, so on the M3-Ultra-shaped profile the AGG
    tier must be 65536 (budget 512 KiB / 8 B) and must NOT be 4096 (the
    retired (64 KiB / 2) / 8). The two differ by 16x on this fixture, which is
    what makes the assertion able to tell them apart at all.

    Deliberately env-free: there is no gate left to set, and a test that set
    one would be pinning a knob instead of the behaviour."""
    var pol = MorselSizingPolicy(_m3_ultra_profile())
    var s = _narrow_i64_schema()
    var hw = _m3_ultra_profile()
    var l1d_base = (hw.l1d_cache_bytes // 2) // s.row_width_bytes()
    assert_equal(l1d_base, 4096)

    assert_equal(pol.agg_morsel_rows(s), 65536)
    assert_true(pol.agg_morsel_rows(s) != l1d_base)
    # DEFAULT is 2.0x the same base -> 131072, i.e. exactly the MAX clamp.
    assert_equal(pol.default_morsel_rows(s), MAX_MORSEL_ROWS_DEFAULT)


# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
