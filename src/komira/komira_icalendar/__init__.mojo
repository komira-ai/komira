"""`komira_icalendar` — RFC 5545 calendar SEMANTICS, with no transport attached.

★ WHAT THIS PACKAGE IS. The iCalendar data model and the algorithms over it:
the lexer (line unfolding, `NAME;PARAMS:VALUE` splitting, TEXT escape/unescape),
the RRULE recurrence engine, VTIMEZONE / TZID resolution with an embedded IANA
fallback table, and the busy-interval algebra + VFREEBUSY emitter. Nothing here
knows what carried the bytes.

★ WHY IT EXISTS. `.ics` is not CalDAV. The SAME `VEVENT` parse and the SAME
RRULE expansion are needed by an iMIP `text/calendar` MIME part (RFC 6047), by
an `.ics` subscription feed served over a plain `GET`, and by a cross-vendor
availability overlay — none of which speak WebDAV. The format outlives any one
transport, so it lives in a package of its own.

★ THE PACKAGE IS A ZERO-DEPENDENCY LEAF, AND THAT IS THE POINT. It imports
nothing from the rest of the tree — no HTTP, no object store, no async, not even
`komira_core`. A consumer that wants to read an `.ics` pays for an `.ics`
parser and nothing else. Any edge that would make this package need a transport
is a bug in the edge, not a missing dep here.

WHAT IS IN IT:
  * `icalendar`       — the RFC 5545 reader. Unfolds folded content lines,
                        walks BEGIN/END components, parses the VEVENT properties
                        (`UID`, `DTSTART`, `DTEND`, `SUMMARY`, `RRULE`, `EXDATE`,
                        `RDATE`, `RECURRENCE-ID`, `TRANSP`), and carries
                        VTIMEZONE definitions through for the resolver. Civil-
                        date arithmetic is Howard Hinnant's `days_from_civil`
                        (pure Mojo, NO FFI).
  * `icalendar_emit`  — the WRITE side: `VEvent` /
                        `VCalendar` -> RFC 5545 text, with UTF-8-safe 75-octet
                        line folding, grammar-driven param quoting and the TEXT
                        escape. iTIP is a protocol in which BOTH parties speak,
                        so a reader alone could receive an invitation but never
                        issue one.
  * `icalendar_recur` — RRULE expansion (`FREQ` DAILY/WEEKLY/MONTHLY/YEARLY,
                        `INTERVAL`, `COUNT`, `UNTIL`, `BYDAY` incl. ordinals,
                        `BYMONTHDAY`, `BYMONTH`, `BYSETPOS`, `WKST`), `EXDATE` /
                        `RDATE` / `RECURRENCE-ID` overrides, and VTIMEZONE-driven
                        TZID -> true-UTC resolution honouring the embedded DST
                        rules. Expansion is BOUNDED by `MAX_INSTANCES`.
  * `freebusy`        — `BusyPeriod`, the interval merge, and the VFREEBUSY
                        document builder.

Encapsulation: owned `String` / scalar / `List` value surface; ZERO
UnsafePointer in any signature; no wildcard origin; no byte-slab; no
take_pointee.
"""

from .icalendar import (
    VEvent,
    VCalendar,
    VTimeZone,
    TzSubComponent,
    CalAddress,
    Civil,
    parse_vcalendar,
    parse_cal_address,
    empty_cal_address,
    dequote_param,
    event_overlaps_range,
    days_from_civil,
    civil_from_days,
    bytes_to_string,
)
from .icalendar_recur import (
    EventInstance,
    RRule,
    ByDayItem,
    MAX_INSTANCES,
    FREQ_NONE,
    FREQ_DAILY,
    FREQ_WEEKLY,
    FREQ_MONTHLY,
    FREQ_YEARLY,
    parse_rrule,
    expand_event,
    tz_offset_seconds_at,
    embedded_zone_for,
)
from .icalendar_emit import (
    ICAL_FOLD_OCTETS,
    ICAL_PRODID,
    ical_escape,
    fold_line,
    format_utc_datetime,
    format_date,
    emit_cal_address,
    emit_vevent,
    emit_vcalendar,
)
from .itip import (
    ITIP_METHOD_REQUEST,
    ITIP_METHOD_REPLY,
    ITIP_METHOD_CANCEL,
    ITIP_METHOD_PUBLISH,
    ITIP_METHOD_COUNTER,
    ITIP_METHOD_DECLINECOUNTER,
    ITIP_METHOD_ADD,
    ITIP_METHOD_REFRESH,
    PARTSTAT_NEEDS_ACTION,
    PARTSTAT_ACCEPTED,
    PARTSTAT_DECLINED,
    PARTSTAT_TENTATIVE,
    PARTSTAT_DELEGATED,
    is_valid_partstat,
    ItipBinding,
    ITIP_BIND_PASS,
    ITIP_BIND_DOWNGRADE,
    ITIP_BIND_REFUSE,
    ITIP_INGEST_SES,
    ITIP_INGEST_POSTMARK_WEBHOOK,
    ITIP_INGEST_SMTP_DIRECT,
    check_itip_sender_binding,
    domain_of,
    ItipDecision,
    ITIP_CREATE,
    ITIP_UPDATE,
    ITIP_SET_PARTSTAT,
    ITIP_CANCEL_SERIES,
    ITIP_CANCEL_INSTANCE,
    ITIP_IGNORE_STALE,
    ITIP_IGNORE_UNKNOWN_OBJECT,
    ITIP_IGNORE_UNSUPPORTED,
    ITIP_REFUSE_NOT_SCHEDULING,
    ITIP_REFUSE_UNBOUND,
    ITIP_REFUSE_ORGANIZER_MISMATCH,
    ITIP_REFUSE_MALFORMED,
    supersedes,
    decide_itip,
    build_reply,
    build_cancel,
    build_request,
)
from .freebusy import (
    BusyPeriod,
    FREE_BUSY_TRUNCATED_PROP,
)
