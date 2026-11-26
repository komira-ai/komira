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
# layers zlib and lz4 open (each holds its own soname and
# `_Global` slot, and only this package imports them). snappy is statically
# linked and called in snappy_block.mojo. Other packages call the codec API of
# this package and declare no codec FFI of their own.
#
# A slot holds a `_CodecLibrary`: the library's handle, or, when the library
# cannot be loaded, the refusal `_open_codec_library` raised
# (`compression: cannot load <soname>: <the loader's error>`). A `_Global`
# init function cannot raise, so the refusal is kept, and each handle accessor
# raises it (`_library_handle`): a missing library is a raise at each use of
# its codec, and a stream of any other codec, or a file that uses none, does
# not open it. The slot is keyed by its name (`_ZSTD_SLOT_NAME` and the two
# below), so a test can fill it first with a refusal of its own and stand for
# a host that lacks the library.
#
# `probe_codec_libraries` opens libzstd through its slot and libz and liblz4
# by soname through the same raising opener, so a caller that wants a missing
# library named before it starts (libkomira does not) gets the first refusal.
# bz2 and lzma are not probed.
# =============================================================================

from std.ffi import OwnedDLHandle, _Global
from std.sys.info import CompilationTarget

from lz4.codec import LIBLZ4_SONAME
from zlib import LIBZ_SONAME


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
    """The libraries `probe_codec_libraries` opens, in order: libzstd, libz,
    liblz4."""
    var sonames = List[String]()
    sonames.append(String(LIBZSTD_SONAME))
    sonames.append(String(LIBZ_SONAME))
    sonames.append(String(LIBLZ4_SONAME))
    return sonames^


def probe_codec_libraries() raises:
    """Open libzstd, libz and liblz4 (`codec_probe_sonames`), raising the
    opener's error naming the first that cannot be loaded. libzstd is opened
    through its handle slot, so the refusal is the one its codec raises."""
    _ = _zstd_handle()
    var rest = List[String]()
    rest.append(String(LIBZ_SONAME))
    rest.append(String(LIBLZ4_SONAME))
    probe_libraries(rest)


struct _CodecLibrary(Movable):
    """What a handle slot holds: the library's handle, or the refusal raised
    when it could not be loaded (then `handle` is empty)."""

    var handle: Optional[OwnedDLHandle]
    var refusal: String

    def __init__(out self, var handle: OwnedDLHandle):
        self.handle = Optional[OwnedDLHandle](handle^)
        self.refusal = String()

    def __init__(out self, *, var refusal: String):
        self.handle = None
        self.refusal = refusal^


def _load_codec_library(soname: String) -> _CodecLibrary:
    """`_open_codec_library(soname)` as a slot's value: the handle, or the
    refusal it raised (a `_Global` init function cannot raise)."""
    try:
        return _CodecLibrary(_open_codec_library(soname))
    except e:
        return _CodecLibrary(refusal=String(e))


def _init_zstd_handle() -> _CodecLibrary:
    """`_Global` init function: open libzstd once per process."""
    return _load_codec_library(LIBZSTD_SONAME)


def _init_bz2_handle() -> _CodecLibrary:
    """`_Global` init function: open libbz2 once per process."""
    return _load_codec_library(LIBBZ2_SONAME)


def _init_lzma_handle() -> _CodecLibrary:
    """`_Global` init function: open liblzma once per process."""
    return _load_codec_library(LIBLZMA_SONAME)


# The slot names: one process-wide slot per name, in every module that spells it.
comptime _ZSTD_SLOT_NAME = "komira_compression_zstd_handle"
comptime _BZ2_SLOT_NAME = "komira_compression_bz2_handle"
comptime _LZMA_SLOT_NAME = "komira_compression_lzma_handle"

comptime _ZSTD_GLOBAL = _Global[_ZSTD_SLOT_NAME, _init_zstd_handle]
comptime _BZ2_GLOBAL = _Global[_BZ2_SLOT_NAME, _init_bz2_handle]
comptime _LZMA_GLOBAL = _Global[_LZMA_SLOT_NAME, _init_lzma_handle]


@always_inline
def _library_handle(
    slot: UnsafePointer[_CodecLibrary, MutUntrackedOrigin]
) raises -> UnsafePointer[OwnedDLHandle, MutUntrackedOrigin]:
    """The handle `slot` holds; raise its refusal when it holds none.

    SAFETY: `slot` is a `_Global` slot's pointer, into process-lifetime static
    storage the runtime manages and never frees; the handle in it is never
    taken out or replaced, so the returned pointer stays valid for the
    process."""
    if not slot[].handle:
        raise Error(slot[].refusal)
    return UnsafePointer(to=slot[].handle.value())


# The accessors: the handle of each slot, or a raise of its refusal.
# SAFETY: `get_or_create_ptr` returns a pointer into process-lifetime static
# storage the runtime manages; `MutUntrackedOrigin` is the stdlib `_Global`
# API's own return type. The handles are never freed.
@always_inline
def _zstd_handle() raises -> UnsafePointer[OwnedDLHandle, MutUntrackedOrigin]:
    return _library_handle(_ZSTD_GLOBAL.get_or_create_ptr())


@always_inline
def _bz2_handle() raises -> UnsafePointer[OwnedDLHandle, MutUntrackedOrigin]:
    return _library_handle(_BZ2_GLOBAL.get_or_create_ptr())


@always_inline
def _lzma_handle() raises -> UnsafePointer[OwnedDLHandle, MutUntrackedOrigin]:
    return _library_handle(_LZMA_GLOBAL.get_or_create_ptr())
