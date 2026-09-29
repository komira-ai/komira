# =============================================================================
# komira_icalendar/icalendar_recur.mojo — RRULE expansion + VTIMEZONE resolution
# =============================================================================
#
# The TIME MODEL that makes a calendar server correct for real-client interop
# (Apple Calendar / iOS / Thunderbird / DAVx5):
#
#   (1) RRULE RECURRENCE EXPANSION (RFC 5545 §3.3.10 / §3.8.5.3): a recurring
#       VEVENT's master DTSTART + RRULE is expanded into the CONCRETE instances
#       that fall in a [window_start, window_end) range. Supported rule parts:
#         FREQ = DAILY / WEEKLY / MONTHLY / YEARLY
#         INTERVAL, COUNT, UNTIL
#         BYDAY (incl. ordinals 3MO / -1FR), BYMONTHDAY, BYMONTH, BYSETPOS, WKST
#       Plus the per-event recurrence companions:
#         EXDATE     — excluded instances (a recurrence-id removed from the set).
#         RDATE      — extra instances (explicit dates added to the set).
#         RECURRENCE-ID overrides — a detached-instance VEVENT (same UID +
#                      a RECURRENCE-ID) overrides ONE occurrence of the master.
#       Each expanded instance carries the master's DURATION (DTEND - DTSTART).
#       Expansion is BOUNDED: a COUNT-less + UNTIL-less rule is capped at
#       `MAX_INSTANCES` candidate steps so it can never run unbounded.
#
#   (2) VTIMEZONE / TZID RESOLUTION (the parser records a TZID without applying
#       it; this applies it): the .ics carries its VTIMEZONE inline (RFC 5545 §3.6.5 — clients
#       send a self-contained zone definition, so NO external Olson db is
#       needed). A TZID-local DTSTART/DTEND is resolved to a TRUE UTC instant by
#       applying the STANDARD / DAYLIGHT UTC offset in force at that wall-clock
#       time, honoring the embedded DST transition rules (the STANDARD/DAYLIGHT
#       sub-component whose RRULE-driven onset is the latest one at-or-before the
#       wall-clock instant). Floating (no TZID, no Z) stays UTC-treated.
#
# DST-RULE SIMPLIFICATION (documented, deliberate):
#   A VTIMEZONE sub-component (STANDARD / DAYLIGHT) gives TZOFFSETFROM,
#   TZOFFSETTO, DTSTART (the onset wall-clock in the FROM offset) and either a
#   single onset or an RRULE (`FREQ=YEARLY;BYMONTH=..;BYDAY=..`). We resolve a
#   query instant by computing, for the instant's civil YEAR, the onset of each
#   sub-component (via its RRULE's BYMONTH + BYDAY ordinal, or its bare DTSTART),
#   and selecting the sub-component whose onset is the latest at-or-before the
#   instant — that sub-component's TZOFFSETTO is the offset in force. This is the
#   standard "find the active rule" algorithm and is correct for the
#   single-DAYLIGHT / single-STANDARD US/EU zone shape that real clients emit. A
#   zone with mid-history rule changes (multiple historical STANDARD blocks) is
#   resolved by the latest-onset rule per year, which is correct for the modern
#   era; we do NOT model pre-1970 historical offset changes.
#
# Encapsulation: owned String / scalar / List value surface; ZERO UnsafePointer
# in any signature; no wildcard origin; no byte-slab; no take_pointee. The
# civil-date math is
# Howard Hinnant's `days_from_civil` (the same proleptic-Gregorian algorithm the
# parser uses).
# =============================================================================

from .icalendar import (
    VEvent,
    VCalendar,
    VTimeZone,
    TzSubComponent,
    days_from_civil,
    civil_from_days,
)


# -----------------------------------------------------------------------------
# §1 — the expansion cap + the expanded-instance value type.
# -----------------------------------------------------------------------------
# The hard guard: a COUNT-less + UNTIL-less RRULE (e.g. `FREQ=DAILY`) is
# unbounded by the rule itself. We cap the number of CANDIDATE steps the
# generator walks so a degenerate rule can never loop forever; the window also
# bounds the kept set. 100000 candidate steps is ~270 years of daily events —
# far past any realistic query window, but finite.
comptime MAX_INSTANCES: Int = 100000


@fieldwise_init
struct EventInstance(
    Copyable, ImplicitlyCopyable, Movable, Deinitable
):
    """One concrete (expanded) occurrence of a recurring VEVENT.

    Fields:
        start: the instance's start as an epoch SECOND (true UTC — tz-resolved).
        end: the instance's end as an epoch second (start + master duration, or
            an explicit override end for a RECURRENCE-ID detached instance).
        is_override: True iff this instance came from a RECURRENCE-ID override
            VEVENT (carried so the query / free-busy can prefer its DTEND).
    """

    var start: Int64
    var end: Int64
    var is_override: Bool


# -----------------------------------------------------------------------------
# §2 — the parsed RRULE.
# -----------------------------------------------------------------------------
comptime FREQ_NONE: UInt8 = 0
comptime FREQ_DAILY: UInt8 = 1
comptime FREQ_WEEKLY: UInt8 = 2
comptime FREQ_MONTHLY: UInt8 = 3
comptime FREQ_YEARLY: UInt8 = 4


@fieldwise_init
struct ByDayItem(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    """One BYDAY entry: a weekday (0=SU..6=SA) and an optional ordinal (e.g.
    `3MO` -> ord=3, wd=1; `-1FR` -> ord=-1, wd=5; bare `MO` -> ord=0)."""

    var ord: Int
    var wd: Int


@fieldwise_init
struct RRule(Movable, Deinitable):
    """A parsed RRULE. `freq == FREQ_NONE` means the string was not a recurrence
    rule (the event is a single instance)."""

    var freq: UInt8
    var interval: Int
    var count: Int            # 0 = no COUNT bound.
    var until: Int64          # 0 = no UNTIL bound (epoch second, inclusive).
    var until_is_date: Bool   # UNTIL was a DATE value (all-day until).
    var by_day: List[ByDayItem]
    var by_month_day: List[Int]
    var by_month: List[Int]
    var by_set_pos: List[Int]
    var wkst: Int             # week start weekday (0=SU..6=SA); default MO=1.


def _weekday_code(s: String) -> Int:
    """Map a two-letter weekday code (SU/MO/TU/WE/TH/FR/SA) to 0..6; -1 if not a
    weekday code."""
    if s == "SU":
        return 0
    if s == "MO":
        return 1
    if s == "TU":
        return 2
    if s == "WE":
        return 3
    if s == "TH":
        return 4
    if s == "FR":
        return 5
    if s == "SA":
        return 6
    return -1


def _parse_int(s: String) -> Int:
    """Parse a signed decimal integer (leading '+'/'-' ok). 0 on empty."""
    var bs = s.as_bytes()
    var n = len(bs)
    var i = 0
    var sign = 1
    if n > 0 and (bs[0] == UInt8(ord("-")) or bs[0] == UInt8(ord("+"))):
        if bs[0] == UInt8(ord("-")):
            sign = -1
        i = 1
    var v = 0
    while i < n:
        var c = Int(bs[i])
        if c >= 48 and c <= 57:
            v = v * 10 + (c - 48)
        i += 1
    return sign * v


def _split(s: String, sep: UInt8) -> List[String]:
    var out = List[String]()
    var bs = s.as_bytes()
    var n = len(bs)
    var cur = String("")
    var i = 0
    while i < n:
        if bs[i] == sep:
            out.append(cur^)
            cur = String("")
        else:
            cur += chr(Int(bs[i]))
        i += 1
    out.append(cur^)
    return out^


def parse_rrule(rule: String) -> RRule:
    """Parse an RRULE value string (`FREQ=WEEKLY;BYDAY=MO,WE;INTERVAL=2;...`)
    into an `RRule`. An empty / FREQ-less string -> `freq == FREQ_NONE`."""
    var freq = FREQ_NONE
    var interval = 1
    var count = 0
    var until = Int64(0)
    var until_is_date = False
    var by_day = List[ByDayItem]()
    var by_month_day = List[Int]()
    var by_month = List[Int]()
    var by_set_pos = List[Int]()
    var wkst = 1  # MO default per RFC 5545.

    var parts = _split(rule, UInt8(ord(";")))
    var pi = 0
    while pi < len(parts):
        var kv = _split(parts[pi], UInt8(ord("=")))
        pi += 1
        if len(kv) < 2:
            continue
        var key = _upper(kv[0])
        var val = kv[1]
        if key == "FREQ":
            var fu = _upper(val)
            if fu == "DAILY":
                freq = FREQ_DAILY
            elif fu == "WEEKLY":
                freq = FREQ_WEEKLY
            elif fu == "MONTHLY":
                freq = FREQ_MONTHLY
            elif fu == "YEARLY":
                freq = FREQ_YEARLY
        elif key == "INTERVAL":
            var iv = _parse_int(val)
            interval = iv if iv >= 1 else 1
        elif key == "COUNT":
            count = _parse_int(val)
        elif key == "UNTIL":
            var u = _parse_until(val)
            until = u.instant
            until_is_date = u.is_date
        elif key == "BYDAY":
            var days = _split(val, UInt8(ord(",")))
            var di = 0
            while di < len(days):
                var item = _parse_byday(days[di])
                if item.wd >= 0:
                    by_day.append(ByDayItem(item.ord, item.wd))
                di += 1
        elif key == "BYMONTHDAY":
            var mds = _split(val, UInt8(ord(",")))
            var mi = 0
            while mi < len(mds):
                by_month_day.append(_parse_int(mds[mi]))
                mi += 1
        elif key == "BYMONTH":
            var mos = _split(val, UInt8(ord(",")))
            var oi = 0
            while oi < len(mos):
                by_month.append(_parse_int(mos[oi]))
                oi += 1
        elif key == "BYSETPOS":
            var sps = _split(val, UInt8(ord(",")))
            var si = 0
            while si < len(sps):
                by_set_pos.append(_parse_int(sps[si]))
                si += 1
        elif key == "WKST":
            var w = _weekday_code(_upper(val))
            if w >= 0:
                wkst = w

    return RRule(
        freq,
        interval,
        count,
        until,
        until_is_date,
        by_day^,
        by_month_day^,
        by_month^,
        by_set_pos^,
        wkst,
    )


@fieldwise_init
struct _ByDayParsed(Movable, Deinitable):
    var ord: Int
    var wd: Int


def _parse_byday(s: String) -> _ByDayParsed:
    """Parse one BYDAY token: an optional signed ordinal prefix + a 2-letter
    weekday code (`3MO`, `-1FR`, `MO`). Returns wd=-1 if the weekday is invalid.
    """
    var bs = s.as_bytes()
    var n = len(bs)
    if n < 2:
        return _ByDayParsed(0, -1)
    # The weekday code is the LAST two bytes.
    var wcode = String("")
    wcode += chr(Int(bs[n - 2]))
    wcode += chr(Int(bs[n - 1]))
    var wd = _weekday_code(_upper(wcode))
    if wd < 0:
        return _ByDayParsed(0, -1)
    var ord_str = String("")
    var i = 0
    while i < n - 2:
        ord_str += chr(Int(bs[i]))
        i += 1
    var ordv = _parse_int(ord_str) if len(ord_str.as_bytes()) > 0 else 0
    return _ByDayParsed(ordv, wd)


@fieldwise_init
struct _UntilParsed(Movable, Deinitable):
    var instant: Int64
    var is_date: Bool


def _parse_until(s: String) -> _UntilParsed:
    """An UNTIL value is a DATE (`YYYYMMDD`) or a UTC DATE-TIME
    (`YYYYMMDDTHHMMSSZ`); RFC 5545 §3.3.10 requires UNTIL be UTC when DTSTART is
    timed. Parse to an epoch second (the comparable instant)."""
    var bs = s.as_bytes()
    var n = len(bs)
    if n == 8:
        var y = _digits(s, 0, 4)
        var mo = _digits(s, 4, 2)
        var d = _digits(s, 6, 2)
        # An all-day UNTIL bounds at the END of that civil day (inclusive).
        return _UntilParsed(
            _civil_epoch_s(y, mo, d, 23, 59, 59), True
        )
    if n >= 15:
        var y = _digits(s, 0, 4)
        var mo = _digits(s, 4, 2)
        var d = _digits(s, 6, 2)
        var h = _digits(s, 9, 2)
        var mi = _digits(s, 11, 2)
        var sec = _digits(s, 13, 2)
        return _UntilParsed(_civil_epoch_s(y, mo, d, h, mi, sec), False)
    return _UntilParsed(Int64(0), False)


# -----------------------------------------------------------------------------
# §2b — the EMBEDDED IANA/Olson fallback table (a TZID with NO inline VTIMEZONE).
# -----------------------------------------------------------------------------
# RFC 5545 §3.6.5 lets a client emit a TZID-local DTSTART WITHOUT an inline
# VTIMEZONE (it assumes the server carries the Olson db). Without a fallback, a
# bare TZID degrades to floating (UTC-treated), which can be wrong by the zone's
# offset. This table closes that
# gap for the ~20 zones that dominate real calendars: each is synthesized into
# the SAME `VTimeZone` shape the inline path produces (a STANDARD + an optional
# DAYLIGHT sub-component with the modern US / EU / AU DST onset rule), so the
# existing `tz_offset_seconds_at` resolver handles it UNCHANGED.
#
# BOUNDED ZONE SET (documented, deliberate): the table covers exactly the
# zones below. A TZID outside this set (and with no inline VTIMEZONE) still
# degrades to floating (UTC-treated), the same as with no table — so the table
# is a pure WIDENING (no zone that resolves inline changes). The DST rules are the MODERN
# (post-2007 US, current EU/AU) rules; we do NOT model historical rule changes
# (the same scope as the inline path). Each onset uses the standard local
# wall-clock transition hour (US/EU/AU all transition near local 02:00–03:00,
# far from any realistic mid-day event, so the exact onset hour is not
# load-bearing for instant selection).
#
#   US (2nd Sun Mar -> 1st Sun Nov DST, except no-DST AZ/HI):
#     America/New_York   STD -5  DST -4
#     America/Chicago    STD -6  DST -5
#     America/Denver     STD -7  DST -6
#     America/Phoenix    STD -7  (no DST)
#     America/Los_Angeles STD -8 DST -7
#     America/Anchorage  STD -9  DST -8
#     America/Honolulu   STD -10 (no DST)
#   EU (last Sun Mar -> last Sun Oct DST):
#     Europe/London      STD +0  DST +1
#     Europe/Paris       STD +1  DST +2
#     Europe/Berlin      STD +1  DST +2
#     Europe/Madrid      STD +1  DST +2
#     Europe/Rome        STD +1  DST +2
#     Europe/Amsterdam   STD +1  DST +2
#   AU (southern hemisphere: 1st Sun Oct -> 1st Sun Apr DST):
#     Australia/Sydney   STD +10 DST +11
#   No-DST:
#     UTC                +0
#     Asia/Tokyo         +9
#     Asia/Kolkata       +5:30
#     Asia/Shanghai      +8
#     Asia/Hong_Kong     +8
#     Asia/Dubai         +4
# -----------------------------------------------------------------------------


def _us_zone(tzid: String, std_off: Int) -> VTimeZone:
    """A US-rule zone: STANDARD `std_off`, DAYLIGHT `std_off + 1h`. DST onset 2nd
    Sunday March (02:00 local), STANDARD onset 1st Sunday November (02:00 local).
    """
    var subs = List[TzSubComponent]()
    # STANDARD: fall-back, 1st Sunday November.
    subs.append(
        TzSubComponent(
            False, std_off + 3600, std_off, 2007, 11, 4, 2, 0, 0, True, 11, 1, 0
        )
    )
    # DAYLIGHT: spring-forward, 2nd Sunday March.
    subs.append(
        TzSubComponent(
            True, std_off, std_off + 3600, 2007, 3, 11, 2, 0, 0, True, 3, 2, 0
        )
    )
    return VTimeZone(tzid, subs^)


def _eu_zone(tzid: String, std_off: Int) -> VTimeZone:
    """An EU-rule zone: STANDARD `std_off`, DAYLIGHT `std_off + 1h`. DST onset
    last Sunday March, STANDARD onset last Sunday October."""
    var subs = List[TzSubComponent]()
    # STANDARD: fall-back, last Sunday October.
    subs.append(
        TzSubComponent(
            False, std_off + 3600, std_off, 2007, 10, 28, 3, 0, 0, True, 10, -1, 0
        )
    )
    # DAYLIGHT: spring-forward, last Sunday March.
    subs.append(
        TzSubComponent(
            True, std_off, std_off + 3600, 2007, 3, 25, 2, 0, 0, True, 3, -1, 0
        )
    )
    return VTimeZone(tzid, subs^)


def _au_zone(tzid: String, std_off: Int) -> VTimeZone:
    """A southern-hemisphere AU-rule zone: STANDARD `std_off`, DAYLIGHT
    `std_off + 1h`. DST onset 1st Sunday October, STANDARD onset 1st Sunday April
    (summer spans the year boundary, which the prior-year onset lookahead in
    `tz_offset_seconds_at` already handles)."""
    var subs = List[TzSubComponent]()
    # STANDARD: end of DST, 1st Sunday April.
    subs.append(
        TzSubComponent(
            False, std_off + 3600, std_off, 2008, 4, 6, 3, 0, 0, True, 4, 1, 0
        )
    )
    # DAYLIGHT: start of DST, 1st Sunday October.
    subs.append(
        TzSubComponent(
            True, std_off, std_off + 3600, 2007, 10, 7, 2, 0, 0, True, 10, 1, 0
        )
    )
    return VTimeZone(tzid, subs^)


def _fixed_zone(tzid: String, off: Int) -> VTimeZone:
    """A no-DST fixed-offset zone: one STANDARD sub-component (no RRULE)."""
    var subs = List[TzSubComponent]()
    subs.append(
        TzSubComponent(False, off, off, 1970, 1, 1, 0, 0, 0, False, 0, 0, -1)
    )
    return VTimeZone(tzid, subs^)


def embedded_zone_for(tzid: String) -> VTimeZone:
    """Resolve a bare TZID (no inline VTIMEZONE) to a synthesized `VTimeZone`
    from the bounded embedded table. An UNKNOWN tzid returns an empty zone
    (`tzid==""`), which the resolver treats as floating (UTC) for any zone
    outside the table."""
    # US zones (2nd Sun Mar -> 1st Sun Nov DST).
    if tzid == "America/New_York":
        return _us_zone(tzid, -5 * 3600)
    if tzid == "America/Chicago":
        return _us_zone(tzid, -6 * 3600)
    if tzid == "America/Denver":
        return _us_zone(tzid, -7 * 3600)
    if tzid == "America/Los_Angeles":
        return _us_zone(tzid, -8 * 3600)
    if tzid == "America/Anchorage":
        return _us_zone(tzid, -9 * 3600)
    # US no-DST zones.
    if tzid == "America/Phoenix":
        return _fixed_zone(tzid, -7 * 3600)
    if tzid == "America/Honolulu":
        return _fixed_zone(tzid, -10 * 3600)
    # EU zones (last Sun Mar -> last Sun Oct DST).
    if tzid == "Europe/London":
        return _eu_zone(tzid, 0)
    if tzid == "Europe/Paris":
        return _eu_zone(tzid, 1 * 3600)
    if tzid == "Europe/Berlin":
        return _eu_zone(tzid, 1 * 3600)
    if tzid == "Europe/Madrid":
        return _eu_zone(tzid, 1 * 3600)
    if tzid == "Europe/Rome":
        return _eu_zone(tzid, 1 * 3600)
    if tzid == "Europe/Amsterdam":
        return _eu_zone(tzid, 1 * 3600)
    # AU (1st Sun Oct -> 1st Sun Apr DST).
    if tzid == "Australia/Sydney":
        return _au_zone(tzid, 10 * 3600)
    # No-DST fixed-offset zones.
    if tzid == "UTC":
        return _fixed_zone(tzid, 0)
    if tzid == "Asia/Tokyo":
        return _fixed_zone(tzid, 9 * 3600)
    if tzid == "Asia/Kolkata":
        return _fixed_zone(tzid, 5 * 3600 + 30 * 60)
    if tzid == "Asia/Shanghai":
        return _fixed_zone(tzid, 8 * 3600)
    if tzid == "Asia/Hong_Kong":
        return _fixed_zone(tzid, 8 * 3600)
    if tzid == "Asia/Dubai":
        return _fixed_zone(tzid, 4 * 3600)
    # Unknown: an empty zone -> the resolver treats it as floating (UTC).
    return VTimeZone(String(""), List[TzSubComponent]())


# -----------------------------------------------------------------------------
# §3 — VTIMEZONE resolution: a TZID-local wall-clock -> a true UTC instant.
# -----------------------------------------------------------------------------


def tz_offset_seconds_at(tz: VTimeZone, wall_epoch_utc_treated: Int64) -> Int:
    """The UTC offset (seconds; e.g. UTC-5 -> -18000) in force in zone `tz` at
    the given wall-clock instant. `wall_epoch_utc_treated` is the LOCAL wall
    clock interpreted naively as if it were UTC (the parser's comparable
    instant). We pick the STANDARD/DAYLIGHT sub-component whose onset (computed
    for the instant's civil year, in LOCAL wall-clock terms) is the LATEST one
    at-or-before the instant; its TZOFFSETTO is the offset in force.

    If the zone has no sub-components, offset 0 (treat as UTC)."""
    if len(tz.subs) == 0:
        return 0
    # Decompose the wall instant into a civil year (to anchor the yearly onset).
    var civ = civil_from_days(Int(wall_epoch_utc_treated // Int64(86400)))
    var year = civ.year

    var best_onset = Int64(-1) << Int64(62)  # very negative.
    var best_offset = 0
    var found = False
    var i = 0
    while i < len(tz.subs):
        ref sub = tz.subs[i]
        # Compute this sub-component's onset for the instant's year (and, to be
        # safe near a year boundary, the prior year too — a Jan instant can fall
        # under the prior year's DAYLIGHT onset).
        var onset_this = _sub_onset_for_year(sub, year)
        var onset_prev = _sub_onset_for_year(sub, year - 1)
        # The onset is expressed in the sub-component's "from" wall clock; we
        # compare against the naive wall instant directly (both are local
        # wall-clock seconds), which is the standard local-rule selection.
        if onset_this <= wall_epoch_utc_treated and onset_this > best_onset:
            best_onset = onset_this
            best_offset = sub.offset_to
            found = True
        if onset_prev <= wall_epoch_utc_treated and onset_prev > best_onset:
            best_onset = onset_prev
            best_offset = sub.offset_to
            found = True
        i += 1
    if not found:
        # The instant precedes every onset in its year/prior-year window — fall
        # back to the sub-component with the EARLIEST onset (the zone's base).
        var earliest = Int64(1) << Int64(62)
        var ei = 0
        while ei < len(tz.subs):
            ref sub = tz.subs[ei]
            var o = _sub_onset_for_year(tz.subs[ei], year)
            if o < earliest:
                earliest = o
                best_offset = sub.offset_to
            ei += 1
    return best_offset


def _sub_onset_for_year(sub: TzSubComponent, year: Int) -> Int64:
    """The LOCAL wall-clock onset instant (epoch second, UTC-treated) of a
    STANDARD/DAYLIGHT sub-component in the given civil `year`.

    If the sub-component carries an RRULE (`FREQ=YEARLY;BYMONTH=m;BYDAY=oWD`),
    the onset is the o-th WD of month m at the DTSTART time-of-day. Otherwise the
    onset is the sub-component's bare DTSTART (a one-shot onset; we still anchor
    its time-of-day in `year` so the per-year comparison is meaningful for the
    no-RRULE single-transition case)."""
    var h = sub.dt_hour
    var mi = sub.dt_min
    var sec = sub.dt_sec
    if sub.has_rrule and sub.r_month >= 1 and sub.r_wd >= 0:
        var d = _nth_weekday_of_month(year, sub.r_month, sub.r_ord, sub.r_wd)
        if d <= 0:
            # Defensive: fall back to the bare DTSTART civil date.
            return _civil_epoch_s(year, sub.dt_month, sub.dt_day, h, mi, sec)
        return _civil_epoch_s(year, sub.r_month, d, h, mi, sec)
    # No RRULE: a single-transition zone. Anchor at the DTSTART month/day in
    # `year` so the per-year onset selection still works.
    return _civil_epoch_s(year, sub.dt_month, sub.dt_day, h, mi, sec)


def _nth_weekday_of_month(year: Int, month: Int, ordn: Int, wd: Int) -> Int:
    """The day-of-month of the `ordn`-th weekday `wd` (0=SU..6=SA) of `month` in
    `year`. ordn>0 counts from the start (1=first); ordn<0 from the end
    (-1=last). Returns -1 if there is no such occurrence."""
    var first_dow = _weekday_of(year, month, 1)  # 0=SU..6=SA.
    var dim = _days_in_month(year, month)
    if ordn > 0:
        # First occurrence of wd is on day (1 + ((wd - first_dow + 7) % 7)).
        var first_day = 1 + ((wd - first_dow + 7) % 7)
        var day = first_day + (ordn - 1) * 7
        if day < 1 or day > dim:
            return -1
        return day
    if ordn < 0:
        var last_dow = _weekday_of(year, month, dim)
        # Last occurrence of wd is on day (dim - ((last_dow - wd + 7) % 7)).
        var last_day = dim - ((last_dow - wd + 7) % 7)
        var day = last_day + (ordn + 1) * 7
        if day < 1 or day > dim:
            return -1
        return day
    # ordn == 0 (a bare weekday in a tz rule is unusual) -> the first occurrence.
    var first_day0 = 1 + ((wd - first_dow + 7) % 7)
    return first_day0


# -----------------------------------------------------------------------------
# §4 — civil-date helpers shared by the expander + the tz resolver.
# -----------------------------------------------------------------------------


def _weekday_of(y: Int, m: Int, d: Int) -> Int:
    """The weekday of civil date y-m-d as 0=SU..6=SA. The epoch day 1970-01-01
    was a THURSDAY (day-of-week 4)."""
    var days = days_from_civil(y, m, d)
    # 1970-01-01 = Thursday = 4 in SU..SA numbering.
    var dow = (Int(days) + 4) % 7
    if dow < 0:
        dow += 7
    return dow


def _days_in_month(y: Int, m: Int) -> Int:
    if m == 2:
        if (y % 4 == 0 and y % 100 != 0) or (y % 400 == 0):
            return 29
        return 28
    if m == 4 or m == 6 or m == 9 or m == 11:
        return 30
    return 31


def _civil_epoch_s(y: Int, mo: Int, d: Int, h: Int, mi: Int, s: Int) -> Int64:
    if y < 1 or mo < 1 or mo > 12 or d < 1 or d > 31:
        return Int64(0)
    var days = days_from_civil(y, mo, d)
    var secs = Int64(days) * Int64(86400)
    secs += Int64(h) * Int64(3600) + Int64(mi) * Int64(60) + Int64(s)
    return secs


def _digits(s: String, start: Int, count: Int) -> Int:
    var bs = s.as_bytes()
    var v = 0
    var i = start
    var stop = start + count
    while i < stop and i < len(bs):
        var c = Int(bs[i])
        if c >= 48 and c <= 57:
            v = v * 10 + (c - 48)
        i += 1
    return v


def _upper(s: String) -> String:
    var bs = s.as_bytes()
    var out = String("")
    var i = 0
    while i < len(bs):
        var c = bs[i]
        if c >= UInt8(ord("a")) and c <= UInt8(ord("z")):
            out += chr(Int(c) - 32)
        else:
            out += chr(Int(c))
        i += 1
    return out^


# -----------------------------------------------------------------------------
# §5 — a civil date (the candidate-occurrence frame).
# -----------------------------------------------------------------------------


@fieldwise_init
struct _CivilDate(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    """A bare civil date (the recurrence-candidate frame: year/month/day, no
    time). The time-of-day comes from the master DTSTART."""

    var y: Int
    var m: Int
    var d: Int


def _add_days(date: _CivilDate, n: Int) -> _CivilDate:
    var dd = days_from_civil(date.y, date.m, date.d) + n
    var c = civil_from_days(dd)
    return _CivilDate(c.year, c.month, c.day)


def _add_months(date: _CivilDate, n: Int) -> _CivilDate:
    """Advance by n months, CLAMPING the day to the target month length (RFC
    5545's MONTHLY/YEARLY base-date stepping is on the same day-of-month; a day
    that overflows the shorter month is the iteration base, not an emitted
    instance — the BYMONTHDAY/BYDAY filter selects the real days)."""
    var total = (date.y * 12 + (date.m - 1)) + n
    var ny = total // 12
    var nm = (total % 12) + 1
    var dim = _days_in_month(ny, nm)
    var nd = date.d if date.d <= dim else dim
    return _CivilDate(ny, nm, nd)


def _add_years(date: _CivilDate, n: Int) -> _CivilDate:
    var ny = date.y + n
    var dim = _days_in_month(ny, date.m)
    var nd = date.d if date.d <= dim else dim
    return _CivilDate(ny, date.m, nd)


def _contains_int(xs: List[Int], v: Int) -> Bool:
    var i = 0
    while i < len(xs):
        if xs[i] == v:
            return True
        i += 1
    return False


def _byday_matches(rule: RRule, date: _CivilDate) -> Bool:
    """True iff `date`'s weekday satisfies the rule's BYDAY set. For MONTHLY /
    YEARLY an ordinal (`3MO`, `-1FR`) constrains WHICH occurrence in the
    month/year; for DAILY/WEEKLY a bare weekday is a plain weekday filter."""
    if len(rule.by_day) == 0:
        return True
    var wd = _weekday_of(date.y, date.m, date.d)
    var i = 0
    while i < len(rule.by_day):
        ref bd = rule.by_day[i]
        if bd.wd == wd:
            if bd.ord == 0:
                return True
            # An ordinal: the date must be the bd.ord-th `wd` of its month
            # (MONTHLY) or — for YEARLY — of its year. We scope the ordinal to
            # the month for MONTHLY and to the year for YEARLY.
            if rule.freq == FREQ_MONTHLY:
                var nth = _nth_weekday_of_month(date.y, date.m, bd.ord, bd.wd)
                if nth == date.d:
                    return True
            elif rule.freq == FREQ_YEARLY:
                if _is_nth_weekday_of_year(date, bd.ord, bd.wd):
                    return True
        i += 1
    return False


def _is_nth_weekday_of_year(date: _CivilDate, ordn: Int, wd: Int) -> Bool:
    """True iff `date` is the `ordn`-th weekday `wd` of its YEAR."""
    # Count occurrences of `wd` from the start (ordn>0) or end (ordn<0).
    if ordn > 0:
        var jan1_dow = _weekday_of(date.y, 1, 1)
        var first_day = 1 + ((wd - jan1_dow + 7) % 7)  # day-of-year (1-based).
        var target_doy = first_day + (ordn - 1) * 7
        var doy = days_from_civil(date.y, date.m, date.d) - days_from_civil(
            date.y, 1, 1
        ) + 1
        return Int(doy) == target_doy
    if ordn < 0:
        var dec31_dow = _weekday_of(date.y, 12, 31)
        var days_in_year = days_from_civil(date.y + 1, 1, 1) - days_from_civil(
            date.y, 1, 1
        )
        var last_doy = Int(days_in_year) - ((dec31_dow - wd + 7) % 7)
        var target_doy = last_doy + (ordn + 1) * 7
        var doy = days_from_civil(date.y, date.m, date.d) - days_from_civil(
            date.y, 1, 1
        ) + 1
        return Int(doy) == target_doy
    return True


def _candidate_dates_in_period(
    rule: RRule, base: _CivilDate
) -> List[_CivilDate]:
    """Enumerate the candidate DATES inside the recurrence PERIOD that `base`
    anchors (the day for DAILY, the ISO week for WEEKLY, the month for MONTHLY,
    the year for YEARLY), applying BYMONTH / BYMONTHDAY / BYDAY. BYSETPOS is
    applied by the caller across this period's ordered candidate set."""
    var out = List[_CivilDate]()
    if rule.freq == FREQ_DAILY:
        # The period is the single base day; BYMONTH filters it.
        if len(rule.by_month) == 0 or _contains_int(rule.by_month, base.m):
            if _byday_matches(rule, base):
                out.append(base)
        return out^
    if rule.freq == FREQ_WEEKLY:
        # The period is the 7 days of the week containing `base`, starting at
        # WKST. Enumerate them; keep those matching BYDAY (or, with no BYDAY,
        # only the base's own weekday).
        var base_dow = _weekday_of(base.y, base.m, base.d)
        var back = (base_dow - rule.wkst + 7) % 7
        var week_start = _add_days(base, -back)
        var k = 0
        while k < 7:
            var day = _add_days(week_start, k)
            var keep: Bool
            if len(rule.by_day) == 0:
                keep = (
                    _weekday_of(day.y, day.m, day.d)
                    == _weekday_of(base.y, base.m, base.d)
                )
            else:
                keep = _byday_matches(rule, day)
            if keep and (
                len(rule.by_month) == 0 or _contains_int(rule.by_month, day.m)
            ):
                out.append(day)
            k += 1
        return out^
    if rule.freq == FREQ_MONTHLY:
        # The period is the base month; enumerate all its days and filter.
        if len(rule.by_month) != 0 and not _contains_int(rule.by_month, base.m):
            return out^
        var dim = _days_in_month(base.y, base.m)
        var day = 1
        while day <= dim:
            var cand = _CivilDate(base.y, base.m, day)
            if _month_day_ok(rule, cand, dim) and _byday_matches(rule, cand):
                # With NO BYMONTHDAY and NO BYDAY, MONTHLY repeats on the base
                # day-of-month only.
                if (
                    len(rule.by_month_day) == 0
                    and len(rule.by_day) == 0
                    and day != base.d
                ):
                    pass
                else:
                    out.append(cand)
            day += 1
        return out^
    if rule.freq == FREQ_YEARLY:
        # The period is the base year; iterate the months (filtered by BYMONTH,
        # else the base month) and the days within.
        var mo = 1
        while mo <= 12:
            var use_month: Bool
            if len(rule.by_month) != 0:
                use_month = _contains_int(rule.by_month, mo)
            else:
                use_month = (mo == base.m)
            if use_month:
                var dim = _days_in_month(base.y, mo)
                var day = 1
                while day <= dim:
                    var cand = _CivilDate(base.y, mo, day)
                    var keep = True
                    if len(rule.by_month_day) != 0:
                        keep = _month_day_ok(rule, cand, dim)
                    if keep and len(rule.by_day) != 0:
                        keep = _byday_matches(rule, cand)
                    # With no BYMONTHDAY and no BYDAY, YEARLY repeats on the base
                    # month/day only.
                    if (
                        len(rule.by_month_day) == 0
                        and len(rule.by_day) == 0
                    ):
                        keep = (cand.d == base.d)
                    if keep:
                        out.append(cand)
                    day += 1
            mo += 1
        return out^
    return out^


def _month_day_ok(rule: RRule, date: _CivilDate, dim: Int) -> Bool:
    """True iff `date`'s day-of-month satisfies BYMONTHDAY (positive = from the
    1st, negative = from the end). With no BYMONTHDAY -> True."""
    if len(rule.by_month_day) == 0:
        return True
    var i = 0
    while i < len(rule.by_month_day):
        var md = rule.by_month_day[i]
        if md > 0 and md == date.d:
            return True
        if md < 0 and (dim + md + 1) == date.d:
            return True
        i += 1
    return False


def _apply_set_pos(
    cands: List[_CivilDate], by_set_pos: List[Int]
) -> List[_CivilDate]:
    """Apply BYSETPOS to an ordered period candidate set: keep the 1-based
    positions (negative counts from the end). With no BYSETPOS -> all."""
    if len(by_set_pos) == 0:
        return cands.copy()
    var out = List[_CivilDate]()
    var n = len(cands)
    var i = 0
    while i < len(by_set_pos):
        var p = by_set_pos[i]
        var idx = -1
        if p > 0 and p <= n:
            idx = p - 1
        elif p < 0 and (n + p) >= 0:
            idx = n + p
        if idx >= 0 and idx < n:
            out.append(cands[idx])
        i += 1
    return out^


def _period_step(rule: RRule, base: _CivilDate) -> _CivilDate:
    """Advance `base` to the next recurrence period start, honoring INTERVAL."""
    if rule.freq == FREQ_DAILY:
        return _add_days(base, rule.interval)
    if rule.freq == FREQ_WEEKLY:
        return _add_days(base, 7 * rule.interval)
    if rule.freq == FREQ_MONTHLY:
        return _add_months(base, rule.interval)
    if rule.freq == FREQ_YEARLY:
        return _add_years(base, rule.interval)
    return _add_days(base, 1)


# -----------------------------------------------------------------------------
# §6 — the public expander.
# -----------------------------------------------------------------------------


@fieldwise_init
struct ExpandContext(Movable, Deinitable):
    """The inputs the expander needs that live OUTSIDE the master VEvent's
    comparable instant: the master's local-wall-clock DTSTART civil components
    (so candidate dates carry the right time-of-day) + duration + the zone."""

    var start_year: Int
    var start_month: Int
    var start_day: Int
    var start_hour: Int
    var start_min: Int
    var start_sec: Int
    var duration_s: Int64
    var has_tz: Bool


def expand_event(
    master: VEvent,
    cal: VCalendar,
    window_start: Int64,
    window_end: Int64,
) -> List[EventInstance]:
    """Expand `master` (a recurring or single VEVENT) into its concrete
    instances overlapping [window_start, window_end). Honors RRULE, EXDATE,
    RDATE, the VTIMEZONE (master.tzid) for UTC resolution, and the RECURRENCE-ID
    overrides carried in `cal` (matched by UID). Bounded by MAX_INSTANCES.

    A non-recurring master yields a single instance (its own [dtstart, end))
    unless it is itself a RECURRENCE-ID override (those are folded into their
    master's set, not emitted standalone)."""
    var out = List[EventInstance]()
    if master.dtstart == Int64(0):
        return out^
    if master.recurrence_id.byte_length() > 0:
        # A detached override is not a standalone series; the master's expansion
        # folds it in. (handle_calendar_query / free-busy call expand_event on
        # MASTERS only — see the report layer.)
        return out^

    var rule = parse_rrule(master.rrule)

    # The master duration (carried by every instance).
    var dur = master.effective_end() - master.dtstart

    # Resolve the zone for this event (if any) once.
    var tz = _zone_for(cal, master.tzid)

    # Build the EXDATE / override exclusion sets (as the master's local
    # wall-clock comparable instants, to match candidate generation).
    # Overrides: map RECURRENCE-ID instant -> the override VEvent.
    var override_starts = List[Int64]()
    var override_instances = List[EventInstance]()
    _collect_overrides(
        cal, master.uid, tz, override_starts, override_instances
    )

    if rule.freq == FREQ_NONE:
        # A single event: emit it (tz-resolved), plus any RDATEs.
        var inst_start = _resolve(master.dtstart, tz, master.has_tz)
        var inst = EventInstance(inst_start, inst_start + dur, False)
        if _overlaps(inst, window_start, window_end):
            out.append(inst)
        _append_rdates(master, tz, dur, window_start, window_end, out)
        return out^

    # Decompose the master DTSTART into local civil components for stepping.
    var base = _civil_of(master.dtstart)
    var h = Int((master.dtstart % Int64(86400)) // Int64(3600))
    var mi = Int((master.dtstart % Int64(3600)) // Int64(60))
    var sec = Int(master.dtstart % Int64(60))

    var emitted = 0          # count of NON-excluded instances (for COUNT).
    var steps = 0
    var cur = base
    while steps < MAX_INSTANCES:
        steps += 1
        # Enumerate this period's candidate dates (ordered), apply BYSETPOS.
        var cands = _apply_set_pos(
            _candidate_dates_in_period(rule, cur), rule.by_set_pos
        )
        var ci = 0
        while ci < len(cands):
            ref cd = cands[ci]
            ci += 1
            # The candidate's LOCAL wall instant (master time-of-day).
            var local_inst = _civil_epoch_s(cd.y, cd.m, cd.d, h, mi, sec)
            # RFC 5545: no instance is generated BEFORE the master DTSTART (a
            # WEEKLY/MONTHLY period that contains DTSTART may enumerate earlier
            # days of that period — those are not occurrences).
            if local_inst < master.dtstart:
                continue
            # COUNT bounds the number of generated instances (pre-EXDATE per RFC
            # 5545: COUNT counts all generated occurrences including excluded
            # ones; but EXDATE'd ones still consume a COUNT slot). We count every
            # generated occurrence toward COUNT, then skip EXDATE for emission.
            if rule.count > 0 and emitted >= rule.count:
                return _finalize(out^, override_instances, window_start, window_end)
            # UNTIL bounds (inclusive). UNTIL is UTC; compare the resolved UTC.
            var utc_inst = _resolve(local_inst, tz, master.has_tz)
            if rule.until != Int64(0):
                # UNTIL applies to the resolved instant for a timed event; for an
                # all-day/floating event the local instant IS the comparable.
                var cmp = utc_inst if master.has_tz else local_inst
                if cmp > rule.until:
                    return _finalize(
                        out^, override_instances, window_start, window_end
                    )
            emitted += 1
            # EXDATE: a candidate matching an excluded date is dropped.
            if _is_excluded(master, local_inst, utc_inst):
                continue
            # An override (RECURRENCE-ID) replaces this occurrence — skip the
            # generated instance; the override is appended in _finalize.
            if _is_overridden(override_starts, local_inst, utc_inst, master):
                continue
            var inst = EventInstance(utc_inst, utc_inst + dur, False)
            if _overlaps(inst, window_start, window_end):
                out.append(inst)
        # Advance to the next period.
        var nxt = _period_step(rule, cur)
        # Stop once the period base passes the window end AND any UNTIL — a
        # window-bounded early exit so we don't walk to MAX_INSTANCES needlessly.
        var nxt_local = _civil_epoch_s(nxt.y, nxt.m, nxt.d, h, mi, sec)
        var nxt_cmp = _resolve(nxt_local, tz, master.has_tz)
        if window_end != Int64(0) and nxt_cmp >= window_end:
            break
        if rule.until != Int64(0):
            var nxt_until_cmp = nxt_cmp if master.has_tz else nxt_local
            if nxt_until_cmp > rule.until:
                break
        cur = nxt

    # Add RDATEs + fold in overrides that fall in the window.
    _append_rdates(master, tz, dur, window_start, window_end, out)
    return _finalize(out^, override_instances, window_start, window_end)


def _finalize(
    var base: List[EventInstance],
    overrides: List[EventInstance],
    window_start: Int64,
    window_end: Int64,
) -> List[EventInstance]:
    """Append the override instances that fall in the window to the base set."""
    var i = 0
    while i < len(overrides):
        if _overlaps(overrides[i], window_start, window_end):
            base.append(overrides[i])
        i += 1
    return base^


def _overlaps(inst: EventInstance, ws: Int64, we: Int64) -> Bool:
    """True iff [inst.start, inst.end) overlaps [ws, we) (0 = unbounded side).
    A zero-length instance (end == start) overlaps iff start in [ws, we)."""
    var lo_ok = True
    if we != Int64(0):
        lo_ok = inst.start < we
    var hi_ok = True
    if ws != Int64(0):
        if inst.end == inst.start:
            hi_ok = inst.start >= ws
        else:
            hi_ok = inst.end > ws
    return lo_ok and hi_ok


def _resolve(local_wall: Int64, tz: VTimeZone, has_tz: Bool) -> Int64:
    """Resolve a LOCAL wall-clock comparable instant to a TRUE UTC instant. With
    no TZID (floating / already-UTC) the local instant IS the comparable (the
    parser's convention). With a TZID + a VTIMEZONE we subtract the
    offset in force: UTC = local - offset (offset west of UTC is negative, so
    subtracting a negative offset adds — e.g. UTC-5 13:00 local -> 18:00 UTC)."""
    if not has_tz or tz.tzid.byte_length() == 0:
        return local_wall
    var off = tz_offset_seconds_at(tz, local_wall)
    return local_wall - Int64(off)


def _zone_for(cal: VCalendar, tzid: String) -> VTimeZone:
    """Resolve `tzid` to a `VTimeZone`. Prefer an INLINE VTIMEZONE (RFC 5545
    §3.6.5 — a self-contained zone the client emitted).
    Fall back to the EMBEDDED IANA table for a bare TZID with no inline
    definition. An empty `tzid` or a zone outside both -> an empty zone (the
    resolver treats it as floating / UTC-treated)."""
    var i = 0
    while i < len(cal.timezones):
        if cal.timezones[i].tzid == tzid:
            return cal.timezones[i].copy()
        i += 1
    if tzid.byte_length() > 0:
        # No inline VTIMEZONE matched — try the embedded Olson fallback table.
        return embedded_zone_for(tzid)
    return VTimeZone(String(""), List[TzSubComponent]())


def _civil_of(epoch_s: Int64) -> _CivilDate:
    var c = civil_from_days(Int(epoch_s // Int64(86400)))
    return _CivilDate(c.year, c.month, c.day)


def _is_excluded(master: VEvent, local_inst: Int64, utc_inst: Int64) -> Bool:
    """True iff `inst` matches an EXDATE. EXDATEs are stored as the master's
    comparable instants; compare against the candidate's LOCAL instant (EXDATE
    values share DTSTART's wall-clock frame / TZID)."""
    var i = 0
    while i < len(master.exdates):
        if master.exdates[i] == local_inst:
            return True
        i += 1
    return False


def _is_overridden(
    override_starts: List[Int64],
    local_inst: Int64,
    utc_inst: Int64,
    master: VEvent,
) -> Bool:
    """True iff a RECURRENCE-ID override targets this occurrence. The override's
    RECURRENCE-ID is the LOCAL wall-clock comparable instant of the occurrence it
    replaces (same TZID frame as DTSTART)."""
    var i = 0
    while i < len(override_starts):
        if override_starts[i] == local_inst:
            return True
        i += 1
    return False


def _collect_overrides(
    cal: VCalendar,
    uid: String,
    tz: VTimeZone,
    mut starts: List[Int64],
    mut instances: List[EventInstance],
):
    """Collect every RECURRENCE-ID override VEVENT with this UID: record the
    occurrence it replaces (its RECURRENCE-ID comparable instant) + build its
    own (tz-resolved) instance."""
    var i = 0
    while i < len(cal.events):
        ref ev = cal.events[i]
        i += 1
        if ev.uid != uid:
            continue
        if ev.recurrence_id.byte_length() == 0:
            continue
        starts.append(ev.recurrence_id_instant)
        var ostart = _resolve(ev.dtstart, tz, ev.has_tz)
        var oend = _resolve(ev.effective_end(), tz, ev.has_tz)
        instances.append(EventInstance(ostart, oend, True))


def _append_rdates(
    master: VEvent,
    tz: VTimeZone,
    dur: Int64,
    window_start: Int64,
    window_end: Int64,
    mut out: List[EventInstance],
):
    """Append RDATE instances (extra explicit occurrences) that fall in the
    window. Each RDATE shares the master's duration + TZID frame."""
    var i = 0
    while i < len(master.rdates):
        var local = master.rdates[i]
        var utc = _resolve(local, tz, master.has_tz)
        var inst = EventInstance(utc, utc + dur, False)
        if _overlaps(inst, window_start, window_end):
            out.append(inst)
        i += 1
