# =============================================================================
# input_limits.mojo — hostile-input ceilings for the CSV reader.
# =============================================================================
#
# ⚠ WHY THIS MODULE EXISTS: release builds ship at `ASSERT=none`.
#
# `ASSERT=none` compiles OUT stdlib bounds-checking. Any quantity this reader
# derives from input bytes and then uses as an index or an allocation size must
# therefore be validated by an EXPLICIT raise with a real error path — not by a
# bounds check, and not by an assert.
#
# DESIGN RULE — validate ONCE at the boundary:
#   * `check_csv_column_count` runs once per file read, right after the header
#     row is turned into names and BEFORE any column builder allocates.
#   * `check_csv_cell_budget` runs once per materialized batch — once in the
#     single-thread reader, once per WORKER on the parallel path — on the
#     (rows, cols, input-bytes) triple, before the first builder allocates.
#   * `check_csv_string_column_bytes` runs once per STRING column, on a total
#     that pass 1 has already summed.
# None sits in a per-cell or per-byte path.
#
# This module is a LEAF: it imports nothing from `komira_csv`.
# =============================================================================


# =============================================================================
# 1. Column-count ceiling
# =============================================================================
#
# `num_cols` is the cell count of the CSV *header row* — entirely attacker
# chosen — and `_materialize_batch_with_schema` loops `c in [0, num_cols)`
# allocating the FULL row count up front in every builder
# (`PrimitiveArray[int64].allocate(num_rows)`, the string builder's
# `(num_rows + 1) * 4`-byte offsets buffer, ...), so allocation is rows x cols,
# not rows x present-cells. (Rows shorter than the header used to be padded with
# nulls; the readers now refuse them in `record_shape`, before any allocation.)
#
# A 400 KB file — a header of 100k comma-separated names (~200 KB) followed by
# 100k one-cell rows (~200 KB) — therefore demands 100k columns x 100k rows,
# and the parallel driver pays that PER WORKER across up to 32 workers. There
# was no cap on `num_cols` anywhere in the CSV path.
#
# 4096 columns is far past any real CSV (the widest in our corpora is
# ClickBench's hits.csv at 105) while rejecting the cardinality attack.
comptime MAX_CSV_COLUMNS: Int = 4096


def check_csv_column_count(n_cols: Int) raises:
    """Raise if the CSV header declares more columns than the reader will
    materialize.

    Called ONCE per read, after the header row is parsed and BEFORE any
    column builder allocates — which is the entire point: the allocation this
    guards has not happened yet.
    """
    if n_cols > MAX_CSV_COLUMNS:
        raise Error(
            "CSV reader: header row declares "
            + String(n_cols)
            + " columns, exceeding the "
            + String(MAX_CSV_COLUMNS)
            + "-column limit. Every column allocates a full row-count buffer"
            + " up front, so the column count"
            + " multiplies the row count into the allocation — and the"
            + " parallel reader pays it once per worker. If this file really"
            + " is this wide, project the columns you need."
        )


# =============================================================================
# 1b. Cell budget — the ceiling the column cap alone does NOT give you
# =============================================================================
#
# ⚠ THE COLUMN CAP IS HALF A GUARD. `check_csv_column_count` bounds ONE of the
# two multiplicands; the allocation is `rows x cols`, and `rows` had no ceiling
# anywhere in the CSV path. The reader's own JSON sibling
# (`komira_json/input_limits.mojo`) states this as a hard requirement and
# ships `MAX_JSON_CELLS_PER_INPUT_BYTE`; the CSV path — same shape, same
# `allocate(num_rows)`-per-column materializer — shipped with no per-input-byte
# budget at all.
#
# The shape is identical to the JSON one. Every column builder allocates the
# FULL row count up front (`PrimitiveArray[...].allocate_nullable(num_rows)` in
# `typed_column_builders.mojo`, the `(num_rows + 1) * 4`-byte offsets buffer in
# `string_column_simd.mojo`), so the allocation
# is rows x cols and NOT rows x present-cells. Neither multiplicand was tied to
# the size of the input that produced them:
#
#   * a header of 4096 one-character names (~8 KB) followed by 1M rows of `x\n`
#     (~2 MB) is a ~2 MB input that demands 4096 x 1_000_000 = 4.1e9 cells.
#     At 8 bytes/cell for an INT64 column that is ~32 GB — and the parallel
#     driver pays it once PER WORKER, up to 32 of them.
#
# This is NOT a bounds check, so it fails identically at `ASSERT=safe` and
# `ASSERT=none` — without it the path is simply unprotected, and an
# unbounded allocation of this class can take down the whole host.
#
# WHY "PER INPUT BYTE" AND NOT AN ABSOLUTE ROW CAP: the invariant that was
# actually broken is "allocation is O(input bytes)". An absolute row cap either
# rejects a legitimate large file or permits the amplification on a small one.
# Measured densities of the corpora we read:
#   * TPC-H lineitem CSV : 16 cols / ~120 B row  = 0.13 cells/byte
#   * ClickBench hits.csv: 105 cols / ~1 KB row  = 0.10 cells/byte
#   * the densest shape a well-formed CSV can have (`1,1,1,...`) is 0.5
#     cells/byte; an all-empty-cell row (`,,,,`) is 1.0.
# 256 is ~256x past the densest well-formed file and still rejects the
# adversarial shape decisively (4.1e9 demanded vs 5.2e8 allowed above).
comptime MAX_CSV_CELLS_PER_INPUT_BYTE: Int = 256


def max_csv_rows_for_columns(n_cols: Int, input_bytes: Int) raises -> Int:
    """Return the row ceiling the cell budget implies for `n_cols` columns over
    an `input_bytes`-byte input.

    Split out so a caller that wants the ceiling (rather than a raise) can get
    it without a division in a loop. `input_bytes + 1` keeps a 0-byte input
    from producing a 0 budget.
    """
    var budget = MAX_CSV_CELLS_PER_INPUT_BYTE * (input_bytes + 1)
    if n_cols <= 0:
        return budget
    return budget // n_cols


def check_csv_cell_budget(
    n_rows: Int, n_cols: Int, input_bytes: Int
) raises:
    """Raise if materializing `n_rows` x `n_cols` accumulator cells would
    exceed the per-input-byte cell budget.

    Called ONCE per materialized batch — once in `read_csv_bytes_to_batch`,
    once per WORKER in `_materialize_batch_with_schema{,_timed}` — before the
    first column builder allocates, which is the entire point: the allocation
    this guards has not happened yet. It is a single compare against a value
    computed once; nothing here runs per row or per cell.
    """
    if n_rows < 0 or n_cols < 0:
        raise Error(
            "CSV reader: negative materialization extent (rows="
            + String(n_rows)
            + ", cols="
            + String(n_cols)
            + "); the scanned-cell index is malformed."
        )
    var max_rows = max_csv_rows_for_columns(n_cols, input_bytes)
    if n_rows > max_rows:
        raise Error(
            "CSV reader: materializing "
            + String(n_rows)
            + " rows x "
            + String(n_cols)
            + " columns = "
            + String(n_rows * n_cols)
            + " accumulator cells from a "
            + String(input_bytes)
            + "-byte input, exceeding the budget of "
            + String(MAX_CSV_CELLS_PER_INPUT_BYTE)
            + " cells per input byte (ceiling for this width: "
            + String(max_rows)
            + " rows). Every column allocates the FULL row count up front,"
            + " so a wide header over many"
            + " rows allocates quadratically in two quantities the input"
            + " controls — and the parallel reader pays it once per worker."
            + " Project the columns you need, or read the file in batches."
        )


# =============================================================================
# 2. Arrow-32 string-offset ceiling
# =============================================================================
#
# `build_string_column_simd` sums untrusted cell lengths into `running_offset`
# and narrows it with a bare `Int32(running_offset)` when writing the offsets
# buffer. Arrow's STRING layout caps ONE array's data buffer at 2^31-1 bytes
# (LARGE_STRING exists precisely for this). Past 2 GiB in one worker's column
# the offsets wrap NEGATIVE while `data_buf` — sized from the UN-narrowed
# `total_bytes_cap` — is correctly large, so the StringArray ships with
# `offsets[i] < 0` and every consumer doing `data[offsets[i]:offsets[i+1]]`
# reads BEFORE the buffer. Reachable from a single ~2 GB CSV with one wide
# text column.
comptime MAX_ARROW_STRING_BYTES: Int = 2147483647  # 2**31 - 1


def check_csv_string_column_bytes(total_bytes: Int, col_idx: Int) raises:
    """Raise if one STRING column's summed cell bytes would overflow the
    Int32 Arrow offsets.

    Called ONCE per STRING column, on the total that pass 1 already computed —
    the per-cell loop is untouched.
    """
    if total_bytes > MAX_ARROW_STRING_BYTES:
        raise Error(
            "CSV reader: STRING column at index "
            + String(col_idx)
            + " holds "
            + String(total_bytes)
            + " bytes of cell data, exceeding the Arrow STRING limit of "
            + String(MAX_ARROW_STRING_BYTES)
            + " bytes (Int32 offsets). Past this size the offset buffer wraps"
            + " NEGATIVE while the data buffer stays correctly large, so"
            + " readers index before the start of the data. Read the file in"
            + " smaller batches, or promote the column to LARGE_STRING"
            + " (64-bit offsets)."
        )


# =============================================================================
# 3. Row-byte ceiling — making `CsvReadOptions.max_row_bytes` REAL
# =============================================================================
#
# `max_row_bytes` is an option whose documented job is a "safety cap on row buffer
# for unterminated quoted regions". A declared-but-unenforced safety cap is
# WORSE than none, because it reads as protection during review: a single
# unbalanced `"` makes the FSA consume the entire remaining buffer as one cell,
# and that cell length flows unchecked into `total_bytes_cap`.
#
# The check is applied per SCANNED ROW (one Int compare against a value the
# caller supplied), not per cell and not per byte — the scanner already tracks
# the row's start offset, so the comparison is free.


def check_csv_row_bytes(
    row_bytes: Int, max_row_bytes: Int, row_start: Int
) raises:
    """Raise if one CSV row spans more bytes than `max_row_bytes`.

    `max_row_bytes <= 0` disables the check (the documented opt-out).
    """
    if max_row_bytes > 0 and row_bytes > max_row_bytes:
        raise Error(
            "CSV reader: the row starting at byte "
            + String(row_start)
            + " spans "
            + String(row_bytes)
            + " bytes, exceeding CsvReadOptions.max_row_bytes = "
            + String(max_row_bytes)
            + ". This is usually an unterminated quoted region: one"
            + " unbalanced '\"' makes the scanner treat every following"
            + " delimiter and newline as field content, so the rest of the"
            + " file becomes a single cell. Fix the quoting, or raise"
            + " max_row_bytes if the file legitimately has rows this wide."
        )
