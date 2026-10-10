# =============================================================================
# test_vendor_shapes.mojo -- vCard inputs in the shape Apple Contacts (3.0),
# Outlook (2.1) and Google Contacts (3.0) export, mapped and round-tripped.
# =============================================================================
#
# What each test proves (and the defect it catches):
#   apple_3_0     `item<n>.` groups strip to the property and X-ABLabel
#                 labels its sibling (the "drop the group strip" mutant
#                 cannot read the card); repeated `type=` with `pref`; a
#                 street with `\n`; a fold inside the postal code; `https\:`
#                 unescaped; an unknown grouped property (X-ABADR) kept.
#   outlook_2_1   bare TYPE parameters and bare PREF; quoted-printable with a
#                 soft line break and UTF-8 (`Caf=C3=A9`); CHARSET and
#                 ENCODING removed; LANGUAGE on N reported; LABEL, X-MS-* and
#                 REV kept.
#   google_3_0    TYPE=INTERNET;TYPE=WORK on EMAIL, a labelled URL in an item
#                 group, CATEGORIES kept, `\n` in NOTE.
# Each card is written back as vCard 4.0 and read again unchanged.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_vcard import Contact, emit_contacts, parse_contacts
from komira_vcard_conformance import (
    apple_shaped_3_0,
    google_shaped_3_0,
    outlook_shaped_2_1,
)


def _eq(got: List[String], var want: List[String], what: String) raises:
    assert_equal(len(got), len(want), what + " length")
    for i in range(len(want)):
        assert_equal(got[i], want[i], what)


def _round_trip(cs: List[Contact]) raises:
    var back = parse_contacts(emit_contacts(cs).as_bytes())
    assert_equal(len(back.contacts), len(cs))
    assert_equal(len(back.dropped), 0)
    for i in range(len(cs)):
        assert_true(back.contacts[i] == cs[i], "round trip")


def test_apple_3_0() raises:
    var got = parse_contacts(apple_shaped_3_0().as_bytes())
    ref c = got.contacts[0]
    assert_equal(c.full_name, "Alex Exemple")
    assert_equal(c.name_component(0), "Exemple")
    assert_equal(c.name_component(1), "Alex")
    _eq(c.organization, [String("Example Corp"), String("Research")], "ORG")
    assert_equal(c.title, "Engineer")
    assert_equal(len(c.emails), 2)
    assert_equal(c.emails[0].value, "alex@example.com")
    assert_equal(c.emails[0].group, "item1")
    assert_equal(c.emails[0].label, "_$!<Other>!$_")
    assert_equal(c.emails[0].pref, 1)
    _eq(c.emails[0].types, [String("internet")], "EMAIL types")
    _eq(c.emails[1].types, [String("internet"), String("home")], "EMAIL 2 types")
    assert_equal(c.phones[0].value, "+1 (555) 010-0001")
    _eq(c.phones[0].types, [String("cell"), String("voice")], "TEL types")
    assert_equal(c.phones[0].pref, 1)
    ref a = c.addresses[0]
    assert_equal(a.group, "item2")
    assert_equal(a.pref, 1)
    assert_equal(a.component(2), "1 Loop Road\nApt 2")
    assert_equal(a.component(5), "95014")
    assert_equal(c.urls[0].value, "https://example.com/alex")
    assert_equal(c.urls[0].label, "_$!<HomePage>!$_")
    assert_equal(c.birthday, "1980-05-04")
    assert_equal(c.note, "Met at the conference, follow up.")
    assert_equal(c.uid, "6A5C1B44-0E2B-4F7D-9C55-0D6B1D3A2F10")
    _eq(
        c.extra,
        [
            String("PRODID:-//Apple Inc.//macOS 14.0//EN"),
            String("item2.X-ABADR:us"),
            String("X-SOCIALPROFILE;type=example:https://social.example/alex"),
        ],
        "extra",
    )
    assert_equal(len(got.dropped), 0)
    _round_trip(got.contacts)
    print("  test_apple_3_0 PASS")


def test_outlook_2_1() raises:
    var got = parse_contacts(outlook_shaped_2_1().as_bytes())
    ref c = got.contacts[0]
    assert_equal(len(c.name), 2)
    assert_equal(c.name_component(0), "Exemple")
    _eq(c.phones[0].types, [String("work"), String("voice")], "TEL work")
    _eq(c.phones[1].types, [String("cell"), String("voice")], "TEL cell")
    _eq(c.addresses[0].types, [String("work")], "ADR types")
    assert_equal(c.addresses[0].pref, 1)
    assert_equal(c.addresses[0].component(3), "Springfield")
    assert_equal(c.emails[0].value, "alex@example.com")
    assert_equal(c.emails[0].pref, 1)
    _eq(c.emails[0].types, [String("internet")], "EMAIL types")
    assert_equal(c.note, "Café meeting\nnext week")
    _eq(
        c.extra,
        [
            String(
                "LABEL;WORK;PREF:1 Main Street\\nSpringfield, IL 62701\\nUnited"
                " States of America"
            ),
            String("X-MS-OL-DEFAULT-POSTAL-ADDRESS:2"),
            String("REV:20260915T120000Z"),
        ],
        "extra",
    )
    _eq(got.dropped, [String("card 1 line 3: N parameter LANGUAGE not kept")], "dropped")
    _round_trip(got.contacts)
    print("  test_outlook_2_1 PASS")


def test_google_3_0() raises:
    var got = parse_contacts(google_shaped_3_0().as_bytes())
    ref c = got.contacts[0]
    _eq(c.emails[0].types, [String("internet"), String("work")], "EMAIL types")
    _eq(c.phones[0].types, [String("cell")], "TEL types")
    assert_equal(c.addresses[0].component(2), "2 Side St")
    assert_equal(c.addresses[0].component(4), "")
    assert_equal(c.addresses[0].component(6), "US")
    assert_equal(c.birthday, "2001-02-03")
    assert_equal(c.urls[0].value, "https://example.org/alex")
    assert_equal(c.urls[0].label, "profile")
    assert_equal(c.note, "Line one\nLine two")
    _eq(c.extra, [String("CATEGORIES:myContacts,Friends")], "extra")
    assert_equal(len(got.dropped), 0)
    _round_trip(got.contacts)
    print("  test_google_3_0 PASS")


def main() raises:
    print("test_vendor_shapes")
    test_apple_3_0()
    test_outlook_2_1()
    test_google_3_0()
    print("ALL TESTS PASS")
