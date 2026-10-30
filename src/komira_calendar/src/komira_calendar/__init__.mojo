"""A simple calendar's model and its validation: what a client may write to a
calendar, an event and a one-occurrence edit, checked field by field, each
refusal a stable code, the JSON path of the field and a sentence.

The messages are `komira_calendar_proto`'s (`komira.calendar.v1`): a
calendar; an event that is all-day (a start date and a day count) or timed (a
local start, an IANA time zone and a duration in seconds); a structured
recurrence rule (DAILY, WEEKLY with weekdays, MONTHLY by day of the month or
by ordinal weekday, YEARLY; an interval; an end by count or by date); removed
occurrences; up to five reminders. It is not iCalendar: no RRULE text, no
attendees.

  local_time.mojo  the local date and local date-time text forms; the shape
                   of an IANA time zone name
  recurrence.mojo  check_recurrence
  expand.mojo      expand (the occurrences in a window) and series_span (from
                   the first start to the last end), in local time
  series.mojo      the rule's periods and the days each picks
  validate.mojo    check_calendar, check_event, check_override
  refusal.mojo     Refusal, RefusalCode, error_response (the API error body)
  limits.mojo      the bounds the checks enforce

Not here: whether a named zone exists, local time to UTC, storage and HTTP.
"""

from .expand import MAX_WINDOW_OCCURRENCES, OPEN_END, Occurrence, SeriesSpan, expand, series_span
from .limits import (
    MAX_COUNT,
    MAX_DESCRIPTION_BYTES,
    MAX_DURATION_SECONDS,
    MAX_EVENT_DAYS,
    MAX_EXDATES,
    MAX_INTERVAL,
    MAX_LOCATION_BYTES,
    MAX_NAME_BYTES,
    MAX_REMINDER_MINUTES,
    MAX_REMINDERS,
    MAX_TITLE_BYTES,
    MAX_UID_BYTES,
)
from .local_time import (
    LocalDateTime,
    MAX_TIME_ZONE_BYTES,
    is_time_zone_name,
    parse_local_date,
    parse_local_datetime,
)
from .recurrence import check_recurrence
from .refusal import Refusal, RefusalCode, error_response
from .validate import check_calendar, check_event, check_override
