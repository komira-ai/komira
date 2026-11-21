"""The installed komira wheel, of either flavour, run from an empty prefix:
what `pip install komira` into a new environment gives a user (python/BUCK,
wheel_install_test, on Linux x86_64 and, for the macOS wheel, which is the
bundled flavour only, on macOS arm64).

    <prefix>/bin/python3.<minor> -I test_installed.py --site <dir>
        [--host-lib <lib>]... --version <v> --flavour bundled|external
        --license-expression <expr> --toolchain-mojo-version <v>
        --abi-table <komira.tsv> --license <LICENSE> --notice <NOTICE>
        --modular-license <LICENSE> --modular-notices <Third-Party-Notices>
        --parquet <file.parquet> --plan-hex <file.hex>

Run by wheel_install_run.py, which installed the wheels into `--site` and
starts this from an empty working directory outside the checkout. Each
`--host-lib` is opened by path first: the C++ runtime (libstdc++, libgcc_s)
that the Mojo runtime libraries need and a user's system provides; the build
workers provide none, so the hermetic interpreter's copies stand in for it.
Then, in order:

- no library path is set: LD_LIBRARY_PATH and LD_PRELOAD are empty (on
  macOS, DYLD_LIBRARY_PATH, DYLD_FALLBACK_LIBRARY_PATH and
  DYLD_INSERT_LIBRARIES);
- bundled: the environment holds the distribution komira and no other, and no
  `modular/` directory: nothing of Modular's. external: it holds komira and
  at most Modular's mojo-compiler and mojo-compiler-mojo-libs;
- `import komira` is the package installed in `--site`, not a source tree;
- the installed distribution is `--version`, and `komira.__version__` is it;
- its metadata is its flavour's and none of the other's: no `Requires-Dist`
  (bundled), or exactly `mojo-compiler==<--toolchain-mojo-version>`
  (external); the `License-Expression` given; `.dist-info/licenses/` holding
  LICENSE and NOTICE, byte for byte the repository's, and (bundled only)
  `MODULAR_LICENSE` and `MODULAR_THIRD_PARTY_NOTICES`, byte for byte the
  pinned compiler package's, and no other; a description whose first line
  names the flavour; and the record of the runtime at
  `komira/_lib/mojo_runtime.tsv`, naming the requirement and the three
  runtime libraries (external), or no record (bundled);
- external: no file under `<site>/komira` is named as a Mojo runtime library,
  and none but an empty one is byte for byte a file of an installed
  distribution of Modular's (by the sha256 its RECORD lists);
- `komira.abi_version()` is the `version` line of the ABI golden;
- `Session().register_parquet` registers the Parquet fixture, and a missing
  file raises `KomiraError` with the engine's status;
- `komira._native.plan_render` of the serialized plan returns its text;
- the process maps libkomira (`libkomira.so`, `libkomira.dylib` on macOS) from
  `<site>/komira/_lib`, its native owner libraries from `<site>/komira/_lib/lib`
  and the three Mojo runtime libraries from `<site>/komira/_lib/lib` (bundled)
  or `<site>/modular/lib` (external), and none of them from elsewhere. On
  macOS (the bundled flavour only) libkomira has no native owner libraries,
  and `lib/` holds exactly the three runtime libraries (`.dylib`). The mapped
  files are /proc/self/maps on Linux and the images dyld has loaded on macOS;
- external: the installed mojo-compiler is the toolchain's Mojo, and each
  runtime library it installed has the build id the record names.

Any failure raises; its last traceback line is what a refusing case of
wheel_install_test names.
"""

import base64
import ctypes
import hashlib
import os
import re
import sys
from importlib import metadata

_DARWIN = sys.platform == "darwin"

# The Mojo runtime libraries: in the bundled wheel, or loaded from Modular's
# package by the external one (Linux only).
_RUNTIME = (
    ("libKGENCompilerRTShared.dylib", "libAsyncRTRuntimeGlobals.dylib", "libMSupportGlobals.dylib")
    if _DARWIN
    else ("libKGENCompilerRTShared.so", "libAsyncRTRuntimeGlobals.so", "libMSupportGlobals.so")
)

_LIBKOMIRA = "libkomira.dylib" if _DARWIN else "libkomira.so"

# The environment variables that would change which library a process loads.
_LIBRARY_PATH_VARIABLES = (
    ("DYLD_LIBRARY_PATH", "DYLD_FALLBACK_LIBRARY_PATH", "DYLD_INSERT_LIBRARIES")
    if _DARWIN
    else ("LD_LIBRARY_PATH", "LD_PRELOAD")
)

_FLAVOURS = ("bundled", "external")

# The distributions Modular's package installs beside the external wheel.
_MODULAR = ("mojo-compiler", "mojo-compiler-mojo-libs")

# The licence files each flavour carries, in `.dist-info/licenses/`.
_LICENCES = {
    "bundled": ("LICENSE", "NOTICE", "MODULAR_LICENSE", "MODULAR_THIRD_PARTY_NOTICES"),
    "external": ("LICENSE", "NOTICE"),
}

# Where the external wheel carries the record of the runtime, under the site.
_RECORD = os.path.join("komira", "_lib", "mojo_runtime.tsv")

_VALUED = (
    "--site",
    "--version",
    "--flavour",
    "--license-expression",
    "--toolchain-mojo-version",
    "--abi-table",
    "--license",
    "--notice",
    "--modular-license",
    "--modular-notices",
    "--parquet",
    "--plan-hex",
)


def parse(argv):
    opts = {"host_lib": []}
    i = 0
    while i < len(argv):
        flag = argv[i]
        if i + 1 >= len(argv):
            raise SystemExit("test_installed: flag {} needs a value".format(flag))
        value = argv[i + 1]
        if flag == "--host-lib":
            opts["host_lib"].append(value)
        elif flag in _VALUED:
            opts[flag[2:].replace("-", "_")] = value
        else:
            raise SystemExit("test_installed: unknown flag {}".format(flag))
        i += 2
    for flag in _VALUED:
        if flag[2:].replace("-", "_") not in opts:
            raise SystemExit("test_installed: {} is required".format(flag))
    if opts["flavour"] not in _FLAVOURS:
        raise SystemExit("test_installed: --flavour is {}, not one of {}".format(opts["flavour"], ", ".join(_FLAVOURS)))
    return opts


def abi_version_of(table):
    """major * 1000 + minor of the `version` line of the ABI golden."""
    with open(table, encoding="utf-8") as f:
        for line in f:
            key, _, value = line.rstrip("\n").partition("\t")
            if key == "version":
                major, minor = value.split(".")
                return int(major) * 1000 + int(minor)
    raise AssertionError("{} has no version line".format(table))


def _dyld_images():
    """The real path of every image dyld has loaded into the process."""
    libsystem = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    libsystem._dyld_image_count.restype = ctypes.c_uint32
    libsystem._dyld_image_count.argtypes = []
    libsystem._dyld_get_image_name.restype = ctypes.c_char_p
    libsystem._dyld_get_image_name.argtypes = [ctypes.c_uint32]
    out = set()
    for i in range(libsystem._dyld_image_count()):
        name = libsystem._dyld_get_image_name(i)
        if name:
            out.add(os.path.realpath(os.fsdecode(name)))
    return out


def mapped_files():
    """The path of every file the process maps: the images dyld has loaded on
    macOS, /proc/self/maps elsewhere."""
    if _DARWIN:
        return _dyld_images()
    out = set()
    with open("/proc/self/maps", encoding="utf-8") as f:
        for line in f:
            fields = line.split(None, 5)
            if len(fields) == 6 and fields[5].startswith("/"):
                out.add(fields[5].rstrip("\n"))
    return out


def under(path, directory):
    return os.path.dirname(path) == os.path.realpath(directory)


def normal(name):
    return re.sub(r"[-_.]+", "-", name).lower()


def sha256_of(path):
    """The sha256 of the file at `path` as RECORD writes it: urlsafe base64,
    without padding."""
    with open(path, "rb") as f:
        digest = hashlib.sha256(f.read()).digest()
    return base64.urlsafe_b64encode(digest).rstrip(b"=").decode("ascii")


def check_metadata(dist, site, opts):
    """The installed distribution's metadata is its flavour's, and none of the
    other flavour's: the requirement first, then the licence expression and
    files, the description's first line and the runtime record."""
    flavour = opts["flavour"]
    want = ["mojo-compiler==" + opts["toolchain_mojo_version"]] if flavour == "external" else []
    got = list(dist.requires or [])
    assert got == want, "the wheel's Requires-Dist is {}, the {} flavour's is {}".format(got, flavour, want)

    expression = dist.metadata["License-Expression"]
    assert expression == opts["license_expression"], "the wheel's License-Expression is {}".format(expression)
    sources = {
        "LICENSE": opts["license"],
        "NOTICE": opts["notice"],
        "MODULAR_LICENSE": opts["modular_license"],
        "MODULAR_THIRD_PARTY_NOTICES": opts["modular_notices"],
    }
    files = sorted(dist.metadata.get_all("License-File") or [])
    assert files == sorted(_LICENCES[flavour]), "the wheel's License-File lines are {}, the {} flavour's are {}".format(
        files, flavour, sorted(_LICENCES[flavour])
    )
    for name in _LICENCES[flavour]:
        got = dist.read_text("licenses/" + name)
        assert got is not None, "the wheel has no .dist-info/licenses/{}".format(name)
        with open(sources[name], encoding="utf-8") as f:
            assert got == f.read(), ".dist-info/licenses/{} differs from {}".format(name, sources[name])

    text = dist.read_text("METADATA")
    body = text.split("\n\n", 1)[1] if "\n\n" in text else ""
    first = body.split("\n", 1)[0]
    preface = "> This wheel is the **{}** flavour of komira: ".format(flavour)
    assert first.startswith(preface), "the wheel's description starts {!r}, not with the {} flavour's preface".format(first, flavour)

    record = os.path.join(site, _RECORD)
    if flavour == "bundled":
        assert not os.path.exists(record), "the bundled wheel carries the external flavour's runtime record"
        return
    assert os.path.isfile(record), "the external wheel carries no runtime record at {}".format(record)
    with open(record, encoding="utf-8") as f:
        rows = [line.split("\t") for line in f.read().splitlines()]
    keys = [r[0] for r in rows]
    assert keys == ["requirement"] + list(_RUNTIME), "the runtime record's keys are {}".format(keys)
    assert rows[0] == ["requirement"] + want, "the runtime record's requirement is {}".format(rows[0][1:])


def check_no_modular_file(site):
    """No file under `<site>/komira` is named as a Mojo runtime library or is
    byte for byte a file of an installed distribution of Modular's. An empty
    file is no one's (py.typed is empty, and so may a file of Modular's be)."""
    theirs = {}
    for d in metadata.distributions(path=[site]):
        if normal(d.metadata["Name"]) in _MODULAR:
            for f in d.files or []:
                if f.hash is not None and f.hash.mode == "sha256":
                    theirs[f.hash.value] = "{} {}".format(normal(d.metadata["Name"]), f)
    package = os.path.join(site, "komira")
    for root, _, names in os.walk(package):
        for name in names:
            path = os.path.join(root, name)
            rel = os.path.relpath(path, site)
            assert name not in _RUNTIME, "the external wheel carries {}, a Mojo runtime library".format(rel)
            if os.path.getsize(path) == 0:
                continue
            same = theirs.get(sha256_of(path))
            assert same is None, "the external wheel's {} is byte for byte {}".format(rel, same)


def main(argv):
    opts = parse(argv)
    for lib in opts["host_lib"]:
        ctypes.CDLL(lib, mode=ctypes.RTLD_GLOBAL)

    for name in _LIBRARY_PATH_VARIABLES:
        assert os.environ.get(name, "") == "", "{} is set: {}".format(name, os.environ[name])
    assert os.listdir(os.getcwd()) == [], "the working directory is not empty: {}".format(os.listdir(os.getcwd()))

    site = os.path.realpath(opts["site"])

    flavour = opts["flavour"]
    names = sorted({normal(d.metadata["Name"]) for d in metadata.distributions(path=[site])})
    others = [n for n in names if n != "komira"]
    assert "komira" in names, "komira is not installed: {}".format(names)
    if flavour == "bundled":
        # `pip install komira` installed komira and nothing else.
        assert not others, "the environment holds komira and also {}".format(", ".join(others))
        assert not os.path.exists(os.path.join(site, "modular")), "the environment has a modular/ directory"
    else:
        # komira, and Modular's package that installs the runtime it loads.
        extra = [n for n in others if n not in _MODULAR]
        assert not extra, "the environment holds komira and also {}, which is not Modular's".format(", ".join(extra))

    import komira

    init = os.path.realpath(komira.__file__)
    assert init == os.path.join(site, "komira", "__init__.py"), "komira was imported from {}, not from {}".format(init, site)

    dist = metadata.distribution("komira")
    assert dist.version == opts["version"], "the installed komira is {}, the wheel is {}".format(dist.version, opts["version"])
    assert komira.__version__ == opts["version"], "komira.__version__ is {}, the wheel is {}".format(komira.__version__, opts["version"])
    info = os.path.realpath(str(dist.locate_file("komira-{}.dist-info".format(opts["version"]))))
    assert os.path.dirname(info) == site, "komira's metadata is at {}, not in {}".format(info, site)

    check_metadata(dist, site, opts)
    if flavour == "external":
        check_no_modular_file(site)

    want_abi = abi_version_of(opts["abi_table"])
    assert komira.abi_version() == want_abi, "komira.abi_version() is {}, the golden says {}".format(komira.abi_version(), want_abi)

    with komira.Session() as s:
        assert s.register_parquet("two_columns", opts["parquet"]) is None
        missing = os.path.join(os.getcwd(), "missing.parquet")
        try:
            s.register_parquet("missing", missing)
        except komira.KomiraError as e:
            assert e.status == -3, "a missing file raised status {}, not -3: {}".format(e.status, e)
            assert str(e), "a missing file raised KomiraError with no message"
        else:
            raise AssertionError("register_parquet of {} did not raise".format(missing))

    with open(opts["plan_hex"], encoding="utf-8") as f:
        plan = bytes.fromhex(f.read().strip())
    native = komira._native.load()
    ctx = native.ctx_new()
    try:
        text = native.plan_render(ctx, plan)
    finally:
        native.ctx_free(ctx)
    assert 'Scan(path="orders"' in text and "path=/data/orders.orc" in text, "plan_render returned {!r}".format(text)

    maps = mapped_files()
    lib_dir = os.path.join(site, "komira", "_lib")
    runtime_dir = os.path.join(lib_dir, "lib") if flavour == "bundled" else os.path.join(site, "modular", "lib")
    for name in _RUNTIME:
        paths = sorted(p for p in maps if os.path.basename(p) == name)
        assert paths and all(under(p, runtime_dir) for p in paths), "{} is mapped from {}, not from {}".format(name, paths, runtime_dir)
    komira_libs = sorted(p for p in maps if os.path.basename(p).startswith("libkomira"))
    assert os.path.join(lib_dir, _LIBKOMIRA) in komira_libs, "{} is not mapped from {}: {}".format(_LIBKOMIRA, lib_dir, komira_libs)
    owners = [p for p in komira_libs if os.path.basename(p) != _LIBKOMIRA]
    if _DARWIN:
        # The C archives are linked into libkomira.dylib: no owner libraries,
        # and the lib directory holds the three runtime libraries and nothing else.
        assert not owners, "libkomira has no native owners on macOS, and {} are mapped".format(owners)
        held = sorted(os.listdir(runtime_dir))
        assert held == sorted(_RUNTIME), "{} holds {}, not exactly {}".format(runtime_dir, held, sorted(_RUNTIME))
    else:
        owners_dir = os.path.join(lib_dir, "lib")
        assert owners and all(under(p, owners_dir) for p in owners), "the native owners are mapped from {}".format(owners)

    if flavour == "external":
        # After the load, so that a prefix without mojo-compiler fails in the
        # loader, with the error a user sees.
        installed = metadata.version("mojo-compiler")
        want = opts["toolchain_mojo_version"]
        assert installed == want, "mojo-compiler {} is installed, the toolchain's Mojo is {}".format(installed, want)
        # The record names the build of each library the loader opened.
        from komira import _runtime

        with open(os.path.join(site, _RECORD), encoding="utf-8") as f:
            recorded = dict(line.split("\t") for line in f.read().splitlines()[1:])
        for name in _RUNTIME:
            got = _runtime.build_id(os.path.join(runtime_dir, name))
            got = got.hex() if got is not None else None
            assert got == recorded[name], "{} in {} has build id {}, the record names {}".format(name, runtime_dir, got, recorded[name])

    print(
        "installed: komira {} ({} flavour) in {}, libkomira ABI {}, runtime from {}".format(
            komira.__version__, flavour, site, want_abi, runtime_dir
        )
    )


if __name__ == "__main__":
    main(sys.argv[1:])
