# The snappy decoders against a destination with less than kSlopBytes of room
# past the decoded length. Every destination is a window of a larger buffer
# filled with a sentinel, so a store past len(dst) shows up as a changed
# sentinel byte -- a plain assertion failure, not undefined behaviour.
#
# - test_long_literal_then_tags_exact_dst, test_copy2_long_tail_exact_dst:
#   two hand-built blobs that reached the Mojo decoder's long-literal and long
#   copy-2 paths with an exact-size destination; those paths did 16-byte
#   stores up to 15 bytes past the decoded length.
# - test_every_room_short_of_the_slop: C-compressed payloads of many sizes
#   and shapes, decoded into every capacity from the exact size to one byte
#   past the slop, so each wide-store site meets a destination that ends at
#   each offset from its store.
# - test_declared_length_larger_than_dst: a blob whose preamble declares more
#   than the destination holds is refused by both decoders before any byte
#   is written.

from std.testing import TestSuite, assert_equal, assert_true

from komira_parquet_codec.snappy import (
    SnappyDecoder,
    kSlopBytes,
    set_snappy_decoder,
    snappy_compress,
    snappy_decompress,
    snappy_max_compressed_length,
)

comptime _SENTINEL: UInt8 = 0xCC
comptime _GUARD = 80


def _decoder(d: Int) -> SnappyDecoder:
    return SnappyDecoder.MOJO if d == 1 else SnappyDecoder.C_LIBRARY


def _guarded(cap: Int, guard: Int = _GUARD) -> List[UInt8]:
    """`cap` bytes for the destination, then `guard` sentinel bytes."""
    var buf = List[UInt8](capacity=cap + guard)
    for _ in range(cap + guard):
        buf.append(_SENTINEL)
    return buf^


def _clobbered_past(buf: List[UInt8], cap: Int) -> Int:
    var n = 0
    for i in range(cap, len(buf)):
        if buf[i] != _SENTINEL:
            n += 1
    return n


def _canary_check(blob: List[UInt8], want_len: Int) raises:
    """Decode `blob` with each decoder into an exact-size window; the sentinel
    bytes after it must be untouched."""
    for d in range(2):
        var decoder = _decoder(d)
        var buf = _guarded(want_len)
        set_snappy_decoder(decoder)
        var n = snappy_decompress(Span(blob), Span(buf)[0:want_len])
        set_snappy_decoder(SnappyDecoder.C_LIBRARY)
        assert_equal(n, want_len, String(decoder) + ": length")
        assert_equal(
            _clobbered_past(buf, want_len),
            0,
            String(decoder) + ": bytes written past len(dst)",
        )


def test_long_literal_then_tags_exact_dst() raises:
    # uncompressed 22 = literal 17 + five copy-2 (length 1, offset 1) tags.
    var blob: List[UInt8] = [22, 0x40]
    for _ in range(17):
        blob.append(0x41)
    for _ in range(5):
        blob.append(0x02)
        blob.append(0x01)
        blob.append(0x00)
    _canary_check(blob, 22)


def test_copy2_long_tail_exact_dst() raises:
    # uncompressed 47 = literal 15 + literal 15 + copy-2 (length 17, offset 16).
    var blob: List[UInt8] = [47, 0x38]
    for _ in range(15):
        blob.append(0x41)
    blob.append(0x38)
    for _ in range(15):
        blob.append(0x42)
    blob.append(0x42)
    blob.append(16)
    blob.append(0)
    _canary_check(blob, 47)


def _payload(n: Int, shape: Int) -> List[UInt8]:
    """`shape` 0: noise (long literals); 1: a 20-byte period (copies with
    offset >= 16); 2: runs and noise mixed; 3: a 2-byte period."""
    var out = List[UInt8](capacity=n)
    var s: UInt32 = UInt32(2463534242 + n * 7 + shape)
    for i in range(n):
        s = s * 1664525 + 1013904223
        if shape == 0:
            out.append(UInt8(Int(s >> 24)))
        elif shape == 1:
            out.append(UInt8(65 + (i % 20)))
        elif shape == 2:
            if (i // 37) % 2 == 0:
                out.append(UInt8(Int(s >> 24)))
            else:
                out.append(UInt8(97 + (i % 23)))
        else:
            out.append(UInt8(120 + (i % 2)))
    return out^


def _compress(data: List[UInt8]) raises -> List[UInt8]:
    var bound = snappy_max_compressed_length(len(data))
    var out = List[UInt8](capacity=bound)
    for _ in range(bound):
        out.append(0)
    var w = snappy_compress(Span(data), Span(out))
    out.resize(w, 0)
    return out^


def test_every_room_short_of_the_slop() raises:
    var sizes: List[Int] = [1, 15, 16, 17, 22, 47, 63, 64, 65, 100, 129, 200, 300]
    for si in range(len(sizes)):
        var n = sizes[si]
        for shape in range(4):
            var data = _payload(n, shape)
            var blob = _compress(data)
            for room in range(kSlopBytes + 2):
                var cap = n + room
                for d in range(2):
                    var decoder = _decoder(d)
                    var where = (
                        String(decoder) + " n=" + String(n) + " shape="
                        + String(shape) + " room=" + String(room)
                    )
                    var buf = _guarded(cap)
                    set_snappy_decoder(decoder)
                    var got = snappy_decompress(Span(blob), Span(buf)[0:cap])
                    set_snappy_decoder(SnappyDecoder.C_LIBRARY)
                    assert_equal(got, n, where + ": length")
                    assert_equal(
                        _clobbered_past(buf, cap),
                        0,
                        where + ": bytes written past len(dst)",
                    )
                    for i in range(n):
                        if buf[i] != data[i]:
                            assert_equal(
                                Int(buf[i]), Int(data[i]),
                                where + ": byte " + String(i),
                            )


def test_declared_length_larger_than_dst() raises:
    # Each blob decodes cleanly to n bytes; the destination holds n // 2, and
    # both decoders must refuse it without writing past it.
    for shape in range(4):
        var n = 200
        var data = _payload(n, shape)
        var blob = _compress(data)
        var cap = n // 2
        for d in range(2):
            var decoder = _decoder(d)
            var where = String(decoder) + " shape=" + String(shape)
            # A decoder that ignored the declared length would write up to n
            # bytes and its overshoot, so the guard covers all of it.
            var buf = _guarded(cap, n + _GUARD)
            var refused = False
            set_snappy_decoder(decoder)
            try:
                _ = snappy_decompress(Span(blob), Span(buf)[0:cap])
            except:
                refused = True
            set_snappy_decoder(SnappyDecoder.C_LIBRARY)
            assert_equal(
                _clobbered_past(buf, cap),
                0,
                where + ": bytes written past len(dst)",
            )
            assert_true(refused, where + ": a too-small dst was not refused")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
