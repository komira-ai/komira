# =============================================================================
# input_limits.mojo — hostile-input ceilings for the JSON/JSONL reader.
# =============================================================================
#
# ⚠ WHY THIS MODULE EXISTS: shipped binaries are built at `ASSERT=none`.
#
# `ASSERT=none` compiles OUT stdlib bounds-checking. A bounds check that
# catches a length derived from
# attacker-controlled bytes becomes, at `ASSERT=none`, a silent out-of-range
# read/write. So any quantity this reader derives from input bytes and then
# uses as an index / an allocation size MUST be validated by an EXPLICIT
# raise, not by a stdlib assert.
#
# DESIGN RULE — validate ONCE at the boundary, never per value:
#   * `check_structural_index_input_size` runs once per `build_structural_index`
#     call (once per file / once per partition).
#   * `check_json_column_count` runs once per inference (schema_inference's
#     `_infer_partial_into` / `_infer_parallel_into_impl`) and once per
#     materialize, before any accumulator is constructed. It is deliberately
#     NOT on `KeyRegistryBuilder`'s insert branch: making that method `raises`
#     would put an error check on the per-key LOOKUP path, which runs once
#     per key per row (tens of millions of times on a large file).
#   * `max_rows_for_columns` is evaluated ONCE and compared against a running
#     row counter — one `Int` compare per row, no multiply in the loop.
# None of these sit in a per-byte or per-value path.
#
# This module is a LEAF: it imports nothing, so every
# other module in the package can depend on it without a cycle.
# =============================================================================


# =============================================================================
# 1. Structural-tape offset ceiling (4 GiB)
# =============================================================================
#
# `StructuralIndex.offsets` is a `List[UInt32]` — a byte offset into the input
# buffer per structural token. Past 2^32 bytes the offset WRAPS, and the tape's
# strict-monotonicity invariant is the ONLY thing keeping every derived range
# non-inverted. An inverted range reaches
# `ArrowStringBuilder.push_bytes(bytes[v_start:v_end])` with `v_end < v_start`,
# i.e. a negative-length `Span` — measured to be a silent `memcpy` with a
# wrapped count even at `ASSERT=safe`.
#
# Reachability is not theoretical: `build_structural_index`,
# `materialize_jsonl_to_batch` and `materialize_jsonl_to_batch_parallel` are all
# public, and the parallel partitioner caps at 32 workers, so a 160 GB JSONL
# yields 5 GB partitions.
comptime MAX_STRUCTURAL_INDEX_BYTES: Int = 4294967295  # 2**32 - 1


def check_structural_index_input_size(n: Int) raises:
    """Raise if a byte buffer is too large for the UInt32 structural tape.

    Called ONCE per `build_structural_index` invocation — never per byte.

    Raises:
        Error naming the actual size and the ceiling, so a caller feeding a
        multi-GB buffer learns to partition it rather than seeing a corrupt
        column.
    """
    if n < 0:
        raise Error(
            "JSON structural index: negative buffer length ("
            + String(n)
            + "); the input Span is malformed."
        )
    if n > MAX_STRUCTURAL_INDEX_BYTES:
        raise Error(
            "JSON structural index: input buffer is "
            + String(n)
            + " bytes, which exceeds the "
            + String(MAX_STRUCTURAL_INDEX_BYTES)
            + "-byte (4 GiB) limit. The structural tape stores each token's"
            + " byte offset as a UInt32; past this size the offsets wrap and"
            + " every derived value range becomes inverted. Split the input"
            + " into <4 GiB partitions (see _compute_jsonl_line_ranges) or"
            + " use the chunked streaming reader"
            + " (read_jsonl_streamed_to_batches)."
        )


# =============================================================================
# 2. Column-cardinality + cell-budget ceilings
# =============================================================================
#
# On the inferred-schema path the column count is the number of DISTINCT JSON
# keys seen anywhere in the file, and the row count is the number of top-level
# objects. NEITHER had a ceiling, and the materializer allocates
# `rows x cols` — not `rows x populated-cells` — because it builds nine
# accumulator structs per column and pushes exactly one value-or-null into
# EVERY column for EVERY row.
#
# That makes allocation QUADRATIC in a quantity the attacker picks twice over.
# A ~1.4 MB file (one row declaring 100k distinct short keys, then 100k rows of
# `{}`) demands ~10^10 accumulator entries — tens of GB. This is not a bounds
# check at all, so it fails identically at `ASSERT=safe` and `ASSERT=none`; it
# was simply unprotected; an unbounded allocation of this class can take
# down the whole host through the kernel OOM killer.
#
# 4096 distinct keys is far past any real JSON document shape while still
# rejecting the cardinality attack at inference time.
comptime MAX_JSON_COLUMNS: Int = 4096

# Ceiling on `rows * columns` — the TRUE allocation driver, and the reason the
# column cap alone is not sufficient: with cols capped at 4096 a 1 MB file can
# still declare 349k rows of `{}`, and 349k x 4096 is still 1.4e9 cells.
#
# The bound is stated PER INPUT BYTE rather than as an absolute, because the
# invariant that was actually broken is "allocation is O(input bytes)". The
# densest legitimate JSONL spends ~6 bytes of input per populated cell
# (`"k":v,`), and a sparse-but-real file — a wide union schema whose rows carry
# only a couple of keys — tops out around 60 cells/byte. 256 is ~4x past that
# worst legitimate shape, and still rejects the adversarial shapes decisively:
#   * 100k keys x 100k `{}` rows (1.4 MB): demands ~1e10 cells, allowed 3.6e8.
#   * 4096 cols x 349k `{}` rows (1 MB):   demands  1.4e9 cells, allowed 2.6e8.
comptime MAX_JSON_CELLS_PER_INPUT_BYTE: Int = 256


def check_json_column_count(n: Int) raises:
    """Raise if a JSON schema declares more columns than the reader will
    materialize.

    Called ONCE per materialize / per inferred schema — before any accumulator
    is constructed, which is the point of the check: the allocation this
    guards has not happened yet.
    """
    if n > MAX_JSON_COLUMNS:
        raise Error(
            "JSON reader: schema declares "
            + String(n)
            + " columns, exceeding the "
            + String(MAX_JSON_COLUMNS)
            + "-column limit. Every column costs a full set of per-row"
            + " accumulators, so column count multiplies the row count into"
            + " the allocation. A document with this many distinct keys is"
            + " almost certainly key-per-value data that should be read as a"
            + " MAP column, not inferred into a wide schema."
        )


def max_rows_for_columns(n_cols: Int, input_bytes: Int) raises -> Int:
    """Return the row ceiling implied by the cell budget for `n_cols` columns
    over an `input_bytes`-byte input.

    Computed ONCE by the materializer; the per-row check is then a single
    `Int` compare against the returned value — no division or multiply in the
    row loop.
    """
    var budget = MAX_JSON_CELLS_PER_INPUT_BYTE * (input_bytes + 1)
    if n_cols <= 0:
        return budget
    return budget // n_cols


def raise_json_cell_budget_exceeded(
    rows: Int, n_cols: Int, input_bytes: Int
) raises:
    """Raise the cell-budget error. Split out of the row loop so the loop body
    carries only the compare plus a call that is never taken in practice."""
    raise Error(
        "JSON reader: materializing "
        + String(rows)
        + " rows x "
        + String(n_cols)
        + " columns = "
        + String(rows * n_cols)
        + " accumulator cells from a "
        + String(input_bytes)
        + "-byte input, exceeding the budget of "
        + String(MAX_JSON_CELLS_PER_INPUT_BYTE)
        + " cells per input byte. The reader allocates one accumulator slot"
        + " per (row, column) pair regardless of how many are POPULATED, so a"
        + " wide schema over many near-empty objects allocates quadratically"
        + " in two quantities the input controls. Project fewer columns, or"
        + " read the file through the chunked streaming reader"
        + " (read_jsonl_streamed_to_batches)."
    )


# =============================================================================
# 3. Arrow-32 string-offset ceiling
# =============================================================================
#
# Arrow's STRING layout caps ONE array's data buffer at 2^31-1 bytes; the
# offsets are Int32 and `ArrowStringBuilder` narrows with a bare `Int32(...)`.
# Past 2 GiB accumulated in one column of one batch the offsets wrap NEGATIVE
# while the data buffer is correctly large, so the array ships with
# `offsets[i] < 0` and every consumer doing `data[offsets[i]:offsets[i+1]]`
# reads before the buffer. LARGE_STRING exists precisely for this case.
comptime MAX_ARROW_STRING_BYTES: Int = 2147483647  # 2**31 - 1


def check_arrow_string_bytes(total_bytes: Int, column_name: String) raises:
    """Raise if one STRING column's accumulated bytes would overflow Int32
    offsets.

    Called ONCE per column at build time (the total is already summed by then),
    NOT per appended value.
    """
    if total_bytes > MAX_ARROW_STRING_BYTES:
        raise Error(
            "JSON reader: STRING column '"
            + column_name
            + "' accumulated "
            + String(total_bytes)
            + " bytes, exceeding the Arrow STRING limit of "
            + String(MAX_ARROW_STRING_BYTES)
            + " bytes (Int32 offsets). Past this size the offset buffer wraps"
            + " negative and readers index before the data buffer. Split the"
            + " input into smaller batches, or promote the column to"
            + " LARGE_STRING (64-bit offsets)."
        )


# =============================================================================
# 4. Streaming max-line ceiling
# =============================================================================
#
# The chunked streaming reader carries a trailing partial line forward into the
# next chunk and re-copies it on every read. A JSONL file with NO unescaped
# newline — or one opening `"` that swallows the rest of the file — makes the
# carry grow by one chunk per read, so the loop copies O(file^2) bytes, holds
# ~2x the file resident, and finally materializes the whole file as ONE line.
# The chunked path exists specifically to BOUND resident bytes for >100 MB
# files; a max-line ceiling is the missing half of that contract.
comptime MAX_JSONL_LINE_BYTES: Int = 268435456  # 256 MiB


def check_jsonl_carry_size(
    carry_len: Int, chunk_bytes: Int, max_line_bytes: Int
) raises:
    """Raise if the streaming reader's carry-forward partial line has grown
    past `max_line_bytes` (defaults to `MAX_JSONL_LINE_BYTES` at the call
    site).

    Called ONCE per chunk read (i.e. once per 4 MiB by default), never per
    byte.
    """
    if carry_len > max_line_bytes:
        raise Error(
            "JSONL streaming reader: a single line has reached "
            + String(carry_len)
            + " bytes without a terminating newline, exceeding the "
            + String(max_line_bytes)
            + "-byte line limit (chunk size "
            + String(chunk_bytes)
            + " bytes). This is usually an unterminated JSON string: an"
            + " opening quote with no closing quote makes every subsequent"
            + " newline string-interior, so the splitter never finds a line"
            + " end and the carry buffer grows by one chunk per read"
            + " (quadratic copy, ~2x file resident)."
        )
