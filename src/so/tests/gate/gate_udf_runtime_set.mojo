# komira_udf_runtime_set: the session given the UDF runtime library a plan's UDFs run on.
#
# Rows: a NULL context is -1; a NULL library or code root, or NULL options with a non-zero length,
# is -2 with the named last error; an options_len of 64 MiB plus one is -5 with the named last error
# (the options are not read); a library that is not there is -3 UDF_RUNTIME_OPEN_FAILED, a negative
# deadline -3 UDF_RUNTIME_CONFIG_INVALID, and options that are not UTF-8 -3, each with its code where
# the text has one and its step (2, bind). That a set
# runtime runs a plan's UDFs is held by the welded test test_plan_result_udfs, on the reference
# runtime; this driver holds the C surface.
#
# A gate driver of //src/so:libkomira. It has no dependency: it opens the library with dlopen
# (RTLD_NOW, through OwnedDLHandle) and calls the C symbols as a foreign host would. A context
# handle, a string and a buffer are passed as the integer word of their address; NULL is the word 0.

from std.ffi import OwnedDLHandle
from std.memory import alloc
from std.sys import CompilationTarget

comptime LIB = "./libkomira.dylib" if CompilationTarget.is_macos() else "./libkomira.so"
comptime CAP = 4096
comptime STEP_BIND = Int32(2)
comptime MAX_INPUT = UInt64(64 * 1024 * 1024)


def _expect(ok: Bool, what: String) raises:
    if not ok:
        raise Error(what)


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


def _not_utf8() -> Int:
    # Two bytes, the first 0xFF, which is never valid UTF-8.
    # SAFETY: a fresh allocation of 2 bytes, owned by this process for its life.
    var p = alloc[UInt8](2)
    p[0] = UInt8(0xFF)
    p[1] = UInt8(ord("x"))
    return Int(p)


def _read(lib: OwnedDLHandle, ctx: Int, code: Bool) raises -> String:
    # The last error's text (or, with `code`, its code) by the two-call protocol.
    # SAFETY: allocated here and freed below; the library writes the 8 bytes of
    # `out_len` and at most CAP bytes of `buf`.
    var out_len = alloc[UInt64](1)
    var buf = alloc[UInt8](CAP)
    var rc: Int32
    if code:
        rc = lib.call["komira_last_error_code", Int32](ctx, buf, UInt64(CAP), out_len)
    else:
        rc = lib.call["komira_last_error", Int32](ctx, buf, UInt64(CAP), out_len)
    _expect(rc == 0, "the last error call returned " + String(rc))
    var text = List[UInt8]()
    for i in range(Int(out_len[0])):
        text.append(buf[i])
    buf.free()
    out_len.free()
    return String(unsafe_from_utf8=text)


def _expect_refusal(lib: OwnedDLHandle, ctx: Int, prefix: String, code: String, what: String) raises:
    var got = _read(lib, ctx, False)
    _expect(got.startswith(prefix), what + ": the last error is '" + got + "', want it to start '" + prefix + "'")
    var got_code = _read(lib, ctx, True)
    _expect(got_code == code, what + ": the last error's code is '" + got_code + "', want '" + code + "'")
    var step = lib.call["komira_last_error_step", Int32](ctx)
    _expect(step == STEP_BIND, what + ": the last error's step is " + String(step) + ", want 2")


def _set(
    lib: OwnedDLHandle, ctx: Int, library: Int, root: Int, deadline: Int64, options: Int, options_len: UInt64
) raises -> Int32:
    return lib.call["komira_udf_runtime_set", Int32](ctx, library, root, deadline, options, options_len)


def main() raises:
    var lib = OwnedDLHandle(LIB)
    var ctx = lib.call["komira_ctx_new", Int]()
    _expect(ctx != 0, "komira_ctx_new returned NULL")
    var missing = _cstr("./no_such_runtime.so")
    var root = _cstr(".")
    var opts = _cstr("interpreter=/x")

    _expect(_set(lib, 0, missing, root, 0, 0, UInt64(0)) == -1, "NULL ctx is not -1")

    var none = String("komira_udf_runtime_set: library, code_root or options is NULL")
    _expect(_set(lib, ctx, 0, root, 0, 0, UInt64(0)) == -2, "NULL library is not -2")
    _expect(_read(lib, ctx, False) == none, "NULL library: the last error is not named")
    _expect(_set(lib, ctx, missing, 0, 0, 0, UInt64(0)) == -2, "NULL code root is not -2")
    _expect(_set(lib, ctx, missing, root, 0, 0, UInt64(3)) == -2, "NULL options of length 3 is not -2")
    _expect(_read(lib, ctx, False) == none, "NULL options: the last error is not named")

    _expect(_set(lib, ctx, missing, root, 0, opts, MAX_INPUT + 1) == -5, "64 MiB plus one is not -5")
    _expect(
        _read(lib, ctx, False) == "komira_udf_runtime_set: options_len is above 67108864 bytes",
        "too long: the last error is not named",
    )

    _expect(_set(lib, ctx, missing, root, 0, opts, UInt64(14)) == -3, "a missing library is not -3")
    _expect_refusal(lib, ctx, "bind: UDF_RUNTIME_OPEN_FAILED: ./no_such_runtime.so: ", "UDF_RUNTIME_OPEN_FAILED", "a missing library")
    _expect(_set(lib, ctx, missing, root, -1, 0, UInt64(0)) == -3, "a negative deadline is not -3")
    _expect_refusal(lib, ctx, "bind: UDF_RUNTIME_CONFIG_INVALID: ", "UDF_RUNTIME_CONFIG_INVALID", "a negative deadline")
    _expect(_set(lib, ctx, missing, root, 0, _not_utf8(), UInt64(2)) == -3, "options that are not UTF-8 are not -3")

    lib.call["komira_ctx_free", NoneType](ctx)
    print("gate_udf_runtime_set: ok")
