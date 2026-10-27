# cursor_grain_feed, grain_decode_move and cursor_grain_split_emit:
#   - the grain formula: the policy bound, the L3 residency bound, the clamps
#     and the power-of-two rounding, the default L3;
#   - a row group read grain by grain (grains of 16 rows over 50-row row
#     groups) gives every row once, in order, then None; the counters move;
#   - the move arm gives the same columns as the copy arm, and the byte
#     counters cross over (copy bytes under the copy arm, move bytes under
#     the move arm, dictionary bytes under both);
#   - open refuses a string dictionary column and a column that may hold a
#     null (a null in a later page would be met only after grains are out:
#     reading on would lose the row group's remaining rows);
#   - open refuses an unsigned dictionary or PLAIN column, a DATE column and a
#     nested footer, and still takes the plain INT32 beside them;
#   - open refuses an INT64 column that carries only the LogicalType TIMESTAMP,
#     and takes a PLAIN chunk whose footer stores dictionary offset 0;
#   - the split arithmetic and the gates' defaults and setters.

from std.memory import ArcPointer
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_async.ops.waker_sink import NoopSink
from komira_fs.local_fs import LocalFs
from komira_parquet.column_decode_context import ColumnDecodeContext
from komira_parquet.file_reader import ParquetFileReader
from komira_parquet.metadata_parser import parse_full_metadata
from komira_parquet_api.metadata import FileMetaData
from komira_parquet_scan.cursor_grain_feed import (
    CursorGrainRg,
    cursor_grain_enabled,
    cursor_grain_next,
    cursor_grain_open,
    cursor_grain_rg_count,
    cursor_grain_rows,
    grain_observed_grain,
    reset_cursor_grain_counts,
    set_cursor_grain_enabled,
)
from komira_parquet_scan.cursor_grain_split_emit import (
    cursor_grain_split_enabled,
    cursor_grain_sub_count,
    set_cursor_grain_split_enabled,
)
from komira_parquet_scan.grain_decode_move import (
    grain_decode_move_enabled,
    grain_dict_resolve_bytes,
    grain_flat_copy_bytes,
    grain_flat_move_bytes,
    reset_grain_move_counts,
    set_grain_decode_move_enabled,
)
from komira_parquet_scan.parquet_reader import ParquetReader
from komira_parquet_scan.subrg_agg_plan import resolve_reader_col_idx
from komira_parquet_scan.subrg_scan_executor import SubrgScanPlan
from komira_runtime_paths import test_tmpdir
from komira_test_parquet_file import PT_INT32, PT_INT64, TestColumn, TestFileLayout, write_parquet_file

comptime _FS = LocalFs[NoopSink]
comptime _MIB = 1 << 20


def test_the_grain_formula() raises:
    # 55 MiB L3, 20 workers, 16 B/row: residency 36,044 rows, policy 16,384.
    assert_equal(cursor_grain_rows(16, 20, 16_384, 55 * _MIB), 16_384)
    # No policy bound: 36,044 rounds down to 32,768.
    assert_equal(cursor_grain_rows(16, 20, 0, 55 * _MIB), 32_768)
    # A wide row hits the floor; a tiny one the ceiling.
    assert_equal(cursor_grain_rows(512, 20, 0, 55 * _MIB), 1024)
    assert_equal(cursor_grain_rows(1, 1, 0, 1 << 30), 65_536)
    # A non-positive L3 means the default (8 MiB): 8 MiB / 2 / 4 / (8 * 2.5).
    assert_equal(cursor_grain_rows(8, 4, 0, 0), cursor_grain_rows(8, 4, 0, 8 * _MIB))


def _test_path(name: String) raises -> String:
    return test_tmpdir() + "/" + name + ".parquet"


def _file(name: String, nulls_in_rg1: Bool) raises -> String:
    """Two row groups of 50: a (INT64 dictionary, r % 5), b (INT32 PLAIN, r),
    f (DOUBLE PLAIN, r / 2), s (string dictionary), n (OPTIONAL INT64 = r,
    pages of 10 rows; NULL at row 95 when `nulls_in_rg1`)."""
    var path = test_tmpdir() + "/" + name + ".parquet"
    var a = List[Int]()
    var b = List[Int]()
    var f = List[Float64]()
    var s = List[String]()
    var n = List[Int]()
    var nn = List[Bool]()
    for r in range(100):
        a.append(r % 5)
        b.append(r)
        f.append(Float64(r) / 2.0)
        s.append("v" + String(r % 2))
        n.append(r)
        nn.append(nulls_in_rg1 and r == 95)
    var cols = List[TestColumn]()
    cols.append(TestColumn.int64("a", a^).dict_encoded())
    cols.append(TestColumn.int32("b", b^))
    cols.append(TestColumn.float64("f", f^))
    cols.append(TestColumn.string("s", s^).dict_encoded())
    cols.append(TestColumn.int64("n", n^).with_nulls(nn^).with_page_rows(10))
    write_parquet_file(path, cols, TestFileLayout([50, 50], 0, False))
    return path^


def _reader(path: String) raises -> ParquetReader[_FS]:
    var file = ParquetFileReader[_FS].open(path)
    var meta = parse_full_metadata(file.metadata_bytes.view_range_ro(0, file.metadata_length))
    return ParquetReader[_FS](_file=file^, _meta=ArcPointer[FileMetaData](meta^))


def _plan(reader: ParquetReader[_FS], names: List[String], types: List[ArrowType]) -> SubrgScanPlan:
    var idx = List[Int]()
    for i in range(len(names)):
        idx.append(resolve_reader_col_idx(reader, names[i]))
    return SubrgScanPlan(names.copy(), idx^, types.copy())


def _schema(names: List[String], types: List[ArrowType]) -> Schema:
    var sb = SchemaBuilder()
    for i in range(len(names)):
        sb.add_field(Field(names[i], types[i], False))
    return sb.build()


def _read_all(move: Bool) raises -> List[RecordBatch]:
    """Every grain of both row groups, columns b, a, f, n."""
    set_grain_decode_move_enabled(move)
    var reader = _reader(_file("grains", False))
    var names: List[String] = ["b", "a", "f", "n"]
    var types: List[ArrowType] = [ArrowType.INT32, ArrowType.INT64, ArrowType.FLOAT64, ArrowType.INT64]
    var plan = _plan(reader, names, types)
    var schema = _schema(names, types)
    var ctx = ColumnDecodeContext()
    var st = CursorGrainRg()
    var out = List[RecordBatch]()
    for g in range(2):
        assert_true(cursor_grain_open(reader, g, 10 + g, plan, reader._meta[].schema, st))
        assert_equal(st.claimed_rg, 10 + g)
        while True:
            var b = cursor_grain_next(st, plan, schema, ctx, 16)
            if not b:
                break
            out.append(b.take())
        assert_false(st.active())
    set_grain_decode_move_enabled(False)
    return out^


def test_grains_give_every_row_once_on_both_arms() raises:
    reset_cursor_grain_counts()
    reset_grain_move_counts()
    var copy = _read_all(False)
    assert_true(grain_flat_copy_bytes() > 0)
    assert_equal(grain_flat_move_bytes(), 0)
    var dict_bytes = grain_dict_resolve_bytes()
    assert_true(dict_bytes > 0)
    assert_equal(cursor_grain_rg_count(), 2)
    assert_equal(grain_observed_grain(), 100 // 8)  # grains 16, 16, 16, 2 per row group
    reset_grain_move_counts()
    var moved = _read_all(True)
    assert_equal(grain_flat_copy_bytes(), 0)
    assert_true(grain_flat_move_bytes() > 0)
    assert_equal(grain_dict_resolve_bytes(), dict_bytes)
    assert_equal(len(copy), 8)
    assert_equal(len(moved), 8)
    var r = 0
    for i in range(len(copy)):
        ref c = copy[i]
        ref m = moved[i]
        assert_equal(c.num_rows(), m.num_rows())
        assert_true(m.column_at(0).arrow_type == ArrowType.INT32)
        for j in range(c.num_rows()):
            assert_equal(Int(c.column_at(0).as_primitive[DType.int32]().get(j)), r)
            assert_equal(Int(m.column_at(0).as_primitive[DType.int32]().get(j)), r)
            assert_equal(Int(m.column_at(1).as_primitive[DType.int64]().get(j)), r % 5)
            assert_equal(Float64(m.column_at(2).as_primitive[DType.float64]().get(j)), Float64(r) / 2.0)
            assert_equal(Int(c.column_at(3).as_primitive[DType.int64]().get(j)), r)
            assert_equal(Int(m.column_at(3).as_primitive[DType.int64]().get(j)), r)
            r += 1
    assert_equal(r, 100)


def test_open_refuses_strings_and_possible_nulls() raises:
    var reader = _reader(_file("refusals", True))
    var st = CursorGrainRg()
    var strs: List[String] = ["s", "b"]
    var stypes: List[ArrowType] = [ArrowType.STRING, ArrowType.INT32]
    assert_false(cursor_grain_open(reader, 0, 0, _plan(reader, strs, stypes), reader._meta[].schema, st))
    # n has a null in row group 1 (row 95, its 5th page): refused there, and
    # still taken in row group 0, which has none.
    var nb: List[String] = ["n", "b"]
    var ntypes: List[ArrowType] = [ArrowType.INT64, ArrowType.INT32]
    var plan = _plan(reader, nb, ntypes)
    assert_true(cursor_grain_open(reader, 0, 0, plan, reader._meta[].schema, st))
    assert_false(cursor_grain_open(reader, 1, 1, plan, reader._meta[].schema, st))
    assert_false(st.active())
    assert_false(cursor_grain_open(reader, 2, 2, plan, reader._meta[].schema, st))


def _typed_file() raises -> String:
    """One row group of 50: u32 (UINT_32 dictionary, 2^31 + r % 4), u64
    (UINT_64 dictionary), p64 (UINT_64 PLAIN), d (DATE PLAIN), b (INT32)."""
    var path = test_tmpdir() + "/grain_typed.parquet"
    var u32 = List[Int]()
    var u64 = List[Int]()
    var b = List[Int]()
    var lowest = -(1 << 62) - (1 << 62)
    for r in range(50):
        u32.append((1 << 31) + r % 4)
        u64.append(lowest + r % 4)
        b.append(r)
    var cols = List[TestColumn]()
    var c0 = TestColumn("u32", PT_INT32, 13)
    c0.ints = u32^
    cols.append(c0^.dict_encoded())
    var c1 = TestColumn("u64", PT_INT64, 14)
    c1.ints = u64.copy()
    cols.append(c1^.dict_encoded())
    var c2 = TestColumn("p64", PT_INT64, 14)
    c2.ints = u64^
    cols.append(c2^)
    var c3 = TestColumn("d", PT_INT32, 6)
    c3.ints = b.copy()
    cols.append(c3^)
    cols.append(TestColumn.int32("b", b^))
    write_parquet_file(path, cols, TestFileLayout.single())
    return path^


def test_open_refuses_annotated_columns_and_a_nested_footer() raises:
    var reader = _reader(_typed_file())
    var st = CursorGrainRg()
    var t32: List[ArrowType] = [ArrowType.INT32, ArrowType.INT32]
    # b alone is taken; next to any annotated column the row group is
    # refused (the caller decodes it whole, with the file's types).
    assert_true(cursor_grain_open(reader, 0, 0, _plan(reader, ["b"], [ArrowType.INT32]), reader._meta[].schema, st))
    for name in ["u32", "u64", "p64", "d"]:
        var plan = _plan(reader, ["b", name], t32)
        assert_false(cursor_grain_open(reader, 0, 0, plan, reader._meta[].schema, st), name)
        assert_false(st.active())
    var meta = reader.meta_copy()
    meta.schema[1].num_children = 1
    var nested = ParquetReader[_FS](
        _file=ParquetFileReader[_FS].open(_typed_file()), _meta=ArcPointer[FileMetaData](meta^)
    )
    assert_false(
        cursor_grain_open(nested, 0, 0, _plan(nested, ["b"], [ArrowType.INT32]), nested._meta[].schema, st)
    )


def test_open_refuses_a_timestamp_and_reads_past_a_zero_dictionary_offset() raises:
    var base = _reader(_file("grain_patched", False))
    var meta = base.meta_copy()
    # a is INT64 (schema element 1); b is INT32 PLAIN (column 1).
    meta.schema[1].logical_timestamp_unit = Optional[Int](2)
    meta.row_groups[0].columns[1].meta_data.dictionary_page_offset = Optional[Int](0)
    var r = ParquetReader[_FS](
        _file=ParquetFileReader[_FS].open(_test_path("grain_patched")), _meta=ArcPointer[FileMetaData](meta^)
    )
    var st = CursorGrainRg()
    var ts: List[String] = ["b", "a"]
    var ts_types: List[ArrowType] = [ArrowType.INT32, ArrowType.INT64]
    assert_false(cursor_grain_open(r, 0, 0, _plan(r, ts, ts_types), r._meta[].schema, st))
    assert_false(st.active())
    var names: List[String] = ["b", "f"]
    var types: List[ArrowType] = [ArrowType.INT32, ArrowType.FLOAT64]
    var plan = _plan(r, names, types)
    assert_true(cursor_grain_open(r, 0, 0, plan, r._meta[].schema, st))
    var ctx = ColumnDecodeContext()
    var k = 0
    while True:
        var bt = cursor_grain_next(st, plan, _schema(names, types), ctx, 16)
        if not bt:
            break
        ref b = bt.value()
        for j in range(b.num_rows()):
            assert_equal(Int(b.column_at(0).as_primitive[DType.int32]().get(j)), k)
            assert_equal(Float64(b.column_at(1).as_primitive[DType.float64]().get(j)), Float64(k) / 2.0)
            k += 1
    assert_equal(k, 50)


def test_split_arithmetic_and_gates() raises:
    assert_equal(cursor_grain_sub_count(100, 0), 1)
    assert_equal(cursor_grain_sub_count(100, 100), 1)
    assert_equal(cursor_grain_sub_count(101, 100), 2)
    assert_equal(cursor_grain_sub_count(16_384, 1024), 16)
    assert_true(cursor_grain_split_enabled())
    set_cursor_grain_split_enabled(False)
    assert_false(cursor_grain_split_enabled())
    set_cursor_grain_split_enabled(True)
    assert_false(cursor_grain_enabled())
    set_cursor_grain_enabled(True)
    assert_true(cursor_grain_enabled())
    set_cursor_grain_enabled(False)
    assert_false(grain_decode_move_enabled())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
