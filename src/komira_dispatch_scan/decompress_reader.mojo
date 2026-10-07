# =============================================================================
# decompress_reader — whole-file decompression shim for line-oriented
#                     format readers (CSV, JSONL).
# =============================================================================
#
# CSV and JSONL are line-oriented text formats whose compression is signalled
# by FILE EXTENSION, not by an in-file header (unlike Parquet/ORC/Avro which
# embed the codec id in the file footer/header). The readers therefore need a
# boundary-level shim that:
#
#   1. Detects `.gz` / `.zst` / `.lz4` suffix on `path`.
#   2. Slurps the compressed bytes via `read_chunked(path)` (mmap-backed,
#      >2 GB safe per `komira_arrow_ipc.chunked_read`).
#   3. Allocates an output `OwnedAlignedBuffer` sized to the decompressed
#      length.
#   4. Calls `komira_parquet_codec.compression.decompress(codec, ...)` — the
#      already-wired libgz / libzstd / liblz4 page-level codec dispatch.
#   5. Returns a `SharedAlignedBuffer[HeapRegion]` whose `.len()` matches the
#      uncompressed byte count.
#
# The result is shape-compatible with `read_chunked(path)`, so an eager-decode
# reader can substitute it in place when the extension is compressed.
#
# Decompressed-size discovery (per-codec):
#   - GZIP:  read the ISIZE trailer (last 4 LE bytes of the gzip frame) for
#            the uncompressed length mod 2^32. For files <= 4 GiB this is
#            exact; for larger files the grow loop below takes over (rare in
#            practice — gzip text corpora rarely exceed 4 GiB raw).
#   - ZSTD:  no hint; the cap-and-grow loop handles it.
#   - LZ4:   framing is detected from the payload magic, not the extension.
#            An LZ4 FRAME may declare a Content Size in its header — used
#            directly when present. A raw block, and a frame that omits the
#            field (the common case), fall back to cap-and-grow.
#
# Cap-and-grow heuristic (the shape of the Avro codec's grow loops):
#   start at `max(4 * compressed_len, 4 KiB)`, retry quadrupling on
#   buffer-too-small failure, ceiling at 16 GiB (`max_output_cap`).
#
# Pointer rules:
#   - No `UnsafePointer` anywhere. Public API takes `String` / `Span` and
#     returns `SharedAlignedBuffer[HeapRegion]`; the codecs take Spans.
#   - No wildcard origins, no `unsafe_from_address=`, no partial moves.
#   - No environment reads.
# =============================================================================


from std.collections import Optional

from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_arrow_ipc.chunked_read import read_chunked
from komira_buffer.heap_region import HeapRegion
from komira_parquet_codec.compression import decompress as _parquet_decompress
from komira_parquet_codec.compression import (
    decompress_lz4_frame as _lz4_frame_decompress,
)
from komira_parquet_codec.compression import Lz4TextFraming
from komira_parquet_codec.compression import lz4_text_framing_of
from komira_parquet_codec.compression import lz4_frame_declared_content_size
from komira_parquet_api.types import CompressionCodec


# =============================================================================
# Extension detection — case-insensitive `.gz` / `.zst` / `.lz4` suffix on
# the inner format extension (`.csv.gz`, `.jsonl.gz`, `.ndjson.zst`, ...).
# =============================================================================


@always_inline
def _has_lower_suffix(lower_path: String, suf: StaticString) -> Bool:
    """`String.endswith` over a pre-lowered path. Centralized here so the
    cascade reads top-to-bottom without per-arm `path.lower()` calls."""
    return lower_path.endswith(String(suf))


def is_compressed_text_path(path: String) -> Bool:
    """Return True iff `path`'s extension marks it as a whole-file-compressed
    line-oriented text payload (CSV or JSONL/NDJSON variant).

    Recognized suffixes (case-insensitive):
      `.csv.gz`, `.csv.zst`, `.csv.lz4`,
      `.jsonl.gz`, `.jsonl.zst`, `.jsonl.lz4`,
      `.ndjson.gz`, `.ndjson.zst`, `.ndjson.lz4`,
      `.json.gz`,  `.json.zst`,  `.json.lz4`.

    Bare `.gz` / `.zst` / `.lz4` (without a preceding format suffix) are
    NOT matched — the caller dispatches on the OUTER format first (`.csv`
    vs `.jsonl`) and asks this helper "is this one of the compressed
    variants of my format?". The match below covers every variant the
    `WholeFileCompressed[Csv|Jsonl, Codec]` write path produces.
    """
    var lower = path.lower()
    # CSV variants
    if _has_lower_suffix(lower, ".csv.gz"):
        return True
    if _has_lower_suffix(lower, ".csv.zst"):
        return True
    if _has_lower_suffix(lower, ".csv.lz4"):
        return True
    # JSONL / NDJSON / JSON variants (line-oriented in all three cases as
    # produced by the WholeFileCompressed[Jsonl, _] write path).
    if _has_lower_suffix(lower, ".jsonl.gz"):
        return True
    if _has_lower_suffix(lower, ".jsonl.zst"):
        return True
    if _has_lower_suffix(lower, ".jsonl.lz4"):
        return True
    if _has_lower_suffix(lower, ".ndjson.gz"):
        return True
    if _has_lower_suffix(lower, ".ndjson.zst"):
        return True
    if _has_lower_suffix(lower, ".ndjson.lz4"):
        return True
    if _has_lower_suffix(lower, ".json.gz"):
        return True
    if _has_lower_suffix(lower, ".json.zst"):
        return True
    if _has_lower_suffix(lower, ".json.lz4"):
        return True
    return False


def _codec_for_path(path: String) raises -> CompressionCodec:
    """Map the trailing extension of `path` to the matching
    `CompressionCodec` enum value. `path` is assumed to satisfy
    `is_compressed_text_path` (caller's responsibility).
    """
    var lower = path.lower()
    if _has_lower_suffix(lower, ".gz"):
        return CompressionCodec.GZIP
    if _has_lower_suffix(lower, ".zst"):
        return CompressionCodec.ZSTD
    if _has_lower_suffix(lower, ".lz4"):
        return CompressionCodec.LZ4_RAW
    raise Error(
        String("decompress_reader: unrecognized compression extension on '")
        + path
        + String("' (expected .gz / .zst / .lz4)")
    )


# =============================================================================
# Decompressed-size hints
# =============================================================================
#
# Cap-and-grow constants — the shape of the Avro codec's output guess.
# The initial guess is conservative enough that 4x compression ratios on
# typical CSV/JSONL text payloads land in one shot; the grow loop handles
# the rare ratio > 4x case.

comptime _MIN_OUTPUT_GUESS: Int = 4096
comptime _MAX_OUTPUT_CAP: Int = 1 << 34  # 16 GiB ceiling — refuse beyond this.

# The ONE decoder error the grow loop may retry: liblz4's FRAME decoder raises this
# exact marker when the input is well-formed but the destination filled
# before the frame ended. Every other frame error is capacity-independent.
comptime _LZ4F_TOO_SMALL_MARKER: StaticString = "LZ4F dst buffer too small"


@always_inline
def _initial_output_guess(compressed_len: Int) -> Int:
    """First-cut decompressed-size guess from compressed length. 4x ratio
    is typical for CSV/JSONL text; the grow loop covers higher ratios."""
    var guess = compressed_len * 4
    if guess < _MIN_OUTPUT_GUESS:
        guess = _MIN_OUTPUT_GUESS
    return guess


def _gzip_isize_hint(compressed: Span[UInt8, _]) -> Optional[Int]:
    """Read the gzip ISIZE trailer (last 4 LE bytes of the frame) as the
    uncompressed length mod 2^32. Returns Some(hint) when the input is a
    plausible gzip frame (>= 18 bytes — gzip's minimum frame = 10-byte
    header + 8-byte trailer + 0-byte payload), else None.

    For files whose ACTUAL uncompressed size exceeds 4 GiB, the trailer's
    mod-2^32 hint is incomplete. The caller's grow-on-failure loop catches
    this and quadruples until success or `_MAX_OUTPUT_CAP`.
    """
    var n = len(compressed)
    if n < 18:
        return None
    # Gzip magic at offset 0: 0x1F 0x8B.
    if compressed[0] != UInt8(0x1F) or compressed[1] != UInt8(0x8B):
        return None
    # ISIZE = LE u32 at offset n-4.
    var b0 = Int(compressed[n - 4])
    var b1 = Int(compressed[n - 3])
    var b2 = Int(compressed[n - 2])
    var b3 = Int(compressed[n - 1])
    var isize = b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    if isize <= 0:
        # 0 is legal (empty file) but uninformative; treat as no-hint so
        # the cap-and-grow path runs with the minimum guess.
        return None
    return Optional[Int](isize)


# =============================================================================
# decompress_text_file_to_buffer — public entry
# =============================================================================


def decompress_text_file_to_buffer(path: String) raises -> SharedAlignedBuffer[HeapRegion]:
    """Slurp the compressed file at `path`, decompress its contents, and
    return a `SharedAlignedBuffer[HeapRegion]` containing the uncompressed
    bytes.

    The output is built in an `OwnedAlignedBuffer` (so the decoder can write
    it and `set_length` can trim it), then promoted via
    `SharedAlignedBuffer.from_owned(buf^)` at the return site.

    Output buffer shape matches `komira_arrow_ipc.chunked_read.read_chunked`:
    a 64-byte-aligned heap allocation with `length` set to the
    uncompressed byte count and `capacity` rounded up to the next 64-byte
    boundary for SIMD tail safety. Callers consume via
    `buf.view_range_ro(0, buf.len()).into_span()`.

    The on-disk encoding for each extension matches what the write path
    for `WholeFileCompressed[Csv|Jsonl, Codec]` (`komira_arrow.formats`)
    produces:
      - `.gz`:  zlib's `compress2` (zlib framing — but the read path's
                `inflateInit2_(15 + 32)` auto-detects gzip / zlib / raw,
                so externally-produced `.gz` files with true gzip framing
                also round-trip).
      - `.zst`: libzstd's `ZSTD_compress` (single frame).
      - `.lz4`: EITHER liblz4 encoding, decided by the payload's own
                leading bytes, NOT by the extension (which cannot say):
                  * LZ4 FRAME (magic 0x184D2204) — what `lz4(1)`,
                    python-lz4's `lz4.frame`, Kafka and every other
                    general-purpose producer emit.
                  * LZ4 RAW BLOCK — `LZ4_compress_default`, what
                    `komira_lz4.lz4_compress` produces.
                Both are read. Reading a frame as a raw block fails for
                EVERY output capacity, so the extension alone cannot pick
                the decoder; see `Lz4TextFraming` in
                `komira_parquet_codec/compression.mojo`.

    Args:
        path: Path to a compressed `.csv.{gz,zst,lz4}` or
              `.{jsonl,ndjson,json}.{gz,zst,lz4}` file.

    Returns:
        `SharedAlignedBuffer[HeapRegion]` whose `len()` == uncompressed byte
        count.

    Raises:
        Error on unrecognized extension, on file-open failure (raised by
        `read_chunked`), on a buffer-too-small grow loop exceeding
        `_MAX_OUTPUT_CAP` (16 GiB), or on codec-level decode failure
        (raised by `komira_parquet_codec.compression.decompress`).
    """
    var src_buf = read_chunked(path)
    var compressed_span = src_buf.view_range_ro(0, src_buf.len()).into_span()
    var out = decompress_text_bytes_to_buffer(compressed_span, path)
    _ = src_buf^
    return out^


def decompress_text_bytes_to_buffer(
    compressed_span: Span[UInt8, _],
    path: String,
    max_output_cap: Int = _MAX_OUTPUT_CAP,
) raises -> SharedAlignedBuffer[HeapRegion]:
    """Bytes-source twin of
    `decompress_text_file_to_buffer`. The cloud csv/json NATIVE read arm
    slurps a compressed object via `fs.read_at` (ranged GET) into an
    in-memory byte span, then feeds that span here. The codec is still
    detected from the path extension (cloud objects keep their `.csv.gz`
    suffix). The file-path variant slurps the file and delegates here, so
    both share one decode and cap-and-grow loop.

    Args:
        compressed_span: The compressed bytes (e.g. an S3 ranged-GET body).
        path: The URI/path (used only for codec-extension detection +
            error messages).
        max_output_cap: The largest output buffer the grow loop allocates
            (default `_MAX_OUTPUT_CAP`, 16 GiB); a payload that needs more
            raises.
    """
    var codec = _codec_for_path(path)
    var compressed_len = len(compressed_span)

    # `.lz4` NAMES TWO ENCODINGS (LZ4 frame vs bare raw block) and the
    # extension does not say which. Read it off the payload's own magic —
    # see the `Lz4TextFraming` block in `komira_parquet_codec/compression.mojo`.
    var lz4_framing = Lz4TextFraming.RAW_BLOCK
    var is_lz4_frame = False
    if codec == CompressionCodec.LZ4_RAW:
        lz4_framing = lz4_text_framing_of(compressed_span)
        is_lz4_frame = lz4_framing == Lz4TextFraming.FRAME
    # What the ceiling refusal below reports: the DETECTED lz4 framing, or
    # just the codec for the formats where framing is not a question.
    var framing_label = String(codec)
    if codec == CompressionCodec.LZ4_RAW:
        framing_label = String(lz4_framing)
    # The last decoder message seen, so a ceiling refusal can NAME the failure
    # instead of asserting a size story it never verified.
    var last_decode_error = String("(none — first attempt)")

    # Per-codec capacity hint.
    var initial_cap = _initial_output_guess(compressed_len)
    if is_lz4_frame:
        # A frame that declares its Content Size needs no guess at all.
        var declared = lz4_frame_declared_content_size(compressed_span)
        if declared:
            initial_cap = declared.value() + 64
    if codec == CompressionCodec.GZIP:
        var hint = _gzip_isize_hint(compressed_span)
        if hint:
            var h = hint.value()
            if h > initial_cap:
                initial_cap = h
            # Pad +64 so a tiny mod-2^32 over-read still fits without a grow.
            initial_cap = initial_cap + 64
    # ZSTD frame-content size: skip — calling `ZSTD_getFrameContentSize`
    # would introduce a second FFI declaration site here that duplicates
    # the one in `komira_parquet_codec/zstd/zstd_ffi.mojo`. The cap-and-grow
    # loop handles zstd files efficiently in practice: 1 retry covers ratios
    # up to 16x.
    # The decompress call below uses `_parquet_decompress` which already
    # owns the libzstd handle.

    # ⚠ ONE FRAME PATH. A second frame decode loop ahead of the shared one
    # would return first, grow on ANY error, and refuse at the ceiling with a
    # size story for a capacity-independent failure.
    # `test_malformed_frame_is_not_reported_as_a_size_limit` guards it.
    #
    # ONE detector (`lz4_text_framing_of`, shared with the parquet codec's
    # text path) and ONE grow policy, below. A
    # second copy of a four-byte magic check is not redundancy; it is a second
    # place for the policy to drift.
    var cap = initial_cap
    while True:
        if cap > max_output_cap:
            raise Error(
                String("decompress_reader: decompressed size exceeds the ")
                + String(max_output_cap)
                + String(" byte cap for path '")
                + path
                + String("' (compressed_len=")
                + String(compressed_len)
                + String(", framing=")
                + framing_label
                + String(", last decoder error: ")
                + last_decode_error
                + String(")")
            )
        # Allocate output buffer at current capacity.
        var out_buf = OwnedAlignedBuffer(cap)
        # `_parquet_decompress` returns the actual decompressed byte count
        # on success. On buffer-too-small, the underlying codec raises;
        # we catch, quadruple capacity, and retry.
        try:
            # The decoder writes into a span over all `cap` bytes of
            # `out_buf`, which outlives the synchronous call; `set_length`
            # then trims the buffer to the bytes written. No pointer leaves
            # this function.
            out_buf.set_length(Int64(cap))
            var out_span = out_buf.view_mut().into_span()
            var written: Int
            if is_lz4_frame:
                written = _lz4_frame_decompress(compressed_span, out_span)
            else:
                written = _parquet_decompress(codec, compressed_span, out_span)
            out_buf.set_length(Int64(written))

            return SharedAlignedBuffer[HeapRegion].from_owned(out_buf^)
        except e:
            # NON-CAPACITY LZ4-FRAME ERRORS ARE RE-RAISED HERE, NOT GROWN.
            # liblz4's frame decoder distinguishes a full destination from a
            # malformed frame; quadrupling against the latter only walks to
            # the ceiling and then reports a SIZE limit for a framing
            # or corruption defect. The other codecs cannot distinguish
            # (LZ4_decompress_safe returns one negative code for both), so
            # they keep the grow-and-retry policy described below.
            var _lz4_msg = String(e)
            if is_lz4_frame and _lz4_msg.find(_LZ4F_TOO_SMALL_MARKER) < 0:
                # No explicit `out_buf^` transfer here: the `raise` unwinds
                # the scope and the destructor frees it. Consuming it on only
                # ONE branch would leave the fall-through path below with a
                # conditionally-moved value.
                raise Error(
                    String(
                        "decompress_reader: LZ4 FRAME decode failed for"
                        " path '"
                    )
                    + path
                    + String("' (compressed_len=")
                    + String(compressed_len)
                    + String(", output_capacity=")
                    + String(cap)
                    + String("). This is NOT a capacity failure — growing"
                            " the buffer cannot fix it. Underlying: ")
                    + _lz4_msg
                )
            # Most codec errors are unrecoverable (corrupted frame,
            # invalid magic, etc.); only the buffer-too-small case wants
            # a retry. We can't distinguish from the Error message alone
            # (and Mojo 1.0.0b1 `Error` is not ImplicitlyCopyable so we
            # cannot capture it across loop iterations cheaply), so the
            # policy is: GROW at quadruple capacity, retry up to the
            # `max_output_cap` ceiling. If the next attempt also raises it
            # propagates naturally. This is the same shape as the Avro
            # codec's grow loops.
            #
            # `out_buf` is consumed here, before the loop head allocates
            # the next one (its destructor frees it).
            _ = out_buf^
            if cap >= max_output_cap:
                raise Error(
                    String(
                        "decompress_reader: decompression failed at the"
                        " maximum buffer of "
                    )
                    + String(max_output_cap)
                    + String(
                        " bytes; either codec input is corrupted or true"
                        " uncompressed size exceeds the cap. path='"
                    )
                    + path
                    + String("' (framing=")
                    + framing_label
                    + String(", last decoder error: ")
                    + _lz4_msg
                    + String(")")
                )
            last_decode_error = _lz4_msg
            # Quadruple — covers the worst plausible compression ratio
            # for text in one retry.
            var new_cap = cap * 4
            if new_cap < cap:  # overflow guard
                raise Error(  # cov: unreachable cap was allocated, so cap * 4 cannot wrap
                    String(  # cov: unreachable cap was allocated, so cap * 4 cannot wrap
                        "decompress_reader: capacity arithmetic overflow"
                        " in grow loop for path '"
                    )
                    + path  # cov: unreachable cap was allocated, so cap * 4 cannot wrap
                    + String("'")  # cov: unreachable cap was allocated, so cap * 4 cannot wrap
                )
            cap = new_cap
            # Loop again at the new cap.
