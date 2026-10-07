# =============================================================================
# tests/test_scan_dedup_cache_share_insert.mojo
#
# Scan dedup cache, sharing insert — parity + aliasing-soundness guard for a
# `share_batch` insert at the scan dedup pass's cross-call cache-insert sites.
#
# WHAT IS UNDER TEST
# ------------------
# The scan dedup pass materializes each shared / multi-table-singleton scan
# ONCE, then (a) registers the batch in the per-call InMemoryRegistry (consumed
# by the in-mem join build/probe) AND (b) inserts it into the
# EngineContext-scoped `ScanDedupCache` for cross-call reuse. The insert is a
# ZERO-COPY `share_batch(batch)`: the cache entry ALIASES the producer's
# Arc-backed column buffers instead of memcpy'ing them. A deep
# `copy_batch(batch)` there would be serial, main-thread planning latency on
# every multi-join query, and dead weight on a fresh EngineContext (a context
# used for one query never reads the cache back).
#
# WHY THIS TEST
# -------------
# The whole hazard of sharing is a dangling-alias / use-after-free: the producer
# batch (the per-call registry batch) is DROPPED when the query's registry tears
# down, but the cache SHARE must keep reading correct bytes (the Arc refcount
# holds the buffers alive). `lookup_copy` then hands warm-context readers the
# cached columns, so cross-call reuse must be byte-identical to a
# deep-copy-on-insert.
#
#   test_share_insert_survives_producer_drop  — THE FALSIFIER. Insert
#     `share_batch(producer)`, read+DROP the producer (registry teardown), then
#     `lookup_copy` and assert every cell equals the KNOWN input values. A
#     share that aliased freed/reused bytes (a missed Arc ref) would read garbage
#     here; the correct Arc share reads byte-stable.
#   test_share_insert_matches_copy_insert_parity — PARITY. share-insert and a
#     copy-insert, read back through `lookup_copy` after BOTH producers drop,
#     are cell-for-cell identical (the reference-vs-optimized oracle).
#
# String columns are included deliberately: they carry an offsets buffer AND a
# data buffer, the highest-risk share shape (miss either and cells corrupt).
#
# Pointer rules: public Column / typed-array / batch /
# cache surface only. No UnsafePointer, no wildcard origin, no
# unsafe_from_address / take_pointee.
# =============================================================================

from std.testing import TestSuite, assert_true, assert_equal

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import SchemaBuilder, Field, RecordBatchBuilder
from komira_column_kernels.compiler_helpers import copy_batch, share_batch
from komira_dispatch_scan.scan_dedup_cache import ScanDedupCache


# --- KNOWN INPUT VALUES (the independent oracle) -----------------------------
# The batch is built from these raw lists, and lookup_copy results are asserted
# against these SAME lists — so a bug that corrupts BOTH the build and the share
# path is still caught (the values are literals, not derived from any copy).


def _exp_i64() -> List[Int64]:
    var v = List[Int64]()
    v.append(Int64(-9))
    v.append(Int64(0))
    v.append(Int64(42))
    v.append(Int64(6001215))
    v.append(Int64(-1))
    return v^


def _exp_str() -> List[String]:
    var v = List[String]()
    v.append(String("FRANCE"))
    v.append(String(""))
    v.append(String("a-longer-string-that-exceeds-inline"))
    v.append(String("GERMANY"))
    v.append(String("z"))
    return v^


def _producer_batch() raises -> RecordBatch:
    """A 2-column (INT64 + STRING) batch built from the known-value lists.

    The STRING column exercises offsets-buffer + data-buffer sharing (the
    highest-risk share shape). Fresh allocation each call so a test can hold two
    independent producers."""
    var sb = SchemaBuilder()
    var builder = RecordBatchBuilder()
    sb.add_field(Field(String("k"), ArrowType.INT64, False))
    builder.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(_exp_i64())
        )
    )
    sb.add_field(Field(String("s"), ArrowType.STRING, False))
    builder.add_column(Column.from_string(StringArray.from_strings(_exp_str())))
    var schema = sb.build()
    return builder.build(schema^)


def _assert_matches_known(imm rb: RecordBatch) raises:
    """Assert `rb` is cell-for-cell equal to the KNOWN input lists."""
    var exp_i = _exp_i64()
    var exp_s = _exp_str()
    assert_equal(rb.num_columns(), 2, "2 columns")
    assert_equal(rb.num_rows(), len(exp_i), "row count")
    ref ci = rb.column_at(0)
    assert_equal(Int(ci.arrow_type.type_id), Int(ArrowType.INT64.type_id), "col0 int64")
    var ai = ci.as_primitive[DType.int64]()
    for i in range(len(exp_i)):
        assert_true(not ai.is_null(i), "int cell non-null")
        assert_equal(ai.get(i), exp_i[i], "int64 cell " + String(i))
    ref cs = rb.column_at(1)
    assert_equal(Int(cs.arrow_type.type_id), Int(ArrowType.STRING.type_id), "col1 string")
    var as_ = cs.as_string()
    for i in range(len(exp_s)):
        assert_true(not as_.is_null(i), "str cell non-null")
        assert_equal(String(as_.get(i)), exp_s[i], "string cell " + String(i))


def test_share_insert_survives_producer_drop() raises:
    """THE FALSIFIER. Mirror the `deduplicate_scans` insert: `share_batch` the
    producer into the cache, then consume + DROP the producer (the per-call
    registry teardown that follows the query). The cached SHARE must still read
    every KNOWN cell — the Arc refcount holds the aliased buffers alive past the
    producer's death. A dangling alias would read freed/reused bytes here."""
    var cache = ScanDedupCache()

    # Materialize-once producer (the batch the registry would own).
    var producer = _producer_batch()

    # (b) cross-call cache insert — the zero-copy share shape.
    cache.insert(String("dedup_key"), share_batch(producer))

    # (a) the registry consumer READS the producer (join build/probe), then the
    # per-call registry tears down -> the producer batch DROPS.
    var probe = producer.column_at(0).as_primitive[DType.int64]()
    assert_equal(probe.get(3), Int64(6001215), "producer readable pre-drop")
    _ = producer^  # DROP the producer — only the cache's Arc share remains.

    # The cache entry survives + reads byte-stable through lookup_copy.
    var got = cache.lookup_copy(String("dedup_key"))
    assert_true(got.__bool__(), "cache hit after producer drop")
    var cached = got.take()
    _assert_matches_known(cached)
    _ = cached^


def test_share_insert_matches_copy_insert_parity() raises:
    """PARITY (reference-vs-optimized oracle). A deep `copy_batch` insert
    and a `share_batch` insert, both read back via `lookup_copy` AFTER
    their producers drop, are cell-for-cell identical — and both equal the known
    input. Cross-call reuse is byte-identical, so no query result can change."""
    var cache = ScanDedupCache()

    var p_share = _producer_batch()
    cache.insert(String("via_share"), share_batch(p_share))
    _ = p_share^  # producer gone; cache holds only the share

    var p_copy = _producer_batch()
    cache.insert(String("via_copy"), copy_batch(p_copy))
    _ = p_copy^

    var g_share = cache.lookup_copy(String("via_share"))
    var g_copy = cache.lookup_copy(String("via_copy"))
    assert_true(g_share.__bool__(), "share entry present")
    assert_true(g_copy.__bool__(), "copy entry present")
    var rb_share = g_share.take()
    var rb_copy = g_copy.take()

    # Both match the independent known-value oracle -> they match each other.
    _assert_matches_known(rb_share)
    _assert_matches_known(rb_copy)
    _ = rb_share^
    _ = rb_copy^


def main() raises:
    var suite = TestSuite()
    suite.test[test_share_insert_survives_producer_drop]()
    suite.test[test_share_insert_matches_copy_insert_parity]()
    suite^.run()
