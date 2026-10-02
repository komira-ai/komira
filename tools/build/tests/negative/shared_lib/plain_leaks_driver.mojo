from std.ffi import OwnedDLHandle
from std.sys import CompilationTarget

comptime LIB = "./plain_leaks.dylib" if CompilationTarget.is_macos() else "./plain_leaks.so"


def main() raises:
    var lib = OwnedDLHandle(LIB)
    if lib.check_symbol("plain_hidden"):
        raise Error("plain_hidden leaked into the dynamic symbol table")
    print("ok")
