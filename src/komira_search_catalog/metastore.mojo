# =============================================================================
# komira_search_catalog/metastore.mojo
#   The durable split catalog of a search index: publish a split, list the
#   live split set, retire and reap merged-away splits, and read across
#   per-writer shards. It is the store behind komira_search_scan's
#   `SearchIndexCatalog` seam.
# =============================================================================
#
# The catalog is not one mutable `meta.json` object. It is an append-only
# manifest lineage, `<index>/meta/manifest/<seq>.chunk`, managed by
# `komira_objectstore.CasManifestStore`, and each chunk body is one encoded
# `SplitSummary`. `SearchMetastore` adds only the payload and the replay
# rules; the compare-and-swap machinery (If-None-Match bootstrap, If-Match
# head advance, retry on 412 with jittered backoff, the process-wide CAS gate,
# and recovery by LIST when the head pointer is missing) all comes from the
# manifest store.
#
# `[Storage]` selects the backend at compile time: any
# `ConditionalWriteStore`, such as a cloud conformer in production or
# `InMemoryConditionalStore` in tests. This library names no cloud client;
# uploading the split object itself is the caller's job, done before
# `publish` (see `SearchMetastore.publish`).
#
# Sharding: many writers appending to one lineage all race one head slot and
# spend most attempts on 412 retries. Instead each writer appends to its own
# sub-lineage `<index>/meta/_lineage/<shard_id>/...`, so it is the only writer
# there and wins on the first attempt. Readers enumerate the sub-lineages,
# plus the unsharded lineage `<index>/meta` that older indexes use, and merge
# the split sets (`list_live_splits_across_shards`). The shard id and path
# helpers live in `komira_objectstore.sublineage_shard_keys` so that other
# indexes can shard the same way without depending on search; they are
# imported here and stay reachable as `komira_search_catalog.metastore.<name>`.
# The reaper for drained writer shards lives in shard_reaper.mojo.
#
# No pointers cross this module's API; every value is owned data or a store
# handle held by value.
# =============================================================================

from komira_objectstore import (
    AppendResult,
    CasManifestStore,
    ConditionalWriteStore,
    RetryPolicy,
    decode_chunk_body,
)
from komira_objectstore.cas_manifest import is_not_found
from komira_objectstore.store import CloneableConditionalWriteStore
from komira_objectstore.sublineage_shard_keys import (
    LINEAGE_BASE_SHARD,
    is_reserved_shard_id,
    make_shard_id,
    shard_manifest_prefix,
    _discover_shard_ids,
)

from komira_search_catalog.generation import (
    generation_floor_key,
    decode_generation_floor,
    raise_generation_floor,
    read_retired_shards,
)
from komira_search_catalog.split_summary import (
    LiveSplitEntry,
    SPLIT_SUMMARY_VERSION,
    SplitSummary,
    decode_split_summary,
    encode_split_summary,
    make_merged_split_summary,
    make_split_summary,
)


# =============================================================================
# SearchMetastore[Storage]
# =============================================================================


struct SearchMetastore[Storage: ConditionalWriteStore](
    Movable, Deinitable
):
    """The split catalog for one manifest lineage (one index, or one shard
    of an index). It holds the `CasManifestStore` by value plus the index
    name.

    The life of a split in the catalog:
      1. `publish` appends its summary; from then on it is live.
      2. Compaction publishes a merged split listing it as an input; readers
         now hide it.
      3. `retire` tombstones its chunk; it leaves the live set but the chunk
         and the split object stay readable.
      4. `reap_chunk` deletes the chunk once a grace period has passed, so an
         in-flight query that already holds the old split never sees a 404.
    """

    var _manifest: CasManifestStore[Self.Storage]
    var _index_name: String

    def __init__(
        out self,
        var manifest: CasManifestStore[Self.Storage],
        var index_name: String,
    ):
        """Take a manifest store already bound to the lineage prefix
        (`<index>/meta`, or a shard's sub-lineage prefix)."""
        self._manifest = manifest^
        self._index_name = index_name^

    @always_inline
    def index_name(self) -> String:
        return self._index_name

    def publish(mut self, var summary: SplitSummary) raises -> AppendResult:
        """Append the summary as the next manifest chunk. This is the point at
        which the split becomes searchable.

        Ordering contract: the split object at `summary.object_key` must
        already be durably written before this call. Written first, a split
        that is never published is a harmless orphan: nothing references it
        and a retention sweep can delete it. Published first, the catalog
        would point readers at an object that does not exist yet.

        The chunk's record count is `summary.doc_count`; the substrate uses it
        for offset bookkeeping only, since splits are keyed by UUID inside the
        body. Returns the `AppendResult` (chunk_seq, etag, attempts)."""
        var body = encode_split_summary(summary)
        return self._manifest.append(body^, summary.doc_count)

    def _replay_live_entries(self) raises -> List[LiveSplitEntry]:
        """Replay the window [log_start_seq, head] and decode each chunk,
        dropping tombstoned sequence numbers and chunks that are already gone.
        Returns (chunk_seq, summary) pairs in publish order. The merge-input
        filter is applied by the public verbs on top of this.

        This must use `read_head_fresh()`, not `read_head()`. A writer defers
        rewriting the durable head object for up to 64 appends to save
        requests, and `read_head()` on a cold handle trusts that object
        whenever it exists. Every reader other than the writer itself is a
        cold handle, so it would stop at a stale head and silently miss every
        split published since; nothing later repairs that. `read_head_fresh()`
        answers from the local cache on a warm handle and LISTs the bucket on
        a cold one, so readers always see the true tail."""
        var head = self._manifest.read_head_fresh()
        var out = List[LiveSplitEntry]()
        if head.chunk_seq < Int64(0):
            return out^  # empty manifest (no publishes yet)
        var log_start = self._manifest.read_log_start().log_start_seq
        var dead = self._manifest.tombstone_seqs()
        var seq = log_start
        if seq < Int64(0):
            seq = Int64(0)
        while seq <= head.chunk_seq:
            if not _contains(dead, seq):
                try:
                    var chunk = self._manifest.read_chunk(seq)
                    # An empty body is the fence seal `reap_drained_shards`
                    # writes, never a split (an encoded summary is never
                    # empty). One a crashed reaper left behind is skipped.
                    if len(chunk) > 0:
                        out.append(
                            LiveSplitEntry(seq, decode_split_summary(chunk))
                        )
                except e:
                    # Only a proven absence is skipped. The store's error
                    # names the object key, so matching a bare "404" would
                    # also skip a permission or server failure on any key
                    # that happens to contain those digits (an index name,
                    # a writer pid in the shard id, chunk 404), and the
                    # split would silently drop out of every query.
                    if not is_not_found(String(e)):
                        raise e^
                    # Reaped after the head was read: neither tombstoned nor
                    # readable. Skip the gap.
            seq += Int64(1)
        return out^

    def list_live_splits(self) raises -> List[SplitSummary]:
        """The live split set, in publish order.

        Drops chunks below the log start, tombstoned chunks, and reaped
        chunks. Also hides any live split whose UUID is an input of a live
        merged split: between publishing a merge and retiring its inputs,
        both are live, and returning both would count the merged documents
        twice. Hiding the inputs makes publish-then-retire look atomic to a
        reader."""
        var entries = self._replay_live_entries()
        var skip = _collect_merge_input_uuids(entries)
        var out = List[SplitSummary]()
        for i in range(len(entries)):
            if not _uuid_in_flat(skip, entries[i].summary.split_uuid):
                out.append(entries[i].summary.copy())
        return out^

    def list_live_splits_with_seq(self) raises -> List[LiveSplitEntry]:
        """Same as `list_live_splits`, but each entry carries the `chunk_seq`
        it was published at. A compactor snapshots this, merges a chosen set,
        then retires exactly those sequence numbers. A split published after
        the snapshot lands at a higher sequence number, outside the retired
        set, so no concurrent publish is lost.

        Ascending publish order (chunk_seq strictly increasing)."""
        var entries = self._replay_live_entries()
        var skip = _collect_merge_input_uuids(entries)
        var out = List[LiveSplitEntry]()
        for i in range(len(entries)):
            if not _uuid_in_flat(skip, entries[i].summary.split_uuid):
                out.append(entries[i].copy())
        return out^

    def generation(self) raises -> Int64:
        """The catalog generation: the number of chunks this lineage has ever
        committed, max(head.chunk_seq + 1, the generation floor). A query
        planner folds this into its plan-cache key, so it must change
        whenever the catalog changes; otherwise a query issued after a
        publish could be answered from a plan cached before it. It also never
        goes down: a cold reader finds the head by LISTing chunks, and reaping
        deletes chunks, so `reap_chunk` first raises the floor to cover the
        chunk it deletes (see generation.mojo). The floor is read after the
        head, which is the order that argument needs.

        Reads `read_head_fresh()` for the same reason as
        `_replay_live_entries`. `num_chunks()` resolves through `read_head()`
        and, on a cold handle, would return the stale deferred head, so the
        generation would not move after a publish. On a cold handle this
        costs a LIST rather than a GET, which the query path already pays in
        the replay; a writer's warm handle stays at zero requests for the
        head. The floor costs one GET."""
        var from_head = self._manifest.read_head_fresh().chunk_seq + Int64(1)
        var floor = self._generation_floor()
        if floor > from_head:
            return floor
        return from_head

    def _generation_floor(self) raises -> Int64:
        """This lineage's durable generation floor, 0 when none was written."""
        try:
            return decode_generation_floor(
                self._manifest.get_object(
                    generation_floor_key(self._manifest.prefix()).raw()
                )
            )
        except e:
            if is_not_found(String(e)):
                return Int64(0)
            raise e^

    def retire(mut self, chunk_seq: Int64) raises -> None:
        """Tombstone `chunk_seq`, stamped with the current wall clock. The
        chunk leaves the live set immediately, so new queries stop fetching
        its split, but the chunk and the split object stay readable until
        `reap_chunk` deletes them after the grace period. Re-retiring
        refreshes the timestamp."""
        self._manifest.schedule_for_delete(chunk_seq)

    def retire_at(mut self, chunk_seq: Int64, schedule_ts_ms: Int64) raises -> None:
        """`retire` with an explicit timestamp in milliseconds, for callers
        and tests that drive their own clock."""
        self._manifest.schedule_for_delete_at(chunk_seq, schedule_ts_ms)

    def tombstone_schedule_ts(self, chunk_seq: Int64) raises -> Int64:
        """The timestamp (ms) recorded when `chunk_seq` was retired. The
        split-object reaper reads it so the chunk and the split object are
        reaped on the same clock. Raises not-found if the chunk is not
        tombstoned."""
        return self._manifest.tombstone_schedule_ts(chunk_seq)

    def tombstoned_seqs(self) raises -> List[Int64]:
        """The chunk sequence numbers currently tombstoned, ascending. The
        tombstone markers are durable, so a reaper that crashed between
        retire and reap finds them again here on its next run."""
        return self._manifest.tombstone_seqs()

    def tombstoned_chunk_object_key(self, chunk_seq: Int64) raises -> String:
        """The split `object_key` recorded in a tombstoned chunk that has not
        been reaped yet. Reaping the chunk deletes the only record of where
        the split object lives, so a reaper must read the key first. Returns
        only the key, not the raw chunk bytes.

        Raises not-found if the chunk is already gone; a reaper treats that as
        "the split object was already reaped"."""
        var chunk = self._manifest.read_chunk(chunk_seq)
        return decode_split_summary(chunk).object_key

    def reap_chunk(mut self, chunk_seq: Int64, now_ms: Int64, grace_ms: Int64) raises -> Bool:
        """Delete a tombstoned chunk and its tombstone marker once
        `now_ms - schedule_ts >= grace_ms`. The grace period must exceed the
        longest query, so a query that picked up the split before it was
        retired can still read it.

        Returns True if the chunk is gone (reaped now, or already reaped),
        False if the grace period has not elapsed yet; the caller leaves the
        tombstone for a later run.

        Two reapers may race. The manifest store's `reap` raises when the
        tombstone is already gone; this method treats that, and a chunk that
        was never tombstoned, as done. Any other error propagates.

        This deletes only the manifest chunk. The split object at
        `summary.object_key` is deleted by the caller on the same grace
        check, using the store it holds."""
        var sched: Int64
        try:
            sched = self._manifest.tombstone_schedule_ts(chunk_seq)
        except e:
            if is_not_found(String(e)):
                # Not tombstoned: never scheduled, or already reaped.
                return True
            raise e^
        if now_ms - sched < grace_ms:
            return False  # grace period not over; keep the tombstone.
        # The chunk is about to stop being listed. Raise the floor to cover it
        # first, so a reader that recovers the head by LIST cannot compute a
        # lower generation than one that still saw this chunk.
        var prefix = self._manifest.prefix()
        raise_generation_floor(
            self._manifest.store_mut(), prefix, chunk_seq + Int64(1)
        )
        try:
            self._manifest.reap(chunk_seq)
        except e:
            # Another reaper got there first: the tombstone is gone and the
            # chunk with it.
            if is_not_found(String(e)) or String(e).find(
                "not ScheduledForDelete"
            ) >= 0:
                return True
            raise e^
        return True


@always_inline
def _contains(xs: List[Int64], v: Int64) -> Bool:
    """Linear membership test. Tombstone lists are small."""
    for i in range(len(xs)):
        if xs[i] == v:
            return True
    return False


def _collect_merge_input_uuids(
    entries: List[LiveSplitEntry],
) -> List[UInt8]:
    """The union (flattened, 16 * n bytes) of the input UUIDs of every live
    merged split. Built only from entries that survived replay, so once a
    merged split is itself retired it stops hiding anything."""
    var out = List[UInt8]()
    for i in range(len(entries)):
        ref s = entries[i].summary
        if s.merge_ops > Int64(0):
            for k in range(len(s.merge_input_uuids)):
                out.append(s.merge_input_uuids[k])
    return out^


def _uuid_in_flat(flat: List[UInt8], u: Array[UInt8, 16]) -> Bool:
    """True iff `u` equals one of the 16-byte records in `flat`."""
    var n = len(flat) // 16
    for i in range(n):
        var is_match = True
        for k in range(16):
            if flat[i * 16 + k] != u[k]:
                is_match = False
                break
        if is_match:
            return True
    return False


# =============================================================================
# Cross-shard read
# =============================================================================
#
# The index-level read: LIST the index's sub-lineages, replay each one, also
# replay the unsharded lineage `<index>/meta`, and merge. The merge-input
# filter runs over the union, so a merged split in the `_base` shard hides its
# inputs even when they live in other writers' shards.
#
# These are free functions over a borrowed cloneable store and the index's
# `<...>/meta` prefix, so `SearchMetastore` stays a single-lineage type. Each
# shard's manifest store is built over `storage.clone()`, which gives every
# shard its own transport.


@fieldwise_init
struct ShardedLiveSplitEntry(Copyable, Movable, Deinitable):
    """A live split's summary with the `shard_id` and `chunk_seq` it was
    published under. A compactor needs both to retire a chunk in the right
    lineage. The unsharded lineage is tagged with the empty shard id, so it is
    addressed by its bare `<index>/meta` prefix."""

    var shard_id: String
    var chunk_seq: Int64
    var summary: SplitSummary


def _replay_shard_entries[
    Storage: CloneableConditionalWriteStore
](
    storage: Storage,
    lineage_prefix: String,
    shard_id: String,
    index_name: String,
) raises -> List[ShardedLiveSplitEntry]:
    """Replay one lineage and tag each entry with `shard_id`. The
    merge-input filter is not applied here: it must run over the union of
    all shards."""
    var manifest = CasManifestStore[Storage](
        storage.clone(), lineage_prefix.copy(), RetryPolicy.default()
    )
    var meta = SearchMetastore[Storage](manifest^, index_name.copy())
    var raw = meta._replay_live_entries()
    var out = List[ShardedLiveSplitEntry]()
    for i in range(len(raw)):
        out.append(
            ShardedLiveSplitEntry(
                shard_id.copy(), raw[i].chunk_seq, raw[i].summary.copy()
            )
        )
    return out^


def _collect_merge_input_uuids_sharded(
    entries: List[ShardedLiveSplitEntry],
) -> List[UInt8]:
    """`_collect_merge_input_uuids` over the cross-shard union."""
    var out = List[UInt8]()
    for i in range(len(entries)):
        ref s = entries[i].summary
        if s.merge_ops > Int64(0):
            for k in range(len(s.merge_input_uuids)):
                out.append(s.merge_input_uuids[k])
    return out^


def list_live_splits_across_shards_with_seq[
    Storage: CloneableConditionalWriteStore
](
    storage: Storage,
    index_meta_prefix: String,
    index_name: String,
) raises -> List[ShardedLiveSplitEntry]:
    """The live (shard_id, chunk_seq, summary) set of a whole index.

    Enumerates the sub-lineages under `<index_meta_prefix>/_lineage/`,
    replays each one, always replays the unsharded lineage
    `<index_meta_prefix>` too (tagged with shard id ""), and applies the
    merge-input filter over the union. An index written before sharding is
    served from the unsharded lineage, a newer one from its shards, and a
    mixed one from both; there are no duplicates because each split is
    published to exactly one lineage.

    Order is deterministic: discovered shards in LIST order, then the
    unsharded lineage."""
    var union = List[ShardedLiveSplitEntry]()

    var shard_ids = _discover_shard_ids(storage, index_meta_prefix)
    for i in range(len(shard_ids)):
        var lineage_prefix = shard_manifest_prefix(
            index_meta_prefix, shard_ids[i]
        )
        var shard_entries = _replay_shard_entries(
            storage, lineage_prefix, shard_ids[i], index_name
        )
        for j in range(len(shard_entries)):
            union.append(shard_entries[j].copy())

    # An index created after sharding simply has no chunks here.
    var legacy_entries = _replay_shard_entries(
        storage, index_meta_prefix, String(""), index_name
    )
    for j in range(len(legacy_entries)):
        union.append(legacy_entries[j].copy())

    var skip = _collect_merge_input_uuids_sharded(union)
    var out = List[ShardedLiveSplitEntry]()
    for i in range(len(union)):
        if not _uuid_in_flat(skip, union[i].summary.split_uuid):
            out.append(union[i].copy())
    return out^


def list_live_splits_across_shards[
    Storage: CloneableConditionalWriteStore
](
    storage: Storage,
    index_meta_prefix: String,
    index_name: String,
) raises -> List[SplitSummary]:
    """The live split set of a whole index, for the query path. Use the
    `_with_seq` variant when the shard id and sequence number are needed."""
    var entries = list_live_splits_across_shards_with_seq(
        storage, index_meta_prefix, index_name
    )
    var out = List[SplitSummary]()
    for i in range(len(entries)):
        out.append(entries[i].summary.copy())
    return out^


def _lineage_generation[
    Storage: CloneableConditionalWriteStore
](storage: Storage, lineage_prefix: String, index_name: String) raises -> Int64:
    var manifest = CasManifestStore[Storage](
        storage.clone(), lineage_prefix.copy(), RetryPolicy.default()
    )
    var meta = SearchMetastore[Storage](manifest^, index_name.copy())
    return meta.generation()


def generation_across_shards[
    Storage: CloneableConditionalWriteStore
](storage: Storage, index_meta_prefix: String, index_name: String) raises -> Int64:
    """The index-level generation: the sum over shard ids of each shard's
    generation, plus the unsharded lineage's. A shard id counts once, as
    max(its live `generation()`, the value recorded when it was reaped), and
    a reaped shard keeps counting its recorded value.

    It is not a unique global version. It changes whenever the catalog
    changes (any publish in any shard raises the sum) and it never goes down
    (see generation.mojo for the argument). The retired-shards record is read
    after every live shard, which is the order that argument needs."""
    var shard_ids = _discover_shard_ids(storage, index_meta_prefix)
    var live = List[Int64]()
    for i in range(len(shard_ids)):
        live.append(
            _lineage_generation(
                storage,
                shard_manifest_prefix(index_meta_prefix, shard_ids[i]),
                index_name,
            )
        )
    var total = _lineage_generation(storage, index_meta_prefix, index_name)
    var retired = read_retired_shards(storage, index_meta_prefix)
    for i in range(len(shard_ids)):
        var recorded = retired.generation_of(shard_ids[i])
        if recorded > live[i]:
            total += recorded
        else:
            total += live[i]
    for j in range(len(retired)):
        var still_listed = False
        for i in range(len(shard_ids)):
            if retired.find(shard_ids[i]) == j:
                still_listed = True
                break
        if not still_listed:
            total += retired.generations[j]
    return total
