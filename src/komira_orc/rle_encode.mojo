# =============================================================================
# rle_encode.mojo — ORC integer/byte/boolean RLE ENCODE (inverse of
#                   rle_decode.mojo; the writer path).
# =============================================================================
#
# Correctness-first encode coverage: RLEv1 + RLEv2 Direct + Short Repeat
# encode every value correctly, just not bit-optimally. This module emits:
#   - encode_vulong / encode_vslong  : base-128 LEB128 + zigzag (inverse of
#                                       OrcIntReader.read_vulong / read_vslong)
#   - encode_byte_rle                : byte RLE (TINYINT DATA / UNION tag)
#   - encode_boolean_rle             : boolean RLE (PRESENT / BOOLEAN DATA)
#   - encode_int_rle_v2              : RLEv2 with a per-run heuristic:
#       * Short Repeat for a constant run of 3..10 identical values
#       * Direct (bit-packed at the run's max width) otherwise
#     This is fully round-trippable through the `decode_rlev2` reader (which
#     handles all 4 sub-variants). Patched Base + Delta ENCODE are a possible
#     bit-optimality improvement — the reader handles all 5 families, so a
#     writer emitting Short Repeat + Direct produces correct, readable ORC.
#
# Signed-ness: integer columns (SHORT/INT/LONG/DATE) are SIGNED — values are
# zigzag-encoded on the wire. LENGTH / dictionary-index / nanos streams are
# UNSIGNED. The encoder takes a `signed` flag and zigzags magnitudes when set
# (mirrors decode_int_rle's `signed` parameter exactly).
#
# Encapsulation: every encoder consumes an owned `List[Int64]` (or List[UInt8])
# and appends to an owned `List[UInt8]`. No UnsafePointer crosses any module
# boundary; pure index arithmetic.
# =============================================================================

from .rle_decode import zigzag_decode


# =============================================================================
# Base-128 varint encode (inverse of OrcIntReader.read_vulong / read_vslong).
# =============================================================================


def encode_vulong(mut out: List[UInt8], value: UInt64):
    """Append `value` as an unsigned base-128 LEB128 varint."""
    var v = value
    while True:
        var b = UInt8(v & 0x7F)
        v >>= 7
        if v != 0:
            out.append(b | 0x80)
        else:
            out.append(b)
            break


@always_inline
def zigzag_encode(v: Int64) -> UInt64:
    """ORC/Protobuf zigzag encode (inverse of zigzag_decode)."""
    return UInt64((v << 1) ^ (v >> 63))


@always_inline
def encode_vslong(mut out: List[UInt8], value: Int64):
    """Append `value` as a zigzag-encoded signed base-128 varint."""
    encode_vulong(out, zigzag_encode(value))


# =============================================================================
# Byte RLE encode (TINYINT DATA / UNION tag). Inverse of decode_byte_rle.
# =============================================================================
#
# We use LITERAL runs only (header in [128, 255] => count = 256 - header, then
# `count` raw bytes), chunked at 128 bytes per run. This is always correct and
# is what the decoder's LITERAL branch reads back; run-compression of repeats
# a possible optimization (the decoder handles both).


def encode_byte_rle(values: List[UInt8]) -> List[UInt8]:
    """Encode a byte stream as byte RLE (literal runs only)."""
    var out = List[UInt8]()
    var i = 0
    var n = len(values)
    while i < n:
        var run = n - i
        if run > 128:
            run = 128
        # LITERAL header: 256 - count (so a run of `run` bytes => 256 - run).
        out.append(UInt8(256 - run))
        for k in range(run):
            out.append(values[i + k])
        i += run
    return out^


# =============================================================================
# Boolean RLE encode (PRESENT stream / BOOLEAN DATA). Inverse of
# decode_boolean_rle.
# =============================================================================
#
# Pack `count` booleans into ceil(count/8) bytes MSB-first, then byte-RLE the
# packed bytes. The decoder reads ceil(count/8) bytes via decode_byte_rle then
# expands bit-by-bit MSB-first — so packing + byte_rle is the exact inverse.


def encode_boolean_rle(flags: List[Bool]) -> List[UInt8]:
    """Encode a boolean stream (one bit per flag, MSB-first) as boolean RLE."""
    var n = len(flags)
    var n_bytes = (n + 7) // 8
    var packed = List[UInt8]()
    for bi in range(n_bytes):
        var byte: UInt8 = 0
        for bit in range(8):
            var idx = bi * 8 + bit
            if idx < n and flags[idx]:
                byte |= UInt8(1) << UInt8(7 - bit)
        packed.append(byte)
    return encode_byte_rle(packed)


# =============================================================================
# RLEv2 integer encode (Short Repeat + Direct heuristic). Inverse of
# decode_rlev2.
# =============================================================================
#
# We chunk the value sequence into runs of <= 512 values. For each run:
#   - if it is a CONSTANT run of 3..10 values: emit Short Repeat (1 + W bytes).
#   - else: emit Direct, bit-packing each value (zigzagged if signed) at the
#     run's maximum bit-width.
#
# This is the per-run sub-variant heuristic in its simplest correct form:
# Short Repeat for constant runs, Direct otherwise. Delta (monotonic) is not
# emitted.


comptime RLEV2_MAX_RUN: Int = 512


@always_inline
def _bit_width(v: UInt64) -> Int:
    """Minimum bit-width needed to represent `v` (>= 1)."""
    if v == 0:
        return 1
    var w = 0
    var x = v
    while x != 0:
        w += 1
        x >>= 1
    return w


@always_inline
def _encode_bit_width(bits: Int) raises -> Int:
    """Map a bit-count to its 5-bit encoded width (inverse of
    rlev2_decode_bit_width). Direct encode keeps widths <= 24 contiguous (W-1);
    wider widths use the non-contiguous codes."""
    if bits >= 1 and bits <= 24:
        return bits - 1
    elif bits <= 26:
        return 24
    elif bits <= 28:
        return 25
    elif bits <= 30:
        return 26
    elif bits <= 32:
        return 27
    elif bits <= 40:
        return 28
    elif bits <= 48:
        return 29
    elif bits <= 56:
        return 30
    elif bits <= 64:
        return 31
    raise Error("OrcRleEncodeError.BAD_WIDTH: bits " + String(bits) + " > 64")


@always_inline
def _decoded_bit_width(enc_w: Int) -> Int:
    """The bit-count an encoded width maps to (matches rlev2_decode_bit_width).
    """
    if enc_w >= 0 and enc_w <= 23:
        return enc_w + 1
    elif enc_w == 24:
        return 26
    elif enc_w == 25:
        return 28
    elif enc_w == 26:
        return 30
    elif enc_w == 27:
        return 32
    elif enc_w == 28:
        return 40
    elif enc_w == 29:
        return 48
    elif enc_w == 30:
        return 56
    return 64


def _pack_bits(mut out: List[UInt8], values: List[UInt64], bits: Int):
    """MSB-first bit-pack `values` at `bits` width (inverse of _unpack_bits)."""
    if bits == 0:
        return
    var cur: UInt64 = 0
    var bits_filled: Int = 0
    for vi in range(len(values)):
        var value = values[vi]
        var need = bits
        while need > 0:
            var space = 8 - bits_filled
            var take = need if need < space else space
            var shift = need - take
            var chunk = (value >> UInt64(shift)) & ((UInt64(1) << UInt64(take)) - 1)
            cur = (cur << UInt64(take)) | chunk
            bits_filled += take
            need -= take
            if bits_filled == 8:
                out.append(UInt8(cur & 0xFF))
                cur = 0
                bits_filled = 0
    if bits_filled > 0:
        # left-justify the final partial byte (MSB-first).
        out.append(UInt8((cur << UInt64(8 - bits_filled)) & 0xFF))


def _emit_short_repeat(
    mut out: List[UInt8], value: UInt64, run_len: Int
):
    """Emit a Short Repeat run (3..10 identical values). value is the raw
    (zigzagged-if-signed) magnitude; W = ceil(significant bytes), >= 1."""
    var byte_width = 1
    var x = value
    while x > 0xFF:
        byte_width += 1
        x >>= 8
    # byte0: 0b00 (Short Repeat) | (W-1)<<3 | (R-3).
    var header = ((byte_width - 1) << 3) | (run_len - 3)
    out.append(UInt8(header))
    # W big-endian bytes of value.
    for k in range(byte_width):
        var shift = (byte_width - 1 - k) * 8
        out.append(UInt8((value >> UInt64(shift)) & 0xFF))


def _emit_direct(
    mut out: List[UInt8], magnitudes: List[UInt64], run_len: Int
) raises:
    """Emit a Direct run of `run_len` values bit-packed at the run's max width.
    """
    var max_bits = 1
    for i in range(run_len):
        var b = _bit_width(magnitudes[i])
        if b > max_bits:
            max_bits = b
    var enc_w = _encode_bit_width(max_bits)
    var actual_bits = _decoded_bit_width(enc_w)
    # byte0: 0b01 (Direct) | enc_w<<1 | len_hi(bit8 of L-1).
    var len_minus_1 = run_len - 1
    var len_hi = (len_minus_1 >> 8) & 0x1
    var byte0 = (RLEV2_DIRECT_TAG << 6) | (enc_w << 1) | len_hi
    out.append(UInt8(byte0))
    out.append(UInt8(len_minus_1 & 0xFF))
    _pack_bits(out, magnitudes, actual_bits)


comptime RLEV2_DIRECT_TAG: Int = 1


def encode_int_rle_v2(values: List[Int64], signed: Bool) raises -> List[UInt8]:
    """Encode `values` as an RLEv2 stream (Short Repeat + Direct heuristic).

    Round-trips exactly through decode_rlev2(out, len(values), signed).
    """
    var out = List[UInt8]()
    var n = len(values)
    var i = 0
    while i < n:
        # Detect a constant run starting at i (for Short Repeat).
        var const_len = 1
        while (
            i + const_len < n
            and const_len < 10
            and values[i + const_len] == values[i]
        ):
            const_len += 1

        if const_len >= 3:
            # Short Repeat: 3..10 identical values.
            var mag: UInt64
            if signed:
                mag = zigzag_encode(values[i])
            else:
                mag = UInt64(values[i])
            _emit_short_repeat(out, mag, const_len)
            i += const_len
            continue

        # Direct run: gather up to RLEV2_MAX_RUN values, but stop early if a
        # constant run of >= 3 begins (so it can be Short-Repeat-encoded).
        var run_len = 0
        var magnitudes = List[UInt64]()
        while i + run_len < n and run_len < RLEV2_MAX_RUN:
            # Look ahead: if a >=3 constant run starts here (and we already have
            # values queued), break so the constant run gets Short Repeat.
            if run_len > 0:
                var look = 1
                while (
                    i + run_len + look < n
                    and look < 3
                    and values[i + run_len + look] == values[i + run_len]
                ):
                    look += 1
                if look >= 3:
                    break
            var v = values[i + run_len]
            if signed:
                magnitudes.append(zigzag_encode(v))
            else:
                magnitudes.append(UInt64(v))
            run_len += 1
        _emit_direct(out, magnitudes, run_len)
        i += run_len
    return out^
