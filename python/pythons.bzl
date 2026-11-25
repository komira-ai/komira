"""The CPython minors the Python package supports: the one list of them
(python/README.md, "Supported Pythons").

Everything that names the supported Pythons reads PYTHONS: the wheel's
`Requires-Python` (REQUIRES_PYTHON, the oldest minor and newer) and its
`Programming Language` classifiers (CLASSIFIERS), the package's tests and the
wheel's install and upgrade tests, one of each per minor on its pinned
interpreter (python/BUCK, python/tests/BUCK), and the hosted-runner jobs of
pypi.yml (the Linux and the macOS jobs), one per minor and platform (the wheel's
user test and the index smoke): they build the target
`//python:supported_pythons`, whose sub-target per platform
(`[linux-x86_64]`, `[macos-arm64]`) is a JSON list of the exact versions
`actions/setup-python` installs there, and `pypi_smoke matrix` writes it as
the job matrix.

Each entry, oldest first:

- `minor`: `3.<n>`.
- `python`: the pinned interpreter of the farm's tests (third_party/python),
  whose version is the one the Linux jobs install.
- `suffix`: what the names of that minor's test targets end with; the 3.13
  targets keep the names they had before the list, with no suffix.
- `macos`: the exact version the macOS arm64 jobs install. A CPython minor that
  only takes security fixes is released as source alone, so `actions/setup-python`
  has no macOS build of its newer patch releases: the newest it has of 3.11 is
  3.11.9 and of 3.12 is 3.12.10.

A minor joins with a line here and its interpreter's pin; the farm's macOS
tests run CPython 3.13 alone (third_party/python, `cpython_macos`).
"""

load("@komira//third_party/python:pins.bzl", "PYTHON", "PYTHON_311", "PYTHON_312", "PYTHON_314")

def _minor(version):
    return ".".join(version.split(".")[:2])

def _entry(pin, suffix, macos):
    return {
        "linux": pin["version"],
        "macos": macos,
        "minor": _minor(pin["version"]),
        "python": "komira//third_party/python:" + pin["name"],
        "suffix": suffix,
    }

PYTHONS = [
    _entry(PYTHON_311, "_py311", "3.11.9"),
    _entry(PYTHON_312, "_py312", "3.12.10"),
    _entry(PYTHON, "", "3.13.16"),
    _entry(PYTHON_314, "_py314", "3.14.8"),
]

REQUIRES_PYTHON = ">=" + PYTHONS[0]["minor"]

CLASSIFIERS = ["Programming Language :: Python :: 3 :: Only"] + [
    "Programming Language :: Python :: " + p["minor"]
    for p in PYTHONS
]

# {platform: the exact versions its hosted-runner jobs install, oldest first}
HOSTED = {
    "linux-x86_64": [p["linux"] for p in PYTHONS],
    "macos-arm64": [p["macos"] for p in PYTHONS],
}
