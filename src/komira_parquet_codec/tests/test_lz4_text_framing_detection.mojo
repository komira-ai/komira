# =============================================================================
# test_lz4_text_framing_detection — `.lz4` text files carry one of TWO
# encodings, and `read_text_source_to_heap_buffer` must tell them apart.
#
# `.csv.lz4` carries no codec id, so the extension cannot say which of liblz4's
# encodings the file holds: LZ4 FRAME (magic 0x184D2204, what `lz4(1)`,
# python-lz4's `lz4.frame`, Kafka and pyarrow emit) or a RAW BLOCK (what
# `LZ4_compress_default` and this package's LZ4_RAW writer emit). Two defects
# are each pinned by their own assertion, because a test that merely asserts
# "the file reads" passes for either fix:
#
#   (1) FRAMING. Mapping `.lz4` to `CompressionCodec.LZ4_RAW` unconditionally
#       sends a frame to `LZ4_decompress_safe`, a BLOCK-format call that reads
#       the frame magic as a block token and fails at EVERY output capacity.
#       Growing the buffer can never work. Pinned by `test_framing_selector_*`
#       and the two round-trip tests.
#
#   (2) DIAGNOSIS. A cap-and-grow loop that catches EVERY exception and
#       quadruples reports a capacity-independent failure as "decompressed
#       size exceeds the cap". Pinned by
#       `test_scanframe_malformed_frame_is_not_reported_as_a_size_limit`.
#
# THE MUTATIONS THIS FILE CATCHES:
#   * `lz4_text_framing_of` always returning RAW_BLOCK   -> selector tests RED
#   * `is_lz4_frame = False` in `_decompress_text_bytes`  -> round-trip RED
#   * restoring the blind `except: cap = cap * 4`        -> diagnosis test RED
#   * flipping `.lz4` statically to the FRAME decoder    -> raw-block RED
#
# Files are written under $TEST_TMPDIR (unique per execution), never a fixed
# `/tmp` path. All asserts via `assert_*`, never `debug_assert`.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_libc.chunked_write import write_chunked
from komira_libc.posix import _read_env

from komira_parquet_codec.compression import (
    Lz4TextFraming,
    compress as _codec_compress,
    compress_bound as _codec_compress_bound,
    compress_lz4_frame,
    lz4_frame_compress_bound,
    lz4_frame_declared_content_size,
    lz4_text_framing_of,
)
from komira_parquet_codec.text_decompress import read_text_source_to_heap_buffer
from komira_parquet_api.types import CompressionCodec


# =============================================================================
# Fixtures — built in-process, so this test needs no data files.
# =============================================================================


def _csv_payload() -> List[UInt8]:
    """A recognizable CSV text payload, shaped like a lineitem table (a header
    line + N comma-separated numeric rows).

    Deliberately compressible: LZ4 must actually emit matches, so a decode
    that silently returned the input unchanged would not pass the byte
    comparison below.
    """
    var out = List[UInt8]()
    var header = String("l_orderkey,l_partkey,l_quantity\n")
    for b in header.as_bytes():
        out.append(b)
    for i in range(4000):
        var line = (
            String(i)
            + String(",")
            + String((i * 7) % 1000)
            + String(",")
            + String(i % 50)
            + String("\n")
        )
        for b in line.as_bytes():
            out.append(b)
    return out^


def _compress_frame(payload: Span[UInt8, _]) raises -> OwnedAlignedBuffer:
    """LZ4 FRAME (magic 0x184D2204) — what `lz4(1)`, python-lz4's
    `lz4.frame`, Kafka and pyarrow emit."""
    var bound = lz4_frame_compress_bound(len(payload))
    var buf = OwnedAlignedBuffer(bound)
    var n = compress_lz4_frame(payload, buf.into_span_capacity())
    buf.set_length(Int64(n))
    return buf^


def _compress_raw_block(payload: Span[UInt8, _]) raises -> OwnedAlignedBuffer:
    """LZ4 RAW BLOCK (`LZ4_compress_default`) — no header, no magic, no
    stored length. What this package's LZ4_RAW writer produces."""
    var bound = _codec_compress_bound(CompressionCodec.LZ4_RAW, len(payload))
    var buf = OwnedAlignedBuffer(bound)
    var n = _codec_compress(
        CompressionCodec.LZ4_RAW, payload, buf.into_span_capacity()
    )
    buf.set_length(Int64(n))
    return buf^


def _write(path: String, bytes: Span[UInt8, _]) raises:
    var handle = open(path, "w")
    write_chunked(handle, bytes)
    handle.close()


def _scratch_path(name: String) -> String:
    """`name` under the directory THIS execution may write scratch files into
    ($TEST_TMPDIR, unique per execution)."""
    var d = _read_env("TEST_TMPDIR")
    if d.byte_length() == 0:
        d = _read_env("TMPDIR")
    if d.byte_length() == 0:
        d = String("/tmp")
    return d + String("/") + name


def _assert_bytes_equal(
    got: Span[UInt8, _], expected: Span[UInt8, _], what: String
) raises:
    assert_equal(
        len(got),
        len(expected),
        what + String(": decoded byte COUNT"),
    )
    var first_diff = -1
    for i in range(len(expected)):
        if got[i] != expected[i]:
            first_diff = i
            break
    assert_equal(
        first_diff, -1, what + String(": first differing byte offset")
    )


# =============================================================================
# (1) THE SELECTOR — asserted directly, so a round-trip that passes for the
#     wrong reason cannot stand in for it.
# =============================================================================


def test_framing_selector_identifies_a_real_lz4_frame() raises:
    var payload = _csv_payload()
    var frame = _compress_frame(Span(payload))
    var span = frame.view_range_ro(0, frame.len()).into_span()

    # The four magic bytes, spelled out: this is the whole basis of the
    # classification and the reason it is an identification, not a guess.
    assert_equal(Int(span[0]), 0x04, "frame magic byte 0")
    assert_equal(Int(span[1]), 0x22, "frame magic byte 1")
    assert_equal(Int(span[2]), 0x4D, "frame magic byte 2")
    assert_equal(Int(span[3]), 0x18, "frame magic byte 3")

    assert_true(
        lz4_text_framing_of(span) == Lz4TextFraming.FRAME,
        String("a real LZ4 frame must classify FRAME, got ")
        + String(lz4_text_framing_of(span)),
    )
    _ = frame^
    _ = payload^


def test_framing_selector_identifies_a_raw_block() raises:
    """The other half, and the reason the fix is DETECTION and not a static
    flip to the frame decoder: this package's own writer emits raw blocks."""
    var payload = _csv_payload()
    var raw = _compress_raw_block(Span(payload))
    var span = raw.view_range_ro(0, raw.len()).into_span()
    assert_true(
        lz4_text_framing_of(span) == Lz4TextFraming.RAW_BLOCK,
        String("a raw LZ4 block must classify RAW_BLOCK, got ")
        + String(lz4_text_framing_of(span)),
    )
    _ = raw^
    _ = payload^


def test_framing_selector_needs_all_four_magic_bytes() raises:
    """Each magic byte is load-bearing. A selector that keyed on a prefix
    (or on length alone) would pass the two tests above and still
    misclassify; mutating each byte in turn is what forbids that."""
    var good = List[UInt8]()
    good.append(0x04)
    good.append(0x22)
    good.append(0x4D)
    good.append(0x18)
    good.append(0x64)
    assert_true(
        lz4_text_framing_of(Span(good)) == Lz4TextFraming.FRAME,
        "the intact magic classifies FRAME",
    )

    for pos in range(4):
        var bad = good.copy()
        bad[pos] = bad[pos] ^ UInt8(0xFF)
        assert_true(
            lz4_text_framing_of(Span(bad)) == Lz4TextFraming.RAW_BLOCK,
            String("mutating magic byte ")
            + String(pos)
            + String(" must fall back to RAW_BLOCK"),
        )

    # Too short to carry a magic at all -> RAW_BLOCK, never a crash.
    var short = List[UInt8]()
    short.append(0x04)
    short.append(0x22)
    short.append(0x4D)
    assert_true(
        lz4_text_framing_of(Span(short)) == Lz4TextFraming.RAW_BLOCK,
        "a 3-byte payload cannot be a frame",
    )
    var empty = List[UInt8]()
    assert_true(
        lz4_text_framing_of(Span(empty)) == Lz4TextFraming.RAW_BLOCK,
        "an empty payload cannot be a frame",
    )


def test_frame_content_size_is_optional_and_absent_here() raises:
    """★ A decoder should not have to guess an output size for a
    self-describing container — and for the frames that declare one it no
    longer does. But the field is OPTIONAL and is usually absent: liblz4's
    one-shot `LZ4F_compressFrame` (FLG=0x64, bit 3 clear) omits it.

    So this asserts the honest shape: `None` here, which is exactly why the
    grow loop must stay live and must not be replaced by a content-size-only
    path. A hint read out of a header that has no hint would be a length read
    off the block payload.
    """
    var payload = _csv_payload()
    var frame = _compress_frame(Span(payload))
    var span = frame.view_range_ro(0, frame.len()).into_span()
    var declared = lz4_frame_declared_content_size(span)
    assert_false(
        Bool(declared),
        "LZ4F_compressFrame does not write Content Size; the reader must not"
        " claim it did",
    )

    # A raw block has no header at all — never interpret its bytes as one.
    var raw = _compress_raw_block(Span(payload))
    var raw_span = raw.view_range_ro(0, raw.len()).into_span()
    assert_false(
        Bool(lz4_frame_declared_content_size(raw_span)),
        "a raw block declares no content size",
    )

    # A hand-built header WITH the C.Size bit set must be read exactly.
    # FLG 0x6C = version 01 | B.Indep | C.Size | C.Checksum.
    var hdr = List[UInt8]()
    hdr.append(0x04)
    hdr.append(0x22)
    hdr.append(0x4D)
    hdr.append(0x18)
    hdr.append(0x6C)  # FLG, bit 3 (C.Size) SET
    hdr.append(0x70)  # BD
    # Content Size = 849086836, little-endian u64.
    var expected_size = 849086836
    for i in range(8):
        hdr.append(UInt8((expected_size >> (8 * i)) & 0xFF))
    hdr.append(0x00)  # HC
    var got = lz4_frame_declared_content_size(Span(hdr))
    assert_true(Bool(got), "a C.Size-bearing header must yield a hint")
    assert_equal(
        got.value(), expected_size, "declared content size, little-endian u64"
    )

    # Same header with the C.Size bit CLEARED must yield nothing, even though
    # the eight bytes are still sitting there.
    var no_size = hdr.copy()
    no_size[4] = 0x64
    assert_false(
        Bool(lz4_frame_declared_content_size(Span(no_size))),
        "clearing the C.Size flag must suppress the hint, not read past it",
    )

    _ = frame^
    _ = raw^
    _ = payload^


# =============================================================================
# (1) THE CONSEQUENCE — through the read entry point.
# =============================================================================


def test_scanframe_path_reads_a_frame_format_csv_lz4() raises:
    """`komira_parquet_codec.text_decompress.read_text_source_to_heap_buffer`.

    RED before the fix: `.lz4` -> LZ4_RAW -> `LZ4_decompress_safe` refuses the
    frame at every capacity -> the grow loop quadruples to the 16 GiB ceiling
    -> raises.
    """
    var payload = _csv_payload()
    var frame = _compress_frame(Span(payload))
    var path = _scratch_path("komira_lz4_framing_scanframe_frame.csv.lz4")
    _write(path, frame.view_range_ro(0, frame.len()).into_span())

    var buf = read_text_source_to_heap_buffer(path)
    _assert_bytes_equal(
        buf.view_range_ro(0, buf.len()).into_span(),
        Span(payload),
        "frame-format .csv.lz4 through read_text_source_to_heap_buffer",
    )
    _ = buf^
    _ = frame^
    _ = payload^


def test_scanframe_path_still_reads_a_raw_block_csv_lz4() raises:
    """The anti-overcorrection guard. Statically re-pointing `.lz4` at the
    FRAME decoder would make the test above pass and BREAK every file this
    package's own LZ4_RAW writer produces. Both encodings must read.
    """
    var payload = _csv_payload()
    var raw = _compress_raw_block(Span(payload))
    var path = _scratch_path("komira_lz4_framing_scanframe_rawblock.csv.lz4")
    _write(path, raw.view_range_ro(0, raw.len()).into_span())

    var buf = read_text_source_to_heap_buffer(path)
    _assert_bytes_equal(
        buf.view_range_ro(0, buf.len()).into_span(),
        Span(payload),
        "raw-block .csv.lz4 through read_text_source_to_heap_buffer",
    )
    _ = buf^
    _ = raw^
    _ = payload^


# =============================================================================
# (2) THE GROW-RETRY ARM AND THE DIAGNOSIS. Both survive the tests above:
#     neutering the FRAME re-raise (`if is_lz4_frame and ...` ->
#     `if False and ...`), and breaking the FRAME grow-retry arm.
# =============================================================================


def _repetitive_payload() -> List[UInt8]:
    """A payload whose compression ratio is FAR above the reader's 4x initial
    guess, so the decode cannot fit in `_initial_output_guess` and the grow
    loop must actually iterate. Identical repeated lines compress ~100x+.
    """
    var out = List[UInt8]()
    var line = String("l_orderkey,l_partkey,l_quantity\n")
    for _ in range(60000):
        for b in line.as_bytes():
            out.append(b)
    return out^


def test_frame_needing_a_grow_iteration_still_decodes() raises:
    """★ THE ARM THAT DECIDES WHETHER THE FIX REGRESSED THE COMMON CASE.

    `_initial_output_guess` allocates 4x the compressed length. A frame whose
    ratio exceeds 4x — routine for repetitive CSV/JSONL — CANNOT fit, so the
    loop must grow and retry. The fix made a non-capacity frame error a hard
    re-raise, matched on the literal `LZ4F dst buffer too small` marker. If
    liblz4's frame wrapper ever fails to emit that exact marker for a full
    destination, EVERY high-ratio frame becomes an immediate
    "NOT a capacity failure" refusal — strictly worse than the pre-fix grow
    loop, and invisible to a test whose fixture fits in the first allocation
    (the ones above all do).
    """
    var payload = _repetitive_payload()
    var frame = _compress_frame(Span(payload))
    var span = frame.view_range_ro(0, frame.len()).into_span()

    # The premise: this really does need a grow iteration, or the test is
    # vacuous. 4x the compressed length must fall short of the payload.
    assert_true(
        len(span) * 4 < len(payload),
        String(
            "fixture must not fit the 4x initial guess, else the grow arm is"
            " never entered: compressed="
        )
        + String(len(span))
        + String(" payload=")
        + String(len(payload)),
    )
    assert_true(
        lz4_text_framing_of(span) == Lz4TextFraming.FRAME,
        "fixture must be a frame",
    )

    var path = _scratch_path("komira_lz4_framing_grow_frame.csv.lz4")
    _write(path, span)
    var buf = read_text_source_to_heap_buffer(path)
    _assert_bytes_equal(
        buf.view_range_ro(0, buf.len()).into_span(),
        Span(payload),
        "high-ratio frame through read_text_source_to_heap_buffer",
    )

    _ = buf^
    _ = frame^
    _ = payload^


def test_scanframe_malformed_frame_is_not_reported_as_a_size_limit() raises:
    """★ THE DIAGNOSIS. Corrupt the frame's HEADER CHECKSUM byte, leaving the
    magic intact, and read it through `read_text_source_to_heap_buffer`.

    The payload is still positively identified as a frame, and liblz4's frame
    decoder rejects it for a reason that has nothing to do with the
    destination buffer. A loop that caught that and quadrupled would hit the
    ceiling and blame a size limit. Deleting the re-raise arm turns this RED.
    """
    var payload = _csv_payload()
    var frame = _compress_frame(Span(payload))
    var bad = List[UInt8]()
    var span = frame.view_range_ro(0, frame.len()).into_span()
    for i in range(len(span)):
        bad.append(span[i])
    # Offset 6 = header checksum for a header with neither C.Size nor DictID.
    bad[6] = bad[6] ^ UInt8(0xFF)
    assert_true(
        lz4_text_framing_of(Span(bad)) == Lz4TextFraming.FRAME,
        "corrupting the header checksum must not change the classification",
    )

    var path = _scratch_path("komira_lz4_framing_scanframe_corrupt.csv.lz4")
    _write(path, Span(bad))

    var raised = False
    var msg = String("")
    try:
        var buf = read_text_source_to_heap_buffer(path)
        _ = buf^
    except e:
        raised = True
        msg = String(e)

    assert_true(raised, "a corrupt LZ4 frame must not decode silently")
    assert_true(
        msg.find("NOT a capacity failure") >= 0,
        String(
            "the refusal must state that growing cannot help. Got: "
        )
        + msg,
    )
    assert_true(
        msg.find("decompressed size exceeds") < 0,
        String(
            "the refusal must NOT blame the size cap for a"
            " capacity-independent decode failure. Got: "
        )
        + msg,
    )

    _ = frame^
    _ = payload^


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
