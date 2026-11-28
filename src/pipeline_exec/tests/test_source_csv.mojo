# =============================================================================
# SOURCE_CSV: a CSV file decoded at its bound schema
# =============================================================================
#
# Each test writes its CSV file under the test's scratch directory, builds a
# SOURCE_CSV spec the way lowering does (path, dialect, every column with its
# bound type) and reads it through `read_csv_spec` or through a plan on
# `RealBuilder`. The sample file has five columns and five rows:
#
#   id  INT64    1..5
#   qty INT64    NULL in row 2
#   price DOUBLE NULL in row 3
#   day DATE     NULL in row 2
#   name VARCHAR plain text; a quoted comma, quoted doubled quotes and a quoted
#                line break; NULL (an empty cell) in row 5
#
# What these tests prove:
#
#   * Every row comes back once, each cell at its bound type, an empty cell as
#     NULL, quoted cells unquoted with their comma, quote and line break.
#   * A `.csv.gz` file is decompressed by its extension and reads the same.
#   * The spec's delimiter and header flag are the ones the file is read with.
#   * A cell is parsed at the declared type: `0001` bound VARCHAR stays `0001`.
#   * A header with no row is no row under the bound columns.
#   * A spec with no file, a spec whose names and types do not pair up, a file
#     whose column is not the bound one, a file with no column, a file of
#     another width, a missing file and an empty one are each refused, the
#     first five by name.
#   * A plan over the source filters, projects and collects every matching row
#     once on several workers and cut morsels, in file order.

from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from arrow.arrow_types import ArrowType
from arrow.schema import RecordBatch
from async_api.token import CancellationToken
from compression.compression_codecs import Gzip
from containers.slab import Slab
from parquet.runtime_footer_cache import ParquetMetadataCache
from physical_plan.csv_source_spec import CsvSourceSpec
from physical_plan.physical_plan import (
    MorselOp,
    SegmentDescPod,
    SourceSpecPod,
)
from pipeline_exec.fake_dispatch import InlineDispatch
from pipeline_exec.plan_harness import (
    chain,
    column_names,
    csv_segment,
    int64_column,
    null_column,
    project_columns,
    string_column,
)
from pipeline_exec.real_builder import RealBuilder
from pipeline_exec.run_plan import run_plan
from pipeline_exec.source_csv import CSV_SOURCE_SCHEMA_MISMATCH, read_csv_spec
from plan_expr.expr import BIN_GT, Expr
from plan_expr.expr_pool import ExprPool
from plan_expr.scalar_value import ScalarValue
from runtime_paths import test_tmpdir


comptime _SAMPLE = (
    "id,qty,price,day,name\n"
    "1,10,1.5,2026-09-15,plain\n"
    '2,,2.25,,"a, b"\n'
    '3,30,,2026-10-01,"say ""hi"""\n'
    '4,40,4.5,2026-11-30,"two\nlines"\n'
    "5,50,0.1,2026-12-31,\n"
)


def _names(
    a: String, b: String = "", c: String = "", d: String = "", e: String = ""
) -> List[String]:
    var out = List[String]()
    out.append(a)
    if b.byte_length() > 0:
        out.append(b)
    if c.byte_length() > 0:
        out.append(c)
    if d.byte_length() > 0:
        out.append(d)
    if e.byte_length() > 0:
        out.append(e)
    return out^


def _sample_types() -> List[ArrowType]:
    var t = List[ArrowType]()
    t.append(ArrowType.INT64)
    t.append(ArrowType.INT64)
    t.append(ArrowType.FLOAT64)
    t.append(ArrowType.DATE32)
    t.append(ArrowType.STRING)
    return t^


def _sample_spec(path: String) -> SourceSpecPod:
    return SourceSpecPod.csv(CsvSourceSpec(
        path,
        UInt8(ord(",")),
        True,
        0,
        _names("id", "qty", "price", "day", "name"),
        _sample_types(),
    ))


def _write_text(name: String, text: String) raises -> String:
    var path = test_tmpdir() + "/" + name
    var fh = open(path, "w")
    fh.write(text)
    fh.close()
    return path^


def _write_bytes(name: String, bytes: List[UInt8]) raises -> String:
    var path = test_tmpdir() + "/" + name
    var fh = open(path, "w")
    fh.write_bytes(Span(bytes))
    fh.close()
    return path^


def _check_sample(ref batch: RecordBatch) raises:
    assert_equal(batch.num_rows(), 5)
    var names = column_names(batch)
    assert_equal(len(names), 5)
    assert_equal(names[0], "id")
    assert_equal(names[4], "name")
    assert_true(batch.column_at(0).arrow_type == ArrowType.INT64)
    assert_true(batch.column_at(2).arrow_type == ArrowType.FLOAT64)
    assert_true(batch.column_at(3).arrow_type == ArrowType.DATE32)
    assert_true(batch.column_at(4).arrow_type == ArrowType.STRING)
    var ids = int64_column(batch, 0)
    for r in range(5):
        assert_equal(ids[r], r + 1)
    var qty_null = null_column(batch, 1)
    var qty = int64_column(batch, 1)
    assert_true(qty_null[1])
    assert_false(qty_null[0])
    assert_equal(qty[0], 10)
    assert_equal(qty[4], 50)
    var price_null = null_column(batch, 2)
    var price = batch.column_at(2).as_primitive[DType.float64]()
    assert_true(price_null[2])
    assert_equal(price.get(0), 1.5)
    assert_equal(price.get(1), 2.25)
    assert_equal(price.get(4), 0.1)
    var day_null = null_column(batch, 3)
    var day = batch.column_at(3).as_primitive[DType.int32]()
    assert_true(day_null[1])
    # Days since the Unix epoch.
    assert_equal(Int(day.get(0)), 20711)
    assert_equal(Int(day.get(2)), 20727)
    assert_equal(Int(day.get(3)), 20787)
    assert_equal(Int(day.get(4)), 20818)
    var name_null = null_column(batch, 4)
    assert_true(name_null[4])
    for r in range(4):
        assert_false(name_null[r], "row " + String(r + 1))
    var s = string_column(batch, 4)
    assert_equal(s[0], "plain")
    assert_equal(s[1], "a, b")
    assert_equal(s[2], 'say "hi"')
    assert_equal(s[3], "two\nlines")


def test_typed_quoted_and_null_cells_come_back_at_the_bound_types() raises:
    var path = _write_text("sample.csv", _SAMPLE)
    _check_sample(read_csv_spec(_sample_spec(path)))


def test_a_spec_that_skips_lines_reads_the_rows_after_the_note_above_the_header() raises:
    var path = _write_text(
        "noted.csv", "exported by a tool\nsecond note line\nid,name\n7,x\n8,y\n"
    )
    var types = List[ArrowType]()
    types.append(ArrowType.INT64)
    types.append(ArrowType.STRING)
    var spec = SourceSpecPod.csv(CsvSourceSpec(
        path, UInt8(ord(",")), True, 0, _names("id", "name"), types^, 2
    ))
    var batch = read_csv_spec(spec)
    assert_equal(batch.num_rows(), 2)
    var names = column_names(batch)
    assert_equal(names[0], "id")
    assert_equal(names[1], "name")
    var ids = int64_column(batch, 0)
    assert_equal(ids[0], 7)
    assert_equal(ids[1], 8)
    var s = string_column(batch, 1)
    assert_equal(s[0], "x")
    assert_equal(s[1], "y")


def test_a_gzip_file_is_read_by_its_extension() raises:
    var raw = String(_SAMPLE)
    var gz = Gzip.compress_gzip_file(raw.as_bytes())
    # The bytes on disk are gzip, not the text.
    assert_equal(Int(gz[0]), 0x1F)
    assert_equal(Int(gz[1]), 0x8B)
    var path = _write_bytes("sample.csv.gz", gz)
    _check_sample(read_csv_spec(_sample_spec(path)))


def test_the_spec_dialect_is_the_one_the_file_is_read_with() raises:
    var path = _write_text("pipe.csv", "7|x\n8|y,z\n")
    var types = List[ArrowType]()
    types.append(ArrowType.INT64)
    types.append(ArrowType.STRING)
    var spec = SourceSpecPod.csv(CsvSourceSpec(
        path, UInt8(ord("|")), False, 0, _names("col_0", "col_1"), types^
    ))
    var batch = read_csv_spec(spec)
    # Without a header row the first line is data.
    assert_equal(batch.num_rows(), 2)
    var a = int64_column(batch, 0)
    assert_equal(a[0], 7)
    assert_equal(a[1], 8)
    var b = string_column(batch, 1)
    assert_equal(b[0], "x")
    assert_equal(b[1], "y,z")


def test_a_cell_is_parsed_at_the_declared_type_not_an_inferred_one() raises:
    var path = _write_text("codes.csv", "code\n0001\n0020\n")
    var types = List[ArrowType]()
    types.append(ArrowType.STRING)
    var spec = SourceSpecPod.csv(CsvSourceSpec(
        path, UInt8(ord(",")), True, 0, _names("code"), types^
    ))
    var batch = read_csv_spec(spec)
    assert_true(batch.column_at(0).arrow_type == ArrowType.STRING)
    var codes = string_column(batch, 0)
    assert_equal(codes[0], "0001")
    assert_equal(codes[1], "0020")


def test_a_header_with_no_row_is_no_row_under_the_bound_columns() raises:
    var path = _write_text("header_only.csv", "id,qty,price,day,name\n")
    var batch = read_csv_spec(_sample_spec(path))
    assert_equal(batch.num_rows(), 0)
    assert_equal(batch.num_columns(), 5)
    assert_true(batch.column_at(3).arrow_type == ArrowType.DATE32)


def test_a_spec_with_no_file_or_unpaired_columns_is_refused() raises:
    with assert_raises(contains="a SOURCE_CSV spec names no file"):
        _ = read_csv_spec(SourceSpecPod())
    var path = _write_text("unpaired.csv", _SAMPLE)
    var one_type = List[ArrowType]()
    one_type.append(ArrowType.INT64)
    var unpaired = SourceSpecPod.csv(CsvSourceSpec(
        path, UInt8(ord(",")), True, 0, _names("id", "qty"), one_type^
    ))
    with assert_raises(
        contains=String(CSV_SOURCE_SCHEMA_MISMATCH) + ": the spec of "
    ):
        _ = read_csv_spec(unpaired)
    var none = SourceSpecPod.csv(CsvSourceSpec(
        path, UInt8(ord(",")), True, 0, List[String](), List[ArrowType]()
    ))
    with assert_raises(contains="names 0 columns and 0 types"):
        _ = read_csv_spec(none)


def test_a_file_whose_columns_are_not_the_bound_ones_is_refused() raises:
    var renamed = _write_text(
        "renamed.csv", "id,qty,price,when,name\n1,10,1.5,2026-09-15,a\n"
    )
    with assert_raises(
        contains=String(CSV_SOURCE_SCHEMA_MISMATCH)
        + ": column 4 of "
        + renamed
        + " is 'when', the plan bound 'day'"
    ):
        _ = read_csv_spec(_sample_spec(renamed))
    # A file of one blank line has no column at all.
    var blank = _write_text("blank.csv", "\n")
    with assert_raises(
        contains=String(CSV_SOURCE_SCHEMA_MISMATCH)
        + ": column 1 of "
        + blank
        + " is '', the plan bound 'id'"
    ):
        _ = read_csv_spec(_sample_spec(blank))
    var narrow = _write_text("narrow.csv", "id,qty\n1,2\n")
    with assert_raises(contains="the plan declares 5 column(s)"):
        _ = read_csv_spec(_sample_spec(narrow))


def test_a_missing_or_empty_file_is_refused() raises:
    var missing = test_tmpdir() + "/no_such_file.csv"
    with assert_raises():
        _ = read_csv_spec(_sample_spec(missing))
    var empty = _write_text("empty.csv", "")
    with assert_raises():
        _ = read_csv_spec(_sample_spec(empty))


def _one(var desc: SegmentDescPod) -> List[SegmentDescPod]:
    var out = List[SegmentDescPod]()
    out.append(desc^)
    return out^


def _qty_gt(v: Int) -> Expr:
    return Expr.binary(
        BIN_GT, Expr.col_ref("qty"), Expr.literal(ScalarValue.from_int(v))
    )


def _run_qty_plan(path: String, workers: Int, morsel_rows: Int) raises -> RecordBatch:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var dispatch = InlineDispatch()
    var ops = chain(
        MorselOp.filter(_qty_gt(15)), project_columns(_names("name", "id"))
    )
    var out = run_plan(
        _one(csv_segment(0, _sample_spec(path), ops^, morsel_rows)),
        builder,
        dispatch,
        workers,
        CancellationToken.new(),
    )
    return out.take(0)


def test_a_plan_over_the_csv_source_filters_projects_and_collects() raises:
    var path = _write_text("plan.csv", _SAMPLE)
    # One worker at the default morsel size, and three workers over morsels
    # of two rows: the same rows, in file order.
    var runs = List[RecordBatch]()
    runs.append(_run_qty_plan(path, 1, 0))
    runs.append(_run_qty_plan(path, 3, 2))
    for i in range(len(runs)):
        ref batch = runs[i]
        var names = column_names(batch)
        assert_equal(len(names), 2)
        assert_equal(names[0], "name")
        assert_equal(names[1], "id")
        # qty > 15 keeps rows 3, 4 and 5; row 2's NULL qty is not kept.
        var ids = int64_column(batch, 1)
        assert_equal(len(ids), 3)
        assert_equal(ids[0], 3)
        assert_equal(ids[1], 4)
        assert_equal(ids[2], 5)
        var s = string_column(batch, 0)
        assert_equal(s[0], 'say "hi"')
        assert_equal(s[1], "two\nlines")
        assert_true(null_column(batch, 0)[2])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
