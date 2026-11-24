# =============================================================================
# test_codec_libraries.mojo
# =============================================================================
#
# The opener behind this package's library handles (codec_libraries.mojo):
# each soname it owns opens on this system, and the same opener given a
# soname that does not exist raises
# `compression: cannot load <soname>: <the loader's error>`, the text
# a handle's init function aborts with. The loader's error is taken from
# OwnedDLHandle itself, so the message is compared whole.
#
# What it catches: a soname spelled wrong (the open fails), an opener that
# swallows the failure or returns a handle anyway, and a message that drops
# the soname or the loader's reason.
# =============================================================================

from std.ffi import OwnedDLHandle
from std.testing import TestSuite, assert_equal, assert_true

from compression.codec_libraries import (
    LIBBZ2_SONAME,
    LIBLZMA_SONAME,
    LIBZSTD_SONAME,
    _open_codec_library,
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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
