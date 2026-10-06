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
    ManifestHead,
    RetryPolicy,
    chunk_key,
    decode_chunk_body,
    decode_chunk_record_count,
    decode_head,
    head_key,
    tombstone_key,
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
    advance_log_start_to,
    bump_generation,
    decode_generation_bumps,
    decode_generation_floor,
    generation_bumps_key,
    generation_floor_key,
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
# Chunk bodies that are not splits
# =============================================================================
#
# Besides an encoded `SplitSummary` (always more than one byte), a chunk body
# is one of:
#
#   * a seal: empty. `reap_drained_shards` writes one at a drained writer
#     shard's next slot, and a publish that finds itself past one rewrites its
#     own chunk into one. A shard with a seal is retired for good: no publish
#     into it succeeds, and the seal is never deleted, because deleting it
#     would free the slot the shard's writer would publish into next.
#   * a reaped stub: one zero byte. `reap_chunk` replaces a reaped chunk's
#     body with it instead of deleting the chunk, so the lineage stays
#     gapless; a stub is deleted only once the log start has moved past it.
#
# Replay skips both.

comptime SHARD_RETIRED_MARKER = "[SHARD_RETIRED]"
"""In the message of the error `SearchMetastore.publish` raises when the shard
it publishes into has been retired by `reap_drained_shards`. Nothing the
publish wrote is visible. The caller re-publishes into a fresh shard id (a
retired shard id never accepts a publish again). Test with
`is_shard_retired`."""

comptime _TORN_LINEAGE = "torn manifest lineage"
"""In the message `CasManifestStore` raises when a cold head recovery reads
a missing chunk at or above the log start it read."""

comptime _MAX_SEQ = Int64(0x7FFFFFFFFFFFFFFF)

@always_inline
def is_shard_retired(msg: String) -> Bool:
    """True iff `msg` is the error of a publish into a retired shard."""
    return msg.find(SHARD_RETIRED_MARKER) >= 0


@always_inline
def _is_seal(body: List[UInt8]) -> Bool:
    return len(body) == 0


@always_inline
def _is_reaped_stub(body: List[UInt8]) -> Bool:
    return len(body) == 1 and body[0] == UInt8(0)


@always_inline
def _is_split(body: List[UInt8]) -> Bool:
    return len(body) > 1


def _reaped_stub() -> List[UInt8]:
    var b = List[UInt8]()
    b.append(UInt8(0))
    return b^


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

    Every one of these moves `generation()`.
    """

    var _manifest: CasManifestStore[Self.Storage]
    var _index_name: String
    # The chunk this handle's last publish won, -1 before the first. When the
    # head a publish starts from is this chunk, the slot after it was this
    # handle's own next slot, so a first-attempt win there needs no check.
    var _last_won: Int64
    # Set once a publish found the shard retired; every later publish on this
    # handle refuses without touching the store.
    var _retired: Bool

    def __init__(
        out self,
        var manifest: CasManifestStore[Self.Storage],
        var index_name: String,
    ):
        """Take a manifest store already bound to the lineage prefix
        (`<index>/meta`, or a shard's sub-lineage prefix)."""
        self._manifest = manifest^
        self._index_name = index_name^
        self._last_won = Int64(-1)
        self._retired = False

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
        body. Returns the `AppendResult` (chunk_seq, etag, attempts).

        Raises an error carrying `SHARD_RETIRED_MARKER` (test with
        `is_shard_retired`) when `reap_drained_shards` has retired this
        lineage. Nothing the publish wrote is then visible, and the caller
        re-publishes into a fresh shard id.

        Retirement check: the reaper retires a shard by creating a seal at
        the writer's next slot, the same create-if-absent a publish does.
        When the head this publish starts from is the chunk this handle last
        won and the append wins the slot right after it, that slot was free,
        so no seal is involved and there is nothing to check (the writer's
        steady state, no extra request). Otherwise the publish either lost a
        slot or started from a head it did not write, so it reads the chunks
        below the one it won, newest first, down to the first one that
        exists: a seal there means the publish landed past it. The publish
        then rewrites its own chunk into a seal, which no reader returns, and
        raises."""
        if self._retired:
            raise Error(self._retired_message())
        var body = encode_split_summary(summary)
        # A cold head recovery can race a reaper that advances the log start
        # and deletes the chunks below it; the recovery then reports a torn
        # lineage. Nothing was written, so retry: once unconditionally, then
        # only while the log start keeps moving. A lineage that stays torn
        # raises.
        var last_log_start = Int64(-2)
        while True:
            try:
                var pre = self._manifest.read_head()
                var r = self._manifest.append(body, summary.doc_count)
                self._refuse_if_past_a_seal(pre.chunk_seq, r.chunk_seq)
                self._last_won = r.chunk_seq
                return r^
            except e:
                if String(e).find(_TORN_LINEAGE) < 0:
                    raise e^
                var ls = self._manifest.read_log_start().log_start_seq
                if ls == last_log_start:
                    raise e^
                last_log_start = ls

    def _retired_message(self) -> String:
        return (
            "komira_search_catalog: "
            + SHARD_RETIRED_MARKER
            + " the lineage "
            + self._manifest.prefix()
            + " was retired by reap_drained_shards; publish into a fresh"
            " shard"
        )

    def _refuse_if_past_a_seal(mut self, pre_seq: Int64, won: Int64) raises:
        """The retirement check of `publish` (see there)."""
        if won == pre_seq + Int64(1) and (
            pre_seq < Int64(0) or pre_seq == self._last_won
        ):
            return
        var prefix = self._manifest.prefix()
        var log_start = self._manifest.read_log_start().log_start_seq
        if won < log_start:
            # A slot below the log start belongs to a reaped prefix, which no
            # reader replays. Reachable only if a head object older than the
            # log start was trusted; refuse rather than report a publish
            # nobody will see.
            raise Error(
                "komira_search_catalog: publish won chunk "
                + String(won)
                + " below the log start "
                + String(log_start)
                + " of "
                + prefix
                + "; it is not visible, publish again"
            )
        var seq = won - Int64(1)
        while seq >= log_start:
            var below = self._read_body_if_present(seq)
            if not below:
                seq -= Int64(1)
                continue
            if _is_seal(below.value()):
                self._manifest.rewrite_chunk_body(won, List[UInt8]())
                self._retired = True
                # The split was visible from the append until the rewrite
                # (to a reader that does not skip this shard); taking it back
                # is a catalog change too. Only the bump after it is
                # possible: the append was the publish's first write.
                self._bump_generation()
                raise Error(self._retired_message())
            return

    def _read_body_if_present(self, chunk_seq: Int64) raises -> Optional[List[UInt8]]:
        """The chunk's body, or None when the store proves it absent."""
        try:
            return Optional(self._manifest.read_chunk(chunk_seq))
        except e:
            if is_not_found(String(e)):
                return None
            raise e^

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
        var head = self._read_head_settled()
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
                    # Seals and reaped stubs are not splits (see the block
                    # above `SearchMetastore`).
                    if _is_split(chunk):
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
                    # Deleted after the log start was read: a reaped stub
                    # below a log start a reaper has since moved. Skip.
            seq += Int64(1)
        return out^

    def _read_head_settled(self) raises -> ManifestHead:
        """`read_head_fresh()`, retried when a cold head recovery races a
        reaper. Recovery reads the log start, LISTs, then reads every chunk
        from the log start up; a reaper that advances the log start and
        deletes the chunks below it in between makes recovery report a torn
        lineage. A reaper only deletes below a log start it has already
        advanced, so a retry reads the new one. Retried once
        unconditionally, then only while the log start keeps moving; a
        lineage that stays torn raises."""
        var last_log_start = Int64(-2)
        while True:
            try:
                return self._manifest.read_head_fresh()
            except e:
                if String(e).find(_TORN_LINEAGE) < 0:
                    raise e^
                var ls = self._manifest.read_log_start().log_start_seq
                if ls == last_log_start:
                    raise e^
                last_log_start = ls

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
        """The catalog generation: it changes on every catalog change
        (`publish`, `retire`, `retire_at`, `reap_chunk`, and the refusal of a
        publish into a retired shard), and never goes down. A query planner
        folds it into its plan-cache key, and a scan reads it before and
        after reading the catalog to tell whether its view stayed current.

        It is `_next_slot()` (the chunks this lineage has ever committed) plus
        the `_GENERATION_BUMPS` counter, which `retire` and `reap_chunk` bump
        before and after their change (generation.mojo has the ordering
        argument). Read in the order head, floor, bumps: every term is read
        after the live objects it covers. It is not a slot number; the shard
        reaper, which needs one, reads `_next_slot()`.

        Costs what `_next_slot()` costs plus one GET for the counter."""
        var slots = self._next_slot()
        return slots + self._generation_bumps()

    def _next_slot(self) raises -> Int64:
        """The number of chunks this lineage has ever committed,
        max(head.chunk_seq + 1, the generation floor): the slot of the next
        publish. It never goes down: a cold reader finds the head by LISTing
        chunks, and reaping can delete chunks, so `reap_chunk` first raises
        the floor to cover the chunk it reaps (see generation.mojo). The
        floor is read after the head, which is the order that argument needs.

        Reads `read_head_fresh()` for the same reason as
        `_replay_live_entries`. `num_chunks()` resolves through `read_head()`
        and, on a cold handle, would return the stale deferred head, so the
        value would not move after a publish. On a cold handle this costs a
        LIST rather than a GET, which the query path already pays in the
        replay; a writer's warm handle stays at zero requests for the head.
        The floor costs one GET."""
        var from_head = self._read_head_settled().chunk_seq + Int64(1)
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

    def _generation_bumps(self) raises -> Int64:
        """This lineage's `_GENERATION_BUMPS` counter, 0 when none was
        written."""
        try:
            return decode_generation_bumps(
                self._manifest.get_object(
                    generation_bumps_key(self._manifest.prefix()).raw()
                )
            )
        except e:
            if is_not_found(String(e)):
                return Int64(0)
            raise e^

    def _bump_generation(mut self) raises:
        """Add one to the `_GENERATION_BUMPS` counter; durable on return."""
        bump_generation(self._manifest.store_mut(), self._manifest.prefix())

    def retire(mut self, chunk_seq: Int64) raises -> None:
        """Tombstone `chunk_seq`, stamped with the current wall clock. The
        chunk leaves the live set immediately, so new queries stop fetching
        its split, but the chunk and the split object stay readable until
        `reap_chunk` deletes them after the grace period. Re-retiring
        refreshes the timestamp. Moves `generation()` (see `retire_at`)."""
        # ORDER: bump, tombstone, bump. Do not drop or reorder the bumps.
        self._bump_generation()
        self._manifest.schedule_for_delete(chunk_seq)
        self._bump_generation()

    def retire_at(mut self, chunk_seq: Int64, schedule_ts_ms: Int64) raises -> None:
        """`retire` with an explicit timestamp in milliseconds, for callers
        and tests that drive their own clock.

        Moves `generation()`: bumps the counter, writes the tombstone, bumps
        again. The first bump is durable before the tombstone exists, so a
        reader that sees the split gone reads a generation after its catalog
        read that differs from any it read before the retire began; the
        second retires the value a reader between the two may have paired
        with the old live set (generation.mojo)."""
        # ORDER: bump, tombstone, bump. Do not drop or reorder the bumps.
        self._bump_generation()
        self._manifest.schedule_for_delete_at(chunk_seq, schedule_ts_ms)
        self._bump_generation()

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
        if not _is_split(chunk):
            # A reaped stub: a reaper got through `reap_chunk`'s rewrite and
            # stopped before dropping the tombstone. Same answer as a
            # deleted chunk.
            raise Error(
                "komira_search_catalog: chunk "
                + String(chunk_seq)
                + " of "
                + self._manifest.prefix()
                + " was already reaped: not_found"
            )
        return decode_split_summary(chunk).object_key

    def reap_chunk(mut self, chunk_seq: Int64, now_ms: Int64, grace_ms: Int64) raises -> Bool:
        """Reap a tombstoned chunk once `now_ms - schedule_ts >= grace_ms`.
        The grace period must exceed the longest query, so a query that
        picked up the split before it was retired can still read it.

        Returns True if the chunk is reaped (now, or already), False if the
        grace period has not elapsed yet; the caller leaves the tombstone for
        a later run.

        Moves `generation()` when it reaps: the steps below sit between two
        bumps of the generation counter, for the reason `retire_at` gives. A
        call that finds nothing to do (not tombstoned, or still in grace)
        changes nothing and bumps nothing.

        Reaping does not delete the chunk. A cold reader recovers the head by
        reading every chunk from the log start up and refuses a missing one
        as a torn lineage, and compaction retires chunks in any order, so a
        deleted chunk below the top would break every cold read of the
        index. Instead:

          1. Raise the generation floor to cover the chunk (generation.mojo).
          2. Replace its body with a reaped stub, which replay skips. Its
             record count is kept, so offsets do not move.
          3. Drop the tombstone.
          4. Advance the log start over the run of reaped stubs it now
             starts with, then delete those stubs. A chunk is deleted only
             once the log start is past it.

        The advance stops below the durable head object's next slot. A cold
        writer that trusts that object (it can lag the true tail) publishes
        into the slot after it; were that slot below the log start, the
        publish would land where no reader looks.

        Two reapers may race; every step is idempotent and the log start only
        moves forward. This deletes only manifest chunks. The split object
        at `summary.object_key` is deleted by the caller on the same grace
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
        var prefix = self._manifest.prefix()
        # ORDER: bump, steps 1 to 4, bump (generation.mojo).
        self._bump_generation()
        raise_generation_floor(
            self._manifest.store_mut(), prefix, chunk_seq + Int64(1)
        )
        try:
            self._manifest.rewrite_chunk_body(chunk_seq, _reaped_stub())
        except e:
            # Another reaper got there first and the log start has already
            # moved past the chunk.
            if not is_not_found(String(e)):
                raise e^
        self._manifest.store_mut().delete(tombstone_key(prefix, chunk_seq))
        self._advance_past_reaped_prefix()
        self._bump_generation()
        return True

    def _advance_past_reaped_prefix(mut self) raises:
        """Step 4 of `reap_chunk`. A reaper racing this one may move the log
        start first; the walk then stops at a chunk it already deleted, and
        the advance never moves the log start backwards."""
        var prefix = self._manifest.prefix()
        var ls = self._manifest.read_log_start()
        var start = ls.log_start_seq
        var offset = ls.log_start_offset
        if start < Int64(0):
            start = Int64(0)
            offset = Int64(0)
        var cap = self._durable_head_next_slot()
        var seq = start
        while seq < cap:
            var raw = self._read_raw_if_present(seq)
            if not raw:
                break
            if not _is_reaped_stub(decode_chunk_body(raw.value())):
                break
            offset += decode_chunk_record_count(raw.value())
            seq += Int64(1)
        if seq == start:
            return
        advance_log_start_to(self._manifest.store_mut(), prefix, seq, offset)
        for q in range(Int(start), Int(seq)):
            self._manifest.store_mut().delete(chunk_key(prefix, Int64(q)))

    def _durable_head_next_slot(self) raises -> Int64:
        """The slot after the durable head object's chunk, or no bound when
        there is no head object (a cold handle then recovers by LIST, which
        starts at the log start)."""
        try:
            var raw = self._manifest.get_object(
                head_key(self._manifest.prefix()).raw()
            )
            return decode_head(raw).chunk_seq + Int64(1)
        except e:
            if is_not_found(String(e)):
                return _MAX_SEQ
            raise e^

    def _read_raw_if_present(self, chunk_seq: Int64) raises -> Optional[List[UInt8]]:
        """The encoded chunk (record count and body), or None when absent."""
        try:
            return Optional(
                self._manifest.get_object(
                    chunk_key(self._manifest.prefix(), chunk_seq).raw()
                )
            )
        except e:
            if is_not_found(String(e)):
                return None
            raise e^


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

    Shards `reap_drained_shards` has retired are skipped.

    Order is deterministic: discovered shards in LIST order, then the
    unsharded lineage."""
    var union = List[ShardedLiveSplitEntry]()

    # A retired shard holds only seals and reaped stubs and never accepts
    # another publish, so it has nothing to contribute; skipping it keeps the
    # read cost from growing with every writer shard ever reaped.
    var retired = read_retired_shards(storage, index_meta_prefix)
    var shard_ids = _discover_shard_ids(storage, index_meta_prefix)
    for i in range(len(shard_ids)):
        if retired.find(shard_ids[i]) >= 0:
            continue
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
    changes (a publish, retire or reap in any lineage raises that lineage's
    `generation()`, so the sum, and `reap_drained_shards` records a shard
    one above its last live value) and it never goes down
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
