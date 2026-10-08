# =============================================================================
# test_unfold_lexer.mojo -- unfolding and lexing against RFC 6350 §3.2-§3.3,
# RFC 6350 §4.1 / §6.3.1 and RFC 6868 §3.1-§3.2 examples, plus the refusals.
# =============================================================================
#
# What each test proves (and the defect it catches):
#   rfc6350_3_2_fold_forms     the three forms RFC 6350 §3.2 gives for one
#                              NOTE unfold to the same line (a fold that keeps
#                              the white space, or drops two octets).
#   folds_recorded             each join is recorded as (offset in the
#                              unfolded text, white-space octet removed), the
#                              record vCard 2.1 quoted-printable reading uses
#                              to put a soft break's continuation back.
#   fold_inside_multibyte      a fold that splits "é" (C3 | A9) is restored
#                              before validation (validating physical lines
#                              would refuse it).
#   invalid_utf8_refused       an ill-formed octet is refused with its line
#                              and offset (the "skip UTF-8 validation" mutant).
#   line_limit / input_limit   the octet bounds hold, with exact messages (the
#                              "remove the size cap" mutant).
#   leading_continuation       a first line that starts with white space is
#                              refused, not silently joined to nothing.
#   line_endings_and_numbers   CRLF and bare LF both end a line, blank lines
#                              are skipped, and line numbers are physical.
#   blank_line_ends_line       RFC 6350 §3.2 / RFC 5545 §3.1: only CRLF +
#                              SPACE/HTAB is a fold, so the CRLF before a
#                              blank line ends the logical line, and a
#                              white-space line after the blank continues the
#                              blank (empty) line, not the line before it.
#                              Both sides: blank then a name, blank then
#                              SPACE, blank then HTAB at the start of input,
#                              blank at the end of input (the "skip blank
#                              lines inside a fold" defect joined "A:1" and
#                              " B" into "A:1B" and refused "\r\n\tx:1").
#   lex_group_name_params      `item1.EMAIL` splits into group and upper-cased
#                              name (the "drop the group strip" mutant).
#   lex_rfc6350_adr_label      a quoted parameter holding ':' ',' and a fold
#                              (RFC 6350 §6.3.1) does not end the parameter.
#   lex_rfc6868_caret          RFC 6868's ^' and ^n decode; ^x is kept (the
#                              §3.1 and §3.2 examples, with the person's name
#                              and the street address replaced by example
#                              ones).
#   lex_bare_param             vCard 2.1 `TEL;WORK;VOICE:` keeps bare params.
#   lex_refusals               malformed lines raise exact messages.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_content_line import (
    ContentLimits,
    parse_content_line,
    unfold,
)


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _extend(mut d: List[UInt8], s: String):
    var b = s.as_bytes()
    for i in range(len(b)):
        d.append(b[i])


def _one_line(d: List[UInt8]) raises -> String:
    var lines = unfold(Span(d))
    assert_equal(len(lines), 1)
    assert_equal(lines[0].line_number, 1)
    return lines[0].text


def _unfold_err(data: List[UInt8], limits: ContentLimits) -> String:
    try:
        _ = unfold(Span(data), limits)
    except e:
        return String(e)
    return String("no error")


def _lex_err(text: String) -> String:
    try:
        _ = parse_content_line(text, 7)
    except e:
        return String(e)
    return String("no error")


def test_rfc6350_3_2_fold_forms() raises:
    var want = "NOTE:This is a long description that exists on a long line."
    var a = _b("NOTE:This is a long description that exists on a long line.\r\n")
    var b = _b(
        "NOTE:This is a long description\r\n  that exists on a long line.\r\n"
    )
    var c = _b(
        "NOTE:This is a long descrip\r\n tion that exists o\r\n n a long"
        " line.\r\n"
    )
    assert_equal(_one_line(a), want)
    assert_equal(_one_line(b), want)
    assert_equal(_one_line(c), want)
    print("  test_rfc6350_3_2_fold_forms PASS")


def test_folds_recorded() raises:
    var d = _b("NOTE:ab\r\n cd\r\n\tef\r\nFN:x\r\n")
    var lines = unfold(Span(d))
    assert_equal(len(lines), 2)
    assert_equal(lines[0].text, "NOTE:abcdef")
    assert_equal(len(lines[0].folds), 2)
    assert_equal(lines[0].folds[0].at, 7)
    assert_equal(lines[0].folds[0].removed, UInt8(32))
    assert_equal(lines[0].folds[1].at, 9)
    assert_equal(lines[0].folds[1].removed, UInt8(9))
    assert_equal(len(lines[1].folds), 0)
    print("  test_folds_recorded PASS")


def test_fold_inside_multibyte() raises:
    var d = _b("FN:Andr")
    d.append(0xC3)
    _extend(d, "\r\n ")
    d.append(0xA9)
    _extend(d, "\r\n")
    var lines = unfold(Span(d))
    assert_equal(len(lines), 1)
    assert_equal(lines[0].text, "FN:André")
    print("  test_fold_inside_multibyte PASS")


def test_invalid_utf8_refused() raises:
    var d = _b("BEGIN:VCARD\r\nFN:ab")
    d.append(0xFF)
    _extend(d, "c\r\n")
    assert_equal(
        _unfold_err(d, ContentLimits()),
        "content line: line 2 is not valid UTF-8 (octet 5 of the unfolded line)",
    )
    # An overlong encoding of '/' (C0 AF) and a surrogate (ED A0 80).
    var o = _b("X:")
    o.append(0xC0)
    o.append(0xAF)
    assert_equal(
        _unfold_err(o, ContentLimits()),
        "content line: line 1 is not valid UTF-8 (octet 2 of the unfolded line)",
    )
    var s = _b("X:")
    s.append(0xED)
    s.append(0xA0)
    s.append(0x80)
    assert_equal(
        _unfold_err(s, ContentLimits()),
        "content line: line 1 is not valid UTF-8 (octet 2 of the unfolded line)",
    )
    print("  test_invalid_utf8_refused PASS")


def test_line_limit() raises:
    var lim = ContentLimits(max_line_octets=10)
    # Exactly 10 octets after unfolding is accepted; the fold does not count.
    var ok = _b("A:12345678\r\n")
    assert_equal(unfold(Span(ok), lim)[0].text, "A:12345678")
    var ok2 = _b("A:1234\r\n 5678\r\n")
    assert_equal(unfold(Span(ok2), lim)[0].text, "A:12345678")
    var long = _b("X:1\r\nA:1234\r\n 56789\r\n")
    assert_equal(
        _unfold_err(long, lim),
        "content line: line 2 is longer than the 10-octet limit",
    )
    print("  test_line_limit PASS")


def test_input_limit() raises:
    var lim = ContentLimits(max_input_octets=8)
    var d = _b("A:123456\r\n")
    assert_equal(
        _unfold_err(d, lim),
        "content line: input is 10 octets; the limit is 8",
    )
    print("  test_input_limit PASS")


def test_leading_continuation() raises:
    var d = _b(" A:1\r\n")
    assert_equal(
        _unfold_err(d, ContentLimits()),
        "content line: line 1 starts with white space and continues no line",
    )
    print("  test_leading_continuation PASS")


def test_line_endings_and_numbers() raises:
    var d = _b("A:1\nB:2\r\n\r\n\nC:3\r\n\t4\r\nD:5")
    var lines = unfold(Span(d))
    assert_equal(len(lines), 4)
    assert_equal(lines[0].text, "A:1")
    assert_equal(lines[1].text, "B:2")
    assert_equal(lines[2].text, "C:34")
    assert_equal(lines[2].line_number, 5)
    assert_equal(lines[3].text, "D:5")
    assert_equal(lines[3].line_number, 7)
    print("  test_line_endings_and_numbers PASS")


def test_blank_line_ends_line() raises:
    var d = _b("A:1\r\n\r\n B:2\r\nC:3\r\n\r\nD:4\r\n\r\n")
    var lines = unfold(Span(d))
    assert_equal(len(lines), 4)
    assert_equal(lines[0].text, "A:1")
    assert_equal(len(lines[0].folds), 0)
    # " B:2" continues the blank line 2: the logical line starts there.
    assert_equal(lines[1].text, "B:2")
    assert_equal(lines[1].line_number, 2)
    assert_equal(len(lines[1].folds), 1)
    assert_equal(lines[1].folds[0].at, 0)
    assert_equal(Int(lines[1].folds[0].removed), 32)
    assert_equal(lines[2].text, "C:3")
    assert_equal(lines[2].line_number, 4)
    assert_equal(lines[3].text, "D:4")
    assert_equal(lines[3].line_number, 6)
    var e = _b("\r\n\tx:1")
    var only = unfold(Span(e))
    assert_equal(len(only), 1)
    assert_equal(only[0].text, "x:1")
    assert_equal(only[0].line_number, 1)
    print("  test_blank_line_ends_line PASS")


def test_blank_then_white_space_only_line() raises:
    # A blank line, then a line that is only white space: that line
    # continues the blank, the logical line stays empty and is skipped with
    # its fold. The next line starts clean: no fold, its own number.
    var d = _b("A:1\r\n\r\n \r\nB:2\r\n")
    var lines = unfold(Span(d))
    assert_equal(len(lines), 2)
    assert_equal(lines[0].text, "A:1")
    assert_equal(len(lines[0].folds), 0)
    assert_equal(lines[1].text, "B:2")
    assert_equal(lines[1].line_number, 4)
    assert_equal(len(lines[1].folds), 0)
    # Two white-space-only continuations (SPACE, then HTAB) mid-stream: both
    # folds go with the skipped line, not only the last one.
    var two = _b("A:1\r\n\r\n \r\n\t\r\nB:2\r\n")
    var pr = unfold(Span(two))
    assert_equal(len(pr), 2)
    assert_equal(pr[1].text, "B:2")
    assert_equal(pr[1].line_number, 5)
    assert_equal(len(pr[1].folds), 0)
    # An HTAB-only continuation of a blank is dropped like a SPACE one.
    var tab = _b("A:1\r\n\r\n\t\r\nB:2\r\n")
    var tb = unfold(Span(tab))
    assert_equal(len(tb), 2)
    assert_equal(tb[1].text, "B:2")
    assert_equal(tb[1].line_number, 4)
    assert_equal(len(tb[1].folds), 0)
    # The same at the end of input: nothing follows, nothing is kept.
    var e = _b("A:1\r\n\r\n \r\n\t")
    var tail = unfold(Span(e))
    assert_equal(len(tail), 1)
    assert_equal(tail[0].text, "A:1")
    assert_equal(len(tail[0].folds), 0)
    # A white-space-only line after a non-blank line is a fold of it.
    var f = _b("A:1\r\n \r\nB:2")
    var kept = unfold(Span(f))
    assert_equal(len(kept), 2)
    assert_equal(len(kept[0].folds), 1)
    assert_equal(kept[0].folds[0].at, 3)
    assert_equal(kept[1].line_number, 3)
    assert_equal(len(kept[1].folds), 0)
    print("  test_blank_then_white_space_only_line PASS")


def test_lex_group_name_params() raises:
    var cl = parse_content_line("item1.email;type=INTERNET,pref:a@example.com", 1)
    assert_equal(cl.group, "item1")
    assert_equal(cl.name, "EMAIL")
    assert_equal(len(cl.params), 1)
    assert_equal(cl.params[0].name, "TYPE")
    assert_equal(len(cl.params[0].values), 2)
    assert_equal(cl.params[0].values[0], "INTERNET")
    assert_equal(cl.params[0].values[1], "pref")
    assert_equal(cl.value, "a@example.com")
    var plain = parse_content_line("FN:a:b;c", 1)
    assert_equal(plain.group, "")
    assert_equal(plain.value, "a:b;c")
    print("  test_lex_group_name_params PASS")


def test_lex_rfc6350_adr_label() raises:
    # RFC 6350 §6.3.1, folded exactly as the RFC prints it.
    var d = _b(
        'ADR;GEO="geo:12.3457,78.910";LABEL="Mr. John Q. Public, Esq.\\n\r\n'
        " Mail Drop: TNE QB\\n123 Main Street\\nAny Town, CA  91921-1234\\n\r\n"
        ' U.S.A.":;;123 Main Street;Any Town;CA;91921-1234;U.S.A.\r\n'
    )
    var lines = unfold(Span(d))
    assert_equal(len(lines), 1)
    var cl = parse_content_line(lines[0].text, lines[0].line_number)
    assert_equal(cl.name, "ADR")
    assert_equal(len(cl.params), 2)
    assert_equal(cl.params[0].values[0], "geo:12.3457,78.910")
    assert_equal(
        cl.params[1].values[0],
        "Mr. John Q. Public, Esq.\\nMail Drop: TNE QB\\n123 Main Street\\nAny"
        " Town, CA  91921-1234\\nU.S.A.",
    )
    assert_equal(cl.value, ";;123 Main Street;Any Town;CA;91921-1234;U.S.A.")
    print("  test_lex_rfc6350_adr_label PASS")


def test_lex_rfc6868_caret() raises:
    # RFC 6868 §3.1 (unquoted) and §3.2 (quoted, folded).
    var a = parse_content_line(
        "ATTENDEE;CN=Jane ^'JJ^' Doe:mailto:jane@example.com", 1
    )
    assert_equal(a.params[0].values[0], 'Jane "JJ" Doe')
    var d = _b(
        'GEO;X-ADDRESS="Example Team^n100 Example St^nAny\r\n'
        ' town, ST 00000":geo:40.446816,-80.00566\r\n'
    )
    var lines = unfold(Span(d))
    var g = parse_content_line(lines[0].text, 1)
    assert_equal(
        g.params[0].values[0],
        "Example Team\n100 Example St\nAnytown, ST 00000",
    )
    assert_equal(g.value, "geo:40.446816,-80.00566")
    var k = parse_content_line("X;P=a^^b^xc:v", 1)
    assert_equal(k.params[0].values[0], "a^b^xc")
    print("  test_lex_rfc6868_caret PASS")


def test_lex_bare_param() raises:
    var cl = parse_content_line("TEL;WORK;VOICE:+1-555-0100", 1)
    assert_equal(len(cl.params), 2)
    assert_equal(cl.params[0].name, "WORK")
    assert_false(cl.params[0].has_value)
    assert_equal(cl.params[1].name, "VOICE")
    assert_true(Bool(cl.param("VOICE")))
    assert_false(Bool(cl.param("HOME")))
    print("  test_lex_bare_param PASS")


def test_lex_refusals() raises:
    assert_equal(
        _lex_err("FN"), "content line: line 7 has no ':' after the property name"
    )
    assert_equal(
        _lex_err(":x"), "content line: line 7 has an empty property name"
    )
    assert_equal(
        _lex_err(".FN:x"), "content line: line 7 has an empty group name"
    )
    assert_equal(
        _lex_err("F N:x"),
        "content line: line 7 has an invalid character in the property name",
    )
    assert_equal(
        _lex_err("a.b.FN:x"),
        "content line: line 7 has an invalid character in the property name",
    )
    assert_equal(
        _lex_err("FN;=x:y"), "content line: line 7 has an empty parameter name"
    )
    assert_equal(
        _lex_err('FN;A="x:y'),
        "content line: line 7 has an unterminated quoted parameter value",
    )
    assert_equal(
        _lex_err('FN;A="x"y:z'),
        "content line: line 7 has a character after a quoted parameter value",
    )
    assert_equal(
        _lex_err('FN;A=x"y:z'),
        "content line: line 7 has a DQUOTE inside an unquoted parameter value",
    )
    assert_equal(
        _lex_err("FN;A B=x:z"),
        "content line: line 7 has an invalid character in a parameter name",
    )
    print("  test_lex_refusals PASS")


def main() raises:
    print("test_unfold_lexer")
    test_rfc6350_3_2_fold_forms()
    test_folds_recorded()
    test_fold_inside_multibyte()
    test_invalid_utf8_refused()
    test_line_limit()
    test_input_limit()
    test_leading_continuation()
    test_line_endings_and_numbers()
    test_blank_line_ends_line()
    test_blank_then_white_space_only_line()
    test_lex_group_name_params()
    test_lex_rfc6350_adr_label()
    test_lex_rfc6868_caret()
    test_lex_bare_param()
    test_lex_refusals()
    print("ALL TESTS PASS")
