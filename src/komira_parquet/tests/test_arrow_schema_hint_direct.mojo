# =============================================================================
# arrow_schema_hint.
#
# The `ARROW:schema` values are made here: an Arrow IPC Schema message from
# komira_arrow_ipc's encoder, base64-encoded by a test-local encoder.
#
# What each test proves:
#   * a value names the Arrow string and binary flavour of each top-level
#     field (string, large_string, dictionary<utf8>, binary, large_binary);
#     fields outside that family are not in the hint;
#   * the message parses with and without the continuation marker, and with
#     padding and line breaks in the base64 text;
#   * a key-value list with no `ARROW:schema`, the key with no value, and
#     values that are not base64 of a Schema message (empty, garbage, a
#     truncated message) all give an EMPTY hint and never raise;
#   * a name declared twice gives no hint for that name;
#   * refine_from_hint changes only the spelling of a string or binary type,
#     never a type the physical column cannot hold.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_arrow_ipc.ipc_encoder_dispatch import encode_schema_message
from komira_parquet_api.metadata import FileMetaData, KeyValue, SchemaElement, RowGroup
from komira_parquet.arrow_schema_hint import (
    ARROW_SCHEMA_KEY,
    ArrowSchemaHint,
    arrow_schema_hint_from_kv,
    arrow_schema_hint_from_metadata,
    parse_arrow_schema_value,
    refine_from_hint,
)

comptime _ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"


def _b64(bytes: List[UInt8], wrap: Int = 0) -> String:
    var alpha = _ALPHABET.as_bytes()
    var out = String()
    var i = 0
    var col = 0
    while i < len(bytes):
        var b0 = Int(bytes[i])
        var b1 = Int(bytes[i + 1]) if i + 1 < len(bytes) else 0
        var b2 = Int(bytes[i + 2]) if i + 2 < len(bytes) else 0
        var n = (b0 << 16) | (b1 << 8) | b2
        out += chr(Int(alpha[(n >> 18) & 63]))
        out += chr(Int(alpha[(n >> 12) & 63]))
        out += chr(Int(alpha[(n >> 6) & 63])) if i + 1 < len(bytes) else String("=")
        out += chr(Int(alpha[n & 63])) if i + 2 < len(bytes) else String("=")
        i += 3
        col += 4
        if wrap > 0 and col >= wrap:
            out += "\n"
            col = 0
    return out^


def _schema_bytes(skip_marker: Bool) raises -> List[UInt8]:
    var sb = SchemaBuilder()
    sb.add_field(Field("s", ArrowType.STRING, True))
    sb.add_field(Field("l", ArrowType.LARGE_STRING, True))
    sb.add_field(Field.dictionary("d", ArrowType.INT32, True))
    sb.add_field(Field("b", ArrowType.BINARY, False))
    sb.add_field(Field("lb", ArrowType.LARGE_BINARY, True))
    sb.add_field(Field("i", ArrowType.INT64, False))
    var schema = sb.build()
    var frame = encode_schema_message(schema)
    var view = frame.view_range_ro(0, frame.len()).into_span()
    var out = List[UInt8]()
    var start = 4 if skip_marker else 0
    for k in range(start, len(view)):
        out.append(view[k])
    return out^


def _check_full_hint(hint: ArrowSchemaHint) raises:
    assert_false(hint.is_empty())
    assert_equal(len(hint.names), 5)
    assert_true(hint.type_for_name("s").value() == ArrowType.STRING)
    assert_true(hint.type_for_name("l").value() == ArrowType.LARGE_STRING)
    assert_true(hint.type_for_name("d").value() == ArrowType.DICTIONARY)
    assert_true(hint.type_for_name("b").value() == ArrowType.BINARY)
    assert_true(hint.type_for_name("lb").value() == ArrowType.LARGE_BINARY)
    assert_false(Bool(hint.type_for_name("i")))
    assert_false(Bool(hint.type_for_name("absent")))


def test_a_value_names_each_string_and_binary_flavour() raises:
    _check_full_hint(parse_arrow_schema_value(_b64(_schema_bytes(False))))


def test_framing_and_base64_whitespace() raises:
    # Without the 0xFFFFFFFF continuation marker (older writers).
    _check_full_hint(parse_arrow_schema_value(_b64(_schema_bytes(True))))
    # Line breaks every 76 characters, and the "=" padding.
    _check_full_hint(parse_arrow_schema_value(_b64(_schema_bytes(False), wrap=76)))


def test_unreadable_values_give_an_empty_hint() raises:
    assert_true(parse_arrow_schema_value("").is_empty())
    assert_true(parse_arrow_schema_value("!!!! not base64 ????").is_empty())
    assert_true(parse_arrow_schema_value("AAAAAAAAAAAAAAAA").is_empty())
    var full = _schema_bytes(False)
    var cut = List[UInt8]()
    for k in range(len(full) // 2):
        cut.append(full[k])
    assert_true(parse_arrow_schema_value(_b64(cut)).is_empty())


def test_key_value_lookup() raises:
    assert_true(arrow_schema_hint_from_kv(None).is_empty())
    var other: List[KeyValue] = [KeyValue("pandas", String("{}"))]
    assert_true(arrow_schema_hint_from_kv(other^).is_empty())
    var no_value: List[KeyValue] = [KeyValue(ARROW_SCHEMA_KEY)]
    assert_true(arrow_schema_hint_from_kv(no_value^).is_empty())
    var wrong_case: List[KeyValue] = [KeyValue("arrow:schema", _b64(_schema_bytes(False)))]
    assert_true(arrow_schema_hint_from_kv(wrong_case^).is_empty())
    var kv: List[KeyValue] = [KeyValue("pandas", String("{}")), KeyValue(ARROW_SCHEMA_KEY, _b64(_schema_bytes(False)))]
    var schema: List[SchemaElement] = [SchemaElement(name="schema")]
    var md = FileMetaData(version=2, schema=schema^, num_rows=0, row_groups=List[RowGroup]())
    assert_true(arrow_schema_hint_from_metadata(md).is_empty())
    md.key_value_metadata = kv^
    _check_full_hint(arrow_schema_hint_from_metadata(md))


def test_a_name_declared_twice_is_not_refined() raises:
    var names: List[String] = ["s", "s", "t"]
    var types: List[ArrowType] = [ArrowType.STRING, ArrowType.LARGE_STRING, ArrowType.BINARY]
    var hint = ArrowSchemaHint(names^, types^)
    assert_false(Bool(hint.type_for_name("s")))
    assert_true(hint.type_for_name("t").value() == ArrowType.BINARY)


def test_refine_changes_only_the_spelling() raises:
    var none = Optional[ArrowType](None)
    assert_true(refine_from_hint(ArrowType.STRING, none) == ArrowType.STRING)
    assert_true(refine_from_hint(ArrowType.STRING, ArrowType.LARGE_STRING) == ArrowType.LARGE_STRING)
    assert_true(refine_from_hint(ArrowType.STRING, ArrowType.DICTIONARY) == ArrowType.DICTIONARY)
    assert_true(refine_from_hint(ArrowType.STRING, ArrowType.STRING) == ArrowType.STRING)
    assert_true(refine_from_hint(ArrowType.STRING, ArrowType.LARGE_BINARY) == ArrowType.STRING)
    assert_true(refine_from_hint(ArrowType.BINARY, ArrowType.LARGE_BINARY) == ArrowType.LARGE_BINARY)
    assert_true(refine_from_hint(ArrowType.BINARY, ArrowType.LARGE_STRING) == ArrowType.BINARY)
    assert_true(refine_from_hint(ArrowType.BINARY, ArrowType.DICTIONARY) == ArrowType.BINARY)
    assert_true(refine_from_hint(ArrowType.INT64, ArrowType.STRING) == ArrowType.INT64)
    assert_true(refine_from_hint(ArrowType.INT64, ArrowType.LARGE_STRING) == ArrowType.INT64)
    assert_true(refine_from_hint(ArrowType.FLOAT64, ArrowType.BINARY) == ArrowType.FLOAT64)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
