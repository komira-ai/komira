# =============================================================================
# komira_search_catalog/shard_reaper.mojo
#   Retiring drained writer shards: `reap_drained_shards`.
# =============================================================================
#
# No pointers cross this module's API; every value is owned data or a store
# handle borrowed for the call.

from komira_objectstore import (
    CasManifestStore,
    RetryPolicy,
    WritePrecondition,
    chunk_key,
    decode_chunk_body,
    encode_chunk,
    log_start_key,
)
from komira_objectstore.cas_manifest import is_not_found, is_precondition
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

from komira_search_catalog.generation import (
    advance_log_start_to,
    read_log_start_seq,
    read_retired_shards,
    record_retired_shard,
)
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
# publish can land between the reaper's drained check and its deletes, or
# arrive after the reaper is done. Neither may be lost or leave a lineage a
# reader cannot replay. Per shard, in this order:
#
#   1. Snapshot: LIST every key under the shard.
#   2. Read the shard's generation `g`. For a drained shard that is exactly
#      the slot of the writer's next publish: `reap_chunk` keeps reaped
#      chunks as stubs until the log start passes them, and raises the
#      generation floor first, so the lineage never looks shorter than the
#      writer's tail.
#   3. The drained check (no live splits, no pending tombstones).
#   4. Fence: create-if-absent a seal chunk (empty body) at slot `g`. A
#      publish is the create-if-absent of the same slot, so exactly one of
#      the two wins. If the publish already took it, the create fails with a
#      precondition error and the shard is left alone.
#   5. Re-read the log start. If it is past `g`, the drained check is stale:
#      the reaper stalled after it, and meanwhile the writer published at
#      `g`, compaction retired that chunk, and `reap_chunk` stubbed it,
#      advanced the log start past it and deleted it. The seal won only
#      because the slot was empty again. The writer's handle now publishes
#      above `g` without a check, so retiring the shard would hide those
#      publishes. The shard counts as fenced and is left alone; the seal
#      stays, and is harmless, because replay and the publish check never
#      look below the log start. Otherwise advance the shard's log start to
#      `g`, so a cold reader or writer replays the shard from the seal and
#      never looks below it.
#      The re-read is sufficient because a chunk is deleted only after the
#      log start has been advanced past it (`reap_chunk`'s prefix advance,
#      and step 7 below, after this step): if slot `g` was written and
#      deleted since step 2, the log start is already above `g`. A publish
#      at `g` after the seal loses the slot to it, so nothing can be written
#      at `g` between the seal and the re-read.
#   6. Record the shard's final generation, `g + 1` (the seal is a chunk),
#      in the index's `_RETIRED_SHARDS` record. The index generation does not
#      drop, and readers skip the shard from now on.
#   7. Delete the snapshot's keys except the log start, every seal, and
#      every chunk above the earliest seal. A publish creates a key that did
#      not exist, so it is never in the snapshot.
#
# The seal is terminal and is never deleted, nor is any chunk above it.
# Deleting one would free a slot at or above the writer's next slot, and the
# writer's warm handle publishes there without a check (its steady state:
# the slot after its own last chunk) and would succeed into a shard readers
# no longer replay. With every seal in place, a later publish into the shard
# finds one, below the slot it won or as the slot it lost, rewrites its own
# chunk into a seal and raises `[SHARD_RETIRED]` (`SearchMetastore.publish`);
# the caller publishes into a fresh shard id. What remains of a retired shard
# is its seals and the log start: two objects in the common case.
#
# A sweep can find a seal no `_RETIRED_SHARDS` record covers yet, and must
# keep it:
#   * a reaper crashed after step 4 (before step 6). Replay skips its seal,
#     so the next sweep finds the shard drained again, reads generation
#     `g + 1` and seals that slot. The old seal at `g` is the writer's next
#     slot, so it stays.
#   * two reapers ran concurrently and both read `_RETIRED_SHARDS` before
#     either recorded the shard. The second one's snapshot can hold the
#     first one's seal; it seals the slot above and keeps both.
# The deletes are bounded by the earliest seal in the snapshot, not by `g`,
# because `g` is past every seal the snapshot holds. They are idempotent, as
# deleting an absent key succeeds. A shard already in the `_RETIRED_SHARDS`
# record is not examined again.
#
# Every chunk below the earliest seal is a reaped stub (the shard was
# drained), and every chunk the shard's writer won is below the earliest
# seal, because that seal took the writer's next slot. Deleting those stubs
# frees only slots at or below the writer's last chunk, which its next publish
# never targets. That holds for one publishing handle per writer shard, which
# is how shard ids are issued (`make_shard_id`).


@fieldwise_init
struct DrainedShardReapResult(
    ImplicitlyCopyable, Copyable, Movable, Deinitable
):
    """Counts from one `reap_drained_shards` sweep.

    Fields:
      shards_examined: writer shards considered (`_base`, the unsharded
                       lineage and retired shards are never counted).
      shards_reaped:   drained shards deleted.
      shards_fenced:   drained shards left alone because a publish took the
                       fenced slot after the drained check, or because the
                       slot had been written and reaped since the check.
      objects_deleted: objects deleted across the reaped shards. The seals
                       and the log start of a retired shard stay.
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


comptime _NOT_A_CHUNK = Int64(-1)
comptime _NO_SEAL = Int64(0x7FFFFFFFFFFFFFFF)


def _chunk_seq_of(lineage_prefix: String, key: String) -> Int64:
    """The chunk sequence number of `key` if it is one of the lineage's
    manifest chunks (`<lineage>/manifest/<20 digits>.chunk`), else
    `_NOT_A_CHUNK`."""
    var head = lineage_prefix + "/manifest/"
    var tail = String(".chunk")
    if not key.startswith(head) or not key.endswith(tail):
        return _NOT_A_CHUNK
    var bytes = key.as_bytes()
    var lo = head.byte_length()
    var hi = key.byte_length() - tail.byte_length()
    if hi <= lo:
        return _NOT_A_CHUNK
    var seq = Int64(0)
    for i in range(lo, hi):
        var c = bytes[i]
        if c < UInt8(ord("0")) or c > UInt8(ord("9")):
            return _NOT_A_CHUNK
        seq = seq * Int64(10) + Int64(c - UInt8(ord("0")))
    return seq


def _earliest_seal[
    Storage: CloneableConditionalWriteStore
](
    storage: Storage, lineage_prefix: String, snapshot: List[String]
) raises -> Int64:
    """The lowest chunk sequence number in `snapshot` whose body is a seal,
    or `_NO_SEAL`. A chunk the store proves absent is skipped. A chunk read
    here as a split or a reaped stub never becomes the earliest seal later:
    the only chunk rewritten into a seal is a refused publish, and that one
    sits above a seal that already existed."""
    var earliest = _NO_SEAL
    for k in range(len(snapshot)):
        var seq = _chunk_seq_of(lineage_prefix, snapshot[k])
        if seq == _NOT_A_CHUNK or seq >= earliest:
            continue
        var raw: List[UInt8]
        try:
            raw = storage.get(Path.parse(snapshot[k]))
        except e:
            if is_not_found(String(e)):
                continue
            raise e^
        if len(decode_chunk_body(raw)) == 0:
            earliest = seq
    return earliest


def reap_drained_shards[
    Storage: CloneableConditionalWriteStore
](
    storage: Storage,
    index_meta_prefix: String,
    index_name: String,
) raises -> DrainedShardReapResult:
    """Retire every drained writer shard of an index, so the shards a read
    replays stay near `_base` plus the writers that are actually indexing.

    The unsharded lineage has no `_lineage/` segment, so
    `_discover_shard_ids` never returns it and it is excluded by
    construction; `_base` is skipped explicitly.

    Safe to run after every compaction pass: a shard still in use has live
    splits, a shard with pending tombstones is skipped, a publish that lands
    after the drained check is fenced, and a publish after the seal is
    refused (see the block above).
    Idempotent: a retired shard is in the `_RETIRED_SHARDS` record and is
    not examined again, and deleting an absent key succeeds."""
    var retired = read_retired_shards(storage, index_meta_prefix)
    var shard_ids = _discover_shard_ids(storage, index_meta_prefix)
    var examined = 0
    var reaped = 0
    var fenced = 0
    var objects_deleted = 0
    for i in range(len(shard_ids)):
        if is_reserved_shard_id(shard_ids[i]):
            continue
        if retired.find(shard_ids[i]) >= 0:
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
        if read_log_start_seq(storage, lineage_prefix) > g:
            fenced += 1
            continue
        # The offset is bookkeeping only for search; the seal's is the
        # lineage's running total, which the recovered head carries.
        advance_log_start_to(
            storage,
            lineage_prefix,
            g,
            meta._read_head_settled().next_offset,
        )
        record_retired_shard(
            storage, index_meta_prefix, shard_ids[i], g + Int64(1)
        )
        var keep = log_start_key(lineage_prefix).raw()
        var first_kept = _earliest_seal(storage, lineage_prefix, snapshot)
        for k in range(len(snapshot)):
            if snapshot[k] == keep:
                continue
            var seq = _chunk_seq_of(lineage_prefix, snapshot[k])
            if seq >= first_kept:
                continue
            storage.delete(Path.parse(snapshot[k]))
            objects_deleted += 1
        reaped += 1
    return DrainedShardReapResult(
        shards_examined=examined,
        shards_reaped=reaped,
        shards_fenced=fenced,
        objects_deleted=objects_deleted,
    )
