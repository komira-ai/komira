# SKIP and CANNOT_TELL with a reason: one marker line each, and exit codes 77
# and 3, never 0. `exit_skip` and `exit_cannot_tell` end the process, so this
# test checks the lines and the codes only; calling either here would end
# (and fail) this test.

from std.testing import assert_equal, assert_true

from komira_test_verdict import (
    CANNOT_TELL_EXIT_CODE,
    CANNOT_TELL_MARKER,
    SKIP_EXIT_CODE,
    SKIP_MARKER,
    VERDICT_CANNOT_TELL,
    cannot_tell_line,
    skip_line,
)


def test_marker_line_and_code() raises:
    assert_equal(
        skip_line("no S3-compatible endpoint configured"),
        String(SKIP_MARKER) + "no S3-compatible endpoint configured",
    )
    assert_equal(String(SKIP_MARKER), "KOMIRA-TEST: SKIP reason=")
    assert_equal(SKIP_EXIT_CODE, 77)
    assert_true(SKIP_EXIT_CODE != 0, "a skip mapped to exit 0")


def test_reason_stays_on_one_line() raises:
    assert_equal(skip_line("a\nb\rc"), String(SKIP_MARKER) + "a b c")
    assert_equal(skip_line(""), String(SKIP_MARKER) + "unspecified")


def test_cannot_tell_line_and_code() raises:
    assert_equal(String(CANNOT_TELL_MARKER), "KOMIRA-TEST: CANNOT_TELL reason=")
    assert_equal(cannot_tell_line("x\ny"), String(CANNOT_TELL_MARKER) + "x y")
    assert_equal(cannot_tell_line(""), String(CANNOT_TELL_MARKER) + "unspecified")
    # The exit and the verdict kind are one number.
    assert_equal(CANNOT_TELL_EXIT_CODE, 3)
    assert_equal(CANNOT_TELL_EXIT_CODE, VERDICT_CANNOT_TELL)


def main() raises:
    test_marker_line_and_code()
    test_reason_stays_on_one_line()
    test_cannot_tell_line_and_code()
    print("test_exits: OK")
