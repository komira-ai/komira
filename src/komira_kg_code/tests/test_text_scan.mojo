# The line scans: which lines are imports, where a declaration's header
# starts, and what a document's front matter says.
from std.testing import assert_equal, assert_true

from komira_kg_code import declaration_line, imported_modules, read_front_matter
from komira_kg_code.text_scan import split_lines


def test_imports_of_each_form() raises:
    var src = String(
        "from a.b import c\n"
        "import d\n"
        "import e.f as g, h\n"
        "from .rel import x\n"
        "from komira_x import (\n"
        "    One,\n"
        "    Two,\n"
        ")\n"
        "def f():\n"
        "    from inner import y\n"
        "# from commented import z\n"
        "fromage = 1\n"
        "important = 2\n"
    )
    var m = imported_modules(src)
    assert_equal(len(m), 7)
    assert_equal(m[0], "a.b")
    assert_equal(m[1], "d")
    assert_equal(m[2], "e.f")
    assert_equal(m[3], "h")
    assert_equal(m[4], ".rel")
    assert_equal(m[5], "komira_x")
    assert_equal(m[6], "inner")


def test_an_import_shown_in_a_docstring_is_not_an_import() raises:
    var src = String(
        '"""How to use it:\n'
        "\n"
        "from shown import Example\n"
        '"""\n'
        "from real import Thing\n"
        'comptime X = 1\n"""One line, from x import y."""\n'
    )
    var m = imported_modules(src)
    assert_equal(len(m), 1)
    assert_equal(m[0], "real")


def test_a_header_spanning_lines_starts_on_its_keyword_line() raises:
    var lines = split_lines(
        "comptime N = 4\n"
        "struct Grid[\n"
        "    width: Int,\n"
        "](Shaped):\n"
        "    def area(self) -> Int:\n"
        "        return 0\n"
        "struct GridView:\n"
        "    pass\n"
        "def grid() -> Int:\n"
        "    return 1\n"
    )
    assert_equal(declaration_line(lines, "comptime", "N", 0, 0), 1)
    assert_equal(declaration_line(lines, "struct", "Grid", 0, 0), 2)
    assert_equal(declaration_line(lines, "struct", "GridView", 0, 0), 7)
    assert_equal(declaration_line(lines, "def", "grid", 0, 0), 9)
    assert_equal(declaration_line(lines, "def", "area", 4, 2), 5)
    assert_equal(declaration_line(lines, "def", "missing", 0, 0), 0)


def test_a_method_is_looked_for_in_its_own_struct_only() raises:
    # A's `__init__` is synthesized (no header in A); B's is written. The
    # line of A.__init__ is unknown, not B's.
    var lines = split_lines(
        "@fieldwise_init\n"
        "struct A:\n"
        "    var x: Int\n"
        "\n"
        "struct B:\n"
        "    def __init__(out self):\n"
        "        pass\n"
    )
    assert_equal(declaration_line(lines, "def", "__init__", 4, 2), 0)
    assert_equal(declaration_line(lines, "def", "__init__", 4, 5), 6)


def test_front_matter_block_and_inline_lists() raises:
    var block = read_front_matter(
        "a.md",
        "---\ntitle: \"The A\"\ngoverns:\n  - //src/x:x\n  - 'src/x/y.mojo'\nowner: me\n---\n# Heading\n",
    )
    assert_equal(block.title, "The A")
    assert_equal(len(block.governs), 2)
    assert_equal(block.governs[0], "//src/x:x")
    assert_equal(block.governs[1], "src/x/y.mojo")
    var inline = read_front_matter("b.md", "---\ngoverns: [//src/a:a, src/b.mojo]\n---\n")
    assert_equal(inline.title, "")
    assert_equal(len(inline.governs), 2)
    assert_equal(inline.governs[0], "//src/a:a")
    assert_equal(inline.governs[1], "src/b.mojo")
    var none = read_front_matter("c.md", "# Title\ngoverns: [x]\n")
    assert_equal(len(none.governs), 0)


def test_unclosed_front_matter_is_refused() raises:
    var msg = String("")
    try:
        _ = read_front_matter("docs/open.md", "---\ngoverns: [x]\n# body\n")
    except e:
        msg = String(e)
    assert_equal(msg, "komira_kg_code: docs/open.md: the front matter opened on line 1 is not closed by a `---` line")


def test_a_last_line_without_a_newline_is_a_line() raises:
    var l = split_lines("a\r\nb")
    assert_equal(len(l), 2)
    assert_equal(l[0], "a")
    assert_equal(l[1], "b")


def test_an_import_with_no_module_name_gives_none() raises:
    # `import (x)`: no dotted name follows, so no module, not an empty one.
    var m = imported_modules("import (x)\nimport ok\n")
    assert_equal(len(m), 1)
    assert_equal(m[0], "ok")


def test_a_header_ending_its_line_after_the_name() raises:
    var lines = split_lines("x = 1\nstruct Bare\n")
    assert_equal(declaration_line(lines, "struct", "Bare", 0, 0), 2)


def test_front_matter_blank_lines_scalars_and_trailing_spaces() raises:
    # A blank indented line inside a governs list keeps the list open; a
    # value's trailing spaces are not part of it.
    var block = read_front_matter("a.md", "---\ntitle: The A  \ngoverns:\n  - one\n  \n  - two\n---\n")
    assert_equal(block.title, "The A")
    assert_equal(len(block.governs), 2)
    assert_equal(block.governs[0], "one")
    assert_equal(block.governs[1], "two")
    # `governs: <entry>` with no brackets is one entry.
    var scalar = read_front_matter("b.md", "---\ngoverns: '//src/a:a'\n---\n")
    assert_equal(len(scalar.governs), 1)
    assert_equal(scalar.governs[0], "//src/a:a")


def main() raises:
    test_imports_of_each_form()
    test_an_import_shown_in_a_docstring_is_not_an_import()
    test_a_header_spanning_lines_starts_on_its_keyword_line()
    test_a_method_is_looked_for_in_its_own_struct_only()
    test_front_matter_block_and_inline_lists()
    test_unclosed_front_matter_is_refused()
    test_a_last_line_without_a_newline_is_a_line()
    test_an_import_with_no_module_name_gives_none()
    test_a_header_ending_its_line_after_the_name()
    test_front_matter_blank_lines_scalars_and_trailing_spaces()
    print("OK")
