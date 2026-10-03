# S3FsOptions: what an S3Fs decides beyond its store's S3Config, every field
# a constructor parameter with S3's standard as the default, and no setting
# read from the environment (test_no_env_reads scans s3_fs.mojo with the
# rest of the package).
#
# Rows: the defaults (every range of a call in flight, depth 64) and
# `standard()` agreeing with them; the in-flight window a call of N ranges
# gets: N with no bound, the bound when it is smaller, N when the bound is
# larger, never below 1 (a call of zero ranges); the window is a function of
# the options and N alone (the same answer every time) and is monotone in N
# and in the bound; the refusals (a negative bound, a depth below 1), each
# naming the setting; the options are values (a copy is independent).
from std.testing import assert_equal, assert_raises, assert_true

from komira_objectstore.store import PREFETCH_DEPTH_S3_STANDARD
from komira_objectstore_s3 import S3FsOptions, S3_FS_ALL_RANGES


def test_defaults() raises:
    var o = S3FsOptions()
    assert_equal(o.prefetch_max_inflight, S3_FS_ALL_RANGES)
    assert_equal(o.prefetch_max_inflight, 0)
    assert_equal(o.prefetch_depth, PREFETCH_DEPTH_S3_STANDARD)
    assert_equal(o.prefetch_depth, 64)
    var s = S3FsOptions.standard()
    assert_equal(s.prefetch_max_inflight, o.prefetch_max_inflight)
    assert_equal(s.prefetch_depth, o.prefetch_depth)


def test_no_bound_is_every_range() raises:
    var o = S3FsOptions()
    assert_equal(o.prefetch_window(1), 1)
    assert_equal(o.prefetch_window(7), 7)
    assert_equal(o.prefetch_window(500), 500)


def test_a_bound_below_the_ranges_wins() raises:
    var o = S3FsOptions(prefetch_max_inflight=8)
    assert_equal(o.prefetch_window(16), 8)
    assert_equal(o.prefetch_window(9), 8)
    assert_equal(o.prefetch_window(8), 8)


def test_a_bound_above_the_ranges_is_the_ranges() raises:
    var o = S3FsOptions(prefetch_max_inflight=16)
    assert_equal(o.prefetch_window(3), 3)
    assert_equal(S3FsOptions(prefetch_max_inflight=1).prefetch_window(3), 1)


def test_never_below_one() raises:
    assert_equal(S3FsOptions().prefetch_window(0), 1)
    assert_equal(S3FsOptions(prefetch_max_inflight=4).prefetch_window(0), 1)


def test_the_window_is_deterministic() raises:
    var o = S3FsOptions(prefetch_max_inflight=5)
    var first = o.prefetch_window(12)
    for _ in range(16):
        assert_equal(o.prefetch_window(12), first)


def test_the_window_is_monotone() raises:
    # Non-decreasing in the number of ranges, and in the bound.
    for bound in range(0, 10):
        var o = S3FsOptions(prefetch_max_inflight=bound)
        var prev = 0
        for n in range(0, 20):
            var w = o.prefetch_window(n)
            assert_true(w >= prev, "the window shrank as the ranges grew")
            assert_true(w >= 1)
            prev = w
    for n in range(1, 20):
        var prev = 0
        for bound in range(1, 25):
            var w = S3FsOptions(prefetch_max_inflight=bound).prefetch_window(n)
            assert_true(w >= prev, "the window shrank as the bound grew")
            assert_true(w <= n)
            prev = w


def test_refusals() raises:
    with assert_raises(contains="S3FsOptions: prefetch_max_inflight must be >= 0 (0 for every range), got -1"):
        _ = S3FsOptions(prefetch_max_inflight=-1)
    with assert_raises(contains="S3FsOptions: prefetch_depth must be >= 1, got 0"):
        _ = S3FsOptions(prefetch_depth=0)


def test_options_are_values() raises:
    var a = S3FsOptions(prefetch_max_inflight=2, prefetch_depth=32)
    var b = a
    b.prefetch_max_inflight = 9
    assert_equal(a.prefetch_max_inflight, 2)
    assert_equal(b.prefetch_max_inflight, 9)
    assert_equal(b.prefetch_depth, 32)


def main() raises:
    test_defaults()
    test_no_bound_is_every_range()
    test_a_bound_below_the_ranges_wins()
    test_a_bound_above_the_ranges_is_the_ranges()
    test_never_below_one()
    test_the_window_is_deterministic()
    test_the_window_is_monotone()
    test_refusals()
    test_options_are_values()
    print("OK")
