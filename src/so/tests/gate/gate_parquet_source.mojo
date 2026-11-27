# komira_parquet_source: the Parquet files a path names, as WireParquetSource
# bytes, through the two-call protocol.
#
# Rows: a glob over two files gives both paths, the one that sorts first first,
# by the protocol (zero capacity and one byte short give -4 with the length and
# write nothing, an exact and a larger buffer give the same bytes and write
# nothing past them); a directory of `k=1/` and `k=2/` folders gives both files
# and, with KOMIRA_HIVE_AUTO, more bytes than with KOMIRA_HIVE_OFF (the
# partition column `k` and its values); a NULL context is -1 and writes nothing;
# a NULL path or NULL out_len is -2 with a last error; a glob that matches
# nothing is -3 with PARQUET_GLOB_NO_MATCH and the pattern as the last error; a
# mode that is not a KOMIRA_HIVE_* value is -3 with HIVE_PARTITIONING_UNKNOWN; a
# good call after a refusal leaves no error.
#
# A gate driver of //src/so:libkomira. It has no dependency: it opens
# the library with dlopen (RTLD_NOW, through OwnedDLHandle) and calls the
# C symbols as a foreign host would. A context handle, a string and a buffer
# are passed as the integer word of their address; NULL is the word 0. The
# inputs are files the driver writes under $TEST_TMPDIR.

from std.ffi import OwnedDLHandle
from std.memory import alloc
from std.os import getenv, makedirs
from std.sys import CompilationTarget

comptime LIB = "./libkomira.dylib" if CompilationTarget.is_macos() else "./libkomira.so"
comptime SENTINEL = UInt8(0xAB)
comptime CAP = 4096
comptime HIVE_AUTO = Int32(0)
comptime HIVE_OFF = Int32(2)


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


def _index(haystack: List[UInt8], needle: String) -> Int:
    # The first offset of `needle` in `haystack`, or -1.
    var nb = needle.as_bytes()
    var n = len(nb)
    if len(haystack) < n:
        return -1
    for i in range(len(haystack) - n + 1):
        var ok = True
        for j in range(n):
            if haystack[i + j] != nb[j]:
                ok = False
                break
        if ok:
            return i
    return -1


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


def _call(
    lib: OwnedDLHandle, ctx: Int, path: Int, hive: Int32, buf: Int, cap: UInt64, out_len: Int
) raises -> Int32:
    return lib.call["komira_parquet_source", Int32](ctx, path, hive, buf, cap, out_len)


def _source(lib: OwnedDLHandle, ctx: Int, path: Int, hive: Int32) raises -> List[UInt8]:
    # The two-call protocol on a good path: a probe, a buffer one byte short,
    # an exact buffer and a larger one. Returns the bytes.
    # SAFETY: allocated here and freed below; the library writes the 8 bytes of
    # `out_len` and at most `cap` bytes of `buf`, where cap is what is passed.
    var out_len = alloc[UInt64](1)
    var buf = alloc[UInt8](CAP)
    for i in range(CAP):
        buf[i] = SENTINEL

    out_len[0] = UInt64(0)
    var rc = _call(lib, ctx, path, hive, 0, UInt64(0), Int(out_len))
    _expect(rc == -4, "zero-capacity probe returned " + String(rc) + ", want -4")
    var n = Int(out_len[0])
    _expect(n > 0 and n < CAP, "probe reported length " + String(n))

    out_len[0] = UInt64(0)
    rc = _call(lib, ctx, path, hive, Int(buf), UInt64(n - 1), Int(out_len))
    _expect(rc == -4 and Int(out_len[0]) == n, "short buffer: rc " + String(rc))
    for i in range(CAP):
        _expect(buf[i] == SENTINEL, "a too-small call wrote into the buffer")

    out_len[0] = UInt64(0)
    rc = _call(lib, ctx, path, hive, Int(buf), UInt64(n), Int(out_len))
    _expect(rc == 0 and Int(out_len[0]) == n, "exact buffer: rc " + String(rc))
    _expect(buf[n] == SENTINEL, "the call wrote past the reported length")
    var first = List[UInt8]()
    for i in range(n):
        first.append(buf[i])

    out_len[0] = UInt64(0)
    rc = _call(lib, ctx, path, hive, Int(buf), UInt64(CAP), Int(out_len))
    _expect(rc == 0 and Int(out_len[0]) == n, "larger buffer: rc " + String(rc))
    _expect(buf[n] == SENTINEL, "the call wrote past the reported length")
    for i in range(n):
        _expect(buf[i] == first[i], "byte " + String(i) + " differs on the second call")

    _expect(len(_last_error(lib, ctx)) == 0, "a good call left an error")
    buf.free()
    out_len.free()
    return first^


def _expect_refused(
    lib: OwnedDLHandle, ctx: Int, path: Int, hive: Int32, want: String
) raises:
    # A path or mode the engine refuses is -3, writes no length, and the last
    # error holds `want`.
    # SAFETY: allocated here and freed below.
    var out_len = alloc[UInt64](1)
    out_len[0] = UInt64(77)
    var rc = _call(lib, ctx, path, hive, 0, UInt64(0), Int(out_len))
    _expect(rc == -3, "a refused call returned " + String(rc) + ", want -3")
    _expect(out_len[0] == 77, "a refused call set the length")
    var error = _last_error(lib, ctx)
    _expect(_contains(error, want), "the last error does not hold `" + want + "`")
    out_len.free()


def main() raises:
    var lib = OwnedDLHandle(LIB)
    var file = _from_hex(String(PARQUET_HEX))
    var root = _tmpdir()
    makedirs(root + "/flat")
    makedirs(root + "/hive/k=1")
    makedirs(root + "/hive/k=2")
    var b = _write_bytes(String("flat/b.parquet"), file)
    var a = _write_bytes(String("flat/a.parquet"), file)
    _ = _write_bytes(String("hive/k=1/x.parquet"), file)
    _ = _write_bytes(String("hive/k=2/y.parquet"), file)
    var glob_c = _cstr(root + "/flat/*.parquet")
    var dir_c = _cstr(root + "/hive")
    var none_pattern = root + "/flat/*.csv"
    var none_c = _cstr(none_pattern)
    var ctx = lib.call["komira_ctx_new", Int]()
    _expect(ctx != 0, "komira_ctx_new returned NULL")

    # SAFETY: allocated here and freed below.
    var out_len = alloc[UInt64](1)
    var buf = alloc[UInt8](CAP)
    out_len[0] = UInt64(77)
    buf[0] = UInt8(5)
    var rc = _call(lib, 0, glob_c, HIVE_OFF, Int(buf), UInt64(CAP), Int(out_len))
    _expect(rc == -1, "NULL ctx returned " + String(rc) + ", want -1")
    _expect(out_len[0] == 77 and buf[0] == 5, "a NULL-context call wrote")
    rc = _call(lib, ctx, 0, HIVE_OFF, Int(buf), UInt64(CAP), Int(out_len))
    _expect(rc == -2, "NULL path returned " + String(rc) + ", want -2")
    _expect(len(_last_error(lib, ctx)) > 0, "NULL path stored no error")
    rc = _call(lib, ctx, glob_c, HIVE_OFF, Int(buf), UInt64(CAP), 0)
    _expect(rc == -2, "NULL out_len returned " + String(rc) + ", want -2")
    _expect(out_len[0] == 77, "a refused call set the length")
    buf.free()
    out_len.free()

    var no_match = "PARQUET_GLOB_NO_MATCH: no file matches '" + none_pattern + "'"
    _expect_refused(lib, ctx, none_c, HIVE_OFF, no_match)
    _expect_refused(lib, ctx, glob_c, Int32(7), "HIVE_PARTITIONING_UNKNOWN")

    var flat = _source(lib, ctx, glob_c, HIVE_OFF)
    var at_a = _index(flat, a)
    var at_b = _index(flat, b)
    _expect(at_a >= 0 and at_b >= 0, "the glob's bytes do not hold both files")
    _expect(at_a < at_b, "the glob's files are not in sorted order")
    _expect(_contains(flat, String("i64")), "the glob's bytes do not hold the column")

    var keyed = _source(lib, ctx, dir_c, HIVE_AUTO)
    var unkeyed = _source(lib, ctx, dir_c, HIVE_OFF)
    _expect(_contains(keyed, String("k=1/x.parquet")), "the directory's first file is missing")
    _expect(_contains(keyed, String("k=2/y.parquet")), "the directory's second file is missing")
    _expect(len(keyed) > len(unkeyed), "KOMIRA_HIVE_AUTO added no partition column")
    lib.call["komira_ctx_free", NoneType](ctx)
    print("ok")
