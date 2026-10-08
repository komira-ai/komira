# =============================================================================
# test_round_trip.mojo -- parse(emit(x)) == x over generated contacts, unknown
# properties surviving a re-export, and the writer's refusals.
# =============================================================================
#
# What each test proves (and the defect it catches):
#   property_round_trip    500 contacts from a fixed-seed generator, with
#                          values drawn from an alphabet of the characters
#                          the writer must escape or fold around (\ , ; :
#                          " ^ line feed, 2- 3- and 4-octet characters) and
#                          lengths that cross the 75-octet fold, each read
#                          back equal to what was written. Any asymmetry in
#                          escaping, splitting, folding, TYPE/PREF tags,
#                          groups and labels, or the TEL uri rule fails it.
#   unknown_survive        a vCard 3.0 export's unknown and repeated
#                          properties come back from read -> write -> read
#                          as the same `extra` lines (a writer that drops
#                          `extra`, or a reader that maps them, fails).
#   emit_golden            the exact 4.0 text for one contact, including
#                          the synthesised `item1` group for a label.
#   emit_refusals          a value cannot inject a line; a group or an
#                          `extra` line that would is refused, exactly, and
#                          each of BEGIN:VCARD, END:VCARD and VERSION is
#                          refused as an `extra` line (dropping any one arm
#                          of the guard lets it start a card or repeat
#                          VERSION).
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_vcard import (
    Contact,
    ContactAddress,
    ContactValue,
    emit_contact,
    emit_contacts,
    parse_contacts,
)


struct _Rng(Movable):
    var s: UInt64

    def __init__(out self, seed: UInt64):
        self.s = seed

    def next(mut self) -> Int:
        # xorshift64*
        self.s ^= self.s >> 12
        self.s ^= self.s << 25
        self.s ^= self.s >> 27
        return Int((self.s * 2685821657736338717) >> 33)

    def below(mut self, n: Int) -> Int:
        return self.next() % n


def _alphabet() -> List[String]:
    var a: List[String] = [
        String("a"), String("b"), String("Z"), String("0"), String(" "),
        String("\\"), String(","), String(";"), String(":"), String('"'),
        String("^"), String("\n"), String("="), String("é"), String("ß"),
        String("日"), String("本"), String("😀"), String("\t"), String("."),
    ]
    return a^


def _strs(var xs: List[String]) -> List[String]:
    return xs^


def _text(mut r: _Rng, alpha: List[String], max_len: Int) -> String:
    var n = r.below(max_len + 1)
    var out = String()
    for _ in range(n):
        out += alpha[r.below(len(alpha))]
    return out^


def _list(mut r: _Rng, alpha: List[String], max_n: Int) -> List[String]:
    var out = List[String]()
    for _ in range(1 + r.below(max_n)):
        out.append(_text(r, alpha, 12))
    return out^


def _types(mut r: _Rng) -> List[String]:
    var pool = _strs(
        [
            String("work"),
            String("home"),
            String("cell"),
            String("voice"),
            String("fax"),
            String("x-custom"),
        ]
    )
    var out = List[String]()
    for _ in range(r.below(3)):
        out.append(pool[r.below(len(pool))])
    return out^


def _value(
    mut r: _Rng, alpha: List[String], mut group_no: Int, tel: Bool
) -> ContactValue:
    var v: ContactValue
    if tel and r.below(3) == 0:
        v = ContactValue(String("tel:+1-555-0") + String(r.below(1000)) + ";ext=7")
    else:
        v = ContactValue(_text(r, alpha, 30))
    v.types = _types(r)
    v.pref = r.below(4) * 30
    if r.below(2) == 0:
        group_no += 1
        v.group = String("item") + String(group_no)
        if r.below(2) == 0:
            v.label = _text(r, alpha, 10)
    return v^


def _contact(mut r: _Rng, alpha: List[String]) -> Contact:
    var c = Contact()
    var kinds = _strs(
        [String("individual"), String("org"), String("group"), String("location")]
    )
    c.kind = kinds[r.below(len(kinds))]
    if r.below(2) == 0:
        c.uid = String("urn:uuid:") + String(r.next())
    c.full_name = _text(r, alpha, 90)
    if r.below(3) > 0:
        for _ in range(5 + r.below(3)):
            c.name.append(_list(r, alpha, 3))
    if r.below(2) == 0:
        c.nicknames = _list(r, alpha, 3)
    if r.below(2) == 0:
        c.organization = _list(r, alpha, 3)
    c.title = _text(r, alpha, 20)
    var group_no = 0
    for _ in range(r.below(3)):
        c.emails.append(_value(r, alpha, group_no, False))
    for _ in range(r.below(3)):
        c.phones.append(_value(r, alpha, group_no, True))
    for _ in range(r.below(3)):
        c.urls.append(_value(r, alpha, group_no, False))
    for _ in range(r.below(3)):
        var parts = List[List[String]]()
        for _ in range(7):
            parts.append(_list(r, alpha, 2))
        var a = ContactAddress(parts^)
        a.types = _types(r)
        a.pref = r.below(2)
        if r.below(2) == 0:
            group_no += 1
            a.group = String("item") + String(group_no)
            a.label = _text(r, alpha, 8)
        c.addresses.append(a^)
    c.birthday = String("--0") + String(1 + r.below(9)) + "15"
    c.note = _text(r, alpha, 200)
    for _ in range(r.below(3)):
        c.members.append(String("urn:uuid:m-") + String(r.next()))
    for k in range(r.below(3)):
        c.extra.append(
            String("X-KOMIRA-TEST-")
            + String(k)
            + ";X-P=\"q;r\":"
            + _text(r, alpha, 100).replace("\n", "\\n")
        )
    return c^


def test_property_round_trip() raises:
    var alpha = _alphabet()
    var r = _Rng(0x9E3779B97F4A7C15)
    var batch = List[Contact]()
    for i in range(500):
        var c = _contact(r, alpha)
        var text = emit_contact(c)
        var back = parse_contacts(text.as_bytes())
        assert_equal(len(back.contacts), 1)
        assert_equal(len(back.dropped), 0)
        if not (back.contacts[0] == c):
            print("round trip", i, "differs; emitted:")
            print(text)
            assert_true(False, "parse(emit(x)) != x")
        batch.append(c^)
    var all = parse_contacts(emit_contacts(batch).as_bytes())
    assert_equal(len(all.contacts), 500)
    print("  test_property_round_trip PASS")


def test_unknown_survive() raises:
    var s = String(
        "BEGIN:VCARD\r\nVERSION:3.0\r\n"
        "PRODID:-//Example//Contacts 1.0//EN\r\n"
        "FN:A\r\n"
        "X-SOCIALPROFILE;type=example:https://example.com/a\r\n"
        "IMPP;X-SERVICE-TYPE=Jabber;type=pref:xmpp:a@example.com\r\n"
        "REV:2026-09-03T10:00:00Z\r\n"
        "TITLE:Lead\r\nTITLE:Second title\r\n"
        "END:VCARD\r\n"
    )
    var first = parse_contacts(s.as_bytes())
    var second = parse_contacts(emit_contacts(first.contacts).as_bytes())
    ref a = first.contacts[0]
    ref b = second.contacts[0]
    assert_equal(len(a.extra), 5)
    assert_equal(a.extra[3], "REV:2026-09-03T10:00:00Z")
    assert_equal(a.extra[4], "TITLE:Second title")
    assert_true(a == b)
    print("  test_unknown_survive PASS")


def test_emit_golden() raises:
    var c = Contact()
    c.full_name = "Doe, Jr.; J\\D"
    c.name.append(_strs([String("Doe, Jr.")]))
    c.name.append(_strs([String("John")]))
    c.name.append(List[String]())
    c.name.append(_strs([String("Dr."), String("Prof.")]))
    c.name.append(_strs([String("")]))
    var e = ContactValue("j@example.com")
    e.types = _strs([String("work")])
    e.pref = 1
    e.label = "Main"
    c.emails.append(e^)
    var t = ContactValue("tel:+1-555-555-5555;ext=5555")
    t.types = _strs([String("voice"), String("home")])
    c.phones.append(t^)
    c.note = "line one\nline two"
    var want = String(
        "BEGIN:VCARD\r\n"
        "VERSION:4.0\r\n"
        "FN:Doe\\, Jr.\\; J\\\\D\r\n"
        "N:Doe\\, Jr.;John;;Dr.,Prof.;\r\n"
        "item1.EMAIL;TYPE=work;PREF=1:j@example.com\r\n"
        "item1.X-ABLabel:Main\r\n"
        "TEL;VALUE=uri;TYPE=voice,home:tel:+1-555-555-5555;ext=5555\r\n"
        "NOTE:line one\\nline two\r\n"
        "END:VCARD\r\n"
    )
    assert_equal(emit_contact(c), want)
    print("  test_emit_golden PASS")


def _emit_err(c: Contact) -> String:
    try:
        _ = emit_contact(c)
    except e:
        return String(e)
    return String("no error")


def test_emit_refusals() raises:
    var c = Contact()
    c.full_name = "x\r\nEND:VCARD\r\nBEGIN:VCARD\r\nFN:injected"
    var text = emit_contact(c)
    var back = parse_contacts(text.as_bytes())
    assert_equal(len(back.contacts), 1)
    assert_equal(back.contacts[0].full_name, "x\nEND:VCARD\nBEGIN:VCARD\nFN:injected")
    var g = Contact()
    var v = ContactValue("a@example.com")
    v.group = "a\r\nX"
    g.emails.append(v^)
    assert_equal(
        _emit_err(g),
        "content line: group 'a\r\nX' has a character outside ALPHA, DIGIT"
        " and '-'",
    )
    var x = Contact()
    x.extra.append("X-A:1\r\nEND:VCARD")
    assert_equal(_emit_err(x), "vcard: extra line 1 holds a line break")
    var y = Contact()
    y.extra.append("END:vcard")
    assert_equal(
        _emit_err(y),
        "vcard: extra line 1 is a BEGIN:VCARD, END:VCARD or VERSION line",
    )
    var yb = Contact()
    yb.extra.append("BEGIN:VCARD")
    assert_equal(
        _emit_err(yb),
        "vcard: extra line 1 is a BEGIN:VCARD, END:VCARD or VERSION line",
    )
    var yv = Contact()
    yv.extra.append("VERSION:3.0")
    assert_equal(
        _emit_err(yv),
        "vcard: extra line 1 is a BEGIN:VCARD, END:VCARD or VERSION line",
    )
    var z = Contact()
    z.extra.append("not a content line")
    assert_equal(
        _emit_err(z),
        "content line: line 1 has an invalid character in the property name",
    )
    print("  test_emit_refusals PASS")


def main() raises:
    print("test_round_trip")
    test_property_round_trip()
    test_unknown_survive()
    test_emit_golden()
    test_emit_refusals()
    print("ALL TESTS PASS")
