"""The version ranges of the distributions the Python package imports, and
the pinned pyarrow wheel of each supported minor.

`PYARROW_REQUIREMENT` is the wheel's one `Requires-Dist` (python/BUCK): a
`Result` reads as pyarrow. Its lower bound is 25.0.1, the pyarrow every test
of the package runs on (`PYARROW_WHEELS`). It has no upper bound: the package
hands pyarrow its answer only through the Arrow C stream interface and the
Arrow PyCapsule interface's `RecordBatchReader.from_stream`, both stable
specifications, and a bound below the newest release would make `pip install
komira` downgrade a user's pyarrow. The wheel's install tests install it beside
the wheel (the installer holds the range) and hold the installed metadata to
this string, so a bound moved without them fails there.

`PYARROW_WHEELS` is {the target suffix of a supported minor (python/pythons.bzl):
the pin of that minor's pyarrow 25.0.1 wheel for linux x86_64}
(third_party/python/pins.bzl), and `PYARROW_MACOS` the macOS arm64 one of
CPython 3.13. python/tests/BUCK declares their downloads.

The plan modules' protobuf range is read only by the tests of python/tests.
The package's first release does not ship the plan modules and declares no
protobuf dependency; the wheel of the release that first ships them declares
`PROTOBUF_REQUIREMENT` as its protobuf `Requires-Dist`.

`PROTOBUF_REQUIREMENT` is the protobuf runtime the generated plan modules
(`komira.plan.v1`, python/BUCK) load under:

- the lower bound is the version of the gencode the pinned protoc (29.1)
  writes, 5.29.1: the runtime refuses gencode newer than itself, so 5.29.1 is
  the oldest runtime that loads it;
- the upper bound excludes the next major, 8: 7.36.2 is the newest runtime the
  tests load the modules under, and no 8.x release exists to test.

python/tests runs the modules under both edges, 5.29.1 and 7.36.2, and under
5.28.3, the release below the range, which must refuse them; each test reads
this string, so a bound moved without its test fails there.
"""

load("@komira//third_party/python:pins.bzl", "MACOS_WHEELS", "PYARROW_311_312", "WHEELS", "WHEELS_314")

PROTOBUF_REQUIREMENT = "protobuf>=5.29.1,<8"

PYARROW_REQUIREMENT = "pyarrow>=25.0.1"

PYARROW_WHEELS = {
    "_py311": PYARROW_311_312["cp311"],
    "_py312": PYARROW_311_312["cp312"],
    "": [w for w in WHEELS if w["name"] == "pyarrow"][0],
    "_py314": [w for w in WHEELS_314["cp314"] if w["name"] == "pyarrow"][0],
}

PYARROW_MACOS = MACOS_WHEELS["pyarrow"] | {"file": MACOS_WHEELS["pyarrow"]["url"].rsplit("/", 1)[1]}
