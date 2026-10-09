"""Test-only helpers of komira_calendar_ics_conformance: the zone tables the
vectors are read with, a vector's line breaks, and a report as text.

The zones are built from POSIX TZ strings (`komira_datetime.posix_zone`) with the
rules in force on the vectors' dates: `rfc_zones` has New York with the
rules of 1987 to 2006 (DST from the first Sunday of April to the last Sunday
of October), the rules RFC 5545's 1990s examples were written under;
`client_zones` has today's rules for New York, London and Berlin.
"""

from komira_calendar_ics import IcsImport, IcsReport, ZoneTable
from komira_proto_codec import encode_json
from komira_datetime import posix_zone


def rfc_zones() raises -> ZoneTable:
    """New York under the 1987-2006 United States rules."""
    var t = ZoneTable()
    t.add(posix_zone("America/New_York", "EST5EDT,M4.1.0,M10.5.0"))
    return t^


def client_zones() raises -> ZoneTable:
    """New York, London and Berlin under today's rules."""
    var t = ZoneTable()
    t.add(posix_zone("America/New_York", "EST5EDT,M3.2.0,M11.1.0"))
    t.add(posix_zone("Europe/London", "GMT0BST,M3.5.0/1,M10.5.0"))
    t.add(posix_zone("Europe/Berlin", "CET-1CEST,M3.5.0,M10.5.0/3"))
    return t^


def crlf(text: String) -> String:
    """`text` with each LF written as CRLF, as iCalendar requires."""
    return text.replace("\n", "\r\n")


def report_text(rep: IcsReport) -> String:
    """Each refusal, then each dropped item, one per line."""
    var out = String()
    for r in rep.refused:
        out += String(r) + "\n"
    for d in rep.dropped:
        out += String(d) + "\n"
    return out^


def events_text(got: IcsImport) raises -> String:
    """Each event as the API's JSON, then each of its edits indented, one
    per line."""
    var out = String()
    for ref e in got.events:
        out += encode_json(e.event) + "\n"
        for ref o in e.overrides:
            out += "  " + encode_json(o) + "\n"
    return out^
