# =============================================================================
# rle_decode.mojo — ORC integer RLE decode (the 5 RLE families) + boolean RLE
#                   + byte RLE.
# =============================================================================
#
# Spec: https://orc.apache.org/specification/ORCv1/#run-length-encoding
#
# ORC routes ALL integer-shaped data through one of five run-length families:
#   1. RLEv1 (legacy; DIRECT / DICTIONARY ColumnEncoding)
#   2. RLEv2 Short Repeat   (tag 0b00)
#   3. RLEv2 Direct         (tag 0b01)
#   4. RLEv2 Patched Base   (tag 0b10)
#   5. RLEv2 Delta          (tag 0b11)
# plus two non-integer RLE shapes used by other streams:
#   - boolean RLE (PRESENT stream; byte-RLE of bit-packed booleans)
#   - byte RLE    (TINYINT DATA; UNION tag)
#
# A column's DATA / LENGTH / SECONDARY streams pick RLEv1 (DIRECT/DICTIONARY)
# or RLEv2 (DIRECT_V2/DICTIONARY_V2) per the StripeFooter ColumnEncoding. The
# RLEv2 sub-variant is chosen PER RUN by the writer (the top 2 bits of each
# run's first byte) — so a single RLEv2 stream interleaves all four sub-variants.
#
# Signed-ness: integer columns (SHORT/INT/LONG/DATE) are SIGNED — values are
# zigzag-encoded on the wire. LENGTH / dictionary-index / nanos streams are
# UNSIGNED — plain base-128. The decoder takes a `signed` flag and applies
# zigzag-decode to the raw unsigned magnitudes when set. (RLEv2 Direct /
# Patched-Base / Delta bit-pack the zigzagged value; RLEv1 zigzags the varint.)
#
# Performance: the DIRECT bit-unpack is SIMD width-specialized and writes
# directly into a pre-sized output buffer; DELTA fixed-delta is a SIMD
# arithmetic progression. Variable-delta is a scalar prefix sum. All behind the
# same `decode_rle_*` surface.
#
# Encapsulation: every decoder reads a borrowed `Span[UInt8, _]` view and
# returns an owned `List[Int64]` of decoded values. No UnsafePointer crosses
# any module boundary; position threading is explicit via the cursor.
# =============================================================================

from std.memory import bitcast
from std.sys.info import simd_width_of

from komira_simd.bit_unpack import simd_unpack_bits


# =============================================================================
# OrcIntReader — forward cursor over an integer RLE stream (decompressed).
# =============================================================================
#
# Holds a borrowed Span + mutable position. The base-128 varint readers handle
# both the unsigned LEB128 and zigzag-signed conventions ORC uses. Heterogeneous
# tuple returns are awkward on Mojo 1.0.0b1, so position lives in the cursor.

struct OrcIntReader[origin: Origin[mut=False]]:
    """Forward decode cursor over an immutable integer-RLE byte view."""

    var data: Span[UInt8, Self.origin]
    var pos: Int

    def __init__(out self, data: Span[UInt8, Self.origin]):
        self.data = data
        self.pos = 0

    @always_inline
    def at_end(self) -> Bool:
        return self.pos >= len(self.data)

    @always_inline
    def remaining(self) -> Int:
        return len(self.data) - self.pos

    @always_inline
    def read_byte(mut self) raises -> UInt8:
        if self.pos >= len(self.data):
            raise Error("OrcRleError.TRUNCATED: stream overrun reading byte")
        var b = self.data[self.pos]
        self.pos += 1
        return b

    # -------------------------------------------------------------------------
    # Base-128 unsigned varint (LEB128). ORC's `readVulong`.
    # -------------------------------------------------------------------------
    # Raw-pointer fast path. liborc's readVulong is a raw-pointer
    # compare+advance+load per continuation byte. A Span subscript does a
    # bounds check per byte; when there are >= 10 bytes
    # remaining (a full varint can never exceed 10 bytes), we read straight
    # through a raw pointer with NO per-byte bounds check, matching liborc.
    @always_inline
    def read_vulong(mut self) raises -> UInt64:
        if self.remaining() >= 10:
            # SAFETY: `src` points at the next bytes of the reader's immutable
            # span; there are >= 10 bytes available and a vulong is at most 10
            # bytes, so every read below is in-bounds. Read-only; never escapes.
            var src = self.data.unsafe_ptr() + self.pos
            var shift: UInt64 = 0
            var acc: UInt64 = 0
            var i = 0
            while i < 10:
                var b = src[i]
                i += 1
                acc |= (UInt64(b & 0x7F) << shift)
                if (b & 0x80) == 0:
                    self.pos += i
                    return acc
                shift += 7
            raise Error("OrcRleError.MALFORMED_VARINT: vulong > 10 bytes")
        # Near-end-of-buffer fallback: bounds-checked per byte.
        var shift: UInt64 = 0
        var acc: UInt64 = 0
        var count = 0
        while True:
            if self.pos >= len(self.data):
                raise Error("OrcRleError.TRUNCATED: vulong overrun")
            var b = self.data[self.pos]
            self.pos += 1
            count += 1
            acc |= (UInt64(b & 0x7F) << shift)
            if (b & 0x80) == 0:
                break
            shift += 7
            if count >= 10:
                raise Error("OrcRleError.MALFORMED_VARINT: vulong > 10 bytes")
        return acc

    # -------------------------------------------------------------------------
    # Base-128 signed varint (zigzag). ORC's `readVslong`.
    # -------------------------------------------------------------------------
    @always_inline
    def read_vslong(mut self) raises -> Int64:
        var u = self.read_vulong()
        return zigzag_decode(u)


@always_inline
def zigzag_decode(u: UInt64) -> Int64:
    """ORC/Protobuf zigzag decode: (n >>> 1) ^ -(n & 1)."""
    return Int64((u >> 1) ^ (~(u & 1) + 1))


# =============================================================================
# HOSTILE-INPUT BOUNDS. Read this before adding a check.
# =============================================================================
#
# `count` is a value COUNT the caller took from the stripe directory / the
# StripeFooter's dictionarySize — i.e. a number the file's WRITER chose. Every
# decode entry point below turns it into an allocation (`resize`) or a write
# extent, so it needs a bound BEFORE either happens.
#
# The bound is physical, not arbitrary. RLEv2's densest run is a fixed-delta
# run: 4 header/varint bytes for 512 values = 128 values per byte. RLEv1's
# densest is a repeat run: 3 bytes for 130 values = 43 per byte. We allow
# `MAX_RLE_VALUES_PER_BYTE = 512` — a 4x margin over the tightest ratio any
# conforming writer can emit — so this rejects only counts that NO stream of
# that size could physically back. Without it, the decoder would `resize` to
# the declared count first and discover the truncation afterwards; at
# ASSERT=none, a 4-byte stream declaring 2^40 values aborts the process in
# `alloc` ("returned a null pointer") rather than raising.
#
# WHERE THE CHECKS LIVE, AND WHY THERE:
#   - `count` vs stream size: ONCE per decode call, at the public entry point,
#     before the destination is sized. Not per value, not per run.
#   - `cursor + run_len <= count`: ONCE per RUN (a run is 1..512 values), in
#     each `_decode_*` arm right after the run header is parsed. Without it a
#     run header could declare 512 values into a 1-value destination; the
#     invariant is not ours to guarantee, because the file's author picks
#     `run_len`. Per-run is ~1/512 the cost of per-value and is the coarsest
#     granularity that is still sound.
#   - patch index vs run length: per PATCH ENTRY (at most 31 per run).

comptime MAX_RLE_VALUES_PER_BYTE: Int = 512


@always_inline
def _check_rle_count(count: Int, n_bytes: Int, what: StringSlice) raises:
    """Reject a declared value count that the stream cannot physically back.

    Called ONCE per decode, before any allocation. See the bounds note above.
    """
    if count < 0:
        raise Error(
            String("OrcRleError.BAD_COUNT: ")
            + String(what)
            + " value count is negative ("
            + String(count)
            + ")"
        )
    if count > n_bytes * MAX_RLE_VALUES_PER_BYTE:
        raise Error(
            String("OrcRleError.COUNT_EXCEEDS_STREAM: ")
            + String(what)
            + " declares "
            + String(count)
            + " values but the stream holds only "
            + String(n_bytes)
            + " bytes (max "
            + String(MAX_RLE_VALUES_PER_BYTE)
            + " values/byte)"
        )


@always_inline
def _check_run_fits(cursor: Int, run_len: Int, count: Int, what: StringSlice) raises:
    """Reject a run header whose length would write past the destination.

    ONE check per run. `run_len` comes from the run header, which the file's
    writer controls; the destination was sized to `count` by the caller.
    """
    if cursor + run_len > count:
        raise Error(
            String("OrcRleError.RUN_OVERRUN: ")
            + String(what)
            + " run declares "
            + String(run_len)
            + " values at offset "
            + String(cursor)
            + " but the destination holds only "
            + String(count)
        )


# =============================================================================
# RLEv2 sub-encoding tags (the top 2 bits of a run's first byte).
# =============================================================================

comptime RLEV2_SHORT_REPEAT: Int = 0  # 0b00
comptime RLEV2_DIRECT: Int = 1  # 0b01
comptime RLEV2_PATCHED_BASE: Int = 2  # 0b10
comptime RLEV2_DELTA: Int = 3  # 0b11


# =============================================================================
# RLEv2 5-bit width table. 32 entries; encoded W -> bits.
# =============================================================================
#
# The non-contiguity (skips 25/27/29/31/33-39/41-47/49-55/57-63) is per spec.


@always_inline
def rlev2_decode_bit_width(n: Int) raises -> Int:
    """Map a 5-bit encoded width to its bit-count (ORC `decodeBitWidth`)."""
    if n >= 0 and n <= 23:
        return n + 1
    elif n == 24:
        return 26
    elif n == 25:
        return 28
    elif n == 26:
        return 30
    elif n == 27:
        return 32
    elif n == 28:
        return 40
    elif n == 29:
        return 48
    elif n == 30:
        return 56
    elif n == 31:
        return 64
    raise Error("OrcRleError.BAD_WIDTH: encoded width " + String(n) + " > 31")


# =============================================================================
# Bit-unpack helper: read `count` big-endian bit-packed values of width `bits`.
# =============================================================================
#
# ORC packs values MSB-first into a contiguous byte run (the same shape as
# Parquet BIT_PACKED). Width-specialized SIMD bit-unpack writing
# DIRECTLY into a caller-supplied output buffer (no intermediate List, no
# per-value append). Mojo 1.0.0b1 does NOT autovectorize unit-stride numeric
# loops, so the byte-aligned widths (8/16/32) and the nibble width (4) are
# hand-staged via explicit SIMD[T, W]. Arbitrary widths fall back to the scalar
# bit-cursor.
#
# Encapsulation: `dst` is a concrete-origin UnsafePointer used STRICTLY inside
# this module's bit-unpack functions for SIMD loads/stores; it never crosses a
# module boundary (the public surface returns owned List[Int64]); this is the
# SIMD inner-loop exception to the no-raw-pointer rule. Callers (`_decode_*`) pre-size their
# output List and pass `out.unsafe_ptr()` + a `start` offset.


@always_inline
def _bswap16[w: Int](v: SIMD[DType.uint16, w]) -> SIMD[DType.uint16, w]:
    """Byte-swap each 16-bit lane (ORC packs big-endian)."""
    return (v >> 8) | (v << 8)


@always_inline
def _bswap32[w: Int](v: SIMD[DType.uint32, w]) -> SIMD[DType.uint32, w]:
    """Byte-swap each 32-bit lane (ORC packs big-endian)."""
    return (
        (v >> 24)
        | ((v >> 8) & 0x0000FF00)
        | ((v << 8) & 0x00FF0000)
        | (v << 24)
    )


def _unpack_w8_simd[
    so: Origin[mut=False], do: Origin[mut=True]
](
    src: UnsafePointer[UInt8, so],
    count: Int,
    dst: UnsafePointer[Int64, do],
):
    """8-bit DIRECT unpack: each input byte zero-extends to one Int64 lane.

    # SAFETY: `src`/`dst` are concrete-origin views passed only within this
    # module; `src` has >= count bytes (caller validated via remaining()); `dst`
    # has >= count slots (caller pre-sized). SIMD load/store only; no escape.
    """
    comptime W = simd_width_of[DType.uint64]()
    var i = 0
    var limit = count - (count % W)
    while i < limit:
        var raw = src.load[width=W](i)  # SIMD[uint8, W]
        dst.store[width=W](i, raw.cast[DType.uint64]().cast[DType.int64]())
        i += W
    while i < count:
        dst.store(i, Int64(Int(src[i])))
        i += 1


def _unpack_w16_simd[
    so: Origin[mut=False], do: Origin[mut=True]
](
    src: UnsafePointer[UInt8, so],
    count: Int,
    dst: UnsafePointer[Int64, do],
):
    """16-bit DIRECT unpack: big-endian 16-bit value -> zero-extended Int64.

    # SAFETY: as `_unpack_w8_simd`; `src` has >= 2*count bytes.
    """
    comptime W = simd_width_of[DType.uint64]()
    var i = 0
    var limit = count - (count % W)
    while i < limit:
        # Load W*2 input bytes, reinterpret as W uint16 lanes, byte-swap.
        var raw = src.load[width = W * 2](i * 2)  # SIMD[uint8, W*2]
        var u16 = bitcast[DType.uint16, W](raw)
        var sw = _bswap16(u16)
        dst.store[width=W](i, sw.cast[DType.uint64]().cast[DType.int64]())
        i += W
    while i < count:
        var hi = UInt64(Int(src[i * 2]))
        var lo = UInt64(Int(src[i * 2 + 1]))
        dst.store(i, Int64((hi << 8) | lo))
        i += 1


def _unpack_w32_simd[
    so: Origin[mut=False], do: Origin[mut=True]
](
    src: UnsafePointer[UInt8, so],
    count: Int,
    dst: UnsafePointer[Int64, do],
):
    """32-bit DIRECT unpack: big-endian 32-bit value -> zero-extended Int64.

    # SAFETY: as `_unpack_w8_simd`; `src` has >= 4*count bytes.
    """
    comptime W = simd_width_of[DType.uint64]()
    var i = 0
    var limit = count - (count % W)
    while i < limit:
        var raw = src.load[width = W * 4](i * 4)  # SIMD[uint8, W*4]
        var u32 = bitcast[DType.uint32, W](raw)
        var sw = _bswap32(u32)
        dst.store[width=W](i, sw.cast[DType.uint64]().cast[DType.int64]())
        i += W
    while i < count:
        var v: UInt64 = 0
        comptime for k in range(4):
            v = (v << 8) | UInt64(Int(src[i * 4 + k]))
        dst.store(i, Int64(v))
        i += 1


def _unpack_w4_simd[
    so: Origin[mut=False], do: Origin[mut=True]
](
    src: UnsafePointer[UInt8, so],
    count: Int,
    dst: UnsafePointer[Int64, do],
):
    """4-bit DIRECT unpack: each byte = 2 nibbles (high nibble first, MSB-first).

    # SAFETY: as `_unpack_w8_simd`; `src` has >= ceil(count/2) bytes.
    """
    comptime W = simd_width_of[DType.uint64]()
    var pairs = count // 2  # whole bytes producing 2 values each
    var i = 0
    var limit = pairs - (pairs % W)
    while i < limit:
        var raw = src.load[width=W](i)  # SIMD[uint8, W]: W bytes = 2W nibbles
        var hi = (raw >> 4).cast[DType.uint64]().cast[DType.int64]()
        var lo = (raw & 0x0F).cast[DType.uint64]().cast[DType.int64]()
        # Output order is hi(byte0), lo(byte0), hi(byte1), lo(byte1), ...
        # Interleave hi/lo into the 2W output slots scalar (cheap vs the load).
        comptime for k in range(W):
            dst.store(2 * (i + k), hi[k])
            dst.store(2 * (i + k) + 1, lo[k])
        i += W
    while i < pairs:
        var b = Int(src[i])
        dst.store(2 * i, Int64((b >> 4) & 0x0F))
        dst.store(2 * i + 1, Int64(b & 0x0F))
        i += 1
    # Trailing odd value (count odd): high nibble of the last byte.
    if (count & 1) != 0:
        var b = Int(src[pairs])
        dst.store(count - 1, Int64((b >> 4) & 0x0F))


def _unpack_scalar_into[
    do: Origin[mut=True]
](
    mut reader: OrcIntReader, bits: Int, count: Int, dst: UnsafePointer[Int64, do]
) raises:
    """Scalar MSB-first bit-cursor unpack into `dst[0..count]`.

    # SAFETY: `dst` has >= count slots (caller pre-sized). Internal only.
    """
    if bits == 0:
        for i in range(count):
            dst.store(i, Int64(0))
        return
    # Fast scalar bit-cursor: bounds-check the whole packed run ONCE, then read
    # bytes through a raw pointer (no per-byte bounds check / pos increment).
    # This is the path for widths not covered by the SIMD kernels (e.g. 9-15,
    # 17-23), which carry much of the DIRECT mass on real data.
    var n_bytes = (bits * count + 7) // 8
    if reader.remaining() >= n_bytes:
        # SAFETY: `src` points at the next `n_bytes` of the reader's immutable
        # span; bounds checked above. Read-only; never escapes this function.
        var src = reader.data.unsafe_ptr() + reader.pos
        var byte_i = 0
        var bits_left: Int = 0
        var cur: UInt64 = 0
        for idx in range(count):
            var value: UInt64 = 0
            var need = bits
            while need > 0:
                if bits_left == 0:
                    cur = UInt64(Int(src[byte_i]))
                    byte_i += 1
                    bits_left = 8
                var take = need if need < bits_left else bits_left
                var shift = bits_left - take
                var mask = (UInt64(1) << UInt64(take)) - 1
                var chunk = (cur >> UInt64(shift)) & mask
                value = (value << UInt64(take)) | chunk
                bits_left -= take
                need -= take
            dst.store(idx, Int64(value))
        reader.pos += n_bytes
        return
    # Truncated-stream fallback: per-byte path raises on overrun.
    var bits_left: Int = 0
    var cur: UInt64 = 0
    for idx in range(count):
        var value: UInt64 = 0
        var need = bits
        while need > 0:
            if bits_left == 0:
                cur = UInt64(reader.read_byte())
                bits_left = 8
            var take = need if need < bits_left else bits_left
            var shift = bits_left - take
            var mask = (UInt64(1) << UInt64(take)) - 1
            var chunk = (cur >> UInt64(shift)) & mask
            value = (value << UInt64(take)) | chunk
            bits_left -= take
            need -= take
        dst.store(idx, Int64(value))


def _unpack_bits_into[
    do: Origin[mut=True]
](
    mut reader: OrcIntReader, bits: Int, count: Int, dst: UnsafePointer[Int64, do]
) raises:
    """Unpack `count` MSB-first bit-packed values of `bits` width into `dst`.

    Dispatches to a width-specialized SIMD kernel for byte-aligned widths
    (8/16/32) and the nibble width (4) when the packed run is contiguous in the
    reader's buffer; otherwise scalar. `dst` must have >= `count` slots.

    # SAFETY: `dst` is a concrete-origin pointer into a caller-pre-sized List;
    # it is used only for stores here and never crosses a module boundary.
    """
    if count == 0:
        return
    if bits == 8 or bits == 16 or bits == 32 or bits == 4:
        # Bytes consumed by the packed run (these widths are exact multiples of
        # 4 bits, so the byte length is the ceil over the contiguous run).
        var n_bytes = (bits * count + 7) // 8
        if reader.remaining() >= n_bytes:
            # SAFETY: src points at the next `n_bytes` of the reader's immutable
            # span; bounds checked above. Used only for SIMD loads here.
            var src = reader.data.unsafe_ptr() + reader.pos
            if bits == 8:
                _unpack_w8_simd(src, count, dst)
            elif bits == 16:
                _unpack_w16_simd(src, count, dst)
            elif bits == 32:
                _unpack_w32_simd(src, count, dst)
            else:  # bits == 4
                _unpack_w4_simd(src, count, dst)
            reader.pos += n_bytes
            return
    # Route the byte-aligned widths the apache-orc reference SIMDs
    # (24/40/48/56/64) and the cheap sub-byte widths (1/2) to the shared
    # width-generic SIMD kernel; w=24 and w=40 carry a large share of DIRECT
    # values on real data. Remaining odd widths (5/6/7/9-15/17-23/...) stay on the fast scalar cursor.
    if (
        bits == 1 or bits == 2 or bits == 24 or bits == 48
        or bits == 40 or bits == 56 or bits == 64
    ):
        var n_bytes = (bits * count + 7) // 8
        if reader.remaining() >= n_bytes:
            # Build borrowed/mutable Span views so no raw pointer crosses into
            # the core packages. `src_span` covers EXACTLY the packed run bytes;
            # the +16 SIMD overread headroom is guaranteed by the reader's
            # remaining() >= n_bytes check ONLY when there are >= 16 trailing
            # bytes, so we pad the span length by the available remainder.
            var avail = reader.remaining()
            var src_span = Span(
                unsafe_ptr=reader.data.unsafe_ptr() + reader.pos, length=avail
            )
            # SAFETY: dst is the caller's pre-sized backing store (>= count
            # slots); we expose it only as a bounded mutable Span to the shared
            # kernel and it never escapes.
            var dst_span = Span(unsafe_ptr=dst, length=count)
            if simd_unpack_bits(src_span, bits, count, dst_span):
                reader.pos += n_bytes
                return
    _unpack_scalar_into(reader, bits, count, dst)


def _unpack_bits(
    mut reader: OrcIntReader, bits: Int, count: Int, mut out: List[Int64]
) raises:
    """Append `count` MSB-first bit-packed values of `bits` width to `out`.

    Compatibility wrapper retained for the patch-list path (small counts).
    """
    var start = len(out)
    out.resize(unsafe_uninit_length=start + count)
    # SAFETY: pointer into `out`'s freshly-grown backing store; concrete origin;
    # used only by the unpack helpers in this module; never escapes.
    _unpack_bits_into(reader, bits, count, out.unsafe_ptr() + start)


# =============================================================================
# RLEv1 — legacy integer RLE (Hive 0.11; DIRECT / DICTIONARY encoding).
# =============================================================================
#
# A stream is a sequence of runs. The first byte (read as a signed int8)
# decides the run shape:
#   - byte in [0, 127]  : REPEAT run. length = byte + 3 (so 3..130). Then a
#                         signed int8 delta, then a base varint. Values are
#                         base + i*delta. (signed columns zigzag the base.)
#   - byte in [-128,-1] : LITERAL run. count = -byte (so 1..128). Then `count`
#                         varints, each decoded (zigzag if signed).


def decode_rlev1(
    data: Span[UInt8, _], count: Int, signed: Bool
) raises -> List[Int64]:
    """Decode EXACTLY `count` values from an RLEv1 stream.

    ⚠ "EXACTLY" IS LOAD-BEARING. Without the final truncation this function
    would return up to `count + 129` values, and every caller assumes it
    returns `count`.

    The loop below appends WHOLE RUNS and only re-tests `len(out) < count`
    between runs, so a final REPEAT run (up to 130 values) or LITERAL run (up
    to 128) legally overshoots. `decode_rlev2_into` cannot do this — its
    `_check_run_fits` rejects an over-long run before it is written — so the
    hazard is RLEv1-only.

    Where a surplus would go, and why truncation (not a raise) is the fix:

      * `decode_int_rle_into` appends the WHOLE temporary into the caller's
        accumulator while `acc.n_rows` advances by `count`. Repeat that per
        stripe and `len(acc.i64s)` drifts arbitrarily far above `acc.n_rows`.
        `ColumnAcc._build_int*` then allocates `n_rows` elements and hands the
        oversized list to `_bulk_fill_int`, whose loop runs to `len(vals)` and
        writes through `PrimitiveArray.store` — which has NO bounds check at
        any ASSERT level. That would be an attacker-controlled Int64 heap write
        past an Arrow buffer, even at `ASSERT=safe`.
      * `decode_int_rle_into_span`'s RLEv1 arm also clamps with
        `min(count, len(tmp))`, but that covers only ONE of the three callers.

    A RAISE here would be over-validation: a conforming writer's last run may
    legitimately carry more values than this call asked for (liborc's RLEv1
    decoder is streaming and keeps the surplus for its next call; ours is
    one-shot per stripe-column and has no next call). Dropping the surplus is
    what liborc effectively does at a stripe boundary. The REAL error path for
    a destination that cannot hold what it is handed lives at the write
    boundary — `_bulk_fill_int` / `_bulk_fill_same` in `column_decoder.mojo` —
    where it is one compare per column build.
    """
    # `count` is writer-controlled (stripe row count / dictionarySize). Bound it
    # against the bytes actually present BEFORE reserving. See the
    # HOSTILE-INPUT BOUNDS note at the top of this module.
    _check_rle_count(count, len(data), "RLEv1")
    var out = List[Int64]()
    out.reserve(count)
    var reader = OrcIntReader(data)
    while len(out) < count:
        var header = Int(reader.read_byte())
        if header < 128:
            # REPEAT run: length = header + 3.
            var run_len = header + 3
            var delta = Int(reader.read_byte())
            # delta is a signed int8.
            if delta >= 128:
                delta -= 256
            var base: Int64
            if signed:
                base = reader.read_vslong()
            else:
                base = Int64(reader.read_vulong())
            for i in range(run_len):
                out.append(base + Int64(i) * Int64(delta))
        else:
            # LITERAL run: count = 256 - header (header is two's-complement).
            var run_len = 256 - header
            for _i in range(run_len):
                if signed:
                    out.append(reader.read_vslong())
                else:
                    out.append(Int64(reader.read_vulong()))
    # Drop the final run's surplus so the POST-CONDITION `len(out) == count`
    # holds for every caller. See the docstring: this is the whole fix.
    if len(out) > count:
        out.resize(count, Int64(0))
    return out^


# =============================================================================
# RLEv2 — the four sub-variants.
# =============================================================================
#
# Each run's first byte top-2-bits select the sub-variant; the decoder reads
# one run at a time until `count` values are produced.


def decode_rlev2(
    data: Span[UInt8, _], count: Int, signed: Bool
) raises -> List[Int64]:
    """Decode `count` values from an RLEv2 stream (all 4 sub-variants)."""
    var out = List[Int64]()
    decode_rlev2_into(data, count, signed, out)
    return out^


def decode_rlev2_into(
    data: Span[UInt8, _], count: Int, signed: Bool, mut out: List[Int64]
) raises:
    """Decode `count` RLEv2 values, APPENDING into `out` (direct write).

    Lets callers decode straight into the column accumulator with no
    intermediate List + copy pass on the no-null fast path.
    """
    # Pre-size the output ONCE to the final count, then thread a plain Int
    # write-cursor through each `_decode_*` arm. liborc decodes through a single
    # register write-cursor into a buffer pre-allocated once per stripe; a
    # per-run `out.resize(...)` would touch the List._len heap header hundreds
    # of thousands of times per column. With a pre-sized buffer + cursor, no
    # per-run resize and no per-run `len(out)` load occurs.
    # `count` is writer-controlled and this `resize` is the allocation it buys.
    # Unchecked at ASSERT=none, a 4-byte stream declaring 2^40 values aborts
    # the process inside `alloc` ("returned a null pointer") — the TRUNCATED
    # raise that would eventually fire comes far too late.
    _check_rle_count(count, len(data), "RLEv2")
    var write_start = len(out)
    out.resize(unsafe_uninit_length=write_start + count)
    # SAFETY: `dst_base` is a concrete-origin pointer into `out`'s pre-sized
    # backing store. The resize above guarantees the backing store holds
    # >= write_start + count slots and is never reallocated inside the loop (no
    # further resize/reserve runs). Used only by this module's `_decode_*`
    # helpers; never crosses a module boundary.
    var dst_base = out.unsafe_ptr() + write_start
    _decode_rlev2_into_ptr(data, count, signed, dst_base)


def decode_rlev2_into_span[
    so: Origin[mut=True]
](
    data: Span[UInt8, _],
    count: Int,
    signed: Bool,
    dst_bytes: Span[UInt8, so],
    elem_start: Int,
) raises:
    """Decode `count` RLEv2 values straight into an Int64 destination buffer
    (passed as its raw BYTE span) starting at element `elem_start` (the
    zero-copy int path).

    The destination is an Arrow `PrimitiveArray[int64]`'s 64B-aligned
    `MmapAlignedBuffer`, exposed as its `Span[UInt8]` capacity view (a safe view —
    no raw pointer crosses the module boundary). Decoding directly into the
    Arrow buffer eliminates the `acc.i64s` List accumulator AND the build-time
    `_bulk_fill_int` 48MB-per-column copy pass (liborc's per-stripe
    AppendBatch model).
    """
    # ⚠ THIS IS A RAISE, NOT A `debug_assert` — A `debug_assert` IS NOT A GUARD.
    #
    # `elem_start` is the running `acc.n_rows` and `count` is the stripe's
    # declared row count — BOTH from the file's stripe directory — and this is
    # the ONLY extent check on the zero-copy BIGINT path that writes straight
    # into the Arrow MmapAlignedBuffer. Mojo's `debug_assert` defaults to
    # assert_mode "none", so it would not fire even at ASSERT=safe; at
    # ASSERT=none it is guaranteed inert. A file whose stripes claim more rows
    # in aggregate than `Footer.numberOfRows` would write attacker-controlled
    # Int64s past the end of the Arrow buffer with nothing in the way.
    #
    # ONE check per stripe-column (not per value): this runs once per
    # decode_rlev2_into_span call, which covers up to a whole stripe.
    if elem_start < 0 or count < 0:
        raise Error(
            String("OrcRleError.BAD_DESTINATION: element start ")
            + String(elem_start)
            + " / count "
            + String(count)
            + " must both be non-negative"
        )
    _check_rle_count(count, len(data), "RLEv2 (zero-copy)")
    if (elem_start + count) * 8 > len(dst_bytes):
        raise Error(
            String("OrcRleError.DESTINATION_OVERRUN: decoding ")
            + String(count)
            + " values at element "
            + String(elem_start)
            + " needs "
            + String((elem_start + count) * 8)
            + " bytes but the output buffer holds "
            + String(len(dst_bytes))
        )
    # SAFETY: `dst_bytes` is a caller-provided safe byte Span over a live
    # 64B-aligned MmapAlignedBuffer sized to hold >= (elem_start+count) Int64s
    # (ENFORCED by the raise above — not asserted). We reinterpret it as Int64* —
    # alignment is guaranteed by the MmapAlignedBuffer[64] origin. The pointer is
    # concrete-origin (`so`), used only by this module's `_decode_*` helpers, and
    # never escapes.
    var dst_base = dst_bytes.unsafe_ptr().bitcast[Int64]() + elem_start
    _decode_rlev2_into_ptr(data, count, signed, dst_base)


def _decode_rlev2_into_ptr[
    do: Origin[mut=True]
](
    data: Span[UInt8, _],
    count: Int,
    signed: Bool,
    dst_base: UnsafePointer[Int64, do],
) raises:
    """Core RLEv2 decode loop writing `count` values through `dst_base`.

    Shared by `decode_rlev2_into` (List destination) and
    `decode_rlev2_into_span` (MmapAlignedBuffer destination). `dst_base` is a
    concrete-origin pointer into a destination that the CALLER has already
    sized to hold >= count values; this fn never resizes or reallocates it.
    Module-internal helper — the pointer does NOT cross the module boundary.
    """
    var cursor = 0
    # A single reusable scratch buffer for variable-delta runs, bounded by
    # RLEv2 MAX_LITERAL_SIZE (512), the same as liborc's fixed scratch: one
    # allocation here, reused for every variable-delta run, instead of a
    # List[Int64] per run.
    var delta_scratch = List[Int64]()
    delta_scratch.resize(unsafe_uninit_length=512)
    var reader = OrcIntReader(data)
    while cursor < count:
        var first = Int(reader.read_byte())
        var sub = (first >> 6) & 0x3
        if sub == RLEV2_SHORT_REPEAT:
            _decode_short_repeat(reader, first, signed, dst_base, cursor, count)
        elif sub == RLEV2_DIRECT:
            _decode_direct(reader, first, signed, dst_base, cursor, count)
        elif sub == RLEV2_PATCHED_BASE:
            _decode_patched_base(reader, first, dst_base, cursor, count)
        else:  # RLEV2_DELTA
            _decode_delta(
                reader, first, signed, dst_base, cursor, count, delta_scratch
            )


# -----------------------------------------------------------------------------
# Short Repeat (tag 0b00): bits[5:3]=W-1 (1..8 bytes), bits[2:0]=R-3 (3..10).
# Then W big-endian bytes = the repeated value.
# -----------------------------------------------------------------------------
def _decode_short_repeat[
    do: Origin[mut=True]
](
    mut reader: OrcIntReader,
    first: Int,
    signed: Bool,
    dst_base: UnsafePointer[Int64, do],
    mut cursor: Int,
    count: Int,
) raises:
    var byte_width = ((first >> 3) & 0x7) + 1
    var run_len = (first & 0x7) + 3
    _check_run_fits(cursor, run_len, count, "RLEv2 SHORT_REPEAT")
    # Read the byte_width value bytes through a raw pointer with
    # ONE bounds-check, not byte_width `read_byte()` calls (each of which pays two
    # bounds checks). byte_width is 1..8.
    var raw: UInt64 = 0
    if reader.remaining() >= byte_width:
        # SAFETY: `src` points at the next byte_width bytes of the reader's
        # immutable span; bounds checked above. Read-only; never escapes.
        var src = reader.data.unsafe_ptr() + reader.pos
        for i in range(byte_width):
            raw = (raw << 8) | UInt64(Int(src[i]))
        reader.pos += byte_width
    else:
        for _i in range(byte_width):
            raw = (raw << 8) | UInt64(reader.read_byte())
    var value: Int64
    if signed:
        value = zigzag_decode(raw)
    else:
        value = Int64(raw)
    # SAFETY: `dst` is a concrete-origin pointer into the caller's pre-sized
    # backing store at the current cursor; cursor + run_len <= count (the buffer
    # was sized to count). Written only here; never escapes.
    var dst = dst_base + cursor
    cursor += run_len
    # SIMD broadcast-store of the repeated value, matching
    # liborc's `movddup` + 2x `movups` (128-bit broadcast, 32 bytes/iter). The
    # 2-lane width runs at full throughput without AVX2 and suits the 3-10 value
    # SHORT_REPEAT range better than the native 8-lane width.
    comptime V2 = SIMD[DType.int64, 2]
    var vec = V2(value)
    var i = 0
    var limit = run_len - (run_len % 4)
    while i < limit:
        dst.store[width=2](i, vec)
        dst.store[width=2](i + 2, vec)
        i += 4
    while i < run_len:
        dst.store(i, value)
        i += 1


# -----------------------------------------------------------------------------
# Direct (tag 0b01): byte0 bits[5:1]=encoded W; byte0 bit0 + byte1 = L-1 (9-bit
# length 1..512). Then ceil(W*L/8) bytes of MSB-first bit-packed values
# (zigzag if signed).
# -----------------------------------------------------------------------------
def _decode_direct[
    do: Origin[mut=True]
](
    mut reader: OrcIntReader,
    first: Int,
    signed: Bool,
    dst_base: UnsafePointer[Int64, do],
    mut cursor: Int,
    count: Int,
) raises:
    var enc_w = (first >> 1) & 0x1F
    var bits = rlev2_decode_bit_width(enc_w)
    var len_hi = first & 0x1
    var len_lo = Int(reader.read_byte())
    var run_len = ((len_hi << 8) | len_lo) + 1
    _check_run_fits(cursor, run_len, count, "RLEv2 DIRECT")
    # SAFETY: concrete-origin pointer into the caller's pre-sized backing store at
    # the current cursor; `cursor + run_len <= count` is ENFORCED by the
    # `_check_run_fits` call above, not assumed — `run_len` comes from the run
    # header, which the file's writer controls. Passed only to this module's
    # unpack/zigzag helpers; never escapes.
    var dst = dst_base + cursor
    cursor += run_len
    _unpack_bits_into(reader, bits, run_len, dst)
    if signed:
        _zigzag_decode_inplace(dst, run_len)


@always_inline
def _zigzag_decode_inplace[
    do: Origin[mut=True]
](dst: UnsafePointer[Int64, do], count: Int):
    """In-place zigzag-decode of `count` raw magnitudes, SIMD-wide.

    # SAFETY: `dst` has >= count slots (caller pre-sized). Internal only.
    """
    comptime W = simd_width_of[DType.int64]()
    var i = 0
    var limit = count - (count % W)
    while i < limit:
        var u = dst.load[width=W](i).cast[DType.uint64]()
        # (u >> 1) ^ -(u & 1)
        var v = (u >> 1) ^ (~(u & 1) + 1)
        dst.store[width=W](i, v.cast[DType.int64]())
        i += W
    while i < count:
        dst.store(i, zigzag_decode(UInt64(dst[i])))
        i += 1


# -----------------------------------------------------------------------------
# Patched Base (tag 0b10):
#   byte0 bits[5:1] = encoded W (value width, same 5-bit table)
#   byte0 bit0 + byte1 = L-1 (9-bit length 1..512)
#   byte2 bits[7:5] = BW-1 (base byte width 1..8)
#   byte2 bits[4:0] = encoded PW (patch width, 5-bit table)
#   byte3 bits[7:5] = PGW-1 (patch gap width 1..8)  [NOTE: stored as PGW-1]
#   byte3 bits[4:0] = PLL (patch list length 0..31)
#   [BW bytes] base value (sign in MSB — signed-magnitude, NOT two's-complement)
#   [ceil(W*L/8)] data values (base subtracted), bit-packed
#   [ceil((PGW+PW)*PLL/8)] patch list: each entry = PGW gap bits + PW patch bits
#
# Patched Base values are NOT zigzag-encoded — the base carries the sign in
# signed-magnitude form, and the unpacked W-bit data is the unsigned offset
# above base (with patches OR-ing high bits in).
# -----------------------------------------------------------------------------
def _decode_patched_base[
    do: Origin[mut=True]
](
    mut reader: OrcIntReader,
    first: Int,
    dst_base: UnsafePointer[Int64, do],
    mut cursor: Int,
    count: Int,
) raises:
    var enc_w = (first >> 1) & 0x1F
    var bits = rlev2_decode_bit_width(enc_w)
    var len_hi = first & 0x1
    var len_lo = Int(reader.read_byte())
    var run_len = ((len_hi << 8) | len_lo) + 1
    _check_run_fits(cursor, run_len, count, "RLEv2 PATCHED_BASE")

    var b2 = Int(reader.read_byte())
    var base_width = ((b2 >> 5) & 0x7) + 1
    var enc_pw = b2 & 0x1F
    var patch_width = rlev2_decode_bit_width(enc_pw)

    var b3 = Int(reader.read_byte())
    var patch_gap_width = ((b3 >> 5) & 0x7) + 1
    var patch_list_len = b3 & 0x1F

    # The patch-list entry is (gap | patch) packed into ONE unpacked Int64, so
    # the two widths must fit in 64 bits together. `patch_width` reaches 64 via
    # the 5-bit width table, which additionally makes `entry >> patch_width` and
    # `UInt64(1) << patch_width` shifts-BY-width (poison) below. One check per
    # run header; the ORC spec caps the patch width well under this.
    if patch_gap_width + patch_width > 64:
        raise Error(
            String("OrcRleError.BAD_PATCH_WIDTH: PATCHED_BASE gap width ")
            + String(patch_gap_width)
            + " + patch width "
            + String(patch_width)
            + " exceeds 64 bits"
        )

    # Base value: signed-magnitude big-endian over `base_width` bytes. The MSB
    # of the first byte is the sign bit (NOT two's complement).
    var base_mag: Int64
    var first_base = Int(reader.read_byte())
    var negative = (first_base & 0x80) != 0
    base_mag = Int64(first_base & 0x7F)
    for _i in range(base_width - 1):
        base_mag = (base_mag << 8) | Int64(Int(reader.read_byte()))
    var base: Int64 = -base_mag if negative else base_mag

    # Data values (base subtracted), bit-packed at `bits` width.
    # SAFETY: concrete-origin pointer into the caller's pre-sized backing store at
    # the current cursor; cursor + run_len <= count. Used only within this
    # module; never escapes.
    var dst = dst_base + cursor
    cursor += run_len
    _unpack_bits_into(reader, bits, run_len, dst)

    # Patch list: PLL entries of (gap, patch). The patch holds the high bits
    # that didn't fit in `bits`; OR them in at `bits` shift after walking gaps.
    var patches = List[Int64]()
    _unpack_bits(reader, patch_gap_width + patch_width, patch_list_len, patches)
    var patch_mask = (UInt64(1) << UInt64(patch_width)) - 1
    # ORC patch positions are CUMULATIVE gaps from index 0 (the first gap IS
    # the first patched index). A gap of 255 with a zero patch is a "skip 255
    # positions" continuation (ORC-642); we accumulate it like any other gap.
    var idx = 0
    for p in range(patch_list_len):
        var entry = UInt64(patches[p])
        var gap = Int(entry >> UInt64(patch_width))
        var patch = entry & patch_mask
        if p == 0:
            idx = gap
        else:
            idx += gap
        # `idx` is a CUMULATIVE sum of up-to-8-bit gaps over up to 31 entries,
        # so it reaches 255*31 = 7905 while the run it indexes holds at most 512
        # values. Unchecked, `dst[idx]` / `dst.store(idx, ...)` would be an
        # attacker-positioned read AND write up to ~63 KB past the run — with
        # partly attacker-chosen content. orc-cpp's RleDecoderV2 bounds the
        # patched index against the run length; so does this. At most 31
        # iterations per run, so the cost is off the per-value path.
        if idx < 0 or idx >= run_len:
            raise Error(
                String("OrcRleError.PATCH_INDEX_OUT_OF_RUN: patch ")
                + String(p)
                + " targets index "
                + String(idx)
                + " in a run of "
                + String(run_len)
                + " values"
            )
        # OR the patch high bits above the W-bit data value, then add base.
        var raw = UInt64(dst[idx]) | (patch << UInt64(bits))
        dst.store(idx, Int64(raw))

    # Add base to every value in the run (SIMD broadcast-add).
    comptime Wb = simd_width_of[DType.int64]()
    var base_vec = SIMD[DType.int64, Wb](base)
    var i = 0
    var limit = run_len - (run_len % Wb)
    while i < limit:
        dst.store[width=Wb](i, dst.load[width=Wb](i) + base_vec)
        i += Wb
    while i < run_len:
        dst.store(i, dst[i] + base)
        i += 1


# -----------------------------------------------------------------------------
# Delta (tag 0b11):
#   byte0 bits[5:1] = encoded delta W (0 means fixed-delta — no per-value bits;
#                     NOTE: for Delta the width is the RAW 5-bit value mapped
#                     through the same table, EXCEPT 0 stays 0)
#   byte0 bit0 + byte1 = L-1 (9-bit length 1..512)
#   [varint] base value (signed: zigzag; unsigned: vulong)
#   [signed varint] delta_base — value[1] - value[0]; sign sets direction
#   [ceil(W*(L-2)/8)] remaining deltas, bit-packed UNSIGNED (added/subtracted
#     per the delta_base sign)
# -----------------------------------------------------------------------------
def _decode_delta[
    do: Origin[mut=True]
](
    mut reader: OrcIntReader,
    first: Int,
    signed: Bool,
    dst_base: UnsafePointer[Int64, do],
    mut cursor: Int,
    count: Int,
    mut scratch: List[Int64],
) raises:
    var enc_w = (first >> 1) & 0x1F
    var delta_bits: Int
    if enc_w == 0:
        delta_bits = 0
    else:
        delta_bits = rlev2_decode_bit_width(enc_w)
    var len_hi = first & 0x1
    var len_lo = Int(reader.read_byte())
    var run_len = ((len_hi << 8) | len_lo) + 1
    _check_run_fits(cursor, run_len, count, "RLEv2 DELTA")

    var base: Int64
    if signed:
        base = reader.read_vslong()
    else:
        base = Int64(reader.read_vulong())
    # delta_base is ALWAYS a signed zigzag varint (its sign sets direction).
    var delta_base = reader.read_vslong()

    # SAFETY: concrete-origin pointer into the caller's pre-sized backing store at
    # the current cursor; cursor + run_len <= count. Used only within this
    # module; never escapes.
    var dst = dst_base + cursor
    cursor += run_len
    var prev = base
    dst.store(0, prev)
    if run_len == 1:
        return
    prev = prev + delta_base
    dst.store(1, prev)
    if run_len == 2:
        return

    var increasing = delta_base >= 0
    var n_deltas = run_len - 2
    if delta_bits == 0:
        # Fixed delta: value[2+i] = prev + (i+1)*delta_base. Pure arithmetic
        # progression — SIMD broadcast-add over a lane-offset vector.
        comptime W = simd_width_of[DType.int64]()
        var offs = SIMD[DType.int64, W](0)
        comptime for k in range(W):
            offs[k] = Int64(k + 1)
        var step_vec = offs * delta_base  # [1*d, 2*d, ..., W*d]
        var bump = SIMD[DType.int64, W](delta_base * Int64(W))
        var cur = SIMD[DType.int64, W](prev) + step_vec
        var i = 0
        var limit = n_deltas - (n_deltas % W)
        while i < limit:
            dst.store[width=W](2 + i, cur)
            cur += bump
            i += W
        # Scalar tail.
        var tail_prev = prev + delta_base * Int64(i)
        while i < n_deltas:
            tail_prev = tail_prev + delta_base
            dst.store(2 + i, tail_prev)
            i += 1
        return

    # Variable deltas: read n_deltas unsigned W-bit values into the REUSED
    # scratch buffer (no per-run alloc), then inclusive
    # prefix-sum (loop-carried; stays scalar). n_deltas <= run_len-2 <= 510,
    # within the 512-slot scratch the caller pre-sized once.
    # SAFETY: concrete-origin scratch pointer into the reused buffer (>= 512
    # slots, n_deltas <= 510); module-internal; never escapes.
    _unpack_bits_into(reader, delta_bits, n_deltas, scratch.unsafe_ptr())
    for i in range(n_deltas):
        var d = scratch[i]
        if increasing:
            prev = prev + d
        else:
            prev = prev - d
        dst.store(2 + i, prev)


# =============================================================================
# Boolean RLE (PRESENT stream).
# =============================================================================
#
# The PRESENT stream is a byte-RLE stream of BITS: the byte-RLE decode produces
# a sequence of bytes, and each byte holds 8 boolean flags MSB-first. We decode
# enough bytes to cover `count` booleans, then expand bit-by-bit.
#
# Returns a List[Bool] of length `count` (1 = present/non-null).


def decode_boolean_rle(data: Span[UInt8, _], count: Int) raises -> List[Bool]:
    """Decode EXACTLY `count` booleans from a boolean (byte-RLE-of-bits) stream.

    ⚠ `count` IS THE STRIPE'S DECLARED ROW COUNT — a protobuf uint64 the file's
    writer chose — and `(count + 7)` is the one expression here that can
    overflow Int and wrap NEGATIVE. At `count` within 7 of `Int.MAX` the sum
    wraps, `n_bytes` goes negative, and the `range(count)` loop below would
    then index `bytes[i // 8]` for ~2^63 iterations into a list that holds
    nothing — at ASSERT=none that is a SIGSEGV (rc=139).

    ⚠ THERE IS DELIBERATELY NO CHECK IN THIS FUNCTION. A check here
    (`_check_rle_count(count, len(data) * 8, ...)`) cannot be falsified alone:
    with it NEUTRALISED the falsifier still PASSES — `decode_byte_rle`'s own `_check_rle_count`
    on the derived `n_bytes` catches the wrap (a negative `n_bytes` is a
    `BAD_COUNT` raise) and catches every non-wrapping over-large count too
    (`n_bytes` in range implies `i // 8 < n_bytes <= len(bytes)` for all
    `i < count`, given `decode_byte_rle`'s exact-length post-condition). A guard
    that cannot be falsified in isolation is not coverage, so there is none.
    The falsifier for this defect neutralises the byte-RLE check, which IS the
    load-bearing one.

    (Recorded so nobody adds it: a bound stated HERE would also have to be in
    BITS. Byte-RLE's densest shape is a 2-byte RUN header carrying 130 bytes =
    1040 BOOLEANS, i.e. 520 booleans per stream byte — ABOVE
    `MAX_RLE_VALUES_PER_BYTE` (512) — so `_check_rle_count(count, len(data))`
    would REJECT an ordinary all-true boolean column. `boolean_rle_dense_ok`
    pins that shape.)
    """
    var n_bytes = (count + 7) // 8
    var bytes = decode_byte_rle(data, n_bytes)
    var out = List[Bool]()
    for i in range(count):
        var byte = bytes[i // 8]
        var bit = 7 - (i % 8)
        out.append(((byte >> UInt8(bit)) & 1) == 1)
    return out^


# =============================================================================
# Byte RLE (TINYINT DATA; UNION tag; and the substrate of boolean RLE).
# =============================================================================
#
# Wire format (ORC `ByteRleDecoder`):
#   - first byte read as int8:
#       >= 0 : RUN. length = byte + 3 (3..130). Next 1 byte repeats `length`x.
#       <  0 : LITERAL. count = -byte (1..128). Next `count` raw bytes.


def decode_byte_rle(data: Span[UInt8, _], count: Int) raises -> List[UInt8]:
    """Decode EXACTLY `count` bytes from a byte-RLE stream.

    ⚠ SAME SHAPE AS `decode_rlev1`: the loop appends WHOLE RUNS and only
    re-tests `len(out) < count` between them, so the final run overshoots by
    up to 129 bytes. `_decode_tinyint_into` / `_no_present_tinyint_into` read
    `raw[i]` for `i < n` and so are not themselves unsafe, but without the
    truncation the post-condition every caller reads the signature as
    promising would not hold, and the surplus would ride into
    `decode_boolean_rle`'s bit expansion. Truncating here makes
    `len(out) == count` a real post-condition for both.

    The `_check_rle_count` is the allocation bound: without it `count` is an
    unbounded `List.append` target driven by the stripe's declared row count.
    """
    _check_rle_count(count, len(data), "byte RLE")
    var out = List[UInt8]()
    var reader = OrcIntReader(data)
    while len(out) < count:
        var header = Int(reader.read_byte())
        if header < 128:
            # RUN: length = header + 3, then one repeated byte.
            var run_len = header + 3
            var value = reader.read_byte()
            for _i in range(run_len):
                out.append(value)
        else:
            # LITERAL: count = 256 - header raw bytes.
            var lit_len = 256 - header
            for _i in range(lit_len):
                out.append(reader.read_byte())
    # Post-condition `len(out) == count` — see the docstring.
    if len(out) > count:
        out.resize(count, UInt8(0))
    return out^


# =============================================================================
# Top-level integer RLE dispatch on ColumnEncoding V1-vs-V2.
# =============================================================================


def decode_int_rle(
    data: Span[UInt8, _], count: Int, signed: Bool, is_v2: Bool
) raises -> List[Int64]:
    """Decode `count` integers; route to RLEv1 or RLEv2 by `is_v2`."""
    if is_v2:
        return decode_rlev2(data, count, signed)
    return decode_rlev1(data, count, signed)


def decode_int_rle_into(
    data: Span[UInt8, _],
    count: Int,
    signed: Bool,
    is_v2: Bool,
    mut out: List[Int64],
) raises:
    """Decode `count` integers APPENDING into `out` (direct write).

    Used by the no-null fast path to decode straight into the column
    accumulator with no intermediate List + copy pass.
    """
    if is_v2:
        decode_rlev2_into(data, count, signed, out)
        return
    # RLEv1 is legacy / rarely hot; route through the allocating path + extend.
    var tmp = decode_rlev1(data, count, signed)
    out.reserve(len(out) + len(tmp))
    for i in range(len(tmp)):
        out.append(tmp[i])


def decode_int_rle_into_span[
    so: Origin[mut=True]
](
    data: Span[UInt8, _],
    count: Int,
    signed: Bool,
    is_v2: Bool,
    dst_bytes: Span[UInt8, so],
    elem_start: Int,
) raises:
    """Decode `count` integers straight into an Int64 destination buffer
    (passed as its raw BYTE span) at element `elem_start`
    (the zero-copy int64 path).

    Routes RLEv2 through the span-writing core (no List, no copy). RLEv1 is
    legacy/cold — decode to a temp List then copy into the destination.
    """
    if is_v2:
        decode_rlev2_into_span(data, count, signed, dst_bytes, elem_start)
        return

    # ⚠ THE RLEv1 TWIN OF THE GUARD IN `decode_rlev2_into_span`.
    #
    # `decode_rlev2_into_span` (above, same file) guards with a real raise, not
    # a `debug_assert`. This arm — the SAME FUNCTION, one branch away, writing
    # into the SAME `i64_buf` through the same raw pointer — needs the same
    # raise: a `debug_assert` whose mode defaults to "none" never fires at
    # ASSERT=safe either. `is_v2` is
    # `encoding_kind == DIRECT_V2 || DICTIONARY_V2` read out of the stripe
    # footer, so a file selects this arm by writing `kind = DIRECT` (0).
    #
    # TWO independent overflow drivers:
    #   1. `elem_start` is the running `acc.n_rows` and `count` the stripe's
    #      declared row count, while `i64_buf` was sized to the FOOTER's
    #      `numberOfRows` — the same cross-check the RLEv2 arm makes.
    #   2. THE ONE THE RLEv2 ARM CANNOT HAVE: a write loop running to
    #      `len(tmp)`, not to `count`. `decode_rlev1` appends WHOLE runs and
    #      only stops once `len(out) >= count`, so a final run legally
    #      overshoots by up to 129 values — 1032 bytes past the end even for
    #      a file whose stripe counts agree with its footer. RLEv2 cannot do
    #      this because `_check_run_fits` rejects a run before it is written.
    #
    # The write is therefore bounded to `count` — the number of values the
    # caller asked for and the number the accumulator advanced by. Writing
    # the surplus is never right: in-bounds it silently overwrites the NEXT
    # stripe's rows. ONE check per stripe-column, not per value.
    if elem_start < 0 or count < 0:
        raise Error(
            String("OrcRleError.BAD_DESTINATION: element start ")
            + String(elem_start)
            + " / count "
            + String(count)
            + " must both be non-negative"
        )
    # Shift form, not `(elem_start + count) * 8`: the byte product is the one
    # expression here that can overflow Int and wrap NEGATIVE.
    if elem_start + count > len(dst_bytes) >> 3:
        raise Error(
            String("OrcRleError.DESTINATION_OVERRUN: decoding ")
            + String(count)
            + " RLEv1 values at element "
            + String(elem_start)
            + " needs "
            + String(elem_start + count)
            + " Int64 slots but the output buffer holds "
            + String(len(dst_bytes) >> 3)
        )
    var tmp = decode_rlev1(data, count, signed)
    # SAFETY: `dst_bytes` is a caller-provided safe byte Span over a live
    # 64B-aligned buffer with >= (elem_start + count) Int64 slots — ENFORCED
    # by the raise above, not asserted. The pointer is concrete-origin (`so`)
    # and never leaves this function.
    var dst_base = dst_bytes.unsafe_ptr().bitcast[Int64]() + elem_start
    var n_write = count if count < len(tmp) else len(tmp)
    for i in range(n_write):
        dst_base[i] = tmp[i]
