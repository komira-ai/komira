# =============================================================================
# Arrow INTERVAL_MONTH_DAY_NANO Tier-2 compute tests
# =============================================================================
#
# Covers:
#   * 16-byte packed (months, days, nanos) round-trip through the
#     IntervalMonthDayNanoArray <-> Column boundary.
#   * Equality kernel — componentwise (well-defined per Arrow spec).
#   * Hash kernel — FNV-1a over the 16-byte slab.
#   * Take / Filter kernels — byte-slab gather/select.
#   * Lex-less-than — deterministic but NOT semantic time-order (verified).
#   * Regression: `copy_column` / `element_size` must not silently
#     truncate 16-byte INTERVAL_MDN rows to 8 bytes.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.interval_mdn_array import IntervalMonthDayNanoArray, INTERVAL_MDN_BYTE_WIDTH
from komira_arrow.schema import RecordBatch, RecordBatchBuilder, Schema, SchemaBuilder, Field
from komira_column_kernels.interval_mdn_kernels import (
    eval_eq_interval_mdn,
    eval_eq_interval_mdn_scalar,
    hash_interval_mdn,
    hash_one_interval_mdn,
    take_interval_mdn,
    filter_interval_mdn,
    lex_lt_interval_mdn,
    lex_lt_one_interval_mdn,
)
from komira_arrow.bitmap import Bitmap


def _triples() -> List[Tuple[Int32, Int32, Int64]]:
    """A small fixture of distinct (months, days, nanos) triples."""
    return [
        (Int32(0), Int32(0), Int64(0)),
        (Int32(1), Int32(0), Int64(0)),         # 1 month
        (Int32(0), Int32(31), Int64(0)),        # 31 days — NOT == 1 month
        (Int32(0), Int32(0), Int64(86_400_000_000_000)),  # 1 day worth of ns
        (Int32(-3), Int32(7), Int64(-1_000)),   # negative components, mixed signs
        (Int32(12), Int32(0), Int64(0)),        # 1 year
    ]


# --- Construction & accessors ------------------------------------------------


def test_interval_mdn_allocate_zero_initialized() raises:
    """A freshly allocated array is zero-initialized."""
    var arr = IntervalMonthDayNanoArray.allocate(4)
    assert_equal(arr.length, 4)
    for i in range(4):
        assert_equal(Int(arr.get_months(i)), 0)
        assert_equal(Int(arr.get_days(i)), 0)
        assert_equal(Int(arr.get_nanos(i)), 0)


def test_interval_mdn_from_triples_get_back() raises:
    """from_triples preserves all three components per row."""
    var arr = IntervalMonthDayNanoArray.from_triples(_triples())
    assert_equal(arr.length, 6)
    # row 1 = (1, 0, 0)
    assert_equal(Int(arr.get_months(1)), 1)
    assert_equal(Int(arr.get_days(1)), 0)
    assert_equal(Int(arr.get_nanos(1)), 0)
    # row 2 = (0, 31, 0) — distinct from row 1's (1, 0, 0)
    assert_equal(Int(arr.get_months(2)), 0)
    assert_equal(Int(arr.get_days(2)), 31)
    # row 3 = (0, 0, 86_400_000_000_000)
    assert_equal(Int(arr.get_nanos(3)), 86_400_000_000_000)
    # row 4 has negative components + mixed signs
    assert_equal(Int(arr.get_months(4)), -3)
    assert_equal(Int(arr.get_days(4)), 7)
    assert_equal(Int(arr.get_nanos(4)), -1_000)


def test_interval_mdn_set_triple_individual() raises:
    """set_triple writes the components and re-reads them correctly."""
    var arr = IntervalMonthDayNanoArray.allocate(3)
    arr.set_triple(0, Int32(5), Int32(10), Int64(15))
    arr.set_triple(1, Int32(-1), Int32(0), Int64(0))
    arr.set_triple(2, Int32(0), Int32(0), Int64(-9_999_999_999))
    var t0 = arr.get_triple(0)
    assert_equal(Int(t0[0]), 5)
    assert_equal(Int(t0[1]), 10)
    assert_equal(Int(t0[2]), 15)
    var t2 = arr.get_triple(2)
    assert_equal(Int(t2[2]), -9_999_999_999)


def test_interval_mdn_nullability() raises:
    """allocate_nullable + set_null marks the slot as null."""
    var arr = IntervalMonthDayNanoArray.allocate_nullable(3)
    assert_false(arr.is_null(0))
    arr.set_null(1)
    assert_true(arr.is_null(1))
    assert_false(arr.is_null(0))
    assert_equal(arr.null_count, 1)


# --- Column round-trip -------------------------------------------------------


def test_interval_mdn_column_round_trip() raises:
    """Column.from_interval_mdn -> as_interval_mdn preserves all triples
    AND the arrow_type tag."""
    var arr = IntervalMonthDayNanoArray.from_triples(_triples())
    var col = Column.from_interval_mdn(arr^)
    assert_equal(col.arrow_type, ArrowType.INTERVAL_MONTH_DAY_NANO)
    assert_equal(col.length(), 6)
    var back = col.as_interval_mdn()
    assert_equal(back.length, 6)
    var srcs = _triples()
    for i in range(6):
        var t = back.get_triple(i)
        var s = srcs[i]
        assert_equal(Int(t[0]), Int(s[0]), "row " + String(i) + " months")
        assert_equal(Int(t[1]), Int(s[1]), "row " + String(i) + " days")
        assert_equal(Int(t[2]), Int(s[2]), "row " + String(i) + " nanos")


# --- Bug I regression: copy_column / element_size at 16 bytes ----------------


def test_interval_mdn_copy_column_bug_i_regression() raises:
    """Pre-Bug-I-fix: `copy_column` fell through `element_size()` returning
    8 for INTERVAL_MDN, silently truncating each 16-byte row to 8 bytes —
    rows 0..N would carry the first 8 bytes (months + days) but lose the
    last 8 (nanos), and the destination buffer would be half-sized.

    Post-fix: every row's nanos component survives the copy.  Verified by
    using a triple with a NON-ZERO nanos value, then running the column
    through `copy_column` (the canonical helper used by gather_batch,
    join row-build, batch-slice, etc.) and reading the triple back.
    """
    # Build a 1-column batch with INTERVAL_MDN data — the nanos value is
    # what disappears under the 8-byte-truncation bug.
    var arr = IntervalMonthDayNanoArray.from_triples(_triples())
    var col = Column.from_interval_mdn(arr^)
    var sb = SchemaBuilder()
    sb.add_field(Field("ts", ArrowType.INTERVAL_MONTH_DAY_NANO, True))
    var sch = sb.build()
    var bb = RecordBatchBuilder()
    bb.add_column(col^)
    var batch = bb.build(sch^)

    # Invoke `copy_column` via the public helper.  This is the same call
    # path used by gather_batch / project_batch / empty_batch_like.
    from komira_column_kernels.compiler_helpers import copy_column

    var copied = copy_column(batch, 0)
    assert_equal(copied.arrow_type, ArrowType.INTERVAL_MONTH_DAY_NANO)
    assert_equal(copied.length(), 6)

    # If element_size returned 8, the copied buffer would be 6*8 = 48 bytes
    # and as_interval_mdn (which reads 6*16 = 96 bytes) would either fault
    # or return garbage.  Verify all three components survive.
    var back = copied.as_interval_mdn()
    var srcs = _triples()
    for i in range(6):
        var t = back.get_triple(i)
        var s = srcs[i]
        assert_equal(Int(t[0]), Int(s[0]), "BUG I months row " + String(i))
        assert_equal(Int(t[1]), Int(s[1]), "BUG I days row " + String(i))
        assert_equal(Int(t[2]), Int(s[2]), "BUG I NANOS row " + String(i))


# --- Equality kernel ---------------------------------------------------------


def test_eval_eq_interval_mdn_componentwise() raises:
    """eval_eq_interval_mdn returns a mask True iff all three components
    match.  Crucially, (1 month, 0 days, 0 ns) != (0 months, 31 days, 0 ns)
    — both are "approximately 1 month" but they are NOT componentwise equal,
    and Arrow's equality is componentwise."""
    var a = IntervalMonthDayNanoArray.from_triples(_triples())
    var b_triples: List[Tuple[Int32, Int32, Int64]] = [
        (Int32(0), Int32(0), Int64(0)),        # eq row 0
        (Int32(1), Int32(0), Int64(0)),        # eq row 1
        (Int32(1), Int32(0), Int64(0)),        # NOT eq row 2 (0,31,0) — different
        (Int32(0), Int32(0), Int64(86_400_000_000_000)),  # eq row 3
        (Int32(-3), Int32(7), Int64(-1_001)),  # NOT eq — nanos differ by 1
        (Int32(12), Int32(0), Int64(0)),       # eq row 5
    ]
    var b = IntervalMonthDayNanoArray.from_triples(b_triples)
    var mask = eval_eq_interval_mdn(a, b)
    assert_equal(mask.length, 6)
    assert_true(Bool(mask.test(0)))
    assert_true(Bool(mask.test(1)))
    assert_false(Bool(mask.test(2)), "(1,0,0) != (0,31,0) — componentwise")
    assert_true(Bool(mask.test(3)))
    assert_false(Bool(mask.test(4)), "1 ns differ")
    assert_true(Bool(mask.test(5)))


def test_eval_eq_interval_mdn_scalar() raises:
    """Per-row equality against a constant triple."""
    var a = IntervalMonthDayNanoArray.from_triples(_triples())
    var mask = eval_eq_interval_mdn_scalar(a, Int32(0), Int32(0), Int64(0))
    # Only row 0 has the all-zero triple.
    assert_true(Bool(mask.test(0)))
    assert_false(Bool(mask.test(1)))
    assert_false(Bool(mask.test(2)))


def test_eval_eq_interval_mdn_with_nulls() raises:
    """Equality respects validity bitmaps (null compares unequal)."""
    var a_triples: List[Tuple[Int32, Int32, Int64]] = [
        (Int32(1), Int32(2), Int64(3)),
        (Int32(0), Int32(0), Int64(0)),
    ]
    var a = IntervalMonthDayNanoArray.from_triples(a_triples)
    # Make a nullable copy of a, mark row 1 null.
    var b = IntervalMonthDayNanoArray.allocate_nullable(2)
    b.set_triple(0, Int32(1), Int32(2), Int64(3))
    b.set_triple(1, Int32(0), Int32(0), Int64(0))
    b.set_null(1)
    var mask = eval_eq_interval_mdn(a, b)
    assert_true(Bool(mask.test(0)))
    assert_false(Bool(mask.test(1)), "null != non-null")


# --- Hash kernel -------------------------------------------------------------


def test_hash_one_interval_mdn_basic() raises:
    """Same triple hashes to same value; distinct triples hash distinct."""
    var h1 = hash_one_interval_mdn(Int32(1), Int32(0), Int64(0))
    var h2 = hash_one_interval_mdn(Int32(1), Int32(0), Int64(0))
    var h3 = hash_one_interval_mdn(Int32(0), Int32(31), Int64(0))
    assert_equal(h1, h2)
    assert_true(h1 != h3, "1 month should hash != 31 days")


def test_hash_interval_mdn_includes_all_three_fields() raises:
    """Hash depends on each of the three fields independently — verified
    by perturbing one field at a time and checking the hash changes."""
    var base = hash_one_interval_mdn(Int32(5), Int32(10), Int64(15))
    var months_perturbed = hash_one_interval_mdn(Int32(6), Int32(10), Int64(15))
    var days_perturbed = hash_one_interval_mdn(Int32(5), Int32(11), Int64(15))
    var nanos_perturbed = hash_one_interval_mdn(Int32(5), Int32(10), Int64(16))
    assert_true(base != months_perturbed, "hash should depend on months")
    assert_true(base != days_perturbed, "hash should depend on days")
    assert_true(base != nanos_perturbed, "hash should depend on nanos")


def test_hash_interval_mdn_array() raises:
    """hash_interval_mdn returns one UInt64 per row; nulls hash to 0."""
    var arr = IntervalMonthDayNanoArray.allocate_nullable(3)
    arr.set_triple(0, Int32(1), Int32(2), Int64(3))
    arr.set_triple(1, Int32(1), Int32(2), Int64(3))
    arr.set_triple(2, Int32(0), Int32(0), Int64(0))
    arr.set_null(2)
    var hashes = hash_interval_mdn(arr)
    assert_equal(len(hashes), 3)
    assert_equal(hashes[0], hashes[1], "identical triples hash identical")
    assert_equal(hashes[2], UInt64(0), "null hashes to 0")


# --- Take + Filter kernels ---------------------------------------------------


def test_take_interval_mdn_indices() raises:
    """take_interval_mdn gathers selected rows preserving the 16-byte slab."""
    var arr = IntervalMonthDayNanoArray.from_triples(_triples())
    var indices: List[Int] = [5, 0, 3, 4]
    var out = take_interval_mdn(arr, indices)
    assert_equal(out.length, 4)
    # row 0 of output = source row 5 = (12, 0, 0)
    assert_equal(Int(out.get_months(0)), 12)
    assert_equal(Int(out.get_days(0)), 0)
    assert_equal(Int(out.get_nanos(0)), 0)
    # row 2 of output = source row 3 = (0, 0, 86_400_000_000_000)
    assert_equal(Int(out.get_nanos(2)), 86_400_000_000_000)
    # row 3 of output = source row 4 = (-3, 7, -1_000) — mixed-sign survives
    assert_equal(Int(out.get_months(3)), -3)
    assert_equal(Int(out.get_nanos(3)), -1_000)


def test_filter_interval_mdn_mask() raises:
    """filter_interval_mdn applies a Bitmap mask and packs the survivors."""
    var arr = IntervalMonthDayNanoArray.from_triples(_triples())
    var mask = Bitmap.create(6)
    mask.set(1)  # 1 month
    mask.set(2)  # 31 days
    mask.set(5)  # 1 year
    var out = filter_interval_mdn(arr, mask)
    assert_equal(out.length, 3)
    assert_equal(Int(out.get_months(0)), 1)
    assert_equal(Int(out.get_days(1)), 31)
    assert_equal(Int(out.get_months(2)), 12)


def test_take_with_nulls() raises:
    """take preserves null status from the source rows."""
    var arr = IntervalMonthDayNanoArray.allocate_nullable(3)
    arr.set_triple(0, Int32(1), Int32(2), Int64(3))
    arr.set_triple(1, Int32(4), Int32(5), Int64(6))
    arr.set_null(1)
    var indices: List[Int] = [0, 1, 0]
    var out = take_interval_mdn(arr, indices)
    assert_equal(out.length, 3)
    assert_false(out.is_null(0))
    assert_true(out.is_null(1), "source[1] was null -> out[1] null")
    assert_false(out.is_null(2))


# --- Lex-lt kernel (deterministic, NOT semantic) -----------------------------


def test_lex_lt_one_interval_mdn_examples() raises:
    """Lex order: months > days > nanos.  WARNING — not calendar order."""
    # (0, 0, 0) < (1, 0, 0)
    assert_true(lex_lt_one_interval_mdn(
        Int32(0), Int32(0), Int64(0), Int32(1), Int32(0), Int64(0)
    ))
    # (1, 0, 0) < (1, 1, 0)
    assert_true(lex_lt_one_interval_mdn(
        Int32(1), Int32(0), Int64(0), Int32(1), Int32(1), Int64(0)
    ))
    # (1, 0, 0) > (0, 31, 0) under LEX  — but semantically "1 month" vs
    # "31 days" is calendar-dependent.  Documenting that lex is not
    # semantic time-order is the point of this test.
    assert_false(lex_lt_one_interval_mdn(
        Int32(1), Int32(0), Int64(0), Int32(0), Int32(31), Int64(0)
    ))
    # (0, 31, 0) < (1, 0, 0) under LEX
    assert_true(lex_lt_one_interval_mdn(
        Int32(0), Int32(31), Int64(0), Int32(1), Int32(0), Int64(0)
    ))


def test_lex_lt_interval_mdn_per_row() raises:
    """Per-row lex less-than — useful for stable sort-merge tie-breaks."""
    var a_triples: List[Tuple[Int32, Int32, Int64]] = [
        (Int32(0), Int32(0), Int64(0)),
        (Int32(5), Int32(0), Int64(0)),
        (Int32(0), Int32(31), Int64(0)),
    ]
    var b_triples: List[Tuple[Int32, Int32, Int64]] = [
        (Int32(0), Int32(0), Int64(1)),   # (0,0,0) < (0,0,1)
        (Int32(5), Int32(0), Int64(0)),   # equal — !<
        (Int32(1), Int32(0), Int64(0)),   # (0,31,0) < (1,0,0) under lex
    ]
    var a = IntervalMonthDayNanoArray.from_triples(a_triples)
    var b = IntervalMonthDayNanoArray.from_triples(b_triples)
    var mask = lex_lt_interval_mdn(a, b)
    assert_true(Bool(mask.test(0)))
    assert_false(Bool(mask.test(1)))
    assert_true(Bool(mask.test(2)))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
