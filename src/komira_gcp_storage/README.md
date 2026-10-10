# komira_gcp_storage

A Cloud Storage client over gRPC, generated at build time from googleapis's
`google/storage/v2/storage.proto`. `StorageClient[C, T]` calls komira_grpc's
`GrpcClient` over the connector `C`, takes each call's bearer token from a
komira_gcp_core `GcpTokenSource` `T`, sets each method's
`x-goog-request-params` routing header from its `google.api.routing`
annotation, and raises a non-OK gRPC status through komira_gcp_core as its
`google.rpc.Code`, never the server's text. It reads no environment and holds
no credential.

The methods are what an object store and a bucket provisioner call:

- objects: `get_object`, `list_objects`, `delete_object`,
  `start_resumable_write`, `read_object` (server streaming) and
  `write_object` (client streaming; it has no routing annotation, so its
  caller sets the routing header on the call's options);
- buckets: `create_bucket`, `get_bucket`, `delete_bucket`, and the bucket
  IAM read-modify-write, `get_iam_policy` and `set_iam_policy`.

No other Storage method is generated.
komira_objectstore_gcs builds a production object store on this client.

## Examples

The request messages are generated types with a protobuf encoder and
decoder (komira_proto_codec's `PbEncoder` and `PbDecoder`). These examples
build the requests an object store sends and read them back; they do not
call the service.

A range read: the bucket's resource name, the object, and the range
`[read_offset, read_offset + read_limit)`:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from komira_proto_codec.proto_binary import PbDecoder, PbEncoder
from komira_gcp_storage.storage import ReadObjectRequest

var read = ReadObjectRequest(
    bucket=String("projects/_/buckets/demo-bucket"),
    object=String("logs/part-0001"),
    generation=Int64(0),
    read_offset=Int64(100),
    read_limit=Int64(256),
    if_generation_match=None,
    if_generation_not_match=None,
    if_metageneration_match=None,
    if_metageneration_not_match=None,
    common_object_request_params=None,
    read_mask=None,
)
var encoder = PbEncoder()
read.encode(encoder)
var decoder = PbDecoder(encoder.into_buf())
var back = ReadObjectRequest.decode(decoder)
assert_equal(back.bucket, "projects/_/buckets/demo-bucket")
assert_equal(back.object, "logs/part-0001")
assert_equal(back.read_offset, Int64(100))
assert_equal(back.read_limit, Int64(256))
assert_false(Bool(back.if_generation_match))
```

A create-if-absent write: the first (and here only) message of a
`write_object` stream carries the object's spec with `if_generation_match`
set to 0, so the write succeeds only if no live object has that name. The
field has explicit presence: a 0 is on the wire and reads back as set,
unlike a write with no precondition. Each oneof of the message is chosen by
its case number (`_oneof0_case = 2` selects `write_object_spec` over
`upload_id`; `_oneof1_case = 1` selects `checksummed_data`):

<!-- mojo-hidden
from std.testing import assert_equal, assert_false, assert_true
from komira_proto_codec.proto_binary import PbDecoder, PbEncoder
-->
```mojo
from komira_gcp_storage.storage import ChecksummedData, WriteObjectRequest, WriteObjectSpec

var payload: List[UInt8] = [0x01, 0x02, 0x03]
var write = WriteObjectRequest(
    write_offset=Int64(0),
    object_checksums=None,
    finish_write=True,
    common_object_request_params=None,
    _oneof0_case=2,
    upload_id=None,
    write_object_spec=Optional[WriteObjectSpec](
        WriteObjectSpec(
            resource=None,
            predefined_acl=String(""),
            if_generation_match=Optional[Int64](Int64(0)),
            if_generation_not_match=None,
            if_metageneration_match=None,
            if_metageneration_not_match=None,
            object_size=None,
            appendable=None,
        )
    ),
    _oneof1_case=1,
    checksummed_data=Optional[ChecksummedData](
        ChecksummedData(content=payload^, crc32c=None)
    ),
)
var write_encoder = PbEncoder()
write.encode(write_encoder)
var write_decoder = PbDecoder(write_encoder.into_buf())
var sent = WriteObjectRequest.decode(write_decoder)
assert_true(sent.finish_write)
assert_false(Bool(sent.upload_id))
ref spec = sent.write_object_spec.value()
assert_true(Bool(spec.if_generation_match))  # 0 is set, not absent
assert_equal(spec.if_generation_match.value(), Int64(0))
assert_equal(len(sent.checksummed_data.value().content), 3)
```
