# =============================================================================
# komira_test_rss reads the process's sizes on the platform the test runs on
# =============================================================================
#
# What each test proves:
#   * test_touched_pages_raise_the_resident_set_and_its_peak: after writing
#     one byte to each 4 KiB of a fresh 64 MiB block, the resident set has
#     grown by at least 32 MiB and by less than 128 MiB, and the peak is at
#     least the resident set before and after. Catches a reader that returns a
#     constant, the wrong field, or bytes or pages where KiB are meant (a unit
#     off by 1024 fails one bound or the other), and a peak that lags the
#     resident set.
#   * test_peak_virtual_is_read_on_linux_and_not_kept_on_macos: on Linux the
#     peak virtual size is a size at least the peak resident one; on macOS it
#     is None. Catches a platform that silently reports a sentinel as a size.
#   * test_a_negative_reading_is_refused_by_name: -1 and any other negative
#     value raise `RssUnreadable: <what>` exactly; 0 is a size.
#   * test_not_kept_is_none_and_the_rest_is_checked: -2 is None for the
#     optional reader; -1 still raises; a size passes through.
# =============================================================================

from std.collections.optional import Optional
from std.memory import alloc
from std.sys.info import CompilationTarget
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_test_rss.rss import (
    _checked,
    _kept,
    peak_resident_kib,
    peak_virtual_kib,
    resident_kib,
)

comptime _TOUCH_BYTES = 64 * 1024 * 1024
comptime _GROWTH_KIB = 32 * 1024


def test_touched_pages_raise_the_resident_set_and_its_peak() raises:
    var before = resident_kib()
    var peak_before = peak_resident_kib()
    assert_true(before > 0)
    assert_true(peak_before >= before)
    var p = alloc[UInt8](_TOUCH_BYTES)
    for i in range(0, _TOUCH_BYTES, 4096):
        p[i] = UInt8(1)
    var after = resident_kib()
    var peak_after = peak_resident_kib()
    var sum = 0
    for i in range(0, _TOUCH_BYTES, 4096):
        sum += Int(p[i])
    p.free()
    assert_equal(sum, _TOUCH_BYTES // 4096)
    assert_true(
        after - before >= _GROWTH_KIB,
        "resident set grew by " + String(after - before) + " KiB",
    )
    assert_true(
        after - before < 4 * _GROWTH_KIB,
        "resident set grew by " + String(after - before) + " KiB",
    )
    assert_true(peak_after >= after)


def test_peak_virtual_is_read_on_linux_and_not_kept_on_macos() raises:
    var v = peak_virtual_kib()
    comptime if CompilationTarget.is_macos():
        assert_false(Bool(v))
    else:
        assert_true(Bool(v))
        assert_true(v.value() >= peak_resident_kib())


def test_a_negative_reading_is_refused_by_name() raises:
    for bad in [Int64(-1), Int64(-7)]:
        try:
            _ = _checked(bad, "resident set")
            raise Error("a negative reading was taken as a size")
        except e:
            assert_equal(String(e), "RssUnreadable: resident set")
    assert_equal(_checked(Int64(0), "resident set"), 0)
    assert_equal(_checked(Int64(123), "resident set"), 123)


def test_not_kept_is_none_and_the_rest_is_checked() raises:
    assert_false(Bool(_kept(Int64(-2), "peak virtual size")))
    var v = _kept(Int64(5), "peak virtual size")
    assert_true(Bool(v))
    assert_equal(v.value(), 5)
    try:
        _ = _kept(Int64(-1), "peak virtual size")
        raise Error("-1 was taken as not kept")
    except e:
        assert_equal(String(e), "RssUnreadable: peak virtual size")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
