# =============================================================================
# Tests for the column-parallel N-way concat of komira_csv/parallel_reader.
# =============================================================================
#
# The parallel reader's driver tail concatenates per-worker batches
# column-parallel: one worker per output column, each running its own
# N-way merge for that column with the single-pass helpers of
# `komira_arrow.streaming_concat`.
#
#   T4  string column: a STRING-heavy fixture takes
#       `_concat_string_columns_multi`.
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


def main() raises:
    test_t4_string_heavy_fast_helper()
    print("test_csv_phase_4_column_parallel_concat_strings: PASS")
