# =============================================================================
# sql_copy_format: the format and codec a COPY ... TO takes from its path
# =============================================================================
#
# What each test proves:
#   * test_the_extension_names_the_format: `.parquet`, `.csv`, `.json`,
#     `.jsonl` and `.ndjson`, in any case, after a directory, and after one
#     `.gz` or `.zst` suffix is removed. Catches a format read from the
#     directory part or from the compression suffix.
#   * test_an_extension_naming_no_format_is_refused: `.txt`, no extension, a
#     bare `.gz`, a `.parquet` directory over a file with no extension and a
#     doubled compression suffix give COPY_FORMAT_NOT_INFERRED, by exact
#     message. Catches a silent default to Parquet.
#   * test_the_codec_follows_the_format_and_the_suffix: Parquet is snappy even
#     under `.gz`; CSV and JSON take gzip from `.gz`, zstd from `.zst`, none
#     otherwise.
#   * test_the_parser_infers_only_what_the_options_leave_open: no option list,
#     an option list without FORMAT, FORMAT given over a name of another
#     format, and COMPRESSION given over a compression suffix.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from arrow.write_target import (
    WCOMP_GZIP,
    WCOMP_SNAPPY,
    WCOMP_UNCOMPRESSED,
    WCOMP_ZSTD,
    WFMT_CSV,
    WFMT_JSONL,
    WFMT_PARQUET,
)
from sql.sql_copy_format import (
    COPY_FORMAT_NOT_INFERRED,
    copy_codec_from_path,
    copy_format_from_path,
)
from sql.sql_parser import parse_sql
from sql.sql_token import tokenize


def _fmt(dest: String, want: UInt8) raises:
    assert_equal(Int(copy_format_from_path(dest)), Int(want), dest)


def _not_inferred(dest: String) raises:
    var msg = String("")
    try:
        _ = copy_format_from_path(dest)
    except e:
        msg = String(e)
    assert_equal(
        msg,
        String(COPY_FORMAT_NOT_INFERRED) + ": COPY ... TO '" + dest
        + "' has no FORMAT, and its extension is not .parquet, .csv, .json,"
        " .jsonl or .ndjson; add (FORMAT parquet), (FORMAT csv) or"
        " (FORMAT json)",
    )


def _parsed(sql: String, fmt: UInt8, codec: UInt8) raises:
    var st = parse_sql(tokenize(sql))
    assert_equal(Int(st.fmt), Int(fmt), sql)
    assert_equal(Int(st.codec), Int(codec), sql)


def test_the_extension_names_the_format() raises:
    _fmt("out.parquet", WFMT_PARQUET)
    _fmt("OUT.PARQUET", WFMT_PARQUET)
    _fmt("/data/runs/out.parquet", WFMT_PARQUET)
    _fmt("out.parquet.gz", WFMT_PARQUET)
    _fmt("rows.csv", WFMT_CSV)
    _fmt("rows.csv.gz", WFMT_CSV)
    _fmt("dir.v2/rows.Csv.ZST", WFMT_CSV)
    _fmt("rows.json", WFMT_JSONL)
    _fmt("rows.json.zst", WFMT_JSONL)
    _fmt("rows.jsonl", WFMT_JSONL)
    _fmt("rows.ndjson.gz", WFMT_JSONL)


def test_an_extension_naming_no_format_is_refused() raises:
    _not_inferred("out.txt")
    _not_inferred("out")
    _not_inferred("out.gz")
    _not_inferred("tables.parquet/out")
    _not_inferred("rows.csv.gz.zst")


def test_the_codec_follows_the_format_and_the_suffix() raises:
    assert_equal(Int(copy_codec_from_path(WFMT_PARQUET, "out.parquet")), Int(WCOMP_SNAPPY))
    assert_equal(Int(copy_codec_from_path(WFMT_PARQUET, "out.parquet.gz")), Int(WCOMP_SNAPPY))
    assert_equal(Int(copy_codec_from_path(WFMT_CSV, "rows.csv")), Int(WCOMP_UNCOMPRESSED))
    assert_equal(Int(copy_codec_from_path(WFMT_CSV, "rows.csv.GZ")), Int(WCOMP_GZIP))
    assert_equal(Int(copy_codec_from_path(WFMT_CSV, "rows.csv.zst")), Int(WCOMP_ZSTD))
    assert_equal(Int(copy_codec_from_path(WFMT_JSONL, "rows.json.gz")), Int(WCOMP_GZIP))
    assert_equal(Int(copy_codec_from_path(WFMT_JSONL, "rows.json")), Int(WCOMP_UNCOMPRESSED))


def test_the_parser_infers_only_what_the_options_leave_open() raises:
    _parsed("COPY t TO 'out.parquet'", WFMT_PARQUET, WCOMP_SNAPPY)
    _parsed("COPY t TO 'rows.csv.gz'", WFMT_CSV, WCOMP_GZIP)
    _parsed("COPY t TO 'rows.json'", WFMT_JSONL, WCOMP_UNCOMPRESSED)
    _parsed("COPY t TO 'out.parquet' (COMPRESSION zstd)", WFMT_PARQUET, WCOMP_ZSTD)
    _parsed("COPY t TO 'rows.csv.zst' (HEADER true)", WFMT_CSV, WCOMP_ZSTD)
    _parsed("COPY t TO 'out.txt' (FORMAT parquet)", WFMT_PARQUET, WCOMP_SNAPPY)
    _parsed("COPY t TO 'rows.csv' (FORMAT parquet)", WFMT_PARQUET, WCOMP_SNAPPY)
    _parsed("COPY t TO 'rows.csv.gz' (FORMAT csv)", WFMT_CSV, WCOMP_GZIP)
    _parsed(
        "COPY t TO 'rows.csv.gz' (FORMAT csv, COMPRESSION none)",
        WFMT_CSV,
        WCOMP_UNCOMPRESSED,
    )
    for sql in ["COPY t TO 'out.txt'", "COPY t TO 'out.txt' (COMPRESSION zstd)"]:
        var msg = String("")
        try:
            _ = parse_sql(tokenize(sql))
        except e:
            msg = String(e)
        assert_true(
            msg.startswith(String(COPY_FORMAT_NOT_INFERRED) + ": COPY ... TO 'out.txt'"),
            sql + " raised: " + msg,
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
