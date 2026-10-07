# =============================================================================
# komira_mail_address/address.mojo -- the address values and their formatting.
# =============================================================================
#
# `AddrSpec` is `local-part@domain`. Its local part is held as its content:
# the quotes and the backslashes of quoted pairs are gone, so `"john"` and
# `john` are one local part (RFC 5321 section 4.1.2: all quoted forms are
# equivalent). Its case is kept: RFC 5321 lets the receiving system treat it
# as case-sensitive. The domain is held in lower case (RFC 5321 section 2.4).
# Two `AddrSpec` are equal when both fields are equal.
#
# Every constructor validates, so every value formats without error and can be
# used in an SMTP command: local part bytes 32..126 and at most 64 octets in
# its written form, domain an RFC 5321 `Domain` of at most 253 octets with
# labels of at most 63, path at most 256 octets.
#
# Formatting writes the minimum quoting: a local part is quoted only when it is
# not a `dot-atom-text`, a display name only when it is not atoms joined by
# single spaces; inside quotes only `"` and `\` are escaped. No line is folded
# and no encoded word is written: a display name is ASCII here, and RFC 2047
# encoding belongs to the message builder.
# =============================================================================

from .chars import (
    COLON,
    DOT,
    GT,
    HTAB,
    HYPHEN,
    LBRACKET,
    LT,
    SEMI,
    SP,
    AT,
    append_phrase,
    append_quoted,
    append_str,
    ascii_string,
    check_input,
    is_alpha,
    is_digit,
    is_dot_atom_text,
)
from .errors import INVALID_DOMAIN, SYNTAX, TOO_LONG, UNSUPPORTED, address_error

comptime MAX_LOCAL_PART = 64
"""RFC 5321 section 4.5.3.1.1, in the written (quoted if needed) form."""
comptime MAX_DOMAIN = 253
"""RFC 1035 section 2.3.4: 255 octets on the wire is 253 in dotted text."""
comptime MAX_LABEL = 63
"""RFC 1035 section 2.3.4."""
comptime MAX_PATH = 256
"""RFC 5321 section 4.5.3.1.3, angle brackets included."""


def _written_local_length(local: Span[UInt8, _]) -> Int:
    if is_dot_atom_text(local):
        return len(local)
    var n = len(local) + 2
    for i in range(len(local)):
        if local[i] == 34 or local[i] == 92:
            n += 1
    return n


def validate_local_part(
    local: Span[UInt8, _], function: StaticString, position: Int
) raises:
    """Refuse an empty local part, a byte outside 32..126 (tab included: RFC
    5321 has no tab in a local part), or one over 64 octets written. Errors
    name `position`, the start of the local part."""
    if len(local) == 0:
        raise address_error(SYNTAX, function, "an empty local part", position)
    for i in range(len(local)):
        var c = local[i]
        if c < 32 or c > 126:
            raise address_error(
                SYNTAX, function, "a control byte in the local part", position
            )
    if _written_local_length(local) > MAX_LOCAL_PART:
        raise address_error(
            TOO_LONG, function, "a local part longer than 64 octets", position
        )


def normalize_domain(
    domain: Span[UInt8, _], function: StaticString, position: Int
) raises -> List[UInt8]:
    """`domain` in lower case, after checking it is an RFC 5321 `Domain`:
    labels of letters, digits and `-`, none empty, none starting or ending
    with `-`. `position` is where `domain` starts in the caller's input."""
    var n = len(domain)
    if n > 0 and domain[0] == LBRACKET:
        raise address_error(UNSUPPORTED, function, "a domain literal", position)
    var out = List[UInt8](capacity=n)
    var label_start = 0
    for i in range(n + 1):
        if i == n or domain[i] == DOT:
            var length = i - label_start
            if length == 0:
                raise address_error(
                    INVALID_DOMAIN,
                    function,
                    "an empty domain label",
                    position + label_start,
                )
            if domain[label_start] == HYPHEN:
                raise address_error(
                    INVALID_DOMAIN,
                    function,
                    "a domain label starting or ending with '-'",
                    position + label_start,
                )
            if domain[i - 1] == HYPHEN:
                raise address_error(
                    INVALID_DOMAIN,
                    function,
                    "a domain label starting or ending with '-'",
                    position + i - 1,
                )
            if length > MAX_LABEL:
                raise address_error(
                    TOO_LONG,
                    function,
                    "a domain label longer than 63 octets",
                    position + label_start,
                )
            if i < n:
                out.append(DOT)
            label_start = i + 1
            continue
        var c = domain[i]
        if is_alpha(c):
            out.append(c | 0x20)
        elif is_digit(c) or c == HYPHEN:
            out.append(c)
        else:
            raise address_error(
                INVALID_DOMAIN,
                function,
                "a byte other than a letter, digit or '-' in a domain label",
                position + i,
            )
    if n > MAX_DOMAIN:
        raise address_error(
            TOO_LONG, function, "a domain longer than 253 octets", position
        )
    return out^


def check_path_length(
    local: Span[UInt8, _], domain_length: Int, function: StaticString, position: Int
) raises:
    """Refuse an address whose path `<local@domain>` is over 256 octets."""
    if 3 + _written_local_length(local) + domain_length > MAX_PATH:
        raise address_error(
            TOO_LONG, function, "a path longer than 256 octets", position
        )


struct AddrSpec(Copyable, Equatable, Movable):
    """`local-part@domain`; see the module header for what it holds."""

    var _local: String
    var _domain: String

    def __init__(out self, local_part: String, domain: String) raises:
        """An address from its local part content (unquoted: `a b` for
        `"a b"`) and its domain. Raises a named error for anything that
        could not be written in a header or an SMTP command; positions are in
        the argument at fault."""
        check_input(local_part.as_bytes(), "AddrSpec")
        check_input(domain.as_bytes(), "AddrSpec")
        validate_local_part(local_part.as_bytes(), "AddrSpec", 0)
        var d = normalize_domain(domain.as_bytes(), "AddrSpec", 0)
        check_path_length(local_part.as_bytes(), len(d), "AddrSpec", 0)
        self._local = local_part
        self._domain = ascii_string(d)

    def local_part(self) -> String:
        """The local part's content, case kept, without quotes."""
        return self._local

    def domain(self) -> String:
        """The domain, in lower case."""
        return self._domain

    def __eq__(self, other: Self) -> Bool:
        return self._local == other._local and self._domain == other._domain

    def __ne__(self, other: Self) -> Bool:
        return not self == other

    def append_to(self, mut out: List[UInt8]):
        """Append the RFC 5322 `addr-spec` form, minimum quoting."""
        var local = self._local.as_bytes()
        if is_dot_atom_text(local):
            for i in range(len(local)):
                out.append(local[i])
        else:
            append_quoted(out, local)
        out.append(AT)
        var d = self._domain.as_bytes()
        for i in range(len(d)):
            out.append(d[i])

    def format(self) -> String:
        """`local@domain`, the local part quoted only when it must be."""
        var out = List[UInt8]()
        self.append_to(out)
        return ascii_string(out)

    def format_path(self) -> String:
        """The RFC 5321 path `<local@domain>`, for `MAIL FROM:` and
        `RCPT TO:`."""
        var out = List[UInt8]()
        out.append(LT)
        self.append_to(out)
        out.append(GT)
        return ascii_string(out)


def _validate_phrase(
    s: Span[UInt8, _], function: StaticString, what: StaticString
) raises:
    check_input(s, function)
    for i in range(len(s)):
        var c = s[i]
        if c != HTAB and (c < 32 or c > 126):
            raise address_error(SYNTAX, function, what, i)


struct Mailbox(Copyable, Movable):
    """A display name (possibly empty) and an `AddrSpec`."""

    var _display_name: String
    var _addr: AddrSpec

    def __init__(out self, addr: AddrSpec):
        """A mailbox with no display name."""
        self._display_name = String("")
        self._addr = addr.copy()

    def __init__(out self, display_name: String, addr: AddrSpec) raises:
        """A mailbox with a display name: ASCII, tab and 32..126 only (an
        encoded word is passed in as its ASCII text)."""
        _validate_phrase(
            display_name.as_bytes(),
            "Mailbox",
            "a control byte in the display name",
        )
        self._display_name = display_name
        self._addr = addr.copy()

    def display_name(self) -> String:
        """The display name as decoded: the quotes and quoted-pair
        backslashes removed, comments dropped, words joined by one space."""
        return self._display_name

    def addr_spec(self) -> AddrSpec:
        return self._addr.copy()

    def append_to(self, mut out: List[UInt8]):
        var name = self._display_name.as_bytes()
        if len(name) == 0:
            self._addr.append_to(out)
            return
        append_phrase(out, name)
        out.append(SP)
        out.append(LT)
        self._addr.append_to(out)
        out.append(GT)

    def format(self) -> String:
        """`addr` without a display name, else `name <addr>`."""
        var out = List[UInt8]()
        self.append_to(out)
        return ascii_string(out)


struct Group(Copyable, Movable):
    """An RFC 5322 group: a name and zero or more mailboxes."""

    var _name: String
    var _members: List[Mailbox]

    def __init__(out self, name: String, members: List[Mailbox]) raises:
        """A group; its name is not empty and follows the display name
        rules."""
        if name.byte_length() == 0:
            raise address_error(SYNTAX, "Group", "an empty group name", 0)
        _validate_phrase(
            name.as_bytes(), "Group", "a control byte in the group name"
        )
        self._name = name
        self._members = members.copy()

    def name(self) -> String:
        return self._name

    def members(self) -> List[Mailbox]:
        return self._members.copy()

    def append_to(self, mut out: List[UInt8]):
        append_phrase(out, self._name.as_bytes())
        out.append(COLON)
        for i in range(len(self._members)):
            if i > 0:
                append_str(out, ", ")
            self._members[i].append_to(out)
        out.append(SEMI)

    def format(self) -> String:
        """`name:m1, m2;`, or `name:;` for an empty group."""
        var out = List[UInt8]()
        self.append_to(out)
        return ascii_string(out)


struct Address(Copyable, Movable):
    """One element of an RFC 5322 `address-list`: a mailbox or a group."""

    var _mailbox: Optional[Mailbox]
    var _group: Optional[Group]

    def __init__(out self, mailbox: Mailbox):
        self._mailbox = Optional[Mailbox](mailbox.copy())
        self._group = None

    def __init__(out self, group: Group):
        self._mailbox = None
        self._group = Optional[Group](group.copy())

    def is_group(self) -> Bool:
        if self._group:
            return True
        return False

    def mailbox(self) raises -> Mailbox:
        """The mailbox; raises (an unnamed error: a caller bug, not bad
        input) when this is a group."""
        if not self._mailbox:
            raise Error("komira_mail_address: Address.mailbox: a group")
        return self._mailbox.value().copy()

    def group(self) raises -> Group:
        """The group; raises when this is a mailbox."""
        if not self._group:
            raise Error("komira_mail_address: Address.group: a mailbox")
        return self._group.value().copy()

    def mailboxes(self) -> List[Mailbox]:
        """This mailbox, or the group's members."""
        if self._group:
            return self._group.value().members()
        var out = List[Mailbox]()
        out.append(self._mailbox.value().copy())
        return out^

    def append_to(self, mut out: List[UInt8]):
        if self._group:
            self._group.value().append_to(out)
        else:
            self._mailbox.value().append_to(out)

    def format(self) -> String:
        var out = List[UInt8]()
        self.append_to(out)
        return ascii_string(out)


def format_mailbox_list(mailboxes: List[Mailbox]) -> String:
    """The mailboxes joined by `, `, unfolded."""
    var out = List[UInt8]()
    for i in range(len(mailboxes)):
        if i > 0:
            append_str(out, ", ")
        mailboxes[i].append_to(out)
    return ascii_string(out)


def format_address_list(addresses: List[Address]) -> String:
    """The addresses joined by `, `, unfolded."""
    var out = List[UInt8]()
    for i in range(len(addresses)):
        if i > 0:
            append_str(out, ", ")
        addresses[i].append_to(out)
    return ascii_string(out)
