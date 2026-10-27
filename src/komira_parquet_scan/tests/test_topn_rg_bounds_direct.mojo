# topn_rg_bounds on footers written by komira_test_parquet_file:
#   - bounds per row group, and the claim order ascending by min and
#     descending by max, ties kept in file order;
#   - an INT32 key;
#   - each decline: an unknown column, a string key, a null in the key, an
#     INT64 annotated UINT_64, a DECIMAL;
#   - an INT32 annotated UINT_32 whose values reach 2**31 has its bounds
#     zero-extended (read signed, the largest values would be negative and a
#     descending top-N would prune the row group holding them).

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_fs.local_fs import LocalFs
from komira_parquet.file_reader import ParquetFileReader
from komira_parquet.metadata_parser import parse_full_metadata
from komira_parquet_api.metadata import FileMetaData
from komira_parquet_scan.topn_rg_bounds import build_topn_rg_prune_plan
from komira_runtime_paths import test_tmpdir
from komira_test_parquet_file import TestColumn, TestFileLayout, write_parquet_file

comptime _FS = LocalFs[NoopSink]
comptime _CT_DECIMAL = 5
comptime _CT_UINT_32 = 13
comptime _CT_UINT_64 = 14


def _meta_of(name: String, var cols: List[TestColumn], var rgs: List[Int]) raises -> FileMetaData:
    var path = test_tmpdir() + "/" + name + ".parquet"
    write_parquet_file(path, cols, TestFileLayout(rgs^, 0, False))
    var f = ParquetFileReader[_FS].open(path)
    return parse_full_metadata(f.metadata_bytes.view_range_ro(0, f.metadata_length))


def _keys() -> List[Int]:
    # Row groups of 3: [7 8 9] [1 2 3] [7 9 12] [-4 0 5]
    return [7, 8, 9, 1, 2, 3, 7, 9, 12, -4, 0, 5]


def _rgs() -> List[Int]:
    return [3, 3, 3, 3]


def test_bounds_and_claim_order_both_ways() raises:
    var cols = List[TestColumn]()
    cols.append(TestColumn.int64("k", _keys()))
    var md = _meta_of("asc", cols^, _rgs())
    var asc = build_topn_rg_prune_plan(md, "k", False)
    assert_true(asc.__bool__())
    ref p = asc.value()
    assert_equal(p.num_units(), 4)
    assert_equal(Int(p.key_min[2]), 7)
    assert_equal(Int(p.key_max[2]), 12)
    assert_equal(Int(p.key_min[3]), -4)
    # Ascending min: -4 (rg 3), 1 (rg 1), 7 (rg 0), 7 (rg 2): the tie keeps
    # file order.
    var want_asc: List[Int] = [3, 1, 0, 2]
    for i in range(4):
        assert_equal(p.claim_order[i], want_asc[i])
    var desc = build_topn_rg_prune_plan(md, "k", True)
    ref q = desc.value()
    assert_true(q.descending)
    # Descending max: 12 (rg 2), 9 (rg 0), 5 (rg 3), 3 (rg 1).
    var want_desc: List[Int] = [2, 0, 3, 1]
    for i in range(4):
        assert_equal(q.claim_order[i], want_desc[i])


def test_an_int32_key() raises:
    var cols = List[TestColumn]()
    cols.append(TestColumn.int32("k", _keys()))
    var md = _meta_of("i32", cols^, _rgs())
    var p = build_topn_rg_prune_plan(md, "k", False)
    assert_equal(Int(p.value().key_min[3]), -4)
    assert_equal(Int(p.value().key_max[2]), 12)


def test_the_declines() raises:
    var base = List[TestColumn]()
    base.append(TestColumn.int64("k", _keys()))
    var s = List[String]()
    for i in range(12):
        s.append("v" + String(i))
    base.append(TestColumn.string("s", s^))
    var md = _meta_of("declines", base^, _rgs())
    assert_false(build_topn_rg_prune_plan(md, "missing", False).__bool__())
    assert_false(build_topn_rg_prune_plan(md, "s", False).__bool__())

    var nulls = List[Bool]()
    for i in range(12):
        nulls.append(i == 10)
    var nc = List[TestColumn]()
    nc.append(TestColumn.int64("k", _keys()).with_nulls(nulls^))
    assert_false(build_topn_rg_prune_plan(_meta_of("nulls", nc^, _rgs()), "k", False).__bool__())

    var u64 = TestColumn.int64("k", _keys())
    u64.converted_type = _CT_UINT_64
    var uc = List[TestColumn]()
    uc.append(u64^)
    assert_false(build_topn_rg_prune_plan(_meta_of("u64", uc^, _rgs()), "k", True).__bool__())

    var dec = TestColumn.int64("k", _keys())
    dec.converted_type = _CT_DECIMAL
    var dc = List[TestColumn]()
    dc.append(dec^)
    assert_false(build_topn_rg_prune_plan(_meta_of("dec", dc^, _rgs()), "k", True).__bool__())


def test_uint32_bounds_are_zero_extended() raises:
    # Row group 1 holds values at and above 2**31.
    var big = 1 << 31
    var keys: List[Int] = [1, 2, 3, big, big + 5, big + 9]
    var c = TestColumn.int32("k", keys^)
    c.converted_type = _CT_UINT_32
    var cols = List[TestColumn]()
    cols.append(c^)
    var md = _meta_of("u32", cols^, [3, 3])
    var p = build_topn_rg_prune_plan(md, "k", True)
    ref plan = p.value()
    assert_equal(Int(plan.key_min[1]), big)
    assert_equal(Int(plan.key_max[1]), big + 9)
    # The row group holding the largest values is claimed first.
    assert_equal(plan.claim_order[0], 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
