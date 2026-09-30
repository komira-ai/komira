# =============================================================================
# Tests for the SourceLike trait + ScalarValue Decimal128/Date32/Timestamp
# variants + PrecisionScalar three-valued lattice:
#
#   - SourceLike trait shape (schema/estimate_rows/fingerprint) compiles +
#     a stub struct that conforms can be type-checked.
#   - ScalarValue.decimal128 / date32 / timestamp_micros constructors work
#     + round-trip equality.
#   - PrecisionScalar.exact / inexact / absent factories work; is_exact /
#     is_inexact / is_absent / is_present discriminate correctly.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.source.source_like import SourceLike
from komira_core.plan.scalar_value import ScalarValue
from komira_core.plan.precision_scalar import (
    PrecisionScalar,
    PRECISION_EXACT,
    PRECISION_INEXACT,
    PRECISION_ABSENT,
)
from komira_core.arrow import Schema, SchemaBuilder


# =============================================================================
# SourceLike trait conformance — stub source that implements the trait.
# Verifies the trait can be imported AND the three required methods can
# be implemented (compile-time conformance check).
# =============================================================================

struct _StubSource(SourceLike, Movable, Copyable, Deinitable):
    var _row_estimate: Int
    var _fp: UInt64

    def __init__(out self, row_estimate: Int, fp: UInt64):
        self._row_estimate = row_estimate
        self._fp = fp

    def copy(self) -> Self:
        return Self(self._row_estimate, self._fp)

    def schema(self) -> Schema:
        # Empty schema is a legal Schema value (zero fields). Sufficient
        # for the trait-conformance compile-check; payload not asserted.
        var sb = SchemaBuilder()
        return sb.build()

    def estimate_rows(self) -> Int:
        return self._row_estimate

    def fingerprint(self) -> UInt64:
        return self._fp


def test_source_like_trait_importable() raises:
    """SourceLike trait + a stub conforming impl compile + can be
    constructed + each method is callable."""
    var src = _StubSource(row_estimate=42, fp=UInt64(0xDEADBEEF))
    # estimate_rows
    assert_equal(src.estimate_rows(), 42)
    # fingerprint
    assert_equal(src.fingerprint(), UInt64(0xDEADBEEF))
    # schema — just check it returns something callable; payload empty
    var s = src.schema()
    assert_equal(s.num_columns(), 0)


def test_source_like_fingerprint_stable_across_copy() raises:
    """fingerprint() returns the same value after .copy() — trait contract
    (cache discrimination requires stable identity across moves)."""
    var src = _StubSource(row_estimate=100, fp=UInt64(0xCAFE))
    var fp_pre = src.fingerprint()
    var src2 = src.copy()
    var fp_post = src2.fingerprint()
    assert_equal(fp_pre, fp_post)


# =============================================================================
# ScalarValue Decimal128 / Date32 / Timestamp variants.
# =============================================================================

def test_scalar_value_decimal128_roundtrip() raises:
    """ScalarValue.decimal128 stores high+low Int64 and is_decimal128
    discriminates correctly."""
    var sv = ScalarValue.decimal128(Int64(0x12345678), Int64(0x0BADF00D))
    assert_true(sv.is_decimal128())
    assert_false(sv.is_int())
    assert_false(sv.is_float())
    assert_false(sv.is_string())
    assert_false(sv.is_bool())
    assert_false(sv.is_null())
    assert_false(sv.is_date32())
    assert_false(sv.is_timestamp())
    assert_equal(sv.dec128_high, Int64(0x12345678))
    assert_equal(sv.dec128_low, Int64(0x0BADF00D))
    # Round-trip via __eq__
    var sv2 = ScalarValue.decimal128(Int64(0x12345678), Int64(0x0BADF00D))
    assert_true(sv == sv2)
    # Distinct payload -> not equal
    var sv3 = ScalarValue.decimal128(Int64(0x12345678), Int64(0))
    assert_true(sv != sv3)


def test_scalar_value_date32_roundtrip() raises:
    """ScalarValue.date32 stores days since epoch."""
    var sv = ScalarValue.date32(Int32(19488))  # days since 1970-01-01
    assert_true(sv.is_date32())
    assert_false(sv.is_decimal128())
    assert_false(sv.is_timestamp())
    assert_equal(Int(sv.date32_val), 19488)
    # Round-trip via __eq__
    var sv2 = ScalarValue.date32(Int32(19488))
    assert_true(sv == sv2)
    var sv3 = ScalarValue.date32(Int32(0))
    assert_true(sv != sv3)


def test_scalar_value_timestamp_micros_roundtrip() raises:
    """ScalarValue.timestamp_micros stores micros since epoch."""
    var sv = ScalarValue.timestamp_micros(Int64(1_700_000_000_000_000))
    assert_true(sv.is_timestamp())
    assert_false(sv.is_decimal128())
    assert_false(sv.is_date32())
    assert_equal(sv.ts_micros, Int64(1_700_000_000_000_000))
    # Round-trip via __eq__
    var sv2 = ScalarValue.timestamp_micros(Int64(1_700_000_000_000_000))
    assert_true(sv == sv2)
    var sv3 = ScalarValue.timestamp_micros(Int64(0))
    assert_true(sv != sv3)


def test_scalar_value_legacy_variants_still_work() raises:
    """The decimal/date/timestamp fields don't break int/float/string/bool/null
    discrimination."""
    var int_v = ScalarValue.from_int(7)
    assert_true(int_v.is_int())
    assert_false(int_v.is_decimal128())
    var fl = ScalarValue.from_float(3.14)
    assert_true(fl.is_float())
    assert_false(fl.is_date32())
    var s = ScalarValue.from_string(String("hello"))
    assert_true(s.is_string())
    assert_false(s.is_timestamp())
    var b = ScalarValue.from_bool(True)
    assert_true(b.is_bool())
    # Default-constructed ScalarValue (no factory) is the untyped-null.
    # `ScalarValue.null(dt)` is a NULL for EVERY dtype (is_null() True,
    # is_int() False) — the
    # declared type is preserved via null_type(), not the dtype field.
    var n = ScalarValue()
    assert_true(n.is_null())
    assert_true(ScalarValue.null(DType.int64).is_null())
    assert_false(ScalarValue.null(DType.int64).is_int())


def test_scalar_value_copy_preserves_typed_fields() raises:
    """ScalarValue.copy() must preserve the decimal/date/timestamp fields (decimal128
    high/low, date32, timestamp micros, _kind)."""
    var sv = ScalarValue.decimal128(Int64(111), Int64(222))
    var sv2 = sv.copy()
    assert_true(sv2.is_decimal128())
    assert_equal(sv2.dec128_high, Int64(111))
    assert_equal(sv2.dec128_low, Int64(222))

    var dt = ScalarValue.date32(Int32(20000))
    var dt2 = dt.copy()
    assert_true(dt2.is_date32())
    assert_equal(Int(dt2.date32_val), 20000)

    var ts = ScalarValue.timestamp_micros(Int64(999_999))
    var ts2 = ts.copy()
    assert_true(ts2.is_timestamp())
    assert_equal(ts2.ts_micros, Int64(999_999))


# =============================================================================
# PrecisionScalar lattice.
# =============================================================================

def test_precision_scalar_exact() raises:
    """PrecisionScalar.exact(v) is EXACT + present + holds the inner value."""
    var ps = PrecisionScalar.exact(ScalarValue.from_int(42))
    assert_true(ps.is_exact())
    assert_false(ps.is_inexact())
    assert_false(ps.is_absent())
    assert_true(ps.is_present())
    assert_equal(ps.tag, PRECISION_EXACT)
    assert_true(ps.value is not None)
    assert_equal(Int(ps.value.value().int_val), 42)


def test_precision_scalar_inexact() raises:
    """PrecisionScalar.inexact(v) is INEXACT + present + holds the inner value."""
    var ps = PrecisionScalar.inexact(ScalarValue.from_int(99))
    assert_false(ps.is_exact())
    assert_true(ps.is_inexact())
    assert_false(ps.is_absent())
    assert_true(ps.is_present())
    assert_equal(ps.tag, PRECISION_INEXACT)
    assert_true(ps.value is not None)
    assert_equal(Int(ps.value.value().int_val), 99)


def test_precision_scalar_absent() raises:
    """PrecisionScalar.absent() is ABSENT + not present + value is None."""
    var ps = PrecisionScalar.absent()
    assert_false(ps.is_exact())
    assert_false(ps.is_inexact())
    assert_true(ps.is_absent())
    assert_false(ps.is_present())
    assert_equal(ps.tag, PRECISION_ABSENT)
    assert_true(ps.value is None)


def test_precision_scalar_copy() raises:
    """PrecisionScalar.copy() preserves tag + deep-copies the inner ScalarValue."""
    var ps = PrecisionScalar.exact(ScalarValue.from_string(String("snow")))
    var ps2 = ps.copy()
    assert_true(ps2.is_exact())
    assert_true(ps2.value is not None)
    assert_equal(ps2.value.value().string_val, String("snow"))

    var ab = PrecisionScalar.absent()
    var ab2 = ab.copy()
    assert_true(ab2.is_absent())
    assert_true(ab2.value is None)


def test_precision_scalar_decimal128_payload() raises:
    """PrecisionScalar composes with the decimal/date/timestamp ScalarValue variants —
    EXACT over Decimal128 is the load-bearing case for ColumnStats."""
    var ps = PrecisionScalar.exact(ScalarValue.decimal128(Int64(1), Int64(2)))
    assert_true(ps.is_exact())
    var inner = ps.value.value().copy()
    assert_true(inner.is_decimal128())
    assert_equal(inner.dec128_high, Int64(1))
    assert_equal(inner.dec128_low, Int64(2))


def main() raises:
    var suite = TestSuite()
    suite.test[test_source_like_trait_importable]()
    suite.test[test_source_like_fingerprint_stable_across_copy]()
    suite.test[test_scalar_value_decimal128_roundtrip]()
    suite.test[test_scalar_value_date32_roundtrip]()
    suite.test[test_scalar_value_timestamp_micros_roundtrip]()
    suite.test[test_scalar_value_legacy_variants_still_work]()
    suite.test[test_scalar_value_copy_preserves_typed_fields]()
    suite.test[test_precision_scalar_exact]()
    suite.test[test_precision_scalar_inexact]()
    suite.test[test_precision_scalar_absent]()
    suite.test[test_precision_scalar_copy]()
    suite.test[test_precision_scalar_decimal128_payload]()
    suite^.run()
