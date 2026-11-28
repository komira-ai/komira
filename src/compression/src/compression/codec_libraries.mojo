# =============================================================================
# codec_libraries.mojo: the codec shared libraries this package opens at run time
# =============================================================================
#
# FFI-BOUNDARY: libbz2 and liblzma, opened by soname with OwnedDLHandle at
# first use and kept in one process-lifetime `_Global` slot each (never
# closed). Nothing here owns a caller buffer; the codec modules
# (bzip2_buffer.mojo and xz_buffer.mojo) call through these handles for one
# synchronous call at a time.
#
# This package is the one owner of every codec library a komira package
# loads: the two sonames below, plus libz, which its implementation layer
# zlib opens (it holds its own soname and `_Global` slot, and only this
# package imports it). snappy and zstd are statically linked (snappy_block.mojo
# and zstd_frame.mojo), and so is lz4 (its implementation layer lz4): no host
# needs a libzstd or a liblz4. Other packages call the codec API of this
# package and declare no codec FFI of their own.
#
# A handle accessor aborts the process when its library cannot be loaded: a
# `_Global` init function cannot raise, and without the library no stream of
# that codec can be read or written. `_open_codec_library` is the opener the
# init functions call; it raises, so a test can call it with a soname that
# does not exist and check the message the abort would carry.
#
# `probe_codec_libraries` opens libz through that raising opener and drops
# the handle: a caller that must not die on a missing library (libkomira)
# calls it before the first codec use, so a missing libz is a raise with the
# opener's message and the `_Global` init, which runs later, finds the
# library. bz2 and lzma are not probed.
# =============================================================================

from std.ffi import OwnedDLHandle, _Global
from std.os import abort
from std.sys.info import CompilationTarget

from zlib import LIBZ_SONAME


# The sonames, per OS.
comptime LIBBZ2_SONAME: StaticString = (
    "libbz2.dylib" if CompilationTarget.is_macos() else "libbz2.so.1.0"
)
comptime LIBLZMA_SONAME: StaticString = (
    "liblzma.dylib" if CompilationTarget.is_macos() else "liblzma.so.5"
)


def _open_codec_library(soname: String) raises -> OwnedDLHandle:
    """dlopen `soname`; raise `compression: cannot load <soname>: <the
    loader's error>` when it cannot be loaded."""
    try:
        return OwnedDLHandle(soname)
    except e:
        raise Error(
            "compression: cannot load " + soname + ": " + String(e)
        )


def probe_libraries(sonames: List[String]) raises:
    """Open each of `sonames` in order and drop the handle; raise `compression:
    cannot load <soname>: <the loader's error>` for the first that cannot be
    loaded."""
    for soname in sonames:
        _ = _open_codec_library(soname)


def codec_probe_sonames() -> List[String]:
    """The libraries `probe_codec_libraries` opens: libz, the one codec
    library a Parquet, CSV or JSON read or write opens at run time (zstd and
    lz4 are linked in)."""
    var sonames = List[String]()
    sonames.append(String(LIBZ_SONAME))
    return sonames^


def probe_codec_libraries() raises:
    """Open libz (`codec_probe_sonames`), raising the opener's error when it
    cannot be loaded."""
    probe_libraries(codec_probe_sonames())


def _open_or_abort(soname: String) -> OwnedDLHandle:
    """`_open_codec_library(soname)`, aborting the process with its message
    when the library cannot be loaded (a `_Global` init function cannot
    raise)."""
    try:
        return _open_codec_library(soname)
    except e:
        abort(String(e))


def _init_bz2_handle() -> OwnedDLHandle:
    """`_Global` init function: open libbz2 once per process."""
    return _open_or_abort(LIBBZ2_SONAME)


def _init_lzma_handle() -> OwnedDLHandle:
    """`_Global` init function: open liblzma once per process."""
    return _open_or_abort(LIBLZMA_SONAME)


comptime _BZ2_GLOBAL = _Global["komira_compression_bz2_handle", _init_bz2_handle]
comptime _LZMA_GLOBAL = _Global[
    "komira_compression_lzma_handle", _init_lzma_handle
]


# The accessors. SAFETY: `get_or_create_ptr` returns a pointer into
# process-lifetime static storage the runtime manages; `MutUntrackedOrigin` is
# the stdlib `_Global` API's own return type. The handles are never freed.
@always_inline
def _bz2_handle() raises -> UnsafePointer[OwnedDLHandle, MutUntrackedOrigin]:
    return _BZ2_GLOBAL.get_or_create_ptr()


@always_inline
def _lzma_handle() raises -> UnsafePointer[OwnedDLHandle, MutUntrackedOrigin]:
    return _LZMA_GLOBAL.get_or_create_ptr()
