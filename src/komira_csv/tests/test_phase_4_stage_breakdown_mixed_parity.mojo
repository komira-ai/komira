# =============================================================================
# Tests for the parallel reader's per-stage timing instrumentation.
# =============================================================================
#
# `stage_timing=True` turns on per-stage timing in
# `komira_csv.parallel_reader.read_csv_bytes_to_batch_parallel` and prints
# one `[CSV_PHASE4_TIMING] ...` line per call. The instrumentation must not
# change the batch the reader returns.
#
#   T4  on a mixed-type fixture the parallel batch matches the
#       single-thread Phase 3 reader.
#
# One of four files split from a single stage-timing test so that each
# welded test finishes inside the coverage run's 450 s limit. Each file
# builds its own fixture.
# =============================================================================

from std.testing import assert_equal, assert_true

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
from komira_csv.parallel_reader import _PhaseTiming


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    var i = 0
    while i < len(b):
        out.append(b[i])
        i = i + 1
    return out^


def _gen_mixed_csv(n_rows: Int) -> List[UInt8]:
    """6-column INT64/FLOAT64/STRING/INT64/FLOAT64/INT64 CSV.

    Sized so n_rows = 25_000 produces ~2 MiB (above 1 MiB parallel
    threshold).
    """
    var s = String("id,score,label,count,ratio,total\n")
    var i = 0
    while i < n_rows:
        s += (
            String(i) + String(",")
            + String(Float64(i) * 1.5) + String(",row_")
            + String(i) + String(",")
            + String(i * 2) + String(",")
            + String(Float64(i) * 0.25) + String(",")
            + String(i * 10) + String("\n")
        )
        i = i + 1
    return _bytes(s)


def _assert_batches_equal_int64(
    a: RecordBatch, b: RecordBatch, col_idx: Int, label: String
) raises:
    ref ac = a.column_at(col_idx)
    ref bc = b.column_at(col_idx)
    var ap = ac.as_primitive[DType.int64]()
    var bp = bc.as_primitive[DType.int64]()
    assert_equal(
        a.num_rows(), b.num_rows(),
        label + ": row count differs"
    )
    var n = a.num_rows()
    var i = 0
    while i < n:
        assert_equal(
            Int(ap.get(i)), Int(bp.get(i)),
            label + ": col " + String(col_idx) + " row " + String(i)
        )
        i = i + 1


def test_t4_mixed_fixture_parity_with_serial() raises:
    var data = _gen_mixed_csv(25_000)
    var bytes = Span(data)
    var opts = CsvReadOptions()
    # Serial (ground truth via Phase 3 single-thread reader).
    var serial = read_csv_bytes_to_batch[Rfc4180, SCANNER_VARIANT_PHASE_3](
        bytes, opts
    )
    # Parallel, un-instrumented; T3 checks the instrumented path against
    # this one.
    var parallel = read_csv_bytes_to_batch_parallel[Rfc4180](bytes, opts, 4)
    assert_equal(parallel.num_rows(), serial.num_rows(), "T4: row counts")
    assert_equal(parallel.num_columns(), serial.num_columns(), "T4: col counts")
    # Spot-check INT64 col 0 (id).
    _assert_batches_equal_int64(parallel, serial, 0, "T4: id col")
    # Spot-check INT64 col 3 (count = i * 2).
    _assert_batches_equal_int64(parallel, serial, 3, "T4: count col")


def main() raises:
    test_t4_mixed_fixture_parity_with_serial()
    print("test_phase_4_stage_breakdown_mixed_parity: PASS")
