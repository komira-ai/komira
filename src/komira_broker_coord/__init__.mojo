"""komira_broker_coord: the broker-node coordinator, with no database.

The minimal control service for a multi-node broker. It serves the
broker-heartbeat endpoint over an HttpServer and persists the partition
assignment through the compare-and-swap object-store `ClusterAssignmentStore`
(`komira_broker`), parameterized over a `CloneableConditionalWriteStore`
(an in-memory store for tests, `S3ConditionalStore[C]` in production). It
depends on no database, Kubernetes client or job store, so a coordinator
binary built on it carries none of them.

Dependencies (cycle-free):
  komira_broker        (ClusterAssignmentStore + the pure assignment pass)
  komira_http          (HttpServer + RequestDispatcher serve loop)
  komira_proto_codec   (encode_proto / decode_proto)
  komira_async         (Reactor / BlockingRuntime serve runtime)
  komira_supervisor_proto, komira_broker_proto
                       (SupervisorHeartbeat / HeartbeatResponse wire and the
                       broker cluster map types)
  komira_objectstore   (CloneableConditionalWriteStore trait)
  komira_uuid          (now_unix_ms)
None of these depends back on komira_broker_coord: it is a leaf above the
broker.
"""

from .broker_heartbeat_handler import (
    BrokerHeartbeatCoordinator,
    NodeRegistryEntry,
    BROKER_NODE_STALE_THRESHOLD_US,
    NO_LEADER_NODE_ID,
    DEFAULT_ADVERTISED_HOST,
    DEFAULT_ADVERTISED_PORT,
)

from .broker_coordinator_service import (
    BrokerCoordinatorDispatcher,
    BrokerCoordinatorService,
    run_coordinator_forever,
    json_response,
    proto_response,
)

from .broker_heartbeat_suspendable import (
    AsyncReassignOp,
    BrokerCoordSuspendableDispatcher,
    BrokerHeartbeatSM,
    build_heartbeat_response,
    proto_heartbeat_http_response,
)
