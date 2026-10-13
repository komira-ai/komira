# =============================================================================
# test_lexer_records.mojo -- parse_content_line, format_content_line and the
# Param / ContentLine records, checked as whole objects.
# =============================================================================
#
# Every fixture of `_fixtures()` is a line and either the whole ContentLine
# RFC 6350 §3.3 / RFC 5545 §3.1 / RFC 6868 make of it or the exact error.
# Every fixture goes through every checker: parse (compared field by field
# with `_diff` AND with `==`), format of the parsed record (exact canonical
# text), and parse of that text (the same record again).
#
# What each test proves (and the defect it catches):
#   fixtures              group kept as written and name upper-cased; bare,
#                         empty, multi-valued, quoted and caret-encoded
#                         parameters; the value is everything after the first
#                         ':' outside quotes. A dropped or swapped field, a
#                         lost has_value, a wrong caret decode (`^n`, `^'`,
#                         `^^` first, middle, last, `^` at the end, `^N`
#                         kept), a mis-split value list, a value boundary
#                         moved by a quoted ':' all change one field.
#   refusals              every parse refusal with its exact message and the
#                         caller's line number (0, 1 and 42), including a
#                         line that ends inside the parameters after an
#                         unquoted value, a quoted value or a trailing ','
#                         ("has no ':' after the property name").
#   record_equality       Param.__eq__ and ContentLine.__eq__ compare every
#                         field: a pair differing in exactly one field is
#                         unequal, identical pairs are equal (a dropped
#                         conjunct makes one pair equal).
#   param_lookup          `param(name)` finds the first of two same-named
#                         parameters, one in the last position, and None for
#                         an absent name.
#   name_octet_grid       every ASCII octet in a property name, a group and a
#                         parameter name of `format_content_line`: allowed
#                         exactly for ALPHA, DIGIT and '-' (the boundaries
#                         '/', '0', '9', ':', '@', 'A', 'Z', '[', '`', 'a',
#                         'z', '{' and ',', '-', '.').
#   token_positions       a bad octet first, in the middle and last of each
#                         token kind is refused (a loop that skips the first
#                         or the last octet); an empty name and an empty
#                         parameter name are refused; an empty group writes
#                         no group.
#   encode_grid           each octet that needs care (LF, DQUOTE, '^', ',',
#                         ';', ':', CR) first, in the middle and last of a
#                         parameter value, and 0, 1 and 2 values: the exact
#                         written text (RFC 6868 encoding, quoting only for
#                         ',', ';', ':'), and it reads back to the values.
#   value_line_breaks     CR and LF first, in the middle and last of the
#                         value are refused; an empty value is written.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_content_line import (
    ContentLine,
    Param,
    format_content_line,
    parse_content_line,
)


# --- whole-record comparison ------------------------------------------------


def _show_values(v: List[String]) -> String:
    var out = String("[")
    for k in range(len(v)):
        if k > 0:
            out += ", "
        out += String("<") + v[k] + String(">")
    return out + String("]")


def _diff(got: ContentLine, want: ContentLine) -> String:
    """The first field where `got` and `want` differ, or the empty string.
    Reads every field of the record and of every parameter."""
    if got.group != want.group:
        return String("group <") + got.group + String("> != <") + want.group + String(">")
    if got.name != want.name:
        return String("name <") + got.name + String("> != <") + want.name + String(">")
    if got.value != want.value:
        return String("value <") + got.value + String("> != <") + want.value + String(">")
    if len(got.params) != len(want.params):
        return String("param count ") + String(len(got.params)) + String(" != ") + String(len(want.params))
    for k in range(len(got.params)):
        ref g = got.params[k]
        ref w = want.params[k]
        var at = String("param ") + String(k) + String(" ")
        if g.name != w.name:
            return at + String("name <") + g.name + String("> != <") + w.name + String(">")
        if g.has_value != w.has_value:
            return at + String("has_value ") + String(g.has_value) + String(" != ") + String(w.has_value)
        if len(g.values) != len(w.values):
            return at + _show_values(g.values) + String(" != ") + _show_values(w.values)
        for j in range(len(g.values)):
            if g.values[j] != w.values[j]:
                return at + _show_values(g.values) + String(" != ") + _show_values(w.values)
    return String()


def _vals(a: String) -> List[String]:
    var v = List[String]()
    v.append(a)
    return v^


def _vals(a: String, b: String) -> List[String]:
    var v = List[String]()
    v.append(a)
    v.append(b)
    return v^


def _vals(a: String, b: String, c: String) -> List[String]:
    var v = List[String]()
    v.append(a)
    v.append(b)
    v.append(c)
    return v^


def _cl(group: String, name: String, value: String) -> ContentLine:
    return ContentLine(group, name, List[Param](), value)


def _cl(group: String, name: String, p0: Param, value: String) -> ContentLine:
    var ps = List[Param]()
    ps.append(p0.copy())
    return ContentLine(group, name, ps^, value)


def _cl(group: String, name: String, p0: Param, p1: Param, value: String) -> ContentLine:
    var ps = List[Param]()
    ps.append(p0.copy())
    ps.append(p1.copy())
    return ContentLine(group, name, ps^, value)


# --- fixtures ---------------------------------------------------------------


struct _Fixture(Copyable, Movable):
    var text: String
    var want: ContentLine
    # What format_content_line writes for the parsed record.
    var canonical: String

    def __init__(out self, text: String, var want: ContentLine, canonical: String):
        self.text = text
        self.want = want^
        self.canonical = canonical


def _fixtures() -> List[_Fixture]:
    var f = List[_Fixture]()
    f.append(_Fixture("FN:x", _cl("", "FN", "x"), "FN:x"))
    f.append(_Fixture("fn:", _cl("", "FN", ""), "FN:"))
    f.append(_Fixture("n:a:b;c", _cl("", "N", "a:b;c"), "N:a:b;c"))
    f.append(_Fixture("g.n:v", _cl("g", "N", "v"), "g.N:v"))
    f.append(_Fixture("Item-9.x-Ab0:v", _cl("Item-9", "X-AB0", "v"), "Item-9.X-AB0:v"))
    f.append(_Fixture('N:"q";r,s', _cl("", "N", '"q";r,s'), 'N:"q";r,s'))
    # Bare parameters (vCard 2.1), one and two, upper-cased.
    f.append(_Fixture("TEL;work:1", _cl("", "TEL", Param(bare="WORK"), "1"), "TEL;WORK:1"))
    f.append(_Fixture(
        "TEL;Work;voice:1",
        _cl("", "TEL", Param(bare="WORK"), Param(bare="VOICE"), "1"),
        "TEL;WORK;VOICE:1",
    ))
    # An empty value is a value: has_value with one empty string.
    f.append(_Fixture("X;a=:v", _cl("", "X", Param("A", _vals("")), "v"), "X;A=:v"))
    f.append(_Fixture("X;A=,:v", _cl("", "X", Param("A", _vals("", "")), "v"), "X;A=,:v"))
    f.append(_Fixture("X;A=b,c,d:v", _cl("", "X", Param("A", _vals("b", "c", "d")), "v"), "X;A=b,c,d:v"))
    f.append(_Fixture('X;A="",b:v', _cl("", "X", Param("A", _vals("", "b")), "v"), "X;A=,b:v"))
    f.append(_Fixture(
        'X;A="x,y;z:w";B=c:v',
        _cl("", "X", Param("A", _vals("x,y;z:w")), Param("B", _vals("c")), "v"),
        'X;A="x,y;z:w";B=c:v',
    ))
    f.append(_Fixture(
        'X;A=b;C="d":v:w',
        _cl("", "X", Param("A", _vals("b")), Param("C", _vals("d")), "v:w"),
        "X;A=b;C=d:v:w",
    ))
    f.append(_Fixture(
        "X;A=b;FLAG:v",
        _cl("", "X", Param("A", _vals("b")), Param(bare="FLAG"), "v"),
        "X;A=b;FLAG:v",
    ))
    # RFC 6868: ^n, ^' and ^^ first, in the middle and last; '^' before any
    # other octet, before an upper-case N and at the very end is kept.
    f.append(_Fixture(
        "X;A=^nb^'c^^:v",
        _cl("", "X", Param("A", _vals("\nb\"c^")), "v"),
        "X;A=^nb^'c^^:v",
    ))
    f.append(_Fixture(
        "X;A=^'^^^n:v",
        _cl("", "X", Param("A", _vals("\"^\n")), "v"),
        "X;A=^'^^^n:v",
    ))
    f.append(_Fixture("X;A=^N^x:v", _cl("", "X", Param("A", _vals("^N^x")), "v"), "X;A=^^N^^x:v"))
    f.append(_Fixture("X;A=a^:v", _cl("", "X", Param("A", _vals("a^")), "v"), "X;A=a^^:v"))
    f.append(_Fixture("X;A=^^^:v", _cl("", "X", Param("A", _vals("^^")), "v"), "X;A=^^^^:v"))
    f.append(_Fixture(
        'X;A="^n,^\'":v',
        _cl("", "X", Param("A", _vals("\n,\"")), "v"),
        "X;A=\"^n,^'\":v",
    ))
    f.append(_Fixture("X;A=b,^^:v", _cl("", "X", Param("A", _vals("b", "^")), "v"), "X;A=b,^^:v"))
    return f^


def test_fixtures() raises:
    var f = _fixtures()
    assert_equal(len(f), 22)
    for i in range(len(f)):
        var got = parse_content_line(f[i].text, 1)
        assert_equal(_diff(got, f[i].want), "", String("parse of ") + f[i].text)
        assert_true(got == f[i].want, String("== after parse of ") + f[i].text)
        var text = format_content_line(got)
        assert_equal(text, f[i].canonical, String("format of ") + f[i].text)
        var again = parse_content_line(text, 1)
        assert_equal(_diff(again, f[i].want), "", String("re-parse of ") + text)
    print("  test_fixtures PASS")


def _lex_err(text: String, line_number: Int) -> String:
    try:
        _ = parse_content_line(text, line_number)
    except e:
        return String(e)
    return String("no error")


def test_refusals() raises:
    var texts = List[String]()
    var whats = List[String]()
    texts.append(""); whats.append("has an empty property name")
    texts.append("FN"); whats.append("has no ':' after the property name")
    texts.append("g.FN"); whats.append("has no ':' after the property name")
    texts.append("g."); whats.append("has an empty property name")
    texts.append(".FN:x"); whats.append("has an empty group name")
    texts.append(".:x"); whats.append("has an empty group name")
    texts.append(":x"); whats.append("has an empty property name")
    texts.append("g.:x"); whats.append("has an empty property name")
    texts.append("F N:x"); whats.append("has an invalid character in the property name")
    texts.append("FN=x"); whats.append("has an invalid character in the property name")
    texts.append("F_N:x"); whats.append("has an invalid character in the property name")
    texts.append("FN;:x"); whats.append("has an empty parameter name")
    texts.append("FN;;:x"); whats.append("has an empty parameter name")
    texts.append("FN;A;:x"); whats.append("has an empty parameter name")
    texts.append("FN;A B=x:z"); whats.append("has an invalid character in a parameter name")
    texts.append("FN;A_B:z"); whats.append("has an invalid character in a parameter name")
    texts.append('FN;A="x'); whats.append("has an unterminated quoted parameter value")
    texts.append('FN;A="'); whats.append("has an unterminated quoted parameter value")
    texts.append('FN;A=b,"x:y'); whats.append("has an unterminated quoted parameter value")
    texts.append('FN;A="x"y:z'); whats.append("has a character after a quoted parameter value")
    texts.append('FN;A="x""y":z'); whats.append("has a character after a quoted parameter value")
    texts.append('FN;A=x"y:z'); whats.append("has a DQUOTE inside an unquoted parameter value")
    texts.append('FN;A=x":z'); whats.append("has a DQUOTE inside an unquoted parameter value")
    texts.append('FN;A=b,c"d:z'); whats.append("has a DQUOTE inside an unquoted parameter value")
    # The line ends inside the parameters: after an unquoted value, a quoted
    # value, a trailing ',' and a second parameter.
    texts.append("FN;A=b"); whats.append("has no ':' after the property name")
    texts.append('FN;A="b"'); whats.append("has no ':' after the property name")
    texts.append("FN;A=b,"); whats.append("has no ':' after the property name")
    texts.append("FN;A=b;C=d"); whats.append("has no ':' after the property name")
    texts.append("FN;A="); whats.append("has no ':' after the property name")
    assert_equal(len(texts), len(whats))
    var numbers = List[Int]()
    numbers.append(0)
    numbers.append(1)
    numbers.append(42)
    for i in range(len(texts)):
        for k in range(len(numbers)):
            assert_equal(
                _lex_err(texts[i], numbers[k]),
                String("content line: line ")
                + String(numbers[k])
                + String(" ")
                + whats[i],
                String("text <") + texts[i] + String(">"),
            )
    print("  test_refusals PASS")


def test_record_equality() raises:
    var base = Param("A", _vals("b", "c"))
    assert_true(base == Param("A", _vals("b", "c")))
    assert_false(base == Param("B", _vals("b", "c")))
    assert_false(base == Param("A", _vals("b", "d")))
    assert_false(base == Param("A", _vals("b")))
    # Same name, same (empty) values, differing only in has_value.
    var bare = Param(bare="A")
    var empty = Param("A", List[String]())
    assert_true(bare == Param(bare="A"))
    assert_false(bare == empty)
    assert_false(empty == bare)
    assert_true(empty == Param("A", List[String]()))
    var line = _cl("g", "N", base.copy(), "v")
    assert_true(line == _cl("g", "N", base.copy(), "v"))
    assert_false(line == _cl("h", "N", base.copy(), "v"))
    assert_false(line == _cl("g", "M", base.copy(), "v"))
    assert_false(line == _cl("g", "N", Param("A", _vals("b")), "v"))
    assert_false(line == _cl("g", "N", base.copy(), "w"))
    assert_false(line == _cl("g", "N", "v"))
    print("  test_record_equality PASS")


def test_param_lookup() raises:
    var cl = parse_content_line("X;A=1;B;A=2;C=3:v", 1)
    var a = cl.param("A")
    assert_true(Bool(a))
    assert_true(a.value() == Param("A", _vals("1")))
    var c = cl.param("C")
    assert_true(Bool(c))
    assert_true(c.value() == Param("C", _vals("3")))
    var b = cl.param("B")
    assert_true(Bool(b))
    assert_true(b.value() == Param(bare="B"))
    assert_false(Bool(cl.param("D")))
    assert_false(Bool(cl.param("a")))
    assert_false(Bool(parse_content_line("X:v", 1).param("A")))
    print("  test_param_lookup PASS")


# --- the writer -------------------------------------------------------------


def _fmt_err(cl: ContentLine) -> String:
    try:
        return format_content_line(cl)
    except e:
        return String("error: ") + String(e)


def _token_err(what: String, token: String) -> String:
    return (
        String("error: content line: ")
        + what
        + String(" '")
        + token
        + String("' has a character outside ALPHA, DIGIT and '-'")
    )


def test_name_octet_grid() raises:
    var allowed = String(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-"
    )
    var ok = 0
    for c in range(1, 128):
        var ch = chr(c)
        var tok = String("A") + ch + String("B")
        var good = allowed.find(ch) >= 0
        if good:
            ok += 1
        var name_want = _token_err("property name", tok)
        var group_want = _token_err("group", tok)
        var param_want = _token_err("parameter name", tok)
        if good:
            name_want = tok + String(":v")
            group_want = tok + String(".N:v")
            param_want = String("N;") + tok + String(":v")
        assert_equal(_fmt_err(_cl("", tok, "v")), name_want)
        assert_equal(_fmt_err(_cl(tok, "N", "v")), group_want)
        assert_equal(_fmt_err(_cl("", "N", Param(bare=tok), "v")), param_want)
    assert_equal(ok, 63)
    print("  test_name_octet_grid PASS")


def test_token_positions() raises:
    var toks = List[String]()
    toks.append("=AB")
    toks.append("A=B")
    toks.append("AB=")
    toks.append("=")
    for i in range(len(toks)):
        var t = toks[i]
        assert_equal(_fmt_err(_cl("", t, "v")), _token_err("property name", t))
        assert_equal(_fmt_err(_cl(t, "N", "v")), _token_err("group", t))
        assert_equal(
            _fmt_err(_cl("", "N", Param(bare=t), "v")),
            _token_err("parameter name", t),
        )
        assert_equal(
            _fmt_err(_cl("", "N", Param(t, _vals("x")), "v")),
            _token_err("parameter name", t),
        )
        # The second parameter's name is checked too.
        assert_equal(
            _fmt_err(_cl("", "N", Param(bare="OK"), Param(bare=t), "v")),
            _token_err("parameter name", t),
        )
    # A group is checked before the name, the name before the parameters.
    assert_equal(_fmt_err(_cl("=g", "=n", Param(bare="=p"), "v")), _token_err("group", "=g"))
    assert_equal(_fmt_err(_cl("", "=n", Param(bare="=p"), "v")), _token_err("property name", "=n"))
    # Empty tokens.
    assert_equal(_fmt_err(_cl("", "", "v")), "error: content line: empty property name")
    assert_equal(_fmt_err(_cl("g", "", "v")), "error: content line: empty property name")
    assert_equal(
        _fmt_err(_cl("", "N", Param(bare=""), "v")),
        "error: content line: empty parameter name",
    )
    assert_equal(
        _fmt_err(_cl("", "N", Param("", _vals("x")), "v")),
        "error: content line: empty parameter name",
    )
    # An empty group writes no group and no '.'.
    assert_equal(_fmt_err(_cl("", "N", "v")), "N:v")
    print("  test_token_positions PASS")


def test_encode_grid() raises:
    # (octet in the value, how it is written, whether it forces quotes)
    var raw = List[String]()
    var enc = List[String]()
    var quotes = List[Bool]()
    raw.append("\n"); enc.append("^n"); quotes.append(False)
    raw.append('"'); enc.append("^'"); quotes.append(False)
    raw.append("^"); enc.append("^^"); quotes.append(False)
    raw.append(","); enc.append(","); quotes.append(True)
    raw.append(";"); enc.append(";"); quotes.append(True)
    raw.append(":"); enc.append(":"); quotes.append(True)
    raw.append("x"); enc.append("x"); quotes.append(False)
    var checked = 0
    for r in range(len(raw)):
        for pos in range(3):
            var value: String
            var written: String
            if pos == 0:
                value = raw[r] + String("ab")
                written = enc[r] + String("ab")
            elif pos == 1:
                value = String("a") + raw[r] + String("b")
                written = String("a") + enc[r] + String("b")
            else:
                value = String("ab") + raw[r]
                written = String("ab") + enc[r]
            if quotes[r]:
                written = String('"') + written + String('"')
            # 1 value, then the same value twice (both written, ',' between).
            var one = _cl("", "X", Param("P", _vals(value)), "v")
            assert_equal(_fmt_err(one), String("X;P=") + written + String(":v"))
            var back = parse_content_line(format_content_line(one), 1)
            assert_equal(_diff(back, one), "", String("re-parse of ") + value)
            var two = _cl("", "X", Param("P", _vals(value, value)), "v")
            assert_equal(
                _fmt_err(two),
                String("X;P=") + written + String(",") + written + String(":v"),
            )
            var back2 = parse_content_line(format_content_line(two), 1)
            assert_equal(_diff(back2, two), "", String("re-parse of two ") + value)
            checked += 1
    assert_equal(checked, 21)
    # Two octets that need encoding next to each other, and every kind in
    # one value: each is replaced once, nothing between them is lost.
    var all = _cl("", "X", Param("P", _vals("\n\"^,;:x^\n")), "v")
    assert_equal(_fmt_err(all), "X;P=\"^n^'^^,;:x^^^n\":v")
    # Zero values with has_value: the '=' with nothing after it.
    assert_equal(_fmt_err(_cl("", "X", Param("P", List[String]()), "v")), "X;P=:v")
    # One empty value, and an empty value between two.
    assert_equal(_fmt_err(_cl("", "X", Param("P", _vals("")), "v")), "X;P=:v")
    assert_equal(_fmt_err(_cl("", "X", Param("P", _vals("a", "", "b")), "v")), "X;P=a,,b:v")
    # A CR first, in the middle and last of a value, and in the second value.
    var crs = List[String]()
    crs.append("\rab")
    crs.append("a\rb")
    crs.append("ab\r")
    for i in range(len(crs)):
        assert_equal(
            _fmt_err(_cl("", "X", Param("P", _vals(crs[i])), "v")),
            "error: content line: a parameter value holds a CR",
        )
        assert_equal(
            _fmt_err(_cl("", "X", Param("P", _vals("ok", crs[i])), "v")),
            "error: content line: a parameter value holds a CR",
        )
    print("  test_encode_grid PASS")


def test_value_line_breaks() raises:
    var bad = List[String]()
    bad.append("\rab")
    bad.append("a\rb")
    bad.append("ab\r")
    bad.append("\nab")
    bad.append("a\nb")
    bad.append("ab\n")
    for i in range(len(bad)):
        assert_equal(
            _fmt_err(_cl("", "NOTE", bad[i])),
            "error: content line: the value of NOTE holds a line break",
        )
    assert_equal(_fmt_err(_cl("", "NOTE", "")), "NOTE:")
    assert_equal(_fmt_err(_cl("", "NOTE", "a\tb")), "NOTE:a\tb")
    print("  test_value_line_breaks PASS")


def main() raises:
    print("test_lexer_records")
    test_fixtures()
    test_refusals()
    test_record_equality()
    test_param_lookup()
    test_name_octet_grid()
    test_token_positions()
    test_encode_grid()
    test_value_line_breaks()
    print("ALL TESTS PASS")
