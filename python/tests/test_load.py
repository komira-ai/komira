"""The loader: importing the package loads nothing; the two hooks run before
the library is opened; libkomira is opened from the directory it is given; a
library of another ABI major version or without a call its minor includes is
refused with LibraryLoadError; and the real library loads and answers each of
its nine calls.

    test_load.py --lib-dir <dir> --runtime-dir <dir>

`<dir>/libkomira/` is `//src/so:libkomira[runnable]` (the library with its
lib/ beside it), `<dir>/fake_<case>/libkomira.so` the stand-ins of
fake_libkomira.c, and `<dir>/two_columns.parquet` a Parquet file
(`--runtime-dir`, which the rule passes, is not read). A process holds one
library, so the refusals come first (each leaves nothing loaded) and the real
library last.
"""

import os
import pathlib
import sys
import tempfile

import komira
from komira import KomiraError, LibraryLoadError
from komira import _native, _runtime


def refused(call):
    try:
        call()
    except LibraryLoadError as e:
        assert e.status is None, e.status
        assert _native._loaded is None, "a refused load left a library loaded"
        return str(e)
    raise AssertionError("the load was not refused")


def engine_error(call, ctx, native, step=None):
    """The KomiraError of an engine refusal: status -3, and the context's last
    error, which is not empty, as the message. Its code and step are the
    context's (None from a library older than 1.7); `step` is the step the
    refusal reports from a 1.7 library, a BindError for "bind"."""
    try:
        call()
    except LibraryLoadError as e:
        raise AssertionError("a refused call is not a load error: {!r}".format(e))
    except KomiraError as e:
        assert e.status == -3, e.status
        assert str(e) != "", "the engine gave no message"
        assert str(e) == native.last_error(ctx), (str(e), native.last_error(ctx))
        assert e.code == native.last_error_code(ctx) and e.step == native.last_error_step(ctx), (e.code, e.step)
        if native.abi_version >= 1007:
            assert e.step == step, (e.step, step)
            assert type(e) is (komira.BindError if step == "bind" else KomiraError), repr(e)
        else:
            assert (e.code, e.step) == (None, None), (e.code, e.step)
        return
    raise AssertionError("the call raised nothing")


def main(args):
    # Absolute, since the paths the rule passes are relative to where the
    # action started.
    lib_dir = os.path.abspath(args[args.index("--lib-dir") + 1])

    def fake(case):
        return os.path.join(lib_dir, "fake_" + case)

    def so(directory):
        return os.path.join(os.path.abspath(directory), "libkomira.so")

    def load(directory):
        return _native.load(directory)

    # The public names, and importing the package loaded no library.
    want = [
        "BindError",
        "CredentialsError",
        "DataFrame",
        "GroupBy",
        "KomiraError",
        "LibraryLoadError",
        "MemoryLimitError",
        "ParseError",
        "Result",
        "Series",
        "Session",
        "StorageError",
        "UnsupportedCpuError",
        "UnsupportedOperation",
        "__version__",
        "abi_version",
        "concat",
        "read_csv",
        "read_json",
        "read_parquet",
    ]
    assert komira.__all__ == want, komira.__all__
    assert issubclass(LibraryLoadError, KomiraError) and issubclass(KomiraError, Exception)
    assert komira.__version__ == "0.0.0", komira.__version__
    assert _native._loaded is None

    # The hooks run before the library is opened, CPU check first, then the
    # check of a Mojo runtime already loaded, given the lib/ beside the
    # library; an error either raises stops the load: the real library is not
    # mapped. The checks' own cases are cpu_test's and runtime_test's; here
    # they are stand-ins.
    calls = []
    real_check = _runtime.check_loaded_runtime
    real_dir = os.path.join(lib_dir, "libkomira")

    def cpu_refuses():
        calls.append("cpu")
        raise LibraryLoadError("this CPU is refused")

    def runtime_refuses(directory):
        calls.append(("runtime", directory))
        raise LibraryLoadError("another runtime")

    def cpu_ok():
        calls.append("cpu")

    def runtime_ok(directory):
        calls.append(("runtime", directory))

    _native._check_cpu = cpu_refuses
    assert refused(lambda: load(real_dir)) == "this CPU is refused"
    assert calls == ["cpu"], calls
    _native._check_cpu = cpu_ok
    _runtime.check_loaded_runtime = runtime_refuses
    calls.clear()
    assert refused(lambda: load(real_dir)) == "another runtime"
    assert calls == ["cpu", ("runtime", os.path.join(real_dir, "lib"))], calls
    _runtime.check_loaded_runtime = runtime_ok

    # With no directory the package loads its own _lib/, which only a wheel
    # holds: here it is absent, and the refusal names the file. Session() and
    # abi_version() load it the same way.
    own = so(os.path.join(os.path.dirname(komira.__file__), "_lib"))
    want = "cannot load libkomira from {0}: {0}: cannot open shared object file: No such file or directory".format(own)
    calls.clear()
    assert refused(lambda: _native.load()) == want
    assert calls == ["cpu", ("runtime", os.path.join(os.path.dirname(own), "lib"))], calls
    assert refused(komira.Session) == want
    assert refused(komira.abi_version) == want

    # A directory with no library carries the loader's message.
    missing = os.path.join(lib_dir, "no_such_dir")
    got = refused(lambda: load(missing))
    want = "cannot load libkomira from {0}: {0}: cannot open shared object file: No such file or directory".format(so(missing))
    assert got == want, got

    # Another ABI major version, above and below, and a version that is not
    # one at all, are refused with the version the library reported.
    got = refused(lambda: load(fake("v2")))
    assert got == "libkomira at {} has ABI version 2.0; this package needs major 1".format(so(fake("v2"))), got
    got = refused(lambda: load(fake("v0")))
    assert got == "libkomira at {} has ABI version 0.999; this package needs major 1".format(so(fake("v0"))), got
    got = refused(lambda: load(fake("negative")))
    want = "libkomira at {} reports ABI version -1, which is not major * 1000 + minor".format(so(fake("negative")))
    assert got == want, got

    # A library without komira_abi_version, and a 1.1 library without a call
    # 1.1 added, are refused by the symbol's name.
    got = refused(lambda: load(fake("no_abi_version")))
    assert got == "libkomira at {} has no symbol komira_abi_version".format(so(fake("no_abi_version"))), got
    got = refused(lambda: load(fake("no_register")))
    want = "libkomira at {} has ABI version 1.1 and no symbol komira_register_parquet".format(so(fake("no_register")))
    assert got == want, got

    # None of the refusals left a library loaded: the real one loads now,
    # through the real runtime check (no Mojo runtime is loaded yet, so it
    # passes). Loading the same file again, by a str or a path, or with no
    # directory, is the same library.
    def runtime_real(directory):
        calls.append(("runtime", directory))
        real_check(directory)

    _runtime.check_loaded_runtime = runtime_real
    calls.clear()
    native = load(real_dir)
    assert calls == ["cpu", ("runtime", os.path.join(real_dir, "lib"))], calls
    assert native.path == so(real_dir), native.path
    # Major 1, and a minor of at least 1, the version that added
    # komira_register_parquet; a later minor is as good.
    assert native.abi_version // 1000 == _native.ABI_MAJOR, native.abi_version
    assert native.abi_version % 1000 >= 1, native.abi_version
    assert komira.abi_version() == native.abi_version
    assert load(real_dir) is native
    assert _native.load(pathlib.Path(real_dir)) is native
    assert _native.load() is native

    # Another file once one is loaded is refused, and the first stays loaded.
    try:
        load(fake("v2"))
    except LibraryLoadError as e:
        want = "libkomira is already loaded from {}; it cannot also be loaded from {}".format(so(real_dir), so(fake("v2")))
        assert str(e) == want, str(e)
    else:
        raise AssertionError("a second library was loaded")
    assert _native.load() is native

    # Two contexts are distinct and hold separate state.
    a = native.ctx_new()
    b = native.ctx_new()
    assert a and b and a != b, (a, b)
    assert native.last_error(a) == ""

    # The engine's refusal is a KomiraError with its status and the last
    # error, read with the two-call protocol, as the message; it is the
    # first context's only.
    gone = os.path.join(lib_dir, "no_such_file.parquet")
    engine_error(lambda: native.register_parquet(a, "gone", gone), a, native, "bind")
    assert native.last_error(b) == "", native.last_error(b)

    # A good call clears the error; a path may be a pathlib.Path.
    parquet = pathlib.Path(lib_dir) / "two_columns.parquet"
    assert native.register_parquet(a, "two", parquet) is None
    assert native.last_error(a) == "", native.last_error(a)

    # The four calls that answer bytes or text, each on a file it reads and on
    # one it cannot.
    schema = native.parquet_schema(a, parquet)
    assert type(schema) is bytes and schema, schema
    engine_error(lambda: native.parquet_schema(a, gone), a, native, "bind")

    scratch = tempfile.mkdtemp()
    csv = os.path.join(scratch, "rows.csv")
    with open(csv, "w", encoding="utf-8") as f:
        f.write("n,s\n1,x\n2,y\n")
    binding = native.csv_binding(a, csv, delimiter=",", has_header=True, all_varchar=False)
    assert type(binding) is bytes and binding, binding
    engine_error(lambda: native.csv_binding(a, gone, delimiter=",", has_header=True, all_varchar=False), a, native, "bind")

    ndjson = os.path.join(scratch, "rows.json")
    with open(ndjson, "w", encoding="utf-8") as f:
        f.write('{"n": 1}\n{"n": 2}\n')
    binding = native.json_binding(a, ndjson)
    assert type(binding) is bytes and binding, binding
    engine_error(lambda: native.json_binding(a, gone), a, native, "bind")

    # Bytes that are not a plan are refused by the decoder.
    engine_error(lambda: native.plan_render(a, b"\xff\xff\xff"), a, native)

    native.ctx_free(a)
    native.ctx_free(b)
    print("load: libkomira {} loaded from {}".format(native.abi_version, native.path))


if __name__ == "__main__":
    main(sys.argv[1:])
