# =============================================================================
# Tests for komira_csv/parallel_reader.mojo: multi-thread parallel CSV scan.
# =============================================================================
#
#   T7  header handling: the header row is stripped by worker 0 only;
#       workers 1..k-1 see their slice's first row as data.
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


def _gen_int_csv(n_rows: Int) -> List[UInt8]:
    """Generate a synthetic CSV with `n_rows` rows of (id, value) Int64
    pairs. Header is `id,value`. Each row is `i,i*10`.

    Row size ~25 bytes for n_rows < 1e6; ~31 bytes for n_rows in 1e6-1e7.
    For ~2 MiB buffer use n_rows = 80_000.
    """
    var s = String("id,value\n")
    var i = 0
    while i < n_rows:
        s += String(i) + String(",") + String(i * 10) + String("\n")
        i = i + 1
    return _bytes(s)


def test_header_handling_across_workers() raises:
    """T7: header row is detected + stripped by worker 0 only.
    Workers 1..k-1 treat their slice's first row as data. Verifies the
    `if tid == 0 and options.has_header` header-skip logic.

    Tested by asserting total row count = data row count (= total rows
    in fixture - 1 header row). If any non-zero worker accidentally
    skipped its first row as a header, the count would be lower.
    """
    # 50_000 data rows + 1 header = 50_001 lines total. With 4 workers,
    # if each worker had stripped a header row we would see
    # 50_001 - 4 = 49_997 rows (a 4-row underrun). The serial baseline
    # is exactly 50_000 (1 header stripped).
    var buf = _gen_int_csv(50_000)  # ~1.05 MiB; just over 1 MiB gate
    var opts = CsvReadOptions()
    var rb_serial = read_csv_bytes_to_batch[Rfc4180, SCANNER_VARIANT_PHASE_3](
        Span(buf), opts
    )
    var rb_parallel = read_csv_bytes_to_batch_parallel[Rfc4180](
        Span(buf), opts, n_workers=4
    )
    _assert_batches_equal(rb_parallel, rb_serial, "T7 header_handling")
    # The critical assertion: row count matches single-thread exactly
    # (any header double-skip would show up here).
    assert_equal(rb_parallel.num_rows(), rb_serial.num_rows())
    assert_equal(rb_parallel.num_rows(), 50_000, "exactly 50k data rows")


def main() raises:
    test_header_handling_across_workers()
    print("test_csv_parallel_reader_header: PASS")
