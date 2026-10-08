# S3FsOptions: what an S3Fs decides beyond its store's S3Config, every
# setting a constructor argument checked there, with S3's standard as the
# default, and no setting read from the environment (test_no_env_reads scans
# s3_fs.mojo with the rest of the package). The settings are read through
# accessors, so a value the constructor refuses cannot be set afterwards.
#
# What these rows pin is what each setting holds and what is refused;
# test_s3_fs_inflight observes the two in-flight bounds kept, and test_s3_fs
# counts the parts the part size makes.
#
# Rows: the defaults, and `standard()` agreeing with them; the in-flight
# window handed to the store for a call of N ranges: N with no bound, the
# bound when it is smaller, N when it is larger, never below 1 (a call of
# zero ranges), and monotone in N and in the bound; the edges each setting
# accepts; the refusals, each naming the setting and the value; the options
# are values (a copy is independent of its source).
from std.testing import assert_equal, assert_raises, assert_true

from komira_objectstore.store import PREFETCH_DEPTH_S3_STANDARD
from komira_objectstore_s3 import (
    S3FsOptions,
    S3_FS_ALL_RANGES,
    S3_FS_DEFAULT_PART_BYTES,
    S3_FS_DEFAULT_UPLOAD_MAX_INFLIGHT,
    S3_FS_UPLOAD_MAX_INFLIGHT_CAP,
    S3_MAX_PART_BYTES,
    S3_MIN_PART_BYTES,
)

comptime _MIB = 1024 * 1024


def test_defaults() raises:
    var o = S3FsOptions()
    assert_equal(o.prefetch_max_inflight(), S3_FS_ALL_RANGES)
    assert_equal(o.prefetch_max_inflight(), 0)
    assert_equal(o.prefetch_depth(), PREFETCH_DEPTH_S3_STANDARD)
    assert_equal(o.prefetch_depth(), 64)
    assert_equal(o.upload_part_bytes(), S3_FS_DEFAULT_PART_BYTES)
    assert_equal(o.upload_part_bytes(), 8 * _MIB)
    assert_equal(o.upload_max_inflight(), S3_FS_DEFAULT_UPLOAD_MAX_INFLIGHT)
    assert_equal(o.upload_max_inflight(), 8)
    var s = S3FsOptions.standard()
    assert_equal(s.prefetch_max_inflight(), o.prefetch_max_inflight())
    assert_equal(s.prefetch_depth(), o.prefetch_depth())
    assert_equal(s.upload_part_bytes(), o.upload_part_bytes())
    assert_equal(s.upload_max_inflight(), o.upload_max_inflight())


def test_s3_part_limits() raises:
    assert_equal(S3_MIN_PART_BYTES, 5 * _MIB)
    assert_equal(S3_MAX_PART_BYTES, 5 * 1024 * _MIB)
    assert_equal(S3_FS_UPLOAD_MAX_INFLIGHT_CAP, 16)


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
    assert_equal(o.prefetch_window(3), 3)
    assert_equal(S3FsOptions(prefetch_max_inflight=1).prefetch_window(3), 1)


def test_never_below_one() raises:
    assert_equal(S3FsOptions().prefetch_window(0), 1)
    assert_equal(S3FsOptions(prefetch_max_inflight=4).prefetch_window(0), 1)


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


def test_the_edges_are_accepted() raises:
    assert_equal(S3FsOptions(prefetch_depth=1).prefetch_depth(), 1)
    assert_equal(S3FsOptions(upload_part_bytes=S3_MIN_PART_BYTES).upload_part_bytes(), S3_MIN_PART_BYTES)
    assert_equal(S3FsOptions(upload_part_bytes=S3_MAX_PART_BYTES).upload_part_bytes(), S3_MAX_PART_BYTES)
    assert_equal(S3FsOptions(upload_max_inflight=1).upload_max_inflight(), 1)
    assert_equal(
        S3FsOptions(upload_max_inflight=S3_FS_UPLOAD_MAX_INFLIGHT_CAP).upload_max_inflight(),
        S3_FS_UPLOAD_MAX_INFLIGHT_CAP,
    )


def test_refusals() raises:
    with assert_raises(contains="S3FsOptions: prefetch_max_inflight must be >= 0 (0 for every range), got -1"):
        _ = S3FsOptions(prefetch_max_inflight=-1)
    with assert_raises(contains="S3FsOptions: prefetch_depth must be >= 1, got 0"):
        _ = S3FsOptions(prefetch_depth=0)
    with assert_raises(contains="S3FsOptions: upload_part_bytes must be 5242880 to 5368709120, got 5242879"):
        _ = S3FsOptions(upload_part_bytes=S3_MIN_PART_BYTES - 1)
    with assert_raises(contains="S3FsOptions: upload_part_bytes must be 5242880 to 5368709120, got 5368709121"):
        _ = S3FsOptions(upload_part_bytes=S3_MAX_PART_BYTES + 1)
    with assert_raises(contains="S3FsOptions: upload_max_inflight must be 1 to 16, got 0"):
        _ = S3FsOptions(upload_max_inflight=0)
    with assert_raises(contains="S3FsOptions: upload_max_inflight must be 1 to 16, got 17"):
        _ = S3FsOptions(upload_max_inflight=17)


def test_options_are_values() raises:
    var a = S3FsOptions(prefetch_max_inflight=2, prefetch_depth=32, upload_max_inflight=4)
    var b = a
    a = S3FsOptions(prefetch_max_inflight=9)
    assert_equal(a.prefetch_max_inflight(), 9)
    assert_equal(b.prefetch_max_inflight(), 2)
    assert_equal(b.prefetch_depth(), 32)
    assert_equal(b.upload_max_inflight(), 4)


def main() raises:
    test_defaults()
    test_s3_part_limits()
    test_no_bound_is_every_range()
    test_a_bound_below_the_ranges_wins()
    test_never_below_one()
    test_the_window_is_monotone()
    test_the_edges_are_accepted()
    test_refusals()
    test_options_are_values()
    print("OK")
