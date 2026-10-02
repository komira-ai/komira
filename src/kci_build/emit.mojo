# =============================================================================
# src/kci_build/emit.mojo -- check every built package against its manifest,
#   then copy the set into `--out-dir` with the manifests `kci publish` reads.
# =============================================================================
#
# VERIFY, for every target, before anything is copied (REFUSED otherwise):
#   - the `[manifest]` output parses as an artifact manifest
#     (kci_artifact_manifest);
#   - its `artifact_type` is the one the publishable list gives the target;
#   - its `file` names the target's default output (same file name: that is
#     the name the registry will see);
#   - the default output is a non-empty file whose sha256 is the manifest's;
#   - no two targets claim one (artifact_type, name, version, subdir).
#
# EMIT: `--out-dir` must be absent or empty, so no package from an earlier
# run can ride along. Each package is copied to `<out_dir>/<subdir>/<file>`,
# the copy is hashed again, and its manifest is written as
# `<out_dir>/<name>-<version>-<subdir>.json` with `file` relative to it.
# `BUILD_SUMMARY.txt` lists what was written; it is for people, nothing
# reads it.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from std.os import listdir, makedirs
from std.os.path import exists, isdir, isfile
from std.pathlib import Path

from komira_crypto import hex_lower_array_32, sha256

from kci_artifact_manifest import (
    ArtifactManifest,
    read_artifact_manifest,
    render_artifact_manifest,
)

from kci_build.allowlist import PublishableEntry
from kci_build.report import TargetResult
from kci_build.request import EXIT_FAILED, EXIT_OK, EXIT_REFUSED, BuildOutcome


def _base_name(path: String) -> String:
    var slash = path.rfind(String("/"))
    if slash < 0:
        return path.copy()
    return String(path[byte = slash + 1 :])


def file_sha256_hex(path: String) raises -> String:
    """The sha256 of the file at `path`, as 64 lowercase hex characters."""
    var data = Path(path).read_bytes()
    return hex_lower_array_32(sha256(Span(data)))


def _refused(target: String, why: String) -> BuildOutcome:
    return BuildOutcome(EXIT_REFUSED, String("kci build: ") + target + String(": ") + why)


struct VerifiedArtifact(Copyable, Movable):
    """A built package that matched its manifest.

    Layout: owned values only. No pointer field."""

    var target: String
    var package_path: String
    var manifest: ArtifactManifest

    def __init__(out self, var target: String, var package_path: String, var manifest: ArtifactManifest):
        self.target = target^
        self.package_path = package_path^
        self.manifest = manifest^


def verify_artifacts(
    entries: List[PublishableEntry],
    results: List[TargetResult],
    mut verified: List[VerifiedArtifact],
) raises -> BuildOutcome:
    """VERIFY (file header). `results` is in `entries` order, each with one
    default and one manifest output."""
    for i in range(len(entries)):
        ref entry = entries[i]
        ref tr = results[i]
        var package = tr.default_outputs[0].copy()
        var m: ArtifactManifest
        try:
            m = read_artifact_manifest(tr.sub_outputs[0])
        except e:
            return _refused(entry.target, String(e))
        if m.artifact_type != entry.artifact_type:
            return _refused(
                entry.target,
                String("its manifest says artifact_type '")
                + m.artifact_type
                + String("' but the publishable list says '")
                + entry.artifact_type
                + String("'"),
            )
        if m.file_name() != _base_name(package):
            return _refused(
                entry.target,
                String("its manifest names file '")
                + m.file_name()
                + String("' but the target built '")
                + _base_name(package)
                + String("'"),
            )
        if not isfile(package):
            return _refused(entry.target, String("its package '") + package + String("' is not a file"))
        var data = Path(package).read_bytes()
        if len(data) == 0:
            return _refused(entry.target, String("its package '") + package + String("' is EMPTY"))
        var actual = hex_lower_array_32(sha256(Span(data)))
        if actual != m.sha256_hex:
            return _refused(
                entry.target,
                String("sha256 of '")
                + package
                + String("' is ")
                + actual
                + String(" but its manifest says ")
                + m.sha256_hex,
            )
        for j in range(len(verified)):
            ref other = verified[j].manifest
            if (
                other.artifact_type == m.artifact_type
                and other.name == m.name
                and other.version == m.version
                and other.subdir == m.subdir
            ):
                return _refused(
                    entry.target,
                    String("builds ")
                    + m.artifact_type
                    + String(" ")
                    + m.name
                    + String(" ")
                    + m.version
                    + String(" for ")
                    + m.subdir
                    + String(", as ")
                    + verified[j].target
                    + String(" already does"),
                )
        verified.append(VerifiedArtifact(entry.target.copy(), package^, m^))
    return BuildOutcome(EXIT_OK, String(""))


def check_out_dir(out_dir: String) raises -> BuildOutcome:
    """REFUSED unless `out_dir` is absent or an empty directory."""
    if not exists(out_dir):
        return BuildOutcome(EXIT_OK, String(""))
    if not isdir(out_dir):
        return BuildOutcome(
            EXIT_REFUSED, String("kci build: --out-dir '") + out_dir + String("' is not a directory")
        )
    if len(listdir(out_dir)) > 0:
        return BuildOutcome(
            EXIT_REFUSED,
            String("kci build: --out-dir '")
            + out_dir
            + String("' is not empty: a package from an earlier run could ride along"),
        )
    return BuildOutcome(EXIT_OK, String(""))


def emit_artifacts(out_dir: String, verified: List[VerifiedArtifact]) raises -> BuildOutcome:
    """EMIT (file header). On OK, `manifests` lists the manifests written."""
    var gate = check_out_dir(out_dir)
    if not gate.ok():
        return gate^
    makedirs(out_dir, exist_ok=True)
    var outcome = BuildOutcome(EXIT_OK, String(""))
    var summary = String("")
    for i in range(len(verified)):
        ref v = verified[i]
        var m = v.manifest.copy()
        var rel = m.subdir + String("/") + m.file_name()
        var dest = out_dir + String("/") + rel
        if exists(dest):
            return _refused(v.target, String("'") + dest + String("' is already written by another target"))
        makedirs(out_dir + String("/") + m.subdir, exist_ok=True)
        var data = Path(v.package_path).read_bytes()
        var f = open(dest, "w")
        f.write_bytes(Span(data))
        f.close()
        var copied = file_sha256_hex(dest)
        if copied != m.sha256_hex:
            return BuildOutcome(
                EXIT_FAILED,
                String("kci build: the copy '")
                + dest
                + String("' hashes to ")
                + copied
                + String(", not ")
                + m.sha256_hex,
            )
        var manifest_path = (
            out_dir + String("/") + m.name + String("-") + m.version + String("-") + m.subdir + String(".json")
        )
        m.source = manifest_path.copy()
        m.file = rel.copy()
        m.file_path = dest.copy()
        var text = render_artifact_manifest(m)
        var mf = open(manifest_path, "w")
        mf.write_bytes(text.as_bytes())
        mf.close()
        outcome.manifests.append(manifest_path.copy())
        summary += (
            m.artifact_type
            + String(" ")
            + v.target
            + String(" -> ")
            + rel
            + String(" sha256 ")
            + m.sha256_hex
            + String("\n")
        )
    var sf = open(out_dir + String("/BUILD_SUMMARY.txt"), "w")
    sf.write_bytes(summary.as_bytes())
    sf.close()
    return outcome^
