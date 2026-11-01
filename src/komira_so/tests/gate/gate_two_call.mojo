# komira_last_error through the two-call protocol, on an error the session holds.
#
# A gate driver of //src/komira_so:libkomira. It has no dependency: it opens
# the library with dlopen (RTLD_NOW, through OwnedDLHandle) and calls the
# C symbols as a foreign host would. A context handle is held as the integer
# word the library returned and passed back as one (a `void *` and an Int are
# passed the same way on both supported targets); NULL is the word 0.
#
# A NULL out_len on a live session is refused with -2 and stores its refusal as
# the last error, which gives the session a text to read. Then: a zero-capacity
# call returns -4 and sets the length without writing; a buffer one byte short
# returns -4, sets the length and writes nothing; an exact buffer returns 0 and
# holds the text; and a larger buffer returns 0 with the same length and writes
# only that many bytes. The text is the same on every read.

from std.ffi import OwnedDLHandle
from std.memory import alloc
from std.sys import CompilationTarget

comptime LIB = "./libkomira.dylib" if CompilationTarget.is_macos() else "./libkomira.so"
comptime SENTINEL = UInt8(0xAB)
comptime WANT = "komira_last_error: out_len is NULL"


def main() raises:
    var want = String(WANT)
    var wb = want.as_bytes()
    var lib = OwnedDLHandle(LIB)
    var ctx = lib.call["komira_ctx_new", Int]()
    if ctx == 0:
        raise Error("komira_ctx_new returned NULL")
    var want_len = WANT.byte_length()
    # SAFETY: allocated here and freed below; the library writes the 8 bytes of
    # `out_len` and at most `cap` bytes of `buf`, where cap is what is passed.
    var out_len = alloc[UInt64](1)
    var buf = alloc[UInt8](64)
    for i in range(64):
        buf[i] = SENTINEL

    var rc = lib.call["komira_last_error", Int32](ctx, buf, UInt64(64), Int(0))
    if rc != -2:
        raise Error("NULL out_len returned " + String(rc) + ", want -2")

    # First call: capacity 0.
    out_len[0] = UInt64(0)
    rc = lib.call["komira_last_error", Int32](ctx, Int(0), UInt64(0), out_len)
    if rc != -4:
        raise Error("zero-capacity call returned " + String(rc) + ", want -4")
    if Int(out_len[0]) != want_len:
        raise Error("zero-capacity call set length " + String(out_len[0]))

    # One byte short: still -4, length set, buffer untouched.
    out_len[0] = UInt64(0)
    rc = lib.call["komira_last_error", Int32](ctx, buf, UInt64(want_len - 1), out_len)
    if rc != -4 or Int(out_len[0]) != want_len:
        raise Error("short buffer: rc " + String(rc) + ", len " + String(out_len[0]))
    for i in range(64):
        if buf[i] != SENTINEL:
            raise Error("a too-small call wrote into the buffer")

    # Exactly the length: the text, and nothing past it.
    out_len[0] = UInt64(0)
    rc = lib.call["komira_last_error", Int32](ctx, buf, UInt64(want_len), out_len)
    if rc != 0 or Int(out_len[0]) != want_len:
        raise Error("exact buffer: rc " + String(rc) + ", len " + String(out_len[0]))
    for i in range(want_len):
        if buf[i] != wb[i]:
            raise Error("byte " + String(i) + " of the exact-buffer text differs")
    if buf[want_len] != SENTINEL:
        raise Error("the call wrote past the reported length")

    # A larger buffer: the same text, the same length.
    for i in range(64):
        buf[i] = SENTINEL
    out_len[0] = UInt64(0)
    rc = lib.call["komira_last_error", Int32](ctx, buf, UInt64(64), out_len)
    if rc != 0 or Int(out_len[0]) != want_len:
        raise Error("larger buffer: rc " + String(rc) + ", len " + String(out_len[0]))
    for i in range(want_len):
        if buf[i] != wb[i]:
            raise Error("byte " + String(i) + " of the larger-buffer text differs")
    if buf[want_len] != SENTINEL:
        raise Error("the call wrote past the reported length")

    lib.call["komira_ctx_free", NoneType](ctx)
    buf.free()
    out_len.free()
    print("ok")
