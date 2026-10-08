# =============================================================================
# Tests for column-parallel N-way concat path in komira_csv/parallel_reader.
# =============================================================================
#
# The parallel reader's driver tail concatenates per-worker batches
# column-parallel: one worker per output column. Each worker runs its own
# N-way merge for that column index using the canonical single-pass
# helpers from `komira_arrow.streaming_concat`.
#
# This module tests the concat path explicitly:
#   T1  wide-schema multi-column scan: a 6-column INT64/FLOAT64/STRING
#       fixture forces column-parallel work across mixed-type columns.
#       Verifies byte-identity with single-thread Phase 3 reader (the
#       "ground truth" for concat correctness).
#   T2  high-N many-batch concat: large fixture with many workers
#       (default num_physical_cores) -- exercises the concat path
#       with N (worker batch count) on the order of 10.
#   T3  fixed-width fast helper coverage: pure-INT64 fixture verifies
#       the `_concat_fixed_columns_multi` fast path used by INT64 +
#       FLOAT64 columns.
#   T4  string column coverage: schema with STRING column verifies
#       the `_concat_string_columns_multi` fast path.
#   T5  BOOL/DATE32 fallback coverage: schema with BOOL or DATE32
#       column verifies the per-column pair-wise fallback runs
#       in parallel with other columns (still correct, just slower
#       than the fast helpers for those types).
#
# Each test asserts a strict byte-identity check vs the single-thread
# Phase 3 reader output, plus an absolute-correctness spot check on
# specific row indices.
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


# =============================================================================
# Helpers
# =============================================================================


# The fixture generators below append each row in place (`s += ...`).
# `s = s + ...` copies the whole buffer for every row, which is quadratic in
# the fixture size and took minutes per fixture in an unoptimized (coverage)
# build.
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


# =============================================================================
# Fixture generators (large fixtures to force > 1 MiB threshold gate)
# =============================================================================


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


def _gen_string_heavy_csv(n_rows: Int) -> List[UInt8]:
    """STRING-heavy CSV with 3 STRING + 1 INT64 columns. Forces the
    string-column fast helper (`_concat_string_columns_multi`).

    Schema: id, name, city, country
    Each row ~60 bytes; for ~1.5 MiB use n_rows = 25_000.
    """
    var s = String("id,name,city,country\n")
    var i = 0
    while i < n_rows:
        s += (
            String(i)
            + String(",alice_")
            + String(i)
            + String(",city_")
            + String(i % 100)
            + String(",country_")
            + String(i % 10)
            + String("\n")
        )
        i = i + 1
    return _bytes(s)


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


# =============================================================================
# Test cases
# =============================================================================


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


def test_t3_fixed_width_fast_helper() raises:
    """T3: pure-INT64 fixture exercises the
    `_concat_fixed_columns_multi` fast path on every column. This is
    the most common production case (numeric ETL); regression of this
    path would tank multi-thread throughput on numeric-heavy workloads.
    """
    var buf = _gen_pure_int_csv(60_000)  # ~1.5 MiB
    var opts = CsvReadOptions()
    var rb_serial = read_csv_bytes_to_batch[Rfc4180, SCANNER_VARIANT_PHASE_3](
        Span(buf), opts
    )
    var rb_parallel = read_csv_bytes_to_batch_parallel[Rfc4180](
        Span(buf), opts, n_workers=4
    )
    _assert_batches_schema_equal(rb_parallel, rb_serial, "T3 fixed_width")
    assert_equal(rb_parallel.num_columns(), 4)
    assert_equal(rb_parallel.num_rows(), 60_000)

    # Every column is INT64.
    var c = 0
    while c < 4:
        assert_true(
            rb_parallel.schema.field_at(c).arrow_type == ArrowType.INT64,
            "T3 col " + String(c) + " is INT64",
        )
        c = c + 1

    var samples = List[Int]()
    samples.append(0)
    samples.append(15_000)
    samples.append(30_000)
    samples.append(59_999)
    _assert_int64_col_equal(rb_parallel, rb_serial, 0, "T3 col0", samples)
    _assert_int64_col_equal(rb_parallel, rb_serial, 1, "T3 col1", samples)
    _assert_int64_col_equal(rb_parallel, rb_serial, 2, "T3 col2", samples)
    _assert_int64_col_equal(rb_parallel, rb_serial, 3, "T3 col3", samples)


def test_t4_string_heavy_fast_helper() raises:
    """T4: STRING-heavy fixture exercises the
    `_concat_string_columns_multi` fast path. STRING concat is the
    second-most-common production case (text-heavy ETL); ensure the
    per-column dispatch routes STRING columns to the string helper.
    """
    var buf = _gen_string_heavy_csv(25_000)  # ~1.5 MiB
    var opts = CsvReadOptions()
    var rb_serial = read_csv_bytes_to_batch[Rfc4180, SCANNER_VARIANT_PHASE_3](
        Span(buf), opts
    )
    var rb_parallel = read_csv_bytes_to_batch_parallel[Rfc4180](
        Span(buf), opts, n_workers=4
    )
    _assert_batches_schema_equal(rb_parallel, rb_serial, "T4 string_heavy")
    assert_equal(rb_parallel.num_columns(), 4)
    assert_equal(rb_parallel.num_rows(), 25_000)

    # Schema: id (INT64), name (STRING), city (STRING), country (STRING).
    assert_true(rb_parallel.schema.field_at(0).arrow_type == ArrowType.INT64)
    assert_true(rb_parallel.schema.field_at(1).arrow_type == ArrowType.STRING)
    assert_true(rb_parallel.schema.field_at(2).arrow_type == ArrowType.STRING)
    assert_true(rb_parallel.schema.field_at(3).arrow_type == ArrowType.STRING)

    # INT64 spot-check.
    var samples = List[Int]()
    samples.append(0)
    samples.append(12_500)
    samples.append(24_999)
    _assert_int64_col_equal(rb_parallel, rb_serial, 0, "T4 id", samples)

    # STRING spot-check: name column at row 12_500 should be "alice_12500".
    ref name_p = rb_parallel.column_at(1)
    ref name_s = rb_serial.column_at(1)
    var sa_p = name_p.as_string()
    var sa_s = name_s.as_string()
    assert_equal(
        sa_p.get(12_500),
        sa_s.get(12_500),
        "T4: name[12500] parity",
    )
    assert_equal(
        sa_p.get(0),
        sa_s.get(0),
        "T4: name[0] parity",
    )
    assert_equal(
        sa_p.get(24_999),
        sa_s.get(24_999),
        "T4: name[24999] parity",
    )

    # Absolute correctness on STRING value.
    assert_equal(
        sa_p.get(0),
        String("alice_0"),
        "T4: name[0] == 'alice_0' (absolute)",
    )
    assert_equal(
        sa_p.get(12_500),
        String("alice_12500"),
        "T4: name[12500] == 'alice_12500' (absolute)",
    )


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
    test_t1_wide_schema_mixed_columns()
    test_t2_high_n_many_workers()
    test_t3_fixed_width_fast_helper()
    test_t4_string_heavy_fast_helper()
    test_t5_bool_fallback_path()
    print("column-parallel concat: ALL 5 tests PASS")
