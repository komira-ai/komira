"""The packages of the release's README e2e: every `src/<name>` that has a `mopm.toml`, with its version.

`readme_e2e_complete` (the root BUCK) fails when this list and the files of the checkout disagree, in
either direction, so a package moved to mopm cannot be left out and a deleted one cannot linger. The
version is the one in the package's `mopm.toml`; `//release/readme_e2e:staged` fails when the package
built says another.
"""

# The compiler the packages are built for (`mojo` of each package's `mojo_conda`).
MOJO = "1.0.0"

# The pinned mopm the e2e installs with. It must have `mopm add --overlay`; one that lacks it fails every
# target of //release/readme_e2e/verify at its install step, naming the option. It is a row of
# buildrules' own pins (rules/mopm/pins.bzl), so buildrules-pins.toml holds no row for it.
MOPM = "toolchains//:mopm_0_0_73"

# The first mopm that has `mopm add --overlay`, as a label like MOPM, or None while no release
# has it. `readme_e2e_complete` (root BUCK) compares it with MOPM: the row of EXCLUDED in
# tools/build/ci/rules.bzl that leaves //release/readme_e2e/verify out of the pull request check
# must be present while MOPM is older than this (or this is None), and absent from this on. The
# row is gone: the e2e is part of the pull request check.
FIRST_MOPM_WITH_OVERLAY = "toolchains//:mopm_0_0_40"

PACKAGES = {
    "anomaly": "0.1.0",
    "atomic_alias": "0.1.0",
    "content_line": "0.1.0",
    "datetime": "0.1.0",
    "encoding": "0.1.0",
    "hashing": "0.1.0",
    "host_probe": "0.1.0",
    "json": "0.1.0",
    "kafka_server": "0.1.0",
    "libc": "0.1.0",
    "lz4": "0.1.0",
    "mail_address": "0.1.0",
    "parquet_api": "0.1.0",
    "protobuf": "0.1.0",
    "retry": "0.1.0",
    "rowcell": "0.1.0",
    "runtime_paths": "0.1.0",
    "scalar_arithmetic": "0.1.0",
    "simd_ops": "0.1.0",
    "test_verdict": "0.1.0",
    "textproto": "0.1.0",
    "validation_run": "0.1.0",
    "xml": "0.1.0",
    "zlib": "0.1.0",
}
