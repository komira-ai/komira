from std.testing import assert_equal, assert_true

from covcheck.exempt import marker_in, scan_markers
from covcheck.lexer import LexState, executable_lines, lex_line, lex_source
from covcheck.text import join

# The source lexer behind exemption markers and the executable-line
# heuristic: a marker inside a string literal, a docstring or after another
# comment's text is not one; a real marker after a string holding `#` is;
# CRLF lines; and which lines are executable, over every kind of line.


def test_marker_inside_a_string_or_another_comment_is_not_a_marker() raises:
    var cases = List[String]()
    cases.append("s = \"x # cov: unreachable why\"")
    cases.append("s = 'it\\'s # cov: unreachable why'")
    cases.append("s = r\"\\\" # cov: unreachable why\"")
    cases.append("    \"\"\"Doc # cov: unreachable why.\"\"\"")
    cases.append("x()  # see # cov: unreachable why")
    var wrong = List[String]()
    for i in range(len(cases)):
        if marker_in(cases[i]).found:
            wrong.append(cases[i])
    assert_equal(len(wrong), 0, String("read as markers: ") + join(wrong, String(" || ")))


def test_marker_in_a_multi_line_docstring_is_not_a_marker() raises:
    var ms = scan_markers(String("p.mojo"), String(
        "def f():\n"
        "    \"\"\"Doc.\n"
        "\n"
        "    x = 1 # cov: unreachable inside the docstring\n"
        "    \"\"\"\n"
        "    g()  # cov: unreachable real\n"
    ))
    assert_equal(len(ms), 1)
    assert_equal(ms[0].line, 6)
    assert_equal(ms[0].reason, "real")


def test_hash_in_a_string_before_a_real_marker() raises:
    var m = marker_in(String("s = \"#\"  # cov: unreachable why"))
    assert_true(m.found)
    assert_equal(m.reason, "why")
    # An escaped quote does not end the string early; the marker after it is real.
    var e = marker_in(String("s = \"a\\\"#\"  # cov: unreachable why"))
    assert_true(e.found)
    assert_equal(e.reason, "why")


def test_crlf_line_with_a_marker() raises:
    var m = marker_in(String("x()  # cov: unreachable why\r"))
    assert_true(m.found)
    assert_equal(m.reason, "why")
    var ms = scan_markers(String("p.mojo"), String("a\r\nb  # cov: unreachable r\r\n"))
    assert_equal(len(ms), 1)
    assert_equal(ms[0].line, 2)
    assert_equal(ms[0].reason, "r")


def test_the_lexer_finds_the_first_comment_outside_strings() raises:
    var st = LexState()
    assert_equal(lex_line(String("a = '#' + \"#\"  # c"), st).comment, 15)
    assert_equal(st.quote, 0)
    # A triple-quoted string left open carries to the next line.
    var l = lex_line(String("x = '''a # b"), st)
    assert_equal(l.comment, -1)
    assert_true(l.code)
    assert_equal(st.quote, 39)
    assert_true(st.triple)
    var inner = lex_line(String("still # inside"), st)
    assert_equal(inner.comment, -1)
    assert_true(not inner.code)
    var close = lex_line(String("end''' # c"), st)
    assert_equal(close.comment, 7)
    assert_true(not close.code)
    assert_equal(st.quote, 0)
    # A one-line string ending its line with a backslash continues.
    _ = lex_line(String("s = \"abc\\"), st)
    assert_equal(st.quote, 34)
    var cont = lex_line(String("# not a comment\"  # real"), st)
    assert_equal(cont.comment, 18)
    # A one-line string left open (no backslash) ends with its line.
    _ = lex_line(String("s = \"abc"), st)
    assert_equal(st.quote, 0)


# Every kind of line, each marked with whether it is executable.
comptime KINDS = (
    "\"\"\"Module docstring on one line.\"\"\"\n"      # 1 no: docstring
    "\n"                                               # 2 no: blank
    "\"\"\"A docstring\n"                              # 3 no: docstring block
    "over # several\n"                                 # 4 no
    "lines.\"\"\"\n"                                   # 5 no
    "import os\n"                                      # 6 no: import
    "from std.os import abort\n"                       # 7 no: import
    "from covcheck.text import (\n"                    # 8 no: parenthesised import
    "    join,  # a comment\n"                         # 9 no
    "    split_on,\n"                                  # 10 no
    ")\n"                                              # 11 no
    "    \t\n"                                         # 12 no: blank (spaces and a tab)
    "# a comment\n"                                    # 13 no: comment only
    "    # an indented comment\n"                      # 14 no
    "def f(x: Int) -> Int:\n"                          # 15 yes
    "    var s = \"a # b\"\n"                          # 16 yes
    "    var t = '''\n"                                # 17 yes: code, then a string opens
    "    import inside a string\n"                     # 18 no: inside the string
    "    '''\n"                                        # 19 no: closes it
    "    return x  # cov: unreachable why\n"           # 20 yes
    "    r\"\"\"raw docstring\"\"\"\n"                 # 21 no: a prefixed string only
    "    \"one\"\n"                                    # 22 no: a string only
    "fromage = 1\n"                                    # 23 yes: not the keyword `from`
    "important()\n"                                    # 24 yes: not the keyword `import`
    "from x import a, \\\n"                            # 25 no: import continued by a backslash
    "    b\n"                                          # 26 no
    "y = 2\n"                                          # 27 yes: the import ended
)


def test_executable_lines_over_every_kind_of_line() raises:
    var got = executable_lines(String(KINDS))
    var s = String("")
    for i in range(len(got)):
        if i > 0:
            s += String(",")
        s += String(got[i])
    assert_equal(s, "15,16,17,20,23,24,27")
    # The same over CRLF line ends.
    var crlf = String(KINDS).replace("\n", "\r\n")
    assert_equal(len(executable_lines(crlf)), 7)


def test_an_init_of_reexports_has_no_executable_line() raises:
    var init = String(
        "\"\"\"Package p.\n"
        "\n"
        "Re-exports.\n"
        "\"\"\"\n"
        "\n"
        "from .a import f\n"
        "from .b import (\n"
        "    g,\n"
        "    h,\n"
        ")\n"
    )
    assert_equal(len(executable_lines(init)), 0)
    var ls = lex_source(init)
    assert_true(ls[8].is_import)


def _nums(got: List[Int]) -> String:
    var s = String("")
    for i in range(len(got)):
        if i > 0:
            s += String(",")
        s += String(got[i])
    return s^


def test_a_byte_order_mark_is_not_code() raises:
    # A UTF-8 byte-order mark (EF BB BF) before line 1 is not part of it.
    var bom = chr(0xFEFF)
    assert_equal(bom.byte_length(), 3)
    assert_equal(_nums(executable_lines(bom + String("\"\"\"Doc.\"\"\"\nfrom .a import f\n"))), "")
    assert_equal(_nums(executable_lines(bom + String("import x\n"))), "")
    assert_equal(_nums(executable_lines(bom + String("x = 1\n"))), "1")
    # Only at the start of the file.
    assert_equal(_nums(executable_lines(String("import x\n") + bom + String("\n"))), "2")
    # The marker on a BOM line is found at the same offset as without it.
    var ms = scan_markers(String("p.mojo"), bom + String("x()  # cov: unreachable r\n"))
    assert_equal(len(ms), 1)
    assert_equal(ms[0].reason, "r")


def test_a_lone_quote_does_not_close_a_triple_quoted_string() raises:
    # Only three quotes close a triple-quoted string: a quoted word, `""`
    # and the other kind of quote inside a docstring leave it open, so its
    # next line is still string (no code, no comment, no marker).
    var src = String(
        "def f():\n"                                             # 1 code
        "    \"\"\"Doc with a \"quoted\" word, \"\" and ''.\n"   # 2 docstring
        "    # cov: unreachable not a marker\n"                  # 3 docstring
        "    \"\"\"\n"                                           # 4 closes it
        "    return 1\n"                                         # 5 code
    )
    assert_equal(_nums(executable_lines(src)), "1,5")
    assert_equal(len(scan_markers(String("p.mojo"), src)), 0)


def test_a_semicolon_ends_an_import() raises:
    # Code after `;` on an import line is executable; another import after
    # it is not; a `;` in a comment or string changes nothing; parentheses
    # after the `;` do not continue the import.
    assert_equal(_nums(executable_lines(String("import os; os.abort()\n"))), "1")
    assert_equal(_nums(executable_lines(String("import a; import b\n"))), "")
    assert_equal(_nums(executable_lines(String("import a; from b import c; d()\n"))), "1")
    assert_equal(_nums(executable_lines(String("import a;\nimport b;  # c; d()\n"))), "")
    assert_equal(_nums(executable_lines(String("from x import y  # a; b()\n"))), "")
    assert_equal(_nums(executable_lines(String("from x import (\n    a,\n    b); f()\n"))), "3")
    assert_equal(_nums(executable_lines(String("from x import y; z = (\n    1)\nimport w\n"))), "1,2")
    assert_equal(_nums(executable_lines(String("import a; s = ';'\n"))), "1")


def test_trait_requirements_are_not_executable() raises:
    # A trait's header and its requirements (a `def` whose body is only
    # `...`, after an optional docstring; decorators and every signature
    # line included) emit no code. A default body, a `...` body outside a
    # trait and the code after the trait block stay counted.
    var src = String(
        "trait T(Movable,\n"                                       # 1 header
        "        Copyable):\n"                                     # 2 header
        "    \"\"\"Doc.\"\"\"\n"                                  # 3 docstring
        "\n"                                                       # 4
        "    def f(self) raises:\n"                                # 5 requirement
        "        ...\n"                                            # 6 requirement
        "\n"                                                       # 7
        "    @staticmethod\n"                                      # 8 decorator
        "    def g[\n"                                             # 9 requirement
        "        X: AnyType,\n"                                    # 10 signature
        "    ](a: List[Int] = \"[\") -> String:\n"                 # 11 signature
        "        \"\"\"Doc.\n"                                     # 12 docstring
        "        ... not code\"\"\"\n"                              # 13 docstring
        "        ...\n"                                            # 14 requirement
        "\n"                                                       # 15
        "    def h(self): ...\n"                                   # 16 inline
        "    def d(self) -> Int:\n"                                # 17 default
        "        return 1\n"                                       # 18 default body
        "    # a comment at member indent\n"                       # 19
        "# a comment at column 0 inside the trait\n"              # 20
        "    def e(self):\n"                                       # 21 requirement
        "        ...  # trailing comment\n"                        # 22
        "\n"                                                       # 23
        "def free():\n"                                            # 24 not a trait
        "    ...\n"                                                # 25
        "struct S:\n"                                              # 26
        "    def m(self):\n"                                       # 27
        "        ...\n"                                            # 28
        "trait_count = 1\n"                                        # 29 not a keyword
    )
    assert_equal(_nums(executable_lines(src)), "17,18,24,25,26,27,28,29")
    # A trait made only of requirements leaves nothing counted.
    var only = String(
        "from a import B\n"
        "\n"
        "trait R(B):\n"
        "    def r[T: AnyType](mut self, x: T) raises -> Int:\n"
        "        ...\n"
    )
    assert_equal(_nums(executable_lines(only)), "")


def main() raises:
    test_marker_inside_a_string_or_another_comment_is_not_a_marker()
    test_marker_in_a_multi_line_docstring_is_not_a_marker()
    test_hash_in_a_string_before_a_real_marker()
    test_crlf_line_with_a_marker()
    test_the_lexer_finds_the_first_comment_outside_strings()
    test_executable_lines_over_every_kind_of_line()
    test_an_init_of_reexports_has_no_executable_line()
    test_a_byte_order_mark_is_not_code()
    test_a_lone_quote_does_not_close_a_triple_quoted_string()
    test_a_semicolon_ends_an_import()
    test_trait_requirements_are_not_executable()
    print("test_lexer: PASS")
