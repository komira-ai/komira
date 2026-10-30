"""The static natives each mopm package declares: `[native.<id>]` of its `mopm.toml`, as mopm's unit graph has them.

`{package: [id, ...]}` for every package of //release/readme_e2e:packages.bzl. Each package's
`buildrules.mojo.lock.bzl` is mopm's own output for its manifest (`buildrules mojo sync` writes it, and
`buildrules check` fails when it differs); a `[native.<id>]` of a workspace member is a unit
`native:<package>/<id>` of that graph, so the ids here are read from it and nothing re-parses a `mopm.toml`.
`mopm_artifacts` (mopm_artifacts.bzl) holds its `natives` attribute to this table.

A package of the list needs its `load` below and its row; `mopm_artifacts` refuses a package without a row.
"""

load("//src/kci_artifact_proto:buildrules.mojo.lock.bzl", kci_artifact_proto = "GRAPH")
load("//src/kci_deploy_model_proto:buildrules.mojo.lock.bzl", kci_deploy_model_proto = "GRAPH")
load("//src/kci_manifest_proto:buildrules.mojo.lock.bzl", kci_manifest_proto = "GRAPH")
load("//src/kci_resource_proto:buildrules.mojo.lock.bzl", kci_resource_proto = "GRAPH")
load("//src/komira_anomaly:buildrules.mojo.lock.bzl", komira_anomaly = "GRAPH")
load("//src/komira_async_api:buildrules.mojo.lock.bzl", komira_async_api = "GRAPH")
load("//src/komira_atomic_alias:buildrules.mojo.lock.bzl", komira_atomic_alias = "GRAPH")
load("//src/komira_bench_report:buildrules.mojo.lock.bzl", komira_bench_report = "GRAPH")
load("//src/komira_broker_proto:buildrules.mojo.lock.bzl", komira_broker_proto = "GRAPH")
load("//src/komira_buffer:buildrules.mojo.lock.bzl", komira_buffer = "GRAPH")
load("//src/komira_bump_arena:buildrules.mojo.lock.bzl", komira_bump_arena = "GRAPH")
load("//src/komira_calendar_proto:buildrules.mojo.lock.bzl", komira_calendar_proto = "GRAPH")
load("//src/komira_chat_proto:buildrules.mojo.lock.bzl", komira_chat_proto = "GRAPH")
load("//src/komira_clock:buildrules.mojo.lock.bzl", komira_clock = "GRAPH")
load("//src/komira_collections:buildrules.mojo.lock.bzl", komira_collections = "GRAPH")
load("//src/komira_contacts_proto:buildrules.mojo.lock.bzl", komira_contacts_proto = "GRAPH")
load("//src/komira_content_line:buildrules.mojo.lock.bzl", komira_content_line = "GRAPH")
load("//src/komira_counters:buildrules.mojo.lock.bzl", komira_counters = "GRAPH")
load("//src/komira_crm_proto:buildrules.mojo.lock.bzl", komira_crm_proto = "GRAPH")
load("//src/komira_datetime:buildrules.mojo.lock.bzl", komira_datetime = "GRAPH")
load("//src/komira_dynamic_filter:buildrules.mojo.lock.bzl", komira_dynamic_filter = "GRAPH")
load("//src/komira_encoding:buildrules.mojo.lock.bzl", komira_encoding = "GRAPH")
load("//src/komira_fork_join:buildrules.mojo.lock.bzl", komira_fork_join = "GRAPH")
load("//src/komira_hash:buildrules.mojo.lock.bzl", komira_hash = "GRAPH")
load("//src/komira_host:buildrules.mojo.lock.bzl", komira_host = "GRAPH")
load("//src/komira_job_report_proto:buildrules.mojo.lock.bzl", komira_job_report_proto = "GRAPH")
load("//src/komira_json:buildrules.mojo.lock.bzl", komira_json = "GRAPH")
load("//src/komira_kafka_server:buildrules.mojo.lock.bzl", komira_kafka_server = "GRAPH")
load("//src/komira_kg_mode:buildrules.mojo.lock.bzl", komira_kg_mode = "GRAPH")
load("//src/komira_kg_spec:buildrules.mojo.lock.bzl", komira_kg_spec = "GRAPH")
load("//src/komira_libc:buildrules.mojo.lock.bzl", komira_libc = "GRAPH")
load("//src/komira_log:buildrules.mojo.lock.bzl", komira_log = "GRAPH")
load("//src/komira_lz4:buildrules.mojo.lock.bzl", komira_lz4 = "GRAPH")
load("//src/komira_mail_address:buildrules.mojo.lock.bzl", komira_mail_address = "GRAPH")
load("//src/komira_mail_message:buildrules.mojo.lock.bzl", komira_mail_message = "GRAPH")
load("//src/komira_managed_mail_proto:buildrules.mojo.lock.bzl", komira_managed_mail_proto = "GRAPH")
load("//src/komira_mcp_server:buildrules.mojo.lock.bzl", komira_mcp_server = "GRAPH")
load("//src/komira_metrics:buildrules.mojo.lock.bzl", komira_metrics = "GRAPH")
load("//src/komira_name_registry:buildrules.mojo.lock.bzl", komira_name_registry = "GRAPH")
load("//src/komira_parquet_api:buildrules.mojo.lock.bzl", komira_parquet_api = "GRAPH")
load("//src/komira_plan_proto:buildrules.mojo.lock.bzl", komira_plan_proto = "GRAPH")
load("//src/komira_proto_codec:buildrules.mojo.lock.bzl", komira_proto_codec = "GRAPH")
load("//src/komira_protobuf:buildrules.mojo.lock.bzl", komira_protobuf = "GRAPH")
load("//src/komira_resources:buildrules.mojo.lock.bzl", komira_resources = "GRAPH")
load("//src/komira_retry:buildrules.mojo.lock.bzl", komira_retry = "GRAPH")
load("//src/komira_rowcell:buildrules.mojo.lock.bzl", komira_rowcell = "GRAPH")
load("//src/komira_runtime_paths:buildrules.mojo.lock.bzl", komira_runtime_paths = "GRAPH")
load("//src/komira_scalar_arithmetic:buildrules.mojo.lock.bzl", komira_scalar_arithmetic = "GRAPH")
load("//src/komira_simd:buildrules.mojo.lock.bzl", komira_simd = "GRAPH")
load("//src/komira_snapshotter:buildrules.mojo.lock.bzl", komira_snapshotter = "GRAPH")
load("//src/komira_spsc_ring:buildrules.mojo.lock.bzl", komira_spsc_ring = "GRAPH")
load("//src/komira_supervisor_proto:buildrules.mojo.lock.bzl", komira_supervisor_proto = "GRAPH")
load("//src/komira_sync:buildrules.mojo.lock.bzl", komira_sync = "GRAPH")
load("//src/komira_test_run_id:buildrules.mojo.lock.bzl", komira_test_run_id = "GRAPH")
load("//src/komira_test_verdict:buildrules.mojo.lock.bzl", komira_test_verdict = "GRAPH")
load("//src/komira_textproto:buildrules.mojo.lock.bzl", komira_textproto = "GRAPH")
load("//src/komira_trace:buildrules.mojo.lock.bzl", komira_trace = "GRAPH")
load("//src/komira_validation_run:buildrules.mojo.lock.bzl", komira_validation_run = "GRAPH")
load("//src/komira_vcard:buildrules.mojo.lock.bzl", komira_vcard = "GRAPH")
load("//src/komira_wkt:buildrules.mojo.lock.bzl", komira_wkt = "GRAPH")
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
    "kci_artifact_proto": kci_artifact_proto,
    "kci_deploy_model_proto": kci_deploy_model_proto,
    "kci_manifest_proto": kci_manifest_proto,
    "kci_resource_proto": kci_resource_proto,
    "komira_anomaly": komira_anomaly,
    "komira_async_api": komira_async_api,
    "komira_atomic_alias": komira_atomic_alias,
    "komira_bench_report": komira_bench_report,
    "komira_broker_proto": komira_broker_proto,
    "komira_buffer": komira_buffer,
    "komira_bump_arena": komira_bump_arena,
    "komira_calendar_proto": komira_calendar_proto,
    "komira_chat_proto": komira_chat_proto,
    "komira_clock": komira_clock,
    "komira_collections": komira_collections,
    "komira_contacts_proto": komira_contacts_proto,
    "komira_content_line": komira_content_line,
    "komira_counters": komira_counters,
    "komira_crm_proto": komira_crm_proto,
    "komira_datetime": komira_datetime,
    "komira_dynamic_filter": komira_dynamic_filter,
    "komira_encoding": komira_encoding,
    "komira_fork_join": komira_fork_join,
    "komira_hash": komira_hash,
    "komira_host": komira_host,
    "komira_job_report_proto": komira_job_report_proto,
    "komira_json": komira_json,
    "komira_kafka_server": komira_kafka_server,
    "komira_kg_mode": komira_kg_mode,
    "komira_kg_spec": komira_kg_spec,
    "komira_libc": komira_libc,
    "komira_log": komira_log,
    "komira_lz4": komira_lz4,
    "komira_mail_address": komira_mail_address,
    "komira_mail_message": komira_mail_message,
    "komira_managed_mail_proto": komira_managed_mail_proto,
    "komira_mcp_server": komira_mcp_server,
    "komira_metrics": komira_metrics,
    "komira_name_registry": komira_name_registry,
    "komira_parquet_api": komira_parquet_api,
    "komira_plan_proto": komira_plan_proto,
    "komira_proto_codec": komira_proto_codec,
    "komira_protobuf": komira_protobuf,
    "komira_resources": komira_resources,
    "komira_retry": komira_retry,
    "komira_rowcell": komira_rowcell,
    "komira_runtime_paths": komira_runtime_paths,
    "komira_scalar_arithmetic": komira_scalar_arithmetic,
    "komira_simd": komira_simd,
    "komira_snapshotter": komira_snapshotter,
    "komira_spsc_ring": komira_spsc_ring,
    "komira_supervisor_proto": komira_supervisor_proto,
    "komira_sync": komira_sync,
    "komira_test_run_id": komira_test_run_id,
    "komira_test_verdict": komira_test_verdict,
    "komira_textproto": komira_textproto,
    "komira_trace": komira_trace,
    "komira_validation_run": komira_validation_run,
    "komira_vcard": komira_vcard,
    "komira_wkt": komira_wkt,
    "komira_xml": komira_xml,
    "komira_zlib": komira_zlib,
}

NATIVE_IDS = {package: declared_natives(graph) for package, graph in _GRAPHS.items()}
