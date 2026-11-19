"""The static natives each mopm package declares: `[native.<id>]` of its `mopm.toml`, as mopm's unit graph has them.

`{package: [id, ...]}` for every package of //release/readme_e2e:packages.bzl. Each package's
`buildrules.mojo.lock.bzl` is mopm's own output for its manifest (`buildrules mojo sync` writes it, and
`buildrules check` fails when it differs); a `[native.<id>]` of a workspace member is a unit
`native:<package>/<id>` of that graph, so the ids here are read from it and nothing re-parses a `mopm.toml`.
`mopm_artifacts` (mopm_artifacts.bzl) holds its `natives` attribute to this table.

A package of the list needs its `load` below and its row; `mopm_artifacts` refuses a package without a row.
"""

load("//src/anomaly:buildrules.mojo.lock.bzl", anomaly = "GRAPH")
load("//src/atomic_alias:buildrules.mojo.lock.bzl", atomic_alias = "GRAPH")
load("//src/content_line:buildrules.mojo.lock.bzl", content_line = "GRAPH")
load("//src/datetime:buildrules.mojo.lock.bzl", datetime = "GRAPH")
load("//src/encoding:buildrules.mojo.lock.bzl", encoding = "GRAPH")
load("//src/hashing:buildrules.mojo.lock.bzl", hashing = "GRAPH")
load("//src/host_probe:buildrules.mojo.lock.bzl", host_probe = "GRAPH")
load("//src/json:buildrules.mojo.lock.bzl", json = "GRAPH")
load("//src/kafka_server:buildrules.mojo.lock.bzl", kafka_server = "GRAPH")
load("//src/libc:buildrules.mojo.lock.bzl", libc = "GRAPH")
load("//src/lz4:buildrules.mojo.lock.bzl", lz4 = "GRAPH")
load("//src/mail_address:buildrules.mojo.lock.bzl", mail_address = "GRAPH")
load("//src/parquet_api:buildrules.mojo.lock.bzl", parquet_api = "GRAPH")
load("//src/protobuf:buildrules.mojo.lock.bzl", protobuf = "GRAPH")
load("//src/resources:buildrules.mojo.lock.bzl", resources = "GRAPH")
load("//src/retry:buildrules.mojo.lock.bzl", retry = "GRAPH")
load("//src/rowcell:buildrules.mojo.lock.bzl", rowcell = "GRAPH")
load("//src/runtime_paths:buildrules.mojo.lock.bzl", runtime_paths = "GRAPH")
load("//src/scalar_arithmetic:buildrules.mojo.lock.bzl", scalar_arithmetic = "GRAPH")
load("//src/simd_ops:buildrules.mojo.lock.bzl", simd_ops = "GRAPH")
load("//src/test_verdict:buildrules.mojo.lock.bzl", test_verdict = "GRAPH")
load("//src/textproto:buildrules.mojo.lock.bzl", textproto = "GRAPH")
load("//src/validation_run:buildrules.mojo.lock.bzl", validation_run = "GRAPH")
load("//src/xml:buildrules.mojo.lock.bzl", xml = "GRAPH")
load("//src/zlib:buildrules.mojo.lock.bzl", zlib = "GRAPH")

def declared_natives(graph):
    """The ids of the `[native.<id>]` of the package whose unit graph is `graph`, sorted."""
    package = graph["package"].partition("@")[0]
    ids = []
    for unit in graph["units"]:
        if unit["kind"] == "native" and unit["package"] == package:
            ids.append(unit["id"].partition("/")[2])
    return sorted(ids)

_GRAPHS = {
    "anomaly": anomaly,
    "atomic_alias": atomic_alias,
    "content_line": content_line,
    "datetime": datetime,
    "encoding": encoding,
    "hashing": hashing,
    "host_probe": host_probe,
    "json": json,
    "kafka_server": kafka_server,
    "libc": libc,
    "lz4": lz4,
    "mail_address": mail_address,
    "parquet_api": parquet_api,
    "protobuf": protobuf,
    "resources": resources,
    "retry": retry,
    "rowcell": rowcell,
    "runtime_paths": runtime_paths,
    "scalar_arithmetic": scalar_arithmetic,
    "simd_ops": simd_ops,
    "test_verdict": test_verdict,
    "textproto": textproto,
    "validation_run": validation_run,
    "xml": xml,
    "zlib": zlib,
}

NATIVE_IDS = {package: declared_natives(graph) for package, graph in _GRAPHS.items()}
