# `kci_artifact_proto`

## Responsibility

The artifacts schema (`kci.release.v1`): the reviewed list of what kci builds
and publishes, as protobuf definitions and the Mojo structs generated from
them. A file names its build systems (a program, the flags it always gets,
and the commands kci runs to find affected targets, build targets and checks)
and its artifacts (a name, the build system that builds it, and the arguments
appended for it). kci knows no build tool by name; the build rules (an empty
`{out_dir}`, one artifact per entry, one kci artifact manifest
`manifest.json` at its top whose `name` is the artifact's) are stated in the
`.proto`.

The package holds no reader or validator: reading an artifacts file,
checking it and rendering a build's argv is `kci_artifact`. The `.proto`
imports no other proto; other protos import it as
`kci/release/v1/artifact.proto`.

## API

The definitions are in
[artifact.proto](https://github.com/komira-ai/komira/blob/main/src/kci_artifact_proto/artifact.proto);
the Mojo module is `kci_artifact_proto.artifact`, with one struct per
message: `Artifacts` (the file), `BuildSystem`, `Command`, `Artifact` and
`Check`. Each struct's constructor takes its fields by name (a message field
is an `Optional`, a `repeated` field a `List`). Encode and decode with
`komira_proto_codec`'s `encode_json` and `decode_json` (proto3 canonical
JSON, `lowerCamelCase` keys) or `encode_proto` and `decode_proto` (protobuf
binary).

`Artifact` field 2 is reserved: it was `allowed_channels`, and a record under
that number is skipped on read.

## Examples

Every example below runs as a test when the package is built.

An artifacts file with one build system and one artifact, written as proto3
JSON. A field at its default (an empty list, an unset message) is left out:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from kci_artifact_proto.artifact import Artifact, Artifacts, BuildSystem, Check, Command
from komira_proto_codec import decode_json, decode_proto, encode_json, encode_proto

def example_artifacts() -> Artifacts:
    var systems = List[BuildSystem]()
    systems.append(
        BuildSystem(
            name=String("buck2"),
            executable=String("./buck2"),
            args=[String("build")],
            affected=None,
            build_targets=None,
            derive_checks=None,
        )
    )
    var artifacts = List[Artifact]()
    artifacts.append(
        Artifact(
            name=String("hello"),
            build_system=String("buck2"),
            args=[String("//src/hello:hello")],
            targets=List[String](),
        )
    )
    return Artifacts(
        build_systems=systems^,
        artifacts=artifacts^,
        schema_version=Int32(1),
        checks=List[Check](),
    )

assert_equal(
    encode_json(example_artifacts()),
    '{"buildSystems":[{"name":"buck2","executable":"./buck2","args":["build"]}],'
    + '"artifacts":[{"name":"hello","buildSystem":"buck2","args":["//src/hello:hello"]}],'
    + '"schemaVersion":1}',
)
```

Reading a file back gives the same message, on either wire: decoding then
encoding again reproduces the bytes exactly. A message field that the file
sets (here `affected`) is present after the round trip:

<!-- mojo-hidden
from std.testing import assert_equal, assert_false, assert_true
from kci_artifact_proto.artifact import Artifacts
from komira_proto_codec import decode_json, decode_proto, encode_json, encode_proto
-->
```mojo
var text = String(
    '{"buildSystems":[{"name":"buck2","executable":"./buck2",'
    + '"affected":{"executable":"./tools/affected","args":["--base","main"]}}],'
    + '"schemaVersion":1}'
)
var file = decode_json[Artifacts](text)
assert_equal(len(file.build_systems), 1)
assert_true(Bool(file.build_systems[0].affected))
assert_equal(file.build_systems[0].affected.value().executable, "./tools/affected")
assert_equal(file.build_systems[0].affected.value().args[1], "main")
assert_false(Bool(file.build_systems[0].build_targets))

var wire = encode_proto(file)
assert_equal(encode_proto(decode_proto[Artifacts](wire.copy())), wire)
assert_equal(encode_json(decode_proto[Artifacts](wire.copy())), encode_json(file))
```

The field numbers are the wire. `Artifact` field 2 (the retired
`allowed_channels`) is reserved: a record under it is skipped, and lands in
no declared field. On the JSON side, a key that is not a field is refused,
so a file still carrying `allowedChannels` fails to read rather than being
silently half-applied:

<!-- mojo-hidden
from std.testing import assert_equal, assert_true
from kci_artifact_proto.artifact import Artifact
from komira_proto_codec import decode_json, decode_proto
-->
```mojo
# name = "n" (field 1), a field-2 string "z", build_system = "b" (field 3).
var old = List[UInt8]()
for b in [0x0A, 1, ord("n"), 0x12, 1, ord("z"), 0x1A, 1, ord("b")]:
    old.append(UInt8(b))
var artifact = decode_proto[Artifact](old^)
assert_equal(artifact.name, "n")
assert_equal(artifact.build_system, "b")
assert_equal(len(artifact.args), 0)
assert_equal(len(artifact.targets), 0)

var refused = String()
try:
    _ = decode_json[Artifact]('{"name":"hello","allowedChannels":["public"]}')
except e:
    refused = String(e)
assert_true(refused.startswith('JsonError: unknown field "allowedChannels"'))
```
