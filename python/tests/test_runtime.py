"""The Mojo runtime preload, `_runtime._preload_runtime_libraries`, on
stand-in directories: a missing library, another `mojo-compiler` version, a
library that cannot be opened, and the three libraries present, opened in
dependency order with RTLD_GLOBAL.

    test_runtime.py --msupport <so> --asyncrt <so> --kgen <so> --consumer <so>

Each `<so>` is a build of fake_mojo_runtime.c: the three runtime libraries,
each needing the ones before it, and a consumer needing the third, as
libkomira does. The script copies them under the runtime's file names into
`<dir>/modular/lib/` of scratch directories. A process holds one runtime, so
every refusal comes first and the load last.
"""

import ctypes
import os
import shutil
import sys
import tempfile

import komira
from komira import KomiraError, LibraryLoadError, RuntimeNotFoundError
from komira import _runtime

NAMES = ("libMSupportGlobals.so", "libAsyncRTRuntimeGlobals.so", "libKGENCompilerRTShared.so")
INSTALL = "install it with: pip install mojo-compiler==1.0.0"


def raised(call):
    try:
        call()
    except Exception as e:  # each caller checks the exact type
        return e
    raise AssertionError("the call raised nothing")


def site(scratch, name, libs, version=None):
    """`<scratch>/<name>`, whose modular/lib holds `libs` ({file name: source
    path, or bytes to write}) and, with `version`, the metadata of a
    `mojo-compiler` of that version."""
    directory = os.path.join(scratch, name)
    libdir = os.path.join(directory, "modular", "lib")
    os.makedirs(libdir)
    for file_name, source in libs.items():
        target = os.path.join(libdir, file_name)
        if isinstance(source, bytes):
            with open(target, "wb") as f:
                f.write(source)
        else:
            shutil.copyfile(source, target)
    if version is not None:
        info = os.path.join(directory, "mojo_compiler-{}.dist-info".format(version))
        os.makedirs(info)
        with open(os.path.join(info, "METADATA"), "w", encoding="utf-8") as f:
            f.write("Metadata-Version: 2.1\nName: mojo-compiler\nVersion: {}\n".format(version))
    return directory


def lib(directory):
    return os.path.join(directory, "modular", "lib")


def preload(search_path, **kwargs):
    return _runtime._preload_runtime_libraries(search_path=search_path, **kwargs)


def main(args):
    def arg(name):
        return os.path.abspath(args[args.index(name) + 1])

    fakes = dict(zip(NAMES, (arg("--msupport"), arg("--asyncrt"), arg("--kgen"))))
    consumer = arg("--consumer")
    scratch = tempfile.mkdtemp()

    # The error is public and a LibraryLoadError; the pinned version.
    assert "RuntimeNotFoundError" in komira.__all__ and komira.RuntimeNotFoundError is RuntimeNotFoundError
    assert issubclass(RuntimeNotFoundError, LibraryLoadError) and issubclass(RuntimeNotFoundError, KomiraError)
    assert _runtime._MOJO_RUNTIME_VERSION == "1.0.0", _runtime._MOJO_RUNTIME_VERSION

    # The file names, in the order they are opened, on Linux and on macOS.
    assert _runtime._library_names("linux") == NAMES, _runtime._library_names("linux")
    want = ("libMSupportGlobals.dylib", "libAsyncRTRuntimeGlobals.dylib", "libKGENCompilerRTShared.dylib")
    assert _runtime._library_names("darwin") == want, _runtime._library_names("darwin")

    # The stand-ins hold the order: libKGENCompilerRTShared opened before the
    # two it needs is refused by the loader, and leaves nothing open.
    e = raised(lambda: ctypes.CDLL(fakes[NAMES[2]], mode=ctypes.RTLD_GLOBAL))
    assert type(e) is OSError and str(e).startswith(fakes[NAMES[2]] + ": undefined symbol: fake_"), str(e)

    none = site(scratch, "none", {})
    partial = site(scratch, "partial", {NAMES[0]: fakes[NAMES[0]], NAMES[2]: fakes[NAMES[2]]})
    present = site(scratch, "present", fakes, version="1.0.0")
    unversioned = site(scratch, "unversioned", fakes)
    newer = site(scratch, "newer", fakes, version="1.2.0")
    two = site(scratch, "two", fakes, version="1.0.0")
    os.makedirs(os.path.join(two, "mojo_compiler-0.9.0.dist-info"))
    with open(os.path.join(two, "mojo_compiler-0.9.0.dist-info", "METADATA"), "w", encoding="utf-8") as f:
        f.write("Metadata-Version: 2.1\nName: mojo-compiler\nVersion: 0.9.0\n")
    bad = site(scratch, "bad", dict(fakes, **{NAMES[0]: b"this is not a shared library\n" * 4}))

    def not_found(search_path, **kwargs):
        e = raised(lambda: preload(search_path, **kwargs))
        assert type(e) is RuntimeNotFoundError and e.status is None, repr(e)
        assert _runtime._loaded_from is None, "a refused preload left a runtime loaded"
        return str(e)

    # Missing. No directory at all; a directory with no modular/lib; one
    # holding two of the three, which names the third; relative entries (the
    # working directory) and repeats are not searched or listed twice.
    got = not_found([])
    want = "the Mojo runtime 1.0.0 is not installed: {} not found (searched no absolute directory); {}".format(
        ", ".join(NAMES), INSTALL
    )
    assert got == want, got
    got = not_found(["", "relative", none, none + os.sep, partial])
    want = "the Mojo runtime 1.0.0 is not installed: {} not found (searched {}, {}); {}".format(
        NAMES[1], lib(none), lib(partial), INSTALL
    )
    assert got == want, got

    # With no search path the hook searches sys.path.
    saved = sys.path[:]
    try:
        sys.path[:] = ["", none]
        got = not_found(None)
    finally:
        sys.path[:] = saved
    want = "the Mojo runtime 1.0.0 is not installed: {} not found (searched {}); {}".format(
        ", ".join(NAMES), lib(none), INSTALL
    )
    assert got == want, got

    # On macOS the names are .dylib: a directory of .so files holds none.
    got = not_found([present], platform="darwin")
    want = "the Mojo runtime 1.0.0 is not installed: {} not found (searched {}); {}".format(
        "libMSupportGlobals.dylib, libAsyncRTRuntimeGlobals.dylib, libKGENCompilerRTShared.dylib", lib(present), INSTALL
    )
    assert got == want, got

    # Wrong version. The first complete directory is the runtime: one whose
    # mojo-compiler is another version is refused, and a good directory after
    # it on the path is not tried. Two versions installed in one directory
    # are named both.
    got = not_found([partial, newer, present])
    want = "the Mojo runtime in {} is mojo-compiler 1.2.0; komira needs 1.0.0: {}".format(lib(newer), INSTALL)
    assert got == want, got
    got = not_found([two])
    want = "the Mojo runtime in {} is mojo-compiler 0.9.0 and 1.0.0; komira needs 1.0.0: {}".format(lib(two), INSTALL)
    assert got == want, got

    # The pinned version, and no mojo-compiler metadata at all, pass the check.
    assert _runtime._check_version(present, lib(present)) is None
    assert _runtime._check_version(unversioned, lib(unversioned)) is None

    # A library that is found but is not one is a LibraryLoadError with the
    # loader's reason, and nothing is loaded.
    path = os.path.join(lib(bad), NAMES[0])
    e = raised(lambda: preload([bad]))
    assert type(e) is LibraryLoadError and e.status is None, repr(e)
    assert str(e) == "cannot load the Mojo runtime library {0}: {0}: invalid ELF header".format(path), str(e)
    assert _runtime._loaded_from is None

    # Present: the three open in dependency order (any other order is refused
    # by the stand-ins, above) and with RTLD_GLOBAL, so the consumer, opened
    # with ctypes' default RTLD_LOCAL, finds libKGENCompilerRTShared's symbol.
    assert preload([none, partial, present]) is None
    assert _runtime._loaded_from == lib(present), _runtime._loaded_from
    ctypes.CDLL(consumer)

    # The same directory again opens nothing new; another one is refused.
    assert preload([present]) is None
    e = raised(lambda: preload([unversioned]))
    assert type(e) is LibraryLoadError, repr(e)
    want = "the Mojo runtime is already loaded from {}; it cannot also be loaded from {}".format(
        lib(present), lib(unversioned)
    )
    assert str(e) == want, str(e)
    assert _runtime._loaded_from == lib(present)
    print("runtime: stand-in Mojo runtime loaded from {}".format(lib(present)))


if __name__ == "__main__":
    main(sys.argv[1:])
