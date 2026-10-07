# =============================================================================
# Parquet page compression: the codec dispatch
# =============================================================================
#
# Codecs:
#   - UNCOMPRESSED: a copy.
#   - SNAPPY:       the statically linked snappy C API, or the Mojo decoder
#                   (snappy/snappy_ffi.mojo).
#   - ZSTD:         libzstd (zstd/zstd_ffi.mojo).
#   - LZ4_RAW:      a liblz4 raw block (codec id 7), through
#                   komira_compression's lz4; read and write.
#   - LZ4:          the DEPRECATED codec id 5, READ ONLY, by framing
#                   detection across its three in-the-wild layouts. A distinct
#                   codec from LZ4_RAW; never written.
#   - GZIP:         libz through komira_compression's zlib (window_bits=15+32:
#                   a gzip or a zlib wrapper).
#   - BROTLI:       the statically linked Brotli decoder
#                   (brotli/brotli_ffi.mojo); read only.
# The LZ4 frame codec (lz4_frame/lz4_ffi.mojo) is also reachable directly,
# for `.lz4` text files. snappy, libzstd, libz and liblz4 are
# komira_compression's (it declares the snappy symbols and owns every codec
# soname); only the Brotli decoder is linked and called from this package.
#
# Contract:
#   - Every entry takes its input as a `Span[UInt8]` and writes into a
#     caller-owned `Span[UInt8, mut]`; the output Span's length is the
#     capacity, and the entry returns the number of bytes written. No raw
#     pointer is in any signature here or in the codecs this module calls:
#     the pointers are taken from the Spans inside each codec, for one
#     synchronous FFI call.
#   - The C libraries never retain a pointer across a call.
# =============================================================================

from std.memory import unsafe_memcpy

from .snappy.snappy_ffi import (
    snappy_decompress as _snappy_decompress,
    snappy_compress as _snappy_compress,
    snappy_uncompressed_length,
    snappy_max_compressed_length,
)
from .zstd.zstd_ffi import (
    _zstd_decompress_into,
    _zstd_compress_into,
    _zstd_compress_bound,
)
# zlib/GZIP codec: komira_compression's zlib (komira_zlib, the libz owner).
from komira_compression.zlib import (
    ZLIB_LEVEL_DEFAULT,
    ZLIB_WINDOW_BITS_AUTO,
    ZLIB_WINDOW_BITS_GZIP,
    zlib_compress_bound,
    zlib_deflate_into,
    zlib_inflate_into,
)
# LZ4 RAW-BLOCK codec: komira_compression's lz4 (komira_lz4, the liblz4
# owner).
from komira_compression.lz4 import (
    lz4_compress_bound,
    lz4_compress_into,
    lz4_decompress_into,
)
# LZ4 FRAME codec (the interoperable framing Kafka and Arrow IPC use): a
# distinct codec from the raw block.
from .lz4_frame.lz4_ffi import (
    _lz4_frame_decompress_into,
    _lz4_frame_compress_into,
    _lz4_frame_compress_bound,
)
from .brotli.brotli_ffi import _brotli_decompress_into

from komira_parquet_api import CompressionCodec


# =============================================================================
# Constants
# =============================================================================

# GZIP decode: `ZLIB_WINDOW_BITS_AUTO` (15 + 32) accepts a gzip or a zlib
# wrapper. Load-bearing for Parquet interop because parquet-mr / DuckDB /
# pyarrow / Spark disagree on which framing they emit for the "GZIP" codec id.
# GZIP encode: `ZLIB_WINDOW_BITS_GZIP` (15 + 16), the gzip wrapper. Every
# Parquet reader accepts gzip framing for the GZIP codec, and more readers
# accept it than zlib framing.

# Default zstd compression level.
comptime _ZSTD_LEVEL_DEFAULT: Int32 = 3


# =============================================================================
# Public API
# =============================================================================


def decompress[
    o_out: MutOrigin
](
    codec: CompressionCodec,
    input: Span[UInt8, _],
    output: Span[UInt8, o_out],
) raises -> Int:
    """Decompress `input` into `output`. Returns the number of bytes written.

    Dispatches to the appropriate codec via per-codec FFI shim:
      - UNCOMPRESSED: memcpy passthrough
      - SNAPPY:  the snappy C API (or the Mojo decoder, `set_snappy_decoder`)
      - ZSTD:    libzstd
      - LZ4_RAW: liblz4 raw block
      - LZ4:     liblz4, by framing detection (see `_decompress_lz4_deprecated`)
      - GZIP:    libz (a gzip or a zlib wrapper)
      - BROTLI:  the Brotli decoder (statically linked)

    Args:
        codec: The Parquet compression codec.
        input: The compressed bytes.
        output: The output buffer; its length is the capacity (at least the
            page's uncompressed size).

    Returns:
        Number of bytes written to output.

    Raises:
        Error if codec is unsupported or decompression fails.
    """
    # The lengths are the Spans' own, never negative: a page decoder that
    # derives a length from page-header arithmetic must refuse a negative
    # one before it builds the Span, because every codec shim hands its
    # lengths to C as `size_t`, where a negative value is an unbounded size.
    if codec == CompressionCodec.UNCOMPRESSED:
        return _copy_uncompressed(input, output)
    elif codec == CompressionCodec.SNAPPY:
        return _snappy_decompress(input, output)
    elif codec == CompressionCodec.ZSTD:
        return _zstd_decompress_into(output, input)
    elif codec == CompressionCodec.LZ4_RAW:
        return lz4_decompress_into(output, input)
    elif codec == CompressionCodec.LZ4:
        # Codec id 5 is the DEPRECATED `LZ4`, a DIFFERENT codec from `LZ4_RAW`
        # (id 7). Routing it to the id-7 decoder would be the silent mis-decode
        # this whole arm exists to prevent — see `_decompress_lz4_deprecated`
        # for the framing-detection contract.
        return _decompress_lz4_deprecated(input, output)
    elif codec == CompressionCodec.GZIP:
        return zlib_inflate_into(output, input, ZLIB_WINDOW_BITS_AUTO)
    elif codec == CompressionCodec.BROTLI:
        # One-shot decode via BrotliDecoderDecompress; `len(output)` is the
        # in/out decoded-size capacity.
        return _brotli_decompress_into(output, input)
    elif codec == CompressionCodec.LZO:
        # LZO decompression is not implemented: a legacy codec, rarely seen.
        raise Error(
            "LZO decompression not supported. LZO is a legacy Parquet compression "
            + "codec. Re-write the file with Snappy or Zstd."
        )
    else:
        raise Error(
            "unsupported decompression codec: " + String(codec)
        )


def compress[
    o_out: MutOrigin
](
    codec: CompressionCodec,
    input: Span[UInt8, _],
    output: Span[UInt8, o_out],
) raises -> Int:
    """Compress `input` into `output`. Returns the number of bytes written.

    `output` must hold at least `compress_bound(codec, len(input))` bytes.
    """
    if codec == CompressionCodec.UNCOMPRESSED:
        return _copy_uncompressed(input, output)
    elif codec == CompressionCodec.SNAPPY:
        return _snappy_compress(input, output)
    elif codec == CompressionCodec.ZSTD:
        return _zstd_compress_into(output, input, _ZSTD_LEVEL_DEFAULT)
    elif codec == CompressionCodec.LZ4_RAW:
        return lz4_compress_into(output, input)
    elif codec == CompressionCodec.GZIP:
        return zlib_deflate_into(
            output, input, ZLIB_LEVEL_DEFAULT, ZLIB_WINDOW_BITS_GZIP
        )
    elif codec == CompressionCodec.LZ4:
        # DELIBERATELY REFUSED, not missing. Codec id 5 has three
        # incompatible on-wire framings in the wild (see
        # `_decompress_lz4_deprecated`); a writer that picks it re-creates
        # the interop problem the format already solved by adding LZ4_RAW.
        # We READ id 5 for the files that already exist; we never write it.
        raise Error(
            "parquet: refusing to WRITE the deprecated LZ4 codec (id 5) —"
            " its framing is ambiguous across implementations, which is why"
            " the format replaced it with LZ4_RAW (id 7). Use"
            " CompressionCodec.LZ4_RAW. (Reading id 5 IS supported.)"
        )
    else:
        raise Error(
            "unsupported compression codec: " + String(codec)
        )


def compress_bound(codec: CompressionCodec, input_len: Int) -> Int:
    """Return the maximum compressed size for a given codec and input size."""
    if codec == CompressionCodec.UNCOMPRESSED:
        return input_len
    elif codec == CompressionCodec.SNAPPY:
        return snappy_max_compressed_length(input_len)
    elif codec == CompressionCodec.ZSTD:
        try:
            return _zstd_compress_bound(input_len)
        except:
            return input_len + input_len // 10 + 64
    elif codec == CompressionCodec.LZ4_RAW:
        try:
            return lz4_compress_bound(input_len)
        except:
            return input_len + input_len // 10 + 64
    elif codec == CompressionCodec.GZIP:
        try:
            return zlib_compress_bound(input_len, ZLIB_WINDOW_BITS_GZIP)
        except:
            return input_len + input_len // 10 + 64
    else:
        return input_len + input_len // 10 + 64


# =============================================================================
# UNCOMPRESSED — passthrough memcpy
# =============================================================================


@always_inline
def _copy_uncompressed[
    o_out: MutOrigin
](input: Span[UInt8, _], output: Span[UInt8, o_out]) raises -> Int:
    """Passthrough: copy input to output. Returns len(input)."""
    var n = len(input)
    if n > len(output):
        raise Error(
            "output buffer too small: need "
            + String(n)
            + " but have "
            + String(len(output))
        )
    if n > 0:
        # SAFETY: `output` holds at least `n` writable bytes and `input` `n`
        # readable ones (checked above), both alive across this call by
        # their Span origins; the two buffers are distinct allocations.
        unsafe_memcpy(dest=output.unsafe_ptr(), src=input.unsafe_ptr(), count=n)
    return n


# -----------------------------------------------------------------------------
# LZ4 (codec id 5) — the DEPRECATED codec. NOT the same thing as LZ4_RAW.
# -----------------------------------------------------------------------------
#
# `parquet.thrift` carries BOTH `LZ4 = 5` and `LZ4_RAW = 7`, and the format
# added the second one *because implementations could not agree on what the
# first one meant*. Three mutually-incompatible byte layouts shipped under
# id 5:
#
#   (a) HADOOP block framing — parquet-mr / Hive / Spark, via Hadoop's
#       `BlockCompressorStream` + `Lz4Codec`. One 8-byte big-endian prefix
#       (uncompressed length, then compressed length) ahead of an LZ4 raw
#       block, repeated for each compressor buffer (256 KiB by default), so a
#       larger page holds several. This is the dominant on-disk form.
#   (b) LZ4 FRAME — Arrow C++ before 0.17 wrote a complete LZ4 frame
#       (magic 0x184D2204) under id 5.
#   (c) bare LZ4 raw block — some writers emitted exactly what id 7 later
#       standardised.
#
# Detection is by STRUCTURE, in decreasing order of evidence, and every arm
# must SUCCEED-OR-REJECT rather than guess:
#
#   1. Hadoop: every prefixed block must have length fields consistent with
#      the remaining buffer and decode to EXACTLY its declared uncompressed
#      length, and the blocks must consume the whole input. Mirrors arrow-cpp
#      `Lz4HadoopCodec::TryDecompressHadoop`.
#   2. Frame: gated on the 4-byte frame magic, so it is a positive
#      identification and not a guess. (arrow-cpp does not attempt this arm;
#      we can, because the magic makes it unambiguous.)
#   3. Bare raw block: the last resort, same decoder id 7 uses.
#
# The ordering matters and is not arbitrary. A real LZ4 frame cannot pass
# arm 1: its first four bytes read as a big-endian length of 0x04224D18
# (~69 MB), which no Parquet page's `uncompressed_page_size` will admit, so
# the `<= output_len` guard rejects it before any decode is attempted.
#
# WRITE SIDE: we never emit codec id 5, and must not. `compress()` refuses
# LZ4 on purpose — a writer that picks the ambiguous id re-creates the
# interop problem the format already solved. Emit LZ4_RAW (id 7).
# -----------------------------------------------------------------------------

# Hadoop `BlockCompressorStream` prefix: 4-byte BE uncompressed length +
# 4-byte BE compressed length. Same constant as arrow-cpp's `kPrefixLength`.
comptime _LZ4_HADOOP_PREFIX_LEN: Int = 8

# LZ4 Frame magic 0x184D2204, on the wire little-endian.
comptime _LZ4F_MAGIC_B0: UInt8 = 0x04
comptime _LZ4F_MAGIC_B1: UInt8 = 0x22
comptime _LZ4F_MAGIC_B2: UInt8 = 0x4D
comptime _LZ4F_MAGIC_B3: UInt8 = 0x18


# =============================================================================
# LZ4 WHOLE-FILE TEXT FRAMING — `.lz4` IS TWO ON-WIRE ENCODINGS, NOT ONE.
# =============================================================================
#
# Parquet/ORC/Avro name their codec in a header the reader parses. A
# line-oriented text file does not: `.csv.lz4` / `.jsonl.lz4` carries no codec
# id, so the EXTENSION is the only signal — and the extension does not say
# which of liblz4's two mutually-incompatible encodings the producer used:
#
#   * LZ4 FRAME (magic 0x184D2204) — the interoperable, self-describing
#     container that the `lz4(1)` CLI, python-lz4's `lz4.frame`, Kafka
#     (KIP-57) and every other general-purpose producer emit. Decoded by
#     `LZ4F_decompress` (`decompress_lz4_frame` below).
#   * LZ4 RAW BLOCK — a bare compressed block: no header, no magic, no stored
#     length, no checksum. It is what `compress(CompressionCodec.LZ4_RAW, ...)`
#     (`LZ4_compress_default`) produces. Decoded by `LZ4_decompress_safe`.
#
# THE WRONG DECODER DOES NOT DEGRADE GRACEFULLY, AND — THE POINT — IT FAILS
# IN A WAY THAT IMPERSONATES A SIZE PROBLEM. `LZ4_decompress_safe` reads a
# frame's first byte as a block token, so it returns a negative error code for
# EVERY output capacity. On a frame whose first four bytes are `04 22 4d 18`:
#
#     LZ4_decompress_safe(frame bytes, dstCap =  4 MiB) -> -4
#     LZ4_decompress_safe(frame bytes, dstCap = 64 MiB) -> -4     <- IDENTICAL
#
# A capacity-independent failure is not a capacity failure, but a reader
# whose cap-and-grow loop retries on every error grows its buffer until it
# hits its ceiling and then reports the decompressed size as too large, for a
# file far smaller than that ceiling. Detection prevents that misleading
# diagnostic, quite apart from the decode it enables.
#
# WHY DETECTION AND NOT A FLIP TO FRAME. Both encodings occur: external
# producers write frames, and LZ4_RAW pages are raw blocks.
# Picking either one statically breaks the other. The magic is a POSITIVE
# identification, so detection is not a guess — the same argument arm 2 of
# `_decompress_lz4_deprecated` already makes for Parquet codec id 5.


struct Lz4TextFraming(ImplicitlyCopyable, Copyable, Equatable, Writable):
    """Which of liblz4's two on-wire encodings a `.lz4` text payload carries.

    Fields:
        value: 0 = raw block, 1 = frame.
    """

    var value: UInt8

    comptime RAW_BLOCK = Lz4TextFraming(0)
    comptime FRAME = Lz4TextFraming(1)

    def __init__(out self, value: UInt8):
        self.value = value

    @always_inline
    def __eq__(self, other: Lz4TextFraming) -> Bool:
        return self.value == other.value

    @always_inline
    def __ne__(self, other: Lz4TextFraming) -> Bool:
        return self.value != other.value

    def write_to[W: Writer](self, mut writer: W):
        if self == Lz4TextFraming.FRAME:
            writer.write("LZ4_FRAME")
        elif self == Lz4TextFraming.RAW_BLOCK:
            writer.write("LZ4_RAW_BLOCK")
        else:
            writer.write("Lz4TextFraming(", String(Int(self.value)), ")")


def lz4_text_framing_of(compressed: Span[UInt8, _]) -> Lz4TextFraming:
    """Classify a whole-file `.lz4` text payload by its leading bytes.

    Returns `FRAME` iff `compressed` opens with the LZ4 Frame magic
    0x184D2204 (little-endian on the wire: `04 22 4D 18`), else `RAW_BLOCK`.

    Positive identification, one direction only: a well-formed LZ4 frame
    ALWAYS starts with that magic, so a frame can never be classified
    RAW_BLOCK. The converse is a 2^-32 coincidence on the first block of a
    raw payload, and it is the same residual arm 2 of
    `_decompress_lz4_deprecated` already accepts.
    """
    if len(compressed) < 4:
        return Lz4TextFraming.RAW_BLOCK
    if (
        compressed[0] == _LZ4F_MAGIC_B0
        and compressed[1] == _LZ4F_MAGIC_B1
        and compressed[2] == _LZ4F_MAGIC_B2
        and compressed[3] == _LZ4F_MAGIC_B3
    ):
        return Lz4TextFraming.FRAME
    return Lz4TextFraming.RAW_BLOCK


def lz4_frame_declared_content_size(
    compressed: Span[UInt8, _],
) -> Optional[Int]:
    """Read the LZ4 frame header's Content Size field, when the producer wrote
    one. `None` when absent, so the caller falls back to cap-and-grow.

    A decoder SHOULD NOT have to guess an output size for a self-describing
    container, and for the frames that carry the field it no longer does: one
    allocation, one decode, no grow loop, no ceiling to trip over.

    LZ4 Frame header layout (lz4 Frame Format spec v1.6.x):

        off 0   4 B  magic 0x184D2204 (LE)
        off 4   1 B  FLG   bits 7-6 version (MUST be 01), bit 3 = C.Size
        off 5   1 B  BD    block-max-size descriptor
        off 6   8 B  Content Size (LE u64) — PRESENT ONLY IF FLG bit 3
        ...     4 B  DictID (LE u32)       — present only if FLG bit 0
        ...     1 B  HC (header checksum)

    ⚠ THE FIELD IS OPTIONAL AND IS USUALLY ABSENT. A streaming producer
    cannot know the total ahead of the stream, so it omits it; `lz4(1)` only
    writes it with `--content-size` (a frame with FLG = 0x64 has bit 3 clear:
    no content size). So this is an OPTIMISATION for the frames that carry it and
    must never become the only path, which is why it returns `Optional` and
    the caller's grow loop stays live.
    """
    if len(compressed) < 15:
        # 4 magic + FLG + BD + 8 content size + HC = 15 bytes minimum for a
        # header that could carry the field at all.
        return None
    if lz4_text_framing_of(compressed) != Lz4TextFraming.FRAME:
        return None
    var flg = Int(compressed[4])
    # Version bits (7-6) must read 01; anything else is not a frame this
    # spec revision describes, so do not interpret its bytes as a length.
    if (flg & 0xC0) != 0x40:
        return None
    # Bit 3 = Content Size present.
    if (flg & 0x08) == 0:
        return None
    var size = 0
    for i in range(8):
        size |= Int(compressed[6 + i]) << (8 * i)
    if size <= 0:
        # 0 is a legal declaration for an empty payload but is uninformative,
        # and a >= 2^63 declaration lands negative — neither is a usable
        # allocation hint. Fall back to cap-and-grow rather than trust it.
        return None
    return Optional[Int](size)



@always_inline
def _read_be_u32(p: Span[UInt8, _], offset: Int) -> Int:
    """Read a 4-byte big-endian unsigned int at `p[offset]`.

    Big-endian because the Hadoop framing is Java-authored (`DataOutputStream`
    network byte order), NOT because Parquet is — every other length in the
    format is little-endian. Returns an `Int` (63-bit), so a 0xFFFFFFFF field
    lands as a large positive value the callers' bounds checks then reject,
    never as a negative that would be reinterpreted as an unbounded size_t at
    the FFI boundary.
    """
    return (
        (Int(p[offset]) << 24)
        | (Int(p[offset + 1]) << 16)
        | (Int(p[offset + 2]) << 8)
        | Int(p[offset + 3])
    )


def _decompress_lz4_deprecated[
    o_out: MutOrigin
](input: Span[UInt8, _], output: Span[UInt8, o_out]) raises -> Int:
    """Decode a DEPRECATED-`LZ4` (codec id 5) page. See the block comment above.

    `len(output)` is the page's `uncompressed_page_size` from the page header,
    which is what makes arm 1's exact-length check decisive.
    """
    var input_len = len(input)
    var output_len = len(output)
    # --- Arm 1: Hadoop block framing (parquet-mr / Hive / Spark) -------------
    # One `[BE u32 uncompressed][BE u32 compressed][raw block]` group per
    # compressor buffer, so a page larger than the buffer holds several, back
    # to back. Accepted only if every group decodes to exactly its declared
    # length and the groups consume the whole input; anything else falls
    # through rather than return a partially-filled page.
    if input_len >= _LZ4_HADOOP_PREFIX_LEN:
        var in_pos = 0
        var out_pos = 0
        var ok = True
        while ok and input_len - in_pos >= _LZ4_HADOOP_PREFIX_LEN:
            var declared_uncompressed = _read_be_u32(input, in_pos)
            var declared_compressed = _read_be_u32(input, in_pos + 4)
            var block_start = in_pos + _LZ4_HADOOP_PREFIX_LEN
            if (
                declared_compressed <= 0
                or declared_uncompressed <= 0
                or declared_compressed > input_len - block_start
                or declared_uncompressed > output_len - out_pos
            ):
                ok = False
                break
            try:
                var written = lz4_decompress_into(
                    output[out_pos : out_pos + declared_uncompressed],
                    input[block_start : block_start + declared_compressed],
                )
                # EXACT match required. A short decode means the length
                # fields were coincidence, not framing.
                if written != declared_uncompressed:
                    ok = False
                    break
            except:
                ok = False
                break
            in_pos = block_start + declared_compressed
            out_pos += declared_uncompressed
        if ok and in_pos == input_len:
            return out_pos

    # --- Arm 2: LZ4 Frame (arrow-cpp < 0.17), gated on the frame magic -------
    if lz4_text_framing_of(input) == Lz4TextFraming.FRAME:
        return _lz4_frame_decompress_into(output, input)

    # --- Arm 3: bare LZ4 raw block -------------------------------------------
    try:
        return lz4_decompress_into(output, input)
    except e:
        raise Error(
            "parquet: page with the DEPRECATED LZ4 codec (id 5) decoded under"
            " NONE of its three known framings (Hadoop block-prefixed, LZ4"
            " frame, bare LZ4 raw block). Codec id 5 is ambiguous by"
            " construction — the format replaced it with LZ4_RAW (id 7) for"
            " exactly this reason. input_len="
            + String(input_len)
            + ", uncompressed_page_size="
            + String(output_len)
            + ". Underlying: "
            + String(e)
        )


def decompress_lz4_frame[
    o_out: MutOrigin
](input: Span[UInt8, _], output: Span[UInt8, o_out]) raises -> Int:
    """LZ4 FRAME-format decompression via liblz4 `LZ4F_decompress`.

    Distinct from LZ4_RAW (raw block / `LZ4_decompress_safe`): this decodes
    the interoperable LZ4 Frame Format (magic 0x184D2204), which is what
    Kafka's `lz4` producer compression emits (KIP-57). Concatenated frames
    decode in full, as `lz4 -d` decodes them; input that ends inside a frame,
    or bytes after a frame that are not one, raise. `len(output)` is the
    output-buffer capacity; a caller that does not know the decoded size
    grows + retries on the "LZ4F dst buffer too small" error. Returns the
    decompressed byte count.
    """
    return _lz4_frame_decompress_into(output, input)


def compress_lz4_frame[
    o_out: MutOrigin
](input: Span[UInt8, _], output: Span[UInt8, o_out]) raises -> Int:
    """LZ4 FRAME-format compression (one-shot) via liblz4 `LZ4F_compressFrame`.

    Produces a complete interoperable LZ4 frame (the format Kafka's `lz4`
    producer emits) into `output`, which must hold at least
    `lz4_frame_compress_bound(len(input))` bytes. The decode counterpart is
    `decompress_lz4_frame`. Returns the frame byte count.
    """
    return _lz4_frame_compress_into(output, input)


def lz4_frame_compress_bound(input_len: Int) raises -> Int:
    """Max LZ4-frame compressed size for `input_len` bytes."""
    return _lz4_frame_compress_bound(input_len)
