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

## Build files

This package is built with buildrules' `mojo_package` and packaged for mopm as `komira_proto_codec`, version 0.1.0
(`mopm.toml`). The library is `src/komira_proto_codec/`, its tests are `tests/`. It has no native archive. It
depends on three libraries of this repository, `komira_encoding`, `komira_json` and `komira_protobuf`, as mopm path
dependencies (`[dependencies]` of `mopm.toml`, each with a path and the version `0.1`). The files that are not sources:

| file | what |
|---|---|
| `mopm.toml` | the mopm manifest: name, version, the Mojo version, the three path dependencies, where the library and its tests are |
| `mopm.lock` | what `mopm lock` writes (with no registry reachable); it lists the three path dependencies and pins the toolchain |
| `mopm-toolchain.toml` | the exact mopm and Mojo versions the build uses (written by hand) |
| `buildrules.mojo.lock.bzl`, `buildrules.mojo.bzl` | written by `buildrules mojo sync` from the files above; `buildrules mojo check` fails when they are stale |
| `generated_tests/` | the tests and `.proto` files that need a generated message type; they are not in `tests/`, so `:lib` does not wait for them (see below) |

`:lib` is the library file and exists only once every test of `tests/` has passed, and, built from the unit graph of
the three dependencies, only once their own tests have passed. After any change to a source, a test, `mopm.toml`,
`mopm.lock` or `mopm-toolchain.toml`, run `buildrules mojo sync`, commit what it writes, and build
`komira//src/komira_proto_codec:lib` on the farm.

`:komira_proto_codec` is `:lib` as komira's Mojo rules take it (`mojo_adopted_library`). Its `deps` are the adopted
labels of the same three packages, so a dependent of this library also sees their `.mojoc` files; the list is kept equal
by hand to the `[dependencies]` of `mopm.toml`. It also compiles and runs the README's examples against `:lib`
(`[tests][readme]`); the tests are not run again.

`generated_tests/` holds `test_copy_hazard`, `test_float32_json_binades` and `test_implicit_presence_json` with the two
`.proto` files they need. A generated message type is built from this library (`mojo_proto_library` over
`:komira_proto_codec`), so a test that uses one cannot be a test of `:lib`. They stay targets of komira's own rules.
