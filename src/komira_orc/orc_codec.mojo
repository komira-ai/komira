# =============================================================================
# orc_codec.mojo — ORC stream codec compression and decompression (the full
# codec matrix).
# =============================================================================
#
# FFI-BOUNDARY: ORC compression codecs (libzstd, libz, liblz4 via dlopen;
# snappy statically linked through the core packages). The FFI pointers in this
# package are confined to the dlopen-handle slots and the per-codec helpers
# below, the same shape as the core packages' Arrow compression codecs.
#
# ORC compression framing: when the file codec is not
# NONE, every stream is broken into chunks. Each chunk is prefixed with a
# 3-byte little-endian header word:
#     header24 = (compressed_length << 1) | isOriginal_bit
# `isOriginal == 1` means the chunk is stored UNCOMPRESSED (the writer's choice
# when compression would enlarge); the reader copies the chunk bytes verbatim.
# Otherwise the chunk payload is codec-compressed and must be decompressed.
# Each chunk's DECOMPRESSED size is bounded by the PostScript
# `compressionBlockSize` (default 256 KiB), so per-chunk output fits a single
# `cap`-sized scratch buffer.
#
# For the NONE codec there is NO chunk framing at all — the stream IS the raw
# bytes (handled by `decompress_stream` short-circuit).
#
# Codec wire details:
#   - Zlib   : RAW RFC-1951 deflate (NO zlib header, NO ADLER32 trailer) —
#              `inflateInit2_(windowBits = -15)`. Same convention as Avro
#              deflate. NOT the parquet GZIP auto-detect (windowBits = 15+32).
#   - Snappy : raw block, `snappy_uncompress`. ORC wraps it in the 3-byte
#              chunk header; there is NO Avro-style BE4 CRC32 trailer.
#   - Lzo    : READ ONLY, and NOT via FFI — `lzo1x_decompress.mojo`, a
#              native LZO1X decoder. liblzo2 is GPL-2.0-or-later, so it is
#              not part of the build; the LZO1X *format* carries no such
#              encumbrance.
#              The WRITE half is deleted rather than reimplemented — the
#              spec deprecates this codec and every other one we support is
#              a better choice, so `compress_stream` refuses it by name.
#              (Apache's own orc-cpp does the same: pyarrow 24 answers
#              `Unknown CompressionKind: LZO` to a write request while
#              still reading LZO files.)
#   - Lz4    : LZ4 block format (NOT frame), `LZ4_decompress_safe`.
#
# Encapsulation: `decompress_stream` takes a borrowed Span and returns an owned
# `List[UInt8]`. No UnsafePointer crosses the module boundary; the FFI pointers
# are confined to the singletons + the per-codec decompress helpers.
# =============================================================================

from std.memory import alloc, unsafe_memset, unsafe_memcpy
from std.ffi import OwnedDLHandle, _Global, external_call
from std.os import abort

from std.sys.info import CompilationTarget

from .lzo1x_decompress import lzo1x_decompress
from .footer import (
    parse_chunk_header,
    ORC_COMPRESSION_NONE,
    ORC_COMPRESSION_ZLIB,
    ORC_COMPRESSION_SNAPPY,
    ORC_COMPRESSION_LZO,
    ORC_COMPRESSION_LZ4,
    ORC_COMPRESSION_ZSTD,
    orc_compression_name,
)


# =============================================================================
# FFI buffer-coercion helpers (the same shape as the core packages' Arrow
# compression codecs).
# =============================================================================
#
# A compress helper that allocates an in_buf + per-byte input copy loop and an
# out_buf + per-byte output append loop pays hundreds of MB of byte-stores per
# large write (256-KiB chunks × N). Instead, pass the input Span pointer
# DIRECTLY to FFI via `_span_ptr` and write DIRECTLY into the output List's
# reserved backing storage via `_list_ptr`.
#
# SAFETY: the helpers cast to an untracked origin for the FFI seam only; both
# input and output remain alive across the synchronous codec call,
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
    """Coerce a `List[UInt8]`'s data pointer to FFI shape (mutable output)."""
    # SAFETY: synchronous FFI; `buf` is not reallocated across the call
    # because the caller pre-reserved capacity (no append happens between
    # this call and consumption of the pointer).
    return buf.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin]()


# =============================================================================
# Public: decompress a whole ORC stream into a flat byte buffer.
# =============================================================================
#
# The ceiling on any single decompressed-chunk allocation. Chosen to equal the
# ceiling the retry-growth paths in `_zstd_decompress_chunk` /
# `_zlib_decompress_chunk` / `_lz4_decompress_chunk` already enforce
# (`new_cap > (1 << 30)` -> raise) so there is ONE number, not two. ORC's spec
# default compressionBlockSize is 256 KiB; 1 GiB is four thousand times that.

comptime ORC_MAX_COMPRESSION_BLOCK_SIZE: Int = 1 << 30


def decompress_stream(
    data: Span[UInt8, _], codec: Int, block_size: Int
) raises -> List[UInt8]:
    """Decompress a complete ORC stream (chunk-framed) into raw bytes.

    `codec` is the PostScript CompressionKind. `block_size` is the
    PostScript `compressionBlockSize` (the per-chunk decompressed cap; ORC's
    default is 256 KiB). For the NONE codec the stream is returned as-is.
    """
    # =========================================================================
    # THE LAST LINE ON AN INVERTED SPAN.
    # =========================================================================
    #
    # EVERY untrusted byte range in the reader funnels through here: per-stream
    # spans (`orc_reader._locate_streams`, `nested_decoder._gather_streams_for_
    # column`, `orc_stride_skip._find_row_index_bytes`), the per-stripe StripeFooter span, the file
    # Footer span, and the Metadata span. Each is `file_bytes[start:end]` over
    # endpoints summed from protobuf uint64s.
    #
    # Mojo's Span slicing CLAMPS an over-large END (harmless: the decoder then
    # raises TRUNCATED) but yields a NEGATIVE length when start > end. At
    # ASSERT=none, `decompress_stream` on a length -16 span SIGSEGVs in the
    # NONE fast path below — `out.extend(data)` is a memcpy with a
    # wrapped-unsigned count, i.e. a wild write, not a clean abort.
    #
    # The endpoints are bounded at parse time (`footer.orc_checked_extent`)
    # and re-checked against the file at each slice site
    # (`orc_reader._checked_file_span`), so this should be unreachable. It stays
    # because it is ONE compare at a chokepoint that a future span site cannot
    # forget to call — several independent span sites are the argument for
    # defence here rather than trust.
    if len(data) < 0:
        raise Error(
            String("OrcCodecError.INVERTED_SPAN: stream span has negative")
            + " length "
            + String(len(data))
            + " (its start offset exceeds its end offset — a byte range"
            " derived from a malformed length or offset)"
        )
    # `block_size` is PostScript.compressionBlockSize: attacker-chosen metadata
    # that becomes each codec helper's INITIAL `alloc` size, once per chunk. The
    # retry-growth path below already refuses to exceed 1 GiB
    # (`new_cap > (1 << 30)`); without the same ceiling on the initial
    # allocation, ~10 bytes of PostScript would buy an arbitrarily large
    # allocation. One ceiling covers both. ORC's spec default is 256 KiB.
    #
    # This also makes the `Int32(out_cap)` narrowing at the LZ4 FFI boundary
    # provably safe: with `cap <= 1 GiB` and the chunk length field only 23 bits
    # wide, `out_cap` can never reach 2^31 and so can never be handed to
    # LZ4_decompress_safe as a NEGATIVE dstCapacity.
    if block_size < 0:
        raise Error(
            String("OrcCodecError.BAD_BLOCK_SIZE: compressionBlockSize is")
            + " negative ("
            + String(block_size)
            + ")"
        )
    if block_size > ORC_MAX_COMPRESSION_BLOCK_SIZE:
        raise Error(
            String("OrcCodecError.BAD_BLOCK_SIZE: compressionBlockSize ")
            + String(block_size)
            + " exceeds the maximum "
            + String(ORC_MAX_COMPRESSION_BLOCK_SIZE)
            + " (ORC's spec default is 262144)"
        )
    if codec == ORC_COMPRESSION_NONE:
        # Bulk-copy the whole stream in ONE memcpy instead of a per-byte
        # append loop: uncompressed DATA streams can be hundreds of MB, and a
        # per-byte loop would dominate the decode. `List.extend(Span)` routes
        # through a single grow + memcpy.
        var out = List[UInt8]()
        out.extend(data)
        return out^

    if (
        codec != ORC_COMPRESSION_ZSTD
        and codec != ORC_COMPRESSION_ZLIB
        and codec != ORC_COMPRESSION_SNAPPY
        and codec != ORC_COMPRESSION_LZO
        and codec != ORC_COMPRESSION_LZ4
    ):
        raise Error(
            String("OrcCodecError.UNKNOWN_CODEC: codec '")
            + orc_compression_name(codec)
            + "' is not a recognized ORC CompressionKind"
        )

    # Walk the chunk framing. Each chunk = 3-byte header + payload. The loop is
    # codec-agnostic; only the per-chunk decompress call differs.
    var out = List[UInt8]()
    var pos = 0
    var cap = block_size if block_size > 0 else (256 * 1024)
    while pos < len(data):
        var hdr = parse_chunk_header(data, pos)
        var payload_start = hdr.payload_start
        var payload_end = payload_start + hdr.compressed_length
        if payload_end > len(data):
            raise Error(
                "OrcCodecError.TRUNCATED: chunk payload runs past stream end"
            )
        if hdr.is_original:
            # Uncompressed chunk — bulk-copy verbatim (one memcpy, not a
            # per-byte append).
            out.extend(data[payload_start:payload_end])
        else:
            var chunk = data[payload_start:payload_end]
            if codec == ORC_COMPRESSION_ZSTD:
                _zstd_decompress_chunk(chunk, cap, out)
            elif codec == ORC_COMPRESSION_ZLIB:
                _zlib_decompress_chunk(chunk, cap, out)
            elif codec == ORC_COMPRESSION_SNAPPY:
                _snappy_decompress_chunk(chunk, cap, out)
            elif codec == ORC_COMPRESSION_LZ4:
                _lz4_decompress_chunk(chunk, cap, out)
            else:  # ORC_COMPRESSION_LZO
                _lzo_decompress_chunk(chunk, cap, out)
        pos = payload_end
    return out^


# =============================================================================
# Stream COMPRESS (the writer path) — the inverse of decompress_stream.
# =============================================================================
#
# For the NONE codec the stream IS the raw bytes (no chunk framing). For every
# other codec we split the stream into chunks of at most
# `_DEFAULT_COMPRESSION_BLOCK_SIZE` (256 KiB) decompressed bytes and emit each
# chunk framed in the 3-byte ORC chunk header:
#     header24 = (payload_length << 1) | isOriginal_bit
# If compression of a chunk does NOT shrink the data (compressed >= original),
# we emit that chunk as isOriginal=1 (uncompressed, verbatim) — exactly what
# the reader's is_original short-circuit reads back. This guarantees the writer
# never enlarges a chunk and that decompress_stream round-trips it.
#
# Chunking discipline: the reader sizes its per-chunk decompression output buffer at
# `compressionBlockSize` (the PostScript field, default 256 KiB). Emitting one
# mega-chunk per stream overruns that
# buffer on any stream whose decompressed size exceeds the block size and
# causes ZSTD/Zlib/Snappy/LZ4/LZO to return a dst-too-small error. Chunking at
# the block-size boundary is therefore a correctness requirement, not a
# size/locality optimization. Mature ORC writers (orc-cpp, hive-orc, arrow-orc)
# all chunk at the configured block size for the same reason.

comptime _DEFAULT_COMPRESSION_BLOCK_SIZE: Int = 256 * 1024


def _emit_chunk_header(mut out: List[UInt8], length: Int, is_original: Bool):
    """Append the 3-byte little-endian ORC chunk header for `length` payload
    bytes with the `is_original` flag (inverse of parse_chunk_header)."""
    var header24 = (length << 1) | (1 if is_original else 0)
    out.append(UInt8(header24 & 0xFF))
    out.append(UInt8((header24 >> 8) & 0xFF))
    out.append(UInt8((header24 >> 16) & 0xFF))


def _compress_one_chunk(slice: Span[UInt8, _], codec: Int) raises -> List[UInt8]:
    """Codec-dispatch one chunk worth of bytes; returns the raw compressed
    payload (NO chunk header). `slice` must be <= compressionBlockSize.

    Accepts a Span instead of an owned List so the caller can pass a borrowed view over the
    stream buffer (no per-chunk slice copy).
    """
    if codec == ORC_COMPRESSION_ZSTD:
        return _zstd_compress_chunk(slice)
    elif codec == ORC_COMPRESSION_ZLIB:
        return _zlib_compress_chunk(slice)
    elif codec == ORC_COMPRESSION_SNAPPY:
        return _snappy_compress_chunk(slice)
    else:  # ORC_COMPRESSION_LZ4
        return _lz4_compress_chunk(slice)


def compress_stream(
    data: List[UInt8], codec: Int
) raises -> List[UInt8]:
    """Compress a complete ORC stream into chunk-framed bytes (the writer path).

    `codec` is the PostScript CompressionKind. For NONE the data is returned
    verbatim (no framing). For every other codec the stream is split into
    chunks of at most `_DEFAULT_COMPRESSION_BLOCK_SIZE` decompressed bytes;
    each chunk is independently compressed and emitted with a 3-byte chunk
    header. A chunk that fails to shrink is emitted as isOriginal=1 (verbatim).
    """
    if codec == ORC_COMPRESSION_NONE:
        return data.copy()

    # WRITE-SIDE LZO IS ABSENT, DELIBERATELY. The only LZO1X encoder
    # available is GPL-2.0-or-later liblzo2, and
    # the ORC spec deprecates the codec, so there is no case in which we would
    # CHOOSE to emit it: zlib / snappy / lz4 / zstd are all supported here and
    # all better. Reading LZO is unaffected — see `decompress_stream`. This is
    # a named refusal rather than an UNKNOWN_CODEC, because codec 3 IS a
    # recognized CompressionKind and a caller deserves to be told which half of
    # it is unsupported and why.
    if codec == ORC_COMPRESSION_LZO:
        raise Error(
            String("OrcCodecError.LZO_WRITE_UNSUPPORTED: ORC CompressionKind")
            + " LZO is READ-ONLY in this implementation (the only LZO1X"
            " encoder available is GPL-licensed, and the ORC spec deprecates"
            " the codec). Write with ZSTD, ZLIB, SNAPPY or LZ4; LZO files"
            " remain readable."
        )
    if (
        codec != ORC_COMPRESSION_ZSTD
        and codec != ORC_COMPRESSION_ZLIB
        and codec != ORC_COMPRESSION_SNAPPY
        and codec != ORC_COMPRESSION_LZ4
    ):
        raise Error(
            String("OrcCodecError.UNKNOWN_CODEC: codec '")
            + orc_compression_name(codec)
            + "' is not a recognized ORC CompressionKind"
        )

    var out = List[UInt8]()
    if len(data) == 0:
        return out^

    var block_size = _DEFAULT_COMPRESSION_BLOCK_SIZE
    var pos = 0
    # Span view over the data List so the per-chunk slicer + per-codec helpers see
    # borrowed bytes directly (no per-chunk slice List allocation).
    var data_span = Span(data)
    while pos < len(data):
        var remaining = len(data) - pos
        var chunk_len = block_size if remaining > block_size else remaining
        # Borrow a Span slice over `data[pos:pos+chunk_len]` (zero-copy).
        var slice = data_span[pos : pos + chunk_len]
        var compressed = _compress_one_chunk(slice, codec)
        if len(compressed) >= chunk_len:
            # Compression did not shrink — store the chunk uncompressed.
            _emit_chunk_header(out, chunk_len, True)
            # Bulk-extend the verbatim chunk in one memcpy (vs per-byte append).
            out.extend(slice)
        else:
            _emit_chunk_header(out, len(compressed), False)
            # Bulk-extend the compressed payload in one memcpy.
            out.extend(Span(compressed))
        pos += chunk_len
    return out^


# =============================================================================
# Per-codec single-chunk COMPRESS helpers (FFI; inverse of the decompress
# helpers). Each returns the raw compressed block (no chunk framing).
# =============================================================================


def _zstd_compress_chunk(src: Span[UInt8, _]) raises -> List[UInt8]:
    """Direct Span-in / List-out via _span_ptr + _list_ptr (no intermediate
    alloc/copy).
    """
    var in_len = len(src)
    var handle_ptr = _default_zstd_handle()
    var out_cap = handle_ptr[].call["ZSTD_compressBound", Int](in_len)
    if out_cap <= 0:
        out_cap = in_len + (in_len // 2) + 64
    var out = List[UInt8](capacity=max(out_cap, 1))
    var written = handle_ptr[].call["ZSTD_compress", Int](
        _list_ptr(out),
        out_cap,
        _span_ptr(src),
        in_len,
        Int32(3),
    )
    var is_err = handle_ptr[].call["ZSTD_isError", Int](written)
    if is_err != 0:
        raise Error("OrcCodecError.ZSTD_COMPRESS_FAILED")
    out.resize(unsafe_uninit_length=Int(written))
    return out^


def _zlib_compress_chunk(src: Span[UInt8, _]) raises -> List[UInt8]:
    """RAW-deflate-compress (windowBits=-15) one stream — inverse of
    _zlib_decompress_chunk's raw RFC-1951 reader.

    Direct Span-in / List-out via _span_ptr + _list_ptr (no intermediate
    alloc/copy).
    """
    var in_len = len(src)
    var out_cap = in_len + in_len // 2 + 128
    var out = List[UInt8](capacity=max(out_cap, 1))
    var in_ptr = _span_ptr(src)
    var out_ptr = _list_ptr(out)

    var handle_ptr = _default_z_handle()
    var version = handle_ptr[].call[
        "zlibVersion", UnsafePointer[UInt8, MutUntrackedOrigin]
    ]()

    # SAFETY: 112-byte scratch z_stream; freed via deflateEnd + free() below.
    var strm = alloc[UInt8](_Z_STREAM_SIZE)
    unsafe_memset(strm, 0, _Z_STREAM_SIZE)
    (strm.bitcast[UInt64]() + 0)[] = UInt64(Int(in_ptr))
    (strm.bitcast[UInt32]() + 2)[] = UInt32(in_len)
    (strm.bitcast[UInt64]() + 3)[] = UInt64(Int(out_ptr))
    (strm.bitcast[UInt32]() + 8)[] = UInt32(out_cap)

    var init_rc = handle_ptr[].call["deflateInit2_", Int32](
        strm,
        Int32(6),  # Z_DEFAULT_COMPRESSION-ish level
        Int32(8),  # Z_DEFLATED
        _Z_WINDOWBITS_RAW,
        Int32(8),  # memLevel
        Int32(0),  # Z_DEFAULT_STRATEGY
        version,
        Int32(_Z_STREAM_SIZE),
    )
    if Int(init_rc) != _Z_OK:
        strm.free()
        raise Error("OrcCodecError.ZLIB_COMPRESS_FAILED: deflateInit2_ rc=" + String(Int(init_rc)))
    var rc = handle_ptr[].call["deflate", Int32](strm, Int32(4))  # Z_FINISH=4
    var total_out = Int((strm.bitcast[UInt64]() + 5)[])
    _ = handle_ptr[].call["deflateEnd", Int32](strm)
    strm.free()
    if Int(rc) != _Z_STREAM_END:
        raise Error("OrcCodecError.ZLIB_COMPRESS_FAILED: deflate rc=" + String(Int(rc)))
    out.resize(unsafe_uninit_length=total_out)
    return out^


def _snappy_compress_chunk(src: Span[UInt8, _]) raises -> List[UInt8]:
    """Direct Span-in / List-out via _span_ptr + _list_ptr (no intermediate
    alloc/copy).
    """
    var in_len = len(src)
    var out_cap = 32 + in_len + in_len // 6
    var out = List[UInt8](capacity=max(out_cap, 1))
    var size_buf = alloc[Int64](1)
    size_buf[0] = Int64(out_cap)
    # FFI-BOUNDARY: snappy is statically linked (the core packages' deps).
    var status = external_call["komira_snappy_compress", Int32](
        _span_ptr(src),
        Int64(in_len),
        _list_ptr(out),
        size_buf,
    )
    var written = Int(size_buf[0])
    size_buf.free()
    if Int(status) != 0:
        raise Error("OrcCodecError.SNAPPY_COMPRESS_FAILED status=" + String(Int(status)))
    out.resize(unsafe_uninit_length=written)
    return out^


def _lz4_compress_chunk(src: Span[UInt8, _]) raises -> List[UInt8]:
    """Direct Span-in / List-out via _span_ptr + _list_ptr (no intermediate
    alloc/copy).
    """
    var in_len = len(src)
    var handle_ptr = _default_lz4_handle()
    var out_cap = Int(handle_ptr[].call["LZ4_compressBound", Int32](Int32(in_len)))
    if out_cap <= 0:
        out_cap = in_len + in_len // 2 + 64
    var out = List[UInt8](capacity=max(out_cap, 1))
    var written = Int(
        handle_ptr[].call["LZ4_compress_default", Int32](
            _span_ptr(src),
            _list_ptr(out),
            Int32(in_len),
            Int32(out_cap),
        )
    )
    if written <= 0:
        raise Error("OrcCodecError.LZ4_COMPRESS_FAILED result=" + String(written))
    out.resize(unsafe_uninit_length=written)
    return out^


# =============================================================================
# Zstd single-chunk decompress (libzstd FFI). Appends to `out`.
# =============================================================================


def _zstd_decompress_chunk(
    chunk: Span[UInt8, _], cap: Int, mut out: List[UInt8]
) raises:
    """Zstd-decompress one chunk into `out`. Uses `ZSTD_getFrameContentSize` to
    size the output buffer precisely; falls back to a growable retry loop when
    the content size is unknown (some ZSTD encoders omit the frame-content-size
    field). `cap` is the writer-advertised compressionBlockSize hint — used as
    the lower bound for the initial guess only."""
    var in_buf = alloc[UInt8](len(chunk))
    for i in range(len(chunk)):
        in_buf[i] = chunk[i]

    var handle_ptr = _default_zstd_handle()
    # ZSTD_getFrameContentSize returns the decompressed size, or a sentinel for
    # unknown / error frames. The sentinels are large positive integers (the C
    # API returns unsigned long long); we treat them as "unknown" and fall back
    # to a growable buffer.
    var frame_size = handle_ptr[].call["ZSTD_getFrameContentSize", Int](
        in_buf.unsafe_origin_cast[MutUntrackedOrigin](),
        len(chunk),
    )
    # ZSTD_CONTENTSIZE_UNKNOWN = (unsigned long long)-1 = -1 when cast to Int
    # on LP64; ZSTD_CONTENTSIZE_ERROR = (unsigned long long)-2 = -2.
    var size_known = frame_size >= 0
    var initial_cap = frame_size if size_known else (cap if cap > 0 else (256 * 1024))
    # ⚠ `frame_size` IS ATTACKER DATA. It is a size declared INSIDE the
    # compressed frame the file supplied, so a ~10-byte zstd header can ask for
    # a terabyte here. `decompress_stream` bounds `cap`, but this branch bypasses
    # `cap` entirely — it is the one initial allocation the block-size ceiling
    # does not cover, so it gets the same ceiling explicitly. A frame that
    # genuinely decompresses past 1 GiB is not something this reader supports
    # anyway (the retry path refuses to grow past it).
    if initial_cap > ORC_MAX_COMPRESSION_BLOCK_SIZE:
        in_buf.free()
        raise Error(
            String("OrcCodecError.BAD_BLOCK_SIZE: zstd frame declares a")
            + " decompressed size of "
            + String(initial_cap)
            + " bytes, above the maximum "
            + String(ORC_MAX_COMPRESSION_BLOCK_SIZE)
        )
    # Defense against a tiny `cap` argument when the writer's hint is missing:
    # never start smaller than the chunk's compressed length (decompressed is
    # at least as large) and never larger than ZSTD_DECOMPRESSBOUND.
    if initial_cap < len(chunk):
        initial_cap = len(chunk)

    var out_cap = initial_cap
    var out_buf = alloc[UInt8](out_cap)
    while True:
        var result = handle_ptr[].call["ZSTD_decompress", Int](
            out_buf.unsafe_origin_cast[MutUntrackedOrigin](),
            out_cap,
            in_buf.unsafe_origin_cast[MutUntrackedOrigin](),
            len(chunk),
        )
        var is_err = handle_ptr[].call["ZSTD_isError", Int](result)
        if is_err == 0:
            # SUCCESS: append `result` decompressed bytes.
            for i in range(result):
                out.append(out_buf[i])
            in_buf.free()
            out_buf.free()
            return
        # FAILED: if the frame size was known up front, this is a real error
        # (not a buffer-too-small). Surface immediately.
        if size_known:
            in_buf.free()
            out_buf.free()
            raise Error(
                "OrcCodecError.ZSTD_FAILED: ZSTD_decompress result="
                + String(result)
                + " (in_len=" + String(len(chunk))
                + ", out_cap=" + String(out_cap)
                + ", known_size=" + String(frame_size) + ")"
            )
        # Unknown frame size — assume buffer-too-small and retry with a doubled
        # output buffer. Cap retries at a generous absolute size (1 GiB) to
        # avoid runaway growth on a malformed frame.
        out_buf.free()
        var new_cap = out_cap * 2
        if new_cap > (1 << 30):
            in_buf.free()
            raise Error(
                "OrcCodecError.ZSTD_FAILED: ZSTD_decompress result="
                + String(result)
                + " (in_len=" + String(len(chunk))
                + ", out_cap=" + String(out_cap)
                + ", retry-cap-exceeded)"
            )
        out_cap = new_cap
        out_buf = alloc[UInt8](out_cap)


# =============================================================================
# Zlib single-chunk decompress (libz raw-deflate FFI). Appends to `out`.
# =============================================================================
#
# ORC zlib is RAW RFC-1951 deflate: no 2-byte zlib header, no 4-byte ADLER32
# trailer. We drive zlib's streaming inflate with `windowBits = -15` (negative
# => raw deflate, no header expected). This is the SAME convention Avro deflate
# uses (the Avro deflate codec) and DIFFERENT from parquet GZIP (windowBits = 15+32
# auto-detect). The z_stream is the opaque 112-byte LP64 layout.

comptime _Z_STREAM_SIZE: Int = 112
comptime _Z_OK: Int = 0
comptime _Z_STREAM_END: Int = 1
comptime _Z_NO_FLUSH: Int = 0
# windowBits = -15 => RAW RFC-1951 deflate (no zlib header/trailer).
comptime _Z_WINDOWBITS_RAW: Int32 = -15


def _zlib_decompress_chunk(
    chunk: Span[UInt8, _], cap: Int, mut out: List[UInt8]
) raises:
    """Raw-deflate-decompress one ORC zlib chunk into `out`.

    Uses `inflateInit2_(windowBits = -15)` so a zlib-WRAPPED payload (0x78
    header + ADLER32) is rejected — ORC zlib is raw RFC-1951 only.

    Retries with a doubled output buffer on Z_BUF_ERROR — handles cross-tool
    files whose chunks decompress to more than the writer-advertised
    compressionBlockSize.
    """
    var in_buf = alloc[UInt8](len(chunk))
    for i in range(len(chunk)):
        in_buf[i] = chunk[i]

    var handle_ptr = _default_z_handle()
    var version = handle_ptr[].call[
        "zlibVersion", UnsafePointer[UInt8, MutUntrackedOrigin]
    ]()

    var initial_cap = cap if cap > 0 else (256 * 1024)
    if initial_cap < len(chunk):
        initial_cap = len(chunk)
    var out_cap = initial_cap
    while True:
        var out_buf = alloc[UInt8](out_cap)

        # SAFETY: `strm` is a 112-byte scratch buffer for the duration of this
        # call; freed via inflateEnd + alloc.free() before return. We only set
        # the four I/O fields (next_in/avail_in/next_out/avail_out) — the rest
        # stay zero.
        var strm = alloc[UInt8](_Z_STREAM_SIZE)
        unsafe_memset(strm, 0, _Z_STREAM_SIZE)
        # next_in @0 (UInt64), avail_in @8 (UInt32 idx 2), next_out @24 (UInt64
        # idx 3), avail_out @32 (UInt32 idx 8). Same LP64 layout as parquet.
        (strm.bitcast[UInt64]() + 0)[] = UInt64(Int(in_buf))
        (strm.bitcast[UInt32]() + 2)[] = UInt32(len(chunk))
        (strm.bitcast[UInt64]() + 3)[] = UInt64(Int(out_buf))
        (strm.bitcast[UInt32]() + 8)[] = UInt32(out_cap)

        var init_rc = handle_ptr[].call["inflateInit2_", Int32](
            strm, _Z_WINDOWBITS_RAW, version, Int32(_Z_STREAM_SIZE)
        )
        if Int(init_rc) != _Z_OK:
            strm.free()
            in_buf.free()
            out_buf.free()
            raise Error(
                "OrcCodecError.ZLIB_FAILED: inflateInit2_(-15) rc="
                + String(Int(init_rc))
            )

        var rc = handle_ptr[].call["inflate", Int32](strm, Int32(_Z_NO_FLUSH))
        # total_out @40 (UInt64 idx 5).
        var total_out = Int((strm.bitcast[UInt64]() + 5)[])
        # avail_out @32 (UInt32 idx 8); if it is 0 AND rc != Z_STREAM_END the
        # buffer was insufficient.
        var avail_out_remaining = Int((strm.bitcast[UInt32]() + 8)[])
        _ = handle_ptr[].call["inflateEnd", Int32](strm)
        strm.free()

        if Int(rc) == _Z_OK or Int(rc) == _Z_STREAM_END:
            # If Z_OK but avail_out == 0, we filled the buffer exactly but the
            # stream may have more bytes — grow and retry.
            if Int(rc) == _Z_OK and avail_out_remaining == 0:
                out_buf.free()
                var new_cap = out_cap * 2
                if new_cap > (1 << 30):
                    in_buf.free()
                    raise Error(
                        "OrcCodecError.ZLIB_FAILED: retry-cap-exceeded"
                        + " (in_len=" + String(len(chunk))
                        + ", out_cap=" + String(out_cap) + ")"
                    )
                out_cap = new_cap
                continue
            for i in range(total_out):
                out.append(out_buf[i])
            in_buf.free()
            out_buf.free()
            return
        # rc == Z_BUF_ERROR (-5) — output buffer too small. Retry doubled.
        out_buf.free()
        var new_cap = out_cap * 2
        if new_cap > (1 << 30):
            in_buf.free()
            raise Error(
                "OrcCodecError.ZLIB_FAILED: inflate rc="
                + String(Int(rc))
                + " (in_len=" + String(len(chunk))
                + ", out_cap=" + String(out_cap)
                + ", retry-cap-exceeded)"
            )
        out_cap = new_cap


# =============================================================================
# Snappy single-chunk decompress (the snappy C API). Appends to `out`.
# =============================================================================
#
# ORC snappy is a RAW snappy block wrapped in the 3-byte ORC chunk header. There
# is NO Avro-style BE4 CRC32 trailer (that is the Avro snappy framing). We hand
# the chunk payload straight to `snappy_uncompress`.


def _snappy_decompress_chunk(
    chunk: Span[UInt8, _], cap: Int, mut out: List[UInt8]
) raises:
    """Snappy-decompress one ORC chunk into `out`. No CRC trailer (cf. Avro).
    Uses `snappy_uncompressed_length` to size the output buffer exactly, so
    chunks decompressing to >cap bytes succeed regardless of the writer's
    advertised compressionBlockSize."""
    var in_buf = alloc[UInt8](len(chunk))
    for i in range(len(chunk)):
        in_buf[i] = chunk[i]

    # SAFETY: 1-element scratch slot for snappy_uncompressed_length's out arg.
    # FFI-BOUNDARY: snappy is statically linked (the core packages' deps).
    var ulen_buf = alloc[Int64](1)
    ulen_buf[0] = Int64(0)
    var ul_status = external_call["komira_snappy_uncompressed_length", Int32](
        in_buf.unsafe_origin_cast[MutUntrackedOrigin](),
        Int64(len(chunk)),
        ulen_buf,
    )
    var precise_size = Int(ulen_buf[0])
    ulen_buf.free()
    var out_cap = precise_size if Int(ul_status) == 0 and precise_size > 0 else (
        cap if cap > 0 else (256 * 1024)
    )
    if out_cap < len(chunk):
        out_cap = len(chunk)

    var out_buf = alloc[UInt8](out_cap)
    # SAFETY: 1-element in/out length slot (in: capacity, out: actual length).
    var size_buf = alloc[Int64](1)
    size_buf[0] = Int64(out_cap)
    var status = external_call["komira_snappy_uncompress", Int32](
        in_buf.unsafe_origin_cast[MutUntrackedOrigin](),
        Int64(len(chunk)),
        out_buf.unsafe_origin_cast[MutUntrackedOrigin](),
        size_buf,
    )
    var written = Int(size_buf[0])
    size_buf.free()
    if Int(status) != 0:
        in_buf.free()
        out_buf.free()
        raise Error(
            "OrcCodecError.SNAPPY_FAILED: snappy_uncompress status="
            + String(Int(status))
            + " (in_len=" + String(len(chunk))
            + ", out_cap=" + String(out_cap) + ")"
        )
    for i in range(written):
        out.append(out_buf[i])
    in_buf.free()
    out_buf.free()


# =============================================================================
# Lz4 single-chunk decompress (liblz4 FFI). Appends to `out`.
# =============================================================================
#
# ORC uses the LZ4 BLOCK format (not the LZ4 frame format), so we call
# `LZ4_decompress_safe(src, dst, compressedSize, dstCapacity)` directly. The
# decompressed size is bounded by `cap`. Returns the byte count, or < 0 on error.


def _lz4_decompress_chunk(
    chunk: Span[UInt8, _], cap: Int, mut out: List[UInt8]
) raises:
    """LZ4-block-decompress one ORC chunk into `out` (LZ4_decompress_safe).
    Retries with a doubled output buffer on size-too-small failure (LZ4 returns
    a negative result code without distinguishing the reason)."""
    var in_buf = alloc[UInt8](len(chunk))
    for i in range(len(chunk)):
        in_buf[i] = chunk[i]

    var handle_ptr = _default_lz4_handle()
    var initial_cap = cap if cap > 0 else (256 * 1024)
    if initial_cap < len(chunk):
        initial_cap = len(chunk)
    var out_cap = initial_cap
    while True:
        var out_buf = alloc[UInt8](out_cap)
        var result = handle_ptr[].call["LZ4_decompress_safe", Int32](
            in_buf.unsafe_origin_cast[MutUntrackedOrigin](),
            out_buf.unsafe_origin_cast[MutUntrackedOrigin](),
            Int32(len(chunk)),
            Int32(out_cap),
        )
        if Int(result) >= 0:
            for i in range(Int(result)):
                out.append(out_buf[i])
            in_buf.free()
            out_buf.free()
            return
        # Negative result — either malformed input OR buffer-too-small. Retry
        # with a doubled buffer up to a 1 GiB ceiling.
        out_buf.free()
        var new_cap = out_cap * 2
        if new_cap > (1 << 30):
            in_buf.free()
            raise Error(
                "OrcCodecError.LZ4_FAILED: LZ4_decompress_safe result="
                + String(Int(result))
                + " (in_len=" + String(len(chunk))
                + ", out_cap=" + String(out_cap)
                + ", retry-cap-exceeded)"
            )
        out_cap = new_cap


# =============================================================================
# Lzo single-chunk decompress — NATIVE (no FFI). Appends to `out`.
# =============================================================================
#
# Deprecated codec, spec-required for READ completeness. Decoded by
# `lzo1x_decompress.mojo`: a native decoder implementing the SAFE variant's
# discipline (every input read length-checked, every output
# write limit-checked, every back-reference checked against the start of the
# block). See that file's header for the licensing rationale and the format.
#
# There is no retry-with-a-doubled-buffer loop: the native decoder grows its
# own scratch buffer as it decodes, so a chunk that expands past the
# writer-advertised `cap` costs a reallocation instead of a full re-decode, and
# the ceiling is enforced BEFORE each allocation rather than after a failure.
# `cap` is purely a sizing hint.


def _lzo_decompress_chunk(
    chunk: Span[UInt8, _], cap: Int, mut out: List[UInt8]
) raises:
    """LZO1X-decompress one ORC chunk into `out` (native; see above)."""
    lzo1x_decompress(chunk, cap, ORC_MAX_COMPRESSION_BLOCK_SIZE, out)


# =============================================================================
# libzstd / libz / liblz4 OwnedDLHandle singletons (process-lifetime dlopen
# cache).
# =============================================================================
#
# Per-OS soname; the first call per process pays the dlopen, subsequent calls
# reuse the handle from its `_Global` slot. Snappy is not here: it is
# statically linked (this package's deps name //third_party/snappy) and its C
# API, renamed komira_snappy_*, is called through `external_call`.

comptime _LIBZSTD: StaticString = (
    "libzstd.dylib" if CompilationTarget.is_macos() else "libzstd.so.1"
)
comptime _LIBZ: StaticString = (
    "libz.dylib" if CompilationTarget.is_macos() else "libz.so.1"
)
comptime _LIBLZ4: StaticString = (
    "liblz4.dylib" if CompilationTarget.is_macos() else "liblz4.so.1"
)
# -----------------------------------------------------------------------------
# Process-lifetime OwnedDLHandle singletons via the stdlib `_Global` runtime
# slot. `_Global[name, init_fn]` is
# a name-keyed, process-global, init-once, cross-compile-unit-coherent slot
# managed by the KGEN runtime — no env var, no address laundering. Distinct
# `_Global` names keep the orc handles independent of other packages'
# singletons for the same dylibs.
# -----------------------------------------------------------------------------


def _init_orc_zstd_handle() -> OwnedDLHandle:
    """`_Global` init_fn (non-raising): dlopen libzstd once per process.

    SAFETY: the OwnedDLHandle ctor raises only on an unresolvable pinned dylib
    (fatal provisioning error), so we `abort`.
    """
    try:
        return OwnedDLHandle(_LIBZSTD)
    except e:
        abort("libzstd dlopen failed (orc codec handle init)")


def _init_orc_z_handle() -> OwnedDLHandle:
    """`_Global` init_fn (non-raising): dlopen libz once per process."""
    try:
        return OwnedDLHandle(_LIBZ)
    except e:
        abort("libz dlopen failed (orc codec handle init)")


def _init_orc_lz4_handle() -> OwnedDLHandle:
    """`_Global` init_fn (non-raising): dlopen liblz4 once per process."""
    try:
        return OwnedDLHandle(_LIBLZ4)
    except e:
        abort("liblz4 dlopen failed (orc codec handle init)")


comptime _ZSTD_GLOBAL = _Global["komira_orc_zstd_handle", _init_orc_zstd_handle]
comptime _Z_GLOBAL = _Global["komira_orc_z_handle", _init_orc_z_handle]
comptime _LZ4_GLOBAL = _Global["komira_orc_lz4_handle", _init_orc_lz4_handle]


# Per-codec accessors — process-lifetime handle slot (init-once via `_Global`).
# SAFETY: FFI seam; `MutUntrackedOrigin` is the stdlib `_Global` return
# type (runtime-managed static storage). No env var, no `unsafe_from_address`.
def _default_zstd_handle() raises -> UnsafePointer[
    OwnedDLHandle, MutUntrackedOrigin
]:
    return _ZSTD_GLOBAL.get_or_create_ptr()


def _default_z_handle() raises -> UnsafePointer[
    OwnedDLHandle, MutUntrackedOrigin
]:
    return _Z_GLOBAL.get_or_create_ptr()


def _default_lz4_handle() raises -> UnsafePointer[
    OwnedDLHandle, MutUntrackedOrigin
]:
    return _LZ4_GLOBAL.get_or_create_ptr()
