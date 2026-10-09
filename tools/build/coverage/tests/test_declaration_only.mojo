from std.testing import assert_equal, assert_false, assert_true

from covcheck.analyze import FORMAT_LCOV, Analysis, Input, Options, Sources, analyze
from covcheck.decls import declaration_only
from covcheck.lexer import executable_lines
from covcheck.paths import repo_files_of
from covcheck.ratchet import parse_ratchet
from covcheck.stats import Finding
from covcheck.text import join, read_text

# Declaration-only files (decls.declaration_only): a file no test compiled
# whose executable lines
# (the heuristic's) are all declarations the compiler emits no code for
# (traits whose methods have no body, comptime values, imports) counts no
# line and raises the information DeclarationOnlyFile, where it was charged
# as uncovered (UnmeasuredFile). Anything with a body keeps counting: the
# near-miss fixture (one trait method with a default implementation) and a
# table of near misses each stay counted.

comptime FIXTURES = "tools/build/coverage/tests/fixtures/decl/"


def _fixture(name: String) raises -> String:
    return read_text(String(FIXTURES) + name)


def test_the_fixture_is_declaration_only() raises:
    var text = _fixture(String("declaration_only.mojo"))
    # The heuristic counts its declarations: 26 lines, the docstrings'
    # `return`/`var` text and the imports aside.
    assert_equal(len(executable_lines(text)), 26)
    assert_true(declaration_only(text))


def test_the_near_miss_fixture_is_not() raises:
    var text = _fixture(String("near_miss.mojo"))
    assert_equal(len(executable_lines(text)), 7)
    assert_false(declaration_only(text))


def test_declaration_only_shapes() raises:
    var yes = List[String]()
    yes.append("trait A(Copyable):\n    \"\"\"Doc.\"\"\"\n    ...\n")
    yes.append("comptime N = 3\ncomptime M: Int = N + 1\n")
    yes.append("from x import y\n\ntrait T:\n    def f(self) -> Int: ...\n")
    yes.append("trait T:\n    def f(self) -> Int:  # why\n        \"\"\"Doc.\n\n        return 1\n        \"\"\"\n        ...  # required\n")
    yes.append("comptime D = {\n    \"a\": 1,\n}\n")
    yes.append("trait T:\n    comptime S: Dict[\n        String, Int\n    ]\n    def f(self, m: Dict[String,\n            Int]) -> Int:\n        ...\n")
    var wrong = List[String]()
    for i in range(len(yes)):
        if not declaration_only(yes[i]):
            wrong.append(yes[i])
    assert_equal(len(wrong), 0, String("not declaration-only: ") + join(wrong, String(" || ")))


def test_near_misses_keep_counting() raises:
    var no = List[String]()
    # a trait default implementation with code, after a docstring
    no.append("trait T:\n    def f(self) -> Int:\n        \"\"\"Doc.\"\"\"\n        return 1\n")
    # a default implementation of `pass` is a body
    no.append("trait T:\n    def f(self):\n        pass\n")
    # `...` then code in the same body
    no.append("trait T:\n    def f(self) -> Int:\n        ...\n        return 1\n")
    # a one-line default implementation
    no.append("trait T:\n    def f(self) -> Int: return 1\n")
    # a decorated method with code
    no.append("trait T:\n    @staticmethod\n    def f() -> Int:\n        return 1\n")
    # a multi-line generic header, then code
    no.append("trait T:\n    def f[\n        n: Int\n    ](self) -> Int:\n        return n\n")
    # a free function, a struct, a top-level var, a statement
    no.append("trait T:\n    ...\n\ndef f() -> Int:\n    return 1\n")
    no.append("def f(): ...\n")
    no.append("struct S:\n    var x: Int\n")
    no.append("comptime N = 1\nvar x = N\n")
    no.append("comptime N = 1\nprint(N)\n")
    # a comptime statement opening a block
    no.append("comptime if True:\n    comptime N = 1\n")
    # a `;` outside an import, and code after an import's `;`
    no.append("comptime N = 1; comptime M = 2\n")
    no.append("import os; os.abort()\ncomptime N = 1\n")
    # a tab in the indentation
    no.append("trait T:\n\tdef f(self): ...\n")
    # a header ending neither with `:` nor with `: ...`
    no.append("trait T:\n    def f(self) -> Int: \"\"\"doc\"\"\"\n")
    # a member outside any trait's block
    no.append("comptime N = 1\n    def f(self): ...\n")
    # code after a docstring closes on its line
    no.append("trait T:\n    def f(self):\n        \"\"\"Doc.\n        \"\"\" + g()\n")
    # a statement still open at the end of the file: ( [ {, and a struct
    # with code inside an open ( or {
    no.append("trait T:\n    ...\ncomptime X = (\n    1\n")
    no.append("trait T:\n    ...\ncomptime X = [\n")
    no.append("comptime X = {\n    1: 2,\n")
    no.append("comptime X = (\n    1,\nstruct S:\n    def f(self) -> Int:\n        return 1\n")
    no.append("comptime X = {\n    1: 2,\nstruct S:\n    def f(self) -> Int:\n        return 1\n")
    # a function inside a statement whose braces balance around it: the
    # walk never reads it as a statement, decls finds it
    no.append("comptime X = {\nstruct S:\n    def f(self) -> Int:\n        return 1\n}\n")
    # a one-line body that opens a bracket and ends in `: ...`
    no.append("trait T:\n    def f(self) -> Int: y[1: ...\n")
    # a carriage return with no line feed: one line to the lexer
    no.append("comptime N = 1\rdef f() -> Int:\r    return 1\r")
    # the lexer ends inside a string: r"""C:\""" never closes, hiding code
    no.append("trait T:\n    ...\ncomptime P = r\"\"\"C:\\\"\"\"\ndef f() -> Int:\n    return 1\n")
    # nothing executable: nothing to leave out
    no.append("\"\"\"Doc.\"\"\"\nfrom x import y\n")
    var wrong = List[String]()
    for i in range(len(no)):
        if declaration_only(no[i]):
            wrong.append(no[i])
    assert_equal(len(wrong), 0, String("read as declaration-only: ") + join(wrong, String(" || ")))


def _repo() -> List[String]:
    var l = List[String]()
    l.append("src/p/BUCK")
    l.append("src/p/a.mojo")
    l.append("src/p/decl.mojo")
    return l^


def _report() -> List[Input]:
    # a.mojo covered, lines and branches; decl.mojo absent from the report.
    var l = List[Input]()
    l.append(Input(String(FORMAT_LCOV), String(""), String("t.info"), String(
        "SF:src/p/a.mojo\nDA:1,1\nDA:2,3\nBRDA:2,0,0,1\nBRDA:2,0,1,2\nend_of_record\n"
    )))
    return l^


def _run(decl: String) raises -> Analysis:
    var s = Sources(String(""))
    s.texts[String("src/p/a.mojo")] = String("def f() -> Int:\n    return 1\n")
    s.texts[String("src/p/decl.mojo")] = decl
    var o = Options()
    o.mode = String("enforce")
    var rat = parse_ratchet(String("src/p\t10000\t10000\n"), String("r.tsv"))
    return analyze(_report(), List[Input](), repo_files_of(_repo()), rat, s, o)


def _kinds(fs: List[Finding]) -> String:
    var s = String("")
    for i in range(len(fs)):
        if i > 0:
            s += String(" ")
        s += fs[i].kind + String("@") + fs[i].path
    return s^


def test_a_declaration_only_file_is_not_charged() raises:
    # Before: decl.mojo's 26 lines counted uncovered, 2/28, UnmeasuredFile
    # and BelowTarget. Now: 2/2 and success, the file a note.
    var a = _run(_fixture(String("declaration_only.mojo")))
    var k = a.package_index(String("src/p"))
    assert_equal(a.packages[k].line_found, 2, _kinds(a.findings))
    assert_equal(a.packages[k].line_hit, 2)
    assert_equal(a.packages[k].files, 1)
    assert_equal(a.packages[k].unmeasured_files, 0)
    assert_equal(_kinds(a.findings), "")
    assert_equal(a.conclusion, "success")
    assert_equal(_kinds(a.info_findings), "DeclarationOnlyFile@src/p/decl.mojo")
    assert_equal(a.info_findings[0].count, 26)
    assert_equal(a.info_findings[0].package, "src/p")
    assert_equal(a.info_findings[0].line, 0)
    assert_true(a.info_findings[0].message.startswith("UnmeasuredFile (declaration-only): "), a.info_findings[0].message)
    assert_equal(a.file_index(String("src/p/decl.mojo")), -1)


def test_the_near_miss_is_charged() raises:
    var a = _run(_fixture(String("near_miss.mojo")))
    var k = a.package_index(String("src/p"))
    assert_equal(a.packages[k].line_found, 9, _kinds(a.findings))
    assert_equal(a.packages[k].unmeasured_files, 1)
    assert_equal(_kinds(a.findings), "BelowTarget@ Regression@ UnmeasuredFile@src/p/decl.mojo")
    assert_equal(len(a.info_findings), 0)
    assert_equal(a.conclusion, "failure")


def test_a_declaration_only_file_with_a_marker_still_counts() raises:
    # A marker on a declaration: the file is not left out (the marker would
    # go stale); its other lines count as before.
    var text = _fixture(String("declaration_only.mojo")).replace(
        "comptime DEFAULT_ID: UInt32 = 7000\n", "comptime DEFAULT_ID: UInt32 = 7000  # cov: unreachable a constant\n"
    )
    var a = _run(text)
    var k = a.package_index(String("src/p"))
    assert_equal(a.packages[k].line_found, 27)
    assert_equal(a.packages[k].exempt_lines, 1)
    assert_equal(len(a.info_findings), 0)


def main() raises:
    test_the_fixture_is_declaration_only()
    test_the_near_miss_fixture_is_not()
    test_declaration_only_shapes()
    test_near_misses_keep_counting()
    test_a_declaration_only_file_is_not_charged()
    test_the_near_miss_is_charged()
    test_a_declaration_only_file_with_a_marker_still_counts()
    print("test_declaration_only: PASS")
