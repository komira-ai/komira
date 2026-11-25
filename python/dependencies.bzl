"""The version ranges of the distributions the Python package imports, and
the pinned pyarrow and protobuf wheels its install tests install beside it.

`PYARROW_REQUIREMENT` and `PROTOBUF_REQUIREMENT` are the wheel's two
`Requires-Dist` lines (python/BUCK), in that order: a `Result` reads as
pyarrow, and a DataFrame encodes its plan with the generated plan modules
(`komira.plan.v1`), which protobuf loads.

`PYARROW_REQUIREMENT`: Its lower bound is 25.0.1, the pyarrow every test
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

The wheel ships the plan modules and declares `PROTOBUF_REQUIREMENT`.
`import komira` does not import protobuf: the first reader that makes a
DataFrame does.

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

`PROTOBUF_WHEEL` is the pin of the protobuf 7.36.2 wheel for linux x86_64
(`abi3`, one file for every supported minor) and `PROTOBUF_MACOS` the macOS
arm64 one: the wheel's install tests install it beside komira's wheel, as
`pip install komira` installs protobuf with it. python/tests/BUCK declares
their downloads.
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

PROTOBUF_WHEEL = [w for w in WHEELS if w["name"] == "protobuf"][0]

PROTOBUF_MACOS = MACOS_WHEELS["protobuf"] | {"file": MACOS_WHEELS["protobuf"]["url"].rsplit("/", 1)[1]}

# The pinned DuckDB wheel (CPython 3.13, linux x86_64), which the analysis job
# test (python/BUCK, `analysis_job_test`) installs beside komira's wheel to
# compare its answers with DuckDB's. It is a test input: the komira wheel does
# not require it. python/tests/BUCK declares its download.
DUCKDB_WHEEL = [w for w in WHEELS if w["name"] == "duckdb"][0]
