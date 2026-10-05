# =============================================================================
# komira_table_store/group_commit.mojo
#   table store GROUP-COMMIT — the CoalescingWindow Phase-3 consumer.
#   N concurrent commits coalesce into ONE create-CAS chunk via the landed
#   `CoalescingWindow` primitive (komira_objectstore/coalescing_window.mojo).
# =============================================================================
#
# WHY: a caller that serializes commits through a queue starts ONE queued
# commit at a time — N concurrent commits cost N
# create-CAS round-trips. Group-commit COALESCES N non-conflicting commits into
# ONE merged chunk = ONE create-CAS. The queue IS the coalescing window (it
# deepens under contention — exactly when coalescing pays).
#
# THE SEAM → table store MAPPING (the four CoalescingWindow seams + the appender):
#   * Item    = TableStoreGroupCommitItem{snapshot_lsn, write_set} — the per-member
#               payload, built from each conn's extracted Txn.
#   * Head    = TableStoreGroupHead{chunk_seq, next_offset} — from the AUTHORITATIVE
#               ManifestHead (the OCC-coupling head).
#   * Outcome = TableStoreGroupOutcome{kind, commit_lsn, intra_batch_seq} — the COMPOSITE
#               LSN: commit_lsn = the SHARED chunk_seq (all winners atomically
#               visible at the one slot — the gapless-monotone invariant
#               _fold_wal_range / _replay_into_index / _occ_check require);
#               intra_batch_seq = the arbitration order within the slot (CDC /
#               audit total order; SI ignores it).
#   * H reader (TableStoreHeadReader) — reads `read_head_authoritative()` (a LIST, NOT
#               poll-shapeable; the single-txn prelude OCC
#               stays blocking too) SYNCHRONOUSLY in read_head_start, encodes the
#               {chunk_seq, next_offset} pair into the CasReadResult body, returns
#               READY. decode_head decodes it back.
#   * C codec (TableStoreGroupCommitCodec) — THE CRUX. Folds intra-batch arbitration
#               (first-in-batch-wins) + per-member OCC (real key-intersection vs
#               the durable head, IDENTICAL to TableStore._occ_check) + the
#               winners' write-set MERGE into ONE chunk body. See its docstring.
#   * A appender (TableStoreExactSlotAppender) — the EXACT-SLOT create-CAS at auth_head+1
#               via the in-tree AsyncManifestAppendOp[Store] (the OCC mode — an
#               escalated slot would be a silent lost-update). A 412 -> LOST_SLOT
#               -> the spine's LIVE 412-loop re-reads head + re-arbitrates (a
#               member can now lose to a freshly-landed chunk) + re-encodes the
#               WHOLE batch + re-appends at the new auth_head+1.
#
# THE OCC/CREATE-CAS COUPLING IS PRESERVED: the spine reads the authoritative head ONCE; the
# SAME `auth` feeds BOTH head_slot (= auth.chunk_seq + 1) AND encode's per-member
# OCC window `(member_snapshot, auth.chunk_seq]`. A WON create-CAS at exactly
# auth.chunk_seq+1 proves the OCC window covered every committed conflict for
# every winner; a 412 forces a fresh read + re-arbitrate + re-OCC.
#
# CRASH-ATOMICITY (structural): the batch = exactly ONE encode body = exactly ONE
# create-CAS slot. Object stores have no atomic multi-object PUT, so the spine
# NEVER splits a batch across two slots — replay folds the full merged write-set
# atomically (all N winners at the shared commit_lsn, or none). Losers are
# runtime-only, never persisted.
#
# stale-reuse / ENCAPSULATION (the repository pointer rules):
#   * Item / Head / Outcome are plain owned/POD structs (WriteOp = POD-of-owned-
#     bytes, reuse-safe trivially). They are buffered in the primitive's Slab[Item] by
#     typed init_pointee_move (concrete origin) and drained by value MOVE — NO
#     wildcard origin EVER touches an inner heap buffer.
#   * The codec / reader / appender each own their OWN CasManifestStore[Store]
#     clone (the store by-value clone() stale-reuse contract); the in-flight create-CAS
#     op lives INSIDE the appender's WAL conformer across the park — only typed
#     CasOpProgress / AppendOutcome cross the seam.
#   * ZERO UnsafePointer in any signature; ZERO wildcard origin; ZERO
#     unsafe_from_address; ZERO take_pointee. Partial moves via Optional.take().
#     Mojo 1.0.0b1.
# =============================================================================

from std.memory import OwnedPointer

# komira_core's Slab, not komira_collections': the coalescing window in
# komira_objectstore takes and returns komira_core's Slab[Item], and the two are
# distinct types.
from komira_collections.slab import Slab

from komira_async.ops.waker_sink import WakerSink
from komira_async.reactor.reactor import Reactor

from komira_objectstore.cas_manifest import (
    AppendResult,
    AsyncManifestAppendOp,
    CasManifestStore,
    ManifestHead,
)
from komira_objectstore.store import (
    AsyncCasStore,
    CasOpProgress,
    CasReadResult,
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
)
from komira_objectstore.coalescing_window import (
    APPEND_ERR,
    APPEND_LOST_SLOT,
    AppendOutcome,
    AuthHeadReader,
    BatchAppender,
    BatchCodec,
    EncodedBatch,
    READ_ERR_CONFLICT,
    READ_ERR_FATAL,
    READ_ERR_TORN,
    SpineFactory,
    _CoalesceSpine,
)

from komira_table_store.table_store_codec import (
    WriteOp,
    bytes_eq,
    decode_commit_chunk_keys,
    encode_commit_chunk,
)
from komira_table_store.table_store import (
    COMMIT_RETRYABLE_TOKEN,
    TableStore,
    _is_lost_slot_412,
    _is_transient_chunk_read,
    _tiny_backoff,
    is_commit_retryable,
    is_occ_conflict,
)


# =============================================================================
# The per-member outcome taxonomy.
# =============================================================================
# A member of a coalesced batch ends in exactly one of three states:
comptime TS_GC_WIN: UInt8 = 0  # merged into the chunk; commit_lsn = shared slot.
comptime TS_GC_LOSS_INTRA: UInt8 = 1  # lost intra-batch arbitration (40001).
comptime TS_GC_LOSS_OCC: UInt8 = 2  # lost per-member OCC vs the durable head (40001).


# =============================================================================
# Item / Head / Outcome.
# =============================================================================


struct TableStoreGroupCommitItem(Copyable, Movable, Deinitable):
    """One member of a coalesced group-commit batch: a single txn's pinned
    snapshot + its buffered write-set (RYOW already deduped by key). Built from a
    conn's extracted open Txn. Copyable (WriteOp is Copyable; the list is plain) —
    the primitive's Slab[Item] stores it by typed value, reuse-safe trivially.

    Field layout:
      var snapshot_lsn: Int64       — the snapshot the member's txn read at (the
                                      per-member OCC window lower bound).
      var write_set: List[WriteOp]  — the member's buffered mutations, deduped.
    """

    var snapshot_lsn: Int64
    var write_set: List[WriteOp]

    def __init__(out self, snapshot_lsn: Int64, var write_set: List[WriteOp]):
        self.snapshot_lsn = snapshot_lsn
        self.write_set = write_set^


struct TableStoreGroupHead(Copyable, Movable, Deinitable):
    """The authoritative manifest head the encode conditions on (the OCC/create-CAS coupling
    head). POD.

    Field layout:
      var chunk_seq: Int64    — highest committed chunk seq (-1 = empty). The OCC
                                window upper bound AND the slot = chunk_seq + 1.
      var next_offset: Int64  — base offset for the next append.
    """

    var chunk_seq: Int64
    var next_offset: Int64

    def __init__(out self, chunk_seq: Int64, next_offset: Int64):
        self.chunk_seq = chunk_seq
        self.next_offset = next_offset


struct TableStoreGroupOutcome(Copyable, Movable, Deinitable):
    """The per-member result handed back to each conn. POD (Copyable — the
    primitive collects outcomes in a List[Tuple[Int, Outcome]]).

    Field layout:
      var kind: UInt8          — TS_GC_WIN / TS_GC_LOSS_INTRA / TS_GC_LOSS_OCC.
      var commit_lsn: Int64    — the SHARED won slot (valid only on WIN; -1 else).
      var intra_batch_seq: Int — the arbitration order within the slot (WIN only).
    """

    var kind: UInt8
    var commit_lsn: Int64
    var intra_batch_seq: Int

    def __init__(out self, kind: UInt8, commit_lsn: Int64, intra_batch_seq: Int):
        self.kind = kind
        self.commit_lsn = commit_lsn
        self.intra_batch_seq = intra_batch_seq

    @staticmethod
    def win(commit_lsn: Int64, intra_batch_seq: Int) -> TableStoreGroupOutcome:
        return TableStoreGroupOutcome(TS_GC_WIN, commit_lsn, intra_batch_seq)

    @staticmethod
    def loss_intra() -> TableStoreGroupOutcome:
        return TableStoreGroupOutcome(TS_GC_LOSS_INTRA, Int64(-1), -1)

    @staticmethod
    def loss_occ() -> TableStoreGroupOutcome:
        return TableStoreGroupOutcome(TS_GC_LOSS_OCC, Int64(-1), -1)

    @always_inline
    def is_win(self) -> Bool:
        return self.kind == TS_GC_WIN

    @always_inline
    def is_loss(self) -> Bool:
        return self.kind != TS_GC_WIN


# Little-endian i64 framing for the head body the reader hands the codec (a
# 16-byte body: chunk_seq || next_offset). Self-contained (the reader/codec are
# the only producer/consumer), so no cross-module codec dependency.
def _put_i64_le(mut out: List[UInt8], v: Int64):
    var u = UInt64(v)
    for i in range(8):
        out.append(UInt8((u >> UInt64(8 * i)) & UInt64(0xFF)))


def _get_i64_le(bytes: List[UInt8], off: Int) raises -> Int64:
    if off + 8 > len(bytes):
        raise Error("group_commit: truncated i64 head body")
    var u = UInt64(0)
    for i in range(8):
        u |= UInt64(Int(bytes[off + i])) << UInt64(8 * i)
    return Int64(u)


def _encode_head_body(chunk_seq: Int64, next_offset: Int64) -> List[UInt8]:
    var out = List[UInt8]()
    _put_i64_le(out, chunk_seq)
    _put_i64_le(out, next_offset)
    return out^


# =============================================================================
# TableStoreHeadReader (SEAM 2: AuthHeadReader).
# =============================================================================
# Reads the AUTHORITATIVE manifest head (read_head_authoritative — a LIST, the
# OCC-coupling head). The landed table store design keeps the head-read BLOCKING
# (a LIST is not poll-shapeable via the AsyncCasStore ABI, and on the warm path
# it hits the local cache — no RTT), so read_head_start does the read
# SYNCHRONOUSLY and returns READY immediately (no park) — identical to the
# landed `commit_prelude_occ` blocking head-read. The table store group-commit's ONE
# parkable I/O step is the create-CAS (the appender), the single ALWAYS-PRESENT
# object-store WRITE per batch.
#
# The reader owns its OWN CasManifestStore clone; the head body is encoded as two
# LE i64 into the CasReadResult the codec decodes (decode_head). stale-reuse: the in-
# flight (synchronous) head-read lives inside the reader's own concrete-origin
# WAL handle; only the typed CasReadResult crosses the seam.


struct TableStoreHeadReader[Store: ConditionalWriteStore & AsyncCasStore](
    AuthHeadReader, Movable, Deinitable
):
    var _wal: CasManifestStore[Self.Store]
    # The synchronously-read head body, stashed for take_read.
    var _pending: Optional[List[UInt8]]

    def __init__(out self, var wal: CasManifestStore[Self.Store]):
        self._wal = wal^
        self._pending = Optional[List[UInt8]]()

    def read_head_start[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> CasOpProgress:
        # Synchronous authoritative head-read (LIST / warm cache). The OCC-coupling
        # head: the same head the create-CAS targets at +1. Stash the
        # encoded body for take_read; report READY (no park).
        var head = self._wal.read_head_authoritative()
        self._pending = Optional[List[UInt8]](
            _encode_head_body(head.chunk_seq, head.next_offset)
        )
        return CasOpProgress.ready()

    def read_head_poll[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> CasOpProgress:
        # The read completes synchronously in read_head_start, so a poll never
        # fires for this reader; defensively report READY.
        return CasOpProgress.ready()

    def take_read(mut self) raises -> CasReadResult:
        if not self._pending:
            raise Error("TableStoreHeadReader.take_read: no staged head")
        var body = self._pending.take()
        return CasReadResult(absent=False, body=body^, etag=String(""))

    def classify_read_error(self, msg: String) -> UInt8:
        # A torn-create (an in-flight competitor chunk under the O_EXCL window)
        # is RETRYABLE; a precondition is a CONFLICT; everything else is FATAL.
        if (
            msg.find("torn") >= 0
            or msg.find("truncated") >= 0
            or msg.find("retryable") >= 0
            or msg.find("RETRYABLE") >= 0
        ):
            return READ_ERR_TORN
        if msg.find("412") >= 0 or msg.find("precondition") >= 0:
            return READ_ERR_CONFLICT
        return READ_ERR_FATAL

    # The group-commit chunk is always inline in the manifest body (encode emits
    # NO staged blob), so the spine never drives the stage-blob phase. The stubs
    # report READY immediately (never reached).
    def stage_blob_start[
        S: WakerSink & Movable & Deinitable,
    ](
        mut self, key: String, var bytes: List[UInt8], mut reactor: Reactor[S]
    ) raises -> CasOpProgress:
        _ = bytes^
        return CasOpProgress.ready()

    def stage_blob_poll[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> CasOpProgress:
        return CasOpProgress.ready()

    def stage_blob_take(mut self) raises -> None:
        pass


# =============================================================================
# Pure arbitration + per-member OCC (the conflict-fuzz reference targets).
# =============================================================================
# These are EXTRACTED as free functions so the conflict-fuzz test can drive them
# directly against a reference model (a missed key-intersection is a SILENT
# lost-update — the highest-risk surface). The codec's encode calls them.


def _write_sets_intersect(a: List[WriteOp], b: List[WriteOp]) -> Bool:
    """True iff write-sets `a` and `b` share ANY key. O(|a|*|b|) byte compares —
    write-sets are small (a single txn's buffered mutations). Catalog/DDL
    mutations are arbitrated keys too (they appear as WriteOps), so two batched
    `CREATE TABLE foo` whose write-sets touch the same catalog key intersect."""
    for i in range(len(a)):
        for j in range(len(b)):
            if bytes_eq(a[i].key, b[j].key):
                return True
    return False


def arbitrate_intra_batch(items: List[TableStoreGroupCommitItem]) -> List[Bool]:
    """INTRA-BATCH arbitration: FIRST-IN-BATCH-WINS (tiebreak = drain / FIFO
    order = the items' index order — ratified). Returns a parallel
    `survives_intra[i]` mask: member i SURVIVES the intra-batch round iff its
    write-set does NOT intersect any EARLIER-index surviving member's write-set.
    A later member sharing a key with an earlier surviving member is an intra-
    batch LOSER (40001), and it NEVER enters the merged write-set (so it cannot
    contribute a lost-update). PURE — no store access.

    NOTE: this checks each later member against the EARLIER SURVIVORS' write-sets
    only (not against earlier losers), so the survivor set is exactly the
    first-claimant per key. Determinism is on the items' drain order."""
    var survives = List[Bool]()
    for i in range(len(items)):
        var ok = True
        for j in range(i):
            if survives[j] and _write_sets_intersect(
                items[i].write_set, items[j].write_set
            ):
                ok = False
                break
        survives.append(ok)
    return survives^


def _occ_member_conflicts_wal[
    Store: ConditionalWriteStore & AsyncCasStore,
](
    mut wal: CasManifestStore[Store],
    snapshot: Int64,
    auth_head_seq: Int64,
    write_set: List[WriteOp],
) raises -> Bool:
    """The SHARED per-member OCC key-intersection scan (THE ONE implementation).
    True iff a key in `write_set` was committed by another txn in chunks
    `(snapshot, auth_head_seq]` (a first-committer-wins conflict — the member's
    snapshot is stale). IDENTICAL key-intersection to TableStore._occ_check.
    Raises a RETRYABLE-tagged error on a torn-create in-flight chunk (the caller
    re-reads + re-arbitrates). Reads through the caller's `wal` ref so BOTH the
    `TableStoreGroupCommitCodec` (its own clone) AND the live `_group_prelude`
    (the borrowed TableStore WAL) run the SAME OCC logic — no second copy."""
    var seq = snapshot + Int64(1)
    while seq <= auth_head_seq:
        var other_keys: List[List[UInt8]]
        try:
            var other_body = wal.read_chunk(seq)
            other_keys = decode_commit_chunk_keys(other_body)
        except e:
            # A torn-create / in-flight chunk under the O_EXCL window — RETRYABLE
            # (re-read head + re-encode). Tag it so the spine's read classify /
            # the driver's `is_commit_retryable` treats it as a re-drive.
            raise Error(
                COMMIT_RETRYABLE_TOKEN
                + ": group_commit OCC scan saw an in-flight chunk at seq "
                + String(seq)
                + " (torn-create — retryable): "
                + String(e)
            )
        for oi in range(len(other_keys)):
            ref ok = other_keys[oi]
            for wi in range(len(write_set)):
                if bytes_eq(write_set[wi].key, ok):
                    return True
        seq += Int64(1)
    return False


def encode_group_batch[
    Store: ConditionalWriteStore & AsyncCasStore,
](
    mut wal: CasManifestStore[Store],
    members: List[TableStoreGroupCommitItem],
    auth_head_seq: Int64,
) raises -> Tuple[List[WriteOp], List[Int], List[TableStoreGroupOutcome]]:
    """THE ONE DOMAIN-LOGIC IMPLEMENTATION for the group-commit fold (the
    share-the-codec refactor). Folds, in order, over `members` +
    the authoritative head seq:
      1. INTRA-BATCH arbitration (first-in-batch-wins) — `arbitrate_intra_batch`.
      2. PER-MEMBER OCC vs the durable head — `_occ_member_conflicts_wal` (the
         SAME key-intersection as the single-txn `_occ_check`), scanned through
         the caller's `wal` ref.
      3. MERGE the surviving winners' write-sets.
    Returns (merged_write_set, winner_member_idxs[in arbitration/drain order],
    outcome skeleton[parallel to members; winners carry a WIN placeholder with
    commit_lsn=-1 + their intra_batch_seq, losers their terminal 40001]). A
    torn-create / retryable read inside the OCC scan re-raises (the caller
    re-drives the WHOLE fold).

    BOTH consumers call THIS function — `TableStoreGroupCommitCodec.encode` (over its own
    `CasManifestStore` clone) AND the live `_group_prelude` (over the
    borrowed `TableStore` WAL). So the 400-seed conflict-fuzz (which drives the
    codec) DIRECTLY covers the live arbitration + per-member OCC + merge:
    there is no second copy to drift. The Mojo-bound-forced parkable PLUMBING
    (the store-agnostic FSM + 412-loop in `AsyncGroupCommitOp` / the spine's
    create-CAS) is the DRIVER around this shared domain logic, documented as the
    accepted, precedented seam."""
    var n = len(members)
    var survives = arbitrate_intra_batch(members)
    var merged = List[WriteOp]()
    var winner_idxs = List[Int]()
    var outcomes = List[TableStoreGroupOutcome]()
    for _ in range(n):
        outcomes.append(TableStoreGroupOutcome.loss_intra())  # default; overwritten below
    for i in range(n):
        if not survives[i]:
            # Intra-batch loser — never enters the merged write-set.
            outcomes[i] = TableStoreGroupOutcome.loss_intra()
            continue
        # Per-member OCC: the member's OWN snapshot vs (snapshot, auth_head_seq].
        var conflicts = _occ_member_conflicts_wal[Store](
            wal, members[i].snapshot_lsn, auth_head_seq, members[i].write_set
        )
        if conflicts:
            outcomes[i] = TableStoreGroupOutcome.loss_occ()
            continue
        # WINNER — merge its write-set + record the winner idx (the WIN outcome's
        # commit_lsn is stamped on the create-CAS win).
        for wi in range(len(members[i].write_set)):
            merged.append(members[i].write_set[wi].copy())
        winner_idxs.append(i)
        outcomes[i] = TableStoreGroupOutcome.win(Int64(-1), len(winner_idxs) - 1)
    return (merged^, winner_idxs^, outcomes^)


# =============================================================================
# TableStoreGroupCommitCodec (SEAM 3: BatchCodec) — THE CRUX.
# =============================================================================
# encode folds THREE things, in this order, over the buffered members + the
# decoded authoritative head:
#   1. INTRA-BATCH arbitration (first-in-batch-wins) — arbitrate_intra_batch.
#      A later member intersecting an earlier SURVIVOR's keys is an intra-batch
#      loser (TS_GC_LOSS_INTRA -> 40001); never enters the merged write-set.
#   2. PER-MEMBER OCC vs the DURABLE head — for each intra-batch survivor, scan
#      chunks `(member_snapshot, auth.chunk_seq]` for any key intersecting THAT
#      member's write-set (IDENTICAL key-intersection to TableStore._occ_check).
#      A stale-snapshot conflict is an OCC loser (TS_GC_LOSS_OCC -> 40001).
#   3. MERGE the surviving winners' write-sets into ONE chunk body
#      (encode_commit_chunk) — the single create-CAS payload. winner_idxs are the
#      winners' orig indices in arbitration (drain) order; loser_outcomes carry
#      the (orig_idx, 40001) pairs for BOTH loser classes.
#
# The codec owns its OWN CasManifestStore[Store] clone for the OCC read_chunk
# scan (the OCC scan is non-empty ONLY under actual contention; it stays blocking
# inside encode, exactly as the landed prelude OCC scan does — the CPU/sync
# ENCODE phase). The OCC/create-CAS coupling: encode's OCC upper bound == head_slot's slot-1
# == the SAME auth the appender create-CASes at +1.


struct TableStoreGroupCommitCodec[Store: ConditionalWriteStore & AsyncCasStore](
    BatchCodec, Movable, Deinitable
):
    comptime Item = TableStoreGroupCommitItem
    comptime Head = TableStoreGroupHead
    comptime Outcome = TableStoreGroupOutcome

    # The OCC-scan WAL clone (read_chunk over (member_snapshot, auth_head]).
    var _wal: CasManifestStore[Self.Store]

    def __init__(out self, var wal: CasManifestStore[Self.Store]):
        self._wal = wal^

    def decode_head(mut self, var rr: CasReadResult) raises -> TableStoreGroupHead:
        if rr.absent:
            return TableStoreGroupHead(chunk_seq=Int64(-1), next_offset=Int64(0))
        var chunk_seq = _get_i64_le(rr.body, 0)
        var next_offset = _get_i64_le(rr.body, 8)
        return TableStoreGroupHead(chunk_seq=chunk_seq, next_offset=next_offset)

    def head_slot(self, ref auth: TableStoreGroupHead) -> Int64:
        # The EXACT slot = auth_head + 1 (the OCC/create-CAS coupling — the OCC window upper
        # bound is auth.chunk_seq, so the commit lands at chunk_seq+1, no
        # un-checked gap below the commit).
        return auth.chunk_seq + Int64(1)

    def estimate_bytes(self, ref it: TableStoreGroupCommitItem) -> Int:
        # The size contribution = the member's write-set byte total (rough — the
        # framing overhead is small). Used only by the size band; the table store forces
        # EXPLICIT flushes (the queue drain), so this is informational.
        var n = 0
        for i in range(len(it.write_set)):
            n += len(it.write_set[i].key) + len(it.write_set[i].row) + 9
        return n

    def encode(
        mut self, ref items: Slab[TableStoreGroupCommitItem], var auth: TableStoreGroupHead
    ) raises -> EncodedBatch[TableStoreGroupOutcome]:
        # SHARE-THE-CODEC: the arbitration + per-member OCC +
        # merge is the ONE shared `encode_group_batch` free function — the SAME
        # implementation the live `_group_prelude` calls. The codec adapts
        # only the Slab[Item] -> List[Item] view + the EncodedBatch packaging
        # (winner_idxs + the (orig_idx, 40001) loser_outcomes the spine ABI
        # wants); the domain logic lives in exactly one place. So the 400-seed
        # conflict-fuzz (which drives THIS encode) directly covers the live
        # arbitration + OCC + merge.
        var n = items.len()
        var view = List[TableStoreGroupCommitItem]()
        for i in range(n):
            view.append(items[i].copy())
        var folded = encode_group_batch[Self.Store](
            self._wal, view, auth.chunk_seq
        )
        var merged = folded[0].copy()
        var winner_idxs = folded[1].copy()
        var outcomes = folded[2].copy()
        _ = folded^

        # Repackage the shared (merged, winner_idxs, outcomes[parallel]) fold
        # into the spine ABI's (winner_idxs, loser_outcomes[(orig_idx, 40001)]).
        var loser_outcomes = List[Tuple[Int, TableStoreGroupOutcome]]()
        for i in range(n):
            if outcomes[i].is_loss():
                loser_outcomes.append((i, outcomes[i].copy()))

        # MERGE the winners' write-sets into ONE chunk body. The chunk's
        # snapshot_lsn header is RESERVED (the per-member OCC already validated
        # each member's own snapshot; the merged chunk's header is informational
        # — we record auth.chunk_seq, the head it was validated against). Replay
        # / cross-handle OCC reads only the KEYS, never the header snapshot.
        var body = encode_commit_chunk(auth.chunk_seq, merged)
        return EncodedBatch[TableStoreGroupOutcome](
            body^,
            Int64(len(merged)),
            Optional[List[UInt8]](),
            String(""),
            Int64(0),
            Int64(0),
            loser_outcomes^,
            winner_idxs^,
        )

    def winner_outcome(
        self, orig_idx: Int, intra_batch_seq: Int, append: AppendResult
    ) -> TableStoreGroupOutcome:
        # COMPOSITE LSN: the SHARED chunk_seq (all winners atomically visible at
        # this slot) + the intra_batch_seq (arbitration order within the slot).
        return TableStoreGroupOutcome.win(append.chunk_seq, intra_batch_seq)


# =============================================================================
# TableStoreExactSlotAppender (SEAM 5: BatchAppender) — the EXACT-SLOT write.
# =============================================================================
# The EXACT-SLOT create-CAS at auth_head+1 (the OCC mode — an escalated slot is a
# silent lost-update). Drives the in-tree parkable AsyncManifestAppendOp[Store]
# over its OWN CasManifestStore[Store] clone. The appender RE-DERIVES the exact
# slot from its WAL's authoritative head at append_start (so the slot is always
# exactly the head the encode's OCC validated against +1; the spine's hint
# matches it, but re-deriving from the WAL is the canonical exact-slot shape the
# landed _ExactSlotAppender / commit_async_* use). A 412 -> LOST_SLOT -> the
# spine's LIVE 412-loop re-reads + re-arbitrates + re-encodes + re-appends.
#
# stale-reuse: the in-flight create-CAS op lives INSIDE the WAL's `_store` conformer
# across the park — only typed CasOpProgress / AppendOutcome cross the seam.


struct TableStoreExactSlotAppender[Store: ConditionalWriteStore & AsyncCasStore](
    BatchAppender, Movable, Deinitable
):
    var _wal: CasManifestStore[Self.Store]
    var _op: AsyncManifestAppendOp[Self.Store]
    var _candidate: Int64
    var _base: Int64
    var _inflight: Bool

    def __init__(out self, var wal: CasManifestStore[Self.Store]):
        self._wal = wal^
        self._op = AsyncManifestAppendOp[Self.Store]()
        self._candidate = Int64(0)
        self._base = Int64(0)
        self._inflight = False

    def append_start[
        S: WakerSink & Movable & Deinitable,
    ](
        mut self,
        var body: List[UInt8],
        record_count: Int64,
        slot: Int64,
        lease_epoch: Int64,
        current_lease_epoch: Int64,
        mut reactor: Reactor[S],
    ) raises -> CasOpProgress:
        # Re-derive the AUTHORITATIVE exact slot (the canonical exact-slot shape
        # — the slot is always the validated head + 1).
        var head = self._wal.read_head_authoritative()
        self._candidate = head.chunk_seq + Int64(1)
        self._base = head.next_offset
        self._inflight = True
        return self._op.start[S](
            self._wal, self._candidate, self._base, body^, record_count, reactor
        )

    def append_poll[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> CasOpProgress:
        return self._op.poll[S](self._wal, reactor)

    def append_take(mut self) raises -> AppendOutcome:
        var r = self._op.take(self._wal)
        # A fresh op for any LOST_SLOT re-drive (the spine re-encodes + re-calls
        # append_start).
        self._op = AsyncManifestAppendOp[Self.Store]()
        self._inflight = False
        if r:
            return AppendOutcome.won(r.take())
        # take->None is the defense-in-depth deferred-412 channel.
        return AppendOutcome.lost_slot()

    def classify_append_error(self, msg: String) -> UInt8:
        # The exact-slot mode: a 412/precondition is a REAL lost slot.
        if (
            msg.find("412") >= 0
            or msg.find("precondition") >= 0
            or msg.find("If-None-Match") >= 0
            or msg.find("If-Match") >= 0
        ):
            return APPEND_LOST_SLOT
        return APPEND_ERR


# =============================================================================
# TableStoreGroupCommitFactory (SpineFactory) — mints a fresh spine per flush.
# =============================================================================
# The window calls make_spine(items^, reason) on each flush. The factory holds
# the CLONEABLE store + the WAL prefix and builds a FRESH CasManifestStore clone
# for EACH seam conformer (reader / codec / appender) per flush — the store
# by-value clone() stale-reuse contract. All three clones share the same Arc-backed
# inner map (so they see the same committed data); each holds its OWN handle.


struct TableStoreGroupCommitFactory[
    Store: CloneableConditionalWriteStore & AsyncCasStore
](SpineFactory, Movable, Deinitable):
    comptime Storage = Self.Store
    comptime H = TableStoreHeadReader[Self.Store]
    comptime C = TableStoreGroupCommitCodec[Self.Store]
    comptime A = TableStoreExactSlotAppender[Self.Store]
    comptime Item = TableStoreGroupCommitItem

    var _store: Self.Store
    var _prefix: String

    def __init__(out self, var store: Self.Store, var prefix: String):
        self._store = store^
        self._prefix = prefix^

    def make_spine(
        mut self, var items: Slab[TableStoreGroupCommitItem], reason: UInt8
    ) raises -> _CoalesceSpine[
        Self.Store,
        TableStoreHeadReader[Self.Store],
        TableStoreGroupCommitCodec[Self.Store],
        TableStoreExactSlotAppender[Self.Store],
    ]:
        var reader = TableStoreHeadReader[Self.Store](
            CasManifestStore[Self.Store](
                self._store.clone(), self._prefix.copy()
            )
        )
        var codec = TableStoreGroupCommitCodec[Self.Store](
            CasManifestStore[Self.Store](
                self._store.clone(), self._prefix.copy()
            )
        )
        var appender = TableStoreExactSlotAppender[Self.Store](
            CasManifestStore[Self.Store](
                self._store.clone(), self._prefix.copy()
            )
        )
        return _CoalesceSpine[
            Self.Store,
            TableStoreHeadReader[Self.Store],
            TableStoreGroupCommitCodec[Self.Store],
            TableStoreExactSlotAppender[Self.Store],
        ](reader^, codec^, appender^, items^, reason)


# =============================================================================
# AsyncGroupCommitOp + the group_commit_async_* driver (the reactor-driven
#      group-commit path).
# =============================================================================
# WHY a STORE-AGNOSTIC carried op (NOT the CoalescingWindow front-end): a
# server that embeds this state may be bound on the BASE `ConditionalWriteStore`
# (and instantiated with non-cloneable in-mem stores in tests), so a
# `CoalescingWindow[TableStoreGroupCommitFactory[Store]]` (which requires
# `CloneableConditionalWriteStore`) CANNOT be a server field in Mojo 1.0.0b1
# (a struct field's type must satisfy the struct's own param bound). So the
# carried-across-park group state mirrors the landed single-txn `AsyncCommitOp`:
# it holds ONLY the N members' (snapshot, write-set) + the in-flight slot POD
# mirror — NO store — and the `group_commit_async_*` free functions (parameterized
# `[Store: ... & AsyncCasStore]`) reconstruct the transient
# `AsyncManifestAppendOp[Store]` each poll from the POD mirror, EXACTLY as
# `commit_async_*` does. The arbitration + per-member OCC logic is the SAME logic
# the `TableStoreGroupCommitCodec` / `arbitrate_intra_batch` (proven by the conflict-fuzz)
# uses — here it runs inline over the caller's borrowed `TableStore[Store]` (no
# clone needed; the driver lives in this module so the WAL handle never crosses a
# boundary).
#
# THE OCC/CREATE-CAS COUPLING (preserved IDENTICALLY to the single-txn path): the synchronous
# prelude reads the AUTHORITATIVE head ONCE; the SAME head feeds BOTH the
# per-member OCC window `(member_snapshot, auth_head]` AND the merged create-CAS
# slot (auth_head+1). A WON slot proves the OCC window covered every conflict for
# every winner. A 412 (lost slot) re-runs the WHOLE prelude (re-read head +
# re-arbitrate [a member can now lose to a freshly-landed competitor] + re-OCC +
# re-merge) + re-parks the next slot — never partial.
#
# CRASH-ATOMICITY (structural): the prelude merges the winners' write-sets into
# ONE chunk body = ONE create-CAS slot. Replay folds all winners at the shared
# commit_lsn or none (the conflict-fuzz / crash-atomicity tests prove this).
#
# stale-reuse: AsyncGroupCommitOp is a plain owned struct (a `List[TableStoreGroupCommitItem]` +
# a `List[TableStoreGroupOutcome]` + PODs + an error String). NO byte-slab + wildcard,
# NO pointer; the in-flight create-CAS op lives INSIDE the WAL's `_store`
# conformer across the park (reconstructed each poll from the POD mirror).

comptime _AGC_PHASE_RUNNING: UInt8 = 0
comptime _AGC_PHASE_DONE: UInt8 = 1
comptime _AGC_PHASE_ERR: UInt8 = 2

comptime _MAX_GROUP_COMMIT_ATTEMPTS: Int = 256


struct AsyncGroupCommitOp(Movable, Deinitable):
    """The carried-across-park state for a poll-shaped GROUP commit: N members'
    (snapshot, write-set) + the parallel per-member outcomes (filled on DONE) +
    the in-flight slot POD mirror. Movable, NOT Copyable (owns Lists + the error
    String).

    Field layout:
      var _members: List[TableStoreGroupCommitItem]  — the N batch members (in drain /
                                               FIFO order = arbitration order).
      var _outcomes: List[TableStoreGroupOutcome]    — parallel to _members; valid on
                                               DONE (each WIN carries the shared
                                               commit_lsn + its intra_batch_seq;
                                               each LOSS carries 40001).
      var _phase / _attempt / _err           — the driver FSM + bound + diag.
      var _candidate / _base / _auth_head_seq / _append_inflight — the in-flight
                                               create-CAS POD mirror (the actual
                                               transport op lives in the WAL
                                               conformer, reconstructed per poll).
      var _merged_body / _merged_count       — the encoded merged chunk (the
                                               winners' write-sets) the parked
                                               create-CAS is landing; retained
                                               across the park (re-encoded on a
                                               412 re-arbitrate).
    """

    var _members: List[TableStoreGroupCommitItem]
    var _outcomes: List[TableStoreGroupOutcome]
    var _phase: UInt8
    var _attempt: Int
    var _err: String
    var _candidate: Int64
    var _base: Int64
    var _auth_head_seq: Int64
    var _append_inflight: Bool
    var _merged_body: List[UInt8]
    var _merged_count: Int64
    # The CURRENT attempt's winner partition + outcome skeleton, STASHED when the
    # create-CAS is kicked + consumed on the WIN finalize (so the finalize uses
    # EXACTLY the partition the won body was built from — no re-run, no drift). A
    # 412 re-arbitrate overwrites them on the next attempt.
    var _winner_idxs: List[Int]
    var _merged_write_set: List[WriteOp]
    var _outcome_skel: List[TableStoreGroupOutcome]

    def __init__(out self, var members: List[TableStoreGroupCommitItem]):
        self._members = members^
        self._outcomes = List[TableStoreGroupOutcome]()
        self._phase = _AGC_PHASE_RUNNING
        self._attempt = 0
        self._err = String("")
        self._candidate = Int64(0)
        self._base = Int64(0)
        self._auth_head_seq = Int64(-1)
        self._append_inflight = False
        self._merged_body = List[UInt8]()
        self._merged_count = Int64(0)
        self._winner_idxs = List[Int]()
        self._merged_write_set = List[WriteOp]()
        self._outcome_skel = List[TableStoreGroupOutcome]()

    @always_inline
    def member_count(self) -> Int:
        return len(self._members)

    @always_inline
    def is_done(self) -> Bool:
        return self._phase == _AGC_PHASE_DONE

    @always_inline
    def is_error(self) -> Bool:
        return self._phase == _AGC_PHASE_ERR

    @always_inline
    def err_text(self) -> String:
        return self._err

    def outcome_at(self, i: Int) raises -> TableStoreGroupOutcome:
        """The member-i outcome (caller checks is_done() first)."""
        if self._phase != _AGC_PHASE_DONE:
            raise Error("AsyncGroupCommitOp.outcome_at: not done")
        if i < 0 or i >= len(self._outcomes):
            raise Error("AsyncGroupCommitOp.outcome_at: index out of range")
        return self._outcomes[i].copy()

    def _set_error(mut self, var msg: String):
        self._phase = _AGC_PHASE_ERR
        self._err = msg^

    def _finish(mut self, var outcomes: List[TableStoreGroupOutcome]):
        self._phase = _AGC_PHASE_DONE
        self._outcomes = outcomes^


# ---- the prelude: arbitrate + per-member OCC + merge (the synchronous CPU pass).
# Returns the merged write-set (winners only, in arbitration order) + the parallel
# per-member outcome SKELETON (WIN with commit_lsn=-1 placeholder for winners; the
# final commit_lsn is stamped on the win). LOSERS get their terminal 40001.
# `survives_intra[i]` is the first-in-batch-wins mask (== arbitrate_intra_batch).


def _group_prelude[
    Store: ConditionalWriteStore & AsyncCasStore,
](
    mut store: TableStore[Store],
    members: List[TableStoreGroupCommitItem],
    auth_head: ManifestHead,
) raises -> Tuple[List[WriteOp], List[Int], List[TableStoreGroupOutcome]]:
    """The synchronous prelude over the authoritative `auth_head` — a THIN
    delegation to the ONE shared `encode_group_batch` (the
    share-the-codec refactor). The arbitration (first-in-batch-wins) + per-member
    OCC (key-intersection over `(snapshot, auth_head]`) + winners' write-set
    MERGE all live in `encode_group_batch`, which the `TableStoreGroupCommitCodec` ALSO
    calls — so the live fold and the codec fold are the SAME code (no second
    copy to drift; the 400-seed conflict-fuzz covers this path directly). The OCC
    scan reads through the borrowed TableStore WAL (`store.wal_mut()`), the SAME
    handle the create-CAS targets at +1 (the OCC/create-CAS coupling). A torn-create /
    retryable read inside the OCC scan re-raises (the driver re-drives the WHOLE
    prelude). Returns (merged_write_set, winner_member_idxs[in arbitration order],
    outcome skeleton[parallel to members; winners carry a WIN placeholder, losers
    their terminal 40001])."""
    return encode_group_batch[Store](
        store.wal_mut(), members, auth_head.chunk_seq
    )


def group_commit_async_start[
    Store: ConditionalWriteStore & AsyncCasStore,
    S: WakerSink & Movable & Deinitable,
](
    mut store: TableStore[Store],
    mut op: AsyncGroupCommitOp,
    mut reactor: Reactor[S],
) raises -> Int64:
    """Begin a poll-shaped GROUP commit of `op`'s N members. Runs the synchronous
    prelude (read auth head + arbitrate + per-member OCC + merge) then kicks off
    the parkable create-CAS at auth_head+1 over the MERGED chunk. Returns the
    BIASED op_id to park on (0 == finished in one synchronous burst — the caller
    checks `op.is_done()`/`op.is_error()` then fans out via `op.outcome_at(i)`).

    An ALL-LOSER batch (no winners survive arbitration + OCC) finishes
    immediately DONE with no create-CAS (every member already has its 40001)."""
    if op.member_count() == 0:
        op._finish(List[TableStoreGroupOutcome]())
        return Int64(0)
    return _group_begin_attempt[Store, S](store, op, reactor)


def _group_begin_attempt[
    Store: ConditionalWriteStore & AsyncCasStore,
    S: WakerSink & Movable & Deinitable,
](
    mut store: TableStore[Store],
    mut op: AsyncGroupCommitOp,
    mut reactor: Reactor[S],
) raises -> Int64:
    """One group-commit attempt: synchronous head-read-auth + arbitrate + OCC +
    merge, then kick the parkable create-CAS at auth_head+1. Returns the op_id to
    park on (or 0 if it completed in this same burst). A torn-create / retryable
    read re-drives after a tiny backoff; the bound backstops a contention storm."""
    op._attempt += 1
    if op._attempt > _MAX_GROUP_COMMIT_ATTEMPTS:
        op._set_error(
            COMMIT_RETRYABLE_TOKEN
            + ": group_commit_async exhausted "
            + String(_MAX_GROUP_COMMIT_ATTEMPTS)
            + " arbitrate/create-CAS attempts under contention (retryable)"
        )
        return Int64(0)
    # --- synchronous prelude: read the AUTHORITATIVE head + arbitrate + OCC. ---
    # LEASE FAST-PATH: `read_auth_head_leased` elides the
    # per-batch authoritative head read (LIST + per-chunk record-count replay)
    # when the lease is held + the local head is warm — this is the
    # group-commit path callers use, so the lease MUST elide its per-batch head read too (the single-writer
    # win the lease exists for). With the flag off it is byte-identical to
    # `read_auth_head()`.
    var auth_head: ManifestHead
    var prelude: Tuple[List[WriteOp], List[Int], List[TableStoreGroupOutcome]]
    try:
        auth_head = store.read_auth_head_leased()
        prelude = _group_prelude[Store](store, op._members, auth_head)
    except pe:
        var em = String(pe)
        if is_commit_retryable(em) or _is_transient_chunk_read(em):
            # torn-create re-drive — invalidate the local lease head so the
            # re-run re-LISTs the authoritative tail (livelock defense).
            store.lease_note_lost_slot()
            _tiny_backoff(op._attempt)
            return _group_begin_attempt[Store, S](store, op, reactor)
        op._set_error(em)
        return Int64(0)
    var merged = prelude[0].copy()
    var winner_idxs = prelude[1].copy()
    var outcomes = prelude[2].copy()
    _ = prelude^

    # ALL-LOSER batch (no winner survived arbitration + OCC): no create-CAS — every
    # member already carries its terminal 40001. Finish DONE immediately.
    if len(winner_idxs) == 0:
        op._finish(outcomes^)
        return Int64(0)

    # --- parkable create-CAS at EXACTLY auth_head + 1 over the MERGED chunk. ---
    op._candidate = auth_head.chunk_seq + Int64(1)
    op._base = auth_head.next_offset
    op._auth_head_seq = auth_head.chunk_seq
    # The merged chunk body (winners' write-sets). The chunk header snapshot is
    # auth.chunk_seq (informational — the per-member OCC already validated each
    # member; replay/OCC reads only the keys).
    var body = encode_commit_chunk(auth_head.chunk_seq, merged)
    op._merged_body = body.copy()
    op._merged_count = Int64(len(merged))
    _ = body^
    # STASH this attempt's partition for the WIN finalize (so finalize uses EXACTLY
    # the partition the won body was built from — no re-run, no drift across the
    # park). A 412 re-arbitrate overwrites these on the next attempt.
    op._winner_idxs = winner_idxs.copy()
    op._merged_write_set = merged.copy()
    op._outcome_skel = outcomes.copy()
    var append = AsyncManifestAppendOp[Store]()
    op._append_inflight = True
    var prog: CasOpProgress
    try:
        prog = append.start[S](
            store.wal_mut(),
            op._candidate,
            op._base,
            op._merged_body.copy(),
            op._merged_count,
            reactor,
        )
    except start_e:
        op._append_inflight = False
        var rem = String(start_e)
        if _is_lost_slot_412(rem):
            # Lost the slot before parking — re-run the prelude (re-arbitrate
            # against the freshly-landed competitor) + re-park. LEASE:
            # invalidate the stale local head so the re-run re-LISTs.
            store.lease_note_lost_slot()
            return _group_begin_attempt[Store, S](store, op, reactor)
        op._set_error(String("group_commit_async: create-CAS start: ") + rem)
        return Int64(0)
    if prog.is_error():
        op._append_inflight = False
        var em = prog.err_text()
        if _is_lost_slot_412(em):
            store.lease_note_lost_slot()
            return _group_begin_attempt[Store, S](store, op, reactor)
        op._set_error(String("group_commit_async: create-CAS start: ") + em)
        return Int64(0)
    if prog.is_pending():
        return prog.op_id
    return _group_after_cas_ready[Store, S](store, op, append^, reactor)


def group_commit_async_poll[
    Store: ConditionalWriteStore & AsyncCasStore,
    S: WakerSink & Movable & Deinitable,
](
    mut store: TableStore[Store],
    mut op: AsyncGroupCommitOp,
    mut reactor: Reactor[S],
) raises -> Int64:
    """Resume a parked group commit after its op_id completed. Advances the
    in-flight create-CAS one step; on the WIN finalizes (fold the MERGED write-set
    + stamp the shared commit_lsn on every winner) + DONEs; on a 412 re-runs the
    prelude (re-arbitrate against the new head) + re-parks. Returns the next op_id
    to park on, or 0 when finished. IDEMPOTENT on terminal ops (a stray
    completion re-driving a finished op is a no-op)."""
    if op.is_done() or op.is_error():
        return Int64(0)
    if not op._append_inflight:
        op._set_error(
            String("group_commit_async_poll: no create-CAS in flight (logic)")
        )
        return Int64(0)
    var append = AsyncManifestAppendOp[Store].resume_inflight(
        op._candidate, op._base, op._merged_count
    )
    var prog = append.poll[S](store.wal_mut(), reactor)
    if prog.is_error():
        op._append_inflight = False
        var em = prog.err_text()
        if _is_lost_slot_412(em):
            store.lease_note_lost_slot()
            return _group_begin_attempt[Store, S](store, op, reactor)
        op._set_error(String("group_commit_async: create-CAS poll: ") + em)
        return Int64(0)
    if prog.is_pending():
        return prog.op_id
    return _group_after_cas_ready[Store, S](store, op, append^, reactor)


def _group_after_cas_ready[
    Store: ConditionalWriteStore & AsyncCasStore,
    S: WakerSink & Movable & Deinitable,
](
    mut store: TableStore[Store],
    mut op: AsyncGroupCommitOp,
    var append: AsyncManifestAppendOp[Store],
    mut reactor: Reactor[S],
) raises -> Int64:
    """The create-CAS completed READY (a WIN — the slot was taken). Finalize the
    MERGED write-set into the index at the won commit_lsn (using the STASHED
    winner partition the won body was built from — `op._merged_write_set` /
    `op._winner_idxs` / `op._outcome_skel`, captured at `_group_begin_attempt`),
    and stamp the shared commit_lsn on every winner. The partition is REUSED, NOT
    recomputed — so the finalized write-set is EXACTLY the one the won body
    encoded (no re-run, no drift across the park). ONLY the defensive take->None
    412 channel re-runs the WHOLE prelude (re-read head + re-arbitrate + re-OCC +
    re-merge) — that is the lost-slot path, not the win path."""
    op._append_inflight = False
    var maybe = append.take(store.wal_mut())
    _ = append^
    if maybe:
        var res = maybe.take()
        var commit_lsn = res.chunk_seq
        # Finalize the MERGED write-set (the STASHED partition's winners) on the
        # live store (server-local index) at the won commit_lsn.
        store.finalize_commit_win(
            commit_lsn, op._auth_head_seq, op._merged_write_set
        )
        # LEASE WIN-ADVANCE: the local head tracks the won tail
        # so the NEXT batch elides the per-batch LIST. The merged body occupies
        # [op._base, op._base + op._merged_count); next base offset is op._base +
        # op._merged_count (no-op when the flag is off).
        store.lease_note_win(commit_lsn, op._base + op._merged_count)
        # Build the per-member outcomes from the STASHED skeleton — stamp the
        # shared commit_lsn on every winner (its intra_batch_seq was already set
        # in the prelude). This uses EXACTLY the partition the won body was built
        # from (no re-run, no drift).
        var outcomes = op._outcome_skel.copy()
        for wi in range(len(op._winner_idxs)):
            outcomes[op._winner_idxs[wi]] = TableStoreGroupOutcome.win(commit_lsn, wi)
        op._finish(outcomes^)
        return Int64(0)
    # 412 via take->None (defensive) — re-run the prelude + re-park. LEASE: the
    # local head is stale (a sibling won the slot); invalidate so the re-run
    # re-LISTs the true tail.
    store.lease_note_lost_slot()
    return _group_begin_attempt[Store, S](store, op, reactor)
