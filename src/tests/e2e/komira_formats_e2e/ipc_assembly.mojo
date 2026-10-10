# =============================================================================
# Arrow IPC File and Stream bytes, assembled from komira's message encoders.
# =============================================================================
#
# komira_arrow_ipc ships the per-message encoders and the framing pieces, not a
# file or stream writer: `encode_schema_message`, `encode_record_batch_message`,
# `arrow_ipc_eos_bytes`, `arrow_ipc_file_magic_header` and
# `encode_footer_message` (Footer flatbuffer + int32 length + "ARROW1"). This
# fixture strings them together in the order the Arrow columnar spec gives
# (format/Columnar.rst, "IPC Streaming Format" and "IPC File Format"):
#
#   stream:  <SCHEMA> <RECORD BATCH>* <EOS 0xFFFFFFFF 0x00000000>
#   file:    "ARROW1" <2 pad bytes> <the stream, EOS included> <FOOTER>
#            <FOOTER SIZE: int32 LE> "ARROW1"
#
# and records one footer Block per RecordBatch: `offset` = bytes written so
# far, `metaDataLength` = the 8-byte prefix plus the padded flatbuffer
# (`arrow_ipc_message_metadata_length`), `bodyLength` = the rest of the frame.
# The bytes reach disk through `write_file_bytes` (the real LocalFs). Nothing
# here reads; the tests do that, through komira's decoders and against the
# spec.
# =============================================================================

from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema
from komira_arrow_ipc.ipc_encoder_dispatch import (
    arrow_ipc_eos_bytes,
    arrow_ipc_file_magic_header,
    arrow_ipc_message_metadata_length,
    encode_footer_message,
    encode_record_batch_message,
    encode_schema_message,
)
from komira_arrow_ipc.ipc_flatbuf import Block
from komira_buffer.heap_region import HeapRegion
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer

from .hive_tree import write_file_bytes


def _append(mut out: List[UInt8], b: SharedAlignedBuffer[HeapRegion]):
    for i in range(b.len()):
        out.append(b.read_u8_at(i))


struct IpcAssembly(Movable):
    """One Arrow IPC File (`is_file`) or Stream under construction: the
    schema message is written on creation, `add` appends one RecordBatch
    message, `finish` appends the EOS marker (and, for a File, the footer)
    and refuses a second call."""

    var schema: Schema
    var is_file: Bool
    var bytes: List[UInt8]
    var blocks: List[Block]
    var finished: Bool

    def __init__(out self, var schema: Schema, is_file: Bool) raises:
        self.bytes = List[UInt8]()
        if is_file:
            _append(self.bytes, arrow_ipc_file_magic_header())
        _append(self.bytes, encode_schema_message(schema))
        self.schema = schema^
        self.is_file = is_file
        self.blocks = List[Block]()
        self.finished = False

    def add(mut self, var batch: RecordBatch) raises:
        var frame = encode_record_batch_message(batch.take_columns())
        var meta = Int(arrow_ipc_message_metadata_length(frame))
        self.blocks.append(
            Block(
                offset=Int64(len(self.bytes)),
                meta_data_length=Int32(meta),
                body_length=Int64(frame.len() - meta),
            )
        )
        _append(self.bytes, frame)

    def finish(mut self) raises -> List[UInt8]:
        if self.finished:
            raise Error("IpcAssembly.finish: already finished (EOS and footer are written once)")
        self.finished = True
        _append(self.bytes, arrow_ipc_eos_bytes())
        if self.is_file:
            _append(
                self.bytes,
                encode_footer_message(self.schema, List[Block](), self.blocks.copy()),
            )
        return self.bytes.copy()


def write_ipc(path: String, mut assembly: IpcAssembly) raises:
    """Finish `assembly` and write its bytes to `path` through LocalFs."""
    write_file_bytes(path, assembly.finish())
