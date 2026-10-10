"""No host Python and no host library reaches a py_test action.

Fails unless: the interpreter (`sys.executable`), `sys.prefix` and every
`sys.path` entry lie under the action's working directory, inside its
`buck-out/`; no `PATH` entry lies outside it; the archive's own
site-packages is not on sys.path and pip is not importable; after the
imports in mapped_files, a shared object of each package in NATIVE is mapped
(so each wheel's native module is loaded, protobuf's upb backend included); and
every file the process maps lies under the working directory except glibc's own
libraries (the host floor, tools/build/toolchains/README.md). So a worker's
/usr/bin/python3, its /usr/lib/python3 and its libstdc++.so.6 are all refused.
"""

import importlib.util
import os
import sys

ROOT = os.getcwd()
INSIDE = ROOT + os.sep

# glibc, which the host floor allows an action to take from the worker.
GLIBC = {
    "ld-linux-x86-64.so.2",
    "libc.so.6",
    "libdl.so.2",
    "libm.so.6",
    "libpthread.so.0",
    "librt.so.1",
    "libutil.so.1",
}


# The packages whose shared objects must be mapped once mapped_files has
# imported them: each pinned wheel that carries native code. protobuf's lives
# in google._upb, which `import google.protobuf` alone does not load.
NATIVE = [
    "_duckdb",
    "_polars_runtime_32",
    "google._upb",
    "grpc",
    "numpy",
    "pandas",
    "pyarrow",
]


def under_root(path):
    return path.startswith(INSIDE)


def interpreter():
    for name, path in [("sys.executable", sys.executable), ("sys.prefix", sys.prefix), ("sys.base_prefix", sys.base_prefix)]:
        assert under_root(path) and "/buck-out/" in path, "{} is {}, outside the action's buck-out ({})".format(name, path, ROOT)
    for entry in sys.path:
        assert under_root(entry), "sys.path entry {} is outside the action ({})".format(entry, ROOT)
    outside = [p for p in os.environ.get("PATH", "").split(os.pathsep) if p and not under_root(os.path.abspath(p))]
    assert not outside, "PATH names directories outside the action: {}".format(outside)
    site = os.path.join(sys.prefix, "lib", "python%d.%d" % sys.version_info[:2], "site-packages")
    assert site not in sys.path, "the archive's site-packages {} is on sys.path".format(site)
    assert importlib.util.find_spec("pip") is None, "pip is importable"
    print("interpreter:", os.path.relpath(sys.executable, ROOT))


def mapped_files():
    import duckdb  # noqa: F401
    import google.protobuf  # noqa: F401
    from google.protobuf import descriptor_pb2  # noqa: F401
    import grpc  # noqa: F401
    import numpy  # noqa: F401
    import pandas  # noqa: F401
    import polars  # noqa: F401
    import pyarrow  # noqa: F401
    import pyarrow.flight  # noqa: F401
    import pyarrow.parquet  # noqa: F401

    paths = set()
    with open("/proc/self/maps") as f:
        for line in f:
            fields = line.split(None, 5)
            if len(fields) == 6 and fields[5].startswith("/"):
                paths.add(fields[5].rstrip("\n"))
    for name in NATIVE:
        spec = importlib.util.find_spec(name)
        if spec is None:
            prefixes = []
        elif spec.submodule_search_locations:
            prefixes = [d + os.sep for d in spec.submodule_search_locations]
        else:
            prefixes = [spec.origin]
        loaded = [p for p in paths if ".so" in os.path.basename(p) and any(p.startswith(x) for x in prefixes)]
        assert loaded, "no shared object of {} is mapped".format(name)
    host = sorted(p for p in paths if not under_root(p) and os.path.basename(p) not in GLIBC)
    assert not host, "files mapped from outside the action: {}".format(host)
    inside = sum(1 for p in paths if under_root(p))
    print("mapped files: {} under the action, {} glibc".format(inside, len(paths) - inside))


interpreter()
mapped_files()
