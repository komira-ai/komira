# komira_ctx_new returns distinct non-NULL handles; komira_ctx_free releases them and accepts NULL.
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
    var a = lib.call["komira_ctx_new", Int]()
    var b = lib.call["komira_ctx_new", Int]()
    if a == 0 or b == 0:
        raise Error("komira_ctx_new returned NULL")
    if a == b:
        raise Error("two live contexts share one handle")
    lib.call["komira_ctx_free", NoneType](a)
    lib.call["komira_ctx_free", NoneType](b)
    # NULL is a no-op, not a crash.
    lib.call["komira_ctx_free", NoneType](Int(0))
    # A handle may be created again after the others are freed.
    var c = lib.call["komira_ctx_new", Int]()
    if c == 0:
        raise Error("komira_ctx_new returned NULL after a free")
    lib.call["komira_ctx_free", NoneType](c)
    print("ok")
