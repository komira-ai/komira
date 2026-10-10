# =============================================================================
# lz4_frame/lz4_ffi.mojo
# =============================================================================
#
# LZ4 FRAME compression / decompression for the page codec and `.lz4` text
# files: komira_compression's lz4 module (komira_lz4's frame API, which owns
# liblz4: its soname, its process-lifetime handle and its FFI).
#
# Kafka's LZ4 producer compression (KIP-57, since Kafka 0.10) emits LZ4-FRAME
# bytes (magic 0x184D2204 + frame descriptor + block headers), NOT raw
# blocks; a raw-block decoder cannot decode them.
#
# # API (package-private: `compression.mojo` is the caller)
#
# `dst` is a Span with a mutable origin, `src` a Span; the full signatures
# are on the functions.
#
#   _lz4_frame_decompress_into(dst, src) raises -> Int
#   _lz4_frame_compress_into(dst, src) raises -> Int
#   _lz4_frame_compress_bound(src_size: Int) raises -> Int
# =============================================================================

from komira_compression.lz4 import (
    lz4_frame_compress_bound,
    lz4_frame_compress_into,
    lz4_frames_decompress_into,
)


def _lz4_frame_decompress_into[
    dori: MutOrigin
](dst: Span[UInt8, dori], src: Span[UInt8, _]) raises -> Int:
    """Decode the LZ4 frames in `src`, one or more back to back, into `dst`
    (capacity `len(dst)`); return the bytes written. Input that ends inside a
    frame, or bytes after a frame that are not one, raise.

    Raises with the literal "LZ4F dst buffer too small" marker when the
    output buffer filled before the frame ended (a caller's grow-and-retry
    loop matches on that text); raises "LZ4F frame truncated" when the input
    ends before the frame does; raises `LZ4F_decompress failed (code=C)` on
    any failure liblz4 flags.
    """
    return lz4_frames_decompress_into(dst, src)


def _lz4_frame_compress_bound(src_size: Int) raises -> Int:
    """Max LZ4-frame compressed size (`LZ4F_compressFrameBound` with the
    default preferences)."""
    return lz4_frame_compress_bound(src_size)


def _lz4_frame_compress_into[
    dori: MutOrigin
](dst: Span[UInt8, dori], src: Span[UInt8, _]) raises -> Int:
    """LZ4 FRAME compression (one-shot, `LZ4F_compressFrame` with the default
    preferences). `len(dst)` must be >= `_lz4_frame_compress_bound`; a
    smaller one is refused before liblz4 is called. Returns the frame byte
    count.
    """
    return lz4_frame_compress_into(dst, src)
