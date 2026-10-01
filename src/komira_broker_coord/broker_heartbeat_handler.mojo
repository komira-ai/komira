# =============================================================================
# komira_broker_coord/broker_heartbeat_handler.mojo
#   BROKER COORDINATOR: the broker-node heartbeat handler (no DB, object-store
#   CAS persistence).
# =============================================================================
#
# The broker runs entirely on the object store (compute and storage are
# decoupled), so this package depends only on komira_broker, komira_http,
# komira_serde, komira_async, engine_rpc and the object-store traits: no
# database, no Kubernetes client, no job store.
#
# WHAT THIS DOES (one broker heartbeat round):
#   1. REGISTER/REFRESH the heartbeating node in the in-memory registry.
#   2. LIVENESS SCAN: prune nodes past `now - stale_threshold_us`.
#   3. ASSIGN: read the prior assignment from the `ClusterAssignmentStore` (the
#      object-store CAS store; `Assignment.decode_binary`), decide the
#      rebalance reason, run the pure `assign_partitions` pass.
#   4. PERSIST: CAS-write the new assignment binary body via the store's etag-CAS
#      (If-None-Match create / If-Match update; loser-re-reads-on-412 + retries).
#      There is no table and no bootstrap phase: the first write creates the
#      object via If-None-Match. The store's opaque etag is the version carried
#      through the retry loop.
#   5. REPLY: build the HeartbeatResponse (this node's assigned partitions + the
#      ClusterConfig + the cluster routing map).
#
# THE COALESCE CACHE sits above the store: the membership-keyed cache +
# `_membership_changed` gate is store-AGNOSTIC (it touches the in-memory
# registry only). Only `reassign` touches the store. A steady-state heartbeat
# does ZERO I/O.
#
# ENCAPSULATION: value-typed surface (Pb* value in, Pb* value out). The
# registry is a List of POD-ish value structs. The `ClusterAssignmentStore[Storage]`
# is owned by value (moved in). ZERO UnsafePointer crosses any boundary; ZERO
# wildcard origin.
# =============================================================================

from std.memory import ArcPointer

from komira_broker import (
    LiveNode,
    Assignment,
    ClusterAssignmentStore,
    assign_partitions,
    rebalance_reason_for,
    live_node_ids,
    REBALANCE_INITIAL,
)
from komira_objectstore.store import CloneableConditionalWriteStore

# The GENERATED engine.proto messages (`engine_rpc`).
from engine_rpc.engine import (
    SupervisorHeartbeat as PbSupervisorHeartbeat,
    HeartbeatResponse as PbHeartbeatResponse,
    NodeLoad as PbNodeLoad,
    ClusterConfig as PbClusterConfig,
    BrokerClusterMap as PbBrokerClusterMap,
    NodeEndpoint as PbNodeEndpoint,
    PartitionLeader as PbPartitionLeader,
)


# =============================================================================
# Defaults — the broker-node liveness cadence.
# =============================================================================

# A broker node is STALE if it has not heartbeated within this window. At the
# 5s heartbeat cadence, a node that misses ~3 heartbeats (15s) is considered
# dead and its partitions reassign.
comptime BROKER_NODE_STALE_THRESHOLD_US: Int64 = Int64(15_000_000)  # 15s

# The CAS-retry bound — a lost CAS (412) re-reads + recomputes + retries up to
# this many times before giving up. 256 mirrors the consumer-group coordinator's
# bound. A single coordinator normally owns the loop, so the CAS is the
# cross-replica safety net, not the steady path; a real burst of contending
# coordinators still converges well within this bound.
comptime _CAS_RETRY_LIMIT: Int = 256

# Peer routing: the no-leader sentinel for a partition no live node owns.
comptime NO_LEADER_NODE_ID: Int32 = -1

# Peer routing: the endpoint default when a broker heartbeat omits the
# advertised_host/port fields.
comptime DEFAULT_ADVERTISED_HOST: String = String("127.0.0.1")
comptime DEFAULT_ADVERTISED_PORT: Int32 = Int32(9092)


# =============================================================================
# _parse_node_id — node_id String -> the Kafka broker.id Int32.
# =============================================================================
def _parse_node_id(s: String) -> Int32:
    """Parse a numeric node_id String to the Kafka broker.id Int32. A
    non-numeric / empty id maps to NO_LEADER_NODE_ID (-1)."""
    var bytes = s.as_bytes()
    if len(bytes) == 0:
        return NO_LEADER_NODE_ID
    var neg = False
    var start = 0
    if bytes[0] == UInt8(0x2D):  # '-'
        neg = True
        start = 1
        if len(bytes) == 1:
            return NO_LEADER_NODE_ID
    var acc = Int(0)
    for i in range(start, len(bytes)):
        var c = bytes[i]
        if c < UInt8(0x30) or c > UInt8(0x39):  # not '0'..'9'
            return NO_LEADER_NODE_ID
        acc = acc * 10 + Int(c - UInt8(0x30))
    if neg:
        acc = -acc
    return Int32(acc)


# =============================================================================
# _id_lists_equal — element-wise String-list equality (the coalesce cache key).
# =============================================================================
def _id_lists_equal(a: List[String], b: List[String]) -> Bool:
    """True iff two String lists are equal (same length + same order). The
    coalesce gate compares the live node-id set against the
    cached assignment's membership."""
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


# =============================================================================
# NodeRegistryEntry — one broker node the coordinator currently tracks.
# =============================================================================


@fieldwise_init
struct NodeRegistryEntry(Copyable, Movable, Deinitable):
    """One broker node in the coordinator's registry: its stable id, the
    liveness clock, the soft-advisory load, the partitions it reports serving,
    its advertised endpoint (for peer routing), and the live topic partition
    count it observed (so the topic can grow its partition count)."""

    var node_id: String
    var last_heartbeat_us: Int64
    var records_served: UInt64
    var owned_partitions: List[UInt32]
    var advertised_host: String
    var advertised_port: Int32
    var reported_partition_total: Int


# =============================================================================
# NodeEndpointSnapshot — the eager registry projection for the
# cluster-wide routing map. Captured at make_frame time (after the prune) so the
# parkable SM builds the routing map AFTER the reassign WITHOUT re-borrowing the
# live registry across the park.
# =============================================================================


@fieldwise_init
struct NodeEndpointSnapshot(Copyable, Movable, Deinitable):
    """One live node's routing fields, snapshotted for the post-park cluster
    map."""

    var node_id: String
    var advertised_host: String
    var advertised_port: Int32


# =============================================================================
# _CoalesceCacheState — the membership-keyed coalesce cache, Arc-shared so the
# SYNCHRONOUS reassign AND the PARKABLE async reassign SM both refresh the same
# cache. The serve loop stays responsive because a steady-state heartbeat
# replies from this cache with ZERO store I/O; the parkable serve preserves that by having the async SM write the freshly-computed assignment
# back here on completion (via its own Arc handle), so a subsequent
# no-membership-change heartbeat is a one-step DONE (never parks).
# =============================================================================


struct _CoalesceCacheState(Movable, Deinitable):
    """The membership-keyed coalesce cache + the recompute counter, Arc-shared
    between the coordinator (sync path) and the parkable reassign SM (async
    path). Single-threaded by construction (the coordinator's serve reactor is
    one thread); the Arc is for SHARED OWNERSHIP across the two value-typed
    owners, not for cross-thread concurrency."""

    var cached_assignment: Optional[Assignment]
    var cached_membership: List[String]
    var cached_effective_p: Int
    var has_cache: Bool
    # Test observability: how many times the store recompute path actually ran.
    var store_recompute_count: Int

    def __init__(out self):
        self.cached_assignment = Optional[Assignment]()
        self.cached_membership = List[String]()
        self.cached_effective_p = 0
        self.has_cache = False
        self.store_recompute_count = 0

    def refresh(
        mut self,
        var assignment: Assignment,
        var membership: List[String],
        effective_p: Int,
    ):
        """Install a freshly-computed assignment as the coalesce cache (called by
        both the sync reassign and the async SM on a won CAS)."""
        self.cached_assignment = Optional[Assignment](assignment^)
        self.cached_membership = membership^
        self.cached_effective_p = effective_p
        self.has_cache = True


# =============================================================================
# BrokerHeartbeatCoordinator[Storage] — the broker-node heartbeat handler.
# =============================================================================


struct BrokerHeartbeatCoordinator[
    Storage: CloneableConditionalWriteStore
](Movable, Deinitable):
    """The broker-node heartbeat handler: owns the registry + a
    `ClusterAssignmentStore[Storage]` (object-store CAS persistence), and turns one
    broker-node heartbeat into an assignment reply. PURE GLUE: it never
    re-implements the spread — it folds the heartbeat into the registry, runs the
    liveness scan, calls the EXISTING pure `assign_partitions`, and persists via
    the store's etag-CAS.

    A coordinator RESTART recovers its assignment from the store on the next
    heartbeat (the prior is read from `ClusterAssignmentStore.read_assignment`),
    so the in-memory registry being empty after a restart does not lose the
    placement — the persisted binary body is the source of truth and the sticky
    pass keeps live nodes on their partitions."""

    var _store: ClusterAssignmentStore[Self.Storage]
    var _cluster: String
    var _topic: String
    var _num_partitions: Int
    var _stale_threshold_us: Int64
    var _registry: List[NodeRegistryEntry]

    # -------------------------------------------------------------------------
    # ASSIGNMENT CACHE + COALESCE: keeps the serve loop from stalling. The
    # cache is membership-keyed + store-AGNOSTIC (touches the in-memory registry
    # only). A heartbeat that does NOT change membership replies FROM CACHE with
    # ZERO store I/O, so the single-threaded reactor stays responsive. The store
    # recompute (`reassign`) runs ONLY on an actual membership change, so there
    # is no per-heartbeat object-store round trip: a blocking store op on the
    # serve thread is removed, not just cached around.
    # -------------------------------------------------------------------------
    # The coalesce cache is Arc-shared so the PARKABLE async
    # reassign SM can refresh it on completion (preserving the steady-state
    # one-step/zero-store-I/O coalesce invariant under the parkable serve). The
    # synchronous reassign and the async SM both reach it via `self._cache[]`.
    var _cache: ArcPointer[_CoalesceCacheState]

    def __init__(
        out self,
        var store: ClusterAssignmentStore[Self.Storage],
        var cluster: String,
        var topic: String,
        num_partitions: Int,
        stale_threshold_us: Int64 = BROKER_NODE_STALE_THRESHOLD_US,
    ):
        self._store = store^
        self._cluster = cluster^
        self._topic = topic^
        self._num_partitions = num_partitions
        self._stale_threshold_us = stale_threshold_us
        self._registry = List[NodeRegistryEntry]()
        self._cache = ArcPointer[_CoalesceCacheState](_CoalesceCacheState())

    def store_mut(ref self) -> ref [self._store] ClusterAssignmentStore[Self.Storage]:
        """Borrow the underlying store (test inspection / shared setup)."""
        return self._store

    def cache_handle(self) -> ArcPointer[_CoalesceCacheState]:
        """A shared handle on the coalesce cache, for the
        parkable async reassign SM (so it refreshes the SAME cache on a won CAS,
        preserving the steady-state coalesce invariant)."""
        return self._cache.copy()

    def clone_underlying_store(self) -> Self.Storage:
        """A fresh handle on the SAME underlying object store
        (Arc-shared core/map), for the parkable async reassign op."""
        return self._store.clone_store()

    def assignment_key(self) -> String:
        """The per-topic assignment object key, so the parkable
        async reassign op addresses the same object the sync reassign does."""
        return self._store.key_for(self._topic)

    @always_inline
    def num_partitions(self) -> Int:
        return self._num_partitions

    @always_inline
    def cluster(self) -> String:
        return self._cluster

    @always_inline
    def topic(self) -> String:
        return self._topic

    def live_node_count(self, now_us: Int64) -> Int:
        """How many registered nodes are LIVE at `now`. Test observability."""
        var c = 0
        for i in range(len(self._registry)):
            if self._registry[i].last_heartbeat_us >= (
                now_us - self._stale_threshold_us
            ):
                c += 1
        return c

    @always_inline
    def store_recompute_count(self) -> Int:
        """TEST OBSERVABILITY: how many times the store
        recompute path (`reassign` — read_assignment + the CAS write) has
        actually run. A steady-state heartbeat (no membership change) leaves this
        FLAT (zero store I/O on the serve thread),
        so the single-threaded reactor stays responsive to `accept()`. Counts
        BOTH the sync reassign and the parkable async reassign (Arc-shared)."""
        return self._cache[].store_recompute_count

    # -------------------------------------------------------------------------
    # _register — fold one node's heartbeat into the registry (add or refresh).
    # -------------------------------------------------------------------------
    def _register(
        mut self,
        node_id: String,
        last_heartbeat_us: Int64,
        records_served: UInt64,
        var owned: List[UInt32],
        var advertised_host: String,
        advertised_port: Int32,
        reported_partition_total: Int,
    ):
        """Add a new node or REFRESH an existing one's liveness clock + reported
        state (incl. its advertised endpoint + its observed live partition
        total)."""
        for i in range(len(self._registry)):
            if self._registry[i].node_id == node_id:
                self._registry[i].last_heartbeat_us = last_heartbeat_us
                self._registry[i].records_served = records_served
                self._registry[i].owned_partitions = owned^
                self._registry[i].advertised_host = advertised_host^
                self._registry[i].advertised_port = advertised_port
                self._registry[i].reported_partition_total = (
                    reported_partition_total
                )
                return
        self._registry.append(
            NodeRegistryEntry(
                node_id=String(node_id),
                last_heartbeat_us=last_heartbeat_us,
                records_served=records_served,
                owned_partitions=owned^,
                advertised_host=advertised_host^,
                advertised_port=advertised_port,
                reported_partition_total=reported_partition_total,
            )
        )

    # -------------------------------------------------------------------------
    # _prune_stale — drop nodes whose last heartbeat is past the stale cutoff.
    # -------------------------------------------------------------------------
    def _prune_stale(mut self, now_us: Int64):
        """Remove every registry entry whose `last_heartbeat_us` is older than
        `now - stale_threshold_us` (a stale node is treated dead — its partitions
        reassign)."""
        var cutoff = now_us - self._stale_threshold_us
        var kept = List[NodeRegistryEntry]()
        for i in range(len(self._registry)):
            if self._registry[i].last_heartbeat_us >= cutoff:
                kept.append(self._registry[i].copy())
        self._registry = kept^

    # -------------------------------------------------------------------------
    # _effective_num_partitions — the LIVE topic P (split-aware).
    # -------------------------------------------------------------------------
    def _effective_num_partitions(self, now_us: Int64) -> Int:
        """The live topic partition count to assign over: `max(configured P,
        max reported live-P over the non-stale registry)`."""
        var p = self._num_partitions
        var cutoff = now_us - self._stale_threshold_us
        for i in range(len(self._registry)):
            if self._registry[i].last_heartbeat_us >= cutoff:
                var reported = self._registry[i].reported_partition_total
                if reported > p:
                    p = reported
        return p

    # -------------------------------------------------------------------------
    # _live_nodes — the LiveNode list for the pure assignment pass.
    # -------------------------------------------------------------------------
    def _live_nodes(self, now_us: Int64) -> List[LiveNode]:
        """Project the (already-pruned) registry onto the `LiveNode` value list
        the pure `live_node_ids` / `assign_partitions` pass consumes."""
        var out = List[LiveNode]()
        for i in range(len(self._registry)):
            out.append(
                LiveNode(
                    node_id=String(self._registry[i].node_id),
                    last_heartbeat_us=self._registry[i].last_heartbeat_us,
                    records_served=self._registry[i].records_served,
                )
            )
        return out^

    # -------------------------------------------------------------------------
    # _membership_changed — the STORE-FREE coalesce gate.
    # -------------------------------------------------------------------------
    def _membership_changed(mut self, now_us: Int64) -> Bool:
        """Prune stale nodes, then return True iff the live membership (sorted
        live node-id set + effective P) differs from the cached assignment's
        membership — or no assignment is cached yet. STORE-FREE: pure over the
        in-memory registry. When this returns False the caller may reply from the
        cache with ZERO store I/O."""
        self._prune_stale(now_us)
        var live = self._live_nodes(now_us)
        var sorted_ids = live_node_ids(live, now_us, self._stale_threshold_us)
        var effective_p = self._effective_num_partitions(now_us)
        ref cache = self._cache[]
        if not cache.has_cache:
            return True
        if effective_p != cache.cached_effective_p:
            return True
        if not _id_lists_equal(sorted_ids, cache.cached_membership):
            return True
        return False

    # -------------------------------------------------------------------------
    # reassign — the registry->assignment pass + the object-store CAS persist.
    #
    # STORE: this is THE store-touching path (read_assignment + the CAS write).
    # It increments `_store_recompute_count` and refreshes the coalesce cache so a
    # subsequent no-membership-change heartbeat replies from cache without
    # re-entering the store.
    # -------------------------------------------------------------------------
    def reassign(mut self, now_us: Int64) raises -> Assignment:
        """Prune stale nodes, read the prior assignment from the CAS store,
        run the pure `assign_partitions` pass over the live set, and CAS-persist
        the binary result (If-None-Match create / If-Match update). On a lost CAS
        (a concurrent coordinator won) the loop RE-READS the winner's body,
        re-runs the pure pass against it, and retries (up to _CAS_RETRY_LIMIT).
        Returns the fresh `Assignment` (the caller projects the responding node's
        partitions onto the reply)."""
        self._cache[].store_recompute_count += 1
        self._prune_stale(now_us)

        var live = self._live_nodes(now_us)
        var sorted_ids = live_node_ids(live, now_us, self._stale_threshold_us)
        var effective_p = self._effective_num_partitions(now_us)

        # CAS-retry loop: read the prior (with its etag), run the pure pass,
        # CAS-write. A 412 (a concurrent coordinator won) re-reads + retries.
        var attempt = 0
        while attempt < _CAS_RETRY_LIMIT:
            attempt += 1

            # Read the prior persisted assignment + its etag. None -> initial.
            var prior = Optional[Assignment]()
            var expected_etag = String("")
            var prior_stored = self._store.read_assignment(self._topic)
            if prior_stored:
                ref ps = prior_stored.value()
                prior = Optional[Assignment](Assignment.decode_binary(ps.body))
                expected_etag = ps.etag.copy()

            var reason = rebalance_reason_for(
                prior, sorted_ids, effective_p, operator_forced=False
            )

            # The sticky pass is idempotent under REBALANCE_NONE, so the persisted
            # body + the reply stay consistent with the live set. A GROWN
            # effective_p vs the prior P reports REBALANCE_PARTITION_COUNT.
            var assignment = assign_partitions(
                sorted_ids.copy(), effective_p, prior^, reason
            )

            # CAS-persist the binary body (create / If-Match).
            try:
                _ = self._store.store_assignment(
                    self._topic, assignment.encode_binary(), expected_etag
                )
            except e:
                # A lost CAS (412): a concurrent coordinator wrote first. Re-read
                # + recompute + retry. Any non-precondition error propagates.
                if ClusterAssignmentStore[
                    Self.Storage
                ].is_precondition_failure(String(e)):
                    continue
                raise Error(String(e))

            # CAS won — refresh the coalesce cache + return.
            self._cache[].refresh(
                assignment.copy(), sorted_ids.copy(), effective_p
            )
            return assignment^

        raise Error(
            "BrokerHeartbeatCoordinator.reassign: CAS contention did not"
            " converge within "
            + String(_CAS_RETRY_LIMIT)
            + " attempts (topic="
            + self._topic
            + ")"
        )

    # -------------------------------------------------------------------------
    # _build_broker_cluster_map — the cluster-wide routing map (peer
    # routing). Called AFTER prune+reassign so dead nodes never appear.
    # -------------------------------------------------------------------------
    def _build_broker_cluster_map(
        self, assignment: Assignment
    ) raises -> PbBrokerClusterMap:
        """Assemble the cluster-wide routing map a single broker uses to serve a
        COMPLETE Kafka Metadata response. NODES: walk the (stale-pruned) registry
        -> one NodeEndpoint per live broker. LEADERS: walk the assignment's
        owners -> per-partition leader (parse node_id String to broker.id; an
        UNASSIGNED partition -> NO_LEADER -1)."""
        var nodes = List[PbNodeEndpoint]()
        for i in range(len(self._registry)):
            ref e = self._registry[i]
            nodes.append(
                PbNodeEndpoint(
                    _parse_node_id(e.node_id),
                    e.advertised_host.copy(),
                    UInt32(Int(e.advertised_port)),
                )
            )
        var leaders = List[PbPartitionLeader]()
        for pid in range(assignment.num_partitions):
            var owner = assignment.owner_of(pid)
            var leader_id = NO_LEADER_NODE_ID
            if owner.byte_length() > 0:
                leader_id = _parse_node_id(owner)
            leaders.append(PbPartitionLeader(UInt32(pid), leader_id))
        return PbBrokerClusterMap(nodes^, leaders^)

    # -------------------------------------------------------------------------
    # handle_broker_heartbeat — the FULL round: register -> reassign -> reply.
    # -------------------------------------------------------------------------
    def handle_broker_heartbeat(
        mut self,
        hb: PbSupervisorHeartbeat,
        now_us: Int64,
    ) raises -> PbHeartbeatResponse:
        """Process one BROKER-NODE heartbeat and build the assignment reply.

        PRECONDITION: `hb.node_id` is present (a node_id-absent heartbeat is a
        plain JOB heartbeat and must NOT route here). Raises if `node_id` absent.

        Steps: fold the heartbeat into the registry; reassign (prune -> pure pass
        -> CAS persist) ONLY on a membership change (else serve from cache, ZERO
        store I/O); build the cluster-wide routing map AFTER the prune; reply with
        THIS node's assigned partitions + the ClusterConfig + the routing map."""
        if not hb.node_id:
            raise Error(
                "broker heartbeat handler: node_id absent — this is a JOB"
                " heartbeat, route to the job-leg handler"
            )
        var node_id = hb.node_id.value()

        var records_served = UInt64(0)
        var reported_partition_total = 0
        if hb.load:
            ref ld = hb.load.value()
            records_served = ld.records_served
            if ld.reported_partition_total:
                reported_partition_total = Int(
                    ld.reported_partition_total.value()
                )

        var owned = List[UInt32]()
        for i in range(len(hb.owned_partitions)):
            owned.append(hb.owned_partitions[i])

        var adv_host = DEFAULT_ADVERTISED_HOST
        if hb.advertised_host:
            adv_host = hb.advertised_host.value()
        var adv_port = DEFAULT_ADVERTISED_PORT
        if hb.advertised_port:
            adv_port = Int32(Int(hb.advertised_port.value()))

        self._register(
            node_id,
            now_us,
            records_served,
            owned^,
            adv_host^,
            adv_port,
            reported_partition_total,
        )

        # COALESCE: keeps the serve loop responsive. Recompute (the store
        # path) ONLY on an actual membership change; otherwise reply from the
        # cached assignment with ZERO store I/O so the single-threaded reactor
        # stays responsive to `accept()` under a heartbeat burst.
        var assignment: Assignment
        if self._membership_changed(now_us):
            assignment = self.reassign(now_us)
        else:
            assignment = self._cache[].cached_assignment.value().copy()

        var assigned = assignment.partitions_for(node_id)
        # The per-partition lease generations for THIS node's
        # assigned partitions, POSITIONALLY PARALLEL to `assigned` (so the owner
        # learns the (pid, generation) lease for every partition it serves).
        var assigned_gens = assignment.generations_for(node_id)
        var cluster = PbClusterConfig(
            UInt32(assignment.num_partitions),
            UInt32(assignment.node_count()),
        )
        var broker_cluster = self._build_broker_cluster_map(assignment)
        return PbHeartbeatResponse(
            False,  # cancel (a broker node is never job-cancelled here)
            assigned^,  # assigned_partitions (this node's share)
            Optional[PbClusterConfig](cluster^),  # cluster
            Optional[PbBrokerClusterMap](broker_cluster^),  # broker_cluster
            assigned_gens^,  # assigned_generations (the lease per assigned pid)
        )

    # -------------------------------------------------------------------------
    # _endpoint_snapshot — project the (pruned) registry onto the routing-map
    # inputs the parkable SM uses AFTER the park.
    # -------------------------------------------------------------------------
    def _endpoint_snapshot(self) -> List[NodeEndpointSnapshot]:
        """Snapshot every (live, already-pruned) registry node's routing fields,
        so the parkable SM can build the cluster-wide routing map after the
        reassign without re-borrowing the live registry."""
        var out = List[NodeEndpointSnapshot]()
        for i in range(len(self._registry)):
            ref e = self._registry[i]
            out.append(
                NodeEndpointSnapshot(
                    node_id=String(e.node_id),
                    advertised_host=String(e.advertised_host),
                    advertised_port=e.advertised_port,
                )
            )
        return out^

    # -------------------------------------------------------------------------
    # prepare_async_heartbeat — the EAGER prelude for the PARKABLE serve. Runs the synchronous, store-FREE part of one heartbeat round —
    # register the node + the coalesce check — and returns a `HeartbeatPrelude`
    # telling the dispatcher whether to deliver a ONE-STEP cached reply (the
    # dominant path, never parks) or to drive a PARKABLE reassign (membership
    # change). NEVER touches the store (the store work is the parkable part).
    # -------------------------------------------------------------------------
    def prepare_async_heartbeat(
        mut self, hb: PbSupervisorHeartbeat, now_us: Int64
    ) raises -> HeartbeatPrelude:
        """Register the node + run the store-free coalesce check. On a coalesce
        HIT, returns a one-step prelude carrying the cached assignment; on a
        membership change, returns a parkable prelude carrying the pure-pass
        inputs (sorted_ids + effective_p) + the endpoint snapshot, and bumps the
        recompute counter (the async reassign WILL recompute). Raises if node_id
        is absent (caller must have routed a non-broker heartbeat away)."""
        if not hb.node_id:
            raise Error(
                "broker heartbeat handler: node_id absent — this is a JOB"
                " heartbeat, route to the job-leg handler"
            )
        var node_id = hb.node_id.value()

        var records_served = UInt64(0)
        var reported_partition_total = 0
        if hb.load:
            ref ld = hb.load.value()
            records_served = ld.records_served
            if ld.reported_partition_total:
                reported_partition_total = Int(
                    ld.reported_partition_total.value()
                )

        var owned = List[UInt32]()
        for i in range(len(hb.owned_partitions)):
            owned.append(hb.owned_partitions[i])

        var adv_host = DEFAULT_ADVERTISED_HOST
        if hb.advertised_host:
            adv_host = hb.advertised_host.value()
        var adv_port = DEFAULT_ADVERTISED_PORT
        if hb.advertised_port:
            adv_port = Int32(Int(hb.advertised_port.value()))

        self._register(
            node_id,
            now_us,
            records_served,
            owned^,
            adv_host^,
            adv_port,
            reported_partition_total,
        )

        # COALESCE — the store-free membership check (prunes stale nodes).
        var changed = self._membership_changed(now_us)
        var endpoints = self._endpoint_snapshot()
        if not changed:
            # Coalesce HIT — reply from cache, ZERO store I/O (one-step DONE).
            return HeartbeatPrelude(
                parked=False,
                node_id=String(node_id),
                cached_assignment=Optional[Assignment](
                    self._cache[].cached_assignment.value().copy()
                ),
                sorted_ids=List[String](),
                effective_p=0,
                endpoints=endpoints^,
            )

        # MEMBERSHIP CHANGE — the parkable reassign. Compute the pure-pass inputs
        # (the registry is already pruned by the coalesce check). The async
        # reassign recomputes, so bump the recompute counter here (it WILL run).
        var live = self._live_nodes(now_us)
        var sorted_ids = live_node_ids(live, now_us, self._stale_threshold_us)
        var effective_p = self._effective_num_partitions(now_us)
        self._cache[].store_recompute_count += 1
        return HeartbeatPrelude(
            parked=True,
            node_id=String(node_id),
            cached_assignment=Optional[Assignment](),
            sorted_ids=sorted_ids^,
            effective_p=effective_p,
            endpoints=endpoints^,
        )


# =============================================================================
# HeartbeatPrelude — the discriminated result of the eager
# prelude. `parked == False` => a coalesce HIT: `cached_assignment` is the reply
# assignment (one-step DONE, never parks). `parked == True` => a membership
# change: `sorted_ids` + `effective_p` are the parkable reassign's pure-pass
# inputs. `node_id` + `endpoints` are common (the reply-building inputs).
# =============================================================================


struct HeartbeatPrelude(Movable, Deinitable):
    """The eager prelude's discriminated output (see the header)."""

    var parked: Bool
    var node_id: String
    var cached_assignment: Optional[Assignment]
    var sorted_ids: List[String]
    var effective_p: Int
    var endpoints: List[NodeEndpointSnapshot]

    def __init__(
        out self,
        parked: Bool,
        var node_id: String,
        var cached_assignment: Optional[Assignment],
        var sorted_ids: List[String],
        effective_p: Int,
        var endpoints: List[NodeEndpointSnapshot],
    ):
        self.parked = parked
        self.node_id = node_id^
        self.cached_assignment = cached_assignment^
        self.sorted_ids = sorted_ids^
        self.effective_p = effective_p
        self.endpoints = endpoints^
