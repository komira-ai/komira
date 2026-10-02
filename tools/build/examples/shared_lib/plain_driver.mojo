from std.ffi import OwnedDLHandle
from std.sys import CompilationTarget

comptime LIB = "./plain.dylib" if CompilationTarget.is_macos() else "./plain.so"


def main() raises:
    var lib = OwnedDLHandle(LIB)
    var add = lib.call["plain_add", Int32](Int32(2), Int32(3))
    if add != 5:
        raise Error("plain_add(2, 3) = " + String(add))
    var sq = lib.call["plain_sum_squares", Int64](Int32(4))
    if sq != 14:
        raise Error("plain_sum_squares(4) = " + String(sq))
    # Not exact: the unlisted @export is in the dynamic symbol table.
    if lib.call["plain_hidden", Int32]() != 7:
        raise Error("plain_hidden() is not 7")
    print("ok")
