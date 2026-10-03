# =============================================================================
# src/kci_release_set/release_manifest.mojo -- `release.json`: the last file
#   `kci build` writes into a release directory.
# =============================================================================
#
#   {"members":[{"artifact_type":..,"build":..,"dir":"<name>","kind":..,
#                "name":..,"sha256":..,"subdir":..,"version":..}, ...],
#    "schema":"kci.release_set.v1","set_hash":"<64 hex>"}
#
# Sorted compact JSON (keys in the order above, members sorted bytewise by
# `name`), one trailing newline. It is a commit marker and a convenience,
# never an authority: a build that stopped leaves no `release.json`, and
# `kci publish` recomputes every member and the set hash from the member
# directories and refuses a `release.json` that differs.
#
# Every value is a string. `build`, `kind` and `subdir` are non-empty for a
# CONDA member and empty for any other type; every other value is non-empty.
#
# `parse_release_manifest` refuses, naming the file: not JSON, not an
# object, a key given twice, an unknown or missing key, a non-string value,
# an unknown schema, no members, members not sorted by name or a name given
# twice, a `dir` other than its member's name, a sha256 or set hash that is
# not 64 lowercase hex characters, and a `set_hash` that is not the hash of
# its own members. `render_release_manifest` parses its own output, so it
# cannot write what the parser refuses.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from std.pathlib import Path

from komira_json import JSON_ARRAY, JSON_OBJECT, JSON_STRING, JsonValue, parse_json_value

from kci_artifact_manifest import is_sha256_hex
from kci_release_channel import ARTIFACT_TYPE_CONDA

from kci_release_set.member import ReleaseMember
from kci_release_set.set_hash import SetHashLine, bytewise_less, set_hash_of_lines

comptime RELEASE_MANIFEST_NAME: String = "release.json"
"""The file name of the release manifest at the top of a release directory."""

comptime RELEASE_SET_SCHEMA: String = "kci.release_set.v1"


struct ReleaseEntry(Copyable, Movable, Equatable):
    """One member row of `release.json`.

    Layout: owned values only. No pointer field."""

    var artifact_type: String
    var build: String
    var dir: String
    var kind: String
    var name: String
    var sha256_hex: String
    var subdir: String
    var version: String

    def __init__(out self):
        self.artifact_type = String("")
        self.build = String("")
        self.dir = String("")
        self.kind = String("")
        self.name = String("")
        self.sha256_hex = String("")
        self.subdir = String("")
        self.version = String("")

    def __eq__(self, other: Self) -> Bool:
        return (
            self.artifact_type == other.artifact_type
            and self.build == other.build
            and self.dir == other.dir
            and self.kind == other.kind
            and self.name == other.name
            and self.sha256_hex == other.sha256_hex
            and self.subdir == other.subdir
            and self.version == other.version
        )


struct ReleaseManifest(Copyable, Movable):
    """`release.json`: the members, sorted by name, and the set hash.

    Layout: owned values only. No pointer field."""

    var entries: List[ReleaseEntry]
    var set_hash: String

    def __init__(out self):
        self.entries = List[ReleaseEntry]()
        self.set_hash = String("")

    def same_as(self, other: ReleaseManifest) -> Bool:
        """Every member and the set hash are equal."""
        if self.set_hash != other.set_hash or len(self.entries) != len(other.entries):
            return False
        for i in range(len(self.entries)):
            if not (self.entries[i] == other.entries[i]):
                return False
        return True


def release_entry_of(member: ReleaseMember) -> ReleaseEntry:
    """The `release.json` row of a verified member."""
    var e = ReleaseEntry()
    e.artifact_type = member.manifest.artifact_type.copy()
    e.build = member.build()
    e.dir = member.declaration.copy()
    e.kind = member.kind()
    e.name = member.manifest.name.copy()
    e.sha256_hex = member.manifest.sha256_hex.copy()
    e.subdir = member.manifest.subdir.copy()
    e.version = member.manifest.version.copy()
    return e^


def _sort_entries(mut entries: List[ReleaseEntry]):
    for i in range(1, len(entries)):
        var j = i
        while j > 0 and bytewise_less(entries[j].name, entries[j - 1].name):
            var t = entries[j].copy()
            entries[j] = entries[j - 1].copy()
            entries[j - 1] = t^
            j -= 1


def _lines_of(entries: List[ReleaseEntry]) -> List[SetHashLine]:
    var lines = List[SetHashLine]()
    for i in range(len(entries)):
        ref e = entries[i]
        lines.append(
            SetHashLine(e.name.copy(), e.version.copy(), e.build.copy(), e.sha256_hex.copy())
        )
    return lines^


def release_manifest_of(members: List[ReleaseMember]) raises -> ReleaseManifest:
    """The release manifest of verified members: sorted, with its set hash."""
    var r = ReleaseManifest()
    for i in range(len(members)):
        r.entries.append(release_entry_of(members[i]))
    _sort_entries(r.entries)
    r.set_hash = set_hash_of_lines(_lines_of(r.entries))
    return r^


def _refuse(source: String, why: String) raises:
    raise Error(String("release manifest '") + source + String("': ") + why)


def _keys_exactly(doc: JsonValue, known: List[String], source: String, what: String) raises:
    for i in range(doc.num_members()):
        var key = doc.key_at(i)
        for j in range(i):
            if doc.key_at(j) == key:
                _refuse(source, what + String("'") + key + String("' is given twice"))
        var ok = False
        for j in range(len(known)):
            if known[j] == key:
                ok = True
        if not ok:
            _refuse(source, what + String("unknown key '") + key + String("'"))
    for j in range(len(known)):
        if not doc.has(known[j]):
            _refuse(source, what + String("missing '") + known[j] + String("'"))


def _str(doc: JsonValue, key: String, source: String, what: String, may_be_empty: Bool) raises -> String:
    var v = doc.get(key)
    if v.kind_tag() != JSON_STRING:
        _refuse(source, what + String("'") + key + String("' is not a string"))
    var s = v.as_string()
    if not may_be_empty and s.byte_length() == 0:
        _refuse(source, what + String("'") + key + String("' is EMPTY"))
    return s^


def _entry_keys() -> List[String]:
    var k = List[String]()
    k.append(String("artifact_type"))
    k.append(String("build"))
    k.append(String("dir"))
    k.append(String("kind"))
    k.append(String("name"))
    k.append(String("sha256"))
    k.append(String("subdir"))
    k.append(String("version"))
    return k^


def _entry(row: JsonValue, index: Int, source: String) raises -> ReleaseEntry:
    var what = String("members[") + String(index) + String("]: ")
    if row.kind_tag() != JSON_OBJECT:
        _refuse(source, what + String("not an object"))
    _keys_exactly(row, _entry_keys(), source, what)
    var e = ReleaseEntry()
    e.artifact_type = _str(row, String("artifact_type"), source, what, False)
    var conda = e.artifact_type == ARTIFACT_TYPE_CONDA
    e.build = _str(row, String("build"), source, what, True)
    e.dir = _str(row, String("dir"), source, what, False)
    e.kind = _str(row, String("kind"), source, what, True)
    e.name = _str(row, String("name"), source, what, False)
    e.sha256_hex = _str(row, String("sha256"), source, what, False)
    e.subdir = _str(row, String("subdir"), source, what, True)
    e.version = _str(row, String("version"), source, what, False)
    if not is_sha256_hex(e.sha256_hex):
        _refuse(source, what + String("'sha256' is not 64 lowercase hex characters"))
    if e.dir != e.name:
        _refuse(
            source,
            what + String("'dir' '") + e.dir + String("' is not the member's name '")
            + e.name + String("'"),
        )
    var keyed = List[String]()
    keyed.append(String("build"))
    keyed.append(String("kind"))
    keyed.append(String("subdir"))
    var values = List[String]()
    values.append(e.build.copy())
    values.append(e.kind.copy())
    values.append(e.subdir.copy())
    for k in range(len(keyed)):
        var empty = values[k].byte_length() == 0
        if conda and empty:
            _refuse(source, what + String("'") + keyed[k] + String("' is EMPTY on a CONDA member"))
        if not conda and not empty:
            _refuse(
                source,
                what + String("'") + keyed[k] + String("' is set on a ") + e.artifact_type
                + String(" member; only CONDA members have one"),
            )
    return e^


def parse_release_manifest(text: String, source: String) raises -> ReleaseManifest:
    """Parse `release.json`'s text (file header); `source` names it."""
    var doc: JsonValue
    try:
        doc = parse_json_value(text)
    except e:
        _refuse(source, String("not JSON: ") + String(e))
        return ReleaseManifest()
    if not doc.is_object():
        _refuse(source, String("not a JSON object"))
    var top = List[String]()
    top.append(String("members"))
    top.append(String("schema"))
    top.append(String("set_hash"))
    _keys_exactly(doc, top, source, String(""))
    var schema = _str(doc, String("schema"), source, String(""), False)
    if schema != RELEASE_SET_SCHEMA:
        _refuse(
            source,
            String("schema '") + schema + String("' is not '") + String(RELEASE_SET_SCHEMA)
            + String("'"),
        )
    var r = ReleaseManifest()
    r.set_hash = _str(doc, String("set_hash"), source, String(""), False)
    if not is_sha256_hex(r.set_hash):
        _refuse(source, String("'set_hash' is not 64 lowercase hex characters"))
    var rows = doc.get(String("members"))
    if rows.kind_tag() != JSON_ARRAY:
        _refuse(source, String("'members' is not an array"))
    if rows.array_len() == 0:
        _refuse(source, String("'members' is EMPTY"))
    for i in range(rows.array_len()):
        var e = _entry(rows.element_at(i), i, source)
        if i > 0:
            ref prev = r.entries[i - 1]
            if prev.name == e.name:
                _refuse(source, String("member '") + e.name + String("' is given twice"))
            if not bytewise_less(prev.name, e.name):
                _refuse(
                    source,
                    String("members are not sorted by name: '") + e.name
                    + String("' comes after '") + prev.name + String("'"),
                )
        r.entries.append(e^)
    var recomputed = set_hash_of_lines(_lines_of(r.entries))
    if recomputed != r.set_hash:
        _refuse(
            source,
            String("'set_hash' ") + r.set_hash + String(" is not the hash of its members (")
            + recomputed + String(")"),
        )
    return r^


def read_release_manifest(path: String) raises -> ReleaseManifest:
    """Read and parse the `release.json` at `path`."""
    var text: String
    try:
        text = Path(path).read_text()
    except e:
        raise Error(
            String("release manifest '") + path + String("' cannot be read: ") + String(e)
        )
    return parse_release_manifest(text, path)


def render_release_manifest(r: ReleaseManifest) raises -> String:
    """`r` as `release.json` text (file header). Members are written sorted
    by name whatever order `r` holds them in."""
    var entries = r.entries.copy()
    _sort_entries(entries)
    var rows = JsonValue.empty_array()
    for i in range(len(entries)):
        ref e = entries[i]
        var row = JsonValue.empty_object()
        row.set_member(String("artifact_type"), JsonValue.from_string(e.artifact_type.copy()))
        row.set_member(String("build"), JsonValue.from_string(e.build.copy()))
        row.set_member(String("dir"), JsonValue.from_string(e.dir.copy()))
        row.set_member(String("kind"), JsonValue.from_string(e.kind.copy()))
        row.set_member(String("name"), JsonValue.from_string(e.name.copy()))
        row.set_member(String("sha256"), JsonValue.from_string(e.sha256_hex.copy()))
        row.set_member(String("subdir"), JsonValue.from_string(e.subdir.copy()))
        row.set_member(String("version"), JsonValue.from_string(e.version.copy()))
        rows.push(row^)
    var doc = JsonValue.empty_object()
    doc.set_member(String("members"), rows^)
    doc.set_member(String("schema"), JsonValue.from_string(String(RELEASE_SET_SCHEMA)))
    doc.set_member(String("set_hash"), JsonValue.from_string(r.set_hash.copy()))
    var text = doc.serialize() + String("\n")
    _ = parse_release_manifest(text, String(RELEASE_MANIFEST_NAME))
    return text^
