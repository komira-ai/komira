"""Every branch of `hive_partition_parser`: component parsing, the two type
probes, type inference, both public entry points with each of their
refusals, and the two `copy` methods.

Each test names the mutant it catches in its docstring.
"""

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType

from komira_dispatch_scan.hive_partition_parser import (
    HivePartitionLayout,
    _PathPartitions,
    _infer_arrow_type,
    _parse_kv_component,
    _parse_one_path,
    _split_on_slash,
    _substr_bytes,
    _value_parses_as_date32,
    _value_parses_as_int,
    parse_hive_partitions,
    parse_hive_partitions_for_cols,
)


def _paths(a: String, b: String = "", c: String = "") -> List[String]:
    var out = List[String]()
    out.append(a)
    if b.byte_length() > 0:
        out.append(b)
    if c.byte_length() > 0:
        out.append(c)
    return out^


def _raises_hive(paths: List[String]) -> String:
    try:
        var l = parse_hive_partitions(paths)
        _ = l^
    except e:
        return String(e)
    return String("")


# =============================================================================
# Component parsing
# =============================================================================


def test_substr_bytes_keeps_non_ascii_bytes_exactly() raises:
    """MUTANT: rebuild the substring with `chr` per byte and `Zürich` comes
    back as nine bytes, not seven."""
    var s = String("city=Zürich")
    var v = _substr_bytes(s, 5, s.byte_length())
    assert_equal(v, String("Zürich"))
    assert_equal(v.byte_length(), 7)


def test_a_component_is_a_partition_only_with_one_equals_and_a_key() raises:
    """`k=v` parses; no `=`, two `=`, and an empty key do not, and leave the
    outputs untouched; an empty value is a value.
    MUTANT: accept the first `=` regardless of the count and `a=b=c`
    parses as key `a`."""
    var k = String("K0")
    var v = String("V0")
    assert_true(_parse_kv_component(String("year=2031"), k, v))
    assert_equal(k, String("year"))
    assert_equal(v, String("2031"))
    k = String("K0")
    v = String("V0")
    assert_false(_parse_kv_component(String("plain"), k, v))
    assert_false(_parse_kv_component(String("a=b=c"), k, v))
    assert_false(_parse_kv_component(String("=v"), k, v))
    assert_equal(k, String("K0"), "a refused component leaves the key alone")
    assert_equal(v, String("V0"), "a refused component leaves the value alone")
    assert_true(_parse_kv_component(String("k="), k, v))
    assert_equal(k, String("k"))
    assert_equal(v, String(""))


def test_split_keeps_empty_components() raises:
    """MUTANT: skip empties in the split and the leading `/` is lost."""
    var c = _split_on_slash(String("/a//b"))
    assert_equal(len(c), 4)
    assert_equal(c[0], String(""))
    assert_equal(c[1], String("a"))
    assert_equal(c[2], String(""))
    assert_equal(c[3], String("b"))


def test_one_path_reads_directories_only_in_order() raises:
    """Leading and doubled slashes are skipped, plain directories are not
    partitions, and the file name is never a partition even when it holds
    `=`; a path with no slash has no partitions.
    MUTANT: scan every component including the last and the file name
    `x=1.parquet` becomes a third key."""
    var p = _parse_one_path(String("/data//year=2031/plain/m=02/x=1.parquet"))
    assert_equal(len(p.keys), 2)
    assert_equal(p.keys[0], String("year"))
    assert_equal(p.values[0], String("2031"))
    assert_equal(p.keys[1], String("m"))
    assert_equal(p.values[1], String("02"))
    var bare = _parse_one_path(String("k=v"))
    assert_equal(len(bare.keys), 0, "a bare file name has no directories")
    var copied = p.copy()
    assert_equal(len(copied.keys), 2)
    assert_equal(copied.values[1], String("02"))


# =============================================================================
# Type probes
# =============================================================================


def test_the_integer_probe() raises:
    """Signed digit runs of at most 18 digits are integers; an empty value,
    a lone sign, a non-digit and 19 digits are not.
    MUTANT: `n_digits > 19` admits the 19-digit value."""
    assert_true(_value_parses_as_int(String("42")))
    assert_true(_value_parses_as_int(String("-7")))
    assert_true(_value_parses_as_int(String("+7")))
    assert_true(_value_parses_as_int(String("123456789012345678")))
    assert_false(_value_parses_as_int(String("1234567890123456789")))
    assert_false(_value_parses_as_int(String("")))
    assert_false(_value_parses_as_int(String("-")))
    assert_false(_value_parses_as_int(String("+")))
    assert_false(_value_parses_as_int(String("4a")))
    assert_false(_value_parses_as_int(String("/1")), "a byte below '0'")
    assert_false(_value_parses_as_int(String(":1")), "a byte above '9'")


def test_the_date_probe() raises:
    """Exactly `YYYY-MM-DD` with month 01-12 and day 01-31 (the month-length
    bound is the next test).
    MUTANT: `mm > 13` admits month 13."""
    assert_true(_value_parses_as_date32(String("2031-01-31")))
    assert_true(_value_parses_as_date32(String("2031-12-01")))
    assert_false(_value_parses_as_date32(String("2031-1-31")), "length")
    assert_false(_value_parses_as_date32(String("2031/01/31")), "first dash")
    assert_false(_value_parses_as_date32(String("2031-01/31")), "second dash")
    assert_false(_value_parses_as_date32(String("20a1-01-31")), "a letter")
    assert_false(_value_parses_as_date32(String("2031-0/-31")), "below '0'")
    assert_false(_value_parses_as_date32(String("2031-00-10")), "month 0")
    assert_false(_value_parses_as_date32(String("2031-13-10")), "month 13")
    assert_false(_value_parses_as_date32(String("2031-01-00")), "day 0")
    assert_false(_value_parses_as_date32(String("2031-01-32")), "day 32")


def _vals(a: String, b: String = "") -> List[String]:
    var out = List[String]()
    out.append(a)
    if b.byte_length() > 0:
        out.append(b)
    return out^


def test_the_date_probe_rejects_a_day_past_month_end() raises:
    """A day past its month's last day is not a date: 29 February outside a
    leap year (the century rule included), 30 February, 31 in a 30-day
    month (komira-ai/komira#1110). A column of such values is STRING.
    MUTANT: dropping the month-length check admits all of these; treating
    every year divisible by 4 as leap admits 2100-02-29."""
    var leap = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    var common = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    for m in range(12):
        var mm = String(m + 1) if m + 1 >= 10 else "0" + String(m + 1)
        assert_true(_value_parses_as_date32("2028-" + mm + "-" + String(leap[m])))
        assert_true(_value_parses_as_date32("2027-" + mm + "-" + String(common[m])))
        if leap[m] < 31:
            var ld = "2028-" + mm + "-" + String(leap[m] + 1)
            assert_false(_value_parses_as_date32(ld), ld)
        if common[m] < 31:
            var cd = "2027-" + mm + "-" + String(common[m] + 1)
            assert_false(_value_parses_as_date32(cd), cd)
    assert_true(_value_parses_as_date32(String("2000-02-29")), "2000 is leap")
    assert_false(_value_parses_as_date32(String("1900-02-29")), "1900")
    assert_false(_value_parses_as_date32(String("2100-02-29")), "2100")
    assert_true(_infer_arrow_type(_vals("2028-02-28", "2028-02-30")) == ArrowType.STRING)


def test_type_inference_order_is_integer_then_date_then_string() raises:
    """An empty set is STRING; all integers are INT64, all dates DATE32, and
    a mix is STRING, including when the loop stops early.
    MUTANT: drop the `if all_date` return and the date column reads
    STRING."""
    assert_true(_infer_arrow_type(List[String]()) == ArrowType.STRING)
    assert_true(_infer_arrow_type(_vals(String("1"), String("-2"))) == ArrowType.INT64)
    assert_true(
        _infer_arrow_type(_vals(String("2031-01-01"), String("2031-02-03")))
        == ArrowType.DATE32
    )
    assert_true(_infer_arrow_type(_vals(String("1"), String("x"))) == ArrowType.STRING)
    assert_true(
        _infer_arrow_type(_vals(String("x"), String("2031-01-01")))
        == ArrowType.STRING,
        "the loop stops at the first value that is neither",
    )
    assert_true(
        _infer_arrow_type(_vals(String("2031-01-01"), String("7")))
        == ArrowType.STRING,
        "a date then an integer is neither type",
    )


# =============================================================================
# parse_hive_partitions
# =============================================================================


def test_a_consistent_layout_parses_with_inferred_types() raises:
    """Two keys over three paths: `year` is INT64, `day` is DATE32, values
    stay raw text per path, partition columns are not nullable, and a copy
    is equal.
    MUTANT: collect values per path only and the type of `day` is inferred
    from nothing."""
    var l = parse_hive_partitions(
        _paths(
            String("d/year=2030/day=2030-01-02/p0.parquet"),
            String("d/year=2030/day=2030-02-03/p1.parquet"),
            String("d/year=2031/day=2031-01-04/p2.parquet"),
        )
    )
    assert_equal(l.num_cols(), 2)
    assert_equal(l.cols[0].name, String("year"))
    assert_true(l.cols[0].arrow_type == ArrowType.INT64)
    assert_equal(l.cols[1].name, String("day"))
    assert_true(l.cols[1].arrow_type == ArrowType.DATE32)
    assert_false(l.cols[0].nullable)
    assert_equal(len(l.values), 3)
    assert_equal(l.values[2][0], String("2031"))
    assert_equal(l.values[1][1], String("2030-02-03"))
    var c = l.copy()
    assert_equal(c.num_cols(), 2)
    assert_equal(c.cols[1].name, String("day"))
    assert_equal(c.values[2][1], String("2031-01-04"))


def test_no_partitions_anywhere_is_an_empty_layout() raises:
    """MUTANT: raise whenever the first path has no keys and this plain
    multi-file scan is refused."""
    var l = parse_hive_partitions(_paths(String("a/x.parquet"), String("b/y.parquet")))
    assert_equal(l.num_cols(), 0)
    assert_equal(len(l.values), 0)


def test_every_mixed_layout_is_refused() raises:
    """An empty list; a first path without keys and a later one with; a
    later path with a different key count; and the same count with a
    different name or order.
    MUTANT: compare only key counts and the renamed key passes."""
    var msg = _raises_hive(List[String]())
    assert_true("empty path list" in msg, msg)
    msg = _raises_hive(_paths(String("a/x.parquet"), String("k=1/y.parquet")))
    assert_true("has no partition columns but path[1]" in msg, msg)
    msg = _raises_hive(_paths(String("k=1/x.parquet"), String("k=1/j=2/y.parquet")))
    assert_true("has 1 partition columns but path[1]" in msg, msg)
    msg = _raises_hive(_paths(String("k=1/x.parquet"), String("q=1/y.parquet")))
    assert_true("column #0 is 'k' but path[1]" in msg, msg)
    msg = _raises_hive(
        _paths(String("a=1/b=2/x.parquet"), String("b=2/a=1/y.parquet"))
    )
    assert_true("column #0 is 'a'" in msg, msg)


# =============================================================================
# parse_hive_partitions_for_cols
# =============================================================================


def test_requested_columns_follow_the_request_order() raises:
    """Columns come out in the requested order, keys not requested are
    ignored, and types are inferred per requested column.
    MUTANT: emit columns in path order and `m` comes before `year`."""
    var req = List[String]()
    req.append(String("m"))
    req.append(String("year"))
    var l = parse_hive_partitions_for_cols(
        _paths(String("year=2030/m=x/z=9/a.parquet"), String("year=2031/m=y/z=8/b.parquet")),
        req,
    )
    assert_equal(l.num_cols(), 2)
    assert_equal(l.cols[0].name, String("m"))
    assert_true(l.cols[0].arrow_type == ArrowType.STRING)
    assert_equal(l.cols[1].name, String("year"))
    assert_true(l.cols[1].arrow_type == ArrowType.INT64)
    assert_equal(l.values[1][0], String("y"))
    assert_equal(l.values[1][1], String("2031"))


def test_requested_columns_refusals_and_the_empty_request() raises:
    """An empty path list raises; an empty request is an empty layout; a
    requested column missing from one path raises and names it.
    MUTANT: skip a path that lacks the column instead of raising and the
    layout has fewer rows than paths."""
    var req = List[String]()
    req.append(String("year"))
    var msg = String("")
    try:
        var l = parse_hive_partitions_for_cols(List[String](), req)
        _ = l^
    except e:
        msg = String(e)
    assert_true("empty path list" in msg, msg)
    var empty = parse_hive_partitions_for_cols(
        _paths(String("year=1/a.parquet")), List[String]()
    )
    assert_equal(empty.num_cols(), 0)
    msg = String("")
    try:
        var l2 = parse_hive_partitions_for_cols(
            _paths(String("year=1/a.parquet"), String("m=1/b.parquet")), req
        )
        _ = l2^
    except e:
        msg = String(e)
    assert_true("column 'year' not found in path 'm=1/b.parquet'" in msg, msg)


def test_path_partitions_struct_holds_its_pairs() raises:
    """MUTANT: none; covers `_PathPartitions.__init__` and `copy` directly."""
    var keys = List[String]()
    keys.append(String("k"))
    var vals = List[String]()
    vals.append(String("v"))
    var p = _PathPartitions(keys^, vals^)
    var c = p.copy()
    assert_equal(c.keys[0], String("k"))
    assert_equal(c.values[0], String("v"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
