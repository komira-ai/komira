# ParquetReader on a file written by komira_test_parquet_file (60 rows, two
# row groups of 30, pages of 10, page index on), every value checked against
# the rows written:
#   - footer facts: counts, the selection class per column shape, the byte
#     range, the statistics prune and all-match, the bloom prune with no
#     bloom, the schema and name lookup;
#   - decodes: subset (fresh, caller context, own context), by name (the
#     identity and a reordered result with a missing column), selected rows
#     (and the dictionary decline under preserve_dict), the fused dictionary
#     count and survivors (None for a plain chunk and for a chunk with a
#     null), the codes feed, the hash-aggregate decode's hashes;
#   - the page-pruned decodes: no page survives -> None; a partial read
#     returns only the surviving pages' rows, row aligned across the filter
#     and payload columns; without the partial allowance every row;
#   - the read-ahead hint's advised bytes per mode;
#   - the offset-width refinement: STRING -> LARGE_STRING with the values
#     and the selection mask kept, a DICTIONARY hint ignored.

from std.memory import ArcPointer
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.record_batch import RecordBatch
from komira_async.ops.waker_sink import NoopSink
from komira_fs.local_fs import LocalFs
from komira_morsel.hash_agg_decoded import fib_hash_key, partition_for_hash
from komira_parquet.arrow_schema_hint import ArrowSchemaHint
from komira_parquet.column_decode_context import ColumnDecodeContext
from komira_parquet.file_reader import ParquetFileReader
from komira_parquet.metadata_parser import parse_full_metadata
from komira_parquet.scan_copy_trace import (
    PREFETCH_MODE_LEGACY,
    PREFETCH_MODE_NONE,
    PREFETCH_MODE_PROJ,
    prefetch_advise_bytes,
)
from komira_parquet_api.metadata import FileMetaData
from komira_parquet_scan.arrow_hint_refine import refine_batch_by_arrow_hint
from komira_parquet_scan.parquet_reader import ParquetReader
from komira_parquet_scan.prefetch import prefetch_range_of
from komira_plan_expr.expr import BIN_GE, BIN_GT, BIN_LT, Expr
from komira_plan_expr.scalar_value import ScalarValue
from komira_runtime_paths import test_tmpdir
from komira_scan_planning.reader_factory import (
    SELECTION_DECLINES,
    SELECTION_FIXED_WIDTH,
    SELECTION_VAR_WIDTH,
)
from komira_test_parquet_file import PT_INT32, PT_INT64, TestColumn, TestFileLayout, write_parquet_file

comptime _FS = LocalFs[NoopSink]
comptime _ROWS = 60
# Column indices.
comptime A = 0  # INT64 = row
comptime S = 1  # string PLAIN
comptime D = 2  # INT64 dictionary = row % 5
comptime DN = 3  # INT64 dictionary, null every 6th row, = row % 3
comptime F = 4  # DOUBLE = row / 2
comptime T = 5  # string dictionary


def _s(r: Int) -> String:
    return "s" + String(r % 4)


def _t(r: Int) -> String:
    return "t" + String(r % 3)


def _file() raises -> String:
    var path = test_tmpdir() + "/reader.parquet"
    var a = List[Int]()
    var s = List[String]()
    var d = List[Int]()
    var dn = List[Int]()
    var nn = List[Bool]()
    var f = List[Float64]()
    var t = List[String]()
    for r in range(_ROWS):
        a.append(r)
        s.append(_s(r))
        d.append(r % 5)
        dn.append(r % 3)
        nn.append(r % 6 == 0)
        f.append(Float64(r) / 2.0)
        t.append(_t(r))
    var cols = List[TestColumn]()
    cols.append(TestColumn.int64("a", a^))
    cols.append(TestColumn.string("s", s^))
    cols.append(TestColumn.int64("d", d^).dict_encoded())
    cols.append(TestColumn.int64("dn", dn^).dict_encoded().with_nulls(nn^))
    cols.append(TestColumn.float64("f", f^))
    cols.append(TestColumn.string("t", t^).dict_encoded())
    write_parquet_file(path, cols, TestFileLayout([30, 30], 10, True))
    return path^


def _reader_at(path: String) raises -> ParquetReader[_FS]:
    var file = ParquetFileReader[_FS].open(path)
    var meta = parse_full_metadata(file.metadata_bytes.view_range_ro(0, file.metadata_length))
    return ParquetReader[_FS](_file=file^, _meta=ArcPointer[FileMetaData](meta^))


def _reader() raises -> ParquetReader[_FS]:
    return _reader_at(_file())


def _reader_with_meta(var meta: FileMetaData) raises -> ParquetReader[_FS]:
    """The standard file under an edited copy of its footer."""
    var file = ParquetFileReader[_FS].open(_file())
    return ParquetReader[_FS](_file=file^, _meta=ArcPointer[FileMetaData](meta^))


comptime _UINT_ROWS = 40
comptime _U32 = 0  # INT32 annotated UINT_32, dictionary = 2^31 + row % 4
comptime _U64 = 1  # INT64 annotated UINT_64, dictionary = 2^63 + row % 4 (as the bits)


def _uint_file() raises -> String:
    var path = test_tmpdir() + "/reader_uint.parquet"
    var u32 = List[Int]()
    var u64 = List[Int]()
    var lowest = -(1 << 62) - (1 << 62)
    for r in range(_UINT_ROWS):
        u32.append((1 << 31) + r % 4)
        u64.append(lowest + r % 4)
    var a = TestColumn(String("u32"), PT_INT32, 13)
    a.ints = u32^
    var b = TestColumn(String("u64"), PT_INT64, 14)
    b.ints = u64^
    var cols = List[TestColumn]()
    cols.append(a^.dict_encoded())
    cols.append(b^.dict_encoded())
    write_parquet_file(path, cols, TestFileLayout.single())
    return path^


def _cmp(op: UInt8, col: String, v: Int) -> Expr:
    return Expr.binary(op, Expr.col_ref(col), Expr.literal(ScalarValue.from_int(v)))


def _i64(b: RecordBatch, col: Int, row: Int) raises -> Int:
    return Int(b.column_at(col).as_primitive[DType.int64]().get(row))


def test_footer_facts() raises:
    var r = _reader()
    assert_equal(r.unit_count_for_file(), 2)
    assert_equal(r.unit_num_rows(1), 30)
    assert_equal(r.unit_num_columns(0), 6)
    assert_equal(r.unit_column_selection_class(0, A, False), SELECTION_FIXED_WIDTH)
    assert_equal(r.unit_column_selection_class(0, S, False), SELECTION_VAR_WIDTH)
    assert_equal(r.unit_column_selection_class(0, D, False), SELECTION_FIXED_WIDTH)
    assert_equal(r.unit_column_selection_class(0, D, True), SELECTION_DECLINES)
    assert_equal(r.unit_column_selection_class(0, F, False), SELECTION_FIXED_WIDTH)
    assert_equal(r.unit_column_selection_class(0, T, False), SELECTION_VAR_WIDTH)
    assert_equal(r.unit_column_selection_class(0, 6, False), SELECTION_DECLINES)
    var br0 = r.unit_byte_range(0)
    var br1 = r.unit_byte_range(1)
    assert_true(br0.length > 0)
    assert_true(br1.offset >= br0.offset + br0.length)
    assert_true(r.can_prune_unit(0, _cmp(BIN_GT, "a", 100)))
    assert_true(r.can_prune_unit(1, _cmp(BIN_LT, "a", 10)))
    assert_false(r.can_prune_unit(0, _cmp(BIN_LT, "a", 10)))
    assert_true(r.unit_all_match(0, _cmp(BIN_LT, "a", 30)))
    assert_false(r.unit_all_match(1, _cmp(BIN_LT, "a", 30)))
    assert_false(r.can_prune_unit_by_bloom(0, _cmp(BIN_GT, "a", 100)))
    var sch = r.build_arrow_schema_for_file()
    assert_equal(sch.num_columns(), 6)
    assert_equal(r.column_name_to_idx_for_file("f"), F)
    assert_equal(r.column_name_to_idx_for_file("zz"), -1)
    assert_equal(r.meta_copy().num_rows, 60)
    assert_true(r.file_path().endswith("reader.parquet"))


def _check_row_group_1(b: RecordBatch) raises:
    """`b` is columns [t, a, f] of row group 1."""
    assert_equal(b.num_rows(), 30)
    for i in range(30):
        var r = 30 + i
        assert_equal(b.column_at(0).as_string().get(i), _t(r))
        assert_equal(_i64(b, 1, i), r)
        assert_equal(Float64(b.column_at(2).as_primitive[DType.float64]().get(i)), Float64(r) / 2.0)


def test_subset_decodes() raises:
    var r = _reader()
    _check_row_group_1(r.decode_columns_subset(1, [T, A, F], False))
    var ctx = ColumnDecodeContext()
    _check_row_group_1(r.decode_columns_subset_with_ctx(1, [T, A, F], False, ctx))
    _check_row_group_1(r.decode_columns_subset_arena(1, [T, A, F], False))
    _check_row_group_1(r.decode_columns_subset_arena(1, [T, A, F], False))
    var kept = r.decode_columns_subset(0, [T], True)
    assert_true(kept.column_at(0).arrow_type == ArrowType.DICTIONARY)


def test_by_name_decodes() raises:
    var r = _reader()
    var names: List[String] = ["a", "s", "d", "dn", "f", "t"]
    var types: List[ArrowType] = [
        ArrowType.INT64, ArrowType.STRING, ArrowType.INT64, ArrowType.INT64, ArrowType.FLOAT64, ArrowType.STRING
    ]
    var ident = r.decode_columns_by_name_remap(1, names, types, False)
    assert_equal(ident.num_columns(), 6)
    assert_equal(_i64(ident, 0, 3), 33)
    var other: List[String] = ["f", "zz", "a"]
    var otypes: List[ArrowType] = [ArrowType.FLOAT64, ArrowType.INT32, ArrowType.INT64]
    var b = r.decode_columns_by_name_remap(1, other, otypes, False)
    assert_equal(b.num_columns(), 3)
    assert_equal(b.column_at(1).null_count(), 30)
    assert_equal(_i64(b, 2, 4), 34)


def test_selected_rows() raises:
    var r = _reader()
    var mask = BooleanArray.allocate(30)
    var keep: List[Int] = [0, 7, 8, 21, 29]
    for i in range(len(keep)):
        mask.data.set(keep[i])
    var got = r.decode_columns_subset_selected(0, [S, A, T], False, mask)
    assert_true(got.__bool__())
    ref b = got.value()
    assert_equal(b.num_rows(), 5)
    for i in range(5):
        assert_equal(b.column_at(0).as_string().get(i), _s(keep[i]))
        assert_equal(_i64(b, 1, i), keep[i])
        assert_equal(b.column_at(2).as_string().get(i), _t(keep[i]))
    # A dictionary chunk kept as a dictionary is declined.
    assert_false(r.decode_columns_subset_selected(0, [S, T], True, mask).__bool__())


def test_fused_dictionary_count_and_survivors() raises:
    var r = _reader()
    # d = row % 5 over rows 0..29: d > 2 holds for 12 rows.
    assert_equal(r.fused_dict_count(0, D, BIN_GT, 2).value(), 12)
    assert_false(r.fused_dict_count(0, A, BIN_GT, 2).__bool__())
    var surv = r.fused_dict_survivors(1, D, BIN_GE, 4)
    ref idx = surv.value()
    assert_equal(len(idx), 6)
    for i in range(len(idx)):
        assert_equal((30 + idx[i]) % 5, 4)
    # A chunk with a null: its codes are not row aligned.
    assert_false(r.fused_dict_survivors(0, DN, BIN_GE, 0).__bool__())
    # The count skips nulls: dn = row % 3 >= 1 on non-null rows of 0..29.
    var want = 0
    for row in range(30):
        if row % 6 != 0 and row % 3 >= 1:
            want += 1
    assert_equal(r.fused_dict_count(0, DN, BIN_GE, 1).value(), want)


def test_the_codes_feed() raises:
    var r = _reader()
    var feed = r.decode_rowgroup_codes_feed(1, [D, A], [F])
    assert_equal(feed.num_keys(), 2)
    assert_equal(feed.n_rows, 30)
    ref k0 = feed.keys[0]
    assert_true(k0.has_codes())
    for i in range(30):
        assert_equal(Int(k0.codes.dict_values[Int(k0.codes.codes.get(i))]), (30 + i) % 5)
    ref k1 = feed.keys[1]
    assert_false(k1.has_codes())
    assert_equal(Int(k1.flat.as_primitive[DType.int64]().get(2)), 32)
    assert_equal(feed.values.num_columns(), 1)


def test_unsigned_dictionary_chunks_are_not_fused() raises:
    # The fused paths widen entries with sign extension, so a UINT_32 value at
    # or above 2^31 (UINT_64 at or above 2^63) would be negative and compare
    # wrongly: the count would be 0 here, not the 20 rows with row % 4 >= 2.
    var r = _reader_at(_uint_file())
    assert_false(r.fused_dict_count(0, _U32, BIN_GT, Int64((1 << 31) + 1)).__bool__())
    assert_false(r.fused_dict_count(0, _U64, BIN_GT, 0).__bool__())
    assert_false(r.fused_dict_survivors(0, _U32, BIN_GT, Int64((1 << 31) + 1)).__bool__())
    assert_false(r.fused_dict_survivors(0, _U64, BIN_GT, 0).__bool__())
    # The codes feed delivers both flat, every row.
    var feed = r.decode_rowgroup_codes_feed(0, [_U32, _U64], List[Int]())
    assert_equal(feed.n_rows, _UINT_ROWS)
    for k in range(2):
        assert_false(feed.keys[k].has_codes())
        assert_equal(feed.keys[k].flat.length(), _UINT_ROWS)
    # The flat decode reads every row.
    var flat = r.decode_columns_subset(0, [_U32], False)
    assert_equal(flat.num_rows(), _UINT_ROWS)


def test_the_codes_feed_delivers_a_key_with_a_null_flat() raises:
    # dn is a dictionary chunk whose nulls (every 6th row) have no code, so its
    # codes would not line up with the rows: it is delivered flat, every row.
    var r = _reader()
    var feed = r.decode_rowgroup_codes_feed(0, [DN, D], [A])
    assert_equal(feed.n_rows, 30)
    ref k0 = feed.keys[0]
    assert_false(k0.has_codes())
    assert_equal(k0.flat.length(), 30)
    assert_equal(k0.flat.null_count(), 5)
    for row in range(30):
        assert_equal(k0.flat.is_null_at(row), row % 6 == 0, "row " + String(row))
        if row % 6 != 0:
            assert_equal(Int(k0.flat.as_primitive[DType.int64]().get(row)), row % 3)
    # The key without a null still comes as codes, row aligned.
    assert_true(feed.keys[1].has_codes())
    assert_equal(feed.keys[1].codes.codes.length, 30)


def test_selected_rows_of_a_column_with_nulls() raises:
    var r = _reader()
    var mask = BooleanArray.allocate(30)
    var keep: List[Int] = [0, 1, 2, 7, 12, 29]
    for i in range(len(keep)):
        mask.data.set(keep[i])
    var got = r.decode_columns_subset_selected(0, [DN], False, mask)
    assert_true(got.__bool__())
    ref col = got.value().column_at(0)
    assert_equal(col.length(), len(keep))
    for i in range(len(keep)):
        var null = keep[i] % 6 == 0
        assert_equal(col.is_null_at(i), null, "row " + String(keep[i]))
        if not null:
            assert_equal(Int(col.as_primitive[DType.int64]().get(i)), keep[i] % 3)


def test_a_dictionary_offset_of_zero_is_no_dictionary() raises:
    var base = _reader()
    var meta = base.meta_copy()
    # a is PLAIN; some writers store dictionary_page_offset = 0 for a chunk
    # with no dictionary page.
    meta.row_groups[1].columns[A].meta_data.dictionary_page_offset = Optional[Int](0)
    var r = _reader_with_meta(meta^)
    assert_equal(r.unit_column_selection_class(1, A, True), SELECTION_FIXED_WIDTH)
    # A real dictionary chunk still declines under preserve_dict.
    assert_equal(r.unit_column_selection_class(1, D, True), SELECTION_DECLINES)
    # The read-ahead range starts at the first data page, not at byte 0.
    var md = r.meta_copy()
    ref chunk = md.row_groups[1].columns[A]
    var span = prefetch_range_of(chunk)
    assert_equal(span[0], chunk.meta_data.data_page_offset)
    assert_equal(span[1], chunk.meta_data.total_compressed_size)
    assert_true(span[0] > 0)


def test_the_read_ahead_range_starts_at_the_dictionary_page() raises:
    var md = _reader().meta_copy()
    ref chunk = md.row_groups[1].columns[T]
    var span = prefetch_range_of(chunk)
    var d = chunk.meta_data.dictionary_page_offset.value()
    assert_true(d < chunk.meta_data.data_page_offset)
    assert_equal(span[0], d)
    assert_equal(span[1], chunk.meta_data.total_compressed_size)


def test_a_nested_footer_declines_every_decision_it_cannot_make() raises:
    # Element 1 turned into a group: leaf c is no longer schema[c + 1], so the
    # selection class, the selected decode and the dictionary-codes paths
    # decline instead of reading the wrong element.
    var meta = _reader().meta_copy()
    meta.schema[1].num_children = 1
    var r = _reader_with_meta(meta^)
    assert_equal(r.unit_column_selection_class(0, S, False), SELECTION_DECLINES)
    assert_equal(r.unit_column_selection_class(0, F, False), SELECTION_DECLINES)
    var mask = BooleanArray.allocate(30)
    mask.data.set(3)
    assert_false(r.decode_columns_subset_selected(0, [S, F], False, mask).__bool__())
    assert_false(r.fused_dict_count(0, D, BIN_GT, 2).__bool__())
    assert_false(r.fused_dict_survivors(1, D, BIN_GE, 4).__bool__())
    var feed = r.decode_rowgroup_codes_feed(1, [D], List[Int]())
    assert_false(feed.keys[0].has_codes())
    # The footer of the file as written is flat and keeps its classes.
    var flat = _reader()
    assert_equal(flat.unit_column_selection_class(0, S, False), SELECTION_VAR_WIDTH)


def test_the_hash_aggregate_decode() raises:
    var r = _reader()
    var got = r.decode_for_hash_agg(0, A, [F, D], False)
    var dec = got.take()
    assert_equal(dec.num_rows(), 30)
    var keys = dec.take_key_array()
    var hashes = dec.take_hashes()
    var parts = dec.take_partition_ids()
    var cols = dec.take_agg_input_columns()
    assert_equal(len(cols), 2)
    for i in range(30):
        var h = fib_hash_key(keys.get_typed[Int64](i))
        assert_equal(hashes.get_typed[UInt64](i), h)
        assert_equal(Int(parts[i]), partition_for_hash(h))
    assert_equal(Float64(cols[0].as_primitive[DType.float64]().get(5)), 2.5)
    assert_equal(Int(cols[1].as_primitive[DType.int64]().get(7)), 2)


def test_page_pruned_decodes() raises:
    var r = _reader()
    var none = _cmp(BIN_GT, "a", 100)
    assert_false(r.decode_columns_subset_with_filter(0, [A], False, none, True).__bool__())
    assert_false(r.decode_filter_and_payload(0, [A], [S], False, none, True).__bool__())
    # a >= 25 in row group 0: only its last page (rows 20..29) survives.
    var late = _cmp(BIN_GE, "a", 25)
    var part = r.decode_columns_subset_with_filter(0, [A, S], False, late, True)
    ref pb = part.value()
    assert_equal(pb.num_rows(), 10)
    for i in range(10):
        assert_equal(_i64(pb, 0, i), 20 + i)
        assert_equal(pb.column_at(1).as_string().get(i), _s(20 + i))
    var whole = r.decode_columns_subset_with_filter(0, [A], False, late, False)
    assert_equal(whole.value().num_rows(), 30)
    var fp = r.decode_filter_and_payload(0, [A], [S, D], False, late, True)
    var pair = fp.take()
    var fb = pair.take_filter()
    var pay = pair.take_payload()
    assert_equal(fb.num_rows(), 10)
    assert_equal(pay.num_rows(), 10)
    for i in range(10):
        assert_equal(_i64(fb, 0, i), 20 + i)
        assert_equal(pay.column_at(0).as_string().get(i), _s(20 + i))
        assert_equal(_i64(pay, 1, i), (20 + i) % 5)
    var fp2 = r.decode_filter_and_payload(1, [A], List[Int](), False, late, False)
    var pair2 = fp2.take()
    assert_equal(pair2.take_filter().num_rows(), 30)
    var empty = pair2.take_payload()
    assert_equal(empty.num_rows(), 30)
    assert_equal(empty.num_columns(), 0)
    assert_true(r.page_index_cache_miss_count() > 0)
    assert_true(r.page_index_cache_size() > 0)


def test_the_read_ahead_hint() raises:
    var r = _reader()
    var md = r.meta_copy()
    var a_bytes = Int(md.row_groups[1].columns[A].meta_data.total_compressed_size)
    var t_bytes = Int(md.row_groups[1].columns[T].meta_data.total_compressed_size)
    var b0 = prefetch_advise_bytes()
    r.advise_prefetch_next(1, [T, A], PREFETCH_MODE_PROJ)
    assert_equal(prefetch_advise_bytes() - b0, a_bytes + t_bytes)
    var b1 = prefetch_advise_bytes()
    r.advise_prefetch_next(1, [T], PREFETCH_MODE_LEGACY)
    assert_equal(prefetch_advise_bytes() - b1, a_bytes)
    var b2 = prefetch_advise_bytes()
    r.advise_prefetch_next(1, [T, A], PREFETCH_MODE_NONE)
    r.advise_prefetch_next(1, List[Int](), PREFETCH_MODE_PROJ)
    r.advise_prefetch_next(2, [A], PREFETCH_MODE_PROJ)
    r.advise_prefetch_next(1, [99], PREFETCH_MODE_PROJ)
    assert_equal(prefetch_advise_bytes() - b2, 0)


def test_the_offset_width_refinement() raises:
    var r = _reader()
    var b = r.decode_columns_subset(0, [S, A, T], False)
    var mask = BooleanArray.allocate(30)
    mask.data.set(3)
    b.set_selection_mask(mask^)
    var names: List[String] = ["s", "t"]
    var types: List[ArrowType] = [ArrowType.LARGE_STRING, ArrowType.DICTIONARY]
    var out = refine_batch_by_arrow_hint(b^, ArrowSchemaHint(names^, types^))
    assert_true(out.schema.field_arrow_type(0) == ArrowType.LARGE_STRING)
    assert_true(out.column_at(0).arrow_type == ArrowType.LARGE_STRING)
    assert_true(out.schema.field_arrow_type(2) == ArrowType.STRING)
    assert_true(out.schema.field_arrow_type(1) == ArrowType.INT64)
    assert_equal(out.column_at(0).as_large_string().get(5), _s(5))
    var kept = out.take_selection_mask()
    assert_equal(kept.value().true_count(), 1)
    var same = refine_batch_by_arrow_hint(r.decode_columns_subset(0, [S], False), ArrowSchemaHint())
    assert_true(same.schema.field_arrow_type(0) == ArrowType.STRING)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
