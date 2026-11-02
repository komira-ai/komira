# =============================================================================
# Footers this package refuses, built byte by byte
# =============================================================================
#
# Each file is `PAR1`, padding, a hand-written Thrift Compact FileMetaData, its
# length and `PAR1`; no writer is involved. Every refusal must name the file.
#
#   * test_footer_without_schema_is_refused: a footer holding only a version
#     and one with an empty schema list. Catches garbage read as an empty file.
#   * test_negative_num_rows_is_refused: Catches a row count below zero passed on.
#   * test_nested_group_is_refused, test_repeated_leaf_is_refused: a group
#     column and a repeated leaf are refused, naming the column, by
#     `FooterCache.summary` and `ParquetFooters.footer_schema`. Catches a group
#     read as a flat string column with its children hoisted.
# =============================================================================

from std.testing import TestSuite, assert_raises

from komira_parquet_footers.footer_cache import FooterCache
from komira_parquet_footers.parquet_footers import ParquetFooters
from komira_runtime_paths import test_tmpdir


def _uleb(mut out: List[UInt8], v: Int):
    var x = UInt64(v)
    while x >= 0x80:
        out.append(UInt8((x & 0x7F) | 0x80))
        x >>= 7
    out.append(UInt8(x))


def _zz(mut out: List[UInt8], v: Int):
    _uleb(out, (v << 1) ^ (v >> 63))


def _name(mut out: List[UInt8], header: UInt8, name: String):
    out.append(header)
    _uleb(out, name.byte_length())
    for b in name.as_bytes():
        out.append(b)


def _leaf(mut f: List[UInt8], type_code: Int, repetition: Int, name: String):
    f.append(0x15)
    _zz(f, type_code)
    f.append(0x25)
    _zz(f, repetition)
    _name(f, 0x18, name)
    f.append(0x00)


def _group(mut f: List[UInt8], repetition: Int, name: String, children: Int):
    f.append(0x35)
    _zz(f, repetition)
    _name(f, 0x18, name)
    f.append(0x15)
    _zz(f, children)
    f.append(0x00)


def _root(mut f: List[UInt8], children: Int):
    _name(f, 0x48, "schema")
    f.append(0x15)
    _zz(f, children)
    f.append(0x00)


def _footer_with(elements: List[UInt8], count: Int, num_rows: Int) -> List[UInt8]:
    """FileMetaData whose schema list is `count` already-encoded `elements`."""
    var f: List[UInt8] = [0x15]
    _zz(f, 2)
    f.append(0x19)
    f.append(UInt8((count << 4) | 0x0C))
    for i in range(len(elements)):
        f.append(elements[i])
    f.append(0x16)
    _zz(f, num_rows)
    f.append(0x19)
    f.append(0x0C)
    f.append(0x00)
    return f^


def _put_framed(file_name: String, body: List[UInt8]) raises -> String:
    var out: List[UInt8] = [0x50, 0x41, 0x52, 0x31]
    for i in range(24):
        out.append(UInt8(i * 7 % 251))
    for i in range(len(body)):
        out.append(body[i])
    var n = len(body)
    for k in range(4):
        out.append(UInt8((n >> (8 * k)) & 0xFF))
    for b in "PAR1".as_bytes():
        out.append(b)
    var path = test_tmpdir() + "/" + file_name
    var fh = open(path, "w")
    fh.write_bytes(Span(out))
    fh.close()
    return path^


def _refused(path: String, reason: String) raises:
    var cache = FooterCache()
    with assert_raises(contains=path):
        _ = cache.summary(path)
    with assert_raises(contains=reason):
        _ = cache.summary(path)
    var footers = ParquetFooters()
    with assert_raises(contains=path):
        _ = footers.footer_schema(path)


def test_footer_without_schema_is_refused() raises:
    var only_version: List[UInt8] = [0x15]
    _zz(only_version, 2)
    only_version.append(0x00)
    _refused(_put_framed("fr_noschema.parquet", only_version), "no schema")
    var empty = List[UInt8]()
    _refused(
        _put_framed("fr_emptyschema.parquet", _footer_with(empty, 0, 5)),
        "no schema",
    )


def test_negative_num_rows_is_refused() raises:
    var e = List[UInt8]()
    _root(e, 1)
    _leaf(e, 2, 0, "a")
    _refused(
        _put_framed("fr_neg.parquet", _footer_with(e, 2, -5)), "negative num_rows"
    )


def test_nested_group_is_refused() raises:
    var e = List[UInt8]()
    _root(e, 1)
    _group(e, 0, "g", 2)
    _leaf(e, 1, 0, "x")
    _leaf(e, 2, 0, "y")
    _refused(_put_framed("fr_group.parquet", _footer_with(e, 4, 3)), "'g'")


def test_repeated_leaf_is_refused() raises:
    var e = List[UInt8]()
    _root(e, 1)
    _leaf(e, 1, 2, "r")
    _refused(_put_framed("fr_repeated.parquet", _footer_with(e, 2, 3)), "'r'")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
