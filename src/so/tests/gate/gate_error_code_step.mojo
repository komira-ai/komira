# komira_last_error_code and komira_last_error_step exist and behave on a fresh session and a NULL context.
#
# A fresh session's code is empty (OK, length 0, nothing written, with or
# without a buffer) and its step is 0 (KOMIRA_STEP_NONE); a NULL context gives
# -1 for the code (nothing written) and step 0.
#
# A gate driver of //src/so:libkomira. It has no dependency: it opens
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
    if not lib.check_symbol("komira_last_error_code"):
        raise Error("komira_last_error_code is not exported")
    if not lib.check_symbol("komira_last_error_step"):
        raise Error("komira_last_error_step is not exported")
    var ctx = lib.call["komira_ctx_new", Int]()
    if ctx == 0:
        raise Error("komira_ctx_new returned NULL")
    # SAFETY: both blocks are allocated here and freed below; the library
    # writes at most the 8 bytes of `out_len` and never the buffer.
    var out_len = alloc[UInt64](1)
    var buf = alloc[UInt8](8)
    for i in range(8):
        buf[i] = SENTINEL

    var step = lib.call["komira_last_error_step", Int32](ctx)
    if step != 0:
        raise Error("a fresh session's step is " + String(step) + ", want 0")

    out_len[0] = UInt64(99)
    var rc = lib.call["komira_last_error_code", Int32](ctx, buf, UInt64(8), out_len)
    if rc != 0 or out_len[0] != 0:
        raise Error("fresh code: rc " + String(rc) + ", len " + String(out_len[0]))
    for i in range(8):
        if buf[i] != SENTINEL:
            raise Error("an empty code wrote into the buffer")

    # The probe call: capacity 0 and no buffer at all.
    out_len[0] = UInt64(99)
    rc = lib.call["komira_last_error_code", Int32](ctx, Int(0), UInt64(0), out_len)
    if rc != 0 or out_len[0] != 0:
        raise Error("code probe: rc " + String(rc) + ", len " + String(out_len[0]))

    # A NULL context: -1, nothing written, and step 0.
    out_len[0] = UInt64(99)
    rc = lib.call["komira_last_error_code", Int32](Int(0), buf, UInt64(8), out_len)
    if rc != -1:
        raise Error("NULL ctx code returned " + String(rc) + ", want -1")
    if out_len[0] != 99:
        raise Error("NULL ctx code wrote *out_len")
    for i in range(8):
        if buf[i] != SENTINEL:
            raise Error("NULL ctx code wrote into the buffer")
    step = lib.call["komira_last_error_step", Int32](Int(0))
    if step != 0:
        raise Error("a NULL context's step is " + String(step) + ", want 0")

    lib.call["komira_ctx_free", NoneType](ctx)
    buf.free()
    out_len.free()
    print("ok")
