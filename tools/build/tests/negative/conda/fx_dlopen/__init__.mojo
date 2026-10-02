"""fx_dlopen: names a shared library at run time, a fixture of tests//negative/conda."""

from std.ffi import OwnedDLHandle


def fx_dlopen_value() -> Int:
    # Never called by the test: the fixture only has to contain the handle type.
    return 6


def fx_dlopen_open() raises -> OwnedDLHandle:
    return OwnedDLHandle("libz.so.1")
