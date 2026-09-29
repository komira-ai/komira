from komira_serde import PbDecoder, PbEncoder
from person_proto.person import Person
from std.testing import assert_equal


def main() raises:
    var p = Person(name=String("hi"), id=Int64(300))
    var enc = PbEncoder()
    p.encode(enc)
    # The bytes prost produces for the same message (//tools/build/examples/rust).
    assert_equal(enc.hex(), "0a 02 68 69 10 ac 02")
    var dec = PbDecoder(enc.buf)
    var q = Person.decode(dec)
    assert_equal(q.name, "hi")
    assert_equal(String(q.id), "300")
    print("test_person: PASS")
