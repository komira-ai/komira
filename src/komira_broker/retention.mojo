# =============================================================================
# komira_broker/retention.mojo
#   Time/size retention + grace-gated reaper
# =============================================================================
#
# Komira message broker — the RETENTION pass + the REAP worker. Retention is a
# metadata operation, time- or size-based: a retention sweep appends a
# tombstone marker (advancing the partition's log-start offset) and a
# background worker deletes the now-unreferenced segment objects. No data
# movement.
#
# This module is PURE-decision (`RetentionPolicy.evaluate`, deterministic, no
# store) PLUS two store-driving orchestrators (`RetentionPass`, `ReapWorker`)
# that compose the persisted CAS-manifest lifecycle FSM:
#
#   RetentionPass.run(manifest, now_ms):
#     1. SNAPSHOT read_head ONCE (the pass operates on a consistent tail).
#     2. Read the persisted log_start (the first still-live chunk seq/offset).
#     3. Iterate live chunks [log_start_seq, head_chunk) — decode each
#        ManifestBody (creation_ts_ms + segment_bytes), build the per-chunk
#        metadata snapshot.  NEVER includes the active/last chunk (head_chunk).
#     4. RetentionPolicy.evaluate → how many OLDEST chunks to retire.
#     5. For each retiring chunk: schedule_for_delete_at (PERSISTED tombstone).
#     6. ADVANCE the persisted log_start atomically (If-Match CAS) to the new
#        first-live (seq, absolute offset) — so consume keeps correct absolute
#        offsets for survivors and the next pass starts above it.
#     7. ASSERT survivor offset contiguity (fail-loud on any gap — a retention
#        bug must never silently renumber the log).
#
#   ReapWorker.run(manifest, now_ms, grace_ms):
#     Read `_LOG_START` ONCE (fail closed: an unreadable pointer reaps
#     nothing). For each tombstone_seq BELOW it: read its schedule_ts; reap
#     ONLY when `now_ms - schedule_ts >= grace_ms` (the grace window).
#     A tombstone AT OR ABOVE it sits on a live chunk (step 6 failed or the
#     process died between 5 and 6): skipped and counted, never deleted, and
#     reclaimable once a later pass advances. Idempotent.
#     A chunk with a MOVED marker (written by the sub-lineage migration and the
#     segment fold: `_base` now references its `.seg`) is reaped as a chunk key
#     only, whatever plain tombstone it also carries, and its grace counts from
#     the MOVED marker's ts. The `.seg` is `_base`'s to reclaim.
#
# ORDER (tombstone, THEN advance) is deliberate. A crash between the two
# strands tombstones on live chunks, which the reaper skips, and the next pass
# re-tombstones the same chunks (they are still at the log start, still out of
# policy) and advances. Advance-first would instead leave chunks below the log
# start that no pass ever revisits (a pass starts AT the log start): a
# permanent leak.
#
# Grace gating lives HERE (above the CasManifestStore.reap verb, which reaps
# unconditionally once tombstoned) so the trait surface stays clock-less and
# the grace policy is a worker concern.
#
# -----------------------------------------------------------------------------
# Encapsulation discipline
# -----------------------------------------------------------------------------
#   * ZERO UnsafePointer in any signature (surface is value / POD / String).
#   * ZERO wildcard origins / `unsafe_from_address`.
#   * The manifest substrate is taken BY MUTABLE REF (`mut manifest`) — a
#     CasManifestStore is a Movable struct encapsulating its own internals; no
#     pointer crosses this boundary.
#   * All retention state is POD ints in stack values; the per-chunk
#     metadata is a `List[_ChunkMeta]` of plain Int64/String fields, NOT a
#     byte-slab element with a heap-owning field under a wildcard cast.
# =============================================================================

from komira_objectstore.cas_manifest import CasManifestStore, LogStart
from komira_objectstore.path import Path
from komira_objectstore.store import ConditionalWriteStore

from .manifest_body import ManifestBody
from .sublineage_rollout_metrics import (
    SubLineageRolloutMetrics,
    audit_segment_contiguity,
)


# =============================================================================
# RetentionPolicy — the per-partition retention configuration + the decision.
# =============================================================================


@fieldwise_init
struct RetentionPolicy(
    Copyable, ImplicitlyCopyable, Movable, Deinitable
):
    """Time/size retention configuration. POD.

    Field layout:
      var retention_ms: Int64    — tombstone a chunk once
                                   `now - creation_ts_ms > retention_ms`.
                                   `-1` == disabled (infinite, the default).
      var retention_bytes: Int64 — tombstone oldest chunks until cumulative
                                   live bytes from log_start <= retention_bytes.
                                   `-1` == disabled (the default).
    """

    var retention_ms: Int64
    var retention_bytes: Int64

    @staticmethod
    def disabled() -> RetentionPolicy:
        return RetentionPolicy(Int64(-1), Int64(-1))

    @staticmethod
    def time_based(retention_ms: Int64) -> RetentionPolicy:
        return RetentionPolicy(retention_ms, Int64(-1))

    @staticmethod
    def size_based(retention_bytes: Int64) -> RetentionPolicy:
        return RetentionPolicy(Int64(-1), retention_bytes)

    @always_inline
    def is_enabled(self) -> Bool:
        return self.retention_ms >= Int64(0) or self.retention_bytes >= Int64(0)


# =============================================================================
# _ChunkMeta — the per-chunk snapshot the policy evaluates over.
# =============================================================================


@fieldwise_init
struct _ChunkMeta(Copyable, Movable, Deinitable):
    """One live chunk's retention-relevant metadata (snapshot, POD-ish).

    Field layout:
      var chunk_seq: Int64       — the manifest chunk slot.
      var base_offset: Int64     — first ABSOLUTE offset this chunk holds.
      var record_count: Int64    — records in this chunk.
      var segment_bytes: Int64   — EXACT segment size (-1 if legacy / unknown).
      var creation_ts_ms: Int64  — flush wall clock ms (-1 if legacy / unknown).
    """

    var chunk_seq: Int64
    var base_offset: Int64
    var record_count: Int64
    var segment_bytes: Int64
    var creation_ts_ms: Int64


# =============================================================================
# RetentionPolicy.evaluate — the PURE decision (no store; deterministic).
# =============================================================================
#
# Given the OLDEST-FIRST list of live chunks (excluding the active/last chunk,
# which is NEVER retired) + `now_ms`, return the COUNT of leading (oldest)
# chunks to tombstone. Both dimensions retire oldest-first and combine by UNION
# (a chunk is retired if EITHER time OR size says so). Size: walk newest→oldest
# accumulating live bytes; once cumulative bytes (from a candidate point to the
# tail) fit under retention_bytes, everything OLDER than that point is retired.
# -----------------------------------------------------------------------------


def evaluate_retention(
    policy: RetentionPolicy,
    chunks: List[_ChunkMeta],  # oldest-first; EXCLUDES the active chunk
    now_ms: Int64,
) -> Int64:
    """Return how many leading (oldest) chunks to tombstone. `chunks` MUST NOT
    include the active/last chunk (the caller excludes it). Never returns more
    than `len(chunks)` (the active chunk is always kept). 0 if nothing is out
    of policy or retention is disabled."""
    var n = len(chunks)
    if n == 0 or not policy.is_enabled():
        return Int64(0)

    # --- time dimension: tombstone leading chunks older than retention_ms ---
    var time_retire = 0
    if policy.retention_ms >= Int64(0):
        for i in range(n):
            var ts = chunks[i].creation_ts_ms
            # Unknown ts (legacy body) → SKIP the time dimension for this chunk
            # (never retire on a missing signal). Stop at the first chunk that
            # is in-policy (oldest-first → once one is young, the rest are too).
            if ts < Int64(0):
                break
            if now_ms - ts > policy.retention_ms:
                time_retire = i + 1
            else:
                break

    # --- size dimension: keep the newest chunks whose cumulative bytes fit ---
    var size_retire = 0
    if policy.retention_bytes >= Int64(0):
        # Walk newest→oldest accumulating live bytes; the kept window is the
        # newest suffix whose cumulative bytes <= retention_bytes. Everything
        # older than the kept window is retired. Unknown size (legacy) counts
        # as 0 bytes (cannot enforce size on a missing signal → never forces a
        # retire by itself, but does not block younger chunks from being kept).
        var cumulative = Int64(0)
        var keep_from = n  # index of the oldest KEPT chunk (default: keep none)
        var j = n - 1
        while j >= 0:
            var sb = chunks[j].segment_bytes
            var add = sb if sb >= Int64(0) else Int64(0)
            if cumulative + add <= policy.retention_bytes:
                cumulative += add
                keep_from = j
                j -= 1
            else:
                break
        size_retire = keep_from  # chunks [0, keep_from) are retired

    # union: retire the MAX of the two dimensions (oldest-first, so a larger
    # count subsumes a smaller one).
    var retire = time_retire if time_retire > size_retire else size_retire
    if retire > n:
        retire = n
    return Int64(retire)


# =============================================================================
# RetentionResult — what a RetentionPass.run reports.
# =============================================================================


@fieldwise_init
struct RetentionResult(Copyable, Movable, Deinitable):
    """Outcome of one retention pass.

    Field layout:
      var tombstoned_count: Int64       — chunks moved to ScheduledForDelete.
      var new_log_start_seq: Int64      — the lowest still-live chunk_seq after
                                          this pass (== prior if nothing retired).
      var new_log_start_offset: Int64   — the first still-readable abs offset.
      var advanced_log_start: Bool      — True iff the log_start pointer moved.
    """

    var tombstoned_count: Int64
    var new_log_start_seq: Int64
    var new_log_start_offset: Int64
    var advanced_log_start: Bool


# =============================================================================
# RetentionPass — the orchestrator (snapshot → evaluate → tombstone → advance).
# =============================================================================


struct RetentionPass[Storage: ConditionalWriteStore](
    Movable, Deinitable
):
    """Runs one retention pass over a partition's CasManifestStore. Stateless
    over the manifest (it reads a fresh snapshot each run); holds only the
    policy."""

    var _policy: RetentionPolicy

    def __init__(out self, policy: RetentionPolicy):
        self._policy = policy

    def run(
        mut self,
        mut manifest: CasManifestStore[Self.Storage],
        now_ms: Int64,
    ) raises -> RetentionResult:
        """Execute one retention pass:
          1. SNAPSHOT read_head once.
          2. Read the persisted log_start.
          3. Build the live-chunk snapshot [log_start_seq, head_chunk) —
             EXCLUDING the active/last chunk (head_chunk), which is never
             retired.
          4. evaluate → count of oldest chunks to retire.
          5. schedule_for_delete_at each (PERSISTED tombstone).
          6. advance_log_start atomically (If-Match CAS).
          7. assert survivor offset contiguity (fail-loud).
        Returns the RetentionResult.
        """
        # The retention
        # pass is a CORRECTNESS consumer of the tail — it must see EVERY committed
        # chunk to retire the correct count of oldest ones (and to derive the new
        # log_start). `read_head()` prefers the per-instance LOCAL `_HEAD` cache and
        # (on a cold/fresh instance) reads the DURABLE `_HEAD` object, whose advance
        # is DEFERRED off the warm-append ack path — so a fresh retention-driver
        # instance over a producer's lineage would see a STALE-LOW tail (the durable
        # `_HEAD` lags the true tail by up to `_HEAD_ADVANCE_DEFER_CADENCE` chunks),
        # mis-derive `head_chunk`, and (if it lagged to == log_start_seq) early-out
        # with `tombstoned_count = 0` even though older chunks are out of policy.
        # Use the LIST-recovered AUTHORITATIVE tail — the same contract the
        # idempotent-producer dedupe consumer follows (a stale-low head would MISS a
        # just-committed batch). The chunk objects themselves are always durable
        # (the chunk create-CAS is unconditional), so the authoritative replay sees
        # them regardless of the deferred `_HEAD`.
        var head = manifest.read_head_authoritative()
        var head_chunk = head.chunk_seq  # highest committed seq (-1 = empty)
        var ls = manifest.read_log_start()
        var log_start_seq = ls.log_start_seq

        # Empty / single-chunk manifest: nothing to retire (the active chunk is
        # always kept). head_chunk == -1 (empty) or log_start_seq >= head_chunk
        # (only the active chunk is live).
        if head_chunk < Int64(0) or log_start_seq >= head_chunk:
            return RetentionResult(
                tombstoned_count=Int64(0),
                new_log_start_seq=ls.log_start_seq,
                new_log_start_offset=ls.log_start_offset,
                advanced_log_start=False,
            )

        # Build the live-chunk snapshot for seqs [log_start_seq, head_chunk)
        # (the active/last chunk head_chunk is EXCLUDED — never retired). Seed
        # the running base offset from the persisted log_start_offset so the
        # snapshot's base offsets are the correct ABSOLUTE offsets after prior
        # truncation (never renumber).
        var chunks = List[_ChunkMeta]()
        var running_base = ls.log_start_offset
        var seq = log_start_seq
        while seq < head_chunk:
            var body_bytes = manifest.read_chunk(seq)
            var body = ManifestBody.decode(body_bytes)
            chunks.append(
                _ChunkMeta(
                    chunk_seq=seq,
                    base_offset=running_base,
                    record_count=body.record_count,
                    segment_bytes=body.segment_bytes,
                    creation_ts_ms=body.creation_ts_ms,
                )
            )
            running_base += body.record_count
            seq += Int64(1)

        var retire = evaluate_retention(self._policy, chunks, now_ms)
        if retire <= Int64(0):
            return RetentionResult(
                tombstoned_count=Int64(0),
                new_log_start_seq=ls.log_start_seq,
                new_log_start_offset=ls.log_start_offset,
                advanced_log_start=False,
            )

        # Tombstone the leading `retire` chunks (oldest-first), PERSISTED.
        var i = 0
        while i < Int(retire):
            manifest.schedule_for_delete_at(chunks[i].chunk_seq, now_ms)
            i += 1

        # The new first-live chunk:
        #   * if `retire < len(chunks)`, it is `chunks[retire]` (a snapshot
        #     chunk that survives);
        #   * if `retire == len(chunks)`, ALL snapshot (non-active) chunks were
        #     retired, so the new first-live chunk is the ACTIVE chunk
        #     (`head_chunk`), which is NOT in the snapshot. Its base offset is
        #     `running_base` (the accumulated sum past the last snapshot chunk).
        # (evaluate_retention never returns more than len(chunks), so the
        # active chunk is ALWAYS kept.)
        var new_seq: Int64
        var new_offset: Int64
        if Int(retire) < len(chunks):
            new_seq = chunks[Int(retire)].chunk_seq
            new_offset = chunks[Int(retire)].base_offset
        else:
            new_seq = head_chunk
            new_offset = running_base

        # ASSERT survivor offset contiguity (fail-loud): the new first-live
        # chunk's base must equal the running sum from the old log_start (no
        # gap introduced by tombstoning). chunks[0..retire) record counts +
        # the old log_start_offset must equal new_offset.
        var expect_offset = ls.log_start_offset
        var k = 0
        while k < Int(retire):
            expect_offset += chunks[k].record_count
            k += 1
        if expect_offset != new_offset:
            raise Error(  # cov: unreachable new_offset is the same sum: chunks[retire].base_offset, or running_base when every snapshot chunk retires
                "RetentionPass: survivor offset contiguity broken — expected"  # cov: unreachable see the line above
                " new log_start_offset "
                + String(expect_offset)  # cov: unreachable see the line above
                + " got "  # cov: unreachable see the line above
                + String(new_offset)  # cov: unreachable see the line above
                + " (retention must NEVER renumber the log)"  # cov: unreachable see the line above
            )

        # Advance the persisted log_start atomically (If-Match CAS). On a
        # stale etag (a concurrent pass / driver won), re-read and retry the
        # advance — bounded; the tombstones are already idempotently persisted.
        # If this raises, the tombstones above stay on live chunks: ReapWorker
        # skips them, and the next pass re-tombstones and re-advances.
        var advanced = self._advance_log_start_cas(
            manifest, new_seq, new_offset
        )

        return RetentionResult(
            tombstoned_count=retire,
            new_log_start_seq=new_seq,
            new_log_start_offset=new_offset,
            advanced_log_start=advanced,
        )

    def run_with_rollout_audit(
        mut self,
        mut manifest: CasManifestStore[Self.Storage],
        now_ms: Int64,
        mut rollout: SubLineageRolloutMetrics,
    ) raises -> RetentionResult:
        """Rollout monitoring: the FORWARD-ONLY
        canary variant of `run`. Behaves EXACTLY like `run` (same tombstone /
        advance / contiguity-fail-loud), but ALSO emits the OFFSET-CONTIGUITY
        AUDIT signal (signal 3) into the live `rollout` metrics holder — riding
        the SAME chunk-metadata walk `run` already builds (ZERO new LIST/GET,
        ZERO new walk). Called ONLY for a sub-lineage-ENABLED partition's
        canary; the default partition calls plain `run` and emits NOTHING new
        (byte-identical legacy path).

        The audit kernel (`audit_segment_contiguity`) checks the live survivor
        chunk set for gap / overlap / per-segment tear over the SAME
        `(base_offset, record_count)` columns the walk built — the same
        definition as the offline gate's `validate_dense_contiguity`. The audit
        runs over the survivor set EVEN when nothing is retired (an empty /
        single-chunk manifest is vacuously contiguous → CLEAN), so the canary
        gets a positive liveness signal every pass."""
        var head = manifest.read_head_authoritative()
        var head_chunk = head.chunk_seq
        var ls = manifest.read_log_start()
        var log_start_seq = ls.log_start_seq

        # Empty / single-chunk manifest: nothing to retire AND vacuously
        # contiguous — emit a CLEAN audit (the walk ran, found no break) so the
        # canary records a liveness sample, then early-out exactly like `run`.
        if head_chunk < Int64(0) or log_start_seq >= head_chunk:
            rollout.record_contiguity_audit(0)
            return RetentionResult(
                tombstoned_count=Int64(0),
                new_log_start_seq=ls.log_start_seq,
                new_log_start_offset=ls.log_start_offset,
                advanced_log_start=False,
            )

        # Build the live-chunk snapshot [log_start_seq, head_chunk) — IDENTICAL
        # to `run`. This is the SOLE walk; the audit reads its columns.
        var chunks = List[_ChunkMeta]()
        var running_base = ls.log_start_offset
        var seq = log_start_seq
        while seq < head_chunk:
            var body_bytes = manifest.read_chunk(seq)
            var body = ManifestBody.decode(body_bytes)
            chunks.append(
                _ChunkMeta(
                    chunk_seq=seq,
                    base_offset=running_base,
                    record_count=body.record_count,
                    segment_bytes=body.segment_bytes,
                    creation_ts_ms=body.creation_ts_ms,
                )
            )
            running_base += body.record_count
            seq += Int64(1)

        # OFFSET-CONTIGUITY AUDIT (signal 3) — ride the walk, emit the result.
        # The survivor set spans [log_start, head_chunk); the active chunk is
        # excluded from the snapshot (never retired) but its base IS
        # `running_base`, contiguous by construction — we audit the snapshot's
        # internal contiguity (gap/overlap/tear across the live survivors).
        var base_col = List[Int64]()
        var count_col = List[Int64]()
        for i in range(len(chunks)):
            base_col.append(chunks[i].base_offset)
            count_col.append(chunks[i].record_count)
        var violations = audit_segment_contiguity(base_col^, count_col^)
        rollout.record_contiguity_audit(violations)

        # ---- the rest is byte-identical to `run` (tombstone + advance) -------
        var retire = evaluate_retention(self._policy, chunks, now_ms)
        if retire <= Int64(0):
            return RetentionResult(
                tombstoned_count=Int64(0),
                new_log_start_seq=ls.log_start_seq,
                new_log_start_offset=ls.log_start_offset,
                advanced_log_start=False,
            )

        var i = 0
        while i < Int(retire):
            manifest.schedule_for_delete_at(chunks[i].chunk_seq, now_ms)
            i += 1

        var new_seq: Int64
        var new_offset: Int64
        if Int(retire) < len(chunks):
            new_seq = chunks[Int(retire)].chunk_seq
            new_offset = chunks[Int(retire)].base_offset
        else:
            new_seq = head_chunk
            new_offset = running_base

        var expect_offset = ls.log_start_offset
        var k = 0
        while k < Int(retire):
            expect_offset += chunks[k].record_count
            k += 1
        if expect_offset != new_offset:
            raise Error(  # cov: unreachable new_offset is the same sum: chunks[retire].base_offset, or running_base when every snapshot chunk retires
                "RetentionPass: survivor offset contiguity broken — expected"  # cov: unreachable see the line above
                " new log_start_offset "
                + String(expect_offset)  # cov: unreachable see the line above
                + " got "  # cov: unreachable see the line above
                + String(new_offset)  # cov: unreachable see the line above
                + " (retention must NEVER renumber the log)"  # cov: unreachable see the line above
            )

        var advanced = self._advance_log_start_cas(
            manifest, new_seq, new_offset
        )

        return RetentionResult(
            tombstoned_count=retire,
            new_log_start_seq=new_seq,
            new_log_start_offset=new_offset,
            advanced_log_start=advanced,
        )

    def _advance_log_start_cas(
        mut self,
        mut manifest: CasManifestStore[Self.Storage],
        new_seq: Int64,
        new_offset: Int64,
    ) raises -> Bool:
        """Advance log_start to (new_seq, new_offset): `advance_log_start_monotone`."""
        return advance_log_start_monotone(manifest, new_seq, new_offset)


def advance_log_start_monotone[
    Storage: ConditionalWriteStore
](
    mut manifest: CasManifestStore[Storage],
    new_seq: Int64,
    new_offset: Int64,
) raises -> Bool:
    """Advance log_start to (new_seq, new_offset) via If-Match CAS, with a
    bounded re-read-on-412 retry. Never moves the pointer backwards (a stale
    state that already passed this point → no-op). Returns True iff the
    pointer ended at/after the target (advanced or already there). Raises when
    the retries run out, on an INCONSISTENT concurrent advance, and on any
    other store error. Shared by RetentionPass and parent compaction."""
    var attempts = 0
    while attempts < 8:
        attempts += 1
        var cur = manifest.read_log_start()
        # Already at/past the target (a concurrent pass advanced it) →
        # done, no backwards move.
        if cur.log_start_seq >= new_seq:
            # Concurrent log_start advance: a concurrent pass (the
            # other of retention/compaction) won the CAS and advanced
            # log_start_seq AT/PAST this pass's target. `seq` and `offset`
            # advance TOGETHER + monotonically (each advance moves both to
            # the base of the first still-live chunk), so a seq that is
            # at/past `new_seq` MUST carry an offset at/past `new_offset`.
            # If it does NOT, the two passes have a DIVERGENT view of the
            # contiguous offset log (a renumber / a torn advance) — do NOT
            # silently no-op past that inconsistency; surface it fail-loud.
            if cur.log_start_offset < new_offset:
                raise Error(
                    "RetentionPass: concurrent log_start advance is"
                    " INCONSISTENT — won log_start_seq "
                    + String(cur.log_start_seq)
                    + " >= target seq "
                    + String(new_seq)
                    + " but won log_start_offset "
                    + String(cur.log_start_offset)
                    + " < target offset "
                    + String(new_offset)
                    + " (offset must advance monotonically with seq; a"
                    " divergent view means the log was renumbered)"
                )
            return True
        try:
            _ = manifest.advance_log_start(
                new_seq, new_offset, cur.etag
            )
            return True
        except e:
            if _is_precondition(String(e)):
                continue  # stale etag — re-read and retry
            raise e^
    # Exhausted retries (heavy contention) — surface fail-loud-retryable.
    raise Error(
        "RetentionPass: advance_log_start exhausted retries under"
        " contention (retryable)"
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
def _is_not_found(msg: String) -> Bool:
    return (
        msg.find("not_found") >= 0
        or msg.find("NotFound") >= 0
        or msg.find("404") >= 0
        or msg.find("NoSuchKey") >= 0
    )


# =============================================================================
# ReapWorker — the grace-gated background reaper.
# =============================================================================


comptime DEFAULT_GRACE_PERIOD_MS = Int64(60_000)


@fieldwise_init
struct ReapResult(Copyable, Movable, Deinitable):
    """Outcome of one ReapWorker pass.

    Field layout:
      var reaped_count: Int64        — tombstoned chunks deleted (chunk key +
                                       markers, and the `.seg` unless the
                                       chunk has a MOVED marker).
      var skipped_live_count: Int64  — tombstones on LIVE chunks (seq at or
                                       above `log_start_seq`): left untouched.
                                       Nonzero means a log-start advance
                                       failed or has not landed yet after its
                                       tombstones; a later advance makes them
                                       reclaimable.
      var log_start_seq: Int64       — the floor this pass read (once).
    """

    var reaped_count: Int64
    var skipped_live_count: Int64
    var log_start_seq: Int64


struct ReapWorker[Storage: ConditionalWriteStore](
    Movable, Deinitable
):
    """The background reaper: deletes tombstoned chunk objects after the grace
    window. Grace gating lives here (above the clock-less `reap` verb)."""

    var _grace_ms: Int64

    def __init__(out self, grace_ms: Int64 = DEFAULT_GRACE_PERIOD_MS):
        self._grace_ms = grace_ms

    def run(
        mut self,
        mut segment_store: Self.Storage,
        mut manifest: CasManifestStore[Self.Storage],
        now_ms: Int64,
    ) raises -> ReapResult:
        """Reap every tombstoned chunk BELOW the log start whose grace window
        has elapsed (`now_ms - schedule_ts >= grace_ms`).

        0. Reads `_LOG_START` ONCE (one GET), before any delete. A read error
           RAISES before anything is deleted (fail closed). The pointer only
           moves forward, so a floor read at the start stays safe all pass.
        1. A tombstone at or above the floor sits on a LIVE chunk: it is
           skipped and counted in `skipped_live_count`, never deleted, and the
           pass goes on (no raise).
        A chunk with a MOVED marker is checked FIRST, before any plain
        tombstone it also carries: the reaper waits until `now_ms - moved_ts
        >= grace_ms`, then calls `manifest.reap(seq)` only (chunk key and both
        markers), never deleting its `.seg`. The plain tombstone's ts is then
        ignored: the MOVED marker is written when the migration or fold
        advances past the chunk, so its ts is the later and correct start of
        the grace window, and the `.seg` is referenced from `_base` whatever a
        retention pass decided.
        For each grace-elapsed plain tombstone below the floor the reaper
        deletes the now-unreferenced SEGMENT objects:
          2. reads the chunk body → decodes the broker `ManifestBody` to learn
             the `.seg` object key (the broker's domain payload);
          3. DELETEs the `.seg` segment object from `segment_store` (the actual
             durable data — idempotent, deleting absent succeeds);
          4. `manifest.reap(seq)` → deletes the manifest chunk + the tombstone
             marker (it re-checks the log start: defense in depth).

        Idempotent: a chunk already reaped is no longer tombstoned, so a re-run
        is a no-op; a chunk still within grace is skipped (a later run reaps
        it). A chunk body that 404s mid-reap (a concurrent reaper won) is
        skipped (the manifest.reap fail-loud guard already enforces tombstone-
        before-reap). A seq whose markers are both gone by the time it is read
        (a concurrent reaper reaped it after this pass's LIST) is skipped."""
        # Step 0. Raises on a read error: nothing deleted this pass.
        var floor = manifest.read_log_start_seq()
        var seqs = manifest.tombstone_seqs()
        var reaped = Int64(0)
        var skipped_live = Int64(0)
        for i in range(len(seqs)):
            var seq = seqs[i]
            if seq >= floor:
                # Step 1. A live chunk: keep its `.seg` and its chunk key.
                skipped_live += Int64(1)
                continue
            var moved_ts = manifest.moved_tombstone_ts(seq)
            if moved_ts:
                # `_base` references this `.seg`: reap the chunk key and the
                # markers once grace elapses, never the segment
                # (komira-ai/komira#494).
                if now_ms - moved_ts.value() >= self._grace_ms:
                    manifest.reap(seq)
                    reaped += Int64(1)
                continue
            var schedule_ts: Int64
            try:
                schedule_ts = manifest.tombstone_schedule_ts(seq)
            except e:
                if not _is_not_found(String(e)):
                    raise e^
                # Neither marker is there any more: another reaper reaped this
                # seq after our LIST. Nothing left to do for it.
                continue
            if now_ms - schedule_ts >= self._grace_ms:
                # Delete the .seg segment object first (the durable data). Read
                # the chunk body for its object_key; if the chunk is already
                # gone (a concurrent reaper), skip — manifest.reap is a no-op
                # path that fail-loud-guards tombstone-before-reap.
                try:
                    var body_bytes = manifest.read_chunk(seq)
                    var body = ManifestBody.decode(body_bytes)
                    # A chunk with no segment object (a txn COMMIT/ABORT
                    # marker: empty key) has nothing to delete. Without this
                    # check the reaper DELETEd `Path.parse("")`, which does not
                    # raise: it is the bucket-root key.
                    if body.has_segment():
                        # delete is idempotent (absent .seg → success).
                        segment_store.delete(Path.parse(body.object_key))
                except e:
                    if not _is_not_found(String(e)):
                        raise e^
                    # chunk already gone — continue to reap (idempotent).
                manifest.reap(seq)
                reaped += Int64(1)
        return ReapResult(
            reaped_count=reaped,
            skipped_live_count=skipped_live,
            log_start_seq=floor,
        )
