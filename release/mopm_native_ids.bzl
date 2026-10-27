"""The static natives each mopm package declares: `[native.<id>]` of its `mopm.toml`, as mopm's unit graph has them.

`{package: [id, ...]}` for every package of //release/readme_e2e:packages.bzl. Each package's
`buildrules.mojo.lock.bzl` is mopm's own output for its manifest (`buildrules mojo sync` writes it, and
`buildrules check` fails when it differs); a `[native.<id>]` of a workspace member is a unit
`native:<package>/<id>` of that graph, so the ids here are read from it and nothing re-parses a `mopm.toml`.
`mopm_artifacts` (mopm_artifacts.bzl) holds its `natives` attribute to this table.

A package of the list needs its `load` below and its row; `mopm_artifacts` refuses a package without a row.
"""

load("//src/komira_anomaly:buildrules.mojo.lock.bzl", komira_anomaly = "GRAPH")
load("//src/komira_atomic_alias:buildrules.mojo.lock.bzl", komira_atomic_alias = "GRAPH")
load("//src/komira_content_line:buildrules.mojo.lock.bzl", komira_content_line = "GRAPH")
load("//src/komira_datetime:buildrules.mojo.lock.bzl", komira_datetime = "GRAPH")
load("//src/komira_encoding:buildrules.mojo.lock.bzl", komira_encoding = "GRAPH")
load("//src/komira_hash:buildrules.mojo.lock.bzl", komira_hash = "GRAPH")
load("//src/komira_host:buildrules.mojo.lock.bzl", komira_host = "GRAPH")
load("//src/komira_json:buildrules.mojo.lock.bzl", komira_json = "GRAPH")
load("//src/komira_kafka_server:buildrules.mojo.lock.bzl", komira_kafka_server = "GRAPH")
load("//src/komira_kg_mode:buildrules.mojo.lock.bzl", komira_kg_mode = "GRAPH")
load("//src/komira_libc:buildrules.mojo.lock.bzl", komira_libc = "GRAPH")
load("//src/komira_lz4:buildrules.mojo.lock.bzl", komira_lz4 = "GRAPH")
load("//src/komira_mail_address:buildrules.mojo.lock.bzl", komira_mail_address = "GRAPH")
load("//src/komira_parquet_api:buildrules.mojo.lock.bzl", komira_parquet_api = "GRAPH")
load("//src/komira_protobuf:buildrules.mojo.lock.bzl", komira_protobuf = "GRAPH")
load("//src/komira_retry:buildrules.mojo.lock.bzl", komira_retry = "GRAPH")
load("//src/komira_rowcell:buildrules.mojo.lock.bzl", komira_rowcell = "GRAPH")
load("//src/komira_runtime_paths:buildrules.mojo.lock.bzl", komira_runtime_paths = "GRAPH")
load("//src/komira_scalar_arithmetic:buildrules.mojo.lock.bzl", komira_scalar_arithmetic = "GRAPH")
load("//src/komira_simd:buildrules.mojo.lock.bzl", komira_simd = "GRAPH")
load("//src/komira_test_verdict:buildrules.mojo.lock.bzl", komira_test_verdict = "GRAPH")
load("//src/komira_textproto:buildrules.mojo.lock.bzl", komira_textproto = "GRAPH")
load("//src/komira_validation_run:buildrules.mojo.lock.bzl", komira_validation_run = "GRAPH")
load("//src/komira_xml:buildrules.mojo.lock.bzl", komira_xml = "GRAPH")
load("//src/komira_zlib:buildrules.mojo.lock.bzl", komira_zlib = "GRAPH")

def declared_natives(graph):
    """The ids of the `[native.<id>]` of the package whose unit graph is `graph`, sorted."""
    package = graph["package"].partition("@")[0]
    ids = []
    for unit in graph["units"]:
        if unit["kind"] == "native" and unit["package"] == package:
            ids.append(unit["id"].partition("/")[2])
    return sorted(ids)

_GRAPHS = {
    "komira_anomaly": komira_anomaly,
    "komira_atomic_alias": komira_atomic_alias,
    "komira_content_line": komira_content_line,
    "komira_datetime": komira_datetime,
    "komira_encoding": komira_encoding,
    "komira_hash": komira_hash,
    "komira_host": komira_host,
    "komira_json": komira_json,
    "komira_kafka_server": komira_kafka_server,
    "komira_kg_mode": komira_kg_mode,
    "komira_libc": komira_libc,
    "komira_lz4": komira_lz4,
    "komira_mail_address": komira_mail_address,
    "komira_parquet_api": komira_parquet_api,
    "komira_protobuf": komira_protobuf,
    "komira_retry": komira_retry,
    "komira_rowcell": komira_rowcell,
    "komira_runtime_paths": komira_runtime_paths,
    "komira_scalar_arithmetic": komira_scalar_arithmetic,
    "komira_simd": komira_simd,
    "komira_test_verdict": komira_test_verdict,
    "komira_textproto": komira_textproto,
    "komira_validation_run": komira_validation_run,
    "komira_xml": komira_xml,
    "komira_zlib": komira_zlib,
}

NATIVE_IDS = {package: declared_natives(graph) for package, graph in _GRAPHS.items()}
