# komira_add_sql_binding: a table bound to the bytes of a WireBoundSource.
#
# Rows: a source naming a local Parquet file binds with 0 and leaves no error, and the same name
# binds again (a taken name is replaced); a NULL context is -1; a NULL name or a NULL source is -2
# with the named last error; a source_len of 64 MiB plus one is -5 with the named last error (the
# source is not read); a scope other than 1 is -3 BIND_SCOPE_UNSUPPORTED, an empty name -3
# TABLE_NAME_EMPTY, a one-byte source (a tag with no length) -3 BIND_SOURCE_MALFORMED "is not a",
# a zero-length source -3 BIND_SOURCE_MALFORMED "names no kind", a name that is not UTF-8 -3, a
# local file that is missing -3 and a gs:// location that names no credential -3
# CREDENTIALS_NOT_FOUND (the library routes gs:// to its GCS store, which refuses a source with no
# credential before anything is dialed), each with its last error word for word, its step (2, bind)
# and, where the text has one, its code; the good call after each refusal clears the error. What a bound
# table answers is the C driver's rows (src/so/tests/c/abi_driver.c).
#
# A gate driver of //src/so:libkomira. It has no dependency: it opens the library with dlopen
# (RTLD_NOW, through OwnedDLHandle) and calls the C symbols as a foreign host would. A context
# handle, a string and a buffer are passed as the integer word of their address (a `void *` and an
# Int are passed the same way on both supported targets); NULL is the word 0. The Parquet file is
# one the driver writes under $TEST_TMPDIR; the source bytes are the protobuf encoding of
# WireBoundSource { files { location = <path> } } written by hand.

from std.ffi import OwnedDLHandle
from std.memory import alloc
from std.os import getenv
from std.sys import CompilationTarget

comptime LIB = "./libkomira.dylib" if CompilationTarget.is_macos() else "./libkomira.so"
comptime CAP = 4096
comptime STEP_BIND = Int32(2)
comptime MAX_INPUT = UInt64(64 * 1024 * 1024)
comptime PARQUET_HEX = "504152311504193c35001806736368656d6115040015042502180369363400150c250218017325004c1c0000001600191c192c26001c150419150619180369363415021600160016002600490c000026001c150c1915061918017315021600160016002600490c0000160016002600160000191c180c4152524f573a736368656d6118ec012f2f2f2f2f36674141414151414141414141414b41417741426741464141674143674141414141424241414d41414141434141494141414142414149414141414241414141414941414142414141414142414141414e6a2f2f2f3841414145464541414141426741414141454141414141414141414145414141427a41414141424141454141514141414151414251414341414741416341444141414142414145414141414141414151495141414141484141414141514141414141414141414177414141476b324e414149414177414341414841416741414141414141414251414141414141414141413d001820706172717565742d6370702d6172726f772076657273696f6e2032342e302e30192c1c00001c0000009901000050415231"


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
    p[0] = UInt8(ord("t"))
    p[1] = UInt8(0xFF)
    p[2] = UInt8(ord("x"))
    p[3] = UInt8(0)
    return Int(p)


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


def _varint(mut out: List[UInt8], value: Int):
    var v = value
    while v >= 0x80:
        out.append(UInt8((v & 0x7F) | 0x80))
        v >>= 7
    out.append(UInt8(v))


def _files_source(location: String) -> List[UInt8]:
    # WireBoundSource { files = 1 { location = 1 } }: two nested length-delimited fields.
    var inner = List[UInt8]()
    inner.append(UInt8(0x0A))
    _varint(inner, len(location.as_bytes()))
    for b in location.as_bytes():
        inner.append(b)
    var out = List[UInt8]()
    out.append(UInt8(0x0A))
    _varint(out, len(inner))
    for b in inner:
        out.append(b)
    return out^


def _bytes_ptr(bytes: List[UInt8]) -> Int:
    # The address of a copy of `bytes` (at least one byte is allocated, so a zero-length source is
    # still a non-NULL pointer). It is not freed: the driver is a short-lived process.
    # SAFETY: a fresh allocation of max(len, 1) bytes, owned by this process for its life; every
    # write below is inside it.
    var p = alloc[UInt8](max(len(bytes), 1))
    p[0] = UInt8(0)
    for i in range(len(bytes)):
        p[i] = bytes[i]
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


def _expect_error(lib: OwnedDLHandle, ctx: Int, want: String, what: String) raises:
    var got = _read(lib, ctx, False)
    _expect(got == want, what + ": the last error is '" + got + "', want '" + want + "'")


def _expect_refusal(
    lib: OwnedDLHandle, ctx: Int, want: String, code: String, what: String
) raises:
    _expect_error(lib, ctx, want, what)
    var got_code = _read(lib, ctx, True)
    _expect(got_code == code, what + ": the last error's code is '" + got_code + "', want '" + code + "'")
    var step = lib.call["komira_last_error_step", Int32](ctx)
    _expect(step == STEP_BIND, what + ": the last error's step is " + String(step) + ", want 2")


def _bind(
    lib: OwnedDLHandle, ctx: Int, name: Int, source: Int, source_len: UInt64, scope: Int32
) raises -> Int32:
    return lib.call["komira_add_sql_binding", Int32](ctx, name, source, source_len, scope)


def _bind_bytes(
    lib: OwnedDLHandle, ctx: Int, name: Int, bytes: List[UInt8], scope: Int32
) raises -> Int32:
    return _bind(lib, ctx, name, _bytes_ptr(bytes), UInt64(len(bytes)), scope)


def main() raises:
    var lib = OwnedDLHandle(LIB)
    var good_path = _write_bytes(String("two_columns.parquet"), _from_hex(String(PARQUET_HEX)))
    var good = _files_source(good_path)
    var missing = _files_source(String("/no/such/file.parquet"))
    var name_c = _cstr("two")
    var ctx = lib.call["komira_ctx_new", Int]()
    _expect(ctx != 0, "komira_ctx_new returned NULL")
    var one = Int32(1)

    _expect(_bind_bytes(lib, ctx, name_c, good, one) == 0, "a local file source was refused")
    _expect_error(lib, ctx, String(""), "a local file source")
    _expect(_bind_bytes(lib, ctx, name_c, good, one) == 0, "binding a taken name was refused")
    _expect_error(lib, ctx, String(""), "binding a taken name")

    _expect(_bind_bytes(lib, 0, name_c, good, one) == -1, "NULL ctx is not -1")
    _expect(_bind(lib, 0, 0, 0, UInt64(0), Int32(0)) == -1, "NULL ctx and NULL args is not -1")

    var none = String("komira_add_sql_binding: name or source is NULL")
    _expect(_bind(lib, ctx, 0, _bytes_ptr(good), UInt64(len(good)), one) == -2, "NULL name is not -2")
    _expect_error(lib, ctx, none, "NULL name")
    _expect(_bind(lib, ctx, name_c, 0, UInt64(len(good)), one) == -2, "NULL source is not -2")
    _expect_error(lib, ctx, none, "NULL source")
    _expect(_bind(lib, ctx, name_c, 0, UInt64(0), one) == -2, "NULL source of length 0 is not -2")
    _expect_error(lib, ctx, none, "NULL source of length 0")

    # Above the bound: not read, so a one-byte buffer stands for the source.
    _expect(
        _bind(lib, ctx, name_c, _bytes_ptr(good), MAX_INPUT + UInt64(1), one) == -5,
        "a source_len of 64 MiB plus one is not -5",
    )
    _expect_error(
        lib, ctx, String("komira_add_sql_binding: source_len is above 67108864 bytes"), "source_len above the bound"
    )
    _expect(
        _bind(lib, ctx, name_c, _bytes_ptr(good), UInt64(0xFFFFFFFFFFFFFFFF), one) == -5,
        "a source_len of UINT64_MAX is not -5",
    )

    _expect(_bind_bytes(lib, ctx, name_c, good, Int32(2)) == -3, "scope 2 is not -3")
    _expect_refusal(
        lib,
        ctx,
        String(
            "BIND_SCOPE_UNSUPPORTED: add_sql_binding scope=2: only KOMIRA_BIND_SESSION (1) binds a source"
        ),
        String("BIND_SCOPE_UNSUPPORTED"),
        "scope 2",
    )
    _expect(_bind_bytes(lib, ctx, name_c, good, Int32(0)) == -3, "scope 0 is not -3")
    _expect_error(
        lib,
        ctx,
        String(
            "BIND_SCOPE_UNSUPPORTED: add_sql_binding scope=0: only KOMIRA_BIND_SESSION (1) binds a source"
        ),
        "scope 0",
    )
    _expect(_bind_bytes(lib, ctx, _cstr(""), good, one) == -3, "an empty name is not -3")
    _expect_refusal(
        lib,
        ctx,
        String("TABLE_NAME_EMPTY: a table name must not be empty"),
        String("TABLE_NAME_EMPTY"),
        "an empty name",
    )
    _expect(_bind_bytes(lib, ctx, _not_utf8_text(), good, one) == -3, "a name that is not UTF-8 is not -3")
    _expect_error(lib, ctx, String("a string argument is not valid UTF-8"), "a name that is not UTF-8")

    var tag_only = List[UInt8]()
    tag_only.append(UInt8(0x0A))
    _expect(_bind_bytes(lib, ctx, name_c, tag_only, one) == -3, "a one-byte source is not -3")
    _expect_refusal(
        lib,
        ctx,
        String(
            "BIND_SOURCE_MALFORMED: add_sql_binding name=two: the source is not a"
            " komira.plan.v1.WireBoundSource"
        ),
        String("BIND_SOURCE_MALFORMED"),
        "a one-byte source",
    )
    var empty = List[UInt8]()
    _expect(_bind_bytes(lib, ctx, name_c, empty, one) == -3, "a zero-length source is not -3")
    _expect_refusal(
        lib,
        ctx,
        String("BIND_SOURCE_MALFORMED: add_sql_binding name=two: the source names no kind"),
        String("BIND_SOURCE_MALFORMED"),
        "a zero-length source",
    )

    _expect(_bind_bytes(lib, ctx, name_c, missing, one) == -3, "a missing local file is not -3")
    _expect(_read(lib, ctx, False).byte_length() > 0, "a missing local file stored no error")
    _expect(
        lib.call["komira_last_error_step", Int32](ctx) == STEP_BIND,
        "a missing local file's step is not bind",
    )

    var gcs = _files_source(String("gs://lake/t/a.parquet"))
    _expect(_bind_bytes(lib, ctx, name_c, gcs, one) == -3, "a gs:// source with no credential is not -3")
    _expect_refusal(
        lib,
        ctx,
        String(
            "CREDENTIALS_NOT_FOUND: add_sql_binding name=two: the source names no credential, or"
            " ambient, which this library does not resolve; name a sealed credential"
        ),
        String("CREDENTIALS_NOT_FOUND"),
        "a gs:// source with no credential",
    )

    _expect(_bind_bytes(lib, ctx, name_c, good, one) == 0, "a good call after a refusal was refused")
    _expect_error(lib, ctx, String(""), "a good call after a refusal")
    lib.call["komira_ctx_free", NoneType](ctx)
    print("ok")
