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

```mojo
var manifest = decode_json[FullManifest](manifest_json())
var preimage = encode_proto(manifest)
assert_equal(encode_proto(decode_proto[FullManifest](preimage.copy())), preimage)
assert_equal(encode_proto(decode_json[FullManifest](encode_json(manifest))), preimage)
```

A kind is read by name and stored by number, and the names are the ones the
`.proto` declares:

```mojo
var bucket = ResourceKind.from_json_name("RESOURCE_KIND_BUCKET")
assert_equal(bucket.number(), ResourceKind.RESOURCE_KIND_BUCKET)
assert_equal(ResourceKind.from_number(bucket.number()).json_name(), "RESOURCE_KIND_BUCKET")
assert_true(ResourceKind.is_known_json_name("RESOURCE_KIND_GRANT"))
assert_false(ResourceKind.is_known_json_name("RESOURCE_KIND_LAMBDA"))
assert_equal(ResourceKind.from_json_name("RESOURCE_KIND_LAMBDA").number(), ResourceKind.RESOURCE_KIND_UNSPECIFIED)
```
