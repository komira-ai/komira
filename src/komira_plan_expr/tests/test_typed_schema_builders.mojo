# =============================================================================
# test_typed_schema_builders.mojo: the schema builders and the footer
# handshake of typed_schema.
#
# `schema_of` / `schema_of_strict` are arity-overloaded; every overload is
# instantiated here and checked column by column, so an overload that drops,
# reorders or retypes a column, or carries the wrong `strict`, fails. The
# derived schemas (`prefixed_schema`, `select_named_schema`, the brand-safe
# rebuild) are checked against the rule their docstrings state,
# and `validate_against_footer` against its exact error text.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_plan_expr.typed_schema import (
    TYPE_UNKNOWN, TYPE_INT8, TYPE_INT32, TYPE_INT64, TYPE_FLOAT64,
    TYPE_STRING, TYPE_DATE32, TYPE_STRUCT,
    Int64Col, Float64Col,
    ColDescriptor, SchemaDescriptor,
    _NN, _NS, _NM,
    schema_of, schema_of_strict,
    prefixed_schema, _build_prefixed_schema,
    _rebuild_coldescriptor_safe, _rebuild_schema_safe,
    materialize_schema_safe,
    validate_against_footer, validate_brand_against_footer,
    select_named_schema,
)


def _expect(s: SchemaDescriptor, n: Int, strict: Bool) raises:
    """Column i is `c<i>` with tag i (so every column of an arity has its own
    tag), non-null, no children, no map types."""
    assert_equal(s.num_cols(), n)
    assert_equal(s.strict, strict)
    for i in range(n):
        assert_equal(s.cols[i].name, String("c") + String(i))
        assert_equal(s.cols[i].dtype, i)
        assert_false(s.cols[i].nullable)
        assert_equal(len(s.cols[i].struct_fields), 0)
        assert_equal(s.cols[i].map_key_dtype, TYPE_UNKNOWN)


def _footer3() -> Schema:
    """`order_key` INT32, `comment` STRING, `extra_col` INT8."""
    var sb = SchemaBuilder()
    sb.add_field(Field("order_key", ArrowType.INT32, False))
    sb.add_field(Field("comment", ArrowType.STRING, True))
    sb.add_field(Field("extra_col", ArrowType.INT8, False))
    return sb.build()


def _decl(var c: List[ColDescriptor], strict: Bool) -> SchemaDescriptor:
    return SchemaDescriptor(c^, strict)


def _err_of(d: SchemaDescriptor, footer: Schema, label: String) -> String:
    try:
        validate_against_footer(d, footer, label)
    except e:
        return String(e)
    return String("<no error>")


comptime TAIL = (
    " — declaring a subset is allowed, so extra file columns are not"
    + " flagged unless schema_of_strict[...] was used.)"
)


# Long (heap) column names: `select_named_schema`'s typo message joins the
# schema's names with `String +=` at comptime, which the interpreter cannot do
# on an inline short String (the CAVEAT in that function).
comptime WIDE = SchemaDescriptor([
    ColDescriptor(String("shipment_reference_identifier"), TYPE_INT64, True, List[ColDescriptor](), TYPE_UNKNOWN, TYPE_UNKNOWN),
    _NN(String("shipment_destination_postcode"), TYPE_STRING),
    _NN(String("shipment_declared_weight_kgs"), TYPE_FLOAT64),
], True)

comptime ORDERS = schema_of["order_key", Int64Col, "order_total", Float64Col]()


def test_validate_subset_passes() raises:
    """A declared subset whose types match passes; extra footer columns are
    not an error when not strict. A DATE32 declaration matches an INT32
    footer column (the storage type)."""
    var c: List[ColDescriptor] = [_NN("comment", TYPE_STRING), _NN("order_key", TYPE_DATE32)]
    assert_equal(_err_of(_decl(c^, False), _footer3(), "t.parquet"), "<no error>")


def test_validate_strict_exact_passes() raises:
    """A strict declaration naming every footer column, in another order,
    passes."""
    var c: List[ColDescriptor] = [
        _NN("extra_col", TYPE_INT8), _NN("comment", TYPE_STRING), _NN("order_key", TYPE_INT32),
    ]
    assert_equal(_err_of(_decl(c^, True), _footer3(), "t.parquet"), "<no error>")


def test_validate_missing_column_message() raises:
    """One absent column: one problem line, no leading newline, and the
    counts of the footer (3) and of the declaration (1)."""
    var c: List[ColDescriptor] = [_NN("price", TYPE_FLOAT64)]
    assert_equal(
        _err_of(_decl(c^, False), _footer3(), "t.parquet"),
        String("ParquetSchemaMismatch: declared schema for \"t.parquet\" does not satisfy the actual schema:\n")
        + "    - column \"price\": declared but not present in the file"
        + "\n  (file has 3 columns; you declared 1" + TAIL,
    )


def test_validate_type_mismatch_message() raises:
    """A type mismatch names the declared and the footer type by
    `type_name`; a footer type with no tag of its own reads `Unknown`."""
    var c: List[ColDescriptor] = [_NN("order_key", TYPE_INT64)]
    assert_equal(
        _err_of(_decl(c^, False), _footer3(), "lbl"),
        String("ParquetSchemaMismatch: declared schema for \"lbl\" does not satisfy the actual schema:\n")
        + "    - column \"order_key\": declared Int64, footer has Int32"
        + "\n  (file has 3 columns; you declared 1" + TAIL,
    )
    var sb = SchemaBuilder()
    sb.add_field(Field("d", ArrowType.DATE32, False))
    var c2: List[ColDescriptor] = [_NN("d", TYPE_DATE32)]
    assert_equal(
        _err_of(_decl(c2^, False), sb.build(), "x"),
        String("ParquetSchemaMismatch: declared schema for \"x\" does not satisfy the actual schema:\n")
        + "    - column \"d\": declared Date32, footer has Unknown"
        + "\n  (file has 1 columns; you declared 1" + TAIL,
    )


def test_validate_every_problem_listed_in_order() raises:
    """Every problem is listed, one per line, declared columns first in
    declaration order and then the strict extras in footer order."""
    var c: List[ColDescriptor] = [
        _NN("order_key", TYPE_INT64), _NN("price", TYPE_FLOAT64), _NN("comment", TYPE_STRING),
    ]
    assert_equal(
        _err_of(_decl(c^, True), _footer3(), "t.parquet"),
        String("ParquetSchemaMismatch: declared schema for \"t.parquet\" does not satisfy the actual schema:\n")
        + "    - column \"order_key\": declared Int64, footer has Int32"
        + "\n    - column \"price\": declared but not present in the file"
        + "\n    - extra column \"extra_col\": file column not in the (strict) declared schema"
        + "\n  (file has 3 columns; you declared 3" + TAIL,
    )


def test_validate_mismatch_after_missing() raises:
    """A type mismatch after an earlier problem starts a new line."""
    var c: List[ColDescriptor] = [_NN("price", TYPE_FLOAT64), _NN("comment", TYPE_INT8)]
    assert_equal(
        _err_of(_decl(c^, False), _footer3(), "t"),
        String("ParquetSchemaMismatch: declared schema for \"t\" does not satisfy the actual schema:\n")
        + "    - column \"price\": declared but not present in the file"
        + "\n    - column \"comment\": declared Int8, footer has StringCol"
        + "\n  (file has 3 columns; you declared 2" + TAIL,
    )


def test_validate_strict_extra_first_problem() raises:
    """A strict extra as the only problem starts the list (no leading
    newline)."""
    var c: List[ColDescriptor] = [_NN("order_key", TYPE_INT32), _NN("comment", TYPE_STRING)]
    assert_equal(
        _err_of(_decl(c^, True), _footer3(), "t"),
        String("ParquetSchemaMismatch: declared schema for \"t\" does not satisfy the actual schema:\n")
        + "    - extra column \"extra_col\": file column not in the (strict) declared schema"
        + "\n  (file has 3 columns; you declared 2" + TAIL,
    )


def test_validate_brand_against_footer() raises:
    """The parametric entry validates the comptime brand: WIDE is strict, so
    a footer holding its three columns passes and one missing a column and
    holding another fails with both problems."""
    var ok = SchemaBuilder()
    ok.add_field(Field("shipment_reference_identifier", ArrowType.INT64, True))
    ok.add_field(Field("shipment_destination_postcode", ArrowType.STRING, False))
    ok.add_field(Field("shipment_declared_weight_kgs", ArrowType.FLOAT64, False))
    validate_brand_against_footer[WIDE](ok.build(), "wide")
    var bad = SchemaBuilder()
    bad.add_field(Field("shipment_reference_identifier", ArrowType.INT64, True))
    bad.add_field(Field("shipment_destination_postcode", ArrowType.STRING, False))
    bad.add_field(Field("z", ArrowType.FLOAT64, False))
    var msg = String("<no error>")
    try:
        validate_brand_against_footer[WIDE](bad.build(), "wide")
    except e:
        msg = String(e)
    assert_equal(
        msg,
        String("ParquetSchemaMismatch: declared schema for \"wide\" does not satisfy the actual schema:\n")
        + "    - column \"shipment_declared_weight_kgs\": declared but not present in the file"
        + "\n    - extra column \"z\": file column not in the (strict) declared schema"
        + "\n  (file has 3 columns; you declared 3" + TAIL,
    )


def test_prefixed_schema() raises:
    """Every name becomes `<alias>.<name>`; type, nullability and `strict`
    unchanged."""
    var p = prefixed_schema[ORDERS, "o"]()
    assert_equal(p.num_cols(), 2)
    assert_equal(p.cols[0].name, "o.order_key")
    assert_equal(p.cols[0].dtype, TYPE_INT64)
    assert_equal(p.cols[1].name, "o.order_total")
    assert_equal(p.cols[1].dtype, TYPE_FLOAT64)
    assert_false(p.strict)


def test_build_prefixed_schema_keeps_every_slot() raises:
    """The runtime body: nullability, STRUCT children (unprefixed), MAP types
    and `strict` are carried; only the top-level names get the prefix."""
    var kids: List[ColDescriptor] = [_NN("street", TYPE_STRING)]
    var c: List[ColDescriptor] = [
        ColDescriptor("id", TYPE_INT64, True, List[ColDescriptor](), TYPE_UNKNOWN, TYPE_UNKNOWN),
        _NS("addr", kids^),
        _NM("tags", TYPE_STRING, TYPE_INT32),
    ]
    var p = _build_prefixed_schema(SchemaDescriptor(c^, True), "t.")
    assert_equal(p.names_joined(), "t.id, t.addr, t.tags")
    assert_true(p.cols[0].nullable)
    assert_false(p.cols[1].nullable)
    assert_equal(p.cols[1].dtype, TYPE_STRUCT)
    assert_equal(p.cols[1].struct_fields[0].name, "street")
    assert_equal(p.cols[2].map_key_dtype, TYPE_STRING)
    assert_equal(p.cols[2].map_value_dtype, TYPE_INT32)
    assert_true(p.strict)


def test_rebuild_safe_is_a_deep_equal_copy() raises:
    """The rebuild keeps every slot of every column and of nested STRUCT
    children at any depth (a STRUCT inside a STRUCT), and `strict`."""
    var inner: List[ColDescriptor] = [_NN("lat", TYPE_FLOAT64)]
    var kids: List[ColDescriptor] = [
        ColDescriptor("street", TYPE_STRING, True, List[ColDescriptor](), TYPE_UNKNOWN, TYPE_UNKNOWN),
        _NS("geo", inner^),
    ]
    var c: List[ColDescriptor] = [_NS("addr", kids^), _NM("tags", TYPE_STRING, TYPE_INT64)]
    var r = _rebuild_schema_safe(SchemaDescriptor(c^, True))
    assert_true(r.strict)
    assert_equal(r.names_joined(), "addr, tags")
    assert_equal(r.cols[0].dtype, TYPE_STRUCT)
    assert_equal(len(r.cols[0].struct_fields), 2)
    assert_true(r.cols[0].struct_fields[0].nullable)
    assert_equal(r.cols[0].struct_fields[1].name, "geo")
    assert_equal(r.cols[0].struct_fields[1].struct_fields[0].name, "lat")
    assert_equal(r.cols[0].struct_fields[1].struct_fields[0].dtype, TYPE_FLOAT64)
    assert_equal(r.cols[1].map_key_dtype, TYPE_STRING)
    assert_equal(r.cols[1].map_value_dtype, TYPE_INT64)
    var one = _rebuild_coldescriptor_safe(_NN("solo", TYPE_INT8))
    assert_equal(one.name, "solo")
    assert_equal(one.dtype, TYPE_INT8)
    assert_equal(len(one.struct_fields), 0)


def test_materialize_schema_safe() raises:
    """The brand-safe lift of a comptime schema reads back every name, type,
    nullability and `strict`."""
    var w = materialize_schema_safe[WIDE]()
    assert_equal(w.num_cols(), 3)
    assert_equal(w.cols[0].name, "shipment_reference_identifier")
    assert_true(w.cols[0].nullable)
    assert_equal(w.cols[2].name, "shipment_declared_weight_kgs")
    assert_equal(w.cols[2].dtype, TYPE_FLOAT64)
    assert_true(w.strict)


def test_select_named_schema_pack_order() raises:
    """The selected columns in the order named (not the schema's), with their
    type and nullability, and the source's `strict`."""
    var s = select_named_schema[WIDE, "shipment_declared_weight_kgs", "shipment_reference_identifier"]()
    assert_equal(s.num_cols(), 2)
    assert_equal(s.cols[0].name, "shipment_declared_weight_kgs")
    assert_equal(s.cols[0].dtype, TYPE_FLOAT64)
    assert_false(s.cols[0].nullable)
    assert_equal(s.cols[1].name, "shipment_reference_identifier")
    assert_equal(s.cols[1].dtype, TYPE_INT64)
    assert_true(s.cols[1].nullable)
    assert_true(s.strict)


def test_schema_of_every_arity() raises:
    """Each arity 1..16 builds exactly its columns, in order, non-null,
    not strict."""
    var s1 = schema_of["c0", 0]()
    _expect(s1, 1, False)
    var s2 = schema_of["c0", 0, "c1", 1]()
    _expect(s2, 2, False)
    var s3 = schema_of["c0", 0, "c1", 1, "c2", 2]()
    _expect(s3, 3, False)
    var s4 = schema_of["c0", 0, "c1", 1, "c2", 2, "c3", 3]()
    _expect(s4, 4, False)
    var s5 = schema_of["c0", 0, "c1", 1, "c2", 2, "c3", 3, "c4", 4]()
    _expect(s5, 5, False)
    var s6 = schema_of["c0", 0, "c1", 1, "c2", 2, "c3", 3, "c4", 4, "c5", 5]()
    _expect(s6, 6, False)
    var s7 = schema_of["c0", 0, "c1", 1, "c2", 2, "c3", 3, "c4", 4, "c5", 5, "c6", 6]()
    _expect(s7, 7, False)
    var s8 = schema_of["c0", 0, "c1", 1, "c2", 2, "c3", 3, "c4", 4, "c5", 5, "c6", 6, "c7", 7]()
    _expect(s8, 8, False)
    var s9 = schema_of["c0", 0, "c1", 1, "c2", 2, "c3", 3, "c4", 4, "c5", 5, "c6", 6, "c7", 7, "c8", 8]()
    _expect(s9, 9, False)
    var s10 = schema_of["c0", 0, "c1", 1, "c2", 2, "c3", 3, "c4", 4, "c5", 5, "c6", 6, "c7", 7, "c8", 8, "c9", 9]()
    _expect(s10, 10, False)
    var s11 = schema_of["c0", 0, "c1", 1, "c2", 2, "c3", 3, "c4", 4, "c5", 5, "c6", 6, "c7", 7, "c8", 8, "c9", 9, "c10", 10]()
    _expect(s11, 11, False)
    var s12 = schema_of["c0", 0, "c1", 1, "c2", 2, "c3", 3, "c4", 4, "c5", 5, "c6", 6, "c7", 7, "c8", 8, "c9", 9, "c10", 10, "c11", 11]()
    _expect(s12, 12, False)
    var s13 = schema_of["c0", 0, "c1", 1, "c2", 2, "c3", 3, "c4", 4, "c5", 5, "c6", 6, "c7", 7, "c8", 8, "c9", 9, "c10", 10, "c11", 11, "c12", 12]()
    _expect(s13, 13, False)
    var s14 = schema_of["c0", 0, "c1", 1, "c2", 2, "c3", 3, "c4", 4, "c5", 5, "c6", 6, "c7", 7, "c8", 8, "c9", 9, "c10", 10, "c11", 11, "c12", 12, "c13", 13]()
    _expect(s14, 14, False)
    var s15 = schema_of["c0", 0, "c1", 1, "c2", 2, "c3", 3, "c4", 4, "c5", 5, "c6", 6, "c7", 7, "c8", 8, "c9", 9, "c10", 10, "c11", 11, "c12", 12, "c13", 13, "c14", 14]()
    _expect(s15, 15, False)
    var s16 = schema_of["c0", 0, "c1", 1, "c2", 2, "c3", 3, "c4", 4, "c5", 5, "c6", 6, "c7", 7, "c8", 8, "c9", 9, "c10", 10, "c11", 11, "c12", 12, "c13", 13, "c14", 14, "c15", 15]()
    _expect(s16, 16, False)


def test_schema_of_strict_every_arity() raises:
    """Each `schema_of_strict` overload (arities 1-8, 10, 12, 16; the
    others do not exist) builds the same columns as `schema_of`, strict."""
    var t1 = schema_of_strict["c0", 0]()
    _expect(t1, 1, True)
    var t2 = schema_of_strict["c0", 0, "c1", 1]()
    _expect(t2, 2, True)
    var t3 = schema_of_strict["c0", 0, "c1", 1, "c2", 2]()
    _expect(t3, 3, True)
    var t4 = schema_of_strict["c0", 0, "c1", 1, "c2", 2, "c3", 3]()
    _expect(t4, 4, True)
    var t5 = schema_of_strict["c0", 0, "c1", 1, "c2", 2, "c3", 3, "c4", 4]()
    _expect(t5, 5, True)
    var t6 = schema_of_strict["c0", 0, "c1", 1, "c2", 2, "c3", 3, "c4", 4, "c5", 5]()
    _expect(t6, 6, True)
    var t7 = schema_of_strict["c0", 0, "c1", 1, "c2", 2, "c3", 3, "c4", 4, "c5", 5, "c6", 6]()
    _expect(t7, 7, True)
    var t8 = schema_of_strict["c0", 0, "c1", 1, "c2", 2, "c3", 3, "c4", 4, "c5", 5, "c6", 6, "c7", 7]()
    _expect(t8, 8, True)
    var t10 = schema_of_strict["c0", 0, "c1", 1, "c2", 2, "c3", 3, "c4", 4, "c5", 5, "c6", 6, "c7", 7, "c8", 8, "c9", 9]()
    _expect(t10, 10, True)
    var t12 = schema_of_strict["c0", 0, "c1", 1, "c2", 2, "c3", 3, "c4", 4, "c5", 5, "c6", 6, "c7", 7, "c8", 8, "c9", 9, "c10", 10, "c11", 11]()
    _expect(t12, 12, True)
    var t16 = schema_of_strict["c0", 0, "c1", 1, "c2", 2, "c3", 3, "c4", 4, "c5", 5, "c6", 6, "c7", 7, "c8", 8, "c9", 9, "c10", 10, "c11", 11, "c12", 12, "c13", 13, "c14", 14, "c15", 15]()
    _expect(t16, 16, True)



def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
