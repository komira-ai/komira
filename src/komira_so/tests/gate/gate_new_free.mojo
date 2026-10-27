# komira_ctx_new returns distinct non-NULL handles with independent state; komira_ctx_free releases them and accepts NULL.
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
    var a = lib.call["komira_ctx_new", Int]()
    var b = lib.call["komira_ctx_new", Int]()
    if a == 0 or b == 0:
        raise Error("komira_ctx_new returned NULL")
    if a == b:
        raise Error("two live contexts share one handle")
    # Distinct addresses are not enough: the two handles must be two sessions.
    # A refused call stores its refusal in the handle it was made on (a NULL
    # out_len, -2), so `a` then holds text and `b` still holds none.
    var rc = lib.call["komira_last_error", Int32](a, Int(0), UInt64(0), Int(0))
    if rc != -2:
        raise Error("NULL out_len on a live context returned " + String(rc) + ", want -2")
    # SAFETY: allocated here, freed below; out_len is one UInt64 slot.
    var len_a = alloc[UInt64](1)
    var len_b = alloc[UInt64](1)
    len_a[0] = UInt64(99)
    len_b[0] = UInt64(99)
    rc = lib.call["komira_last_error", Int32](a, Int(0), UInt64(0), len_a)
    if rc != -4 or len_a[0] == 0:
        raise Error("the first context kept no refusal text")
    rc = lib.call["komira_last_error", Int32](b, Int(0), UInt64(0), len_b)
    if rc != 0 or len_b[0] != 0:
        raise Error("a refusal on one context showed in the other")
    len_a.free()
    len_b.free()
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
