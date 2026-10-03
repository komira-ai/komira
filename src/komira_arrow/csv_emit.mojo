# =============================================================================
# CSV_EMIT -- RecordBatch -> CSV for a parity (result-diff) harness
# =============================================================================
#
# PERF-CRITICAL (for correctness, not speed): byte-output must be parseable
# by a CSV diff and match DuckDB's default `.mode csv` output, otherwise every
# parity check fails with meaningless text-vs-text mismatches.
#
# Output contract:
#
#     ...any preceding output...
#     #PARITY_BEGIN
#     col1,col2,col3             <-- comma-separated header, ONE line
#     1,foo,3.14                 <-- comma-separated data rows
#     ...
#     #PARITY_END
#     ...any following output...
#
# A harness extracts the sentinel block, runs the reference engine in
# `.mode csv` `.header on`, then csv.reader-diffs the two outputs with
# relative-epsilon tolerance on floats:
#   - cell_equal tries int() first, then float(), then exact string match.
#   - NaN-vs-NaN -> equal. inf-vs-inf -> equal if sign matches.
#
# Format decisions (probed against the DuckDB CLI, .mode csv, .header on):
#   - DELIMITER:        comma  (`,`).  Python csv.reader default.
#   - NULL:             literal `NULL`.  DuckDB emits `NULL` by default.
#   - FLOAT (F64/F32):  Mojo default `String(f)` matches DuckDB's shortest-
#                       round-trip formatter ("Ryu-like") on every value
#                       probed -- `0.1+0.2 -> 0.3`, `1e-308 -> 1e-308`,
#                       `1e308 -> 1e+308`, `3.141592653589793` round-trips.
#                       Even where the two differ byte-for-byte (e.g. Mojo
#                       prints `-0.0` but DuckDB prints `0.0`) the diff
#                       float-parses both and relative-eps-compares, so it
#                       passes. We match DuckDB byte-for-byte wherever
#                       we can; we rely on the numeric compare where we
#                       cannot (-0.0 is the only observed divergence).
#   - INT (I32/I64):    Mojo default `String(i)`.
#   - BOOL:             `true` / `false` lowercase.  Matches DuckDB.
#   - STRING:           RFC-4180 quoting -- wrap in double-quotes iff the
#                       value contains `,`, `"`, `\n`, or `\r`; embedded
#                       `"` -> `""`.  Matches DuckDB default.
#   - DICTIONARY:       resolve to dictionary string, then STRING rules.
#
# Known ambiguities (ACCEPTED, documented, symmetric with DuckDB):
#   1. A string value equal to the 4 bytes `NULL` (unquoted by our RFC-4180
#      rules since it contains none of `,"\n\r`) round-trips as SQL NULL at
#      the diff stage.  DuckDB has the SAME ambiguity.
#   2. Mojo emits `-0.0`; DuckDB emits `0.0`.  The diff float-parses both;
#      `float('-0.0') == float('0.0')` so this is invisible to the diff.
#   3. Empty string `""` is emitted unquoted as an empty cell.  csv.reader
#      with default options reads it as `""` too.  DuckDB emits empty
#      strings the same way.  Distinguishing empty-string from NULL in CSV
#      is fundamentally ambiguous; we accept the DuckDB convention.
#
# USAGE: the caller decides (from its own configuration) whether to emit,
# and calls `emit_parity_batch(batch)` after its normal work.
#
# Testability: `emit_record_batch_csv_to` writes to a mut String sink so
# unit tests can assert byte-exact output without capturing stdout.
# `emit_record_batch_csv` is a convenience wrapper that prints to stdout.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.record_batch import RecordBatch


# -----------------------------------------------------------------------------
# Header: column names, comma-joined, no quoting
# -----------------------------------------------------------------------------
#
# Per the harness contract, column names don't need to match DuckDB byte-for-byte
# (aliases can differ); python3 diff warns but does not fail on header
# difference.  We skip RFC-4180 quoting for header cells on the assumption
# that result column names are simple identifiers -- if a future query emits
# a header containing `,` or `"`, we'd need to apply _write_string_cell to
# header cells too.  Flag TODO noted for that case.


def _write_header(mut sink: String, batch: RecordBatch) raises:
    var n = batch.num_columns()
    for i in range(n):
        if i > 0:
            sink.write(",")
        sink.write(batch.schema.field_name(i))
    sink.write("\n")


# -----------------------------------------------------------------------------
# RFC-4180 string cell writer
# -----------------------------------------------------------------------------
#
# PERF note: we do a single pass over the bytes looking for the 4 trigger
# chars, then a second pass copying-with-escape IF a trigger was found.
# For the common case (no trigger) the second pass is a single writer.write
# of the unquoted value.  The double-scan is fine -- strings in result output
# are short (<~40 bytes) and we care about correctness over microseconds
# here.  If profiling shows this hot, switch to a single pass building into
# a small scratch buffer.


def _needs_quoting(s: String) -> Bool:
    # We cannot iterate bytes of a String directly and portably, but we can
    # use `.find` which is O(n) per character.  Four O(n) scans is O(4n) --
    # still O(n), and result strings are short.  `find` returns -1 on miss.
    if s.find(",") >= 0:
        return True
    if s.find('"') >= 0:
        return True
    if s.find("\n") >= 0:
        return True
    if s.find("\r") >= 0:
        return True
    return False


def _write_string_cell(mut sink: String, s: String):
    if not _needs_quoting(s):
        sink.write(s)
        return
    # Quoted form: surround with `"`, double any internal `"`.
    sink.write('"')
    # `String.replace` produces a new String; for short result strings this
    # is an acceptable allocation.  A streaming char-by-char escape would
    # avoid the allocation but would require byte-level iteration that is
    # awkward in Mojo 0.26 without UnsafePointer gymnastics.
    var escaped = s.replace('"', '""')
    sink.write(escaped)
    sink.write('"')


# -----------------------------------------------------------------------------
# Column-major formatting: materialize each column into a List[String] of
# per-row rendered cells, then transpose into row-major CSV lines.
#
# Why this shape: RecordBatch stores columnar; `Column.as_primitive[...]`
# reconstructs a typed array by copying the column's buffer.  If we did
# per-cell dispatch inside a row loop, we'd call `as_primitive` O(R*C)
# times -- copying each column R times.  Pre-materializing once per column
# is O(C) buffer copies + O(C*R) String allocations (one per cell), which
# is the lower bound for a row-major text emit of columnar data.
#
# Mojo 0.26 cannot hold heterogeneous typed arrays across a heap
# collection (parameterized types don't erase to a common base), so this
# column-major-then-transpose approach is the cleanest way to keep the
# typed-array materialization out of the inner loop.
# -----------------------------------------------------------------------------


def _format_column_cells(
    batch: RecordBatch, col_index: Int
) raises -> List[String]:
    var num_rows = batch.num_rows()
    var out = List[String]()
    out.reserve(num_rows)
    # Bind the Column by ref -- Column is Movable but not ImplicitlyCopyable,
    # so we cannot `var col_ref = ...`.  The `ref` binding shares the
    # origin-tracked reference from RecordBatch.column_at().
    ref col_ref = batch.column_at(col_index)
    var arrow_type = batch.schema.field_arrow_type(col_index)

    if arrow_type == ArrowType.INT64:
        var arr = col_ref.as_primitive[DType.int64]()
        for r in range(num_rows):
            if arr.is_null(r):
                out.append("NULL")
            else:
                out.append(String(arr.get(r)))
    elif arrow_type == ArrowType.INT32:
        var arr = col_ref.as_primitive[DType.int32]()
        for r in range(num_rows):
            if arr.is_null(r):
                out.append("NULL")
            else:
                out.append(String(arr.get(r)))
    elif arrow_type == ArrowType.FLOAT64:
        var arr = col_ref.as_primitive[DType.float64]()
        for r in range(num_rows):
            if arr.is_null(r):
                out.append("NULL")
            else:
                out.append(String(arr.get(r)))
    elif arrow_type == ArrowType.FLOAT32:
        var arr = col_ref.as_primitive[DType.float32]()
        for r in range(num_rows):
            if arr.is_null(r):
                out.append("NULL")
            else:
                out.append(String(arr.get(r)))
    elif arrow_type == ArrowType.BOOL:
        var arr = col_ref.as_boolean()
        for r in range(num_rows):
            if arr.is_null(r):
                out.append("NULL")
            elif arr.get(r):
                out.append("true")
            else:
                out.append("false")
    elif arrow_type == ArrowType.STRING:
        var arr = col_ref.as_string()
        for r in range(num_rows):
            if arr.is_null(r):
                out.append("NULL")
            else:
                var cell = String()
                _write_string_cell(cell, arr.get(r))
                out.append(cell^)
    elif arrow_type == ArrowType.DICTIONARY:
        var arr = col_ref.as_dictionary()
        for r in range(num_rows):
            if arr.indices.is_null(r):
                out.append("NULL")
            else:
                var cell = String()
                _write_string_cell(cell, arr.get(r))
                out.append(cell^)
    elif arrow_type == ArrowType.NULL:
        for _ in range(num_rows):
            out.append("NULL")
    else:
        raise Error(
            "emit_record_batch_csv: unsupported ArrowType '"
            + String(arrow_type)
            + "' for parity emit at column index "
            + String(col_index)
            + ".  Supported: INT32, INT64, FLOAT32, FLOAT64, BOOL, STRING,"
            + " DICTIONARY, NULL."
        )
    return out^


# -----------------------------------------------------------------------------
# Public API
# -----------------------------------------------------------------------------


def emit_record_batch_csv_to(mut sink: String, batch: RecordBatch) raises:
    """Emit `batch` as CSV (header + rows) into `sink`.

    Format: comma-separated, LF line terminators, DuckDB `.mode csv`-
    compatible NULL / bool / float / string encoding.  See module header
    for full format rationale.

    This variant writes to a caller-supplied String for testability.
    Use `emit_record_batch_csv` to write directly to stdout.
    """
    _write_header(sink, batch)

    var num_rows = batch.num_rows()
    var num_cols = batch.num_columns()
    if num_cols == 0:
        # Zero-column batch: _write_header already emitted a bare "\n"
        # (the header with no field names).  DuckDB's CSV output for a
        # zero-column SELECT is empty (no rows), so we omit row emit too.
        # This is a degenerate case queries rarely hit; we handle it
        # defensively rather than erroring.
        return

    # Column-major formatting (build N buffers of R strings), then
    # row-major emit.  See rationale above _format_column_cells.
    var columns = List[List[String]]()
    columns.reserve(num_cols)
    for c in range(num_cols):
        columns.append(_format_column_cells(batch, c))

    for r in range(num_rows):
        for c in range(num_cols):
            if c > 0:
                sink.write(",")
            sink.write(columns[c][r])
        sink.write("\n")


def emit_record_batch_csv(batch: RecordBatch) raises:
    """Emit `batch` as CSV to stdout.

    Convenience wrapper over `emit_record_batch_csv_to` that constructs
    an internal String buffer and prints it.  Prefer the `_to` variant
    if you need to compose output (e.g., parity sentinels) and want a
    single print call.
    """
    var buf = String()
    emit_record_batch_csv_to(buf, batch)
    # `print(end="")` suppresses the extra LF that `print` appends; the
    # CSV already terminates each row with `\n`.
    print(buf, end="")


def emit_parity_batch(batch: RecordBatch) raises:
    """Emit `batch` wrapped in `#PARITY_BEGIN` / `#PARITY_END` sentinels.

    This is the primary entry point for callers running in parity
    mode.  The sentinels are on their own lines per the harness contract.
    """
    var buf = String()
    buf.write("#PARITY_BEGIN\n")
    emit_record_batch_csv_to(buf, batch)
    buf.write("#PARITY_END\n")
    print(buf, end="")
