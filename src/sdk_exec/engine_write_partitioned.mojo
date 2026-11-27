# =============================================================================
# engine_write_partitioned -- write a query's result as a Hive-partitioned
# directory tree: COPY ... TO '<dir>' (PARTITION_BY (<columns>))
# =============================================================================
#
#   COPY (SELECT id, amount, year, month FROM sales)
#   TO 'out' (FORMAT parquet, PARTITION_BY (year, month))
#
# writes, as the pinned DuckDB (v1.5.6) writes it:
#
#   out/year=2027/month=1/data_0.parquet
#   out/year=2027/month=2/data_0.parquet
#   out/year=2028/month=1/data_0.parquet
#
# One directory level per PARTITION_BY column, in the list's order, and one
# file per distinct combination of their values, named `data_0` with the
# format's extension: `.parquet`, or `.csv` with `.gz` or `.zst` when the CSV
# is compressed. A file holds the rows of its combination in the result's
# order, and every result column but the partition columns (DuckDB writes
# them only with WRITE_PARTITION_COLUMNS, which is refused). The answer is
# DuckDB's: one BIGINT `Count`, every row written.
#
# A directory is `<column>=<value>`, both escaped as DuckDB's
# `StringUtil::URLEncode` escapes them (fs/partition_codec, HIVE_WRITER_URI):
# every byte but ASCII letters, digits and `- _ . ~` becomes `%XX`, upper-case
# hex (`a/b` is `a%2Fb`, `é` is `%C3%A9`). The value is the text DuckDB casts
# it to: an integer's digits, `true` / `false`, a DATE as `YYYY-MM-DD` (a year
# before 1 as `... (BC)`), a DECIMAL with its scale's digits (`1.50`), a
# string as it is. NULL is `__HIVE_DEFAULT_PARTITION__`, and so is the string
# `__HIVE_DEFAULT_PARTITION__` (DuckDB writes it unescaped too, and reads it
# back as NULL); the empty string is an empty value (`k=`).
#
# Refused by name before any directory or file is made:
#   COPY_TARGET_EXISTS     the target is a file, or a directory holding
#                          anything, a hidden file included (step `bind`), as
#                          DuckDB refuses both; OVERWRITE, OVERWRITE_OR_IGNORE
#                          and APPEND are refused options
#   STORAGE_NOT_FOUND      the target's parent directory does not exist; it is
#                          not made (step `bind`)
#   COPY_TYPE_UNSUPPORTED  a partition column of a type whose directory name
#                          is not written yet (floats, timestamps, times,
#                          intervals, binary, nested), or a written column the
#                          file's writer refuses (step `execute`)
#   COPY_DUPLICATE_COLUMN  CSV with two written columns of one name
#                          (engine_write.check_copy_columns; step `execute`)
#
# The target directory is made when it does not exist (its parent must), so
# an empty result leaves an empty directory, as DuckDB does. The whole result
# is held in memory and grouped there, as a COPY to one file holds it; each
# file is written whole with `write_file_atomic`, but the tree is not one
# atomic unit: a failure after the first file leaves the files written so far.

from std.collections import Dict
from std.os import listdir, makedirs, mkdir
from std.os.path import exists, isdir

from arrow.arrow_types import ArrowType
from arrow.schema import RecordBatch
from arrow.write_target import WCOMP_GZIP, WCOMP_ZSTD, WFMT_PARQUET
from column_kernels.compiler_helpers import (
    gather_batch,
    materialize_selection_if_present,
    project_batch_by_names,
)
from fs.atomic_write import STORAGE_IO, STORAGE_NOT_FOUND
from fs.partition_codec import (
    HIVE_DEFAULT_PARTITION,
    HIVE_WRITER_URI,
    partition_value_spelling_for,
)

from .engine_write import (
    COPY_TYPE_UNSUPPORTED,
    check_copy_columns,
    write_copy_result,
)
from .engine_write_text import date_text, decimal_text

comptime COPY_TARGET_EXISTS = "COPY_TARGET_EXISTS"
"""Refusal (step `bind`): a partitioned COPY whose target is a file or a
directory that holds anything."""

comptime PARTITION_FILE_STEM = "data_0"
"""The name, before its extension, of the one file in each partition
directory, as DuckDB names it."""


def _trimmed(dest: String) -> String:
    """`dest` without trailing `/` (DuckDB writes `out/` as `out`)."""
    var end = dest.byte_length()
    while end > 1 and dest.as_bytes()[end - 1] == UInt8(ord("/")):
        end -= 1
    return String(dest[byte = 0:end])


def _parent(dir: String) -> String:
    """The directory `dir` is made in: what comes before its last `/` (`/`
    for a name at the root), and `.` for a bare name."""
    var slash = dir.rfind("/")
    if slash < 0:
        return String(".")
    return String(dir[byte = 0 : max(slash, 1)])


def _clause(partition_by: List[String]) -> String:
    var s = String("PARTITION_BY (")
    for i in range(len(partition_by)):
        if i > 0:
            s += ", "
        s += partition_by[i]
    return s + ")"


def check_partitioned_target(dest: String, partition_by: List[String]) raises:
    """Refuse a partitioned COPY to `dest` that DuckDB refuses, before the
    query runs: `dest` is a file or a directory holding anything
    (`COPY_TARGET_EXISTS`), or a path whose parent directory does not exist
    (`STORAGE_NOT_FOUND`)."""
    var dir = _trimmed(dest)
    var what = "COPY ... TO '" + dest + "' (" + _clause(partition_by) + ")"
    if exists(dir):
        if not isdir(dir):
            raise Error(
                String(COPY_TARGET_EXISTS) + ": " + what
                + ": it is a file, not a directory; OVERWRITE is not supported"
            )
        if len(listdir(dir)) > 0:
            raise Error(
                String(COPY_TARGET_EXISTS) + ": " + what
                + ": the directory is not empty; OVERWRITE, OVERWRITE_OR_IGNORE"
                " and APPEND are not supported"
            )
        return
    var parent = _parent(dir)
    if not isdir(parent):
        raise Error(
            String(STORAGE_NOT_FOUND) + ": " + what + ": the directory '"
            + parent + "' does not exist"
        )


def _partition_type_written(at: ArrowType) -> Bool:
    """True for a type whose directory text `_segments` writes."""
    return (
        at == ArrowType.BOOL
        or at == ArrowType.INT8
        or at == ArrowType.INT16
        or at == ArrowType.INT32
        or at == ArrowType.INT64
        or at == ArrowType.UINT8
        or at == ArrowType.UINT16
        or at == ArrowType.UINT32
        or at == ArrowType.UINT64
        or at == ArrowType.STRING
        or at == ArrowType.LARGE_STRING
        or at == ArrowType.DICTIONARY
        or at == ArrowType.DATE32
        or at == ArrowType.DECIMAL128
    )


def partition_value_segment(value: Optional[String]) -> String:
    """The escaped directory text of one partition value, as DuckDB writes
    it: `__HIVE_DEFAULT_PARTITION__` for NULL, nothing for the empty string,
    and the value URL-escaped otherwise (module header)."""
    if not value:
        return HIVE_DEFAULT_PARTITION
    if value.value().byte_length() == 0:
        return String("")
    return partition_value_spelling_for(
        value.value(), ArrowType.STRING, HIVE_WRITER_URI
    )


def _int_values[
    dtype: DType
](batch: RecordBatch, c: Int, mut out: List[Optional[String]]) raises:
    var arr = batch.column_at(c).as_primitive[dtype]()
    for r in range(batch.num_rows()):
        if arr.is_null(r):
            out.append(None)
        else:
            out.append(String(arr.get(r)))


def _values(batch: RecordBatch, c: Int) raises -> List[Optional[String]]:
    """Each row's value of column `c` as DuckDB's VARCHAR text, None for
    NULL. The column's type is `_partition_type_written`."""
    var out = List[Optional[String]](capacity=batch.num_rows())
    var at = batch.schema.field_arrow_type(c)
    ref col = batch.column_at(c)
    if at == ArrowType.INT64:
        _int_values[DType.int64](batch, c, out)
    elif at == ArrowType.INT32:
        _int_values[DType.int32](batch, c, out)
    elif at == ArrowType.INT16:
        _int_values[DType.int16](batch, c, out)
    elif at == ArrowType.INT8:
        _int_values[DType.int8](batch, c, out)
    elif at == ArrowType.UINT64:
        _int_values[DType.uint64](batch, c, out)
    elif at == ArrowType.UINT32:
        _int_values[DType.uint32](batch, c, out)
    elif at == ArrowType.UINT16:
        _int_values[DType.uint16](batch, c, out)
    elif at == ArrowType.UINT8:
        _int_values[DType.uint8](batch, c, out)
    elif at == ArrowType.BOOL:
        var arr = col.as_boolean()
        for r in range(batch.num_rows()):
            if arr.is_null(r):
                out.append(None)
            else:
                out.append(String("true") if arr.get(r) else String("false"))
    elif at == ArrowType.DATE32:
        var arr = col.as_primitive[DType.int32]()
        for r in range(batch.num_rows()):
            if arr.is_null(r):
                out.append(None)
            else:
                out.append(date_text(arr.get(r)))
    elif at == ArrowType.DECIMAL128:
        var arr = col.as_decimal128()
        for r in range(batch.num_rows()):
            if arr.is_null(r):
                out.append(None)
            else:
                out.append(decimal_text(arr.get_i128(r), arr.scale))
    elif col.arrow_type == ArrowType.DICTIONARY:
        # Dictionary codes are not offsets: decode through the dictionary.
        var arr = batch.column_as_string(c)
        for r in range(batch.num_rows()):
            if arr.is_null(r):
                out.append(None)
            else:
                out.append(String(arr.get(r)))
    else:
        for r in range(batch.num_rows()):
            if col.utf8_is_null_at(r):
                out.append(None)
            else:
                out.append(col.utf8_value_at(r))
    return out^


def partition_file_name(fmt: UInt8, codec: UInt8) -> String:
    """The name of the file in each partition directory: `data_0.parquet`
    for Parquet, `data_0.csv` for CSV, with `.gz` or `.zst` when the CSV is
    compressed with gzip or zstd."""
    if fmt == WFMT_PARQUET:
        return String(PARTITION_FILE_STEM) + ".parquet"
    var name = String(PARTITION_FILE_STEM) + ".csv"
    if codec == WCOMP_GZIP:
        name += ".gz"
    elif codec == WCOMP_ZSTD:
        name += ".zst"
    return name^


def write_partitioned_result(
    var batch: RecordBatch,
    dest: String,
    fmt: UInt8,
    codec: UInt8,
    partition_by: List[String],
) raises -> Int:
    """Write `batch` under the directory `dest` partitioned by the columns
    `partition_by` (result column names, `check_partitioned_target` already
    passed), one `partition_file_name` file per distinct combination of
    their values in the WFMT_* format `fmt` with the WCOMP_* `codec`, and
    return the rows written (the module header says what is written).

    Raises:
        `COPY_TYPE_UNSUPPORTED` naming the first partition column
        of a type that is not written, or `check_copy_columns`' refusal of
        the columns written, before any directory is made; `STORAGE_IO` when
        a directory cannot be made; `write_file_atomic`'s errors.
    """
    var rows = materialize_selection_if_present(batch^)
    var key_cols = List[Int]()
    for i in range(len(partition_by)):
        var c = rows.schema.column_index(partition_by[i])
        var at = rows.schema.field_arrow_type(c)
        if not _partition_type_written(at):
            raise Error(
                String(COPY_TYPE_UNSUPPORTED) + ": COPY ... TO '"
                + dest + "' (" + _clause(partition_by) + "): column '"
                + partition_by[i] + "' has type " + String(at)
                + ", which is not written as a partition directory name yet"
            )
        key_cols.append(c)
    var data_names = List[String]()
    for c in range(rows.num_columns()):
        if c not in key_cols:
            data_names.append(rows.schema.field_name(c))
    var file = partition_file_name(fmt, codec)
    var dir = _trimmed(dest)
    check_copy_columns(project_batch_by_names(rows, data_names), dest, fmt)
    # The directory of each row: `<key>=<value>/...`, built column by column.
    var paths = List[String](capacity=rows.num_rows())
    for _ in range(rows.num_rows()):
        paths.append(String(""))
    for i in range(len(key_cols)):
        var key = partition_value_segment(
            Optional(rows.schema.field_name(key_cols[i]))
        )
        var values = _values(rows, key_cols[i])
        for r in range(rows.num_rows()):
            paths[r] += key + "=" + partition_value_segment(values[r]) + "/"
    # Group the rows by directory, in the order each directory first appears.
    var group_of = Dict[String, Int]()
    var groups = List[List[Int]]()
    var group_paths = List[String]()
    for r in range(rows.num_rows()):
        var g = group_of.get(paths[r])
        if g:
            groups[g.value()].append(r)
        else:
            group_of[paths[r]] = len(groups)
            groups.append([r])
            group_paths.append(paths[r])
    try:
        if not exists(dir):
            mkdir(dir)
        for g in range(len(groups)):
            makedirs(dir + "/" + group_paths[g], exist_ok=True)
    except e:
        raise Error(
            String(STORAGE_IO) + ": COPY ... TO '" + dest + "' ("
            + _clause(partition_by) + "): a directory cannot be made: "
            + String(e)
        )
    for g in range(len(groups)):
        var part = project_batch_by_names(gather_batch(rows, groups[g]), data_names)
        _ = write_copy_result(
            part^, dir + "/" + group_paths[g] + file, fmt, codec
        )
    return rows.num_rows()
