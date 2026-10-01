# =============================================================================
# komira_aws_core/aws_codec.mojo -- the awsJson scalar codec and error shape
# =============================================================================
#
# The awsJson 1.0 / 1.1 protocols put each scalar on the wire in one fixed
# form (https://smithy.io/2.0/aws/protocols/aws-json-1_0-protocol.html):
#
#   string, enum      a JSON string
#   boolean           true / false
#   integer, long     a JSON number, no fraction
#   float, double     a JSON number; NaN, Infinity and -Infinity as the JSON
#                     STRINGS "NaN", "Infinity", "-Infinity"
#   blob              a JSON string, standard base64, padded
#   timestamp         by the member's timestampFormat (default epoch-seconds):
#                       AWS_TS_UNIX     a JSON number, seconds, ms precision
#                       AWS_TS_ISO8601  "2026-09-15T12:00:00Z" (".123" ms)
#                       AWS_TS_RFC822   "Tue, 15 Sep 2026 12:00:00 GMT"
#
# A timestamp in a generated shape is a Float64 of epoch seconds whatever its
# wire format, so one instant has one representation.
#
# This module produces and consumes `AwsJsonToken`s -- one JSON leaf: its kind
# (number, string, bool) and its text, unescaped. The JSON document type is
# komira_json's `JsonValue`; each `aws_json_*` name the generator imports is
# a one-line wrap of the token function here (`JsonValue.from_number(t.text)`
# / `.from_string` / `.from_bool`) and lands with that dependency. Every rule
# of the encoding is here and tested here.
#
# Errors (https://smithy.io/2.0/aws/protocols/aws-json-1_0-protocol.html
# #operation-error-serialization): the code is the body's `__type` (else
# `code`), cut at the first ':' and after the last '#'. The message is the
# body's `message` (else `Message`, `errorMessage`). Neither function ever
# returns other text from the body: a response body can hold a secret.
# =============================================================================

from komira_crypto import base64_decode, base64_encode

from ._flat_json import parse_top_level_strings
from ._text import sub


comptime AWS_TS_UNIX = 0
comptime AWS_TS_ISO8601 = 1
comptime AWS_TS_RFC822 = 2

comptime AWS_JSON_NUMBER = 0
comptime AWS_JSON_STRING = 1
comptime AWS_JSON_BOOL = 2

# The longest error code / message an error carries. A longer one is cut.
comptime AWS_ERROR_CODE_MAX_BYTES = 128
comptime AWS_ERROR_MESSAGE_MAX_BYTES = 512

# Epoch seconds of 10000-01-01T00:00:00Z: timestamps are 1970..9999.
comptime _MAX_EPOCH = 253402300800


@fieldwise_init
struct AwsJsonToken(Copyable, Movable):
    """One JSON leaf: `kind` (AWS_JSON_NUMBER / _STRING / _BOOL) and its
    `text` -- the number as written, the string unescaped, or "true" /
    "false"."""

    var kind: Int
    var text: String

    def is_string(self) -> Bool:
        return self.kind == AWS_JSON_STRING

    def is_number(self) -> Bool:
        return self.kind == AWS_JSON_NUMBER


# -----------------------------------------------------------------------------
# Encoding
# -----------------------------------------------------------------------------


def aws_token_string(s: String) -> AwsJsonToken:
    return AwsJsonToken(AWS_JSON_STRING, s)


def aws_token_bool(v: Bool) -> AwsJsonToken:
    return AwsJsonToken(AWS_JSON_BOOL, String("true") if v else String("false"))


def aws_token_i32(v: Int32) -> AwsJsonToken:
    return AwsJsonToken(AWS_JSON_NUMBER, String(v))


def aws_token_i64(v: Int64) -> AwsJsonToken:
    return AwsJsonToken(AWS_JSON_NUMBER, String(v))


def aws_token_f64(v: Float64) -> AwsJsonToken:
    """A double: a number, or the string "NaN" / "Infinity" / "-Infinity"."""
    if v != v:
        return AwsJsonToken(AWS_JSON_STRING, String("NaN"))
    if v == _inf():
        return AwsJsonToken(AWS_JSON_STRING, String("Infinity"))
    if v == -_inf():
        return AwsJsonToken(AWS_JSON_STRING, String("-Infinity"))
    return AwsJsonToken(AWS_JSON_NUMBER, String(v))


def aws_token_f32(v: Float32) -> AwsJsonToken:
    """A float, written at Float32 precision (so 0.1 is "0.1", not the
    Float64 widening of it)."""
    if v != v:
        return AwsJsonToken(AWS_JSON_STRING, String("NaN"))
    var z = Float32(0.0)
    var inf = Float32(1.0) / z
    if v == inf:
        return AwsJsonToken(AWS_JSON_STRING, String("Infinity"))
    if v == -inf:
        return AwsJsonToken(AWS_JSON_STRING, String("-Infinity"))
    return AwsJsonToken(AWS_JSON_NUMBER, String(v))


def aws_token_blob(data: Span[UInt8, _]) -> AwsJsonToken:
    """A blob: standard base64, padded."""
    return AwsJsonToken(AWS_JSON_STRING, base64_encode(data))


def aws_token_ts(epoch_seconds: Float64, fmt: Int) raises -> AwsJsonToken:
    """A timestamp in `fmt` (AWS_TS_UNIX / _ISO8601 / _RFC822)."""
    var ms = _epoch_ms(epoch_seconds)
    if fmt == AWS_TS_UNIX:
        var out = String(ms // 1000)
        var frac = ms % 1000
        if frac != 0:
            out += "." + _frac_ms(frac)
        return AwsJsonToken(AWS_JSON_NUMBER, out^)
    if fmt == AWS_TS_ISO8601:
        return AwsJsonToken(AWS_JSON_STRING, _iso8601(ms))
    if fmt == AWS_TS_RFC822:
        return AwsJsonToken(AWS_JSON_STRING, _rfc822(ms // 1000))
    raise Error("unknown AWS timestamp format " + String(fmt))


# -----------------------------------------------------------------------------
# Decoding
# -----------------------------------------------------------------------------


def aws_f64_from_token(tok: AwsJsonToken) raises -> Float64:
    """A double from a number or from "NaN" / "Infinity" / "-Infinity"."""
    if tok.kind == AWS_JSON_NUMBER:
        return _number(tok.text)
    if tok.kind == AWS_JSON_STRING:
        if tok.text == "NaN":
            return _nan()
        if tok.text == "Infinity":
            return _inf()
        if tok.text == "-Infinity":
            return -_inf()
    raise Error("an awsJson double is neither a number nor NaN / Infinity")


def aws_blob_from_text(text: String) raises -> List[UInt8]:
    """A blob from its base64 text."""
    try:
        return base64_decode(text)
    except:
        raise Error("an awsJson blob is not valid base64")


def aws_ts_from_token(tok: AwsJsonToken) raises -> Float64:
    """Epoch seconds from a timestamp in any of the three formats: a number,
    an ISO 8601 / RFC 3339 date-time, an RFC 822 / HTTP date, or a decimal
    number written as a string."""
    if tok.kind == AWS_JSON_NUMBER:
        return _number(tok.text)
    if tok.kind != AWS_JSON_STRING:
        raise Error("an awsJson timestamp is neither a number nor a string")
    var b = tok.text.as_bytes()
    if len(b) >= 20 and b[4] == UInt8(0x2D) and b[7] == UInt8(0x2D):
        return _parse_iso8601(tok.text)
    if len(b) >= 29 and b[3] == UInt8(0x2C):
        return _parse_rfc822(tok.text)
    return _number(tok.text)


# -----------------------------------------------------------------------------
# Errors
# -----------------------------------------------------------------------------


def aws_is_error_status(status: Int) -> Bool:
    """True for anything but 2xx."""
    return status < 200 or status > 299


def aws_error_code(raw: String) -> String:
    """The short error code from a `__type` / x-amzn-ErrorType value: cut at
    the first ':', then after the last '#'; only [A-Za-z0-9_.-] kept, at
    most AWS_ERROR_CODE_MAX_BYTES."""
    var s = raw
    var colon = s.find(":")
    if colon >= 0:
        s = sub(s, 0, colon)
    var hash = s.rfind("#")
    if hash >= 0:
        s = sub(s, hash + 1, s.byte_length())
    var out = String("")
    var b = s.as_bytes()
    for i in range(len(b)):
        if out.byte_length() >= AWS_ERROR_CODE_MAX_BYTES:
            break
        var c = b[i]
        var ok = (
            (c >= UInt8(0x41) and c <= UInt8(0x5A))
            or (c >= UInt8(0x61) and c <= UInt8(0x7A))
            or (c >= UInt8(0x30) and c <= UInt8(0x39))
            or c == UInt8(0x5F)
            or c == UInt8(0x2E)
            or c == UInt8(0x2D)
        )
        if ok:
            out += chr(Int(c))
    return out^


def aws_error_code_from_body(body: String) -> String:
    """The error code of an awsJson error body, "" when the body is not a
    JSON object or carries none. Returns nothing else from the body."""
    try:
        var j = parse_top_level_strings(body)
        if j.has("__type"):
            return aws_error_code(j.get("__type"))
        if j.has("code"):
            return aws_error_code(j.get("code"))
    except:
        pass
    return String("")


def aws_error_message_from_body(body: String) -> String:
    """The error message of an awsJson error body (`message`, `Message` or
    `errorMessage`), control bytes as spaces, cut at
    AWS_ERROR_MESSAGE_MAX_BYTES on a character boundary. "" when absent or
    when the body is not a JSON object. Returns nothing else from the
    body."""
    try:
        var j = parse_top_level_strings(body)
        var keys: List[String] = ["message", "Message", "errorMessage"]
        for k in range(len(keys)):
            if j.has(keys[k]):
                return _clean_message(j.get(keys[k]))
    except:
        pass
    return String("")


def _clean_message(m: String) -> String:
    var b = m.as_bytes()
    var cut = len(b)
    if cut > AWS_ERROR_MESSAGE_MAX_BYTES:
        cut = AWS_ERROR_MESSAGE_MAX_BYTES
        # Back off to the start of a UTF-8 sequence.
        while cut > 0 and (b[cut] & UInt8(0xC0)) == UInt8(0x80):
            cut -= 1
    var out = List[UInt8]()
    for i in range(cut):
        var c = b[i]
        if c < UInt8(0x20) or c == UInt8(0x7F):
            out.append(UInt8(0x20))
        else:
            out.append(c)
    return String(unsafe_from_utf8=Span(out))


# -----------------------------------------------------------------------------
# Numbers and calendar
# -----------------------------------------------------------------------------


def _nan() -> Float64:
    var z = Float64(0.0)
    return z / z


def _inf() -> Float64:
    var z = Float64(0.0)
    return Float64(1.0) / z


def _number(text: String) raises -> Float64:
    var b = text.as_bytes()
    if len(b) == 0:
        raise Error("an awsJson number is empty")
    for i in range(len(b)):
        var c = b[i]
        var ok = (
            (c >= UInt8(0x30) and c <= UInt8(0x39))
            or c == UInt8(0x2D)
            or c == UInt8(0x2B)
            or c == UInt8(0x2E)
            or c == UInt8(0x65)
            or c == UInt8(0x45)
        )
        if not ok:
            raise Error("an awsJson number has a byte outside [0-9+-.eE]")
    return atof(text)


def _epoch_ms(epoch_seconds: Float64) raises -> Int:
    if epoch_seconds != epoch_seconds:
        raise Error("an AWS timestamp is NaN")
    if epoch_seconds < 0.0 or epoch_seconds >= Float64(_MAX_EPOCH):
        raise Error("an AWS timestamp is outside 1970..9999")
    var ms = Int(epoch_seconds * 1000.0 + 0.5)
    if ms >= _MAX_EPOCH * 1000:
        ms = _MAX_EPOCH * 1000 - 1
    return ms


def _frac_ms(frac: Int) -> String:
    """`frac` (1..999) milliseconds as ".ddd" digits, trailing zeros cut."""
    var s = String(frac + 1000)  # "1ddd"
    var d = sub(s, 1, 4)
    while d.endswith("0"):
        d = sub(d, 0, d.byte_length() - 1)
    return d^


def _pad(mut out: String, v: Int, width: Int):
    var s = String(v)
    for _ in range(width - s.byte_length()):
        out += "0"
    out += s


def _civil(days: Int) -> Tuple[Int, Int, Int]:
    """(year, month, day) of a day count since 1970-01-01."""
    var z = days + 719468
    var era = z // 146097
    var doe = z - era * 146097
    var yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    var y = yoe + era * 400
    var doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    var mp = (5 * doy + 2) // 153
    var d = doy - (153 * mp + 2) // 5 + 1
    var m = mp + 3 if mp < 10 else mp - 9
    if m <= 2:
        y += 1
    return (y, m, d)


def _days_from_civil(y0: Int, m: Int, d: Int) -> Int:
    var y = y0 - 1 if m <= 2 else y0
    var era = y // 400
    var yoe = y - era * 400
    var mp = m - 3 if m > 2 else m + 9
    var doy = (153 * mp + 2) // 5 + d - 1
    var doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468


def _iso8601(ms: Int) -> String:
    var secs = ms // 1000
    var ymd = _civil(secs // 86400)
    var t = secs % 86400
    var out = String("")
    _pad(out, ymd[0], 4)
    out += "-"
    _pad(out, ymd[1], 2)
    out += "-"
    _pad(out, ymd[2], 2)
    out += "T"
    _pad(out, t // 3600, 2)
    out += ":"
    _pad(out, (t % 3600) // 60, 2)
    out += ":"
    _pad(out, t % 60, 2)
    if ms % 1000 != 0:
        out += "." + _frac_ms(ms % 1000)
    out += "Z"
    return out^


comptime _DAYS = "SunMonTueWedThuFriSat"
comptime _MONTHS = "JanFebMarAprMayJunJulAugSepOctNovDec"


def _rfc822(secs: Int) -> String:
    var days = secs // 86400
    var ymd = _civil(days)
    var t = secs % 86400
    var wd = (days + 4) % 7  # 1970-01-01 was a Thursday
    var out = sub(String(_DAYS), wd * 3, wd * 3 + 3) + ", "
    _pad(out, ymd[2], 2)
    out += " " + sub(String(_MONTHS), (ymd[1] - 1) * 3, ymd[1] * 3) + " "
    _pad(out, ymd[0], 4)
    out += " "
    _pad(out, t // 3600, 2)
    out += ":"
    _pad(out, (t % 3600) // 60, 2)
    out += ":"
    _pad(out, t % 60, 2)
    out += " GMT"
    return out^


def _digits(b: Span[UInt8, _], at: Int, n: Int) raises -> Int:
    if at + n > len(b):
        raise Error("an AWS timestamp is truncated")
    var v = 0
    for i in range(at, at + n):
        if b[i] < UInt8(0x30) or b[i] > UInt8(0x39):
            raise Error("an AWS timestamp has a non-digit where a digit belongs")
        v = v * 10 + Int(b[i] - UInt8(0x30))
    return v


def _expect(b: Span[UInt8, _], at: Int, c: UInt8) raises:
    if at >= len(b) or b[at] != c:
        raise Error("an AWS timestamp is malformed")


def _from_fields(
    y: Int, mo: Int, d: Int, h: Int, mi: Int, s: Int
) raises -> Int:
    if mo < 1 or mo > 12 or d < 1 or d > 31 or h > 23 or mi > 59 or s > 60:
        raise Error("an AWS timestamp has a field out of range")
    var days = _days_from_civil(y, mo, d)
    var back = _civil(days)
    if back[1] != mo or back[2] != d:
        raise Error("an AWS timestamp names a day that does not exist")
    return days * 86400 + h * 3600 + mi * 60 + s


def _parse_iso8601(text: String) raises -> Float64:
    """YYYY-MM-DDTHH:MM:SS[.f+](Z|+HH:MM|-HH:MM)."""
    var b = text.as_bytes()
    var y = _digits(b, 0, 4)
    _expect(b, 4, UInt8(0x2D))
    var mo = _digits(b, 5, 2)
    _expect(b, 7, UInt8(0x2D))
    var d = _digits(b, 8, 2)
    if b[10] != UInt8(0x54) and b[10] != UInt8(0x74):
        raise Error("an AWS timestamp is malformed")
    var h = _digits(b, 11, 2)
    _expect(b, 13, UInt8(0x3A))
    var mi = _digits(b, 14, 2)
    _expect(b, 16, UInt8(0x3A))
    var s = _digits(b, 17, 2)
    var i = 19
    var frac = Float64(0.0)
    if i < len(b) and b[i] == UInt8(0x2E):
        i += 1
        var scale = Float64(0.1)
        var start = i
        while i < len(b) and b[i] >= UInt8(0x30) and b[i] <= UInt8(0x39):
            frac += Float64(Int(b[i] - UInt8(0x30))) * scale
            scale /= 10.0
            i += 1
        if i == start:
            raise Error("an AWS timestamp has an empty fraction")
    var offset = 0
    if i < len(b) and (b[i] == UInt8(0x5A) or b[i] == UInt8(0x7A)):
        i += 1
    elif i < len(b) and (b[i] == UInt8(0x2B) or b[i] == UInt8(0x2D)):
        var sign = 1 if b[i] == UInt8(0x2B) else -1
        var oh = _digits(b, i + 1, 2)
        _expect(b, i + 3, UInt8(0x3A))
        var om = _digits(b, i + 4, 2)
        offset = sign * (oh * 3600 + om * 60)
        i += 6
    else:
        raise Error("an AWS timestamp has no time zone")
    if i != len(b):
        raise Error("an AWS timestamp has text after it")
    var secs = _from_fields(y, mo, d, h, mi, s) - offset
    return Float64(secs) + frac


def _parse_rfc822(text: String) raises -> Float64:
    """`Www, DD Mmm YYYY HH:MM:SS GMT` (IMF-fixdate)."""
    var b = text.as_bytes()
    if len(b) != 29:
        raise Error("an AWS timestamp is malformed")
    var d = _digits(b, 5, 2)
    var mon = sub(text, 8, 11)
    var mo = 0
    var months = String(_MONTHS)
    for k in range(12):
        if sub(months, k * 3, k * 3 + 3) == mon:
            mo = k + 1
    if mo == 0:
        raise Error("an AWS timestamp has an unknown month")
    var y = _digits(b, 12, 4)
    var h = _digits(b, 17, 2)
    _expect(b, 19, UInt8(0x3A))
    var mi = _digits(b, 20, 2)
    _expect(b, 22, UInt8(0x3A))
    var s = _digits(b, 23, 2)
    if sub(text, 25, 29) != " GMT":
        raise Error("an AWS timestamp is not in GMT")
    return Float64(_from_fields(y, mo, d, h, mi, s))
