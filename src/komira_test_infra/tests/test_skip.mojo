# SKIP-with-reason: one marker line and exit code 77, never 0. `exit_skip`
# ends the process, so this test checks the line and the code only; calling
# it here would end (and fail) this test.

from std.testing import assert_equal, assert_true

from komira_test_infra import SKIP_EXIT_CODE, SKIP_MARKER, skip_line


def test_marker_line_and_code() raises:
    assert_equal(
        skip_line("no S3-compatible endpoint configured"),
        String(SKIP_MARKER) + "no S3-compatible endpoint configured",
    )
    assert_equal(SKIP_EXIT_CODE, 77)
    assert_true(SKIP_EXIT_CODE != 0, "a skip mapped to exit 0")


def test_reason_stays_on_one_line() raises:
    assert_equal(skip_line("a\nb\rc"), String(SKIP_MARKER) + "a b c")
    assert_equal(skip_line(""), String(SKIP_MARKER) + "unspecified")


def main() raises:
    test_marker_line_and_code()
    test_reason_stays_on_one_line()
    print("test_skip: OK")
