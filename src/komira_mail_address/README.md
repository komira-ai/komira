# komira_mail_address

Email addresses for software that sends mail: one grammar for header fields
(RFC 5322 section 3.4: `addr-spec`, `name-addr`, groups, quoted strings and
comments) and for SMTP paths (RFC 5321 section 4.1.2), parsing, formatting
and normalization. No dependencies beyond the Mojo standard library.

Every example below runs as a test when the package is built.

## Parse a header field, write the envelope

```mojo
from komira_mail_address import parse_address_list, parse_mailbox
from std.testing import assert_equal

var to = parse_address_list('Mary Smith <mary@x.test>, "Giant; \\"Big\\" Box" <sysservices@Example.NET>')
assert_equal(len(to), 2)
var giant = to[1].mailbox()
assert_equal(giant.display_name(), 'Giant; "Big" Box')
assert_equal(giant.addr_spec().domain(), "example.net")  # domains are lower-cased
assert_equal(giant.addr_spec().format_path(), "<sysservices@example.net>")  # for RCPT TO:

var sender = parse_mailbox("Pete(A nice \\) chap) <pete(his account)@silly.test(his host)>")
assert_equal(sender.format(), "Pete <pete@silly.test>")  # comments are dropped
```

## Build addresses and format them

Constructors validate, so every value can be written into a header or an SMTP
command. Formatting uses the minimum quoting.

```mojo
from komira_mail_address import AddrSpec, Mailbox
from std.testing import assert_equal

var from_ = Mailbox("Acme Support", AddrSpec("support", "Acme.Example"))
assert_equal(from_.format(), "Acme Support <support@acme.example>")
assert_equal(Mailbox("Doe, Jane", AddrSpec("jane", "example.com")).format(), '"Doe, Jane" <jane@example.com>')
assert_equal(AddrSpec("a b", "example.com").format_path(), '<"a b"@example.com>')
```

## What is refused

CR, LF and NUL anywhere (a header or command injection), bytes above 0x7F
(SMTPUTF8 and IDNA are not supported: give a domain in its `xn--` form),
domain literals, a domain that is not letters, digits and `-` labels, the RFC
5321 length limits, and RFC 5322's obsolete forms except a `.` in an unquoted
display name. Every error names its kind and a byte position and holds no
input byte.

```mojo
from komira_mail_address import parse_addr_spec, error_kind
from std.testing import assert_equal

var msg = String("")
try:
    _ = parse_addr_spec("a@b@acme.example")
except e:
    msg = String(e)
    assert_equal(error_kind(e), "Syntax")
assert_equal(msg, "komira_mail_address.Syntax: parse_addr_spec: unexpected byte after the address at position 3")

# A quoted local part holding `@` and `,` is one address, never two.
var one = parse_addr_spec('"x@victim.example,y"@acme.example')
assert_equal(one.local_part(), "x@victim.example,y")
assert_equal(one.domain(), "acme.example")
```

## Limits

- The input is an unfolded field body: the message parser removes the line
  folds first. Nothing here folds a long line or encodes a non-ASCII display
  name (RFC 2047); an encoded word passes through as its ASCII text.
- Local parts are compared exactly (RFC 5321 lets a receiving system treat
  them as case-sensitive); whether to compare them without case is the
  caller's decision.
