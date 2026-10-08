# Header folding (RFC 5322 sections 2.1.1 and 2.2.3, RFC 2047 section 2):
# every line the builder writes is at most 76 characters when the value has
# white space to fold at, a field longer than 998 octets is folded rather
# than written as one line, unfolding gives back the exact value, a folded
# line is never white space only, and a line that cannot be folded under 998
# octets is refused. A value with no white space (or non-ASCII) becomes
# encoded words, which fold.

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


def test_unfoldable_line_is_refused() raises:
    # A field name of 1,000 octets leaves no place to fold.
    var name = String("X-")
    for _ in range(998):
        name += "n"
    var b = _builder()
    b.add_header(name, "v")
    var msg = String("")
    try:
        _ = b.build()
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "komira_mail_message.LineTooLong: MessageBuilder.build: a header line longer than 998 octets with no white space to fold at",
    )


def main() raises:
    test_long_subject_folds_at_76()
    test_field_over_998_octets_is_folded()
    test_runs_of_white_space_survive_folding()
    test_word_without_white_space_is_encoded()
    test_long_address_lists_fold_between_addresses()
    test_unfoldable_line_is_refused()
    print("test_folding: OK")
