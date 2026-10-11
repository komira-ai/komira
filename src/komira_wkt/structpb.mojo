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
# of element type — it breaks the cycle and keeps the struct `Copyable`.
#
# -- Copy constructors --------------------------------------------------------
# `Value`, `Struct`, `ListValue` and `_StructEntry` each define an explicit
# `def __init__(out self, *, copy: Self)` that copies every field with its
# own `.copy()` (the two boxes copy through `Struct` and `ListValue`'s own
# constructors). A synthesized copy constructor has been reported to be
# treated as trivial for some layouts of a struct with an explicit
# `__deinit__` (which `Struct` and `ListValue` need, see their
# destructors), letting `List.copy()` memcpy elements that own heap
# buffers. That was not reproduced for these types; the explicit
# constructors make the deep copy explicit regardless. The other
# heap-owning well-known types (`StringValue`, `BytesValue`, `FieldMask`,
# `Any`) define one for the same reason.
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
# `komira_wkt` takes its JSON value and parser from `komira_json`.
# =============================================================================

from komira_proto_codec import (
    ProtoNullValueEnum,
    Serializable,
    Proto3JsonWkt,
    WireEncoder,
    WireDecoder,
    read_proto3_json_f64,
)
from komira_json import JsonValue, parse_json_value
from komira_json import write_json_string, write_i64_dec, write_f64_dtoa
from komira_json import (
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
struct NullValue(ProtoNullValueEnum, Copyable, Movable, ImplicitlyCopyable):
    """`google.protobuf.NullValue` — a one-member enum (`NULL_VALUE = 0`).

    A `ProtoEnum`, so a generated message can hold a field of it (Firestore's
    `Value.null_value`); a `ProtoNullValueEnum`, so komira_proto_codec's JSON
    backend writes that field as `null` and reads `null` back as
    `NULL_VALUE`, as the protobuf JSON mapping specifies."""

    var value: Int

    comptime NULL_VALUE: Int = 0

    def number(self) -> Int:
        return self.value

    def json_name(self) -> String:
        """`NULL_VALUE` for 0; any other number's decimal text, as a
        generated enum gives for an undeclared value."""
        if self.value == 0:
            return String("NULL_VALUE")
        return String(self.value)

    @staticmethod
    def from_number(n: Int) -> Self:
        return Self(n)

    @staticmethod
    def from_json_name(s: String) -> Self:
        return Self(0)

    @staticmethod
    def is_known_json_name(s: String) -> Bool:
        return s == "NULL_VALUE"

    @staticmethod
    def known_json_names() -> String:
        return String("NULL_VALUE")

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
struct Value(Proto3JsonWkt, Copyable, Movable):
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

    def __init__(out self, *, copy: Self):
        """Deep copy: each field via its own `.copy()` (module header)."""
        self.kind = copy.kind
        self.number_value = copy.number_value
        self.string_value = copy.string_value.copy()
        self.bool_value = copy.bool_value
        self.struct_value = copy.struct_value.copy()
        self.list_value = copy.list_value.copy()

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
        var buf = List[UInt8]()
        self.write_proto3_json(buf)
        return String(unsafe_from_utf8=Span(buf))

    @staticmethod
    def from_proto3_json(text: String) raises -> Self:
        """Parse any JSON value into a `Value`."""
        return _value_from_json(parse_json_value(text))

    # -- `Proto3JsonWkt`: the codec arms call these ----------------------

    def write_proto3_json(self, mut buf: List[UInt8]) raises:
        """Append the literal JSON value. REFUSES a NaN / Infinity number:
        the spec says a `Value` holding one cannot be serialized, and
        JSON has no spelling for it."""
        if self.kind == VALUE_KIND_UNSET:
            # No arm set is not a JSON value; the reference implementations
            # refuse it ("no kind set") rather than guess `null`.
            raise Error("WktError: google.protobuf.Value has no kind set")
        if self.kind == VALUE_KIND_NULL:
            _append_ascii(buf, "null")
        elif self.kind == VALUE_KIND_NUMBER:
            _write_number(buf, self.number_value)
        elif self.kind == VALUE_KIND_STRING:
            write_json_string(buf, self.string_value)
        elif self.kind == VALUE_KIND_BOOL:
            _append_ascii(buf, "true" if self.bool_value else "false")
        elif self.kind == VALUE_KIND_STRUCT:
            if len(self.struct_value) == 0:
                _append_ascii(buf, "{}")
            else:
                self.struct_value[0].write_proto3_json(buf)
        else:  # VALUE_KIND_LIST
            if len(self.list_value) == 0:
                _append_ascii(buf, "[]")
            else:
                self.list_value[0].write_proto3_json(buf)

    @staticmethod
    def read_proto3_json(v: JsonValue) raises -> Self:
        return _value_from_json(v)


# =============================================================================
# google.protobuf.Struct — a JSON object.
# =============================================================================


@fieldwise_init
struct Struct(Proto3JsonWkt, Copyable, Movable):
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

    def __init__(out self, *, copy: Self):
        """Deep copy: each field via its own `.copy()` (module header)."""
        self.keys = copy.keys.copy()
        self.values = copy.values.copy()

    def put(mut self, key: String, var value: Value):
        """Set `key` to `value`. `Struct.fields` is a `map<string, Value>`,
        so a key already present is REPLACED in place (last write wins, and
        the key keeps its first position); a new key is appended."""
        for i in range(len(self.keys)):
            if self.keys[i] == key:
                self.values[i] = value^
                return
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
        """Decode the `map<string, Value>` field. A key that repeats on the
        wire replaces the earlier entry (last write wins), as `put` and the
        JSON reader do and as protobuf map semantics require.

        On the binary wire each `fields` occurrence is one entry message.
        In the proto3-JSON message form the one `fields` key holds the
        whole map as a JSON object (member name = map key, member value =
        a `Value` in its canonical JSON form), read in document order."""
        var out = Self.new()
        while True:
            var key = dec.next_field()
            if key.end:
                break
            if key.field_no == 1:
                var entry = dec.read_message[_StructEntry]()
                # Copy both fields out — a partial-move (`entry.key^`) of a
                # field from the middle of a struct with a synthesized
                # destructor is not allowed.
                out.put(entry.key, entry.value.copy())
            elif key.json_name == "fields":
                # `Dict` iterates in insertion order, and a repeated member
                # keeps its first position with the last value, as `put`.
                var members = Dict[String, Value]()
                dec.read_into_string_message_map[Value](members)
                for item in members.items():
                    out.put(item.key, item.value.copy())
            else:
                dec.skip()
        return out^

    # -- the canonical-JSON surface ---------------------------------------

    def to_proto3_json(self) raises -> String:
        """The JSON object form `{"k": v, ...}`."""
        var buf = List[UInt8]()
        self.write_proto3_json(buf)
        return String(unsafe_from_utf8=Span(buf))

    @staticmethod
    def from_proto3_json(text: String) raises -> Self:
        """Parse a JSON object into a `Struct`."""
        var jv = parse_json_value(text)
        if not jv.is_object():
            raise Error("WktError: Struct JSON is not an object: " + text)
        return _struct_from_json(jv)

    # -- `Proto3JsonWkt`: the codec arms call these ----------------------

    def write_proto3_json(self, mut buf: List[UInt8]) raises:
        buf.append(0x7B)  # '{'
        for i in range(len(self.keys)):
            if i > 0:
                buf.append(0x2C)  # ','
            write_json_string(buf, self.keys[i])
            buf.append(0x3A)  # ':'
            self.values[i].write_proto3_json(buf)
        buf.append(0x7D)  # '}'

    @staticmethod
    def read_proto3_json(v: JsonValue) raises -> Self:
        """A free-form JSON object, every member kept (a real document
        decodes to a POPULATED Struct)."""
        if not v.is_object():
            raise Error("WktError: Struct JSON must be an object")
        return _struct_from_json(v)


    # An explicit destructor breaks the non-co-inductive `Deinitable`
    # check on this struct's recursive self-reference. Field destructors
    # still run; ownership is unchanged.
    def __deinit__(deinit self):
        pass


# =============================================================================
# google.protobuf.ListValue — a JSON array.
# =============================================================================


@fieldwise_init
struct ListValue(Proto3JsonWkt, Copyable, Movable):
    """`google.protobuf.ListValue` — a JSON array: `repeated Value values`."""

    var values: List[Value]

    @staticmethod
    def new() -> Self:
        """An empty `ListValue` (`[]`)."""
        return Self(List[Value]())

    def __init__(out self, *, copy: Self):
        """Deep copy: each field via its own `.copy()` (module header)."""
        self.values = copy.values.copy()

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
        """Decode the `repeated Value values` field: one element per
        occurrence on the binary wire, the whole JSON array under the one
        `values` key in the proto3-JSON message form (each element a
        `Value` in its canonical JSON form)."""
        var values = List[Value]()
        while True:
            var key = dec.next_field()
            if key.end:
                break
            if key.field_no == 1 or key.json_name == "values":
                dec.read_into_repeated_message[Value](values)
            else:
                dec.skip()
        return Self(values^)

    # -- the canonical-JSON surface ---------------------------------------

    def to_proto3_json(self) raises -> String:
        """The JSON array form `[v, ...]`."""
        var buf = List[UInt8]()
        self.write_proto3_json(buf)
        return String(unsafe_from_utf8=Span(buf))

    @staticmethod
    def from_proto3_json(text: String) raises -> Self:
        """Parse a JSON array into a `ListValue`."""
        var jv = parse_json_value(text)
        if not jv.is_array():
            raise Error("WktError: ListValue JSON is not an array: " + text)
        return _list_from_json(jv)

    # -- `Proto3JsonWkt`: the codec arms call these ----------------------

    def write_proto3_json(self, mut buf: List[UInt8]) raises:
        buf.append(0x5B)  # '['
        for i in range(len(self.values)):
            if i > 0:
                buf.append(0x2C)  # ','
            self.values[i].write_proto3_json(buf)
        buf.append(0x5D)  # ']'

    @staticmethod
    def read_proto3_json(v: JsonValue) raises -> Self:
        if not v.is_array():
            raise Error("WktError: ListValue JSON must be an array")
        return _list_from_json(v)


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

    def __init__(out self, *, copy: Self):
        """Deep copy: each field via its own `.copy()` (module header)."""
        self.key = copy.key.copy()
        self.value = copy.value.copy()

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
        # Correctly rounded at any length; a number past the double range
        # is refused here, so a decoded Value never holds an infinity that
        # `_write_number` would refuse to write.
        return Value.number(read_proto3_json_f64(jv))
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


def _write_number(mut buf: List[UInt8], v: Float64) raises:
    """A `Value` number as JSON. REFUSES NaN / +-Infinity (the spec: a
    `Value` holding one cannot be serialized). An integral value below 2^53
    renders WITHOUT a fraction (`42`, not `42.0`) — what the reference
    implementations emit, so a free-form payload re-encodes byte-identically
    to the document it was read from. `-0.0` keeps its sign via the general
    formatter."""
    if v != v:
        raise Error("WktError: a Value number cannot be NaN")
    if v > Float64(1.7976931348623157e308) or v < Float64(
        -1.7976931348623157e308
    ):
        raise Error("WktError: a Value number cannot be Infinity")
    var limit = Float64(9007199254740992.0)  # 2^53
    if v > -limit and v < limit and v != Float64(0.0):
        var i = Int64(v)
        if Float64(i) == v:
            write_i64_dec(buf, i)
            return
    if v == Float64(0.0) and Float64(1.0) / v > Float64(0.0):
        buf.append(0x30)  # '0' (+0.0; -0.0 falls through to keep its sign)
        return
    write_f64_dtoa(buf, v)


def _append_ascii(mut buf: List[UInt8], s: StringSlice):
    var b = s.as_bytes()
    for i in range(len(b)):
        buf.append(b[i])
