"""Email addresses: one grammar for headers (RFC 5322 section 3.4) and SMTP
paths (RFC 5321 section 4.1.2), parsing, formatting and normalization.

| function | input | result |
|---|---|---|
| `parse_addr_spec` | `local@domain` | `AddrSpec` |
| `parse_mailbox` | a `Sender:` value: `addr-spec` or `[name] <addr-spec>` | `Mailbox` |
| `parse_mailbox_list` | a `From:` value | `List[Mailbox]` |
| `parse_address_list` | a `To:` / `Cc:` value, groups included | `List[Address]` |
| `parse_path` | `<local@domain>` | `AddrSpec` |
| `parse_reverse_path` | `<local@domain>` or `<>` | `Optional[AddrSpec]` |

Each parser takes a `String` or the bytes (`Span[UInt8]`) of an unfolded
header field body or SMTP path. CR, LF and NUL are refused anywhere, so no
value of this package can carry a line break into a header or a command.
Bytes above 0x7F are refused: SMTPUTF8 (RFC 6531) and IDNA are not supported,
and a domain must be written in its A-label (`xn--`) form. Of RFC 5322's
obsolete forms only a `.` in an unquoted display name is accepted; source
routes, empty list elements and white space around dots are refused, and
domain literals are not supported. See `parse.mojo`.

Values: `AddrSpec` keeps the local part's content and case and the domain in
lower case; `Mailbox` adds a decoded display name; `Group` is a name and
mailboxes; `Address` is one of the two. Constructors validate, and
`format()` writes the minimum quoting (`format_path()` the SMTP path), so
`parse(format(x)) == x`.

Errors are named: the message starts `komira_mail_address.<Kind>: <function>:`
and ends `at position <n>`, and never holds input bytes (`errors.mojo`;
`error_kind` reads the kind).
"""

from .address import (
    AddrSpec,
    Address,
    Group,
    Mailbox,
    format_address_list,
    format_mailbox_list,
)
from .errors import error_kind
from .parse import (
    parse_addr_spec,
    parse_address_list,
    parse_mailbox,
    parse_mailbox_list,
    parse_path,
    parse_reverse_path,
)
