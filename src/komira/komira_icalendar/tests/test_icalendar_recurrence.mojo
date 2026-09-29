# =============================================================================
# test_icalendar_recurrence — the RRULE / VTIMEZONE regression guard
# =============================================================================
#
# These tests never touch a socket, a store or an HTTP verb:
# `test_recurrence_expansion`, `test_vtimezone_resolution` and
# `test_bare_tzid_olson_fallback` call `parse_vcalendar` + `expand_event` on a
# literal `.ics` string and assert on the result. The recurrence and DST logic
# is the hard part of the format, so it is guarded here, next to the code,
# independent of any transport.
#
# WHAT THEY PROVE:
#   §5  RRULE expansion — WEEKLY/BYDAY, multi-BYDAY, COUNT, UNTIL, EXDATE and a
#       MONTHLY BYDAY ordinal each yield the EXACT instance set in a window.
#   §6  an INLINE VTIMEZONE resolves a TZID-local DTSTART to true UTC, and the
#       DST rules are applied (EDT 13:00 -> 17:00Z, EST 13:00 -> 18:00Z).
#   §9  a BARE TZID with no inline VTIMEZONE resolves via the embedded IANA
#       fallback table, to the same two answers.
# =============================================================================

from std.testing import assert_true, assert_false, assert_equal

from komira_icalendar import (
    parse_vcalendar,
    expand_event,
)


# =============================================================================
# §5 — recurrence expansion (in-process unit tests on expand_event).
#
# WHAT THIS PROVES:
#   * a weekly RRULE expanded in a window returns the EXACT instance count.
#   * BYDAY (MO,WE,FR), COUNT, and UNTIL each bound the set correctly.
#   * EXDATE removes exactly one instance.
#   * a MONTHLY BYDAY ordinal (3rd Monday) expands to the right civil days.
# =============================================================================
def _master_ics(uid: String, dtstart: String, dtend: String, rrule: String) -> String:
    """A minimal VCALENDAR with one recurring master VEVENT (UTC DTSTART)."""
    return String(
        "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Komira//Test//EN\r\n"
        "BEGIN:VEVENT\r\nUID:"
    ) + uid + String("\r\nDTSTART:") + dtstart + String(
        "\r\nDTEND:"
    ) + dtend + String("\r\nRRULE:") + rrule + String(
        "\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
    )


def _utc_epoch(
    y: Int, mo: Int, d: Int, h: Int, mi: Int, s: Int
) -> Int64:
    """epoch second for a UTC civil date-time (Hinnant days_from_civil)."""
    var yy = y
    var m = mo
    if m <= 2:
        yy -= 1
    var era = (yy if yy >= 0 else yy - 399) // 400
    var yoe = yy - era * 400
    var mp = (m + 9) % 12
    var doy = (153 * mp + 2) // 5 + d - 1
    var doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    var days = era * 146097 + doe - 719468
    return Int64(days) * Int64(86400) + Int64(h) * Int64(3600) + Int64(
        mi
    ) * Int64(60) + Int64(s)


def _count_in_window(
    ics: String, ws: Int64, we: Int64
) -> Int:
    """Parse `ics` and expand its FIRST master VEVENT into [ws, we), returning
    the instance count."""
    var cal = parse_vcalendar(ics)
    if len(cal.events) == 0:
        return 0
    var insts = expand_event(cal.events[0], cal, ws, we)
    return len(insts)


def test_recurrence_expansion() raises:
    # ----- (1) WEEKLY count in a window --------------------------------------
    # FREQ=WEEKLY;BYDAY=MO starting Mon 2026-06-01 09:00Z. June 2026 Mondays:
    # 1, 8, 15, 22, 29 -> 5 Mondays. Window [Jun 1 00:00 .. Jul 1 00:00) -> 5.
    var weekly = _master_ics(
        String("wk@komira"),
        String("20260601T090000Z"),
        String("20260601T100000Z"),
        String("FREQ=WEEKLY;BYDAY=MO"),
    )
    var ws = _utc_epoch(2026, 6, 1, 0, 0, 0)
    var we = _utc_epoch(2026, 7, 1, 0, 0, 0)
    var n_weekly = _count_in_window(weekly, ws, we)
    assert_equal(
        n_weekly, 5, "WEEKLY;BYDAY=MO yields 5 Mondays in June 2026"
    )

    # A narrower window [Jun 8 .. Jun 23) covers Mondays 8, 15, 22 -> 3.
    var n_narrow = _count_in_window(
        weekly, _utc_epoch(2026, 6, 8, 0, 0, 0), _utc_epoch(2026, 6, 23, 0, 0, 0)
    )
    assert_equal(n_narrow, 3, "WEEKLY narrowed window yields 3 Mondays")

    # ----- (2) BYDAY multi-day ------------------------------------------------
    # FREQ=WEEKLY;BYDAY=MO,WE,FR from Mon 2026-06-01. In [Jun 1 .. Jun 8) the
    # week has Mon 1, Wed 3, Fri 5 -> 3 instances.
    var mwf = _master_ics(
        String("mwf@komira"),
        String("20260601T090000Z"),
        String("20260601T093000Z"),
        String("FREQ=WEEKLY;BYDAY=MO,WE,FR"),
    )
    var n_mwf = _count_in_window(
        mwf, _utc_epoch(2026, 6, 1, 0, 0, 0), _utc_epoch(2026, 6, 8, 0, 0, 0)
    )
    assert_equal(n_mwf, 3, "WEEKLY;BYDAY=MO,WE,FR yields Mon/Wed/Fri in week 1")

    # ----- (3) COUNT bounds the set ------------------------------------------
    # FREQ=DAILY;COUNT=3 from 2026-06-01 -> exactly 3 instances (Jun 1,2,3),
    # even in a wide window.
    var daily3 = _master_ics(
        String("d3@komira"),
        String("20260601T090000Z"),
        String("20260601T100000Z"),
        String("FREQ=DAILY;COUNT=3"),
    )
    var n_count = _count_in_window(
        daily3, _utc_epoch(2026, 6, 1, 0, 0, 0), _utc_epoch(2026, 7, 1, 0, 0, 0)
    )
    assert_equal(n_count, 3, "FREQ=DAILY;COUNT=3 yields exactly 3 instances")

    # ----- (4) UNTIL bounds the set ------------------------------------------
    # FREQ=DAILY;UNTIL=20260603T090000Z from Jun 1 -> Jun 1, 2, 3 (inclusive) = 3.
    var until_ics = _master_ics(
        String("u@komira"),
        String("20260601T090000Z"),
        String("20260601T100000Z"),
        String("FREQ=DAILY;UNTIL=20260603T090000Z"),
    )
    var n_until = _count_in_window(
        until_ics,
        _utc_epoch(2026, 6, 1, 0, 0, 0),
        _utc_epoch(2026, 7, 1, 0, 0, 0),
    )
    assert_equal(
        n_until, 3, "FREQ=DAILY;UNTIL=Jun3 09:00Z yields 3 inclusive instances"
    )

    # ----- (5) EXDATE removes one instance -----------------------------------
    # FREQ=WEEKLY;BYDAY=MO from Jun 1 with EXDATE Jun 15 -> June Mondays minus
    # Jun 15 = {1, 8, 22, 29} = 4 in [Jun 1 .. Jul 1).
    var ex_ics = String(
        "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Komira//Test//EN\r\n"
        "BEGIN:VEVENT\r\nUID:ex@komira\r\n"
        "DTSTART:20260601T090000Z\r\nDTEND:20260601T100000Z\r\n"
        "RRULE:FREQ=WEEKLY;BYDAY=MO\r\n"
        "EXDATE:20260615T090000Z\r\n"
        "END:VEVENT\r\nEND:VCALENDAR\r\n"
    )
    var n_ex = _count_in_window(ex_ics, ws, we)
    assert_equal(
        n_ex, 4, "EXDATE Jun 15 removes exactly one of the 5 June Mondays"
    )

    # ----- (6) MONTHLY BYDAY ordinal (3rd Monday) ----------------------------
    # FREQ=MONTHLY;BYDAY=3MO from 2026-06-15 (which IS the 3rd Monday of June).
    # In [Jun 1 .. Sep 1) the 3rd Mondays are Jun 15, Jul 20, Aug 17 -> 3.
    var third_mon = _master_ics(
        String("3mo@komira"),
        String("20260615T090000Z"),
        String("20260615T100000Z"),
        String("FREQ=MONTHLY;BYDAY=3MO"),
    )
    var n_3mo = _count_in_window(
        third_mon,
        _utc_epoch(2026, 6, 1, 0, 0, 0),
        _utc_epoch(2026, 9, 1, 0, 0, 0),
    )
    assert_equal(
        n_3mo, 3, "FREQ=MONTHLY;BYDAY=3MO yields the 3rd Monday of Jun/Jul/Aug"
    )

    # The first expanded instance starts at the master DTSTART (Jun 15 09:00Z).
    var cal3 = parse_vcalendar(third_mon)
    var insts3 = expand_event(
        cal3.events[0],
        cal3,
        _utc_epoch(2026, 6, 1, 0, 0, 0),
        _utc_epoch(2026, 9, 1, 0, 0, 0),
    )
    assert_equal(
        Int(insts3[0].start),
        Int(_utc_epoch(2026, 6, 15, 9, 0, 0)),
        "first 3rd-Monday instance starts at Jun 15 09:00Z",
    )
    # The second instance is Jul 20 09:00Z (the 3rd Monday of July 2026).
    assert_equal(
        Int(insts3[1].start),
        Int(_utc_epoch(2026, 7, 20, 9, 0, 0)),
        "second 3rd-Monday instance is Jul 20 09:00Z",
    )
    print("PASS recurrence-expansion (WEEKLY/BYDAY/COUNT/UNTIL/EXDATE/MONTHLY)")


# =============================================================================
# §6 — VTIMEZONE / TZID resolution (in-process).
#
# WHAT THIS PROVES:
#   * a TZID-local event with an INLINE VTIMEZONE resolves to the correct UTC
#     instant — and that UTC instant DIFFERS from the naive-UTC interpretation
#     by exactly the zone offset.
#   * the DST transition rules are honored: the SAME zone resolves a summer
#     (DAYLIGHT, EDT -4) event and a winter (STANDARD, EST -5) event to
#     different offsets.
# =============================================================================
def _ny_vtimezone() -> String:
    """An inline America/New_York VTIMEZONE (the self-contained definition real
    clients emit): EST = UTC-5 (STANDARD, onset 1st Sun Nov), EDT = UTC-4
    (DAYLIGHT, onset 2nd Sun Mar)."""
    return String(
        "BEGIN:VTIMEZONE\r\n"
        "TZID:America/New_York\r\n"
        "BEGIN:DAYLIGHT\r\n"
        "TZOFFSETFROM:-0500\r\n"
        "TZOFFSETTO:-0400\r\n"
        "DTSTART:20070311T020000\r\n"
        "RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2SU\r\n"
        "TZNAME:EDT\r\n"
        "END:DAYLIGHT\r\n"
        "BEGIN:STANDARD\r\n"
        "TZOFFSETFROM:-0400\r\n"
        "TZOFFSETTO:-0500\r\n"
        "DTSTART:20071104T020000\r\n"
        "RRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=1SU\r\n"
        "TZNAME:EST\r\n"
        "END:STANDARD\r\n"
        "END:VTIMEZONE\r\n"
    )


def _tz_event_ics(dtstart_local: String) -> String:
    """A VCALENDAR with the inline NY VTIMEZONE + one TZID-local VEVENT."""
    return String("BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Komira//Test//EN\r\n") + (
        _ny_vtimezone()
    ) + String(
        "BEGIN:VEVENT\r\nUID:tz@komira\r\n"
        "DTSTART;TZID=America/New_York:"
    ) + dtstart_local + String(
        "\r\nDTEND;TZID=America/New_York:"
    ) + dtstart_local + String(
        "\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
    )


def test_vtimezone_resolution() raises:
    # ----- (1) summer event (EDT, -4): 13:00 local -> 17:00 UTC ---------------
    # A 2026-06-15T13:00 America/New_York event. EDT is UTC-4, so the true UTC
    # instant is 17:00Z. The NAIVE interpretation (the parser alone) is 13:00Z.
    # The resolved instant must DIFFER from the naive one by +4h (14400s).
    var summer = _tz_event_ics(String("20260615T130000"))
    var cal_s = parse_vcalendar(summer)
    assert_equal(len(cal_s.events), 1, "tz event parsed")
    assert_true(cal_s.events[0].has_tz, "the DTSTART carried a TZID")
    var insts_s = expand_event(
        cal_s.events[0],
        cal_s,
        _utc_epoch(2026, 6, 1, 0, 0, 0),
        _utc_epoch(2026, 7, 1, 0, 0, 0),
    )
    assert_equal(len(insts_s), 1, "single tz event expands to one instance")
    var true_utc_summer = _utc_epoch(2026, 6, 15, 17, 0, 0)  # 13:00 EDT = 17Z.
    var naive_utc = _utc_epoch(2026, 6, 15, 13, 0, 0)         # naive 13:00.
    assert_equal(
        Int(insts_s[0].start),
        Int(true_utc_summer),
        "EDT 13:00 local resolves to 17:00 UTC",
    )
    # The crucial assertion: tz-resolution CHANGED the instant by the
    # zone offset relative to the naive-UTC interpretation.
    assert_equal(
        Int(insts_s[0].start - naive_utc),
        14400,
        "tz-resolved instant differs from naive-UTC by the +4h EDT offset",
    )
    assert_false(
        insts_s[0].start == naive_utc,
        "the tz-resolved instant is NOT the naive-UTC interpretation",
    )

    # ----- (2) winter event (EST, -5): 13:00 local -> 18:00 UTC ---------------
    # The SAME zone, a January event. EST is UTC-5 -> 18:00Z. This proves the
    # DST rules are applied (winter uses the STANDARD offset, not DAYLIGHT).
    var winter = _tz_event_ics(String("20260115T130000"))
    var cal_w = parse_vcalendar(winter)
    var insts_w = expand_event(
        cal_w.events[0],
        cal_w,
        _utc_epoch(2026, 1, 1, 0, 0, 0),
        _utc_epoch(2026, 2, 1, 0, 0, 0),
    )
    assert_equal(len(insts_w), 1, "winter tz event expands to one instance")
    var true_utc_winter = _utc_epoch(2026, 1, 15, 18, 0, 0)  # 13:00 EST = 18Z.
    assert_equal(
        Int(insts_w[0].start),
        Int(true_utc_winter),
        "EST 13:00 local resolves to 18:00 UTC (DST rule applied)",
    )
    # Summer vs winter differ by exactly one hour (the DST offset change).
    assert_equal(
        Int(insts_w[0].start) - Int(insts_s[0].start) - 0,
        Int(_utc_epoch(2026, 1, 15, 18, 0, 0))
        - Int(_utc_epoch(2026, 6, 15, 17, 0, 0)),
        "winter resolves one hour later (UTC) than the analogous summer time",
    )
    print("PASS vtimezone-resolution (EDT 13:00->17:00Z, EST 13:00->18:00Z)")


# =============================================================================
# §9 — bare-TZID Olson FALLBACK (no inline VTIMEZONE, in-process).
#
# WHAT THIS PROVES:
#   * a `DTSTART;TZID=America/New_York` event with NO inline VTIMEZONE resolves
#     to the correct UTC instant via the EMBEDDED IANA table — summer (+4 EDT)
#     and winter (+5 EST) — asserting the resolved instant DIFFERS from the naive
#     -UTC interpretation by exactly the zone offset, AND that the DST rule is
#     applied (summer vs winter differ by one hour).
# =============================================================================
def _bare_tzid_event_ics(dtstart_local: String) -> String:
    """A VCALENDAR with a TZID-local VEVENT and NO inline VTIMEZONE (the bare-TZID
    form the Olson fallback table must resolve)."""
    return String(
        "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Komira//Test//EN\r\n"
        "BEGIN:VEVENT\r\nUID:baretz@komira\r\n"
        "DTSTART;TZID=America/New_York:"
    ) + dtstart_local + String(
        "\r\nDTEND;TZID=America/New_York:"
    ) + dtstart_local + String(
        "\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
    )


def test_bare_tzid_olson_fallback() raises:
    # ----- (1) summer (EDT, -4): 13:00 local -> 17:00 UTC, no inline VTIMEZONE -
    var summer = _bare_tzid_event_ics(String("20260615T130000"))
    var cal_s = parse_vcalendar(summer)
    assert_equal(len(cal_s.events), 1, "bare-tzid event parsed")
    assert_equal(
        len(cal_s.timezones), 0, "the event carries NO inline VTIMEZONE"
    )
    assert_true(cal_s.events[0].has_tz, "the DTSTART carried a TZID parameter")
    var insts_s = expand_event(
        cal_s.events[0],
        cal_s,
        _utc_epoch(2026, 6, 1, 0, 0, 0),
        _utc_epoch(2026, 7, 1, 0, 0, 0),
    )
    assert_equal(len(insts_s), 1, "single bare-tzid event expands to one")
    var true_utc_summer = _utc_epoch(2026, 6, 15, 17, 0, 0)  # 13:00 EDT = 17Z.
    var naive_utc_s = _utc_epoch(2026, 6, 15, 13, 0, 0)
    assert_equal(
        Int(insts_s[0].start),
        Int(true_utc_summer),
        "bare TZID=America/New_York EDT 13:00 resolves to 17:00 UTC via the"
        " embedded table",
    )
    assert_equal(
        Int(insts_s[0].start - naive_utc_s),
        14400,
        "the bare-TZID-resolved instant differs from naive-UTC by +4h (EDT)",
    )
    assert_false(
        insts_s[0].start == naive_utc_s,
        "the bare-TZID instant is NOT the naive-UTC interpretation",
    )

    # ----- (2) winter (EST, -5): 13:00 local -> 18:00 UTC, no inline VTIMEZONE -
    var winter = _bare_tzid_event_ics(String("20260115T130000"))
    var cal_w = parse_vcalendar(winter)
    assert_equal(len(cal_w.timezones), 0, "winter event carries NO VTIMEZONE")
    var insts_w = expand_event(
        cal_w.events[0],
        cal_w,
        _utc_epoch(2026, 1, 1, 0, 0, 0),
        _utc_epoch(2026, 2, 1, 0, 0, 0),
    )
    assert_equal(len(insts_w), 1, "winter bare-tzid event expands to one")
    var true_utc_winter = _utc_epoch(2026, 1, 15, 18, 0, 0)  # 13:00 EST = 18Z.
    var naive_utc_w = _utc_epoch(2026, 1, 15, 13, 0, 0)
    assert_equal(
        Int(insts_w[0].start),
        Int(true_utc_winter),
        "bare TZID EST 13:00 resolves to 18:00 UTC (DST rule applied via table)",
    )
    assert_equal(
        Int(insts_w[0].start - naive_utc_w),
        18000,
        "the winter bare-TZID instant differs from naive-UTC by +5h (EST)",
    )
    print(
        "PASS bare-tzid-olson-fallback (TZID=America/New_York with NO inline"
        " VTIMEZONE resolves to correct UTC via the embedded table: EDT 13:00->"
        "17:00Z / EST 13:00->18:00Z, each differing from naive-UTC by the offset)"
    )


def main() raises:
    test_recurrence_expansion()
    test_vtimezone_resolution()
    test_bare_tzid_olson_fallback()
    print(
        "PASS test_icalendar_recurrence (RRULE expansion"
        " WEEKLY/BYDAY/COUNT/UNTIL/EXDATE/MONTHLY-ordinal yields exact instance"
        " counts; an inline VTIMEZONE resolves a TZID-local DTSTART to true UTC"
        " (EDT 13:00->17:00Z / EST 13:00->18:00Z, differing from naive-UTC by the"
        " zone offset); a BARE TZID with no inline VTIMEZONE resolves to the same"
        " instants via the embedded IANA fallback table)"
    )
