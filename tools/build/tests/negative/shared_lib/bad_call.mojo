from std.ffi import OwnedDLHandle
from std.sys import CompilationTarget

comptime LIB = "./missing_call.dylib" if CompilationTarget.is_macos() else "./missing_call.so"


def main() raises:
    var lib = OwnedDLHandle(LIB)
    if lib.call["neg_add", Int32](Int32(2), Int32(2)) != 5:
        raise Error("neg_add(2, 2) is not 5")
