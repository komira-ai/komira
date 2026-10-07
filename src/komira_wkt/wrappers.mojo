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
# the value must be JSON-quoted. The float wrappers return the complete JSON
# value the codec writes (`0.5`, `"NaN"`), so theirs is False. Every
# numeric `from_proto3_json()` reads through `read_proto3_json`, with its
# checks. This split keeps the wrappers usable both standalone and as a
# generated message field.
# =============================================================================

from komira_proto_codec import (
    Serializable,
    Proto3JsonWkt,
    WireEncoder,
    WireDecoder,
    read_proto3_json_f32,
    read_proto3_json_f64,
    write_proto3_json_f32,
    write_proto3_json_f64,
)
from komira_json import (
    JsonValue,
    JSON_STRING,
    write_json_string,
    write_i64_dec,
    parse_json_value,
)
from komira_encoding import base64_encode, base64_decode


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
        write_proto3_json_f64(buf, self.value)

    @staticmethod
    def read_proto3_json(v: JsonValue) raises -> Self:
        return Self(read_proto3_json_f64(v))

    def to_proto3_json(self) -> String:
        return _f64_json_text(self.value)

    @staticmethod
    def is_json_string() -> Bool:
        return False

    @staticmethod
    def from_proto3_json(text: String) raises -> Self:
        return Self.read_proto3_json(parse_json_value(text))


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
        write_proto3_json_f32(buf, self.value)

    @staticmethod
    def read_proto3_json(v: JsonValue) raises -> Self:
        return Self(read_proto3_json_f32(v))

    def to_proto3_json(self) -> String:
        var buf = List[UInt8]()
        write_proto3_json_f32(buf, self.value)
        return String(unsafe_from_utf8=Span(buf))

    @staticmethod
    def is_json_string() -> Bool:
        return False

    @staticmethod
    def from_proto3_json(text: String) raises -> Self:
        return Self.read_proto3_json(parse_json_value(text))


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
        return Self.read_proto3_json(_json_string(text))


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
        return Self.read_proto3_json(_json_string(text))


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
        return Self.read_proto3_json(_json_string(text))


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
        return Self.read_proto3_json(_json_string(text))


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

    def __init__(out self, *, copy: Self):
        """Deep copy: each field via its own `.copy()` (see `structpb.mojo`)."""
        self.value = copy.value.copy()

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

    def __init__(out self, *, copy: Self):
        """Deep copy: each field via its own `.copy()` (see `structpb.mojo`)."""
        self.value = copy.value.copy()

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
# The string helpers' readers. `from_proto3_json(text)` on a numeric wrapper
# reads through the same `read_proto3_json` the codec arms call, so the
# string helpers and the codec accept and refuse exactly the same values
# (Int64 / UInt64 bounds, the 32-bit range checks). The integer wrappers
# take the unquoted text, so it is handed over as a JSON string value, which
# `as_int64` / `as_uint64` read as the decimal text proto3 JSON carries.
# =============================================================================


def _json_string(text: String) -> JsonValue:
    var v = JsonValue()
    v.kind = JSON_STRING
    v.text = text
    return v^


def _f64_json_text(v: Float64) -> String:
    """The complete JSON value `write_proto3_json` writes for a double: a
    shortest-form number, or the quoted string "NaN" / "Infinity" /
    "-Infinity" (which is why the float wrappers' `is_json_string()` is
    False: their text is already a complete JSON value)."""
    var buf = List[UInt8]()
    write_proto3_json_f64(buf, v)
    return String(unsafe_from_utf8=Span(buf))


# The proto3-JSON double form, used by DoubleValue, is the codec's
# (`write_proto3_json_f64` / `read_proto3_json_f64`), the one a plain
# `double` field uses; FloatValue uses the codec's float32 form
# (`write_proto3_json_f32` / `read_proto3_json_f32`).


def _append_ascii(mut buf: List[UInt8], s: String):
    var b = s.as_bytes()
    for i in range(len(b)):
        buf.append(b[i])
