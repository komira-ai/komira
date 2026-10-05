# Every codec through the public dispatch, with truncations, single-byte
# corruptions and exact/short/empty destinations. A decode must either raise
# or return a count <= len(dst), and the sentinel bytes before and after the
# destination must never change.
#
# - test_snappy_c, test_snappy_mojo, test_gzip, test_zstd, test_lz4_raw,
#   test_lz4_deprecated_as_frame_and_raw_and_hadoop, test_brotli_vectors: the
#   truncation and corruption sweep, codec by codec.
# - test_hadoop_block_larger_than_dst, test_hadoop_second_block_overclaims:
#   a Hadoop-framed LZ4 page whose (first or second) block declares more
#   than the rest of the destination holds is refused.
# - test_hostile_size_claims: size fields claiming gigabytes or more.

from std.pathlib import Path
from std.testing import TestSuite, assert_equal, assert_true

from komira_parquet_api import CompressionCodec
from komira_parquet_codec import (
    SnappyDecoder,
    compress,
    compress_bound,
    decompress,
    compress_lz4_frame,
    lz4_frame_compress_bound,
    set_snappy_decoder,
)

comptime _PAD = 64


def _payload(n: Int) -> List[UInt8]:
    var out = List[UInt8](capacity=n)
    var s: UInt32 = 12345
    for i in range(n):
        s = s * 1664525 + 1013904223
        # mixture: runs, repeats, some noise
        if (i // 50) % 3 == 0:
            out.append(UInt8(65 + (i % 7)))
        elif (i // 50) % 3 == 1:
            out.append(UInt8(Int(s >> 24)))
        else:
            out.append(UInt8(97 + (i % 3)))
    return out^


def _decode_checked(
    codec: CompressionCodec, blob: List[UInt8], cap: Int, label: String
) raises -> Int:
    """Decode into a `cap`-byte window of a canary-padded buffer. Returns -1
    if the decode raised, else the byte count. Fails if a canary changed or the
    count exceeds `cap`."""
    var buf = List[UInt8](capacity=cap + 2 * _PAD)
    for _ in range(cap + 2 * _PAD):
        buf.append(UInt8(0xCC))
    var got = -1
    try:
        got = decompress(codec, Span(blob), Span(buf)[_PAD : _PAD + cap])
    except:
        got = -1
    for i in range(_PAD):
        assert_true(buf[i] == 0xCC, label + ": wrote BEFORE dst at " + String(i))
    for i in range(_PAD + cap, cap + 2 * _PAD):
        assert_true(
            buf[i] == 0xCC,
            label + ": wrote PAST dst, offset " + String(i - _PAD - cap),
        )
    assert_true(got <= cap, label + ": count exceeds capacity")
    return got


def _hammer(codec: CompressionCodec, blob: List[UInt8], n: Int, name: String) raises:
    # truncations, at three capacities
    var step = 1 if len(blob) < 400 else 7
    var cut = 0
    while cut < len(blob):
        var piece = List[UInt8](capacity=cut)
        for i in range(cut):
            piece.append(blob[i])
        _ = _decode_checked(codec, piece, n, name + " trunc " + String(cut))
        _ = _decode_checked(codec, piece, n - 1, name + " trunc-1 " + String(cut))
        _ = _decode_checked(codec, piece, 0, name + " trunc-0 " + String(cut))
        cut += step
    # single-byte corruptions
    var pos = 0
    while pos < len(blob):
        for v in range(3):
            var bad = List[UInt8](capacity=len(blob))
            for i in range(len(blob)):
                bad.append(blob[i])
            bad[pos] = bad[pos] ^ UInt8([0xFF, 0x01, 0x80][v])
            _ = _decode_checked(codec, bad, n, name + " flip " + String(pos))
            _ = _decode_checked(codec, bad, n // 2, name + " flip-half " + String(pos))
        pos += step


def _compress_all(codec: CompressionCodec, data: List[UInt8]) raises -> List[UInt8]:
    var out = List[UInt8](capacity=compress_bound(codec, len(data)))
    for _ in range(compress_bound(codec, len(data))):
        out.append(0)
    var w = compress(codec, Span(data), Span(out))
    out.resize(w, 0)
    return out^


def test_snappy_c() raises:
    var data = _payload(900)
    var blob = _compress_all(CompressionCodec.SNAPPY, data)
    set_snappy_decoder(SnappyDecoder.C_LIBRARY)
    _hammer(CompressionCodec.SNAPPY, blob, len(data), "snappy-c")


def test_snappy_mojo() raises:
    var data = _payload(900)
    var blob = _compress_all(CompressionCodec.SNAPPY, data)
    set_snappy_decoder(SnappyDecoder.MOJO)
    _hammer(CompressionCodec.SNAPPY, blob, len(data), "snappy-mojo")
    set_snappy_decoder(SnappyDecoder.C_LIBRARY)


def test_gzip() raises:
    var data = _payload(900)
    _hammer(CompressionCodec.GZIP, _compress_all(CompressionCodec.GZIP, data), len(data), "gzip")


def test_zstd() raises:
    var data = _payload(900)
    _hammer(CompressionCodec.ZSTD, _compress_all(CompressionCodec.ZSTD, data), len(data), "zstd")


def test_lz4_raw() raises:
    var data = _payload(900)
    _hammer(CompressionCodec.LZ4_RAW, _compress_all(CompressionCodec.LZ4_RAW, data), len(data), "lz4raw")


def test_lz4_deprecated_as_frame_and_raw_and_hadoop() raises:
    var data = _payload(900)
    var raw = _compress_all(CompressionCodec.LZ4_RAW, data)
    _hammer(CompressionCodec.LZ4, raw, len(data), "lz4dep-raw")
    # Hadoop framing: BE u32 uncompressed, BE u32 compressed, block
    var had = List[UInt8]()
    var n = len(data)
    var c = len(raw)
    had.append(UInt8((n >> 24) & 0xFF)); had.append(UInt8((n >> 16) & 0xFF))
    had.append(UInt8((n >> 8) & 0xFF)); had.append(UInt8(n & 0xFF))
    had.append(UInt8((c >> 24) & 0xFF)); had.append(UInt8((c >> 16) & 0xFF))
    had.append(UInt8((c >> 8) & 0xFF)); had.append(UInt8(c & 0xFF))
    for i in range(c):
        had.append(raw[i])
    var ok = _decode_checked(CompressionCodec.LZ4, had, n, "hadoop-ok")
    assert_equal(ok, n)
    _hammer(CompressionCodec.LZ4, had, len(data), "lz4dep-hadoop")
    # frame
    var fb = lz4_frame_compress_bound(len(data))
    var fr = List[UInt8](capacity=fb)
    for _ in range(fb):
        fr.append(0)
    var fw = compress_lz4_frame(Span(data), Span(fr))
    fr.resize(fw, 0)
    _hammer(CompressionCodec.LZ4, fr, len(data), "lz4dep-frame")


def test_hadoop_block_larger_than_dst() raises:
    var data = _payload(300)
    var raw = _compress_all(CompressionCodec.LZ4_RAW, data)
    var had = List[UInt8]()
    var n = len(data)
    var c = len(raw)
    had.append(UInt8((n >> 24) & 0xFF)); had.append(UInt8((n >> 16) & 0xFF))
    had.append(UInt8((n >> 8) & 0xFF)); had.append(UInt8(n & 0xFF))
    had.append(UInt8((c >> 24) & 0xFF)); had.append(UInt8((c >> 16) & 0xFF))
    had.append(UInt8((c >> 8) & 0xFF)); had.append(UInt8(c & 0xFF))
    for i in range(c):
        had.append(raw[i])
    assert_equal(_decode_checked(CompressionCodec.LZ4, had, 100, "hadoop-bigger"), -1)


def _hadoop_prefix(mut out: List[UInt8], uncompressed: Int, compressed: Int):
    out.append(UInt8((uncompressed >> 24) & 0xFF))
    out.append(UInt8((uncompressed >> 16) & 0xFF))
    out.append(UInt8((uncompressed >> 8) & 0xFF))
    out.append(UInt8(uncompressed & 0xFF))
    out.append(UInt8((compressed >> 24) & 0xFF))
    out.append(UInt8((compressed >> 16) & 0xFF))
    out.append(UInt8((compressed >> 8) & 0xFF))
    out.append(UInt8(compressed & 0xFF))


def test_hadoop_second_block_overclaims() raises:
    # Two Hadoop blocks of 120 bytes each into a 200-byte destination: the
    # first fits, the second declares 120 where 80 remain.
    var a = _payload(120)
    var b = _payload(240)
    var b_tail = List[UInt8](capacity=120)
    for i in range(120, 240):
        b_tail.append(b[i])
    var ra = _compress_all(CompressionCodec.LZ4_RAW, a)
    var rb = _compress_all(CompressionCodec.LZ4_RAW, b_tail)
    var had = List[UInt8]()
    _hadoop_prefix(had, len(a), len(ra))
    for i in range(len(ra)):
        had.append(ra[i])
    _hadoop_prefix(had, len(b_tail), len(rb))
    for i in range(len(rb)):
        had.append(rb[i])
    assert_equal(_decode_checked(CompressionCodec.LZ4, had, 240, "hadoop-2-ok"), 240)
    assert_equal(
        _decode_checked(CompressionCodec.LZ4, had, 200, "hadoop-2-overclaim"), -1
    )


def test_hostile_size_claims() raises:
    # Hadoop prefix claiming 4 GiB - 1 of both.
    var h: List[UInt8] = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00]
    for _ in range(100):
        h.append(0x11)
    assert_equal(_decode_checked(CompressionCodec.LZ4, h, 64, "hadoop-bomb"), -1)
    # snappy preamble claiming 4 GiB - 1, tiny body, both decoders.
    var sn: List[UInt8] = [0xFF, 0xFF, 0xFF, 0xFF, 0x0F, 0x00, 0x41]
    for d in range(2):
        set_snappy_decoder(SnappyDecoder.MOJO if d == 1 else SnappyDecoder.C_LIBRARY)
        assert_equal(_decode_checked(CompressionCodec.SNAPPY, sn, 1024, "snappy-bomb"), -1)
        # Overlong varint
        var sv: List[UInt8] = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01, 0x00]
        assert_equal(_decode_checked(CompressionCodec.SNAPPY, sv, 1024, "snappy-varint"), -1)
    set_snappy_decoder(SnappyDecoder.C_LIBRARY)
    # LZ4 raw: literal-run token claiming a huge literal (0xF0 + 255s)
    var lz: List[UInt8] = [0xF0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x10]
    for _ in range(40):
        lz.append(0x22)
    assert_equal(_decode_checked(CompressionCodec.LZ4_RAW, lz, 64, "lz4raw-bomb"), -1)
    # zstd frame magic + frame header claiming a 2^40 content size
    var zs: List[UInt8] = [0x28, 0xB5, 0x2F, 0xFD, 0xA0, 0, 0, 0, 0, 0, 1, 0x01, 0x00, 0x00]
    assert_equal(_decode_checked(CompressionCodec.ZSTD, zs, 64, "zstd-bomb"), -1)
    # empty inputs
    var empty = List[UInt8]()
    for k in range(6):
        var codec = [CompressionCodec.SNAPPY, CompressionCodec.GZIP, CompressionCodec.ZSTD, CompressionCodec.LZ4_RAW, CompressionCodec.LZ4, CompressionCodec.BROTLI][k]
        var r = _decode_checked(codec, empty, 16, "empty-" + String(k))
        assert_true(r == -1 or r == 0)


def test_brotli_vectors() raises:
    var want = Path("brotli/tests/testdata/ukkonooa").read_bytes()
    var blob = Path("brotli/tests/testdata/ukkonooa.compressed").read_bytes()
    _hammer(CompressionCodec.BROTLI, blob, len(want), "brotli")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
