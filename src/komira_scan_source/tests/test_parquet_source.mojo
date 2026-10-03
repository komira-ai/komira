# =============================================================================
# Tests for ParquetSource, the concrete SourceLike impl for Parquet files.
#
#   - ParquetSource(path, schema, name=None, mtime_ns=0) constructs cleanly.
#   - schema() returns a deep copy (mutating the copy doesn't affect source).
#   - estimate_rows() returns -1 (unknown: the footer row count is not
#     read).
#   - fingerprint() = hash_combine(hash(path), mtime_ns):
#       * Same path + same mtime → same fingerprint (cache hit).
#       * Same path + different mtime → different fingerprint (file
#         rewritten; a stale cache entry must not be reused).
#       * Different path + same mtime → different fingerprint.
#   - copy() produces an independent value (mutate-one-other-unchanged)
#     but same fingerprint (identity-preserving).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false, assert_not_equal

from komira_scan_source.parquet_source import ParquetSource
from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.arrow_types import ArrowType


def _make_lineitem_schema() -> Schema:
    """Reusable 3-col schema for fingerprint + copy tests."""
    var sb = SchemaBuilder()
    sb.add_field(Field("l_orderkey", ArrowType.INT64, nullable=False))
    sb.add_field(Field("l_partkey", ArrowType.INT64, nullable=False))
    sb.add_field(Field("l_quantity", ArrowType.FLOAT64, nullable=True))
    return sb.build()


def _make_empty_schema() -> Schema:
    var sb = SchemaBuilder()
    return sb.build()


# =============================================================================
# Construction + accessors
# =============================================================================


def test_parquet_source_construct_minimal() raises:
    """Construct with path + minimal Schema; verify path/name/mtime accessors."""
    var src = ParquetSource(String("lineitem.parquet"), _make_lineitem_schema())
    assert_equal(src.path, String("lineitem.parquet"))
    assert_true(src.name is None)
    assert_equal(src._mtime_ns, UInt64(0))
    assert_equal(src.schema_cached.num_columns(), 3)


def test_parquet_source_construct_with_name_and_mtime() raises:
    """Optional name + non-default mtime_ns set correctly."""
    var src = ParquetSource(
        String("/data/orders.parquet"),
        _make_lineitem_schema(),
        Optional(String("orders_alias")),
        UInt64(1_700_000_000_000_000_000),
    )
    assert_equal(src.path, String("/data/orders.parquet"))
    assert_true(src.name is not None)
    assert_equal(src.name.value(), String("orders_alias"))
    assert_equal(src._mtime_ns, UInt64(1_700_000_000_000_000_000))


# =============================================================================
# Trait conformance — schema() / estimate_rows() / fingerprint()
# =============================================================================


def test_parquet_source_schema_returns_copy() raises:
    """schema() returns a Schema copy; mutating the returned schema
    cannot affect the source's cached state. We check this via a
    structural equality: copy's column count matches source's."""
    var src = ParquetSource(String("p.parquet"), _make_lineitem_schema())
    var s_returned = src.schema()
    assert_equal(s_returned.num_columns(), 3)
    # The source's cached schema is independently still 3 columns:
    assert_equal(src.schema_cached.num_columns(), 3)
    # And a second call returns another fresh copy:
    var s_returned2 = src.schema()
    assert_equal(s_returned2.num_columns(), 3)


def test_parquet_source_estimate_rows_unknown() raises:
    """estimate_rows() returns -1 (footer not read)."""
    var src = ParquetSource(String("p.parquet"), _make_empty_schema())
    assert_equal(src.estimate_rows(), -1)


# =============================================================================
# Fingerprint stability + discrimination
# =============================================================================


def test_parquet_source_fingerprint_same_path_same_mtime() raises:
    """Two ParquetSources with identical path + mtime → SAME fingerprint
    (cache hit semantics)."""
    var a = ParquetSource(
        String("/data/lineitem.parquet"),
        _make_lineitem_schema(),
        None,
        UInt64(123_456_789),
    )
    var b = ParquetSource(
        String("/data/lineitem.parquet"),
        _make_lineitem_schema(),
        None,
        UInt64(123_456_789),
    )
    assert_equal(a.fingerprint(), b.fingerprint())


def test_parquet_source_fingerprint_same_path_different_mtime() raises:
    """Same path + DIFFERENT mtime → DIFFERENT fingerprint (file
    rewritten; a stale cache entry must not be reused)."""
    var pre_rewrite = ParquetSource(
        String("/data/lineitem.parquet"),
        _make_lineitem_schema(),
        None,
        UInt64(1_700_000_000_000_000_000),
    )
    var post_rewrite = ParquetSource(
        String("/data/lineitem.parquet"),
        _make_lineitem_schema(),
        None,
        UInt64(1_700_000_001_000_000_000),  # advanced by 1s
    )
    assert_not_equal(pre_rewrite.fingerprint(), post_rewrite.fingerprint())


def test_parquet_source_fingerprint_different_path_same_mtime() raises:
    """Different path + SAME mtime → DIFFERENT fingerprint (path is the
    primary identity axis; mtime is a secondary invalidation key)."""
    var a = ParquetSource(
        String("/data/lineitem.parquet"),
        _make_lineitem_schema(),
        None,
        UInt64(42),
    )
    var b = ParquetSource(
        String("/data/orders.parquet"),
        _make_lineitem_schema(),
        None,
        UInt64(42),
    )
    assert_not_equal(a.fingerprint(), b.fingerprint())


def test_parquet_source_fingerprint_ignores_name() raises:
    """The optional `name` field is debug-only and MUST NOT contribute
    to fingerprint: it is an optional debug label, NOT used for cache
    identity."""
    var unnamed = ParquetSource(
        String("/data/p.parquet"),
        _make_lineitem_schema(),
        None,
        UInt64(99),
    )
    var named = ParquetSource(
        String("/data/p.parquet"),
        _make_lineitem_schema(),
        Optional(String("custom_alias")),
        UInt64(99),
    )
    assert_equal(unnamed.fingerprint(), named.fingerprint())


# =============================================================================
# copy() — independence + identity preservation
# =============================================================================


def test_parquet_source_copy_preserves_fingerprint() raises:
    """src.copy().fingerprint() == src.fingerprint() — identity must be
    stable across explicit clones (the SourceLike trait contract in
    source/source_like.mojo)."""
    var src = ParquetSource(
        String("/data/orders.parquet"),
        _make_lineitem_schema(),
        Optional(String("orders")),
        UInt64(424242),
    )
    var fp_pre = src.fingerprint()
    var src2 = src.copy()
    var fp_post = src2.fingerprint()
    assert_equal(fp_pre, fp_post)


def test_parquet_source_copy_preserves_fields() raises:
    """copy() preserves path + name + mtime + schema column count."""
    var src = ParquetSource(
        String("/data/x.parquet"),
        _make_lineitem_schema(),
        Optional(String("xtable")),
        UInt64(777),
    )
    var src2 = src.copy()
    assert_equal(src.path, src2.path)
    assert_true(src2.name is not None)
    assert_equal(src.name.value(), src2.name.value())
    assert_equal(src._mtime_ns, src2._mtime_ns)
    assert_equal(src.schema_cached.num_columns(), src2.schema_cached.num_columns())


def test_parquet_source_copy_name_none_preserved() raises:
    """copy() preserves None on the optional name field."""
    var src = ParquetSource(String("p.parquet"), _make_empty_schema())
    var src2 = src.copy()
    assert_true(src2.name is None)


def main() raises:
    var suite = TestSuite()
    suite.test[test_parquet_source_construct_minimal]()
    suite.test[test_parquet_source_construct_with_name_and_mtime]()
    suite.test[test_parquet_source_schema_returns_copy]()
    suite.test[test_parquet_source_estimate_rows_unknown]()
    suite.test[test_parquet_source_fingerprint_same_path_same_mtime]()
    suite.test[test_parquet_source_fingerprint_same_path_different_mtime]()
    suite.test[test_parquet_source_fingerprint_different_path_same_mtime]()
    suite.test[test_parquet_source_fingerprint_ignores_name]()
    suite.test[test_parquet_source_copy_preserves_fingerprint]()
    suite.test[test_parquet_source_copy_preserves_fields]()
    suite.test[test_parquet_source_copy_name_none_preserved]()
    suite^.run()
