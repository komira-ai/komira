# =============================================================================
# Parquet page compression: codec dispatch over snappy, zstd, lz4, zlib, brotli
# =============================================================================
#
# Each codec is reached through a per-codec FFI shim: snappy through the
# statically linked snappy C API (snappy_mojo/snappy_ffi.mojo), zstd, LZ4
# frame and brotli through libraries opened at run time
# (zstd_mojo/zstd_ffi.mojo, lz4_mojo/lz4_ffi.mojo, brotli_mojo/brotli_ffi.mojo),
# and LZ4 raw block and zlib through the komira_lz4 and komira_zlib packages.
# Each shim keeps its own process-lifetime library handle.
#
# Contract:
#   - The Mojo side owns the input and output byte buffers.
#   - The C libraries never retain a pointer across a call: every call is
#     stateless on the byte regions.
#   - The Mojo side frees both buffers; the C library only reads the input,
#     writes the output and returns a length or a status.
#   - Buffer pointers are cast to an untracked origin only at the FFI call:
#     the C ABI has no origins, the call is synchronous, and the caller
#     keeps the buffer alive across it.
# =============================================================================
# Compression / Decompression — Parquet page-level codec dispatch
# =============================================================================
#
# Supports:
#   - UNCOMPRESSED: passthrough memcpy
#   - SNAPPY:       the snappy C API (snappy_ffi.mojo)
#   - ZSTD:         libzstd (zstd_ffi.mojo)
#   - LZ4_RAW:      liblz4 raw block (codec id 7) — read + write
#   - LZ4:          liblz4, the DEPRECATED codec id 5 — READ ONLY, with
#                   framing detection across its three in-the-wild layouts.
#                   Distinct codec from LZ4_RAW; never written.
#   - GZIP:         libz (window_bits=15+32 for gzip/zlib auto-detect)
#   - BROTLI:       libbrotlidec — read only.
# =============================================================================

from std.memory import unsafe_memcpy

from .snappy_mojo.snappy_ffi import (
    snappy_decompress as _snappy_decompress,
    snappy_compress as _snappy_compress,
    snappy_uncompressed_length as _snappy_uncompressed_length_view,
    snappy_max_compressed_length as _snappy_max_compressed_length,
)
from .zstd_mojo.zstd_ffi import (
    zstd_decompress_ffi,
    zstd_compress_ffi,
    zstd_compress_bound_ffi,
)
# zlib/GZIP codec: the libz FFI shim is its own zero-dependency library, so a
# consumer that needs only zlib framing does not depend on Parquet.
from komira_zlib.zlib_ffi import (
    zlib_inflate_ffi,
    zlib_deflate_ffi,
    zlib_compress_bound_ffi,
)
# LZ4 RAW-BLOCK codec: a shared leaf library, so the Parquet page codec and
# other LZ4 raw-block users depend on one copy and not on each other.
from komira_core_ffi.lz4_codec import (
    lz4_decompress_ffi,
    lz4_compress_ffi,
    lz4_compress_bound_ffi,
)
# LZ4 FRAME codec (the interoperable framing Kafka and Arrow IPC use): a
# distinct codec from the raw block, kept in this package.
from .lz4_mojo.lz4_ffi import (
    lz4_frame_decompress_ffi,
    lz4_frame_compress_ffi,
    lz4_frame_compress_bound_ffi,
)
from .brotli_mojo.brotli_ffi import brotli_decompress_ffi

from komira_core.collections.byte_view import ByteView

from .types import CompressionCodec


# =============================================================================
# Constants — zlib framing selectors used by gzip codec dispatch
# =============================================================================

# windowBits = 15 (max) + 32 (auto-detect gzip vs zlib vs raw deflate).
# Load-bearing for Parquet interop because parquet-mr / DuckDB / pyarrow /
# Spark all disagree on which framing they emit for the "GZIP" codec id.
comptime _Z_WBITS_AUTO_INFLATE: Int32 = 15 + 32
# windowBits = 31 (15 + 16): gzip wrapper for compression. Every Parquet
# reader accepts gzip framing for the GZIP codec, and more readers accept it
# than zlib framing.
comptime _Z_WBITS_GZIP_DEFLATE: Int32 = 15 + 16
# Default deflate level (libz default is 6 — balances compression vs throughput).
comptime _Z_LEVEL_DEFAULT: Int32 = 6
# Default zstd compression level.
comptime _ZSTD_LEVEL_DEFAULT: Int32 = 3


# =============================================================================
# Public API
# =============================================================================

# SAFETY: All functions in this module take UnsafePointer[UInt8] parameters
# because they operate on raw byte buffers for binary codec operations
# (Snappy, GZIP, etc.). Compression/decompression algorithms require direct
# byte-level access with pointer arithmetic. Cannot use smart pointers
# because the callers (Parquet page decoders) work with raw file data.


def decompress[
    _in_mut: Bool, o_in: Origin[mut=_in_mut], //,
    o_out: Origin[mut=True],
](
    codec: CompressionCodec,
    input: UnsafePointer[UInt8, o_in],
    input_len: Int,
    output: UnsafePointer[UInt8, o_out],
    output_len: Int,
) raises -> Int:
    """Decompress data. Returns number of bytes written to output.

    Dispatches to the appropriate codec via per-codec FFI shim:
      - UNCOMPRESSED: memcpy passthrough
      - SNAPPY: libsnappy
      - ZSTD:   libzstd
      - LZ4_RAW: liblz4
      - GZIP:   libz (auto-detect gzip / zlib / raw deflate framing)

    Args:
        codec: The Parquet compression codec.
        input: Pointer to compressed input data.
        input_len: Number of compressed bytes.
        output: Pre-allocated output buffer.
        output_len: Capacity of the output buffer (must >= uncompressed size).

    Returns:
        Number of bytes written to output.

    Raises:
        Error if codec is unsupported or decompression fails.
    """
    # Refuse a negative length before any codec sees it.
    #
    # Every codec shim converts these to unsigned before the FFI call:
    # `UInt64(input_len)` / `Int64(output_cap)` into a `size_t` out-param
    # (the snappy shim, and the same shape in the zstd / lz4 / zlib /
    # brotli shims). A NEGATIVE length arriving from page-header
    # arithmetic therefore reaches libsnappy/libzstd as ~2^64, i.e. the
    # library believes it has an unbounded destination and writes
    # codec-expanded attacker data past the end of the real allocation.
    #
    # Checked ONCE at the dispatch rather than in five callers: this runs
    # per PAGE, is off every per-row path, and closes the codec-side half
    # of the data page v2 level-length and uncompressed_page_size sites in one
    # place. (An honestly-large length is NOT the hazard — the codecs all
    # respect a destination capacity they are handed; only the sign
    # reinterpretation is.)
    if input_len < 0 or output_len < 0:
        raise Error(
            "parquet: corrupt page: negative decompression length"
            " (input_len="
            + String(input_len)
            + ", output_len="
            + String(output_len)
            + ") — refusing to call the codec, which would reinterpret it"
            " as an unbounded size_t"
        )
    if codec == CompressionCodec.UNCOMPRESSED:
        return _decompress_uncompressed(input, input_len, output, output_len)
    elif codec == CompressionCodec.SNAPPY:
        return _decompress_snappy(input, input_len, output, output_len)
    elif codec == CompressionCodec.ZSTD:
        return _decompress_zstd(input, input_len, output, output_len)
    elif codec == CompressionCodec.LZ4_RAW:
        return _decompress_lz4_raw(input, input_len, output, output_len)
    elif codec == CompressionCodec.LZ4:
        # Codec id 5 is the
        # DEPRECATED `LZ4`, a DIFFERENT codec from `LZ4_RAW` (id 7). Routing
        # it to the id-7 decoder would be the silent mis-decode this whole
        # arm exists to prevent — see `_decompress_lz4_deprecated` for the
        # framing-detection contract.
        return _decompress_lz4_deprecated(input, input_len, output, output_len)
    elif codec == CompressionCodec.GZIP:
        return _decompress_gzip(input, input_len, output, output_len)
    elif codec == CompressionCodec.BROTLI:
        # One-shot decode via libbrotlidec.
        # `output_len` is the page's
        # uncompressed size; it's passed as the in/out decoded-size capacity.
        return _decompress_brotli(input, input_len, output, output_len)
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
    _in_mut: Bool, o_in: Origin[mut=_in_mut], //,
    o_out: Origin[mut=True],
](
    codec: CompressionCodec,
    input: UnsafePointer[UInt8, o_in],
    input_len: Int,
    output: UnsafePointer[UInt8, o_out],
    output_len: Int,
) raises -> Int:
    """Compress data. Returns number of bytes written to output."""
    if codec == CompressionCodec.UNCOMPRESSED:
        return _decompress_uncompressed(input, input_len, output, output_len)
    elif codec == CompressionCodec.SNAPPY:
        return _compress_snappy(input, input_len, output, output_len)
    elif codec == CompressionCodec.ZSTD:
        return _compress_zstd(input, input_len, output, output_len)
    elif codec == CompressionCodec.LZ4_RAW:
        return _compress_lz4_raw(input, input_len, output, output_len)
    elif codec == CompressionCodec.GZIP:
        return _compress_gzip(input, input_len, output, output_len)
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
            return zstd_compress_bound_ffi(input_len)
        except:
            return input_len + input_len // 10 + 64
    elif codec == CompressionCodec.LZ4_RAW:
        try:
            return lz4_compress_bound_ffi(input_len)
        except:
            return input_len + input_len // 10 + 64
    elif codec == CompressionCodec.GZIP:
        try:
            return zlib_compress_bound_ffi(input_len, _Z_WBITS_GZIP_DEFLATE)
        except:
            return input_len + input_len // 10 + 64
    else:
        return input_len + input_len // 10 + 64


# =============================================================================
# UNCOMPRESSED — passthrough memcpy
# =============================================================================


@always_inline
def _decompress_uncompressed[
    _in_mut: Bool, o_in: Origin[mut=_in_mut], //,
    o_out: Origin[mut=True],
](
    input: UnsafePointer[UInt8, o_in],
    input_len: Int,
    output: UnsafePointer[UInt8, o_out],
    output_len: Int,
) raises -> Int:
    """Passthrough: copy input to output. Returns input_len."""
    if input_len > output_len:
        raise Error(
            "output buffer too small: need "
            + String(input_len)
            + " but have "
            + String(output_len)
        )
    unsafe_memcpy(dest=output, src=input, count=input_len)
    return input_len


# =============================================================================
# SNAPPY — libsnappy FFI via snappy_mojo.snappy_ffi
# =============================================================================


def snappy_max_compressed_length(input_len: Int) -> Int:
    """Maximum compressed size for Snappy.

    Snappy guarantees compressed output is at most 32 + input_len + input_len/6.
    Pure arithmetic — delegates to the snappy_ffi helper which computes
    locally (no dlopen needed for an arithmetic function).
    """
    return _snappy_max_compressed_length(input_len)


def _decompress_snappy[
    _in_mut: Bool, o_in: Origin[mut=_in_mut], //,
    o_out: Origin[mut=True],
](
    input: UnsafePointer[UInt8, o_in],
    input_len: Int,
    output: UnsafePointer[UInt8, o_out],
    output_len: Int,
) raises -> Int:
    """Snappy decompression via libsnappy.

    Constructs ByteView wrappers at the FFI boundary and delegates to the
    snappy_ffi shim. The shim casts to an untracked origin at the
    FFI call site only.
    """
    # FFI boundary: cast the caller origins to an untracked origin to build
    # the ByteView wrappers the snappy_ffi shim takes (ByteView[_]).
    var input_view = ByteView[MutUntrackedOrigin](
        input.unsafe_mut_cast[True]().unsafe_origin_cast[MutUntrackedOrigin](), input_len
    )
    var output_view = ByteView[MutUntrackedOrigin](
        output.unsafe_origin_cast[MutUntrackedOrigin](), output_len
    )
    return _snappy_decompress(input_view, output_view)


def _compress_snappy[
    _in_mut: Bool, o_in: Origin[mut=_in_mut], //,
    o_out: Origin[mut=True],
](
    input: UnsafePointer[UInt8, o_in],
    input_len: Int,
    output: UnsafePointer[UInt8, o_out],
    output_len: Int,
) raises -> Int:
    """Snappy compression via libsnappy."""
    # FFI-BOUNDARY: see `_decompress_snappy` for the cast-at-boundary rationale.
    var input_view = ByteView[MutUntrackedOrigin](
        input.unsafe_mut_cast[True]().unsafe_origin_cast[MutUntrackedOrigin](), input_len
    )
    var output_view = ByteView[MutUntrackedOrigin](
        output.unsafe_origin_cast[MutUntrackedOrigin](), output_len
    )
    return _snappy_compress(input_view, output_view)


def snappy_uncompressed_length[
    _in_mut: Bool, o_in: Origin[mut=_in_mut], //,
](
    input: UnsafePointer[UInt8, o_in],
    input_len: Int,
) raises -> Int:
    """Read the uncompressed length from a Snappy preamble via libsnappy.

    Delegates to `snappy_uncompressed_length` in libsnappy via the snappy_ffi
    shim — libsnappy's implementation is authoritative and handles all
    edge cases.
    """
    if input_len == 0:
        raise Error("snappy: empty input")
    # FFI boundary: cast the caller origin to an untracked origin for the
    # ByteView the snappy_ffi shim takes.
    var input_view = ByteView[MutUntrackedOrigin](
        input.unsafe_mut_cast[True]().unsafe_origin_cast[MutUntrackedOrigin](), input_len
    )
    return _snappy_uncompressed_length_view(input_view)


# =============================================================================
# ZSTD — libzstd FFI via zstd_mojo.zstd_ffi
# =============================================================================


def _decompress_zstd[
    _in_mut: Bool, o_in: Origin[mut=_in_mut], //,
    o_out: Origin[mut=True],
](
    input: UnsafePointer[UInt8, o_in],
    input_len: Int,
    output: UnsafePointer[UInt8, o_out],
    output_len: Int,
) raises -> Int:
    """ZSTD decompression via libzstd's `ZSTD_decompress`."""
    return zstd_decompress_ffi(output, output_len, input, input_len)


def _compress_zstd[
    _in_mut: Bool, o_in: Origin[mut=_in_mut], //,
    o_out: Origin[mut=True],
](
    input: UnsafePointer[UInt8, o_in],
    input_len: Int,
    output: UnsafePointer[UInt8, o_out],
    output_len: Int,
) raises -> Int:
    """ZSTD compression at level 3 via libzstd `ZSTD_compress`."""
    return zstd_compress_ffi(
        output, output_len, input, input_len, _ZSTD_LEVEL_DEFAULT
    )


# =============================================================================
# LZ4_RAW — liblz4 raw block via komira_core_ffi.lz4_codec
# =============================================================================


def _decompress_lz4_raw[
    _in_mut: Bool, o_in: Origin[mut=_in_mut], //,
    o_out: Origin[mut=True],
](
    input: UnsafePointer[UInt8, o_in],
    input_len: Int,
    output: UnsafePointer[UInt8, o_out],
    output_len: Int,
) raises -> Int:
    """LZ4 raw block decompression via liblz4 `LZ4_decompress_safe`."""
    return lz4_decompress_ffi(output, output_len, input, input_len)


def _compress_lz4_raw[
    _in_mut: Bool, o_in: Origin[mut=_in_mut], //,
    o_out: Origin[mut=True],
](
    input: UnsafePointer[UInt8, o_in],
    input_len: Int,
    output: UnsafePointer[UInt8, o_out],
    output_len: Int,
) raises -> Int:
    """LZ4 raw block compression via liblz4 `LZ4_compress_default`."""
    return lz4_compress_ffi(output, output_len, input, input_len)


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
#       `BlockCompressorStream` + `Lz4Codec`. An 8-byte big-endian prefix
#       (uncompressed length, then compressed length) ahead of an LZ4 raw
#       block. This is the dominant on-disk form.
#   (b) LZ4 FRAME — Arrow C++ before 0.17 wrote a complete LZ4 frame
#       (magic 0x184D2204) under id 5.
#   (c) bare LZ4 raw block — some writers emitted exactly what id 7 later
#       standardised.
#
# Detection is by STRUCTURE, in decreasing order of evidence, and every arm
# must SUCCEED-OR-REJECT rather than guess:
#
#   1. Hadoop: requires both length fields to be self-consistent with the
#      buffer AND the decode to return EXACTLY the declared uncompressed
#      length. Mirrors arrow-cpp `Lz4HadoopCodec::TryDecompressHadoop`.
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
# WRITE SIDE: we never emit codec id 5, and must not. `compress()` has no
# LZ4 arm on purpose — a writer that picks the ambiguous id re-creates the
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
#     length, no checksum. It is what this module's own `_compress_lz4_raw`
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
# producers write frames, and `_compress_lz4_raw` writes raw blocks.
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
def _read_be_u32[
    _m: Bool, o: Origin[mut=_m], //
](p: UnsafePointer[UInt8, o], offset: Int) -> Int:
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
    _in_mut: Bool, o_in: Origin[mut=_in_mut], //,
    o_out: Origin[mut=True],
](
    input: UnsafePointer[UInt8, o_in],
    input_len: Int,
    output: UnsafePointer[UInt8, o_out],
    output_len: Int,
) raises -> Int:
    """Decode a DEPRECATED-`LZ4` (codec id 5) page. See the block comment above.

    `output_len` is the page's `uncompressed_page_size` from the page header,
    which is what makes arm 1's exact-length check decisive.
    """
    # --- Arm 1: Hadoop block framing (parquet-mr / Hive / Spark) -------------
    if input_len >= _LZ4_HADOOP_PREFIX_LEN:
        var declared_uncompressed = _read_be_u32(input, 0)
        var declared_compressed = _read_be_u32(input, 4)
        if (
            declared_compressed > 0
            and declared_uncompressed > 0
            and declared_compressed <= input_len - _LZ4_HADOOP_PREFIX_LEN
            and declared_uncompressed <= output_len
        ):
            try:
                var written = lz4_decompress_ffi(
                    output,
                    output_len,
                    input + _LZ4_HADOOP_PREFIX_LEN,
                    declared_compressed,
                )
                # EXACT match required. A short/long decode means the two
                # length fields were coincidence, not framing — fall through
                # rather than return a partially-filled page.
                if written == declared_uncompressed:
                    return written
            except:
                pass

    # --- Arm 2: LZ4 Frame (arrow-cpp < 0.17), gated on the frame magic -------
    if (
        input_len >= 4
        and input[0] == _LZ4F_MAGIC_B0
        and input[1] == _LZ4F_MAGIC_B1
        and input[2] == _LZ4F_MAGIC_B2
        and input[3] == _LZ4F_MAGIC_B3
    ):
        return lz4_frame_decompress_ffi(output, output_len, input, input_len)

    # --- Arm 3: bare LZ4 raw block -------------------------------------------
    try:
        return lz4_decompress_ffi(output, output_len, input, input_len)
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
    _in_mut: Bool, o_in: Origin[mut=_in_mut], //,
    o_out: Origin[mut=True],
](
    input: UnsafePointer[UInt8, o_in],
    input_len: Int,
    output: UnsafePointer[UInt8, o_out],
    output_len: Int,
) raises -> Int:
    """LZ4 FRAME-format decompression via liblz4 `LZ4F_decompress`.

    Distinct from `_decompress_lz4_raw` (raw block / `LZ4_decompress_safe`):
    this decodes the interoperable LZ4 Frame Format (magic 0x184D2204), which
    is what Kafka's `lz4` producer compression emits (KIP-57). `output_len`
    is the output-buffer capacity; the caller grows + retries on the
    "LZ4F dst buffer too small" error. Returns the decompressed byte count.

    SAFETY: delegates straight to the lz4_ffi frame wrapper, which owns the
    decompression context lifecycle and the per-call size counters.
    """
    return lz4_frame_decompress_ffi(output, output_len, input, input_len)


def compress_lz4_frame[
    _in_mut: Bool, o_in: Origin[mut=_in_mut], //,
    o_out: Origin[mut=True],
](
    input: UnsafePointer[UInt8, o_in],
    input_len: Int,
    output: UnsafePointer[UInt8, o_out],
    output_len: Int,
) raises -> Int:
    """LZ4 FRAME-format compression (one-shot) via liblz4 `LZ4F_compressFrame`.

    Produces a complete interoperable LZ4 frame (the format Kafka's `lz4`
    producer emits). The decode counterpart is `decompress_lz4_frame`.
    Returns the frame byte count.

    SAFETY: delegates straight to the lz4_ffi stateless one-shot wrapper.
    """
    return lz4_frame_compress_ffi(output, output_len, input, input_len)


def lz4_frame_compress_bound(input_len: Int) raises -> Int:
    """Max LZ4-frame compressed size for `input_len` bytes."""
    return lz4_frame_compress_bound_ffi(input_len)


# =============================================================================
# BROTLI — libbrotlidec FFI via brotli_mojo.brotli_ffi (decompress only)
# =============================================================================


def _decompress_brotli[
    _in_mut: Bool, o_in: Origin[mut=_in_mut], //,
    o_out: Origin[mut=True],
](
    input: UnsafePointer[UInt8, o_in],
    input_len: Int,
    output: UnsafePointer[UInt8, o_out],
    output_len: Int,
) raises -> Int:
    """Brotli decompression via libbrotlidec `BrotliDecoderDecompress`.

    `output_len` is the page's uncompressed size, passed as the in/out
    decoded-size capacity; the FFI shim returns the actual decoded length.
    Brotli is decode-only here (this package never writes it).
    """
    return brotli_decompress_ffi(output, output_len, input, input_len)


# =============================================================================
# GZIP / zlib — libz via komira_zlib.zlib_ffi
# =============================================================================
#
# Parquet's "GZIP" codec can use ANY of gzip framing, zlib framing, or raw
# deflate depending on the writer (parquet-mr, DuckDB, pyarrow, etc. all
# disagree). We pass `window_bits = 15 + 32` to libz's inflateInit2_ which
# auto-detects all three at decode time. For compression we emit gzip
# framing (windowBits = 31) since all Parquet readers accept it.
# =============================================================================


def _decompress_gzip[
    _in_mut: Bool, o_in: Origin[mut=_in_mut], //,
    o_out: Origin[mut=True],
](
    input: UnsafePointer[UInt8, o_in],
    input_len: Int,
    output: UnsafePointer[UInt8, o_out],
    output_len: Int,
) raises -> Int:
    """GZIP/zlib/raw-deflate decompression via libz `inflate` with
    auto-detect window_bits (15 + 32)."""
    return zlib_inflate_ffi(
        output, output_len, input, input_len, _Z_WBITS_AUTO_INFLATE
    )


def _compress_gzip[
    _in_mut: Bool, o_in: Origin[mut=_in_mut], //,
    o_out: Origin[mut=True],
](
    input: UnsafePointer[UInt8, o_in],
    input_len: Int,
    output: UnsafePointer[UInt8, o_out],
    output_len: Int,
) raises -> Int:
    """GZIP compression at level 6 via libz `deflateInit2_` + `deflate(Z_FINISH)`
    (gzip framing, windowBits=15+16=31)."""
    return zlib_deflate_ffi(
        output, output_len, input, input_len,
        _Z_LEVEL_DEFAULT, _Z_WBITS_GZIP_DEFLATE,
    )
