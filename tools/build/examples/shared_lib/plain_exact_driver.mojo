from std.ffi import OwnedDLHandle
from std.sys import CompilationTarget

comptime LIB = "./plain_exact.dylib" if CompilationTarget.is_macos() else "./plain_exact.so"


def main() raises:
    var lib = OwnedDLHandle(LIB)
    if lib.call["plain_add", Int32](Int32(40), Int32(2)) != 42:
        raise Error("plain_add(40, 2) is not 42")
    if lib.check_symbol("plain_hidden"):
        raise Error("plain_hidden leaked into the dynamic symbol table")
    print("ok")
