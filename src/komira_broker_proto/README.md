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
