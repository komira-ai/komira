"""fx_dlopen_drift: opens a shared library it does not declare, a fixture of tests//negative/conda_dlopen."""

from std.ffi import OwnedDLHandle


def fx_dlopen_drift_value() -> Int:
    # Never called by the test: the fixture only has to contain the handle type.
    return 7


def fx_dlopen_drift_open() raises -> OwnedDLHandle:
    return OwnedDLHandle("libz.so.1")
