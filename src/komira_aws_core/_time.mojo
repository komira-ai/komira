# =============================================================================
# komira_aws_core/_time.mojo -- the civil calendar under the timestamp codecs
# =============================================================================
#
# Package-private: aws_codec.mojo (awsJson) and aws_text.mojo (REST text)
# both write and read timestamps through it. Days count from 1970-01-01, in
# the proleptic Gregorian calendar.
# =============================================================================


comptime DAY_NAMES = "SunMonTueWedThuFriSat"
comptime MONTH_NAMES = "JanFebMarAprMayJunJulAugSepOctNovDec"


def civil(days: Int) -> Tuple[Int, Int, Int]:
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


def days_from_civil(y0: Int, m: Int, d: Int) -> Int:
    var y = y0 - 1 if m <= 2 else y0
    var era = y // 400
    var yoe = y - era * 400
    var mp = m - 3 if m > 2 else m + 9
    var doy = (153 * mp + 2) // 5 + d - 1
    var doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468


def digits_at(b: Span[UInt8, _], at: Int, n: Int) raises -> Int:
    if at + n > len(b):
        raise Error("an AWS timestamp is truncated")
    var v = 0
    for i in range(at, at + n):
        if b[i] < UInt8(0x30) or b[i] > UInt8(0x39):
            raise Error("an AWS timestamp has a non-digit where a digit belongs")
        v = v * 10 + Int(b[i] - UInt8(0x30))
    return v


def expect_byte(b: Span[UInt8, _], at: Int, c: UInt8) raises:
    if at >= len(b) or b[at] != c:
        raise Error("an AWS timestamp is malformed")


def from_fields(
    y: Int, mo: Int, d: Int, h: Int, mi: Int, s: Int
) raises -> Int:
    if mo < 1 or mo > 12 or d < 1 or d > 31 or h > 23 or mi > 59 or s > 60:
        raise Error("an AWS timestamp has a field out of range")
    var days = days_from_civil(y, mo, d)
    var back = civil(days)
    if back[1] != mo or back[2] != d:
        raise Error("an AWS timestamp names a day that does not exist")
    return days * 86400 + h * 3600 + mi * 60 + s


def parse_iso8601(text: String) raises -> Float64:
    """YYYY-MM-DDTHH:MM:SS[.f+](Z|+HH:MM|-HH:MM)."""
    var b = text.as_bytes()
    var y = digits_at(b, 0, 4)
    expect_byte(b, 4, UInt8(0x2D))
    var mo = digits_at(b, 5, 2)
    expect_byte(b, 7, UInt8(0x2D))
    var d = digits_at(b, 8, 2)
    if b[10] != UInt8(0x54) and b[10] != UInt8(0x74):
        raise Error("an AWS timestamp is malformed")
    var h = digits_at(b, 11, 2)
    expect_byte(b, 13, UInt8(0x3A))
    var mi = digits_at(b, 14, 2)
    expect_byte(b, 16, UInt8(0x3A))
    var s = digits_at(b, 17, 2)
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
        var oh = digits_at(b, i + 1, 2)
        expect_byte(b, i + 3, UInt8(0x3A))
        var om = digits_at(b, i + 4, 2)
        offset = sign * (oh * 3600 + om * 60)
        i += 6
    else:
        raise Error("an AWS timestamp has no time zone")
    if i != len(b):
        raise Error("an AWS timestamp has text after it")
    var secs = from_fields(y, mo, d, h, mi, s) - offset
    return Float64(secs) + frac
