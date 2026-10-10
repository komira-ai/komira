# =============================================================================
# summary.mojo -- read the report `connectconformance` prints on stdout
# =============================================================================
#
# At the end of a run the runner (internal/app/connectconformance/results.go,
# `report`, at the pinned v1.0.5) prints, in this order:
#
#   FAILED: <case>:                  a case that failed and is not listed as
#   <indented errors>                known-failing (then its errors)
#   FAILED: <case> was expected to fail but did not
#                                    a listed case that passed (stale entry)
#   INFO: <case> failed (as expected):
#   <indented errors>                a listed case that failed
#   Total cases: <N>
#   <P> passed, <F> failed
#   Another <C> could not be run due to client timing out or exiting prematurely.
#   (Another <K> failed as expected due to being known failures/flakes.)
#
# the last two lines only when C or K is not zero. The runner's own verdict
# (its exit status) ignores C, so the gate here does not.
# =============================================================================


@fieldwise_init
struct RunSummary(Copyable, Movable):
    var total: Int
    var passed: Int
    var failed: Int
    var could_not_run: Int
    var known_failing: Int

    def describe(self) -> String:
        return (
            String(self.total) + " cases: " + String(self.passed) + " passed, "
            + String(self.failed) + " failed, " + String(self.known_failing)
            + " failed as known, " + String(self.could_not_run) + " could not run"
        )


struct RunReport(Movable):
    """The summary and the case names of the report's banners."""

    var summary: RunSummary
    var failed: List[String]  # FAILED banners (new failures)
    var failed_why: List[String]  # the first error line under each
    var stale: List[String]  # FAILED ... was expected to fail but did not
    var known: List[String]  # INFO ... failed (as expected)

    def __init__(out self, var summary: RunSummary):
        self.summary = summary^
        self.failed = List[String]()
        self.failed_why = List[String]()
        self.stale = List[String]()
        self.known = List[String]()


def _leading_int(s: String) raises -> Int:
    """The decimal number `s` starts with; raises when it starts with none."""
    var b = s.as_bytes()
    var n = 0
    var i = 0
    while i < len(b) and b[i] >= UInt8(ord("0")) and b[i] <= UInt8(ord("9")):
        n = n * 10 + Int(b[i] - UInt8(ord("0")))
        i += 1
    if i == 0:
        raise Error("expected a number at '" + s + "'")
    return n


comptime _FAILED = "FAILED: "
comptime _INFO = "INFO: "
comptime _STALE_TAIL = " was expected to fail but did not"
comptime _KNOWN_TAIL = " failed (as expected):"


def parse_report(stdout: String) raises -> RunReport:
    """The report at the end of the runner's stdout. Raises when the summary
    lines are missing or malformed, so a run that ended early is never read as
    a run of zero cases."""
    var total = -1
    var passed = -1
    var failed = -1
    var could_not_run = 0
    var known_failing = 0
    var failed_names = List[String]()
    var failed_why = List[String]()
    var want_why = False
    var stale_names = List[String]()
    var known_names = List[String]()
    for raw in stdout.split("\n"):
        var line = String(raw)
        if want_why:
            # The first error line; one that ends in ':' introduces the
            # next ("received an unexpected error:"), so take that too.
            ref why = failed_why[len(failed_why) - 1]
            if why.byte_length() > 0:
                why += " "
            why += String(line.strip())
            want_why = why.endswith(":")
        if line.startswith(_FAILED):
            var rest = String(line[byte = String(_FAILED).byte_length() :])
            if rest.endswith(_STALE_TAIL):
                stale_names.append(String(rest[byte = 0 : rest.byte_length() - String(_STALE_TAIL).byte_length()]))
            elif rest.endswith(":"):
                failed_names.append(String(rest[byte = 0 : rest.byte_length() - 1]))
                failed_why.append(String(""))
                want_why = True
            continue
        if line.startswith(_INFO) and line.endswith(_KNOWN_TAIL):
            var rest = String(line[byte = String(_INFO).byte_length() :])
            known_names.append(String(rest[byte = 0 : rest.byte_length() - String(_KNOWN_TAIL).byte_length()]))
            continue
        var t = String(line.strip())
        if t.startswith("Total cases: "):
            total = _leading_int(String(t[byte = String("Total cases: ").byte_length() :]))
        elif t.endswith(" failed") and t.find(" passed, ") > 0:
            passed = _leading_int(t)
            failed = _leading_int(String(t[byte = t.find(" passed, ") + String(" passed, ").byte_length() :]))
        elif t.startswith("Another ") and t.find(" could not be run") > 0:
            could_not_run = _leading_int(String(t[byte = String("Another ").byte_length() :]))
        elif t.startswith("(Another ") and t.find(" failed as expected") > 0:
            known_failing = _leading_int(String(t[byte = String("(Another ").byte_length() :]))
    if total < 0 or passed < 0 or failed < 0:
        raise Error("the runner printed no 'Total cases' / 'passed, failed' summary")
    var report = RunReport(
        RunSummary(
            total=total, passed=passed, failed=failed,
            could_not_run=could_not_run, known_failing=known_failing,
        )
    )
    report.failed = failed_names^
    report.failed_why = failed_why^
    report.stale = stale_names^
    report.known = known_names^
    return report^


def summary_problems(report: RunReport, expected_total: Int, min_passed: Int) -> List[String]:
    """Every reason the run is not green beyond the runner's own verdict:
    the counts must agree with the banners, every case must have run, the
    run must hold exactly the pinned number of cases and at least
    `min_passed` passing ones."""
    var p = List[String]()
    ref s = report.summary
    if s.total != expected_total:
        p.append(
            "the run reported " + String(s.total) + " cases; this config against the pinned suite has "
            + String(expected_total)
        )
    if s.could_not_run > 0:
        p.append(String(s.could_not_run) + " cases could not be run (the server under test died or hung)")
    if s.failed != len(report.failed) + len(report.stale):
        p.append(
            "the summary counts " + String(s.failed) + " failures; the report names "
            + String(len(report.failed)) + " failures and " + String(len(report.stale)) + " stale entries"
        )
    if s.known_failing != len(report.known):
        p.append(
            "the summary counts " + String(s.known_failing) + " known failures; the report names "
            + String(len(report.known))
        )
    if s.passed + s.failed + s.known_failing != s.total:
        p.append("passed + failed + known failures is not the total: " + s.describe())
    if s.passed < min_passed:
        p.append(
            "only " + String(s.passed) + " cases passed; at least " + String(min_passed)
            + " pass at this pin, so a run with fewer is not the run it claims"
        )
    for i in range(len(report.failed)):
        p.append("NEW FAILURE " + report.failed[i] + ": " + report.failed_why[i])
    for ref n in report.stale:
        p.append("STALE known-failing entry: " + n + " passes now; remove its pattern")
    return p^
