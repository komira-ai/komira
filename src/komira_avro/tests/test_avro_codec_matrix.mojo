# =============================================================================
# test_avro_codec_matrix.mojo — full Avro read codec matrix.
# =============================================================================
#
# Round-trip tests for
# all 6 officially-spec Avro codecs (null/deflate/snappy/bzip2/xz/zstandard)
# plus 3 wire-detail guards:
#   - test_codec_zstd_wire_name_zstandard — "zstandard" accepted, "zstd" rejected.
#   - test_codec_deflate_raw_rfc1951_not_zlib_wrapped — raw deflate decodes,
#     zlib-wrapped payload does NOT (proves inflateInit2(-15)).
#   - test_codec_snappy_be4_crc32_trailer — strip-and-validate (regression guard).
#
# Fixtures: no Java DataFileWriter is needed: each compressed
# fixture is built IN-TEST by calling the SAME C library's compress entry
# through a local OwnedDLHandle (the codec FFI carve-out). This exercises both
# directions (compress in-test, decompress through decompress_block).
# =============================================================================

from std.testing import assert_equal, assert_true
from std.memory import alloc, unsafe_memset
from std.ffi import OwnedDLHandle, external_call
from std.sys.info import CompilationTarget

from komira_avro import (
    decompress_block,
    codec_tag_from_wire_name,
    AVRO_CODEC_NULL,
    AVRO_CODEC_DEFLATE,
    AVRO_CODEC_SNAPPY,
    AVRO_CODEC_BZIP2,
    AVRO_CODEC_XZ,
    AVRO_CODEC_ZSTANDARD,
    crc32_ieee,
)


# -- Per-OS sonames (match avro_codec.mojo; snappy is statically linked). --
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


@always_inline
def _null_ffi_byte() -> UnsafePointer[UInt8, MutUntrackedOrigin]:
    """A raw NULL FFI byte pointer (Mojo has no null `UnsafePointer`
    constructor, and `unsafe_from_address=0` is banned).

    # SAFETY: `Optional[UnsafePointer[...]]` is layout-compatible with the bare
    # pointer (the Mojo non-null-pointer layout guarantee); `None` is the all-zero
    # (NULL) bit pattern. Used only for the liblzma allocator = NULL arg.
    """
    var none: Optional[UnsafePointer[UInt8, MutUntrackedOrigin]] = None
    return UnsafePointer(to=none).bitcast[
        UnsafePointer[UInt8, MutUntrackedOrigin]
    ]()[]


def _sample_payload() -> List[UInt8]:
    """A compressible ~600-byte payload (repeats so every codec shrinks it)."""
    var out = List[UInt8]()
    for r in range(60):
        var base = String("avro-codec-row-") + String(r) + String("|")
        var b = base.as_bytes()
        for i in range(len(b)):
            out.append(b[i])
    return out^


def _assert_roundtrip(decompressed: List[UInt8], original: List[UInt8]) raises:
    assert_equal(len(decompressed), len(original), "length matches")
    for i in range(len(original)):
        assert_equal(
            Int(decompressed[i]), Int(original[i]), "byte " + String(i)
        )


# =============================================================================
# null
# =============================================================================
def test_codec_null_roundtrip() raises:
    var raw = _sample_payload()
    var out = decompress_block(AVRO_CODEC_NULL, Span(raw))
    _assert_roundtrip(out, raw)


# =============================================================================
# snappy (raw_snappy ‖ BE4 crc32(uncompressed))
# =============================================================================
def _snappy_compress_literal(raw: List[UInt8]) -> List[UInt8]:
    """Minimal valid snappy raw stream for a payload as a single literal run.

    For runs > 60 bytes, snappy uses a 1-byte tag with the literal-length
    encoded in the following 1-2 bytes (tag value 60/61 => 1/2 trailing bytes).
    """
    var out = List[UInt8]()
    var n = UInt64(len(raw))
    while True:
        var b = UInt8(n & 0x7F)
        n >>= 7
        if n != 0:
            out.append(b | 0x80)
        else:
            out.append(b)
            break
    var L = len(raw)
    if L <= 60:
        out.append(UInt8((L - 1) << 2))
    elif L < 256:
        out.append(UInt8(60 << 2))  # tag type 00, len-of-len = 1 byte
        out.append(UInt8(L - 1))
    else:
        out.append(UInt8(61 << 2))  # 2 trailing length bytes
        out.append(UInt8((L - 1) & 0xFF))
        out.append(UInt8(((L - 1) >> 8) & 0xFF))
    for i in range(L):
        out.append(raw[i])
    return out^


def _be4(crc: UInt32, mut out: List[UInt8]):
    out.append(UInt8((crc >> 24) & 0xFF))
    out.append(UInt8((crc >> 16) & 0xFF))
    out.append(UInt8((crc >> 8) & 0xFF))
    out.append(UInt8(crc & 0xFF))


def test_codec_snappy_roundtrip() raises:
    var raw = _sample_payload()
    var payload = _snappy_compress_literal(raw)
    var crc = crc32_ieee(Span(raw))
    _be4(crc, payload)
    var out = decompress_block(AVRO_CODEC_SNAPPY, Span(payload))
    _assert_roundtrip(out, raw)


def test_codec_snappy_be4_crc32_trailer() raises:
    """Regression guard: the BE4 CRC32 trailer is stripped and
    validated; a corrupt trailer must raise."""
    var raw = _sample_payload()
    # Good CRC decodes.
    var good = _snappy_compress_literal(raw)
    var crc = crc32_ieee(Span(raw))
    _be4(crc, good)
    var out = decompress_block(AVRO_CODEC_SNAPPY, Span(good))
    _assert_roundtrip(out, raw)

    # Corrupt CRC must raise.
    var bad = _snappy_compress_literal(raw)
    _be4(crc ^ UInt32(0xFFFFFFFF), bad)
    var raised = False
    try:
        var _x = decompress_block(AVRO_CODEC_SNAPPY, Span(bad))
    except:
        raised = True
    assert_true(raised, "corrupt BE4 CRC32 trailer must raise")


# =============================================================================
# deflate — RAW RFC-1951 (compress in-test via libz deflateInit2(-15)).
# =============================================================================
comptime _Z_STREAM_SIZE: Int = 112
comptime _Z_OK: Int = 0
comptime _Z_FINISH: Int = 4
comptime _Z_STREAM_END: Int = 1
comptime _Z_DEFLATED: Int32 = 8
comptime _Z_DEFAULT_STRATEGY: Int32 = 0


def _deflate_raw_compress(raw: List[UInt8]) raises -> List[UInt8]:
    """RAW RFC-1951 deflate of `raw` via libz deflateInit2 windowBits=-15."""
    var handle = OwnedDLHandle(_LIBZ)
    var version = handle.call[
        "zlibVersion", UnsafePointer[UInt8, MutUntrackedOrigin]
    ]()
    var in_len = len(raw)
    var in_buf = alloc[UInt8](max(in_len, 1))
    for i in range(in_len):
        in_buf[i] = raw[i]
    var cap = in_len + in_len // 2 + 128
    var out_buf = alloc[UInt8](cap)

    var strm = alloc[UInt8](_Z_STREAM_SIZE)
    unsafe_memset(strm, 0, _Z_STREAM_SIZE)
    (strm.bitcast[UInt64]() + 0)[] = UInt64(Int(in_buf))
    (strm.bitcast[UInt32]() + 2)[] = UInt32(in_len)
    (strm.bitcast[UInt64]() + 3)[] = UInt64(Int(out_buf))
    (strm.bitcast[UInt32]() + 8)[] = UInt32(cap)

    # deflateInit2_(strm, level=6, method=Z_DEFLATED, windowBits=-15,
    #               memLevel=8, strategy=0, version, stream_size)
    var init_rc = handle.call["deflateInit2_", Int32](
        strm,
        Int32(6),
        _Z_DEFLATED,
        Int32(-15),
        Int32(8),
        _Z_DEFAULT_STRATEGY,
        version,
        Int32(_Z_STREAM_SIZE),
    )
    if Int(init_rc) != _Z_OK:
        raise Error("test deflateInit2_ failed rc " + String(Int(init_rc)))
    var rc = handle.call["deflate", Int32](strm, Int32(_Z_FINISH))
    var total_out = Int((strm.bitcast[UInt64]() + 5)[])
    _ = handle.call["deflateEnd", Int32](strm)
    if Int(rc) != _Z_STREAM_END:
        raise Error("test deflate did not finish rc " + String(Int(rc)))
    var out = List[UInt8]()
    for i in range(total_out):
        out.append(out_buf[i])
    strm.free()
    in_buf.free()
    out_buf.free()
    _ = handle^
    return out^


def _zlib_wrapped_compress(raw: List[UInt8]) raises -> List[UInt8]:
    """ZLIB-WRAPPED deflate (windowBits=+15) — has 0x78 header + ADLER32. Used
    by the negative-case wire-detail test to prove the reader is raw-only."""
    var handle = OwnedDLHandle(_LIBZ)
    var in_len = len(raw)
    var in_buf = alloc[UInt8](max(in_len, 1))
    for i in range(in_len):
        in_buf[i] = raw[i]
    var cap = in_len + in_len // 2 + 128
    var out_buf = alloc[UInt8](cap)
    var len_buf = alloc[Int64](1)
    len_buf[0] = Int64(cap)
    # compress2(dest, destLen, source, sourceLen, level) => zlib framing.
    var rc = handle.call["compress2", Int32](
        out_buf.unsafe_origin_cast[MutUntrackedOrigin](),
        len_buf,
        in_buf.unsafe_origin_cast[MutUntrackedOrigin](),
        Int64(in_len),
        Int32(6),
    )
    if Int(rc) != _Z_OK:
        raise Error("test compress2 failed rc " + String(Int(rc)))
    var written = Int(len_buf[0])
    var out = List[UInt8]()
    for i in range(written):
        out.append(out_buf[i])
    in_buf.free()
    out_buf.free()
    len_buf.free()
    _ = handle^
    return out^


def test_codec_deflate_roundtrip() raises:
    var raw = _sample_payload()
    var payload = _deflate_raw_compress(raw)
    var out = decompress_block(AVRO_CODEC_DEFLATE, Span(payload))
    _assert_roundtrip(out, raw)


def test_codec_deflate_raw_rfc1951_not_zlib_wrapped() raises:
    """Raw RFC-1951 payload decodes; a zlib-WRAPPED payload does NOT — proves
    the reader uses inflateInit2(-15), not the default zlib-wrapped init."""
    var raw = _sample_payload()

    # (1) Raw deflate decodes correctly.
    var raw_payload = _deflate_raw_compress(raw)
    var out = decompress_block(AVRO_CODEC_DEFLATE, Span(raw_payload))
    _assert_roundtrip(out, raw)

    # (2) The raw payload must NOT begin with a zlib header byte (0x78).
    assert_true(
        raw_payload[0] != UInt8(0x78),
        "raw RFC-1951 deflate has no 0x78 zlib header",
    )

    # (3) A zlib-wrapped payload (0x78 header + ADLER32) must FAIL through the
    # raw (-15) reader. zlib's header bytes are not valid raw-deflate, so
    # inflate(-15) raises.
    var wrapped = _zlib_wrapped_compress(raw)
    assert_true(
        wrapped[0] == UInt8(0x78),
        "zlib-wrapped payload starts with the 0x78 header byte",
    )
    var raised = False
    try:
        var _x = decompress_block(AVRO_CODEC_DEFLATE, Span(wrapped))
    except:
        raised = True
    assert_true(
        raised, "zlib-wrapped payload must fail through inflateInit2(-15)"
    )


# =============================================================================
# zstandard — libzstd ZSTD_compress (compress in-test).
# =============================================================================
def _zstd_compress(raw: List[UInt8]) raises -> List[UInt8]:
    var handle = OwnedDLHandle(_LIBZSTD)
    var in_len = len(raw)
    var in_buf = alloc[UInt8](max(in_len, 1))
    for i in range(in_len):
        in_buf[i] = raw[i]
    var cap = Int(
        handle.call["ZSTD_compressBound", Int](in_len)
    )
    var out_buf = alloc[UInt8](max(cap, 1))
    var result = handle.call["ZSTD_compress", Int](
        out_buf.unsafe_origin_cast[MutUntrackedOrigin](),
        cap,
        in_buf.unsafe_origin_cast[MutUntrackedOrigin](),
        in_len,
        Int32(3),
    )
    var is_err = handle.call["ZSTD_isError", Int](result)
    if is_err != 0:
        raise Error("test ZSTD_compress failed result " + String(result))
    var out = List[UInt8]()
    for i in range(Int(result)):
        out.append(out_buf[i])
    in_buf.free()
    out_buf.free()
    _ = handle^
    return out^


def test_codec_zstd_roundtrip() raises:
    var raw = _sample_payload()
    var payload = _zstd_compress(raw)
    var out = decompress_block(AVRO_CODEC_ZSTANDARD, Span(payload))
    _assert_roundtrip(out, raw)


def test_codec_zstd_wire_name_zstandard() raises:
    """"zstandard" maps to the zstd codec; "zstd" shorthand is rejected."""
    var tag = codec_tag_from_wire_name(String("zstandard"))
    assert_equal(tag, AVRO_CODEC_ZSTANDARD, "'zstandard' -> ZSTANDARD tag")

    var raised = False
    try:
        var _t = codec_tag_from_wire_name(String("zstd"))
    except:
        raised = True
    assert_true(raised, "'zstd' shorthand must be rejected (not spec wire name)")


# =============================================================================
# bzip2 — libbz2 BZ2_bzBuffToBuffCompress (compress in-test).
# =============================================================================
def _bzip2_compress(raw: List[UInt8]) raises -> List[UInt8]:
    var handle = OwnedDLHandle(_LIBBZ2)
    var in_len = len(raw)
    var in_buf = alloc[UInt8](max(in_len, 1))
    for i in range(in_len):
        in_buf[i] = raw[i]
    # bzip2 worst case: source + 1% + 600 bytes.
    var cap = in_len + in_len // 100 + 600
    var out_buf = alloc[UInt8](cap)
    var len_buf = alloc[UInt32](1)
    len_buf[0] = UInt32(cap)
    # BZ2_bzBuffToBuffCompress(dest, destLen, source, sourceLen,
    #                          blockSize100k, verbosity, workFactor)
    var rc = handle.call["BZ2_bzBuffToBuffCompress", Int32](
        out_buf.unsafe_origin_cast[MutUntrackedOrigin](),
        len_buf,
        in_buf.unsafe_origin_cast[MutUntrackedOrigin](),
        UInt32(in_len),
        Int32(9),
        Int32(0),
        Int32(0),
    )
    if Int(rc) != 0:
        raise Error("test BZ2 compress failed rc " + String(Int(rc)))
    var written = Int(len_buf[0])
    var out = List[UInt8]()
    for i in range(written):
        out.append(out_buf[i])
    in_buf.free()
    out_buf.free()
    len_buf.free()
    _ = handle^
    return out^


def test_codec_bzip2_roundtrip() raises:
    var raw = _sample_payload()
    var payload = _bzip2_compress(raw)
    var out = decompress_block(AVRO_CODEC_BZIP2, Span(payload))
    _assert_roundtrip(out, raw)


# =============================================================================
# xz — liblzma lzma_easy_buffer_encode (compress in-test).
# =============================================================================
def _xz_compress(raw: List[UInt8]) raises -> List[UInt8]:
    var handle = OwnedDLHandle(_LIBLZMA)
    var in_len = len(raw)
    var in_buf = alloc[UInt8](max(in_len, 1))
    for i in range(in_len):
        in_buf[i] = raw[i]
    var cap = Int(handle.call["lzma_stream_buffer_bound", Int64](Int64(in_len)))
    var out_buf = alloc[UInt8](max(cap, 1))
    var out_pos = alloc[Int64](1)
    out_pos[0] = Int64(0)
    var null_allocator = _null_ffi_byte()
    # lzma_easy_buffer_encode(preset, check, allocator, in, in_size,
    #                         out, out_pos, out_size)
    # preset=6, check=LZMA_CHECK_CRC64(4).
    var rc = handle.call["lzma_easy_buffer_encode", Int32](
        UInt32(6),
        Int32(4),
        null_allocator,
        in_buf.unsafe_origin_cast[MutUntrackedOrigin](),
        Int64(in_len),
        out_buf.unsafe_origin_cast[MutUntrackedOrigin](),
        out_pos,
        Int64(cap),
    )
    if Int(rc) != 0:
        raise Error("test lzma encode failed rc " + String(Int(rc)))
    var written = Int(out_pos[0])
    var out = List[UInt8]()
    for i in range(written):
        out.append(out_buf[i])
    in_buf.free()
    out_buf.free()
    out_pos.free()
    _ = handle^
    return out^


def test_codec_xz_roundtrip() raises:
    var raw = _sample_payload()
    var payload = _xz_compress(raw)
    var out = decompress_block(AVRO_CODEC_XZ, Span(payload))
    _assert_roundtrip(out, raw)


def main() raises:
    test_codec_null_roundtrip()
    test_codec_snappy_roundtrip()
    test_codec_snappy_be4_crc32_trailer()
    test_codec_deflate_roundtrip()
    test_codec_deflate_raw_rfc1951_not_zlib_wrapped()
    test_codec_zstd_roundtrip()
    test_codec_zstd_wire_name_zstandard()
    test_codec_bzip2_roundtrip()
    test_codec_xz_roundtrip()
    print("test_avro_codec_matrix: ALL PASS")
