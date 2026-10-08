# =============================================================================
# src/kci_api/formats.mojo -- the FORMAT TABLE: every document kci reads
#   or writes, its name, and the schema majors this kci reads.
# =============================================================================
#
# POLICY (one statement, for every row):
#
#   * Every document carries `schema_version: <integer major>`. A produced
#     (JSON) document also carries `format: "<name>"`; an authored
#     (textproto) file is identified by the flag that names it.
#   * AUTHORED: a missing `schema_version` is refused, naming the field to
#     add; a major above `current_major` is refused as "needs a newer kci";
#     a major below `oldest_major_read` is refused as "no longer read". An
#     unknown field under a known major stays the parser's typo refusal.
#   * PRODUCED: a `format` other than the row's name is refused; a major
#     outside [`oldest_major_read`, `current_major`] is refused the same way.
#     Unknown keys inside a known major are IGNORED by readers (a reader
#     records them; it never fails on them), so a writer may ADD a key
#     inside a major and an old reader keeps working.
#   * Writers are additive-only inside a major. Removing or renaming a key,
#     changing a value's meaning, or changing a default is a major bump.
#
# Run-specific values (a run id, an attempt) never go into a file a build
# action writes (manifest.json, metadata.json): such a value in an action's
# inputs makes every run a cache miss and the package bytes differ per run.
#
# The names are spelled here only.
# Pure functions over owned values; no pointer, no file I/O.
# =============================================================================

from komira_json import JSON_NUMBER, JSON_STRING, JsonValue

comptime KIND_AUTHORED: String = "AUTHORED"
comptime KIND_PRODUCED: String = "PRODUCED"

comptime FORMAT_ARTIFACTS: String = "kci.artifacts"
"""The artifacts file (textproto, written by people)."""
comptime FORMAT_CELLS: String = "kci.cells"
"""The cells file: the cells a DEPLOY step deploys into (textproto, written
by people)."""
comptime FORMAT_CHANNELS: String = "kci.channels"
"""The release channels file (textproto, written by people)."""
comptime FORMAT_MACHINE: String = "kci.machine"
"""The machine file: the release machine (textproto, written by people)."""
comptime FORMAT_ARTIFACT_MANIFEST: String = "kci.artifact_manifest"
"""`manifest.json`, one per built artifact (written by the package build)."""
comptime FORMAT_CONDA_METADATA: String = "kci.conda_metadata"
"""`metadata.json` next to a conda package (written by the package build)."""
comptime FORMAT_RELEASE_SET: String = "kci.release_set"
"""`release.json`, the last file a BUILD step writes into a release directory."""
comptime FORMAT_RESULT: String = "kci.result"
"""The result document every verb writes with `--result-file`."""

comptime SCHEMA_VERSION_KEY: String = "schema_version"
comptime FORMAT_KEY: String = "format"


struct FormatRow(Copyable, Movable):
    """One document kci reads or writes.

    Layout: owned Strings and Ints. No pointer field."""

    var name: String
    var kind: String
    var current_major: Int
    var oldest_major_read: Int

    def __init__(out self, var name: String, var kind: String, current_major: Int, oldest_major_read: Int):
        self.name = name^
        self.kind = kind^
        self.current_major = current_major
        self.oldest_major_read = oldest_major_read


def format_table() -> List[FormatRow]:
    """Every document, authored files first."""
    var t = List[FormatRow]()
    t.append(FormatRow(String(FORMAT_ARTIFACTS), String(KIND_AUTHORED), 1, 1))
    t.append(FormatRow(String(FORMAT_CELLS), String(KIND_AUTHORED), 1, 1))
    t.append(FormatRow(String(FORMAT_CHANNELS), String(KIND_AUTHORED), 1, 1))
    t.append(FormatRow(String(FORMAT_MACHINE), String(KIND_AUTHORED), 1, 1))
    t.append(FormatRow(String(FORMAT_ARTIFACT_MANIFEST), String(KIND_PRODUCED), 1, 1))
    t.append(FormatRow(String(FORMAT_CONDA_METADATA), String(KIND_PRODUCED), 1, 1))
    # Major 1 was `"schema": "kci.release_set.v1"`, written before the
    # release identity carried a revision and a platform. It is no longer
    # read: a release directory is rebuilt, never carried across kci versions.
    t.append(FormatRow(String(FORMAT_RELEASE_SET), String(KIND_PRODUCED), 2, 2))
    t.append(FormatRow(String(FORMAT_RESULT), String(KIND_PRODUCED), 1, 1))
    return t^


def format_row(name: String) raises -> FormatRow:
    """The row of format `name`; raises on a name not in the table."""
    var t = format_table()
    for i in range(len(t)):
        if t[i].name == name:
            return t[i].copy()
    raise Error(String("format '") + name + String("' is not in kci's format table"))


def current_major(name: String) raises -> Int:
    """The major this kci writes for format `name`."""
    return format_row(name).current_major


def _range_refusal(row: FormatRow, source: String, found: Int) raises:
    if found > row.current_major:
        raise Error(
            source + String(": schema_version ") + String(found)
            + String(" needs a newer kci (this kci reads ") + row.name
            + String(" up to major ") + String(row.current_major) + String(")")
        )
    if found < row.oldest_major_read:
        var span = String(row.oldest_major_read)
        if row.current_major != row.oldest_major_read:
            span += String("..") + String(row.current_major)
        raise Error(
            source + String(": schema_version ") + String(found)
            + String(" is no longer read (this kci reads ") + row.name
            + String(" major ") + span + String(")")
        )


def check_authored_version(name: String, source: String, present: Bool, found: Int) raises:
    """Refuse an authored file's version (file header). `present` is whether
    the file states `schema_version` at all; `found` is its value."""
    var row = format_row(name)
    if row.kind != KIND_AUTHORED:
        raise Error(String("format '") + name + String("' is not an authored file"))
    if not present:
        raise Error(
            source + String(": no schema_version; add `schema_version: ")
            + String(row.current_major) + String("` (this kci reads ") + row.name
            + String(" up to major ") + String(row.current_major) + String(")")
        )
    _range_refusal(row, source, found)


def check_produced_version(name: String, source: String, found_format: String, found: Int) raises:
    """Refuse a produced document's `format` and `schema_version` (file
    header)."""
    var row = format_row(name)
    if row.kind != KIND_PRODUCED:
        raise Error(String("format '") + name + String("' is not a produced document"))
    if found_format != row.name:
        raise Error(
            source + String(": format '") + found_format + String("' is not '") + row.name
            + String("'")
        )
    _range_refusal(row, source, found)


def produced_header(doc: JsonValue, name: String, source: String) raises -> Int:
    """Read and check a produced JSON document's `format` and
    `schema_version`; return the major. Refuses a missing key, a `format`
    that is not a string and a `schema_version` that is not an integer."""
    if not doc.is_object():
        raise Error(source + String(": not a JSON object"))
    if not doc.has(String(FORMAT_KEY)):
        raise Error(source + String(": no 'format' (a ") + name + String(" document names its format)"))
    if not doc.has(String(SCHEMA_VERSION_KEY)):
        raise Error(source + String(": no 'schema_version'"))
    var f = doc.get(String(FORMAT_KEY))
    if f.kind_tag() != JSON_STRING:
        raise Error(source + String(": 'format' is not a string"))
    var v = doc.get(String(SCHEMA_VERSION_KEY))
    if v.kind_tag() != JSON_NUMBER or not v.is_integral_number():
        raise Error(source + String(": 'schema_version' is not an integer"))
    var major = Int(v.as_int64())
    check_produced_version(name, source, f.as_string(), major)
    return major


def unknown_keys(doc: JsonValue, known: List[String]) raises -> List[String]:
    """The keys of object `doc` that are not in `known`, in document order:
    what a reader of a produced document ignores (file header)."""
    var out = List[String]()
    for i in range(doc.num_members()):
        var key = doc.key_at(i)
        var ok = False
        for j in range(len(known)):
            if known[j] == key:
                ok = True
        if not ok:
            out.append(key^)
    return out^
