# subrg_split_decode on files written by komira_test_parquet_file:
#   - the plan probe: numeric columns resolve with their own types; a string
#     column, an unknown name and an empty list give no plan;
#   - page boundaries of the driver column (pages of 20 rows; one page);
#   - a row range decoded alone equals those rows, at page boundaries and
#     inside pages, an INT32 column kept INT32;
#   - the shared-dictionary decode equals the per-range decode;
#   - a refused column gives the refusal sentinel and the range None.

from std.memory import ArcPointer
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.record_batch import RecordBatch
from komira_async.ops.waker_sink import NoopSink
from komira_collections.slab import Slab
from komira_fs.local_fs import LocalFs
from komira_parquet.column_decode_context import ColumnDecodeContext
from komira_parquet.file_reader import ParquetFileReader
from komira_parquet.metadata_parser import parse_full_metadata
from komira_parquet_api.metadata import FileMetaData
from komira_parquet_scan.parquet_reader import ParquetReader
from komira_parquet_scan.subrg_split_decode import (
    SharedColDict,
    build_shared_col_dict,
    decode_subrg_unit,
    decode_subrg_unit_shared,
    subrg_build_chunk_schema,
    subrg_page_row_boundaries,
    subrg_probe_build_plan,
)
from komira_runtime_paths import test_tmpdir
from komira_test_parquet_file import TestColumn, TestFileLayout, write_parquet_file

comptime _FS = LocalFs[NoopSink]


def _file() raises -> String:
    """One row group of 100 rows, pages of 20: a (INT64 dictionary, r % 6),
    b (INT32 PLAIN, r), f (DOUBLE dictionary, (r % 4) / 2), s (string)."""
    var path = test_tmpdir() + "/split.parquet"
    var a = List[Int]()
    var b = List[Int]()
    var f = List[Float64]()
    var s = List[String]()
    for r in range(100):
        a.append(r % 6)
        b.append(r)
        f.append(Float64(r % 4) / 2.0)
        s.append("x" + String(r))
    var cols = List[TestColumn]()
    cols.append(TestColumn.int64("a", a^).dict_encoded())
    cols.append(TestColumn.int32("b", b^).with_page_rows(100))
    cols.append(TestColumn.float64("f", f^).dict_encoded())
    cols.append(TestColumn.string("s", s^))
    write_parquet_file(path, cols, TestFileLayout([100], 20, False))
    return path^


def _reader() raises -> ParquetReader[_FS]:
    var file = ParquetFileReader[_FS].open(_file())
    var meta = parse_full_metadata(file.metadata_bytes.view_range_ro(0, file.metadata_length))
    return ParquetReader[_FS](_file=file^, _meta=ArcPointer[FileMetaData](meta^))


def test_the_plan_probe() raises:
    var r = _reader()
    var p = subrg_probe_build_plan(r, ["f", "b", "a"])
    ref plan = p.value()
    assert_equal(plan.reader_col_idx[0], 2)
    assert_true(plan.col_arrow_types[0] == ArrowType.FLOAT64)
    assert_true(plan.col_arrow_types[1] == ArrowType.INT32)
    var sch = subrg_build_chunk_schema(plan)
    assert_equal(sch.field_name(2), "a")
    assert_false(sch.field_nullable(2))
    assert_false(subrg_probe_build_plan(r, ["a", "s"]).__bool__())
    assert_false(subrg_probe_build_plan(r, ["zz"]).__bool__())
    assert_false(subrg_probe_build_plan(r, List[String]()).__bool__())


def test_page_boundaries() raises:
    var r = _reader()
    var pages = subrg_page_row_boundaries(r, 0, 0)
    assert_equal(len(pages), 6)
    for i in range(6):
        assert_equal(pages[i], i * 20)
    var one = subrg_page_row_boundaries(r, 0, 1)
    assert_equal(len(one), 2)
    assert_equal(one[1], 100)


def _check_rows(bt: RecordBatch, lo: Int, hi: Int) raises:
    """`bt` is columns b, a, f of rows [lo, hi)."""
    assert_equal(bt.num_rows(), hi - lo)
    for j in range(hi - lo):
        var row = lo + j
        assert_equal(Int(bt.column_at(0).as_primitive[DType.int32]().get(j)), row)
        assert_equal(Int(bt.column_at(1).as_primitive[DType.int64]().get(j)), row % 6)
        assert_equal(Float64(bt.column_at(2).as_primitive[DType.float64]().get(j)), Float64(row % 4) / 2.0)


def test_row_ranges_alone_and_shared() raises:
    var r = _reader()
    var plan = subrg_probe_build_plan(r, ["b", "a", "f"]).value().copy()
    var schema = subrg_build_chunk_schema(plan)
    var ctx = ColumnDecodeContext()
    var shared = Slab[SharedColDict].create(3)
    for ci in range(3):
        shared.append(build_shared_col_dict(r, 0, plan.reader_col_idx[ci], r._meta[].schema))
    for lohi in [(0, 20), (20, 60), (33, 47), (95, 100)]:
        var lo = lohi[0]
        var hi = lohi[1]
        var alone = decode_subrg_unit(r, 0, lo, hi, plan, schema, ctx, r._meta[].schema, 64)
        var via_shared = decode_subrg_unit_shared(r, lo, hi, plan, schema, ctx, shared, 0, 64)
        _check_rows(alone.value(), lo, hi)
        _check_rows(via_shared.value(), lo, hi)


def test_refusals() raises:
    var r = _reader()
    var sd = build_shared_col_dict(r, 0, 3, r._meta[].schema)
    assert_false(sd.supported)
    var plan = subrg_probe_build_plan(r, ["b"]).value().copy()
    var schema = subrg_build_chunk_schema(plan)
    var ctx = ColumnDecodeContext()
    var shared = Slab[SharedColDict].create(1)
    shared.append(sd^)
    assert_false(decode_subrg_unit_shared(r, 0, 10, plan, schema, ctx, shared, 0, 64).__bool__())
    assert_false(decode_subrg_unit(r, 0, 10, 10, plan, schema, ctx, r._meta[].schema, 64).__bool__())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
