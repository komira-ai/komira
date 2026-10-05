# =============================================================================
# komira_broker/log_compaction.mojo
#   Kafka cleanup.policy=compact (key-based latest-value log compaction)
# =============================================================================
#
# The Kafka log-cleaner semantics: keep only the LATEST value per KEY in the
# cleanable range; a null-value record is a TOMBSTONE that deletes a key and is
# itself retained `delete.retention.ms` then dropped.
#
# -----------------------------------------------------------------------------
# DISTINCT from the two same-named things in this tree (do NOT conflate):
#   * `komira_broker_compaction` (Arrow-IPC -> Parquet TIER compaction) keeps
#     ALL rows — it changes the storage format, not the row set.
#   * `partition_compaction.mojo` (split-LINEAGE collapse) re-routes a frozen
#     parent's rows into range-pure children — it never drops a row.
#   THIS module drops superseded-per-key records (the only one that does).
#
# -----------------------------------------------------------------------------
# THE OFFSET MODEL (the design keystone — read this before touching the cleaner)
# -----------------------------------------------------------------------------
# A broker offset is NOT stored per-record. It is DERIVED: live chunk seq `k`
# occupies `[base_k, base_k + record_count_k - 1]`, where `base_k` is the running
# sum of prior live chunks' `record_count` (the manifest append IS the offset
# allocator — `cas_manifest._append_inner`; `ConsumeCore.resolve_index` rebuilds
# offsets by summing `record_count` from log_start). Therefore:
#
#   ** Changing a chunk's `record_count` renumbers EVERY downstream chunk. **
#
# Kafka compaction MUST preserve surviving records' ORIGINAL offsets and leave
# GAPS (e.g. survivors at offsets 1, 4, 7 — never renumbered to 0, 1, 2). So the
# cleaner rewrites a cleanable chunk's segment to hold ONLY survivor rows, each
# stamped with its ORIGINAL ABSOLUTE OFFSET (a survivor-offset sidecar in the
# rewritten chunk body), while keeping the manifest chunk body's `record_count`
# UNCHANGED — the compacted chunk stays SPARSE within its `[base, last]` span, so
# consumers see the gaps and NO downstream offset shifts. This is the opposite of
# the split-lineage rewrite (which renumbers into fresh children); compaction
# NEVER renumbers.
#
# -----------------------------------------------------------------------------
# WHAT THE CLEANER DOES (one async tick, mirrors retention's RetentionPass)
# -----------------------------------------------------------------------------
#   1. Determine the CLEANABLE range: live chunks `[log_start_seq, head_chunk)` —
#      EXCLUDING the active/head chunk (never compacted, exactly like retention).
#      Records at/after the clean-point (the active region) are untouched.
#   2. Caller decodes the cleanable chunks' segments into RecordBatches (the
#      decode seam — the broker LEAF does not decode; mirrors
#      `compact_split_parent` / `transcode`), one batch per chunk in OFFSET order.
#   3. Build the per-key HIGHEST-offset map across the whole cleanable range
#      (`compact_records`, the PURE decision): for each key keep only the record
#      at its highest offset. A TOMBSTONE (null value) at key K supersedes all
#      prior K and is itself retained iff within the `delete.retention.ms` grace
#      window (relative to `now_ms`); past grace, the tombstone is dropped too.
#   4. Per cleanable chunk: rewrite its segment to the survivor rows that ORIGINATE
#      in that chunk (each stamped with its original absolute offset), and CAS-swap
#      the manifest chunk body in place (same chunk_seq, record_count PRESERVED) to
#      point at the rewritten segment. The original segment object is left for the
#      grace-gated reaper (idempotent + crash-safe — identical lifecycle to
#      retention's tombstone-then-reap).
#
# This module ships the PURE DECISION (`compact_records`, deterministic, no store)
# + the leaf-level survivor model. The store-driving orchestration (read cleanable
# chunks -> decode via seam -> rewrite -> CAS-swap -> grace GC) is `LogCleaner`,
# which mirrors `RetentionPass`. `delete` vs `compact` routing is the topic
# config's `cleanup_policy` (BrokerTopicConfig): a `compact` topic runs the
# cleaner; a `delete` topic runs the time/size reaper; `compact,delete` runs both
# (noted; the cleaner + reaper compose without interference because the cleaner
# never touches the active region and the reaper never touches a live chunk body).
#
# -----------------------------------------------------------------------------
# Encapsulation discipline
# -----------------------------------------------------------------------------
#   * ZERO UnsafePointer in any signature — surface is value / RecordBatch /
#     List / Slab / CasManifestStore (by mut ref) / POD.
#   * ZERO wildcard origins / `unsafe_from_address` / `take_pointee`.
#   * Every type here is a stack value, never a byte-slab element. The
#     POD record/result structs hold Int64 / Bool / one owned String (key) — none
#     stored in an OwnedSlab/AtomicSlab with a wildcard cast.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.record_batch import RecordBatch
from komira_collections.slab import Slab

from komira_objectstore.cas_manifest import CasManifestStore
from komira_objectstore.store import ConditionalWriteStore

from .manifest_body import ManifestBody, encode_manifest_body, MARKER_NONE


# =============================================================================
# CleanupPolicy — the per-topic cleanup.policy (Kafka `cleanup.policy`). POD.
# =============================================================================

comptime CLEANUP_POLICY_DELETE: Int64 = 0  # time/size retention — the default.
comptime CLEANUP_POLICY_COMPACT: Int64 = 1  # key-based latest-value log compaction.
comptime CLEANUP_POLICY_COMPACT_DELETE: Int64 = 2  # both (Kafka `compact,delete`).


@always_inline
def _write_cleanup_policy_name[W: Writer](mut writer: W, p: Int64):
    """WRITE what `cleanup_policy_name` returns. ⚠ THIS WRITES; IT DOES NOT RETURN.

    The arms live here so no string constant is ever SELECTED and
    returned. A literal-returning ladder lowers to two parallel
    (pointer, length) constant arrays whose two call-site references
    an `--emit shared-lib` link can bind INDEPENDENTLY — and a pair bound
    CROSSED reads the wrong string, or out of bounds."""
    if p == CLEANUP_POLICY_COMPACT:
        writer.write(String("compact"))
        return
    if p == CLEANUP_POLICY_COMPACT_DELETE:
        writer.write(String("compact,delete"))
        return
    writer.write(String("delete"))
    return


@always_inline
def cleanup_policy_name(p: Int64) -> String:
    var out = String()
    _write_cleanup_policy_name(out, p)
    return out^


@always_inline
def cleanup_policy_from_name(s: String) -> Int64:
    """Parse a Kafka `cleanup.policy` string. Unknown / empty → `delete` (the
    Kafka default). `compact` and `delete` may be combined (`compact,delete` /
    `delete,compact`)."""
    var has_compact = s.find("compact") >= 0
    var has_delete = s.find("delete") >= 0
    if has_compact and has_delete:
        return CLEANUP_POLICY_COMPACT_DELETE
    if has_compact:
        return CLEANUP_POLICY_COMPACT
    return CLEANUP_POLICY_DELETE


@always_inline
def cleanup_policy_compacts(p: Int64) -> Bool:
    """True iff this policy runs the LOG CLEANER (compact or compact,delete)."""
    return p == CLEANUP_POLICY_COMPACT or p == CLEANUP_POLICY_COMPACT_DELETE


@always_inline
def cleanup_policy_deletes(p: Int64) -> Bool:
    """True iff this policy runs the time/size REAPER (delete or compact,delete)."""
    return p == CLEANUP_POLICY_DELETE or p == CLEANUP_POLICY_COMPACT_DELETE


# =============================================================================
# CompactionConfig — the per-topic compaction tuning (Kafka log-cleaner knobs).
# =============================================================================


@fieldwise_init
struct CompactionConfig(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    """Per-topic log-compaction configuration. POD.

    Field layout:
      var policy: Int64                — CLEANUP_POLICY_{DELETE,COMPACT,
                                         COMPACT_DELETE}. `delete` (the default)
                                         skips the cleaner entirely.
      var delete_retention_ms: Int64   — how long a TOMBSTONE (null-value record)
                                         is retained after it becomes the latest
                                         record for its key, before it too is
                                         dropped (Kafka `delete.retention.ms`).
                                         The tombstone-grace window. `-1` ==
                                         retain forever (never drop a tombstone).
      var min_cleanable_dirty_ratio_pct: Int64 — the dirty-ratio threshold, in
                                         PERCENT (Kafka `min.cleanable.dirty.ratio`,
                                         a fraction in [0,1], here scaled x100 to
                                         stay POD-integer). A cleaner run is only
                                         WORTH it when the cleanable (dirty)
                                         fraction of the log exceeds this. `0`
                                         (the default) == always clean when asked.
    """

    var policy: Int64
    var delete_retention_ms: Int64
    var min_cleanable_dirty_ratio_pct: Int64

    @staticmethod
    def delete_default() -> CompactionConfig:
        """The Kafka default: `cleanup.policy=delete` (no compaction)."""
        return CompactionConfig(CLEANUP_POLICY_DELETE, Int64(-1), Int64(0))

    @staticmethod
    def compact(delete_retention_ms: Int64 = Int64(86_400_000)) -> CompactionConfig:
        """A `cleanup.policy=compact` topic with a `delete.retention.ms` grace
        (Kafka default 24h)."""
        return CompactionConfig(
            CLEANUP_POLICY_COMPACT, delete_retention_ms, Int64(0)
        )

    @always_inline
    def compacts(self) -> Bool:
        return cleanup_policy_compacts(self.policy)

    @always_inline
    def deletes(self) -> Bool:
        return cleanup_policy_deletes(self.policy)


# =============================================================================
# CleanRecord — one decoded record's compaction-relevant identity. POD-ish.
# =============================================================================


@fieldwise_init
struct CleanRecord(Copyable, Movable, Deinitable):
    """One record in the cleanable range, reduced to what compaction needs.

    Field layout:
      var key: String          — the record's KEY (the topic's partition_by
                                 column value, rendered to a canonical String —
                                 INT64 keys via String(value), STRING keys
                                 verbatim). The dedup identity.
      var abs_offset: Int64    — the record's ORIGINAL ABSOLUTE offset (preserved
                                 through compaction — survivors keep this; gaps
                                 appear where superseded records are dropped).
      var chunk_seq: Int64     — the manifest chunk this record originates in (so
                                 the orchestrator knows which chunk to rewrite).
      var is_tombstone: Bool   — True iff the record's VALUE is null (a Kafka
                                 tombstone — deletes the key; retained within the
                                 delete.retention.ms grace, then dropped).
    """

    var key: String
    var abs_offset: Int64
    var chunk_seq: Int64
    var is_tombstone: Bool


# =============================================================================
# CompactionPlan — the survivor set + drop accounting (what compact_records yields).
# =============================================================================


@fieldwise_init
struct CompactionPlan(Movable, Deinitable):
    """The result of the PURE compaction decision over a cleanable range.

    Field layout:
      var survivors: List[CleanRecord]  — the records to KEEP, in ascending
                                          abs_offset order. For each non-tombstone
                                          key: the record at its highest offset.
                                          For a tombstone key within grace: the
                                          tombstone (retained). A tombstone past
                                          grace is NOT a survivor (dropped).
      var dropped_count: Int64          — records removed (superseded duplicates +
                                          grace-expired tombstones).
      var survivor_count: Int64         — len(survivors) (convenience).
    """

    var survivors: List[CleanRecord]
    var dropped_count: Int64
    var survivor_count: Int64


# =============================================================================
# compact_records — the PURE compaction decision (no store; deterministic).
# =============================================================================


def compact_records(
    records: List[CleanRecord],
    delete_retention_ms: Int64,
    now_ms: Int64,
) raises -> CompactionPlan:
    """Given the cleanable range's records (ANY offset order) + the tombstone
    grace window, return the survivor set: for each KEY, ONLY the record at its
    HIGHEST offset, with tombstone-grace applied.

    Semantics (Kafka log-cleaner):
      * Latest-per-key: a key's survivor is its highest-offset record. All lower-
        offset records for that key are dropped (superseded).
      * Tombstone (null value): the highest-offset record for a key being a
        tombstone means the key is DELETED. The tombstone is RETAINED (a survivor)
        iff it is still within the grace window — i.e. `delete_retention_ms < 0`
        (retain forever) OR `now_ms - abs_offset_as_time < grace`. Since this leaf
        has no per-record timestamp, the grace gate uses the record's
        `abs_offset` as a monotone proxy ONLY when the caller passes an
        offset-as-time mapping; the canonical path passes the tombstone's
        creation ms via the orchestrator. Here the PURE decision treats grace as:
        a tombstone is dropped iff the caller has marked the window elapsed by
        passing `now_ms >= 0 and delete_retention_ms == 0` (immediate-drop) — see
        `LogCleaner.run` for the wall-clock-driven gate. To keep the PURE function
        deterministic and store-free, grace is expressed as: keep the tombstone
        unless `delete_retention_ms == 0` (drop-immediately) — the orchestrator
        supplies the real wall-clock comparison by pre-filtering records it deems
        grace-expired. (The offline test exercises BOTH: in-grace retain +
        immediate-drop.)
      * OFFSETS ARE PRESERVED: survivors keep their original `abs_offset`. The
        survivor list is returned ascending by `abs_offset` (gaps where dropped).

    Determinism: a single forward scan builds key -> best-record; ties cannot
    occur (offsets are unique within a partition). Then a second pass applies the
    tombstone-grace drop + sorts ascending by offset.
    """
    # Pass 1: per-key highest-offset record. Parallel key/offset/index lists keep
    # the surface POD (no Dict[String, _] needed for the small cleanable ranges;
    # manifests are small — the same "manifests are small" assumption retention
    # and resolve_index lean on).
    var keys = List[String]()
    var best_idx = List[Int]()  # index into `records` of the current best for keys[j]
    var n = len(records)
    for i in range(n):
        ref rec = records[i]
        var j = _find_key(keys, rec.key)
        if j < 0:
            keys.append(rec.key)
            best_idx.append(i)
        else:
            if records[i].abs_offset > records[best_idx[j]].abs_offset:
                best_idx[j] = i

    # Pass 2: emit survivors. A key's survivor is its highest-offset record,
    # UNLESS that record is a tombstone whose grace window says drop-immediately
    # (delete_retention_ms == 0). `now_ms` is accepted for signature symmetry
    # with the orchestrator (the wall-clock gate lives there; the pure fn's
    # grace is the deterministic immediate-drop knob).
    _ = now_ms
    var survivors = List[CleanRecord]()
    var nk = len(keys)
    for j in range(nk):
        ref best = records[best_idx[j]]
        if best.is_tombstone and delete_retention_ms == Int64(0):
            # Grace already elapsed (immediate-drop) → drop the tombstone too.
            continue
        survivors.append(
            CleanRecord(
                key=String(best.key),
                abs_offset=best.abs_offset,
                chunk_seq=best.chunk_seq,
                is_tombstone=best.is_tombstone,
            )
        )

    # Sort survivors ascending by abs_offset (offsets preserved; gaps visible).
    _sort_by_offset(survivors)

    var sc = Int64(len(survivors))
    # dropped == every scanned record that is NOT a survivor (superseded
    # duplicates + grace-expired tombstones).
    return CompactionPlan(
        survivors=survivors^, dropped_count=Int64(n) - sc, survivor_count=sc
    )


@always_inline
def _find_key(keys: List[String], k: String) -> Int:
    """Linear find of `k` in `keys` (small cleanable ranges — manifests are
    small). Returns the index or -1."""
    for j in range(len(keys)):
        if keys[j] == k:
            return j
    return -1


def _sort_by_offset(mut survivors: List[CleanRecord]):
    """Ascending insertion sort by abs_offset (small N — cleanable range)."""
    for i in range(1, len(survivors)):
        var v = survivors[i].copy()
        var j = i - 1
        while j >= 0 and survivors[j].abs_offset > v.abs_offset:
            survivors[j + 1] = survivors[j].copy()
            j -= 1
        survivors[j + 1] = v^


# =============================================================================
# extract_clean_records — decode one cleanable chunk's RecordBatch -> CleanRecords.
# =============================================================================


def extract_clean_records(
    batch: RecordBatch,
    key_col: Int,
    value_col: Int,
    base_offset: Int64,
    chunk_seq: Int64,
) raises -> List[CleanRecord]:
    """Reduce one cleanable chunk's decoded RecordBatch to its per-record
    compaction identity (`CleanRecord`s). The caller supplies the chunk's
    `base_offset` (manifest-authoritative — `ConsumeCore.resolve_index` /
    `SegmentRef.base_offset`) so each record's ORIGINAL ABSOLUTE offset is
    `base_offset + row` (offsets are preserved — never renumbered).

    Tombstone detection: a record is a tombstone iff its VALUE column entry is
    NULL (the Arrow validity bit is 0) — distinguishable from an empty value.
    STRING value columns use `column_as_string(...).is_null(row)`; this is the
    Kafka `null value == tombstone` contract.

    KEY rendering: INT64 keys render via `String(column_value(...))`; STRING keys
    render verbatim via `column_as_string(...).get(row)`. The String form is the
    canonical dedup identity (so heterogeneous key dtypes share one code path)."""
    var out = List[CleanRecord]()
    var nrows = batch.num_rows()
    var key_is_string = _col_is_string(batch, key_col)
    var val_is_string = _col_is_string(batch, value_col)
    for row in range(nrows):
        # --- KEY ---
        var key_str: String
        if key_is_string:
            key_str = batch.column_as_string(key_col).get(row)
        else:
            key_str = String(Int(batch.column_value(key_col, row)))
        # --- TOMBSTONE (null value) ---
        var tomb: Bool
        if val_is_string:
            tomb = batch.column_as_string(value_col).is_null(row)
        else:
            tomb = batch.column_as_primitive_int64(value_col).is_null(row)
        out.append(
            CleanRecord(
                key=key_str^,
                abs_offset=base_offset + Int64(row),
                chunk_seq=chunk_seq,
                is_tombstone=tomb,
            )
        )
    return out^


@always_inline
def _col_is_string(batch: RecordBatch, col: Int) raises -> Bool:
    """True iff column `col`'s arrow type is a STRING/utf8 type."""
    var t = batch.schema.field_arrow_type(col)
    return t == ArrowType(ArrowType.STRING.type_id)


# =============================================================================
# RewrittenChunkBody — the in-place chunk-body rewrite (record_count PRESERVED).
# =============================================================================


def encode_compacted_chunk_body(
    original: ManifestBody,
    new_object_key: String,
    new_crc32: UInt32,
    survivor_offsets: List[Int64],
) raises -> List[UInt8]:
    """Encode the rewritten manifest chunk body for a compacted segment.

    CRITICAL (offset preservation): the new body keeps the ORIGINAL
    `record_count` so the manifest offset allocator never renumbers the
    downstream chunks — the compacted chunk stays SPARSE within its
    `[base, base + record_count - 1]` span. Only the `object_key` (points at the
    rewritten segment) and `crc32` change; the retention/producer/txn trailers are carried
    through verbatim (a compaction rewrite preserves the chunk's retention +
    producer + txn metadata).

    `survivor_offsets` are the surviving records' ORIGINAL absolute offsets (a
    sidecar the consumer uses to present survivors at their true offsets with
    gaps). They are appended length-prefixed AFTER the existing trailers so an
    OLD (pre-compaction) decoder ignores them — the chunk body remains
    backward-compatible (same tolerant trailer-scan as ManifestBody.decode).

    Returns the new chunk-body bytes (the consumer body INSIDE the manifest chunk
    envelope; the caller wraps it via the manifest rewrite verb)."""
    # Reuse the canonical encoder for the base body (record_count UNCHANGED).
    var body = encode_manifest_body(
        new_object_key,
        original.record_count,  # PRESERVED — never renumber downstream.
        new_crc32,
        original.segment_bytes,
        original.creation_ts_ms,
        original.producer_id,
        original.producer_epoch,
        original.first_seq,
        original.last_seq,
        original.marker_type,
        String(original.txn_id),
    )
    # Append the survivor-offset sidecar (length-prefixed; ignored by old decoders).
    _put_i64_le(body, Int64(len(survivor_offsets)))
    for i in range(len(survivor_offsets)):
        _put_i64_le(body, survivor_offsets[i])
    return body^


@always_inline
def _put_i64_le(mut out: List[UInt8], v: Int64):
    var u = UInt64(v)
    for i in range(8):
        out.append(UInt8((u >> UInt64(8 * i)) & UInt64(0xFF)))


# =============================================================================
# CleanResult — what a LogCleaner.run reports. POD.
# =============================================================================


@fieldwise_init
struct CleanResult(Copyable, Movable, Deinitable):
    """The outcome of one log-compaction tick.

    Field layout:
      var cleanable_chunks: Int64    — live non-active chunks in the cleanable
                                       range that were considered.
      var records_scanned: Int64     — total records across the cleanable range.
      var survivors: Int64           — records kept (latest-per-key + live
                                       tombstones).
      var dropped: Int64             — records removed (superseded + grace-expired
                                       tombstones).
      var ran: Bool                  — True iff the cleaner actually compacted
                                       (False when policy != compact, the dirty
                                       ratio gate failed, or the range was empty).
    """

    var cleanable_chunks: Int64
    var records_scanned: Int64
    var survivors: Int64
    var dropped: Int64
    var ran: Bool


# =============================================================================
# LogCleaner — the store-driving log-compaction orchestrator (mirrors RetentionPass).
# =============================================================================


struct LogCleaner[Storage: ConditionalWriteStore](Movable, Deinitable):
    """Runs one log-compaction tick over a partition's CasManifestStore. Holds
    only the per-topic `CompactionConfig`; reads a fresh manifest snapshot each
    run (stateless over the manifest, exactly like RetentionPass).

    The broker LEAF does NOT decode segments (segment decode
    pulls the SDK Arrow-IPC reader). So `run` takes the cleanable chunks ALREADY
    DECODED into RecordBatches by the caller (the decode seam — mirrors
    `compact_split_parent` / `transcode`), one batch per cleanable chunk in
    chunk-seq (== offset) order, plus the chunk metadata (seq + base_offset) so
    each record's ORIGINAL ABSOLUTE offset is reconstructed.
    """

    var _config: CompactionConfig
    var _key_col: Int
    var _value_col: Int

    def __init__(
        out self,
        config: CompactionConfig,
        key_col: Int = 0,
        value_col: Int = 1,
    ):
        self._config = config
        self._key_col = key_col
        self._value_col = value_col

    def run(
        mut self,
        mut manifest: CasManifestStore[Self.Storage],
        var cleanable_batches: Slab[RecordBatch],
        cleanable_base_offsets: List[Int64],
        cleanable_chunk_seqs: List[Int64],
        now_ms: Int64,
    ) raises -> CleanResult:
        """Compact the supplied cleanable chunks (latest-per-key + tombstone
        grace), PRESERVING surviving offsets (gaps where superseded records are
        dropped), and CAS-swap each rewritten chunk body in place (record_count
        UNCHANGED — never renumber downstream chunks).

        `cleanable_batches[i]` is the decoded RecordBatch for chunk
        `cleanable_chunk_seqs[i]`, whose first record is at absolute offset
        `cleanable_base_offsets[i]`. The active/head chunk MUST NOT be included
        (the caller excludes it — the active region is never compacted).

        Routing: if `policy` does NOT compact (a `delete`-only topic), this is a
        no-op (`ran=False`) — the time/size reaper handles that topic. (A
        `compact,delete` topic runs BOTH; this method runs the compaction half.)
        """
        var n = len(cleanable_batches)
        if not self._config.compacts() or n == 0:
            # No-op path: drop the supplied batches (the Slab destructor frees
            # each RecordBatch; nothing rewritten).
            _ = cleanable_batches^
            return CleanResult(
                cleanable_chunks=Int64(n),
                records_scanned=Int64(0),
                survivors=Int64(0),
                dropped=Int64(0),
                ran=False,
            )

        # 1. Reduce every cleanable batch to CleanRecords (key, abs_offset,
        #    chunk_seq, is_tombstone). One batch ref at a time (disjoint borrows).
        var records = List[CleanRecord]()
        for i in range(n):
            var recs = extract_clean_records(
                cleanable_batches[i],
                self._key_col,
                self._value_col,
                cleanable_base_offsets[i],
                cleanable_chunk_seqs[i],
            )
            for r in range(len(recs)):
                records.append(recs[r].copy())
        cleanable_batches.set_len_unchecked(0)
        _ = cleanable_batches^

        var scanned = Int64(len(records))

        # 2. PURE decision: per-key highest-offset survivor + tombstone grace.
        #    The wall-clock tombstone grace is applied HERE (the orchestrator owns
        #    the clock): a tombstone whose chunk creation_ts is older than
        #    `delete_retention_ms` is grace-expired → drop it (pass
        #    delete_retention_ms=0 to compact_records for those keys). Since this
        #    leaf-level offline path has no per-record ts, the grace decision uses
        #    the config's `delete_retention_ms` directly: `< 0` retain forever,
        #    `== 0` drop-immediately, `> 0` retain (the wall-clock pre-filter
        #    lives in the S3-integration caller that has segment creation_ts).
        var plan = compact_records(
            records, self._config.delete_retention_ms, now_ms
        )

        # 3. Per cleanable chunk: gather its surviving offsets, rewrite the chunk
        #    body in place (record_count PRESERVED), CAS-swap the manifest.
        var survivor_total = plan.survivor_count
        var rewritten = Int64(0)
        for i in range(n):
            var seq = cleanable_chunk_seqs[i]
            var surv_offsets = List[Int64]()
            for s in range(len(plan.survivors)):
                if plan.survivors[s].chunk_seq == seq:
                    surv_offsets.append(plan.survivors[s].abs_offset)
            # Read the original body to carry its trailers through (the rewrite
            # preserves record_count + retention/producer/txn metadata).
            var orig_bytes = manifest.read_chunk(seq)
            var orig = ManifestBody.decode(orig_bytes)
            # Rewrite the body (same object_key + crc here at the leaf level — the
            # S3-integration caller re-PUTs a compacted .seg and passes its new
            # key/crc; the offline path keeps the key, proving the offset-
            # preservation + record_count invariant without an SDK re-encode).
            var new_body = encode_compacted_chunk_body(
                orig, String(orig.object_key), orig.crc32, surv_offsets
            )
            manifest.rewrite_chunk_body(seq, new_body)
            rewritten += Int64(1)

        _ = rewritten
        return CleanResult(
            cleanable_chunks=Int64(n),
            records_scanned=scanned,
            survivors=survivor_total,
            dropped=plan.dropped_count,
            ran=True,
        )


# =============================================================================
# decode_compacted_survivor_offsets — read the survivor-offset sidecar back.
# =============================================================================


def decode_compacted_survivor_offsets(
    chunk_body: List[UInt8],
) raises -> List[Int64]:
    """Read the survivor-offset sidecar appended by `encode_compacted_chunk_body`
    off a (possibly compacted) manifest chunk body. Returns an EMPTY list for an
    un-compacted body (no sidecar — the tolerant trailer scan finds nothing past
    the txn trailer). A compacted body yields the surviving records' ORIGINAL
    absolute offsets, proving offsets were PRESERVED (gaps, no renumber).

    The sidecar sits AFTER the txn trailer in the body layout (see
    `ManifestBody.decode` for the trailer offsets). We re-walk to the end of the
    txn trailer, then read `[ survivor_count i64 ][ offset i64 ]*` if present."""
    var n = len(chunk_body)
    # record_count(8) + crc(4) + key_len(8) + key + retention(16) + producer(32) + txn...
    var key_len = Int(_get_i64_le(chunk_body, 12))
    var trailer_at = 20 + key_len
    if trailer_at + 16 > n:
        return List[Int64]()  # legacy body, no sidecar.
    var producer_at = trailer_at + 16
    if producer_at + 32 > n:
        return List[Int64]()  # retention body, no sidecar.
    var txn_at = producer_at + 32
    if txn_at + 16 > n:
        return List[Int64]()  # producer body, no sidecar.
    var txn_id_len = Int(_get_i64_le(chunk_body, txn_at + 8))
    var sidecar_at = txn_at + 16 + txn_id_len
    if sidecar_at + 8 > n:
        return List[Int64]()  # txn body, no sidecar.
    var count = Int(_get_i64_le(chunk_body, sidecar_at))
    var out = List[Int64]()
    var off = sidecar_at + 8
    for _ in range(count):
        if off + 8 > n:
            break
        out.append(_get_i64_le(chunk_body, off))
        off += 8
    return out^


def is_chunk_compacted(chunk_body: List[UInt8]) raises -> Bool:
    """True iff `chunk_body` carries a survivor-offset SIDECAR BLOCK — i.e. the
    chunk has been through the log cleaner — regardless of how many survivors it
    holds.

    This is the COMPACTED discriminator that `decode_compacted_survivor_offsets`
    alone cannot provide: a ZERO-SURVIVOR chunk (every key fully superseded by a
    later cleanable chunk) writes a sidecar block with `count == 0`, whose
    decoded offset list is EMPTY — byte-identical at the offset-list level to an
    UN-compacted chunk (which has no sidecar block at all). Using
    `len(decode_compacted_survivor_offsets(body)) > 0` as the "is compacted" test
    therefore mis-reads a zero-survivor compacted chunk as un-compacted, breaking
    the cleaner's idempotency skip-guard (it would re-rewrite the already-empty
    chunk on every round, minting a fresh orphan each time).

    The presence test walks to the same `sidecar_at` offset
    `decode_compacted_survivor_offsets` uses and reports whether the 8-byte
    survivor-count word is PHYSICALLY present (`sidecar_at + 8 <= len`). An
    un-compacted body (legacy / retention / producer / txn, no sidecar) stops before
    `sidecar_at`, so this returns False; a compacted body (>=1 survivor OR
    zero-survivor) has the count word present, so this returns True."""
    var n = len(chunk_body)
    # record_count(8) + crc(4) + key_len(8) + key + retention(16) + producer(32) + txn...
    var key_len = Int(_get_i64_le(chunk_body, 12))
    var trailer_at = 20 + key_len
    if trailer_at + 16 > n:
        return False  # legacy body, no sidecar block.
    var producer_at = trailer_at + 16
    if producer_at + 32 > n:
        return False  # retention body, no sidecar block.
    var txn_at = producer_at + 32
    if txn_at + 16 > n:
        return False  # producer body, no sidecar block.
    var txn_id_len = Int(_get_i64_le(chunk_body, txn_at + 8))
    var sidecar_at = txn_at + 16 + txn_id_len
    # Compacted iff the 8-byte survivor-count word is physically present (a
    # zero-survivor chunk still writes this word, with value 0).
    return sidecar_at + 8 <= n


@always_inline
def _get_i64_le(bytes: List[UInt8], off: Int) raises -> Int64:
    if off + 8 > len(bytes):
        raise Error("log_compaction: truncated i64 at " + String(off))
    var u = UInt64(0)
    for i in range(8):
        u |= UInt64(Int(bytes[off + i])) << UInt64(8 * i)
    return Int64(u)
