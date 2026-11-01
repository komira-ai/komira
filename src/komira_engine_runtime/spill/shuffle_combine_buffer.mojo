# =============================================================================
# shuffle_combine_buffer: `ShuffleCombineBuffer`, the per-partition encode
# buffer of the shuffle producer combine.
# =============================================================================
#
# A map task drains its R radix sub-tables into one shuffle segment, encoding
# one partition slice at a time and streaming each into the segment writer:
#
#     for p in 0..R:
#         encode sub-table p into this buffer        # append_bytes(...)
#         write the slice into the segment           # take()
#
# `take()` hands the slice out and resets the buffer, so the resident bytes
# stay bounded by the largest single partition slice, not the sum of all R.
# `high_water()` reports that length peak (allocation capacity can be up to
# about 2x it); a caller can compare it against a spill threshold to route a
# slice that alone is too large to spill storage instead (that routing is not
# in this module).
#
# The buffer is built per map task, dropped at step end and rebuilt the next
# step. Its storage is an `OwnedPointer[List[UInt8]]`: a concrete-origin owned
# allocation whose destruction the compiler ties to the struct's. There is no
# `UnsafePointer` in this file and no wildcard origin; appends go through
# `List[UInt8]` operations.
# =============================================================================

from std.memory import OwnedPointer


struct ShuffleCombineBuffer(Movable, Deinitable):
    """Per-partition encode buffer for the distributed-shuffle producer
    combine. Accumulates the encoded bytes for ONE partition slice at a time,
    with a bounded memory high-water: `take()`/`reset()` releases the slice at
    the partition boundary, so peak RAM is about one partition-slice encode
    buffer, not the sum of all R partitions.

    Lifecycle (per map task, per step):

        var buf = ShuffleCombineBuffer()          # construct (per map task)
        for p in 0..R:
            buf.append_bytes(encode(sub_table_p)) # accumulate partition p
            var slice = buf.take()                # finalize + reset for p+1
            segment.write_at(slice)               # stream into multipart
        # buf dropped at step end; reconstructed next step.

    Movable + Deinitable; it owns heap through the OwnedPointer field, so it is
    not Copyable (the buffer is single-owner scratch).

    Fields:
        _bytes:      `OwnedPointer[List[UInt8]]`, the owning byte storage: a
                     concrete-origin owned heap allocation with a stable
                     address.
        _high_water: deterministic peak number of resident accumulated bytes
                     observed since construction (a bounded-RAM check reads this via
                     `high_water()`). Records the MAX single-partition-slice
                     size ever held — it does NOT reset on `take()`/`reset()`
                     (it is the high-WATER mark, a monotonic peak), but the
                     LIVE byte count (`len()`) does drop back to 0 on
                     `take()`/`reset()`, so the peak stays bounded to one
                     partition slice as long as the caller drains per
                     partition.
    """

    # SAFETY: `OwnedPointer[List[UInt8]]` holds the heap allocation behind a
    # stable address. `List[UInt8]` is the compiler-tracked heap owner; the
    # OwnedPointer's drop runs the List's drop which frees the buffer. The
    # field's lifetime is tied to the struct's destructor.
    var _bytes: OwnedPointer[List[UInt8]]
    var _high_water: Int

    # =========================================================================
    # Construction / destruction
    # =========================================================================

    def __init__(out self):
        """Construct an empty combine buffer (no pre-reservation)."""
        self._bytes = OwnedPointer(List[UInt8]())
        self._high_water = 0

    def __init__(out self, capacity: Int):
        """Construct an empty combine buffer with `capacity` bytes reserved.

        Reserves `capacity` bytes for the first slice. `take()` then reserves
        the size of the slice it hands out for the next one. `capacity <= 0`
        means no pre-reservation.

        Args:
            capacity: Number of bytes to pre-reserve in the backing buffer.
        """
        var b = List[UInt8]()
        if capacity > 0:
            b.reserve(capacity)
        self._bytes = OwnedPointer(b^)
        self._high_water = 0

    # `__del__` is auto-synthesized: the OwnedPointer's drop runs the
    # List[UInt8]'s drop which frees the heap buffer.

    # =========================================================================
    # Accumulate — the per-partition encode hot path
    # =========================================================================

    def append_bytes(mut self, data: Span[UInt8, _]):
        """Append `data` to the current partition slice and update the
        high-water mark.

        This is the per-partition encode accumulation: the caller encodes a
        radix sub-table to bytes and feeds them here, then `take()`s the
        finalized slice. Uses safe `List` extend over the span (no
        UnsafePointer).

        Args:
            data: The encoded bytes to accumulate (e.g. one encoded sub-table
                  chunk).
        """
        self._bytes[].extend(data)
        var live = len(self._bytes[])
        if live > self._high_water:
            self._high_water = live

    def append_byte(mut self, b: UInt8):
        """Append a single byte (framing convenience; same high-water
        accounting as `append_bytes`)."""
        self._bytes[].append(b)
        var live = len(self._bytes[])
        if live > self._high_water:
            self._high_water = live

    # =========================================================================
    # Inspect — the instrumented counters a bounded-RAM check reads
    # =========================================================================

    @always_inline
    def len(self) -> Int:
        """Number of bytes currently accumulated in the live partition slice.
        Drops back to 0 after `take()` / `reset()`."""
        return len(self._bytes[])

    @always_inline
    def __len__(self) -> Int:
        """`Sized` shape — same as `len()`."""
        return len(self._bytes[])

    @always_inline
    def high_water(self) -> Int:
        """Peak number of accumulated bytes (the maximum `len()`) observed
        since construction.

        This is a monotonic peak that does not reset on `take()`/`reset()`.
        Because the live byte count (`len()`) drops to 0 at each partition
        boundary, the peak stays at about one partition slice as long as the
        caller drains per partition.

        It is a length peak, not a capacity peak: `List` growth can leave the
        allocation up to about 2x the bytes held, so resident memory can reach
        about twice this value. It also counts only this buffer's bytes, not
        downstream writer transients (copies or in-flight upload parts), so a
        caller comparing it with a spill threshold must allow for both."""
        return self._high_water

    @always_inline
    def capacity(self) -> Int:
        """Bytes the live slice's backing allocation can hold without
        growing."""
        return self._bytes[].capacity()

    @always_inline
    def is_empty(self) -> Bool:
        """True iff no bytes are currently accumulated in the live slice."""
        return len(self._bytes[]) == 0

    # =========================================================================
    # Finalize / reset — the per-partition lifecycle (and the spill seam)
    # =========================================================================

    def take(mut self) -> List[UInt8]:
        """Finalize the current partition slice: return the accumulated bytes
        and reset the buffer to empty for the NEXT partition.

        This is the per-partition boundary and the spill seam: the caller
        decides whether the returned `List[UInt8]` goes to the segment writer
        or to spill storage. The buffer's live byte count drops back to 0, so
        the high-water stays bounded to one partition slice. The fresh list
        reserves the handed-out slice's length, so a loop over similar-sized
        partitions does not regrow it from empty each time.

        The high-water mark is PRESERVED across `take()` (it is the monotonic
        peak, not the live count).

        Returns:
            The accumulated bytes of the finalized partition slice (owned;
            the caller takes ownership). The internal buffer is left empty.
        """
        # Swap the owned List out behind a fresh one, leaving `self` valid
        # and empty. No partial move through a pointer.
        var out_len = len(self._bytes[])
        var next = List[UInt8]()
        if out_len > 0:
            next.reserve(out_len)
        var fresh = OwnedPointer(next^)
        var owned = self._bytes^
        self._bytes = fresh^
        return owned^.into_inner()

    def reset(mut self):
        """Reset the live partition slice to empty WITHOUT returning the bytes
        (drops the accumulated bytes). Use after a `take()` that handed the
        slice elsewhere, or to discard a partially-encoded slice on error.

        The high-water mark is preserved. The backing allocation is released
        (a fresh empty List) and the live byte count drops to 0.
        """
        var fresh = OwnedPointer(List[UInt8]())
        self._bytes = fresh^

    def clear_retaining_capacity(mut self):
        """Reset the live slice to empty but RETAIN the backing buffer's
        capacity (avoids a re-alloc when the next partition is a similar
        size). The high-water mark is preserved.

        Unlike `reset()`, the allocation stays resident; the live byte count
        drops to 0.
        """
        self._bytes[].clear()

    def reset_high_water(mut self):
        """Reset the high-water mark to the current live byte count. For test
        / instrumentation use (re-baseline the peak between measurement
        windows). NOT used on the production combine path."""
        self._high_water = len(self._bytes[])
