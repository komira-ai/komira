# komira_last_error on a fresh session: OK, length 0, a zero-capacity probe with a NULL buffer is OK, and nothing is written.
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
comptime SENTINEL = UInt8(0xAB)


def main() raises:
    var lib = OwnedDLHandle(LIB)
    var ctx = lib.call["komira_ctx_new", Int]()
    if ctx == 0:
        raise Error("komira_ctx_new returned NULL")
    # SAFETY: both blocks are allocated here, freed below, and the library
    # writes at most the 8 bytes of `out_len` and, never, the buffer.
    var out_len = alloc[UInt64](1)
    var buf = alloc[UInt8](8)
    for i in range(8):
        buf[i] = SENTINEL

    out_len[0] = UInt64(99)
    var rc = lib.call["komira_last_error", Int32](ctx, buf, UInt64(8), out_len)
    if rc != 0:
        raise Error("last_error on a fresh session returned " + String(rc))
    if out_len[0] != 0:
        raise Error("fresh session error length is " + String(out_len[0]))
    for i in range(8):
        if buf[i] != SENTINEL:
            raise Error("an empty error wrote into the buffer")

    # The probe call of the two-call protocol: capacity 0, no buffer at all.
    out_len[0] = UInt64(99)
    rc = lib.call["komira_last_error", Int32](ctx, Int(0), UInt64(0), out_len)
    if rc != 0 or out_len[0] != 0:
        raise Error("zero-capacity probe: rc " + String(rc) + ", len " + String(out_len[0]))

    lib.call["komira_ctx_free", NoneType](ctx)
    buf.free()
    out_len.free()
    print("ok")
