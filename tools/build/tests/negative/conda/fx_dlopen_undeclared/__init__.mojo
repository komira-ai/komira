"""fx_dlopen_undeclared: opens two shared libraries and declares one, a fixture of tests//negative/conda."""

from std.ffi import OwnedDLHandle


def fx_dlopen_undeclared_value() -> Int:
    # Never called by the test: the fixture only has to name the sonames.
    return 7


def fx_dlopen_undeclared_open() raises -> OwnedDLHandle:
    return OwnedDLHandle("libz.so.1")


def fx_dlopen_undeclared_open_lz4() raises -> OwnedDLHandle:
    return OwnedDLHandle("liblz4.so.1")
