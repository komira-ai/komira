# =============================================================================
# komira_icalendar/freebusy.mojo — busy-interval algebra + the VFREEBUSY
# emitter (RFC 5545 §3.6.4 / RFC 4791 §7.10's response document)
# =============================================================================
#
# WHY IT IS A SEPARATE MODULE. None of this is WebDAV. `BusyPeriod` is a pair
# of epoch seconds; `_merge_periods` is interval coalescing; `_build_vfreebusy`
# emits an RFC 5545 VCALENDAR body. CalDAV's `free-busy-query` is one caller;
# the others are not CalDAV: the iTIP `METHOD:REQUEST`/`REPLY` path over email
# (iMIP) and a cross-vendor availability overlay, which projects EXTERNAL
# calendars into `BusyPeriod`s and feeds them into this same merge.
#
# `_ical_escape` lives here for the same reason: it is the exact inverse of the
# parser's `_ical_unescape` (`icalendar.mojo`), and any emitter — VFREEBUSY,
# VEVENT, iTIP — needs it.
#
# KNOWN LIMITATION: `_merge_periods` is an O(n²) insertion sort.
#
# Encapsulation: owned `String` / scalar / `List` surface; ZERO UnsafePointer
# in any signature; no wildcard origin; no byte-slab; no take_pointee.
# =============================================================================


# -----------------------------------------------------------------------------
# §1 — the busy-interval value type.
# -----------------------------------------------------------------------------


@fieldwise_init
struct BusyPeriod(Copyable, Movable, Deinitable):
    """A busy period [start, end) (epoch seconds).

    The PUBLIC busy-interval type of the free/busy union. A higher layer (a
    cross-vendor OVERLAY projector) projects each EXTERNAL calendar's
    non-transparent occurrences into `BusyPeriod`s clipped to the query window
    and feeds them into the SAME merge the native busy-collection loop fills.
    `_merge_periods` then coalesces native ∪ external — cross-vendor
    dedup falls out of interval-overlap coalescing, so no UID-matching is
    needed.

    Encapsulation: a plain-POD value type (two `Int64`s) with no heap-owning
    field, ZERO UnsafePointer, no wildcard origin. Crossing the module boundary
    as an owned value is encapsulation-clean."""

    var start: Int64
    var end: Int64


# Internal alias — the native collection path was written against `_Period`
# before the union; `BusyPeriod` is the public name. Keeping the alias avoids a
# mechanical churn of every internal `_Period` site.
comptime _Period = BusyPeriod


comptime FREE_BUSY_TRUNCATED_PROP: StaticString = (
    "X-KOMIRA-FREEBUSY-TRUNCATED:TRUE"
)


def _ical_escape(s: String) -> String:
    r"""Escape an RFC 5545 §3.3.11 TEXT value for emission (the inverse of the
    parser's `_ical_unescape`): `\` -> `\\`, `;` -> `\;`, `,` -> `\,`, a LF ->
    `\n`. The SUMMARY round-trips through the expanded VEVENT correctly."""
    var bs = s.as_bytes()
    var out = String("")
    var i = 0
    while i < len(bs):
        var c = bs[i]
        if c == UInt8(ord("\\")):
            out += "\\\\"
        elif c == UInt8(ord(";")):
            out += "\\;"
        elif c == UInt8(ord(",")):
            out += "\\,"
        elif c == UInt8(0x0A):
            out += "\\n"
        elif c == UInt8(0x0D):
            pass  # drop a bare CR (the LF carries the line break).
        else:
            out += chr(Int(c))
        i += 1
    return out^


def _merge_periods(var ps: List[_Period]) -> List[_Period]:
    """Sort `ps` by start and coalesce overlapping / adjacent periods."""
    # Insertion sort by start (the busy set is small).
    var n = len(ps)
    var i = 1
    while i < n:
        var key_s = ps[i].start
        var key_e = ps[i].end
        var j = i - 1
        while j >= 0 and ps[j].start > key_s:
            ps[j + 1] = _Period(ps[j].start, ps[j].end)
            j -= 1
        ps[j + 1] = _Period(key_s, key_e)
        i += 1
    var out = List[_Period]()
    var k = 0
    while k < n:
        var cs = ps[k].start
        var ce = ps[k].end
        if len(out) == 0:
            out.append(_Period(cs, ce))
        else:
            # Read the last merged period into locals (avoid holding a ref across
            # the in-place reassignment below).
            var last_start = out[len(out) - 1].start
            var last_end = out[len(out) - 1].end
            if cs <= last_end:
                # Overlap / adjacency -> extend the last period's end.
                var new_end = last_end if last_end >= ce else ce
                out[len(out) - 1] = _Period(last_start, new_end)
            else:
                out.append(_Period(cs, ce))
        k += 1
    return out^


def _build_vfreebusy(
    win_start: Int64, win_end: Int64, periods: List[_Period], truncated: Bool
) -> String:
    """Build the VFREEBUSY response document (a minimal VCALENDAR wrapping one
    VFREEBUSY with DTSTART/DTEND = the window + one FREEBUSY line per merged busy
    period, as `<start>/<end>` UTC DATE-TIME ranges).

    ★ `truncated` EMITS `X-KOMIRA-FREEBUSY-TRUNCATED:TRUE`, AND OMITTING IT WOULD
    BE A LIE OF THE MOST DANGEROUS KIND. A free/busy answer's meaning is "these are
    the busy intervals in the window" — i.e. every gap is bookable. A capped answer
    whose cap is invisible says a gap is free when the server simply stopped
    looking, so a scheduler double-books someone. An `X-` property is the RFC 5545
    §3.8.8.2 extension mechanism: conforming clients ignore what they do not know,
    so this is additive, and a client that DOES read it can degrade to "narrow your
    window and ask again"."""
    var out = String(
        "BEGIN:VCALENDAR\r\n"
        "VERSION:2.0\r\n"
        "PRODID:-//Komira//CalDAV//EN\r\n"
        "BEGIN:VFREEBUSY\r\n"
    )
    if win_start != Int64(0):
        out += String("DTSTART:") + _epoch_to_ical_utc(win_start) + String(
            "\r\n"
        )
    if win_end != Int64(0):
        out += String("DTEND:") + _epoch_to_ical_utc(win_end) + String("\r\n")
    if truncated:
        out += String(FREE_BUSY_TRUNCATED_PROP) + String("\r\n")
    var i = 0
    while i < len(periods):
        out += String("FREEBUSY:") + _epoch_to_ical_utc(
            periods[i].start
        ) + String("/") + _epoch_to_ical_utc(periods[i].end) + String("\r\n")
        i += 1
    out += String("END:VFREEBUSY\r\n" "END:VCALENDAR\r\n")
    return out^


def _epoch_to_ical_utc(epoch_s: Int64) -> String:
    """Format an epoch second as an iCalendar UTC DATE-TIME (`YYYYMMDDTHHMMSSZ`).
    """
    var days = Int(epoch_s // Int64(86400))
    var rem = Int(epoch_s % Int64(86400))
    if rem < 0:
        rem += 86400
        days -= 1
    var c = _civil_from_days_local(days)
    var h = rem // 3600
    var mi = (rem % 3600) // 60
    var s = rem % 60
    var out = String("")
    out += _pad4(c.y)
    out += _pad2(c.m)
    out += _pad2(c.d)
    out += "T"
    out += _pad2(h)
    out += _pad2(mi)
    out += _pad2(s)
    out += "Z"
    return out^


@fieldwise_init
struct _Civ(Movable, Deinitable):
    var y: Int
    var m: Int
    var d: Int


def _civil_from_days_local(z_in: Int) -> _Civ:
    """Howard Hinnant `civil_from_days` (local copy to keep the report layer
    self-contained — same algorithm as icalendar.civil_from_days)."""
    var z = z_in + 719468
    var era = (z if z >= 0 else z - 146096) // 146097
    var doe = z - era * 146097
    var yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    var y = yoe + era * 400
    var doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    var mp = (5 * doy + 2) // 153
    var d = doy - (153 * mp + 2) // 5 + 1
    var m = mp + 3 if mp < 10 else mp - 9
    var year = y + 1 if m <= 2 else y
    return _Civ(year, m, d)


def _pad2(v: Int) -> String:
    var out = String("")
    if v < 10:
        out += "0"
    out += String(v)
    return out^


def _pad4(v: Int) -> String:
    var out = String("")
    if v < 1000:
        out += "0"
    if v < 100:
        out += "0"
    if v < 10:
        out += "0"
    out += String(v)
    return out^
