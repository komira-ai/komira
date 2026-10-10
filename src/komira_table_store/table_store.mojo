# =============================================================================
# komira_table_store/table_store.mojo
#   TableStore[Store] / Txn / CommitResult — the single-table key->row MVCC
#   store over a CAS-manifest WAL (the table-store correctness slice).
# =============================================================================
#
# The minimal correctness proof of this storage core: commit = ONE create-CAS
# append to `CasManifestStore`, and
# snapshot-isolation MVCC over that log is correct under real concurrency.
# Pure Mojo API; generic over `[Store: ConditionalWriteStore]` so the IDENTICAL
# code runs on the in-memory / shared-in-memory (real threads) / local-fs
# conformers today and S3/GCS later UNCHANGED.
#
# -----------------------------------------------------------------------------
# THE LOAD-BEARING CORRECTNESS SUBTLETY (get this exactly right)
# -----------------------------------------------------------------------------
# The OCC window's upper bound and the create-CAS target slot are COUPLED.
#   * `begin()` MAY pin its snapshot from the cached `_HEAD` (`read_head`) — a
#     lagging snapshot is fine for SI (a reader may always pin an OLDER view).
#   * `commit()`'s OCC check AND `open()`/`recover` MUST read the AUTHORITATIVE
#     head (`read_head_authoritative` / LIST recovery), NEVER the cached
#     `_HEAD` (which can lag). The OCC window is `(snapshot, auth_head]` and
#     the commit create-CAS lands at EXACTLY `auth_head + 1` (via
#     `try_append_at_seq`). Winning that slot proves no chunk committed above
#     the OCC-validated head; a 412 forces re-read-authoritative + re-OCC.
# Any path that lets the append claim a slot >1 past the OCC-validated head, or
# that runs OCC against the cached `_HEAD`, is a SILENT isolation hole (not a
# crash). That is why `commit` uses `try_append_at_seq(auth_head+1, ...)` and
# NOT `CasManifestStore.append` (whose cached-head escalation can win a slot
# more than one past the validated head).
#
# -----------------------------------------------------------------------------
# Encapsulation / stale-reuse discipline (the repository pointer rules)
# -----------------------------------------------------------------------------
#   * ZERO UnsafePointer in any signature. The store flows as a typed value /
#     `ref [origin] T`; the WAL is owned by value (`CasManifestStore[Store]`).
#   * `Txn` has NO store-pointer field — the store is passed `mut`/`ref` per
#     method (avoids a borrowed pointer field nulled between uses, which the
#     pointer rules ban).
#   * Row versions / write-sets are plain byte `List`s with inline version
#     stamps, never heap-owning `Slab` element fields.
#   * ZERO wildcard origins / `unsafe_from_address` / `take_pointee`.
#
# -----------------------------------------------------------------------------
# Deferred hardening
# -----------------------------------------------------------------------------
# TODO: LocalFs fsync_dir; a typed result-code for torn-create +
# fail-loud on PERSISTENT truncation (today the OCC loop retries torn-create
# reads under a bounded MAX_COMMIT_ATTEMPTS and degrades to a RETRYABLE token,
# which is correct but not fail-loud after the bound); the extra deterministic
# tests (delete-then-reinsert, OCC-on-tombstone, abort-no-head-bump,
# recovery-fail-loud); and a `snapshot >= log_start` compaction guard. NOT
# gating this slice.
# =============================================================================

from komira_objectstore.cas_manifest import (
    AppendResult,
    AsyncManifestAppendOp,
    CasManifestStore,
    CatalogSidecar,
    LogStart,
    ManifestHead,
    is_lease_fenced,
)
from komira_objectstore.store import (
    AsyncCasStore,
    CasOpProgress,
    ConditionalWriteStore,
)

from komira_async.ops.waker_sink import WakerSink
from komira_async.reactor.reactor import Reactor

from std.memory import OwnedPointer

from komira_collections.slab import Slab

from komira_table_store.key_index import KeyIndex, KeyValue, VisibleVersion
from komira_table_store.table_store_codec import (
    CommitChunk,
    TS_OP_PUT,
    TS_OP_TOMBSTONE,
    TS_STAMP_LSN_UNSET,
    WriteOp,
    bytes_eq,
    decode_commit_chunk,
    decode_commit_chunk_keys,
    encode_commit_chunk,
)


@always_inline
def _fold_lsn_for_chunk(seq: Int64, chunk: CommitChunk) -> Int64:
    """The commit_lsn a decoded chunk's rows fold AT (Option-A S-b). For a
    single-WAL chunk (`stamp_lsn == TS_STAMP_LSN_UNSET` = -1, EVERY heap + k=1
    index chunk) the fold uses the WAL `seq` exactly as before — byte-identical.
    For a SHARDED secondary-index chunk that carries an EXPLICIT `stamp_lsn >= 0`
    (the heap DML-LSN `L`), the fold uses `L`, NOT this shard WAL's slot — the
    invariant-#3 per-lineage single-commit-LSN re-scope (the D1-b generalization).

    MONOTONICITY (the load-bearing invariant the chains rely on): within ONE
    shard's WAL the chunks are appended in `seq` order and each carries the `L`
    its heap-first DML won; a writer's DMLs are sequential so consecutive
    `stamp_lsn` values ascend in lockstep with `seq`. So replaying a shard WAL
    ascending in `seq` still appends versions ascending in `commit_lsn` — the
    `KeyChain` append-only ascending invariant holds (no sort needed)."""
    if chunk.stamp_lsn >= Int64(0):
        return chunk.stamp_lsn
    return seq


# =============================================================================
# OCC abort signal taxonomy — the first-committer-wins loser.
# =============================================================================
#
# The slice raises an OCC-conflict-tagged `Error` (Mojo 1.0.0b1 traits have no
# typed result enum; the store's own taxonomy is "discriminable by message
# prefix" — `precondition (412)` etc., classified by `_is_precondition`). We
# mirror that: `commit` raises an Error whose message carries the stable token
# `OCC_CONFLICT 40001`, and `is_occ_conflict(msg)` classifies it. The eventual
# SQL face maps it to SQLSTATE 40001 (serialization_failure).
# -----------------------------------------------------------------------------

comptime OCC_CONFLICT_TOKEN: String = "OCC_CONFLICT 40001"

# A RETRYABLE contention signal (distinct from OCC abort): the commit loop
# exhausted its bounded create-CAS attempts under genuine multi-writer
# contention, OR the underlying CAS-manifest append raised its own retry-budget-
# exhausted error. NEITHER is a correctness failure — the caller should re-drive
# the txn (re-begin at a fresh snapshot + retry), exactly as it does on an OCC
# 40001. The token is discriminable by message substring (the store's own
# convention; the CAS-manifest append embeds "(retryable)" too).
comptime COMMIT_RETRYABLE_TOKEN: String = "TS_COMMIT_RETRYABLE"

# A TERMINAL unique-constraint violation (SQLSTATE 23505 — unique_violation).
# Distinct from BOTH retry classes above: a 23505 is NEVER retried (the
# competing distinct-pk value was OBSERVED live under the unique prefix, so the
# constraint is genuinely violated). The SI-7 UNIQUE enforcement
# protocol raises an Error carrying this token from three sites: the buffer-time
# fast-fail prefix scan, the intra-statement pre-check, and the executor-side
# post-conflict recheck (which converts a guard-key 40001 into a terminal 23505
# the moment a competing committed value is seen at the fresh snapshot S'). The
# discriminator below mirrors `is_occ_conflict` so callers classify the abort
# taxonomy by stable token, never by a raw substring guess. The eventual SQL
# face maps it to SQLSTATE 23505 (unique_violation).
comptime UNIQUE_VIOLATION_TOKEN: String = "UNIQUE_VIOLATION 23505"


@always_inline
def is_unique_violation(msg: String) -> Bool:
    """True iff `msg` is the TERMINAL first-committer-wins UNIQUE violation
    (SQLSTATE 23505). The discriminable signal the SQL face maps to
    unique_violation. Unlike `is_occ_conflict` / `is_commit_retryable`, a 23505
    is NEVER retried — observing the competing value is the terminal condition
    that structurally prevents a perpetual 40001 loop."""
    return msg.find(UNIQUE_VIOLATION_TOKEN) >= 0


@always_inline
def is_occ_conflict(msg: String) -> Bool:
    """True iff `msg` is the first-committer-wins OCC abort (SQLSTATE 40001).
    The discriminable signal the SQL face maps to serialization_failure."""
    return msg.find(OCC_CONFLICT_TOKEN) >= 0


@always_inline
def is_commit_retryable(msg: String) -> Bool:
    """True iff `msg` is a RETRYABLE commit-contention error (the bounded
    create-CAS attempts were exhausted, OR the CAS-manifest append raised its
    own retry-budget-exhausted error). The caller re-drives the txn; NOT a
    correctness failure (the create-CAS slot is still the sole arbiter)."""
    return (
        msg.find(COMMIT_RETRYABLE_TOKEN) >= 0
        or (msg.find("(retryable)") >= 0 and msg.find("exhausted") >= 0)
    )


@always_inline
def _is_transient_chunk_read(msg: String) -> Bool:
    """True iff `msg` is a transient torn-create chunk-read (a chunk whose
    create-CAS WON but whose bytes are still landing — the LocalFs O_EXCL
    torn-create window under cross-thread contention). The full-read returns a
    present-but-zero/partial body, so the chunk codec raises a truncated-decode
    or the store raises not_found. Both are RETRYABLE (re-read after the bytes
    land — sub-ms window), NOT corruption: the create-CAS slot is the sole
    arbiter and a torn body is never a committed conflict."""
    return (
        msg.find("truncated") >= 0
        or msg.find("not_found") >= 0
        or msg.find("404") >= 0
        or msg.find("chunk body length") >= 0
        or msg.find("bad commit-chunk magic") >= 0
    )


@always_inline
def _is_lost_slot_412(msg: String) -> Bool:
    """True iff `msg` is a lost-slot 412/precondition from the parkable
    create-CAS.

    THE LIVE CHANNEL (LOW-1) — both shipping `AsyncCasStore` conformers surface a
    lost slot as an ERR `CasOpProgress` from their `*_start` / `*_poll` verb (the
    S3 conformer always; the in-mem SLOW conformer catches the final-tick sync-put
    412 raise into `CasOpProgress.error(...)`, AND — BLOCKER-2 — on the
    immediate-completion fast path the same catch fires inside `cas_put_start`).
    This classifier gates that ERR in BOTH the START path
    (`_commit_async_begin_attempt`) and the POLL path (`commit_async_poll`), which
    re-read the authoritative head + re-OCC + re-park — SYMMETRICALLY, never a
    terminal error. (The `AsyncManifestAppendOp.take`->None path is a DEFENSIVE
    fallback for a conformer that defers the 412 to `cas_put_take`; not exercised
    by either shipping conformer — see that method's docstring.) The create-CAS
    slot stays the sole arbiter; a 412 is never a correctness failure.

    LOW-2: deliberately does NOT match "If-Match". The create-CAS path is ALWAYS
    If-None-Match (empty expected_etag => create-if-absent), so an "If-Match"
    error never originates here; matching it would risk misclassifying an
    unrelated error as a retryable lost-slot signal (up to
    _MAX_ASYNC_COMMIT_ATTEMPTS spurious retries). The 412 / precondition /
    If-None-Match substrings fully cover both conformers' lost-slot wording."""
    return (
        msg.find("412") >= 0
        or msg.find("precondition") >= 0
        or msg.find("If-None-Match") >= 0
    )


@always_inline
def _tiny_backoff(attempt: Int):
    """A bounded micro-sleep to let an in-flight competitor's bytes land before
    re-reading (the torn-create window is sub-ms). Caps at ~1ms; full jitter is
    unnecessary here (the create-CAS already serializes the slot)."""
    from std.ffi import external_call

    var us = attempt * 50
    if us > 1000:
        us = 1000
    if us > 0:
        _ = external_call["usleep", Int32](UInt32(us))


@fieldwise_init
struct CommitResult(Copyable, Movable, Deinitable):
    """The outcome of a successful commit. `commit_lsn` is the won slot
    (= the commit LSN); -1 for a read-only / empty txn. `did_append` is False
    for a read-only txn (no chunk was written).

    S-a (D-A3): `attempts` is the CREATE-CAS slot-race count
    (`AppendResult.attempts`) — how many create-CAS attempts the winning append
    took (1 = won first try; >1 = lost the slot to a concurrent committer and
    re-drove). This is the per-lineage CONTENTION signal the adaptive-index-
    sharding governor reacts to (slot-race contention, NOT the
    OCC-redrive count). 0 for a read-only txn (no append). POD-only — reuse-safe (no heap fields)."""

    var commit_lsn: Int64
    var did_append: Bool
    var attempts: Int

    @staticmethod
    def read_only() -> CommitResult:
        return CommitResult(Int64(-1), False, 0)

    @staticmethod
    def committed(commit_lsn: Int64, attempts: Int = 1) -> CommitResult:
        """`attempts` defaults to 1 (won first try) so the ~handful of internal
        callers that synthesize a CommitResult without a slot-race count stay
        source-compatible; the live commit path passes `res.attempts`."""
        return CommitResult(commit_lsn, True, attempts)


# =============================================================================
# Txn — the by-value transaction handle (snapshot + write-set buffer).
# =============================================================================

# The sentinel for a txn NOT bound to a partition shard (a plain /
# NONE-table `TableStore.begin()` — the single-lineage path). A partition router
# overwrites it with the real shard slot at begin; `PartitionedTableStore.commit`
# only enforces the begin==commit invariant when the slot is >= 0, so every plain
# `TableStore` caller is byte-inert.
comptime _TXN_SHARD_UNBOUND: Int = -1


struct Txn(Movable, Deinitable):
    """A transaction handle, owned by value and threaded through the op
    methods. Holds the pinned snapshot LSN + the in-RAM write-set buffer.

    NO pointer to the store lives on `Txn` (the store is passed `mut`/`ref` to
    each `TableStore` method) — avoids a long-lived borrowed-pointer field
    (hard-ban #3 removal of the borrowed-nulled carve-out). The write-set is a
    plain `List[WriteOp]`, deduped by key (last write per key wins), NOT a
    `Slab` (reuse-safe trivially).

    THE SHARD-BINDING tag. `shard_slot` is
    the partition shard SLOT a `PartitionedTableStore` pinned this txn's snapshot
    on (set by the router's `begin_on` / `begin_for_key`). It makes the
    begin==commit-shard invariant STRUCTURALLY enforced: `PartitionedTableStore.
    commit` asserts the routed target slot == `shard_slot` and raises (the
    cross-shard token) on a mismatch, replacing an earlier docstring-only
    precondition. A PLAIN (un-partitioned) `TableStore.begin()` leaves it at the
    `_TXN_SHARD_UNBOUND` sentinel (-1) — the NONE / single-lineage path never
    consults it, so the field is byte-inert for every non-partitioned caller
    (the existing 1-arg `Txn(snapshot_lsn)` call sites are unchanged: the new
    parameter is DEFAULTED). A POD Int — reuse-safe trivially.

    Field layout:
      var snapshot_lsn: Int64       — the snapshot pinned at begin (-1 = empty).
      var write_set: List[WriteOp]  — buffered mutations, deduped by key.
      var is_open: Bool             — False after commit/abort (use-after-end
                                       guard).
      var shard_slot: Int           — the partition shard slot this
                                       txn is bound to (-1 = _TXN_SHARD_UNBOUND,
                                       the plain/NONE path).
    """

    var snapshot_lsn: Int64
    var write_set: List[WriteOp]
    var is_open: Bool
    var shard_slot: Int

    def __init__(out self, snapshot_lsn: Int64, shard_slot: Int = _TXN_SHARD_UNBOUND):
        self.snapshot_lsn = snapshot_lsn
        self.write_set = List[WriteOp]()
        self.is_open = True
        self.shard_slot = shard_slot

    def _buffer(mut self, op: UInt8, var key: List[UInt8], var row: List[UInt8]):
        # Dedup by key: last write per key wins (overwrite in place).
        for i in range(len(self.write_set)):
            if bytes_eq(self.write_set[i].key, key):
                self.write_set[i].op = op
                self.write_set[i].row = row^
                return
        self.write_set.append(WriteOp(op, key^, row^))

    def insert(mut self, var key: List[UInt8], var row: List[UInt8]) raises:
        """Buffer a PUT (RAM-only). insert/update are both PUT at this layer —
        insert-vs-update existence semantics are a SQL-binder concern."""
        if not self.is_open:
            raise Error("Txn.insert: transaction is not open")
        self._buffer(TS_OP_PUT, key^, row^)

    def update(mut self, var key: List[UInt8], var row: List[UInt8]) raises:
        """Buffer a PUT (RAM-only). Same as insert at this layer."""
        if not self.is_open:
            raise Error("Txn.update: transaction is not open")
        self._buffer(TS_OP_PUT, key^, row^)

    def delete(mut self, var key: List[UInt8]) raises:
        """Buffer a TOMBSTONE (RAM-only)."""
        if not self.is_open:
            raise Error("Txn.delete: transaction is not open")
        self._buffer(TS_OP_TOMBSTONE, key^, List[UInt8]())

    def buffered(self, key: List[UInt8]) -> Optional[WriteOp]:
        """The txn's own buffered op for `key`, if any (the RYOW probe).
        A reader checks this FIRST, overriding the snapshot view."""
        for i in range(len(self.write_set)):
            if bytes_eq(self.write_set[i].key, key):
                return Optional(self.write_set[i].copy())
        return Optional[WriteOp](None)


# =============================================================================
# AsyncCommitOp — the carried-across-park state for a poll-shaped commit.
# =============================================================================
# (table-store P2). The parkable commit's in-flight state, owned by
# the caller (e.g. on a per-connection `Slab`) across the create-CAS round-trip. The
# TableStore drives it via `commit_async_start`/`commit_async_poll`; the
# IN-FLIGHT create-CAS op (transport buffers) lives inside the `_wal._store`
# conformer (the stale-reuse contract), NOT here — this struct holds ONLY the consumed
# txn's snapshot + write-set (the OCC + chunk-body inputs), the attempt counter,
# the in-flight slot/auth-head, and the terminal outcome. Plain owned values +
# PODs — NO byte-slab, NO wildcard origin, NO pointer (trivially reuse-safe, including
# when stored on a caller's `Slab` via the concrete-origin Slab access).
#
# NOT a TableStore method-state: the op is SEPARATE from the store so the serve
# loop can hold it on the per-connection state across the park while the store
# stays a single shared server field (mirror of the broker's AsyncReassignOp,
# which the SuspendableHandler owns separately from the coordinator).

# The async-commit attempt bound — mirrors the sync `MAX_COMMIT_ATTEMPTS`.
comptime _MAX_ASYNC_COMMIT_ATTEMPTS: Int = 256

comptime _ACO_PHASE_RUNNING: UInt8 = 0
comptime _ACO_PHASE_DONE: UInt8 = 1
comptime _ACO_PHASE_ERR: UInt8 = 2


@fieldwise_init
struct AsyncCommitOp(Movable, Deinitable):
    """The carried-across-park state for a poll-shaped commit.

    Built from a consumed `Txn` (`AsyncCommitOp.from_txn(txn^)`); the TableStore
    drives it step-wise on the serve reactor. On completion the caller checks
    `is_done()`/`is_error()` and then `take_result()` (the won CommitResult) or
    `err_text()` (the OCC 40001 / retryable token). Movable, NOT Copyable: owns
    the write-set List + the error String.

    stale-reuse: a plain owned struct (snapshot Int64 + a `List[WriteOp]` + PODs + an
    error String). It is NOT a byte-slab element itself; when a caller holds
    it on a `Slab` it is reached via the concrete-origin Slab access (no
    wildcard cast), so the reuse-safe argument is the same as for any other
    heap-owning field reached that way."""

    var _snapshot: Int64
    var _write_set: List[WriteOp]
    var _phase: UInt8
    var _attempt: Int
    # In-flight create-CAS bookkeeping carried across the park (the POD MIRROR of
    # `AsyncManifestAppendOp`'s state — the actual transport in-flight op lives
    # inside the WAL's `_store` conformer, so the driver reconstructs a transient
    # `AsyncManifestAppendOp[Store]` from these each poll):
    #   * `_candidate`    — the slot the parked create-CAS targets.
    #   * `_base`         — the slot's base offset.
    #   * `_auth_head_seq`— the auth-head seq the OCC validated against (the
    #                       win-path fold's upper bound — MUST-FIX #1).
    #   * `_append_inflight` — True while a create-CAS is parked (so `poll`
    #                       re-enters the in-flight conformer op, not a fresh one).
    var _candidate: Int64
    var _base: Int64
    var _auth_head_seq: Int64
    var _append_inflight: Bool
    # Terminal outcome.
    var _result: CommitResult
    var _err: String

    @staticmethod
    def from_txn(var txn: Txn) raises -> AsyncCommitOp:
        """Build a commit op from a consumed open txn (the SQL face calls this
        in place of `store.commit(txn^)`). RYOW already collapsed duplicate keys
        in the buffer. Consumes `txn`."""
        if not txn.is_open:
            raise Error("AsyncCommitOp.from_txn: transaction is not open")
        txn.is_open = False
        var snap = txn.snapshot_lsn
        var ws = txn.write_set.copy()
        _ = txn^
        return AsyncCommitOp(
            _snapshot=snap,
            _write_set=ws^,
            _phase=_ACO_PHASE_RUNNING,
            _attempt=0,
            _candidate=Int64(0),
            _base=Int64(0),
            _auth_head_seq=Int64(-1),
            _append_inflight=False,
            _result=CommitResult.read_only(),
            _err=String(""),
        )

    @always_inline
    def write_set_len(self) -> Int:
        return len(self._write_set)

    @always_inline
    def snapshot_lsn_value(self) -> Int64:
        """The consumed txn's pinned snapshot (group-commit reads it to build the
        member's TableStoreGroupCommitItem). POD read, no move."""
        return self._snapshot

    def write_set_copy(self) -> List[WriteOp]:
        """A COPY of the carried write-set (group-commit moves each queued conn's
        write-set into a group member; WriteOp is Copyable, so a copy is a clean
        value handoff that leaves the consumed op droppable)."""
        return self._write_set.copy()

    @always_inline
    def is_done(self) -> Bool:
        return self._phase == _ACO_PHASE_DONE

    @always_inline
    def is_error(self) -> Bool:
        return self._phase == _ACO_PHASE_ERR

    @always_inline
    def err_text(self) -> String:
        return self._err

    def take_result(self) raises -> CommitResult:
        """The won CommitResult (caller checks is_done() first)."""
        if self._phase != _ACO_PHASE_DONE:
            raise Error("AsyncCommitOp.take_result: not done")
        return self._result.copy()

    def _finish_read_only(mut self):
        self._phase = _ACO_PHASE_DONE
        self._result = CommitResult.read_only()

    def _finish_committed(mut self, commit_lsn: Int64):
        self._phase = _ACO_PHASE_DONE
        self._result = CommitResult.committed(commit_lsn)

    def _set_error(mut self, var msg: String):
        self._phase = _ACO_PHASE_ERR
        self._err = msg^

    @staticmethod
    def terminal_committed(commit_lsn: Int64) -> AsyncCommitOp:
        """A TERMINAL (already-DONE, committed) op carrying `commit_lsn` + an
        EMPTY write-set. Group-commit's fan-out synthesizes one
        per WINNER member so the caller's single-commit terminal handling (the win
        reply and its finalize step) drives the terminal — the write-set was ALREADY
        folded into the index by the group driver's finalize_commit_win, so the
        synthesized op's write-set is empty (the terminal helper only reads
        is_done()/take_result(), never re-folds)."""
        var op = AsyncCommitOp(
            _snapshot=Int64(0),
            _write_set=List[WriteOp](),
            _phase=_ACO_PHASE_DONE,
            _attempt=0,
            _candidate=Int64(0),
            _base=Int64(0),
            _auth_head_seq=Int64(-1),
            _append_inflight=False,
            _result=CommitResult.committed(commit_lsn),
            _err=String(""),
        )
        return op^

    @staticmethod
    def terminal_error(var msg: String) -> AsyncCommitOp:
        """A TERMINAL (already-ERR) op carrying `msg` (an OCC 40001 / retryable).
        Group-commit's fan-out synthesizes one per LOSER member conn so the
        caller's single-commit terminal handling drives the loss reply (the
        SQLSTATE error and its undo step) —
        the loser's write-set NEVER entered the merged chunk (never persisted)."""
        var op = AsyncCommitOp(
            _snapshot=Int64(0),
            _write_set=List[WriteOp](),
            _phase=_ACO_PHASE_ERR,
            _attempt=0,
            _candidate=Int64(0),
            _base=Int64(0),
            _auth_head_seq=Int64(-1),
            _append_inflight=False,
            _result=CommitResult.read_only(),
            _err=msg^,
        )
        return op^


# =============================================================================
# TableStore[Store] — the single-table MVCC store over a CAS-manifest WAL.
# =============================================================================


struct TableStore[Store: ConditionalWriteStore](Movable, Deinitable):
    """Single-table key->row MVCC store over a CAS-manifest WAL.

    Owns the `CasManifestStore[Store]` (which owns the backend `Store` by
    value) + the in-RAM `KeyIndex` memtable. Generic over the backend so the
    SAME code runs on InMemory / SharedInMemory / LocalFs now and S3 later,
    unchanged.

    Fields:
      var _wal: CasManifestStore[Store]   — the durable commit log.
      var _index: KeyIndex                — the in-RAM memtable; rebuildable.
      var _folded_seq: Int64              — the highest WAL chunk_seq folded
                                            into `_index` so far (-1 = none).
                                            The index is a CACHE of the WAL up
                                            to this seq; reads fold the delta
                                            `(_folded_seq, snapshot]` before
                                            serving so a handle observes ALL
                                            handles' commits visible at its
                                            snapshot (MUST-FIX #1 — shared-store
                                            snapshot-authoritative reads).
      var _observed_auth_seq: Int64       — OCC-STARVATION FIX: the highest
                                            AUTHORITATIVE tail this handle has
                                            ever READ (`read_head_authoritative`
                                            / the lease head), monotone, -1 =
                                            none. `begin()` floors the snapshot
                                            at it so a writer that just lost an
                                            OCC race re-pins at the tail it
                                            demonstrably observed instead of
                                            falling back to the lagging durable
                                            `_HEAD`. See `begin()`.
    """

    var _wal: CasManifestStore[Self.Store]
    var _index: KeyIndex
    var _folded_seq: Int64
    # OCC-STARVATION FIX (see `begin()` / `_note_observed_auth`). Monotone
    # high-water mark of AUTHORITATIVE tails this handle has read. POD Int64.
    var _observed_auth_seq: Int64
    # SECONDARY INDEX — the per-index memtable family,
    # routed purely by the leading 4-byte lineage ordinal of each WriteOp key.
    #   * `_idx_lineage_ords[i]` is index i's disjoint high-band lineage ordinal.
    #   * `_idx_indexes[i]` is index i's memtable, boxed in an OwnedPointer.
    #
    # CONTAINER (SINGLE-OWNER `Slab[OwnedPointer[KeyIndex]]`):
    # a single-owner Slab of single-owner OwnedPointer boxes. The TableStore is
    # the SOLE owner of the index family — it is never copied (no clone() ever
    # escapes), so the container is single-owner end to end; NO ArcPointer (the
    # refcount/shared-ownership machinery is exactly what the pointer rules
    # say to avoid for state that does not genuinely share).
    #
    # Why the OwnedPointer box (not a by-value `Slab` OF `KeyIndex`): the
    # OwnedPointer gives a STABLE KeyIndex heap address across slab grows. When
    # the Slab reallocates its byte buffer (`append` past capacity), only the
    # 8-byte OwnedPointer handles relocate — the boxed KeyIndex (and its inner
    # `List[KeyChain]` heap buffer) stay put — so a ref taken into a KeyIndex is
    # not invalidated by a later register_index that grows the slab. (A by-value
    # `Slab` of `KeyIndex` is ALSO single-owner and reuse-safe, but a held
    # KeyIndex ref would dangle across a grow; the boxed form removes that
    # footgun.)
    #
    # REUSE-SAFETY: the unified `Slab[T]` (`komira_collections/slab.mojo`)
    # is REUSE-SAFE by construction — it stores T BY VALUE in CONCRETE-ORIGIN byte
    # storage (`self._bytes.unsafe_ptr().bitcast[T]()`, origin tied to `self`,
    # NO wildcard) with a hand-written `__del__` that destroys each live slot. It
    # is NOT the engine's separate wildcard byte-arena; element T here is the POD
    # 8-byte `OwnedPointer[KeyIndex]` handle (the KeyIndex's heap-owning
    # `List[KeyChain]` lives behind the OwnedPointer, not inside the slab bytes),
    # so there is no byte-slab + heap-owning-inner-field trap. `Slab[T]`'s bound
    # is `T: Deinitable` (NOT Copyable) — it stores move-only
    # OwnedPointer boxes directly.
    #
    # The two containers are PARALLEL (same slot order — `_idx_lineage_ords` is a
    # plain POD `List[Int32]`). A WriteOp whose key begins with
    # `_idx_lineage_ords[i]` folds into `_idx_indexes[i][]` (Slab index -> deref
    # the OwnedPointer); a heap-ordinal key folds into `_index`. The fold ROUTING
    # lives HERE in TableStore, NOT in KeyIndex.apply_write_set (which is a method
    # on ONE memtable and physically cannot route to a sibling).
    var _idx_lineage_ords: List[Int32]
    var _idx_indexes: Slab[OwnedPointer[KeyIndex]]
    # -------------------------------------------------------------------------
    # SINGLE-WRITER LEASE LIST-ELISION FAST-PATH (DEFAULT-ON per
    # was DEFAULT-OFF at landing)
    # -------------------------------------------------------------------------
    # The biggest remaining median commit-latency win: in single-writer steady
    # state, ELIDE the per-commit (post-P3: per coalesced BATCH) authoritative
    # head recovery — `read_head_authoritative()` is a LIST + a GET-per-chunk
    # record-count replay (`_recover_head_by_list`, ~700ms+, grows with chunk
    # count). When the lease is held (the flag is on AND a local monotone head
    # is warm), the commit OCC-validates against the LOCAL head (0 GETs) and
    # create-CASes at `local_head + 1` with the real (writer_lease_epoch,
    # current_lease_epoch). This MIRRORS the broker's `_LocalHeadCache`
    # (cas_manifest.mojo:523-597) — the local cache is the LIST-eliding
    # MECHANISM; the writer lease-epoch is the correctness LICENSE ("I am the
    # sole live writer; my local head is authoritative for my next commit").
    #
    # CORRECTNESS (the load-bearing invariant — the same one `_LocalHeadCache` states): the
    # local head is NEVER a correctness oracle. The chunk create-CAS slot stays
    # the SOLE OCC arbiter (gaplessness + offset density). A WRONG/STALE local
    # head can only LOSE the slot (412) — never commit a wrong offset. On a 412
    # the lease head is INVALIDATED and the commit falls back to today's
    # `read_head_authoritative()` LIST + full OCC + retry. So the result is
    # strictly >= today's (first commit after a cold start lists + warms, the
    # rest elide). NO isolation hole: in single-writer steady state the local
    # head IS the true authoritative head (this writer committed the last chunk,
    # no sibling exists), so OCC over `(snapshot, local_head]` is byte-identical
    # to OCC over `(snapshot, auth_head]`; a sibling that slips a chunk in is
    # caught by the 412 -> re-LIST -> re-OCC against the now-visible competitor.
    #
    # stale-reuse: PLAIN VALUE FIELDS (Bool + Int64) — NO byte-slab element, NO heap-
    # owning inner field, NO wildcard origin, NO UnsafePointer. reuse-safe (no heap fields), by the
    # same reasoning the `_LocalHeadCache` header gives (cas_manifest.mojo:546).
    #
    #   * `_lease_fastpath_enabled` — the DEFAULT-ON flag (was
    #     DEFAULT-OFF ). When False every commit path is
    #     byte-identical to the pre-lease behavior (always reads the LIST head);
    #     ops can flip it off at runtime via `disable_writer_lease_fastpath()`
    #     (no logic redeploy) or construct with `with_writer_lease_fastpath=False`.
    #   * `_lease_head_present`     — True iff the local head is warm + trusted.
    #   * `_lease_head_seq`         — cached highest committed chunk seq.
    #   * `_lease_head_next_offset` — cached base offset for the next commit.
    #   * `_writer_lease_epoch`     — the owner's per-lineage lease generation
    #                                 (the broker-style fence; 0 = no lease).
    #   * `_current_lease_epoch`    — the live generation read authoritatively
    #                                 (0 = no lease). A `_writer_lease_epoch <
    #                                 _current_lease_epoch` is FENCED at the
    #                                 create-CAS (`try_append_at_seq` raises
    #                                 `lease_fenced`) -> invalidate + fall back.
    var _lease_fastpath_enabled: Bool
    var _lease_head_present: Bool
    var _lease_head_seq: Int64
    var _lease_head_next_offset: Int64
    var _writer_lease_epoch: Int64
    var _current_lease_epoch: Int64

    def __init__(
        out self,
        var wal: CasManifestStore[Self.Store],
        with_writer_lease_fastpath: Bool = True,
    ):
        """Construct a TableStore.

        `with_writer_lease_fastpath` — the single-writer lease LIST-elision
        fast-path's DEFAULT. DEFAULT-ON: the measurement
        (workflow wo2yza4so) proved lease-ON wins at EVERY regime — single-writer
        AND multi-writer-same-lineage (N=16: ~12x fewer store-ops, p99 ratio
        0.11-0.20x, ON had ZERO terminal-fails vs OFF's 3 replay-storm
        livelocks) — so the global default is ON, not conditional. Pass False
        (or call `disable_writer_lease_fastpath()` at runtime) to construct/run
        with it OFF — ops can turn it off WITHOUT a logic redeploy via the
        runtime disable. Default-ON warms COLD with NO lease epochs (0,0) so the
        non-zero-epoch async/group guard stays DORMANT; the
        first commit lists + warms, the rest elide."""
        self._wal = wal^
        self._index = KeyIndex()
        self._folded_seq = Int64(-1)
        self._observed_auth_seq = Int64(-1)
        self._idx_lineage_ords = List[Int32]()
        self._idx_indexes = Slab[OwnedPointer[KeyIndex]]()
        # Lease fast-path DEFAULT-ON ; cold (no warm local head
        # until the first commit lists + warms); NO lease epochs (0,0) so the
        # non-zero-epoch async/group fence guard is dormant.
        self._lease_fastpath_enabled = with_writer_lease_fastpath
        self._lease_head_present = False
        self._lease_head_seq = Int64(-1)
        self._lease_head_next_offset = Int64(0)
        self._writer_lease_epoch = Int64(0)
        self._current_lease_epoch = Int64(0)

    # ---- secondary-index memtable registration + routed write-set fold -------
    #
    # The index lineage ordinals MUST be registered
    # BEFORE any WAL chunk carrying their keys is folded (live commit OR replay),
    # so the fold can route an index-lineage WriteOp to its own memtable. The SQL
    # layer registers an index's lineage ordinal at `open()` (after recovering
    # the catalog) and at CREATE INDEX time (before the backfill commit).

    def register_index(mut self, index_lineage_ord: Int32) raises:
        """Register a secondary-index lineage so subsequent folds route its
        WriteOps into a dedicated memtable. Idempotent (a re-register of an
        already-known ordinal is a no-op — the SQL layer re-registers every
        catalog index at open()).

        CATCH-UP FOLD: a register that arrives AFTER the store
        has already folded WAL history (`_folded_seq > -1` — the open()-replay
        ran, or a prior read advanced the cache) must re-fold the ALREADY-FOLDED
        range `[log_start, _folded_seq]` into the NEW index memtable. Otherwise
        the index WriteOps in those chunks were routed to the heap memtable (the
        lineage was not yet registered when they were folded) and the index would
        be silently empty. This catch-up scans the WAL once and applies ONLY the
        new lineage's WriteOps into the new memtable, so the post-register index
        memtable is byte-identical to one folded with the lineage present from the
        start. (The stray index-prefix entries left in the heap memtable by the
        pre-register fold are benign — heap reads are bounded to the low-band
        table prefix range, never the high-band index lineage.)"""
        for i in range(len(self._idx_lineage_ords)):
            if self._idx_lineage_ords[i] == index_lineage_ord:
                return  # already registered — no-op (idempotent open()/re-run)
        self._idx_lineage_ords.append(index_lineage_ord)
        self._idx_indexes.append(OwnedPointer[KeyIndex](KeyIndex()))
        var slot = len(self._idx_indexes) - 1
        # catch-up fold over the already-folded WAL range for THIS lineage only.
        if self._folded_seq >= Int64(0):
            var ls = self._wal.read_log_start()
            var start = ls.log_start_seq
            if start < Int64(0):
                start = Int64(0)
            var seq = start
            while seq <= self._folded_seq:
                var body: List[UInt8]
                try:
                    body = self._wal.read_chunk(seq)
                except e:
                    _ = e
                    break  # no committed chunk at/below the bound — stop.
                var chunk = decode_commit_chunk(body)
                # Option-A S-b: a sharded-index chunk folds at its explicit
                # stamp_lsn (the heap DML-LSN), else the WAL seq (byte-identical).
                var fold_lsn = _fold_lsn_for_chunk(seq, chunk)
                for wi in range(len(chunk.write_set)):
                    ref w = chunk.write_set[wi]
                    if self._key_lineage_ord(w.key) == index_lineage_ord:
                        self._idx_indexes[slot][].apply_write(fold_lsn, w)
                seq += Int64(1)

    @always_inline
    def _key_lineage_ord(self, key: List[UInt8]) -> Int32:
        """The leading 4-byte BIG-ENDIAN lineage ordinal of a TableStore key
        (the EXT-2 / index-lineage prefix `encode_table_prefix` produced). A key
        shorter than 4 bytes (never produced by the codecs) yields -1 so it
        routes to the heap (the safe default)."""
        if len(key) < 4:
            return Int32(-1)
        var u = UInt32(0)
        for i in range(4):
            u = (u << UInt32(8)) | UInt32(Int(key[i]))
        return Int32(Int(u))

    def _idx_slot_for_ord(self, lineage_ord: Int32) -> Int:
        """The `_idx_indexes` slot whose lineage ordinal equals `lineage_ord`, or
        -1 if `lineage_ord` is not a registered index lineage (=> route to heap).
        Linear scan over the (small) registered-index list."""
        for i in range(len(self._idx_lineage_ords)):
            if self._idx_lineage_ords[i] == lineage_ord:
                return i
        return -1

    def _route_apply_write_set(
        mut self, commit_lsn: Int64, write_set: List[WriteOp]
    ):
        """Fold a committed write-set at `commit_lsn`, ROUTING each WriteOp by
        its leading 4-byte lineage ordinal into `_index` (heap) OR the matching
        `_idx_indexes[i]` (the routing lives in TableStore, the
        ONE place that can reach a sibling memtable). The same dispatch is used by
        the live commit, the open-time replay, and the cross-handle fold so the
        three paths produce byte-identical memtables (recovery byte-identity)."""
        for wi in range(len(write_set)):
            ref w = write_set[wi]
            var ord = self._key_lineage_ord(w.key)
            var slot = self._idx_slot_for_ord(ord)
            if slot < 0:
                self._index.apply_write(commit_lsn, w)
            else:
                self._idx_indexes[slot][].apply_write(commit_lsn, w)

    # ---- recovery: rebuild _index from the WAL (bucket-is-truth) ----

    @staticmethod
    def open(
        var wal: CasManifestStore[Self.Store],
        with_writer_lease_fastpath: Bool = True,
    ) raises -> Self:
        """Construct + replay `[log_start .. head_authoritative]` ascending
        into the index. Uses `read_head_authoritative` (NOT the cached
        `_HEAD`) — recovery is a correctness path that must see the true
        highest-committed slot. A version is visible iff it is the newest
        `<= S` non-tombstone — a pure function of the reconstructed chain, so
        recovered state == pre-crash committed state.

        `with_writer_lease_fastpath` — the lease LIST-elision fast-path's
        DEFAULT-ON escape-hatch, forwarded to `__init__`. Pass
        False to construct a lease-OFF store (ops can also disable at runtime via
        `disable_writer_lease_fastpath()` — no logic redeploy)."""
        var ts = Self(wal^, with_writer_lease_fastpath)
        ts._replay_into_index()
        return ts^

    @staticmethod
    def open_deferred(
        var wal: CasManifestStore[Self.Store],
        with_writer_lease_fastpath: Bool = True,
    ) raises -> Self:
        """Construct WITHOUT replaying the WAL (`_folded_seq` stays -1). The
        caller MUST `register_index` every secondary-index lineage it knows
        about (from the recovered catalog) and THEN call `replay()` — so the
        ONE replay pass routes every chunk into every index memtable in a
        SINGLE WAL scan.

        PERF-CRITICAL (the per-request cache work — the dominant
        per-request-open cost). The alternative ordering — `open()` (replay
        heap-only) THEN `register_index` per index — forces register_index's
        catch-up fold to RE-READ EVERY WAL chunk once PER INDEX (each
        `read_chunk` is an UNCACHED GCS GET, cas_manifest.mojo:2624). On a
        C-chunk store with K indexes that is ~K·C GETs at open. With
        register-before-replay it is C GETs total: the single `replay()` scan
        already visits every chunk and `_route_apply_write_set` already routes
        to every registered memtable (the `_replay_into_index` comment was
        written for EXACTLY this ordering). Measured on an 8-chunk
        store: the catalog/index-registration phase dropped from ~6s to ~1s.
        Do NOT collapse this back to `open()` + per-index `register_index`
        without re-introducing the K·C re-fold.

        `with_writer_lease_fastpath` — the lease LIST-elision fast-path's
        DEFAULT-ON escape-hatch, forwarded to `__init__`."""
        return Self(wal^, with_writer_lease_fastpath)

    def replay(mut self) raises:
        """Run the single WAL replay pass (`[log_start..head]`), routing each
        chunk into the heap memtable + every REGISTERED index memtable. Call
        exactly once after `open_deferred` + the `register_index` calls. (A
        re-call re-folds from log_start — correct but wasteful; the intended
        use is one call post-registration)."""
        self._replay_into_index()

    # TORN-CREATE SETTLE BOUND — how many times an AUTHORITATIVE read may
    # re-drive a present-but-still-landing chunk. The LocalFs O_EXCL window is
    # sub-ms and `_tiny_backoff` ramps to 1ms, so this is ~30ms of patience.
    comptime _REPLAY_SETTLE_ATTEMPTS: Int = 32

    def _read_head_authoritative_settled(mut self) raises -> ManifestHead:
        """`read_head_authoritative()` that TOLERATES the LocalFs O_EXCL
        torn-create window (a chunk whose create-CAS WON but whose bytes are
        still landing — present-but-zero-length).

        WHY (the second half of the K=16 LocalFs soak red): the LIST recovery
        GETs every chunk to replay cumulative record_counts, so a concurrent
        committer's in-flight chunk makes it raise `cas_manifest: truncated i64
        at offset 0`. `_occ_check` has ALWAYS classified exactly this as
        RETRYABLE ("a TRANSIENT contention condition, NOT a conflict and NOT a
        corruption"), but the recovery path did not — so `TableStore.open()`
        against a store that ANOTHER writer is actively committing to raised an
        UNCLASSIFIED error and killed the caller. Measured: 2 of 16 soak writer
        threads died at `open()` this way, losing all 20 of their rounds.

        This does NOT paper over corruption: a chunk that never settles still
        raises after the bound, and a NON-transient error is re-raised
        immediately and unchanged."""
        var attempt = 0
        while True:
            attempt += 1
            try:
                return self._wal.read_head_authoritative()
            except e:
                if (
                    not _is_transient_chunk_read(String(e))
                    or attempt >= Self._REPLAY_SETTLE_ATTEMPTS
                ):
                    raise e^
                _tiny_backoff(attempt)

    def _read_head_settled(self) raises -> ManifestHead:
        """`read_head()` that TOLERATES a TORN read of the `_HEAD` POINTER
        OBJECT (same contract + bound as `_read_head_authoritative_settled`).

        WHY (the THIRD site of the torn-read class, measured post-rebase at
        ~5% of K=16 LocalFs soak runs — 3 of 60). The two settled helpers above
        cover the RECOVERY path (`_replay_into_index`). They do not cover
        `begin()`, which reads the durable pointer via `read_head()`:

          * `_read_head_inner` (cas_manifest.mojo:1442) GETs `<prefix>/_HEAD`
            and `decode_head`s it. Every committer advances that object
            best-effort (`_try_advance_head`), and on LocalFs that write is NOT
            atomic — so a concurrent GET can observe a PARTIALLY-WRITTEN
            `_HEAD` and `decode_head` raises `cas_manifest: truncated i64 at
            offset 0`.
          * `_read_head_inner` already treats an ABSENT `_HEAD` as "the cache
            is unusable, LIST the bucket" (the pointer is a CACHE; the bucket
            is the source of truth). A TORN `_HEAD` is the
            same condition, but it escaped as an UNCLASSIFIED error.
          * So `begin()` — which callers reasonably treat as infallible
            snapshot-pinning and place OUTSIDE their commit-retry try — killed
            the caller outright. Measured: 1 of 16 soak writer threads died in
            `begin()` this way, losing all 10 of its rounds (150 of 160 private
            keys committed) at ~5% of runs.

        Re-reading is SAFE and side-effect-free: `begin()` pins a snapshot and
        writes nothing, and a torn pointer read is never a committed fact. The
        bound is the same 32 attempts / ~30ms of patience; a `_HEAD` that never
        settles still raises, and a NON-transient error is re-raised
        immediately and unchanged, so this cannot mask a real store failure.

        NOTE (the deeper fix, deliberately NOT taken here): the principled
        place is `CasManifestStore._read_head_inner`, which could fold a torn
        decode into the SAME `_recover_head_by_list()` escape it already has
        for an absent `_HEAD` — fixing every `read_head()` consumer at once.
        That is an `komira_objectstore` change affecting the broker and KG
        read paths; it belongs to that module's owner, not to this fix."""
        var attempt = 0
        while True:
            attempt += 1
            try:
                return self._wal.read_head()
            except e:
                if (
                    not _is_transient_chunk_read(String(e))
                    or attempt >= Self._REPLAY_SETTLE_ATTEMPTS
                ):
                    raise e^
                _tiny_backoff(attempt)

    def _read_chunk_settled(mut self, seq: Int64) raises -> CommitChunk:
        """`read_chunk` + decode that tolerates the torn-create window (same
        contract as `_read_head_authoritative_settled`)."""
        var attempt = 0
        while True:
            attempt += 1
            try:
                var body = self._wal.read_chunk(seq)
                return decode_commit_chunk(body)
            except e:
                if (
                    not _is_transient_chunk_read(String(e))
                    or attempt >= Self._REPLAY_SETTLE_ATTEMPTS
                ):
                    raise e^
                _tiny_backoff(attempt)

    def _replay_into_index(mut self) raises:
        # bucket-is-truth: the AUTHORITATIVE head + the log-start pointer.
        # SETTLED: a concurrent committer's in-flight chunk is a transient
        # contention condition, not a recovery failure (see the helper).
        var head = self._read_head_authoritative_settled()
        var ls = self._wal.read_log_start()
        var start_seq = ls.log_start_seq
        if start_seq < Int64(0):
            start_seq = Int64(0)
        var seq = start_seq
        # Replay ascending so each key's chain is built in commit-LSN order
        # (the slot sequence is monotone gapless — no sort needed).
        while seq <= head.chunk_seq:
            var chunk = self._read_chunk_settled(seq)
            # Route each WriteOp by its lineage ordinal into the
            # heap memtable OR the matching index memtable (the catalog indexes
            # were register_index'd before this replay, so the routing knows
            # every index lineage; a chunk written before an index existed simply
            # has no WriteOps in that lineage).
            # Option-A S-b: a sharded-index chunk folds at its explicit stamp_lsn
            # (the heap DML-LSN L), else the WAL seq (byte-identical single-WAL).
            self._route_apply_write_set(
                _fold_lsn_for_chunk(seq, chunk), chunk.write_set
            )
            seq += Int64(1)
        # The index is now a complete cache of the WAL up to the authoritative
        # head: record the high-water mark so subsequent reads only fold the
        # cross-handle delta committed AFTER this point (MUST-FIX #1).
        self._folded_seq = head.chunk_seq
        # OCC-STARVATION FIX: the replay head came from the AUTHORITATIVE tail,
        # so it is also a valid observed-tail floor for `begin()`.
        self._note_observed_auth(head.chunk_seq)

    # ---- transaction lifecycle ----

    def begin(self) raises -> Txn:
        """Pin a snapshot. `snapshot_lsn = max(read_head().chunk_seq,
        _folded_seq)` — never BELOW what THIS handle has already authoritatively
        observed (the highest WAL chunk folded into its index at open()/a prior
        commit/read). `-1` for an empty log (nothing committed yet). No object
        is written on begin.

        P0 STALE-LOW-HEAD FIX (a stale snapshot after a second writer). The cached
        durable `_HEAD` is advanced only best-effort and can LAG the true tail (a
        2nd / interrupted writer committed chunks but the `_HEAD` pointer never
        caught up). Pinning a snapshot straight off the lagging `_HEAD` made a
        FRESH handle — which already replayed the AUTHORITATIVE tail at open()
        (`_folded_seq = read_head_authoritative().chunk_seq`) — pin a snapshot
        BELOW chunks it had already folded, so `get()`/`scan()` (which fold only
        `(_folded_seq, snapshot]`, a no-op when snapshot <= _folded_seq) served
        a stale view that MISSED the just-committed rows. To a reader it
        looks as if the 2nd writer corrupted the store: a fresh handle cannot
        see the data.

        `_folded_seq` is a SOUND lower bound on the visible tail (every chunk
        <= it is durably folded into this handle's index, observed via the
        AUTHORITATIVE LIST at open or a committed write), so pinning at least it
        is never AHEAD of what this handle has read — SI is preserved (a reader
        may always pin a NEWER-but-already-observed snapshot; it never pins one
        ahead of committed truth). Taking the MAX also keeps the common warm
        single-writer case (where `_HEAD` == tail >= `_folded_seq`) unchanged.

        OCC-STARVATION FIX (table-store LocalFs K-writer soak livelock). The
        `max` above is ALSO floored by `_observed_auth_seq` — the highest
        AUTHORITATIVE tail this handle has ever read. Without it a contended
        writer STARVES FOREVER, and this is not a tail-probability effect but a
        structural no-progress state:

          * `read_head()`'s only LIST escape fires when `_HEAD` is ABSENT, never
            when it is PRESENT-BUT-STALE-LOW. The durable `_HEAD` advance is
            best-effort (`_try_advance_head`) and under K-way contention it
            loses its CAS races and effectively STALLS.
          * `_folded_seq` only advances on THIS handle's own commit or read.
          * So a writer that keeps LOSING its OCC race re-pins `begin()` at the
            SAME stale-low snapshot every retry, while the true tail runs away.
            Its OCC window `(snapshot, auth_head]` therefore only GROWS and
            always contains the contended key => every retry aborts 40001, with
            probability of success EXACTLY ZERO. Measured on the K=16 LocalFs
            soak: snapshot frozen at seq 17 for 400 consecutive attempts while
            the true tail reached 159; every attempt raised "conflict on a key
            committed at chunk_seq 18 > snapshot 17".
          * The cruel part: `_commit_impl` had ALREADY READ the true tail
            (`lease_auth_head_for_commit`) microseconds earlier and threw that
            knowledge away when it raised 40001.

        Flooring at `_observed_auth_seq` recovers exactly that discarded fact,
        for ZERO extra I/O. SAFETY is the SAME argument `_folded_seq` uses: a
        tail returned by `read_head_authoritative()` is a REAL committed tail
        this handle OBSERVED, so pinning at it is never AHEAD of committed truth
        (SI preserved — a reader may always pin a newer-but-already-observed
        snapshot). Reads stay correct because `get()`/`scan()` fold the
        `(_folded_seq, snapshot]` delta before serving (MUST-FIX #1).

        This does NOT weaken first-committer-wins: a conflict in the window is
        still a genuine 40001 abort. It only stops the RETRY from being pinned
        to a snapshot that can never win.

        TORN-`_HEAD` FIX: the pointer read is SETTLED (see
        `_read_head_settled`) — a concurrent committer's non-atomic `_HEAD`
        advance can be observed half-written, and that transient must not kill
        a caller that (reasonably) treats snapshot-pinning as infallible."""
        var head = self._read_head_settled()
        var snap = head.chunk_seq
        if self._folded_seq > snap:
            snap = self._folded_seq
        if self._observed_auth_seq > snap:
            snap = self._observed_auth_seq
        return Txn(snap)

    def abort(self, var txn: Txn):
        """Drop the in-RAM write-set buffer. No store interaction (writes only
        touch the object store at commit). The `txn` is consumed by value."""
        txn.is_open = False
        _ = txn^

    def commit(mut self, var txn: Txn) raises -> CommitResult:
        """The OCC-check-then-create-CAS loop. On success, folds the
        committed write-set into `_index` at the won commit_lsn and returns
        `CommitResult.committed(commit_lsn)`. Raises an `OCC_CONFLICT`-tagged
        Error (SQLSTATE 40001) on first-committer-wins loss.

        THE COUPLING: the OCC window upper bound is the AUTHORITATIVE head
        and the create-CAS lands at EXACTLY `auth_head + 1`. Winning that slot
        proves the OCC window `(snapshot, auth_head]` covered every committed
        conflict; a 412 forces re-read-authoritative + re-OCC against the now-
        visible competitor chunk.

        BYTE-IDENTICAL: delegates to `_commit_impl` with `TS_STAMP_LSN_UNSET`
        (-1), so the chunk encodes v2 and the fold stamps rows at the WON WAL
        slot exactly as before. The explicit-DML-LSN path is `commit_index_shard`
        (Option-A S-b)."""
        return self._commit_impl(txn^, TS_STAMP_LSN_UNSET)

    def commit_index_shard(
        mut self,
        var txn: Txn,
        dml_lsn: Int64,
        enable_separate_wal: Bool = False,
    ) raises -> CommitResult:
        """ADAPTIVE INDEX SHARDING — Option-A S-b: commit a
        SHARDED secondary-index lineage's WriteOps to THIS (the index shard's)
        WAL, stamped with the EXPLICIT heap DML-LSN `dml_lsn = L`.

        THE TWO-PHASE (D-A1-(i), the invariant-#3 re-scope crux): `commit_lsn`
        is the base-WAL slot a create-CAS won, so two WALs cannot SHARE a slot
        number. The DML is therefore a HEAP-ANCHORED two-phase across two WALs:
        the HEAP commits to the base WAL FIRST and wins slot `L` (= the DML-LSN);
        THEN the over-contended index lineage commits its index WriteOps HERE,
        winning its OWN shard-WAL slot `S_shard`, but the chunk carries an
        explicit `stamp_lsn = L` so EVERY fold (hot replay, cold columnarize,
        cross-shard merge) reads the index rows at `commit_lsn = L`, NOT
        `S_shard`. This is the exact generalization of the D1-b
        `lo_lsn = MIN(commit_lsn)`-explicit decoupling.

        THE GATE (mirrors the slice-4b disabled-until-proven discipline):
        `enable_separate_wal` defaults FALSE — the SEPARATE-WAL S-b path is
        DISABLED by default until the T-INV3-* + T-CRASH-2 correctness
        falsifiers pass. When False this RAISES (a wired-but-not-yet-enabled
        caller must opt in EXPLICITLY); the mechanism + the gate ship here; turning
        it on by default (the S-c live SQL post-commit seam) is a later slice.

        `dml_lsn` MUST be `>= 0` (the heap commit's won slot). The crash contract
        (D-A4): the heap is the durable anchor — if this index-shard append never
        lands (a crash after the heap commit), the index entry is re-derivable
        from the heap's committed write-set on recovery (T-CRASH-2)."""
        if not enable_separate_wal:
            raise Error(
                "TableStore.commit_index_shard: the separate-index-shard-WAL"
                " (Option-A S-b) path is DISABLED by default until the"
                " T-INV3-* + T-CRASH-2 correctness falsifiers pass — pass"
                " enable_separate_wal=True to opt in."
            )
        if dml_lsn < Int64(0):
            raise Error(
                "TableStore.commit_index_shard: dml_lsn must be >= 0 (the heap"
                " commit's won DML-LSN L); got " + String(Int(dml_lsn))
                + " — heap-first two-phase: commit the heap FIRST, then stamp"
                " the index-shard append with the won L"
            )
        return self._commit_impl(txn^, dml_lsn)

    def _commit_impl(
        mut self, var txn: Txn, stamp_lsn: Int64
    ) raises -> CommitResult:
        """The shared OCC-check-then-create-CAS commit loop. `stamp_lsn` is the
        Option-A S-b cross-WAL DML-LSN: `TS_STAMP_LSN_UNSET` (-1) for a normal
        single-WAL commit (the chunk encodes v2; the fold stamps rows at the WON
        WAL slot — byte-identical), or an explicit `L >= 0` for a sharded-index
        chunk (the chunk encodes v3 carrying `L`; the fold stamps the index rows
        at `L`, NOT this WAL's won slot)."""
        if not txn.is_open:
            raise Error("TableStore.commit: transaction is not open")
        txn.is_open = False

        # Read-only / empty txn: no append, no LSN (identical to abort on the
        # store). RYOW already collapsed duplicate keys in the buffer.
        if len(txn.write_set) == 0:
            _ = txn^
            return CommitResult.read_only()

        var snapshot = txn.snapshot_lsn
        var body = encode_commit_chunk(snapshot, txn.write_set, stamp_lsn)
        var record_count = Int64(len(txn.write_set))

        # The OCC + create-CAS loop. Bounded retries so a pathological
        # contention storm degrades rather than spins forever (the offline
        # backend is linearizable so this terminates quickly; the bound is a
        # livelock backstop).
        var attempts = 0
        comptime MAX_COMMIT_ATTEMPTS = 256
        while True:
            attempts += 1
            if attempts > MAX_COMMIT_ATTEMPTS:
                raise Error(
                    COMMIT_RETRYABLE_TOKEN
                    + ": TableStore.commit exhausted "
                    + String(MAX_COMMIT_ATTEMPTS)
                    + " OCC/create-CAS attempts under contention (retryable)"
                )

            # --- 1. OCC first-committer-wins check ---
            # Read the AUTHORITATIVE committed tail (NOT the cached _HEAD —
            # correctness path). Scan every chunk committed strictly AFTER
            # our snapshot: (snapshot, auth_head]. Any key there that is also
            # in our write-set => a concurrent committer already wrote a
            # conflicting key with commit_lsn > our snapshot => ABORT 40001.
            #
            # read_head_authoritative() LIST-replays cumulative record_counts
            # over [log_start..top], so it (like _occ_check) can transiently
            # see an in-flight chunk under the LocalFs O_EXCL torn-create window
            # (present-but-zero-length => "truncated i64"). That is a RETRYABLE
            # contention condition, NOT a correctness failure — re-drive the
            # loop (the bytes land within a sub-ms window). We catch it here so
            # the head-read AND the OCC scan share the retryable classification;
            # an OCC_CONFLICT (40001) from _occ_check is re-raised UNCHANGED.
            # LEASE FAST-PATH: when the lease is held + the
            # local head is warm, `lease_auth_head_for_commit` returns the LOCAL
            # monotone head (ZERO GETs — no LIST, no per-chunk replay); otherwise
            # it reads the authoritative LIST head + warms the local head (flag
            # on) or returns it directly (flag off — byte-identical to today). In
            # single-writer steady state the local head IS the true tail, so the
            # OCC over (snapshot, auth_head] below is identical to the LIST path;
            # a sibling that slipped a chunk in is caught by the create-CAS 412.
            var auth_head: ManifestHead
            try:
                auth_head = self.lease_auth_head_for_commit()
                self._occ_check(snapshot, auth_head, txn.write_set)
            except occ_e:
                var em = String(occ_e)
                if is_occ_conflict(em):
                    raise occ_e^  # genuine first-committer-wins abort
                if is_commit_retryable(em) or _is_transient_chunk_read(em):
                    # in-flight chunk (torn-create) — re-drive after a tiny wait.
                    # Invalidate the lease head so the re-drive re-LISTs the
                    # authoritative tail (defends against any livelock on a head
                    # that mis-derived a window chunk; the LIST re-anchors truth).
                    self.lease_note_lost_slot()
                    _tiny_backoff(attempts)
                    continue
                raise occ_e^  # genuine unexpected error

            # --- 2. the commit = ONE create-CAS at EXACTLY auth_head + 1 ---
            # The slot is coupled to the OCC window upper bound: we
            # validated (snapshot, auth_head]; the commit lands at auth_head+1,
            # so there is no un-checked gap below the commit. The (writer,
            # current) lease epochs FENCE a stale displaced writer at the
            # create-CAS (defaults 0,0 = no fence when no lease is held).
            var candidate = auth_head.chunk_seq + Int64(1)
            var base = auth_head.next_offset
            var maybe: Optional[AppendResult]
            try:
                maybe = self._wal.try_append_at_seq(
                    candidate,
                    base,
                    body,
                    record_count,
                    self._writer_lease_epoch,
                    self._current_lease_epoch,
                )
            except cas_e:
                # A `lease_fenced` rejection (a superseded/expired lease epoch):
                # the create-CAS refused before taking a slot. Invalidate the
                # local head + re-raise (NEVER a wrong-offset commit). Any other
                # error propagates unchanged.
                if is_lease_fenced(String(cas_e)):
                    self.lease_note_lost_slot()
                raise cas_e^
            if maybe:
                var res = maybe.take()
                var commit_lsn = res.chunk_seq
                # Bring the index up to the authoritative head we validated
                # against (fold any cross-handle commits in (_folded_seq,
                # auth_head] we had not yet folded), THEN fold our own committed
                # write-set at the won LSN. After this the index is a complete
                # cache of the WAL up to commit_lsn (MUST-FIX #1 — keep the
                # cache high-water mark honest so subsequent reads don't re-fold
                # what we already hold).
                _ = self._fold_wal_range(
                    self._folded_seq + Int64(1), auth_head.chunk_seq
                )
                # Route our own committed write-set into the heap +
                # index memtables. Single-WAL (stamp_lsn == -1): heap + index
                # WriteOps share this ONE write-set / ONE commit_lsn = the won
                # WAL slot (invariant #1). Option-A S-b (stamp_lsn >= 0): this is
                # a sharded-index chunk, so its rows fold at the EXPLICIT heap
                # DML-LSN L, NOT this WAL's won slot — the invariant-#3 per-
                # lineage single-commit-LSN re-scope.
                var fold_lsn = commit_lsn
                if stamp_lsn >= Int64(0):
                    fold_lsn = stamp_lsn
                self._route_apply_write_set(fold_lsn, txn.write_set)
                # `_folded_seq` tracks THIS WAL's folded position (the won slot),
                # NOT the stamp — the high-water mark is a WAL-slot watermark.
                self._folded_seq = commit_lsn
                # LEASE WIN-ADVANCE: the local head now tracks the won tail so
                # the NEXT commit elides the LIST (mirror _LocalHeadCache). The
                # body occupies [base, base+record_count); next base offset is
                # base + record_count (no-op when the flag is off).
                self.lease_note_win(commit_lsn, base + record_count)
                _ = txn^
                # S-a (D-A3): surface the create-CAS slot-race count (1 = won
                # first try; >1 = contended) so the governor / stress harness can
                # observe the per-lineage contention the auto-split reacts to.
                return CommitResult.committed(commit_lsn, res.attempts)

            # --- 412: we lost the slot to a concurrent committer.
            # Do NOT blindly retry the append — loop back to step 1: re-read the
            # AUTHORITATIVE head (now includes the competitor's chunk) + re-run
            # the OCC check. If they touched one of our keys we abort 40001;
            # else we re-append at the new auth_head+1. INVALIDATE the local lease
            # head first: a 412 on a lease-derived attempt means the local head
            # is demonstrably stale (a sibling won the slot we computed), so the
            # re-drive MUST re-LIST the true tail (the create-CAS already
            # protected correctness; this stops us recomputing the stale slot).
            self.lease_note_lost_slot()
            continue

    # =========================================================================
    # POLL-SHAPED (parkable) commit support (table-store P2).
    # =========================================================================
    # The serve thread parks across the create-CAS round-trip so OTHER
    # connections progress while one txn's commit is in flight. Durability is
    # UNCHANGED — the commit still WAITS for the create-CAS to LAND (the won slot
    # is durable) before it acks CommitResult.committed; this is async I/O
    # (reactor-parked), NOT PostgreSQL relaxed-durability "asynchronous commit".
    #
    # THE DECOMPOSITION (v1 design): the synchronous `commit` loop is { read
    # auth-head (LIST) -> OCC-scan (per-chunk GETs) -> create-CAS (one
    # If-None-Match PUT) }. v1 parks the CREATE-CAS only — the single
    # ALWAYS-PRESENT object-store WRITE per commit (one chunk = one commit), and
    # the only step the `AsyncCasStore` ABI can express (a single-object PUT). The
    # head-read is a LIST (`read_head_authoritative` -> `_recover_head_by_list`),
    # NOT a single-object GET, so the ABI cannot park it (and on the warm path it
    # hits the local `_HEAD` cache — no RTT). The OCC-scan is non-empty ONLY under
    # actual contention. Both stay BLOCKING in v1 (see the report).
    #
    # THE COUPLING IS PRESERVED: the synchronous prelude OCC-validates against
    # `read_head_authoritative()` and the parked create-CAS targets EXACTLY
    # `auth_head + 1`; a 412 (lost slot) re-runs the synchronous prelude + re-
    # parks the next create-CAS, so the won slot is ALWAYS `occ_validated_head+1`
    # — IDENTICAL to the sync loop, just with the write step parked.
    #
    # WHY FREE FUNCTIONS (commit_async_*) drive this, not TableStore methods: the
    # parkable create-CAS needs `Store: ... & AsyncCasStore`, but
    # `TableStore[Store: ConditionalWriteStore]` carries the base bound and the
    # async path must stay OPT-IN (InMemory / LocalFs callers keep the blocking
    # `commit()` and do NOT conform to AsyncCasStore). Mojo 1.0.0b1 has no
    # method-level wider-bound clause, so the orchestration lives in free
    # functions parameterized `[Store: ... & AsyncCasStore]` (BELOW the struct)
    # that drive a transient `AsyncManifestAppendOp[Store]` against the base-bound
    # public helpers exposed HERE. The blocking `commit()` is untouched.

    def wal_mut(mut self) -> ref [self._wal] CasManifestStore[Self.Store]:
        """Borrow the WAL by `mut` ref — the async-commit free
        functions drive the poll-shaped create-CAS through it. Concrete origin
        bound to `self._wal`; the WAL handle never crosses a module boundary
        (the free functions live in THIS module)."""
        return self._wal

    def commit_prelude_occ(
        self, snapshot: Int64, write_set: List[WriteOp]
    ) raises -> ManifestHead:
        """The synchronous commit prelude: read the AUTHORITATIVE head (LIST) +
        run the OCC first-committer-wins scan over (snapshot, auth_head]. Returns
        the validated auth_head (the create-CAS lands at auth_head+1). Raises an
        OCC_CONFLICT (40001) on a genuine first-committer-wins loss, or a
        retryable/torn-create error the caller re-drives. Base-bound (no
        AsyncCasStore) — the async driver calls this for the always-blocking
        prelude (the LIST is not poll-shapeable via the ABI; v1 design)."""
        var auth_head = self._wal.read_head_authoritative()
        self._occ_check(snapshot, auth_head, write_set)
        return auth_head^

    def commit_prelude_occ_leased(
        mut self, snapshot: Int64, write_set: List[WriteOp]
    ) raises -> ManifestHead:
        """The lease-aware async commit prelude: identical to
        `commit_prelude_occ` but reads the head through `lease_auth_head_for_commit`
        — eliding the LIST when the lease is held + the local head is warm (else
        the LIST path + warm). With the flag off it is byte-identical to
        `commit_prelude_occ` (no elide, no warm). The async single-commit driver
        calls THIS so its blocking prelude head-read is lease-elided too. A 412 /
        torn-create re-drive must call `lease_note_lost_slot` (the driver does, on
        its re-run path)."""
        # TEMPORARY SCAFFOLDING: the epoch fence is wired only on
        # the SYNC commit() path; this async / group create-CAS is UNFENCED, so a
        # non-zero epoch would be SILENTLY DROPPED here (→ torn offset, no fence).
        # Fail LOUD on the unsafe config until the async/group fence lands; remove
        # this guard then. With the default epochs (0,0) it is dormant.
        if self._writer_lease_epoch != Int64(0) or self._current_lease_epoch != Int64(0):
            raise Error(
                "non-zero writer-lease epochs are not supported on the async/group"
                " commit path yet — the epoch fence is wired only on sync commit();"
                " the async/group create-CAS is unfenced (would silently drop the"
                " fence → torn offset). Use epochs (0,0) until"
                " that lands."
            )
        var auth_head = self.lease_auth_head_for_commit()
        self._occ_check(snapshot, auth_head, write_set)
        return auth_head^

    def read_auth_head(self) raises -> ManifestHead:
        """Read the AUTHORITATIVE manifest head (LIST). The OCC-coupling head:
        the group-commit driver uses it as BOTH the per-member OCC window upper
        bound AND the exact create-CAS slot (auth_head+1). Raises a retryable /
        torn-create error the caller re-drives. Base-bound (the LIST is not
        poll-shapeable via the ABI)."""
        return self._wal.read_head_authoritative()

    # =========================================================================
    # SINGLE-WRITER LEASE LIST-ELISION FAST-PATH — the helpers.
    # =========================================================================
    # The lease state (declared on the struct) + these helpers are the ONE place
    # the LIST-elision lives; the sync `commit()`, the async single-commit
    # prelude, and the group-commit batch path ALL route their
    # authoritative-head read through `lease_auth_head_for_commit` /
    # `read_auth_head_leased`, and their win/lost-slot transitions through
    # `lease_note_win` / `lease_note_lost_slot`. With the flag OFF every helper
    # degrades to the existing LIST path (byte-identical behavior).

    def enable_writer_lease_fastpath(
        mut self,
        writer_lease_epoch: Int64 = Int64(0),
        current_lease_epoch: Int64 = Int64(0),
    ):
        """Turn ON the single-writer lease LIST-elision fast-path. The fast-path is now DEFAULT-ON at
        construction; this method is for re-enabling after a runtime disable, or
        for refreshing the lease epochs. `writer_lease_epoch` /
        `current_lease_epoch` are the broker-style ownership fence the
        create-CAS carries (default 0,0 = no fence, the elision is then a pure
        local-head optimization gated only by the create-CAS slot arbiter).

        Enabling does NOT itself read the store — the local head stays COLD
        (`_lease_head_present = False`) until the first commit lists + warms it
        (so the first commit after enable is identical to today; the rest
        elide). Idempotent re-enable just refreshes the epochs + leaves any warm
        head in place."""
        self._lease_fastpath_enabled = True
        self._writer_lease_epoch = writer_lease_epoch
        self._current_lease_epoch = current_lease_epoch

    def disable_writer_lease_fastpath(mut self):
        """Turn OFF the lease fast-path + invalidate any warm local head (every
        subsequent commit reads the authoritative LIST head). For tests /
        defensive teardown; the normal path leaves it on once enabled."""
        self._lease_fastpath_enabled = False
        self._lease_head_present = False
        self._lease_head_seq = Int64(-1)
        self._lease_head_next_offset = Int64(0)

    @always_inline
    def lease_fastpath_enabled(self) -> Bool:
        """True iff the lease fast-path is ON (test/observability accessor)."""
        return self._lease_fastpath_enabled

    @always_inline
    def lease_head_warm(self) -> Bool:
        """True iff the local lease head is currently warm + trusted (i.e. the
        NEXT commit will elide the LIST). False when the flag is off or the head
        is cold/invalidated. Test/observability accessor."""
        return self._lease_fastpath_enabled and self._lease_head_present

    @always_inline
    def lease_writer_epoch(self) -> Int64:
        """The owner's per-lineage writer lease generation (0 = no lease). The
        commit paths pass this into `try_append_at_seq` so a stale displaced
        writer is FENCED at the create-CAS."""
        return self._writer_lease_epoch

    @always_inline
    def lease_current_epoch(self) -> Int64:
        """The live lease generation the create-CAS fences against (0 = no
        lease)."""
        return self._current_lease_epoch

    def _note_observed_auth(mut self, seq: Int64):
        """OCC-STARVATION FIX — record an AUTHORITATIVE tail this handle read, so
        the NEXT `begin()` cannot re-pin BELOW it (see `begin()` for the full
        starvation model). MONOTONE-forward only: the watermark is a lower bound
        on the visible tail, so it must never regress (a `read_head_fresh`-style
        cache going cold, or a lease head behind an already-observed LIST tail,
        must not drag the snapshot backwards). Callers pass any head they got
        from `read_head_authoritative()` (a true committed tail) or the warm
        lease head (this handle's own last WON slot) — both are heads this handle
        genuinely observed, which is exactly the safety precondition."""
        if seq > self._observed_auth_seq:
            self._observed_auth_seq = seq

    def lease_auth_head_for_commit(mut self) raises -> ManifestHead:
        """The OCC-window-upper-bound + create-CAS-slot head for a commit
        attempt, with the LIST elided when the lease is held.

        * Lease HELD (flag on AND local head warm): return the LOCAL monotone
          head — ZERO GETs (no LIST, no per-chunk record-count replay). The
          create-CAS at `local_head + 1` is the sole arbiter; a stale local head
          can only LOSE the slot (-> `lease_note_lost_slot` re-LISTs).
        * Lease ABSENT / cold / flag off: read `read_head_authoritative()` (the
          existing LIST path) and, when the flag is on, WARM the local head from
          it so the NEXT commit elides. With the flag off this is byte-identical
          to calling `read_head_authoritative()` directly.

        Raises a retryable / torn-create error the caller re-drives (same as the
        LIST path)."""
        if self._lease_fastpath_enabled and self._lease_head_present:
            # WARM lease: the local head is authoritative for this writer's next
            # commit (single-writer steady state). 0 GETs. `etag` is unknown on
            # the cached head — `try_append_at_seq` reads the `_HEAD` etag itself
            # for its best-effort monotone advance, so an empty etag here is fine.
            self._note_observed_auth(self._lease_head_seq)
            return ManifestHead(
                self._lease_head_seq,
                self._lease_head_next_offset,
                String(""),
            )
        var auth_head = self._wal.read_head_authoritative()
        # OCC-STARVATION FIX: remember this authoritative tail so a 40001 abort
        # does not send the retry's `begin()` back to the lagging durable `_HEAD`.
        self._note_observed_auth(auth_head.chunk_seq)
        if self._lease_fastpath_enabled:
            # COLD-START warm (or post-412 re-warm): trust this LIST result as
            # the local head for the NEXT commit's elision.
            self._lease_head_present = True
            self._lease_head_seq = auth_head.chunk_seq
            self._lease_head_next_offset = auth_head.next_offset
        return auth_head^

    def read_auth_head_leased(mut self) raises -> ManifestHead:
        """The lease-aware counterpart of `read_auth_head` — the
        group-commit batch path (`_group_begin_attempt`) calls THIS so the
        per-batch authoritative head read is elided when the lease is held. With
        the flag off it is byte-identical to `read_auth_head()` (no warm, no
        elide). Identical body to `lease_auth_head_for_commit`; the second name
        documents the group-commit call-site intent (read the OCC-coupling
        head, lease-elided)."""
        # TEMPORARY SCAFFOLDING: the epoch fence is wired only on
        # the SYNC commit() path; this group-commit create-CAS is UNFENCED, so a
        # non-zero epoch would be SILENTLY DROPPED here (→ torn offset, no fence).
        # Fail LOUD on the unsafe config until the async/group fence lands; remove
        # this guard then. With the default epochs (0,0) it is dormant.
        if self._writer_lease_epoch != Int64(0) or self._current_lease_epoch != Int64(0):
            raise Error(
                "non-zero writer-lease epochs are not supported on the async/group"
                " commit path yet — the epoch fence is wired only on sync commit();"
                " the async/group create-CAS is unfenced (would silently drop the"
                " fence → torn offset). Use epochs (0,0) until"
                " that lands."
            )
        return self.lease_auth_head_for_commit()

    def lease_note_win(mut self, won_seq: Int64, won_next_offset: Int64):
        """Advance the local lease head after a committed create-CAS WIN at slot
        `won_seq` whose body ends at base offset `won_next_offset` (= base +
        record_count). Mirrors `_LocalHeadCache`'s win-advance: the owner now
        knows the true tail is `(won_seq, won_next_offset)`, so the NEXT commit
        elides the LIST. No-op when the flag is off."""
        if not self._lease_fastpath_enabled:
            return
        self._lease_head_present = True
        self._lease_head_seq = won_seq
        self._lease_head_next_offset = won_next_offset

    def lease_note_lost_slot(mut self):
        """Invalidate the local lease head after a 412 (a sibling won the slot we
        computed) OR a `lease_fenced` rejection. The next commit attempt falls
        back to `read_head_authoritative()` (the LIST) + full OCC against the
        now-visible competitor, then re-warms. No-op when the flag is off. This
        is the `_LocalHeadCache.cold()` transition (cas_manifest.mojo:1574)."""
        self._lease_head_present = False

    # NOTE (share-the-codec refactor): the per-member BOOLEAN OCC
    # that group-commit needs now lives as the SHARED `_occ_member_conflicts_wal`
    # free function in `group_commit.mojo` (which `encode_group_batch` — the ONE
    # domain-logic fold both the codec and the live `_group_prelude` call —
    # invokes over the borrowed WAL ref). The former `occ_member_has_conflict`
    # wrapper here was a second copy of that scan routed through `_occ_check`; it
    # was removed so there is exactly one per-member OCC implementation (no
    # parallel API to drift). The single-txn `commit()` keeps its own raising
    # `_occ_check` (it aborts the WHOLE txn on a conflict, vs the group driver
    # routing the one conflicting member to a 40001 loser).

    def finalize_commit_win(
        mut self,
        commit_lsn: Int64,
        auth_head_seq: Int64,
        write_set: List[WriteOp],
    ) raises -> None:
        """Finalize a won commit on the LIVE store (the index memtable is
        server-local): bring the index up to the authoritative head we validated
        against, THEN fold our own committed write-set at the won LSN (MUST-FIX
        #1). Base-bound; IDENTICAL to the sync `commit` win-path tail."""
        _ = self._fold_wal_range(self._folded_seq + Int64(1), auth_head_seq)
        self._route_apply_write_set(commit_lsn, write_set)
        self._folded_seq = commit_lsn

    def _occ_check(
        self,
        snapshot: Int64,
        auth_head: ManifestHead,
        write_set: List[WriteOp],
    ) raises:
        """Scan chunks (snapshot, auth_head] for any key intersecting our
        write-set. Raise OCC_CONFLICT (40001) on the first overlap.

        For the correctness slice this replays each chunk's KEYS — O(chunks-
        since-snapshot) per commit. A faster build would key it on a side
        `key -> last-commit-LSN` map so the check is O(write-set); the
        correctness verdict is identical either way."""
        var seq = snapshot + Int64(1)
        while seq <= auth_head.chunk_seq:
            # The authoritative head can include a chunk whose create-CAS WON but
            # whose bytes are still landing (the LocalFs O_EXCL torn-create
            # window under cross-thread contention: present-but-zero-length, so
            # `decode_commit_chunk_keys` raises a truncated/not-found error).
            # That is a TRANSIENT contention condition, NOT a conflict and NOT a
            # corruption — re-raise it as RETRYABLE so the round re-drives (the
            # competitor's bytes land within a sub-ms window; the re-read sees a
            # complete chunk). The create-CAS slot is still the sole arbiter.
            var other_keys: List[List[UInt8]]
            try:
                var other_body = self._wal.read_chunk(seq)
                other_keys = decode_commit_chunk_keys(other_body)
            except e:
                raise Error(
                    COMMIT_RETRYABLE_TOKEN
                    + ": OCC scan saw an in-flight chunk at seq "
                    + String(seq)
                    + " (torn-create window — retry): "
                    + String(e)
                )
            for oi in range(len(other_keys)):
                ref ok = other_keys[oi]
                for wi in range(len(write_set)):
                    if bytes_eq(write_set[wi].key, ok):
                        raise Error(
                            OCC_CONFLICT_TOKEN
                            + ": write-write conflict on a key committed at"
                            " chunk_seq "
                            + String(seq)
                            + " > snapshot "
                            + String(snapshot)
                            + " (first-committer-wins; retry the txn)"
                        )
            seq += Int64(1)

    # ---- reads (snapshot-authoritative + RYOW overlay) ----
    #
    # MUST-FIX #1 (BLOCKER — shared-store read correctness). The per-handle
    # `_index` is a CACHE of the WAL up to `_folded_seq`. In the deployed
    # shape (MANY stateless workers, each a TableStore over ONE shared prefix)
    # a handle's index is a PARTIAL view (its own open()-replay + its own
    # commits). A correct snapshot read MUST observe ALL handles' commits
    # visible at its snapshot. So before serving get()/scan() at snapshot S we
    # REFRESH the index by folding the WAL delta (_folded_seq, S] — extending
    # the cache up to the snapshot. The newest committed version <= S across
    # ALL handles (incl. tombstones -> None) is then a pure function of the
    # refreshed chain. RYOW overlays on top. The single-handle fast path
    # is preserved: when the index is already current at/above S the refresh is
    # a no-op (no WAL read). SI stability: a reader pinned at S folds only up to
    # S, so chunks committed above S are never folded by this read and the <= S
    # view is stable for the txn's lifetime.

    def get(mut self, txn: Txn, key: List[UInt8]) raises -> Optional[List[UInt8]]:
        """RYOW buffer first; else the version visible at
        `txn.snapshot_lsn`, snapshot-authoritative across ALL handles on a
        shared store. None == key invisible at this snapshot (absent or
        tombstoned)."""
        # RYOW: a buffered PUT returns its row; a buffered TOMBSTONE returns
        # invisible — overriding the snapshot view.
        var buffered = txn.buffered(key)
        if buffered:
            ref w = buffered.value()
            if w.op == TS_OP_TOMBSTONE:
                return Optional[List[UInt8]](None)
            return Optional(w.row.copy())
        # Buffer miss: bring the index up to the snapshot (fold cross-handle
        # commits), then read the newest committed version <= snapshot. The
        # index now reflects every handle's commit visible at this snapshot —
        # no stale "local hit wins" (the SI violation MUST-FIX #1 closes).
        self._refresh_index_to(txn.snapshot_lsn)
        return self._index.visible_at(key, txn.snapshot_lsn)

    def scan(
        mut self, txn: Txn, lo: List[UInt8], hi: List[UInt8]
    ) raises -> List[KeyValue]:
        """Range scan `[lo, hi)` at `txn.snapshot_lsn`, RYOW-overlaid, in
        ascending key order. Tombstoned / invisible keys suppressed.
        The base view comes from the index AFTER folding the WAL up to the
        snapshot (so cross-handle keys are included — MUST-FIX #1, no
        phantom-absence); the RYOW buffer overlays the txn's own buffered
        writes on top."""
        self._refresh_index_to(txn.snapshot_lsn)
        var base = self._index.scan_visible(lo, hi, txn.snapshot_lsn)
        return self._overlay_ryow(txn, lo, hi, False, base^)

    def scan_from(
        mut self, txn: Txn, lo: List[UInt8]
    ) raises -> List[KeyValue]:
        """Range scan `[lo, +inf)` at `txn.snapshot_lsn`, RYOW-overlaid, in
        ascending key order — the UNBOUNDED-UPPER scan mode. Identical to `scan`
        except there is NO upper bound: it walks to the end of the sorted key
        space. The SQL face uses this for a full scan and for open-ended `>=`/`>`
        ranges, so it NEVER has to synthesize a fixed-length max byte-string
        (which silently drops large/long TEXT keys — adversarial-review HIGH-1).
        +inf semantics live in the storage layer, where bound correctness
        belongs."""
        self._refresh_index_to(txn.snapshot_lsn)
        var base = self._index.scan_visible_from(lo, txn.snapshot_lsn)
        # `hi` is ignored when hi_unbounded=True; pass an empty placeholder.
        return self._overlay_ryow(txn, lo, List[UInt8](), True, base^)

    # ---- SECONDARY INDEX reads ----
    #
    # An index scan resolves visibility ON THE INDEX'S OWN chain (the EXISTING
    # `KeyIndex.scan_visible`, already tombstone-suppressing + snapshot-correct):
    # the index ALONE decides which `(index_key, pk)` pairs are live at S, with
    # NO heap probe for the existence question (the inline-versioned model).
    # The cross-handle refresh (MUST-FIX #1) folds the index memtable
    # to the snapshot first, exactly like the heap scan — a stale index memtable
    # on a multi-writer prefix is a silent wrong-result hole.
    #
    # NOTE: the index read path does NOT consult the txn's RYOW buffer for index
    # keys. The SQL executor's index lookups run at the txn snapshot over the
    # COMMITTED index memtable; in slice 1 every indexed read is a fresh-snapshot
    # autocommit SELECT, so there is no same-txn uncommitted index entry to
    # overlay. (Same-txn RYOW over the index is a slice-3+ concern.)

    def index_scan_visible(
        mut self,
        txn: Txn,
        index_lineage_ord: Int32,
        lo: List[UInt8],
        hi: List[UInt8],
    ) raises -> List[KeyValue]:
        """Range scan `[lo, hi)` over index lineage `index_lineage_ord`'s memtable
        at `txn.snapshot_lsn`, ascending composite-key order == index order. `lo`
        / `hi` are the FULL lineage-prefixed bounds (the SQL layer builds them via
        `idx_prefix ++ encode_index_key(...)`). Returns live `(composite_key,
        covered_value)` pairs (covered_value empty in the non-covering slice).
        Tombstoned / superseded entries suppressed by the index's own chain."""
        self._refresh_index_to(txn.snapshot_lsn)
        var slot = self._idx_slot_for_ord(index_lineage_ord)
        if slot < 0:
            raise Error(
                "TableStore.index_scan_visible: lineage ordinal "
                + String(Int(index_lineage_ord))
                + " is not a registered index (register_index first)"
            )
        return self._idx_indexes[slot][].scan_visible(
            lo, hi, txn.snapshot_lsn
        )

    def index_hot_version_at(
        mut self, txn: Txn, index_lineage_ord: Int32, key: List[UInt8]
    ) raises -> VisibleVersion:
        """The HOT side of the SI-6c dual-tier INDEX read-merge: the winning HOT
        version of a composite index `key` in lineage `index_lineage_ord`'s
        memtable at the txn's snapshot, with its `commit_lsn` + tombstone flag
        preserved (so the adapter's cold-split merge can LWW it). Folds the
        cross-handle WAL delta up to the snapshot first (the index memtable
        participates in the same refresh as the heap). A key absent from the
        index memtable (or an unregistered lineage) returns
        `VisibleVersion.absent()` — the merge then defers to the cold tier.

        Unlike the heap path there is NO RYOW overlay for index keys (the index
        read path does not consult the txn's buffer — slice-3+ concern, matching
        `index_scan_visible`)."""
        self._refresh_index_to(txn.snapshot_lsn)
        var slot = self._idx_slot_for_ord(index_lineage_ord)
        if slot < 0:
            return VisibleVersion.absent()
        return self._idx_indexes[slot][].visible_version_at(
            key, txn.snapshot_lsn
        )

    def heap_visible_at(
        mut self, txn: Txn, key: List[UInt8]
    ) raises -> Optional[List[UInt8]]:
        """The heap-deferred non-covered read: the heap version
        visible for `key` at the txn's snapshot. RYOW-overlaid (a same-txn
        buffered heap write wins). SLICE-1 PRECONDITION: this is the
        HOT-ONLY `_index.visible_at` after the cross-handle refresh — correct in
        slice 1 ONLY because NOTHING has columnarized (every heap version is
        still in the hot memtable). The general post-columnarize guarantee needs
        the dual-tier read-merge (SI-6c).

        SI-6c NOTE: the dual-tier (hot + cold split) merge that CLOSES the
        INDEX-hot-vs-HEAP-cold hole lives ONE TIER UP, in
        the columnar adapter's `dual_tier_read.heap_visible_at_dual_tier`, NOT
        here. That is a deliberate ENCAPSULATION decision: the cold tier is
        Parquet + the `ColumnarCatalog` lineage, both owned by the adapter
        package; folding the cold-split substrate into the reuse-safe
        `komira_table_store` LEAF would force the leaf to gain a
        Parquet/columnar dependency (and create an `komira_table_store` <->
        columnar-adapter cycle — the columnar adapter already depends
        on this leaf). The leaf instead exposes `heap_hot_version_at` (the HOT
        side of the merge, with the winning version's `commit_lsn` +
        tombstone flag preserved); the adapter composes it with the cold-split
        re-fold + the LWW-by-`commit_lsn` merge. This `heap_visible_at` remains
        the correct hot-only read when NO cold tier exists for the table."""
        return self.get(txn, key)

    def heap_hot_version_at(
        mut self, txn: Txn, key: List[UInt8]
    ) raises -> VisibleVersion:
        """The HOT side of the SI-6c dual-tier heap read-merge: the winning HOT
        version of `key` at the txn's snapshot, with its `commit_lsn` +
        tombstone flag preserved (NOT collapsed to None) so the adapter's
        cold-split merge can compare hot-vs-cold by `commit_lsn` and let a hot
        tombstone SUPPRESS a lower cold value (LWW with
        tombstone-wins).

        Folds the cross-handle WAL delta up to the snapshot first (MUST-FIX #1,
        exactly like `get`), then probes the hot memtable for the winning
        version. RYOW: a same-txn buffered heap write wins (a buffered PUT =>
        a found non-tombstone version at +inf commit_lsn so it beats any
        committed/cold version; a buffered TOMBSTONE => a found tombstone at
        +inf so it suppresses every lower version). The +inf stamp is the
        XMAX-style sentinel: a buffered write is the reader's OWN uncommitted
        write and must dominate every committed/cold version it can see."""
        # RYOW: a same-txn buffered write dominates (stamped at +inf so it beats
        # any committed/cold version's commit_lsn in the merge).
        var buffered = txn.buffered(key)
        if buffered:
            ref w = buffered.value()
            var is_tomb = w.op == TS_OP_TOMBSTONE
            var row = List[UInt8]()
            if not is_tomb:
                row = w.row.copy()
            return VisibleVersion(
                True, Int64(0x7FFFFFFFFFFFFFFF), is_tomb, row^
            )
        # Buffer miss: refresh the hot index to the snapshot, then return the
        # winning hot version (commit_lsn + tombstone flag preserved).
        self._refresh_index_to(txn.snapshot_lsn)
        return self._index.visible_version_at(key, txn.snapshot_lsn)

    # ---- public: cheap freshness refresh for a long-lived CACHED handle -------

    def refresh_to_durable_head(mut self) raises -> Int64:
        """Refresh this handle's folded index to the DURABLE `_HEAD` pointer
        (the per-request cache work: the per-worker cached
        handle). Reads the durable `_HEAD` OBJECT (`read_durable_head()`, ONE GET,
        O(1) — NOT the O(chunks) authoritative LIST) as the freshness ORACLE, and
        delta-folds ONLY the NEW chunks `(_folded_seq, durable_head]`. Returns the
        new `_folded_seq`.

        WHY THE DURABLE `_HEAD` (preserves W0.7, O(1) oracle): a long-lived cached
        handle that does NO write keeps a STALE LOCAL `_head_cache`; a plain
        `begin()` off that local cache would pin a snapshot BELOW commits OTHER
        handles made (the stale-low torn read the W0.7 per-request-fresh-open
        avoided). The DURABLE `_HEAD` object is what EVERY committer advances —
        exactly the W0.7 freshness contract ("see commits that advanced `_HEAD`").
        Reading it (one GET) BEFORE `begin()` makes the cached handle see every
        chunk up to the durable `_HEAD`, reusing the warm connection + the
        already-folded snapshot (only the delta is read). This is NOT weaker than
        W0.7 — it IS W0.7, made O(1): the fresh-per-request open also pinned its
        snapshot off the durable `_HEAD` (`begin()` -> `read_head()`), it just
        paid the whole fold to get there.

        COST: 1 `_HEAD` GET + `delta` chunk GETs. On a QUIET store the delta is 0
        -> 1 GET total (the cache-hit fast path). Under a burst the delta is the
        commits since the last refresh — bounded by request rate, NOT store age.
        vs the O(chunks) authoritative LIST (`read_head_authoritative` LISTs AND
        re-GETs every chunk to replay record_counts) the prior approach used."""
        var dh = self._wal.read_durable_head()
        if dh.chunk_seq <= self._folded_seq:
            return self._folded_seq  # already current to the durable head.
        var folded_to = self._fold_wal_range(
            self._folded_seq + Int64(1), dh.chunk_seq
        )
        if folded_to > self._folded_seq:
            self._folded_seq = folded_to
        return self._folded_seq

    @always_inline
    def folded_seq(self) -> Int64:
        """The highest WAL chunk_seq folded into this handle's index (the
        cached-snapshot high-water mark). Used by the per-worker cache to report
        the snapshot freshness; -1 = nothing folded yet."""
        return self._folded_seq

    # ---- internal: snapshot-authoritative index refresh (cross-handle reads) -

    def _refresh_index_to(mut self, snapshot: Int64) raises:
        """Extend the in-RAM index CACHE so it covers every WAL chunk committed
        `<= snapshot` (MUST-FIX #1). Folds only the delta `(_folded_seq,
        snapshot]` — a no-op when the index is already current at/above the
        snapshot (the single-handle fast path: this handle's own commits keep
        `_folded_seq` at the head). A reader pinned at `snapshot` folds ONLY up
        to `snapshot` (never to the live head), so versions committed above the
        snapshot are NOT folded by this read — the `<= snapshot` view stays
        stable for the txn's lifetime (SI). Reading at a LOWER snapshot after a
        higher one is still correct: `visible_at` ignores chain entries with
        `commit_lsn > snapshot`, so a `_folded_seq` already past `snapshot` is
        harmless and we do not roll it back."""
        if snapshot <= self._folded_seq:
            return  # cache already current to the snapshot — no WAL read.
        var folded_to = self._fold_wal_range(
            self._folded_seq + Int64(1), snapshot
        )
        # Advance the high-water mark to the highest seq we ACTUALLY folded
        # (which may be < snapshot if a slot at/below the snapshot does not yet
        # exist — a stale-low or time-travel-above-tail snapshot). Never claim
        # we covered a slot we did not read, or a later read at a higher
        # snapshot would skip it.
        if folded_to > self._folded_seq:
            self._folded_seq = folded_to

    def _fold_wal_range(mut self, lo_seq: Int64, hi_seq: Int64) raises -> Int64:
        """Fold committed WAL chunks `[lo_seq, hi_seq]` (inclusive) into the
        index, ascending (commit-LSN order; the slot sequence is monotone
        gapless so each key's chain stays ascending). Returns the highest seq
        ACTUALLY folded (or `lo_seq - 1` if none / `lo_seq > hi_seq`). Bounded
        by the snapshot / head the caller passes; never reads above it. A slot
        at/below the bound that does not yet exist (e.g. a snapshot pinned from
        a stale-low cached head, or a time-travel snapshot above the live tail)
        ends the fold — a gapless log has no holes below a committed seq, so
        nothing above it exists either."""
        var start = lo_seq
        if start < Int64(0):
            start = Int64(0)
        var seq = start
        while seq <= hi_seq:
            var body: List[UInt8]
            try:
                body = self._wal.read_chunk(seq)
            except e:
                # No committed chunk at this slot at/below the bound — stop.
                _ = e
                break
            var chunk = decode_commit_chunk(body)
            # The cross-handle fold routes too, so an index
            # memtable participates in the MUST-FIX #1 cross-handle refresh (a
            # stale index scan on a multi-writer prefix would be a silent wrong-
            # result hole). One WAL pass, one shared `_folded_seq` for all
            # keyspaces (lockstep refresh).
            # Option-A S-b: a sharded-index chunk folds at its explicit stamp_lsn
            # (the heap DML-LSN L), else the WAL seq (byte-identical single-WAL).
            self._route_apply_write_set(
                _fold_lsn_for_chunk(seq, chunk), chunk.write_set
            )
            seq += Int64(1)
        return seq - Int64(1)

    def _overlay_ryow(
        self,
        txn: Txn,
        lo: List[UInt8],
        hi: List[UInt8],
        hi_unbounded: Bool,
        var base: List[KeyValue],
    ) raises -> List[KeyValue]:
        """Overlay the txn's buffered write-set on a base scan result: a
        buffered PUT replaces / inserts the key; a buffered TOMBSTONE removes
        it. Keeps ascending key order. Bounded to `[lo, hi)` when
        `hi_unbounded` is False, else `[lo, +inf)` (the `hi` arg is ignored)."""
        if len(txn.write_set) == 0:
            return base^
        from komira_table_store.table_store_codec import bytes_cmp

        var out = List[KeyValue]()
        for i in range(len(base)):
            ref kv = base[i]
            var buffered = txn.buffered(kv.key)
            if buffered:
                # The buffer overrides — handle it in the merge pass below.
                continue
            out.append(KeyValue(kv.key.copy(), kv.row.copy()))
        # Insert buffered PUTs that fall in range (skip tombstones).
        for wi in range(len(txn.write_set)):
            ref w = txn.write_set[wi]
            if w.op == TS_OP_TOMBSTONE:
                continue
            if bytes_cmp(w.key, lo) < 0:
                continue
            if not hi_unbounded and bytes_cmp(w.key, hi) >= 0:
                continue
            out.append(KeyValue(w.key.copy(), w.row.copy()))
        # Re-sort ascending by key (the overlay may have inserted out of order).
        _sort_kv(out)
        return out^

    # ---- WAL introspection (the soak's linearizability assertions) ----

    def wal_head_seq(self) raises -> Int64:
        """The authoritative highest-committed chunk_seq (-1 if empty). The
        soak reads this to assert the create-CAS slot sequence is gapless."""
        return self._wal.read_head_authoritative().chunk_seq

    def wal_chunk_keys(self, seq: Int64) raises -> List[List[UInt8]]:
        """The keys touched by committed chunk `seq` (for the soak's per-slot
        assertions). Raises if the slot was never committed."""
        return decode_commit_chunk_keys(self._wal.read_chunk(seq))

    def wal_chunk_write_set(self, seq: Int64) raises -> List[WriteOp]:
        """The FULL write-set (op + key + row) of committed chunk `seq` — for
        the soak's HOT-key version-chain audit (MUST-FIX #3): the auditor walks
        every WAL chunk, extracts each version of a hot key, and asserts the
        commit-LSN chain is strictly increasing with no two chunks carrying the
        same value (a genuine lost update fails that). Raises if the slot was
        never committed. Keeps WAL access encapsulated in the store (the test
        never touches the raw backend / chunk codec directly)."""
        var chunk = decode_commit_chunk(self._wal.read_chunk(seq))
        return chunk.write_set.copy()

    # ---- durable catalog sidecar (A1 — catalog durability) ----
    #
    # The TABLE SCHEMA must survive a container restart (Phase-1a was an
    # in-memory catalog only — the A1 hard blocker). The schema lives in an
    # OPAQUE `_CATALOG` sidecar object under the SAME prefix as the WAL (a
    # single mutable, etag-CAS-versioned blob — same shape as `_HEAD` /
    # `_LOG_START`). The STORAGE layer round-trips the blob VERBATIM and never
    # interprets it; the SQL layer (its catalog codec) owns the
    # encoding (TableSchema/ColumnDef <-> bytes) — so the reuse-safe table store
    # leaf gains NO knowledge of SQL types. These thin accessors expose the
    # sidecar through the store the SQL layer already holds, keeping the raw
    # CAS confined to the CasManifestStore (no store handle escapes the table store).

    def read_catalog_blob(self) raises -> CatalogSidecar:
        """Read the persisted catalog sidecar (opaque blob + etag + present
        flag). `CatalogSidecar.absent()` when never written. The SQL layer
        recovers its `TableCatalog` from `blob` at `open()` time, and threads
        `etag` back into `cas_catalog_blob` for the next durable mutation."""
        return self._wal.read_catalog_sidecar()

    def cas_catalog_blob(
        self, blob: List[UInt8], expected_etag: String
    ) raises -> CatalogSidecar:
        """Persist the catalog sidecar to `blob` via an `If-Match` CAS on
        `expected_etag` (empty etag => first-ever If-None-Match create).
        Returns the new `CatalogSidecar` (with the post-write etag). Raises
        `precondition` (412) on a stale etag — a concurrent catalog mutation
        won the slot; the SQL layer re-reads + re-applies (catalog mutations
        are rare DDL, so the retry is cheap). The blob is OPAQUE here."""
        return self._wal.cas_catalog_sidecar(blob, expected_etag)


@always_inline
def _sort_kv(mut xs: List[KeyValue]):
    """Insertion sort `xs` ascending by key (byte-lexicographic). Small result
    sets in the correctness slice."""
    from komira_table_store.table_store_codec import bytes_cmp

    var n = len(xs)
    var i = 1
    while i < n:
        var key = xs[i].copy()
        var j = i - 1
        # bubble xs[i] left into place (KeyValue is Copyable)
        while j >= 0 and bytes_cmp(xs[j].key, key.key) > 0:
            xs[j + 1] = xs[j].copy()
            j -= 1
        xs[j + 1] = key^
        i += 1


# =============================================================================
# Poll-shaped commit DRIVER (table-store P2) — free functions
# parameterized `[Store: ConditionalWriteStore & AsyncCasStore]`.
# =============================================================================
# These orchestrate the parkable commit over a `TableStore[Store]` + an
# `AsyncCommitOp`. They carry the wider `AsyncCasStore` bound (the parkable
# create-CAS) that the base-bound `TableStore[Store: ConditionalWriteStore]`
# cannot express per-method in Mojo 1.0.0b1. The blocking `TableStore.commit()`
# is untouched — InMemory / LocalFs callers (no AsyncCasStore) keep using it; a
# reactor-driven caller opts into THIS path for AsyncCasStore backends.
#
# THE stale-reuse CONTRACT: the in-flight create-CAS op (the dialed stream + the
# HttpClient pool's heap buffers) lives INSIDE `store.wal_mut()._store` (the
# conformer's OWN concrete-origin handle) across the park — the `AsyncCasStore`
# surface is start/poll/take of TYPED VALUES only. The carried-across-park state
# is on the caller's `AsyncCommitOp` (a concrete owned value, reuse-safe on a
# caller's `Slab` by the concrete-origin Slab access) — plain owned/POD fields,
# NO byte-slab + wildcard cast. The transient `AsyncManifestAppendOp[Store]` each
# poll reconstructs holds only POD + borrows the WAL per call. ZERO UnsafePointer
# / wildcard origin / unsafe_from_address; the reactor is a per-call `mut` borrow.


def commit_async_start[
    Store: ConditionalWriteStore & AsyncCasStore,
    S: WakerSink & Movable & Deinitable,
](
    mut store: TableStore[Store], mut op: AsyncCommitOp, mut reactor: Reactor[S]
) raises -> Int64:
    """Begin a poll-shaped commit of `op` (the consumed txn's snapshot +
    write-set). Runs the synchronous prelude (head-read-auth + OCC) then kicks
    off the parkable create-CAS at auth_head+1. Returns the BIASED op_id to park
    on (0 == finished in one synchronous burst — the caller checks
    `op.is_done()`/`op.is_error()` then `op.take_result()`). A read-only / empty
    txn finishes immediately (DONE, did_append=False)."""
    if op.write_set_len() == 0:
        op._finish_read_only()
        return Int64(0)
    return _commit_async_begin_attempt[Store, S](store, op, reactor)


def commit_async_poll[
    Store: ConditionalWriteStore & AsyncCasStore,
    S: WakerSink & Movable & Deinitable,
](
    mut store: TableStore[Store], mut op: AsyncCommitOp, mut reactor: Reactor[S]
) raises -> Int64:
    """Resume a parked commit after its op_id completed. Advances the in-flight
    create-CAS one non-blocking step; on the WIN it finalizes (index fold +
    route) + DONEs; on a 412 it re-runs the synchronous prelude + re-parks. On a
    transport error it errors the op. Returns the next op_id to park on, or 0
    when finished (`op.is_done()`/`op.is_error()`)."""
    # IDEMPOTENT on terminal ops (MEDIUM-1): a stray completion re-driving an
    # already-DONE/ERR op must NOT overwrite the committed result with an ERR (a
    # serve-loop integration hazard — a spurious bucket-2 wakeup on a finished
    # op). Return 0 (finished) without touching the terminal outcome.
    if op.is_done() or op.is_error():
        return Int64(0)
    if not op._append_inflight:
        op._set_error(
            String("commit_async_poll: no create-CAS in flight (logic error)")
        )
        return Int64(0)
    # Reconstruct the transient append op from the carried POD mirror; the actual
    # in-flight transport state lives in the WAL's conformer (persists across the
    # park), so the reconstructed op faithfully resumes it.
    var append = AsyncManifestAppendOp[Store].resume_inflight(
        op._candidate, op._base, Int64(op.write_set_len())
    )
    var prog = append.poll[S](store.wal_mut(), reactor)
    if prog.is_error():
        op._append_inflight = False
        var em = prog.err_text()
        # A LOST-SLOT 412 surfaced as an ERR from this conformer's poll (the
        # in-mem SLOW conformer runs the sync put on the final tick + catches the
        # 412 raise into ERR). Treat it EXACTLY like the `take`-side 412 (None):
        # re-run the synchronous prelude (re-read auth head + re-OCC) + re-park
        # the next create-CAS (IDENTICAL to the sync 412 loop). A
        # genuine OCC 40001 raised inside the prelude is then re-classified there.
        if _is_lost_slot_412(em):
            # LEASE: a 412 means the local lease head is stale —
            # invalidate so the re-run re-LISTs the true tail.
            store.lease_note_lost_slot()
            return _commit_async_begin_attempt[Store, S](store, op, reactor)
        op._set_error(String("commit_async: create-CAS poll: ") + em)
        return Int64(0)
    if prog.is_pending():
        return prog.op_id
    return _commit_async_after_cas_ready[Store, S](store, op, append^, reactor)


def _commit_async_begin_attempt[
    Store: ConditionalWriteStore & AsyncCasStore,
    S: WakerSink & Movable & Deinitable,
](
    mut store: TableStore[Store], mut op: AsyncCommitOp, mut reactor: Reactor[S]
) raises -> Int64:
    """One commit attempt: synchronous head-read-auth + OCC, then kick off the
    parkable create-CAS at auth_head+1. Returns the op_id to park on (or 0 if the
    create-CAS completed in this same synchronous burst — then the win/loss path
    runs). A genuine OCC 40001 / unexpected error marks the op errored."""
    op._attempt += 1
    if op._attempt > _MAX_ASYNC_COMMIT_ATTEMPTS:
        op._set_error(
            COMMIT_RETRYABLE_TOKEN
            + ": commit_async exhausted "
            + String(_MAX_ASYNC_COMMIT_ATTEMPTS)
            + " OCC/create-CAS attempts under contention (retryable)"
        )
        return Int64(0)
    # --- synchronous prelude: OCC first-committer-wins. IDENTICAL
    # classification to the sync `commit`: a genuine OCC_CONFLICT (40001) errors
    # the op; a torn-create / retryable contention re-drives after a tiny backoff.
    # LEASE: `commit_prelude_occ_leased` elides the LIST head-read
    # when the lease is held + the local head is warm (else the LIST path + warm;
    # byte-identical to `commit_prelude_occ` when the flag is off).
    var auth_head: ManifestHead
    try:
        auth_head = store.commit_prelude_occ_leased(op._snapshot, op._write_set)
    except occ_e:
        var em = String(occ_e)
        if is_occ_conflict(em):
            op._set_error(em)
            return Int64(0)
        if is_commit_retryable(em) or _is_transient_chunk_read(em):
            # torn-create re-drive — invalidate the local lease head so the
            # re-run re-LISTs the authoritative tail (defends against livelock).
            store.lease_note_lost_slot()
            _tiny_backoff(op._attempt)
            return _commit_async_begin_attempt[Store, S](store, op, reactor)
        op._set_error(em)
        return Int64(0)
    # --- parkable create-CAS at EXACTLY auth_head + 1. ---
    op._candidate = auth_head.chunk_seq + Int64(1)
    op._base = auth_head.next_offset
    op._auth_head_seq = auth_head.chunk_seq
    var body = encode_commit_chunk(op._snapshot, op._write_set)
    var rc = Int64(op.write_set_len())
    var append = AsyncManifestAppendOp[Store]()
    op._append_inflight = True
    # The create-CAS START. A lost-slot 412 surfaces TWO ways the START path must
    # handle SYMMETRICALLY with `commit_async_poll` (BLOCKER-1): (1) BOTH ABI
    # conformers surface a 412 as an ERR `CasOpProgress` (the S3 conformer always;
    # the in-mem SLOW conformer on the immediate-completion fast path — the
    # loopback-MinIO / S3-Express deployment target — completes INSIDE
    # `cas_put_start` and returns ERR), and (2) a misbehaving conformer could RAISE
    # a precondition out of start. EITHER lost-slot signal must re-run the prelude
    # (re-read the authoritative head via LIST + re-OCC against the fixed txn
    # snapshot) + re-park the next slot — NEVER a terminal error. A genuine OCC
    # 40001 raised inside the re-run prelude is then classified there.
    var prog: CasOpProgress
    try:
        prog = append.start[S](
            store.wal_mut(), op._candidate, op._base, body^, rc, reactor
        )
    except start_e:
        # Defense: a conformer that RAISES the 412 (ABI-noncompliant). Classify
        # it as a lost slot and re-run; a non-412 raise is a real transport error.
        op._append_inflight = False
        var rem = String(start_e)
        if _is_lost_slot_412(rem):
            store.lease_note_lost_slot()
            return _commit_async_begin_attempt[Store, S](store, op, reactor)
        op._set_error(String("commit_async: create-CAS start: ") + rem)
        return Int64(0)
    if prog.is_error():
        op._append_inflight = False
        var em = prog.err_text()
        # A LOST-SLOT 412 surfaced as an ERR from start (the immediate-completion
        # fast path). Treat it EXACTLY like the poll-side 412: re-run the prelude
        # + re-park (IDENTICAL to the sync 412 loop). The
        # `_MAX_ASYNC_COMMIT_ATTEMPTS` bound still applies across the re-runs.
        if _is_lost_slot_412(em):
            store.lease_note_lost_slot()
            return _commit_async_begin_attempt[Store, S](store, op, reactor)
        op._set_error(String("commit_async: create-CAS start: ") + em)
        return Int64(0)
    if prog.is_pending():
        return prog.op_id
    return _commit_async_after_cas_ready[Store, S](store, op, append^, reactor)


def _commit_async_after_cas_ready[
    Store: ConditionalWriteStore & AsyncCasStore,
    S: WakerSink & Movable & Deinitable,
](
    mut store: TableStore[Store],
    mut op: AsyncCommitOp,
    var append: AsyncManifestAppendOp[Store],
    mut reactor: Reactor[S],
) raises -> Int64:
    """The create-CAS completed READY (a WIN — the slot was taken). Consume it:
    finalize (index fold + route) + DONE.

    LOW-1 / ABI NOTE — the LIVE 412 channel is the START/POLL ERR classification,
    NOT this `take`->None path. Both AsyncCasStore conformers surface a lost-slot
    412 as an ERR `CasOpProgress` from `cas_put_start` / `cas_put_poll` (the S3
    conformer always; the in-mem SLOW conformer on the immediate-completion fast
    path) — so a 412 is intercepted by `_is_lost_slot_412` in
    `_commit_async_begin_attempt` (START) / `commit_async_poll` (POLL) and never
    reaches READY here. A READY that arrives at this function is therefore always
    a WIN in practice. The `take`->None branch below is kept ONLY as
    defense-in-depth for a hypothetical conformer that defers the 412 to
    `cas_put_take` (the ABI permits it, but neither shipping conformer does); it
    re-runs the prelude + re-parks identically, so it is correct if ever taken."""
    op._append_inflight = False
    var maybe = append.take(store.wal_mut())
    _ = append^
    if maybe:
        var res = maybe.take()
        var commit_lsn = res.chunk_seq
        # Finalize on the LIVE store (the index memtable is server-local).
        store.finalize_commit_win(commit_lsn, op._auth_head_seq, op._write_set)
        # LEASE WIN-ADVANCE: the local head tracks the won tail
        # so the NEXT commit elides the LIST. Body occupies [base, base+rc); the
        # next base offset is base + rc (no-op when the flag is off).
        store.lease_note_win(commit_lsn, op._base + Int64(op.write_set_len()))
        op._finish_committed(commit_lsn)
        return Int64(0)
    # 412 via take->None — the DEFENSIVE fallback channel (see the docstring; not
    # exercised by either shipping conformer). Re-run the prelude + re-park.
    store.lease_note_lost_slot()
    return _commit_async_begin_attempt[Store, S](store, op, reactor)
