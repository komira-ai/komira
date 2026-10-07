# =============================================================================
# DELTA_BINARY_PACKED decoder (one-shot AND resumable)
# =============================================================================
#
# Delta encoding stores the first value, then deltas between consecutive
# values. Deltas are organized into blocks, each block into miniblocks,
# with per-miniblock bit widths for tight packing.
#
# Format (DELTA_BINARY_PACKED):
#   [block_size: ULEB128]       — values per block (typically 128)
#   [miniblock_count: ULEB128]  — miniblocks per block (typically 4)
#   [total_count: ULEB128]      — total value count
#   [first_value: zigzag i64]   — first value, unencoded
#   For each block:
#     [min_delta: zigzag i64]
#     [bit_width_0..bit_width_N: u8] — one per miniblock
#     For each miniblock:
#       [bit-packed deltas: miniblock_size * bit_width / 8 bytes]
#
# Used for sorted integer columns (timestamps, IDs) by Spark, Impala, etc. —
# and, by a writer that falls back from dictionary encoding, for every
# integer column whose cardinality overflows its dictionary, i.e. every
# high-cardinality join key / id / timestamp.
#
# The string-side siblings (DELTA_LENGTH_BYTE_ARRAY, DELTA_BYTE_ARRAY) live in
# `delta_byte_array.mojo`; they consume the `DeltaDecoder` below.
#
# TWO DECODE PATHS, one format:
#   * ONE-SHOT   `decode_int64` / `decode_int32` — decode a whole page in a
#     single call. Every non-streaming caller uses this and its bytes are
#     frozen.
#   * RESUMABLE  `begin_resumable` + `resume_fill_int64` / `resume_fill_int32`
#     — decode a page in cache-sized chunks, carrying the running sum forward.
#     A sub-row-group column cursor is its production caller. See the
#     resume-state block inside the struct for why the one-shot cannot simply
#     be called twice.
#
# Reference: parquet-format Encodings.md, DELTA_BINARY_PACKED (5)
#
# SAFETY: every public function takes Spans or an `OwnedAlignedBuffer`; no
# public function writes past the end of its output. _unpack_miniblock
# (private) takes UnsafePointer for bit-level access within a data buffer
# (strided bit extraction spanning byte boundaries). All cursor-based parsing
# (varints, header reads, byte reads) uses ByteBuffer for bounds-checked
# access.
# =============================================================================

from std.memory import unsafe_memcpy

from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.byte_buffer import ByteBuffer

from .decode_arm_trace import take_delta_page_arm


# A block size above this is corrupt (writers use small multiples of 128):
# `miniblock_size * bit_width` would overflow, a miniblock's byte length would
# turn negative, and the next miniblock would be read from before the page.
comptime _MAX_BLOCK_SIZE = 1 << 31


# =============================================================================
# Miniblock unpacking
# =============================================================================


@always_inline
def _unpack_miniblock[
    o_data: Origin[mut=True], o_out: Origin[mut=True]
](
    data: UnsafePointer[UInt8, o_data],
    data_offset: Int,
    data_len: Int,
    bit_width: Int,
    count: Int,
    min_delta: Int,
    current_value: Int,
    output: UnsafePointer[Int64, o_out],
    out_offset: Int,
) -> Tuple[Int, Int]:
    """Unpack one miniblock of delta-encoded values.

    NOT-VECTORIZABLE: Each value depends on previous (prefix sum of deltas).
    Bit-unpacking spans byte boundaries with arbitrary bit widths.
    Could split into two passes (SIMD unpack + serial prefix sum) for
    power-of-2 widths, but the complexity is not justified for current
    miniblock sizes (typically 32-128 values).

    SAFETY: Takes raw UnsafePointer for bit-level strided access across
    byte boundaries. ByteBuffer's sequential cursor model does not fit
    arbitrary-offset bit extraction.

    Returns (new_current_value, values_written).
    """
    var cur = current_value
    var written = 0

    if bit_width == 0:
        # All deltas are exactly min_delta.
        for _ in range(count):
            cur = cur + min_delta
            (output + out_offset + written)[] = Int64(cur)
            written += 1
        return (cur, written)

    var mask = (1 << bit_width) - 1 if bit_width < 64 else -1

    var bit_pos = 0

    for _ in range(count):
        var byte_idx = data_offset + (bit_pos >> 3)
        var bit_offset = bit_pos & 7

        # Read 8 bytes as a single 64-bit LE load when safe (covers every
        # bit offset of a width up to 57 bits without byte-by-byte
        # construction). Falls back to byte-by-byte only near the end of the
        # buffer.
        var raw = UInt64(0)
        if byte_idx + 8 <= data_len:
            # Single 64-bit load.
            raw = (data + byte_idx).bitcast[UInt64]()[]
        else:
            # Near buffer end: byte-by-byte to avoid out-of-bounds.
            var bytes_needed = ((bit_offset + bit_width) + 7) >> 3
            for b in range(min(bytes_needed, 8)):
                if byte_idx + b < data_len:
                    raw = raw | (UInt64((data + byte_idx + b)[]) << UInt64(b * 8))
        # Unsigned: an arithmetic shift would copy bit 63 into the value.
        var bits = raw >> UInt64(bit_offset)
        # A value at bit offset o that is w bits wide spans o + w bits: past
        # 64 (widths 58..63 at the larger offsets) its high bits are in the
        # ninth byte.
        if bit_offset > 0 and bit_offset + bit_width > 64:
            if byte_idx + 8 < data_len:
                bits = bits | (
                    UInt64((data + byte_idx + 8)[]) << UInt64(64 - bit_offset)
                )
        var val = Int(bits) & mask

        # val is unsigned delta offset from min_delta.
        var delta = min_delta + val
        cur = cur + delta
        (output + out_offset + written)[] = Int64(cur)
        written += 1
        bit_pos += bit_width

    return (cur, written)


# =============================================================================
# DeltaDecoder struct
# =============================================================================


struct DeltaDecoder(Movable):
    """Decodes DELTA_BINARY_PACKED encoded integer data.

    Supports both Int32 and Int64 output. The format always uses i64 internally
    for delta accumulation (matching the Parquet spec), then narrows for i32.

    Fields:
        reader: ByteBuffer cursor over the encoded byte stream (owns data).
    """

    var reader: ByteBuffer

    # =========================================================================
    # The RESUMABLE decode state.
    # =========================================================================
    #
    # WHY THE ONE-SHOT `decode_int64` CANNOT BE CALLED TWICE. Every piece of
    # resume state it needs lives in a LOCAL: it re-reads the four header
    # varints on entry (`block_size`, `miniblock_count`, `total_count`,
    # `first_value`), and it holds the running prefix sum (`current_value`) and
    # the stream position (`values_decoded`) in locals that die with the call.
    # Only `self.reader`'s byte cursor survives — so a SECOND call parses a
    # "header" out of the middle of the packed value stream and yields garbage.
    # That, and nothing about the FORMAT, is what blocked cache-aligned
    # streaming decode of a DELTA_BINARY_PACKED column.
    #
    # WHAT THE FORMAT DOES AND DOES NOT ALLOW. DBP is a running-sum encoding
    # (`value[N] = value[N-1] + min_delta + delta[N]`), so it admits NO random
    # SEEK — you cannot jump to value 8192 without having summed 0..8191. It is
    # however natively BLOCK-structured (parquet-format Encodings.md,
    # DELTA_BINARY_PACKED (5)): a header, then blocks of `block_size` values,
    # each split into `miniblock_count` bit-packed miniblocks with their own
    # widths. SEQUENTIAL chunking — 0..8191, then 8192..16383 — needs only the
    # running value carried forward, which is exactly what these fields do.
    #
    # THE RESUME SET, AND WHY IT IS SUFFICIENT. Decoding value `i` needs
    # (a) the running sum `value[i-1]`, (b) which miniblock `i` is in and the
    # reader positioned at that miniblock's packed bytes, (c) that miniblock's
    # bit width, (d) the enclosing block's `min_delta`, and (e) the geometry
    # (`miniblock_size`, `miniblock_count`) that says when the current block's
    # widths run out and a new block header must be read. `_res_current_value`
    # is (a); `_res_mb_idx` + `self.reader`'s own cursor are (b);
    # `_res_bws[_res_mb_idx]` is (c); `_res_min_delta` is (d); the two geometry
    # fields are (e). `_res_values_produced` + `_res_bound` bound the stream
    # exactly as the one-shot's `values_decoded`/`num_values` pair does, and
    # `_res_armed` is the "header already parsed" flag that stops the re-parse.
    #
    # MID-MINIBLOCK RESUME WITHOUT A BIT CURSOR. A chunk boundary that lands
    # inside a miniblock does NOT need a bit-position field: a miniblock is
    # bounded (`miniblock_size`, typically 32 to 256), so the
    # decoder unpacks it WHOLE into `_res_pending` and hands back the caller's
    # `room` values, draining the staged tail first on the next call.
    # `_res_pending_off` is how much of that stage has been returned. This
    # "produced-but-not-yet-returned" stash keeps the chunk cap HARD
    # (a caller asking for exactly N values gets exactly N).
    #
    # ⛔ NONE OF THESE FIELDS IS READ OR WRITTEN BY `decode_int64` /
    # `decode_int32`. The one-shot path is byte-for-byte what it was; the
    # resumable path is a strictly ADDITIVE second entry point
    # (`begin_resumable` + `resume_fill_int64` / `resume_fill_int32`).
    var _res_armed: Bool
    var _res_done: Bool
    var _res_bound: Int
    var _res_miniblock_count: Int
    var _res_miniblock_size: Int
    var _res_current_value: Int
    var _res_values_produced: Int
    var _res_min_delta: Int
    var _res_bws: List[UInt8]
    var _res_mb_idx: Int
    var _res_pending: List[Int64]
    var _res_pending_off: Int

    def __init__(out self, data: Span[UInt8, _]):
        """Construct a DeltaDecoder.

        Copies the encoded data from the Span into an owned ByteBuffer.
        The caller's buffer does not need to remain alive after construction.

        Args:
            data: The DELTA_BINARY_PACKED encoded stream.
        """
        # =====================================================================
        # THIS COPY IS A BULK memcpy, NOT A BYTE LOOP.
        # =====================================================================
        #
        # A byte loop reads `List[UInt8].append` once per encoded byte: about
        # eleven instructions (load, store, inc, two compares, a branch to the
        # `_realloc` site, and the pointer arithmetic to rebuild the source
        # address each time) for what a `memcpy` does at a small fraction of
        # that. On a scan whose integer columns are DELTA_BINARY_PACKED that
        # loop was the largest single share of retired instructions; the
        # loop retires at a high IPC, so its share of cycles is far smaller
        # than its share of instructions.
        #
        # WHY A COPY AT ALL, RATHER THAN A BORROW. `ByteBuffer` OWNS its
        # `List[UInt8]`, and `DeltaDecoder` is `Movable` and outlives the
        # call that constructs it on the resumable path (`begin_resumable` +
        # `resume_fill_*` are separate calls on a decoder the cursor stores).
        # A borrowing decoder is a different type with a different lifetime
        # contract; converting the loop to a bulk copy captures the whole
        # measured term without that change.
        #
        # The gate-off arm is the byte loop, kept so the two arms can be
        # compared from one binary. See `decode_arm_trace`.
        var data_len = len(data)
        var buf = List[UInt8](capacity=max(data_len, 1))
        if take_delta_page_arm():
            if data_len > 0:
                # ⭐ NO ZERO-FILL: the memcpy below writes exactly `data_len`
                # bytes from index 0, which is the WHOLE readable range of the
                # list, so no byte is readable before it is written.
                buf.resize(unsafe_uninit_length=data_len)
                # SAFETY: `data` holds `data_len` valid bytes (its own
                # length). `buf.unsafe_ptr()` is a module-internal escape
                # used exactly once, at the memcpy call; it does not outlive
                # this statement. memcpy is origin-polymorphic on src/dest.
                unsafe_memcpy(
                    dest=buf.unsafe_ptr(),
                    src=data.unsafe_ptr(),
                    count=data_len,
                )
        else:
            # The byte loop, kept ONLY so the two arms can
            # be compared from one binary. ⛔ Do not "simplify" this back into
            # the default path.
            for i in range(data_len):
                buf.append(data[i])
        self.reader = ByteBuffer(buf^)
        # Disarmed until `begin_resumable` parses the page header.
        self._res_armed = False
        self._res_done = False
        self._res_bound = 0
        self._res_miniblock_count = 0
        self._res_miniblock_size = 0
        self._res_current_value = 0
        self._res_values_produced = 0
        self._res_min_delta = 0
        self._res_bws = List[UInt8]()
        self._res_mb_idx = 0
        self._res_pending = List[Int64]()
        self._res_pending_off = 0

    def decode_int64[
        o: MutOrigin
    ](mut self, num_values: Int, output: Span[Int64, o]) -> Int:
        """Decode DELTA_BINARY_PACKED values into Int64 output buffer.

        Args:
            num_values: Number of values to decode; at most `len(output)`
                are decoded.
            output: Buffer for decoded Int64 values.

        Returns:
            Number of values actually decoded.
        """
        var n = min(num_values, len(output))
        if n <= 0:
            return 0
        # SAFETY: the core writes at most `n <= len(output)` slots.
        return self._decode_int64_ptr(n, output.unsafe_ptr())

    def _decode_int64_ptr[
        o: Origin[mut=True]
    ](
        mut self, num_values: Int, output: UnsafePointer[Int64, o]
    ) -> Int:
        """The core of `decode_int64`: `output` holds at least
        `num_values >= 1` Int64 slots, and at most that many are written."""
        if self.reader.is_empty():
            return 0

        try:
            # --- Read header ---
            var block_size = self.reader.read_uleb128()
            var miniblock_count = self.reader.read_uleb128()
            # total_count from header (may differ from num_values)
            _ = self.reader.read_uleb128()
            var first_value = self.reader.read_zigzag_varint()

            # `<= 0`, not `== 0`: a ten-byte varint decodes to a negative
            # Int, and a negative miniblock size would step the reader
            # BACKWARDS past bytes it already read. A block size above
            # `_MAX_BLOCK_SIZE` is refused for the same reason.
            if (
                miniblock_count <= 0
                or block_size <= 0
                or block_size > _MAX_BLOCK_SIZE
            ):
                output[] = Int64(first_value)
                return 1

            var miniblock_size = block_size // miniblock_count
            if miniblock_size == 0:
                output[] = Int64(first_value)
                return 1

            # Output first value.
            output[] = Int64(first_value)
            var current_value = first_value
            var values_decoded = 1

            # --- Decode blocks ---
            # _unpack_miniblock needs raw pointer + offset for bit-level access,
            # so we extract origin-tied views from the reader (current_view),
            # then advance the reader after each block. The view keeps the
            # borrow alive until the inner loop completes.
            while values_decoded < num_values and not self.reader.is_empty():
                # Read min_delta for this block.
                var min_delta = self.reader.read_zigzag_varint()

                # Read bit widths for each miniblock.
                if self.reader.remaining() < miniblock_count:
                    break

                # Snapshot the bit-width bytes via an origin-tied view,
                # then advance. We read the values IMMEDIATELY into an
                # InlineArray so the view can be dropped before advance.
                # SAFETY: bounds-checked (remaining() >= miniblock_count).
                var bw_snapshot_view = self.reader.current_view()
                var bw_snap_ptr = bw_snapshot_view._unsafe_ptr()
                # Copy bit widths into a local array so the view does not
                # outlive the upcoming mutations of self.reader.
                var bws = List[UInt8](capacity=miniblock_count)
                for i in range(miniblock_count):
                    bws.append((bw_snap_ptr + i)[])
                _ = bw_snapshot_view^
                self.reader.advance(miniblock_count)

                # Decode each miniblock.
                # _unpack_miniblock needs raw pointer access for bit extraction.
                # current_view() gives us an origin-tied view of the packed
                # data; the pointer is valid as long as the view lives.
                var miniblock_data_view = self.reader.current_view()
                var miniblock_data_ptr = miniblock_data_view._unsafe_ptr()
                var miniblock_data_remaining = self.reader.remaining()
                var miniblock_bytes_consumed = 0

                for mb_idx in range(miniblock_count):
                    if values_decoded >= num_values:
                        break

                    # SAFETY: bws was snapshotted from reader.current_view()
                    # before advance; mb_idx < miniblock_count so access is in
                    # bounds.
                    var bw = Int(bws[mb_idx])
                    var values_in_mb = min(miniblock_size, num_values - values_decoded)
                    var packed_bytes = (miniblock_size * bw + 7) >> 3

                    var result = _unpack_miniblock(
                        miniblock_data_ptr,
                        miniblock_bytes_consumed,
                        miniblock_data_remaining,
                        bw,
                        values_in_mb,
                        min_delta,
                        current_value,
                        output,
                        values_decoded,
                    )
                    current_value = result[0]
                    values_decoded += result[1]

                    miniblock_bytes_consumed += packed_bytes

                # Advance reader past all miniblock packed data.
                var skip = min(miniblock_bytes_consumed, self.reader.remaining())
                self.reader.advance(skip)

            # Pad with last value if we decoded fewer than requested.
            while values_decoded < num_values:
                (output + values_decoded)[] = Int64(current_value)
                values_decoded += 1

            return values_decoded
        except:
            # On any read error, return what we have so far.
            return 0

    def decode_int32[
        o: MutOrigin
    ](mut self, num_values: Int, output: Span[Int32, o]) -> Int:
        """Decode DELTA_BINARY_PACKED values into Int32 output buffer.

        Decodes as Int64 internally, then narrows to Int32. This avoids
        duplicating the decode logic.

        Args:
            num_values: Number of values to decode; at most `len(output)`
                are decoded.
            output: Buffer for decoded Int32 values.

        Returns:
            Number of values actually decoded.
        """
        var n = min(num_values, len(output))
        if n <= 0:
            return 0
        # SAFETY: the core writes at most `n <= len(output)` slots.
        return self._decode_int32_ptr(n, output.unsafe_ptr())

    def _decode_int32_ptr[
        o: Origin[mut=True]
    ](
        mut self, num_values: Int, output: UnsafePointer[Int32, o]
    ) -> Int:
        """The core of `decode_int32`: `output` holds at least
        `num_values >= 1` Int32 slots, and at most that many are written."""

        # Decode into a temporary i64 buffer, then narrow.
        from std.memory import alloc

        var i64_buf = alloc[Int64](num_values)
        var decoded = self._decode_int64_ptr(num_values, i64_buf)

        # PERF-CRITICAL: SIMD i64->i32 narrowing via .cast.
        # SIMD[DType.int64, N].cast[DType.int32]() generates NEON `xtn`
        # (extract narrow). Process 4 i64s per iteration (i.e. load 32B
        # into v0.2d+v1.2d, xtn to v2.4s, store 16B).
        comptime WN: Int = 4
        var simd_end = (decoded // WN) * WN
        var i = 0
        while i < simd_end:
            var i64_vec = (i64_buf + i).load[width=WN]()
            var i32_vec = i64_vec.cast[DType.int32]()
            (output + i).store[width=WN](i32_vec)
            i += WN
        while i < decoded:
            (output + i)[] = Int32((i64_buf + i)[])
            i += 1

        i64_buf.free()
        return decoded

    # =========================================================================
    # The RESUMABLE entry points (ADDITIVE; one-shot untouched).
    # =========================================================================

    def begin_resumable(mut self, total_values: Int) -> Bool:
        """Parse the DELTA_BINARY_PACKED page header ONCE and arm the resumable
        path for a stream of exactly `total_values` values.

        `total_values` plays the role the one-shot `decode_int64`'s `num_values`
        argument plays: it is the DECLARED value count of the page (the V1 data
        page header's `num_values`), it bounds the walk, and a stream that ends
        early is PADDED with the last decoded value — byte-for-byte the one-shot
        tail behaviour, so a page decoded in chunks equals the same page decoded
        in one shot.

        Returns False (leaving the decoder DISARMED) for an empty stream, a
        non-positive count, an unreadable header, or the DEGENERATE geometry
        `block_size == 0` / `miniblock_count == 0` / `miniblock_size == 0`.

        ⚠ THE DEGENERATE CASE IS THE ONE PLACE THE TWO PATHS DIFFER ON PURPOSE.
        `decode_int64` answers a degenerate header by emitting `first_value`
        alone and returning 1 — a SHORT decode dressed as a success, which a
        streaming caller cannot distinguish from a drained page. `begin_
        resumable` REFUSES instead, so a streaming cursor declines the
        chunk at page-open and the caller falls back to the whole-row-group
        decode (which then reproduces exactly the one-shot bytes). A 4-byte
        hostile page whose `miniblock_count` is 0 is that shape.
        """
        self._res_armed = False
        self._res_done = False
        self._res_pending = List[Int64]()
        self._res_pending_off = 0
        self._res_bws = List[UInt8]()
        self._res_mb_idx = 0
        self._res_values_produced = 0
        self._res_min_delta = 0
        if total_values <= 0 or self.reader.is_empty():
            return False
        try:
            var block_size = self.reader.read_uleb128()
            var miniblock_count = self.reader.read_uleb128()
            # total_count from the header — the DECLARED bound is the caller's
            # `total_values` (mirrors the one-shot, which likewise discards it).
            _ = self.reader.read_uleb128()
            var first_value = self.reader.read_zigzag_varint()
            if (
                miniblock_count <= 0
                or block_size <= 0
                or block_size > _MAX_BLOCK_SIZE
            ):
                return False
            var miniblock_size = block_size // miniblock_count
            if miniblock_size <= 0:
                return False
            self._res_miniblock_count = miniblock_count
            self._res_miniblock_size = miniblock_size
            self._res_bound = total_values
            self._res_current_value = first_value
            # `_res_mb_idx == miniblock_count` means "no live block" -> the
            # first miniblock walk reads a block header. Set it so the FIRST
            # value (which the header carries, not a delta) is emitted before
            # any block is read.
            self._res_mb_idx = miniblock_count
            self._res_armed = True
            return True
        except:
            return False

    @always_inline
    def resume_armed(self) -> Bool:
        """True iff `begin_resumable` accepted this page (the resumable path is
        live). False means the caller must use the one-shot path or decline."""
        return self._res_armed

    @always_inline
    def resume_values_returned(self) -> Int:
        """Values HANDED BACK to the caller so far across `resume_fill_*` calls.

        Not the same as values PRODUCED: a chunk boundary inside a miniblock
        leaves up to `miniblock_size - 1` produced-but-unreturned values staged
        in `_res_pending`, and those are not returned yet."""
        return self._res_values_produced - (
            len(self._res_pending) - self._res_pending_off
        )

    def resume_fill_int64(
        mut self,
        mut dst: OwnedAlignedBuffer,
        dst_elem_offset: Int,
        max_values: Int,
    ) raises -> Int:
        """Decode AT MOST `max_values` further values into `dst` as Int64,
        starting at Int64 slot `dst_elem_offset`, and return how many were
        written (0 once the page is drained). The decoder is left ready to
        continue from the next value.

        `max_values` is a HARD cap, not a hint — a boundary landing inside a
        miniblock stages the remainder rather than overrunning the caller.

        ENCAPSULATION: the destination crosses the module boundary
        as an `OwnedAlignedBuffer`, never as an `UnsafePointer`.

        Raises:
            Error if `dst` holds fewer than `dst_elem_offset + max_values`
            Int64 slots, or `dst_elem_offset` is negative.
        """
        if not self._res_armed or max_values <= 0:
            return 0
        _require_resume_dst_extent(dst.len(), dst_elem_offset, max_values, 8)
        # SAFETY: `dst` is the caller's buffer; `view_mut()` derives an
        # origin-tied interior pointer bounded by `dst`'s length, which holds
        # `dst_elem_offset + max_values` Int64 slots (checked above). The
        # pointer does not outlive this call.
        var dv = dst.view_mut()
        var p = dv._unsafe_ptr().bitcast[Int64]() + dst_elem_offset
        return self._resume_fill_i64(p, max_values)

    def resume_fill_int32(
        mut self,
        mut dst: OwnedAlignedBuffer,
        dst_elem_offset: Int,
        max_values: Int,
    ) raises -> Int:
        """Int32 sibling of `resume_fill_int64` — decodes as Int64 (the format
        accumulates deltas in i64 per the spec) then narrows, exactly as the
        one-shot `decode_int32` does.

        The narrowing stage is a per-call LOCAL rather than a decoder field on
        purpose: taking an interior pointer into a `self`-owned scratch while
        `_resume_fill_i64` needs `mut self` is a double borrow of `self`. One
        allocation per CHUNK (not per value, not per page) on the INT32 arm
        only; the INT64 arm — every 8-byte id/timestamp column
        — decodes straight into the caller's buffer with no staging at all.

        Raises:
            Error if `dst` holds fewer than `dst_elem_offset + max_values`
            Int32 slots, or `dst_elem_offset` is negative.
        """
        if not self._res_armed or max_values <= 0:
            return 0
        _require_resume_dst_extent(dst.len(), dst_elem_offset, max_values, 4)
        var tmp = List[Int64](capacity=max_values)
        tmp.resize(max_values, Int64(0))
        # SAFETY: `tmp` is a local owned List of exactly `max_values` Int64s,
        # alive across the call; the pointer is origin-tied to it and never
        # escapes.
        var n = self._resume_fill_i64(tmp.unsafe_ptr(), max_values)
        if n <= 0:
            return n
        # SAFETY: `dst` holds `dst_elem_offset + max_values >= dst_elem_offset
        # + n` Int32 slots (checked above); `view_mut()` bounds the interior
        # pointer by `dst`'s length.
        var dv = dst.view_mut()
        var out = dv._unsafe_ptr().bitcast[Int32]() + dst_elem_offset
        # SIMD i64->i32 narrowing, mirroring `decode_int32`'s xtn loop.
        comptime WN: Int = 4
        var simd_end = (n // WN) * WN
        var i = 0
        while i < simd_end:
            var v64 = (tmp.unsafe_ptr() + i).load[width=WN]()
            (out + i).store[width=WN](v64.cast[DType.int32]())
            i += WN
        while i < n:
            (out + i)[] = Int32(tmp[i])
            i += 1
        return n

    def _parse_next_block(mut self) -> Bool:
        """Read the next block's `min_delta` + per-miniblock bit widths and
        reset `_res_mb_idx` to 0. Returns False at end-of-stream.

        The two False conditions mirror the one-shot loop's two `break`s
        exactly: an empty reader (`while ... and not self.reader.is_empty()`)
        and fewer bytes left than the bit-width table needs
        (`if self.reader.remaining() < miniblock_count: break`). Matching them
        is what makes a truncated page pad identically on both paths.
        """
        if self.reader.is_empty():
            return False
        var mbc = self._res_miniblock_count
        try:
            var md = self.reader.read_zigzag_varint()
            if self.reader.remaining() < mbc:
                return False
            # SAFETY: bounds-checked directly above (`remaining() >= mbc`). The
            # widths are copied out into an owned List so the origin-tied view
            # dies before the reader is advanced — the same snapshot-then-
            # advance shape `decode_int64` uses.
            var bw_view = self.reader.current_view()
            var bw_ptr = bw_view._unsafe_ptr()
            var bws = List[UInt8](capacity=mbc)
            for i in range(mbc):
                bws.append((bw_ptr + i)[])
            _ = bw_view^
            self.reader.advance(mbc)
            self._res_min_delta = md
            self._res_bws = bws^
            self._res_mb_idx = 0
            return True
        except:
            return False

    # unbounded-decode-extent: reviewed -- every write is `out_ptr + written`
    # (or `+ written + i`, i < room = target - written) and the function
    # returns the moment `written >= target`, where
    # `target = min(max_values, remaining)`. So no slot past `max_values - 1`
    # is ever touched, and `max_values` is a REQUIRED parameter the caller
    # sizes the buffer from -- the extent is in the signature. The guard the
    # linter cannot resolve, `room >= values_in_mb`, is the CHOICE between
    # unpacking a miniblock straight into the caller and staging it; both
    # arms are already inside the `written < target` bound.
    def _resume_fill_i64[
        o: Origin[mut=True]
    ](mut self, out_ptr: UnsafePointer[Int64, o], max_values: Int) -> Int:
        """The resumable core: emit up to `max_values` values at `out_ptr`.

        SAFETY: `out_ptr` must address at least `max_values` Int64 slots. It is
        INTERNAL to this struct — the two public
        entry points derive it from an `OwnedAlignedBuffer` / a local List and
        it never crosses a module boundary. Both entry points return before
        calling it unless the decoder is armed and `max_values > 0`.
        """
        var pending_avail = len(self._res_pending) - self._res_pending_off
        var returned = self._res_values_produced - pending_avail
        var remaining = self._res_bound - returned
        if remaining <= 0:
            return 0
        var target = min(max_values, remaining)
        var written = 0

        # (1) Drain the staged tail of a miniblock a previous call cut short.
        if pending_avail > 0:
            var take = min(pending_avail, target)
            for i in range(take):
                (out_ptr + i)[] = self._res_pending[self._res_pending_off + i]
            self._res_pending_off += take
            written += take
            if self._res_pending_off >= len(self._res_pending):
                self._res_pending = List[Int64]()
                self._res_pending_off = 0
            if written >= target:
                return written

        # (2) The FIRST value is carried by the page header, not by a delta.
        if self._res_values_produced == 0:
            (out_ptr + written)[] = Int64(self._res_current_value)
            written += 1
            self._res_values_produced = 1
            if written >= target:
                return written

        # (3) Walk miniblocks, reading a block header whenever the current
        # block's width table runs out.
        while written < target and not self._res_done:
            if self._res_mb_idx >= self._res_miniblock_count:
                if not self._parse_next_block():
                    self._res_done = True
                    break
            var stream_left = self._res_bound - self._res_values_produced
            if stream_left <= 0:
                break  # cov: unreachable written grows with values produced, so stream_left >= target - written > 0
            # Hoist every field read BEFORE the reader view is taken, so no
            # field access happens while the origin-tied borrow is live.
            var bw = Int(self._res_bws[self._res_mb_idx])
            var min_delta = self._res_min_delta
            var cur = self._res_current_value
            var mb_size = self._res_miniblock_size
            var values_in_mb = min(mb_size, stream_left)
            # A miniblock's packed body is ALWAYS `miniblock_size * bw` bits,
            # even when the tail values are padding, and a width-0 miniblock
            # occupies ZERO bytes (all deltas equal `min_delta`). Identical
            # arithmetic to the one-shot's `packed_bytes`.
            var packed_bytes = (mb_size * bw + 7) >> 3
            var room = target - written
            if room >= values_in_mb:
                # Whole miniblock fits — unpack STRAIGHT into the caller.
                # SAFETY: the view covers every unread byte and dies before the
                # reader is advanced below; `_unpack_miniblock` bounds its own
                # reads by the length passed. `out_ptr + written` has
                # `values_in_mb <= room` slots left.
                var mv = self.reader.current_view()
                var mp = mv._unsafe_ptr()
                var mrem = self.reader.remaining()
                var res = _unpack_miniblock(
                    mp, 0, mrem, bw, values_in_mb, min_delta, cur,
                    out_ptr, written,
                )
                _ = mv^
                self._res_current_value = res[0]
                written += res[1]
            else:
                # The chunk boundary lands INSIDE this miniblock: unpack it
                # whole into a local stage, hand back `room`, keep the rest.
                var staged = List[Int64](capacity=values_in_mb)
                staged.resize(values_in_mb, Int64(0))
                # SAFETY: as above for `mp`; `staged` is a local owned List of
                # exactly `values_in_mb` Int64 slots, alive across the call.
                var mv = self.reader.current_view()
                var mp = mv._unsafe_ptr()
                var mrem = self.reader.remaining()
                var res = _unpack_miniblock(
                    mp, 0, mrem, bw, values_in_mb, min_delta, cur,
                    staged.unsafe_ptr(), 0,
                )
                _ = mv^
                self._res_current_value = res[0]
                for i in range(room):
                    (out_ptr + written + i)[] = staged[i]
                self._res_pending = staged^
                self._res_pending_off = room
                written += room
            self._res_values_produced += values_in_mb
            self._res_mb_idx += 1
            var skip = min(packed_bytes, self.reader.remaining())
            if skip > 0:
                try:
                    self.reader.advance(skip)
                except:
                    self._res_done = True  # cov: unreachable skip <= remaining(), so advance cannot raise

        # (4) Tail-pad with the last decoded value when the stream ended before
        # the declared count — the one-shot does exactly this
        # (`while values_decoded < num_values: output[...] = current_value`).
        while written < target:
            (out_ptr + written)[] = Int64(self._res_current_value)
            written += 1
            self._res_values_produced += 1
        return written


def _require_resume_dst_extent(
    dst_len: Int, dst_elem_offset: Int, max_values: Int, elem_size: Int
) raises:
    """Refuse a `resume_fill_*` destination that cannot hold `max_values`
    elements of `elem_size` bytes from element `dst_elem_offset` on.

    The bound is taken in elements (`dst_len // elem_size`) and nothing is
    multiplied: `(dst_elem_offset + max_values) * elem_size` wraps for a
    `max_values` near 2^64 / elem_size (2^61 Int64s is 0 bytes after the
    wrap), and a check on the wrapped product would pass."""
    var dst_slots = dst_len // elem_size
    if (
        dst_elem_offset < 0
        or dst_elem_offset > dst_slots
        or max_values > dst_slots - dst_elem_offset
    ):
        raise Error(
            "parquet: DELTA_BINARY_PACKED destination too small: "
            + String(max_values)
            + " values of "
            + String(elem_size)
            + " bytes from element "
            + String(dst_elem_offset)
            + " do not fit "
            + String(dst_len)
            + " bytes"
        )


# =============================================================================
# delta_binary_packed_byte_count — calculate bytes consumed without full decode
# =============================================================================


def delta_binary_packed_byte_count(
    data: Span[UInt8, _],
    num_values: Int,
) -> Int:
    """Calculate the byte count consumed by a DELTA_BINARY_PACKED stream.

    Parses the header and block structure to determine exactly how many
    bytes the delta-encoded data occupies, without fully decoding values.
    This is needed by DELTA_LENGTH_BYTE_ARRAY and DELTA_BYTE_ARRAY to
    find where the delta-encoded lengths end and raw bytes begin.

    Args:
        data: The DELTA_BINARY_PACKED encoded stream (and what follows it).
        num_values: Number of values encoded in the stream.

    Returns:
        Number of bytes consumed by the delta-encoded stream.
    """
    var data_len = len(data)
    if num_values == 0 or data_len == 0:
        return 0

    # Copy data from caller's buffer into owned List[UInt8].
    var buf = List[UInt8](capacity=data_len)
    for i in range(data_len):
        buf.append(data[i])
    var reader = ByteBuffer(buf^)

    try:
        # Read header: block_size, miniblock_count, total_count, first_value.
        var block_size = reader.read_uleb128()
        var miniblock_count = reader.read_uleb128()
        # total_count from header — may differ from num_values
        _ = reader.read_uleb128()
        # first_value consumed
        _ = reader.read_zigzag_varint()

        # `<= 0` and the block size bound: see `DeltaDecoder.decode_int64`.
        if (
            miniblock_count <= 0
            or block_size <= 0
            or block_size > _MAX_BLOCK_SIZE
        ):
            return min(reader.position(), data_len)

        var miniblock_size = block_size // miniblock_count
        # First value already consumed from the count.
        var values_remaining = num_values - 1 if num_values > 0 else 0

        while values_remaining > 0 and not reader.is_empty():
            # Skip min_delta.
            _ = reader.read_zigzag_varint()

            # Read bit widths.
            if reader.remaining() < miniblock_count:
                break

            # Snapshot bit widths via an origin-tied view, then advance.
            # SAFETY: bounds-checked (remaining() >= miniblock_count).
            var bw_view = reader.current_view()
            var bw_snap = bw_view._unsafe_ptr()
            var bws = List[UInt8](capacity=miniblock_count)
            for i in range(miniblock_count):
                bws.append((bw_snap + i)[])
            _ = bw_view^
            reader.advance(miniblock_count)

            # Skip miniblock data.
            for mb_idx in range(miniblock_count):
                if values_remaining == 0:
                    break
                # SAFETY: bws snapshotted before advance; mb_idx < miniblock_count.
                var bw = Int(bws[mb_idx])
                var packed_bytes = (miniblock_size * bw + 7) >> 3
                var skip = min(packed_bytes, reader.remaining())
                reader.advance(skip)
                values_remaining = max(0, values_remaining - miniblock_size)

        return min(reader.position(), data_len)
    except:
        return min(data_len, data_len)
