# The RFC 5321 section 4.1.2 path, both ways. `format_path` writes
# `<local@domain>` with the minimum quoting (the envelope a submission client
# sends); `parse_path` reads it back with no white space, no comment and no
# source route; `parse_reverse_path` also takes the null path `<>`.

from std.testing import assert_equal, assert_false, assert_true

from komira_mail_address import (
    AddrSpec,
    parse_addr_spec,
    parse_path,
    parse_reverse_path,
)


def _path_error(s: String) -> String:
    try:
        _ = parse_path(s)
    except e:
        return String(e)
    return String("OK")


comptime P: String = "komira_mail_address."


def test_format_path_minimum_quoting() raises:
    # (local part content, domain as given, the path written)
    assert_equal(AddrSpec("user", "Example.COM").format_path(), "<user@example.com>")
    assert_equal(AddrSpec("first.last", "example.com").format_path(), "<first.last@example.com>")
    assert_equal(AddrSpec("a b", "example.com").format_path(), '<"a b"@example.com>')
    assert_equal(AddrSpec('a"b', "example.com").format_path(), '<"a\\"b"@example.com>')
    assert_equal(AddrSpec("a\\b", "example.com").format_path(), '<"a\\\\b"@example.com>')
    assert_equal(AddrSpec(".a", "example.com").format_path(), '<".a"@example.com>')
    assert_equal(AddrSpec("a..b", "example.com").format_path(), '<"a..b"@example.com>')
    assert_equal(AddrSpec("a@b", "example.com").format_path(), '<"a@b"@example.com>')
    assert_equal(AddrSpec("user+tag", "xn--bcher-kva.example").format_path(), "<user+tag@xn--bcher-kva.example>")


def test_parse_path_round_trips() raises:
    var locals = List[String]()
    locals.append("user")
    locals.append("first.last")
    locals.append("a b")
    locals.append('a"b')
    locals.append("a\\b")
    locals.append(".a")
    locals.append("a@b,c")
    for k in range(len(locals)):
        var a = AddrSpec(locals[k], "Example.com")
        var back = parse_path(a.format_path())
        assert_true(back == a, locals[k])
        assert_equal(back.local_part(), locals[k])
        assert_equal(back.domain(), "example.com")
        # The header form and the path form agree on the address.
        assert_true(parse_addr_spec(a.format()) == a, locals[k])


def test_reverse_path() raises:
    assert_false(Bool(parse_reverse_path("<>")))
    var r = parse_reverse_path("<bounce@example.com>")
    assert_true(Bool(r))
    assert_equal(r.value().local_part(), "bounce")


def test_path_refusals() raises:
    assert_equal(_path_error("user@example.com"), P + "Syntax: parse_path: expected '<' at position 0")
    assert_equal(_path_error(""), P + "Syntax: parse_path: expected '<' at position 0")
    assert_equal(
        _path_error("<>"),
        P + "Syntax: parse_path: the null path where a mailbox is required at position 1",
    )
    assert_equal(
        _path_error("< user@example.com>"),
        P + "Syntax: parse_path: expected a local part at position 1",
    )
    assert_equal(
        _path_error("<a(c)@example.com>"),
        P + "Syntax: parse_path: expected '@' at position 2",
    )
    assert_equal(
        _path_error("<@a.example:user@b.example>"),
        P + "Obsolete: parse_path: a source route (obsolete syntax) at position 1",
    )
    assert_equal(
        _path_error("<user@example.com"),
        P + "Syntax: parse_path: expected '>' at position 17",
    )
    assert_equal(
        _path_error("<a@b.example> SIZE=10"),
        P + "Syntax: parse_path: unexpected byte after the address at position 13",
    )
    assert_equal(
        _path_error('<"a\tb"@example.com>'),
        P + "Syntax: parse_path: a control byte in the local part at position 1",
    )
    assert_equal(
        _path_error("<a@[192.0.2.1]>"),
        P + "Unsupported: parse_path: a domain literal at position 3",
    )


def main() raises:
    test_format_path_minimum_quoting()
    test_parse_path_round_trips()
    test_reverse_path()
    test_path_refusals()
    print("test_rfc5321_path: OK")
