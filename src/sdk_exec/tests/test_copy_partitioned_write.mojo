# =============================================================================
# engine_write_partitioned: the directories, files and refusals of a
# partitioned COPY, driven with hand-built batches
# =============================================================================
#
# What each test proves:
#   * test_rows_are_grouped_by_directory_in_result_order: one file per
#     distinct value, each holding its rows in the result's order and only
#     the columns that are not partition columns; NULL and the string
#     `__HIVE_DEFAULT_PARTITION__` share the NULL directory, as DuckDB writes
#     them; the answer is every row; a target that is already an empty
#     directory is written into. Catches rows of one value split over
#     two files, rows reordered within a file, and the partition column
#     written into the file.
#   * test_every_partition_type_names_its_directory_as_duckdb_casts_it: for
#     BIGINT, INTEGER, SMALLINT, TINYINT, UBIGINT, UINTEGER, USMALLINT,
#     UTINYINT, BOOLEAN, VARCHAR, a large string, a dictionary-encoded
#     string, DECIMAL and DATE, the directory names are the values' VARCHAR
#     text (extremes, a negative number, a DECIMAL's scale digits, a date as
#     `YYYY-MM-DD`), URL-escaped (a quote, a comma, a carriage return and a
#     space), the empty string an empty name, NULL
#     `__HIVE_DEFAULT_PARTITION__`. Catches a value written as its storage
#     (a day count, an unscaled decimal, a dictionary code) and a byte left
#     unescaped.
#   * test_partition_value_segment_and_file_name: the escaping of NULL, the
#     empty string, `__HIVE_DEFAULT_PARTITION__`, `/`, `=`, `%`, a multi-byte
#     character and the kept bytes `- _ . ~`; the file is `data_0.parquet`,
#     `data_0.csv`, `data_0.csv.gz` or `data_0.csv.zst`.
#   * test_refusals: a FLOAT64 partition column is COPY_TYPE_UNSUPPORTED and
#     two written CSV columns of one name COPY_DUPLICATE_COLUMN, each with
#     its whole message and with no directory made; a value whose directory
#     name the file system refuses (longer than a name may be) is
#     STORAGE_IO (the target directory itself is made first).
#   * test_the_target_check: a file at the target and a directory holding
#     only a hidden file are COPY_TARGET_EXISTS, a missing parent directory
#     STORAGE_NOT_FOUND, each with its whole message; an empty directory, a
#     path whose parent exists (with or without a trailing `/`) and a bare
#     name in the working directory pass.

from std.os import listdir, makedirs
from std.os.path import exists, isdir
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from arrow.arrow_types import ArrowType
from arrow.boolean_array import BooleanArray
from arrow.column import Column
from arrow.decimal_array import Decimal128Array
from arrow.dictionary_array import StringDictionaryArray
from arrow.large_string_array import LargeStringArray
from arrow.primitive_array import PrimitiveArray
from arrow.record_batch import RecordBatch, RecordBatchBuilder
from arrow.schema import Field, SchemaBuilder
from arrow.string_array import StringArray
from arrow.write_target import (
    WCOMP_GZIP,
    WCOMP_SNAPPY,
    WCOMP_UNCOMPRESSED,
    WCOMP_ZSTD,
    WFMT_CSV,
    WFMT_PARQUET,
)
from byte_buffer.heap_region import HeapRegion
from fs.atomic_write import STORAGE_IO, STORAGE_NOT_FOUND
from runtime_paths import test_tmpdir
from sdk_exec.engine_write import COPY_DUPLICATE_COLUMN, COPY_TYPE_UNSUPPORTED
from sdk_exec.engine_write_partitioned import (
    COPY_TARGET_EXISTS,
    check_partitioned_target,
    partition_file_name,
    partition_value_segment,
    write_partitioned_result,
)


def _dir(name: String) raises -> String:
    return test_tmpdir() + "/partitioned_" + name


def _tree(root: String, prefix: String, mut out: List[String]) raises:
    var names = listdir(root)
    for i in range(len(names)):
        var path = root + "/" + names[i]
        if isdir(path):
            _tree(path, prefix + names[i] + "/", out)
        else:
            out.append(prefix + names[i])


def _files(root: String) raises -> String:
    """Every file under `root`, relative to it, sorted, one per line."""
    var out = List[String]()
    _tree(root, String(""), out)
    sort(out)
    var s = String("")
    for i in range(len(out)):
        s += out[i] + "\n"
    return s^


def _read(path: String) raises -> String:
    with open(path, "r") as f:
        return f.read()


def _one(name: String) -> List[String]:
    var l = List[String]()
    l.append(name)
    return l^


def _prim[
    dt: DType
](a: Scalar[dt], c: Scalar[dt], at: ArrowType) raises -> Column[HeapRegion]:
    """Rows: a, NULL, c."""
    var arr = PrimitiveArray[dt].allocate_nullable(3)
    arr.set(0, a)
    arr.set(1, Scalar[dt](0))
    arr.set(2, c)
    arr._set_null(1)
    return Column.from_primitive_with_arrow_type[dt](arr^, at)


def _middle_null() -> List[Bool]:
    var v = List[Bool]()
    v.append(True)
    v.append(False)
    v.append(True)
    return v^


def _with_v(name: String, var col: Column[HeapRegion], field: Field) raises -> RecordBatch:
    """The column `col` (field `field`) and a BIGINT `v` 0, 1, 2."""
    var v = PrimitiveArray[DType.int64].allocate(3)
    for i in range(3):
        v.set(i, Int64(i))
    var sb = SchemaBuilder()
    sb.add_field(field.copy())
    sb.add_field(Field("v", ArrowType.INT64, False))
    var rb = RecordBatchBuilder()
    rb.add_column(col^)
    rb.add_column(Column.from_primitive[DType.int64](v^))
    return rb.build(sb.build())


def _expect_tree(name: String, var batch: RecordBatch, a: String, c: String) raises:
    """Partition `batch` by its column `name` into a fresh directory and
    hold the tree to the directories `a`, NULL and `c`."""
    var d = _dir("type_" + name)
    assert_equal(
        write_partitioned_result(batch^, d, WFMT_PARQUET, WCOMP_SNAPPY, _one(name)), 3
    )
    var want = List[String]()
    want.append(name + "=" + a + "/data_0.parquet")
    want.append(name + "=__HIVE_DEFAULT_PARTITION__/data_0.parquet")
    want.append(name + "=" + c + "/data_0.parquet")
    sort(want)
    var s = String("")
    for i in range(len(want)):
        s += want[i] + "\n"
    assert_equal(_files(d), s, name)


def _int_tree[dt: DType](name: String, at: ArrowType, a: Scalar[dt], c: Scalar[dt]) raises:
    _expect_tree(
        name,
        _with_v(name, _prim[dt](a, c, at), Field(name, at, True)),
        String(a),
        String(c),
    )


def test_rows_are_grouped_by_directory_in_result_order() raises:
    var ks = List[String]()
    ks.append("b")
    ks.append("a")
    ks.append("b")
    ks.append("")
    ks.append("__HIVE_DEFAULT_PARTITION__")
    var valid = List[Bool]()
    for i in range(5):
        valid.append(i != 3)
    var v = PrimitiveArray[DType.int64].allocate(5)
    for i in range(5):
        v.set(i, Int64(i))
    var sb = SchemaBuilder()
    sb.add_field(Field("v", ArrowType.INT64, False))
    sb.add_field(Field("k", ArrowType.STRING, True))
    var rb = RecordBatchBuilder()
    rb.add_column(Column.from_primitive[DType.int64](v^))
    rb.add_column(Column.from_string(StringArray.from_strings_with_validity(ks, valid)))
    var d = _dir("grouped")
    makedirs(d, exist_ok=True)
    assert_equal(
        write_partitioned_result(
            rb.build(sb.build()), d, WFMT_CSV, WCOMP_UNCOMPRESSED, _one("k")
        ),
        5,
    )
    assert_equal(
        _files(d),
        "k=__HIVE_DEFAULT_PARTITION__/data_0.csv\nk=a/data_0.csv\nk=b/data_0.csv\n",
    )
    assert_equal(_read(d + "/k=b/data_0.csv"), "v\n0\n2\n")
    assert_equal(_read(d + "/k=a/data_0.csv"), "v\n1\n")
    assert_equal(_read(d + "/k=__HIVE_DEFAULT_PARTITION__/data_0.csv"), "v\n3\n4\n")


def test_every_partition_type_names_its_directory_as_duckdb_casts_it() raises:
    _int_tree[DType.int64]("i64", ArrowType.INT64, -5, 9223372036854775807)
    _int_tree[DType.int32]("i32", ArrowType.INT32, -7, 2147483647)
    _int_tree[DType.int16]("i16", ArrowType.INT16, -300, 32767)
    _int_tree[DType.int8]("i8", ArrowType.INT8, -128, 127)
    _int_tree[DType.uint64]("u64", ArrowType.UINT64, 18446744073709551615, 0)
    _int_tree[DType.uint32]("u32", ArrowType.UINT32, 4294967295, 1)
    _int_tree[DType.uint16]("u16", ArrowType.UINT16, 65535, 2)
    _int_tree[DType.uint8]("u8", ArrowType.UINT8, 255, 3)
    var b = BooleanArray.allocate_nullable(3)
    b.set(0, True)
    b.set(2, False)
    b._set_null(1)
    _expect_tree(
        "b",
        _with_v("b", Column.from_boolean(b^), Field("b", ArrowType.BOOL, True)),
        "true",
        "false",
    )
    var sv = List[String]()
    sv.append('a"b c')
    sv.append("")
    sv.append("")
    _expect_tree(
        "s",
        _with_v(
            "s",
            Column.from_string(StringArray.from_strings_with_validity(sv, _middle_null())),
            Field("s", ArrowType.STRING, True),
        ),
        "a%22b%20c",
        "",
    )
    var lv = List[String]()
    lv.append("L,M")
    lv.append("")
    lv.append("cr\r")
    _expect_tree(
        "ls",
        _with_v(
            "ls",
            Column.from_large_string(
                LargeStringArray.from_strings_with_validity(lv, _middle_null())
            ),
            Field("ls", ArrowType.LARGE_STRING, True),
        ),
        "L%2CM",
        "cr%0D",
    )
    var idx = PrimitiveArray[DType.int32].allocate_nullable(3)
    idx.set(0, Int32(1))
    idx.set(1, Int32(0))
    idx.set(2, Int32(0))
    idx._set_null(1)
    var words = List[String]()
    words.append("y")
    words.append("x")
    _expect_tree(
        "dict",
        _with_v(
            "dict",
            Column.from_dictionary(
                StringDictionaryArray.from_parts(idx^, StringArray.from_strings(words))
            ),
            Field("dict", ArrowType.DICTIONARY, True),
        ),
        "x",
        "y",
    )
    var dec = Decimal128Array.allocate_nullable(3, 10, 2)
    dec.set_raw(0, Int64(250), Int64(0))
    dec.set_raw(2, Int64(-5), Int64(-1))
    dec.set_null(1)
    _expect_tree(
        "dec",
        _with_v("dec", Column.from_decimal128(dec^), Field.decimal128("dec", 10, 2, True)),
        "2.50",
        "-0.05",
    )
    _expect_tree(
        "d",
        _with_v(
            "d",
            _prim[DType.int32](20826, 21000, ArrowType.DATE32),
            Field("d", ArrowType.DATE32, True),
        ),
        "2027-01-08",
        "2027-07-01",
    )


def test_partition_value_segment_and_file_name() raises:
    assert_equal(partition_value_segment(None), "__HIVE_DEFAULT_PARTITION__")
    assert_equal(partition_value_segment(String("")), "")
    assert_equal(
        partition_value_segment(String("__HIVE_DEFAULT_PARTITION__")),
        "__HIVE_DEFAULT_PARTITION__",
    )
    assert_equal(partition_value_segment(String("a/b=c%d")), "a%2Fb%3Dc%25d")
    assert_equal(partition_value_segment(String("é")), "%C3%A9")
    assert_equal(partition_value_segment(String("a-b_c.d~e")), "a-b_c.d~e")
    assert_equal(partition_file_name(WFMT_PARQUET, WCOMP_ZSTD), "data_0.parquet")
    assert_equal(partition_file_name(WFMT_CSV, WCOMP_UNCOMPRESSED), "data_0.csv")
    assert_equal(partition_file_name(WFMT_CSV, WCOMP_GZIP), "data_0.csv.gz")
    assert_equal(partition_file_name(WFMT_CSV, WCOMP_ZSTD), "data_0.csv.zst")


def _refused(var batch: RecordBatch, d: String, fmt: UInt8, by: String) raises -> String:
    try:
        _ = write_partitioned_result(batch^, d, fmt, WCOMP_UNCOMPRESSED, _one(by))
    except e:
        return String(e)
    raise Error("written, expected a refusal: " + d)


def test_refusals() raises:
    var f = _dir("float")
    assert_equal(
        _refused(
            _with_v(
                "f",
                _prim[DType.float64](1.5, 2.5, ArrowType.FLOAT64),
                Field("f", ArrowType.FLOAT64, True),
            ),
            f,
            WFMT_PARQUET,
            "f",
        ),
        String(COPY_TYPE_UNSUPPORTED) + ": COPY ... TO '" + f
        + "' (PARTITION_BY (f)): column 'f' has type " + String(ArrowType.FLOAT64)
        + ", which is not written as a partition directory name yet",
    )
    assert_false(exists(f))
    var dup = _dir("duplicate")
    var k = PrimitiveArray[DType.int64].allocate(1)
    k.set(0, Int64(1))
    var a = PrimitiveArray[DType.int64].allocate(1)
    a.set(0, Int64(2))
    var b = PrimitiveArray[DType.int64].allocate(1)
    b.set(0, Int64(3))
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, False))
    sb.add_field(Field("v", ArrowType.INT64, False))
    sb.add_field(Field("v", ArrowType.INT64, False))
    var rb = RecordBatchBuilder()
    rb.add_column(Column.from_primitive[DType.int64](k^))
    rb.add_column(Column.from_primitive[DType.int64](a^))
    rb.add_column(Column.from_primitive[DType.int64](b^))
    assert_equal(
        _refused(rb.build(sb.build()), dup, WFMT_CSV, "k"),
        String(COPY_DUPLICATE_COLUMN) + ": COPY ... TO '" + dup
        + "': the result has two columns named 'v'; give each column of a CSV"
        " file its own name (AS)",
    )
    assert_false(exists(dup))
    var long = _dir("long_name")
    var lv = List[String]()
    lv.append(String("x") * 300)
    var valid = List[Bool]()
    valid.append(True)
    var v = PrimitiveArray[DType.int64].allocate(1)
    v.set(0, Int64(0))
    var lsb = SchemaBuilder()
    lsb.add_field(Field("k", ArrowType.STRING, True))
    lsb.add_field(Field("v", ArrowType.INT64, False))
    var lrb = RecordBatchBuilder()
    lrb.add_column(Column.from_string(StringArray.from_strings_with_validity(lv, valid)))
    lrb.add_column(Column.from_primitive[DType.int64](v^))
    var msg = _refused(lrb.build(lsb.build()), long, WFMT_PARQUET, "k")
    assert_true(
        msg.startswith(
            String(STORAGE_IO) + ": COPY ... TO '" + long
            + "' (PARTITION_BY (k)): a directory cannot be made: "
        ),
        msg,
    )


def _target_refusal(dest: String) raises -> String:
    try:
        check_partitioned_target(dest, _one("k"))
    except e:
        return String(e)
    raise Error("passed, expected a refusal: " + dest)


def test_the_target_check() raises:
    var root = _dir("targets")
    makedirs(root + "/empty", exist_ok=True)
    makedirs(root + "/hidden", exist_ok=True)
    with open(root + "/hidden/.keep", "w") as f:
        f.write("")
    with open(root + "/file", "w") as f:
        f.write("x")
    assert_equal(
        _target_refusal(root + "/file"),
        String(COPY_TARGET_EXISTS) + ": COPY ... TO '" + root
        + "/file' (PARTITION_BY (k)): it is a file, not a directory; OVERWRITE"
        " is not supported",
    )
    assert_equal(
        _target_refusal(root + "/hidden/"),
        String(COPY_TARGET_EXISTS) + ": COPY ... TO '" + root
        + "/hidden/' (PARTITION_BY (k)): the directory is not empty;"
        " OVERWRITE, OVERWRITE_OR_IGNORE and APPEND are not supported",
    )
    assert_equal(
        _target_refusal(root + "/absent/out"),
        String(STORAGE_NOT_FOUND) + ": COPY ... TO '" + root
        + "/absent/out' (PARTITION_BY (k)): the directory '" + root
        + "/absent' does not exist",
    )
    check_partitioned_target(root + "/empty", _one("k"))
    check_partitioned_target(root + "/new", _one("k"))
    check_partitioned_target(root + "/new/", _one("k"))
    # A bare name is made in the working directory, which exists.
    check_partitioned_target("komira_partitioned_target_never_made", _one("k"))
    assert_false(exists(root + "/new"))
    assert_true(isdir(root + "/empty"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
