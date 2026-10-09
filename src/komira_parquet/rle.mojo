# =============================================================================
# RLE / Bit-Packing Hybrid Decoder — Parquet's most important encoding
# =============================================================================
#
# Used for definition/repetition levels, boolean columns, and RLE_DICTIONARY.
#
# Format: alternating runs of RLE (repeated values) and BIT_PACKED (groups
# of values packed at a fixed bit width).
#
# Each block starts with a varint header:
#   - If header & 1 == 0: RLE run  (header >> 1 = repeat count,
#                                    followed by ceil(bit_width/8) bytes of value)
#   - If header & 1 == 1: Bit-packed group (header >> 1 = num_groups,
#                                           each group = 8 values,
#                                           followed by num_groups * bit_width bytes)
#
# Reference: parquet-format Encodings.md, RLE / Bit-Packing Hybrid (3)
#
# SAFETY: every public function takes Spans: the encoded bytes as a
# `Span[UInt8]` and the decoded values as a mutable `Span[Int32]`, and no
# public function writes past the end of its output Span. The private
# bit-unpack helpers take the raw pointers the public functions derive from
# those Spans. Input data is read through ByteBuffer, which owns a copy of
# the encoded bytes and encapsulates the raw pointer internally.
# =============================================================================

from std.memory import unsafe_memcpy, unsafe_memset

from komira_buffer.byte_buffer import ByteBuffer

from .rle_bitunpack import (
    _unpack_bitwidth1,
    _unpack_bitwidth2,
    _unpack_bitwidth4,
    _unpack_bitwidth8,
    _unpack_generic,
)


# A run header at or above this is corrupt: a ten-byte varint decodes to a
# NEGATIVE Int, and a huge one overflows `num_groups * 8` and
# `num_groups * bit_width`. Either would turn a run's count or byte length
# negative, so the decoder would memset a negative length or step its reader
# backwards. No page holds a run of 2^56 values.
comptime _MAX_RUN_HEADER = 1 << 57


# =============================================================================
# Varint helpers (legacy API — kept for external callers)
# =============================================================================


@always_inline
def read_uleb128(data: Span[UInt8, _], offset: Int) -> Tuple[Int, Int]:
    """Read a ULEB128 varint from data at the given offset.

    Returns (value, bytes_consumed). The read stops at the end of `data`: a
    varint cut short by the end of the input returns the bits read so far and
    the bytes it consumed, and an offset outside `data` returns (0, 0).

    NOTE: Prefer ByteBuffer.read_uleb128() for new code. This function is
    retained for callers that have not yet migrated to ByteBuffer.
    """
    var result = 0
    var shift = 0
    var pos = offset
    while pos >= 0 and pos < len(data):
        var byte = Int(data[pos])
        result = result | ((byte & 0x7F) << shift)
        pos += 1
        if byte & 0x80 == 0:
            break
        shift += 7
        if shift >= 64:
            break
    return (result, pos - offset)


# =============================================================================
# RleDecoder struct
# =============================================================================


@fieldwise_init
struct RleRunResult(Copyable, Movable):
    """Run-aligned result of `RleDecoder.decode_run_int32`.

    Fields:
        written: Values written into the caller's buffer this call.
        rle_value: For a truncated RLE run, the repeated value (so the caller can
            continue it); meaningful only when `rle_leftover > 0`.
        rle_leftover: Values of a truncated RLE run NOT yet emitted (0 if none).
        exhausted: True when the stream had no further runs (`written == 0`).
    """

    var written: Int
    var rle_value: Int32
    var rle_leftover: Int
    var exhausted: Bool


struct RleDecoder(Movable):
    """Decodes RLE/bit-packed hybrid encoded data.

    This is the core decoder for Parquet definition levels, repetition levels,
    dictionary indices, and boolean pages encoded with RLE_DICTIONARY.

    Format: Each block starts with a varint header:
      - If header & 1 == 0: RLE run (header >> 1 = count, followed by value)
      - If header & 1 == 1: Bit-packed group (header >> 1 = num_groups of 8,
                            followed by packed values)

    Fields:
        reader: ByteBuffer cursor over the encoded byte stream (owns data).
        bit_width: Number of bits per value (1..32).
    """

    var reader: ByteBuffer
    var bit_width: Int
    # Mid-bitpacked-run resume state for
    # `decode_run_int32` ONLY. `_bp_groups_left` > 0 means the decoder is PARKED
    # inside a bitpacked run with that many 8-value groups not yet decoded;
    # `_bp_value_off` is the run's first global value index already consumed.
    # The reader cursor sits at the next UNCONSUMED group's packed bytes. Default
    # 0 — `decode_int32` (the legacy whole-run path) NEVER touches these, so its
    # byte-output is unchanged.
    var _bp_groups_left: Int
    var _bp_value_off: Int

    def __init__(
        out self,
        data: Span[UInt8, _],
        bit_width: Int,
    ) raises:
        """Construct an RleDecoder.

        Copies the encoded data from the Span into an owned ByteBuffer.
        The caller's buffer does not need to remain alive after construction.

        Args:
            data: The encoded byte stream.
            bit_width: Number of bits per value (0..32).
        """
        # Bulk memcpy the encoded page into
        # the owned buffer instead of a scalar per-byte List.append loop. The
        # old loop read every input byte twice (once to copy here, once to
        # unpack) at scalar-append throughput (~hundreds of MB/s) — a full
        # extra pass over every compressed page before any unpacking. A single
        # `resize` + `memcpy` does the copy at vectorized memcpy throughput.
        # SAFETY: `data` holds `data_len` valid bytes (its own length);
        # `buf.unsafe_ptr()` is valid for `data_len` bytes after the
        # resize and the regions do not overlap (decompressed page vs fresh
        # List allocation).
        # =================================================================
        # The bit-width bound.
        #
        # `bit_width` is the FIRST BODY BYTE of an RLE_DICTIONARY page —
        # a raw 0..255 attacker byte. The Parquet spec bounds bit widths at
        # 32 and nothing enforced it. For bit_width >= 65 the runtime
        # unpacker (`_unpack_generic_runtime`) computes
        # `avail = (64 - bit_offset) // bit_width == 0`, so `to_extract`
        # is 0, nothing is written, `bit_pos += 0`, and the
        # `while written < max_values` loop SPINS FOREVER on identical
        # state with no exit and no raise — an unconditional hang from a
        # ONE-BYTE edit. For 33..64 it does not hang but `mask` collapses
        # to -1 and the decoder emits garbage codes that then feed the
        # dictionary gather.
        #
        # Rejected at CONSTRUCTION so every caller (the dictionary page
        # decoders, the def/rep-level decoders) inherits the bound without
        # a copy of the check, and so no per-value cost is paid inside the
        # unpack loops.
        # =================================================================
        if bit_width < 0 or bit_width > 32:
            raise Error(
                "parquet: corrupt RLE stream: bit_width "
                + String(bit_width)
                + " is outside the Parquet-legal range [0, 32]"
            )

        var data_len = len(data)
        var buf = List[UInt8](capacity=data_len)
        if data_len > 0:
            buf.resize(data_len, UInt8(0))
            unsafe_memcpy(
                dest=buf.unsafe_ptr(), src=data.unsafe_ptr(), count=data_len
            )
        self.reader = ByteBuffer(buf^)
        self.bit_width = bit_width
        self._bp_groups_left = 0
        self._bp_value_off = 0

    def decode_int32[
        o: MutOrigin
    ](mut self, num_values: Int, output: Span[Int32, o]) -> Int:
        """Decode up to num_values values into the output buffer.

        Args:
            num_values: Maximum number of values to decode; at most
                `len(output)` are decoded.
            output: Buffer to write decoded Int32 values into.

        Returns:
            The number of values actually decoded.
        """
        # SAFETY: the core writes at most its `num_values` slots, which is
        # at most `len(output)`.
        return self._decode_int32_ptr(
            min(num_values, len(output)), output.unsafe_ptr()
        )

    def _decode_int32_ptr[
        o: Origin[mut=True]
    ](
        mut self, num_values: Int, output: UnsafePointer[Int32, o]
    ) -> Int:
        """The core of `decode_int32`: `output` holds at least `num_values`
        Int32 slots."""
        var decoded = 0

        while not self.reader.is_empty() and decoded < num_values:
            # Read varint header via ByteBuffer.
            # NOTE: read_uleb128 raises on truncated data; we catch that
            # gracefully by checking is_empty() in the loop guard.
            try:
                var header = self.reader.read_uleb128()
                if header < 0 or header >= _MAX_RUN_HEADER:
                    break

                if header & 1 == 1:
                    # --- Bit-packed run ---
                    var num_groups = header >> 1
                    var values_in_run = num_groups * 8
                    var total_bytes = num_groups * self.bit_width
                    var to_decode = min(values_in_run, num_values - decoded)
                    var avail_bytes = min(
                        total_bytes, self.reader.remaining()
                    )

                    # Get an origin-tied view of the packed data. The
                    # ByteBuffer has already bounds-checked; the unpack
                    # helpers use their own pack_len guard. The view's
                    # origin is tied to `self.reader` (self), so the
                    # compiler tracks liveness through the unpack call.
                    # SAFETY: pack_view keeps the borrow alive during the
                    # _unpack_* call below; pack_ptr does not outlive it.
                    var pack_view = self.reader.current_view()
                    var pack_ptr = pack_view._unsafe_ptr()

                    if self.bit_width == 1:
                        var w = _unpack_bitwidth1(
                            pack_ptr, avail_bytes, output, decoded, to_decode
                        )
                        decoded += w
                    elif self.bit_width == 2:
                        var w = _unpack_bitwidth2(
                            pack_ptr, avail_bytes, output, decoded, to_decode
                        )
                        decoded += w
                    elif self.bit_width == 4:
                        var w = _unpack_bitwidth4(
                            pack_ptr, avail_bytes, output, decoded, to_decode
                        )
                        decoded += w
                    elif self.bit_width == 8:
                        var w = _unpack_bitwidth8(
                            pack_ptr, avail_bytes, output, decoded, to_decode
                        )
                        decoded += w
                    else:
                        var w = _unpack_generic(
                            pack_ptr,
                            avail_bytes,
                            self.bit_width,
                            output,
                            decoded,
                            to_decode,
                        )
                        decoded += w

                    # Advance past the packed bytes (may advance less than
                    # total_bytes if near end of buffer, but we must advance
                    # by the format-specified amount to stay in sync).
                    var skip = min(total_bytes, self.reader.remaining())
                    try:
                        self.reader.advance(skip)
                    except:
                        pass  # cov: unreachable skip <= remaining(), so advance cannot raise

                else:
                    # --- RLE run ---
                    var run_len = header >> 1
                    var value_bytes = (self.bit_width + 7) >> 3

                    if self.reader.remaining() < value_bytes:
                        break

                    # Read the repeated value (little-endian, up to 4 bytes).
                    var value = Int32(0)
                    for b in range(min(value_bytes, 4)):
                        try:
                            var byte_val = self.reader.read_byte()
                            value = value | (Int32(byte_val) << Int32(b * 8))
                        except:
                            break  # cov: unreachable remaining() >= value_bytes was checked, so read_byte cannot raise

                    var count = min(run_len, num_values - decoded)
                    # Fill the output with the repeated value.
                    if value == Int32(0):
                        # SAFETY: `output` is a function parameter with a
                        # caller-supplied mutable origin (origin-polymorphic
                        # via [o: Origin[mut=True]]). `output + decoded`
                        # preserves that origin. We bitcast the pointee
                        # type to UInt8 for the byte-level memset; no
                        # address laundering is involved.
                        unsafe_memset(
                            (output + decoded).bitcast[UInt8](),
                            0,
                            count * 4,
                        )
                    elif count >= 8:
                        var dest = output + decoded
                        var pairs = count >> 1
                        for i in range(pairs):
                            (dest + i * 2)[] = value
                            (dest + i * 2 + 1)[] = value
                        if count & 1 != 0:
                            (dest + count - 1)[] = value
                    else:
                        for i in range(count):
                            (output + decoded + i)[] = value
                    decoded += count
            except:
                break

        return decoded

    def decode_run_int32[
        o: MutOrigin
    ](mut self, output: Span[Int32, o], cap: Int) -> RleRunResult:
        """Decode the next run into `output` (up to `cap` values, and never
        more than `len(output)`) and return a run-aligned result; see
        `_decode_run_int32_ptr`. A `cap` of 0 or less writes nothing: an RLE
        run is then parked whole in `rle_leftover`."""
        # SAFETY: the core writes at most its `cap` slots, which is clamped to
        # [0, len(output)]. Without the lower clamp a negative `cap` reaches
        # the RLE arm as a negative count: a negative memset length and a
        # negative `written`.
        return self._decode_run_int32_ptr(
            output.unsafe_ptr(), max(0, min(cap, len(output)))
        )

    def _decode_run_int32_ptr[
        o: Origin[mut=True]
    ](
        mut self, output: UnsafePointer[Int32, o], cap: Int
    ) -> RleRunResult:
        """Decode the next run into `output` (up to `cap` values) and return a
        run-aligned result so the caller can resume WITHOUT data loss.

        Returns an `RleRunResult` carrying:
          * `written`   — values written into `output` (>= 0).
          * `rle_value` — for an RLE run truncated by `cap`, the repeated value
            so the caller can continue it; meaningful only when `rle_leftover>0`.
          * `rle_leftover` — for an RLE run whose `run_len > cap`, the values NOT
            yet emitted (caller emits them on the next call); 0 otherwise.
          * `exhausted` — True when the stream had no more runs (written==0).

        The leaf `decode_int32` is NOT
        resumable mid-run — `decode_int32(N)` advances past the WHOLE current run
        even when N < run-size, dropping the tail (the mid-run non-resumability
        that defeats sub-page <256KB chunking on a single large page). This method
        is run-aligned: a BITPACKED run is decoded in whole 8-value groups, at
        most `cap // 8` of them per call, with the rest parked for the next call
        (`_decode_bitpacked_groups`); a long RLE run is split safely via the
        `rle_leftover`/`rle_value` continuation (RLE resume needs no byte cursor —
        it is just a repeated value). Byte-identical values to `decode_int32`.

        SAFETY: `output` must hold at least `cap` Int32 slots, and `cap` must
        be >= 0. Every write is bounded by `cap`: an RLE run writes
        `min(run_len, cap)` values, a bitpacked run `8 * min(groups, cap // 8)`.
        """
        # Resume a PARKED bitpacked run first (mid-run continuation).
        if self._bp_groups_left > 0:
            return self._decode_bitpacked_groups(output, cap)
        if self.reader.is_empty():
            return RleRunResult(0, Int32(0), 0, True)
        try:
            var header = self.reader.read_uleb128()
            if header < 0 or header >= _MAX_RUN_HEADER:
                return RleRunResult(0, Int32(0), 0, True)
            if header & 1 == 1:
                # Bitpacked group block — decoded GROUP-ALIGNED, resumable.
                self._bp_groups_left = header >> 1
                self._bp_value_off = 0
                return self._decode_bitpacked_groups(output, cap)
            else:
                # RLE run.
                var run_len = header >> 1
                var value_bytes = (self.bit_width + 7) >> 3
                if self.reader.remaining() < value_bytes:
                    return RleRunResult(0, Int32(0), 0, True)
                var value = Int32(0)
                for b in range(min(value_bytes, 4)):
                    try:
                        var byte_val = self.reader.read_byte()
                        value = value | (Int32(byte_val) << Int32(b * 8))
                    except:
                        break  # cov: unreachable remaining() >= value_bytes was checked, so read_byte cannot raise
                var count = min(run_len, cap)
                if value == Int32(0):
                    # SAFETY: `output` holds >= cap slots; count <= cap.
                    unsafe_memset(output.bitcast[UInt8](), 0, count * 4)
                else:
                    for i in range(count):
                        (output + i)[] = value
                var leftover = run_len - count
                return RleRunResult(count, value, leftover, False)
        except:
            return RleRunResult(0, Int32(0), 0, True)

    def _decode_bitpacked_groups[
        o: Origin[mut=True]
    ](
        mut self, output: UnsafePointer[Int32, o], cap: Int
    ) -> RleRunResult:
        """Decode GROUP-ALIGNED 8-value groups of the currently-parked bitpacked
        run into `output`, up to `cap` values, advancing the reader past exactly
        the groups consumed and parking the rest (`_bp_groups_left`). This is the
        mid-bitpacked-run resumption that makes a single large bitpacked run (a
        writer may emit a whole column chunk as one run) chunkable into a fixed
        buffer.

        Decodes `g = min(_bp_groups_left, cap // 8)` groups = `g*8` values from
        the reader's CURRENT position (the next unconsumed group), then advances
        the reader by `g * bit_width` bytes. Byte-identical values to
        `decode_int32` because the bitpacked layout is group-local (group `k`'s
        bytes are independent of decode granularity).

        SAFETY: `output` holds >= `cap` Int32 slots; `g*8 <= cap`.
        """
        var groups = min(self._bp_groups_left, cap // 8)
        if groups <= 0:
            # cap < 8 with groups parked — caller must pass cap >= 8. Treat as a
            # no-progress sentinel (not exhausted; the run is still parked).
            return RleRunResult(0, Int32(0), 0, False)
        var to_decode = groups * 8
        var run_bytes = groups * self.bit_width
        var avail_bytes = min(run_bytes, self.reader.remaining())
        # SAFETY: pack_view keeps the borrow alive across the unpack call;
        # pack_ptr does not outlive it. Mirror of decode_int32's bitpacked arm.
        var pack_view = self.reader.current_view()
        var pack_ptr = pack_view._unsafe_ptr()
        var w: Int
        if self.bit_width == 1:
            w = _unpack_bitwidth1(pack_ptr, avail_bytes, output, 0, to_decode)
        elif self.bit_width == 2:
            w = _unpack_bitwidth2(pack_ptr, avail_bytes, output, 0, to_decode)
        elif self.bit_width == 4:
            w = _unpack_bitwidth4(pack_ptr, avail_bytes, output, 0, to_decode)
        elif self.bit_width == 8:
            w = _unpack_bitwidth8(pack_ptr, avail_bytes, output, 0, to_decode)
        else:
            w = _unpack_generic(
                pack_ptr, avail_bytes, self.bit_width, output, 0, to_decode
            )
        var skip = min(run_bytes, self.reader.remaining())
        try:
            self.reader.advance(skip)
        except:
            pass  # cov: unreachable skip <= remaining(), so advance cannot raise
        self._bp_groups_left -= groups
        self._bp_value_off += to_decode
        return RleRunResult(w, Int32(0), 0, False)


# =============================================================================
# Convenience functions
# =============================================================================


def decode_rle_int32[
    o_out: MutOrigin
](
    data: Span[UInt8, _],
    bit_width: Int,
    num_values: Int,
    output: Span[Int32, o_out],
) raises -> Int:
    """Decode RLE/bit-packed hybrid data into Int32 output buffer.

    Convenience wrapper around RleDecoder.

    Args:
        data: The encoded byte stream.
        bit_width: Number of bits per value.
        num_values: Maximum values to decode; at most `len(output)` are.
        output: Output buffer.

    Returns:
        Number of values decoded.
    """
    var decoder = RleDecoder(data, bit_width)
    return decoder.decode_int32(num_values, output)


def validate_level_section_length(encoded_len: Int, data_len: Int) raises:
    """Reject a V1 level-section length prefix that its page cannot contain.

    THE ONE PLACE THE V1 `[4-byte LE length][RLE bytes]` PREFIX IS JUDGED.

    A Parquet V1 data page stores its repetition and definition levels as
    `[4-byte little-endian length][RLE/bit-pack bytes]`, and every decoder of
    that shape hands the caller `bytes_consumed = 4 + encoded_len` so the
    caller can step over the section to reach the values:

        values_ptr += bytes_consumed
        values_len -= bytes_consumed

    `encoded_len` is read with `read_i32_le()` — a **SIGNED** 32-bit integer
    lifted verbatim out of the file. A negative value (e.g. the four bytes
    `00 00 00 80`, i.e. -2147483648) does BOTH halves of the damage at once:
    it walks `values_ptr` ~2 GB **BEFORE** the page buffer, and it *inflates*
    `values_len` by the same amount. Every downstream extent check therefore
    sees a huge POSITIVE remaining length and agrees that the wild pointer is
    fine — the length check does not merely fail to catch this, it is actively
    subverted by it. An oversized positive value is the same defect with the
    pointer walking forward instead of back.

    Validated HERE, at the point the prefix is first read, because the
    consumers cannot recover the truth afterwards: by the time
    `(values_ptr, values_len)` reaches them the corruption is already
    self-consistent. One compare per LEVEL SECTION (i.e. per page), never per
    value.

    Args:
        encoded_len: The declared level-section byte count, as read from the
            file's signed 4-byte little-endian prefix.
        data_len: Total bytes available at the start of the level section,
            prefix included.

    Raises:
        Error naming the declared length and the bytes actually present.
    """
    if encoded_len < 0 or encoded_len > data_len - 4:
        raise Error(
            "parquet: corrupt level section: declared length "
            + String(encoded_len)
            + " does not fit the "
            + String(data_len - 4)
            + " bytes that follow its 4-byte prefix"
        )


def decode_def_levels[
    o_out: MutOrigin
](
    data: Span[UInt8, _],
    num_values: Int,
    output: Span[Int32, o_out],
) raises -> Tuple[Int, Int]:
    """Decode definition levels from a Parquet page.

    Definition levels use bit_width=1 with a 4-byte LE length prefix:
    `decode_levels` with a bit width of 1.

    Format: [4-byte LE length][RLE/bit-pack encoded data]

    Args:
        data: The definition level section and what follows it.
        num_values: Number of definition levels to decode.
        output: Output buffer for decoded levels; holds at least
            `num_values` slots.

    Returns:
        Tuple of (values_decoded, bytes_consumed including 4-byte prefix).

    Raises:
        Error if `output` is shorter than `num_values` or the length prefix
        does not fit `data`.
    """
    return decode_levels(data, num_values, 1, output)


def decode_def_levels_u8(
    src: Span[UInt8, _],
    num_values: Int,
) raises -> List[UInt8]:
    """Decode a Parquet V1 def-level stream (bit_width=1) to a flat u8 row vector.

    Returns a List[UInt8] of length `num_values` where each element is 0 (null)
    or 1 (non-null): the per-page row-order "validity" vector used for
    nullable rank-mapping.

    Bit logic delegated to
    decode_def_levels (which wraps RleDecoder) — no RLE duplication here.

    Args:
        src: The def-level section ([4-byte LE len][RLE]) and what follows it.
        num_values: Number of def-levels to decode (page row count).

    Returns:
        List[UInt8] of length num_values. Empty list if num_values <= 0.
    """
    var out = List[UInt8]()
    if num_values <= 0:
        return out^

    var scratch = List[Int32](capacity=num_values)
    scratch.resize(num_values, Int32(0))

    if len(src) >= 4:
        _ = decode_def_levels(src, num_values, Span(scratch))

    # Reserve + cast each Int32 level to UInt8 (0 or 1). Levels beyond what was
    # decoded stay 0 (null) — defensive for truncated/empty streams.
    out.reserve(num_values)
    for i in range(num_values):
        var lvl = Int(scratch[i])
        # max_def_level for bit_width=1 is always 1; clamp to {0,1}.
        if lvl >= 1:
            out.append(UInt8(1))
        else:
            out.append(UInt8(0))
    return out^


def decode_levels[
    o_out: MutOrigin
](
    data: Span[UInt8, _],
    num_values: Int,
    bit_width: Int,
    output: Span[Int32, o_out],
) raises -> Tuple[Int, Int]:
    """Decode rep/def levels from a Parquet V1 page with arbitrary bit width.

    Parquet V1 level format: [4-byte LE length][RLE/bit-pack encoded data]
    The bit_width is determined by the max level value:
      max_level=0 -> bit_width=0 (no levels stored)
      max_level=1 -> bit_width=1
      max_level=2-3 -> bit_width=2
      max_level=4-7 -> bit_width=3
      etc.

    Args:
        data: The level section and what follows it.
        num_values: Number of levels to decode.
        bit_width: Bits per level value (ceil(log2(max_level + 1))).
        output: Output buffer for decoded Int32 levels; holds at least
            `num_values` slots.

    Returns:
        Tuple of (values_decoded, bytes_consumed including 4-byte prefix).
        A section shorter than its 4-byte prefix, or `num_values == 0`,
        decodes nothing and consumes what there is of the prefix.

    Raises:
        Error if `output` is shorter than `num_values`, if the length prefix
        does not fit `data` (see `validate_level_section_length`), or if
        `bit_width` is outside [0, 32].
    """
    if num_values > len(output):
        raise Error(
            "parquet: level output holds "
            + String(len(output))
            + " values but "
            + String(num_values)
            + " were asked for"
        )
    if bit_width == 0:
        # max_level == 0: all values are 0, no bytes consumed.
        for i in range(num_values):
            output[i] = Int32(0)
        return (num_values, 0)

    var data_len = len(data)
    if data_len < 4 or num_values == 0:
        return (0, min(4, data_len))

    # The 4-byte LE length prefix, a SIGNED i32 out of the file.
    var encoded_len = Int(
        Int32(data[0])
        | (Int32(data[1]) << 8)
        | (Int32(data[2]) << 16)
        | (Int32(data[3]) << 24)
    )

    # A negative `encoded_len` would walk the caller's values pointer BEFORE
    # the page (it steps over the section by `4 + encoded_len`) while
    # INFLATING its remaining length by the same amount, so every length
    # comparison downstream would receive a huge POSITIVE length and pass.
    # Fixing the consumer cannot close that: the consumer is handed a
    # self-consistent lie. It is refused at the source, here.
    validate_level_section_length(encoded_len, data_len)

    var decoder = RleDecoder(data[4 : 4 + encoded_len], bit_width)
    var decoded = decoder.decode_int32(num_values, output)
    return (decoded, 4 + encoded_len)


@always_inline
def bit_width_for_max_level(max_level: Int) -> Int:
    """Compute the minimum bit width needed to represent values 0..max_level.

    Returns 0 when max_level == 0 (no levels needed).
    Returns ceil(log2(max_level + 1)) otherwise.

    Args:
        max_level: The maximum possible level value.

    Returns:
        The bit width (0 to 8 for typical Parquet schemas).
    """
    if max_level == 0:
        return 0
    # Bit width = number of bits to store values [0, max_level].
    var bits = 0
    var v = max_level
    while v > 0:
        bits += 1
        v >>= 1
    return bits
