# =============================================================================
# komira_broker/partition_assignment.mojo
#   Multi-node control plane — the PURE partition->node assignment pass
# =============================================================================
#
# This file is the STORE-AGNOSTIC assignment ALGORITHM: `assign_partitions(
# live_nodes, P, prior) -> Assignment` plus the node-liveness/stale tracking +
# rebalance-trigger decisions. It has ZERO dependency on a database, the object
# store or the heartbeat transport, so the unit tests run it OFFLINE; the
# caller persists the result (for example through cluster_assignment_store).
#
# -----------------------------------------------------------------------------
# THE MODEL — partitions are spread across NODES (distinct from partition SPLIT)
# -----------------------------------------------------------------------------
# `partition_map.mojo` decides HOW MANY partitions a topic has (split/merge —
# partition COUNT). THIS file decides WHICH NODE serves each partition (the
# partition->node placement). The two are orthogonal: P comes from the partition
# map (`PartitionMap.num_partitions()`); the assignment maps each pid `[0, P)`
# onto exactly one live node.
#
# -----------------------------------------------------------------------------
# THE TWO PROPERTIES THE ALGORITHM GUARANTEES
# -----------------------------------------------------------------------------
#  1. EVEN SPREAD: every live node serves either floor(P/N) or ceil(P/N)
#     partitions (the most-balanced possible integer split). For P=6, N=3 each
#     node serves exactly 2.
#  2. STICKY / MINIMAL-MOVE: a partition that is ALREADY assigned to a still-live
#     node STAYS there whenever doing so does not violate property 1. Only the
#     partitions that MUST move (those on a dead node, or the few that must shed
#     from an over-full node to satisfy even-spread) are reassigned. This bounds
#     the data-plane churn on a rebalance (a moved partition costs the new owner
#     a cold catch-up read; a stuck partition costs nothing).
#
# The algorithm is deterministic given (live_nodes sorted by node_id, P, prior),
# so two replicas computing the same assignment converge — the store layer's
# CAS breaks any genuine concurrent-write race, not the algorithm.
#
# -----------------------------------------------------------------------------
# SOFT-ADVISORY LOAD — NOT a lock
# -----------------------------------------------------------------------------
# A node's reported load (records_served / partition_count) is recorded for
# observability + licensing accounting. It is NEVER the basis for ownership:
# ownership is the assignment-table CAS, not a load-derived lease. A future
# increment may BIAS the even-spread tie-break toward less-loaded nodes, but
# today the tie-break is purely lexicographic on node_id (stable + testable). The
# `soft-advisory-is-not-a-lock` unit test pins this: a node reporting huge load
# still keeps its fair share; load never grants or revokes a partition.
#
# -----------------------------------------------------------------------------
# Encapsulation discipline
# -----------------------------------------------------------------------------
#   * ZERO UnsafePointer in any signature — every type here is a plain Movable +
#     Copyable value (String node ids + Int partition ids + small POD counters).
#   * ZERO wildcard origins / unsafe_from_address / take_pointee.
#   * These are stack values, never byte-slab elements. The only
#     heap-owning fields are List[String] / List[Int] of POD scalars / Strings —
#     never stored in an OwnedSlab/AtomicSlab with a wildcard cast.
# =============================================================================

from std.ffi import external_call
from std.time import perf_counter_ns


# =============================================================================
# Disjoint-keyspace WRITE-path sub-lineage SHARDING.
# =============================================================================
#
# THE CONTENTION PROBLEM (the same one komira_search's sub-lineage sharding
# solves): N concurrent broker writers producing to ONE partition race ONE
# manifest `_HEAD` create-CAS slot. Under genuine multi-writer contention the
# 412-loser re-reads HEAD + retries under backoff → throughput collapses as N
# grows and appends drop to retry-exhaustion. The fix is DISJOINT KEYSPACES:
# each writer publishes into its OWN manifest sub-lineage
# `<partition>/_lineage/<shard_id>/manifest/<seq>.chunk` so it is the SOLE
# writer of that lineage's `_HEAD` slot → every append wins first-try (zero
# cross-writer contention by construction).
#
# This file owns the WRITE-side sharding primitives ONLY (shard_id minting + the
# sub-lineage prefix). The read path (the `_base` fold + consume-reads-`_base`)
# lives in sublineage_segment_fold / sublineage_consume. Sub-lineage writes are
# a NON-DEFAULT mode (`BrokerCore.enable_sublineage_write`, default OFF); see
# `BrokerCore.flush` (broker_core.mojo) for the flag branch.
#
# COLLISION-FREE shard_id: the requirement is
# only that two CONCURRENT writers get DISTINCT shard_ids (so they never share a
# `_HEAD` slot) — a sub-lineage is its own keyspace, so there is no shared slot
# to collide on once the shard_id differs. The minted form is:
#
#     shard_id = <instance_id>-<pid>[-<worker_idx>]-<boot_nonce>
#
#   * instance_id  — a stable per-instance string (deployment node id / broker id).
#                    Distinguishes instances in a multi-node fleet.
#   * pid          — `getpid()` (a vsyscall, no allocation). Distinguishes
#                    PROCESSES on one node; survives the "two default-config
#                    processes share a node id" trap.
#   * worker_idx   — the per-worker index (>= 0) when a process mounts multiple
#                    writer cores; omitted (< 0) for the single-core process.
#   * boot_nonce   — a per-BOOT random nonce. Folded in
#                    so a platform `instance_id` REUSE across a reboot (a cloud
#                    instance recycled with the SAME id, or a pid wrapped to the
#                    same value after a fast restart) cannot collide with the
#                    PRIOR boot's still-live sub-lineage. The lease-generation
#                    fence is defense-in-depth ON TOP of this:
#                    a displaced prior-boot writer is fenced by generation even
#                    if a shard_id ever did collide.
#
# Encapsulation: pure value transforms (String + Int + Int64). ZERO UnsafePointer
# in any signature; the only FFI is the `getpid` vsyscall + the boot-nonce clock
# read (a stack-local SIMD scratch for gettimeofday-free entropy — perf_counter).
# These are stack Strings/ints, never byte-slab elements.
# -----------------------------------------------------------------------------


@always_inline
def _broker_getpid() -> Int64:
    """The current process id (POSIX `getpid`, a vsyscall — no allocation). The
    same symbol the broker's segment-key uniquifier uses
    (`broker_core._broker_proc_nonce`). Folded into every shard_id so two broker
    processes on the SAME `instance_id` mint DISTINCT sub-lineages."""
    return Int64(external_call["getpid", Int32]())


@always_inline
def _xorshift64_sa(var x: UInt64) -> UInt64:
    """Xorshift64 step (the cas_manifest `_xorshift64` twin, local so this file
    keeps its zero-dependency property). Used only to whiten the boot-nonce
    entropy — quality only needs to be "distinct across boots," not crypto."""
    x ^= x << UInt64(13)
    x ^= x >> UInt64(7)
    x ^= x << UInt64(17)
    return x


# The per-BOOT nonce: minted ONCE per process from the high-resolution clock
# (whitened by xorshift, mixed with the pid so two processes booting in the
# same clock tick still diverge). Mojo has no global variables, so this is
# computed at the first `broker_boot_nonce()` call by the CALLER and held by
# the caller (the BrokerCore mints its shard_id ONCE at enable-time and holds
# the String for its lifetime — the nonce never needs to be a process global).
@always_inline
def broker_boot_nonce() -> Int64:
    """A per-call random-ish nonce for the boot-uniqueness component of a shard_id
    Seeds an xorshift from `perf_counter_ns()` XORed with the pid, so two
    processes that mint at nearly the same instant draw different values. The
    caller mints this ONCE (at `enable_sublineage_write` time) and folds it into
    the stable shard_id — it is NOT re-rolled per append (that would scatter one
    writer's chunks across many lineages). Returns a non-negative Int64."""
    var seed = (
        UInt64(perf_counter_ns())
        ^ (UInt64(_broker_getpid()) * UInt64(0x9E3779B97F4A7C15))
    )
    var r = _xorshift64_sa(seed | UInt64(1))
    # Mask to the low 48 bits → always non-negative, compact in the key string.
    return Int64(r & UInt64(0xFFFFFFFFFFFF))


def mint_shard_id(
    instance_id: String, worker_idx: Int = -1, boot_nonce: Int64 = Int64(-1)
) raises -> String:
    """Mint a collision-free WRITE-path shard_id.

    Form: `<instance_id>-<pid>[-w<worker_idx>]-<boot_nonce>`.

    * `instance_id` — the stable per-instance string (node / broker id). Must be
      NON-EMPTY (an empty id is a wiring bug — every deployment has one, and the
      shard_id's whole job is to be distinct, so we fail LOUD rather than mint a
      degenerate `-<pid>-...` form).
    * `worker_idx`  — `>= 0` appends a `-w<idx>` segment (a process with multiple
      writer cores); `< 0` (the default) omits it (single-core process).
    * `boot_nonce`  — `>= 0` uses the supplied nonce (deterministic tests pass a
      fixed value); `< 0` (the default) mints a fresh per-boot nonce
      (`broker_boot_nonce()`). Folded in so a reused `instance_id`/pid across a
      reboot cannot collide with the prior boot's live sub-lineage.

    The shard_id contains NO `/` (it is one path segment under `_lineage/`); the
    components are joined by `-`. Raises on an empty `instance_id`."""
    if instance_id.byte_length() == 0:
        raise Error(
            "mint_shard_id: instance_id must be non-empty (every deployment has a"
            " stable node/broker id; an empty id defeats shard distinctness)"
        )
    var nonce = boot_nonce
    if nonce < Int64(0):
        nonce = broker_boot_nonce()
    var out = instance_id + "-" + String(_broker_getpid())
    if worker_idx >= 0:
        out += "-w" + String(worker_idx)
    out += "-" + String(nonce)
    return out^


@always_inline
def sublineage_prefix(base_prefix: String, shard_id: String) -> String:
    """The manifest-lineage key prefix for a writer's sub-lineage.

    Inserts a `_lineage/<shard_id>` segment between the partition's base manifest
    prefix and the `/manifest/<seq>.chunk` + `/_HEAD` layout that
    `CasManifestStore` owns under it:

        <base_prefix>/_lineage/<shard_id>

    where `base_prefix` is the partition's single-lineage manifest prefix
    (`broker_core._manifest_prefix(cluster, topic, partition)` =
     `<cluster>/_meta/topics/<topic>/<partition>`). Each sub-lineage is a PLAIN
    `CasManifestStore` over this distinct prefix — full reuse of the substrate's
    append/read_chunk/cas_gate with NO `CasManifestStore` change. The enumeration
    prefix for the read path is `<base_prefix>/_lineage/` (a LIST
    with delimiter `/` returns each `<shard_id>/` as a common-prefix)."""
    return base_prefix + "/_lineage/" + shard_id


# =============================================================================
# Rebalance trigger reasons — why a fresh assignment pass ran.
# =============================================================================

comptime REBALANCE_NONE: Int = 0  # no change needed (assignment already valid)
comptime REBALANCE_NEW_NODE: Int = 1  # a node joined (live set grew)
comptime REBALANCE_STALE_NODE: Int = 2  # a node went stale/dead (live set shrank)
comptime REBALANCE_PARTITION_COUNT: Int = 3  # P changed (a split/merge landed)
comptime REBALANCE_OPERATOR: Int = 4  # an operator forced a rebalance
comptime REBALANCE_INITIAL: Int = 5  # first-ever assignment (no prior)


# =============================================================================
# Binary-codec constants.
# =============================================================================

# The magic word at the head of every binary assignment body — ASCII "BASS"
# (Broker ASSignment), read little-endian. Guards a wrong / truncated body.
comptime _ASSIGNMENT_MAGIC: Int = 0x42415353
# The binary format version. v3 carries the partition-lifetime MAX-GENERATIONS
# trailer
# APPENDED after the v2 generations trailer. v2 carries the per-partition lease
# GENERATIONS trailer (the writer-lease-epoch fence source-of-truth)
# APPENDED after the v1 owners array. Each trailer is length-prefixed,
# so a v1 reader stops after the owners array, a v2 reader stops after the
# generations trailer, and a v3 reader continues to the max-generations trailer —
# decode_binary tolerates a body ending early (the back-compat contract: an
# omitted gens trailer -> all-zeros, an omitted maxgens trailer -> seeded from
# gens). The decoder rejects an UNKNOWN (future) version; v1/v2/v3 are understood.
comptime _ASSIGNMENT_FORMAT_VERSION: Int = 3
# The previous versions this build still DECODES (back-compat: a persisted v1
# blob has no trailers; a v2 blob has only the generations trailer). encode_binary
# always writes the current version. The decode tests the BYTES (length-prefixed
# trailers), not just the version word, so a v1/v2-version body is also tolerated.
comptime _ASSIGNMENT_FORMAT_VERSION_V1: Int = 1
comptime _ASSIGNMENT_FORMAT_VERSION_V2: Int = 2
# The u16 sentinel an owner index uses for the unassigned ("" owner) partition —
# the no-live-node / over-provisioned-pid state. 0xFFFF caps the node table at
# 65535 real nodes (index 0..0xFFFE), which is the same u16 cap the encoder asserts.
comptime _ASSIGNMENT_UNASSIGNED: Int = 0xFFFF


@always_inline
def _write_rebalance_reason_name[W: Writer](mut writer: W, reason: Int):
    """WRITE what `rebalance_reason_name` returns. ⚠ THIS WRITES; IT DOES NOT RETURN.

    The arms live here so no string constant is ever SELECTED and
    returned. A literal-returning ladder lowers to two parallel
    (pointer, length) constant arrays whose two call-site references
    an `--emit shared-lib` link can bind INDEPENDENTLY — and a pair bound
    CROSSED reads the wrong string, or out of bounds."""
    if reason == REBALANCE_NEW_NODE:
        writer.write(String("new_node"))
        return
    if reason == REBALANCE_STALE_NODE:
        writer.write(String("stale_node"))
        return
    if reason == REBALANCE_PARTITION_COUNT:
        writer.write(String("partition_count"))
        return
    if reason == REBALANCE_OPERATOR:
        writer.write(String("operator"))
        return
    if reason == REBALANCE_INITIAL:
        writer.write(String("initial"))
        return
    writer.write(String("none"))
    return


@always_inline
def rebalance_reason_name(reason: Int) -> String:
    """Human/JSON name for a rebalance-trigger reason."""
    var out = String()
    _write_rebalance_reason_name(out, reason)
    return out^


# =============================================================================
# LiveNode — one node in the cluster's current live set (the heartbeat view).
# =============================================================================


@fieldwise_init
struct LiveNode(Copyable, Movable, Deinitable):
    """One node the coordinator currently considers LIVE (heartbeated within the stale
    threshold). POD-ish value (a String id + two soft-advisory load counters).

    Field layout:
      var node_id: String         — the stable cluster node identity (the same
                                    `node_id` the node reports on every heartbeat;
                                    the assignment is keyed on it). NON-EMPTY.
      var last_heartbeat_us: Int64 — wall-clock micros of this node's most recent
                                    heartbeat (the liveness clock). The coordinator derives
                                    liveness by comparing against `now - stale`.
      var records_served: UInt64  — SOFT-ADVISORY: cumulative records
                                    this node served. Recorded for observability +
                                    licensing; NEVER the basis for ownership.
    """

    var node_id: String
    var last_heartbeat_us: Int64
    var records_served: UInt64

    @staticmethod
    def at(node_id: String, last_heartbeat_us: Int64) -> LiveNode:
        """A node with no reported load (the common heartbeat case)."""
        return LiveNode(
            node_id=node_id,
            last_heartbeat_us=last_heartbeat_us,
            records_served=UInt64(0),
        )


# =============================================================================
# Assignment — the partition->node placement the coordinator computed + persists.
# =============================================================================


struct Assignment(Copyable, Movable, Deinitable):
    """The computed partition->node placement: `owner[pid]` is the node_id that
    SHOULD serve partition `pid`, for every `pid` in `[0, P)`. Plus the reason the
    pass ran (observability) + the live node set it spread across (so a consumer
    can publish the ClusterConfig).

    Field layout:
      var num_partitions: Int     — P (the total partition count assigned).
      var owners: List[String]    — owners[pid] == the node_id serving pid. Length
                                    == num_partitions; every entry NON-EMPTY when
                                    there is >= 1 live node (an empty live set
                                    leaves every owner "" — the no-broker state).
      var node_ids: List[String]  — the sorted live node ids the spread used.
      var reason: Int             — the REBALANCE_* reason this assignment ran.
      var generations: List[Int64] — generations[pid] == the MONOTONE lease
                                    generation for partition pid (the
                                    writer-lease-epoch fence source-of-truth).
                                    INCREMENTED whenever owners[pid] CHANGES vs the
                                    prior assignment (the lease-acquire); STABLE
                                    when the owner is unchanged. Never reset / never
                                    decreases — a displaced owner's last-seen
                                    generation is therefore STRICTLY LESS than the
                                    live one, which is exactly what the manifest
                                    append fence (`writer_lease_epoch <
                                    current_lease_epoch -> FENCED`) rejects. Length
                                    == num_partitions; a decoded LEGACY (v1, no-
                                    generations) body yields all-zeros (back-compat).
      var max_generations: List[Int64] — the PARTITION-LIFETIME high-water of
                                    `generations[pid]` (the merge/split
                                    continuity fix).
                                    max_generations[pid] == the HIGHEST lease
                                    generation partition `pid` has EVER held over
                                    its entire lifetime, NOT just under the current
                                    (possibly shrunk) P. THE KEY DIFFERENCE from
                                    `generations`: this list is NEVER tail-truncated
                                    when P shrinks (a merge) — only padded when P
                                    grows. So a pid that reaches gen 2, is dropped
                                    by a merge (P shrinks), then RE-CREATED by a
                                    resplit (P grows) re-acquires STRICTLY ABOVE its
                                    lifetime high-water (3), never below it (which
                                    would let a displaced gen-2 writer pass the fence
                                    `2 < 1 == False`). Recomputing the generation
                                    from the (truncated) live `generations` array
                                    ALONE is insufficient — that would let a
                                    re-created pid reuse a generation; the high-water is what makes the
                                    lease generation monotone over the partition's
                                    LIFETIME, not just the current P. Length >=
                                    max(num_partitions, prior length); a decoded
                                    LEGACY (v1/v2-without-maxgens) body yields the
                                    `generations` values as the high-water seed.
    """

    var num_partitions: Int
    var owners: List[String]
    var node_ids: List[String]
    var reason: Int
    var generations: List[Int64]
    var max_generations: List[Int64]

    def __init__(
        out self,
        num_partitions: Int,
        var owners: List[String],
        var node_ids: List[String],
        reason: Int,
        var generations: List[Int64] = List[Int64](),
        var max_generations: List[Int64] = List[Int64](),
    ):
        self.num_partitions = num_partitions
        self.owners = owners^
        self.node_ids = node_ids^
        self.reason = reason
        # Generations default to all-zeros when not supplied (the initial pass /
        # a legacy decode / a caller that does not track leases). Pad/truncate to
        # exactly num_partitions so generations[pid] is always addressable.
        self.generations = generations^
        while len(self.generations) < num_partitions:
            self.generations.append(Int64(0))
        while len(self.generations) > num_partitions:
            _ = self.generations.pop()

        # MAX_GENERATIONS — the partition-lifetime
        # high-water. CRITICAL: this is NEVER tail-truncated when P shrinks (a
        # merge). It is seeded from `max_generations` when supplied (carried
        # forward across passes / from a v3 decode), and falls back to the
        # current `generations` when not supplied (a legacy v1/v2 decode or an
        # initial pass — the live generation IS the high-water at that point).
        # We PAD it up to (but never down to) at least num_partitions, and we
        # element-wise raise it to >= the current generation so the high-water
        # never lags the live generation. The NEVER-TRUNCATE is what preserves a
        # dropped pid's generation across a merge -> resplit (the confirmed bug).
        self.max_generations = max_generations^
        if len(self.max_generations) == 0 and len(self.generations) > 0:
            # No high-water supplied: seed it from the live generations (the
            # initial-pass / legacy-decode case — generation == high-water).
            for pid in range(len(self.generations)):
                self.max_generations.append(self.generations[pid])
        # Pad up to at least num_partitions so max_generations[pid] is always
        # addressable for every live pid. We do NOT pop the tail — a longer
        # array (carried from a larger prior P that a merge shrank) RETAINS the
        # dropped pids' lifetime high-water so a resplit re-creates them above it.
        while len(self.max_generations) < num_partitions:
            self.max_generations.append(Int64(0))
        # Element-wise raise the high-water to >= the current generation for
        # every live pid (the live generation can never exceed its own lifetime
        # high-water, but this keeps the invariant total even if a caller passes
        # a stale high-water array).
        for pid in range(len(self.generations)):
            if pid < len(self.max_generations):
                if self.generations[pid] > self.max_generations[pid]:
                    self.max_generations[pid] = self.generations[pid]

    def copy(self) -> Self:
        return Self(
            num_partitions=self.num_partitions,
            owners=self.owners.copy(),
            node_ids=self.node_ids.copy(),
            reason=self.reason,
            generations=self.generations.copy(),
            max_generations=self.max_generations.copy(),
        )

    @always_inline
    def node_count(self) -> Int:
        """The number of live nodes the spread used."""
        return len(self.node_ids)

    def owner_of(self, pid: Int) raises -> String:
        """The node_id that SHOULD serve partition `pid`. Raises on an out-of-
        range pid (a programming error — the caller enumerates `[0, P)`)."""
        if pid < 0 or pid >= len(self.owners):
            raise Error(
                "Assignment.owner_of: pid "
                + String(pid)
                + " out of range [0, "
                + String(len(self.owners))
                + ")"
            )
        return self.owners[pid]

    def partitions_for(self, node_id: String) -> List[UInt32]:
        """The partitions assigned to `node_id`, ascending — the
        `assigned_partitions[]` the coordinator pushes back to that node on its heartbeat
        (the in-process relay reconciles this against its owned set). Empty if the
        node owns nothing (a fresh / over-provisioned node)."""
        var out = List[UInt32]()
        for pid in range(len(self.owners)):
            if self.owners[pid] == node_id:
                out.append(UInt32(pid))
        return out^

    def count_for(self, node_id: String) -> Int:
        """How many partitions `node_id` owns under this assignment."""
        var c = 0
        for pid in range(len(self.owners)):
            if self.owners[pid] == node_id:
                c += 1
        return c

    def generation_of(self, pid: Int) raises -> Int64:
        """The MONOTONE lease generation for partition `pid`. This
        is the `writer_lease_epoch` the partition's CURRENT owner carries on its
        appends; the manifest fence compares it against the live generation. Raises
        on an out-of-range pid (the caller enumerates [0, P))."""
        if pid < 0 or pid >= len(self.generations):
            raise Error(
                "Assignment.generation_of: pid "
                + String(pid)
                + " out of range [0, "
                + String(len(self.generations))
                + ")"
            )
        return self.generations[pid]

    def max_generation_of(self, pid: Int) raises -> Int64:
        """The PARTITION-LIFETIME high-water of the lease generation for `pid`
 — the highest generation pid has EVER held over
        its lifetime, even across a merge that dropped it and a resplit that
        re-created it. >= `generation_of(pid)` always. Raises on an out-of-range
        pid (the caller enumerates [0, P))."""
        if pid < 0 or pid >= len(self.max_generations):
            raise Error(
                "Assignment.max_generation_of: pid "
                + String(pid)
                + " out of range [0, "
                + String(len(self.max_generations))
                + ")"
            )
        return self.max_generations[pid]

    def generations_for(self, node_id: String) -> List[Int64]:
        """The per-partition lease generations for the partitions `node_id` owns,
        POSITIONALLY PARALLEL to `partitions_for(node_id)` — i.e. the generation
        the heartbeat delivers to `node_id` for each of its assigned partitions, so
        the owner learns the `(pid, generation)` lease for every partition it
        serves (the owner stamps `generation` as its
        `writer_lease_epoch` on appends). Empty when the node owns nothing."""
        var out = List[Int64]()
        for pid in range(len(self.owners)):
            if self.owners[pid] == node_id:
                # generations is padded to num_partitions in __init__; pid is in
                # range whenever owners[pid] is (the two lists are co-sized).
                if pid < len(self.generations):
                    out.append(self.generations[pid])
                else:
                    out.append(Int64(0))
        return out^

    # -------------------------------------------------------------------------
    # encode / decode — compact JSON (the persisted form a store keeps as a
    # single CAS'd blob; the FORMAT lives here, not in the store layer).
    # -------------------------------------------------------------------------

    def encode(self) -> String:
        """Serialize to a compact JSON object string. Layout:

          {"p":6,"reason":1,"nodes":["a","b","c"],"owners":["a","b","c","a","b","c"]}

        `owners[pid]` is the node_id serving pid; an unassigned (empty-live-set)
        owner renders as "". Node ids are simple cluster identifiers (no quotes /
        backslashes expected) but are escaped defensively. The store CAS's this
        whole string atomically (a one-row version-CAS for the assignment)."""
        var s = String('{"p":')
        s += String(self.num_partitions)
        s += String(',"reason":')
        s += String(self.reason)
        s += String(',"nodes":[')
        for i in range(len(self.node_ids)):
            if i > 0:
                s += String(",")
            s += _json_quote(self.node_ids[i])
        s += String('],"owners":[')
        for i in range(len(self.owners)):
            if i > 0:
                s += String(",")
            s += _json_quote(self.owners[i])
        s += String('],"gens":[')
        for i in range(len(self.generations)):
            if i > 0:
                s += String(",")
            s += String(self.generations[i])
        # maxgens — the partition-lifetime high-water.
        # Persisted so the prior reconstructed from this blob carries the
        # dropped-pid history across a merge -> resplit (it can be LONGER than
        # "gens" when a merge shrank P but retained the dropped pids' watermark).
        s += String('],"maxgens":[')
        for i in range(len(self.max_generations)):
            if i > 0:
                s += String(",")
            s += String(self.max_generations[i])
        s += String("]}")
        return s^

    @staticmethod
    def decode(text: String) raises -> Assignment:
        """Parse the compact JSON written by `encode` (byte-level forward scan —
        the writer is the only producer of this format; same discipline as
        PartitionMap.decode). Raises on a missing field / malformed body."""
        var bytes = _to_byte_list(text)

        var p_at = _abytes_find_after(bytes, String('"p":'), 0)
        if p_at < 0:
            raise Error("Assignment.decode: missing 'p' field")
        var p_val = _aparse_int_at(bytes, p_at)

        var r_at = _abytes_find_after(bytes, String('"reason":'), 0)
        var reason_val = REBALANCE_NONE
        if r_at >= 0:
            reason_val = _aparse_int_at(bytes, r_at)

        var nodes_open = _abytes_find_after(bytes, String('"nodes":['), 0)
        if nodes_open < 0:
            raise Error("Assignment.decode: missing 'nodes' field")
        var nodes_close = _afind_array_close(bytes, nodes_open)
        var node_ids = _aparse_string_array(bytes, nodes_open, nodes_close)

        var owners_open = _abytes_find_after(bytes, String('"owners":['), 0)
        if owners_open < 0:
            raise Error("Assignment.decode: missing 'owners' field")
        var owners_close = _afind_array_close(bytes, owners_open)
        var owners = _aparse_string_array(bytes, owners_open, owners_close)

        # generations — OPTIONAL for back-compat: a legacy blob
        # with no "gens" field decodes as all-zeros (the Assignment ctor pads).
        var gens = List[Int64]()
        var gens_open = _abytes_find_after(bytes, String('"gens":['), 0)
        if gens_open >= 0:
            var gens_close = _afind_array_close(bytes, gens_open)
            gens = _aparse_int_array(bytes, gens_open, gens_close)

        # maxgens — OPTIONAL: a legacy/v2 blob with no
        # "maxgens" field seeds the high-water from `gens` (the ctor does this).
        var maxgens = List[Int64]()
        var maxgens_open = _abytes_find_after(bytes, String('"maxgens":['), 0)
        if maxgens_open >= 0:
            var maxgens_close = _afind_array_close(bytes, maxgens_open)
            maxgens = _aparse_int_array(bytes, maxgens_open, maxgens_close)

        return Assignment(
            num_partitions=p_val,
            owners=owners^,
            node_ids=node_ids^,
            reason=reason_val,
            generations=gens^,
            max_generations=maxgens^,
        )

    # -------------------------------------------------------------------------
    # encode_binary / decode_binary — the COMPACT BINARY persisted form (the
    # object-store CAS store body). The format lives HERE next to the JSON
    # encode/decode (the comment above — "the FORMAT lives here, not in the store
    # layer"). Binary is smaller + decode-cheaper than the JSON: node-ids are
    # INTERNED once (the node table) and `owners[pid]` is a u16 INDEX into that
    # table (0xFFFF == the unassigned "" owner), NOT a P-deep list of full node-id
    # string copies. The store CAS's the whole byte body atomically (If-Match).
    #
    # WIRE LAYOUT (all integers little-endian, length-prefixed):
    #   magic           u32   == 0x42415353  ("BASS" — Broker ASSignment)
    #   format_version  u16   == 1            (reject unknown versions)
    #   reserved        u16   == 0            (forward-compat flags word)
    #   num_partitions  i32                   (P; the assigned partition count)
    #   reason          i32                   (the REBALANCE_* trigger)
    #   node_count      u32   (== N)
    #   node table      N x [ len u16 | bytes (UTF-8 node_id) ]
    #   owners_count    u32   (== P)
    #   owners          P x u16 (index into the node table; 0xFFFF == unassigned)
    #
    # FORWARD-COMPAT: the magic guards a wrong body; the version rejects an
    # unknown future format; the `reserved` flags word + the length-prefixed
    # sub-records let a v2 append fields a v1 reader skips by prefix. u16 caps
    # N / P at 65535 (the encoder asserts; a v2 can widen the owner index to u32
    # if ever needed — the magic+version make that a clean break).
    # -------------------------------------------------------------------------

    def encode_binary(self) raises -> List[UInt8]:
        """Serialize to the compact binary body (the S3-CAS store form). Interns
        node-ids once into a node table; `owners[pid]` is encoded as a u16 index
        into that table (0xFFFF for the unassigned "" owner). Raises if N or P
        exceeds the u16 cap (65535) — an impossible cluster size here, asserted
        so a silent truncation can never corrupt the body."""
        # The node table is `self.node_ids` (the sorted live ids the spread used).
        # owners[pid] resolves to an index into this table; "" -> 0xFFFF.
        var n_nodes = len(self.node_ids)
        var n_owners = len(self.owners)
        if n_nodes > 0xFFFF:
            raise Error(
                "Assignment.encode_binary: node_count "
                + String(n_nodes)
                + " exceeds the u16 cap (65535)"
            )
        if n_owners > 0xFFFF:
            raise Error(
                "Assignment.encode_binary: owners_count "
                + String(n_owners)
                + " exceeds the u16 cap (65535)"
            )

        var out = List[UInt8]()
        _put_u32(out, UInt32(_ASSIGNMENT_MAGIC))
        _put_u16(out, UInt16(_ASSIGNMENT_FORMAT_VERSION))
        _put_u16(out, UInt16(0))  # reserved flags word
        _put_i32(out, Int32(self.num_partitions))
        _put_i32(out, Int32(self.reason))

        # Node table.
        _put_u32(out, UInt32(n_nodes))
        for i in range(n_nodes):
            var nb = self.node_ids[i].as_bytes()
            var nlen = len(nb)
            if nlen > 0xFFFF:
                raise Error(
                    "Assignment.encode_binary: node_id length "
                    + String(nlen)
                    + " exceeds the u16 cap"
                )
            _put_u16(out, UInt16(nlen))
            for j in range(nlen):
                out.append(nb[j])

        # Owners (u16 index into the node table; 0xFFFF == unassigned).
        _put_u32(out, UInt32(n_owners))
        for pid in range(n_owners):
            var owner = self.owners[pid]
            var idx = _ASSIGNMENT_UNASSIGNED
            if owner.byte_length() > 0:
                var found = _index_of(self.node_ids, owner)
                # An owner that is not in the node table is a malformed
                # assignment (the pass always spreads onto node_ids). Defensive:
                # encode as unassigned rather than corrupt the index.
                if found >= 0:
                    idx = found
            _put_u16(out, UInt16(idx))

        # GENERATIONS TRAILER — `generations_count u32` then
        # P x i64 (LE). APPENDED after the owners array: a v1 reader stops at the
        # owners array (the body simply ends there); a v2 reader continues and
        # reads the trailer. The count is co-sized with P (the ctor pads), so this
        # is exactly P i64s. This is the writer-lease-epoch fence source-of-truth.
        var n_gens = len(self.generations)
        _put_u32(out, UInt32(n_gens))
        for pid in range(n_gens):
            _put_i64(out, self.generations[pid])

        # MAX-GENERATIONS TRAILER —
        # `max_generations_count u32` then count x i64 (LE). APPENDED after the
        # generations trailer. A v2 reader stops after the generations trailer;
        # a v3 reader continues. CRITICAL: this count can be LONGER than P (a
        # merge shrank P but the high-water retained the dropped pids' watermark),
        # so we emit len(self.max_generations), NOT P. This is the partition-
        # lifetime high-water that makes the lease generation monotone across a
        # merge -> resplit (the confirmed Slice-A continuity fix).
        var n_maxgens = len(self.max_generations)
        _put_u32(out, UInt32(n_maxgens))
        for pid in range(n_maxgens):
            _put_i64(out, self.max_generations[pid])
        return out^

    @staticmethod
    def decode_binary(body: List[UInt8]) raises -> Assignment:
        """Parse the compact binary body written by `encode_binary`. Validates
        the magic + version + length prefixes; raises on a bad magic, an unknown
        version, a truncated body, or an owner index out of the node table range.
        Reconstructs `owners` as full node-id strings (0xFFFF -> the "" owner)."""
        var pos = 0
        var magic = _read_u32(body, pos)
        pos += 4
        if magic != UInt32(_ASSIGNMENT_MAGIC):
            raise Error(
                "Assignment.decode_binary: bad magic 0x"
                + _hex32(magic)
                + " (expected 0x42415353 'BASS')"
            )
        var version = _read_u16(body, pos)
        pos += 2
        # v1 (no trailers), v2 (generations trailer), and v3 (generations +
        # max-generations trailers) are all understood (back-compat). Any other
        # version is rejected.
        if (
            version != UInt16(_ASSIGNMENT_FORMAT_VERSION)
            and version != UInt16(_ASSIGNMENT_FORMAT_VERSION_V1)
            and version != UInt16(_ASSIGNMENT_FORMAT_VERSION_V2)
        ):
            raise Error(
                "Assignment.decode_binary: unknown format_version "
                + String(Int(version))
                + " (this build understands versions "
                + String(_ASSIGNMENT_FORMAT_VERSION_V1)
                + ", "
                + String(_ASSIGNMENT_FORMAT_VERSION_V2)
                + ", and "
                + String(_ASSIGNMENT_FORMAT_VERSION)
                + ")"
            )
        _ = _read_u16(body, pos)  # reserved flags word (ignored at v1)
        pos += 2
        var num_partitions = Int(_read_i32(body, pos))
        pos += 4
        var reason = Int(_read_i32(body, pos))
        pos += 4

        # Node table.
        var n_nodes = Int(_read_u32(body, pos))
        pos += 4
        var node_ids = List[String]()
        for _ in range(n_nodes):
            var nlen = Int(_read_u16(body, pos))
            pos += 2
            if pos + nlen > len(body):
                raise Error(
                    "Assignment.decode_binary: truncated node table"
                    " (need " + String(nlen) + " bytes at " + String(pos) + ")"
                )
            var s = String("")
            for j in range(nlen):
                s += chr(Int(body[pos + j]))
            pos += nlen
            node_ids.append(s^)

        # Owners (u16 index into the node table; 0xFFFF == unassigned).
        var n_owners = Int(_read_u32(body, pos))
        pos += 4
        var owners = List[String]()
        for _ in range(n_owners):
            var idx = Int(_read_u16(body, pos))
            pos += 2
            if idx == _ASSIGNMENT_UNASSIGNED:
                owners.append(String(""))
            elif idx < 0 or idx >= n_nodes:
                raise Error(
                    "Assignment.decode_binary: owner index "
                    + String(idx)
                    + " out of node-table range [0, "
                    + String(n_nodes)
                    + ")"
                )
            else:
                owners.append(node_ids[idx])

        # GENERATIONS TRAILER. Read it iff there are MORE
        # bytes after the owners array (a v2 body) — a v1 body ends right here, so
        # `pos >= len(body)` leaves generations empty (the ctor pads to all-zeros).
        # We test the BYTES, not just the version word, so a v1-version body is
        # also tolerated. The trailer is `generations_count u32` then count x i64.
        var generations = List[Int64]()
        if pos + 4 <= len(body):
            var n_gens = Int(_read_u32(body, pos))
            pos += 4
            for _ in range(n_gens):
                generations.append(_read_i64(body, pos))
                pos += 8

        # MAX-GENERATIONS TRAILER. Read it iff there
        # are STILL more bytes after the generations trailer (a v3 body) — a v1/v2
        # body ends after the generations trailer, so this leaves max_generations
        # empty (the ctor seeds it from `generations`, the back-compat contract).
        # The trailer is `max_generations_count u32` then count x i64. The count
        # can be LONGER than P (a merge retained dropped pids' watermark).
        var max_generations = List[Int64]()
        if pos + 4 <= len(body):
            var n_maxgens = Int(_read_u32(body, pos))
            pos += 4
            for _ in range(n_maxgens):
                max_generations.append(_read_i64(body, pos))
                pos += 8

        return Assignment(
            num_partitions=num_partitions,
            owners=owners^,
            node_ids=node_ids^,
            reason=reason,
            generations=generations^,
            max_generations=max_generations^,
        )

    def is_even(self) -> Bool:
        """True iff the spread is the most-balanced integer split: every live
        node serves floor(P/N) or ceil(P/N) partitions. (P==0 or N==0 trivially
        even)."""
        var n = len(self.node_ids)
        if n == 0:
            return True
        var lo = self.num_partitions // n
        var hi = lo + (1 if self.num_partitions % n != 0 else 0)
        for i in range(n):
            var c = self.count_for(self.node_ids[i])
            if c < lo or c > hi:
                return False
        return True

    # -------------------------------------------------------------------------
    # view — the ZERO-COPY read path. Validate the header, then
    # return an `AssignmentView` that BORROWS `body` (origin-tied) and reads every
    # field DIRECTLY from the bytes — NO List allocation, NO re-parse. The owned
    # `decode_binary` above stays for the cache / where ownership is needed; this
    # is the transient hot read (in-DC the object-store RTT is sub-ms, so the
    # parse cost the owned decode pays — a P-deep List[String] of node-id copies —
    # is a real fraction of a read; viewing the bytes in place removes it).
    # -------------------------------------------------------------------------
    @staticmethod
    def view[origin: Origin[mut=False]](
        body: Span[UInt8, origin]
    ) raises -> AssignmentView[origin]:
        """Borrow `body` and return a zero-copy `AssignmentView` over it. Validates
        the magic + version + that the header + node table + owners array all fit
        within the buffer (so every later in-place read is in bounds). Raises on a
        bad magic / unknown version / a truncated body — exactly the contract
        `decode_binary` enforces, but WITHOUT materializing any List. The returned
        view's lifetime is tied to `body` via `origin` (the compiler rejects any
        use after `body` drops); it must not outlive the buffer it borrows."""
        return AssignmentView[origin](body)


# =============================================================================
# AssignmentView — the ZERO-COPY read over a persisted binary body.
# =============================================================================
#
# A read-only window onto an `Assignment.encode_binary()` body that reads every
# field DIRECTLY from the borrowed bytes — NO List allocation, NO re-parse. The
# view BORROWS the buffer for its lifetime via the `origin` parameter (a concrete
# immutable origin tied to the source `Span`, NOT a wildcard origin) — the
# compiler rejects any use of the view after the buffer drops, so the view can
# never dangle. This is the canonical zero-copy view shape (cf.
# `AvroByteReader[origin]` in komira_avro).
#
# WHAT IS ZERO-COPY:
#   * The header scalars (P, reason, node_count) are read once at construction
#     and cached as plain Int fields (8 bytes each, no heap).
#   * `owners_bytes()` returns a `Span[UInt8, origin]` OVER THE SOURCE BODY (the
#     P*2 owner-index bytes) — the SAME bytes, not a fresh List.
#   * `owner_index(pid)` reads the u16 LE at `owners_off + pid*2` directly from
#     the body — O(1), no allocation.
#   * `node(i)` returns a `StringSlice[origin]` that points INTO the body (the
#     node table is walked from its start; O(i) for a tiny node set, no copy).
#   * `owner(pid)` composes the two: read the index, then slice the node — the
#     unassigned 0xFFFF sentinel yields the empty slice.
#
# WHAT IS NOT cached: the per-node offsets are NOT precomputed into a List (that
# would re-introduce a heap allocation and a stale-pointer hazard if this view were
# ever byte-slabbed — it is not, it is a stack/transient value). The node table
# is tiny (broker clusters are single/double-digit nodes), so the on-demand walk
# is cheap and keeps the view a pure Span + scalar-Int aggregate.
#
# ENCAPSULATION: zero UnsafePointer crosses any boundary; all byte arithmetic is
# in this struct's private methods with `# SAFETY:` comments and is bounds-checked
# against `len(self._body)` (the header validation at construction guarantees the
# node table + owners array fit, so the per-field reads are in range).
# =============================================================================


struct AssignmentView[origin: Origin[mut=False]](Copyable, Movable):
    """A zero-copy read window onto an `encode_binary` body.

    Borrows the source bytes for its lifetime (`origin`-parametric, NOT a wildcard
    origin) and reads P / reason / node-count / per-pid owner index / node strings
    / per-pid owner slice DIRECTLY from the buffer — no List allocation, no
    re-parse. Construct via `Assignment.view(body)` (which validates the header).

    Field layout (all plain values — no pointer crosses any boundary):
      var _body: Span[UInt8, origin]  — the borrowed binary body.
      var _num_partitions: Int        — P (cached from the header).
      var _reason: Int                — the REBALANCE_* reason (cached).
      var _node_count: Int            — N (cached).
      var _nodes_off: Int             — byte offset where the node table starts.
      var _owners_off: Int            — byte offset where the owners u16 array
                                        starts (after the node table + the
                                        owners_count u32).
    """

    var _body: Span[UInt8, Self.origin]
    var _num_partitions: Int
    var _reason: Int
    var _node_count: Int
    var _nodes_off: Int
    var _owners_off: Int
    # The v2 generations trailer. `_gens_off` is the byte offset
    # of the i64 array (after owners + the generations_count u32), or -1 when no
    # trailer is present (a v1 body — every generation reads as 0). `_gens_count`
    # is the count of i64s in the trailer (0 when absent).
    var _gens_off: Int
    var _gens_count: Int
    # The v3 max-generations trailer. `_maxgens_off` is
    # the byte offset of the i64 array (after the generations trailer + the
    # max_generations_count u32), or -1 when no trailer is present (a v1/v2 body —
    # max_generation(pid) falls back to generation(pid)). `_maxgens_count` is the
    # count of i64s in the trailer (can be LONGER than P — a merge retained
    # dropped pids' watermark).
    var _maxgens_off: Int
    var _maxgens_count: Int

    def __init__(out self, body: Span[UInt8, Self.origin]) raises:
        """Validate the header + the node table + owners array bounds, then cache
        the offsets. Raises on a bad magic / unknown version / truncated body —
        the SAME contract `decode_binary` enforces, with NO List materialized."""
        self._body = body

        # --- header (fixed 20-byte prefix) ----------------------------------
        var magic = _vread_u32(body, 0)
        if magic != UInt32(_ASSIGNMENT_MAGIC):
            raise Error(
                "AssignmentView: bad magic 0x"
                + _hex32(magic)
                + " (expected 0x42415353 'BASS')"
            )
        var version = _vread_u16(body, 4)
        # v1 (no trailers), v2 (generations trailer), and v3 (generations +
        # max-generations trailers) are all understood (back-compat). Any other
        # version is rejected.
        if (
            version != UInt16(_ASSIGNMENT_FORMAT_VERSION)
            and version != UInt16(_ASSIGNMENT_FORMAT_VERSION_V1)
            and version != UInt16(_ASSIGNMENT_FORMAT_VERSION_V2)
        ):
            raise Error(
                "AssignmentView: unknown format_version "
                + String(Int(version))
                + " (this build understands versions "
                + String(_ASSIGNMENT_FORMAT_VERSION_V1)
                + ", "
                + String(_ASSIGNMENT_FORMAT_VERSION_V2)
                + ", and "
                + String(_ASSIGNMENT_FORMAT_VERSION)
                + ")"
            )
        # bytes 6..8 reserved (ignored at v1)
        self._num_partitions = Int(_vread_i32(body, 8))
        self._reason = Int(_vread_i32(body, 12))
        self._node_count = Int(_vread_u32(body, 16))

        # --- node table: walk it ONCE to find where the owners array starts.
        # We do not allocate; we only advance an offset past each
        # `[len u16 | bytes]` record, bounds-checking each step. This is O(N)
        # over the tiny node set and validates the whole table fits.
        self._nodes_off = 20
        var pos = self._nodes_off
        for _ in range(self._node_count):
            var nlen = Int(_vread_u16(body, pos))
            pos += 2
            # SAFETY: bounds-check the node string body before skipping it (so a
            # later node(i) walk can never read past the buffer).
            if pos + nlen > len(body):
                raise Error(
                    "AssignmentView: truncated node table (need "
                    + String(nlen)
                    + " bytes at "
                    + String(pos)
                    + ")"
                )
            pos += nlen

        # --- owners array: owners_count u32 then P x u16. Cache where the u16
        # array starts and bounds-check that all P*2 bytes are present.
        var owners_count = Int(_vread_u32(body, pos))
        pos += 4
        self._owners_off = pos
        # SAFETY: verify the full owners array is in range so owner_index(pid)
        # and owners_bytes() are always reading committed bytes.
        if self._owners_off + owners_count * 2 > len(body):
            raise Error(
                "AssignmentView: truncated owners array (need "
                + String(owners_count * 2)
                + " bytes at "
                + String(self._owners_off)
                + ")"
            )
        pos = self._owners_off + owners_count * 2

        # --- generations trailer. Present iff MORE bytes
        # follow the owners array (a v2 body). A v1 body ends here -> no trailer
        # (_gens_off = -1, every generation reads as 0). The trailer is
        # `generations_count u32` then count x i64; bounds-check it fully fits.
        self._gens_off = -1
        self._gens_count = 0
        if pos + 4 <= len(body):
            var gens_count = Int(_vread_u32(body, pos))
            pos += 4
            # SAFETY: verify the full i64 array is in range so generation(pid)
            # only ever reads committed bytes.
            if pos + gens_count * 8 > len(body):
                raise Error(
                    "AssignmentView: truncated generations array (need "
                    + String(gens_count * 8)
                    + " bytes at "
                    + String(pos)
                    + ")"
                )
            self._gens_off = pos
            self._gens_count = gens_count
            pos = self._gens_off + gens_count * 8

        # --- max-generations trailer. Present iff
        # STILL more bytes follow the generations trailer (a v3 body). A v1/v2
        # body ends here -> no trailer (_maxgens_off = -1, max_generation(pid)
        # falls back to generation(pid)). The trailer is `max_generations_count
        # u32` then count x i64; bounds-check it fully fits.
        self._maxgens_off = -1
        self._maxgens_count = 0
        if pos + 4 <= len(body):
            var maxgens_count = Int(_vread_u32(body, pos))
            pos += 4
            # SAFETY: verify the full i64 array is in range so max_generation(pid)
            # only ever reads committed bytes.
            if pos + maxgens_count * 8 > len(body):
                raise Error(
                    "AssignmentView: truncated max-generations array (need "
                    + String(maxgens_count * 8)
                    + " bytes at "
                    + String(pos)
                    + ")"
                )
            self._maxgens_off = pos
            self._maxgens_count = maxgens_count

    @always_inline
    def num_partitions(self) -> Int:
        """P — the assigned partition count (cached from the header)."""
        return self._num_partitions

    @always_inline
    def reason(self) -> Int:
        """The REBALANCE_* trigger reason this assignment ran (cached)."""
        return self._reason

    @always_inline
    def node_count(self) -> Int:
        """N — the number of live nodes in the node table (cached)."""
        return self._node_count

    @always_inline
    def owners_offset(self) -> Int:
        """The byte offset in the body where the owners u16 array starts. Exposed
        so a caller (or a test) can confirm the owners are read IN PLACE."""
        return self._owners_off

    def owners_bytes(self) -> Span[UInt8, Self.origin]:
        """A `Span` over the raw owners array (P * u16 LE) — the SAME bytes inside
        the borrowed body, NOT a fresh List. This is the zero-copy core: the owner
        indices are never materialized; a consumer reads them in place."""
        # SAFETY: the constructor bounds-checked that [_owners_off, _owners_off +
        # P*2) is within the body, so this slice is in range. The slice carries
        # the body's `origin`, so it cannot outlive the buffer.
        return self._body[self._owners_off : self._owners_off + self._num_partitions * 2]

    @always_inline
    def owner_index(self, pid: Int) raises -> UInt16:
        """The raw u16 owner index for `pid` (0xFFFF == the unassigned "" owner),
        read DIRECTLY from the body — O(1), no allocation. Raises on an out-of-
        range pid (the caller enumerates [0, P))."""
        if pid < 0 or pid >= self._num_partitions:
            raise Error(
                "AssignmentView.owner_index: pid "
                + String(pid)
                + " out of range [0, "
                + String(self._num_partitions)
                + ")"
            )
        # SAFETY: the per-pid u16 is within the bounds-checked owners array.
        return _vread_u16(self._body, self._owners_off + pid * 2)

    def node(self, i: Int) raises -> StringSlice[Self.origin]:
        """The i-th node id as a `StringSlice` that points INTO the borrowed body
        (zero-copy — no String allocation). Walks the node table from its start
        (O(i) over the tiny node set). Raises on an out-of-range index."""
        if i < 0 or i >= self._node_count:
            raise Error(
                "AssignmentView.node: index "
                + String(i)
                + " out of range [0, "
                + String(self._node_count)
                + ")"
            )
        # Walk to the i-th `[len u16 | bytes]` record.
        var pos = self._nodes_off
        for _ in range(i):
            var skip = Int(_vread_u16(self._body, pos))
            pos += 2 + skip
        var nlen = Int(_vread_u16(self._body, pos))
        pos += 2
        # SAFETY: the constructor validated the whole node table fits, so the
        # [pos, pos+nlen) slice is in range; the slice carries `origin` and is a
        # borrow into the body (cannot dangle).
        return StringSlice(unsafe_from_utf8=self._body[pos : pos + nlen])

    def owner(self, pid: Int) raises -> StringSlice[Self.origin]:
        """The node id serving `pid` as a zero-copy `StringSlice` into the body
        (the empty slice for the unassigned 0xFFFF owner). Composes
        `owner_index` + `node` — both in-place reads, no allocation."""
        var idx = Int(self.owner_index(pid))
        if idx == _ASSIGNMENT_UNASSIGNED:
            # The unassigned "" owner: an empty slice over the (committed) header
            # byte 0 — length 0, so it reads nothing.
            return StringSlice(unsafe_from_utf8=self._body[0:0])
        if idx < 0 or idx >= self._node_count:
            raise Error(
                "AssignmentView.owner: owner index "
                + String(idx)
                + " out of node-table range [0, "
                + String(self._node_count)
                + ") for pid "
                + String(pid)
            )
        return self.node(idx)

    @always_inline
    def generation(self, pid: Int) raises -> Int64:
        """The MONOTONE lease generation for partition `pid`,
        read DIRECTLY from the v2 trailer — O(1), no allocation. A LEGACY (v1)
        body has no trailer, so every generation reads as 0 (the back-compat
        contract). Raises on an out-of-range pid (the caller enumerates [0, P))."""
        if pid < 0 or pid >= self._num_partitions:
            raise Error(
                "AssignmentView.generation: pid "
                + String(pid)
                + " out of range [0, "
                + String(self._num_partitions)
                + ")"
            )
        # No trailer (v1 body) or pid beyond the trailer -> 0.
        if self._gens_off < 0 or pid >= self._gens_count:
            return Int64(0)
        # SAFETY: the per-pid i64 is within the bounds-checked generations array.
        return _vread_i64(self._body, self._gens_off + pid * 8)

    @always_inline
    def max_generation(self, pid: Int) raises -> Int64:
        """The PARTITION-LIFETIME high-water of the lease generation for `pid`,
        read DIRECTLY from the v3 trailer — O(1), no
        allocation. A LEGACY (v1/v2) body has no max-generations trailer, so this
        falls back to `generation(pid)` (the high-water == the live generation at
        that point — the back-compat contract). The max-generations trailer can
        be LONGER than P, so the read accepts a pid in [0, _maxgens_count)."""
        if pid < 0:
            raise Error(
                "AssignmentView.max_generation: pid "
                + String(pid)
                + " out of range"
            )
        # No trailer (v1/v2 body) or pid beyond the trailer -> fall back to the
        # live generation (only valid for pid < P; the ctor seeds the rest).
        if self._maxgens_off < 0 or pid >= self._maxgens_count:
            if pid < self._num_partitions:
                return self.generation(pid)
            return Int64(0)
        # SAFETY: the per-pid i64 is within the bounds-checked max-generations
        # array.
        return _vread_i64(self._body, self._maxgens_off + pid * 8)

    @always_inline
    def max_generations_count(self) -> Int:
        """The number of i64s in the v3 max-generations trailer (0 for a v1/v2
        body). Can be LONGER than P (a merge retained dropped pids' watermark)."""
        return self._maxgens_count

    def to_owned(self) raises -> Assignment:
        """Materialize the view into an OWNED `Assignment` (the cache path: view
        zero-copy on the hot read, copy into an owned value only where retention
        is needed). This DOES allocate (it builds the node_ids + owners +
        generations + max_generations Lists) — it is the explicit opt-in to
        ownership, the opposite of the zero-copy read; the hot path never calls
        it."""
        var node_ids = List[String]()
        for i in range(self._node_count):
            node_ids.append(String(self.node(i)))
        var owners = List[String]()
        for pid in range(self._num_partitions):
            owners.append(String(self.owner(pid)))
        var generations = List[Int64]()
        for pid in range(self._num_partitions):
            generations.append(self.generation(pid))
        # The high-water can be LONGER than P (a merge retained dropped pids'
        # watermark) — materialize the FULL trailer so the owned value carries
        # the dropped-pid history forward (the Slice-A continuity invariant).
        var max_generations = List[Int64]()
        var maxgens_n = self._maxgens_count
        if maxgens_n < self._num_partitions:
            maxgens_n = self._num_partitions
        for pid in range(maxgens_n):
            max_generations.append(self.max_generation(pid))
        return Assignment(
            num_partitions=self._num_partitions,
            owners=owners^,
            node_ids=node_ids^,
            reason=self._reason,
            generations=generations^,
            max_generations=max_generations^,
        )


# =============================================================================
# Liveness — split a heartbeat-reported node set into live vs stale.
# =============================================================================


def is_node_live(
    last_heartbeat_us: Int64, now_us: Int64, stale_threshold_us: Int64
) -> Bool:
    """A node is LIVE iff its most recent heartbeat is within `stale_threshold_us`
    of `now`. The cutoff is `now - stale` (an absolute cutoff, not a
    per-node elapsed-time comparison). A node that
    has not heartbeated since the cutoff is STALE (treated dead for assignment)."""
    return last_heartbeat_us >= (now_us - stale_threshold_us)


def live_node_ids(
    nodes: List[LiveNode], now_us: Int64, stale_threshold_us: Int64
) -> List[String]:
    """The sorted node_ids that are LIVE at `now` (heartbeated within `stale`).
    SORTED ascending so the assignment is deterministic across replicas. Stale
    nodes are dropped (their partitions reassign — REBALANCE_STALE_NODE)."""
    var ids = List[String]()
    for i in range(len(nodes)):
        if is_node_live(nodes[i].last_heartbeat_us, now_us, stale_threshold_us):
            ids.append(nodes[i].node_id)
    _sort_strings(ids)
    return ids^


# =============================================================================
# assign_partitions — THE PURE ASSIGNMENT PASS (even-spread + sticky-min-move).
# =============================================================================


def assign_partitions(
    live_node_ids_sorted: List[String],
    num_partitions: Int,
    prior: Optional[Assignment],
    reason: Int,
) raises -> Assignment:
    """Compute the partition->node placement for `num_partitions` (P) over the
    sorted live node set, keeping a partition on its prior still-live owner
    whenever even-spread permits (sticky / minimal-move).

    ALGORITHM (two passes):
      capacity[node] = ceil(P/N) for the first (P mod N) nodes (lexicographic),
                       floor(P/N) for the rest. This is the per-node quota of the
                       most-balanced integer split.
      PASS 1 (stick): for each pid in [0, P), if `prior` assigned pid to a node
        that is STILL LIVE and that node has remaining capacity, keep it there
        (decrement that node's remaining capacity). This pins the maximal set of
        partitions that can stay put without breaking even-spread.
      PASS 2 (fill): assign every still-unassigned pid (a fresh pid, a pid whose
        prior owner died, or a pid shed from an over-quota node) to live nodes
        with remaining capacity, in ascending node order, ascending pid order.
        This is deterministic + fills exactly to the per-node quota, so the result
        is even-spread by construction.

    With no `prior` (REBALANCE_INITIAL) PASS 1 is a no-op and PASS 2 lays down the
    canonical round-robin-by-quota assignment.

    An EMPTY live set (no broker nodes up) yields every owner "" (the no-broker
    state — nothing is served; a producer's Metadata refresh sees no leader and
    backs off). P==0 (no partitions) yields an empty owners list.

    Raises on a negative P (a programming error)."""
    if num_partitions < 0:
        raise Error(
            "assign_partitions: num_partitions must be >= 0 (got "
            + String(num_partitions)
            + ")"
        )

    var node_ids = live_node_ids_sorted.copy()
    var n = len(node_ids)

    # Empty live set: nothing can be served. Every owner is "".
    if n == 0:
        var owners_empty = List[String]()
        for _ in range(num_partitions):
            owners_empty.append(String(""))
        # Generations carry forward from the prior (no live owner = no acquire to
        # bump; a partition that goes to "" loses its owner but the generation is
        # only meaningful for the next REAL acquire — keep it monotone). When a
        # prior owner existed and is now "", that IS a change, so bump (so the
        # next acquirer's generation is strictly above the displaced owner's).
        var gens_empty = _compute_generations(owners_empty, prior)
        var ge_live = gens_empty[0].copy()
        var ge_max = gens_empty[1].copy()
        return Assignment(
            num_partitions=num_partitions,
            owners=owners_empty^,
            node_ids=node_ids^,
            reason=reason,
            generations=ge_live^,
            max_generations=ge_max^,
        )

    # Per-node quota of the most-balanced integer split (the even-spread target).
    # The first `extra` nodes (lexicographically) get base+1; the rest get base.
    var base = num_partitions // n
    var extra = num_partitions % n
    var remaining = List[Int]()  # remaining[i] = capacity left for node_ids[i]
    for i in range(n):
        remaining.append(base + 1 if i < extra else base)

    # owners[pid], "" == unassigned-so-far.
    var owners = List[String]()
    for _ in range(num_partitions):
        owners.append(String(""))

    # PASS 1 — STICK: keep a partition on its prior still-live owner if that node
    # still has remaining capacity.
    if prior:
        ref p = prior.value()
        var prior_len = len(p.owners)
        for pid in range(num_partitions):
            if pid >= prior_len:
                continue  # a new pid (P grew) — no prior owner to stick.
            var prev_owner = p.owners[pid]
            if prev_owner.byte_length() == 0:
                continue
            var idx = _index_of(node_ids, prev_owner)
            if idx < 0:
                continue  # prior owner is no longer live — must move.
            if remaining[idx] > 0:
                owners[pid] = prev_owner
                remaining[idx] = remaining[idx] - 1

    # PASS 2 — FILL: assign every still-unassigned pid to the next live node with
    # remaining capacity (ascending node order, ascending pid order).
    var fill_cursor = 0
    for pid in range(num_partitions):
        if owners[pid].byte_length() > 0:
            continue
        # Advance to the next node with capacity (wrap is impossible — total
        # remaining capacity == #unassigned by construction).
        while fill_cursor < n and remaining[fill_cursor] <= 0:
            fill_cursor += 1
        if fill_cursor >= n:
            # Defensive: capacity must always cover the unassigned count.
            raise Error(  # cov: unreachable the quotas sum to P and each pid takes one slot, so a slot is always left
                "assign_partitions: ran out of node capacity at pid "  # cov: unreachable see the line above
                + String(pid)  # cov: unreachable see the line above
                + " (invariant violated — capacity should equal P)"  # cov: unreachable see the line above
            )
        owners[pid] = node_ids[fill_cursor]
        remaining[fill_cursor] = remaining[fill_cursor] - 1

    # LEASE GENERATIONS — bump-on-transfer. A partition whose
    # owner CHANGED vs the prior assignment gets a fresh (incremented) generation
    # (the lease-acquire); an unchanged owner keeps its generation. This is what
    # makes a displaced owner's last-seen generation STRICTLY LESS than the live
    # one — the exact precondition the manifest append fence rejects.
    var generations = _compute_generations(owners, prior)
    var g_live = generations[0].copy()
    var g_max = generations[1].copy()

    return Assignment(
        num_partitions=num_partitions,
        owners=owners^,
        node_ids=node_ids^,
        reason=reason,
        generations=g_live^,
        max_generations=g_max^,
    )


# =============================================================================
# _compute_generations — the bump-on-transfer lease-generation pass.
#   PARTITION-LIFETIME MONOTONE (the merge/split continuity fix).
# =============================================================================


def _compute_generations(
    owners: List[String], prior: Optional[Assignment]
) -> Tuple[List[Int64], List[Int64]]:
    """Compute the per-partition lease generations for a freshly-computed `owners`
    list, given the `prior` assignment. The rule is now
    PARTITION-LIFETIME MONOTONE (never reset, never decreases below ANY generation
    that pid EVER held — even across a merge that dropped the pid and a resplit
    that re-created it):

      For each pid, let `floor` = the prior partition-LIFETIME high-water
      (`prior.max_generations[pid]` — which SURVIVES a merge truncate because the
      Assignment ctor never tail-truncates `max_generations`; for a never-owned /
      legacy pid the floor is 0).

      * UNCHANGED owner (owners[pid] == prior.owners[pid], owner present in the
        prior) -> KEEP the prior live generation (the same owner keeps its lease;
        no handoff). The high-water is raised to >= this generation.
      * CHANGED owner (a transfer, a new pid, a node death, an acquire from "",
        OR a RE-CREATED pid whose prior owner array no longer covers it after a
        merge) -> `floor + 1` (the lease-ACQUIRE, ABOVE the lifetime high-water).
        This is the Slice-A fix: a re-created pid 5 whose lifetime high-water was
        2 (frozen in `max_generations` across the merge) re-acquires at 3, NOT 1
        — so a displaced gen-2 writer's fence (`2 < 3`) correctly FIRES.
      * A pid that is now UNASSIGNED ("") AND was unassigned before keeps its
        prior live generation (no acquire); a pid that WAS owned and is now ""
        bumps to `floor + 1` (the owner changed) so the next acquirer is strictly
        above the displaced owner — preserving the fence's strict-less-than
        invariant.

    THE CONFIRMED BUG this fixes: recomputing the generation from the (truncated)
    live `generations` array ALONE restarts a re-created pid at 1, below a
    displaced high-gen writer's frozen lease => fence bypass. Anchoring the bump
    on the NEVER-TRUNCATED `max_generations` high-water makes the generation
    monotone over the partition's LIFETIME, not just the current P.

    Returns a tuple `(generations, max_generations)` — BOTH the live generations
    and the carried-forward high-water (the ctor raises the high-water to >= the
    live generations, and never truncates it, so the dropped-pid history persists
    for the next pass)."""
    var out = List[Int64]()
    var out_max = List[Int64]()
    var prior_owners_len = 0
    var prior_max_len = 0
    if prior:
        prior_owners_len = len(prior.value().owners)
        prior_max_len = len(prior.value().max_generations)

    # The high-water output must cover BOTH the new pid range AND any longer
    # prior high-water (a merge shrank P but the prior retained the dropped pids'
    # lifetime watermark — we carry it forward unchanged so a resplit sees it).
    var max_pid = len(owners)
    if prior_max_len > max_pid:
        max_pid = prior_max_len

    for pid in range(max_pid):
        var prev_owner = String("")
        var prev_gen = Int64(0)
        var prev_max = Int64(0)
        if prior:
            ref p = prior.value()
            if pid < prior_owners_len:
                prev_owner = p.owners[pid]
                if pid < len(p.generations):
                    prev_gen = p.generations[pid]
            # The partition-LIFETIME high-water — read even when pid is beyond
            # the (truncated) owners array, because max_generations is NEVER
            # truncated by a merge. This is what survives merge -> resplit.
            if pid < prior_max_len:
                prev_max = p.max_generations[pid]

        # The acquire floor is the lifetime high-water (>= prev_gen always).
        var floor = prev_max if prev_max > prev_gen else prev_gen

        # pids BEYOND the new owners range are dropped pids whose history we only
        # carry forward in the high-water (no live generation entry for them).
        if pid >= len(owners):
            out_max.append(floor)
            continue

        if owners[pid] == prev_owner and pid < prior_owners_len:
            # Unchanged owner (including "" -> "") — keep the prior live
            # generation; the high-water is at least this generation + the floor.
            out.append(prev_gen)
            var hw = floor if floor > prev_gen else prev_gen
            out_max.append(hw)
        else:
            # Owner CHANGED, or a RE-CREATED pid (prior owners array did not
            # cover it after a merge) — bump ABOVE the lifetime high-water.
            var bumped = floor + Int64(1)
            out.append(bumped)
            out_max.append(bumped)
    # Return BOTH lists as a tuple — Mojo destructures a tuple cleanly at the
    # call site (a struct field-extraction trips the partial-move tracker).
    # Element 0 = live generations, element 1 = high-water.
    return (out^, out_max^)


# =============================================================================
# rebalance_reason_for — decide WHETHER (and why) a fresh pass is needed.
# =============================================================================


def rebalance_reason_for(
    prior: Optional[Assignment],
    new_live_ids_sorted: List[String],
    num_partitions: Int,
    operator_forced: Bool,
) -> Int:
    """Decide the rebalance-trigger reason given the prior assignment and the
    fresh inputs. Returns a REBALANCE_* constant; REBALANCE_NONE means
    the prior assignment is still valid and NO new pass is required (the common
    steady-state heartbeat — re-running the pass when nothing changed would be
    pointless churn, even though `assign_partitions` is idempotent under sticky).

    Precedence (most-disruptive first so the reason is informative):
      operator_forced              -> REBALANCE_OPERATOR
      no prior                     -> REBALANCE_INITIAL
      P changed                    -> REBALANCE_PARTITION_COUNT
      live set shrank (a node left)-> REBALANCE_STALE_NODE
      live set grew (a node joined)-> REBALANCE_NEW_NODE
      otherwise                    -> REBALANCE_NONE
    """
    if operator_forced:
        return REBALANCE_OPERATOR
    if not prior:
        return REBALANCE_INITIAL
    ref p = prior.value()
    if p.num_partitions != num_partitions:
        return REBALANCE_PARTITION_COUNT
    # Compare the (sorted) live id sets.
    var prior_ids = p.node_ids.copy()
    if not _string_lists_equal(prior_ids, new_live_ids_sorted):
        if len(new_live_ids_sorted) < len(prior_ids):
            return REBALANCE_STALE_NODE
        if len(new_live_ids_sorted) > len(prior_ids):
            return REBALANCE_NEW_NODE
        # Same size, different membership (one swapped out + one in) — treat as a
        # stale-node event (a node was replaced; its partitions must move).
        return REBALANCE_STALE_NODE
    return REBALANCE_NONE


# =============================================================================
# Module helpers — string-list utilities (pure; no pointer flow).
# =============================================================================


def _index_of(ids: List[String], target: String) -> Int:
    """Index of `target` in `ids`, or -1 if absent."""
    for i in range(len(ids)):
        if ids[i] == target:
            return i
    return -1


def _string_lists_equal(a: List[String], b: List[String]) -> Bool:
    """Element-wise equality of two String lists (same length + same order)."""
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def _sort_strings(mut ids: List[String]):
    """In-place ascending sort of a small String list (insertion sort — the node
    set is tiny, O(N^2) is fine + branch-predictable; keeps the assignment
    deterministic across replicas)."""
    var n = len(ids)
    for i in range(1, n):
        var j = i
        while j > 0 and ids[j - 1] > ids[j]:
            var tmp = ids[j - 1]
            ids[j - 1] = ids[j]
            ids[j] = tmp^
            j -= 1


# =============================================================================
# JSON encode/decode byte helpers (compact ASCII — local to this file).
# =============================================================================


def _json_quote(s: String) -> String:
    """Render a String as a JSON string literal, escaping `"` and `\\`. Node ids
    are simple cluster identifiers (no control chars expected); this is the
    defensive minimum so an embedded quote can't corrupt the array."""
    var out = String('"')
    var b = s.as_bytes()
    for i in range(len(b)):
        var c = b[i]
        if c == UInt8(34):  # "
            out += String('\\"')
        elif c == UInt8(92):  # backslash
            out += String("\\\\")
        else:
            out += chr(Int(c))
    out += String('"')
    return out^


def _to_byte_list(s: String) -> List[UInt8]:
    """Copy a String's UTF-8 bytes into an owned List[UInt8] (matches the
    PartitionMap byte-scan discipline — operate on an owned List so no Span
    origin needs to be threaded through the helpers). The assignment JSON is
    ASCII so byte == char."""
    var b = s.as_bytes()
    var out = List[UInt8]()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _abytes_find(hay: List[UInt8], needle: String, start: Int) -> Int:
    """Index of `needle` in `hay` at/after `start`, or -1."""
    var nb = _to_byte_list(needle)
    var nlen = len(nb)
    if nlen == 0:
        return start
    var hlen = len(hay)
    var i = start if start >= 0 else 0
    while i + nlen <= hlen:
        var ok = True
        for j in range(nlen):
            if hay[i + j] != nb[j]:
                ok = False
                break
        if ok:
            return i
        i += 1
    return -1


def _abytes_find_after(hay: List[UInt8], key: String, start: Int) -> Int:
    """Index just AFTER `key` in `hay` (the first byte of the value), or -1."""
    var at = _abytes_find(hay, key, start)
    if at < 0:
        return -1
    return at + len(_to_byte_list(key))


def _afind_array_close(hay: List[UInt8], open_at: Int) -> Int:
    """Index of the `]` closing the array whose first inside-byte is `open_at`
    (these arrays hold only flat string elements, no nesting). `len(hay)` if
    not found."""
    var i = open_at
    var n = len(hay)
    while i < n:
        if hay[i] == UInt8(93):  # ']'
            return i
        i += 1
    return n


def _aparse_int_at(hay: List[UInt8], start: Int) raises -> Int:
    """Read a (possibly negative) decimal int at `start`, skipping spaces."""
    var i = start
    var n = len(hay)
    while i < n and hay[i] == UInt8(32):
        i += 1
    var sign = 1
    if i < n and hay[i] == UInt8(45):  # '-'
        sign = -1
        i += 1
    var v = 0
    var saw = False
    while i < n:
        var c = hay[i]
        if c < UInt8(48) or c > UInt8(57):
            break
        v = v * 10 + Int(c - UInt8(48))
        saw = True
        i += 1
    if not saw:
        raise Error("Assignment.decode: expected integer at " + String(start))
    return sign * v


def _aparse_string_array(
    hay: List[UInt8], open_at: Int, close_at: Int
) -> List[String]:
    """Parse a JSON array of string literals between `open_at` (first byte inside
    `[`) and `close_at` (the `]`), honoring `\\"` / `\\\\` escapes. An empty array
    yields an empty list; an empty literal `""` yields a "" element (the
    unassigned-owner case)."""
    var out = List[String]()
    var i = open_at
    while i < close_at:
        # Find the next opening quote.
        while i < close_at and hay[i] != UInt8(34):  # '"'
            i += 1
        if i >= close_at:
            break
        i += 1  # past the opening quote
        var cur = String("")
        while i < close_at:
            var c = hay[i]
            if c == UInt8(92):  # backslash escape
                if i + 1 < close_at:
                    var nxt = hay[i + 1]
                    cur += chr(Int(nxt))
                    i += 2
                    continue
                i += 1
                continue
            if c == UInt8(34):  # closing quote
                i += 1
                break
            cur += chr(Int(c))
            i += 1
        out.append(cur^)
    return out^


def _aparse_int_array(
    hay: List[UInt8], open_at: Int, close_at: Int
) raises -> List[Int64]:
    """Parse a JSON array of (possibly negative) decimal integers between
    `open_at` (first byte inside `[`) and `close_at` (the `]`). An empty array
    yields an empty list. Used for the generations array."""
    var out = List[Int64]()
    var i = open_at
    while i < close_at:
        # Skip separators / whitespace to the next digit or sign.
        while i < close_at and (
            hay[i] == UInt8(32)  # space
            or hay[i] == UInt8(44)  # ','
        ):
            i += 1
        if i >= close_at:
            break
        if hay[i] < UInt8(48) or hay[i] > UInt8(57):
            if hay[i] != UInt8(45):  # not a digit and not '-' -> done
                break
        var v = _aparse_int_at(hay, i)
        out.append(Int64(v))
        # Advance past the integer we just read (sign + digits).
        if i < close_at and hay[i] == UInt8(45):
            i += 1
        while i < close_at and hay[i] >= UInt8(48) and hay[i] <= UInt8(57):
            i += 1
    return out^


# =============================================================================
# Little-endian scalar codec helpers (the binary assignment body). All
# arithmetic is on plain owned `List[UInt8]` + typed scalars; ZERO
# UnsafePointer, ZERO wildcard origin. Each helper returns a typed scalar /
# appends typed bytes — no pointer crosses any boundary.
# =============================================================================


@always_inline
def _put_u16(mut out: List[UInt8], v: UInt16):
    # SAFETY: pure value arithmetic on a UInt16 — append the two LE bytes; no
    # pointer, no aliasing. The mask/shift cannot overflow a UInt8.
    out.append(UInt8(v & UInt16(0xFF)))
    out.append(UInt8((v >> UInt16(8)) & UInt16(0xFF)))


@always_inline
def _put_u32(mut out: List[UInt8], v: UInt32):
    # SAFETY: pure value arithmetic on a UInt32 — append the four LE bytes; no
    # pointer, no aliasing.
    out.append(UInt8(v & UInt32(0xFF)))
    out.append(UInt8((v >> UInt32(8)) & UInt32(0xFF)))
    out.append(UInt8((v >> UInt32(16)) & UInt32(0xFF)))
    out.append(UInt8((v >> UInt32(24)) & UInt32(0xFF)))


@always_inline
def _put_i32(mut out: List[UInt8], v: Int32):
    # SAFETY: reinterpret the Int32's bit pattern as a UInt32 (two's-complement,
    # bitcast — no value change) and emit it LE. `reason` / `num_partitions` are
    # small non-negative ints in practice, but the codec is total over Int32.
    _put_u32(out, v.cast[DType.uint32]())


@always_inline
def _read_u16(body: List[UInt8], pos: Int) raises -> UInt16:
    # SAFETY: bounds-checked read of two LE bytes from an owned List[UInt8]; the
    # check raises (never indexes out of range) before any access.
    if pos < 0 or pos + 2 > len(body):
        raise Error(
            "assignment binary decode: truncated u16 at offset " + String(pos)
        )
    return UInt16(Int(body[pos])) | (UInt16(Int(body[pos + 1])) << UInt16(8))


@always_inline
def _read_u32(body: List[UInt8], pos: Int) raises -> UInt32:
    # SAFETY: bounds-checked read of four LE bytes from an owned List[UInt8].
    if pos < 0 or pos + 4 > len(body):
        raise Error(
            "assignment binary decode: truncated u32 at offset " + String(pos)
        )
    return (
        UInt32(Int(body[pos]))
        | (UInt32(Int(body[pos + 1])) << UInt32(8))
        | (UInt32(Int(body[pos + 2])) << UInt32(16))
        | (UInt32(Int(body[pos + 3])) << UInt32(24))
    )


@always_inline
def _read_i32(body: List[UInt8], pos: Int) raises -> Int32:
    # SAFETY: read the LE u32 then reinterpret its bit pattern as Int32
    # (two's-complement bitcast — no value change). Bounds-checked via _read_u32.
    return _read_u32(body, pos).cast[DType.int32]()


@always_inline
def _put_i64(mut out: List[UInt8], v: Int64):
    # SAFETY: reinterpret the Int64's bit pattern as a UInt64 (two's-complement
    # bitcast — no value change) and emit the eight LE bytes; no pointer, no
    # aliasing. Used for the generations trailer.
    var u = v.cast[DType.uint64]()
    for k in range(8):
        out.append(UInt8((u >> UInt64(k * 8)) & UInt64(0xFF)))


@always_inline
def _read_i64(body: List[UInt8], pos: Int) raises -> Int64:
    # SAFETY: bounds-checked read of eight LE bytes from an owned List[UInt8],
    # reinterpreted as Int64 (two's-complement bitcast). The check raises before
    # any index access.
    if pos < 0 or pos + 8 > len(body):
        raise Error(
            "assignment binary decode: truncated i64 at offset " + String(pos)
        )
    var u = UInt64(0)
    for k in range(8):
        u = u | (UInt64(Int(body[pos + k])) << UInt64(k * 8))
    return u.cast[DType.int64]()


# =============================================================================
# Span-based LE read helpers — the ZERO-COPY decode path. These
# mirror `_read_u16` / `_read_u32` / `_read_i32` above but read from a BORROWED
# `Span[UInt8, _]` (the persisted body) instead of an owned List. The Span's `_`
# origin is a TYPE PARAMETER inferred at the call site (the standard view idiom —
# NOT a wildcard `MutAnyOrigin`/`ImmutAnyOrigin`), so the read borrows the source
# bytes for the call's duration; nothing is allocated. Bounds-checked against
# `len(span)` (raises before any out-of-range access). No pointer crosses any
# boundary — the Span IS the view.
# =============================================================================


@always_inline
def _vread_u16(body: Span[UInt8, _], pos: Int) raises -> UInt16:
    # SAFETY: bounds-checked read of two LE bytes from a borrowed Span; the check
    # raises before any index access. The Span borrows the source body — no copy.
    if pos < 0 or pos + 2 > len(body):
        raise Error(
            "assignment binary view: truncated u16 at offset " + String(pos)
        )
    return UInt16(Int(body[pos])) | (UInt16(Int(body[pos + 1])) << UInt16(8))


@always_inline
def _vread_u32(body: Span[UInt8, _], pos: Int) raises -> UInt32:
    # SAFETY: bounds-checked read of four LE bytes from a borrowed Span.
    if pos < 0 or pos + 4 > len(body):
        raise Error(
            "assignment binary view: truncated u32 at offset " + String(pos)
        )
    return (
        UInt32(Int(body[pos]))
        | (UInt32(Int(body[pos + 1])) << UInt32(8))
        | (UInt32(Int(body[pos + 2])) << UInt32(16))
        | (UInt32(Int(body[pos + 3])) << UInt32(24))
    )


@always_inline
def _vread_i32(body: Span[UInt8, _], pos: Int) raises -> Int32:
    # SAFETY: read the LE u32 then reinterpret its bit pattern as Int32 (bitcast,
    # no value change). Bounds-checked via _vread_u32.
    return _vread_u32(body, pos).cast[DType.int32]()


@always_inline
def _vread_i64(body: Span[UInt8, _], pos: Int) raises -> Int64:
    # SAFETY: bounds-checked read of eight LE bytes from a borrowed Span,
    # reinterpreted as Int64 (two's-complement bitcast). The check raises before
    # any index access. Used for the generations trailer.
    if pos < 0 or pos + 8 > len(body):
        raise Error(
            "assignment binary view: truncated i64 at offset " + String(pos)
        )
    var u = UInt64(0)
    for k in range(8):
        u = u | (UInt64(Int(body[pos + k])) << UInt64(k * 8))
    return u.cast[DType.int64]()


def _hex32(v: UInt32) -> String:
    """Render a UInt32 as 8 lowercase hex digits (for the bad-magic diagnostic)."""
    var digits = String("0123456789abcdef")
    var db = digits.as_bytes()
    var out = String("")
    for shift in range(7, -1, -1):
        var nibble = Int((v >> UInt32(shift * 4)) & UInt32(0xF))
        out += chr(Int(db[nibble]))
    return out^
