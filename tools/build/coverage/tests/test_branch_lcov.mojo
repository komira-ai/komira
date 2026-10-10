from std.testing import assert_equal, assert_true

from covcheck.analyze import FORMAT_BRANCH_LCOV, FORMAT_COBERTURA, FORMAT_LCOV, Analysis, Input, Options, Sources, analyze
from covcheck.annotate import annotations, touched_packages
from covcheck.branch_lcov import parse_branch_lcov
from covcheck.diff import parse_diff
from covcheck.paths import RepoFiles, repo_files_of
from covcheck.ratchet import Ratchet, parse_ratchet

# Branch record files (`--branch-lcov`, cov_branch_classify's records): the
# strict reader, the sum of one arm across tests ('-' is counted and not
# taken), the refusal of two tests disagreeing on a location's decisions,
# one source of branch data per file, the numbers and findings they give a
# package next to a Cobertura line report, and their annotations.

# One location (65,9) with an `if` (br) and the `or`'s select and right
# operand at 65,20, as cov_branch_classify writes them for policy.mojo.
comptime ONE = (
    "SF:src/alpha/a.mojo\n"
    "BRDA:2,9:br:0/1,0,-\n"
    "BRDA:2,9:br:0/1,1,-\n"
    "BRDA:3,20:select:0/2,0,0\n"
    "BRDA:3,20:select:0/2,1,6\n"
    "BRDA:3,20:select:1/2,0,1\n"
    "BRDA:3,20:select:1/2,1,0\n"
    "end_of_record\n"
)


def _refused(text: String, want: String) raises:
    """`text` is refused with an error that holds `want`."""
    var raised = False
    try:
        _ = parse_branch_lcov(text, String("b.info"))
    except e:
        raised = True
        var msg = String(e)
        assert_true(msg.find(want) >= 0, msg + String(" lacks ") + want)
    assert_true(raised, String("accepted: ") + text)


def _rec(brda: String) -> String:
    return String("SF:src/alpha/a.mojo\n") + brda + String("end_of_record\n")


# b.mojo named with no decision, as cov_branch_classify writes a measured
# file its test holds code of: a test of COB_FULL names it too.
comptime B_NONE = "SF:src/alpha/b.mojo\nend_of_record\n"


def test_reader_keys_counts_and_dash() raises:
    var fs = parse_branch_lcov(String(ONE), String("b.info"))
    assert_equal(len(fs), 1)
    ref f = fs[0]
    assert_equal(f.path, "src/alpha/a.mojo")
    assert_equal(f.line_found(), 0)
    assert_equal(f.branch_found(), 6)
    # '-' is a branch counted and not taken.
    assert_equal(f.branch_hit(), 2)
    assert_equal(f.branches[String("2,9:br:0/1,0")], 0)
    assert_equal(f.branches[String("3,20:select:0/2,1")], 6)
    # Numbers are keyed without leading zeros: the same arm from two tests
    # is one key whatever its spelling.
    var z = parse_branch_lcov(_rec(String("BRDA:02,09:br:00/01,00,1\nBRDA:2,9:br:0/1,01,0\n")), String("z.info"))
    assert_true(String("2,9:br:0/1,0") in z[0].branches)
    assert_true(String("2,9:br:0/1,1") in z[0].branches)
    # A switch has two arms or more; a test that ran none of the library's
    # code writes an empty file.
    var s = parse_branch_lcov(_rec(String("BRDA:4,5:switch:0/1,0,1\nBRDA:4,5:switch:0/1,1,0\nBRDA:4,5:switch:0/1,2,3\n")), String("s.info"))
    assert_equal(s[0].branch_found(), 3)
    assert_equal(len(parse_branch_lcov(String(""), String("e.info"))), 0)
    # A raising call in a `try:` body: two arms, returned (0) and raised
    # into the handler (1), here never raised.
    var t = parse_branch_lcov(_rec(String("BRDA:5,14:try:0/1,0,5\nBRDA:5,14:try:0/1,1,0\n")), String("t.info"))
    assert_equal(t[0].branch_found(), 2)
    assert_equal(t[0].branch_hit(), 1)
    assert_equal(t[0].branches[String("5,14:try:0/1,1")], 0)


def test_reader_refusals() raises:
    # Line data and every other lcov record: this file holds branches only.
    _refused(_rec(String("DA:2,1\n")), String("b.info:2: 'DA' record in a branch record file"))
    _refused(_rec(String("LF:1\n")), String("'LF' record"))
    _refused(_rec(String("BRF:2\n")), String("'BRF' record"))
    _refused(_rec(String("FN:1,f\n")), String("'FN' record"))
    _refused(String("TN:x\n") + _rec(String("")), String("b.info:1: 'TN' record"))
    _refused(_rec(String("\n")), String("b.info:2: not a record: ''"))
    _refused(String("SF:a\r\nend_of_record\n"), String("carriage return"))
    _refused(String("BRDA:2,9:br:0/1,0,1\n"), String("b.info:1: BRDA outside SF .. end_of_record"))
    _refused(String("end_of_record\n"), String("end_of_record outside a record"))
    _refused(String("SF:\nend_of_record\n"), String("SF names no file"))
    _refused(String("SF:a\nSF:b\n"), String("SF before the end_of_record"))
    _refused(String("SF:a\nend_of_record\nSF:a\nend_of_record\n"), String("b.info:3: SF a is named a second time"))
    _refused(String("SF:a\nBRDA:2,9:br:0/1,0,1\nBRDA:2,9:br:0/1,1,1\n"), String("b.info:3: the last record has no end_of_record"))
    # The BRDA line itself.
    _refused(_rec(String("BRDA:2,0,0,1\n")), String("BRDA block '0' is not <col>:<kind>:<n>/<N>"))
    _refused(_rec(String("BRDA:2,9:br:0/1,0\n")), String("(4 fields), not 3"))
    _refused(_rec(String("BRDA:2,9:br:0/1,0,1,2\n")), String("(4 fields), not 5"))
    _refused(_rec(String("BRDA:2,9:cond:0/1,0,1\n")), String("kind 'cond' is not br, select, switch, try or rhs"))
    _refused(_rec(String("BRDA:0,9:br:0/1,0,1\n")), String("BRDA line 0 is below 1"))
    _refused(_rec(String("BRDA:2,0:br:0/1,0,1\n")), String("BRDA column 0 is below 1"))
    _refused(_rec(String("BRDA:2,9:br:1/1,0,1\n")), String("<n> must be below <N>"))
    _refused(_rec(String("BRDA:2,9:br:0-1,0,1\n")), String("decision '0-1' is not <n>/<N>"))
    _refused(_rec(String("BRDA:2,9:br:0/0,0,1\n")), String("decision count 0 is below 1"))
    _refused(_rec(String("BRDA:2,9:br:0/1,x,1\n")), String("BRDA arm 'x' is not a decimal number"))
    _refused(_rec(String("BRDA:2,9:br:0/1,0,many\n")), String("BRDA taken 'many' is not a decimal number or -"))
    _refused(_rec(String("BRDA:2,9:br:0/1,0,-1\n")), String("BRDA taken '-1'"))
    _refused(_rec(String("BRDA:2,9:br:0/1,0,1\nBRDA:2,9:br:0/1,0,2\n")), String("b.info:3: BRDA 2,9:br:0/1,0 is given twice in one record"))
    # The record as a whole, at its end_of_record.
    _refused(_rec(String("BRDA:2,9:br:0/1,0,1\nBRDA:2,9:br:0/1,2,1\n")), String("b.info:4: src/alpha/a.mojo: the arms of 2,9:br:0/1 are not 0 to 1 (highest 2)"))
    _refused(_rec(String("BRDA:2,9:br:0/1,0,1\n")), String("2,9:br:0/1 has 1 arms, not 2"))
    _refused(_rec(String("BRDA:2,9:br:0/1,0,1\nBRDA:2,9:br:0/1,1,1\nBRDA:2,9:br:0/1,2,1\n")), String("2,9:br:0/1 has 3 arms, not 2"))
    _refused(_rec(String("BRDA:4,5:switch:0/1,0,1\n")), String("4,5:switch:0/1 has 1 arms, not 2 or more"))
    _refused(_rec(String("BRDA:5,14:try:0/1,0,1\nBRDA:5,14:try:0/1,1,1\nBRDA:5,14:try:0/1,2,1\n")), String("5,14:try:0/1 has 3 arms, not 2"))
    _refused(_rec(String("BRDA:2,9:br:0/2,0,1\nBRDA:2,9:br:0/2,1,1\n")), String("the location 2,9:br has 1 of its 2 decisions"))
    _refused(_rec(String("BRDA:2,9:br:0/2,0,1\nBRDA:2,9:br:0/2,1,1\nBRDA:2,9:br:1/3,0,1\n")), String("b.info:4: BRDA 2,9:br:1/3,0: the location 2,9:br has 2 decisions"))


def _repo() -> RepoFiles:
    var l = List[String]()
    l.append("BUCK")
    l.append("src/alpha/BUCK")
    l.append("src/alpha/a.mojo")
    l.append("src/alpha/b.mojo")
    l.append("src/alpha/c.mojo")
    l.append("src/alpha/tests/test_a.mojo")
    return repo_files_of(l)


def _sources() -> Sources:
    var s = Sources(String(""))
    s.texts[String("src/alpha/a.mojo")] = String("def a():\n    if x:\n        y()\n")
    s.texts[String("src/alpha/b.mojo")] = String("def b():\n    return 1\n")
    # No executable line by the lexer's heuristic: with no record it counts
    # nothing.
    s.texts[String("src/alpha/c.mojo")] = String("# c\n")
    s.texts[String("src/alpha/tests/test_a.mojo")] = String("def main():\n    pass\n")
    return s^


comptime COB_FULL = (
    "<coverage><classes>"
    "<class filename=\"src/alpha/a.mojo\"><lines><line number=\"1\" hits=\"1\"/><line number=\"2\" hits=\"1\"/><line number=\"3\" hits=\"2\"/></lines></class>"
    "<class filename=\"src/alpha/b.mojo\"><lines><line number=\"1\" hits=\"1\"/><line number=\"2\" hits=\"1\"/></lines></class>"
    "</classes></coverage>"
)


def _inputs(cob: String, branch_files: List[String]) -> List[Input]:
    var r = List[Input]()
    r.append(Input(String(FORMAT_COBERTURA), String(""), String("t.xml"), cob))
    for i in range(len(branch_files)):
        r.append(Input(String(FORMAT_BRANCH_LCOV), String(""), String("b") + String(i) + String(".info"), branch_files[i]))
    return r^


def _kinds(a: Analysis) -> String:
    var s = String("")
    for i in range(len(a.findings)):
        if i > 0:
            s += String(" ")
        s += a.findings[i].kind
        if a.findings[i].metric.byte_length() > 0:
            s += String(":") + a.findings[i].metric
    return s^


def _message(a: Analysis, kind: String) -> String:
    """The message of `a`'s first finding of `kind`, or empty."""
    for i in range(len(a.findings)):
        if a.findings[i].kind == kind:
            return a.findings[i].message
    return String("")


def _gate(reports: List[Input], ratchet: String) raises -> Analysis:
    var o = Options()
    o.mode = String("enforce")
    o.only_package = String("src/alpha")
    return analyze(reports, List[Input](), _repo(), parse_ratchet(ratchet, String("r.tsv")), _sources(), o)


def _raises(reports: List[Input], want: String) raises:
    var raised = False
    try:
        _ = _gate(reports, String("src/alpha\t10000\t0\n"))
    except e:
        raised = True
        assert_true(String(e).find(want) >= 0, String(e) + String(" lacks ") + want)
    assert_true(raised, String("accepted, wanted: ") + want)


def test_records_sum_by_id_across_tests() raises:
    # Two tests: '-' + 3 = 3 (taken), '-' + '-' stays not taken, 0 + 2 = 2.
    var b = List[String]()
    b.append(_rec(String("BRDA:2,9:br:0/1,0,-\nBRDA:2,9:br:0/1,1,-\nBRDA:3,9:br:0/1,0,0\nBRDA:3,9:br:0/1,1,1\n")))
    b.append(_rec(String("BRDA:2,9:br:0/1,0,3\nBRDA:2,9:br:0/1,1,-\nBRDA:3,9:br:0/1,0,2\nBRDA:3,9:br:0/1,1,-\n")))
    var a = _gate(_inputs(String(COB_FULL), b), String("src/alpha\t10000\t0\n"))
    assert_equal(a.packages[0].branch_found, 4)
    assert_equal(a.packages[0].branch_hit, 3)
    ref f = a.files[a.file_index(String("src/alpha/a.mojo"))]
    assert_equal(f.branches[String("2,9:br:0/1,0")], 3)
    assert_equal(f.branches[String("2,9:br:0/1,1")], 0)
    # Lines are the line report's alone.
    assert_equal(a.packages[0].line_found, 5)
    assert_equal(a.packages[0].line_hit, 5)


def test_branch_numbers_replace_branch_not_measured() raises:
    # Every line covered (Cobertura, no branch data). Without branch records
    # the one finding is BranchNotMeasured; with them, branch is a number:
    # one arm never taken is BelowTarget on branch and nothing else; both
    # taken, no finding (enforce passes).
    var none = List[String]()
    var n = _gate(_inputs(String(COB_FULL), none), String("src/alpha\t10000\t-\n"))
    assert_equal(_kinds(n), "BranchNotMeasured:branch")
    # Its message names both sources: kcov's (none) and the branch records
    # a gate reads only for a library of COVERAGE_BRANCH_GATE.
    var msg = _message(n, String("BranchNotMeasured"))
    assert_true(msg.find("kcov's Cobertura holds none") >= 0 and msg.find("COVERAGE_BRANCH_GATE") >= 0, msg)
    var half = List[String]()
    half.append(_rec(String("BRDA:2,9:br:0/1,0,4\nBRDA:2,9:br:0/1,1,-\n")) + String(B_NONE))
    var h = _gate(_inputs(String(COB_FULL), half), String("src/alpha\t10000\t0\n"))
    assert_equal(_kinds(h), "BelowTarget:branch")
    assert_equal(h.packages[0].branch_bp(), 5000)
    assert_equal(h.conclusion, "failure")
    var both = List[String]()
    both.append(_rec(String("BRDA:2,9:br:0/1,0,4\nBRDA:2,9:br:0/1,1,-\n")) + String(B_NONE))
    both.append(_rec(String("BRDA:2,9:br:0/1,0,-\nBRDA:2,9:br:0/1,1,1\n")))
    var g = _gate(_inputs(String(COB_FULL), both), String("src/alpha\t10000\t10000\n"))
    assert_equal(_kinds(g), "")
    assert_equal(g.packages[0].branch_bp(), 10000)
    assert_equal(g.conclusion, "success")
    # The branch floor holds: measured below it is a Regression, and a row
    # with '-' a BranchFloorMissing.
    assert_equal(_kinds(_gate(_inputs(String(COB_FULL), half), String("src/alpha\t10000\t10000\n"))), "BelowTarget:branch Regression:branch")
    assert_equal(_kinds(_gate(_inputs(String(COB_FULL), half), String("src/alpha\t10000\t-\n"))), "BelowTarget:branch BranchFloorMissing:branch")
    # An empty branch record file (a test that ran none of the package's
    # decisions) measures no branch.
    var empty = List[String]()
    empty.append(String(""))
    assert_equal(_kinds(_gate(_inputs(String(COB_FULL), empty), String("src/alpha\t10000\t-\n"))), "BranchNotMeasured:branch")
    # A file named with no BRDA (cov_branch_classify saw its code in the
    # test and no decision in it) measures the package's branches: with
    # both files so named there are none to take, so no BranchNotMeasured
    # and no branch number.
    var sf = List[String]()
    sf.append(String("SF:src/alpha/a.mojo\nend_of_record\n") + String(B_NONE))
    var d = _gate(_inputs(String(COB_FULL), sf), String("src/alpha\t10000\t-\n"))
    assert_equal(_kinds(d), "")
    assert_equal(d.packages[0].branch_bp(), -1)
    assert_equal(d.conclusion, "success")
    # The same for a file no line report names (counted from its source).
    var sc = List[String]()
    sc.append(String("SF:src/alpha/a.mojo\nend_of_record\n") + String(B_NONE) + String("SF:src/alpha/c.mojo\nend_of_record\n"))
    assert_equal(_kinds(_gate(_inputs(String(COB_FULL), sc), String("src/alpha\t10000\t-\n"))), "")
    # A left-out test source named so measures nothing of the package.
    var st = List[String]()
    st.append(String("SF:src/alpha/tests/test_a.mojo\nend_of_record\n"))
    assert_equal(_kinds(_gate(_inputs(String(COB_FULL), st), String("src/alpha\t10000\t-\n"))), "BranchNotMeasured:branch")


def test_decision_count_conflict_refused() raises:
    # Two tests give one location (line 2, column 9, br) a different number
    # of decisions: their copies of the code hold different ones, and
    # summing `<n>/<N>` by id would add unrelated arms.
    var b = List[String]()
    b.append(_rec(String("BRDA:2,9:br:0/1,0,1\nBRDA:2,9:br:0/1,1,0\n")))
    b.append(_rec(String("BRDA:2,9:br:0/2,0,1\nBRDA:2,9:br:0/2,1,0\nBRDA:2,9:br:1/2,0,0\nBRDA:2,9:br:1/2,1,1\n")))
    _raises(_inputs(String(COB_FULL), b),
        String("src/alpha/a.mojo:2: b0.info gives 1 decision(s) at 9:br and b1.info gives 2: the tests' copies of this code hold different decisions at one location, so their branch records cannot be summed by id"))
    # The same N on another kind at that column is another location.
    var k = List[String]()
    k.append(_rec(String("BRDA:2,9:br:0/1,0,1\nBRDA:2,9:br:0/1,1,0\n")))
    k.append(_rec(String("BRDA:2,9:select:0/2,0,1\nBRDA:2,9:select:0/2,1,0\nBRDA:2,9:select:1/2,0,0\nBRDA:2,9:select:1/2,1,1\n")))
    assert_equal(_gate(_inputs(String(COB_FULL), k), String("src/alpha\t10000\t0\n")).packages[0].branch_found, 6)
    # One decision with another number of arms (a switch).
    var s = List[String]()
    s.append(_rec(String("BRDA:4,5:switch:0/1,0,1\nBRDA:4,5:switch:0/1,1,0\n")))
    s.append(_rec(String("BRDA:4,5:switch:0/1,0,1\nBRDA:4,5:switch:0/1,1,0\nBRDA:4,5:switch:0/1,2,0\n")))
    _raises(_inputs(String(COB_FULL), s), String("src/alpha/a.mojo:4: b0.info gives the decision 4,5:switch:0/1 2 arms and b1.info gives it 3"))
    # A file the gate leaves out (a test source) is not checked: its
    # records count nowhere.
    var t = List[String]()
    t.append(String("SF:src/alpha/tests/test_a.mojo\nBRDA:2,5:br:0/1,0,1\nBRDA:2,5:br:0/1,1,1\nend_of_record\n"))
    t.append(String("SF:src/alpha/tests/test_a.mojo\nBRDA:2,5:br:0/2,0,1\nBRDA:2,5:br:0/2,1,1\nBRDA:2,5:br:1/2,0,1\nBRDA:2,5:br:1/2,1,1\nend_of_record\n"))
    var ta = _gate(_inputs(String(COB_FULL), t), String("src/alpha\t10000\t-\n"))
    assert_equal(ta.excluded_test_files, 1)
    assert_equal(ta.packages[0].branch_found, 0)


def test_one_report_names_a_file_once() raises:
    # Two spellings in one branch record file that map to one repository
    # path would count that test's arms twice: refused. Two files naming it
    # are two tests, summed (test_records_sum_by_id_across_tests).
    var b = List[String]()
    b.append(_rec(String("BRDA:2,9:br:0/1,0,1\nBRDA:2,9:br:0/1,1,0\n"))
        + String("SF:./src/alpha/a.mojo\nBRDA:2,9:br:0/1,0,1\nBRDA:2,9:br:0/1,1,0\nend_of_record\n"))
    _raises(_inputs(String(COB_FULL), b), String("b0.info: SF ./src/alpha/a.mojo is src/alpha/a.mojo, which an earlier SF of this file names: one test's records would be counted twice"))


def test_one_source_of_branch_data_per_file() raises:
    # Cobertura condition-coverage and branch records for one file: refused.
    var cob = String(
        "<coverage><classes><class filename=\"src/alpha/a.mojo\"><lines>"
        "<line number=\"2\" hits=\"1\" branch=\"true\" condition-coverage=\"50% (1/2)\"/></lines></class></classes></coverage>"
    )
    var b = List[String]()
    b.append(_rec(String("BRDA:2,9:br:0/1,0,1\nBRDA:2,9:br:0/1,1,0\n")))
    _raises(_inputs(cob, b), String("src/alpha/a.mojo: branch records come from both the line report t.xml and the branch record file b0.info"))
    # So for an lcov BRDA, read with branch records as Cobertura is.
    var l = List[Input]()
    l.append(Input(String(FORMAT_LCOV), String(""), String("t.info"), String("SF:src/alpha/a.mojo\nDA:2,1\nBRDA:2,0,0,1\nBRDA:2,0,1,1\nend_of_record\n")))
    l.append(Input(String(FORMAT_BRANCH_LCOV), String(""), String("b.info"), b[0]))
    _raises(l, String("from both the line report t.info and the branch record file b.info"))
    # Branch records for another file than the line report's branches are
    # read; the two formats of line reports are still never mixed.
    var other = List[String]()
    other.append(String("SF:src/alpha/b.mojo\nBRDA:2,5:br:0/1,0,1\nBRDA:2,5:br:0/1,1,1\nend_of_record\n"))
    assert_equal(_gate(_inputs(cob, other), String("src/alpha\t10000\t0\n")).packages[0].branch_found, 4)
    var mix = _inputs(String(COB_FULL), other)
    mix.append(Input(String(FORMAT_LCOV), String(""), String("t.info"), String("SF:src/alpha/a.mojo\nDA:2,1\nend_of_record\n")))
    _raises(mix, String("the reports mix cobertura (t.xml) and lcov (t.info)"))


def test_branches_of_a_file_no_line_report_names() raises:
    # A file only branch records name: its lines count from its source (no
    # test compiled it as far as line coverage knows: UnmeasuredFile), and
    # its branches still count. A test source's records are left out.
    var cob = String("<coverage><classes><class filename=\"src/alpha/b.mojo\"><lines><line number=\"1\" hits=\"1\"/><line number=\"2\" hits=\"1\"/></lines></class></classes></coverage>")
    var b = List[String]()
    b.append(_rec(String("BRDA:2,9:br:0/1,0,1\nBRDA:2,9:br:0/1,1,-\n")) + String(B_NONE)
        + String("SF:src/alpha/tests/test_a.mojo\nBRDA:2,5:br:0/1,0,1\nBRDA:2,5:br:0/1,1,1\nend_of_record\n"))
    var a = _gate(_inputs(cob, b), String("src/alpha\t0\t0\n"))
    assert_equal(a.packages[0].unmeasured_files, 1)
    assert_equal(a.packages[0].branch_found, 2)
    assert_equal(a.packages[0].branch_hit, 1)
    assert_equal(a.excluded_test_files, 1)
    assert_equal(_kinds(a), "BelowTarget:branch BelowTarget:line UnmeasuredFile")
    # Its branch records show an arm taken, so the finding says the two
    # measurements disagree rather than that no test compiled it.
    assert_equal(_message(a, String("UnmeasuredFile")), "no line report names this file, yet its branch records show 1 arm(s) taken: the line and branch measurements disagree on whether it ran; its 3 executable lines count as not covered")
    var nr = List[String]()
    nr.append(_rec(String("BRDA:2,9:br:0/1,0,-\nBRDA:2,9:br:0/1,1,-\n")) + String(B_NONE))
    assert_equal(_message(_gate(_inputs(cob, nr), String("src/alpha\t0\t0\n")), String("UnmeasuredFile")), "no test binary compiled this file: its 3 executable lines count as not covered")
    # Branch records keep such a file in the count even when the heuristic
    # finds no executable line in it.
    var c = List[String]()
    c.append(String("SF:src/alpha/a.mojo\nend_of_record\n") + String(B_NONE) + String("SF:src/alpha/c.mojo\nBRDA:1,3:br:0/1,0,1\nBRDA:1,3:br:0/1,1,1\nend_of_record\n"))
    var k = _gate(_inputs(String(COB_FULL), c), String("src/alpha\t0\t0\n"))
    assert_equal(k.packages[0].branch_found, 2)
    assert_equal(k.packages[0].branch_hit, 2)
    assert_equal(_kinds(k), "")


def test_file_no_branch_record_file_names() raises:
    # COB_FULL gives a.mojo and b.mojo line records; the branch records
    # name a.mojo alone. b.mojo's branches were not read (the classifier
    # names every measured file its test holds code of), so counting it as
    # none would lift the package's branch number: BranchUnmeasuredFile on
    # b.mojo, a failure in enforce mode. The numbers are a.mojo's.
    var b = List[String]()
    b.append(_rec(String("BRDA:2,9:br:0/1,0,1\nBRDA:2,9:br:0/1,1,1\n")))
    var a = _gate(_inputs(String(COB_FULL), b), String("src/alpha\t10000\t10000\n"))
    assert_equal(_kinds(a), "BranchUnmeasuredFile")
    assert_equal(a.findings[0].path, "src/alpha/b.mojo")
    assert_equal(a.findings[0].package, "src/alpha")
    assert_equal(_message(a, String("BranchUnmeasuredFile")), "a line report names this file, but no branch record file of its package does: its branches were not measured (cov_branch_classify names every measured file its test holds code of), so the package's branch numbers leave it out")
    assert_equal(a.packages[0].branch_bp(), 10000)
    assert_equal(a.conclusion, "failure")
    # In census mode the same finding is listed and the run is neutral.
    var o = Options()
    o.mode = String("census")
    o.only_package = String("src/alpha")
    var c = analyze(_inputs(String(COB_FULL), b), List[Input](), _repo(), parse_ratchet(String("src/alpha\t10000\t10000\n"), String("r.tsv")), _sources(), o)
    assert_equal(_kinds(c), "BranchUnmeasuredFile")
    assert_equal(c.conclusion, "neutral")
    # Named with no BRDA (code, no decision), b.mojo is measured: no finding.
    var named = List[String]()
    named.append(_rec(String("BRDA:2,9:br:0/1,0,1\nBRDA:2,9:br:0/1,1,1\n")) + String(B_NONE))
    assert_equal(_kinds(_gate(_inputs(String(COB_FULL), named), String("src/alpha\t10000\t10000\n"))), "")
    # A package no branch record file names a kept file of keeps
    # BranchNotMeasured alone, with no finding per file.
    var none = List[String]()
    assert_equal(_kinds(_gate(_inputs(String(COB_FULL), none), String("src/alpha\t10000\t-\n"))), "BranchNotMeasured:branch")
    # A file whose line report gives its own branch records is measured.
    var l = List[Input]()
    l.append(Input(String(FORMAT_LCOV), String(""), String("t.info"), String(
        "SF:src/alpha/a.mojo\nDA:1,1\nDA:2,1\nDA:3,1\nend_of_record\n"
        "SF:src/alpha/b.mojo\nDA:1,1\nDA:2,1\nBRDA:2,0,0,1\nBRDA:2,0,1,1\nend_of_record\n"
    )))
    l.append(Input(String(FORMAT_BRANCH_LCOV), String(""), String("b.info"), b[0]))
    var lb = _gate(l, String("src/alpha\t10000\t10000\n"))
    assert_equal(_kinds(lb), "")
    assert_equal(lb.packages[0].branch_found, 4)


def test_annotations_of_branch_records() raises:
    # An arm never taken is a `Branch not covered` annotation on its line,
    # counted over every arm of the line (both locations of line 3).
    var b = List[String]()
    b.append(String(ONE))
    var o = Options()
    var a = analyze(_inputs(String(COB_FULL), b), List[Input](), _repo(), Ratchet(), _sources(), o)
    var d = parse_diff(String("diff --git a/src/alpha/a.mojo b/src/alpha/a.mojo\n--- a/src/alpha/a.mojo\n+++ b/src/alpha/a.mojo\n@@ -1,0 +2 @@\n+x\n"))
    var anns = annotations(a, d, touched_packages(a, d, _repo()))
    var got = String("")
    for i in range(len(anns)):
        if anns[i].title == String("Branch not covered"):
            got += anns[i].path + String(":") + String(anns[i].start_line) + String(" ") + anns[i].message + String("\n")
    assert_equal(got, "src/alpha/a.mojo:2 0 of 2 branches taken on this line\nsrc/alpha/a.mojo:3 2 of 4 branches taken on this line\n")


def main() raises:
    test_reader_keys_counts_and_dash()
    test_reader_refusals()
    test_records_sum_by_id_across_tests()
    test_branch_numbers_replace_branch_not_measured()
    test_decision_count_conflict_refused()
    test_one_report_names_a_file_once()
    test_one_source_of_branch_data_per_file()
    test_branches_of_a_file_no_line_report_names()
    test_file_no_branch_record_file_names()
    test_annotations_of_branch_records()
    print("test_branch_lcov: PASS")
