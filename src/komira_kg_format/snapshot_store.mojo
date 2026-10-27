# =============================================================================
# snapshot_store -- the snapshot lineage of a graph on a conditional-write object
#   store: bases, delta chains, folds and the change gate's fingerprints.
# =============================================================================
#
# `KgSnapshotStore` is a thin orchestrator over `CasManifestStore`: a domain
# payload (a `KgManifestBody`, `KgDeltaBody` or `KgChainBody`) rides inside the
# opaque body of a manifest chunk, and the table data sits in content-addressed
# objects on the same store. The compare-and-set that gives every chunk a unique,
# gapless sequence number is the manifest's; this module adds the one rule the
# manifest cannot know, that a new chain head must be built from the head it
# lands directly after (see "Writers").
#
# Chunks and objects
# ------------------
#   <prefix>/manifest/...       one chunk per write: a base (`KG_CHUNK_BASE`), a
#                               chain head (`KG_CHUNK_CHAIN`) or a delta
#                               (`KG_CHUNK_DELTA`); the kind is the chunk's
#                               format version (`kg_chunk_kind`). A base
#                               written by a compactor is marked pending (its
#                               record count is zero; see "The head").
#   <prefix>/objects/<h>.parquet  a base table, as Parquet; <h> is the hash of
#                               the bytes, so equal bytes are one object.
#   <prefix>/deltas/<h>.delta    a delta table (`delta_codec`: framed or Parquet).
#   <prefix>/fingerprints/...   the fingerprint lineage (`source_fingerprint`).
#
# The head
# --------
# The head of the graph is the newest base or chain-head chunk, not the newest
# chunk. A delta is written before the chain head that names it, so for a moment
# the newest chunk can be a delta no chain refers to yet; readers and writers
# look past it. A delta no head ever names (its writer stopped between the two
# writes) stays in the lineage, unreferenced and harmless.
#
# A base written by a compactor (`write_base_tables`) is pending: it holds the
# folded tables, but the deltas that arrived while the fold ran are not in it, so
# it must not become the head by being the newest chunk. A pending base is a base
# chunk with a record count of zero (a base from `write_snapshot` records its
# table count, at least one). It is skipped like a delta until
# `commit_compacted_head` names it in a chain head together with the deltas it
# did not fold.
#
# Writers
# -------
# `write_snapshot` and `write_base_tables` append a base with the manifest's
# append, which retries a lost slot (up to the retry policy) and cannot lose
# data: the base stands alone.
#
# A chain head is built from the head before it, so a plain append is not enough:
# a writer that read head H, then lost a race and appended after another writer's
# head H2, would publish a chain that forgets H2's delta. `append_delta` and
# `commit_compacted_head` therefore append the chain head at exactly the slot
# after the tip they read (`try_append_at_seq`); if another chunk took that slot,
# they read the tip again, rebuild the chain from the head they now find and try
# again, at most `max_head_attempts` times. Every lost race is counted
# (`lost_races`, `last_write_lost_races`); running out of attempts raises an
# error that ends "(retryable)".
#
# Chain order
# -----------
# The deltas of a chain are in the order their chain heads landed, which is not
# always the order they were ingested: if writer W1 wrote delta 5 and writer W2
# delta 6, and W2's chain head took its slot first, the chain is [6, 5] and the
# name index's "later wins" follows that order, so W1's entry wins. Each head is
# built over the one before it, so no delta is lost, only the apply order
# between concurrent writers is decided by the race.
#
# Reads
# -----
# Reads take the head from a warm handle's own committed tail or, on a fresh
# handle, from the store's listing. A handle that has written reads its own
# latest write; to see another handle's commits, read through a fresh handle.
#
# No clock
# --------
# The store reads no clock. Where time matters (the stamp on a retired delta),
# the caller passes `now_ms`, read from the host's own clock.
#
# Table data and the Slab
# -----------------------
# A write takes its tables as a `Slab[KgTable]`, consumed by popping so a failure
# part-way leaves the slab consistent. All tables are checked before the first
# object is written; a failure after that leaves objects no chunk names, which
# are harmless (content-addressed, never overwritten with different bytes).
# =============================================================================

from komira_arrow.record_batch import RecordBatch
from komira_collections.slab import Slab
from komira_objectstore.cas_manifest import (
    CasManifestStore,
    RetryPolicy,
    chunk_key,
    decode_chunk_body,
    decode_chunk_record_count,
    is_retryable_contention,
)
from komira_objectstore.path import Path
from komira_objectstore.store import CloneableConditionalWriteStore
from komira_parquet_api.types import CompressionCodec
from komira_parquet_writer.record_batch_writer import (
    write_record_batch_to_parquet_bytes,
)

from .chain_view import ChainView
from .chunk_kind import (
    KG_CHUNK_BASE,
    KG_CHUNK_CHAIN,
    KG_CHUNK_DELTA,
    kg_chunk_kind,
)
from .delta_body import KgChainBody, KgDeltaBody, KgNameIndexBody
from .delta_codec import encode_delta_table_object
from .manifest_body import KgManifestBody, KgTableEntry
from .snapshot_view import SnapshotId, SnapshotView
from .source_fingerprint import (
    SourceFingerprintSet,
    SourceFingerprintStore,
    fnv1a64_hex,
)


# The attempts `append_delta` and `commit_compacted_head` make to land a chain
# head after the tip they read, unless the caller says otherwise.
comptime DEFAULT_MAX_HEAD_ATTEMPTS: Int = 8

# The record count of a pending base chunk (`write_base_tables`). A base from
# `write_snapshot` records its table count, which is never zero.
comptime PENDING_BASE_RECORD_COUNT: Int64 = 0


struct KgTable(Movable):
    """One table to write: a name, its rows and the schema version they follow.

    The batch is held in an `Optional` so the write can move it out and leave a
    value that drops cleanly; `RecordBatch` cannot be copied, so a `KgTable` is
    moved into a `Slab` and from there into the write.

    Fields:
        name: The table name ("entities", "edges", ...).
        batch: The rows, until the write takes them.
        schema_version: The table's schema version (see `schemas`).
    """

    var name: String
    var batch: Optional[RecordBatch]
    var schema_version: Int64

    def __init__(
        out self,
        var name: String,
        var batch: RecordBatch,
        schema_version: Int64,
    ):
        """A table `name` of `batch`, stamped with `schema_version`."""
        self.name = name^
        self.batch = Optional[RecordBatch](batch^)
        self.schema_version = schema_version

    def take_batch(mut self) raises -> RecordBatch:
        """Move the rows out.

        Raises:
            If they were already taken.
        """
        if not self.batch:
            raise Error(
                "KgTable.take_batch: the batch of "
                + self.name
                + " was already taken"
            )
        return self.batch.take()


struct _CommittedHead(Movable):
    """The newest base or chain-head chunk: its sequence number, whether it is a
    chain head, and the chain it denotes (a base alone is a chain of one)."""

    var seq: Int64
    var is_chain: Bool
    var chain: KgChainBody

    def __init__(out self, seq: Int64, is_chain: Bool, var chain: KgChainBody):
        self.seq = seq
        self.is_chain = is_chain
        self.chain = chain^


struct KgSnapshotStore[Store: CloneableConditionalWriteStore](Movable):
    """The snapshot lineage of one graph under a key prefix.

    Owns the manifest lineage, a clone of the same backend for the table
    objects, and the fingerprint lineage. `Store.clone()` shares the underlying
    data, so all three reach the same bucket.

    Parameters:
        Store: The object store; an S3-compatible store in production, a shared
            in-memory store in tests.
    """

    var _manifest: CasManifestStore[Self.Store]
    var _objects: Self.Store
    var _fingerprints: SourceFingerprintStore[Self.Store]
    var _prefix: String
    var _max_retries: Int
    var _max_head_attempts: Int
    var _lost_total: Int
    var _lost_last: Int

    def __init__(
        out self,
        var store: Self.Store,
        var prefix: String,
        retry: RetryPolicy = RetryPolicy.default(),
        max_head_attempts: Int = DEFAULT_MAX_HEAD_ATTEMPTS,
    ) raises:
        """A store over `store` with all keys under `prefix`.

        Args:
            store: The backend; cloned for the object writes and the
                fingerprints, then moved into the manifest.
            prefix: The key prefix of this graph; one graph is one prefix.
            retry: How the manifest retries a lost slot: its backoff and its
                budget of retries (default 8).
            max_head_attempts: How many times a chain head is attempted after a
                lost race before the write fails; at least one.

        Raises:
            If `prefix` is empty or ends in a slash, or `max_head_attempts` is
            below one.
        """
        if prefix.byte_length() == 0 or prefix.endswith("/"):
            raise Error(
                "KgSnapshotStore: the prefix must be non-empty and must not end"
                " in a slash, got '" + prefix + "'"
            )
        if max_head_attempts < 1:
            raise Error(
                "KgSnapshotStore: max_head_attempts must be at least 1, got "
                + String(max_head_attempts)
            )
        var objects = store.clone()
        var fp_backend = store.clone()
        self._manifest = CasManifestStore[Self.Store](
            store^, prefix + "/manifest", retry
        )
        self._objects = objects^
        self._fingerprints = SourceFingerprintStore[Self.Store](
            fp_backend^, prefix.copy()
        )
        self._prefix = prefix^
        self._max_retries = retry.max_retries
        self._max_head_attempts = max_head_attempts
        self._lost_total = 0
        self._lost_last = 0

    @always_inline
    def prefix(self) -> String:
        """The key prefix of this graph."""
        return self._prefix.copy()

    def objects_ref(ref self) -> ref [self._objects] Self.Store:
        """A borrow of the handle the table objects are written through, for a
        host that needs to ask the backend something of its own (for example
        whether the bucket is reachable). It hands out no ownership; the other
        handles of this store reach the same backend."""
        return self._objects

    # ---- lost races ----

    @always_inline
    def lost_races(self) -> Int:
        """How many compare-and-set races this handle has lost and retried since
        it was made: each slot a manifest append lost to another writer, and
        each chain head that another chunk got in front of."""
        return self._lost_total

    @always_inline
    def last_write_lost_races(self) -> Int:
        """The races the most recent write lost; zero if it won first time. A
        write is `write_snapshot`, `write_base_tables`, `append_delta` or
        `commit_compacted_head`."""
        return self._lost_last

    def _note_lost(mut self, n: Int):
        if n > 0:
            self._lost_total += n
            self._lost_last += n

    # ---- keys ----

    def _object_key(self, dir: String, ext: String, bytes: List[UInt8]) -> String:
        return self._prefix + "/" + dir + "/" + fnv1a64_hex(Span(bytes)) + ext

    # ---- write ----

    def _put_tables(
        mut self, var tables: Slab[KgTable], is_delta: Bool
    ) raises -> List[KgTableEntry]:
        """Check every table, then write each table's object; the entries in the
        order the tables were given. Consumes `tables`."""
        var n = len(tables)
        for i in range(n):
            ref t = tables[i]
            if t.schema_version < 0:
                raise Error(
                    "KgSnapshotStore: negative schema_version "
                    + String(t.schema_version)
                    + " for table "
                    + t.name
                )
            for j in range(i):
                if tables[j].name == t.name:
                    raise Error(
                        "KgSnapshotStore: table named twice: " + t.name
                    )
        # Popped from the end, so the entries come out backwards.
        var backwards = List[KgTableEntry](capacity=n)
        for _ in range(n):
            var popped = tables.pop()
            var table = popped.take()
            var batch = table.take_batch()
            var name = table.name.copy()
            var rows = Int64(batch.num_rows())
            var bytes: List[UInt8]
            var key: String
            if is_delta:
                bytes = encode_delta_table_object(batch^)
                key = self._object_key("deltas", ".delta", bytes)
            else:
                bytes = write_record_batch_to_parquet_bytes(
                    batch, CompressionCodec.SNAPPY
                )
                key = self._object_key("objects", ".parquet", bytes)
            _ = self._objects.put(Path.parse(key), bytes^)
            backwards.append(
                KgTableEntry(name^, key^, table.schema_version, rows)
            )
        var entries = List[KgTableEntry](capacity=n)
        for i in range(n):
            entries.append(backwards[n - 1 - i].copy())
        return entries^

    def _append_chunk(
        mut self, body: List[UInt8], record_count: Int64
    ) raises -> SnapshotId:
        """Append a chunk after whatever the tip is, counting the slots lost."""
        try:
            var res = self._manifest.append(body, record_count)
            self._note_lost(res.attempts - 1)
            return res.chunk_seq
        except e:
            if is_retryable_contention(String(e)):
                self._note_lost(self._max_retries + 1)
            raise e^

    def _write_base(
        mut self, var tables: Slab[KgTable], embedding_dim: Int, pending: Bool
    ) raises -> SnapshotId:
        self._lost_last = 0
        if len(tables) == 0:
            raise Error("KgSnapshotStore: no tables")
        var body = KgManifestBody(embedding_dim)
        var entries = self._put_tables(tables^, False)
        for i in range(len(entries)):
            ref e = entries[i]
            body.add_table(
                e.name.copy(),
                e.object_key.copy(),
                e.schema_version,
                e.row_count,
            )
        var record_count = Int64(len(entries))
        if pending:
            record_count = PENDING_BASE_RECORD_COUNT
        return self._append_chunk(body.encode(), record_count)

    def write_snapshot(
        mut self, var tables: Slab[KgTable], embedding_dim: Int
    ) raises -> SnapshotId:
        """Write a new base snapshot of `tables`, make it the head and return
        its id.

        Each table becomes a content-addressed Parquet object; one manifest
        chunk records them. Any chain before it is no longer the head (use
        `write_base_tables` and `commit_compacted_head` to fold a chain);
        earlier snapshots stay readable. A snapshot may hold any subset of the
        tables. `tables` is consumed.

        Args:
            tables: The tables, in the order the manifest lists them.
            embedding_dim: The components of every embedding in the graph,
                recorded in the manifest; no default exists.

        Raises:
            If `tables` is empty, a table is named twice or has a negative
            schema version, `embedding_dim` is not positive, or the manifest
            runs out of retries.
        """
        return self._write_base(tables^, embedding_dim, False)

    def write_base_tables(
        mut self, var tables: Slab[KgTable], embedding_dim: Int
    ) raises -> SnapshotId:
        """Write the folded tables of a compaction as a pending base and return
        its chunk.

        The base is not the head and no reader sees it as one: it is skipped
        until `commit_compacted_head` names it in a chain head. Otherwise it is
        written as `write_snapshot` writes a base, and `read_snapshot` opens it.

        Raises:
            As `write_snapshot`.
        """
        return self._write_base(tables^, embedding_dim, True)

    def append_delta(
        mut self,
        var delta_tables: Slab[KgTable],
        var name_index: KgNameIndexBody,
    ) raises -> SnapshotId:
        """Append a delta to the head chain and return the new head.

        `delta_tables` holds only the rows that changed, never a whole-table
        rewrite, and `name_index` the name entries this ingest adds; the base's
        objects are untouched. Two chunks are written: the delta, then a chain
        head naming it after the deltas already there. The chain head is
        appended directly after the tip it was built from and retried from the
        new tip if another chunk got there first (see the file header), so no
        concurrent delta is dropped. `delta_tables` is consumed; it may be empty
        when the delta only adds name-index entries.

        Raises:
            If the lineage has no base yet, a table is named twice or has a
            negative schema version, the manifest runs out of retries, or the
            chain head still loses the race after `max_head_attempts` attempts
            (an error ending "(retryable)": nothing was lost, the delta is
            written and unreferenced).
        """
        self._lost_last = 0
        var first_tip = self._manifest.read_head_authoritative()
        if not self._committed_head(first_tip.chunk_seq):
            raise Error(
                "KgSnapshotStore.append_delta: empty lineage at prefix "
                + self._prefix
                + " (write a base snapshot before a delta)"
            )
        var entries = self._put_tables(delta_tables^, True)
        var body = KgDeltaBody()
        for i in range(len(entries)):
            ref e = entries[i]
            body.add_table(
                e.name.copy(), e.object_key.copy(), e.schema_version, e.row_count
            )
        body.name_index = name_index^
        var delta_seq = self._append_chunk(
            body.encode(), Int64(body.num_tables())
        )
        for _ in range(self._max_head_attempts):
            var tip = self._manifest.read_head_authoritative()
            var found = self._committed_head(tip.chunk_seq)
            if not found:
                raise Error(
                    "KgSnapshotStore.append_delta: the lineage has no head"
                )
            var head = found.take()
            var chain = head.chain.copy()
            chain.append_delta(delta_seq)
            var won = self._manifest.try_append_at_seq(
                tip.chunk_seq + 1,
                tip.next_offset,
                chain.encode(),
                Int64(chain.num_deltas()),
            )
            if won:
                return won.take().chunk_seq
            self._note_lost(1)
        raise self._head_race_error("append_delta")

    def commit_compacted_head(
        mut self,
        new_base_seq: SnapshotId,
        folded_base_seq: SnapshotId,
        var folded_delta_seqs: List[Int64],
    ) raises -> SnapshotId:
        """Make `new_base_seq` the head, carrying forward every delta it did not
        fold, and return the new head.

        A compactor reads a chain (`open_latest_chain`), folds its base and the
        deltas it lists into a new base (`write_base_tables`) and calls this.
        Between the read and now another writer may have appended deltas; those
        are not in `folded_delta_seqs`, so they are carried onto the new base
        and never lost. The head is built from the chain found directly before
        it and retried from the new tip if another chunk took the slot (see the
        file header).

        Args:
            new_base_seq: The base written by `write_base_tables`.
            folded_base_seq: The base of the chain that was folded
                (`ChainView.base_id`).
            folded_delta_seqs: The deltas that were folded
                (`ChainView.delta_seqs`).

        Raises:
            If `new_base_seq` is not a pending base or is not after every
            folded delta (a base cannot have folded a delta written after it),
            the head's base is no longer
            `folded_base_seq` (another compaction committed first: fold the new
            chain instead), a folded delta is not on the head chain, or the
            chain head still loses the race after `max_head_attempts` attempts
            (an error ending "(retryable)").
        """
        self._lost_last = 0
        if new_base_seq < 0:
            raise Error(
                "KgSnapshotStore.commit_compacted_head: negative base "
                + String(new_base_seq)
            )
        var base_chunk = self._manifest.read_chunk(new_base_seq)
        if (
            kg_chunk_kind(base_chunk) != KG_CHUNK_BASE
            or not _is_pending_base(self._record_count(new_base_seq))
        ):
            raise Error(
                "KgSnapshotStore.commit_compacted_head: chunk "
                + String(new_base_seq)
                + " is not a pending base (write it with write_base_tables)"
            )
        for _ in range(self._max_head_attempts):
            var tip = self._manifest.read_head_authoritative()
            var found = self._committed_head(tip.chunk_seq)
            if not found:
                raise Error(
                    "KgSnapshotStore.commit_compacted_head: the lineage has no head"
                )
            var head = found.take()
            if head.chain.base_seq != folded_base_seq:
                raise Error(
                    "KgSnapshotStore.commit_compacted_head: the head's base is "
                    + String(head.chain.base_seq)
                    + ", not the base "
                    + String(folded_base_seq)
                    + " that was folded (another compaction committed first)"
                )
            for j in range(len(folded_delta_seqs)):
                var present = False
                for i in range(head.chain.num_deltas()):
                    if head.chain.delta_seqs[i] == folded_delta_seqs[j]:
                        present = True
                if not present:
                    raise Error(
                        "KgSnapshotStore.commit_compacted_head: folded delta "
                        + String(folded_delta_seqs[j])
                        + " is not on the head chain"
                    )
                # A base written before a delta cannot have folded it. The
                # store cannot see what the pending base holds, so this is the
                # one check it has.
                if folded_delta_seqs[j] >= new_base_seq:
                    raise Error(
                        "KgSnapshotStore.commit_compacted_head: base "
                        + String(new_base_seq)
                        + " was written before folded delta "
                        + String(folded_delta_seqs[j])
                        + " and cannot have folded it"
                    )
            var carry = List[Int64]()
            for i in range(head.chain.num_deltas()):
                var seq = head.chain.delta_seqs[i]
                var was_folded = False
                for j in range(len(folded_delta_seqs)):
                    if folded_delta_seqs[j] == seq:
                        was_folded = True
                if not was_folded:
                    carry.append(seq)
            var new_chain = KgChainBody(new_base_seq, carry^)
            var won = self._manifest.try_append_at_seq(
                tip.chunk_seq + 1,
                tip.next_offset,
                new_chain.encode(),
                Int64(new_chain.num_deltas()),
            )
            if won:
                return won.take().chunk_seq
            self._note_lost(1)
        raise self._head_race_error("commit_compacted_head")

    def _chunk_key(self, seq: Int64) raises -> String:
        return chunk_key(self._prefix + "/manifest", seq).raw()

    def _record_count(self, seq: Int64) raises -> Int64:
        """The record count in the envelope of chunk `seq`."""
        return decode_chunk_record_count(
            self._manifest.get_object(self._chunk_key(seq))
        )

    def _head_race_error(self, who: String) -> Error:
        return Error(
            "KgSnapshotStore."
            + who
            + ": lost the race for the chain head "
            + String(self._max_head_attempts)
            + " times (retryable) - prefix="
            + self._prefix
        )

    def retire_folded_delta(mut self, delta_seq: Int64, now_ms: Int64) raises:
        """Mark a folded delta's chunk as retired at `now_ms`.

        Call it after `commit_compacted_head`, for each delta that was folded and
        not carried forward. It writes a retention marker stamped with `now_ms`
        and nothing else: the chunk and the delta's objects stay, so a reader
        pinned to a head from before the fold reads on undisturbed. When to
        delete them is the host's retention decision, taken against
        `retired_age_ms`; a chunk is reclaimable only once the lineage's log
        start has moved past it (`CasManifestStore.reap` refuses a chunk at or
        above it).

        Args:
            delta_seq: The folded delta's chunk.
            now_ms: The time to stamp, in milliseconds, from the caller's clock.

        Raises:
            If the chunk is not a delta or is still on the head chain.
        """
        if kg_chunk_kind(self._manifest.read_chunk(delta_seq)) != KG_CHUNK_DELTA:
            raise Error(
                "KgSnapshotStore.retire_folded_delta: chunk "
                + String(delta_seq)
                + " is not a delta"
            )
        # The head is read from the store, not from this handle's warm tail: a
        # handle that has not seen another handle's chain head must not retire
        # a delta that head still names.
        var tip = self._manifest.read_head_authoritative()
        var found = self._committed_head(tip.chunk_seq)
        if not found:
            raise Error(
                "KgSnapshotStore.retire_folded_delta: the lineage has no head"
            )
        var chain = found.take().chain.copy()
        for i in range(chain.num_deltas()):
            if chain.delta_seqs[i] == delta_seq:
                raise Error(
                    "KgSnapshotStore.retire_folded_delta: delta "
                    + String(delta_seq)
                    + " is still on the head chain"
                )
        self._manifest.schedule_for_delete_at(delta_seq, now_ms)

    def retired_age_ms(self, delta_seq: Int64, now_ms: Int64) raises -> Int64:
        """Milliseconds from the stamp `retire_folded_delta` wrote to `now_ms`;
        zero if `now_ms` is earlier than the stamp.

        Raises:
            If the delta was never retired.
        """
        var age = now_ms - self._manifest.tombstone_schedule_ts(delta_seq)
        if age < Int64(0):
            return Int64(0)
        return age

    # ---- the head ----

    def _committed_head(
        self, tip_seq: Int64
    ) raises -> Optional[_CommittedHead]:
        """The newest base or chain head at or below `tip_seq`, looking past
        deltas that no head names yet and past pending bases; none if there is
        no such chunk."""
        var seq = tip_seq
        while seq >= 0:
            var envelope = self._manifest.get_object(self._chunk_key(seq))
            var raw = decode_chunk_body(envelope)
            var kind = kg_chunk_kind(raw)
            if kind == KG_CHUNK_BASE and not _is_pending_base(
                decode_chunk_record_count(envelope)
            ):
                return Optional[_CommittedHead](
                    _CommittedHead(seq, False, KgChainBody(seq))
                )
            if kind == KG_CHUNK_CHAIN:
                var chain = KgChainBody.decode(raw)
                _check_chain_refs(chain, seq)
                self._check_chain_kinds(chain, seq)
                return Optional[_CommittedHead](
                    _CommittedHead(seq, True, chain^)
                )
            seq -= 1
        return None

    def _check_chain_kinds(self, chain: KgChainBody, seq: Int64) raises:
        """A chain head names a base and deltas, by chunk kind; a corrupt
        chain that names anything else (and is forward-consistent) is refused
        here, so no writer carries it into a new head. Costs one chunk read
        for the base and one per delta."""
        if (
            kg_chunk_kind(self._manifest.read_chunk(chain.base_seq))
            != KG_CHUNK_BASE
        ):
            raise Error(
                "KgSnapshotStore: chain head "
                + String(seq)
                + " names chunk "
                + String(chain.base_seq)
                + " as its base, which is not a base"
            )
        for i in range(chain.num_deltas()):
            var d = chain.delta_seqs[i]
            if kg_chunk_kind(self._manifest.read_chunk(d)) != KG_CHUNK_DELTA:
                raise Error(
                    "KgSnapshotStore: chain head "
                    + String(seq)
                    + " names chunk "
                    + String(d)
                    + " as a delta, which is not a delta"
                )

    def _head(self, who: String) raises -> _CommittedHead:
        var tip = self._manifest.read_head_fresh()
        var found = self._committed_head(tip.chunk_seq)
        if not found:
            raise Error(
                "KgSnapshotStore."
                + who
                + ": no snapshot written yet (empty lineage at prefix "
                + self._prefix
                + ")"
            )
        return found.take()

    def latest_snapshot_id(self) raises -> SnapshotId:
        """The id of the head, or -1 if nothing was written. Cheaper than
        opening it."""
        var tip = self._manifest.read_head_fresh()
        var found = self._committed_head(tip.chunk_seq)
        if not found:
            return Int64(-1)
        return found.take().seq

    def head_seq(self) raises -> SnapshotId:
        """The chunk of the head; -1 if the lineage is empty. Same as
        `latest_snapshot_id`."""
        return self.latest_snapshot_id()

    def head_is_chain(self) raises -> Bool:
        """True iff the head is a chain head, False iff it is a base alone or the
        lineage is empty. Tells a reader whether `open_latest` or
        `open_latest_chain` applies."""
        var tip = self._manifest.read_head_fresh()
        var found = self._committed_head(tip.chunk_seq)
        if not found:
            return False
        return found.take().is_chain

    def resolve_head_chain(self) raises -> KgChainBody:
        """The head as a chain: a chain head verbatim, a base alone as a chain
        of one with no deltas.

        Raises:
            If the lineage is empty.
        """
        var head = self._head("resolve_head_chain")
        return head.chain.copy()

    # ---- read ----

    def open_latest(self) raises -> SnapshotView[Self.Store]:
        """The head, when it is a base alone.

        Raises:
            If the lineage is empty, or the head is a chain (use
            `open_latest_chain`).
        """
        var head = self._head("open_latest")
        if head.is_chain:
            raise Error(
                "KgSnapshotStore.open_latest: the head is a delta chain; use"
                " open_latest_chain"
            )
        return self.read_snapshot(head.seq)

    def read_snapshot(self, id: SnapshotId) raises -> SnapshotView[Self.Store]:
        """The base snapshot at chunk `id`. An earlier snapshot stays readable
        as long as its chunk and objects are kept.

        Raises:
            If `id` is negative, is not a base chunk, or does not decode.
        """
        if id < Int64(0):
            raise Error(
                "KgSnapshotStore.read_snapshot: negative snapshot id "
                + String(id)
            )
        var raw = self._manifest.read_chunk(id)
        if kg_chunk_kind(raw) != KG_CHUNK_BASE:
            raise Error(
                "KgSnapshotStore.read_snapshot: chunk "
                + String(id)
                + " is not a base snapshot"
            )
        var body = KgManifestBody.decode(raw)
        return SnapshotView[Self.Store](id, body^, self._objects.clone())

    def open_latest_chain(self) raises -> ChainView[Self.Store]:
        """The head as a `ChainView`: base and deltas. A base alone is a chain
        of one.

        Raises:
            If the lineage is empty.
        """
        var head = self._head("open_latest_chain")
        return self.read_chain(head.seq)

    def read_chain(self, head_seq: SnapshotId) raises -> ChainView[Self.Store]:
        """The chain whose head is chunk `head_seq`: a chain head, or a base
        alone as a chain of one. Each earlier head resolves its own base and
        deltas, so a reader can pin any head it was handed.

        Raises:
            If `head_seq` is negative, is a delta, or does not decode.
        """
        var chain = self.read_chain_body(head_seq)
        var base_view = self.read_snapshot(chain.base_seq)
        var deltas = List[KgDeltaBody]()
        for k in range(chain.num_deltas()):
            deltas.append(self.read_delta_body(chain.delta_seqs[k]))
        return ChainView[Self.Store](
            head_seq,
            base_view^,
            chain.delta_seqs.copy(),
            deltas^,
            self._objects.clone(),
        )

    def read_chain_body(self, head_seq: SnapshotId) raises -> KgChainBody:
        """The chain at exactly chunk `head_seq`, not the latest: a chain head
        decodes as is, a base alone is a chain of one.

        Raises:
            If `head_seq` is negative, is a delta, or does not decode.
        """
        if head_seq < Int64(0):
            raise Error(
                "KgSnapshotStore.read_chain_body: negative head seq "
                + String(head_seq)
            )
        var raw = self._manifest.read_chunk(head_seq)
        var kind = kg_chunk_kind(raw)
        if kind == KG_CHUNK_CHAIN:
            var chain = KgChainBody.decode(raw)
            _check_chain_refs(chain, head_seq)
            return chain^
        if kind == KG_CHUNK_BASE:
            return KgChainBody(head_seq)
        raise Error(
            "KgSnapshotStore.read_chain_body: chunk "
            + String(head_seq)
            + " is a delta, not a head"
        )

    def read_delta_body(self, delta_seq: SnapshotId) raises -> KgDeltaBody:
        """The delta at chunk `delta_seq`: its changed tables and name index.
        A compactor uses it to tell a delta that carries rows from one that only
        adds name-index entries.

        Raises:
            If `delta_seq` is negative or is not a delta chunk.
        """
        if delta_seq < Int64(0):
            raise Error(
                "KgSnapshotStore.read_delta_body: negative delta seq "
                + String(delta_seq)
            )
        var raw = self._manifest.read_chunk(delta_seq)
        if kg_chunk_kind(raw) != KG_CHUNK_DELTA:
            raise Error(
                "KgSnapshotStore.read_delta_body: chunk "
                + String(delta_seq)
                + " is not a delta"
            )
        return KgDeltaBody.decode(raw)

    def chain_total_bytes(
        self, chain: KgChainBody
    ) raises -> Tuple[Int64, Int64]:
        """`(base_bytes, delta_bytes)` of a chain: the sizes the
        `CompactionPolicy` size leg compares. They are the object sizes the
        store reports (a metadata request each); no object is downloaded."""
        var base_view = self.read_snapshot(chain.base_seq)
        var base_bytes = Int64(0)
        for i in range(base_view.num_tables()):
            ref e = base_view.body.tables[i]
            base_bytes += self._objects.head(Path.parse(e.object_key)).size
        var delta_bytes = Int64(0)
        for k in range(chain.num_deltas()):
            var dbody = self.read_delta_body(chain.delta_seqs[k])
            for t in range(dbody.num_tables()):
                ref de = dbody.tables[t]
                delta_bytes += self._objects.head(Path.parse(de.object_key)).size
        return (base_bytes, delta_bytes)

    # ---- the change gate: fingerprints per (partition, source) ----

    def fingerprint_load(self) raises -> SourceFingerprintSet:
        """The latest fingerprint set, or an empty one on a fresh lineage. A
        change gate reads it once per ingest to decide changed or unchanged."""
        return self._fingerprints.load()

    def fingerprint_lookup(
        self, partition_id: String, source: String
    ) raises -> String:
        """The stored content hash for `(partition_id, source)`, or "" if it was
        never ingested (always a change)."""
        var fps = self._fingerprints.load()
        return fps.lookup(partition_id, source)

    def fingerprint_save(mut self, var fps: SourceFingerprintSet) raises:
        """Append `fps` as the new current set; refuses to replace a stored set
        with an empty one."""
        self._fingerprints.save(fps^)

    def fingerprint_patch_save(
        mut self,
        var partition_id: String,
        var source: String,
        var content_hash: String,
        var structural_sig: String,
    ) raises:
        """Load the set, replace the one `(partition_id, source)` key and save
        it, so every other source's fingerprint is kept. A changed ingest calls
        it after it wrote its snapshot.

        This is load, patch, save: two handles patching at the same moment can
        lose one patch, so a lineage has one fingerprint writer at a time."""
        var fps = self._fingerprints.load()
        fps.patch(partition_id^, source^, content_hash^, structural_sig^)
        self._fingerprints.save(fps^)


def _is_pending_base(record_count: Int64) -> Bool:
    """Whether a base chunk with this record count is a pending compaction base
    (see the file header)."""
    return record_count == PENDING_BASE_RECORD_COUNT


def _check_chain_refs(chain: KgChainBody, seq: Int64) raises:
    """A chain head names only chunks written before it; one that names a later
    or the same chunk is corrupt."""
    if chain.base_seq >= seq:
        raise Error(
            "KgSnapshotStore: chain head "
            + String(seq)
            + " names base "
            + String(chain.base_seq)
            + ", which is not before it"
        )
    for i in range(chain.num_deltas()):
        if chain.delta_seqs[i] >= seq:
            raise Error(
                "KgSnapshotStore: chain head "
                + String(seq)
                + " names delta "
                + String(chain.delta_seqs[i])
                + ", which is not before it"
            )
