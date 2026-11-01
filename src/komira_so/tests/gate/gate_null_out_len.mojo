# A NULL out_len on a live context is -2, with or without a buffer, and the buffer is not written.
#
# A gate driver of //src/komira_so:libkomira. It has no dependency: it opens
# the library with dlopen (RTLD_NOW, through OwnedDLHandle) and calls the
# C symbols as a foreign host would. A context handle is held as the integer
# word the library returned and passed back as one (a `void *` and an Int are
# passed the same way on both supported targets); NULL is the word 0.

from std.ffi import OwnedDLHandle
from std.memory import alloc
from std.sys import CompilationTarget

comptime LIB = "./libkomira.dylib" if CompilationTarget.is_macos() else "./libkomira.so"


def main() raises:
    var lib = OwnedDLHandle(LIB)
    var ctx = lib.call["komira_ctx_new", Int]()
    if ctx == 0:
        raise Error("komira_ctx_new returned NULL")
    # SAFETY: allocated here and freed below; the library must not write it.
    var buf = alloc[UInt8](4)
    buf[0] = UInt8(5)
    var rc = lib.call["komira_last_error", Int32](ctx, buf, UInt64(4), Int(0))
    if rc != -2:
        raise Error("NULL out_len with a buffer returned " + String(rc) + ", want -2")
    rc = lib.call["komira_last_error", Int32](ctx, Int(0), UInt64(0), Int(0))
    if rc != -2:
        raise Error("NULL out_len and NULL buffer returned " + String(rc) + ", want -2")
    if buf[0] != 5:
        raise Error("a refused call wrote into the buffer")
    lib.call["komira_ctx_free", NoneType](ctx)
    buf.free()
    print("ok")
