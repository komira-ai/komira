# =============================================================================
# test_avro_schema_names.mojo — AvroSchema.parse refuses names, namespaces and
# enum symbols that are not Avro names; valid schemas keep the reference
# Parsing Canonical Form and fingerprint.
# =============================================================================
#
# Spec (Avro 1.11.1, "Names"): the name part of a fullname, a field name and an
# enum symbol match [A-Za-z_][A-Za-z0-9_]*; a fullname or namespace is a
# dot-separated sequence of such names; "" as a namespace is the null
# namespace. Parsing Canonical Form copies names unescaped, so a name holding
# '"' or '\' would make the canonical form invalid JSON.
#
#   T1 each invalid form is refused with its exact message.
#   T2 valid names, dotted fullnames, "" and dotted namespaces are accepted.
#   T3 canonical form and fingerprint equal the Apache Avro reference vectors
#      (share/test/data/schema-tests.txt, release 1.11.1, cases 019, 021,
#      025, 026, 027, 029; fingerprints are the file's signed longs as u64).
# =============================================================================

from std.testing import assert_equal

from komira_avro import AvroSchema


comptime _PAT = " does not match [A-Za-z_][A-Za-z0-9_]*"


def _refusal(json: String) -> String:
    try:
        _ = AvroSchema.parse(json)
    except e:
        return String(e)
    return String("<accepted>")


def _rec(name_member: String) -> String:
    return '{"type":"record",' + name_member + ',"fields":[]}'


def test_record_name_refusals() raises:
    """T1: record names, including each dotted component."""
    assert_equal(
        _refusal(_rec('"name":"a-b"')),
        "AvroSchemaError.INVALID_NAME: record name 'a-b'" + _PAT,
    )
    assert_equal(
        _refusal(_rec('"name":"1a"')),
        "AvroSchemaError.INVALID_NAME: record name '1a'" + _PAT,
    )
    assert_equal(
        _refusal('{"type":"record","fields":[]}'),
        "AvroSchemaError.INVALID_NAME: record name ''" + _PAT,
    )
    assert_equal(
        _refusal(_rec('"name":"a\\"b"')),
        "AvroSchemaError.INVALID_NAME: record name 'a\"b'" + _PAT,
    )
    assert_equal(
        _refusal(_rec('"name":"x.1y"')),
        "AvroSchemaError.INVALID_NAME: record name 'x.1y': component '1y'"
        + _PAT,
    )
    assert_equal(
        _refusal(_rec('"name":"a..b"')),
        "AvroSchemaError.INVALID_NAME: record name 'a..b': component ''"
        + _PAT,
    )
    assert_equal(
        _refusal(_rec('"name":".foo"')),
        "AvroSchemaError.INVALID_NAME: record name '.foo': component ''"
        + _PAT,
    )
    assert_equal(
        _refusal(_rec('"name":"foo."')),
        "AvroSchemaError.INVALID_NAME: record name 'foo.': component ''"
        + _PAT,
    )
    # A letter outside ASCII is not in [A-Za-z].
    assert_equal(
        _refusal(_rec('"name":"\\u00e9t"')),
        "AvroSchemaError.INVALID_NAME: record name 'ét'" + _PAT,
    )


def test_namespace_refusals() raises:
    """T1: namespaces on record, enum and fixed."""
    assert_equal(
        _refusal(_rec('"name":"R","namespace":"x-y"')),
        "AvroSchemaError.INVALID_NAME: record namespace 'x-y'" + _PAT,
    )
    assert_equal(
        _refusal(_rec('"name":"R","namespace":"x..y"')),
        "AvroSchemaError.INVALID_NAME: record namespace 'x..y': component ''"
        + _PAT,
    )
    assert_equal(
        _refusal(
            '{"type":"enum","name":"E","namespace":"a.9","symbols":["A"]}'
        ),
        "AvroSchemaError.INVALID_NAME: enum namespace 'a.9': component '9'"
        + _PAT,
    )
    assert_equal(
        _refusal('{"type":"fixed","name":"F","namespace":"a b","size":1}'),
        "AvroSchemaError.INVALID_NAME: fixed namespace 'a b'" + _PAT,
    )


def test_field_enum_fixed_refusals() raises:
    """T1: field names, enum names and symbols, fixed names."""
    assert_equal(
        _refusal(
            '{"type":"record","name":"R","fields":'
            '[{"name":"a\\"b","type":"int"}]}'
        ),
        "AvroSchemaError.INVALID_NAME: field name 'a\"b'" + _PAT,
    )
    assert_equal(
        _refusal(
            '{"type":"record","name":"R","fields":'
            '[{"name":"a\\\\b","type":"int"}]}'
        ),
        "AvroSchemaError.INVALID_NAME: field name 'a\\b'" + _PAT,
    )
    # A field name is a simple name: a dot is refused, not split.
    assert_equal(
        _refusal(
            '{"type":"record","name":"R","fields":'
            '[{"name":"a.b","type":"int"}]}'
        ),
        "AvroSchemaError.INVALID_NAME: field name 'a.b'" + _PAT,
    )
    assert_equal(
        _refusal(
            '{"type":"record","name":"R","fields":[{"type":"int"}]}'
        ),
        "AvroSchemaError.INVALID_NAME: field name ''" + _PAT,
    )
    assert_equal(
        _refusal('{"type":"enum","name":"E","symbols":["A","B\\"C"]}'),
        "AvroSchemaError.INVALID_NAME: enum symbol 'B\"C'" + _PAT,
    )
    assert_equal(
        _refusal('{"type":"enum","name":"E","symbols":["A","b.c"]}'),
        "AvroSchemaError.INVALID_NAME: enum symbol 'b.c'" + _PAT,
    )
    assert_equal(
        _refusal('{"type":"enum","name":"E","symbols":["A",5]}'),
        "AvroSchemaError.INVALID_NAME: enum symbol ''" + _PAT,
    )
    assert_equal(
        _refusal('{"type":"enum","name":"E-1","symbols":["A"]}'),
        "AvroSchemaError.INVALID_NAME: enum name 'E-1'" + _PAT,
    )
    assert_equal(
        _refusal('{"type":"fixed","name":"x.","size":4}'),
        "AvroSchemaError.INVALID_NAME: fixed name 'x.': component ''" + _PAT,
    )


def test_valid_names_accepted() raises:
    """T2: every legal form parses."""
    assert_equal(_refusal(_rec('"name":"_"')), "<accepted>")
    assert_equal(_refusal(_rec('"name":"_a9Z"')), "<accepted>")
    assert_equal(_refusal(_rec('"name":"a.b._c9.Foo"')), "<accepted>")
    assert_equal(_refusal(_rec('"name":"R","namespace":""')), "<accepted>")
    assert_equal(_refusal(_rec('"name":"R","namespace":"x.y_1"')), "<accepted>")
    assert_equal(
        _refusal(
            '{"type":"record","name":"R","fields":[{"name":"_f1","type":'
            '{"type":"enum","name":"E","namespace":"","symbols":["A1","_b"]}},'
            '{"name":"g","type":{"type":"fixed","name":"n.F","size":2}}]}'
        ),
        "<accepted>",
    )


def _check_vector(json: String, pcf: String, fp: UInt64) raises:
    var s = AvroSchema.parse(json)
    assert_equal(s.parsing_canonical_form(), pcf)
    assert_equal(s.fingerprint(), fp)


def test_reference_canonical_form_and_fingerprint() raises:
    """T3: Apache Avro schema-tests.txt vectors are unchanged."""
    # 019: fingerprint -4824392279771201922
    _check_vector(
        '{"fields":[], "type":"record", "name":"foo"}',
        '{"name":"foo","type":"record","fields":[]}',
        UInt64(0xBD0C50C84319BE7E),
    )
    # 021: a dotted name wins over the namespace; -4616218487480524110
    _check_vector(
        '{"fields":[], "type":"record", "name":"a.b.foo", "namespace":"x.y"}',
        '{"name":"a.b.foo","type":"record","fields":[]}',
        UInt64(0xBFEFE5BE5021E2B2),
    )
    # 025: 7843277075252814651
    _check_vector(
        '{"fields":[{"type":{"type":"boolean"}, "name":"f1"}],'
        ' "type":"record", "name":"foo"}',
        '{"name":"foo","type":"record","fields":[{"name":"f1",'
        '"type":"boolean"}]}',
        UInt64(0x6CD8EAF1C968A33B),
    )
    # 026: -4860222112080293046
    _check_vector(
        '{ "fields":[{"type":"boolean", "aliases":[], "name":"f1",'
        ' "default":true},'
        ' {"order":"descending","name":"f2","doc":"Hello","type":"int"}],'
        ' "type":"record", "name":"foo"}',
        '{"name":"foo","type":"record","fields":[{"name":"f1",'
        '"type":"boolean"},{"name":"f2","type":"int"}]}',
        UInt64(0xBC8D05BD57F4934A),
    )
    # 027: -6342190197741309591
    _check_vector(
        '{"type":"enum", "name":"foo", "symbols":["A1"]}',
        '{"name":"foo","type":"enum","symbols":["A1"]}',
        UInt64(0xA7FC039E15AA3169),
    )
    # 029: 1756455273707447556
    _check_vector(
        '{"name":"foo","type":"fixed","size":15}',
        '{"name":"foo","type":"fixed","size":15}',
        UInt64(0x18602EC3ED31A504),
    )


def main() raises:
    test_record_name_refusals()
    test_namespace_refusals()
    test_field_enum_fixed_refusals()
    test_valid_names_accepted()
    test_reference_canonical_form_and_fingerprint()
    print("test_avro_schema_names: ALL PASS")
