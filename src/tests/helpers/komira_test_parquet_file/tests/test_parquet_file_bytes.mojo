# The bytes komira_test_parquet_file writes. A one-row REQUIRED INT64 file
# is compared byte for byte with a copy encoded by hand from parquet.thrift
# (field ids, Thrift Compact headers, zigzag varints), so the encoder cannot
# drift without this test going red; bigger files are checked for their
# framing (both magics, the footer length) and the inputs the writer refuses.

from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from komira_test_parquet_file import (
    TestColumn,
    TestFileLayout,
    parquet_file_bytes,
)


def _expect(var want: List[Int]) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(len(want)):
        out.append(UInt8(want[i]))
    return out^


def _assert_bytes(got: List[UInt8], want: List[UInt8]) raises:
    assert_equal(len(got), len(want), "length")
    for i in range(len(want)):
        assert_equal(Int(got[i]), Int(want[i]), "byte " + String(i))


def test_one_row_int64_file_byte_for_byte() raises:
    var cols = List[TestColumn]()
    cols.append(TestColumn.int64("a", [7]))
    var got = parquet_file_bytes(cols, TestFileLayout.single())
    # fmt: off
    var want = _expect([
        0x50, 0x41, 0x52, 0x31,                     # PAR1
        # PageHeader: type 0, sizes 8 and 8, data_page_header {1, PLAIN,
        # RLE, RLE}
        0x15, 0x00, 0x15, 0x10, 0x15, 0x10, 0x2C,
        0x15, 0x02, 0x15, 0x00, 0x15, 0x06, 0x15, 0x06, 0x00, 0x00,
        0x07, 0, 0, 0, 0, 0, 0, 0,                  # PLAIN 7
        # FileMetaData
        0x15, 0x02,                                 # 1: version 1
        0x19, 0x2C,                                 # 2: schema, 2 structs
        0x48, 0x06, 0x73, 0x63, 0x68, 0x65, 0x6D, 0x61,  # 4: "schema"
        0x15, 0x02, 0x00,                           # 5: num_children 1
        0x15, 0x04, 0x25, 0x00, 0x18, 0x01, 0x61, 0x00,  # INT64 REQUIRED "a"
        0x16, 0x02,                                 # 3: num_rows 1
        0x19, 0x1C,                                 # 4: row_groups, 1
        0x19, 0x1C,                                 #   1: columns, 1
        0x26, 0x08,                                 #     2: file_offset 4
        0x1C,                                       #     3: meta_data
        0x15, 0x04,                                 #       type INT64
        0x19, 0x25, 0x00, 0x06,                     #       PLAIN, RLE
        0x19, 0x18, 0x01, 0x61,                     #       path ["a"]
        0x15, 0x00,                                 #       UNCOMPRESSED
        0x16, 0x02,                                 #       num_values 1
        0x16, 0x32, 0x16, 0x32,                     #       sizes 25, 25
        0x26, 0x08,                                 #       9: data page 4
        0x3C,                                       #       12: statistics
        0x36, 0x00,                                 #         3: nulls 0
        0x28, 0x08, 0x07, 0, 0, 0, 0, 0, 0, 0,      #         5: max 7
        0x18, 0x08, 0x07, 0, 0, 0, 0, 0, 0, 0,      #         6: min 7
        0x00, 0x00, 0x00,
        0x16, 0x32,                                 #   2: total bytes 25
        0x16, 0x02,                                 #   3: num_rows 1
        0x00,
        0x00,
    ])
    # fmt: on
    var footer_len = len(want) - 4 - 25
    for k in range(4):
        want.append(UInt8((footer_len >> (8 * k)) & 0xFF))
    for b in [0x50, 0x41, 0x52, 0x31]:
        want.append(UInt8(b))
    _assert_bytes(got, want)


def _u32_le(b: List[UInt8], at: Int) -> Int:
    var v = 0
    for k in range(4):
        v |= Int(b[at + k]) << (8 * k)
    return v


def test_framing_of_a_bigger_file() raises:
    var ints = List[Int]()
    var strs = List[String]()
    var nulls = List[Bool]()
    for r in range(100):
        ints.append(r * 3 - 50)
        strs.append("s" + String(r % 7))
        nulls.append(r % 5 == 0)
    var cols = List[TestColumn]()
    cols.append(TestColumn.int32("i", ints.copy()).with_nulls(nulls.copy()))
    cols.append(TestColumn.string("s", strs^).dict_encoded())
    var b = parquet_file_bytes(cols, TestFileLayout([60, 40], 16, True))
    var n = len(b)
    assert_true(n > 100)
    assert_equal(Int(b[0]), 0x50)
    assert_equal(Int(b[3]), 0x31)
    assert_equal(Int(b[n - 4]), 0x50)
    assert_equal(Int(b[n - 1]), 0x31)
    var footer_len = _u32_le(b, n - 8)
    assert_true(footer_len > 0 and footer_len < n - 12)
    # The footer is a struct: it ends with its STOP byte.
    assert_equal(Int(b[n - 9]), 0)


def test_refusals() raises:
    var two = List[TestColumn]()
    two.append(TestColumn.int64("a", [1, 2]))
    two.append(TestColumn.int64("b", [1]))
    with assert_raises(contains="row count"):
        _ = parquet_file_bytes(two, TestFileLayout.single())
    var one = List[TestColumn]()
    one.append(TestColumn.int64("a", [1, 2, 3]))
    with assert_raises(contains="add up"):
        _ = parquet_file_bytes(one, TestFileLayout([1, 1], 0, False))
    var bad_nulls = List[TestColumn]()
    bad_nulls.append(TestColumn.int64("a", [1, 2]).with_nulls([True]))
    with assert_raises(contains="one flag per row"):
        _ = parquet_file_bytes(bad_nulls, TestFileLayout.single())
    with assert_raises(contains="no columns"):
        _ = parquet_file_bytes(List[TestColumn](), TestFileLayout.single())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
