# =============================================================================
# test_rfc9555.mojo -- the vCard side of RFC 9555 §2's conversion figures,
# checked against what each figure's JSContact side says the card means.
# =============================================================================
#
# What each test proves (and the defect it catches):
#   fig_7_10_38    KIND, FN with an unescaped comma, UID (Figures 7, 10, 38).
#   fig_12         the seven-component N of RFC 9554 (secondary surname,
#                  generation) is kept whole; SORT-AS is reported, not kept.
#   fig_13_9       NICKNAME; BDAY as written; BIRTHPLACE (not mapped) kept.
#   fig_15         the 18-component ADR of RFC 9554 keeps every component;
#                  CC is reported (a reader that cuts ADR at 7 fails).
#   fig_16_21      EMAIL contexts/pref and TEL features/pref from TYPE and
#                  PREF; the tel: URI is not unescaped or split.
#   fig_25_27      ORG name and units with `\,`; a grouped ORG maps and its
#                  group is reported; ROLE (not mapped) is kept.
#   fig_34_39_40   NOTE unescaped with CREATED/AUTHOR-NAME reported; URL;
#                  X-ABLabel becomes the label of the TEL in its group.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_vcard import ContactImport, emit_contacts, parse_contacts
from komira_vcard_conformance import rfc9555_figures


def _eq(got: List[String], var want: List[String], what: String) raises:
    assert_equal(len(got), len(want), what + " length")
    for i in range(len(want)):
        assert_equal(got[i], want[i], what)


def _read() raises -> ContactImport:
    var got = parse_contacts(rfc9555_figures().as_bytes())
    assert_equal(len(got.contacts), 8)
    return got^


def test_fig_7_10_38() raises:
    var got = _read()
    ref c = got.contacts[0]
    assert_equal(c.kind, "individual")
    assert_equal(c.full_name, "John Q. Public, Esq.")
    assert_equal(c.uid, "urn:uuid:f81d4fae-7dec-11d0-a765-00a0c91e6bf6")
    print("  test_fig_7_10_38 PASS")


def test_fig_12() raises:
    var got = _read()
    ref c = got.contacts[1]
    assert_equal(len(c.name), 7)
    _eq(c.name[0], [String("Stevenson")], "surname")
    _eq(c.name[1], [String("John")], "given")
    _eq(c.name[2], [String("Philip"), String("Paul")], "given2")
    _eq(c.name[3], [String("Dr.")], "title")
    _eq(c.name[4], [String("Jr."), String("M.D."), String("A.C.P.")], "credential")
    _eq(c.name[5], [String("")], "surname2")
    _eq(c.name[6], [String("Jr.")], "generation")
    print("  test_fig_12 PASS")


def test_fig_13_9() raises:
    var got = _read()
    ref c = got.contacts[2]
    _eq(c.nicknames, [String("Johnny")], "NICKNAME")
    assert_equal(c.birthday, "19531015T231000Z")
    _eq(
        c.extra,
        [String("BIRTHPLACE:123 Main Street\\nAny Town, CA 91921-1234\\nU.S.A.")],
        "extra",
    )
    print("  test_fig_13_9 PASS")


def test_fig_15() raises:
    var got = _read()
    ref a = got.contacts[3].addresses[0]
    assert_equal(len(a.parts), 18)
    _eq(a.types, [String("work")], "contexts")
    assert_equal(a.component(2), "54321 Oak St")
    assert_equal(a.component(3), "Reston")
    assert_equal(a.component(4), "VA")
    assert_equal(a.component(5), "20190")
    assert_equal(a.component(6), "USA")
    assert_equal(a.component(10), "54321")
    assert_equal(a.component(11), "Oak St")
    assert_equal(a.component(17), "")
    print("  test_fig_15 PASS")


def test_fig_16_21() raises:
    var got = _read()
    ref c = got.contacts[4]
    assert_equal(c.emails[0].value, "jqpublic@xyz.example.com")
    _eq(c.emails[0].types, [String("work")], "EMAIL-1 contexts")
    assert_equal(c.emails[0].pref, 0)
    assert_equal(c.emails[1].value, "jane_doe@example.com")
    assert_equal(c.emails[1].pref, 1)
    assert_equal(c.phones[0].value, "tel:+1-555-555-5555;ext=5555")
    _eq(c.phones[0].types, [String("voice"), String("home")], "PHONE-1")
    assert_equal(c.phones[0].pref, 1)
    assert_equal(c.phones[1].value, "tel:+33-01-23-45-67")
    _eq(c.phones[1].types, [String("home")], "PHONE-2")
    print("  test_fig_16_21 PASS")


def test_fig_25_27() raises:
    var got = _read()
    _eq(
        got.contacts[5].organization,
        [String("ABC, Inc."), String("North American Division"), String("Marketing")],
        "ORG-1",
    )
    ref c = got.contacts[6]
    assert_equal(c.title, "Research Scientist")
    _eq(c.organization, [String("ABC, Inc.")], "grouped ORG")
    _eq(c.extra, [String("group1.ROLE:Project Leader")], "ROLE kept")
    print("  test_fig_25_27 PASS")


def test_fig_34_39_40() raises:
    var got = _read()
    ref c = got.contacts[7]
    assert_equal(c.note, "Office hours are from 0800 to 1715 EST, Mon-Fri.")
    assert_equal(
        c.urls[0].value, "https://example.org/restaurant.french/~chezchic.html"
    )
    assert_equal(c.phones[0].value, "tel:+1-555-555-5555")
    assert_equal(c.phones[0].group, "item1")
    assert_equal(c.phones[0].label, "foo")
    assert_equal(len(c.extra), 0)
    print("  test_fig_34_39_40 PASS")


def test_dropped_and_round_trip() raises:
    var got = _read()
    _eq(
        got.dropped,
        [
            String("card 2 line 9: N parameter SORT-AS not kept"),
            String("card 4 line 21: ADR parameter CC not kept"),
            String("card 6 line 33: ORG parameter SORT-AS not kept"),
            String("card 7 line 39: ORG group group1 not kept"),
            String("card 8 line 43: NOTE parameter CREATED not kept"),
            String("card 8 line 43: NOTE parameter AUTHOR-NAME not kept"),
        ],
        "dropped",
    )
    var back = parse_contacts(emit_contacts(got.contacts).as_bytes())
    assert_equal(len(back.dropped), 0)
    for i in range(len(got.contacts)):
        assert_true(back.contacts[i] == got.contacts[i], "round trip")
    print("  test_dropped_and_round_trip PASS")


def main() raises:
    print("test_rfc9555")
    test_fig_7_10_38()
    test_fig_12()
    test_fig_13_9()
    test_fig_15()
    test_fig_16_21()
    test_fig_25_27()
    test_fig_34_39_40()
    test_dropped_and_round_trip()
    print("ALL TESTS PASS")
