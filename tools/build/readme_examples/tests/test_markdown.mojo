# The CommonMark fence reader and the link reader: what is code, and which
# links are relative.

from std.testing import assert_equal, assert_false, assert_true
from readme_examples.markdown import code_mask, fences, relative_links
from readme_examples.text import split_lines


def _mask(text: String) -> String:
    """One character per line: C for code, . for prose."""
    var m = code_mask(split_lines(text))
    var s = String("")
    for i in range(len(m)):
        s += "C" if m[i] else "."
    return s


def test_a_fence_closes_only_on_its_own_character() raises:
    # A ~~~ block quoting ``` is ONE block: the ``` lines inside it neither
    # open nor close anything. (A reader toggling on every fence line sees
    # the link line as prose.)
    assert_equal(_mask("a\n~~~\n```\n[x](missing.md)\n```\n~~~\nb\n"), ".CCCCC.")
    assert_equal(_mask("```\n~~~\n```\n[y](y.md)\n"), "CCC.")


def test_a_closing_fence_is_at_least_as_long() raises:
    assert_equal(_mask("````\n```\nx\n````\nz\n"), "CCCC.")
    assert_equal(_mask("```\nx\n`````\nz\n"), "CCC.")


def test_a_closing_fence_has_no_info_string() raises:
    # "```mojo" inside an open ``` block is content, not its end.
    assert_equal(_mask("```\n```mojo\nx\n```\ny\n"), "CCCC.")


def test_a_backtick_info_string_holds_no_backtick() raises:
    # "``` a`b" is not a fence (CommonMark), so it opens nothing.
    assert_equal(_mask("``` a`b\nx\n"), "..")
    assert_equal(_mask("~~~ a`b\nx\n~~~\n"), "CCC")


def test_two_characters_are_not_a_fence() raises:
    assert_equal(_mask("``\nx\n``\n"), "...")


def test_an_open_fence_runs_to_the_end() raises:
    assert_equal(_mask("a\n```\nb\nc\n"), ".CCC")
    var fs = fences(split_lines("a\n```mojo\nb\n"))
    assert_equal(len(fs), 1)
    assert_equal(fs[0].close_line, -1)


def test_fence_fields() raises:
    var fs = fences(split_lines("x\n  ~~~~ mojo  \n  y\n  ~~~~\n"))
    assert_equal(len(fs), 1)
    assert_equal(fs[0].open_line, 1)
    assert_equal(fs[0].close_line, 3)
    assert_equal(fs[0].indent, 2)
    assert_equal(fs[0].char, 126)
    assert_equal(fs[0].length, 4)
    assert_equal(fs[0].info, "mojo")


def test_relative_links_skip_code_and_urls() raises:
    var text = String(
        "[a](a.md) and `[b](b.md)` and [c](https://x.org/c) and [d](#top)\n"
        + "~~~\n```\n[e](e.md)\n```\n~~~\n"
        + "[ref]: <f.md>\n"
        + "![img](//cdn/x.png) [g](g.md#h)\n"
    )
    var links = relative_links(split_lines(text))
    assert_equal(len(links), 4)
    assert_equal(links[0].target, "a.md")
    assert_equal(links[0].line, 0)
    assert_equal(links[1].target, "#top")
    assert_equal(links[2].target, "f.md")
    assert_equal(links[2].line, 6)
    assert_equal(links[3].target, "g.md#h")
    assert_equal(links[3].line, 7)


def test_relative_links_skip_html_comments() raises:
    # An HTML block that opens with `<!--` is raw HTML up to the line holding
    # `-->` (CommonMark), never Markdown: a README's mojo-hidden code such as
    # `Span[UInt8](bytes)` is no link. A link after the comment still counts.
    var text = String(
        "<!-- mojo-hidden\nvar s = Span[UInt8](bytes)\n-->\n"
        + "<!-- one line [x](gone.md) -->\n"
        + "  <!-- indented [y](gone2.md)\n -->\n"
        + "after [z](kept.md)\n"
    )
    var links = relative_links(split_lines(text))
    assert_equal(len(links), 1)
    assert_equal(links[0].target, "kept.md")
    assert_equal(links[0].line, 6)


def main() raises:
    test_a_fence_closes_only_on_its_own_character()
    test_a_closing_fence_is_at_least_as_long()
    test_a_closing_fence_has_no_info_string()
    test_a_backtick_info_string_holds_no_backtick()
    test_two_characters_are_not_a_fence()
    test_an_open_fence_runs_to_the_end()
    test_fence_fields()
    test_relative_links_skip_code_and_urls()
    test_relative_links_skip_html_comments()
    print("test_markdown: OK")
