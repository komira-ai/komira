from komira_proto_codec import PbDecoder, PbEncoder
from std.testing import assert_equal, assert_true
from team_proto.person import Person
from team_proto.team import Team


def main() raises:
    var lead = Person(name=String("hi"), id=Int64(300))
    var t = Team(title=String("core"), lead=Optional(lead^))
    var enc = PbEncoder()
    t.encode(enc)
    # field 1: "core"; field 2: the 7 bytes of the Person in test_person.
    assert_equal(enc.hex(), "0a 04 63 6f 72 65 12 07 0a 02 68 69 10 ac 02")
    var dec = PbDecoder(enc.buf)
    var u = Team.decode(dec)
    assert_equal(u.title, "core")
    assert_true(Bool(u.lead))
    assert_equal(u.lead.value().name, "hi")
    print("test_team: PASS")
