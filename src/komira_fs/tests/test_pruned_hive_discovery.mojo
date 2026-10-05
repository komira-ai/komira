# =============================================================================
# test_pruned_hive_discovery.mojo
# =============================================================================
# Unit tests for the Hive-partition prune-at-list-prefix core:
#   * the encode/parse round-trip helper (the HARD-FAIL GATE:
#     a one-byte encode/parse disagreement = silent zero rows).
#   * key=value path parse.
#   * evaluate_partition_prefix derivation (equality + IN fan-out + range
#     residual).
#   * the filter_partitions fold.
#   * partition-schema inference + type-probe.
#   * the PrunedHiveDiscovery end-to-end via the `from_listing` injected seam
#     (the "injected path lists" seam — fold + inference + arena-handle storage
#     without FS wiring).
#
# Tested at the DISCOVERY SEAM (no typed-read / ctx.materialize binding) —
# avoids compiling the typed source path.
#
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_fs.file_discovery import GlobDiscoveryOptions
from komira_fs.partition_codec import (
    encode_partition_value,
    parse_partition_value,
    parse_key_value_segments,
    probe_partition_type,
    HIVE_DEFAULT_PARTITION,
)
from komira_fs.pruned_hive_discovery import (
    PartitionConstraint,
    PartitionPredicate,
    PrefixDerivation,
    PrunedHiveDiscovery,
    evaluate_partition_prefix,
)


# =============================================================================
# encode/parse ROUND-TRIP helper.
# =============================================================================
# `parse(encode(v)) == v` AND `encode(parse(s)) == s` across the FULL type
# matrix: int / str / date / timestamp / null / special-chars. A failing
# round-trip is the difference between a working query and silent zero rows.


def _assert_roundtrip(value: String, t: ArrowType) raises:
    """parse(encode(value)) == value."""
    var enc = encode_partition_value(value, t)
    var back = parse_partition_value(enc, t)
    assert_equal(back, value)


def _assert_roundtrip_segment(segment: String, t: ArrowType) raises:
    """encode(parse(segment)) == segment (the inverse direction)."""
    var dec = parse_partition_value(segment, t)
    var re = encode_partition_value(dec, t)
    assert_equal(re, segment)


def test_roundtrip_int() raises:
    _assert_roundtrip(String("2024"), ArrowType.INT64)
    _assert_roundtrip(String("0"), ArrowType.INT64)
    _assert_roundtrip(String("-17"), ArrowType.INT64)
    _assert_roundtrip(String("9223372036854775807"), ArrowType.INT64)


def test_roundtrip_string_plain() raises:
    _assert_roundtrip(String("us-west"), ArrowType.STRING)
    _assert_roundtrip(String("region_42"), ArrowType.STRING)
    _assert_roundtrip(String("a.b.c"), ArrowType.STRING)


def test_roundtrip_string_special_chars() raises:
    """Special chars that MUST be %-escaped to survive a path segment: `/`,
    `=`, `%`, space, and a non-ASCII byte. The round-trip is the gate."""
    _assert_roundtrip(String("a/b"), ArrowType.STRING)
    _assert_roundtrip(String("k=v"), ArrowType.STRING)
    _assert_roundtrip(String("50%"), ArrowType.STRING)
    _assert_roundtrip(String("new york"), ArrowType.STRING)
    _assert_roundtrip(String("a&b?c#d"), ArrowType.STRING)
    # mixed escape + literal
    _assert_roundtrip(String("us west/2024"), ArrowType.STRING)


def test_roundtrip_date() raises:
    _assert_roundtrip(String("2026-11-04"), ArrowType.DATE32)
    _assert_roundtrip(String("2000-01-01"), ArrowType.DATE32)


def test_roundtrip_timestamp() raises:
    _assert_roundtrip(String("2026-11-04 03:00:00"), ArrowType.TIMESTAMP)
    _assert_roundtrip(String("1999-12-31 23:59:59"), ArrowType.TIMESTAMP)


def test_roundtrip_null_sentinel() raises:
    """The canonical NULL (empty string) <-> __HIVE_DEFAULT_PARTITION__."""
    # encode("") -> the sentinel
    assert_equal(
        encode_partition_value(String(""), ArrowType.STRING),
        HIVE_DEFAULT_PARTITION,
    )
    # parse(sentinel) -> ""
    assert_equal(
        parse_partition_value(HIVE_DEFAULT_PARTITION, ArrowType.STRING),
        String(""),
    )
    # full round-trip both ways
    _assert_roundtrip(String(""), ArrowType.STRING)
    _assert_roundtrip_segment(HIVE_DEFAULT_PARTITION, ArrowType.STRING)


def test_roundtrip_inverse_segments() raises:
    """encode(parse(s)) == s for canonical on-disk segments (the other
    direction of the round-trip — guards against an encode that does not
    reproduce a valid on-disk segment)."""
    _assert_roundtrip_segment(String("2024"), ArrowType.INT64)
    _assert_roundtrip_segment(String("2026-11-04"), ArrowType.DATE32)
    _assert_roundtrip_segment(String("us-west"), ArrowType.STRING)
    _assert_roundtrip_segment(String("a%2Fb"), ArrowType.STRING)  # escaped `/`
    _assert_roundtrip_segment(String("50%25"), ArrowType.STRING)  # escaped `%`


def test_encode_escapes_segment_breakers() raises:
    """An encoded value must NOT contain a raw `/` or `=` (would corrupt the
    path-segment / key=value parse). The escape is uppercase-hex %XX."""
    var enc_slash = encode_partition_value(String("a/b"), ArrowType.STRING)
    assert_equal(enc_slash, String("a%2Fb"))
    var enc_eq = encode_partition_value(String("k=v"), ArrowType.STRING)
    assert_equal(enc_eq, String("k%3Dv"))
    var enc_pct = encode_partition_value(String("50%"), ArrowType.STRING)
    assert_equal(enc_pct, String("50%25"))


def test_parse_malformed_escape_raises() raises:
    """A truncated / malformed %-escape RAISES (Fail Fast & Loud)."""
    var raised = False
    try:
        _ = parse_partition_value(String("a%2"), ArrowType.STRING)
    except:
        raised = True
    assert_true(raised)
    raised = False
    try:
        _ = parse_partition_value(String("a%ZZb"), ArrowType.STRING)
    except:
        raised = True
    assert_true(raised)


# =============================================================================
# key=value path parse.
# =============================================================================


def test_parse_kv_two_cols() raises:
    var keys = List[String]()
    var vals = List[String]()
    parse_key_value_segments(
        String("events/dt=2026-11-04/hour=03/f.parquet"), keys, vals
    )
    assert_equal(len(keys), 2)
    assert_equal(keys[0], String("dt"))
    assert_equal(vals[0], String("2026-11-04"))
    assert_equal(keys[1], String("hour"))
    assert_equal(vals[1], String("03"))


def test_parse_kv_filename_never_partition() raises:
    """The final component (the file) is never a partition, even if it looks
    like key=value (it won't here, but the rule is structural)."""
    var keys = List[String]()
    var vals = List[String]()
    parse_key_value_segments(String("a/dt=2024/part-0.parquet"), keys, vals)
    assert_equal(len(keys), 1)
    assert_equal(keys[0], String("dt"))


def test_parse_kv_disqualifies_nonconforming() raises:
    """Components with no `=`, a double-`=`, or a `?` are NOT partitions."""
    var keys = List[String]()
    var vals = List[String]()
    # plain dir (no =), double-= dir, and a ?-bearing dir all skipped
    parse_key_value_segments(
        String("base/plaindir/a==b/x?y/dt=2024/f.parquet"), keys, vals
    )
    assert_equal(len(keys), 1)
    assert_equal(keys[0], String("dt"))
    assert_equal(vals[0], String("2024"))


def test_parse_kv_leading_slash() raises:
    var keys = List[String]()
    var vals = List[String]()
    parse_key_value_segments(String("/abs/dt=2024/f.parquet"), keys, vals)
    assert_equal(len(keys), 1)
    assert_equal(vals[0], String("2024"))


def test_parse_kv_none() raises:
    """A path with no key=value dirs yields empty (plain multi-file)."""
    var keys = List[String]()
    var vals = List[String]()
    parse_key_value_segments(String("a/b/c/file.parquet"), keys, vals)
    assert_equal(len(keys), 0)


# =============================================================================
# evaluate_partition_prefix derivation.
# =============================================================================


def _cols_dt_hour() -> List[String]:
    var c = List[String]()
    c.append(String("dt"))
    c.append(String("hour"))
    return c^


def _types_date_int() -> List[ArrowType]:
    var t = List[ArrowType]()
    t.append(ArrowType.DATE32)
    t.append(ArrowType.INT64)
    return t^


def test_prefix_equality_consumes_leading_run() raises:
    """dt='2026-11-04' AND hour=3 -> single prefix events/dt=.../hour=3/,
    no residual."""
    var preds = List[PartitionConstraint]()
    preds.append(
        PartitionConstraint.eq(String("dt"), String("2026-11-04"), ArrowType.DATE32)
    )
    preds.append(PartitionConstraint.eq(String("hour"), String("3"), ArrowType.INT64))
    var p = PartitionPredicate(constraints=preds^)
    var d = evaluate_partition_prefix(
        String("events/"), _cols_dt_hour(), _types_date_int(), p
    )
    assert_equal(len(d.prefixes), 1)
    assert_equal(d.prefixes[0], String("events/dt=2026-11-04/hour=3/"))
    assert_equal(len(d.residual_cols), 0)


def test_prefix_stops_at_inequality() raises:
    """dt='2026-11-04' AND hour>0 -> prefix events/dt=2026-11-04/, residual
    [hour]."""
    var preds = List[PartitionConstraint]()
    preds.append(
        PartitionConstraint.eq(String("dt"), String("2026-11-04"), ArrowType.DATE32)
    )
    # hour > 0  (op GT)
    preds.append(
        PartitionConstraint.compare(String("hour"), 4, String("0"), ArrowType.INT64)
    )
    var p = PartitionPredicate(constraints=preds^)
    var d = evaluate_partition_prefix(
        String("events/"), _cols_dt_hour(), _types_date_int(), p
    )
    assert_equal(len(d.prefixes), 1)
    assert_equal(d.prefixes[0], String("events/dt=2026-11-04/"))
    assert_equal(len(d.residual_cols), 1)
    assert_equal(d.residual_cols[0], String("hour"))


def test_prefix_in_fanout() raises:
    """dt IN -> TWO targeted prefixes (within the
    fan-out cap), hour residual."""
    var vals = List[String]()
    vals.append(String("2026-11-04"))
    vals.append(String("2026-11-05"))
    var preds = List[PartitionConstraint]()
    preds.append(PartitionConstraint.in_list(String("dt"), vals, ArrowType.DATE32))
    var p = PartitionPredicate(constraints=preds^)
    var d = evaluate_partition_prefix(
        String("events/"), _cols_dt_hour(), _types_date_int(), p
    )
    assert_equal(len(d.prefixes), 2)
    # order follows the IN-list order
    assert_equal(d.prefixes[0], String("events/dt=2026-11-04/"))
    assert_equal(d.prefixes[1], String("events/dt=2026-11-05/"))
    # hour is unpinned -> residual
    assert_equal(len(d.residual_cols), 1)
    assert_equal(d.residual_cols[0], String("hour"))


def test_prefix_eq_then_in_cartesian() raises:
    """dt=X AND hour IN (1,2,3) -> cartesian: 1 x 3 = 3 prefixes."""
    var hours = List[String]()
    hours.append(String("1"))
    hours.append(String("2"))
    hours.append(String("3"))
    var preds = List[PartitionConstraint]()
    preds.append(
        PartitionConstraint.eq(String("dt"), String("2026-11-04"), ArrowType.DATE32)
    )
    preds.append(PartitionConstraint.in_list(String("hour"), hours, ArrowType.INT64))
    var p = PartitionPredicate(constraints=preds^)
    var d = evaluate_partition_prefix(
        String("events/"), _cols_dt_hour(), _types_date_int(), p
    )
    assert_equal(len(d.prefixes), 3)
    assert_equal(d.prefixes[0], String("events/dt=2026-11-04/hour=1/"))
    assert_equal(d.prefixes[2], String("events/dt=2026-11-04/hour=3/"))
    assert_equal(len(d.residual_cols), 0)


def test_prefix_empty_predicate_lists_base() raises:
    """No predicate -> single base prefix, all cols residual (fold filters
    nothing -> keeps all)."""
    var p = PartitionPredicate.empty()
    var d = evaluate_partition_prefix(
        String("events/"), _cols_dt_hour(), _types_date_int(), p
    )
    assert_equal(len(d.prefixes), 1)
    assert_equal(d.prefixes[0], String("events/"))
    assert_equal(len(d.residual_cols), 2)


def test_prefix_encodes_special_value() raises:
    """An equality on a string col with a special char encodes into the
    prefix (round-trip-safe) — 'matches nothing' guard in action."""
    var cols = List[String]()
    cols.append(String("region"))
    var types = List[ArrowType]()
    types.append(ArrowType.STRING)
    var preds = List[PartitionConstraint]()
    preds.append(
        PartitionConstraint.eq(String("region"), String("us west"), ArrowType.STRING)
    )
    var p = PartitionPredicate(constraints=preds^)
    var d = evaluate_partition_prefix(String("t/"), cols, types, p)
    assert_equal(len(d.prefixes), 1)
    assert_equal(d.prefixes[0], String("t/region=us%20west/"))


# =============================================================================
# PrunedHiveDiscovery end-to-end via the from_listing injected seam.
# =============================================================================
# Exercises the fold + schema inference + arena-handle storage (/
# ) against an injected candidate listing (as if fs.list returned it).


def _listing_dated() -> List[String]:
    """A 3-partition dated table; deliberately unsorted to exercise the sort."""
    var p = List[String]()
    p.append(String("events/dt=2026-11-05/hour=03/c.parquet"))
    p.append(String("events/dt=2026-11-04/hour=01/a.parquet"))
    p.append(String("events/dt=2026-11-04/hour=02/b.parquet"))
    return p^


def test_discovery_infers_schema() raises:
    """No declared cols -> schema inferred from paths: dt=DATE32, hour=INT64
    (the hour values 01/02/03 are integer-typed)."""
    var p = PartitionPredicate.empty()
    var disc = PrunedHiveDiscovery.from_listing(
        String("events/"),
        _listing_dated(),
        List[String](),  # infer
        List[ArrowType](),
        p,
        GlobDiscoveryOptions.default(),
    )
    var sch = disc.partition_schema()
    assert_equal(sch.num_columns(), 2)
    assert_equal(sch.names[0], String("dt"))
    assert_equal(sch.names[1], String("hour"))
    assert_equal(disc.num_partition_cols(), 2)
    assert_true(disc.partition_col_type_at(0) == ArrowType.DATE32)
    assert_true(disc.partition_col_type_at(1) == ArrowType.INT64)


def test_discovery_no_predicate_keeps_all() raises:
    """Empty predicate -> all 3 files survive, lexically sorted, partition
    values reconstructed per file from the arena handles."""
    var p = PartitionPredicate.empty()
    var disc = PrunedHiveDiscovery.from_listing(
        String("events/"),
        _listing_dated(),
        List[String](),
        List[ArrowType](),
        p,
        GlobDiscoveryOptions.default(),
    )
    assert_equal(disc.num_paths(), 3)
    # lexical sort: dt=2026-11-04/hour=01 < .../hour=02 < dt=2026-11-05/...
    assert_equal(
        disc.path_at(0), String("events/dt=2026-11-04/hour=01/a.parquet")
    )
    assert_equal(
        disc.path_at(2), String("events/dt=2026-11-05/hour=03/c.parquet")
    )
    # arena-handle partition values for file 0
    var pv0 = disc.partition_values_at(0)
    assert_equal(pv0.num_pairs(), 2)
    assert_equal(pv0.keys[0], String("dt"))
    assert_equal(pv0.values[0], String("2026-11-04"))
    assert_equal(pv0.keys[1], String("hour"))
    assert_equal(pv0.values[1], String("01"))
    # file 2
    var pv2 = disc.partition_values_at(2)
    assert_equal(pv2.values[0], String("2026-11-05"))


def test_discovery_fold_drops_nonmatching() raises:
    """A residual inequality (hour > 1) folds out the hour=01 file, keeping
    the hour=02 + hour=03 files."""
    var preds = List[PartitionConstraint]()
    # hour > 1
    preds.append(
        PartitionConstraint.compare(String("hour"), 4, String("1"), ArrowType.INT64)
    )
    var p = PartitionPredicate(constraints=preds^)
    var disc = PrunedHiveDiscovery.from_listing(
        String("events/"),
        _listing_dated(),
        List[String](),
        List[ArrowType](),
        p,
        GlobDiscoveryOptions.default(),
    )
    # hour=01 dropped; hour=02 + hour=03 survive
    assert_equal(disc.num_paths(), 2)
    assert_equal(
        disc.path_at(0), String("events/dt=2026-11-04/hour=02/b.parquet")
    )
    assert_equal(
        disc.path_at(1), String("events/dt=2026-11-05/hour=03/c.parquet")
    )


def test_discovery_fold_equality_residual() raises:
    """dt='2026-11-04' as a fold constraint keeps only the two 2026-11-04
    files (DATE32 lexical/equality compare)."""
    var preds = List[PartitionConstraint]()
    preds.append(
        PartitionConstraint.eq(String("dt"), String("2026-11-04"), ArrowType.DATE32)
    )
    var p = PartitionPredicate(constraints=preds^)
    var disc = PrunedHiveDiscovery.from_listing(
        String("events/"),
        _listing_dated(),
        List[String](),
        List[ArrowType](),
        p,
        GlobDiscoveryOptions.default(),
    )
    assert_equal(disc.num_paths(), 2)
    var pv0 = disc.partition_values_at(0)
    assert_equal(pv0.values[0], String("2026-11-04"))
    var pv1 = disc.partition_values_at(1)
    assert_equal(pv1.values[0], String("2026-11-04"))


def test_discovery_fold_in_list() raises:
    """hour IN (1,3) keeps the hour=01 + hour=03 files, drops hour=02."""
    var hv = List[String]()
    hv.append(String("1"))
    hv.append(String("3"))
    var preds = List[PartitionConstraint]()
    preds.append(PartitionConstraint.in_list(String("hour"), hv, ArrowType.INT64))
    var p = PartitionPredicate(constraints=preds^)
    var disc = PrunedHiveDiscovery.from_listing(
        String("events/"),
        _listing_dated(),
        List[String](),
        List[ArrowType](),
        p,
        GlobDiscoveryOptions.default(),
    )
    assert_equal(disc.num_paths(), 2)
    # hour=02 dropped: survivors are hour=01 (file0) and hour=03 (file1)
    var pv0 = disc.partition_values_at(0)
    assert_equal(pv0.values[1], String("01"))
    var pv1 = disc.partition_values_at(1)
    assert_equal(pv1.values[1], String("03"))


def test_discovery_fold_empties_raises() raises:
    """A residual that matches nothing RAISES under the default empty-match
    policy."""
    var preds = List[PartitionConstraint]()
    # hour > 99 matches no file
    preds.append(
        PartitionConstraint.compare(String("hour"), 4, String("99"), ArrowType.INT64)
    )
    var p = PartitionPredicate(constraints=preds^)
    var raised = False
    try:
        _ = PrunedHiveDiscovery.from_listing(
            String("events/"),
            _listing_dated(),
            List[String](),
            List[ArrowType](),
            p,
            GlobDiscoveryOptions.default(),
        )
    except:
        raised = True
    assert_true(raised)


def test_discovery_null_partition_value() raises:
    """A __HIVE_DEFAULT_PARTITION__ segment decodes to the canonical NULL
    (empty string) in the reconstructed partition values."""
    var listing = List[String]()
    listing.append(
        String("t/region=__HIVE_DEFAULT_PARTITION__/f.parquet")
    )
    listing.append(String("t/region=us/g.parquet"))
    var p = PartitionPredicate.empty()
    var disc = PrunedHiveDiscovery.from_listing(
        String("t/"),
        listing^,
        List[String](),
        List[ArrowType](),
        p,
        GlobDiscoveryOptions.default(),
    )
    assert_equal(disc.num_paths(), 2)
    # lexical: "__HIVE..." sorts before "us"
    var pv0 = disc.partition_values_at(0)
    assert_equal(pv0.values[0], String(""))  # decoded NULL
    var pv1 = disc.partition_values_at(1)
    assert_equal(pv1.values[0], String("us"))


def test_discovery_probe_string_on_mixed() raises:
    """A col with mixed int/string values type-probes to STRING (VARCHAR
    fallback on conflict —)."""
    var listing = List[String]()
    listing.append(String("t/k=123/a.parquet"))
    listing.append(String("t/k=abc/b.parquet"))
    var p = PartitionPredicate.empty()
    var disc = PrunedHiveDiscovery.from_listing(
        String("t/"),
        listing^,
        List[String](),
        List[ArrowType](),
        p,
        GlobDiscoveryOptions.default(),
    )
    assert_true(disc.partition_col_type_at(0) == ArrowType.STRING)


def main() raises:
    var suite = TestSuite()
    # round-trip helper (the HARD-FAIL gate)
    suite.test[test_roundtrip_int]()
    suite.test[test_roundtrip_string_plain]()
    suite.test[test_roundtrip_string_special_chars]()
    suite.test[test_roundtrip_date]()
    suite.test[test_roundtrip_timestamp]()
    suite.test[test_roundtrip_null_sentinel]()
    suite.test[test_roundtrip_inverse_segments]()
    suite.test[test_encode_escapes_segment_breakers]()
    suite.test[test_parse_malformed_escape_raises]()
    # key=value parse
    suite.test[test_parse_kv_two_cols]()
    suite.test[test_parse_kv_filename_never_partition]()
    suite.test[test_parse_kv_disqualifies_nonconforming]()
    suite.test[test_parse_kv_leading_slash]()
    suite.test[test_parse_kv_none]()
    # evaluate_partition_prefix
    suite.test[test_prefix_equality_consumes_leading_run]()
    suite.test[test_prefix_stops_at_inequality]()
    suite.test[test_prefix_in_fanout]()
    suite.test[test_prefix_eq_then_in_cartesian]()
    suite.test[test_prefix_empty_predicate_lists_base]()
    suite.test[test_prefix_encodes_special_value]()
    # PrunedHiveDiscovery end-to-end (from_listing seam)
    suite.test[test_discovery_infers_schema]()
    suite.test[test_discovery_no_predicate_keeps_all]()
    suite.test[test_discovery_fold_drops_nonmatching]()
    suite.test[test_discovery_fold_equality_residual]()
    suite.test[test_discovery_fold_in_list]()
    suite.test[test_discovery_fold_empties_raises]()
    suite.test[test_discovery_null_partition_value]()
    suite.test[test_discovery_probe_string_on_mixed]()
    suite^.run()
