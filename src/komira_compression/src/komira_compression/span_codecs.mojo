# =============================================================================
# Span codec conformers — the `Compression` conformers that need no pointer
# =============================================================================
#
# The conformers whose every method is Span in, List out: they call this
# package's snappy_block.mojo and the komira_zlib / komira_lz4 Span APIs, and
# hold no pointer of their own.
#   - `Snappy`                     — snappy, linked into the binary.
#   - `Gzip[level: Int = 6]`       — libz via komira_zlib (auto-detect read).
#   - `Lz4Raw`                     — liblz4 raw block via komira_lz4.
# SCAFFOLD — trait shape lands; bodies raise clear errors:
#   - `Lzo`                        — Parquet codec id 3.
#   - `Brotli[quality: Int = 11]`  — Parquet codec id 4.
#   - `Zlib[level: Int = 6]`       — Parquet codec id 8.
#
# compression_codecs.mojo holds the conformers with pointer-taking methods
# (Uncompressed, Zstd, Lz4Frame and the context handle) and re-exports these,
# so `from komira_compression.compression_codecs import Snappy` still works.
# =============================================================================

from komira_compression.compression import Compression
from komira_compression.snappy_block import (
    snappy_compress_into,
    snappy_max_compressed_length,
    snappy_uncompress_into,
    snappy_uncompressed_length,
)
from komira_lz4.codec import (
    lz4_compress_bound,
    lz4_compress_into,
    lz4_decompress_into,
)
from komira_zlib import (
    ZLIB_WINDOW_BITS_AUTO,
    ZLIB_WINDOW_BITS_ZLIB,
    zlib_compress_bound,
    zlib_crc32,
    zlib_deflate_into,
    zlib_inflate_into,
)


# =============================================================================
# Snappy — the snappy C API, statically linked (Parquet codec id 1)
# =============================================================================
#
# Through snappy_block.mojo, the one module that declares the snappy symbols.
# =============================================================================


@fieldwise_init
struct Snappy(Compression):
    """The snappy compression codec, calling the snappy C API. Parquet codec
    id 1. Default for Parquet (matches DuckDB).

    The snappy library is statically linked into every binary that uses
    this package, so no shared library is needed at run time. A native Mojo
    Snappy decoder lives in `komira_parquet_codec` and is used on the Parquet
    path; this conformer calls the C library through `snappy_block`.
    """

    var _reserved: Bool

    comptime PARQUET_CODEC_ID: Int8 = 1
    comptime FILE_EXTENSION: StaticString = ""
    comptime NAME: StaticString = "snappy"

    def __init__(out self):
        self._reserved = False

    @staticmethod
    def compress(input: Span[UInt8, _]) raises -> List[UInt8]:
        var n = len(input)
        var max_out = snappy_max_compressed_length(n)
        var out = List[UInt8](capacity=max_out)
        # SAFETY: the `max_out` bytes are the List's reserved capacity; snappy
        # writes the block into them and the List is cut to what it wrote.
        out.resize(unsafe_uninit_length=max_out)
        var written = snappy_compress_into(Span(out), input)
        out.resize(unsafe_uninit_length=written)
        return out^

    @staticmethod
    def decompress(
        input: Span[UInt8, _], expected_size: Int
    ) raises -> List[UInt8]:
        var n = len(input)
        if n == 0:
            raise Error("Snappy.decompress: empty input")

        # Compute or accept output size.
        var out_len: Int
        if expected_size > 0:
            out_len = expected_size
        else:
            # Ask snappy for the declared uncompressed length.
            try:
                out_len = snappy_uncompressed_length(input)
            except e:
                raise Error("Snappy.decompress: " + String(e))

        var out = List[UInt8](capacity=out_len)
        # SAFETY: the `out_len` bytes are the List's reserved capacity; snappy
        # writes at most that many and the List is cut to what it wrote.
        out.resize(unsafe_uninit_length=out_len)
        var written: Int
        try:
            written = snappy_uncompress_into(Span(out), input)
        except e:
            raise Error("Snappy.decompress: " + String(e))
        out.resize(unsafe_uninit_length=written)
        return out^


# =============================================================================
# Gzip[level] — libz through komira_zlib (Parquet codec id 2)
# =============================================================================
#
# Write: one zlib-framed deflate stream (`zlib_deflate_into` with
# `ZLIB_WINDOW_BITS_ZLIB`, memLevel 8, default strategy: the same stream libz's
# `compress2` writes) — accepted by all major Parquet readers with auto-detect.
# Read: `zlib_inflate_into` with `ZLIB_WINDOW_BITS_AUTO` (15 + 32), which
# auto-detects gzip / zlib framing (load-bearing for interop with pyarrow /
# parquet-mr / DuckDB / Spark).
#
# ⚠ ZLIB FRAMING IS NOT GZIP FILE FRAMING, and a `.gz` FILE must be the latter.
# The zlib stream is RFC 1950 (2-byte header + deflate + adler32); a gzip FILE
# is RFC 1952 (10-byte header starting `1f 8b` + raw deflate + crc32 + isize).
# Inside a Parquet page the distinction is invisible — every major reader
# auto-detects, which is why the write path above is fine there and has been for
# its whole life. On DISK it is the difference between a file `gunzip`, `zcat`
# and DuckDB can open and one they refuse. `compress_gzip_file` below is the
# file-framing entry; use it for any whole-file `.gz` sink.
#
# libz itself is loaded, once per process, by komira_zlib; this file holds no
# libz handle and declares no libz symbol.
# =============================================================================


@fieldwise_init
struct Gzip[level: Int = 6](Compression):
    """The libz compression codec (through komira_zlib). Parquet codec id 2.

    `level` is a comptime parameter (1-9; default 6 matches DuckDB /
    pyarrow / parquet-mr).

    Write path: `compress` (zlib framing) — for a Parquet PAGE.
    File path:  `compress_gzip_file` (RFC 1952 gzip framing) — for a `.gz` FILE.
    Both take an input of any length, over 4 GiB included (komira_zlib feeds
    libz in 32-bit slices, as `compress2` did; ISIZE is the length mod 2^32).
    Read path: `decompress`, auto-detecting gzip / zlib framing, so both
    framings read back here. The stream must end inside the input and decode
    to at most `expected_size` bytes; a truncated, oversized or corrupt stream
    is refused.
    """

    var _reserved: Bool

    comptime PARQUET_CODEC_ID: Int8 = 2
    comptime FILE_EXTENSION: StaticString = ".gz"
    comptime NAME: StaticString = "gzip"

    def __init__(out self):
        self._reserved = False

    @staticmethod
    def _deflate_zlib(input: Span[UInt8, _], lead: Int) raises -> List[UInt8]:
        """`[lead bytes, uninitialised][zlib stream of input]`, with room for 8
        more bytes after the stream (capacity only)."""
        var n = len(input)
        var bound = zlib_compress_bound(n, ZLIB_WINDOW_BITS_ZLIB)
        var out = List[UInt8](capacity=lead + bound + 8)
        out.resize(unsafe_uninit_length=lead + bound)
        var zlen = zlib_deflate_into(
            Span(out)[lead : lead + bound],
            input,
            Int32(Self.level),
            ZLIB_WINDOW_BITS_ZLIB,
        )
        out.resize(lead + zlen, UInt8(0))
        return out^

    @staticmethod
    def compress(input: Span[UInt8, _]) raises -> List[UInt8]:
        # komira_zlib refuses a level libz does not take (deflateInit2_'s
        # Z_STREAM_ERROR): `Gzip[10]` raises here.
        try:
            return Self._deflate_zlib(input, 0)
        except e:
            raise Error("Gzip.compress: " + String(e))

    @staticmethod
    def compress_gzip_file(input: Span[UInt8, _]) raises -> List[UInt8]:
        """Compress to a GZIP FILE (RFC 1952) — the framing a `.gz` file needs.

        `compress` above emits RFC 1950 zlib framing, which is right for a
        Parquet page and WRONG for a file: a `.gz` written that way starts `78 …`
        instead of `1f 8b`, and `gunzip` / `zcat` / DuckDB all refuse it. Our own
        readers auto-detect, so a self round-trip test cannot see the difference
        — only another tool can.

        ZERO-COPY REFRAME. A zlib stream is `[2-byte header][deflate][4-byte
        adler32]`; a gzip file is `[10-byte header][the SAME deflate][4-byte
        crc32][4-byte isize]`. So the zlib stream is written at offset 8, the
        10-byte gzip header then overwrites exactly the two zlib header bytes it
        left at [8,10), and the 8-byte trailer overwrites the 4 adler bytes in
        place. The deflate payload — all of it — is never moved.
        """
        var n = len(input)
        var out: List[UInt8]
        try:
            # 8 leading bytes, so the deflate body lands at 10.
            out = Self._deflate_zlib(input, 8)
        except e:
            raise Error("Gzip.compress_gzip_file: " + String(e))
        var crc = zlib_crc32(input)
        # A zlib stream is at least 8 bytes (the 2-byte header, the 2-byte
        # empty final block of an empty input, the 4-byte adler32), so the
        # header and trailer below overwrite bytes the stream wrote.
        var zlen = len(out) - 8

        # RFC 1952 §2.3 header: magic, CM=8 (deflate), FLG=0 (no name/extra),
        # MTIME=0 (no timestamp — keeps the output BYTE-DETERMINISTIC, which a
        # write-parity corpus depends on), XFL by level, OS=255 (unknown).
        out[0] = UInt8(0x1F)
        out[1] = UInt8(0x8B)
        out[2] = UInt8(8)
        out[3] = UInt8(0)
        out[4] = UInt8(0)
        out[5] = UInt8(0)
        out[6] = UInt8(0)
        out[7] = UInt8(0)
        comptime xfl = 2 if Self.level == 9 else (4 if Self.level == 1 else 0)
        out[8] = UInt8(xfl)
        out[9] = UInt8(255)

        # Trailer, little-endian, starting where the adler32 sat.
        var isize = UInt32(n & 0xFFFFFFFF)
        out.resize(8 + zlen - 4, UInt8(0))
        out.append(UInt8(Int(crc) & 0xFF))
        out.append(UInt8((Int(crc) >> 8) & 0xFF))
        out.append(UInt8((Int(crc) >> 16) & 0xFF))
        out.append(UInt8((Int(crc) >> 24) & 0xFF))
        out.append(UInt8(Int(isize) & 0xFF))
        out.append(UInt8((Int(isize) >> 8) & 0xFF))
        out.append(UInt8((Int(isize) >> 16) & 0xFF))
        out.append(UInt8((Int(isize) >> 24) & 0xFF))
        return out^

    @staticmethod
    def decompress(
        input: Span[UInt8, _], expected_size: Int
    ) raises -> List[UInt8]:
        if expected_size <= 0:
            raise Error(
                "Gzip.decompress: expected_size must be > 0 (got "
                + String(expected_size) + ")"
            )
        var out = List[UInt8](capacity=expected_size)
        out.resize(unsafe_uninit_length=expected_size)
        var written: Int
        try:
            written = zlib_inflate_into(
                Span(out), input, ZLIB_WINDOW_BITS_AUTO
            )
        except e:
            raise Error("Gzip.decompress: " + String(e))
        out.resize(written, UInt8(0))
        return out^


# =============================================================================
# SCAFFOLD codecs — trait shape lands; bodies raise clear errors
# =============================================================================
#
# Each scaffold conformer is structurally complete: it satisfies the
# `Compression` trait, has correct `PARQUET_CODEC_ID` / `FILE_EXTENSION` /
# `NAME`, and so `(F == X)` cascades pick it up. Only the
# runtime body differs — they raise a clear error pointing at
# `komira_parquet.compression` for production paths.


@fieldwise_init
struct Lzo(Compression):
    """LZO compression codec (Parquet codec id 3) — LEGACY scaffold.

    LZO is extremely rare in modern Parquet files; even `komira_parquet.
    compression.decompress` raises a clear "re-write with Snappy or Zstd"
    error for this codec (it has never been wired). This trait conformer
    inherits the same boundary.
    """

    var _reserved: Bool

    comptime PARQUET_CODEC_ID: Int8 = 3
    comptime FILE_EXTENSION: StaticString = ""
    comptime NAME: StaticString = "lzo"

    def __init__(out self):
        self._reserved = False

    @staticmethod
    def compress(input: Span[UInt8, _]) raises -> List[UInt8]:
        raise Error(
            "Lzo.compress: not supported. LZO is a legacy Parquet codec; "
            + "re-write with Snappy or Zstd."
        )

    @staticmethod
    def decompress(
        input: Span[UInt8, _], expected_size: Int
    ) raises -> List[UInt8]:
        raise Error(
            "Lzo.decompress: not supported. LZO is a legacy Parquet codec; "
            + "re-write with Snappy or Zstd."
        )


@fieldwise_init
struct Brotli[quality: Int = 11](Compression):
    """Brotli compression codec (Parquet codec id 4) — SCAFFOLD.

    Brotli is rare in Parquet but common in HTTP / web payloads. This
    conformer carries the trait shape; libbrotli FFI is not wired.
    """

    var _reserved: Bool

    comptime PARQUET_CODEC_ID: Int8 = 4
    comptime FILE_EXTENSION: StaticString = ".br"
    comptime NAME: StaticString = "brotli"

    def __init__(out self):
        self._reserved = False

    @staticmethod
    def compress(input: Span[UInt8, _]) raises -> List[UInt8]:
        raise Error(
            "Brotli.compress: not yet wired in Compression trait conformer "
            + "(scaffold; libbrotli FFI is not wired)."
        )

    @staticmethod
    def decompress(
        input: Span[UInt8, _], expected_size: Int
    ) raises -> List[UInt8]:
        raise Error(
            "Brotli.decompress: not yet wired in Compression trait conformer "
            + "(scaffold; libbrotli FFI is not wired)."
        )


@fieldwise_init
struct Lz4Raw(Compression):
    """LZ4 raw-block compression codec (Parquet codec id 7).

    Delegates to komira_lz4's raw-block API (`lz4_compress_bound` /
    `lz4_compress_into` / `lz4_decompress_into`, over liblz4's
    `LZ4_compressBound` / `LZ4_compress_default` / `LZ4_decompress_safe`).
    This is the raw LZ4 BLOCK format (no frame magic, no block list, no end
    mark); distinct on-wire from `Lz4Frame` (Arrow IPC, magic 0x184D2204). The
    two LZ4 framings are NOT interchangeable.
    """

    var _reserved: Bool

    comptime PARQUET_CODEC_ID: Int8 = 7
    comptime FILE_EXTENSION: StaticString = ".lz4"
    comptime NAME: StaticString = "lz4_raw"

    def __init__(out self):
        self._reserved = False

    @staticmethod
    def compress(input: Span[UInt8, _]) raises -> List[UInt8]:
        # The block format carries NO length/frame prefix — the caller stores
        # the uncompressed size out-of-band (Parquet page header carries it).
        # An empty input is the one-byte empty block 0x00.
        # komira_lz4 refuses a source past LZ4_MAX_INPUT_SIZE (liblz4's
        # bound is 0 for one, so nothing is allocated for it first).
        var bound = lz4_compress_bound(len(input))
        var out = List[UInt8](capacity=bound)
        out.resize(unsafe_uninit_length=bound)
        var written: Int
        try:
            written = lz4_compress_into(Span(out), input)
        except e:
            raise Error("Lz4Raw.compress: " + String(e))
        out.resize(written, UInt8(0))
        return out^

    @staticmethod
    def decompress(
        input: Span[UInt8, _], expected_size: Int
    ) raises -> List[UInt8]:
        # The raw block carries no uncompressed-size prefix, so `expected_size`
        # (the decoded size the caller knows out-of-band) IS the destination
        # capacity.
        if expected_size <= 0:
            raise Error(
                "Lz4Raw.decompress: expected_size must be > 0 (got "
                + String(expected_size) + ")"
            )
        var out = List[UInt8](capacity=expected_size)
        out.resize(unsafe_uninit_length=expected_size)
        var written: Int
        try:
            written = lz4_decompress_into(Span(out), input)
        except e:
            raise Error("Lz4Raw.decompress: " + String(e))
        out.resize(written, UInt8(0))
        return out^


@fieldwise_init
struct Zlib[level: Int = 6](Compression):
    """Raw zlib/deflate compression codec (Parquet codec id 8) — SCAFFOLD.

    Distinct from `Gzip` in that `Zlib` uses raw deflate framing (no
    gzip magic header). The Parquet "GZIP" codec id 2 covers both gzip
    and zlib framing via auto-detect; this slot reserves codec id 8 for
    explicit raw-deflate write paths. Raw deflate (`deflateInit2` with
    `windowBits = -15`) is not wired.
    """

    var _reserved: Bool

    comptime PARQUET_CODEC_ID: Int8 = 8
    comptime FILE_EXTENSION: StaticString = ".zz"
    comptime NAME: StaticString = "zlib"

    def __init__(out self):
        self._reserved = False

    @staticmethod
    def compress(input: Span[UInt8, _]) raises -> List[UInt8]:
        raise Error(
            "Zlib.compress: not yet wired in Compression trait conformer "
            + "(scaffold; production uses komira_parquet.compression GZIP)."
        )

    @staticmethod
    def decompress(
        input: Span[UInt8, _], expected_size: Int
    ) raises -> List[UInt8]:
        raise Error(
            "Zlib.decompress: not yet wired in Compression trait conformer "
            + "(scaffold; production uses komira_parquet.compression GZIP)."
        )
