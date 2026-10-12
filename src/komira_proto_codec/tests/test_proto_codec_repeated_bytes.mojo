# =============================================================================
# test_proto_codec_repeated_bytes.mojo — `repeated bytes` on both backends.
# =============================================================================
#
# The generator emits `enc.write_bytes_element` and `dec.read_into_repeated_bytes`
# for a `repeated bytes` field (`UdfRef.data_blobs` in komira_plan_proto is
# the first one in the tree). This suite holds both backends to the shape a
# foreign reader expects:
#
#   * protobuf-binary: one length-delimited record per element, never packed,
#     in order, an empty element kept as a zero-length record. Checked in exact
#     bytes, then decoded back.
#   * proto3-JSON: an array of base64 strings. Checked as text, then decoded
#     back.
#
# The message is HAND-WRITTEN in the generator's shape (begin_list_field, one
# element call per item, end_list_field; one read call per next_field()).
# Defects each case catches: an encoder that packs the elements or drops an
# empty one (the exact-bytes check), a decoder that reads one element per
# field instead of appending (the two-element decode), a JSON element written
# raw instead of base64 (the text check).
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_proto_codec import (
    Serializable,
    WireEncoder,
    WireDecoder,
    encode_proto,
    decode_proto,
    encode_json,
    decode_json,
)


@fieldwise_init
struct Blobs(Serializable):
    """`message Blobs { repeated bytes blobs = 1; }`."""

    var blobs: List[List[UInt8]]

    def encode[E: WireEncoder](self, mut enc: E) raises:
        enc.begin_list_field(1, "blobs")
        for i in range(len(self.blobs)):
            enc.write_bytes_element(1, self.blobs[i])
        enc.end_list_field()

    @staticmethod
    def decode[D: WireDecoder](mut dec: D) raises -> Self:
        var blobs = List[List[UInt8]]()
        while True:
            var key = dec.next_field()
            if key.end:
                break
            if key.field_no == 1 or key.json_name == "blobs":
                dec.read_into_repeated_bytes(blobs)
            else:
                dec.skip()
        return Blobs(blobs^)


def _corpus() -> Blobs:
    var blobs = List[List[UInt8]]()
    var a: List[UInt8] = [0x00, 0xFF, 0x80]
    blobs.append(a^)
    blobs.append(List[UInt8]())
    var c: List[UInt8] = [0x41]
    blobs.append(c^)
    return Blobs(blobs^)


def _hex(b: List[UInt8]) -> String:
    var out = String("")
    for i in range(len(b)):
        out += hex(Int(b[i])) + " "
    return out


def _check_decoded(got: Blobs, what: String) raises:
    assert_equal(len(got.blobs), 3, what + ": element count")
    assert_equal(_hex(got.blobs[0]), "0x0 0xff 0x80 ", what + ": element 0")
    assert_equal(len(got.blobs[1]), 0, what + ": the empty element survives")
    assert_equal(_hex(got.blobs[2]), "0x41 ", what + ": element 2")


def test_binary_records() raises:
    var bytes = encode_proto(_corpus())
    # 0a 03 00 ff 80 | 0a 00 | 0a 01 41: three records under field 1, LEN.
    assert_equal(
        _hex(bytes),
        "0xa 0x3 0x0 0xff 0x80 0xa 0x0 0xa 0x1 0x41 ",
        "binary: one record per element, unpacked, the empty one kept",
    )
    _check_decoded(decode_proto[Blobs](bytes^), "binary")


def test_json_base64_array() raises:
    var text = encode_json(_corpus())
    assert_equal(text, '{"blobs":["AP+A","","QQ=="]}', "json: an array of base64 strings")
    _check_decoded(decode_json[Blobs](text), "json")


def main() raises:
    test_binary_records()
    test_json_base64_array()
    print("test_proto_codec_repeated_bytes: OK")
