# Header folding (RFC 5322 sections 2.1.1 and 2.2.3, RFC 2047 section 2):
# every line the builder writes is at most 76 characters when the value has
# white space to fold at, a field longer than 998 octets is folded rather
# than written as one line, unfolding gives back the exact value, a folded
# line is never white space only, and a line that cannot be folded under 998
# octets is refused, at exactly 998 octets accepted and 999 refused, with an
# empty value too (the `Name: ` prefix alone). A value with no white space
# (or non-ASCII) becomes encoded words, which fold.

from std.testing import assert_equal, assert_true

from komira_mail_address import AddrSpec
from komira_mail_message import MessageBuilder, parse_message, split_header_fields


def _s(b: List[UInt8]) raises -> String:
    return String(StringSlice(from_utf8=Span(b)))


def _builder() raises -> MessageBuilder:
    var b = MessageBuilder()
    b.set_from("", AddrSpec("a", "acme.example"))
    b.set_date(1790000000)
    return b^


def _check_lines(built: List[UInt8], limit: Int) raises:
    """Every line ends CRLF, is at most `limit` octets, and no header line is
    white space only."""
    var start = 0
    var in_header = True
    for i in range(len(built)):
        if built[i] != 10:
            continue
        assert_true(i > 0 and built[i - 1] == 13)
        var length = i - 1 - start
        assert_true(length <= limit, String("line of ") + String(length))
        if in_header:
            if length == 0:
                in_header = False
            else:
                var blank = True
                for k in range(start, i - 1):
                    if built[k] != 32 and built[k] != 9:
                        blank = False
                assert_true(not blank)
        start = i + 1


def _header_lines(built: List[UInt8], name: String) raises -> Int:
    """How many lines the field `name` takes."""
    var block = split_header_fields(Span(built))
    for i in range(len(block.fields)):
        if block.fields[i].is_named(name):
            var raw = block.fields[i].raw()
            var lines = 1
            for k in range(len(raw)):
                if raw[k] == 10:
                    lines += 1
            return lines
    return 0


def test_long_subject_folds_at_76() raises:
    var subject = String("")
    for i in range(40):
        if i > 0:
            subject += " "
        subject += "word" + String(i)
    var b = _builder()
    b.set_subject(subject)
    var built = b.build()
    _check_lines(built, 76)
    assert_true(_header_lines(built, "Subject") > 1)
    var m = parse_message(Span(built))
    assert_equal(m.subject().value(), subject)


def test_field_over_998_octets_is_folded() raises:
    # 1,500 octets of words: one line would break RFC 5322's 998 limit.
    var subject = String("")
    while subject.byte_length() < 1500:
        subject += "folding "
    subject += "end"
    var b = _builder()
    b.set_subject(subject)
    var built = b.build()
    _check_lines(built, 76)
    assert_true(_header_lines(built, "Subject") >= 20)
    var m = parse_message(Span(built))
    assert_equal(m.subject().value(), subject)


def test_runs_of_white_space_survive_folding() raises:
    # Folds go before the last byte of a white space run, so unfolding gives
    # the runs back and no line is white space only.
    var subject = String("")
    for i in range(30):
        subject += "x" + String(i) + "  \t "
    subject += "tail"
    var b = _builder()
    b.add_header("X-Note", subject)
    var built = b.build()
    _check_lines(built, 76)
    var m = parse_message(Span(built))
    assert_equal(_s(m.header("X-Note").value().value()), subject)


def test_word_without_white_space_is_encoded() raises:
    var word = String("")
    for _ in range(1200):
        word += "z"
    var b = _builder()
    b.set_subject(word)
    var built = b.build()
    _check_lines(built, 76)
    var m = parse_message(Span(built))
    assert_equal(m.subject().value(), word)


def test_long_address_lists_fold_between_addresses() raises:
    var b = _builder()
    for i in range(20):
        b.add_to(String("Recipient ") + String(i), AddrSpec(String("r") + String(i), "example.com"))
    b.add_cc("Zoë Ünïcödé-Lastname-That-Is-Long Ωmega", AddrSpec("z", "example.com"))
    var built = b.build()
    _check_lines(built, 76)
    assert_true(_header_lines(built, "To") > 1)


comptime TOO_LONG = "komira_mail_message.LineTooLong: MessageBuilder.build: a header line longer than 998 octets with no white space to fold at"


def _name(length: Int) -> String:
    """A field name of `length` octets."""
    var name = String("X-")
    for _ in range(length - 2):
        name += "n"
    return name^


def _build_error(name: String, value: String) raises -> String:
    var b = _builder()
    b.add_header(name, value)
    try:
        _ = b.build()
    except e:
        return String(e)
    return String("OK")


def _longest_line(built: List[UInt8]) -> Int:
    var longest = 0
    var start = 0
    for i in range(len(built)):
        if built[i] == 10:
            longest = max(longest, i - 1 - start)
            start = i + 1
    return longest


def test_998_octet_boundary() raises:
    # RFC 5322 section 2.1.1: 998 octets is the longest line. `Name: ` with
    # an empty value takes len(name) + 2 octets.
    assert_equal(_build_error(_name(996), ""), "OK")
    assert_equal(_build_error(_name(997), ""), TOO_LONG)
    # A value with no white space to cut at: 994 + 2 + 2 = 998 is written,
    # one octet more is refused.
    assert_equal(_build_error(_name(994), "vv"), "OK")
    assert_equal(_build_error(_name(994), "vvv"), TOO_LONG)
    var b = _builder()
    b.add_header(_name(994), "vv")
    var built = b.build()
    assert_equal(_longest_line(built), 998)
    var m = parse_message(Span(built))
    assert_equal(_s(m.header(_name(994)).value().value()), "vv")
    var e = _builder()
    e.add_header(_name(996), "")
    built = e.build()
    assert_equal(_longest_line(built), 998)


def test_long_name_first_word_holds_one_whole_character() raises:
    # After a 58-octet name the first encoded word's limit is clamped to 16
    # characters: 4 for the text, less than the 8 of one 4-byte character in
    # B form. That character still goes whole into the first word, never
    # split into bytes that are not UTF-8 on their own.
    var b = _builder()
    b.add_header(_name(58), "😀")
    var built = b.build()
    assert_true(_s(built).find("=?UTF-8?B?8J+YgA==?=") >= 0, _s(built))
    var m = parse_message(Span(built))
    assert_equal(m.header(_name(58)).value().text(), "😀")


def main() raises:
    test_long_subject_folds_at_76()
    test_field_over_998_octets_is_folded()
    test_runs_of_white_space_survive_folding()
    test_word_without_white_space_is_encoded()
    test_long_address_lists_fold_between_addresses()
    test_998_octet_boundary()
    test_long_name_first_word_holds_one_whole_character()
    print("test_folding: OK")
