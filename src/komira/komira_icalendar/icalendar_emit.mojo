# =============================================================================
# komira_icalendar/icalendar_emit.mojo — the RFC 5545 WRITE side
# =============================================================================
#
# ★ WHY A READER IS NOT ENOUGH. iTIP (RFC 5546) is a protocol in which BOTH
# parties speak. A REQUEST is a document WE author and send; a REPLY is a
# document WE author in answer to someone else's REQUEST. `parse_vcalendar` can
# only ever tell us what somebody else said; without an emitter, a caller could
# read an invitation and never issue one, and an iMIP composer would have
# nothing to put in its `text/calendar` part.
#
# WHAT IT EMITS: a `VCALENDAR` carrying `METHOD` + one or more `VEVENT`s, with
# the RFC 5546 §3.2 scheduling properties (`ORGANIZER`, `ATTENDEE`, `SEQUENCE`,
# `DTSTAMP`, `STATUS`) that `VEvent` carries, as parsed by `icalendar.mojo`.
#
# ── THREE THINGS THAT ARE EASY TO GET WRONG, AND WHAT WE DO ─────────────────
#
# (1) LINE FOLDING IS A HARD LIMIT, NOT A STYLE CHOICE. RFC 5545 §3.1: *"Lines
#     of text SHOULD NOT be longer than 75 octets, excluding the line break."*
#     A single ATTENDEE line with a CN and a DIR blows past 75 easily, and some
#     receiving parsers DO truncate. We fold at 75 OCTETS — counted in bytes,
#     not characters, because the RFC counts octets — and we NEVER break inside
#     a multi-byte UTF-8 sequence: a fold placed between a lead byte and its
#     continuation bytes would make the unfolded result invalid UTF-8. The
#     fold point is walked backwards off any continuation byte (0x80..0xBF)
#     before the break is inserted. `_fold` is the only place byte-exactness
#     matters and it is the only place we go through `List[UInt8]`.
#
#     ⚠ The conversion back is `String(unsafe_from_utf8=...)`, NOT the
#     `chr(Int(b))` byte-loop that this package's own `_slice_str` uses. That loop is LOSSY above U+007F — byte
#     0xC3 becomes codepoint U+00C3, which re-encodes as TWO bytes — so an
#     accented SUMMARY would gain a byte every round trip. iMIP mandates
#     UTF-8 (see the composer's charset), so this is load-bearing here.
#
# (2) A PARAM VALUE IS QUOTED OR IT IS NOT, AND THE GRAMMAR DECIDES.
#     RFC 5545 §3.1.1: a `paramtext` may not contain `:` `;` `,` or DQUOTE; a
#     value containing any of the first three MUST be a `quoted-string`. `CN`
#     is the property that trips this constantly, because human names carry
#     commas (`CN=Doe, Jane`) — emitted bare, the `,` reads as a param-value
#     LIST separator and the name silently splits in two. `_param` decides by
#     inspecting the value, so a caller cannot forget.
#
#     ⚠ AND THERE IS NO ESCAPE INSIDE A QUOTED STRING. The grammar has no
#     mechanism at all — a DQUOTE simply cannot appear in a param value. We
#     DROP interior DQUOTEs rather than emit a line that re-parses as a
#     different value, and say so at `_param`. This is the one place the
#     emitter is not a total inverse of the parser, and it is a property of
#     RFC 5545, not of this code.
#
# (3) THE TEXT ESCAPE IS THE PARSER'S INVERSE, NOT AN HTML-STYLE SANITIZER.
#     `_ical_escape` mirrors `icalendar._ical_unescape` exactly: `\` `;` `,`
#     and LF. A SUMMARY of `Lunch; then coffee, maybe` must survive; unescaped,
#     the `;` would read as the start of a parameter and the `,` as a value
#     list. NOTE the deliberate asymmetry with (2): in a TEXT VALUE the escape
#     is backslash, in a PARAM VALUE it is quoting. Using one where the other
#     belongs is the classic iCalendar emitter bug.
#
# ── WHAT THIS FILE DELIBERATELY DOES NOT DO ─────────────────────────────────
# No RRULE emission beyond passing `VEvent.rrule` through OPAQUE (it is stored
# opaque; re-serializing it is a no-op by construction). No VALARM (a display
# detail of the RECEIVING calendar, not of the invitation).
#
# ★ NO VTIMEZONE EMISSION — AND THEREFORE `emit_vevent` REFUSES A TZID-LOCAL
# EVENT RATHER THAN EMITTING ONE. Every instant we emit is UTC (`...Z`), which
# is always legal, needs no zone definition, and is what an iTIP message should
# carry anyway since the organiser's zone is not the attendee's. But that is
# only sound when the instant IS UTC. For an event with `has_tz`, it is not:
# `icalendar.mojo` normalizes a TZID-local DATE-TIME "by treating the wall-clock
# as if it were UTC" and records the TZID WITHOUT applying it. Emitting that
# number with a `Z` would ship a 13:00 America/New_York meeting as `13:00Z` —
# well-formed, universally parseable, and five hours wrong. So `emit_vevent`
# raises, naming the TZID. See its docstring.
#
# Encapsulation: owned `String` / scalar / `List` surface; ZERO UnsafePointer
# in any signature; no wildcard origin; no byte-slab; no take_pointee.
# =============================================================================

from .icalendar import (
    VEvent,
    VCalendar,
    CalAddress,
    civil_from_days,
)


# The octet limit of RFC 5545 §3.1, excluding the CRLF. A folded continuation
# line begins with ONE space, which counts toward the next line's 75.
comptime ICAL_FOLD_OCTETS: Int = 75

# The default PRODID. RFC 5545 §3.7.3 makes one REQUIRED on every VCALENDAR.
comptime ICAL_PRODID: StaticString = "-//Komira//iMIP//EN"


# -----------------------------------------------------------------------------
# §1 — TEXT value escaping (the exact inverse of `icalendar._ical_unescape`).
# -----------------------------------------------------------------------------


def ical_escape(s: String) -> String:
    r"""Escape an RFC 5545 §3.3.11 TEXT value for emission: `\` -> `\\`,
    `;` -> `\;`, `,` -> `\,`, LF -> `\n`. A CR is DROPPED rather than escaped —
    the grammar has no `\r`, and a bare CR inside a value would be indis-
    tinguishable from the line break that terminates the content line.

    This duplicates the file-private `freebusy._ical_escape` deliberately: that
    one is private to the free/busy emitter, and this package's stated idiom is
    per-file self-containment."""
    var bs = s.as_bytes()
    var out = List[UInt8]()
    var i = 0
    while i < len(bs):
        var c = bs[i]
        if c == UInt8(ord("\\")):
            out.append(UInt8(ord("\\")))
            out.append(UInt8(ord("\\")))
        elif c == UInt8(ord(";")):
            out.append(UInt8(ord("\\")))
            out.append(UInt8(ord(";")))
        elif c == UInt8(ord(",")):
            out.append(UInt8(ord("\\")))
            out.append(UInt8(ord(",")))
        elif c == UInt8(0x0A):
            out.append(UInt8(ord("\\")))
            out.append(UInt8(ord("n")))
        elif c == UInt8(0x0D):
            pass
        else:
            # ⚠ APPEND THE BYTE, do NOT `out += chr(Int(c))`. `chr` maps a byte
            # to a CODEPOINT: byte 0xC3 becomes U+00C3, which re-encodes as the
            # TWO bytes 0xC3 0x83. Every non-ASCII character would double in
            # size on each pass. See the module header (1).
            out.append(c)
        i += 1
    return String(unsafe_from_utf8=Span(out))


# -----------------------------------------------------------------------------
# §2 — content-line folding (RFC 5545 §3.1), UTF-8 safe.
# -----------------------------------------------------------------------------


def _is_utf8_continuation(b: UInt8) -> Bool:
    """True iff `b` is a UTF-8 CONTINUATION byte (`10xxxxxx`, 0x80..0xBF) — a
    byte that may never begin a line, because it is the tail of a multi-byte
    character whose lead byte precedes it."""
    return (b & UInt8(0xC0)) == UInt8(0x80)


def fold_line(line: String) -> String:
    """Fold one logical content line to RFC 5545 §3.1's 75-octet limit,
    inserting `CRLF SPACE` at each break. The returned String has NO trailing
    CRLF (the caller joins lines).

    The break is placed at most `ICAL_FOLD_OCTETS` bytes in, then walked BACK
    off any UTF-8 continuation byte so a multi-byte character is never split.
    A pathological run (a single character wider than the limit cannot occur —
    UTF-8 maxes at 4 bytes — but a defensive floor keeps this total).

    Byte-exact throughout: the only transformation is INSERTION of the fold
    sequence, so `_unfold(fold_line(x)) == x` for every `x` with no CR/LF."""
    var bs = line.as_bytes()
    var n = len(bs)
    if n <= ICAL_FOLD_OCTETS:
        return line
    var out = List[UInt8]()
    var i = 0
    var first = True
    while i < n:
        # A continuation line spends one octet on its leading SPACE.
        var budget = ICAL_FOLD_OCTETS if first else ICAL_FOLD_OCTETS - 1
        var end = i + budget
        if end > n:
            end = n
        else:
            # Walk back off a continuation byte so the break lands on a
            # character boundary. Bounded: UTF-8 sequences are <= 4 bytes.
            var guard = 0
            while end > i and _is_utf8_continuation(bs[end]) and guard < 4:
                end -= 1
                guard += 1
            if end <= i:
                # Defensive: never make zero progress.
                end = i + budget
                if end > n:
                    end = n
        if not first:
            out.append(UInt8(0x0D))
            out.append(UInt8(0x0A))
            out.append(UInt8(0x20))
        var k = i
        while k < end:
            out.append(bs[k])
            k += 1
        i = end
        first = False
    # ⚠ NOT the `chr(Int(b))` loop — see the module header (1). That loop is
    # lossy above U+007F and every accented SUMMARY would grow on each pass.
    return String(unsafe_from_utf8=Span(out))


# -----------------------------------------------------------------------------
# §3 — parameter emission.
# -----------------------------------------------------------------------------


def _needs_quoting(v: String) -> Bool:
    """True iff `v` may not be emitted as a bare `paramtext` (RFC 5545 §3.1.1):
    it contains `:`, `;` or `,`."""
    var bs = v.as_bytes()
    var i = 0
    while i < len(bs):
        var c = bs[i]
        if (
            c == UInt8(ord(":"))
            or c == UInt8(ord(";"))
            or c == UInt8(ord(","))
        ):
            return True
        i += 1
    return False


def _strip_dquotes(v: String) -> String:
    """`v` with every DQUOTE removed.

    ⚠ THIS IS LOSSY AND THAT IS FORCED BY THE GRAMMAR, NOT CHOSEN. RFC 5545
    §3.1.1 gives a `quoted-string` NO escape mechanism whatsoever, so a param
    value containing a DQUOTE is simply not expressible. The alternatives were
    to emit it raw — which re-parses as a DIFFERENT value, silently truncating
    at the stray quote — or to refuse the whole message. Dropping the character
    keeps the address and the rest of the name intact and cannot change which
    party the line names, which is the property that matters for the
    ORGANIZER-binding control."""
    var bs = v.as_bytes()
    var out = String("")
    var i = 0
    while i < len(bs):
        if bs[i] != UInt8(ord('"')):
            out += chr(Int(bs[i]))
        i += 1
    return out^


def _param(name: String, value: String) -> String:
    """One `;NAME=VALUE` parameter, quoted iff the grammar requires it. Returns
    "" for an empty value so callers can append unconditionally."""
    if value.byte_length() == 0:
        return String("")
    if _needs_quoting(value):
        return String(";") + name + "=\"" + _strip_dquotes(value) + "\""
    return String(";") + name + "=" + _strip_dquotes(value)


# -----------------------------------------------------------------------------
# §4 — instants -> RFC 5545 DATE-TIME / DATE values.
# -----------------------------------------------------------------------------


def _pad2(n: Int) -> String:
    if n < 10:
        return String("0") + String(n)
    return String(n)


def _pad4(n: Int) -> String:
    if n < 10:
        return String("000") + String(n)
    if n < 100:
        return String("00") + String(n)
    if n < 1000:
        return String("0") + String(n)
    return String(n)


def format_utc_datetime(instant: Int64) -> String:
    """An epoch SECOND -> the RFC 5545 UTC DATE-TIME form `YYYYMMDDTHHMMSSZ`.

    Always UTC. An iTIP message crosses organisations, so the organiser's local
    zone is meaningless to the recipient and a `TZID=` would oblige us to emit
    a matching VTIMEZONE; the `Z` form is universally accepted and needs none."""
    var secs = Int(instant)
    var days = secs // 86400
    var rem = secs - days * 86400
    if rem < 0:
        rem += 86400
        days -= 1
    var c = civil_from_days(days)
    var hh = rem // 3600
    var mm = (rem - hh * 3600) // 60
    var ss = rem - hh * 3600 - mm * 60
    return (
        _pad4(c.year)
        + _pad2(c.month)
        + _pad2(c.day)
        + "T"
        + _pad2(hh)
        + _pad2(mm)
        + _pad2(ss)
        + "Z"
    )


def format_date(instant: Int64) -> String:
    """An epoch SECOND -> the RFC 5545 DATE form `YYYYMMDD` (the all-day
    `VALUE=DATE` value)."""
    var secs = Int(instant)
    var days = secs // 86400
    if secs - days * 86400 < 0:
        days -= 1
    var c = civil_from_days(days)
    return _pad4(c.year) + _pad2(c.month) + _pad2(c.day)


# -----------------------------------------------------------------------------
# §5 — CAL-ADDRESS emission (ORGANIZER / ATTENDEE).
# -----------------------------------------------------------------------------


def emit_cal_address(name: String, addr: CalAddress) -> String:
    """One `ORGANIZER` / `ATTENDEE` content line, UNFOLDED (the caller folds).
    "" if the address is absent, so callers can append unconditionally.

    Parameter order follows RFC 5545 §3.2's own listing. Only parameters that
    are PRESENT are emitted: `partstat` in particular is "" when the sender
    said nothing, and the parse side deliberately does not default it,
    so emitting a default here would manufacture the exact positive statement
    that side refused to invent.

    `value` is emitted VERBATIM, never the normalized `email` — RFC 5546
    §3.2.3 requires a REPLY to echo the organiser's properties unaltered, and
    re-spelling `MAILTO:` as `mailto:` is an alteration."""
    if not addr.is_present():
        return String("")
    var out = name
    out += _param(String("CN"), addr.cn)
    out += _param(String("CUTYPE"), addr.cutype)
    out += _param(String("ROLE"), addr.role)
    out += _param(String("PARTSTAT"), addr.partstat)
    if addr.rsvp:
        out += ";RSVP=TRUE"
    out += _param(String("DELEGATED-TO"), addr.delegated_to)
    out += _param(String("DELEGATED-FROM"), addr.delegated_from)
    out += _param(String("SENT-BY"), addr.sent_by)
    out += ":" + addr.value
    return out^


# -----------------------------------------------------------------------------
# §6 — VEVENT / VCALENDAR emission.
# -----------------------------------------------------------------------------


def _append_folded(mut buf: String, line: String):
    """Append one content line, folded, with its CRLF terminator."""
    if line.byte_length() == 0:
        return
    buf += fold_line(line)
    buf += "\r\n"


def emit_vevent(ev: VEvent) raises -> String:
    """One `BEGIN:VEVENT ... END:VEVENT` block, folded, CRLF-terminated.

    ★ RAISES ON A TZID-LOCAL EVENT (`has_tz`), AND THAT IS A CORRECTNESS
    REFUSAL, NOT A MISSING FEATURE. `VEvent.dtstart` is not a true UTC instant
    for such an event: `icalendar.mojo`'s header states the simplification
    plainly — a floating / TZID-local DATE-TIME is normalized "by treating the
    wall-clock as if it were UTC", and the TZID is recorded for provenance but
    NEVER applied to the instant. Emitting that number with a `Z` suffix
    therefore ASSERTS a UTC time that the value is not: a 13:00
    America/New_York meeting ships as `13:00Z`, which is 08:00 in New York.
    The document is perfectly well-formed, every recipient parses it
    successfully, and they all agree on a time five hours from the one the
    organiser chose. Silent, uniform, and wrong.

    The alternative to refusing is a VTIMEZONE emitter that faithfully
    round-trips a parsed zone definition, which does not exist. So this fails
    LOUDLY, at the point of the problem, naming the TZID.

    Property order is RFC 5546 §3.2's REQUEST listing: the identity properties
    (`UID`, `DTSTAMP`, `SEQUENCE`) first, then the parties, then the event
    detail. The RFC does not REQUIRE an order, but a stable one makes the
    output diffable and makes a byte-comparison test meaningful.

    `dtstart` / `dtend` of 0 are the parser's absent sentinel and are OMITTED
    rather than emitted as the 1970 epoch — an invitation to a meeting in 1970
    is worse than one with a missing field, which a receiver will reject
    loudly."""
    if ev.has_tz:
        raise Error(
            String(
                "icalendar_emit: refusing to emit VEVENT '"
            )
            + ev.uid
            + String(
                "' — it is TZID-local (TZID="
            )
            + ev.tzid
            + String(
                "), and its dtstart is a WALL-CLOCK reading rather than a true"
                " UTC instant (see icalendar.mojo's DATE-TIME/TZID"
                " simplification). Emitting it with a Z suffix would move the"
                " meeting by the zone offset while producing a perfectly"
                " well-formed document. Resolve the instant to true UTC before"
                " emitting, or add a VTIMEZONE emitter."
            )
        )

    var out = String("BEGIN:VEVENT\r\n")
    _append_folded(out, String("UID:") + ev.uid)
    if ev.dtstamp != Int64(0):
        _append_folded(out, String("DTSTAMP:") + format_utc_datetime(ev.dtstamp))
    # SEQUENCE 0 is a REAL value (RFC 5545 §3.8.7.4 makes 0 the default), and
    # RFC 5546 §3.2 makes the property REQUIRED on a REQUEST — so it is always
    # emitted, never suppressed as "empty".
    _append_folded(out, String("SEQUENCE:") + String(ev.sequence))
    if ev.dtstart != Int64(0):
        if ev.all_day:
            _append_folded(
                out, String("DTSTART;VALUE=DATE:") + format_date(ev.dtstart)
            )
        else:
            _append_folded(
                out, String("DTSTART:") + format_utc_datetime(ev.dtstart)
            )
    if ev.dtend != Int64(0):
        if ev.all_day:
            _append_folded(
                out, String("DTEND;VALUE=DATE:") + format_date(ev.dtend)
            )
        else:
            _append_folded(
                out, String("DTEND:") + format_utc_datetime(ev.dtend)
            )
    if ev.recurrence_id.byte_length() > 0:
        _append_folded(out, String("RECURRENCE-ID:") + ev.recurrence_id)
    if ev.rrule.byte_length() > 0:
        # OPAQUE passthrough — `rrule` is stored as the raw rule text, so
        # re-emitting it is an identity, not a re-serialization.
        _append_folded(out, String("RRULE:") + ev.rrule)
    _append_folded(out, emit_cal_address(String("ORGANIZER"), ev.organizer))
    var i = 0
    while i < len(ev.attendees):
        _append_folded(
            out, emit_cal_address(String("ATTENDEE"), ev.attendees[i])
        )
        i += 1
    if ev.summary.byte_length() > 0:
        _append_folded(out, String("SUMMARY:") + ical_escape(ev.summary))
    if ev.description.byte_length() > 0:
        _append_folded(
            out, String("DESCRIPTION:") + ical_escape(ev.description)
        )
    if ev.location.byte_length() > 0:
        _append_folded(out, String("LOCATION:") + ical_escape(ev.location))
    if ev.status.byte_length() > 0:
        _append_folded(out, String("STATUS:") + ev.status)
    if ev.transp.byte_length() > 0:
        _append_folded(out, String("TRANSP:") + ev.transp)
    out += "END:VEVENT\r\n"
    return out^


def emit_vcalendar(vcal: VCalendar, prodid: String) raises -> String:
    """A complete `VCALENDAR` document, CRLF-terminated throughout.

    ★ `METHOD` IS EMITTED AT THE VCALENDAR LEVEL AND NOWHERE ELSE, which is the
    write-side mirror of the parser's read-side rule that a `METHOD:` inside a
    VEVENT is ignored. RFC 6047 §2.4 requires the MIME `method=` parameter and
    this property to agree; keeping exactly one authoritative site on each side
    is what makes that check meaningful rather than ambiguous.

    An EMPTY `vcal.method` emits no METHOD line at all — producing a plain
    calendar OBJECT (RFC 5545 §3.7.2) rather than a scheduling message. That
    distinction is the parser's and it is preserved here: `.ics` export and
    invitation are different documents."""
    var out = String("BEGIN:VCALENDAR\r\n")
    _append_folded(out, String("PRODID:") + prodid)
    out += "VERSION:2.0\r\n"
    out += "CALSCALE:GREGORIAN\r\n"
    if vcal.method.byte_length() > 0:
        _append_folded(out, String("METHOD:") + vcal.method)
    var i = 0
    while i < len(vcal.events):
        out += emit_vevent(vcal.events[i])
        i += 1
    out += "END:VCALENDAR\r\n"
    return out^
