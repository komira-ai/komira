# =============================================================================
# parquet_files -- a Parquet table that is a file, a glob or a directory
# =============================================================================
#
# `resolve_parquet_source` turns the path a user names into the
# `ParquetSource` a scan reads:
#
#   * a file: that file;
#   * a glob (`*`, `?`, `[...]`, `{a,b}`, one `**`, the syntax of `fs.glob`):
#     every file it matches, sorted byte-wise;
#   * a directory (only when the caller allows it, as `register_parquet`
#     does): the glob `<dir>/**/*.parquet`, with a file or directory whose
#     name starts with `.` skipped. A directory named in SQL is refused
#     (`PARQUET_PATH_IS_DIRECTORY`): DuckDB reads a glob, not a bare directory.
#
# No file matching is `PARQUET_GLOB_NO_MATCH`. Every file must have exactly the
# first file's schema (names, order, Arrow type, decimal precision and scale,
# time zone, nullability), else `PARQUET_FILES_SCHEMA_MISMATCH` names the first
# file, the other file and the column. Each file's footer is read through the
# caller's footer reader, so a file replaced after its footer was read is
# refused by name.
#
# Hive partitioning follows DuckDB's `HivePartitioning::Parse` over the whole
# path text: a component counts only if a `/` ends it (so never the file name),
# holds exactly one `=` that is not its first byte, and holds no `?` or newline;
# the key is the text before the `=`, the value the text after it.
#
#   * AUTO: partition columns exist when the first file has at least one key and
#     every file has the same key set; otherwise there are none.
#   * ON: the same, but a file whose key set differs from the first file's is
#     refused (`HIVE_PARTITION_LAYOUT_MISMATCH`).
#   * OFF: no partition columns.
#
# Partition columns follow the data columns, ordered by key name byte-wise, each
# not nullable. A value is percent-decoded (`%XX` only). A key repeated in one
# path, a malformed escape, an empty value, `NULL` in any case and
# `__HIVE_DEFAULT_PARTITION__` are `HIVE_PARTITION_VALUE_UNSUPPORTED`; a key
# equal, ignoring case, to a data column is `HIVE_PARTITION_COLUMN_IN_FILE`.
#
# The type of a partition column follows DuckDB's sequential autocast over the
# files in sorted order: the first value picks DATE (`YYYY-MM-DD`, a real
# calendar date), else TIMESTAMP (`YYYY-MM-DD HH:MM:SS`), else BIGINT (an
# optional `-` and ASCII digits that fit Int64), else VARCHAR; a later value
# that does not parse as the current type makes the column VARCHAR for good.
# A value DuckDB's cast might read as a date, timestamp or integer but those
# strict forms do not (surrounding white space, a leading `+` before a digit,
# a `T` separator, fractional seconds, one-digit month or day, `/` or `.` as a
# date separator) is `HIVE_PARTITION_VALUE_UNSUPPORTED`: the engine does not
# guess what DuckDB's cast accepts.
#
# The partition values kept in the source are the decoded text (`007` stays
# `007`).
# =============================================================================

from arrow.arrow_types import ArrowType
from arrow.schema import Field, Schema
from async_rt.ops.waker_sink import NoopSink
from fs.file_discovery import EagerGlobDiscovery, GlobDiscoveryOptions
from fs.glob import has_glob
from fs.local_fs import LocalFs
from fs.partition_codec import HIVE_DEFAULT_PARTITION, parse_partition_value
from scan_source.parquet_source import ParquetSource
from sql.sql_ast import HIVE_PARTITIONING_OFF, HIVE_PARTITIONING_ON
from sql.sql_bind_parquet import SqlParquetFooters

comptime PARQUET_GLOB_NO_MATCH = "PARQUET_GLOB_NO_MATCH"
comptime PARQUET_PATH_IS_DIRECTORY = "PARQUET_PATH_IS_DIRECTORY"
comptime PARQUET_FILES_SCHEMA_MISMATCH = "PARQUET_FILES_SCHEMA_MISMATCH"
comptime HIVE_PARTITION_LAYOUT_MISMATCH = "HIVE_PARTITION_LAYOUT_MISMATCH"
comptime HIVE_PARTITION_VALUE_UNSUPPORTED = "HIVE_PARTITION_VALUE_UNSUPPORTED"
comptime HIVE_PARTITION_COLUMN_IN_FILE = "HIVE_PARTITION_COLUMN_IN_FILE"

comptime _Fs = LocalFs[NoopSink]

comptime _TYPE_DATE = 0
comptime _TYPE_TIMESTAMP = 1
comptime _TYPE_BIGINT = 2
comptime _TYPE_VARCHAR = 3


# -----------------------------------------------------------------------------
# Small byte helpers
# -----------------------------------------------------------------------------


def _text(s: String, start: Int, end: Int) -> String:
    """The bytes `[start, end)` of `s`, byte-exact."""
    var bs = s.as_bytes()
    return String(StringSlice(unsafe_from_utf8=bs[start:end]))


def _is_digit(b: UInt8) -> Bool:
    return b >= UInt8(ord("0")) and b <= UInt8(ord("9"))


def _is_space(b: UInt8) -> Bool:
    return (
        b == UInt8(ord(" "))
        or b == UInt8(9)
        or b == UInt8(10)
        or b == UInt8(11)
        or b == UInt8(12)
        or b == UInt8(13)
    )


def _two(v: String, at: Int) -> Int:
    """The value of the two ASCII digits of `v` at `at`."""
    var bs = v.as_bytes()
    return (Int(bs[at]) - ord("0")) * 10 + (Int(bs[at + 1]) - ord("0"))


# -----------------------------------------------------------------------------
# Strict value forms
# -----------------------------------------------------------------------------


def _days_in_month(year: Int, month: Int) -> Int:
    if month == 2:
        var leap = (year % 4 == 0 and year % 100 != 0) or year % 400 == 0
        return 29 if leap else 28
    if month == 4 or month == 6 or month == 9 or month == 11:
        return 30
    return 31


def _starts_with_date(v: String) -> Bool:
    """The first ten bytes of `v` are `YYYY-MM-DD` and a real calendar date."""
    var bs = v.as_bytes()
    if len(bs) < 10:
        return False
    for i in range(10):
        if i == 4 or i == 7:
            if bs[i] != UInt8(ord("-")):
                return False
        elif not _is_digit(bs[i]):
            return False
    var year = _two(v, 0) * 100 + _two(v, 2)
    var month = _two(v, 5)
    var day = _two(v, 8)
    if month < 1 or month > 12:
        return False
    return day >= 1 and day <= _days_in_month(year, month)


def _is_date(v: String) -> Bool:
    return v.byte_length() == 10 and _starts_with_date(v)


def _is_timestamp(v: String) -> Bool:
    var bs = v.as_bytes()
    if len(bs) != 19 or not _starts_with_date(v):
        return False
    if bs[10] != UInt8(ord(" ")):
        return False
    for i in range(11, 19):
        if i == 13 or i == 16:
            if bs[i] != UInt8(ord(":")):
                return False
        elif not _is_digit(bs[i]):
            return False
    return _two(v, 11) <= 23 and _two(v, 14) <= 59 and _two(v, 17) <= 59


def _is_bigint(v: String) -> Bool:
    """An optional `-`, then one or more ASCII digits, within Int64."""
    var bs = v.as_bytes()
    var start = 0
    var negative = False
    if len(bs) > 0 and bs[0] == UInt8(ord("-")):
        start = 1
        negative = True
    if start >= len(bs):
        return False
    for i in range(start, len(bs)):
        if not _is_digit(bs[i]):
            return False
    var first = start
    while first < len(bs) - 1 and bs[first] == UInt8(ord("0")):
        first += 1
    var digits = len(bs) - first
    if digits > 19:
        return False
    if digits < 19:
        return True
    var limit = String("9223372036854775808") if negative else String(
        "9223372036854775807"
    )
    var lb = limit.as_bytes()
    for i in range(19):
        var a = bs[first + i]
        var b = lb[i]
        if a < b:
            return True
        if a > b:
            return False
    return True


def _classify(v: String) -> Int:
    if _is_date(v):
        return _TYPE_DATE
    if _is_timestamp(v):
        return _TYPE_TIMESTAMP
    if _is_bigint(v):
        return _TYPE_BIGINT
    return _TYPE_VARCHAR


def _guessable_but_not_strict(v: String) -> Bool:
    """True for a value DuckDB's cast might read as a date, timestamp or
    integer while the strict forms do not: (a) surrounding white space around
    something, (b) a `+` before a digit, (c) a digit first and only digits and
    `-/.: T` after, with a `-`, `/` or `:` among them, that is neither a strict
    date nor a strict timestamp."""
    var bs = v.as_bytes()
    var n = len(bs)
    if n == 0:
        return False
    if _is_space(bs[0]) or _is_space(bs[n - 1]):
        var blank = True
        for i in range(n):
            if not _is_space(bs[i]):
                blank = False
        if not blank:
            return True
    if n >= 2 and bs[0] == UInt8(ord("+")) and _is_digit(bs[1]):
        return True
    if _is_digit(bs[0]):
        var only_numeric = True
        var separated = False
        for i in range(n):
            var b = bs[i]
            if b == UInt8(ord("-")) or b == UInt8(ord("/")) or b == UInt8(
                ord(":")
            ):
                separated = True
            elif not (
                _is_digit(b)
                or b == UInt8(ord("."))
                or b == UInt8(ord(" "))
                or b == UInt8(ord("T"))
            ):
                only_numeric = False
        if only_numeric and separated:
            return not (_is_date(v) or _is_timestamp(v))
    return False


# -----------------------------------------------------------------------------
# Listing the files
# -----------------------------------------------------------------------------


def _under_hidden_name(path: String, root: String) -> Bool:
    """`path`, below `root` (which ends in `/`), has a component that starts
    with `.`. A path outside `root` has none."""
    var bs = path.as_bytes()
    var rb = root.as_bytes()
    if len(bs) < len(rb):
        return False
    for i in range(len(rb)):
        if bs[i] != rb[i]:
            return False
    var at_start = True
    for i in range(len(rb), len(bs)):
        if at_start and bs[i] == UInt8(ord(".")):
            return True
        at_start = bs[i] == UInt8(ord("/"))
    return False


def _is_directory(mut fs: _Fs, path: String) -> Bool:
    """`fs.is_dir` raises for a path that is not there; that is no directory."""
    try:
        return fs.is_dir(path)
    except:
        return False


def _discover(mut fs: _Fs, pattern: String) raises -> List[String]:
    var found = EagerGlobDiscovery.open_with_options(
        fs, pattern, GlobDiscoveryOptions(allow_empty_glob=True)
    )
    var out = List[String]()
    for i in range(found.num_paths()):
        out.append(found.path_at(i))
    return out^


def _list_files(path: String, allow_directory: Bool) raises -> List[String]:
    """The files `path` names, sorted: one for a plain file, the matches of a
    glob, or the `.parquet` files under a directory."""
    var fs = _Fs.new()
    var files = List[String]()
    if has_glob(path):
        files = _discover(fs, path)
        if len(files) == 0:
            raise Error(
                PARQUET_GLOB_NO_MATCH + ": no file matches '" + path + "'"
            )
        return files^
    if not _is_directory(fs, path):
        files.append(path.copy())
        return files^
    if not allow_directory:
        raise Error(
            PARQUET_PATH_IS_DIRECTORY
            + ": '"
            + path
            + "' is a directory; name a glob such as '"
            + path
            + "/**/*.parquet'"
        )
    var root = path.copy()
    while root.byte_length() > 1 and root.endswith("/"):
        root = _text(root, 0, root.byte_length() - 1)
    var listed = _discover(fs, root + "/**/*.parquet")
    for i in range(len(listed)):
        if not _under_hidden_name(listed[i], root + "/"):
            files.append(listed[i].copy())
    if len(files) == 0:
        raise Error(
            PARQUET_GLOB_NO_MATCH
            + ": the directory '"
            + path
            + "' holds no .parquet file"
        )
    return files^


# -----------------------------------------------------------------------------
# The schemas of the files
# -----------------------------------------------------------------------------


def _schema_difference(first: Schema, other: Schema) -> String:
    """The first way `other` differs from `first`, or "" when they are equal."""
    if other.num_columns() != first.num_columns():
        return (
            "it has "
            + String(other.num_columns())
            + " columns, the first file has "
            + String(first.num_columns())
        )
    for i in range(first.num_columns()):
        var name = first.field_name(i)
        if other.field_name(i) != name:
            return (
                "column "
                + String(i)
                + " is '"
                + other.field_name(i)
                + "', the first file has '"
                + name
                + "'"
            )
        if other.field_arrow_type(i) != first.field_arrow_type(i):
            return (
                "column '"
                + name
                + "' is "
                + String(other.field_arrow_type(i))
                + ", the first file has "
                + String(first.field_arrow_type(i))
            )
        if (
            first.field_arrow_type(i) == ArrowType.DECIMAL128
            and (
                other.field_decimal_precision(i)
                != first.field_decimal_precision(i)
                or other.field_decimal_scale(i) != first.field_decimal_scale(i)
            )
        ):
            return (
                "column '"
                + name
                + "' is decimal("
                + String(other.field_decimal_precision(i))
                + ", "
                + String(other.field_decimal_scale(i))
                + "), the first file has decimal("
                + String(first.field_decimal_precision(i))
                + ", "
                + String(first.field_decimal_scale(i))
                + ")"
            )
        if other.field_tz(i) != first.field_tz(i):
            return (
                "column '"
                + name
                + "' has time zone '"
                + other.field_tz(i)
                + "', the first file has '"
                + first.field_tz(i)
                + "'"
            )
        if other.field_nullable(i) != first.field_nullable(i):
            return (
                "column '"
                + name
                + "' is "
                + ("nullable" if other.field_nullable(i) else "not null")
                + ", the first file has it "
                + ("nullable" if first.field_nullable(i) else "not null")
            )
    return String("")


# -----------------------------------------------------------------------------
# Hive keys and values
# -----------------------------------------------------------------------------


def _hive_pairs(
    path: String, mut keys: List[String], mut values: List[String]
) raises:
    """The `key=value` components of `path`, in path order, values still
    percent-encoded. A component counts only if a `/` ends it."""
    var bs = path.as_bytes()
    var start = 0
    for i in range(len(bs)):
        if bs[i] != UInt8(ord("/")):
            continue
        var eq = -1
        var equals = 0
        var barred = False
        for j in range(start, i):
            if bs[j] == UInt8(ord("=")):
                equals += 1
                if eq < 0:
                    eq = j
            elif bs[j] == UInt8(ord("?")) or bs[j] == UInt8(10):
                barred = True
        if equals == 1 and eq > start and not barred:
            var key = _text(path, start, eq)
            for k in range(len(keys)):
                if keys[k] == key:
                    raise Error(
                        HIVE_PARTITION_VALUE_UNSUPPORTED
                        + ": the key '"
                        + key
                        + "' appears twice in '"
                        + path
                        + "'"
                    )
            keys.append(key^)
            values.append(_text(path, eq + 1, i))
        start = i + 1


def _sorted_copy(keys: List[String]) -> List[String]:
    var out = List[String]()
    for i in range(len(keys)):
        var at = len(out)
        while at > 0 and out[at - 1] > keys[i]:
            at -= 1
        out.insert(at, keys[i].copy())
    return out^


def _decode_value(path: String, key: String, raw: String) raises -> String:
    """The decoded value of partition `key` in `path`, or a refusal."""
    var head = (
        HIVE_PARTITION_VALUE_UNSUPPORTED
        + ": the value of '"
        + key
        + "' in '"
        + path
        + "' "
    )
    if raw == HIVE_DEFAULT_PARTITION:
        raise Error(head + "is a NULL partition, which is not read yet")
    var decoded = String("")
    try:
        decoded = parse_partition_value(raw, ArrowType.STRING)
    except:
        raise Error(head + "has a malformed percent escape")
    if decoded.byte_length() == 0:
        raise Error(head + "is empty")
    if decoded.lower() == "null":
        raise Error(head + "is NULL, which is not read yet")
    if _guessable_but_not_strict(decoded):
        raise Error(
            head
            + "is '"
            + decoded
            + "', which DuckDB may read as a date, timestamp or integer but"
            " is not in the form YYYY-MM-DD, YYYY-MM-DD HH:MM:SS or digits"
        )
    return decoded^


def _same_keys(a: List[String], b: List[String]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def _hive_columns(
    files: List[String],
    data: Schema,
    mode: UInt8,
    mut cols: List[Field],
    mut table: List[List[String]],
) raises:
    """Fill `cols` and `table` (one row of decoded values per file) with the
    partition columns of `files`, or leave them empty when there are none."""
    if mode == HIVE_PARTITIONING_OFF:
        return
    var raw_keys = List[List[String]]()
    var raw_values = List[List[String]]()
    var sorted_keys = List[List[String]]()
    for f in range(len(files)):
        var keys = List[String]()
        var values = List[String]()
        _hive_pairs(files[f], keys, values)
        sorted_keys.append(_sorted_copy(keys))
        raw_keys.append(keys^)
        raw_values.append(values^)
    if len(sorted_keys[0]) == 0:
        return
    var uniform = True
    for f in range(1, len(files)):
        if not _same_keys(sorted_keys[0], sorted_keys[f]):
            if mode == HIVE_PARTITIONING_ON:
                raise Error(
                    HIVE_PARTITION_LAYOUT_MISMATCH
                    + ": '"
                    + files[f]
                    + "' has partition keys that differ from those of '"
                    + files[0]
                    + "'"
                )
            uniform = False
    if not uniform:
        return
    var names = sorted_keys[0].copy()
    for c in range(len(names)):
        for d in range(data.num_columns()):
            if data.field_name(d).lower() == names[c].lower():
                raise Error(
                    HIVE_PARTITION_COLUMN_IN_FILE
                    + ": the partition key '"
                    + names[c]
                    + "' of '"
                    + files[0]
                    + "' is also the column '"
                    + data.field_name(d)
                    + "' of the files"
                )
    for f in range(len(files)):
        var row = List[String]()
        for c in range(len(names)):
            for k in range(len(raw_keys[f])):
                if raw_keys[f][k] == names[c]:
                    row.append(_decode_value(files[f], names[c], raw_values[f][k]))
        table.append(row^)
    for c in range(len(names)):
        var kind = -1
        for f in range(len(files)):
            var seen = _classify(table[f][c])
            if kind < 0:
                kind = seen
            elif kind != _TYPE_VARCHAR and seen != kind:
                kind = _TYPE_VARCHAR
        var arrow = ArrowType.STRING
        if kind == _TYPE_DATE:
            arrow = ArrowType.DATE32
        elif kind == _TYPE_TIMESTAMP:
            arrow = ArrowType.TIMESTAMP_US
        elif kind == _TYPE_BIGINT:
            arrow = ArrowType.INT64
        cols.append(Field(names[c], arrow, False))


# -----------------------------------------------------------------------------
# The entry point
# -----------------------------------------------------------------------------


def resolve_parquet_source[
    F: SqlParquetFooters
](
    footers: F, path: String, hive_partitioning: UInt8, allow_directory: Bool
) raises -> ParquetSource:
    """The source a read of `path` scans: its files listed and sorted, each
    checked against the first file's schema, with the Hive partition columns
    `hive_partitioning` (a `HIVE_PARTITIONING_*` mode) asks for.

    One file without partition columns gives `ParquetSource(path, schema)`.

    Raises:
        Error starting with `PARQUET_GLOB_NO_MATCH`, `PARQUET_PATH_IS_DIRECTORY`
        (a directory while `allow_directory` is False),
        `PARQUET_FILES_SCHEMA_MISMATCH`, `HIVE_PARTITION_LAYOUT_MISMATCH`,
        `HIVE_PARTITION_VALUE_UNSUPPORTED` or `HIVE_PARTITION_COLUMN_IN_FILE`,
        or an error naming a file whose footer does not read.
    """
    var files = _list_files(path, allow_directory)
    var first = footers.footer_schema(files[0])
    for i in range(1, len(files)):
        var other = footers.footer_schema(files[i])
        var difference = _schema_difference(first, other)
        if difference.byte_length() > 0:
            raise Error(
                PARQUET_FILES_SCHEMA_MISMATCH
                + ": '"
                + files[i]
                + "' differs from '"
                + files[0]
                + "': "
                + difference
            )
    var cols = List[Field]()
    var table = List[List[String]]()
    _hive_columns(files, first, hive_partitioning, cols, table)
    if len(files) == 1 and len(cols) == 0:
        return ParquetSource(files[0].copy(), first^)
    return ParquetSource.partitioned(files^, first^, cols^, table^)
