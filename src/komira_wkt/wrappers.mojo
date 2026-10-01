# =============================================================================
# wrappers.mojo — the google.protobuf scalar wrapper WKTs.
# =============================================================================
#
#   message DoubleValue { double value = 1; }
#   message FloatValue  { float  value = 1; }
#   message Int64Value  { int64  value = 1; }
#   message UInt64Value { uint64 value = 1; }
#   message Int32Value  { int32  value = 1; }
#   message UInt32Value { uint32 value = 1; }
#   message BoolValue   { bool   value = 1; }
#   message StringValue { string value = 1; }
#   message BytesValue  { bytes  value = 1; }
#
# A scalar wrapper boxes one scalar so a `.proto` can distinguish "field is
# absent" from "field is the zero value" (a wrapper-typed message field is
# itself `Optional` in the generated struct).
#
# Wire form (protobuf-binary): the single `value` field, via `Serializable`.
# Canonical JSON form (proto3 JSON mapping): the BARE scalar's JSON form —
# NOT an object.
# A `StringValue("hi")` is the JSON value `"hi"`; an `Int32Value(7)` is `7`;
# an `Int64Value(...)` is a JSON STRING (the int64 precision-safety rule);
# a `BytesValue` is a base64 string.
#
# `to_proto3_json()` returns the raw scalar JSON text (a number / `true` /
# `false`, or — for the string-shaped wrappers — the text WITHOUT enclosing
# quotes; the caller wraps it). `is_json_string()` tells the caller whether
# the value must be JSON-quoted. This split keeps the wrappers usable both
# standalone and as a generated message field.
# =============================================================================

from komira_serde import (
    Serializable,
    Proto3JsonWkt,
    WireEncoder,
    WireDecoder,
    JsonValue,
    JSON_NUMBER,
    JSON_STRING,
    write_json_string,
    write_i64_dec,
    write_f64_dtoa,
)
from komira_serde import base64_encode, base64_decode


# =============================================================================
# DoubleValue / FloatValue — floating-point wrappers (JSON: a number).
# =============================================================================


@fieldwise_init
struct DoubleValue(Proto3JsonWkt, Copyable, Movable, ImplicitlyCopyable):
    """`google.protobuf.DoubleValue` — a boxed `double`."""

    var value: Float64

    def encode[E: WireEncoder](self, mut enc: E) raises:
        enc.write_f64_field(1, "value", self.value)

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        var v = Float64(0.0)
        while True:
            var key = dec.next_field()
            if key.end:
                break
            if key.field_no == 1 or key.json_name == "value":
                v = dec.read_f64()
            else:
                dec.skip()
        return Self(v)

    # -- `Proto3JsonWkt`: the bare scalar, through the codec arms ------

    def write_proto3_json(self, mut buf: List[UInt8]) raises:
        _write_f64_json(buf, self.value)

    @staticmethod
    def read_proto3_json(v: JsonValue) raises -> Self:
        return Self(_read_f64_json(v))

    def to_proto3_json(self) -> String:
        return String(self.value)

    @staticmethod
    def is_json_string() -> Bool:
        return False

    @staticmethod
    def from_proto3_json(text: String) raises -> Self:
        return Self(_parse_f64(text))


@fieldwise_init
struct FloatValue(Proto3JsonWkt, Copyable, Movable, ImplicitlyCopyable):
    """`google.protobuf.FloatValue` — a boxed `float`."""

    var value: Float32

    def encode[E: WireEncoder](self, mut enc: E) raises:
        enc.write_f32_field(1, "value", self.value)

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        var v = Float32(0.0)
        while True:
            var key = dec.next_field()
            if key.end:
                break
            if key.field_no == 1 or key.json_name == "value":
                v = dec.read_f32()
            else:
                dec.skip()
        return Self(v)

    # -- `Proto3JsonWkt`: the bare scalar, through the codec arms ------

    def write_proto3_json(self, mut buf: List[UInt8]) raises:
        _write_f64_json(buf, Float64(self.value))

    @staticmethod
    def read_proto3_json(v: JsonValue) raises -> Self:
        return Self(Float32(_read_f64_json(v)))

    def to_proto3_json(self) -> String:
        return String(self.value)

    @staticmethod
    def is_json_string() -> Bool:
        return False

    @staticmethod
    def from_proto3_json(text: String) raises -> Self:
        return Self(Float32(_parse_f64(text)))


# =============================================================================
# Int64Value / UInt64Value — 64-bit wrappers (JSON: a STRING, for precision).
# =============================================================================


@fieldwise_init
struct Int64Value(Proto3JsonWkt, Copyable, Movable, ImplicitlyCopyable):
    """`google.protobuf.Int64Value` — a boxed `int64`."""

    var value: Int64

    def encode[E: WireEncoder](self, mut enc: E) raises:
        enc.write_i64_field(1, "value", self.value)

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        var v = Int64(0)
        while True:
            var key = dec.next_field()
            if key.end:
                break
            if key.field_no == 1 or key.json_name == "value":
                v = dec.read_i64()
            else:
                dec.skip()
        return Self(v)

    # -- `Proto3JsonWkt`: the bare scalar, through the codec arms ------

    def write_proto3_json(self, mut buf: List[UInt8]) raises:
        buf.append(0x22)
        write_i64_dec(buf, self.value)
        buf.append(0x22)

    @staticmethod
    def read_proto3_json(v: JsonValue) raises -> Self:
        return Self(v.as_int64())

    def to_proto3_json(self) -> String:
        # proto3 JSON: int64 -> JSON STRING. Raw decimal text; the caller
        # quotes.
        return String(self.value)

    @staticmethod
    def is_json_string() -> Bool:
        return True

    @staticmethod
    def from_proto3_json(text: String) raises -> Self:
        return Self(Int64(_parse_int(text)))


@fieldwise_init
struct UInt64Value(Proto3JsonWkt, Copyable, Movable, ImplicitlyCopyable):
    """`google.protobuf.UInt64Value` — a boxed `uint64`."""

    var value: UInt64

    def encode[E: WireEncoder](self, mut enc: E) raises:
        enc.write_u64_field(1, "value", self.value)

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        var v = UInt64(0)
        while True:
            var key = dec.next_field()
            if key.end:
                break
            if key.field_no == 1 or key.json_name == "value":
                v = dec.read_u64()
            else:
                dec.skip()
        return Self(v)

    # -- `Proto3JsonWkt`: the bare scalar, through the codec arms ------

    def write_proto3_json(self, mut buf: List[UInt8]) raises:
        write_json_string(buf, String(self.value))

    @staticmethod
    def read_proto3_json(v: JsonValue) raises -> Self:
        return Self(v.as_uint64())

    def to_proto3_json(self) -> String:
        # proto3 JSON: uint64 -> JSON STRING.
        return String(self.value)

    @staticmethod
    def is_json_string() -> Bool:
        return True

    @staticmethod
    def from_proto3_json(text: String) raises -> Self:
        return Self(UInt64(_parse_uint_text(text)))


# =============================================================================
# Int32Value / UInt32Value — 32-bit wrappers (JSON: a number).
# =============================================================================


@fieldwise_init
struct Int32Value(Proto3JsonWkt, Copyable, Movable, ImplicitlyCopyable):
    """`google.protobuf.Int32Value` — a boxed `int32`."""

    var value: Int32

    def encode[E: WireEncoder](self, mut enc: E) raises:
        enc.write_i32_field(1, "value", self.value)

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        var v = Int32(0)
        while True:
            var key = dec.next_field()
            if key.end:
                break
            if key.field_no == 1 or key.json_name == "value":
                v = dec.read_i32()
            else:
                dec.skip()
        return Self(v)

    # -- `Proto3JsonWkt`: the bare scalar, through the codec arms ------

    def write_proto3_json(self, mut buf: List[UInt8]) raises:
        write_i64_dec(buf, Int64(self.value))

    @staticmethod
    def read_proto3_json(v: JsonValue) raises -> Self:
        var x = v.as_int64()
        if x < Int64(-2147483648) or x > Int64(2147483647):
            raise Error("WktError: Int32Value out of range: " + v.text)
        return Self(Int32(x))

    def to_proto3_json(self) -> String:
        return String(self.value)

    @staticmethod
    def is_json_string() -> Bool:
        return False

    @staticmethod
    def from_proto3_json(text: String) raises -> Self:
        return Self(Int32(_parse_int(text)))


@fieldwise_init
struct UInt32Value(Proto3JsonWkt, Copyable, Movable, ImplicitlyCopyable):
    """`google.protobuf.UInt32Value` — a boxed `uint32`."""

    var value: UInt32

    def encode[E: WireEncoder](self, mut enc: E) raises:
        enc.write_u32_field(1, "value", self.value)

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        var v = UInt32(0)
        while True:
            var key = dec.next_field()
            if key.end:
                break
            if key.field_no == 1 or key.json_name == "value":
                v = dec.read_u32()
            else:
                dec.skip()
        return Self(v)

    # -- `Proto3JsonWkt`: the bare scalar, through the codec arms ------

    def write_proto3_json(self, mut buf: List[UInt8]) raises:
        write_i64_dec(buf, Int64(self.value))

    @staticmethod
    def read_proto3_json(v: JsonValue) raises -> Self:
        var x = v.as_uint64()
        if x > UInt64(4294967295):
            raise Error("WktError: UInt32Value out of range: " + v.text)
        return Self(UInt32(x))

    def to_proto3_json(self) -> String:
        return String(self.value)

    @staticmethod
    def is_json_string() -> Bool:
        return False

    @staticmethod
    def from_proto3_json(text: String) raises -> Self:
        return Self(UInt32(_parse_uint_text(text)))


# =============================================================================
# BoolValue — boolean wrapper (JSON: true / false).
# =============================================================================


@fieldwise_init
struct BoolValue(Proto3JsonWkt, Copyable, Movable, ImplicitlyCopyable):
    """`google.protobuf.BoolValue` — a boxed `bool`."""

    var value: Bool

    def encode[E: WireEncoder](self, mut enc: E) raises:
        enc.write_bool_field(1, "value", self.value)

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        var v = False
        while True:
            var key = dec.next_field()
            if key.end:
                break
            if key.field_no == 1 or key.json_name == "value":
                v = dec.read_bool()
            else:
                dec.skip()
        return Self(v)

    # -- `Proto3JsonWkt`: the bare scalar, through the codec arms ------

    def write_proto3_json(self, mut buf: List[UInt8]) raises:
        _append_ascii(buf, self.to_proto3_json())

    @staticmethod
    def read_proto3_json(v: JsonValue) raises -> Self:
        return Self(v.as_bool())

    def to_proto3_json(self) -> String:
        return String("true") if self.value else String("false")

    @staticmethod
    def is_json_string() -> Bool:
        return False

    @staticmethod
    def from_proto3_json(text: String) raises -> Self:
        if text == "true":
            return Self(True)
        if text == "false":
            return Self(False)
        raise Error("WktError: BoolValue JSON must be true/false: " + text)


# =============================================================================
# StringValue — string wrapper (JSON: a string).
# =============================================================================


@fieldwise_init
struct StringValue(Proto3JsonWkt, Copyable, Movable):
    """`google.protobuf.StringValue` — a boxed `string`."""

    var value: String

    def encode[E: WireEncoder](self, mut enc: E) raises:
        enc.write_string_field(1, "value", self.value)

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        var v = String("")
        while True:
            var key = dec.next_field()
            if key.end:
                break
            if key.field_no == 1 or key.json_name == "value":
                v = dec.read_string()
            else:
                dec.skip()
        return Self(v)

    # -- `Proto3JsonWkt`: the bare scalar, through the codec arms ------

    def write_proto3_json(self, mut buf: List[UInt8]) raises:
        write_json_string(buf, self.value)

    @staticmethod
    def read_proto3_json(v: JsonValue) raises -> Self:
        return Self(v.as_string())

    def to_proto3_json(self) -> String:
        # The raw string content; the caller wraps + escapes as a JSON string.
        return self.value

    @staticmethod
    def is_json_string() -> Bool:
        return True

    @staticmethod
    def from_proto3_json(text: String) -> Self:
        # `text` is the already-unquoted string content.
        return Self(text)


# =============================================================================
# BytesValue — bytes wrapper (JSON: a base64 string).
# =============================================================================


@fieldwise_init
struct BytesValue(Proto3JsonWkt, Copyable, Movable):
    """`google.protobuf.BytesValue` — a boxed `bytes`."""

    var value: List[UInt8]

    def encode[E: WireEncoder](self, mut enc: E) raises:
        enc.write_bytes_field(1, "value", self.value)

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        var v = List[UInt8]()
        while True:
            var key = dec.next_field()
            if key.end:
                break
            if key.field_no == 1 or key.json_name == "value":
                v = dec.read_bytes()
            else:
                dec.skip()
        return Self(v^)

    # -- `Proto3JsonWkt`: the bare scalar, through the codec arms ------

    def write_proto3_json(self, mut buf: List[UInt8]) raises:
        write_json_string(buf, base64_encode(self.value))

    @staticmethod
    def read_proto3_json(v: JsonValue) raises -> Self:
        return Self(base64_decode(v.as_string()))

    def to_proto3_json(self) -> String:
        # proto3 JSON: bytes -> base64 string content (the caller quotes it).
        return base64_encode(self.value)

    @staticmethod
    def is_json_string() -> Bool:
        return True

    @staticmethod
    def from_proto3_json(text: String) raises -> Self:
        return Self(base64_decode(text))


# =============================================================================
# Local scalar parsers — kept self-contained (komira_wkt depends only on
# komira_serde).
# =============================================================================


def _parse_int(text: String) raises -> Int:
    """Parse a signed decimal integer."""
    var b = text.as_bytes()
    var n = len(b)
    if n == 0:
        raise Error("WktError: empty integer text")
    var idx = 0
    var negative = False
    if b[0] == 0x2D:  # '-'
        negative = True
        idx = 1
    elif b[0] == 0x2B:  # '+'
        idx = 1
    if idx >= n:
        raise Error("WktError: integer text has no digits: " + text)
    var v = 0
    while idx < n:
        var c = b[idx]
        if c < 0x30 or c > 0x39:
            raise Error("WktError: bad integer text: " + text)
        v = v * 10 + Int(c - 0x30)
        idx += 1
    return -v if negative else v


def _parse_uint_text(text: String) raises -> Int:
    """Parse an unsigned decimal integer."""
    var b = text.as_bytes()
    var n = len(b)
    if n == 0:
        raise Error("WktError: empty unsigned-integer text")
    var idx = 0
    if b[0] == 0x2B:  # tolerate a leading '+'
        idx = 1
    if idx >= n:
        raise Error("WktError: unsigned-integer text has no digits: " + text)
    var v = 0
    while idx < n:
        var c = b[idx]
        if c < 0x30 or c > 0x39:
            raise Error("WktError: bad unsigned-integer text: " + text)
        v = v * 10 + Int(c - 0x30)
        idx += 1
    return v


def _parse_f64(text: String) raises -> Float64:
    """Parse a JSON number into a Float64."""
    try:
        return atof(text)
    except:
        raise Error("WktError: bad floating-point text: " + text)


# =============================================================================
# The proto3-JSON double form, shared by DoubleValue / FloatValue.
#
# A finite value is a JSON number, written by the same formatter a plain
# `double` field uses. The three non-finite values are the spec's STRINGS
# "NaN" / "Infinity" / "-Infinity" — a JSON number cannot carry them, and
# writing `null` would turn a present wrapper into an absent one.
# =============================================================================


def _write_f64_json(mut buf: List[UInt8], v: Float64):
    if v != v:
        write_json_string(buf, String("NaN"))
    elif v > Float64(1.7976931348623157e308):
        write_json_string(buf, String("Infinity"))
    elif v < Float64(-1.7976931348623157e308):
        write_json_string(buf, String("-Infinity"))
    else:
        write_f64_dtoa(buf, v)


def _read_f64_json(v: JsonValue) raises -> Float64:
    """A JSON number, or a string holding a number or one of the spec's
    three non-finite spellings."""
    if v.kind == JSON_STRING:
        var inf = Float64(1.0e308) * Float64(10.0)
        if v.text == "NaN":
            return inf - inf
        if v.text == "Infinity":
            return inf
        if v.text == "-Infinity":
            return -inf
        return _parse_f64(v.text)
    if v.kind != JSON_NUMBER:
        raise Error("WktError: expected a JSON number for a double wrapper")
    return _parse_f64(v.text)


def _append_ascii(mut buf: List[UInt8], s: String):
    var b = s.as_bytes()
    for i in range(len(b)):
        buf.append(b[i])
