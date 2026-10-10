"""Every branch of `decompress_reader`: the suffix table, the codec choice,
the two size hints, each codec's round trip, the grow loop and its three
refusals, and the file entry point.

Fixtures are compressed here with the same codec package the reader decodes
with (`komira_parquet_codec.compression`), so each round trip checks the
decoded bytes against the input, not against a stored blob. Each test names
the mutant it catches in its docstring.
"""

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_buffer.heap_region import HeapRegion
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_parquet_api.types import CompressionCodec
from komira_parquet_codec.compression import (
    compress,
    compress_bound,
    compress_lz4_frame,
    lz4_frame_compress_bound,
    lz4_frame_declared_content_size,
)
from komira_runtime_paths import test_tmpdir

from komira_dispatch_scan.decompress_reader import (
    _MAX_OUTPUT_CAP,
    _codec_for_path,
    _gzip_isize_hint,
    _initial_output_guess,
    decompress_text_bytes_to_buffer,
    decompress_text_file_to_buffer,
    is_compressed_text_path,
)


# =============================================================================
# Fixtures
# =============================================================================


def _text(n: Int) -> List[UInt8]:
    """`n` bytes of CSV-like text that compresses well (a short repeating
    row), so a 4x first guess is too small once `n` is large."""
    var row = String("1,abc,2.5\n").as_bytes()
    var out = List[UInt8]()
    for i in range(n):
        out.append(row[i % len(row)])
    return out^


def _compress(codec: CompressionCodec, src: List[UInt8]) raises -> List[UInt8]:
    var out = List[UInt8](length=compress_bound(codec, len(src)), fill=0)
    var n = compress(codec, Span(src), Span(out))
    out.resize(n, UInt8(0))
    return out^


def _lz4_frame(src: List[UInt8]) raises -> List[UInt8]:
    var out = List[UInt8](length=lz4_frame_compress_bound(len(src)), fill=0)
    var n = compress_lz4_frame(Span(src), Span(out))
    out.resize(n, UInt8(0))
    return out^


def _assert_bytes(buf: SharedAlignedBuffer[HeapRegion], want: List[UInt8]) raises:
    assert_equal(buf.len(), len(want), "decoded length")
    var got = buf.view_range_ro(0, buf.len()).into_span()
    for i in range(len(want)):
        if got[i] != want[i]:
            assert_equal(Int(got[i]), Int(want[i]), "decoded byte " + String(i))


def _raises(
    span: Span[UInt8, _], path: String, cap: Int = _MAX_OUTPUT_CAP
) -> String:
    """The message `decompress_text_bytes_to_buffer` raises, or "" if none."""
    try:
        var b = decompress_text_bytes_to_buffer(span, path, cap)
        _ = b^
    except e:
        return String(e)
    return String("")


# =============================================================================
# is_compressed_text_path / _codec_for_path
# =============================================================================


def test_every_compressed_text_suffix_is_recognised() raises:
    """All twelve suffixes, in any case.
    MUTANT: drop any one arm of the cascade and its suffix reads False."""
    var formats = List[String]()
    formats.append(".csv"); formats.append(".jsonl")
    formats.append(".ndjson"); formats.append(".json")
    var codecs = List[String]()
    codecs.append(".gz"); codecs.append(".zst"); codecs.append(".lz4")
    for f in range(len(formats)):
        for c in range(len(codecs)):
            var p = String("dir/data") + formats[f] + codecs[c]
            assert_true(is_compressed_text_path(p), p)
            assert_true(is_compressed_text_path(p.upper()), p.upper())


def test_a_bare_codec_or_plain_text_suffix_is_not_compressed_text() raises:
    """A bare `.gz`, an uncompressed `.csv` and another format are not text
    the reader decompresses.
    MUTANT: a final `return True` makes every one of these True."""
    assert_false(is_compressed_text_path(String("x.gz")))
    assert_false(is_compressed_text_path(String("x.csv")))
    assert_false(is_compressed_text_path(String("x.parquet.zst")))
    assert_false(is_compressed_text_path(String("")))


def test_the_codec_follows_the_last_extension() raises:
    """`.gz` is GZIP, `.zst` ZSTD, `.lz4` LZ4_RAW (framing is decided later,
    from the bytes), in any case; anything else raises and names the path.
    MUTANT: swap the GZIP and ZSTD arms and the first two asserts fail."""
    assert_true(_codec_for_path(String("a.csv.GZ")) == CompressionCodec.GZIP)
    assert_true(_codec_for_path(String("a.csv.zst")) == CompressionCodec.ZSTD)
    assert_true(_codec_for_path(String("a.json.lz4")) == CompressionCodec.LZ4_RAW)
    var msg = String("")
    try:
        _ = _codec_for_path(String("a.csv.bz2"))
    except e:
        msg = String(e)
    assert_true("unrecognized compression extension" in msg, msg)
    assert_true("a.csv.bz2" in msg, msg)


def test_an_unrecognised_extension_raises_through_the_public_entry() raises:
    """The bytes entry asks `_codec_for_path` first, so a wrong extension
    raises before any decode.
    MUTANT: default the codec to GZIP and this decodes garbage instead."""
    var b = _text(10)
    var msg = _raises(Span(b), String("data.csv"))
    assert_true("unrecognized compression extension" in msg, msg)


# =============================================================================
# The two size hints
# =============================================================================


def test_the_first_guess_is_four_times_the_input_and_at_least_4_kib() raises:
    """MUTANT: drop the 4 KiB floor and a 10-byte input guesses 40 bytes."""
    assert_equal(_initial_output_guess(10), 4096)
    assert_equal(_initial_output_guess(1024), 4096)
    assert_equal(_initial_output_guess(1025), 4100)
    assert_equal(_initial_output_guess(1 << 20), 4 << 20)


def test_the_gzip_trailer_hint_needs_a_whole_gzip_frame() raises:
    """None for fewer than 18 bytes, for either magic byte wrong, and for an
    ISIZE of 0; otherwise the little-endian ISIZE.
    MUTANT: check only the first magic byte and the second case reads a
    hint off a non-gzip payload."""
    var b = List[UInt8](length=18, fill=0)
    b[0] = 0x1F
    b[1] = 0x8B
    b[14] = 0x10
    b[15] = 0x27  # ISIZE = 0x2710 = 10000
    var h = _gzip_isize_hint(Span(b))
    assert_true(Bool(h), "a whole frame gives a hint")
    assert_equal(h.value(), 10000)
    var short = List[UInt8](length=17, fill=0)
    short[0] = 0x1F
    short[1] = 0x8B
    assert_false(Bool(_gzip_isize_hint(Span(short))), "17 bytes")
    var bad1 = b.copy()
    bad1[1] = 0x8C
    assert_false(Bool(_gzip_isize_hint(Span(bad1))), "second magic byte")
    var bad0 = b.copy()
    bad0[0] = 0x1E
    assert_false(Bool(_gzip_isize_hint(Span(bad0))), "first magic byte")
    var zero = b.copy()
    zero[14] = 0
    zero[15] = 0
    assert_false(Bool(_gzip_isize_hint(Span(zero))), "ISIZE 0")


# =============================================================================
# Round trips, one per codec and hint shape
# =============================================================================


def test_gzip_with_a_trailer_larger_than_the_guess_decodes_in_one_shot() raises:
    """100,000 bytes of text gzip to far below 25,000, so the trailer hint
    (100,000) beats the 4x guess and is the first capacity. The decode is
    exact either way (the grow loop would recover a wrong guess), so this
    proves the round trip and reaches the `h > initial_cap` side.
    MUTANT: no capacity mutant shows here, since the grow loop recovers a
    wrong guess; `test_the_gzip_trailer_hint_needs_a_whole_gzip_frame`
    pins the hint itself, and the byte-exact compare fails on a wrong
    `set_length`."""
    var src = _text(100_000)
    var gz = _compress(CompressionCodec.GZIP, src)
    assert_true(len(gz) * 4 < 100_000, "the fixture must beat the guess")
    var out = decompress_text_bytes_to_buffer(Span(gz), String("t.csv.gz"))
    _assert_bytes(out, src)


def test_gzip_smaller_than_the_guess_keeps_the_guess() raises:
    """A 50-byte payload: the trailer says 50, the guess is 4096, the guess
    stays (plus the 64-byte pad) and the decode returns exactly 50 bytes.
    This reaches the `h <= initial_cap` side of the hint.
    MUTANT: `set_length(cap)` instead of the bytes written and the decoded
    length reads 4160, not 50."""
    var src = _text(50)
    var gz = _compress(CompressionCodec.GZIP, src)
    var out = decompress_text_bytes_to_buffer(Span(gz), String("t.jsonl.gz"))
    _assert_bytes(out, src)


def test_an_empty_gzip_payload_decodes_to_nothing() raises:
    """ISIZE 0 gives no hint (the `if hint` false side); the guess decodes an
    empty payload to zero bytes.
    MUTANT: `set_length(cap)` instead of the bytes written and the length
    reads 4096."""
    var src = List[UInt8]()
    var gz = _compress(CompressionCodec.GZIP, src)
    var out = decompress_text_bytes_to_buffer(Span(gz), String("t.ndjson.gz"))
    assert_equal(out.len(), 0)


def test_zstd_round_trips_and_grows_past_a_small_guess() raises:
    """A zstd payload has no hint here, so 200,000 bytes of text start at
    4x the compressed size and grow until they fit.
    MUTANT: re-raise on the first failure instead of growing and this
    raises."""
    var src = _text(200_000)
    var z = _compress(CompressionCodec.ZSTD, src)
    assert_true(len(z) * 4 < 200_000, "the fixture must need a grow")
    var out = decompress_text_bytes_to_buffer(Span(z), String("t.csv.zst"))
    _assert_bytes(out, src)


def test_a_raw_lz4_block_round_trips_and_grows() raises:
    """`.lz4` holding a raw block (not a frame) decodes through the parquet
    codec's LZ4_RAW arm, growing past the 4x guess.
    MUTANT: read every `.lz4` as a frame and this raises a frame error."""
    var src = _text(200_000)
    var raw = _compress(CompressionCodec.LZ4_RAW, src)
    assert_true(len(raw) * 4 < 200_000, "the fixture must need a grow")
    var out = decompress_text_bytes_to_buffer(Span(raw), String("t.json.lz4"))
    _assert_bytes(out, src)


def test_a_small_raw_lz4_block_decodes_in_one_shot() raises:
    """The raw-block arm without a grow.
    MUTANT: hand the raw block to the frame decoder and this raises."""
    var src = _text(300)
    var raw = _compress(CompressionCodec.LZ4_RAW, src)
    var out = decompress_text_bytes_to_buffer(Span(raw), String("t.csv.lz4"))
    _assert_bytes(out, src)


def test_an_lz4_frame_round_trips_and_grows_on_the_too_small_marker() raises:
    """A frame with no declared content size starts at the 4x guess; the
    frame decoder raises its too-small marker, which is the one frame error
    the loop grows on.
    MUTANT: drop the marker check (`find(...) < 0` read as always true) and
    the first too-small error is re-raised as a non-capacity failure."""
    var src = _text(200_000)
    var fr = _lz4_frame(src)
    assert_true(len(fr) * 4 < 200_000, "the fixture must need a grow")
    assert_false(
        Bool(lz4_frame_declared_content_size(Span(fr))),
        "the fixture must not declare its size, or no grow happens",
    )
    var out = decompress_text_bytes_to_buffer(Span(fr), String("t.csv.lz4"))
    _assert_bytes(out, src)


# =============================================================================
# Refusals
# =============================================================================


def _frame_declaring(size: Int) -> List[UInt8]:
    """A frame header that declares `size` bytes of content, followed by a
    body that is not a valid block: the decoder fails for a reason growing
    cannot fix."""
    var b = List[UInt8]()
    b.append(0x04); b.append(0x22); b.append(0x4D); b.append(0x18)  # magic
    b.append(0x68)  # FLG: version 01, block independence, content size
    b.append(0x40)  # BD: 64 KiB blocks
    for i in range(8):
        b.append(UInt8((size >> (8 * i)) & 0xFF))
    b.append(0x00)  # header checksum (wrong on purpose)
    for _ in range(16):
        b.append(0xFF)
    return b^


def test_malformed_frame_is_not_reported_as_a_size_limit() raises:
    """A frame that declares its size and then fails to decode is refused at
    once as NOT a capacity failure, at the declared capacity (+64), with no
    grow and no size story.
    MUTANT: grow on every frame error and this reaches the ceiling and
    reports a size limit instead."""
    var fr = _frame_declaring(1000)
    var msg = _raises(Span(fr), String("x.csv.lz4"))
    assert_true("LZ4 FRAME decode failed" in msg, msg)
    assert_true("NOT a capacity failure" in msg, msg)
    assert_true("output_capacity=1064" in msg, msg)
    assert_false("exceeds" in msg, msg)


def test_a_first_guess_above_the_ceiling_is_refused_before_any_decode() raises:
    """With a ceiling below the 4 KiB first guess the loop refuses before it
    allocates, and says no decoder ran.
    MUTANT: compare with `>=` instead of `>` at the top of the loop and a
    ceiling equal to the guess refuses too (the next test decodes there)."""
    var src = _text(1000)
    var z = _compress(CompressionCodec.ZSTD, src)
    var msg = _raises(Span(z), String("t.csv.zst"), 1000)
    assert_true("exceeds the 1000 byte cap" in msg, msg)
    assert_true("(none — first attempt)" in msg, msg)
    assert_true("framing=ZSTD" in msg, msg)


def test_a_ceiling_equal_to_the_first_guess_still_decodes() raises:
    """MUTANT: `cap >= max_output_cap` at the top of the loop refuses here."""
    var src = _text(1000)
    var z = _compress(CompressionCodec.ZSTD, src)
    var out = decompress_text_bytes_to_buffer(Span(z), String("t.csv.zst"), 4096)
    _assert_bytes(out, src)


def test_a_grow_past_the_ceiling_is_refused_with_the_last_decoder_error() raises:
    """The first attempt fails too small, the quadrupled capacity passes the
    ceiling, and the refusal carries the decoder's message and, for `.lz4`,
    the detected framing.
    MUTANT: drop `last_decode_error = _lz4_msg` and the message says no
    decoder ran."""
    var src = _text(200_000)
    var raw = _compress(CompressionCodec.LZ4_RAW, src)
    var msg = _raises(Span(raw), String("t.csv.lz4"), 10_000)
    assert_true("exceeds the 10000 byte cap" in msg, msg)
    assert_false("(none — first attempt)" in msg, msg)
    assert_true("framing=LZ4_RAW_BLOCK" in msg, msg)


def test_a_failure_at_exactly_the_ceiling_is_refused_as_the_last_attempt() raises:
    """With the ceiling at 4x the first guess the second attempt runs at the
    ceiling, fails, and is refused there rather than grown past it.
    MUTANT: drop the `cap >= max_output_cap` check and the loop grows once
    more and reports "exceeds" instead."""
    var src = _text(200_000)
    var raw = _compress(CompressionCodec.LZ4_RAW, src)
    var first = _initial_output_guess(len(raw))
    var msg = _raises(Span(raw), String("t.csv.lz4"), first * 4)
    assert_true("decompression failed at the maximum buffer of" in msg, msg)
    assert_true(String(first * 4) in msg, msg)


# =============================================================================
# The file entry point
# =============================================================================


def test_the_file_entry_reads_the_file_and_decodes_it() raises:
    """`decompress_text_file_to_buffer` slurps the file and delegates; the
    path's extension picks the codec.
    MUTANT: pass a wrong span (an empty one) and the decode fails."""
    var src = _text(5000)
    var gz = _compress(CompressionCodec.GZIP, src)
    var path = test_tmpdir() + "/decompress_reader_file.csv.gz"
    var fh = open(path, "w")
    fh.write_bytes(Span(gz))
    fh.close()
    var out = decompress_text_file_to_buffer(path)
    _assert_bytes(out, src)


def test_a_missing_file_raises() raises:
    """MUTANT: none; the open failure propagates from `read_chunked`."""
    var raised = False
    try:
        var b = decompress_text_file_to_buffer(
            test_tmpdir() + "/no_such_file.csv.gz"
        )
        _ = b^
    except:
        raised = True
    assert_true(raised)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
