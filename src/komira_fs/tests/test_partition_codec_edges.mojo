# =============================================================================
# test_partition_codec_edges.mojo
# =============================================================================
# The edges of the Hive partition codec and the prune fold that the
# round-trip tests do not reach:
#
#   * `%xx` escapes decode with lowercase hex as with uppercase.
#   * the komira writer's per-byte escape rule equals `encode_partition_value`.
#   * `key=value` parsing drops a component holding `?` or a control byte or
#     with an empty key,
#     and a path with no `/` has no partition components.
#   * the type probe: no values is a string; a bare sign is not an integer;
#     a date with a wrong separator, a non-digit or a day outside 1..31 is not
#     a date; month-end days of a leap and a common year are dates; the
#     timestamp shape `YYYY-MM-DD HH:MM:SS` and each way it can be wrong
#     (separator, digit, month, day, hour, minute, second), at the bounds.
#   * `_compare_values`: every operator, numeric for INT64 (zero-padded
#     values compare equal) and lexical for strings; an unknown operator
#     never holds.
#   * `_parse_int_or_zero`: signs, empty, garbage.
#   * the fold: an opaque constraint keeps a file; a constraint on a column
#     the path lacks drops it.
#   * schema inference: no paths, a first path with no partition, and a value
#     with a malformed escape (probed raw, as a string).
#   * an empty base prefix derives the root prefix `/`.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_fs.file_discovery import GlobDiscoveryOptions
from komira_fs.partition_codec import (
    HIVE_WRITER_KOMIRA,
    _escape_for_writer,
    encode_partition_value,
    parse_key_value_segments,
    parse_partition_value,
    probe_partition_type,
)
from komira_fs.pruned_hive_discovery import (
    PartitionConstraint,
    PartitionPredicate,
    PrunedHiveDiscovery,
    evaluate_partition_prefix,
    _OP_EQ,
    _OP_NE,
    _OP_LT,
    _OP_LE,
    _OP_GT,
    _OP_GE,
    _compare_values,
    _infer_schema_from_paths,
    _parse_int_or_zero,
    _type_for_col,
)


def _one(v: String) -> List[String]:
    var out = List[String]()
    out.append(v)
    return out^


def _probe(v: String) -> ArrowType:
    return probe_partition_type(_one(v))


def test_unescape_lowercase_hex() raises:
    assert_equal(parse_partition_value("Z%c3%bcrich", ArrowType.STRING), "Zürich")
    assert_equal(parse_partition_value("a%2fb%3a", ArrowType.STRING), "a/b:")


def test_komira_writer_rule_is_encode() raises:
    var vals = List[String]()
    vals.append("a b:c/d=e")
    vals.append("Zürich~x.y_z-0")
    vals.append("100%")
    for i in range(len(vals)):
        assert_equal(
            _escape_for_writer(vals[i], HIVE_WRITER_KOMIRA),
            encode_partition_value(vals[i], ArrowType.STRING),
        )


def test_kv_drops_disqualified_components() raises:
    var keys = List[String]()
    var vals = List[String]()
    parse_key_value_segments("t/a=1?/b=2/=3/d=\t/c=4/f.parquet", keys, vals)
    assert_equal(len(keys), 2)
    assert_equal(keys[0], "b")
    assert_equal(vals[0], "2")
    assert_equal(keys[1], "c")
    assert_equal(vals[1], "4")


def test_kv_no_slash_has_no_partitions() raises:
    var keys = List[String]()
    var vals = List[String]()
    keys.append("stale")
    vals.append("stale")
    parse_key_value_segments("a=1", keys, vals)
    assert_equal(len(keys), 0)
    assert_equal(len(vals), 0)


def test_probe_empty_and_sign_only() raises:
    assert_true(probe_partition_type(List[String]()) == ArrowType.STRING)
    assert_true(_probe("-") == ArrowType.STRING)
    assert_true(_probe("+") == ArrowType.STRING)
    assert_true(_probe("+5") == ArrowType.INT64)
    assert_true(_probe("-5") == ArrowType.INT64)


def test_probe_date_rejections() raises:
    assert_true(_probe("2028/01/01") == ArrowType.STRING)  # separator
    assert_true(_probe("2028-01x01") == ArrowType.STRING)  # second separator
    assert_true(_probe("2028-0a-01") == ArrowType.STRING)  # digit
    # Bytes just outside '0'..'9' whose arithmetic value would make a valid
    # day (':' - '0' = 10, '/' - '0' = -1): rejected by the digit check, not
    # by the range check.
    assert_true(_probe("2028-01-1:") == ArrowType.STRING)
    assert_true(_probe("2028-01-1/") == ArrowType.STRING)
    assert_true(_probe("2028-01-32") == ArrowType.STRING)  # day > 31
    assert_true(_probe("2028-01-00") == ArrowType.STRING)  # day 0
    assert_true(_probe("2028-13-01") == ArrowType.STRING)  # month 13
    assert_true(_probe("2028-00-01") == ArrowType.STRING)  # month 0


def test_probe_month_end_sweep() raises:
    """The last day of every month of a leap year (2028) and of a common year
    (2027) is a date."""
    var leap = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    var common = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    for m in range(12):
        var mm = String(m + 1) if m + 1 >= 10 else "0" + String(m + 1)
        assert_true(_probe("2028-" + mm + "-" + String(leap[m])) == ArrowType.DATE32)
        assert_true(_probe("2027-" + mm + "-" + String(common[m])) == ArrowType.DATE32)
        assert_true(_probe("2027-" + mm + "-01") == ArrowType.DATE32)


def test_probe_timestamp() raises:
    assert_true(_probe("2028-01-02 03:04:05") == ArrowType.TIMESTAMP)
    assert_true(_probe("2028-12-31 23:59:59") == ArrowType.TIMESTAMP)
    assert_true(_probe("2028-01-01 00:00:00") == ArrowType.TIMESTAMP)
    var both = List[String]()
    both.append("2028-01-01 00:00:00")
    both.append("2029-06-30 12:30:45")
    assert_true(probe_partition_type(both) == ArrowType.TIMESTAMP)
    # A date among timestamps is neither.
    both.append("2029-06-30")
    assert_true(probe_partition_type(both) == ArrowType.STRING)


def test_probe_timestamp_rejections() raises:
    assert_true(_probe("2028/01-02 03:04:05") == ArrowType.STRING)  # date sep
    assert_true(_probe("2028-01-0x 03:04:05") == ArrowType.STRING)  # date digit
    assert_true(_probe("2028-01-1: 03:04:05") == ArrowType.STRING)  # ':' = 10
    assert_true(_probe("2028-01-1/ 03:04:05") == ArrowType.STRING)  # '/' = -1
    assert_true(_probe("2028-01-02T03:04:05") == ArrowType.STRING)  # T
    assert_true(_probe("2028-01-02 03-04:05") == ArrowType.STRING)  # time sep
    assert_true(_probe("2028-01-02 03:04:0x") == ArrowType.STRING)  # time digit
    assert_true(_probe("2028-01-02 03:04:1:") == ArrowType.STRING)  # ':' = 10
    assert_true(_probe("2028-01-02 03:04:1/") == ArrowType.STRING)  # '/' = -1
    assert_true(_probe("2028-13-02 03:04:05") == ArrowType.STRING)  # month
    assert_true(_probe("2028-00-02 03:04:05") == ArrowType.STRING)  # month 0
    assert_true(_probe("2028-01-32 03:04:05") == ArrowType.STRING)  # day
    assert_true(_probe("2028-01-00 03:04:05") == ArrowType.STRING)  # day 0
    assert_true(_probe("2028-01-02 24:00:00") == ArrowType.STRING)  # hour
    assert_true(_probe("2028-01-02 23:60:00") == ArrowType.STRING)  # minute
    assert_true(_probe("2028-01-02 23:59:60") == ArrowType.STRING)  # second


def test_compare_values_int64() raises:
    var t = ArrowType.INT64
    # 02 vs 2: numerically equal.
    assert_true(_compare_values("02", _OP_EQ, "2", t))
    assert_false(_compare_values("3", _OP_EQ, "2", t))
    assert_true(_compare_values("3", _OP_NE, "2", t))
    assert_false(_compare_values("02", _OP_NE, "2", t))
    assert_true(_compare_values("1", _OP_LT, "2", t))
    assert_false(_compare_values("2", _OP_LT, "2", t))
    assert_true(_compare_values("2", _OP_LE, "02", t))
    assert_false(_compare_values("3", _OP_LE, "2", t))
    assert_true(_compare_values("10", _OP_GT, "9", t))  # numeric, not lexical
    assert_false(_compare_values("2", _OP_GT, "2", t))
    assert_true(_compare_values("2", _OP_GE, "2", t))
    assert_false(_compare_values("1", _OP_GE, "2", t))
    assert_false(_compare_values("1", 99, "1", t))


def test_compare_values_string() raises:
    var t = ArrowType.STRING
    assert_true(_compare_values("b", _OP_EQ, "b", t))
    assert_false(_compare_values("02", _OP_EQ, "2", t))  # text, not number
    assert_true(_compare_values("a", _OP_NE, "b", t))
    assert_false(_compare_values("b", _OP_NE, "b", t))
    assert_true(_compare_values("a", _OP_LT, "b", t))
    assert_false(_compare_values("b", _OP_LT, "b", t))
    assert_true(_compare_values("b", _OP_LE, "b", t))
    assert_false(_compare_values("c", _OP_LE, "b", t))
    assert_true(_compare_values("9", _OP_GT, "10", t))  # lexical
    assert_false(_compare_values("b", _OP_GT, "b", t))
    assert_true(_compare_values("b", _OP_GE, "b", t))
    assert_false(_compare_values("a", _OP_GE, "b", t))
    assert_false(_compare_values("a", 99, "a", t))


def test_parse_int_or_zero() raises:
    assert_equal(_parse_int_or_zero(""), 0)
    assert_equal(_parse_int_or_zero("12x"), 0)
    assert_equal(_parse_int_or_zero("+7"), 7)
    assert_equal(_parse_int_or_zero("-12"), -12)
    assert_equal(_parse_int_or_zero("007"), 7)


def _listing() -> List[String]:
    var l = List[String]()
    l.append("t/year=2028/a.parquet")
    l.append("t/year=2029/b.parquet")
    return l^


def _year() -> List[String]:
    return _one("year")


def _int64() -> List[ArrowType]:
    var t = List[ArrowType]()
    t.append(ArrowType.INT64)
    return t^


def test_fold_other_keeps_files() raises:
    var cs = List[PartitionConstraint]()
    cs.append(PartitionConstraint.other("year"))
    var disc = PrunedHiveDiscovery.from_listing(
        "t",
        _listing(),
        _year(),
        _int64(),
        PartitionPredicate(constraints=cs^),
        GlobDiscoveryOptions.default(),
    )
    assert_equal(disc.num_paths(), 2)


def test_fold_missing_column_drops_file() raises:
    var cs = List[PartitionConstraint]()
    cs.append(PartitionConstraint.eq("month", "1", ArrowType.INT64))
    var disc = PrunedHiveDiscovery.from_listing(
        "t",
        _listing(),
        _year(),
        _int64(),
        PartitionPredicate(constraints=cs^),
        GlobDiscoveryOptions(allow_empty_glob=True),
    )
    assert_equal(disc.num_paths(), 0)


def test_fold_compare_ops_end_to_end() raises:
    """GE and LT on an INT64 column through `from_listing`."""
    var cs = List[PartitionConstraint]()
    cs.append(PartitionConstraint.compare("year", _OP_GE, "2029", ArrowType.INT64))
    var ge = PrunedHiveDiscovery.from_listing(
        "t", _listing(), _year(), _int64(),
        PartitionPredicate(constraints=cs^), GlobDiscoveryOptions.default(),
    )
    assert_equal(ge.num_paths(), 1)
    assert_equal(ge.path_at(0), "t/year=2029/b.parquet")
    var cs2 = List[PartitionConstraint]()
    cs2.append(PartitionConstraint.compare("year", _OP_LT, "2029", ArrowType.INT64))
    var lt = PrunedHiveDiscovery.from_listing(
        "t", _listing(), _year(), _int64(),
        PartitionPredicate(constraints=cs2^), GlobDiscoveryOptions.default(),
    )
    assert_equal(lt.num_paths(), 1)
    assert_equal(lt.path_at(0), "t/year=2028/a.parquet")


def test_type_for_col() raises:
    var names = List[String]()
    names.append("year")
    names.append("day")
    var types = List[ArrowType]()
    types.append(ArrowType.INT64)
    types.append(ArrowType.DATE32)
    assert_true(_type_for_col(names, types, "day") == ArrowType.DATE32)
    assert_true(_type_for_col(names, types, "year") == ArrowType.INT64)
    assert_true(_type_for_col(names, types, "other") == ArrowType.STRING)


def test_infer_schema_edges() raises:
    var names = List[String]()
    var types = List[ArrowType]()
    names.append("stale")
    types.append(ArrowType.INT64)
    _infer_schema_from_paths(List[String](), names, types)
    assert_equal(len(names), 0)
    assert_equal(len(types), 0)
    # The first path names no partition: nothing is inferred.
    var p = List[String]()
    p.append("a/plain.parquet")
    p.append("a/k=1/f.parquet")
    _infer_schema_from_paths(p, names, types)
    assert_equal(len(names), 0)
    # A malformed escape is probed as its raw text: the column is a string
    # even though the other value is an integer.
    var q = List[String]()
    q.append("k=5/f.parquet")
    q.append("k=%zz/g.parquet")
    _infer_schema_from_paths(q, names, types)
    assert_equal(len(names), 1)
    assert_equal(names[0], "k")
    assert_true(types[0] == ArrowType.STRING)
    # Without it, the same column is an integer.
    _infer_schema_from_paths(_one("k=5/f.parquet"), names, types)
    assert_true(types[0] == ArrowType.INT64)


def test_empty_base_prefix_is_root() raises:
    var d = evaluate_partition_prefix(
        "", List[String](), List[ArrowType](), PartitionPredicate.empty()
    )
    assert_equal(len(d.prefixes), 1)
    assert_equal(d.prefixes[0], "/")


def main() raises:
    var suite = TestSuite()
    suite.test[test_unescape_lowercase_hex]()
    suite.test[test_komira_writer_rule_is_encode]()
    suite.test[test_kv_drops_disqualified_components]()
    suite.test[test_kv_no_slash_has_no_partitions]()
    suite.test[test_probe_empty_and_sign_only]()
    suite.test[test_probe_date_rejections]()
    suite.test[test_probe_month_end_sweep]()
    suite.test[test_probe_timestamp]()
    suite.test[test_probe_timestamp_rejections]()
    suite.test[test_compare_values_int64]()
    suite.test[test_compare_values_string]()
    suite.test[test_parse_int_or_zero]()
    suite.test[test_fold_other_keeps_files]()
    suite.test[test_fold_missing_column_drops_file]()
    suite.test[test_fold_compare_ops_end_to_end]()
    suite.test[test_type_for_col]()
    suite.test[test_infer_schema_edges]()
    suite.test[test_empty_base_prefix_is_root]()
    suite^.run()
