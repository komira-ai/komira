# =============================================================================
# Tests for SourceVariant, the tagged union over concrete sources:
#   - Direct-payload storage (NOT Optional[OwnedPointer[T]]).
#   - Inactive arm = `Optional[T] = None` (NOT a pre-allocated
#     empty_default, which would cost an allocation per inactive arm).
#   - Tag-dispatch on `tag` byte; SOURCE_VARIANT_PARQUET=0,
#     SOURCE_VARIANT_IN_MEMORY=1.
#
# Same direct-payload + tag-dispatch shape as `WhenCaseData` and
# `Expr.copy()` in `expr.mojo`.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_true,
    assert_false,
    assert_not_equal,
)

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, RecordBatch, Schema, SchemaBuilder
from komira_arrow.primitive_array import PrimitiveArray
from komira_collections.slab import Slab
from komira_scan_source.parquet_source import ParquetSource
from komira_scan_source.in_memory_source import InMemorySource
from komira_scan_source.source_variant import (
    SourceVariant,
    SOURCE_VARIANT_PARQUET,
    SOURCE_VARIANT_IN_MEMORY,
)


# =============================================================================
# Helpers
# =============================================================================


def _make_1col_int64_schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("c0", ArrowType.INT64, nullable=False))
    return sb.build()


def _make_2col_int64_schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("c0", ArrowType.INT64, nullable=False))
    sb.add_field(Field("c1", ArrowType.INT64, nullable=False))
    return sb.build()


def _build_int64_array(num_rows: Int, seed: Int) -> PrimitiveArray[DType.int64]:
    var vals = List[Int64]()
    for i in range(num_rows):
        vals.append(Int64(seed + i))
    return PrimitiveArray[DType.int64].from_list(vals)


def _build_1col_batch(num_rows: Int, seed: Int) raises -> RecordBatch:
    return RecordBatch.from_columns_1(
        _make_1col_int64_schema(),
        _build_int64_array(num_rows, seed),
    )


def _make_parquet_source(
    path: String,
    mtime_ns: UInt64 = UInt64(0),
) raises -> ParquetSource:
    return ParquetSource(path, _make_1col_int64_schema(), None, mtime_ns)


def _make_in_memory_source(seed: Int = 0) raises -> InMemorySource:
    return InMemorySource.from_record_batch(
        _build_1col_batch(4, seed),
    )


# =============================================================================
# Construction + tag dispatch
# =============================================================================


def test_source_variant_from_parquet() raises:
    """Construct from ParquetSource: tag, kind_name, accessors pass-through."""
    var src = _make_parquet_source(String("/data/lineitem.parquet"), UInt64(42))
    var fp_expected = src.fingerprint()
    var ncols = src.schema().num_columns()
    var v = SourceVariant(src^)
    assert_equal(v.tag, SOURCE_VARIANT_PARQUET)
    assert_equal(v.kind_name(), String("parquet"))
    assert_equal(v.fingerprint(), fp_expected)
    assert_equal(v.schema().num_columns(), ncols)
    assert_equal(v.estimate_rows(), -1)  # ParquetSource returns -1
    # Inactive arm is None:
    assert_true(v._in_memory is None)
    assert_true(v._parquet is not None)


def test_source_variant_from_in_memory() raises:
    """Construct from InMemorySource: tag, kind_name, accessors pass-through."""
    var src = _make_in_memory_source(seed=7)
    var fp_expected = src.fingerprint()
    var rows_expected = src.estimate_rows()
    var v = SourceVariant(src^)
    assert_equal(v.tag, SOURCE_VARIANT_IN_MEMORY)
    assert_equal(v.kind_name(), String("in_memory"))
    assert_equal(v.fingerprint(), fp_expected)
    assert_equal(v.schema().num_columns(), 1)
    assert_equal(v.estimate_rows(), rows_expected)
    assert_equal(v.estimate_rows(), 4)  # _build_1col_batch(4, *)
    # Inactive arm is None:
    assert_true(v._parquet is None)
    assert_true(v._in_memory is not None)


# =============================================================================
# copy() — active-arm-only dispatch + None inactive arm
# =============================================================================


def test_source_variant_copy_parquet_active_arm() raises:
    """copy() on PARQUET-tag variant: only _parquet is deep-cloned;
    _in_memory stays None on both original and clone."""
    var v = SourceVariant(
        _make_parquet_source(String("/data/orders.parquet"), UInt64(123))
    )
    var v2 = v.copy()
    assert_equal(v2.tag, SOURCE_VARIANT_PARQUET)
    assert_true(v2._parquet is not None)
    assert_true(v2._in_memory is None)
    # And the original arm structure unchanged:
    assert_true(v._in_memory is None)
    assert_true(v._parquet is not None)


def test_source_variant_copy_in_memory_active_arm() raises:
    """copy() on IN_MEMORY-tag variant: only _in_memory is refcount-bumped;
    _parquet stays None on both original and clone."""
    var v = SourceVariant(_make_in_memory_source(seed=11))
    var v2 = v.copy()
    assert_equal(v2.tag, SOURCE_VARIANT_IN_MEMORY)
    assert_true(v2._in_memory is not None)
    assert_true(v2._parquet is None)
    assert_true(v._parquet is None)
    assert_true(v._in_memory is not None)


# =============================================================================
# Fingerprint pass-through + stability contracts
# =============================================================================


def test_source_variant_fingerprint_matches_parquet_inner() raises:
    """SourceVariant.fingerprint() == wrapped ParquetSource.fingerprint()."""
    var p = _make_parquet_source(String("/data/x.parquet"), UInt64(99))
    var inner_fp = p.fingerprint()
    var v = SourceVariant(p^)
    assert_equal(v.fingerprint(), inner_fp)


def test_source_variant_fingerprint_matches_in_memory_inner() raises:
    """SourceVariant.fingerprint() == wrapped InMemorySource.fingerprint()."""
    var s = _make_in_memory_source(seed=3)
    var inner_fp = s.fingerprint()
    var v = SourceVariant(s^)
    assert_equal(v.fingerprint(), inner_fp)


def test_source_variant_schema_matches_inner() raises:
    """schema() pass-through: column count + Field names match the
    wrapped source's schema for both kinds."""
    var v_pq = SourceVariant(
        ParquetSource(
            String("/data/multi.parquet"),
            _make_2col_int64_schema(),
        )
    )
    var sch_pq = v_pq.schema()
    assert_equal(sch_pq.num_columns(), 2)

    var v_im = SourceVariant(
        InMemorySource.from_record_batch(
            _build_1col_batch(2, 0),
        )
    )
    var sch_im = v_im.schema()
    assert_equal(sch_im.num_columns(), 1)


def test_source_variant_estimate_rows_matches_inner() raises:
    """estimate_rows() pass-through: -1 for parquet, exact for
    in-memory (sum of per-batch row counts)."""
    var v_pq = SourceVariant(_make_parquet_source(String("/d/p.parquet")))
    assert_equal(v_pq.estimate_rows(), -1)

    var batches = Slab[RecordBatch]()
    batches.append(_build_1col_batch(5, 0))
    batches.append(_build_1col_batch(7, 100))
    var v_im = SourceVariant(
        InMemorySource.from_record_batches(
            batches^,
        )
    )
    assert_equal(v_im.estimate_rows(), 12)


# =============================================================================
# Move + copy fingerprint stability (cache discrimination)
# =============================================================================


def test_source_variant_fingerprint_stable_across_move() raises:
    """Cache-discrimination contract: fingerprint is stable
    across `value^` move for both kinds."""
    # Parquet:
    var vp = SourceVariant(
        _make_parquet_source(String("/data/move.parquet"), UInt64(55))
    )
    var fp_pre_p = vp.fingerprint()
    var vp2 = vp^
    assert_equal(fp_pre_p, vp2.fingerprint())

    # InMemory:
    var vi = SourceVariant(_make_in_memory_source(seed=22))
    var fp_pre_i = vi.fingerprint()
    var vi2 = vi^
    assert_equal(fp_pre_i, vi2.fingerprint())


def test_source_variant_fingerprint_stable_across_copy() raises:
    """copy() preserves fingerprint (delegates to inner .copy() which
    preserves identity per the ParquetSource + InMemorySource contracts)."""
    # Parquet:
    var vp = SourceVariant(
        _make_parquet_source(String("/data/cp.parquet"), UInt64(7))
    )
    var fp_p = vp.fingerprint()
    var vp_clone = vp.copy()
    assert_equal(fp_p, vp_clone.fingerprint())

    # InMemory (refcount-bump preserves _identity):
    var vi = SourceVariant(_make_in_memory_source(seed=33))
    var fp_i = vi.fingerprint()
    var vi_clone = vi.copy()
    assert_equal(fp_i, vi_clone.fingerprint())


# =============================================================================
# Discrimination — distinct sources yield distinct fingerprints
# =============================================================================


def test_source_variant_different_parquet_sources_distinct() raises:
    """Two SourceVariants wrapping different ParquetSources (distinct
    paths) yield distinct fingerprints."""
    var a = SourceVariant(_make_parquet_source(String("/data/a.parquet")))
    var b = SourceVariant(_make_parquet_source(String("/data/b.parquet")))
    assert_not_equal(a.fingerprint(), b.fingerprint())


def test_source_variant_different_in_memory_sources_distinct() raises:
    """Two SourceVariants wrapping different InMemorySources (distinct
    Arc payloads + monotonic ns) yield distinct fingerprints."""
    var a = SourceVariant(_make_in_memory_source(seed=1))
    var b = SourceVariant(_make_in_memory_source(seed=2))
    assert_not_equal(a.fingerprint(), b.fingerprint())


def test_source_variant_cross_kind_fingerprints_distinct() raises:
    """ParquetSource and InMemorySource compute fingerprints over
    structurally disjoint inputs — even with similar surface inputs the
    resulting hashes must differ. (path hash vs Arc-addr hash mixing is
    deterministically distinct unless catastrophic coincidence.)"""
    var v_pq = SourceVariant(
        _make_parquet_source(String("/data/shared_name"), UInt64(0))
    )
    var v_im = SourceVariant(_make_in_memory_source(seed=0))
    assert_not_equal(v_pq.fingerprint(), v_im.fingerprint())


# =============================================================================
# Copyable container interop — Movable + Copyable contract
# =============================================================================


def test_source_variant_movable_into_list() raises:
    """SourceVariant is Copyable + Movable, so List[SourceVariant] is
    valid (List[T] requires T: Copyable). Validates the
    `(Movable, Copyable, Deinitable)` trait declaration."""
    var lst = List[SourceVariant]()
    lst.append(SourceVariant(_make_parquet_source(String("/d/a.parquet"))))
    lst.append(SourceVariant(_make_in_memory_source(seed=5)))
    assert_equal(len(lst), 2)
    assert_equal(lst[0].tag, SOURCE_VARIANT_PARQUET)
    assert_equal(lst[1].tag, SOURCE_VARIANT_IN_MEMORY)
    # Accessor still works after stored-in-list:
    assert_equal(lst[0].kind_name(), String("parquet"))
    assert_equal(lst[1].kind_name(), String("in_memory"))


# =============================================================================
# Suite
# =============================================================================


def main() raises:
    var suite = TestSuite()
    # Construction + tag dispatch
    suite.test[test_source_variant_from_parquet]()
    suite.test[test_source_variant_from_in_memory]()
    # copy() active-arm
    suite.test[test_source_variant_copy_parquet_active_arm]()
    suite.test[test_source_variant_copy_in_memory_active_arm]()
    # Fingerprint pass-through
    suite.test[test_source_variant_fingerprint_matches_parquet_inner]()
    suite.test[test_source_variant_fingerprint_matches_in_memory_inner]()
    suite.test[test_source_variant_schema_matches_inner]()
    suite.test[test_source_variant_estimate_rows_matches_inner]()
    # Move + copy stability
    suite.test[test_source_variant_fingerprint_stable_across_move]()
    suite.test[test_source_variant_fingerprint_stable_across_copy]()
    # Discrimination
    suite.test[test_source_variant_different_parquet_sources_distinct]()
    suite.test[test_source_variant_different_in_memory_sources_distinct]()
    suite.test[test_source_variant_cross_kind_fingerprints_distinct]()
    # Container interop
    suite.test[test_source_variant_movable_into_list]()
    suite^.run()
