"""A validation refusal: a stable code, the JSON path of the field it is about,
and a sentence for a person. `error_response` writes it in the API's error
envelope (`komira_calendar_proto.calendar.ErrorResponse`)."""

from komira_calendar_proto.calendar import ApiError, ErrorResponse


struct RefusalCode:
    """The refusal codes. Each is its own name as a string, so a client can
    branch on it; a code is never renamed or reused."""

    # Text fields.
    comptime NAME_REQUIRED = "NAME_REQUIRED"
    comptime TEXT_TOO_LONG = "TEXT_TOO_LONG"
    comptime TEXT_CONTROL_CHARACTER = "TEXT_CONTROL_CHARACTER"
    comptime COLOR_MALFORMED = "COLOR_MALFORMED"
    # Time zones.
    comptime TIME_ZONE_REQUIRED = "TIME_ZONE_REQUIRED"
    comptime TIME_ZONE_MALFORMED = "TIME_ZONE_MALFORMED"
    # Event timing.
    comptime STATUS_UNKNOWN = "STATUS_UNKNOWN"
    comptime START_DATE_REQUIRED = "START_DATE_REQUIRED"
    comptime START_REQUIRED = "START_REQUIRED"
    comptime START_MALFORMED = "START_MALFORMED"
    comptime DAYS_OUT_OF_RANGE = "DAYS_OUT_OF_RANGE"
    comptime DURATION_ZERO = "DURATION_ZERO"
    comptime DURATION_TOO_LONG = "DURATION_TOO_LONG"
    comptime ALL_DAY_WITH_ZONE = "ALL_DAY_WITH_ZONE"
    comptime ALL_DAY_WITH_TIME = "ALL_DAY_WITH_TIME"
    comptime TIMED_WITH_DATE = "TIMED_WITH_DATE"
    # Recurrence.
    comptime FREQUENCY_REQUIRED = "FREQUENCY_REQUIRED"
    comptime FREQUENCY_UNKNOWN = "FREQUENCY_UNKNOWN"
    comptime INTERVAL_OUT_OF_RANGE = "INTERVAL_OUT_OF_RANGE"
    comptime WEEKDAYS_NOT_WEEKLY = "WEEKDAYS_NOT_WEEKLY"
    comptime WEEKDAY_UNKNOWN = "WEEKDAY_UNKNOWN"
    comptime WEEKDAY_DUPLICATE = "WEEKDAY_DUPLICATE"
    comptime MONTHLY_RULE_REQUIRED = "MONTHLY_RULE_REQUIRED"
    comptime MONTHLY_RULE_AMBIGUOUS = "MONTHLY_RULE_AMBIGUOUS"
    comptime MONTHLY_FIELDS_NOT_MONTHLY = "MONTHLY_FIELDS_NOT_MONTHLY"
    comptime MONTH_DAY_OUT_OF_RANGE = "MONTH_DAY_OUT_OF_RANGE"
    comptime ORDINAL_OUT_OF_RANGE = "ORDINAL_OUT_OF_RANGE"
    comptime ORDINAL_WEEKDAY_REQUIRED = "ORDINAL_WEEKDAY_REQUIRED"
    comptime ORDINAL_REQUIRED = "ORDINAL_REQUIRED"
    comptime COUNT_WITH_UNTIL = "COUNT_WITH_UNTIL"
    comptime COUNT_OUT_OF_RANGE = "COUNT_OUT_OF_RANGE"
    comptime UNTIL_MALFORMED = "UNTIL_MALFORMED"
    comptime UNTIL_BEFORE_START = "UNTIL_BEFORE_START"
    # Excluded occurrences and reminders.
    comptime EXDATES_WITHOUT_RECURRENCE = "EXDATES_WITHOUT_RECURRENCE"
    comptime TOO_MANY_EXDATES = "TOO_MANY_EXDATES"
    comptime EXDATE_MALFORMED = "EXDATE_MALFORMED"
    comptime EXDATE_DUPLICATE = "EXDATE_DUPLICATE"
    comptime TOO_MANY_REMINDERS = "TOO_MANY_REMINDERS"
    comptime REMINDER_OUT_OF_RANGE = "REMINDER_OUT_OF_RANGE"
    comptime REMINDER_DUPLICATE = "REMINDER_DUPLICATE"
    # One-occurrence edits.
    comptime OVERRIDE_WITHOUT_RECURRENCE = "OVERRIDE_WITHOUT_RECURRENCE"
    comptime ORIGINAL_START_MALFORMED = "ORIGINAL_START_MALFORMED"
    comptime OVERRIDE_EMPTY = "OVERRIDE_EMPTY"
    comptime OVERRIDE_CANCELLED_WITH_CHANGES = "OVERRIDE_CANCELLED_WITH_CHANGES"


@fieldwise_init
struct Refusal(Copyable, Movable, Writable):
    """Why a value was refused: `code` (a `RefusalCode`), `field` (the JSON
    path, for example `recurrence.until` or `reminders[5].minutesBefore`) and `message`."""

    var code: String
    var field: String
    var message: String

    def write_to[W: Writer](self, mut writer: W):
        writer.write(self.code, " at ", self.field, ": ", self.message)


def error_response(refusal: Refusal) -> ErrorResponse:
    """The API's error body for `refusal`:
    `{"error":{"code":...,"message":...,"field":...}}`."""
    return ErrorResponse(
        Optional[ApiError](ApiError(refusal.code.copy(), refusal.message.copy(), refusal.field.copy()))
    )
