# =============================================================================
# komira_parquet_codec.text_decompress — whole-file text (CSV / JSONL) read that
#   DECOMPRESSES a `.gz/.zst/.lz4` suffix.
# =============================================================================
#
# `read_text_source_to_heap_buffer(path)` reads a line-oriented text file whole.
# When the extension marks a whole-file-compressed payload (`.csv.gz`,
# `.jsonl.zst`, `.ndjson.lz4`, ...) it decompresses it with this package's
# codecs (`compression.mojo`: libz, libzstd, liblz4); otherwise it reads the
# raw bytes. A reader that slurped a `.csv.gz` raw would hand its parser
# gzip-frame bytes instead of CSV text.
#
# It returns a UNIFIED `SharedAlignedBuffer[HeapRegion]` in both the compressed
# and raw arms (the raw `read_chunked` mmap buffer is promoted via
# `realign_to[64]`, matching the decompressed arm's type), so a caller consumes
# `buf.view_range_ro(0, buf.len()).into_span()` uniformly regardless of
# compression.
#
# The module lives in this package, not in komira_compression, because it
# reads files with komira_arrow_ipc's `read_chunked`, and komira_arrow_ipc
# depends on komira_compression.
#
# Encapsulation: the public API takes `String` and returns
# `SharedAlignedBuffer[HeapRegion]`; the decode calls take Spans, so this
# module takes no pointer at all.
# =============================================================================

from std.collections import Optional

from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_arrow_ipc.chunked_read import read_chunked
from komira_buffer.heap_region import HeapRegion

from .compression import decompress as _parquet_decompress
from .compression import decompress_lz4_frame as _lz4_frame_decompress
from .compression import Lz4TextFraming
from .compression import lz4_text_framing_of
from .compression import lz4_frame_declared_content_size
from komira_parquet_api.types import CompressionCodec


# =============================================================================
# Extension detection — case-insensitive `.gz` / `.zst` / `.lz4` on the inner
# format extension (`.csv.gz`, `.jsonl.gz`, `.ndjson.zst`, `.json.lz4`, ...).
# =============================================================================


@always_inline
def _has_lower_suffix(lower_path: String, suf: StaticString) -> Bool:
    return lower_path.endswith(String(suf))


def is_compressed_text_path(path: String) -> Bool:
    """Return True iff `path`'s extension marks it as a whole-file-compressed
    line-oriented text payload (CSV or JSONL/NDJSON/JSON variant).

    Recognized suffixes (case-insensitive):
      `.csv.{gz,zst,lz4}`, `.jsonl.{gz,zst,lz4}`, `.ndjson.{gz,zst,lz4}`,
      `.json.{gz,zst,lz4}`."""
    var lower = path.lower()
    if _has_lower_suffix(lower, ".csv.gz"):
        return True
    if _has_lower_suffix(lower, ".csv.zst"):
        return True
    if _has_lower_suffix(lower, ".csv.lz4"):
        return True
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
    """Map the trailing extension of `path` to the matching `CompressionCodec`.
    `path` is assumed to satisfy `is_compressed_text_path` (caller's
    responsibility)."""
    var lower = path.lower()
    if _has_lower_suffix(lower, ".gz"):
        return CompressionCodec.GZIP
    if _has_lower_suffix(lower, ".zst"):
        return CompressionCodec.ZSTD
    if _has_lower_suffix(lower, ".lz4"):
        return CompressionCodec.LZ4_RAW
    raise Error(
        String("text_decompress: unrecognized compression extension on '")
        + path
        + String("' (expected .gz / .zst / .lz4)")
    )


# =============================================================================
# Decompressed-size hints + cap-and-grow constants.
# =============================================================================

comptime _MIN_OUTPUT_GUESS: Int = 4096
comptime _MAX_OUTPUT_CAP: Int = 1 << 34  # 16 GiB ceiling — refuse beyond this.

# The ONE error the grow loop is allowed to retry: liblz4's frame decoder
# raises this exact marker (`lz4_ffi._lz4_frame_decompress_into`) when the input
# is well-formed but the destination filled before the frame ended. Any OTHER
# frame error is capacity-independent and quadrupling cannot fix it.
comptime _LZ4F_TOO_SMALL_MARKER: StaticString = "LZ4F dst buffer too small"


@always_inline
def _initial_output_guess(compressed_len: Int) -> Int:
    """First-cut decompressed-size guess from compressed length (4x ratio is
    typical for CSV/JSONL text; the grow loop covers higher ratios)."""
    var guess = compressed_len * 4
    if guess < _MIN_OUTPUT_GUESS:
        guess = _MIN_OUTPUT_GUESS
    return guess


def _gzip_isize_hint(compressed: Span[UInt8, _]) -> Optional[Int]:
    """Read the gzip ISIZE trailer (last 4 LE bytes) as the uncompressed length
    mod 2^32. Returns Some(hint) for a plausible gzip frame (>= 18 bytes), else
    None. Files > 4 GiB raw get an incomplete mod-2^32 hint; the grow loop
    covers that."""
    var n = len(compressed)
    if n < 18:
        return None
    if compressed[0] != UInt8(0x1F) or compressed[1] != UInt8(0x8B):
        return None
    var b0 = Int(compressed[n - 4])
    var b1 = Int(compressed[n - 3])
    var b2 = Int(compressed[n - 2])
    var b3 = Int(compressed[n - 1])
    var isize = b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    if isize <= 0:
        return None
    return Optional[Int](isize)


def _decompress_text_bytes(
    compressed_span: Span[UInt8, _], path: String,
    max_output_cap: Int = _MAX_OUTPUT_CAP,
) raises -> SharedAlignedBuffer[HeapRegion]:
    """Decompress a compressed byte span to a `SharedAlignedBuffer[HeapRegion]`,
    codec detected from `path`'s extension. Cap-and-grow loop, refusing an
    output capacity above `max_output_cap` (16 GiB unless a test lowers it)."""
    var codec = _codec_for_path(path)
    var compressed_len = len(compressed_span)

    # `.lz4` NAMES TWO ENCODINGS. Which one this payload is cannot be read off
    # the extension, so read it off the payload — see the `Lz4TextFraming`
    # block in `compression.mojo` for why mapping `.lz4` statically to
    # LZ4_RAW mis-decoded every frame-format file with a size-shaped error.
    var lz4_framing = Lz4TextFraming.RAW_BLOCK
    var is_lz4_frame = False
    if codec == CompressionCodec.LZ4_RAW:
        lz4_framing = lz4_text_framing_of(compressed_span)
        is_lz4_frame = lz4_framing == Lz4TextFraming.FRAME

    var initial_cap = _initial_output_guess(compressed_len)
    if codec == CompressionCodec.GZIP:
        var hint = _gzip_isize_hint(compressed_span)
        if hint:
            var h = hint.value()
            if h > initial_cap:
                initial_cap = h
            initial_cap = initial_cap + 64
    elif is_lz4_frame:
        # A frame that declares its Content Size needs no guess at all: one
        # allocation, one decode, no grow loop. Absent (the common case), fall
        # through to the 4x guess.
        var declared = lz4_frame_declared_content_size(compressed_span)
        if declared:
            initial_cap = declared.value() + 64

    var cap = initial_cap
    var framing_label = String(codec)
    if codec == CompressionCodec.LZ4_RAW:
        framing_label = String(lz4_framing)
    # The last decoder message seen, so the ceiling refusal below can name the
    # actual failure instead of asserting a size story it never verified.
    var last_decode_error = String("")
    while True:
        if cap > max_output_cap:
            raise Error(
                String("text_decompress: decompressed size exceeds the ")
                + String(max_output_cap)
                + String("-byte cap for path '")
                + path
                + String("' (compressed_len=")
                + String(compressed_len)
                + String(", framing=")
                + framing_label
                + String(", last decoder error: ")
                + last_decode_error
                + String(")")
            )
        var out_buf = OwnedAlignedBuffer(cap)
        try:
            # Both decode entries take Spans: the input over the caller's
            # bytes and the output over `out_buf`'s whole capacity (`cap`
            # bytes), so no pointer is taken here.
            var written: Int
            if is_lz4_frame:
                written = _lz4_frame_decompress(
                    compressed_span, out_buf.into_span_capacity(),
                )
            else:
                written = _parquet_decompress(
                    codec, compressed_span, out_buf.into_span_capacity(),
                )
            out_buf.set_length(Int64(written))
            return SharedAlignedBuffer[HeapRegion].from_owned(out_buf^)
        except e:
            # ONLY buffer-too-small wants a retry. For the LZ4 FRAME decoder
            # that is a decidable question — liblz4 tells us apart a full
            # destination (`_LZ4F_TOO_SMALL_MARKER`) from a malformed frame —
            # so a non-capacity frame error is re-raised HERE, at the byte
            # count that produced it, instead of being quadrupled four times
            # into a 16-GiB-ceiling refusal that blames a size nobody measured.
            #
            # The other codecs stay on grow-and-retry because they genuinely
            # cannot distinguish: `LZ4_decompress_safe` returns one negative
            # code for both "dst too small" and "corrupt input", and zlib /
            # zstd are wrapped the same way here. Their ceiling message now
            # carries `last decoder error:` so the failure is at least named.
            var msg = String(e)
            if is_lz4_frame and msg.find(_LZ4F_TOO_SMALL_MARKER) < 0:
                raise Error(
                    String(
                        "text_decompress: LZ4 FRAME decode failed for path '"
                    )
                    + path
                    + String("' (compressed_len=")
                    + String(compressed_len)
                    + String(", output_capacity=")
                    + String(cap)
                    + String("). This is NOT a capacity failure — growing the"
                            " buffer cannot fix it. Underlying: ")
                    + msg
                )
            last_decode_error = msg
            cap = cap * 4


# =============================================================================
# read_text_source_to_heap_buffer — the shared decompress-or-slurp entry.
# =============================================================================


def read_text_source_to_heap_buffer(
    path: String,
) raises -> SharedAlignedBuffer[HeapRegion]:
    """Slurp a line-oriented text file (`path`) into a `SharedAlignedBuffer[
    HeapRegion]`, DECOMPRESSING when the extension marks a whole-file-compressed
    payload (`.csv.{gz,zst,lz4}` / `.jsonl.{gz,zst,lz4}` / ...), else reading the
    raw bytes.

    Both arms return the same heap-buffer type, so callers consume
    `buf.view_range_ro(0, buf.len()).into_span()` uniformly.

    Args:
        path: A `.csv` / `.jsonl` file path (or its `.gz/.zst/.lz4` variant).

    Returns:
        `SharedAlignedBuffer[HeapRegion]` whose `.len()` == the UNCOMPRESSED byte
        count.

    Raises:
        File-open failure (`read_chunked`), unrecognized extension on a compressed
        path, grow-loop overflow (16 GiB), or codec decode failure.
    """
    if is_compressed_text_path(path):
        var src_buf = read_chunked(path)
        var compressed_span = src_buf.view_range_ro(0, src_buf.len()).into_span()
        var out = _decompress_text_bytes(compressed_span, path)
        _ = src_buf^
        return out^
    return read_chunked(path).realign_to[64]()
