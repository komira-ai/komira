# =============================================================================
# test_storage_messages.mojo — the generated Cloud Storage request messages.
# =============================================================================
#
# The requests an object store builds for its conditional writes and range
# reads, encoded by the generated types and decoded back (proto round-trip),
# and the create-if-absent write compared byte for byte with the encoding
# written out by hand:
#
#   * WriteObjectRequest: the first message carries a WriteObjectSpec (the
#     `first_message` oneof's second arm), the data chunk (the `data` oneof)
#     and finish_write; a continuation carries the upload id (the first arm);
#   * WriteObjectSpec.if_generation_match: 0 for create-if-absent, a
#     generation for compare-and-swap. The field has explicit presence, so 0
#     is on the wire and decodes as set, unlike an unset match;
#   * ChecksummedData.crc32c is a fixed32;
#   * ReadObjectRequest carries the bucket's resource name, the object name
#     and the range [read_offset, read_offset + read_limit).
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_proto_codec.proto_binary import PbDecoder, PbEncoder

from komira_gcp_storage.storage import (
    ChecksummedData,
    ReadObjectRequest,
    WriteObjectRequest,
    WriteObjectSpec,
)


def _spec(if_generation_match: Optional[Int64]) -> WriteObjectSpec:
    return WriteObjectSpec(
        resource=None,
        predefined_acl=String(""),
        if_generation_match=if_generation_match,
        if_generation_not_match=None,
        if_metageneration_match=None,
        if_metageneration_not_match=None,
        object_size=None,
        appendable=None,
    )


def _first_write(
    if_generation_match: Optional[Int64], var payload: List[UInt8], crc32c: Optional[UInt32]
) -> WriteObjectRequest:
    return WriteObjectRequest(
        write_offset=Int64(0),
        object_checksums=None,
        finish_write=True,
        common_object_request_params=None,
        _oneof0_case=2,
        upload_id=None,
        write_object_spec=Optional[WriteObjectSpec](_spec(if_generation_match)),
        _oneof1_case=1,
        checksummed_data=Optional[ChecksummedData](
            ChecksummedData(content=payload^, crc32c=crc32c)
        ),
    )


def _bytes(req: WriteObjectRequest) raises -> List[UInt8]:
    var enc = PbEncoder()
    req.encode(enc)
    return enc.into_buf()


def _roundtrip(req: WriteObjectRequest) raises -> WriteObjectRequest:
    var dec = PbDecoder(_bytes(req))
    return WriteObjectRequest.decode(dec)


def _payload() -> List[UInt8]:
    var p = List[UInt8]()
    p.append(UInt8(1))
    p.append(UInt8(2))
    p.append(UInt8(3))
    return p^


def test_create_if_absent_write_roundtrips() raises:
    var rt = _roundtrip(_first_write(Optional[Int64](Int64(0)), _payload(), None))
    assert_true(rt.finish_write)
    assert_equal(rt.write_offset, Int64(0))
    assert_equal(rt._oneof0_case, 2)
    assert_false(rt.upload_id.__bool__())
    assert_true(rt.write_object_spec.__bool__())
    assert_true(rt.write_object_spec.value().if_generation_match.__bool__())
    assert_equal(rt.write_object_spec.value().if_generation_match.value(), Int64(0))
    assert_false(rt.write_object_spec.value().if_generation_not_match.__bool__())
    assert_equal(rt._oneof1_case, 1)
    assert_equal(len(rt.checksummed_data.value().content), 3)
    assert_equal(rt.checksummed_data.value().content[0], UInt8(1))
    assert_equal(rt.checksummed_data.value().content[2], UInt8(3))
    assert_false(rt.checksummed_data.value().crc32c.__bool__())


def test_create_if_absent_write_bytes() raises:
    """The encoding of the create-if-absent first message, field by field:
    write_offset (3) 0, finish_write (7) true, write_object_spec (2) holding
    predefined_acl (7) "" and if_generation_match (3) 0, then
    checksummed_data (4) holding content (1) 01 02 03."""
    var want: List[UInt8] = [
        0x18, 0x00,
        0x38, 0x01,
        0x12, 0x04, 0x3A, 0x00, 0x18, 0x00,
        0x22, 0x05, 0x0A, 0x03, 0x01, 0x02, 0x03,
    ]
    var got = _bytes(_first_write(Optional[Int64](Int64(0)), _payload(), None))
    assert_equal(len(got), len(want))
    for i in range(len(want)):
        assert_equal(got[i], want[i], String("byte ") + String(i))


def test_an_unset_generation_match_is_not_on_the_wire() raises:
    """No precondition: the spec holds only predefined_acl, and the field
    decodes as unset, not as 0."""
    var got = _bytes(_first_write(None, _payload(), None))
    assert_equal(got[4], UInt8(0x12))
    assert_equal(got[5], UInt8(0x02), "the spec is predefined_acl alone")
    var rt = _roundtrip(_first_write(None, _payload(), None))
    assert_false(rt.write_object_spec.value().if_generation_match.__bool__())


def test_compare_and_swap_write_roundtrips() raises:
    var rt = _roundtrip(
        _first_write(Optional[Int64](Int64(1712345678901234)), List[UInt8](), None)
    )
    assert_equal(
        rt.write_object_spec.value().if_generation_match.value(),
        Int64(1712345678901234),
    )


def test_crc32c_is_a_fixed32() raises:
    var got = _bytes(_first_write(None, _payload(), Optional[UInt32](UInt32(0xE3069283))))
    # checksummed_data's last five bytes: tag (2, fixed32) and the value,
    # little-endian.
    var n = len(got)
    assert_equal(got[n - 5], UInt8(0x15))
    assert_equal(got[n - 4], UInt8(0x83))
    assert_equal(got[n - 3], UInt8(0x92))
    assert_equal(got[n - 2], UInt8(0x06))
    assert_equal(got[n - 1], UInt8(0xE3))
    var rt = _roundtrip(_first_write(None, _payload(), Optional[UInt32](UInt32(0xE3069283))))
    assert_equal(rt.checksummed_data.value().crc32c.value(), UInt32(0xE3069283))


def test_resumable_continuation_carries_the_upload_id() raises:
    var req = WriteObjectRequest(
        write_offset=Int64(2097152),
        object_checksums=None,
        finish_write=False,
        common_object_request_params=None,
        _oneof0_case=1,
        upload_id=Optional[String](String("upload-0001")),
        write_object_spec=None,
        _oneof1_case=1,
        checksummed_data=Optional[ChecksummedData](
            ChecksummedData(content=_payload(), crc32c=None)
        ),
    )
    var rt = _roundtrip(req)
    assert_equal(rt._oneof0_case, 1)
    assert_equal(rt.upload_id.value(), "upload-0001")
    assert_false(rt.write_object_spec.__bool__())
    assert_equal(rt.write_offset, Int64(2097152))
    assert_false(rt.finish_write)


def test_read_object_range_roundtrips() raises:
    var req = ReadObjectRequest(
        bucket=String("projects/_/buckets/b"),
        object=String("k"),
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
    var enc = PbEncoder()
    req.encode(enc)
    var dec = PbDecoder(enc.into_buf())
    var rt = ReadObjectRequest.decode(dec)
    assert_equal(rt.bucket, "projects/_/buckets/b")
    assert_equal(rt.object, "k")
    assert_equal(rt.read_offset, Int64(100))
    assert_equal(rt.read_limit, Int64(256))
    assert_false(rt.if_generation_match.__bool__())


def main() raises:
    test_create_if_absent_write_roundtrips()
    test_create_if_absent_write_bytes()
    test_an_unset_generation_match_is_not_on_the_wire()
    test_compare_and_swap_write_roundtrips()
    test_crc32c_is_a_fixed32()
    test_resumable_continuation_carries_the_upload_id()
    test_read_object_range_roundtrips()
    print("all Cloud Storage message tests passed")
