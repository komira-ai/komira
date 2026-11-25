# komira_register_arrow_stream: the refusals a host meets before any chunk
# of its stream is read.
#
# Rows: a released stream (its `release` NULL) is -3 with the drain's
# refusal word for word, and none of its callbacks is called; an empty name is
# -3 with TABLE_NAME_EMPTY and a name that is not UTF-8 -3 with the named
# error; a NULL context is -1, with or without the other arguments; a NULL
# name or NULL stream is -2 with the named last error. Every refusal leaves
# the name free: komira_register_json then takes it and the good call clears
# the earlier error. The streams the library drains, and how often it
# releases them, are the C driver's rows (src/so/tests/c/abi_driver.c), which
# builds a producer in C.
# A gate driver of //src/so:libkomira. It has no dependency: it opens
# the library with dlopen (RTLD_NOW, through OwnedDLHandle) and calls the
# C symbols as a foreign host would. A context handle, a string and a stream
# are passed as the integer word of their address (a `void *` and an Int are
# passed the same way on both supported targets); NULL is the word 0. The JSON
# file is written under $TEST_TMPDIR.

from std.ffi import OwnedDLHandle
from std.memory import alloc
from std.os import getenv
from std.sys import CompilationTarget

comptime LIB = "./libkomira.dylib" if CompilationTarget.is_macos() else "./libkomira.so"
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
    # SAFETY: a fresh allocation of len(b) + 1 bytes, owned by this process
    # for its life; every write below is inside it.
    var p = alloc[UInt8](len(b) + 1)
    for i in range(len(b)):
        p[i] = b[i]
    p[len(b)] = UInt8(0)
    return Int(p)


def _not_utf8_text() -> Int:
    # A NUL-terminated string whose second byte, 0xFF, is never valid UTF-8.
    # SAFETY: a fresh allocation of 4 bytes, owned by this process for its
    # life; the four writes below are inside it.
    var p = alloc[UInt8](4)
    p[0] = UInt8(ord("/"))
    p[1] = UInt8(0xFF)
    p[2] = UInt8(ord("x"))
    p[3] = UInt8(0)
    return Int(p)


def _write_text(name: String, text: String) raises -> String:
    var path = _tmpdir() + "/" + name
    with open(path, "w") as f:
        f.write(text)
    return path^


def _released_stream() -> Int:
    # The address of a released `struct ArrowArrayStream`: five NULL words,
    # so its `release` is NULL and no callback of it may be called.
    # SAFETY: a fresh allocation of five words, owned by this process for its
    # life; the five writes below are inside it.
    var p = alloc[Int](5)
    for i in range(5):
        p[i] = 0
    return Int(p)


def _last_error(lib: OwnedDLHandle, ctx: Int) raises -> String:
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
    return String(unsafe_from_utf8=text)


def _expect_error(lib: OwnedDLHandle, ctx: Int, want: String, what: String) raises:
    var got = _last_error(lib, ctx)
    _expect(got == want, what + ": the last error is '" + got + "', want '" + want + "'")


def _reg(lib: OwnedDLHandle, ctx: Int, name: Int, stream: Int) raises -> Int32:
    return lib.call["komira_register_arrow_stream", Int32](ctx, name, stream)


def main() raises:
    var lib = OwnedDLHandle(LIB)
    var json_c = _cstr(_write_text(String("events.json"), String('{"id":1}\n')))
    var ctx = lib.call["komira_ctx_new", Int]()
    _expect(ctx != 0, "komira_ctx_new returned NULL")

    _expect(_reg(lib, ctx, _cstr("t"), _released_stream()) == -3, "a released stream is not -3")
    _expect_error(
        lib, ctx, String("from_arrow_c_stream: stream is already released"), "a released stream"
    )
    _expect(_reg(lib, ctx, _cstr(""), _released_stream()) == -3, "an empty name is not -3")
    _expect_error(lib, ctx, String("TABLE_NAME_EMPTY: a table name must not be empty"), "an empty name")
    _expect(_reg(lib, ctx, _not_utf8_text(), _released_stream()) == -3, "a name that is not UTF-8 is not -3")
    _expect_error(lib, ctx, String("a string argument is not valid UTF-8"), "a name that is not UTF-8")

    _expect(_reg(lib, 0, _cstr("t"), _released_stream()) == -1, "NULL ctx is not -1")
    _expect(_reg(lib, 0, 0, 0) == -1, "NULL ctx and NULL args is not -1")
    _expect(_reg(lib, ctx, 0, _released_stream()) == -2, "NULL name is not -2")
    _expect_error(lib, ctx, String("komira_register_arrow_stream: name or stream is NULL"), "NULL name")
    _expect(_reg(lib, ctx, _cstr("t"), 0) == -2, "NULL stream is not -2")
    _expect_error(lib, ctx, String("komira_register_arrow_stream: name or stream is NULL"), "NULL stream")

    # Every refusal above left the name `t` free.
    _expect(
        lib.call["komira_register_json", Int32](ctx, _cstr("t"), json_c) == 0,
        "the name of a refused stream is not free",
    )
    _expect_error(lib, ctx, String(""), "a good call after a refusal")
    lib.call["komira_ctx_free", NoneType](ctx)
    print("ok")
