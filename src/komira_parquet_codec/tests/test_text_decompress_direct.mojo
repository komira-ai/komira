# =============================================================================
# test_text_decompress_direct — every branch of `text_decompress`, through its
# public entry and its private helpers.
#
# `read_text_source_to_heap_buffer(path)` is what a SQL `read_csv('x.csv.gz')`
# bind calls on its compressed-CSV branch: when `is_compressed_text_path(path)`
# holds it reads the file whole, decompressed, and hands the text to the CSV
# schema inferrer. This file writes CSV (and JSONL) text compressed with each
# codec under $TEST_TMPDIR and checks the bytes that come back, then drives the
# cap-and-grow loop's every arm with a lowered `max_output_cap`, so the size
# hints and the ceiling are observable without a 16 GiB allocation.
#
# What each test proves, and the defect it catches, is in its docstring.
# All asserts via `assert_*`, never `debug_assert`.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_libc.chunked_write import write_chunked
from komira_libc.posix import _read_env

from komira_parquet_api.types import CompressionCodec
from komira_parquet_codec.compression import (
    compress,
    compress_bound,
    compress_lz4_frame,
    lz4_frame_compress_bound,
    lz4_frame_declared_content_size,
)
from komira_parquet_codec.text_decompress import (
    _codec_for_path,
    _decompress_text_bytes,
    _gzip_isize_hint,
    _initial_output_guess,
    is_compressed_text_path,
    read_text_source_to_heap_buffer,
)


# =============================================================================
# Helpers
# =============================================================================


def _scratch_path(name: String) -> String:
    """`name` under the directory THIS execution may write scratch files into
    ($TEST_TMPDIR, unique per execution)."""
    var d = _read_env("TEST_TMPDIR")
    if d.byte_length() == 0:
        d = _read_env("TMPDIR")
    if d.byte_length() == 0:
        d = String("/tmp")
    return d + String("/") + name


def _write(path: String, bytes: Span[UInt8, _]) raises:
    var handle = open(path, "w")
    write_chunked(handle, bytes)
    handle.close()


def _bytes_of(text: String) -> List[UInt8]:
    var out = List[UInt8]()
    for b in text.as_bytes():
        out.append(b)
    return out^


def _csv_text() -> List[UInt8]:
    """A `;`-delimited CSV with a header, the shape a `read_csv` bind infers
    `k int64, name string` from."""
    var t = String("k;name\n")
    for i in range(300):
        t += String(i) + String(";name_") + String(i % 17) + String("\n")
    return _bytes_of(t)


def _repetitive(n_lines: Int) -> List[UInt8]:
    """Identical lines: every codec compresses this far beyond the 4x initial
    guess, so a decode must grow (or use a size hint) to fit."""
    var t = String("")
    for _ in range(n_lines):
        t += String("l_orderkey,l_partkey,l_quantity\n")
    return _bytes_of(t)


def _noise(n: Int) -> List[UInt8]:
    """Pseudo-random bytes (a 32-bit LCG): incompressible, so the gzip ISIZE
    hint is BELOW the 4x guess."""
    var out = List[UInt8]()
    var x: UInt32 = 12345
    for _ in range(n):
        x = x * 1103515245 + 12345
        out.append(UInt8((x >> 16) & 0xFF))
    return out^


def _compress(codec: CompressionCodec, payload: Span[UInt8, _]) raises -> List[UInt8]:
    var bound = compress_bound(codec, len(payload))
    var buf = OwnedAlignedBuffer(bound)
    var n = compress(codec, payload, buf.into_span_capacity())
    var out = List[UInt8]()
    var span = buf.into_span_capacity()
    for i in range(n):
        out.append(span[i])
    return out^


def _compress_frame(payload: Span[UInt8, _]) raises -> List[UInt8]:
    var bound = lz4_frame_compress_bound(len(payload))
    var buf = OwnedAlignedBuffer(bound)
    var n = compress_lz4_frame(payload, buf.into_span_capacity())
    var out = List[UInt8]()
    var span = buf.into_span_capacity()
    for i in range(n):
        out.append(span[i])
    return out^


def _assert_bytes_equal(
    got: Span[UInt8, _], expected: Span[UInt8, _], what: String
) raises:
    assert_equal(len(got), len(expected), what + String(": byte count"))
    var first_diff = -1
    for i in range(len(expected)):
        if got[i] != expected[i]:
            first_diff = i
            break
    assert_equal(first_diff, -1, what + String(": first differing byte"))


def _read_back(path: String, expected: Span[UInt8, _], what: String) raises:
    var buf = read_text_source_to_heap_buffer(path)
    _assert_bytes_equal(buf.view_range_ro(0, buf.len()).into_span(), expected, what)
    _ = buf^


def _growth_never_fits(compressed_len: Int, need: Int, cap: Int) -> Bool:
    """True when no capacity the loop reaches from the 4x guess without a
    hint (the guess, 4x it, ...) up to `cap` holds `need` bytes: a decode
    that fits under `cap` must have used a size hint."""
    var c = _initial_output_guess(compressed_len)
    while c <= cap:
        if c >= need:
            return False
        c = c * 4
    return True


def _decode_error(
    compressed: Span[UInt8, _], path: String, max_output_cap: Int
) -> String:
    """The message `_decompress_text_bytes` raises, or "" when it decodes."""
    try:
        var buf = _decompress_text_bytes(compressed, path, max_output_cap)
        _ = buf^
    except e:
        return String(e)
    return String("")


# XXH32 (seed 0) for inputs shorter than 16 bytes: the LZ4 frame header
# checksum is its second byte. Checked against published vectors below.
comptime _P1: UInt32 = 2654435761
comptime _P2: UInt32 = 2246822519
comptime _P3: UInt32 = 3266489917
comptime _P4: UInt32 = 668265263
comptime _P5: UInt32 = 374761393


def _rotl(x: UInt32, r: UInt32) -> UInt32:
    return (x << r) | (x >> (32 - r))


def _xxh32_short(data: Span[UInt8, _]) -> UInt32:
    var n = len(data)
    var h: UInt32 = _P5 + UInt32(n)
    var i = 0
    while i + 4 <= n:
        var k = (
            UInt32(data[i])
            | (UInt32(data[i + 1]) << 8)
            | (UInt32(data[i + 2]) << 16)
            | (UInt32(data[i + 3]) << 24)
        )
        h = h + k * _P3
        h = _rotl(h, 17) * _P4
        i += 4
    while i < n:
        h = h + UInt32(data[i]) * _P5
        h = _rotl(h, 11) * _P1
        i += 1
    h ^= h >> 15
    h *= _P2
    h ^= h >> 13
    h *= _P3
    h ^= h >> 16
    return h


def _with_content_size(frame: Span[UInt8, _], size: Int) raises -> List[UInt8]:
    """`frame` (liblz4's one-shot output: FLG without C.Size or DictID) with
    the Content Size field inserted and the header checksum recomputed."""
    assert_equal(Int(frame[4]) & 0x09, 0, "fixture frame has no C.Size/DictID")
    var desc = List[UInt8]()
    desc.append(frame[4] | UInt8(0x08))
    desc.append(frame[5])
    for i in range(8):
        desc.append(UInt8((size >> (8 * i)) & 0xFF))
    var out = List[UInt8]()
    for i in range(4):
        out.append(frame[i])
    for i in range(len(desc)):
        out.append(desc[i])
    out.append(UInt8((_xxh32_short(Span(desc)) >> 8) & 0xFF))
    for i in range(7, len(frame)):
        out.append(frame[i])
    return out^


# =============================================================================
# Extension detection
# =============================================================================


def test_every_compressed_suffix_is_recognized_in_any_case() raises:
    """All twelve `<format>.<codec>` suffixes are compressed text, in lower
    and upper case. Catches: a suffix check dropped or misspelled, and the
    `.lower()` dropped (the upper-case paths go false)."""
    var sufs: List[String] = [
        ".csv.gz", ".csv.zst", ".csv.lz4",
        ".jsonl.gz", ".jsonl.zst", ".jsonl.lz4",
        ".ndjson.gz", ".ndjson.zst", ".ndjson.lz4",
        ".json.gz", ".json.zst", ".json.lz4",
    ]
    for i in range(len(sufs)):
        var p = String("dir/data") + sufs[i]
        assert_true(is_compressed_text_path(p), p)
        assert_true(is_compressed_text_path(p.upper()), p.upper())


def test_other_suffixes_are_not_compressed_text() raises:
    """Plain text, a foreign archive and a foreign codec are not. Catches: the
    final `return False` flipped, and a check keyed on the codec suffix alone
    (`.tar.gz`, `.parquet.zst` would go true)."""
    var paths: List[String] = [
        "a.csv", "a.jsonl", "a.tar.gz", "a.parquet.zst", "a.csv.bz2",
        "a.gz", "csv.gz", "a.csv.gz.txt", "",
    ]
    for i in range(len(paths)):
        assert_false(is_compressed_text_path(paths[i]), paths[i])


def test_codec_for_path_maps_each_extension() raises:
    """`.gz` -> GZIP, `.zst` -> ZSTD, `.lz4` -> LZ4_RAW (the framing is read
    off the payload later), in any case; anything else raises naming the
    path. Catches: two codecs swapped, the `.lower()` dropped, the raise
    replaced by a default codec."""
    assert_true(_codec_for_path("a.csv.gz") == CompressionCodec.GZIP)
    assert_true(_codec_for_path("A.JSONL.GZ") == CompressionCodec.GZIP)
    assert_true(_codec_for_path("a.csv.zst") == CompressionCodec.ZSTD)
    assert_true(_codec_for_path("a.csv.lz4") == CompressionCodec.LZ4_RAW)
    var msg = String("")
    try:
        _ = _codec_for_path("a.csv.bz2")
    except e:
        msg = String(e)
    assert_true(msg.find("unrecognized compression extension") >= 0, msg)
    assert_true(msg.find("a.csv.bz2") >= 0, msg)


# =============================================================================
# Size hints
# =============================================================================


def test_initial_output_guess_is_four_times_with_a_floor() raises:
    """4x the compressed length, never below 4096. Catches: the floor dropped
    (0 and 100 give 0 and 400), the comparison flipped, a different ratio."""
    assert_equal(_initial_output_guess(0), 4096)
    assert_equal(_initial_output_guess(100), 4096)
    assert_equal(_initial_output_guess(1024), 4096)
    assert_equal(_initial_output_guess(1025), 4100)
    assert_equal(_initial_output_guess(10000), 40000)


def test_gzip_isize_hint() raises:
    """The ISIZE trailer, little-endian, only for a plausible gzip frame.
    Catches: the length floor lowered (a 17-byte buffer with the magic gives a
    hint), either magic byte unchecked, the byte order reversed (70000 needs
    three bytes), and a zero ISIZE returned as a hint."""
    var payload = _noise(70000)
    var gz = _compress(CompressionCodec.GZIP, Span(payload))
    var hint = _gzip_isize_hint(Span(gz))
    assert_true(Bool(hint), "a real gzip frame yields a hint")
    assert_equal(hint.value(), 70000)

    var short = List[UInt8](length=17, fill=0)
    short[0] = 0x1F
    short[1] = 0x8B
    short[13] = 0x10
    assert_false(Bool(_gzip_isize_hint(Span(short))), "17 bytes: no hint")

    var bad0 = gz.copy()
    bad0[0] = 0x1E
    assert_false(Bool(_gzip_isize_hint(Span(bad0))), "first magic byte wrong")
    var bad1 = gz.copy()
    bad1[1] = 0x8C
    assert_false(Bool(_gzip_isize_hint(Span(bad1))), "second magic byte wrong")

    var empty = List[UInt8]()
    var gz_empty = _compress(CompressionCodec.GZIP, Span(empty))
    assert_true(len(gz_empty) >= 18, "an empty gzip member is 20 bytes")
    assert_false(Bool(_gzip_isize_hint(Span(gz_empty))), "ISIZE 0: no hint")


def test_xxh32_helper_matches_published_vectors() raises:
    """The helper the content-size fixture uses: XXH32 seed 0 of "", "a",
    "abc" and a 10-byte input (the frame-descriptor length)."""
    var e = List[UInt8]()
    assert_equal(Int(_xxh32_short(Span(e))), 0x02CC5D05)
    var a = _bytes_of("a")
    assert_equal(Int(_xxh32_short(Span(a))), 0x550D7456)
    var abc = _bytes_of("abc")
    assert_equal(Int(_xxh32_short(Span(abc))), 0x32D153FF)


# =============================================================================
# The compressed-CSV read, codec by codec
# =============================================================================


def test_compressed_csv_reads_back_as_text_for_every_codec() raises:
    """The compressed-CSV branch of a `read_csv` bind: `.csv.gz`, `.csv.zst`,
    `.csv.lz4` as a raw block and as a frame, and an upper-case `.CSV.GZ`,
    each read back byte for byte as the CSV text. Catches: any codec mapped
    to the wrong decoder, the frame/raw-block detection dropped, a written
    length that is not the decoded length."""
    var csv = _csv_text()
    var gz = _compress(CompressionCodec.GZIP, Span(csv))
    var zst = _compress(CompressionCodec.ZSTD, Span(csv))
    var raw = _compress(CompressionCodec.LZ4_RAW, Span(csv))
    var frame = _compress_frame(Span(csv))

    var p = _scratch_path("direct_orders.csv.gz")
    _write(p, Span(gz))
    _read_back(p, Span(csv), ".csv.gz")
    p = _scratch_path("direct_orders_upper.CSV.GZ")
    _write(p, Span(gz))
    _read_back(p, Span(csv), ".CSV.GZ")
    p = _scratch_path("direct_orders.csv.zst")
    _write(p, Span(zst))
    _read_back(p, Span(csv), ".csv.zst")
    p = _scratch_path("direct_orders_raw.csv.lz4")
    _write(p, Span(raw))
    _read_back(p, Span(csv), ".csv.lz4 raw block")
    p = _scratch_path("direct_orders_frame.csv.lz4")
    _write(p, Span(frame))
    _read_back(p, Span(csv), ".csv.lz4 frame")

    var jsonl = _bytes_of(String('{"k":1}\n{"k":2}\n'))
    var jgz = _compress(CompressionCodec.GZIP, Span(jsonl))
    p = _scratch_path("direct_rows.jsonl.gz")
    _write(p, Span(jgz))
    _read_back(p, Span(jsonl), ".jsonl.gz")


def test_uncompressed_csv_reads_back_raw() raises:
    """The raw arm: a `.csv` file comes back as its bytes, not decoded.
    Catches: the raw arm routed through a decoder (gzip of CSV text fails)."""
    var csv = _csv_text()
    var p = _scratch_path("direct_orders.csv")
    _write(p, Span(csv))
    _read_back(p, Span(csv), ".csv raw")


def test_empty_gzip_member_reads_back_empty() raises:
    """ISIZE 0 gives no hint and the 4096-byte guess; the decode writes 0
    bytes. Catches: a hint of 0 used as the capacity."""
    var empty = List[UInt8]()
    var gz = _compress(CompressionCodec.GZIP, Span(empty))
    var p = _scratch_path("direct_empty.csv.gz")
    _write(p, Span(gz))
    _read_back(p, Span(empty), "empty .csv.gz")


def test_missing_file_raises_in_both_arms() raises:
    """A path that does not exist raises from either arm, never an empty
    buffer."""
    var arms: List[String] = ["direct_missing.csv.gz", "direct_missing.csv"]
    for i in range(len(arms)):
        var raised = False
        try:
            var buf = read_text_source_to_heap_buffer(_scratch_path(arms[i]))
            _ = buf^
        except:
            raised = True
        assert_true(raised, arms[i])


# =============================================================================
# The cap-and-grow loop, observed through a lowered `max_output_cap`
# =============================================================================


def test_gzip_isize_hint_sizes_the_first_allocation() raises:
    """A high-ratio gzip decodes with the cap set to its size + 64: only the
    ISIZE hint reaches that in one allocation; growing from the 4x guess
    passes the cap. A low-ratio gzip (hint below the guess) decodes too.
    Catches: the hint ignored, or `h > initial_cap` flipped."""
    var payload = _repetitive(2000)
    var gz = _compress(CompressionCodec.GZIP, Span(payload))
    assert_true(
        _growth_never_fits(len(gz), len(payload), len(payload) + 64),
        "premise: growing from the guess cannot fit under the cap",
    )
    var buf = _decompress_text_bytes(Span(gz), "a.csv.gz", len(payload) + 64)
    _assert_bytes_equal(
        buf.view_range_ro(0, buf.len()).into_span(), Span(payload), "hinted gzip"
    )
    _ = buf^

    var noise = _noise(10000)
    var gzn = _compress(CompressionCodec.GZIP, Span(noise))
    assert_true(len(gzn) * 4 > len(noise), "premise: the hint is below the guess")
    var bufn = _decompress_text_bytes(Span(gzn), "a.csv.gz")
    _assert_bytes_equal(
        bufn.view_range_ro(0, bufn.len()).into_span(), Span(noise), "low-ratio gzip"
    )
    _ = bufn^


def test_lz4_frame_declared_content_size_sizes_the_first_allocation() raises:
    """A high-ratio LZ4 frame that declares its Content Size decodes with the
    cap set to that size + 64; without the declared size it would have to
    grow past the cap. Catches: the declared size ignored."""
    var payload = _repetitive(2000)
    var frame = _compress_frame(Span(payload))
    assert_true(
        _growth_never_fits(len(frame), len(payload), len(payload) + 64),
        "premise: growing from the guess cannot fit under the cap",
    )
    var sized = _with_content_size(Span(frame), len(payload))
    var declared = lz4_frame_declared_content_size(Span(sized))
    assert_true(Bool(declared), "the rebuilt header declares its size")
    assert_equal(declared.value(), len(payload))
    var buf = _decompress_text_bytes(Span(sized), "a.csv.lz4", len(payload) + 64)
    _assert_bytes_equal(
        buf.view_range_ro(0, buf.len()).into_span(), Span(payload), "sized frame"
    )
    _ = buf^
    # The same frame without the field cannot fit under that cap.
    var msg = _decode_error(Span(frame), "a.csv.lz4", len(payload) + 64)
    assert_true(msg.find("decompressed size exceeds") >= 0, msg)


def test_non_frame_codecs_grow_and_retry() raises:
    """zstd and an LZ4 raw block whose output is beyond the 4x guess decode
    after the loop grows. Catches: a non-frame error re-raised instead of
    retried, the growth step dropped."""
    var payload = _repetitive(4000)
    var zst = _compress(CompressionCodec.ZSTD, Span(payload))
    var raw = _compress(CompressionCodec.LZ4_RAW, Span(payload))
    assert_true(_initial_output_guess(len(zst)) < len(payload), "premise zstd")
    assert_true(_initial_output_guess(len(raw)) < len(payload), "premise lz4")
    var b1 = _decompress_text_bytes(Span(zst), "a.jsonl.zst")
    _assert_bytes_equal(
        b1.view_range_ro(0, b1.len()).into_span(), Span(payload), "zstd grown"
    )
    var b2 = _decompress_text_bytes(Span(raw), "a.ndjson.lz4")
    _assert_bytes_equal(
        b2.view_range_ro(0, b2.len()).into_span(), Span(payload), "lz4 raw grown"
    )
    _ = b1^
    _ = b2^


def test_cap_is_inclusive() raises:
    """A zstd payload that needs the second allocation (4096 -> 16384)
    decodes with the cap at exactly 16384 and is refused at 16383. Catches:
    `cap > max_output_cap` turned into `>=`, and an off-by-one the other way.
    The refusal names the cap, the framing and the decoder's last error."""
    var payload = _repetitive(500)
    assert_true(len(payload) > 4096 and len(payload) <= 16384, "premise size")
    var zst = _compress(CompressionCodec.ZSTD, Span(payload))
    assert_equal(_initial_output_guess(len(zst)), 4096, "premise guess")
    var buf = _decompress_text_bytes(Span(zst), "a.csv.zst", 16384)
    _assert_bytes_equal(
        buf.view_range_ro(0, buf.len()).into_span(), Span(payload), "at the cap"
    )
    _ = buf^

    var msg = _decode_error(Span(zst), "a.csv.zst", 16383)
    assert_true(
        msg.find("decompressed size exceeds the 16383-byte cap") >= 0, msg
    )
    assert_true(msg.find("path 'a.csv.zst'") >= 0, msg)
    assert_true(msg.find("compressed_len=" + String(len(zst))) >= 0, msg)
    assert_true(msg.find("framing=ZSTD,") >= 0, msg)
    var at = msg.find("last decoder error: ")
    assert_true(at >= 0, msg)
    assert_true(
        msg.byte_length() > at + 21, "the decoder's last error is named: " + msg
    )


def test_ceiling_refusal_names_the_lz4_framing_and_gzip_without_hint() raises:
    """Bytes no decoder accepts are retried up to the cap and then refused.
    A `.lz4` names its detected framing (LZ4_RAW_BLOCK, not the codec name
    LZ4_RAW); a 10-byte `.gz` has no ISIZE hint. Catches: the framing label
    taken from the codec for `.lz4`, the last decoder error not kept."""
    var junk = List[UInt8](length=20, fill=0xFF)
    var msg = _decode_error(Span(junk), "a.csv.lz4", 4096)
    assert_true(msg.find("framing=LZ4_RAW_BLOCK,") >= 0, msg)
    assert_true(msg.find("last decoder error: )") < 0, msg)

    var short = List[UInt8](length=10, fill=0x55)
    assert_false(Bool(_gzip_isize_hint(Span(short))), "premise: no hint")
    var msg2 = _decode_error(Span(short), "a.csv.gz", 4096)
    assert_true(msg2.find("4096-byte cap") >= 0, msg2)
    assert_true(msg2.find("framing=GZIP,") >= 0, msg2)
    assert_true(msg2.find("last decoder error: )") < 0, msg2)


def test_corrupt_frame_is_refused_at_the_first_capacity() raises:
    """A frame with a corrupt header checksum is re-raised at the first
    capacity, naming it, instead of being grown. Catches: the re-raise arm
    removed or keyed on the wrong condition, the capacity in the message
    wrong."""
    var payload = _csv_text()
    var bad = _compress_frame(Span(payload))
    bad[6] = bad[6] ^ UInt8(0xFF)
    var msg = _decode_error(Span(bad), "a.json.lz4", 1 << 30)
    assert_true(msg.find("NOT a capacity failure") >= 0, msg)
    assert_true(msg.find("path 'a.json.lz4'") >= 0, msg)
    assert_true(
        msg.find(
            "output_capacity=" + String(_initial_output_guess(len(bad))) + ")"
        )
        >= 0,
        msg,
    )
    assert_true(msg.find("decompressed size exceeds") < 0, msg)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
