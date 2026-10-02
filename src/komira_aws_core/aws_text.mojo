# =============================================================================
# komira_aws_core/aws_text.mojo -- the text form of a REST-bound scalar
# =============================================================================
#
# A member bound to a URI label (`httpLabel`), a query parameter
# (`httpQuery`, `httpQueryParams`) or a header (`httpHeader`,
# `httpPrefixHeaders`) travels as text. The Smithy HTTP binding traits fix
# that text (https://smithy.io/2.0/spec/http-bindings.html, the
# "serialization rules" of each trait):
#
#   boolean            "true" / "false", nothing else
#   byte .. long,      the decimal integer, an optional leading '-'
#   intEnum
#   float, double      the decimal number; NaN, Infinity and -Infinity as
#                      "NaN", "Infinity", "-Infinity"
#   blob               standard base64, padded (query and header only)
#   string with        standard base64 of its UTF-8 bytes (header only;
#   @mediaType         `@jsonValue` is the same rule)
#   timestamp          by the member's timestampFormat; when it has none,
#                      date-time in a label or a query value, http-date in
#                      a header:
#                        AWS_TS_ISO8601  date-time     2026-09-15T12:00:00Z
#                        AWS_TS_RFC822   http-date     Tue, 15 Sep 2026
#                                                      12:00:00 GMT
#                        AWS_TS_UNIX     epoch-seconds 1789473600
#
# Writers produce exactly that text. Readers are strict: each reads only the
# text its rule writes, so "1", "TRUE" and " true" are not booleans, "+1"
# and "1.0" are not integers, and a date-time is not read where an
# http-date belongs. The two timestamp reads that are more than the written
# form are fractional seconds -- "Sun, 06 Nov 1994 08:49:37.5 GMT" and any
# number of fraction digits in a date-time -- and a date-time with a UTC
# offset; the Smithy timestamp formats allow both
# (https://smithy.io/2.0/spec/protocol-traits.html#timestampformat-trait).
#
# http-date is the IMF-fixdate form of RFC 9110 section 5.6.7. The two
# obsolete forms that section also defines (rfc850-date, which needs a
# clock to place its two-digit year, and asctime-date) are refused, as
# aws-sdk-go-v2 (`smithy-go/time.ParseHTTPDate`) and smithy-rs
# (`DateTime::from_str(.., Format::HttpDate)`) refuse them: an AWS service
# writes IMF-fixdate.
#
# A timestamp is a Float64 of epoch seconds, as in aws_codec.mojo; writing
# one refuses NaN and anything outside 1970..9999.
# =============================================================================

from komira_encoding import base64_decode, base64_encode

from ._text import sub, utf8_text
from .aws_codec import (
    AWS_TS_ISO8601,
    AWS_TS_RFC822,
    AWS_TS_UNIX,
    _from_fields,
    _inf,
    _nan,
    _parse_iso8601,
    aws_token_f32,
    aws_token_f64,
    aws_token_ts,
)


comptime _DAYS = "SunMonTueWedThuFriSat"
comptime _MONTHS = "JanFebMarAprMayJunJulAugSepOctNovDec"


# -----------------------------------------------------------------------------
# Writers
# -----------------------------------------------------------------------------


def aws_text_bool(v: Bool) -> String:
    return String("true") if v else String("false")


def aws_text_int(v: Int64) -> String:
    """Any integer kind (byte, short, integer, long, intEnum), widened."""
    return String(v)


def aws_text_f64(v: Float64) -> String:
    """A double: the number, or "NaN" / "Infinity" / "-Infinity"."""
    return aws_token_f64(v).text


def aws_text_f32(v: Float32) -> String:
    """A float, at Float32 precision ("0.1", not its Float64 widening)."""
    return aws_token_f32(v).text


def aws_text_blob(data: Span[UInt8, _]) -> String:
    """A blob: standard base64, padded."""
    return base64_encode(data)


def aws_text_media(value: String) -> String:
    """A `@mediaType` (or `@jsonValue`) string in a header: standard base64
    of its UTF-8 bytes."""
    return base64_encode(value.as_bytes())


def aws_text_ts(epoch_seconds: Float64, fmt: Int) raises -> String:
    """A timestamp in `fmt` (AWS_TS_ISO8601 / AWS_TS_RFC822 / AWS_TS_UNIX).
    date-time and epoch-seconds keep milliseconds, trailing zeros cut;
    http-date has whole seconds. Refuses NaN and anything outside
    1970..9999."""
    return aws_token_ts(epoch_seconds, fmt).text


# -----------------------------------------------------------------------------
# Readers
# -----------------------------------------------------------------------------


def _is_digit(c: UInt8) -> Bool:
    return c >= UInt8(0x30) and c <= UInt8(0x39)


def aws_bool_from_text(text: String) raises -> Bool:
    """"true" or "false"; anything else is refused."""
    if text == "true":
        return True
    if text == "false":
        return False
    raise Error("an AWS boolean is neither true nor false")


def aws_int_from_text(text: String, bits: Int) raises -> Int64:
    """A `bits`-bit signed integer (8, 16, 32 or 64): an optional '-', then
    one or more decimal digits. Refuses any other byte and a value outside
    the kind's range."""
    if bits != 8 and bits != 16 and bits != 32 and bits != 64:
        raise Error("an AWS integer has " + String(bits) + " bits")
    var b = text.as_bytes()
    var i = 0
    var neg = False
    if len(b) > 0 and b[0] == UInt8(0x2D):
        neg = True
        i = 1
    if i == len(b):
        raise Error("an AWS integer has no digits")
    var top = UInt64(1) << UInt64(bits - 1)
    var limit = top if neg else top - 1
    var mag = UInt64(0)
    while i < len(b):
        if not _is_digit(b[i]):
            raise Error("an AWS integer has a byte that is not a digit")
        var d = UInt64(Int(b[i]) - 0x30)
        if mag > (limit - d) // 10:
            raise Error(
                "an AWS integer is outside the "
                + String(bits)
                + "-bit range"
            )
        mag = mag * 10 + d
        i += 1
    if not neg:
        return Int64(mag)
    if mag == 0:
        return Int64(0)
    return -Int64(mag - 1) - 1


def aws_i32_from_text(text: String) raises -> Int32:
    return Int32(aws_int_from_text(text, 32))


def aws_i64_from_text(text: String) raises -> Int64:
    return aws_int_from_text(text, 64)


def _scan_digits(b: Span[UInt8, _], mut i: Int) -> Int:
    var start = i
    while i < len(b) and _is_digit(b[i]):
        i += 1
    return i - start


def aws_f64_from_text(text: String) raises -> Float64:
    """A float or double: "NaN", "Infinity", "-Infinity", or a decimal
    number `-?D+(.D+)?([eE][+-]?D+)?`."""
    if text == "NaN":
        return _nan()
    if text == "Infinity":
        return _inf()
    if text == "-Infinity":
        return -_inf()
    var b = text.as_bytes()
    var i = 0
    if len(b) > 0 and b[0] == UInt8(0x2D):
        i = 1
    var ok = _scan_digits(b, i) > 0
    if ok and i < len(b) and b[i] == UInt8(0x2E):
        i += 1
        ok = _scan_digits(b, i) > 0
    if ok and i < len(b) and (b[i] == UInt8(0x65) or b[i] == UInt8(0x45)):
        i += 1
        if i < len(b) and (b[i] == UInt8(0x2B) or b[i] == UInt8(0x2D)):
            i += 1
        ok = _scan_digits(b, i) > 0
    if not ok or i != len(b):
        raise Error("an AWS number is not a decimal number, NaN or Infinity")
    return atof(text)


def aws_blob_from_base64(text: String) raises -> List[UInt8]:
    """A blob from its standard, padded base64 text."""
    try:
        return base64_decode(text)
    except:
        raise Error("an AWS blob is not valid base64")


def aws_media_from_text(text: String) raises -> String:
    """A `@mediaType` string from a header: base64-decoded, and refused
    when the decoded bytes are not well-formed UTF-8."""
    var raw = aws_blob_from_base64(text)
    return utf8_text(Span(raw), "an AWS media-type header value")


def aws_ts_from_text(text: String, fmt: Int) raises -> Float64:
    """A timestamp written in `fmt`. Refuses text in another format."""
    if fmt == AWS_TS_ISO8601:
        # The date-time reader indexes up to byte 19; the shortest date-time
        # ("YYYY-MM-DDTHH:MM:SSZ") is 20 bytes.
        if text.byte_length() < 20:
            raise Error("an AWS date-time is too short")
        return _parse_iso8601(text)
    if fmt == AWS_TS_RFC822:
        return aws_http_date_from_text(text)
    if fmt == AWS_TS_UNIX:
        return _epoch_seconds(text)
    raise Error("unknown AWS timestamp format " + String(fmt))


def _epoch_seconds(text: String) raises -> Float64:
    """epoch-seconds: `-?D+(.D+)?`, no exponent."""
    var b = text.as_bytes()
    var i = 0
    if len(b) > 0 and b[0] == UInt8(0x2D):
        i = 1
    var ok = _scan_digits(b, i) > 0
    if ok and i < len(b) and b[i] == UInt8(0x2E):
        i += 1
        ok = _scan_digits(b, i) > 0
    if not ok or i != len(b):
        raise Error("an AWS epoch-seconds timestamp is not a decimal number")
    return atof(text)


def _two(b: Span[UInt8, _], at: Int) raises -> Int:
    if at + 2 > len(b) or not _is_digit(b[at]) or not _is_digit(b[at + 1]):
        raise Error("an AWS http-date is malformed")
    return (Int(b[at]) - 0x30) * 10 + Int(b[at + 1]) - 0x30


def _name_index(names: String, text: String, at: Int) -> Int:
    """The index of the 3-letter name at bytes [at, at+3) of `text` in the
    concatenated `names`, -1 when it is none of them (case matters)."""
    var got = sub(text, at, at + 3)
    for k in range(names.byte_length() // 3):
        if sub(names, k * 3, k * 3 + 3) == got:
            return k
    return -1


def aws_http_date_from_text(text: String) raises -> Float64:
    """An http-date: IMF-fixdate, `Www, DD Mmm YYYY HH:MM:SS GMT` (RFC 9110
    section 5.6.7), with an optional fraction of a second after SS. The
    day name must be one of the seven; whether it agrees with the date is
    not checked (RFC 9110 calls it redundant). Refuses the obsolete
    rfc850-date and asctime-date forms."""
    var b = text.as_bytes()
    if len(b) < 29:
        raise Error("an AWS http-date is too short")
    if _name_index(String(_DAYS), text, 0) < 0:
        raise Error("an AWS http-date has an unknown day name")
    if b[3] != UInt8(0x2C) or b[4] != UInt8(0x20):
        raise Error("an AWS http-date is malformed")
    var d = _two(b, 5)
    if b[7] != UInt8(0x20):
        raise Error("an AWS http-date is malformed")
    var mo = _name_index(String(_MONTHS), text, 8) + 1
    if mo == 0:
        raise Error("an AWS http-date has an unknown month")
    if b[11] != UInt8(0x20):
        raise Error("an AWS http-date is malformed")
    var y = _two(b, 12) * 100 + _two(b, 14)
    if b[16] != UInt8(0x20):
        raise Error("an AWS http-date is malformed")
    var h = _two(b, 17)
    if b[19] != UInt8(0x3A):
        raise Error("an AWS http-date is malformed")
    var mi = _two(b, 20)
    if b[22] != UInt8(0x3A):
        raise Error("an AWS http-date is malformed")
    var s = _two(b, 23)
    var i = 25
    var frac = Float64(0.0)
    if i < len(b) and b[i] == UInt8(0x2E):
        i += 1
        var scale = Float64(0.1)
        var start = i
        while i < len(b) and _is_digit(b[i]):
            frac += Float64(Int(b[i]) - 0x30) * scale
            scale /= 10.0
            i += 1
        if i == start:
            raise Error("an AWS http-date has an empty fraction")
    if sub(text, i, len(b)) != " GMT":
        raise Error("an AWS http-date does not end in GMT")
    return Float64(_from_fields(y, mo, d, h, mi, s)) + frac
