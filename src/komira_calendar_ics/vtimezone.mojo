# =============================================================================
# vtimezone.mojo -- the VTIMEZONE an export writes for each zone it uses
# (RFC 5545 §3.6.5), from the zone's rules in `komira_datetime`.
# =============================================================================
#
# The component covers every instant from one year before the earliest
# start the export writes in the zone (`from_utc`) onwards:
#   - each transition the zone lists in that span is one observance with
#     no RRULE: DTSTART is the wall time just before the change (in the old
#     offset), TZOFFSETFROM the old offset, TZOFFSETTO the new one, TZNAME
#     the new abbreviation; DAYLIGHT when the new type is daylight time,
#     else STANDARD;
#   - when the zone's footer (its POSIX TZ string) has daylight time with
#     both rules in the `Mm.w.d` form and a rule time within the day, the
#     transitions after the last listed one are two observances with a
#     yearly RRULE (`BYMONTH=m;BYDAY=wDD`, week 5 written -1), each starting
#     at its first change in the span;
#   - any other footer with changes (a `Jn` or `n` rule, a rule time outside
#     the day) is written as single observances up to 100 years past
#     `from_utc`;
#   - a zone with no change in the span is one observance at
#     1970-01-01T00:00:00, both offsets the one in effect.
# Observances are written in order of their first onset.
# =============================================================================

from komira_content_line import ContentLine, Param, fold_line, format_content_line
from komira_datetime import RULE_MONTH_WEEK_DAY, PosixRule, PosixTz, Zone, ZoneOffset, parse_posix_tz

from .rrule import weekday_name
from .values import SECONDS_PER_DAY, format_ics_datetime, format_utc_offset

comptime _YEAR = 366 * SECONDS_PER_DAY
comptime _MAX_OBSERVANCES = 400


struct _Observance(Copyable, Movable):
    var onset_local: Int
    var from_offset: Int
    var to_offset: Int
    var daylight: Bool
    var name: String
    var rrule: String

    def __init__(out self, onset_local: Int, from_offset: Int, var to: ZoneOffset, var rrule: String):
        self.onset_local = onset_local
        self.from_offset = from_offset
        self.to_offset = to.utc_offset
        self.daylight = to.is_dst
        self.name = to.abbreviation.copy()
        self.rrule = rrule^


def prop_line(name: String, value: String) raises -> String:
    """One property with no parameters, folded, ending in CRLF; `value` is
    written as given."""
    return fold_line(format_content_line(ContentLine(String(), name.copy(), List[Param](), value.copy())))


def _rule_ok(r: PosixRule) -> Bool:
    return r.kind == RULE_MONTH_WEEK_DAY and r.time >= 0 and r.time < SECONDS_PER_DAY


def _yearly(r: PosixRule) -> String:
    var week = -1 if r.week == 5 else r.week
    # PosixRule weekday is 0..6 from Sunday; weekday_name takes 1..7 from Monday.
    var wd = 7 if r.weekday == 0 else r.weekday
    return "FREQ=YEARLY;BYMONTH=" + String(r.month) + ";BYDAY=" + String(week) + weekday_name(wd)


def _first_after(tz: PosixTz, start: Bool, after: Int) -> Int:
    """The first DST start (or end) instant strictly after `after`."""
    var year = (after // _YEAR) + 1970 - 1
    while True:
        var t = tz.start_utc(year) if start else tz.end_utc(year)
        if t > after:
            return t
        year += 1


def write_vtimezone(tzid: String, zone: Zone, from_utc: Int) raises -> String:
    """The VTIMEZONE of `zone` under `tzid` (module header), folded."""
    var begin = from_utc - _YEAR
    var listed_end = begin
    var last = zone.last_listed_transition()
    if last and last.value() > begin:
        listed_end = last.value()
    var footer = zone.footer()
    var rules = False
    var tz = parse_posix_tz("UTC0")
    if footer.byte_length() > 0:
        tz = parse_posix_tz(footer)
        rules = tz.has_dst and _rule_ok(tz.start) and _rule_ok(tz.end)
    var obs = List[_Observance]()
    var t = begin
    var horizon = from_utc + 100 * _YEAR
    while len(obs) < _MAX_OBSERVANCES:
        var nxt = zone.next_transition(t)
        if not nxt:
            break
        ref tr = nxt.value()
        if rules and tr.at > listed_end:
            break
        if tr.at > horizon:
            break
        obs.append(_Observance(tr.at + tr.before.utc_offset, tr.before.utc_offset, tr.after.copy(), String()))
        t = tr.at
    if rules:
        var s = _first_after(tz, True, listed_end)
        var e = _first_after(tz, False, listed_end)
        var dst_on = _Observance(s + tz.standard.utc_offset, tz.standard.utc_offset, tz.daylight.copy(), _yearly(tz.start))
        var dst_off = _Observance(e + tz.daylight.utc_offset, tz.daylight.utc_offset, tz.standard.copy(), _yearly(tz.end))
        if s < e:
            obs.append(dst_on^)
            obs.append(dst_off^)
        else:
            obs.append(dst_off^)
            obs.append(dst_on^)
    if len(obs) == 0:
        var now = zone.offset_at(from_utc)
        obs.append(_Observance(0, now.utc_offset, now^, String()))
    var out = prop_line("BEGIN", "VTIMEZONE")
    out += fold_line(format_content_line(ContentLine(String(), "TZID", List[Param](), tzid.copy())))
    for ref o in obs:
        var kind = "DAYLIGHT" if o.daylight else "STANDARD"
        out += prop_line("BEGIN", kind)
        out += prop_line("DTSTART", format_ics_datetime(o.onset_local, False))
        if o.rrule.byte_length() > 0:
            out += prop_line("RRULE", o.rrule)
        if o.name.byte_length() > 0:
            out += prop_line("TZNAME", o.name)
        out += prop_line("TZOFFSETFROM", format_utc_offset(o.from_offset))
        out += prop_line("TZOFFSETTO", format_utc_offset(o.to_offset))
        out += prop_line("END", kind)
    out += prop_line("END", "VTIMEZONE")
    return out^
