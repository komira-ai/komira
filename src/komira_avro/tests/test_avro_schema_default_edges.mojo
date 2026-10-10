# =============================================================================
# test_avro_schema_default_edges.mojo -- two edges of field-default capture in
# `AvroSchema.parse`: the most negative `long`, and a default on a field
# whose type is the empty union.
# =============================================================================
#
# What each case proves, and the defect it catches:
#   D1  a `long` default of -9223372036854775808 (Int64.MIN) parses and is
#       captured as that value; -9223372036854775807 and 9223372036854775807
#       still parse; one past either end (-9223372036854775809,
#       9223372036854775808) is refused as an overflow, as are the 19-digit
#       magnitudes above Int64.MAX of either sign. Catches a parser that
#       builds the magnitude as a positive Int and negates it at the end (2^63
#       overflows before the sign is applied, so Int64.MIN was refused), and
#       one that accepts 2^63 without a sign once the negative side is fixed.
#       Mutant: drop the unsigned `== Int64.MIN` refusal: red, "(accepted)"
#       for 9223372036854775808.
#   D2  a field whose type is `[]` and that carries a default is refused with
#       INVALID_DEFAULT, for an int, a null, a string and an object default
#       (the Avro specification reads a union default as its first matching
#       branch; an empty union has no branch, so no default is valid). The
#       same field without a default still parses. Catches the parser that
#       read the default by its JSON type alone and recorded it. Mutant:
#       refuse only when the default is not null: red, "(accepted)" for the
#       null default.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_avro import AvroSchema, AVRO_DEFAULT_INT


comptime _MJ = "AvroSchemaError.MALFORMED_JSON: "
comptime _OVERFLOW = _MJ + "integer literal overflows a 64-bit signed integer"


def _long_field(default: String) -> String:
    return (
        '{"type":"record","name":"R","fields":[{"name":"a","type":"long",'
        + '"default":'
        + default
        + "}]}"
    )


def _refusal(json: String) -> String:
    try:
        _ = AvroSchema.parse(json)
    except e:
        return String(e)
    return "(accepted)"


def _long_default(literal: String) raises -> Int64:
    var s = AvroSchema.parse(_long_field(literal))
    ref d = s.node(s.root()).field_defaults[0]
    assert_equal(d.kind, AVRO_DEFAULT_INT, literal + " kind")
    return d.int_val


def test_long_default_extremes() raises:
    """D1."""
    assert_equal(
        _long_default("-9223372036854775808"), Int64.MIN, "Int64.MIN"
    )
    assert_equal(
        _long_default("-9223372036854775807"),
        Int64.MIN + 1,
        "Int64.MIN + 1",
    )
    assert_equal(
        _long_default("9223372036854775807"), Int64.MAX, "Int64.MAX"
    )
    assert_equal(_long_default("-0"), Int64(0), "-0")
    assert_equal(_long_default("-7"), Int64(-7), "-7")
    assert_equal(_refusal(_long_field("9223372036854775808")), _OVERFLOW)
    assert_equal(_refusal(_long_field("-9223372036854775809")), _OVERFLOW)
    assert_equal(_refusal(_long_field("9999999999999999999")), _OVERFLOW)
    assert_equal(_refusal(_long_field("-9999999999999999999")), _OVERFLOW)


def _empty_union_field(default: String) -> String:
    return (
        '{"type":"record","name":"R","fields":[{"name":"a","type":[]'
        + default
        + "}]}"
    )


def test_empty_union_default_refused() raises:
    """D2."""
    var want = String(
        "AvroSchemaError.INVALID_DEFAULT: field 'a' has a default, but its"
        " type is the empty union, which has no branch to read it as"
    )
    var defaults: List[String] = [
        ',"default":1', ',"default":null', ',"default":"x"', ',"default":{}'
    ]
    for d in defaults:
        assert_equal(_refusal(_empty_union_field(d)), want, d)
    var s = AvroSchema.parse(_empty_union_field(""))
    assert_equal(len(s.node(s.root()).field_defaults), 1)
    assert_true(_refusal(_empty_union_field("")) == "(accepted)")


def main() raises:
    # Each case runs even when the other fails, and every failure is shown.
    var failed = String("")
    try:
        test_long_default_extremes()
    except e:
        failed += "D1: " + String(e) + "\n"
    try:
        test_empty_union_default_refused()
    except e:
        failed += "D2: " + String(e) + "\n"
    if failed != "":
        raise Error(failed)
    print("test_avro_schema_default_edges: ALL PASS")
