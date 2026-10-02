# SKIP-with-reason: one marker line and exit code 77, never 0.

from std.testing import assert_equal, assert_true

from komira_test_infra import SKIP_EXIT_CODE, SKIP_MARKER, report_skip, skip_line


def test_marker_line_and_code() raises:
    assert_equal(
        skip_line("no shared store configured"),
        "KOMIRA-TEST-INFRA: SKIP reason=no shared store configured",
    )
    assert_equal(SKIP_MARKER, "KOMIRA-TEST-INFRA: SKIP reason=")
    var code = report_skip("no shared store configured")
    assert_equal(code, 77)
    assert_equal(code, SKIP_EXIT_CODE)
    assert_true(code != 0, "a skip mapped to exit 0")


def test_reason_stays_on_one_line() raises:
    assert_equal(skip_line("a\nb\rc"), "KOMIRA-TEST-INFRA: SKIP reason=a b c")
    assert_equal(skip_line(""), "KOMIRA-TEST-INFRA: SKIP reason=unspecified")
    assert_equal(report_skip(""), 77)


def main() raises:
    test_marker_line_and_code()
    test_reason_stays_on_one_line()
    print("test_skip: OK")
