# =============================================================================
# test_report_and_gate.mojo -- the JUnit reader and the allowlist gate, alone
# =============================================================================
#
# No server and no h2spec: a report written in the exact shape h2spec's
# reporter/junit_report.go produces (indented, never self-closing, a failure
# as <error> or <failure>, escaped attribute values), and allowlists against
# it. What each part proves:
#   1. parse_junit numbers cases per suite (`http2/6.5/2`), reads all three
#      outcomes, unescapes descriptions, keeps the failure text, and refuses a
#      suite whose `tests` count differs from the cases it holds and a
#      <testcase> outside every <testsuite>;
#   2. parse_summary reads h2spec's colored stdout summary line, and count()
#      over the parsed report equals it;
#   3. the gate passes when the list is exactly the failures and the skips;
#      goes red on an unlisted failure, on an unlisted skip, on a case listed
#      as a failure that was skipped and one listed as a skip that failed, on
#      a listed case that now passes (stale), on an id the run never reported,
#      on a run of more or fewer cases than expected; and refuses a line with
#      no reason (a bare `skip:` included) and a duplicate line.
# A gate that always passed, or a parser that dropped failed cases, fails 3.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_http_conformance import (
    CASE_FAILED,
    CASE_PASSED,
    CASE_SKIPPED,
    SummaryCounts,
    count,
    gate,
    parse_allowlist,
    parse_junit,
    parse_summary,
)


comptime _REPORT = """<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="3.5. HTTP/2 Connection Preface" package="http2/3.5" id="3.5" tests="2" skipped="0" failures="0" errors="1">
    <testcase package="http2/3.5" classname="Sends client connection preface" time="0.0010"></testcase>
    <testcase package="http2/3.5" classname="Sends invalid connection preface" time="2.0010">
      <error>Expect:
GOAWAY Frame (Error Code: PROTOCOL_ERROR)
Connection closed
Actual:
Timeout</error>
    </testcase>
  </testsuite>
  <testsuite name="6.5. SETTINGS" package="http2/6.5" id="6.5" tests="3" skipped="1" failures="1" errors="0">
    <testcase package="http2/6.5" classname="Sends a SETTINGS frame with ACK flag and payload" time="0.0020"></testcase>
    <testcase package="http2/6.5" classname="Sends a &#34;SETTINGS&#34; frame &amp; more" time="0.0020">
      <failure>Expect:
GOAWAY Frame (Error Code: FRAME_SIZE_ERROR)
Actual:
DATA Frame (length:18, flags:0x01, stream_id:1)</failure>
    </testcase>
    <testcase package="http2/6.5" classname="Sends SETTINGS_MAX_CONCURRENT_STREAMS" time="0.0001">
      <skipped></skipped>
    </testcase>
  </testsuite>
</testsuites>"""

comptime _STDOUT = "Finished in 4.1 seconds\n\x1b[0m5 tests, 2 passed, 1 skipped, 2 failed\x1b[0m\n"


def test_parse_junit() raises:
    var r = parse_junit(String(_REPORT))
    assert_equal(len(r), 5)
    assert_equal(r[0].id, String("http2/3.5/1"))
    assert_equal(r[0].outcome, CASE_PASSED)
    assert_equal(r[1].id, String("http2/3.5/2"))
    assert_equal(r[1].outcome, CASE_FAILED, "an <error> is a failure")
    assert_true(r[1].detail.find("Timeout") >= 0, "the failure text is kept")
    assert_equal(r[2].id, String("http2/6.5/1"), "numbering restarts per suite")
    assert_equal(r[3].outcome, CASE_FAILED, "a <failure> is a failure")
    assert_equal(r[3].desc, String('Sends a "SETTINGS" frame & more'))
    assert_equal(r[4].id, String("http2/6.5/3"))
    assert_equal(r[4].outcome, CASE_SKIPPED)
    var bad = String(_REPORT).replace('tests="3"', 'tests="4"')
    var raised = False
    try:
        _ = parse_junit(bad)
    except e:
        raised = String(e).find("declares 4 tests and holds 3") >= 0
    assert_true(raised, "a suite whose count disagrees is refused")
    var stray = String(_REPORT).replace(
        "<testsuites>\n",
        '<testsuites>\n<testcase package="http2/3.5" classname="x"></testcase>\n',
    )
    assert_true(stray != String(_REPORT))
    raised = False
    try:
        _ = parse_junit(stray)
    except e:
        raised = String(e).find("outside a <testsuite>") >= 0
    assert_true(raised, "a case outside every suite is refused")
    print("  test_parse_junit PASS")


def test_summary_matches_count() raises:
    var s = parse_summary(String(_STDOUT))
    assert_true(s == SummaryCounts(total=5, passed=2, skipped=1, failed=2))
    assert_true(count(parse_junit(String(_REPORT))) == s)
    var raised = False
    try:
        _ = parse_summary(String("Finished in 1 seconds\n"))
    except:
        raised = True
    assert_true(raised, "no summary line is an error")
    print("  test_summary_matches_count PASS")


def _problems(allow: String, expected_cases: Int = 5) raises -> List[String]:
    return gate(parse_junit(String(_REPORT)), allow, expected_cases)


def _has(p: List[String], needle: String) -> Bool:
    for ref s in p:
        if s.find(needle) >= 0:
            return True
    return False


def test_gate() raises:
    comptime FAILS = "# reviewed\n\nhttp2/3.5/2 times out\nhttp2/6.5/2 answers 200\n"
    var exact = String(FAILS) + "http2/6.5/3 skip: no MAX_CONCURRENT_STREAMS\n"
    assert_equal(len(_problems(exact)), 0, "the exact list passes")

    var missing = _problems(String("http2/3.5/2 times out\nhttp2/6.5/3 skip: x\n"))
    assert_equal(len(missing), 1)
    assert_true(_has(missing, "NEW FAILURE http2/6.5/2"), "an unlisted failure is red")

    var new_skip = _problems(String(FAILS))
    assert_equal(len(new_skip), 1)
    assert_true(_has(new_skip, "NEW SKIP http2/6.5/3"), "an unlisted skip is red")

    var skip_as_fail = _problems(String(FAILS) + "http2/6.5/3 fails\n")
    assert_equal(len(skip_as_fail), 1)
    assert_true(
        _has(skip_as_fail, "NEW SKIP http2/6.5/3 (listed as a failure on line 5)"),
        "a case listed as a failure that was skipped is red",
    )

    var fail_as_skip = _problems(
        String("http2/3.5/2 skip: x\nhttp2/6.5/2 answers 200\nhttp2/6.5/3 skip: x\n")
    )
    assert_equal(len(fail_as_skip), 1)
    assert_true(
        _has(fail_as_skip, "NEW FAILURE http2/3.5/2 (listed as a skip on line 1)"),
        "a case listed as a skip that failed is red",
    )

    var stale = _problems(exact + "http2/6.5/1 was fixed\n")
    assert_equal(len(stale), 1)
    assert_true(_has(stale, "STALE ALLOWLIST ENTRY http2/6.5/1"), "a passing listed case is red")

    var stale_skip = _problems(exact + "http2/3.5/1 skip: was skipped\n")
    assert_equal(len(stale_skip), 1)
    assert_true(_has(stale_skip, "STALE ALLOWLIST ENTRY http2/3.5/1"), "a passing skip-listed case is red")

    var unknown = _problems(exact + "http2/9.9/1 typo\n")
    assert_true(_has(unknown, "UNKNOWN ALLOWLIST ENTRY http2/9.9/1"), "an unreported id is red")

    var few = _problems(exact, expected_cases=6)
    assert_true(_has(few, "reported 5 cases; the pinned suite has 6"), "a short run is red")
    var many = _problems(exact, expected_cases=4)
    assert_true(_has(many, "reported 5 cases; the pinned suite has 4"), "a long run is red")

    assert_true(_has(_problems(String("http2/3.5/2\n")), "has no reason"))
    assert_true(_has(_problems(String("http2/3.5/2 skip:\n")), "has no reason"))
    assert_true(_has(_problems(exact + "http2/3.5/2 again\n"), "already listed on line 3"))
    var parsed = parse_allowlist(exact)
    assert_equal(len(parsed), 3)
    assert_false(parsed[0].skip)
    assert_true(parsed[2].skip)
    assert_equal(parsed[2].reason, String("no MAX_CONCURRENT_STREAMS"))
    print("  test_gate PASS")


def main() raises:
    test_parse_junit()
    test_summary_matches_count()
    test_gate()
    print("PASS komira_http_conformance report and gate")
