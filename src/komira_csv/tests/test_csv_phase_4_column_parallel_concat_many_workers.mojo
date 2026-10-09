# =============================================================================
# Tests for the column-parallel N-way concat of komira_csv/parallel_reader.
# =============================================================================
#
# The parallel reader's driver tail concatenates per-worker batches
# column-parallel: one worker per output column, each running its own
# N-way merge for that column with the single-pass helpers of
# `komira_arrow.streaming_concat`.
#
#   T2  high-N many-batch concat: n_workers=0 (num_physical_cores)
#       exercises the concat with N on the order of 10.
#
# One of five files split from a single column-parallel concat test so
# that each welded test finishes inside the coverage run's 450 s limit.
# Each file builds its own fixture and asserts schema and row-count
# identity with the single-thread Phase 3 reader, plus value spot checks
# on specific rows.
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


def _bytes(s: String) -> List[UInt8]:
    """Convert a String to a List[UInt8] for test fixtures."""
    var out = List[UInt8]()
    var b = s.as_bytes()
    var i = 0
    while i < len(b):
        out.append(b[i])
        i = i + 1
    return out^


def _assert_batches_schema_equal(
    parallel_rb: RecordBatch,
    serial_rb: RecordBatch,
    label: String,
) raises:
    """Strict schema + row count equality."""
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


def _assert_int64_col_equal(
    a: RecordBatch,
    b: RecordBatch,
    col_idx: Int,
    label: String,
    sample_indices: List[Int],
) raises:
    """Spot-check INT64 column parity at given sample indices."""
    ref ac = a.column_at(col_idx)
    ref bc = b.column_at(col_idx)
    var ap = ac.as_primitive[DType.int64]()
    var bp = bc.as_primitive[DType.int64]()
    var i = 0
    while i < len(sample_indices):
        var idx = sample_indices[i]
        assert_equal(
            Int(ap.get(idx)),
            Int(bp.get(idx)),
            label + ": INT64 col " + String(col_idx) + " row " + String(idx)
                + " differs",
        )
        i = i + 1


def _gen_pure_int_csv(n_rows: Int) -> List[UInt8]:
    """Pure-numeric (INT64-only) CSV. Forces the fixed-width fast
    helper (`_concat_fixed_columns_multi`) on every column.

    Schema: a, b, c, d (4 INT64 cols).
    Each row ~25 bytes; for ~1.5 MiB use n_rows = 60_000.
    """
    var s = String("a,b,c,d\n")
    var i = 0
    while i < n_rows:
        s += (
            String(i)
            + String(",")
            + String(i * 2)
            + String(",")
            + String(i * 3)
            + String(",")
            + String(i * 4)
            + String("\n")
        )
        i = i + 1
    return _bytes(s)


def test_t2_high_n_many_workers() raises:
    """T2: high-N concat -- spawn `num_physical_cores()` workers on a
    large fixture. Verifies the column-parallel concat scales correctly
    when N (number of input batches) is on the order of 10+.

    n_workers=0 routes through `num_physical_cores()` (typically 8-10
    on dev machines). Output must remain byte-identical to single-thread.
    """
    var buf = _gen_pure_int_csv(80_000)  # ~2 MiB, 4 cols
    var opts = CsvReadOptions()
    var rb_serial = read_csv_bytes_to_batch[Rfc4180, SCANNER_VARIANT_PHASE_3](
        Span(buf), opts
    )
    # n_workers=0 -> num_physical_cores (high N).
    var rb_parallel = read_csv_bytes_to_batch_parallel[Rfc4180](
        Span(buf), opts, n_workers=0
    )
    _assert_batches_schema_equal(rb_parallel, rb_serial, "T2 high_n")
    assert_equal(rb_parallel.num_rows(), 80_000, "T2: 80_000 rows")
    assert_equal(rb_parallel.num_columns(), 4, "T2: 4 cols")

    # Sample 5 indices spanning the row range.
    var samples = List[Int]()
    samples.append(0)
    samples.append(10_000)
    samples.append(40_000)
    samples.append(70_000)
    samples.append(79_999)
    _assert_int64_col_equal(rb_parallel, rb_serial, 0, "T2 col0", samples)
    _assert_int64_col_equal(rb_parallel, rb_serial, 1, "T2 col1", samples)
    _assert_int64_col_equal(rb_parallel, rb_serial, 2, "T2 col2", samples)
    _assert_int64_col_equal(rb_parallel, rb_serial, 3, "T2 col3", samples)

    # Absolute correctness: col0[i] = i; col3[i] = i*4.
    ref c0 = rb_parallel.column_at(0)
    var a0 = c0.as_primitive[DType.int64]()
    assert_equal(Int(a0.get(40_000)), 40_000, "T2 col0[40000]")
    ref c3 = rb_parallel.column_at(3)
    var a3 = c3.as_primitive[DType.int64]()
    assert_equal(Int(a3.get(40_000)), 40_000 * 4, "T2 col3[40000]")


def main() raises:
    test_t2_high_n_many_workers()
    print("test_csv_phase_4_column_parallel_concat_many_workers: PASS")
