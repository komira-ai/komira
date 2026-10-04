# =============================================================================
# src/kci_release_set/release_manifest.mojo -- `release.json`: the last file
#   the BUILD step writes into a platform's release directory.
# =============================================================================
#
# Format `kci.release_set`, schema_version 2 (kci_api's format table):
#
#   {"format":"kci.release_set",
#    "members":[{"artifact_type":..,"build":..,"dir":"<name>","kind":..,
#                "name":..,"platform":..,"sha256":..,"subdir":..,
#                "version":..}, ...],
#    "platform":"linux-x86_64",
#    "produced_by":{"attempt":1,"run_id":"gh-123"},
#    "revision":"<40 hex>",
#    "schema_version":2,
#    "set_hash":"<64 hex>"}
#
# Sorted compact JSON (keys bytewise, members sorted bytewise by `name`),
# one trailing newline. It lives at `<release-dir>/<platform>/release.json`
# (kci_api's layout), next to one directory per member. It is a commit
# marker and a convenience, never an authority: a build that stopped leaves
# no `release.json`, and the PUBLISH step recomputes every member and the set
# hash from the member directories and refuses a `release.json` that
# differs.
#
# THE RELEASE IDENTITY is (revision, platform): the full commit id the set
# was built from and the platform it was built for. Both are in the set hash
# (set_hash.mojo). `produced_by` records which run built it (--run-id,
# --attempt) and is NOT in the hash. A member's `platform` is the set's or
# `noarch`; a CONDA member's `subdir` is its platform's conda subdir.
#
# Every member value is a string. `build`, `kind` and `subdir` are non-empty
# for a CONDA member and empty for any other type; every other member value
# is non-empty. Member names are unique (each is the directory `dir` under
# the platform's release directory).
#
# Major 1 (`"schema":"kci.release_set.v1"`, no revision, no platform) is no
# longer read: a release directory is rebuilt, never carried across kci
# versions. Unknown keys inside major 2 are ignored (kci_api's policy)
# and listed in `ignored_keys`.
#
# `parse_release_manifest` refuses, naming the file: not JSON, not an
# object, a key given twice, a missing key, a value of the wrong JSON type,
# a format or major this kci does not read, a revision that is not a full
# commit id, a platform kci does not release, a `produced_by` whose run id or
# attempt is not one kci accepts, no members, members not sorted by name or
# a name given twice, a `dir` other than its member's name, a member
# platform that is neither the set's nor `noarch`, a CONDA subdir that is not
# its platform's, a sha256 or set hash that is not 64 lowercase hex
# characters, and a `set_hash` that is not the hash of its own identity and
# members. `render_release_manifest` parses its own output, so it cannot
# write what the parser refuses.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from std.pathlib import Path

from komira_json import JSON_ARRAY, JSON_NUMBER, JSON_OBJECT, JSON_STRING, JsonValue, parse_json_value

from kci_artifact_manifest import is_sha256_hex
from kci_api import (
    FORMAT_RELEASE_SET,
    RELEASE_MANIFEST_NAME,
    conda_subdir_of,
    current_major,
    produced_header,
    require_attempt,
    require_full_commit_id,
    require_member_platform,
    require_release_platform,
    require_run_id,
)
from kci_release_channel import ARTIFACT_TYPE_CONDA

from kci_release_set.member import ReleaseMember, member_platform
from kci_release_set.set_hash import SetHashLine, bytewise_less, set_hash_of_lines


struct ReleaseIdentity(Copyable, Movable):
    """What a release set is (revision, platform) and which run produced it
    (run id, attempt). Built only through the checking constructor.

    Layout: owned Strings and an Int. No pointer field."""

    var revision: String
    var platform: String
    var produced_by_run_id: String
    var produced_by_attempt: Int

    def __init__(
        out self,
        var revision: String,
        var platform: String,
        var produced_by_run_id: String,
        produced_by_attempt: Int,
    ) raises:
        require_full_commit_id(String("revision"), revision)
        require_release_platform(platform)
        require_run_id(produced_by_run_id)
        require_attempt(produced_by_attempt)
        self.revision = revision^
        self.platform = platform^
        self.produced_by_run_id = produced_by_run_id^
        self.produced_by_attempt = produced_by_attempt


struct ReleaseEntry(Copyable, Movable, Equatable):
    """One member row of `release.json`.

    Layout: owned values only. No pointer field."""

    var artifact_type: String
    var build: String
    var dir: String
    var kind: String
    var name: String
    var platform: String
    var sha256_hex: String
    var subdir: String
    var version: String

    def __init__(out self):
        self.artifact_type = String("")
        self.build = String("")
        self.dir = String("")
        self.kind = String("")
        self.name = String("")
        self.platform = String("")
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
            and self.platform == other.platform
            and self.sha256_hex == other.sha256_hex
            and self.subdir == other.subdir
            and self.version == other.version
        )


struct ReleaseManifest(Copyable, Movable):
    """`release.json`: the identity, the members sorted by name, and the set
    hash. `ignored_keys` is set by the parser only (file header).

    Layout: owned values only. No pointer field."""

    var revision: String
    var platform: String
    var produced_by_run_id: String
    var produced_by_attempt: Int
    var entries: List[ReleaseEntry]
    var set_hash: String
    var ignored_keys: List[String]

    def __init__(out self):
        self.revision = String("")
        self.platform = String("")
        self.produced_by_run_id = String("")
        self.produced_by_attempt = 0
        self.entries = List[ReleaseEntry]()
        self.set_hash = String("")
        self.ignored_keys = List[String]()

    def set_identity(mut self, identity: ReleaseIdentity):
        self.revision = identity.revision.copy()
        self.platform = identity.platform.copy()
        self.produced_by_run_id = identity.produced_by_run_id.copy()
        self.produced_by_attempt = identity.produced_by_attempt

    def same_as(self, other: ReleaseManifest) -> Bool:
        """The identity, `produced_by`, every member and the set hash are
        equal."""
        if (
            self.revision != other.revision
            or self.platform != other.platform
            or self.produced_by_run_id != other.produced_by_run_id
            or self.produced_by_attempt != other.produced_by_attempt
            or self.set_hash != other.set_hash
            or len(self.entries) != len(other.entries)
        ):
            return False
        for i in range(len(self.entries)):
            if not (self.entries[i] == other.entries[i]):
                return False
        return True


def release_entry_of(member: ReleaseMember, release_platform: String) raises -> ReleaseEntry:
    """The `release.json` row of a verified member of a `release_platform`
    release (`member_platform` gives its platform)."""
    var e = ReleaseEntry()
    e.artifact_type = member.manifest.artifact_type.copy()
    e.build = member.build()
    e.dir = member.declaration.copy()
    e.kind = member.kind()
    e.name = member.manifest.name.copy()
    e.platform = member_platform(member, release_platform)
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
            SetHashLine(
                e.name.copy(),
                e.platform.copy(),
                e.version.copy(),
                e.build.copy(),
                e.subdir.copy(),
                e.artifact_type.copy(),
                e.sha256_hex.copy(),
            )
        )
    return lines^


def entries_set_hash(revision: String, platform: String, entries: List[ReleaseEntry]) raises -> String:
    """The set hash of release rows built from `revision` for `platform`."""
    return set_hash_of_lines(revision, platform, _lines_of(entries))


def release_manifest_of(members: List[ReleaseMember], identity: ReleaseIdentity) raises -> ReleaseManifest:
    """The release manifest of verified members: the identity, the members
    sorted, and the set hash."""
    var r = ReleaseManifest()
    r.set_identity(identity)
    for i in range(len(members)):
        r.entries.append(release_entry_of(members[i], identity.platform))
    _sort_entries(r.entries)
    r.set_hash = entries_set_hash(r.revision, r.platform, r.entries)
    return r^


def release_set_hash(members: List[ReleaseMember], identity: ReleaseIdentity) raises -> String:
    """The set hash of verified members (set_hash.mojo's header)."""
    return release_manifest_of(members, identity).set_hash


def _refuse(source: String, why: String) raises:
    raise Error(String("release manifest '") + source + String("': ") + why)


def _no_twice(doc: JsonValue, source: String, what: String) raises:
    for i in range(doc.num_members()):
        var key = doc.key_at(i)
        for j in range(i):
            if doc.key_at(j) == key:
                _refuse(source, what + String("'") + key + String("' is given twice"))


def _note_unknown(doc: JsonValue, known: List[String], where: String, mut ignored: List[String]) raises:
    for i in range(doc.num_members()):
        var key = doc.key_at(i)
        var ok = False
        for j in range(len(known)):
            if known[j] == key:
                ok = True
        if not ok:
            ignored.append(where + key)


def _require_keys(doc: JsonValue, known: List[String], source: String, what: String) raises:
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


def _int(doc: JsonValue, key: String, source: String, what: String) raises -> Int:
    var v = doc.get(key)
    if v.kind_tag() != JSON_NUMBER or not v.is_integral_number():
        _refuse(source, what + String("'") + key + String("' is not an integer"))
    return Int(v.as_int64())


def _words(names: String) -> List[String]:
    var out = List[String]()
    var parts = names.split(String(" "))
    for i in range(len(parts)):
        out.append(String(parts[i]))
    return out^


def _entry(row: JsonValue, index: Int, release_platform: String, source: String, mut ignored: List[String]) raises -> ReleaseEntry:
    var what = String("members[") + String(index) + String("]: ")
    if row.kind_tag() != JSON_OBJECT:
        _refuse(source, what + String("not an object"))
    _no_twice(row, source, what)
    var keys = _words(String("artifact_type build dir kind name platform sha256 subdir version"))
    _require_keys(row, keys, source, what)
    _note_unknown(row, keys, String("members[") + String(index) + String("]."), ignored)
    var e = ReleaseEntry()
    e.artifact_type = _str(row, String("artifact_type"), source, what, False)
    var conda = e.artifact_type == ARTIFACT_TYPE_CONDA
    e.build = _str(row, String("build"), source, what, True)
    e.dir = _str(row, String("dir"), source, what, False)
    e.kind = _str(row, String("kind"), source, what, True)
    e.name = _str(row, String("name"), source, what, False)
    e.platform = _str(row, String("platform"), source, what, False)
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
    try:
        require_member_platform(release_platform, e.platform)
    except err:
        _refuse(source, what + String(err))
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
    if conda:
        var want = conda_subdir_of(e.platform)
        if e.subdir != want:
            _refuse(
                source,
                what + String("'subdir' '") + e.subdir + String("' is not platform ")
                + e.platform + String("'s conda subdir '") + want + String("'"),
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
    _no_twice(doc, source, String(""))
    if doc.has(String("schema")) and not doc.has(String("format")):
        _refuse(
            source,
            String("this is major 1 of the release set (\"schema\"), which is no longer read")
            + String(" (this kci reads kci.release_set major ")
            + String(current_major(String(FORMAT_RELEASE_SET)))
            + String("): build the release again"),
        )
    # produced_header's refusals start "<its source>: ", so it is given this
    # file's refusal prefix as its source.
    _ = produced_header(
        doc, String(FORMAT_RELEASE_SET), String("release manifest '") + source + String("'")
    )
    var r = ReleaseManifest()
    var top = _words(String("format members platform produced_by revision schema_version set_hash"))
    _require_keys(doc, top, source, String(""))
    _note_unknown(doc, top, String(""), r.ignored_keys)
    r.revision = _str(doc, String("revision"), source, String(""), False)
    try:
        require_full_commit_id(String("'revision'"), r.revision)
    except e:
        _refuse(source, String(e))
    r.platform = _str(doc, String("platform"), source, String(""), False)
    try:
        require_release_platform(r.platform)
    except e:
        _refuse(source, String(e))
    var by = doc.get(String("produced_by"))
    if by.kind_tag() != JSON_OBJECT:
        _refuse(source, String("'produced_by' is not an object"))
    _no_twice(by, source, String("produced_by: "))
    var by_keys = _words(String("attempt run_id"))
    _require_keys(by, by_keys, source, String("produced_by: "))
    _note_unknown(by, by_keys, String("produced_by."), r.ignored_keys)
    r.produced_by_run_id = _str(by, String("run_id"), source, String("produced_by: "), False)
    r.produced_by_attempt = _int(by, String("attempt"), source, String("produced_by: "))
    try:
        require_run_id(r.produced_by_run_id)
        require_attempt(r.produced_by_attempt)
    except e:
        _refuse(source, String("produced_by: ") + String(e))
    r.set_hash = _str(doc, String("set_hash"), source, String(""), False)
    if not is_sha256_hex(r.set_hash):
        _refuse(source, String("'set_hash' is not 64 lowercase hex characters"))
    var rows = doc.get(String("members"))
    if rows.kind_tag() != JSON_ARRAY:
        _refuse(source, String("'members' is not an array"))
    if rows.array_len() == 0:
        _refuse(source, String("'members' is EMPTY"))
    for i in range(rows.array_len()):
        var e = _entry(rows.element_at(i), i, r.platform, source, r.ignored_keys)
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
    var recomputed = entries_set_hash(r.revision, r.platform, r.entries)
    if recomputed != r.set_hash:
        _refuse(
            source,
            String("'set_hash' ") + r.set_hash + String(" is not the hash of its revision, platform")
            + String(" and members (") + recomputed + String(")"),
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
        row.set_member(String("platform"), JsonValue.from_string(e.platform.copy()))
        row.set_member(String("sha256"), JsonValue.from_string(e.sha256_hex.copy()))
        row.set_member(String("subdir"), JsonValue.from_string(e.subdir.copy()))
        row.set_member(String("version"), JsonValue.from_string(e.version.copy()))
        rows.push(row^)
    var by = JsonValue.empty_object()
    by.set_member(String("attempt"), JsonValue.from_i64(Int64(r.produced_by_attempt)))
    by.set_member(String("run_id"), JsonValue.from_string(r.produced_by_run_id.copy()))
    var doc = JsonValue.empty_object()
    doc.set_member(String("format"), JsonValue.from_string(String(FORMAT_RELEASE_SET)))
    doc.set_member(String("members"), rows^)
    doc.set_member(String("platform"), JsonValue.from_string(r.platform.copy()))
    doc.set_member(String("produced_by"), by^)
    doc.set_member(String("revision"), JsonValue.from_string(r.revision.copy()))
    doc.set_member(
        String("schema_version"), JsonValue.from_i64(Int64(current_major(String(FORMAT_RELEASE_SET))))
    )
    doc.set_member(String("set_hash"), JsonValue.from_string(r.set_hash.copy()))
    var text = doc.serialize() + String("\n")
    _ = parse_release_manifest(text, String(RELEASE_MANIFEST_NAME))
    return text^
