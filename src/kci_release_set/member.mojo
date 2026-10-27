# =============================================================================
# src/kci_release_set/member.mojo -- one artifact's directory of a release,
#   checked: what the BUILD step refuses as soon as a build finishes and what
#   the PUBLISH step re-checks over the bytes on disk. One function, so the two
#   cannot drift apart.
# =============================================================================
#
# `verify_member(artifact, dir)` refuses (RAISES, every message starting
# `artifact '<artifact>': `), in this order:
#
#   - `dir` is a symlink, or is not a directory;
#   - any top-level entry is a symlink (checked with lstat semantics, never
#     followed: a link can name bytes outside the release directory, and the
#     bare-name rule below exists so that nothing outside it can be named);
#   - its top level holds no `manifest.json` (kci_artifact's
#     `require_one_manifest`), or `manifest.json` is not a regular file; the
#     manifest does not parse (kci_artifact_manifest's
#     `read_artifact_manifest`);
#   - the manifest's `name` is not the artifact's, exactly
#     (`require_manifest_name`);
#   - `file` or `metadata` is not a bare name in `dir` (no `/`, not `.` or
#     `..`; the manifest format allows a relative path for `file`, the release
#     layout does not), or the two are the same name, or either is
#     `manifest.json`;
#   - the top level holds anything other than `manifest.json`, `file` and
#     `metadata` (the release directory is exactly what will ship), or `file`
#     or `metadata` is missing or is not a regular file (a symlink was
#     already refused above, so "regular file" holds for links too);
#   - `file` is a directory (only an OCI member's file is one), is EMPTY,
#     or its sha256 is not the manifest's;
#   - CONDA: `metadata` does not parse (`read_conda_metadata`), or disagrees
#     with the manifest (`name`, `version`, `subdir`, `file_name` = `file`), or
#     its `size` is not the file's, or it is not `stamped`.
#
# AN OCI MEMBER (an image) is the one type whose `file` is a DIRECTORY: its
# OCI image layout. Its manifest names no `metadata` (kci_artifact_manifest),
# so the top level holds exactly `manifest.json` and the layout. After the
# checks above that apply (the directory, the links, the one manifest, the
# name, `file` a bare name and not `manifest.json`, nothing else at the top
# level), it is refused when:
#
#   - the manifest's `platform` is `noarch` (an image is built for one
#     platform);
#   - `file` is missing, or is not a directory;
#   - anything inside the layout, at any depth, is a symlink (lstat
#     semantics, checked BEFORE any file of the layout is read, so a link is
#     never followed: as at the top level, it can name bytes outside the
#     release directory);
#   - the layout does not verify: komira_oci's `read_oci_layout`, which reads
#     `index.json` and the manifest and HASHES EVERY BLOB (config and layers)
#     against the digest that names it; one flipped byte of a layer refuses;
#   - the layout holds an entry its index and manifest do not reference: it
#     holds exactly `oci-layout`, `index.json`, the directories `blobs` and
#     `blobs/sha256`, and the blobs of the manifest, the config and the
#     layers (entries checked in bytewise order of their paths);
#   - the layout's image manifest digest is not `sha256:` + the manifest's
#     `sha256`. That ties the bytes on disk to the release set: the set hash
#     carries the manifest's `sha256` (set_hash.mojo), so a member that
#     verifies holds exactly the image the set names;
#   - the image's OCI platform (its config's `os/architecture[/variant]`) is
#     not the manifest platform's (kci_api's `oci_platform_of`).
#
# An OCI member's `size` is the sum of the byte lengths of the image
# manifest and of each DISTINCT blob it names (a layer listed twice is one
# file, counted once).
#
# PYTHON is accepted as the manifest parser accepts it; the PUBLISH step refuses
# to publish it.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from std.os import listdir
from std.os.path import exists, isdir, isfile, islink
from std.pathlib import Path

from komira_crypto import hex_lower_array_32, sha256

from kci_artifact import (
    KCI_MANIFEST_NAME,
    require_manifest_name,
    require_one_manifest,
)
from kci_artifact_manifest import ArtifactManifest, read_artifact_manifest
from kci_api import oci_platform_of, require_member_platform
from kci_release_channel import ARTIFACT_TYPE_CONDA, ARTIFACT_TYPE_OCI
from komira_oci import OciLayout, read_oci_layout

from kci_release_set.conda_metadata import CondaMetadata, read_conda_metadata
from kci_release_set.set_hash import sort_bytewise


struct ReleaseMember(Copyable, Movable):
    """One verified artifact directory. `dir_name` is the directory's last
    path segment (the artifact's name); `conda` is meaningful only when
    `has_conda` (a CONDA artifact); `size` is the file's size in bytes (for
    an OCI member, the image's: manifest, config and layers).

    Layout: owned values only. No pointer field."""

    var artifact: String
    var dir: String
    var manifest: ArtifactManifest
    var size: Int
    var has_conda: Bool
    var conda: CondaMetadata

    def __init__(
        out self,
        var artifact: String,
        var dir: String,
        var manifest: ArtifactManifest,
        size: Int,
    ):
        self.artifact = artifact^
        self.dir = dir^
        self.manifest = manifest^
        self.size = size
        self.has_conda = False
        self.conda = CondaMetadata(String(""))

    def build(self) -> String:
        """The conda build string; "" for an artifact with none (PYTHON)."""
        if self.has_conda:
            return self.conda.build.copy()
        return String("")

    def kind(self) -> String:
        """`library` / `metapackage` for CONDA; "" otherwise."""
        if self.has_conda:
            return self.conda.kind.copy()
        return String("")


def _refuse(artifact: String, why: String) raises:
    raise Error(String("artifact '") + artifact + String("': ") + why)


def _bare(artifact: String, key: String, value: String) raises:
    if value.find(String("/")) >= 0 or value == "." or value == "..":
        _refuse(
            artifact,
            String("the manifest's '")
            + key
            + String("' is '")
            + value
            + String("', not a file name in the artifact's directory"),
        )
    if value == KCI_MANIFEST_NAME:
        _refuse(
            artifact,
            String("the manifest's '") + key + String("' names the manifest itself"),
        )


def file_sha256_hex(path: String) raises -> String:
    """The sha256 of the file at `path`, as 64 lowercase hex characters."""
    var data = Path(path).read_bytes()
    return hex_lower_array_32(sha256(Span(data)))


def _no_trailing_slash(path: String) -> String:
    """`path` without trailing `/`s (but never emptied): `islink("l/")`
    resolves the link, `islink("l")` does not."""
    var b = path.as_bytes()
    var n = len(b)
    while n > 1 and b[n - 1] == UInt8(47):  # '/'
        n -= 1
    return String(path[byte = :n])


def verify_member(artifact: String, dir: String) raises -> ReleaseMember:
    """Check one artifact directory (file header); return what it holds."""
    if islink(_no_trailing_slash(dir)):
        _refuse(
            artifact,
            String("'")
            + dir
            + String("' is a symlink, not a directory: a link can name bytes outside the")
            + String(" release directory"),
        )
    if not isdir(dir):
        _refuse(artifact, String("'") + dir + String("' is not a directory"))
    var base = dir.copy()
    if not base.endswith(String("/")):
        base += String("/")
    var listing = List[String]()
    var raw = listdir(dir)
    for i in range(len(raw)):
        var entry = String(raw[i])
        if islink(base + entry):
            _refuse(
                artifact,
                String("the directory's '")
                + entry
                + String("' is a symlink: the directory holds regular files only, and a link")
                + String(" can name bytes outside the release directory"),
            )
        listing.append(entry^)
    require_one_manifest(artifact, listing)
    if not isfile(base + String(KCI_MANIFEST_NAME)):
        _refuse(
            artifact,
            String("its ") + String(KCI_MANIFEST_NAME) + String(" is not a regular file"),
        )
    var m = read_artifact_manifest(base + String(KCI_MANIFEST_NAME))
    require_manifest_name(artifact, m.name)
    _bare(artifact, String("file"), m.file)
    if m.artifact_type == ARTIFACT_TYPE_OCI:
        return _verify_image(artifact, dir, base, listing, m)
    _bare(artifact, String("metadata"), m.metadata)
    if m.file == m.metadata:
        _refuse(
            artifact,
            String("the manifest's 'file' and 'metadata' are the same name '")
            + m.file
            + String("'"),
        )
    for i in range(len(listing)):
        var entry = listing[i].copy()
        if entry != KCI_MANIFEST_NAME and entry != m.file and entry != m.metadata:
            _refuse(
                artifact,
                String("the directory holds '")
                + entry
                + String("', which its manifest does not name; it holds exactly ")
                + String(KCI_MANIFEST_NAME)
                + String(", the file and the metadata"),
            )
    var file_path = base + m.file
    var metadata_path = base + m.metadata
    # Every top-level entry was refused above if it was a symlink, so
    # `isfile` (which follows links) here means a regular file.
    if isdir(file_path):
        _refuse(
            artifact,
            String("its file '")
            + m.file
            + String("' is a directory: only an OCI member's file is a directory")
            + String(" (its image layout)"),
        )
    if not isfile(file_path):
        _refuse(artifact, String("its file '") + m.file + String("' is not in the directory"))
    if not isfile(metadata_path):
        _refuse(
            artifact,
            String("its metadata '") + m.metadata + String("' is not in the directory"),
        )
    var data = Path(file_path).read_bytes()
    var size = len(data)
    if size == 0:
        _refuse(artifact, String("its file '") + m.file + String("' is EMPTY"))
    var actual = hex_lower_array_32(sha256(Span(data)))
    if actual != m.sha256_hex:
        _refuse(
            artifact,
            String("the sha256 of '")
            + m.file
            + String("' is ")
            + actual
            + String(" but its manifest says ")
            + m.sha256_hex,
        )
    var member = ReleaseMember(artifact.copy(), dir.copy(), m.copy(), size)
    if m.artifact_type == ARTIFACT_TYPE_CONDA:
        var md: CondaMetadata
        try:
            md = read_conda_metadata(metadata_path)
        except e:
            _refuse(artifact, String(e))
            return member^
        _agree(artifact, String("name"), md.name, m.name)
        _agree(artifact, String("version"), md.version, m.version)
        _agree(artifact, String("subdir"), md.subdir, m.subdir)
        _agree(artifact, String("file_name"), md.file_name, m.file)
        if md.size != size:
            _refuse(
                artifact,
                String("its metadata says size ")
                + String(md.size)
                + String(" but '")
                + m.file
                + String("' is ")
                + String(size)
                + String(" bytes"),
            )
        if not md.stamped:
            _refuse(
                artifact,
                String("its metadata says stamped: false; an unstamped package is never released"),
            )
        member.has_conda = True
        member.conda = md^
    return member^


def _walk_layout(
    artifact: String, file: String, root: String, rel: String, mut entries: List[String]
) raises:
    """Every entry under `root/rel`, as paths relative to `root` (a
    directory's path ends in `/`), refusing a symlink before anything is
    read through it."""
    var here = root + rel
    var names = listdir(here)
    for i in range(len(names)):
        var path = rel + String(names[i])
        if islink(root + path):
            _refuse(
                artifact,
                String("its image layout '")
                + file
                + String("' holds a symlink at '")
                + path
                + String("': a link can name bytes outside the release directory"),
            )
        if isdir(root + path):
            entries.append(path + String("/"))
            _walk_layout(artifact, file, root, path + String("/"), entries)
        else:
            entries.append(path.copy())


def _blob_entry(digest: String) -> String:
    """`blobs/<algorithm>/<hex>`: where a layout keeps the blob `digest`."""
    return String("blobs/") + digest.replace(String(":"), String("/"))


def _verify_image(
    artifact: String, dir: String, base: String, listing: List[String], m: ArtifactManifest
) raises -> ReleaseMember:
    """The OCI arm of `verify_member` (file header): `listing` is the
    directory's top level, every entry already checked not to be a link."""
    for i in range(len(listing)):
        ref entry = listing[i]
        if entry != KCI_MANIFEST_NAME and entry != m.file:
            _refuse(
                artifact,
                String("the directory holds '")
                + entry
                + String("', which its manifest does not name; an OCI member holds exactly ")
                + String(KCI_MANIFEST_NAME)
                + String(" and the image layout"),
            )
    if m.platform == "noarch":
        _refuse(
            artifact,
            String("an OCI member's platform is 'noarch': an image is built for one platform"),
        )
    var want_platform = oci_platform_of(m.platform)
    var layout_dir = base + m.file
    if not exists(layout_dir):
        _refuse(artifact, String("its file '") + m.file + String("' is not in the directory"))
    if not isdir(layout_dir):
        _refuse(
            artifact,
            String("its file '")
            + m.file
            + String("' is not a directory: an OCI member's file is its image layout"),
        )
    var entries = List[String]()
    _walk_layout(artifact, m.file, layout_dir + String("/"), String(""), entries)
    var layout: OciLayout
    try:
        layout = read_oci_layout(layout_dir)
    except e:
        _refuse(
            artifact,
            String("its image layout '") + m.file + String("' does not verify: ") + String(e),
        )
        return ReleaseMember(artifact.copy(), dir.copy(), m.copy(), 0)
    var known = List[String]()
    known.append(String("oci-layout"))
    known.append(String("index.json"))
    known.append(String("blobs/"))
    known.append(String("blobs/sha256/"))
    known.append(_blob_entry(layout.manifest_digest))
    known.append(_blob_entry(layout.config.digest))
    for i in range(len(layout.layers)):
        known.append(_blob_entry(layout.layers[i].digest))
    sort_bytewise(entries)
    for i in range(len(entries)):
        var referenced = False
        for j in range(len(known)):
            if known[j] == entries[i]:
                referenced = True
        if not referenced:
            _refuse(
                artifact,
                String("its image layout '")
                + m.file
                + String("' holds '")
                + entries[i]
                + String("', which its index and manifest do not reference"),
            )
    var named = String("sha256:") + m.sha256_hex
    if layout.manifest_digest != named:
        _refuse(
            artifact,
            String("the image manifest digest of '")
            + m.file
            + String("' is ")
            + layout.manifest_digest
            + String(" but its manifest says ")
            + named,
        )
    if layout.platform() != want_platform:
        _refuse(
            artifact,
            String("its image layout '")
            + m.file
            + String("' is for ")
            + layout.platform()
            + String(" but its manifest says platform ")
            + m.platform
            + String(" (")
            + want_platform
            + String(")"),
        )
    # Each distinct blob once: an image may list one layer twice.
    var counted = List[String]()
    var size = len(layout.manifest_raw)
    var blobs = layout.layers.copy()
    blobs.append(layout.config.copy())
    for i in range(len(blobs)):
        var seen = False
        for j in range(len(counted)):
            if counted[j] == blobs[i].digest:
                seen = True
        if not seen:
            counted.append(blobs[i].digest.copy())
            size += blobs[i].size
    return ReleaseMember(artifact.copy(), dir.copy(), m.copy(), size)


def member_platform(member: ReleaseMember, release_platform: String) raises -> String:
    """The platform a verified member is for: its manifest's `platform`
    (kci_artifact_manifest checked it against the platform table, and a
    CONDA manifest's `subdir` against that platform's conda subdir). Refused:
    a platform that is neither the release's nor `noarch`."""
    var p = member.manifest.platform.copy()
    try:
        require_member_platform(release_platform, p)
    except e:
        _refuse(member.artifact, String(e))
    return p^


def _agree(artifact: String, key: String, metadata_value: String, manifest_value: String) raises:
    if metadata_value != manifest_value:
        _refuse(
            artifact,
            String("its metadata says ")
            + key
            + String(" '")
            + metadata_value
            + String("' but its manifest says '")
            + manifest_value
            + String("'"),
        )
