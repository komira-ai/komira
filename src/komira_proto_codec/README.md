# komira_proto_codec

One description of a protobuf message, two encodings. A message type conforms
to `Serializable` by writing its fields once in `encode` and reading them once
in `decode`, and then `encode_proto` / `decode_proto` give the protobuf binary
form and `encode_json` / `decode_json` the proto3 canonical JSON form. The
format is chosen at compile time, so there is no runtime branching or dynamic
dispatch. Generated message types conform already; a hand-written one, as
below, works the same way. JSON decoding is strict: a key that is not a field
of the message is refused, naming it and where it is; `decode_json_lenient`
ignores unknown keys instead, for documents written by a newer version of the
schema.

## Examples

A message with two fields, `string name = 1; int64 id = 2;`, round-tripped
through the protobuf binary form:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo module
from komira_proto_codec import Serializable, WireDecoder, WireEncoder, decode_proto, encode_proto


@fieldwise_init
struct User(Serializable):
    var name: String
    var id: Int64

    def encode[E: WireEncoder](self, mut enc: E) raises:
        enc.write_string_field(1, "name", self.name)
        enc.write_i64_field(2, "id", self.id)

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        var user = User("", 0)
        while True:
            var key = dec.next_field()
            if key.end:
                break
            if key.field_no == 1 or key.json_name == "name":
                user.name = dec.read_string()
            elif key.field_no == 2 or key.json_name == "id":
                user.id = dec.read_i64()
            else:
                dec.skip()
        return user^


def main() raises:
    var bytes = encode_proto(User("ada", 150))
    assert_equal(bytes, [0x0A, 0x03, 0x61, 0x64, 0x61, 0x10, 0x96, 0x01])
    var back = decode_proto[User](bytes^)
    assert_equal(back.name, "ada")
    assert_equal(back.id, 150)
```

The same message as proto3 JSON; an `int64` is written as a JSON string, so no
reader loses precision above 2^53:

<!-- mojo-hidden
from std.testing import assert_equal
from komira_proto_codec import Serializable, WireDecoder, WireEncoder


@fieldwise_init
struct User(Serializable):
    var name: String
    var id: Int64

    def encode[E: WireEncoder](self, mut enc: E) raises:
        enc.write_string_field(1, "name", self.name)
        enc.write_i64_field(2, "id", self.id)

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        var user = User("", 0)
        while True:
            var key = dec.next_field()
            if key.end:
                break
            if key.field_no == 1 or key.json_name == "name":
                user.name = dec.read_string()
            elif key.field_no == 2 or key.json_name == "id":
                user.id = dec.read_i64()
            else:
                dec.skip()
        return user^
-->
```mojo module
from komira_proto_codec import decode_json, encode_json


def main() raises:
    assert_equal(encode_json(User("ada", 9007199254740993)), '{"name":"ada","id":"9007199254740993"}')
    var user = decode_json[User]('{"name": "ada", "id": "42"}')
    assert_equal(user.id, 42)
```

An unknown key is refused; the lenient decoder ignores it:

<!-- mojo-hidden
from std.testing import assert_equal, assert_true
from komira_proto_codec import Serializable, WireDecoder, WireEncoder


@fieldwise_init
struct User(Serializable):
    var name: String
    var id: Int64

    def encode[E: WireEncoder](self, mut enc: E) raises:
        enc.write_string_field(1, "name", self.name)
        enc.write_i64_field(2, "id", self.id)

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        var user = User("", 0)
        while True:
            var key = dec.next_field()
            if key.end:
                break
            if key.field_no == 1 or key.json_name == "name":
                user.name = dec.read_string()
            elif key.field_no == 2 or key.json_name == "id":
                user.id = dec.read_i64()
            else:
                dec.skip()
        return user^
-->
```mojo module
from komira_proto_codec import decode_json, decode_json_lenient


def main() raises:
    var message = String()
    try:
        _ = decode_json[User]('{"name": "ada", "nmae": "typo"}')
    except e:
        message = String(e)
    assert_true(message.startswith('JsonError: unknown field "nmae" at $'))
    assert_equal(decode_json_lenient[User]('{"name": "ada", "nmae": "typo"}').name, "ada")
```
