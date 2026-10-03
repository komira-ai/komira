# =============================================================================
# komira_search_catalog/shard_reaper.mojo
#   Reaping drained writer shards: `reap_drained_shards`.
# =============================================================================
#
# No pointers cross this module's API; every value is owned data or a store
# handle borrowed for the call.

from komira_objectstore import (
    CasManifestStore,
    RetryPolicy,
    WritePrecondition,
    chunk_key,
    encode_chunk,
)
from komira_objectstore.cas_manifest import is_precondition
from komira_objectstore.path import Path
from komira_objectstore.store import (
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
)
from komira_objectstore.sublineage_shard_keys import (
    is_reserved_shard_id,
    shard_manifest_prefix,
    _discover_shard_ids,
)

from komira_search_catalog.generation import record_retired_shard
from komira_search_catalog.metastore import SearchMetastore


# =============================================================================
# Reaping drained writer shards
# =============================================================================
#
# As compaction folds a writer shard's splits into `_base`, that shard's
# manifest drains: every chunk retired, past grace, and reaped. A drained
# shard still costs one head read on every cross-shard read, and each process
# restart creates new shard ids, so without cleanup read cost grows for the
# life of the index.
#
# A writer shard is drained, and safe to delete, iff:
#   1. it has no live splits, and
#   2. it has no pending tombstones. A tombstone still in its grace period
#      means a query may still be reading the old split.
#
# Never reaped:
#   * `_base`, the shard compaction writes into;
#   * the unsharded lineage `<index>/meta`. Deleting its head would break
#     reads of older indexes. There is one per index, so leaving its empty
#     shell costs a bounded amount.
#
# The writer that owns a drained shard may still be alive, and its next
# publish can land between the reaper's drained check and its deletes. That
# publish must not be deleted. Per shard, in this order:
#
#   1. Snapshot: LIST every key under the shard.
#   2. Read the shard's generation `g`. For a drained shard that is exactly
#      the slot of the writer's next publish: every chunk it committed was
#      reaped through `reap_chunk`, which raised the generation floor past
#      it first.
#   3. The drained check (no live splits, no pending tombstones).
#   4. Fence: create-if-absent a seal chunk (empty body) at slot `g`. A
#      publish is the create-if-absent of the same slot, so exactly one of
#      the two wins. If the publish already took it, the create fails with a
#      precondition error and the shard is left alone. If the seal wins, the
#      writer's publish moves to a later slot.
#   5. Record the shard's final generation, `g + 1` (the seal is a chunk),
#      in the index's `_RETIRED_SHARDS` record, so the index generation does
#      not drop when the shard stops being listed (generation.mojo).
#   6. Delete only the snapshot's keys, then the seal. A publish is the
#      creation of a key that did not exist, so it is never in the snapshot
#      and never deleted, even when the fence could not see its slot (a shard
#      whose chunks were reaped before generation floors existed reads a `g`
#      below the writer's slot; the seal then lands on a free slot and fences
#      nothing).
#
# A reaper that crashes after step 4 leaves a seal that replay skips; the
# next sweep finds the shard drained again and finishes it. Deletes are
# idempotent, since deleting an absent key succeeds. Afterwards the shard no
# longer appears in `_discover_shard_ids`.
#
# What this does not repair: a publish that slips past the fence survives as
# a chunk whose earlier chunks and head are gone, and a cold reader that
# recovers that shard's head by LIST refuses the gap. The publish is not
# lost, but the shard needs the same gap-tolerant recovery as any lineage
# whose chunks were reaped out of order.


@fieldwise_init
struct DrainedShardReapResult(
    ImplicitlyCopyable, Copyable, Movable, Deinitable
):
    """Counts from one `reap_drained_shards` sweep.

    Fields:
      shards_examined: writer shards considered (`_base` and the unsharded
                       lineage are never counted).
      shards_reaped:   drained shards deleted.
      shards_fenced:   drained shards left alone because a publish took the
                       fenced slot after the drained check.
      objects_deleted: objects deleted across the reaped shards, seals
                       included.
    """

    var shards_examined: Int
    var shards_reaped: Int
    var shards_fenced: Int
    var objects_deleted: Int


def _shard_is_drained[
    Storage: ConditionalWriteStore
](meta: SearchMetastore[Storage]) raises -> Bool:
    """True iff the shard has no live splits and no pending tombstones. A
    shard whose head is already gone but which still has a stray object
    replays as empty, so it counts as drained and the remnant gets
    deleted."""
    var live = meta._replay_live_entries()
    if len(live) > 0:
        return False
    var tombs = meta.tombstoned_seqs()
    if len(tombs) > 0:
        return False
    return True


def _keys_under_prefix[
    Storage: CloneableConditionalWriteStore
](storage: Storage, lineage_prefix: String) raises -> List[String]:
    """Every object key under `<lineage_prefix>/`.

    In-memory backends LIST flat keys in `objects`; cloud backends may fold
    subdirectories into `common_prefixes`, so this descends into those. A
    shard tree is at most `<shard>/{manifest,tombstones,_meta}/<file>`, with
    `_meta/` nesting one level further (`dedup/<producer>/<seq>.seq`), so two
    levels of descent cover it."""
    var keys = List[String]()
    var listed = storage.list_with_delimiter(Path.parse(lineage_prefix + "/"))
    for i in range(len(listed.objects)):
        keys.append(listed.objects[i].location)
    for j in range(len(listed.common_prefixes)):
        var sub = listed.common_prefixes[j]
        var sub_listed = storage.list_with_delimiter(Path.parse(sub))
        for k in range(len(sub_listed.objects)):
            keys.append(sub_listed.objects[k].location)
        for m in range(len(sub_listed.common_prefixes)):
            var sub2 = sub_listed.common_prefixes[m]
            var sub2_listed = storage.list_with_delimiter(Path.parse(sub2))
            for q in range(len(sub2_listed.objects)):
                keys.append(sub2_listed.objects[q].location)
    return keys^


def reap_drained_shards[
    Storage: CloneableConditionalWriteStore
](
    storage: Storage,
    index_meta_prefix: String,
    index_name: String,
) raises -> DrainedShardReapResult:
    """Delete every drained writer shard of an index, so the live shard count
    stays near `_base` plus the writers that are actually indexing.

    The unsharded lineage has no `_lineage/` segment, so
    `_discover_shard_ids` never returns it and it is excluded by
    construction; `_base` is skipped explicitly.

    Safe to run after every compaction pass: a shard still in use has live
    splits, a shard with pending tombstones is skipped, and a publish that
    lands after the drained check is fenced (see the block above).
    Idempotent: a reaped shard no longer appears in the LIST, and deleting an
    absent key succeeds."""
    var shard_ids = _discover_shard_ids(storage, index_meta_prefix)
    var examined = 0
    var reaped = 0
    var fenced = 0
    var objects_deleted = 0
    for i in range(len(shard_ids)):
        if is_reserved_shard_id(shard_ids[i]):
            continue
        examined += 1
        var lineage_prefix = shard_manifest_prefix(
            index_meta_prefix, shard_ids[i]
        )
        var snapshot = _keys_under_prefix(storage, lineage_prefix)
        var manifest = CasManifestStore[Storage](
            storage.clone(), lineage_prefix.copy(), RetryPolicy.default()
        )
        var meta = SearchMetastore[Storage](manifest^, index_name.copy())
        var g = meta.generation()
        if not _shard_is_drained(meta):
            continue
        var seal = chunk_key(lineage_prefix, g)
        try:
            _ = storage.conditional_put(
                seal,
                encode_chunk(List[UInt8](), Int64(0)),
                WritePrecondition.if_none_match_star(),
            )
        except e:
            if not is_precondition(String(e)):
                raise e^
            fenced += 1
            continue
        record_retired_shard(
            storage, index_meta_prefix, shard_ids[i], g + Int64(1)
        )
        for k in range(len(snapshot)):
            storage.delete(Path.parse(snapshot[k]))
        storage.delete(seal)
        objects_deleted += len(snapshot) + 1
        reaped += 1
    return DrainedShardReapResult(
        shards_examined=examined,
        shards_reaped=reaped,
        shards_fenced=fenced,
        objects_deleted=objects_deleted,
    )
