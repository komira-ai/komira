# `kci_deploy_model_proto`

## Responsibility

The deploy model (`kci.deploy.v1`): `DeploymentSpec`, what one deployment
asks for, and the intent types other deploy protos reuse, as protobuf
definitions and the Mojo structs generated from them.

- `DeploymentSpec`: a name and namespace, its containers (`ContainerSpec`,
  with `EnvVar` and `PortSpec`), labels, the account it deploys into, the
  compute, datastore and inbound intents, the secrets it binds
  (`SecretBinding`), the provider and stage, the served ports, the lifecycle,
  and the datastore's index tables (`BundleIndexTable`, `BundleIndex`,
  `BundleIndexField`).
- The intent enums: `ComputeIntent`, `DatastoreNeed`, `DatastoreFamily`,
  `DatastoreImpl`, `InboundNeed`, `NetworkIngress`, `DeployProvider`,
  `StageIdentity`, `DeployLifecycle` and `SecretCustody`.

The `.proto` imports no other proto, so the generated code's only runtime is
`komira_proto_codec`. Other protos import it as
`kci/deploy/v1/deploy_model.proto` and name this target in `proto_deps`.

## API

The definitions are in
[deploy_model.proto](https://github.com/komira-ai/komira/blob/main/src/kci_deploy_model_proto/deploy_model.proto);
the Mojo module is `kci_deploy_model_proto.deploy_model`. Each message is a
struct whose constructor takes its fields by name (a proto3 `optional` field
or a message field is an `Optional`, a `repeated` field a `List`). Each enum
is a struct over its number (`.value`, `number()`) with one `Int` constant
per declared value, spelled as in the `.proto`
(`ComputeIntent.COMPUTE_INTENT_SERVERLESS`); `json_name()`,
`from_json_name()`, `from_number()`, `is_known_json_name()` and
`known_json_names()` map between the number and the name. Encode and decode
with `komira_proto_codec`'s `encode_json` and `decode_json` (proto3 canonical
JSON) or `encode_proto` and `decode_proto` (protobuf binary).

## Examples

Every example below runs as a test when the package is built.

A deployment read from proto3 JSON. An enum is written by its value name, a
field the text leaves out holds its default, and a proto3 `optional` field
says whether it was given at all:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from kci_deploy_model_proto.deploy_model import ComputeIntent, DatastoreNeed, DeployProvider, DeploymentSpec
from komira_proto_codec import decode_json, decode_proto, encode_json, encode_proto

var spec = decode_json[DeploymentSpec](
    '{"name":"api","namespace":"prod",'
    + '"containers":[{"name":"api","image":"registry.example/api",'
    + '"ports":[{"name":"http","containerPort":8080}]}],'
    + '"compute":"COMPUTE_INTENT_SERVERLESS","provider":"DEPLOY_PROVIDER_CLOUD_RUN",'
    + '"keepLastN":3}'
)
assert_equal(spec.containers[0].ports[0].container_port, Int32(8080))
assert_equal(spec.compute.number(), ComputeIntent.COMPUTE_INTENT_SERVERLESS)
assert_equal(spec.provider.number(), DeployProvider.DEPLOY_PROVIDER_CLOUD_RUN)
assert_equal(spec.datastore.number(), DatastoreNeed.DATASTORE_NEED_UNSPECIFIED)
assert_true(Bool(spec.keep_last_n))
assert_equal(spec.keep_last_n.value(), Int32(3))
assert_false(Bool(spec.prior_digest))
```

A proto3 `optional` field that is given is written even when it holds the
default, so "keep none" (`keepLastN: 0`) survives a round trip and stays
distinct from "not said". Decoding and encoding again reproduces the binary
bytes exactly, and the JSON round trip gives the same binary:

<!-- mojo-hidden
from std.testing import assert_equal, assert_false, assert_true
from kci_deploy_model_proto.deploy_model import DeploymentSpec
from komira_proto_codec import decode_json, decode_proto, encode_json, encode_proto
-->
```mojo
var spec = decode_json[DeploymentSpec]('{"name":"api","keepLastN":0}')
assert_true(Bool(spec.keep_last_n))
assert_equal(spec.keep_last_n.value(), Int32(0))
assert_equal(encode_json(spec), '{"name":"api","keepLastN":0}')

var unsaid = decode_json[DeploymentSpec]('{"name":"api"}')
assert_false(Bool(unsaid.keep_last_n))
assert_equal(encode_json(unsaid), '{"name":"api"}')

var wire = encode_proto(spec)
assert_equal(encode_proto(decode_proto[DeploymentSpec](wire.copy())), wire)
assert_equal(encode_proto(decode_json[DeploymentSpec](encode_json(spec))), wire)
```

Enum numbers and names map both ways. An unknown name reads as the zero value
(proto3's rule for an unknown enum value), and a number that no declaration
owns renders as its decimal text. `DatastoreNeed` 3 is reserved (it was
`DATASTORE_NEED_OBJECTSTORE`), so it has no name:

<!-- mojo-hidden
from std.testing import assert_equal, assert_false, assert_true
from kci_deploy_model_proto.deploy_model import DatastoreNeed
-->
```mojo
var dedicated = DatastoreNeed.from_json_name("DATASTORE_NEED_DEDICATED")
assert_equal(dedicated.number(), DatastoreNeed.DATASTORE_NEED_DEDICATED)
assert_equal(DatastoreNeed.from_number(dedicated.number()).json_name(), "DATASTORE_NEED_DEDICATED")
assert_true(DatastoreNeed.is_known_json_name("DATASTORE_NEED_DEDICATED"))
assert_true("DATASTORE_NEED_DEDICATED" in DatastoreNeed.known_json_names())

assert_equal(DatastoreNeed.from_json_name("DATASTORE_NEED_SOMETHING_ELSE").number(), 0)
assert_false(DatastoreNeed.is_known_json_name("DATASTORE_NEED_OBJECTSTORE"))
assert_equal(DatastoreNeed.from_number(3).json_name(), "3")
```

## Build files

This package is built with buildrules' `mojo_package` and packaged for mopm as `kci_deploy_model_proto`, version 0.1.0
(`mopm.toml`). Its library is the generator's output, committed at `generated/kci_deploy_model_proto_generated/` and
compiled as the module `kci_deploy_model_proto` (`[targets] lib` of `mopm.toml`); its tests are `tests/`. It depends on one sibling package, `komira_proto_codec` (`{ path = "../komira_proto_codec", version = "0.1" }`), so the `.conda` of this package records `mojo-komira_proto_codec >=0.1,<0.2` as its dependency
and holds none of their files. The files that are not sources:

| file | what |
|---|---|
| `mopm.toml` | the mopm manifest: name, version, the Mojo version, the dependencies and where the library and its tests are |
| `mopm.lock` | the toolchain pins and the path dependencies, direct and transitive (no registry is reached: every dependency is a sibling) |
| `mopm-toolchain.toml` | the exact mopm and Mojo versions the build uses (written by hand) |
| `buildrules.mojo.lock.bzl`, `buildrules.mojo.bzl` | written by `buildrules mojo sync` from the files above and from the manifests of the siblings; `buildrules mojo check` fails when they are stale |

The `.proto` files are the inputs of the generator. `kci_deploy_model_proto_generated_gen` writes the Mojo for them,
`kci_deploy_model_proto_generated_fresh` compares it with the committed directory and fails when they differ, and
`:lib` is built only after that check has passed. Regenerate with
`./buck2 run komira//tools/build/gen:regen -- komira//src/kci_deploy_model_proto:kci_deploy_model_proto_generated`.
`mojo_package` does not run that check itself, so the gate is a target beside it (`BUCK`).

After any change to a `.proto` file, a test, or a manifest of this package or of a sibling, regenerate, run
`buildrules mojo sync` with the packages staged, commit what it writes, and build `komira//src/kci_deploy_model_proto:lib`
on the farm.

`:conda` is buildrules' `mojo_conda` over `:lib`, packed with the manifests of the path dependencies beside its own
(`members`); `:conda_holds` reads it back and fails when the dependencies are not exactly the ones above.
`:kci_deploy_model_proto` is `:lib` as komira's Mojo rules take it (`mojo_adopted_library`): its `deps` are the adopted
target of each package in `[dependencies]`, and the rule refuses a list that is not the closure `:lib` was built from.
It also compiles and runs the README's examples (`[tests][readme]`) against `:lib`.
