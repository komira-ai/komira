# `komira_broker_proto`

## Responsibility

The multi-node routing types of a broker cluster, as protobuf messages
(`komira.broker.v1`) and the Mojo structs generated from them. A coordinator
assigns partitions to broker nodes; these messages carry what the nodes and
the coordinator tell each other about that:

- `BrokerClusterMap`: every live broker's reachable endpoint plus each
  partition's current leader, so any one broker can answer a complete Kafka
  Metadata request for the whole cluster.
- `NodeEndpoint`, `PartitionLeader`: one entry of each list. A leader of
  `-1` means no live node owns the partition.
- `NodeLoad`: a node's soft-advisory load report.
- `ClusterConfig`: the cluster shape (total partitions, live node count).

The file imports no other `.proto`. `komira_supervisor_proto`, the heartbeat
that carries these types, imports it. The field numbers are the contract:
`tests/test_broker_field_numbers.mojo` pins every one of them as wire bytes.

## API

| name | file | what it is |
|---|---|---|
| `BrokerClusterMap`, `NodeEndpoint`, `PartitionLeader` | [broker.proto](https://github.com/komira-ai/komira/blob/main/src/komira_broker_proto/komira/broker/v1/broker.proto) | the cluster-wide routing map |
| `NodeLoad`, `ClusterConfig` | [broker.proto](https://github.com/komira-ai/komira/blob/main/src/komira_broker_proto/komira/broker/v1/broker.proto) | a node's load report, the cluster shape |

The Mojo module is `komira_broker_proto.broker`. Each message is a struct
whose constructor takes its fields in declaration order (a proto3 `optional`
field or a message field is an `Optional`, a `repeated` field a `List`), and
conforms to `komira_proto_codec`'s `Serializable`, so `encode_proto` and
`decode_proto` (and the JSON pair) read and write it.

## Example

Every example below runs as a test when the package is built.

```mojo
from komira_broker_proto.broker import BrokerClusterMap, NodeEndpoint, PartitionLeader
from komira_proto_codec import decode_proto, encode_proto
from std.testing import assert_equal

var nodes = List[NodeEndpoint]()
nodes.append(NodeEndpoint(Int32(1), String("broker-1"), UInt32(9092)))
var leaders = List[PartitionLeader]()
leaders.append(PartitionLeader(UInt32(0), Int32(1)))
leaders.append(PartitionLeader(UInt32(1), Int32(-1)))  # no live owner

var routing = BrokerClusterMap(nodes^, leaders^)
var back = decode_proto[BrokerClusterMap](encode_proto(routing))
assert_equal(back.nodes[0].host, "broker-1")
assert_equal(back.nodes[0].port, UInt32(9092))
assert_equal(back.leaders[1].leader_node_id, Int32(-1))
```

`NodeLoad.reported_partition_total` has presence: unset is absent on the
wire, and a node that read the partition map reports its count, zero
included.

```mojo
from komira_broker_proto.broker import NodeLoad
from komira_proto_codec import decode_proto, encode_proto
from std.testing import assert_equal, assert_false

var quiet = NodeLoad(UInt64(0), UInt32(2), None)
assert_false(Bool(decode_proto[NodeLoad](encode_proto(quiet)).reported_partition_total))

var grown = NodeLoad(UInt64(1200), UInt32(2), Optional[UInt32](UInt32(16)))
assert_equal(decode_proto[NodeLoad](encode_proto(grown)).reported_partition_total.value(), UInt32(16))
```

## Build files

This package is built with buildrules' `mojo_package` and packaged for mopm as `komira_broker_proto`, version 0.1.0
(`mopm.toml`). Its library is the generator's output, committed at `generated/komira_broker_proto_generated/` and
compiled as the module `komira_broker_proto` (`[targets] lib` of `mopm.toml`); its tests are `tests/`. It depends on one sibling package, `komira_proto_codec` (`{ path = "../komira_proto_codec", version = "0.1" }`), so the `.conda` of this package records `mojo-komira_proto_codec >=0.1,<0.2` as its dependency
and holds none of their files. The files that are not sources:

| file | what |
|---|---|
| `mopm.toml` | the mopm manifest: name, version, the Mojo version, the dependencies and where the library and its tests are |
| `mopm.lock` | the toolchain pins and the path dependencies, direct and transitive (no registry is reached: every dependency is a sibling) |
| `mopm-toolchain.toml` | the exact mopm and Mojo versions the build uses (written by hand) |
| `buildrules.mojo.lock.bzl`, `buildrules.mojo.bzl` | written by `buildrules mojo sync` from the files above and from the manifests of the siblings; `buildrules mojo check` fails when they are stale |

The `.proto` files are the inputs of the generator. `komira_broker_proto_generated_gen` writes the Mojo for them,
`komira_broker_proto_generated_fresh` compares it with the committed directory and fails when they differ, and
`:lib` is built only after that check has passed. Regenerate with
`./buck2 run komira//tools/build/gen:regen -- komira//src/komira_broker_proto:komira_broker_proto_generated`.
`mojo_package` does not run that check itself, so the gate is a target beside it (`BUCK`).

After any change to a `.proto` file, a test, or a manifest of this package or of a sibling, regenerate, run
`buildrules mojo sync` with the packages staged, commit what it writes, and build `komira//src/komira_broker_proto:lib`
on the farm.

`:conda` is buildrules' `mojo_conda` over `:lib`, packed with the manifests of the path dependencies beside its own
(`members`); `:conda_holds` reads it back and fails when the dependencies are not exactly the ones above.
`:komira_broker_proto` is `:lib` as komira's Mojo rules take it (`mojo_adopted_library`): its `deps` are the adopted
target of each package in `[dependencies]`, and the rule refuses a list that is not the closure `:lib` was built from.
It also compiles and runs the README's examples (`[tests][readme]`) against `:lib`.
