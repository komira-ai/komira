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
#                   kci_api's format table), kind ("library" | "native" |
#                   "metapackage"),
#                   name, version, subdir, build, build_number (integer >= 0),
#                   file_name, size (integer > 0), depends (array of
#                   strings), timestamp_ms (integer), source_commit,
#                   stamped (boolean), label
#   a library       import_name, mojo_pin, payload_path, payload_sha256;
#                   optionally doc_files: an array of {path, sha256} objects,
#                   the documentation the package installs, each path under
#                   share/doc/<name>/ and given once; optionally lib_files
#                   (below)
#   native          lib_files: the package of libkomira_native.so.1
#                   (`komira_pack conda --kind native`), which holds no Mojo:
#                   no import_name, mojo_pin, payload or doc_files. Its
#                   `lib_files` holds at least one file row
#   a metapackage   members: an array of {name, version, sha256} objects,
#                   each optionally with build
#
# `build` in a member row is optional because the packer on main writes
# {name, sha256, version} and the compiler-version change of the packer adds
# `build`; the reader accepts both and records whether it was there
# (`MetaMember.has_build`). Whether a release may ship a row without it is
# the PUBLISH step's rule, not the reader's.
#
# `lib_files` is an array of rows, each `{path, sha256}` (a file) or
# `{path, target}` (a symbolic link): `path` under lib/ with no empty, '.'
# or '..' component and given once; `target` a bare file name in the
# link's own directory that a FILE row of the array installs. A library
# carries it (the packer writes [] when it ships no archive), a package
# written before the packer shipped lib files has none; the reader records
# whether it was there (`CondaMetadata.has_lib_files`).
#
# `doc_files` is optional because a package the packer wrote before it
# shipped docs has none; the reader records whether it was there
# (`CondaMetadata.has_doc_files`). Whether a release needs it is the
# validation's rule, not the reader's.
#
# `format` and `schema_version` are read first (kci_api's
# `produced_header`): another format, or a major this kci does not read, is
# refused. Inside a known major an unknown key is IGNORED and listed in
# `ignored_keys` (kci_api's policy: writers only ever add keys inside a
# major).
#
# Refused, naming the file and the key: not JSON, not an object, a key given
# twice, a key of the other kind, a missing key, a value of the wrong JSON
# type, an empty string (only `source_commit` of an unstamped package may be
# empty: the packer writes "" when no commit was given), a sha256 that is not
# 64 lowercase hex characters, an unknown `kind`, a malformed `lib_files`
# row, a native package with no file in `lib_files`.
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
from kci_api import FORMAT_CONDA_METADATA, produced_header

comptime KIND_LIBRARY: String = "library"
comptime KIND_METAPACKAGE: String = "metapackage"
comptime KIND_NATIVE: String = "native"
"""The package of libkomira_native.so.1: one shared object and its link name,
no Mojo. Libraries that call komira's C require it at the release's version
and build."""


def is_member_kind(kind: String) -> Bool:
    """Whether a package of `kind` is a member of a release set's metapackage
    and may be required by a library of the set: a library or the native
    package."""
    return kind == KIND_LIBRARY or kind == KIND_NATIVE


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


struct DocFile(Copyable, Movable):
    """One row of a library's `doc_files`: a documentation file the package
    installs (`path`, under share/doc/<name>/) and the sha256 of its bytes.

    Layout: owned values only. No pointer field."""

    var path: String
    var sha256_hex: String

    def __init__(out self):
        self.path = String("")
        self.sha256_hex = String("")


struct LibFile(Copyable, Movable):
    """One row of `lib_files`: a file under lib/ (`sha256_hex` set, `target`
    "") or a symbolic link (`target` set, `sha256_hex` "").

    Layout: owned values only. No pointer field."""

    var path: String
    var sha256_hex: String
    var target: String

    def __init__(out self):
        self.path = String("")
        self.sha256_hex = String("")
        self.target = String("")

    def is_link(self) -> Bool:
        return self.target.byte_length() > 0


struct CondaMetadata(Copyable, Movable):
    """A parsed `metadata.json`. The library-only fields are "" on a
    metapackage or a native package, `members` is empty on a library or a
    native package, and `lib_files` is empty on a metapackage. `source` names the file
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
    # A library's documentation files; `has_doc_files` is False when the key
    # is absent (a package written before the packer shipped docs).
    var doc_files: List[DocFile]
    var has_doc_files: Bool
    # The files under lib/ (a native package's shared object and link, a
    # library's archives); `has_lib_files` is False when the key is absent.
    var lib_files: List[LibFile]
    var has_lib_files: Bool
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
        self.doc_files = List[DocFile]()
        self.has_doc_files = False
        self.lib_files = List[LibFile]()
        self.has_lib_files = False
        self.ignored_keys = List[String]()

    def is_metapackage(self) -> Bool:
        return self.kind == KIND_METAPACKAGE

    def is_native(self) -> Bool:
        return self.kind == KIND_NATIVE


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


def _library_optional_keys() -> List[String]:
    var k = List[String]()
    k.append(String("doc_files"))
    return k^


def _lib_files_key() -> List[String]:
    var k = List[String]()
    k.append(String("lib_files"))
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


def _doc_row(
    row: JsonValue, index: Int, under: String, seen: List[DocFile], source: String, mut ignored: List[String]
) raises -> DocFile:
    var what = String("doc_files[") + String(index) + String("]: ")
    if row.kind_tag() != JSON_OBJECT:
        _refuse(source, what + String("not an object"))
    var known = List[String]()
    known.append(String("path"))
    known.append(String("sha256"))
    _no_twice_note_unknown(
        row, known, source, what, String("doc_files[") + String(index) + String("]."), ignored
    )
    var d = DocFile()
    d.path = _string(row, String("path"), source, what)
    d.sha256_hex = _hex(row, String("sha256"), source, what)
    var ok = d.path.startswith(under) and d.path.byte_length() > under.byte_length()
    if ok:
        var rest = String(d.path[byte = under.byte_length() :])
        for part in rest.split("/"):
            if part == "" or part == "." or part == "..":
                ok = False
    if not ok:
        _refuse(
            source,
            what
            + String("'path' ")
            + d.path
            + String(" is not under ")
            + under
            + String(" with no empty, '.' or '..' component"),
        )
    for i in range(len(seen)):
        if seen[i].path == d.path:
            _refuse(source, what + String("'path' ") + d.path + String(" is given twice"))
    return d^


def _lib_row(row: JsonValue, index: Int, seen: List[LibFile], source: String, mut ignored: List[String]) raises -> LibFile:
    var what = String("lib_files[") + String(index) + String("]: ")
    if row.kind_tag() != JSON_OBJECT:
        _refuse(source, what + String("not an object"))
    var known = List[String]()
    known.append(String("path"))
    known.append(String("sha256"))
    known.append(String("target"))
    _no_twice_note_unknown(
        row, known, source, what, String("lib_files[") + String(index) + String("]."), ignored
    )
    var f = LibFile()
    f.path = _string(row, String("path"), source, what)
    var under = String("lib/")
    var ok = f.path.startswith(under) and f.path.byte_length() > under.byte_length()
    if ok:
        var rest = String(f.path[byte = under.byte_length() :])
        for part in rest.split("/"):
            if part == "" or part == "." or part == "..":
                ok = False
    if not ok:
        _refuse(
            source,
            what + String("'path' ") + f.path + String(" is not under lib/ with no empty, '.' or '..' component"),
        )
    for i in range(len(seen)):
        if seen[i].path == f.path:
            _refuse(source, what + String("'path' ") + f.path + String(" is given twice"))
    var has_sha = row.has(String("sha256"))
    var has_target = row.has(String("target"))
    if has_sha and has_target:
        _refuse(source, what + String("has both 'sha256' (a file) and 'target' (a link)"))
    if not has_sha and not has_target:
        _refuse(source, what + String("missing 'sha256' (a file) or 'target' (a link)"))
    if has_sha:
        f.sha256_hex = _hex(row, String("sha256"), source, what)
    else:
        f.target = _string(row, String("target"), source, what)
        if f.target.find(String("/")) >= 0 or f.target == String(".") or f.target == String(".."):
            _refuse(
                source,
                what + String("'target' ") + f.target + String(" is not a file name in the link's directory"),
            )
    return f^


def _read_lib_files(doc: JsonValue, mut md: CondaMetadata, source: String) raises:
    """`lib_files` into `md` (file header): every row checked, then every
    link's target a file row of the array."""
    md.has_lib_files = True
    var rows = doc.get(String("lib_files"))
    if rows.kind_tag() != JSON_ARRAY:
        _refuse(source, String("'lib_files' is not an array"))
    for i in range(rows.array_len()):
        var f = _lib_row(rows.element_at(i), i, md.lib_files, source, md.ignored_keys)
        md.lib_files.append(f^)
    for i in range(len(md.lib_files)):
        ref f = md.lib_files[i]
        if not f.is_link():
            continue
        var slash = f.path.rfind(String("/"))
        var want = String(f.path[byte = : slash + 1]) + f.target
        var found = False
        for j in range(len(md.lib_files)):
            if md.lib_files[j].path == want and not md.lib_files[j].is_link():
                found = True
        if not found:
            _refuse(
                source,
                String("lib_files[")
                + String(i)
                + String("]: link ")
                + f.path
                + String(" -> ")
                + f.target
                + String(": no file row of 'lib_files' is ")
                + want,
            )


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
    var optional = _library_optional_keys()
    var meta = _metapackage_keys()
    var lib_files = _lib_files_key()
    var all_keys = common.copy()
    all_keys.extend(library.copy())
    all_keys.extend(optional.copy())
    all_keys.extend(lib_files.copy())
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
    elif md.kind == KIND_NATIVE:
        own = lib_files.copy()
        other = library.copy()
        other.extend(optional.copy())
        other.extend(meta.copy())
    elif md.kind == KIND_METAPACKAGE:
        own = meta.copy()
        other = library.copy()
        other.extend(optional.copy())
        other.extend(lib_files.copy())
    else:
        _refuse(
            source,
            String("kind '") + md.kind + String("' is not 'library', 'native' or 'metapackage'"),
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
        if doc.has(String("doc_files")):
            md.has_doc_files = True
            var docs = doc.get(String("doc_files"))
            if docs.kind_tag() != JSON_ARRAY:
                _refuse(source, String("'doc_files' is not an array"))
            var under = String("share/doc/") + md.name + String("/")
            for i in range(docs.array_len()):
                var d = _doc_row(docs.element_at(i), i, under, md.doc_files, source, md.ignored_keys)
                md.doc_files.append(d^)
        if doc.has(String("lib_files")):
            _read_lib_files(doc, md, source)
    elif md.kind == KIND_NATIVE:
        _read_lib_files(doc, md, source)
        var files = 0
        for i in range(len(md.lib_files)):
            if not md.lib_files[i].is_link():
                files += 1
        if files == 0:
            _refuse(source, String("a native package's 'lib_files' holds no file"))
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
