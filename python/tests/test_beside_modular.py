"""komira beside Modular's own Mojo runtime in one process (python/BUCK, the
`beside_*` wheel_install_test targets).

    <prefix>/bin/python3.<minor> -I test_beside_modular.py --site <dir>
        [--host-lib <lib>]... --order modular-first|komira-first
        --runtime same|other --modular-version <v>
        --toolchain-mojo-version <v> --parquet <file.parquet>

Run by wheel_install_run.py, which installed the komira wheel and Modular's
mojo-compiler into `--site` and starts this from an empty working directory.
Each `--host-lib` is opened by path first (the C++ runtime a user's system
provides, as in test_installed.py). Modular's runtime is loaded the way a Mojo
extension module's NEEDED entry loads it: <site>/modular/lib/
libKGENCompilerRTShared.so opened by path (RTLD_LOCAL), which brings its two
other libraries from beside it. komira's is loaded by its first call.

What each case holds (docs/design/python_package.md, decision 6, says why):

- the installed mojo-compiler is `--modular-version`, and with `--runtime
  same` that is the toolchain's Mojo;
- `same`, Modular's first: komira loads and answers, and every Mojo runtime
  library is mapped from <site>/modular/lib only: libkomira bound to Modular's
  runtime, and komira's copy was never opened;
- `same`, komira's first: komira loads and answers; Modular's
  libKGENCompilerRTShared.so then loads as a second copy, from
  <site>/modular/lib, while the two other libraries are komira's only; komira
  still answers;
- `other`, Modular's first: komira's first call raises the runtime check's
  LibraryLoadError (the case states the line);
- `other`, komira's first: komira loads and answers; Modular's library fails
  to load with the loader's `undefined symbol` (its code needs symbols
  komira's libraries lack), and komira still answers.

Any failure raises; its last traceback line is what a refusing case names.
"""

import ctypes
import os
import sys
from importlib import metadata

_RUNTIME = ("libKGENCompilerRTShared.so", "libAsyncRTRuntimeGlobals.so", "libMSupportGlobals.so")

_VALUED = ("--site", "--order", "--runtime", "--modular-version", "--toolchain-mojo-version", "--parquet")


def parse(argv):
    opts = {"host_lib": []}
    i = 0
    while i < len(argv):
        flag = argv[i]
        if i + 1 >= len(argv):
            raise SystemExit("test_beside_modular: flag {} needs a value".format(flag))
        value = argv[i + 1]
        if flag == "--host-lib":
            opts["host_lib"].append(value)
        elif flag in _VALUED:
            opts[flag[2:].replace("-", "_")] = value
        else:
            raise SystemExit("test_beside_modular: unknown flag {}".format(flag))
        i += 2
    for flag in _VALUED:
        if flag[2:].replace("-", "_") not in opts:
            raise SystemExit("test_beside_modular: {} is required".format(flag))
    if opts["order"] not in ("modular-first", "komira-first") or opts["runtime"] not in ("same", "other"):
        raise SystemExit("test_beside_modular: --order or --runtime has no such value")
    return opts


def mapped_dirs(name):
    """The directories every mapping of a file named `name` comes from."""
    out = set()
    with open("/proc/self/maps", encoding="utf-8") as f:
        for line in f:
            fields = line.split(None, 5)
            if len(fields) == 6 and fields[5].startswith("/"):
                path = fields[5].rstrip("\n")
                if os.path.basename(path) == name:
                    out.add(os.path.dirname(path))
    return out


def answers(komira, parquet):
    """komira's library is loaded and answers: its version, and a Parquet
    file registered on a session."""
    assert komira.abi_version() // 1000 == 1, komira.abi_version()
    with komira.Session() as s:
        assert s.register_parquet("t", parquet) is None


def main(argv):
    opts = parse(argv)
    for lib in opts["host_lib"]:
        ctypes.CDLL(lib, mode=ctypes.RTLD_GLOBAL)
    for name in ("LD_LIBRARY_PATH", "LD_PRELOAD"):
        assert os.environ.get(name, "") == "", "{} is set: {}".format(name, os.environ[name])

    site = os.path.realpath(opts["site"])
    modular = os.path.join(site, "modular", "lib")
    ours = os.path.join(site, "komira", "_lib", "lib")
    installed = metadata.version("mojo-compiler")
    assert installed == opts["modular_version"], "mojo-compiler {} is installed, the case names {}".format(installed, opts["modular_version"])
    if opts["runtime"] == "same":
        assert installed == opts["toolchain_mojo_version"], (
            "the same-version cases need Modular's runtime at the toolchain's Mojo: mojo-compiler {} is installed, "
            "the toolchain's is {}".format(installed, opts["toolchain_mojo_version"])
        )

    import komira

    def load_modular():
        return ctypes.CDLL(os.path.join(modular, "libKGENCompilerRTShared.so"))

    if opts["order"] == "modular-first":
        load_modular()
        for name in _RUNTIME:
            assert mapped_dirs(name) == {modular}, "{} is mapped from {}".format(name, mapped_dirs(name))
        # `other`: the runtime check refuses here, and that line is the case's.
        answers(komira, opts["parquet"])
        for name in _RUNTIME:
            assert mapped_dirs(name) == {modular}, "after komira loaded, {} is mapped from {}".format(name, mapped_dirs(name))
        print("beside: Modular's runtime first; libkomira bound to it, komira's copy not mapped")
        return

    answers(komira, opts["parquet"])
    for name in _RUNTIME:
        assert mapped_dirs(name) == {ours}, "{} is mapped from {}".format(name, mapped_dirs(name))
    if opts["runtime"] == "same":
        load_modular()
        kgen = mapped_dirs("libKGENCompilerRTShared.so")
        assert kgen == {ours, modular}, "libKGENCompilerRTShared.so is mapped from {}".format(kgen)
        for name in _RUNTIME[1:]:
            assert mapped_dirs(name) == {ours}, "{} is mapped from {}".format(name, mapped_dirs(name))
        answers(komira, opts["parquet"])
        print("beside: komira's runtime first; Modular's libKGENCompilerRTShared.so a second copy on komira's two others")
        return
    try:
        load_modular()
    except OSError as e:
        message = str(e)
    else:
        raise AssertionError("Modular's runtime of another version loaded beside komira's")
    assert "undefined symbol: " in message, "Modular's runtime failed with {}".format(message)
    for name in _RUNTIME:
        assert mapped_dirs(name) == {ours}, "after the failed load, {} is mapped from {}".format(name, mapped_dirs(name))
    answers(komira, opts["parquet"])
    print("beside: komira's runtime first; Modular's {} runtime refused by the loader: {}".format(installed, message))


if __name__ == "__main__":
    main(sys.argv[1:])
