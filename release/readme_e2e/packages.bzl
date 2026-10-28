"""The packages of the release's README e2e: every `src/<name>` that has a `mopm.toml`, with its version.

`readme_e2e_complete` (the root BUCK) fails when this list and the files of the checkout disagree, in
either direction, so a package moved to mopm cannot be left out and a deleted one cannot linger. The
version is the one in the package's `mopm.toml`; `//release/readme_e2e:staged` fails when the package
built says another.
"""

# The compiler the packages are built for (`mojo` of each package's `mojo_conda`).
MOJO = "1.0.0"

# The pinned mopm the e2e installs with. It must have `mopm add --overlay`; one that lacks it fails every
# target of //release/readme_e2e/verify at its install step, naming the option. buildrules does not pin
# it yet, so it is the `[mopm."0.0.81"]` row of buildrules-pins.toml (linux x86_64 only).
MOPM = "toolchains//:mopm_0_0_81"

# The first mopm that has `mopm add --overlay`, as a label like MOPM, or None while no release
# has it. `readme_e2e_complete` (root BUCK) compares it with MOPM: the row of EXCLUDED in
# tools/build/ci/rules.bzl that leaves //release/readme_e2e/verify out of the pull request check
# must be present while MOPM is older than this (or this is None), and absent from this on. The
# row is gone: the e2e is part of the pull request check.
FIRST_MOPM_WITH_OVERLAY = "toolchains//:mopm_0_0_40"

PACKAGES = {
    "komira_anomaly": "0.1.0",
    "komira_async_api": "0.1.0",
    "komira_atomic_alias": "0.1.0",
    "komira_bench_report": "0.1.0",
    "komira_buffer": "0.1.0",
    "komira_bump_arena": "0.1.0",
    "komira_clock": "0.1.0",
    "komira_collections": "0.1.0",
    "komira_content_line": "0.1.0",
    "komira_counters": "0.1.0",
    "komira_datetime": "0.1.0",
    "komira_dynamic_filter": "0.1.0",
    "komira_encoding": "0.1.0",
    "komira_fork_join": "0.1.0",
    "komira_hash": "0.1.0",
    "komira_host": "0.1.0",
    "komira_json": "0.1.0",
    "komira_kafka_server": "0.1.0",
    "komira_kg_mode": "0.1.0",
    "komira_kg_spec": "0.1.0",
    "komira_libc": "0.1.0",
    "komira_lz4": "0.1.0",
    "komira_mail_address": "0.1.0",
    "komira_mail_message": "0.1.0",
    "komira_mcp_server": "0.1.0",
    "komira_metrics": "0.1.0",
    "komira_name_registry": "0.1.0",
    "komira_parquet_api": "0.1.0",
    "komira_proto_codec": "0.1.0",
    "komira_protobuf": "0.1.0",
    "komira_resources": "0.1.0",
    "komira_retry": "0.1.0",
    "komira_rowcell": "0.1.0",
    "komira_runtime_paths": "0.1.0",
    "komira_scalar_arithmetic": "0.1.0",
    "komira_simd": "0.1.0",
    "komira_snapshotter": "0.1.0",
    "komira_spsc_ring": "0.1.0",
    "komira_sync": "0.1.0",
    "komira_test_run_id": "0.1.0",
    "komira_test_verdict": "0.1.0",
    "komira_textproto": "0.1.0",
    "komira_trace": "0.1.0",
    "komira_validation_run": "0.1.0",
    "komira_vcard": "0.1.0",
    "komira_wkt": "0.1.0",
    "komira_xml": "0.1.0",
    "komira_zlib": "0.1.0",
}
