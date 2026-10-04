# =============================================================================
# src/kci_contract/layout.mojo -- the names of the files kci produces and the
#   layout of a release directory.
# =============================================================================
#
#   <release-dir>/<platform>/                 one platform's release
#   <release-dir>/<platform>/<name>/          one member: manifest.json, the
#                                             file, its metadata; nothing else
#   <release-dir>/<platform>/release.json     written LAST by the BUILD step
#
# `<release-dir>` is a flag (`--release-dir`) and has no default path.
#
# The machine file (the stage graph) is the ONE file kci finds by
# convention: `release/machine.textproto`, relative to the working
# directory, next to `release/artifacts.textproto` and
# `release/channels.textproto`. `kci run --machine <path>` overrides it.
# No other file (the result file, the release directory, a declaration, a
# channel file) has a default.
#
# A declaration's `{release_dir}` placeholder stands
# for `<release-dir>/<platform>`, so a declaration that reads an earlier
# member (`{release_dir}/komira_encoding/manifest.json`) is the same text on
# every platform.
#
# The names are spelled here only.
# Pure functions over owned values; no pointer, no file I/O.
# =============================================================================

comptime ARTIFACT_MANIFEST_NAME: String = "manifest.json"
"""The one artifact manifest at the top of a member's directory."""

comptime RELEASE_MANIFEST_NAME: String = "release.json"
"""The release manifest at the top of a platform's release directory."""

comptime DEFAULT_MACHINE_FILE: String = "release/machine.textproto"
"""The machine file `kci run` reads when `--machine` is not given (file
header): the one default path kci has."""


def _join(a: String, b: String) -> String:
    if a.endswith(String("/")):
        return a + b
    return a + String("/") + b


def _segment(what: String, s: String) raises:
    if (
        s.byte_length() == 0
        or s.find(String("/")) >= 0
        or s == "."
        or s == ".."
    ):
        raise Error(what + String(" '") + s + String("' is not one path segment"))


def release_platform_dir(release_dir: String, platform: String) raises -> String:
    """`<release-dir>/<platform>`: what `{release_dir}` stands for."""
    if release_dir.byte_length() == 0:
        raise Error(String("the release directory is EMPTY"))
    _segment(String("platform"), platform)
    return _join(release_dir, platform)


def member_dir(release_dir: String, platform: String, name: String) raises -> String:
    """`<release-dir>/<platform>/<name>`."""
    _segment(String("artifact name"), name)
    return _join(release_platform_dir(release_dir, platform), name)


def release_manifest_path(release_dir: String, platform: String) raises -> String:
    """`<release-dir>/<platform>/release.json`."""
    return _join(release_platform_dir(release_dir, platform), String(RELEASE_MANIFEST_NAME))
