# =============================================================================
# test_iceberg_partition_spec.mojo — partition-spec model falsifiers.
# =============================================================================
#
# The model-level checks (no store, no commit): the partition transform math,
# the spec JSON and the per-row partition-value routing.
#
#   1. murmur3_x86_32 matches the reference vectors (an external engine must
#      derive the SAME bucket).
#   2. iceberg_bucket_of routes int/long/string keys deterministically into
#      [0, N) and is stable across calls.
#   3. partition_value_of computes the right tuple (IDENTITY = value verbatim;
#      BUCKET = the bucket index) for a row.
#   4. rows with DIFFERENT partition values land in DIFFERENT partition keys;
#      rows with the SAME partition value share ONE partition key (the grouping
#      invariant the per-partition data-file router depends on).
#   5. partition_spec_json emits the spec-shaped {spec-id, fields:[{source-id,
#      field-id, name, transform}]} for identity + bucket.
# =============================================================================

from std.testing import assert_true, assert_equal

from komira_iceberg import (
    ICE_T_LONG,
    ICE_T_STRING,
    ICE_T_INT,
    IcebergSchema,
    RowCell,
    make_long_cell,
    make_string_cell,
    make_int_cell,
    PartitionSpec,
    PartitionField,
    ICE_TRANSFORM_IDENTITY,
    ICE_TRANSFORM_BUCKET,
    murmur3_x86_32,
    iceberg_bucket_of,
    partition_value_of,
    partition_value_type_tags,
    partition_key_string,
    partition_spec_json,
)


def _people_schema() -> IcebergSchema:
    var schema = IcebergSchema(0)
    schema.add(String("id"), ICE_T_LONG, required=True)
    schema.add(String("region"), ICE_T_STRING, required=True)
    return schema^


def _row(id: Int64, var region: String) -> List[RowCell]:
    var r = List[RowCell]()
    r.append(make_long_cell(id))
    r.append(make_string_cell(region^))
    return r^


# =============================================================================
# 1 — murmur3_x86_32 reference vectors.
# =============================================================================


def test_murmur3_reference_vectors() raises:
    """murmur3_x86_32(seed=0) matches the well-known reference vectors.

    Canonical Austin-Appleby murmur3 x86 32-bit seed-0 vectors:
      "" (empty)                                   -> 0x00000000
      "hello"                                       -> 0x248bfa47
      "The quick brown fox jumps over the lazy dog" -> 0x2e4ff723

    A hash that is not the standard murmur3 fails here (Iceberg's
    bucket transform requires the EXACT spec hash for cross-engine agreement)."""
    # Empty input hashes to 0 with seed 0 (the murmur3 identity).
    var empty = List[UInt8]()
    assert_equal(
        Int(murmur3_x86_32(empty, UInt32(0))), 0, "murmur3('') == 0"
    )

    # "hello" -> the reference murmur3_x86_32 seed-0 value 0x248bfa47.
    var hello = List[UInt8]()
    for c in String("hello").as_bytes():
        hello.append(c)
    assert_equal(
        Int(murmur3_x86_32(hello, UInt32(0))),
        Int(UInt32(0x248BFA47)),
        "murmur3('hello') == 0x248bfa47 (reference vector)",
    )

    # "The quick brown fox jumps over the lazy dog" -> 0x2e4ff723.
    var fox = List[UInt8]()
    for c in String(
        "The quick brown fox jumps over the lazy dog"
    ).as_bytes():
        fox.append(c)
    assert_equal(
        Int(murmur3_x86_32(fox, UInt32(0))),
        Int(UInt32(0x2E4FF723)),
        "murmur3(fox) == 0x2e4ff723 (reference vector)",
    )


# =============================================================================
# 2 — bucket determinism + range.
# =============================================================================


def test_bucket_in_range_and_stable() raises:
    """iceberg_bucket_of routes keys into [0, N) and is STABLE (same value ->
    same bucket on repeated calls). A long key + a string key both work."""
    var buckets = 8

    # long key
    for v in range(0, 200):
        var cell = make_long_cell(Int64(v))
        var b = iceberg_bucket_of(cell, ICE_T_LONG, buckets)
        assert_true(b >= 0 and b < buckets, "long bucket in [0,N)")
        # stable
        var b2 = iceberg_bucket_of(cell, ICE_T_LONG, buckets)
        assert_equal(b, b2, "long bucket stable across calls")

    # string key
    var names = List[String]()
    names.append(String("alice"))
    names.append(String("bob"))
    names.append(String("carol"))
    names.append(String("dave"))
    for i in range(len(names)):
        var cell = make_string_cell(String(names[i]))
        var b = iceberg_bucket_of(cell, ICE_T_STRING, buckets)
        assert_true(b >= 0 and b < buckets, "string bucket in [0,N)")
        var b2 = iceberg_bucket_of(cell, ICE_T_STRING, buckets)
        assert_equal(b, b2, "string bucket stable across calls")


# =============================================================================
# 3 — partition_value_of (IDENTITY + BUCKET).
# =============================================================================


def test_partition_value_of_identity_and_bucket() raises:
    """partition_value_of yields IDENTITY = the source value verbatim; BUCKET =
    the bucket index INT. Spec: bucket(4, id) on `id` + identity on `region`."""
    var schema = _people_schema()
    var spec = PartitionSpec(0)
    spec.add_bucket(1, 4, String("id_bucket"))  # source field-id 1 == id
    spec.add_identity(2, String("region"))  # source field-id 2 == region

    var row = _row(Int64(42), String("us-east"))
    var pv = partition_value_of(spec, schema, row)
    assert_equal(len(pv), 2, "two partition fields -> two partition values")

    # field 0: bucket(4, 42) — an INT in [0,4).
    assert_equal(pv[0].type_tag, ICE_T_INT, "bucket value is INT")
    var expect_bucket = iceberg_bucket_of(make_long_cell(Int64(42)), ICE_T_LONG, 4)
    assert_equal(
        Int(pv[0].as_long()),
        expect_bucket,
        "bucket partition value == iceberg_bucket_of(id)",
    )

    # field 1: identity(region) — the string verbatim.
    assert_equal(pv[1].type_tag, ICE_T_STRING, "identity value keeps type")
    assert_equal(
        pv[1].as_string(), String("us-east"), "identity value == source"
    )

    # value type tags line up.
    var tags = partition_value_type_tags(spec, schema)
    assert_equal(tags[0], ICE_T_INT, "bucket tag INT")
    assert_equal(tags[1], ICE_T_STRING, "identity tag = source type")


# =============================================================================
# 4 — grouping invariant: same partition -> same key; different -> different.
# =============================================================================


def test_partition_key_grouping_invariant() raises:
    """Rows with the SAME partition value share ONE partition key; rows with a
    DIFFERENT partition value get a DIFFERENT key. This is the invariant the
    per-partition data-file router relies on (equal key == same file)."""
    var schema = _people_schema()
    var spec = PartitionSpec(0)
    spec.add_identity(2, String("region"))  # partition by region

    var r_east_1 = _row(Int64(1), String("us-east"))
    var r_east_2 = _row(Int64(2), String("us-east"))
    var r_west = _row(Int64(3), String("us-west"))

    var k_east_1 = partition_key_string(
        spec, partition_value_of(spec, schema, r_east_1)
    )
    var k_east_2 = partition_key_string(
        spec, partition_value_of(spec, schema, r_east_2)
    )
    var k_west = partition_key_string(
        spec, partition_value_of(spec, schema, r_west)
    )

    assert_equal(
        k_east_1, k_east_2, "two us-east rows share ONE partition key"
    )
    assert_true(k_east_1 != k_west, "us-east and us-west keys DIFFER")
    # the key carries the col=value fragment.
    assert_true(
        k_east_1.find("region=us-east") >= 0,
        "partition key names the col=value fragment",
    )


# =============================================================================
# 5 — partition_spec_json emit shape.
# =============================================================================


def test_partition_spec_json_shape() raises:
    """partition_spec_json emits the spec-shaped {spec-id, fields:[...]} with
    the source-id / field-id / name / transform per field (vs the empty
    unpartitioned form)."""
    var spec = PartitionSpec(0)
    spec.add_bucket(1, 16, String("id_bucket"))
    spec.add_identity(2, String("region"))

    var j = partition_spec_json(spec)
    assert_true(j.find('"spec-id":0') >= 0, "spec-id present")
    assert_true(j.find('"source-id":1') >= 0, "bucket source-id")
    assert_true(
        j.find('"transform":"bucket[16]"') >= 0, "bucket[16] transform"
    )
    assert_true(j.find('"source-id":2') >= 0, "identity source-id")
    assert_true(
        j.find('"transform":"identity"') >= 0, "identity transform"
    )
    assert_true(j.find('"name":"id_bucket"') >= 0, "bucket field name")
    assert_true(j.find('"name":"region"') >= 0, "identity field name")
    # partition-field ids assigned 1000-based.
    assert_true(j.find('"field-id":1000') >= 0, "first partition field-id 1000")
    assert_true(j.find('"field-id":1001') >= 0, "second partition field-id 1001")


def main() raises:
    test_murmur3_reference_vectors()
    test_bucket_in_range_and_stable()
    test_partition_value_of_identity_and_bucket()
    test_partition_key_grouping_invariant()
    test_partition_spec_json_shape()
    print("test_iceberg_partition_spec: ALL PASS")
