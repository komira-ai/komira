# =============================================================================
# Unit tests for detect_hardware_profile() — SS1 cross-platform completion
# =============================================================================
#
# Slot: MORSEL-SIZE-HARDWARE-AUTO-DERIVE SS1.
#
# Covers:
#   - On macOS (host runtime test): sysctl probe returns non-zero l1d,
#     non-zero physical_cores, l1d_min_bytes <= l1d_cache_bytes (heterogeneous
#     min ordering invariant).
#   - On any platform: detect() returns SOMETHING (PURE function — no exceptions).
#   - Defaults: defaults().l1d_min_bytes == l1d_cache_bytes (homogeneous shape).
#   - Constructor: 9-arg backward-compat sets l1d_min_bytes = l1d_cache_bytes.
#   - Constructor: 10-arg explicit sets l1d_min_bytes from the 10th argument.
#   - Constructor: 10-arg with 0 sentinel falls back to l1d_cache_bytes.
#   - Linux sysfs string parsers: "32K", "1024K", "1M", "32768", "32768\n"
#     all map to the expected byte counts.
#   - Min-nonzero helper: skip-zero behavior on three combinations.
#
# Detection invariant (test_detect_returns_sane_values_extended):
#   detect() returns a profile with:
#     - physical_cores >= 1
#     - l1d_cache_bytes > 0
#     - l1d_min_bytes > 0
#     - l1d_min_bytes <= l1d_cache_bytes (min cannot exceed max-of-clusters
#       since `l1d_cache_bytes` is the homogeneous probe result)
#
# Note on warn-and-fall-back: we can't directly simulate sysctl failure on
# a healthy macOS host, but the defaults() fall-back invariant is
# exercised on every Linux test (the macOS Mojo binary's Linux branch
# does NOT runtime-execute, but it must parse + compile).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_engine_runtime.hardware_detect import (
    default_hardware_profile,
    detect_hardware_profile,
    _parse_size_with_suffix,
    _min_nonzero3,
)
from komira_host_profile.hardware import (
    HardwareProfile,
    DEFAULT_L1D_BYTES,
    DEFAULT_L2_BYTES,
)

# ENGINE-SEV-1: `_parse_decimal_int` moved DOWN to core with the
# host RAM-basis probe. It is imported from its DEFINITION site rather than
# through `hardware.mojo`'s re-export, so this test cannot go green against a
# stale namespace re-export after the definition moves again.
from komira_host.proc_probe import _parse_decimal_int


# -----------------------------------------------------------------------------
# Constructor: 9-arg backward-compat ctor sets l1d_min_bytes = l1d_cache_bytes
# -----------------------------------------------------------------------------


def test_ctor_9_arg_back_compat_sets_l1d_min_to_l1d() raises:
    """The original 9-arg ctor (pre-SS1) sets `l1d_min_bytes` equal to
    `l1d_cache_bytes` so existing callers see a sane non-zero value
    matching homogeneous-silicon semantics."""
    var hw = HardwareProfile(
        4,                 # physical_cores
        4,                 # logical_cores
        64 * 1024,         # l1d_cache_bytes
        512 * 1024,        # l2_cache_bytes
        0,                 # l3_cache_bytes
        64,                # cache_line_bytes
        1 << 30,           # total_ram_bytes
        1 << 29,           # available_ram_bytes
        1,                 # numa_nodes
    )
    assert_equal(hw.l1d_cache_bytes, 64 * 1024)
    assert_equal(hw.l1d_min_bytes, 64 * 1024)


def test_ctor_10_arg_explicit_l1d_min() raises:
    """The 10-arg ctor sets `l1d_min_bytes` from the 10th argument when > 0."""
    var hw = HardwareProfile(
        4, 4,
        192 * 1024,        # l1d_cache_bytes (P-core)
        512 * 1024,
        0, 64, 1 << 30, 1 << 29, 1,
        128 * 1024,        # l1d_min_bytes (E-core)
    )
    assert_equal(hw.l1d_cache_bytes, 192 * 1024)
    assert_equal(hw.l1d_min_bytes, 128 * 1024)
    assert_true(hw.l1d_min_bytes <= hw.l1d_cache_bytes)


def test_ctor_10_arg_zero_sentinel_falls_back() raises:
    """l1d_min_bytes=0 is the sentinel meaning "homogeneous"; the ctor must
    set l1d_min_bytes = l1d_cache_bytes in that case."""
    var hw = HardwareProfile(
        4, 4, 96 * 1024, 256 * 1024, 0, 64, 1 << 30, 1 << 29, 1,
        0,  # l1d_min_bytes sentinel
    )
    assert_equal(hw.l1d_min_bytes, 96 * 1024)


# -----------------------------------------------------------------------------
# Defaults: l1d_min_bytes == DEFAULT_L1D_BYTES
# -----------------------------------------------------------------------------


def test_defaults_l1d_min_equals_default_l1d() raises:
    """`defaults()` is the warn-and-fall-back result; on homogeneous Apple-
    Silicon-shaped defaults, l1d_min_bytes == DEFAULT_L1D_BYTES."""
    var hw = default_hardware_profile()
    assert_equal(hw.l1d_min_bytes, DEFAULT_L1D_BYTES)
    assert_equal(hw.l1d_cache_bytes, DEFAULT_L1D_BYTES)


# -----------------------------------------------------------------------------
# detect(): host probe returns sane values + l1d_min ordering invariant
# -----------------------------------------------------------------------------


def test_detect_returns_sane_values_extended() raises:
    """On any supported platform, detect() returns a profile with non-zero
    cache + RAM fields, and l1d_min_bytes does not exceed l1d_cache_bytes.

    On a macOS M3 Ultra host we expect:
      - l1d_cache_bytes == 196608  (P-core, 192 KB)
      - l1d_min_bytes   == 131072  (E-core min, 128 KB)
    On homogeneous Intel Macs or sysctl-blocked fallback:
      - l1d_cache_bytes >= 32 KB
      - l1d_min_bytes   == l1d_cache_bytes
    """
    var hw = detect_hardware_profile()
    assert_true(hw.physical_cores >= 1)
    assert_true(hw.logical_cores >= 1)
    assert_true(hw.l1d_cache_bytes > 0)
    assert_true(hw.l1d_min_bytes > 0)
    # CRITICAL ordering invariant: min-of-cluster cannot exceed the
    # canonical probe result (since `l1d_cache_bytes` on Apple Silicon
    # is the P-core value, the larger cluster).
    assert_true(hw.l1d_min_bytes <= hw.l1d_cache_bytes)
    assert_true(hw.l2_cache_bytes > 0)
    assert_true(hw.cache_line_bytes > 0)
    assert_true(hw.total_ram_bytes > 0)


def test_detect_is_pure_two_calls_same_result() raises:
    """`detect()` is a PURE function (no caching, no module state). Two
    consecutive calls on a stable machine return identical field values.

    This is the SS1 purity contract: caller (SS2 EngineContext) is the
    one responsible for caching the result; `detect()` itself runs the
    full FFI probe each call.
    """
    var a = detect_hardware_profile()
    var b = detect_hardware_profile()
    assert_equal(a.physical_cores, b.physical_cores)
    assert_equal(a.logical_cores, b.logical_cores)
    assert_equal(a.l1d_cache_bytes, b.l1d_cache_bytes)
    assert_equal(a.l1d_min_bytes, b.l1d_min_bytes)
    assert_equal(a.l2_cache_bytes, b.l2_cache_bytes)
    assert_equal(a.l3_cache_bytes, b.l3_cache_bytes)


# -----------------------------------------------------------------------------
# Heterogeneous-core min behavior
# -----------------------------------------------------------------------------


def test_heterogeneous_l1d_min_below_l1d_cache_bytes() raises:
    """When constructed with `l1d_min_bytes < l1d_cache_bytes` (the
    canonical heterogeneous shape: M3 Ultra P=192KB, E=128KB), the field
    must preserve the strict-less-than relationship for downstream
    morsel-size formulas (SS2 uses l1d_min_bytes / 2 / row_width)."""
    var hw_m3_ultra = HardwareProfile(
        24, 24,
        192 * 1024,        # P-core L1d
        16 * 1024 * 1024,  # P-cluster L2 (16 MB shared per cluster)
        0,                 # No traditional L3 on Apple Silicon
        128, 1 << 35, 1 << 34, 1,
        128 * 1024,        # l1d_min (E-core)
    )
    assert_true(hw_m3_ultra.l1d_min_bytes < hw_m3_ultra.l1d_cache_bytes)
    # The min would gate auto-derived morsel size at SS2 wiring time.
    assert_equal(hw_m3_ultra.l1d_min_bytes // 2, 64 * 1024)


# -----------------------------------------------------------------------------
# Warn-and-fall-back failure mode
# -----------------------------------------------------------------------------


def test_defaults_is_the_fallback_shape() raises:
    """When `detect()` falls back due to a probe failure (sysctl blocked
    on a hardened mac sandbox; sysfs missing in a hardened container), it
    returns `defaults()`. This test exercises the FALLBACK SHAPE without
    requiring us to inject an FFI failure: the contract is that the
    fallback equals `defaults()`.

    Field invariants on the fallback (Apple-Silicon-shaped):
      - physical_cores >= 1 (clamped from num_physical_cores())
      - l1d_cache_bytes == 32 KB (DEFAULT_L1D_BYTES)
      - l1d_min_bytes == 32 KB (homogeneous fallback shape)
      - l2_cache_bytes == 256 KB (DEFAULT_L2_BYTES)
      - numa_nodes == 1

    Note: `detect()` raises NOTHING — the warn-and-fall-back contract is
    that it ALWAYS returns a valid `HardwareProfile`. This means a
    consumer can call `detect_hardware_profile()` from any context
    (including a notebook with a restricted sandbox) and proceed; the
    one-line stderr warning is the triage signal.
    """
    var fb = default_hardware_profile()
    assert_true(fb.physical_cores >= 1)
    assert_equal(fb.l1d_cache_bytes, DEFAULT_L1D_BYTES)
    assert_equal(fb.l1d_min_bytes, DEFAULT_L1D_BYTES)
    assert_equal(fb.l2_cache_bytes, DEFAULT_L2_BYTES)
    assert_equal(fb.numa_nodes, 1)
    # Defaults must not raise; the contract is total.
    var roundtrip = default_hardware_profile()
    assert_equal(roundtrip.l1d_cache_bytes, fb.l1d_cache_bytes)


# -----------------------------------------------------------------------------
# Writable shape includes l1d_min field
# -----------------------------------------------------------------------------


def test_write_to_includes_l1d_min() raises:
    """The `Writable` implementation must include `l1d_min=...` so users
    debugging morsel sizing can see the heterogeneous-aware value."""
    var hw = HardwareProfile(
        4, 4, 192 * 1024, 256 * 1024, 0, 64, 1 << 30, 1 << 29, 1, 128 * 1024,
    )
    var rendered = String(hw)
    # The exact format is in `HardwareProfile.write_to`; we assert the
    # key substrings are present.
    assert_true(_contains(rendered, "l1d_min"))
    assert_true(_contains(rendered, "131072"))
    assert_true(_contains(rendered, "physical_cores"))


# -----------------------------------------------------------------------------
# Linux sysfs string parser — used by `_linux_read_cpu_cache_sizes`
# -----------------------------------------------------------------------------


def test_parse_size_with_suffix_decimal() raises:
    """Bare decimal: "32768" -> 32768 bytes (no suffix)."""
    assert_equal(_parse_size_with_suffix(String("32768")), 32768)


def test_parse_size_with_suffix_kibi() raises:
    """K suffix means kibibytes per Linux kernel docs."""
    assert_equal(_parse_size_with_suffix(String("32K")), 32 * 1024)
    assert_equal(_parse_size_with_suffix(String("1024K")), 1024 * 1024)


def test_parse_size_with_suffix_mebi() raises:
    """M suffix means mebibytes."""
    assert_equal(_parse_size_with_suffix(String("1M")), 1024 * 1024)
    assert_equal(_parse_size_with_suffix(String("16M")), 16 * 1024 * 1024)


def test_parse_size_with_suffix_lowercase_suffix() raises:
    """Sysfs uses uppercase but be lenient on case."""
    assert_equal(_parse_size_with_suffix(String("32k")), 32 * 1024)


def test_parse_size_with_suffix_empty_zero() raises:
    """Empty string + zero-only -> 0 sentinel."""
    assert_equal(_parse_size_with_suffix(String("")), 0)
    assert_equal(_parse_size_with_suffix(String("0")), 0)
    assert_equal(_parse_size_with_suffix(String("abc")), 0)


def test_parse_decimal_int_basic() raises:
    """Leading-digits parser stops at first non-digit."""
    assert_equal(_parse_decimal_int(String("123")), 123)
    assert_equal(_parse_decimal_int(String("42abc")), 42)
    assert_equal(_parse_decimal_int(String("")), 0)
    assert_equal(_parse_decimal_int(String("abc")), 0)


# -----------------------------------------------------------------------------
# _min_nonzero3 helper — heterogeneous L1d min logic
# -----------------------------------------------------------------------------


def test_min_nonzero3_all_nonzero() raises:
    """Standard heterogeneous case: P + E + fallback all set, pick min."""
    # M3 Ultra: P-core=131072, E-core=65536, hw.l1dcachesize=65536
    assert_equal(_min_nonzero3(131072, 65536, 65536), 65536)
    # M2 Max: P-core=131072, E-core=65536, hw.l1dcachesize=131072
    assert_equal(_min_nonzero3(131072, 65536, 131072), 65536)


def test_min_nonzero3_homogeneous_intel_mac() raises:
    """Intel Mac: no perflevel keys; only hw.l1dcachesize set."""
    assert_equal(_min_nonzero3(0, 0, 32768), 32768)


def test_min_nonzero3_perflevel0_only() raises:
    """perflevel0 set, perflevel1 absent (single-cluster Apple Silicon)."""
    assert_equal(_min_nonzero3(131072, 0, 131072), 131072)


def test_min_nonzero3_all_zero() raises:
    """All probes failed -> returns 0 (caller must handle)."""
    assert_equal(_min_nonzero3(0, 0, 0), 0)


def test_min_nonzero3_fallback_smaller_than_perflevel() raises:
    """Defensive: even if fallback (3rd arg) is smaller, the min wins."""
    assert_equal(_min_nonzero3(131072, 65536, 32768), 32768)


# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------


def _contains(haystack: String, needle: String) -> Bool:
    """Substring helper for the rendered-string assertions above."""
    var p_len = needle.byte_length()
    var h_len = haystack.byte_length()
    if p_len > h_len:
        return False
    if p_len == 0:
        return True
    var hb = haystack.as_bytes()
    var nb = needle.as_bytes()
    var stop = h_len - p_len
    var i = 0
    while i <= stop:
        var ok = True
        var j = 0
        while j < p_len:
            if hb[i + j] != nb[j]:
                ok = False
                break
            j += 1
        if ok:
            return True
        i += 1
    return False


# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
