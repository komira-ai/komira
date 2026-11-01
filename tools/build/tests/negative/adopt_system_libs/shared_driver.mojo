from std.ffi import OwnedDLHandle
from std.sys import CompilationTarget

comptime LIB = "./syslib_probe.dylib" if CompilationTarget.is_macos() else "./syslib_probe.so"


def main() raises:
    var lib = OwnedDLHandle(LIB)
    if lib.call["probe_sqlite", Int32]() != 1:
        raise Error("the library did not find SQLite by its bare name")
    print("ok")
