# =============================================================================
# codec_libraries.mojo: the codec shared libraries this package opens at run time
# =============================================================================
#
# FFI-BOUNDARY: libzstd, libbz2 and liblzma, opened by soname with
# OwnedDLHandle at first use and kept in one process-lifetime `_Global` slot
# each (never closed). Nothing here owns a caller buffer; the codec modules
# (zstd_frame.mojo, bzip2_buffer.mojo, xz_buffer.mojo and the Zstd conformer's
# decompression contexts in compression_codecs.mojo) call through these
# handles for one synchronous call at a time.
#
# This package is the one owner of every codec library a komira package
# loads: the sonames below, plus libz and liblz4, which its implementation
# layers komira_zlib and komira_lz4 open (each holds its own soname and
# `_Global` slot, and only this package imports them). snappy is statically
# linked and called in snappy_block.mojo. Other packages call the codec API of
# this package and declare no codec FFI of their own.
#
# A handle accessor aborts the process when its library cannot be loaded: a
# `_Global` init function cannot raise, and without the library no stream of
# that codec can be read or written. `_open_codec_library` is the opener the
# init functions call; it raises, so a test can call it with a soname that
# does not exist and check the message the abort would carry.
# =============================================================================

from std.ffi import OwnedDLHandle, _Global
from std.os import abort
from std.sys.info import CompilationTarget


# The sonames, per OS.
comptime LIBZSTD_SONAME: StaticString = (
    "libzstd.dylib" if CompilationTarget.is_macos() else "libzstd.so.1"
)
comptime LIBBZ2_SONAME: StaticString = (
    "libbz2.dylib" if CompilationTarget.is_macos() else "libbz2.so.1.0"
)
comptime LIBLZMA_SONAME: StaticString = (
    "liblzma.dylib" if CompilationTarget.is_macos() else "liblzma.so.5"
)


def _open_codec_library(soname: String) raises -> OwnedDLHandle:
    """dlopen `soname`; raise `komira_compression: cannot load <soname>: <the
    loader's error>` when it cannot be loaded."""
    try:
        return OwnedDLHandle(soname)
    except e:
        raise Error(
            "komira_compression: cannot load " + soname + ": " + String(e)
        )


def _init_zstd_handle() -> OwnedDLHandle:
    """`_Global` init function: open libzstd once per process."""
    try:
        return _open_codec_library(LIBZSTD_SONAME)
    except e:
        abort(String(e))


def _init_bz2_handle() -> OwnedDLHandle:
    """`_Global` init function: open libbz2 once per process."""
    try:
        return _open_codec_library(LIBBZ2_SONAME)
    except e:
        abort(String(e))


def _init_lzma_handle() -> OwnedDLHandle:
    """`_Global` init function: open liblzma once per process."""
    try:
        return _open_codec_library(LIBLZMA_SONAME)
    except e:
        abort(String(e))


comptime _ZSTD_GLOBAL = _Global[
    "komira_compression_zstd_handle", _init_zstd_handle
]
comptime _BZ2_GLOBAL = _Global["komira_compression_bz2_handle", _init_bz2_handle]
comptime _LZMA_GLOBAL = _Global[
    "komira_compression_lzma_handle", _init_lzma_handle
]


# The accessors. SAFETY: `get_or_create_ptr` returns a pointer into
# process-lifetime static storage the runtime manages; `MutUntrackedOrigin` is
# the stdlib `_Global` API's own return type. The handles are never freed.
@always_inline
def _zstd_handle() raises -> UnsafePointer[OwnedDLHandle, MutUntrackedOrigin]:
    return _ZSTD_GLOBAL.get_or_create_ptr()


@always_inline
def _bz2_handle() raises -> UnsafePointer[OwnedDLHandle, MutUntrackedOrigin]:
    return _BZ2_GLOBAL.get_or_create_ptr()


@always_inline
def _lzma_handle() raises -> UnsafePointer[OwnedDLHandle, MutUntrackedOrigin]:
    return _LZMA_GLOBAL.get_or_create_ptr()
