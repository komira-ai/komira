# =============================================================================
# test_avro_cov_schema.mojo -- the schema parser's refusal arms, the kind-name
# diagnostics, and the Avro -> Arrow mapping of the complex kinds and the
# logical types no file-level test carries.
# =============================================================================
#
# What each case proves, and the mutant planted in the product code to see
# it fail (each alone, then restored; the red message is quoted):
#   K1  `_kind_name` (the Parsing Canonical Form names) and `avro_kind_name`
#       (diagnostics) name every kind, and an unknown kind as "unknown" /
#       "kind#<n>". Mutant: avro_kind_name's map arm writes "array": red,
#       "array" vs "map".
#   A1  avro_node_to_arrow maps record -> STRUCT, array -> LIST, map -> MAP,
#       null -> NULL, local-timestamp-millis/micros -> TIMESTAMP_MS/US,
#       duration over fixed(12) -> INTERVAL_MONTH_DAY_NANO; refuses a
#       decimal precision above 76 and a node of no known kind. Mutant:
#       local-timestamp-micros -> TIMESTAMP_MS: red, "local-timestamp-micros".
#   A2  a logical type over the wrong physical type is refused for the
#       local-timestamp and duration annotations. Mutant: duration also
#       accepts `bytes`: red, "(accepted)" vs LOGICAL_TYPE_PHYSICAL_MISMATCH.
#   P1  each structural refusal of `_build_node` (unknown named type, an
#       object with no "type", "fields" not an array, a field that is not an
#       object, object-form union "branches" not an array, an unknown type
#       name, a schema that is a JSON number or boolean) is raised by name.
#   P2  each JSON refusal of the schema parser (end of input, key not a
#       string, missing ':', missing ',' or '}', a bad boolean, a bad null,
#       an integer of 20 digits, an integer above Int64.MAX) is raised with
#       its byte offset; `false` and a final `null` parse. Mutants:
#       `_match_literal`'s `>` -> `>=`: red, "bad boolean literal at byte 0"
#       for the schema `true`; the digit limit `> 19` -> `> 20`: red,
#       "overflows" vs "has 20 digits".
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType

from komira_avro import (
    AvroSchema,
    avro_node_to_arrow,
    AVRO_KIND_NULL,
    AVRO_KIND_BOOLEAN,
    AVRO_KIND_INT,
    AVRO_KIND_LONG,
    AVRO_KIND_FLOAT,
    AVRO_KIND_DOUBLE,
    AVRO_KIND_BYTES,
    AVRO_KIND_STRING,
    AVRO_KIND_RECORD,
    AVRO_KIND_ENUM,
    AVRO_KIND_ARRAY,
    AVRO_KIND_MAP,
    AVRO_KIND_UNION,
    AVRO_KIND_FIXED,
)
from komira_avro.avro_schema import _kind_name, avro_kind_name


def test_kind_names() raises:
    """K1."""
    var kinds: List[Int] = [
        AVRO_KIND_NULL,
        AVRO_KIND_BOOLEAN,
        AVRO_KIND_INT,
        AVRO_KIND_LONG,
        AVRO_KIND_FLOAT,
        AVRO_KIND_DOUBLE,
        AVRO_KIND_BYTES,
        AVRO_KIND_STRING,
        AVRO_KIND_RECORD,
        AVRO_KIND_ENUM,
        AVRO_KIND_ARRAY,
        AVRO_KIND_MAP,
        AVRO_KIND_UNION,
        AVRO_KIND_FIXED,
    ]
    var names: List[String] = [
        "null",
        "boolean",
        "int",
        "long",
        "float",
        "double",
        "bytes",
        "string",
        "record",
        "enum",
        "array",
        "map",
        "union",
        "fixed",
    ]
    for i in range(len(kinds)):
        assert_equal(_kind_name(kinds[i]), names[i], "_kind_name " + names[i])
        assert_equal(
            avro_kind_name(kinds[i]), names[i], "avro_kind_name " + names[i]
        )
    assert_equal(_kind_name(99), "unknown")
    assert_equal(avro_kind_name(99), "kind#99")
    assert_equal(avro_kind_name(-1), "kind#-1")


def _arrow_of_root(json: String) raises -> ArrowType:
    var s = AvroSchema.parse(json)
    return avro_node_to_arrow(s, s.root())


def _arrow_err(json: String) -> String:
    try:
        _ = _arrow_of_root(json)
    except e:
        return String(e)
    return String("(accepted)")


def test_complex_and_logical_mapping() raises:
    """A1."""
    var rec = AvroSchema.parse(
        '{"type":"record","name":"R","fields":['
        '{"name":"a","type":{"type":"array","items":"int"}},'
        '{"name":"m","type":{"type":"map","values":"long"}},'
        '{"name":"n","type":"null"}]}'
    )
    var root = rec.node(rec.root())
    assert_true(avro_node_to_arrow(rec, rec.root()) == ArrowType.STRUCT, "rec")
    assert_true(
        avro_node_to_arrow(rec, root.children[0]) == ArrowType.LIST, "array"
    )
    assert_true(
        avro_node_to_arrow(rec, root.children[1]) == ArrowType.MAP, "map"
    )
    assert_true(
        avro_node_to_arrow(rec, root.children[2]) == ArrowType.NULL, "null"
    )
    assert_true(
        _arrow_of_root('{"type":"long","logicalType":"local-timestamp-millis"}')
        == ArrowType.TIMESTAMP_MS,
        "local-timestamp-millis",
    )
    assert_true(
        _arrow_of_root('{"type":"long","logicalType":"local-timestamp-micros"}')
        == ArrowType.TIMESTAMP_US,
        "local-timestamp-micros",
    )
    assert_true(
        _arrow_of_root(
            '{"type":"fixed","name":"D","size":12,"logicalType":"duration"}'
        )
        == ArrowType.INTERVAL_MONTH_DAY_NANO,
        "duration",
    )
    assert_equal(
        _arrow_err(
            '{"type":"bytes","logicalType":"decimal","precision":77,"scale":0}'
        ),
        "AvroSchemaError.DECIMAL_PRECISION_TOO_LARGE: limit=76",
    )
    assert_true(
        _arrow_of_root(
            '{"type":"bytes","logicalType":"decimal","precision":76,"scale":0}'
        )
        == ArrowType.DECIMAL256,
        "precision 76",
    )
    # A node of no known kind (the arena is plain data: a corrupted kind is
    # refused, not mapped).
    var odd = AvroSchema.parse('"int"')
    odd.nodes[odd.root()].kind = 99
    var got = String("(accepted)")
    try:
        _ = avro_node_to_arrow(odd, odd.root())
    except e:
        got = String(e)
    assert_equal(got, "AvroSchemaError.UNKNOWN_TYPE in avro_node_to_arrow")


def _mismatch(logical: String, expected: String, physical: String) -> String:
    return (
        String("AvroSchemaError.LOGICAL_TYPE_PHYSICAL_MISMATCH: logicalType '")
        + logical
        + "' requires an underlying Avro "
        + expected
        + ", but this node's physical type is "
        + physical
        + " (the schema in the file header is not self-consistent)"
    )


def test_logical_physical_mismatch() raises:
    """A2."""
    assert_equal(
        _arrow_err('{"type":"int","logicalType":"local-timestamp-millis"}'),
        _mismatch("local-timestamp-millis", "long", "int"),
    )
    assert_equal(
        _arrow_err('{"type":"string","logicalType":"local-timestamp-micros"}'),
        _mismatch("local-timestamp-micros", "long", "string"),
    )
    assert_equal(
        _arrow_err('{"type":"bytes","logicalType":"duration"}'),
        _mismatch("duration", "fixed(12)", "bytes"),
    )


def _refusal(text: String) -> String:
    try:
        var _s = AvroSchema.parse(text)
    except e:
        return String(e)
    return String("(accepted)")


comptime _MJ = "AvroSchemaError.MALFORMED_JSON: "


def test_structure_refusals() raises:
    """P1."""
    assert_equal(_refusal('"Nowhere"'), "AvroSchemaError.UNKNOWN_TYPE: Nowhere")
    assert_equal(
        _refusal('{"name":"x"}'), _MJ + "object missing 'type'"
    )
    assert_equal(
        _refusal('{"type":"record","name":"R","fields":5}'),
        _MJ + "record 'fields' not array",
    )
    assert_equal(
        _refusal('{"type":"record","name":"R","fields":[5]}'),
        _MJ + "field not object",
    )
    assert_equal(
        _refusal('{"type":"union","branches":"int"}'),
        _MJ + "object-form union 'branches' not array",
    )
    assert_equal(
        _refusal('{"type":"nosuch"}'), "AvroSchemaError.UNKNOWN_TYPE: nosuch"
    )
    assert_equal(_refusal("5"), _MJ + "unexpected JSON value")
    assert_equal(_refusal("true"), _MJ + "unexpected JSON value")


def test_json_refusals() raises:
    """P2."""
    assert_equal(
        _refusal('{"type":'), _MJ + "unexpected end of input at byte 8"
    )
    assert_equal(_refusal("{"), _MJ + "object key not string at byte 1")
    assert_equal(_refusal('{"a" 1}'), _MJ + "expected ':' at byte 5")
    assert_equal(_refusal('{"a":1 2}'), _MJ + "expected ',' or '}' at byte 7")
    assert_equal(_refusal("[fx]"), _MJ + "bad boolean literal at byte 1")
    assert_equal(_refusal("[tru"), _MJ + "bad boolean literal at byte 1")
    assert_equal(_refusal("[nul"), _MJ + "bad null literal at byte 1")
    assert_equal(_refusal("[nulx]"), _MJ + "bad null literal at byte 1")
    # `false` and a `null` that ends the text are values; they reach the
    # schema builder, which refuses them as types.
    assert_equal(
        _refusal('{"type":"string","x":false}'), "(accepted)"
    )
    assert_equal(_refusal("null"), _MJ + "unexpected JSON value")
    assert_equal(
        _refusal('{"type":"fixed","name":"F","size":12345678901234567890}'),
        _MJ + "integer literal has 20 digits, which cannot be represented"
        " (max 19)",
    )
    assert_equal(
        _refusal('{"type":"fixed","name":"F","size":9223372036854775808}'),
        _MJ + "integer literal overflows a 64-bit signed integer",
    )
    # Int64.MAX itself is representable; it is then refused as a fixed size.
    var big = _refusal(
        '{"type":"fixed","name":"F","size":9223372036854775807}'
    )
    assert_true(big.find("FIXED_SIZE_OUT_OF_RANGE") >= 0, big)


def main() raises:
    test_kind_names()
    test_complex_and_logical_mapping()
    test_logical_physical_mismatch()
    test_structure_refusals()
    test_json_refusals()
    print("test_avro_cov_schema: ALL PASS")
