# =============================================================================
# komira_comms_index/comms_index.mojo
#   The comms index: the generic mechanism and its API.
# =============================================================================
#
# A per-collection CAS-manifest DELTA-LOG of immutable index chunks plus a
# mutable `_HEAD` CAS pointer, compacted into immutable base chunks, all on an
# object store, with no always-on database. This file is the generic mechanism
# that mail flags, calendar sync and chat event logs each adopt by plugging a
# chunk body in.
#
# -----------------------------------------------------------------------------
# What this file stands on, and what it adds
# -----------------------------------------------------------------------------
# STANDS ON `komira_objectstore`:
#   * CasManifestStore[Store] — the immutable-chunks + mutable-`_HEAD` primitive.
#       - append()            -> the `If-None-Match` create-CAS, the single
#                                linearization point of an append.
#       - read_head()         -> the mutable `_HEAD` tail pointer (the cursor).
#       - read_chunk(seq)     -> immutable chunk read-back.
#       - num_chunks()        -> the tail length.
#       - read_log_start() / advance_log_start() -> the `_LOG_START` CAS pointer
#                               that drops the folded delta prefix (the
#                               compaction watermark), an `If-Match`
#                               compare-swap.
#       - schedule_for_delete() / reap() -> the lifecycle that reclaims the
#                               folded delta chunks (Staged, Published,
#                               ScheduledForDelete).
#   * ConditionalWriteStore — the backend seam (an S3 conditional store in
#       production, `InMemoryConditionalStore` in offline tests).
#
# ADDS:
#   1. The chunk-body codecs                  -> comms_chunk_codec.mojo
#                                               (KeyedDelta + the compacted-base
#                                               codec).
#   2. The read-fold (deltas over a base)     -> `read_state` below:
#       last-writer-wins per key by `seq`.
#   3. The compaction body (fold tail -> base) -> `compact` below.
#
# -----------------------------------------------------------------------------
# The `_HEAD` race-safety argument
# -----------------------------------------------------------------------------
# Every mutation is an APPEND of one immutable delta chunk via the manifest's
# `If-None-Match` create-CAS on the next slot K. The create-winner of slot K
# owns slot K — there is EXACTLY ONE winner, so the delta-log is gapless and
# totally ordered. A `_HEAD` "swap" in this model is NOT a lost-update-prone
# read-modify-write of a shared mutable cell; it is:
#
#   (a) for an APPEND: a `conditional_put(If-None-Match:*)` on a FRESH key
#       (slot K). Two racing appends targeting the same slot K: the store admits
#       exactly ONE creator; the LOSER sees a 412, RE-READS the now-advanced
#       head, recomputes K+1, and retries (the manifest's append retry loop).
#       No torn state: the loser never overwrote the winner's chunk
#       (create-if-absent refuses to clobber), and it cannot corrupt the winner
#       because it wrote a DIFFERENT key. The `_HEAD` cache object is advisory;
#       even if a stale `_HEAD` is read, the slot create-CAS is the sole
#       correctness arbiter and a stale read only costs one wasted attempt.
#
#   (b) for a COMPACTION watermark advance: an `If-Match` compare-swap on the
#       `_LOG_START` pointer (advance_log_start). Two racing compactions read
#       the same etag, both compute a base and try to CAS the pointer forward;
#       the store admits exactly ONE (the etag matches for only one); the LOSER
#       sees a 412 and RE-READS `_LOG_START`. The base chunk each wrote is an
#       immutable append (its own slot CAS), so a losing compaction's base is
#       simply a redundant chunk the reaper later collects — it can never
#       corrupt the surviving fold because `read_state` folds by `seq` (LWW) and
#       a base only ever LOWERS precedence (deltas appended after it still
#       win). ONE wins, losers re-read; no torn state.
#
# In BOTH cases the linearization point is the object store's OWN conditional
# create / compare-swap, which works across replicas AND across processes (no
# single-writer file lock). There is no in-place mutation of a shared cell
# anywhere; every "swap" is an atomic admit-exactly-one on the store, and the
# fold is order-independent under the `seq` LWW tiebreak.
#
# -----------------------------------------------------------------------------
# Encapsulation
# -----------------------------------------------------------------------------
#   * No pointer in any public signature — the surface is value / `List[UInt8]`
#     / `CommsState` (owned-List POD). The CAS round-trips flow through
#     CasManifestStore's already-encapsulated verbs.
#   * No wildcard origins, no `unsafe_from_address`, no `take_pointee`.
#   * The fold's live state is a plain `List[_FoldEntry]` (owned `List[UInt8]`
#     key/value), not a `Slab[T]` byte slab with a wildcard cast. `KeyedDelta` is
#     a stack value the fold holds, never a slab element.
# =============================================================================

from komira_objectstore.cas_manifest import (
    CasManifestStore,
    LogStart,
    ManifestHead,
    RetryPolicy,
)
from komira_objectstore.compact_window import (
    CompactionSource,
    CompactProduct,
    CompactRange,
    CompactSummary,
    compact_once,
)
from komira_objectstore.store import ConditionalWriteStore

from komira_comms_index.comms_chunk_codec import (
    KeyedDelta,
    DELTA_OP_PUT,
    DELTA_OP_TOMBSTONE,
    bytes_equal,
    decode_compacted_base,
    decode_keyed_delta,
    encode_compacted_base,
    encode_keyed_delta,
)


# =============================================================================
# CommsState — the materialized merged state (read_state's return)
# =============================================================================


struct CommsState(Movable, Deinitable):
    """The current merged state for one collection: the live set of
    (key, value) survivors after folding the compacted base + the delta tail
    last-writer-wins, with tombstoned keys removed.

    Two parallel owned-bytes lists (SoA, no byte slab). The
    comms server decodes each `value` with its own per-type codec (flag bitset
    / etag+dtstart+dtend / ciphertext_leaf+envelope); the substrate keeps them
    opaque. Iteration order is INSERTION order of first-seen keys (stable across
    a compact, since the base preserves it) — the comms server sorts/filters as
    it needs. `seqs` carries the winning per-key seq (for an incremental sync
    watermark)."""

    var keys: List[List[UInt8]]
    var values: List[List[UInt8]]
    var seqs: List[Int64]

    def __init__(out self):
        self.keys = List[List[UInt8]]()
        self.values = List[List[UInt8]]()
        self.seqs = List[Int64]()

    @always_inline
    def len(self) -> Int:
        return len(self.keys)

    def find(self, key: List[UInt8]) -> Int:
        """Index of `key` in the live state, or -1 if absent."""
        for i in range(len(self.keys)):
            if bytes_equal(self.keys[i], key):
                return i
        return -1

    def contains(self, key: List[UInt8]) -> Bool:
        return self.find(key) >= 0

    def value_for(self, key: List[UInt8]) raises -> List[UInt8]:
        """The live value bytes for `key`. Raises if `key` is absent (the
        caller checks `contains` first, or treats absence as not-found)."""
        var idx = self.find(key)
        if idx < 0:
            raise Error("CommsState.value_for: key not present")
        return self.values[idx].copy()


# =============================================================================
# CommsDelta — one classified post-token change (read_deltas_since's element)
# =============================================================================


struct CommsDelta(Copyable, Movable, Deinitable):
    """One per-key change in a `read_deltas_since(token)` slice: the key, its
    CURRENT value (empty when removed), the winning chunk_seq within the slice,
    and whether the key's LAST op in the slice was a TOMBSTONE (removed=True) or
    a PUT (removed=False).

    This is the generic INCREMENTAL-sync element the comms servers need
    that `read_state` cannot give: `read_state` folds the LIVE survivors and
    drops tombstones, which is the INITIAL-sync answer; an incremental sync since
    a token must ALSO surface the keys REMOVED after the token. RFC-6578
    sync-collection (calendar), CONDSTORE (mail), and `/sync?since=` (chat) all
    consume this same shape.

    A plain owned-bytes POD held in a `List[CommsDelta]` (no
    byte slab, no heap-owning Movable element). Copyable (its fields are
    `List[UInt8]` / Int64 / Bool) so it rides a plain `List`."""

    var key: List[UInt8]
    var value: List[UInt8]
    var seq: Int64
    var removed: Bool

    def __init__(
        out self, var key: List[UInt8], var value: List[UInt8], seq: Int64, removed: Bool
    ):
        self.key = key^
        self.value = value^
        self.seq = seq
        self.removed = removed


# =============================================================================
# _FoldEntry — one mutable fold slot (last-writer-wins accumulator)
# =============================================================================


struct _FoldEntry(Copyable, Movable, Deinitable):
    """A per-key fold accumulator: the current winning (value, seq) + whether
    the latest delta tombstoned the key. A plain owned-List record held in a
    `List[_FoldEntry]` — NOT a byte-slab element. Copyable (its
    fields are all Copyable: `List[UInt8]` / Int64 / Bool) so it can ride a
    plain `List` (which requires Copyable)."""

    var key: List[UInt8]
    var value: List[UInt8]
    var seq: Int64
    var tombstoned: Bool

    def __init__(
        out self, var key: List[UInt8], var value: List[UInt8], seq: Int64, tombstoned: Bool
    ):
        self.key = key^
        self.value = value^
        self.seq = seq
        self.tombstoned = tombstoned


# =============================================================================
# CommsIndex[Store] — the generic mechanism over a CAS-manifest
# =============================================================================


struct CommsIndex[Store: ConditionalWriteStore](Movable, Deinitable):
    """The comms index for ONE collection (one mailbox / one
    calendar / one chat room). A thin generic mechanism over
    `CasManifestStore[Store]`: every comms type (mail flags / calendar sync /
    chat event-log) constructs one of these against the SAME object store the
    blobs sit on, and plugs its own `KeyedDelta` body in.

    Fields:
      var _manifest: CasManifestStore[Store] — the immutable-chunks + mutable
                     `_HEAD` substrate (REUSED; owns the backend by value).

    The per-collection key prefix (`<root>/mail/<mailbox>/_idx`,
    `<root>/caldav/<collection>/_idx`, `<root>/chat/<room>/_log`) is the
    manifest lineage — passed at construction.
    """

    var _manifest: CasManifestStore[Self.Store]

    def __init__(
        out self,
        var store: Self.Store,
        var prefix: String,
        retry: RetryPolicy = RetryPolicy.default(),
    ):
        self._manifest = CasManifestStore[Self.Store](store^, prefix^, retry)

    @always_inline
    def prefix(self) -> String:
        return self._manifest.prefix()

    # =========================================================================
    # put_delta — append one immutable delta chunk (the mutable hot path)
    # =========================================================================

    def put_delta(mut self, delta: KeyedDelta) raises -> Int64:
        """Append one immutable `KeyedDelta` chunk to the per-collection
        delta-log via the manifest's `If-None-Match` create-CAS (the single
        linearization point). O(1): one small PUT + one `_HEAD`
        If-Match advance. Returns the committed chunk_seq (the durable global
        total-order / sync-token).

        A `\\Seen` flip, a UID assignment, a calendar add/remove, a chat event
        are ALL "append one delta chunk whose body says what changed" — no
        object is ever mutated in place. The race-safety is the manifest's
        create-winner-owns-slot-K property (see the module header `_HEAD`
        race-safety argument): concurrent appends serialize at the slot object,
        exactly one wins, the loser re-reads and retries."""
        var body = _tag_delta_chunk(encode_keyed_delta(delta))
        # record_count=1: ONE keyed delta per chunk. The manifest offset
        # semantics are unused for comms (we key by the delta's key, not a
        # contiguous offset); the chunk_seq IS the durable total-order.
        var res = self._manifest.append(body, Int64(1))
        return res.chunk_seq

    # =========================================================================
    # read_state — replay base + delta tail (the LSM read-fold)
    # =========================================================================

    def read_state(self) raises -> CommsState:
        """Materialize the current merged state by folding the compacted base
        split + the delta tail last-writer-wins, dropping tombstoned keys
        (read = fold the log tail over a base snapshot).

        The fold walks every live chunk `[log_start_seq .. head]` in chunk-seq
        order. A chunk is EITHER a compacted base (decoded as a survivor
        directory, lowest precedence) OR a single delta. For each (key) the
        winning record is the one with the HIGHEST `seq` (the per-key LWW
        tiebreak the caller controls); a TOMBSTONE at the winning seq removes
        the key. A base entry's `seq` is preserved, so a delta appended AFTER a
        base with a higher seq still wins.

        Order-independent under the `seq` tiebreak: re-reading the same chunks
        in any order yields the same merged state (the property that makes a
        losing compaction's redundant base harmless — module header).

        FRESH-READER CORRECTNESS: uses `read_head_fresh()`, NOT
        `read_head()`. Warm appends DEFER the durable `_HEAD` PUT (the broker
        flush-op-reduction); a cold-cache reader handle's `read_head()` trusts a
        stale-low durable `_HEAD` (its LIST-recovery escape fires only when
        `_HEAD` is ABSENT, never stale-low) and SILENTLY UNDERCOUNTS the tail.
        `read_head_fresh()` keeps the warm path 0-RPC but goes authoritative
        (LIST) on a cold cache — the true tail. This is a cross-handle
        CORRECTNESS read, exactly the verb's intended consumer."""
        var head = self._manifest.read_head_fresh()
        var ls = self._manifest.read_log_start()
        var start_seq = ls.log_start_seq
        if start_seq < Int64(0):
            start_seq = Int64(0)

        # The fold accumulator — a plain List, NOT a byte slab.
        var fold = List[_FoldEntry]()

        var seq = start_seq
        while seq <= head.chunk_seq:
            var chunk: List[UInt8]
            try:
                chunk = self._manifest.read_chunk(seq)
            except e:
                if _is_not_found(String(e)):
                    # A reaped prefix below log_start is legitimate; at-or-above
                    # log_start a hole would be a torn lineage, but the manifest
                    # is gapless-by-construction, so tolerate a transient and
                    # continue (read_state is a fold, not a recovery oracle).
                    seq += Int64(1)
                    continue
                raise e^
            # Discriminate base vs. delta by the leading version byte. A base
            # body begins with COMMS_BASE_VERSION (1) in a tagged frame; a delta
            # body begins with the op byte (PUT=0 / TOMBSTONE=1). We try base
            # first ONLY when the body is a base (compaction wrote it); the
            # caller never appends a raw base via put_delta, so the
            # discriminator is unambiguous: a base chunk is produced ONLY by
            # `compact` (which sets the record_count and the COMMS_BASE marker
            # via the dedicated path). We tag base chunks explicitly below
            # (see `_is_base_chunk`).
            if _is_base_chunk(chunk):
                var base_survivors = decode_compacted_base(_base_payload(chunk))
                for i in range(len(base_survivors)):
                    _fold_one(fold, base_survivors[i])
            else:
                var d = decode_keyed_delta(_delta_payload(chunk))
                _fold_one(fold, d)
            seq += Int64(1)

        # Project the fold into the live state (drop tombstoned keys).
        var out = CommsState()
        for i in range(len(fold)):
            ref e = fold[i]
            if e.tombstoned:
                continue
            out.keys.append(e.key.copy())
            out.values.append(e.value.copy())
            out.seqs.append(e.seq)
        return out^

    # =========================================================================
    # read_deltas_since — the INCREMENTAL slice (PUTs + TOMBSTONES after a token)
    # =========================================================================

    def read_deltas_since(self, token: Int64) raises -> List[CommsDelta]:
        """The classified per-key change slice in the chunk range `(token, head]`
        — the generic INCREMENTAL-sync read (RFC-6578 sync-collection /
        CONDSTORE / chat `/sync?since=`). Unlike `read_state` (which folds the
        LIVE survivors and DROPS tombstones — the INITIAL-sync answer), this
        surfaces every key TOUCHED after the token, INCLUDING the keys REMOVED
        after it (removed=True), so the caller can report precise removed-key
        tombstones.

        Each key collapses to its LAST op in the slice (chunk_seq order IS the
        total order): a key PUT (possibly several times) since the token -> ONE
        changed entry carrying the value + seq of its LAST PUT in the slice; a
        key TOMBSTONEd since the token -> ONE removed entry; a key PUT-then-
        TOMBSTONEd after the token -> removed (last op wins); a key TOMBSTONEd-
        then-re-PUT after the token -> changed (last op wins).

        Only DELTA chunks carry an op; a BASE chunk (a compaction product) in the
        range is SKIPPED (its survivors predate the token's relevance — a token
        below the compaction watermark `log_start_seq()` has had its incremental
        basis folded away, so the caller falls back to a full `read_state` resync
        when `token < log_start_seq()`). The slice is bounded (compaction keeps
        the delta tail short), so the per-key find-or-overwrite is cheap.

        FRESH-READER CORRECTNESS: `read_head_fresh()` (warm =
        0-RPC, cold = authoritative LIST) — a cold-cache reader must NOT trust a
        stale-low deferred durable `_HEAD` or it MISSES the deltas above it."""
        var head = self._manifest.read_head_fresh()

        # touched: one CommsDelta per key changed in the slice, the LAST op wins.
        var touched = List[CommsDelta]()

        var seq = token + Int64(1)
        if seq < Int64(0):
            seq = Int64(0)
        while seq <= head.chunk_seq:
            var chunk: List[UInt8]
            try:
                chunk = self._manifest.read_chunk(seq)
            except e:
                if _is_not_found(String(e)):
                    seq += Int64(1)
                    continue
                raise e^
            # A BASE chunk in the slice has no single op — its survivors are
            # pre-token state already accounted for; skip it.
            if _is_base_chunk(chunk):
                seq += Int64(1)
                continue
            var d = decode_keyed_delta(_delta_payload(chunk))
            var removed = d.is_tombstone()
            # Find-or-overwrite this key's touched entry (last op wins).
            var found = -1
            for j in range(len(touched)):
                if bytes_equal(touched[j].key, d.key):
                    found = j
                    break
            if found >= 0:
                touched[found] = CommsDelta(
                    d.key.copy(), d.value.copy(), seq, removed
                )
            else:
                touched.append(
                    CommsDelta(d.key.copy(), d.value.copy(), seq, removed)
                )
            seq += Int64(1)

        return touched^

    # =========================================================================
    # compact — fold the delta tail into an immutable LSM base, advance _HEAD
    # =========================================================================

    def compact(mut self) raises -> Int64:
        """Fold the accumulated delta tail into a new immutable base split,
        append it as a fresh chunk, and advance the `_LOG_START` watermark past
        the folded deltas (the `If-Match` compare-swap), then schedule+reap the
        retired delta chunks (compaction folds the delta tail
        into a new immutable base split).

        The merged base carries the latest-per-key survivors (tombstoned keys
        are DROPPED — the LSM tombstone-GC makes the removal permanent). Last-
        writer-wins per key by `seq`. `read_state` is IDENTICAL before/after a
        compact (the substrate's correctness contract): compaction changes the
        STORAGE (fewer chunks) but never the materialized state.

        Returns the chunk_seq of the new base. Idempotent-ish: a compact with
        an empty tail (nothing to fold) is a no-op returning the current head.

        Race-safety (module header (b)): two racing compactions read the same
        `_LOG_START` etag; the `If-Match` advance admits exactly one; the loser
        sees a 412 and re-reads. The losing compaction's base is a redundant
        immutable chunk the reaper later collects; it cannot corrupt the fold
        (read_state folds by `seq`, a base only lowers precedence).

        ── DRIVEN BY THE SHARED CompactWindow ENVELOPE ──
        This method is the canonical witness the `compact_window` primitive was
        modeled on (compact_window.mojo header). It ROUTES through the
        shared 6-step driver `compact_once[_CommsCompactionSource]`: the comms
        DOMAIN fold (LWW + tombstone-drop + base-chunk encode/append) lives in
        the conformer's `fold_and_materialize`; the K1 watermark-CAS-loser-no-op
        and the K2 floor-clamped reap loop are the shared `run_watermark_advance`
        / `run_clamped_retire` helpers the driver calls. The conformer plans
        the range, folds the survivors, appends the base, advances `_LOG_START`
        with the `If-Match` etag, and reaps `[start_seq, base_seq)`;
        `test_compaction_preserves_state` (read_state identical before/after)
        is the preservation check.

        The conformer holds a borrowed `Pointer` to `self._manifest` (a concrete
        origin — NOT a wildcard / `unsafe_from_address`; the trait surface
        itself crosses only typed values).
        `compact()` re-derives its Int64 return (base_seq
        on WON, the re-read head on a 412-LOST, head.chunk_seq on a NO-OP) from
        the driver's `CompactSummary` + the conformer's retained outputs."""
        # Construct the conformer + drive the shared envelope. Both the
        # conformer ctor (`manifest_o`) and `compact_once` (`Src`) rely on
        # ARGUMENT INFERENCE — a nested explicit `[Store, manifest_o]` does not
        # resolve in Mojo 1.0.
        var src = _CommsCompactionSource(Pointer(to=self._manifest))
        var summary = compact_once(src)

        if summary.is_noop():
            # NO-OP: nothing committed past the watermark (head.chunk_seq <
            # start_seq). It returns head.chunk_seq — the conformer
            # stashed it at plan time.
            return src.planned_head()

        if summary.lost():
            # 412-LOST: a concurrent compaction advanced `_LOG_START` first. Our
            # base is a harmless redundant chunk; the winner's watermark stands.
            # Re-read the head and return its chunk_seq; do NOT
            # reap (the winner owns the reap window — the driver already skipped
            # `run_clamped_retire` on the LOST branch).
            var fresh = self._manifest.read_head()
            return fresh.chunk_seq

        # WON: the base was appended, `_LOG_START` advanced, and the subsumed
        # deltas `[start_seq, base_seq)` were reaped (best-effort, the K2 floor-
        # clamped loop). Return the new base chunk_seq.
        return src.materialized_base_seq()

    # =========================================================================
    # purge — ERASE the whole collection's durable key family (the delete verb)
    # =========================================================================

    def purge(mut self) raises -> Int64:
        """ERASE every durable object this collection owns — the compacted base
        chunks, the whole delta tail, the tombstone markers, the dedup
        sentinels, `_HEAD` and `_LOG_START`. Returns the number of DELETEs
        issued. After this the lineage is EMPTY: a fresh `CommsIndex` bound to
        the SAME prefix reads back nothing and starts at head_seq == -1.

        WHY THIS EXISTS. Dropping a `CommsIndex`
        VALUE frees the in-process handle and touches NO object — the log is
        append-only and outlives the handle by design. That is right for a
        mailbox being closed and WRONG for a room being deleted: without a
        purge verb the caller has no way to erase, so "deleted" data stayed
        durable AND stayed reachable by anything that re-bound the prefix. A
        delete that only forgets is not a delete, and under GDPR erasure it is
        an exposure. This is the mechanism; the CALLER owns the policy of when
        a collection is erasable.

        CRASH SAFETY — IDEMPOTENT AND RESTART-COMPLETABLE. The purge is a
        SEQUENCE of DELETEs, not a transaction. A crash between object N and
        N+1 leaves a partially-purged lineage, and that state is recovered by
        simply CALLING THIS VERB AGAIN: delete-of-absent succeeds on S3 (and on
        every store conformer here), so re-running over already-deleted objects
        is a no-op, and the objects that survived the crash are enumerated
        fresh by the LIST and removed. There is no state a retry cannot finish.

        The ONE ordering property that makes the half-purged state SAFE rather
        than merely recoverable: `_HEAD` and `_LOG_START` are deleted LAST
        (see `CasManifestStore.purge_all`), AFTER every chunk. So a crash
        mid-purge leaves a lineage whose surviving `_HEAD` points at a chunk
        range that is missing its low end — which `read_state` folds as FEWER
        events, never as MORE, and never as a torn/undecodable chunk. A
        half-purged room therefore reads as PARTIALLY erased, never as live and
        never as corrupt, and the retry completes the erasure."""
        return self._manifest.purge_all()

    # =========================================================================
    # Introspection (for tests + the comms servers' incremental sync)
    # =========================================================================

    def head_seq(self) raises -> Int64:
        """The current tail chunk_seq (-1 if empty). The durable sync-token
        watermark: a client that has seen up to seq S reads deltas with
        chunk_seq > S for an incremental sync.

        FRESH-READER CORRECTNESS: `read_head_fresh()` so a
        cold-cache reader handle reports the TRUE tail, not the stale-low
        deferred durable `_HEAD` (warm = 0-RPC, cold = authoritative LIST)."""
        var head = self._manifest.read_head_fresh()
        return head.chunk_seq

    def log_start_seq(self) raises -> Int64:
        """The lowest still-live chunk_seq (the compaction watermark)."""
        var ls = self._manifest.read_log_start()
        return ls.log_start_seq

    def num_live_chunks(self) raises -> Int64:
        """The number of live chunks in the delta-log + base (head - log_start
        + 1). Shrinks after a compact — the storage-cost proof.

        FRESH-READER CORRECTNESS: `read_head_fresh()` so a
        cold-cache reader handle counts the TRUE tail, not a stale-low deferred
        durable `_HEAD` (warm = 0-RPC, cold = authoritative LIST)."""
        var head = self._manifest.read_head_fresh()
        var ls = self._manifest.read_log_start()
        var start = ls.log_start_seq
        if start < Int64(0):
            start = Int64(0)
        if head.chunk_seq < start:
            return Int64(0)
        return head.chunk_seq - start + Int64(1)


# =============================================================================
# _CommsCompactionSource — the comms conformer for the shared CompactWindow
# =============================================================================
#
# The `CompactionSource` (komira_objectstore.compact_window) conformer for the
# comms compaction — the canonical witness the primitive was modeled on
# (compact_window.mojo header). It plugs the comms
# DOMAIN fold/encode/output + watermark + retire into the shared 6-step envelope;
# the driver (`compact_once`) supplies the RESUME/PLAN gating, the K1 watermark-
# CAS-loser-no-op (run_watermark_advance) and the K2 floor-clamped reap
# (run_clamped_retire). The conformer performs fold, base append, watermark
# advance and reap in that order, over the `_LOG_START` `If-Match` etag read at
# plan time.
#
# ── encapsulation ─────────────────────────────────────────────────────────────
#   * OutputRef = Int64 (the base chunk_seq) — POD; the trait surface crosses
#     ONLY typed values (CompactRange / CompactProduct[Int64] / Int64 / Bool).
#   * The conformer holds a BORROWED `Pointer[CasManifestStore[Store], origin]`
#     to the index's manifest — a CONCRETE origin the compiler tracks, NOT a
#     wildcard (`MutAnyOrigin` / `MutExternalOrigin`), NOT `unsafe_from_address`,
#     NOT `take_pointee`. The pointer never crosses the TRAIT seam (the driver /
#     helpers see only typed values); it is a private internal field.
#   * The fold accumulator is a plain `List[_FoldEntry]` (owned `List[UInt8]`
#     key/value), NOT a byte slab of heap-owning Movable elements, the same
#     shape `read_state` uses.


struct _CommsCompactionSource[
    Store: ConditionalWriteStore,
    manifest_o: Origin[mut=True],
](CompactionSource, Movable, Deinitable):
    """The comms `CompactionSource`: drives ONE compaction pass through
    the shared CompactWindow envelope. OutputRef = the base chunk_seq (Int64).

    Fields:
      var _m: Pointer[CasManifestStore[Store], manifest_o] — borrowed handle to
              the owning CommsIndex's manifest (concrete origin; private).
      var _ls_etag: String — the `_LOG_START` etag snapshotted at plan time (the
              `If-Match` precondition for the later advance).
      var _planned_head: Int64 — the head chunk_seq at plan time (the
              NO-OP return value: `head.chunk_seq`).
      var _base_seq: Int64 — the base chunk_seq this pass appended (the
              WON return value; the OutputRef the driver's summary intentionally
              drops, retained here for `compact()`'s Int64 return).
    """

    comptime OutputRef = Int64

    # SAFETY: `manifest_o` is the concrete origin of the owning CommsIndex's
    # `_manifest` field, taken from `Pointer(to=self._manifest)` inside
    # `CommsIndex.compact(mut self)`. This type is private and is constructed
    # only there, as a local `src` that is destroyed before `compact` returns, so
    # it cannot outlive the `mut self` borrow that keeps `_manifest` alive. While
    # `compact_once(src)` runs, `_manifest` is touched only through this pointer;
    # `compact` reads `self._manifest` again only after the pass, when `src`
    # makes no further manifest calls.
    var _m: Pointer[CasManifestStore[Self.Store], Self.manifest_o]
    var _ls_etag: String
    var _planned_head: Int64
    var _base_seq: Int64

    def __init__(
        out self,
        m: Pointer[CasManifestStore[Self.Store], Self.manifest_o],
    ):
        self._m = m
        self._ls_etag = String("")
        self._planned_head = Int64(-1)
        self._base_seq = Int64(-1)

    @always_inline
    def planned_head(self) -> Int64:
        """The head chunk_seq at plan time — the NO-OP return."""
        return self._planned_head

    @always_inline
    def materialized_base_seq(self) -> Int64:
        """The base chunk_seq this pass appended — the WON return."""
        return self._base_seq

    # ---- steps 1+2 (RESUME + PLAN): read HEAD + _LOG_START, derive the range --
    def plan_range(mut self) raises -> CompactRange:
        # FRESH-READER CORRECTNESS: `read_head_fresh()` so a
        # cold-cache compactor handle plans over the TRUE tail, never a stale-low
        # deferred durable `_HEAD` (which would fold a SHORT range + leave the
        # deferred tail un-folded). Warm = 0-RPC, cold = authoritative LIST.
        var head = self._m[].read_head_fresh()
        var ls = self._m[].read_log_start()
        var start_seq = ls.log_start_seq
        if start_seq < Int64(0):
            start_seq = Int64(0)
        # Snapshot the plan-time head (the NO-OP return) + the `_LOG_START` etag
        # (the `If-Match` precondition for advance).
        self._planned_head = head.chunk_seq
        self._ls_etag = ls.etag
        # Nothing committed yet, or only the watermark — no tail to fold (the
        # `head.chunk_seq < start_seq` early-exit).
        if head.chunk_seq < start_seq:
            return CompactRange.noop()
        return CompactRange(lo=start_seq, hi=head.chunk_seq)

    # ---- steps 3+4 (FOLD + MATERIALIZE): fold [lo,hi] survivors, append base ---
    def fold_and_materialize(
        mut self, range: CompactRange
    ) raises -> CompactProduct[Self.OutputRef]:
        # 1. Fold every live chunk [lo .. hi] into survivors (the DOMAIN fold —
        #    LWW per key by seq).
        var fold = List[_FoldEntry]()
        var seq = range.lo
        while seq <= range.hi:
            var chunk: List[UInt8]
            try:
                chunk = self._m[].read_chunk(seq)
            except e:
                if _is_not_found(String(e)):
                    seq += Int64(1)
                    continue
                raise e^
            if _is_base_chunk(chunk):
                var base_survivors = decode_compacted_base(_base_payload(chunk))
                # NOTE: the `range` parameter (CompactRange) shadows the builtin
                # `range()` here, so iterate via an explicit index `while`.
                var bi = 0
                while bi < len(base_survivors):
                    _fold_one(fold, base_survivors[bi])
                    bi += 1
            else:
                var d = decode_keyed_delta(_delta_payload(chunk))
                _fold_one(fold, d)
            seq += Int64(1)

        # 2. Project the live survivors (drop tombstones) into a base.
        #    Explicit-index `while` — the `range` param shadows
        #    the builtin `range()`.
        var survivors = List[KeyedDelta]()
        var fi = 0
        while fi < len(fold):
            ref e = fold[fi]
            if not e.tombstoned:
                survivors.append(
                    KeyedDelta(DELTA_OP_PUT, e.seq, e.key.copy(), e.value.copy())
                )
            fi += 1

        # 3. Append the base as a fresh immutable chunk (own slot CAS).
        #    The base_seq is the OutputRef + the materialized
        #    high-water input (base_seq == hi + 1; everything below it is folded).
        var base_body = _tag_base_chunk(encode_compacted_base(survivors))
        var base_res = self._m[].append(base_body, Int64(1))
        self._base_seq = base_res.chunk_seq

        return CompactProduct[Self.OutputRef](
            covered=range,
            output=self._base_seq,
            materialized_thru=range.hi,
            row_count=Int64(len(survivors)),
        )

    # ---- step 5 (ADVANCE): `_LOG_START` `If-Match` CAS; 412 => False (lost) ----
    def advance_watermark(
        mut self, product: CompactProduct[Self.OutputRef]
    ) raises -> Bool:
        # The new log-start is the FIRST UN-FOLDED slot — `covered.hi + 1`, NOT
        # `product.output` (the base chunk_seq). The base appends as its own
        # immutable chunk via the slot create-CAS; under a CONCURRENT put_delta
        # that lands DURING the fold (after PLAN read HEAD, before the base
        # create wins), the base 412s on the now-taken slot and re-anchors ONE
        # SLOT HIGHER, so `base_seq > covered.hi + 1`. Advancing `_LOG_START` to
        # `base_seq` would then SKIP every concurrent delta in
        # `[covered.hi + 1, base_seq - 1]` at the next read — a SILENT DATA LOSS. We instead advance to `covered.hi + 1`: everything
        # the base actually folded (`[lo, covered.hi]`) drops; the base chunk +
        # any concurrent deltas above the folded range stay live and `read_state`
        # MERGE-folds them (a base is NOT a reset — survivors keep their per-key
        # seq, so a concurrent delta in the skipped band still merges correctly).
        # `safe_retire_floor` already returns `materialized_thru + 1 ==
        # covered.hi + 1`, so the reap window is unchanged + consistent with this.
        try:
            var new_ls = product.covered.hi + Int64(1)
            _ = self._m[].advance_log_start(
                new_ls, new_ls, self._ls_etag
            )
        except e:
            if _is_precondition(String(e)):
                # 412: a concurrent compaction advanced `_LOG_START` first. Report
                # LOST — our base is a harmless redundant chunk; the driver's K1
                # helper turns this into the lost-redundant exit (no reap).
                return False
            raise e^
        return True

    # ---- step 6 (RETIRE), one input: schedule_for_delete + reap (best-effort) -
    def retire_input(mut self, idx: Int64) raises:
        # Tombstone then reap the now-subsumed delta chunk (for ONE chunk). A
        # raise is treated best-effort by the K2 helper (run_clamped_retire
        # swallows it): a reaped chunk below the advanced log_start is
        # legitimate; read_state never reads it again.
        self._m[].schedule_for_delete(idx)
        self._m[].reap(idx)

    # ---- the K2 clamp: min(desired, materialized_thru + 1) ----
    def safe_retire_floor(
        self, product: CompactProduct[Self.OutputRef]
    ) raises -> Int64:
        # The reap window is [start_seq, base_seq), so the UNCLAMPED desired IS
        # the base chunk_seq (product.output). The
        # crash-atomicity clamp then caps at what the base durably covers
        # (materialized_thru + 1). In the normal fully-materialized case
        # base_seq == hi + 1 == materialized_thru + 1, so the floor == base_seq.
        # The clamp only bites in the partial-materialize crash case, where it
        # keeps crash-atomicity (never reaps an input above the durable base)
        # without altering the observable read_state.
        var desired = product.output  # base_seq
        var clamped = product.materialized_thru + Int64(1)
        if clamped < desired:
            return clamped
        return desired


# =============================================================================
# Fold helper — apply one KeyedDelta to the LWW accumulator
# =============================================================================


def _fold_one(mut fold: List[_FoldEntry], d: KeyedDelta):
    """Last-writer-wins fold of one delta into the accumulator. The winner per
    key is the record with the HIGHEST `seq`; a TOMBSTONE at the winning seq
    marks the key removed (projected out at read). A later PUT with a higher
    seq un-removes it. Linear scan over the (bounded — compaction keeps the
    tail short) accumulator, the search `merge._merge_one_terms` shape."""
    for i in range(len(fold)):
        if bytes_equal(fold[i].key, d.key):
            # Existing fold slot for this key — keep the higher-seq winner.
            if d.seq >= fold[i].seq:
                fold[i].value = d.value.copy()
                fold[i].seq = d.seq
                fold[i].tombstoned = d.is_tombstone()
            return
    # First time we see this key.
    fold.append(
        _FoldEntry(d.key.copy(), d.value.copy(), d.seq, d.is_tombstone())
    )


# =============================================================================
# Base-chunk tagging — distinguish a compacted base from a raw delta in the log
# =============================================================================
#
# Both bases and deltas live in the SAME manifest as chunks. The read-fold must
# tell them apart. We prepend a 1-byte CHUNK_KIND tag to every chunk body:
#   CHUNK_KIND_DELTA (0) → the rest is a KeyedDelta body.
#   CHUNK_KIND_BASE  (1) → the rest is a compacted-base body.
# put_delta tags DELTA; compact tags BASE. This is unambiguous + tiny (one byte)
# and keeps the codecs (comms_chunk_codec) pure — the discriminator is a framing
# concern owned HERE, not in the per-type codec.

comptime CHUNK_KIND_DELTA: UInt8 = 0
comptime CHUNK_KIND_BASE: UInt8 = 1


@always_inline
def _is_base_chunk(chunk: List[UInt8]) -> Bool:
    return len(chunk) >= 1 and chunk[0] == CHUNK_KIND_BASE


@always_inline
def _base_payload(chunk: List[UInt8]) -> List[UInt8]:
    """Strip the CHUNK_KIND_BASE tag, returning the compacted-base body."""
    var out = List[UInt8]()
    for i in range(1, len(chunk)):
        out.append(chunk[i])
    return out^


@always_inline
def _delta_payload(chunk: List[UInt8]) -> List[UInt8]:
    """Strip the CHUNK_KIND_DELTA tag, returning the KeyedDelta body."""
    var out = List[UInt8]()
    for i in range(1, len(chunk)):
        out.append(chunk[i])
    return out^


@always_inline
def _tag_base_chunk(var base_body: List[UInt8]) -> List[UInt8]:
    """Prepend the CHUNK_KIND_BASE tag to a compacted-base body."""
    var out = List[UInt8]()
    out.append(CHUNK_KIND_BASE)
    for i in range(len(base_body)):
        out.append(base_body[i])
    return out^


@always_inline
def _tag_delta_chunk(var delta_body: List[UInt8]) -> List[UInt8]:
    """Prepend the CHUNK_KIND_DELTA tag to a KeyedDelta body."""
    var out = List[UInt8]()
    out.append(CHUNK_KIND_DELTA)
    for i in range(len(delta_body)):
        out.append(delta_body[i])
    return out^


# =============================================================================
# StoreError taxonomy probes (mirror cas_manifest's `_is_not_found` /
# `_is_precondition` — re-derived locally to avoid importing a private helper).
# =============================================================================


@always_inline
def _is_not_found(msg: String) -> Bool:
    return _contains(msg, "not_found") or _contains(msg, "(404)")


@always_inline
def _is_precondition(msg: String) -> Bool:
    return _contains(msg, "precondition") or _contains(msg, "(412)")


@always_inline
def _contains(haystack: String, needle: String) -> Bool:
    var h = haystack.as_bytes()
    var n = needle.as_bytes()
    if len(n) == 0:
        return True
    if len(h) < len(n):
        return False
    for i in range(len(h) - len(n) + 1):
        var ok = True
        for j in range(len(n)):
            if h[i + j] != n[j]:
                ok = False
                break
        if ok:
            return True
    return False
