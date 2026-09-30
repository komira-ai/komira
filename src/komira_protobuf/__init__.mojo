"""`komira_protobuf` — general-purpose Protocol Buffers wire codec.

The protobuf wire format is general, not tied to any one message set (ORC's
four metadata messages — PostScript / Footer / Metadata / StripeFooter — are
one consumer among several). This package is that general codec:

  - wire_types.mojo : PB_WIRE_* constants + zigzag transforms.
  - reader.mojo     : the wire DECODER — varint / sint / fixed32 / fixed64 /
                      length-delimited / packed-repeated, plus PbFieldCursor,
                      a general tag-driven field-dispatch loop.
  - writer.mojo     : the wire ENCODER — the symmetric flip of every reader
                      primitive.

Dependency direction (cycle-free; leaf of the proto-codegen DAG):
  komira_protobuf -> std only (no komira_* dependency).
  komira_orc      -> komira_protobuf  (the ORC metadata codec consumes it)
  komira_serde    -> komira_protobuf  (the ProtoBinaryWire backend)

This is a SIBLING package under the `komira` namespace root (parent-claims-
namespace-safe — one `-I` root, never split).

Encapsulation: the public API exposes only typed values — small
result structs, scalars, String, List, Span, raised Error. No UnsafePointer
crosses the module boundary; the reader walks Span views with pure index
arithmetic; the writer appends to owned List[UInt8].
"""

from .wire_types import (
    PB_WIRE_VARINT,
    PB_WIRE_FIXED64,
    PB_WIRE_LEN,
    PB_WIRE_FIXED32,
    pb_wire_type_name,
    zigzag_encode,
    zigzag_decode,
    zigzag_encode32,
    zigzag_decode32,
)

from .reader import (
    PbVarint,
    PbTag,
    PbLenField,
    PbScalar32,
    PbScalar64,
    PbFieldCursor,
    pb_read_varint,
    pb_read_tag,
    pb_read_len_field,
    pb_skip_field,
    pb_read_string,
    pb_read_bytes,
    pb_read_sint64,
    pb_read_sint32,
    pb_read_fixed32,
    pb_read_fixed64,
    pb_read_float,
    pb_read_double,
    pb_read_packed_varints,
    pb_read_packed_sint64,
    pb_read_packed_fixed32,
    pb_read_packed_fixed64,
)

from .writer import (
    pb_write_varint,
    pb_write_tag,
    pb_write_varint_field,
    pb_write_bool_field,
    pb_write_len_field,
    pb_write_sint64_field,
    pb_write_sint32_field,
    pb_write_fixed64_field,
    pb_write_fixed32_field,
    pb_write_double_field,
    pb_write_float_field,
    pb_write_string_field,
    pb_write_bytes_field,
    pb_write_message_field,
    pb_write_packed_varints,
    pb_write_packed_sint64,
    pb_write_packed_fixed64,
    pb_write_packed_fixed32,
)
