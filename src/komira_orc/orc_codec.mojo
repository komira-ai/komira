# =============================================================================
# orc_codec.mojo — ORC stream codec compression and decompression (the full
# codec matrix).
# =============================================================================
#
# The codecs are komira_compression's codec API (snappy_block, zstd_frame,
# zlib, lz4): this module declares no codec FFI and takes no pointer.
# komira_compression owns every codec soname and the snappy symbols.
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
# `List[UInt8]`. Each codec writes into a List this module allocates, through
# a Span over it.
# =============================================================================

from komira_compression.lz4 import (
    lz4_compress_bound,
    lz4_compress_into,
    lz4_decompress_into,
)
from komira_compression.snappy_block import (
    snappy_compress_into,
    snappy_max_compressed_length,
    snappy_uncompress_into,
    snappy_uncompressed_length,
)
from komira_compression.zlib import (
    ZLIB_LEVEL_DEFAULT,
    ZlibInflateOutcome,
    ZLIB_WINDOW_BITS_RAW,
    Z_OK,
    Z_STREAM_END,
    zlib_compress_bound,
    zlib_deflate_into,
    zlib_inflate_once,
)
from komira_compression.zstd_frame import (
    ZSTD_DEFAULT_LEVEL,
    zstd_compress_bound,
    zstd_compress_into,
    zstd_decompress_into,
    zstd_frame_content_size,
)

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


def _output_buffer(cap: Int) -> List[UInt8]:
    """A List of `cap` bytes for a codec to write into. The bytes are not
    initialized; the caller reads back only the ones the codec wrote."""
    var out = List[UInt8](capacity=cap)
    # SAFETY: `cap` bytes were reserved above; only the codec's written
    # prefix is read (or kept) afterwards.
    out.resize(unsafe_uninit_length=cap)
    return out^


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
    # that becomes each codec helper's INITIAL buffer size, once per chunk. The
    # retry-growth path below already refuses to exceed 1 GiB
    # (`new_cap > (1 << 30)`); without the same ceiling on the initial
    # allocation, ~10 bytes of PostScript would buy an arbitrarily large
    # allocation. One ceiling covers both. ORC's spec default is 256 KiB.
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
# Per-codec single-chunk COMPRESS helpers (inverse of the decompress helpers).
# Each returns the raw compressed block (no chunk framing); the codec writes
# straight into the returned List, sized at its own bound.
# =============================================================================


def _zstd_compress_chunk(src: Span[UInt8, _]) raises -> List[UInt8]:
    """One zstd frame at level 3."""
    var out = _output_buffer(max(zstd_compress_bound(len(src)), 1))
    var written: Int
    try:
        written = zstd_compress_into(Span(out), src, ZSTD_DEFAULT_LEVEL)
    except e:
        raise Error("OrcCodecError.ZSTD_COMPRESS_FAILED: " + String(e))
    out.resize(unsafe_uninit_length=written)
    return out^


def _zlib_compress_chunk(src: Span[UInt8, _]) raises -> List[UInt8]:
    """RAW-deflate-compress (level 6, windowBits -15) one chunk — inverse of
    _zlib_decompress_chunk's raw RFC-1951 reader."""
    var cap = zlib_compress_bound(len(src), ZLIB_WINDOW_BITS_RAW)
    var out = _output_buffer(max(cap, 1))
    var written: Int
    try:
        written = zlib_deflate_into(
            Span(out), src, ZLIB_LEVEL_DEFAULT, ZLIB_WINDOW_BITS_RAW
        )
    except e:
        raise Error("OrcCodecError.ZLIB_COMPRESS_FAILED: " + String(e))
    out.resize(unsafe_uninit_length=written)
    return out^


def _snappy_compress_chunk(src: Span[UInt8, _]) raises -> List[UInt8]:
    """One raw snappy block."""
    var out = _output_buffer(snappy_max_compressed_length(len(src)))
    var written: Int
    try:
        written = snappy_compress_into(Span(out), src)
    except e:
        raise Error("OrcCodecError.SNAPPY_COMPRESS_FAILED: " + String(e))
    out.resize(unsafe_uninit_length=written)
    return out^


def _lz4_compress_chunk(src: Span[UInt8, _]) raises -> List[UInt8]:
    """One LZ4 raw block (`LZ4_compress_default`)."""
    var out = _output_buffer(lz4_compress_bound(len(src)))
    var written: Int
    try:
        written = lz4_compress_into(Span(out), src)
    except e:
        raise Error("OrcCodecError.LZ4_COMPRESS_FAILED: " + String(e))
    out.resize(unsafe_uninit_length=written)
    return out^


# =============================================================================
# Zstd single-chunk decompress. Appends to `out`.
# =============================================================================


def _zstd_decompress_chunk(
    chunk: Span[UInt8, _], cap: Int, mut out: List[UInt8]
) raises:
    """Zstd-decompress one chunk into `out`. Uses the frame header's content
    size to size the output buffer precisely; falls back to a growable retry
    loop when the content size is unknown (some ZSTD encoders omit the
    frame-content-size field). `cap` is the writer-advertised
    compressionBlockSize hint — used as the lower bound for the initial guess
    only."""
    # The content size is the decompressed size, or a sentinel for unknown /
    # error frames. The sentinels (and any size of 2^63 or more) are treated
    # as "unknown", with a growable buffer.
    var content = zstd_frame_content_size(chunk)
    var size_known = content < (UInt64(1) << 63)
    var frame_size = Int(content) if size_known else -1
    var initial_cap = frame_size if size_known else (cap if cap > 0 else (256 * 1024))
    # ⚠ `frame_size` IS ATTACKER DATA. It is a size declared INSIDE the
    # compressed frame the file supplied, so a ~10-byte zstd header can ask for
    # a terabyte here. `decompress_stream` bounds `cap`, but this branch bypasses
    # `cap` entirely — it is the one initial allocation the block-size ceiling
    # does not cover, so it gets the same ceiling explicitly. A frame that
    # genuinely decompresses past 1 GiB is not something this reader supports
    # anyway (the retry path refuses to grow past it).
    if initial_cap > ORC_MAX_COMPRESSION_BLOCK_SIZE:
        raise Error(
            String("OrcCodecError.BAD_BLOCK_SIZE: zstd frame declares a")
            + " decompressed size of "
            + String(initial_cap)
            + " bytes, above the maximum "
            + String(ORC_MAX_COMPRESSION_BLOCK_SIZE)
        )
    # Defense against a tiny `cap` argument when the writer's hint is missing:
    # never start smaller than the chunk's compressed length.
    if initial_cap < len(chunk):
        initial_cap = len(chunk)

    var out_cap = initial_cap
    while True:
        var buf = _output_buffer(out_cap)
        try:
            var result = zstd_decompress_into(Span(buf), chunk)
            out.extend(Span(buf)[0:result])
            return
        except e:
            # If the frame size was known up front, this is a real error
            # (not a buffer-too-small). Surface immediately.
            if size_known:
                raise Error(
                    "OrcCodecError.ZSTD_FAILED: " + String(e)
                    + " (known_size=" + String(frame_size) + ")"
                )
            # Unknown frame size — assume buffer-too-small and retry with a
            # doubled output buffer. Cap retries at a generous absolute size
            # (1 GiB) to avoid runaway growth on a malformed frame.
            var new_cap = out_cap * 2
            if new_cap > (1 << 30):
                raise Error(
                    "OrcCodecError.ZSTD_FAILED: " + String(e)
                    + " (retry-cap-exceeded)"
                )
            out_cap = new_cap


# =============================================================================
# Zlib single-chunk decompress (raw deflate). Appends to `out`.
# =============================================================================
#
# ORC zlib is RAW RFC-1951 deflate: no 2-byte zlib header, no 4-byte ADLER32
# trailer. Each attempt is one `inflate` call with `windowBits = -15`
# (`ZLIB_WINDOW_BITS_RAW`: negative => raw deflate, no header expected). This
# is the SAME convention Avro deflate uses and DIFFERENT from parquet GZIP
# (windowBits = 15+32 auto-detect).


def _zlib_decompress_chunk(
    chunk: Span[UInt8, _], cap: Int, mut out: List[UInt8]
) raises:
    """Raw-deflate-decompress one ORC zlib chunk into `out`.

    Inflates with `windowBits = -15`, so a zlib-WRAPPED payload (0x78 header
    + ADLER32) is rejected — ORC zlib is raw RFC-1951 only.

    Retries with a doubled output buffer when libz stops short (Z_OK with the
    output full, or any other return code) — handles cross-tool files whose
    chunks decompress to more than the writer-advertised
    compressionBlockSize.
    """
    var initial_cap = cap if cap > 0 else (256 * 1024)
    if initial_cap < len(chunk):
        initial_cap = len(chunk)
    var out_cap = initial_cap
    while True:
        var buf = _output_buffer(out_cap)
        var res: ZlibInflateOutcome
        try:
            res = zlib_inflate_once(Span(buf), chunk, ZLIB_WINDOW_BITS_RAW)
        except e:
            raise Error("OrcCodecError.ZLIB_FAILED: " + String(e))
        if res.rc == Z_OK or res.rc == Z_STREAM_END:
            # If Z_OK but no output space is left, we filled the buffer
            # exactly but the stream may have more bytes — grow and retry.
            if res.rc == Z_OK and res.unwritten == 0:
                var new_cap = out_cap * 2
                if new_cap > (1 << 30):
                    raise Error(
                        "OrcCodecError.ZLIB_FAILED: retry-cap-exceeded"
                        + " (in_len=" + String(len(chunk))
                        + ", out_cap=" + String(out_cap) + ")"
                    )
                out_cap = new_cap
                continue
            out.extend(Span(buf)[0 : res.written])
            return
        # Any other return code (Z_BUF_ERROR: output buffer too small).
        # Retry doubled.
        var new_cap = out_cap * 2
        if new_cap > (1 << 30):
            raise Error(
                "OrcCodecError.ZLIB_FAILED: inflate rc="
                + String(Int(res.rc))
                + " (in_len=" + String(len(chunk))
                + ", out_cap=" + String(out_cap)
                + ", retry-cap-exceeded)"
            )
        out_cap = new_cap


# =============================================================================
# Snappy single-chunk decompress. Appends to `out`.
# =============================================================================
#
# ORC snappy is a RAW snappy block wrapped in the 3-byte ORC chunk header. There
# is NO Avro-style BE4 CRC32 trailer (that is the Avro snappy framing). The
# chunk payload goes straight to `snappy_uncompress_into`.


def _snappy_decompress_chunk(
    chunk: Span[UInt8, _], cap: Int, mut out: List[UInt8]
) raises:
    """Snappy-decompress one ORC chunk into `out`. No CRC trailer (cf. Avro).
    Uses the block's declared uncompressed length to size the output buffer
    exactly, so chunks decompressing to >cap bytes succeed regardless of the
    writer's advertised compressionBlockSize."""
    var precise_size = 0
    try:
        precise_size = snappy_uncompressed_length(chunk)
    except:
        # An unparseable preamble: fall back to `cap`; the decode refuses it.
        precise_size = 0
    var out_cap = precise_size if precise_size > 0 else (
        cap if cap > 0 else (256 * 1024)
    )
    if out_cap < len(chunk):
        out_cap = len(chunk)

    var buf = _output_buffer(out_cap)
    var written: Int
    try:
        written = snappy_uncompress_into(Span(buf), chunk)
    except e:
        raise Error("OrcCodecError.SNAPPY_FAILED: " + String(e))
    out.extend(Span(buf)[0:written])


# =============================================================================
# Lz4 single-chunk decompress. Appends to `out`.
# =============================================================================
#
# ORC uses the LZ4 BLOCK format (not the LZ4 frame format):
# `lz4_decompress_into` (`LZ4_decompress_safe`). The decompressed size is
# bounded by `cap`; a failure does not say whether the block is corrupt or the
# buffer too small.


def _lz4_decompress_chunk(
    chunk: Span[UInt8, _], cap: Int, mut out: List[UInt8]
) raises:
    """LZ4-block-decompress one ORC chunk into `out`.
    Retries with a doubled output buffer on any failure (LZ4 returns a
    negative result code without distinguishing the reason)."""
    var initial_cap = cap if cap > 0 else (256 * 1024)
    if initial_cap < len(chunk):
        initial_cap = len(chunk)
    var out_cap = initial_cap
    while True:
        var buf = _output_buffer(out_cap)
        try:
            var written = lz4_decompress_into(Span(buf), chunk)
            out.extend(Span(buf)[0:written])
            return
        except e:
            # Malformed input OR buffer-too-small. Retry with a doubled
            # buffer up to a 1 GiB ceiling.
            var new_cap = out_cap * 2
            if new_cap > (1 << 30):
                raise Error(
                    "OrcCodecError.LZ4_FAILED: " + String(e)
                    + " (retry-cap-exceeded)"
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
