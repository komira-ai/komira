from std.testing import assert_equal, assert_true

from komira_json import JsonValue, parse_json_value

from covcheck.analysis import ExcludedFile
from covcheck.analyze import FORMAT_LCOV, Analysis, Input, Options, Sources, analyze
from covcheck.annotate import (
    DEFAULT_MAX_ANNOTATIONS,
    Annotation,
    DiffCoverage,
    PathRange,
    annotations,
    annotations_json,
    cap_annotations,
    cap_note,
    diff_coverage,
    line_message,
    merge_consecutive,
    touched_packages,
    uncovered_ranges,
)
from covcheck.checkrun import body_name, checkrun_bodies, valid_sha
from covcheck.diff import parse_diff
from covcheck.result import gate_json
from covcheck.jsonw import JsonOut
from covcheck.model import FileCov
from covcheck.paths import RepoFiles, repo_files_of
from covcheck.held import Held
from covcheck.summary import MAX_SUMMARY, md_code, render_summary, truncate_summary

# What the PR check adds: check-run batching, annotations (scope, order,
# ranges, kinds, levels), changed-line coverage, the summary's size limit,
# and JSON escaping.

comptime SHA = "0123456789abcdef0123456789abcdef01234567"


def _anns(n: Int) -> List[Annotation]:
    var out = List[Annotation]()
    for i in range(n):
        out.append(Annotation(String("src/a/x.mojo"), i + 1, i + 1, String("warning"), String("Line not covered"), line_message(i + 1, i + 1)))
    return out^


def _batches(n: Int, conclusion: String) raises -> String:
    """`<annotations per body>` for each body, after checking the bodies'
    fixed fields."""
    var bodies = checkrun_bodies(String("coverage"), String(SHA), String("t"), String("s"), conclusion, _anns(n))
    var s = String("")
    var seen = 0
    for i in range(len(bodies)):
        var v = parse_json_value(bodies[i])
        var count = v.get(String("output")).get(String("annotations")).array_len()
        if count > 0:
            var first = v.get(String("output")).get(String("annotations")).element_at(0)
            assert_equal(Int(first.get(String("start_line")).as_int64()), seen + 1)
        seen += count
        if i > 0:
            s += String(" ")
        s += String(count)
        assert_equal(v.get(String("output")).get(String("title")).as_string(), "t")
        assert_equal(v.get(String("output")).get(String("summary")).as_string(), "s")
        if i == 0:
            assert_equal(v.get(String("name")).as_string(), "coverage")
            assert_equal(v.get(String("head_sha")).as_string(), String(SHA))
            assert_equal(v.get(String("status")).as_string(), "in_progress")
            assert_true(not v.has(String("conclusion")))
        elif i == len(bodies) - 1:
            assert_equal(v.get(String("status")).as_string(), "completed")
            assert_equal(v.get(String("conclusion")).as_string(), conclusion)
            assert_true(not v.has(String("head_sha")))
        else:
            assert_true(not v.has(String("status")))
    assert_equal(seen, n)
    return s^


def test_checkrun_batching() raises:
    assert_equal(_batches(0, String("neutral")), "0 0")
    assert_equal(_batches(1, String("neutral")), "1 0")
    assert_equal(_batches(50, String("success")), "50 0")
    assert_equal(_batches(51, String("failure")), "50 1")
    assert_equal(_batches(100, String("neutral")), "50 50")
    assert_equal(_batches(120, String("failure")), "50 50 20")


def test_annotation_cap() raises:
    # Cap 3 of 5: the first 3 in their order, and the note; the full list
    # (annotations_json) keeps all 5.
    var five = _anns(5)
    var capped = cap_annotations(five, 3)
    assert_equal(len(capped), 3)
    for i in range(3):
        assert_equal(capped[i].start_line, i + 1)
    assert_equal(cap_note(5, 3, True), "2 annotations omitted (cap 3); the full list is in the annotations file")
    assert_equal(cap_note(5, 3, False), "2 annotations omitted (cap 3); the full list was not written (give --annotations-out)")
    var bodies = checkrun_bodies(String("coverage"), String(SHA), String("t"), String("s"), String("neutral"), capped)
    var sent = 0
    for i in range(len(bodies)):
        sent += parse_json_value(bodies[i]).get(String("output")).get(String("annotations")).array_len()
    assert_equal(sent, 3)
    var full = parse_json_value(annotations_json(five))
    assert_equal(full.array_len(), 5)
    assert_equal(Int(full.element_at(4).get(String("start_line")).as_int64()), 5)
    # A cap equal to the count (or above it) omits nothing and says nothing.
    assert_equal(len(cap_annotations(five, 5)), 5)
    assert_equal(cap_note(5, 5, False), "")
    assert_equal(cap_note(5, 6, False), "")
    # The default, and the requests it bounds a run to: 1 POST and 19 PATCHes.
    assert_equal(DEFAULT_MAX_ANNOTATIONS, 1000)
    assert_equal(_batches(1000, String("failure")), "50 50 50 50 50 50 50 50 50 50 50 50 50 50 50 50 50 50 50 50")


def test_body_names_sort_in_send_order() raises:
    assert_equal(body_name(0), "000.json")
    assert_equal(body_name(7), "007.json")
    assert_equal(body_name(123), "123.json")


def test_head_sha_validation() raises:
    assert_true(valid_sha(String(SHA)))
    assert_true(not valid_sha(String("0123456789ABCDEF0123456789abcdef01234567")))
    assert_true(not valid_sha(String("0123456789abcdef")))
    assert_true(not valid_sha(String("g123456789abcdef0123456789abcdef01234567")))


def test_json_escaping_of_a_path_with_a_quote() raises:
    var a = List[Annotation]()
    a.append(Annotation(String("src/a/q\"x\\y.mojo"), 1, 1, String("warning"), String("Line not covered"), String("m\nn")))
    var bodies = checkrun_bodies(String("cov\"erage"), String(SHA), String("t"), String("s"), String("neutral"), a)
    assert_true(bodies[0].find("src/a/q\\\"x\\\\y.mojo") >= 0, bodies[0])
    var v = parse_json_value(bodies[0])
    var ann = v.get(String("output")).get(String("annotations")).element_at(0)
    assert_equal(ann.get(String("path")).as_string(), "src/a/q\"x\\y.mojo")
    assert_equal(ann.get(String("message")).as_string(), "m\nn")
    assert_equal(v.get(String("name")).as_string(), "cov\"erage")


def test_merge_consecutive() raises:
    var l = List[Int]()
    l.append(3)
    l.append(4)
    l.append(5)
    l.append(7)
    l.append(9)
    l.append(10)
    var r = merge_consecutive(l)
    assert_equal(len(r), 3)
    assert_equal(r[0].start, 3)
    assert_equal(r[0].end, 5)
    assert_equal(r[1].start, 7)
    assert_equal(r[1].end, 7)
    assert_equal(r[2].end, 10)


def test_uncovered_ranges_break_only_on_covered_or_exempt_lines() raises:
    var f = FileCov(String("x"))
    f.add_line(2, 0)
    f.add_line(4, 0)   # 3 has no record: 2-4 is one run
    f.add_line(5, 1)   # covered: breaks
    f.add_line(6, 0)
    f.add_line(9, 0)   # 8 is exempt: breaks
    var ex = List[Int]()
    ex.append(8)
    var r = uncovered_ranges(f, ex)
    assert_equal(len(r), 3)
    assert_equal(r[0].start, 2)
    assert_equal(r[0].end, 4)
    assert_equal(r[1].start, 6)
    assert_equal(r[1].end, 6)
    assert_equal(r[2].start, 9)
    assert_equal(line_message(2, 4), "Lines 2-4 are not executed by any test")
    assert_equal(line_message(6, 6), "Line 6 is not executed by any test")


def _repo() -> RepoFiles:
    var l = List[String]()
    l.append("BUCK")
    l.append("README.md")
    l.append("src/a/BUCK")
    l.append("src/a/x.mojo")
    l.append("src/a/y.mojo")
    l.append("src/a/z.mojo")
    l.append("src/a/README.md")
    l.append("src/b/BUCK")
    l.append("src/b/w.mojo")
    return repo_files_of(l)


def _analysis(mode: String) raises -> Analysis:
    var s = Sources(String(""))
    s.texts[String("src/a/x.mojo")] = String("1\n2\n3\n4\n5\n6\n")
    s.texts[String("src/a/y.mojo")] = String("1\n2\n3  # cov: unreachable never\n")
    s.texts[String("src/b/w.mojo")] = String("1\n")
    # In no report: counted from its source, both lines executable.
    s.texts[String("src/a/z.mojo")] = String("1\n2\n")
    var r = List[Input]()
    r.append(Input(String(FORMAT_LCOV), String(""), String("t.info"), String(
        "SF:src/a/x.mojo\nDA:1,1\nDA:2,0\nDA:3,0\nDA:4,1\nDA:6,0\nBRDA:4,0,0,1\nBRDA:4,0,1,0\nBRDA:4,0,2,-\nend_of_record\n"
        "SF:src/a/y.mojo\nDA:1,0\nDA:3,0\nend_of_record\n"
        "SF:src/b/w.mojo\nDA:1,0\nend_of_record\n"
    )))
    var m = List[Input]()
    m.append(Input(String("mutants"), String(""), String("m.tsv"), String(
        "src/a/x.mojo\t4\tsurvived\tnegate\ta > b\nsrc/a/z.mojo\t2\tsurvived\tdelete\t\nsrc/a/x.mojo\t1\tkilled\tnegate\td\n"
    )))
    var o = Options()
    o.mode = mode
    return analyze(r, m, _repo(), Held(), s, o)


comptime DIFF_Y = "diff --git a/src/a/y.mojo b/src/a/y.mojo\n--- a/src/a/y.mojo\n+++ b/src/a/y.mojo\n@@ -0,0 +1,3 @@\n+1\n+2\n+3\n"
comptime DIFF_X = "diff --git a/src/a/x.mojo b/src/a/x.mojo\n--- a/src/a/x.mojo\n+++ b/src/a/x.mojo\n@@ -1,0 +2,2 @@\n+2\n+3\n@@ -5,0 +6 @@\n+6\n"
comptime DIFF_DOC = "diff --git a/src/a/README.md b/src/a/README.md\n--- a/src/a/README.md\n+++ b/src/a/README.md\n@@ -1 +1 @@\n-a\n+b\n"
comptime DIFF_NEW = "diff --git a/src/a/z.mojo b/src/a/z.mojo\nnew file mode 100644\n--- /dev/null\n+++ b/src/a/z.mojo\n@@ -0,0 +1,2 @@\n+1\n+2\n"


def _describe(a: List[Annotation]) -> String:
    var s = String("")
    for i in range(len(a)):
        s += a[i].path + String(":") + String(a[i].start_line) + String("-") + String(a[i].end_line)
        s += String(" ") + a[i].level + String(" ") + a[i].title + String(" | ") + a[i].message + String("\n")
    return s^


def test_annotations_cover_every_file_of_touched_packages_changed_first() raises:
    var a = _analysis(String("neutral"))
    var d = parse_diff(String(DIFF_Y))
    var touched = touched_packages(a, d, _repo())
    assert_equal(len(touched), 1)
    assert_equal(touched[0], "src/a")
    # y.mojo (changed) first; then x.mojo and z.mojo (in no report: one run
    # of executable lines, and a mutant); never src/b, which the change does
    # not touch.
    assert_equal(_describe(annotations(a, d, touched)),
        "src/a/y.mojo:1-1 warning Line not covered | Line 1 is not executed by any test\n"
        "src/a/y.mojo:3-3 notice Coverage exemption | Exempt from coverage (exempt): never. Every exemption needs a reviewer's approval.\n"
        "src/a/x.mojo:2-3 warning Line not covered | Lines 2-3 are not executed by any test\n"
        "src/a/x.mojo:4-4 warning Branch not covered | 1 of 3 branches taken on this line\n"
        "src/a/x.mojo:4-4 warning Mutant survived | negate: a > b; no test failed\n"
        "src/a/x.mojo:6-6 warning Line not covered | Line 6 is not executed by any test\n"
        "src/a/z.mojo:1-2 warning File not compiled into any test | Lines 1-2 are in a file no test binary compiled, so not executed by any test\n"
        "src/a/z.mojo:2-2 warning Mutant survived | delete; no test failed\n"
    )


def test_cap_keeps_the_changed_files_first() raises:
    # The changed y.mojo sorts after x.mojo by path, yet the cap keeps its
    # annotations: it takes the first ones of the list in its order (changed
    # files first), never the first ones by path.
    var a = _analysis(String("neutral"))
    var d = parse_diff(String(DIFF_Y))
    var capped = cap_annotations(annotations(a, d, touched_packages(a, d, _repo())), 2)
    assert_equal(_describe(capped),
        "src/a/y.mojo:1-1 warning Line not covered | Line 1 is not executed by any test\n"
        "src/a/y.mojo:3-3 notice Coverage exemption | Exempt from coverage (exempt): never. Every exemption needs a reviewer's approval.\n"
    )


def test_annotation_level_is_failure_in_enforce_mode() raises:
    var a = _analysis(String("enforce"))
    var d = parse_diff(String(DIFF_Y))
    var anns = annotations(a, d, touched_packages(a, d, _repo()))
    assert_equal(anns[0].level, "failure")
    assert_equal(anns[1].level, "notice")


def test_untouched_change_annotates_nothing() raises:
    var a = _analysis(String("neutral"))
    var d = parse_diff(String("diff --git a/README.md b/README.md\n--- a/README.md\n+++ b/README.md\n@@ -1 +1 @@\n-a\n+b\n"))
    var touched = touched_packages(a, d, _repo())
    assert_equal(len(touched), 0)
    assert_equal(len(annotations(a, d, touched)), 0)


def test_binary_change_touches_its_package() raises:
    # A binary file added to src/b (no `---`/`+++` lines) touches src/b.
    var a = _analysis(String("neutral"))
    var d = parse_diff(String(
        "diff --git a/src/b/blob.bin b/src/b/blob.bin\nnew file mode 100644\nindex 0000000..1111111\n"
        "Binary files /dev/null and b/src/b/blob.bin differ\n"
    ))
    var touched = touched_packages(a, d, _repo())
    assert_equal(len(touched), 1)
    assert_equal(touched[0], "src/b")
    assert_equal(_describe(annotations(a, d, touched)), "src/b/w.mojo:1-1 warning Line not covered | Line 1 is not executed by any test\n")


def test_diff_coverage_counts() raises:
    var a = _analysis(String("neutral"))
    var d = parse_diff(String(DIFF_X) + String(DIFF_Y) + String(DIFF_DOC) + String(DIFF_NEW))
    var dc = diff_coverage(a, d, _repo(), False)
    # x.mojo 2,3 uncovered, 6 uncovered; y.mojo 1 uncovered, 2 no record, 3
    # exempt; z.mojo (in no report, so its executable lines 1,2 count with 0
    # hits) uncovered; the README is not a source.
    assert_equal(dc.covered, 0)
    assert_equal(dc.uncovered, 6)
    assert_equal(dc.not_instrumented, 1)
    assert_equal(dc.exempt, 1)
    assert_equal(len(dc.ranges), 4)
    assert_equal(dc.ranges[3].path, "src/a/z.mojo")
    assert_equal(dc.ranges[3].start, 1)
    assert_equal(dc.ranges[3].end, 2)
    assert_equal(dc.ranges[0].path, "src/a/x.mojo")
    assert_equal(dc.ranges[0].start, 2)
    assert_equal(dc.ranges[0].end, 3)
    assert_equal(dc.ranges[1].start, 6)
    assert_equal(dc.ranges[2].path, "src/a/y.mojo")


def test_diff_coverage_covered_line() raises:
    var a = _analysis(String("neutral"))
    var d = parse_diff(String("diff --git a/src/a/x.mojo b/src/a/x.mojo\n--- a/src/a/x.mojo\n+++ b/src/a/x.mojo\n@@ -0,0 +1 @@\n+1\n"))
    var dc = diff_coverage(a, d, _repo(), False)
    assert_equal(dc.covered, 1)
    assert_equal(dc.uncovered, 0)


def test_changes_that_are_no_source_of_a_measured_package_count_for_nothing() raises:
    var a = _analysis(String("neutral"))
    # A file with no extension, a change in a test source of the package
    # (left out unless tests are included), and a path in no package at all.
    var l = List[String]()
    l.append("src/a/BUCK")
    l.append("src/a/x.mojo")
    l.append("loose/q.mojo")
    var repo = repo_files_of(l)
    var d = parse_diff(String(
        "diff --git a/src/a/LICENSE b/src/a/LICENSE\n--- a/src/a/LICENSE\n+++ b/src/a/LICENSE\n@@ -0,0 +1 @@\n+x\n"
        "diff --git a/src/a/tests/test_x.mojo b/src/a/tests/test_x.mojo\n--- a/src/a/tests/test_x.mojo\n+++ b/src/a/tests/test_x.mojo\n@@ -0,0 +1 @@\n+x\n"
        "diff --git a/loose/q.mojo b/loose/q.mojo\n--- a/loose/q.mojo\n+++ b/loose/q.mojo\n@@ -0,0 +1 @@\n+x\n"
    ))
    var dc = diff_coverage(a, d, repo, False)
    assert_equal(dc.covered + dc.uncovered + dc.not_instrumented + dc.exempt, 0)
    var with_tests = diff_coverage(a, d, repo, True)
    assert_equal(with_tests.covered + with_tests.uncovered + with_tests.not_instrumented + with_tests.exempt, 1)


def test_the_gate_result_of_a_package_nothing_measured_is_all_zero() raises:
    var v = parse_json_value(gate_json(Analysis(), String("src/none")))
    assert_equal(v.get(String("package")).get(String("package")).as_string(), "src/none")
    assert_equal(Int(v.get(String("package")).get(String("line_found")).as_int64()), 0)


def test_summary_truncation() raises:
    var line = String("")
    for _ in range(99):
        line += String("x")
    line += String("\n")
    var big = String("")
    for _ in range(700):
        big += line
    assert_equal(big.byte_length(), 70000)
    var t = truncate_summary(big)
    assert_true(t.byte_length() <= MAX_SUMMARY)
    # Cut at a line end: 653 whole lines kept (65300 bytes <= 65335).
    assert_true(t.startswith(String(big[byte=0:65300]) + String("\n**Summary truncated**: 4700 bytes left out")), String(t[byte=65290:]))
    assert_true(t.endswith("bytes left out; the full summary is the --summary-out file; the result JSON holds every number.\n"))
    assert_equal(truncate_summary(big), t)
    assert_equal(truncate_summary(String("short\n")), "short\n")
    # A limit below the marker's room: the text is cut to nothing, never
    # indexed before its start.
    var small = truncate_summary(String(big[byte=0:300]), 150)
    assert_true(small.startswith("\n**Summary truncated**: 300 bytes left out"), small)


def test_summary_limit_is_exactly_65535() raises:
    # GitHub's limit is 65535: a summary of 65535 bytes is sent whole, one of
    # 65536 is cut (the literal, not MAX_SUMMARY, so a wrong constant fails).
    var fits = String("")
    for _ in range(65535):
        fits += String("y")
    assert_equal(truncate_summary(fits), fits)
    var over = fits + String("y")
    var t = truncate_summary(over)
    assert_true(t.byte_length() <= 65535)
    assert_true(t.find("**Summary truncated**") >= 0)


def test_md_code_spans() raises:
    assert_equal(md_code(String("a|b")), "`a\\|b`")
    # A backtick inside needs a double-backtick span.
    assert_equal(md_code(String("a`b|c")), "`` a`b\\|c ``")


def test_summary_of_a_run_that_measured_nothing() raises:
    var s = render_summary(Analysis(), List[String](), DiffCoverage(), False, String(""))
    assert_true(s.startswith("## Coverage: line n/a, branch not measured\n\n"), s)
    assert_true(s.find("### Packages\n\nNo package was measured.\n\n") >= 0, s)
    assert_true(s.find("### Findings (0)\n\nNone.\n\n") >= 0, s)


def test_summary_names_every_test_only_package() raises:
    var a = Analysis()
    a.info_dirs.append(String("src/a/tests"))
    a.info_dirs.append(String("src/b/tests"))
    var s = render_summary(a, List[String](), DiffCoverage(), False, String(""))
    assert_true(s.find("except a test-only package (`src/a/tests`, `src/b/tests` and under): measured and shown") >= 0, s)


def test_summary_writes_uncovered_changed_lines_as_ranges() raises:
    var d = DiffCoverage()
    d.uncovered = 3
    d.ranges.append(PathRange(String("src/a/x.mojo"), 2, 3))
    d.ranges.append(PathRange(String("src/a/x.mojo"), 6, 6))
    d.ranges.append(PathRange(String("src/a/y.mojo"), 1, 1))
    var s = render_summary(Analysis(), List[String](), d, True, String(""))
    assert_true(s.find("Uncovered changed lines:\n\n- `src/a/x.mojo`: 2-3, 6\n- `src/a/y.mojo`: 1\n\n") >= 0, s)


def test_summary_counts_the_ranges_it_leaves_out() raises:
    var d = DiffCoverage()
    for i in range(201):
        d.ranges.append(PathRange(String("src/a/x.mojo"), 2 * i + 1, 2 * i + 1))
    var s = render_summary(Analysis(), List[String](), d, True, String(""))
    assert_true(s.find(", 399\n- and 1 more ranges, omitted here (the --annotations-out file lists every one)\n\n") >= 0, s)
    assert_true(s.find("401") < 0, s)


def test_summary_names_at_most_ten_uncompiled_files() raises:
    var a = Analysis()
    for i in range(11):
        var x = ExcludedFile(String("src/a"), String("src/a/f") + String(i) + String(".mojo"))
        x.lines = 1
        x.arms = 2
        a.excluded.append(x^)
    var s = render_summary(a, List[String](), DiffCoverage(), False, String(""))
    assert_true(s.find("- 11 lines and 22 branch arms of the code no test compiled") >= 0, s)
    assert_true(s.find("`src/a/f0.mojo` (1 lines, 2 arms), `src/a/f1.mojo` (1 lines, 2 arms)") >= 0, s)
    assert_true(s.find("`src/a/f9.mojo` (1 lines, 2 arms), and 1 more files (the result JSON names every one)\n") >= 0, s)
    assert_true(s.find("f10.mojo") < 0, s)


def test_summary_truncation_without_a_line_end_keeps_utf8_whole() raises:
    # No line end in reach: the cut falls on byte 200, inside the 2-byte
    # sequence that starts at 199, so the cut moves back to 199.
    var text = String("a")
    for _ in range(300):
        text += String("é")
    assert_equal(text.byte_length(), 601)
    var t = truncate_summary(text, 400)
    var kept = String("a")
    for _ in range(99):
        kept += String("é")
    assert_equal(kept.byte_length(), 199)
    assert_true(t.startswith(kept + String("\n**Summary truncated**: 402 bytes left out")), t)


def test_json_writer_places_commas_between_members_only() raises:
    var j = JsonOut()
    j.begin_array()
    j.item()
    j.int_value(1)
    j.item()
    j.str_value(String("a\"b"))
    j.end_array()
    assert_equal(j.text(), "[1,\"a\\\"b\"]")
    # An element named outside any container is just the value.
    var top = JsonOut()
    top.item()
    top.int_value(7)
    assert_equal(top.text(), "7")


def main() raises:
    test_checkrun_batching()
    test_annotation_cap()
    test_body_names_sort_in_send_order()
    test_head_sha_validation()
    test_json_escaping_of_a_path_with_a_quote()
    test_merge_consecutive()
    test_uncovered_ranges_break_only_on_covered_or_exempt_lines()
    test_annotations_cover_every_file_of_touched_packages_changed_first()
    test_cap_keeps_the_changed_files_first()
    test_annotation_level_is_failure_in_enforce_mode()
    test_untouched_change_annotates_nothing()
    test_binary_change_touches_its_package()
    test_diff_coverage_counts()
    test_diff_coverage_covered_line()
    test_changes_that_are_no_source_of_a_measured_package_count_for_nothing()
    test_the_gate_result_of_a_package_nothing_measured_is_all_zero()
    test_summary_truncation()
    test_summary_limit_is_exactly_65535()
    test_md_code_spans()
    test_summary_of_a_run_that_measured_nothing()
    test_summary_names_every_test_only_package()
    test_summary_writes_uncovered_changed_lines_as_ranges()
    test_summary_counts_the_ranges_it_leaves_out()
    test_summary_names_at_most_ten_uncompiled_files()
    test_summary_truncation_without_a_line_end_keeps_utf8_whole()
    test_json_writer_places_commas_between_members_only()
    print("test_report: PASS")
