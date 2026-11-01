# =============================================================================
# tzif.mojo -- the TZif reader (RFC 9636, which obsoletes RFC 8536)
# =============================================================================
#
# A TZif file is a 44-byte header, a data block, and from version 2 on a
# second header, a second data block with 64-bit times, and a footer:
#
#   header  "TZif", version (0, '2', '3' or '4': RFC 8536 defines 1 to 3,
#           RFC 9636 adds 4), 15 reserved bytes, then six
#           big-endian 32-bit counts: isutcnt, isstdcnt, leapcnt, timecnt,
#           typecnt, charcnt
#   block   timecnt transition times (4 bytes in version 1, 8 after), timecnt
#           type indices (1 byte), typecnt local time types (utoff 4 bytes
#           signed, isdst 1, desigidx 1), charcnt abbreviation bytes,
#           leapcnt leap-second records, isstdcnt and isutcnt indicators
#   footer  "\n" POSIX TZ string "\n" (the string may be empty)
#
# A version 2+ reader skips the version 1 block and reads the second one:
# zic's "slim" output leaves the first block empty, and the 32-bit block of a
# "fat" file stops at 2038. A version 1 file is read from its only block, and
# has no footer.
#
# Refused, each with an error naming the file and the fault: a bad magic or
# version, a second header that disagrees with the first, a truncated file,
# bytes after the footer, typecnt or charcnt of zero, an isutcnt or isstdcnt
# other than 0 or typecnt, transition times not strictly ascending, a type
# index past typecnt, an isdst other than 0 or 1, a UTC offset outside
# -26..+26 hours (both ends inclusive, so -93600 and +93600 are read: RFC
# 9636 section 3.2 says utoff MUST NOT be -2^31 and SHOULD be in
# [-89999, 93599]; that SHOULD binds writers, and this reader accepts the
# wider band and refuses -2^31 with everything else past it), an abbreviation index past charcnt or with no NUL after it,
# an abbreviation byte other than a letter, digit, `+` or `-`, an
# unparseable footer, a footer that gives another type at the last
# transition than the file does (RFC 9636 section 3.3: the string MUST be
# consistent with the last transition), and leap-second records (a "right/"
# zone counts TAI seconds, which epoch seconds do not). Version 4 differs
# from 3 only in what its leap-second records may say, so with those refused
# a version 4 file reads as a version 3 one.
#
# The standard/wall and UT/local indicators are read past and not kept: they
# only matter to a POSIX TZ string given without rules, which a TZif footer
# never is.
# =============================================================================

from .zone_offset import ZoneOffset
from .posix_tz import PosixRule, PosixTz, RULE_JULIAN, parse_posix_tz
from .zone import Zone

comptime _HEADER_BYTES = 44
comptime _MAX_UTC_OFFSET = 26 * 3600  # inclusive; see the module header


struct _Counts(Copyable, ImplicitlyCopyable, Movable):
    var isutcnt: Int
    var isstdcnt: Int
    var leapcnt: Int
    var timecnt: Int
    var typecnt: Int
    var charcnt: Int
    var version: Int

    def __init__(out self):
        self.isutcnt = 0
        self.isstdcnt = 0
        self.leapcnt = 0
        self.timecnt = 0
        self.typecnt = 0
        self.charcnt = 0
        self.version = 0

    def block_bytes(self, time_size: Int) -> Int:
        return (
            self.timecnt * time_size
            + self.timecnt
            + self.typecnt * 6
            + self.charcnt
            + self.leapcnt * (time_size + 4)
            + self.isstdcnt
            + self.isutcnt
        )


def _describe(t: ZoneOffset) -> String:
    return (
        t.abbreviation + " (utoff " + String(t.utc_offset) + ", isdst "
        + String(Int(t.is_dst)) + ")"
    )


def _fail(name: String, what: String) -> Error:
    return Error("TZif " + name + ": " + what)


def _u32(data: Span[UInt8, _], at: Int) -> Int:
    return (
        (Int(data[at]) << 24)
        | (Int(data[at + 1]) << 16)
        | (Int(data[at + 2]) << 8)
        | Int(data[at + 3])
    )


def _i32(data: Span[UInt8, _], at: Int) -> Int:
    var v = _u32(data, at)
    if v >= 0x8000_0000:
        v -= 0x1_0000_0000
    return v


def _i64(data: Span[UInt8, _], at: Int) -> Int:
    var u = UInt64(0)
    for k in range(8):
        u = (u << 8) | UInt64(data[at + k])
    return Int(u.cast[DType.int64]())


def _header(data: Span[UInt8, _], at: Int, name: String) raises -> _Counts:
    if len(data) < at + _HEADER_BYTES:
        raise _fail(
            name,
            "truncated: a header needs "
            + String(at + _HEADER_BYTES)
            + " bytes, the file has "
            + String(len(data)),
        )
    if (
        Int(data[at]) != ord("T")
        or Int(data[at + 1]) != ord("Z")
        or Int(data[at + 2]) != ord("i")
        or Int(data[at + 3]) != ord("f")
    ):
        raise _fail(name, "no TZif magic at byte " + String(at))
    var c = _Counts()
    var v = Int(data[at + 4])
    if v == 0:
        c.version = 1
    elif v >= ord("2") and v <= ord("4"):
        c.version = v - ord("0")
    else:
        raise _fail(name, "unknown version byte " + String(v))
    c.isutcnt = _u32(data, at + 20)
    c.isstdcnt = _u32(data, at + 24)
    c.leapcnt = _u32(data, at + 28)
    c.timecnt = _u32(data, at + 32)
    c.typecnt = _u32(data, at + 36)
    c.charcnt = _u32(data, at + 40)
    if c.typecnt == 0:
        raise _fail(name, "typecnt is 0")
    if c.charcnt == 0:
        raise _fail(name, "charcnt is 0")
    if c.isutcnt != 0 and c.isutcnt != c.typecnt:
        raise _fail(name, "isutcnt is neither 0 nor typecnt")
    if c.isstdcnt != 0 and c.isstdcnt != c.typecnt:
        raise _fail(name, "isstdcnt is neither 0 nor typecnt")
    if c.leapcnt != 0:
        raise _fail(
            name,
            "leap-second records are not supported (the zone counts TAI seconds)",
        )
    return c


def _abbreviation(
    data: Span[UInt8, _], chars_at: Int, charcnt: Int, index: Int, name: String
) raises -> String:
    if index >= charcnt:
        raise _fail(
            name,
            "abbreviation index " + String(index) + " is past charcnt " + String(charcnt),
        )
    var out = String()
    var i = index
    while i < charcnt:
        var b = Int(data[chars_at + i])
        if b == 0:
            return out^
        var ok = (
            (b >= ord("A") and b <= ord("Z"))
            or (b >= ord("a") and b <= ord("z"))
            or (b >= ord("0") and b <= ord("9"))
            or b == ord("+")
            or b == ord("-")
        )
        if not ok:
            raise _fail(
                name,
                "abbreviation byte " + String(b) + " is not a letter, digit, + or -",
            )
        out += chr(b)
        i += 1
    raise _fail(name, "abbreviation at index " + String(index) + " has no NUL")


def parse_tzif(data: Span[UInt8, _], name: String) raises -> Zone:
    """Reads one TZif file (the module header); `name` is the zone's name,
    kept on the `Zone` and used in every error."""
    var first = _header(data, 0, name)
    var at = _HEADER_BYTES
    var c = first
    var time_size = 4
    if first.version >= 2:
        at += first.block_bytes(4)
        c = _header(data, at, name)
        if c.version != first.version:
            raise _fail(
                name,
                "the second header's version "
                + String(c.version)
                + " is not the first's "
                + String(first.version),
            )
        at += _HEADER_BYTES
        time_size = 8
    var end = at + c.block_bytes(time_size)
    if len(data) < end:
        raise _fail(
            name,
            "truncated: the data block needs "
            + String(end)
            + " bytes, the file has "
            + String(len(data)),
        )

    var times = List[Int](capacity=c.timecnt)
    for i in range(c.timecnt):
        var t: Int
        if time_size == 8:
            t = _i64(data, at + i * 8)
        else:
            t = _i32(data, at + i * 4)
        if i > 0 and t <= times[i - 1]:
            raise _fail(
                name,
                "transition " + String(i) + " is not after transition " + String(i - 1),
            )
        times.append(t)
    at += c.timecnt * time_size

    var type_index = List[Int](capacity=c.timecnt)
    for i in range(c.timecnt):
        var idx = Int(data[at + i])
        if idx >= c.typecnt:
            raise _fail(
                name,
                "transition " + String(i) + " names type " + String(idx)
                + ", past typecnt " + String(c.typecnt),
            )
        type_index.append(idx)
    at += c.timecnt

    var chars_at = at + c.typecnt * 6
    var types = List[ZoneOffset](capacity=c.typecnt)
    for i in range(c.typecnt):
        var p = at + i * 6
        var utoff = _i32(data, p)
        if utoff < -_MAX_UTC_OFFSET or utoff > _MAX_UTC_OFFSET:
            raise _fail(
                name,
                "type " + String(i) + " has UTC offset " + String(utoff)
                + ", outside -26..+26 hours",
            )
        var isdst = Int(data[p + 4])
        if isdst > 1:
            raise _fail(name, "type " + String(i) + " has isdst " + String(isdst))
        var abbr = _abbreviation(data, chars_at, c.charcnt, Int(data[p + 5]), name)
        types.append(ZoneOffset(utoff, isdst == 1, abbr^))
    at = end

    var has_footer = False
    var footer = PosixTz(
        String(),
        types[0].copy(),
        False,
        types[0].copy(),
        PosixRule(RULE_JULIAN, 1, 0, 0, 0, 0),
        PosixRule(RULE_JULIAN, 1, 0, 0, 0, 0),
    )
    if c.version >= 2:
        if at >= len(data) or Int(data[at]) != ord("\n"):
            raise _fail(name, "no newline opens the footer at byte " + String(at))
        var close = at + 1
        while close < len(data) and Int(data[close]) != ord("\n"):
            close += 1
        if close >= len(data):
            raise _fail(name, "no newline closes the footer")
        if close + 1 != len(data):
            raise _fail(
                name,
                String(len(data) - close - 1) + " bytes follow the footer",
            )
        var tz = String()
        for i in range(at + 1, close):
            var b = Int(data[i])
            if b < 0x20 or b > 0x7E:
                raise _fail(name, "footer byte " + String(b) + " is not printable ASCII")
            tz += chr(b)
        if tz.byte_length() > 0:
            footer = parse_posix_tz(tz)
            has_footer = True
            if c.timecnt > 0:
                var last = times[c.timecnt - 1]
                var from_footer = footer.offset_at(last)
                ref from_file = types[type_index[c.timecnt - 1]]
                if from_footer != from_file:
                    raise _fail(
                        name,
                        "the footer \"" + tz + "\" gives "
                        + _describe(from_footer) + " at the last transition "
                        + String(last) + "; the file gives "
                        + _describe(from_file),
                    )
    elif at != len(data):
        raise _fail(
            name, String(len(data) - at) + " bytes follow the version 1 data block"
        )
    return Zone(name.copy(), times^, type_index^, types^, has_footer, footer^)
