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
(`mopm.toml`). The library is `src/komira_proto_codec/`, its tests are `tests/`. It depends on three sibling
packages, `komira_encoding`, `komira_json` and `komira_protobuf` (`[dependencies]` of `mopm.toml`, each `{ path =
"../<name>", version = "0.1" }`), so the `.conda` of this package records `mojo-komira_encoding >=0.1,<0.2`,
`mojo-komira_json >=0.1,<0.2` and `mojo-komira_protobuf >=0.1,<0.2` as dependencies and holds none of their files.
The files that are not sources:

| file | what |
|---|---|
| `mopm.toml` | the mopm manifest: name, version, the Mojo version, the dependencies and where the library and its tests are |
| `mopm.lock` | the toolchain pins and the path dependencies (no registry is reached: every dependency is a sibling) |
| `mopm-toolchain.toml` | the exact mopm and Mojo versions the build uses (written by hand) |
| `coverage_floor.txt` | `lines NN.NN` and `branches NN.NN`: the least coverage `:coverage` may measure; `:coverage_floor` fails when either falls below |
| `buildrules.mojo.lock.bzl`, `buildrules.mojo.bzl` | written by `buildrules mojo sync` from the files above and from the manifests of the siblings; `buildrules mojo check` fails when they are stale |

`tests/test_*.mojo` are the package's tests and weld to `:lib`. `tests/standalone/` holds the three programs that
cannot be (their names have no `test_` prefix, so mopm does not discover them; the census counts them as test code, like the rest of `tests/`): `test_copy_hazard` and `test_implicit_presence_json` read a message type generated from
`tests/copy_hazard.proto` and `tests/implicit_presence.proto`, and `test_float32_json_binades` takes its binade and part
as defines. They are targets of their own in `BUCK` (`test_copy_hazard`, `implicit_presence_proto`,
`test_float32_json_binades_<binade>_<part>`).

`generated/` holds the committed output of the generator for the two `mojo_proto_library` targets above
(`copy_hazard_proto`, `implicit_presence_proto`; `tools/build/gen/README.md`). It is not the library: the library is
hand-written under `src/`. `<name>_fresh` compares each directory with what the generator writes now and is the first
gate of `<name>`; regenerate with `./buck2 run komira//tools/build/gen:regen -- komira//src/komira_proto_codec:`.

After any change to a source, a test, or a manifest of this package or of a sibling, run `buildrules mojo sync` with
the packages staged, commit what it writes, and build `komira//src/komira_proto_codec:lib` on the farm.

`:conda` is buildrules' `mojo_conda` over `:lib`: the `.conda` of the mopm package, packed with the siblings'
manifests beside its own (`members`), which therefore exists only once the tests have passed. `:conda_holds` reads
it back and fails when the dependencies are not exactly the three above. `:komira_proto_codec` is `:lib` as komira's
Mojo rules take it (`mojo_adopted_library`): its `deps` are the adopted target of each package in `[dependencies]`, and
the rule refuses a list that is not the closure `:lib` was built from. It also compiles and runs the README's
examples (`[tests][readme]`) against `:lib`.
