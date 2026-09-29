# =============================================================================
# test_icalendar_scheduling — the iTIP scheduling properties on the iCalendar
# object model (iMIP)
# =============================================================================
#
# ★ WHY IT MATTERS. A single-user calendar-storage parser has no PERSON in it:
# no ORGANIZER, no ATTENDEE, no SEQUENCE, no STATUS, no DTSTAMP. RFC 5546
# scheduling is a different thing, and every assertion in this file is about a
# property such a parser could not express.
#
# THE FOUR THINGS THIS FILE FALSIFIES:
#   §1 the QUOTE-AWARE LEXER. `DIR="ldap://example.com:6666/o=ABC"` is RFC 5545's
#      own example and a first-bare-colon split cuts it in half. This test
#      FAILS on such a lexer — it is a regression guard, not a demonstration
#      that parsing works.
#   §2 the scheduling properties parse, with their RFC-mandated DEFAULTS
#      (SEQUENCE absent == 0, RSVP absent == FALSE) distinguished from absence
#      where the distinction is load-bearing (PARTSTAT).
#   §3 ADDRESS NORMALIZATION is fail-closed: `MAILTO:` normalizes, a non-mailto
#      URI normalizes to "" and must NOT match every lookup.
#   §4 METHOD is a VCALENDAR property, is read only outside a component, and its
#      absence is the discriminator between an iTIP MESSAGE and a plain object.
# =============================================================================

from std.testing import assert_true, assert_false, assert_equal

from komira_icalendar import (
    parse_vcalendar,
    parse_cal_address,
    dequote_param,
    CalAddress,
)


# =============================================================================
# §1 — the quote-aware lexer.
#
# ⚠ A `_split_content_line` that scans for the FIRST `:` with no quote state
# fails this test:
# `ATTENDEE;DIR="ldap://example.com:6666/o=ABC";CN=Jane:mailto:jane@example.com`
# splits at the colon inside `ldap://` and produces params `DIR="ldap` with a
# value of `//example.com:6666/o=ABC";CN=Jane:mailto:jane@example.com`. Every
# param on that line is then unreadable and the address is garbage.
# =============================================================================
def test_quoted_param_containing_colon_does_not_split_the_line() raises:
    var ics = String(
        "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nMETHOD:REQUEST\r\n"
        "BEGIN:VEVENT\r\nUID:quoted-1\r\nDTSTART:20260615T130000Z\r\n"
        'ATTENDEE;DIR="ldap://example.com:6666/o=ABC";CN="Doe, Jane";'
        "PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:jane@example.com\r\n"
        "END:VEVENT\r\nEND:VCALENDAR\r\n"
    )
    var cal = parse_vcalendar(ics)
    assert_equal(len(cal.events), 1, "one VEVENT parses")
    var ev = cal.events[0].copy()
    assert_equal(len(ev.attendees), 1, "one ATTENDEE parses")
    var a = ev.attendees[0].copy()
    # The VALUE must be the whole CAL-ADDRESS, not a fragment of the ldap URL.
    assert_equal(
        a.value,
        String("mailto:jane@example.com"),
        "the value is everything after the first UNQUOTED colon",
    )
    assert_equal(
        a.email,
        String("jane@example.com"),
        "the normalized addr-spec survives a quoted param carrying a colon",
    )
    # A quoted CN containing a COMMA must not be split on `,` either, and the
    # surrounding DQUOTEs are delimiters, not content.
    assert_equal(
        a.cn, String("Doe, Jane"), "a quoted CN with a comma is one value"
    )
    assert_equal(a.partstat, String("NEEDS-ACTION"), "PARTSTAT parses")
    assert_true(a.rsvp, "RSVP=TRUE parses")
    print(
        "PASS quoted-param-colon (a quoted param value containing `:` and `,`"
        " — RFC 5545 §3.1.1's own DIR=\"ldap://host:6666/o=ABC\" example — does"
        " not split the content line; CN, PARTSTAT, RSVP and the CAL-ADDRESS all"
        " survive)"
    )


def test_dequote_is_the_exact_inverse_of_the_grammar() raises:
    assert_equal(dequote_param(String('"a b"')), String("a b"), "pair stripped")
    assert_equal(dequote_param(String("a b")), String("a b"), "bare untouched")
    # A LONE quote is not a pair and must be left alone rather than guessed at —
    # RFC 5545 §3.1.1 has no escape inside a quoted-string, so a lone DQUOTE is
    # malformed input, and silently "repairing" it invents content.
    assert_equal(dequote_param(String('"a')), String('"a'), "lone quote kept")
    assert_equal(dequote_param(String('"')), String('"'), "single char kept")
    assert_equal(dequote_param(String("")), String(""), "empty kept")
    print("PASS dequote-param (strips exactly a surrounding DQUOTE pair)")


# =============================================================================
# §2 — the scheduling properties, with their RFC defaults.
# =============================================================================
def _request_ics() -> String:
    return String(
        "BEGIN:VCALENDAR\r\n"
        "VERSION:2.0\r\n"
        "PRODID:-//Komira//iMIP//EN\r\n"
        "METHOD:REQUEST\r\n"
        "BEGIN:VEVENT\r\n"
        "UID:sched-1@komira.test\r\n"
        "DTSTAMP:20260601T090000Z\r\n"
        "DTSTART:20260615T130000Z\r\n"
        "DTEND:20260615T140000Z\r\n"
        "SEQUENCE:3\r\n"
        "STATUS:CONFIRMED\r\n"
        "SUMMARY:Design review\r\n"
        "DESCRIPTION:Bring the RFC\\, and the counterexample\r\n"
        "LOCATION:Room 4\\; second floor\r\n"
        'ORGANIZER;CN="Ada Organiser":mailto:ada@komira.test\r\n'
        "ATTENDEE;CN=Bob;ROLE=REQ-PARTICIPANT;CUTYPE=INDIVIDUAL;"
        "PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:bob@partner.test\r\n"
        "ATTENDEE;ROLE=OPT-PARTICIPANT:MAILTO:Carol@Partner.TEST\r\n"
        "END:VEVENT\r\n"
        "END:VCALENDAR\r\n"
    )


def test_scheduling_properties_parse() raises:
    var cal = parse_vcalendar(_request_ics())
    assert_equal(cal.method, String("REQUEST"), "METHOD is a VCALENDAR prop")
    assert_equal(len(cal.events), 1, "one VEVENT")
    var ev = cal.events[0].copy()

    assert_equal(ev.uid, String("sched-1@komira.test"), "UID")
    assert_equal(Int(ev.sequence), 3, "SEQUENCE parses as an integer")
    assert_equal(ev.status, String("CONFIRMED"), "STATUS uppercased")
    assert_true(ev.dtstamp != Int64(0), "DTSTAMP resolves to an instant")
    assert_true(
        ev.dtstamp < ev.dtstart,
        "DTSTAMP (when the message was made) precedes DTSTART here",
    )
    # TEXT escaping is undone on read — an escaped comma/semicolon is content.
    assert_equal(
        ev.description,
        String("Bring the RFC, and the counterexample"),
        "DESCRIPTION is unescaped (\\, -> ,)",
    )
    assert_equal(
        ev.location,
        String("Room 4; second floor"),
        "LOCATION is unescaped (\\; -> ;)",
    )

    assert_true(ev.organizer.is_present(), "ORGANIZER present")
    assert_equal(
        ev.organizer.email, String("ada@komira.test"), "organizer addr-spec"
    )
    assert_equal(ev.organizer.cn, String("Ada Organiser"), "organizer CN")

    assert_equal(len(ev.attendees), 2, "BOTH ATTENDEEs are kept")
    assert_equal(ev.attendees[0].email, String("bob@partner.test"), "att 0")
    assert_equal(ev.attendees[0].role, String("REQ-PARTICIPANT"), "ROLE")
    assert_equal(ev.attendees[0].cutype, String("INDIVIDUAL"), "CUTYPE")
    assert_true(ev.attendees[0].rsvp, "RSVP=TRUE")
    # ★ Case-insensitive scheme + case-folded addr-spec: `MAILTO:Carol@Partner.TEST`
    # is the SAME attendee as `mailto:carol@partner.test`. Exchange emits the
    # upper form; two spellings must not become two attendees.
    assert_equal(
        ev.attendees[1].email,
        String("carol@partner.test"),
        "MAILTO: (uppercase scheme, mixed-case address) normalizes",
    )
    assert_equal(
        ev.attendees[1].value,
        String("MAILTO:Carol@Partner.TEST"),
        "the RAW value is preserved verbatim for echo-back in a REPLY",
    )
    print(
        "PASS scheduling-properties (ORGANIZER/ATTENDEE+params/SEQUENCE/STATUS/"
        "DTSTAMP/DESCRIPTION/LOCATION all parse; TEXT escapes are undone; a"
        " mixed-case MAILTO: normalizes while the raw value is preserved)"
    )


def test_rfc_defaults_for_absent_properties() raises:
    var ics = String(
        "BEGIN:VCALENDAR\r\nVERSION:2.0\r\n"
        "BEGIN:VEVENT\r\nUID:defaults-1\r\nDTSTART:20260615T130000Z\r\n"
        "ATTENDEE:mailto:zed@partner.test\r\n"
        "END:VEVENT\r\nEND:VCALENDAR\r\n"
    )
    var ev = parse_vcalendar(ics).events[0].copy()
    # RFC 5545 §3.8.7.4: SEQUENCE defaults to 0. 0 is a REAL revision number
    # here, not "unknown" — a REQUEST with no SEQUENCE is revision 0.
    assert_equal(Int(ev.sequence), 0, "absent SEQUENCE defaults to 0")
    # RFC 5545 §3.2.17: RSVP defaults to FALSE.
    assert_false(ev.attendees[0].rsvp, "absent RSVP defaults to FALSE")
    # ⚠ PARTSTAT is deliberately NOT defaulted to NEEDS-ACTION at parse time.
    # "the sender said nothing" and "the sender said NEEDS-ACTION" are different
    # facts: only the second is a positive statement the state machine may act
    # on. Defaulting here would erase that distinction irrecoverably.
    assert_equal(
        ev.attendees[0].partstat,
        String(""),
        "absent PARTSTAT stays empty — absence is not NEEDS-ACTION",
    )
    assert_false(ev.organizer.is_present(), "absent ORGANIZER is not present")
    assert_equal(ev.status, String(""), "absent STATUS is empty")
    assert_equal(Int(ev.dtstamp), 0, "absent DTSTAMP is 0")
    print(
        "PASS rfc-defaults (SEQUENCE->0 and RSVP->FALSE per the RFC; PARTSTAT"
        " absence is preserved as absence and NOT defaulted to NEEDS-ACTION)"
    )


# =============================================================================
# §3 — address normalization is fail-closed.
# =============================================================================
def test_non_mailto_cal_address_normalizes_to_empty_and_matches_nothing() raises:
    var a = parse_cal_address(String(""), String("urn:uuid:not-an-email"))
    assert_equal(a.value, String("urn:uuid:not-an-email"), "raw kept")
    assert_equal(
        a.email, String(""), "a non-mailto URI has NO normalized addr-spec"
    )
    # ★ THE FAIL-CLOSED PROPERTY. An event whose only ATTENDEE is a non-mailto
    # URI must not answer "yes, that is you" to a lookup for the empty string —
    # otherwise any REPLY with an unparseable attendee could set a PARTSTAT on
    # the wrong row.
    var ics = String(
        "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:u\r\n"
        "ATTENDEE:urn:uuid:not-an-email\r\n"
        "END:VEVENT\r\nEND:VCALENDAR\r\n"
    )
    var ev = parse_vcalendar(ics).events[0].copy()
    assert_equal(
        ev.find_attendee(String("")),
        -1,
        "an empty lookup matches NOTHING, even against an unnormalizable"
        " attendee",
    )
    assert_equal(
        ev.find_attendee(String("nobody@x.test")), -1, "a miss is a miss"
    )
    print(
        "PASS non-mailto-fail-closed (a non-mailto CAL-ADDRESS normalizes to ''"
        " and an empty lookup matches nothing — an unparseable attendee cannot"
        " be mistaken for the caller)"
    )


def test_itip_key_distinguishes_series_from_instance() raises:
    var series = String(
        "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:evt-9\r\n"
        "DTSTART:20260615T130000Z\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
    )
    var instance = String(
        "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:evt-9\r\n"
        "RECURRENCE-ID:20260622T130000Z\r\n"
        "DTSTART:20260622T140000Z\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
    )
    var s = parse_vcalendar(series).events[0].copy()
    var i = parse_vcalendar(instance).events[0].copy()
    assert_equal(s.itip_key(), String("evt-9"), "a master keys on UID alone")
    assert_true(
        s.itip_key() != i.itip_key(),
        "a detached instance is a DIFFERENT scheduling object from its series",
    )
    assert_true(
        i.itip_key().byte_length() > (String("evt-9")).byte_length(),
        "the instance key carries the RECURRENCE-ID",
    )
    print(
        "PASS itip-key (UID keys a series; UID+RECURRENCE-ID keys one detached"
        " instance, and the two are never equal — RFC 5546 §1.4)"
    )


# =============================================================================
# §4 — METHOD is a VCALENDAR property and its absence is the discriminator.
# =============================================================================
def test_method_absent_is_a_plain_object_not_a_scheduling_message() raises:
    var plain = String(
        "BEGIN:VCALENDAR\r\nVERSION:2.0\r\n"
        "BEGIN:VEVENT\r\nUID:plain-1\r\nDTSTART:20260615T130000Z\r\n"
        "ORGANIZER:mailto:ada@komira.test\r\n"
        "ATTENDEE:mailto:bob@partner.test\r\n"
        "END:VEVENT\r\nEND:VCALENDAR\r\n"
    )
    var cal = parse_vcalendar(plain)
    # ⚠ An .ics with an ORGANIZER and ATTENDEEs but NO METHOD is a calendar
    # OBJECT (RFC 5545 §3.7.2), not an invitation. A user importing a public
    # `.ics` must not thereby be "invited" by its author.
    assert_equal(
        cal.method,
        String(""),
        "no METHOD -> not a scheduling message, even with ORGANIZER+ATTENDEE",
    )
    assert_true(
        cal.events[0].organizer.is_present(),
        "the ORGANIZER still parses — it is METHOD that makes it an invite",
    )
    print(
        "PASS method-absence (an ORGANIZER+ATTENDEE .ics with no METHOD is a"
        " calendar OBJECT, not an iTIP message)"
    )


def test_method_is_read_only_outside_a_component() raises:
    # A `METHOD:` line INSIDE a VEVENT is not the calendar's method. Reading it
    # there would let a crafted VEVENT body override the message's declared
    # method — the exact confusion RFC 6047 §2.4's method-agreement rule exists
    # to prevent.
    var ics = String(
        "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nMETHOD:REQUEST\r\n"
        "BEGIN:VEVENT\r\nUID:m-1\r\nMETHOD:CANCEL\r\n"
        "DTSTART:20260615T130000Z\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
    )
    var cal = parse_vcalendar(ics)
    assert_equal(
        cal.method,
        String("REQUEST"),
        "the VCALENDAR-level METHOD wins; a METHOD inside a VEVENT is ignored",
    )
    print(
        "PASS method-scope (a METHOD line inside a VEVENT cannot override the"
        " VCALENDAR's own METHOD)"
    )


def main() raises:
    test_quoted_param_containing_colon_does_not_split_the_line()
    test_dequote_is_the_exact_inverse_of_the_grammar()
    test_scheduling_properties_parse()
    test_rfc_defaults_for_absent_properties()
    test_non_mailto_cal_address_normalizes_to_empty_and_matches_nothing()
    test_itip_key_distinguishes_series_from_instance()
    test_method_absent_is_a_plain_object_not_a_scheduling_message()
    test_method_is_read_only_outside_a_component()
    print(
        "PASS test_icalendar_scheduling (the RFC 5546 scheduling properties"
        " parse off a VEVENT with their RFC defaults; the lexer is quote-aware"
        " so a quoted param carrying `:`/`,` no longer splits the line; address"
        " normalization is fail-closed on non-mailto URIs; and METHOD is a"
        " VCALENDAR property whose ABSENCE distinguishes a calendar object from"
        " a scheduling message)"
    )
