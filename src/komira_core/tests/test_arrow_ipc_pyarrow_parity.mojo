# =============================================================================
# test_arrow_ipc_pyarrow_parity.mojo
# pyarrow-fixture-decoding tests
# =============================================================================
#
# Validates that the FlatbufReader correctly decodes Arrow IPC bytes
# produced by pyarrow (the reference producer). This is the byte-identity
# direction that proves the wire layout is canonical: pyarrow emits the
# canonical Flatbuffers layout (i64 inline slots, inline 16-byte Buffer
# structs, vtable-indexed fields with declared widths) and our reader walks
# it without misparsing.
#
# The fixtures are pyarrow-written files declared as this test's data; the
# test runs with its data directory as the current directory, so each is
# opened by the path it is declared at.
#
# Coverage:
#   1. schema_only.arrow — Schema message with 23 primitive Type arms
#   2. schema_record_batch.arrow — Schema + RecordBatch (100 rows, 3 cols)
#   3. arrow_file.arrow — Full Arrow File (magic + IPC stream + Footer)
#   4. tensor_1d_int64.tensor — Tensor message; walks Tensor.data via the
#      inline 16-byte Buffer struct accessor `_read_table_field_buffer_inline`.
#
# No SparseTensor fixture: the pyarrow Python binding does NOT expose a
# writer for SparseTensor IPC bytes (pa.ipc.write_tensor rejects
# SparseCOOTensor). The inline-Buffer encoding for SparseTensor is covered
# internally by test_arrow_ipc_flatbuf_wire_canonical.mojo.
# =============================================================================

from std.io import FileHandle
from std.testing import TestSuite, assert_equal, assert_true


from komira_core.arrow.shared_aligned_buffer import SharedAlignedBuffer
from komira_core.io.heap_region import HeapRegion
from komira_core.arrow.ipc_flatbuf import (
    FlatbufReader,
    flatbuf_reader_over,
    parse_ipc_message,
    read_message,
    read_schema,
    read_record_batch,
    read_tensor,
    MESSAGE_HEADER_SCHEMA,
    MESSAGE_HEADER_RECORD_BATCH,
    MESSAGE_HEADER_TENSOR,
    TYPE_INT,
    TYPE_FLOATING_POINT,
    TYPE_UTF8,
)


# ---------------------------------------------------------------------------
# Test helpers
# ---------------------------------------------------------------------------


def _load_fixture(path: String) raises -> SharedAlignedBuffer[HeapRegion]:
    """Load a fixture file into an 8-byte-aligned buffer.

    Reads the full file into memory; suitable for the small (~1-3 KB)
    Arrow IPC test fixtures.
    """
    var f = FileHandle(path, "r")
    _ = f.seek(0, 2)  # SEEK_END
    var file_size = Int(f.seek(0, 1))  # SEEK_CUR == tell
    _ = f.seek(0, 0)  # rewind
    var raw = f.read_bytes(file_size)
    f.close()

    var out = SharedAlignedBuffer[HeapRegion].heap_owned(file_size)
    for i in range(file_size):
        out.write_u8_at(i, raw[i])
    out.set_length(file_size)

    return out^


def _extract_first_fb_payload(
    var frame_buf: SharedAlignedBuffer[HeapRegion],
) raises -> SharedAlignedBuffer[HeapRegion]:
    """Parse the IPC framing on the first message in `frame_buf` and
    extract the FB payload bytes into a fresh MmapAlignedBuffer.

    Returns a buffer whose byte 0 is the FB payload's first byte (i.e.
    the FB root_offset's anchor), so flatbuf_reader_over can be used
    directly.
    """
    var frame = parse_ipc_message(frame_buf)
    var size = frame.metadata_size
    var payload = SharedAlignedBuffer[HeapRegion].heap_owned(size)
    # Copy frame_buf[metadata_pos .. metadata_pos+size) → payload[0..size).
    for i in range(size):
        payload.write_u8_at(i, frame_buf.read_u8_at(frame.metadata_pos + i))
    payload.set_length(size)

    return payload^


# ---------------------------------------------------------------------------
# Fixture 1 — schema_only.arrow
# ---------------------------------------------------------------------------


def test_pyarrow_schema_only_decodes_correctly() raises:
    """Schema-only IPC stream with 23 primitive Type arms.

    Validates that our FlatbufReader correctly walks pyarrow's emitted
    Schema message: the Message wrapper's header_tag must be SCHEMA (1),
    the Schema's field count must match, and each field's type_tag must
    decode to the expected variant.
    """
    var frame_buf = _load_fixture(
        "src/komira_core/tests/fixtures/arrow_ipc/schema_only.arrow"
    )
    var payload = _extract_first_fb_payload(frame_buf^)
    var reader = flatbuf_reader_over(payload)
    var msg = read_message(reader, reader.read_root_offset())
    assert_equal(msg.header_tag, MESSAGE_HEADER_SCHEMA)
    assert_equal(msg.body_length, Int64(0))

    var schema = read_schema(reader, msg.header_table_pos)
    # gen_fixtures.py:gen_schema_only emits 23 fields:
    # null, bool, int8/16/32/64, uint8/16/32/64, float16/32/64,
    # decimal128, date32/64, time32_ms, time64_us, timestamp_ns,
    # duration_s, utf8, binary, fixed_size_binary.
    assert_equal(len(schema.fields), 23)

    # Spot-check a few fields by name + type_tag. FieldDescriptor isn't
    # ImplicitlyCopyable; use ref-bind to avoid implicit-copy errors.
    ref f0 = schema.fields[0]
    assert_equal(String(f0.name), String("f_null"))
    # f_int8/16/32/64 + f_uint8/16/32/64 all have TYPE_INT tag.
    ref f_int64 = schema.fields[5]
    assert_equal(String(f_int64.name), String("f_int64"))
    assert_equal(f_int64.type_tag, TYPE_INT)
    ref f_uint8 = schema.fields[6]
    assert_equal(String(f_uint8.name), String("f_uint8"))
    assert_equal(f_uint8.type_tag, TYPE_INT)
    # f_float64 has TYPE_FLOATING_POINT.
    ref f_float64 = schema.fields[12]
    assert_equal(String(f_float64.name), String("f_float64"))
    assert_equal(f_float64.type_tag, TYPE_FLOATING_POINT)
    # f_utf8 has TYPE_UTF8.
    ref f_utf8 = schema.fields[20]
    assert_equal(String(f_utf8.name), String("f_utf8"))
    assert_equal(f_utf8.type_tag, TYPE_UTF8)


# ---------------------------------------------------------------------------
# Fixture 2 — schema_record_batch.arrow
# ---------------------------------------------------------------------------


def test_pyarrow_schema_record_batch_first_message_is_schema() raises:
    """First message in schema_record_batch.arrow is the Schema. Validates
    that pyarrow's two-message stream (Schema first, then RecordBatch)
    starts with a Schema as expected.
    """
    var frame_buf = _load_fixture(
        "src/komira_core/tests/fixtures/arrow_ipc/schema_record_batch.arrow"
    )
    var payload = _extract_first_fb_payload(frame_buf^)
    var reader = flatbuf_reader_over(payload)
    var msg = read_message(reader, reader.read_root_offset())
    assert_equal(msg.header_tag, MESSAGE_HEADER_SCHEMA)
    var schema = read_schema(reader, msg.header_table_pos)
    # gen_schema_record_batch emits 3 fields: i (int64), f (float64), s (utf8).
    assert_equal(len(schema.fields), 3)
    assert_equal(String(schema.fields[0].name), String("i"))
    assert_equal(schema.fields[0].type_tag, TYPE_INT)
    assert_equal(String(schema.fields[1].name), String("f"))
    assert_equal(schema.fields[1].type_tag, TYPE_FLOATING_POINT)
    assert_equal(String(schema.fields[2].name), String("s"))
    assert_equal(schema.fields[2].type_tag, TYPE_UTF8)


# ---------------------------------------------------------------------------
# Fixture 3 — arrow_file.arrow (File format)
# ---------------------------------------------------------------------------


def test_pyarrow_arrow_file_has_arrow_magic() raises:
    """Arrow File starts with the ARROW1\\0\\0 magic header (6 bytes
    'ARROW1' + 2 bytes pad) per the Arrow File format spec.

    This is a basic byte-level check on the file format wrapper —
    there is no Mojo-side Arrow File reader (the IPC stream reader is
    sufficient); but the byte-identity check proves the fixture is
    well-formed pyarrow output.
    """
    var frame_buf = _load_fixture(
        "src/komira_core/tests/fixtures/arrow_ipc/arrow_file.arrow"
    )
    # ARROW1 = 0x41 0x52 0x52 0x4F 0x57 0x31
    assert_equal(frame_buf.read_u8_at(0), UInt8(0x41))  # 'A'
    assert_equal(frame_buf.read_u8_at(1), UInt8(0x52))  # 'R'
    assert_equal(frame_buf.read_u8_at(2), UInt8(0x52))  # 'R'
    assert_equal(frame_buf.read_u8_at(3), UInt8(0x4F))  # 'O'
    assert_equal(frame_buf.read_u8_at(4), UInt8(0x57))  # 'W'
    assert_equal(frame_buf.read_u8_at(5), UInt8(0x31))  # '1'
    # Trailer: same magic at end.
    var n = frame_buf.len()
    assert_equal(frame_buf.read_u8_at(n - 6), UInt8(0x41))
    assert_equal(frame_buf.read_u8_at(n - 5), UInt8(0x52))
    assert_equal(frame_buf.read_u8_at(n - 4), UInt8(0x52))
    assert_equal(frame_buf.read_u8_at(n - 3), UInt8(0x4F))
    assert_equal(frame_buf.read_u8_at(n - 2), UInt8(0x57))
    assert_equal(frame_buf.read_u8_at(n - 1), UInt8(0x31))


# ---------------------------------------------------------------------------
# Fixture 4 — tensor_1d_int64.tensor
# ---------------------------------------------------------------------------


def test_pyarrow_tensor_inline_buffer_canonical() raises:
    """Tensor message: Tensor.data is an INLINE 16-byte Buffer struct
    (offset i64 + length i64) at field 4, NOT an offset to a
    separately-emitted Buffer table.

    pyarrow 24's `pa.ipc.write_tensor(pa.Tensor.from_numpy(np.arange(
    1000, dtype=np.int64)))` produces an 8,192-byte stream:
        - 8 bytes IPC framing (0xFFFFFFFF continuation + i32 size 184)
        - 184 bytes Flatbuffers Message metadata (Tensor table)
        - 8,000 bytes body (1000 × int64 = 8,000)

    The data Buffer descriptor has offset=0 (relative to body) and
    length=8000. If `_read_table_field_buffer_inline` read a u32 offset
    instead of an inline 16-byte struct, these values would not
    round-trip — we'd see garbage.

    This is the third-party byte-identity proof for the inline Buffer
    encoding: pyarrow emits an inline 16-byte Buffer; our reader decodes it
    correctly.
    """
    var frame_buf = _load_fixture(
        "src/komira_core/tests/fixtures/arrow_ipc/tensor_1d_int64.tensor"
    )
    # Sanity: file size should be 8,192 (8 framing + 184 metadata + 8,000 body).
    assert_equal(frame_buf.len(), 8192)

    # Body length on the Message wrapper should report 8,000 bytes (the
    # tensor's i64×1000 data) — an i64 inline slot, not a u32-truncated
    # one.
    var payload = _extract_first_fb_payload(frame_buf^)
    var reader = flatbuf_reader_over(payload)
    var msg = read_message(reader, reader.read_root_offset())
    assert_equal(msg.header_tag, MESSAGE_HEADER_TENSOR)
    assert_equal(msg.body_length, Int64(8000))

    # Walk the Tensor table — this internally calls
    # _read_table_field_buffer_inline(reader, table_pos, 4) for Tensor.data.
    var tensor = read_tensor(reader, msg.header_table_pos)

    # The Tensor shape vector must have one TensorDim of size 1000.
    assert_equal(len(tensor.shape), 1)
    assert_equal(tensor.shape[0].size, Int64(1000))

    # Strides: pyarrow emits strides=(8,) for 1D contiguous tensors.
    assert_equal(len(tensor.strides), 1)
    assert_equal(tensor.strides[0], Int64(8))

    # Lock-in: Tensor.data must be the inline
    # 16-byte Buffer struct {offset=0, length=8000}.
    assert_equal(tensor.data.offset, Int64(0))
    assert_equal(tensor.data.length, Int64(8000))


# ---------------------------------------------------------------------------
# SparseTensor — NOT covered (pyarrow API gap)
# ---------------------------------------------------------------------------
# The pyarrow Python binding does NOT expose a writer for SparseTensor IPC
# bytes:
#   pa.ipc.write_tensor(SparseCOOTensor) -> TypeError
#   pickle(SparseCOOTensor) -> TypeError (C++ stp pointer not picklable)
# No Python-level path emits SparseTensor bytes via pyarrow.
#
# The inline-Buffer encoding for SparseTensor is covered by:
#   test_sparse_tensor_non_zero_above_4g_and_inline_data
#   test_sparse_matrix_csx_two_inline_buffers_above_4g
# in test_arrow_ipc_flatbuf_wire_canonical.mojo (Mojo writes both sides —
# internal round-trip rather than third-party byte-identity). A non-pyarrow
# producer (arrow-cpp via FFI, arrow-rs) would close the third-party half.

# ---------------------------------------------------------------------------
# TestSuite registration
# ---------------------------------------------------------------------------


def main() raises:
    var suite = TestSuite()
    suite.test[test_pyarrow_schema_only_decodes_correctly]()
    suite.test[test_pyarrow_schema_record_batch_first_message_is_schema]()
    suite.test[test_pyarrow_arrow_file_has_arrow_magic]()
    suite.test[test_pyarrow_tensor_inline_buffer_canonical]()
    suite^.run()
