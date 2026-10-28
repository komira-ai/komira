# =============================================================================
# BITMAP — Arrow validity bitmap
# =============================================================================
#
# Arrow uses a null bitmap to track which elements in an array are valid (not
# null). The bitmap is LSB-first within each byte:
#   Convention: 1 = valid, 0 = null.
# =============================================================================

from std.memory import ArcPointer, unsafe_memcpy, unsafe_memset
from std.bit import pop_count
from std.algorithm import vectorize
from std.sys import simd_width_of

from komira_buffer.byte_view import ByteView
from komira_buffer.heap_region import HeapRegion
from komira_buffer.memory_region import MemoryRegion
from komira_buffer.mmap_region import MmapRegion

from komira_buffer.aligned_buffer_trait import AlignedBufferTrait
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer


# =============================================================================
# PERF-CRITICAL: SIMD popcount helper
# =============================================================================
# Port of the reference clang codegen for popcount. Clang-O3 emits
# `cnt.16b` + `udot.4s` + `uadalp.2d` with four parallel accumulators
# processing 64 bytes per iteration; Mojo's scalar `pop_count((u64 + i)[])`
# loop emits `cnt.8b + addv.8b` producing 8 bytes/iter — 8x slower.
#
# Using SIMD[uint8, 16] calls through `llvm.ctpop` which LLVM lowers to
# `cnt.16b` on ARM. Accumulating into SIMD[uint64, 2] via `reduce_add`
# on every chunk is the pattern that matches the clang codegen. The
# final `.reduce_add()` fuses into `addp + addv`.
#
# Note: a swap to `hadd_u8x16` (single `addv.16b` via
# `llvm.aarch64.neon.uaddv`) gains little: the popcount call is a
# sub-millisecond fraction of a query's wall. The wrapper stays available
# for future call sites where popcount is a dominant cost.
#
# Tail: any bytes past the last full 16-byte chunk use scalar pop_count.
# Scalar fallback: if ptr is null OR num_bytes == 0 the for loop is a no-op,
# the scalar tail returns 0, total is 0.
#
# NOT inline because the scalar-tail branch confuses the inliner and hurts
# the common full-chunk path.
# =============================================================================


@always_inline
def _simd_popcount_bytes[
    _mut: Bool, origin: Origin[mut=_mut], //,
](view: ByteView[origin], num_bytes: Int) -> Int:
    """Count the total number of set bits in the first num_bytes of `view`.

    Uses SIMD popcount (NEON `cnt.16b`) at 16 bytes/iter for the bulk,
    scalar pop_count (on u64 words) for the tail. Matches clang's codegen
    for the equivalent C loop — see the module docstring.

    Takes a `ByteView[origin]` (not a raw pointer); the view's `load_simd`
    + `get_typed[UInt64]` + `read_u8_at` keep the load widths at
    @always_inline. PERF-CRITICAL: popcount hot paths.
    """
    if num_bytes <= 0:
        return 0

    var count: Int = 0
    comptime W: Int = 16  # 16-byte NEON register width; fires `cnt.16b`
    var simd_end = (num_bytes // W) * W
    var i = 0

    # Bulk 16-byte pass. SIMD[uint8, 16].ctpop produces per-byte bit counts
    # (0..8 each). `reduce_add` folds the 16 byte-counts into a single
    # integer. On ARM NEON LLVM lowers this chain to the canonical
    # `cnt.16b + addv.16b` pipeline.
    while i < simd_end:
        var chunk = view.load_simd[DType.uint8, W](i)
        var cnts = pop_count(chunk)
        count += Int(cnts.reduce_add())
        i += W

    # Scalar tail: fold remaining (0..15) bytes at the u64 granularity
    # where possible, byte-wise for the final <8. Keeps the tail fast
    # for misaligned lengths (e.g. num_bytes = 17 becomes one u64 + 1 byte).
    var tail = num_bytes - simd_end
    var u64_end = tail >> 3
    for k in range(u64_end):
        # view.get_typed[UInt64](k) addresses element-index k starting
        # from byte 0 -- we need to address from `simd_end`. Use
        # byte-offset read via bitcast at the view level.
        var byte_off = simd_end + (k << 3)
        count += Int(pop_count(view.read_u64_le_at(byte_off)))
    var tail_byte_start = simd_end + (u64_end << 3)
    for k in range(tail_byte_start, num_bytes):
        count += Int(pop_count(view.read_u8_at(k)))
    return count


@always_inline
def bytes_for_bits(num_bits: Int) -> Int:
    """Compute the number of bytes needed to hold `num_bits` bits."""
    return (num_bits + 7) >> 3


@always_inline
def read_bit_aligned_buffer[
    B_src: AlignedBufferTrait,
](src_buf: B_src, bit_index: Int) -> Bool:
    """Read ONE bit: `src[bit_index]`, where `bit_index` is a BIT position.

    The SCALAR sibling of `copy_bits_aligned_buffer` (a contiguous run) and
    `gather_bits_aligned_buffer` (an indexed run). All three exist so that
    "address row r of a bit-packed BOOL column" has exactly one implementation
    in this repo, because the alternative — every caller writing `>> 3` and
    `& 7` by hand — is how the same defect lands in several different
    spellings.

    ⚠ `bit_index` is `column._offset + row`, NOT a byte address. For BOOL,
    `_offset` is itself a bit index, so callers must add it in bit space and
    never scale either term by an element width. A bit-packed BOOL column has
    no per-element byte width; `n * width` is not an imprecise answer for it,
    it is the wrong SHAPE of arithmetic.

    Bounds against the BUFFER's capacity are debug-asserted by the underlying
    `read_u8_at`; the caller owns the LOGICAL bound (`bit_index < length`),
    exactly as for the two run-oriented siblings.

    Args:
        src_buf: Buffer holding the packed bits.
        bit_index: Absolute BIT position to read.

    Returns:
        True iff the bit is set.
    """
    return (
        src_buf.read_u8_at(bit_index >> 3) >> UInt8(bit_index & 7)
    ) & UInt8(1) == UInt8(1)


def copy_bits_aligned_buffer[
    B_dst: AlignedBufferTrait,
    B_src: AlignedBufferTrait,
](
    mut dst_buf: B_dst,
    dst_bit_offset: Int,
    src_buf: B_src,
    src_bit_offset: Int,
    num_bits: Int,
):
    """Copy `num_bits` bits between two AlignedBuffers, byte-aligned-fast.

    Public buffer-level primitive shared by `Bitmap.copy_bits_into` and
    by callers that hold raw `MmapAlignedBuffer[64]` packed-bit storage
    (Arrow BOOL columns, validity bitmaps held outside a `Bitmap`
    wrapper). Same two-path shape as `Bitmap.copy_bits_into`:

      * **Both byte-aligned fast path** (`src_bit_offset & 7 == 0` AND
        `dst_bit_offset & 7 == 0`): memcpy-backed `view_range_mut.
        copy_from_view_at` for the bulk; partial-byte
        read-modify-write for the trailing `num_bits & 7` bits to
        preserve any dst bits past the copied region.
      * **Bit-unaligned fallback**: per-bit walk (cold path; production
        callers — late-mat copy, morsel slice — feed byte-aligned
        offsets when their offsets are multiples of 8).

    The buffer-level core of `Bitmap.copy_bits_into`, so the
    `copy_column_ref` BOOL slice and the morsel `_slice_fixed_width` /
    `_slice_variable_width` validity-copy sites share the same memcpy
    fast-path instead of per-bit scalar loops.

    SAFETY:
      * Caller MUST have validated `src_bit_offset + num_bits <=
        src_buf_total_bits` and same for dst BEFORE calling.
      * Bounds against the BUFFER's `capacity` are debug-asserted by
        the underlying `view_range_*` / `read_u8_at` calls.
      * `dst_buf` and `src_buf` MUST NOT alias; aliased calls read
        partially-overwritten source bytes.

    Args:
        dst_buf: Destination buffer (mut).
        dst_bit_offset: Bit position in `dst_buf` where the copy
            begins.
        src_buf: Source buffer.
        src_bit_offset: Bit position in `src_buf` where the copy
            begins.
        num_bits: Number of bits to copy.
    """
    if num_bits <= 0:
        return

    var src_bit_off = src_bit_offset & 7
    var dst_bit_off = dst_bit_offset & 7
    var src_byte_off = src_bit_offset >> 3
    var dst_byte_off = dst_bit_offset >> 3

    if src_bit_off == 0 and dst_bit_off == 0:
        # Fast path: both ends byte-aligned. Bulk byte-copy + partial
        # tail-byte read-modify-write.
        var full_bytes = num_bits >> 3
        var tail_bits = num_bits & 7

        if full_bytes > 0:
            # PERF-CRITICAL: memcpy-backed byte-copy via the view API.
            dst_buf.view_range_mut(
                dst_byte_off, full_bytes
            ).copy_from_view_at(
                0,
                src_buf.view_range_ro(src_byte_off, full_bytes),
            )

        if tail_bits > 0:
            # Trailing partial byte: preserve dst bits past the copied
            # region within the same byte.
            var src_tail_byte = src_buf.read_u8_at(
                src_byte_off + full_bytes
            )
            var keep_mask = UInt8((1 << tail_bits) - 1)
            var dst_byte_idx = dst_byte_off + full_bytes
            var dst_cur = dst_buf.read_u8_at(dst_byte_idx)
            var dst_new = (dst_cur & ~keep_mask) | (
                src_tail_byte & keep_mask
            )
            dst_buf.write_u8_at(dst_byte_idx, dst_new)
        return

    # Slow path: bit-unaligned. Walk bit-by-bit. Correctness over speed
    # — production hot paths pass byte-aligned offsets.
    for j in range(num_bits):
        var src_bit = (
            src_buf.read_u8_at(src_byte_off + ((src_bit_off + j) >> 3))
            >> UInt8((src_bit_off + j) & 7)
        ) & UInt8(1)
        var dst_byte_idx = dst_byte_off + ((dst_bit_off + j) >> 3)
        var dst_bit_idx = (dst_bit_off + j) & 7
        var cur = dst_buf.read_u8_at(dst_byte_idx)
        var bit_mask = UInt8(1) << UInt8(dst_bit_idx)
        if src_bit == UInt8(1):
            dst_buf.write_u8_at(dst_byte_idx, cur | bit_mask)
        else:
            dst_buf.write_u8_at(dst_byte_idx, cur & ~bit_mask)


def gather_bits_aligned_buffer[
    B_dst: AlignedBufferTrait,
    B_src: AlignedBufferTrait,
](
    mut dst_buf: B_dst,
    src_buf: B_src,
    src_bit_offset: Int,
    indices: List[Int],
):
    """Scatter-gather bits: `dst[i] = src[src_bit_offset + indices[i]]`.

    The INDEXED sibling of `copy_bits_aligned_buffer`, which can only move a
    CONTIGUOUS run. A row gather (SORT's finalize permutation, a FILTER's
    survivor list, a join probe's match list) picks rows in arbitrary order, so
    it needs this one — and a bit-packed BOOL column is the only Arrow layout
    where "pick row r" is not a byte address.

    Why this exists as a shared primitive rather than three inlined loops: the
    per-row bit arithmetic below is exactly the arithmetic that
    `n * element_size(BOOL)` got wrong at every site that lacked a BOOL arm,
    and this repo has already paid for four hand-copied byte-width ladders
    drifting apart (see the notes at `compiler_helpers.element_size`). One
    definition, tree-wide.

    Args:
        dst_buf: Destination buffer. Bit `i` of the OUTPUT (LSB-first within
            each byte, Arrow's layout) is written from `indices[i]`. Written
            whole-byte at a time, so it does NOT need to be pre-zeroed, and any
            dst bits past `len(indices)` in the final partial byte are CLEARED
            — the caller owns a freshly-allocated `(n + 7) >> 3`-byte buffer.
        src_buf: Source buffer holding the packed bits.
        src_bit_offset: The source column's `_offset`, in BITS. For BOOL this
            is a bit index, never a byte index — the distinction that made
            `_offset * width` silently return the wrong rows on a sliced
            column.
        indices: Row indices into the source, relative to `src_bit_offset`.

    SAFETY:
      * Caller MUST have validated `src_bit_offset + max(indices) <`
        src bit count, and `dst_buf.len() >= (len(indices) + 7) >> 3`,
        BEFORE calling. Bounds against the buffers are debug-asserted by the
        underlying `read_u8_at` / `write_u8_at`.
      * `dst_buf` and `src_buf` MUST NOT alias.
    """
    var n = len(indices)
    var full_bytes = n >> 3
    var tail_bits = n & 7

    var b = 0
    while b < full_bytes:
        var base = b << 3
        var acc = UInt8(0)
        for k in range(8):
            var sb = src_bit_offset + indices[base + k]
            var bit = (src_buf.read_u8_at(sb >> 3) >> UInt8(sb & 7)) & UInt8(1)
            acc |= bit << UInt8(k)
        dst_buf.write_u8_at(b, acc)
        b += 1

    if tail_bits > 0:
        var base = full_bytes << 3
        var acc = UInt8(0)
        for k in range(tail_bits):
            var sb = src_bit_offset + indices[base + k]
            var bit = (src_buf.read_u8_at(sb >> 3) >> UInt8(sb & 7)) & UInt8(1)
            acc |= bit << UInt8(k)
        dst_buf.write_u8_at(full_bytes, acc)


struct Bitmap[K: MemoryRegion = HeapRegion](Movable):
    """Arrow-format validity bitmap: 1 bit per element, LSB-first.

    Bit = 1 means the element is valid (not null).
    Bit = 0 means the element is null.

    Backed by an MmapAlignedBuffer for SIMD-friendly access.

    Parameters:
        K: The MemoryRegion type backing the bitmap. Defaults to
           HeapRegion (owning). K=MmapRegion is the zero-copy IPC path
           (read-only mmap-borrowed bitmap; mutating methods are
           constrained-out for that K).
           The K parameter carries the buffer region type through the
           validity-bitmap wrapper. Default K=HeapRegion means `Bitmap`
           sites compile as `Bitmap[HeapRegion]` with no annotation.

    Fields:
        buffer: The underlying aligned memory holding the packed bits.
        length: Number of logical bits (= number of elements in the array).
    """

    # Holder field is a `SharedAlignedBuffer[Self.K]`.
    var buffer: SharedAlignedBuffer[Self.K]
    var length: Int

    # --- LIFECYCLE ---

    @staticmethod
    def create(num_bits: Int) -> Bitmap[HeapRegion]:
        """Create a bitmap for `num_bits` elements, all initially null (0).

        Args:
            num_bits: Number of bits (elements) in the bitmap.

        Returns:
            A new Bitmap[HeapRegion] with all bits cleared (all null).
            Owning allocation routes through HeapRegion-only path.
        """
        var bm = Bitmap[HeapRegion]()
        var num_bytes = bytes_for_bits(num_bits)
        # Bridge OAB -> SAB[HeapRegion]. OAB's ctor sets
        # `_length = capacity` directly so no separate `set_length` needed.
        var oab = OwnedAlignedBuffer(num_bytes)
        bm.buffer = SharedAlignedBuffer.from_owned(oab^)
        bm.buffer.zero()
        bm.length = num_bits
        return bm^

    @staticmethod
    def from_borrowed_view(
        bitmap_view: ByteView[_], num_bits: Int
    ) -> Bitmap[HeapRegion]:
        """Construct a non-owning Bitmap whose `buffer` borrows into
        `bitmap_view`'s bytes. The returned Bitmap drops without
        freeing the borrowed bytes (capacity=0 sentinel on the inner
        MmapAlignedBuffer).

        Used by ipc_decoder_dispatch.decode_record_batch_zerocopy
        nullable arm — validity
        bitmap bytes live in the IPC body buffer; the Bitmap points
        into them with no memcpy.

        Returns Bitmap[HeapRegion] (the borrow goes through
        `_borrow_from_view` which is constrained K=HeapRegion — the
        underlying _region is an empty HeapRegion placeholder; the
        bytes' lifetime is the caller's source ByteView).

        SAFETY: same contract as Column.from_borrowed_*: the source
        bytes referenced by `bitmap_view` MUST outlive the returned
        Bitmap. Caller responsibility.
        """
        var bytes_needed = bytes_for_bits(num_bits)
        debug_assert(
            bytes_needed <= bitmap_view.len(),
            "Bitmap.from_borrowed_view: view too short for num_bits",
        )
        # Migrated from
        # `SharedAlignedBuffer.from_aligned_buffer(
        #     MmapAlignedBuffer[64, HeapRegion]._borrow_from_view(bitmap_view,
        #         bytes_needed))` to the NEW SAB-direct factory.
        _ = bytes_needed
        var bm = Bitmap[HeapRegion]()
        bm.buffer = SharedAlignedBuffer.from_borrowed_view(bitmap_view)
        bm.length = num_bits
        return bm^

    # mmap-backed Bitmap factory.
    #
    # Builds a non-owning Bitmap whose `buffer` borrows into the mmap region
    # at the given absolute file offset, with an ArcPointer<MmapRegion>
    # keepalive that defers munmap until the last consumer drops. Used by
    # the path-mode IPC reader for the validity bitmap of zero-copy
    # mmap-borrowed columns.
    @staticmethod
    def from_mmap(
        region: ArcPointer[MmapRegion],
        offset: Int,
        num_bits: Int,
    ) raises -> Bitmap[MmapRegion]:
        """Construct a non-owning Bitmap[MmapRegion] borrowing into an mmap region.

        The return type is the SEMANTIC-FAITHFUL `Bitmap[MmapRegion]` (not a
        bare `Bitmap` with default K=HeapRegion), matching the K=MmapRegion
        mmap borrow it wraps.

        Args:
            region: ArcPointer to the mmap region. Refcount-bumped via
                the inner `MmapAlignedBuffer.borrow_from_mmap`.
            offset: Absolute byte offset in the mmap region where the
                bitmap bytes start.
            num_bits: Number of logical bits (= elements in the column).

        SAFETY: the mmap region's bytes at [offset, offset + bytes_for_bits(
        num_bits)) must contain the LSB-first validity bitmap encoded per
        Arrow spec. The ArcPointer keepalive (inside the MmapAlignedBuffer)
        keeps the region alive until the last consumer drops.
        """
        var bytes_needed = bytes_for_bits(num_bits)
        # Build the SAB[MmapRegion] directly (the field is
        # now SAB[Self.K]) — borrow_from_mmap is the explicit mmap-K SAB
        # constructor (parallel to `MmapAlignedBuffer.borrow_from_mmap`).
        var sab_buf = SharedAlignedBuffer.borrow_from_mmap(
            region, Int64(offset), Int64(bytes_needed)
        )
        # Field-wise ctor — `Bitmap[MmapRegion]()` would fail the
        # constrained K=HeapRegion empty-default ctor.
        return Bitmap[MmapRegion](sab_buf^, num_bits)

    @staticmethod
    def from_mmap_erased(
        region: ArcPointer[MmapRegion],
        offset: Int,
        num_bits: Int,
    ) raises -> Bitmap[HeapRegion]:
        """Zero-copy mmap-borrow validity bitmap that returns K=HeapRegion
        via the type-erased keepalive cookie.

        Sibling of
        `from_mmap` but returns `Bitmap[HeapRegion]` (the field type required
        by the non-K-parametric `Column._validity: Optional[Bitmap[HeapRegion]]`)
        WITHOUT a realign memcpy. The inner SAB carries the
        `ArcPointer[MmapRegion]` keepalive that pins the mapping; the bytes
        alias the mmap'd page cache directly.

        Avoids a `from_mmap(...).buffer.realign_to[64]()` bridge (one
        alloc+memcpy per validity bitmap per RecordBatch).

        Args:
            region: ArcPointer to the mmap region. Refcount-bumped into the
                keepalive cookie.
            offset: Absolute byte offset of the bitmap bytes in the region.
            num_bits: Number of logical bits (= column length).

        Returns:
            Bitmap[HeapRegion] aliasing the mmap bytes, mapping pinned.
        """
        var bytes_needed = bytes_for_bits(num_bits)
        var sab_buf = SharedAlignedBuffer.borrow_mmap_erased(
            ArcPointer[MmapRegion](copy=region),
            Int64(offset),
            Int64(bytes_needed),
        )
        return Bitmap[HeapRegion](sab_buf^, num_bits)

    @staticmethod
    def create_all_valid(num_bits: Int) -> Bitmap[HeapRegion]:
        """Create a bitmap for `num_bits` elements, all initially valid (1).

        Args:
            num_bits: Number of bits (elements) in the bitmap.

        Returns:
            A new Bitmap[HeapRegion] with all bits set (all valid).
        """
        var bm = Bitmap[HeapRegion]()
        var num_bytes = bytes_for_bits(num_bits)
        # Bridge OAB -> SAB[HeapRegion] (see Bitmap.create).
        var oab = OwnedAlignedBuffer(num_bytes)
        bm.buffer = SharedAlignedBuffer.from_owned(oab^)
        if num_bytes > 0:
            # Migrated memset(_unsafe_data_ptr(), 0xFF, ...) onto
            # `view_range_mut(0, num_bytes).fill(0xFF)` — memset-backed.
            bm.buffer.view_range_mut(0, num_bytes).fill(0xFF)
            bm.buffer.set_length(num_bytes)

            # Clear trailing bits in the last byte that are beyond num_bits.
            var trailing = num_bits & 7
            if trailing > 0:
                var mask = UInt8((1 << trailing) - 1)
                # Migrated trailing-mask store to `write_u8_at`.
                bm.buffer.write_u8_at(num_bytes - 1, mask)
        bm.length = num_bits
        return bm^

    @staticmethod
    def copy_slice_from[
        src_K: MemoryRegion, //,
    ](
        src: Bitmap[src_K], src_bit_offset: Int, num_bits: Int
    ) raises -> Bitmap[HeapRegion]:
        """Copy `num_bits` bits from `src` starting at `src_bit_offset`.

        This is the bulk-copy primitive used by `copy_column` (A.4) when a
        column has a validity bitmap with nulls that must be preserved
        across a slice copy. Replaces the per-row scalar
        `for r: bm.set(r) / bm.clear(r)` loop in
        `compiler_helpers.copy_column`.

        Two paths:
          * **Byte-aligned fast path** (`src_bit_offset % 8 == 0`): direct
            memcpy of `bytes_for_bits(num_bits)` bytes from
            `src.buffer + (src_bit_offset >> 3)` into a fresh MmapAlignedBuffer.
            Trailing bits past `num_bits` in the final byte are masked to
            0 so downstream popcount/test sees canonical zeros. This is the
            common case for non-zero-copy column copies (most callers).
          * **Bit-unaligned fallback**: scalar bit-shift loop (one byte
            at a time, OR'd from the two source bytes that straddle the
            destination byte). Correctness-preserving but no SIMD; callers
            that hit this path are typically zero-copy slices originating
            from PrimitiveArray.slice() with non-byte-aligned offsets,
            which are uncommon in the production hot paths.

        Args:
            src: Source bitmap to copy from.
            src_bit_offset: Starting bit index in `src` (must be in
                `[0, src.length]`).
            num_bits: Number of bits to copy (must satisfy
                `src_bit_offset + num_bits <= src.length`).

        Returns:
            A new Bitmap of `length == num_bits` whose bits mirror
            `src[src_bit_offset .. src_bit_offset + num_bits]`.

        Raises:
            On out-of-bounds (`src_bit_offset + num_bits > src.length`).
        """
        if src_bit_offset < 0 or num_bits < 0:
            raise Error("Bitmap.copy_slice_from: negative offset/length")
        if src_bit_offset + num_bits > src.length:
            raise Error("Bitmap.copy_slice_from: slice exceeds source length")

        # Empty-slice short-circuit. Pre-zeroed buffer is correct for
        # length=0 (downstream popcount/test never reads).
        if num_bits == 0:
            return Bitmap.create(0)

        var num_bytes = bytes_for_bits(num_bits)
        var dst = Bitmap[HeapRegion]()
        # Bridge OAB -> SAB[HeapRegion] (see Bitmap.create).
        var oab = OwnedAlignedBuffer(num_bytes)
        dst.buffer = SharedAlignedBuffer.from_owned(oab^)
        dst.buffer.zero()
        dst.length = num_bits

        if (src_bit_offset & 7) == 0:
            # Byte-aligned fast path: direct memcpy of whole bytes from the
            # source's view at the corresponding byte offset. MmapAlignedBuffer
            # pads to 64 bytes and zero-initializes the pad, so the trailing
            # bits past `num_bits` in the final destination byte are
            # already 0 from the `zero()` above; we still mask explicitly
            # so the API stays robust if `zero()` semantics ever change.
            var src_byte_off = src_bit_offset >> 3
            dst.buffer.copy_from_view(
                src.buffer.view_range_ro(src_byte_off, num_bytes)
            )
        else:
            # Bit-unaligned fallback. Each destination byte is built by
            # OR-ing two adjacent source bytes shifted appropriately.
            #   shift = src_bit_offset & 7      (1..7)
            #   dst[i] = (src[base+i] >> shift)
            #          | (src[base+i+1] << (8-shift))
            # The high bits of the trailing dst byte get masked at the end.
            var shift = src_bit_offset & 7
            var inv_shift = 8 - shift
            var src_byte_off = src_bit_offset >> 3
            # Number of source bytes spanned by the slice. Could be
            # `num_bytes` or `num_bytes + 1` depending on tail bit-position.
            var src_last_bit = src_bit_offset + num_bits - 1
            var src_byte_end = (src_last_bit >> 3) + 1  # one-past-last
            var src_span = src_byte_end - src_byte_off
            for i in range(num_bytes):
                var lo = src.buffer.read_u8_at(src_byte_off + i)
                var hi: UInt8 = 0
                if i + 1 < src_span:
                    hi = src.buffer.read_u8_at(src_byte_off + i + 1)
                var byte = (lo >> UInt8(shift)) | (hi << UInt8(inv_shift))
                dst.buffer.write_u8_at(i, byte)

        # Mask trailing bits in the final byte past `num_bits` so
        # popcount() / test() never observe stale 1s from the source's
        # tail beyond the slice.
        var trailing = num_bits & 7
        if trailing > 0:
            var mask = UInt8((1 << trailing) - 1)
            var last = dst.buffer.read_u8_at(num_bytes - 1)
            dst.buffer.write_u8_at(num_bytes - 1, last & mask)

        dst.buffer.set_length(num_bytes)

        return dst^

    @staticmethod
    def copy_bits_into[
        src_K: MemoryRegion, //,
    ](
        mut dst: Bitmap[HeapRegion],
        dst_bit_offset: Int,
        src: Bitmap[src_K],
        src_bit_offset: Int,
        num_bits: Int,
    ) raises -> None:
        """Copy `num_bits` from `src[src_bit_offset..]` into `dst[dst_bit_offset..]`.

        PERF-CRITICAL: bulk-copy primitive used by
        `_concat_fixed_columns_multi` to fold per-batch validity bitmaps into
        a single output bitmap, instead of a per-bit scalar loop
        (`for j: src_bm.test(off+j); dst_bm.clear(...)`).

        Requirements:
          * `dst_bit_offset + num_bits <= dst.length`
          * `src_bit_offset + num_bits <= src.length`
          * `dst[dst_bit_offset..dst_bit_offset+num_bits]` MAY be either
            all-valid (1) or arbitrary on entry: we OVERWRITE with
            `src[src_bit_offset..src_bit_offset+num_bits]`. (i.e. this
            is a copy, not an OR or AND.)

        Two paths:
          * **Both byte-aligned fast path** (`src_bit_offset % 8 == 0`
            AND `dst_bit_offset % 8 == 0`): direct byte-copy of
            `num_bits >> 3` whole bytes via memcpy-backed view copy,
            then a partial-byte tail merge for the trailing `num_bits & 7`
            bits (read-modify-write to preserve the destination's bits
            past the copied region).
          * **Bit-unaligned fallback**: scalar byte-walk that reads each
            destination byte's contribution from one or two source bytes
            (shifted by `(src_bit_offset & 7) - (dst_bit_offset & 7)`).
            This is a cold path; the streaming-concat hot path passes
            byte-aligned offsets when row_cursor and src_offset are both
            multiples of 8.

        Returns: nothing (mutates `dst` in place).

        Body delegated to the buffer-level
        free function `copy_bits_aligned_buffer` so the BOOL slice path
        in `copy_column_ref` and the validity-bitmap path
        in `_slice_fixed_width` / `_slice_variable_width` can reuse the
        same memcpy-backed primitive without first copying through a
        Bitmap wrapper. Bounds-check semantics preserved.
        """
        if src_bit_offset < 0 or dst_bit_offset < 0 or num_bits < 0:
            raise Error("Bitmap.copy_bits_into: negative offset/length")
        if num_bits <= 0:
            return
        if src_bit_offset + num_bits > src.length:
            raise Error(
                "Bitmap.copy_bits_into: src slice exceeds source length"
            )
        if dst_bit_offset + num_bits > dst.length:
            raise Error(
                "Bitmap.copy_bits_into: dst slice exceeds destination length"
            )
        copy_bits_aligned_buffer(
            dst.buffer, dst_bit_offset, src.buffer, src_bit_offset, num_bits
        )

    def __init__(out self):
        """Internal: create an empty bitmap. Use create() or create_all_valid().

        Constrained to K=HeapRegion. K=MmapRegion `Bitmap` is built via the field-wise
        `__init__(buffer, length)` ctor below from `from_mmap`.
        """
        comptime assert (Self.K == HeapRegion), ( "Bitmap(): owning empty bitmap requires K=HeapRegion." " K=MmapRegion buffers must use Bitmap.from_mmap." )
        # Construct directly with HeapRegion (Self.K == HeapRegion per the
        # constrained block above). The SAB ctor below uses the (region,
        # offset, length) variant which works for any K. The rebind on the
        # ArcPointer narrows the type assignment for the typechecker (same
        # pattern as the other aligned buffers' size-ctors).
        var empty_region = HeapRegion(List[UInt8]())
        var arc_heap = ArcPointer[HeapRegion](empty_region^)
        var arc_self_k = rebind[ArcPointer[Self.K]](arc_heap^)
        self.buffer = SharedAlignedBuffer[Self.K](
            region=arc_self_k^, offset=0, length=0
        )
        self.length = 0

    def __init__(
        out self,
        var buffer: SharedAlignedBuffer[Self.K],
        length: Int,
    ):
        """Field-wise constructor. Used by `from_mmap` (and any future
        K-overriding factory) where the empty-default ctor cannot apply
        (it requires K=HeapRegion).

        Parameter type flipped to SAB to
        match the new field type; bridge across K=HeapRegion vs K=MmapRegion
        is now the caller's concern (callers route through
        `SharedAlignedBuffer.from_aligned_buffer` or
        `SharedAlignedBuffer.borrow_from_mmap`).
        """
        self.buffer = buffer^
        self.length = length

    def share(self) -> Self:
        """Arc-SHARE this bitmap: share the packed-bits `buffer` (Arc
        refcount++, no byte copy) and copy the `length` scalar. The zero-copy
        dual of the deep-copy in `copy_column` path 3 / `deep_copy` for the
        validity bitmap. Used by `Column.share`."""
        return Self(self.buffer.share(), self.length)

    # --- BIT OPERATIONS ---

    @always_inline
    def set(mut self, index: Int):
        """Set bit at `index` to 1 (mark element as valid).

        Migrated read-modify-write via `_unsafe_data_ptr()` onto
        `MmapAlignedBuffer.read_u8_at` + `write_u8_at`. Same codegen at
        @always_inline (one byte load + or + store).
        """
        var byte_idx = index >> 3
        var bit_idx = index & 7
        var cur = self.buffer.read_u8_at(byte_idx)
        self.buffer.write_u8_at(byte_idx, cur | (UInt8(1) << UInt8(bit_idx)))

    @always_inline
    def clear(mut self, index: Int):
        """Clear bit at `index` to 0 (mark element as null).

        See `set` above.
        """
        var byte_idx = index >> 3
        var bit_idx = index & 7
        var cur = self.buffer.read_u8_at(byte_idx)
        self.buffer.write_u8_at(byte_idx, cur & ~(UInt8(1) << UInt8(bit_idx)))

    @always_inline
    def test(self, index: Int) -> Bool:
        """Test whether bit at `index` is set (element is valid).

        Migrated load via `_unsafe_data_ptr()` onto `read_u8_at`.
        """
        var byte_idx = index >> 3
        var bit_idx = index & 7
        return (self.buffer.read_u8_at(byte_idx) >> UInt8(bit_idx)) & 1 == 1

    def popcount(self) -> Int:
        """Count the number of set bits (valid elements) in the bitmap.

        PERF-CRITICAL: Routes through `_simd_popcount_bytes` which uses NEON
        `cnt.16b` + SIMD reduce_add to process 16 bytes per iteration.
        About 8x faster than a scalar `pop_count(u64)` loop on ARM M-series.

        Scalar fallback: `_simd_popcount_bytes` handles n<16 via a scalar
        tail loop, so popcount remains correct for tiny bitmaps.

        Migrated to the ByteView-accepting `_simd_popcount_bytes`.
        """
        var num_bytes = bytes_for_bits(self.length)
        return _simd_popcount_bytes(self.buffer.view_ro(), num_bytes)

    def all_valid(self) -> Bool:
        """Check if ALL bits are set (no nulls in the array)."""
        return self.popcount() == self.length

    def null_count(self) -> Int:
        """Count the number of null (unset) elements."""
        return self.length - self.popcount()

    # --- BITWISE COMBINERS ---
    #
    # PERF-CRITICAL: CASE-expression port depends on these.
    # Why explicit SIMD: Mojo does NOT reliably auto-vectorize scalar loops over UnsafePointer, even
    # for trivially-linear bitwise ops. Use explicit SIMD[UInt64, W] stride
    # to get NEON/AVX codegen. This mirrors arrow-rs's bit_util::bitwise_bin_op.
    #
    # Safety invariants relied on by these kernels:
    #   - The aligned buffers pad allocations up to the next 64-byte boundary
    #     and memset-zero the pad region. This lets
    #     us do unconditional SIMD loads past `length` bits (we read zeros)
    #     and unconditional SIMD stores to the result buffer (the writes land
    #     in the pad region, which nobody observes).
    #   - We still explicitly zero the trailing bits past `length` in the
    #     output, so downstream popcount()/test() see canonical 0 there.

    def and_[
        other_K: MemoryRegion, //,
    ](self, other: Bitmap[other_K]) raises -> Bitmap[HeapRegion]:
        """Bitwise AND with another bitmap of the same length.

        Returns a new Bitmap[HeapRegion] where bit i is set iff
        self[i] AND other[i].

        Raises:
            If `other.length != self.length`.

        Note: named `and_` (not `and`) because `and` is a reserved keyword.
        """
        if self.length != other.length:
            raise Error("Bitmap.and_: length mismatch")
        return _bitwise_combine[_BITOP_AND](self, other)

    def and_not[
        other_K: MemoryRegion, //,
    ](self, other: Bitmap[other_K]) raises -> Bitmap[HeapRegion]:
        """Bitwise `self AND NOT other` (i.e. bits set in self but not other).

        Returns a new Bitmap[HeapRegion] where bit i is set iff
        self[i] AND NOT other[i].

        Raises:
            If `other.length != self.length`.
        """
        if self.length != other.length:
            raise Error("Bitmap.and_not: length mismatch")
        return _bitwise_combine[_BITOP_AND_NOT](self, other)


# =============================================================================
# INTERNAL — SIMD bitwise combine kernel
# =============================================================================

comptime _BITOP_AND: Int = 0
comptime _BITOP_AND_NOT: Int = 1


def _bitwise_combine[
    a_K: MemoryRegion, b_K: MemoryRegion, //, op: Int,
](a: Bitmap[a_K], b: Bitmap[b_K]) -> Bitmap[HeapRegion]:
    """SIMD u64-wide bitwise combine over two equal-length bitmaps.

    Pattern: explicit SIMD[UInt64, W] load/store, stride = W lanes, with a
    u64 scalar tail for the final ≤7 words. The 64-byte pad in MmapAlignedBuffer
    makes the scalar u64 tail safe even if `length` is not a multiple of 64.

    Trailing bits in the final partial u64 (those past `length & 63`) are
    cleared after the combine so popcount() / test() never observe stale bits.

    Migrated from `_unsafe_data_ptr().bitcast[UInt64]()` onto
    `MmapAlignedBuffer.load_simd[DType.uint64, W]` / `store_simd` / `read_u64_le_at`
    / `write_u64_le_at` / `read_u8_at` / `write_u8_at`. The `byte_offset`
    argument to load_simd/store_simd is in bytes, so the w-th SIMD step is
    at byte_offset `w * W * 8` and the k-th scalar u64 is at `k * 8`.
    PERF-CRITICAL: AND/AND-NOT are the hot filter combiners.
    """
    var n_bits = a.length
    var out = Bitmap.create(n_bits)
    if n_bits == 0:
        return out^

    var num_bytes = bytes_for_bits(n_bits)
    var full_u64 = num_bytes >> 3          # number of complete 8-byte words
    var tail_bytes = num_bytes & 7          # 0..7 leftover bytes

    # SIMD stride over full u64 words. W=native u64 lane count.
    comptime W: Int = simd_width_of[DType.uint64]()
    var i = 0
    var simd_limit = (full_u64 // W) * W
    while i < simd_limit:
        var byte_off = i * 8
        var va = a.buffer.load_simd[DType.uint64, W](byte_off)
        var vb = b.buffer.load_simd[DType.uint64, W](byte_off)
        comptime if op == _BITOP_AND:
            out.buffer.store_simd[DType.uint64, W](byte_off, va & vb)
        else:
            out.buffer.store_simd[DType.uint64, W](byte_off, va & ~vb)
        i += W

    # Scalar u64 tail — ≤ W-1 iterations.
    while i < full_u64:
        var byte_off = i * 8
        var va = a.buffer.read_u64_le_at(byte_off)
        var vb = b.buffer.read_u64_le_at(byte_off)
        comptime if op == _BITOP_AND:
            out.buffer.write_u64_le_at(byte_off, va & vb)
        else:
            out.buffer.write_u64_le_at(byte_off, va & ~vb)
        i += 1

    # Remaining 0..7 bytes past the last full u64 — do byte-wise.
    if tail_bytes > 0:
        var byte_off = full_u64 << 3
        for k in range(tail_bytes):
            var xa = a.buffer.read_u8_at(byte_off + k)
            var xb = b.buffer.read_u8_at(byte_off + k)
            comptime if op == _BITOP_AND:
                out.buffer.write_u8_at(byte_off + k, xa & xb)
            else:
                out.buffer.write_u8_at(byte_off + k, xa & ~xb)

    # Zero trailing bits in the final byte past `n_bits`, so downstream
    # popcount() / test() see canonical zeros.
    var trailing = n_bits & 7
    if trailing > 0 and num_bytes > 0:
        var cur = out.buffer.read_u8_at(num_bytes - 1)
        var keep = UInt8((1 << trailing) - 1)
        out.buffer.write_u8_at(num_bytes - 1, cur & keep)

    # Buffer.length tracks bytes in use (parallels create_all_valid).
    out.buffer.set_length(num_bytes)

    return out^
