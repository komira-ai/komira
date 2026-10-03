# =============================================================================
# FFI-BOUNDARY: avro_codec.mojo — OCF block codec decompression (full matrix).
# =============================================================================
#
# The full Avro 1.11.1 codec matrix:
#   null      — no-op passthrough.
#   snappy    — raw_snappy ‖ BE4 crc32(uncompressed) framing.
#   deflate   — libz inflateInit2(-15), RAW RFC-1951 — NOT
#               zlib-wrapped; NOT reusable from Parquet's GZIP arm.
#   zstandard — libzstd ZSTD_decompress; wire string is "zstandard"
#               byte-equal, NOT "zstd" — dispatch enforced in ocf_header.
#   bzip2     — libbz2 BZ2_bzBuffToBuffDecompress; no Avro framing.
#   xz        — liblzma lzma_stream_buffer_decode; no Avro framing.
#
# CRITICAL Avro snappy wire detail: the snappy block payload is
#
#     raw_snappy_compressed_bytes ‖ BE4 crc32(uncompressed_bytes)
#
# i.e. the last 4 bytes are a big-endian CRC32 (IEEE 802.3) of the
# UNCOMPRESSED data. The decoder MUST strip those 4 bytes BEFORE calling
# `snappy_uncompress`, then VALIDATE the CRC32 of the decompressed result
# against the trailer. A direct libsnappy call on the raw payload FAILS.
#
# Encapsulation: the public entry `decompress_block(codec_tag, payload)` takes
# a borrowed `Span[UInt8]` and returns an owned `List[UInt8]` of decompressed
# bytes. No UnsafePointer crosses the module boundary. The codec FFI is an
# FFI carve-out — pointer arithmetic is
# confined to the FFI call site with a # SAFETY: comment.
#
# The codec bindings are local to this package (it does not depend on
# komira_parquet): snappy is statically linked through `komira_core`'s
# dependency on it; the other codec libraries are opened with a
# process-lifetime OwnedDLHandle per library (per-OS soname).
# =============================================================================

from std.memory import unsafe_memcpy, unsafe_memset, alloc
from std.ffi import OwnedDLHandle, _Global, external_call
from std.os import abort

from std.sys.info import CompilationTarget

from .ocf_header import (
    AVRO_CODEC_NULL,
    AVRO_CODEC_SNAPPY,
    AVRO_CODEC_DEFLATE,
    AVRO_CODEC_BZIP2,
    AVRO_CODEC_XZ,
    AVRO_CODEC_ZSTANDARD,
    codec_wire_name,
)


# =============================================================================
# FFI buffer-coercion helpers (like komira_core.arrow.compression_codecs).
# =============================================================================
#
# The compress / decompress helpers pass the input Span pointer DIRECTLY to
# FFI via `_span_ptr` (no input buffer copy) and write DIRECTLY into the output
# `List[UInt8]`'s reserved backing storage via `_list_ptr` (no output buffer
# copy). Copying through scratch buffers instead costs two allocs / frees per
# block and a byte-by-byte store of every input and output byte.
#
# SAFETY: the helpers cast to `MutExternalOrigin` for the FFI seam (FFI
# carve-out); both Span and List remain alive across the synchronous codec call,
# their backing storage is heap-owned and not reallocated for the duration.


@always_inline
def _span_ptr(s: Span[UInt8, _]) -> UnsafePointer[UInt8, MutUntrackedOrigin]:
    """Coerce a `Span[UInt8, _]` to a `MutExternalOrigin`-cast UnsafePointer
    for FFI. FFI-BOUNDARY: synchronous C call; caller owns the buffer.
    """
    # SAFETY: see header. The cast does not extend lifetime; the Span ref
    # remains in scope across the external_call below.
    return (
        s.unsafe_ptr()
        .unsafe_mut_cast[True]()
        .unsafe_origin_cast[MutUntrackedOrigin]()
    )


@always_inline
def _list_ptr(
    mut buf: List[UInt8],
) -> UnsafePointer[UInt8, MutUntrackedOrigin]:
    """Coerce a `List[UInt8]`'s data pointer to FFI shape."""
    # SAFETY: synchronous FFI; `buf` is not reallocated across the call
    # because the caller pre-reserved capacity (no append happens between
    # this call and consumption of the pointer).
    return buf.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin]()


@always_inline
def _null_ffi_byte() -> UnsafePointer[UInt8, MutUntrackedOrigin]:
    """A raw NULL FFI byte pointer (Mojo has no null `UnsafePointer`
    constructor, and `unsafe_from_address=0` is banned).

    # SAFETY: `Optional[UnsafePointer[...]]` is layout-compatible with the bare
    # pointer (the Mojo non-null-pointer layout guarantee); `None` is the all-zero
    # (NULL) bit pattern. Used only for explicit C-NULL arguments (liblzma's
    # allocator = NULL → "use the default malloc/free").
    """
    var none: Optional[UnsafePointer[UInt8, MutUntrackedOrigin]] = None
    return UnsafePointer(to=none).bitcast[
        UnsafePointer[UInt8, MutUntrackedOrigin]
    ]()[]


# =============================================================================
# Public entry — decompress one OCF block payload by codec tag.
# =============================================================================


def decompress_block(
    codec_tag: Int, payload: Span[UInt8, _], uncompressed_hint: Int = 0
) raises -> List[UInt8]:
    """Decompress an OCF block payload by codec tag (full Avro codec matrix).

    Args:
        codec_tag: AVRO_CODEC_* tag from the OCF header.
        payload: Borrowed view of the on-disk (post-compression) block bytes.
        uncompressed_hint: Optional hint for the decompressed size. Used by the
            grow-on-overflow codecs (deflate / bzip2 / xz) to seed the first
            output-buffer estimate; ignored by snappy / zstandard (which carry
            their own length preamble / frame header).

    Returns:
        Owned List[UInt8] of decompressed bytes.

    Raises:
        On an unknown codec tag or a codec failure (snappy status /
        CRC32 mismatch / inflate / bzip2 / xz / zstd error).
    """
    if codec_tag == AVRO_CODEC_NULL:
        # No-op codec: copy the borrowed bytes into an owned List via a single
        # bulk `List.extend(Span)` -> `uninit_copy_n` -> one memcpy (a per-byte
        # append loop is measurably slower on a null-codec read). Same shape
        # as the string accumulator's `push_bytes` in `action_table.mojo`.
        var n = len(payload)
        var out = List[UInt8](capacity=n)
        out.extend(payload)
        return out^
    elif codec_tag == AVRO_CODEC_SNAPPY:
        return _decompress_snappy_avro(payload)
    elif codec_tag == AVRO_CODEC_DEFLATE:
        return _decompress_deflate_avro(payload, uncompressed_hint)
    elif codec_tag == AVRO_CODEC_ZSTANDARD:
        return _decompress_zstandard_avro(payload, uncompressed_hint)
    elif codec_tag == AVRO_CODEC_BZIP2:
        return _decompress_bzip2_avro(payload, uncompressed_hint)
    elif codec_tag == AVRO_CODEC_XZ:
        return _decompress_xz_avro(payload, uncompressed_hint)
    raise Error(
        String("AvroCodecError.UNKNOWN_CODEC: tag ") + String(codec_tag)
    )


# =============================================================================
# Grow-on-overflow output sizing for the codecs without an inline length.
# =============================================================================
#
# Avro OCF blocks do NOT carry the uncompressed length inline (unlike snappy's
# preamble or a zstd frame header). For deflate / bzip2, we must guess an
# output capacity and grow it on a buffer-too-small signal. The first guess is
# max(uncompressed_hint, 4 * payload, MIN); each retry quadruples capacity.

comptime _MIN_OUTPUT_GUESS: Int = 4096
comptime _MAX_OUTPUT_CAP: Int = 1 << 31  # 2 GiB ceiling — refuse beyond this.

# UNTRUSTED INPUT. Two codecs let the COMPRESSED STREAM
# declare its own decompressed size — snappy's varint preamble and zstd's
# Frame_Content_Size — and both declarations were used verbatim as an
# allocation size with no relation to the block's actual byte count. A ~40-byte
# block could ask for 4 GiB (snappy) or, once `Int(content)` went negative,
# make the allocation and the declared `dstCapacity` disagree (zstd, a genuine
# heap overflow). This ceiling is the shared upper bound: an Avro block is a
# batching unit, typically 64 KiB and never remotely this large, so 2 GiB
# refuses nothing real. Kept equal to `_MAX_OUTPUT_CAP` so the declared-size
# codecs and the grow-loop codecs enforce one number.
comptime MAX_DECOMPRESSED_BLOCK_BYTES: Int = _MAX_OUTPUT_CAP


@always_inline
def _initial_output_guess(payload_len: Int, hint: Int) -> Int:
    var guess = payload_len * 4
    if hint > guess:
        guess = hint
    if guess < _MIN_OUTPUT_GUESS:
        guess = _MIN_OUTPUT_GUESS
    return guess


# =============================================================================
# Snappy (Avro framing: raw_snappy ‖ BE4 crc32(uncompressed)).
# =============================================================================


def _decompress_snappy_avro(payload: Span[UInt8, _]) raises -> List[UInt8]:
    """Strip + validate the BE4 CRC32 trailer, then snappy-uncompress.

    The Avro snappy block is `raw_snappy_compressed ‖ BE4 crc32(uncompressed)`.
    """
    var total = len(payload)
    if total < 4:
        raise Error(
            "AvroCodecError.SNAPPY_TRUNCATED: payload < 4-byte CRC trailer"
        )
    var snappy_len = total - 4
    # BE4 CRC32 trailer (last 4 bytes, big-endian).
    var crc_expected: UInt32 = 0
    crc_expected |= UInt32(payload[snappy_len + 0]) << 24
    crc_expected |= UInt32(payload[snappy_len + 1]) << 16
    crc_expected |= UInt32(payload[snappy_len + 2]) << 8
    crc_expected |= UInt32(payload[snappy_len + 3])

    var out = _snappy_uncompress(payload, snappy_len)

    var crc_actual = crc32_ieee(Span(out))
    if crc_actual != crc_expected:
        raise Error(
            String("AvroCodecError.SNAPPY_CRC32_MISMATCH: expected ")
            + String(Int(crc_expected))
            + ", got "
            + String(Int(crc_actual))
        )
    return out^


def _snappy_uncompress(
    payload: Span[UInt8, _], snappy_len: Int
) raises -> List[UInt8]:
    """Call libsnappy `snappy_uncompress` on the first `snappy_len` bytes of
    `payload` (the raw snappy stream, trailer already excluded by length).

    Returns an owned List[UInt8] of the decompressed bytes.

    Zero-copy, like `_compress_snappy_avro`: no input scratch copy and no
    per-byte output copy (snappy writes straight into the returned List).
    Every reader (columnar and row-typed, serial and parallel) dispatches
    through this helper via `decompress_block(SNAPPY, raw)`.

    SAFETY (FFI carve-out): `payload` is alive
    across the synchronous libsnappy call (caller's borrow). `out` is a
    fresh List with capacity pre-reserved to `ulen` so libsnappy writes
    directly into its uninitialized backing store — no realloc across
    the call, no aliasing with `payload`. `size_buf` is heap-owned for
    the call; freed before return.
    """
    # Query the declared uncompressed length from the snappy preamble.
    var in_ptr = _span_ptr(payload)
    var len_buf = alloc[Int64](1)
    len_buf[0] = Int64(0)
    var len_status = external_call["snappy_uncompressed_length", Int32](
        in_ptr,
        Int64(snappy_len),
        len_buf,
    )
    if Int(len_status) != 0:
        len_buf.free()
        raise Error("AvroCodecError.SNAPPY_LENGTH_FAILED")
    var ulen = Int(len_buf[0])
    len_buf.free()
    # UNTRUSTED INPUT. `ulen` is the snappy stream's own
    # uncompressed-length preamble — an attacker-chosen varint inside the block
    # payload — and was used verbatim as `List(capacity=ulen)` with nothing
    # relating it to the block's size. The WRITE is safe (libsnappy bounds its
    # output by `*size_buf`, which equals this reserved capacity), so this is
    # allocation amplification rather than corruption: a ~40-byte block could
    # declare 4 GiB and get it. Bounded here, at the one place the declaration
    # enters the process.
    if ulen < 0 or ulen > MAX_DECOMPRESSED_BLOCK_BYTES:
        raise Error(
            String(
                "AvroCodecError.SNAPPY_LENGTH_OUT_OF_RANGE: stream declares "
            )
            + String(ulen)
            + " uncompressed bytes from a "
            + String(snappy_len)
            + "-byte block; the ceiling is "
            + String(MAX_DECOMPRESSED_BLOCK_BYTES)
        )

    var out = List[UInt8](capacity=max(ulen, 1))
    var size_buf = alloc[Int64](1)
    size_buf[0] = Int64(ulen)
    var status = external_call["snappy_uncompress", Int32](
        in_ptr,
        Int64(snappy_len),
        _list_ptr(out),
        size_buf,
    )
    var written = Int(size_buf[0])
    size_buf.free()
    if Int(status) != 0:
        raise Error(
            String("AvroCodecError.SNAPPY_UNCOMPRESS_FAILED: status ")
            + String(Int(status))
        )
    # SAFETY: pre-reserved capacity == max(ulen, 1) >= written.
    out.resize(unsafe_uninit_length=written)
    return out^


# =============================================================================
# Deflate (RAW RFC-1951, libz inflateInit2(-15)).
# =============================================================================
#
# Avro deflate blocks are RAW DEFLATE (RFC 1951): no zlib header, no ADLER32
# trailer. This is NOT the framing Parquet's GZIP arm uses (zlib-wrapped or
# auto-detect windowBits=15+32), so the libz handle is reused but the
# inflateInit2_ windowBits MUST be NEGATIVE (-15) to select raw mode.
#
# z_stream layout (LP64): the zlib `z_stream` struct.

comptime _Z_STREAM_SIZE: Int = 112
comptime _Z_OK: Int = 0
comptime _Z_STREAM_END: Int = 1
comptime _Z_BUF_ERROR: Int = -5
comptime _Z_NO_FLUSH: Int = 0
# windowBits = -15: RAW deflate (no zlib header, no ADLER32). NOT 15+32.
comptime _Z_WINDOWBITS_RAW: Int32 = -15


def _decompress_deflate_avro(
    payload: Span[UInt8, _], hint: Int
) raises -> List[UInt8]:
    """Inflate a RAW RFC-1951 deflate block (libz inflateInit2(-15)).

    Grows the output buffer on Z_BUF_ERROR (Avro blocks carry no inline
    uncompressed length).
    """
    var cap = _initial_output_guess(len(payload), hint)
    while True:
        var res = _inflate_raw_once(payload, cap)
        if res.ok:
            var out = List[UInt8]()
            for i in range(res.written):
                out.append(res.buf[i])
            res.buf.free()
            return out^
        res.buf.free()
        if not res.need_more:
            raise Error(
                String("AvroCodecError.DEFLATE_FAILED: inflate rc ")
                + String(res.rc)
            )
        if cap >= _MAX_OUTPUT_CAP:
            raise Error("AvroCodecError.DEFLATE_OUTPUT_OVERFLOW")
        cap *= 4


struct _InflateResult:
    """Result of one inflate attempt: success flag, grow-retry flag, the owned
    output scratch buffer (caller frees), bytes written, and the raw rc."""

    var ok: Bool
    var need_more: Bool
    var buf: UnsafePointer[UInt8, MutUntrackedOrigin]
    var written: Int
    var rc: Int

    def __init__(
        out self,
        ok: Bool,
        need_more: Bool,
        buf: UnsafePointer[UInt8, MutUntrackedOrigin],
        written: Int,
        rc: Int,
    ):
        self.ok = ok
        self.need_more = need_more
        self.buf = buf
        self.written = written
        self.rc = rc


def _inflate_raw_once(
    payload: Span[UInt8, _], output_cap: Int
) raises -> _InflateResult:
    """One raw-deflate inflate pass into a fresh `output_cap` scratch buffer.

    On Z_BUF_ERROR (or Z_OK without STREAM_END = ran out of output room),
    returns need_more=True so the caller can grow + retry. On hard error,
    returns ok=False need_more=False with the rc.

    SAFETY (FFI carve-out): `strm` is a 112-byte opaque z_stream scratch +
    `in_buf` (compressed copy) + `out_buf` (decompressed scratch), all
    process-owned heap for the duration of the synchronous inflate. libz never
    retains the pointers; `strm` + `in_buf` are freed before return, `out_buf`
    is handed back to the caller to free.
    """
    var in_len = len(payload)
    var in_buf = alloc[UInt8](max(in_len, 1))
    for i in range(in_len):
        in_buf[i] = payload[i]
    var out_buf = alloc[UInt8](max(output_cap, 1))

    var handle_ptr = _default_z_handle()
    var version = handle_ptr[].call[
        "zlibVersion", UnsafePointer[UInt8, MutUntrackedOrigin]
    ]()

    var strm = alloc[UInt8](_Z_STREAM_SIZE)
    unsafe_memset(strm, 0, _Z_STREAM_SIZE)
    # next_in @ offset 0; avail_in @ offset 8; next_out @ offset 24;
    # avail_out @ offset 32 (LP64). See parquet/compression.mojo layout note.
    (strm.bitcast[UInt64]() + 0)[] = UInt64(Int(in_buf))
    (strm.bitcast[UInt32]() + 2)[] = UInt32(in_len)
    (strm.bitcast[UInt64]() + 3)[] = UInt64(Int(out_buf))
    (strm.bitcast[UInt32]() + 8)[] = UInt32(output_cap)

    var init_rc = handle_ptr[].call["inflateInit2_", Int32](
        strm, _Z_WINDOWBITS_RAW, version, Int32(_Z_STREAM_SIZE)
    )
    if Int(init_rc) != _Z_OK:
        strm.free()
        in_buf.free()
        return _InflateResult(False, False, out_buf, 0, Int(init_rc))

    var rc = handle_ptr[].call["inflate", Int32](strm, Int32(_Z_NO_FLUSH))
    # total_out @ offset 40 (index 5 in the UInt64 view).
    var total_out = Int((strm.bitcast[UInt64]() + 5)[])
    _ = handle_ptr[].call["inflateEnd", Int32](strm)
    strm.free()
    in_buf.free()

    var irc = Int(rc)
    if irc == _Z_STREAM_END:
        return _InflateResult(True, False, out_buf, total_out, irc)
    if irc == _Z_BUF_ERROR or irc == _Z_OK:
        # Z_OK without STREAM_END on a one-shot inflate = output buffer full.
        return _InflateResult(False, True, out_buf, total_out, irc)
    return _InflateResult(False, False, out_buf, total_out, irc)


# =============================================================================
# Zstandard (libzstd ZSTD_decompress; wire string "zstandard", NOT "zstd").
# =============================================================================
#
# zstd frames carry the content size in the frame header, so we query it via
# ZSTD_getFrameContentSize and allocate exactly. Falls back to the grow loop
# if the size is unknown (streamed-without-size frames return special values).

comptime _ZSTD_CONTENTSIZE_UNKNOWN: UInt64 = 0xFFFFFFFFFFFFFFFF  # (size_t)-1
comptime _ZSTD_CONTENTSIZE_ERROR: UInt64 = 0xFFFFFFFFFFFFFFFE  # (size_t)-2


def _decompress_zstandard_avro(
    payload: Span[UInt8, _], hint: Int
) raises -> List[UInt8]:
    """Decompress a standard zstd frame (libzstd ZSTD_decompress).

    Queries ZSTD_getFrameContentSize for an exact allocation when present;
    otherwise grows from the hint-seeded guess.
    """
    var in_len = len(payload)
    # SAFETY (FFI carve-out): in_buf holds a process-owned copy of the
    # compressed bytes for the synchronous zstd call; freed before return.
    var in_buf = alloc[UInt8](max(in_len, 1))
    for i in range(in_len):
        in_buf[i] = payload[i]
    var handle_ptr = _default_zstd_handle()

    var content = handle_ptr[].call["ZSTD_getFrameContentSize", UInt64](
        in_buf.unsafe_origin_cast[MutUntrackedOrigin](), Int64(in_len)
    )
    var cap: Int
    if content == _ZSTD_CONTENTSIZE_UNKNOWN or content == _ZSTD_CONTENTSIZE_ERROR:
        cap = _initial_output_guess(in_len, hint)
    else:
        # ⚠ UNTRUSTED INPUT — AND THIS ONE WAS ALREADY
        # BROKEN AT ASSERT=safe; it never needed bounds checks to be off.
        #
        # `content` is the zstd frame header's Frame_Content_Size: an
        # attacker-chosen 64-bit field inside the compressed block payload.
        # Only the two sentinels are filtered above. For any `content` in
        # [2^63, 2^64-3] the `Int(content)` below is NEGATIVE, and the two uses
        # of it then disagreed:
        #
        #     alloc[UInt8](max(cap, 1))    -> allocates ONE byte
        #     ZSTD_decompress(..., cap, …) -> passes the UNCLAMPED negative cap,
        #                                     which libzstd reinterprets as a
        #                                     huge size_t dstCapacity
        #
        # so libzstd's own dstCapacity check passed and it wrote the frame's
        # real decompressed bytes into a 1-byte allocation. The attacker
        # controls both the declared size and the payload: a clean heap
        # overflow, no asserts involved.
        #
        # Two changes: reject a content size that is negative-when-narrowed or
        # beyond any credible block, and (below) pass the SAME value that was
        # allocated so the two can never diverge again.
        if content > UInt64(MAX_DECOMPRESSED_BLOCK_BYTES):
            raise Error(
                String(
                    "AvroCodecError.ZSTD_CONTENT_SIZE_OUT_OF_RANGE: frame"
                    " header declares "
                )
                + String(content)
                + " decompressed bytes; the ceiling is "
                + String(MAX_DECOMPRESSED_BLOCK_BYTES)
            )
        cap = Int(content)
        if cap == 0:
            cap = 1

    # ONE value for both the allocation and the declared capacity. The prior
    # shape allocated `max(cap, 1)` and declared `cap`.
    var dst_cap = max(cap, 1)
    var out_buf = alloc[UInt8](dst_cap)
    var result = handle_ptr[].call["ZSTD_decompress", Int](
        out_buf.unsafe_origin_cast[MutUntrackedOrigin](),
        dst_cap,
        in_buf.unsafe_origin_cast[MutUntrackedOrigin](),
        in_len,
    )
    var is_err = handle_ptr[].call["ZSTD_isError", Int](result)
    in_buf.free()
    if is_err != 0:
        out_buf.free()
        raise Error(
            String("AvroCodecError.ZSTD_FAILED: ZSTD_decompress error result ")
            + String(result)
        )
    var out = List[UInt8]()
    for i in range(Int(result)):
        out.append(out_buf[i])
    out_buf.free()
    return out^


# =============================================================================
# Bzip2 (libbz2 BZ2_bzBuffToBuffDecompress; no Avro framing).
# =============================================================================
#
# int BZ2_bzBuffToBuffDecompress(char* dest, unsigned* destLen,
#                                char* source, unsigned sourceLen,
#                                int small, int verbosity);
# Returns BZ_OK(0) on success; BZ_OUTBUFF_FULL(-8) when destLen too small.

comptime _BZ_OK: Int = 0
comptime _BZ_OUTBUFF_FULL: Int = -8


def _decompress_bzip2_avro(
    payload: Span[UInt8, _], hint: Int
) raises -> List[UInt8]:
    """Decompress a standard bzip2 stream (libbz2 BZ2_bzBuffToBuffDecompress).

    Grows the output buffer on BZ_OUTBUFF_FULL.
    """
    var in_len = len(payload)
    # SAFETY (FFI carve-out): in_buf holds the compressed copy; out_buf the
    # decompressed scratch; len_buf a 1-element size_t in/out slot. All
    # process-owned heap for the synchronous bzip2 call; freed appropriately.
    var in_buf = alloc[UInt8](max(in_len, 1))
    for i in range(in_len):
        in_buf[i] = payload[i]
    var handle_ptr = _default_bz2_handle()

    var cap = _initial_output_guess(in_len, hint)
    while True:
        var out_buf = alloc[UInt8](max(cap, 1))
        var len_buf = alloc[UInt32](1)
        len_buf[0] = UInt32(cap)
        var rc = handle_ptr[].call["BZ2_bzBuffToBuffDecompress", Int32](
            out_buf.unsafe_origin_cast[MutUntrackedOrigin](),
            len_buf,
            in_buf.unsafe_origin_cast[MutUntrackedOrigin](),
            UInt32(in_len),
            Int32(0),  # small=0 (faster, more memory)
            Int32(0),  # verbosity=0
        )
        var irc = Int(rc)
        if irc == _BZ_OK:
            var written = Int(len_buf[0])
            len_buf.free()
            var out = List[UInt8]()
            for i in range(written):
                out.append(out_buf[i])
            out_buf.free()
            in_buf.free()
            return out^
        out_buf.free()
        len_buf.free()
        if irc != _BZ_OUTBUFF_FULL:
            in_buf.free()
            raise Error(
                String("AvroCodecError.BZIP2_FAILED: BZ2 rc ") + String(irc)
            )
        if cap >= _MAX_OUTPUT_CAP:
            in_buf.free()
            raise Error("AvroCodecError.BZIP2_OUTPUT_OVERFLOW")
        cap *= 4


# =============================================================================
# Xz (liblzma lzma_stream_buffer_decode; no Avro framing).
# =============================================================================
#
# lzma_ret lzma_stream_buffer_decode(uint64_t* memlimit, uint32_t flags,
#                                    const lzma_allocator* allocator,
#                                    const uint8_t* in, size_t* in_pos,
#                                    size_t in_size,
#                                    uint8_t* out, size_t* out_pos,
#                                    size_t out_size);
# Returns LZMA_OK(0) on success; LZMA_BUF_ERROR(10) when out_size too small.

comptime _LZMA_OK: Int = 0
comptime _LZMA_BUF_ERROR: Int = 10
# Generous decode memory limit (avoids LZMA_MEMLIMIT_ERROR on large dicts).
comptime _LZMA_MEMLIMIT: UInt64 = 1 << 34  # 16 GiB headroom


def _decompress_xz_avro(
    payload: Span[UInt8, _], hint: Int
) raises -> List[UInt8]:
    """Decompress a standard .xz stream (liblzma lzma_stream_buffer_decode).

    Grows the output buffer on LZMA_BUF_ERROR.
    """
    var in_len = len(payload)
    # SAFETY (FFI carve-out): all buffers (compressed copy, decompressed
    # scratch, the in/out position + memlimit scratch slots) are process-owned
    # heap for the synchronous lzma call; freed appropriately. liblzma never
    # retains the pointers (one-shot buffer decode, no allocator handed in).
    var in_buf = alloc[UInt8](max(in_len, 1))
    for i in range(in_len):
        in_buf[i] = payload[i]
    var handle_ptr = _default_lzma_handle()

    var cap = _initial_output_guess(in_len, hint)
    while True:
        var out_buf = alloc[UInt8](max(cap, 1))
        var memlimit = alloc[UInt64](1)
        memlimit[0] = _LZMA_MEMLIMIT
        var in_pos = alloc[Int64](1)
        in_pos[0] = Int64(0)
        var out_pos = alloc[Int64](1)
        out_pos[0] = Int64(0)
        # allocator = NULL (use liblzma's default malloc/free).
        var null_allocator = _null_ffi_byte()
        var rc = handle_ptr[].call["lzma_stream_buffer_decode", Int32](
            memlimit,
            UInt32(0),  # flags
            null_allocator,
            in_buf.unsafe_origin_cast[MutUntrackedOrigin](),
            in_pos,
            Int64(in_len),
            out_buf.unsafe_origin_cast[MutUntrackedOrigin](),
            out_pos,
            Int64(cap),
        )
        var irc = Int(rc)
        if irc == _LZMA_OK:
            var written = Int(out_pos[0])
            memlimit.free()
            in_pos.free()
            out_pos.free()
            var out = List[UInt8]()
            for i in range(written):
                out.append(out_buf[i])
            out_buf.free()
            in_buf.free()
            return out^
        out_buf.free()
        memlimit.free()
        in_pos.free()
        out_pos.free()
        if irc != _LZMA_BUF_ERROR:
            in_buf.free()
            raise Error(
                String("AvroCodecError.XZ_FAILED: lzma rc ") + String(irc)
            )
        if cap >= _MAX_OUTPUT_CAP:
            in_buf.free()
            raise Error("AvroCodecError.XZ_OUTPUT_OVERFLOW")
        cap *= 4


# =============================================================================
# Codec library handles (process-lifetime dlopen cache).
# =============================================================================
#
# Snappy is statically linked (the snappy C API through `external_call`), so it
# needs no handle. libz / libzstd / libbz2 / liblzma are opened by per-OS
# soname on first use, one process-lifetime handle per library.

comptime _LIBZ: StaticString = (
    "libz.dylib" if CompilationTarget.is_macos() else "libz.so.1"
)
comptime _LIBZSTD: StaticString = (
    "libzstd.dylib" if CompilationTarget.is_macos() else "libzstd.so.1"
)
comptime _LIBBZ2: StaticString = (
    "libbz2.dylib" if CompilationTarget.is_macos() else "libbz2.so.1.0"
)
comptime _LIBLZMA: StaticString = (
    "liblzma.dylib" if CompilationTarget.is_macos() else "liblzma.so.5"
)
# -----------------------------------------------------------------------------
# Process-lifetime OwnedDLHandle singletons via the stdlib `_Global` runtime
# slot. `_Global[name, init_fn]` is
# a name-keyed, process-global, init-once, cross-compile-unit-coherent slot
# managed by the KGEN runtime — no env var, no address laundering. Distinct
# `_Global` names keep the avro handles independent of the arrow / parquet / orc
# singletons for the same dylibs.
# -----------------------------------------------------------------------------


def _init_avro_z_handle() -> OwnedDLHandle:
    """`_Global` init_fn (non-raising): dlopen libz once per process.

    SAFETY: the OwnedDLHandle ctor raises only on an unresolvable pinned dylib
    (fatal provisioning error), so each init_fn `abort`s.
    """
    try:
        return OwnedDLHandle(_LIBZ)
    except e:
        abort("libz dlopen failed (avro codec handle init)")


def _init_avro_zstd_handle() -> OwnedDLHandle:
    """`_Global` init_fn (non-raising): dlopen libzstd once per process."""
    try:
        return OwnedDLHandle(_LIBZSTD)
    except e:
        abort("libzstd dlopen failed (avro codec handle init)")


def _init_avro_bz2_handle() -> OwnedDLHandle:
    """`_Global` init_fn (non-raising): dlopen libbz2 once per process."""
    try:
        return OwnedDLHandle(_LIBBZ2)
    except e:
        abort("libbz2 dlopen failed (avro codec handle init)")


def _init_avro_lzma_handle() -> OwnedDLHandle:
    """`_Global` init_fn (non-raising): dlopen liblzma once per process."""
    try:
        return OwnedDLHandle(_LIBLZMA)
    except e:
        abort("liblzma dlopen failed (avro codec handle init)")


comptime _Z_GLOBAL = _Global["komira_avro_z_handle", _init_avro_z_handle]
comptime _ZSTD_GLOBAL = _Global[
    "komira_avro_zstd_handle", _init_avro_zstd_handle
]
comptime _BZ2_GLOBAL = _Global["komira_avro_bz2_handle", _init_avro_bz2_handle]
comptime _LZMA_GLOBAL = _Global[
    "komira_avro_lzma_handle", _init_avro_lzma_handle
]


# Per-codec accessors — process-lifetime handle slot (init-once via `_Global`).
# SAFETY: FFI carve-out; `MutUntrackedOrigin` is the stdlib `_Global` return
# type (runtime-managed static storage). No env var, no `unsafe_from_address`.
def _default_z_handle() raises -> UnsafePointer[
    OwnedDLHandle, MutUntrackedOrigin
]:
    """Process-lifetime libz handle (Avro deflate, inflateInit2(-15))."""
    return _Z_GLOBAL.get_or_create_ptr()


def _default_zstd_handle() raises -> UnsafePointer[
    OwnedDLHandle, MutUntrackedOrigin
]:
    """Process-lifetime libzstd handle."""
    return _ZSTD_GLOBAL.get_or_create_ptr()


def _default_bz2_handle() raises -> UnsafePointer[
    OwnedDLHandle, MutUntrackedOrigin
]:
    """Process-lifetime libbz2 handle."""
    return _BZ2_GLOBAL.get_or_create_ptr()


def _default_lzma_handle() raises -> UnsafePointer[
    OwnedDLHandle, MutUntrackedOrigin
]:
    """Process-lifetime liblzma handle."""
    return _LZMA_GLOBAL.get_or_create_ptr()


# =============================================================================
# CRC32 (IEEE 802.3) — for the Avro snappy trailer validation.
# =============================================================================
#
# Standard reflected CRC32 with polynomial 0xEDB88320, init 0xFFFFFFFF, final
# XOR 0xFFFFFFFF. This is the same CRC32 the Avro Java reference + zlib's
# `crc32` use for the snappy block trailer.


@always_inline
def _build_crc32_table() -> Array[UInt32, 256]:
    """Returns an InlineArray (stack-allocated; no heap): a `List[UInt32]`
    would allocate and grow via 256 appends on EVERY snappy WRITE call.
    """
    var table = Array[UInt32, 256](fill=UInt32(0))
    for i in range(256):
        var c = UInt32(i)
        for _j in range(8):
            if (c & UInt32(1)) != 0:
                c = UInt32(0xEDB88320) ^ (c >> 1)
            else:
                c = c >> 1
        table[i] = c
    return table^


def crc32_ieee(bytes: Span[UInt8, _]) -> UInt32:
    """CRC32 (IEEE 802.3, reflected, poly 0xEDB88320) of a byte sequence."""
    var table = _build_crc32_table()
    var crc = UInt32(0xFFFFFFFF)
    for i in range(len(bytes)):
        var idx = Int((crc ^ UInt32(bytes[i])) & UInt32(0xFF))
        crc = table[idx] ^ (crc >> 8)
    return crc ^ UInt32(0xFFFFFFFF)


# =============================================================================
# Public entry — COMPRESS one OCF block payload by codec tag.
# =============================================================================
#
# The inverse of `decompress_block`. Given the raw (uncompressed) Avro-binary
# block payload and a codec tag, returns the on-disk (post-compression) bytes
# the OCF block body should carry. Each codec's framing matches what
# `decompress_block` expects on the way back in:
#   null      — passthrough (no-op).
#   deflate   — RAW RFC-1951 (libz deflateInit2 windowBits=-15; NO zlib header,
#               NO ADLER32 trailer — the read path uses inflateInit2(-15)).
#   snappy    — raw_snappy ‖ BE4 crc32(uncompressed) — the Avro snappy framing
#               the decompressor strips + validates.
#   zstandard — a standard zstd frame (libzstd ZSTD_compress).
#   bzip2     — a standard bzip2 stream (libbz2 BZ2_bzBuffToBuffCompress).
#   xz        — a standard .xz stream (liblzma lzma_easy_buffer_encode).
#
# Encapsulation: takes a borrowed Span[UInt8], returns an owned List[UInt8].
# The FFI carve-out is confined to each codec's call site (same singleton dlopen
# handles the decompress side already uses).


def compress_block(codec_tag: Int, payload: Span[UInt8, _]) raises -> List[UInt8]:
    """Compress an OCF block payload by codec tag (full Avro codec matrix).

    Args:
        codec_tag: AVRO_CODEC_* tag from the writer options.
        payload: Borrowed view of the raw (uncompressed) block bytes.

    Returns:
        Owned List[UInt8] of on-disk (post-compression) bytes, framed exactly
        as `decompress_block` expects.

    Raises:
        On an unknown codec tag or a codec failure.
    """
    if codec_tag == AVRO_CODEC_NULL:
        # Bulk memcpy, not a per-byte append loop. Pre-reserve + resize + memcpy.
        var n = len(payload)
        var out = List[UInt8](capacity=n)
        if n > 0:
            # SAFETY: dst is the freshly-reserved List backing store; src is
            # the borrowed Span's underlying buffer (alive across the call).
            unsafe_memcpy(
                dest=out.unsafe_ptr(),
                src=payload.unsafe_ptr(),
                count=n,
            )
        out.resize(unsafe_uninit_length=n)
        return out^
    elif codec_tag == AVRO_CODEC_DEFLATE:
        return _compress_deflate_avro(payload)
    elif codec_tag == AVRO_CODEC_SNAPPY:
        return _compress_snappy_avro(payload)
    elif codec_tag == AVRO_CODEC_ZSTANDARD:
        return _compress_zstandard_avro(payload)
    elif codec_tag == AVRO_CODEC_BZIP2:
        return _compress_bzip2_avro(payload)
    elif codec_tag == AVRO_CODEC_XZ:
        return _compress_xz_avro(payload)
    raise Error(
        String("AvroCodecError.UNKNOWN_CODEC: tag ") + String(codec_tag)
    )


# -----------------------------------------------------------------------------
# Deflate compress (RAW RFC-1951, libz deflateInit2 windowBits=-15).
# -----------------------------------------------------------------------------
#
# deflateInit2_ signature (LP64):
#   int deflateInit2_(z_streamp strm, int level, int method, int windowBits,
#                     int memLevel, int strategy, const char* version,
#                     int stream_size);
# We seed next_in/avail_in/next_out/avail_out in the 112-byte z_stream scratch
# (same layout the decompress side uses), then a single deflate(Z_FINISH).

comptime _Z_FINISH: Int32 = 4
comptime _Z_DEFLATED: Int32 = 8
comptime _Z_DEFAULT_LEVEL: Int32 = 6
comptime _Z_DEFAULT_MEMLEVEL: Int32 = 8
comptime _Z_DEFAULT_STRATEGY: Int32 = 0


def _compress_deflate_avro(payload: Span[UInt8, _]) raises -> List[UInt8]:
    """RAW-deflate-compress (windowBits=-15) — inverse of _inflate_raw_once.

    Skips an `in_buf` copy by passing `payload.unsafe_ptr()` directly into the z_stream;
    writes deflate output directly into the returned List backing store (no
    intermediate `out_buf` alloc + per-byte append). `payload` and `out` both
    remain alive across the synchronous FFI call.

    SAFETY (FFI carve-out): `strm` (112-byte z_stream scratch) is heap-owned
    for the synchronous deflate; libz never retains the pointers; `strm` freed
    before return. Span/List backing storage is owned by the caller-stack /
    fresh allocation and not reallocated across the deflate call.
    """
    var in_len = len(payload)
    # deflate worst-case bound: in + in/2 + 128 (deflateBound-ish headroom).
    var out_cap = in_len + (in_len // 2) + 128
    var out = List[UInt8](capacity=max(out_cap, 1))
    var in_ptr = _span_ptr(payload)
    var out_ptr = _list_ptr(out)

    var handle_ptr = _default_z_handle()
    var version = handle_ptr[].call[
        "zlibVersion", UnsafePointer[UInt8, MutUntrackedOrigin]
    ]()

    var strm = alloc[UInt8](_Z_STREAM_SIZE)
    unsafe_memset(strm, 0, _Z_STREAM_SIZE)
    (strm.bitcast[UInt64]() + 0)[] = UInt64(Int(in_ptr))
    (strm.bitcast[UInt32]() + 2)[] = UInt32(in_len)
    (strm.bitcast[UInt64]() + 3)[] = UInt64(Int(out_ptr))
    (strm.bitcast[UInt32]() + 8)[] = UInt32(out_cap)

    var init_rc = handle_ptr[].call["deflateInit2_", Int32](
        strm,
        _Z_DEFAULT_LEVEL,
        _Z_DEFLATED,
        _Z_WINDOWBITS_RAW,
        _Z_DEFAULT_MEMLEVEL,
        _Z_DEFAULT_STRATEGY,
        version,
        Int32(_Z_STREAM_SIZE),
    )
    if Int(init_rc) != _Z_OK:
        strm.free()
        raise Error(
            String("AvroCodecError.DEFLATE_COMPRESS_FAILED: deflateInit2_ rc ")
            + String(Int(init_rc))
        )
    var rc = handle_ptr[].call["deflate", Int32](strm, _Z_FINISH)
    var total_out = Int((strm.bitcast[UInt64]() + 5)[])
    _ = handle_ptr[].call["deflateEnd", Int32](strm)
    strm.free()
    if Int(rc) != _Z_STREAM_END:
        raise Error(
            String("AvroCodecError.DEFLATE_COMPRESS_FAILED: deflate rc ")
            + String(Int(rc))
        )
    out.resize(unsafe_uninit_length=total_out)
    return out^


# -----------------------------------------------------------------------------
# Snappy compress (Avro framing: raw_snappy ‖ BE4 crc32(uncompressed)).
# -----------------------------------------------------------------------------


def _compress_snappy_avro(payload: Span[UInt8, _]) raises -> List[UInt8]:
    """Snappy-compress then append the BE4 CRC32 trailer of the UNCOMPRESSED
    bytes (the Avro snappy block framing the decompressor expects).

    Skips an `in_buf` copy by passing `payload.unsafe_ptr()` directly to snappy_compress;
    writes compressed bytes + the 4-byte CRC trailer directly into the returned
    List backing store (no intermediate `out_buf` alloc + per-byte append).
    Reserves `out_cap + 4` so the trailer slot is in-bounds without realloc.

    SAFETY (FFI carve-out): `size_buf` is heap-owned for the synchronous
    snappy_compress; freed before return. Span/List backing storage is owned
    by the caller-stack / fresh allocation and not reallocated across the call.
    """
    var in_len = len(payload)
    # snappy_max_compressed_length(n) = 32 + n + n/6. Add 4 for the trailer.
    var out_cap = 32 + in_len + (in_len // 6)
    var out = List[UInt8](capacity=max(out_cap + 4, 1))

    var size_buf = alloc[Int64](1)
    size_buf[0] = Int64(out_cap)
    var status = external_call["snappy_compress", Int32](
        _span_ptr(payload),
        Int64(in_len),
        _list_ptr(out),
        size_buf,
    )
    var written = Int(size_buf[0])
    size_buf.free()
    if Int(status) != 0:
        raise Error(
            String("AvroCodecError.SNAPPY_COMPRESS_FAILED: status ")
            + String(Int(status))
        )
    # BE4 CRC32 of the UNCOMPRESSED payload (the Avro snappy trailer).
    var crc = crc32_ieee(payload)
    # Set the List length to fit snappy bytes + 4 trailer bytes.
    # SAFETY: pre-reserved capacity == out_cap + 4 >= written + 4.
    out.resize(unsafe_uninit_length=written + 4)
    # Write the 4 trailer bytes directly into the in-bounds slots.
    var base_ptr = out.unsafe_ptr()
    base_ptr[written + 0] = UInt8((crc >> 24) & UInt32(0xFF))
    base_ptr[written + 1] = UInt8((crc >> 16) & UInt32(0xFF))
    base_ptr[written + 2] = UInt8((crc >> 8) & UInt32(0xFF))
    base_ptr[written + 3] = UInt8(crc & UInt32(0xFF))
    return out^


# -----------------------------------------------------------------------------
# Zstandard compress (libzstd ZSTD_compress).
# -----------------------------------------------------------------------------

comptime _ZSTD_LEVEL: Int32 = 3


def _compress_zstandard_avro(payload: Span[UInt8, _]) raises -> List[UInt8]:
    """Compress to a standard zstd frame (libzstd ZSTD_compress, level 3).

    Skips an `in_buf` copy by passing `payload.unsafe_ptr()` directly; writes zstd
    output directly into the returned List backing store.

    SAFETY (FFI carve-out): Span/List backing storage is owned by the
    caller-stack / fresh allocation; not reallocated across the synchronous
    ZSTD_compress call.
    """
    var in_len = len(payload)
    var handle_ptr = _default_zstd_handle()
    var out_cap = handle_ptr[].call["ZSTD_compressBound", Int](in_len)
    if out_cap <= 0:
        out_cap = in_len + (in_len // 2) + 64
    var out = List[UInt8](capacity=max(out_cap, 1))
    var written = handle_ptr[].call["ZSTD_compress", Int](
        _list_ptr(out),
        out_cap,
        _span_ptr(payload),
        in_len,
        _ZSTD_LEVEL,
    )
    var is_err = handle_ptr[].call["ZSTD_isError", Int](written)
    if is_err != 0:
        raise Error(
            String("AvroCodecError.ZSTD_COMPRESS_FAILED: result ")
            + String(written)
        )
    out.resize(unsafe_uninit_length=Int(written))
    return out^


# -----------------------------------------------------------------------------
# Bzip2 compress (libbz2 BZ2_bzBuffToBuffCompress).
# -----------------------------------------------------------------------------
#
# int BZ2_bzBuffToBuffCompress(char* dest, unsigned* destLen,
#                              char* source, unsigned sourceLen,
#                              int blockSize100k, int verbosity, int workFactor);
# Returns BZ_OK(0); BZ_OUTBUFF_FULL(-8) when dest too small.

comptime _BZ_BLOCKSIZE_100K: Int32 = 9
comptime _BZ_WORKFACTOR: Int32 = 0


def _compress_bzip2_avro(payload: Span[UInt8, _]) raises -> List[UInt8]:
    """Compress to a standard bzip2 stream (libbz2 BZ2_bzBuffToBuffCompress).

    Skips an `in_buf` copy by passing `payload.unsafe_ptr()` directly; writes bzip2
    output directly into the returned List backing store.

    SAFETY (FFI carve-out): `len_buf` (1-element in/out scratch) is
    heap-owned for the synchronous BZ2_bzBuffToBuffCompress; freed before
    return. Span/List backing storage owned by caller-stack / fresh allocation;
    not reallocated across the call.
    """
    var in_len = len(payload)
    var handle_ptr = _default_bz2_handle()
    # bzip2 worst-case = in + 1% + 600 bytes (libbz2 docs).
    var out_cap = in_len + (in_len // 100) + 1024
    var out = List[UInt8](capacity=max(out_cap, 1))
    var len_buf = alloc[UInt32](1)
    len_buf[0] = UInt32(out_cap)
    var rc = handle_ptr[].call["BZ2_bzBuffToBuffCompress", Int32](
        _list_ptr(out),
        len_buf,
        _span_ptr(payload),
        UInt32(in_len),
        _BZ_BLOCKSIZE_100K,
        Int32(0),  # verbosity
        _BZ_WORKFACTOR,
    )
    var irc = Int(rc)
    var written = Int(len_buf[0])
    len_buf.free()
    if irc != _BZ_OK:
        raise Error(
            String("AvroCodecError.BZIP2_COMPRESS_FAILED: BZ2 rc ")
            + String(irc)
        )
    out.resize(unsafe_uninit_length=written)
    return out^


# -----------------------------------------------------------------------------
# Xz compress (liblzma lzma_easy_buffer_encode).
# -----------------------------------------------------------------------------
#
# lzma_ret lzma_easy_buffer_encode(uint32_t preset, lzma_check check,
#                                  const lzma_allocator* allocator,
#                                  const uint8_t* in, size_t in_size,
#                                  uint8_t* out, size_t* out_pos,
#                                  size_t out_size);
# Returns LZMA_OK(0). out_pos is an in/out size_t (start 0 -> bytes written).
# check = LZMA_CHECK_CRC64(4) is the default xz integrity check. preset 6 is
# the liblzma default.

comptime _LZMA_PRESET_DEFAULT: UInt32 = 6
comptime _LZMA_CHECK_CRC64: Int32 = 4


def _compress_xz_avro(payload: Span[UInt8, _]) raises -> List[UInt8]:
    """Compress to a standard .xz stream (liblzma lzma_easy_buffer_encode).

    Skips an `in_buf` copy by passing `payload.unsafe_ptr()` directly; writes xz
    output directly into the returned List backing store.

    SAFETY (FFI carve-out): `out_pos` (1-element in/out scratch) is
    heap-owned for the synchronous lzma encode; freed before return. liblzma
    never retains the pointers (one-shot buffer encode, NULL allocator).
    Span/List backing storage owned by caller-stack / fresh allocation; not
    reallocated across the call.
    """
    var in_len = len(payload)
    var handle_ptr = _default_lzma_handle()
    # xz container overhead is small; allow generous headroom for tiny inputs.
    var out_cap = in_len + (in_len // 3) + 1024
    var out = List[UInt8](capacity=max(out_cap, 1))
    var out_pos = alloc[Int64](1)
    out_pos[0] = Int64(0)
    var null_allocator = _null_ffi_byte()
    var rc = handle_ptr[].call["lzma_easy_buffer_encode", Int32](
        _LZMA_PRESET_DEFAULT,
        _LZMA_CHECK_CRC64,
        null_allocator,
        _span_ptr(payload),
        Int64(in_len),
        _list_ptr(out),
        out_pos,
        Int64(out_cap),
    )
    var irc = Int(rc)
    var written = Int(out_pos[0])
    out_pos.free()
    if irc != _LZMA_OK:
        raise Error(
            String("AvroCodecError.XZ_COMPRESS_FAILED: lzma rc ") + String(irc)
        )
    out.resize(unsafe_uninit_length=written)
    return out^
