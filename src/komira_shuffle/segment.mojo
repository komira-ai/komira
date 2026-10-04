# =============================================================================
# komira_shuffle/segment.mojo
#   The `.seg` dense-index trailer codec + a minimal SegWriter / SegReader
#   for the distributed shuffle.
# =============================================================================
#
# The `{producer_id}.seg` layout: R partition bodies concatenated + a DENSE
# index trailer of EXACTLY R entries incl. zero-length + a footer.
#
# This is NOT a streamed-multipart stream-combine (that would use an
# OwnedPointer/Slab concrete-origin combine buffer). It is the smallest
# possible shape: build R partition bodies concatenated in ONE
# `List[UInt8]`, append the dense trailer, append the footer, ONE `put`. The
# SegReader locates the trailer from the object tail and returns a partition's
# bytes via `get_range`.
#
# `.seg` object layout:
#   [ partition_0 bytes ]                     <- MAY be zero-length
#   [ partition_1 bytes ]
#   ...
#   [ partition_{R-1} bytes ]
#   [ DENSE TRAILER: EXACTLY R × ( offset: i64 LE, len: i64 LE, row_count: i64 LE ) ]
#   [ FOOTER: ( magic: i64 LE, partition_count R: i64 LE ) ]
#
# The footer is a FIXED 16 bytes at the very tail; the trailer is the 24*R bytes
# immediately before it. A reader tail-GETs the 16-byte footer (or the whole
# object, today) to learn R, then reads the trailer, then range-reads a
# partition's slice.
#
# DENSE-INDEX INVARIANT: a partition this producer wrote no rows for
# STILL gets a dense trailer entry `(running_offset, len=0, row_count=0)` with
# the running offset UNCHANGED. The trailer always has EXACTLY R entries — never
# sparse. This is what lets an empty-partition reducer read zero bytes without
# blocking or erroring.
#
# Pointer discipline: ZERO UnsafePointer. Bytes flow as owned `List[UInt8]`;
# the store is held by value (`S: ConditionalWriteStore`). heap-reuse N/A
# (transient values + a by-value store handle, no wildcard origins).
# =============================================================================

from komira_objectstore.path import Path
from komira_objectstore.store import ConditionalWriteStore
from komira_shuffle.codec import put_i64_le, get_i64_le
from komira_shuffle.entry import PartitionSlot


# Footer magic distinguishing a `.seg` tail from arbitrary bytes.
comptime _SEG_MAGIC: Int64 = Int64(0x5348_5546_5345_4720)  # "SHUFSEG "
comptime _FOOTER_LEN: Int = 16  # (magic i64, partition_count i64)
comptime _TRAILER_ENTRY_LEN: Int = 24  # (offset i64, len i64, row_count i64)


def encode_seg_trailer(slots: List[PartitionSlot]) -> List[UInt8]:
    """Encode the dense trailer (EXACTLY len(slots) entries) + the footer.

    The caller guarantees `slots` has exactly R entries (dense, incl.
    zero-length) — this does NOT re-check density (the SegWriter builds it
    densely by construction). Returns the trailer+footer bytes to append after
    the concatenated partition bodies."""
    var out = List[UInt8]()
    for i in range(len(slots)):
        ref s = slots[i]
        put_i64_le(out, s.offset)
        put_i64_le(out, s.length)
        put_i64_le(out, s.row_count)
    # footer
    put_i64_le(out, _SEG_MAGIC)
    put_i64_le(out, Int64(len(slots)))
    return out^


def decode_seg_footer(tail: List[UInt8]) raises -> Int64:
    """Decode the partition_count R from the last 16 bytes of a `.seg` object.
    `tail` must be AT LEAST the trailing footer (16 bytes). Raises on a bad
    magic (not a `.seg` object / truncated)."""
    var n = len(tail)
    if n < _FOOTER_LEN:
        raise Error("shuffle_segment: object too small for footer")
    var magic = get_i64_le(tail, n - _FOOTER_LEN)
    if magic != _SEG_MAGIC:
        raise Error("shuffle_segment: bad .seg footer magic")
    return get_i64_le(tail, n - 8)


def decode_seg_trailer(seg_bytes: List[UInt8]) raises -> List[PartitionSlot]:
    """Decode the dense trailer (R entries) from a FULL `.seg` object's bytes.
    The trailer is the 24*R bytes immediately before the 16-byte footer. Raises
    on truncation / bad footer."""
    var r = Int(decode_seg_footer(seg_bytes))
    if r < 0:
        raise Error("shuffle_segment: negative partition_count")
    var n = len(seg_bytes)
    var trailer_start = n - _FOOTER_LEN - r * _TRAILER_ENTRY_LEN
    if trailer_start < 0:
        raise Error("shuffle_segment: object too small for dense trailer")
    var slots = List[PartitionSlot]()
    var off = trailer_start
    for _i in range(r):
        var s_off = get_i64_le(seg_bytes, off)
        var s_len = get_i64_le(seg_bytes, off + 8)
        var s_rc = get_i64_le(seg_bytes, off + 16)
        slots.append(PartitionSlot(s_off, s_len, s_rc))
        off += _TRAILER_ENTRY_LEN
    return slots^


struct SegWriter(Movable, Deinitable):
    """The `.seg` builder: accumulate R partition bodies concatenated in one
    buffer (dense, incl. zero-length), then `finish` to append the dense trailer
    + footer and produce the object bytes.

    NOT a stream-combine (no multipart, no spill, RAM = full object), so it
    suits small objects.

    Field layout:
      var _body: List[UInt8]            — concatenated partition bodies + (on
                                          finish) trailer + footer.
      var _slots: List[PartitionSlot]    — the dense index built as partitions
                                          are appended.
      var _running_offset: Int64         — next partition's offset.
    """

    var _body: List[UInt8]
    var _slots: List[PartitionSlot]
    var _running_offset: Int64

    def __init__(out self):
        self._body = List[UInt8]()
        self._slots = List[PartitionSlot]()
        self._running_offset = Int64(0)

    def append_partition(mut self, bytes: List[UInt8], row_count: Int64):
        """Append partition `len(self._slots)`'s bytes + record its dense slot.

        A zero-length `bytes` (an empty partition this producer wrote no rows
        for) records a dense slot `(running_offset, 0, 0)` with the running
        offset UNCHANGED — the DENSE-INDEX INVARIANT. Call this
        EXACTLY R times in partition order (0..R-1) so the trailer is dense."""
        self._slots.append(
            PartitionSlot(self._running_offset, Int64(len(bytes)), row_count)
        )
        for i in range(len(bytes)):
            self._body.append(bytes[i])
        self._running_offset += Int64(len(bytes))

    @always_inline
    def partition_count(self) -> Int:
        return len(self._slots)

    def slots_copy(self) -> List[PartitionSlot]:
        """A copy of the dense index (the producer records this in its
        `_entries` ShuffleEntry after the body is durable)."""
        return self._slots.copy()

    def finish(deinit self) -> List[UInt8]:
        """Consume the writer, append the dense trailer + footer, and return the
        complete `.seg` object bytes (ready for ONE `put`)."""
        var trailer = encode_seg_trailer(self._slots)
        # `deinit self` deconstructs the writer: move the body OUT, append the
        # trailer to it, return it (the canonical reclaim-a-field idiom, mirrors
        # migration.into_db `deinit self -> return self._db^`).
        var body = self._body^
        for i in range(len(trailer)):
            body.append(trailer[i])
        return body^


def write_segment[
    S: ConditionalWriteStore
](
    mut store: S, key: Path, var writer: SegWriter
) raises -> List[PartitionSlot]:
    """Finish `writer`, `put` the `.seg` object at `key`, and return the dense
    index slots (the producer threads these into its `_entries` ShuffleEntry).
    ONE unconditional `put` — the `.seg` bodies are plain disjoint-key PUTs, no
    CAS."""
    var slots = writer.slots_copy()
    var obj = writer^.finish()
    _ = store.put(key, obj^)
    return slots^


struct SegReader[S: ConditionalWriteStore](Movable, Deinitable):
    """The `.seg` reader: locate the dense trailer from the object tail and
    return a partition's bytes via `get_range`.

    Holds the backend store by value (a clone-shared handle is the idiom — see
    LocalFsConditionalStore.clone). heap-reuse N/A (by-value store, no wildcard
    origins).

    Field layout:
      var _store: S      — the backend.
      var _key: Path     — the `.seg` object key.
    """

    var _store: Self.S
    var _key: Path

    def __init__(out self, var store: Self.S, var key: Path):
        self._store = store^
        self._key = key^

    def read_dense_index(self) raises -> List[PartitionSlot]:
        """Read the dense trailer (EXACTLY R entries). This reads the whole
        object (small objects); a large-object reader tail-GETs the footer then the
        trailer. Raises on a bad/absent `.seg`."""
        var whole = self._store.get(self._key)
        return decode_seg_trailer(whole)

    def read_partition(self, partition: Int) raises -> List[UInt8]:
        """Range-read partition `partition`'s slice. Returns EMPTY for a
        zero-length (empty) partition WITHOUT a range request — the empty-slice
        read is zero bytes by construction (step 3: drop zero-length
        slices). Raises if `partition` is out of `[0, R)`."""
        var slots = self.read_dense_index()
        if partition < 0 or partition >= len(slots):
            raise Error(
                "shuffle_segment: partition "
                + String(partition)
                + " out of range (R="
                + String(len(slots))
                + ")"
            )
        ref s = slots[partition]
        if s.length == Int64(0):
            # EMPTY partition — zero bytes, no range request, never blocks/errors.
            return List[UInt8]()
        return self._store.get_range(self._key, s.offset, s.length)
