"""Imports every pinned wheel and holds its version, and the interpreter's, to the pins.

Arguments: `python=<version>` and one `<distribution>=<version>` per wheel of
third_party/python/pins.bzl. Fails unless the distributions named are exactly
the ones MODULES lists, each module imports, and each version (the module's
`__version__`, or the installed metadata where the module has none) is the pin.
A distribution whose module does not load its native code on import also has
the native module named in EXTENSIONS imported.
"""

import importlib
import importlib.metadata
import sys

# distribution -> the module it installs, and whether that module carries
# `__version__`.
MODULES = {
    "duckdb": ("duckdb", True),
    "grpcio": ("grpc", True),
    "numpy": ("numpy", True),
    "pandas": ("pandas", True),
    "polars": ("polars", True),
    "polars-runtime-32": ("_polars_runtime_32", False),
    "protobuf": ("google.protobuf", True),
    "pyarrow": ("pyarrow", True),
    "python-dateutil": ("dateutil", True),
    "six": ("six", True),
    "typing-extensions": ("typing_extensions", False),
    "tzdata": ("tzdata", True),
}

# distribution -> its native module, where importing the module above does not
# load it: `google.protobuf` is pure Python, and upb loads on first use.
EXTENSIONS = {
    "protobuf": "google._upb._message",
}


def main(args):
    pins = dict(a.split("=", 1) for a in args)
    want_python = pins.pop("python")
    got_python = "%d.%d.%d" % sys.version_info[:3]
    assert got_python == want_python, "python is {}, the pin says {}".format(got_python, want_python)
    print("python", got_python)
    assert sorted(pins) == sorted(MODULES), "pinned {} but smoke.py checks {}".format(sorted(pins), sorted(MODULES))
    for dist in sorted(pins):
        module, has_version = MODULES[dist]
        m = importlib.import_module(module)
        if dist in EXTENSIONS:
            importlib.import_module(EXTENSIONS[dist])
        got = m.__version__ if has_version else importlib.metadata.version(dist)
        assert got == pins[dist], "{} ({}) is {}, the pin says {}".format(dist, module, got, pins[dist])
        print(dist, got)


main(sys.argv[1:])
