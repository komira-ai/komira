# =============================================================================
# komira_broker/broker_node_state.mojo
#   Multi-node control plane — the in-process job-supervisor->broker relay
# =============================================================================
#
# The job supervisor and the broker are the SAME co-located node. The job
# supervisor holds a borrowed `ref` to a `BrokerNodeState` and, on each
# heartbeat round, reconciles the coordinator's `assigned_partitions[]` reply
# against the set this node is CURRENTLY serving — all in-process, NO second
# listener / file / RPC.
#
# -----------------------------------------------------------------------------
# WHAT THIS IS (the relay seam)
# -----------------------------------------------------------------------------
# `BrokerNodeState` owns:
#   * this node's stable `node_id` (the same id reported on the heartbeat).
#   * the set of partitions this node is CURRENTLY serving (`owned`).
# `apply_assignment(assigned)` diffs `assigned` (the desired set from the coordinator)
# against `owned` and returns a `ReconcileDelta { started, stopped }`:
#   * STARTED = in `assigned` but not in `owned`  -> begin serving (the caller
#     adds them to the Kafka server's leader map so Metadata reports this node
#     as leader + the partition accepts produce/consume).
#   * STOPPED = in `owned` but not in `assigned` -> stop serving (the caller
#     removes them from the leader map so Metadata stops advertising this node;
#     a client retrying produce gets NOT_LEADER_OR_FOLLOWER and refreshes).
# After computing the delta, `owned` becomes exactly `assigned` (idempotent: a
# re-apply of the same set yields an empty delta — no churn).
#
# WHY a delta (not direct side effects): keeping `BrokerNodeState` a PURE,
# testable value (owned-set + diff) means the unit tests run it offline; the
# actual start/stop side effects (mutating the Kafka server's per-partition
# leader map) are applied by the integration caller from the delta. This is the
# same shape as the assignment pass: pure decision here, effect at the edge.
#
# -----------------------------------------------------------------------------
# ENCAPSULATION: the job supervisor holds a borrowed `ref BrokerNodeState`
# that rides the per-dispatch heartbeat value (a borrowed ref threaded through
# the dispatch API, NOT a long-lived wildcard field). ZERO UnsafePointer crosses
# any boundary; no wildcard origin; no unsafe_from_address. BrokerNodeState is
# a stack value (a String + two List[UInt32]), never a byte-slab element.
# =============================================================================


# =============================================================================
# ReconcileDelta — the partitions to START + STOP serving after a reconcile.
# =============================================================================


@fieldwise_init
struct ReconcileDelta(Movable, Copyable, Deinitable):
    """The result of one `apply_assignment` reconcile: which partitions this node
    must BEGIN serving + which it must STOP serving to match the coordinator's desired
    assignment. Both lists are ascending + disjoint. An empty delta (both lists
    empty) means the node is already serving exactly the assigned set — the
    steady-state heartbeat (no churn).

    Field layout:
      var started: List[UInt32] — partitions to begin serving (added).
      var stopped: List[UInt32] — partitions to stop serving (removed).
    """

    var started: List[UInt32]
    var stopped: List[UInt32]

    @always_inline
    def is_empty(self) -> Bool:
        """True iff no partition changed ownership this reconcile."""
        return len(self.started) == 0 and len(self.stopped) == 0

    @always_inline
    def change_count(self) -> Int:
        """Total partitions that changed ownership (started + stopped)."""
        return len(self.started) + len(self.stopped)


# =============================================================================
# BrokerNodeState — the node's owned-partition set + the reconcile relay.
# =============================================================================


struct BrokerNodeState(Movable):
    """The co-located node's broker-serving state: its `node_id` + the set of
    partitions it is CURRENTLY serving + the per-partition lease GENERATION this
    node holds (the writer-lease-epoch the owner stamps on
    appends). The job supervisor holds a borrowed `ref` to one of these and
    calls `apply_assignment` each heartbeat round (the in-process relay).

    The owned set is kept SORTED ascending so `owned_partitions()` (the list the
    node reports back on its NEXT heartbeat's `owned_partitions[]`) is
    deterministic, and the diff is a clean merge-walk.

    LEASE GENERATIONS:
    the node tracks TWO per-pid generations:
      * `_lease_acquire_gen[pid]` — the WRITER epoch: the lease generation FROZEN
        at the moment this node BEGAN serving the partition (the acquire). The
        owner stamps THIS as `writer_lease_epoch` on every append. It is NOT
        raised by subsequent heartbeats while ownership is continuous.
      * `_lease_latest_gen[pid]` — the CURRENT epoch: the LATEST generation this
        node has observed from the coordinator's `assigned_generations[]` (the
        most authoritative value the node knows). Refreshed EVERY heartbeat. The
        owner reads THIS as `current_lease_epoch` at produce.

    For a continuously-owning live owner, acquire == latest (writer == current ->
    NEVER self-fenced — correct). The fence fires for the BEST-EFFORT case the
    scope targets: a DISPLACED owner that has OBSERVED the post-takeover bumped
    generation (its `_lease_latest_gen` reflects the new owner's higher epoch via
    a heartbeat) but is still flushing an in-flight produce stamped with its OLD
    frozen acquire epoch -> writer (old) < current (new) -> FENCED at the
    manifest. This is best-effort defense-in-depth: it does NOT close the full
    TOCTOU window (read-current ▷ transfer ▷ create-CAS are not atomic on a single
    manifest) — full torn-offset correctness is the per-generation sub-lineage
    model, separate from this fence.

    A pid with no delivered generation reads 0 (the no-op fence default). When a
    partition STOPS being owned its lease entries are dropped; a RE-acquire freezes
    a FRESH (higher) acquire epoch from the next heartbeat."""

    var _node_id: String
    var _owned: List[UInt32]
    # Per-pid lease generations. Positionally KEYED on pid (the
    # i-th _lease_pid entry pairs with _lease_acquire_gen[i] / _lease_latest_gen[i]).
    # Tiny (one per owned partition); a linear scan is fine.
    #   _lease_acquire_gen[i] = the WRITER epoch frozen at this node's acquire of
    #                           _lease_pid[i] (stamped as writer_lease_epoch).
    #   _lease_latest_gen[i]  = the CURRENT epoch (latest observed; read as
    #                           current_lease_epoch). >= acquire always.
    var _lease_pid: List[UInt32]
    var _lease_acquire_gen: List[Int64]
    var _lease_latest_gen: List[Int64]

    def __init__(out self, var node_id: String):
        """A fresh node serving NOTHING (the boot state — the first heartbeat
        reports an empty owned set; the coordinator's first assignment reply seeds it)."""
        self._node_id = node_id^
        self._owned = List[UInt32]()
        self._lease_pid = List[UInt32]()
        self._lease_acquire_gen = List[Int64]()
        self._lease_latest_gen = List[Int64]()

    def __init__(out self, var node_id: String, var owned: List[UInt32]):
        """A node pre-seeded with an owned set (test setup). The set is sorted +
        de-duplicated on construction so the invariant holds. No lease
        generations (every owned pid reads generation 0 until a heartbeat with
        generations lands)."""
        self._node_id = node_id^
        self._owned = _sorted_unique(owned^)
        self._lease_pid = List[UInt32]()
        self._lease_acquire_gen = List[Int64]()
        self._lease_latest_gen = List[Int64]()

    @always_inline
    def node_id(self) -> String:
        return self._node_id

    def _lease_index_of(self, pid: UInt32) -> Int:
        for i in range(len(self._lease_pid)):
            if self._lease_pid[i] == pid:
                return i
        return -1

    def writer_lease_epoch_of(self, pid: UInt32) -> Int64:
        """The WRITER epoch for `pid` — the lease generation
        FROZEN at this node's acquire of the partition. Stamped as
        `writer_lease_epoch` on appends. 0 when the partition has no tracked lease
        (an older coordinator / a partition not owned / the no-op fence default)."""
        var idx = self._lease_index_of(pid)
        if idx < 0:
            return Int64(0)
        return self._lease_acquire_gen[idx]

    def current_lease_epoch_of(self, pid: UInt32) -> Int64:
        """The CURRENT epoch for `pid` — the LATEST lease
        generation this node has observed from the coordinator. Read as
        `current_lease_epoch` at produce. >= writer_lease_epoch_of(pid) always.
        0 when the partition has no tracked lease."""
        var idx = self._lease_index_of(pid)
        if idx < 0:
            return Int64(0)
        return self._lease_latest_gen[idx]

    def lease_generation_of(self, pid: UInt32) -> Int64:
        """Back-compat alias: the WRITER epoch (the lease the owner stamps). Kept
        for callers that want the single "this node's lease" value; new fence
        callers use writer_lease_epoch_of / current_lease_epoch_of explicitly."""
        return self.writer_lease_epoch_of(pid)

    def owned_partitions(self) -> List[UInt32]:
        """The partitions this node is CURRENTLY serving, ascending. This is the
        `owned_partitions[]` the node reports on its NEXT heartbeat (so the coordinator
        sees the post-reconcile reality and its sticky pass keeps them here)."""
        return self._owned.copy()

    @always_inline
    def owns(self, pid: UInt32) -> Bool:
        """True iff this node is currently serving partition `pid`."""
        for i in range(len(self._owned)):
            if self._owned[i] == pid:
                return True
        return False

    @always_inline
    def partition_count(self) -> Int:
        """How many partitions this node currently serves (the soft-advisory
        `NodeLoad.partition_count` it reports)."""
        return len(self._owned)

    # -------------------------------------------------------------------------
    # apply_assignment — the RECONCILE (the in-process relay's core).
    # -------------------------------------------------------------------------
    def apply_assignment(mut self, assigned: List[UInt32]) -> ReconcileDelta:
        """Reconcile the coordinator's desired `assigned` set against the currently-owned
        set. Returns the START/STOP delta and UPDATES the owned set to exactly
        `assigned` (sorted + de-duplicated). No lease generations supplied — the
        lease map is left unchanged (the no-op / older-coordinator path).

        IDEMPOTENT: re-applying the same set yields an empty delta (the
        steady-state heartbeat — no churn). The delta lets the caller mutate the
        Kafka server's per-partition leader map (start = advertise this node as
        leader; stop = drop it so a client retry gets NOT_LEADER_OR_FOLLOWER and
        refreshes Metadata)."""
        return self.apply_assignment(assigned, List[Int64]())

    def apply_assignment(
        mut self, assigned: List[UInt32], generations: List[Int64]
    ) -> ReconcileDelta:
        """Reconcile the coordinator's desired `assigned` set + the per-partition lease
        `generations` (POSITIONALLY PARALLEL to `assigned`:
        generations[i] is the lease generation for assigned[i]) against the
        currently-owned set + lease map. Returns the START/STOP delta and UPDATES
        the owned set to exactly `assigned`.

        LEASE MAP UPDATE (the writer/current epoch tracking):
          * For a CONTINUOUSLY-owned pid: the WRITER (acquire) epoch is CARRIED
            FORWARD unchanged (the node has not re-acquired); the CURRENT (latest)
            epoch is RAISED to the delivered generation (the node now knows the
            authoritative latest — if a bump happened while it was still in the
            assignment, current > writer and the fence fires).
          * For a NEWLY-started pid (in `started`): the acquire epoch is FROZEN at
            the delivered generation, and current == acquire (a fresh, clean lease
            — never self-fenced until a later bump it observes).
          * A STOPPED pid's lease entries are dropped.
        Both epochs honor a MONOTONICITY guard: a stale/out-of-order heartbeat can
        never LOWER a known epoch (that would be a self-inflicted fence bypass —
        the coordinator only ever bumps).

        IDEMPOTENT: re-applying the same set+generations yields an empty delta and
        leaves both epochs unchanged."""
        var want = _sorted_unique(assigned.copy())

        var started = List[UInt32]()
        var stopped = List[UInt32]()

        # STARTED = in `want` but not in current owned.
        for i in range(len(want)):
            if not self.owns(want[i]):
                started.append(want[i])
        # STOPPED = in current owned but not in `want`.
        for i in range(len(self._owned)):
            if not _contains(want, self._owned[i]):
                stopped.append(self._owned[i])

        # Rebuild the lease map for the new owned set. assigned[i] pairs with
        # generations[i]; a missing generation (older coordinator / short list)
        # leaves the delivered value 0.
        var new_lease_pid = List[UInt32]()
        var new_acquire = List[Int64]()
        var new_latest = List[Int64]()
        for i in range(len(assigned)):
            var pid = assigned[i]
            # Skip a duplicate pid already recorded.
            var dup = False
            for k in range(len(new_lease_pid)):
                if new_lease_pid[k] == pid:
                    dup = True
                    break
            if dup:
                continue
            var delivered = Int64(0)
            if i < len(generations):
                delivered = generations[i]

            var was_owned = self.owns(pid)
            var prior_acquire = self.writer_lease_epoch_of(pid)
            var prior_latest = self.current_lease_epoch_of(pid)

            var acquire: Int64
            if was_owned:
                # Continuously owned: CARRY FORWARD the acquire (frozen) epoch.
                # (The monotonicity guard keeps it from regressing if the prior
                # was somehow higher than a stale delivered value.)
                acquire = prior_acquire
            else:
                # Newly started: FREEZE the acquire at the delivered generation.
                acquire = delivered

            # The CURRENT (latest) epoch is the max of the delivered value, the
            # prior latest, and the acquire (never below acquire). This is what a
            # displaced-but-still-assigned owner reads to fence itself once it has
            # observed a higher generation.
            var latest = delivered
            if prior_latest > latest:
                latest = prior_latest
            if acquire > latest:
                latest = acquire

            new_lease_pid.append(pid)
            new_acquire.append(acquire)
            new_latest.append(latest)
        self._lease_pid = new_lease_pid^
        self._lease_acquire_gen = new_acquire^
        self._lease_latest_gen = new_latest^

        # The owned set becomes exactly the assigned set.
        self._owned = want^
        return ReconcileDelta(started=started^, stopped=stopped^)


# =============================================================================
# Module helpers — small List[UInt32] set utilities (pure; no pointer flow).
# =============================================================================


def _contains(xs: List[UInt32], target: UInt32) -> Bool:
    for i in range(len(xs)):
        if xs[i] == target:
            return True
    return False


def _sorted_unique(var xs: List[UInt32]) -> List[UInt32]:
    """Return `xs` sorted ascending with duplicates removed (insertion sort — the
    per-node partition set is tiny; keeps the owned set canonical so the diff is
    deterministic + the reported `owned_partitions[]` is stable)."""
    # Insertion sort in place.
    var n = len(xs)
    for i in range(1, n):
        var j = i
        while j > 0 and xs[j - 1] > xs[j]:
            var tmp = xs[j - 1]
            xs[j - 1] = xs[j]
            xs[j] = tmp
            j -= 1
    # De-duplicate (adjacent after sort).
    var out = List[UInt32]()
    for i in range(len(xs)):
        if i == 0 or xs[i] != xs[i - 1]:
            out.append(xs[i])
    return out^
