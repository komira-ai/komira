# komira_broker_coordinator

The coordinator of a multi-node `komira_broker` cluster, with no database. Each
broker node sends it a heartbeat; it answers with the partitions that node
serves, the lease generation of each, the cluster size and the routing map
(which node leads which partition, at which advertised address).

- `BrokerHeartbeatCoordinator[Storage]` folds a heartbeat into an in-memory
  registry of nodes, drops nodes that have not heartbeated within the stale
  threshold (`BROKER_NODE_STALE_THRESHOLD_US`, 15 s by default), and when the
  set of live nodes changed, recomputes the assignment with `komira_broker`'s
  sticky `assign_partitions` and persists it through `ClusterAssignmentStore`
  with a compare-and-swap write to the object store. A heartbeat that does not
  change membership is answered from the cached assignment with no store I/O.
  After a restart the assignment is read back from the store, so live nodes
  keep their partitions.
- `BrokerCoordinatorService` and `run_coordinator_forever` serve the heartbeat
  route over `komira_http_server`; `BrokerCoordSuspendableDispatcher` and
  `BrokerHeartbeatSM` are the variant whose store writes do not block the serve
  loop.

The heartbeat and its reply are the generated protobuf messages of
`komira_supervisor_proto` (`SupervisorHeartbeat`, `HeartbeatResponse`) and
`komira_broker_proto`. The store is a type parameter: an in-memory
conditional-write store in tests, an object-store client in a deployment. The
coordinator does not move data and does not run partition split or merge.

## Examples

Two nodes join a 6-partition topic and split it evenly; a third joins and the
spread reflows to two each. Steady heartbeats are answered without touching the
store. Times are microseconds passed by the caller, so nothing here reads a
clock:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_broker import ClusterAssignmentStore
from komira_broker_coordinator import BrokerHeartbeatCoordinator
from komira_broker_proto.broker import NodeLoad
from komira_objectstore import SharedInMemoryConditionalStore
from komira_supervisor_proto.supervisor import JobPhase, SupervisorHeartbeat

comptime Store = SharedInMemoryConditionalStore


def heartbeat(node_id: String) -> SupervisorHeartbeat:
    return SupervisorHeartbeat(
        String("00000000-0000-0000-0000-000000000000"),  # no work item: a broker node
        JobPhase(JobPhase.JOB_PHASE_RUNNING),
        "broker-node-" + node_id,
        None,  # progress
        None,  # message
        None,  # failure
        Optional[String](node_id),
        Optional[NodeLoad](NodeLoad(UInt64(0), UInt32(0), Optional[UInt32]())),
        List[UInt32](),  # partitions the node reports owning
        None,  # advertised host: the default
        None,  # advertised port: the default
    )


var coord = BrokerHeartbeatCoordinator[Store](
    ClusterAssignmentStore[Store](Store(), "cluster-1"), "cluster-1", "events", 6
)
var now = Int64(1_000_000_000)
_ = coord.handle_broker_heartbeat(heartbeat("1"), now)
now += 100_000
var reply = coord.handle_broker_heartbeat(heartbeat("2"), now)
assert_equal(len(reply.assigned_partitions), 3)  # node 2 serves 3 of 6
assert_equal(reply.cluster.value().node_count, UInt32(2))
assert_equal(len(reply.assigned_generations), len(reply.assigned_partitions))

var writes = coord.store_recompute_count()
for _ in range(5):
    now += 100_000
    _ = coord.handle_broker_heartbeat(heartbeat("1"), now)
assert_equal(coord.store_recompute_count(), writes)  # membership unchanged: no store I/O

now += 100_000
var joined = coord.handle_broker_heartbeat(heartbeat("3"), now)
assert_equal(coord.store_recompute_count(), writes + 1)
assert_equal(len(joined.assigned_partitions), 2)
assert_equal(joined.cluster.value().node_count, UInt32(3))
assert_equal(coord.live_node_count(now), 3)
```

A heartbeat without a node id is not a broker heartbeat, and is refused:

<!-- mojo-hidden from std.testing import assert_true -->
```mojo
from komira_broker import ClusterAssignmentStore
from komira_broker_coordinator import BrokerHeartbeatCoordinator
from komira_objectstore import SharedInMemoryConditionalStore
from komira_supervisor_proto.supervisor import JobPhase, SupervisorHeartbeat

var coord = BrokerHeartbeatCoordinator[SharedInMemoryConditionalStore](
    ClusterAssignmentStore[SharedInMemoryConditionalStore](SharedInMemoryConditionalStore(), "c"),
    "c",
    "events",
    4,
)
var anonymous = SupervisorHeartbeat(
    String("00000000-0000-0000-0000-000000000000"),
    JobPhase(JobPhase.JOB_PHASE_RUNNING),
    "anonymous",
    None, None, None,
    None,  # no node id
    None,
    List[UInt32](),
    None, None,
)
var refused = False
try:
    _ = coord.handle_broker_heartbeat(anonymous, 0)
except e:
    refused = String(e).find("node_id absent") >= 0
assert_true(refused)
```
