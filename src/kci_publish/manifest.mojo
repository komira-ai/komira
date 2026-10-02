# =============================================================================
# src/kci_publish/manifest.mojo -- the artifact manifest and the
#   approved-names file: the two inputs that say WHAT a run publishes.
# =============================================================================
#
# ─── THE ARTIFACT MANIFEST ──────────────────────────────────────────────────
# One JSON object per package file, written by the build that produced it:
#
#   {"artifact_type": "CONDA",            CONDA or PYTHON
#    "name": "example-pkg",               the package name
#    "version": "1.2.3",
#    "subdir": "linux-64",                CONDA only: the channel subdir
#    "file": "example-pkg-1.2.3-h0_0.conda",
#    "sha256": "<64 hex>",                the file's sha256, as built
#    "metadata": "METADATA"}              PYTHON only: the wheel's METADATA
#
# `file` and `metadata` are paths; a relative one is relative to the
# directory holding the manifest. Every key above is a string; a missing
# required key, a key that does not belong to the artifact type, an unknown
# key and a non-string value are each refused naming the manifest and the key.
#
# ─── THE APPROVED-NAMES FILE ────────────────────────────────────────────────
# One package name per line. Blank lines and lines starting `#` are ignored;
# surrounding whitespace is trimmed. An empty file approves nothing. The
# names are compared the way the registry compares them (`ApprovedNames`).
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from std.pathlib import Path

from komira_json import JSON_STRING, JsonValue, parse_json_value

from kci_pkg_upload import ApprovedNames
from kci_release_channel import ARTIFACT_TYPE_CONDA, ARTIFACT_TYPE_PYTHON


struct ArtifactManifest(Copyable, Movable, Deinitable):
    """One artifact, as its manifest states it. `file_path` and
    `metadata_path` are already resolved against the manifest's directory;
    `source` names the manifest in every refusal.

    Layout: owned Strings. No pointer field."""

    var source: String
    var artifact_type: String
    var name: String
    var version: String
    var subdir: String
    var file_path: String
    var sha256_hex: String
    var metadata_path: String

    def __init__(out self, var source: String):
        self.source = source^
        self.artifact_type = String("")
        self.name = String("")
        self.version = String("")
        self.subdir = String("")
        self.file_path = String("")
        self.sha256_hex = String("")
        self.metadata_path = String("")

    def file_name(self) -> String:
        """The last path segment of `file_path`: the name the registry sees."""
        var slash = self.file_path.rfind(String("/"))
        if slash < 0:
            return self.file_path.copy()
        return String(self.file_path[byte = slash + 1 :])


def _refuse(source: String, why: String) raises:
    raise Error(String("artifact manifest '") + source + String("': ") + why)


def _dir_of(path: String) -> String:
    var slash = path.rfind(String("/"))
    if slash < 0:
        return String("")
    return String(path[byte = : slash + 1])


def _resolve(base_dir: String, path: String) -> String:
    if path.startswith(String("/")) or base_dir.byte_length() == 0:
        return path.copy()
    return base_dir + path


def _is_hex64(s: String) -> Bool:
    var b = s.as_bytes()
    if len(b) != 64:
        return False
    for i in range(len(b)):
        var c = b[i]
        var digit = c >= UInt8(48) and c <= UInt8(57)
        var lower = c >= UInt8(97) and c <= UInt8(102)
        if not (digit or lower):
            return False
    return True


def _string_member(doc: JsonValue, key: String, source: String) raises -> String:
    var v = doc.get(key)
    if v.kind_tag() != JSON_STRING:
        _refuse(source, String("'") + key + String("' is not a string"))
    var s = v.as_string()
    if s.strip().byte_length() == 0:
        _refuse(source, String("'") + key + String("' is EMPTY"))
    return s^


def parse_artifact_manifest(text: String, source: String) raises -> ArtifactManifest:
    """Parse one manifest's text. `source` is the manifest's path: it names
    the manifest in refusals, and relative paths resolve against its
    directory."""
    var doc: JsonValue
    try:
        doc = parse_json_value(text)
    except e:
        _refuse(source, String("not JSON: ") + String(e))
        return ArtifactManifest(source.copy())
    if not doc.is_object():
        _refuse(source, String("not a JSON object"))
    var known = List[String]()
    known.append(String("artifact_type"))
    known.append(String("name"))
    known.append(String("version"))
    known.append(String("subdir"))
    known.append(String("file"))
    known.append(String("sha256"))
    known.append(String("metadata"))
    for i in range(doc.num_members()):
        var key = doc.key_at(i)
        var ok = False
        for j in range(len(known)):
            if known[j] == key:
                ok = True
        if not ok:
            _refuse(source, String("unknown key '") + key + String("'"))
    var m = ArtifactManifest(source.copy())
    var required = List[String]()
    required.append(String("artifact_type"))
    required.append(String("name"))
    required.append(String("version"))
    required.append(String("file"))
    required.append(String("sha256"))
    for i in range(len(required)):
        if not doc.has(required[i]):
            _refuse(source, String("missing '") + required[i] + String("'"))
    m.artifact_type = _string_member(doc, String("artifact_type"), source)
    m.name = _string_member(doc, String("name"), source)
    m.version = _string_member(doc, String("version"), source)
    var base = _dir_of(source)
    m.file_path = _resolve(base, _string_member(doc, String("file"), source))
    m.sha256_hex = _string_member(doc, String("sha256"), source)
    if not _is_hex64(m.sha256_hex):
        _refuse(source, String("'sha256' is not 64 lowercase hex characters"))
    if m.artifact_type == ARTIFACT_TYPE_CONDA:
        if not doc.has(String("subdir")):
            _refuse(source, String("a CONDA artifact needs 'subdir'"))
        if doc.has(String("metadata")):
            _refuse(source, String("'metadata' belongs to a PYTHON artifact"))
        m.subdir = _string_member(doc, String("subdir"), source)
        if m.subdir == "noarch":
            _refuse(
                source,
                String("subdir 'noarch' is not published: a compiled package")
                + String(" names its platform subdir"),
            )
    elif m.artifact_type == ARTIFACT_TYPE_PYTHON:
        if not doc.has(String("metadata")):
            _refuse(source, String("a PYTHON artifact needs 'metadata'"))
        if doc.has(String("subdir")):
            _refuse(source, String("'subdir' belongs to a CONDA artifact"))
        m.metadata_path = _resolve(
            base, _string_member(doc, String("metadata"), source)
        )
    else:
        _refuse(
            source,
            String("artifact_type '")
            + m.artifact_type
            + String("' is not published by kci publish (CONDA or PYTHON)"),
        )
    return m^


def read_artifact_manifest(path: String) raises -> ArtifactManifest:
    """Read and parse the manifest at `path`."""
    var text: String
    try:
        text = Path(path).read_text()
    except e:
        raise Error(
            String("artifact manifest '")
            + path
            + String("' cannot be read: ")
            + String(e)
        )
    return parse_artifact_manifest(text, path)


def parse_approved_names(text: String, source: String) raises -> ApprovedNames:
    """The approved-names file's text as an `ApprovedNames` (see the header).
    A refused name is reported with its line number."""
    var names = ApprovedNames()
    var lines = text.split(String("\n"))
    for i in range(len(lines)):
        var line = String(String(lines[i]).strip())
        if line.byte_length() == 0 or line.startswith(String("#")):
            continue
        try:
            names.approve(line^)
        except e:
            raise Error(
                String("approved-names file '")
                + source
                + String("': line ")
                + String(i + 1)
                + String(": ")
                + String(e)
            )
    return names^


def read_approved_names(path: String) raises -> ApprovedNames:
    var text: String
    try:
        text = Path(path).read_text()
    except e:
        raise Error(
            String("approved-names file '")
            + path
            + String("' cannot be read: ")
            + String(e)
        )
    return parse_approved_names(text, path)
