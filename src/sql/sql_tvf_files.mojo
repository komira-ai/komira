# =============================================================================
# sql/sql_tvf_files.mojo
#   The files a CSV or JSON Lines name reads, and the one schema they share.
# =============================================================================
#
# `read_csv('p')`, `read_json('p')`, `FROM 'p'` and `register_csv` /
# `register_json` take a name that is one file or a glob pattern, in the
# pattern syntax `read_parquet` takes (`fs.glob`: `*`, `?`, `[...]`, `{a,b}`
# and one `**`, which also matches no folder at all). `tvf_files` lists them:
#
#   * a name with no pattern character is that one file, not looked up here, so
#     a missing file keeps the reader's own refusal;
#   * a pattern is every regular file it matches, sorted byte-wise, as
#     `fs.file_discovery.EagerGlobDiscovery` returns them. A name that starts
#     with `.` is matched only by a pattern that spells the `.`. A pattern that
#     matches no file is `CSV_GLOB_NO_MATCH` / `JSON_GLOB_NO_MATCH`, naming it.
#
# The files of one pattern read as one table at one schema, inferred from each
# file and merged in file order, as one inference over all of their rows would
# settle it:
#
#   * CSV (`merge_csv_schema`): every file has the same columns, by name, in
#     the same order, else `CSV_FILES_SCHEMA_MISMATCH` names the file and the
#     column (DuckDB refuses such a set unless `union_by_name=true`, which is
#     refused by name here). A column's type is the first file's when every
#     file agrees; BIGINT and DOUBLE make DOUBLE; any other two types make
#     VARCHAR, the type the CSV inferrer gives a column of mixed cells. A
#     file with no value in a column (a header-only file) infers VARCHAR for
#     it, so that column reads as VARCHAR.
#   * JSON Lines (`merge_json_schema`): the keys of every file, in the order
#     they are first seen; a file without a key reads it as NULL, as a record
#     without it does. A key's type follows the JSON inferrer's own rule across
#     records: a NULL-only key takes the other type, BIGINT and DOUBLE make
#     DOUBLE, and any other two types are `JSON_FILES_SCHEMA_MISMATCH`, as two
#     such records in one file are refused.
# =============================================================================

from arrow.arrow_types import ArrowType
from arrow.schema import Field, Schema, SchemaBuilder
from async_rt.ops.waker_sink import NoopSink
from fs.file_discovery import EagerGlobDiscovery, GlobDiscoveryOptions
from fs.glob import has_glob
from fs.local_fs import LocalFs

comptime CSV_GLOB_NO_MATCH = "CSV_GLOB_NO_MATCH"
"""The refusal of a CSV pattern that matches no file."""
comptime JSON_GLOB_NO_MATCH = "JSON_GLOB_NO_MATCH"
"""The refusal of a JSON Lines pattern that matches no file."""
comptime CSV_FILES_SCHEMA_MISMATCH = "CSV_FILES_SCHEMA_MISMATCH"
"""The refusal of CSV files of one pattern whose columns differ."""
comptime JSON_FILES_SCHEMA_MISMATCH = "JSON_FILES_SCHEMA_MISMATCH"
"""The refusal of JSON Lines files of one pattern that give one key two types
no type holds."""

comptime _Fs = LocalFs[NoopSink]


def tvf_files(path: String, no_match: String) raises -> List[String]:
    """The files `path` names: `[path]` for a name with no pattern character,
    else every file the pattern matches, sorted byte-wise.

    Raises:
        `<no_match>: no file matches '<path>'` for a pattern that matches no
        file.
    """
    var files = List[String]()
    if not has_glob(path):
        files.append(path.copy())
        return files^
    var fs = _Fs.new()
    var found = EagerGlobDiscovery.open_with_options(
        fs, path, GlobDiscoveryOptions(allow_empty_glob=True)
    )
    for i in range(found.num_paths()):
        files.append(found.path_at(i))
    if len(files) == 0:
        raise Error(no_match + ": no file matches '" + path + "'")
    return files^


def _wider_csv_type(a: ArrowType, b: ArrowType) -> ArrowType:
    """The type a CSV column holds when one file infers `a` and another `b`."""
    if a == b:
        return a
    if (a == ArrowType.INT64 and b == ArrowType.FLOAT64) or (
        a == ArrowType.FLOAT64 and b == ArrowType.INT64
    ):
        return ArrowType.FLOAT64
    return ArrowType.STRING


def merge_csv_schema(
    merged: Schema, merged_from: String, other: Schema, other_path: String
) raises -> Schema:
    """`merged` (the schema of the files before `other_path`, the first of
    them `merged_from`) and `other` (the schema of `other_path`) as one.

    Raises:
        `CSV_FILES_SCHEMA_MISMATCH: '<other_path>' differs from
        '<merged_from>': <how>` when the column count or a column name at one
        position differs.
    """
    var head = (
        String(CSV_FILES_SCHEMA_MISMATCH)
        + ": '"
        + other_path
        + "' differs from '"
        + merged_from
        + "': "
    )
    if other.num_columns() != merged.num_columns():
        raise Error(
            head
            + "it has "
            + String(other.num_columns())
            + " columns, the first file has "
            + String(merged.num_columns())
        )
    var sb = SchemaBuilder()
    for i in range(merged.num_columns()):
        var f = merged.field_at_unchecked(i)
        var g = other.field_at_unchecked(i)
        if g.name != f.name:
            raise Error(
                head
                + "column "
                + String(i)
                + " is '"
                + g.name
                + "', the first file has '"
                + f.name
                + "'"
            )
        var t = _wider_csv_type(f.arrow_type, g.arrow_type)
        if t == f.arrow_type:
            var keep = f.copy()
            keep.nullable = f.nullable or g.nullable
            sb.add_field(keep)
        else:
            sb.add_field(Field(f.name, t, f.nullable or g.nullable))
    return sb.build()


def merge_json_schema(
    merged: Schema, merged_from: String, other: Schema, other_path: String
) raises -> Schema:
    """`merged` (the schema of the files before `other_path`, the first of
    them `merged_from`) and `other` (the schema of `other_path`) as one: the
    keys of `merged`, then the keys only `other` has.

    Raises:
        `JSON_FILES_SCHEMA_MISMATCH: column '<key>' is <type> in
        '<other_path>' and <type> in the files before it, from
        '<merged_from>'` for two types no type holds.
    """
    var sb = SchemaBuilder()
    var used = List[Bool]()
    for _ in range(other.num_columns()):
        used.append(False)
    for i in range(merged.num_columns()):
        var f = merged.field_at_unchecked(i)
        var j = -1
        for k in range(other.num_columns()):
            if other.field_name(k) == f.name:
                j = k
                break
        if j < 0:
            sb.add_field(f)
            continue
        used[j] = True
        var a = f.arrow_type
        var b = other.field_arrow_type(j)
        if a == b or b == ArrowType.NULL:
            sb.add_field(f)
        elif a == ArrowType.NULL:
            sb.add_field(other.field_at_unchecked(j))
        elif (a == ArrowType.INT64 and b == ArrowType.FLOAT64) or (
            a == ArrowType.FLOAT64 and b == ArrowType.INT64
        ):
            sb.add_field(Field(f.name, ArrowType.FLOAT64, True))
        else:
            raise Error(
                String(JSON_FILES_SCHEMA_MISMATCH)
                + ": column '"
                + f.name
                + "' is "
                + String(b)
                + " in '"
                + other_path
                + "' and "
                + String(a)
                + " in the files before it, from '"
                + merged_from
                + "'"
            )
    for k in range(other.num_columns()):
        if not used[k]:
            sb.add_field(other.field_at_unchecked(k))
    return sb.build()
