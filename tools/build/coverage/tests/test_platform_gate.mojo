from std.testing import assert_equal, assert_false, assert_true

from covcheck.analyze import FORMAT_COBERTURA, Analysis, Input, Options, Sources, analyze
from covcheck.annotate import DiffCoverage
from covcheck.held import Held
from covcheck.paths import RepoFiles, repo_files_of
from covcheck.result import report_json
from covcheck.summary import render_summary

# A function of buildrules' uncompiled report whose every caller is in a compile-time arm this target did not
# compile is platform-gated: not counted, and listed. The proof is from the call sites of its name in the package's
# sources: a site is dropped when it is in a compiled function, in one of its arms, on a line no report records (or in
# a function that is itself gated); any live site, no site, or an arm that was compiled keeps the function counted.

comptime PKG = "src/mp"
comptime LIB = "src/mp/src/mp/lib.mojo"
comptime OTHER = "src/mp/src/mp/other.mojo"

comptime LIB_SOURCE = (
    "def compiled(x: Int) -> Int:\n"                                           # 1
    "    var y = x\n"                                                          # 2
    "    comptime if DROPPED:\n"                                               # 3
    "        y = gated_a(y) + live_one(y) + chain_top(y) + dup(y)\n"           # 4  an arm no report records
    "    comptime else:\n"                                                     # 5
    "        y = arm_callee(x)\n"                                              # 6  the arm that was compiled
    "    return y + live_one(x)\n"                                             # 7  a live call
    "\n"                                                                       # 8
    "def gated_a(x: Int) -> Int:\n"                                            # 9  only caller: line 4
    "    return x + 1\n"                                                       # 10
    "\n"                                                                       # 11
    "def live_one(x: Int) -> Int:\n"                                           # 12 callers: line 4 and line 7
    "    return x + 2\n"                                                       # 13
    "\n"                                                                       # 14
    "def orphan(x: Int) -> Int:\n"                                             # 15 no caller at all
    "    return x + 3\n"                                                       # 16
    "\n"                                                                       # 17
    "def arm_callee(x: Int) -> Int:\n"                                         # 18 caller: line 6, a compiled arm
    "    return x + 4\n"                                                       # 19
    "\n"                                                                       # 20
    "def chain_top(x: Int) -> Int:\n"                                          # 21 only caller: line 4
    "    return chain_leaf(x)\n"                                               # 22
    "\n"                                                                       # 23
    "def chain_leaf(x: Int) -> Int:\n"                                         # 24 only caller: chain_top
    "    return x + 5\n"                                                       # 25
    "\n"                                                                       # 26
    "def dup(x: Int) -> Int:\n"                                                # 27 callers: line 4, and other.mojo's live `dup(`
    "    return x + 6\n"                                                       # 28
)

comptime OTHER_SOURCE = (
    "def dup(x: Int) -> Int:\n"      # 1  a function of the same name, compiled
    "    return x\n"                 # 2
    "\n"                             # 3
    "def user(x: Int) -> Int:\n"     # 4
    "    return dup(x)\n"            # 5  a live call of that name
)

comptime TEST_REPORT = "buck-out/v2/art/komira/x/src/mp/__test_a__cov__/test_a__cov.cobertura.xml"
comptime UNCOMPILED_REPORT = "buck-out/v2/art/komira/x/src/mp/__coverage__/uncompiled.cobertura.xml"


def _repo() -> RepoFiles:
    var l = List[String]()
    l.append("src/mp/BUCK")
    l.append(LIB)
    l.append(OTHER)
    return repo_files_of(l)


def _sources() -> Sources:
    var s = Sources(String(""))
    s.texts[String(LIB)] = String(LIB_SOURCE)
    s.texts[String(OTHER)] = String(OTHER_SOURCE)
    return s^


def _ints(*values: Int) -> List[Int]:
    var l = List[Int]()
    for v in values:
        l.append(v)
    return l^


def _class(path: String, lines: List[Int], hits: Int) -> String:
    var t = String("\t\t\t\t<class name=\"c\" filename=\"") + path + String("\">\n\t\t\t\t\t<lines>\n")
    for i in range(len(lines)):
        t += String("\t\t\t\t\t\t<line number=\"") + String(lines[i]) + String("\" hits=\"") + String(hits) + String("\"/>\n")
    t += String("\t\t\t\t\t</lines>\n\t\t\t\t</class>\n")
    return t^


def _report(origin: String, classes: String) -> Input:
    var t = String("<?xml version=\"1.0\" ?>\n<coverage timestamp=\"0\">\n\t<packages>\n\t\t<package name=\"\">\n\t\t\t<classes>\n")
    t += classes + String("\t\t\t</classes>\n\t\t</package>\n\t</packages>\n</coverage>\n")
    return Input(String(FORMAT_COBERTURA), String(""), origin, t)


def _analyze() raises -> Analysis:
    # The tests compiled `compiled` (its arm `else` and its live lines, not the dropped arm's line 4) and the other
    # file; the uncompiled report lists the seven functions below `compiled`.
    var l = List[Input]()
    l.append(_report(
        String(UNCOMPILED_REPORT),
        _class(String(LIB), _ints(10, 13, 16, 19, 22, 25, 28), 0),
    ))
    l.append(_report(
        String(TEST_REPORT),
        _class(String(LIB), _ints(1, 2, 6, 7), 1) + _class(String(OTHER), _ints(1, 2, 4, 5), 1),
    ))
    return analyze(l, List[Input](), _repo(), Held(), _sources(), Options())


def _names(a: Analysis) -> String:
    var s = String("")
    for i in range(len(a.platform_gated)):
        s += a.platform_gated[i].name + String(":") + String(a.platform_gated[i].lines) + String(";")
    return s^


def test_every_caller_in_a_dropped_arm_is_gated_and_a_chain_of_them_too() raises:
    # `gated_a`: its one caller is on line 4, in a dropped arm of a compiled function. `chain_top`: the same; and
    # `chain_leaf`: its only caller is `chain_top`, a gated function. One line each is in the report.
    var a = _analyze()
    assert_equal(_names(a), "gated_a:1;chain_top:1;chain_leaf:1;")
    assert_equal(a.platform_gated_lines(), 3)
    var h = a.files[a.file_index(String(LIB))].hits.copy()
    for ln in _ints(10, 22, 25):
        assert_false(ln in h, "line " + String(ln) + " is counted")


def test_a_live_caller_a_missing_caller_or_a_compiled_arm_keeps_a_function_counted() raises:
    var a = _analyze()
    var h = a.files[a.file_index(String(LIB))].hits.copy()
    # live_one: callers on line 4 (dropped) and line 7 (live). orphan: no caller. arm_callee: its caller, line 6,
    # is in an arm that has a record. dup: one dropped caller, and a live call of the name in another file.
    for ln in _ints(13, 16, 19, 28):
        assert_true(ln in h, "line " + String(ln) + " is not counted")
    var k = a.package_index(String(PKG))
    assert_true(k >= 0)
    # 4 lines of `compiled` + 4 counted functions' 4 lines + 4 of the other file.
    assert_equal(a.packages[k].line_found, 4 + 4 + 4)


def test_what_is_gated_is_in_the_result_and_the_summary() raises:
    var a = _analyze()
    var json = report_json(a, List[String](), DiffCoverage())
    assert_true('"platform_gated_functions":3' in json)
    assert_true('"platform_gated_lines":3' in json)
    assert_true('{"package":"src/mp","path":"src/mp/src/mp/lib.mojo","function":"gated_a","line":9,"lines":1}' in json)
    var summary = render_summary(a, List[String](), DiffCoverage(), False, String(""))
    assert_true("3 platform-gated functions, 3 lines" in summary)
    assert_true("`gated_a` in `src/mp/src/mp/lib.mojo` (1 lines)" in summary)


def test_with_no_uncompiled_report_nothing_is_gated() raises:
    var l = List[Input]()
    l.append(_report(
        String(TEST_REPORT),
        _class(String(LIB), _ints(1, 2, 6, 7), 1) + _class(String(OTHER), _ints(1, 2, 4, 5), 1),
    ))
    var a = analyze(l, List[Input](), _repo(), Held(), _sources(), Options())
    assert_equal(len(a.platform_gated), 0)
    assert_true('"platform_gated_functions":0' in report_json(a, List[String](), DiffCoverage()))


def main() raises:
    test_every_caller_in_a_dropped_arm_is_gated_and_a_chain_of_them_too()
    test_a_live_caller_a_missing_caller_or_a_compiled_arm_keeps_a_function_counted()
    test_what_is_gated_is_in_the_result_and_the_summary()
    test_with_no_uncompiled_report_nothing_is_gated()
