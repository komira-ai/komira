from std.testing import assert_equal, assert_true

from mutate.cli import read_text
from mutate.gen import Mutant, apply, generate
from mutate.sample import render_list

# The mutator: a fixture source to its exact mutant list (every operator,
# what is never mutated: comments, strings, docstrings, backtick MLIR text,
# unary minus, `->`, shifts, floats, hex; early returns and where they are
# not made; both markers), then single cases for each rule, and what a
# mutant does to the source.

comptime FIXTURES = "tools/build/coverage/mutate/tests/fixtures/"


def _ids(src: String) raises -> String:
    """The ids and replacements of `src`'s mutants, one per line."""
    var g = generate(String("f.mojo"), src)
    var out = String("")
    for m in g.mutants:
        out += m.id() + " " + m.replacement + "\n"
    return out^


def _find(src: String, id: String) raises -> Mutant:
    var g = generate(String("f.mojo"), src)
    for m in g.mutants:
        if m.id() == id:
            return m.copy()
    raise Error("no mutant " + id + " in:\n" + _ids(src))


def test_fixture_golden() raises:
    var g = generate(String("ops.mojo"), read_text(String(FIXTURES) + "ops.src"))
    var got = render_list(g.mutants, g.suppressed, 0, String("s"))
    assert_equal(got, read_text(String(FIXTURES) + "ops.expected"))


def test_comparisons() raises:
    assert_equal(_ids("a = b <= c\n"), "f.mojo:1:7:cmp_negate >\n")
    assert_equal(_ids("a = b > c\n"), "f.mojo:1:7:cmp_negate <=\n")
    assert_equal(_ids("a = b < c\n"), "f.mojo:1:7:cmp_negate >=\n")
    assert_equal(_ids("a = b >= c\n"), "f.mojo:1:7:cmp_negate <\n")
    assert_equal(_ids("a = b == c\n"), "f.mojo:1:7:cmp_negate !=\n")
    assert_equal(_ids("a = b != c\n"), "f.mojo:1:7:cmp_negate ==\n")
    # shifts, their assignments and the arrow are not comparisons
    assert_equal(_ids("a = b << c\na <<= b\na >>= b\na = b >> c\n"), "")


def test_arithmetic_binary_only() raises:
    assert_equal(_ids("a = b + c\n"), "f.mojo:1:7:arith_swap -\n")
    assert_equal(_ids("a = (b) - c\n"), "f.mojo:1:9:arith_swap +\n")
    assert_equal(_ids("a = x[i] - c\n"), "f.mojo:1:10:arith_swap +\n")
    assert_equal(_ids("a -= b\n"), "f.mojo:1:3:arith_swap +=\n")
    # unary: after an operator, an opening bracket, a keyword, a line start
    assert_equal(_ids("a = -b\n"), "")
    assert_equal(_ids("f(-b, +c)\n"), "")
    assert_equal(_ids("return -b\n"), "")
    assert_equal(_ids("if not -b in c:\n"), "f.mojo:1:4:not_delete \n")
    # a `+` joining strings is not swapped: a string literal or a
    # `String(...)` call before it, a literal or `String` after it; a `-`
    # next to a string still is (it is not a join)
    assert_equal(_ids("a = 'x' + b\na = b + 'x'\na = String(b) + c\na = b + String(c)\na += 'x'\n"), "")
    assert_equal(_ids("a = str(b) + c\n"), "f.mojo:1:12:arith_swap -\n")
    assert_equal(_ids("a = String(b)[0] + c\n"), "f.mojo:1:15:const_inc 1\nf.mojo:1:18:arith_swap -\n")
    assert_equal(_ids("a = 'x' - b\na -= 'x'\n"), "f.mojo:1:9:arith_swap +\nf.mojo:2:3:arith_swap +=\n")


def test_booleans() raises:
    assert_equal(_ids("a = b and c or d\n"), "f.mojo:1:7:bool_swap or\nf.mojo:1:13:bool_swap and\n")
    assert_equal(_ids("a = b not in c\n"), "f.mojo:1:7:not_delete \n")
    # identifiers holding the words are not the words
    assert_equal(_ids("a = band + notx\n"), "f.mojo:1:10:arith_swap -\n")


def test_constants() raises:
    assert_equal(_ids("a = 0\n"), "f.mojo:1:5:const_inc 1\n")
    assert_equal(_ids("a = 7\n"), "f.mojo:1:5:const_inc 8\nf.mojo:1:5:const_dec 6\n")
    assert_equal(_ids("a = 999999999999999999\n"), "f.mojo:1:5:const_inc 1000000000000000000\nf.mojo:1:5:const_dec 999999999999999998\n")
    # more than 18 digits, floats, exponents, hex, binary, separators, digits in names
    assert_equal(_ids("a = 1000000000000000000\n"), "")
    assert_equal(_ids("a = 1.5\na = 2e10\na = 1e-5\na = 0xFF\na = 0b11\na = 1_000\na = UInt8\n"), "")


def test_strings_and_comments_are_not_code() raises:
    var src = String(
        "a = 'b < c'\n"
        + "a = \"b + 1\"\n"
        + "a = \"\"\"x == y\n  and 2\"\"\"\n"
        + "a = '''or\n1'''\n"
        + "a = rb'x - 3'\n"
        + "a = f\"{x > 1}\"\n"
        + "a = `!x<y> + 1`\n"
        + "a = 'esc \\' + 1'\n"
        + "# a < b and 1\n"
    )
    assert_equal(_ids(src), "")
    # an unterminated one-line string ends at its line
    assert_equal(_ids("a = 'b\nc = d < e\n"), "f.mojo:2:7:cmp_negate >=\n")
    # code after a string on the same line is code
    assert_equal(_ids("a = 'b' if c else d < e\n"), "f.mojo:1:21:cmp_negate >=\n")


def test_raise_delete_extent() raises:
    var src = String("def f(x: Int) raises -> Int:\n    if x: raise Error('a')  # why\n    raise Error(\n        'b'\n    ); x = 1\n")
    var one = _find(src, "f.mojo:2:11:raise_delete")
    assert_equal(apply(src, one), "def f(x: Int) raises -> Int:\n    if x: pass  # why\n    raise Error(\n        'b'\n    ); x = 1\n")
    var multi = _find(src, "f.mojo:3:5:raise_delete")
    assert_equal(apply(src, multi), "def f(x: Int) raises -> Int:\n    if x: raise Error('a')  # why\n    pass; x = 1\n")
    # `raises` and a `raise` that does not start a statement are not deleted
    assert_equal(_ids("def f() raises:\n    x = raise_it\n"), "f.mojo:2:5:return_early return\n    \n")


def test_early_returns() raises:
    var src = String("def f(mut a: Int):\n    \"\"\"Doc.\"\"\"\n\n    # note\n    a = b\n")
    var m = _find(src, "f.mojo:5:5:return_early")
    assert_equal(apply(src, m), "def f(mut a: Int):\n    \"\"\"Doc.\"\"\"\n\n    # note\n    return\n    a = b\n")
    var b = String("    def g[T: X](self, x: T) raises -> Bool:\n        return x.ok()\n")
    assert_equal(_ids(b), "f.mojo:2:9:return_true return True\n        \nf.mojo:2:9:return_false return False\n        \n")
    # `-> None` is no value
    assert_equal(_ids("def f() -> None:\n    g()\n"), "f.mojo:2:5:return_early return\n    \n")
    # not made: a constructor, another return type, a one-line body, `pass`,
    # `...`, a body that already is the inserted statement
    assert_equal(_ids("def __init__(out self):\n    g()\n"), "")
    assert_equal(_ids("def f() -> Int:\n    g()\n"), "")
    assert_equal(_ids("def f(): g()\n"), "")
    assert_equal(_ids("def f():\n    pass\n"), "")
    assert_equal(_ids("def f() -> Bool:\n    ...\n"), "")
    assert_equal(_ids("def f() -> Bool:\n    return True\n"), "f.mojo:2:5:return_false return False\n    \n")
    assert_equal(_ids("def f():\n    return\n"), "")


def test_markers() raises:
    var g = generate(String("f.mojo"), String("a = b < 1  # mutation: equivalent cmp_negate,const_dec b is 0 or 1\n"))
    assert_equal(len(g.mutants), 1)
    assert_equal(g.mutants[0].id(), "f.mojo:1:9:const_inc")
    assert_equal(len(g.suppressed), 2)
    assert_equal(g.suppressed[0].id, "f.mojo:1:7:cmp_negate")
    assert_equal(g.suppressed[0].kind, "equivalent")
    assert_equal(g.suppressed[0].reason, "b is 0 or 1")
    assert_equal(g.suppressed[1].id, "f.mojo:1:9:const_dec")
    # a marker reaches its own line only
    var h = generate(String("f.mojo"), String("# cov: unreachable why\na = b < c\n"))
    assert_equal(len(h.mutants), 1)
    var bad = List[String]()
    bad.append("a = 1  # mutation: equivalent cmp_negate\n")
    bad.append("a = 1  # mutation: equivalent cmp_negat why\n")
    bad.append("a = 1  # mutation: equivalent\n")
    bad.append("a = 1  # mutation: equivalent \n")
    bad.append("a = 1  # mutation: equivalnt cmp_negate why\n")
    for i in range(len(bad)):
        var refused = False
        try:
            _ = generate(String("f.mojo"), bad[i])
        except e:
            refused = String(e).startswith("f.mojo:1: ")
        assert_true(refused, bad[i])


def test_path_refusals() raises:
    for p in [":x.mojo", "a\tb.mojo", ""]:
        var refused = False
        try:
            _ = generate(String(p), String("a = 1\n"))
        except:
            refused = True
        assert_true(refused, String(p))


def test_apply_changes_only_the_span() raises:
    var src = String("x = a + 10\n")
    var g = generate(String("f.mojo"), src)
    assert_equal(len(g.mutants), 3)
    assert_equal(apply(src, g.mutants[0]), "x = a - 10\n")
    assert_equal(apply(src, g.mutants[1]), "x = a + 11\n")
    assert_equal(apply(src, g.mutants[2]), "x = a + 9\n")


def main() raises:
    test_fixture_golden()
    test_comparisons()
    test_arithmetic_binary_only()
    test_booleans()
    test_constants()
    test_strings_and_comments_are_not_code()
    test_raise_delete_extent()
    test_early_returns()
    test_markers()
    test_path_refusals()
    test_apply_changes_only_the_span()
    print("test_gen: PASS")
