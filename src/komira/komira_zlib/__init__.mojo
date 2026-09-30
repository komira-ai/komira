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
#   * `zlib_inflate_ffi(dst, dst_cap, src, src_size, window_bits=15+32) -> Int`
#   * `zlib_deflate_ffi(dst, dst_cap, src, src_size, level, window_bits) -> Int`
#   * `zlib_compress_bound_ffi(src_size, window_bits) -> Int`
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
    zlib_inflate_ffi,
    zlib_deflate_ffi,
    zlib_compress_bound_ffi,
)
