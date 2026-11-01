# komira_register_parquet: a Parquet file bound into the session by name.
#
# Rows: a good file is 0 and leaves no error; the same name may be registered
# again; a NULL context is -1; a NULL name or NULL path is -2 with a last error;
# a missing file and a file that is not Parquet are -3 with the reader's message
# as the last error, and the next good call clears that error.
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

comptime PARQUET_HEX = "504152311504193c35001806736368656d6115040015042502180369363400150c250218017325004c1c0000001600191c192c26001c150419150619180369363415021600160016002600490c000026001c150c1915061918017315021600160016002600490c0000160016002600160000191c180c4152524f573a736368656d6118ec012f2f2f2f2f36674141414151414141414141414b41417741426741464141674143674141414141424241414d41414141434141494141414142414149414141414241414141414941414142414141414142414141414e6a2f2f2f3841414145464541414141426741414141454141414141414141414145414141427a41414141424141454141514141414151414251414341414741416341444141414142414145414141414141414151495141414141484141414141514141414141414141414177414141476b324e414149414177414341414841416741414141414141414251414141414141414141413d001820706172717565742d6370702d6172726f772076657273696f6e2032342e302e30192c1c00001c0000009901000050415231"


def _reg(lib: OwnedDLHandle, ctx: Int, name: Int, path: Int) raises -> Int32:
    return lib.call["komira_register_parquet", Int32](ctx, name, path)


def main() raises:
    var lib = OwnedDLHandle(LIB)
    var good_c = _cstr(_write_bytes(String("two_columns.parquet"), _from_hex(String(PARQUET_HEX))))
    var text_c = _cstr(_write_text(String("not_parquet.parquet"), String("this is text")))
    var missing_c = _cstr(String("/no/such/file.parquet"))
    var name_c = _cstr(String("two"))
    var ctx = lib.call["komira_ctx_new", Int]()
    _expect(ctx != 0, "komira_ctx_new returned NULL")

    _expect(_reg(lib, ctx, name_c, good_c) == 0, "a good file was refused")
    _expect(len(_last_error(lib, ctx)) == 0, "a good file left an error")
    _expect(_reg(lib, ctx, name_c, good_c) == 0, "registering a name twice was refused")

    _expect(_reg(lib, 0, name_c, good_c) == -1, "NULL ctx is not -1")
    _expect(_reg(lib, 0, 0, 0) == -1, "NULL ctx and NULL args is not -1")

    _expect(_reg(lib, ctx, 0, good_c) == -2, "NULL name is not -2")
    _expect(len(_last_error(lib, ctx)) > 0, "NULL name stored no error")
    _expect(_reg(lib, ctx, name_c, 0) == -2, "NULL path is not -2")
    _expect(len(_last_error(lib, ctx)) > 0, "NULL path stored no error")

    _expect(_reg(lib, ctx, name_c, missing_c) == -3, "a missing file is not -3")
    _expect(len(_last_error(lib, ctx)) > 0, "a missing file stored no error")
    _expect(_reg(lib, ctx, name_c, text_c) == -3, "a non-Parquet file is not -3")
    _expect(len(_last_error(lib, ctx)) > 0, "a non-Parquet file stored no error")

    _expect(_reg(lib, ctx, name_c, good_c) == 0, "a good file after a refusal was refused")
    _expect(len(_last_error(lib, ctx)) == 0, "the earlier error was not cleared")
    lib.call["komira_ctx_free", NoneType](ctx)
    print("ok")
