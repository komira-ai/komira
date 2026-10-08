# =============================================================================
# test_report_and_reasons.mojo -- the report reader and the reason rule alone
# =============================================================================
#
# parse_report reads text in the exact shape the pinned runner prints
# (results.go `report`, v1.0.5); summary_problems and parse_known_failing are
# the gates the run test applies on top of the runner's own verdict. Each
# case below is one way the gate must go red, so a reader that misreads the
# report (or a gate that forgets a check) fails here, without a server.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_connect_conformance import (
    parse_known_failing,
    parse_report,
    summary_problems,
)

comptime _A = "Basic/HTTPVersion:2/Protocol:PROTOCOL_GRPC/Codec:CODEC_PROTO/Compression:COMPRESSION_IDENTITY/TLS:true/unary/success"
comptime _B = "Basic/HTTPVersion:2/Protocol:PROTOCOL_CONNECT/Codec:CODEC_PROTO/Compression:COMPRESSION_IDENTITY/TLS:true/unimplemented"
comptime _C = "Errors/HTTPVersion:2/Protocol:PROTOCOL_GRPC/Codec:CODEC_PROTO/Compression:COMPRESSION_IDENTITY/TLS:true/unary/aborted"


def _green() -> String:
    return (
        String("INFO: ") + _A + " failed (as expected):\n"
        + "\tactual response headers missing \"x-custom-header\"\n"
        + "INFO: " + _B + " failed (as expected):\n"
        + "\tactual error {code: 5 (not_found), message: \"\"} does not match expected code unimplemented\n"
        + "\n"
        + "Total cases: 5\n"
        + "3 passed, 0 failed\n"
        + "(Another 2 failed as expected due to being known failures/flakes.)\n"
    )


def _has(problems: List[String], fragment: String) -> Bool:
    for ref p in problems:
        if p.find(fragment) >= 0:
            return True
    return False


def test_a_green_report_reads_and_passes() raises:
    var r = parse_report(_green())
    assert_equal(r.summary.total, 5, "total")
    assert_equal(r.summary.passed, 3, "passed")
    assert_equal(r.summary.failed, 0, "failed")
    assert_equal(r.summary.known_failing, 2, "known")
    assert_equal(r.summary.could_not_run, 0, "could not run")
    assert_equal(len(r.known), 2, "INFO banners")
    assert_equal(r.known[1], String(_B), "the name between the banner's prefix and suffix")
    assert_equal(len(summary_problems(r, 5, 3)), 0, "a green run has no problem")
    print("  test_a_green_report_reads_and_passes PASS")


def test_new_failures_stale_entries_and_lost_cases_are_red() raises:
    var text = (
        String("FAILED: ") + _C + ":\n"
        + "\tactual error contain 0 details; expecting 1\n"
        + "FAILED: " + _A + " was expected to fail but did not\n"
        + "\n"
        + "Total cases: 4\n"
        + "1 passed, 2 failed\n"
        + "Another 1 could not be run due to client timing out or exiting prematurely.\n"
    )
    var r = parse_report(text)
    assert_equal(r.failed[0], String(_C), "the FAILED banner's case")
    assert_equal(r.stale[0], String(_A), "the stale banner's case")
    var p = summary_problems(r, 4, 1)
    assert_true(_has(p, "NEW FAILURE " + String(_C)), "a new failure is named")
    assert_true(_has(p, "STALE known-failing entry: " + String(_A)), "a stale entry is named")
    assert_true(_has(p, "1 cases could not be run"), "a case that could not run is red")
    print("  test_new_failures_stale_entries_and_lost_cases_are_red PASS")


def test_a_short_or_vacuous_run_is_red() raises:
    var r = parse_report(_green())
    assert_true(_has(summary_problems(r, 6, 3), "the run reported 5 cases"), "a case count off the pin")
    assert_true(_has(summary_problems(r, 5, 4), "only 3 cases passed"), "fewer passes than the pin's")
    var raised = False
    try:
        _ = parse_report(String("Computed 9 config case permutations.\n"))
    except:
        raised = True
    assert_true(raised, "a report without its summary is refused, not read as zero cases")
    print("  test_a_short_or_vacuous_run_is_red PASS")


def test_counts_that_disagree_with_the_banners_are_red() raises:
    var text = (
        String("INFO: ") + _A + " failed (as expected):\n\tx\n\n"
        + "Total cases: 3\n"
        + "1 passed, 0 failed\n"
        + "(Another 2 failed as expected due to being known failures/flakes.)\n"
    )
    var p = summary_problems(parse_report(text), 3, 1)
    assert_true(_has(p, "known failures; the report names 1"), "two counted, one named")
    print("  test_counts_that_disagree_with_the_banners_are_red PASS")


def test_every_pattern_needs_its_reason() raises:
    var good = (
        String("## prose about the file\n")
        + "\n"
        + "# komira_connect returns NOT_FOUND for an unregistered method,\n"
        + "# not UNIMPLEMENTED.\n"
        + "**/unimplemented\n"
        + "**/unary/unimplemented\n"
        + "\n"
        + "# no error details\n"
        + "Errors/**\n"
    )
    var parsed = parse_known_failing(good)
    assert_equal(len(parsed[1]), 0, "a well-formed file has no problem")
    assert_equal(len(parsed[0]), 3, "three patterns")
    assert_equal(
        parsed[0][1].reason,
        String("komira_connect returns NOT_FOUND for an unregistered method, not UNIMPLEMENTED."),
        "a reason spans its comment lines",
    )
    assert_equal(parsed[0][2].reason, String("no error details"), "each block its own reason")

    var no_reason = parse_known_failing(String("# r\na/**\n\nb/**\n"))
    assert_true(_has(no_reason[1], "pattern 'b/**' has no reason above it"), "a bare pattern")
    var dangling = parse_known_failing(String("# r\n\n# s\nb/**\n"))
    assert_true(_has(dangling[1], "line 1: a reason with no pattern under it"), "a reason alone")
    var trailing = parse_known_failing(String("# r\na/**\n# s\nb/**\n"))
    assert_true(_has(trailing[1], "line 3: a comment after the block's patterns"), "comment after patterns")
    var twice = parse_known_failing(String("# r\na/**\n\n# s\na/**\n"))
    assert_true(_has(twice[1], "is already listed on line 2"), "a pattern listed twice")
    var prose_only = parse_known_failing(String("## a pattern is not a reason\nc/**\n"))
    assert_true(_has(prose_only[1], "pattern 'c/**' has no reason above it"), "## is not a reason")
    print("  test_every_pattern_needs_its_reason PASS")


def main() raises:
    test_a_green_report_reads_and_passes()
    test_new_failures_stale_entries_and_lost_cases_are_red()
    test_a_short_or_vacuous_run_is_red()
    test_counts_that_disagree_with_the_banners_are_red()
    test_every_pattern_needs_its_reason()
    print("PASS komira_connect_conformance report and reasons")
