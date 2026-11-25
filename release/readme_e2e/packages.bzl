"""The packages of the release's README e2e: every `src/<name>` that has a `mopm.toml`, with its version.

`readme_e2e_complete` (the root BUCK) fails when this list and the files of the checkout disagree, in
either direction, so a package moved to mopm cannot be left out and a deleted one cannot linger. The
version is the one in the package's `mopm.toml`; `//release/readme_e2e:staged` fails when the package
built says another.
"""

# The namespace of every package: a package `<name>` here is `komira-ai/<name>` to mopm (its full name),
# and its file is `mojo-komira-ai.<name>-<version>-<build>.conda`. Its import name is `<name>`.
NAMESPACE = "komira-ai"

# The compiler the packages are built for (`mojo` of each package's `mojo_conda`).
MOJO = "1.1.0"

# The pinned mopm the e2e installs with. It must have `mopm add --overlay`; one that lacks it fails every
# target of //release/readme_e2e/verify at its install step, naming the option. It is the mopm every package
# of the repository builds with (`mopm-toolchain.toml`), which buildrules pins for all three hosts.
MOPM = "toolchains//:mopm_0_0_138"

# The first mopm that has `mopm add --overlay`, as a label like MOPM, or None while no release
# has it. `readme_e2e_complete` (root BUCK) compares it with MOPM: the row of EXCLUDED in
# tools/build/ci/rules.bzl that leaves //release/readme_e2e/verify out of the pull request check
# must be present while MOPM is older than this (or this is None), and absent from this on. The
# row is gone: the e2e is part of the pull request check.
FIRST_MOPM_WITH_OVERLAY = "toolchains//:mopm_0_0_40"

PACKAGES = {
    "anomaly": "0.1.0",
    "async_api": "0.1.0",
    "atomic_alias": "0.1.0",
    "awslc": "0.1.0",
    "bench": "0.1.0",
    "bench_report": "0.1.0",
    "broker_proto": "0.1.0",
    "bump_arena": "0.1.0",
    "byte_buffer": "0.1.0",
    "calendar": "0.1.0",
    "calendar_ics": "0.1.0",
    "calendar_proto": "0.1.0",
    "chat_proto": "0.1.0",
    "clock": "0.1.0",
    "codeworks_api": "0.1.0",
    "compression": "0.1.0",
    "contacts_proto": "0.1.0",
    "containers": "0.1.0",
    "content_line": "0.1.0",
    "counters": "0.1.0",
    "crm_proto": "0.1.0",
    "crypto": "0.1.0",
    "datetime": "0.1.0",
    "dynamic_filter": "0.1.0",
    "encoding": "0.1.0",
    "fork_join": "0.1.0",
    "hashing": "0.1.0",
    "host_probe": "0.1.0",
    "job_report_proto": "0.1.0",
    "json": "0.1.0",
    "kafka_server": "0.1.0",
    "kg_mode": "0.1.0",
    "kg_spec": "0.1.0",
    "libc": "0.1.0",
    "log": "0.1.0",
    "lz4": "0.1.0",
    "mail_address": "0.1.0",
    "mail_message": "0.1.0",
    "managed_mail_proto": "0.1.0",
    "mcp_server": "0.1.0",
    "metrics": "0.1.0",
    "name_registry": "0.1.0",
    "parquet_api": "0.1.0",
    "plan_proto": "0.1.0",
    "proto_codec": "0.1.0",
    "protobuf": "0.1.0",
    "resources": "0.1.0",
    "retry": "0.1.0",
    "rowcell": "0.1.0",
    "runtime_paths": "0.1.0",
    "scalar_arithmetic": "0.1.0",
    "simd_ops": "0.1.0",
    "snapshotter": "0.1.0",
    "spsc_ring": "0.1.0",
    "supervisor_proto": "0.1.0",
    "sync": "0.1.0",
    "test_run_id": "0.1.0",
    "test_verdict": "0.1.0",
    "textproto": "0.1.0",
    "trace": "0.1.0",
    "uuid": "0.1.0",
    "validation_run": "0.1.0",
    "vcard": "0.1.0",
    "wkt": "0.1.0",
    "xml": "0.1.0",
    "zlib": "0.1.0",
}
