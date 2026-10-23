from std.testing import assert_equal, assert_true

from covcheck.analyze import FORMAT_COBERTURA, Analysis, Input, Options, Sources, analyze
from covcheck.held import Held, add_hold
from covcheck.paths import RepoFiles, repo_files_of

# The reports of a package built with buildrules' mojo_package (its `:coverage[reports]`): one
# kcov Cobertura file per test, every path relative to the repository root, and each report names
# the test's own source under the package's `tests/` next to the library's sources. A path in
# several reports is summed. `covcheck report` must count the library's sources only, leave the
# tests/ sources out, and read the package's `coverage_held` against those numbers.

comptime PKG = "src/mp"
comptime LIB = "src/mp/src/mp/lib.mojo"
comptime INIT = "src/mp/src/mp/__init__.mojo"
comptime TEST_A = "src/mp/tests/test_a.mojo"
comptime TEST_B = "src/mp/tests/test_b.mojo"

# Four executable lines, as the lexer counts them.
comptime LIB_SOURCE = (
    "def f(x: Int) -> Int:\n"   # 1
    "    if x < 0:\n"           # 2
    "        return 0\n"        # 3
    "    return x\n"            # 4
)


def _repo() -> RepoFiles:
    var l = List[String]()
    l.append("src/mp/BUCK")
    l.append("src/mp/coverage_floor.txt")
    l.append("src/mp/coverage_held")
    l.append("src/mp/mopm.toml")
    l.append(INIT)
    l.append(LIB)
    l.append(TEST_A)
    l.append(TEST_B)
    return repo_files_of(l)


def _sources() -> Sources:
    var s = Sources(String(""))
    # A re-export: no executable line, so no class in any report.
    s.texts[String(INIT)] = String("\"\"\"mp.\"\"\"\n\nfrom .lib import f\n")
    s.texts[String(LIB)] = String(LIB_SOURCE)
    s.texts[String(TEST_A)] = String("def main():\n    pass\n")
    s.texts[String(TEST_B)] = String("def main():\n    pass\n")
    return s^


def _class(path: String, hits: List[Int]) -> String:
    """A `<class>` of the shape buildrules writes: lines 1..len(hits), `hits[i]` the hits of line i + 1."""
    var t = String("\t\t\t\t<class name=\"") + path + String("\" filename=\"") + path + String("\">\n\t\t\t\t\t<lines>\n")
    for i in range(len(hits)):
        t += String("\t\t\t\t\t\t<line number=\"") + String(i + 1) + String("\" hits=\"") + String(hits[i]) + String("\"/>\n")
    t += String("\t\t\t\t\t</lines>\n\t\t\t\t</class>\n")
    return t^


def _report(origin: String, lib_hits: List[Int], test_path: String) -> Input:
    """One test's report: the library file with `lib_hits`, then the test's own source (all lines run)."""
    var tests = List[Int]()
    tests.append(1)
    tests.append(1)
    var t = String("<?xml version=\"1.0\" ?>\n<coverage timestamp=\"0\">\n\t<sources>\n\t\t<source>.</source>\n\t</sources>\n")
    t += String("\t<packages>\n\t\t<package name=\"\">\n\t\t\t<classes>\n")
    t += _class(String(LIB), lib_hits) + _class(test_path, tests)
    t += String("\t\t\t</classes>\n\t\t</package>\n\t</packages>\n</coverage>\n")
    return Input(String(FORMAT_COBERTURA), String(""), origin, t)


def _hits(a: Int, b: Int, c: Int, d: Int) -> List[Int]:
    var l = List[Int]()
    l.append(a)
    l.append(b)
    l.append(c)
    l.append(d)
    return l^


def _held_line() raises -> Held:
    var h = Held()
    add_hold(h, String(PKG), String("line\n"), String("src/mp/coverage_held"), List[String]())
    return h^


def _kinds(a: Analysis) -> String:
    var s = String("")
    for i in range(len(a.findings)):
        if i > 0:
            s += String(" ")
        s += a.findings[i].kind
        if a.findings[i].path.byte_length() > 0:
            s += String("@") + a.findings[i].path
    return s^


def _two_tests(lib_a: List[Int], lib_b: List[Int]) -> List[Input]:
    var l = List[Input]()
    l.append(_report(String("buck-out/v2/art/komira/x/src/mp/__test_a__cov__/test_a__cov.cobertura.xml"), lib_a, String(TEST_A)))
    l.append(_report(String("buck-out/v2/art/komira/x/src/mp/__test_b__cov__/test_b__cov.cobertura.xml"), lib_b, String(TEST_B)))
    return l^


def test_per_test_reports_are_summed_and_count_library_sources_only() raises:
    # Each test runs two of the four lines, the two between them all four: 4/4. The two tests'
    # own sources (2 lines each, all run) are in the reports and in no number.
    var a = analyze(_two_tests(_hits(1, 1, 0, 1), _hits(1, 0, 1, 0)), List[Input](), _repo(), _held_line(), _sources(), Options())
    var k = a.package_index(String(PKG))
    assert_true(k >= 0)
    assert_equal(a.packages[k].line_found, 4)
    assert_equal(a.packages[k].line_hit, 4)
    assert_equal(a.packages[k].files, 1)
    assert_equal(a.packages[k].unmeasured_files, 0)
    # The held line is met, and nothing is said of the re-export or of a test source.
    assert_equal(_kinds(a), "BranchNotMeasured")


def test_a_line_no_test_runs_is_below_the_hold_and_the_tests_do_not_lift_it() raises:
    # Line 3 runs in neither test: 3/4 of the library, 75%. With the tests' own lines counted
    # it would read 7/8 (87.5%) or better, so the hold failing shows they are left out.
    var o = Options()
    o.mode = String("enforce")
    var a = analyze(_two_tests(_hits(1, 1, 0, 1), _hits(1, 1, 0, 0)), List[Input](), _repo(), _held_line(), _sources(), o)
    var k = a.package_index(String(PKG))
    assert_true(k >= 0)
    assert_equal(a.packages[k].line_found, 4)
    assert_equal(a.packages[k].line_hit, 3)
    assert_equal(a.packages[k].line_bp(), 7500)
    assert_equal(_kinds(a), "BranchNotMeasured Regression")
    assert_equal(a.conclusion, "failure")


def test_the_tests_sources_are_counted_only_when_asked() raises:
    # The same reports with --include-tests: the two test files join the package (4 + 2 + 2 lines).
    var o = Options()
    o.include_tests = True
    var a = analyze(_two_tests(_hits(1, 1, 0, 1), _hits(1, 0, 1, 0)), List[Input](), _repo(), Held(), _sources(), o)
    var k = a.package_index(String(PKG))
    assert_true(k >= 0)
    assert_equal(a.packages[k].line_found, 8)
    assert_equal(a.packages[k].files, 3)


def main() raises:
    test_per_test_reports_are_summed_and_count_library_sources_only()
    test_a_line_no_test_runs_is_below_the_hold_and_the_tests_do_not_lift_it()
    test_the_tests_sources_are_counted_only_when_asked()
    print("test_package_reports: PASS")
