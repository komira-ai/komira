# =============================================================================
# komira_engine_runtime/spill/shuffle_combine_buffer.mojo
#   `ShuffleCombineBuffer` — the per-partition encode buffer for the
#   distributed-shuffle producer combine (Phase B2).
# =============================================================================
#
# The hot combine buffer must be spillable: stream-combine, not
# concat-in-RAM.
#
# # What this is
#
# During the producer combine (§1.3 step 2 / §2.1), a map task drains its R
# radix sub-tables into ONE shuffle segment, encoding ONE partition slice at a
# time and streaming each into the multipart write boundary:
#
#     for p in 0..R:
#         encode sub-table p into THIS buffer        # append_bytes(...)
#         write_at(buffer.take()) into the segment    # take() the slice
#         buffer.reset()                              # free, move to p+1
#
# `ShuffleCombineBuffer` is the per-partition encode scratch. Its memory
# high-water is BOUNDED to ~one partition-slice encode buffer (NOT the sum of
# all R partitions) because `take()`/`reset()` releases the accumulated bytes
# at the partition boundary — the hot partition streams through the multipart
# window instead of materializing in RAM (§2.1 net: a bounded transient
# regardless of skew).
#
# # The load-bearing safety property (amendment 5 — gap6/bug#60)
#
# This struct is constructed PER MAP TASK, torn down AT STEP END, and
# reconstructed the NEXT STEP — precisely the destroy-recreate lifecycle shape
# the pointer rules ban. A wildcard-
# origin owning field on that struct would let tcmalloc byte-reuse reinterpret
# stale bytes under the new struct's lifetime (the gap6 hazard,
#
# Therefore the owning byte storage is `OwnedPointer[List[UInt8]]` — a
# CONCRETE-ORIGIN owned heap allocation with a stable address (Rust's `Box<T>`,
# the first option in the §2.1 amendment-5 text). `List[UInt8]` is itself the
# compiler-tracked heap owner (the same owner `Slab[T]` wraps internally), so
# the compiler's ASAP-destruction tracking relates the field's lifetime to the
# struct's `__del__`. There is:
#   * NO wildcard-origin field (`MutAnyOrigin`/`ImmutAnyOrigin`/
#     `MutExternalOrigin`),
#   * NO owning `UnsafePointer` field,
#   * NO `unsafe_from_address=Int(...)`,
#   * NO partial-move-via-UnsafePointer.
# Enforced by `scripts/lint_wildcard_field.sh` (this struct is the exact
# target of amendment 5).
#
# Pointer discipline: ZERO UnsafePointer anywhere in this file. The encode
# accumulation uses safe `List[UInt8]` ops (append / extend over a `Span`),
# which is strictly safer than the amendment-5-permitted concrete-origin
# hot-loop pointer and passes every safety lint. (The §2.1 carve-out for an
# internal `# SAFETY:`-annotated concrete-origin UnsafePointer in the encode
# hot loop remains available if a future SIMD encode kernel needs it — it would
# be confined to one method body, never stored as a field, never crossing a
# module boundary.)
#
# # The B4 spill seam (designed, NOT wired here)
#
# §2.1 step 2: a single hot partition that alone exceeds RAM routes through the
# existing operator spill path (`FileSystemSpillStorage.write_chunk` +
# `spill_writer`). This file deliberately does NOT wire spill — B2 ships the
# bounded in-RAM transient + the high-water instrument the B5 gate reads; B4
# adds the `storage.write_chunk(buffer.take())` drain at the partition boundary
# when `high_water()` crosses the multipart skew threshold. The `take()` API is
# exactly the seam: it hands the finalized partition slice out (to the segment
# writer in the common case, or to the spill storage in the hot-partition case)
# and resets for the next partition. No design change to this struct is needed
# for B4.
# =============================================================================

from std.memory import OwnedPointer


struct ShuffleCombineBuffer(Movable, Deinitable):
    """Per-partition encode buffer for the distributed-shuffle producer
    combine. Accumulates the encoded bytes for ONE partition slice at a time,
    with a BOUNDED memory high-water — `take()`/`reset()` releases the slice at
    the partition boundary so peak RAM is ~one partition-slice encode buffer,
    NOT the sum of all R partitions.

    Lifecycle (per map task, per step — the bug#60 destroy-recreate shape):

        var buf = ShuffleCombineBuffer()          # construct (per map task)
        for p in 0..R:
            buf.append_bytes(encode(sub_table_p)) # accumulate partition p
            var slice = buf.take()                # finalize + reset for p+1
            segment.write_at(slice)               # stream into multipart
        # buf dropped at step end; reconstructed next step.

    Movable + Deinitable (it owns heap via the OwnedPointer field
    → NOT trivially Copyable; that is correct — copying a combine buffer would
    be a bug, the buffer is single-owner scratch).

    Fields:
        _bytes:      `OwnedPointer[List[UInt8]]` — the owning byte storage.
                     CONCRETE-ORIGIN owned heap allocation with a stable
                     address (amendment 5, gap6/bug#60-safe). NEVER a
                     wildcard-origin field, NEVER an owning UnsafePointer.
        _high_water: deterministic peak number of resident accumulated bytes
                     observed since construction (the B5 gate reads this via
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
    # OwnedPointer's drop runs the List's drop which frees the buffer. This is
    # the amendment-5 concrete-origin field — NOT a wildcard-origin pointer,
    # NOT an owning UnsafePointer. ASAP-destruction tracking relates this
    # field's lifetime to the struct's destructor (the gap6/bug#60-safe shape).
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

        Pre-reserving the typical partition-slice encode size avoids per-append
        re-allocations on the combine hot path. `capacity <= 0` is treated as
        no pre-reservation.

        Args:
            capacity: Number of bytes to pre-reserve in the backing buffer.
        """
        var b = List[UInt8]()
        if capacity > 0:
            b.reserve(capacity)
        self._bytes = OwnedPointer(b^)
        self._high_water = 0

    # `__del__` is auto-synthesized: the OwnedPointer's drop runs the
    # List[UInt8]'s drop which frees the heap buffer. No hand-written
    # destructor (and no wildcard pointer to manually free) — that is the
    # gap6/bug#60-safe shape.

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
            data: The encoded bytes to accumulate (e.g. one THSPLC/THSPILL2
                  sub-table chunk).
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
    # Inspect — the instrumented counters the B5 gate reads
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
        """Deterministic peak number of resident accumulated bytes observed
        since construction (the B5 bounded-RAM gate reads this).

        This is the high-WATER mark: a monotonic peak that does NOT reset on
        `take()`/`reset()`. Because the LIVE byte count (`len()`) drops to 0 at
        each partition boundary, the peak stays bounded to ~one
        partition-slice encode buffer as long as the caller drains per
        partition — that is the §2.1 bounded-transient property the B5 gate
        asserts (peak ≈ one sub-table, NOT the sum of all R partitions).

        CAVEAT (B5 gate must account for this): `high_water` observes ONLY THIS
        buffer's live accumulated bytes. It does NOT include the downstream
        FileSystem-side transients of the B3 stream-combine — the S3 conformer's
        `_coalesce` copy (bounded to ~one part by the chunked write) or the
        K-deep × part in-flight PUT window. The true process peak during a
        stream-combine is `high_water` + ~(1 + K)×part, so the B5 bounded-RAM
        gate must measure real RSS or add those FS-side terms rather than read
        the peak off `high_water()` alone."""
        return self._high_water

    @always_inline
    def is_empty(self) -> Bool:
        """True iff no bytes are currently accumulated in the live slice."""
        return len(self._bytes[]) == 0

    # =========================================================================
    # Finalize / reset — the per-partition lifecycle (and the B4 spill seam)
    # =========================================================================

    def take(mut self) -> List[UInt8]:
        """Finalize the current partition slice: return the accumulated bytes
        and reset the buffer to empty for the NEXT partition.

        This is the per-partition boundary and the B4 spill seam: the returned
        `List[UInt8]` is handed to the segment writer's `write_at` (common
        case) or to `FileSystemSpillStorage.write_chunk` (hot-partition case).
        The buffer's live byte count drops back to 0 — releasing the slice's
        RAM — so the high-water stays bounded to one partition slice.

        The high-water mark is PRESERVED across `take()` (it is the monotonic
        peak, not the live count).

        Returns:
            The accumulated bytes of the finalized partition slice (owned;
            the caller takes ownership). The internal buffer is left empty.
        """
        # Swap the owned List out behind a fresh empty one — leaves `self` in a
        # valid empty state (the canonical OwnedPointer swap-and-take idiom,
        # the sanctioned replacement for a partial move, mirrors
        # `WhenBuilder.otherwise`'s `self._cases^` swap). NO partial-move via
        # UnsafePointer.
        var fresh = OwnedPointer(List[UInt8]())
        var owned = self._bytes^
        self._bytes = fresh^
        return owned^.into_inner()

    def reset(mut self):
        """Reset the live partition slice to empty WITHOUT returning the bytes
        (drops the accumulated bytes). Use after a `take()` that handed the
        slice elsewhere, or to discard a partially-encoded slice on error.

        The high-water mark is PRESERVED (monotonic peak). The backing
        allocation's capacity is RELEASED (a fresh empty List) so the live
        byte count drops to 0 and peak RAM stays bounded — symmetric with
        `take()`.
        """
        var fresh = OwnedPointer(List[UInt8]())
        self._bytes = fresh^

    def clear_retaining_capacity(mut self):
        """Reset the live slice to empty but RETAIN the backing buffer's
        capacity (avoids a re-alloc when the next partition is a similar
        size). The high-water mark is preserved.

        This is an optimization variant of `reset()` for the common case where
        the caller drains per partition into a same-process segment writer (no
        spill) and wants to reuse the allocation. The live byte count still
        drops to 0, so peak RAM is unchanged — `clear()` frees no pages but the
        high-water already captured the peak.
        """
        self._bytes[].clear()

    def reset_high_water(mut self):
        """Reset the high-water mark to the current live byte count. For test
        / instrumentation use (re-baseline the peak between measurement
        windows). NOT used on the production combine path."""
        self._high_water = len(self._bytes[])
