# komira_abi_version returns 1001, the version 1.1 as major * 1000 + minor.
#
# A gate driver of //src/komira_so:libkomira. It has no dependency: it opens
# the library with dlopen (RTLD_NOW, through OwnedDLHandle) and calls the
# C symbols as a foreign host would. A context handle is held as the integer
# word the library returned and passed back as one (a `void *` and an Int are
# passed the same way on both supported targets); NULL is the word 0.

from std.ffi import OwnedDLHandle
from std.sys import CompilationTarget

comptime LIB = "./libkomira.dylib" if CompilationTarget.is_macos() else "./libkomira.so"


def main() raises:
    var lib = OwnedDLHandle(LIB)
    var v = lib.call["komira_abi_version", Int32]()
    if v != 1001:
        raise Error("komira_abi_version() = " + String(v) + ", want 1001")
    print("ok")
