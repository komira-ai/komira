"""Validation of the fields a client writes: a calendar, an event and a
one-occurrence edit. Each check returns the first rule the value breaks, as a
`Refusal`, or None. Fields the service writes (`id`, `owner`, `calendar_id`,
`version`, `created_at`, `updated_at`) are not checked here.

Whether a named time zone exists is not checked here: only its shape is.
"""

from std.collections import Set

from komira_calendar_proto.calendar import (
    Calendar,
    Event,
    EventStatus,
    OccurrenceOverride,
)

from .limits import (
    MAX_DESCRIPTION_BYTES,
    MAX_DURATION_SECONDS,
    MAX_EVENT_DAYS,
    MAX_EXDATES,
    MAX_LOCATION_BYTES,
    MAX_NAME_BYTES,
    MAX_REMINDER_MINUTES,
    MAX_REMINDERS,
    MAX_TITLE_BYTES,
    MAX_UID_BYTES,
)
from .local_time import (
    LocalDateTime,
    is_time_zone_name,
    parse_local_date,
    parse_local_datetime,
)
from .recurrence import check_recurrence
from .refusal import Refusal, RefusalCode


def _refuse(code: String, field: String, message: String) -> Optional[Refusal]:
    return Optional[Refusal](Refusal(code, field, message))


def _check_text(value: String, field: String, max_bytes: Int, single_line: Bool) -> Optional[Refusal]:
    """Too long, or a control character: any below 0x20 or 0x7F except tab,
    and for multi-line text also except LF and CR."""
    var n = value.byte_length()
    if n > max_bytes:
        return _refuse(
            RefusalCode.TEXT_TOO_LONG,
            field,
            field + " is " + String(n) + " bytes; at most " + String(max_bytes) + " are allowed",
        )
    var b = value.as_bytes()
    for i in range(n):
        var c = b[i]
        if c >= 0x20 and c != 0x7F:
            continue
        if c == 0x09:
            continue
        if not single_line and (c == 0x0A or c == 0x0D):
            continue
        return _refuse(
            RefusalCode.TEXT_CONTROL_CHARACTER,
            field,
            field + " holds control character " + hex(Int(c)) + " at byte " + String(i),
        )
    return None


def _parse_start(text: String, all_day: Bool) raises -> LocalDateTime:
    """A start in its event's form: a local date for an all-day event (read
    as its midnight), a local date-time otherwise."""
    if all_day:
        return LocalDateTime(parse_local_date(text), 0)
    return parse_local_datetime(text)


def _form(all_day: Bool) -> String:
    return "a local date (YYYY-MM-DD)" if all_day else "a local date-time (YYYY-MM-DDTHH:MM:SS)"


def _is_hex(c: UInt8) -> Bool:
    return (c >= 0x30 and c <= 0x39) or (c >= 0x61 and c <= 0x66) or (c >= 0x41 and c <= 0x46)


def check_calendar(calendar: Calendar) -> Optional[Refusal]:
    """The first rule `calendar` breaks, or None: a one-line `name` of 1 to
    256 bytes, a `color` that is empty or `#rrggbb`, and a `time_zone` shaped
    like an IANA name."""
    if calendar.name.byte_length() == 0:
        return _refuse(RefusalCode.NAME_REQUIRED, "name", "a calendar needs a name")
    var r = _check_text(calendar.name, "name", MAX_NAME_BYTES, True)
    if r:
        return r^
    var color = calendar.color.as_bytes()
    if len(color) > 0:
        var ok = len(color) == 7 and color[0] == 0x23
        if ok:
            for i in range(1, 7):
                ok = ok and _is_hex(color[i])
        if not ok:
            return _refuse(
                RefusalCode.COLOR_MALFORMED,
                "color",
                "color is empty or #rrggbb (six hex digits)",
            )
    if calendar.time_zone.byte_length() == 0:
        return _refuse(
            RefusalCode.TIME_ZONE_REQUIRED,
            "timeZone",
            "a calendar needs a default time zone",
        )
    if not is_time_zone_name(calendar.time_zone):
        return _refuse(
            RefusalCode.TIME_ZONE_MALFORMED,
            "timeZone",
            "timeZone is not shaped like an IANA time zone name",
        )
    return None


def _check_event_text(event: Event) -> Optional[Refusal]:
    var r = _check_text(event.uid, "uid", MAX_UID_BYTES, True)
    if r:
        return r^
    r = _check_text(event.title, "title", MAX_TITLE_BYTES, True)
    if r:
        return r^
    r = _check_text(event.location, "location", MAX_LOCATION_BYTES, True)
    if r:
        return r^
    return _check_text(event.description, "description", MAX_DESCRIPTION_BYTES, False)


def _check_all_day(event: Event, mut start_day: Int) -> Optional[Refusal]:
    if event.time_zone.byte_length() > 0:
        return _refuse(
            RefusalCode.ALL_DAY_WITH_ZONE,
            "timeZone",
            "an all-day event has no time zone",
        )
    if event.start.byte_length() > 0:
        return _refuse(
            RefusalCode.ALL_DAY_WITH_TIME,
            "start",
            "an all-day event starts on startDate, not start",
        )
    if event.duration_seconds != 0:
        return _refuse(
            RefusalCode.ALL_DAY_WITH_TIME,
            "durationSeconds",
            "an all-day event lasts days, not durationSeconds",
        )
    if event.start_date.byte_length() == 0:
        return _refuse(
            RefusalCode.START_DATE_REQUIRED,
            "startDate",
            "an all-day event needs startDate",
        )
    try:
        start_day = parse_local_date(event.start_date)
    except e:
        return _refuse(
            RefusalCode.START_MALFORMED,
            "startDate",
            "startDate is not a local date (YYYY-MM-DD): " + String(e),
        )
    return _check_days(event.days)


def _check_timed(event: Event, mut start_day: Int) -> Optional[Refusal]:
    if event.start_date.byte_length() > 0:
        return _refuse(
            RefusalCode.TIMED_WITH_DATE,
            "startDate",
            "a timed event starts on start, not startDate",
        )
    if event.days != 0:
        return _refuse(
            RefusalCode.TIMED_WITH_DATE,
            "days",
            "a timed event lasts durationSeconds, not days",
        )
    if event.start.byte_length() == 0:
        return _refuse(RefusalCode.START_REQUIRED, "start", "a timed event needs start")
    try:
        start_day = parse_local_datetime(event.start).days
    except e:
        return _refuse(
            RefusalCode.START_MALFORMED,
            "start",
            "start is not a local date-time (YYYY-MM-DDTHH:MM:SS): " + String(e),
        )
    if event.time_zone.byte_length() == 0:
        return _refuse(
            RefusalCode.TIME_ZONE_REQUIRED,
            "timeZone",
            "a timed event needs timeZone; floating times are not supported",
        )
    if not is_time_zone_name(event.time_zone):
        return _refuse(
            RefusalCode.TIME_ZONE_MALFORMED,
            "timeZone",
            "timeZone is not shaped like an IANA time zone name",
        )
    return _check_duration(event.duration_seconds)


def _check_duration(seconds: UInt32) -> Optional[Refusal]:
    if seconds == 0:
        return _refuse(
            RefusalCode.DURATION_ZERO,
            "durationSeconds",
            "a timed event lasts at least one second",
        )
    if Int(seconds) > MAX_DURATION_SECONDS:
        return _refuse(
            RefusalCode.DURATION_TOO_LONG,
            "durationSeconds",
            "durationSeconds " + String(seconds) + " is above " + String(MAX_DURATION_SECONDS),
        )
    return None


def _check_days(days: UInt32) -> Optional[Refusal]:
    if days < 1 or Int(days) > MAX_EVENT_DAYS:
        return _refuse(
            RefusalCode.DAYS_OUT_OF_RANGE,
            "days",
            "days " + String(days) + " is outside 1.." + String(MAX_EVENT_DAYS),
        )
    return None


def _check_exdates(event: Event) -> Optional[Refusal]:
    var n = len(event.exdates)
    if n == 0:
        return None
    if not event.recurrence:
        return _refuse(
            RefusalCode.EXDATES_WITHOUT_RECURRENCE,
            "exdates",
            "only a recurring event has occurrences to exclude",
        )
    if n > MAX_EXDATES:
        return _refuse(
            RefusalCode.TOO_MANY_EXDATES,
            "exdates",
            "exdates holds " + String(n) + "; at most " + String(MAX_EXDATES) + " are allowed",
        )
    var all_day = event.show_without_time
    var seen = Set[String]()
    for i in range(n):
        var at = "exdates[" + String(i) + "]"
        try:
            _ = _parse_start(event.exdates[i], all_day)
        except e:
            return _refuse(
                RefusalCode.EXDATE_MALFORMED,
                at,
                at + " is not " + _form(all_day) + ": " + String(e),
            )
        if event.exdates[i] in seen:
            return _refuse(
                RefusalCode.EXDATE_DUPLICATE,
                at,
                event.exdates[i] + " is excluded twice",
            )
        seen.add(event.exdates[i])
    return None


def _check_reminders(event: Event) -> Optional[Refusal]:
    var n = len(event.reminders)
    if n > MAX_REMINDERS:
        return _refuse(
            RefusalCode.TOO_MANY_REMINDERS,
            "reminders",
            "reminders holds " + String(n) + "; at most " + String(MAX_REMINDERS) + " are allowed",
        )
    var seen = Set[Int]()
    for i in range(n):
        var minutes = Int(event.reminders[i].minutes_before)
        var at = "reminders[" + String(i) + "].minutesBefore"
        if minutes > MAX_REMINDER_MINUTES:
            return _refuse(
                RefusalCode.REMINDER_OUT_OF_RANGE,
                at,
                "minutesBefore " + String(minutes) + " is above " + String(MAX_REMINDER_MINUTES),
            )
        if minutes in seen:
            return _refuse(
                RefusalCode.REMINDER_DUPLICATE,
                at,
                "a reminder " + String(minutes) + " minutes before is set twice",
            )
        seen.add(minutes)
    return None


def check_event(event: Event) -> Optional[Refusal]:
    """The first rule `event` breaks, or None. In order: text lengths and
    control characters; the status; the timing of its form (all-day:
    `start_date` and `days`, no zone and no time; timed: `start`,
    `time_zone`, a positive `duration_seconds`, no date); the recurrence
    rule; the excluded occurrences (only on a recurring event, each in the
    event's form, no repeats); the reminders (at most 5, no repeats)."""
    var r = _check_event_text(event)
    if r:
        return r^
    var status = event.status.value
    if status != EventStatus.CONFIRMED and status != EventStatus.CANCELLED:
        return _refuse(
            RefusalCode.STATUS_UNKNOWN,
            "status",
            "status " + String(status) + " is not CONFIRMED or CANCELLED",
        )
    var start_day = 0
    if event.show_without_time:
        r = _check_all_day(event, start_day)
    else:
        r = _check_timed(event, start_day)
    if r:
        return r^
    if event.recurrence:
        r = check_recurrence(event.recurrence.value(), start_day)
        if r:
            return r^
    r = _check_exdates(event)
    if r:
        return r^
    return _check_reminders(event)


def check_override(edit: OccurrenceOverride, event: Event) -> Optional[Refusal]:
    """The first rule `edit` breaks against its `event`, which must already
    pass `check_event`, or None. The event must recur; `original_start` and
    a replacement `start` are in the event's form; a cancelled occurrence
    carries no replacement, and a kept one carries at least one; `days`
    applies to an all-day event and `duration_seconds` to a timed one."""
    if not event.recurrence:
        return _refuse(
            RefusalCode.OVERRIDE_WITHOUT_RECURRENCE,
            "eventId",
            "only a recurring event has occurrences to edit",
        )
    var all_day = event.show_without_time
    try:
        _ = _parse_start(edit.original_start, all_day)
    except e:
        return _refuse(
            RefusalCode.ORIGINAL_START_MALFORMED,
            "originalStart",
            "originalStart is not " + _form(all_day) + ": " + String(e),
        )
    var changes = (
        Bool(edit.title)
        or Bool(edit.start)
        or Bool(edit.duration_seconds)
        or Bool(edit.location)
        or Bool(edit.description)
        or Bool(edit.days)
    )
    if edit.cancelled and changes:
        return _refuse(
            RefusalCode.OVERRIDE_CANCELLED_WITH_CHANGES,
            "cancelled",
            "a cancelled occurrence carries no replacement fields",
        )
    if not edit.cancelled and not changes:
        return _refuse(
            RefusalCode.OVERRIDE_EMPTY,
            "cancelled",
            "an override cancels the occurrence or replaces at least one field",
        )
    var r: Optional[Refusal] = None
    if edit.title:
        r = _check_text(edit.title.value(), "title", MAX_TITLE_BYTES, True)
        if r:
            return r^
    if edit.location:
        r = _check_text(edit.location.value(), "location", MAX_LOCATION_BYTES, True)
        if r:
            return r^
    if edit.description:
        r = _check_text(edit.description.value(), "description", MAX_DESCRIPTION_BYTES, False)
        if r:
            return r^
    if edit.start:
        try:
            _ = _parse_start(edit.start.value(), all_day)
        except e:
            return _refuse(
                RefusalCode.START_MALFORMED,
                "start",
                "start is not " + _form(all_day) + ": " + String(e),
            )
    if edit.duration_seconds:
        if all_day:
            return _refuse(
                RefusalCode.ALL_DAY_WITH_TIME,
                "durationSeconds",
                "an all-day event lasts days, not durationSeconds",
            )
        r = _check_duration(edit.duration_seconds.value())
        if r:
            return r^
    if edit.days:
        if not all_day:
            return _refuse(
                RefusalCode.TIMED_WITH_DATE,
                "days",
                "a timed event lasts durationSeconds, not days",
            )
        r = _check_days(edit.days.value())
        if r:
            return r^
    return None
