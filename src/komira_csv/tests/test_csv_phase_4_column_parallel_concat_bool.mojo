# =============================================================================
# Tests for the column-parallel N-way concat of komira_csv/parallel_reader.
# =============================================================================
#
# The parallel reader's driver tail concatenates per-worker batches
# column-parallel: one worker per output column, each running its own
# N-way merge for that column with the single-pass helpers of
# `komira_arrow.streaming_concat`.
#
#   T5  BOOL fallback: the BOOL column takes the per-column pair-wise
#       fallback while the INT64 columns take the fast helper.
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


def _gen_bool_mix_csv(n_rows: Int) -> List[UInt8]:
    """Mixed BOOL + INT64 CSV. Forces the BOOL column down the per-
    column pair-wise fallback path while INT64 columns take the fast
    helper -- exercises the cascade selection per column.

    Schema: id, active, count
    Each row ~16-20 bytes; for ~1.5 MiB use n_rows = 80_000.
    """
    var s = String("id,active,count\n")
    var i = 0
    while i < n_rows:
        var b: String
        if i % 2 == 0:
            b = String("true")
        else:
            b = String("false")
        s += (
            String(i)
            + String(",")
            + b
            + String(",")
            + String(i * 5)
            + String("\n")
        )
        i = i + 1
    return _bytes(s)


def test_t5_bool_fallback_path() raises:
    """T5: BOOL column exercises the per-column pair-wise fallback in
    `_concat_one_column_pairwise` (BOOL is not in the fixed-width
    fast-helper set). Other columns (INT64) still run via the fast
    helper -- the cascade picks the right path PER COLUMN.

    This verifies the mixed-cascade case where some columns take the
    fast path and others take the slow pair-wise fold, both within
    the same parallel dispatch.
    """
    var buf = _gen_bool_mix_csv(80_000)  # ~1.5 MiB
    var opts = CsvReadOptions()
    var rb_serial = read_csv_bytes_to_batch[Rfc4180, SCANNER_VARIANT_PHASE_3](
        Span(buf), opts
    )
    var rb_parallel = read_csv_bytes_to_batch_parallel[Rfc4180](
        Span(buf), opts, n_workers=4
    )
    _assert_batches_schema_equal(rb_parallel, rb_serial, "T5 bool_fallback")
    assert_equal(rb_parallel.num_columns(), 3, "T5: 3 cols")
    assert_equal(rb_parallel.num_rows(), 80_000, "T5: 80_000 rows")

    # Schema: id (INT64), active (BOOL), count (INT64).
    assert_true(rb_parallel.schema.field_at(0).arrow_type == ArrowType.INT64)
    assert_true(rb_parallel.schema.field_at(1).arrow_type == ArrowType.BOOL)
    assert_true(rb_parallel.schema.field_at(2).arrow_type == ArrowType.INT64)

    # INT64 fast-path columns.
    var samples = List[Int]()
    samples.append(0)
    samples.append(10_000)
    samples.append(40_000)
    samples.append(79_999)
    _assert_int64_col_equal(rb_parallel, rb_serial, 0, "T5 id", samples)
    _assert_int64_col_equal(rb_parallel, rb_serial, 2, "T5 count", samples)

    # BOOL pair-wise-fallback column: spot-check a few values.
    ref ap = rb_parallel.column_at(1)
    ref as_ = rb_serial.column_at(1)
    var bp = ap.as_boolean()
    var bs = as_.as_boolean()
    var i = 0
    while i < len(samples):
        var idx = samples[i]
        assert_equal(
            bp.get(idx),
            bs.get(idx),
            "T5: bool[" + String(idx) + "] parity",
        )
        i = i + 1
    # Absolute correctness: row[2*k].active = True; row[2*k+1].active = False.
    assert_equal(bp.get(0), True, "T5: bool[0] == True (absolute)")
    assert_equal(bp.get(1), False, "T5: bool[1] == False (absolute)")
    assert_equal(bp.get(40_000), True, "T5: bool[40000] == True (absolute)")
    assert_equal(bp.get(40_001), False, "T5: bool[40001] == False (absolute)")


def main() raises:
    test_t5_bool_fallback_path()
    print("test_csv_phase_4_column_parallel_concat_bool: PASS")
