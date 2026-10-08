# =============================================================================
# test_fold_escape.mojo -- folding at 75 octets, TEXT escaping and the
# split-before-unescape rule, and the writer's refusals.
# =============================================================================
#
# What each test proves (and the defect it catches):
#   fold_ascii_boundary     75 octets stay one line, 76 fold; a continuation
#                           line is SPACE + 74 octets (an off-by-one width).
#   fold_multibyte_octets   a line of 3-octet characters folds at the last
#                           whole character within 75 OCTETS: the golden is
#                           exact (the "fold at 75 characters" mutant writes
#                           75 characters = 225 octets on the first line).
#   fold_unfold_identity    unfold(fold(x)) == x over lengths 0..400 and a
#                           mix of 1- to 4-octet characters.
#   escape_unescape         RFC 6350 §3.4 / §4.1: backslash, comma,
#                           semicolon and line breaks, both directions.
#   split_before_unescape   `Doe\, Jr.` stays one value and `\;` one field
#                           (the "unescape before splitting" mutant).
#   format_round_trip       format(parse(x)) == x for quoted, caret-encoded
#                           and bare parameters.
#   format_quotes_separators a parameter value holding ';' or ':' is written
#                           quoted and reads back as the same values and the
#                           same line value (the "quote only on ','" mutant
#                           lets `home;VALUE=uri` add a parameter and `x:y`
#                           move the value boundary).
#   format_refusals         a group, name or parameter value that would break
#                           the line is refused with an exact message.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_content_line import (
    ContentLine,
    FOLD_OCTETS,
    Param,
    escape_text,
    fold_line,
    format_content_line,
    parse_content_line,
    split_unescaped,
    unescape_text,
    unfold,
)


def _rep(s: String, n: Int) -> String:
    var out = String()
    for _ in range(n):
        out += s
    return out^


def _physical_lines(folded: String) -> List[String]:
    var out = List[String]()
    var parts = folded.split("\r\n")
    for i in range(len(parts) - 1):
        out.append(String(parts[i]))
    return out^


def test_fold_ascii_boundary() raises:
    var l75 = String("X:") + _rep("a", 73)
    assert_equal(fold_line(l75), l75 + "\r\n")
    var l76 = l75 + "b"
    assert_equal(fold_line(l76), l75 + "\r\n b\r\n")
    var l200 = String("X:") + _rep("c", 198)
    var phys = _physical_lines(fold_line(l200))
    assert_equal(len(phys), 3)
    assert_equal(phys[0].byte_length(), 75)
    assert_equal(phys[1].byte_length(), 75)
    assert_equal(phys[2].byte_length(), 200 - 75 - 74 + 1)
    print("  test_fold_ascii_boundary PASS")


def test_fold_multibyte_octets() raises:
    # "N:" + 40 x U+65E5 (3 octets each) = 122 octets. 75 octets hold "N:"
    # and 24 characters (74 octets): the 25th would end at octet 77.
    var line = String("N:") + _rep("日", 40)
    var want = (
        String("N:") + _rep("日", 24) + "\r\n " + _rep("日", 16) + "\r\n"
    )
    assert_equal(fold_line(line), want)
    var phys = _physical_lines(fold_line(line))
    for i in range(len(phys)):
        assert_true(phys[i].byte_length() <= FOLD_OCTETS)
    print("  test_fold_multibyte_octets PASS")


def test_fold_unfold_identity() raises:
    var alphabet = List[String]()
    alphabet.append("a")
    alphabet.append("é")
    alphabet.append("日")
    alphabet.append("😀")
    alphabet.append(" ")
    for n in range(0, 401):
        var line = String("X:")
        for k in range(n):
            line += alphabet[(k * 7 + n) % len(alphabet)]
        var folded = fold_line(line)
        var phys = _physical_lines(folded)
        for i in range(len(phys)):
            assert_true(phys[i].byte_length() <= FOLD_OCTETS)
        var back = unfold(folded.as_bytes())
        assert_equal(len(back), 1)
        assert_equal(back[0].text, line)
    print("  test_fold_unfold_identity PASS")


def test_escape_unescape() raises:
    assert_equal(
        escape_text("a\\b,c;d\ne\r\nf\rg"), "a\\\\b\\,c\\;d\\ne\\nf\\ng"
    )
    assert_equal(unescape_text("a\\\\b\\,c\\;d\\ne\\Nf"), "a\\b,c;d\ne\nf")
    # RFC 6350 §4.1's NOTE, unfolded.
    assert_equal(
        unescape_text(
            "Mythical Manager\\nHyjinx Software Division\\nBabsCo\\, Inc.\\n"
        ),
        "Mythical Manager\nHyjinx Software Division\nBabsCo, Inc.\n",
    )
    # A vCard 3.0 writer's `\:` reads as ':'; a trailing backslash is kept.
    assert_equal(unescape_text("http\\://example.com/\\"), "http://example.com/\\")
    assert_equal(unescape_text("\\é"), "é")
    print("  test_escape_unescape PASS")


def test_split_before_unescape() raises:
    var fields = split_unescaped("Doe\\, Jr.;John;;;", 59)
    assert_equal(len(fields), 5)
    assert_equal(fields[0], "Doe\\, Jr.")
    var values = split_unescaped(fields[0], 44)
    assert_equal(len(values), 1)
    assert_equal(unescape_text(values[0]), "Doe, Jr.")
    var adr = split_unescaped(";;123 Main St\\; Apt 4;Town", 59)
    assert_equal(len(adr), 4)
    assert_equal(unescape_text(adr[2]), "123 Main St; Apt 4")
    var trailing = split_unescaped("a\\\\;b", 59)
    assert_equal(len(trailing), 2)
    assert_equal(unescape_text(trailing[0]), "a\\")
    assert_equal(len(split_unescaped("", 59)), 1)
    print("  test_split_before_unescape PASS")


def test_format_round_trip() raises:
    var lines = List[String]()
    lines.append('ADR;LABEL="a, b^nc";TYPE=work,home:;;x;y;z;;')
    lines.append("item1.TEL;WORK;VOICE:+1-555-0100")
    lines.append("X-A;X-P=^'q^';X-E=:v")
    for i in range(len(lines)):
        var cl = parse_content_line(lines[i], 1)
        assert_equal(format_content_line(cl), lines[i])
    print("  test_format_round_trip PASS")


def test_format_quotes_separators() raises:
    var vals = List[String]()
    vals.append("home;VALUE=uri")
    vals.append("x:y")
    var ps = List[Param]()
    ps.append(Param("TYPE", vals^))
    var text = format_content_line(ContentLine("", "TEL", ps^, "+1-555-0100"))
    assert_equal(text, 'TEL;TYPE="home;VALUE=uri","x:y":+1-555-0100')
    var back = parse_content_line(text, 1)
    assert_equal(len(back.params), 1)
    assert_equal(len(back.params[0].values), 2)
    assert_equal(back.params[0].values[0], "home;VALUE=uri")
    assert_equal(back.params[0].values[1], "x:y")
    assert_equal(back.value, "+1-555-0100")
    print("  test_format_quotes_separators PASS")


def _fmt_err(cl: ContentLine) -> String:
    try:
        _ = format_content_line(cl)
    except e:
        return String(e)
    return String("no error")


def test_format_refusals() raises:
    var no_params = List[Param]()
    assert_equal(
        _fmt_err(ContentLine("a\r\nEND", "FN", no_params.copy(), "x")),
        "content line: group 'a\r\nEND' has a character outside ALPHA, DIGIT"
        " and '-'",
    )
    assert_equal(
        _fmt_err(ContentLine("", "F:N", no_params.copy(), "x")),
        "content line: property name 'F:N' has a character outside ALPHA,"
        " DIGIT and '-'",
    )
    assert_equal(
        _fmt_err(ContentLine("", "FN", no_params.copy(), "x\r\nEND:VCARD")),
        "content line: the value of FN holds a line break",
    )
    var p = List[Param]()
    var vals = List[String]()
    vals.append("a\rb")
    p.append(Param("TYPE", vals^))
    assert_equal(
        _fmt_err(ContentLine("", "FN", p^, "x")),
        "content line: a parameter value holds a CR",
    )
    print("  test_format_refusals PASS")


def main() raises:
    print("test_fold_escape")
    test_fold_ascii_boundary()
    test_fold_multibyte_octets()
    test_fold_unfold_identity()
    test_escape_unescape()
    test_split_before_unescape()
    test_format_round_trip()
    test_format_quotes_separators()
    test_format_refusals()
    print("ALL TESTS PASS")
