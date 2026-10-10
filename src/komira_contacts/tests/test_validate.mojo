# =============================================================================
# test_validate.mojo -- what a client may write (validate.mojo).
# =============================================================================
#
# One accepted value and one refused value per rule, the refusal compared by
# its exact text, so dropping a rule or loosening its bound fails a row:
#   book name   empty, 256 bytes, a line break; 255 bytes passes
#   card kind   a number no CardKind names
#   uid         1025 bytes, a line break; 1024 bytes passes
#   members     on an INDIVIDUAL card; on a GROUP card passes
#   pref        101 on an email, a phone, an address; 100 passes
# =============================================================================

from std.testing import assert_equal

from komira_proto_codec import decode_json
from komira_contacts_proto.contacts import Card, CardKind

from komira_contacts import check_book_name, check_card

comptime OK = "ok"


def _name(n: String) -> String:
    try:
        check_book_name(n)
        return String(OK)
    except e:
        return String(e)


def _card(json: String) raises -> String:
    var c = decode_json[Card](json)
    try:
        check_card(c)
        return String(OK)
    except e:
        return String(e)


def _repeat(n: Int) -> String:
    var s = String()
    for _ in range(n):
        s += "a"
    return s^


def test_book_name() raises:
    assert_equal(_name(""), "contacts: invalid name: required")
    assert_equal(_name(_repeat(255)), OK)
    assert_equal(_name(_repeat(256)), "contacts: invalid name: longer than 255 bytes")
    assert_equal(_name("a\nb"), "contacts: invalid name: must be one line")
    assert_equal(_name("a\rb"), "contacts: invalid name: must be one line")


def test_card() raises:
    assert_equal(_card('{"kind":"GROUP","members":["u1"]}'), OK)
    assert_equal(_card('{"kind":7}'), "contacts: invalid kind: must be INDIVIDUAL, ORG or GROUP")
    assert_equal(_card('{"uid":"' + _repeat(1024) + '"}'), OK)
    assert_equal(_card('{"uid":"' + _repeat(1025) + '"}'), "contacts: invalid uid: longer than 1024 bytes")
    assert_equal(_card('{"uid":"a\\nb"}'), "contacts: invalid uid: must be one line")
    assert_equal(_card('{"members":["u1"]}'), "contacts: invalid members: only a GROUP card has members")
    assert_equal(_card('{"emails":[{"pref":100}],"phones":[{"pref":100}],"addresses":[{"pref":100}]}'), OK)
    assert_equal(_card('{"emails":[{"pref":101}]}'), "contacts: invalid emails: pref must be 0 to 100")
    assert_equal(_card('{"phones":[{"pref":101}]}'), "contacts: invalid phones: pref must be 0 to 100")
    assert_equal(_card('{"addresses":[{"pref":101}]}'), "contacts: invalid addresses: pref must be 0 to 100")


def main() raises:
    test_book_name()
    test_card()
    print("PASS komira_contacts validate")
