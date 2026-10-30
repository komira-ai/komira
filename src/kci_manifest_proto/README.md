# `kci_manifest_proto`

## Responsibility

The deployment resource graph (`kci.manifest.v1`): `FullManifest`, the fully
expanded, typed graph of resources for one environment, as protobuf
definitions and the Mojo structs generated from them. A composition
synthesizes it from the authored intent, a planner diffs it, and a deployer
applies it node by node in dependency order. It is never written by hand.

- `FullManifest`: the environment it targets, its content address (empty
  until it is pinned), and its nodes.
- `ResourceNode`: a `logical_id` unique in the manifest, a generic
  `ResourceKind`, the `depends_on` edges (the `logical_id`s created first),
  a `Retention` (delete or keep on a reverse walk), and a `oneof config`
  holding the typed spec of its kind (`QueueSpec`, `DnsRecordSpec`,
  `ConfigSpec`, `ServerlessComputeSpec`, `ResolvedBucketSpec`, `GrantSpec`,
  ...).

The kind vocabulary is generic (serverless compute, datastore, queue,
bucket, grant, ...): no vendor product name is a kind. A pinned manifest's
binary encoding is its content-address preimage. The `.proto` imports
nothing: the deployer's only desired-state input needs no intent schema.

`ResourceKind` numbers are append-only: a stored manifest carries the number,
so renumbering a kind would re-point every stored node.
`tests/test_resource_kind_ordinals.mojo` pins each one.

## API

The definitions are in
[full_manifest.proto](https://github.com/komira-ai/komira/blob/main/src/kci_manifest_proto/full_manifest.proto);
the Mojo module is `kci_manifest_proto.full_manifest`, and the `.proto` is
imported as `kci/manifest/v1/full_manifest.proto`. Each message is a struct
(a message field or a `oneof` arm is an `Optional`, a `repeated` field a
`List`, a `map` a `Dict`); each enum is a struct over its number with one
`Int` constant per declared value (`ResourceKind.RESOURCE_KIND_QUEUE`).
Encode and decode with `komira_proto_codec`'s `encode_json` and
`decode_json` (proto3 canonical JSON) or `encode_proto` and `decode_proto`
(protobuf binary).

## Examples

Every example below runs as a test when the package is built.

A two-node manifest read from proto3 JSON: a queue, and a config entry
created after it. Each node's kind is an enum value, its edges are the
`depends_on` list, and its spec is the one `config` arm the JSON sets:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from kci_manifest_proto.full_manifest import FullManifest, ResourceKind, ResourceNode, Retention
from komira_proto_codec import decode_json, decode_proto, encode_json, encode_proto

def manifest_json() -> String:
    return (
        '{"environment":"staging","nodes":['
        + '{"logicalId":"jobs","kind":"RESOURCE_KIND_QUEUE","retention":"RETENTION_DELETE",'
        + '"queue":{"name":"jobs"}},'
        + '{"logicalId":"settings","kind":"RESOURCE_KIND_CONFIG","dependsOn":["jobs"],'
        + '"retention":"RETENTION_RETAIN_KEEP","configData":{"values":{"QUEUE":"jobs"}}}'
        + ']}'
    )

var manifest = decode_json[FullManifest](manifest_json())
assert_equal(manifest.environment, "staging")
assert_equal(manifest.content_address, "")

ref queue = manifest.nodes[0]
assert_equal(queue.kind.number(), ResourceKind.RESOURCE_KIND_QUEUE)
assert_equal(queue.retention.number(), Retention.RETENTION_DELETE)
assert_equal(queue.queue.value().name, "jobs")
assert_false(Bool(queue.config_data))
assert_equal(len(queue.depends_on), 0)

ref settings = manifest.nodes[1]
assert_equal(settings.kind.number(), ResourceKind.RESOURCE_KIND_CONFIG)
assert_equal(settings.depends_on[0], queue.logical_id)
assert_equal(settings.retention.number(), Retention.RETENTION_RETAIN_KEEP)
assert_equal(settings.config_data.value().values["QUEUE"], "jobs")
assert_false(Bool(settings.queue))
```

The binary encoding is the content-address preimage, so it must not drift
across a round trip: decoding and encoding again reproduces the bytes, and
the JSON form decodes to the same bytes:

<!-- mojo-hidden
from std.testing import assert_equal
from kci_manifest_proto.full_manifest import FullManifest
from komira_proto_codec import decode_json, decode_proto, encode_json, encode_proto

def manifest_json() -> String:
    return (
        '{"environment":"staging","nodes":['
        + '{"logicalId":"jobs","kind":"RESOURCE_KIND_QUEUE","retention":"RETENTION_DELETE",'
        + '"queue":{"name":"jobs"}},'
        + '{"logicalId":"settings","kind":"RESOURCE_KIND_CONFIG","dependsOn":["jobs"],'
        + '"retention":"RETENTION_RETAIN_KEEP","configData":{"values":{"QUEUE":"jobs"}}}'
        + ']}'
    )
-->
```mojo
var manifest = decode_json[FullManifest](manifest_json())
var preimage = encode_proto(manifest)
assert_equal(encode_proto(decode_proto[FullManifest](preimage.copy())), preimage)
assert_equal(encode_proto(decode_json[FullManifest](encode_json(manifest))), preimage)
```

A kind is read by name and stored by number, and the names are the ones the
`.proto` declares:

<!-- mojo-hidden
from std.testing import assert_equal, assert_false, assert_true
from kci_manifest_proto.full_manifest import ResourceKind
-->
```mojo
var bucket = ResourceKind.from_json_name("RESOURCE_KIND_BUCKET")
assert_equal(bucket.number(), ResourceKind.RESOURCE_KIND_BUCKET)
assert_equal(ResourceKind.from_number(bucket.number()).json_name(), "RESOURCE_KIND_BUCKET")
assert_true(ResourceKind.is_known_json_name("RESOURCE_KIND_GRANT"))
assert_false(ResourceKind.is_known_json_name("RESOURCE_KIND_LAMBDA"))
assert_equal(ResourceKind.from_json_name("RESOURCE_KIND_LAMBDA").number(), ResourceKind.RESOURCE_KIND_UNSPECIFIED)
```

## Build files

This package is built with buildrules' `mojo_package` and packaged for mopm as `kci_manifest_proto`, version 0.1.0
(`mopm.toml`). Its library is the generator's output, committed at `generated/kci_manifest_proto_generated/` and
compiled as the module `kci_manifest_proto` (`[targets] lib` of `mopm.toml`); its tests are `tests/`. It depends on one sibling package, `komira_proto_codec` (`{ path = "../komira_proto_codec", version = "0.1" }`), so the `.conda` of this package records `mojo-komira_proto_codec >=0.1,<0.2` as its dependency
and holds none of their files. The files that are not sources:

| file | what |
|---|---|
| `mopm.toml` | the mopm manifest: name, version, the Mojo version, the dependencies and where the library and its tests are |
| `mopm.lock` | the toolchain pins and the path dependencies, direct and transitive (no registry is reached: every dependency is a sibling) |
| `mopm-toolchain.toml` | the exact mopm and Mojo versions the build uses (written by hand) |
| `buildrules.mojo.lock.bzl`, `buildrules.mojo.bzl` | written by `buildrules mojo sync` from the files above and from the manifests of the siblings; `buildrules mojo check` fails when they are stale |

The `.proto` files are the inputs of the generator. `kci_manifest_proto_generated_gen` writes the Mojo for them,
`kci_manifest_proto_generated_fresh` compares it with the committed directory and fails when they differ, and
`:lib` is built only after that check has passed. Regenerate with
`./buck2 run komira//tools/build/gen:regen -- komira//src/kci_manifest_proto:kci_manifest_proto_generated`.
`mojo_package` does not run that check itself, so the gate is a target beside it (`BUCK`).

After any change to a `.proto` file, a test, or a manifest of this package or of a sibling, regenerate, run
`buildrules mojo sync` with the packages staged, commit what it writes, and build `komira//src/kci_manifest_proto:lib`
on the farm.

`:conda` is buildrules' `mojo_conda` over `:lib`, packed with the manifests of the path dependencies beside its own
(`members`); `:conda_holds` reads it back and fails when the dependencies are not exactly the ones above.
`:kci_manifest_proto` is `:lib` as komira's Mojo rules take it (`mojo_adopted_library`): its `deps` are the adopted
target of each package in `[dependencies]`, and the rule refuses a list that is not the closure `:lib` was built from.
It also compiles and runs the README's examples (`[tests][readme]`) against `:lib`.
