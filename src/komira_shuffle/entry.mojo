# =============================================================================
# komira_shuffle/entry.mojo
#   The `_entries` chunk-body codec for the distributed-shuffle SEAL.
# =============================================================================
#
# The producer's `_entries` append, and the seal's committed-producer-set
# dedup source.
#
# A `ShuffleEntry` is the body a map producer appends to the `_entries`
# `CasManifestStore` manifest AFTER its `{producer_id}.seg` body is durable. It
# records:
#   * `producer_id`   — the DedupSentinel identity component (`(producer_id,
#                       first_seq)`); the seal verifies the SET of distinct
# producer_ids each-once.
#   * `object_key`    — the `{producer_id}.seg` object key the reducer reads.
#   * dense R×(offset, len, row_count) — the per-partition index, EXACTLY R
#                       entries (one per partition 0..R-1, INCLUDING zero-length
#                       entries for partitions this producer wrote no rows for —
#                       the DENSE-INDEX INVARIANT).
#
# The producer-set dedup is body-aware, with its own codec — NOT broker-trailer
# reuse: the driver builds `committed_producers` by scanning
# `_entries` chunks and decoding `producer_id` from THIS shuffle-defined codec.
# The broker's `_body_matches_producer_batch` / `ManifestBody` trailer is NOT
# reused — the shuffle entry is its own shape (it carries the dense per-partition
# read plan the broker entry has no notion of). Dedup is set-insertion over
# decoded producer_ids, then set-equality `committed == expected`.
#
# Wire format (all integers little-endian, mirroring cas_manifest's body codec):
#   [ producer_id     : Int64 LE ]
#   [ partition_count : Int64 LE ]   = R (the dense-index length)
#   [ key_len         : Int64 LE ]
#   [ key bytes       : key_len UTF-8 ]
#   [ R × ( offset: Int64 LE, len: Int64 LE, row_count: Int64 LE ) ]
#
# Pointer discipline: ZERO UnsafePointer. The struct is a transient value
# (Copyable/Movable POD-with-owned-List/String) — never a byte-slab element,
# never a long-lived or wildcard-origin field, so heap-reuse is N/A.
# =============================================================================

from komira_shuffle.codec import (
    put_i64_le,
    get_i64_le,
    put_len_prefixed_str,
    get_len_prefixed_str,
)


@fieldwise_init
struct PartitionSlot(Copyable, Movable, Deinitable):
    """One dense per-partition index entry: `(offset, len, row_count)`.

    A partition this producer wrote no rows for STILL gets a dense slot with
    `len == 0` and `row_count == 0` (the running offset unchanged) — the
    DENSE-INDEX INVARIANT. POD (3 i64), never heap-owning.

    Field layout:
      var offset: Int64     — byte offset of this partition's slice in `.seg`.
      var length: Int64     — byte length of the slice (0 = empty partition).
      var row_count: Int64  — rows in the slice (0 = empty partition).
    """

    var offset: Int64
    var length: Int64
    var row_count: Int64

    @staticmethod
    @always_inline
    def empty(offset: Int64) -> PartitionSlot:
        """A dense zero-length entry at `offset` (running offset unchanged)."""
        return PartitionSlot(offset, Int64(0), Int64(0))


@fieldwise_init
struct ShuffleEntry(Copyable, Movable, Deinitable):
    """The `_entries` chunk body — one per map producer.

    Transient value: the producer encodes it once after its `.seg` body is
    durable, appends it to the `_entries` manifest; the driver decodes it at the
    join to build `committed_producers`. NOT a byte-slab element (heap-reuse N/A).

    Field layout:
      var producer_id: Int64           — the DedupSentinel identity component.
      var object_key: String           — the `{producer_id}.seg` key.
      var slots: List[PartitionSlot] — EXACTLY R dense entries.
    """

    var producer_id: Int64
    var object_key: String
    var slots: List[PartitionSlot]

    @always_inline
    def partition_count(self) -> Int:
        return len(self.slots)


def encode_shuffle_entry(entry: ShuffleEntry) -> List[UInt8]:
    """Encode a `ShuffleEntry` to the `_entries` chunk-body wire format."""
    var out = List[UInt8]()
    put_i64_le(out, entry.producer_id)
    put_i64_le(out, Int64(len(entry.slots)))  # R = partition_count
    put_len_prefixed_str(out, entry.object_key)
    for i in range(len(entry.slots)):
        ref s = entry.slots[i]
        put_i64_le(out, s.offset)
        put_i64_le(out, s.length)
        put_i64_le(out, s.row_count)
    return out^


def decode_shuffle_entry(bytes: List[UInt8]) raises -> ShuffleEntry:
    """Decode a `ShuffleEntry` from the `_entries` chunk-body wire format.

    Raises on a truncated body (the `get_i64_le` / `get_len_prefixed_str`
    bounds checks fire). The dense-index length (R entries) is taken from the
    encoded `partition_count` header — the decode reads EXACTLY R slots.
    """
    var producer_id = get_i64_le(bytes, 0)
    var r = Int(get_i64_le(bytes, 8))
    if r < 0:
        raise Error("shuffle_entry: negative partition_count " + String(r))
    var off = 16
    var key_pair = get_len_prefixed_str(bytes, off)
    var object_key = key_pair[0].copy()
    off = key_pair[1]
    var slots = List[PartitionSlot]()
    for _i in range(r):
        var slot_off = get_i64_le(bytes, off)
        var slot_len = get_i64_le(bytes, off + 8)
        var slot_rc = get_i64_le(bytes, off + 16)
        slots.append(PartitionSlot(slot_off, slot_len, slot_rc))
        off += 24
    return ShuffleEntry(producer_id, object_key^, slots^)


def decode_shuffle_entry_producer_id(bytes: List[UInt8]) raises -> Int64:
    """Decode ONLY the producer_id from an `_entries` body — the dedup-source
    fast path the driver-join uses to build `committed_producers`.

    Reads just the leading i64; does not materialize the dense index. The full
    `decode_shuffle_entry` is used where the read plan is also needed.
    """
    return get_i64_le(bytes, 0)
