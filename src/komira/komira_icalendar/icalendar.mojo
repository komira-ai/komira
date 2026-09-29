# =============================================================================
# komira_icalendar/icalendar.mojo — a minimal RFC 5545 (iCalendar) parser
# =============================================================================
#
# The PARSE-ON-READ substrate that calendar REPORT handlers (calendar-query
# time-range filtering + calendar-multiget + sync-collection) run against, and
# the structure a calendar adapter lowers into its own records.
#
# WHAT THIS PARSER DOES (the deliberate scope):
#   * UNFOLD folded content lines — RFC 5545 §3.1: a CRLF immediately followed
#     by a single LWSP (space or HTAB) is a line continuation; the CRLF + the
#     ONE leading whitespace are removed and the bytes are concatenated to the
#     prior logical line. We accept bare LF folds too (lenient — some clients
#     emit `\n ` rather than `\r\n `).
#   * Recognize BEGIN:VCALENDAR / BEGIN:VEVENT ... END:VEVENT blocks. Each
#     VEVENT becomes one `VEvent`. Properties OUTSIDE a VEVENT (PRODID, VERSION,
#     CALSCALE) and other components (VTODO / VTIMEZONE / VJOURNAL / VALARM) are
#     IGNORED by the VEVENT walk (VALARM nested inside a VEVENT is skipped wholesale so
#     its TRIGGER/ACTION lines never leak into the VEVENT).
#   * Parse the VEVENT properties: UID, DTSTART, DTEND, SUMMARY,
#     RRULE (stored OPAQUE — the raw RRULE string; expansion is
#     `icalendar_recur`'s job).
#
# DATE-TIME / TZID SIMPLIFICATION (documented, deliberate):
#   A DTSTART / DTEND value is ONE of:
#     (a) a DATE-TIME in UTC: `20260615T130000Z`        -> the exact UTC instant.
#     (b) a FLOATING / local DATE-TIME: `20260615T130000` (optionally with a
#         `TZID=<zone>` parameter) -> we normalize to a COMPARABLE INSTANT by
#         treating the wall-clock as if it were UTC. We do NOT carry an Olson
#         tz database in the parser, so the TZID is RECORDED (VEvent.tzid) for
#         provenance but NOT used to shift the instant. This is correct for
#         time-range OVERLAP filtering as long as the query's range bounds use
#         the same convention (the test drives Z-suffixed UTC ranges); it can be
#         off by the zone offset for a TZID-local event vs. a UTC query bound.
#         `icalendar_recur` applies the zone. The simplification is LOCAL to
#         `_parse_ical_instant` — every consumer sees a single Int64 epoch-second
#         instant.
#     (c) a DATE value: `20260615` (the `VALUE=DATE` all-day form) -> midnight
#         UTC of that civil day; `all_day=True` is set. An all-day event with no
#         DTEND spans exactly one day (DTSTART .. DTSTART+1day), per RFC 5545.
#   The instant is an epoch SECOND (Int64). 0 is the "unparseable / absent"
#   sentinel (the bi-temporal / overlap logic treats a 0 start as non-matching).
#
# Civil-date arithmetic is Howard Hinnant's `days_from_civil` (proleptic
# Gregorian), in pure Mojo; NO FFI, NO build dep.
#
# Encapsulation: owned `String` / scalar / `List` surface; ZERO UnsafePointer
# in any signature; no wildcard origin; no byte-slab; no take_pointee.
# =============================================================================


# -----------------------------------------------------------------------------
# §1 — the parsed value types.
# -----------------------------------------------------------------------------


@fieldwise_init
struct CalAddress(Copyable, Movable, Deinitable):
    """One ORGANIZER or ATTENDEE property: a CAL-ADDRESS value plus its params.

    ★ WHY THIS TYPE EXISTS (iMIP). RFC 5546
    (iTIP) is a SCHEDULING protocol layered on RFC 5545, and every one of its
    flows is keyed on who asked and who answered: a REQUEST carries an
    `ORGANIZER` and one `ATTENDEE` per invitee, a REPLY carries the replying
    `ATTENDEE` with its `PARTSTAT`, a CANCEL carries the `ORGANIZER`. A
    single-user calendar entry has no person in it at all; that is the whole
    difference between storing a calendar and scheduling with someone.

    ⚠ **`email` IS THE SECURITY-RELEVANT FIELD, AND IT IS NOT THE `From:`
    HEADER.** RFC 6047 §2.3: *"The relevant address MUST be ascertained by
    opening the `text/calendar` MIME body part and examining the `ATTENDEE` and
    `ORGANIZER` properties"* — the RFC 5322 `Sender` / `Reply-To` headers cannot
    be relied on. §3 names both spoofing threats (Organizer AND Attendee)
    directly. `itip.check_organizer_binding` is the control that binds this
    field to an authenticated sending domain; see that function for what it does
    and does NOT cover.

    Fields:
        value: the CAL-ADDRESS value VERBATIM, e.g. `mailto:jane@example.com`.
            Kept raw so a REPLY can echo the organiser's own spelling back
            (RFC 5546 §3.2.3: a REPLY MUST NOT alter properties it echoes).
        email: the normalized addr-spec — `value` with a case-insensitive
            `mailto:` scheme stripped and the result lowercased. "" if `value`
            is not a `mailto:` URI. RFC 5545 permits any URI; in practice iMIP
            is mailto-only, and a non-mailto CAL-ADDRESS must NOT silently
            compare equal to some address.
        cn: the `CN` param (common name), dequoted. "" if absent.
        partstat: the `PARTSTAT` param UPPERCASED (`NEEDS-ACTION` / `ACCEPTED` /
            `DECLINED` / `TENTATIVE` / `DELEGATED`). "" if absent — deliberately
            NOT defaulted here, because "the sender said nothing" and "the sender
            said NEEDS-ACTION" are different facts to the state machine.
        role: the `ROLE` param UPPERCASED (`REQ-PARTICIPANT` / `OPT-PARTICIPANT`
            / `NON-PARTICIPANT` / `CHAIR`). "" if absent.
        cutype: the `CUTYPE` param UPPERCASED (`INDIVIDUAL` / `GROUP` /
            `RESOURCE` / `ROOM` / `UNKNOWN`). "" if absent.
        rsvp: True iff the `RSVP` param is `TRUE` (case-insensitive). RFC 5545
            §3.2.17 defaults it FALSE.
        sent_by: the `SENT-BY` param, dequoted — a delegate acting for this
            address. "" if absent. ⚠ Security-relevant: a message whose
            ORGANIZER carries SENT-BY is claiming "someone else sent this on the
            organiser's behalf", which is the shape a spoof takes.
        delegated_to: the `DELEGATED-TO` param RAW (may be a quoted,
            comma-separated list). "" if absent.
        delegated_from: the `DELEGATED-FROM` param RAW. "" if absent.
    """

    var value: String
    var email: String
    var cn: String
    var partstat: String
    var role: String
    var cutype: String
    var rsvp: Bool
    var sent_by: String
    var delegated_to: String
    var delegated_from: String

    def is_present(self) -> Bool:
        """True iff this address was present on the VEVENT. An ABSENT organiser
        is an empty `CalAddress`, not an Optional — that keeps `VEvent`
        `@fieldwise_init` and every field pointer-free."""
        return self.value.byte_length() > 0


def empty_cal_address() -> CalAddress:
    """The absent-address sentinel: every field empty, `rsvp` False."""
    return CalAddress(
        String(""),
        String(""),
        String(""),
        String(""),
        String(""),
        String(""),
        False,
        String(""),
        String(""),
        String(""),
    )


@fieldwise_init
struct VEvent(Copyable, Movable, Deinitable):
    """One parsed VEVENT block.

    Fields:
        uid: The event UID (RFC 5545 §3.8.4.7; the stable cross-instance id).
        summary: The SUMMARY text (event title; may be "").
        dtstart: The DTSTART as an epoch SECOND (the comparable instant; see the
            DATE-TIME/TZID simplification in the module header). 0 if absent.
        dtend: The DTEND as an epoch second. 0 if absent — a consumer that needs
            an end treats an absent DTEND as DTSTART (a zero-length instant) for
            a timed event, or DTSTART + 1 day for an all-day event.
        all_day: True iff DTSTART was a DATE value (`VALUE=DATE` / no time
            component) — the event is a whole-day event.
        rrule: The RRULE recurrence rule string, OPAQUE (e.g.
            `FREQ=WEEKLY;BYDAY=MO`). NO expansion here (see `icalendar_recur`)
            — a filter over this field alone matches the master DTSTART/DTEND. "" if the event is non-recurring.
        tzid: The DTSTART `TZID=` parameter value (provenance only — NOT applied
            to the instant by the parser). "" if the value was UTC / floating /
            all-day.

    ★ THE SCHEDULING HALF is the last seven fields. They are what makes this an
    ITIP-capable object rather than a calendar-entry one: `organizer`, `attendees`,
    `sequence`, `status`, `dtstamp`, `description`, `location`. RFC 5546 §3.2
    makes `ORGANIZER`, `UID`, `SEQUENCE`, `DTSTAMP` and `DTSTART` REQUIRED on a
    REQUEST, so an object without them cannot express one.
    """

    var uid: String
    var summary: String
    var dtstart: Int64
    var dtend: Int64
    var all_day: Bool
    var rrule: String
    var tzid: String
    # Recurrence + tz fields:
    var has_tz: Bool                     # True iff DTSTART carried a TZID param
    #                                      (so the expander tz-resolves it; a
    #                                      floating / UTC value has has_tz=False).
    var recurrence_id: String            # the RECURRENCE-ID raw value ("" if
    #                                      this VEVENT is a master, not a detached
    #                                      override instance).
    var recurrence_id_instant: Int64     # the RECURRENCE-ID as a comparable
    #                                      LOCAL-wall instant (the occurrence this
    #                                      override replaces). 0 if no RECURRENCE-ID.
    var exdates: List[Int64]             # EXDATE comparable LOCAL-wall instants.
    var rdates: List[Int64]              # RDATE comparable LOCAL-wall instants.
    var transp: String                   # the TRANSP value ("OPAQUE" default /
    #                                      "TRANSPARENT" -> excluded from busy).
    # --- iTIP scheduling properties (RFC 5546) ------------------------------
    var organizer: CalAddress            # the ORGANIZER. `is_present()` False
    #                                      if the VEVENT carried none (which
    #                                      makes it a non-scheduling event —
    #                                      RFC 5546 §3.2 requires ORGANIZER on
    #                                      every REQUEST / REPLY / CANCEL).
    var attendees: List[CalAddress]      # every ATTENDEE, in document order.
    var sequence: Int64                  # SEQUENCE (RFC 5545 §3.8.7.4). The
    #                                      REVISION COUNTER: a higher SEQUENCE
    #                                      obsoletes a lower one. DEFAULT 0 when
    #                                      absent, per the RFC — so 0 is a real
    #                                      value here, not a sentinel.
    var status: String                   # STATUS UPPERCASED — "TENTATIVE" /
    #                                      "CONFIRMED" / "CANCELLED". "" absent.
    var dtstamp: Int64                   # DTSTAMP as an epoch SECOND (always
    #                                      UTC per RFC 5545 §3.8.7.2). 0 if
    #                                      absent. The SEQUENCE TIEBREAKER: when
    #                                      two messages carry the same SEQUENCE,
    #                                      the later DTSTAMP wins.
    var description: String              # DESCRIPTION, unescaped. "" if absent.
    var location: String                 # LOCATION, unescaped. "" if absent.

    def effective_end(self) -> Int64:
        """The event's effective END instant for overlap math. An explicit DTEND
        wins; else an all-day event ends one day after DTSTART; else (a timed
        event with no DTEND) the end equals the start (a zero-length instant)."""
        if self.dtend != Int64(0):
            return self.dtend
        if self.all_day and self.dtstart != Int64(0):
            return self.dtstart + Int64(86400)
        return self.dtstart

    def is_recurring(self) -> Bool:
        """True iff the event carries an RRULE (a recurrence rule)."""
        return self.rrule.byte_length() > 0

    def is_transparent(self) -> Bool:
        """True iff TRANSP:TRANSPARENT — the event does not consume time (RFC
        5545 §3.8.2.7); free-busy aggregation excludes it."""
        return _upper(self.transp) == "TRANSPARENT"

    def is_cancelled(self) -> Bool:
        """True iff STATUS:CANCELLED (RFC 5545 §3.8.1.11) — the property a
        CANCEL sets, and the reason a cancelled instance must keep occupying its
        row rather than being deleted (a later REQUEST can revive it)."""
        return self.status == "CANCELLED"

    def find_attendee(self, email_lower: String) -> Int:
        """The index in `attendees` whose normalized `email` equals
        `email_lower`, or -1. Matching is on the NORMALIZED addr-spec, never on
        the raw CAL-ADDRESS: `MAILTO:Jane@Example.COM` and `mailto:jane@example.com`
        are the same attendee and must not produce two rows.

        ⚠ Returns -1 for an empty `email_lower` even if some attendee's `email`
        is also "" — a non-mailto CAL-ADDRESS (which normalizes to "") must not
        match every lookup. That is a fail-closed choice: an unmatched attendee
        makes a REPLY get refused, a spuriously-matched one lets any party set
        any other party's PARTSTAT."""
        if email_lower.byte_length() == 0:
            return -1
        var i = 0
        while i < len(self.attendees):
            if self.attendees[i].email == email_lower:
                return i
            i += 1
        return -1

    def itip_key(self) -> String:
        """The iTIP identity of this VEVENT: `UID` for a whole series, or
        `UID + "\\x1f" + RECURRENCE-ID` for a detached instance (RFC 5546 §1.4 —
        *"the UID + RECURRENCE-ID"* pair is the scheduling object identifier).

        The separator is US (0x1f), which cannot occur in either component: a
        UID is a text value that in practice is an addr-spec-shaped token, and a
        RECURRENCE-ID is a DATE-TIME. Using it means the key is unambiguous
        without escaping, so `a` + `b|c` and `a|b` + `c` cannot collide."""
        if self.recurrence_id.byte_length() == 0:
            return self.uid
        return self.uid + chr(0x1F) + self.recurrence_id


# -----------------------------------------------------------------------------
# §1b — VTIMEZONE (RFC 5545 §3.6.5): the embedded zone definition the .ics
# carries inline so a TZID-local instant can be resolved to true UTC with NO
# external Olson db. Each VTIMEZONE has one or more STANDARD/DAYLIGHT
# sub-components giving the offset-in-force + the DST transition rule.
# -----------------------------------------------------------------------------


@fieldwise_init
struct TzSubComponent(Copyable, Movable, Deinitable):
    """One STANDARD or DAYLIGHT block of a VTIMEZONE.

    Fields:
        is_daylight: True for a DAYLIGHT block, False for STANDARD.
        offset_from: the TZOFFSETFROM as SECONDS east of UTC (e.g. UTC-5 ->
            -18000). The offset in force BEFORE this transition.
        offset_to: the TZOFFSETTO as seconds east of UTC — the offset this block
            puts in force AFTER its onset.
        dt_year/dt_month/dt_day: the block's DTSTART civil date (the onset, in
            the offset_from wall clock). For an RRULE block this is the FIRST
            onset; the RRULE projects it to other years.
        dt_hour/dt_min/dt_sec: the onset time-of-day.
        has_rrule: True iff the block carries an `FREQ=YEARLY` onset rule.
        r_month: the RRULE BYMONTH (1..12) — the month the transition fires.
        r_ord: the RRULE BYDAY ordinal (e.g. 2 for "2nd Sunday", -1 for "last").
        r_wd: the RRULE BYDAY weekday (0=SU..6=SA).
    """

    var is_daylight: Bool
    var offset_from: Int
    var offset_to: Int
    var dt_year: Int
    var dt_month: Int
    var dt_day: Int
    var dt_hour: Int
    var dt_min: Int
    var dt_sec: Int
    var has_rrule: Bool
    var r_month: Int
    var r_ord: Int
    var r_wd: Int


@fieldwise_init
struct VTimeZone(Copyable, Movable, Deinitable):
    """A parsed VTIMEZONE: its TZID + its STANDARD/DAYLIGHT sub-components. An
    empty `subs` list (or empty `tzid`) resolves as a no-op (UTC-treated)."""

    var tzid: String
    var subs: List[TzSubComponent]


@fieldwise_init
struct VCalendar(Movable, Deinitable):
    """A parsed VCALENDAR: the VEVENT blocks + the VTIMEZONE definitions it
    contains. Owned Lists of value-typed components; no pointer fields.

    `method` is the RFC 5546 `METHOD:` property UPPERCASED — `REQUEST` /
    `REPLY` / `CANCEL` / `PUBLISH` / … — and "" when absent. ⚠ **An absent
    METHOD is not a defect; it is the discriminator.** RFC 5545 §3.7.2: a
    VCALENDAR with no METHOD is a plain calendar OBJECT (what a CalDAV PUT or an
    `.ics` file carries), and one WITH a METHOD is an iTIP SCHEDULING MESSAGE.
    They must not be conflated: an `.ics` a user imported from a website is not
    an invite from that website, and treating it as one is the whole reason
    RFC 6047 §2.4 makes the MIME `method=` parameter and this property agree."""

    var events: List[VEvent]
    var timezones: List[VTimeZone]
    var method: String


# -----------------------------------------------------------------------------
# §2 — line unfolding (RFC 5545 §3.1).
# -----------------------------------------------------------------------------


def bytes_to_string(b: List[UInt8]) -> String:
    """Byte-EXACT `List[UInt8]` -> `String`. PUBLIC: `itip.mojo` needs the same
    guarantee when it lowercases an IDN domain, and two spellings of one domain
    comparing unequal is a security bug in the binding control, not a cosmetic
    one.

    ⚠ THIS EXISTS BECAUSE `out += chr(Int(byte))` IS LOSSY ABOVE U+007F, and
    that idiom is easy to reach for on a text-value path. `chr` maps a BYTE to a CODEPOINT: byte 0xC3 becomes
    U+00C3, which re-encodes as the TWO bytes 0xC3 0x83. So `é` (0xC3 0xA9)
    would come out of `_unfold` as four bytes, and the next byte-loop would
    double it again — an accented SUMMARY, DESCRIPTION, LOCATION or CN corrupted
    on every parse, silently, growing each pass.

    `test_icalendar_emit` assertion (3) round-trips a 2-byte character
    positioned to straddle the fold point and compares BYTE LENGTH: byte-exact
    on both sides, it is 2.

    For ASCII this is bit-identical to a `chr` loop (`chr(c) == the byte` for
    c < 128), so no ASCII behaviour changes."""
    return String(unsafe_from_utf8=Span(b))


def _unfold(text: String) -> List[String]:
    """Unfold an iCalendar stream into logical lines.

    RFC 5545 §3.1: a CRLF (or, leniently, a bare LF) immediately followed by a
    single linear-whitespace char (SPACE or HTAB) is a fold — the line break and
    the ONE leading whitespace are removed and the remaining bytes are joined to
    the previous logical line. Returns the list of logical lines (no trailing
    CR/LF on any line)."""
    var lines = List[String]()
    var bs = text.as_bytes()
    var n = len(bs)
    var cur = List[UInt8]()
    var i = 0
    while i < n:
        var c = bs[i]
        if c == UInt8(0x0D):  # CR
            # Look past an optional LF to the next byte.
            var j = i + 1
            if j < n and bs[j] == UInt8(0x0A):
                j += 1
            # Fold iff the next byte is SPACE / HTAB.
            if j < n and (bs[j] == UInt8(0x20) or bs[j] == UInt8(0x09)):
                # Continuation: drop CRLF + the one leading whitespace.
                i = j + 1
                continue
            # Hard line break.
            lines.append(bytes_to_string(cur))
            cur = List[UInt8]()
            i = j
            continue
        if c == UInt8(0x0A):  # bare LF
            var j = i + 1
            if j < n and (bs[j] == UInt8(0x20) or bs[j] == UInt8(0x09)):
                i = j + 1
                continue
            lines.append(bytes_to_string(cur))
            cur = List[UInt8]()
            i = j
            continue
        cur.append(c)
        i += 1
    if len(cur) > 0:
        lines.append(bytes_to_string(cur))
    return lines^


# -----------------------------------------------------------------------------
# §3 — one content line -> (name, params, value).
#   A content line is `NAME[;PARAM=VAL[;...]]:VALUE`. The name + params are
#   before the FIRST unquoted ':'; the value is everything after it (a ':' inside
#   a quoted param value does not terminate; see `_split_content_line`).
# -----------------------------------------------------------------------------


@fieldwise_init
struct _ContentLine(Movable, Deinitable):
    var name: String       # the property name, UPPERCASE (e.g. "DTSTART").
    var params: String     # the raw param segment (e.g. "VALUE=DATE;TZID=...").
    var value: String      # everything after the first ':'.


def _split_content_line(line: String) -> _ContentLine:
    """Split `NAME[;PARAM=VAL[;…]]:VALUE` into its three parts.

    ★ QUOTE-AWARE, and that is load-bearing, not tidiness. RFC 5545 §3.1.1 lets a param value be a QUOTED-STRING, and a
    quoted param value MAY contain `:` and `;` — the RFC's own `DIR` example is
    literally `DIR="ldap://example.com:6666/o=ABC"`. Splitting on the first bare
    `:` cuts THAT line in the middle of a URL and yields a `DIR` param of
    `"ldap` plus a garbage value.

    The properties UID / SUMMARY / DTSTART / RRULE / TRANSP do not carry quoted
    params. It matters because `ATTENDEE` and `ORGANIZER` are the properties that carry `CN`,
    `DIR`, `SENT-BY` and `DELEGATED-TO` — all QUOTED-STRING in the wild, all
    routinely containing `:` (a `mailto:`/`ldap:` URI) or `,` (`CN="Doe, Jane"`).

    A quote-aware scan is strictly MORE correct than a first-colon split on
    every input — an unquoted line has no quotes to be inside — so it is not a
    behaviour flag. `test_icalendar_scheduling`'s
    `test_quoted_param_containing_colon_does_not_split_the_line` is the
    falsifier."""
    var bs = line.as_bytes()
    var n = len(bs)
    # Find the first ':' OUTSIDE a QUOTED-STRING (the name/params <-> value
    # separator). RFC 5545 §3.1.1 has no escape inside a quoted string — a DQUOTE
    # simply toggles, and a param value may not itself contain a DQUOTE — so a
    # single toggle flag is a complete parser for the grammar, not an
    # approximation of one.
    var colon = -1
    var in_q = False
    var i = 0
    while i < n:
        var c = bs[i]
        if c == UInt8(ord('"')):
            in_q = not in_q
        elif c == UInt8(ord(":")) and not in_q:
            colon = i
            break
        i += 1
    if colon < 0:
        # No value separator — a malformed line; name only.
        return _ContentLine(_upper(line), String(""), String(""))
    # The name+params segment is bs[0:colon]; split it on the first ';'. The
    # NAME cannot contain a quote (RFC 5545 §3.1: name is iana-token / x-name),
    # so the first unquoted ';' before `colon` is the param separator.
    var semi = -1
    var k = 0
    while k < colon:
        if bs[k] == UInt8(ord(";")):
            semi = k
            break
        k += 1
    # Byte-exact accumulation — see `bytes_to_string`. The NAME is an iana-token
    # (ASCII by grammar) but PARAMS carries CN and VALUE carries SUMMARY /
    # DESCRIPTION / LOCATION, all of which are free UTF-8 text.
    var name = List[UInt8]()
    var params = List[UInt8]()
    if semi < 0:
        # No params.
        var a = 0
        while a < colon:
            name.append(bs[a])
            a += 1
    else:
        var a = 0
        while a < semi:
            name.append(bs[a])
            a += 1
        var b = semi + 1
        while b < colon:
            params.append(bs[b])
            b += 1
    var value = List[UInt8]()
    var v = colon + 1
    while v < n:
        value.append(bs[v])
        v += 1
    return _ContentLine(
        _upper(bytes_to_string(name)), bytes_to_string(params), bytes_to_string(value)
    )


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


def _param_value(params: String, key_upper: String) -> String:
    """Extract the value of param `key_upper` (case-insensitive on the key) from
    the raw param segment `params` (`K1=V1;K2=V2`). Returns "" if absent. The
    returned value is RAW (un-unquoted; TZID values are bare in practice — use
    `dequote_param` when the value may be a QUOTED-STRING).

    Quote-aware for the same reason `_split_content_line` is: `CN="Doe; Jane"`
    is legal RFC 5545 §3.1.1 and a naive `;` split loses half the name."""
    var segs = _split_params(params)
    var i = 0
    while i < len(segs):
        var seg = segs[i]
        var eq = _index_of(seg, UInt8(ord("=")))
        if eq >= 0:
            var k = _upper(_substr(seg, 0, eq))
            if k == key_upper:
                return _substr(seg, eq + 1, len(seg.as_bytes()))
        i += 1
    return String("")


def _split_params(params: String) -> List[String]:
    """Split a raw param segment on `;` OUTSIDE any QUOTED-STRING."""
    var bs = params.as_bytes()
    var n = len(bs)
    var out = List[String]()
    var cur = String("")
    var in_q = False
    var i = 0
    while i < n:
        var c = bs[i]
        if c == UInt8(ord('"')):
            in_q = not in_q
            cur += chr(Int(c))
        elif c == UInt8(ord(";")) and not in_q:
            out.append(cur^)
            cur = String("")
        else:
            cur += chr(Int(c))
        i += 1
    out.append(cur^)
    return out^


def dequote_param(s: String) -> String:
    """Strip a surrounding DQUOTE pair from a param value, if present.

    RFC 5545 §3.1.1: a param value is either a `paramtext` (bare) or a
    `quoted-string`. There is NO escape sequence inside a quoted string — the
    DQUOTEs are pure delimiters — so removing the outer pair is the complete
    inverse, and any interior DQUOTE (which the grammar forbids) is left alone
    rather than guessed at."""
    var bs = s.as_bytes()
    var n = len(bs)
    if n >= 2 and bs[0] == UInt8(ord('"')) and bs[n - 1] == UInt8(ord('"')):
        return _substr(s, 1, n - 1)
    return s


def parse_cal_address(params: String, value: String) -> CalAddress:
    """Parse one ORGANIZER / ATTENDEE content line into a `CalAddress`.

    `value` is the CAL-ADDRESS (kept verbatim); `params` is the raw param
    segment. The normalized `email` is the `mailto:` addr-spec lowercased, or ""
    for any non-mailto URI — see `CalAddress.email` for why that is fail-closed
    rather than lenient."""
    var raw = _trim_value(value)
    return CalAddress(
        raw,
        _normalize_mailto(raw),
        dequote_param(_param_value(params, String("CN"))),
        _upper(dequote_param(_param_value(params, String("PARTSTAT")))),
        _upper(dequote_param(_param_value(params, String("ROLE")))),
        _upper(dequote_param(_param_value(params, String("CUTYPE")))),
        _upper(dequote_param(_param_value(params, String("RSVP")))) == "TRUE",
        dequote_param(_param_value(params, String("SENT-BY"))),
        _param_value(params, String("DELEGATED-TO")),
        _param_value(params, String("DELEGATED-FROM")),
    )


def _normalize_mailto(raw: String) -> String:
    """`mailto:Jane@Example.COM` -> `jane@example.com`; "" for any other scheme.

    The scheme match is case-INSENSITIVE (RFC 3986 §3.1: *"schemes are
    case-insensitive"*, and `MAILTO:` appears in the wild — Exchange emits it).
    The addr-spec is lowercased wholesale. ⚠ That is technically over-broad:
    RFC 5321 §2.4 says the LOCAL part is case-sensitive and only the domain is
    not. We lowercase both anyway, and deliberately, because every mail system
    this will ever talk to treats the local part case-insensitively, and the
    alternative — `Jane@x.com` and `jane@x.com` being two different attendees on
    one event — is a correctness bug the user would see and could not fix.
    ★ It is also what makes the ORGANIZER-binding comparison in
    `itip.check_organizer_binding` total: two spellings of one address must not
    produce a PASS and a REFUSE."""
    var bs = raw.as_bytes()
    if len(bs) < 7:
        return String("")
    var scheme = _upper(_substr(raw, 0, 7))
    if scheme != "MAILTO:":
        return String("")
    return _lower_ascii(_substr(raw, 7, len(bs)))


def _lower_ascii(s: String) -> String:
    """ASCII-lowercase (the inverse of `_upper`; non-ASCII bytes pass through)."""
    var bs = s.as_bytes()
    var out = String("")
    var i = 0
    while i < len(bs):
        var c = bs[i]
        if c >= UInt8(ord("A")) and c <= UInt8(ord("Z")):
            out += chr(Int(c) + 32)
        else:
            out += chr(Int(c))
        i += 1
    return out^


# -----------------------------------------------------------------------------
# §4 — the VEVENT block parser.
# -----------------------------------------------------------------------------


def parse_vcalendar(text: String) -> VCalendar:
    """Parse an iCalendar stream into a `VCalendar` of its VEVENT blocks + its
    VTIMEZONE definitions.

    Tolerant: lines outside a VEVENT / VTIMEZONE (PRODID / VERSION / CALSCALE)
    and other components (VTODO / VJOURNAL) are ignored. A VALARM nested INSIDE a
    VEVENT is skipped wholesale (its TRIGGER/ACTION never bleed into the event).
    VEVENTs are returned in document order; the VTIMEZONEs are resolved when the
    expander tz-resolves a TZID-local instant.

    Captures RRULE, EXDATE, RDATE, RECURRENCE-ID, TRANSP per VEVENT,
    and the embedded VTIMEZONE (STANDARD/DAYLIGHT offsets + DST onset rules)."""
    var events = List[VEvent]()
    var timezones = List[VTimeZone]()
    var lines = _unfold(text)

    var in_event = False
    var alarm_depth = 0  # >0 while inside a nested VALARM (skip its lines).
    var uid = String("")
    var summary = String("")
    var rrule = String("")
    var tzid = String("")
    var has_tz = False
    var dtstart = Int64(0)
    var dtend = Int64(0)
    var all_day = False
    var recurrence_id = String("")
    var recurrence_id_instant = Int64(0)
    var exdates = List[Int64]()
    var rdates = List[Int64]()
    var transp = String("")
    # iTIP scheduling accumulators.
    var organizer = empty_cal_address()
    var attendees = List[CalAddress]()
    var sequence = Int64(0)
    var status = String("")
    var dtstamp = Int64(0)
    var description = String("")
    var location = String("")
    # The VCALENDAR-level METHOD (RFC 5546) — outside any component.
    var method = String("")

    # VTIMEZONE accumulators.
    var in_tz = False
    var tz_id = String("")
    var tz_subs = List[TzSubComponent]()
    var in_sub = False
    var sub_is_daylight = False
    var sub_off_from = 0
    var sub_off_to = 0
    var sub_y = 0
    var sub_mo = 0
    var sub_d = 0
    var sub_h = 0
    var sub_mi = 0
    var sub_s = 0
    var sub_has_rrule = False
    var sub_r_month = 0
    var sub_r_ord = 0
    var sub_r_wd = -1

    var li = 0
    while li < len(lines):
        var cl = _split_content_line(lines[li])
        li += 1
        var name = cl.name

        if name == "BEGIN":
            var comp = _upper(cl.value)
            if comp == "VEVENT" and alarm_depth == 0 and not in_tz:
                in_event = True
                # Reset the per-event accumulators.
                uid = String("")
                summary = String("")
                rrule = String("")
                tzid = String("")
                has_tz = False
                dtstart = Int64(0)
                dtend = Int64(0)
                all_day = False
                recurrence_id = String("")
                recurrence_id_instant = Int64(0)
                exdates = List[Int64]()
                rdates = List[Int64]()
                transp = String("")
                organizer = empty_cal_address()
                attendees = List[CalAddress]()
                sequence = Int64(0)
                status = String("")
                dtstamp = Int64(0)
                description = String("")
                location = String("")
                continue
            if comp == "VTIMEZONE" and not in_event:
                in_tz = True
                tz_id = String("")
                tz_subs = List[TzSubComponent]()
                continue
            if in_tz and (comp == "STANDARD" or comp == "DAYLIGHT"):
                in_sub = True
                sub_is_daylight = (comp == "DAYLIGHT")
                sub_off_from = 0
                sub_off_to = 0
                sub_y = 0
                sub_mo = 0
                sub_d = 0
                sub_h = 0
                sub_mi = 0
                sub_s = 0
                sub_has_rrule = False
                sub_r_month = 0
                sub_r_ord = 0
                sub_r_wd = -1
                continue
            if in_event and comp == "VALARM":
                alarm_depth += 1
                continue
            # Any other BEGIN inside/outside an event we don't model.
            continue

        if name == "END":
            var comp = _upper(cl.value)
            if comp == "VALARM" and alarm_depth > 0:
                alarm_depth -= 1
                continue
            if (
                (comp == "STANDARD" or comp == "DAYLIGHT")
                and in_tz
                and in_sub
            ):
                tz_subs.append(
                    TzSubComponent(
                        sub_is_daylight,
                        sub_off_from,
                        sub_off_to,
                        sub_y,
                        sub_mo,
                        sub_d,
                        sub_h,
                        sub_mi,
                        sub_s,
                        sub_has_rrule,
                        sub_r_month,
                        sub_r_ord,
                        sub_r_wd,
                    )
                )
                in_sub = False
                continue
            if comp == "VTIMEZONE" and in_tz:
                timezones.append(VTimeZone(tz_id, tz_subs^))
                tz_subs = List[TzSubComponent]()
                in_tz = False
                continue
            if comp == "VEVENT" and in_event and alarm_depth == 0:
                events.append(
                    VEvent(
                        uid,
                        summary,
                        dtstart,
                        dtend,
                        all_day,
                        rrule,
                        tzid,
                        has_tz,
                        recurrence_id,
                        recurrence_id_instant,
                        exdates^,
                        rdates^,
                        transp,
                        # EXPLICIT copy: `organizer` is a per-event accumulator
                        # reset at the next BEGIN:VEVENT, so it cannot be moved
                        # out here. `CalAddress` is deliberately NOT
                        # ImplicitlyCopyable — a person-shaped value should copy
                        # only where someone wrote that it copies.
                        organizer.copy(),
                        attendees^,
                        sequence,
                        status,
                        dtstamp,
                        description,
                        location,
                    )
                )
                exdates = List[Int64]()
                rdates = List[Int64]()
                attendees = List[CalAddress]()
                in_event = False
                continue
            continue

        # --- inside a VTIMEZONE STANDARD/DAYLIGHT sub-component --------------
        if in_tz and in_sub:
            if name == "TZOFFSETFROM":
                sub_off_from = _parse_utc_offset(cl.value)
            elif name == "TZOFFSETTO":
                sub_off_to = _parse_utc_offset(cl.value)
            elif name == "DTSTART":
                var c = _parse_ical_civil(cl.value)
                sub_y = c.year
                sub_mo = c.month
                sub_d = c.day
                sub_h = c.hour
                sub_mi = c.minute
                sub_s = c.second
            elif name == "RRULE":
                var r = _parse_tz_rrule(cl.value)
                sub_has_rrule = r.ok
                sub_r_month = r.month
                sub_r_ord = r.ord
                sub_r_wd = r.wd
            continue
        if in_tz:
            if name == "TZID":
                tz_id = cl.value
            continue

        # --- a VCALENDAR-level property (outside every component) -----------
        # RFC 5546 §3.2: METHOD is a CALENDAR property, not an event one. It is
        # the discriminator between a scheduling MESSAGE and a plain calendar
        # OBJECT, so it is read here and nowhere else.
        if not in_event and not in_tz and alarm_depth == 0:
            if name == "METHOD":
                method = _upper(_trim_value(cl.value))
            continue

        if not in_event or alarm_depth > 0:
            continue

        # --- a VEVENT property line -----------------------------------------
        if name == "UID":
            uid = cl.value
        elif name == "SUMMARY":
            summary = _ical_unescape(cl.value)
        elif name == "RRULE":
            rrule = cl.value
        elif name == "TRANSP":
            transp = _upper(_trim_value(cl.value))
        elif name == "DTSTART":
            var inst = _parse_ical_instant(cl.params, cl.value)
            dtstart = inst.instant
            all_day = inst.is_date
            if inst.tzid.byte_length() > 0:
                tzid = inst.tzid
                has_tz = True
        elif name == "DTEND":
            var inst = _parse_ical_instant(cl.params, cl.value)
            dtend = inst.instant
        elif name == "RECURRENCE-ID":
            var inst = _parse_ical_instant(cl.params, cl.value)
            recurrence_id = cl.value
            recurrence_id_instant = inst.instant
        elif name == "EXDATE":
            _append_date_list(cl.params, cl.value, exdates)
        elif name == "RDATE":
            _append_date_list(cl.params, cl.value, rdates)
        # --- the iTIP scheduling properties (RFC 5546) ----------------------
        elif name == "ORGANIZER":
            organizer = parse_cal_address(cl.params, cl.value)
        elif name == "ATTENDEE":
            # RFC 5545 §3.8.4.1: ATTENDEE may appear MANY times on one VEVENT.
            # Every occurrence is appended — dedup is NOT done here, because
            # "the organiser listed jane twice" is a fact the state machine may
            # want to refuse rather than a defect the lexer should hide.
            attendees.append(parse_cal_address(cl.params, cl.value))
        elif name == "SEQUENCE":
            sequence = Int64(_digits_signed(_trim_value(cl.value)))
        elif name == "STATUS":
            status = _upper(_trim_value(cl.value))
        elif name == "DTSTAMP":
            var inst = _parse_ical_instant(cl.params, cl.value)
            dtstamp = inst.instant
        elif name == "DESCRIPTION":
            description = _ical_unescape(cl.value)
        elif name == "LOCATION":
            location = _ical_unescape(cl.value)

    return VCalendar(events^, timezones^, method^)


def _trim_value(s: String) -> String:
    """Trim leading/trailing ASCII whitespace from a property value."""
    var bs = s.as_bytes()
    var n = len(bs)
    var a = 0
    while a < n and (
        bs[a] == UInt8(0x20)
        or bs[a] == UInt8(0x09)
        or bs[a] == UInt8(0x0D)
        or bs[a] == UInt8(0x0A)
    ):
        a += 1
    var b = n
    while b > a and (
        bs[b - 1] == UInt8(0x20)
        or bs[b - 1] == UInt8(0x09)
        or bs[b - 1] == UInt8(0x0D)
        or bs[b - 1] == UInt8(0x0A)
    ):
        b -= 1
    return _substr(s, a, b)


def _append_date_list(params: String, value: String, mut into: List[Int64]):
    """Append the comparable LOCAL-wall instants from an EXDATE / RDATE value (a
    comma-separated list of DATE / DATE-TIME values sharing the property's
    TZID frame) to `into`."""
    var segs = _split_on(value, UInt8(ord(",")))
    var i = 0
    while i < len(segs):
        var inst = _parse_ical_instant(params, segs[i])
        if inst.instant != Int64(0):
            into.append(inst.instant)
        i += 1


# -----------------------------------------------------------------------------
# §4b — VTIMEZONE field parsers (offset, civil date-time, onset RRULE).
# -----------------------------------------------------------------------------


def _parse_utc_offset(s: String) -> Int:
    """Parse a TZOFFSETFROM/TZOFFSETTO value (`+HHMM` / `-HHMM` / `+HHMMSS`) to
    SECONDS east of UTC. `-0500` -> -18000."""
    var t = _trim_value(s)
    var bs = t.as_bytes()
    var n = len(bs)
    if n < 5:
        return 0
    var sign = 1
    var idx = 0
    if bs[0] == UInt8(ord("-")):
        sign = -1
        idx = 1
    elif bs[0] == UInt8(ord("+")):
        idx = 1
    var hh = _digits(t, idx, 2)
    var mm = _digits(t, idx + 2, 2)
    var ss = 0
    if (n - idx) >= 6:
        ss = _digits(t, idx + 4, 2)
    return sign * (hh * 3600 + mm * 60 + ss)


@fieldwise_init
struct _CivilParsed(Movable, Deinitable):
    var year: Int
    var month: Int
    var day: Int
    var hour: Int
    var minute: Int
    var second: Int


def _parse_ical_civil(value: String) -> _CivilParsed:
    """Parse a `YYYYMMDDTHHMMSS` (the VTIMEZONE sub-component DTSTART, which is a
    LOCAL wall-clock value, never Z) into its civil components."""
    var t = _trim_value(value)
    var y = _digits(t, 0, 4)
    var mo = _digits(t, 4, 2)
    var d = _digits(t, 6, 2)
    var h = _digits(t, 9, 2)
    var mi = _digits(t, 11, 2)
    var s = _digits(t, 13, 2)
    return _CivilParsed(y, mo, d, h, mi, s)


@fieldwise_init
struct _TzRRuleParsed(Movable, Deinitable):
    var ok: Bool
    var month: Int
    var ord: Int
    var wd: Int


def _parse_tz_rrule(value: String) -> _TzRRuleParsed:
    """Parse a VTIMEZONE onset RRULE (`FREQ=YEARLY;BYMONTH=3;BYDAY=2SU`). We need
    only BYMONTH + the single ordinal BYDAY (the DST onset). Returns ok=False if
    BYMONTH / BYDAY are absent."""
    var month = 0
    var ordn = 0
    var wd = -1
    var parts = _split_on(value, UInt8(ord(";")))
    var pi = 0
    while pi < len(parts):
        var kv = _split_on(parts[pi], UInt8(ord("=")))
        pi += 1
        if len(kv) < 2:
            continue
        var key = _upper(kv[0])
        var val = kv[1]
        if key == "BYMONTH":
            month = _digits_signed(val)
        elif key == "BYDAY":
            # Take the FIRST BYDAY token (DST rules carry a single ordinal day).
            var days = _split_on(val, UInt8(ord(",")))
            if len(days) > 0:
                var bd = _parse_tz_byday(days[0])
                ordn = bd.ord
                wd = bd.wd
    var ok = (month >= 1 and wd >= 0)
    return _TzRRuleParsed(ok, month, ordn, wd)


@fieldwise_init
struct _TzByDay(Movable, Deinitable):
    var ord: Int
    var wd: Int


def _parse_tz_byday(s: String) -> _TzByDay:
    """Parse a tz-rule BYDAY token (`2SU`, `-1SU`, `SU`) -> (ord, weekday)."""
    var t = _trim_value(s)
    var bs = t.as_bytes()
    var n = len(bs)
    if n < 2:
        return _TzByDay(0, -1)
    var wcode = String("")
    wcode += chr(Int(bs[n - 2]))
    wcode += chr(Int(bs[n - 1]))
    var wd = _tz_weekday(_upper(wcode))
    if wd < 0:
        return _TzByDay(0, -1)
    var ord_str = String("")
    var i = 0
    while i < n - 2:
        ord_str += chr(Int(bs[i]))
        i += 1
    var ordn = _digits_signed(ord_str) if len(ord_str.as_bytes()) > 0 else 0
    return _TzByDay(ordn, wd)


def _tz_weekday(s: String) -> Int:
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


def _digits_signed(s: String) -> Int:
    var t = _trim_value(s)
    var bs = t.as_bytes()
    var n = len(bs)
    var sign = 1
    var i = 0
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


# -----------------------------------------------------------------------------
# §5 — DATE / DATE-TIME value -> a comparable epoch-second instant.
# -----------------------------------------------------------------------------


@fieldwise_init
struct _Instant(Movable, Deinitable):
    var instant: Int64   # epoch second (0 = unparseable / absent).
    var is_date: Bool    # True iff a DATE (all-day) value.
    var tzid: String     # the TZID param (provenance only).


def _parse_ical_instant(params: String, value: String) -> _Instant:
    """Parse a DTSTART/DTEND value into a comparable epoch-second instant.

    See the module header for the DATE-TIME / TZID simplification. The forms:
      * `20260615`               -> a DATE (all-day): midnight UTC of that day.
      * `20260615T130000Z`       -> a UTC DATE-TIME: the exact instant.
      * `20260615T130000`        -> a floating/local DATE-TIME: treated as UTC
                                    wall-clock (TZID recorded, not applied).
    """
    var tzid = _param_value(params, String("TZID"))
    var is_date_param = _param_value(params, String("VALUE")) == "DATE"
    var bs = value.as_bytes()
    var n = len(bs)

    # A DATE value: exactly 8 digits, no 'T'. (Also recognized via VALUE=DATE.)
    if n == 8 and not _has_T(value):
        var y = _digits(value, 0, 4)
        var mo = _digits(value, 4, 2)
        var d = _digits(value, 6, 2)
        return _Instant(_civil_epoch_s(y, mo, d, 0, 0, 0), True, tzid)
    if is_date_param and n >= 8:
        var y = _digits(value, 0, 4)
        var mo = _digits(value, 4, 2)
        var d = _digits(value, 6, 2)
        return _Instant(_civil_epoch_s(y, mo, d, 0, 0, 0), True, tzid)

    # A DATE-TIME value: `YYYYMMDDTHHMMSS[Z]`.
    if n >= 15:
        var y = _digits(value, 0, 4)
        var mo = _digits(value, 4, 2)
        var d = _digits(value, 6, 2)
        # value[8] is 'T'.
        var h = _digits(value, 9, 2)
        var mi = _digits(value, 11, 2)
        var s = _digits(value, 13, 2)
        # A trailing 'Z' means UTC; either way the parser treats the wall-clock as
        # the comparable instant (the TZID, if any, is recorded but not applied).
        return _Instant(_civil_epoch_s(y, mo, d, h, mi, s), False, tzid)

    # Unparseable.
    return _Instant(Int64(0), is_date_param, tzid)


def _has_T(s: String) -> Bool:
    var bs = s.as_bytes()
    var i = 0
    while i < len(bs):
        if bs[i] == UInt8(ord("T")) or bs[i] == UInt8(ord("t")):
            return True
        i += 1
    return False


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


def days_from_civil(y: Int, m: Int, d: Int) -> Int:
    """Days since 1970-01-01 for the civil date y-m-d (proleptic Gregorian).
    Howard Hinnant's `days_from_civil`.
    Public so the recurrence expander / tz resolver share the exact
    same proleptic-Gregorian arithmetic."""
    var yy = y
    if m <= 2:
        yy -= 1
    var era = (yy if yy >= 0 else yy - 399) // 400
    var yoe = yy - era * 400
    var mp = (m + 9) % 12
    var doy = (153 * mp + 2) // 5 + d - 1
    var doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468


def _days_from_civil(y: Int, m: Int, d: Int) -> Int:
    """Private alias retained for the existing call sites in this file."""
    return days_from_civil(y, m, d)


@fieldwise_init
struct Civil(Copyable, Movable, Deinitable):
    """A civil date (year/month/day) — the result of `civil_from_days`."""

    var year: Int
    var month: Int
    var day: Int


def civil_from_days(z_in: Int) -> Civil:
    """The inverse of `days_from_civil`: a day-count since 1970-01-01 ->
    (year, month, day). Howard Hinnant's `civil_from_days` (proleptic
    Gregorian)."""
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
    return Civil(year, m, d)


def _civil_epoch_s(y: Int, mo: Int, d: Int, h: Int, mi: Int, s: Int) -> Int64:
    """The UTC epoch in SECONDS for the civil date+time. Returns 0 for an
    obviously-invalid date (defensive — keeps the 0 sentinel meaningful)."""
    if y < 1 or mo < 1 or mo > 12 or d < 1 or d > 31:
        return Int64(0)
    var days = _days_from_civil(y, mo, d)
    var secs = Int64(days) * Int64(86400)
    secs += Int64(h) * Int64(3600) + Int64(mi) * Int64(60) + Int64(s)
    return secs


# -----------------------------------------------------------------------------
# §6 — small byte helpers (self-contained; no cross-module pointer crossing).
# -----------------------------------------------------------------------------


def _ical_unescape(s: String) -> String:
    r"""Unescape RFC 5545 §3.3.11 TEXT escapes in a value: `\n`/`\N` -> LF,
    `\,` -> ',', `\;` -> ';', `\\` -> '\'. Other backslash sequences pass
    through with the backslash dropped (lenient)."""
    var bs = s.as_bytes()
    var n = len(bs)
    # Byte-exact — this runs over SUMMARY / DESCRIPTION / LOCATION, the values
    # most likely to carry non-ASCII. See `bytes_to_string`.
    var out = List[UInt8]()
    var i = 0
    while i < n:
        var c = bs[i]
        if c == UInt8(ord("\\")) and i + 1 < n:
            var nx = bs[i + 1]
            if nx == UInt8(ord("n")) or nx == UInt8(ord("N")):
                out.append(UInt8(0x0A))
            elif nx == UInt8(ord(",")):
                out.append(UInt8(ord(",")))
            elif nx == UInt8(ord(";")):
                out.append(UInt8(ord(";")))
            elif nx == UInt8(ord("\\")):
                out.append(UInt8(ord("\\")))
            else:
                out.append(nx)
            i += 2
            continue
        out.append(c)
        i += 1
    return bytes_to_string(out)


def _split_on(s: String, sep: UInt8) -> List[String]:
    var out = List[String]()
    var bs = s.as_bytes()
    var n = len(bs)
    # Byte-exact (see `bytes_to_string`): this splits param segments, whose values
    # include CN — a human name, i.e. arbitrary UTF-8.
    var cur = List[UInt8]()
    var i = 0
    while i < n:
        if bs[i] == sep:
            out.append(bytes_to_string(cur))
            cur = List[UInt8]()
        else:
            cur.append(bs[i])
        i += 1
    out.append(bytes_to_string(cur))
    return out^


def _index_of(s: String, b: UInt8) -> Int:
    var bs = s.as_bytes()
    var i = 0
    while i < len(bs):
        if bs[i] == b:
            return i
        i += 1
    return -1


def _substr(s: String, start: Int, end: Int) -> String:
    var bs = s.as_bytes()
    var n = len(bs)
    var a = start if start >= 0 else 0
    var b = end if end <= n else n
    # Byte-exact (see `bytes_to_string`). NOTE the offsets are BYTE offsets, which
    # is what every caller computes (they scan `as_bytes()`), so slicing on
    # them and reassembling byte-for-byte is the consistent choice.
    var out = List[UInt8]()
    var i = a
    while i < b:
        out.append(bs[i])
        i += 1
    return bytes_to_string(out)


# -----------------------------------------------------------------------------
# §7 — time-range overlap (the calendar-query `time-range` predicate).
# -----------------------------------------------------------------------------


def event_overlaps_range(
    event: VEvent, range_start: Int64, range_end: Int64
) -> Bool:
    """True iff `event` overlaps the half-open range [range_start, range_end)
    (epoch seconds). RFC 4791 §9.9 — a VEVENT overlaps when its (start, end)
    intersects the range. A 0 (unset) range bound means "unbounded on that side".

    Overlap math (master DTSTART/DTEND only — NO recurrence expansion here,
    per the deliberate scope):
      * the event's span is [dtstart, effective_end()].
      * a zero-length event (effective_end == dtstart) overlaps iff dtstart is in
        [range_start, range_end).
    """
    var es = event.dtstart
    if es == Int64(0):
        return False  # an event with no parseable start never matches.
    var ee = event.effective_end()

    var lo_ok = True
    if range_end != Int64(0):
        # The event must START before the range ends.
        if ee == es:
            lo_ok = es < range_end
        else:
            lo_ok = es < range_end
    var hi_ok = True
    if range_start != Int64(0):
        # The event must END at or after the range start. A zero-length event
        # (ee == es) is included when es >= range_start.
        if ee == es:
            hi_ok = es >= range_start
        else:
            hi_ok = ee > range_start
    return lo_ok and hi_ok
