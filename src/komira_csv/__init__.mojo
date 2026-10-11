"""`komira_csv` — CSV chassis: FSA + ContainsZeroByte scanner + 3 QuoteStyles.


Public surface (consumers: the plan compiler's CSV scan arm,
komira_sdk `ctx.read_csv`):
  - QuoteStyle trait + 3 conformers (Rfc4180 / Excel / Posix)
  - CsvReadOptions: options struct with no pointer fields (InlineArray-bounded
    null/true/false token sets)
  - is_null_cell / is_true_cell / is_false_cell: null-detection helpers
  - Row, CellRange, scan_csv_phase1: low-level scanner surface
  - read_csv_to_batch, read_csv_to_batch_with_options,
    read_csv_bytes_to_batch: high-level entry points (slurp +
    materialize -> RecordBatch).
"""

from .quote_styles import QuoteStyle, Rfc4180, Excel, Posix
from .csv_options import (
    CsvReadOptions,
    MAX_NULL_STRINGS,
    MAX_TRUE_FALSE_STRINGS,
    DEFAULT_MAX_ROW_BYTES,
    QUOTE_STYLE_TAG_RFC4180,
    QUOTE_STYLE_TAG_EXCEL,
    QUOTE_STYLE_TAG_POSIX,
)
from .null_detection import is_null_cell, is_true_cell, is_false_cell
from .csv_scanner_phase1 import (
    Row,
    CellRange,
    scan_csv_phase1,
    scan_csv_phase2_movemask,
    scan_csv_phase3_pclmulqdq,
    # Flat-buffer
    # scanner variants emitting into ScannedCells (4 contiguous Lists)
    # instead of List[Row]; ~5-8x speedup over the per-row legacy shape.
    scan_csv_phase1_into_cells,
    scan_csv_phase2_movemask_into_cells,
    scan_csv_phase3_pclmulqdq_into_cells,
    # Projection-aware Phase 2
    # scanner that emits boundary metadata ONLY for the projected columns.
    scan_csv_phase2_movemask_projected,
    # Sibling primitive for the
    # row-streaming partition. Finds the first 0x0A at or after `start`
    # via 64-byte SIMD chunks; no quote/cell/state-machine overhead.
    # Consumed by the row-streaming CSV/JSONL readers.
    #
    # ⚠ For a CSV body specifically, prefer `compute_csv_quote_safe_row_ranges`
    # below: a raw `\n` is a row terminator only when it is OUTSIDE a quoted
    # field, and this primitive cannot tell. (JSONL has no quoted newlines, so
    # its use there is exact.)
    find_first_newline_simd,
)
from .csv_chunk_split import (
    # THE CSV body partitioner: quote-parity boundary classification plus an
    # FSA-agreement check, refusing to split what it cannot prove rather than
    # mis-splitting it. Consumed by BOTH parallel CSV readers.
    compute_csv_quote_safe_row_ranges,
    csv_split_is_quote_parity_safe,
)
from .scanned_cells import (
    ScannedCells,
    CELL_FLAG_WAS_QUOTED,
    CELL_FLAG_NEEDS_UNESCAPE,
    pack_cell_flags,
)
from .csv_state_machine import (
    CSV_STATE_STANDARD,
    CSV_STATE_QUOTED,
    CSV_STATE_QUOTE_IN_QUOTED,
    CSV_STATE_POSIX_ESCAPE,
    CSV_STATE_CR_LF_LOOKAHEAD,
    CSV_N_STATES,
    contains_zero_byte,
    contains_any_of_4,
    broadcast_byte,
    classify_byte,
)
from .cell_parsers import (
    _try_parse_int64,
    _try_parse_float64,
    _try_parse_date32,
    _try_parse_bool,
    # Widened DType
    # parsers (UInt*, smaller Int widths, Float32, Date64, Timestamp_*,
    # Time_*, Duration_*, Decimal128).
    _try_parse_uint8,
    _try_parse_uint16,
    _try_parse_uint32,
    _try_parse_uint64,
    _try_parse_int8,
    _try_parse_int16,
    _try_parse_int32,
    _try_parse_float32,
    _try_parse_decimal128_to_int64,
    cell_to_string,
    unescape_cell_double_quote,
    unescape_cell_posix,
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
from .type_inference import infer_column_types, infer_column_types_wide
from .reader import (
    read_csv_to_batch,
    read_csv_to_batch_with_options,
    read_csv_bytes_to_batch,
    # Runtime Q dispatcher.
    read_csv_bytes_to_batch_dynamic,
    SCANNER_VARIANT_PHASE_1,
    SCANNER_VARIANT_PHASE_2,
    SCANNER_VARIANT_PHASE_3,
    SCANNER_VARIANT_PHASE_4,
    DEFAULT_SCANNER_VARIANT,
)
from .parallel_reader import (
    read_csv_bytes_to_batch_parallel,
    # Runtime Q
    # dispatcher for the parallel reader, used by ctx.read_csv.
    read_csv_bytes_to_batch_parallel_dynamic,
    # Dispatcher-aware variant
    # (runtime worker pool via LocalDispatcher.run_with_state) — threaded
    # from ctx._read_csv_eager with ctx.dispatcher()/ctx.cancel_token().
    read_csv_bytes_to_batch_parallel_dynamic_with_dispatcher,
    _PARALLEL_SDK_BYTES_THRESHOLD,
)
# Per-DType
# typed builders that materialize the 22 widened parsers into Arrow columns.
from .typed_column_builders import dispatch_typed_builder
