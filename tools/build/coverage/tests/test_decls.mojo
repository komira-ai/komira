from std.testing import assert_equal, assert_true

from komira_json import parse_json_value

from covcheck.analyze import FORMAT_LCOV, Analysis, Input, Options, Sources, analyze
from covcheck.decls import FnDecl, declared_functions, uncompiled_functions
from covcheck.paths import repo_files_of
from covcheck.ratchet import Ratchet
from covcheck.result import gate_json, report_json
from covcheck.annotate import DiffCoverage

# Declaration reachability (decls.mojo, analyze.mojo step 8): which functions
# a source declares, where each one's body ends, which of its lines are its
# own, and which functions no report gives a line: those are listed, and no
# number changes (report only).


def _render(fns: List[FnDecl]) -> String:
    """`name@line-end:l,l,...` per function, `;`-separated."""
    var s = String("")
    for i in range(len(fns)):
        if i > 0:
            s += ";"
        s += fns[i].name + "@" + String(fns[i].line) + "-" + String(fns[i].end) + ":"
        for k in range(len(fns[i].lines)):
            if k > 0:
                s += ","
            s += String(fns[i].lines[k])
    return s^


def _finding_kinds(a: Analysis) -> String:
    var s = String("")
    for i in range(len(a.findings)):
        s += a.findings[i].kind + ";"
    return s^


comptime STRUCT_AND_TOP = (
    "\"\"\"Module doc.\"\"\"\n"          # 1
    "from x import y\n"                  # 2
    "\n"                                 # 3
    "struct S:\n"                        # 4
    "    var a: Int\n"                   # 5
    "\n"                                 # 6
    "    def __init__(out self):\n"      # 7
    "        self.a = 1\n"               # 8
    "\n"                                 # 9
    "    @always_inline\n"               # 10
    "    def get(self) -> Int:\n"        # 11
    "        \"\"\"Doc.\"\"\"\n"         # 12
    "        return self.a\n"            # 13
    "\n"                                 # 14
    "\n"                                 # 15
    "def top(\n"                         # 16
    "    a: Int,\n"                      # 17
    "    b: Int,\n"                      # 18
    ") -> Int:\n"                        # 19
    "    # a comment\n"                  # 20
    "    return a + b\n"                 # 21
    "\n"                                 # 22
    "fn old_style(x: Int) -> Int:\n"     # 23
    "    return x\n"                     # 24
)


def test_methods_and_functions_with_their_own_lines() raises:
    # A method's body ends where the struct's next member starts; a
    # signature over several lines counts each of its lines; a docstring,
    # a comment and a blank line are not executable; `fn` is a declaration
    # like `def`.
    assert_equal(
        _render(declared_functions(String(STRUCT_AND_TOP))),
        "__init__@7-8:7,8;get@11-13:11,13;top@16-21:16,17,18,19,21;old_style@23-24:23,24",
    )


def test_a_trait_requirement_is_not_a_function_a_default_is() raises:
    var src = String(
        "trait T:\n"                          # 1
        "    def f(self): ...\n"              # 2
        "    def g(self) -> Int:\n"           # 3
        "        \"\"\"Doc.\"\"\"\n"          # 4
        "        ...\n"                       # 5
        "    def h(self) -> Int:\n"           # 6
        "        return 1\n"                  # 7
        "    def k(self):\n"                  # 8
        "        pass\n"                      # 9
    )
    # `...` alone (on the line or as the body, after a docstring) declares
    # without defining; `pass` is a body (its code sits on the def line).
    assert_equal(_render(declared_functions(src)), "h@6-7:6,7;k@8-9:8,9")


def test_a_body_on_the_signature_line() raises:
    var src = String("def f() -> Int: return 1\ndef g(): ...\nx = 2\n")
    assert_equal(_render(declared_functions(src)), "f@1-1:1")


def test_a_nested_function_owns_its_lines() raises:
    var src = String(
        "def outer():\n"          # 1
        "    var x = 1\n"         # 2
        "    def inner():\n"      # 3
        "        x += 1\n"        # 4
        "    inner()\n"           # 5
    )
    assert_equal(_render(declared_functions(src)), "outer@1-5:1,2,5;inner@3-4:3,4")


def test_def_in_a_string_or_a_comment_is_not_a_declaration() raises:
    var src = String(
        "s = \"\"\"\n"            # 1
        "def fake():\n"           # 2
        "    pass\n"              # 3
        "\"\"\"\n"                # 4
        "# def no():\n"           # 5
        "t = \"def nope(): pass\"\n"  # 6
        "defx = 1\n"              # 7
        "def real():\n"           # 8
        "    pass\n"              # 9
    )
    assert_equal(_render(declared_functions(src)), "real@8-9:8,9")


def test_a_generic_signature_over_lines_and_brackets_in_a_string() raises:
    var src = String(
        "def f[\n"                      # 1
        "    T: Copyable,\n"            # 2
        "](x: T) -> T:\n"               # 3
        "    return x\n"                # 4
        "def g(s: String = \"a)[:\"):\n"  # 5
        "    pass\n"                    # 6
        "comptime N = 3\n"              # 7
    )
    assert_equal(_render(declared_functions(src)), "f@1-4:1,2,3,4;g@5-6:5,6")


def test_a_docstring_at_a_lower_indent_does_not_end_the_body() raises:
    var src = String(
        "def f():\n"                    # 1
        "    \"\"\"Doc\n"               # 2
        "at column zero.\n"             # 3
        "    \"\"\"\n"                  # 4
        "    return 1\n"                # 5
        "x = 2\n"                       # 6
    )
    assert_equal(_render(declared_functions(src)), "f@1-5:1,5")


comptime THREE = (
    "def a():\n"       # 1
    "    pass\n"       # 2
    "\n"               # 3
    "def b():\n"       # 4
    "    x()\n"        # 5
    "\n"               # 6
    "def c():\n"       # 7
    "    y()\n"        # 8
    "    z()\n"        # 9
)


def test_uncompiled_functions_are_those_with_no_recorded_line() raises:
    var rec = Dict[Int, Int]()
    rec[1] = 0  # a: its def line has a record (with 0 hits: compiled, not run)
    var none = Dict[Int, Bool]()
    assert_equal(_render(uncompiled_functions(String(THREE), rec, none)), "b@4-5:4,5;c@7-9:7,8,9")
    # One record anywhere in the body makes it compiled.
    rec[9] = 2
    assert_equal(_render(uncompiled_functions(String(THREE), rec, none)), "b@4-5:4,5")
    # A marked line leaves the count; a function with every line marked is
    # not listed.
    var marked = Dict[Int, Bool]()
    marked[5] = True
    assert_equal(_render(uncompiled_functions(String(THREE), rec, marked)), "b@4-5:4")
    marked[4] = True
    assert_equal(_render(uncompiled_functions(String(THREE), rec, marked)), "")


def test_a_compiled_closure_does_not_make_its_parent_compiled() raises:
    var src = String(
        "def outer():\n"          # 1
        "    def inner():\n"      # 2
        "        x()\n"           # 3
        "    inner()\n"           # 4
    )
    var rec = Dict[Int, Int]()
    rec[3] = 1
    assert_equal(_render(uncompiled_functions(src, rec, Dict[Int, Bool]())), "outer@1-4:1,4")


def test_analyze_lists_uncompiled_functions_and_changes_no_number() raises:
    var files = List[String]()
    files.append("src/p/BUCK")
    files.append("src/p/m.mojo")
    var s = Sources(String(""))
    s.texts[String("src/p/m.mojo")] = String(THREE + "def d():\n    w()  # cov: unreachable why\n")
    var r = List[Input]()
    r.append(Input(String(FORMAT_LCOV), String(""), String("t.info"), String("SF:src/p/m.mojo\nDA:1,1\nDA:2,1\nend_of_record\n")))
    var a = analyze(r, List[Input](), repo_files_of(files), Ratchet(), s, Options())
    # The numbers and findings are those of the same report over a source
    # holding only the compiled function: the list changes none of them.
    var only_a = Sources(String(""))
    only_a.texts[String("src/p/m.mojo")] = String("def a():\n    pass\n")
    var base = analyze(r, List[Input](), repo_files_of(files), Ratchet(), only_a, Options())
    assert_equal(len(base.uncompiled_functions), 0)
    assert_equal(a.packages[0].line_found, 2)
    assert_equal(a.packages[0].line_hit, 2)
    assert_equal(a.packages[0].line_found, base.packages[0].line_found)
    assert_equal(a.packages[0].line_hit, base.packages[0].line_hit)
    assert_equal(_finding_kinds(a), _finding_kinds(base))
    assert_equal(len(a.uncompiled_functions), 3)
    assert_equal(a.uncompiled_functions[0].name, "b")
    assert_equal(a.uncompiled_functions[0].line, 4)
    assert_equal(a.uncompiled_functions[0].lines, 2)
    assert_equal(a.uncompiled_functions[1].name, "c")
    assert_equal(a.uncompiled_functions[1].lines, 3)
    # d's marked line leaves its count.
    assert_equal(a.uncompiled_functions[2].name, "d")
    assert_equal(a.uncompiled_functions[2].lines, 1)
    assert_equal(a.uncompiled_functions[2].package, "src/p")
    var g = parse_json_value(gate_json(a, String("src/p")))
    var u = g.get(String("uncompiled_functions"))
    assert_equal(u.array_len(), 3)
    assert_equal(u.element_at(1).get(String("path")).as_string(), "src/p/m.mojo")
    assert_equal(Int(u.element_at(1).get(String("line")).as_int64()), 7)
    assert_equal(u.element_at(1).get(String("name")).as_string(), "c")
    assert_equal(Int(u.element_at(1).get(String("lines")).as_int64()), 3)
    var rj = parse_json_value(report_json(a, List[String](), DiffCoverage()))
    assert_equal(rj.get(String("uncompiled_functions")).array_len(), 3)


def test_a_marker_without_a_reason_leaves_the_count() raises:
    var files = List[String]()
    files.append("src/p/BUCK")
    files.append("src/p/m.mojo")
    var s = Sources(String(""))
    s.texts[String("src/p/m.mojo")] = String("def a():\n    pass\n\ndef b():\n    x()  # cov: unreachable\n")
    var r = List[Input]()
    r.append(Input(String(FORMAT_LCOV), String(""), String("t.info"), String("SF:src/p/m.mojo\nDA:1,1\nend_of_record\n")))
    var a = analyze(r, List[Input](), repo_files_of(files), Ratchet(), s, Options())
    assert_equal(len(a.uncompiled_functions), 1)
    assert_equal(a.uncompiled_functions[0].lines, 2)


def test_a_file_no_test_compiled_lists_no_function() raises:
    # Its lines are already counted (UnmeasuredFile); listing its functions
    # as well would say the same thing twice.
    var files = List[String]()
    files.append("src/p/BUCK")
    files.append("src/p/m.mojo")
    files.append("src/p/n.mojo")
    var s = Sources(String(""))
    s.texts[String("src/p/m.mojo")] = String("def a():\n    pass\n")
    s.texts[String("src/p/n.mojo")] = String(THREE)
    var r = List[Input]()
    r.append(Input(String(FORMAT_LCOV), String(""), String("t.info"), String("SF:src/p/m.mojo\nDA:1,1\nend_of_record\n")))
    var a = analyze(r, List[Input](), repo_files_of(files), Ratchet(), s, Options())
    assert_equal(len(a.uncompiled_functions), 0)
    assert_true(a.packages[0].unmeasured_files == 1)


def main() raises:
    test_methods_and_functions_with_their_own_lines()
    test_a_trait_requirement_is_not_a_function_a_default_is()
    test_a_body_on_the_signature_line()
    test_a_nested_function_owns_its_lines()
    test_def_in_a_string_or_a_comment_is_not_a_declaration()
    test_a_generic_signature_over_lines_and_brackets_in_a_string()
    test_a_docstring_at_a_lower_indent_does_not_end_the_body()
    test_uncompiled_functions_are_those_with_no_recorded_line()
    test_a_compiled_closure_does_not_make_its_parent_compiled()
    test_analyze_lists_uncompiled_functions_and_changes_no_number()
    test_a_marker_without_a_reason_leaves_the_count()
    test_a_file_no_test_compiled_lists_no_function()
    print("test_decls: PASS")
