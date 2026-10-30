"""The `.ics` edge of a simple calendar: an iCalendar (RFC 5545) file read
into `komira_calendar`'s model, with a report of everything the model does
not hold, and the model written back as iCalendar.

It reads and writes a declared subset: a VCALENDAR of VEVENTs with UID,
DTSTART, DTEND or DURATION, SUMMARY, DESCRIPTION, LOCATION, STATUS, an RRULE
within the model's structured rule, EXDATE, RECURRENCE-ID edits of single
occurrences, and VALARMs that are reminders before the start; VTIMEZONE is
read only to map its TZID to an IANA name. Time zone rules come from a
`ZoneSource` (`komira_datetime` zones). Nothing outside the subset is kept, and
nothing is dropped without a line in the report (past `MAX_DROPPED_KINDS`
kinds, one line counts the rest).

  tree.mojo        the content lines (komira_content_line) as components
  props.mojo       a VEVENT's properties: read, or reported
  read_event.mojo  one VEVENT to an event or a one-occurrence edit
  rrule.mojo       RRULE text to and from the structured rule
  read.mojo        read_ics: a file to events and a report
  write.mojo       write_ics, IcsExport: events to a file
  vtimezone.mojo   the VTIMEZONE an export writes for a zone
  values.mojo      DATE, DATE-TIME, DURATION and UTC offset values
  zones.mojo       ZoneSource, ZoneinfoDirectory, ZoneTable; TZID mapping
  report.mojo      IcsReport, IcsRefusal, IcsDropped, IcsCode
"""

from .read import IcsImport, read_ics
from .read_event import IcsEvent
from .report import MAX_DROPPED_KINDS, OVERFLOW_DETAIL, IcsCode, IcsDropped, IcsRefusal, IcsReport
from .tree import IcsLimits
from .write import PRODID, IcsExport, write_ics
from .zones import ZoneSource, ZoneTable, ZoneinfoDirectory
