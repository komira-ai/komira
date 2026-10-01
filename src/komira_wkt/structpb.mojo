# =============================================================================
# structpb.mojo — google.protobuf.Struct / Value / ListValue / NullValue.
# =============================================================================
#
#   enum NullValue { NULL_VALUE = 0; }
#   message Value {
#     oneof kind {
#       NullValue  null_value   = 1;
#       double     number_value = 2;
#       string     string_value = 3;
#       bool       bool_value   = 4;
#       Struct     struct_value = 5;
#       ListValue  list_value   = 6;
#     }
#   }
#   message Struct    { map<string, Value> fields = 1; }
#   message ListValue { repeated Value values = 1; }
#
# This triad models an arbitrary JSON value as a protobuf message — `Value`
# is the JSON-value sum type, `Struct` a JSON object, `ListValue` a JSON array.
#
# -- The recursion break ------------------------------------------------------
# `Value` -> `Struct` -> `Value` and `Value` -> `ListValue` -> `Value` are
# size cycles. A struct cannot inline itself. `Serializable` requires
# `Copyable`, so `OwnedPointer` (single-owner, non-`Copyable`) is NOT an
# option (the generated code uses the `List[T]` substitute for exactly this
# reason). So the two recursive `Value` fields — `struct_value` and
# `list_value` — are stored as `List[Struct]` / `List[ListValue]` holding
# 0-or-1 elements. A `List` is a finitely-sized pointer+len+cap regardless
# of element type — it breaks the cycle and keeps the struct trivially
# `Copyable`.
#
# -- The `Value` oneof --------------------------------------------------------
# `Value` is a 6-arm oneof. It is modelled with an `Int` discriminant `kind`
# plus one storage field per arm (the same shape the code generator emits
# for a proto `oneof`). Exactly one arm is set; the discriminant says which.
#
# -- The canonical-JSON form --------------------------------------------------
# `Value` / `Struct` / `ListValue` ARE the JSON value they model — their
# `to_proto3_json()` emits the literal JSON (`null`, a number, a quoted
# string, `true`/`false`, a `{...}` object, a `[...]` array). This module
# carries a small self-contained JSON value-emitter + parser for that path so
# `komira_wkt` keeps its single dependency on `komira_serde`.
# =============================================================================

from komira_serde import Serializable, WireEncoder, WireDecoder
from komira_serde import JsonValue, parse_json_value
from komira_serde import (
    JSON_NULL,
    JSON_BOOL,
    JSON_NUMBER,
    JSON_STRING,
    JSON_ARRAY,
    JSON_OBJECT,
)


# The `Value.kind` discriminant — 0 = unset, then one per oneof arm.
comptime VALUE_KIND_UNSET: Int = 0
comptime VALUE_KIND_NULL: Int = 1
comptime VALUE_KIND_NUMBER: Int = 2
comptime VALUE_KIND_STRING: Int = 3
comptime VALUE_KIND_BOOL: Int = 4
comptime VALUE_KIND_STRUCT: Int = 5
comptime VALUE_KIND_LIST: Int = 6


# =============================================================================
# google.protobuf.NullValue — the one-member enum.
# =============================================================================


@fieldwise_init
struct NullValue(Copyable, Movable, ImplicitlyCopyable):
    """`google.protobuf.NullValue` — a one-member enum (`NULL_VALUE = 0`)."""

    var value: Int

    comptime NULL_VALUE: Int = 0

    def __eq__(self, other: Self) -> Bool:
        return self.value == other.value

    def __ne__(self, other: Self) -> Bool:
        return self.value != other.value


# The canonical `NullValue` constant.
comptime NULL_VALUE = NullValue(0)


# =============================================================================
# google.protobuf.Value — the JSON-value sum type.
# =============================================================================


@fieldwise_init
struct Value(Serializable, Copyable, Movable):
    """`google.protobuf.Value` — a dynamically-typed JSON value.

    Exactly one arm is set; `kind` is the discriminant (`VALUE_KIND_*`).
    The two recursive arms (`struct_value`, `list_value`) are stored as a
    0-or-1 `List` to break the message-size cycle (see the module header)."""

    var kind: Int
    var number_value: Float64
    var string_value: String
    var bool_value: Bool
    var struct_value: List[Struct]
    var list_value: List[ListValue]

    # -- constructors -----------------------------------------------------

    @staticmethod
    def null() -> Self:
        """A `Value` holding JSON `null`."""
        return Self(
            VALUE_KIND_NULL, Float64(0.0), String(""), False,
            List[Struct](), List[ListValue](),
        )

    @staticmethod
    def number(v: Float64) -> Self:
        """A `Value` holding a JSON number."""
        return Self(
            VALUE_KIND_NUMBER, v, String(""), False,
            List[Struct](), List[ListValue](),
        )

    @staticmethod
    def string(v: String) -> Self:
        """A `Value` holding a JSON string."""
        return Self(
            VALUE_KIND_STRING, Float64(0.0), v, False,
            List[Struct](), List[ListValue](),
        )

    @staticmethod
    def boolean(v: Bool) -> Self:
        """A `Value` holding a JSON boolean."""
        return Self(
            VALUE_KIND_BOOL, Float64(0.0), String(""), v,
            List[Struct](), List[ListValue](),
        )

    @staticmethod
    def struct_(var v: Struct) -> Self:
        """A `Value` holding a JSON object (`Struct`)."""
        var box = List[Struct]()
        box.append(v^)
        return Self(
            VALUE_KIND_STRUCT, Float64(0.0), String(""), False,
            box^, List[ListValue](),
        )

    @staticmethod
    def list(var v: ListValue) -> Self:
        """A `Value` holding a JSON array (`ListValue`)."""
        var box = List[ListValue]()
        box.append(v^)
        return Self(
            VALUE_KIND_LIST, Float64(0.0), String(""), False,
            List[Struct](), box^,
        )

    # -- the `Serializable` protobuf-binary surface -----------------------

    def encode[E: WireEncoder](self, mut enc: E) raises:
        """Encode the single set oneof arm."""
        if self.kind == VALUE_KIND_NULL:
            enc.write_i32_field(1, "nullValue", Int32(0))
        elif self.kind == VALUE_KIND_NUMBER:
            enc.write_f64_field(2, "numberValue", self.number_value)
        elif self.kind == VALUE_KIND_STRING:
            enc.write_string_field(3, "stringValue", self.string_value)
        elif self.kind == VALUE_KIND_BOOL:
            enc.write_bool_field(4, "boolValue", self.bool_value)
        elif self.kind == VALUE_KIND_STRUCT:
            for i in range(len(self.struct_value)):
                enc.write_message_field[Struct](
                    5, "structValue", self.struct_value[i]
                )
        elif self.kind == VALUE_KIND_LIST:
            for i in range(len(self.list_value)):
                enc.write_message_field[ListValue](
                    6, "listValue", self.list_value[i]
                )

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        """Decode the single set oneof arm."""
        var kind = VALUE_KIND_UNSET
        var number_value = Float64(0.0)
        var string_value = String("")
        var bool_value = False
        var struct_value = List[Struct]()
        var list_value = List[ListValue]()
        while True:
            var key = dec.next_field()
            if key.end:
                break
            if key.field_no == 1 or key.json_name == "nullValue":
                _ = dec.read_i32()
                kind = VALUE_KIND_NULL
            elif key.field_no == 2 or key.json_name == "numberValue":
                number_value = dec.read_f64()
                kind = VALUE_KIND_NUMBER
            elif key.field_no == 3 or key.json_name == "stringValue":
                string_value = dec.read_string()
                kind = VALUE_KIND_STRING
            elif key.field_no == 4 or key.json_name == "boolValue":
                bool_value = dec.read_bool()
                kind = VALUE_KIND_BOOL
            elif key.field_no == 5 or key.json_name == "structValue":
                struct_value = List[Struct]()
                struct_value.append(dec.read_message[Struct]())
                kind = VALUE_KIND_STRUCT
            elif key.field_no == 6 or key.json_name == "listValue":
                list_value = List[ListValue]()
                list_value.append(dec.read_message[ListValue]())
                kind = VALUE_KIND_LIST
            else:
                dec.skip()
        return Self(
            kind, number_value, string_value^, bool_value,
            struct_value^, list_value^,
        )

    # -- the canonical-JSON surface ---------------------------------------

    def to_proto3_json(self) raises -> String:
        """The literal JSON value this `Value` models."""
        if self.kind == VALUE_KIND_NULL or self.kind == VALUE_KIND_UNSET:
            return String("null")
        elif self.kind == VALUE_KIND_NUMBER:
            return String(self.number_value)
        elif self.kind == VALUE_KIND_STRING:
            return _json_quote(self.string_value)
        elif self.kind == VALUE_KIND_BOOL:
            return String("true") if self.bool_value else String("false")
        elif self.kind == VALUE_KIND_STRUCT:
            if len(self.struct_value) == 0:
                return String("{}")
            return self.struct_value[0].to_proto3_json()
        else:  # VALUE_KIND_LIST
            if len(self.list_value) == 0:
                return String("[]")
            return self.list_value[0].to_proto3_json()

    @staticmethod
    def from_proto3_json(text: String) raises -> Self:
        """Parse any JSON value into a `Value`."""
        return _value_from_json(parse_json_value(text))


# =============================================================================
# google.protobuf.Struct — a JSON object.
# =============================================================================


@fieldwise_init
struct Struct(Serializable, Copyable, Movable):
    """`google.protobuf.Struct` — a JSON object: ordered `(key, Value)` pairs.

    Stored as parallel `keys` / `values` lists (not a `Dict`) to keep field
    iteration in deterministic insertion order — the proto3-JSON object form
    is order-sensitive for byte-stable golden diffs."""

    var keys: List[String]
    var values: List[Value]

    @staticmethod
    def new() -> Self:
        """An empty `Struct` (`{}`)."""
        return Self(List[String](), List[Value]())

    def put(mut self, key: String, var value: Value):
        """Append a `(key, value)` pair."""
        self.keys.append(key)
        self.values.append(value^)

    # -- the `Serializable` protobuf-binary surface -----------------------
    #
    # `map<string, Value> fields = 1` — on the wire this is a repeated
    # length-delimited entry sub-message per pair (key field 1 + value
    # field 2). `Struct` is a fixed, known WKT shape, so its entry codec is
    # written out explicitly here as the nested `_StructEntry` message.

    def encode[E: WireEncoder](self, mut enc: E) raises:
        """Encode the `map<string, Value>` field as repeated entry messages."""
        for i in range(len(self.keys)):
            var entry = _StructEntry(self.keys[i], self.values[i].copy())
            enc.write_message_field[_StructEntry](1, "fields", entry)

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        """Decode the `map<string, Value>` field."""
        var keys = List[String]()
        var values = List[Value]()
        while True:
            var key = dec.next_field()
            if key.end:
                break
            if key.field_no == 1 or key.json_name == "fields":
                var entry = dec.read_message[_StructEntry]()
                # Copy both fields out — a partial-move (`entry.key^`) of a
                # field from the middle of a struct with a synthesized
                # destructor is not allowed.
                keys.append(entry.key)
                values.append(entry.value.copy())
            else:
                dec.skip()
        return Self(keys^, values^)

    # -- the canonical-JSON surface ---------------------------------------

    def to_proto3_json(self) raises -> String:
        """The JSON object form `{"k": v, ...}`."""
        var out = String("{")
        for i in range(len(self.keys)):
            if i > 0:
                out += ","
            out += _json_quote(self.keys[i])
            out += ":"
            out += self.values[i].to_proto3_json()
        out += "}"
        return out

    @staticmethod
    def from_proto3_json(text: String) raises -> Self:
        """Parse a JSON object into a `Struct`."""
        var jv = parse_json_value(text)
        if not jv.is_object():
            raise Error("WktError: Struct JSON is not an object: " + text)
        return _struct_from_json(jv)


    # An explicit destructor breaks the non-co-inductive `Deinitable`
    # check on this struct's recursive self-reference. Field destructors
    # still run; ownership is unchanged.
    def __deinit__(deinit self):
        pass


# =============================================================================
# google.protobuf.ListValue — a JSON array.
# =============================================================================


@fieldwise_init
struct ListValue(Serializable, Copyable, Movable):
    """`google.protobuf.ListValue` — a JSON array: `repeated Value values`."""

    var values: List[Value]

    @staticmethod
    def new() -> Self:
        """An empty `ListValue` (`[]`)."""
        return Self(List[Value]())

    def add(mut self, var value: Value):
        """Append a `Value` to the array."""
        self.values.append(value^)

    # -- the `Serializable` protobuf-binary surface -----------------------

    def encode[E: WireEncoder](self, mut enc: E) raises:
        """Encode the `repeated Value values` field."""
        for i in range(len(self.values)):
            enc.write_message_field[Value](1, "values", self.values[i])

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        """Decode the `repeated Value values` field."""
        var values = List[Value]()
        while True:
            var key = dec.next_field()
            if key.end:
                break
            if key.field_no == 1 or key.json_name == "values":
                values.append(dec.read_message[Value]())
            else:
                dec.skip()
        return Self(values^)

    # -- the canonical-JSON surface ---------------------------------------

    def to_proto3_json(self) raises -> String:
        """The JSON array form `[v, ...]`."""
        var out = String("[")
        for i in range(len(self.values)):
            if i > 0:
                out += ","
            out += self.values[i].to_proto3_json()
        out += "]"
        return out

    @staticmethod
    def from_proto3_json(text: String) raises -> Self:
        """Parse a JSON array into a `ListValue`."""
        var jv = parse_json_value(text)
        if not jv.is_array():
            raise Error("WktError: ListValue JSON is not an array: " + text)
        return _list_from_json(jv)


    # An explicit destructor breaks the non-co-inductive `Deinitable`
    # check on this struct's recursive self-reference. Field destructors
    # still run; ownership is unchanged.
    def __deinit__(deinit self):
        pass


# =============================================================================
# _StructEntry — the synthetic `map<string,Value>` entry sub-message.
#
# protobuf encodes a `map<K,V>` field as a repeated length-delimited message
# with `key` = field 1 and `value` = field 2. This is that entry message for
# `Struct.fields`; it is module-private (an implementation detail of the
# `Struct` wire codec, never part of the public WKT surface).
# =============================================================================


@fieldwise_init
struct _StructEntry(Serializable, Copyable, Movable):
    """The `map<string, Value>` wire entry for `Struct.fields`."""

    var key: String
    var value: Value

    def encode[E: WireEncoder](self, mut enc: E) raises:
        enc.write_string_field(1, "key", self.key)
        enc.write_message_field[Value](2, "value", self.value)

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        var key = String("")
        var value = Value.null()
        while True:
            var fk = dec.next_field()
            if fk.end:
                break
            if fk.field_no == 1 or fk.json_name == "key":
                key = dec.read_string()
            elif fk.field_no == 2 or fk.json_name == "value":
                value = dec.read_message[Value]()
            else:
                dec.skip()
        return Self(key^, value^)


# =============================================================================
# JSON <-> WKT conversion (the canonical-JSON parse side).
# =============================================================================


def _value_from_json(jv: JsonValue) raises -> Value:
    """Convert a parsed `JsonValue` into a WKT `Value`."""
    var kind = jv.kind
    if kind == JSON_NULL:
        return Value.null()
    elif kind == JSON_BOOL:
        return Value.boolean(jv.as_bool())
    elif kind == JSON_NUMBER:
        return Value.number(jv.as_float64())
    elif kind == JSON_STRING:
        return Value.string(jv.as_string())
    elif kind == JSON_OBJECT:
        return Value.struct_(_struct_from_json(jv))
    elif kind == JSON_ARRAY:
        return Value.list(_list_from_json(jv))
    else:
        raise Error("WktError: unknown JSON kind in Value conversion")


def _struct_from_json(jv: JsonValue) raises -> Struct:
    """Convert a JSON-object `JsonValue` into a WKT `Struct`."""
    var s = Struct.new()
    for i in range(len(jv.obj_keys)):
        s.put(jv.obj_keys[i], _value_from_json(jv.children[i].copy()))
    return s^


def _list_from_json(jv: JsonValue) raises -> ListValue:
    """Convert a JSON-array `JsonValue` into a WKT `ListValue`."""
    var lv = ListValue.new()
    for i in range(len(jv.children)):
        lv.add(_value_from_json(jv.children[i].copy()))
    return lv^


def _json_quote(s: String) -> String:
    """Wrap `s` as a JSON string with RFC-8259 §7 escaping. Iterates raw
    UTF-8 bytes (multibyte-safe — a continuation byte >= 0x80 passes
    through verbatim)."""
    var out = List[UInt8]()
    out.append(0x22)  # '"'
    var bytes = s.as_bytes()
    for i in range(len(bytes)):
        var b = bytes[i]
        if b == 0x22:  # '"'
            out.append(0x5C)
            out.append(0x22)
        elif b == 0x5C:  # backslash
            out.append(0x5C)
            out.append(0x5C)
        elif b == 0x0A:  # '\n'
            out.append(0x5C)
            out.append(0x6E)
        elif b == 0x0D:  # '\r'
            out.append(0x5C)
            out.append(0x72)
        elif b == 0x09:  # '\t'
            out.append(0x5C)
            out.append(0x74)
        elif b == 0x08:  # '\b'
            out.append(0x5C)
            out.append(0x62)
        elif b == 0x0C:  # '\f'
            out.append(0x5C)
            out.append(0x66)
        elif b < 0x20:
            out.append(0x5C)
            out.append(0x75)
            out.append(0x30)
            out.append(0x30)
            out.append(_hex_digit((b >> 4) & 0xF))
            out.append(_hex_digit(b & 0xF))
        else:
            out.append(b)
    out.append(0x22)  # '"'
    return String(unsafe_from_utf8=Span(out))


@always_inline
def _hex_digit(nibble: UInt8) -> UInt8:
    """A 0..15 nibble as its lowercase-hex ASCII byte."""
    if nibble < 10:
        return 0x30 + nibble
    return 0x61 + (nibble - 10)
