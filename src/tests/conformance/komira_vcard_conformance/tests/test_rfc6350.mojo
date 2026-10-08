# =============================================================================
# test_rfc6350.mojo -- RFC 6350 (vCard 4.0) and RFC 2426 (vCard 3.0) examples:
# each card mapped field by field, written back as vCard 4.0 and read again.
# =============================================================================
#
# What each test proves (and the defect it catches):
#   kind_6_1_4          KIND individual/org and an ORG whose name holds an
#                       escaped comma (`ABC\, Inc.` must stay one component).
#   member_6_6_5        group cards: the MEMBER values of the family card are
#                       exactly the UIDs of the two member cards.
#   property_examples   FN with `\,`, the five-component (eight-value) N of §6.2.2 (split
#                       before unescape), NICKNAME lists across lines, the
#                       folded ADR with a quoted LABEL holding ':' and ',',
#                       TEL as a tel: URI with `;ext=`, EMAIL TYPE/PREF; the
#                       dropped parameters are named exactly.
#   bday_text_6_2_5     `BDAY;VALUE=text:circa 1800` is kept whole in
#                       `extra` and written back with VALUE=text (mapping it
#                       to `birthday` dropped the parameter and wrote
#                       `BDAY:circa 1800`, not a date-and-or-time).
#   author_8            the §8 card: mapped fields, the seven unmapped
#                       properties kept as written, and the exact vCard 4.0
#                       text written back (including the KEY line refolded
#                       at 75 octets).
#   rfc2426_7           a vCard 3.0 card: `BEGIN:vCard`, TYPE lists with
#                       PREF inside TYPE, a fold before a ';' separator.
# Every test also checks parse(emit(cards)) == cards.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_vcard import Contact, emit_contacts, parse_contacts
from komira_vcard_conformance import (
    rfc2426_7_example,
    rfc6350_6_1_4_kind,
    rfc6350_6_2_5_bday_text,
    rfc6350_6_6_5_member,
    rfc6350_6_property_examples,
    rfc6350_8_author,
)


def _eq(got: List[String], var want: List[String], what: String) raises:
    assert_equal(len(got), len(want), what + " length")
    for i in range(len(want)):
        assert_equal(got[i], want[i], what)


def _round_trip(cs: List[Contact]) raises:
    var text = emit_contacts(cs)
    var back = parse_contacts(text.as_bytes())
    assert_equal(len(back.contacts), len(cs))
    assert_equal(len(back.dropped), 0)
    for i in range(len(cs)):
        assert_true(back.contacts[i] == cs[i], "round trip")


def test_kind_6_1_4() raises:
    var got = parse_contacts(rfc6350_6_1_4_kind().as_bytes())
    assert_equal(len(got.contacts), 2)
    assert_equal(got.contacts[0].kind, "individual")
    assert_equal(got.contacts[0].full_name, "Jane Doe")
    _eq(
        got.contacts[0].organization,
        [String("ABC, Inc."), String("North American Division"), String("Marketing")],
        "ORG",
    )
    assert_equal(got.contacts[1].kind, "org")
    assert_equal(got.contacts[1].full_name, "ABC Marketing")
    assert_equal(len(got.dropped), 0)
    _round_trip(got.contacts)
    print("  test_kind_6_1_4 PASS")


def test_member_6_6_5() raises:
    var got = parse_contacts(rfc6350_6_6_5_member().as_bytes())
    assert_equal(len(got.contacts), 4)
    ref family = got.contacts[0]
    assert_equal(family.kind, "group")
    assert_equal(family.full_name, "The Doe family")
    _eq(family.members, [got.contacts[1].uid.copy(), got.contacts[2].uid.copy()], "MEMBER")
    assert_equal(
        got.contacts[1].uid, "urn:uuid:03a0e51f-d1aa-4385-8a53-e29025acd8af"
    )
    _eq(
        got.contacts[3].members,
        [
            String("mailto:subscriber1@example.com"),
            String("xmpp:subscriber2@example.com"),
            String("sip:subscriber3@example.com"),
            String("tel:+1-418-555-5555"),
        ],
        "MEMBER list",
    )
    _round_trip(got.contacts)
    print("  test_member_6_6_5 PASS")


def test_property_examples() raises:
    var got = parse_contacts(rfc6350_6_property_examples().as_bytes())
    ref c = got.contacts[0]
    assert_equal(c.full_name, "Mr. John Q. Public, Esq.")
    assert_equal(len(c.name), 5)
    _eq(c.name[0], [String("Stevenson")], "N family")
    _eq(c.name[2], [String("Philip"), String("Paul")], "N additional")
    _eq(c.name[4], [String("Jr."), String("M.D."), String("A.C.P.")], "N suffix")
    _eq(c.nicknames, [String("Jim"), String("Jimmie"), String("Boss")], "NICKNAME")
    assert_equal(c.birthday, "--0415")
    assert_equal(len(c.addresses), 1)
    ref a = c.addresses[0]
    assert_equal(len(a.parts), 7)
    assert_equal(a.component(2), "123 Main Street")
    assert_equal(a.component(5), "91921-1234")
    assert_equal(a.component(6), "U.S.A.")
    assert_equal(len(c.phones), 2)
    assert_equal(c.phones[0].value, "tel:+1-555-555-5555;ext=5555")
    _eq(c.phones[0].types, [String("voice"), String("home")], "TEL types")
    assert_equal(c.phones[0].pref, 1)
    assert_equal(c.phones[1].value, "tel:+33-01-23-45-67")
    assert_equal(c.emails[0].value, "jqpublic@xyz.example.com")
    _eq(c.emails[0].types, [String("work")], "EMAIL types")
    assert_equal(c.emails[1].pref, 1)
    assert_equal(c.title, "Research Scientist")
    assert_equal(len(c.extra), 0)
    _eq(
        got.dropped,
        [
            String("card 1 line 6: NICKNAME parameter TYPE not kept"),
            String("card 1 line 8: ADR parameter GEO not kept"),
            String("card 1 line 8: ADR parameter LABEL not kept"),
        ],
        "dropped",
    )
    _round_trip(got.contacts)
    print("  test_property_examples PASS")


def test_bday_text_6_2_5() raises:
    var got = parse_contacts(rfc6350_6_2_5_bday_text().as_bytes())
    ref c = got.contacts[0]
    assert_equal(c.full_name, "Jane Doe")
    assert_equal(c.birthday, "")
    _eq(c.extra, [String("BDAY;VALUE=text:circa 1800")], "extra")
    assert_equal(len(got.dropped), 0)
    assert_equal(
        emit_contacts(got.contacts),
        "BEGIN:VCARD\r\nVERSION:4.0\r\nFN:Jane Doe\r\n"
        "BDAY;VALUE=text:circa 1800\r\nEND:VCARD\r\n",
    )
    _round_trip(got.contacts)
    print("  test_bday_text_6_2_5 PASS")


def test_author_8() raises:
    var got = parse_contacts(rfc6350_8_author().as_bytes())
    ref c = got.contacts[0]
    assert_equal(c.full_name, "Simone Exemple")
    assert_equal(c.name_component(0), "Exemple")
    _eq(c.name[4], [String("ing. jr"), String("M.Sc.")], "N suffix")
    assert_equal(c.birthday, "--0203")
    _eq(c.organization, [String("Viagenie")], "ORG")
    assert_equal(c.addresses[0].component(1), "Suite D2-630")
    assert_equal(c.addresses[0].component(3), "Quebec")
    _eq(
        c.phones[1].types,
        [String("work"), String("cell"), String("voice"), String("video"), String("text")],
        "TEL types",
    )
    assert_equal(c.urls[0].value, "http://nomis80.example")
    _eq(
        c.extra,
        [
            String("ANNIVERSARY:20090808T1430-0500"),
            String("GENDER:M"),
            String("LANG;PREF=1:fr"),
            String("LANG;PREF=2:en"),
            String("GEO;TYPE=work:geo:46.772673,-71.282945"),
            String(
                "KEY;TYPE=work;VALUE=uri:http://www.viagenie.example/simone.exemple/simone.asc"
            ),
            String("TZ:-0500"),
        ],
        "extra",
    )
    _eq(got.dropped, [String("card 1 line 10: ORG parameter TYPE not kept")], "dropped")
    var want = String(
        "BEGIN:VCARD\r\n"
        "VERSION:4.0\r\n"
        "FN:Simone Exemple\r\n"
        "N:Exemple;Simone;;;ing. jr,M.Sc.\r\n"
        "ORG:Viagenie\r\n"
        "EMAIL;TYPE=work:simone.exemple@viagenie.example\r\n"
        "TEL;VALUE=uri;TYPE=work,voice;PREF=1:tel:+1-418-656-9254;ext=102\r\n"
        "TEL;VALUE=uri;TYPE=work,cell,voice,video,text:tel:+1-418-262-6501\r\n"
        "ADR;TYPE=work:;Suite D2-630;2875 Laurier;Quebec;QC;G1V 2M2;Canada\r\n"
        "URL;TYPE=home:http://nomis80.example\r\n"
        "BDAY:--0203\r\n"
        "ANNIVERSARY:20090808T1430-0500\r\n"
        "GENDER:M\r\n"
        "LANG;PREF=1:fr\r\n"
        "LANG;PREF=2:en\r\n"
        "GEO;TYPE=work:geo:46.772673,-71.282945\r\n"
        "KEY;TYPE=work;VALUE=uri:http://www.viagenie.example/simone.exemple/simone.a\r\n"
        " sc\r\n"
        "TZ:-0500\r\n"
        "END:VCARD\r\n"
    )
    assert_equal(emit_contacts(got.contacts), want)
    _round_trip(got.contacts)
    print("  test_author_8 PASS")


def test_rfc2426_7() raises:
    var got = parse_contacts(rfc2426_7_example().as_bytes())
    ref c = got.contacts[0]
    assert_equal(c.full_name, "Alex Exemple")
    _eq(c.organization, [String("Example Development Corporation")], "ORG")
    ref a = c.addresses[0]
    _eq(a.types, [String("work"), String("postal"), String("parcel")], "ADR types")
    assert_equal(a.component(2), "6544 Battleford Drive")
    assert_equal(a.component(3), "Raleigh")
    assert_equal(a.component(6), "U.S.A.")
    _eq(c.phones[0].types, [String("voice"), String("msg"), String("work")], "TEL")
    _eq(c.phones[1].types, [String("fax"), String("work")], "TEL fax")
    _eq(c.emails[0].types, [String("internet")], "EMAIL types")
    assert_equal(c.emails[0].pref, 1)
    assert_equal(c.emails[1].pref, 0)
    assert_equal(c.urls[0].value, "http://home.example.net/~aexemple")
    assert_equal(len(got.dropped), 0)
    assert_equal(len(c.extra), 0)
    _round_trip(got.contacts)
    print("  test_rfc2426_7 PASS")


def main() raises:
    print("test_rfc6350")
    test_kind_6_1_4()
    test_member_6_6_5()
    test_property_examples()
    test_bday_text_6_2_5()
    test_author_8()
    test_rfc2426_7()
    print("ALL TESTS PASS")
