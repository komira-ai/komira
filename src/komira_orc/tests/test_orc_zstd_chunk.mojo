# =============================================================================
# test_orc_zstd_chunk.mojo — ORC Zstd chunk-framing decompress.
# =============================================================================
#
# ORC compressed streams are framed in 3-byte chunk headers: (compressed_length << 1) |
# isOriginal. The reader decompresses each non-original chunk via libzstd and
# copies original chunks verbatim. None codec returns the stream as-is.
#
# The zstd frame below was produced with `zstd -1` on the literal
# "hello orc zstd world!!" (22 bytes -> 35-byte frame) — a known-good frame so
# the test exercises the real libzstd FFI without needing a zstd-COMPRESS
# binding in-tree.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_orc import (
    decompress_stream,
    parse_chunk_header,
    ORC_COMPRESSION_NONE,
    ORC_COMPRESSION_ZSTD,
)


def _u8s(*vals: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(len(vals)):
        out.append(UInt8(vals[i]))
    return out^


def _zstd_frame() -> List[UInt8]:
    # `zstd -1` of "hello orc zstd world!!".
    return _u8s(
        40, 181, 47, 253, 36, 22, 177, 0, 0, 104, 101, 108, 108, 111, 32, 111,
        114, 99, 32, 122, 115, 116, 100, 32, 119, 111, 114, 108, 100, 33, 33,
        106, 9, 116, 247,
    )


def _expected() -> String:
    return String("hello orc zstd world!!")


def _emit_chunk_header(compressed_length: Int, is_original: Bool) -> List[UInt8]:
    var header = (compressed_length << 1) | (1 if is_original else 0)
    var out = List[UInt8]()
    out.append(UInt8(header & 0xFF))
    out.append(UInt8((header >> 8) & 0xFF))
    out.append(UInt8((header >> 16) & 0xFF))
    return out^


def _bytes_to_string(b: List[UInt8]) -> String:
    var s = String("")
    for i in range(len(b)):
        s += chr(Int(b[i]))
    return s^


# =============================================================================
# Tests
# =============================================================================


def test_none_codec_passthrough() raises:
    var data = List[UInt8]()
    data.append(UInt8(ord("A")))
    data.append(UInt8(ord("B")))
    data.append(UInt8(ord("C")))
    var out = decompress_stream(data, ORC_COMPRESSION_NONE, 0)
    assert_equal(len(out), 3)
    assert_equal(_bytes_to_string(out), String("ABC"))


def test_zstd_single_compressed_chunk() raises:
    var frame = _zstd_frame()
    var stream = _emit_chunk_header(len(frame), False)
    for i in range(len(frame)):
        stream.append(frame[i])
    var out = decompress_stream(stream, ORC_COMPRESSION_ZSTD, 256 * 1024)
    assert_equal(_bytes_to_string(out), _expected())


def test_zstd_original_chunk_verbatim() raises:
    # isOriginal = 1 — the chunk bytes are stored uncompressed; copied as-is.
    var payload = List[UInt8]()
    var msg = String("uncompressed-chunk")
    var mb = msg.as_bytes()
    for i in range(len(mb)):
        payload.append(mb[i])
    var stream = _emit_chunk_header(len(payload), True)
    for i in range(len(payload)):
        stream.append(payload[i])
    var out = decompress_stream(stream, ORC_COMPRESSION_ZSTD, 256 * 1024)
    assert_equal(_bytes_to_string(out), msg)


def test_zstd_mixed_chunks() raises:
    # An original chunk followed by a compressed chunk in one stream.
    var orig = String("PREFIX:")
    var ob = orig.as_bytes()
    var op = List[UInt8]()
    for i in range(len(ob)):
        op.append(ob[i])
    var stream = _emit_chunk_header(len(op), True)
    for i in range(len(op)):
        stream.append(op[i])
    # Compressed chunk.
    var frame = _zstd_frame()
    var h2 = _emit_chunk_header(len(frame), False)
    for i in range(len(h2)):
        stream.append(h2[i])
    for i in range(len(frame)):
        stream.append(frame[i])
    var out = decompress_stream(stream, ORC_COMPRESSION_ZSTD, 256 * 1024)
    assert_equal(_bytes_to_string(out), orig + _expected())


def test_chunk_header_parse() raises:
    var hdr_bytes = _emit_chunk_header(100, False)
    var hdr = parse_chunk_header(hdr_bytes, 0)
    assert_equal(hdr.compressed_length, 100)
    assert_true(not hdr.is_original)
    var hdr2_bytes = _emit_chunk_header(7, True)
    var hdr2 = parse_chunk_header(hdr2_bytes, 0)
    assert_equal(hdr2.compressed_length, 7)
    assert_true(hdr2.is_original)


def main() raises:
    test_none_codec_passthrough()
    test_zstd_single_compressed_chunk()
    test_zstd_original_chunk_verbatim()
    test_zstd_mixed_chunks()
    test_chunk_header_parse()
    print("test_orc_zstd_chunk: ALL PASS")
