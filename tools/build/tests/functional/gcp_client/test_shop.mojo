from komira_gcp_shop.item import Item
from komira_gcp_shop.shop import GetItemRequest, GetItemResponse
from komira_proto_codec import PbDecoder, PbEncoder
from std.testing import assert_equal, assert_true


def main() raises:
    var req = GetItemRequest(name=String("hi"))
    var enc = PbEncoder()
    req.encode(enc)
    assert_equal(enc.hex(), "0a 02 68 69")

    # GetItemResponse refers to Item, generated from the bundled item.proto
    # into the same package.
    var item = Item(name=String("hi"), price_cents=Int64(300))
    var resp = GetItemResponse(item=Optional(item^), version=Int64(5))
    var out = PbEncoder()
    resp.encode(out)
    # field 1: the 7 bytes of the Item; field 2: 5.
    assert_equal(out.hex(), "0a 07 0a 02 68 69 10 ac 02 10 05")
    var dec = PbDecoder(out.buf)
    var back = GetItemResponse.decode(dec)
    assert_true(Bool(back.item))
    assert_equal(back.item.value().name, "hi")
    assert_equal(String(back.item.value().price_cents), "300")
    assert_equal(String(back.version), "5")
    print("test_shop: PASS")
