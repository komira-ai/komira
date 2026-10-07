# =============================================================================
# test_avro_schema_parse.mojo — AvroSchema JSON parse + Parsing Canonical Form
#                               + CRC-64-AVRO fingerprint + type lattice.
# =============================================================================
#
# Acceptance:
#   - JSON -> canonical form fixture.
#   - CRC-64-AVRO ("Rabin") fingerprint check against known reference vectors.
#   - Avro -> Arrow type lattice mapping.
#
# Coverage:
#   T1  primitive PCF: "int"/"long"/"string"/etc. reduce to bare type-name.
#   T2  CRC-64-AVRO reference vectors for primitive canonical forms.
#   T3  record PCF: STRIP non-parsing attributes, fixed member order.
#   T4  union[null, T] PCF.
#   T5  enum PCF (symbols preserved + ordered).
#   T6  fixed PCF (size as bare integer).
#   T7  array / map PCF.
#   T8  Avro -> Arrow lattice: primitives.
#   T9  Avro -> Arrow lattice: logical types (date / timestamp / decimal).
#   T10 Avro -> Arrow lattice: union[null, T] collapses to nullable T.
#   T11 fingerprint is stable across re-parse (determinism).
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_avro import AvroSchema, avro_node_to_arrow, crc_64_avro
from komira_arrow.arrow_types import ArrowType


def _fp(json: String) raises -> UInt64:
    var s = AvroSchema.parse(json)
    return s.fingerprint()


def _pcf(json: String) raises -> String:
    var s = AvroSchema.parse(json)
    return s.parsing_canonical_form()


def test_primitive_pcf() raises:
    """T1: primitives canonicalize to their bare quoted type-name."""
    assert_equal(_pcf(String('"int"')), String('"int"'))
    assert_equal(_pcf(String('"long"')), String('"long"'))
    assert_equal(_pcf(String('"string"')), String('"string"'))
    assert_equal(_pcf(String('"boolean"')), String('"boolean"'))
    assert_equal(_pcf(String('"null"')), String('"null"'))
    assert_equal(_pcf(String('"double"')), String('"double"'))
    assert_equal(_pcf(String('"bytes"')), String('"bytes"'))
    # Object-form primitive reduces to bare name (logical type stripped from PCF).
    assert_equal(_pcf(String('{"type":"int"}')), String('"int"'))


def test_crc64_avro_reference_vectors() raises:
    """T2: CRC-64-AVRO of canonical primitive forms == published Avro vectors.

    Reference values from the Avro spec SchemaNormalization fingerprint64
    over the canonical form string. crc_64_avro is called directly over the
    canonical-form bytes for each primitive.
    """
    # fingerprint64("\"null\"") == 0x63dd24e7cc258f8a
    assert_equal(_fp(String('"null"')), UInt64(0x63dd24e7cc258f8a))
    # fingerprint64("\"boolean\"") == 0x9f42fc78a4d4f764
    assert_equal(_fp(String('"boolean"')), UInt64(0x9f42fc78a4d4f764))
    # fingerprint64("\"int\"") == 0x7275d51a3f395c8f
    assert_equal(_fp(String('"int"')), UInt64(0x7275d51a3f395c8f))
    # fingerprint64("\"long\"") == 0xd054e14493f41db7
    assert_equal(_fp(String('"long"')), UInt64(0xd054e14493f41db7))
    # fingerprint64("\"string\"") == 0x8f014872634503c7
    assert_equal(_fp(String('"string"')), UInt64(0x8f014872634503c7))


def test_record_pcf_strips_and_orders() raises:
    """T3: record PCF strips non-parsing attributes; fixed member order."""
    var json = String(
        '{"type":"record","name":"Test","doc":"ignored",'
        '"fields":[{"name":"f","type":"long","doc":"d"},'
        '{"name":"g","type":"int"}]}'
    )
    var expect = String(
        '{"name":"Test","type":"record","fields":'
        '[{"name":"f","type":"long"},{"name":"g","type":"int"}]}'
    )
    assert_equal(_pcf(json), expect)


def test_union_pcf() raises:
    """T4: union renders as a JSON array of canonical branches."""
    var json = String('["null","long"]')
    assert_equal(_pcf(json), String('["null","long"]'))


def test_enum_pcf() raises:
    """T5: enum PCF preserves ordered symbols, strips doc/default."""
    var json = String(
        '{"type":"enum","name":"Suit","doc":"x",'
        '"symbols":["SPADES","HEARTS","DIAMONDS","CLUBS"]}'
    )
    var expect = String(
        '{"name":"Suit","type":"enum",'
        '"symbols":["SPADES","HEARTS","DIAMONDS","CLUBS"]}'
    )
    assert_equal(_pcf(json), expect)


def test_fixed_pcf() raises:
    """T6: fixed PCF emits size as a bare integer (no quotes)."""
    var json = String('{"type":"fixed","name":"md5","size":16}')
    assert_equal(_pcf(json), String('{"name":"md5","type":"fixed","size":16}'))


def test_array_map_pcf() raises:
    """T7: array/map PCF emit items/values canonical child."""
    assert_equal(
        _pcf(String('{"type":"array","items":"string"}')),
        String('{"type":"array","items":"string"}'),
    )
    assert_equal(
        _pcf(String('{"type":"map","values":"int"}')),
        String('{"type":"map","values":"int"}'),
    )


def test_lattice_primitives() raises:
    """T8: Avro -> Arrow lattice for primitives."""
    var s_int = AvroSchema.parse(String('"int"'))
    assert_true(avro_node_to_arrow(s_int, s_int.root()) == ArrowType.INT32)
    var s_long = AvroSchema.parse(String('"long"'))
    assert_true(avro_node_to_arrow(s_long, s_long.root()) == ArrowType.INT64)
    var s_float = AvroSchema.parse(String('"float"'))
    assert_true(avro_node_to_arrow(s_float, s_float.root()) == ArrowType.FLOAT32)
    var s_double = AvroSchema.parse(String('"double"'))
    assert_true(avro_node_to_arrow(s_double, s_double.root()) == ArrowType.FLOAT64)
    var s_str = AvroSchema.parse(String('"string"'))
    assert_true(avro_node_to_arrow(s_str, s_str.root()) == ArrowType.STRING)
    var s_bool = AvroSchema.parse(String('"boolean"'))
    assert_true(avro_node_to_arrow(s_bool, s_bool.root()) == ArrowType.BOOL)
    var s_bytes = AvroSchema.parse(String('"bytes"'))
    assert_true(avro_node_to_arrow(s_bytes, s_bytes.root()) == ArrowType.BINARY)


def test_lattice_logical_types() raises:
    """T9: Avro -> Arrow lattice for logical types."""
    var s_date = AvroSchema.parse(String('{"type":"int","logicalType":"date"}'))
    assert_true(avro_node_to_arrow(s_date, s_date.root()) == ArrowType.DATE32)

    var s_ts = AvroSchema.parse(
        String('{"type":"long","logicalType":"timestamp-micros"}')
    )
    assert_true(avro_node_to_arrow(s_ts, s_ts.root()) == ArrowType.TIMESTAMP_US)

    var s_dec = AvroSchema.parse(
        String('{"type":"bytes","logicalType":"decimal","precision":10,"scale":2}')
    )
    assert_true(avro_node_to_arrow(s_dec, s_dec.root()) == ArrowType.DECIMAL128)

    var s_dec256 = AvroSchema.parse(
        String('{"type":"bytes","logicalType":"decimal","precision":50,"scale":4}')
    )
    assert_true(avro_node_to_arrow(s_dec256, s_dec256.root()) == ArrowType.DECIMAL256)


def test_lattice_union_null_collapse() raises:
    """T10: union[null, T] / union[T, null] -> nullable Arrow T."""
    var s1 = AvroSchema.parse(String('["null","long"]'))
    assert_true(avro_node_to_arrow(s1, s1.root()) == ArrowType.INT64)
    var s2 = AvroSchema.parse(String('["string","null"]'))
    assert_true(avro_node_to_arrow(s2, s2.root()) == ArrowType.STRING)


def test_fingerprint_deterministic() raises:
    """T11: re-parsing the same schema yields the same fingerprint."""
    var json = String(
        '{"type":"record","name":"R","fields":[{"name":"a","type":"int"},'
        '{"name":"b","type":["null","string"]}]}'
    )
    assert_equal(_fp(json), _fp(json))


def main() raises:
    test_primitive_pcf()
    test_crc64_avro_reference_vectors()
    test_record_pcf_strips_and_orders()
    test_union_pcf()
    test_enum_pcf()
    test_fixed_pcf()
    test_array_map_pcf()
    test_lattice_primitives()
    test_lattice_logical_types()
    test_lattice_union_null_collapse()
    test_fingerprint_deterministic()
    print("test_avro_schema_parse: ALL PASS")
