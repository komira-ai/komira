# =============================================================================
# test_cards.mojo -- card structure, limits and vCard 2.1 quoted-printable;
# hostile input fails closed with exact messages.
# =============================================================================
#
# What each test proves (and the defect it catches):
#   two_cards_mixed_case     BEGIN:vCard / END:vCard (RFC 2426 §7 spells it
#                            so) pair; versions and line numbers are kept.
#   unterminated_card        a BEGIN:VCARD with no END:VCARD is refused, not
#                            returned half-read.
#   structure_refusals       END with no card, a property outside a card, a
#                            nested BEGIN, no VERSION, a second VERSION, an
#                            unsupported VERSION.
#   card_limit               card max_cards + 1 is refused (a missing count
#                            check imports any number of cards).
#   ten_mb_line              a 10 MiB line is refused under the default
#                            1 MiB line limit (the "remove the size cap"
#                            mutant).
#   invalid_utf8             a card holding an ill-formed octet is refused
#                            (the "skip UTF-8 validation" mutant).
#   quoted_printable         vCard 2.1 QP with soft breaks, UTF-8 and
#                            ISO-8859-1, the bare QUOTED-PRINTABLE parameter;
#                            bad hex, a bad charset and QP decoding to
#                            invalid UTF-8 are refused.
#   qp_soft_break_space      the line after a soft break is read as written:
#                            a leading SPACE is data, not a fold (unfolding
#                            first joined "abc=" and " 2Bx" into "abc=2Bx"
#                            and decoded "+", and refused "Long=" + " note").
#   qp_param_fold            a fold inside the parameters of a QP line is
#                            not a soft break of the value: right after a
#                            parameter's "=" and mid-name before a "=3D"
#                            value (the "rebuild folds before the value
#                            start" mutant aborts or splices parameter text).
#   qp_blank_after_soft_break  a blank line after a soft break ends the
#                            value: NOTE is "abc" and the next TEL survives
#                            (joining the next logical line read the TEL
#                            into NOTE as "abcTEL:123" and lost it).
#   qp_blank_then_white_space  a blank line after a soft break ends the
#                            value even when the next line starts with
#                            SPACE: that line continues the blank line (RFC
#                            6350 §3.2), so it is a line of its own, not a
#                            content line, refused at the blank's line number
#                            (skipping the blank inside the fold read
#                            "abc def"; dropping the soft-break check of a
#                            line that begins blank reads "abcdef"). Same
#                            for a fold after the blank that ends in "=".
#   qp_soft_break_at_end     a soft break on the last line of input, with or
#                            without a final CRLF or a trailing blank line,
#                            ends the value and the card is refused as
#                            unterminated, not read past the last line (the
#                            "drop the end-of-input guard" mutant aborts).
#   qp_join_limit            a value joined over soft breaks is refused at
#                            max_line_octets though each physical line is
#                            under it (the "no cap on the join" mutant).
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_vcard import VCardLimits, parse_vcards


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


def _err(s: String, limits: VCardLimits = VCardLimits()) -> String:
    try:
        _ = parse_vcards(s.as_bytes(), limits)
    except e:
        return String(e)
    return String("no error")


def _err_b(d: List[UInt8]) -> String:
    try:
        _ = parse_vcards(Span(d))
    except e:
        return String(e)
    return String("no error")


def test_two_cards_mixed_case() raises:
    var s = (
        "BEGIN:vCard\r\nVERSION:3.0\r\nFN:A\r\nEND:vCard\r\n"
        "\r\n"
        "begin:VCARD\r\nfn:B\r\nversion:4.0\r\nNOTE:x\r\nend:vcard\r\n"
    )
    var cards = parse_vcards(s.as_bytes())
    assert_equal(len(cards), 2)
    assert_equal(cards[0].version, "3.0")
    assert_equal(cards[0].begin_line, 1)
    assert_equal(len(cards[0].lines), 1)
    assert_equal(cards[0].lines[0].line.name, "FN")
    assert_equal(cards[1].version, "4.0")
    assert_equal(cards[1].begin_line, 6)
    assert_equal(len(cards[1].lines), 2)
    assert_equal(cards[1].lines[0].text, "fn:B")
    assert_equal(cards[1].lines[1].line_number, 9)
    assert_equal(len(parse_vcards("".as_bytes())), 0)
    print("  test_two_cards_mixed_case PASS")


def test_unterminated_card() raises:
    assert_equal(
        _err("BEGIN:VCARD\r\nVERSION:4.0\r\nFN:A\r\n"),
        "vcard: the card begun at line 1 has no END:VCARD",
    )
    print("  test_unterminated_card PASS")


def test_structure_refusals() raises:
    assert_equal(
        _err("END:VCARD\r\n"), "vcard: line 1: END:VCARD with no card begun"
    )
    assert_equal(
        _err("FN:A\r\n"),
        "vcard: line 1: a property outside BEGIN:VCARD and END:VCARD",
    )
    assert_equal(
        _err("BEGIN:VCARD\r\nVERSION:4.0\r\nBEGIN:VCARD\r\n"),
        "vcard: line 3: BEGIN:VCARD inside the card begun at line 1",
    )
    assert_equal(
        _err("BEGIN:VCARD\r\nFN:A\r\nEND:VCARD\r\n"),
        "vcard: the card begun at line 1 has no VERSION",
    )
    assert_equal(
        _err("BEGIN:VCARD\r\nVERSION:4.0\r\nVERSION:4.0\r\nEND:VCARD\r\n"),
        "vcard: line 3: a second VERSION in the card begun at line 1",
    )
    assert_equal(
        _err("BEGIN:VCARD\r\nVERSION:5.0\r\nEND:VCARD\r\n"),
        "vcard: line 2: VERSION 5.0 is not 2.1, 3.0 or 4.0",
    )
    print("  test_structure_refusals PASS")


def test_card_limit() raises:
    var one = String("BEGIN:VCARD\r\nVERSION:4.0\r\nFN:A\r\nEND:VCARD\r\n")
    var lim = VCardLimits(max_cards=2)
    var two = one.copy()
    two += one
    var three = two.copy()
    three += one
    assert_equal(len(parse_vcards(two.as_bytes(), lim)), 2)
    assert_equal(
        _err(three, lim),
        "vcard: line 9: card 3 is over the limit of 2 cards",
    )
    print("  test_card_limit PASS")


def test_ten_mb_line() raises:
    var d = _b("BEGIN:VCARD\r\nVERSION:4.0\r\nNOTE:")
    for _ in range(10 * 1024 * 1024):
        d.append(120)
    _extend(d, "\r\nEND:VCARD\r\n")
    assert_equal(
        _err_b(d), "content line: line 3 is longer than the 1048576-octet limit"
    )
    print("  test_ten_mb_line PASS")


def test_invalid_utf8() raises:
    var d = _b("BEGIN:VCARD\r\nVERSION:4.0\r\nFN:J")
    d.append(0xC3)
    d.append(0x28)
    _extend(d, "\r\nEND:VCARD\r\n")
    assert_equal(
        _err_b(d),
        "content line: line 3 is not valid UTF-8 (octet 4 of the unfolded line)",
    )
    print("  test_invalid_utf8 PASS")


def test_quoted_printable() raises:
    var s = (
        "BEGIN:VCARD\r\nVERSION:2.1\r\n"
        "NOTE;ENCODING=QUOTED-PRINTABLE;CHARSET=UTF-8:caf=C3=A9 =\r\n"
        "au lait=0D=0A=\r\n"
        "line 2\r\n"
        "N;CHARSET=ISO-8859-1;ENCODING=QUOTED-PRINTABLE:M=FCller;J=F6rg\r\n"
        "ADR;HOME;QUOTED-PRINTABLE:;;Stra=C3=9Fe 1\r\n"
        "END:VCARD\r\n"
    )
    var cards = parse_vcards(s.as_bytes())
    assert_equal(len(cards[0].lines), 3)
    ref note = cards[0].lines[0]
    assert_equal(note.line.value, "café au lait\\nline 2")
    assert_equal(len(note.line.params), 0)
    assert_equal(note.line_number, 3)
    assert_equal(cards[0].lines[1].line.value, "Müller;Jörg")
    assert_equal(cards[0].lines[1].text, "N:Müller;Jörg")
    assert_equal(cards[0].lines[2].text, "ADR;HOME:;;Straße 1")
    assert_equal(
        _err(
            "BEGIN:VCARD\r\nVERSION:2.1\r\nNOTE;ENCODING=QUOTED-PRINTABLE:a=G1\r\n"
        ),
        "vcard: line 3: invalid quoted-printable at octet 1",
    )
    assert_equal(
        _err(
            "BEGIN:VCARD\r\nVERSION:2.1\r\n"
            "NOTE;ENCODING=QUOTED-PRINTABLE;CHARSET=KOI8-R:a\r\n"
        ),
        "vcard: line 3: CHARSET KOI8-R is not UTF-8, US-ASCII or ISO-8859-1",
    )
    assert_equal(
        _err(
            "BEGIN:VCARD\r\nVERSION:2.1\r\n"
            "NOTE;ENCODING=QUOTED-PRINTABLE:ab=FF\r\n"
        ),
        "vcard: line 3: the quoted-printable value is not valid UTF-8 (octet"
        " 2)",
    )
    print("  test_quoted_printable PASS")


def _value_or_error(s: String) -> String:
    try:
        var cards = parse_vcards(s.as_bytes())
        return String("value=[") + cards[0].lines[0].line.value + "]"
    except e:
        return String("error=[") + String(e) + "]"


def test_qp_soft_break_space() raises:
    assert_equal(
        _value_or_error(
            "BEGIN:VCARD\r\nVERSION:2.1\r\n"
            "NOTE;ENCODING=QUOTED-PRINTABLE:abc=\r\n 2Bx\r\nEND:VCARD\r\n"
        ),
        "value=[abc 2Bx]",
    )
    assert_equal(
        _value_or_error(
            "BEGIN:VCARD\r\nVERSION:2.1\r\n"
            "NOTE;ENCODING=QUOTED-PRINTABLE:Long=\r\n note\r\nEND:VCARD\r\n"
        ),
        "value=[Long note]",
    )
    # A soft break whose next line starts with HTAB, then one with no white
    # space, then a 3.0/4.0 fold that is not after a "=" (white space removed).
    assert_equal(
        _value_or_error(
            "BEGIN:VCARD\r\nVERSION:2.1\r\n"
            "NOTE;QUOTED-PRINTABLE:a=\r\n\tb=\r\nc=3D\r\n d\r\nEND:VCARD\r\n"
        ),
        "value=[a\tbc=d]",
    )
    print("  test_qp_soft_break_space PASS")


def test_qp_param_fold() raises:
    assert_equal(
        _value_or_error(
            "BEGIN:VCARD\r\nVERSION:3.0\r\n"
            "NOTE;ENCODING=\r\n QUOTED-PRINTABLE:abc\r\nEND:VCARD\r\n"
        ),
        "value=[abc]",
    )
    assert_equal(
        _value_or_error(
            "BEGIN:VCARD\r\nVERSION:2.1\r\n"
            "NOTE;ENC\r\n ODING=QUOTED-PRINTABLE:abc=3Dx\r\nEND:VCARD\r\n"
        ),
        "value=[abc=x]",
    )
    print("  test_qp_param_fold PASS")


def test_qp_blank_after_soft_break() raises:
    var cards = parse_vcards(
        String(
            "BEGIN:VCARD\r\nVERSION:2.1\r\n"
            "NOTE;QUOTED-PRINTABLE:abc=\r\n\r\nTEL:123\r\nEND:VCARD\r\n"
        ).as_bytes()
    )
    assert_equal(len(cards[0].lines), 2)
    assert_equal(cards[0].lines[0].text, "NOTE:abc")
    assert_equal(cards[0].lines[1].text, "TEL:123")
    assert_equal(cards[0].lines[1].line_number, 5)
    print("  test_qp_blank_after_soft_break PASS")


def test_qp_blank_then_white_space() raises:
    assert_equal(
        _value_or_error(
            "BEGIN:VCARD\r\nVERSION:2.1\r\n"
            "NOTE;QUOTED-PRINTABLE:abc=\r\n\r\n def\r\nEND:VCARD\r\n"
        ),
        "error=[content line: line 4 has no ':' after the property name]",
    )
    assert_equal(
        _value_or_error(
            "BEGIN:VCARD\r\nVERSION:2.1\r\n"
            "NOTE;QUOTED-PRINTABLE:ab\r\n\r\n c=\r\nde\r\nEND:VCARD\r\n"
        ),
        "error=[content line: line 4 has an invalid character in the"
        " property name]",
    )
    # A fold inside the QP line, then a soft break: the next physical line
    # is joined (the adjacency count includes the fold's line).
    assert_equal(
        _value_or_error(
            "BEGIN:VCARD\r\nVERSION:2.1\r\n"
            "NOTE;QUOTED-PRINTABLE:ab\r\n c=\r\nde\r\nEND:VCARD\r\n"
        ),
        "value=[abcde]",
    )
    # A soft break, a blank line, then two white-space lines: the blank's
    # logical line has two folds and is not joined (the blank is its first
    # fold, not its last).
    assert_equal(
        _value_or_error(
            "BEGIN:VCARD\r\nVERSION:2.1\r\n"
            "NOTE;QUOTED-PRINTABLE:abc=\r\n\r\n d\r\n e\r\nEND:VCARD\r\n"
        ),
        "error=[content line: line 4 has no ':' after the property name]",
    )
    print("  test_qp_blank_then_white_space PASS")


def _lines_or_error(s: String) -> String:
    try:
        var cards = parse_vcards(s.as_bytes())
        var out = String("")
        for ref l in cards[0].lines:
            out += (
                l.line.name
                + "="
                + l.line.value
                + "@"
                + String(l.line_number)
                + ";"
            )
        return out
    except e:
        return String("error=[") + String(e) + "]"


def test_qp_after_blank_and_white_space_line() raises:
    # A blank line then a white-space-only line before a QP line: the empty
    # logical line is skipped with its fold, so the NOTE line carries no
    # stale fold and the soft-break adjacency count is exact both ways.
    # A blank after the "=" ends the value; TEL stays its own line.
    assert_equal(
        _lines_or_error(
            "BEGIN:VCARD\r\nVERSION:2.1\r\n\r\n \r\n"
            "NOTE;ENCODING=QUOTED-PRINTABLE:abc=\r\n\r\nTEL:123\r\n"
            "END:VCARD\r\n"
        ),
        "NOTE=abc@5;TEL=123@7;",
    )
    # The physical line right after the "=" is joined.
    assert_equal(
        _value_or_error(
            "BEGIN:VCARD\r\nVERSION:2.1\r\n\r\n \r\n"
            "NOTE;QUOTED-PRINTABLE:abc=\r\ndef\r\nEND:VCARD\r\n"
        ),
        "value=[abcdef]",
    )
    # Two continuations of the blank (SPACE, then HTAB): both folds are
    # dropped, so the soft break still joins the next physical line.
    assert_equal(
        _value_or_error(
            "BEGIN:VCARD\r\nVERSION:2.1\r\n\r\n \r\n\t\r\n"
            "NOTE;QUOTED-PRINTABLE:abc=\r\ndef\r\nEND:VCARD\r\n"
        ),
        "value=[abcdef]",
    )
    print("  test_qp_after_blank_and_white_space_line PASS")


def test_qp_soft_break_at_end() raises:
    var want = "vcard: the card begun at line 1 has no END:VCARD"
    assert_equal(
        _err("BEGIN:VCARD\r\nVERSION:2.1\r\nNOTE;QUOTED-PRINTABLE:abc="),
        want,
    )
    assert_equal(
        _err("BEGIN:VCARD\r\nVERSION:2.1\r\nNOTE;QUOTED-PRINTABLE:abc=\r\n"),
        want,
    )
    assert_equal(
        _err(
            "BEGIN:VCARD\r\nVERSION:2.1\r\n"
            "NOTE;QUOTED-PRINTABLE:abc=\r\n\r\n"
        ),
        want,
    )
    print("  test_qp_soft_break_at_end PASS")


def test_qp_join_limit() raises:
    # Each physical line is under 30 octets; the joined value is 36.
    assert_equal(
        _err(
            "BEGIN:VCARD\r\nVERSION:2.1\r\n"
            "NOTE;QUOTED-PRINTABLE:aaaa=\r\nbbbbbbbbbbbb=\r\n"
            "cccccccccccccccccccc\r\nEND:VCARD\r\n",
            VCardLimits(max_line_octets=30),
        ),
        "content line: line 3 is longer than the 30-octet limit",
    )
    print("  test_qp_join_limit PASS")


def main() raises:
    print("test_cards")
    test_two_cards_mixed_case()
    test_unterminated_card()
    test_structure_refusals()
    test_card_limit()
    test_ten_mb_line()
    test_invalid_utf8()
    test_quoted_printable()
    test_qp_soft_break_space()
    test_qp_blank_after_soft_break()
    test_qp_blank_then_white_space()
    test_qp_after_blank_and_white_space_line()
    test_qp_soft_break_at_end()
    test_qp_param_fold()
    test_qp_join_limit()
    print("ALL TESTS PASS")
