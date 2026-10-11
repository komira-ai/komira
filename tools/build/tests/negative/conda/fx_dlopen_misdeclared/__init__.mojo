"""fx_dlopen_misdeclared: opens liblz4.so.1 and declares libz.so.1 instead, a fixture of tests//negative/conda."""

from std.ffi import OwnedDLHandle


def fx_dlopen_misdeclared_value() -> Int:
    # Never called by the test: the fixture only has to name the soname.
    return 7


def fx_dlopen_misdeclared_open() raises -> OwnedDLHandle:
    return OwnedDLHandle("liblz4.so.1")
