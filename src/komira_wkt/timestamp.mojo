# =============================================================================
# timestamp.mojo — google.protobuf.Timestamp + google.protobuf.Duration.
# =============================================================================
#
# The two most-used WKTs.
#
#   message Timestamp { int64 seconds = 1; int32 nanos = 2; }
#   message Duration  { int64 seconds = 1; int32 nanos = 2; }
#
# Wire form (protobuf-binary): the two scalar fields, via `Serializable`.
# Canonical JSON form (proto3 JSON mapping):
#   - Timestamp -> an RFC-3339 / ISO-8601 UTC string, e.g.
#     "1972-01-01T10:00:20.021Z". `seconds` is a Unix epoch offset; the
#     fractional part is 0 / 3 / 6 / 9 digits (shortest that is exact).
#   - Duration  -> "<seconds>[.<frac>]s", e.g. "1.000340012s" or "-12s".
#     A negative duration has the sign on `seconds` (and `nanos` carries the
#     same sign per the proto spec).
#
# `to_proto3_json()` / `from_proto3_json()` implement the canonical-JSON
# special form; the `Serializable` `encode` / `decode` bodies are the generic
# two-field protobuf-binary path (correct + round-trip-safe on
# `PbEncoder`/`PbDecoder`).
#
# The civil-date conversion is the standard branch-free algorithm (Howard
# Hinnant, "chrono-Compatible Low-Level Date Algorithms"). It is kept
# self-contained here so `komira_wkt` needs no more than `komira_proto_codec`.
# =============================================================================

from komira_proto_codec import Serializable, WireEncoder, WireDecoder


# =============================================================================
# google.protobuf.Timestamp
# =============================================================================


@fieldwise_init
struct Timestamp(Serializable, Copyable, Movable, ImplicitlyCopyable):
    """`google.protobuf.Timestamp` — a point in time as a Unix-epoch offset.

    `seconds` is seconds since 1970-01-01T00:00:00Z; `nanos` is the
    non-negative fractional nanoseconds in `[0, 999999999]`.
    """

    var seconds: Int64
    var nanos: Int32

    @staticmethod
    def new() -> Self:
        """The epoch zero value (1970-01-01T00:00:00Z)."""
        return Self(Int64(0), Int32(0))

    # -- the `Serializable` protobuf-binary surface -----------------------

    def encode[E: WireEncoder](self, mut enc: E) raises:
        """Encode as the two-field protobuf message form."""
        enc.write_i64_field(1, "seconds", self.seconds)
        enc.write_i32_field(2, "nanos", self.nanos)

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        """Decode from the two-field protobuf message form."""
        var seconds = Int64(0)
        var nanos = Int32(0)
        while True:
            var key = dec.next_field()
            if key.end:
                break
            if key.field_no == 1 or key.json_name == "seconds":
                seconds = dec.read_i64()
            elif key.field_no == 2 or key.json_name == "nanos":
                nanos = dec.read_i32()
            else:
                dec.skip()
        return Self(seconds, nanos)

    # -- the canonical-JSON surface ---------------------------------------

    def to_proto3_json(self) raises -> String:
        """The RFC-3339 string form, e.g. `"1972-01-01T10:00:20.021Z"`.

        Returns the raw scalar text WITHOUT enclosing JSON quotes — the
        generated client / `encode_json` wraps it as a JSON string."""
        var secs = Int(self.seconds)
        var nanos = Int(self.nanos)
        # The day index and the seconds-of-day, floor-divided so a negative
        # epoch (a pre-1970 timestamp) lands on the correct civil day.
        var days = _floor_div(secs, 86400)
        var sod = secs - days * 86400
        var ymd = _civil_from_days(days)
        var hh = sod // 3600
        var mm = (sod % 3600) // 60
        var ss = sod % 60
        var out = String("")
        out += _pad4(ymd[0])
        out += "-"
        out += _pad2(ymd[1])
        out += "-"
        out += _pad2(ymd[2])
        out += "T"
        out += _pad2(hh)
        out += ":"
        out += _pad2(mm)
        out += ":"
        out += _pad2(ss)
        out += _frac_suffix(nanos)
        out += "Z"
        return out

    @staticmethod
    def from_proto3_json(text: String) raises -> Self:
        """Parse the RFC-3339 string form (the raw scalar text, unquoted).

        Accepts `YYYY-MM-DDTHH:MM:SS[.fff]Z`. A trailing `Z` is required
        (proto3-canonical Timestamps are always UTC)."""
        var b = _bytes_of(text)
        var n = len(b)
        if n < 20:
            raise Error("WktError: Timestamp JSON too short: " + text)
        var year = _parse_uint(b, 0, 4)
        _expect(b, 4, 0x2D, text)  # '-'
        var month = _parse_uint(b, 5, 2)
        _expect(b, 7, 0x2D, text)  # '-'
        var day = _parse_uint(b, 8, 2)
        _expect(b, 10, 0x54, text)  # 'T'
        var hh = _parse_uint(b, 11, 2)
        _expect(b, 13, 0x3A, text)  # ':'
        var mm = _parse_uint(b, 14, 2)
        _expect(b, 16, 0x3A, text)  # ':'
        var ss = _parse_uint(b, 17, 2)
        # Optional fractional seconds.
        var nanos = 0
        var idx = 19
        if idx < n and b[idx] == 0x2E:  # '.'
            idx += 1
            var frac_start = idx
            while idx < n and b[idx] >= 0x30 and b[idx] <= 0x39:
                idx += 1
            var frac_digits = idx - frac_start
            if frac_digits == 0 or frac_digits > 9:
                raise Error("WktError: bad Timestamp fraction: " + text)
            var frac_val = _parse_uint(b, frac_start, frac_digits)
            # Scale the fraction up to nanoseconds (9 digits).
            var scale = 1
            for _ in range(9 - frac_digits):
                scale *= 10
            nanos = frac_val * scale
        if idx >= n or b[idx] != 0x5A:  # 'Z'
            raise Error("WktError: Timestamp must end in 'Z' (UTC): " + text)
        var days = _days_from_civil(year, month, day)
        var secs = days * 86400 + hh * 3600 + mm * 60 + ss
        return Self(Int64(secs), Int32(nanos))


# =============================================================================
# google.protobuf.Duration
# =============================================================================


@fieldwise_init
struct Duration(Serializable, Copyable, Movable, ImplicitlyCopyable):
    """`google.protobuf.Duration` — a signed, fixed-length span of time.

    `seconds` is the whole-second span; `nanos` is the fractional part in
    `[-999999999, 999999999]`. A non-zero `Duration` has `seconds` and
    `nanos` of the same sign (proto spec)."""

    var seconds: Int64
    var nanos: Int32

    @staticmethod
    def new() -> Self:
        """A zero-length duration."""
        return Self(Int64(0), Int32(0))

    # -- the `Serializable` protobuf-binary surface -----------------------

    def encode[E: WireEncoder](self, mut enc: E) raises:
        """Encode as the two-field protobuf message form."""
        enc.write_i64_field(1, "seconds", self.seconds)
        enc.write_i32_field(2, "nanos", self.nanos)

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        """Decode from the two-field protobuf message form."""
        var seconds = Int64(0)
        var nanos = Int32(0)
        while True:
            var key = dec.next_field()
            if key.end:
                break
            if key.field_no == 1 or key.json_name == "seconds":
                seconds = dec.read_i64()
            elif key.field_no == 2 or key.json_name == "nanos":
                nanos = dec.read_i32()
            else:
                dec.skip()
        return Self(seconds, nanos)

    # -- the canonical-JSON surface ---------------------------------------

    def to_proto3_json(self) raises -> String:
        """The `"<seconds>[.<frac>]s"` string form (raw, unquoted).

        e.g. `3s`, `1.000340012s`, `-12s`. The sign is carried once on the
        whole-second magnitude; an all-zero duration is `0s`."""
        var secs = Int(self.seconds)
        var nanos = Int(self.nanos)
        var negative = secs < 0 or nanos < 0
        var abs_secs = secs if secs >= 0 else -secs
        var abs_nanos = nanos if nanos >= 0 else -nanos
        var out = String("")
        if negative:
            out += "-"
        out += String(abs_secs)
        out += _frac_suffix(abs_nanos)
        out += "s"
        return out

    @staticmethod
    def from_proto3_json(text: String) raises -> Self:
        """Parse the `"<seconds>[.<frac>]s"` string form (raw, unquoted)."""
        var b = _bytes_of(text)
        var n = len(b)
        if n < 2 or b[n - 1] != 0x73:  # 's'
            raise Error("WktError: Duration JSON must end in 's': " + text)
        var idx = 0
        var negative = False
        if b[idx] == 0x2D:  # '-'
            negative = True
            idx += 1
        elif b[idx] == 0x2B:  # '+'
            idx += 1
        var int_start = idx
        while idx < n - 1 and b[idx] >= 0x30 and b[idx] <= 0x39:
            idx += 1
        if idx == int_start:
            raise Error("WktError: Duration has no integer part: " + text)
        var whole = _parse_uint(b, int_start, idx - int_start)
        var nanos = 0
        if idx < n - 1 and b[idx] == 0x2E:  # '.'
            idx += 1
            var frac_start = idx
            while idx < n - 1 and b[idx] >= 0x30 and b[idx] <= 0x39:
                idx += 1
            var frac_digits = idx - frac_start
            if frac_digits == 0 or frac_digits > 9:
                raise Error("WktError: bad Duration fraction: " + text)
            var frac_val = _parse_uint(b, frac_start, frac_digits)
            var scale = 1
            for _ in range(9 - frac_digits):
                scale *= 10
            nanos = frac_val * scale
        if idx != n - 1:
            raise Error("WktError: trailing chars in Duration: " + text)
        var secs_signed = -whole if negative else whole
        var nanos_signed = -nanos if negative else nanos
        return Self(Int64(secs_signed), Int32(nanos_signed))


# =============================================================================
# Self-contained helpers — civil-date conversion + decimal formatting.
# =============================================================================


@always_inline
def _floor_div(a: Int, b: Int) -> Int:
    """Floor division — rounds toward negative infinity (`a // b` in Mojo on
    `Int` truncates toward zero; a pre-1970 epoch needs the floor)."""
    var q = a // b
    if (a % b != 0) and ((a < 0) != (b < 0)):
        q -= 1
    return q


def _days_from_civil(y: Int, m: Int, d: Int) -> Int:
    """Days since 1970-01-01 for a proleptic-Gregorian (y, m, d).

    Howard Hinnant's branch-free algorithm — exact for the full Int range."""
    var yy = y - (1 if m <= 2 else 0)
    var era = (yy if yy >= 0 else yy - 399) // 400
    var yoe = yy - era * 400
    var doy = (153 * (m + (-3 if m > 2 else 9)) + 2) // 5 + d - 1
    var doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468


def _civil_from_days(z_in: Int) -> Array[Int, 3]:
    """The proleptic-Gregorian (year, month, day) for a days-since-1970
    index. The inverse of `_days_from_civil` (Howard Hinnant)."""
    var z = z_in + 719468
    var era = (z if z >= 0 else z - 146096) // 146097
    var doe = z - era * 146097
    var yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    var y = yoe + era * 400
    var doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    var mp = (5 * doy + 2) // 153
    var d = doy - (153 * mp + 2) // 5 + 1
    var m = mp + (3 if mp < 10 else -9)
    var year = y + (1 if m <= 2 else 0)
    var out = Array[Int, 3](fill=0)
    out[0] = year
    out[1] = m
    out[2] = d
    return out^


def _frac_suffix(nanos: Int) -> String:
    """The fractional-seconds suffix for an RFC-3339 / Duration string.

    Empty if `nanos == 0`; otherwise `.fff` (3 digits), `.ffffff` (6), or
    `.fffffffff` (9) — the shortest length that represents `nanos` exactly,
    per the proto3-JSON spec."""
    if nanos == 0:
        return String("")
    var digits = String("")
    var x = nanos
    # Build the 9-digit zero-padded fraction.
    var tmp = Array[Int, 9](fill=0)
    for i in range(9):
        tmp[8 - i] = x % 10
        x = x // 10
    # Trim trailing zeros to 3 / 6 / 9 boundaries.
    var keep = 9
    if tmp[6] == 0 and tmp[7] == 0 and tmp[8] == 0:
        keep = 6
        if tmp[3] == 0 and tmp[4] == 0 and tmp[5] == 0:
            keep = 3
    for i in range(keep):
        digits += String(tmp[i])
    return String(".") + digits


def _pad2(v: Int) -> String:
    """A non-negative `Int` as a 2-digit zero-padded decimal."""
    if v < 10:
        return String("0") + String(v)
    return String(v)


def _pad4(v: Int) -> String:
    """A non-negative `Int` as a 4-digit zero-padded decimal (the year)."""
    var s = String(v)
    while s.byte_length() < 4:
        s = String("0") + s
    return s


def _bytes_of(s: String) -> List[UInt8]:
    """Materialize a `String`'s raw UTF-8 bytes into an owned `List[UInt8]`.

    The parse helpers index a `List[UInt8]` rather than the `Span` that
    `String.as_bytes()` returns — a `Span` parameter would have to thread an
    explicit unbound origin, and the date-string parse is not on any hot
    path, so an owned-`List` copy is the simpler, encapsulation-clean shape.
    """
    var out = List[UInt8]()
    var src = s.as_bytes()
    for i in range(len(src)):
        out.append(src[i])
    return out^


def _parse_uint(b: List[UInt8], start: Int, count: Int) raises -> Int:
    """Parse `count` ASCII decimal digits at `b[start:]` into an Int."""
    var v = 0
    for i in range(count):
        var c = b[start + i]
        if c < 0x30 or c > 0x39:
            raise Error("WktError: expected a decimal digit")
        v = v * 10 + Int(c - 0x30)
    return v


def _expect(b: List[UInt8], idx: Int, ch: UInt8, ctx: String) raises:
    """Assert `b[idx]` is the literal byte `ch` (a date-string separator)."""
    if idx >= len(b) or b[idx] != ch:
        raise Error("WktError: malformed date/time string: " + ctx)
