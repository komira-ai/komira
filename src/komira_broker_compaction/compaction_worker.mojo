# =============================================================================
# compaction_worker.mojo: the CompactionWorker orchestrator
# =============================================================================
#
# Orchestrates one compaction round for a single topic-partition:
#   1. Resolve the live manifest index (offset to segment).
#   2. Select a contiguous prefix of uncompacted live segments (starting at the
#      compacted tail) to compact: at least `min_segments` and up to
#      `max_segments` (a bounded round; the worker can run repeatedly).
#   3. Read each selected segment's Arrow-IPC stream bytes from the object
#      store.
#   4. Transcode the streams to ONE Parquet object's bytes (with the schema
#      check), with no local disk.
#   5. PUT the Parquet object to the compacted-tier key.
#   6. Append the CompactedEntry to the separate compaction-index lineage (the
#      lazy manifest-swap commit; offset contiguity is checked inside
#      `append_compacted`, which raises on a gap).
#   7. Tombstone the superseded live manifest chunks (`schedule_for_delete`);
#      the grace-gated ReapWorker reaps them after the grace period.
#
# The whole round is commit-then-supersede: the Parquet PUT and the
# compaction-index append land BEFORE any live tombstone, so a crash between
# steps leaves the live tier fully readable (a consumer reads live until the
# compacted entry is visible). A re-run is idempotent at the boundary: the next
# round starts at the new compacted tail.
#
# Why this is in the adapter and not in `komira_broker`: it drives the
# transcode, which needs the Arrow-IPC decoder and the Parquet writer. It
# composes the broker's ConsumeCore and CompactionIndex (held by value) with
# the partition's segment store and live manifest.
#
# No UnsafePointer in any signature; the substrate is held by value.
# =============================================================================

from komira_collections.slab import Slab

from komira_objectstore.cas_manifest import CasManifestStore
from komira_objectstore.path import Path
from komira_objectstore.store import ConditionalWriteStore

from komira_broker.consume_core import ConsumeCore, SegmentRef, ConsumeSegment
from komira_broker.compacted_index import CompactionIndex, evaluate_slo_backpressure, SloDecision

from komira_parquet_api.types import CompressionCodec

from .transcode import transcode_segments_to_parquet


# =============================================================================
# CompactionRoundResult — the outcome of one compaction round (POD).
# =============================================================================


@fieldwise_init
struct CompactionRoundResult(Copyable, Movable, Deinitable):
    """The outcome of one `CompactionWorker.run_once` round.

    Field layout:
      var compacted: Bool          — True iff a Parquet object was published.
      var parquet_key: String      — the published Parquet object key
                                     (empty when compacted == False).
      var base_offset: Int64       — first absolute offset compacted (-1 if none).
      var last_offset: Int64       — last absolute offset compacted (-1 if none).
      var record_count: Int64      — records compacted (0 if none).
      var segments_compacted: Int64 — # live segments folded into the object.
      var supersedes_lo: Int64     — first live chunk_seq superseded (-1 none).
      var supersedes_hi: Int64     — last live chunk_seq superseded (-1 none).
      var tombstoned_count: Int64  — # superseded live chunks tombstoned.
    """

    var compacted: Bool
    var parquet_key: String
    var base_offset: Int64
    var last_offset: Int64
    var record_count: Int64
    var segments_compacted: Int64
    var supersedes_lo: Int64
    var supersedes_hi: Int64
    var tombstoned_count: Int64

    @staticmethod
    def none() -> CompactionRoundResult:
        """A no-op round (nothing to compact)."""
        return CompactionRoundResult(
            compacted=False,
            parquet_key=String(""),
            base_offset=Int64(-1),
            last_offset=Int64(-1),
            record_count=Int64(0),
            segments_compacted=Int64(0),
            supersedes_lo=Int64(-1),
            supersedes_hi=Int64(-1),
            tombstoned_count=Int64(0),
        )


@always_inline
def _compacted_parquet_key(
    cluster: String,
    topic: String,
    partition: Int64,
    base_offset: Int64,
    last_offset: Int64,
    uniq: Int64,
) -> String:
    """The compacted-tier Parquet object key. Carries the offset range +debug
    uniquifier (the AUTHORITATIVE range is the compaction-index entry; the key
    range is for debuggability + uniqueness across rounds/brokers)."""
    return (
        cluster
        + "/topics/"
        + topic
        + "/"
        + String(partition)
        + "/compacted/"
        + String(base_offset)
        + "-"
        + String(last_offset)
        + "-"
        + String(uniq)
        + ".parquet"
    )


# =============================================================================
# CompactionWorker[Storage] — one partition's compaction orchestrator.
# =============================================================================


struct CompactionWorker[Storage: ConditionalWriteStore](
    Movable, Deinitable
):
    """Orchestrates compaction rounds for ONE topic-partition (the
    adapter-side driver). Composes the broker leaf's ConsumeCore (live read) +
    CompactionIndex (compacted lineage) + the partition's segment store + live
    manifest, and drives the transcode (Arrow-IPC decode and Parquet encode).

    Ownership (all by value):
      var _consume: ConsumeCore[Storage]            — live read side.
      var _index: CompactionIndex[Storage]          — compacted lineage.
      var _segment_store: Storage                   — PUTs Parquet objects.
      var _live_manifest: CasManifestStore[Storage] — tombstones superseded live
                                                      chunks (schedule_for_delete).
      var _cluster / _topic / _partition            — key layout.
      var _round_counter: Int64                     — Parquet key uniquifier.
    """

    var _consume: ConsumeCore[Self.Storage]
    var _index: CompactionIndex[Self.Storage]
    var _segment_store: Self.Storage
    var _live_manifest: CasManifestStore[Self.Storage]
    var _cluster: String
    var _topic: String
    var _partition: Int64
    var _round_counter: Int64

    def __init__(
        out self,
        var consume: ConsumeCore[Self.Storage],
        var index: CompactionIndex[Self.Storage],
        var segment_store: Self.Storage,
        var live_manifest: CasManifestStore[Self.Storage],
        var cluster: String,
        var topic: String,
        partition: Int64,
    ):
        self._consume = consume^
        self._index = index^
        self._segment_store = segment_store^
        self._live_manifest = live_manifest^
        self._cluster = cluster^
        self._topic = topic^
        self._partition = partition
        self._round_counter = Int64(0)

    # NOTE: there is intentionally NO generic `build(store, ...)` factory here.
    # `Storage: ConditionalWriteStore` does NOT guarantee a `.clone()` method
    # (that is backend-specific, e.g. SharedInMemoryConditionalStore /
    # S3ConditionalStore both provide it, but the trait does not). The CALLER —
    # which holds a concrete, cloneable store — constructs the ConsumeCore,
    # CompactionIndex, segment store, and live manifest, and passes them in via
    # `__init__`. Same discipline as BrokerCore / ConsumeCore (whose tests build
    # the substrate from a concrete `_Store.clone()`).

    @always_inline
    def slo_backpressure(
        mut self, threshold: Int64 = Int64(1000)
    ) raises -> SloDecision:
        """The flush back-pressure decision: how many live
        segments are NOT yet compacted (live num_chunks - compacted segments
        folded so far), compared against `threshold`. The producer consults
        this to throttle when the live tier outruns compaction."""
        var live_n = self._consume.num_chunks()
        var compacted = self._index.resolve_compacted()
        var folded = Int64(0)
        for i in range(len(compacted)):
            folded += (
                compacted[i].supersedes_hi - compacted[i].supersedes_lo + Int64(1)
            )
        var uncompacted = live_n - folded
        if uncompacted < Int64(0):
            uncompacted = Int64(0)
        return evaluate_slo_backpressure(uncompacted, threshold)

    # -------------------------------------------------------------------------
    # run_once — execute one bounded compaction round.
    # -------------------------------------------------------------------------

    def run_once(
        mut self,
        now_ms: Int64,
        min_segments: Int64 = Int64(2),
        max_segments: Int64 = Int64(64),
        codec: CompressionCodec = CompressionCodec.SNAPPY,
    ) raises -> CompactionRoundResult:
        """Execute one bounded compaction round. Compacts a contiguous prefix of
        UNCOMPACTED live segments (>= `min_segments`, <= `max_segments`,
        starting at the compacted tail) into ONE Parquet object.

        Returns `CompactionRoundResult.none()` when there are fewer than
        `min_segments` uncompacted live segments (nothing worth a round yet).

        The order is commit-then-supersede (crash-safe — see the module header):
        PUT Parquet -> append compacted entry -> tombstone superseded live
        chunks. The grace-gated ReapWorker (REUSED) reaps the tombstoned live
        segments after the grace period.
        """
        # 1. Live index + the compacted boundary.
        var live_index = self._consume.resolve_index()
        var compacted_tail = self._index.compacted_tail_offset()

        # 2. Select the contiguous UNCOMPACTED prefix starting at compacted_tail.
        # A live SegmentRef is uncompacted iff base_offset >= compacted_tail
        # (the compacted prefix is [0, compacted_tail) by contiguity invariant).
        var selected = List[SegmentRef]()
        for i in range(len(live_index)):
            ref s = live_index[i]
            if s.base_offset < compacted_tail:
                continue  # already compacted (superseded prefix)
            selected.append(s.copy())
            if Int64(len(selected)) >= max_segments:
                break

        if Int64(len(selected)) < min_segments:
            return CompactionRoundResult.none()

        # The selected segments MUST be contiguous + start at compacted_tail
        # (offset contiguity; checked before committing).
        if selected[0].base_offset != compacted_tail:
            raise Error(
                "CompactionWorker.run_once: first uncompacted segment base "
                + String(selected[0].base_offset)
                + " != compacted tail "
                + String(compacted_tail)
                + " (live/compacted offset desync — refusing to compact)"
            )
        for i in range(1, len(selected)):
            if selected[i].base_offset != selected[i - 1].last_offset + Int64(1):
                raise Error(
                    "CompactionWorker.run_once: NON-CONTIGUOUS live segments at"
                    " index "
                    + String(i)
                    + " (gap between offsets "
                    + String(selected[i - 1].last_offset)
                    + " and "
                    + String(selected[i].base_offset)
                    + ")"
                )

        var base_offset = selected[0].base_offset
        var last_offset = selected[len(selected) - 1].last_offset
        var record_count = last_offset - base_offset + Int64(1)
        var supersedes_lo = selected[0].chunk_seq
        var supersedes_hi = selected[len(selected) - 1].chunk_seq

        # 3. Read each selected segment's Arrow-IPC stream bytes.
        var segment_streams = Slab[List[UInt8]]()
        for i in range(len(selected)):
            var seg = self._consume.read_segment(selected[i].copy())
            # ConsumeSegment.stream_bytes is the Arrow-IPC stream (footer sliced
            # off by read_segment). take_stream_bytes consumes the whole segment
            # and hands back the bytes (no partial-move, no copy).
            segment_streams.append(seg^.take_stream_bytes())

        # 4. Transcode the streams -> ONE Parquet object's bytes (no local disk).
        var parquet_bytes = transcode_segments_to_parquet(
            segment_streams^, codec=codec
        )

        # 5. PUT the Parquet object to the compacted-tier key.
        self._round_counter += Int64(1)
        var pkey = _compacted_parquet_key(
            self._cluster,
            self._topic,
            self._partition,
            base_offset,
            last_offset,
            self._round_counter,
        )
        var _put = self._segment_store.put(Path.parse(pkey), parquet_bytes^)
        _ = _put

        # 6. APPEND the CompactedEntry (lazy-swap commit; contiguity asserted
        #    fail-loud inside append_compacted).
        var _ar = self._index.append_compacted(
            parquet_key=String(pkey),
            base_offset=base_offset,
            last_offset=last_offset,
            record_count=record_count,
            supersedes_lo=supersedes_lo,
            supersedes_hi=supersedes_hi,
        )
        _ = _ar

        # 7. TOMBSTONE the superseded LIVE chunks (the grace-gated ReapWorker
        #    reaps them after the grace period). schedule_for_delete_at stamps
        #    the marker with `now_ms` so the grace window is measured from here.
        var tombstoned = Int64(0)
        var seq = supersedes_lo
        while seq <= supersedes_hi:
            self._live_manifest.schedule_for_delete_at(seq, now_ms)
            tombstoned += Int64(1)
            seq += Int64(1)

        # 8. ADVANCE the live log_start past the superseded prefix (atomic
        #    If-Match CAS), exactly as the retention pass does. This is REQUIRED
        #    for correctness: the live ConsumeCore.resolve_index is log_start-
        #    aware — it seeds its running base offset from log_start and starts
        #    at log_start_seq. Without this advance, after the superseded chunks
        #    are reaped, resolve_index would start at seq 0 (404 on the reaped
        #    chunks) with running_base seeded at the OLD log_start, breaking the
        #    surviving live segments' absolute offsets (they'd be dropped/
        #    misnumbered). Advancing to (supersedes_hi+1, last_offset+1) makes
        #    the live tier start at the first STILL-LIVE chunk with its correct
        #    absolute base, so the dual-tier consume sees the live suffix.
        var new_log_start_seq = supersedes_hi + Int64(1)
        var new_log_start_offset = last_offset + Int64(1)
        var _adv = self._advance_log_start_cas(
            new_log_start_seq, new_log_start_offset
        )
        _ = _adv

        return CompactionRoundResult(
            compacted=True,
            parquet_key=pkey^,
            base_offset=base_offset,
            last_offset=last_offset,
            record_count=record_count,
            segments_compacted=Int64(len(selected)),
            supersedes_lo=supersedes_lo,
            supersedes_hi=supersedes_hi,
            tombstoned_count=tombstoned,
        )

    def _advance_log_start_cas(
        mut self, new_seq: Int64, new_offset: Int64
    ) raises -> Bool:
        """Advance the live log_start to (new_seq, new_offset) via If-Match CAS,
        with a bounded re-read-on-412 retry. Never moves the pointer backwards
        (a state already at/past the target → no-op). Mirrors
        `RetentionPass._advance_log_start_cas`. Returns True iff the pointer
        ended at/after the target."""
        var attempts = 0
        while attempts < 8:
            attempts += 1
            var cur = self._live_manifest.read_log_start()
            if cur.log_start_seq >= new_seq:
                # NEW-6 (concurrent log_start advance): a concurrent pass (the
                # other of retention/compaction) advanced log_start_seq AT/PAST
                # this pass's target. seq + offset advance TOGETHER monotonically
                # (each advance moves both to the first still-live chunk's base),
                # so a won seq >= new_seq MUST carry a won offset >= new_offset.
                # If not, the two passes diverge on the contiguous offset log (a
                # renumber / torn advance) — do NOT silently no-op past it.
                if cur.log_start_offset < new_offset:
                    raise Error(
                        "CompactionWorker: concurrent log_start advance is"
                        " INCONSISTENT — won log_start_seq "
                        + String(cur.log_start_seq)
                        + " >= target seq "
                        + String(new_seq)
                        + " but won log_start_offset "
                        + String(cur.log_start_offset)
                        + " < target offset "
                        + String(new_offset)
                        + " (offset must advance monotonically with seq)"
                    )
                return True  # concurrent advance already past target
            try:
                _ = self._live_manifest.advance_log_start(
                    new_seq, new_offset, cur.etag
                )
                return True
            except e:
                if _is_precondition_msg(String(e)):
                    continue  # stale etag — re-read and retry
                raise e^
        raise Error(
            "CompactionWorker: advance_log_start exhausted retries under"
            " contention (retryable)"
        )


@always_inline
def _is_precondition_msg(msg: String) -> Bool:
    """Classify a precondition / 412 CAS-conflict store error (the stale-etag
    retry in `_advance_log_start_cas`)."""
    return (
        msg.find("precondition") >= 0
        or msg.find("Precondition") >= 0
        or msg.find("412") >= 0
        or msg.find("PreconditionFailed") >= 0
    )
