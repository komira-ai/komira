# =============================================================================
# type_inference — per-column type inference over an N-row sample prefix.
# =============================================================================
#
# Infer one ArrowType per column over the first N rows
# (CsvReadOptions.infer_rows; default 100; -1 = whole file). The inference
# lattice is:
#
#   Int64 -> Float64 -> Date32 -> Bool -> String
#                                          ^---- fallback (always works)
#
# A column is INT64 iff every non-null cell parses as Int64.
# A column is FLOAT64 iff every non-null cell parses as Float64 (incl. ints).
# A column is DATE32 iff every non-null cell parses as `YYYY-MM-DD`.
# A column is BOOL iff every non-null cell matches true_strings or false_strings.
# Otherwise the column is STRING.
#
# The ordering matters: Int64 is stricter than Float64; Date32 is independent
# (10-char ISO format). Bool also requires Float/Int to fail (so "1"/"0"
# columns don't become Bool by accident — they stay Int64).
#
# Wider default coverage (UInt*, smaller Int widths, DECIMAL128, Float32,
# Date64, TIMESTAMP_*) is not inferred; the chassis below threads the
# inferred ArrowType through to the builder layer regardless.
# =============================================================================

from komira_arrow.arrow_types import ArrowType

from .csv_options import CsvReadOptions
from .scanned_cells import ScannedCells
from .cell_parsers import (
    _try_parse_int64,
    _try_parse_float64,
    _try_parse_bool,
    _try_parse_date32,
)
from .temporal_parsers import (
    _try_parse_date64,
    _try_parse_timestamp_s,
    _try_parse_timestamp_ms,
    _try_parse_timestamp_us,
    _try_parse_timestamp_ns,
    _try_parse_time_s,
    _try_parse_time_ms,
    _try_parse_time_us,
    _try_parse_time_ns,
    _try_parse_duration_s,
    _try_parse_duration_ms,
    _try_parse_duration_us,
    _try_parse_duration_ns,
)
from .null_detection import is_null_cell


def infer_column_types(
    bytes: Span[UInt8, _],
    cells: ScannedCells,
    data_start: Int,
    n_rows_total: Int,
    num_cols: Int,
    options: CsvReadOptions,
) raises -> List[ArrowType]:
    """Infer one ArrowType per column over an N-row sample.

    Args:
        bytes:        The full file byte-span (cell ranges reference into this).
        cells:        The scanned cells (flat-buffer).
        data_start:   Offset of the first DATA row (1 if header present, else 0).
        n_rows_total: Total number of data rows (already excludes header).
        num_cols:     Column count (taken from header / first data row).
        options:      CsvReadOptions (provides null_strings + true/false_strings).

    Returns:
        List[ArrowType] of length `num_cols`. Defaults to STRING when no
        rows are available for inference.
    """
    var result = List[ArrowType]()
    var infer_rows = options.infer_rows
    var n_rows_sample = n_rows_total
    if infer_rows >= 0 and infer_rows < n_rows_total:
        n_rows_sample = infer_rows

    var col = 0
    while col < num_cols:
        var all_int = True
        var all_float = True
        var all_date = True
        var all_bool = True
        var saw_any_non_null = False

        var r = 0
        while r < n_rows_sample:
            var row_idx = data_start + r
            if col >= cells.num_cells_in_row(row_idx):
                r = r + 1
                continue
            var cs = cells.cell_start(row_idx, col)
            var ce = cells.cell_end(row_idx, col)
            var cell = bytes[cs:ce]
            if is_null_cell(cell, options):
                r = r + 1
                continue
            saw_any_non_null = True

            if all_int:
                if not _try_parse_int64(cell):
                    all_int = False
            if all_float:
                if not _try_parse_float64(cell, options.decimal_separator):
                    all_float = False
            if all_date:
                if not _try_parse_date32(cell):
                    all_date = False
            if all_bool:
                if not _try_parse_bool(cell, options):
                    all_bool = False

            # Early exit if every typed inference has failed.
            if not all_int and not all_float and not all_date and not all_bool:
                break
            r = r + 1

        # Resolve the column type. Order: most-specific to most-general.
        if not saw_any_non_null:
            # All-null column: default to STRING (matches pandas).
            result.append(ArrowType.STRING)
        elif all_int:
            result.append(ArrowType.INT64)
        elif all_date:
            result.append(ArrowType.DATE32)
        elif all_bool:
            result.append(ArrowType.BOOL)
        elif all_float:
            result.append(ArrowType.FLOAT64)
        else:
            result.append(ArrowType.STRING)
        col = col + 1
    return result^


# =============================================================================
# Wider type inference.
# =============================================================================
#
# `infer_column_types_wide` adds temporal types (Date64 / Timestamp_*/
# Time_* / Duration_*) to the inference lattice. Existing 5-type lattice
# (Int64/Float64/Date32/Bool/String) preserved for the default
# `infer_column_types` entry; this is an opt-in widening for callers that
# need temporal-type inference.
#
# Priority order (most-specific first; first match wins after the per-row
# scan):
#   Int64 ->  most precision-conscious numeric (no fraction)
#   Date32 -> ISO 'YYYY-MM-DD' exact 10-char form
#   Date64 -> ISO datetime (date OR 'YYYY-MM-DD HH:MM:SS...')
#   Timestamp_NS -> max-precision datetime
#   Timestamp_US -> us-precision datetime
#   Timestamp_MS -> ms-precision datetime
#   Timestamp_S  -> seconds (rejects sub-second)
#   Time_NS / Time_US / Time_MS / Time_S -> HH:MM:SS[.fff[fff[fff]]]
#   Duration_NS / Duration_US / Duration_MS / Duration_S -> ISO 8601 P-grammar
#   Bool   -> only true_/false_strings
#   Float64 -> widest numeric
#   String  -> fallback
#
# Resolution rules (after the scan):
#   - all-Int64 cells => INT64.
#   - all-Date32 cells (independent of others) => DATE32 (only if Int fails).
#   - all-Date64 cells => DATE64 (preferred over Timestamp_* because Date64
#     is the canonical ms-since-epoch wire form pandas emits).
#   - all-Timestamp_S cells => TIMESTAMP_S (sub-second-free datetimes).
#   - any all-Timestamp_NS/US/MS => TIMESTAMP_NS (narrowest fits all).
#   - all-Time_* (preferring narrowest unit that fits) => TIME64_NS / etc.
#   - all-Duration_* => DURATION_NS (narrowest fits all).
#   - all-Bool => BOOL.
#   - all-Float64 => FLOAT64.
#   - else => STRING.


def infer_column_types_wide(
    bytes: Span[UInt8, _],
    cells: ScannedCells,
    data_start: Int,
    n_rows_total: Int,
    num_cols: Int,
    options: CsvReadOptions,
) raises -> List[ArrowType]:
    """Infer ArrowType per column over an N-row sample, widened to temporal
    types (Date64 / Timestamp_* / Time_* / Duration_*).

    Adds temporal coverage to the
    5-type default lattice; callers can opt in for files where datetime/
    duration columns must be inferred (vs forced via per-column overrides).
    """
    var result = List[ArrowType]()
    var infer_rows = options.infer_rows
    var n_rows_sample = n_rows_total
    if infer_rows >= 0 and infer_rows < n_rows_total:
        n_rows_sample = infer_rows

    var col = 0
    while col < num_cols:
        var all_int = True
        var all_float = True
        var all_date32 = True
        var all_date64 = True
        var all_ts_s = True
        var all_ts_ms = True
        var all_ts_us = True
        var all_ts_ns = True
        var all_time_s = True
        var all_time_ms = True
        var all_time_us = True
        var all_time_ns = True
        var all_dur_s = True
        var all_dur_ms = True
        var all_dur_us = True
        var all_dur_ns = True
        var all_bool = True
        var saw_any_non_null = False

        var r = 0
        while r < n_rows_sample:
            var row_idx = data_start + r
            if col >= cells.num_cells_in_row(row_idx):
                r = r + 1
                continue
            var cs = cells.cell_start(row_idx, col)
            var ce = cells.cell_end(row_idx, col)
            var cell = bytes[cs:ce]
            if is_null_cell(cell, options):
                r = r + 1
                continue
            saw_any_non_null = True

            if all_int and not _try_parse_int64(cell):
                all_int = False
            if all_float and not _try_parse_float64(cell, options.decimal_separator):
                all_float = False
            if all_date32 and not _try_parse_date32(cell):
                all_date32 = False
            if all_date64 and not _try_parse_date64(cell):
                all_date64 = False
            if all_ts_s and not _try_parse_timestamp_s(cell):
                all_ts_s = False
            if all_ts_ms and not _try_parse_timestamp_ms(cell):
                all_ts_ms = False
            if all_ts_us and not _try_parse_timestamp_us(cell):
                all_ts_us = False
            if all_ts_ns and not _try_parse_timestamp_ns(cell):
                all_ts_ns = False
            if all_time_s and not _try_parse_time_s(cell):
                all_time_s = False
            if all_time_ms and not _try_parse_time_ms(cell):
                all_time_ms = False
            if all_time_us and not _try_parse_time_us(cell):
                all_time_us = False
            if all_time_ns and not _try_parse_time_ns(cell):
                all_time_ns = False
            if all_dur_s and not _try_parse_duration_s(cell):
                all_dur_s = False
            if all_dur_ms and not _try_parse_duration_ms(cell):
                all_dur_ms = False
            if all_dur_us and not _try_parse_duration_us(cell):
                all_dur_us = False
            if all_dur_ns and not _try_parse_duration_ns(cell):
                all_dur_ns = False
            if all_bool and not _try_parse_bool(cell, options):
                all_bool = False

            r = r + 1

        # Resolve type: order most-specific to most-general.
        if not saw_any_non_null:
            result.append(ArrowType.STRING)
        elif all_int:
            result.append(ArrowType.INT64)
        elif all_date32:
            # 'YYYY-MM-DD' exact 10-char form — preferred over Date64 for
            # date-only columns (smaller wire format).
            result.append(ArrowType.DATE32)
        elif all_date64:
            # Date64 covers both date-only and datetime. Reserve TIMESTAMP_*
            # for cells that exercise sub-second precision.
            result.append(ArrowType.DATE64)
        elif all_ts_s:  # cov: unreachable kcov records no hit on an elif line, which runs whenever an earlier arm fails; the arm body is unreachable: a Timestamp_S or _MS cell also parses as Date64, which wins (issue 1126)
            result.append(ArrowType.TIMESTAMP_S)  # cov: unreachable a Timestamp_S or _MS cell also parses as Date64, which wins (issue 1126)
        elif all_ts_ms:  # cov: unreachable kcov records no hit on an elif line, which runs whenever an earlier arm fails; the arm body is unreachable: a Timestamp_S or _MS cell also parses as Date64, which wins (issue 1126)
            result.append(ArrowType.TIMESTAMP_MS)  # cov: unreachable a Timestamp_S or _MS cell also parses as Date64, which wins (issue 1126)
        elif all_ts_us:
            result.append(ArrowType.TIMESTAMP_US)
        elif all_ts_ns:
            result.append(ArrowType.TIMESTAMP_NS)
        elif all_time_s:
            result.append(ArrowType.TIME32_S)
        elif all_time_ms:
            result.append(ArrowType.TIME32_MS)
        elif all_time_us:
            result.append(ArrowType.TIME64_US)
        elif all_time_ns:
            result.append(ArrowType.TIME64_NS)
        elif all_dur_s:
            result.append(ArrowType.DURATION_S)
        elif all_dur_ms:  # cov: unreachable kcov records no hit on an elif line, which runs whenever an earlier arm fails; the arm body is unreachable: Duration_MS/US/NS accept exactly the cells Duration_S accepts (issue 1126)
            result.append(ArrowType.DURATION_MS)  # cov: unreachable Duration_MS/US/NS accept exactly the cells Duration_S accepts (issue 1126)
        elif all_dur_us:  # cov: unreachable kcov records no hit on an elif line, which runs whenever an earlier arm fails; the arm body is unreachable: Duration_MS/US/NS accept exactly the cells Duration_S accepts (issue 1126)
            result.append(ArrowType.DURATION_US)  # cov: unreachable Duration_MS/US/NS accept exactly the cells Duration_S accepts (issue 1126)
        elif all_dur_ns:  # cov: unreachable kcov records no hit on an elif line, which runs whenever an earlier arm fails; the arm body is unreachable: Duration_MS/US/NS accept exactly the cells Duration_S accepts (issue 1126)
            result.append(ArrowType.DURATION_NS)  # cov: unreachable Duration_MS/US/NS accept exactly the cells Duration_S accepts (issue 1126)
        elif all_bool:
            result.append(ArrowType.BOOL)
        elif all_float:
            result.append(ArrowType.FLOAT64)
        else:
            result.append(ArrowType.STRING)
        col = col + 1
    return result^
