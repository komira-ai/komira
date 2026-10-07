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
# - test_short_literal_store_exact_dst, test_short_copy2_store_exact_dst,
#   test_copy1_fast_store_exact_dst, test_apply_copy_store_exact_dst:
#   hand-built blobs that put a short literal, a short copy-2 (offset >= 16),
#   a copy-1 with offset >= 16 or a non-overlapping copy of at most 16 bytes
#   at every distance from the end of the output. Those are the four sites
#   where the Mojo decoder does a single 16-byte store, each legal only with
#   room for it, so each blob is decoded into every capacity from the exact
#   size to past the slop, the sentinel after it must be untouched and the
#   Mojo output must equal the C library's. The tails are offset-1 copies of
#   length 2, which both decoders write exactly, so any overshoot comes from
#   the tag under test. The C compressor seldom emits these shapes near the
#   end of a blob.

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


def _decode[
    o: MutOrigin
](decoder: SnappyDecoder, blob: List[UInt8], dst: Span[UInt8, o]) raises -> Int:
    """Decode `blob` into `dst` with `decoder`. The process-wide decoder is
    reset to the C library whether or not the decode raises, so a failure
    here cannot leave a later test comparing the Mojo decoder with itself."""
    set_snappy_decoder(decoder)
    try:
        var n = snappy_decompress(Span(blob), dst)
        set_snappy_decoder(SnappyDecoder.C_LIBRARY)
        return n
    except e:
        set_snappy_decoder(SnappyDecoder.C_LIBRARY)
        raise e^


def _canary_check(blob: List[UInt8], want_len: Int) raises:
    """Decode `blob` with each decoder into an exact-size window; the sentinel
    bytes after it must be untouched."""
    for d in range(2):
        var decoder = _decoder(d)
        var buf = _guarded(want_len)
        var n = _decode(decoder, blob, Span(buf)[0:want_len])
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
                    var got = _decode(decoder, blob, Span(buf)[0:cap])
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
            try:
                _ = _decode(decoder, blob, Span(buf)[0:cap])
            except:
                refused = True
            assert_equal(
                _clobbered_past(buf, cap),
                0,
                where + ": bytes written past len(dst)",
            )
            assert_true(refused, where + ": a too-small dst was not refused")


def _put_varint(mut out: List[UInt8], v: Int):
    var x = v
    while x >= 128:
        out.append(UInt8((x & 127) | 128))
        x >>= 7
    out.append(UInt8(x))


def _literal(mut body: List[UInt8], n: Int, seed: Int):
    """A literal tag of 1..60 bytes and its bytes."""
    body.append(UInt8((n - 1) << 2))
    for i in range(n):
        body.append(UInt8(33 + (seed * 7 + i * 13) % 90))


def _copy1(mut body: List[UInt8], length: Int, offset: Int):
    """A copy-1 tag: length 4..11, offset < 2048."""
    body.append(UInt8(((offset >> 8) << 5) | ((length - 4) << 2) | 1))
    body.append(UInt8(offset & 255))


def _copy2(mut body: List[UInt8], length: Int, offset: Int):
    """A copy-2 tag: length 1..64, offset < 65536."""
    body.append(UInt8(((length - 1) << 2) | 2))
    body.append(UInt8(offset & 255))
    body.append(UInt8(offset >> 8))


def _rle_tail(mut body: List[UInt8], tags: Int):
    """`tags` copy-4 tags of length 2 at offset 1: 2 output bytes each for 5
    input bytes, written exactly by both decoders (an RLE fill)."""
    for _ in range(tags):
        body.append(UInt8(((2 - 1) << 2) | 3))
        body.append(1)
        body.append(0)
        body.append(0)
        body.append(0)


def _blob(n: Int, body: List[UInt8]) -> List[UInt8]:
    var out = List[UInt8]()
    _put_varint(out, n)
    for b in body:
        out.append(b)
    return out^


def _every_room_matches_c(blob: List[UInt8], n: Int, what: String) raises:
    """Decode `blob` (declaring `n` bytes) with each decoder into a window of
    every capacity from n to n + kSlopBytes + 1 of a sentinel-filled buffer.
    No byte past the window may change, and the Mojo output must equal the C
    library's."""
    for room in range(kSlopBytes + 2):
        var cap = n + room
        var where = what + " room=" + String(room)
        var c_buf = _guarded(cap)
        var c_n = _decode(SnappyDecoder.C_LIBRARY, blob, Span(c_buf)[0:cap])
        assert_equal(c_n, n, where + ": C length")
        var m_buf = _guarded(cap)
        var m_n = _decode(SnappyDecoder.MOJO, blob, Span(m_buf)[0:cap])
        assert_equal(m_n, n, where + ": Mojo length")
        assert_equal(
            _clobbered_past(m_buf, cap),
            0,
            where + ": Mojo bytes written past len(dst)",
        )
        assert_equal(
            _clobbered_past(c_buf, cap),
            0,
            where + ": C bytes written past len(dst)",
        )
        for i in range(n):
            if m_buf[i] != c_buf[i]:
                assert_equal(
                    Int(m_buf[i]), Int(c_buf[i]), where + ": byte " + String(i)
                )


def test_short_literal_store_exact_dst() raises:
    # [prefix literal] + a literal of 1..16 bytes + `tail` RLE tags. The
    # short-literal path stores 16 bytes when 21 input bytes follow the tag,
    # which the RLE tail supplies while adding only 2 output bytes per tag.
    # The prefix puts the literal at op 0, at a small op and after a long
    # literal.
    var prefixes: List[Int] = [0, 1, 5, 17]
    for pi in range(len(prefixes)):
        var prefix = prefixes[pi]
        for length in range(1, 17):
            for tail in range(9):
                var body = List[UInt8]()
                if prefix > 0:
                    _literal(body, prefix, 1)
                _literal(body, length, 2)
                _rle_tail(body, tail)
                var n = prefix + length + 2 * tail
                _every_room_matches_c(
                    _blob(n, body),
                    n,
                    "short literal prefix=" + String(prefix) + " len="
                    + String(length) + " tail=" + String(tail),
                )


def test_short_copy2_store_exact_dst() raises:
    # A literal of 16..20 bytes + a copy-2 of length 1..16 at offset 16..lit
    # + `tail` RLE tags. With room, the short copy-2 path stores 16 bytes from
    # op - offset.
    for lit in range(16, 21):
        for length in range(1, 17):
            for tail in range(9):
                var body = List[UInt8]()
                _literal(body, lit, 3)
                _copy2(body, length, 16 + (lit + length) % (lit - 15))
                _rle_tail(body, tail)
                var n = lit + length + 2 * tail
                _every_room_matches_c(
                    _blob(n, body),
                    n,
                    "short copy-2 lit=" + String(lit) + " len="
                    + String(length) + " tail=" + String(tail),
                )


def test_copy1_fast_store_exact_dst() raises:
    # A literal of 16..20 bytes + a copy-1 of 4..11 bytes at offset 16..lit
    # + `tail` RLE tags. With room, the copy-1 fast path stores 16 bytes from
    # op - offset; the source window ends at or before op, so every byte the
    # store would put past the output is a literal byte, never the sentinel.
    for lit in range(16, 21):
        for length in range(4, 12):
            for tail in range(9):
                var body = List[UInt8]()
                _literal(body, lit, 5)
                _copy1(body, length, 16 + (lit + length) % (lit - 15))
                _rle_tail(body, tail)
                var n = lit + length + 2 * tail
                _every_room_matches_c(
                    _blob(n, body),
                    n,
                    "copy-1 fast lit=" + String(lit) + " len="
                    + String(length) + " tail=" + String(tail),
                )


def test_apply_copy_store_exact_dst() raises:
    # A literal of 4..15 bytes + a copy-1 of 4..11 bytes at offset lit (>=
    # length, so no overlap; < 16, so off the copy-1 fast path at any room) +
    # `tail` RLE tags. These reach _apply_copy's single 16-byte store, which
    # is legal only when 16 bytes fit before the decoded length. (Without
    # slop the short copy-2 and copy-1 fast-path blobs above reach it too.)
    for lit in range(4, 16):
        for length in range(4, 12):
            if length > lit:
                continue
            for tail in range(9):
                var body = List[UInt8]()
                _literal(body, lit, 4)
                _copy1(body, length, lit)
                _rle_tail(body, tail)
                var n = lit + length + 2 * tail
                _every_room_matches_c(
                    _blob(n, body),
                    n,
                    "copy-1 lit=" + String(lit) + " len=" + String(length)
                    + " tail=" + String(tail),
                )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
