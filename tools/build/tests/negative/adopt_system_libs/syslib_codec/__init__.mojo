"""syslib_codec: a library whose code opens a shared library by its bare name, as a package that says `mode = "load"` for a library does. Nothing links it; the
code finds it on the library path when it runs."""

from std.ffi import OwnedDLHandle


def sqlite_is_loadable() raises -> Bool:
    """Opens SQLite by its bare name; raises where the loader cannot find it."""
    var lib = OwnedDLHandle("libsqlite3.so.0")
    return lib.check_symbol("sqlite3_libversion_number")


def answer() -> Int:
    return 42
