from std.testing import assert_equal, assert_true

from covcheck.analyze import FORMAT_COBERTURA, FORMAT_LCOV, Analysis, Input, Options, Sources, analyze
from covcheck.paths import RepoFiles, repo_files_of
from covcheck.ratchet import Ratchet, parse_ratchet
from covcheck.result import package_json
from covcheck.stats import is_info_package
from covcheck.text import render_bp

# The one computation behind `report` and `gate`: merging reports, test
# sources, exemptions, mutants, the target, conclusions per mode, and the
# gate's numbers being the report's.


def _repo(with_b: Bool = False) -> RepoFiles:
    """src/alpha is a.mojo (and b.mojo when `with_b`) and a test; src/beta
    is c.mojo. A test that reports only a.mojo leaves no file of src/alpha
    out (the full-source denominator is test_full_source's)."""
    var l = List[String]()
    l.append("BUCK")
    l.append("src/alpha/BUCK")
    l.append("src/alpha/a.mojo")
    if with_b:
        l.append("src/alpha/b.mojo")
    l.append("src/alpha/tests/test_a.mojo")
    l.append("src/beta/BUCK")
    l.append("src/beta/c.mojo")
    return repo_files_of(l)


def _sources() -> Sources:
    """Sources with no marker, for every file the tests measure."""
    var s = Sources(String(""))
    s.texts[String("src/alpha/a.mojo")] = String("a\nb\nc\nd\n")
    s.texts[String("src/alpha/b.mojo")] = String("a\nb\nc\n")
    s.texts[String("src/alpha/tests/test_a.mojo")] = String("a\nb\n")
    s.texts[String("src/beta/c.mojo")] = String("a\nb\nc\n")
    return s^


def _lcov(text: String) -> List[Input]:
    var l = List[Input]()
    l.append(Input(String(FORMAT_LCOV), String(""), String("t.info"), text))
    return l^


def _none() -> List[Input]:
    return List[Input]()


def _run(reports: List[Input], mutants: List[Input], sources: Sources, opts: Options) raises -> Analysis:
    return analyze(reports, mutants, _repo(), Ratchet(), sources, opts)


def _kinds(a: Analysis) -> String:
    var s = String("")
    for i in range(len(a.findings)):
        if i > 0:
            s += String(" ")
        s += a.findings[i].kind
        if a.findings[i].metric.byte_length() > 0:
            s += String(":") + a.findings[i].metric
    return s^


def test_two_cobertura_inputs_sum_per_line() raises:
    # One test binary reached line 1, the other line 2: both covered.
    var r = List[Input]()
    r.append(Input(String(FORMAT_COBERTURA), String(""), String("one.xml"), String(
        "<coverage><classes><class filename=\"src/alpha/a.mojo\"><lines>"
        "<line number=\"1\" hits=\"0\"/><line number=\"2\" hits=\"1\"/></lines></class></classes></coverage>"
    )))
    r.append(Input(String(FORMAT_COBERTURA), String(""), String("two.xml"), String(
        "<coverage><classes><class filename=\"src/alpha/a.mojo\"><lines>"
        "<line number=\"1\" hits=\"3\"/><line number=\"2\" hits=\"0\"/></lines></class></classes></coverage>"
    )))
    var a = _run(r, _none(), _sources(), Options())
    assert_equal(len(a.packages), 1)
    assert_equal(a.packages[0].line_found, 2)
    assert_equal(a.packages[0].line_hit, 2)
    assert_equal(a.packages[0].files, 1)


def test_test_sources_left_out_by_default() raises:
    var r = List[Input]()
    r.append(Input(String(FORMAT_LCOV), String("src/alpha"), String("t.info"), String(
        "SF:tests/test_a.mojo\nDA:1,0\nend_of_record\nSF:src/alpha/a.mojo\nDA:1,1\nend_of_record\n"
    )))
    var a = _run(r, _none(), _sources(), Options())
    assert_equal(a.excluded_test_files, 1)
    assert_equal(a.packages[0].line_found, 1)
    assert_equal(a.packages[0].line_hit, 1)
    var o = Options()
    o.include_tests = True
    var b = _run(r, _none(), _sources(), o)
    assert_equal(b.excluded_test_files, 0)
    assert_equal(b.packages[0].line_found, 2)
    assert_equal(b.packages[0].line_hit, 1)


def test_named_test_sources_left_out() raises:
    # A welded test outside <package>/tests/ (the gate's --test-source) is
    # left out like one under it: counted as a test source, not measured,
    # and not a file no test compiled. Without the option it is source.
    var l = List[String]()
    l.append("src/alpha/BUCK")
    l.append("src/alpha/a.mojo")
    l.append("src/alpha/wire/tests/test_w.mojo")
    l.append("src/alpha/test_top.mojo")
    var repo = repo_files_of(l)
    var s = _sources()
    s.texts[String("src/alpha/wire/tests/test_w.mojo")] = String("a\nb\n")
    s.texts[String("src/alpha/test_top.mojo")] = String("a\nb\nc\n")
    var r = _lcov(String(
        "SF:src/alpha/a.mojo\nDA:1,1\nend_of_record\nSF:src/alpha/wire/tests/test_w.mojo\nDA:1,1\nDA:2,0\nend_of_record\n"
    ))
    var o = Options()
    o.only_package = String("src/alpha")
    o.target_bp = 0
    var plain = analyze(r, _none(), repo, Ratchet(), s, o)
    assert_equal(plain.excluded_test_files, 0)
    assert_equal(plain.packages[0].line_found, 6)
    assert_equal(plain.packages[0].unmeasured_files, 1)
    o.test_sources[String("src/alpha/wire/tests/test_w.mojo")] = True
    o.test_sources[String("src/alpha/test_top.mojo")] = True
    var named = analyze(r, _none(), repo, Ratchet(), s, o)
    assert_equal(named.excluded_test_files, 1)
    assert_equal(named.packages[0].line_found, 1)
    assert_equal(named.packages[0].line_hit, 1)
    assert_equal(named.packages[0].unmeasured_files, 0)
    o.include_tests = True
    assert_equal(analyze(r, _none(), repo, Ratchet(), s, o).packages[0].line_found, 6)


def test_basis_points_round_down() raises:
    var a = _run(_lcov(String("SF:src/alpha/a.mojo\nDA:1,1\nDA:2,1\nDA:3,0\nend_of_record\n")), _none(), _sources(), Options())
    assert_equal(a.packages[0].line_bp(), 6666)
    assert_equal(render_bp(a.packages[0].line_bp()), "66.66%")
    assert_equal(render_bp(5), "0.05%")
    assert_equal(render_bp(10000), "100.00%")


def test_exemptions_change_the_counts_and_find_stale_and_reasonless() raises:
    var s = _sources()
    s.texts[String("src/alpha/a.mojo")] = String(
        "covered()  # cov: unreachable but it is covered\n"
        "never()  # cov: unreachable only on a corrupt heap\n"
        "missed()\n"
        "also()  # cov: unreachable\n"
    )
    var a = _run(_lcov(String("SF:src/alpha/a.mojo\nDA:1,1\nDA:2,0\nDA:3,0\nDA:4,0\nBRDA:2,0,0,0\nend_of_record\n")), _none(), s, Options())
    # Line 2 left the counts (and its branch); 1 (stale) and 4 (no reason) did not.
    assert_equal(a.packages[0].line_found, 3)
    assert_equal(a.packages[0].line_hit, 1)
    assert_equal(a.packages[0].branch_found, 0)
    assert_equal(a.packages[0].exempt_lines, 1)
    assert_equal(len(a.exemptions), 3)
    assert_equal(a.exemptions[0].status, "stale")
    assert_equal(a.exemptions[1].status, "exempt")
    assert_equal(a.exemptions[2].status, "no reason")
    assert_equal(_kinds(a), "BelowTarget:line MissingRow:line StaleExemption ExemptionWithoutReason")


def test_mutants_score_and_survivors() raises:
    var m = List[Input]()
    m.append(Input(String("mutants"), String(""), String("m.tsv"), String(
        "src/alpha/a.mojo\t1\tkilled\top\td\n"
        "src/alpha/a.mojo\t2\tsurvived\top\tflip\n"
        "src/alpha/a.mojo\t3\ttimeout\top\td\n"
        "src/alpha/a.mojo\t4\terror\top\td\n"
        "oss/modular/mojo/stdlib/std/x.mojo\t1\tsurvived\top\td\n"
    )))
    var a = _run(_lcov(String("SF:src/alpha/a.mojo\nDA:1,1\nend_of_record\n")), m, _sources(), Options())
    ref p = a.packages[0]
    assert_equal(p.mutants, 4)
    assert_equal(p.killed, 1)
    assert_equal(p.survived, 1)
    assert_equal(p.timeout, 1)
    assert_equal(p.error, 1)
    assert_equal(p.mutation_bp(), 2500)
    assert_equal(a.ignored_mutants, 1)
    assert_equal(_kinds(a), "BranchNotMeasured:branch MissingRow:line MutantSurvived")
    assert_equal(a.findings[2].path, "src/alpha/a.mojo")
    assert_equal(a.findings[2].line, 2)


def test_target_and_branch_na() raises:
    var t = String("SF:src/alpha/a.mojo\nDA:1,1\nDA:2,0\nend_of_record\n")
    var o = Options()
    o.target_bp = 5000
    var a = _run(_lcov(t), _none(), _sources(), o)
    assert_equal(a.packages[0].branch_bp(), -1)
    # No branch record: n/a, and not measured, which no target accepts.
    assert_equal(_kinds(a), "BranchNotMeasured:branch MissingRow:line")
    o.target_bp = 5001
    var b = _run(_lcov(t), _none(), _sources(), o)
    assert_equal(_kinds(b), "BelowTarget:line BranchNotMeasured:branch MissingRow:line")


def test_conclusion_per_mode() raises:
    var t = _lcov(String("SF:src/alpha/a.mojo\nDA:1,0\nend_of_record\n"))
    var o = Options()
    o.mode = String("census")
    assert_equal(_run(t, _none(), _sources(), o).conclusion, "neutral")
    o.mode = String("neutral")
    assert_equal(_run(t, _none(), _sources(), o).conclusion, "neutral")
    o.mode = String("enforce")
    assert_equal(_run(t, _none(), _sources(), o).conclusion, "failure")
    var clean = _lcov(String("SF:src/alpha/a.mojo\nDA:1,1\nBRDA:1,0,0,1\nBRDA:1,0,1,1\nend_of_record\n"))
    var r = parse_ratchet(String("src/alpha\t10000\t10000\n"), String("r.tsv"))
    var ok = analyze(clean, _none(), _repo(), r, _sources(), o)
    assert_equal(len(ok.findings), 0)
    assert_equal(ok.conclusion, "success")


def test_branch_not_measured() raises:
    # Every line covered, a ratchet row, no branch record (kcov's Cobertura
    # has none): the one finding is BranchNotMeasured, so enforce fails and
    # census lists it; branch is n/a, never read as meeting the target.
    var t = _lcov(String("SF:src/alpha/a.mojo\nDA:1,1\nDA:2,1\nend_of_record\n"))
    var r = parse_ratchet(String("src/alpha\t10000\t-\n"), String("r.tsv"))
    var o = Options()
    o.mode = String("enforce")
    var a = analyze(t, _none(), _repo(), r, _sources(), o)
    assert_equal(_kinds(a), "BranchNotMeasured:branch")
    assert_equal(a.packages[0].line_bp(), 10000)
    assert_equal(a.packages[0].branch_bp(), -1)
    assert_equal(a.findings[0].bound, 10000)
    assert_equal(a.findings[0].measured, -1)
    assert_equal(a.conclusion, "failure")
    o.mode = String("census")
    var c = analyze(t, _none(), _repo(), r, _sources(), o)
    assert_equal(_kinds(c), "BranchNotMeasured:branch")
    assert_equal(c.conclusion, "neutral")
    # The gate's findings are the report's.
    o.only_package = String("src/alpha")
    assert_equal(_kinds(analyze(t, _none(), _repo(), r, _sources(), o)), "BranchNotMeasured:branch")
    # A branch record makes it measured, even when a marker then takes the
    # branch out of the count (branch n/a, but measured and exempted).
    var s = _sources()
    s.texts[String("src/alpha/a.mojo")] = String("a\nb  # cov: unreachable only on a corrupt heap\nc\nd\n")
    var e = _lcov(String("SF:src/alpha/a.mojo\nDA:1,1\nDA:2,1\nBRDA:2,0,0,0\nBRDA:2,0,1,1\nend_of_record\n"))
    var x = analyze(e, _none(), _repo(), parse_ratchet(String("src/alpha\t10000\t-\n"), String("r.tsv")), s, Options())
    assert_equal(x.packages[0].branch_found, 0)
    assert_true(_kinds(x).find("BranchNotMeasured") < 0, _kinds(x))
    # With no target there is nothing to fall short of; a package with no
    # line record is NotMeasured, not BranchNotMeasured as well.
    var z = Options()
    z.target_bp = 0
    assert_equal(_kinds(analyze(t, _none(), _repo(), r, _sources(), z)), "")
    # Any target above 0 asks for branches: 1 basis point is enough.
    z.target_bp = 1
    assert_equal(_kinds(analyze(t, _none(), _repo(), r, _sources(), z)), "BranchNotMeasured:branch")
    var g = Options()
    g.only_package = String("src/beta")
    assert_equal(_kinds(analyze(t, _none(), _repo(), r, _sources(), g)), "BelowTarget:line MissingRow:line NotMeasured:line UnmeasuredFile")


def test_gate_numbers_equal_the_report() raises:
    # Exemptions, merged reports, test sources and mutants in two packages:
    # the gate's entry for src/alpha is the report's, byte for byte.
    var s = _sources()
    s.texts[String("src/alpha/b.mojo")] = String("x\ny  # cov: unreachable never\nz\n")
    var r = List[Input]()
    r.append(Input(String(FORMAT_LCOV), String("src/alpha"), String("one.info"), String(
        "SF:src/alpha/a.mojo\nDA:1,0\nDA:2,4\nBRDA:2,0,0,1\nBRDA:2,0,1,-\nend_of_record\n"
        "SF:tests/test_a.mojo\nDA:1,1\nend_of_record\n"
        "SF:src/beta/c.mojo\nDA:1,1\nend_of_record\n"
    )))
    r.append(Input(String(FORMAT_LCOV), String(""), String("two.info"), String(
        "SF:src/alpha/a.mojo\nDA:1,2\nDA:3,0\nend_of_record\n"
        "SF:src/alpha/b.mojo\nDA:1,1\nDA:2,0\nDA:3,0\nend_of_record\n"
    )))
    var m = List[Input]()
    m.append(Input(String("mutants"), String(""), String("m.tsv"), String(
        "src/alpha/a.mojo\t1\tsurvived\top\td\nsrc/beta/c.mojo\t1\tkilled\top\td\n"
    )))
    var rat = parse_ratchet(String("src/alpha\t9000\t-\nsrc/beta\t1\t-\n"), String("r.tsv"))
    var full = analyze(r, m, _repo(True), rat, s, Options())
    var o = Options()
    o.only_package = String("src/alpha")
    var gate = analyze(r, m, _repo(True), rat, s, o)
    assert_equal(len(gate.packages), 1)
    var k = full.package_index(String("src/alpha"))
    assert_true(k >= 0)
    assert_equal(package_json(gate.packages[0]), package_json(full.packages[k]))
    var want = String("")
    for i in range(len(full.findings)):
        if full.findings[i].package == String("src/alpha"):
            want += full.findings[i].kind + String(" ") + full.findings[i].message + String("\n")
    var got = String("")
    for i in range(len(gate.findings)):
        got += gate.findings[i].kind + String(" ") + gate.findings[i].message + String("\n")
    assert_equal(got, want)
    # And the numbers themselves: a.mojo 1,2 hit (summed), 3 not; b.mojo 1
    # hit, 2 exempt, 3 not.
    assert_equal(gate.packages[0].line_found, 5)
    assert_equal(gate.packages[0].line_hit, 3)
    assert_equal(gate.packages[0].branch_found, 2)
    assert_equal(gate.packages[0].branch_hit, 1)


def test_gate_on_a_package_with_no_data_fails() raises:
    # The gated package has a BUCK file and a ratchet row but no report
    # covers it (a forgotten strip prefix sends every path elsewhere): it
    # cannot pass by having nothing measured. The gated package is always
    # measured, so its one source file counts too: 4 lines, none covered.
    var o = Options()
    o.only_package = String("src/alpha")
    o.mode = String("enforce")
    var rat = parse_ratchet(String("src/alpha\t9000\t-\n"), String("r.tsv"))
    var a = analyze(_lcov(String("SF:src/beta/c.mojo\nDA:1,1\nend_of_record\n")), _none(), _repo(), rat, _sources(), o)
    assert_equal(_kinds(a), "BelowTarget:line NotMeasured:line Regression:line UnmeasuredFile")
    assert_equal(a.packages[0].line_found, 4)
    assert_equal(a.packages[0].unmeasured_files, 1)
    assert_equal(a.conclusion, "failure")
    # The report: a package present only through its mutants is not measured.
    var m = List[Input]()
    m.append(Input(String("mutants"), String(""), String("m.tsv"), String("src/beta/c.mojo\t1\tkilled\top\td\n")))
    var b = _run(_lcov(String("SF:src/alpha/a.mojo\nDA:1,1\nend_of_record\n")), m, _sources(), Options())
    assert_equal(_kinds(b), "BranchNotMeasured:branch MissingRow:line NotMeasured:line")
    # With no target there is nothing to fall short of.
    var o0 = Options()
    o0.target_bp = 0
    assert_equal(_kinds(_run(_lcov(String("SF:src/alpha/a.mojo\nDA:1,1\nend_of_record\n")), m, _sources(), o0)), "MissingRow:line")


def test_mixed_formats_refused() raises:
    var r = _lcov(String("SF:src/alpha/a.mojo\nBRDA:3,0,0,1\nBRDA:3,0,1,0\nDA:3,1\nend_of_record\n"))
    r.append(Input(String(FORMAT_COBERTURA), String(""), String("c.xml"), String(
        "<coverage><classes><class filename=\"src/alpha/a.mojo\"><lines>"
        "<line number=\"3\" hits=\"1\" branch=\"true\" condition-coverage=\"50% (1/2)\"/></lines></class></classes></coverage>"
    )))
    var raised = False
    try:
        _ = _run(r, _none(), _sources(), Options())
    except e:
        raised = True
        assert_true(String(e).find("the reports mix lcov (t.info) and cobertura (c.xml)") >= 0, String(e))
    assert_true(raised)


def test_unmapped_paths_are_an_error_naming_each() raises:
    var raised = False
    try:
        _ = _run(_lcov(String("SF:src/alpha/gone.mojo\nDA:1,1\nend_of_record\nSF:src/beta/gone2.mojo\nDA:1,1\nend_of_record\n")), _none(), _sources(), Options())
    except e:
        raised = True
        var msg = String(e)
        assert_true(msg.find("src/alpha/gone.mojo") >= 0, msg)
        assert_true(msg.find("src/beta/gone2.mojo") >= 0, msg)
    assert_true(raised)


def test_outside_files_are_counted_once() raises:
    var a = _run(_lcov(String(
        "SF:/opt/mojo/std/a.mojo\nDA:1,1\nend_of_record\n"
        "SF:/opt/mojo/std/a.mojo\nDA:2,1\nend_of_record\n"
        "SF:oss/modular/mojo/stdlib/std/b.mojo\nDA:1,1\nend_of_record\n"
        "SF:src/alpha/a.mojo\nDA:1,1\nend_of_record\n"
    )), _none(), _sources(), Options())
    assert_equal(a.ignored_files, 2)
    assert_equal(a.total.line_found, 1)


def test_missing_source_is_an_error() raises:
    var raised = False
    try:
        _ = _run(_lcov(String("SF:src/alpha/a.mojo\nDA:1,1\nend_of_record\n")), _none(), Sources(String("")), Options())
    except e:
        raised = True
        assert_true(String(e).find("no source for src/alpha/a.mojo") >= 0)
    assert_true(raised)


def test_enforce_fails_on_a_single_finding() raises:
    # Fully covered, its branch too, but no ratchet row: exactly one
    # finding, and one finding is enough for `failure` in enforce mode
    # (neutral stays neutral).
    var t = _lcov(String("SF:src/alpha/a.mojo\nDA:1,1\nBRDA:1,0,0,1\nend_of_record\n"))
    var o = Options()
    o.mode = String("enforce")
    var a = _run(t, _none(), _sources(), o)
    assert_equal(_kinds(a), "MissingRow:line")
    assert_equal(a.conclusion, "failure")
    o.mode = String("neutral")
    assert_equal(_run(t, _none(), _sources(), o).conclusion, "neutral")


def test_unmapped_mutant_path_is_an_error() raises:
    # A mutants row naming a repository directory but no repository file is
    # an error like an unmapped report path, never counted as outside.
    var m = List[Input]()
    m.append(Input(String("mutants"), String(""), String("m.tsv"), String("src/alpha/gone.mojo\t1\tsurvived\top\td\n")))
    var raised = False
    try:
        _ = _run(_lcov(String("SF:src/alpha/a.mojo\nDA:1,1\nend_of_record\n")), m, _sources(), Options())
    except e:
        raised = True
        var msg = String(e)
        assert_true(msg.find("m.tsv") >= 0, msg)
        assert_true(msg.find("src/alpha/gone.mojo") >= 0, msg)
    assert_true(raised)


def test_info_packages() raises:
    # A test-only package's findings are information (step 8): out of
    # `findings`, so out of the conclusion; a directory covers itself and
    # what is under it, at a segment boundary.
    var dirs = List[String]()
    dirs.append("src/tests")
    assert_true(is_info_package(String("src/tests"), dirs))
    assert_true(is_info_package(String("src/tests/e2e/komira_x_e2e"), dirs))
    assert_true(not is_info_package(String("src/testsuite"), dirs))
    assert_true(not is_info_package(String("src/komira_x"), dirs))
    assert_true(not is_info_package(String("(root)"), dirs))
    var t = _lcov(String("SF:src/alpha/a.mojo\nDA:1,0\nend_of_record\nSF:src/beta/c.mojo\nDA:1,0\nend_of_record\n"))
    var o = Options()
    o.mode = String("enforce")
    o.info_packages.append("src/beta")
    var a = _run(t, _none(), _sources(), o)
    assert_equal(_kinds(a), "BelowTarget:line BranchNotMeasured:branch MissingRow:line")
    assert_equal(len(a.info_findings), 3)
    for i in range(len(a.findings)):
        assert_equal(a.findings[i].package, "src/alpha")
    for i in range(len(a.info_findings)):
        assert_equal(a.info_findings[i].package, "src/beta")
    assert_equal(len(a.info_packages), 1)
    assert_equal(a.info_packages[0], "src/beta")
    assert_equal(len(a.packages), 2)
    assert_equal(a.conclusion, "failure")
    o.info_packages.append("src/alpha")
    var b = _run(t, _none(), _sources(), o)
    assert_equal(len(b.findings), 0)
    assert_equal(len(b.info_findings), 6)
    assert_equal(b.conclusion, "success")
    # A row a test-only package has: its Regression is information too,
    # and the proposal raises no floor and adds no row for it.
    var r = parse_ratchet(String("src/beta\t9000\t-\n"), String("r.tsv"))
    var o2 = Options()
    o2.mode = String("enforce")
    o2.info_packages.append("src/beta")
    var c = analyze(t, _none(), _repo(), r, _sources(), o2)
    var info = String("")
    for i in range(len(c.info_findings)):
        info += c.info_findings[i].kind + String(" ")
    assert_true(info.find("Regression") >= 0, info)
    for i in range(len(c.findings)):
        assert_true(c.findings[i].package != "src/beta")
    # alpha gets its proposed row; beta keeps its row as it was, not
    # lowered to the 0% measured nor raised.
    assert_equal(len(c.proposal.rows), 2)
    assert_equal(c.proposal.rows[0].package, "src/alpha")
    assert_equal(c.proposal.rows[1].package, "src/beta")
    assert_equal(c.proposal.rows[1].line_floor, 9000)
    # With no row: a test-only package gets none proposed.
    var e = analyze(t, _none(), _repo(), Ratchet(), _sources(), o2)
    assert_equal(len(e.proposal.rows), 1)
    assert_equal(e.proposal.rows[0].package, "src/alpha")
    o2.info_packages = List[String]()
    var d = analyze(t, _none(), _repo(), r, _sources(), o2)
    var kinds = String("")
    for i in range(len(d.findings)):
        kinds += d.findings[i].package + String(":") + d.findings[i].kind + String(" ")
    assert_true(kinds.find("src/beta:Regression") >= 0, kinds)


def main() raises:
    test_two_cobertura_inputs_sum_per_line()
    test_test_sources_left_out_by_default()
    test_named_test_sources_left_out()
    test_basis_points_round_down()
    test_exemptions_change_the_counts_and_find_stale_and_reasonless()
    test_mutants_score_and_survivors()
    test_target_and_branch_na()
    test_conclusion_per_mode()
    test_branch_not_measured()
    test_enforce_fails_on_a_single_finding()
    test_gate_numbers_equal_the_report()
    test_gate_on_a_package_with_no_data_fails()
    test_mixed_formats_refused()
    test_unmapped_paths_are_an_error_naming_each()
    test_unmapped_mutant_path_is_an_error()
    test_outside_files_are_counted_once()
    test_missing_source_is_an_error()
    test_info_packages()
    print("test_analyze: PASS")
