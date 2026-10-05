# =============================================================================
# Snappy decompression — a Mojo implementation of the classic decoder
# =============================================================================
#
# A port of the classic (pre-"branchless") decompressor in google/snappy's
# snappy.cc. The shipped snappy library builds only the branchless decoder,
# which sends each COPY tag's byte copy through out-of-line helper calls; the
# classic decoder's `IncrementalCopy` is a tight inlined 16-byte loop with no
# calls per tag.
#
# This decoder is compiled into the binary, with no FFI boundary. Its copy
# helpers are `@always_inline`, so the per-tag copy path is inlined 16-byte
# loads and stores with no out-of-line calls, the shape of the classic C++
# decoder.
#
# # Structure (the logic of snappy.cc's classic path)
#
#   RawUncompress → InternalUncompress → DecompressAllTags + SnappyArrayWriter.
#
# Simplified vs. reference: input is a flat complete blob (no Source/RefillTag);
# output is a pre-allocated flat buffer (a page decoder sizes it from the
# page's uncompressed_page_size + kSlopBytes).
#
# # Encapsulation
#
# Every function here is package-private: `snappy_ffi.mojo` builds the
# ByteViews from the caller's Spans and calls the two entries. The
# signatures take `ByteView[_]` / `ByteView[mut=True, _]` plus `Int` byte
# indices — NO `UnsafePointer` and NO wildcard origins escape
# this module. All pointer arithmetic is confined inside ByteView's
# `@always_inline` accessors (bounds-checked via `debug_assert`, elided under
# `-O` so the release codegen is a bare unaligned load/store).
# =============================================================================

from komira_buffer.byte_view import ByteView

from .format import (
    LITERAL,
    COPY_1_BYTE_OFFSET,
    COPY_2_BYTE_OFFSET,
    kSlopBytes,
    kMaximumTagLength,
)
from .varint import _varint_decode32


# =============================================================================
# SIMD copy helpers — @always_inline so the per-tag copy path is inlined
# `movups`/`movdqu` with zero out-of-line calls.
# =============================================================================


@always_inline
def _copy16_cross(
    src: ByteView[_], src_idx: Int, dst: ByteView[mut=True, _], dst_idx: Int
):
    """16-byte unaligned copy from `src[src_idx..]` to `dst[dst_idx..]`.

    Reference: snappy.cc:229-236 UnalignedCopy128. On LE x86/ARM64 this lowers
    to a single unaligned 16-byte load + store (`movdqu` / `ldr q0`).
    """
    dst.store_simd[DType.uint8, 16](dst_idx, src.load_simd[DType.uint8, 16](src_idx))


@always_inline
def _copy16_within(
    dst: ByteView[mut=True, _], src_idx: Int, dst_idx: Int
):
    """16-byte unaligned copy within a single (mutable) view — the within-dst
    back-reference copy fast path."""
    dst.store_simd[DType.uint8, 16](dst_idx, dst.load_simd[DType.uint8, 16](src_idx))


@always_inline
def _copy8_within(dst: ByteView[mut=True, _], src_idx: Int, dst_idx: Int):
    """8-byte unaligned copy within a single view. Reference: snappy.cc:223-227
    UnalignedCopy64."""
    dst.write_u64_le_at(dst_idx, dst.read_u64_le_at(src_idx))


def _incremental_copy_slow(
    dst: ByteView[mut=True, _], src_idx: Int, dst_idx: Int, length: Int
):
    """Byte-by-byte fallback. Reference: snappy.cc:259-271 IncrementalCopySlow.

    Correct for any pattern size, any length: each write becomes readable for
    subsequent reads (RLE), so overlapping src/dst with dst_idx > src_idx is
    well-defined.
    """
    for i in range(length):
        dst.write_u8_at(dst_idx + i, dst.read_u8_at(src_idx + i))


def _incremental_copy(
    dst: ByteView[mut=True, _],
    src_idx: Int,
    dst_idx: Int,
    length: Int,          # number of bytes to write
    buf_limit_offset: Int,  # max bytes writable from dst_idx before the logical
                            # output end (no slop assumed here — conservative)
) -> Int:
    """Copy `length` bytes with pattern extension (RLE).

    Reference: snappy.cc:423-606 IncrementalCopy (non-SSE path).

    Preconditions: src_idx < dst_idx, 0 < length <= 64, length <= buf_limit.
    `pattern_size = dst_idx - src_idx`. When pattern_size < length the pattern
    must be expanded before bulk copies (each copied byte becomes source for
    later reads).
    """
    var pattern_size = dst_idx - src_idx

    if pattern_size >= 8:
        # Each 16-byte read at (src_idx + k) needs pattern_size >= 16 to be
        # purely non-overlapping within a single 16-byte window; for
        # pattern_size in [8..15] bytes 8..15 of the read alias the write.
        if pattern_size >= 16 and length + 15 <= buf_limit_offset:
            # 4x unrolled 16-byte copies (snappy.cc:566-582).
            _copy16_within(dst, src_idx, dst_idx)
            if 16 < length:
                _copy16_within(dst, src_idx + 16, dst_idx + 16)
            if 32 < length:
                _copy16_within(dst, src_idx + 32, dst_idx + 32)
            if 48 < length:
                _copy16_within(dst, src_idx + 48, dst_idx + 48)
            return length
        # 8-byte chunk path: pattern_size >= 8 means each 8-byte read is of
        # already-written bytes and the write doesn't clobber a byte re-read
        # within the SAME chunk.
        if length + 7 <= buf_limit_offset:
            var op = 0
            while op < length:
                _copy8_within(dst, src_idx + op, dst_idx + op)
                op += 8
            return length

    # pattern_size < 8 OR tight slop: byte-by-byte (always correct).
    _incremental_copy_slow(dst, src_idx, dst_idx, length)
    return length


# =============================================================================
# uncompressed_length (pure-Mojo — no libsnappy dependency)
# =============================================================================


@always_inline
def _snappy_uncompressed_length_mojo(compressed: ByteView[_]) raises -> Int:
    """Read the uncompressed length from a Snappy preamble (pure Mojo)."""
    var parsed = _varint_decode32(compressed)
    return Int(parsed[0])


# =============================================================================
# Decode status codes + result (the per-tag error paths are kept out of line)
# =============================================================================
#
# A `raise Error(String(...))` inlined into the hot decode function brings the
# String construction, stack-trace and refcount machinery into its body and
# roughly doubles its size. So the hot loop (`_snappy_decode_core`) returns a
# `_DecodeResult` STATUS
# instead of raising — it constructs ZERO Error Strings, so none of the String
# machinery lands in its body. The single `raise` is deferred to the `@no_inline`
# cold mapper `_raise_decode_error`, reached ONLY from the thin
# `_snappy_decompress_mojo` boundary wrapper on a non-OK status (never on valid
# input). This is the C++ decoder's shape: a status-returning tag loop + a one-shot
# error raise at the RawUncompress boundary.
# =============================================================================

comptime _DEC_OK: Int = 0
comptime _DEC_EMPTY_INPUT: Int = 1
comptime _DEC_BAD_PREAMBLE: Int = 2
comptime _DEC_DST_TOO_SMALL: Int = 3
comptime _DEC_TRUNC_LONGLIT_LEN: Int = 4
comptime _DEC_LIT_PAST_INPUT: Int = 5
comptime _DEC_LIT_PAST_UNCOMP: Int = 6
comptime _DEC_TRUNC_COPY1: Int = 7
comptime _DEC_TRUNC_COPY2: Int = 8
comptime _DEC_TRUNC_COPY4: Int = 9
comptime _DEC_LEN_MISMATCH: Int = 10
comptime _DEC_TRAILING: Int = 11
comptime _DEC_COPY_OFFSET_ZERO: Int = 12
comptime _DEC_COPY_OFFSET_EXCEEDS: Int = 13
comptime _DEC_COPY_PAST_UNCOMP: Int = 14


@fieldwise_init
struct _DecodeResult(Copyable, Movable):
    """Hot-loop return: a status code + the context ints the cold error mapper
    needs to reconstruct the human-readable message. All-POD (4 Ints, no
    heap-owning fields) — returned by value, never stored in a byte slab."""
    var status: Int    # _DEC_OK or a _DEC_* error
    var written: Int   # `op` at return — bytes produced
    var expected: Int  # `uncompressed_len` (0 until the preamble is parsed)
    var consumed: Int  # `ip` at return — compressed bytes consumed


@always_inline
def _varint_decode32_status(data: ByteView[_]) -> Tuple[UInt32, Int, Int]:
    """Non-raising varint (LEB128) decode for the hot decode core. Returns
    `(value, bytes_consumed, status)`; on a malformed varint `status` is
    `_DEC_BAD_PREAMBLE` (or `_DEC_EMPTY_INPUT` for empty) and `(value, consumed)`
    are unspecified. Mirrors `_varint_decode32` but returns a status code instead
    of constructing an Error String, keeping the String machinery out of the hot
    function."""
    var data_len = data.len()
    if data_len == 0:
        return (UInt32(0), 0, _DEC_EMPTY_INPUT)
    var result: UInt32 = 0
    var shift: UInt32 = 0
    var pos = 0
    while pos < data_len:
        if shift >= 32:
            return (UInt32(0), pos, _DEC_BAD_PREAMBLE)
        var byte = data.read_u8_at(pos)
        pos += 1
        var val: UInt32 = UInt32(byte) & 0x7F
        if shift == 28 and val > 0xF:
            return (UInt32(0), pos, _DEC_BAD_PREAMBLE)
        result = result | (val << shift)
        if (UInt32(byte) & 0x80) == 0:
            return (result, pos, _DEC_OK)
        shift += 7
    return (UInt32(0), pos, _DEC_BAD_PREAMBLE)


# =============================================================================
# Main decoder
# =============================================================================


def _snappy_decompress_mojo(
    compressed: ByteView[_],
    dst: ByteView[mut=True, _],
) raises -> Int:
    """Decompress a raw/unframed Snappy blob into `dst`. Returns bytes written.

    PERF-CRITICAL slop requirement: the 16-byte-store fast paths run only
    when `dst.len() >= uncompressed_length + kSlopBytes` (64), as a page
    decoder sizes it. With less room every overshooting path is off
    (`has_slop` false) and each tag stores exactly the bytes it produces, so
    nothing is written past `dst.len()` — correct, just slower.

    Thin boundary wrapper: the hot decode runs in
    `_snappy_decode_core`, which returns a status (ZERO inlined error-String
    machinery). This wrapper raises ONCE — via the `@no_inline` cold mapper — on
    a non-OK status. Reference entry: RawUncompress (snappy.cc:2245) →
    InternalUncompress (snappy.cc:1785) → DecompressAllTags (snappy.cc:1576).
    """
    var r = _snappy_decode_core(compressed, dst)
    if r.status != _DEC_OK:
        _raise_decode_error(r, compressed.len(), dst.len())
    return r.written


def _snappy_decode_core(
    compressed: ByteView[_],
    dst: ByteView[mut=True, _],
) -> _DecodeResult:
    """Hot decode loop (the C++ `DecompressAllTags` analog). Returns a
    `_DecodeResult` status instead of raising, so the function body carries ZERO
    inlined `raise Error(...)` machinery: no String ctor, no StackTrace, no
    atomic refcount drops. ALL error reporting is deferred to the `@no_inline`
    `_raise_decode_error` at the `_snappy_decompress_mojo` boundary.
    """
    var compressed_len = compressed.len()
    var dst_cap = dst.len()
    if compressed_len == 0:
        return _DecodeResult(_DEC_EMPTY_INPUT, 0, 0, 0)

    # --- 1. Read preamble ---
    var pre = _varint_decode32_status(compressed)
    if pre[2] != _DEC_OK:
        return _DecodeResult(pre[2], 0, 0, pre[1])
    var uncompressed_len = Int(pre[0])
    var ip_start = pre[1]

    if uncompressed_len > dst_cap:
        return _DecodeResult(_DEC_DST_TOO_SMALL, 0, uncompressed_len, ip_start)

    # The 16-byte-store fast paths may write up to 15 bytes past the bytes a
    # tag produces, so they run only when `dst` has kSlopBytes of room past
    # the decoded length (`has_slop`). Without it every tag takes a path
    # that stores exactly the bytes it produces.
    #
    # Each wide-store site is guarded by `has_slop`, directly or through
    # `op < op_slop_limit` (op_slop_limit is 0 without slop, so that test is
    # then false for every op): `op_slop_limit` is the largest op from which
    # a 16-byte store stays inside the decoded length plus the slop
    # (snappy.cc:2182 op_limit_min_slop). An end bound alone is not a guard:
    # `op + n <= op_slop_limit + (kSlopBytes - 1)` holds for small n at
    # op_slop_limit 0, which is how a 16-byte store once ran past an
    # exact-size `dst`.
    var has_slop = dst_cap >= uncompressed_len + kSlopBytes
    var op_slop_limit: Int
    if has_slop:
        op_slop_limit = uncompressed_len - (kSlopBytes - 1)
    else:
        op_slop_limit = 0

    var ip = ip_start
    var op = 0

    # --- 2. Tag stream (DecompressAllTags, snappy.cc:1576; copy paths 1667-1694) ---
    while ip < compressed_len and op < uncompressed_len:
        var c = Int(compressed.read_u8_at(ip))
        ip += 1
        var tag_type = c & 3

        if tag_type == LITERAL:
            # --- Literal (snappy.cc:1631-1666) ---
            var literal_length: Int
            var len_minus_1 = c >> 2
            if len_minus_1 < 60:
                literal_length = len_minus_1 + 1
                # PERF-CRITICAL: "TryFastAppend" (snappy.cc:2203-2215). ~95% of
                # literal invocations hit this (len <= 16). Safe overshoot: 16B
                # past op is within uncompressed_len + kSlopBytes (op <
                # op_slop_limit); 16B past ip needs kMaximumTagLength more
                # compressed bytes for the next tag.
                if (
                    literal_length <= 16
                    and op < op_slop_limit
                    and ip + 16 + kMaximumTagLength <= compressed_len
                ):
                    _copy16_cross(compressed, ip, dst, op)
                    ip += literal_length
                    op += literal_length
                    continue
            else:
                var extra = len_minus_1 - 59   # 1..4
                if ip + extra > compressed_len:
                    return _DecodeResult(
                        _DEC_TRUNC_LONGLIT_LEN, op, uncompressed_len, ip
                    )
                var length_m1: UInt32 = 0
                for i in range(extra):
                    length_m1 = length_m1 | (
                        UInt32(compressed.read_u8_at(ip + i)) << UInt32(i * 8)
                    )
                ip += extra
                literal_length = Int(length_m1) + 1

            if ip + literal_length > compressed_len:
                return _DecodeResult(
                    _DEC_LIT_PAST_INPUT, op, uncompressed_len, ip
                )
            if op + literal_length > uncompressed_len:
                return _DecodeResult(
                    _DEC_LIT_PAST_UNCOMP, op, uncompressed_len, ip
                )
            # PERF-CRITICAL long-literal: 16-byte-stride inlined SIMD copy is
            # faster than a libc memcpy call for sizes 60..~2KB (no call
            # overhead). The loop may write up to 15 bytes past literal_length,
            # so it needs the slop: op + literal_length <= uncompressed_len is
            # checked above, and the slop covers the last store's overshoot.
            # Reference: EmitLiteral allow_fast_path loop (snappy.cc:648-656).
            # This is the DOMINANT path for poorly compressible data (FLOAT64 =
            # mostly long literals) — the loop LLVM should emit as a tight
            # `movdqu` self-loop like the C++ decoder's inlined literal copy.
            if (
                has_slop
                and literal_length >= 16
                and ip + literal_length + 15 <= compressed_len
            ):
                var i = 0
                while i < literal_length:
                    _copy16_cross(compressed, ip + i, dst, op + i)
                    i += 16
            else:
                # Cold fallback: non-overshoot exact copy (near buffer end, or
                # tight input). memcpy-backed, non-overlapping (compressed→dst).
                dst.copy_from_view_at(op, compressed.sub(ip, literal_length))
            ip += literal_length
            op += literal_length

        elif tag_type == COPY_1_BYTE_OFFSET:
            # --- Copy, 1-byte offset (snappy.cc:1674-1692).
            # length in [4..11], offset in [0..2047].
            if ip >= compressed_len:
                return _DecodeResult(_DEC_TRUNC_COPY1, op, uncompressed_len, ip)
            var length = ((c >> 2) & 7) + 4
            var offset = ((c >> 5) << 8) | Int(compressed.read_u8_at(ip))
            ip += 1
            # PERF-CRITICAL: offset >= 16 & slop → single 16-byte within-dst
            # store from dst[op-offset]. Max copy-1 length is 11 (< 16), and
            # offset >= 16 guarantees read/write windows don't overlap.
            if offset >= 16 and op < op_slop_limit and offset <= op:
                _copy16_within(dst, op - offset, op)
                op += length
                continue
            var st = _apply_copy(dst, op, uncompressed_len, offset, length)
            if st != _DEC_OK:
                return _DecodeResult(st, op, uncompressed_len, ip)
            op += length

        elif tag_type == COPY_2_BYTE_OFFSET:
            # --- Copy, 2-byte offset. length in [1..64], offset in [0..65535].
            if ip + 2 > compressed_len:
                return _DecodeResult(_DEC_TRUNC_COPY2, op, uncompressed_len, ip)
            var length = (c >> 2) + 1
            var offset = Int(compressed.read_u16_le_at(ip))
            ip += 2
            # PERF-CRITICAL: offset >= 16, length <= 16, slop → single 16-byte store.
            if (
                offset >= 16
                and length <= 16
                and op < op_slop_limit
                and offset <= op
            ):
                _copy16_within(dst, op - offset, op)
                op += length
                continue
            # PERF-CRITICAL: length > 16, offset >= 16 → inlined 16-byte-stride
            # copy (common on text with long identical runs). The last store
            # may overshoot op + length by up to 15 bytes, into the slop.
            if (
                has_slop
                and offset >= 16
                and op + length <= uncompressed_len
                and offset <= op
            ):
                var i = 0
                while i < length:
                    _copy16_within(dst, (op - offset) + i, op + i)
                    i += 16
                op += length
                continue
            var st = _apply_copy(dst, op, uncompressed_len, offset, length)
            if st != _DEC_OK:
                return _DecodeResult(st, op, uncompressed_len, ip)
            op += length

        else:
            # --- Copy, 4-byte offset (snappy.cc:1668-1673).
            if ip + 4 > compressed_len:
                return _DecodeResult(_DEC_TRUNC_COPY4, op, uncompressed_len, ip)
            var length = (c >> 2) + 1
            var offset = Int(compressed.read_u32_le_at(ip))
            ip += 4
            var st = _apply_copy(dst, op, uncompressed_len, offset, length)
            if st != _DEC_OK:
                return _DecodeResult(st, op, uncompressed_len, ip)
            op += length

    # --- 3. Length check ---
    if op != uncompressed_len:
        return _DecodeResult(_DEC_LEN_MISMATCH, op, uncompressed_len, ip)
    if ip != compressed_len:
        return _DecodeResult(_DEC_TRAILING, op, uncompressed_len, ip)

    return _DecodeResult(_DEC_OK, op, uncompressed_len, ip)


@no_inline
def _raise_decode_error(
    r: _DecodeResult, compressed_len: Int, dst_cap: Int
) raises:
    """Cold, out-of-line status→Error mapper. ALL of the
    decoder's String construction / StackTrace / refcount machinery lives here
    so it stays OUT of the hot `_snappy_decode_core` body. Never called on valid
    input; `@no_inline` guarantees it is not folded back into the caller."""
    var s = r.status
    if s == _DEC_EMPTY_INPUT:
        raise Error("snappy: empty input")
    if s == _DEC_BAD_PREAMBLE:
        raise Error("snappy: malformed varint length preamble")
    if s == _DEC_DST_TOO_SMALL:
        raise Error(
            "snappy: output buffer too small: need " + String(r.expected)
            + " bytes but cap is " + String(dst_cap)
        )
    if s == _DEC_TRUNC_LONGLIT_LEN:
        raise Error("snappy: truncated long-literal length field")
    if s == _DEC_LIT_PAST_INPUT:
        raise Error("snappy: literal extends past end of compressed input")
    if s == _DEC_LIT_PAST_UNCOMP:
        raise Error("snappy: literal writes past declared uncompressed length")
    if s == _DEC_TRUNC_COPY1:
        raise Error("snappy: truncated copy-1 (missing offset byte)")
    if s == _DEC_TRUNC_COPY2:
        raise Error("snappy: truncated copy-2 (missing offset bytes)")
    if s == _DEC_TRUNC_COPY4:
        raise Error("snappy: truncated copy-4 (missing offset bytes)")
    if s == _DEC_LEN_MISMATCH:
        raise Error(
            "snappy: produced " + String(r.written)
            + " bytes but preamble declared " + String(r.expected)
        )
    if s == _DEC_TRAILING:
        raise Error(
            "snappy: trailing bytes after final tag ("
            + String(compressed_len - r.consumed) + " left over)"
        )
    if s == _DEC_COPY_OFFSET_ZERO:
        raise Error("snappy: copy offset is zero (illegal)")
    if s == _DEC_COPY_OFFSET_EXCEEDS:
        raise Error(
            "snappy: copy offset exceeds produced bytes " + String(r.written)
        )
    if s == _DEC_COPY_PAST_UNCOMP:
        raise Error("snappy: copy writes past declared uncompressed length")
    raise Error("snappy: decode failed (status=" + String(s) + ")")


def _apply_copy(
    dst: ByteView[mut=True, _],
    op: Int,
    uncompressed_len: Int,
    offset: Int,
    length: Int,
) -> Int:
    """Apply a copy tag: write `length` bytes to dst[op..], reading from
    dst[op-offset..] with RLE extension. Returns `_DEC_OK` or a `_DEC_COPY_*`
    status — no `raise` (keeps the String machinery out of the copy
    path; the core maps a non-OK status into a `_DecodeResult`).

    Reference: SnappyArrayWriter::AppendFromSelf (snappy.cc:2217-2237). This is
    the small-offset / near-end handler (the main loop peels off the
    offset>=16 + in-slop fast cases inline).
    """
    # snappy.cc:2218: offset must be > 0 and <= produced bytes. The C++
    # "offset - 1u >= op" unsigned trick catches offset==0 and offset>op at
    # once; we check explicitly.
    if offset == 0:
        return _DEC_COPY_OFFSET_ZERO
    if offset > op:
        return _DEC_COPY_OFFSET_EXCEEDS
    if op + length > uncompressed_len:
        return _DEC_COPY_PAST_UNCOMP

    var src_idx = op - offset
    var dst_idx = op

    if offset >= length:
        # Non-overlapping copy — memcpy is legal.
        # PERF-CRITICAL: for length <= 16, one inlined 16-byte store beats a
        # libc memcpy call. (op + 16 <= uncompressed_len keeps it in-bounds of
        # the logical end even without relying on slop here.)
        if length <= 16 and op + 16 <= uncompressed_len:
            _copy16_within(dst, src_idx, dst_idx)
            return _DEC_OK
        # Cold near-end fallback (op >= op_slop_limit, length > 16). Exact
        # byte copy through `self` only — a within-dst `copy_from_view_at`
        # would alias `dst.origin` (exclusivity violation), and a chunked
        # 8/16-byte copy could overshoot the buffer end when no slop is
        # present. Non-overlapping (offset >= length), so scalar is correct.
        _incremental_copy_slow(dst, src_idx, dst_idx, length)
        return _DEC_OK

    # offset < length → RLE extension required.
    # PERF-CRITICAL: offset == 1 is very common in text (runs of spaces/zeros).
    if offset == 1:
        var b = dst.read_u8_at(op - 1)
        dst.sub(op, length).fill(b)
        return _DEC_OK
    # PERF-CRITICAL: offset == 2 (CRLF / 16-bit ASCII). Build an 8-byte expanded
    # pattern, then splat it in 8-byte chunks. Guard against overshooting the
    # allocated buffer (the last chunk overshoots op+length by up to 7 bytes).
    if offset == 2 and op + length + 10 <= dst.len():
        var b0 = dst.read_u8_at(op - 2)
        var b1 = dst.read_u8_at(op - 1)
        # LE u64 whose byte sequence is b0 b1 b0 b1 b0 b1 b0 b1.
        var pat: UInt64 = (
            UInt64(b0)
            | (UInt64(b1) << 8)
            | (UInt64(b0) << 16)
            | (UInt64(b1) << 24)
            | (UInt64(b0) << 32)
            | (UInt64(b1) << 40)
            | (UInt64(b0) << 48)
            | (UInt64(b1) << 56)
        )
        var i = 0
        while i < length:
            dst.write_u64_le_at(op + i, pat)
            i += 8
        return _DEC_OK

    var buf_limit_offset = uncompressed_len - op
    _ = _incremental_copy(dst, src_idx, dst_idx, length, buf_limit_offset)
    return _DEC_OK
