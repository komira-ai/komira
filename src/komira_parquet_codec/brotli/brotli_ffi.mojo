# =============================================================================
# brotli/brotli_ffi.mojo
# =============================================================================
#
# Brotli DECOMPRESSION (read path only) — FFI wrapper to the Brotli decoder's
# one-shot `BrotliDecoderDecompress` symbol.
#
# Parquet supports a BROTLI compression codec. This package reads it through
# the Brotli decoder built from //third_party/brotli and linked statically
# into every binary that depends on this package, as snappy is, so no
# libbrotlidec is needed at run time. Writing Brotli is out of scope.
#
# # API
#
# Brotli's one-shot decode API (<brotli/decode.h>):
#   BrotliDecoderResult BrotliDecoderDecompress(
#       size_t encoded_size, const uint8_t* encoded_buffer,
#       size_t* decoded_size, uint8_t* decoded_buffer);
#
# `decoded_size` is in/out: caller sets it to the output buffer capacity
# (the Parquet page's uncompressed_page_size), and on SUCCESS it holds the
# actual number of bytes written. The return value is a BrotliDecoderResult,
# a C `int` enum; SUCCESS == 1.
#
#   _brotli_decompress_into(dst, src) raises -> Int
#
# `dst` is a Span with a mutable origin, `src` a Span; the full signature is
# on the function.
#
# # Encapsulation
#
# Package-private: `_brotli_decompress_into` takes Spans with caller-chosen
# origins and no raw pointer. The pointers taken from them are cast to an
# untracked origin ONLY at the `external_call` site, which carries a
# `# SAFETY:` block.
# =============================================================================

from std.ffi import external_call


# BrotliDecoderResult enum value for a complete, successful one-shot decode.
# (BROTLI_DECODER_RESULT_SUCCESS == 1; ERROR == 0; NEEDS_MORE_INPUT == 2;
#  NEEDS_MORE_OUTPUT == 3.)
comptime _BROTLI_DECODER_RESULT_SUCCESS: Int32 = 1


# -----------------------------------------------------------------------------
# Entry — the BROTLI arm of the codec dispatch in compression.mojo calls it.
# -----------------------------------------------------------------------------


def _brotli_decompress_into[
    dori: MutOrigin
](dst: Span[UInt8, dori], src: Span[UInt8, _]) raises -> Int:
    """Decompress a Brotli stream via the Brotli decoder's one-shot
    `BrotliDecoderDecompress`. Returns the number of bytes written to dst.

    `decoded_size` is passed in as `len(dst)` (the Parquet page's
    uncompressed size) and read back as the actual decoded byte count. A
    stream that decodes to more than `len(dst)`, or that ends early, raises.

    SAFETY: BrotliDecoderDecompress reads exactly `len(src)` bytes from
    `src` and writes up to `*decoded_size` bytes to `dst`. Both Spans keep
    their buffers alive for the duration of this synchronous call; the
    decoder retains no pointer past the call. Origins are cast to an
    untracked origin ONLY at the call site. `decoded_size` is a stack local
    whose address is passed as the in/out size pointer; it is alive across
    the call.
    """
    var src_size = len(src)
    var dst_capacity = len(dst)

    # In/out size: set to output capacity, read back as decoded length.
    var decoded_size: UInt64 = UInt64(dst_capacity)

    # SAFETY: see the docstring. The two buffers are the caller's Spans and
    # the size is a stack local; all outlive this synchronous call, and the
    # decoder copies nothing past return. The return is a C `int` enum,
    # declared Int32, so the upper half of the 64-bit return register (left
    # unspecified for a 32-bit return) is never read.
    var result = external_call[
        "BrotliDecoderDecompress",
        Int32,
        UInt64,
        UnsafePointer[UInt8, MutUntrackedOrigin],
        UnsafePointer[UInt64, MutUntrackedOrigin],
        UnsafePointer[UInt8, MutUntrackedOrigin],
    ](
        UInt64(src_size),
        src.unsafe_ptr()
        .unsafe_mut_cast[True]()
        .unsafe_origin_cast[MutUntrackedOrigin](),
        UnsafePointer(to=decoded_size).unsafe_origin_cast[MutUntrackedOrigin](),
        dst.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin](),
    )

    if result != _BROTLI_DECODER_RESULT_SUCCESS:
        raise Error(
            "BrotliDecoderDecompress failed (result="
            + String(result)
            + ", input_len="
            + String(src_size)
            + ", output_cap="
            + String(dst_capacity)
            + ")"
        )
    return Int(decoded_size)
