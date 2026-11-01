# komira_csv_binding: a CSV file's scan binding through the two-call protocol.
#
# Rows: a good file gives the binding bytes (naming the path and the CSV kind)
# by the protocol: zero capacity and one byte short give -4 with the length and
# write nothing, an exact and a larger buffer give the same bytes and write
# nothing past them; a NULL context is -1 and writes nothing; a NULL path or
# NULL out_len is -2 with a last error; a missing file is -3 with a last
# error; the delimiter, the header flag and the all-varchar flag each change
# the bytes, and any non-zero flag is true; a good call after a refusal leaves
# no error.
#
# A gate driver of //src/komira_so:libkomira. It has no dependency: it opens
# the library with dlopen (RTLD_NOW, through OwnedDLHandle) and calls the
# C symbols as a foreign host would. A context handle, a string and a buffer
# are passed as the integer word of their address (a `void *` and an Int are
# passed the same way on both supported targets); NULL is the word 0. The
# inputs are files the driver writes under $TEST_TMPDIR.

from std.ffi import OwnedDLHandle
from std.memory import alloc
from std.os import getenv
from std.sys import CompilationTarget

comptime LIB = "./libkomira.dylib" if CompilationTarget.is_macos() else "./libkomira.so"
comptime SENTINEL = UInt8(0xAB)
comptime CAP = 4096


def _expect(ok: Bool, what: String) raises:
    if not ok:
        raise Error(what)


def _tmpdir() raises -> String:
    var d = getenv("TEST_TMPDIR", "")
    if d == "":
        raise Error("TEST_TMPDIR is unset")
    return d^


def _cstr(s: String) -> Int:
    # The address of a NUL-terminated copy of `s`. It is not freed: the driver
    # is a short-lived process and holds a handful of these.
    var b = s.as_bytes()
    var p = alloc[UInt8](len(b) + 1)
    for i in range(len(b)):
        p[i] = b[i]
    p[len(b)] = UInt8(0)
    return Int(p)


def _write_text(name: String, text: String) raises -> String:
    var path = _tmpdir() + "/" + name
    with open(path, "w") as f:
        f.write(text)
    return path^


def _hex_value(c: UInt8) -> Int:
    if c >= UInt8(ord("0")) and c <= UInt8(ord("9")):
        return Int(c) - ord("0")
    return Int(c) - ord("a") + 10


def _from_hex(hex: String) -> List[UInt8]:
    var b = hex.as_bytes()
    var out = List[UInt8]()
    var i = 0
    while i + 1 < len(b):
        out.append(UInt8(_hex_value(b[i]) * 16 + _hex_value(b[i + 1])))
        i += 2
    return out^


def _write_bytes(name: String, bytes: List[UInt8]) raises -> String:
    var path = _tmpdir() + "/" + name
    with open(path, "w") as f:
        f.write_bytes(Span(bytes))
    return path^


def _contains(haystack: List[UInt8], needle: String) -> Bool:
    var nb = needle.as_bytes()
    var n = len(nb)
    if n == 0:
        return True
    if len(haystack) < n:
        return False
    for i in range(len(haystack) - n + 1):
        var ok = True
        for j in range(n):
            if haystack[i + j] != nb[j]:
                ok = False
                break
        if ok:
            return True
    return False


def _last_error(lib: OwnedDLHandle, ctx: Int) raises -> List[UInt8]:
    # SAFETY: allocated here and freed below; the library writes the 8 bytes of
    # `out_len` and at most CAP bytes of `buf`.
    var out_len = alloc[UInt64](1)
    var buf = alloc[UInt8](CAP)
    var rc = lib.call["komira_last_error", Int32](ctx, buf, UInt64(CAP), out_len)
    _expect(rc == 0, "komira_last_error returned " + String(rc))
    var text = List[UInt8]()
    for i in range(Int(out_len[0])):
        text.append(buf[i])
    buf.free()
    out_len.free()
    return text^


def _call(
    lib: OwnedDLHandle, ctx: Int, arg: Int, arg_len: UInt64, buf: Int, cap: UInt64, out_len: Int
) raises -> Int32:
    return lib.call["komira_csv_binding", Int32](
        ctx, arg, UInt8(ord(",")), Int32(1), Int32(0), buf, cap, out_len
    )


def _binding(
    lib: OwnedDLHandle, ctx: Int, path: Int, delimiter: UInt8, header: Int32, varchar: Int32
) raises -> List[UInt8]:
    var out_len = alloc[UInt64](1)
    var buf = alloc[UInt8](CAP)
    var rc = lib.call["komira_csv_binding", Int32](
        ctx, path, delimiter, header, varchar, Int(buf), UInt64(CAP), Int(out_len)
    )
    _expect(rc == 0, "komira_csv_binding returned " + String(rc))
    var out = List[UInt8]()
    for i in range(Int(out_len[0])):
        out.append(buf[i])
    buf.free()
    out_len.free()
    return out^


def _check_protocol(
    lib: OwnedDLHandle, ctx: Int, arg: Int, arg_len: UInt64, want: String
) raises -> List[UInt8]:
    # The two-call protocol on a good input: a probe, a buffer one byte short,
    # an exact buffer and a larger one. Returns the bytes.
    # SAFETY: allocated here and freed below; the library writes the 8 bytes of
    # `out_len` and at most `cap` bytes of `buf`, where cap is what is passed.
    var out_len = alloc[UInt64](1)
    var buf = alloc[UInt8](CAP)
    for i in range(CAP):
        buf[i] = SENTINEL

    out_len[0] = UInt64(0)
    var rc = _call(lib, ctx, arg, arg_len, 0, UInt64(0), Int(out_len))
    _expect(rc == -4, "zero-capacity probe returned " + String(rc) + ", want -4")
    var n = Int(out_len[0])
    _expect(n > 0 and n < CAP, "probe reported length " + String(n))

    out_len[0] = UInt64(0)
    rc = _call(lib, ctx, arg, arg_len, Int(buf), UInt64(n - 1), Int(out_len))
    _expect(rc == -4 and Int(out_len[0]) == n, "short buffer: rc " + String(rc))
    for i in range(CAP):
        _expect(buf[i] == SENTINEL, "a too-small call wrote into the buffer")

    out_len[0] = UInt64(0)
    rc = _call(lib, ctx, arg, arg_len, Int(buf), UInt64(n), Int(out_len))
    _expect(rc == 0 and Int(out_len[0]) == n, "exact buffer: rc " + String(rc))
    _expect(buf[n] == SENTINEL, "the call wrote past the reported length")
    var first = List[UInt8]()
    for i in range(n):
        first.append(buf[i])
    _expect(_contains(first, want), "the output does not hold `" + want + "`")

    for i in range(CAP):
        buf[i] = SENTINEL
    out_len[0] = UInt64(0)
    rc = _call(lib, ctx, arg, arg_len, Int(buf), UInt64(CAP), Int(out_len))
    _expect(rc == 0 and Int(out_len[0]) == n, "larger buffer: rc " + String(rc))
    _expect(buf[n] == SENTINEL, "the call wrote past the reported length")
    for i in range(n):
        _expect(buf[i] == first[i], "byte " + String(i) + " differs on the second call")

    # A call that succeeded leaves no error behind from an earlier refusal.
    _expect(len(_last_error(lib, ctx)) == 0, "a good call left an error")
    buf.free()
    out_len.free()
    return first^


def _check_refusals(
    lib: OwnedDLHandle,
    ctx: Int,
    arg: Int,
    arg_len: UInt64,
    bad: Int,
    bad_len: UInt64,
) raises:
    # SAFETY: allocated here and freed below.
    var out_len = alloc[UInt64](1)
    var buf = alloc[UInt8](CAP)

    # A NULL context is -1 and writes nothing, even beside NULL arguments.
    out_len[0] = UInt64(77)
    buf[0] = UInt8(5)
    var rc = _call(lib, 0, arg, arg_len, Int(buf), UInt64(CAP), Int(out_len))
    _expect(rc == -1, "NULL ctx returned " + String(rc) + ", want -1")
    _expect(out_len[0] == 77 and buf[0] == 5, "a NULL-context call wrote")
    rc = _call(lib, 0, 0, arg_len, 0, UInt64(0), 0)
    _expect(rc == -1, "NULL ctx and NULL args returned " + String(rc) + ", want -1")

    # A NULL input is -2 and the session says so.
    rc = _call(lib, ctx, 0, arg_len, Int(buf), UInt64(CAP), Int(out_len))
    _expect(rc == -2, "NULL input returned " + String(rc) + ", want -2")
    _expect(len(_last_error(lib, ctx)) > 0, "NULL input stored no error")
    _expect(out_len[0] == 77, "a refused call set the length")

    # A NULL out_len is -2.
    rc = _call(lib, ctx, arg, arg_len, Int(buf), UInt64(CAP), 0)
    _expect(rc == -2, "NULL out_len returned " + String(rc) + ", want -2")

    # An input the engine refuses is -3 with its message as the last error.
    rc = _call(lib, ctx, bad, bad_len, Int(buf), UInt64(CAP), Int(out_len))
    _expect(rc == -3, "a bad input returned " + String(rc) + ", want -3")
    _expect(len(_last_error(lib, ctx)) > 0, "a bad input stored no error")
    _expect(out_len[0] == 77, "a refused call set the length")
    buf.free()
    out_len.free()


def main() raises:
    var lib = OwnedDLHandle(LIB)
    var good = _write_text(String("t.csv"), String("a,b\n1,x\n2,y\n"))
    var good_c = _cstr(good)
    var missing_c = _cstr(String("/no/such/file.csv"))
    var ctx = lib.call["komira_ctx_new", Int]()
    _expect(ctx != 0, "komira_ctx_new returned NULL")
    _check_refusals(lib, ctx, good_c, UInt64(0), missing_c, UInt64(0))
    var base = _check_protocol(lib, ctx, good_c, UInt64(0), good)
    _expect(_contains(base, String("komira.csv")), "the binding does not name the CSV kind")

    var comma = UInt8(ord(","))
    _expect(_binding(lib, ctx, good_c, comma, Int32(1), Int32(0)) == base, "the binding is not repeatable")
    _expect(_binding(lib, ctx, good_c, UInt8(ord(";")), Int32(1), Int32(0)) != base, "the delimiter did not change the binding")
    _expect(_binding(lib, ctx, good_c, comma, Int32(0), Int32(0)) != base, "has_header did not change the binding")
    _expect(_binding(lib, ctx, good_c, comma, Int32(1), Int32(1)) != base, "all_varchar did not change the binding")
    _expect(_binding(lib, ctx, good_c, comma, Int32(7), Int32(0)) == base, "a non-zero has_header is not true")
    lib.call["komira_ctx_free", NoneType](ctx)
    print("ok")
