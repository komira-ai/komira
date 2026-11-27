# komira_register_csv_with_skip and komira_csv_binding_with_skip: a CSV file
# whose first lines are not data (ABI 1.11).
#
# Rows: a file with a note line above the header registers with skip 1; a
# file of no note registers with skip 0; a NULL context is -1; a NULL name or
# NULL path is -2 with the named last error; a negative skip is -3 with the
# CSV_SKIP_NEGATIVE message word for word at step bind, and the name stays
# free; a skip that leaves no line is -3 with CSV_SKIP_PAST_END word for word.
# The binding with skip 0 is the bytes of komira_csv_binding; with skip 1 it
# is other bytes that name the skip param; a NULL context is -1, a NULL path
# or out_len -2, a negative skip -3 with CSV_SKIP_NEGATIVE and no length
# written.
# A gate driver of //src/so:libkomira. It has no dependency: it opens
# the library with dlopen (RTLD_NOW, through OwnedDLHandle) and calls the
# C symbols as a foreign host would. A context handle and a string are passed
# as the integer word of their address; NULL is the word 0. The inputs are
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


def _reg(
    lib: OwnedDLHandle,
    ctx: Int,
    name: Int,
    path: Int,
    header: Int32,
    skip: Int64,
) raises -> Int32:
    return lib.call["komira_register_csv_with_skip", Int32](
        ctx, name, path, UInt8(ord(",")), header, Int32(0), skip
    )


def _binding(
    lib: OwnedDLHandle, ctx: Int, path: Int, skip: Int64, out_len: Int
) raises -> Int32:
    return lib.call["komira_csv_binding_with_skip", Int32](
        ctx, path, UInt8(ord(",")), Int32(1), Int32(0), skip, 0, UInt64(0), out_len
    )


def _bytes_with_skip(lib: OwnedDLHandle, ctx: Int, path: Int, skip: Int64) raises -> List[UInt8]:
    var out_len = alloc[UInt64](1)
    var buf = alloc[UInt8](CAP)
    var rc = lib.call["komira_csv_binding_with_skip", Int32](
        ctx, path, UInt8(ord(",")), Int32(1), Int32(0), skip, Int(buf), UInt64(CAP), Int(out_len)
    )
    _expect(rc == 0, "komira_csv_binding_with_skip returned " + String(rc))
    var out = List[UInt8]()
    for i in range(Int(out_len[0])):
        out.append(buf[i])
    buf.free()
    out_len.free()
    return out^


def _bytes_plain(lib: OwnedDLHandle, ctx: Int, path: Int) raises -> List[UInt8]:
    var out_len = alloc[UInt64](1)
    var buf = alloc[UInt8](CAP)
    var rc = lib.call["komira_csv_binding", Int32](
        ctx, path, UInt8(ord(",")), Int32(1), Int32(0), Int(buf), UInt64(CAP), Int(out_len)
    )
    _expect(rc == 0, "komira_csv_binding returned " + String(rc))
    var out = List[UInt8]()
    for i in range(Int(out_len[0])):
        out.append(buf[i])
    buf.free()
    out_len.free()
    return out^


def _contains(haystack: List[UInt8], needle: String) -> Bool:
    var nb = needle.as_bytes()
    var n = len(nb)
    for i in range(len(haystack) - n + 1):
        var ok = True
        for j in range(n):
            if haystack[i + j] != nb[j]:
                ok = False
                break
        if ok:
            return True
    return False


def main() raises:
    var lib = OwnedDLHandle(LIB)
    var plain_c = _cstr(_write_text(String("plain.csv"), String("id,name\n1,ann\n2,bob\n")))
    var note_c = _cstr(_write_text(String("note.csv"), String("exported by hand\nid,name\n1,ann\n")))
    var ctx = lib.call["komira_ctx_new", Int]()
    _expect(ctx != 0, "komira_ctx_new returned NULL")

    _expect(_reg(lib, ctx, _cstr("plain"), plain_c, 1, 0) == 0, "skip 0 was refused")
    _expect_error(lib, ctx, String(""), "skip 0")
    _expect(_reg(lib, ctx, _cstr("noted"), note_c, 1, 1) == 0, "skip 1 over a note line was refused")
    _expect_error(lib, ctx, String(""), "skip 1")

    _expect(_reg(lib, 0, _cstr("t"), note_c, 1, 1) == -1, "NULL ctx is not -1")
    _expect(_reg(lib, ctx, 0, note_c, 1, 1) == -2, "NULL name is not -2")
    _expect_error(lib, ctx, String("komira_register_csv_with_skip: name or path is NULL"), "NULL name")
    _expect(_reg(lib, ctx, _cstr("t"), 0, 1, 1) == -2, "NULL path is not -2")
    _expect_error(lib, ctx, String("komira_register_csv_with_skip: name or path is NULL"), "NULL path")

    var negative = String(
        "CSV_SKIP_NEGATIVE: skip=-1 is negative; skip is the number of lines to skip at the start of the file and"
        " must be 0 or more"
    )
    _expect(_reg(lib, ctx, _cstr("t"), note_c, 1, -1) == -3, "a negative skip is not -3")
    _expect_error(lib, ctx, negative, "a negative skip")
    _expect(lib.call["komira_last_error_step", Int32](ctx) == 2, "a negative skip is not at step bind")
    _expect(
        _reg(lib, ctx, _cstr("t"), note_c, 1, 3) == -3,
        "a skip past the last line is not -3",
    )
    _expect_error(
        lib,
        ctx,
        String(
            "CSV_SKIP_PAST_END: skip=3 skips every line of the file, which has 3 lines; no header or record is left"
            " to read"
        ),
        "a skip past the end",
    )
    # Every refusal above left the name `t` free.
    _expect(_reg(lib, ctx, _cstr("t"), note_c, 1, 1) == 0, "a good call after a refusal was refused")
    _expect_error(lib, ctx, String(""), "a good call after a refusal")

    # The binding.
    var plain = _bytes_plain(lib, ctx, plain_c)
    _expect(_bytes_with_skip(lib, ctx, plain_c, Int64(0)) == plain, "skip 0 is not the bytes of komira_csv_binding")
    var noted = _bytes_with_skip(lib, ctx, note_c, Int64(1))
    _expect(_contains(noted, String("skip")), "the binding of skip 1 does not name the skip param")
    _expect(not _contains(plain, String("skip")), "the binding of skip 0 names a skip param")
    _expect(_bytes_with_skip(lib, ctx, note_c, Int64(1)) == noted, "the binding of skip 1 is not repeatable")
    _expect(_bytes_with_skip(lib, ctx, plain_c, Int64(1)) != plain, "skip 1 did not change the binding")

    var out_len = alloc[UInt64](1)
    out_len[0] = UInt64(77)
    _expect(_binding(lib, 0, note_c, Int64(1), Int(out_len)) == -1, "NULL ctx is not -1")
    _expect(_binding(lib, ctx, 0, Int64(1), Int(out_len)) == -2, "NULL path is not -2")
    _expect_error(lib, ctx, String("komira_csv_binding_with_skip: path or out_len is NULL"), "NULL path")
    _expect(_binding(lib, ctx, note_c, Int64(1), 0) == -2, "NULL out_len is not -2")
    _expect(_binding(lib, ctx, note_c, Int64(-1), Int(out_len)) == -3, "a negative skip is not -3")
    _expect_error(lib, ctx, negative, "a negative skip binding")
    _expect(lib.call["komira_last_error_step", Int32](ctx) == 2, "a negative skip binding is not at step bind")
    _expect(out_len[0] == 77, "a refused call set the length")
    _expect(_binding(lib, ctx, note_c, Int64(3), Int(out_len)) == -3, "a skip past the end is not -3")
    _expect(out_len[0] == 77, "a refused call set the length")
    out_len.free()
    lib.call["komira_ctx_free", NoneType](ctx)
    print("ok")
