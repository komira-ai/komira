# =============================================================================
# test_csv_schema_sample_inference.mojo
# =============================================================================
#
# Proves `read_csv_bytes_to_schema[Q]` (header + bounded-sample SCHEMA
# inference, NO column materialization) produces a Schema IDENTICAL (column
# names + per-column ArrowType) to the schema the full-file eager decode
# (`read_csv_bytes_to_batch[Q]`) produces — for columns whose type is stable
# across the file (the only shapes the numeric row fast-path admits).
#
# Why: a row-streaming reader needs only the schema, and a full columnar
# decode of the ENTIRE file to read it costs hundreds of milliseconds per
# query on SF1 lineitem. The cheap path scans only a bounded byte prefix. This
# test pins that the cheap path's schema == the expensive path's schema.
#
# LIMITATION (documented): sampled inference can differ from full-file
# inference if a column WIDENS deep in the file (e.g. INT64 for the first N
# rows then FLOAT64 / STRING). The bounded sample matches the full decoder's
# OWN bounded `infer_rows` cap (default 100), so for any well-typed (stable)
# column the schemas are byte-identical. A column that widens past the sample
# is the existing risk surface; the row fast-path HARD-RAISES downstream on the
# non-numeric outcome, so it fails loudly, never silently wrong.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true
from std.io import FileHandle

from komira_arrow_ipc.chunked_read import read_chunked

from komira_csv.reader import (
    read_csv_bytes_to_batch,
    read_csv_bytes_to_schema,
)
from komira_csv.csv_options import CsvReadOptions
from komira_csv.quote_styles import Rfc4180

from komira_arrow.schema import Schema
from komira_runtime_paths import test_tmpdir


def _scratch_dir() raises -> String:
    """The directory this test run may write scratch files into: a fixed
    `/tmp` path would be shared by concurrent runs on one machine."""
    return test_tmpdir()


def _assert_schemas_identical(imm got: Schema, imm want: Schema) raises:
    """Assert two schemas have identical column names + ArrowType type_ids."""
    assert_equal(
        got.num_columns(),
        want.num_columns(),
        "field count: got "
        + String(got.num_columns())
        + " want "
        + String(want.num_columns()),
    )
    for i in range(want.num_columns()):
        var gf = got.field_at(i)
        var wf = want.field_at(i)
        assert_equal(
            gf.name, wf.name, "name @col " + String(i)
        )
        assert_equal(
            Int(gf.arrow_type.type_id),
            Int(wf.arrow_type.type_id),
            "arrow_type @col "
            + String(i)
            + " ("
            + wf.name
            + "): got "
            + String(Int(gf.arrow_type.type_id))
            + " want "
            + String(Int(wf.arrow_type.type_id)),
        )


def _schema_from_full_decode(path: String) raises -> Schema:
    """The expensive path: full eager columnar decode, then take its schema."""
    var buf = read_chunked(path)
    var span = buf.view_range_ro(0, buf.len()).into_span()
    var opts = CsvReadOptions()
    var batch = read_csv_bytes_to_batch[Rfc4180](span, opts)
    return batch.schema.copy()


def _schema_from_sample(path: String) raises -> Schema:
    """The NEW path: header + bounded-sample schema inference (no materialize).
    """
    var buf = read_chunked(path)
    var span = buf.view_range_ro(0, buf.len()).into_span()
    var opts = CsvReadOptions()
    return read_csv_bytes_to_schema[Rfc4180](span, opts)


# -----------------------------------------------------------------------------
# 1. Small mixed-type CSV: sample schema == full-decode schema.
# -----------------------------------------------------------------------------
def test_small_mixed_schema_equivalence() raises:
    var path = (_scratch_dir() + String("/ru3b_perf_small_mixed.csv"))
    # i64, f64, string. Types stable across the (tiny) file.
    var text = String(
        "a,b,c\n"
        "1,1.5,hello\n"
        "6,2.5,world\n"
        "3,3.5,foo\n"
        "9,4.5,bar\n"
    )
    var f = FileHandle(path, "w")
    f.write(text)
    f.close()

    var full = _schema_from_full_decode(path)
    var sample = _schema_from_sample(path)
    _assert_schemas_identical(sample, full)
    # Sanity: 3 columns named a/b/c.
    assert_equal(sample.num_columns(), 3)
    assert_equal(sample.field_at(0).name, String("a"))
    assert_equal(sample.field_at(2).name, String("c"))


# -----------------------------------------------------------------------------
# 2. Lineitem-shaped numeric subset, LARGER than the sample prefix budget so
#    the bounded-prefix snap path is exercised (not just whole-file fallback).
#    Types are STABLE across the whole file -> schemas must be identical.
# -----------------------------------------------------------------------------
def test_lineitem_shaped_numeric_large_schema_equivalence() raises:
    var path = (_scratch_dir() + String("/ru3b_perf_lineitem_numeric.csv"))
    var f = FileHandle(path, "w")
    # 6 numeric columns: i64, i64, i64, f64, f64, f64. Header + many rows so the
    # file exceeds the 256 KiB sample budget (forces the prefix-snap branch).
    f.write(String("l_orderkey,l_partkey,l_quantity,l_extendedprice,l_discount,l_tax\n"))
    var n = 60000  # ~ > 256 KiB at ~ 45 bytes/row
    var i = 0
    while i < n:
        var ln = (
            String(i + 1)
            + ","
            + String((i * 7) % 200000 + 1)
            + ","
            + String(i % 50 + 1)
            + ","
            + String(i % 50 + 1)
            + ".25,"
            + "0."
            + String(i % 10)
            + ",0.0"
            + String(i % 9)
            + "\n"
        )
        f.write(ln)
        i = i + 1
    f.close()

    var full = _schema_from_full_decode(path)
    var sample = _schema_from_sample(path)
    _assert_schemas_identical(sample, full)
    # Sanity: 6 columns, first is l_orderkey, types match the numeric shape.
    assert_equal(sample.num_columns(), 6)
    assert_equal(sample.field_at(0).name, String("l_orderkey"))
    assert_equal(sample.field_at(3).name, String("l_extendedprice"))


# -----------------------------------------------------------------------------
# 3. All-i64 CSV (the canonical row-streaming fast-path shape) — stable type,
#    schemas identical.
# -----------------------------------------------------------------------------
def test_all_i64_schema_equivalence() raises:
    var path = (_scratch_dir() + String("/ru3b_perf_all_i64.csv"))
    var text = String("a,b\n1,10\n6,20\n3,30\n9,40\n5,50\n7,60\n")
    var f = FileHandle(path, "w")
    f.write(text)
    f.close()

    var full = _schema_from_full_decode(path)
    var sample = _schema_from_sample(path)
    _assert_schemas_identical(sample, full)
    assert_equal(sample.num_columns(), 2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
