from std.testing import assert_equal, assert_false, assert_true

from covcheck.analyze import FORMAT_BRANCH_LCOV, FORMAT_COBERTURA, Analysis, Input, Options, Sources, analyze
from covcheck.held import Held
from covcheck.paths import RepoFiles, repo_files_of
from covcheck.result import report_json
from covcheck.annotate import DiffCoverage
from covcheck.summary import render_summary
from covcheck.uncompiled import is_uncompiled_report

# buildrules' report of the code no test compiled (`uncompiled.cobertura.xml`, `uncompiled.branches.info`):
# the executable lines of every function none of whose lines has a record, as found and not hit, and the
# arms of their decision words, as not taken. A function the compiler inlined into its callers, and one whose
# code is in a `comptime if` arm dropped here, look the same as a function nobody calls. A line is left out of
# the numbers only with evidence that a test reached the function: a line that calls it, outside it, that a
# test's report says was hit. An inlined function: all its lines. A gated function: the lines inside its
# compile-time arms, never the lines outside them. Everything else is counted.

comptime PKG = "src/mp"
comptime LIB = "src/mp/src/mp/lib.mojo"

comptime LIB_SOURCE = (
    "def driver(x: Int) -> Int:\n"                       # 1  compiled: a test hit it
    "    return inl_called(x) + gated_called(x) + outer(x)\n"  # 2
    "\n"                                                  # 3
    "def plain(x: Int) -> Int:\n"                         # 4  no test calls it
    "    if x < 0:\n"                                     # 5
    "        return 0\n"                                  # 6
    "    return x\n"                                      # 7
    "\n"                                                  # 8
    "@always_inline\n"                                    # 9
    "def inl_called(x: Int) -> Int:\n"                    # 10 inlined: driver calls it
    "    return x + 1\n"                                  # 11
    "\n"                                                  # 12
    "@always_inline\n"                                    # 13
    "def inl_uncalled(x: Int) -> Int:\n"                  # 14 inlined, and nothing calls it
    "    return x + 2\n"                                  # 15
    "\n"                                                  # 16
    "def gated_called(x: Int) -> Int:\n"                  # 17 live code outside two arms; driver calls it
    "    var y = x\n"                                     # 18
    "    comptime if True:\n"                             # 19
    "        y = x and x\n"                               # 20
    "    comptime else:\n"                                # 21
    "        y = 0\n"                                     # 22
    "    return y\n"                                      # 23
    "\n"                                                  # 24
    "def gated_uncalled(x: Int) -> Int:\n"                # 25 an arm, and nothing calls it
    "    comptime if True:\n"                             # 26
    "        return x\n"                                  # 27
    "    return 0\n"                                      # 28
    "\n"                                                  # 29
    "def outer(x: Int) -> Int:\n"                         # 30 plain; driver calls it
    "    @parameter\n"                                    # 31
    "    def inner() -> Int:\n"                           # 32 a closure with an arm of its own
    "        comptime if True:\n"                         # 33
    "            return x\n"                              # 34
    "        return 0\n"                                  # 35
    "    return inner()\n"                                # 36
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
    # The manifest of the package, read for its programs (programs.mojo): it declares none.
    s.texts[String("src/mp/mopm.toml")] = String("[targets]\nlib = { path = \"src/mp\" }\n")
    return s^


def _report(origin: String, lines: List[Int], hits: Int) -> Input:
    var t = String("<?xml version=\"1.0\" ?>\n<coverage timestamp=\"0\">\n\t<packages>\n\t\t<package name=\"\">\n\t\t\t<classes>\n")
    t += String("\t\t\t\t<class name=\"lib\" filename=\"") + String(LIB) + String("\">\n\t\t\t\t\t<lines>\n")
    for i in range(len(lines)):
        t += String("\t\t\t\t\t\t<line number=\"") + String(lines[i]) + String("\" hits=\"") + String(hits) + String("\"/>\n")
    t += String("\t\t\t\t\t</lines>\n\t\t\t\t</class>\n\t\t\t</classes>\n\t\t</package>\n\t</packages>\n</coverage>\n")
    return Input(String(FORMAT_COBERTURA), String(""), origin, t)


def _ints(*values: Int) -> List[Int]:
    var l = List[Int]()
    for v in values:
        l.append(v)
    return l^


def _uncompiled_lines() -> List[Int]:
    """The own executable lines of every function no test compiled."""
    return _ints(
        4, 5, 6, 7, 10, 11, 14, 15, 17, 18, 19, 20, 21, 22, 23, 25, 26, 27, 28, 30, 31, 32, 33, 34, 35, 36
    )


def _uncompiled_branches(origin: String) -> Input:
    """The arms of `if` (line 5, in `plain`) and of `and` (line 20, in an arm of `gated_called`), none taken."""
    var t = String("SF:") + String(LIB) + String("\nBRDA:5,8:br:0/1,0,-\nBRDA:5,8:br:0/1,1,-\nBRDA:20,17:br:0/1,0,-\nBRDA:20,17:br:0/1,1,-\nend_of_record\n")
    return Input(String(FORMAT_BRANCH_LCOV), String(""), origin, t)


def _inputs(driver_hit: Bool, uncompiled_name: String, branch_name: String) -> List[Input]:
    """The test's report: `driver` (lines 1 and 2) ran, line 2 (the calls) with a hit only when `driver_hit`."""
    var l = List[Input]()
    # The uncompiled report first: it must not matter where it is among the reports.
    l.append(_report(uncompiled_name, _uncompiled_lines(), 0))
    l.append(_uncompiled_branches(branch_name))
    l.append(_report(String(TEST_REPORT), _ints(1), 1))
    var calls = _ints(2)
    l.append(_report(String("buck-out/v2/art/komira/x/src/mp/__test_b__cov__/test_b__cov.cobertura.xml"), calls, 1 if driver_hit else 0))
    return l^


def _analyze(driver_hit: Bool) raises -> Analysis:
    return analyze(_inputs(driver_hit, String(UNCOMPILED_REPORT), String(UNCOMPILED_BRANCHES)), List[Input](), _repo(), Held(), _sources(), Options())


def _lib(a: Analysis) raises -> Int:
    var i = a.file_index(String(LIB))
    assert_true(i >= 0)
    return i


def test_a_function_a_test_called_is_left_out_and_the_rest_is_counted() raises:
    # Line 2 (the calls) was hit. Of the 26 uncompiled lines 6 are left out: the 2 of `inl_called`, and the 4
    # in the two arms of `gated_called` (19-22). The 2 test lines are hit: 2 + 20 = 22 lines found, 2 hit.
    var a = _analyze(True)
    var k = a.package_index(String(PKG))
    assert_true(k >= 0)
    assert_equal(a.packages[k].line_found, 22)
    assert_equal(a.packages[k].line_hit, 2)
    # Of the 4 arms the 2 on line 20 (in a left-out arm) go; the 2 of `plain` stay.
    assert_equal(a.packages[k].branch_found, 2)
    assert_equal(a.packages[k].branch_hit, 0)
    assert_equal(a.excluded_lines(), 6)
    assert_equal(a.excluded_arms(), 2)
    assert_equal(len(a.excluded), 1)
    assert_equal(a.excluded[0].path, String(LIB))
    assert_equal(a.excluded[0].package, String(PKG))
    assert_equal(a.excluded[0].lines, 6)
    assert_equal(a.excluded[0].arms, 2)


def test_a_function_nobody_calls_is_counted_whatever_its_class() raises:
    # `inl_uncalled` (14, 15) is inlined and nothing calls it; `gated_uncalled` (25-28) has an arm and nothing
    # calls it; `plain` (4-7) is plain: all counted, with `inl_called` and `gated_called` called or not.
    var a = _analyze(True)
    var h = a.files[_lib(a)].hits.copy()
    for ln in _ints(4, 5, 6, 7, 14, 15, 25, 26, 27, 28):
        assert_true(ln in h, "line " + String(ln) + " is not counted")


def test_a_gated_function_is_left_out_by_arm_not_whole() raises:
    # `gated_called` is called: its arm lines 19-22 go, its live lines 17, 18 and 23 stay.
    var a = _analyze(True)
    var h = a.files[_lib(a)].hits.copy()
    for ln in _ints(19, 20, 21, 22, 10, 11):
        assert_false(ln in h, "line " + String(ln) + " is counted")
    for ln in _ints(17, 18, 23):
        assert_true(ln in h, "line " + String(ln) + " is not counted")


def test_a_closure_is_a_function_of_its_own_and_does_not_reclassify_the_outer() raises:
    # `outer` is plain and called, so its lines (30, 31, 36) count; the closure `inner` has an arm (33, 34), and
    # nothing hit calls it (its call is on line 36, which no test hit): counted.
    var a = _analyze(True)
    var h = a.files[_lib(a)].hits.copy()
    for ln in _ints(30, 31, 36, 32, 33, 34, 35):
        assert_true(ln in h, "line " + String(ln) + " is not counted")


def test_without_a_hit_line_that_calls_them_nothing_is_left_out() raises:
    # The same reports with line 2 not hit: no evidence for any function, so all 26 uncompiled lines and the 4
    # arms count, and nothing is reported as left out.
    var a = _analyze(False)
    var k = a.package_index(String(PKG))
    assert_true(k >= 0)
    assert_equal(a.packages[k].line_found, 1 + 1 + 26)
    assert_equal(a.packages[k].branch_found, 4)
    assert_equal(a.excluded_lines(), 0)
    assert_equal(len(a.excluded), 0)


def test_the_same_reports_under_other_names_count_every_function() raises:
    # Only the file name and its directory set buildrules' report apart: the same lines named otherwise are a
    # test's, and are all counted: 2 + 26 lines, 4 arms.
    var a = analyze(_inputs(True, String("x/other.cobertura.xml"), String("x/other.info")), List[Input](), _repo(), Held(), _sources(), Options())
    var k = a.package_index(String(PKG))
    assert_true(k >= 0)
    assert_equal(a.packages[k].line_found, 28)
    assert_equal(a.packages[k].branch_found, 4)
    assert_equal(a.excluded_lines(), 0)


def test_what_is_left_out_is_in_the_result_and_the_summary() raises:
    var a = _analyze(True)
    var json = report_json(a, List[String](), DiffCoverage())
    assert_true('"excluded_lines":6' in json)
    assert_true('"excluded_arms":2' in json)
    assert_true('"excluded_files":[{"package":"src/mp","path":"src/mp/src/mp/lib.mojo","lines":6,"arms":2}]' in json)
    var summary = render_summary(a, List[String](), DiffCoverage(), False, String(""))
    assert_true("6 lines and 2 branch arms of the code no test compiled" in summary)
    assert_true("`src/mp/src/mp/lib.mojo`" in summary)
    # Nothing left out: neither is said.
    var b = _analyze(False)
    assert_true('"excluded_lines":0' in report_json(b, List[String](), DiffCoverage()))
    assert_false("of the code no test compiled" in render_summary(b, List[String](), DiffCoverage(), False, String("")))


def test_a_file_the_report_leaves_nothing_of_counts_like_one_no_report_names() raises:
    # The uncompiled report names the file for `inl_called` alone (lines 10, 11), and line 2, which calls it, was
    # hit in another file's report: nothing of the uncompiled file is left, so it is not named by that report;
    # the files-no-test-compiled pass then counts it from its source, without the two lines the report left out.
    var l = List[Input]()
    l.append(_report(String(UNCOMPILED_REPORT), _ints(10, 11), 0))
    l.append(Input(
        String(FORMAT_COBERTURA), String(""), String(TEST_REPORT),
        String("<coverage><packages><package name=\"\"><classes><class name=\"o\" filename=\"src/mp/src/mp/other.mojo\"><lines><line number=\"2\" hits=\"1\"/></lines></class></classes></package></packages></coverage>"),
    ))
    var files = List[String]()
    files.append("src/mp/BUCK")
    files.append(LIB)
    files.append("src/mp/src/mp/other.mojo")
    var s = Sources(String(""))
    s.texts[String(LIB)] = String(LIB_SOURCE)
    # `other.mojo` imports inl_called and line 2 calls it (a hit line).
    s.texts[String("src/mp/src/mp/other.mojo")] = String("from mp.lib import inl_called\nx = inl_called(1)\n")
    var a = analyze(l, List[Input](), repo_files_of(files), Held(), s, Options())
    var k = a.package_index(String(PKG))
    assert_true(k >= 0)
    var i = a.file_index(String(LIB))
    assert_true(i >= 0)
    assert_false(10 in a.files[i].hits)
    assert_false(11 in a.files[i].hits)
    assert_true(1 in a.files[i].hits)
    assert_equal(a.excluded_lines(), 2)


def test_the_names_that_set_the_reports_apart() raises:
    assert_true(is_uncompiled_report(String(UNCOMPILED_REPORT)))
    assert_true(is_uncompiled_report(String(UNCOMPILED_BRANCHES)))
    assert_true(is_uncompiled_report(String("__coverage__/uncompiled.cobertura.xml")))
    # Not under `__coverage__/`, or another name: a test's report.
    assert_false(is_uncompiled_report(String("uncompiled.cobertura.xml")))
    assert_false(is_uncompiled_report(String("x/uncompiled.cobertura.xml")))
    assert_false(is_uncompiled_report(String("x/__test_a__cov__/uncompiled.cobertura.xml")))
    assert_false(is_uncompiled_report(String("x/__coverage__/not_uncompiled.cobertura.xml")))
    assert_false(is_uncompiled_report(String("x/__coverage__/uncompiled.cobertura.xml.bak")))
    assert_false(is_uncompiled_report(String(TEST_REPORT)))


def test_a_declaration_is_no_evidence_that_a_function_is_called() raises:
    # The hit line is the `def` line of another function that has the same name as `inl_called`
    # (its parameter list opens right after the name): a declaration calls nothing, so nothing is left out.
    var l = List[Input]()
    l.append(_report(String(UNCOMPILED_REPORT), _uncompiled_lines(), 0))
    l.append(_report(String(TEST_REPORT), _ints(1), 1))
    var files = List[String]()
    files.append("src/mp/BUCK")
    files.append(LIB)
    files.append("src/mp/src/mp/other.mojo")
    l.append(Input(
        String(FORMAT_COBERTURA), String(""), String("buck-out/v2/art/komira/x/src/mp/__test_c__cov__/test_c__cov.cobertura.xml"),
        String("<coverage><packages><package name=\"\"><classes><class name=\"o\" filename=\"src/mp/src/mp/other.mojo\"><lines><line number=\"1\" hits=\"1\"/></lines></class></classes></package></packages></coverage>"),
    ))
    var s = Sources(String(""))
    s.texts[String(LIB)] = String(LIB_SOURCE)
    s.texts[String("src/mp/src/mp/other.mojo")] = String("  def inl_called(x: Int) -> Int:  # declared, not called\n")
    var a = analyze(l, List[Input](), repo_files_of(files), Held(), s, Options())
    assert_equal(a.excluded_lines(), 0)


def test_a_method_call_is_evidence_for_a_method_and_a_bare_call_for_a_free_function() raises:
    # `free` (a free function) and `meth` (a method) are `@always_inline` and uncalled by any report. The hit line 1 reads
    # `v.free()`: a method call of another type's `free`, no evidence for the free function; `meth` is called as
    # `S(v).meth()`, which names its type. A second hit line, a bare `free(v)`, is evidence for the free function.
    var src = String(
        "def driver(v: Int) -> Int:\n"        # 1
        "    return v.free() + S(v).meth()\n" # 2
        "\n"                                  # 3
        "@always_inline\n"                    # 4
        "def free(v: Int) -> Int:\n"          # 5
        "    return v\n"                      # 6
        "\n"                                  # 7
        "struct S:\n"                         # 8
        "    @always_inline\n"                # 9
        "    def meth(self) -> Int:\n"        # 10
        "        pass\n"                      # 11
        "\n"                                  # 12
        "def driver2(v: Int) -> Int:\n"       # 13
        "    return free(v)\n"                # 14
    )
    var files = List[String]()
    files.append("src/mp/BUCK")
    files.append(LIB)
    var s = Sources(String(""))
    s.texts[String(LIB)] = src
    var one = List[Input]()
    one.append(_report(String(UNCOMPILED_REPORT), _ints(5, 6, 10, 11), 0))
    one.append(_report(String(TEST_REPORT), _ints(1, 2), 1))
    var a = analyze(one, List[Input](), repo_files_of(files), Held(), s, Options())
    var h = a.files[a.file_index(String(LIB))].hits.copy()
    # `meth` (10, 11) is left out; `free` (5, 6) is counted: only a method call of that name was hit.
    assert_false(10 in h)
    assert_true(5 in h)
    assert_true(6 in h)
    # With the bare call hit too, `free` is left out as well.
    var two = List[Input]()
    two.append(_report(String(UNCOMPILED_REPORT), _ints(5, 6, 10, 11), 0))
    two.append(_report(String(TEST_REPORT), _ints(1, 2, 14), 1))
    var b = analyze(two, List[Input](), repo_files_of(files), Held(), s, Options())
    var h2 = b.files[b.file_index(String(LIB))].hits.copy()
    assert_false(5 in h2)
    assert_false(10 in h2)


def _evidence_run(src: String, other_pkg: Bool, uncompiled: List[Int], hit_in_lib: List[Int], other_text: String = String("x = foo(1)\n"), other_hit: Int = 1) raises -> Analysis:
    """`src` is src/mp's file; the hit call is on line `other_hit` of `other_text`, a file of src/mp (the second file
    `other.mojo`), or of src/other when `other_pkg`."""
    var other = String("src/other/src/other/o.mojo") if other_pkg else String("src/mp/src/mp/other.mojo")
    var files = List[String]()
    files.append("src/mp/BUCK")
    files.append(LIB)
    files.append(other)
    if other_pkg:
        files.append("src/other/BUCK")
    var s = Sources(String(""))
    s.texts[String(LIB)] = src
    s.texts[other] = other_text.copy()
    var l = List[Input]()
    l.append(_report(String(UNCOMPILED_REPORT), uncompiled, 0))
    l.append(_report(String(TEST_REPORT), hit_in_lib, 1))
    l.append(Input(
        String(FORMAT_COBERTURA), String(""), String("buck-out/v2/art/komira/x/src/mp/__test_c__cov__/test_c__cov.cobertura.xml"),
        String("<coverage><packages><package name=\"\"><classes><class name=\"o\" filename=\"") + other
        + String("\"><lines><line number=\"") + String(other_hit) + String("\" hits=\"1\"/></lines></class></classes></package></packages></coverage>"),
    ))
    return analyze(l, List[Input](), repo_files_of(files), Held(), s, Options())


def test_a_hit_call_in_another_package_is_no_evidence() raises:
    var src = String(
        "@always_inline\n"                    # 1
        "def foo(x: Int) -> Int:\n"           # 2
        "    return x\n"                      # 3
        "\n"                                  # 4
        "def driver(x: Int) -> Int:\n"        # 5
        "    return x\n"                      # 6
    )
    # The hit `foo(1)` is in a file of the same package that imports the name: left out. In another package: counted.
    var same = _evidence_run(src, False, _ints(3), _ints(5, 6), String("from mp.lib import foo\nx = foo(1)\n"), 2)
    assert_equal(same.excluded_lines(), 1)
    var other = _evidence_run(src, True, _ints(3), _ints(5, 6))
    assert_equal(other.excluded_lines(), 0)
    assert_true(3 in other.files[other.file_index(String(LIB))].hits)


def test_a_name_the_package_declares_twice_is_no_evidence_for_a_free_function() raises:
    # `foo` is declared in lib.mojo (inlined, uncalled) and in other.mojo: a call of the name could be either.
    var src = String(
        "@always_inline\n"                    # 1
        "def foo(x: Int) -> Int:\n"           # 2
        "    return x\n"                      # 3
        "\n"                                  # 4
        "def driver(x: Int) -> Int:\n"        # 5
        "    return x\n"                      # 6
    )
    var files = List[String]()
    files.append("src/mp/BUCK")
    files.append(LIB)
    files.append("src/mp/src/mp/other.mojo")
    var s = Sources(String(""))
    s.texts[String(LIB)] = src
    s.texts[String("src/mp/src/mp/other.mojo")] = String("def foo(x: Int) -> Int:\n    return foo(x)\n")
    var l = List[Input]()
    l.append(_report(String(UNCOMPILED_REPORT), _ints(3), 0))
    l.append(_report(String(TEST_REPORT), _ints(5, 6), 1))
    l.append(Input(
        String(FORMAT_COBERTURA), String(""), String("buck-out/v2/art/komira/x/src/mp/__test_c__cov__/test_c__cov.cobertura.xml"),
        String("<coverage><packages><package name=\"\"><classes><class name=\"o\" filename=\"src/mp/src/mp/other.mojo\"><lines><line number=\"2\" hits=\"1\"/></lines></class></classes></package></packages></coverage>"),
    ))
    var a = analyze(l, List[Input](), repo_files_of(files), Held(), s, Options())
    assert_equal(a.excluded_lines(), 0)
    assert_true(3 in a.files[a.file_index(String(LIB))].hits)


def test_a_method_is_told_by_the_type_its_call_names() raises:
    # `A.ne` and `B.ne` are both inlined and uncompiled, and `ne` is declared twice. The hit call is
    # `A(x).ne(1)`: its receiver names A, so A's lines are left out and B's are counted.
    var src = String(
        "struct A:\n"                         # 1
        "    @always_inline\n"                # 2
        "    def ne(self, o: Int) -> Bool:\n" # 3
        "        return o == 1\n"             # 4
        "\n"                                  # 5
        "struct B:\n"                         # 6
        "    @always_inline\n"                # 7
        "    def ne(self, o: Int) -> Bool:\n" # 8
        "        return o == 2\n"             # 9
        "\n"                                  # 10
        "def driver(x: Int) -> Bool:\n"       # 11
        "    return A(x).ne(1)\n"             # 12
    )
    var files = List[String]()
    files.append("src/mp/BUCK")
    files.append(LIB)
    var s = Sources(String(""))
    s.texts[String(LIB)] = src
    var l = List[Input]()
    l.append(_report(String(UNCOMPILED_REPORT), _ints(3, 4, 8, 9), 0))
    l.append(_report(String(TEST_REPORT), _ints(11, 12), 1))
    var a = analyze(l, List[Input](), repo_files_of(files), Held(), s, Options())
    var h = a.files[a.file_index(String(LIB))].hits.copy()
    assert_false(3 in h)
    assert_false(4 in h)
    assert_true(8 in h)
    assert_true(9 in h)


def test_a_call_named_inside_a_multi_line_string_is_no_evidence() raises:
    # Line 3 is the interior of a triple-quoted string; a report that marks it hit does not make it a call.
    var src = String(
        "def driver(x: Int) -> Int:\n"        # 1
        "    var s = \"\"\"\n"             # 2
        "inl_called(1)\n"                     # 3
        "\"\"\"\n"                         # 4
        "    return x\n"                      # 5
        "\n"                                  # 6
        "@always_inline\n"                    # 7
        "def inl_called(x: Int) -> Int:\n"    # 8
        "    return x\n"                      # 9
    )
    var files = List[String]()
    files.append("src/mp/BUCK")
    files.append(LIB)
    var s = Sources(String(""))
    s.texts[String(LIB)] = src
    var l = List[Input]()
    l.append(_report(String(UNCOMPILED_REPORT), _ints(9), 0))
    l.append(_report(String(TEST_REPORT), _ints(1, 2, 3, 5), 1))
    var a = analyze(l, List[Input](), repo_files_of(files), Held(), s, Options())
    assert_equal(a.excluded_lines(), 0)
    assert_true(9 in a.files[a.file_index(String(LIB))].hits)


def test_a_free_function_needs_a_call_that_can_reach_it() raises:
    var src = String(
        "@always_inline\n"                    # 1
        "def foo(x: Int) -> Int:\n"           # 2
        "    return x\n"                      # 3
        "\n"                                  # 4
        "def driver(x: Int) -> Int:\n"        # 5
        "    return x\n"                      # 6
    )
    # A hit `foo(1)` in another file of the package that does not import `foo` or its module: counted.
    var none = _evidence_run(src, False, _ints(3), _ints(5, 6))
    assert_equal(none.excluded_lines(), 0)
    assert_true(3 in none.files[none.file_index(String(LIB))].hits)
    # One that imports the module (`import mp.lib`): left out.
    var module = _evidence_run(src, False, _ints(3), _ints(5, 6), String("import mp.lib\nx = lib.foo(1)\ny = foo(1)\n"), 3)
    assert_equal(module.excluded_lines(), 1)
    # A call in the same file is enough: line 6 here calls it.
    var own = String(
        "@always_inline\n"                    # 1
        "def foo(x: Int) -> Int:\n"           # 2
        "    return x\n"                      # 3
        "\n"                                  # 4
        "def driver(x: Int) -> Int:\n"        # 5
        "    return foo(x)\n"                 # 6
    )
    var same = _evidence_run(own, False, _ints(3), _ints(5, 6))
    assert_equal(same.excluded_lines(), 1)


def test_a_method_needs_a_call_that_names_its_type() raises:
    var src = String(
        "struct S:\n"                         # 1
        "    @always_inline\n"                # 2
        "    def size(self) -> Int:\n"        # 3
        "        return 1\n"                  # 4
        "\n"                                  # 5
        "def driver(b: List[Int]) -> Int:\n"  # 6
        "    return b.size()\n"               # 7
        "\n"                                  # 8
        "def typed(x: Int) -> Int:\n"         # 9
        "    return S().size()\n"             # 10
    )
    var files = List[String]()
    files.append("src/mp/BUCK")
    files.append(LIB)
    var s = Sources(String(""))
    s.texts[String(LIB)] = src
    # Only the call on an unknown receiver (line 7) was hit: the method is counted.
    var l = List[Input]()
    l.append(_report(String(UNCOMPILED_REPORT), _ints(3, 4), 0))
    l.append(_report(String(TEST_REPORT), _ints(6, 7), 1))
    var a = analyze(l, List[Input](), repo_files_of(files), Held(), s, Options())
    assert_equal(a.excluded_lines(), 0)
    # With the call that names the type (line 10) hit too: left out.
    var m = List[Input]()
    m.append(_report(String(UNCOMPILED_REPORT), _ints(3, 4), 0))
    m.append(_report(String(TEST_REPORT), _ints(6, 7, 9, 10), 1))
    var b = analyze(m, List[Input](), repo_files_of(files), Held(), s, Options())
    assert_equal(b.excluded_lines(), 2)


def main() raises:
    test_a_function_a_test_called_is_left_out_and_the_rest_is_counted()
    test_a_function_nobody_calls_is_counted_whatever_its_class()
    test_a_gated_function_is_left_out_by_arm_not_whole()
    test_a_closure_is_a_function_of_its_own_and_does_not_reclassify_the_outer()
    test_without_a_hit_line_that_calls_them_nothing_is_left_out()
    test_the_same_reports_under_other_names_count_every_function()
    test_what_is_left_out_is_in_the_result_and_the_summary()
    test_a_file_the_report_leaves_nothing_of_counts_like_one_no_report_names()
    test_a_declaration_is_no_evidence_that_a_function_is_called()
    test_a_method_call_is_evidence_for_a_method_and_a_bare_call_for_a_free_function()
    test_a_hit_call_in_another_package_is_no_evidence()
    test_a_name_the_package_declares_twice_is_no_evidence_for_a_free_function()
    test_a_method_is_told_by_the_type_its_call_names()
    test_a_call_named_inside_a_multi_line_string_is_no_evidence()
    test_a_free_function_needs_a_call_that_can_reach_it()
    test_a_method_needs_a_call_that_names_its_type()
    test_the_names_that_set_the_reports_apart()
