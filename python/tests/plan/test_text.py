"""The text rules `.str` and komira.pl's `str` share (komira/_text.py), with no
library. Checked:

- `PYTHON_WHITESPACE` is exactly the characters `str.isspace()` is true of,
  every one once, and `UNICODE_WHITE_SPACE` exactly the Unicode White_Space
  characters (Python's whitespace without U+001C to U+001F, which Unicode does
  not count), so a strip with no argument trims what Python and polars trim;
- `trim` builds the engine's character-set trim of each side;
- `escape` puts a backslash before each character the engine's patterns read
  as syntax and before no other, so `\\d` stays a backslash and a `d`;
- `polars_replacement` reads `$$`, `$n`, `${n}`, a `$` that starts no group,
  a group the pattern does not have (''), `$0` and a backslash as polars does,
  and refuses a named group, a group past 9 and a pattern whose groups
  cannot be counted, each by its full message, and reads a digit outside
  ASCII as no group number;
- `matches_empty` is true of exactly the patterns that match the empty string.

    test_text.py
"""

import sys

from komira import _text
from komira._errors import UnsupportedOperation
from komira._ops import ColRef, Lit, StringFnN

# Unicode's PropList.txt, White_Space: 0009..000D, 0020, 0085, 00A0, 1680,
# 2000..200A, 2028, 2029, 202F, 205F, 3000.
WHITE_SPACE_CODE_POINTS = (
    list(range(0x09, 0x0E)) + [0x20, 0x85, 0xA0, 0x1680] + list(range(0x2000, 0x200B))
    + [0x2028, 0x2029, 0x202F, 0x205F, 0x3000]
)


def raised(call):
    try:
        call()
    except Exception as e:  # each caller checks the exact type
        return e
    raise AssertionError("the call raised nothing")


def refuses(call, cls, message):
    e = raised(call)
    assert type(e) is cls and e.args[0] == message, repr(e)


def test_python_whitespace_is_what_str_isspace_is_true_of():
    want = sorted(chr(c) for c in range(sys.maxunicode + 1) if chr(c).isspace())
    assert sorted(_text.PYTHON_WHITESPACE) == want
    assert len(set(_text.PYTHON_WHITESPACE)) == len(_text.PYTHON_WHITESPACE) == 29
    assert "".join(want).strip() == ""
    assert " \t\n\xa0x　\x1c".strip() == "x"


def test_unicode_white_space_is_the_white_space_property_and_python_whitespace_without_the_separators():
    assert sorted(_text.UNICODE_WHITE_SPACE) == [chr(c) for c in WHITE_SPACE_CODE_POINTS]
    assert len(set(_text.UNICODE_WHITE_SPACE)) == len(_text.UNICODE_WHITE_SPACE) == 25
    assert set(_text.PYTHON_WHITESPACE) - set(_text.UNICODE_WHITE_SPACE) == {"\x1c", "\x1d", "\x1e", "\x1f"}
    assert "​" not in _text.PYTHON_WHITESPACE  # a zero-width space is no whitespace to either


def test_trim_builds_the_engine_character_set_trim_of_each_side():
    s = ColRef("s")
    assert _text.trim(s, "xy", "both") == StringFnN("trim", (s, Lit("xy")))
    assert _text.trim(s, "xy", "left") == StringFnN("ltrim", (s, Lit("xy")))
    assert _text.trim(s, "", "right") == StringFnN("rtrim", (s, Lit("")))


def test_escape_puts_a_backslash_before_each_character_of_syntax_and_no_other():
    assert _text.escape("a.b") == "a\\.b"
    assert _text.escape("\\.^$|?*+()[]{}") == "\\\\\\.\\^\\$\\|\\?\\*\\+\\(\\)\\[\\]\\{\\}"
    assert _text.escape("\\d") == "\\\\d"
    assert _text.escape("été -/#,<>:=!") == "été -/#,<>:=!"
    assert _text.escape("") == ""


def test_matches_empty_is_true_of_a_pattern_that_matches_the_empty_string_and_no_other():
    for pattern in ("", "x*", "a?", "a|", "^", "$", "(b)*", "[0-9]{0,2}"):
        assert _text.matches_empty(pattern), pattern
    for pattern in ("a", "x+", "[0-9]", "\\$", "a|b", "\\b"):
        assert not _text.matches_empty(pattern), pattern
    # a pattern Python's re cannot read is left to the engine
    assert not _text.matches_empty("(a")


def test_polars_replacement_reads_dollars_as_polars_and_a_backslash_as_itself():
    two = "(a)(b)"
    read = lambda value, pattern=two: _text.polars_replacement(value, pattern, "str.replace")
    assert read("plain") == "plain"
    assert read("") == ""
    assert read("$1") == "\\1"
    assert read("${2}x") == "\\2x"
    assert read("$2$1") == "\\2\\1"
    assert read("$0") == "\\0"
    assert read("$01") == "\\1"
    assert read("$$1") == "$1"
    assert read("$$") == "$"
    assert read("a$") == "a$"
    assert read("$ x") == "$ x"
    assert read("$-") == "$-"
    assert read("${") == "${"
    assert read("${}") == "${}"
    assert read("${1") == "${1"
    assert read("\\") == "\\\\"
    assert read("\\1") == "\\\\1"
    # a group the pattern does not have gives '', as polars' regex crate does
    assert read("<$3>") == "<>"
    assert read("<$1>", "a") == "<>"
    assert read("<${9}>", "a") == "<>"


def test_polars_replacement_refusals_by_message():
    refuses(
        lambda: _text.polars_replacement("$name", "(?P<name>a)", "str.replace"),
        UnsupportedOperation,
        "str.replace: the value refers to the group named 'name', and the engine refers to a group by its "
        "number only: write $1 for the first group",
    )
    refuses(
        lambda: _text.polars_replacement("$1a", "(a)", "str.replace_all"),
        UnsupportedOperation,
        "str.replace_all: the value refers to the group named '1a', and the engine refers to a group by its "
        "number only: write $1 for the first group",
    )
    refuses(
        lambda: _text.polars_replacement("${10}", "(a)", "str.replace"),
        UnsupportedOperation,
        "str.replace: the value refers to group 10, and the engine refers to groups 0 to 9 only",
    )
    e = raised(lambda: _text.polars_replacement("$1", "(a", "str.replace"))
    assert type(e) is UnsupportedOperation and e.__cause__ is None, repr(e)
    assert e.args[0] == (
        "str.replace: the groups of the pattern '(a' cannot be counted (missing ), unterminated subpattern at "
        "position 0), and the value refers to one; write the value without $"
    ), e.args[0]
    # a digit outside ASCII is no group number: polars reads `${²}` as a name
    for name in ("²", "٣"):
        refuses(
            lambda name=name: _text.polars_replacement("${" + name + "}", "(a)", "str.replace"),
            UnsupportedOperation,
            f"str.replace: the value refers to the group named {name!r}, and the engine refers to a group by its "
            "number only: write $1 for the first group",
        )
    # with no group referred to, the pattern is not read
    assert _text.polars_replacement("$$x", "(a", "str.replace") == "$x"


def main():
    tests = [(n, f) for n, f in sorted(globals().items()) if n.startswith("test_") and callable(f)]
    for _, f in tests:
        f()
    print("text: {} tests".format(len(tests)))


if __name__ == "__main__":
    main()
