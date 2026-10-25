from std.testing import assert_equal, assert_true

from covcheck.analyze import FORMAT_BRANCH_LCOV, FORMAT_COBERTURA, Analysis, Input, Options, Sources, analyze
from covcheck.held import Held
from covcheck.paths import RepoFiles, repo_files_of
from covcheck.uncompiled import is_uncompiled_report

# buildrules' report of the code no test compiled (`uncompiled.cobertura.xml`, `uncompiled.branches.info`):
# the executable lines of every function none of whose lines has a record, as found and not hit, and the
# arms of their decision words, as not taken. A function the compiler inlined into its callers, and one whose
# code is in a `comptime if` arm dropped here, look the same, so those two classes (decls.mojo) are left out of
# the numbers; a plain function is counted.

comptime PKG = "src/mp"
comptime LIB = "src/mp/src/mp/lib.mojo"

comptime LIB_SOURCE = (
    "def compiled(x: Int) -> Int:\n"     # 1
    "    return x\n"                      # 2
    "\n"                                  # 3
    "def plain(x: Int) -> Int:\n"         # 4  a function no test calls
    "    if x < 0:\n"                     # 5
    "        return 0\n"                  # 6
    "    return x\n"                      # 7
    "\n"                                  # 8
    "@always_inline\n"                    # 9
    "def inlined(x: Int) -> Int:\n"       # 10
    "    return x + 1\n"                  # 11
    "\n"                                  # 12
    "def gated(x: Int) -> Int:\n"         # 13
    "    comptime if True:\n"             # 14
    "        return x and x\n"            # 15
    "    return 0\n"                      # 16
)

comptime TEST_REPORT = "buck-out/v2/art/komira/x/src/mp/__test_a__cov__/test_a__cov.cobertura.xml"
comptime UNCOMPILED_REPORT = "buck-out/v2/art/komira/x/src/mp/__coverage__/uncompiled.cobertura.xml"
comptime UNCOMPILED_BRANCHES = "buck-out/v2/art/komira/x/src/mp/__coverage__/uncompiled.branches.info"


def _repo() -> RepoFiles:
    var l = List[String]()
    l.append("src/mp/BUCK")
    l.append("src/mp/mopm.toml")
    l.append(LIB)
    return repo_files_of(l)


def _sources() -> Sources:
    var s = Sources(String(""))
    s.texts[String(LIB)] = String(LIB_SOURCE)
    return s^


def _report(origin: String, lines: List[Int], hits: Int) -> Input:
    var t = String("<?xml version=\"1.0\" ?>\n<coverage timestamp=\"0\">\n\t<packages>\n\t\t<package name=\"\">\n\t\t\t<classes>\n")
    t += String("\t\t\t\t<class name=\"lib\" filename=\"") + String(LIB) + String("\">\n\t\t\t\t\t<lines>\n")
    for i in range(len(lines)):
        t += String("\t\t\t\t\t\t<line number=\"") + String(lines[i]) + String("\" hits=\"") + String(hits) + String("\"/>\n")
    t += String("\t\t\t\t\t</lines>\n\t\t\t\t</class>\n\t\t\t</classes>\n\t\t</package>\n\t</packages>\n</coverage>\n")
    return Input(String(FORMAT_COBERTURA), String(""), origin, t)


def _ints(a: Int, b: Int, c: Int, d: Int) -> List[Int]:
    var l = List[Int]()
    l.append(a)
    l.append(b)
    l.append(c)
    l.append(d)
    return l^


def _uncompiled_lines() -> List[Int]:
    """Every own line of `plain`, `inlined` and `gated`."""
    var l = _ints(4, 5, 6, 7)
    l.append(10)
    l.append(11)
    l.append(13)
    l.append(14)
    l.append(15)
    l.append(16)
    return l^


def _uncompiled_branches(origin: String) -> Input:
    """The arms of `if` (line 5, in `plain`) and of `and` (line 15, in `gated`), none taken."""
    var t = String("SF:") + String(LIB) + String("\nBRDA:5,8:br:0/1,0,-\nBRDA:5,8:br:0/1,1,-\nBRDA:15,17:br:0/1,0,-\nBRDA:15,17:br:0/1,1,-\nend_of_record\n")
    return Input(String(FORMAT_BRANCH_LCOV), String(""), origin, t)


def _inputs(uncompiled_name: String, branch_name: String) -> List[Input]:
    var l = List[Input]()
    var compiled = List[Int]()
    compiled.append(1)
    compiled.append(2)
    l.append(_report(String(TEST_REPORT), compiled, 1))
    l.append(_report(uncompiled_name, _uncompiled_lines(), 0))
    l.append(_uncompiled_branches(branch_name))
    return l^


def test_the_two_unreliable_classes_are_left_out_of_an_uncompiled_report() raises:
    # `compiled` (lines 1-2, hit) and the plain `plain` (lines 4-7, not hit): 2 of 6 lines. `inlined` and `gated`
    # (lines 10-11, 13-16) are in the report and in no number. Of the four arms only `plain`'s two remain.
    var a = analyze(_inputs(String(UNCOMPILED_REPORT), String(UNCOMPILED_BRANCHES)), List[Input](), _repo(), Held(), _sources(), Options())
    var k = a.package_index(String(PKG))
    assert_true(k >= 0)
    assert_equal(a.packages[k].line_found, 6)
    assert_equal(a.packages[k].line_hit, 2)
    assert_equal(a.packages[k].branch_found, 2)
    assert_equal(a.packages[k].branch_hit, 0)


def test_the_same_reports_under_other_names_count_every_function() raises:
    # Only the file name sets buildrules' report apart: a report of the same lines named otherwise is a test's,
    # and its lines are all counted: 2 of 12 lines, 0 of 4 arms.
    var a = analyze(_inputs(String("x/other.cobertura.xml"), String("x/other.info")), List[Input](), _repo(), Held(), _sources(), Options())
    var k = a.package_index(String(PKG))
    assert_true(k >= 0)
    assert_equal(a.packages[k].line_found, 12)
    assert_equal(a.packages[k].line_hit, 2)
    assert_equal(a.packages[k].branch_found, 4)


def test_the_left_out_functions_are_still_listed_as_unreliable() raises:
    # The report gave `inlined` and `gated` no line the numbers keep, so they have no record: they are in
    # `unrecorded_functions` with the class that says it is no evidence.
    var a = analyze(_inputs(String(UNCOMPILED_REPORT), String(UNCOMPILED_BRANCHES)), List[Input](), _repo(), Held(), _sources(), Options())
    var kinds = String("")
    for i in range(len(a.unrecorded_functions)):
        kinds += a.unrecorded_functions[i].name + String(":") + a.unrecorded_functions[i].kind + String(" ")
    assert_equal(kinds, "inlined:always_inline gated:comptime_if ")


def test_a_file_only_unreliable_functions_make_is_not_named_by_the_report() raises:
    # A file the uncompiled report names only for an unreliable function has nothing left in it: it is
    # not named by the report, so the report alone measures no package (no empty file is counted as one
    # no test compiled).
    var only = List[Int]()
    only.append(10)
    only.append(11)
    var l = List[Input]()
    l.append(_report(String(UNCOMPILED_REPORT), only, 0))
    var a = analyze(l, List[Input](), _repo(), Held(), _sources(), Options())
    assert_equal(a.package_index(String(PKG)), -1)
    assert_equal(len(a.files), 0)


def test_the_names_that_set_the_reports_apart() raises:
    assert_true(is_uncompiled_report(String(UNCOMPILED_REPORT)))
    assert_true(is_uncompiled_report(String(UNCOMPILED_BRANCHES)))
    assert_true(is_uncompiled_report(String("uncompiled.cobertura.xml")))
    assert_true(not is_uncompiled_report(String("x/not_uncompiled.cobertura.xml")))
    assert_true(not is_uncompiled_report(String("x/uncompiled.cobertura.xml.bak")))
    assert_true(not is_uncompiled_report(String(TEST_REPORT)))


def main() raises:
    test_the_two_unreliable_classes_are_left_out_of_an_uncompiled_report()
    test_the_same_reports_under_other_names_count_every_function()
    test_the_left_out_functions_are_still_listed_as_unreliable()
    test_a_file_only_unreliable_functions_make_is_not_named_by_the_report()
    test_the_names_that_set_the_reports_apart()
