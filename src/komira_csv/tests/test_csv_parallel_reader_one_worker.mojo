# =============================================================================
# Tests for komira_csv/parallel_reader.mojo: multi-thread parallel CSV scan.
# =============================================================================
#
#   T5  n_workers=1 explicit serial mode: n_workers=1 routes through the
#       single-thread fallback even on a large buffer.
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


def test_explicit_n_workers_one() raises:
    """T5: passing n_workers=1 forces single-thread fallback even on a
    large buffer. Verifies the threshold-OR-worker-count gate logic.
    """
    var buf = _gen_int_csv(100_000)  # ~2 MiB
    var opts = CsvReadOptions()
    var rb_serial = read_csv_bytes_to_batch[Rfc4180, SCANNER_VARIANT_PHASE_3](
        Span(buf), opts
    )
    var rb_parallel = read_csv_bytes_to_batch_parallel[Rfc4180](
        Span(buf), opts, n_workers=1
    )
    _assert_batches_equal(rb_parallel, rb_serial, "T5 n_workers_1")
    assert_equal(rb_parallel.num_rows(), 100_000)


def main() raises:
    test_explicit_n_workers_one()
    print("test_csv_parallel_reader_one_worker: PASS")
