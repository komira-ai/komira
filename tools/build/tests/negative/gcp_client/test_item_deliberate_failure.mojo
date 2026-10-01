from caller_test_red.item import Item
from komira_serde import PbEncoder
from std.testing import assert_equal


def main() raises:
    # The encoding is "0a 02 68 69 10 ac 02"; the expectation is wrong on
    # purpose, so the library's gate must refuse to publish its package.
    var item = Item(name=String("hi"), price_cents=Int64(300))
    var enc = PbEncoder()
    item.encode(enc)
    assert_equal(enc.hex(), "0a 02 68 69 10 ad 02")
