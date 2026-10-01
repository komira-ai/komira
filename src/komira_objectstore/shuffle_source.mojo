# =============================================================================
# komira_objectstore/shuffle_source.mojo
#   SOURCE_SHUFFLE_READ — the SOLE reduce-facing shuffle read.
# =============================================================================
#
# "Read the seal": the reduce shard reads ONLY through this.
#
# `read_shuffle_partition(...)` is the ONE public read entry point a reduce shard
# uses. It is the structural form of the SOLE-READ-BARRIER INVARIANT:
#
#   * It reads the SEAL first (block-on-absence + exact-producer-set re-verify)
#     via `read_seal` (module `shuffle_seal_driver`). `read_seal` returns ONLY
#     the verified `StepComplete` — never the raw `_entries` tail. The `_entries`
#     `CasManifestStore` construction + the producer-set scan are `_`-prefixed
#     MODULE-PRIVATE inside `shuffle_seal_driver` (`_entries_manifest`,
#     `_scan_entries`). There is NO public raw-`_entries`-read function anywhere.
#   * It resolves the LIFTED dense read plan for partition `p`, DROPS zero-length
#     slices, `get_range`s each NON-ZERO slice from the producer's
#     `.seg`, and concatenates them in plan order.
#   * If EVERY slice for `p` is zero-length (an empty partition — no producer
#     wrote a row for it), it returns EMPTY immediately: never blocks, never
#     errors.
#
# LAYERING CHOICE (the sole-read-barrier): this
# module is co-located in `komira_objectstore` (NOT in an engine package) so it
# can call the seal read while the `_entries` scan stays module-private to
# `shuffle_seal_driver`. The alternative — put the source in an engine package
# and re-export an entries-read — would either expose the raw `_entries` tail to
# the reduce path (violating) or force `komira_objectstore` to depend on
# the engine (inverting the layering: the engine depends on objectstore).
# Co-location keeps the invariant STRUCTURAL: the only reduce read API is
# `read_shuffle_partition`, and the `_entries` scan is unreachable from it except
# through the verified seal. `read_seal` is callable (it returns only the verified
# `StepComplete`), but it is NOT the entries tail — exposing it is safe.
#
# `get_range` (base `ConditionalWriteStore` verb) is used per non-zero slice — NOT
# the concurrent `get_ranges` (that lives on the separate `RangeFetchStore`
# refining trait, which the base CAS store does not conform to). A
# coalesced/concurrent fan-out (`plan_coalesce` + `get_ranges`) is not built.
#
# Pointer discipline: ZERO UnsafePointer. Bytes flow as owned `List[UInt8]`; the
# store is held by value (clone-shared handle). heap-reuse N/A (transient values
# + by-value store handle, no wildcard origins).
# =============================================================================

from komira_objectstore.store import CloneableConditionalWriteStore
from komira_objectstore.path import Path
from komira_objectstore.shuffle_codec import get_i64_le
from komira_objectstore.shuffle_seal import StepComplete
from komira_objectstore.shuffle_seal_driver import read_seal


def read_shuffle_partition[
    S: CloneableConditionalWriteStore
](
    store: S,
    shuffle_id: Int64,
    step_id: Int64,
    partition_id: Int64,
    expected_producers: List[Int64],
    max_park_iters: Int = 64,
) raises -> List[UInt8]:
    """SOURCE_SHUFFLE_READ: the SOLE reduce-facing read. Returns the
    concatenated partition-`partition_id` bytes across every producer (in the
    seal's plan order).

    Sequence (all internal — the reduce caller never reads `_entries`):
      1. `read_seal` — block-on-absence (bounded park) until the seal is present
         AND `committed_producers == expected_producers` as sets each-once;
         raises on `committed ⊊ expected` (a missing producer / partial set).
      2. Resolve the LIFTED dense plan for `partition_id`: for each plan row
         (producer), read `(offset, len, row_count)`; DROP zero-length slices.
      3. If ALL slices for the partition are zero-length -> return EMPTY
         immediately (the partition no producer wrote). No
         range request, no block, no error.
      4. `get_range` each NON-ZERO slice from that producer's `.seg` and concat.

    The SOLE-READ-BARRIER: this is the ONLY public read path;
    `read_seal` returns only the verified seal, and there is NO public raw-
    `_entries`-read API. Reverting it (reading `_entries` directly + proceeding
    without the seal-block) re-introduces the silent under-read — the
    seal-blocks-on-absence test catches it.
    """
    if partition_id < Int64(0):
        raise Error(
            "shuffle_source: negative partition_id " + String(partition_id)
        )

    # ---- Step 1: read the seal (block-on-absence + exact-set re-verify). ----
    # A withheld seal -> read_seal parks then RAISES (no under-read). A
    # committed ⊊ expected seal -> read_seal RAISES (no partial aggregate).
    var seal = read_seal(
        store, shuffle_id, step_id, expected_producers, max_park_iters
    )

    var p = Int(partition_id)
    var r = Int(seal.partition_count)
    if p >= r:
        raise Error(
            "shuffle_source: partition_id "
            + String(partition_id)
            + " out of range (R="
            + String(r)
            + ")"
        )

    if not seal.is_lifted():
        # The driver only seals LIFTED (it always lifts the full plan). A
        # TRAILER_FALLBACK seal (capped index) needs a tail-GET of each .seg
        # trailer over the verified set, which is not built. Fail loud rather
        # than under-read.
        raise Error(
            "shuffle_source: TRAILER_FALLBACK read plan not supported"
            " (the consumer would tail-GET each .seg trailer; that path is"
            " not implemented)."
        )

    # ---- Steps 2-4: resolve the dense plan for `p`, drop zero-length, read. ----
    var plan_rows = len(seal.read_plan_producer_ids)
    var out = List[UInt8]()
    for i in range(plan_rows):
        # dense_slot(i, p) = (offset, len, row_count) for plan row i, partition p.
        var slot = seal.dense_slot(i, p)
        var offset = slot[0]
        var length = slot[1]
        if length == Int64(0):
            # Zero-length slice — DROP it. This producer wrote no
            # rows for partition p. No range request (avoids a wasteful/malformed
            # zero-length range request on a real S3 backend; on LocalFs a
            # get_range(.,.,0) is a benign empty read, so this is the
            # discipline/efficiency guard — the load-bearing empty-partition
            # correctness line is the DENSE trailer in shuffle_segment.SegWriter).
            continue
        # Non-zero slice: range-read it from this producer's `.seg`.
        var seg_key = Path.parse(seal.read_plan_object_keys[i])
        var slice_bytes = store.get_range(seg_key, offset, length)
        for b in range(len(slice_bytes)):
            out.append(slice_bytes[b])

    # If every slice was zero-length, `out` is EMPTY — the empty-partition read
    # completes immediately (we never blocked: read_seal returned the present
    # seal, and the loop issued zero range requests).
    return out^


# -----------------------------------------------------------------------------
# decode_partition_payloads — split a concatenated partition body back into its
# per-row payloads (the inverse of shuffle_sink.encode_partition_body). NOT a
# reduce-read API — a test/parity helper that decodes the OPAQUE body
# shape the sink writes. The seal protocol is body-agnostic; this helper knows the
# `[len: i64 LE][payload]` frame so the harness can assert round-trip
# parity (the shuffle is correctness-transparent).
# -----------------------------------------------------------------------------


def decode_partition_payloads(body: List[UInt8]) raises -> List[List[UInt8]]:
    """Decode a concatenated partition body (`[len][payload]` frames) into its
    per-row payloads. Raises on truncation (the `get_i64_le` bounds check)."""
    var out = List[List[UInt8]]()
    var off = 0
    var n = len(body)
    while off < n:
        var plen = Int(get_i64_le(body, off))
        if plen < 0:
            raise Error(
                "shuffle_source: negative payload length " + String(plen)
            )
        var start = off + 8
        if start + plen > n:
            raise Error("shuffle_source: truncated payload at offset " + String(off))
        var payload = List[UInt8]()
        for i in range(plen):
            payload.append(body[start + i])
        out.append(payload^)
        off = start + plen
    return out^
