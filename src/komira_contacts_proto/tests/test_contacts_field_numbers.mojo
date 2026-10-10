# =============================================================================
# test_contacts_field_numbers.mojo
# =============================================================================
#
# THE WIRE CENSUS for `komira.contacts.v1`: field numbers as binary bytes,
# field names as proto3 JSON keys, enum numbers as their names.
#
# A stored card body and a client's request are only as stable as these
# numbers and names. Renumbering or renaming a field is legal to protoc and
# compiles clean; nothing else in the toolchain objects, so this file is the
# guard.
#
# BINARY. For Card (with every nested message) and AddressBook, a byte stream
# is written by hand here, field by field, with the number and wire type the
# proto declares and a value no other field of the message holds. Then:
#   1. it is decoded and every field is read back BY NAME, which catches two
#      fields of one wire type swapping numbers;
#   2. the decoded message is encoded again and must give the hand-written
#      bytes back exactly (the encoder writes fields in number order, each
#      repeated element as its own record), which catches a field moved to an
#      unused number and a changed wire type.
# The bytes restate the proto literally; deriving them from the generated
# code would agree with it by construction.
#
# JSON. The same Card and AddressBook, and a ChangesResponse, an
# ImportCardsResponse and an ErrorResponse, are encoded as proto3 JSON and
# compared with literal documents: every key (lowerCamel), a uint64 as a
# string, an enum as its name.
#
# ENUMS. Each value's number and name, both ways.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_proto_codec import decode_json, decode_proto, encode_json, encode_proto
from komira_contacts_proto.contacts import (
    AddressBook,
    BookKind,
    Card,
    CardKind,
    ChangesResponse,
    ErrorResponse,
    ImportCardsResponse,
)


def _varint(mut b: List[UInt8], v: UInt64):
    var x = v
    while x >= 0x80:
        b.append(UInt8((x & 0x7F) | 0x80))
        x >>= 7
    b.append(UInt8(x))


def _uint(mut b: List[UInt8], field: Int, v: UInt64):
    """A varint record: tag (wire type 0), then the value."""
    _varint(b, UInt64(field << 3))
    _varint(b, v)


def _len(mut b: List[UInt8], field: Int, payload: List[UInt8]):
    """A length-delimited record (wire type 2)."""
    _varint(b, UInt64((field << 3) | 2))
    _varint(b, UInt64(len(payload)))
    for c in payload:
        b.append(c)


def _str(mut b: List[UInt8], field: Int, s: String):
    var p = List[UInt8]()
    for c in s.as_bytes():
        p.append(c)
    _len(b, field, p)


def _hex(b: List[UInt8]) -> String:
    var digits = String("0123456789abcdef").as_bytes()
    var out = String()
    for i in range(len(b)):
        out += chr(Int(digits[Int(b[i]) >> 4]))
        out += chr(Int(digits[Int(b[i]) & 15]))
    return out^


def _card_bytes() -> List[UInt8]:
    var name = List[UInt8]()
    _str(name, 1, "F")
    _str(name, 2, "G")
    _str(name, 3, "S")
    _str(name, 4, "M")
    _str(name, 5, "P")
    _str(name, 6, "X")
    var org = List[UInt8]()
    _str(org, 1, "O")
    _str(org, 2, "U1")
    _str(org, 2, "U2")
    var email = List[UInt8]()
    _str(email, 1, "a@example.org")
    _str(email, 2, "work")
    _uint(email, 3, 1)
    var phone = List[UInt8]()
    _str(phone, 1, "+1")
    _str(phone, 2, "cell")
    _uint(phone, 3, 2)
    var adr = List[UInt8]()
    _str(adr, 1, "s")
    _str(adr, 2, "l")
    _str(adr, 3, "r")
    _str(adr, 4, "p")
    _str(adr, 5, "c")
    _str(adr, 6, "home")
    _uint(adr, 7, 3)
    var b = List[UInt8]()
    _str(b, 1, "c1")
    _str(b, 2, "b1")
    _str(b, 3, "u1")
    _uint(b, 4, 1)  # ORG
    _len(b, 5, name)
    _str(b, 6, "n")
    _len(b, 7, org)
    _str(b, 8, "t")
    _len(b, 9, email)
    _len(b, 10, phone)
    _len(b, 11, adr)
    _str(b, 12, "https://example.org")
    _str(b, 13, "19850412")
    _str(b, 14, "hi")
    _str(b, 15, "m1")
    _str(b, 16, "X-A:1")
    _uint(b, 17, 5)
    _uint(b, 18, 9)
    return b^


comptime _CARD_JSON = (
    '{"id":"c1","addressBookId":"b1","uid":"u1","kind":"ORG",'
    '"name":{"full":"F","given":"G","surname":"S","middle":"M","prefix":"P","suffix":"X"},'
    '"nickname":"n","organization":{"name":"O","units":["U1","U2"]},"title":"t",'
    '"emails":[{"address":"a@example.org","label":"work","pref":1}],'
    '"phones":[{"number":"+1","label":"cell","pref":2}],'
    '"addresses":[{"street":"s","locality":"l","region":"r","postcode":"p",'
    '"country":"c","label":"home","pref":3}],'
    '"urls":["https://example.org"],"birthday":"19850412","notes":"hi","members":["m1"],'
    '"vcardExtra":["X-A:1"],"version":"5","modseq":"9"}'
)


def test_card_binary() raises:
    var want = _card_bytes()
    var card = decode_proto[Card](want.copy())
    assert_equal(card.id, "c1")
    assert_equal(card.address_book_id, "b1")
    assert_equal(card.uid, "u1")
    assert_equal(card.kind.value, CardKind.ORG)
    ref name = card.name.value()
    assert_equal(name.full, "F")
    assert_equal(name.given, "G")
    assert_equal(name.surname, "S")
    assert_equal(name.middle, "M")
    assert_equal(name.prefix, "P")
    assert_equal(name.suffix, "X")
    assert_equal(card.nickname, "n")
    assert_equal(card.organization.value().name, "O")
    assert_equal(len(card.organization.value().units), 2)
    assert_equal(card.organization.value().units[1], "U2")
    assert_equal(card.title, "t")
    assert_equal(card.emails[0].address, "a@example.org")
    assert_equal(card.emails[0].label, "work")
    assert_equal(card.emails[0].pref, UInt32(1))
    assert_equal(card.phones[0].number, "+1")
    assert_equal(card.phones[0].label, "cell")
    assert_equal(card.phones[0].pref, UInt32(2))
    ref adr = card.addresses[0]
    assert_equal(adr.street, "s")
    assert_equal(adr.locality, "l")
    assert_equal(adr.region, "r")
    assert_equal(adr.postcode, "p")
    assert_equal(adr.country, "c")
    assert_equal(adr.label, "home")
    assert_equal(adr.pref, UInt32(3))
    assert_equal(card.urls[0], "https://example.org")
    assert_equal(card.birthday, "19850412")
    assert_equal(card.notes, "hi")
    assert_equal(card.members[0], "m1")
    assert_equal(card.vcard_extra[0], "X-A:1")
    assert_equal(card.version, UInt64(5))
    assert_equal(card.modseq, UInt64(9))
    assert_equal(_hex(encode_proto(card)), _hex(want), "Card re-encodes to the hand-written bytes")


def test_card_json() raises:
    var card = decode_proto[Card](_card_bytes())
    assert_equal(encode_json(card), String(_CARD_JSON))
    var back = decode_json[Card](String(_CARD_JSON))
    assert_equal(_hex(encode_proto(back)), _hex(_card_bytes()), "Card JSON decodes to the same message")


def test_address_book() raises:
    var want = List[UInt8]()
    _str(want, 1, "b1")
    _uint(want, 2, 2)  # SHARED
    _str(want, 3, "o")
    _str(want, 4, "N")
    _uint(want, 5, 1)
    _uint(want, 6, 3)
    _uint(want, 7, 4)
    var book = decode_proto[AddressBook](want.copy())
    assert_equal(book.id, "b1")
    assert_equal(book.kind.value, BookKind.SHARED)
    assert_equal(book.owner, "o")
    assert_equal(book.name, "N")
    assert_true(book.is_default)
    assert_equal(book.version, UInt64(3))
    assert_equal(book.modseq, UInt64(4))
    assert_equal(_hex(encode_proto(book)), _hex(want), "AddressBook re-encodes to the hand-written bytes")
    assert_equal(
        encode_json(book),
        '{"id":"b1","kind":"SHARED","owner":"o","name":"N","isDefault":true,"version":"3","modseq":"4"}',
    )


def test_feed_import_and_error_json() raises:
    comptime changes = (
        '{"changes":[{"cardId":"c1","uid":"u1","modseq":"7","deleted":true}],"modseq":"7"}'
    )
    assert_equal(encode_json(decode_json[ChangesResponse](changes)), changes)
    comptime imported = (
        '{"created":2,"updated":1,"refused":[{"index":3,"code":"invalid","message":"no FN"}]}'
    )
    assert_equal(encode_json(decode_json[ImportCardsResponse](imported)), imported)
    comptime err = '{"error":{"code":"not_found","message":"not found","field":"uid"}}'
    assert_equal(encode_json(decode_json[ErrorResponse](err)), err)


def test_enums() raises:
    assert_equal(BookKind.BOOK_KIND_UNSPECIFIED, 0)
    assert_equal(BookKind.PERSONAL, 1)
    assert_equal(BookKind.SHARED, 2)
    assert_equal(BookKind.DIRECTORY, 3)
    assert_equal(BookKind(BookKind.PERSONAL).json_name(), "PERSONAL")
    assert_equal(BookKind(BookKind.DIRECTORY).json_name(), "DIRECTORY")
    assert_equal(BookKind.from_json_name("SHARED").value, 2)
    assert_equal(CardKind.INDIVIDUAL, 0)
    assert_equal(CardKind.ORG, 1)
    assert_equal(CardKind.GROUP, 2)
    assert_equal(CardKind(CardKind.GROUP).json_name(), "GROUP")
    assert_equal(CardKind.from_json_name("ORG").value, 1)


def main() raises:
    test_card_binary()
    test_card_json()
    test_address_book()
    test_feed_import_and_error_json()
    test_enums()
    print("PASS komira_contacts_proto field numbers")
