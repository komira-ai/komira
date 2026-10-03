# =============================================================================
# test_orc_schema_canonical_form.mojo — ORC type tree -> canonical form +
#                                       Arrow type lattice.
# =============================================================================
#
# Acceptance: type tree -> canonical form + Arrow lattice mapping.
#
# The OrcSchema is built directly from a flat `List[OrcRawType]` (the same
# shape Footer.types yields), then canonicalized to Hive notation + mapped
# to the Arrow lattice. Canonical form is stable across re-build (round-trip
# equality testing).
#
# Coverage:
#   T1  primitive lattice: all 13 scalar ORC kinds -> Arrow types.
#   T2  canonical form: flat struct of primitives.
#   T3  canonical form: nested array<int> + map<string,bigint>.
#   T4  canonical form: decimal(p,s) + varchar(N) + char(N).
#   T5  canonical form: uniontype<int,string>.
#   T6  lattice: DECIMAL p<=38 -> Decimal128; p>38 raises.
#   T7  lattice: TIMESTAMP / TIMESTAMP_INSTANT -> Timestamp[ns]; DATE -> Date32.
#   T8  bad-child-index in subtypes raises; empty schema raises.
#   T9  canonical form is deterministic across re-build.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_core.arrow.arrow_types import ArrowType

from komira_orc import (
    OrcSchema,
    OrcRawType,
    orc_node_to_arrow,
    ORC_KIND_BOOLEAN,
    ORC_KIND_BYTE,
    ORC_KIND_SHORT,
    ORC_KIND_INT,
    ORC_KIND_LONG,
    ORC_KIND_FLOAT,
    ORC_KIND_DOUBLE,
    ORC_KIND_STRING,
    ORC_KIND_BINARY,
    ORC_KIND_TIMESTAMP,
    ORC_KIND_TIMESTAMP_INSTANT,
    ORC_KIND_DATE,
    ORC_KIND_DECIMAL,
    ORC_KIND_VARCHAR,
    ORC_KIND_CHAR,
    ORC_KIND_STRUCT,
    ORC_KIND_LIST,
    ORC_KIND_MAP,
    ORC_KIND_UNION,
)


# -----------------------------------------------------------------------------
# OrcRawType node builders (mirror what footer.OrcRawType.parse produces).
# -----------------------------------------------------------------------------


def _leaf(kind: Int) -> OrcRawType:
    return OrcRawType(
        kind=kind,
        subtypes=List[Int](),
        field_names=List[String](),
        maximum_length=0,
        precision=0,
        scale=0,
    )


def _decimal(precision: Int, scale: Int) -> OrcRawType:
    return OrcRawType(
        kind=ORC_KIND_DECIMAL,
        subtypes=List[Int](),
        field_names=List[String](),
        maximum_length=0,
        precision=precision,
        scale=scale,
    )


def _varchar_char(kind: Int, n: Int) -> OrcRawType:
    return OrcRawType(
        kind=kind,
        subtypes=List[Int](),
        field_names=List[String](),
        maximum_length=n,
        precision=0,
        scale=0,
    )


def _compound(kind: Int, subtypes: List[Int], names: List[String]) -> OrcRawType:
    return OrcRawType(
        kind=kind,
        subtypes=subtypes.copy(),
        field_names=names.copy(),
        maximum_length=0,
        precision=0,
        scale=0,
    )


def _children(*ids: Int) -> List[Int]:
    var out = List[Int]()
    for i in range(len(ids)):
        out.append(ids[i])
    return out^


# -----------------------------------------------------------------------------
# Tests.
# -----------------------------------------------------------------------------


def test_primitive_lattice() raises:
    """T1: all 13 scalar kinds map to their Arrow types."""
    var nodes = List[OrcRawType]()
    nodes.append(_leaf(ORC_KIND_BOOLEAN))
    nodes.append(_leaf(ORC_KIND_BYTE))
    nodes.append(_leaf(ORC_KIND_SHORT))
    nodes.append(_leaf(ORC_KIND_INT))
    nodes.append(_leaf(ORC_KIND_LONG))
    nodes.append(_leaf(ORC_KIND_FLOAT))
    nodes.append(_leaf(ORC_KIND_DOUBLE))
    nodes.append(_leaf(ORC_KIND_STRING))
    nodes.append(_leaf(ORC_KIND_BINARY))
    var schema = OrcSchema(nodes^)
    assert_true(orc_node_to_arrow(schema, 0) == ArrowType.BOOL)
    assert_true(orc_node_to_arrow(schema, 1) == ArrowType.INT8)
    assert_true(orc_node_to_arrow(schema, 2) == ArrowType.INT16)
    assert_true(orc_node_to_arrow(schema, 3) == ArrowType.INT32)
    assert_true(orc_node_to_arrow(schema, 4) == ArrowType.INT64)
    assert_true(orc_node_to_arrow(schema, 5) == ArrowType.FLOAT32)
    assert_true(orc_node_to_arrow(schema, 6) == ArrowType.FLOAT64)
    assert_true(orc_node_to_arrow(schema, 7) == ArrowType.STRING)
    assert_true(orc_node_to_arrow(schema, 8) == ArrowType.BINARY)


def test_canonical_flat_struct() raises:
    """T2: struct<l_orderkey:bigint,l_partkey:int,l_comment:string>."""
    var nodes = List[OrcRawType]()
    var names = List[String]()
    names.append(String("l_orderkey"))
    names.append(String("l_partkey"))
    names.append(String("l_comment"))
    nodes.append(_compound(ORC_KIND_STRUCT, _children(1, 2, 3), names))
    nodes.append(_leaf(ORC_KIND_LONG))
    nodes.append(_leaf(ORC_KIND_INT))
    nodes.append(_leaf(ORC_KIND_STRING))
    var schema = OrcSchema.from_types(nodes^)
    assert_equal(
        schema.canonical_form(),
        String("struct<l_orderkey:bigint,l_partkey:int,l_comment:string>"),
    )


def test_canonical_nested_array_map() raises:
    """T3: array<int> + map<string,bigint> nested inside a struct."""
    # struct<tags:array<int>,attrs:map<string,bigint>>
    # indices: 0 struct, 1 array, 2 int(elem), 3 map, 4 string(key), 5 bigint(val)
    var nodes = List[OrcRawType]()
    var names = List[String]()
    names.append(String("tags"))
    names.append(String("attrs"))
    nodes.append(_compound(ORC_KIND_STRUCT, _children(1, 3), names))
    nodes.append(_compound(ORC_KIND_LIST, _children(2), List[String]()))
    nodes.append(_leaf(ORC_KIND_INT))
    nodes.append(_compound(ORC_KIND_MAP, _children(4, 5), List[String]()))
    nodes.append(_leaf(ORC_KIND_STRING))
    nodes.append(_leaf(ORC_KIND_LONG))
    var schema = OrcSchema.from_types(nodes^)
    assert_equal(
        schema.canonical_form(),
        String("struct<tags:array<int>,attrs:map<string,bigint>>"),
    )


def test_canonical_decimal_varchar_char() raises:
    """T4: decimal(18,4) + varchar(40) + char(10)."""
    var nodes = List[OrcRawType]()
    var names = List[String]()
    names.append(String("price"))
    names.append(String("code"))
    names.append(String("flag"))
    nodes.append(_compound(ORC_KIND_STRUCT, _children(1, 2, 3), names))
    nodes.append(_decimal(18, 4))
    nodes.append(_varchar_char(ORC_KIND_VARCHAR, 40))
    nodes.append(_varchar_char(ORC_KIND_CHAR, 10))
    var schema = OrcSchema.from_types(nodes^)
    assert_equal(
        schema.canonical_form(),
        String("struct<price:decimal(18,4),code:varchar(40),flag:char(10)>"),
    )


def test_canonical_uniontype() raises:
    """T5: uniontype<int,string>."""
    var nodes = List[OrcRawType]()
    nodes.append(_compound(ORC_KIND_UNION, _children(1, 2), List[String]()))
    nodes.append(_leaf(ORC_KIND_INT))
    nodes.append(_leaf(ORC_KIND_STRING))
    var schema = OrcSchema.from_types(nodes^)
    assert_equal(schema.canonical_form(), String("uniontype<int,string>"))


def test_decimal_lattice_and_precision_cap() raises:
    """T6: DECIMAL p<=38 -> Decimal128; p>38 raises."""
    var ok_nodes = List[OrcRawType]()
    ok_nodes.append(_decimal(38, 10))
    var ok_schema = OrcSchema(ok_nodes^)
    assert_true(orc_node_to_arrow(ok_schema, 0) == ArrowType.DECIMAL128)

    var bad_nodes = List[OrcRawType]()
    bad_nodes.append(_decimal(39, 10))
    var bad_schema = OrcSchema(bad_nodes^)
    var raised = False
    try:
        var _t = orc_node_to_arrow(bad_schema, 0)
    except:
        raised = True
    assert_true(raised, "DECIMAL precision > 38 must raise (ORC v1 cap)")


def test_temporal_lattice() raises:
    """T7: TIMESTAMP / TIMESTAMP_INSTANT -> Timestamp[ns]; DATE -> Date32."""
    var nodes = List[OrcRawType]()
    nodes.append(_leaf(ORC_KIND_TIMESTAMP))
    nodes.append(_leaf(ORC_KIND_TIMESTAMP_INSTANT))
    nodes.append(_leaf(ORC_KIND_DATE))
    var schema = OrcSchema(nodes^)
    assert_true(orc_node_to_arrow(schema, 0) == ArrowType.TIMESTAMP_NS)
    assert_true(orc_node_to_arrow(schema, 1) == ArrowType.TIMESTAMP_NS)
    assert_true(orc_node_to_arrow(schema, 2) == ArrowType.DATE32)


def test_bad_child_index_and_empty_raise() raises:
    """T8: a subtypes index out of range raises; empty schema raises."""
    var bad = List[OrcRawType]()
    bad.append(_compound(ORC_KIND_STRUCT, _children(5), List[String]()))  # 5 OOR
    var raised = False
    try:
        var _s = OrcSchema.from_types(bad^)
    except:
        raised = True
    assert_true(raised, "bad child index must raise")

    var empty = List[OrcRawType]()
    var raised2 = False
    try:
        var _s = OrcSchema.from_types(empty^)
    except:
        raised2 = True
    assert_true(raised2, "empty schema must raise")


def _build_ab_struct() raises -> String:
    """Build struct<a:int,b:double> and return its canonical form."""
    var names = List[String]()
    names.append(String("a"))
    names.append(String("b"))
    var nodes = List[OrcRawType]()
    nodes.append(_compound(ORC_KIND_STRUCT, _children(1, 2), names))
    nodes.append(_leaf(ORC_KIND_INT))
    nodes.append(_leaf(ORC_KIND_DOUBLE))
    var schema = OrcSchema.from_types(nodes^)
    return schema.canonical_form()


def test_canonical_form_deterministic() raises:
    """T9: canonical form is stable across re-build."""
    assert_equal(_build_ab_struct(), _build_ab_struct())
    assert_equal(_build_ab_struct(), String("struct<a:int,b:double>"))


def main() raises:
    test_primitive_lattice()
    test_canonical_flat_struct()
    test_canonical_nested_array_map()
    test_canonical_decimal_varchar_char()
    test_canonical_uniontype()
    test_decimal_lattice_and_precision_cap()
    test_temporal_lattice()
    test_bad_child_index_and_empty_raise()
    test_canonical_form_deterministic()
    print("test_orc_schema_canonical_form: ALL PASS")
