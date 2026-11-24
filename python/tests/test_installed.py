"""The installed komira wheel, run from an empty prefix: what `pip install
komira` into a new environment gives a user (python/BUCK, wheel_install_test,
on Linux x86_64 and, for the macOS wheel, on macOS arm64).

    <prefix>/bin/python3.<minor> -I test_installed.py --site <dir>
        [--host-lib <lib>]... --version <v> --license-expression <expr>
        --requires-python <spec> --classifier <classifier>...
        --abi-table <komira.tsv> --license <LICENSE> --notice <NOTICE>
        --modular-license <LICENSE> --modular-notices <Third-Party-Notices>
        --aws-lc-license <LICENSE> --s2n-tls-license <LICENSE>
        --parquet <file.parquet> --plan-hex <file.hex>
        --readings <readings.parquet> --requires-dist <requirement>...

Run by wheel_install_run.py, which installed the wheels into `--site` and
starts this from an empty working directory outside the checkout. Each
`--host-lib` is opened by path first: the C++ runtime (libstdc++, libgcc_s)
that the Mojo runtime libraries need and a user's system provides; the build
workers provide none, so the hermetic interpreter's copies stand in for it.
Then, in order:

- no library path is set: LD_LIBRARY_PATH and LD_PRELOAD are empty (on
  macOS, DYLD_LIBRARY_PATH, DYLD_FALLBACK_LIBRARY_PATH and
  DYLD_INSERT_LIBRARIES);
- the environment holds the distribution komira, the distributions its
  `--requires-dist` lines name (pyarrow) and no other, and no `modular/`
  directory: nothing of Modular's;
- `import komira` is the package installed in `--site`, not a source tree;
- the installed distribution is `--version`, and `komira.__version__` is it;
- its `Requires-Dist` lines are the `--requires-dist` values, in that order
  and no other, its `License-Expression` is the
  given one, its `Requires-Python` is `--requires-python`, and its
  `Classifier` lines are the `--classifier` values, in that order and no
  other; `.dist-info/licenses/` holds LICENSE and NOTICE, byte for byte the
  repository's, `AWS_LC_LICENSE` and `S2N_TLS_LICENSE`, byte for byte the
  pinned aws-lc and s2n-tls archives' LICENSE files, and `MODULAR_LICENSE`
  and `MODULAR_THIRD_PARTY_NOTICES`, byte for byte the pinned compiler
  package's, and no other; its description is
  README.md, which starts with the line `# komira`;
- `komira.abi_version()` is the `version` line of the ABI golden;
- `Session().register_parquet` registers the Parquet fixture, and a missing
  file raises `KomiraError` with the engine's status;
- `Session.sql("SELECT 1 AS n").to_arrow()` is one row, `n` INT32 holding 1,
  and an aggregate over `--readings` (`id` 1 to 5, `value` 10.5 to 50.5) is
  its one row of count, sum, min and max, read with the installed pyarrow;
- `komira._native.plan_render` of the serialized plan returns its text;
- the process maps libkomira (`libkomira.so`, `libkomira.dylib` on macOS) from
  `<site>/komira/_lib`, and its native owner libraries and the three Mojo
  runtime libraries from `<site>/komira/_lib/lib`, and none of them from
  elsewhere. On macOS libkomira has no native owner libraries, and `lib/` holds
  exactly the three runtime libraries (`.dylib`). The mapped files are
  /proc/self/maps on Linux and the images dyld has loaded on macOS.

Any failure raises; its last traceback line is what a refusing case of
wheel_install_test names.
"""

import ctypes
import os
import re
import sys
from importlib import metadata

_DARWIN = sys.platform == "darwin"

# The Mojo runtime libraries the wheel carries.
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

# The licence files the wheel carries, in `.dist-info/licenses/`.
_LICENCES = (
    "LICENSE",
    "NOTICE",
    "AWS_LC_LICENSE",
    "S2N_TLS_LICENSE",
    "MODULAR_LICENSE",
    "MODULAR_THIRD_PARTY_NOTICES",
)

_VALUED = (
    "--site",
    "--version",
    "--license-expression",
    "--abi-table",
    "--license",
    "--notice",
    "--modular-license",
    "--modular-notices",
    "--aws-lc-license",
    "--s2n-tls-license",
    "--parquet",
    "--plan-hex",
    "--requires-python",
    "--readings",
)


def parse(argv):
    opts = {"host_lib": [], "classifier": [], "requires_dist": []}
    i = 0
    while i < len(argv):
        flag = argv[i]
        if i + 1 >= len(argv):
            raise SystemExit("test_installed: flag {} needs a value".format(flag))
        value = argv[i + 1]
        if flag in ("--host-lib", "--classifier", "--requires-dist"):
            opts[flag[2:].replace("-", "_")].append(value)
        elif flag in _VALUED:
            opts[flag[2:].replace("-", "_")] = value
        else:
            raise SystemExit("test_installed: unknown flag {}".format(flag))
        i += 2
    for flag in _VALUED:
        if flag[2:].replace("-", "_") not in opts:
            raise SystemExit("test_installed: {} is required".format(flag))
    if not opts["classifier"]:
        raise SystemExit("test_installed: --classifier is required at least once")
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


def normalize(name):
    """The PEP 503 normalized form of a distribution name."""
    return re.sub(r"[-_.]+", "-", name).lower()


def under(path, directory):
    return os.path.dirname(path) == os.path.realpath(directory)


def check_metadata(dist, opts):
    """The installed distribution's metadata: its requirements, the Pythons it
    claims, the licence expression and files, and the description."""
    got = dist.metadata.get_all("Requires-Dist") or []
    assert got == opts["requires_dist"], "the wheel's Requires-Dist is {}, not {}".format(got, opts["requires_dist"])

    requires_python = dist.metadata["Requires-Python"]
    assert requires_python == opts["requires_python"], "the wheel's Requires-Python is {}, not {}".format(requires_python, opts["requires_python"])
    classifiers = dist.metadata.get_all("Classifier") or []
    assert classifiers == opts["classifier"], "the wheel's Classifier lines are {}, not {}".format(classifiers, opts["classifier"])

    expression = dist.metadata["License-Expression"]
    assert expression == opts["license_expression"], "the wheel's License-Expression is {}".format(expression)
    sources = {
        "LICENSE": opts["license"],
        "NOTICE": opts["notice"],
        "AWS_LC_LICENSE": opts["aws_lc_license"],
        "S2N_TLS_LICENSE": opts["s2n_tls_license"],
        "MODULAR_LICENSE": opts["modular_license"],
        "MODULAR_THIRD_PARTY_NOTICES": opts["modular_notices"],
    }
    files = sorted(dist.metadata.get_all("License-File") or [])
    assert files == sorted(_LICENCES), "the wheel's License-File lines are {}".format(files)
    for name in _LICENCES:
        got = dist.read_text("licenses/" + name)
        assert got is not None, "the wheel has no .dist-info/licenses/{}".format(name)
        with open(sources[name], encoding="utf-8") as f:
            assert got == f.read(), ".dist-info/licenses/{} differs from {}".format(name, sources[name])

    text = dist.read_text("METADATA")
    body = text.split("\n\n", 1)[1] if "\n\n" in text else ""
    first = body.split("\n", 1)[0]
    assert first == "# komira", "the wheel's description starts {!r}, not with README.md's first line".format(first)


def main(argv):
    opts = parse(argv)
    for lib in opts["host_lib"]:
        ctypes.CDLL(lib, mode=ctypes.RTLD_GLOBAL)

    for name in _LIBRARY_PATH_VARIABLES:
        assert os.environ.get(name, "") == "", "{} is set: {}".format(name, os.environ[name])
    assert os.listdir(os.getcwd()) == [], "the working directory is not empty: {}".format(os.listdir(os.getcwd()))

    site = os.path.realpath(opts["site"])

    # `pip install komira` installed komira, its requirements and nothing else.
    names = sorted({normalize(d.metadata["Name"]) for d in metadata.distributions(path=[site])})
    required = {normalize(re.match(r"[A-Za-z0-9._-]+", r).group(0)) for r in opts["requires_dist"]}
    others = [n for n in names if n != "komira" and n not in required]
    assert "komira" in names, "komira is not installed: {}".format(names)
    assert not others, "the environment holds komira and also {}".format(", ".join(others))
    assert not os.path.exists(os.path.join(site, "modular")), "the environment has a modular/ directory"

    import komira

    init = os.path.realpath(komira.__file__)
    assert init == os.path.join(site, "komira", "__init__.py"), "komira was imported from {}, not from {}".format(init, site)

    dist = metadata.distribution("komira")
    assert dist.version == opts["version"], "the installed komira is {}, the wheel is {}".format(dist.version, opts["version"])
    assert komira.__version__ == opts["version"], "komira.__version__ is {}, the wheel is {}".format(komira.__version__, opts["version"])
    info = os.path.realpath(str(dist.locate_file("komira-{}.dist-info".format(opts["version"]))))
    assert os.path.dirname(info) == site, "komira's metadata is at {}, not in {}".format(info, site)

    check_metadata(dist, opts)

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

        # SQL, read as Arrow by the installed pyarrow.
        one = s.sql("SELECT 1 AS n").to_arrow()
        assert one.schema.names == ["n"] and str(one.schema.field("n").type) == "int32", one.schema
        assert one.to_pylist() == [{"n": 1}], one.to_pylist()
        s.register_parquet("readings", opts["readings"])
        agg = s.sql("SELECT count(*) AS n, sum(value) AS total, min(id) AS lo, max(id) AS hi FROM readings").to_arrow()
        want = [{"n": 5, "total": 152.5, "lo": 1, "hi": 5}]
        assert agg.to_pylist() == want, "the aggregate over {} is {}, not {}".format(opts["readings"], agg.to_pylist(), want)

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
    runtime_dir = os.path.join(lib_dir, "lib")
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
        assert owners and all(under(p, runtime_dir) for p in owners), "the native owners are mapped from {}".format(owners)

    print("installed: komira {} in {}, libkomira ABI {}, runtime from {}".format(komira.__version__, site, want_abi, runtime_dir))


if __name__ == "__main__":
    main(sys.argv[1:])
