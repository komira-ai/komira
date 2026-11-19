"""A mid-size closure re-exported through one @export file: the core packages
(Arrow batch builder, snappy C lib), json, encoding,
crypto (aws-lc), protobuf and gcp_core."""

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.schema import Field, SchemaBuilder
from arrow.string_array import StringArray
from arrow.schema import RecordBatchBuilder
from byte_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from crypto.sha256 import sha256
from encoding import base64_encode
from gcp_core.status import code_from_http_status
from json.parse import parse_json_value
from protobuf.reader import pb_read_varint
from protobuf.writer import pb_write_varint


@export
def mid_json_serialized_len() abi("C") -> Int32:
    try:
        var v = parse_json_value('{"a":[1,2,3],"b":"hello","c":null}')
        return Int32(v.serialize().byte_length())
    except:
        return -1


@export
def mid_base64_len(n: Int32) abi("C") -> Int32:
    var data = List[UInt8]()
    for i in range(Int(n)):
        data.append(UInt8(i & 255))
    return Int32(base64_encode(Span(data)).byte_length())


@export
def mid_sha256_first_byte(n: Int32) abi("C") -> Int32:
    var data = List[UInt8]()
    for i in range(Int(n)):
        data.append(UInt8(i & 255))
    var d = sha256(Span(data))
    return Int32(Int(d[0]))


@export
def mid_pb_roundtrip(v: UInt64) abi("C") -> UInt64:
    var buf = List[UInt8]()
    pb_write_varint(buf, v)
    try:
        return pb_read_varint(Span(buf), 0).value
    except:
        return 0


@export
def mid_gcp_code_from_http(status: Int32) abi("C") -> Int32:
    return Int32(code_from_http_status(Int(status)))


def _three_strings() -> StringArray[]:
    var offsets_buf = OwnedAlignedBuffer(4 * 4)
    var o = offsets_buf.view_typed_mut[DType.int32]()
    o[0] = 0
    o[1] = 5
    o[2] = 10
    o[3] = 14
    offsets_buf.set_length(4 * 4)
    var data_buf = OwnedAlignedBuffer(14)
    var d = data_buf.view_typed_mut[DType.uint8]()
    for i in range(14):
        d[i] = UInt8(97 + i)
    data_buf.set_length(14)
    return StringArray(
        offsets=offsets_buf^,
        data=data_buf^,
        validity=None,
        length=3,
        data_length=14,
        null_count=0,
    )


@export
def mid_batch_rows() abi("C") -> Int32:
    try:
        var col = Column.from_string(_three_strings())
        var sb = SchemaBuilder()
        sb.add_field(Field("name", ArrowType.STRING, False))
        var schema = sb.build()
        var builder = RecordBatchBuilder()
        builder.add_column(col^)
        var batch = builder.build(schema^)
        ref c = batch.column_at(0)
        return Int32(c.as_string().length)
    except:
        return -1
