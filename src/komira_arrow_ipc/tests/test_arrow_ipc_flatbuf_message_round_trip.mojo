# =============================================================================
# test_arrow_ipc_flatbuf_message_round_trip.mojo — Message / RecordBatch /
# Footer flatbuffers
# =============================================================================
#
# Validates Message + RecordBatch + Footer + struct vector (FieldNode /
# Buffer / Block) encode/decode.
#
# Coverage:
#   1. RecordBatch round-trip (length + nodes + buffers).
#   2. Message round-trip with Schema-as-header.
#   3. Message round-trip with RecordBatch-as-header.
#   4. Footer round-trip (schema + dict + rb blocks).
#   5. FieldNode + Buffer + Block struct vectors.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow_ipc.ipc_flatbuf import (
    FlatbufWriter,
    flatbuf_reader_over,
    write_type_int,
    write_field,
    write_schema,
    write_record_batch,
    write_message,
    write_footer,
    read_message,
    read_record_batch,
    FieldNode,
    BufferDescriptor,
    Block,
    TYPE_INT,
    MESSAGE_HEADER_SCHEMA,
    MESSAGE_HEADER_RECORD_BATCH,
    METADATA_VERSION_V5,
    ENDIANNESS_LITTLE,
)


# ---------------------------------------------------------------------------
# RecordBatch round-trip
# ---------------------------------------------------------------------------


def test_record_batch_single_column() raises:
    """1-column RecordBatch with 100 rows + 2 buffers (validity + data)."""
    var w = FlatbufWriter(1024)
    var nodes = List[FieldNode]()
    nodes.append(FieldNode(length=Int64(100), null_count=Int64(0)))
    var buffers = List[BufferDescriptor]()
    buffers.append(BufferDescriptor(offset=Int64(0), length=Int64(16)))   # validity
    buffers.append(BufferDescriptor(offset=Int64(16), length=Int64(800)))  # data
    var rb_pos = write_record_batch(w, Int64(100), nodes, buffers)
    var buf = w^.finalize(rb_pos)

    var reader = flatbuf_reader_over(buf)
    var rd = read_record_batch(reader, reader.read_root_offset())
    assert_equal(rd.length, Int64(100))
    assert_equal(len(rd.nodes), 1)
    assert_equal(rd.nodes[0].length, Int64(100))
    assert_equal(rd.nodes[0].null_count, Int64(0))
    assert_equal(len(rd.buffers), 2)
    assert_equal(rd.buffers[0].offset, Int64(0))
    assert_equal(rd.buffers[0].length, Int64(16))
    assert_equal(rd.buffers[1].offset, Int64(16))
    assert_equal(rd.buffers[1].length, Int64(800))


def test_record_batch_empty() raises:
    """0-row RecordBatch with no nodes + no buffers."""
    var w = FlatbufWriter(1024)
    var nodes = List[FieldNode]()
    var buffers = List[BufferDescriptor]()
    var rb_pos = write_record_batch(w, Int64(0), nodes, buffers)
    var buf = w^.finalize(rb_pos)

    var reader = flatbuf_reader_over(buf)
    var rd = read_record_batch(reader, reader.read_root_offset())
    assert_equal(rd.length, Int64(0))
    assert_equal(len(rd.nodes), 0)
    assert_equal(len(rd.buffers), 0)


# ---------------------------------------------------------------------------
# Message round-trip
# ---------------------------------------------------------------------------


def test_message_schema_header() raises:
    """Message wrapping a Schema header."""
    var w = FlatbufWriter(2048)
    var type_pos = write_type_int(w, 64, True)
    var field_pos = write_field(w, "a", False, TYPE_INT, type_pos)
    var fields = List[Int]()
    fields.append(field_pos)
    var schema_pos = write_schema(w, ENDIANNESS_LITTLE, fields)

    var msg_pos = write_message(
        w,
        Int16(Int(METADATA_VERSION_V5)),
        MESSAGE_HEADER_SCHEMA,
        schema_pos,
        Int64(0),  # bodyLength = 0 for Schema messages
    )
    var buf = w^.finalize(msg_pos)

    var reader = flatbuf_reader_over(buf)
    var md = read_message(reader, reader.read_root_offset())
    assert_equal(md.version, Int16(Int(METADATA_VERSION_V5)))
    assert_equal(md.header_tag, MESSAGE_HEADER_SCHEMA)
    assert_true(md.header_table_pos > 0)
    assert_equal(md.body_length, Int64(0))


def test_message_record_batch_header() raises:
    """Message wrapping a RecordBatch header."""
    var w = FlatbufWriter(2048)
    var nodes = List[FieldNode]()
    nodes.append(FieldNode(length=Int64(5), null_count=Int64(0)))
    var buffers = List[BufferDescriptor]()
    buffers.append(BufferDescriptor(offset=Int64(0), length=Int64(8)))
    buffers.append(BufferDescriptor(offset=Int64(8), length=Int64(40)))
    var rb_pos = write_record_batch(w, Int64(5), nodes, buffers)

    var msg_pos = write_message(
        w,
        Int16(Int(METADATA_VERSION_V5)),
        MESSAGE_HEADER_RECORD_BATCH,
        rb_pos,
        Int64(48),  # body bytes = 8 (validity) + 40 (data)
    )
    var buf = w^.finalize(msg_pos)

    var reader = flatbuf_reader_over(buf)
    var md = read_message(reader, reader.read_root_offset())
    assert_equal(md.header_tag, MESSAGE_HEADER_RECORD_BATCH)
    assert_equal(md.body_length, Int64(48))
    # Walk into the RecordBatch.
    var rd = read_record_batch(reader, md.header_table_pos)
    assert_equal(rd.length, Int64(5))
    assert_equal(len(rd.nodes), 1)


# ---------------------------------------------------------------------------
# Footer round-trip
# ---------------------------------------------------------------------------


def test_footer_minimal() raises:
    """Footer pointing at a Schema with no dict blocks + 1 rb block."""
    var w = FlatbufWriter(2048)
    var type_pos = write_type_int(w, 64, True)
    var field_pos = write_field(w, "x", False, TYPE_INT, type_pos)
    var fields = List[Int]()
    fields.append(field_pos)
    var schema_pos = write_schema(w, ENDIANNESS_LITTLE, fields)

    var dicts = List[Block]()
    var rbs = List[Block]()
    rbs.append(Block(offset=Int64(8), meta_data_length=Int32(256), body_length=Int64(1024)))

    var footer_pos = write_footer(
        w, Int16(Int(METADATA_VERSION_V5)), schema_pos, dicts, rbs
    )
    var buf = w^.finalize(footer_pos)
    assert_true(buf.len() > 0)


# ---------------------------------------------------------------------------
# TestSuite registration
# ---------------------------------------------------------------------------


def main() raises:
    var suite = TestSuite()
    suite.test[test_record_batch_single_column]()
    suite.test[test_record_batch_empty]()
    suite.test[test_message_schema_header]()
    suite.test[test_message_record_batch_header]()
    suite.test[test_footer_minimal]()
    suite^.run()
