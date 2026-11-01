# A NULL context is -1 from komira_last_error and leaves the caller's slots alone.
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
    # SAFETY: allocated here and freed below; the library must not write them.
    var out_len = alloc[UInt64](1)
    var buf = alloc[UInt8](4)
    out_len[0] = UInt64(77)
    buf[0] = UInt8(5)
    var rc = lib.call["komira_last_error", Int32](Int(0), buf, UInt64(4), out_len)
    if rc != -1:
        raise Error("NULL ctx returned " + String(rc) + ", want -1")
    if out_len[0] != 77 or buf[0] != 5:
        raise Error("a NULL-context call wrote into the caller's memory")
    # A NULL context outranks a NULL out_len: the first check is the context.
    rc = lib.call["komira_last_error", Int32](Int(0), Int(0), UInt64(0), Int(0))
    if rc != -1:
        raise Error("NULL ctx and NULL out_len returned " + String(rc) + ", want -1")
    buf.free()
    out_len.free()
    print("ok")
