"""fx_dlopen_unmapped: declares a soname system_libs.bzl does not name, a fixture of tests//negative/conda."""

from std.ffi import OwnedDLHandle


def fx_dlopen_unmapped_value() -> Int:
    # Never called by the test: the fixture only has to name the soname.
    return 8


def fx_dlopen_unmapped_open() raises -> OwnedDLHandle:
    return OwnedDLHandle("libfx_nowhere.so.1")
