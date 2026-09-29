# =============================================================================
# test_icalendar_emit
#   Proves the RFC 5545 WRITE side is
#   the parser's INVERSE, and falsifies the three emitter bugs that are easy to
#   write and silent to ship.
#
#   WHY A ROUND-TRIP IS THE RIGHT ORACLE HERE. There is no second iCalendar
#   implementation here to diff against, and a byte-literal expectation
#   would only prove the emitter still does what it did when the literal was
#   written. But the package contains a parser that was NOT written to make
#   this test pass — so `parse(emit(x)) == x` is a real
#   falsifier: the two halves were authored against the RFC independently and
#   agreement between them is evidence about the RFC, not about one author.
#
#   ASSERTIONS:
#     (1) A short VEVENT round-trips field-for-field.
#     (2) FOLDING: a >75-octet ATTENDEE line is folded, and unfolds back to the
#         SAME CalAddress. The fold is real (the emitted text contains CRLF+SP)
#         — otherwise (2) would pass vacuously on an unfolded line.
#     (3) ⭐ UTF-8 IS NOT SPLIT BY A FOLD. A 2-byte character positioned to
#         STRADDLE octet 75 survives. This is the assertion that fails if the
#         fold breaks blindly at 75, and also the one that fails if the emitter
#         reassembles bytes with a `chr(Int(b))` loop, which is lossy
#         above U+007F.
#     (4) A `CN` containing a COMMA round-trips as ONE name — the param is
#         quoted. Emitted bare, the comma reads as a value-LIST separator.
#     (5) TEXT escaping: `;` `,` `\` in a SUMMARY survive.
#     (6) METHOD is emitted at VCALENDAR level, and an EMPTY method emits NO
#         METHOD line (a calendar OBJECT, not a scheduling message).
#     (7) SEQUENCE:0 is EMITTED, not suppressed — RFC 5546 §3.2 makes it
#         REQUIRED on a REQUEST and 0 is a real value, not "absent".
#
#   Pure-String, NETWORK-FREE, zero-dep leaf — size=small.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_icalendar import (
    VEvent,
    VCalendar,
    VTimeZone,
    CalAddress,
    parse_vcalendar,
    empty_cal_address,
    ical_escape,
    fold_line,
    emit_vevent,
    emit_vcalendar,
    emit_cal_address,
    format_utc_datetime,
    ICAL_FOLD_OCTETS,
)


def _repeat(c: String, n: Int) -> String:
    var out = String("")
    var i = 0
    while i < n:
        out += c
        i += 1
    return out^


def _addr(
    value: String, cn: String, partstat: String, rsvp: Bool
) -> CalAddress:
    var a = empty_cal_address()
    a.value = value
    a.email = _mailto_lower(value)
    a.cn = cn
    a.partstat = partstat
    a.rsvp = rsvp
    return a^


def _mailto_lower(v: String) -> String:
    """The same normalization `parse_cal_address` applies, so a hand-built
    fixture matches what the parser would have produced."""
    var bs = v.as_bytes()
    if len(bs) < 7:
        return String("")
    var head = String("")
    var i = 0
    while i < 7:
        var c = Int(bs[i])
        if c >= ord("A") and c <= ord("Z"):
            c = c + 32
        head += chr(c)
        i += 1
    if head != "mailto:":
        return String("")
    var out = String("")
    var k = 7
    while k < len(bs):
        var c2 = Int(bs[k])
        if c2 >= ord("A") and c2 <= ord("Z"):
            c2 = c2 + 32
        out += chr(c2)
        k += 1
    return out^


def _mk_event(summary: String) -> VEvent:
    """A minimal but SCHEDULING-complete VEVENT (RFC 5546 §3.2 REQUEST needs
    ORGANIZER + UID + SEQUENCE + DTSTAMP + DTSTART)."""
    return VEvent(
        String("evt-round-trip-1"),          # uid
        summary,                             # summary
        Int64(1781000000),                   # dtstart
        Int64(1781003600),                   # dtend
        False,                               # all_day
        String(""),                          # rrule
        String(""),                          # tzid
        False,                               # has_tz
        String(""),                          # recurrence_id
        Int64(0),                            # recurrence_id_instant
        List[Int64](),                       # exdates
        List[Int64](),                       # rdates
        String(""),                          # transp
        _addr(String("mailto:jane@example.com"), String("Jane"), String(""), False),
        List[CalAddress](),                  # attendees
        Int64(0),                            # sequence
        String(""),                          # status
        Int64(1780900000),                   # dtstamp
        String(""),                          # description
        String(""),                          # location
    )


def _mk_vcal(ev: VEvent, method: String) -> VCalendar:
    var evs = List[VEvent]()
    evs.append(ev.copy())
    return VCalendar(evs^, List[VTimeZone](), method)


def _contains(hay: String, needle: String) -> Bool:
    var h = hay.as_bytes()
    var n = needle.as_bytes()
    if len(n) == 0:
        return True
    if len(n) > len(h):
        return False
    var i = 0
    while i <= len(h) - len(n):
        var k = 0
        var ok = True
        while k < len(n):
            if h[i + k] != n[k]:
                ok = False
                break
            k += 1
        if ok:
            return True
        i += 1
    return False


def _wrap(ev_block: String, method: String) -> String:
    var out = String("BEGIN:VCALENDAR\r\nPRODID:-//test//EN\r\nVERSION:2.0\r\n")
    if method.byte_length() > 0:
        out += String("METHOD:") + method + "\r\n"
    out += ev_block
    out += "END:VCALENDAR\r\n"
    return out^


def main() raises:
    # -------------------------------------------------------------------------
    # (1) A short VEVENT round-trips field-for-field.
    # -------------------------------------------------------------------------
    var ev = _mk_event(String("Design review"))
    var doc = _wrap(emit_vevent(ev), String("REQUEST"))
    var back = parse_vcalendar(doc)
    assert_equal(len(back.events), 1, "exactly one VEVENT survives the emit")
    var r = back.events[0].copy()
    assert_equal(r.uid, ev.uid)
    assert_equal(r.summary, ev.summary)
    assert_equal(r.dtstart, ev.dtstart, "DTSTART is the same INSTANT")
    assert_equal(r.dtend, ev.dtend)
    assert_equal(r.dtstamp, ev.dtstamp, "DTSTAMP round-trips")
    assert_equal(
        r.organizer.email,
        String("jane@example.com"),
        "the ORGANIZER survives emit->parse with its normalized address",
    )
    assert_equal(back.method, String("REQUEST"))

    # -------------------------------------------------------------------------
    # (2) FOLDING is real, and it is reversible.
    #     A CN long enough to push the ATTENDEE line past 75 octets.
    # -------------------------------------------------------------------------
    var long_cn = _repeat(String("Bartholomew "), 8) + String("Smith")
    var att = _addr(
        String("mailto:bart@example.com"),
        long_cn,
        String("NEEDS-ACTION"),
        True,
    )
    var line = emit_cal_address(String("ATTENDEE"), att)
    assert_true(
        len(line.as_bytes()) > ICAL_FOLD_OCTETS,
        "PRECONDITION: the unfolded ATTENDEE line MUST exceed 75 octets, or"
        " assertion (2) proves nothing",
    )
    var folded = fold_line(line)
    assert_true(
        _contains(folded, String("\r\n ")),
        "the emitted line MUST actually be folded (CRLF + SPACE present)",
    )
    var ev2 = _mk_event(String("Folding"))
    ev2.attendees.append(att.copy())
    var back2 = parse_vcalendar(_wrap(emit_vevent(ev2), String("REQUEST")))
    assert_equal(len(back2.events), 1)
    assert_equal(len(back2.events[0].attendees), 1)
    var ratt = back2.events[0].attendees[0].copy()
    assert_equal(
        ratt.cn, long_cn, "the folded CN unfolds to the SAME name, byte for byte"
    )
    assert_equal(ratt.email, String("bart@example.com"))
    assert_equal(ratt.partstat, String("NEEDS-ACTION"))
    assert_true(ratt.rsvp, "RSVP=TRUE survives the fold")

    # -------------------------------------------------------------------------
    # (3) ⭐ A MULTI-BYTE UTF-8 CHARACTER IS NOT SPLIT BY THE FOLD.
    #
    #     `SUMMARY:` is 8 octets. 66 ASCII chars take the line to octet 74, so
    #     the 2-octet `é` occupies octets 74..75 — straddling the 75-octet fold
    #     point exactly. A blind break at 75 emits a lone lead byte followed by
    #     `\r\n ` and then the orphaned continuation byte; the unfolded result
    #     is invalid UTF-8 and the character is destroyed.
    # -------------------------------------------------------------------------
    var straddle = _repeat(String("A"), 66) + String("é") + _repeat(String("B"), 20)
    var ev3 = _mk_event(straddle)
    var emitted3 = emit_vevent(ev3)
    assert_true(
        _contains(emitted3, String("\r\n ")),
        "PRECONDITION: the SUMMARY line MUST be long enough to fold",
    )
    var back3 = parse_vcalendar(_wrap(emitted3, String("REQUEST")))
    assert_equal(len(back3.events), 1)
    assert_equal(
        back3.events[0].summary,
        straddle,
        "a 2-byte character straddling the fold point survives INTACT — this"
        " fails if the fold breaks blindly at octet 75, and it fails if the"
        " emitter reassembles bytes with the lossy chr(Int(b)) loop",
    )
    assert_equal(
        len(back3.events[0].summary.as_bytes()),
        len(straddle.as_bytes()),
        "and the BYTE LENGTH is unchanged — the lossy loop would GROW it",
    )

    # -------------------------------------------------------------------------
    # (4) A CN containing a COMMA is quoted, and round-trips as ONE name.
    # -------------------------------------------------------------------------
    var comma_cn = String("Doe, Jane Q.")
    var att4 = _addr(
        String("mailto:jane.doe@example.com"), comma_cn, String("ACCEPTED"), False
    )
    var line4 = emit_cal_address(String("ATTENDEE"), att4)
    assert_true(
        _contains(line4, String("CN=\"Doe, Jane Q.\"")),
        "a CN containing a comma MUST be emitted as a quoted-string — bare,"
        " the comma is a param value-LIST separator",
    )
    var ev4 = _mk_event(String("Comma"))
    ev4.attendees.append(att4.copy())
    var back4 = parse_vcalendar(_wrap(emit_vevent(ev4), String("REQUEST")))
    assert_equal(len(back4.events[0].attendees), 1)
    assert_equal(
        back4.events[0].attendees[0].cn,
        comma_cn,
        "the comma-bearing CN survives as ONE value",
    )
    assert_equal(
        back4.events[0].attendees[0].email, String("jane.doe@example.com")
    )

    # -------------------------------------------------------------------------
    # (5) TEXT escaping — `;` `,` `\` in a SUMMARY.
    # -------------------------------------------------------------------------
    var nasty = String("Lunch; then coffee, maybe \\ tea")
    assert_equal(
        ical_escape(nasty),
        String("Lunch\\; then coffee\\, maybe \\\\ tea"),
        "TEXT escape is backslash-based (NOT quoting — that is for PARAMS)",
    )
    var ev5 = _mk_event(nasty)
    var back5 = parse_vcalendar(_wrap(emit_vevent(ev5), String("REQUEST")))
    assert_equal(
        back5.events[0].summary,
        nasty,
        "a SUMMARY with ; , and \\ round-trips unchanged",
    )

    # -------------------------------------------------------------------------
    # (6) METHOD lives at VCALENDAR level; an EMPTY method emits NO METHOD line.
    # -------------------------------------------------------------------------
    var vc = _mk_vcal(ev, String("REQUEST"))
    var doc6 = emit_vcalendar(vc, String("-//Example//iMIP//EN"))
    assert_true(_contains(doc6, String("\r\nMETHOD:REQUEST\r\n")))
    assert_false(
        _contains(doc6, String("\r\nBEGIN:VEVENT\r\nMETHOD")),
        "METHOD MUST NOT be emitted inside the VEVENT — the read side ignores"
        " it there on purpose, so writing it there would be dead text that"
        " disagrees with the authoritative copy",
    )
    var vc_obj = _mk_vcal(ev, String(""))
    var doc6b = emit_vcalendar(vc_obj, String("-//Example//iMIP//EN"))
    assert_false(
        _contains(doc6b, String("METHOD")),
        "an empty method emits NO METHOD line — that is a calendar OBJECT"
        " (RFC 5545 §3.7.2), not a scheduling message",
    )
    assert_equal(
        parse_vcalendar(doc6b).method,
        String(""),
        "and it parses back as method-less",
    )

    # -------------------------------------------------------------------------
    # (7) SEQUENCE:0 is EMITTED, not suppressed as "empty".
    # -------------------------------------------------------------------------
    assert_true(
        _contains(emit_vevent(ev), String("SEQUENCE:0")),
        "SEQUENCE 0 is a REAL value (RFC 5545 §3.8.7.4 default) and RFC 5546"
        " §3.2 makes the property REQUIRED on a REQUEST — suppressing it as"
        " falsy would emit an invalid REQUEST",
    )
    assert_equal(
        format_utc_datetime(Int64(0)),
        String("19700101T000000Z"),
        "the epoch formats as the RFC 5545 UTC DATE-TIME form",
    )

    # -------------------------------------------------------------------------
    # (8) A TZID-LOCAL EVENT IS REFUSED, NOT SILENTLY EMITTED AS UTC.
    #
    #     `VEvent.dtstart` is NOT a true UTC instant for a TZID-local event.
    #     The parser documents the simplification at its head: a floating /
    #     TZID-local DATE-TIME is normalized "by treating the wall-clock as if
    #     it were UTC", and the TZID is recorded for provenance but NOT applied
    #     to the instant. So emitting that number with a `Z` suffix ASSERTS it
    #     is UTC when it is a wall-clock reading — a 13:00 America/New_York
    #     meeting goes out as 13:00Z, i.e. 08:00 local. The meeting silently
    #     moves by the zone offset, and every recipient agrees on the wrong
    #     answer because the document is perfectly well-formed.
    #
    #     Refusing is the only honest option available without a VTIMEZONE
    #     emitter: a parsed VTIMEZONE cannot be reproduced faithfully, so we
    #     fail LOUDLY at the point of the problem, naming the TZID.
    # -------------------------------------------------------------------------
    var tz_ev = _mk_event(String("Zone-bearing"))
    tz_ev.has_tz = True
    tz_ev.tzid = String("America/New_York")
    var tz_raised = False
    var tz_msg = String("")
    try:
        var _ignored = emit_vevent(tz_ev)
    except e:
        tz_raised = True
        tz_msg = String(e)
    assert_true(
        tz_raised,
        "emitting a TZID-local event MUST raise — its dtstart is a wall-clock"
        " reading, and emitting it with a Z suffix moves the meeting by the"
        " zone offset while looking perfectly well-formed",
    )
    assert_true(
        _contains(tz_msg, String("America/New_York")),
        "and the refusal MUST name the TZID, so an operator knows which event"
        " and which zone — a bare 'cannot emit' is unactionable",
    )

    print(
        "test_icalendar_emit: RFC 5545 emit round-trip, UTF-8-safe folding,"
        " param quoting, TEXT escaping, METHOD placement and the TZID-local"
        " refusal all PASSED"
    )
