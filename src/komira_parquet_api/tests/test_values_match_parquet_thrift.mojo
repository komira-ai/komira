# Every value this package names is the value parquet.thrift gives it. The
# expected numbers are not written here: parquet.thrift is read from the
# parquet-format archive //third_party/parquet-format pins by sha256, staged at
# format/, and each enum's members are parsed out of it. A wrong number would
# make a reader pick the wrong decoder, decompressor or column annotation with
# no error, so the spec is the only acceptable source.
#
# Each enum is checked both ways: every name this package defines has the
# spec's value, and every spec member this package does not name is listed
# below with the reason, so a newer pin that adds a member fails here until
# someone decides whether to name it.
from std.testing import TestSuite, assert_equal, assert_true

from komira_parquet_api import (
    BoundaryOrder,
    CompressionCodec,
    Encoding,
    FieldRepetitionType,
    PageType,
    ParquetType,
)
from komira_parquet_api.types import (
    CONVERTED_TYPE_BSON,
    CONVERTED_TYPE_DATE,
    CONVERTED_TYPE_DECIMAL,
    CONVERTED_TYPE_ENUM,
    CONVERTED_TYPE_INT_8,
    CONVERTED_TYPE_INT_16,
    CONVERTED_TYPE_JSON,
    CONVERTED_TYPE_UINT_8,
    CONVERTED_TYPE_UINT_16,
    CONVERTED_TYPE_UINT_32,
    CONVERTED_TYPE_UINT_64,
    CONVERTED_TYPE_UTF8,
)

comptime _THRIFT = "format/src/main/thrift/parquet.thrift"


def _read(path: String) raises -> String:
    with open(path, "r") as f:
        return f.read()


struct _Enum(Movable):
    """One `enum <name> { ... }` block of parquet.thrift: its members in order."""

    var name: String
    var members: List[String]
    var values: List[Int]
    var seen: List[Bool]

    def __init__(out self, name: String):
        self.name = name
        self.members = List[String]()
        self.values = List[Int]()
        self.seen = List[Bool]()

    def value(mut self, member: String) raises -> Int:
        for i in range(len(self.members)):
            if self.members[i] == member:
                self.seen[i] = True
                return self.values[i]
        raise Error("parquet.thrift enum " + self.name + " has no member " + member)

    def expect(mut self, member: String, ours: Int) raises:
        assert_equal(ours, self.value(member), self.name + "." + member)

    def expect_rest_unnamed(self, var unnamed: List[String]) raises:
        """Every member `expect` did not check is one of `unnamed`, and each
        of `unnamed` is a member."""
        for i in range(len(self.members)):
            if self.seen[i]:
                continue
            var listed = False
            for j in range(len(unnamed)):
                if unnamed[j] == self.members[i]:
                    listed = True
            assert_true(
                listed,
                "parquet.thrift "
                + self.name
                + "."
                + self.members[i]
                + " is neither named by this package nor listed as unnamed",
            )
        for j in range(len(unnamed)):
            var found = False
            for i in range(len(self.members)):
                if self.members[i] == unnamed[j] and not self.seen[i]:
                    found = True
            assert_true(found, self.name + "." + unnamed[j] + " is listed as unnamed but is not")


def _is_member_start(b: Int) -> Bool:
    return b >= 65 and b <= 90  # 'A'..'Z'


def _parse_enum(text: String, name: String) raises -> _Enum:
    """Members of `enum <name> {`: each `  NAME = <int>;` line, one per line.

    A member is indented by exactly two spaces and starts with an upper-case
    letter. Any other line (a comment, its deeper-indented prose, or a member
    the spec has commented out) is not a member; a member-shaped line this
    cannot parse is an error, never skipped.
    """
    var open_at = text.find(String("\nenum ") + name + " {")
    if open_at < 0:
        raise Error("parquet.thrift has no enum " + name)
    var close_at = text.find("\n}", open_at)
    if close_at < 0:
        raise Error("parquet.thrift enum " + name + " is not closed")
    var out = _Enum(name)
    var lines = String(text[byte=open_at + 1 : close_at]).split("\n")
    for li in range(1, len(lines)):
        var raw = String(lines[li])
        var b = raw.as_bytes()
        var s = 2
        if len(b) <= s or b[0] != 32 or b[1] != 32 or not _is_member_start(Int(b[s])):
            continue
        var eq = raw.find(" = ", s)
        var semi = raw.find(";", s)
        if eq < 0 or semi < eq:
            raise Error("parquet.thrift enum " + name + ": unparsed line: " + raw)
        out.members.append(String(raw[byte=s:eq]))
        out.values.append(atol(String(raw[byte = eq + 3 : semi]).strip()))
        out.seen.append(False)
    assert_true(len(out.members) > 0, "parquet.thrift enum " + name + " parsed empty")
    return out^


def test_the_spec_is_the_pinned_one() raises:
    # Not vacuous: the staged file is parquet.thrift, whole.
    var text = _read(_THRIFT)
    assert_true(text.find("namespace java org.apache.parquet.format") >= 0)
    assert_true(text.find("\nstruct FileMetaData {") >= 0)


def test_physical_type() raises:
    var e = _parse_enum(_read(_THRIFT), "Type")
    e.expect("BOOLEAN", Int(ParquetType.BOOLEAN.value))
    e.expect("INT32", Int(ParquetType.INT32.value))
    e.expect("INT64", Int(ParquetType.INT64.value))
    e.expect("INT96", Int(ParquetType.INT96.value))
    e.expect("FLOAT", Int(ParquetType.FLOAT.value))
    e.expect("DOUBLE", Int(ParquetType.DOUBLE.value))
    e.expect("BYTE_ARRAY", Int(ParquetType.BYTE_ARRAY.value))
    e.expect("FIXED_LEN_BYTE_ARRAY", Int(ParquetType.FIXED_LEN_BYTE_ARRAY.value))
    e.expect_rest_unnamed([])


def test_field_repetition_type() raises:
    var e = _parse_enum(_read(_THRIFT), "FieldRepetitionType")
    e.expect("REQUIRED", Int(FieldRepetitionType.REQUIRED.value))
    e.expect("OPTIONAL", Int(FieldRepetitionType.OPTIONAL.value))
    e.expect("REPEATED", Int(FieldRepetitionType.REPEATED.value))
    e.expect_rest_unnamed([])


def test_encoding() raises:
    var e = _parse_enum(_read(_THRIFT), "Encoding")
    e.expect("PLAIN", Int(Encoding.PLAIN.value))
    e.expect("PLAIN_DICTIONARY", Int(Encoding.PLAIN_DICTIONARY.value))
    e.expect("RLE", Int(Encoding.RLE.value))
    e.expect("BIT_PACKED", Int(Encoding.BIT_PACKED.value))
    e.expect("DELTA_BINARY_PACKED", Int(Encoding.DELTA_BINARY_PACKED.value))
    e.expect("DELTA_LENGTH_BYTE_ARRAY", Int(Encoding.DELTA_LENGTH_BYTE_ARRAY.value))
    e.expect("DELTA_BYTE_ARRAY", Int(Encoding.DELTA_BYTE_ARRAY.value))
    e.expect("RLE_DICTIONARY", Int(Encoding.RLE_DICTIONARY.value))
    e.expect("BYTE_STREAM_SPLIT", Int(Encoding.BYTE_STREAM_SPLIT.value))
    # ALP: not named here yet; a page in it prints as Encoding(10). (Value 1,
    # GROUP_VAR_INT, is commented out in the spec, so it is not a member.)
    e.expect_rest_unnamed(["ALP"])


def test_compression_codec() raises:
    var e = _parse_enum(_read(_THRIFT), "CompressionCodec")
    e.expect("UNCOMPRESSED", Int(CompressionCodec.UNCOMPRESSED.value))
    e.expect("SNAPPY", Int(CompressionCodec.SNAPPY.value))
    e.expect("GZIP", Int(CompressionCodec.GZIP.value))
    e.expect("LZO", Int(CompressionCodec.LZO.value))
    e.expect("BROTLI", Int(CompressionCodec.BROTLI.value))
    e.expect("LZ4", Int(CompressionCodec.LZ4.value))
    e.expect("ZSTD", Int(CompressionCodec.ZSTD.value))
    e.expect("LZ4_RAW", Int(CompressionCodec.LZ4_RAW.value))
    e.expect_rest_unnamed([])


def test_page_type() raises:
    var e = _parse_enum(_read(_THRIFT), "PageType")
    e.expect("DATA_PAGE", Int(PageType.DATA_PAGE.value))
    e.expect("INDEX_PAGE", Int(PageType.INDEX_PAGE.value))
    e.expect("DICTIONARY_PAGE", Int(PageType.DICTIONARY_PAGE.value))
    e.expect("DATA_PAGE_V2", Int(PageType.DATA_PAGE_V2.value))
    e.expect_rest_unnamed([])


def test_boundary_order() raises:
    var e = _parse_enum(_read(_THRIFT), "BoundaryOrder")
    e.expect("UNORDERED", Int(BoundaryOrder.UNORDERED.value))
    e.expect("ASCENDING", Int(BoundaryOrder.ASCENDING.value))
    e.expect("DESCENDING", Int(BoundaryOrder.DESCENDING.value))
    e.expect_rest_unnamed([])


def test_converted_type() raises:
    var e = _parse_enum(_read(_THRIFT), "ConvertedType")
    e.expect("UTF8", CONVERTED_TYPE_UTF8)
    e.expect("ENUM", CONVERTED_TYPE_ENUM)
    e.expect("DECIMAL", CONVERTED_TYPE_DECIMAL)
    e.expect("DATE", CONVERTED_TYPE_DATE)
    e.expect("UINT_8", CONVERTED_TYPE_UINT_8)
    e.expect("UINT_16", CONVERTED_TYPE_UINT_16)
    e.expect("UINT_32", CONVERTED_TYPE_UINT_32)
    e.expect("UINT_64", CONVERTED_TYPE_UINT_64)
    e.expect("INT_8", CONVERTED_TYPE_INT_8)
    e.expect("INT_16", CONVERTED_TYPE_INT_16)
    e.expect("JSON", CONVERTED_TYPE_JSON)
    e.expect("BSON", CONVERTED_TYPE_BSON)
    # Annotations no reader branches on by number: nested-type markers, the
    # time and timestamp units (read from the LogicalType union instead),
    # INT_32 / INT_64 (the physical type's own width) and INTERVAL.
    e.expect_rest_unnamed(
        [
            "MAP",
            "MAP_KEY_VALUE",
            "LIST",
            "TIME_MILLIS",
            "TIME_MICROS",
            "TIMESTAMP_MILLIS",
            "TIMESTAMP_MICROS",
            "INT_32",
            "INT_64",
            "INTERVAL",
        ]
    )


def _struct_block(text: String, name: String) raises -> String:
    var open_at = text.find(String("\nstruct ") + name + " {")
    if open_at < 0:
        raise Error("parquet.thrift has no struct " + name)
    var close_at = text.find("\n}", open_at)
    if close_at < 0:
        raise Error("parquet.thrift struct " + name + " is not closed")
    return String(text[byte=open_at:close_at])


def test_statistics_field_9_is_the_spec_nan_count() raises:
    # metadata.mojo's Statistics.hll_registers doc says field 9 is the spec's
    # nan_count, so registers must not be written to or read from it. This
    # keeps that doc true for the pinned spec.
    var block = _struct_block(_read(_THRIFT), "Statistics")
    assert_true(block.find("\n   9: optional i64 nan_count;") >= 0)


def test_page_header_crc_is_optional_standard_crc32() raises:
    # metadata.mojo's PageHeader.crc doc: field 4, optional i32, the standard
    # CRC-32 (gzip's polynomial), not CRC-32C.
    var block = _struct_block(_read(_THRIFT), "PageHeader")
    assert_true(block.find("\n  4: optional i32 crc") >= 0)
    assert_true(block.find("The standard CRC32 algorithm is used (with polynomial 0x04C11DB7") >= 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
