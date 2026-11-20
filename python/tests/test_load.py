"""The loader: libkomira is opened from the directory it is given, a library of
another ABI major version or without a function the package binds is refused
with LibraryLoadError, and the real library loads and answers.

    test_load.py --lib-dir <dir>

`<dir>/libkomira/` is `//src/so:libkomira[runnable]` (the library with its
lib/ beside it), `<dir>/fake_<case>/libkomira.so` the stand-ins of
fake_libkomira.c, and `<dir>/two_columns.parquet` a Parquet file. A process
holds one library, so the refusals come first (each leaves nothing loaded)
and the real library last.
"""

import os
import pathlib
import sys

import komira
from komira import KomiraError, LibraryLoadError
from komira import _native


def refused(lib_dir):
    try:
        _native.load(lib_dir)
    except LibraryLoadError as e:
        assert e.status is None, e.status
        return str(e)
    raise AssertionError("load({}) was not refused".format(lib_dir))


def main(args):
    lib_dir = args[args.index("--lib-dir") + 1]

    def fake(case):
        return os.path.join(lib_dir, "fake_" + case)

    def so(directory):
        return os.path.join(os.path.abspath(directory), "libkomira.so")

    assert komira.__all__ == ["KomiraError", "LibraryLoadError"], komira.__all__
    assert issubclass(LibraryLoadError, KomiraError) and issubclass(KomiraError, Exception)

    # With no directory the package loads its own _lib/, which only a wheel
    # holds: here it is absent, and the refusal names the file.
    own = so(os.path.join(os.path.dirname(komira.__file__), "_lib"))
    got = refused(None)
    want = "cannot load libkomira from {0}: {0}: cannot open shared object file: No such file or directory".format(own)
    assert got == want, got

    # A directory with no library carries the loader's message.
    missing = os.path.join(lib_dir, "no_such_dir")
    got = refused(missing)
    want = "cannot load libkomira from {0}: {0}: cannot open shared object file: No such file or directory".format(so(missing))
    assert got == want, got

    # Another ABI major version, above and below, and a version that is not
    # one at all, are refused with the version the library reported.
    got = refused(fake("v2"))
    assert got == "libkomira at {} has ABI version 2.0; this package needs major 1".format(so(fake("v2"))), got
    got = refused(fake("v0"))
    assert got == "libkomira at {} has ABI version 0.999; this package needs major 1".format(so(fake("v0"))), got
    got = refused(fake("negative"))
    want = "libkomira at {} reports ABI version -1, which is not major * 1000 + minor".format(so(fake("negative")))
    assert got == want, got

    # A library of major 1 without a function the package binds names it.
    got = refused(fake("no_register"))
    assert got == "libkomira at {} has no symbol komira_register_parquet".format(so(fake("no_register"))), got

    # None of the refusals left a library loaded: the real one loads now, and
    # loading the same file again, by a str or a path, is the same library.
    real_dir = os.path.join(lib_dir, "libkomira")
    native = _native.load(real_dir)
    assert native.path == so(real_dir), native.path
    # Major 1, and a minor of at least 1, the version that added
    # komira_register_parquet; a later minor is as good.
    assert native.abi_version // 1000 == _native.ABI_MAJOR, native.abi_version
    assert native.abi_version % 1000 >= 1, native.abi_version
    assert _native.load(real_dir) is native
    assert _native.load(pathlib.Path(real_dir)) is native

    # Another file once one is loaded is refused, and the first stays loaded.
    got = refused(fake("v2"))
    want = "libkomira is already loaded from {}; it cannot also be loaded from {}".format(so(real_dir), so(fake("v2")))
    assert got == want, got
    assert _native.load(real_dir) is native

    # Two contexts are distinct and hold separate state.
    a = native.ctx_new()
    b = native.ctx_new()
    assert a and b and a != b, (a, b)
    assert native.last_error(a) == ""

    # The engine's refusal is a KomiraError with its status and the last
    # error, read with the two-call protocol, as the message.
    gone = os.path.join(lib_dir, "no_such_file.parquet")
    try:
        native.register_parquet(a, "gone", gone)
    except LibraryLoadError as e:
        raise AssertionError("a refused call is not a load error: {!r}".format(e))
    except KomiraError as e:
        assert e.status == -3, e.status
        assert str(e) != "", "the engine gave no message"
        assert str(e) == native.last_error(a), (str(e), native.last_error(a))
    else:
        raise AssertionError("registering a missing file raised nothing")
    assert native.last_error(b) == "", native.last_error(b)

    # A good call clears the error; a path may be a pathlib.Path.
    parquet = pathlib.Path(lib_dir) / "two_columns.parquet"
    assert native.register_parquet(a, "two", parquet) is None
    assert native.last_error(a) == "", native.last_error(a)

    native.ctx_free(a)
    native.ctx_free(b)
    print("load: libkomira {} loaded from {}".format(native.abi_version, native.path))


if __name__ == "__main__":
    main(sys.argv[1:])
