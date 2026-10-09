# =============================================================================
# test_contacts.mojo -- the card-to-Contact mapping, line by line.
# =============================================================================
#
# What each test proves (and the defect it catches):
#   n_escaped_comma        `N:Doe\, Jr.;John;;;` has ONE family value
#                          "Doe, Jr." (the "unescape before splitting N/ADR"
#                          mutant gives two: "Doe" and " Jr.").
#   adr_escaped_semicolon  `\;` inside an ADR street stays in the street.
#   apple_groups           `item1.EMAIL` maps to an email (the "drop the
#                          group strip" mutant leaves it unmapped) and
#                          `item1.X-ABLabel` becomes its label.
#   tags_by_version        3.0 TYPE=pref and TYPE lists, 2.1 bare
#                          parameters and bare PREF, 4.0 PREF=n, quoted
#                          TYPE="work,voice"; all read to types + pref.
#   tel_uri_kept_raw       TEL;VALUE=uri keeps `;ext=` (it is not unescaped
#                          or split).
#   dropped_report         parameters a mapping does not keep are named,
#                          exactly; a PREF outside 1..100 is one of them.
#   extra_kept_verbatim    unknown properties, a second FN and an X-ABLabel
#                          with no labelled sibling are kept as written.
#   value_text_kept_whole  UID, BDAY, URL and MEMBER with VALUE=text are kept
#                          whole in `extra` (a reader that maps them loses
#                          the value type: UID and URL would be written as
#                          URIs, BDAY as a date); a later UID goes to
#                          `extra` too; VALUE=text on FN is accepted.
#   kind_and_members       KIND defaults to individual and is lower-cased;
#                          MEMBER values are kept in order.
# =============================================================================

from std.testing import assert_equal

from komira_vcard import Contact, parse_contacts


def _one(body: String) raises -> Contact:
    var s = String("BEGIN:VCARD\r\nVERSION:4.0\r\n") + body + "END:VCARD\r\n"
    var got = parse_contacts(s.as_bytes())
    assert_equal(len(got.contacts), 1)
    return got.contacts[0].copy()


def test_n_escaped_comma() raises:
    var c = _one("N:Doe\\, Jr.;John;Q.,R.;Dr.;\r\n")
    assert_equal(len(c.name), 5)
    assert_equal(len(c.name[0]), 1)
    assert_equal(c.name[0][0], "Doe, Jr.")
    assert_equal(c.name[1][0], "John")
    assert_equal(len(c.name[2]), 2)
    assert_equal(c.name[2][1], "R.")
    assert_equal(c.name_component(2), "Q. R.")
    assert_equal(c.name[4][0], "")
    print("  test_n_escaped_comma PASS")


def test_adr_escaped_semicolon() raises:
    var c = _one("ADR;TYPE=home:;;1 Main St\\; Apt 4,Rear;Town;;;\r\n")
    assert_equal(len(c.addresses), 1)
    ref a = c.addresses[0]
    assert_equal(len(a.parts), 7)
    assert_equal(len(a.parts[2]), 2)
    assert_equal(a.parts[2][0], "1 Main St; Apt 4")
    assert_equal(a.component(2), "1 Main St; Apt 4, Rear")
    assert_equal(a.component(3), "Town")
    assert_equal(a.types[0], "home")
    print("  test_adr_escaped_semicolon PASS")


def test_apple_groups() raises:
    var c = _one(
        "item1.EMAIL;type=INTERNET;type=pref:a@example.com\r\n"
        "item1.X-ABLabel:_$!<Other>!$_\r\n"
        "item2.TEL:+1-555-0100\r\n"
        "item2.X-ABLabel:Desk\\, east\r\n"
    )
    assert_equal(len(c.emails), 1)
    assert_equal(c.emails[0].value, "a@example.com")
    assert_equal(c.emails[0].group, "item1")
    assert_equal(c.emails[0].label, "_$!<Other>!$_")
    assert_equal(c.emails[0].pref, 1)
    assert_equal(len(c.emails[0].types), 1)
    assert_equal(c.emails[0].types[0], "internet")
    assert_equal(c.phones[0].label, "Desk, east")
    assert_equal(len(c.extra), 0)
    print("  test_apple_groups PASS")


def test_tags_by_version() raises:
    var c = _one(
        "TEL;TYPE=WORK,VOICE;TYPE=pref:1\r\n"
        "TEL;WORK;FAX;PREF:2\r\n"
        "TEL;PREF=3;TYPE=\"work,cell\":3\r\n"
        "EMAIL:e@example.com\r\n"
    )
    assert_equal(len(c.phones), 3)
    assert_equal(len(c.phones[0].types), 2)
    assert_equal(c.phones[0].types[0], "work")
    assert_equal(c.phones[0].types[1], "voice")
    assert_equal(c.phones[0].pref, 1)
    assert_equal(c.phones[1].types[1], "fax")
    assert_equal(c.phones[1].pref, 1)
    assert_equal(c.phones[2].types[1], "cell")
    assert_equal(c.phones[2].pref, 3)
    assert_equal(c.emails[0].pref, 0)
    assert_equal(len(c.emails[0].types), 0)
    print("  test_tags_by_version PASS")


def test_tel_uri_kept_raw() raises:
    var c = _one(
        'TEL;VALUE=uri;PREF=1;TYPE="voice,home":tel:+1-555-555-5555;ext=5555\r\n'
    )
    assert_equal(c.phones[0].value, "tel:+1-555-555-5555;ext=5555")
    assert_equal(c.phones[0].pref, 1)
    print("  test_tel_uri_kept_raw PASS")


def test_dropped_report() raises:
    var s = String(
        "BEGIN:VCARD\r\nVERSION:4.0\r\nFN;LANGUAGE=en:A\r\nEND:VCARD\r\n"
        "BEGIN:VCARD\r\nVERSION:4.0\r\nFN;VALUE=text:B\r\n"
        "EMAIL;PREF=101;X-Y=z:b@example.com\r\n"
        'N;SORT-AS="B":B;;;;\r\nEND:VCARD\r\n'
    )
    var got = parse_contacts(s.as_bytes())
    assert_equal(len(got.dropped), 4)
    assert_equal(got.dropped[0], "card 1 line 3: FN parameter LANGUAGE not kept")
    assert_equal(got.dropped[1], "card 2 line 8: EMAIL parameter PREF not kept")
    assert_equal(got.dropped[2], "card 2 line 8: EMAIL parameter X-Y not kept")
    assert_equal(got.dropped[3], "card 2 line 9: N parameter SORT-AS not kept")
    assert_equal(got.contacts[1].emails[0].pref, 0)
    print("  test_dropped_report PASS")


def test_extra_kept_verbatim() raises:
    var c = _one(
        "FN:First\r\n"
        "X-Custom;x-p=\"a:b\":v\\,w\r\n"
        "FN:Second\r\n"
        "item9.X-ABLabel:orphan\r\n"
        "PHOTO;MEDIATYPE=image/png:https://example.com/p\r\n"
        " .png\r\n"
    )
    assert_equal(c.full_name, "First")
    assert_equal(len(c.extra), 4)
    assert_equal(c.extra[0], 'X-Custom;x-p="a:b":v\\,w')
    assert_equal(c.extra[1], "FN:Second")
    assert_equal(c.extra[2], "PHOTO;MEDIATYPE=image/png:https://example.com/p.png")
    assert_equal(c.extra[3], "item9.X-ABLabel:orphan")
    print("  test_extra_kept_verbatim PASS")


def test_kind_and_members() raises:
    var a = _one("FN:A\r\n")
    assert_equal(a.kind, "individual")
    var g = _one(
        "KIND:Group\r\nFN:The Doe family\r\n"
        "MEMBER:urn:uuid:03a0e51f-d1aa-4385-8a53-e29025acd8af\r\n"
        "MEMBER:mailto:subscriber1@example.com\r\n"
    )
    assert_equal(g.kind, "group")
    assert_equal(len(g.members), 2)
    assert_equal(g.members[1], "mailto:subscriber1@example.com")
    print("  test_kind_and_members PASS")


def test_value_text_kept_whole() raises:
    var got = parse_contacts(
        (
            "BEGIN:VCARD\r\nVERSION:4.0\r\nFN;VALUE=text:A\r\n"
            "UID;VALUE=text:abc\r\nBDAY;VALUE=text:circa 1800\r\n"
            "URL;VALUE=text:see office\r\nMEMBER;VALUE=TEXT:the Does\r\n"
            "UID:urn:uuid:x\r\nEND:VCARD\r\n"
        ).as_bytes()
    )
    ref c = got.contacts[0]
    assert_equal(c.full_name, "A")
    assert_equal(c.uid, "")
    assert_equal(c.birthday, "")
    assert_equal(len(c.urls), 0)
    assert_equal(len(c.members), 0)
    assert_equal(len(c.extra), 5)
    assert_equal(c.extra[0], "UID;VALUE=text:abc")
    assert_equal(c.extra[1], "BDAY;VALUE=text:circa 1800")
    assert_equal(c.extra[2], "URL;VALUE=text:see office")
    assert_equal(c.extra[3], "MEMBER;VALUE=TEXT:the Does")
    assert_equal(c.extra[4], "UID:urn:uuid:x")
    assert_equal(len(got.dropped), 0)
    print("  test_value_text_kept_whole PASS")


def main() raises:
    print("test_contacts")
    test_n_escaped_comma()
    test_adr_escaped_semicolon()
    test_apple_groups()
    test_tags_by_version()
    test_tel_uri_kept_raw()
    test_dropped_report()
    test_extra_kept_verbatim()
    test_value_text_kept_whole()
    test_kind_and_members()
    print("ALL TESTS PASS")
