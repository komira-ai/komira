# =============================================================================
# komira_objectstore/shuffle_sink.mojo
#   SINK_SHUFFLE_WRITE — the map-producer scatter-and-write.
# =============================================================================
#
# The map-write: scatter via `HashPartitioner`, write the `{producer_id}.seg`
# body with the DENSE R-entry index trailer, append `_entries`.
#
# A map shard (producer) takes its rows, partitions each row's KEY bytes by
# `HashPartitioner` into R buckets, builds R dense partition bodies (INCLUDING
# zero-length bodies for partitions it wrote no rows for — the DENSE-INDEX
# INVARIANT), writes its `{producer_id}.seg` via `write_segment` (the
# dense trailer carries all R entries), then appends its `_entries` ShuffleEntry
# under `(producer_id, first_seq=step_id)` via the PUBLIC
# `CasManifestStore.append_idempotent` — so a map REPLAY of the same producer
# lands an idempotent-identical entry.
#
# Body format (a simple row encoding, not a columnar split — the seal is
# body-agnostic):
# each row in a partition is encoded as a length-prefixed payload
# `[len: i64 LE][payload bytes]`. The reducer (`shuffle_source`) concatenates the
# raw partition bytes across producers and the test harness splits them back into
# the row set for the parity assert. The seal/`.seg`/`_entries` protocol does NOT
# care about the body shape — it only carries the dense (offset, len, row_count)
# slices — so a richer columnar body can drop in with no seal change.
#
# `.seg` body is a PLAIN disjoint-key PUT (no CAS); only the `_entries` append
# rides the CAS manifest.
#
# Pointer discipline: ZERO UnsafePointer. Rows / bodies flow as owned
# `List[UInt8]`; the store is held by value (clone-shared handle). heap-reuse
# N/A (transient values + by-value store handle, no wildcard origins).
# =============================================================================

from komira_objectstore.cas_manifest import (
    CasManifestStore,
    RetryPolicy,
    IDEMPOTENT_COMMITTED,
    IDEMPOTENT_DUPLICATE,
    IDEMPOTENT_RETRYABLE,
)
from komira_objectstore.store import CloneableConditionalWriteStore
from komira_objectstore.path import Path
from komira_objectstore.shuffle_codec import put_i64_le
from komira_objectstore.shuffle_entry import (
    ShuffleEntry,
    PartitionSlot,
    encode_shuffle_entry,
)
from komira_objectstore.shuffle_partitioner import HashPartitioner
from komira_objectstore.shuffle_segment import SegWriter, write_segment
from komira_objectstore.shuffle_seal_driver import entries_prefix


# -----------------------------------------------------------------------------
# ShuffleRow — a row: (key_bytes, payload_bytes). The key drives the
# partition; the payload is the opaque body the reducer round-trips for parity.
# -----------------------------------------------------------------------------


@fieldwise_init
struct ShuffleRow(Copyable, Movable, Deinitable):
    """One map-input row: `key` (partitioned on) + `payload` (the
    opaque body bytes). Transient value (owned-List fields) — never a byte-slab
    element, so heap-reuse is N/A.

    Field layout:
      var key: List[UInt8]      — the partition key (hashed by HashPartitioner).
      var payload: List[UInt8]   — the row's body bytes (round-tripped verbatim).
    """

    var key: List[UInt8]
    var payload: List[UInt8]


# -----------------------------------------------------------------------------
# Body codec — a partition body is a sequence of length-prefixed payloads. The
# reducer-side `decode_partition_payloads` (in shuffle_source) inverts it.
# -----------------------------------------------------------------------------


def encode_partition_body(rows: List[ShuffleRow]) -> List[UInt8]:
    """Encode a partition's rows as concatenated `[len: i64 LE][payload]` frames.
    An EMPTY `rows` yields an EMPTY body (zero bytes) — the dense zero-length
    partition."""
    var out = List[UInt8]()
    for i in range(len(rows)):
        ref payload = rows[i].payload
        put_i64_le(out, Int64(len(payload)))
        for j in range(len(payload)):
            out.append(payload[j])
    return out^


# -----------------------------------------------------------------------------
# SINK_SHUFFLE_WRITE — scatter the producer's rows into R buckets, write the
# `.seg`, append the `_entries` entry idempotently.
# -----------------------------------------------------------------------------


def shuffle_segment_key(
    shuffle_id: Int64, step_id: Int64, producer_id: Int64
) -> String:
    """The `{shuffle_id}/{step_id}/{producer_id}.seg` object key."""
    return (
        String(shuffle_id)
        + "/"
        + String(step_id)
        + "/"
        + String(producer_id)
        + ".seg"
    )


def sink_shuffle_write[
    S: CloneableConditionalWriteStore
](
    mut store: S,
    shuffle_id: Int64,
    step_id: Int64,
    producer_id: Int64,
    partition_count: Int64,
    rows: List[ShuffleRow],
) raises -> ShuffleEntry:
    """SINK_SHUFFLE_WRITE: partition `rows` into R buckets by
    `HashPartitioner`, write `{producer_id}.seg` (DENSE R-entry trailer incl
    zero-length), then append the `_entries` ShuffleEntry under
    `(producer_id, step_id)` idempotently. Returns the ShuffleEntry the producer
    committed (its dense slots match the `.seg` trailer).

    IDEMPOTENT REPLAY: a re-run of the SAME
    producer (same `(producer_id, step_id)`) overwrites the `.seg` with
    byte-identical content (disjoint-key PUT). The sink's `append_idempotent`
    is the STORAGE-LAYER each-once guard: on a replay its `DedupSentinel` claim
    412s on the already-claimed `(producer_id, step_id)` and lands NO second
    `_entries` chunk, so the `_entries` manifest holds ONE chunk per producer.
    (test_phase_a_idempotent_replay_no_double_read asserts this directly at the
    storage layer — n_prod chunks after a replay.)
    The CORRECTNESS guard that the END-TO-END read (the idempotent-replay test)
    relies on, however, is the DRIVER's `_scan_entries` dedup
    (`shuffle_seal_driver._scan_entries` -> `sorted_unique_i64`): it
    SET-deduplicates committed producer ids and keeps the first-seen entry per
    producer. That dedup is what makes the read each-once even if a SECOND chunk
    did land — i.e. reverting THIS sink to a plain `append` (so a replay lands a
    2nd `_entries` chunk) still passes the end-to-end test 2, BECAUSE the driver
    dedup masks the extra chunk. The storage-layer assertion in test 2 is what
    catches a sink regression that the driver dedup would otherwise hide.
    """
    var r = Int(partition_count)
    var partitioner = HashPartitioner(partition_count)

    # Scatter rows into R buckets by key. `buckets[p]` collects partition p's
    # rows (in producer-local order).
    var buckets = List[List[ShuffleRow]]()
    for _p in range(r):
        buckets.append(List[ShuffleRow]())
    for i in range(len(rows)):
        ref row = rows[i]
        var pid = partitioner.partition_for(row.key)
        buckets[pid].append(row.copy())

    # Build the `.seg` densely: append EXACTLY R partition bodies in order
    # 0..R-1, INCLUDING zero-length bodies (the DENSE-INDEX INVARIANT).
    var w = SegWriter()
    for p in range(r):
        var body = encode_partition_body(buckets[p])
        w.append_partition(body, Int64(len(buckets[p])))

    var seg_key_str = shuffle_segment_key(shuffle_id, step_id, producer_id)
    var seg_key = Path.parse(seg_key_str)
    # `write_segment` does ONE plain disjoint-key PUT and returns the dense slots
    # (which the `_entries` entry mirrors). A replay re-PUTs byte-identical bytes.
    var slots = write_segment(store, seg_key, w^)

    # Append the `_entries` ShuffleEntry idempotently under (producer_id,
    # step_id). The body carries the dense R-slot read plan + the `.seg` key.
    var entry = ShuffleEntry(producer_id, seg_key_str, slots^)
    var entry_body = encode_shuffle_entry(entry)
    var entries = CasManifestStore[S](
        store.clone(), entries_prefix(shuffle_id, step_id), RetryPolicy.default()
    )
    # append_idempotent under (producer_id, first_seq=step_id), producer_epoch=0,
    # registered_epoch=0 (never fenced). The DedupSentinel claim CAS on
    # `(producer_id, step_id)` is the each-once oracle: a re-driven producer's
    # second append 412s on the already-claimed sentinel and does NOT land a
    # second `_entries` chunk -> the `_entries` manifest holds ONE chunk for this
    # producer, and the driver's seal scan dedups to one set member.
    #
    # OUTCOME interpretation (single-process, NO concurrent writer):
    #   * COMMITTED  — we won + appended (the first write).
    #   * DUPLICATE  — already fully committed (idempotent ack).
    #   * RETRYABLE  — the sentinel is STAGED (a prior identical write of THIS
    #     (producer_id, step_id) claimed it; the chunk is durable, but the
    #     `_FINALIZE_ON_HOT_PATH` gate is OFF so the sentinel stays staged, and
    #     the phantom-detect tail-scan can't match a shuffle body (no broker
    #     producer trailer), so it returns RETRYABLE rather than DUPLICATE —
    #     exactly the substrate quirk DECISION (b) in `shuffle_seal.mojo`
    #     documents for the seal). With a single producer per id there is NO
    #     concurrent writer, so a RETRYABLE here is the idempotent-replay
    #     signal: the entry is already durable, do NOT re-append, do NOT raise.
    #     (A real concurrent double-drive is arbitrated by the cross-process
    #     claim loop.)
    # All three outcomes mean "this producer's `_entries` entry is durable
    # exactly once" — the reversion that breaks this (a plain `append` instead of
    # `append_idempotent`) lands TWO chunks for the replayed producer; the seal's
    # sorted_unique_i64 still dedups the SET, but a count-based seal would then
    # double-read (the idempotent-replay test).
    var res = entries.append_idempotent(
        entry_body^,
        Int64(1),  # record_count = 1 (one entry record)
        producer_id,  # the DedupSentinel identity component
        Int64(0),  # producer_epoch
        step_id,  # first_seq
        step_id,  # last_seq
        Int64(0),  # registered_epoch (never fenced)
    )
    if (
        res.outcome != IDEMPOTENT_COMMITTED
        and res.outcome != IDEMPOTENT_DUPLICATE
        and res.outcome != IDEMPOTENT_RETRYABLE
    ):
        _ = entries^
        raise Error(
            "shuffle_sink: producer "
            + String(producer_id)
            + " `_entries` append returned outcome "
            + String(res.outcome)
            + " (expected COMMITTED/DUPLICATE/RETRYABLE)."
        )
    _ = entries^
    return entry^
