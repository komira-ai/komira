"""The static natives each mopm package declares: `[native.<id>]` of its `mopm.toml`, as mopm's unit graph has them.

`{package: [id, ...]}` for every package of //release/readme_e2e:packages.bzl. Each package's
`buildrules.mojo.lock.bzl` is mopm's own output for its manifest (`buildrules mojo sync` writes it, and
`buildrules check` fails when it differs); a `[native.<id>]` of a workspace member is a unit
`native:<package>/<id>` of that graph, so the ids here are read from it and nothing re-parses a `mopm.toml`.
`mopm_artifacts` (mopm_artifacts.bzl) holds its `natives` attribute to this table.

A package of the list needs its `load` below and its row; `mopm_artifacts` refuses a package without a row.
"""

load("//src/anomaly:buildrules.mojo.lock.bzl", anomaly = "GRAPH")
load("//src/async_api:buildrules.mojo.lock.bzl", async_api = "GRAPH")
load("//src/atomic_alias:buildrules.mojo.lock.bzl", atomic_alias = "GRAPH")
load("//src/awslc:buildrules.mojo.lock.bzl", awslc = "GRAPH")
load("//src/bench:buildrules.mojo.lock.bzl", bench = "GRAPH")
load("//src/bench_report:buildrules.mojo.lock.bzl", bench_report = "GRAPH")
load("//src/broker_proto:buildrules.mojo.lock.bzl", broker_proto = "GRAPH")
load("//src/byte_buffer:buildrules.mojo.lock.bzl", byte_buffer = "GRAPH")
load("//src/bump_arena:buildrules.mojo.lock.bzl", bump_arena = "GRAPH")
load("//src/calendar:buildrules.mojo.lock.bzl", calendar = "GRAPH")
load("//src/calendar_ics:buildrules.mojo.lock.bzl", calendar_ics = "GRAPH")
load("//src/calendar_proto:buildrules.mojo.lock.bzl", calendar_proto = "GRAPH")
load("//src/chat_proto:buildrules.mojo.lock.bzl", chat_proto = "GRAPH")
load("//src/clock:buildrules.mojo.lock.bzl", clock = "GRAPH")
load("//src/codeworks_api:buildrules.mojo.lock.bzl", codeworks_api = "GRAPH")
load("//src/containers:buildrules.mojo.lock.bzl", containers = "GRAPH")
load("//src/compression:buildrules.mojo.lock.bzl", compression = "GRAPH")
load("//src/contacts_proto:buildrules.mojo.lock.bzl", contacts_proto = "GRAPH")
load("//src/content_line:buildrules.mojo.lock.bzl", content_line = "GRAPH")
load("//src/counters:buildrules.mojo.lock.bzl", counters = "GRAPH")
load("//src/crm_proto:buildrules.mojo.lock.bzl", crm_proto = "GRAPH")
load("//src/crypto:buildrules.mojo.lock.bzl", crypto = "GRAPH")
load("//src/datetime:buildrules.mojo.lock.bzl", datetime = "GRAPH")
load("//src/dynamic_filter:buildrules.mojo.lock.bzl", dynamic_filter = "GRAPH")
load("//src/encoding:buildrules.mojo.lock.bzl", encoding = "GRAPH")
load("//src/fork_join:buildrules.mojo.lock.bzl", fork_join = "GRAPH")
load("//src/hashing:buildrules.mojo.lock.bzl", hashing = "GRAPH")
load("//src/host_probe:buildrules.mojo.lock.bzl", host_probe = "GRAPH")
load("//src/job_report_proto:buildrules.mojo.lock.bzl", job_report_proto = "GRAPH")
load("//src/json:buildrules.mojo.lock.bzl", json = "GRAPH")
load("//src/kafka_server:buildrules.mojo.lock.bzl", kafka_server = "GRAPH")
load("//src/kg_mode:buildrules.mojo.lock.bzl", kg_mode = "GRAPH")
load("//src/kg_spec:buildrules.mojo.lock.bzl", kg_spec = "GRAPH")
load("//src/libc:buildrules.mojo.lock.bzl", libc = "GRAPH")
load("//src/log:buildrules.mojo.lock.bzl", log = "GRAPH")
load("//src/lz4:buildrules.mojo.lock.bzl", lz4 = "GRAPH")
load("//src/mail_address:buildrules.mojo.lock.bzl", mail_address = "GRAPH")
load("//src/mail_message:buildrules.mojo.lock.bzl", mail_message = "GRAPH")
load("//src/managed_mail_proto:buildrules.mojo.lock.bzl", managed_mail_proto = "GRAPH")
load("//src/mcp_server:buildrules.mojo.lock.bzl", mcp_server = "GRAPH")
load("//src/metrics:buildrules.mojo.lock.bzl", metrics = "GRAPH")
load("//src/name_registry:buildrules.mojo.lock.bzl", name_registry = "GRAPH")
load("//src/parquet_api:buildrules.mojo.lock.bzl", parquet_api = "GRAPH")
load("//src/plan_proto:buildrules.mojo.lock.bzl", plan_proto = "GRAPH")
load("//src/proto_codec:buildrules.mojo.lock.bzl", proto_codec = "GRAPH")
load("//src/protobuf:buildrules.mojo.lock.bzl", protobuf = "GRAPH")
load("//src/resources:buildrules.mojo.lock.bzl", resources = "GRAPH")
load("//src/retry:buildrules.mojo.lock.bzl", retry = "GRAPH")
load("//src/rowcell:buildrules.mojo.lock.bzl", rowcell = "GRAPH")
load("//src/runtime_paths:buildrules.mojo.lock.bzl", runtime_paths = "GRAPH")
load("//src/scalar_arithmetic:buildrules.mojo.lock.bzl", scalar_arithmetic = "GRAPH")
load("//src/simd_ops:buildrules.mojo.lock.bzl", simd_ops = "GRAPH")
load("//src/snapshotter:buildrules.mojo.lock.bzl", snapshotter = "GRAPH")
load("//src/spsc_ring:buildrules.mojo.lock.bzl", spsc_ring = "GRAPH")
load("//src/supervisor_proto:buildrules.mojo.lock.bzl", supervisor_proto = "GRAPH")
load("//src/sync:buildrules.mojo.lock.bzl", sync = "GRAPH")
load("//src/test_run_id:buildrules.mojo.lock.bzl", test_run_id = "GRAPH")
load("//src/test_verdict:buildrules.mojo.lock.bzl", test_verdict = "GRAPH")
load("//src/textproto:buildrules.mojo.lock.bzl", textproto = "GRAPH")
load("//src/trace:buildrules.mojo.lock.bzl", trace = "GRAPH")
load("//src/uuid:buildrules.mojo.lock.bzl", uuid = "GRAPH")
load("//src/validation_run:buildrules.mojo.lock.bzl", validation_run = "GRAPH")
load("//src/vcard:buildrules.mojo.lock.bzl", vcard = "GRAPH")
load("//src/wkt:buildrules.mojo.lock.bzl", wkt = "GRAPH")
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
    "async_api": async_api,
    "atomic_alias": atomic_alias,
    "awslc": awslc,
    "bench": bench,
    "bench_report": bench_report,
    "broker_proto": broker_proto,
    "byte_buffer": byte_buffer,
    "bump_arena": bump_arena,
    "calendar": calendar,
    "calendar_ics": calendar_ics,
    "calendar_proto": calendar_proto,
    "chat_proto": chat_proto,
    "clock": clock,
    "codeworks_api": codeworks_api,
    "containers": containers,
    "compression": compression,
    "contacts_proto": contacts_proto,
    "content_line": content_line,
    "counters": counters,
    "crm_proto": crm_proto,
    "crypto": crypto,
    "datetime": datetime,
    "dynamic_filter": dynamic_filter,
    "encoding": encoding,
    "fork_join": fork_join,
    "hashing": hashing,
    "host_probe": host_probe,
    "job_report_proto": job_report_proto,
    "json": json,
    "kafka_server": kafka_server,
    "kg_mode": kg_mode,
    "kg_spec": kg_spec,
    "libc": libc,
    "log": log,
    "lz4": lz4,
    "mail_address": mail_address,
    "mail_message": mail_message,
    "managed_mail_proto": managed_mail_proto,
    "mcp_server": mcp_server,
    "metrics": metrics,
    "name_registry": name_registry,
    "parquet_api": parquet_api,
    "plan_proto": plan_proto,
    "proto_codec": proto_codec,
    "protobuf": protobuf,
    "resources": resources,
    "retry": retry,
    "rowcell": rowcell,
    "runtime_paths": runtime_paths,
    "scalar_arithmetic": scalar_arithmetic,
    "simd_ops": simd_ops,
    "snapshotter": snapshotter,
    "spsc_ring": spsc_ring,
    "supervisor_proto": supervisor_proto,
    "sync": sync,
    "test_run_id": test_run_id,
    "test_verdict": test_verdict,
    "textproto": textproto,
    "trace": trace,
    "uuid": uuid,
    "validation_run": validation_run,
    "vcard": vcard,
    "wkt": wkt,
    "xml": xml,
    "zlib": zlib,
}

NATIVE_IDS = {package: declared_natives(graph) for package, graph in _GRAPHS.items()}
