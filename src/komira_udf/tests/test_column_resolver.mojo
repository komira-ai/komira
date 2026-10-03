# =============================================================================
# Tests for column_resolver.mojo.
#
# Source: komira_udf.column_resolver
#
# Coverage:
#   1. Empty resolver — len()=0, has("x")=False, index_for("x") raises
#   2. Explicit ctor — round-trip names/indices/dtypes
#   3. Explicit ctor — mismatched-length raises (names vs indices, names vs
#      dtypes)
#   4. from_arrow_schema — build from a synthetic 4-col Schema; verify all 4
#      names -> correct indices
#   5. index_for hit — returns correct Int
#   6. index_for miss — raises with the helpful error message (must include
#      the missing name + the full available-names list)
#   7. dtype_for matches the file's declared DType
#   8. has() returns Bool correctly for hit + miss
#   9. DType "defensive" test — dtype_for returns the FILE's DType; the bind
#      pass is responsible for comparing to the expected typed-Expr DType.
#      Here we just confirm the resolver round-trips an F64 vs an I64 vs an
#      I32 vs a Bool faithfully on the same multi-DType schema.
#
# Round 2c addendum: ColumnResolver also
# carries per-column ArrowType because DType loses info for STRING /
# DECIMAL128 / DATE32 / TIMESTAMP-with-tz / DICTIONARY / nested types (all
# of those collapse to `DTYPE_NONE`). Tests 10-13 cover the ArrowType
# layer including the load-bearing STRING / DATE32 regression case.
#
#   10. ArrowType round-trip on Q6-narrow 4-col schema (numeric-only path)
#   11. arrow_type_for hit returns the right ArrowType
#   12. arrow_type_for miss raises with helpful diagnostic
#   13. STRING / DATE32 regression — these are the cases where DTYPE_NONE
#       would otherwise have lost info; `arrow_type_for` returns the right
#       `ArrowType.STRING` / `ArrowType.DATE32`
#   14. Backward-compat: `dtype_for(name)` still works on the original 4
#       cases it covered (INT64 / FLOAT64 / INT32 / BOOL)
# =============================================================================


from std.testing import TestSuite, assert_true, assert_false, assert_equal

from komira_core.dtype_sentinel import DTYPE_NONE
from komira_core.arrow.schema import Schema, SchemaBuilder, Field
from komira_core.arrow.arrow_types import ArrowType
from komira_udf.column_resolver import ColumnResolver


# -----------------------------------------------------------------------------
# Test fixtures — synthetic schema builders
# -----------------------------------------------------------------------------


def _build_q6_narrow_schema() raises -> Schema:
    """The Q6-narrow 4-column schema used as the canonical
    multi-DType fixture across these tests:

        col 0: l_shipdate       INT64
        col 1: l_discount       FLOAT64
        col 2: l_quantity       FLOAT64
        col 3: l_extendedprice  FLOAT64
    """
    var sb = SchemaBuilder()
    sb.add_field(Field(String("l_shipdate"),      ArrowType.INT64,   False))
    sb.add_field(Field(String("l_discount"),      ArrowType.FLOAT64, False))
    sb.add_field(Field(String("l_quantity"),      ArrowType.FLOAT64, False))
    sb.add_field(Field(String("l_extendedprice"), ArrowType.FLOAT64, False))
    return sb.build()


def _build_multi_dtype_schema() raises -> Schema:
    """A 4-column schema spanning 4 distinct DTypes — for the
    "defensive validation" round-trip test:

        col 0: id        INT64
        col 1: price     FLOAT64
        col 2: count32   INT32
        col 3: is_active BOOL
    """
    var sb = SchemaBuilder()
    sb.add_field(Field(String("id"),        ArrowType.INT64,   False))
    sb.add_field(Field(String("price"),     ArrowType.FLOAT64, False))
    sb.add_field(Field(String("count32"),   ArrowType.INT32,   False))
    sb.add_field(Field(String("is_active"), ArrowType.BOOL,    False))
    return sb.build()


# -----------------------------------------------------------------------------
# 1) Empty resolver
# -----------------------------------------------------------------------------


def test_empty_resolver_len_is_zero() raises:
    var r = ColumnResolver()
    assert_equal(r.len(), 0)


def test_empty_resolver_has_returns_false() raises:
    var r = ColumnResolver()
    assert_false(r.has(String("x")))
    assert_false(r.has(String("")))


def test_empty_resolver_index_for_raises() raises:
    var r = ColumnResolver()
    var raised = False
    try:
        var _ = r.index_for(String("x"))
    except _:
        raised = True
    assert_true(raised)


def test_empty_resolver_dtype_for_raises() raises:
    var r = ColumnResolver()
    var raised = False
    try:
        var _ = r.dtype_for(String("x"))
    except _:
        raised = True
    assert_true(raised)


# -----------------------------------------------------------------------------
# 2) Explicit ctor — round-trip names/indices/dtypes
# -----------------------------------------------------------------------------


def test_explicit_ctor_roundtrip() raises:
    var names: List[String] = [
        String("a"), String("b"), String("c"),
    ]
    var indices: List[Int] = [0, 1, 2]
    var dtypes: List[DType] = [
        DType.int64, DType.float64, DType.bool,
    ]
    var arrow_types: List[ArrowType] = [
        ArrowType.INT64, ArrowType.FLOAT64, ArrowType.BOOL,
    ]
    var r = ColumnResolver(names^, indices^, dtypes^, arrow_types^)

    assert_equal(r.len(), 3)
    assert_equal(r.index_for(String("a")), 0)
    assert_equal(r.index_for(String("b")), 1)
    assert_equal(r.index_for(String("c")), 2)
    assert_true(r.dtype_for(String("a")) == DType.int64)
    assert_true(r.dtype_for(String("b")) == DType.float64)
    assert_true(r.dtype_for(String("c")) == DType.bool)
    assert_true(r.arrow_type_for(String("a")) == ArrowType.INT64)
    assert_true(r.arrow_type_for(String("b")) == ArrowType.FLOAT64)
    assert_true(r.arrow_type_for(String("c")) == ArrowType.BOOL)


def test_explicit_ctor_permuted_indices() raises:
    """The ctor does NOT enforce indices == 0..n-1; a permutation is
    legal (a future re-projected sub-schema may need this)."""
    var names: List[String] = [String("x"), String("y"), String("z")]
    var indices: List[Int] = [7, 3, 5]
    var dtypes: List[DType] = [
        DType.int64, DType.int64, DType.int64,
    ]
    var arrow_types: List[ArrowType] = [
        ArrowType.INT64, ArrowType.INT64, ArrowType.INT64,
    ]
    var r = ColumnResolver(names^, indices^, dtypes^, arrow_types^)

    assert_equal(r.index_for(String("x")), 7)
    assert_equal(r.index_for(String("y")), 3)
    assert_equal(r.index_for(String("z")), 5)


# -----------------------------------------------------------------------------
# 3) Explicit ctor — mismatched-length defensive raises
# -----------------------------------------------------------------------------


def test_explicit_ctor_mismatched_names_vs_indices_raises() raises:
    var names: List[String] = [String("a"), String("b")]
    var indices: List[Int] = [0]        # length 1 — mismatch
    var dtypes: List[DType] = [DType.int64, DType.int64]
    var arrow_types: List[ArrowType] = [ArrowType.INT64, ArrowType.INT64]
    var raised = False
    try:
        var _ = ColumnResolver(names^, indices^, dtypes^, arrow_types^)
    except _:
        raised = True
    assert_true(raised)


def test_explicit_ctor_mismatched_names_vs_dtypes_raises() raises:
    var names: List[String] = [String("a"), String("b")]
    var indices: List[Int] = [0, 1]
    var dtypes: List[DType] = [DType.int64]   # length 1 — mismatch
    var arrow_types: List[ArrowType] = [ArrowType.INT64, ArrowType.INT64]
    var raised = False
    try:
        var _ = ColumnResolver(names^, indices^, dtypes^, arrow_types^)
    except _:
        raised = True
    assert_true(raised)


def test_explicit_ctor_mismatched_names_vs_arrow_types_raises() raises:
    """Round 2c addendum — defensive raise when arrow_types list length
    differs from names list length."""
    var names: List[String] = [String("a"), String("b")]
    var indices: List[Int] = [0, 1]
    var dtypes: List[DType] = [DType.int64, DType.int64]
    var arrow_types: List[ArrowType] = [ArrowType.INT64]   # length 1 — mismatch
    var raised = False
    try:
        var _ = ColumnResolver(names^, indices^, dtypes^, arrow_types^)
    except _:
        raised = True
    assert_true(raised)


# -----------------------------------------------------------------------------
# 4) from_arrow_schema — build from a synthetic 4-col Schema
# -----------------------------------------------------------------------------


def test_from_arrow_schema_q6_narrow() raises:
    var schema = _build_q6_narrow_schema()
    var r = ColumnResolver.from_arrow_schema(schema)

    assert_equal(r.len(), 4)
    assert_equal(r.index_for(String("l_shipdate")),      0)
    assert_equal(r.index_for(String("l_discount")),      1)
    assert_equal(r.index_for(String("l_quantity")),      2)
    assert_equal(r.index_for(String("l_extendedprice")), 3)


def test_from_arrow_schema_empty_schema() raises:
    """A schema with zero columns produces a zero-length resolver."""
    var sb = SchemaBuilder()
    var schema = sb.build()
    var r = ColumnResolver.from_arrow_schema(schema)
    assert_equal(r.len(), 0)
    assert_false(r.has(String("any_name")))


# -----------------------------------------------------------------------------
# 5) index_for hit
# -----------------------------------------------------------------------------


def test_index_for_hit() raises:
    var schema = _build_q6_narrow_schema()
    var r = ColumnResolver.from_arrow_schema(schema)
    # All 4 columns
    assert_equal(r.index_for(String("l_shipdate")), 0)
    assert_equal(r.index_for(String("l_discount")), 1)


# -----------------------------------------------------------------------------
# 6) index_for miss — raises with the helpful diagnostic
# -----------------------------------------------------------------------------


def test_index_for_miss_raises_with_helpful_diagnostic() raises:
    var schema = _build_q6_narrow_schema()
    var r = ColumnResolver.from_arrow_schema(schema)
    var raised = False
    var msg = String("")
    try:
        var _ = r.index_for(String("l_nonexistent_column"))
    except e:
        raised = True
        msg = String(e)
    assert_true(raised)
    # The diagnostic should mention the missing name AND list the available
    # names so the user can spot a typo.
    assert_true(String("l_nonexistent_column") in msg)
    assert_true(String("available") in msg)
    assert_true(String("l_shipdate") in msg)


def test_dtype_for_miss_raises_with_helpful_diagnostic() raises:
    var schema = _build_q6_narrow_schema()
    var r = ColumnResolver.from_arrow_schema(schema)
    var raised = False
    var msg = String("")
    try:
        var _ = r.dtype_for(String("not_a_real_col"))
    except e:
        raised = True
        msg = String(e)
    assert_true(raised)
    assert_true(String("not_a_real_col") in msg)
    assert_true(String("available") in msg)


# -----------------------------------------------------------------------------
# 7) dtype_for matches the file's declared DType
# -----------------------------------------------------------------------------


def test_dtype_for_matches_file_dtype() raises:
    var schema = _build_q6_narrow_schema()
    var r = ColumnResolver.from_arrow_schema(schema)
    assert_true(r.dtype_for(String("l_shipdate"))      == DType.int64)
    assert_true(r.dtype_for(String("l_discount"))      == DType.float64)
    assert_true(r.dtype_for(String("l_quantity"))      == DType.float64)
    assert_true(r.dtype_for(String("l_extendedprice")) == DType.float64)


# -----------------------------------------------------------------------------
# 8) has() returns Bool correctly for hit + miss
# -----------------------------------------------------------------------------


def test_has_hit() raises:
    var schema = _build_q6_narrow_schema()
    var r = ColumnResolver.from_arrow_schema(schema)
    assert_true(r.has(String("l_shipdate")))
    assert_true(r.has(String("l_extendedprice")))


def test_has_miss() raises:
    var schema = _build_q6_narrow_schema()
    var r = ColumnResolver.from_arrow_schema(schema)
    assert_false(r.has(String("not_in_schema")))
    assert_false(r.has(String("")))


# -----------------------------------------------------------------------------
# 9) Defensive validation — round-trip across 4 distinct DTypes
# -----------------------------------------------------------------------------


def test_multi_dtype_roundtrip() raises:
    """The resolver carries per-column DType. The bind pass is what compares the file's DType to the
    typed-Expr's declared DType; the resolver itself just round-trips
    faithfully. This test confirms it does so across 4 distinct DTypes
    (I64, F64, I32, Bool) on the same schema."""
    var schema = _build_multi_dtype_schema()
    var r = ColumnResolver.from_arrow_schema(schema)

    assert_equal(r.len(), 4)

    # Indices
    assert_equal(r.index_for(String("id")),        0)
    assert_equal(r.index_for(String("price")),     1)
    assert_equal(r.index_for(String("count32")),   2)
    assert_equal(r.index_for(String("is_active")), 3)

    # DTypes — each distinct
    assert_true(r.dtype_for(String("id"))        == DType.int64)
    assert_true(r.dtype_for(String("price"))     == DType.float64)
    assert_true(r.dtype_for(String("count32"))   == DType.int32)
    assert_true(r.dtype_for(String("is_active")) == DType.bool)


# -----------------------------------------------------------------------------
# Round 2c addendum — ArrowType layer
# -----------------------------------------------------------------------------


def _build_string_date32_schema() raises -> Schema:
    """A 4-column schema exercising the load-bearing "DType loses info"
    cases that motivate carrying ArrowType: STRING + DATE32 cannot be
    represented in Mojo's DType enum (both collapse to DTYPE_NONE).

        col 0: name        STRING
        col 1: birth_date  DATE32
        col 2: id          INT64       (a numeric column for contrast)
        col 3: active      BOOL        (a numeric column for contrast)
    """
    var sb = SchemaBuilder()
    sb.add_field(Field(String("name"),       ArrowType.STRING, False))
    sb.add_field(Field(String("birth_date"), ArrowType.DATE32, False))
    sb.add_field(Field(String("id"),         ArrowType.INT64,  False))
    sb.add_field(Field(String("active"),     ArrowType.BOOL,   False))
    return sb.build()


def test_arrow_type_roundtrip_q6_narrow() raises:
    """`from_arrow_schema` populates the `_arrow_types` field with each
    column's ArrowType in declaration order. Verified on the numeric-only
    Q6-narrow 4-col schema (parallel to the existing dtype_for test)."""
    var schema = _build_q6_narrow_schema()
    var r = ColumnResolver.from_arrow_schema(schema)

    assert_equal(r.len(), 4)
    assert_true(r.arrow_type_for(String("l_shipdate"))      == ArrowType.INT64)
    assert_true(r.arrow_type_for(String("l_discount"))      == ArrowType.FLOAT64)
    assert_true(r.arrow_type_for(String("l_quantity"))      == ArrowType.FLOAT64)
    assert_true(r.arrow_type_for(String("l_extendedprice")) == ArrowType.FLOAT64)


def test_arrow_type_for_miss_raises_with_helpful_diagnostic() raises:
    """`arrow_type_for` mirrors `index_for` / `dtype_for`: raises on a
    missing name with a diagnostic that lists the available names."""
    var schema = _build_q6_narrow_schema()
    var r = ColumnResolver.from_arrow_schema(schema)
    var raised = False
    var msg = String("")
    try:
        var _ = r.arrow_type_for(String("not_a_real_col"))
    except e:
        raised = True
        msg = String(e)
    assert_true(raised)
    assert_true(String("not_a_real_col") in msg)
    assert_true(String("available") in msg)
    assert_true(String("l_shipdate") in msg)


def test_arrow_type_for_string_and_date32_regression() raises:
    """LOAD-BEARING regression test: ArrowType
    is what carries STRING / DATE32 cases through to bind-time validation.
    `dtype_for` returns `DTYPE_NONE` for both (Mojo's DType enum has no
    slot for them); `arrow_type_for` returns the right ArrowType."""
    var schema = _build_string_date32_schema()
    var r = ColumnResolver.from_arrow_schema(schema)

    assert_equal(r.len(), 4)

    # Indices round-trip
    assert_equal(r.index_for(String("name")),       0)
    assert_equal(r.index_for(String("birth_date")), 1)
    assert_equal(r.index_for(String("id")),         2)
    assert_equal(r.index_for(String("active")),     3)

    # ArrowType — the load-bearing path. STRING + DATE32 round-trip
    # faithfully even though DType cannot represent them.
    assert_true(r.arrow_type_for(String("name"))       == ArrowType.STRING)
    assert_true(r.arrow_type_for(String("birth_date")) == ArrowType.DATE32)
    assert_true(r.arrow_type_for(String("id"))         == ArrowType.INT64)
    assert_true(r.arrow_type_for(String("active"))     == ArrowType.BOOL)

    # DType — for STRING + DATE32 the Field ctor drops to DTYPE_NONE.
    # Documented for the regression: this is EXACTLY why arrow_type_for
    # is the load-bearing accessor for these cases.
    assert_true(r.dtype_for(String("name"))       == DTYPE_NONE)
    assert_true(r.dtype_for(String("birth_date")) == DTYPE_NONE)
    # The numeric columns DType still round-trips.
    assert_true(r.dtype_for(String("id"))         == DType.int64)
    assert_true(r.dtype_for(String("active"))     == DType.bool)


def test_dtype_for_backward_compat_after_arrow_type_added() raises:
    """Backward-compatibility regression: `dtype_for` still returns the
    right DType for the 4 numeric cases it has always
    covered (INT64 / FLOAT64 / INT32 / BOOL). The ArrowType field addition
    must not break the pre-existing dtype_for surface."""
    var schema = _build_multi_dtype_schema()
    var r = ColumnResolver.from_arrow_schema(schema)

    assert_true(r.dtype_for(String("id"))        == DType.int64)
    assert_true(r.dtype_for(String("price"))     == DType.float64)
    assert_true(r.dtype_for(String("count32"))   == DType.int32)
    assert_true(r.dtype_for(String("is_active")) == DType.bool)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
