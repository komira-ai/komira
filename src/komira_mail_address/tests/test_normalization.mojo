# Normalization and formatting: the domain is lower-cased, the local part's
# case and content are kept, quoting is the minimum, two quoted forms of one
# local part are one address, and formatting then parsing gives the same
# values back.

from std.testing import assert_equal, assert_false, assert_true

from komira_mail_address import (
    AddrSpec,
    Address,
    Group,
    Mailbox,
    format_address_list,
    parse_addr_spec,
    parse_address_list,
    parse_mailbox,
)


def test_domain_is_lower_cased_local_part_kept() raises:
    # (input, local part, domain, formatted)
    var a = parse_addr_spec("Jane.Doe@Example.COM")
    assert_equal(a.local_part(), "Jane.Doe")
    assert_equal(a.domain(), "example.com")
    assert_equal(a.format(), "Jane.Doe@example.com")
    assert_equal(AddrSpec("x", "MAIL.Example.ORG").domain(), "mail.example.org")
    assert_equal(parse_addr_spec("a@XN--BCHER-KVA.Example").domain(), "xn--bcher-kva.example")
    assert_equal(parse_addr_spec("a@Sub-1.Example9.test").domain(), "sub-1.example9.test")


def test_equality() raises:
    assert_true(parse_addr_spec('"john"@example.com') == parse_addr_spec("john@example.com"))
    assert_true(parse_addr_spec('"john.doe"@example.com') == parse_addr_spec("john.doe@example.com"))
    assert_true(parse_addr_spec("a@EXAMPLE.com") == parse_addr_spec("a@example.com"))
    assert_true(parse_addr_spec("John@example.com") != parse_addr_spec("john@example.com"))
    assert_true(parse_addr_spec("a@example.com") != parse_addr_spec("a@example.net"))
    assert_true(parse_addr_spec(" a (comment) @ example.com ") == AddrSpec("a", "example.com"))


def test_minimum_quoting() raises:
    assert_equal(parse_addr_spec('"john.doe"@example.com').format(), "john.doe@example.com")
    assert_equal(parse_addr_spec('"a b"@example.com').format(), '"a b"@example.com')
    assert_equal(parse_addr_spec('"a\\"b"@example.com').format(), '"a\\"b"@example.com')
    assert_equal(parse_addr_spec('"\\a\\b\\c"@example.com').format(), "abc@example.com")


def test_display_names() raises:
    var addr = AddrSpec("support", "Acme.Example")
    assert_equal(Mailbox(addr).format(), "support@acme.example")
    assert_equal(Mailbox("Acme Support", addr).format(), "Acme Support <support@acme.example>")
    assert_equal(Mailbox("Doe, Jane", addr).format(), '"Doe, Jane" <support@acme.example>')
    assert_equal(Mailbox(" padded ", addr).format(), '" padded " <support@acme.example>')
    assert_equal(Mailbox('say "hi"', addr).format(), '"say \\"hi\\"" <support@acme.example>')
    # An encoded word is ASCII text here; decoding it is the message layer's.
    var m = parse_mailbox("=?utf-8?q?Caf=C3=A9?= <a@example.com>")
    assert_equal(m.display_name(), "=?utf-8?q?Caf=C3=A9?=")
    assert_equal(m.format(), "=?utf-8?q?Caf=C3=A9?= <a@example.com>")
    # Words separated by any CFWS become one space; quoted white space is kept.
    assert_equal(parse_mailbox("  John \t (x) Doe  <a@example.com>").display_name(), "John Doe")
    assert_equal(parse_mailbox('"John  Doe" <a@example.com>').display_name(), "John  Doe")


def test_round_trip() raises:
    var members = List[Mailbox]()
    members.append(Mailbox("Ed Jones", AddrSpec("c", "a.test")))
    members.append(Mailbox(AddrSpec("joe", "where.test")))
    var list = List[Address]()
    list.append(Address(Mailbox('Giant; "Big" Box', AddrSpec("sys services", "Example.NET"))))
    list.append(Address(Group("A Group", members)))
    list.append(Address(Group("Undisclosed recipients", List[Mailbox]())))
    var text = format_address_list(list)
    assert_equal(
        text,
        '"Giant; \\"Big\\" Box" <"sys services"@example.net>, A Group:Ed Jones <c@a.test>, joe@where.test;, Undisclosed recipients:;',
    )
    var back = parse_address_list(text)
    assert_equal(len(back), 3)
    assert_equal(format_address_list(back), text)
    assert_equal(back[0].mailbox().display_name(), 'Giant; "Big" Box')
    assert_true(back[0].mailbox().addr_spec() == AddrSpec("sys services", "example.net"))
    assert_equal(len(back[1].group().members()), 2)


def test_constructors_refuse() raises:
    var msg = String("OK")
    try:
        _ = Group("", List[Mailbox]())
    except e:
        msg = String(e)
    assert_equal(msg, "komira_mail_address.Syntax: Group: an empty group name at position 0")
    msg = String("OK")
    try:
        _ = Mailbox(String("a") + chr(1) + "b", AddrSpec("a", "example.com"))
    except e:
        msg = String(e)
    assert_equal(msg, "komira_mail_address.Syntax: Mailbox: a control byte in the display name at position 1")
    msg = String("OK")
    try:
        _ = AddrSpec("", "example.com")
    except e:
        msg = String(e)
    assert_equal(msg, "komira_mail_address.Syntax: AddrSpec: an empty local part at position 0")


def main() raises:
    test_domain_is_lower_cased_local_part_kept()
    test_equality()
    test_minimum_quoting()
    test_display_names()
    test_round_trip()
    test_constructors_refuse()
    print("test_normalization: OK")
