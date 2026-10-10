"""The examples of a README. Pure: no I/O.

A fenced block whose info string is `mojo` or `mojo module` is an EXAMPLE,
and every example runs: there is no skip word. A sketch that cannot run is
fenced ```text. The info string is the example's mode, and nothing else is:
`mojo` (statements, pasted into a `main`) or `mojo module` (a whole program
with its own `main`; program.mojo). The vocabulary after `mojo` is closed
and holds `module` alone, so `mojo skip` (or any other word after `mojo`)
is refused, and so is a near miss of the language word (`Mojo`, `mojo,`,
`.mojo`, `🔥`): a typo can never turn an example into prose that silently
does not run.

Hidden lines: an HTML comment `<!-- mojo-hidden ... -->` that ends on the
line just before an example's opening fence is prepended to it; one that
starts on the line just after its closing fence is appended. Either a whole
comment on one line (`<!-- mojo-hidden assert_equal(x, 1) -->`) or the
opening on its own line, code lines, and `-->` on the last. GitHub does not
render an HTML comment, so the page shows the example clean; every raw view
shows the hidden lines. A `mojo-hidden` comment next to no example, and a
comment that spells the marker differently (`mojo_hidden`, `Mojo-hidden`),
are refused: hidden code that never runs is the defect this guards.

Every refusal names `<readme>:<line>` (1-based), and all of them are
reported at once.
"""

from .markdown import Fence, code_mask, fences, relative_links
from .text import byte_at, indent_of, is_blank, lower_ascii, split_lines, strip, substr, suffix


@fieldwise_init
struct Example(Copyable, Movable):
    # 1-based README line of the opening fence.
    var line: Int
    # The fence says `mojo module`: a whole program, copied as it is.
    var module: Bool
    # The code: hidden lines before, the block's lines, hidden lines after.
    var code: List[String]
    # 1-based README line of each entry of `code`.
    var code_lines: List[Int]


@fieldwise_init
struct _Hidden(Copyable, Movable):
    # 0-based first and last lines of the comment.
    var first: Int
    var last: Int
    var code: List[String]
    var code_lines: List[Int]


comptime _FIRE = "\U0001F525"
comptime _MARK = "mojo-hidden"


def _first_word(info: String) -> String:
    var n = info.byte_length()
    var k = 0
    while k < n and byte_at(info, k) != 32 and byte_at(info, k) != 9:
        k += 1
    return substr(info, 0, k)


comptime MODULE_WORD = "module"


def _after_mojo(info: String) -> String:
    """What follows the leading `mojo` of `info`, without surrounding space."""
    return strip(suffix(info, 4))


def info_refusal(info: String) -> String:
    """Why `info` may not open a fence of a README, or "" when it may. An
    info string of `mojo` or `mojo module` is an example; any other word is
    prose."""
    var word = _first_word(info)
    if word == "mojo":
        var rest = _after_mojo(info)
        if rest.byte_length() > 0 and rest != MODULE_WORD:
            return (
                "`"
                + info
                + "`: an example's info string is `mojo` or `mojo module`; nothing else may follow `mojo`"
                + " (there is no skip word: fence a sketch that cannot run as ```text)"
            )
        return ""
    if lower_ascii(word).find("mojo") >= 0 or word.find(_FIRE) >= 0:
        return (
            "`"
            + word
            + "` is not `mojo`: write ```mojo for an example that runs, or ```text"
            + " for a sketch"
        )
    return ""


def _comment_start(line: String) -> String:
    """The text after `<!--` when `line` opens an HTML comment, else ""."""
    var t = strip(line)
    if not t.startswith("<!--"):
        return ""
    return String(" ") + suffix(t, 4)


def _hidden_comments(
    lines: List[String], mask: List[Bool], display: String, mut refusals: List[String]
) -> List[_Hidden]:
    var out = List[_Hidden]()
    var i = 0
    var n = len(lines)
    while i < n:
        if mask[i]:
            i += 1
            continue
        var after = _comment_start(lines[i])
        if after.byte_length() == 0:
            i += 1
            continue
        var body = strip(after)
        var where = display + ":" + String(i + 1) + ": "
        if not body.startswith(_MARK) or (
            body.byte_length() > _MARK.byte_length()
            and byte_at(body, _MARK.byte_length()) != 32
            and byte_at(body, _MARK.byte_length()) != 9
            and not suffix(body, _MARK.byte_length()).startswith("-->")
        ):
            if lower_ascii(body).startswith("mojo"):
                refusals.append(
                    where + "`<!-- " + _first_word(body) + "`: the hidden-lines marker is exactly `<!-- mojo-hidden`"
                )
            i += 1
            continue
        var rest = suffix(body, _MARK.byte_length())
        var h = _Hidden(i, i, List[String](), List[Int]())
        var end = rest.find("-->")
        if end >= 0:
            # One line: `<!-- mojo-hidden CODE -->`.
            var code = strip(substr(rest, 0, end))
            if strip(suffix(rest, end + 3)).byte_length() > 0:
                refusals.append(where + "text after `-->` on a mojo-hidden line")
            if code.byte_length() > 0:
                h.code.append(code)
                h.code_lines.append(i + 1)
            out.append(h^)
            i += 1
            continue
        if strip(rest).byte_length() > 0:
            refusals.append(where + "a multi-line mojo-hidden comment holds nothing after `<!-- mojo-hidden` on its first line")
        var j = i + 1
        var closed = False
        while j < n:
            var e = lines[j].find("-->")
            if e >= 0:
                var tail = substr(lines[j], 0, e)
                if not is_blank(tail):
                    h.code.append(tail)
                    h.code_lines.append(j + 1)
                if strip(suffix(lines[j], e + 3)).byte_length() > 0:
                    refusals.append(display + ":" + String(j + 1) + ": text after `-->` on a mojo-hidden line")
                closed = True
                break
            h.code.append(lines[j])
            h.code_lines.append(j + 1)
            j += 1
        if not closed:
            refusals.append(where + "a mojo-hidden comment is never closed with `-->`")
            break
        h.last = j
        out.append(h^)
        i = j + 1
    return out^


def _dedent(line: String, indent: Int) -> String:
    var k = 0
    var n = line.byte_length()
    while k < indent and k < n and (byte_at(line, k) == 32 or byte_at(line, k) == 9):
        k += 1
    return suffix(line, k)


def extract_examples(text: String, display: String, refuse_relative_links: Bool) raises -> List[Example]:
    """The examples of README `text`, named `display` in every message.

    With `refuse_relative_links` (a README that ships in its package), a
    relative link outside code is refused too: the installed copy sits where
    the repository's other files do not. Anchors and absolute URLs pass.
    Raises with every refusal, one per line."""
    var lines = split_lines(text)
    var mask = code_mask(lines)
    var refusals = List[String]()
    var fs = fences(lines)
    var hidden = _hidden_comments(lines, mask, display, refusals)
    var used = List[Bool](length=len(hidden), fill=False)
    var out = List[Example]()
    for k in range(len(fs)):
        ref f = fs[k]
        var where = display + ":" + String(f.open_line + 1) + ": "
        var why = info_refusal(f.info)
        if why.byte_length() > 0:
            refusals.append(where + why)
            continue
        if _first_word(f.info) != "mojo":
            continue
        if f.close_line < 0:
            refusals.append(where + "the ```mojo example is never closed")
            continue
        var ex = Example(f.open_line + 1, _after_mojo(f.info) == MODULE_WORD, List[String](), List[Int]())
        for h in range(len(hidden)):
            if hidden[h].last == f.open_line - 1:
                used[h] = True
                for c in range(len(hidden[h].code)):
                    ex.code.append(hidden[h].code[c])
                    ex.code_lines.append(hidden[h].code_lines[c])
        for li in range(f.open_line + 1, f.close_line):
            ex.code.append(_dedent(lines[li], f.indent))
            ex.code_lines.append(li + 1)
        for h in range(len(hidden)):
            if hidden[h].first == f.close_line + 1:
                if used[h]:
                    refusals.append(
                        display
                        + ":"
                        + String(hidden[h].first + 1)
                        + ": a mojo-hidden comment both follows one example and precedes another;"
                        + " put a blank line on one side"
                    )
                used[h] = True
                for c in range(len(hidden[h].code)):
                    ex.code.append(hidden[h].code[c])
                    ex.code_lines.append(hidden[h].code_lines[c])
        out.append(ex^)
    for h in range(len(hidden)):
        if not used[h]:
            refusals.append(
                display
                + ":"
                + String(hidden[h].first + 1)
                + ": a mojo-hidden comment must end on the line just before a ```mojo fence"
                + " or start on the line just after its closing fence; this one runs nowhere"
            )
    if refuse_relative_links:
        var links = relative_links(lines)
        for k in range(len(links)):
            var t = links[k].target
            if t.startswith("#"):
                continue
            refusals.append(
                display
                + ":"
                + String(links[k].line + 1)
                + ": "
                + t
                + ": a relative link in a README that ships in its package; the installed copy"
                + " has no such file. Link an absolute URL, or an #anchor of this README"
            )
    if len(refusals) > 0:
        var msg = String("")
        # Document order: a refusal starts with `<display>:<line>:`.
        _sort_by_line(refusals, display)
        for k in range(len(refusals)):
            if k > 0:
                msg += "\n"
            msg += refusals[k]
        raise Error(msg)
    return out^


def _line_of(s: String, display: String) -> Int:
    var rest = suffix(s, display.byte_length() + 1)
    var v = 0
    var k = 0
    while k < rest.byte_length() and byte_at(rest, k) >= 48 and byte_at(rest, k) <= 57:
        v = v * 10 + byte_at(rest, k) - 48
        k += 1
    return v


def _sort_by_line(mut xs: List[String], display: String):
    # Insertion sort, stable: a handful of entries.
    for i in range(1, len(xs)):
        var j = i
        while j > 0 and _line_of(xs[j - 1], display) > _line_of(xs[j], display):
            var t = xs[j - 1]
            xs[j - 1] = xs[j]
            xs[j] = t
            j -= 1
