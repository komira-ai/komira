# =============================================================================
# komira_telemetry_read.scan_plan: a time range in, a set of object keys out.
# =============================================================================
#
# `plan_telemetry_scan` turns `[t0_ns, t1_ns]` over one dataset into the object
# keys a query engine must open, and nothing more. The answer to "which objects
# do I have to open?" is what a reader of the at-rest format cannot get without
# replaying the manifest, so this is the surface that matters: hand
# `TelemetryScanPlan.object_keys()` to DuckDB, pyarrow or Polars, or to
# `segment_read.mojo` in this package. Nothing about the surviving set is
# specific to this package's decoder.
#
# The key layout, the catalog entry and the merge-input uuid test all come from
# `komira_telemetry_store`, the writer side. This module states no key and no
# entry layout of its own, so a reader and a writer cannot drift apart.
#
# -- THE FOUR STEPS -----------------------------------------------------------
#   1. COMPUTE the UTC day strings the range touches. Arithmetic, no I/O, at
#      most `MAX_TELEMETRY_DAYS_PER_QUERY` of them.
#   2. Per day: the writer-shard enumeration LIST, `_discover_shard_ids`, the
#      union fold that is correct whether or not the backend populates
#      `common_prefixes` (a local-filesystem store never does; a cloud store
#      always does).
#   3. Per shard: replay the manifest by exact GET (`_replay_lineage_entries`).
#   4. PRUNE on the catalog entries alone: time overlap, then the optional
#      series overlap, then the merge-input skip. A pruned object is never GET.
#
# -- HOW MANY LISTs, MEASURED -------------------------------------------------
# Replaying one lineage needs the tombstone set, and
# `CasManifestStore.tombstone_seqs()` discovers it by LISTing
# `<prefix>/tombstones/` and `<prefix>/moved_tombstones/`. So the cost is
#
#     LISTs = (one per DAY, shard enumeration) + (two per SHARD, tombstones)
#
# It is O(partitions), never O(objects), and every one of those LISTs is
# single-level with a `/`-free remainder, so both object-store conformer
# families answer it. The scan-plan tests count it off the in-memory store's
# `n_list()`.
#
# -- THE DURABLE `_HEAD` IS A LOWER BOUND, NOT THE TAIL -----------------------
# `CasManifestStore` defers the durable `_HEAD` advance for up to 64 warm
# appends, so a writer that published N segments on one handle can leave `_HEAD`
# at the first chunk. A reader that trusted it would see one segment and miss
# the newest N-1, with no error. This replay therefore probes forward past the
# head: chunk seqs are dense above `log_start`, so the true tail is found by
# GETting `head+1, head+2, ...` until the first not-found. Every probe is an
# exact GET of a computed key; the cost is one wasted GET beyond the tail.
#
# THE TWO NOT-FOUND ARMS MEAN DIFFERENT THINGS AND MUST NOT BE MERGED:
#   * at or below the durable head -> a REAPED chunk. Skip it and keep going.
#   * above the durable head       -> the TRUE TAIL. Stop.
# Merging them either truncates the replay at the first reap gap (data loss) or
# scans forever past the tail (an unbounded read).
#
# `Storage` is borrowed and cloned per lineage. Every public signature takes
# and returns values (String, Int64, List, owned structs).
# =============================================================================

from komira_objectstore.store import CloneableConditionalWriteStore
from komira_objectstore.cas_manifest import (
    CasManifestStore,
    RetryPolicy,
    is_not_found,
)
from komira_objectstore.sublineage_shard_keys import (
    _discover_shard_ids,
    shard_manifest_prefix,
)

from komira_telemetry_store.keys import (
    TELEMETRY_ROOT,
    days_covering,
    telemetry_partition_prefix,
)
from komira_telemetry_store.segment_entry import (
    TelemetrySegmentEntry,
    decode_telemetry_segment_entry,
    uuid_in_flat,
)


# =============================================================================
# §1 — the optional series filter (metrics only).
# =============================================================================


@fieldwise_init
struct TelemetrySeriesFilter(Copyable, Movable, Deinitable):
    """An OPTIONAL `[lo, hi]` filter on `series_id`, for the metrics dataset.

    `active` IS NOT REDUNDANT WITH A SENTINEL RANGE. A log segment carries
    `min_series_id == max_series_id == 0`, so any non-trivial range filter
    applied unguarded to the log dataset prunes EVERY segment and returns an
    empty plan over a bucket full of data: a silent, total false negative.
    `none()` is therefore the default and the guard is explicit."""

    var active: Bool
    var lo: Int64
    var hi: Int64

    @staticmethod
    def none() -> TelemetrySeriesFilter:
        """No series filter: the only correct value for the `logs` dataset."""
        return TelemetrySeriesFilter(False, Int64(0), Int64(0))

    @staticmethod
    def range(lo: Int64, hi: Int64) -> TelemetrySeriesFilter:
        """Keep only segments whose series range intersects `[lo, hi]`."""
        return TelemetrySeriesFilter(True, lo, hi)


# =============================================================================
# §2 — the plan.
# =============================================================================


struct TelemetryScanPlan(Movable, Deinitable):
    """The answer to "which objects hold `[t0,t1]` of `<dataset>`?", plus the
    accounting that makes the answer auditable.

    `object_keys()` is the deliverable: plain `String`s, not a handle to
    anything of this package's.

    THE ACCOUNTING FIELDS TELL "NOTHING MATCHED" FROM "NOTHING WAS READ".
    `entries_replayed == 0` means the catalog is empty: nothing has been
    published, or the day or prefix is wrong. `entries_replayed > 0` with
    `len(segments) == 0` means the catalog is full and the time range excluded
    all of it. Those are opposite problems that produce the identical empty
    result. `pruned_by_time` is also the only honest way to state the
    read-amplification win: a plan that pruned 0 of 4 segments is a full scan.

    Movable-only (owns Lists)."""

    var dataset: String
    var t0_ns: Int64
    var t1_ns: Int64
    var days: List[String]
    var segments: List[TelemetrySegmentEntry]
    var shards_replayed: Int
    var entries_replayed: Int
    var pruned_by_time: Int
    var pruned_by_series: Int
    var skipped_absorbed: Int

    def __init__(
        out self,
        var dataset: String,
        t0_ns: Int64,
        t1_ns: Int64,
        var days: List[String],
        var segments: List[TelemetrySegmentEntry],
        shards_replayed: Int,
        entries_replayed: Int,
        pruned_by_time: Int,
        pruned_by_series: Int,
        skipped_absorbed: Int,
    ):
        self.dataset = dataset^
        self.t0_ns = t0_ns
        self.t1_ns = t1_ns
        self.days = days^
        self.segments = segments^
        self.shards_replayed = shards_replayed
        self.entries_replayed = entries_replayed
        self.pruned_by_time = pruned_by_time
        self.pruned_by_series = pruned_by_series
        self.skipped_absorbed = skipped_absorbed

    def object_keys(self) -> List[String]:
        """The surviving `.parquet` keys, ascending by `min_ts_ns`.

        A reader runs `SELECT * FROM read_parquet([...these keys...]) WHERE ts
        BETWEEN ...` and never calls this package again."""
        var out = List[String](capacity=len(self.segments))
        for i in range(len(self.segments)):
            out.append(self.segments[i].object_key.copy())
        return out^

    def rows_selected(self) -> Int64:
        """Rows the surviving segments hold, from the CATALOG: known before a
        single data byte is fetched, so a "this query will read N rows"
        warning is possible at plan time."""
        var n = Int64(0)
        for i in range(len(self.segments)):
            n += self.segments[i].row_count
        return n

    def bytes_selected(self) -> Int64:
        """Bytes the surviving segments hold, from the catalog."""
        var n = Int64(0)
        for i in range(len(self.segments)):
            n += self.segments[i].byte_size
        return n


# =============================================================================
# §3 — the manifest replay.
# =============================================================================


def _contains_seq(xs: List[Int64], v: Int64) -> Bool:
    for i in range(len(xs)):
        if xs[i] == v:
            return True
    return False


def _replay_lineage_entries[
    Storage: CloneableConditionalWriteStore
](storage: Storage, lineage_prefix: String) raises -> List[
    TelemetrySegmentEntry
]:
    """Replay ONE writer sub-lineage's manifest into its live segment entries.

    Reads, in order:
      * `<prefix>/_HEAD`         one exact GET (`read_durable_head`): a LOWER
                                 BOUND on the tail, never trusted as the tail.
      * `<prefix>/_LOG_START`    one exact GET; absent means never truncated.
      * `<prefix>/tombstones/`   one LIST.
      * `<prefix>/manifest/<seq:020d>.chunk` exact GETs, from `log_start`
                                 upward, past the durable head to the first
                                 gap above it.

    NO `except: pass`. A not-found is the only tolerated store error and its two
    meanings are separated by position (below the head = reaped, above = the
    tail). Anything else (a permission fault, a truncated body, an unknown
    envelope version) raises, because an empty page that means "the bucket is
    unreachable" reads exactly like "nothing was logged"."""
    var manifest = CasManifestStore[Storage](
        storage.clone(), lineage_prefix.copy(), RetryPolicy.default()
    )
    var out = List[TelemetrySegmentEntry]()

    var durable_tail = manifest.read_durable_head().chunk_seq
    var log_start = manifest.read_log_start().log_start_seq
    var dead = manifest.tombstone_seqs()

    var seq = log_start
    if seq < Int64(0):
        seq = Int64(0)

    # ONE loop over both regions. `seq <= durable_tail` selects the arm.
    while True:
        if _contains_seq(dead, seq):
            # Tombstoned (retired by compaction, not yet reaped). Skip the body
            # and KEEP WALKING: a tombstone is not the end of the manifest, and
            # that holds above the durable head too. A tombstone marker only
            # exists for a slot that was COMMITTED, so it is positive evidence
            # the true tail is at least here. The forward probe must therefore
            # NOT treat a tombstoned seq as its terminating condition; only a
            # not-found chunk above the head ends the walk.
            seq += Int64(1)
            continue
        var body: List[UInt8]
        try:
            body = manifest.read_chunk(seq)
        except e:
            if not is_not_found(String(e)):
                raise e^
            # `read_chunk` raising a not-found message (matched by
            # `is_not_found`) is the only way to reach this arm; any other
            # error was re-raised above, and `out` is local, so no partial
            # state escapes.
            if seq > durable_tail:
                break  # THE TRUE TAIL: the probe's terminating condition.
            seq += Int64(1)
            continue  # a REAPED gap below the head.
        out.append(decode_telemetry_segment_entry(body))
        seq += Int64(1)
    return out^


def plan_telemetry_scan[
    Storage: CloneableConditionalWriteStore
](
    storage: Storage,
    dataset: String,
    t0_ns: Int64,
    t1_ns: Int64,
    series: TelemetrySeriesFilter = TelemetrySeriesFilter.none(),
) raises -> TelemetryScanPlan:
    """The direct query path. `[t0_ns, t1_ns]` (INCLUSIVE) over `dataset` yields
    the object keys a query engine must open, and nothing more. The keys are
    read under `TELEMETRY_ROOT`, the writers' default root.

    The merge-input skip is applied over the UNION of every day and shard, not
    per lineage. Compaction is day-scoped, so a per-day fold would suffice
    today; folding over the whole plan costs one pass and stays correct if that
    ever changes. It is applied AFTER time pruning purely so `skipped_absorbed`
    counts only segments that would otherwise have been read.

    A DAY WITH NO `_lineage/` COSTS ONE LIST AND NOTHING ELSE. That is the
    normal case for most of a 30-day range and it must stay cheap, which is why
    step 2 cannot be replaced by "list the data prefix and see"."""
    var days = days_covering(t0_ns, t1_ns)

    var union = List[TelemetrySegmentEntry]()
    var shards_replayed = 0
    var entries_replayed = 0
    var pruned_by_time = 0
    var pruned_by_series = 0

    for d in range(len(days)):
        var day_root = telemetry_partition_prefix(
            String(TELEMETRY_ROOT), dataset, days[d]
        )
        # STEP 2: the one shard-enumeration LIST for this day.
        var shard_ids = _discover_shard_ids(storage, day_root)
        for s in range(len(shard_ids)):
            var lineage = shard_manifest_prefix(day_root, shard_ids[s])
            var entries = _replay_lineage_entries(storage, lineage)
            shards_replayed += 1
            for i in range(len(entries)):
                entries_replayed += 1
                # STEP 4a: the file-level TIME prune. The whole win.
                if not entries[i].overlaps_time(t0_ns, t1_ns):
                    pruned_by_time += 1
                    continue
                # STEP 4b: the OPTIONAL series prune (metrics only).
                if series.active and not entries[i].overlaps_series(
                    series.lo, series.hi
                ):
                    pruned_by_series += 1
                    continue
                union.append(entries[i].copy())

    # STEP 4c: the merge-input skip over the UNION. Without it, a reader in the
    # window between a compaction's publish and its tombstone returns the merged
    # segment AND every input it absorbed, i.e. every merged row TWICE.
    var absorbed = List[UInt8]()
    for i in range(len(union)):
        if union[i].merge_ops > Int64(0):
            for k in range(len(union[i].merge_input_uuids)):
                absorbed.append(union[i].merge_input_uuids[k])
    var kept = List[TelemetrySegmentEntry]()
    var skipped_absorbed = 0
    for i in range(len(union)):
        if uuid_in_flat(absorbed, union[i].segment_uuid):
            skipped_absorbed += 1
            continue
        kept.append(union[i].copy())

    # Deterministic order: ascending `min_ts_ns`, `object_key` breaking a tie.
    # A TIE-BREAK IS REQUIRED, NOT COSMETIC: two segments flushed in the same
    # millisecond have the same `min_ts_ns`, so without the key comparison the
    # plan's order would depend on shard-enumeration order and a caller's
    # "first N objects" would not be reproducible.
    # Insertion sort: stable, O(k^2) in the surviving entries k (one per
    # segment, not per row). A stable merge sort is the replacement if k grows.
    for i in range(1, len(kept)):
        var j = i
        while j > 0:
            var a = kept[j - 1].min_ts_ns
            var b = kept[j].min_ts_ns
            var swap = a > b
            if a == b and kept[j - 1].object_key > kept[j].object_key:
                swap = True
            if not swap:
                break
            var tmp = kept[j - 1].copy()
            kept[j - 1] = kept[j].copy()
            kept[j] = tmp^
            j -= 1

    return TelemetryScanPlan(
        dataset.copy(),
        t0_ns,
        t1_ns,
        days^,
        kept^,
        shards_replayed,
        entries_replayed,
        pruned_by_time,
        pruned_by_series,
        skipped_absorbed,
    )
