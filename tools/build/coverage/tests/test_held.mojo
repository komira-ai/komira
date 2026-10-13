from std.testing import assert_equal, assert_true

from covcheck.analyze import FORMAT_LCOV, Analysis, Input, Options, Sources, analyze
from covcheck.held import Held, add_hold, parse_hold
from covcheck.paths import RepoFiles, repo_files_of
from covcheck.stats import Finding

# The holds (held.mojo; README.md, "The 99% threshold and holds"): the
# marker's grammar and every refusal, and what a hold does to the findings
# against the 99.00% target, at its edges. Each case names the defect that
# turns it red.


def _repo() -> RepoFiles:
    """src/alpha is a.mojo; src/gen is a package whose one source has no
    executable line (a library whose sources are all generated)."""
    var l = List[String]()
    l.append("src/alpha/BUCK")
    l.append("src/alpha/a.mojo")
    l.append("src/beta/BUCK")
    l.append("src/beta/c.mojo")
    l.append("src/gen/BUCK")
    l.append("src/gen/gen.mojo")
    return repo_files_of(l)


def _sources() -> Sources:
    var s = Sources(String(""))
    s.texts[String("src/alpha/a.mojo")] = String("a\nb\nc\nd\n")
    s.texts[String("src/beta/c.mojo")] = String("a\nb\nc\n")
    s.texts[String("src/gen/gen.mojo")] = String("")
    return s^


def _report(found: Int, hit: Int, arms: Int, taken: Int) -> List[Input]:
    """One lcov record of src/alpha/a.mojo: `hit` of `found` lines covered,
    `taken` of `arms` single-arm decisions taken (no BRDA when `arms` is 0)."""
    var t = String("SF:src/alpha/a.mojo\n")
    for i in range(1, found + 1):
        t += String("DA:") + String(i) + String(",") + (String("1") if i <= hit else String("0")) + String("\n")
    for i in range(1, arms + 1):
        t += String("BRDA:") + String(i) + String(",0,0,") + (String("1") if i <= taken else String("0")) + String("\n")
    t += String("end_of_record\n")
    var l = List[Input]()
    l.append(Input(String(FORMAT_LCOV), String(""), String("t.info"), t))
    return l^


def _held(package: String, text: String) raises -> Held:
    var h = Held()
    add_hold(h, package, text, package + String("/coverage_held"), List[String]())
    return h^


def _census() -> Options:
    var o = Options()
    o.mode = String("census")
    o.target_bp = 9900
    return o^


def _kinds(fs: List[Finding]) -> String:
    var s = String("")
    for i in range(len(fs)):
        if i > 0:
            s += String(" ")
        s += fs[i].kind
        if fs[i].metric.byte_length() > 0:
            s += String(":") + fs[i].metric
    return s^


def _refused(text: String, package: String, want: String) raises:
    var dirs = List[String]()
    dirs.append(String("src/tests"))
    var raised = False
    try:
        _ = parse_hold(text, String("m"), package, dirs)
    except e:
        raised = True
        assert_true(String(e).find(want) >= 0, String(e))
    assert_true(raised, text)


def test_marker_grammar() raises:
    # Comments, then `line` and/or `branch`; a comment-only marker holds
    # nothing (the gate's default when the package has none).
    var none = List[String]()
    var h = parse_hold(String("# held\nline\nbranch\n"), String("m"), String("src/a"), none)
    assert_true(h.line and h.branch)
    var l = parse_hold(String("# held\nline\n"), String("m"), String("src/a"), none)
    assert_true(l.line and not l.branch)
    var e = parse_hold(String("# not held\n"), String("m"), String("src/a"), none)
    assert_true(not e.line and not e.branch)
    # Defect: a refusal dropped. Each of these must raise, naming the line.
    _refused(String("# c\nline 9900\n"), String("src/a"), String("m:2: 'line 9900' is not a held metric"))
    _refused(String("line\t9900\n"), String("src/a"), String("m:1: 'line\t9900' is not a held metric"))
    _refused(String("lines\n"), String("src/a"), String("m:1: 'lines' is not a held metric"))
    _refused(String("9900\n"), String("src/a"), String("m:1: '9900' is not a held metric"))
    _refused(String("line\nline\n"), String("src/a"), String("m:2: line is held twice"))
    _refused(String("branch\n# c\nbranch\n"), String("src/a"), String("m:3: branch is held twice"))
    _refused(String("line\n\nbranch\n"), String("src/a"), String("m:2: an empty line"))
    _refused(String("line\r\n"), String("src/a"), String("m:1: carriage return"))
    _refused(String("line\n"), String("src/tests/x"), String("m:1: src/tests/x is a test-only package"))
    _refused(String("# c\nbranch\n"), String("src/tests"), String("m:2: src/tests is a test-only package"))
    # A test-only package's gate reads a marker holding nothing (its
    # default): accepted.
    var tests = List[String]()
    tests.append(String("src/tests"))
    var t = parse_hold(String("# Not held: the package has no coverage_held.\n"), String("m"), String("src/tests/x"), tests)
    assert_true(not t.line and not t.branch)
    # A second marker for one package (two --held of it) is refused.
    var two = _held(String("src/a"), String("line\n"))
    var raised = False
    try:
        add_hold(two, String("src/a"), String("branch\n"), String("other"), none)
    except e2:
        raised = True
        assert_true(String(e2).find("other: a second coverage_held for src/a") >= 0, String(e2))
    assert_true(raised)


def test_held_line_below_the_target_fails() raises:
    # 197 of 199 lines: 98.99% (rounded down), held: a Regression, failure
    # in census mode. Defect: the hold ignored (BelowTarget, neutral).
    var a = analyze(_report(199, 197, 1, 1), List[Input](), _repo(), _held(String("src/alpha"), String("line\n")), _sources(), _census())
    assert_equal(a.packages[0].line_bp(), 9899)
    assert_equal(_kinds(a.findings), "Regression:line")
    assert_equal(a.findings[0].message, "line 98.99% is below the target 99.00%, which coverage_held holds it at")
    assert_equal(a.conclusion, "failure")
    var o = _census()
    o.mode = String("neutral")
    assert_equal(analyze(_report(199, 197, 1, 1), List[Input](), _repo(), _held(String("src/alpha"), String("line\n")), _sources(), o).conclusion, "failure")


def test_held_line_at_exactly_the_target_passes() raises:
    # 198 of 200 lines: 99.00%. Defect: `<=` for `<` (the edge fails).
    var a = analyze(_report(200, 198, 1, 1), List[Input](), _repo(), _held(String("src/alpha"), String("line\nbranch\n")), _sources(), _census())
    assert_equal(a.packages[0].line_bp(), 9900)
    assert_equal(_kinds(a.findings), "")
    assert_equal(len(a.info_findings), 0)
    assert_equal(a.conclusion, "neutral")


def test_not_held_below_the_target_is_neutral() raises:
    # 50.00%, not held: BelowTarget, which fails nothing in census mode.
    # Defect: BelowTarget made fatal.
    var a = analyze(_report(4, 2, 1, 1), List[Input](), _repo(), Held(), _sources(), _census())
    assert_equal(_kinds(a.findings), "BelowTarget:line")
    assert_equal(a.conclusion, "neutral")


def test_not_held_at_the_target_is_a_notice() raises:
    # 100% line and branch, nothing held: a ReachedTarget per metric, as
    # information that never fails, not even in enforce mode. Defect: the
    # notice dropped, or made a finding.
    var a = analyze(_report(4, 4, 2, 2), List[Input](), _repo(), Held(), _sources(), _census())
    assert_equal(_kinds(a.findings), "")
    assert_equal(_kinds(a.info_findings), "ReachedTarget:line ReachedTarget:branch")
    assert_equal(
        a.info_findings[0].message,
        "line 100.00% reaches the target 99.00%: hold it, adding `line` to src/alpha/coverage_held, once every library of the package reaches it",
    )
    assert_equal(a.conclusion, "neutral")
    var o = _census()
    o.mode = String("enforce")
    assert_equal(analyze(_report(4, 4, 2, 2), List[Input](), _repo(), Held(), _sources(), o).conclusion, "success")
    # Held line: only branch is left to hold.
    var b = analyze(_report(4, 4, 2, 2), List[Input](), _repo(), _held(String("src/alpha"), String("line\n")), _sources(), _census())
    assert_equal(_kinds(b.info_findings), "ReachedTarget:branch")


def test_a_hold_is_per_metric() raises:
    # Held branch: 197 of 199 arms is a Regression on branch. Held line
    # only: branch 50.00% is BelowTarget, neutral. Defect: one hold for both.
    var a = analyze(_report(4, 4, 199, 197), List[Input](), _repo(), _held(String("src/alpha"), String("branch\n")), _sources(), _census())
    assert_equal(_kinds(a.findings), "Regression:branch")
    assert_equal(a.conclusion, "failure")
    var b = analyze(_report(4, 4, 2, 1), List[Input](), _repo(), _held(String("src/alpha"), String("line\n")), _sources(), _census())
    assert_equal(_kinds(b.findings), "BelowTarget:branch")
    assert_equal(b.conclusion, "neutral")


def test_held_branch_not_measured_fails() raises:
    # Held branch and no branch record (a gate reading none): a Regression
    # in place of BranchNotMeasured. Not held: BranchNotMeasured, neutral.
    # Defect: an unmeasured held metric passing.
    var a = analyze(_report(4, 4, 0, 0), List[Input](), _repo(), _held(String("src/alpha"), String("line\nbranch\n")), _sources(), _census())
    assert_equal(_kinds(a.findings), "Regression:branch")
    assert_equal(a.findings[0].measured, -1)
    assert_equal(a.conclusion, "failure")
    var b = analyze(_report(4, 4, 0, 0), List[Input](), _repo(), _held(String("src/alpha"), String("line\n")), _sources(), _census())
    assert_equal(_kinds(b.findings), "BranchNotMeasured:branch")
    assert_equal(b.conclusion, "neutral")


def test_held_not_measured_fails_unless_nothing_to_cover() raises:
    # The report names src/beta only; src/alpha holds line: it is in the
    # run all the same, and no line of it was measured: a Regression.
    var beta = List[Input]()
    beta.append(Input(String(FORMAT_LCOV), String(""), String("b.info"), String("SF:src/beta/c.mojo\nDA:1,1\nBRDA:1,0,0,1\nend_of_record\n")))
    var held = _held(String("src/alpha"), String("line\n"))
    var r = analyze(beta, List[Input](), _repo(), held, _sources(), _census())
    assert_equal(r.packages[0].package, "src/alpha")
    assert_true(_kinds(r.findings).find("Regression:line") >= 0, _kinds(r.findings))
    assert_equal(r.conclusion, "failure")
    # In a report a held package with no line at all is not exempt: the
    # report has no library whose every source it counts.
    var gen = analyze(beta, List[Input](), _repo(), _held(String("src/gen"), String("line\nbranch\n")), _sources(), _census())
    assert_equal(_kinds(gen.findings), "Regression:branch Regression:line")
    assert_equal(gen.findings[1].message, "line is held (coverage_held) and no line of this package was measured (no report for it, or none of its paths mapped to it)")
    # The gate of src/alpha with no report: its source counts uncovered,
    # 0.00% under its hold.
    var o = _census()
    o.only_package = String("src/alpha")
    var g = analyze(List[Input](), List[Input](), _repo(), held, _sources(), o)
    assert_equal(_kinds(g.findings), "NotMeasured:line Regression:line UnmeasuredFile")
    assert_equal(g.conclusion, "failure")
    # The gate of src/gen, held on both, whose one source has no executable
    # line: nothing to cover, so no Regression (NotMeasured alone, which
    # fails nothing). Defect: the exemption dropped (komira_wkt's generated
    # library would fail).
    o.only_package = String("src/gen")
    var n = analyze(List[Input](), List[Input](), _repo(), _held(String("src/gen"), String("line\nbranch\n")), _sources(), o)
    assert_equal(n.packages[0].line_found, 0)
    assert_equal(_kinds(n.findings), "NotMeasured:line")
    assert_equal(n.conclusion, "neutral")
    # A hold of a directory with no BUCK file is an error.
    var raised = False
    try:
        _ = analyze(beta, List[Input](), _repo(), _held(String("src/none"), String("line\n")), _sources(), _census())
    except e:
        raised = True
        assert_true(String(e).find("coverage_held of src/none: the directory has no BUCK file") >= 0, String(e))
    assert_true(raised)


def main() raises:
    test_marker_grammar()
    test_held_line_below_the_target_fails()
    test_held_line_at_exactly_the_target_passes()
    test_not_held_below_the_target_is_neutral()
    test_not_held_at_the_target_is_a_notice()
    test_a_hold_is_per_metric()
    test_held_branch_not_measured_fails()
    test_held_not_measured_fails_unless_nothing_to_cover()
    print("test_held: PASS")
