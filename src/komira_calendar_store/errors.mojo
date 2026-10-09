# =============================================================================
# komira_calendar_store/errors.mojo -- the texts the store raises.
# =============================================================================
#
# Every refusal of the store is an `Error` whose text starts with one of the
# constants below, so a caller maps it to an HTTP status by prefix:
#
#   ERR_NOT_FOUND         404: no such calendar, event or override
#   ERR_VERSION_CONFLICT  412: the If-Match version is not the stored one
#   ERR_UID_TAKEN         409: the uid is used by a live event of the calendar
#   ERR_BUSY              409 (retry): another write to the calendar came
#                         between this write's read and its write
#   ERR_INVALID           400: `calendar: invalid <code> at <field>: <message>`,
#                         a komira_calendar `Refusal` or one of the codes below
# =============================================================================

from komira_calendar import Refusal

comptime ERR_NOT_FOUND: StaticString = "calendar: not found"
comptime ERR_VERSION_CONFLICT: StaticString = "calendar: version conflict"
comptime ERR_UID_TAKEN: StaticString = "calendar: uid is already used in this calendar"
comptime ERR_BUSY: StaticString = "calendar: another write to this calendar came first; retry"
comptime ERR_INVALID: StaticString = "calendar: invalid "

# The store's own refusal codes, beside komira_calendar's RefusalCode.
comptime TIME_ZONE_UNKNOWN: StaticString = "TIME_ZONE_UNKNOWN"
comptime NO_SUCH_OCCURRENCE: StaticString = "NO_SUCH_OCCURRENCE"
comptime UID_CHANGED: StaticString = "UID_CHANGED"
comptime WINDOW_EMPTY: StaticString = "WINDOW_EMPTY"


def invalid(refusal: Refusal) -> Error:
    """`calendar: invalid <code> at <field>: <message>`."""
    return Error(String(ERR_INVALID) + String(refusal))


def invalid_field(code: StaticString, field: StaticString, message: String) -> Error:
    return invalid(Refusal(String(code), String(field), message))


def not_found() -> Error:
    return Error(String(ERR_NOT_FOUND))


def version_conflict() -> Error:
    return Error(String(ERR_VERSION_CONFLICT))


def busy() -> Error:
    return Error(String(ERR_BUSY))
