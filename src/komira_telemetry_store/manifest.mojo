# =============================================================================
# komira_telemetry_store.manifest: DISCOVERY BY MANIFEST REPLAY, NEVER BY
#   LISTING. And the replay itself is EXACT GETs, all the way down.
# =============================================================================
#
# The substrate is `CasManifestStore` UNCHANGED: append-only immutable chunks
# under a prefix, conditional-create, `_HEAD` tail pointer, body ENTIRELY
# OPAQUE. What this module adds is a body type that carries a TIME RANGE
# (`segment_entry.mojo`) and a replay that does not list.
#
# -- HOW A READER FINDS DATA, AND WHERE THE ONE LIST IS -----------------------
#   1. COMPUTE the `YYYYMMDD` prefixes covering [t0,t1].  Arithmetic. No I/O.
#   2. Per day: ONE LIST, writer-shard enumeration through `_discover_shard_ids`
#      (`komira_objectstore/sublineage_shard_keys.mojo`), the union-fold
#      spelling that is correct on BOTH object-store conformers. THIS IS THE
#      ONLY LISTING IN THE LAYOUT.
#   3. Per shard: REPLAY BY EXACT GET. Zero listing.
#   4. PRUNE on the manifest entries alone: a pruned-out object is NEVER GET.
#   5. GET exactly the surviving `object_key`s.
#
# -- WHY THE REPLAY DOES NOT LIST ---------------------------------------------
# A replay that trusts the durable `_HEAD` alone is wrong, and a replay that
# LISTS the bucket to repair it pays an O(chunks) LIST. Two listings would
# otherwise be needed:
#
#   * recovering the head by LIST when the reader is cold;
#   * discovering tombstones by LISTing `<prefix>/tombstones/`.
#
# The bug behind the first is real. `CasManifestStore` DEFERS its durable
# `_HEAD` advance for up to `_HEAD_ADVANCE_DEFER_CADENCE = 64` warm appends. The
# FIRST append (cold cache) advances `_HEAD` durably; every warm append after
# it DEFERS. So a writer that publishes N segments on one handle leaves the
# durable `_HEAD` pinned at seq 0, and a FRESH reader that trusts `_HEAD` sees
# ONE segment and silently misses N-1. That is not a cache miss: nothing repairs
# it.
#
# THE ANSWER HERE IS A FORWARD PROBE, NOT A LIST, and it is available precisely
# BECAUSE key depth is a constant (keys.mojo rule 3): a chunk's key is
# `<prefix>/manifest/<seq:020d>.chunk`, so seq N+1 is a COMPUTED NAME. Replay
# therefore runs in two regions:
#
#   (a) [log_start .. durable_head]  GAP-TOLERANT. A reaped chunk is a hole
#       here (compaction retires merged inputs, which sit mid-log), so a
#       not-found is SKIPPED.
#   (b) (durable_head .. inf)        STRICT. The deferred-advance tail. Probe
#       forward one computed key at a time and stop at the FIRST not-found.
#       Nothing above a durable head has been tombstoned-and-reaped: the reaper
#       only ever acts on seqs a head has already covered.
#
# Cost: ONE extra GET over reading the head, against an O(surviving-chunks)
# LIST; the replay must GET every chunk body anyway.
#
# -- AND THE TOMBSTONE LIST IS NOT NEEDED EITHER, BOTH CASES NAMED ------------
# Every chunk a tombstone LIST would drop is already handled here without it,
# and there are exactly two kinds:
#
#   * COMPACTION INPUTS. The dup-window skip (`merge_input_uuids`) drops them
#     while the merge is live, which is what makes publish+tombstone OBSERVABLY
#     ATOMIC: no row is double-counted whether or not the inputs are
#     tombstoned yet, let alone reaped.
#   * RETENTION RETIREMENT. Retention advances `_LOG_START`
#     (`cas_manifest.advance_log_start`), and this replay STARTS at `log_start`,
#     so a retention-retired chunk is below the window and is never read,
#     tombstone or no tombstone. That read is one exact GET of `_LOG_START`.
#
# So the only chunks that can be tombstoned-but-not-reaped INSIDE
# `[log_start, head]` are merge inputs, and the skip already drops them. A
# reaped chunk anywhere in that window is a hole, which region (a) tolerates.
#
# NO POINTER CROSSES A MODULE BOUNDARY: the surface is owned values only.
# =============================================================================

from komira_objectstore.cas_manifest import (
    AppendResult,
    CasManifestStore,
    RetryPolicy,
    decode_head,
    is_not_found,
)
from komira_objectstore.store import (
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
)
from komira_objectstore.sublineage_shard_keys import (
    _discover_shard_ids,
    shard_manifest_prefix,
)

from komira_telemetry_store.keys import (
    days_covering,
    telemetry_partition_prefix,
)
from komira_telemetry_store.segment_entry import (
    TELEMETRY_UUID_BYTES,
    TelemetrySegmentEntry,
    decode_telemetry_segment_entry,
    encode_telemetry_segment_entry,
    uuid_in_flat,
)


@fieldwise_init
struct TelemetryLiveEntry(Copyable, Movable, Deinitable):
    """A live segment plus the manifest `chunk_seq` it was published at.

    The seq is what a compactor retires (`retire(seq)`) for EXACTLY the segments
    it merged — never a watermark, because a segment published after the
    compactor's snapshot lands at a higher seq and is structurally outside the
    retire set."""

    var chunk_seq: Int64
    var entry: TelemetrySegmentEntry


struct TelemetrySegmentManifest[Storage: ConditionalWriteStore](
    Movable, Deinitable
):
    """ONE writer shard's segment catalog for ONE `(dataset, day)` partition.

    A plain domain adapter over the shared `CasManifestStore`, with a
    time-range body and a replay that does not list."""

    var _manifest: CasManifestStore[Self.Storage]

    def __init__(out self, var manifest: CasManifestStore[Self.Storage]):
        self._manifest = manifest^

    @always_inline
    def prefix(self) -> String:
        return self._manifest.prefix()

    # ---- publish ------------------------------------------------------------

    def publish(mut self, var entry: TelemetrySegmentEntry) raises -> AppendResult:
        """Append the entry as the next manifest chunk. The `.parquet` object
        MUST already be PUT before this call — the append is the linearization
        point that makes the segment READABLE, and a manifest entry naming an
        absent object is the one ordering that loses data instead of bytes.

        `record_count = entry.row_count`, so the substrate's contiguous-range
        bookkeeping counts ROWS, matching what the reader is about to fetch."""
        var rows = entry.row_count
        var body = encode_telemetry_segment_entry(entry)
        return self._manifest.append(body^, rows)

    # ---- replay -------------------------------------------------------------

    def _durable_head_seq(self) raises -> Int64:
        """The durable `_HEAD`'s chunk_seq by ONE EXACT GET, or -1 if absent.

        NOT `read_durable_head()`, and the difference is the whole point of
        this module: that method falls back to `_recover_head_by_list` when
        `_HEAD` is ABSENT, so on a fresh partition it LISTS. Here an absent
        `_HEAD` simply means "no durable tail yet" and region (b) — the strict
        forward probe — covers everything from `log_start` upward."""
        try:
            var raw = self._manifest.get_object(self._manifest.prefix() + "/_HEAD")
            return decode_head(raw).chunk_seq
        except e:
            if is_not_found(String(e)):
                return Int64(-1)
            raise e^

    def replay_live_entries(self) raises -> List[TelemetryLiveEntry]:
        """Replay the whole live window BY EXACT GET. ZERO listing. See the
        header for the two regions and why the forward probe replaces a LIST."""
        var out = List[TelemetryLiveEntry]()
        var log_start = self._manifest.read_log_start().log_start_seq
        if log_start < Int64(0):
            log_start = Int64(0)
        var head = self._durable_head_seq()
        var seq = log_start
        # (a) the durably-known region: GAP-TOLERANT (reaped chunks are holes).
        while seq <= head:
            try:
                var chunk = self._manifest.read_chunk(seq)
                out.append(
                    TelemetryLiveEntry(
                        seq, decode_telemetry_segment_entry(chunk)
                    )
                )
            except e:
                if not is_not_found(String(e)):
                    raise e^
            seq += Int64(1)
        # (b) the deferred-advance tail: STRICT stop at the first not-found.
        while True:
            var chunk: List[UInt8]
            try:
                chunk = self._manifest.read_chunk(seq)
            except e:
                if is_not_found(String(e)):
                    break
                raise e^
            out.append(
                TelemetryLiveEntry(seq, decode_telemetry_segment_entry(chunk))
            )
            seq += Int64(1)
        return out^

    def live_segments(self) raises -> List[TelemetrySegmentEntry]:
        """The live segment set with the dup-window skip applied — every row
        EXACTLY ONCE, including inside a compaction's publish->tombstone
        window."""
        var entries = self.replay_live_entries()
        return apply_merge_input_skip(entries)

    def segments_overlapping(
        self, t0_ns: Int64, t1_ns: Int64
    ) raises -> List[TelemetrySegmentEntry]:
        """THE PRUNE. Live segments whose CLOSED [min_ts,max_ts] intersects
        the CLOSED query range — decided on the MANIFEST ENTRY ALONE, so a
        pruned-out object is never fetched. This is the property the whole
        layout exists to provide."""
        var live = self.live_segments()
        var out = List[TelemetrySegmentEntry]()
        for i in range(len(live)):
            if live[i].overlaps_time(t0_ns, t1_ns):
                out.append(live[i].copy())
        return out^


def apply_merge_input_skip(
    entries: List[TelemetryLiveEntry],
) raises -> List[TelemetrySegmentEntry]:
    """Drop any live segment whose uuid appears in a LIVE merged segment's
    input set.

    WITHOUT THIS, EVERY ROW IN THE WINDOW IS RETURNED TWICE. Between a
    compaction's publish (the merge is live) and its tombstone-of-inputs (the
    inputs are still live), both are in the manifest. On a metrics dashboard
    that is a silently doubled rate; in logs it is every line duplicated. The
    skip is what makes publish+tombstone OBSERVABLY ATOMIC."""
    var skip = List[UInt8]()
    for i in range(len(entries)):
        ref e = entries[i].entry
        for b in range(len(e.merge_input_uuids)):
            skip.append(e.merge_input_uuids[b])
    var out = List[TelemetrySegmentEntry]()
    for i in range(len(entries)):
        if not uuid_in_flat(skip, entries[i].entry.segment_uuid):
            out.append(entries[i].entry.copy())
    return out^


def open_partition_manifest[
    Storage: CloneableConditionalWriteStore
](
    store: Storage,
    root: String,
    dataset: String,
    day: String,
    writer_id: String,
    retry: RetryPolicy = RetryPolicy.default(),
) raises -> TelemetrySegmentManifest[Storage]:
    """Bind a manifest to ONE `(dataset, day, writer_id)` sub-lineage at
    `<root>/<ds>/<day>/_lineage/<writer_id>`, the object store's sub-lineage shape,
    so concurrent writers never CAS-contend on one `_HEAD`."""
    var lineage = shard_manifest_prefix(
        telemetry_partition_prefix(root, dataset, day), writer_id
    )
    return TelemetrySegmentManifest[Storage](
        CasManifestStore[Storage](store.clone(), lineage^, retry)
    )


def discover_partition_writer_ids[
    Storage: ConditionalWriteStore
](store: Storage, root: String, dataset: String, day: String) raises -> List[String]:
    """THE ONE LISTING IN THE WHOLE LAYOUT: writer-shard enumeration for one
    `(dataset, day)` partition.

    It goes through `_discover_shard_ids`, which folds the UNION of
    `objects`-derived ids and `common_prefixes`-derived ids, deduped. That union
    is the spelling that is correct on both conformers: it does not DEPEND on
    `common_prefixes` (which a local-filesystem store never populates) and it
    TOLERATES them (which a cloud store always returns). Every other
    read-path key in this layout is an exact GET of a computed name."""
    return _discover_shard_ids[Storage](
        store, telemetry_partition_prefix(root, dataset, day)
    )


@fieldwise_init
struct TelemetryReadPlan(Copyable, Movable, Deinitable):
    """What a time-range read must fetch, and the accounting that proves the
    pruning happened.

    `segments` are the ONLY objects the reader GETs. `considered` is how many
    manifest entries were examined — reported so a test can assert that pruning
    SKIPPED something rather than merely returning everything, which is the
    vacuous shape a count-only assertion would miss."""

    var segments: List[TelemetrySegmentEntry]
    var considered: Int
    var partitions_scanned: Int


def plan_time_range_read[
    Storage: CloneableConditionalWriteStore
](
    store: Storage,
    root: String,
    dataset: String,
    t0_ns: Int64,
    t1_ns: Int64,
    retry: RetryPolicy = RetryPolicy.default(),
) raises -> TelemetryReadPlan:
    """END TO END: compute the day prefixes, enumerate writer shards (the
    one LIST), replay each shard by exact GET, prune on manifest entries, and
    return exactly the objects worth fetching.

    Step 1 is what makes the rest cheap: the partition set is COMPUTED from the
    range, so a 15-minute dashboard query considers ONE day whatever the
    retention window holds."""
    var days = days_covering(t0_ns, t1_ns)
    var segments = List[TelemetrySegmentEntry]()
    var considered = 0
    for d in range(len(days)):
        var writers = discover_partition_writer_ids[Storage](
            store, root, dataset, days[d]
        )
        for w in range(len(writers)):
            var m = open_partition_manifest[Storage](
                store, root, dataset, days[d], writers[w], retry
            )
            var live = m.live_segments()
            considered += len(live)
            for i in range(len(live)):
                if live[i].overlaps_time(t0_ns, t1_ns):
                    segments.append(live[i].copy())
            _ = m^
    return TelemetryReadPlan(segments^, considered, len(days))
