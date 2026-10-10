# =============================================================================
# report.mojo -- an h2spec run's results, read from its JUnit report
# =============================================================================
#
# h2spec (reporter/junit_report.go) writes one <testsuite> per group of cases
# that ran, with `package` = the group id (`http2/6.5`, `generic/3.2`,
# `hpack/4.2`), and one <testcase> per case that ran, in the group's order,
# with `classname` = the case's description. A failed case holds a <failure>
# or an <error> (which of the two depends on the Go error type h2spec's case
# returned; both mean the case failed), a skipped one a <skipped>; a passed
# one holds nothing. Go's encoding/xml never writes a self-closing element.
#
# A case's id is `<group id>/<n>`, n its 1-based position among the group's
# cases in the report. When every case of a group runs (the suite here runs
# whole groups, never single cases) that is h2spec's own id for the case, the
# one `h2spec <id>` selects.
#
# The report carries no total, so the stdout summary line h2spec prints
# (`N tests, P passed, S skipped, F failed`) is read too, and the two must
# agree: a parser that drops or misreads a case cannot pass unnoticed.
# =============================================================================

comptime CASE_PASSED: UInt8 = 0
comptime CASE_FAILED: UInt8 = 1
comptime CASE_SKIPPED: UInt8 = 2


@fieldwise_init
struct CaseResult(Copyable, Movable):
    """One h2spec case: its id, its description and its outcome."""

    var id: String
    var desc: String
    var outcome: UInt8
    # What h2spec said about a failure (`Expect: ... Actual: ...`), as written.
    var detail: String


@fieldwise_init
struct SummaryCounts(Copyable, Movable, Equatable):
    """The counts of h2spec's summary line, or of a parsed report."""

    var total: Int
    var passed: Int
    var skipped: Int
    var failed: Int

    def __eq__(self, other: Self) -> Bool:
        return (
            self.total == other.total
            and self.passed == other.passed
            and self.skipped == other.skipped
            and self.failed == other.failed
        )

    def __ne__(self, other: Self) -> Bool:
        return not self == other

    def describe(self) -> String:
        return (
            String(self.total) + " tests, " + String(self.passed) + " passed, "
            + String(self.skipped) + " skipped, " + String(self.failed) + " failed"
        )


def _unescape(s: String) -> String:
    """The text of an XML attribute value as Go's encoding/xml escapes it."""
    if s.find("&") < 0:
        return s
    var out = s.replace("&quot;", '"').replace("&#34;", '"')
    out = out.replace("&#39;", "'").replace("&apos;", "'")
    out = out.replace("&lt;", "<").replace("&gt;", ">")
    out = out.replace("&#xA;", "\n").replace("&#x9;", "\t").replace("&#xD;", "\r")
    return out.replace("&amp;", "&")


def _attr(tag: String, name: String) raises -> String:
    """The value of attribute `name` in the open tag `tag` (`<x a="v" ...>`)."""
    var key = " " + name + '="'
    var at = tag.find(key)
    if at < 0:
        raise Error("h2spec report: no " + name + " attribute in " + tag)
    var start = at + key.byte_length()
    var end = tag.find('"', start)
    if end < 0:
        raise Error("h2spec report: unterminated " + name + " attribute in " + tag)
    return _unescape(String(tag[byte=start:end]))


def _starts_at(s: String, at: Int, prefix: String) -> Bool:
    var n = prefix.byte_length()
    if at + n > s.byte_length():
        return False
    return String(s[byte=at : at + n]) == prefix


def _skip_space(s: String, var at: Int) -> Int:
    var b = s.as_bytes()
    while at < len(b) and (b[at] == UInt8(32) or b[at] == UInt8(10) or b[at] == UInt8(9) or b[at] == UInt8(13)):
        at += 1
    return at


def _child_text(body: String, open: String, close: String) -> String:
    """The text between `open`'s tag end and `close` in `body`, or empty."""
    var at = body.find(open)
    if at < 0:
        return String("")
    var gt = body.find(">", at)
    var end = body.find(close, gt)
    if gt < 0 or end < 0:
        return String("")
    return String(body[byte = gt + 1 : end])


def parse_junit(xml: String) raises -> List[CaseResult]:
    """Every case of an h2spec JUnit report, in report order.

    Raises on anything that is not the shape h2spec writes: a <testcase>
    outside a <testsuite>, a case whose `package` is not its suite's, an
    unterminated element, or a suite whose `tests` count differs from the
    cases it holds."""
    var out = List[CaseResult]()
    var at = 0
    while True:
        var suite_at = xml.find("<testsuite ", at)
        var stray = xml.find("<testcase ", at)
        if stray >= 0 and (suite_at < 0 or stray < suite_at):
            raise Error("h2spec report: a <testcase> outside a <testsuite>")
        if suite_at < 0:
            break
        var suite_gt = xml.find(">", suite_at)
        if suite_gt < 0:
            raise Error("h2spec report: unterminated <testsuite> tag")
        var suite_tag = String(xml[byte=suite_at : suite_gt + 1])
        var suite_end = xml.find("</testsuite>", suite_gt)
        if suite_end < 0:
            raise Error("h2spec report: unterminated <testsuite>")
        var group = _attr(suite_tag, "package")
        var declared = Int(_attr(suite_tag, "tests"))
        var n = 0
        var c = suite_gt + 1
        while True:
            var case_at = xml.find("<testcase ", c)
            if case_at < 0 or case_at > suite_end:
                break
            var case_gt = xml.find(">", case_at)
            var case_end = xml.find("</testcase>", case_gt)
            if case_gt < 0 or case_end < 0 or case_end > suite_end:
                raise Error("h2spec report: unterminated <testcase> in " + group)
            var tag = String(xml[byte=case_at : case_gt + 1])
            if _attr(tag, "package") != group:
                raise Error("h2spec report: a case of " + _attr(tag, "package") + " inside suite " + group)
            n += 1
            var body = String(xml[byte = case_gt + 1 : case_end])
            var first = _skip_space(body, 0)
            var outcome = CASE_PASSED
            var detail = String("")
            if _starts_at(body, first, "<failure"):
                outcome = CASE_FAILED
                detail = _child_text(body, "<failure", "</failure>")
            elif _starts_at(body, first, "<error"):
                outcome = CASE_FAILED
                detail = _child_text(body, "<error", "</error>")
            elif _starts_at(body, first, "<skipped"):
                outcome = CASE_SKIPPED
            elif first != body.byte_length():
                raise Error("h2spec report: unexpected content in case " + group + "/" + String(n))
            out.append(CaseResult(
                id=group + "/" + String(n),
                desc=_attr(tag, "classname"),
                outcome=outcome,
                detail=detail^,
            ))
            c = case_end + String("</testcase>").byte_length()
        if n != declared:
            raise Error(
                "h2spec report: suite " + group + " declares " + String(declared)
                + " tests and holds " + String(n)
            )
        at = suite_end + String("</testsuite>").byte_length()
    return out^


def count(results: List[CaseResult]) -> SummaryCounts:
    """The summary counts of parsed results."""
    var passed = 0
    var skipped = 0
    var failed = 0
    for ref r in results:
        if r.outcome == CASE_PASSED:
            passed += 1
        elif r.outcome == CASE_SKIPPED:
            skipped += 1
        else:
            failed += 1
    return SummaryCounts(total=len(results), passed=passed, skipped=skipped, failed=failed)


def _int_before(line: String, word: String) raises -> Int:
    """The integer just before ` <word>` in `line`."""
    var at = line.find(" " + word)
    if at < 0:
        raise Error("h2spec summary: no '" + word + "' in: " + line)
    var b = line.as_bytes()
    var start = at
    while start > 0 and b[start - 1] >= UInt8(48) and b[start - 1] <= UInt8(57):
        start -= 1
    if start == at:
        raise Error("h2spec summary: no count before '" + word + "' in: " + line)
    return Int(String(line[byte=start:at]))


def parse_summary(stdout: String) raises -> SummaryCounts:
    """The counts of the last `N tests, P passed, S skipped, F failed` line of
    h2spec's standard output. Raises when there is none."""
    var found = False
    var counts = SummaryCounts(total=0, passed=0, skipped=0, failed=0)
    for line in stdout.split("\n"):
        var l = String(line)
        if l.find(" tests, ") >= 0 and l.find(" passed, ") >= 0 and l.find(" skipped, ") >= 0 and l.find(" failed") >= 0:
            counts = SummaryCounts(
                total=_int_before(l, "tests,"),
                passed=_int_before(l, "passed,"),
                skipped=_int_before(l, "skipped,"),
                failed=_int_before(l, "failed"),
            )
            found = True
    if not found:
        raise Error("h2spec printed no summary line")
    return counts^
