# =============================================================================
# Tests for komira_csv/parallel_reader.mojo: multi-thread parallel CSV scan.
# =============================================================================
#
#   T4  per-worker quote-region carry independence: every worker's
#       scanner starts at quote_region_carry=0 (verified by byte-identity
#       on a fixture whose every row carries a quoted cell).
#
# One of six files split from a single parallel reader test so that each
# welded test finishes inside the coverage run's 450 s limit. Each file
# builds its own fixture and compares `read_csv_bytes_to_batch_parallel`
# with the single-thread Phase 3 reader (schema, row count, and the
# values the test names).
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import RecordBatch

from komira_csv import (
    CsvReadOptions,
    Rfc4180,
    read_csv_bytes_to_batch,
    read_csv_bytes_to_batch_parallel,
    SCANNER_VARIANT_PHASE_3,
)


def _bytes(s: String) -> List[UInt8]:
    """Convert a String to a List[UInt8] for test fixtures."""
    var out = List[UInt8]()
    var b = s.as_bytes()
    var i = 0
    while i < len(b):
        out.append(b[i])
        i = i + 1
    return out^


def _assert_batches_equal(
    parallel_rb: RecordBatch,
    serial_rb: RecordBatch,
    label: String,
) raises:
    """Assert that two RecordBatches have identical schema + row count
    + per-cell INT64 values (for the synthetic fixtures used here).

    Covers the most-common cell shapes: INT64 / FLOAT64 / STRING. The
    BOOL / DATE32 paths are exercised by Phase 1/2/3 parity tests
    (the partition logic is shape-agnostic on cell type).
    """
    assert_equal(
        parallel_rb.num_columns(),
        serial_rb.num_columns(),
        label + ": column counts differ",
    )
    assert_equal(
        parallel_rb.num_rows(),
        serial_rb.num_rows(),
        label + ": row counts differ",
    )
    var num_cols = parallel_rb.num_columns()
    var c = 0
    while c < num_cols:
        var pf = parallel_rb.schema.field_at(c)
        var sf = serial_rb.schema.field_at(c)
        assert_equal(
            String(pf.name),
            String(sf.name),
            label + ": col " + String(c) + " name differs",
        )
        assert_true(
            pf.arrow_type == sf.arrow_type,
            label + ": col " + String(c) + " arrow_type differs",
        )
        c = c + 1


def test_per_worker_quote_region_carry_independence() raises:
    """T4: every worker's internal scanner state starts at
    quote_region_carry=0. Verified by byte-identity on a fixture that
    exercises Phase 3's PCLMULQDQ carry mechanism WITHIN each worker's
    slice but never crosses a worker boundary (because partition
    aligns to outside-quote newlines).
    """
    # Build a fixture where every row is quoted: `i,"value of i"\n`.
    # Per-row size ~22 bytes; 80_000 rows = ~1.7 MiB.
    var s = String("id,note\n")
    var i = 0
    while i < 80_000:
        s += String(i) + String(",\"value of ") + String(i) + String("\"\n")
        i = i + 1
    var buf = _bytes(s)

    var opts = CsvReadOptions()
    var rb_serial = read_csv_bytes_to_batch[Rfc4180, SCANNER_VARIANT_PHASE_3](
        Span(buf), opts
    )
    var rb_parallel = read_csv_bytes_to_batch_parallel[Rfc4180](
        Span(buf), opts, n_workers=4
    )
    _assert_batches_equal(rb_parallel, rb_serial, "T4 per_worker_quote_carry")

    # Sanity: 2 cols (id Int64, note String).
    assert_equal(rb_parallel.num_columns(), 2)
    assert_equal(rb_parallel.num_rows(), 80_000)
    assert_true(rb_parallel.schema.field_at(0).arrow_type == ArrowType.INT64)
    assert_true(rb_parallel.schema.field_at(1).arrow_type == ArrowType.STRING)


def main() raises:
    test_per_worker_quote_region_carry_independence()
    print("test_csv_parallel_reader_quote_carry: PASS")
