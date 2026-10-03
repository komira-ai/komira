# =============================================================================
# src/kci_release_set/member.mojo -- one artifact's directory of a release,
#   checked: what `kci build` refuses as soon as a build finishes and what
#   `kci publish` re-checks over the bytes on disk. One function, so the two
#   cannot drift apart.
# =============================================================================
#
# `verify_member(declaration, dir)` refuses (RAISES, every message starting
# `artifact '<declaration>': `), in this order:
#
#   - `dir` is a symlink, or is not a directory;
#   - any top-level entry is a symlink (checked with lstat semantics, never
#     followed: a link can name bytes outside the release directory, and the
#     bare-name rule below exists so that nothing outside it can be named);
#   - its top level holds no `manifest.json` (kci_artifact_declaration's
#     `require_one_manifest`), or `manifest.json` is not a regular file; the
#     manifest does not parse (kci_artifact_manifest's
#     `read_artifact_manifest`);
#   - the manifest's `name` is not the declaration's, exactly
#     (`require_manifest_name`);
#   - `file` or `metadata` is not a bare name in `dir` (no `/`, not `.` or
#     `..`; the manifest format allows a relative path for `file`, the release
#     layout does not), or the two are the same name, or either is
#     `manifest.json`;
#   - the top level holds anything other than `manifest.json`, `file` and
#     `metadata` (the release directory is exactly what will ship), or `file`
#     or `metadata` is missing or is not a regular file (a symlink was
#     already refused above, so "regular file" holds for links too);
#   - `file` is EMPTY, or its sha256 is not the manifest's;
#   - CONDA: `metadata` does not parse (`read_conda_metadata`), or disagrees
#     with the manifest (`name`, `version`, `subdir`, `file_name` = `file`), or
#     its `size` is not the file's, or it is not `stamped`.
#
# PYTHON is accepted as the manifest parser accepts it; `kci publish` refuses
# to publish it.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from std.os import listdir
from std.os.path import isdir, isfile, islink
from std.pathlib import Path

from komira_crypto import hex_lower_array_32, sha256

from kci_artifact_declaration import (
    KCI_MANIFEST_NAME,
    require_manifest_name,
    require_one_manifest,
)
from kci_artifact_manifest import ArtifactManifest, read_artifact_manifest
from kci_contract import require_member_platform
from kci_release_channel import ARTIFACT_TYPE_CONDA

from kci_release_set.conda_metadata import CondaMetadata, read_conda_metadata


struct ReleaseMember(Copyable, Movable):
    """One verified artifact directory. `dir_name` is the directory's last
    path segment (the declaration's name); `conda` is meaningful only when
    `has_conda` (a CONDA artifact); `size` is the file's size in bytes.

    Layout: owned values only. No pointer field."""

    var declaration: String
    var dir: String
    var manifest: ArtifactManifest
    var size: Int
    var has_conda: Bool
    var conda: CondaMetadata

    def __init__(
        out self,
        var declaration: String,
        var dir: String,
        var manifest: ArtifactManifest,
        size: Int,
    ):
        self.declaration = declaration^
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


def _refuse(declaration: String, why: String) raises:
    raise Error(String("artifact '") + declaration + String("': ") + why)


def _bare(declaration: String, key: String, value: String) raises:
    if value.find(String("/")) >= 0 or value == "." or value == "..":
        _refuse(
            declaration,
            String("the manifest's '")
            + key
            + String("' is '")
            + value
            + String("', not a file name in the artifact's directory"),
        )
    if value == KCI_MANIFEST_NAME:
        _refuse(
            declaration,
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


def verify_member(declaration: String, dir: String) raises -> ReleaseMember:
    """Check one artifact directory (file header); return what it holds."""
    if islink(_no_trailing_slash(dir)):
        _refuse(
            declaration,
            String("'")
            + dir
            + String("' is a symlink, not a directory: a link can name bytes outside the")
            + String(" release directory"),
        )
    if not isdir(dir):
        _refuse(declaration, String("'") + dir + String("' is not a directory"))
    var base = dir.copy()
    if not base.endswith(String("/")):
        base += String("/")
    var listing = List[String]()
    var raw = listdir(dir)
    for i in range(len(raw)):
        var entry = String(raw[i])
        if islink(base + entry):
            _refuse(
                declaration,
                String("the directory's '")
                + entry
                + String("' is a symlink: the directory holds regular files only, and a link")
                + String(" can name bytes outside the release directory"),
            )
        listing.append(entry^)
    require_one_manifest(declaration, listing)
    if not isfile(base + String(KCI_MANIFEST_NAME)):
        _refuse(
            declaration,
            String("its ") + String(KCI_MANIFEST_NAME) + String(" is not a regular file"),
        )
    var m = read_artifact_manifest(base + String(KCI_MANIFEST_NAME))
    require_manifest_name(declaration, m.name)
    _bare(declaration, String("file"), m.file)
    _bare(declaration, String("metadata"), m.metadata)
    if m.file == m.metadata:
        _refuse(
            declaration,
            String("the manifest's 'file' and 'metadata' are the same name '")
            + m.file
            + String("'"),
        )
    for i in range(len(listing)):
        var entry = listing[i].copy()
        if entry != KCI_MANIFEST_NAME and entry != m.file and entry != m.metadata:
            _refuse(
                declaration,
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
    if not isfile(file_path):
        _refuse(declaration, String("its file '") + m.file + String("' is not in the directory"))
    if not isfile(metadata_path):
        _refuse(
            declaration,
            String("its metadata '") + m.metadata + String("' is not in the directory"),
        )
    var data = Path(file_path).read_bytes()
    var size = len(data)
    if size == 0:
        _refuse(declaration, String("its file '") + m.file + String("' is EMPTY"))
    var actual = hex_lower_array_32(sha256(Span(data)))
    if actual != m.sha256_hex:
        _refuse(
            declaration,
            String("the sha256 of '")
            + m.file
            + String("' is ")
            + actual
            + String(" but its manifest says ")
            + m.sha256_hex,
        )
    var member = ReleaseMember(declaration.copy(), dir.copy(), m.copy(), size)
    if m.artifact_type == ARTIFACT_TYPE_CONDA:
        var md: CondaMetadata
        try:
            md = read_conda_metadata(metadata_path)
        except e:
            _refuse(declaration, String(e))
            return member^
        _agree(declaration, String("name"), md.name, m.name)
        _agree(declaration, String("version"), md.version, m.version)
        _agree(declaration, String("subdir"), md.subdir, m.subdir)
        _agree(declaration, String("file_name"), md.file_name, m.file)
        if md.size != size:
            _refuse(
                declaration,
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
                declaration,
                String("its metadata says stamped: false; an unstamped package is never released"),
            )
        member.has_conda = True
        member.conda = md^
    return member^


def member_platform(member: ReleaseMember, release_platform: String) raises -> String:
    """The platform a verified member is for: its manifest's `platform`
    (kci_artifact_manifest checked it against the platform table, and a
    CONDA manifest's `subdir` against that platform's conda subdir). Refused:
    a platform that is neither the release's nor `noarch`."""
    var p = member.manifest.platform.copy()
    try:
        require_member_platform(release_platform, p)
    except e:
        _refuse(member.declaration, String(e))
    return p^


def _agree(declaration: String, key: String, metadata_value: String, manifest_value: String) raises:
    if metadata_value != manifest_value:
        _refuse(
            declaration,
            String("its metadata says ")
            + key
            + String(" '")
            + metadata_value
            + String("' but its manifest says '")
            + manifest_value
            + String("'"),
        )
