# =============================================================================
# komira_objectstore/cas_manifest.mojo
#   The shared CAS-manifest substrate + the `MetadataStore` trait
# =============================================================================
#
# The pure-S3 coordination substrate owned by `komira_objectstore`, conformed to
# by BOTH the Komira message broker (offset allocator) AND the search engine
# (split metastore). This file is the *one* place the CAS-manifest
# append+lifecycle protocol lives — coordination shared by contract, not by
# copy.
#
# -----------------------------------------------------------------------------
# DESIGN NOTE — the shared `MetadataStore` trait
# -----------------------------------------------------------------------------
#
# The abstraction: a **CAS-manifest** is an ordered
# sequence of immutable manifest *chunks* under a key prefix, appended via
# conditional-create (`If-None-Match: *`), fronted by a mutable `_HEAD`
# pointer object, with a per-entry lifecycle FSM
# (`Staged → Published → ScheduledForDelete`). Every chunk, once created,
# is immutable; the chunk's *position in the sequence* is its identity. The
# create-winner of slot K owns slot K — there is exactly one winner, so the
# sequence is gapless and totally ordered (linearizable append).
#
# WHY ONE TRAIT SERVES BOTH CONSUMERS (the load-bearing shared-foundation
# decision). The trait surface is the *manifest mechanism*, NOT either
# consumer's domain payload. Both consumers map onto the same three verbs —
# append, lifecycle-transition, read-back — with their domain meaning
# carried ENTIRELY inside the opaque chunk body (`List[UInt8]`), never on the
# trait surface:
#
#   ┌─────────────────────┬──────────────────────────┬─────────────────────────┐
#   │ Trait concept       │ Broker (offset allocator)│ Search (split metastore)│
#   ├─────────────────────┼──────────────────────────┼─────────────────────────┤
#   │ manifest lineage    │ one partition's segment  │ one index's split       │
#   │ (key prefix)        │ index                    │ catalog (meta.json line)│
#   ├─────────────────────┼──────────────────────────┼─────────────────────────┤
#   │ append(body) →      │ commit a segment: body = │ register a split: body =│
#   │ returns AppendResult│ (object_key, N, crc,     │ (split_id, doc_count,   │
#   │ {chunk_seq,         │  producer-boundaries).   │  footer_offset, min/max,│
#   │  base_offset,       │ base_offset = prev tail; │  schema-hash).          │
#   │  last_offset}       │ records occupy           │ base/last carry the     │
#   │                     │ [base, last] — the       │ split's doc-id range    │
#   │                     │ append IS the offset     │ (or are ignored: search │
#   │                     │ allocator.    │ keys by split_id, not   │
#   │                     │                          │ a contiguous offset).   │
#   ├─────────────────────┼──────────────────────────┼─────────────────────────┤
#   │ lifecycle FSM       │ Staged: PUT .seg, not    │ Staged: split PUT to S3,│
#   │ Staged → Published  │   yet in manifest.       │   not in meta.json.     │
#   │ → ScheduledForDelete│ Published: append landed │ Published: meta.json CAS│
#   │                     │   → visible to consumers.│   landed → searchable.  │
#   │                     │ ScheduledForDelete:      │ ScheduledForDelete:     │
#   │                     │   retention tombstone →  │   split retired → reaper│
#   │                     │   reaper deletes .seg.   │   deletes the .split.   │
#   ├─────────────────────┼──────────────────────────┼─────────────────────────┤
#   │ read_chunk(seq) /   │ resolve offset→segment;  │ list live splits; fetch │
#   │ read_head /         │ replay the manifest tail.│ a split's catalog entry.│
#   │ list_chunks         │                          │                         │
#   └─────────────────────┴──────────────────────────┴─────────────────────────┘
#
# The trait deliberately carries NEITHER `offset` NOR `split` in any method
# name or signature — `base_offset` / `last_offset` are the GENERIC
# "contiguous range this chunk's body occupies" (the broker uses them as
# Kafka offsets; search either uses them as doc-id ranges or ignores them and
# keys by an id embedded in the body). The chunk body is opaque bytes the
# consumer encodes/decodes. This is the no-leakage property: the broker's
# offset semantics and search's split semantics both live in the body, above
# this trait, never inside it.
#
# WHY `[Store: ConditionalWriteStore]`. The trait is parametrized
# over the storage backend, NOT over a domain. `ConditionalWriteStore`
# already carries the exact verb set the protocol needs (conditional_put for
# the `If-None-Match` append + the `If-Match` HEAD advance; get / get_range
# for read-back; list_with_delimiter for the LIST-recovery path; delete for
# the reaper). One backend per deployment, so `[Store]` does not multiply
# per-request — it is a backend selector, the same discipline as `S3Fs[C]`.
#
# -----------------------------------------------------------------------------
# THE TWO CONFORMERS
# -----------------------------------------------------------------------------
#
#   (a) `CasManifestStore[Store]` — the pure-S3 / pure-`ConditionalWriteStore`
# DEFAULT. Implements manifest-append protocol against any
#       `ConditionalWriteStore` (S3 via `S3ConditionalStore[C]` in production;
#       the in-memory conformer below for offline tests). This is the body
# that runs the `If-None-Match` append CAS loop + the bounded-
#       backoff retry policy.
#
#   (b) `InMemoryConditionalStore` — a `ConditionalWriteStore` conformer over
#       an in-process map (no live store). Lets the property-test rig run the
#       SAME `CasManifestStore` protocol offline (CI without MinIO). It is a
#       `ConditionalWriteStore`, so `CasManifestStore[InMemoryConditionalStore]`
#       exercises the real append loop — the protocol code is identical; only
#       the backend differs. This is the "test the one primitive once" rig.
#
# The opt-in job-store-CAS backend is NOT precluded — it is simply
# a third `ConditionalWriteStore` conformer that would slot in as
# `CasManifestStore[JobStoreConditionalStore]` with zero protocol change.
#
# -----------------------------------------------------------------------------
# Encapsulation discipline
# -----------------------------------------------------------------------------
#   * ZERO UnsafePointer in any public signature (the whole surface is
#     value/`List[UInt8]`/POD).
#   * ZERO wildcard origins (no `MutAnyOrigin` / `MutExternalOrigin`).
#   * ZERO `unsafe_from_address`.
# * heap-reuse: the chunk body is a plain `List[UInt8]`; the manifest's in-memory
#     state (`InMemoryConditionalStore`) holds owned `String`/`List` fields in
#     a plain `Dict`-shaped struct that is NOT stored in a byte-slab — no
#     byte-slab-with-wildcard element anywhere. The retry policy state is POD
#     ints. Nothing here is a Movable struct living in an `OwnedSlab`.
# =============================================================================

from std.ffi import external_call
from std.memory import OwnedPointer
from std.time import perf_counter_ns

from komira_async.ops.waker_sink import WakerSink
from komira_async.reactor.reactor import Reactor

# The tier-2 LIST-escalation counter (adaptive index sharding).
# `CasManifestStore` carries an OPTIONAL, DEFAULT-OFF
# `OwnedPointer[MetricsSet]` sink (the same default-OFF holder shape as the
# broker's sub-lineage rollout metrics — a default-OFF store constructs NO
# holder, so the un-instrumented append path is unchanged and pays nothing).
# The counter is incremented at the `force_auth`
# trigger branch in `_append_inner`'s retry loop. NO wildcard-origin field
# the field is `Optional[OwnedPointer[MetricsSet]]`, a POD handle
# behind the canonical OwnedPointer indirection. Cycle-free: komira_metrics deps
# {the core packages and the small leaf packages} only — never reaches back into komira_objectstore.
from komira_metrics.metrics_set import MetricsSet, new_owned_metrics_set

from komira_objectstore.cas_backoff_probe import record_cas_backoff
from komira_objectstore.path import Path

# Reclamation never touches a live chunk (at or above `_LOG_START`):
# decisions + error text, no I/O (cycle-free: imports nothing from here).
from komira_objectstore.chunk_reclaim_guard import (
    advance_regress_error,
    advance_would_regress,
    reap_is_refused,
    reap_refused_error,
    rewrite_target_deleted_error,
)

# The reaped-slot guard (opt-in; komira-ai/komira#486): a create that wins a
# chunk slot below `_LOG_START` is never reported committed. The rules, the
# soundness argument and the error text live in `manifest_slot_guard`; this
# file only calls them (cycle-free: it imports nothing from this package).
from komira_objectstore.manifest_slot_guard import (
    head_is_below_log_start,
    log_start_unread_error,
    probed_slot_is_below_log_start,
    slot_reaped_error,
    won_slot_is_reaped,
)

# Adaptive index sharding: the neutral shard-id +
# sub-lineage discovery kernel. `discover_shard_ids` below is the encapsulated
# passthrough — it LISTs `<index_meta_prefix>/_lineage/` through `_store` (which
# never crosses the boundary) and returns a plain `List[String]`. Cycle-free:
# sublineage_shard_keys imports ONLY {path, store, types}, never cas_manifest.
from komira_objectstore.sublineage_shard_keys import _discover_shard_ids

# =============================================================================
# Process-global CAS-manifest serialization gate — a READ/WRITE lock
# =============================================================================
#
# The shared CAS substrate over `S3ConditionalStore[C]` is fanned by the
# broker to K>=4 concurrent writers racing ONE manifest prefix, AND read
# concurrently by thread-per-core search workers (the search server is
# multi-threaded share-nothing; each worker builds a fresh scope-local
# `CasManifestStore` and
# fans `list_live_splits` = read_head + read_log_start + tombstone_seqs +
# N x read_chunk). Under genuine same-prefix CAS contention the composed
# `append` path (read_head + conditional_put + advance_head, repeated per
# 412-retry) drives a high volume of concurrent small String/List allocations
# through the bundled tcmalloc in libAsyncRTRuntimeGlobals, which corrupts the
# PROCESS-GLOBAL tcmalloc central freelist (SIGSEGV in
# `tcmalloc::CentralFreeList::FetchFromOneSpans`, 100% deterministic at K>=4).
#
# Pinned by a bisection over a live S3-compatible store: every
# READ-shaped sub-operation (read_head/GET-404 loop, puts, conditional_puts,
# GET->put interleaves) is clean concurrently at K=16; ONLY the REAL
# `manifest.append` racing a SHARED prefix crashes. The corruption is
# WRITE-shaped — reads alone never reproduce it.
#
# GATE SHAPE — a read/write lock:
#   * READ verbs (read_head / read_chunk / tombstone_seqs /
#     tombstone_schedule_ts / read_log_start; num_chunks delegates to
#     read_head) take the SHARED (read) lock -> concurrent readers proceed in
#     PARALLEL, so read<->read serialization does not cap thread-per-core
#     throughput.
#   * WRITE verbs (append / reap / advance_log_start / rewrite_chunk_body /
#     schedule_for_delete_at) take the EXCLUSIVE (write) lock -> still
#     excludes ALL readers while a publish is in flight.
# Read<->write exclusion is PRESERVED, so a reader's allocator churn never
# runs concurrently with the proven-corrupting contended-append churn — the
# masked corruption cannot be reintroduced. Only read<->read exclusion is
# lifted, which no consumer relies on for correctness (broker consume is
# read-only and concurrent-safe by S3/store linearizability; append re-reads
# HEAD inside its own retained write lock via the UNLOCKED `_read_head_inner`,
# so an unserialized external read can never corrupt an append).
#
# The lock lives as a static `pthread_rwlock_t` in the already-everywhere-
# linked `_posix_shim.c` (`komira_cas_gate_rdlock/wrlock/unlock`) — no Mojo
# global. It is WRITER-PREFERRING on Linux
# (PTHREAD_RWLOCK_PREFER_WRITER_NONRECURSIVE_NP, init at runtime via
# pthread_once + attr because PTHREAD_RWLOCK_INITIALIZER cannot set the kind)
# so a read-heavy load cannot starve a publish; macOS uses the
# implementation-defined default (publishes are rare -> not a concern). The
# genuine deep fix is at the allocator level (the tcmalloc overflow under the
# bundled allocator + concurrent writers); once it exists the WHOLE gate
# (read AND write) can be removed.
#
# NOTE on a non-S3 backend: the gate serializes ALL CasManifestStore composite
# ops regardless of backend. For the thread-safe in-memory conformer this is a
# harmless (tiny) serialization; the offline twin's correctness is unchanged.


# EXPERIMENT TOGGLE (for tests of the un-gated path).
# The disable check lives ENTIRELY in komira_async's C shim: `komira_cas_gate_rdlock`
# / `wrlock` / `unlock` consult a static `_cas_gate_disabled` flag and no-op
# when it is set. A test that wants the un-gated path calls
# `komira_cas_gate_set_disabled`
# ONCE in main before spawning. Production NEVER calls the setter, so the flag
# is 0 and the gate is always on. The switch is an explicit call, never
# configuration read from the environment.
@always_inline
def _cas_gate_rdlock():
    # READ verbs take the SHARED (read) lock — concurrent readers proceed in
    # parallel. Read<->read
    # serialization is lifted; read<->write exclusion is preserved by the
    # writer's `_cas_gate_wrlock`.
    _ = external_call["komira_cas_gate_rdlock", NoneType]()


@always_inline
def _cas_gate_wrlock():
    # WRITE verbs take the EXCLUSIVE (write) lock — still excludes ALL readers
    # while a publish is in flight, which is the property that holds the masked
    # bundled-tcmalloc central-freelist corruption closed.
    _ = external_call["komira_cas_gate_wrlock", NoneType]()


@always_inline
def _cas_gate_unlock():
    _ = external_call["komira_cas_gate_unlock", NoneType]()
from komira_objectstore.store import (
    AsyncCasStore,
    CasOpProgress,
    ConditionalWriteStore,
)
from komira_objectstore.types import (
    ListResult,
    ObjectMeta,
    STORE_ERR_NOT_FOUND,
    STORE_ERR_PRECONDITION,
    WritePrecondition,
)


# =============================================================================
# Lifecycle FSM — the shared Staged → Published → ScheduledForDelete states
# =============================================================================

comptime LIFECYCLE_STAGED = UInt8(0)
comptime LIFECYCLE_PUBLISHED = UInt8(1)
comptime LIFECYCLE_SCHEDULED_FOR_DELETE = UInt8(2)


@always_inline
def _write_lifecycle_name[W: Writer](mut writer: W, state: UInt8):
    """WRITE what `lifecycle_name` returns. ⚠ THIS WRITES; IT DOES NOT RETURN.

    The arms live here so no string constant is ever SELECTED and
    returned. A literal-returning ladder lowers to two parallel
    (pointer, length) constant arrays whose two call-site references
    an `--emit shared-lib` link can bind INDEPENDENTLY; a shared
    library has been seen to bind such a pair CROSSED, which crashed
    the host interpreter."""
    if state == LIFECYCLE_STAGED:
        writer.write(String("Staged"))
        return
    if state == LIFECYCLE_PUBLISHED:
        writer.write(String("Published"))
        return
    if state == LIFECYCLE_SCHEDULED_FOR_DELETE:
        writer.write(String("ScheduledForDelete"))
        return
    writer.write(String("Unknown"))
    return


@always_inline
def lifecycle_name(state: UInt8) -> String:
    var out = String()
    _write_lifecycle_name(out, state)
    return out^


# =============================================================================
# AppendResult — what a successful manifest append returns
# =============================================================================


@fieldwise_init
struct AppendResult(Copyable, Movable, Deinitable):
    """Result of a successful CAS-manifest append. POD-ish (one String etag).

    Field layout:
      var chunk_seq: Int64    — the slot this append won (0-based monotone).
      var base_offset: Int64  — first offset this chunk's body occupies
                                (= prev tail + 1; broker: Kafka offset,
                                 search: doc-id range start or ignored).
      var last_offset: Int64  — last offset this chunk's body occupies
                                (= base_offset + record_count - 1).
      var etag: String        — the committed chunk object's etag.
      var attempts: Int       — how many CAS attempts this append took
                                (1 = won first try; >1 = contended). The
                                C-4 stress harness reads this for the
                                412-rate characterization.
    """

    var chunk_seq: Int64
    var base_offset: Int64
    var last_offset: Int64
    var etag: String
    var attempts: Int


# =============================================================================
# DedupSentinel + IdempotentAppendResult — the producer-batch idempotency
# sentinel (broker exactly-once atomicity).
# =============================================================================
#
# The dedup sentinel is one tiny object per committed producer batch, created
# via `conditional_put(If-None-Match)` keyed on the producer-batch identity
# `(producer_id, first_seq)`. Its create-CAS is the SINGLE cross-process
# linearization point for COMMISSION ("did this exact producer batch already
# commit") — the control-object linearization-point pattern specialized to
# one per-(producer, batch) record. Written ATOMICALLY-FIRST in the commit
# (step 1, before the chunk append), so it serializes same-producer batches
# at a single object and binds the dedup decision to the commit.
#
# Encapsulation: POD-ish (7 i64 + one owned String etag). NOT a byte-slab
# element (heap-reuse N/A) — a stack value held by the protocol.


comptime IDEMPOTENT_COMMITTED: Int = 0  # we won + appended exactly once
comptime IDEMPOTENT_DUPLICATE: Int = 1  # already committed (idempotent ack)
comptime IDEMPOTENT_FENCED: Int = 2  # stale PRODUCER-EPOCH zombie (no write)
comptime IDEMPOTENT_RETRYABLE: Int = 3  # in-flight winner / genuine no-commit
# IDEMPOTENT_LEASE_FENCED — a stale PARTITION-OWNERSHIP writer
# (writer_lease_epoch < current_lease_epoch). DISTINCT from IDEMPOTENT_FENCED (the
# producer-id epoch fence): the broker maps this to Kafka NOT_LEADER_OR_FOLLOWER
# (refresh metadata — an ownership transfer), NOT INVALID_PRODUCER_EPOCH. The
# two fences must never share a code.
comptime IDEMPOTENT_LEASE_FENCED: Int = 4


# =============================================================================
# The writer-lease-epoch fence — the at-least-once `append` path
# signals a stale displaced writer by RAISING a CLASSIFIED error (it returns a
# bare AppendResult, with no outcome enum, so a raise is the least-invasive
# signal — every existing caller's signature is unchanged). The broker maps this
# to the same Kafka fenced code the idempotent IDEMPOTENT_FENCED path uses. The
# message carries a stable marker substring `lease_fenced` so the classifier
# below matches it without false positives.
# =============================================================================
comptime _LEASE_FENCED_MARKER: String = "lease_fenced"


def is_lease_fenced(msg: String) -> Bool:
    """True iff `msg` is the writer-lease-epoch FENCED error raised by the
    at-least-once `append` path for a stale displaced writer.
    The broker maps a true result to the same fenced Kafka code the idempotent
    `IDEMPOTENT_FENCED` outcome maps to."""
    return msg.find(_LEASE_FENCED_MARKER) >= 0

# THROUGHPUT GATE (exactly-once): whether the WINNER advances its staged sentinel ->
# committed on the HOT commit path (Step 3 finalize). OFF by default — the
# finalize is a pure optimization (a duplicate retry can read the offset
# directly instead of scanning), and skipping it halves the per-append
# extra-write cost on the exclusive cas-gate, which is load-bearing for the
# split-brain contention e2e's 45s client deadline. Correctness is UNCHANGED:
# the exact chunk-identity scan (`_scan_tail_for_batch`) recovers the offset for
# a committed-but-staged sentinel whether or not it was finalized. The
# staged-orphan reaper MUST scan-before-delete (it does), so a committed-but-
# staged sentinel is never reaped.
comptime _FINALIZE_ON_HOT_PATH: Bool = False


@fieldwise_init
struct DedupSentinel(Copyable, Movable, Deinitable):
    """One decoded dedup sentinel — the per-(producer, batch) commission LP.

    A `committed_chunk_seq >= 0` sentinel is FULLY committed (the chunk landed);
    `committed_chunk_seq == -1` is a STAGED claim (the winner is mid-append or
    crashed before/at the chunk append). The body records, for this exact batch:
    the epoch it committed under (the fence input), the sequence range it covers,
    and the committed manifest location + offset range (so a phantom retry reads
    back the exact offset to ack idempotently WITHOUT re-appending).

    Field layout (little-endian wire — see `encode_dedup_sentinel`):
      var producer_id: Int64
      var producer_epoch: Int64
      var first_seq: Int64
      var last_seq: Int64
      var committed_chunk_seq: Int64  — -1 = STAGED claim; >=0 = committed slot.
      var base_offset: Int64          — committed base offset (-1 if staged).
      var last_offset: Int64          — committed last offset (-1 if staged).
      var etag: String                — the sentinel object's etag (for the
                                        Step-3 If-Match finalize); empty when
                                        decoded without a head read.
    """

    var producer_id: Int64
    var producer_epoch: Int64
    var first_seq: Int64
    var last_seq: Int64
    var committed_chunk_seq: Int64
    var base_offset: Int64
    var last_offset: Int64
    var etag: String

    @staticmethod
    def staged(
        producer_id: Int64,
        producer_epoch: Int64,
        first_seq: Int64,
        last_seq: Int64,
    ) -> DedupSentinel:
        """A not-yet-committed CLAIM (committed_chunk_seq == -1)."""
        return DedupSentinel(
            producer_id,
            producer_epoch,
            first_seq,
            last_seq,
            Int64(-1),
            Int64(-1),
            Int64(-1),
            String(""),
        )

    @always_inline
    def is_committed(self) -> Bool:
        return self.committed_chunk_seq >= Int64(0)


def encode_dedup_sentinel(s: DedupSentinel) -> List[UInt8]:
    """Encode the sentinel body (7 i64 LE). The etag is NOT in the body (it is
    the object's server-assigned version, read separately)."""
    var out = List[UInt8]()
    _put_i64_le(out, s.producer_id)
    _put_i64_le(out, s.producer_epoch)
    _put_i64_le(out, s.first_seq)
    _put_i64_le(out, s.last_seq)
    _put_i64_le(out, s.committed_chunk_seq)
    _put_i64_le(out, s.base_offset)
    _put_i64_le(out, s.last_offset)
    return out^


def decode_dedup_sentinel(bytes: List[UInt8], etag: String) raises -> DedupSentinel:
    var producer_id = _get_i64_le(bytes, 0)
    var producer_epoch = _get_i64_le(bytes, 8)
    var first_seq = _get_i64_le(bytes, 16)
    var last_seq = _get_i64_le(bytes, 24)
    var committed_chunk_seq = _get_i64_le(bytes, 32)
    var base_offset = _get_i64_le(bytes, 40)
    var last_offset = _get_i64_le(bytes, 48)
    return DedupSentinel(
        producer_id,
        producer_epoch,
        first_seq,
        last_seq,
        committed_chunk_seq,
        base_offset,
        last_offset,
        etag,
    )


@fieldwise_init
struct IdempotentAppendResult(Copyable, Movable, Deinitable):
    """The outcome of an exactly-once `append_idempotent`.

    `outcome` is one of IDEMPOTENT_{COMMITTED, DUPLICATE, FENCED, RETRYABLE}.
    On COMMITTED / DUPLICATE the offset fields carry the committed location;
    on FENCED / RETRYABLE they are -1 (the caller maps those to Kafka codes
    / retries). POD-ish (one String etag). Not a byte-slab element."""

    var outcome: Int
    var chunk_seq: Int64
    var base_offset: Int64
    var last_offset: Int64
    var attempts: Int

    @staticmethod
    def committed(r: AppendResult) -> IdempotentAppendResult:
        return IdempotentAppendResult(
            IDEMPOTENT_COMMITTED,
            r.chunk_seq,
            r.base_offset,
            r.last_offset,
            r.attempts,
        )

    @staticmethod
    def duplicate(
        chunk_seq: Int64, base_offset: Int64, last_offset: Int64
    ) -> IdempotentAppendResult:
        return IdempotentAppendResult(
            IDEMPOTENT_DUPLICATE, chunk_seq, base_offset, last_offset, 0
        )

    @staticmethod
    def fenced() -> IdempotentAppendResult:
        return IdempotentAppendResult(
            IDEMPOTENT_FENCED, Int64(-1), Int64(-1), Int64(-1), 0
        )

    @staticmethod
    def lease_fenced() -> IdempotentAppendResult:
        """A stale PARTITION-OWNERSHIP writer (writer_lease_epoch <
        current_lease_epoch). DISTINCT from `fenced` (the
        producer-epoch fence) so the broker maps it to NOT_LEADER_OR_FOLLOWER."""
        return IdempotentAppendResult(
            IDEMPOTENT_LEASE_FENCED, Int64(-1), Int64(-1), Int64(-1), 0
        )

    @staticmethod
    def retryable() -> IdempotentAppendResult:
        return IdempotentAppendResult(
            IDEMPOTENT_RETRYABLE, Int64(-1), Int64(-1), Int64(-1), 0
        )


# =============================================================================
# ManifestHead — the cached `_HEAD` tail pointer
# =============================================================================


@fieldwise_init
struct ManifestHead(Copyable, Movable, Deinitable):
    """The `_HEAD` tail pointer: `{chunk_seq, next_offset, etag_of_last_chunk}`.

    Cacheable; a stale read just wastes a CAS attempt (correctness is
    preserved by the `If-None-Match` append — see step 1). The
    `next_offset` is the base offset the next append will claim.

    Field layout:
      var chunk_seq: Int64     — highest committed chunk seq (-1 = empty).
      var next_offset: Int64   — base offset for the next append.
      var etag_of_last_chunk: String — etag of the highest chunk (for an
                                 optional `If-Match` HEAD advance).
    """

    var chunk_seq: Int64
    var next_offset: Int64
    var etag_of_last_chunk: String

    @staticmethod
    def empty() -> ManifestHead:
        """The HEAD of an empty manifest: no chunks, next base = 0."""
        return ManifestHead(Int64(-1), Int64(0), String(""))


# =============================================================================
# _LocalHeadCache — the single-writer-per-instance local `_HEAD` tail cache
# =============================================================================
#
# Broker flush op reduction. A `CasManifestStore` instance is
# the offset allocator for ONE manifest lineage (one broker partition), held by
# value on the owning `BrokerCore` for the broker's lifetime. The hot append
# path takes `mut self` — so a SINGLE writer per instance is guaranteed by the
# Mojo borrow checker (no two threads can `append` the SAME instance
# concurrently; cross-writer contention is between DISTINCT instances over the
# same prefix). After a successful append+advance, the owner's local cache is
# AUTHORITATIVE for ITS next append (the single-writer-per-partition common case
# post-writer-lease), so the next append computes `candidate_seq` + `base_offset`
# DIRECTLY and ELIDES the `_HEAD` GET + the etag HEAD (ops 2 + 3 of the 5-op
# ack).
#
# CORRECTNESS (the load-bearing invariant): the cache is NEVER a correctness
# oracle. The chunk slot `If-None-Match` create-CAS remains the SOLE arbiter of
# gaplessness + offset density. A STALE cache (a concurrent sibling instance won
# the slot we computed) only ever causes a 412 at the create-CAS -> the cache is
# INVALIDATED -> the append falls back to the EXISTING re-read path (GET `_HEAD`,
# re-anchor, retry). A stale cache can therefore cause at most one wasted attempt
# (a 412 + a re-read); it can NEVER produce a committed wrong/duplicate offset.
#
# This is a plain typed value field on `CasManifestStore` (NOT a byte-slab
# element) — heap-reuse N/A (the lone heap-owning field, `head_etag: String`, is a
# direct struct field, not a heap-owning field of a Movable struct stored in a
# byte-backed slab under a wildcard cast). No UnsafePointer, no wildcard origin.
# -----------------------------------------------------------------------------


# How many consecutive cache-warm appends may DEFER the durable `_HEAD` advance
# before one is forced to persist it (best-effort, non-blocking-correctness). The
# durable `_HEAD` is purely a recovery cache (LIST reconstructs it), so a deferred
# advance is recoverable — but letting it go stale FOREVER would make every cold
# reader / fresh handle pay an O(N) LIST. This bounds the durable `_HEAD` to at
# most `_HEAD_ADVANCE_DEFER_CADENCE` chunks behind the true tail. With the cadence
# > 1, the COMMON warm ack stays at 2 synchronous ops; every Nth warm ack
# additionally persists the durable `_HEAD` (3 ops, amortized to ~2 + 1/N). This
# is a best-effort piggyback, NOT a task scheduler.
comptime _HEAD_ADVANCE_DEFER_CADENCE = Int64(64)


@fieldwise_init
struct _LocalHeadCache(Copyable, Movable, Deinitable):
    """The owner's local view of the durable `_HEAD` tail (single-writer-per-
    instance). `present == False` = cold (no append has landed on this instance
    yet, or the cache was invalidated by a 412); the append path then runs the
    existing read/LIST-recovery path. When present, `(chunk_seq, next_offset)` is
    the cached tail and `head_etag` is the etag of the durable `_HEAD` as of the
    LAST durable advance this instance performed (may be empty if the durable
    advance was deferred / unknown — the advance then falls back to its
    read-recheck path).

    Field layout:
      var present: Bool        — True iff the cache is warm + trusted.
      var chunk_seq: Int64     — cached highest committed chunk seq.
      var next_offset: Int64   — cached base offset for the next append.
      var head_etag: String    — durable `_HEAD` etag at the last advance (or "").
      var deferred_advances: Int64 — count of consecutive warm appends that have
                                 DEFERRED the durable `_HEAD` advance since the
                                 last durable persist; the cadence forces a
                                 best-effort persist when it reaches
                                 `_HEAD_ADVANCE_DEFER_CADENCE`.
    """

    var present: Bool
    var chunk_seq: Int64
    var next_offset: Int64
    var head_etag: String
    var deferred_advances: Int64

    @staticmethod
    def cold() -> _LocalHeadCache:
        """A cold (untrusted) cache — the append path reads/LIST-recovers."""
        return _LocalHeadCache(
            False, Int64(-1), Int64(0), String(""), Int64(0)
        )


# =============================================================================
# RetryPolicy — bounded exponential backoff with full jitter
# =============================================================================
#
# Normative. On the k-th 412, sleep a uniformly-random
# duration in [0, min(base * 2^k, cap)]. After `max_retries` 412s the append
# FAILS with a retryable error (livelock-free by construction). Full jitter
# decorrelates concurrent writers so they don't re-collide in lockstep.
# -----------------------------------------------------------------------------


comptime CAS_LIST_ESCALATE_AFTER: Int = 3
"""Consecutive 412s after which `CasManifestStore.append` re-anchors on the
bucket's authoritative tail (the LIST escalation) instead of probing one slot
forward. Public so a test can state what its bound relies on: a call whose
budget (`max_retries + 1` attempts) exceeds this many attempts makes at least
one attempt past a re-anchor."""


@fieldwise_init
struct RetryPolicy(
    Copyable, ImplicitlyCopyable, Movable, Deinitable
):
    """Bounded exponential backoff with full jitter. POD.

    Field layout:
      var base_us: Int64      — base backoff, microseconds (default 5_000 = 5ms).
      var cap_us: Int64       — backoff cap, microseconds (default 250_000 = 250ms).
      var max_retries: Int    — max 412 retries before terminal fail (default 8).
    """

    var base_us: Int64
    var cap_us: Int64
    var max_retries: Int

    @staticmethod
    def default() -> RetryPolicy:
        # normative defaults: base=5ms, cap=250ms (the flush
        # cadence, so backoff never exceeds one flush interval), ~8 retries.
        return RetryPolicy(Int64(5_000), Int64(250_000), 8)

    @staticmethod
    def fast_test() -> RetryPolicy:
        # Tighter schedule for the offline property test / fast CI: keeps
        # the no-gap invariant identical, just shorter waits.
        return RetryPolicy(Int64(100), Int64(5_000), 12)

    @staticmethod
    def broker_contention() -> RetryPolicy:
        # The WRITE-path policy for the
        # Kafka data plane, tuned for GENUINE multi-writer contention on ONE
        # partition's manifest (two+ broker nodes producing many small records
        # to the same partition concurrently). With `fast_test()` (base=100us,
        # cap=5ms, 12 retries) a 2-node x 500-record concurrent produce has far
        # too short a cumulative backoff window: the 412-loser EXHAUSTS the
        # budget and raises the retryable
        # "exhausted N retries (retryable)" Error. With this policy the common
        # case resolves via retry WITHOUT surfacing the error; the rare genuine
        # exhaustion still degrades gracefully (the produce handler maps it to a
        # retriable per-partition Kafka error_code — NEVER a process exit).
        #
        # base=500us, cap=100ms, 28 retries. Full jitter draws uniform in
        # [0, min(base*2^k, cap)] per attempt, so the cumulative window grows
        # generously (each later attempt sleeps up to ~100ms) while staying
        # bounded (livelock-free by the max_retries cap). 28 attempts of up to
        # ~100ms each gives a multi-second contention window — enough for two
        # writers to serialize ~1000 appends through the CAS allocator.
        #
        # The exactly-once produce
        # path wraps each chunk append in the sentinel protocol (a create-CAS
        # before the slot append, inside the exclusive cas-gate), which lengthens
        # the per-produce wall time. Under cross-node SPLIT-BRAIN single-record
        # produces this widens the window in which two brokers' produces overlap
        # on the shared partition manifest, raising the slot-CAS collision rate;
        # a collision triggers backoff + (after a run of 412s) the O(N) authoritative
        # LIST escalation, which feeds back into more overlap. The budget is
        # base=500us, cap=100ms, 40 retries. A bisection showed
        # the produce path is dominated NOT by slot-CAS contention (>99% of
        # appends win on the FIRST attempt) but by intermittent multi-second
        # object-store op stalls on a busy broker, so the backoff schedule is a
        # second-order knob here; this is a balanced default (immediate
        # decorrelation, a moderate cap, a generous ceiling) backstopped by the
        # forward-probe + O(gap) incremental escalation re-anchor on the rare 412.
        # The sentinel guarantees exactly-once regardless of the schedule; a
        # genuine exhaustion degrades gracefully (retriable per-partition code).
        return RetryPolicy(Int64(500), Int64(100_000), 40)

    @always_inline
    def backoff_us_for_attempt(self, k: Int) -> Int64:
        """The UPPER BOUND of the jittered sleep window for the k-th 412
        (k is 1-based). Returns `min(base * 2^k, cap)`. The actual sleep is
        a uniform draw in [0, this]."""
        # Saturating shift: cap k so base<<k cannot overflow Int64. base is
        # small (microseconds) and cap is tight, so any k >= 40 already
        # saturates to cap.
        if k >= 40:
            return self.cap_us
        var scaled = self.base_us * (Int64(1) << Int64(k))
        if scaled > self.cap_us or scaled < Int64(0):
            return self.cap_us
        return scaled


# -----------------------------------------------------------------------------
# Full-jitter sleep — uniform draw in [0, upper_us], then sleep that long.
#
# We use a cheap xorshift PRNG seeded from perf_counter_ns() so concurrent
# writers (different threads) draw decorrelated values without a shared RNG
# (no lock, no shared state — each call seeds fresh from the clock + a
# per-call salt). The draw quality only needs to break lockstep, not be
# cryptographic.
# -----------------------------------------------------------------------------


@always_inline
def _xorshift64(var x: UInt64) -> UInt64:
    x ^= x << UInt64(13)
    x ^= x >> UInt64(7)
    x ^= x << UInt64(17)
    return x


@always_inline
def _jittered_sleep_us(upper_us: Int64, attempt: Int):
    """Sleep a uniform-random duration in [0, upper_us] microseconds.

    Full jitter. Seeds an xorshift from the high-resolution
    clock XORed with a per-call salt (the attempt count) so two threads
    entering backoff at nearly the same instant still draw different waits.
    Every backoff is counted (`cas_backoff_probe`), a zero bound included:
    the attempt, its bound, the draw and the time the sleep took, so a test
    can hold them to the policy.
    """
    if upper_us <= Int64(0):
        record_cas_backoff(attempt, upper_us, Int64(0), Int64(0))
        return
    var salt = UInt64(attempt)
    var seed = UInt64(perf_counter_ns()) ^ (salt * UInt64(0x9E3779B97F4A7C15))
    var r = _xorshift64(seed | UInt64(1))
    var draw_us = r % UInt64(upper_us + 1)
    var t0 = perf_counter_ns()
    # Use `usleep` (microsecond, distinct symbol) instead of stdlib
    # `time.sleep` → `nanosleep`: an AOT binary that links komira_async (whose
    # reactor declares its OWN `external_call["nanosleep", ...]`) hits a
    # "conflicting nanosleep signature" legalization failure. Same fix as
    # komira_job_supervisor._sleep_secs / komira_supervisor._sleep_ms.
    _ = external_call["usleep", Int32](UInt32(draw_us))
    var slept_us = Int64((perf_counter_ns() - t0) // 1000)
    record_cas_backoff(attempt, upper_us, Int64(draw_us), slept_us)


# =============================================================================
# The shared `MetadataStore` trait
# =============================================================================
#
# This is the surface BOTH the broker `MetadataStore` and the search
# metastore conform to. It is the manifest mechanism, parametrized over the
# storage backend; it leaks NEITHER offset NOR split specifics (see the
# design note above).
# -----------------------------------------------------------------------------


trait MetadataStore(Movable, Deinitable):
    """The shared CAS-manifest coordination surface.

    Conformers: `CasManifestStore[Store]` (pure-`ConditionalWriteStore`
    default; S3 / in-memory / future job-store backends). The broker's
    offset allocator and the search engine's split metastore are the SAME
    trait, distinguished only by the opaque chunk `body: List[UInt8]` they
    append and read back — no offset/split vocabulary on this surface.

    Lifecycle: every appended chunk transitions
    `Staged → Published → ScheduledForDelete`; `append` lands it Published
    (visible), `schedule_for_delete` tombstones it, `reap` removes the
    object after the grace window. (Staged is the pre-append state the
    caller holds before `append` — it has no trait verb because Staging is
    "object PUT, not yet in the manifest", which is the caller's own write.)

    Pointer discipline: ZERO UnsafePointer in any signature. Bodies flow as
    owned `List[UInt8]`; results are PODs carrying the committed etag.
    """

    def append(
        mut self,
        body: List[UInt8],
        record_count: Int64,
        writer_lease_epoch: Int64 = Int64(0),
        current_lease_epoch: Int64 = Int64(0),
    ) raises -> AppendResult:
        """Append `body` as the next manifest chunk via the `If-None-Match`
        create-CAS loop. Assigns the contiguous offset range
        `[base, base + record_count - 1]` to this chunk — the append IS the
        allocator (the manifest is the counter; no separate next_offset CAS).

        On contention (another writer won the slot, 412) re-reads HEAD,
        recomputes base, and retries under bounded exponential backoff with
        full jitter. After `max_retries` 412s, RAISES a
        retryable error (`StoreError.precondition`-shaped, livelock-free).

        Writer-lease-epoch fence: `writer_lease_epoch` /
        `current_lease_epoch` default to 0 (the fence is a NO-OP for callers
        that do not track partition leases — search's split metastore, the table store,
        an older broker). When supplied, a `writer_lease_epoch <
        current_lease_epoch` RAISES the classified `lease_fenced` error BEFORE
        any chunk create-CAS (a stale displaced owner never takes an offset).

        Returns the `AppendResult` (chunk_seq, base/last offset, etag,
        attempt count). The committed chunk is Published (visible) on return.
        """
        ...

    def read_head(self) raises -> ManifestHead:
        """Read the manifest's current tail pointer. Cacheable — a stale
        read just wastes the next append's first attempt. Reconstructed by
        LISTing the highest chunk if the `_HEAD` cache object is absent
        (bucket is the source of truth; pointer is a cache — step 4).
        """
        ...

    def read_chunk(self, chunk_seq: Int64) raises -> List[UInt8]:
        """Read back the immutable body of chunk `chunk_seq`. Raises
        `StoreError.not_found` if the slot was never committed."""
        ...

    def num_chunks(self) raises -> Int64:
        """The number of committed chunks (= highest chunk_seq + 1). Zero for an
        empty manifest.

        ⚠ ADVISORY, AND WEAKER THAN FOUR OF ITS CALLERS BELIEVE. A conformer MAY
        answer from a durable pointer object that a writer is allowed to leave
        stale-low, so the result is a LOWER BOUND on the committed tail, not the
        tail. `CasManifestStore`'s does exactly that, by up to 63 chunks — see
        the ⛔ note on its implementation, which records the measurement and why
        the one-line fix is NOT the fix.

        A caller that needs the TRUE tail must ask for it by name:
        `read_head_authoritative()` (always LIST) or `read_head_fresh()` (warm
        cache, else LIST). Do not read this method as a correctness oracle."""
        ...

    def schedule_for_delete(mut self, chunk_seq: Int64) raises -> None:
        """Transition chunk `chunk_seq` to `ScheduledForDelete` (the
        retention tombstone). Does NOT remove the object — `reap` does that
        after the grace window. Idempotent."""
        ...

    def reap(mut self, chunk_seq: Int64) raises -> None:
        """Remove the underlying object for a `ScheduledForDelete` chunk
        (the reaper verb). Idempotent (deleting an absent object succeeds).
        Raises if the chunk is not in `ScheduledForDelete` (fail-loud — you
        must tombstone before you reap), or if it is at or above the log start
        (a live chunk: advance the log start past a chunk before reaping it)."""
        ...


# =============================================================================
# Chunk-body / HEAD wire encoding (dependency-free, deterministic)
# =============================================================================
#
# We deliberately do NOT pull a JSON library into komira_objectstore (it
# depends only on the core packages — adding a serde dep would invert the DAG).
# The chunk object the manifest protocol manages has a tiny fixed envelope:
#   [ record_count: Int64 LE ][ body_len: Int64 LE ][ body bytes... ]
# The body is the consumer's opaque payload (offset record / split entry).
# The protocol only needs `record_count` to compute the offset range; the
# body is round-tripped verbatim. The `_HEAD` object encodes
#   [ chunk_seq: Int64 LE ][ next_offset: Int64 LE ][ etag_len ][ etag ].
# All integers little-endian. This is the manifest-internal framing; the
# CONSUMER's domain encoding lives inside `body` and is none of our business.
# -----------------------------------------------------------------------------


@always_inline
def _put_i64_le(mut out: List[UInt8], v: Int64):
    var u = UInt64(v)
    for i in range(8):
        out.append(UInt8((u >> UInt64(8 * i)) & UInt64(0xFF)))


@always_inline
def _get_i64_le(bytes: List[UInt8], off: Int) raises -> Int64:
    if off + 8 > len(bytes):
        raise Error("cas_manifest: truncated i64 at offset " + String(off))
    var u = UInt64(0)
    for i in range(8):
        u |= UInt64(Int(bytes[off + i])) << UInt64(8 * i)
    return Int64(u)


def encode_chunk(body: List[UInt8], record_count: Int64) -> List[UInt8]:
    """Wrap a consumer body + record_count into the manifest chunk envelope."""
    var out = List[UInt8]()
    _put_i64_le(out, record_count)
    _put_i64_le(out, Int64(len(body)))
    for i in range(len(body)):
        out.append(body[i])
    return out^


def decode_chunk_record_count(chunk: List[UInt8]) raises -> Int64:
    """Extract the record_count from an encoded chunk."""
    return _get_i64_le(chunk, 0)


def decode_chunk_body(chunk: List[UInt8]) raises -> List[UInt8]:
    """Extract the consumer body from an encoded chunk."""
    var body_len = Int(_get_i64_le(chunk, 8))
    if 16 + body_len > len(chunk):
        raise Error("cas_manifest: chunk body length exceeds chunk size")
    var out = List[UInt8]()
    for i in range(body_len):
        out.append(chunk[16 + i])
    return out^


def encode_head(head: ManifestHead) -> List[UInt8]:
    var out = List[UInt8]()
    _put_i64_le(out, head.chunk_seq)
    _put_i64_le(out, head.next_offset)
    var eb = head.etag_of_last_chunk.as_bytes()
    _put_i64_le(out, Int64(len(eb)))
    for i in range(len(eb)):
        out.append(eb[i])
    return out^


def decode_head(bytes: List[UInt8]) raises -> ManifestHead:
    var chunk_seq = _get_i64_le(bytes, 0)
    var next_offset = _get_i64_le(bytes, 8)
    var etag_len = Int(_get_i64_le(bytes, 16))
    # BYTE-EXACT decode of the etag run. ⛔ NOT `etag += chr(Int(bytes[...]))`:
    # `encode_head` writes the etag's bytes RAW, so a `chr` decode is an
    # ASYMMETRIC codec pair — `chr` maps a CODE POINT to its UTF-8 ENCODING and
    # re-encodes every byte >= 0x80 into two, so the decoded etag would not
    # match the one that was written and every `If-Match` on it would 412.
    # An etag is an OPAQUE token from the store; this decoder may not assume a
    # charset for it, so it never passes a byte through `chr`.
    var etag_bytes = List[UInt8]()
    for i in range(etag_len):
        etag_bytes.append(bytes[24 + i])
    var etag = String(StringSlice(unsafe_from_utf8=Span(etag_bytes)))
    return ManifestHead(chunk_seq, next_offset, etag^)


# =============================================================================
# Key layout — the manifest's object keys under a prefix
# =============================================================================
#
#   <prefix>/manifest/<chunk_seq:020d>.chunk   ← If-None-Match append target
#   <prefix>/_HEAD                              ← If-Match tail pointer cache
#
# The 20-digit zero-pad makes chunk keys lexically sortable, so a LIST of the
# manifest prefix yields chunks in sequence order — the bucket-is-truth
# recovery path.
# -----------------------------------------------------------------------------


@always_inline
def _pad20(seq: Int64) -> String:
    var s = String(seq)
    var pad = 20 - s.byte_length()
    var out = String("")
    for _ in range(pad):
        out += "0"
    out += s
    return out^


def chunk_key(prefix: String, chunk_seq: Int64) raises -> Path:
    return Path.parse(prefix + "/manifest/" + _pad20(chunk_seq) + ".chunk")


def head_key(prefix: String) raises -> Path:
    return Path.parse(prefix + "/_HEAD")


# =============================================================================
# Retention — persisted tombstone markers + the log-start pointer
#
# =============================================================================
#
# The lifecycle-FSM tombstone state is PERSISTED, not process-local (a
# process-local list would be re-discovered as EMPTY by a broker restart — a
# durability bug): one tiny S3 object per tombstoned chunk:
#
#   <prefix>/tombstones/<chunk_seq:020d>.tomb   ← body = schedule_ts_ms (i64 LE)
#   <prefix>/moved_tombstones/<chunk_seq:020d>.tomb   ← same body
#
# A MOVED marker retires a chunk whose payload objects (the objects its body
# names, the broker's `.seg`) another manifest now references: a reaper deletes
# the chunk key and the markers, never the payload. It is a separate key so
# that a plain tombstone written later for the same chunk (a retention pass
# working from an older `_LOG_START` snapshot) cannot overwrite it: only
# `schedule_moved_for_delete_at` writes it. A chunk is ScheduledForDelete when
# either marker exists, `tombstone_seqs` lists both, and `reap` and
# `purge_all` delete both.
#
# Per-chunk markers are idempotent (create-or-overwrite of one key), discovered
# on restart via a LIST of `<prefix>/tombstones/`, and decoupled from the hot
# `_HEAD` CAS. The grace-aware reaper consults a marker's
# `schedule_ts_ms` and deletes the chunk only after the grace window elapses;
# on reap the marker MAY be deleted (we delete it — simplest, the chunk is
# gone so the marker has no further use; a re-tombstone of an absent chunk
# would fail-loud on the existence check anyway).
#
# The persisted LOG-START pointer:
#
#   <prefix>/_LOG_START   ← body = (log_start_offset i64 LE)(log_start_seq i64 LE)
#                            (etag-CAS advanced via If-Match)
#
# `log_start_offset` is the first still-readable absolute offset; `log_start_seq`
# is the lowest still-live chunk_seq (chunks < log_start_seq are reaped/retired).
# Consume seeds its running_base from this so surviving chunks keep their
# CORRECT ABSOLUTE offsets after reaping (finding #4 — never renumber).
# -----------------------------------------------------------------------------


def tombstone_key(prefix: String, chunk_seq: Int64) raises -> Path:
    return Path.parse(
        prefix + "/tombstones/" + _pad20(chunk_seq) + ".tomb"
    )


def moved_tombstone_key(prefix: String, chunk_seq: Int64) raises -> Path:
    """The MOVED marker of `chunk_seq`: retire the chunk key, keep the payload
    another manifest references."""
    return Path.parse(
        prefix + "/moved_tombstones/" + _pad20(chunk_seq) + ".tomb"
    )


def log_start_key(prefix: String) raises -> Path:
    return Path.parse(prefix + "/_LOG_START")


def catalog_key(prefix: String) raises -> Path:
    """The `<prefix>/_CATALOG` sidecar object key. A SINGLE mutable, etag-CAS-
    versioned sidecar (same shape as `_HEAD` / `_LOG_START`) holding an OPAQUE
    consumer blob. The CAS-manifest substrate carries NEITHER the blob's
    meaning NOR its encoding — the table store uses it for the durable table catalog
   , and the body is whatever the consumer encodes. This
    keeps the manifest mechanism domain-free (the blob is the consumer's
    business, above this trait), exactly like the opaque chunk body."""
    return Path.parse(prefix + "/_CATALOG")


# =============================================================================
# the dedup-sentinel key (exactly-once atomicity)
# =============================================================================
#
#   <prefix>/_meta/dedup/<producer_id:020d>/<first_seq:020d>.seq
#
# Per-PARTITION (the sentinel co-locates with the manifest it gates).
# Keyed by `(producer_id, first_seq)`: a retry re-sends the SAME
# batch, so `first_seq` (the batch base sequence) is the stable idempotency key.
# Zero-padded for lexical order (LIST-able for GC, mirroring `_pad20`).


def dedup_sentinel_key(
    prefix: String, producer_id: Int64, first_seq: Int64
) raises -> Path:
    return Path.parse(
        prefix
        + "/_meta/dedup/"
        + _pad20(producer_id)
        + "/"
        + _pad20(first_seq)
        + ".seq"
    )


# =============================================================================
# LogStart — the persisted `_LOG_START` pointer
# =============================================================================


@fieldwise_init
struct LogStart(Copyable, Movable, Deinitable):
    """The partition's log-start pointer: the first still-readable offset +
    the lowest still-live chunk seq, plus the etag for an `If-Match` advance.

    Field layout:
      var log_start_offset: Int64 — first still-readable ABSOLUTE offset.
      var log_start_seq: Int64    — lowest still-live chunk_seq (chunks
                                    `< log_start_seq` are reaped/retired).
      var etag: String            — the `_LOG_START` object's etag (empty if
                                    the object does not exist yet → the next
                                    advance creates it via If-None-Match).
    """

    var log_start_offset: Int64
    var log_start_seq: Int64
    var etag: String

    @staticmethod
    def zero() -> LogStart:
        """The log-start of a never-truncated partition: offset 0, seq 0, no
        `_LOG_START` object yet (empty etag)."""
        return LogStart(Int64(0), Int64(0), String(""))


# =============================================================================
# CatalogSidecar — the read-back of the `_CATALOG` opaque sidecar
# =============================================================================


@fieldwise_init
struct CatalogSidecar(Movable, Deinitable):
    """The read-back of the `<prefix>/_CATALOG` sidecar: the opaque consumer
    blob + its etag + a `present` flag (False when the object does not exist
    yet — a never-written catalog). The etag is the CAS token the next
    `cas_catalog_sidecar` advance feeds back (empty when absent → the first
    write is an If-None-Match create). The blob is an OPAQUE `List[UInt8]` —
    the CAS substrate never interprets it (the SQL layer's catalog codec does).

    Field layout:
      var present: Bool       — True iff the `_CATALOG` object exists.
      var blob: List[UInt8]   — the opaque consumer bytes (empty when absent).
      var etag: String        — the object's etag (empty when absent).
    """

    var present: Bool
    var blob: List[UInt8]
    var etag: String

    @staticmethod
    def absent() -> CatalogSidecar:
        """The never-written catalog: no object, empty blob, empty etag (the
        next CAS advance creates via If-None-Match)."""
        return CatalogSidecar(False, List[UInt8](), String(""))


def encode_log_start(ls: LogStart) -> List[UInt8]:
    var out = List[UInt8]()
    _put_i64_le(out, ls.log_start_offset)
    _put_i64_le(out, ls.log_start_seq)
    return out^


def decode_log_start(bytes: List[UInt8], etag: String) raises -> LogStart:
    var off = _get_i64_le(bytes, 0)
    var seq = _get_i64_le(bytes, 8)
    return LogStart(off, seq, etag)


def _sorted_unique(var xs: List[Int64]) -> List[Int64]:
    """`xs` ascending with duplicates removed (insertion sort: manifests'
    marker sets are small)."""
    for i in range(1, len(xs)):
        var v = xs[i]
        var j = i - 1
        while j >= 0 and xs[j] > v:
            xs[j + 1] = xs[j]
            j -= 1
        xs[j + 1] = v
    var out = List[Int64]()
    for i in range(len(xs)):
        if len(out) == 0 or out[len(out) - 1] != xs[i]:
            out.append(xs[i])
    return out^


@always_inline
def _seq_from_tombstone_key(key: String) -> Int64:
    # Extract the <chunk_seq:020d> from "..../tombstones/<020d>.tomb".
    return _seq_after_marker(key, String("/tombstones/"))


@always_inline
def _seq_from_moved_tombstone_key(key: String) -> Int64:
    # Extract the <chunk_seq:020d> from "..../moved_tombstones/<020d>.tomb".
    return _seq_after_marker(key, String("/moved_tombstones/"))


@always_inline
def _seq_after_marker(key: String, marker: String) -> Int64:
    var idx = key.rfind(marker)
    if idx < 0:
        return Int64(-1)
    var start = idx + marker.byte_length()
    var bs = key.as_bytes()
    var v = Int64(0)
    var i = start
    var n = len(bs)
    var any = False
    var zero = UInt8(ord("0"))
    var nine = UInt8(ord("9"))
    while i < n and bs[i] >= zero and bs[i] <= nine:
        v = v * Int64(10) + Int64(Int(bs[i]) - Int(zero))
        i += 1
        any = True
    if not any:
        return Int64(-1)
    return v


# Wall clock (ms) via gettimeofday — the trait `schedule_for_delete` (clock-less
# verb) stamps the tombstone with this; `schedule_for_delete_at` takes an
# explicit ts for deterministic offline tests (the BrokerCore clock-passed-in
# discipline). gettimeofday is a distinct external symbol (no legalization
# conflict with this module's `usleep` / cas-gate calls).
def _now_millis() -> Int64:
    var tv = SIMD[DType.int64, 2](Int64(0), Int64(0))
    var tz = SIMD[DType.int64, 2](Int64(0), Int64(0))
    # SAFETY: stack-local SIMD scratch addressed for the gettimeofday FFI; the
    # pointers do not escape this call (identical to group_coordinator's
    # `_now_millis`). No wildcard origin, no heap, no cross-module pointer.
    _ = external_call["gettimeofday", Int32](
        UnsafePointer(to=tv).bitcast[UInt8](),
        UnsafePointer(to=tz).bitcast[UInt8](),
    )
    return tv[0] * Int64(1000) + tv[1] // Int64(1000)


# =============================================================================
# CasManifestStore[Store] — the pure-ConditionalWriteStore conformer
# =============================================================================


struct CasManifestStore[Store: ConditionalWriteStore](
    MetadataStore, Movable, Deinitable
):
    """The shared CAS-manifest protocol over any `ConditionalWriteStore`.

    Owns its backend `Store` by value + the manifest key `_prefix` + the
    `_retry` policy. Construct with a backend store, a key prefix (one
    manifest lineage = one prefix), and a retry policy. The SAME struct
    serves the broker (one per partition) and search (one per index) — the
    domain difference is entirely in the chunk bodies the caller appends.

    Fields:
      var _store: Store        — the backend (S3 / in-memory / job-store).
      var _prefix: String      — the manifest lineage key prefix.
      var _retry: RetryPolicy — backoff/max-retry policy.
      var _head_cache: _LocalHeadCache — Flush-op reduction:
                                 the owner's local `_HEAD` tail cache. After a
                                 successful append the owner's cache is
                                 authoritative for its NEXT append, eliding the
                                 `_HEAD` GET + etag HEAD. A stale cache 412s at
                                 the create-CAS oracle -> invalidate + fall back;
                                 NEVER a wrong offset. Single-writer-per-instance
                                 by `mut self`; a plain typed field (heap-reuse N/A).

    Tombstone state is NO LONGER a process-local list — it is
    PERSISTED to S3 as one `<prefix>/tombstones/<seq>.tomb` marker per
    tombstoned chunk, so a broker restart re-discovers marks via LIST
    (ground-truth #1 fix). The struct holds NO tombstone field; `_is_marked`
    / `reap` / restart recovery all consult S3.
    """

    var _store: Self.Store
    var _prefix: String
    var _retry: RetryPolicy
    var _head_cache: _LocalHeadCache
    # Adaptive index sharding: the tier-2 LIST-escalation
    # metrics sink. DEFAULT-OFF: `None` constructs no holder, so the
    # un-instrumented append path is unchanged and pays nothing
    # (the `force_auth` increment is guarded by `if self._escalation_metrics`).
    # The OWNED `MetricsSet` is held behind the canonical `OwnedPointer`
    # indirection (it is non-Movable); the field is an `Optional` of that POD
    # handle — NO wildcard-origin field, NO `UnsafePointer` in any
    # signature. The handle never crosses a module boundary as a raw pointer
    # (invariant #7) — only the typed `Int64` escalation count is read out.
    var _escalation_metrics: Optional[OwnedPointer[MetricsSet]]
    # The reaped-slot guard (manifest_slot_guard.mojo). DEFAULT-OFF: a manifest
    # that never opts in pays nothing. The broker opts in for its partitions.
    var _reaped_slot_guard: Bool

    def __init__(
        out self,
        var store: Self.Store,
        var prefix: String,
        retry: RetryPolicy = RetryPolicy.default(),
    ):
        self._store = store^
        self._prefix = prefix^
        self._retry = retry
        # Flush-op reduction: start cold — the first append reads/LIST-
        # recovers the tail and populates the cache from its win.
        self._head_cache = _LocalHeadCache.cold()
        # Escalation metrics: DEFAULT-OFF — no holder constructed. The instrumented index-
        # write dispatcher OPTS IN via `enable_escalation_metrics()`.
        self._escalation_metrics = None
        self._reaped_slot_guard = False

    @always_inline
    def prefix(self) -> String:
        return self._prefix

    # ---- the reaped-slot guard (opt-in) ----

    @always_inline
    def enable_reaped_slot_guard(mut self):
        """OPT IN to the reaped-slot guard (manifest_slot_guard.mojo): after
        every winning create this manifest GETs `_LOG_START` and refuses a win
        below it with the retryable `slot_reaped` error; the forward probe and
        the cold write path never trust a head below the log start. Cost: one
        GET per acknowledged append. For a lineage whose chunks are reaped (the
        broker's partitions); idempotent."""
        self._reaped_slot_guard = True

    @always_inline
    def reaped_slot_guard_enabled(self) -> Bool:
        """True iff `enable_reaped_slot_guard` was called on this handle."""
        return self._reaped_slot_guard

    # ---- the tier-2 LIST-escalation counter ----

    comptime _CAS_LIST_ESCALATIONS = "cas_list_escalations"
    """The tier-2 counter name: the number of `force_auth` LIST-escalation events
    (LIST_ESCALATE_AFTER consecutive 412s ⇒ O(manifest) LIST + replay) this store
    has driven. Incremented at the trigger branch in `_append_inner`'s retry
    loop — at the trigger, NOT the consecutive_412=0 reset."""

    def enable_escalation_metrics(mut self) raises:
        """OPT IN to the tier-2 LIST-escalation counter. Allocates
        the `MetricsSet` behind the canonical OwnedPointer indirection (the
        non-Movable factory shape) and registers the escalation counter. Called
        ONCE by the instrumented index-write dispatcher at construction; a store
        that never opts in constructs no holder and the append path is byte-for-
        byte unchanged (default-OFF). Idempotent: a second call is a no-op (the
        registration is idempotent, and an already-present holder is kept)."""
        if self._escalation_metrics:
            return
        var m = new_owned_metrics_set()
        _ = m[].register_counter[Self._CAS_LIST_ESCALATIONS]()
        self._escalation_metrics = Optional(m^)

    @always_inline
    def escalation_metrics_enabled(self) -> Bool:
        """True iff the tier-2 counter is opted in (the holder is present)."""
        return Bool(self._escalation_metrics)

    def escalation_count(self) -> Int64:
        """The total tier-2 LIST-escalation count this store has observed (the
        per-lineage aggregation seam reads this off the store off
        the hot path and maps the per-window DELTA into
        `CasContentionWindow.observe_list_escalation()`). Returns 0 when the
        counter is not enabled (default-OFF) — the metrics handle NEVER crosses
        the boundary, only this typed `Int64` does (invariant #7)."""
        if self._escalation_metrics:
            return (
                self._escalation_metrics.value()[]
                .counter[Self._CAS_LIST_ESCALATIONS]()
                .reduce()
            )
        return Int64(0)

    @always_inline
    def store_mut(mut self) -> ref [self._store] Self.Store:
        """Borrow the backend store by `mut` ref. The ONLY
        caller is the poll-shaped `AsyncManifestAppendOp` (same module), which
        drives the AsyncCasStore `cas_put_*` verbs on the SAME backend the
        manifest protocol uses. The ref's origin is bound to `self._store` (a
        CONCRETE origin, NEVER a wildcard); the store handle itself never crosses
        a module boundary — the op lives in cas_manifest. Encapsulation: the
        accessor returns a `ref`, not a raw pointer; the AsyncCasStore surface it
        reaches is start/poll/take of typed values only."""
        return self._store

    # ---- HEAD read (with bucket-is-truth LIST recovery) ----

    def read_head(self) raises -> ManifestHead:
        # CAS-GATE (multi-threaded conditional-store callers): serialize the
        # composite read across the whole process. Exception-safe unlock (no
        # `finally` in Mojo 1.0.0b1 — catch, unlock, re-raise). The internal
        # retry-loop / recovery callers use `_read_head_inner` (UNLOCKED) so
        # the non-recursive rwlock never self-deadlocks.
        #
        # Flush-op reduction: prefer the LOCAL `_HEAD`
        # cache when present. This instance defers its durable `_HEAD` advance off
        # the warm ack path, so the DURABLE `_HEAD` object can lag the tail this
        # instance has actually committed. The local cache is the FRESHEST
        # lower-bound on the tail for THIS instance (monotone-forward; a present
        # cache means this instance's last append WON, and a 412 always
        # invalidates the cache). So `read_head()` returns the local cache when
        # warm — making same-instance reads (`num_chunks`, the dedup tier-2 scan
        # seed) see the deferred-advance tail WITHOUT a durable read. Correctness
        # consumers still use `read_head_authoritative()` (LIST); a present-cache
        # return is no staler than the prior durable-`_HEAD` cache (both are
        # documented LOWER bounds — a sibling can commit beyond either). NO op:
        # this elides the GET entirely on the warm path. `mut self` is NOT needed
        # (pure field read).
        if self._head_cache.present:
            return ManifestHead(
                self._head_cache.chunk_seq,
                self._head_cache.next_offset,
                self._head_cache.head_etag,
            )
        _cas_gate_rdlock()
        try:
            var h = self._read_head_inner()
            _cas_gate_unlock()
            return h^
        except e:
            _cas_gate_unlock()
            raise e^

    def read_head_fresh(self) raises -> ManifestHead:
        """Read the manifest tail with FRESH-READER correctness: prefer the warm
        local cache (this instance's own committed tail), but on a COLD cache go
        AUTHORITATIVE (LIST recovery) rather than trust the durable `_HEAD`
        OBJECT — which the deferred-advance optimization (flush-op
        reduction) knowingly lets lag the true tail by up to
        `_HEAD_ADVANCE_DEFER_CADENCE` chunks.

        WHY THIS EXISTS (the fresh-reader gap — push-ingest correctness).
        The plain `read_head` cold path GETs the durable `_HEAD`
        object and trusts it; its only LIST-recovery escape fires when `_HEAD` is
        ABSENT, NEVER when `_HEAD` is present-but-stale-low. So a FRESH reader
        handle (cold cache) on a backend a SEPARATE long-lived writer handle has
        been appending to (deferring its durable `_HEAD` advance off the warm-ack
        path) reads a stale-low head and SILENTLY MISSES every committed chunk
        above the lagging `_HEAD`. The production push-ingest shape — one
        long-lived writer accumulating a base + deltas, read by a separate fresh
        query endpoint — is EXACTLY this gap.

        The fix is to make the COLD path authoritative: a warm cache is this
        instance's own true lower bound (no read needed); a cold cache must NOT
        believe a `_HEAD` the writer deferred — it LISTs the bucket (the
        documented source of truth) and gets the true highest committed tail.
        This is the correct HEAD read for ANY cross-handle CORRECTNESS consumer
        that must see every committed chunk (a knowledge-graph snapshot/chain read). The
        broker's perf-sensitive append hot path keeps using `read_head()` /
        `read_head_authoritative()` directly; this method does not change either.

        Cost: a warm cache stays 0-RPC; a cold cache pays the same O(surviving-
        chunks) LIST that `read_head_authoritative()` does. For such a reader that is a
        bounded chain (base + ≤ compaction-cadence deltas), read off the (cold)
        query path — never the warm ingest hot path. READ verb -> SHARED lock;
        exception-safe unlock."""
        if self._head_cache.present:
            return ManifestHead(
                self._head_cache.chunk_seq,
                self._head_cache.next_offset,
                self._head_cache.head_etag,
            )
        _cas_gate_rdlock()
        try:
            var h = self._read_head_inner(force_authoritative=True)
            _cas_gate_unlock()
            return h^
        except e:
            _cas_gate_unlock()
            raise e^

    def read_head_authoritative(self) raises -> ManifestHead:
        """Read the manifest tail straight from the BUCKET (LIST recovery),
        BYPASSING the cached `_HEAD` (stale-head forward progress).

        The cached `_HEAD` is advanced only best-effort, so under sustained
        cross-process contention it can lag the TRUE tail for a whole deadline.
        Any CORRECTNESS consumer that must see the true highest-committed chunk
        (e.g. the idempotent-producer dedupe's `recover_last_committed_seq`,
        which scans `0..head.chunk_seq` for a producer's last committed
        sequence — a stale-low head would MISS a just-committed batch and
        wrongly report OUT_OF_ORDER) MUST use this, not `read_head`. The hot
        append path keeps using the cache (with the per-N-412 LIST escalation);
        this is the explicit always-authoritative read for correctness paths.
        READ verb -> SHARED (read) lock; exception-safe unlock."""
        _cas_gate_rdlock()
        try:
            var h = self._read_head_inner(force_authoritative=True)
            _cas_gate_unlock()
            return h^
        except e:
            _cas_gate_unlock()
            raise e^

    def read_durable_head(self) raises -> ManifestHead:
        """Read the DURABLE `_HEAD` pointer OBJECT (a single GET, O(1)), bypassing
        BOTH the local per-instance cache AND the authoritative LIST recovery
        (the freshness oracle for a per-request cache).

        WHY (the cheap cross-handle freshness check): `read_head()` short-circuits
        to the LOCAL `_head_cache` when present (0 RPC but BLIND to sibling
        commits — wrong for a long-lived cached handle that must see OTHER
        handles' writes). `read_head_authoritative()` is correct but O(chunks) —
        `_recover_head_by_list` LISTs AND re-GETs every chunk to replay
        record_counts (~700ms+, grows with chunk count). The DURABLE `_HEAD`
        object is what EVERY committer advances (best-effort, a documented
        lower bound), so a single GET of it is the right O(1) freshness oracle for
        the per-worker cache: if its `chunk_seq` is unchanged the snapshot is
        already fresh (0 further reads); if advanced, fold ONLY the delta. Falls
        back to the LIST only when `_HEAD` is ABSENT (a fresh / never-written
        store). READ verb -> SHARED lock; exception-safe unlock."""
        _cas_gate_rdlock()
        try:
            var h = self._read_head_inner(force_authoritative=False)
            _cas_gate_unlock()
            return h^
        except e:
            _cas_gate_unlock()
            raise e^

    def _read_head_etag(self) raises -> String:
        """Best-effort read of the `_HEAD` OBJECT's etag (NOT the chunk etag in
        the body). Empty string if `_HEAD` is absent (the next advance creates
        it via If-None-Match) or on a transient error (the advance then falls
        back to its read-recheck loop). Used by the hot append path to do a
        ONE-CALL monotone `_HEAD` advance (`If-Match` on this etag) instead of
        a GET+HEAD+PUT cycle (stale-head forward-progress perf)."""
        try:
            var meta = self._store.head(head_key(self._prefix))
            return meta.etag
        except e:
            _ = e
            return String("")

    def _read_head_inner(
        self,
        force_authoritative: Bool = False,
        clamp_to_log_start: Bool = False,
    ) raises -> ManifestHead:
        # Stale-head forward progress: when `force_authoritative` is
        # set (the contended append's escalation after N consecutive 412s), we
        # BYPASS the cached `_HEAD` entirely and go straight to the bucket's
        # authoritative tail (`_recover_head_by_list`). This is the second half
        # of the livelock fix: even with a MONOTONE _HEAD, a writer that keeps
        # losing the slot can be wedged behind a _HEAD that lags the TRUE tail
        # (it advances only best-effort). The cache only tells you a LOWER
        # bound on the tail; under sustained contention that lower bound can be
        # stale-low for the whole deadline. LISTing the manifest prefix yields
        # the TRUE highest committed seq, so the wedged writer computes a fresh
        # `candidate_seq` BEYOND all taken slots and makes forward progress.
        # (No-gap/no-dup is preserved: LIST recovery replays cumulative
        # record_counts, so `next_offset` is the exact running-sum base the
        # next If-None-Match append will claim — identical to the cached path,
        # just authoritative.)
        if force_authoritative:
            return self._recover_head_by_list()
        # Try the cached _HEAD object first (the fast path).
        var h: ManifestHead
        try:
            var hk = head_key(self._prefix)
            var raw = self._store.get(hk)
            h = decode_head(raw)
        except e:
            if _is_not_found(String(e)):
                # _HEAD absent — recover the true tail by LISTing the
                # manifest prefix and reading the highest chunk (the
                # bucket is the source of truth, the pointer is a cache).
                return self._recover_head_by_list()
            raise e^
        # Reaped-slot guard rule 4 (manifest_slot_guard.mojo), WRITE PATH ONLY:
        # a durable `_HEAD` below `_LOG_START` (it lags on an idle partition)
        # is replaced by the LIST-recovered head. One more GET; readers do not
        # pass the flag.
        if clamp_to_log_start and head_is_below_log_start(
            h.chunk_seq, self._read_log_start_seq_inner()
        ):
            return self._recover_head_by_list()
        return h^

    def _read_log_start_inner(self) raises -> LogStart:
        """UNLOCKED `_LOG_START` read (the gate is already held by the caller —
        `read_head` rdlock / `append` wrlock). Mirrors the public
        `read_log_start` minus the (non-recursive) gate take, so recovery can
        seed the offset replay from the retention pointer without
        self-deadlocking. Returns `LogStart.zero()` when the object is absent
        (a never-truncated partition)."""
        var lk = log_start_key(self._prefix)
        try:
            var raw = self._store.get(lk)
            var meta = self._store.head(lk)
            return decode_log_start(raw, meta.etag)
        except e:
            if _is_not_found(String(e)):
                return LogStart.zero()
            raise e^

    def _recover_head_by_list(self) raises -> ManifestHead:
        # Log-start-aware recovery: LIST recovery MUST be aware of
        # the retention `_LOG_START` pointer, or a crash-recovery after
        # retention silently RENUMBERS committed offsets (data corruption).
        #
        # After retention reaps the prefix `[0 .. log_start_seq-1]`, those
        # chunk objects are GONE — `read_chunk(seq < log_start_seq)` 404s.
        # That hole is LEGITIMATE (a reaped prefix), NOT a missing committed
        # chunk. The pre-fix replay started at seq=0 with next_off=0 and
        # fail-soft `break`d on the FIRST 404 → it returned `next_offset=0`
        # for a partition whose live tail is at (say) offset 50. The next
        # append then claims a high slot with `base_offset=0` → it RENUMBERS
        # on top of committed offsets. This matters MORE now that the stale-
        # _HEAD fix escalates to this function as the AUTHORITATIVE tail under
        # contention.
        #
        # The fix mirrors the (already log_start-aware) consume path: seed the
        # replay from `_LOG_START` (start seq = `log_start_seq`, start offset =
        # `log_start_offset` = the absolute base of the first surviving chunk),
        # then replay cumulative record_counts over the SURVIVING range
        # `[log_start_seq .. top]`. A 404 BELOW `log_start_seq` is never even
        # read (we start at `log_start_seq`); a 404 AT-OR-ABOVE `log_start_seq`
        # is a real missing COMMITTED chunk → fail LOUD (a torn lineage must
        # never silently truncate the tail).
        var ls = self._read_log_start_inner()
        var start_seq = ls.log_start_seq
        var start_off = ls.log_start_offset
        if start_seq < Int64(0):
            start_seq = Int64(0)
            start_off = Int64(0)

        var listing = self._list_chunks()
        var top = listing.chunk_seq
        if top < Int64(0) or top < start_seq:
            # No surviving chunk AT OR ABOVE log_start (empty manifest, or the
            # whole live tail has been reaped). The authoritative tail is the
            # log-start position: the next append claims seq `start_seq` at base
            # `start_off`, gapless with the reaped prefix and with no renumber.
            # (`chunk_seq = start_seq - 1` so `candidate_seq = start_seq`.)
            return ManifestHead(start_seq - Int64(1), start_off, String(""))

        # Replay cumulative record_counts over the SURVIVING range only,
        # seeded from the absolute log-start offset (NOT 0). Capture the
        # highest chunk's etag for the recovered HEAD (populate the
        # real top-chunk etag instead of leaving it empty).
        var next_off = start_off
        var seq = start_seq
        var last_etag = String("")
        while seq <= top:
            var ck = chunk_key(self._prefix, seq)
            try:
                var c = self._store.get(ck)
                next_off += decode_chunk_record_count(c)
            except e2:
                if _is_not_found(String(e2)):
                    # A 404 AT-OR-ABOVE log_start_seq is a real missing
                    # COMMITTED chunk (the If-None-Match append is gapless by
                    # construction; the surviving range must be intact). Fail
                    # LOUD — silently truncating here would mis-derive the tail
                    # and the next append would renumber over committed
                    # offsets. This is the catastrophic case the pre-fix
                    # fail-soft `break` masked.
                    raise Error(
                        "CasManifestStore: recovery found a MISSING committed"
                        " chunk at seq "
                        + String(seq)
                        + " (>= log_start_seq "
                        + String(start_seq)
                        + ") — torn manifest lineage, refusing to renumber."
                        " prefix="
                        + self._prefix
                    )
                raise e2^
            # Capture the etag of the highest chunk for the recovered HEAD.
            if seq == top:
                try:
                    var meta = self._store.head(ck)
                    last_etag = meta.etag
                except e3:
                    _ = e3  # etag is an advisory hint; tolerate a transient miss
            seq += Int64(1)
        return ManifestHead(top, next_off, last_etag^)

    # ---- append (the load-bearing If-None-Match CAS loop) ----

    def append(
        mut self,
        body: List[UInt8],
        record_count: Int64,
        writer_lease_epoch: Int64 = Int64(0),
        current_lease_epoch: Int64 = Int64(0),
    ) raises -> AppendResult:
        # Writer-lease-epoch fence: `writer_lease_epoch` is the
        # appending owner's per-partition lease generation (carried from its last
        # heartbeat); `current_lease_epoch` is the live generation the caller read
        # AUTHORITATIVELY at flush. Both default to 0 (the fence is a NO-OP for a
        # caller that does not supply leases — e.g. search's split metastore, the
        # table-store path, or an older broker). The fence (a stale displaced writer
        # whose generation is below the live one is rejected BEFORE any chunk
        # create-CAS) is applied inside `_append_inner`, before the retry loop.
        # CAS-GATE NARROWED: the
        # process-global write gate NO LONGER spans the append's S3 round-trips
        # (read_head + conditional_put + advance_head + the 412-retry loop). The
        # append now runs LOCK-FREE; the `If-None-Match` create-CAS is the SOLE
        # correctness arbiter (the 412-loser re-reads HEAD + retries), so
        # concurrent appends — process-local pthread workers OR cross-process
        # nodes — serialize at the slot object, not at a process-wide mutex.
        #
        # WHY THIS IS SAFE (the gate is an allocator guard, not a correctness
        # lock — see the module header): the gate only ever
        # serialized over the bundled-tcmalloc central freelist to mask an
        # allocator corruption under contended-append churn. That corruption
        # has two distinct lost-origin (heap-reuse) causes, both fixed at
        # the SOURCE:
        # * the S3 conditional store's transport is held through a
        #     concrete-origin `ArcPointer[Optional[...]]`, never a
        #     `Slab[Optional[...]]`+`MutExternalOrigin` wildcard interior-
        #     mut (byte-slab + wildcard defeats ASAP-destruction of the
        #     HttpClient pool's heap buffers).
        # * the 412-retry GET-then-PUT ASAP-defer is closed
        #     by the per-attempt `_try_append_at` frame drop barrier (the GET's
        #     HTTP transients now materialize at the function-return boundary,
        #     never surviving into the next PUT's allocations).
        # With the corrupting allocations confined, the contended-append churn no
        # longer publishes a corrupt node to the shared central freelist, so the
        # serialization the gate provided is not load-bearing here: a
        # 2-process shared-prefix append crasher runs clean at 50+ rounds and a
        # multi-node produce-contention run is crash-free.
        # There is NO in-memory critical section in `_append_inner` to protect
        # (the store is per-instance; `_HEAD` is an S3 object, not process state;
        # the only shared object is the freelist the gate masked).
        return self._append_inner(
            body, record_count, writer_lease_epoch, current_lease_epoch
        )

    # ---- OCC-coupled single-slot append (table-store correctness slice) ----

    def try_append_at_seq(
        mut self,
        candidate_seq: Int64,
        base_offset: Int64,
        body: List[UInt8],
        record_count: Int64,
        writer_lease_epoch: Int64 = Int64(0),
        current_lease_epoch: Int64 = Int64(0),
    ) raises -> Optional[AppendResult]:
        """ONE `If-None-Match` create-CAS at the EXACT slot `candidate_seq`
        (no internal head re-read, no escalation past it). Returns
        `Some(AppendResult)` on WIN (the slot was free and we took it),
        `None` on a 412 (someone else owns the slot — the caller MUST re-read
        the AUTHORITATIVE head and re-run its conflict check before retrying).

        WHY THIS EXISTS (the table-store OCC/create-CAS coupling). The hot
        `append` path targets `cached_head+1`
        and ESCALATES past it on contention, so the slot it ultimately wins can
        be MORE THAN ONE past any head a caller validated against. For the
        OCC first-committer-wins check that is a SILENT isolation hole: a
        conflicting chunk could land in the un-checked gap `(occ_head, won-1]`.
        This verb lets the caller couple the two precisely — OCC-validate
        against `read_head_authoritative()`, then create-CAS at exactly
        `auth_head + 1`; a 412 forces re-read-authoritative + re-OCC, so the
        won slot is ALWAYS exactly `occ_validated_head + 1` and the checked
        window `(snapshot, occ_head]` leaves zero gap below the commit.

        The store-internal `_try_append_at` does the same single-attempt CAS
        for the hot path; this is its narrow PUBLIC wrapper (still confining
        all raw `conditional_put` arithmetic inside this module). It also does
        the best-effort monotone `_HEAD` advance on a win (so a subsequent
        cached-`read_head` snapshot tracks the tail), exactly like the hot
        path. The `_HEAD` cache is NEVER trusted for correctness (the caller's
        OCC uses `read_head_authoritative`).

        Runs LOCK-FREE (same rationale as `append` — the slot create-CAS is
        the sole correctness arbiter)."""
        if record_count < Int64(0):
            raise Error(
                "CasManifestStore.try_append_at_seq: negative record_count"
            )
        if candidate_seq < Int64(0):
            raise Error(
                "CasManifestStore.try_append_at_seq: negative candidate_seq"
            )
        # Writer-lease-epoch fence. Reject a stale
        # displaced writer BEFORE the single-slot create-CAS. The callers
        # (komira_table_store's table_store; and the adaptive-index-sharding
        # `IndexShardControl.try_bump_target` epoch-fenced count bump)
        # do NOT supply leases, so the defaults (0,0) make this a
        # harmless no-op for them; the fence is here for surface uniformity with
        # `append` / `append_idempotent`. (The index control record carries its OWN
        # epoch fence in the chunk BODY — a separate, higher-level decision-
        # generation fence — independent of this writer-lease fence.) A fenced
        # writer raises the classified `lease_fenced` error (distinct from the
        # `None` 412-loser signal).
        if writer_lease_epoch < current_lease_epoch:
            raise Error(
                "CasManifestStore.try_append_at_seq: "
                + _LEASE_FENCED_MARKER
                + " — writer_lease_epoch "
                + String(writer_lease_epoch)
                + " < current_lease_epoch "
                + String(current_lease_epoch)
                + " prefix="
                + self._prefix
            )
        # Build the ManifestHead the single-attempt helper expects (it claims
        # `head.chunk_seq + 1` at base `head.next_offset`). We want the create
        # at `candidate_seq`, so pass `chunk_seq = candidate_seq - 1`. The
        # `_HEAD` etag is read best-effort for the monotone advance fast path;
        # an empty etag falls back to the read-recheck advance.
        var head = ManifestHead(
            candidate_seq - Int64(1), base_offset, String("")
        )
        var head_etag = self._read_head_etag()
        # Flush-op reduction: the OCC path commits a chunk WITHOUT going
        # through the hot `_append_inner` local-cache update, so any warm local
        # cache on THIS instance is now stale w.r.t. an OCC win. Invalidate it so
        # a subsequent `append` re-reads the true tail (this path is the table-store
        # OCC caller, which does not interleave with `append` on one instance in
        # practice; the invalidate keeps the two surfaces coherent regardless).
        # The OCC path still performs its own durable advance (default
        # `defer_durable_advance=False`).
        var res = self._try_append_at(head, head_etag, body, record_count, 1)
        if res:
            self._head_cache = _LocalHeadCache.cold()
        return res^

    # ---- POLL-SHAPED create-CAS support ----------
    #
    # The parkable counterpart of `try_append_at_seq` lives in the parametric
    # `AsyncManifestAppendOp[Storage]` struct BELOW (which carries the wider
    # `Storage: ... & AsyncCasStore` bound — Mojo 1.0.0b1 expresses a wider trait
    # requirement on a parametric STRUCT, not a method of a weaker-bounded
    # struct). To keep ALL the raw key arithmetic + the `_HEAD` advance inside
    # THIS module (the encapsulation contract — exactly as `try_append_at_seq`
    # confines `conditional_put`), the op delegates to these two narrow base-
    # bound helpers: `async_append_build_chunk` (build the chunk key + encode the
    # chunk for the parkable `cas_put_start`) and `apply_async_append_win` (the
    # win-path best-effort monotone `_HEAD` advance + cache invalidate, identical
    # to the sync win). The op only ever sees a `Path` + opaque bytes + an
    # AppendResult — never the offset/encoding arithmetic.

    def async_append_build_chunk(
        self, candidate_seq: Int64, body: List[UInt8], record_count: Int64
    ) raises -> Tuple[Path, List[UInt8]]:
        """Build the (chunk key, encoded chunk) for a poll-shaped create-CAS at
        `candidate_seq` (confines `chunk_key` + `encode_chunk` to this module).
        The op moves the encoded bytes into the conformer's `cas_put_start`."""
        if record_count < Int64(0):
            raise Error(
                "CasManifestStore.async_append_build_chunk: negative"
                " record_count"
            )
        if candidate_seq < Int64(0):
            raise Error(
                "CasManifestStore.async_append_build_chunk: negative"
                " candidate_seq"
            )
        var ck = chunk_key(self._prefix, candidate_seq)
        var encoded = encode_chunk(body, record_count)
        return (ck^, encoded^)

    def apply_async_append_win(
        mut self,
        candidate_seq: Int64,
        base_offset: Int64,
        record_count: Int64,
        var won_etag: String,
        log_start_seq_after_win: Int64 = Int64(-1),
    ) raises -> None:
        """Finalize a poll-shaped create-CAS WIN: the same best-effort monotone
        `_HEAD` advance + local-cache invalidate the sync `try_append_at_seq`
        does on its win (so a subsequent cached `read_head` tracks the tail). A
        lost advance is recoverable by LIST; table-store correctness reads always go
        authoritative. The op passes the slot + base + the won chunk etag.

        On a guarded manifest the op passes `log_start_seq_after_win`, the
        `_LOG_START` its parked check phase read after the win; a win below it
        (or a missing read, -1) raises instead of advancing `_HEAD`
        (manifest_slot_guard.mojo). Unguarded manifests ignore it."""
        if self._reaped_slot_guard:
            if log_start_seq_after_win < Int64(0):
                raise Error(
                    "CasManifestStore.apply_async_append_win: a guarded"
                    " manifest needs the _LOG_START read after the win"
                )
            if won_slot_is_reaped(candidate_seq, log_start_seq_after_win):
                self._head_cache = _LocalHeadCache.cold()
                raise slot_reaped_error("apply_async_append_win")
        self._try_advance_head(
            candidate_seq,
            base_offset + record_count,
            won_etag,
            candidate_seq - Int64(1),
            String(""),  # no read `_HEAD` etag on the parked path -> read-recheck
        )
        self._head_cache = _LocalHeadCache.cold()

    # ---- exactly-once append (the producer-batch sentinel protocol) ----

    def read_dedup_sentinel(
        self, producer_id: Int64, first_seq: Int64
    ) raises -> Optional[DedupSentinel]:
        """Read the dedup sentinel for a batch identity `(producer_id,
        first_seq)`, or `None` if the batch was never claimed (the phantom-detect
        read; exactly-once atomicity). The returned `DedupSentinel`
        carries the etag for the next `If-Match` finalize. Strongly consistent
        (S3 read-after-write). READ verb -> SHARED (read) lock."""
        _cas_gate_rdlock()
        try:
            var r = self._read_dedup_sentinel_inner(producer_id, first_seq)
            _cas_gate_unlock()
            return r^
        except e:
            _cas_gate_unlock()
            raise e^

    def _read_dedup_sentinel_inner(
        self, producer_id: Int64, first_seq: Int64
    ) raises -> Optional[DedupSentinel]:
        # UNLOCKED sentinel read (the gate is held by the caller — the public
        # `read_dedup_sentinel` rdlock, or `append_idempotent`'s wrlock).
        var key = dedup_sentinel_key(self._prefix, producer_id, first_seq)
        try:
            var raw = self._store.get(key)
            var meta = self._store.head(key)
            return Optional(decode_dedup_sentinel(raw, String(meta.etag)))
        except e:
            if _is_not_found(String(e)):
                return Optional[DedupSentinel](None)
            raise e^

    def append_idempotent(
        mut self,
        body: List[UInt8],
        record_count: Int64,
        producer_id: Int64,
        producer_epoch: Int64,
        first_seq: Int64,
        last_seq: Int64,
        registered_epoch: Int64,
        writer_lease_epoch: Int64 = Int64(0),
        current_lease_epoch: Int64 = Int64(0),
    ) raises -> IdempotentAppendResult:
        """Exactly-once append under (a) CAS phantom failure (durable-but-raised
        commit) and (b) cross-process same-producer contention
        (exactly-once atomicity).

        The FOUR-step protocol: epoch-fence → Step 1 claim
        `(producer_id, first_seq)` via an `If-None-Match` create-CAS (the single
        cross-process LINEARIZATION POINT — exactly one winner) → Step 2 the
        EXISTING gapless `_append_inner` (unchanged) → Step 3 finalize the
        sentinel with the committed offset via `If-Match`. A 412 at Step 1, OR an
        `_append_inner` raise at Step 2, runs the EXACT phantom-detect
        (`_scan_tail_for_batch` matches the chunk's `(producer_id, first_seq)`
        identity — no max-seq heuristic), returning DUPLICATE/COMMITTED with the
        recorded offset when a chunk is durable, else releasing the staged claim
        and signalling retryable.

        `registered_epoch` is the producer's currently-registered epoch (the
        fence input, read by the caller from the producer registry); an
        `producer_epoch < registered_epoch` returns FENCED with no write.

        Writer-lease-epoch fence: `writer_lease_epoch` is the
        appending owner's per-partition lease generation; `current_lease_epoch` is
        the live generation the caller read AUTHORITATIVELY at flush. A
        `writer_lease_epoch < current_lease_epoch` returns FENCED with NO write —
        evaluated at Step 0, BEFORE the sentinel create-CAS (the LP), so a stale
        displaced writer's records never take a slot. This is DISTINCT from the
        producer-epoch fence above (that is the Kafka producer-id IDENTITY fence;
        this is the partition-OWNERSHIP fence). Both default to 0 (no-op) for a
        caller that does not supply leases.

        CAS-GATE NARROWED: like
        `append`, this no longer holds the process-global write gate across its
        S3 round-trips. The sentinel create-CAS (`If-None-Match`, the single
        cross-process LINEARIZATION POINT) + the chunk append (whose own
        `If-None-Match` slot CAS is the gaplessness oracle) + the `If-Match`
        finalize all arbitrate correctness at their S3 objects; no process-wide
        mutex is needed. Runs LOCK-FREE. See `append`'s SAFETY block for the
        heap-reuse source-fix rationale (the transport held through a concrete
        origin; the retry-loop ASAP-defer frame barrier). Allocator-churn class
        is identical to `append`; the same evidence covers it.
        """
        return self._append_idempotent_inner(
            body,
            record_count,
            producer_id,
            producer_epoch,
            first_seq,
            last_seq,
            registered_epoch,
            writer_lease_epoch,
            current_lease_epoch,
        )

    def _resolve_existing_sentinel(
        mut self,
        producer_id: Int64,
        first_seq: Int64,
    ) raises -> IdempotentAppendResult:
        # Step 1's create-CAS 412'd — a sentinel already exists. Resolve the
        # EXACT outcome by reading it back. It
        # never guesses.
        var s_opt = self._read_dedup_sentinel_inner(producer_id, first_seq)
        if not s_opt:
            # The sentinel vanished between the 412 and the read (a concurrent
            # reaper released an abandoned staged claim). Signal retryable — the
            # client re-claims cleanly.
            return IdempotentAppendResult.retryable()
        ref s = s_opt.value()
        if s.is_committed():
            # FULLY committed — return the recorded offset (idempotent DUPLICATE).
            return IdempotentAppendResult.duplicate(
                s.committed_chunk_seq, s.base_offset, s.last_offset
            )
        # STAGED claim (committed_chunk_seq == -1): the winner is (i) mid-append,
        # (ii) crashed in the phantom window, or (iii) committed but lost the
        # finalize. Disambiguate by scanning the authoritative tail for THIS
        # batch identity.
        var found = self._scan_tail_for_batch(producer_id, first_seq)
        if found:
            # The chunk IS durable (finalize lost / winner still finishing).
            # Heal the sentinel forward (best-effort If-Match) + return DUPLICATE.
            self._best_effort_finalize(
                producer_id,
                first_seq,
                s.etag,
                found.value().chunk_seq,
                found.value().base_offset,
                found.value().last_offset,
            )
            return IdempotentAppendResult.duplicate(
                found.value().chunk_seq,
                found.value().base_offset,
                found.value().last_offset,
            )
        # No chunk for this batch in the tail => the winner has NOT committed yet
        # (still in-flight) OR died before the chunk landed. The staged sentinel
        # is a CLAIM, not a commit. Signal retryable so the client re-drives.
        return IdempotentAppendResult.retryable()

    def _append_idempotent_inner(
        mut self,
        body: List[UInt8],
        record_count: Int64,
        producer_id: Int64,
        producer_epoch: Int64,
        first_seq: Int64,
        last_seq: Int64,
        registered_epoch: Int64,
        writer_lease_epoch: Int64 = Int64(0),
        current_lease_epoch: Int64 = Int64(0),
    ) raises -> IdempotentAppendResult:
        if record_count < Int64(0):
            raise Error("CasManifestStore.append_idempotent: negative record_count")

        # ---- Step 0a: producer-EPOCH fence (the Kafka producer-id IDENTITY fence,
        # re-validated at the LP) ----
        if producer_epoch < registered_epoch:
            return IdempotentAppendResult.fenced()

        # ---- Step 0b: writer-LEASE-EPOCH fence (the partition-OWNERSHIP fence,
        #) ---- A stale displaced owner whose lease generation is
        # below the live one is rejected HERE, BEFORE the sentinel create-CAS (the
        # LP), so its records never claim a batch identity nor take an offset (the
        # torn-offset guard). Distinct from the producer-epoch fence above. Returns
        # the DISTINCT lease_fenced() outcome (IDEMPOTENT_LEASE_FENCED) so the
        # broker maps it to NOT_LEADER_OR_FOLLOWER, not INVALID_PRODUCER_EPOCH.
        # Defaults (0,0) make this a no-op for a non-lease caller.
        #
        # BEST-EFFORT — the RESIDUAL TOCTOU WINDOW (honest, by design): the caller
        # reads `current_lease_epoch` and THEN calls this append; those two are NOT
        # atomic on a single manifest. The interleaving
        #   t0  caller reads current (= G)   [still the owner of record]
        #   t1  ownership transfers, the live gen -> G+1
        #   t2  this create-CAS lands with the gen read at t0 (= G) -> writer == G,
        #       current == G -> G < G is FALSE -> NOT fenced -> the stale chunk
        #       slips into the live stream (a TORN OFFSET).
        # is irreducible for a SINGLE manifest per partition: the read and the
        # create-CAS cannot be coupled atomically. This fence catches the COMMON
        # case (a displaced owner that has ALREADY OBSERVED the post-transfer
        # generation, so its current > writer at flush), which is defense-in-depth,
        # NOT a full correctness barrier (best-effort by construction). FULL
        # torn-offset correctness needs per-generation SUB-LINEAGES (a DISJOINT
        # keyspace per generation, where a stale writer's chunk is STRUCTURALLY
        # unable to enter the new owner's stream). That is a SEPARATE mechanism,
        # NOT this fence.
        if writer_lease_epoch < current_lease_epoch:
            return IdempotentAppendResult.lease_fenced()

        # ---- Step 1: claim the batch identity (the LINEARIZATION POINT) ----
        var key = dedup_sentinel_key(self._prefix, producer_id, first_seq)
        var staged = DedupSentinel.staged(
            producer_id, producer_epoch, first_seq, last_seq
        )
        var sentinel_etag: String
        try:
            var meta = self._store.conditional_put(
                key, encode_dedup_sentinel(staged), WritePrecondition.if_none_match_star()
            )
            sentinel_etag = String(meta.etag)
        except e:
            if _is_precondition(String(e)):
                # SOMEONE (the original, or a concurrent sibling) already claimed
                # this batch — resolve idempotently.
                return self._resolve_existing_sentinel(producer_id, first_seq)
            raise e^

        # ---- WE WON the claim. We are the sole committer of this batch. ----

        # ---- Step 2: append the chunk (the existing gapless allocator) ----
        # The leases are passed through for uniformity; the Step-0b fence already
        # guaranteed `writer >= current` above, so the inner re-check is a no-op
        # on this path (it cannot newly fence here).
        var append_res: AppendResult
        try:
            append_res = self._append_inner(
                body, record_count, writer_lease_epoch, current_lease_epoch
            )
        except append_err:
            # Step 2 RAISED. EXACT phantom-detect: did the chunk land anyway?
            var found = self._scan_tail_for_batch(producer_id, first_seq)
            if found:
                # PHANTOM SUCCESS: the chunk DID land; only the response was
                # lost. Heal the sentinel + return COMMITTED (idempotent success
                # re-raise would DOUBLE-WRITE on the client's retry).
                self._best_effort_finalize(
                    producer_id,
                    first_seq,
                    sentinel_etag,
                    found.value().chunk_seq,
                    found.value().base_offset,
                    found.value().last_offset,
                )
                return IdempotentAppendResult(
                    IDEMPOTENT_COMMITTED,
                    found.value().chunk_seq,
                    found.value().base_offset,
                    found.value().last_offset,
                    found.value().attempts,
                )
            # Genuine no-commit. We hold the staged claim; release it so the
            # client's retry re-claims cleanly (no false-DUPLICATE), then
            # re-raise retryable. SAFE: only the WINNER holds the etag; the
            # delete is conditioned on "no chunk durable" (verified by the
            # authoritative scan), so it releases an abandoned claim, never a
            # real commit.
            self._store.delete(key)
            raise append_err^

        # ---- Step 3: finalize the sentinel with the committed location ----
        # FAST PATH: we are the WINNER and hold the staged etag from Step 1, so a
        # SINGLE If-Match PUT advances staged->committed — NO extra GET+HEAD
        # re-read on the hot commit path (the per-append cost stays +1 write for
        # the claim +1 write for the finalize, never an extra read). A lost
        # finalize is recovered by the chunk-scan fallback on a subsequent
        # retry (the staged sentinel + the durable chunk together still resolve
        # to DUPLICATE — see `_resolve_existing_sentinel`).
        #
        # THROUGHPUT NOTE (exactly-once, under cross-node split-brain contention): under
        # single-record produces the finalize is the SECOND extra write on the
        # exclusive cas-gate hot path, and at high cross-node contention it
        # lengthens the critical section enough to push the slot-CAS budget over
        # the 45s client deadline. The finalize is a pure OPTIMIZATION (it lets a
        # duplicate retry read the offset directly instead of scanning), NOT a
        # correctness requirement: the EXACT chunk-identity scan recovers the
        # offset whether or not the sentinel was finalized. So we GATE the
        # hot-path finalize on `_FINALIZE_ON_HOT_PATH` — OFF by default, which
        # halves the per-append extra-write cost (back to +1) and restores the
        # contention headroom. A retry of a committed-but-staged batch pays one tail
        # scan (the rare lost-ack path), which is bounded + early-exits near the
        # tail. (The staged-orphan reaper MUST scan-before-delete so it never
        # reaps a committed-but-staged sentinel — that contract holds regardless
        # of this gate.)
        comptime if _FINALIZE_ON_HOT_PATH:
            self._finalize_own_claim(
                producer_id,
                producer_epoch,
                first_seq,
                last_seq,
                sentinel_etag,
                append_res.chunk_seq,
                append_res.base_offset,
                append_res.last_offset,
            )
        return IdempotentAppendResult.committed(append_res)

    def _finalize_own_claim(
        mut self,
        producer_id: Int64,
        producer_epoch: Int64,
        first_seq: Int64,
        last_seq: Int64,
        staged_etag: String,
        chunk_seq: Int64,
        base_offset: Int64,
        last_offset: Int64,
    ) -> None:
        # ONE-CALL finalize for the WINNER: advance the staged sentinel ->
        # committed via an If-Match on the etag we got from the Step-1 create-CAS.
        # No GET/HEAD — we already know the identity + the etag. Best-effort
        # (swallow errors; a lost finalize is recovered by the chunk-scan
        # fallback). If `staged_etag` is empty (shouldn't happen on this path),
        # fall back to the re-read finalize.
        if staged_etag.byte_length() == 0:
            self._best_effort_finalize(
                producer_id,
                first_seq,
                staged_etag,
                chunk_seq,
                base_offset,
                last_offset,
            )
            return
        try:
            var key = dedup_sentinel_key(self._prefix, producer_id, first_seq)
            var committed = DedupSentinel(
                producer_id,
                producer_epoch,
                first_seq,
                last_seq,
                chunk_seq,
                base_offset,
                last_offset,
                String(""),
            )
            _ = self._store.conditional_put(
                key,
                encode_dedup_sentinel(committed),
                WritePrecondition.if_match(staged_etag),
            )
        except e:
            _ = e  # advisory; a lost finalize is recovered by the chunk scan

    def _best_effort_finalize(
        mut self,
        producer_id: Int64,
        first_seq: Int64,
        expected_etag: String,
        chunk_seq: Int64,
        base_offset: Int64,
        last_offset: Int64,
    ) -> None:
        # Advance the staged sentinel -> committed via an If-Match CAS on the
        # CURRENT etag (re-read to carry the staged body's identity — we may be
        # healing a SIBLING's claim, not our own). Best-effort: a lost
        # finalize is recovered by the chunk-scan fallback on the next retry.
        _ = expected_etag  # advisory hint; we re-read the authoritative etag
        try:
            var key = dedup_sentinel_key(self._prefix, producer_id, first_seq)
            var cur = self._read_dedup_sentinel_inner(producer_id, first_seq)
            if not cur:
                return  # claim vanished (reaper) — nothing to finalize
            ref c = cur.value()
            if c.is_committed():
                return  # already finalized by another path — done
            var carried = DedupSentinel(
                c.producer_id,
                c.producer_epoch,
                c.first_seq,
                c.last_seq,
                chunk_seq,
                base_offset,
                last_offset,
                String(""),
            )
            var precond = WritePrecondition.if_match(c.etag)
            _ = self._store.conditional_put(
                key, encode_dedup_sentinel(carried), precond
            )
        except e:
            _ = e  # advisory; a lost finalize is recovered by the chunk scan

    def _scan_tail_for_batch(
        self, producer_id: Int64, first_seq: Int64
    ) raises -> Optional[AppendResult]:
        # EXACT phantom-detect: walk the authoritative tail DOWNWARD from the
        # bucket's true head and stop at the first chunk whose body carries
        # `(producer_id, first_seq)` (the broker's producer trailer is in
        # every chunk body). A chunk with that
        # identity exists IFF the append committed — no false positive (the
        # identity is exact), no false negative (the log-start-aware
        # authoritative tail sees every live committed chunk). Bounded: the
        # latest batch of an idempotent producer is near the tail (early-exit),
        # reusing `recover_last_committed_seq`'s top-down early-exit walk.
        #
        # Returns the committed `AppendResult{chunk_seq, base_offset, last_offset}`
        # (etag/attempts unused by the caller) when found, else None.
        #
        # This takes no gate (`append_idempotent` runs lock-free).
        # We decode the manifest body via this module's chunk codec, then read
        # the broker's producer trailer directly off the consumer body bytes
        # (the trailer offsets are stable; see the broker manifest body's wire layout).
        #
        # Replay cumulative record_counts forward to derive each chunk's base
        # offset, seeded from the log-start (so a reaped prefix is honored). We
        # need the base offset (a forward running sum) for the matching chunk, so
        # a single forward pass over `[log_start_seq .. top]` is the natural
        # shape; the idempotent producer's latest batch is near the tail so the
        # match early-exits. `_list_chunks` gives the true top (bucket-is-truth),
        # avoiding the double-read a full `_recover_head_by_list` replay would do.
        var top = self._list_chunks().chunk_seq
        if top < Int64(0):
            return Optional[AppendResult](None)
        var ls = self._read_log_start_inner()
        var start_seq = ls.log_start_seq
        var start_off = ls.log_start_offset
        if start_seq < Int64(0):
            start_seq = Int64(0)
            start_off = Int64(0)
        var next_off = start_off
        var seq = start_seq
        while seq <= top:
            var ck = chunk_key(self._prefix, seq)
            var c: List[UInt8]
            try:
                c = self._store.get(ck)
            except e:
                # Skipping an unreadable chunk would number every later chunk
                # (and the ack) too low. A 404 here is a chunk reaped after the
                # `_LOG_START` read (it moved past `seq`: restart from it, seq
                # strictly forward) or a torn lineage (refuse, as
                # `_recover_head_by_list` does).
                if not _is_not_found(String(e)):
                    raise e^
                var now = self._read_log_start_inner()
                if now.log_start_seq <= seq:
                    raise Error(
                        "CasManifestStore: batch scan found a MISSING committed"
                        " chunk at seq "
                        + String(seq)
                        + " (>= log_start_seq "
                        + String(now.log_start_seq)
                        + ") — torn manifest lineage, refusing to renumber."
                        " prefix="
                        + self._prefix
                    )
                next_off = now.log_start_offset
                seq = now.log_start_seq
                continue
            var rc = decode_chunk_record_count(c)
            var consumer_body = decode_chunk_body(c)
            var hit = _body_matches_producer_batch(
                consumer_body, producer_id, first_seq
            )
            if hit:
                var base = next_off
                var last = base + rc - Int64(1)
                return Optional(AppendResult(seq, base, last, String(""), 0))
            next_off += rc
            seq += Int64(1)
        return Optional[AppendResult](None)

    def _try_append_at(
        mut self,
        head: ManifestHead,
        head_etag: String,
        body: List[UInt8],
        record_count: Int64,
        attempt: Int,
        defer_durable_advance: Bool = False,
    ) raises -> Optional[AppendResult]:
        # Flush-op reduction: when `defer_durable_advance`
        # is set (the hot `_append_inner` path), the WINNING attempt SKIPS the
        # durable best-effort `_HEAD` advance PUT (op 5) so the ack does NOT block
        # on it. The caller (`_append_inner`) instead updates its LOCAL `_HEAD`
        # cache synchronously from the win, which is what gives the NEXT append a
        # correct candidate WITHOUT a GET. The durable `_HEAD` is a recovery cache
        # (LIST / `_recover_head_by_list` reconstruct it), so a deferred advance is
        # fully recoverable. Default `False` preserves every OTHER caller
        # (`try_append_at_seq`, the OCC path) which still does the durable advance
        # on a win.
        #
        # The cross-process CAS crash, second instance (FIX): one CAS attempt
        # in its OWN function scope. The retry loop (`_append_inner`) calls
        # this fresh per attempt, INTERLEAVED with `_read_head_inner` GETs.
        #
        # # SAFETY (lost-origin / premature ASAP-drop): the within-path
        # bisect proved the corruptor is the GET-then-PUT sequence executed
        # back-to-back in the retry loop WITHOUT an intervening stack unwind
        # (bisect: 412→re-read-GET→raise = CLEAN; 412→re-PUT-only = CLEAN;
        # 412→re-read-GET→re-PUT = CRASH; and a per-attempt stack-unwind across
        # two `append` calls = CLEAN). Under the no-unwind `continue` the AOT
        # compiler ASAP-defers a heap transient owned by the GET's HTTP
        # response path past the loop back-edge so its drop overlaps the next
        # `conditional_put` (PUT) allocations → tcmalloc recycles the block →
        # the next `String._alloc`/`Path.parse` faults on the corrupted
        # freelist next-ptr. Confining EACH attempt's PUT to its own function
        # frame gives those transients a CONCRETE tracked drop point at this
        # function's return boundary (the same materialization the unwind
        # forced), so no GET transient survives into the PUT. Returns
        # `Some(result)` on WIN, `None` on a 412 (caller re-reads + retries);
        # re-raises any non-412 error. A guarded manifest raises `slot_reaped`
        # or `log_start_unread` instead of returning a win it must not
        # acknowledge (manifest_slot_guard.mojo).
        var candidate_seq = head.chunk_seq + Int64(1)
        var base = head.next_offset
        var ck = chunk_key(self._prefix, candidate_seq)
        var encoded = encode_chunk(body, record_count)
        # Only the create sits inside the `try`: a 412 there is a lost slot. The
        # reaped-slot check runs outside it, so no error raised after the win
        # can be mistaken for a lost slot and re-append the same body.
        var meta: ObjectMeta
        try:
            meta = self._store.conditional_put(
                ck, encoded, WritePrecondition.if_none_match_star()
            )
        except e:
            if not _is_precondition(String(e)):
                raise e^
            # 412 — another writer won this slot. Signal retry to the caller.
            return Optional[AppendResult](None)
        # Reaped-slot guard rule 1 (opt-in): before any `_HEAD` or cache update.
        if self._reaped_slot_guard:
            self._refuse_win_below_log_start(candidate_seq, "append")
        # WON the slot — its records occupy [base, last]. Ordering
        # is now fixed.
        var meta_etag = meta.etag
        var last = base + record_count - Int64(1)
        # Best-effort MONOTONE HEAD advance. The fast path is a ONE-CALL
        # If-Match on `head_etag` (the `_HEAD` etag this attempt read): it
        # succeeds only if `_HEAD` is STILL at `candidate_seq-1`, so the
        # write to `candidate_seq` is strictly forward (monotone). On any
        # conflict / empty etag it falls back to the read-recheck loop. A
        # lost advance is recoverable by LIST.
        # Flush-op reduction: DEFER this off the ack-blocking path on
        # the hot append (the caller updates its local cache synchronously
        # instead). The monotone If-Match invariant is preserved for any
        # advance that DOES run (the OCC path + the contention/cold fall-back
        # both keep calling `_try_advance_head`, which never writes `_HEAD`
        # backwards).
        if not defer_durable_advance:
            self._try_advance_head(
                candidate_seq,
                base + record_count,
                meta_etag,
                head.chunk_seq,
                head_etag,
            )
        return Optional[AppendResult](
            AppendResult(candidate_seq, base, last, meta_etag^, attempt)
        )

    def _refuse_win_below_log_start(
        mut self, candidate_seq: Int64, site: String
    ) raises:
        """Reaped-slot guard rules 1 and 2 (manifest_slot_guard.mojo), run after
        a create WON `candidate_seq` and before any `_HEAD` or cache update. ONE
        GET of the `_LOG_START` body. A win below it raises `slot_reaped`; a
        failed read raises `log_start_unread` (fail closed). Either way the head
        cache is invalidated and nothing is acknowledged."""
        var log_start_seq: Int64
        try:
            log_start_seq = self._read_log_start_seq_inner()
        except e:
            self._head_cache = _LocalHeadCache.cold()
            raise log_start_unread_error(site, String(e))
        if won_slot_is_reaped(candidate_seq, log_start_seq):
            self._head_cache = _LocalHeadCache.cold()
            raise slot_reaped_error(site)

    def _append_inner(
        mut self,
        body: List[UInt8],
        record_count: Int64,
        writer_lease_epoch: Int64 = Int64(0),
        current_lease_epoch: Int64 = Int64(0),
    ) raises -> AppendResult:
        if record_count < Int64(0):
            raise Error("CasManifestStore.append: negative record_count")
        # Writer-lease-epoch fence. A stale displaced owner whose
        # lease generation is BELOW the live one must NOT take an offset — reject
        # it HERE, before the retry loop runs even one chunk_key create-CAS, so a
        # zombie writer's records never splice into the new owner's lineage (the
        # torn-offset guard). Defaults (0,0) make this a no-op for non-broker
        # callers. SAFE-BY-MONOTONICITY: `current_lease_epoch` was read
        # authoritatively at flush; because the live generation only INCREASES
        # (assign_partitions bumps it on transfer, never resets), reading it
        # slightly before the actual create-CAS LP is conservative — the value can
        # only go UP between the read and the LP, so `writer < current` stays true
        # for any genuinely displaced writer.
        if writer_lease_epoch < current_lease_epoch:
            raise Error(
                "CasManifestStore.append: "
                + _LEASE_FENCED_MARKER
                + " — writer_lease_epoch "
                + String(writer_lease_epoch)
                + " < current_lease_epoch "
                + String(current_lease_epoch)
                + " (stale displaced writer rejected before taking an offset)"
                + " prefix="
                + self._prefix
            )
        # Flush-op reduction: the LOCAL `_HEAD` cache.
        # On a WARM cache (the single-writer-per-instance steady state) we
        # compute the candidate slot + base offset DIRECTLY from the cache,
        # ELIDING the `_HEAD` GET (op 2) AND the etag HEAD (op 3) — the two reads
        # that the 5-op ack spent re-establishing a tail this instance already
        # knows from its last win. A COLD/invalidated cache runs the existing
        # read/LIST-recovery path. The cache is NEVER a correctness oracle: a
        # stale cache only causes a 412 at the chunk create-CAS below (someone
        # else won the slot) -> we INVALIDATE + fall back to the re-read path;
        # the create-CAS remains the sole gaplessness arbiter, so a stale cache
        # can never produce a committed wrong/duplicate offset.
        #
        # `from_cache` tracks whether THIS attempt's `head` came from the warm
        # cache, so a 412 on a cache-derived attempt invalidates the cache before
        # the fall-back (a cache-derived 412 means the cache is demonstrably
        # stale; a read-derived 412 is normal contention and leaves the cache —
        # already cold on that branch — untouched).
        var head: ManifestHead
        var head_etag: String
        var from_cache = False
        if self._head_cache.present:
            # PIGGYBACK the deferred durable `_HEAD` advance (best-effort, bounded
            # cadence). The durable `_HEAD` is a recovery cache; we deferred its
            # advance off prior acks. Before this append (NOT blocking the prior
            # ack), if we have deferred too many advances, persist the cached tail
            # durably so a cold reader / fresh handle never sees a `_HEAD` more
            # than `_HEAD_ADVANCE_DEFER_CADENCE` chunks stale. Monotone +
            # best-effort: `_try_advance_head` never writes `_HEAD` backwards and
            # swallows errors (the bucket is truth, recoverable by LIST). This is
            # the "piggyback onto the next append's write" half of the deferral.
            if (
                self._head_cache.deferred_advances
                >= _HEAD_ADVANCE_DEFER_CADENCE
            ):
                self._persist_deferred_head_advance()
            head = ManifestHead(
                self._head_cache.chunk_seq,
                self._head_cache.next_offset,
                String(""),
            )
            head_etag = self._head_cache.head_etag
            from_cache = True
        else:
            # UNLOCKED internal read (the gate is already held by `append`).
            # Guarded manifests clamp a durable `_HEAD` below `_LOG_START`.
            head = self._read_head_inner(
                clamp_to_log_start=self._reaped_slot_guard
            )
            # Capture the `_HEAD` OBJECT etag so the winning append can do a
            # ONE-CALL monotone advance (If-Match on this etag) instead of a
            # GET+HEAD+PUT cycle. Empty when `_HEAD` is absent (LIST-recovered
            # head) or after a force-authoritative read — the advance then falls
            # back to its read-recheck loop. (Stale-head forward-progress perf.)
            head_etag = self._read_head_etag()
        var attempt = 0
        # Stale-head forward progress: count CONSECUTIVE 412s. After
        # N (=3) the cached `_HEAD` is demonstrably stale/contended, so the
        # NEXT re-read BYPASSES the cache and goes straight to the bucket's
        # authoritative tail (LIST recovery). This is what breaks the livelock:
        # a writer that keeps recomputing the same already-taken
        # `candidate_seq` from a stale-low _HEAD instead computes a fresh seq
        # beyond ALL taken slots. We re-escalate every N 412s so a writer that
        # is still losing keeps re-anchoring on the true tail.
        comptime LIST_ESCALATE_AFTER = CAS_LIST_ESCALATE_AFTER
        var consecutive_412 = 0
        while True:
            attempt += 1
            # ONE attempt per function call — the per-attempt frame is the
            # drop barrier that keeps the prior GET's HTTP transients from
            # ASAP-deferring into this PUT (see _try_append_at SAFETY block).
            # Flush-op reduction: defer the durable `_HEAD` advance (op 5)
            # off the ack ONLY when this attempt's head came from the WARM local
            # cache (`from_cache`). On the COLD/first-flush path and on a
            # contention FALL-BACK (read/probe/escalate-derived head), we KEEP the
            # durable advance — those paths are not the steady-state hot path, and
            # eagerly advancing `_HEAD` there keeps it present + fresh for cold
            # readers / fresh handles (so they don't pay an O(N) LIST recovery).
            # The warm cache update (below) is what carries the tail forward
            # without a GET; the durable `_HEAD` PUT is deferred + best-effort
            # (recoverable by LIST). The chunk create-CAS (durability +
            # gaplessness) and the segment PUT are always unchanged.
            var maybe = self._try_append_at(
                head, head_etag, body, record_count, attempt, from_cache
            )
            if maybe:
                ref won = maybe.value()
                # Update the LOCAL cache synchronously: the owner now knows the
                # true tail is `won.chunk_seq` at `next = won.last_offset + 1`.
                # `head_etag` stays unknown (we deferred the durable advance on the
                # warm path; the next append's advance falls back to its
                # read-recheck path IF it ever needs to advance durably). This is
                # the synchronous-cache / deferred-durable split the op-reduction
                # requires.
                #
                # `deferred_advances` counts consecutive WARM wins that deferred
                # their durable advance:
                #   * WARM win (`from_cache`): we deferred -> carry the prior
                #     count forward + 1. The cadence piggyback (above) persists +
                #     resets it when it reaches `_HEAD_ADVANCE_DEFER_CADENCE`.
                #   * COLD / contention-fall-back win (`not from_cache`): this win
                #     DID the durable advance (`defer_durable_advance=False`), so
                #     `_HEAD` is current -> reset the count to 0.
                var new_deferred = Int64(0)
                if from_cache:
                    var prior_deferred = Int64(0)
                    if self._head_cache.present:
                        prior_deferred = self._head_cache.deferred_advances
                    new_deferred = prior_deferred + Int64(1)
                self._head_cache = _LocalHeadCache(
                    True,
                    won.chunk_seq,
                    won.last_offset + Int64(1),
                    String(""),
                    new_deferred,
                )
                return maybe.take()
            # 412 — another writer won this slot. If THIS attempt came from the
            # warm local cache, the cache is demonstrably STALE (a concurrent
            # sibling instance won the slot we computed) — INVALIDATE it so the
            # fall-back path below re-anchors on the bucket's true tail and the
            # NEXT append (after this one wins) repopulates a fresh cache. The
            # create-CAS already protected correctness; this just stops us from
            # recomputing the same stale candidate.
            if from_cache:
                self._head_cache = _LocalHeadCache.cold()
                from_cache = False
            # 412 — another writer won this slot. Apply the
            # bounded backoff with full jitter, then re-read HEAD and
            # retry.
            consecutive_412 += 1
            if attempt > self._retry.max_retries:
                raise Error(
                    "CasManifestStore.append: exhausted "
                    + String(self._retry.max_retries)
                    + " retries under contention (retryable) — prefix="
                    + self._prefix
                )
            var upper = self._retry.backoff_us_for_attempt(attempt)
            _jittered_sleep_us(upper, attempt)
            # FORWARD-PROBE re-anchor: the slot we just tried
            # (`head.chunk_seq + 1`) is TAKEN — read THAT chunk directly (one GET
            # of a known key, NOT a LIST, NOT the lagging cached `_HEAD`) to learn
            # its record_count, and advance the head to it so the next attempt
            # tries `taken_seq + 1` at the correct running-sum base. This keeps a
            # contended writer re-anchored on the true tail WITHOUT the O(N) LIST
            # cost of the cached-_HEAD escalation. On a run of LIST_ESCALATE_AFTER
            # consecutive 412s (a writer that has fallen several slots behind), do
            # the O(gap) incremental authoritative re-anchor instead. Correctness
            # is preserved by the slot `If-None-Match` create-CAS (this is only a
            # forward-progress hint); the crash-recovery `_recover_head_by_list`
            # is UNTOUCHED.
            var taken_seq = head.chunk_seq + Int64(1)
            var force_auth = consecutive_412 >= LIST_ESCALATE_AFTER
            if force_auth:
                # The tier-2 LIST-escalation counter.
                # Increment ONCE per escalation, AT THE TRIGGER (not the
                # consecutive_412=0 reset below). DEFAULT-OFF: the guard means an
                # un-instrumented store does ZERO extra work (the field is None);
                # an instrumented store pays one Relaxed atomic fetch_add — no
                # new I/O. This is the super-linear severity escalator the
                # governor's tier-2 AND-gate consumes.
                #
                # CROSS-WRITER COUNTER SAFETY: the counter needs no stronger
                # ordering than Relaxed because there is no cross-writer SHARING
                # of a single counter. Each writer holds a scope-local,
                # non-Copyable `CasManifestStore` that OWNS a distinct
                # `OwnedPointer[MetricsSet]` (single-owner, never aliased — a
                # `clone()` mints a fresh Store with its own None holder), so two
                # writers never fetch_add the SAME `MetricsSet`. The `mut self`
                # on `append` further serializes every increment within one
                # writer (append is exclusive on its own store). The Relaxed
                # atomic fetch_add is therefore belt-and-suspenders — correct even
                # if a future caller were to share the holder — not load-bearing
                # for today's per-instance ownership.
                if self._escalation_metrics:
                    self._escalation_metrics.value()[].counter[
                        Self._CAS_LIST_ESCALATIONS
                    ]().inc_out_of_pipeline(Int64(1))
                consecutive_412 = 0
                head = self._escalate_head_incremental(head)
                head_etag = String("")
                continue
            var probed = self._probe_taken_chunk_forward(head, taken_seq)
            if probed:
                head = probed.take()
                head_etag = String("")
            elif self._reaped_slot_guard:
                # Reaped-slot guard rule 3: the taken slot is gone (reaped since
                # the 412), so this writer is below the log start and so may be
                # the durable `_HEAD`. Recover by LIST (log-start aware).
                head = self._recover_head_by_list()
                head_etag = String("")
            else:
                head = self._read_head_inner(force_authoritative=False)
                head_etag = self._read_head_etag()
            continue

    def _persist_deferred_head_advance(mut self) -> None:
        # Flush-op reduction: the bounded-cadence
        # piggyback of the deferred durable `_HEAD` advance. The hot warm-cache
        # append path DEFERS the durable `_HEAD` PUT off the ack (the local cache
        # carries the tail forward); this catches the durable `_HEAD` up to the
        # cached tail once every `_HEAD_ADVANCE_DEFER_CADENCE` warm appends so a
        # cold reader / fresh handle never sees a `_HEAD` more than the cadence
        # stale. BEST-EFFORT + MONOTONE: `_try_advance_head` (with an empty
        # expected etag -> the read-recheck slow path) never writes `_HEAD`
        # backwards and swallows all errors (the bucket is truth; a lost advance
        # is recoverable by LIST). On return the deferred counter is reset; if the
        # persist failed transiently it simply tries again on the next cadence.
        if not self._head_cache.present:
            return  # cov: unreachable the only caller checks _head_cache.present first
        var seq = self._head_cache.chunk_seq
        var next_off = self._head_cache.next_offset
        # `_try_advance_head` with empty `expected_head_etag` takes the monotone
        # read-recheck slow path: it GETs `_HEAD`, skips if already >= seq, else
        # If-Match advances. `expected_prev_seq = -1` + empty etag forces the slow
        # path (the fast one-call path requires a non-empty etag). The chunk etag
        # for `_HEAD.etag_of_last_chunk` is advisory only (a read_head fast-path
        # hint), so an empty value is fine.
        self._try_advance_head(
            seq, next_off, String(""), Int64(-1), String("")
        )
        # Reset the deferred counter regardless of the persist outcome — a
        # transient failure just re-defers, and the cadence will retry. Keep the
        # rest of the cache (tail position) intact.
        self._head_cache.deferred_advances = Int64(0)

    def _probe_taken_chunk_forward(
        self, prev_head: ManifestHead, taken_seq: Int64
    ) raises -> Optional[ManifestHead]:
        # FORWARD-PROBE re-anchor (exactly-once throughput). The slot `taken_seq` (=
        # prev_head.chunk_seq+1) just 412'd, so SOME writer committed it. Read
        # THAT chunk's record_count (one GET of a known key — far cheaper than a
        # LIST or a stale-_HEAD re-read) and return a head pointing AT `taken_seq`
        # with `next_offset = prev_head.next_offset + record_count`, so the next
        # attempt tries `taken_seq+1` at the correct running-sum base. Returns
        # None if the chunk is gone (a 404): an unguarded caller falls back to
        # a cached-_HEAD re-read, a guarded one to LIST recovery (the slot was
        # reaped, so the writer is below the log start). A guarded manifest
        # also re-anchors by LIST when the slot is below `_LOG_START`. This is
        # a forward-progress HINT only — the slot If-None-Match CAS is the
        # gaplessness oracle. We only advance
        # ONE slot at a time, so if the other writer is several slots ahead, the
        # next probe walks forward one more (each a single GET), or the
        # LIST_ESCALATE_AFTER fallback re-anchors on the true top.
        var ck = chunk_key(self._prefix, taken_seq)
        try:
            var c = self._store.get(ck)
            var rc = decode_chunk_record_count(c)
            # Reaped-slot guard rule 3 (opt-in): a chunk below `_LOG_START` may
            # be a refused win with a different record count; its count must not
            # seed the next offset. Re-anchor by LIST (log-start aware) instead.
            if self._reaped_slot_guard and probed_slot_is_below_log_start(
                taken_seq, self._read_log_start_seq_inner()
            ):
                return Optional(self._recover_head_by_list())
            return Optional(
                ManifestHead(
                    taken_seq, prev_head.next_offset + rc, String("")
                )
            )
        except e:
            if _is_not_found(String(e)):
                return Optional[ManifestHead](None)
            raise e^

    def _escalate_head_incremental(
        self, seed: ManifestHead
    ) raises -> ManifestHead:
        # O(gap) authoritative tail for the CONTENDED APPEND escalation only.
        # LIST the manifest prefix for the TRUE top seq (one LIST, no per-chunk
        # GET), then replay cumulative record_counts over ONLY the GAP
        # `[seed.chunk_seq+1 .. top]`, seeding `next_offset` from the caller's
        # current head. If `seed` is empty/behind log_start, fall back to the
        # full authoritative recovery (the cold/first-escalation case).
        #
        # WHY THIS IS SAFE (forward-progress hint, not the gaplessness oracle):
        # the slot `If-None-Match` create-CAS is what guarantees no-dup/no-gap.
        # This function only computes the NEXT candidate slot + its base offset to
        # try; if it is slightly stale (the other writer won more slots in the
        # gap window), the next attempt simply 412s and re-escalates. It never
        # renumbers a committed offset (the base is derived by replaying the
        # surviving chunks' record_counts, identical to the full recovery — just
        # seeded from a known-good lower bound instead of from log_start).
        var ls = self._read_log_start_inner()
        var top = self._list_chunks().chunk_seq
        if top < Int64(0):
            # Empty manifest — next append claims seq log_start_seq @ log_start_off.
            var s = ls.log_start_seq
            var o = ls.log_start_offset
            if s < Int64(0):
                s = Int64(0)
                o = Int64(0)
            return ManifestHead(s - Int64(1), o, String(""))
        # If the seed is a usable lower bound (at or above log_start, with a real
        # next_offset), replay only the gap above it; else fall back to the full
        # authoritative replay (correctness-equivalent, just costlier).
        var start_seq = seed.chunk_seq + Int64(1)
        var next_off = seed.next_offset
        if (
            seed.chunk_seq < ls.log_start_seq - Int64(1)
            or seed.next_offset < ls.log_start_offset
        ):
            # Seed is below the retention horizon (or unset) — full recovery.
            return self._recover_head_by_list()
        if start_seq > top:
            # Seed already AT/ABOVE the true top — the cached head was not stale
            # in the seq dimension; nothing to replay, return it as-is.
            return ManifestHead(seed.chunk_seq, seed.next_offset, String(""))
        var seq = start_seq
        var last_etag = String("")
        while seq <= top:
            var ck = chunk_key(self._prefix, seq)
            try:
                var c = self._store.get(ck)
                next_off += decode_chunk_record_count(c)
            except e2:
                if _is_not_found(String(e2)):
                    # A hole at/above log_start above the seed — a torn lineage in
                    # the gap. Fall back to the full recovery, which fail-louds
                    # (we must never silently truncate here).
                    return self._recover_head_by_list()
                raise e2^
            if seq == top:
                try:
                    var meta = self._store.head(ck)
                    last_etag = meta.etag
                except e3:
                    _ = e3  # advisory etag hint; tolerate a transient miss
            seq += Int64(1)
        return ManifestHead(top, next_off, last_etag^)

    def _try_advance_head(
        mut self,
        chunk_seq: Int64,
        next_offset: Int64,
        last_etag: String,
        expected_prev_seq: Int64,
        expected_head_etag: String,
    ) -> None:
        # MONOTONIC best-effort _HEAD advance (stale-head forward progress).
        # The _HEAD object is a CACHE (the bucket/chunks are the
        # source of truth), BUT it MUST NEVER move BACKWARDS. The prior
        # "write unconditionally / last-writer-wins" policy was WRONG under
        # SUSTAINED cross-process contention: an OLDER advance (carrying a
        # lower chunk_seq) could clobber _HEAD to a LOWER seq AFTER a newer
        # advance landed. Every contending writer then re-reads that stale-low
        # _HEAD, recomputes the SAME already-taken `candidate_seq =
        # head.chunk_seq+1`, gets a permanent 412, degrades to the retryable
        # code, the client retries, re-reads the same stale _HEAD — a LIVELOCK
        # with no forward progress (verified: ~700-900 attempts, all 412).
        #
        # FAST PATH (one S3 call): the winning append already read `_HEAD` at
        # `expected_prev_seq` with object etag `expected_head_etag`. Doing a
        # single `If-Match(expected_head_etag)` PUT of `chunk_seq` succeeds ONLY
        # if `_HEAD` is STILL exactly what we read (`expected_prev_seq`), so the
        # write to `chunk_seq = expected_prev_seq+1` is strictly FORWARD
        # (monotone) and cannot clobber a concurrent advance. On any conflict /
        # empty etag we fall to the read-recheck loop (the SLOW path).
        #
        # SLOW PATH (read-recheck loop): GET `_HEAD`, skip if our `chunk_seq <=
        # current`, else If-Match on the current etag (or If-None-Match create
        # when absent), bounded re-check on conflict. Each GET+PUT cycle is
        # confined to `_try_advance_head_once` (its own function frame) so the
        # GET's HTTP transients get a tracked drop point and never ASAP-defer
        # into the PUT — the drop-barrier discipline `_try_append_at` uses (see
        # its SAFETY block).
        #
        # Always best-effort (swallow errors — the bucket is truth; a lost CAS
        # is recoverable by LIST), but it can ONLY move `_HEAD` forward.
        try:
            # FAST PATH: one-call monotone If-Match advance.
            #
            # MONOTONICITY (the `_HEAD`-regression / torn-read guard):
            # `_try_advance_head_fast` DECODES the etag-pinned
            # `_HEAD` it is about to overwrite and refuses to advance unless
            # `chunk_seq` is STRICTLY FORWARD of the LIVE seq — so a fast advance
            # can NEVER regress `_HEAD` below the true tail, for EVERY caller
            # (incl. the OCC `try_append_at_seq` caller whose synthetic
            # `candidate_seq - 1` does not match the etag's true seq). Without
            # it, a 2nd / interrupted writer winning a lower-or-equal slot lands
            # `_HEAD` backward via the etag-only fast CAS, so a fresh
            # `read_head()`/`begin()` pinned a stale-low snapshot and missed
            # committed rows -> "cas_manifest: truncated i64" on the regressed
            # tail. A non-forward candidate is short-circuited inside the verb; a
            # conflict / absent `_HEAD` FALLS to the slow path, which re-reads +
            # applies its own `chunk_seq <= cur_seq` guard (also monotone).
            if expected_head_etag.byte_length() != 0 and expected_prev_seq >= Int64(0):
                if self._try_advance_head_fast(
                    chunk_seq, next_offset, last_etag, expected_head_etag
                ):
                    return
                # Fast path conflicted (someone else advanced / etag changed) —
                # fall through to the read-recheck slow path.
            var bounded = 0
            while bounded < 5:
                bounded += 1
                # Returns True when DONE (advanced, skipped-monotone, or a
                # transient error → give up); False when a 412 means "re-read
                # the current _HEAD and re-check monotonicity".
                if self._try_advance_head_once(
                    chunk_seq, next_offset, last_etag
                ):
                    return
            # Bounded retries exhausted — leave _HEAD as it is (forward-only
            # is preserved; the bucket is still truth, recoverable by LIST).
            return
        except e:
            _ = e  # advisory; ignore

    def _try_advance_head_fast(
        mut self,
        chunk_seq: Int64,
        next_offset: Int64,
        last_etag: String,
        expected_head_etag: String,
    ) raises -> Bool:
        # ONE-CALL monotone advance: If-Match on the etag the append read. Its
        # OWN function frame is the drop barrier (no GET here — pure PUT — so
        # there is no GET-then-PUT transient hazard). Returns True = advanced;
        # False = conflict (caller falls to the read-recheck slow path).
        #
        # MONOTONICITY: `expected_head_etag` was read by the
        # caller; the `If-Match` lands ONLY if `_HEAD` is byte-unchanged since
        # then. The CALLER's guard (`chunk_seq > expected_prev_seq` in
        # `_try_advance_head`) is correct ONLY when `expected_head_etag` actually
        # names `_HEAD` at `expected_prev_seq` — true for the hot `_append_inner`
        # caller (it reads the head + its etag together) but NOT for the OCC
        # `try_append_at_seq` caller (it reads the CURRENT `_HEAD` etag, which may
        # name a HIGHER seq than its synthetic `candidate_seq - 1`). To be safe
        # for EVERY caller, this verb DECODES the etag-pinned `_HEAD` it is about
        # to overwrite and refuses to advance unless `chunk_seq` is STRICTLY
        # FORWARD of that pinned seq — so a fast `If-Match` can NEVER regress
        # `_HEAD` below the live tail (the torn-read root cause). The decode
        # adds one cheap GET; the no-regression guarantee is the whole point.
        var hk = head_key(self._prefix)
        try:
            var cur_raw = self._store.get(hk)
            var cur = decode_head(cur_raw)
            # The etag we hold MUST still name THIS `_HEAD` value, else the
            # If-Match below 412s and we fall to the slow path; decoding it now
            # lets us apply the monotonicity guard against the LIVE seq.
            if chunk_seq <= cur.chunk_seq:
                # A non-forward advance — `_HEAD` is already at/ahead of us.
                # Treat as DONE (the tail is already at least where we'd write);
                # NEVER regress. Returning True ends the advance without a write.
                return True
        except e_read:
            _ = e_read  # `_HEAD` vanished / transient — let the slow path create.
            return False
        var h = ManifestHead(chunk_seq, next_offset, last_etag)
        var enc = encode_head(h)
        try:
            _ = self._store.conditional_put(
                hk, enc, WritePrecondition.if_match(expected_head_etag)
            )
            return True
        except e:
            _ = e  # conflict or transient — slow path re-checks monotonicity
            return False

    def _try_advance_head_once(
        mut self, chunk_seq: Int64, next_offset: Int64, last_etag: String
    ) raises -> Bool:
        # ONE monotone-advance attempt in its OWN function scope (the drop
        # barrier). Returns True = DONE (advanced / skipped-monotone / gave up
        # on a transient); False = a 412 conflict, caller re-reads + retries.
        var hk = head_key(self._prefix)
        # Read the current cache (+ etag) to decide monotonicity.
        var cur_seq = Int64(-1)
        var cur_etag = String("")
        var cur_present = False
        try:
            var raw = self._store.get(hk)
            var cur = decode_head(raw)
            var meta = self._store.head(hk)
            cur_seq = cur.chunk_seq
            cur_etag = meta.etag
            cur_present = True
        except e_read:
            if not _is_not_found(String(e_read)):
                return True  # transient read error; advisory — give up
            # _HEAD absent — cur_present stays False; we create via
            # If-None-Match below.
        # MONOTONICITY GUARD: never write _HEAD backwards.
        if cur_present and chunk_seq <= cur_seq:
            return True
        var h = ManifestHead(chunk_seq, next_offset, last_etag)
        var enc = encode_head(h)
        var precond = WritePrecondition.if_none_match_star()
        if cur_present:
            precond = WritePrecondition.if_match(cur_etag)
        try:
            _ = self._store.conditional_put(hk, enc, precond)
            return True  # forward advance landed
        except e_put:
            if _is_precondition(String(e_put)):
                # A concurrent advance (or create) beat us — caller re-reads +
                # re-checks monotonicity (bounded). We may now find a HIGHER
                # seq and correctly skip.
                return False
            return True  # transient write error; advisory — give up

    # ---- read-back ----

    def read_chunk(self, chunk_seq: Int64) raises -> List[UInt8]:
        # CAS-GATE: READ verb -> SHARED (read) lock. Concurrent readers proceed
        # in parallel; the exclusive write lock still blocks them while an
        # append/publish is in flight. Exception-safe unlock.
        _cas_gate_rdlock()
        try:
            var c = self._store.get(chunk_key(self._prefix, chunk_seq))
            var out = decode_chunk_body(c)
            _cas_gate_unlock()
            return out^
        except e:
            _cas_gate_unlock()
            raise e^

    def num_chunks(self) raises -> Int64:
        """The number of committed chunks (= highest chunk_seq + 1).

        ⛔ THIS DOES NOT SATISFY THE CONTRACT ITS TRAIT DECLARES, AND THAT IS A
        KNOWN, OPEN DEFECT. Read this before believing a number it returns.

        `read_head()` trusts the DURABLE `_HEAD` OBJECT on a COLD handle;
        `_read_head_inner`'s LIST-recovery escape fires only when `_HEAD` is
        ABSENT, never when it is present-but-stale-low. Flush-op reduction
        (see `_LocalHeadCache`) KNOWINGLY defers the durable `_HEAD` advance for up to
        `_HEAD_ADVANCE_DEFER_CADENCE` = 64 warm appends. So on any handle that is
        not the writer's own, THIS METHOD CAN UNDER-COUNT BY UP TO 63 CHUNKS.

        Callers that treat `num_chunks()` as authoritative are exposed: a split
        catalog that enumerates `0 .. num_chunks()-1` silently DROPS committed
        merged splits on an under-count.

        WHY IT IS STILL `read_head()`, stated so nobody re-lands the one-liner:
        the obvious fix — `read_head_fresh()`, which keeps the warm path 0-RPC
        and makes the cold path LIST — breaks a cold-read latency profile: a
        cold columnar range scan over 12 splits at a simulated 50 ms RTT goes
        from within its 400 ms ceiling to ~1.4 s (~28 RTT-rounds where the
        concurrency bound allows 8).

        The cost is real because callers invoke this INSIDE per-split fan-outs,
        so an authoritative LIST per call serializes ~20 extra round-trips. The
        correct fix is therefore NOT here: it is to read the authoritative tail
        ONCE per catalog operation and thread it down, per caller. That is a
        refactor with its own falsifiers. Do not "fix" this by flipping the
        reader — the cold-read latency profile is the falsifier that catches it.

        A caller that needs the TRUE tail today must say so explicitly:
        `read_head_authoritative()` (always LIST) or `read_head_fresh()` (warm
        cache, else LIST). `SearchMetastore.generation()` uses the latter; the
        other callers have not been audited.
        """
        var head = self.read_head()
        return head.chunk_seq + Int64(1)

    # ---- sidecar object I/O (manifests / data files written ALONGSIDE the
    #      manifest lineage, addressed by a full object key) ----
    #
    # The CAS-manifest lineage owns the `<prefix>/chunk-*` / `<prefix>/_HEAD`
    # namespace; a consumer that materializes adjacent objects (e.g. an Iceberg
    # adapter writing Avro manifest + manifest-list bytes under the table's data
    # prefix) reaches the SAME backend store through these typed passthroughs
    # instead of holding a raw store handle. The store stays encapsulated: the
    # key + bytes cross the boundary as owned values, never `_store` itself.

    def put_object(mut self, key: String, var bytes: List[UInt8]) raises -> None:
        """Unconditional PUT of `bytes` at the full object `key` (a sidecar
        object adjacent to this lineage's chunks, e.g. an Avro manifest). The
        key is an ABSOLUTE object key, NOT relative to `_prefix`."""
        _ = self._store.put(Path.parse(key), bytes^)

    def get_object(self, key: String) raises -> List[UInt8]:
        """Full-object fetch of a sidecar object at the full `key`."""
        return self._store.get(Path.parse(key))

    def discover_shard_ids(self, index_meta_prefix: String) raises -> List[String]:
        """Enumerate the DISTINCT sub-lineage shard_ids present under
        `<index_meta_prefix>/_lineage/` (adaptive-index-sharding read
        discovery). A backend-agnostic flat LIST through the
        encapsulated `_store` — the store NEVER crosses the boundary; only the
        owned `List[String]` of shard_ids returns. An index with NO sub-lineages
        (the k=1 / legacy single-lineage common case) returns an EMPTY list, and
        the caller replays the legacy lineage (shard_id="") for back-compat —
        byte-identical to the pre-sharding direct read. The LIST is the single
        bounded discovery round-trip the per-index discovery cache memoizes
        (invariant #1: ZERO extra LIST at steady state)."""
        return _discover_shard_ids[Self.Store](self._store, index_meta_prefix)

    def object_size(self, key: String) raises -> Int64:
        """HEAD the sidecar object at `key` -> its byte size (exact, from the
        store, so a manifest-list entry records the true on-disk length)."""
        var meta = self._store.head(Path.parse(key))
        return meta.size

    def rewrite_chunk_body(
        mut self, chunk_seq: Int64, new_body: List[UInt8]
    ) raises -> None:
        """Overwrite an EXISTING chunk's consumer body IN PLACE (same chunk_seq),
        PRESERVING its `record_count` (log compaction).

        This is the log-compaction swap verb: the cleaner rewrites a cleanable
        chunk's segment to hold only the latest-per-key survivors and re-points
        the chunk body at the rewritten segment, but the chunk's `record_count`
        MUST NOT change — the manifest is the offset allocator (live chunk seq
        `k` occupies `[base_k, base_k + record_count_k - 1]`, base = running sum
        of prior counts), so changing a chunk's record_count would silently
        RENUMBER every downstream chunk's offsets. Kafka compaction preserves
        surviving offsets + leaves GAPS; the compacted chunk stays SPARSE within
        its unchanged span.

        Fail-LOUD if (a) the chunk does not exist (compact a never-committed
        chunk = caller bug), or (b) `new_body`'s record_count differs from the
        existing chunk's (the offset-preservation invariant — refuse to
        renumber). The overwrite is last-writer-wins on the chunk key (the same
        idempotency contract retention's tombstone markers use; one serial
        background cleaner tick, no contending writer on a non-active chunk).
        The `_HEAD` cache is NOT touched — it only caches the tail/active chunk,
        which the cleaner never rewrites; downstream offsets are unchanged so the
        cache stays valid.

        The overwrite is CONDITIONAL (If-Match on the etag read before the
        body), so it never recreates a chunk the reaper deleted between the read
        and the write (chunk_reclaim_guard.mojo). That raises a `not_found`
        error; a concurrent rewrite raises the store's precondition error.
        Cost: one HEAD more than an unconditional overwrite (a cold path).
        """
        # WRITE verb (in-place chunk overwrite) -> EXCLUSIVE lock.
        _cas_gate_wrlock()
        try:
            var ck = chunk_key(self._prefix, chunk_seq)
            # The etag first, then the body: a rewrite landing between the two
            # leaves the etag stale, so the If-Match below refuses.
            var etag = self._store.head(ck).etag
            # Fail-loud existence check + record_count guard.
            var existing = self._store.get(ck)
            var old_rc = decode_chunk_record_count(existing)
            # Re-derive new_body's record_count from the canonical chunk-envelope
            # encoding: encode the new body, read its rc back.
            var new_encoded = encode_chunk(new_body, old_rc)
            var check_rc = decode_chunk_record_count(new_encoded)
            if check_rc != old_rc:
                # The `except` below releases the gate (once).
                raise Error(  # cov: unreachable encode_chunk(body, old_rc) always decodes back to old_rc
                    "CasManifestStore.rewrite_chunk_body: record_count guard"  # cov: unreachable see the line above
                    " — refusing to renumber chunk "
                    + String(chunk_seq)  # cov: unreachable see the line above
                )
            try:
                _ = self._store.conditional_put(
                    ck, new_encoded, WritePrecondition.if_match(etag)
                )
            except e_put:
                if _is_precondition(String(e_put)) and self._chunk_is_gone(ck):
                    raise rewrite_target_deleted_error(chunk_seq)
                raise e_put^
            _cas_gate_unlock()
        except e:
            _cas_gate_unlock()
            raise e^

    def _chunk_is_gone(self, ck: Path) -> Bool:
        """True iff a HEAD proves `ck` absent. Any other HEAD outcome (present,
        or an error that is not absence) is False: the caller then reports the
        original failure."""
        try:
            _ = self._store.head(ck)
            return False
        except e:
            return _is_not_found(String(e))

    # ---- lifecycle FSM ----

    def schedule_for_delete(mut self, chunk_seq: Int64) raises -> None:
        """Tombstone the chunk (the retention marker), PERSISTED to S3 as
        `<prefix>/tombstones/<seq>.tomb`. Idempotent; fail-loud if the chunk
        does not exist. Stamps the marker with the current wall clock
        (`_now_millis`) — for a deterministic schedule ts use
        `schedule_for_delete_at`. (Trait verb: clock-less signature)."""
        self.schedule_for_delete_at(chunk_seq, _now_millis())

    def schedule_for_delete_at(
        mut self, chunk_seq: Int64, schedule_ts_ms: Int64
    ) raises -> None:
        """Tombstone `chunk_seq` with an EXPLICIT schedule timestamp (ms).
        Writes (idempotently — last-writer-wins on the tiny marker key) the
        persisted tombstone `<prefix>/tombstones/<seq>.tomb` whose body is the
        schedule ts. Verifies the chunk exists first (fail-loud on a bad
        seq). The grace-aware reaper reads the ts to gate the actual delete.
        """
        # CAS-GATE: WRITE verb (tombstone PUT) -> EXCLUSIVE lock. Serializes the
        # existence-check GET + tombstone PUT. NOTE: `schedule_for_delete`
        # (above) is a LOCK-FREE delegator that calls this — it does NOT take
        # the gate itself, so there is no double-lock.
        _cas_gate_wrlock()
        try:
            # Fail-loud existence check (a tombstone for a never-committed
            # chunk is a caller bug).
            var _c = self._store.get(chunk_key(self._prefix, chunk_seq))
            _ = _c
            # Persist the marker (last-writer-wins keeps it idempotent — a
            # re-tombstone just refreshes the ts; the offline twin's `put`
            # overwrites, S3's PUT overwrites).
            var tomb = List[UInt8]()
            _put_i64_le(tomb, schedule_ts_ms)
            _ = self._store.put(
                tombstone_key(self._prefix, chunk_seq), tomb
            )
            _cas_gate_unlock()
        except e:
            _cas_gate_unlock()
            raise e^

    def schedule_moved_for_delete_at(
        mut self, chunk_seq: Int64, schedule_ts_ms: Int64
    ) raises -> None:
        """Retire `chunk_seq` with a MOVED marker
        `<prefix>/moved_tombstones/<seq>.tomb` (body: the schedule ts): another
        manifest now references the payload objects the chunk body names, so a
        reaper deletes the chunk key and never the payload. No other verb writes
        this key, so a later `schedule_for_delete_at` on the same chunk cannot
        undo it. Idempotent (a rewrite refreshes the ts); fail-loud if the chunk
        does not exist."""
        # CAS-GATE: WRITE verb -> EXCLUSIVE lock (existence GET + marker PUT).
        _cas_gate_wrlock()
        try:
            var _c = self._store.get(chunk_key(self._prefix, chunk_seq))
            _ = _c
            var tomb = List[UInt8]()
            _put_i64_le(tomb, schedule_ts_ms)
            _ = self._store.put(
                moved_tombstone_key(self._prefix, chunk_seq), tomb
            )
            _cas_gate_unlock()
        except e:
            _cas_gate_unlock()
            raise e^

    def _is_marked(self, chunk_seq: Int64) raises -> Bool:
        # Consult S3: a plain or a moved marker object exists iff the chunk is
        # ScheduledForDelete. (No process-local state — restart-safe.)
        if self._marker_exists(tombstone_key(self._prefix, chunk_seq)):
            return True
        return self._marker_exists(moved_tombstone_key(self._prefix, chunk_seq))

    def _marker_exists(self, key: Path) raises -> Bool:
        try:
            var _t = self._store.get(key)
            _ = _t
            return True
        except e:
            if _is_not_found(String(e)):
                return False
            raise e^

    def _list_marker_seqs(
        self, dir: String, moved: Bool
    ) raises -> List[Int64]:
        """The seqs under `<prefix>/<dir>/`, unsorted. Caller holds the lock."""
        var res = self._store.list_with_delimiter(
            Path.parse(self._prefix + "/" + dir + "/")
        )
        var out = List[Int64]()
        for i in range(len(res.objects)):
            ref loc = res.objects[i].location
            var seq = (
                _seq_from_moved_tombstone_key(loc) if moved
                else _seq_from_tombstone_key(loc)
            )
            if seq >= Int64(0):
                out.append(seq)
        return out^

    def tombstone_seqs(self) raises -> List[Int64]:
        """The chunk_seqs currently ScheduledForDelete — discovered by LISTing
        `<prefix>/tombstones/` AND `<prefix>/moved_tombstones/` (restart-safe;
        this is how a fresh broker re-discovers marks, ground-truth #1). A seq
        with both markers appears once. Returned ascending."""
        # READ verb -> SHARED (read) lock.
        _cas_gate_rdlock()
        try:
            var out = self._list_marker_seqs(String("tombstones"), False)
            var moved = self._list_marker_seqs(String("moved_tombstones"), True)
            _cas_gate_unlock()
            for i in range(len(moved)):
                out.append(moved[i])
            return _sorted_unique(out^)
        except e:
            _cas_gate_unlock()
            raise e^

    def moved_tombstone_seqs(self) raises -> List[Int64]:
        """The chunk_seqs carrying a MOVED marker (LIST of
        `<prefix>/moved_tombstones/`). Returned ascending."""
        # READ verb -> SHARED (read) lock.
        _cas_gate_rdlock()
        try:
            var out = self._list_marker_seqs(String("moved_tombstones"), True)
            _cas_gate_unlock()
            return _sorted_unique(out^)
        except e:
            _cas_gate_unlock()
            raise e^

    def moved_tombstone_ts(self, chunk_seq: Int64) raises -> Optional[Int64]:
        """The schedule ts of `chunk_seq`'s MOVED marker, or None when it has
        none. Any read error other than absence raises."""
        # READ verb -> SHARED (read) lock.
        _cas_gate_rdlock()
        try:
            var t = self._store.get(
                moved_tombstone_key(self._prefix, chunk_seq)
            )
            var ts = _get_i64_le(t, 0)
            _cas_gate_unlock()
            return Optional[Int64](ts)
        except e:
            _cas_gate_unlock()
            if _is_not_found(String(e)):
                return None
            raise e^

    def tombstone_schedule_ts(self, chunk_seq: Int64) raises -> Int64:
        """The schedule timestamp (ms) recorded for a tombstoned chunk. Raises
        `not_found` if the chunk is not tombstoned. The grace-aware reaper
        reads this to decide whether the grace window has elapsed."""
        # READ verb -> SHARED (read) lock.
        _cas_gate_rdlock()
        try:
            var t = self._store.get(tombstone_key(self._prefix, chunk_seq))
            var ts = _get_i64_le(t, 0)
            _cas_gate_unlock()
            return ts
        except e:
            _cas_gate_unlock()
            raise e^

    def reap(mut self, chunk_seq: Int64) raises -> None:
        """Remove the chunk object for a ScheduledForDelete chunk (the reaper
        verb). Fail-loud if the chunk is NOT tombstoned (tombstone before you
        reap). Either marker counts: a plain tombstone or a MOVED marker.
        Idempotent (deleting an absent object succeeds). Deletes both markers
        too (the chunk is gone; the markers are spent). It never touches the
        payload objects the chunk body names: deleting those is the caller's
        decision (the broker `ReapWorker` deletes them only without a MOVED
        marker).

        Grace gating lives ABOVE this verb (in the ReapWorker / the
        BrokerCore reap trigger, which reads `tombstone_schedule_ts` and only
        calls `reap` once `now - schedule_ts >= grace`).

        Refuses a chunk at or above `_LOG_START` (a live chunk carrying a
        stranded tombstone; chunk_reclaim_guard.mojo), and fails closed when
        `_LOG_START` cannot be read: nothing is deleted. Cost: one GET."""
        if not self._is_marked(chunk_seq):
            raise Error(
                "CasManifestStore.reap: chunk "
                + String(chunk_seq)
                + " is not ScheduledForDelete — tombstone before reaping"
            )
        # CAS-GATE: WRITE verb -> EXCLUSIVE lock for the two DELETEs. The
        # `_is_marked` pre-check above STAYS UNLOCKED — wrapping it would
        # create an rdlock-then-wrlock upgrade on one call stack (deadlock).
        _cas_gate_wrlock()
        try:
            var floor = self._read_log_start_seq_inner()
            if reap_is_refused(chunk_seq, floor):
                raise reap_refused_error(chunk_seq, floor)
            self._store.delete(chunk_key(self._prefix, chunk_seq))
            # Drop the spent markers (idempotent — deleting absent is fine).
            self._store.delete(tombstone_key(self._prefix, chunk_seq))
            self._store.delete(moved_tombstone_key(self._prefix, chunk_seq))
            _cas_gate_unlock()
        except e:
            _cas_gate_unlock()
            raise e^

    def purge_all(mut self) raises -> Int64:
        """WHOLE-LINEAGE reclamation: delete EVERY object this manifest owns —
        all `manifest/<seq>.chunk` chunks, all `tombstones/<seq>.tomb` and
        `moved_tombstones/<seq>.tomb` markers,
        all `_meta/dedup/<pid>/<seq>.seq` sentinels, the `_HEAD` cache, and the
        `_LOG_START` pointer. Returns the number of DELETE calls issued.

        This is the per-LINEAGE reaper verb (distinct from the per-CHUNK `reap`):
        it reclaims the manifest's ENTIRE key family when the whole lineage is no
        longer needed — the cross-epoch shuffle-retention use.
        The CALLER owns the policy decision that
        the lineage is reclaimable (e.g. the per-epoch shuffle reaper only purges
        an epoch's `_entries`/`_seal` manifests when EVERY consumer's checkpointed
        cursor has advanced strictly past that epoch). This verb itself purges
        UNCONDITIONALLY — it is a mechanism, not a policy.

        OUTSIDE the live-chunk guarantee `reap` and `rewrite_chunk_body` keep
        (chunk_reclaim_guard.mojo): this deletes chunks at or above
        `_LOG_START`, then `_LOG_START` itself (which then reads as zero). Use it
        only on a lineage nothing reads or appends to any more (the shuffle
        epoch reaper), never on a broker partition.

        Idempotent (S3 delete-of-absent succeeds), and SAFE to call on a fully-
        or partially-purged lineage. Enumerates each known leaf-prefix via
        `list_with_delimiter` so it is correct on a delimiter-listing backend
        (S3) as well as the flat offline stores, plus issues direct deletes of
        the singleton `_HEAD` / `_LOG_START` keys.

        Key-layout encapsulation: the manifest's internal key shapes
        (`manifest/`, `tombstones/`, `moved_tombstones/`, `_meta/dedup/`,
        `_HEAD`, `_LOG_START`) stay
        PRIVATE to this module — the reaper above this layer reclaims a manifest
        lineage by calling THIS verb, never by reconstructing the CAS-internal
        key names."""
        # WRITE verb (a sequence of DELETEs) -> EXCLUSIVE lock for the whole
        # purge so a concurrent reader/appender does not observe a half-purged
        # lineage. Exception-safe unlock (no `finally` in Mojo 1.0.0b1).
        _cas_gate_wrlock()
        try:
            var deletes = Int64(0)
            # manifest/<seq>.chunk
            var manifest_lk = Path.parse(self._prefix + "/manifest/")
            var manifest_res = self._store.list_with_delimiter(manifest_lk)
            for i in range(len(manifest_res.objects)):
                self._store.delete(
                    Path.parse(manifest_res.objects[i].location)
                )
                deletes += Int64(1)
            # tombstones/<seq>.tomb
            var tomb_lk = Path.parse(self._prefix + "/tombstones/")
            var tomb_res = self._store.list_with_delimiter(tomb_lk)
            for i in range(len(tomb_res.objects)):
                self._store.delete(Path.parse(tomb_res.objects[i].location))
                deletes += Int64(1)
            # moved_tombstones/<seq>.tomb
            var moved_lk = Path.parse(self._prefix + "/moved_tombstones/")
            var moved_res = self._store.list_with_delimiter(moved_lk)
            for i in range(len(moved_res.objects)):
                self._store.delete(Path.parse(moved_res.objects[i].location))
                deletes += Int64(1)
            # _meta/dedup/<pid>/<seq>.seq  (the idempotency sentinels)
            var dedup_lk = Path.parse(self._prefix + "/_meta/dedup/")
            var dedup_res = self._store.list_with_delimiter(dedup_lk)
            for i in range(len(dedup_res.objects)):
                self._store.delete(Path.parse(dedup_res.objects[i].location))
                deletes += Int64(1)
            # A FLAT full-prefix sweep catches any other object the flat offline
            # stores (LocalFs / in-memory) match by prefix — and harmlessly
            # re-deletes (idempotent) the already-removed nested keys on those
            # backends. On a delimiter-listing S3 backend this returns only the
            # direct children (none, after the leaf-prefix deletes above + the
            # singletons below), so it adds no incorrect reach.
            var flat_lk = Path.parse(self._prefix + "/")
            var flat_res = self._store.list_with_delimiter(flat_lk)
            for i in range(len(flat_res.objects)):
                self._store.delete(Path.parse(flat_res.objects[i].location))
                deletes += Int64(1)
            # Singletons (direct deletes; idempotent if already absent).
            self._store.delete(head_key(self._prefix))
            deletes += Int64(1)
            self._store.delete(log_start_key(self._prefix))
            deletes += Int64(1)
            _cas_gate_unlock()
            return deletes
        except e:
            _cas_gate_unlock()
            raise e^

    # ---- log-start pointer ----

    def read_log_start_seq(self) raises -> Int64:
        """The lowest live chunk seq from `_LOG_START`, in ONE GET (no HEAD:
        no etag). 0 when the object is absent (never truncated). Raises on any
        other read error, so a reclaimer that uses it as its floor fails
        closed."""
        # READ verb -> SHARED (read) lock.
        _cas_gate_rdlock()
        try:
            var seq = self._read_log_start_seq_inner()
            _cas_gate_unlock()
            return seq
        except e:
            _cas_gate_unlock()
            raise e^

    def _read_log_start_seq_inner(self) raises -> Int64:
        # UNLOCKED body of `read_log_start_seq` (the caller holds the gate).
        return self._read_log_start_body_inner().log_start_seq

    def _read_log_start_body_inner(self) raises -> LogStart:
        # UNLOCKED one-GET read of `_LOG_START` (no HEAD, so no etag); zero
        # when absent, raises on any other error. The caller holds the gate.
        try:
            var raw = self._store.get(log_start_key(self._prefix))
            return decode_log_start(raw, String(""))
        except e:
            if _is_not_found(String(e)):
                return LogStart.zero()
            raise e^

    def read_log_start(self) raises -> LogStart:
        """Read the persisted `<prefix>/_LOG_START` pointer. Returns
        `LogStart.zero()` (offset 0, seq 0, empty etag) if the partition has
        never been truncated (the object is absent). The empty etag signals
        the next advance must CREATE (If-None-Match), not CAS."""
        # READ verb -> SHARED lock, released exactly once on every path (a
        # second release wedges every later write-locked verb in the process).
        _cas_gate_rdlock()
        try:
            var ls = self._read_log_start_inner()
            _cas_gate_unlock()
            return ls^
        except e:
            _cas_gate_unlock()
            raise e^

    def advance_log_start(
        mut self,
        new_log_start_seq: Int64,
        new_log_start_offset: Int64,
        expected_etag: String,
    ) raises -> LogStart:
        """Advance the persisted log-start pointer to
        `(new_log_start_seq, new_log_start_offset)` via an `If-Match` CAS on
        the current etag (or `If-None-Match` create when `expected_etag` is
        empty — the first-ever advance). Returns the new `LogStart` with the
        post-write etag. Raises `precondition` (412) on a stale etag — the
        caller re-reads `read_log_start` and retries (atomic
        advance). Never moves the pointer BACKWARDS: a target whose seq or
        offset is below the current pointer is refused with a precondition
        (412) error, so a caller that retries on 412 re-reads and finds the
        pointer already past its target (chunk_reclaim_guard.mojo). The current
        pointer is read (one GET) before the If-Match write: if it is newer than
        `expected_etag`, the write itself is refused."""
        # WRITE verb (If-Match CAS on _LOG_START) -> EXCLUSIVE lock.
        _cas_gate_wrlock()
        try:
            if expected_etag.byte_length() != 0:
                var cur = self._read_log_start_body_inner()
                if advance_would_regress(
                    cur.log_start_seq,
                    cur.log_start_offset,
                    new_log_start_seq,
                    new_log_start_offset,
                ):
                    raise advance_regress_error(
                        cur.log_start_seq,
                        cur.log_start_offset,
                        new_log_start_seq,
                        new_log_start_offset,
                    )
            var body = encode_log_start(
                LogStart(new_log_start_offset, new_log_start_seq, String(""))
            )
            var lk = log_start_key(self._prefix)
            var precond = WritePrecondition.if_none_match_star()
            if expected_etag.byte_length() != 0:
                precond = WritePrecondition.if_match(expected_etag)
            var meta = self._store.conditional_put(lk, body, precond)
            # Copy (not ^-move) the etag — Mojo 1.0.0b1 rejects a single-field
            # move out of the middle of `meta`. Cold path (one PUT per pass).
            var ls = LogStart(
                new_log_start_offset, new_log_start_seq, String(meta.etag)
            )
            _cas_gate_unlock()
            return ls^
        except e:
            _cas_gate_unlock()
            raise e^

    # ---- _CATALOG sidecar (the durable table catalog) ----

    def read_catalog_sidecar(self) raises -> CatalogSidecar:
        """Read the persisted `<prefix>/_CATALOG` sidecar. Returns
        `CatalogSidecar.absent()` (present=False, empty blob/etag) when the
        object does not exist (a never-written catalog) — the next
        `cas_catalog_sidecar` then CREATEs it via If-None-Match. The blob is
        the OPAQUE consumer payload (the table store's serialized TableCatalog); the
        CAS substrate round-trips it verbatim. READ verb -> SHARED (read)
        lock, released exactly once on every path (no `finally` in 1.0.0b1)."""
        _cas_gate_rdlock()
        try:
            var ck = catalog_key(self._prefix)
            var raw = self._store.get(ck)
            var meta = self._store.head(ck)
            var sc = CatalogSidecar(True, raw^, String(meta.etag))
            _cas_gate_unlock()
            return sc^
        except e:
            _cas_gate_unlock()
            if _is_not_found(String(e)):
                return CatalogSidecar.absent()
            raise e^

    def cas_catalog_sidecar(
        self, blob: List[UInt8], expected_etag: String
    ) raises -> CatalogSidecar:
        """Write the `<prefix>/_CATALOG` sidecar to `blob` via an `If-Match` CAS
        on `expected_etag` (or `If-None-Match` CREATE when `expected_etag` is
        empty — the first-ever write). Returns the new `CatalogSidecar`
        (present=True, the new blob + post-write etag). Raises
        `precondition` (412) on a stale etag — the caller re-reads
        `read_catalog_sidecar` and retries (a concurrent catalog mutation on a
        shared prefix won; the catalog is small + DDL is rare, so the natural
        retry is cheap). WRITE verb -> EXCLUSIVE lock; exception-safe unlock.

        The blob is OPAQUE — the substrate never decodes it. This is the same
        single-mutable-sidecar CAS shape as `advance_log_start`."""
        _cas_gate_wrlock()
        try:
            var ck = catalog_key(self._prefix)
            var precond = WritePrecondition.if_none_match_star()
            if expected_etag.byte_length() != 0:
                precond = WritePrecondition.if_match(expected_etag)
            var meta = self._store.conditional_put(ck, blob.copy(), precond)
            var sc = CatalogSidecar(True, blob.copy(), String(meta.etag))
            _cas_gate_unlock()
            return sc^
        except e:
            _cas_gate_unlock()
            raise e^

    # ---- internal LIST helper (bucket-is-truth recovery) ----

    def _list_chunks(self) raises -> _ChunkListing:
        # LIST the manifest/ prefix; the highest lexical key is the tail.
        var lk = Path.parse(self._prefix + "/manifest/")
        var res = self._store.list_with_delimiter(lk)
        var top = Int64(-1)
        var count = Int64(0)
        for i in range(len(res.objects)):
            var loc = res.objects[i].location
            var seq = _seq_from_key(loc)
            if seq >= Int64(0):
                count += Int64(1)
                if seq > top:
                    top = seq
        return _ChunkListing(top, count)


@fieldwise_init
struct _ChunkListing(Copyable, Movable, Deinitable):
    var chunk_seq: Int64  # highest seq seen (-1 if none)
    var count: Int64


# =============================================================================
# read the broker's producer trailer off a manifest CONSUMER body.
# =============================================================================
#
# `_scan_tail_for_batch` (the exact phantom-detect) must match a chunk's
# `(producer_id, first_seq)` identity. That identity lives in the broker's
# `ManifestBody` producer trailer, which is the OPAQUE consumer payload of the
# manifest chunk — `komira_objectstore` MUST NOT import `komira_broker`
# (that would invert the package DAG). So we read the trailer directly off the
# body bytes using the STABLE wire layout documented in
# `komira_broker.manifest_body`:
#
#   [ record_count: i64 ][ crc32: u32 ][ key_len: i64 ][ key bytes... ]
#   [ segment_bytes: i64 ][ creation_ts_ms: i64 ]          ← retention trailer
#   [ producer_id: i64 ][ producer_epoch: i64 ]            ← producer trailer
#   [ first_seq: i64 ][ last_seq: i64 ]                    ← producer trailer (cont.)
#
# A body WITHOUT the producer trailer (a non-idempotent / legacy chunk) has
# no producer identity → no match (returns False). This coupling is the price
# of the DAG firewall; it is exercised by the offline primitive test + the
# broker's idempotent-producer round-trip test so a wire-layout drift fails
# loudly.


@always_inline
def _body_matches_producer_batch(
    consumer_body: List[UInt8], producer_id: Int64, first_seq: Int64
) -> Bool:
    # producer_id is non-idempotent sentinel (-1) → never a sentinel match.
    if producer_id < Int64(0):
        return False
    try:
        # key_len is at offset 12 (after record_count i64 + crc32 u32).
        var key_len = Int(_get_i64_le(consumer_body, 12))
        var trailer_at = 20 + key_len  # past key bytes
        var producer_at = trailer_at + 16  # past the retention trailer
        # The producer trailer must be fully present (32 bytes:
        # producer_id, producer_epoch, first_seq, last_seq).
        if producer_at + 32 > len(consumer_body):
            return False
        var body_pid = _get_i64_le(consumer_body, producer_at)
        var body_first = _get_i64_le(consumer_body, producer_at + 16)
        return body_pid == producer_id and body_first == first_seq
    except e:
        _ = e
        return False


def _seq_from_key(key: String) -> Int64:
    # Extract the <chunk_seq:020d> from "..../manifest/<020d>.chunk".
    var marker = String("/manifest/")
    var idx = key.rfind(marker)
    if idx < 0:
        return Int64(-1)
    var start = idx + marker.byte_length()
    var bs = key.as_bytes()
    # Read 20 digits.
    var v = Int64(0)
    var i = start
    var n = len(bs)
    var any = False
    var zero = UInt8(ord("0"))
    var nine = UInt8(ord("9"))
    while i < n and bs[i] >= zero and bs[i] <= nine:
        v = v * Int64(10) + Int64(Int(bs[i]) - Int(zero))
        i += 1
        any = True
    if not any:
        return Int64(-1)
    return v


# ---- error-class probes (the trait raises Error; we classify by message) ----


@always_inline
def _is_not_found(msg: String) -> Bool:
    """True iff a raised store Error PROVES the object is absent.

    ⛔ `status=404`, NOT A BARE `404` — AND THE `=` IS THE LOAD-BEARING
    CHARACTER, NOT THE DIGITS. Every production conformer builds its message
    AROUND THE OBJECT KEY (`komira_aws_s3.s3._mk_error` and
    `gcs_grpc_errors.map_grpc_error_to_store_error` both emit
    `StoreError[<KIND>] <method> <scheme>://<bucket>/<key> status=<http> ...`),
    so a bare `404` needle searches the KEY. A `PERMISSION_DENIED` or a `5xx`
    about a colliding key then answered TRUE and **the credential failure became
    "the object is absent"** — a WRONG answer, not a missing one, produced
    silently because as far as this code was concerned nothing went wrong.

    ★ AND HERE THE COLLISION IS ARITHMETIC, NOT A LOTTERY. A manifest chunk key
    is `<prefix>/manifest/<chunk_seq:020d>.chunk`, so chunk sequence 404 IS
    `.../manifest/00000000000000000404.chunk`, and so are 1404, 4040, 40400, …
    — a fixed, dense, entirely predictable set every partition eventually
    reaches and then keeps colliding on forever. (`komira_telemetry_read`
    narrowed the identical predicate because 16 random hex characters contain
    `404` "one in a few dozen runs".) The `<prefix>` is caller-supplied on top of
    that, so a topic carrying `404` collides on `_HEAD`, `_LOG_START`,
    `_CATALOG` and every tombstone as well.

    THE COST AT THIS FUNCTION'S OWN CALL SITES: `read_log_start` answers
    `LogStart.zero()` ("never truncated"), `read_catalog_sidecar` answers
    `CatalogSidecar.absent()` ("no catalog"), `_is_marked` answers "not
    tombstoned", and the recovery scan treats a live chunk as missing. The next
    writer then CREATEs with `If-None-Match` over state that exists.

    ⚠ THIS IS NOT NEW POLICY — IT IS THE THIRD COPY BEING BROUGHT INTO LINE.
    `komira_telemetry_read.scan_plan._is_not_found` and
    `src/cmd/cp_telemetry_validator/cp_telem_lib._store_error_says_not_found`
    already carry exactly this needle set, and the latter's docstring names THIS
    FUNCTION as one of the two in-tree copies that still matched a bare `404`.
    Every needle below is one a key CANNOT contain: the key alphabet admits no
    `[`, `]` or `=`, and the canonical taxonomy token is uppercase.

      `StoreError[NOT_FOUND]`  GCS gRPC + S3 + Azure + Firestore, canonical
      `status=404`             the same message's HTTP projection
      `not_found`              the in-memory / LocalFs / delimiter conformers,
                               which all spell it `not_found (404)`
      `NotFound` / `NoSuchKey` the S3-family / XML conformers

    ⛔ THE CHANGE IS MONOTONE: the matched set is a strict SUBSET of what the old
    body matched, so this can only ever RAISE where it used to SWALLOW. No call
    site can newly swallow a real failure. Falsifier:
    `tests/test_cas_manifest_absence_is_anchored.mojo`.

    ⚠ `_is_precondition` BELOW STILL CARRIES THE SAME DEFECT WITH `412`, AND IS
    DELIBERATELY NOT CHANGED HERE. Chunk sequence 412 spells `412` in its key by
    the identical arithmetic, so a 403 on it reads as a lost CAS race — but that
    arm drives the append RETRY LOOP, i.e. a liveness path, and narrowing it
    needs its own falsifier per call site rather than a ride-along on this one.
    It is stated here so the omission is a recorded decision and not the silence
    that produced this defect."""
    return (
        msg.find("StoreError[NOT_FOUND]") >= 0
        or msg.find("status=404") >= 0
        or msg.find("not_found") >= 0
        or msg.find("NotFound") >= 0
        or msg.find("NoSuchKey") >= 0
    )


@always_inline
def _is_precondition(msg: String) -> Bool:
    return (
        msg.find("precondition") >= 0
        or msg.find("Precondition") >= 0
        or msg.find("412") >= 0
        or msg.find("PreconditionFailed") >= 0
    )


@always_inline
def is_not_found(msg: String) -> Bool:
    """True iff a raised store Error proves the object is absent. The public
    spelling of `_is_not_found` for packages built on this one
    (`komira_search_catalog`'s replay and reapers): the same anchored needles,
    one definition. A message that merely contains `404`, for example in the
    object key, is not absence."""
    return _is_not_found(msg)


@always_inline
def is_precondition(msg: String) -> Bool:
    """True iff `msg` is a lost conditional write (HTTP 412 / precondition
    failed). The public spelling of `_is_precondition` for packages built on
    this one (`komira_shuffle`'s partition claim): same substring convention,
    one definition."""
    return _is_precondition(msg)


@always_inline
def is_retryable_contention(msg: String) -> Bool:
    """True iff `msg` is the `CasManifestStore.append` retry-budget-exhausted
    Error (raised at `_append_inner` after `max_retries` 412s under genuine
    multi-writer contention). This is a RETRYABLE failure — the caller (e.g.
    the Kafka produce handler) must CATCH it and degrade gracefully (map it to
    a retriable per-partition response code), NEVER let it propagate out of the
    serve loop and exit the broker process.

    Classified by the `(retryable)` marker the `append` raise embeds (the same
    message-substring convention `_is_not_found` / `_is_precondition` use — the
    `MetadataStore` trait raises `Error`, not a typed variant, in Mojo 1.0.0b1).
    The `exhausted` token is required too so an unrelated message that merely
    contains `(retryable)` is not mis-classified."""
    return msg.find("(retryable)") >= 0 and msg.find("exhausted") >= 0


# =============================================================================
# AsyncManifestAppendOp[Storage] — the POLL-SHAPED create-CAS at a slot.
# =============================================================================
# The parkable counterpart of
# `CasManifestStore.try_append_at_seq`: ONE `If-None-Match` create-CAS at the
# EXACT slot `candidate_seq`, driven step-wise on a CALLER-SUPPLIED reactor so
# the serve thread parks across the object-store write RTT instead of blocking
# on it. Mirrors `try_append_at_seq`'s contract (Some(AppendResult) on WIN, None
# on a 412), as a 3-phase start/poll/take state machine.
#
# WHY A PARAMETRIC STRUCT (not methods on CasManifestStore): the poll-shaped
# verbs need `Storage: ConditionalWriteStore & AsyncCasStore` (the `cas_put_*`
# verbs), but `CasManifestStore[Store: ConditionalWriteStore]` carries the BASE
# bound. Mojo 1.0.0b1 expresses a wider trait requirement on a parametric STRUCT
# (the broker's `AsyncReassignOp[Storage: ... & AsyncCasStore]` shape), NOT via a
# method-level conditional bound on a weaker-bounded struct (there is no
# `requires`/`where` method-clause in 1.0.0b1). So this op carries the wider
# bound and borrows a `CasManifestStore[Storage]` by `mut` ref per call.
#
# ENCAPSULATION (the heap-reuse + encapsulation contract): the op holds NO store handle of
# its own — it BORROWS the live `CasManifestStore[Storage]` by `mut` ref per
# start/poll/take (never stored), and reaches the AsyncCasStore verbs through
# `wal.store_mut()` (a concrete-origin `ref [wal._store]` accessor). All key
# arithmetic + the `_HEAD` advance stay INSIDE cas_manifest (the op calls
# `wal.async_append_build_chunk` / `wal.apply_async_append_win`). The IN-FLIGHT
# create-CAS op (the dialed stream + the transport pool's heap buffers) lives
# inside the `wal._store` conformer's OWN concrete-origin handle across the park
# (the AsyncCasStore surface is start/poll/take of TYPED VALUES only — no
# transport buffer crosses the trait boundary). The op carries ONLY POD finalize
# inputs (slot / base / record_count) on plain value fields — NO byte-slab, NO
# wildcard origin, NO unsafe_from_address, NO pointer. The reactor is a per-call
# `mut` borrow. AT MOST ONE create-CAS in flight per op (single `_inflight`).

# The site name the op's refusals carry (no digits: manifest_slot_guard.mojo).
comptime _AMA_SITE: String = "async_append"

comptime _AMA_IDLE: UInt8 = 0
comptime _AMA_INFLIGHT: UInt8 = 1  # the create-CAS is in flight
comptime _AMA_DONE: UInt8 = 2
# Guarded manifests only (manifest_slot_guard.mojo): after the create WINS, the
# op reads `_LOG_START` as its own parkable phase before anything is applied.
comptime _AMA_CHECKING: UInt8 = 3  # the `_LOG_START` read is in flight
comptime _AMA_CHECKED: UInt8 = 4  # won and live: `take` applies the win
comptime _AMA_LOST: UInt8 = 5  # the create's take raised a 412
comptime _AMA_REFUSED: UInt8 = 6  # slot_reaped / log_start_unread


struct AsyncManifestAppendOp[
    Storage: ConditionalWriteStore & AsyncCasStore
](Movable, Deinitable):
    """A poll-shaped `If-None-Match` create-CAS at an exact manifest slot, driven
    one non-blocking step at a time on a caller-supplied reactor.
    Carries the POD slot bookkeeping across the park; borrows the live
    `CasManifestStore[Storage]` per call (never stored). See the header."""

    var _state: UInt8
    var _candidate: Int64
    var _base: Int64
    var _rc: Int64
    # Guarded manifests: the won chunk etag, the `_LOG_START` seq the check
    # read after the win, and the refusal text (slot_reaped / log_start_unread).
    var _won_etag: String
    var _log_start_seq: Int64
    var _refusal: String

    def __init__(out self):
        self._state = _AMA_IDLE
        self._candidate = Int64(0)
        self._base = Int64(0)
        self._rc = Int64(0)
        self._won_etag = String("")
        self._log_start_seq = Int64(-1)
        self._refusal = String("")

    @staticmethod
    def resume_inflight(
        candidate: Int64, base: Int64, record_count: Int64
    ) -> AsyncManifestAppendOp[Self.Storage]:
        """Reconstruct an in-flight op from its carried POD mirror.
        The caller (a parkable-commit driver) mirrors the POD slot
        bookkeeping on its own across-park state; the actual in-flight transport
        op persists inside the WAL's conformer, so this faithfully RESUMES it.
        `poll`/`take` then advance the same in-flight conformer op.

        It resumes the CREATE phase only. On a guarded manifest the op's
        `_LOG_START` check phase is not mirrored, so a guarded caller keeps the
        op itself across parks (the broker's appender does)."""
        var op = AsyncManifestAppendOp[Self.Storage]()
        op._state = _AMA_INFLIGHT
        op._candidate = candidate
        op._base = base
        op._rc = record_count
        return op^

    def start[
        S: WakerSink & Movable & Deinitable,
    ](
        mut self,
        mut wal: CasManifestStore[Self.Storage],
        candidate_seq: Int64,
        base_offset: Int64,
        body: List[UInt8],
        record_count: Int64,
        mut reactor: Reactor[S],
    ) raises -> CasOpProgress:
        """Kick off the poll-shaped create-CAS at `candidate_seq`. Returns READY
        (immediate completion — call `take`), PENDING(op_id) (park the frame on
        `op_id` + re-enter `poll`), or ERR. Confines the chunk key + encoding to
        cas_manifest (via `wal.async_append_build_chunk`); the encoded chunk is
        moved into the conformer's `cas_put_start` (empty etag => If-None-Match
        create) — its in-flight transport buffer lives inside `wal._store`."""
        self._candidate = candidate_seq
        self._base = base_offset
        self._rc = record_count
        self._won_etag = String("")
        self._log_start_seq = Int64(-1)
        self._refusal = String("")
        var built = wal.async_append_build_chunk(
            candidate_seq, body, record_count
        )
        var ck = built[0].copy()
        var encoded = built[1].copy()
        _ = built^
        self._state = _AMA_INFLIGHT
        var prog = wal.store_mut().cas_put_start[S](
            ck, encoded^, String(""), reactor
        )
        return self._after_put[S](wal, prog^, reactor)

    def poll[
        S: WakerSink & Movable & Deinitable,
    ](
        mut self, mut wal: CasManifestStore[Self.Storage], mut reactor: Reactor[S]
    ) raises -> CasOpProgress:
        """Advance the in-flight create-CAS one non-blocking step (called when
        its op_id completed). READY / PENDING(op_id) / ERR."""
        if self._state == _AMA_INFLIGHT:
            var prog = wal.store_mut().cas_put_poll[S](reactor)
            return self._after_put[S](wal, prog^, reactor)
        if self._state == _AMA_CHECKING:
            var rp: CasOpProgress
            try:
                rp = wal.store_mut().read_poll[S](reactor)
            except e:
                return self._refuse(
                    wal, log_start_unread_error(_AMA_SITE, String(e))
                )
            return self._after_check(wal, rp^)
        return CasOpProgress.error(
            String("AsyncManifestAppendOp.poll: no create-CAS in flight")
        )

    def _after_put[
        S: WakerSink & Movable & Deinitable,
    ](
        mut self,
        mut wal: CasManifestStore[Self.Storage],
        var prog: CasOpProgress,
        mut reactor: Reactor[S],
    ) raises -> CasOpProgress:
        """The create-CAS advanced. Unguarded, or not READY yet: return it as
        is (`take` finalizes, exactly as before). Guarded and READY: take the
        create now and, on a WIN, start the `_LOG_START` read as the next
        parkable phase (reaped-slot guard rule 1), BEFORE any `_HEAD` or cache
        update. A 412 from the take parks nothing: `take` returns None."""
        if not prog.is_ready() or not wal.reaped_slot_guard_enabled():
            return prog^
        var meta: ObjectMeta
        try:
            meta = wal.store_mut().cas_put_take()
        except e:
            if not _is_precondition(String(e)):
                raise e^
            self._state = _AMA_LOST
            return CasOpProgress.ready()
        self._won_etag = meta.etag
        self._state = _AMA_CHECKING
        var rp: CasOpProgress
        try:
            rp = wal.store_mut().read_start[S](
                log_start_key(wal.prefix()), reactor
            )
        except e:
            return self._refuse(wal, log_start_unread_error(_AMA_SITE, String(e)))
        return self._after_check(wal, rp^)

    def _after_check(
        mut self, mut wal: CasManifestStore[Self.Storage], var rp: CasOpProgress
    ) raises -> CasOpProgress:
        """The `_LOG_START` read advanced. PENDING: park. ERR or an undecodable
        body: FAIL CLOSED (rule 2). A win below the log start: `slot_reaped`
        (rule 1). Otherwise READY, and `take` applies the win."""
        if rp.is_pending():
            return rp^
        if rp.is_error():
            return self._refuse(
                wal, log_start_unread_error(_AMA_SITE, rp.err_text())
            )
        var log_start_seq: Int64
        try:
            var r = wal.store_mut().read_take()
            if r.absent:
                log_start_seq = Int64(0)  # never truncated
            else:
                log_start_seq = decode_log_start(r.body, String("")).log_start_seq
        except e:
            return self._refuse(wal, log_start_unread_error(_AMA_SITE, String(e)))
        if won_slot_is_reaped(self._candidate, log_start_seq):
            return self._refuse(wal, slot_reaped_error(_AMA_SITE))
        self._log_start_seq = log_start_seq
        self._state = _AMA_CHECKED
        return CasOpProgress.ready()

    def _refuse(
        mut self, mut wal: CasManifestStore[Self.Storage], err: Error
    ) -> CasOpProgress:
        """End the op without acknowledging: invalidate the head cache, keep
        the refusal for `take`, and surface it as ERR (the live error channel
        the caller classifies, like a 412). `_HEAD` is never touched."""
        wal._head_cache = _LocalHeadCache.cold()
        self._refusal = String(err)
        self._state = _AMA_REFUSED
        return CasOpProgress.error(self._refusal)

    def take(
        mut self, mut wal: CasManifestStore[Self.Storage]
    ) raises -> Optional[AppendResult]:
        """Consume the completed create-CAS (caller checks READY first). Returns
        `Some(AppendResult)` on WIN (the slot was free + we took it) or `None` on
        a 412 (someone else owns it — re-read authoritative head + re-OCC before
        re-driving). On a WIN it applies the same best-effort monotone `_HEAD`
        advance + cache-invalidate the sync `try_append_at_seq` does (via
        `wal.apply_async_append_win`).

        On a guarded manifest (manifest_slot_guard.mojo) the create's take and
        the post-win `_LOG_START` read already ran in `start`/`poll` (the read
        is its own parked phase), so `take` only applies a checked win, returns
        None for a 412, or raises the refusal (`slot_reaped` /
        `log_start_unread`) that `poll` already surfaced as ERR.

        LOW-1 / ABI NOTE — the LIVE lost-slot 412 channel is the ERR `*_start` /
        `*_poll` return, classified by the caller's `_is_lost_slot_412`, NOT this
        `take`->None path. Both shipping `AsyncCasStore` conformers surface a 412
        as a `CasOpProgress.error(...)` from `cas_put_start` (immediate-completion
        fast path) / `cas_put_poll` (final-tick), so a READY never reaches this
        `take` for a lost slot. The `take`->None mapping below (classify a
        `cas_put_take` 412/precondition raise via `_is_precondition` into `None`,
        exactly as the sync `_try_append_at` maps a 412 to `None`) is kept as
        defense-in-depth for a hypothetical conformer that defers the 412 to
        `cas_put_take` — correct if ever taken, but not exercised today."""
        if self._state == _AMA_CHECKED:
            # Guarded, won, and the post-win `_LOG_START` check passed.
            self._state = _AMA_DONE
            var won_etag = self._won_etag
            wal.apply_async_append_win(
                self._candidate,
                self._base,
                self._rc,
                won_etag.copy(),
                self._log_start_seq,
            )
            return Optional[AppendResult](
                AppendResult(
                    self._candidate,
                    self._base,
                    self._base + self._rc - Int64(1),
                    won_etag^,
                    1,
                )
            )
        if self._state == _AMA_LOST:
            self._state = _AMA_DONE
            return Optional[AppendResult](None)
        if self._state == _AMA_REFUSED:
            self._state = _AMA_DONE
            raise Error(self._refusal)
        if self._state != _AMA_INFLIGHT:
            raise Error("AsyncManifestAppendOp.take: no create-CAS in flight")
        if wal.reaped_slot_guard_enabled():
            # A guarded op becomes takeable only through its check phase.
            raise Error(
                "AsyncManifestAppendOp.take: the create and its _LOG_START"
                " check have not completed"
            )
        self._state = _AMA_DONE
        var candidate = self._candidate
        var base = self._base
        var rc = self._rc
        var meta: ObjectMeta
        try:
            meta = wal.store_mut().cas_put_take()
        except e:
            if not _is_precondition(String(e)):
                raise e^
            # 412 — another writer won this slot. Signal the loser to the caller.
            return Optional[AppendResult](None)
        # WON — finalize identically to the sync win path.
        var meta_etag = meta.etag
        var last = base + rc - Int64(1)
        wal.apply_async_append_win(candidate, base, rc, meta_etag.copy())
        return Optional[AppendResult](
            AppendResult(candidate, base, last, meta_etag^, 1)
        )
