# =============================================================================
# test_codec_libraries.mojo
# =============================================================================
#
# The opener behind this package's library handles (codec_libraries.mojo):
# each soname it owns opens on this system, and the same opener given a
# soname that does not exist raises
# `compression: cannot load <soname>: <the loader's error>`. The loader's
# error is taken from OwnedDLHandle itself, so the message is compared whole.
#
# The handle slots: a slot over a library that loads holds its handle, and
# the accessor (`_library_handle`) returns it; a slot over a soname that does
# not exist holds the opener's refusal, and the accessor raises it, word for
# word, on every call (the slot is filled once; it neither aborts nor opens
# the library again). The probe opens libzstd through its slot, libz and
# liblz4 by soname, and names the first missing one.
#
# What it catches: a soname spelled wrong (the open fails), an opener that
# swallows the failure or returns a handle anyway, a message that drops the
# soname or the loader's reason, a slot that aborts or forgets its refusal,
# and an accessor that hands out a handle the slot does not hold.
# =============================================================================

from std.ffi import OwnedDLHandle, _Global
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from compression.codec_libraries import (
    LIBBZ2_SONAME,
    LIBLZMA_SONAME,
    LIBZSTD_SONAME,
    _CodecLibrary,
    _ZSTD_SLOT_NAME,
    _library_handle,
    _load_codec_library,
    _open_codec_library,
    _zstd_handle,
    codec_probe_sonames,
    probe_codec_libraries,
    probe_libraries,
)
from lz4.codec import LIBLZ4_SONAME
from zlib import LIBZ_SONAME


def _loader_error(soname: String) -> String:
    """What OwnedDLHandle raises for `soname`, or "" when it opens."""
    try:
        _ = OwnedDLHandle(soname)
    except e:
        return String(e)
    return ""


def _check_missing(soname: StaticString) raises:
    var absent = String(soname) + ".komira-absent"
    var reason = _loader_error(absent)
    assert_true(reason.byte_length() > 0, absent + " opened")
    var msg = String("")
    try:
        _ = _open_codec_library(absent)
    except e:
        msg = String(e)
    assert_equal(msg, "compression: cannot load " + absent + ": " + reason)


def test_every_owned_soname_opens() raises:
    _ = _open_codec_library(LIBZSTD_SONAME)
    _ = _open_codec_library(LIBBZ2_SONAME)
    _ = _open_codec_library(LIBLZMA_SONAME)


def test_a_missing_zstd_library_is_named() raises:
    _check_missing(LIBZSTD_SONAME)


def test_a_missing_bzip2_library_is_named() raises:
    _check_missing(LIBBZ2_SONAME)


def test_a_missing_xz_library_is_named() raises:
    _check_missing(LIBLZMA_SONAME)


def test_the_probe_opens_the_three_libraries() raises:
    var sonames = codec_probe_sonames()
    assert_equal(len(sonames), 3)
    assert_equal(sonames[0], String(LIBZSTD_SONAME))
    assert_equal(sonames[1], String(LIBZ_SONAME))
    assert_equal(sonames[2], String(LIBLZ4_SONAME))
    probe_codec_libraries()


def _probe_message(sonames: List[String]) -> String:
    try:
        probe_libraries(sonames)
    except e:
        return String(e)
    return ""


def test_the_probe_names_a_missing_library_after_present_ones() raises:
    var absent = String(LIBLZ4_SONAME) + ".komira-absent"
    var reason = _loader_error(absent)
    assert_true(reason.byte_length() > 0, absent + " opened")
    var sonames = List[String]()
    sonames.append(String(LIBZSTD_SONAME))
    sonames.append(String(LIBZ_SONAME))
    sonames.append(absent)
    assert_equal(
        _probe_message(sonames),
        "compression: cannot load " + absent + ": " + reason,
    )
    var first = List[String]()
    first.append(absent)
    first.append(String(LIBZSTD_SONAME))
    assert_equal(
        _probe_message(first),
        "compression: cannot load " + absent + ": " + reason,
    )


# A slot of this test's own over a soname that does not exist: the path the
# package's slots take, with the open failing.
comptime _ABSENT = "libzstd.so.komira-absent"


def _init_absent() -> _CodecLibrary:
    return _load_codec_library(_ABSENT)


comptime _ABSENT_GLOBAL = _Global["komira_compression_test_absent", _init_absent]


def _handle_message() -> String:
    """What the accessor of the absent slot raises, or "" when it returns."""
    try:
        _ = _library_handle(_ABSENT_GLOBAL.get_or_create_ptr())
    except e:
        return String(e)
    return ""


def test_a_slot_over_a_library_that_loads_holds_its_handle() raises:
    var library = _load_codec_library(LIBZSTD_SONAME)
    assert_true(Bool(library.handle))
    assert_equal(library.refusal, "")
    # The package's own slot hands out the handle, and a call through it
    # answers (ZSTD_compressBound(0) is a frame header's bound, above 0).
    var handle = _zstd_handle()
    assert_true(handle[].call["ZSTD_compressBound", Int](0) > 0)


def test_a_slot_over_a_missing_library_keeps_the_refusal() raises:
    var reason = _loader_error(_ABSENT)
    assert_true(reason.byte_length() > 0, String(_ABSENT) + " opened")
    var want = "compression: cannot load " + String(_ABSENT) + ": " + reason
    var library = _load_codec_library(_ABSENT)
    assert_false(Bool(library.handle))
    assert_equal(library.refusal, want)
    # The accessor raises the refusal on the first use and on every later
    # one: the slot is filled once, and the process goes on.
    assert_equal(_handle_message(), want)
    assert_equal(_handle_message(), want)


def test_the_zstd_slot_is_the_one_its_name_spells() raises:
    # A module that spells the slot's name reaches the package's own slot,
    # which this process filled with libzstd's handle above or does now.
    _ = _zstd_handle()
    comptime same = _Global[_ZSTD_SLOT_NAME, _init_absent]
    assert_true(Bool(same.get_or_create_ptr()[].handle))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
