# =============================================================================
# test_auto_schema.mojo — acceptance test
# =============================================================================
#
# Asserts that a `DerivedSchemaRow`-derived `SchemaDescriptor` matches a
# hand-written `schema_of[...]()` descriptor for the TPC-H Lineitem shape
# (field-name + dtype-tag equality). This is the acceptance gate for the
# ergonomic auto-schema trait — it proves the additive `DerivedSchemaRow`
# option produces a byte-equivalent schema to the canonical hand-written
# builder so the two paths are interchangeable for a flat row struct.
#
# Coverage:
#   - DerivedSchemaRow.schema() field-name + dtype equality vs schema_of
#     for the 5-column Q6 Lineitem shape.
#   - derive_schema[T]() free-function path matches the trait method.
#   - per-scalar dtype dispatch (I8/I16/I32/I64/U*/F32/F64/Bool/String).
#   - definition-order preservation.
#   - strict flag is False (subset-allowed, matching schema_of).
#   - §5 DECIMAL128 via an `Int128` field, with the ARROW half and a control
#     that the arm did not widen. Added 2026-09-22.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false

from komira_sdk.auto_schema import DerivedSchemaRow, derive_schema
from komira_plan_expr.typed_schema import (
    SchemaDescriptor,
    schema_of,
    arrow_type_of,
    Int32Col, Int64Col, Float64Col,
    Int8Col, Int16Col, UInt8Col, UInt16Col, UInt32Col, UInt64Col,
    Float32Col, BoolCol, StringCol, Decimal128Col,
    TYPE_INT32, TYPE_INT64, TYPE_FLOAT64,
    TYPE_INT8, TYPE_INT16, TYPE_UINT8, TYPE_UINT16, TYPE_UINT32, TYPE_UINT64,
    TYPE_FLOAT32, TYPE_BOOL, TYPE_STRING, TYPE_DECIMAL128, TYPE_UNKNOWN,
)
from komira_arrow.arrow_types import ArrowType


# -----------------------------------------------------------------------------
# Row types
# -----------------------------------------------------------------------------


@fieldwise_init
struct Lineitem(DerivedSchemaRow):
    """TPC-H lineitem row — the Q6 column subset."""
    var l_orderkey: Int64
    var l_discount: Float64
    var l_quantity: Float64
    var l_extendedprice: Float64
    var l_shipdate: Int32


@fieldwise_init
struct AllScalars(DerivedSchemaRow):
    """Exercises every dtype dispatch branch in `_dtype_tag_for`."""
    var f_int8val: Int8
    var f_int16val: Int16
    var f_int32val: Int32
    var f_int64val: Int64
    var f_uint8val: UInt8
    var f_uint16val: UInt16
    var f_uint32val: UInt32
    var f_uint64val: UInt64
    var f_flt32val: Float32
    var f_flt64val: Float64
    var f_boolval: Bool
    var f_strval: String


@fieldwise_init
struct DecRow(DerivedSchemaRow):
    """The cross-surface corpus fixture shape at `decimal128_12_2` — `k`, `g`
    and a DECIMAL128 `v` (`plan_matrix_corpus.write_fixture`).

    ⚠ `Int128` IS THE DECLARATION, NOT A WIDENING OF `Int64`. Arrow has no
    int128 primitive; DECIMAL128 is the 16-byte two's-complement integer type
    and `Decimal128Array.get_i128` returns `SIMD[DType.int128, 1]`, so `Int128`
    is this column's storage type in Mojo the same way `Int32` is DATE32's.
    """
    var k: Int64
    var g: Int64
    var v: Int128


@fieldwise_init
struct DecNotWidenedRow(DerivedSchemaRow):
    """★ THE CONTROL FOR §5. A `T == Int128` arm written as a loose numeric
    test would swallow these three, and every §5 assertion would still pass —
    a too-wide arm is invisible from the positive side alone."""
    var a: Int64
    var b: UInt64
    var c: Float64


# -----------------------------------------------------------------------------
# Helper: assert two SchemaDescriptors are name+dtype equal.
# -----------------------------------------------------------------------------


def _assert_schema_eq(
    auto: SchemaDescriptor, hand: SchemaDescriptor
) raises:
    assert_equal(auto.num_cols(), hand.num_cols())
    for i in range(hand.num_cols()):
        assert_equal(auto.cols[i].name, hand.cols[i].name)
        assert_equal(auto.cols[i].dtype, hand.cols[i].dtype)


# -----------------------------------------------------------------------------
# 1) ACCEPTANCE — auto-derived Lineitem schema == hand-written schema_of
# -----------------------------------------------------------------------------


def test_lineitem_auto_matches_handwritten() raises:
    """The headline acceptance assertion: DerivedSchemaRow.schema() for the
    Lineitem struct equals the hand-written schema_of[...] descriptor in both
    field name and dtype tag."""
    var auto = Lineitem.schema()
    var hand = schema_of[
        "l_orderkey", Int64Col,
        "l_discount", Float64Col,
        "l_quantity", Float64Col,
        "l_extendedprice", Float64Col,
        "l_shipdate", Int32Col,
    ]()
    _assert_schema_eq(auto, hand)


def test_lineitem_explicit_columns() raises:
    """Spell out the expected Lineitem columns directly (independent of
    schema_of, in case the builder itself ever drifts)."""
    var s = Lineitem.schema()
    assert_equal(s.num_cols(), 5)
    assert_equal(s.cols[0].name, String("l_orderkey"))
    assert_equal(s.cols[0].dtype, TYPE_INT64)
    assert_equal(s.cols[1].name, String("l_discount"))
    assert_equal(s.cols[1].dtype, TYPE_FLOAT64)
    assert_equal(s.cols[2].name, String("l_quantity"))
    assert_equal(s.cols[2].dtype, TYPE_FLOAT64)
    assert_equal(s.cols[3].name, String("l_extendedprice"))
    assert_equal(s.cols[3].dtype, TYPE_FLOAT64)
    assert_equal(s.cols[4].name, String("l_shipdate"))
    assert_equal(s.cols[4].dtype, TYPE_INT32)


# -----------------------------------------------------------------------------
# 2) trait method == free-function path
# -----------------------------------------------------------------------------


def test_trait_method_matches_derive_schema_fn() raises:
    """`Foo.schema()` (trait default) and `derive_schema[Foo]()` (free fn)
    produce the same descriptor."""
    var via_trait = Lineitem.schema()
    var via_fn = derive_schema[Lineitem]()
    _assert_schema_eq(via_trait, via_fn)


# -----------------------------------------------------------------------------
# 3) every scalar dtype dispatch branch
# -----------------------------------------------------------------------------


def test_all_scalar_dtypes() raises:
    var s = AllScalars.schema()
    assert_equal(s.num_cols(), 12)
    assert_equal(s.cols[0].dtype, TYPE_INT8)
    assert_equal(s.cols[1].dtype, TYPE_INT16)
    assert_equal(s.cols[2].dtype, TYPE_INT32)
    assert_equal(s.cols[3].dtype, TYPE_INT64)
    assert_equal(s.cols[4].dtype, TYPE_UINT8)
    assert_equal(s.cols[5].dtype, TYPE_UINT16)
    assert_equal(s.cols[6].dtype, TYPE_UINT32)
    assert_equal(s.cols[7].dtype, TYPE_UINT64)
    assert_equal(s.cols[8].dtype, TYPE_FLOAT32)
    assert_equal(s.cols[9].dtype, TYPE_FLOAT64)
    assert_equal(s.cols[10].dtype, TYPE_BOOL)
    assert_equal(s.cols[11].dtype, TYPE_STRING)


def test_all_scalars_match_handwritten() raises:
    var auto = AllScalars.schema()
    var hand = schema_of[
        "f_int8val", Int8Col,
        "f_int16val", Int16Col,
        "f_int32val", Int32Col,
        "f_int64val", Int64Col,
        "f_uint8val", UInt8Col,
        "f_uint16val", UInt16Col,
        "f_uint32val", UInt32Col,
        "f_uint64val", UInt64Col,
        "f_flt32val", Float32Col,
        "f_flt64val", Float64Col,
        "f_boolval", BoolCol,
        "f_strval", StringCol,
    ]()
    _assert_schema_eq(auto, hand)


# -----------------------------------------------------------------------------
# 4) definition-order preservation + strict flag
# -----------------------------------------------------------------------------


def test_definition_order_preserved() raises:
    var s = Lineitem.schema()
    var names = String("")
    for i in range(s.num_cols()):
        if i > 0:
            names += ","
        names += s.cols[i].name
    assert_equal(
        names,
        String("l_orderkey,l_discount,l_quantity,l_extendedprice,l_shipdate"),
    )


def test_strict_flag_false() raises:
    """Auto-derived schema is subset-allowed (strict=False), matching
    schema_of (vs schema_of_strict)."""
    var s = Lineitem.schema()
    assert_false(s.strict)


# -----------------------------------------------------------------------------
# 5) ★★ DECIMAL128 — the `Int128` field arm (2026-09-22)
# -----------------------------------------------------------------------------
#
# RED BEFORE THE ARM, measured with a local `mojo run` probe
# over this same struct shape:
#
#     fields: 3
#        k tag= 3 Int64
#        g tag= 3 Int64
#        v tag= -1 Unknown
#     RED: v derives -1 Unknown -- want TYPE_DECIMAL128 = 15
#
# ⛔ AND THE RED WAS NOT A REFUSAL, WHICH IS WHY THIS SECTION ASSERTS THE ARROW
# HALF TOO. `arrow_type_of(TYPE_UNKNOWN)` is `int64` (the function ends in a
# bare `return ArrowType.INT64`), so before the arm this declaration reached
# the footer handshake claiming int64 — refused over a DECIMAL128 footer with a
# message naming a type the caller never wrote, and ADMITTED over an int64 one.
# A test asserting only the tag would go green on a tag that maps to the wrong
# Arrow type.
#
# THE SUBJECT MUTATIONS THAT RED THIS SECTION (2026-09-22, each a one-line edit
# to `auto_schema._dtype_tag_for`, never to this file):
#   M1  the `Int128` arm DELETED            -> 2 FAIL / 9 pass
#   M3  the arm returns TYPE_INT64 instead  -> 2 FAIL / 9 pass
#       (M3 is the answer the old header sentence prescribed — "Decimal columns
#        ... map to the integer tag here" — so this section is precisely the
#        falsifier for the documentation defect, not only for the missing arm.)


def test_decimal128_field_derives_decimal_tag() raises:
    """An `Int128` field derives TYPE_DECIMAL128, not TYPE_UNKNOWN."""
    var s = DecRow.schema()
    assert_equal(s.num_cols(), 3)
    assert_equal(s.cols[0].dtype, TYPE_INT64)
    assert_equal(s.cols[1].dtype, TYPE_INT64)
    assert_equal(s.cols[2].name, String("v"))
    assert_equal(s.cols[2].dtype, TYPE_DECIMAL128)


def test_decimal128_auto_matches_handwritten() raises:
    """THE ACCEPTANCE ASSERTION, in this file's own headline shape: the
    reflected descriptor equals the hand-written `Decimal128Col` one.

    ★ THIS IS THE ONE THAT MATTERS. `Decimal128Col` has existed in
    `typed_schema` since its first version; the defect was that the REFLECTED path had
    no way to reach it, so the two spellings of one schema disagreed. Asserting
    equality against the pre-existing builder is what makes the arm a
    convergence rather than a second convention."""
    var auto = DecRow.schema()
    var hand = schema_of[
        "k", Int64Col,
        "g", Int64Col,
        "v", Decimal128Col,
    ]()
    _assert_schema_eq(auto, hand)


def test_decimal128_tag_maps_to_arrow_decimal128() raises:
    """The ARROW half — the tag must not resolve to an integer Arrow type.

    A decimal read as an integer is a REINTERPRETATION that yields plausible
    numbers (`decimal128(12,2)/40.00` -> `4000`), which is exactly what the
    cross-surface corpus's `decimal128_12_2` column exists to catch."""
    assert_equal(String(arrow_type_of(TYPE_DECIMAL128)),
                 String(ArrowType.DECIMAL128))
    # ⛔ AND THE PRE-FIX PATH, PINNED: an unmapped field type still comes out
    # `int64` here. This is a RECORD of a live hazard, not an endorsement —
    # the day `arrow_type_of` stops defaulting, this line reds and the comment
    # in `auto_schema._dtype_tag_for` has to be retired with it.
    assert_equal(String(arrow_type_of(TYPE_UNKNOWN)),
                 String(ArrowType.INT64))


def test_decimal128_arm_did_not_widen() raises:
    """`Int64` / `UInt64` / `Float64` must keep their own tags.

    ⚠ AND IT IS NOT THE UNIQUE DETECTOR — SAYING SO IS THE POINT. This started
    life labelled "★ THE CONTROL", and the mutation run that was supposed to
    prove that reported otherwise. Measured 2026-09-22 against
    `auto_schema._dtype_tag_for`:

      * M2  `elif (T == Int128 or T == Int64)` — 11/11 STILL PASSED. A VACUOUS
        MUTANT: the `T == Int64` arm sits EARLIER in the same `comptime`
        if/elif chain, so widening the LAST arm is unreachable. A mutation run
        that stopped here would have "proven" a control that proves nothing.
      * M2b the same widening moved to the TOP of the chain — RED, but it reds
        SEVEN tests, `test_all_scalar_dtypes` and
        `test_lineitem_auto_matches_handwritten` among them.

    ⇒ Every widening this function can suffer is already caught by
    `test_all_scalar_dtypes`, which covers all twelve pre-existing arms. This
    test is a LOCAL restatement, kept so a reader of the §5 arm sees the claim
    beside it; it is not additional coverage and must not be cited as such."""
    var s = DecNotWidenedRow.schema()
    assert_equal(s.num_cols(), 3)
    assert_equal(s.cols[0].dtype, TYPE_INT64)
    assert_equal(s.cols[1].dtype, TYPE_UINT64)
    assert_equal(s.cols[2].dtype, TYPE_FLOAT64)
    assert_false(s.cols[0].dtype == TYPE_DECIMAL128)
    assert_false(s.cols[1].dtype == TYPE_DECIMAL128)
    assert_false(s.cols[2].dtype == TYPE_DECIMAL128)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
