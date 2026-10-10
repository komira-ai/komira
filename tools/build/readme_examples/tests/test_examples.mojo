# A README's examples: which fences are examples, the refusals (each naming
# its line), hidden lines, and the shipped-README link refusal.

from std.testing import assert_equal, assert_false, assert_true
from readme_examples.examples import Example, extract_examples, info_refusal


def _refusal(text: String, links: Bool = False) -> String:
    """The refusal message for `text`, or "" when it is accepted."""
    try:
        _ = extract_examples(text, "R.md", links)
    except e:
        return String(e)
    return ""


def _join(ex: Example) -> String:
    var s = String("")
    for i in range(len(ex.code)):
        s += String(ex.code_lines[i]) + "|" + ex.code[i] + "\n"
    return s


def test_only_exactly_mojo_is_an_example() raises:
    var text = String(
        "# T\n```mojo\nprint(1)\n```\n```text\nsketch()\n```\n```\nplain\n```\n"
        + "~~~mojo\nprint(2)\n~~~\n```sh\npixi add x\n```\n"
    )
    var exs = extract_examples(text, "R.md", False)
    assert_equal(len(exs), 2)
    assert_equal(exs[0].line, 2)
    assert_equal(_join(exs[0]), "3|print(1)\n")
    assert_equal(exs[1].line, 11)
    assert_equal(_join(exs[1]), "12|print(2)\n")


def test_no_example_is_an_empty_list() raises:
    assert_equal(len(extract_examples("# T\n\nprose\n```text\nx\n```\n", "R.md", False)), 0)


def test_an_indented_fence_is_dedented_by_its_indent() raises:
    var exs = extract_examples("- item\n\n  ```mojo\n  if True:\n      pass\n  ```\n", "R.md", False)
    assert_equal(_join(exs[0]), "4|if True:\n5|    pass\n")


def test_a_word_after_mojo_is_refused() raises:
    # The vocabulary after `mojo` is closed and holds `module` alone: no skip word.
    assert_equal(
        _refusal("a\n```mojo skip\nx\n```\n"),
        "R.md:2: `mojo skip`: an example's info string is `mojo` or `mojo module`; nothing else may follow `mojo`"
        + " (there is no skip word: fence a sketch that cannot run as ```text)",
    )
    assert_true(_refusal("```mojo ignore\n```\n").startswith("R.md:1: `mojo ignore`"))
    for info in ["mojo module skip", "mojo Module", "mojo modules", "mojo main"]:
        assert_true(_refusal("```" + info + "\n```\n").startswith("R.md:1: `" + info + "`"), info)


def test_the_fence_tag_is_the_mode() raises:
    # `mojo module` is an example in module mode; `mojo` is not, whatever
    # its code declares. Hidden lines attach to either.
    var exs = extract_examples(
        "```mojo\nstruct T:\n    pass\n```\n<!-- mojo-hidden x = 1 -->\n```mojo module\ndef main():\n    pass\n```\n"
        + "~~~mojo  module\n~~~\n",
        "R.md",
        False,
    )
    assert_equal(len(exs), 3)
    assert_false(exs[0].module)
    assert_true(exs[1].module)
    assert_equal(_join(exs[1]), "5|x = 1\n7|def main():\n8|    pass\n")
    assert_true(exs[2].module)
    assert_equal(info_refusal("mojo module"), "")


def test_an_indented_module_fence_keeps_its_mode() raises:
    # The mode comes from the tag alone, wherever the fence sits: a
    # `mojo module` fence inside a list item is a whole program, dedented by
    # the fence's indent like any other example.
    var exs = extract_examples(
        "- item\n\n  ```mojo module\n  def main():\n      pass\n  ```\n", "R.md", False
    )
    assert_equal(len(exs), 1)
    assert_true(exs[0].module)
    assert_equal(_join(exs[0]), "4|def main():\n5|    pass\n")


def test_near_misses_are_refused() raises:
    for w in ["Mojo", "MOJO", "mojo,", ".mojo", "{.mojo}", "\U0001F525", "mojo-example"]:
        var why = info_refusal(w)
        assert_true(why.byte_length() > 0, w)
    assert_equal(info_refusal("mojo"), "")
    assert_equal(info_refusal("text"), "")
    assert_equal(info_refusal("python"), "")
    assert_equal(
        _refusal("x\n\n```Mojo\nprint(1)\n```\n"),
        "R.md:3: `Mojo` is not `mojo`: write ```mojo for an example that runs, or ```text for a sketch",
    )


def test_every_refusal_is_reported_in_line_order() raises:
    var why = _refusal("```mojo skip\n```\n<!-- mojo-hidden x = 1 -->\n\n```Mojo\n```\n")
    var lines = why.split("\n")
    assert_equal(len(lines), 3)
    assert_true(lines[0].startswith("R.md:1: "), why)
    assert_true(lines[1].startswith("R.md:3: a mojo-hidden comment must end"), why)
    assert_true(lines[2].startswith("R.md:5: "), why)


def test_an_unclosed_example_is_refused() raises:
    assert_equal(_refusal("a\n```mojo\nprint(1)\n"), "R.md:2: the ```mojo example is never closed")


def test_hidden_lines_before_and_after() raises:
    var text = String(
        "<!-- mojo-hidden from std.testing import assert_equal -->\n"
        + "```mojo\n"
        + "var x = 2\n"
        + "```\n"
        + "<!-- mojo-hidden\n"
        + "assert_equal(x, 2)\n"
        + "    -->\n"
    )
    var exs = extract_examples(text, "R.md", False)
    assert_equal(len(exs), 1)
    assert_equal(_join(exs[0]), "1|from std.testing import assert_equal\n3|var x = 2\n6|assert_equal(x, 2)\n")


def test_a_hidden_comment_must_touch_an_example() raises:
    assert_equal(
        _refusal("<!-- mojo-hidden x = 1 -->\n\n```mojo\nprint(1)\n```\n"),
        "R.md:1: a mojo-hidden comment must end on the line just before a ```mojo fence"
        + " or start on the line just after its closing fence; this one runs nowhere",
    )
    # Next to a fence that is not an example.
    assert_true(_refusal("<!-- mojo-hidden x = 1 -->\n```text\nx\n```\n").startswith("R.md:1: a mojo-hidden"))


def test_a_misspelled_marker_is_refused() raises:
    assert_equal(
        _refusal("<!-- mojo_hidden x = 1 -->\n```mojo\nprint(1)\n```\n"),
        "R.md:1: `<!-- mojo_hidden`: the hidden-lines marker is exactly `<!-- mojo-hidden`",
    )
    assert_true(_refusal("<!-- Mojo-hidden\nx\n-->\n```mojo\n```\n").startswith("R.md:1: `<!-- Mojo-hidden`"))
    # An ordinary comment is prose.
    assert_equal(_refusal("<!-- a note -->\n```mojo\nprint(1)\n```\n"), "")


def test_an_unclosed_hidden_comment_is_refused() raises:
    assert_true(
        _refusal("<!-- mojo-hidden\nx = 1\n```mojo\n```\n").find("R.md:1: a mojo-hidden comment is never closed") >= 0
    )


def test_a_shipped_readme_refuses_relative_links() raises:
    var text = String("See [api](api.md), [top](#use), [site](https://example.org/x).\n\n```mojo\nprint(1)\n```\n")
    assert_equal(_refusal(text, links=False), "")
    assert_equal(
        _refusal(text, links=True),
        "R.md:1: api.md: a relative link in a README that ships in its package; the installed copy"
        + " has no such file. Link an absolute URL, or an #anchor of this README",
    )


def main() raises:
    test_only_exactly_mojo_is_an_example()
    test_no_example_is_an_empty_list()
    test_an_indented_fence_is_dedented_by_its_indent()
    test_a_word_after_mojo_is_refused()
    test_the_fence_tag_is_the_mode()
    test_an_indented_module_fence_keeps_its_mode()
    test_near_misses_are_refused()
    test_every_refusal_is_reported_in_line_order()
    test_an_unclosed_example_is_refused()
    test_hidden_lines_before_and_after()
    test_a_hidden_comment_must_touch_an_example()
    test_a_misspelled_marker_is_refused()
    test_an_unclosed_hidden_comment_is_refused()
    test_a_shipped_readme_refuses_relative_links()
    print("test_examples: OK")
