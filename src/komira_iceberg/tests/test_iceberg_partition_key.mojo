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

from std.memory import bitcast
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
    make_double_cell,
    make_null_cell,
    ICE_T_DOUBLE,
    murmur3_x86_32,
    transform_name,
    partition_value_type_tags,
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


def _bytes_of(s: String) -> List[UInt8]:
    return List[UInt8](s.as_bytes())


def test_murmur3_reference_vectors_and_every_tail_length() raises:
    # Reference values of the canonical x86 32-bit murmur3, seed 0: the empty
    # input, a 5-byte input (tail of 1), and tails of 2, 3 and none ("abcd").
    assert_equal(Int(murmur3_x86_32(List[UInt8](), UInt32(0))), 0)
    assert_equal(Int(murmur3_x86_32(_bytes_of(String("hello")), UInt32(0))), 0x248BFA47)
    assert_equal(
        Int(murmur3_x86_32(_bytes_of(String("The quick brown fox jumps over the lazy dog")), UInt32(0))),
        0x2E4FF723,
    )
    assert_equal(Int(murmur3_x86_32(_bytes_of(String("ab")), UInt32(0))), 2613040991)
    assert_equal(Int(murmur3_x86_32(_bytes_of(String("abc")), UInt32(0))), 0xB3DD93FA)
    assert_equal(Int(murmur3_x86_32(_bytes_of(String("abcd")), UInt32(0))), 1139631978)
    # The seed matters.
    assert_true(
        murmur3_x86_32(_bytes_of(String("abc")), UInt32(1))
        != murmur3_x86_32(_bytes_of(String("abc")), UInt32(0))
    )


def test_bucket_masks_a_hash_above_2_to_the_31() raises:
    # murmur3 of the 8-byte long: 2 -> 3323962100, 3 -> 2738575283, 7 ->
    # 4157363267, all >= 2^31. The bucket is (hash & 0x7FFFFFFF) % N: dropping
    # the mask would give 4, 3 and 1 for N = 7, not 2, 1 and 6.
    assert_equal(iceberg_bucket_of(make_long_cell(Int64(2)), ICE_T_LONG, _HUGE), 1176478452)
    assert_equal(iceberg_bucket_of(make_long_cell(Int64(2)), ICE_T_LONG, 7), 2)
    assert_equal(iceberg_bucket_of(make_long_cell(Int64(3)), ICE_T_LONG, 7), 1)
    assert_equal(iceberg_bucket_of(make_long_cell(Int64(7)), ICE_T_LONG, 7), 6)
    assert_equal(iceberg_bucket_of(make_long_cell(Int64(4)), ICE_T_LONG, 7), 0)


def test_a_non_positive_bucket_count_is_refused() raises:
    with assert_raises():
        _ = iceberg_bucket_of(make_long_cell(Int64(1)), ICE_T_LONG, 0)
    with assert_raises():
        _ = iceberg_bucket_of(make_long_cell(Int64(1)), ICE_T_LONG, -3)


def test_a_null_never_becomes_a_partition_value_or_a_bucket() raises:
    # A null would hash as 0 / "" and share a bucket and a key with the real
    # value; it is refused everywhere it could be zeroed.
    with assert_raises():
        _ = iceberg_bucket_of(make_null_cell(ICE_T_LONG), ICE_T_LONG, 16)
    with assert_raises():
        _ = iceberg_bucket_of(make_null_cell(ICE_T_STRING), ICE_T_STRING, 16)
    var ident = _spec_region()
    var null_region = List[RowCell]()
    null_region.append(make_long_cell(Int64(1)))
    null_region.append(make_null_cell(ICE_T_STRING))
    with assert_raises():
        _ = partition_value_of(ident, _schema(), null_region)
    var bucket = PartitionSpec(0)
    bucket.add_bucket(1, 8, String("id_bucket"))
    var null_id = List[RowCell]()
    null_id.append(make_null_cell(ICE_T_LONG))
    null_id.append(make_string_cell(String("eu")))
    with assert_raises():
        _ = partition_value_of(bucket, _schema(), null_id)
    # A null in a value tuple handed straight to the key builder.
    var tuple = List[RowCell]()
    tuple.append(make_null_cell(ICE_T_STRING))
    with assert_raises():
        _ = partition_key_string(ident, tuple)
    var rows = List[List[RowCell]]()
    rows.append(_row(1, String("eu")))
    rows.append(null_region.copy())
    with assert_raises():
        _ = route_rows_to_partitions(ident, _schema(), rows)


def test_a_bucket_and_identity_spec_gives_the_full_tuple_and_types() raises:
    var spec = PartitionSpec(0)
    spec.add_bucket(1, 16, String("id_bucket"))
    spec.add_identity(2, String("region"))
    var pv = partition_value_of(spec, _schema(), _row(34, String("eu")))
    assert_equal(len(pv), 2)
    assert_equal(pv[0].type_tag, ICE_T_INT)
    assert_equal(pv[0].as_long(), Int64(2017239379 % 16))
    assert_equal(pv[1].as_string(), String("eu"))
    var types = partition_value_type_tags(spec, _schema())
    assert_equal(len(types), 2)
    assert_equal(types[0], ICE_T_INT)
    assert_equal(types[1], ICE_T_STRING)
    assert_equal(partition_key_string(spec, pv), String("id_bucket=" + String(2017239379 % 16) + "/region=eu"))
    # An identity field's partition type is its source column's.
    assert_equal(partition_value_type_tags(_spec_region(), _schema())[0], ICE_T_STRING)
    assert_equal(len(partition_value_type_tags(PartitionSpec(0), _schema())), 0)
    assert_equal(transform_name(0, 0), String("identity"))
    assert_equal(transform_name(1, 16), String("bucket[16]"))
    with assert_raises():
        _ = transform_name(9, 0)


def test_wrong_arity_is_refused_not_indexed() raises:
    var spec = _spec_region()
    var short = List[RowCell]()
    short.append(make_long_cell(Int64(1)))
    with assert_raises():
        _ = partition_value_of(spec, _schema(), short)
    var long_row = _row(1, String("eu"))
    long_row.append(make_long_cell(Int64(2)))
    with assert_raises():
        _ = partition_value_of(spec, _schema(), long_row)
    var rows = List[List[RowCell]]()
    rows.append(_row(1, String("eu")))
    rows.append(short.copy())
    with assert_raises():
        _ = route_rows_to_partitions(spec, _schema(), rows)
    # More partition fields than values.
    var two = PartitionSpec(0)
    two.add_identity(1, String("id"))
    two.add_identity(2, String("region"))
    var one_value = List[RowCell]()
    one_value.append(make_long_cell(Int64(1)))
    with assert_raises():
        _ = partition_key_string(two, one_value)


def test_field_names_are_escaped_in_the_key() raises:
    var spec = PartitionSpec(0)
    spec.add_identity(2, String("a/b=c"))
    var pv = partition_value_of(spec, _schema(), _row(1, String("x")))
    assert_equal(partition_key_string(spec, pv), String("a%2Fb%3Dc=x"))


def test_zero_and_negative_zero_identity_keys_are_one_key() raises:
    var s = IcebergSchema(0)
    s.add(String("v"), ICE_T_DOUBLE, required=True)
    var spec = PartitionSpec(0)
    spec.add_identity(1, String("v"))
    var neg = bitcast[DType.float64, 1](UInt64(0x8000000000000000))
    var a = List[RowCell]()
    a.append(make_double_cell(neg))
    var b = List[RowCell]()
    b.append(make_double_cell(Float64(0)))
    var ka = partition_key_string(spec, partition_value_of(spec, s, a))
    var kb = partition_key_string(spec, partition_value_of(spec, s, b))
    assert_equal(ka, kb)
    var c = List[RowCell]()
    c.append(make_double_cell(Float64(1.5)))
    assert_true(partition_key_string(spec, partition_value_of(spec, s, c)) != ka)


def test_routing_keeps_the_typed_and_encoded_tuples() raises:
    var spec = PartitionSpec(0)
    spec.add_identity(2, String("region"))
    var rows = List[List[RowCell]]()
    rows.append(_row(1, String("eu")))
    var parts = route_rows_to_partitions(spec, _schema(), rows)
    assert_equal(len(parts), 1)
    assert_equal(parts[0].partition_values[0].as_string(), String("eu"))
    assert_equal(parts[0].partition_types[0], ICE_T_STRING)
    # Avro string "eu": zigzag length 2 -> 0x04, then the bytes.
    assert_equal(len(parts[0].partition_avro[0]), 3)
    assert_equal(parts[0].partition_avro[0][0], UInt8(4))
    assert_equal(parts[0].partition_avro[0][1], UInt8(ord("e")))
    assert_equal(parts[0].partition_avro[0][2], UInt8(ord("u")))


def main() raises:
    test_bucket_matches_spec_appendix_b()
    test_bucket_modulo_and_refusals()
    test_partition_key_is_a_safe_path_fragment()
    test_unpartitioned_key_is_empty()
    test_routing_groups_rows_in_first_seen_order()
    test_add_bucket_clamps_a_non_positive_count()
    test_murmur3_reference_vectors_and_every_tail_length()
    test_bucket_masks_a_hash_above_2_to_the_31()
    test_a_non_positive_bucket_count_is_refused()
    test_a_null_never_becomes_a_partition_value_or_a_bucket()
    test_a_bucket_and_identity_spec_gives_the_full_tuple_and_types()
    test_wrong_arity_is_refused_not_indexed()
    test_field_names_are_escaped_in_the_key()
    test_zero_and_negative_zero_identity_keys_are_one_key()
    test_routing_keeps_the_typed_and_encoded_tuples()
    print("test_iceberg_partition_key: all passed")
