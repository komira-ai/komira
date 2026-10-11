# =============================================================================
# Counters unit tests
# =============================================================================
#
# Port of counter validation from v0.3. Tests:
#   1. Counters.now() returns non-negative values.
#   2. delta_from computes correct deltas.
#   3. Peak RSS is absolute (not delta) in delta_from.
#   4. Zero-initialized Counters() is all zeros.
#   5. Writable produces non-empty output.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_engine_runtime.counters import Counters


# --- Zero initialization ----------------------------------------------------

def test_zero_init() raises:
    """Default Counters() is all zeros."""
    var c = Counters()
    assert_equal(c.voluntary_ctx_switches, 0)
    assert_equal(c.involuntary_ctx_switches, 0)
    assert_equal(c.major_page_faults, 0)
    assert_equal(c.peak_rss_bytes, 0)
    assert_equal(c.user_time_us, 0)
    assert_equal(c.system_time_us, 0)


# --- now() returns sensible values ------------------------------------------

def test_now_nonnegative() raises:
    """Counters.now() fields are non-negative."""
    var c = Counters.now()
    assert_true(c.voluntary_ctx_switches >= 0, "vol_csw >= 0")
    assert_true(c.involuntary_ctx_switches >= 0, "invol_csw >= 0")
    assert_true(c.major_page_faults >= 0, "maj_flt >= 0")
    assert_true(c.peak_rss_bytes >= 0, "peak_rss >= 0")
    assert_true(c.user_time_us >= 0, "user_us >= 0")
    assert_true(c.system_time_us >= 0, "sys_us >= 0")


def test_now_has_positive_rss() raises:
    """A running process should have positive peak RSS."""
    var c = Counters.now()
    assert_true(c.peak_rss_bytes > 0, "peak_rss should be > 0 for a running process")


def test_now_has_realistic_rss() raises:
    """Peak RSS must be at least 1 MiB for a running Mojo process — guards
    against the v0.3-port linux regression where `ru_maxrss` is reported in
    KB but the field claims `_bytes`. Pre-fix on linux a 60 MB process
    would show `peak_rss_bytes = 60000` (off by 1024×); post-fix shows
    the correct ~60 MB. A Mojo AOT binary with the stdlib alone exceeds
    1 MiB resident, so this threshold is tight enough to catch the unit
    bug and loose enough to remain stable across platforms.
    Workstream C C.3."""
    var c = Counters.now()
    assert_true(
        c.peak_rss_bytes > 1024 * 1024,
        "peak_rss_bytes must exceed 1 MiB for any running Mojo process; "
        "got " + String(c.peak_rss_bytes) + " — likely the linux ru_maxrss "
        "unit bug (KB reported as bytes).",
    )


def test_now_has_user_time() raises:
    """A running process should have accumulated some user CPU time."""
    var c = Counters.now()
    assert_true(c.user_time_us > 0, "user_time_us should be > 0")


# --- delta_from --------------------------------------------------------------

def test_delta_from_basic() raises:
    """Delta_from computes correct arithmetic deltas."""
    var before = Counters(10, 5, 2, 1000, 100, 50)
    var after = Counters(15, 7, 3, 2000, 300, 150)
    var delta = after.delta_from(before)

    assert_equal(delta.voluntary_ctx_switches, 5)
    assert_equal(delta.involuntary_ctx_switches, 2)
    assert_equal(delta.major_page_faults, 1)
    assert_equal(delta.user_time_us, 200)
    assert_equal(delta.system_time_us, 100)


def test_delta_from_peak_rss_absolute() raises:
    """Peak_rss_bytes in delta is the 'after' value, not a difference.
    v0.3 counters.rs:38: peak is absolute, not delta."""
    var before = Counters(0, 0, 0, 1000, 0, 0)
    var after = Counters(0, 0, 0, 2000, 0, 0)
    var delta = after.delta_from(before)
    assert_equal(delta.peak_rss_bytes, 2000)


def test_delta_from_zero() raises:
    """Delta from identical snapshots is all zeros (except peak RSS)."""
    var c = Counters(10, 5, 2, 1000, 100, 50)
    var delta = c.delta_from(c)
    assert_equal(delta.voluntary_ctx_switches, 0)
    assert_equal(delta.involuntary_ctx_switches, 0)
    assert_equal(delta.major_page_faults, 0)
    assert_equal(delta.peak_rss_bytes, 1000)  # absolute
    assert_equal(delta.user_time_us, 0)
    assert_equal(delta.system_time_us, 0)


# --- Writable ----------------------------------------------------------------

def test_writable() raises:
    """Counters can be printed."""
    var c = Counters.now()
    var s = String(c)
    assert_true(s.byte_length() > 0, "str() should produce non-empty output")
    assert_true("Counters" in s, "output should contain 'Counters'")


# --- Entry point -------------------------------------------------------------

def main() raises:
    test_zero_init()
    test_now_nonnegative()
    test_now_has_positive_rss()
    test_now_has_realistic_rss()
    test_now_has_user_time()
    test_delta_from_basic()
    test_delta_from_peak_rss_absolute()
    test_delta_from_zero()
    test_writable()
    print("test_counters: 9 tests passed")
