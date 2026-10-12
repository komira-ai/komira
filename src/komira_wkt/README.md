# komira_wkt

The protobuf well-known types as Mojo structs: `Timestamp`, `Duration`,
`Empty`, the scalar wrappers (`Int32Value`, `StringValue`, `BytesValue`, ...),
`FieldMask`, `Struct` / `Value` / `ListValue`, and an opaque `Any`. A
generated client imports them when a `.proto` message has a
`google.protobuf.*` field.

Each type encodes as an ordinary message on the protobuf binary wire, and
has the special proto3 JSON form the protobuf JSON mapping gives it: a
`Timestamp` is an RFC 3339 string, a `Duration` is `"<seconds>s"`, a wrapper
is its bare scalar, a `FieldMask` is one comma-joined lowerCamelCase string,
and a `Struct` is the JSON object it holds. `to_proto3_json()` and
`from_proto3_json()` give that form as text; `encode_json` and `decode_json`
of `komira_proto_codec` use it for a well-known type wherever one appears in
a message. The structs hold owned values only.

Every example below runs as a test when the package is built, so it cannot
go stale.

## Timestamp and Duration

```mojo
from komira_wkt import Duration, Timestamp
from std.testing import assert_equal

var ts = Timestamp(Int64(1788256820), Int32(21000000))
assert_equal(ts.to_proto3_json(), "2026-09-01T10:00:20.021Z")

var parsed = Timestamp.from_proto3_json("2026-10-01T00:00:00Z")
assert_equal(parsed.seconds, Int64(1790812800))
assert_equal(parsed.nanos, Int32(0))

# An offset is accepted on input and applied; output is always UTC.
var offset = Timestamp.from_proto3_json("2026-10-01T01:00:00+01:00")
assert_equal(offset.to_proto3_json(), "2026-10-01T00:00:00Z")

assert_equal(Duration(Int64(1), Int32(340012)).to_proto3_json(), "1.000340012s")
assert_equal(Duration.from_proto3_json("90.5s").nanos, Int32(500000000))
```

Text that is not a timestamp is refused, naming the type:

```mojo
from komira_wkt import Timestamp
from std.testing import assert_raises

with assert_raises(contains="Timestamp"):
    _ = Timestamp.from_proto3_json("yesterday")
```

## FieldMask, Struct and the wrappers

A `FieldMask` holds snake_case paths on the wire and writes lowerCamelCase
in JSON. A `Struct` keeps its keys in insertion order.

```mojo
from komira_wkt import FieldMask, Int64Value, Struct, Value
from std.testing import assert_equal, assert_true

var paths: List[String] = ["user_id", "display_name"]
var mask = FieldMask(paths^)
assert_equal(mask.to_proto3_json(), "userId,displayName")
assert_equal(FieldMask.from_proto3_json("userId,displayName").paths[1], "display_name")

var s = Struct.new()
s.put("name", Value.string("example"))
s.put("active", Value.boolean(True))
s.put("count", Value.number(3.0))
assert_equal(s.to_proto3_json(), '{"name":"example","active":true,"count":3}')

# A 64-bit integer wrapper is a JSON string, as the mapping requires;
# to_proto3_json gives the text and the codec adds the quotes.
assert_equal(Int64Value(Int64(42)).to_proto3_json(), "42")
assert_true(Int64Value.is_json_string())
```

## Binary round trip

Every type is a `komira_proto_codec` `Serializable` message.

```mojo
from komira_proto_codec import decode_proto, encode_proto
from komira_wkt import Duration
from std.testing import assert_equal

var d = Duration(Int64(-12), Int32(0))
var bytes = encode_proto[Duration](d)
var back = decode_proto[Duration](bytes^)
assert_equal(back.seconds, Int64(-12))
```

## A well-known type inside a message

A message with a `Timestamp` field writes it with the ordinary message arm;
on the JSON backend the codec gives the field its RFC 3339 form.

```mojo module
from komira_proto_codec import Serializable, WireDecoder, WireEncoder, decode_json, encode_json
from komira_wkt import Timestamp
from std.testing import assert_equal


@fieldwise_init
struct Event(Serializable, Copyable, Movable):
    var name: String
    var at: Optional[Timestamp]

    def encode[E: WireEncoder](self, mut enc: E) raises:
        if self.name != "":
            enc.write_string_field(1, "name", self.name)
        if self.at:
            enc.write_message_field[Timestamp](2, "at", self.at.value())

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        dec.expect_fields("Event", "name,at")
        var name = String("")
        var at = Optional[Timestamp](None)
        while True:
            var key = dec.next_field()
            if key.end:
                break
            if key.field_no == 1 or key.json_name == "name":
                name = dec.read_string()
            elif key.field_no == 2 or key.json_name == "at":
                at = dec.read_message[Timestamp]()
            else:
                dec.skip()
        return Self(name^, at^)


def main() raises:
    var e = Event("deploy", Timestamp(Int64(1790812800), Int32(0)))
    var doc = encode_json[Event](e)
    assert_equal(doc, '{"name":"deploy","at":"2026-10-01T00:00:00Z"}')
    assert_equal(decode_json[Event](doc).at.value().seconds, Int64(1790812800))
```
