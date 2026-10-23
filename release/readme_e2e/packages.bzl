"""The packages of the release's README e2e: every `src/<name>` that has a `mopm.toml`, with its version.

`readme_e2e_complete` (the root BUCK) fails when this list and the files of the checkout disagree, in
either direction, so a package moved to mopm cannot be left out and a deleted one cannot linger. The
version is the one in the package's `mopm.toml`; `//release/readme_e2e:staged` fails when the package
built says another.
"""

# The compiler the packages are built for (`mojo` of each package's `mojo_conda`).
MOJO = "1.0.0"

# The pinned mopm the e2e installs with. It must have `mopm add --overlay`; one that lacks it fails every
# target of //release/readme_e2e/verify at its install step, naming the option. Bump it with the pins
# (`buildrules mojo sync`).
MOPM = "toolchains//:mopm_0_0_25"

PACKAGES = {
    "komira_anomaly": "0.1.0",
    "komira_datetime": "0.1.0",
    "komira_encoding": "0.1.0",
    "komira_hash": "0.1.0",
    "komira_json": "0.1.0",
    "komira_protobuf": "0.1.0",
    "komira_retry": "0.1.0",
    "komira_scalar_arithmetic": "0.1.0",
    "komira_simd": "0.1.0",
    "komira_textproto": "0.1.0",
    "komira_xml": "0.1.0",
}
