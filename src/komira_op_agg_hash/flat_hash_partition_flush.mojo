# =============================================================================
# FlatHashPartitionFlush -- byte buffer for one radix partition
# =============================================================================
#
# PERF-CRITICAL: the per-partition row buffer of the abandon cycle. When a
# worker's FlatHashAggregator reaches its L2-resident cap, every live entry
# is scattered into one of `num_partitions` FlatHashPartitionFlush buffers
# keyed by `(mixed_hash >> shift) & (num_partitions - 1)`. The table is then
# `clear_for_reuse()`d and probing resumes in L2.
#
# Key invariants
# --------------
# 1. Movable-only, so a List cannot hold it (List requires Copyable): a
#    worker's buffers live in a `komira_collections.Slab`, one run of
#    `num_partitions` buffers per worker.
# 2. Every row is exactly `entry_stride` bytes, byte-identical to the source
#    FlatHashAggregator's entry. The combine step copies rows into fresh
#    aggregator entries; a stride mismatch silently corrupts keys or
#    accumulator state.
# 3. Every pointer `_scatter_flush` reads carries the origin of the
#    aggregator buffer it came from.
# =============================================================================

from std.memory import unsafe_memcpy, UnsafePointer

from komira_collections.slab import Slab


# Initial row capacity of a partition buffer's first allocation. Growth
# doubles from here; a skewed partition pays proportionally.
comptime _INITIAL_ROW_CAPACITY: Int = 256


struct FlatHashPartitionFlush(Movable):
    """Row-bytes buffer for a single radix partition.

    Appends rows (each exactly `entry_stride` bytes) copied from a
    FlatHashAggregator entry. Doubles capacity on full.

    Fields:
        row_data: Byte buffer holding `num_groups * entry_stride` bytes
            of live data out of `row_capacity * entry_stride` bytes allocated.
        row_capacity: Capacity in rows (NOT bytes).
        num_groups: Number of rows currently stored.
        entry_stride: Bytes per row; MUST equal the aggregator's entry stride.
    """

    var row_data: List[UInt8]
    var row_capacity: Int
    var num_groups: Int
    var entry_stride: Int

    @staticmethod
    def new(entry_stride: Int) -> FlatHashPartitionFlush:
        """Construct an EMPTY partition buffer (row_capacity=0, row_data empty).

        The first allocation is deferred to `reserve()`, so it happens on the
        worker thread that owns the buffer and performs every later growth:
        a buffer allocated on one thread and grown (freed) on another
        corrupts a per-thread allocator's freelist.
        """
        return FlatHashPartitionFlush(List[UInt8](), 0, 0, entry_stride)

    def __init__(
        out self,
        var row_data: List[UInt8],
        row_capacity: Int,
        num_groups: Int,
        entry_stride: Int,
    ):
        self.row_data = row_data^
        self.row_capacity = row_capacity
        self.num_groups = num_groups
        self.entry_stride = entry_stride

    # -------------------------------------------------------------------------
    # Mutation
    # -------------------------------------------------------------------------

    def reserve(mut self, additional_rows: Int):
        """Ensure space for `num_groups + additional_rows`.

        Doubles capacity on full. When a larger-than-double add is
        requested, doubles until the request fits.
        """
        var need = self.num_groups + additional_rows
        if need <= self.row_capacity:
            return

        var new_cap = self.row_capacity
        if new_cap < 1:
            new_cap = _INITIAL_ROW_CAPACITY
        while new_cap < need:
            new_cap *= 2

        var new_bytes = new_cap * self.entry_stride
        var new_buf = List[UInt8](capacity=new_bytes)
        new_buf.resize(unsafe_uninit_length=new_bytes)
        if self.num_groups > 0:
            unsafe_memcpy(
                dest=new_buf.unsafe_ptr(),
                src=self.row_data.unsafe_ptr(),
                count=self.num_groups * self.entry_stride,
            )
        self.row_data = new_buf^
        self.row_capacity = new_cap

    # PERF-CRITICAL: per-row append inside the flush scatter loop; inlined
    # so the `memcpy(entry_stride)` folds into the caller.
    @always_inline
    def _append_row[
        o_src: Origin
    ](mut self, src: UnsafePointer[UInt8, o_src]):
        """Copy exactly `entry_stride` bytes from `src` into the buffer.

        The caller has already called `reserve()` with enough capacity, and
        `src` points at a whole entry of the source aggregator.
        """
        var dest = self.row_data.unsafe_ptr() + self.num_groups * self.entry_stride
        unsafe_memcpy(dest=dest, src=src, count=self.entry_stride)
        self.num_groups += 1

    def row(ref self, i: Int) -> Span[UInt8, origin_of(self.row_data)]:
        """The bytes of stored row `i` (`entry_stride` of them), for
        `FlatHashAggregator.merge_flushed_row`."""
        debug_assert(
            i >= 0 and i < self.num_groups,
            "FlatHashPartitionFlush.row: index out of range",
        )
        return Span[UInt8, origin_of(self.row_data)](
            unsafe_ptr=self.row_data.unsafe_ptr() + i * self.entry_stride,
            length=self.entry_stride,
        )


# =============================================================================
# Scatter body of FlatHashAggregator.flush_to_partitions
# =============================================================================
#
# Three phases over the aggregator's buffers:
#   1. walk the live tags, compute each partition index, count per partition;
#   2. reserve on each destination partition;
#   3. walk the live tags again and copy each entry row into its partition.
#
# The partition index comes from the mixed hash, read from `_tags[slot]`
# (the same value as the entry's hash header, at a compact 8 B stride). Do
# NOT re-hash from the key: the combine step re-probes with the stored hash.
#
# SAFETY: `tags` and `slot_to_idx` point at `capacity` elements of the
# calling aggregator's buffers and `entries` at its entry buffer, each with
# that buffer's origin; the aggregator is borrowed for the call. Entry
# `slot_to_idx[slot]` lives at `entries + idx * entry_stride`.
def _scatter_flush[
    o_tags: Origin,
    o_idx: Origin,
    o_entries: Origin,
](
    tags: UnsafePointer[UInt64, o_tags],
    slot_to_idx: UnsafePointer[Int32, o_idx],
    entries: UnsafePointer[UInt8, o_entries],
    capacity: Int,
    entry_stride: Int,
    mut flushes: Slab[FlatHashPartitionFlush],
    first: Int,
    num_partitions: Int,
    shift: UInt32,
) raises:
    """Scatter every live entry into `flushes[first .. first + num_partitions]`.

    No-op when the table is empty.

    Args:
        tags: The aggregator's `_tags` array (`capacity` UInt64s, 0 = empty).
        slot_to_idx: The aggregator's `_slot_to_idx` array (`capacity`
            Int32s, -1 = empty). Indexed by slot.
        entries: The aggregator's flat `_entries` buffer.
        capacity: Number of slots in the table.
        entry_stride: Bytes per entry; MUST equal the flush buffers' stride.
        flushes: The slab holding this worker's partition buffers.
        first: Index in `flushes` of this worker's partition 0.
        num_partitions: Number of partitions (a power of 2, at most 256).
        shift: Bits to shift the mixed hash right before masking to the
            partition index: `64 - log2(num_partitions)`, i.e. 56 for 256.
    """
    var mask = UInt64(num_partitions - 1)
    var shift64 = UInt64(shift)

    # CORRECTNESS: `h != 0` identifies live entries. The mixers
    # (_fib_hash_1 / _fib_hash_2 / _fib_hash_n) clamp `if h == 0: h = 1`
    # before storing, so a live entry never carries a zero tag, and empty
    # slots carry tag 0 by construction (clear_for_reuse zeroes _tags).
    #
    # PERF-CRITICAL: `counts` is a stack array (1 KB at 256 partitions), so
    # an abandon cycle allocates nothing for it.
    if num_partitions > 256:
        raise Error(
            "flush_to_partitions: num_partitions=" + String(num_partitions)
            + " exceeds the stack-buffered maximum of 256"
        )
    if first < 0 or first + num_partitions > len(flushes):
        raise Error(
            "flush_to_partitions: partitions " + String(first) + ".."
            + String(first + num_partitions) + " exceed the slab's "
            + String(len(flushes)) + " buffers"
        )
    var counts = Array[UInt32, 256](uninitialized=True)
    for p in range(num_partitions):
        counts[p] = UInt32(0)

    # Phase 1: count groups per partition.
    for slot in range(capacity):
        var h = (tags + slot)[]
        if h != UInt64(0):
            var p = Int((h >> shift64) & mask)
            counts[p] += UInt32(1)

    # Phase 2: reserve on destinations that will see data.
    for p in range(num_partitions):
        var c = Int(counts[p])
        if c > 0:
            flushes[first + p].reserve(c)

    # Phase 3: scatter.
    # PERF-CRITICAL: inner loop of the flush; each iteration is a tag load,
    # shift/mask, one entry-index load and a memcpy(entry_stride).
    for slot in range(capacity):
        var h = (tags + slot)[]
        if h != UInt64(0):
            var p = Int((h >> shift64) & mask)
            var entry_idx = Int((slot_to_idx + slot)[])
            var src = entries + entry_idx * entry_stride
            flushes[first + p]._append_row(src)
