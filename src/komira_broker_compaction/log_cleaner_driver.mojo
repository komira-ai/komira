# =============================================================================
# log_cleaner_driver.mojo: the log-cleaner driver
# =============================================================================
#
# This is the wiring `komira_broker`'s `LogCleaner` cannot do: it actually
# re-encodes a cleanable `.seg`. The cleaner in `komira_broker/log_compaction`
# ships the pure decision (`compact_records`) and the offset-preserving manifest
# swap, but it keeps the original `object_key`: it never reads a `.seg` (the
# broker may not decode Arrow-IPC) and never writes a new one.
#
# The re-encode lives here because it needs `decode_arrow_ipc_stream`
# (`komira_op_sources`) to decode the cleanable `.seg` objects. The write side
# reuses the broker's `encode_segment` (Arrow-IPC stream plus a 40-byte footer),
# so a compacted `.seg` has the same format as a live `.seg` and the existing
# live consume path reads it with no new decode logic.
#
# -----------------------------------------------------------------------------
# THE CLEANER TICK (one round over one compact-policy partition)
# -----------------------------------------------------------------------------
#   1. Resolve the live manifest index (offset to segment). The cleanable range
#      is every live chunk except the active (head) chunk, as in retention.
#   2. For each cleanable chunk: GET its `.seg`, slice the footer, decode the
#      Arrow-IPC stream -> one RecordBatch.
#   3. extract_clean_records over each batch (key, abs_offset, chunk_seq,
#      tombstone) -> the per-record compaction identity.
#   4. Wall-clock tombstone grace: a chunk whose `creation_ts_ms` is older than
#      `delete_retention_ms` has its tombstones grace-expired.
#   5. compact_records over all records (tombstones included) -> the survivor
#      set (latest-per-key, offsets preserved). A surviving tombstone in a
#      grace-expired chunk is then dropped, which removes the whole key (the
#      prior superseded value is not resurrected).
#   6. Per cleanable chunk that has DROPPED records: gather the survivor ROWS
#      (row = abs_offset - base_offset) into a survivor-only RecordBatch via the
#      DType-agnostic `gather_batch`, re-encode it as a NEW `.seg` with
#      `encode_segment`, PUT it under a fresh compacted-segment key, and CAS-swap
#      the manifest chunk body (record_count PRESERVED) to point at the NEW key
#      + its CRC, carrying the survivor-offset sidecar.
#   7. The ORPHANED original `.seg` is scheduled for grace-gated GC by writing a
#      per-orphan tombstone marker keyed by the orphaned object key; the
#      `CompactionReapWorker` deletes it post-grace. (The chunk body now points
#      at the NEW seg, so the standard chunk-tombstone reaper — which reaps by
#      body.object_key — CANNOT be used for the orphan; it would delete the live
#      compacted seg. A by-explicit-key orphan reaper is the correct GC.)
#
# Crash-safety: the order is PUT-new -> swap-manifest -> tombstone-old. A crash
# before the swap leaves the original `.seg` + the original chunk body intact
# (consumer reads the full chunk; a re-run re-compacts idempotently). A crash
# after the swap but before the orphan-tombstone just leaks one `.seg` object (a
# later round's resolve never references it; a sweep GC can mop it). No offset
# gap, no data loss, at any interruption point.
#
# A chunk with NO dropped records (already fully compacted / all-distinct keys)
# is SKIPPED (no re-encode, no swap, no orphan) — the round is idempotent.
#
# No UnsafePointer in any signature (the surface is values, RecordBatch, List,
# Slab and a store passed by mut ref); no wildcard origins, no
# `unsafe_from_address`, no `take_pointee`.
# =============================================================================

from komira_collections.slab import Slab

from komira_arrow.record_batch import RecordBatch
from komira_column_kernels.compiler_helpers import gather_batch

from komira_objectstore.cas_manifest import CasManifestStore
from komira_objectstore.path import Path
from komira_objectstore.store import ConditionalWriteStore

from komira_broker.broker_core import SegmentFooter, encode_segment
from komira_broker.consume_core import ConsumeCore, SegmentRef
from komira_broker.manifest_body import ManifestBody, MARKER_NONE
from komira_broker.log_compaction import (
    CleanRecord,
    CompactionConfig,
    CompactionPlan,
    compact_records,
    extract_clean_records,
    encode_compacted_chunk_body,
    decode_compacted_survivor_offsets,
    is_chunk_compacted,
)

from komira_op_sources.arrow_stream_reader import decode_arrow_ipc_stream


# =============================================================================
# Orphan-segment tombstone key layout — the by-explicit-key GC for the original
# `.seg` a compaction rewrite supersedes.
# =============================================================================
#
#   <prefix>/compaction_orphans/<schedule_ts:020d>-<seq:020d>.orphan
#     body = [ schedule_ts_ms i64 LE ][ key_len i64 LE ][ orphaned .seg key... ]
#
# The marker carries the orphaned `.seg` object key (the chunk body no longer
# points at it after the swap). The CompactionReapWorker LISTs this prefix,
# reads each marker's schedule_ts + key, and deletes the `.seg` once the grace
# window elapses. Keyed by (schedule_ts, chunk_seq) so a chunk re-compacted in a
# later round produces a DISTINCT marker (its prior orphan is independently
# reaped). Distinct from `<prefix>/tombstones/` (chunk-lifecycle tombstones,
# RetentionPass/ReapWorker) — the two reapers never touch the same object.
# -----------------------------------------------------------------------------


@always_inline
def _pad20(v: Int64) -> String:
    var s = String(v)
    var pad = 20 - s.byte_length()
    var out = String("")
    for _ in range(pad):
        out += "0"
    out += s
    return out^


def _orphan_marker_key(
    prefix: String, schedule_ts_ms: Int64, chunk_seq: Int64
) raises -> Path:
    return Path.parse(
        prefix
        + "/compaction_orphans/"
        + _pad20(schedule_ts_ms)
        + "-"
        + _pad20(chunk_seq)
        + ".orphan"
    )


@always_inline
def _put_i64_le(mut out: List[UInt8], v: Int64):
    var u = UInt64(v)
    for i in range(8):
        out.append(UInt8((u >> UInt64(8 * i)) & UInt64(0xFF)))


@always_inline
def _get_i64_le(bytes: List[UInt8], off: Int) raises -> Int64:
    if off + 8 > len(bytes):
        raise Error("log_cleaner_driver: truncated i64 at " + String(off))
    var u = UInt64(0)
    for i in range(8):
        u |= UInt64(Int(bytes[off + i])) << UInt64(8 * i)
    return Int64(u)


def _encode_orphan_marker(schedule_ts_ms: Int64, seg_key: String) -> List[UInt8]:
    var out = List[UInt8]()
    _put_i64_le(out, schedule_ts_ms)
    var kb = seg_key.as_bytes()
    _put_i64_le(out, Int64(len(kb)))
    for i in range(len(kb)):
        out.append(kb[i])
    return out^


def _decode_orphan_marker(bytes: List[UInt8]) raises -> _OrphanMarker:
    var ts = _get_i64_le(bytes, 0)
    var key_len = Int(_get_i64_le(bytes, 8))
    if 16 + key_len > len(bytes):
        raise Error("log_cleaner_driver: truncated orphan marker key")
    var key = String("")
    for i in range(key_len):
        key += chr(Int(bytes[16 + i]))
    return _OrphanMarker(schedule_ts_ms=ts, seg_key=key^)


@fieldwise_init
struct _OrphanMarker(Copyable, Movable, Deinitable):
    """One orphaned-`.seg` tombstone: its schedule timestamp + the object key
    of the superseded original segment. POD-ish (one owned String)."""

    var schedule_ts_ms: Int64
    var seg_key: String


@always_inline
def _chunk_expired(
    chunk_seqs: List[Int64], expired: List[Bool], seq: Int64
) -> Bool:
    """Look up the per-chunk grace-expired flag for `seq` (parallel lists keyed
    by chunk_seq). False if not found (defensive — a survivor's chunk is always
    one of the cleanable chunks). Linear scan; cleanable ranges are small."""
    for i in range(len(chunk_seqs)):
        if chunk_seqs[i] == seq:
            return expired[i]
    return False


@always_inline
def _sidecar_row_of(sidecar: List[Int64], abs_offset: Int64) -> Int:
    """The PHYSICAL row index of `abs_offset` within a compacted chunk's
    survivor-offset sidecar (the sparse layout: physical row `r` sits at
    `sidecar[r]`). Returns -1 if absent (should never happen — a survivor of a
    compacted chunk is always one of its current physical rows). Linear scan;
    cleanable chunks are small."""
    for r in range(len(sidecar)):
        if sidecar[r] == abs_offset:
            return r
    return -1


@always_inline
def _seq_ts_from_orphan_key(key: String) -> Int64:
    """Extract the schedule_ts (the first :020d field) from an orphan marker
    location for the ascending-by-schedule LIST sort. Returns -1 on no match."""
    var marker = String("/compaction_orphans/")
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


# =============================================================================
# ProductionCleanResult — what one production cleaner tick reports. POD.
# =============================================================================


@fieldwise_init
struct ProductionCleanResult(Copyable, Movable, Deinitable):
    """The outcome of one `ProductionLogCleaner.run_once` tick.

    Field layout:
      var ran: Bool                  — True iff the cleaner actually compacted
                                       (False when policy != compact or the
                                       cleanable range was empty).
      var cleanable_chunks: Int64    — live non-active chunks considered.
      var records_scanned: Int64     — total records across the cleanable range.
      var survivors: Int64           — records kept (latest-per-key + live
                                       tombstones).
      var dropped: Int64             — records removed (superseded + grace-
                                       expired tombstones).
      var chunks_rewritten: Int64    — cleanable chunks that had >=1 drop and
                                       were re-encoded + swapped (a chunk with
                                       no drops is skipped — idempotent).
      var orphans_scheduled: Int64   — original `.seg` objects scheduled for
                                       grace-gated GC (== chunks_rewritten).
    """

    var ran: Bool
    var cleanable_chunks: Int64
    var records_scanned: Int64
    var survivors: Int64
    var dropped: Int64
    var chunks_rewritten: Int64
    var orphans_scheduled: Int64

    @staticmethod
    def noop(cleanable: Int64) -> ProductionCleanResult:
        return ProductionCleanResult(
            ran=False,
            cleanable_chunks=cleanable,
            records_scanned=Int64(0),
            survivors=Int64(0),
            dropped=Int64(0),
            chunks_rewritten=Int64(0),
            orphans_scheduled=Int64(0),
        )


# =============================================================================
# ProductionLogCleaner[Storage] — the store-driving production cleaner.
# =============================================================================


struct ProductionLogCleaner[Storage: ConditionalWriteStore](
    Movable, Deinitable
):
    """Runs one PRODUCTION log-compaction tick over a compact-policy partition:
    decode the cleanable `.seg`s, compute latest-per-key survivors (with
    wall-clock tombstone grace), RE-ENCODE each dirty chunk's survivors as a new
    `.seg`, PUT it, CAS-swap the manifest chunk body (record_count PRESERVED,
    offsets PRESERVED with gaps), and schedule the orphaned original `.seg` for
    grace-gated GC.

    Composes the broker leaf's ConsumeCore (live read, by value) + the
    partition's segment store (PUTs the compacted `.seg`, by value) + the live
    manifest (CAS-swap + orphan markers, by value). Holds the per-topic
    CompactionConfig. Stateless over the manifest (fresh snapshot each run,
    exactly like RetentionPass / CompactionWorker).

    Ownership (all by value):
      var _consume: ConsumeCore[Storage]            — live read side.
      var _segment_store: Storage                   — PUTs compacted `.seg`s.
      var _manifest: CasManifestStore[Storage]      — CAS-swap + orphan markers.
      var _config: CompactionConfig                 — per-topic policy.
      var _cluster / _topic / _partition            — compacted-seg key layout.
      var _key_col / _value_col                     — the key/value column idx.
      var _seg_counter: Int64                       — compacted-seg key uniquifier.
    """

    var _consume: ConsumeCore[Self.Storage]
    var _segment_store: Self.Storage
    var _manifest: CasManifestStore[Self.Storage]
    var _config: CompactionConfig
    var _cluster: String
    var _topic: String
    var _partition: Int64
    var _key_col: Int
    var _value_col: Int
    var _seg_counter: Int64

    def __init__(
        out self,
        var consume: ConsumeCore[Self.Storage],
        var segment_store: Self.Storage,
        var manifest: CasManifestStore[Self.Storage],
        config: CompactionConfig,
        var cluster: String,
        var topic: String,
        partition: Int64,
        key_col: Int = 0,
        value_col: Int = 1,
    ):
        self._consume = consume^
        self._segment_store = segment_store^
        self._manifest = manifest^
        self._config = config
        self._cluster = cluster^
        self._topic = topic^
        self._partition = partition
        self._key_col = key_col
        self._value_col = value_col
        self._seg_counter = Int64(0)

    @always_inline
    def _compacted_seg_key(mut self, chunk_seq: Int64, now_ms: Int64) -> String:
        """A fresh compacted-`.seg` object key. Carries the source chunk_seq +
        a uniquifier (round-stamp + counter) so re-compacting the same chunk in
        a later round PUTs a distinct object (the prior one is orphaned + GC'd).
        """
        self._seg_counter += Int64(1)
        return (
            self._cluster
            + "/topics/"
            + self._topic
            + "/"
            + String(self._partition)
            + "/segments/"
            + String(now_ms)
            + "-compacted-"
            + String(chunk_seq)
            + "-"
            + String(self._seg_counter)
            + ".seg"
        )

    # -------------------------------------------------------------------------
    # run_once — one production cleaner tick over the cleanable range.
    # -------------------------------------------------------------------------

    def run_once(mut self, now_ms: Int64) raises -> ProductionCleanResult:
        """Execute one production compaction tick. No-op (`ran=False`) for a
        non-compact topic or an empty cleanable range.

        `now_ms` is the caller's wall clock (ms), passed in (not read here) so
        the cleaner is deterministically testable — it drives the tombstone
        grace gate (a tombstone in a chunk whose `creation_ts_ms` is older than
        `delete_retention_ms` is grace-expired) AND stamps the orphan markers.
        """
        # 1. Resolve the live index; the cleanable range is everything but the
        #    active/head chunk (the highest chunk_seq).
        if not self._config.compacts():
            return ProductionCleanResult.noop(Int64(0))
        var index = self._consume.resolve_index()
        var n = len(index)
        if n <= 1:
            # 0 or 1 live chunk → only the active chunk → nothing cleanable.
            return ProductionCleanResult.noop(Int64(0))
        # The active chunk is the HIGHEST chunk_seq in the resolved index (the
        # tail). Exclude it: cleanable == index[0 .. n-1).
        var active_seq = index[n - 1].chunk_seq
        var cleanable_count = Int64(n - 1)

        # 2. Decode each cleanable chunk's `.seg` -> one RecordBatch, holding the
        #    per-chunk base_offset + chunk_seq + creation_ts for the grace gate.
        #    `RecordBatch` is Movable-only → Slab, not List.
        #
        #    IDEMPOTENCY (re-run over an already-compacted chunk): a compacted
        #    chunk's `.seg` is SPARSE (physical rows = survivors only), and its
        #    survivor-offset SIDECAR carries each physical row's PRESERVED
        #    absolute offset. So for a compacted chunk physical row `r` is NOT at
        #    `base + r` — it is at `sidecar[r]`. We capture the sidecar here and
        #    use it to stamp the correct absolute offset in step 3 (so a re-run
        #    never mis-numbers the already-compacted survivors). An un-compacted
        #    chunk has an empty sidecar → falls back to `base + r`.
        var batches = Slab[RecordBatch]()
        var base_offsets = List[Int64]()
        var chunk_seqs = List[Int64]()
        var creation_ts = List[Int64]()
        var sidecars = List[List[Int64]]()
        # Per-chunk "has this chunk already been through the cleaner?" flag,
        # detected by the PRESENCE of the survivor-offset sidecar BLOCK — NOT by
        # `len(sidecar) > 0`. A ZERO-SURVIVOR chunk (fully superseded by a later
        # cleanable chunk) is compacted but has an EMPTY survivor-offset list, so
        # `len(sidecar) > 0` would mis-read it as un-compacted and the step-6
        # skip-guard would re-rewrite it on every round (minting a fresh orphan
        # each time — not idempotent). `is_chunk_compacted` checks the sidecar
        # block's physical presence (a zero-survivor chunk still writes the
        # count word, with value 0), so it correctly reads as compacted.
        var was_compacted_flags = List[Bool]()
        for i in range(n - 1):
            ref s = index[i]
            # Read the chunk body for its creation_ts (wall-clock grace gate) +
            # its survivor-offset sidecar (empty for an un-compacted chunk OR for
            # a zero-survivor compacted chunk).
            var body_bytes = self._manifest.read_chunk(s.chunk_seq)
            var body = ManifestBody.decode(body_bytes)
            var sidecar = decode_compacted_survivor_offsets(body_bytes)
            was_compacted_flags.append(is_chunk_compacted(body_bytes))
            # GET the `.seg`, slice the footer, decode the Arrow-IPC stream.
            var seg = self._consume.read_segment(s.copy())
            var stream = seg^.take_stream_bytes()
            batches.append(decode_arrow_ipc_stream(stream^))
            base_offsets.append(s.base_offset)
            chunk_seqs.append(s.chunk_seq)
            creation_ts.append(body.creation_ts_ms)
            sidecars.append(sidecar^)

        # 3. extract_clean_records over each batch. ALL records (including
        #    tombstones) go into the input so compact_records computes the true
        #    latest-per-key. The wall-clock tombstone grace is applied in step 5
        #    AFTER the per-key decision (a tombstone-latest key past grace must
        #    drop the WHOLE KEY — NOT resurrect a prior superseded value, which
        #    is what pre-filtering the tombstone would wrongly do).
        var grace_ms = self._config.delete_retention_ms
        var records = List[CleanRecord]()
        # Per-chunk grace-expired flag, indexed to chunk_seqs[i], so step 5 can
        # decide whether a tombstone survivor's chunk is past its grace window.
        var chunk_grace_expired = List[Bool]()
        for i in range(n - 1):
            var recs = extract_clean_records(
                batches[i],
                self._key_col,
                self._value_col,
                base_offsets[i],
                chunk_seqs[i],
            )
            # Is THIS chunk past its tombstone grace window? grace < 0 → retain
            # forever (never expire); else expired iff the chunk is older than
            # the grace window: now_ms - creation_ts >= grace_ms.
            var ct = creation_ts[i]
            var grace_expired = (
                grace_ms >= Int64(0)
                and ct >= Int64(0)
                and (now_ms - ct) >= grace_ms
            )
            chunk_grace_expired.append(grace_expired)
            # If this chunk is already compacted, its physical rows sit at the
            # sidecar's PRESERVED offsets — override the base+row offsets that
            # extract_clean_records assigned (idempotent re-run correctness).
            ref sc = sidecars[i]
            var is_compacted = len(sc) == len(recs)
            for r in range(len(recs)):
                var abs_off = sc[r] if is_compacted else recs[r].abs_offset
                records.append(
                    CleanRecord(
                        key=String(recs[r].key),
                        abs_offset=abs_off,
                        chunk_seq=recs[r].chunk_seq,
                        is_tombstone=recs[r].is_tombstone,
                    )
                )
        # Free the decoded batches (Slab destructor frees each RecordBatch).
        batches.set_len_unchecked(0)
        _ = batches^

        var scanned = Int64(len(records))

        # 5. PURE decision: per-key highest-offset survivor. Pass grace_ms
        #    through so the leaf's immediate-drop knob (delete_retention_ms == 0)
        #    fires when grace is explicitly zero. Then apply the WALL-CLOCK
        #    tombstone grace: a survivor that is a TOMBSTONE whose chunk is past
        #    its grace window is dropped — and since the tombstone WAS the
        #    latest-per-key, dropping it removes the WHOLE KEY (Kafka semantics:
        #    a deleted key past delete.retention.ms leaves no record, NOT a
        #    resurrected prior value). Offsets of the remaining survivors are
        #    PRESERVED.
        var raw_plan = compact_records(records, grace_ms, now_ms)
        var survivors = List[CleanRecord]()
        var expired_tombstone_drops = Int64(0)
        for s in range(len(raw_plan.survivors)):
            ref sv = raw_plan.survivors[s]
            if sv.is_tombstone and _chunk_expired(
                chunk_seqs, chunk_grace_expired, sv.chunk_seq
            ):
                # Past-grace tombstone survivor → drop the key entirely.
                expired_tombstone_drops += Int64(1)
                continue
            survivors.append(
                CleanRecord(
                    key=String(sv.key),
                    abs_offset=sv.abs_offset,
                    chunk_seq=sv.chunk_seq,
                    is_tombstone=sv.is_tombstone,
                )
            )
        var survivor_total = Int64(len(survivors))
        var dropped_total = raw_plan.dropped_count + expired_tombstone_drops

        # 6. Per cleanable chunk with >=1 drop: gather survivors -> new `.seg` ->
        #    PUT -> CAS-swap the chunk body (record_count PRESERVED) -> schedule
        #    the orphaned original `.seg` for grace-gated GC.
        var chunks_rewritten = Int64(0)
        var orphans = Int64(0)
        for i in range(n - 1):
            var seq = chunk_seqs[i]
            var base = base_offsets[i]
            # Re-read the original chunk body to (a) learn the original `.seg`
            # key for the orphan marker, (b) carry its trailers through the
            # rewrite, (c) detect whether ANY record dropped from this chunk.
            var orig_bytes = self._manifest.read_chunk(seq)
            var orig = ManifestBody.decode(orig_bytes)
            var orig_count = orig.record_count
            # The chunk's CURRENT physical layout: a compacted chunk is sparse,
            # its physical rows at the sidecar's PRESERVED offsets; an
            # un-compacted chunk is dense at base..base+orig_count-1.
            #
            # `was_compacted` is the sidecar-presence flag (is_chunk_compacted),
            # not `len(sc) > 0`. A zero-survivor compacted chunk has an empty
            # `sc` but is compacted: its current `.seg` physically holds 0 rows.
            # With the presence flag `phys_count == 0` for it, so the skip-guard
            # below (`len(rows) == phys_count`, `0 == 0`) skips it on a re-run
            # (idempotent: no re-rewrite, no new orphan). Reading it as
            # un-compacted would give `phys_count == orig_count`, and the guard
            # would re-rewrite the already-empty chunk every round.
            ref sc = sidecars[i]
            var was_compacted = was_compacted_flags[i]
            var phys_count = (
                Int64(len(sc)) if was_compacted else orig_count
            )

            # Gather this chunk's survivor PHYSICAL ROW indices, in ascending
            # order, + the survivor abs_offsets for the new sidecar. The
            # abs_offset -> physical-row map is: for an un-compacted chunk row =
            # abs_offset - base; for an already-compacted chunk row = the index
            # of abs_offset within the current sidecar (the sparse layout).
            var rows = List[Int]()
            var surv_offsets = List[Int64]()
            for s in range(len(survivors)):
                ref sv = survivors[s]
                if sv.chunk_seq == seq:
                    var phys_row: Int
                    if was_compacted:
                        phys_row = _sidecar_row_of(sc, sv.abs_offset)
                    else:
                        phys_row = Int(sv.abs_offset - base)
                    rows.append(phys_row)
                    surv_offsets.append(sv.abs_offset)

            # No drops in this chunk relative to its CURRENT physical layout
            # (survivors == current physical row count) → SKIP: nothing to
            # compact, leave the chunk + its `.seg` untouched (idempotent — a
            # re-run never re-rewrites an already-clean / already-compacted
            # chunk that lost no further rows).
            if Int64(len(rows)) == phys_count:
                continue

            # Re-decode the chunk's CURRENT `.seg` and gather the survivor rows
            # into a new survivor-only RecordBatch (DType-agnostic gather_batch).
            # The SegmentRef carries the PHYSICAL count so read_segment's relaxed
            # cross-check accepts the (possibly sparse) current segment.
            var seg_ref = SegmentRef(
                chunk_seq=seq,
                base_offset=base,
                last_offset=base + orig_count - Int64(1),
                record_count=phys_count,
                object_key=String(orig.object_key),
                crc32=orig.crc32,
            )
            var cseg = self._consume.read_segment(seg_ref^)
            var stream2 = cseg^.take_stream_bytes()
            var src_batch = decode_arrow_ipc_stream(stream2^)
            var surv_batch = gather_batch(src_batch, rows)
            _ = src_batch^

            # Re-encode the survivor batch as a new `.seg` (Arrow-IPC + footer).
            # The footer's debug base is the chunk's original base (offsets are
            # preserved via the manifest, not the footer). Slab[RecordBatch] is
            # the encode_segment input shape.
            var buf = Slab[RecordBatch]()
            buf.append(surv_batch^)
            var new_seg_bytes = encode_segment(buf^, base)
            var new_footer = SegmentFooter.decode(new_seg_bytes)
            var new_crc = new_footer.crc32

            # PUT the new compacted `.seg` under a fresh key.
            var new_key = self._compacted_seg_key(seq, now_ms)
            var _pm = self._segment_store.put(
                Path.parse(new_key), new_seg_bytes^
            )
            _ = _pm

            # CAS-swap the manifest chunk body in place (record_count PRESERVED;
            # offsets PRESERVED via the survivor-offset sidecar; never renumber).
            var new_body = encode_compacted_chunk_body(
                orig, String(new_key), new_crc, surv_offsets
            )
            self._manifest.rewrite_chunk_body(seq, new_body)
            chunks_rewritten += Int64(1)

            # Schedule the ORPHANED original `.seg` for grace-gated GC. The chunk
            # body now points at `new_key`, so the standard chunk-tombstone
            # reaper (reaps by body.object_key) would delete the LIVE compacted
            # seg — wrong. We tombstone the orphan by EXPLICIT KEY instead.
            var marker = _encode_orphan_marker(now_ms, String(orig.object_key))
            var _om = self._segment_store.put(
                _orphan_marker_key(self._manifest.prefix(), now_ms, seq),
                marker,
            )
            _ = _om
            orphans += Int64(1)

        _ = active_seq  # (active chunk excluded by construction; documented.)
        return ProductionCleanResult(
            ran=True,
            cleanable_chunks=cleanable_count,
            records_scanned=scanned,
            survivors=survivor_total,
            dropped=dropped_total,
            chunks_rewritten=chunks_rewritten,
            orphans_scheduled=orphans,
        )


# =============================================================================
# CompactionReapWorker[Storage] — the grace-gated orphan-`.seg` reaper.
# =============================================================================


comptime DEFAULT_ORPHAN_GRACE_MS = Int64(60_000)


struct CompactionReapWorker[Storage: ConditionalWriteStore](
    Movable, Deinitable
):
    """Deletes the orphaned original `.seg` objects a compaction rewrite
    superseded, after the grace window. Distinct from `ReapWorker` (which reaps
    chunk-lifecycle tombstones by the chunk body's object_key) — this reaper
    deletes by the EXPLICIT key recorded in the orphan marker, because the chunk
    body no longer points at the orphaned segment after the swap.

    Grace gating lives here (above the clock-less store verbs), exactly like
    ReapWorker: an orphan whose marker `schedule_ts_ms` is older than `grace_ms`
    is reaped (delete the `.seg` + drop the spent marker). Idempotent — a marker
    whose `.seg` is already gone deletes the marker only; a re-run is a no-op.
    """

    var _segment_store: Self.Storage
    var _manifest: CasManifestStore[Self.Storage]
    var _grace_ms: Int64

    def __init__(
        out self,
        var segment_store: Self.Storage,
        var manifest: CasManifestStore[Self.Storage],
        grace_ms: Int64 = DEFAULT_ORPHAN_GRACE_MS,
    ):
        self._segment_store = segment_store^
        self._manifest = manifest^
        self._grace_ms = grace_ms

    def run(mut self, now_ms: Int64) raises -> Int64:
        """Reap every orphaned `.seg` whose grace window has elapsed
        (`now_ms - schedule_ts >= grace_ms`). Returns the count reaped.

        LISTs `<prefix>/compaction_orphans/`, reads each marker (schedule_ts +
        the orphaned `.seg` key), and for grace-elapsed markers deletes the
        `.seg` then the marker. Idempotent (deleting an absent object
        succeeds)."""
        var prefix = self._manifest.prefix()
        var lk = Path.parse(prefix + "/compaction_orphans/")
        var listing = self._segment_store.list_with_delimiter(lk)
        var reaped = Int64(0)
        for i in range(len(listing.objects)):
            var loc = listing.objects[i].location
            if _seq_ts_from_orphan_key(loc) < Int64(0):
                continue  # not an orphan marker key.
            var marker_path = Path.parse(loc)
            var raw = self._segment_store.get(marker_path)
            var m = _decode_orphan_marker(raw)
            if now_ms - m.schedule_ts_ms >= self._grace_ms:
                # Delete the orphaned `.seg` (idempotent — absent → success),
                # then drop the spent marker.
                self._segment_store.delete(Path.parse(m.seg_key))
                self._segment_store.delete(marker_path)
                reaped += Int64(1)
        return reaped

    @always_inline
    def prefix(self) -> String:
        return self._manifest.prefix()
