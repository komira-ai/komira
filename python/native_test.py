"""Tests of the Python binding of libkomira (komira/_native.py, _wire.py, _session.py),
run against the real library by python_binding_test.

    native_test.py --lib-dir <dir> --parquet <two_columns.parquet>

Each test_* function is run; every failure is reported by name at the end.
"""

import ctypes
import os
import sys
import traceback
import types

import pyarrow as pa
import pyarrow.parquet as pq

from komira import KomiraError, Session, _native, _wire

# A serialized plan: one scan of "/data/orders.orc" (the same bytes as
# src/komira_so/tests/gate/gate_plan_render.mojo). It holds NUL bytes.
SCAN_PLAN_HEX = "080412a903124c0a200a0161100518052000280030003a00400450005a04756e6974620563656e74730a130a0162100518052001280030003a00400450000a130a0173100d18002001280030003a004004500022d8020af90112f60108c0c2d2f703120a6b6f6d6972612e6f72631a066f7264657273221b0a0a6861735f666f6f74657210051a00200129000000000000000022250a047061746810011a102f646174612f6f72646572732e6f72632000290000000000000000221d0a0c7374726970655f636f756e7410021a0020072900000000000000002a4c0a200a0161100518052000280030003a00400450005a04756e6974620563656e74730a130a0162100518052001280030003a00400450000a130a0173100d18002001280030003a004004500030effdb6f50d38cef5b7f70f420a0803103f180120012801500258d285d8cc04600180010068007008780010011a4c0a200a0161100518052000280030003a00400450005a04756e6974620563656e74730a130a0162100518052001280030003a00400450000a130a0173100d18002001280030003a0040045000200030004000480050015800"

LIB = None
PARQUET = None


def lib_path():
    return os.path.join(LIB, "libkomira.so")


def raises(want_status, fn, *args):
    try:
        fn(*args)
    except KomiraError as e:
        assert e.status == want_status, "status %r, want %r (%s)" % (e.status, want_status, e)
        return e
    raise AssertionError("no KomiraError, want status %r" % (want_status,))


def fake_lib(version):
    return types.SimpleNamespace(komira_abi_version=lambda: version)


def test_real_library_version():
    native = _native.load(lib_path())
    assert native.abi_version == 1001, native.abi_version


def test_major_2_is_refused():
    # A real library whose version function is replaced by one reporting 2.0.
    lib = ctypes.CDLL(lib_path())
    lib.komira_abi_version = lambda: 2000
    e = raises(None, _native.Native, lib)
    assert "2.0" in str(e) and "major 1" in str(e), str(e)


def test_version_matrix():
    for version in (0, 999, 2000, 2001, 3001):
        e = raises(None, _native.Native, fake_lib(version))
        assert "needs major 1" in str(e), (version, str(e))
    # Older minor: 1.0 lacks exports this binding binds.
    e = raises(None, _native.Native, fake_lib(1000))
    assert "1.1 or later" in str(e), str(e)
    # The check runs before any symbol is looked up (the fake has no other export).
    assert "ABI" in str(e)
    # A newer minor of the same major is accepted if the exports are there.
    lib = ctypes.CDLL(lib_path())
    lib.komira_abi_version = lambda: 1002
    assert _native.Native(lib).abi_version == 1002


def test_missing_export_is_named():
    class Lib:
        def __init__(self, real):
            self._real = real
            self.komira_abi_version = lambda: 1001

        def __getattr__(self, name):
            if name == "komira_plan_render":
                raise AttributeError(name)
            return getattr(self._real, name)

    e = raises(None, _native.Native, Lib(ctypes.CDLL(lib_path())))
    assert "komira_plan_render" in str(e), str(e)


def test_load_failure():
    e = raises(None, _native.load, os.path.join(LIB, "no_such_library.so"))
    assert "no_such_library.so" in str(e), str(e)


def test_argtypes_of_all_nine():
    native = _native.load(lib_path())
    lib = native.lib
    assert lib.komira_ctx_new.argtypes == [] and lib.komira_ctx_new.restype is ctypes.c_void_p
    assert lib.komira_ctx_free.restype is None and len(lib.komira_ctx_free.argtypes) == 1
    counts = {
        "komira_last_error": 4,
        "komira_register_parquet": 3,
        "komira_parquet_schema": 5,
        "komira_csv_binding": 8,
        "komira_json_binding": 5,
        "komira_plan_render": 6,
    }
    for name, n in counts.items():
        fn = getattr(lib, name)
        assert len(fn.argtypes) == n and fn.restype is ctypes.c_int32, (name, fn.argtypes, fn.restype)
    assert lib.komira_csv_binding.argtypes[2] is ctypes.c_uint8
    assert lib.komira_plan_render.argtypes[2] is ctypes.c_uint64


def test_engine_error_carries_status_and_last_error():
    with Session(lib_path()) as s:
        e = raises(_native.KOMIRA_ERR_ENGINE, s.register_parquet, "t", "/no/such/file.parquet")
        assert e.last_error and e.last_error in str(e), (e.last_error, str(e))
        assert "KOMIRA_ERR_ENGINE" in str(e), str(e)
        # A good call afterwards clears the error: the library cleared it at the start.
        s.register_parquet("t", PARQUET)
        assert s._native.last_error(s._ctx) == ""


def test_null_ctx_and_null_arg_map_to_errors():
    native = _native.load(lib_path())
    # NULL context: -1, and there is no context to read a last error from.
    rc = native.lib.komira_register_parquet(None, b"a", b"b")
    e = raises(_native.KOMIRA_ERR_NULL_CTX, native.check, None, rc, "komira_register_parquet")
    assert e.last_error == ""
    # NULL name on a live context: -2, with the library's refusal as last error.
    ctx = native.ctx_new()
    try:
        rc = native.lib.komira_register_parquet(ctx, None, None)
        e = raises(_native.KOMIRA_ERR_NULL_ARG, native.check, ctx, rc, "komira_register_parquet")
        assert "NULL" in e.last_error and e.last_error in str(e), e.last_error
    finally:
        native.ctx_free(ctx)


def test_too_large_plan_is_status_5_and_unread():
    native = _native.load(lib_path())
    ctx = native.ctx_new()
    try:
        n = ctypes.c_uint64(7)
        rc = native.lib.komira_plan_render(ctx, b"abc", 64 * 1024 * 1024 + 1, None, 0, ctypes.byref(n))
        e = raises(_native.KOMIRA_ERR_TOO_LARGE, native.check, ctx, rc, "komira_plan_render")
        assert e.last_error, "no last error"
    finally:
        native.ctx_free(ctx)


def test_binding_guards():
    with Session(lib_path()) as s:
        raises(None, s.register_parquet, "t\0x", PARQUET)
        raises(None, s.register_parquet, "t", 42)
        raises(None, s.parquet_schema, "bad\ud800path")
    s2 = Session(lib_path())
    s2.close()
    s2.close()  # closing twice is fine
    e = raises(None, s2.plan_render, b"")
    assert "closed" in str(e)


def test_parquet_schema_equals_pyarrow():
    want = pq.read_schema(PARQUET).remove_metadata()
    assert [f.name for f in want] == ["i64", "s"] or [f.name for f in want] == ["s", "i64"], want
    with Session(lib_path()) as s:
        got = s.parquet_schema(PARQUET)
        assert isinstance(got, pa.Schema)
        assert got.equals(want, check_metadata=False), "got\n%s\nwant\n%s" % (got, want)
        assert got.field("i64").type == pa.int64() and got.field("s").type == pa.string()
        # Registering the same file works and does not change the schema.
        s.register_parquet("t", PARQUET)
        assert s.parquet_schema(PARQUET).equals(want, check_metadata=False)
        raises(_native.KOMIRA_ERR_ENGINE, s.parquet_schema, "/no/such/file.parquet")


def test_wire_decoder_types():
    def field(name, type_id, nullable=True, extra=b""):
        body = b"\x0a" + bytes([len(name)]) + name.encode() + b"\x10" + bytes([type_id]) + b"\x20" + bytes([int(nullable)]) + extra
        return b"\x0a" + bytes([len(body)]) + body

    data = field("a", 4) + field("b", 1, False) + field("c", 24, True, b"\x3a\x03UTC") + field("d", 18, True, b"\x28\x0a\x30\x02")
    got = _wire.schema_from_wire(data)
    want = pa.schema(
        [pa.field("a", pa.int32()), pa.field("b", pa.bool_(), nullable=False), pa.field("c", pa.timestamp("us", tz="UTC")), pa.field("d", pa.decimal128(10, 2))]
    )
    assert got.equals(want, check_metadata=True), "got\n%s\nwant\n%s" % (got, want)
    raises(None, _wire.schema_from_wire, field("x", 19))  # DICTIONARY: not decoded
    raises(None, _wire.schema_from_wire, field("x", 20))  # LIST: not decoded
    raises(None, _wire.schema_from_wire, field("x", 4)[:-1])  # truncated


def test_two_call_growth():
    # The text grows between the probe and the read: the helper reads again
    # with the new length and returns the whole answer, never a truncated one.
    seen = {"n": 0}

    def growing(buf, cap, n):
        seen["n"] += 1
        if seen["n"] == 1:  # probe
            n._obj.value = 10
            return _native.KOMIRA_ERR_BUFFER_TOO_SMALL
        n._obj.value = 12  # the text grew
        if cap < 12:
            return _native.KOMIRA_ERR_BUFFER_TOO_SMALL
        ctypes.memmove(buf, b"twelve bytes", 12)
        return _native.KOMIRA_OK

    assert _native.read_two_call(growing) == (_native.KOMIRA_OK, b"twelve bytes")
    assert seen["n"] == 3, seen

    # A text that keeps growing is given up on, with the too-small status.
    def always_growing(buf, cap, n):
        n._obj.value = cap + 1
        return _native.KOMIRA_ERR_BUFFER_TOO_SMALL

    assert _native.read_two_call(always_growing)[0] == _native.KOMIRA_ERR_BUFFER_TOO_SMALL
    # An empty answer needs no second call; a hard failure ends after the probe.
    assert _native.read_two_call(lambda b, c, n: _native.KOMIRA_OK) == (_native.KOMIRA_OK, b"")
    n_calls = []
    assert _native.read_two_call(lambda b, c, n: n_calls.append(1) or _native.KOMIRA_ERR_ENGINE)[0] == _native.KOMIRA_ERR_ENGINE
    assert len(n_calls) == 1


def test_two_call_against_the_library():
    # The real protocol: capacity 0 and one byte short are -4 and write nothing;
    # read_two_call returns exactly the text.
    native = _native.load(lib_path())
    ctx = native.ctx_new()
    try:
        raises(_native.KOMIRA_ERR_ENGINE, native.register_parquet, ctx, "t", "/no/such/file.parquet")
        n = ctypes.c_uint64(0)
        assert native.lib.komira_last_error(ctx, None, 0, ctypes.byref(n)) == _native.KOMIRA_ERR_BUFFER_TOO_SMALL
        total = n.value
        assert total > 1
        buf = ctypes.create_string_buffer(b"\xab" * total, total)
        assert native.lib.komira_last_error(ctx, buf, total - 1, ctypes.byref(n)) == _native.KOMIRA_ERR_BUFFER_TOO_SMALL
        assert buf.raw == b"\xab" * total, "a too-small buffer was written"
        text = native.last_error(ctx)
        assert len(text.encode("utf-8")) == total, (len(text), total)
    finally:
        native.ctx_free(ctx)


def test_csv_and_json_bindings():
    import tempfile

    native = _native.load(lib_path())
    d = tempfile.mkdtemp()
    csv = os.path.join(d, "t.csv")
    with open(csv, "w") as f:
        f.write("a;b\n1;x\n2;y\n")
    jl = os.path.join(d, "t.jsonl")
    with open(jl, "w") as f:
        f.write('{"a": 1, "b": "x"}\n{"a": 2, "b": "y"}\n')
    ctx = native.ctx_new()
    try:
        base = native.csv_binding(ctx, csv, ord(";"), True, False)
        assert base and csv.encode() in base, "the binding does not name the file"
        # Each input changes the binding (the delimiter and the header enter its
        # identity; all_varchar makes every column a string).
        assert native.csv_binding(ctx, csv, ord(","), True, False) != base, "delimiter ignored"
        assert native.csv_binding(ctx, csv, ord(";"), False, False) != base, "has_header ignored"
        assert native.csv_binding(ctx, csv, ord(";"), True, True) != base, "all_varchar ignored"
        assert native.csv_binding(ctx, csv, ord(";"), True, False) == base, "not deterministic"
        j = native.json_binding(ctx, jl)
        assert j and jl.encode() in j
        raises(_native.KOMIRA_ERR_ENGINE, native.csv_binding, ctx, os.path.join(d, "nope.csv"))
        raises(_native.KOMIRA_ERR_ENGINE, native.json_binding, ctx, os.path.join(d, "nope.jsonl"))
        raises(None, native.csv_binding, ctx, csv, 300)
    finally:
        native.ctx_free(ctx)


def test_plan_render():
    plan = bytes.fromhex(SCAN_PLAN_HEX)
    assert b"\0" in plan
    with Session(lib_path()) as s:
        text = s.plan_render(plan)
        assert isinstance(text, str)
        assert text.startswith('Scan(path="orders"'), text
        assert "path=/data/orders.orc" in text, text
        e = raises(_native.KOMIRA_ERR_ENGINE, s.plan_render, b"\xff\xff\xff")
        assert e.last_error, "no last error for garbage"
        # A good call after a refusal works and leaves no error.
        assert s.plan_render(plan) == text
        assert s._native.last_error(s._ctx) == ""


def main(argv):
    global LIB, PARQUET
    LIB = argv[argv.index("--lib-dir") + 1]
    PARQUET = argv[argv.index("--parquet") + 1]
    failed = []
    tests = sorted(n for n in globals() if n.startswith("test_"))
    for name in tests:
        try:
            globals()[name]()
            print("ok   " + name)
        except BaseException:  # noqa: BLE001 - every failure is reported by name
            traceback.print_exc()
            failed.append(name)
            print("FAIL " + name)
    if failed:
        raise AssertionError("%d of %d failed: %s" % (len(failed), len(tests), ", ".join(failed)))
    print("%d tests passed" % len(tests))


if __name__ == "__main__":
    main(sys.argv[1:])
