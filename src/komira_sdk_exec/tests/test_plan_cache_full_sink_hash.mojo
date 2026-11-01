# =============================================================================
# Unit test -- plan_compile_cache full sink hash
# =============================================================================
#
# Validates `compose_full_cache_key` and its sink-config salt in
# `plan_compile_cache.mojo`:
#
#   1. different SinkVariant kinds (CSV vs Parquet, CSV vs JSONL) produce
#      DIFFERENT cache keys for the SAME plan, so a `write_csv` and a
#      `write_parquet` on the same DataFrame do NOT alias.
#   2. different compression kinds of one format (CSV vs CSV_GZIP, Parquet
#      Snappy vs Zstd) produce DIFFERENT cache keys (the codec is part of the
#      hash).
#   3. the same SinkVariant kind produces the SAME key every time the helper
#      is queried (it is pure and deterministic).
#
# The PATH is excluded from the sink salt by construction (the helper only
# consumes `sink_kind: UInt8`), so two `write_csv("/a")` and `write_csv("/b")`
# calls SHARE cache keys when the structural and stats hashes match.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_not_equal

from komira_sdk_exec.plan_compile_cache import compose_full_cache_key
from komira_sdk_exec.sink_variant_tags import (
    SINK_VARIANT_FILE_CSV,
    SINK_VARIANT_FILE_CSV_GZIP,
    SINK_VARIANT_FILE_JSONL,
    SINK_VARIANT_FILE_PARQUET_SNAPPY,
    SINK_VARIANT_FILE_PARQUET_ZSTD,
)


def test_csv_vs_parquet_keys_differ() raises:
    var structural = UInt64(0xCAFE_BABE_1234_5678)
    var stats = UInt64(0xDEAD_BEEF_AAAA_BBBB)
    var csv_key = compose_full_cache_key(structural, stats, SINK_VARIANT_FILE_CSV)
    var parquet_key = compose_full_cache_key(
        structural, stats, SINK_VARIANT_FILE_PARQUET_SNAPPY
    )
    assert_not_equal(csv_key, parquet_key)


def test_csv_vs_csv_gzip_keys_differ() raises:
    var structural = UInt64(0x1111_2222_3333_4444)
    var stats = UInt64(0x5555_6666_7777_8888)
    var csv_key = compose_full_cache_key(structural, stats, SINK_VARIANT_FILE_CSV)
    var csv_gz_key = compose_full_cache_key(
        structural, stats, SINK_VARIANT_FILE_CSV_GZIP
    )
    assert_not_equal(csv_key, csv_gz_key)


def test_csv_vs_jsonl_keys_differ() raises:
    var structural = UInt64(0xAAAA_BBBB_CCCC_DDDD)
    var stats = UInt64(0xEEEE_FFFF_1111_2222)
    var csv_key = compose_full_cache_key(structural, stats, SINK_VARIANT_FILE_CSV)
    var jsonl_key = compose_full_cache_key(
        structural, stats, SINK_VARIANT_FILE_JSONL
    )
    assert_not_equal(csv_key, jsonl_key)


def test_parquet_snappy_vs_zstd_keys_differ() raises:
    var structural = UInt64(0x9999_8888_7777_6666)
    var stats = UInt64(0x5555_4444_3333_2222)
    var snappy_key = compose_full_cache_key(
        structural, stats, SINK_VARIANT_FILE_PARQUET_SNAPPY
    )
    var zstd_key = compose_full_cache_key(
        structural, stats, SINK_VARIANT_FILE_PARQUET_ZSTD
    )
    assert_not_equal(snappy_key, zstd_key)


def test_same_kind_same_key_deterministic() raises:
    var structural = UInt64(0xFFFF_EEEE_DDDD_CCCC)
    var stats = UInt64(0xBBBB_AAAA_9999_8888)
    var k1 = compose_full_cache_key(structural, stats, SINK_VARIANT_FILE_CSV)
    var k2 = compose_full_cache_key(structural, stats, SINK_VARIANT_FILE_CSV)
    assert_equal(k1, k2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
