# =============================================================================
# komira_zlib — FFI shim facade for libz
# =============================================================================
#
# # Why this is its OWN library
#
# A consumer that only needs zlib framing must not depend on the query engine.
# This package is a zero-dependency FFI leaf (std.ffi + std.memory + std.os +
# std.sys.info, nothing else). If it lived inside the parquet library, any user
# of zlib framing (for example, a git server's loose-object framing) would pull
# parquet, the compiler, the engine operators and runtime, and every format
# reader into its build closure, and a compile break in any of them would block
# a release of code that never touches them. `komira_parquet` depends on this
# library for its GZIP/zlib page codec instead of containing it.
#
# Both compression directions delegate to the system libz through a runtime
# dlopen: a native inflate/deflate implementation is not worth carrying when
# libz is already the reference it would be measured against.
#
# Public symbols (stable surface for `komira_parquet`'s compression codec):
#   * `zlib_inflate_into(dst, src, window_bits=ZLIB_WINDOW_BITS_AUTO) -> Int`
#   * `zlib_inflate_once(dst, src, window_bits) -> ZlibInflateOutcome` (one
#     `inflate` call, its return code and counts handed back unjudged)
#   * `zlib_deflate_into(dst, src, level, window_bits) -> Int`
#   * `zlib_compress_bound(src_len, window_bits) -> Int`
#   * `zlib_skip_stream(src, window_bits=ZLIB_WINDOW_BITS_AUTO) -> Int`
#   * `zlib_crc32(data, crc=0) -> UInt32` (the gzip trailer's CRC-32)
#   * the `ZLIB_WINDOW_BITS_*` framing selectors and `ZLIB_LEVEL_DEFAULT`
#   (Span in, caller-owned Span out; a too-small `dst` is refused). No public
#   signature holds a raw pointer: the pointer-taking `_zlib_*_ffi` entries
#   they wrap are underscore-prefixed and not re-exported here (private to
#   `zlib_ffi.mojo` by convention; the compiler does not enforce it).
#
# `window_bits` selects framing:
#     15 (max)       : zlib wrapper (RFC 1950 — Adler-32 trailer)
#    -15 (negative)  : raw deflate (RFC 1951 — no header/trailer)
#     15 + 16 = 31   : gzip wrapper (RFC 1952 — CRC-32 trailer)
#     15 + 32 = 47   : zlib + gzip auto-detect (inflate only; load-bearing
#                      for Parquet interop where writers disagree on framing)
#
# See `zlib_ffi.mojo` for the FFI implementation.
# =============================================================================

from .zlib_ffi import (
    ZLIB_LEVEL_DEFAULT,
    ZLIB_WINDOW_BITS_AUTO,
    ZLIB_WINDOW_BITS_GZIP,
    ZLIB_WINDOW_BITS_RAW,
    ZLIB_WINDOW_BITS_ZLIB,
    zlib_compress_bound,
    zlib_crc32,
    zlib_deflate_into,
    zlib_inflate_into,
    zlib_inflate_once,
    zlib_skip_stream,
    ZlibInflateOutcome,
)
