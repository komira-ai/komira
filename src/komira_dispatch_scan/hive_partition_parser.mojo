# =============================================================================
# hive_partition_parser — Hive-style partition path parsing +
# type inference.
# =============================================================================
#
# Given a list of parquet file paths like
#
#   data/year=2030/month=01/part-0.parquet
#   data/year=2030/month=02/part-1.parquet
#   data/year=2031/month=01/part-2.parquet
#
# this module:
#   1. parses out the `<key>=<value>` directory components from each path
#      (in path order), producing a per-path ordered list of (key, value);
#   2. validates that every path carries the same partition KEYS in the
#      same order (the partition LAYOUT must be consistent — DuckDB raises
#      otherwise; we do too);
#   3. infers each key's column TYPE from its values across all paths,
#      mirroring DuckDB's `hive_partitioning.cpp` inference order:
#        - BIGINT  (Int64) if every value parses as a signed integer;
#        - DATE    (Date32) if every value matches `YYYY-MM-DD`;
#        - else VARCHAR (String).
#   4. emits `(partition_col_fields, per_path_partition_values)` ready for
#      `ParquetSource.partitioned(...)`.
#
# Reference implementations studied:
#   * DuckDB `src/common/hive_partitioning.cpp`
#     (`HivePartitioning::Parse`): splits each path on `/`, keeps only the
#     components that contain a single `=`, treats the part before `=` as
#     the column name and after `=` as the value (URL-decoded). Type is
#     inferred by `LogicalType::GetMaxLogicalType` over the value set with
#     the candidate order BIGINT → DATE → ... → VARCHAR. A path missing a
#     partition key that other paths have is an error
#     (`HivePartitioning::Parse` requires consistent layout);
#     `hive_types` / `HIVE_TYPES` can override the inference.
#   * DuckDB `src/execution/operator/scan/physical_table_scan.cpp`:
#     partition values become CONSTANT columns appended to the scan output
#     (one literal per row of the morsel) — that projection is the engine
#     piece, not this module.
#   * DataFusion `datafusion/core/src/datasource/listing/helpers.rs`
#     (`parse_partitions_for_path`): same `key=value` directory split;
#     partition values are kept as strings and cast at scan time to the
#     declared partition-column type (the `ListingTableConfig` carries the
#     partition schema explicitly — DataFusion does NOT auto-infer the
#     type, it requires the user to declare it). Our `read_parquet_partitioned`
#     gives the user the same explicit-cols escape hatch; this module is
#     the auto-inference convenience (DuckDB-style).
#
# Pure logic: no I/O, no pointers, no engine deps. Unit-testable in
# isolation against synthetic path lists.
# =============================================================================

from std.collections import Optional

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field


# =============================================================================
# Internal result struct for one path's parsed partition pairs.
# =============================================================================


struct _PathPartitions(Movable, Copyable, Deinitable):
    """Parsed (key, value) partition pairs for one path, in directory order.
    `keys` and `values` are the same length."""
    var keys: List[String]
    var values: List[String]

    def __init__(out self, var keys: List[String], var values: List[String]):
        self.keys = keys^
        self.values = values^

    def copy(self) -> Self:
        return Self(self.keys.copy(), self.values.copy())


# =============================================================================
# Public result type
# =============================================================================


struct HivePartitionLayout(Movable, Copyable, Deinitable):
    """Parsed Hive partition layout for a set of parquet paths.

    Fields:
        cols: one Field per partition column (name + inferred ArrowType,
            nullable=False). Ordered by directory depth (outermost first),
            matching the order the keys appear in the paths.
        values: per-path raw value text. `len(values) == len(input_paths)`;
            each inner list has `len(cols)` entries (the value for col[i]
            on that path, as the raw `<value>` text — the engine parses to
            cols[i].arrow_type at scan time).
    """

    var cols: List[Field]
    var values: List[List[String]]

    def __init__(out self, var cols: List[Field], var values: List[List[String]]):
        self.cols = cols^
        self.values = values^

    def copy(self) -> Self:
        var cols_copy = List[Field]()
        for i in range(len(self.cols)):
            cols_copy.append(self.cols[i].copy())
        var vals_copy = List[List[String]]()
        for i in range(len(self.values)):
            var row = List[String]()
            for j in range(len(self.values[i])):
                row.append(String(self.values[i][j]))
            vals_copy.append(row^)
        return Self(cols_copy^, vals_copy^)

    def num_cols(self) -> Int:
        return len(self.cols)


# =============================================================================
# Path-component parsing
# =============================================================================


def _substr_bytes(s: String, start: Int, end: Int) -> String:
    """Reproduce `s`'s bytes in `[start, end)` EXACTLY, as a String.

    ⛔ DO NOT REWRITE THIS AS `out += chr(Int(bs[i]))` PER BYTE. That is a
    SILENT WRONG ANSWER on any non-ASCII path component. `chr` maps a CODE
    POINT to its UTF-8 ENCODING, so a stored byte >= 0x80 is not reproduced
    but re-encoded into TWO. The directory `city=Zürich` (5A C3 BC 72 69 63
    68) would parse to 5A C3 83 C2 BC 72 69 63 68 — `ZÃ¼rich`. ASCII is the
    corruption's fixed point, which is why an all-ASCII corpus never sees it.

    ⚠ THIS ONE IS ON USER DATA. A Hive partition VALUE is a directory name —
    `country=Österreich`, `city=東京`, `product=Café` are all ordinary — and
    the parsed value is used TWICE, with two different wrong answers:

      * it is materialized as the partition column's data
        (`ParquetSource.partitioned(..., layout.values, ...)`), i.e. a
        visibly mojibaked output column; and
      * partition pruning compares it BYTE-WISE against the user's predicate
        literal, which is a CORRECT UTF-8 String. Corrupt on one side only
        means `WHERE city = 'Zürich'` matches NO path, every path is pruned
        and the query returns an EMPTY RESULT. Dropped rows, not mangled
        ones.
    """
    var bs = s.as_bytes()
    # SAFETY: `bs` borrows `s` for the whole expression; the sub-Span is
    # length-explicit and the String constructor copies out of it.
    # `StringSlice(unsafe_from_utf8=)` is the spelling for a
    # byte-exact reinterpretation — NOT
    # `String(unsafe_from_utf8_ptr=)`, which stops at the first NUL.
    return String(StringSlice(unsafe_from_utf8=bs[start:end]))


def _parse_kv_component(comp: String, mut out_key: String, mut out_value: String) -> Bool:
    """If `comp` is exactly `<key>=<value>` with one `=` and a non-empty
    key, write the key into `out_key` / value into `out_value` and return
    True. Otherwise leave the outs untouched and return False (it's a plain
    directory component, not a partition component)."""
    var bs = comp.as_bytes()
    var eq_pos = -1
    var eq_count = 0
    for i in range(len(bs)):
        if bs[i] == UInt8(ord("=")):
            eq_count += 1
            if eq_pos < 0:
                eq_pos = i
    if eq_count != 1:
        return False
    if eq_pos == 0:
        return False  # empty key
    out_key = _substr_bytes(comp, 0, eq_pos)
    out_value = _substr_bytes(comp, eq_pos + 1, len(bs))
    return True


def _split_on_slash(path: String) -> List[String]:
    """Split `path` on `/` into owned String components (empties kept; the
    caller skips them). `split` returns StringSlice refs, so each is copied
    into an owned String."""
    var out = List[String]()
    for s in path.split("/"):
        out.append(String(s))
    return out^


def _parse_one_path(path: String) -> _PathPartitions:
    """Parse the partition (key, value) pairs out of one path, in
    directory order. A path with no partition components returns empty
    lists. The LAST `/`-component (the file name itself, e.g.
    `part-0.parquet`) is never treated as a partition directory."""
    var keys = List[String]()
    var vals = List[String]()
    var comps = _split_on_slash(path)
    var n = len(comps)
    if n <= 1:
        return _PathPartitions(keys^, vals^)
    # Only consider components strictly before the final one.
    for i in range(n - 1):
        ref comp = comps[i]
        if comp.byte_length() == 0:
            continue  # leading "/" or "//"
        var k = String("")
        var v = String("")
        if _parse_kv_component(comp, k, v):
            keys.append(k^)
            vals.append(v^)
    return _PathPartitions(keys^, vals^)


# =============================================================================
# Type inference
# =============================================================================


def _value_parses_as_int(v: String) -> Bool:
    """True iff `v` is a non-empty optionally-signed run of ASCII digits
    that fits in Int64. Leading `+`/`-` allowed; no whitespace. Empty → not
    an int (an empty partition value is a string, possibly representing
    NULL — DuckDB's `__HIVE_DEFAULT_PARTITION__` is also a string)."""
    var bs = v.as_bytes()
    if len(bs) == 0:
        return False
    var start = 0
    if bs[0] == UInt8(ord("-")) or bs[0] == UInt8(ord("+")):
        if len(bs) == 1:
            return False
        start = 1
    for i in range(start, len(bs)):
        if bs[i] < UInt8(ord("0")) or bs[i] > UInt8(ord("9")):
            return False
    # Conservative Int64 range guard: up to 18 digits always fits; >=19
    # digits we conservatively treat as NOT-an-int (falls back to String)
    # rather than risk overflow. A 19-digit partition value is absurd in
    # practice; the precise boundary check (9223372036854775807) is left
    # to the engine's scan-time literal parse, which raises clearly.
    var n_digits = len(bs) - start
    if n_digits > 18:
        return False
    return True


def _days_in_month(yyyy: Int, mm: Int) -> Int:
    """The number of days of month `mm` (1..12) of year `yyyy` in the
    proleptic Gregorian calendar: February has 29 days in a year divisible
    by 4 and not by 100, or divisible by 400."""
    if mm == 2:
        var leap = (yyyy % 4 == 0 and yyyy % 100 != 0) or yyyy % 400 == 0
        return 29 if leap else 28
    if mm == 4 or mm == 6 or mm == 9 or mm == 11:
        return 30
    return 31


def _value_parses_as_date32(v: String) -> Bool:
    """True iff `v` matches the strict `YYYY-MM-DD` shape and names a real
    calendar date: month 01-12 and day 01 up to the month's last day (29
    February only in a leap year). (DuckDB uses the full date parser; this
    strict-shape check is the conservative subset that never mis-classifies
    a string as a date.)"""
    var bs = v.as_bytes()
    if len(bs) != 10:
        return False
    for i in range(10):
        if i == 4 or i == 7:
            if bs[i] != UInt8(ord("-")):
                return False
        else:
            if bs[i] < UInt8(ord("0")) or bs[i] > UInt8(ord("9")):
                return False
    var yyyy = 0
    for i in range(4):
        yyyy = yyyy * 10 + (Int(bs[i]) - ord("0"))
    var mm = (Int(bs[5]) - ord("0")) * 10 + (Int(bs[6]) - ord("0"))
    var dd = (Int(bs[8]) - ord("0")) * 10 + (Int(bs[9]) - ord("0"))
    if mm < 1 or mm > 12:
        return False
    if dd < 1 or dd > _days_in_month(yyyy, mm):
        return False
    return True


def _infer_arrow_type(values: List[String]) -> ArrowType:
    """Infer the column type for a partition key from its full value set,
    mirroring DuckDB's candidate order: BIGINT → DATE → VARCHAR.

    An empty value set (shouldn't happen — every path contributes a value)
    falls through to STRING.
    """
    if len(values) == 0:
        return ArrowType.STRING
    var all_int = True
    var all_date = True
    for i in range(len(values)):
        if not _value_parses_as_int(values[i]):
            all_int = False
        if not _value_parses_as_date32(values[i]):
            all_date = False
        if not all_int and not all_date:
            break
    if all_int:
        return ArrowType.INT64
    if all_date:
        return ArrowType.DATE32
    return ArrowType.STRING


# =============================================================================
# Public API
# =============================================================================


def parse_hive_partitions(paths: List[String]) raises -> HivePartitionLayout:
    """Parse Hive partition columns from a list of parquet paths, inferring
    each column's type from its values (DuckDB-style auto-detection).

    Behavior:
      * The partition LAYOUT (the ordered list of partition keys) must be
        IDENTICAL across all paths. If path A has `year/month` and path B
        has only `year`, that's a `mixed partition layout` error (matches
        DuckDB's `HivePartitioning::Parse`). A path with NO partition
        components is fine ONLY if every path has none — in which case the
        result is an empty layout (the caller treats this as a plain
        multi-file scan).
      * Each column's type is inferred over its full value set: BIGINT if
        all values parse as signed integers, DATE if all match
        `YYYY-MM-DD`, else VARCHAR.
      * Values are kept as the raw `<value>` text; the engine parses to the
        inferred type at scan time when projecting the constant column.

    Args:
        paths: Non-empty list of parquet file paths (already concrete — if
            these came from a glob, the glob is expanded BEFORE this call).

    Returns:
        HivePartitionLayout with `cols` (one Field per partition key) and
        `values` (per-path raw value text).

    Raises:
        - Empty `paths`.
        - Mixed partition layout across paths (different keys or order).
    """
    if len(paths) == 0:
        raise Error("parse_hive_partitions: empty path list")

    var first = _parse_one_path(paths[0])

    if len(first.keys) == 0:
        for i in range(1, len(paths)):
            var pi = _parse_one_path(paths[i])
            if len(pi.keys) != 0:
                raise Error(
                    "parse_hive_partitions: mixed partition layout — path[0] '"
                    + paths[0]
                    + "' has no partition columns but path["
                    + String(i)
                    + "] '"
                    + paths[i]
                    + "' has "
                    + String(len(pi.keys))
                )
        return HivePartitionLayout(List[Field](), List[List[String]]())

    var num_keys = len(first.keys)
    var canonical_keys = List[String]()
    for i in range(num_keys):
        canonical_keys.append(String(first.keys[i]))

    var per_path_values = List[List[String]]()
    var per_col_values = List[List[String]]()
    for _ in range(num_keys):
        per_col_values.append(List[String]())

    for path_idx in range(len(paths)):
        var parsed = _parse_one_path(paths[path_idx])
        if len(parsed.keys) != num_keys:
            raise Error(
                "parse_hive_partitions: mixed partition layout — path[0] '"
                + paths[0]
                + "' has "
                + String(num_keys)
                + " partition columns but path["
                + String(path_idx)
                + "] '"
                + paths[path_idx]
                + "' has "
                + String(len(parsed.keys))
            )
        for k in range(num_keys):
            if parsed.keys[k] != canonical_keys[k]:
                raise Error(
                    "parse_hive_partitions: mixed partition layout — path[0]"
                    " column #"
                    + String(k)
                    + " is '"
                    + canonical_keys[k]
                    + "' but path["
                    + String(path_idx)
                    + "] '"
                    + paths[path_idx]
                    + "' column #"
                    + String(k)
                    + " is '"
                    + parsed.keys[k]
                    + "'"
                )
        var row = List[String]()
        for k in range(num_keys):
            row.append(String(parsed.values[k]))
            per_col_values[k].append(String(parsed.values[k]))
        per_path_values.append(row^)

    var cols = List[Field]()
    for k in range(num_keys):
        var t = _infer_arrow_type(per_col_values[k])
        # Partition columns are not nullable by convention.
        cols.append(Field(String(canonical_keys[k]), t, False))

    return HivePartitionLayout(cols^, per_path_values^)


def parse_hive_partitions_for_cols(
    paths: List[String],
    requested_cols: List[String],
) raises -> HivePartitionLayout:
    """Like `parse_hive_partitions` but only extracts the named columns
    (the explicit-cols escape hatch used by `read_parquet_partitioned`,
    DataFusion-style). Columns NOT in `requested_cols` that appear in the
    paths are simply ignored; a `requested_col` that does NOT appear in
    every path is an error.

    Args:
        paths: Non-empty list of parquet file paths.
        requested_cols: The partition column names the caller wants. Order
            in the result follows `requested_cols`. Empty → empty layout.

    Returns:
        HivePartitionLayout restricted to `requested_cols`, types inferred.

    Raises:
        - Empty `paths`.
        - A requested column missing from some path.
    """
    if len(paths) == 0:
        raise Error("parse_hive_partitions_for_cols: empty path list")
    if len(requested_cols) == 0:
        return HivePartitionLayout(List[Field](), List[List[String]]())

    var per_path_values = List[List[String]]()
    var per_col_values = List[List[String]]()
    for _ in range(len(requested_cols)):
        per_col_values.append(List[String]())

    for path_idx in range(len(paths)):
        var parsed = _parse_one_path(paths[path_idx])
        var row = List[String]()
        for rc_idx in range(len(requested_cols)):
            ref want = requested_cols[rc_idx]
            var found_idx = -1
            for k in range(len(parsed.keys)):
                if parsed.keys[k] == want:
                    found_idx = k
                    break
            if found_idx < 0:
                raise Error(
                    "parse_hive_partitions_for_cols: requested partition"
                    " column '"
                    + want
                    + "' not found in path '"
                    + paths[path_idx]
                    + "'"
                )
            row.append(String(parsed.values[found_idx]))
            per_col_values[rc_idx].append(String(parsed.values[found_idx]))
        per_path_values.append(row^)

    var cols = List[Field]()
    for rc_idx in range(len(requested_cols)):
        var t = _infer_arrow_type(per_col_values[rc_idx])
        cols.append(Field(String(requested_cols[rc_idx]), t, False))

    return HivePartitionLayout(cols^, per_path_values^)
