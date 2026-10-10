# =============================================================================
# src/kci_artifact_manifest/manifest.mojo -- the artifact manifest: one JSON
#   object per package file, saying what the file is and what it hashes to.
# =============================================================================
#
#   {"format": "kci.artifact_manifest",  the format (kci_api's table)
#    "schema_version": 1,                 its major (an integer)
#    "artifact_type": "CONDA",            CONDA or PYTHON
#    "name": "example-pkg",               the package name
#    "version": "1.2.3",
#    "platform": "linux-x86_64",          kci_api's platform table
#    "subdir": "linux-64",                CONDA only: the channel subdir,
#                                         the platform's conda subdir
#    "file": "linux-64/example-pkg-1.2.3-h0_0.conda",
#    "sha256": "<64 hex>",                the file's sha256, as built
#    "metadata": "METADATA"}              PYTHON: the wheel's METADATA
#                                         CONDA: the build's metadata.json
#
# `format` and `schema_version` are read first (kci_api's
# `produced_header`): another format, or a major this kci does not read, is
# refused. Inside major 1 an unknown key is IGNORED and listed in
# `ignored_keys` (kci_api's policy: writers only ever add keys inside a
# major). `platform` is the platform the artifact was built for: a released
# one or `noarch`; a CONDA artifact's `subdir` must be its platform's conda
# subdir. Nothing run-specific (a run id, an attempt) is ever in a manifest:
# the package build writes it inside a cached build action, and a per-run
# value would make every run a cache miss and the bytes differ per run.
#
# `metadata` is required for both artifact types. `file` and `metadata` are
# paths; a relative one is relative to the directory holding the manifest.
# A CONDA `metadata` is a bare file name: the file sits next to the
# manifest, so copying the manifest's directory (as the BUILD step does)
# cannot separate the two. Every value but `schema_version` is a string. A
# missing required key, a key given twice, a key that does not belong to the
# artifact type, a non-string or empty value and a sha256 that is not 64
# lowercase hex characters are each refused, naming the manifest and the key.
#
# `render_artifact_manifest` writes the same format back, keys in the order
# above, so what the BUILD step writes is exactly what the PUBLISH step reads.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from std.pathlib import Path

from komira_json import JSON_STRING, JsonValue, parse_json_value

from kci_api import (
    FORMAT_ARTIFACT_MANIFEST,
    conda_subdir_of,
    current_major,
    produced_header,
    require_artifact_platform,
)
from kci_release_channel import ARTIFACT_TYPE_CONDA, ARTIFACT_TYPE_PYTHON


struct ArtifactManifest(Copyable, Movable, Deinitable):
    """One artifact, as its manifest states it.

    `file` and `metadata` are the paths as written in the manifest;
    `file_path` and `metadata_path` are the same paths resolved against the
    manifest's directory. `source` names the manifest in every refusal.

    Layout: owned Strings. No pointer field."""

    var source: String
    var artifact_type: String
    var name: String
    var version: String
    var platform: String
    var subdir: String
    var file: String
    var file_path: String
    var sha256_hex: String
    var metadata: String
    var metadata_path: String
    # Set by the parser only: keys of a known major it ignored (file header).
    var ignored_keys: List[String]

    def __init__(out self, var source: String):
        self.source = source^
        self.artifact_type = String("")
        self.name = String("")
        self.version = String("")
        self.platform = String("")
        self.subdir = String("")
        self.file = String("")
        self.file_path = String("")
        self.sha256_hex = String("")
        self.metadata = String("")
        self.metadata_path = String("")
        self.ignored_keys = List[String]()

    def file_name(self) -> String:
        """The last path segment of `file_path`: the name the registry sees.

        It is read from `file_path`, the path whose bytes get uploaded, and
        not from `file`, so the name and the bytes cannot come from two
        different fields. A parsed manifest and the BUILD step set both, and
        both give the same last segment; a caller that builds a manifest by
        hand and sets only `file_path` still gets the right name."""
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


def is_sha256_hex(s: String) -> Bool:
    """True iff `s` is 64 lowercase hex characters."""
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


def _known_keys() -> List[String]:
    var known = List[String]()
    known.append(String("format"))
    known.append(String("schema_version"))
    known.append(String("artifact_type"))
    known.append(String("name"))
    known.append(String("version"))
    known.append(String("platform"))
    known.append(String("subdir"))
    known.append(String("file"))
    known.append(String("sha256"))
    known.append(String("metadata"))
    return known^


def parse_artifact_manifest(text: String, source: String) raises -> ArtifactManifest:
    """Parse one manifest's text. `source` is the manifest's path: it names
    the manifest in refusals, and relative paths resolve against its
    directory."""
    var doc: JsonValue
    try:
        doc = parse_json_value(text)
    except e:
        _refuse(source, String("not JSON: ") + String(e))
        return ArtifactManifest(source.copy())  # cov: unreachable _refuse above always raises
    if not doc.is_object():
        _refuse(source, String("not a JSON object"))
    for i in range(doc.num_members()):
        var key = doc.key_at(i)
        for j in range(i):
            if doc.key_at(j) == key:
                _refuse(source, String("'") + key + String("' is given twice"))
    # produced_header's refusals start "<its source>: ", so it is given this
    # file's refusal prefix as its source.
    _ = produced_header(
        doc, String(FORMAT_ARTIFACT_MANIFEST), String("artifact manifest '") + source + String("'")
    )
    var m = ArtifactManifest(source.copy())
    var known = _known_keys()
    for i in range(doc.num_members()):
        var key = doc.key_at(i)
        var ok = False
        for j in range(len(known)):
            if known[j] == key:
                ok = True
        if not ok:
            m.ignored_keys.append(key^)
    var required = List[String]()
    required.append(String("artifact_type"))
    required.append(String("name"))
    required.append(String("version"))
    required.append(String("platform"))
    required.append(String("file"))
    required.append(String("sha256"))
    for i in range(len(required)):
        if not doc.has(required[i]):
            _refuse(source, String("missing '") + required[i] + String("'"))
    m.artifact_type = _string_member(doc, String("artifact_type"), source)
    m.name = _string_member(doc, String("name"), source)
    m.version = _string_member(doc, String("version"), source)
    m.platform = _string_member(doc, String("platform"), source)
    try:
        require_artifact_platform(m.platform)
    except e:
        _refuse(source, String(e))
    var base = _dir_of(source)
    m.file = _string_member(doc, String("file"), source)
    m.file_path = _resolve(base, m.file)
    m.sha256_hex = _string_member(doc, String("sha256"), source)
    if not is_sha256_hex(m.sha256_hex):
        _refuse(source, String("'sha256' is not 64 lowercase hex characters"))
    if m.artifact_type == ARTIFACT_TYPE_CONDA:
        if not doc.has(String("subdir")):
            _refuse(source, String("a CONDA artifact needs 'subdir'"))
        if not doc.has(String("metadata")):
            _refuse(source, String("a CONDA artifact needs 'metadata'"))
        m.metadata = _string_member(doc, String("metadata"), source)
        if (
            m.metadata.find(String("/")) >= 0
            or m.metadata == "."
            or m.metadata == ".."
        ):
            _refuse(
                source,
                String("a CONDA 'metadata' is a file name next to the")
                + String(" manifest, not a path"),
            )
        m.metadata_path = _resolve(base, m.metadata)
        m.subdir = _string_member(doc, String("subdir"), source)
        if m.subdir == "noarch":
            _refuse(
                source,
                String("subdir 'noarch' is not published: a compiled package")
                + String(" names its platform subdir"),
            )
        var want = conda_subdir_of(m.platform)
        if m.subdir != want:
            _refuse(
                source,
                String("subdir '") + m.subdir + String("' is not platform ") + m.platform
                + String("'s conda subdir '") + want + String("'"),
            )
        if not m.file_name().endswith(String(".conda")):
            _refuse(source, String("a CONDA 'file' must end in .conda"))
    elif m.artifact_type == ARTIFACT_TYPE_PYTHON:
        if not doc.has(String("metadata")):
            _refuse(source, String("a PYTHON artifact needs 'metadata'"))
        if doc.has(String("subdir")):
            _refuse(source, String("'subdir' belongs to a CONDA artifact"))
        m.metadata = _string_member(doc, String("metadata"), source)
        m.metadata_path = _resolve(base, m.metadata)
    else:
        _refuse(
            source,
            String("artifact_type '")
            + m.artifact_type
            # Names the PUBLISH step: `kci run --stage S` is the one verb
            # for stages.
            + String("' is not published by the PUBLISH step (CONDA or PYTHON)"),
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


def render_artifact_manifest(m: ArtifactManifest) raises -> String:
    """`m` as manifest text: compact JSON, keys in the header's order, with
    `file` and `metadata` as written (not resolved), at this kci's major.
    Parsing the result at the same path gives back `m`."""
    var doc = JsonValue.empty_object()
    doc.set_member(String("format"), JsonValue.from_string(String(FORMAT_ARTIFACT_MANIFEST)))
    doc.set_member(
        String("schema_version"),
        JsonValue.from_i64(Int64(current_major(String(FORMAT_ARTIFACT_MANIFEST)))),
    )
    doc.set_member(String("artifact_type"), JsonValue.from_string(m.artifact_type.copy()))
    doc.set_member(String("name"), JsonValue.from_string(m.name.copy()))
    doc.set_member(String("version"), JsonValue.from_string(m.version.copy()))
    doc.set_member(String("platform"), JsonValue.from_string(m.platform.copy()))
    if m.artifact_type == ARTIFACT_TYPE_CONDA:
        doc.set_member(String("subdir"), JsonValue.from_string(m.subdir.copy()))
    doc.set_member(String("file"), JsonValue.from_string(m.file.copy()))
    doc.set_member(String("sha256"), JsonValue.from_string(m.sha256_hex.copy()))
    doc.set_member(String("metadata"), JsonValue.from_string(m.metadata.copy()))
    var text = doc.serialize() + String("\n")
    # The renderer checks its own output: a value the parser would refuse
    # (an empty name, a bad hash) is refused here, before anything is written.
    _ = parse_artifact_manifest(text, m.source)
    return text^
