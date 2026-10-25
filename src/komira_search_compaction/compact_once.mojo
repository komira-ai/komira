# =============================================================================
# komira_search_compaction/compact_once.mojo — one compaction pass.
# =============================================================================
#
# `compact_once` is the reusable "run one compaction pass" call that a
# compactor binary and a test both make. It wires the other modules of this
# package and the catalog together; the merge, policy and reap logic live in
# merge_split.mojo, select.mojo, reaper.mojo and the catalog.
#
# It is generic over a `CloneableConditionalWriteStore`: the one store holds
# both the split objects and the manifest lineages, and no cloud client or
# transport type appears here. The caller supplies the store (an object store
# handle in production, an in-memory store in tests).
#
# The pass works over the union of all of the index's lineages: the writer
# shards, the unsharded lineage `<index>/meta`, and the reserved `_base`
# lineage. It writes the merged split into `_base` (the compactor is the only
# writer of `_base`, so its appends never contend), retires each input in the
# lineage it came from, and removes the writer shards that have fully drained,
# which bounds how many lineages a read has to merge.
#
# One `compact_once`:
#
#   1. Snapshot    the live splits of all lineages, each with its shard id and
#                  chunk sequence (`list_live_splits_across_shards_with_seq`).
#   2. Select      `select_merge` over the snapshot.
#   3. If a plan:
#      a. read     the object of each input split from the store;
#      b. merge    `merge_split_bytes`;
#      c. publish  write the merged split object to the store FIRST, then
#                  append its summary to `_base`. A reader that finds the
#                  summary must find the object, and an object whose summary
#                  was never appended is a harmless orphan; the reverse order
#                  would publish a summary naming a missing object. The
#                  summary lists the input UUIDs, so a catalog read hides the
#                  inputs from the moment it is live and publishing the merge
#                  and retiring the inputs look atomic;
#      d. retire   exactly the snapshot chunks that were merged, each in its
#                  source lineage (`retire_at`). A split published into a shard
#                  after the snapshot is outside the retire set, so no update
#                  is lost.
#   4. Reap        the retired chunks of every lineage whose grace period has
#                  passed, from this and earlier runs: the split object first
#                  (its key is read BEFORE the chunk goes), then the manifest
#                  chunk.
#   5. Reap shards `reap_drained_shards`: remove every writer shard whose
#                  splits all folded into `_base`.
#   6. Return      a `CompactionResult`.
#
# A pass is idempotent. The merged object key is content-addressed, so a re-run
# over the same inputs writes the same key; `select_merge` excludes the merged
# split it just produced; the reap tolerates a chunk that is already gone.
#
# One compaction pass at a time per index is the caller's contract. This module
# takes no lock; it relies on the store's compare-and-swap and on the
# content-addressed key to stay correct even if two runs overlap by accident.
#
# No pointer appears in any signature.
# =============================================================================

from komira_objectstore.cas_manifest import CasManifestStore, RetryPolicy
from komira_objectstore.path import Path
from komira_objectstore.store import CloneableConditionalWriteStore
from komira_objectstore.sublineage_shard_keys import (
    LINEAGE_BASE_SHARD,
    shard_manifest_prefix,
    _discover_shard_ids,
)

from komira_search.split import SplitView

from komira_search_catalog.generation import read_retired_shards
from komira_search_catalog.metastore import (
    SearchMetastore,
    list_live_splits_across_shards_with_seq,
)
from komira_search_catalog.shard_reaper import reap_drained_shards
from komira_search_catalog.split_summary import make_merged_split_summary

from komira_search_compaction.merge_split import (
    merge_split_bytes,
    content_addressed_merge_key,
)
from komira_search_compaction.reaper import reap_retired_split
from komira_search_compaction.select import MergeCandidate, select_merge


# =============================================================================
# CompactionConfig: the per-pass knobs.
# =============================================================================


@fieldwise_init
struct CompactionConfig(Copyable, Movable, Deinitable):
    """The per-pass configuration that cannot be derived from the split set.

    Fields:
      key_prefix: the object-key prefix; the content-addressed merged key
                  embeds it as `<key_prefix>/<index>/splits/merged-<digest>.split`.
      now_ms:     the current time in milliseconds, which the reaper compares
                  with each retirement's schedule time. The caller reads the
                  clock; a test sets it by hand.
      grace_ms:   the reap grace period in milliseconds. A retired chunk and
                  the split object it names are reaped only once
                  `now_ms - schedule_ts >= grace_ms`. It must exceed the
                  longest in-flight query, so that a searcher which took its
                  snapshot before the retirement never finds its object gone.

    The policy constants (`MERGE_FACTOR`, the targets, `MAX_MERGED_BYTES`) are
    compile-time constants in select.mojo, not per-pass knobs."""

    var key_prefix: String
    var now_ms: Int64
    var grace_ms: Int64


comptime DEFAULT_GRACE_MS: Int64 = 600_000
"""A conservative default grace period: 10 minutes. A caller that knows its
longest query should set a smaller value of its own."""


# =============================================================================
# CompactionResult: the outcome of one pass.
# =============================================================================


@fieldwise_init
struct CompactionResult(
    ImplicitlyCopyable, Copyable, Movable, Deinitable
):
    """The outcome of one compaction pass.

    Fields:
      merged:         True iff a merge fired (at least `MERGE_FACTOR` eligible
                      ingest splits had accumulated). False means a no-op: the
                      pass stayed below the trigger or the index is empty.
      inputs_merged:  the K input splits collapsed into one (0 if no merge).
      seqs_retired:   how many snapshot chunks were retired (K on a merge, 0
                      on a no-op).
      merged_bytes:   the size of the merged split object (0 on a no-op).
      chunks_reaped:  how many retired manifest chunks were past their grace
                      period and reaped, from this merge and from earlier runs.
      splits_reaped:  how many retired split objects were past their grace
                      period and deleted.
      shards_reaped:  how many drained writer shards were removed this pass.

    Plain values (a Bool and six Ints), so it is ImplicitlyCopyable."""

    var merged: Bool
    var inputs_merged: Int
    var seqs_retired: Int
    var merged_bytes: Int
    var chunks_reaped: Int
    var splits_reaped: Int
    var shards_reaped: Int

    def summary_line(self) -> String:
        """A one-line human summary, for a compactor's output."""
        if not self.merged:
            return String(
                "compact_once: no-op (no merge fired; chunks_reaped="
            ) + String(self.chunks_reaped) + ", splits_reaped=" + String(
                self.splits_reaped
            ) + ", shards_reaped=" + String(self.shards_reaped) + ")"
        return (
            String("compact_once: merged ")
            + String(self.inputs_merged)
            + " splits -> 1 ("
            + String(self.merged_bytes)
            + " bytes), retired "
            + String(self.seqs_retired)
            + " seqs, reaped "
            + String(self.chunks_reaped)
            + " chunks + "
            + String(self.splits_reaped)
            + " .split objects + "
            + String(self.shards_reaped)
            + " drained shards"
        )


# =============================================================================
# compact_once.
# =============================================================================


def _base_metastore[
    Storage: CloneableConditionalWriteStore
](
    storage: Storage, index_meta_prefix: String, index: String
) raises -> SearchMetastore[Storage]:
    """A `SearchMetastore` on the reserved `_base` fold-target lineage
    `<index>/meta/_lineage/_base`, over a clone of `storage`. The compactor is
    the only writer of `_base`, so every append wins its `_HEAD` slot on the
    first try."""
    var lineage = shard_manifest_prefix(index_meta_prefix, LINEAGE_BASE_SHARD)
    var manifest = CasManifestStore[Storage](
        storage.clone(), lineage^, RetryPolicy.default()
    )
    return SearchMetastore[Storage](manifest^, index.copy())


def _shard_metastore[
    Storage: CloneableConditionalWriteStore
](
    storage: Storage,
    index_meta_prefix: String,
    shard_id: String,
    index: String,
) raises -> SearchMetastore[Storage]:
    """A `SearchMetastore` on one source lineage, the lineage a `retire` must
    target, over a clone of `storage`. A writer shard's lineage is
    `<index>/meta/_lineage/<shard_id>`; the unsharded lineage (shard id "") is
    the bare `<index>/meta`, with no `_lineage/` segment."""
    var lineage: String
    if shard_id.byte_length() == 0:
        lineage = index_meta_prefix
    else:
        lineage = shard_manifest_prefix(index_meta_prefix, shard_id)
    var manifest = CasManifestStore[Storage](
        storage.clone(), lineage^, RetryPolicy.default()
    )
    return SearchMetastore[Storage](manifest^, index.copy())


def compact_once[
    Storage: CloneableConditionalWriteStore
](
    storage: Storage,
    index_meta_prefix: String,
    index: String,
    field: String,
    config: CompactionConfig,
    var merged_uuid: Array[UInt8, 16],
) raises -> CompactionResult:
    """Run one finite compaction pass for `(index, field)` over all of the
    index's lineages (see the module header for the steps).

    `storage` holds the split objects and the manifests; the pass clones it
    once for each lineage it touches. `index_meta_prefix` is
    `<key_prefix>/<index>/meta`, the parent of the `_lineage/<shard_id>`
    shards (and itself the unsharded lineage).

    `merged_uuid` is the fresh 16-byte UUID of the merged split. The caller
    mints it, so this function reads no clock and no random source and the
    merged bytes are a deterministic function of the input set.

    The pass is idempotent. At most one pass should run at a time per index;
    that is the caller's contract and this function takes no lock."""
    # ---- 1. Snapshot the live splits of every lineage. ----
    # Each entry carries (shard_id, chunk_seq, summary); the unsharded lineage
    # is tagged shard id "". The merged-input skip over the union is already
    # applied inside list_live_splits_across_shards_with_seq.
    var snapshot = list_live_splits_across_shards_with_seq(
        storage, index_meta_prefix, index
    )

    # ---- 2. Select a merge set. ----
    var candidates = List[MergeCandidate]()
    for i in range(len(snapshot)):
        candidates.append(
            MergeCandidate(
                snapshot[i].shard_id.copy(),
                snapshot[i].chunk_seq,
                snapshot[i].summary.copy(),
            )
        )
    var plan = select_merge(candidates)

    if not plan.should_merge():
        # No merge fired. Still reap earlier runs' tombstones that are past
        # their grace period, and the drained shards, then return.
        var reaped = _reap_past_grace_tombstones_cross_shard[Storage](
            storage, index_meta_prefix, index, config
        )
        var shard_reap = reap_drained_shards(
            storage, index_meta_prefix, index
        )
        return CompactionResult(
            merged=False,
            inputs_merged=0,
            seqs_retired=0,
            merged_bytes=0,
            chunks_reaped=reaped[0],
            splits_reaped=reaped[1],
            shards_reaped=shard_reap.shards_reaped,
        )

    # ---- 3a. Read the object of each selected input, and record its
    #          (shard_id, seq) so the retire goes to the source lineage. ----
    var input_bytes = List[List[UInt8]]()
    var input_uuids = List[Array[UInt8, 16]]()
    var retire_shards = List[String]()
    var retire_seqs = List[Int64]()
    for i in range(plan.num_selected()):
        ref cand = plan.selected[i]
        var bts = storage.get(Path.parse(cand.summary.object_key))
        input_bytes.append(bts^)
        input_uuids.append(cand.summary.split_uuid.copy())
        retire_shards.append(cand.shard_id.copy())
        retire_seqs.append(cand.chunk_seq)

    # The content-addressed merged key: deterministic in the sorted input UUIDs,
    # so a re-run with the same set writes the same key (a harmless overwrite).
    var object_key = content_addressed_merge_key(
        config.key_prefix, index, input_uuids
    )

    # ---- 3b. Merge. The bucket argument is only recorded by the sink; the
    #          store is already bound to its container, so it is empty here. ----
    var mr = merge_split_bytes(
        input_bytes^,
        index,
        String(""),
        config.key_prefix,
        field,
        merged_uuid,
        object_key,
    )

    # Read the scalars and the input-UUID set (a small copy) BEFORE consuming
    # mr's split bytes. The footer (document count, min and max document id)
    # comes from the merged bytes: the merge assigns a fresh dense 0..M-1
    # document-id space.
    var merge_ops = mr.merge_ops
    var input_uuids_flat = mr.input_uuids_flat.copy()
    var merged_view = SplitView.parse(mr.split_bytes.copy())
    var merged_doc_count = Int64(merged_view.doc_count())
    var merged_min_id = Int64(merged_view.min_doc_id())
    var merged_max_id = Int64(merged_view.max_doc_id())
    var merged_byte_len = len(mr.split_bytes)
    # Move the split bytes out of mr (move, then reset; no partial move).
    var split_bytes = mr.take_split_bytes()

    # ---- 3c. Publish the merged split into `_base`: the object FIRST, the
    #          manifest append SECOND. The append is the linearization point
    #          that makes the split visible, so the object must already exist
    #          when it lands. The compactor is the only writer of `_base`. ----
    var merged_summary = make_merged_split_summary(
        merged_uuid^,
        merged_doc_count,
        Int64(merged_byte_len),
        merged_min_id,
        merged_max_id,
        index,
        field,
        object_key.copy(),
        merge_ops,
        input_uuids_flat^,
    )
    _ = storage.put(Path.parse(object_key), split_bytes^)
    var base_meta = _base_metastore[Storage](storage, index_meta_prefix, index)
    _ = base_meta.publish(merged_summary^)
    _ = base_meta^

    # ---- 3d. Retire exactly the snapshot chunks that were merged, each in its
    #          source lineage (no watermark). Publishing the merged summary
    #          already hides the inputs from a catalog read (the merged-input
    #          skip over the union of lineages), so a search in the window
    #          between publish and retire never counts a document twice, even
    #          though the inputs live in other shards. ----
    var n_retired = 0
    for i in range(len(retire_seqs)):
        var shard_meta = _shard_metastore[Storage](
            storage, index_meta_prefix, retire_shards[i], index
        )
        shard_meta.retire_at(retire_seqs[i], config.now_ms)
        n_retired += 1
        _ = shard_meta^

    # ---- 4. Reap retired chunks past their grace period, per source lineage
    #         (this merge's and earlier runs'). The chunks retired just now are
    #         inside the grace period (their schedule time is now_ms), so only
    #         earlier runs' leftovers can be reaped. ----
    var reaped = _reap_past_grace_tombstones_cross_shard[Storage](
        storage, index_meta_prefix, index, config
    )

    # ---- 5. Reap drained writer shards. A shard whose splits all folded into
    #         `_base` (no live split, no pending retirement) is removed, so it
    #         stops costing every read a lineage to merge. ----
    var shard_reap = reap_drained_shards(storage, index_meta_prefix, index)

    return CompactionResult(
        merged=True,
        inputs_merged=plan.num_selected(),
        seqs_retired=n_retired,
        merged_bytes=merged_byte_len,
        chunks_reaped=reaped[0],
        splits_reaped=reaped[1],
        shards_reaped=shard_reap.shards_reaped,
    )


# =============================================================================
# The grace-gated reap of retired chunks and their split objects.
# =============================================================================


def _reap_past_grace_tombstones_cross_shard[
    Storage: CloneableConditionalWriteStore
](
    storage: Storage,
    index_meta_prefix: String,
    index: String,
    config: CompactionConfig,
) raises -> Tuple[Int, Int]:
    """Reap the past-grace retired chunks of every lineage: each writer shard
    and the reserved `_base` that `_discover_shard_ids` finds under
    `_lineage/` (skipping the shards `reap_drained_shards` has retired), then
    the unsharded lineage (shard id ""). Inputs are retired
    in their source lineages, so one pass's retirements are spread across the
    shards.

    The discovery lists the `_lineage/` directory, so it also finds a shard with
    no live split but a pending retirement, which the live-split snapshot does
    not show. `_base` is included: reaping its own past-grace retirements is
    correct, and today it holds none because merged splits are never merged
    again.

    Per lineage it delegates to `_reap_shard_tombstones`. Returns the sum of
    (chunks_reaped, splits_reaped) over all lineages."""
    var chunks_reaped = 0
    var splits_reaped = 0
    var retired = read_retired_shards(storage, index_meta_prefix)
    var shard_ids = _discover_shard_ids(storage, index_meta_prefix)
    for si in range(len(shard_ids)):
        # A retired shard holds only a seal and reaped stubs, and had no
        # pending retirement when it was retired; it has nothing to reap.
        if retired.find(shard_ids[si]) >= 0:
            continue
        var meta = _shard_metastore[Storage](
            storage, index_meta_prefix, shard_ids[si], index
        )
        var r = _reap_shard_tombstones[Storage](storage, meta, config)
        chunks_reaped += r[0]
        splits_reaped += r[1]
        _ = meta^
    # The unsharded lineage (the bare `<index>/meta`).
    var legacy_meta = _shard_metastore[Storage](
        storage, index_meta_prefix, String(""), index
    )
    var lr = _reap_shard_tombstones[Storage](storage, legacy_meta, config)
    chunks_reaped += lr[0]
    splits_reaped += lr[1]
    _ = legacy_meta^
    return (chunks_reaped, splits_reaped)


def _reap_shard_tombstones[
    Storage: CloneableConditionalWriteStore
](
    storage: Storage,
    mut metastore: SearchMetastore[Storage],
    config: CompactionConfig,
) raises -> Tuple[Int, Int]:
    """A grace-gated sweep over every retired chunk of one lineage: this run's
    and any leftover of a run that stopped before it finished, found again
    through `tombstoned_seqs`. For each retired chunk past its grace period:

      1. read the chunk's summary for the split's object key BEFORE the chunk
         goes, because reaping the chunk removes the only record of the key and
         the split object would be orphaned;
      2. delete the split object (`reap_retired_split`);
      3. reap the manifest chunk with the same grace gate.

    A chunk that is already gone between listing and reading is skipped, and
    deleting an object that is already gone is harmless, so a re-run is safe.

    Returns (chunks_reaped, splits_reaped): the counts actually deleted this
    pass. A chunk still inside its grace period is left for a later run."""
    var tombs = metastore.tombstoned_seqs()
    var chunks_reaped = 0
    var splits_reaped = 0
    for i in range(len(tombs)):
        var seq = tombs[i]
        # The schedule time gates both reaps; read it once.
        var sched: Int64
        try:
            sched = metastore.tombstone_schedule_ts(seq)
        except e:
            # Already reaped between tombstoned_seqs and this read (a
            # concurrent run or an earlier leftover). Nothing to do.
            _ = String(e)
            continue
        if config.now_ms - sched < config.grace_ms:
            continue

        # Capture the split object's key BEFORE reaping the chunk that holds
        # it. A chunk that is already gone yields "": the object was deleted
        # when that chunk was reaped, so skip it.
        var object_key: String
        try:
            object_key = metastore.tombstoned_chunk_object_key(seq)
        except e:
            _ = String(e)
            object_key = String("")

        if object_key.byte_length() > 0:
            if reap_retired_split(
                storage, object_key, sched, config.now_ms, config.grace_ms
            ):
                splits_reaped += 1

        if metastore.reap_chunk(seq, config.now_ms, config.grace_ms):
            chunks_reaped += 1
    return (chunks_reaped, splits_reaped)
