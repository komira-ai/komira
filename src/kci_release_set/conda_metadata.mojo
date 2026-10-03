# =============================================================================
# src/kci_release_set/conda_metadata.mojo -- the `metadata.json` a conda
#   package's build leaves next to its manifest, read and checked.
# =============================================================================
#
# The format is the one `komira_pack conda` / `conda-meta` writes
# (packaging/conda/README.md, "What a package is"): one JSON object, sorted
# compact, with
#
#   every package   format ("kci.conda_metadata"), schema_version (integer,
#                   kci_contract's format table), kind ("library" |
#                   "metapackage"),
#                   name, version, subdir, build, build_number (integer >= 0),
#                   file_name, size (integer > 0), depends (array of
#                   strings), timestamp_ms (integer), source_commit,
#                   stamped (boolean), label
#   a library       import_name, mojo_pin, payload_path, payload_sha256
#   a metapackage   members: an array of {name, version, sha256} objects,
#                   each optionally with build
#
# `build` in a member row is optional because the packer on main writes
# {name, sha256, version} and the compiler-version change of the packer adds
# `build`; the reader accepts both and records whether it was there
# (`MetaMember.has_build`). Whether a release may ship a row without it is
# `kci publish`'s rule, not the reader's.
#
# `format` and `schema_version` are read first (kci_contract's
# `produced_header`): another format, or a major this kci does not read, is
# refused. Inside a known major an unknown key is IGNORED and listed in
# `ignored_keys` (kci_contract's policy: writers only ever add keys inside a
# major).
#
# Refused, naming the file and the key: not JSON, not an object, a key given
# twice, a key of the other kind, a missing key, a value of the wrong JSON
# type, an empty string (only `source_commit` of an unstamped package may be
# empty: the packer writes "" when no commit was given), a sha256 that is not
# 64 lowercase hex characters, an unknown `kind`.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from std.pathlib import Path

from komira_json import (
    JSON_ARRAY,
    JSON_BOOL,
    JSON_NUMBER,
    JSON_OBJECT,
    JSON_STRING,
    JsonValue,
    parse_json_value,
)

from kci_artifact_manifest import is_sha256_hex
from kci_contract import FORMAT_CONDA_METADATA, produced_header

comptime KIND_LIBRARY: String = "library"
comptime KIND_METAPACKAGE: String = "metapackage"


struct MetaMember(Copyable, Movable):
    """One row of a metapackage's `members`. `build` is "" when the row has
    none (`has_build` False).

    Layout: owned values only. No pointer field."""

    var name: String
    var version: String
    var build: String
    var has_build: Bool
    var sha256_hex: String

    def __init__(out self):
        self.name = String("")
        self.version = String("")
        self.build = String("")
        self.has_build = False
        self.sha256_hex = String("")


struct CondaMetadata(Copyable, Movable):
    """A parsed `metadata.json`. The library-only fields are "" on a
    metapackage and `members` is empty on a library. `source` names the file
    in every refusal.

    Layout: owned values only. No pointer field."""

    var source: String
    var schema_version: Int
    var kind: String
    var name: String
    var version: String
    var subdir: String
    var build: String
    var build_number: Int
    var file_name: String
    var size: Int
    var depends: List[String]
    var timestamp_ms: Int
    var source_commit: String
    var stamped: Bool
    var label: String
    var import_name: String
    var mojo_pin: String
    var payload_path: String
    var payload_sha256: String
    var members: List[MetaMember]
    # Set by the parser only: keys of a known major it ignored (file header).
    var ignored_keys: List[String]

    def __init__(out self, var source: String):
        self.source = source^
        self.schema_version = 0
        self.kind = String("")
        self.name = String("")
        self.version = String("")
        self.subdir = String("")
        self.build = String("")
        self.build_number = 0
        self.file_name = String("")
        self.size = 0
        self.depends = List[String]()
        self.timestamp_ms = 0
        self.source_commit = String("")
        self.stamped = False
        self.label = String("")
        self.import_name = String("")
        self.mojo_pin = String("")
        self.payload_path = String("")
        self.payload_sha256 = String("")
        self.members = List[MetaMember]()
        self.ignored_keys = List[String]()

    def is_metapackage(self) -> Bool:
        return self.kind == KIND_METAPACKAGE


def _refuse(source: String, why: String) raises:
    raise Error(String("conda metadata '") + source + String("': ") + why)


def _common_keys() -> List[String]:
    var k = List[String]()
    k.append(String("format"))
    k.append(String("schema_version"))
    k.append(String("kind"))
    k.append(String("name"))
    k.append(String("version"))
    k.append(String("subdir"))
    k.append(String("build"))
    k.append(String("build_number"))
    k.append(String("file_name"))
    k.append(String("size"))
    k.append(String("depends"))
    k.append(String("timestamp_ms"))
    k.append(String("source_commit"))
    k.append(String("stamped"))
    k.append(String("label"))
    return k^


def _library_keys() -> List[String]:
    var k = List[String]()
    k.append(String("import_name"))
    k.append(String("mojo_pin"))
    k.append(String("payload_path"))
    k.append(String("payload_sha256"))
    return k^


def _metapackage_keys() -> List[String]:
    var k = List[String]()
    k.append(String("members"))
    return k^


def _in(keys: List[String], key: String) -> Bool:
    for i in range(len(keys)):
        if keys[i] == key:
            return True
    return False


def _no_twice_note_unknown(
    doc: JsonValue,
    known: List[String],
    source: String,
    what: String,
    note: String,
    mut ignored: List[String],
) raises:
    """Refuse a key given twice; list (never refuse) a key not in `known`, as
    `note + key`."""
    for i in range(doc.num_members()):
        var key = doc.key_at(i)
        for j in range(i):
            if doc.key_at(j) == key:
                _refuse(source, what + String("'") + key + String("' is given twice"))
        if not _in(known, key):
            ignored.append(note + key)


def _need(doc: JsonValue, key: String, source: String, what: String) raises -> JsonValue:
    if not doc.has(key):
        _refuse(source, what + String("missing '") + key + String("'"))
    return doc.get(key)


def _string(
    doc: JsonValue, key: String, source: String, what: String = String(""), may_be_empty: Bool = False
) raises -> String:
    var v = _need(doc, key, source, what)
    if v.kind_tag() != JSON_STRING:
        _refuse(source, what + String("'") + key + String("' is not a string"))
    var s = v.as_string()
    if not may_be_empty and s.byte_length() == 0:
        _refuse(source, what + String("'") + key + String("' is EMPTY"))
    return s^


def _integer(doc: JsonValue, key: String, source: String) raises -> Int:
    var v = _need(doc, key, source, String(""))
    if v.kind_tag() != JSON_NUMBER or not v.is_integral_number():
        _refuse(source, String("'") + key + String("' is not an integer"))
    return Int(v.as_int64())


def _hex(doc: JsonValue, key: String, source: String, what: String = String("")) raises -> String:
    var s = _string(doc, key, source, what)
    if not is_sha256_hex(s):
        _refuse(source, what + String("'") + key + String("' is not 64 lowercase hex characters"))
    return s^


def _member_row(row: JsonValue, index: Int, source: String, mut ignored: List[String]) raises -> MetaMember:
    var what = String("members[") + String(index) + String("]: ")
    if row.kind_tag() != JSON_OBJECT:
        _refuse(source, what + String("not an object"))
    var known = List[String]()
    known.append(String("name"))
    known.append(String("version"))
    known.append(String("build"))
    known.append(String("sha256"))
    _no_twice_note_unknown(
        row, known, source, what, String("members[") + String(index) + String("]."), ignored
    )
    var m = MetaMember()
    m.name = _string(row, String("name"), source, what)
    m.version = _string(row, String("version"), source, what)
    m.sha256_hex = _hex(row, String("sha256"), source, what)
    if row.has(String("build")):
        m.build = _string(row, String("build"), source, what)
        m.has_build = True
    return m^


def parse_conda_metadata(text: String, source: String) raises -> CondaMetadata:
    """Parse one `metadata.json`'s text; `source` names it in refusals."""
    var doc: JsonValue
    try:
        doc = parse_json_value(text)
    except e:
        _refuse(source, String("not JSON: ") + String(e))
        return CondaMetadata(source.copy())
    if not doc.is_object():
        _refuse(source, String("not a JSON object"))
    var common = _common_keys()
    var library = _library_keys()
    var meta = _metapackage_keys()
    var all_keys = common.copy()
    all_keys.extend(library.copy())
    all_keys.extend(meta.copy())
    var md = CondaMetadata(source.copy())
    _no_twice_note_unknown(doc, all_keys, source, String(""), String(""), md.ignored_keys)
    # produced_header's refusals start "<its source>: ", so it is given this
    # file's refusal prefix as its source.
    md.schema_version = produced_header(
        doc, String(FORMAT_CONDA_METADATA), String("conda metadata '") + source + String("'")
    )

    md.kind = _string(doc, String("kind"), source)
    var own: List[String]
    var other: List[String]
    if md.kind == KIND_LIBRARY:
        own = library.copy()
        other = meta.copy()
    elif md.kind == KIND_METAPACKAGE:
        own = meta.copy()
        other = library.copy()
    else:
        _refuse(
            source,
            String("kind '") + md.kind + String("' is neither 'library' nor 'metapackage'"),
        )
        return md^
    for i in range(doc.num_members()):
        var key = doc.key_at(i)
        if _in(other, key):
            _refuse(
                source,
                String("'") + key + String("' does not belong to a ") + md.kind,
            )
    for i in range(len(common)):
        _ = _need(doc, common[i], source, String(""))
    for i in range(len(own)):
        _ = _need(doc, own[i], source, String(""))

    md.name = _string(doc, String("name"), source)
    md.version = _string(doc, String("version"), source)
    md.subdir = _string(doc, String("subdir"), source)
    md.build = _string(doc, String("build"), source)
    md.build_number = _integer(doc, String("build_number"), source)
    if md.build_number < 0:
        _refuse(source, String("'build_number' is negative"))
    md.file_name = _string(doc, String("file_name"), source)
    md.size = _integer(doc, String("size"), source)
    if md.size <= 0:
        _refuse(source, String("'size' is not positive"))
    var deps = doc.get(String("depends"))
    if deps.kind_tag() != JSON_ARRAY:
        _refuse(source, String("'depends' is not an array"))
    for i in range(deps.array_len()):
        var d = deps.element_at(i)
        if d.kind_tag() != JSON_STRING or d.as_string().byte_length() == 0:
            _refuse(
                source,
                String("depends[") + String(i) + String("] is not a non-empty string"),
            )
        md.depends.append(d.as_string())
    md.timestamp_ms = _integer(doc, String("timestamp_ms"), source)
    var stamped = doc.get(String("stamped"))
    if stamped.kind_tag() != JSON_BOOL:
        _refuse(source, String("'stamped' is not a boolean"))
    md.stamped = stamped.as_bool()
    md.source_commit = _string(
        doc, String("source_commit"), source, may_be_empty=not md.stamped
    )
    md.label = _string(doc, String("label"), source)
    if md.kind == KIND_LIBRARY:
        md.import_name = _string(doc, String("import_name"), source)
        md.mojo_pin = _string(doc, String("mojo_pin"), source)
        md.payload_path = _string(doc, String("payload_path"), source)
        md.payload_sha256 = _hex(doc, String("payload_sha256"), source)
    else:
        var rows = doc.get(String("members"))
        if rows.kind_tag() != JSON_ARRAY:
            _refuse(source, String("'members' is not an array"))
        for i in range(rows.array_len()):
            md.members.append(_member_row(rows.element_at(i), i, source, md.ignored_keys))
    return md^


def read_conda_metadata(path: String) raises -> CondaMetadata:
    """Read and parse the `metadata.json` at `path`."""
    var text: String
    try:
        text = Path(path).read_text()
    except e:
        raise Error(
            String("conda metadata '") + path + String("' cannot be read: ") + String(e)
        )
    return parse_conda_metadata(text, path)
