# =============================================================================
# test_iceberg_partition_key.mojo — bucket vectors, path-safe keys, routing.
# =============================================================================
#
# What each test proves (and the defect it catches):
#   1. The bucket transform gives the values of Iceberg table spec Appendix B
#      (34 as int or long -> hash 2017239379; "iceberg" -> 1210000089): an
#      engine that derives a different bucket prunes the wrong partitions.
#   2. bucket(N) is `(hash & 0x7FFFFFFF) % N`, int and long hash alike, and a
#      type outside int/long/string is refused.
#   3. partition_key_string is a safe path fragment: a value with `/`, `..`,
#      `=` or non-ASCII bytes never adds path structure, and two different
#      values never share a key (percent-encoding is injective).
#   4. route_rows_to_partitions groups rows by key in first-seen order, and an
#      unpartitioned spec routes everything to one bucket with an empty key.
#   5. add_bucket clamps a non-positive bucket count to 1 (no divide by zero).
# =============================================================================

from std.testing import assert_true, assert_equal, assert_false, assert_raises

from komira_iceberg import (
    ICE_T_BOOLEAN,
    ICE_T_INT,
    ICE_T_LONG,
    ICE_T_STRING,
    IcebergSchema,
    PartitionSpec,
    RowCell,
    make_int_cell,
    make_long_cell,
    make_string_cell,
    make_boolean_cell,
    iceberg_bucket_of,
    partition_value_of,
    partition_key_string,
    route_rows_to_partitions,
)

comptime _HUGE: Int = 1 << 31


def test_bucket_matches_spec_appendix_b() raises:
    # With N = 2^31 the bucket is `hash & 0x7FFFFFFF`, the spec's published
    # hash for each value (all three are positive, below 2^31).
    assert_equal(iceberg_bucket_of(make_int_cell(Int32(34)), ICE_T_INT, _HUGE), 2017239379)
    assert_equal(iceberg_bucket_of(make_long_cell(Int64(34)), ICE_T_LONG, _HUGE), 2017239379)
    assert_equal(
        iceberg_bucket_of(make_string_cell(String("iceberg")), ICE_T_STRING, _HUGE),
        1210000089,
    )


def test_bucket_modulo_and_refusals() raises:
    assert_equal(iceberg_bucket_of(make_long_cell(Int64(34)), ICE_T_LONG, 16), 2017239379 % 16)
    assert_equal(iceberg_bucket_of(make_long_cell(Int64(34)), ICE_T_LONG, 1), 0)
    with assert_raises():
        _ = iceberg_bucket_of(make_boolean_cell(True), ICE_T_BOOLEAN, 4)


def _spec_region() -> PartitionSpec:
    var spec = PartitionSpec(0)
    spec.add_identity(2, String("region"))
    return spec^


def _schema() -> IcebergSchema:
    var s = IcebergSchema(0)
    s.add(String("id"), ICE_T_LONG, required=True)
    s.add(String("region"), ICE_T_STRING, required=True)
    return s^


def _row(id: Int64, var region: String) -> List[RowCell]:
    var r = List[RowCell]()
    r.append(make_long_cell(id))
    r.append(make_string_cell(region^))
    return r^


def _key(var region: String) raises -> String:
    var spec = _spec_region()
    var pv = partition_value_of(spec, _schema(), _row(1, region^))
    return partition_key_string(spec, pv)


def test_partition_key_is_a_safe_path_fragment() raises:
    assert_equal(_key(String("us-east_1.x")), String("region=us-east_1.x"))
    assert_equal(_key(String("a/b")), String("region=a%2Fb"))
    assert_equal(_key(String("../../etc")), String("region=..%2F..%2Fetc"))
    assert_equal(_key(String("k=v")), String("region=k%3Dv"))
    assert_equal(_key(String("é")), String("region=%C3%A9"))
    assert_equal(_key(String("a b%")), String("region=a%20b%25"))
    # Injective: a literal `%2F` and a `/` must not collide.
    assert_true(_key(String("a%2Fb")) != _key(String("a/b")))
    # No separator ever appears inside the value part.
    assert_equal(_key(String("x/y/z")).find("/"), -1)


def test_unpartitioned_key_is_empty() raises:
    var spec = PartitionSpec(0)
    var pv = partition_value_of(spec, _schema(), _row(1, String("x")))
    assert_equal(partition_key_string(spec, pv), String(""))


def test_routing_groups_rows_in_first_seen_order() raises:
    var spec = _spec_region()
    var rows = List[List[RowCell]]()
    rows.append(_row(1, String("eu")))
    rows.append(_row(2, String("us")))
    rows.append(_row(3, String("eu")))
    rows.append(_row(4, String("a/b")))
    var parts = route_rows_to_partitions(spec, _schema(), rows)
    assert_equal(len(parts), 3)
    assert_equal(parts[0].partition_key, String("region=eu"))
    assert_equal(len(parts[0].rows), 2)
    assert_equal(parts[1].partition_key, String("region=us"))
    assert_equal(len(parts[1].rows), 1)
    assert_equal(parts[2].partition_key, String("region=a%2Fb"))
    assert_equal(len(parts[0].partition_avro), 1)
    var copy = parts[0].copy()
    assert_equal(len(copy.rows), 2)

    var none = route_rows_to_partitions(PartitionSpec(0), _schema(), rows)
    assert_equal(len(none), 1)
    assert_equal(none[0].partition_key, String(""))
    assert_equal(len(none[0].rows), 4)


def test_add_bucket_clamps_a_non_positive_count() raises:
    var spec = PartitionSpec(0)
    spec.add_bucket(1, 0, String("b"))
    spec.add_bucket(1, -5, String("c"))
    assert_equal(spec.fields[0].param, 1)
    assert_equal(spec.fields[1].param, 1)
    assert_equal(spec.fields[1].field_id, 1001)
    assert_equal(spec.last_partition_id(), 1001)
    assert_equal(PartitionSpec(0).last_partition_id(), 999)
    with assert_raises():
        var s2 = PartitionSpec(0)
        s2.add_identity(77, String("nope"))
        _ = partition_value_of(s2, _schema(), _row(1, String("x")))


def main() raises:
    test_bucket_matches_spec_appendix_b()
    test_bucket_modulo_and_refusals()
    test_partition_key_is_a_safe_path_fragment()
    test_unpartitioned_key_is_empty()
    test_routing_groups_rows_in_first_seen_order()
    test_add_bucket_clamps_a_non_positive_count()
    print("test_iceberg_partition_key: all passed")
