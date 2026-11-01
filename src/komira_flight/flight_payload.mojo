# =============================================================================
# flight_payload.mojo: the Arrow IPC <-> FlightData bridge.
# =============================================================================
#
# The payload codec that converts between a RecordBatch and the Flight
# DoGet/DoPut FlightData stream convention.
#
# THE DoGet SCHEMA-FIRST CONVENTION (Arrow Flight):
#   The DoGet response stream is:
#     FlightData[0] = SCHEMA   (data_header = IPC SCHEMA message metadata, body empty)
#     FlightData[1..N]         = one per RecordBatch
#                               (data_header = IPC RecordBatch message METADATA,
#                                data_body   = IPC RecordBatch message BODY bytes)
#   A Flight client reconstitutes each Arrow IPC message from
#   (data_header ++ data_body). The metadata/body split comes from
#   `arrow_ipc_message_metadata_length(frame)` (= 8 + the aligned flatbuffer
#   length), the byte where the IPC RecordBatch message's flatbuffer metadata
#   ends and its body begins. data_header holds the bare flatbuffer, without
#   the 8-byte continuation-marker + length prefix.
#
# DoPut is the inverse: the client sends the same schema-first stream; each
# batch FlightData is reassembled into a complete single-batch Arrow IPC stream
# (schema frame ++ (data_header ++ data_body) ++ EOS) and decoded with
# `decode_arrow_ipc_stream` (the broker's own decode entry point).
#
# This is the only file in the package that touches the Arrow IPC
# encoder/decoder. messages.mojo and flight_ticket.mojo stay free of it.
#
# Typed values only: RecordBatch / List[UInt8]. SharedAlignedBuffer frames are
# copied to owned List[UInt8] through `read_u8_at`.
# =============================================================================

from komira_arrow_ipc.ipc_encoder_dispatch import (
    arrow_ipc_eos_bytes,
    arrow_ipc_message_metadata_length,
    encode_record_batch_message,
    encode_schema_message,
)
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema
from komira_buffer.heap_region import HeapRegion

from komira_op_sources.arrow_stream_reader import decode_arrow_ipc_stream

from .messages import FlightData


# =============================================================================
# Buffer -> List[UInt8] helpers (no UnsafePointer escapes).
# =============================================================================


@always_inline
def _buf_to_list(buf: SharedAlignedBuffer[HeapRegion]) -> List[UInt8]:
    """Copy a complete encoded Arrow IPC frame to an owned List[UInt8]."""
    var out = List[UInt8]()
    var n = buf.len()
    for i in range(n):
        out.append(buf.read_u8_at(i))
    return out^


@always_inline
def _buf_range_to_list(
    buf: SharedAlignedBuffer[HeapRegion], start: Int, end: Int
) -> List[UInt8]:
    """Copy `buf[start:end)` to an owned List[UInt8]."""
    var out = List[UInt8]()
    for i in range(start, end):
        out.append(buf.read_u8_at(i))
    return out^


# =============================================================================
# DoGet — RecordBatch(es) -> schema-first FlightData stream.
# =============================================================================


comptime _ENCAP_PREFIX_LEN: Int = 8
"""The v0.15+ encapsulation prefix: 4-byte 0xFFFFFFFF + 4-byte u32 metadata len.
pyarrow's FlightData.data_header carries the BARE flatbuffer metadata (no
prefix), so DoGet strips this prefix and DoPut re-adds it."""


def encode_schema_flight_data(schema: Schema) raises -> List[UInt8]:
    """Encode the DoGet stream's FIRST FlightData: the IPC schema message
    metadata in `data_header` (BARE flatbuffer, prefix stripped — pyarrow's
    wire shape), empty body. Returns the serialized FlightData protobuf bytes."""
    var schema_frame = encode_schema_message(schema)
    var meta_len = Int(arrow_ipc_message_metadata_length(schema_frame))
    # data_header = the flatbuffer metadata WITHOUT the 8-byte encapsulation
    # prefix (pyarrow's data_header convention).
    var header = _buf_range_to_list(
        schema_frame, _ENCAP_PREFIX_LEN, meta_len
    )
    _ = schema_frame^
    var fd = FlightData.schema_message(header^)
    return fd.encode()


def encode_batch_flight_data(var batch: RecordBatch) raises -> List[UInt8]:
    """Encode one RecordBatch as a DoGet FlightData: IPC message metadata in
    `data_header` (BARE flatbuffer, prefix stripped — pyarrow's wire shape), IPC
    body bytes in `data_body`. Returns the serialized FlightData protobuf bytes.

    The columns are encoded as one IPC RecordBatch message frame, split at
    `arrow_ipc_message_metadata_length` into [prefix | flatbuffer | body]; the
    8-byte encapsulation prefix is dropped from `data_header` (pyarrow re-frames
    the message from data_header ++ data_body itself)."""
    var cols = batch.take_columns()
    var frame = encode_record_batch_message(cols^)
    var meta_len = Int(arrow_ipc_message_metadata_length(frame))
    var total = frame.len()
    var header = _buf_range_to_list(frame, _ENCAP_PREFIX_LEN, meta_len)
    var body = _buf_range_to_list(frame, meta_len, total)
    _ = frame^
    _ = batch^
    var fd = FlightData.batch_message(header^, body^)
    return fd.encode()


# =============================================================================
# DoPut — FlightData batch message -> RecordBatch (schema established first).
# =============================================================================


@always_inline
def _append_encapsulated_message(
    mut stream: List[UInt8], metadata: List[UInt8], body: List[UInt8]
):
    """Append one Arrow IPC v0.15+ ENCAPSULATED message to `stream`:
        [u32 0xFFFFFFFF continuation marker]
        [u32 metadata_len (little-endian)]
        [metadata flatbuffer bytes (already 8-byte padded)]
        [body bytes]
    pyarrow Flight strips the 8-byte continuation+length prefix from the
    `data_header` field (it carries only the bare flatbuffer Message metadata,
    already 8-padded — verified on the wire: schema/batch headers start with the
    flatbuffer root offset, NOT 0xFF). So we RE-ADD the encapsulation prefix
    here to reconstruct a frame `decode_arrow_ipc_stream` can read.

    `_metadata_is_already_framed` detects a metadata that ALREADY carries the
    0xFFFFFFFF prefix (the DoGet-produced split, where we kept the prefix in
    data_header) and passes it through unchanged — so the bridge round-trips both
    our own DoGet output AND pyarrow's prefix-stripped data_header."""
    var mlen = len(metadata)
    if (
        mlen >= 8
        and metadata[0] == UInt8(0xFF)
        and metadata[1] == UInt8(0xFF)
        and metadata[2] == UInt8(0xFF)
        and metadata[3] == UInt8(0xFF)
    ):
        # Already an encapsulated frame (our own DoGet split kept the prefix).
        for i in range(mlen):
            stream.append(metadata[i])
        for i in range(len(body)):
            stream.append(body[i])
        return
    # Bare flatbuffer metadata (pyarrow's data_header) — add the prefix.
    stream.append(UInt8(0xFF))
    stream.append(UInt8(0xFF))
    stream.append(UInt8(0xFF))
    stream.append(UInt8(0xFF))
    stream.append(UInt8(mlen & 0xFF))
    stream.append(UInt8((mlen >> 8) & 0xFF))
    stream.append(UInt8((mlen >> 16) & 0xFF))
    stream.append(UInt8((mlen >> 24) & 0xFF))
    for i in range(mlen):
        stream.append(metadata[i])
    for i in range(len(body)):
        stream.append(body[i])


def flight_data_to_record_batch(
    schema_header: List[UInt8],
    data_header: List[UInt8],
    data_body: List[UInt8],
) raises -> RecordBatch:
    """Reassemble a single-batch Arrow IPC stream from the schema message
    (`schema_header`, the IPC SCHEMA message metadata from the DoPut stream's
    first FlightData) + this batch's IPC message header (`data_header`) + body
    (`data_body`), then decode it to a RecordBatch.

    Stream layout assembled: [schema frame] [rb message frame] [EOS marker],
    where each frame is the v0.15+ ENCAPSULATED form (0xFFFFFFFF + len + metadata
    + body). pyarrow strips that prefix from `data_header`, so
    `_append_encapsulated_message` re-adds it (and passes through frames that
    already carry it, so our own DoGet output round-trips too)."""
    var stream = List[UInt8]()
    _append_encapsulated_message(stream, schema_header, List[UInt8]())
    _append_encapsulated_message(stream, data_header, data_body)
    var eos = arrow_ipc_eos_bytes()
    var eos_list = _buf_to_list(eos)
    _ = eos^
    for i in range(len(eos_list)):
        stream.append(eos_list[i])
    return decode_arrow_ipc_stream(stream^)
