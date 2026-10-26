# Direct tests of arrow_schema_hint.mojo beyond test_arrow_schema_hint_direct:
# base64 values that use the '+' and '/' digits, an IPC message that is not a
# Schema, and the type-tag mapping of dictionary-encoded fields (a utf8 or
# large utf8 value type is a dictionary column, any other value type is not
# refined).
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow_ipc.ipc_encoder_dispatch import encode_record_batch_message
from komira_arrow_ipc.ipc_flatbuf import (
    TYPE_BINARY,
    TYPE_LARGE_BINARY,
    TYPE_LARGE_UTF8,
    TYPE_UTF8,
)
from komira_buffer.heap_region import HeapRegion
from komira_collections.slab import Slab

from komira_parquet.arrow_schema_hint import (
    _b64_decode_into_buffer,
    _ipc_type_tag_to_arrow_type,
    parse_arrow_schema_value,
)

comptime _ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"


def _b64(bytes: List[UInt8]) -> String:
    var alpha = _ALPHABET.as_bytes()
    var out = String()
    var i = 0
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
    return out^


def test_base64_plus_and_slash_decode_to_their_sextets() raises:
    # '+' is 62 and '/' is 63: "+/8=" is 111110 111111 111100 -> FB FF.
    var buf = _b64_decode_into_buffer("+/8=")
    assert_equal(buf.len(), 2)
    assert_equal(Int(buf.read_u8_at(0)), 0xFB)
    assert_equal(Int(buf.read_u8_at(1)), 0xFF)
    # The encoder above and the decoder agree on bytes that use both digits.
    var raw: List[UInt8] = [UInt8(0xFB), UInt8(0xEF), UInt8(0xBE), UInt8(0xFF), UInt8(0xFF)]
    var again = _b64_decode_into_buffer(_b64(raw))
    assert_equal(again.len(), 5)
    for i in range(5):
        assert_equal(Int(again.read_u8_at(i)), Int(raw[i]))


def test_a_record_batch_message_is_not_a_schema_hint() raises:
    var cols = Slab[Column[HeapRegion]]()
    var ints = List[Int32]()
    ints.append(Int32(1))
    ints.append(Int32(2))
    cols.append(Column.from_primitive[DType.int32](PrimitiveArray[DType.int32].from_list(ints)))
    var frame = encode_record_batch_message(cols^)
    var view = frame.view_range_ro(0, frame.len()).into_span()
    var bytes = List[UInt8]()
    for i in range(len(view)):
        bytes.append(view[i])
    assert_true(parse_arrow_schema_value(_b64(bytes)).is_empty())


def test_a_dictionary_of_utf8_values_is_a_dictionary_in_either_width() raises:
    assert_true(_ipc_type_tag_to_arrow_type(TYPE_UTF8, True).value() == ArrowType.DICTIONARY)
    assert_true(_ipc_type_tag_to_arrow_type(TYPE_LARGE_UTF8, True).value() == ArrowType.DICTIONARY)
    assert_true(_ipc_type_tag_to_arrow_type(TYPE_UTF8, False).value() == ArrowType.STRING)
    assert_true(_ipc_type_tag_to_arrow_type(TYPE_LARGE_UTF8, False).value() == ArrowType.LARGE_STRING)


def test_a_dictionary_of_binary_values_is_not_refined() raises:
    assert_false(Bool(_ipc_type_tag_to_arrow_type(TYPE_BINARY, True)))
    assert_false(Bool(_ipc_type_tag_to_arrow_type(TYPE_LARGE_BINARY, True)))
    assert_true(_ipc_type_tag_to_arrow_type(TYPE_BINARY, False).value() == ArrowType.BINARY)
    assert_true(_ipc_type_tag_to_arrow_type(TYPE_LARGE_BINARY, False).value() == ArrowType.LARGE_BINARY)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
