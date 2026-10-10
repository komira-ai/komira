# =============================================================================
# komira_mail_message/date.mojo -- the `Date` and `Message-ID` values.
# =============================================================================
#
# `format_date` writes RFC 5322 section 3.3 `date-time`,
# `Mon, 21 Sep 2026 14:13:20 +0000`, from seconds since 1970-01-01T00:00:00Z
# and the zone's offset from UTC in minutes; the day, date and time are the
# local ones in that zone. The calendar is the proleptic Gregorian one
# (days-from-civil inverted, as in H. Hinnant's "chrono-compatible low-level
# date algorithms").
#
# `format_message_id` writes RFC 5322 section 3.6.4 `msg-id`,
# `<id-left@id-right>`, both parts `dot-atom-text`. The package keeps no
# clock and draws no random numbers: the caller supplies the time and a
# unique left part.
# =============================================================================

from .chars import AT, COLON, DOT, GT, LT, SP, append_bytes, append_decimal, is_atext
from .errors import INVALID_VALUE, message_error

comptime _DAYS: StaticString = "ThuFriSatSunMonTueWed"
"""Day names from 1970-01-01, a Thursday."""
comptime _MONTHS: StaticString = "JanFebMarAprMayJunJulAugSepOctNovDec"

comptime MAX_UNIX_SECONDS = 253402300799
"""9999-12-31T23:59:59Z: RFC 5322 writes four-digit years."""


def _append_name(mut out: List[UInt8], names: StaticString, index: Int):
    var b = names.as_bytes()
    for k in range(3):
        out.append(b[index * 3 + k])


def format_date(unix_seconds: Int, utc_offset_minutes: Int = 0) raises -> String:
    """`date-time` for the instant `unix_seconds` (at or after 1970) in the
    zone `utc_offset_minutes` east of UTC (-1439..1439)."""
    if unix_seconds < 0 or unix_seconds > MAX_UNIX_SECONDS:
        raise message_error(
            INVALID_VALUE, "format_date", "a time before 1970 or after 9999"
        )
    if utc_offset_minutes < -1439 or utc_offset_minutes > 1439:
        raise message_error(
            INVALID_VALUE, "format_date", "a zone offset outside -2359..+2359"
        )
    var local = unix_seconds + utc_offset_minutes * 60
    if local < 0:
        raise message_error(
            INVALID_VALUE, "format_date", "a local time before 1970"
        )
    var days = local // 86400
    var seconds = local % 86400
    # civil_from_days, for days >= 0.
    var z = days + 719468
    var era = z // 146097
    var doe = z - era * 146097
    var yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    var doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    var mp = (5 * doy + 2) // 153
    var day = doy - (153 * mp + 2) // 5 + 1
    var month = mp + 3 if mp < 10 else mp - 9
    var year = yoe + era * 400 + (1 if month <= 2 else 0)
    var out = List[UInt8](capacity=31)
    _append_name(out, _DAYS, days % 7)
    out.append(44)  # ,
    out.append(SP)
    append_decimal(out, day, 2)
    out.append(SP)
    _append_name(out, _MONTHS, month - 1)
    out.append(SP)
    append_decimal(out, year, 4)
    out.append(SP)
    append_decimal(out, seconds // 3600, 2)
    out.append(COLON)
    append_decimal(out, (seconds // 60) % 60, 2)
    out.append(COLON)
    append_decimal(out, seconds % 60, 2)
    out.append(SP)
    var offset = utc_offset_minutes
    if offset < 0:
        out.append(45)  # -
        offset = -offset
    else:
        out.append(43)  # +
    append_decimal(out, offset // 60, 2)
    append_decimal(out, offset % 60, 2)
    return String(StringSlice(from_utf8=Span(out)))


def is_dot_atom_text(s: Span[UInt8, _]) -> Bool:
    """RFC 5322 `dot-atom-text`: atoms of `atext` joined by single dots."""
    var n = len(s)
    if n == 0:
        return False
    var run = 0
    for i in range(n):
        if s[i] == DOT:
            if run == 0:
                return False
            run = 0
        elif is_atext(s[i]):
            run += 1
        else:
            return False
    return run > 0


def format_message_id(id_left: String, id_right: String) raises -> String:
    """`<id_left@id_right>`. Both parts must be `dot-atom-text`; the result
    is at most 250 octets. `id_left` must be unique (a random value, or a
    time and a counter); `id_right` is usually the sender's domain."""
    if not is_dot_atom_text(id_left.as_bytes()) or not is_dot_atom_text(
        id_right.as_bytes()
    ):
        raise message_error(
            INVALID_VALUE,
            "format_message_id",
            "a message id part that is not dot-atom-text",
        )
    if id_left.byte_length() + id_right.byte_length() + 3 > 250:
        raise message_error(
            INVALID_VALUE, "format_message_id", "a message id over 250 octets"
        )
    return String("<") + id_left + String("@") + id_right + String(">")


def is_msg_id(s: Span[UInt8, _]) -> Bool:
    """True when `s` is exactly `<dot-atom-text@dot-atom-text>`."""
    var n = len(s)
    if n < 5 or s[0] != LT or s[n - 1] != GT:
        return False
    var at = -1
    for i in range(1, n - 1):
        if s[i] == AT:
            if at >= 0:
                return False
            at = i
    if at < 0:
        return False
    var left = List[UInt8]()
    var right = List[UInt8]()
    for i in range(1, at):
        left.append(s[i])
    for i in range(at + 1, n - 1):
        right.append(s[i])
    return is_dot_atom_text(Span(left)) and is_dot_atom_text(Span(right))
