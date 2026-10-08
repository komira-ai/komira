# What the parsers and constructors refuse, each with its exact message:
# CR, LF and NUL anywhere (header and SMTP command injection), bytes above
# 0x7F (no SMTPUTF8, no IDNA), a second `@` (one input, one address), domain
# literals, domains that are not RFC 5321 `Domain`s, the RFC 5321 length
# limits, unterminated quotes and comments, a group inside a group. Also the
# RFC 3696 section 3 examples (as corrected by its errata 246) and the
# comma-smuggling vector: a quoted local part holding `@` and `,` is ONE
# address, never split.

from std.testing import assert_equal, assert_false, assert_true

from komira_mail_address import (
    AddrSpec,
    Group,
    Mailbox,
    error_kind,
    parse_addr_spec,
    parse_address_list,
    parse_mailbox,
    parse_mailbox_list,
    parse_path,
)


def _addr_error(s: String) -> String:
    try:
        _ = parse_addr_spec(s)
    except e:
        return String(e)
    return String("OK")


def _list_error(s: String) -> String:
    try:
        _ = parse_address_list(s)
    except e:
        return String(e)
    return String("OK")


def _mailbox_error(s: String) -> String:
    try:
        _ = parse_mailbox(s)
    except e:
        return String(e)
    return String("OK")


def _mailbox_list_error(s: String) -> String:
    try:
        _ = parse_mailbox_list(s)
    except e:
        return String(e)
    return String("OK")


def _path_error(s: String) -> String:
    try:
        _ = parse_path(s)
    except e:
        return String(e)
    return String("OK")


def _new_addr_error(local: String, domain: String) -> String:
    try:
        _ = AddrSpec(local, domain)
    except e:
        return String(e)
    return String("OK")


def _new_mailbox_error(name: String) -> String:
    try:
        _ = Mailbox(name, AddrSpec("a", "example.com"))
    except e:
        return String(e)
    return String("OK")


def _new_group_error(name: String) -> String:
    try:
        _ = Group(name, List[Mailbox]())
    except e:
        return String(e)
    return String("OK")


comptime P: String = "komira_mail_address."


def test_cr_lf_nul_are_refused_everywhere() raises:
    assert_equal(
        _mailbox_error("victim@example.com\r\nBcc: attacker@example.net"),
        P + "ForbiddenByte: parse_mailbox: CR, LF or NUL at position 18",
    )
    assert_equal(
        _list_error("a@example.com\nBcc: x@example.net"),
        P + "ForbiddenByte: parse_address_list: CR, LF or NUL at position 13",
    )
    assert_equal(
        _addr_error(String("a@exa") + chr(0) + "mple.com"),
        P + "ForbiddenByte: parse_addr_spec: CR, LF or NUL at position 5",
    )
    # Inside a quoted display name, a quoted local part, and a comment.
    assert_equal(
        _mailbox_error('"Joe\r\nBcc: x@example.net" <a@example.com>'),
        P + "ForbiddenByte: parse_mailbox: CR, LF or NUL at position 4",
    )
    assert_equal(
        _addr_error('"a\nb"@example.com'),
        P + "ForbiddenByte: parse_addr_spec: CR, LF or NUL at position 2",
    )
    assert_equal(
        _mailbox_error("a@example.com (x\ny)"),
        P + "ForbiddenByte: parse_mailbox: CR, LF or NUL at position 16",
    )
    assert_equal(
        _mailbox_list_error("a@example.com\r"),
        P + "ForbiddenByte: parse_mailbox_list: CR, LF or NUL at position 13",
    )
    assert_equal(
        _path_error("<a@example.com>\r\nRCPT TO:<b@example.com>"),
        P + "ForbiddenByte: parse_path: CR, LF or NUL at position 15",
    )
    # Constructors refuse them too, so no value can hold one.
    assert_equal(
        _new_addr_error("a\nb", "example.com"),
        P + "ForbiddenByte: AddrSpec: CR, LF or NUL at position 1",
    )
    assert_equal(
        _new_addr_error("a", "example.com\r\n"),
        P + "ForbiddenByte: AddrSpec: CR, LF or NUL at position 11",
    )
    assert_equal(
        _new_mailbox_error("Joe\r\nBcc: x@example.net"),
        P + "ForbiddenByte: Mailbox: CR, LF or NUL at position 3",
    )
    assert_equal(
        _new_group_error("A\r\nBcc: x@example.net"),
        P + "ForbiddenByte: Group: CR, LF or NUL at position 1",
    )
    assert_equal(
        _new_group_error(String("A") + chr(1) + "B"),
        P + "Syntax: Group: a control byte in the group name at position 1",
    )


def test_non_ascii_is_refused_and_a_labels_pass() raises:
    assert_equal(
        _addr_error("jörg@example.com"),
        P + "NonAscii: parse_addr_spec: a byte above 0x7F (SMTPUTF8 and IDNA are not supported) at position 1",
    )
    assert_equal(
        _addr_error("user@bücher.example"),
        P + "NonAscii: parse_addr_spec: a byte above 0x7F (SMTPUTF8 and IDNA are not supported) at position 6",
    )
    assert_equal(
        _new_mailbox_error("Café"),
        P + "NonAscii: Mailbox: a byte above 0x7F (SMTPUTF8 and IDNA are not supported) at position 3",
    )
    var a = parse_addr_spec("user@xn--bcher-kva.example")
    assert_equal(a.domain(), "xn--bcher-kva.example")


def test_one_input_one_address() raises:
    # The comma-smuggling vector: one address whose local part holds `@`
    # and `,`; a splitter on `,` or `@` would deliver to victim.example.
    var list = parse_address_list('"x@victim.example,y"@acme.example')
    assert_equal(len(list), 1)
    var a = list[0].mailbox().addr_spec()
    assert_equal(a.local_part(), "x@victim.example,y")
    assert_equal(a.domain(), "acme.example")
    assert_equal(a.format(), '"x@victim.example,y"@acme.example')
    assert_equal(a.format_path(), '<"x@victim.example,y"@acme.example>')
    # A second `@` is refused, never read as either address.
    assert_equal(
        _addr_error("a@b@acme.example"),
        P + "Syntax: parse_addr_spec: unexpected byte after the address at position 3",
    )
    assert_equal(
        _list_error("a@b@acme.example"),
        P + "Syntax: parse_address_list: unexpected byte after the address at position 3",
    )
    assert_equal(
        _mailbox_error("<a@b@acme.example>"),
        P + "Syntax: parse_mailbox: expected '>' at position 4",
    )
    assert_equal(
        _mailbox_error("a@b@acme.example"),
        P + "Syntax: parse_mailbox: unexpected byte after the address at position 3",
    )
    # Two mailboxes where one is asked for: refused, never the first.
    assert_equal(
        _mailbox_error("a@x.test, b@y.test"),
        P + "Syntax: parse_mailbox: unexpected byte after the address at position 8",
    )


def test_rfc3696_section_3_examples() raises:
    # Valid: the section's list, with its first three entries as corrected
    # by erratum 246 (the backslash forms moved inside quotes), byte for byte.
    assert_equal(parse_addr_spec('"Abc\\@def"@example.com').local_part(), "Abc@def")
    assert_equal(
        parse_addr_spec('"Fred\\ Bloggs"@example.com').local_part(), "Fred Bloggs"
    )
    assert_equal(
        parse_addr_spec('"Joe.\\\\Blow"@example.com').local_part(), "Joe.\\Blow"
    )
    assert_equal(
        parse_addr_spec("customer/department=shipping@example.com").local_part(),
        "customer/department=shipping",
    )
    assert_equal(parse_addr_spec("$A12345@example.com").local_part(), "$A12345")
    assert_equal(
        parse_addr_spec("!def!xyz%abc@example.com").local_part(), "!def!xyz%abc"
    )
    assert_equal(parse_addr_spec("_somename@example.com").local_part(), "_somename")
    assert_equal(parse_addr_spec('"Abc@def"@example.com').local_part(), "Abc@def")
    assert_equal(
        parse_addr_spec('"Fred Bloggs"@example.com').local_part(), "Fred Bloggs"
    )
    # Invalid: the three unquoted backslash forms of the original text.
    assert_equal(
        _addr_error("Abc\\@def@example.com"),
        P + "Syntax: parse_addr_spec: expected '@' at position 3",
    )
    assert_equal(
        _addr_error("Fred\\ Bloggs@example.com"),
        P + "Syntax: parse_addr_spec: expected '@' at position 4",
    )
    assert_equal(
        _addr_error("Joe.\\\\Blow@example.com"),
        P + "Syntax: parse_addr_spec: '.' not followed by an atom at position 3",
    )
    # RFC 5321 section 4.1.2: "Joe\,Smith" is the nine-character `Joe,Smith`.
    var j = parse_addr_spec('"Joe\\,Smith"@example.com')
    assert_equal(j.local_part(), "Joe,Smith")
    assert_equal(j.format(), '"Joe,Smith"@example.com')


def test_domains() raises:
    assert_equal(
        _addr_error("user@[192.0.2.1]"),
        P + "Unsupported: parse_addr_spec: a domain literal at position 5",
    )
    assert_equal(
        _addr_error("user@exa_mple.com"),
        P + "InvalidDomain: parse_addr_spec: a byte other than a letter, digit or '-' in a domain label at position 8",
    )
    assert_equal(
        _addr_error("user@-example.test"),
        P + "InvalidDomain: parse_addr_spec: a domain label starting or ending with '-' at position 5",
    )
    assert_equal(
        _addr_error("user@example-.test"),
        P + "InvalidDomain: parse_addr_spec: a domain label starting or ending with '-' at position 12",
    )
    assert_equal(
        _addr_error("user@example.com."),
        P + "Syntax: parse_addr_spec: '.' not followed by an atom at position 16",
    )
    assert_equal(
        _new_addr_error("user", "example..com"),
        P + "InvalidDomain: AddrSpec: an empty domain label at position 8",
    )
    assert_equal(
        _new_addr_error("user", ""),
        P + "InvalidDomain: AddrSpec: an empty domain label at position 0",
    )
    assert_equal(
        _new_addr_error("user", "[192.0.2.1]"),
        P + "Unsupported: AddrSpec: a domain literal at position 0",
    )


def _repeat(c: String, n: Int) -> String:
    var s = String("")
    for _ in range(n):
        s += c
    return s


def test_length_limits() raises:
    # Local part: 64 octets as written.
    assert_equal(parse_addr_spec(_repeat("a", 64) + "@example.com").local_part(), _repeat("a", 64))
    assert_equal(
        _addr_error(_repeat("a", 65) + "@example.com"),
        P + "TooLong: parse_addr_spec: a local part longer than 64 octets at position 0",
    )
    # 62 content octets plus a space need quotes: 65 written.
    assert_equal(
        _new_addr_error(_repeat("a", 62) + " ", "example.com"),
        P + "TooLong: AddrSpec: a local part longer than 64 octets at position 0",
    )
    # A '"' is written with a backslash: 61 + 1 content octets are 2 + 62 + 1
    # = 65 written, refused; 60 + 1 are 64 written, accepted.
    assert_equal(
        _new_addr_error(_repeat("a", 61) + '"', "example.com"),
        P + "TooLong: AddrSpec: a local part longer than 64 octets at position 0",
    )
    var q64 = AddrSpec(_repeat("a", 60) + '"', "example.com")
    assert_equal(q64.format(), '"' + _repeat("a", 60) + '\\""@example.com')
    # A '\' is written with a backslash too: the same 65 refused, 64 accepted.
    assert_equal(
        _new_addr_error(_repeat("a", 61) + "\\", "example.com"),
        P + "TooLong: AddrSpec: a local part longer than 64 octets at position 0",
    )
    var b64 = AddrSpec(_repeat("a", 60) + "\\", "example.com")
    assert_equal(b64.format(), '"' + _repeat("a", 60) + '\\\\"@example.com')
    # Label: 63 octets.
    assert_equal(parse_addr_spec("a@" + _repeat("b", 63) + ".com").domain(), _repeat("b", 63) + ".com")
    assert_equal(
        _addr_error("a@" + _repeat("b", 64) + ".com"),
        P + "TooLong: parse_addr_spec: a domain label longer than 63 octets at position 2",
    )
    # Domain: at most 253 octets. The path limit is reached first (`<a@` +
    # 253 + `>` is 257), so the longest domain any address can hold is 252,
    # and 254 is refused by the domain rule, before the path rule.
    var l63 = _repeat("d", 63)
    var d253 = l63 + "." + l63 + "." + l63 + "." + _repeat("e", 61)
    var d252 = l63 + "." + l63 + "." + l63 + "." + _repeat("e", 60)
    assert_equal(parse_addr_spec("a@" + d252).domain(), d252)
    assert_equal(
        _addr_error("a@" + d253),
        P + "TooLong: parse_addr_spec: a path longer than 256 octets at position 0",
    )
    assert_equal(
        _addr_error("a@" + d253 + "e"),
        P + "TooLong: parse_addr_spec: a domain longer than 253 octets at position 2",
    )
    # Path: `<` + 64 + `@` + domain + `>` at most 256, so the domain may be
    # 189 octets beside a 64-octet local part, not 190.
    var l64 = _repeat("a", 64)
    var d189 = l63 + "." + l63 + "." + _repeat("f", 61)
    assert_equal(parse_addr_spec(l64 + "@" + d189).format_path().byte_length(), 256)
    assert_equal(
        _addr_error(l64 + "@" + d189 + "f"),
        P + "TooLong: parse_addr_spec: a path longer than 256 octets at position 0",
    )


def test_malformed() raises:
    assert_equal(
        _addr_error('"abc@example.com'),
        P + "Syntax: parse_addr_spec: an unterminated quoted string at position 0",
    )
    assert_equal(
        _addr_error("a(b@example.com"),
        P + "Syntax: parse_addr_spec: an unterminated comment at position 1",
    )
    assert_equal(
        _addr_error("@example.com"),
        P + "Syntax: parse_addr_spec: expected a local part at position 0",
    )
    assert_equal(
        _addr_error("user@"),
        P + "Syntax: parse_addr_spec: expected a domain at position 5",
    )
    assert_equal(
        _addr_error("a..b@example.com"),
        P + "Syntax: parse_addr_spec: '.' not followed by an atom at position 1",
    )
    assert_equal(
        _addr_error('"a".b@example.com'),
        P + "Obsolete: parse_addr_spec: a quoted string in a dotted local part (obsolete syntax) at position 3",
    )
    # The same obsolete form with the quoted word after the '.'.
    assert_equal(
        _addr_error('a."b"@example.com'),
        P + "Obsolete: parse_addr_spec: a quoted string in a dotted local part (obsolete syntax) at position 2",
    )
    # A domain has no quoted strings, obsolete or not.
    assert_equal(
        _addr_error('a@example."com"'),
        P + "Syntax: parse_addr_spec: '.' not followed by an atom at position 9",
    )
    assert_equal(
        _addr_error("a. b@example.com"),
        P + "Obsolete: parse_addr_spec: white space or a comment after '.' (obsolete syntax) at position 2",
    )
    assert_equal(
        _mailbox_error("Mary Smith"),
        P + "Syntax: parse_mailbox: expected '@' at position 5",
    )
    assert_equal(
        _addr_error('""@example.com'),
        P + "Syntax: parse_addr_spec: an empty local part at position 0",
    )
    assert_equal(
        _list_error(""),
        P + "Syntax: parse_address_list: an empty list at position 0",
    )
    assert_equal(
        _list_error(", a@example.com"),
        P + "Obsolete: parse_address_list: an empty list element (obsolete syntax) at position 0",
    )
    assert_equal(
        _list_error("a@example.com,"),
        P + "Obsolete: parse_address_list: an empty list element (obsolete syntax) at position 14",
    )
    assert_equal(
        _list_error("A:B:c@example.com;;"),
        P + "Syntax: parse_address_list: a group where a mailbox is required at position 3",
    )
    assert_equal(
        _list_error("A:c@example.com,;"),
        P + "Obsolete: parse_address_list: an empty list element (obsolete syntax) at position 16",
    )
    assert_equal(
        _list_error("A:c@example.com"),
        P + "Syntax: parse_address_list: expected ',' or ';' at position 15",
    )
    assert_equal(
        _mailbox_list_error("A:;"),
        P + "Syntax: parse_mailbox_list: a group where a mailbox is required at position 1",
    )
    assert_equal(
        _mailbox_error("<@a.example:b@c.example>"),
        P + "Obsolete: parse_mailbox: a source route (obsolete syntax) at position 1",
    )


def test_errors_name_the_kind_and_hold_no_input() raises:
    var msg = _addr_error("secret-user@exa_mple.com")
    assert_false("secret" in msg, msg)
    assert_false("exa_mple" in msg, msg)
    try:
        _ = parse_addr_spec("x@[192.0.2.1]")
    except e:
        assert_equal(error_kind(e), "Unsupported")
    assert_equal(error_kind(Error("something else")), "")


def main() raises:
    test_cr_lf_nul_are_refused_everywhere()
    test_non_ascii_is_refused_and_a_labels_pass()
    test_one_input_one_address()
    test_rfc3696_section_3_examples()
    test_domains()
    test_length_limits()
    test_malformed()
    test_errors_name_the_kind_and_hold_no_input()
    print("test_refusals: OK")
