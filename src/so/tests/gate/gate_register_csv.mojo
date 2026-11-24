# komira_register_csv: a CSV file bound into the session as a table by name.
#
# Rows: a good file is 0 and leaves no error, for each dialect argument
# (another delimiter, no header, all_varchar, and any non-zero int32_t as
# true); a name already registered, in any case and by either call, is -3
# with TABLE_ALREADY_REGISTERED word for word; an empty name is -3 with
# TABLE_NAME_EMPTY; a NULL context is -1; a NULL name or NULL path is -2 with
# the named last error; a missing file, an empty file and a path that is not
# UTF-8 are -3 with a last error; a refused name is not taken, and the next
# good call clears the earlier error.
# A gate driver of //src/so:libkomira. It has no dependency: it opens
# the library with dlopen (RTLD_NOW, through OwnedDLHandle) and calls the
# C symbols as a foreign host would. A context handle and a string are passed
# as the integer word of their address (a `void *` and an Int are passed the
# same way on both supported targets); NULL is the word 0. The inputs are
# files the driver writes under $TEST_TMPDIR.

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


def _not_utf8_path() -> Int:
    # A NUL-terminated path whose second byte, 0xFF, is never valid UTF-8.
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


def _expect_some_error(lib: OwnedDLHandle, ctx: Int, what: String) raises:
    _expect(_last_error(lib, ctx).byte_length() > 0, what + " stored no error")


def _reg(
    lib: OwnedDLHandle, ctx: Int, name: Int, path: Int, delim: UInt8, header: Int32, varchar: Int32
) raises -> Int32:
    return lib.call["komira_register_csv", Int32](ctx, name, path, delim, header, varchar)


def main() raises:
    var lib = OwnedDLHandle(LIB)
    var comma = UInt8(ord(","))
    var good_c = _cstr(_write_text(String("people.csv"), String("id,name\n1,ann\n2,bob\n")))
    var pipe_c = _cstr(_write_text(String("pipe.csv"), String("id|name\n1|ann\n")))
    var bare_c = _cstr(_write_text(String("bare.csv"), String("1,2\n3,4\n")))
    var empty_c = _cstr(_write_text(String("empty.csv"), String("")))
    var missing_c = _cstr(_tmpdir() + "/no_such_file.csv")
    var not_utf8_c = _not_utf8_path()
    var ctx = lib.call["komira_ctx_new", Int]()
    _expect(ctx != 0, "komira_ctx_new returned NULL")

    _expect(_reg(lib, ctx, _cstr("people"), good_c, comma, 1, 0) == 0, "a good file was refused")
    _expect_error(lib, ctx, String(""), "a good file")
    _expect(_reg(lib, ctx, _cstr("piped"), pipe_c, UInt8(ord("|")), 1, 0) == 0, "a | file was refused")
    _expect(_reg(lib, ctx, _cstr("bare"), bare_c, comma, 0, 0) == 0, "a file with no header was refused")
    _expect(_reg(lib, ctx, _cstr("text"), good_c, comma, 1, 1) == 0, "all_varchar was refused")
    _expect(_reg(lib, ctx, _cstr("wide"), good_c, comma, -7, 9) == 0, "non-zero int32_t flags were refused")

    _expect(_reg(lib, ctx, _cstr("people"), good_c, comma, 1, 0) == -3, "a taken name is not -3")
    _expect_error(
        lib,
        ctx,
        String("TABLE_ALREADY_REGISTERED: the session already has a table named 'people'"),
        "a taken name",
    )
    _expect(_reg(lib, ctx, _cstr("PEOPLE"), good_c, comma, 1, 0) == -3, "a taken name in upper case is not -3")
    _expect_error(
        lib,
        ctx,
        String("TABLE_ALREADY_REGISTERED: the session already has a table named 'PEOPLE'"),
        "a taken name in upper case",
    )
    var json_c = _cstr(_write_text(String("rows.json"), String("{\"a\":1}\n")))
    _expect(
        lib.call["komira_register_json", Int32](ctx, _cstr("bare"), json_c) == -3,
        "a CSV table's name taken by komira_register_json is not -3",
    )
    _expect(_reg(lib, ctx, _cstr(""), good_c, comma, 1, 0) == -3, "an empty name is not -3")
    _expect_error(lib, ctx, String("TABLE_NAME_EMPTY: a table name must not be empty"), "an empty name")

    _expect(_reg(lib, 0, _cstr("t"), good_c, comma, 1, 0) == -1, "NULL ctx is not -1")
    _expect(_reg(lib, 0, 0, 0, comma, 1, 0) == -1, "NULL ctx and NULL args is not -1")
    _expect(_reg(lib, ctx, 0, good_c, comma, 1, 0) == -2, "NULL name is not -2")
    _expect_error(lib, ctx, String("komira_register_csv: name or path is NULL"), "NULL name")
    _expect(_reg(lib, ctx, _cstr("t"), 0, comma, 1, 0) == -2, "NULL path is not -2")
    _expect_error(lib, ctx, String("komira_register_csv: name or path is NULL"), "NULL path")

    _expect(_reg(lib, ctx, _cstr("t"), missing_c, comma, 1, 0) == -3, "a missing file is not -3")
    _expect_some_error(lib, ctx, "a missing file")
    _expect(_reg(lib, ctx, _cstr("t"), empty_c, comma, 1, 0) == -3, "an empty file is not -3")
    _expect_some_error(lib, ctx, "an empty file")
    _expect(_reg(lib, ctx, _cstr("t"), not_utf8_c, comma, 1, 0) == -3, "a path that is not UTF-8 is not -3")
    _expect_error(lib, ctx, String("a string argument is not valid UTF-8"), "a path that is not UTF-8")

    # Every refusal above left the name `t` free.
    _expect(_reg(lib, ctx, _cstr("t"), good_c, comma, 1, 0) == 0, "a good file after a refusal was refused")
    _expect_error(lib, ctx, String(""), "a good call after a refusal")
    lib.call["komira_ctx_free", NoneType](ctx)
    print("ok")
