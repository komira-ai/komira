# =============================================================================
# test_codecs_linked.mojo
# =============================================================================
#
# zstd is linked into the program (//third_party/zstd, every symbol renamed
# komira_zstd_*), so a zstd frame and a zstd conformer round trip open no
# shared library: after them the loader holds no libzstd, the library a host
# such as macOS does not have. lz4 is linked the same way (its own package's
# test holds that), so an LZ4 frame round trip through this package's
# conformer loads no liblz4 either. Whether a library is loaded is asked of
# the loader itself: `dlopen(soname, RTLD_NOW | RTLD_NOLOAD)` returns a
# handle only for a library the process already holds. The C library, which
# every process holds, is the probe's positive case. (libz, which gzip opens
# at run time by the bare name libz.dylib, is not one on macOS: on the macOS
# workers a no-load open of that name gave no handle after a gzip round
# trip, so it cannot show that the probe sees a loaded library there.)
#
# What it catches: a codec that opens libzstd or liblz4 at run time again (on
# a host without them, the first zstd or lz4 Parquet page ends the process),
# and a probe that reports nothing loaded whatever is.
# =============================================================================

from std.ffi import OwnedDLHandle, RTLD
from std.sys.info import CompilationTarget
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from compression.compression_codecs import Lz4Frame, Zstd
from compression.zstd_frame import (
    ZSTD_DEFAULT_LEVEL,
    zstd_compress_bound,
    zstd_compress_into,
    zstd_decompress_into,
)

# <dlfcn.h>'s RTLD_NOLOAD: 4 in glibc, 0x10 on macOS.
comptime _RTLD_NOLOAD = 0x10 if CompilationTarget.is_macos() else 4

# The sonames a host's own libzstd and liblz4 have.
comptime _HOST_LIBZSTD: StaticString = (
    "libzstd.dylib" if CompilationTarget.is_macos() else "libzstd.so.1"
)
comptime _HOST_LIBLZ4: StaticString = (
    "liblz4.dylib" if CompilationTarget.is_macos() else "liblz4.so.1"
)
comptime _LIBC: StaticString = (
    "libSystem.B.dylib" if CompilationTarget.is_macos() else "libc.so.6"
)


def _loaded(soname: StaticString) -> Bool:
    """Whether the process already holds `soname`: the loader opens it
    without loading anything (RTLD_NOLOAD)."""
    try:
        _ = OwnedDLHandle(String(soname), RTLD.NOW | _RTLD_NOLOAD)
        return True
    except:
        return False


def _text(n: Int) -> List[UInt8]:
    var src = List[UInt8]()
    for i in range(n):
        src.append(UInt8(97 + i % 7))
    return src^


def test_a_zstd_round_trip_loads_no_libzstd() raises:
    var src = _text(4096)
    var frame = List[UInt8](length=zstd_compress_bound(len(src)), fill=0)
    var n = zstd_compress_into(Span(frame), Span(src), ZSTD_DEFAULT_LEVEL)
    var out = List[UInt8](length=len(src), fill=0)
    assert_equal(zstd_decompress_into(Span(out), Span(frame)[0:n]), len(src))
    var packed = Zstd[3].compress(Span(src))
    var unpacked = Zstd[3].decompress(Span(packed), len(src))
    assert_equal(len(unpacked), len(src))
    for i in range(len(src)):
        assert_equal(out[i], src[i])
        assert_equal(unpacked[i], src[i])
    assert_false(
        _loaded(_HOST_LIBZSTD),
        String(_HOST_LIBZSTD) + " is loaded after a zstd round trip",
    )


def test_an_lz4_frame_round_trip_loads_no_liblz4() raises:
    var src = _text(4096)
    var frame = Lz4Frame.compress(Span(src))
    var out = Lz4Frame.decompress(Span(frame), len(src))
    assert_equal(len(out), len(src))
    for i in range(len(src)):
        assert_equal(out[i], src[i])
    assert_false(
        _loaded(_HOST_LIBLZ4),
        String(_HOST_LIBLZ4) + " is loaded after an LZ4 frame round trip",
    )


def test_the_probe_sees_the_c_library() raises:
    assert_true(
        _loaded(_LIBC), String(_LIBC) + " is not seen loaded in the process"
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
