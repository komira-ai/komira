"""fx_dlopen: opens a shared library no conda package ships, a fixture of tests//negative/conda."""

from std.ffi import OwnedDLHandle


def fx_dlopen_value() -> Int:
    # Never called by the test: the fixture only has to contain the handle type.
    return 6


def fx_dlopen_open() raises -> OwnedDLHandle:
    return OwnedDLHandle("libfx_dlopen.so.1")
