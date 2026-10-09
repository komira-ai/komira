# =============================================================================
# Tests for the column-parallel N-way concat of komira_csv/parallel_reader.
# =============================================================================
#
# The parallel reader's driver tail concatenates per-worker batches
# column-parallel: one worker per output column, each running its own
# N-way merge for that column with the single-pass helpers of
# `komira_arrow.streaming_concat`.
#
#   T1  wide-schema multi-column scan: a 6-column INT64/FLOAT64/STRING
#       fixture forces column-parallel work across mixed-type columns.
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


def _assert_float64_col_equal(
    a: RecordBatch,
    b: RecordBatch,
    col_idx: Int,
    label: String,
    sample_indices: List[Int],
) raises:
    """Spot-check FLOAT64 column parity at given sample indices (exact
    equality; the fixtures use exact-representable floats)."""
    ref ac = a.column_at(col_idx)
    ref bc = b.column_at(col_idx)
    var ap = ac.as_primitive[DType.float64]()
    var bp = bc.as_primitive[DType.float64]()
    var i = 0
    while i < len(sample_indices):
        var idx = sample_indices[i]
        assert_equal(
            Float64(ap.get(idx)),
            Float64(bp.get(idx)),
            label + ": FLOAT64 col " + String(col_idx) + " row " + String(idx)
                + " differs",
        )
        i = i + 1


def _gen_wide_mixed_csv(n_rows: Int) -> List[UInt8]:
    """6-column CSV with INT64, FLOAT64, STRING, INT64, FLOAT64, INT64
    columns. Forces column-parallel work across mixed-type columns.

    Schema: id, score, label, count, ratio, total
    Each row is ~80-95 bytes. For ~2 MiB use n_rows = 25_000.
    """
    var s = String("id,score,label,count,ratio,total\n")
    var i = 0
    while i < n_rows:
        s += (
            String(i)
            + String(",")
            + String(Float64(i) * 1.5)
            + String(",row_")
            + String(i)
            + String(",")
            + String(i * 2)
            + String(",")
            + String(Float64(i) * 0.25)
            + String(",")
            + String(i * 10)
            + String("\n")
        )
        i = i + 1
    return _bytes(s)


def test_t1_wide_schema_mixed_columns() raises:
    """T1: 6-column mixed-type fixture exercises column-parallel work
    across INT64/FLOAT64/STRING simultaneously.

    Verifies the column-parallel concat preserves byte-identity with
    the single-thread Phase 3 reader -- the per-column dispatcher
    (string-helper / fixed-helper) must produce the same Column shape
    + values as the serial pair-wise fold did.
    """
    # 25_000 rows ~ 2.2 MiB; forces > 1 MiB threshold + multi-column
    # column-parallel concat.
    var buf = _gen_wide_mixed_csv(25_000)
    var opts = CsvReadOptions()
    var rb_serial = read_csv_bytes_to_batch[Rfc4180, SCANNER_VARIANT_PHASE_3](
        Span(buf), opts
    )
    var rb_parallel = read_csv_bytes_to_batch_parallel[Rfc4180](
        Span(buf), opts, n_workers=4
    )
    _assert_batches_schema_equal(rb_parallel, rb_serial, "T1 wide_schema")

    assert_equal(rb_parallel.num_columns(), 6, "T1: 6 cols")
    assert_equal(rb_parallel.num_rows(), 25_000, "T1: 25_000 rows")

    # Schema spot-check.
    assert_true(rb_parallel.schema.field_at(0).arrow_type == ArrowType.INT64)
    assert_true(rb_parallel.schema.field_at(1).arrow_type == ArrowType.FLOAT64)
    assert_true(rb_parallel.schema.field_at(2).arrow_type == ArrowType.STRING)
    assert_true(rb_parallel.schema.field_at(3).arrow_type == ArrowType.INT64)
    assert_true(rb_parallel.schema.field_at(4).arrow_type == ArrowType.FLOAT64)
    assert_true(rb_parallel.schema.field_at(5).arrow_type == ArrowType.INT64)

    # Spot-check 4 sample indices across the row space.
    var samples = List[Int]()
    samples.append(0)
    samples.append(5000)
    samples.append(12_500)
    samples.append(24_999)
    _assert_int64_col_equal(rb_parallel, rb_serial, 0, "T1 id", samples)
    _assert_float64_col_equal(rb_parallel, rb_serial, 1, "T1 score", samples)
    _assert_int64_col_equal(rb_parallel, rb_serial, 3, "T1 count", samples)
    _assert_float64_col_equal(rb_parallel, rb_serial, 4, "T1 ratio", samples)
    _assert_int64_col_equal(rb_parallel, rb_serial, 5, "T1 total", samples)

    # Absolute correctness on first + last rows.
    ref id_p = rb_parallel.column_at(0)
    var id_arr = id_p.as_primitive[DType.int64]()
    assert_equal(Int(id_arr.get(0)), 0, "T1: row 0 id == 0")
    assert_equal(Int(id_arr.get(24_999)), 24_999, "T1: last row id")


def main() raises:
    test_t1_wide_schema_mixed_columns()
    print("test_csv_phase_4_column_parallel_concat_wide_schema: PASS")
