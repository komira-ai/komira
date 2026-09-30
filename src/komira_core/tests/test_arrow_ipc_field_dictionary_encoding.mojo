# =============================================================================
# test_arrow_ipc_field_dictionary_encoding.mojo
# =============================================================================
#
# Flatbuf-layer tests for `Field.dictionary` (Schema.fbs slot 4 of the Field
# table).
#
# Validates that:
#   1. A Field written with a DictionaryEncoding (id + indexType + isOrdered)
#      round-trips byte-faithfully through `write_field` -> read_schema.
#   2. A Field written without DictionaryEncoding (default -1 dictionary_pos)
#      decodes with `dictionary_encoding = None` on the FieldDescriptor.
#
# This covers ONLY the flatbuf layer (descriptor + writer + reader wire-up);
# encoder/decoder dispatch is exercised elsewhere.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.arrow.ipc_flatbuf import (
    FlatbufWriter,
    flatbuf_reader_over,
    write_type_int,
    write_dictionary_encoding,
    write_field,
    write_schema,
    read_schema,
    TYPE_INT,
    TYPE_UTF8,
    write_type_utf8,
    ENDIANNESS_LITTLE,
)


def test_write_then_read_field_with_dictionary_encoding() raises:
    """Field with DictionaryEncoding round-trips byte-faithfully.

    Wire shape mirrors the v1 lossy-expand-to-STRING contract: the Field
    Type union is STRING (TYPE_UTF8) and Field.dictionary carries
    id=7, indexType=INT32 signed, isOrdered=false.
    """
    var w = FlatbufWriter(1024)
    # Inner Type (STRING) — v1 lossy-expand contract.
    var type_pos = write_type_utf8(w)
    # DictionaryEncoding table (id=7, indexType=Int32 signed, not ordered).
    var dict_enc_pos = write_dictionary_encoding(
        w,
        Int64(7),
        32,
        True,
        False,
    )
    # Field referencing both: name="dict_col", nullable, STRING, dict slot 4.
    var field_pos = write_field(
        w,
        "dict_col",
        True,
        TYPE_UTF8,
        type_pos,
        dictionary_pos=dict_enc_pos,
    )
    var fields = List[Int]()
    fields.append(field_pos)
    var schema_pos = write_schema(w, ENDIANNESS_LITTLE, fields)
    var buf = w^.finalize(schema_pos)

    var reader = flatbuf_reader_over(buf)
    var sd = read_schema(reader, reader.read_root_offset())
    assert_equal(len(sd.fields), 1)
    ref f0 = sd.fields[0]
    assert_equal(String(f0.name), String("dict_col"))
    assert_true(f0.nullable)
    assert_equal(f0.type_tag, TYPE_UTF8)
    assert_true(Bool(f0.dictionary_encoding))
    ref de = f0.dictionary_encoding.value()
    assert_equal(Int(de.id), 7)
    assert_equal(de.index_type_bit_width, 32)
    assert_true(de.index_type_is_signed)
    assert_false(de.is_ordered)


def test_write_then_read_field_without_dictionary_encoding() raises:
    """Field without DictionaryEncoding has None on read-back.

    Back-compat path: `write_field` callers that don't pass
    `dictionary_pos` (or pass -1) should produce a Field with no
    Field.dictionary slot; `read_field` returns None for the descriptor's
    `dictionary_encoding` field.
    """
    var w = FlatbufWriter(1024)
    var type_pos = write_type_int(w, 64, True)
    var field_pos = write_field(w, "plain", False, TYPE_INT, type_pos)
    var fields = List[Int]()
    fields.append(field_pos)
    var schema_pos = write_schema(w, ENDIANNESS_LITTLE, fields)
    var buf = w^.finalize(schema_pos)

    var reader = flatbuf_reader_over(buf)
    var sd = read_schema(reader, reader.read_root_offset())
    assert_equal(len(sd.fields), 1)
    ref f0 = sd.fields[0]
    assert_equal(String(f0.name), String("plain"))
    assert_false(f0.nullable)
    assert_equal(f0.type_tag, TYPE_INT)
    assert_false(Bool(f0.dictionary_encoding))


def main() raises:
    var suite = TestSuite()
    suite.test[test_write_then_read_field_with_dictionary_encoding]()
    suite.test[test_write_then_read_field_without_dictionary_encoding]()
    suite^.run()
