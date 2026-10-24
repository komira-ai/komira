# parquet_source_helpers on files written by komira_test_parquet_file:
#   - the Arrow schema of a footer;
#   - the per-chunk subset decode, with a fresh context per chunk and with a
#     caller's reused context, both against the rows written, on a dictionary
#     chunk kept and dense, and its refusal of an index that is not a leaf;
#   - the numeric dictionary codes of one chunk (None for a PLAIN chunk);
#   - by name: names to leaf indices, the union of several files' schemas in
#     first-seen order and its type-conflict error naming both files, the
#     positional-identity test, and the by-name decode that puts each column
#     in its result slot and a column the file lacks as typed nulls;
#   - the read-ahead hint is harmless on any row group index.

from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_async.ops.waker_sink import NoopSink
from komira_fs.local_fs import LocalFs
from komira_parquet.column_decode_context import ColumnDecodeContext
from komira_parquet.file_reader import ParquetFileReader
from komira_parquet.metadata_parser import parse_full_metadata
from komira_parquet.parquet_source_helpers import (
    _advise_prefetch_next_rg,
    _build_schema_from_meta,
    _build_union_by_name_schema,
    _decode_columns_by_name_remap,
    _decode_columns_subset_per_chunk,
    _decode_columns_subset_per_chunk_with_ctx,
    _decode_numeric_dict_codes_one_col,
    _name_to_file_col_idx,
    _remap_is_positional_identity,
    _resolve_result_names_to_file_indices,
)
from komira_parquet_api.metadata import FileMetaData
from komira_runtime_paths import test_tmpdir
from komira_test_parquet_file import TestColumn, TestFileLayout, write_parquet_file

comptime _Reader = ParquetFileReader[LocalFs[NoopSink]]


def _a(r: Int) -> Int:
    return r * 3


def _s(r: Int) -> String:
    return "s" + String(r % 3)


def _n(r: Int) -> Int:
    return r % 4


def _file() raises -> String:
    var path = test_tmpdir() + "/helpers.parquet"
    var a = List[Int]()
    var s = List[String]()
    var n = List[Int]()
    for r in range(30):
        a.append(_a(r))
        s.append(_s(r))
        n.append(_n(r))
    var cols = List[TestColumn]()
    cols.append(TestColumn.int64("a", a^))
    cols.append(TestColumn.string("s", s^).dict_encoded())
    cols.append(TestColumn.int64("n", n^).dict_encoded())
    write_parquet_file(path, cols, TestFileLayout([20, 10], 0, False))
    return path^


def _meta(reader: _Reader) raises -> FileMetaData:
    return parse_full_metadata(reader.metadata_bytes.view_range_ro(0, reader.metadata_length))


def test_the_schema_of_a_footer() raises:
    var reader = _Reader.open(_file())
    var sch = _build_schema_from_meta(_meta(reader))
    assert_equal(sch.num_columns(), 3)
    assert_equal(sch.field_name(1), "s")
    assert_true(sch.field_arrow_type(1) == ArrowType.STRING)
    assert_true(sch.field_arrow_type(2) == ArrowType.INT64)


def _check_nas(b: RecordBatch, first: Int) raises:
    """`b` is columns n, a, s of rows from `first`."""
    assert_equal(b.num_columns(), 3)
    assert_equal(b.schema.field_name(0), "n")
    for i in range(b.num_rows()):
        var r = first + i
        assert_equal(Int(b.column_at(0).as_primitive[DType.int64]().get(i)), _n(r))
        assert_equal(Int(b.column_at(1).as_primitive[DType.int64]().get(i)), _a(r))
        assert_equal(b.column_at(2).as_string().get(i), _s(r))


def test_the_subset_decode_with_fresh_and_reused_contexts() raises:
    var reader = _Reader.open(_file())
    var md = _meta(reader)
    var ctx = ColumnDecodeContext()
    for g in range(2):
        var first = 0 if g == 0 else 20
        var fresh = _decode_columns_subset_per_chunk(reader, md.row_groups[g], md.schema, [2, 0, 1], False)
        var reused = _decode_columns_subset_per_chunk_with_ctx(
            reader, md.row_groups[g], md.schema, [2, 0, 1], False, ctx
        )
        _check_nas(fresh, first)
        _check_nas(reused, first)
    var kept = _decode_columns_subset_per_chunk(reader, md.row_groups[0], md.schema, [1], True)
    assert_true(kept.column_at(0).arrow_type == ArrowType.DICTIONARY)
    with assert_raises(contains="is not a leaf"):
        _ = _decode_columns_subset_per_chunk(reader, md.row_groups[0], md.schema, [3], False)


def test_numeric_dictionary_codes_of_one_chunk() raises:
    var reader = _Reader.open(_file())
    var md = _meta(reader)
    var codes = _decode_numeric_dict_codes_one_col(reader, md.row_groups[1], md.schema, 2)
    assert_true(codes.__bool__())
    ref c = codes.value()
    for i in range(10):
        assert_equal(Int(c.dict_values[Int(c.codes.get(i))]), _n(20 + i))
    assert_false(
        _decode_numeric_dict_codes_one_col(reader, md.row_groups[1], md.schema, 0).__bool__()
    )


def _schema(names: List[String], types: List[ArrowType]) -> Schema:
    var sb = SchemaBuilder()
    for i in range(len(names)):
        sb.add_field(Field(names[i], types[i], True))
    return sb.build()


def test_names_union_and_identity() raises:
    var reader = _Reader.open(_file())
    var md = _meta(reader)
    assert_equal(_name_to_file_col_idx(md, "n"), 2)
    assert_equal(_name_to_file_col_idx(md, "zz"), -1)
    var remap = _resolve_result_names_to_file_indices(md, ["n", "zz", "a"])
    assert_equal(remap[0], 2)
    assert_equal(remap[1], -1)
    assert_equal(remap[2], 0)
    assert_true(_remap_is_positional_identity([0, 1, 2], 3))
    assert_false(_remap_is_positional_identity([0, 2, 1], 3))
    assert_false(_remap_is_positional_identity([0, 1], 3))

    var schemas = List[Schema]()
    schemas.append(_schema(["a", "b"], [ArrowType.INT64, ArrowType.STRING]))
    schemas.append(_schema(["c", "a"], [ArrowType.FLOAT64, ArrowType.INT64]))
    var u = _build_union_by_name_schema(schemas, ["f0", "f1"])
    assert_equal(len(u[0]), 3)
    assert_equal(u[0][2], "c")
    assert_true(u[1][2] == ArrowType.FLOAT64)
    schemas.append(_schema(["b"], [ArrowType.INT32]))
    with assert_raises(contains="'b' is"):
        _ = _build_union_by_name_schema(schemas, ["f0", "f1", "f2"])
    try:
        _ = _build_union_by_name_schema(schemas, ["f0", "f1", "f2"])
    except e:
        assert_true(String(e).find("f0") >= 0 and String(e).find("f2") >= 0)


def test_the_by_name_decode() raises:
    var reader = _Reader.open(_file())
    var md = _meta(reader)
    var names: List[String] = ["n", "missing", "a"]
    var types: List[ArrowType] = [ArrowType.INT64, ArrowType.DATE32, ArrowType.INT64]
    var remap = _resolve_result_names_to_file_indices(md, names)
    var b = _decode_columns_by_name_remap(
        reader, md.row_groups[1], md.schema, remap, names, types, 10, False
    )
    assert_equal(b.num_columns(), 3)
    assert_equal(b.schema.field_name(1), "missing")
    assert_true(b.column_at(1).arrow_type == ArrowType.DATE32)
    assert_equal(b.column_at(1).null_count(), 10)
    for i in range(10):
        assert_equal(Int(b.column_at(0).as_primitive[DType.int64]().get(i)), _n(20 + i))
        assert_equal(Int(b.column_at(2).as_primitive[DType.int64]().get(i)), _a(20 + i))
    with assert_raises(contains="slots but"):
        _ = _decode_columns_by_name_remap(
            reader, md.row_groups[1], md.schema, remap, ["n"], types, 10, False
        )


def test_the_read_ahead_hint() raises:
    var reader = _Reader.open(_file())
    var md = _meta(reader)
    for g in range(-1, 4):
        _advise_prefetch_next_rg(reader, md, g)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
