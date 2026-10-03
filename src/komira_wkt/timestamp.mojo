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
# The calendar arithmetic and the RFC 3339 text are komira_datetime's; this
# file adds the protobuf range (years 0001..9999) and the 0 / 3 / 6 / 9
# fraction-digit rule.
# =============================================================================

from komira_datetime import (
    Timestamp as UtcInstant,
    format_rfc3339,
    parse_rfc3339,
)

from komira_proto_codec import (
    Serializable,
    Proto3JsonWkt,
    WireEncoder,
    WireDecoder,
)
from komira_json import JsonValue, JSON_STRING, write_json_string


# The canonical range of each type, as `timestamp.proto` and `duration.proto`
# state it: 0001-01-01T00:00:00Z through 9999-12-31T23:59:59Z, and
# +-10000 years of seconds.
comptime _TS_MIN_SECONDS: Int = -62135596800
comptime _TS_MAX_SECONDS: Int = 253402300799
comptime _DUR_MAX_SECONDS: Int = 315576000000


# =============================================================================
# google.protobuf.Timestamp
# =============================================================================


@fieldwise_init
struct Timestamp(Proto3JsonWkt, Copyable, Movable, ImplicitlyCopyable):
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
        generated client / `encode_json` wraps it as a JSON string.

        REFUSES a value the canonical form cannot express: `seconds` outside
        0001-01-01T00:00:00Z..9999-12-31T23:59:59Z, or `nanos` outside
        [0, 999999999]."""
        var secs = Int(self.seconds)
        var nanos = Int(self.nanos)
        if secs < _TS_MIN_SECONDS or secs > _TS_MAX_SECONDS:
            raise Error(
                "WktError: Timestamp seconds outside 0001..9999: "
                + String(secs)
            )
        if nanos < 0 or nanos > 999999999:
            raise Error(
                "WktError: Timestamp nanos outside [0, 999999999]: "
                + String(nanos)
            )
        # Nine fraction digits, cut to the shortest group of three that is
        # exact: the proto3 JSON rule of 0, 3, 6 or 9 digits.
        return format_rfc3339(UtcInstant(secs, nanos), 9, 3)

    @staticmethod
    def from_proto3_json(text: String) raises -> Self:
        """Parse the RFC-3339 string form (the raw scalar text, unquoted).

        Accepts `YYYY-MM-DDTHH:MM:SS[.f{1,9}]` and a zone: `Z`, or a
        `+hh:mm` / `-hh:mm` offset (RFC 3339 allows one on input; the
        canonical OUTPUT is always `Z`), which is applied. `T` and `Z` must
        be upper case; a leap second (`:60`) is refused. The instant must
        lie in 0001-01-01T00:00:00Z..9999-12-31T23:59:59.999999999Z."""
        var ts: UtcInstant
        try:
            ts = parse_rfc3339(text, allow_lowercase=False)
        except e:
            raise Error("WktError: bad Timestamp (" + String(e) + "): " + text)
        if ts.seconds < _TS_MIN_SECONDS or ts.seconds > _TS_MAX_SECONDS:
            raise Error("WktError: Timestamp outside 0001..9999: " + text)
        return Self(Int64(ts.seconds), Int32(ts.nanos))

    # -- `Proto3JsonWkt`: the codec arms call these ----------------------

    def write_proto3_json(self, mut buf: List[UInt8]) raises:
        write_json_string(buf, self.to_proto3_json())

    @staticmethod
    def read_proto3_json(v: JsonValue) raises -> Self:
        if v.kind != JSON_STRING:
            raise Error("WktError: Timestamp JSON must be an RFC 3339 string")
        return Self.from_proto3_json(v.text)


# =============================================================================
# google.protobuf.Duration
# =============================================================================


@fieldwise_init
struct Duration(Proto3JsonWkt, Copyable, Movable, ImplicitlyCopyable):
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
        if secs < -_DUR_MAX_SECONDS or secs > _DUR_MAX_SECONDS:
            raise Error(
                "WktError: Duration seconds outside +-315576000000: "
                + String(secs)
            )
        if nanos < -999999999 or nanos > 999999999:
            raise Error(
                "WktError: Duration nanos outside +-999999999: "
                + String(nanos)
            )
        if (secs > 0 and nanos < 0) or (secs < 0 and nanos > 0):
            raise Error(
                "WktError: Duration seconds and nanos have opposite signs: "
                + String(secs) + ", " + String(nanos)
            )
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
        if idx - int_start > 12:
            raise Error("WktError: Duration out of range: " + text)
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
        if whole > _DUR_MAX_SECONDS:
            raise Error("WktError: Duration out of range: " + text)
        var secs_signed = -whole if negative else whole
        var nanos_signed = -nanos if negative else nanos
        return Self(Int64(secs_signed), Int32(nanos_signed))

    # -- `Proto3JsonWkt`: the codec arms call these ----------------------

    def write_proto3_json(self, mut buf: List[UInt8]) raises:
        write_json_string(buf, self.to_proto3_json())

    @staticmethod
    def read_proto3_json(v: JsonValue) raises -> Self:
        if v.kind != JSON_STRING:
            raise Error("WktError: Duration JSON must be a string like 1.5s")
        return Self.from_proto3_json(v.text)


# =============================================================================
# Decimal helpers of the Duration form.
# =============================================================================


def _frac_suffix(nanos: Int) -> String:
    """The fractional-seconds suffix of a Duration string.

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
