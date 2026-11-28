# =============================================================================
# test_static_codec.mojo
# =============================================================================
#
# lz4 is linked into the program (//third_party/lz4, every symbol renamed
# komira_lz4_*), so an LZ4 raw block and an LZ4 frame round trip open no
# shared library: after them the loader holds no liblz4, the library a host
# such as macOS does not have. Whether a library is loaded is asked of the
# loader itself: `dlopen(soname, RTLD_NOW | RTLD_NOLOAD)` returns a handle
# only for a library the process already holds. The C library, which every
# process holds, is the probe's positive case.
#
# What it catches: a codec that opens liblz4 at run time again (on a host
# without it, the first LZ4 Parquet page or Arrow IPC buffer ends the
# process), and a probe that reports nothing loaded whatever is.
# =============================================================================

from std.ffi import OwnedDLHandle, RTLD
from std.sys.info import CompilationTarget
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from lz4.codec import lz4_compress, lz4_decompress
from lz4.frame import (
    lz4_frame_compress_bound,
    lz4_frame_compress_into,
    lz4_frame_decompress_into,
)

# <dlfcn.h>'s RTLD_NOLOAD: 4 in glibc, 0x10 on macOS.
comptime _RTLD_NOLOAD = 0x10 if CompilationTarget.is_macos() else 4

# The soname a host's own liblz4 has, and the C library's.
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


def test_block_and_frame_round_trips_load_no_liblz4() raises:
    var src = _text(4096)
    var block = lz4_compress(Span(src))
    var from_block = lz4_decompress(Span(block), len(src))
    var frame = List[UInt8](length=lz4_frame_compress_bound(len(src)), fill=0)
    var n = lz4_frame_compress_into(Span(frame), Span(src))
    var from_frame = List[UInt8](length=len(src), fill=0)
    assert_equal(
        lz4_frame_decompress_into(Span(from_frame), Span(frame)[0:n]), len(src)
    )
    assert_equal(len(from_block), len(src))
    for i in range(len(src)):
        assert_equal(from_block[i], src[i])
        assert_equal(from_frame[i], src[i])
    assert_false(
        _loaded(_HOST_LIBLZ4),
        String(_HOST_LIBLZ4) + " is loaded after LZ4 round trips",
    )


def test_the_probe_sees_the_c_library() raises:
    assert_true(
        _loaded(_LIBC), String(_LIBC) + " is not seen loaded in the process"
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
