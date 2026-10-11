from std.testing import assert_equal, assert_true

from covcheck.analyze import FORMAT_LCOV, Analysis, Input, Options, Sources, analyze
from covcheck.annotate import annotations, touched_packages
from covcheck.diff import parse_diff
from covcheck.paths import RepoFiles, repo_files_of
from covcheck.ratchet import Ratchet, parse_ratchet
from covcheck.result import package_json

# The full-source denominator: a source file of a measured package that no
# report names counts, every executable line of it uncovered, and raises
# UnmeasuredFile; a file with no executable line raises nothing.

comptime Z_SOURCE = (
    "\"\"\"A module no test imports.\"\"\"\n"     # 1 docstring
    "from std.os import abort\n"                 # 2 import
    "\n"                                         # 3 blank
    "def h(x: Int) -> Int:\n"                    # 4 code
    "    # the common case first\n"              # 5 comment
    "    if x < 0:\n"                            # 6 code
    "        abort()\n"                          # 7 code
    "    return x + 1\n"                         # 8 code
)

comptime INIT_SOURCE = (
    "\"\"\"Package p: re-exports.\n"
    "\n"
    "Nothing here runs.\n"
    "\"\"\"\n"
    "\n"
    "from .a import f\n"
    "from .z import (\n"
    "    h,\n"
    ")\n"
)


def _repo() -> RepoFiles:
    var l = List[String]()
    l.append("src/p/BUCK")
    l.append("src/p/__init__.mojo")
    l.append("src/p/a.mojo")
    l.append("src/p/z.mojo")
    l.append("src/p/README.md")
    l.append("src/p/tests/test_a.mojo")
    l.append("src/q/BUCK")
    l.append("src/q/q.mojo")
    return repo_files_of(l)


def _sources() -> Sources:
    var s = Sources(String(""))
    s.texts[String("src/p/__init__.mojo")] = String(INIT_SOURCE)
    s.texts[String("src/p/a.mojo")] = String("def f() -> Int:\n    return 1\n")
    s.texts[String("src/p/z.mojo")] = String(Z_SOURCE)
    s.texts[String("src/p/tests/test_a.mojo")] = String("def main():\n    pass\n")
    s.texts[String("src/q/q.mojo")] = String("x\n")
    return s^


def _report() -> List[Input]:
    # a.mojo fully covered; z.mojo and __init__.mojo absent from the report.
    var l = List[Input]()
    l.append(Input(String(FORMAT_LCOV), String(""), String("t.info"), String("SF:src/p/a.mojo\nDA:1,1\nDA:2,3\nend_of_record\n")))
    return l^


def _report_with_branches() -> List[Input]:
    # a.mojo fully covered, lines and the two branches of line 2.
    var l = List[Input]()
    l.append(Input(String(FORMAT_LCOV), String(""), String("t.info"), String(
        "SF:src/p/a.mojo\nDA:1,1\nDA:2,3\nBRDA:2,0,0,1\nBRDA:2,0,1,2\nend_of_record\n"
    )))
    return l^


def _kinds(a: Analysis) -> String:
    var s = String("")
    for i in range(len(a.findings)):
        if i > 0:
            s += String(" ")
        s += a.findings[i].kind
        if a.findings[i].path.byte_length() > 0:
            s += String("@") + a.findings[i].path
    return s^


def _enforce() -> Options:
    var o = Options()
    o.mode = String("enforce")
    return o^


def test_absent_file_fails_the_target() raises:
    # Without the full-source denominator p reads 100% (2/2) and passes.
    var rat = parse_ratchet(String("src/p\t10000\t-\n"), String("r.tsv"))
    var a = analyze(_report(), List[Input](), _repo(), rat, _sources(), _enforce())
    var k = a.package_index(String("src/p"))
    assert_true(k >= 0)
    # a.mojo 2 found 2 hit; z.mojo lines 4, 6, 7, 8 found, none hit.
    assert_equal(a.packages[k].line_found, 6, _kinds(a))
    assert_equal(a.packages[k].line_hit, 2)
    assert_equal(_kinds(a), "BelowTarget BranchNotMeasured Regression UnmeasuredFile@src/p/z.mojo")
    assert_equal(a.conclusion, "failure")
    # src/q has no record: it is not measured, so q.mojo is not read in.
    assert_equal(a.package_index(String("src/q")), -1)


def test_init_of_reexports_raises_nothing() raises:
    # A package of a.mojo (covered, its branches too) and an __init__.mojo
    # of a docstring and imports: 100%, no finding, the __init__ not counted
    # as a file.
    var l = List[String]()
    l.append("src/p/BUCK")
    l.append("src/p/__init__.mojo")
    l.append("src/p/a.mojo")
    var rat = parse_ratchet(String("src/p\t10000\t10000\n"), String("r.tsv"))
    var a = analyze(_report_with_branches(), List[Input](), repo_files_of(l), rat, _sources(), _enforce())
    assert_equal(_kinds(a), "")
    assert_equal(a.conclusion, "success")
    assert_equal(a.packages[0].files, 1)
    assert_equal(a.packages[0].unmeasured_files, 0)
    assert_equal(a.packages[0].line_found, 2)


def test_markers_apply_to_a_file_no_test_compiled() raises:
    # z.mojo's line 7 exempt (reason given) leaves the count; line 8's
    # marker has no reason, so it stays counted and is a finding.
    var s = _sources()
    s.texts[String("src/p/z.mojo")] = String(Z_SOURCE).replace(
        "        abort()\n", "        abort()  # cov: unreachable callers pass x >= 0\n"
    ).replace("    return x + 1\n", "    return x + 1  # cov: unreachable\n")
    var a = analyze(_report(), List[Input](), _repo(), parse_ratchet(String("src/p\t10000\t-\n"), String("r.tsv")), s, _enforce())
    var k = a.package_index(String("src/p"))
    assert_equal(a.packages[k].line_found, 5)
    assert_equal(a.packages[k].exempt_lines, 1)
    assert_equal(len(a.exemptions), 2)
    assert_equal(a.exemptions[0].line, 7)
    assert_equal(a.exemptions[0].status, "exempt")
    assert_equal(a.exemptions[1].status, "no reason")
    assert_equal(_kinds(a), "BelowTarget BranchNotMeasured Regression UnmeasuredFile@src/p/z.mojo ExemptionWithoutReason@src/p/z.mojo")
    for i in range(len(a.findings)):
        if a.findings[i].kind == String("UnmeasuredFile"):
            assert_equal(a.findings[i].count, 3)
            assert_equal(a.findings[i].line, 0)
            assert_true(a.findings[i].message.find("its 3 executable lines") >= 0, a.findings[i].message)


def test_test_sources_and_helpers() raises:
    # tests/ directly in the package is left out unless --include-tests; a
    # test helper anywhere else in the package is source.
    var l = List[String]()
    l.append("src/p/BUCK")
    l.append("src/p/a.mojo")
    l.append("src/p/testing_helpers.mojo")
    l.append("src/p/tests/test_a.mojo")
    var s = _sources()
    s.texts[String("src/p/testing_helpers.mojo")] = String("def fake() -> Int:\n    return 0\n")
    var a = analyze(_report(), List[Input](), repo_files_of(l), Ratchet(), s, Options())
    assert_equal(_kinds(a), "BelowTarget BranchNotMeasured MissingRow UnmeasuredFile@src/p/testing_helpers.mojo")
    var o = Options()
    o.include_tests = True
    var b = analyze(_report(), List[Input](), repo_files_of(l), Ratchet(), s, o)
    assert_equal(_kinds(b), "BelowTarget BranchNotMeasured MissingRow UnmeasuredFile@src/p/testing_helpers.mojo UnmeasuredFile@src/p/tests/test_a.mojo")
    assert_equal(b.packages[0].line_found, 6)


def test_gate_equals_report_with_unmeasured_files() raises:
    var rat = parse_ratchet(String("src/p\t9000\t-\n"), String("r.tsv"))
    var full = analyze(_report(), List[Input](), _repo(), rat, _sources(), Options())
    var o = Options()
    o.only_package = String("src/p")
    var gate = analyze(_report(), List[Input](), _repo(), rat, _sources(), o)
    assert_equal(package_json(gate.packages[0]), package_json(full.packages[full.package_index(String("src/p"))]))
    assert_equal(_kinds(gate), _kinds(full))
    assert_true(package_json(gate.packages[0]).find("\"unmeasured_files\":1") >= 0, package_json(gate.packages[0]))
    # Neutral mode: the same findings; the line under its floor of 90.00%
    # is a Regression, which fails in every mode.
    assert_true(_kinds(full).find("Regression") >= 0, _kinds(full))
    assert_equal(full.conclusion, "failure")


def test_annotations_of_a_file_no_test_compiled() raises:
    # One range per run of consecutive executable lines: z.mojo's 4, then
    # 6-8 (the comment on 5 breaks the run, where a line with no record in
    # a compiled file would not).
    var a = analyze(_report(), List[Input](), _repo(), parse_ratchet(String("src/p\t10000\t-\n"), String("r.tsv")), _sources(), _enforce())
    var d = parse_diff(String("diff --git a/src/p/a.mojo b/src/p/a.mojo\n--- a/src/p/a.mojo\n+++ b/src/p/a.mojo\n@@ -1 +1 @@\n-x\n+y\n"))
    var anns = annotations(a, d, touched_packages(a, d, _repo()))
    var s = String("")
    for i in range(len(anns)):
        s += anns[i].path + String(":") + String(anns[i].start_line) + String("-") + String(anns[i].end_line)
        s += String(" ") + anns[i].level + String(" ") + anns[i].title + String(" | ") + anns[i].message + String("\n")
    assert_equal(s,
        "src/p/z.mojo:4-4 failure File not compiled into any test | Line 4 is in a file no test binary compiled, so not executed by any test\n"
        "src/p/z.mojo:6-8 failure File not compiled into any test | Lines 6-8 are in a file no test binary compiled, so not executed by any test\n"
    )


def test_a_report_entry_with_no_record_counts_as_unmeasured() raises:
    # The report names z.mojo but gives it no line record (an lcov `SF:`
    # straight to `end_of_record`): z.mojo still counts its executable
    # lines uncovered, as if the report did not name it.
    var l = List[Input]()
    l.append(Input(String(FORMAT_LCOV), String(""), String("t.info"), String(
        "SF:src/p/a.mojo\nDA:1,1\nDA:2,3\nend_of_record\nSF:src/p/z.mojo\nend_of_record\n"
    )))
    var rat = parse_ratchet(String("src/p\t10000\t-\n"), String("r.tsv"))
    var a = analyze(l, List[Input](), _repo(), rat, _sources(), _enforce())
    var k = a.package_index(String("src/p"))
    assert_true(k >= 0)
    assert_equal(a.packages[k].line_found, 6, _kinds(a))
    assert_equal(a.packages[k].line_hit, 2)
    assert_equal(a.packages[k].files, 2)
    assert_equal(a.packages[k].unmeasured_files, 1)
    assert_equal(_kinds(a), "BelowTarget BranchNotMeasured Regression UnmeasuredFile@src/p/z.mojo")
    assert_equal(a.conclusion, "failure")
    # The package's only report entry has no record: it is still measured
    # (NotMeasured), and the lines of z.mojo and a.mojo (now named by no
    # report) count against it: 4 + 2.
    var only = List[Input]()
    only.append(Input(String(FORMAT_LCOV), String(""), String("t.info"), String("SF:src/p/z.mojo\nend_of_record\n")))
    var b = analyze(only, List[Input](), _repo(), rat, _sources(), _enforce())
    var j = b.package_index(String("src/p"))
    assert_equal(b.packages[j].line_found, 6, _kinds(b))
    assert_equal(b.packages[j].line_hit, 0)
    assert_equal(_kinds(b), "BelowTarget NotMeasured Regression UnmeasuredFile@src/p/a.mojo UnmeasuredFile@src/p/z.mojo")


def test_unmeasured_files_counts_only_files_with_a_finding() raises:
    # A file no test compiled whose every executable line is exempted, and
    # one holding only a marker on a comment line: both are listed for their
    # markers, neither is an UnmeasuredFile, so neither is counted in
    # unmeasured_files (which equals the number of UnmeasuredFile findings).
    var s = _sources()
    s.texts[String("src/p/z.mojo")] = String("abort()  # cov: unreachable r\n")
    s.texts[String("src/p/__init__.mojo")] = String("# cov: unreachable r\n")
    var a = analyze(_report(), List[Input](), _repo(), parse_ratchet(String("src/p\t10000\t-\n"), String("r.tsv")), s, _enforce())
    var k = a.package_index(String("src/p"))
    # The report has no branch record: that, and no file finding.
    assert_equal(_kinds(a), "BranchNotMeasured")
    assert_equal(len(a.exemptions), 2)
    assert_equal(a.packages[k].exempt_lines, 1)
    assert_equal(a.packages[k].line_found, 2)
    assert_equal(a.packages[k].unmeasured_files, 0)
    assert_equal(a.packages[k].files, 3)


def test_measured_means_a_report_recorded_a_line() raises:
    # A report recorded a.mojo's one line and a marker exempts it: nothing
    # is left to count, but a report measured the package, so it is not
    # NotMeasured.
    var l = List[String]()
    l.append("src/p/BUCK")
    l.append("src/p/a.mojo")
    var s = _sources()
    s.texts[String("src/p/a.mojo")] = String("abort()  # cov: unreachable r\n")
    var r = List[Input]()
    r.append(Input(String(FORMAT_LCOV), String(""), String("t.info"), String("SF:src/p/a.mojo\nDA:1,0\nend_of_record\n")))
    var a = analyze(r, List[Input](), repo_files_of(l), Ratchet(), s, _enforce())
    assert_equal(a.packages[0].exempt_lines, 1)
    assert_equal(a.packages[0].line_found, 0)
    assert_true((String(" ") + _kinds(a)).find(" NotMeasured") < 0, _kinds(a))
    # The report names only z.mojo, with no record, and z.mojo's line 7 is
    # exempt: an exemption in a file no test compiled does not make the
    # package measured, so NotMeasured stays.
    var z = _sources()
    z.texts[String("src/p/z.mojo")] = String(Z_SOURCE).replace(
        "        abort()\n", "        abort()  # cov: unreachable callers pass x >= 0\n"
    )
    var only = List[Input]()
    only.append(Input(String(FORMAT_LCOV), String(""), String("t.info"), String("SF:src/p/z.mojo\nend_of_record\n")))
    var b = analyze(only, List[Input](), _repo(), Ratchet(), z, _enforce())
    var k = b.package_index(String("src/p"))
    assert_equal(b.packages[k].exempt_lines, 1)
    assert_true((String(" ") + _kinds(b)).find(" NotMeasured") >= 0, _kinds(b))


def main() raises:
    test_absent_file_fails_the_target()
    test_init_of_reexports_raises_nothing()
    test_markers_apply_to_a_file_no_test_compiled()
    test_test_sources_and_helpers()
    test_gate_equals_report_with_unmeasured_files()
    test_annotations_of_a_file_no_test_compiled()
    test_a_report_entry_with_no_record_counts_as_unmeasured()
    test_unmeasured_files_counts_only_files_with_a_finding()
    test_measured_means_a_report_recorded_a_line()
    print("test_full_source: PASS")
