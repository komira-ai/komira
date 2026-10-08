# The address fields of RFC 5322 Appendix A, each parsed and checked field by
# field, then formatted back. A.1.1-A.3 are the plain forms; A.5 is the
# white-space-and-comments example, unfolded (RFC 5322 section 2.2.3) because
# the parsers take an unfolded field body; A.6.1 is the obsolete example: its
# `From:` (a `.` in an unquoted display name) is accepted, and each obsolete
# form of its `To:` is refused with the exact message.

from std.testing import assert_equal, assert_false, assert_true

from komira_mail_address import (
    AddrSpec,
    Address,
    Mailbox,
    format_address_list,
    format_mailbox_list,
    parse_address_list,
    parse_mailbox,
    parse_mailbox_list,
)


def _check(m: Mailbox, name: String, local: String, domain: String) raises:
    assert_equal(m.display_name(), name)
    assert_equal(m.addr_spec().local_part(), local)
    assert_equal(m.addr_spec().domain(), domain)


def _one(field_body: String) raises -> Mailbox:
    var list = parse_mailbox_list(field_body)
    assert_equal(len(list), 1)
    return list[0].copy()


def _list_error(field_body: String) -> String:
    try:
        _ = parse_address_list(field_body)
    except e:
        return String(e)
    return String("OK")


def test_a_1_1_simple_addressing() raises:
    _check(_one(" John Doe <jdoe@machine.example>"), "John Doe", "jdoe", "machine.example")
    var to = parse_address_list(" Mary Smith <mary@example.net>")
    assert_equal(len(to), 1)
    _check(to[0].mailbox(), "Mary Smith", "mary", "example.net")
    _check(
        parse_mailbox(" Michael Jones <mjones@machine.example>"),
        "Michael Jones",
        "mjones",
        "machine.example",
    )
    assert_equal(format_address_list(to), "Mary Smith <mary@example.net>")


def test_a_1_2_different_types_of_mailboxes() raises:
    var from_ = _one(' "Joe Q. Public" <john.q.public@example.com>')
    _check(from_, "Joe Q. Public", "john.q.public", "example.com")
    assert_equal(from_.format(), '"Joe Q. Public" <john.q.public@example.com>')

    var to = parse_address_list(
        " Mary Smith <mary@x.test>, jdoe@example.org, Who? <one@y.test>"
    )
    assert_equal(len(to), 3)
    _check(to[0].mailbox(), "Mary Smith", "mary", "x.test")
    _check(to[1].mailbox(), "", "jdoe", "example.org")
    _check(to[2].mailbox(), "Who?", "one", "y.test")
    assert_equal(
        format_address_list(to),
        "Mary Smith <mary@x.test>, jdoe@example.org, Who? <one@y.test>",
    )

    var cc = parse_address_list(
        ' <boss@nil.test>, "Giant; \\"Big\\" Box" <sysservices@example.net>'
    )
    assert_equal(len(cc), 2)
    _check(cc[0].mailbox(), "", "boss", "nil.test")
    _check(cc[1].mailbox(), 'Giant; "Big" Box', "sysservices", "example.net")
    # `<boss@nil.test>` has no display name, so it is written bare.
    assert_equal(
        format_address_list(cc),
        'boss@nil.test, "Giant; \\"Big\\" Box" <sysservices@example.net>',
    )


def test_a_1_3_group_addresses() raises:
    _check(_one(" Pete <pete@silly.example>"), "Pete", "pete", "silly.example")
    var to = parse_address_list(
        " A Group:Ed Jones <c@a.test>,joe@where.test,John <jdoe@one.test>;"
    )
    assert_equal(len(to), 1)
    assert_true(to[0].is_group())
    var g = to[0].group()
    assert_equal(g.name(), "A Group")
    var m = g.members()
    assert_equal(len(m), 3)
    _check(m[0], "Ed Jones", "c", "a.test")
    _check(m[1], "", "joe", "where.test")
    _check(m[2], "John", "jdoe", "one.test")
    assert_equal(len(to[0].mailboxes()), 3)
    assert_equal(
        format_address_list(to),
        "A Group:Ed Jones <c@a.test>, joe@where.test, John <jdoe@one.test>;",
    )

    var cc = parse_address_list(" Undisclosed recipients:;")
    assert_equal(len(cc), 1)
    assert_true(cc[0].is_group())
    assert_equal(cc[0].group().name(), "Undisclosed recipients")
    assert_equal(len(cc[0].group().members()), 0)
    assert_equal(format_address_list(cc), "Undisclosed recipients:;")


def test_a_2_reply_messages() raises:
    var reply_to = parse_address_list(
        ' "Mary Smith: Personal Account" <smith@home.example>'
    )
    assert_equal(len(reply_to), 1)
    assert_false(reply_to[0].is_group())
    _check(
        reply_to[0].mailbox(),
        "Mary Smith: Personal Account",
        "smith",
        "home.example",
    )
    assert_equal(
        format_address_list(reply_to),
        '"Mary Smith: Personal Account" <smith@home.example>',
    )
    _check(_one(" Mary Smith <mary@example.net>"), "Mary Smith", "mary", "example.net")
    _check(_one(" John Doe <jdoe@machine.example>"), "John Doe", "jdoe", "machine.example")


def test_a_3_resent_messages() raises:
    _check(_one(" Mary Smith <mary@example.net>"), "Mary Smith", "mary", "example.net")
    var to = parse_address_list(" Jane Brown <j-brown@other.example>")
    _check(to[0].mailbox(), "Jane Brown", "j-brown", "other.example")


def test_a_5_white_space_and_comments() raises:
    var from_ = _one(" Pete(A nice \\) chap) <pete(his account)@silly.test(his host)>")
    _check(from_, "Pete", "pete", "silly.test")
    assert_equal(from_.format(), "Pete <pete@silly.test>")

    var to = parse_address_list(
        String("A Group(Some people)")
        + "     :Chris Jones <c@(Chris's host.)public.example>,"
        + "         joe@example.org,"
        + "  John <jdoe@one.test> (my dear friend); (the end of the group)"
    )
    assert_equal(len(to), 1)
    var g = to[0].group()
    assert_equal(g.name(), "A Group")
    var m = g.members()
    assert_equal(len(m), 3)
    _check(m[0], "Chris Jones", "c", "public.example")
    _check(m[1], "", "joe", "example.org")
    _check(m[2], "John", "jdoe", "one.test")
    assert_equal(
        format_address_list(to),
        "A Group:Chris Jones <c@public.example>, joe@example.org, John <jdoe@one.test>;",
    )

    var cc = parse_address_list(
        "(Empty list)(start)Hidden recipients  :(nobody(that I know))  ;"
    )
    assert_equal(len(cc), 1)
    assert_equal(cc[0].group().name(), "Hidden recipients")
    assert_equal(len(cc[0].group().members()), 0)


def test_a_6_1_obsolete_addressing() raises:
    # Accepted: the unquoted `.` in the display name (obs-phrase). It is
    # written back quoted, the form RFC 5322 says to generate.
    var from_ = _one(" Joe Q. Public <john.q.public@example.com>")
    _check(from_, "Joe Q. Public", "john.q.public", "example.com")
    assert_equal(
        format_mailbox_list(parse_mailbox_list(" Joe Q. Public <john.q.public@example.com>")),
        '"Joe Q. Public" <john.q.public@example.com>',
    )
    # Refused: the `To:` field as written, then each of its obsolete forms on
    # its own.
    assert_equal(
        _list_error(" Mary Smith <@node.test:mary@example.net>, , jdoe@test  . example"),
        "komira_mail_address.Obsolete: parse_address_list: a source route (obsolete syntax) at position 13",
    )
    assert_equal(
        _list_error(" Mary Smith <mary@example.net>, , jdoe@test.example"),
        "komira_mail_address.Obsolete: parse_address_list: an empty list element (obsolete syntax) at position 32",
    )
    assert_equal(
        _list_error(" jdoe@test  . example"),
        "komira_mail_address.Obsolete: parse_address_list: white space or a comment before '.' (obsolete syntax) at position 12",
    )


def main() raises:
    test_a_1_1_simple_addressing()
    test_a_1_2_different_types_of_mailboxes()
    test_a_1_3_group_addresses()
    test_a_2_reply_messages()
    test_a_3_resent_messages()
    test_a_5_white_space_and_comments()
    test_a_6_1_obsolete_addressing()
