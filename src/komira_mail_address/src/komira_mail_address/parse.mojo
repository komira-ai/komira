# =============================================================================
# komira_mail_address/parse.mojo -- the RFC 5322 and RFC 5321 address parsers.
# =============================================================================
#
# One grammar for every entry point, so a header and an SMTP command cannot
# disagree about where an address ends.
#
# Input. An unfolded header field body (RFC 5322 section 2.2.3: unfolding
# removes each CRLF that is followed by white space) or an SMTP path. CR, LF
# and NUL are refused anywhere, and so is any byte above 0x7F; see
# `chars.check_input`.
#
# RFC 5322 (header) entry points accept section 3.4: `addr-spec`, `name-addr`
# with a `display-name`, groups, quoted strings, quoted pairs, and comments
# (nested) and white space wherever CFWS is allowed. Of the section 4
# obsolete forms they accept only `obs-phrase` (a `.` in an unquoted display
# name, as in `Joe Q. Public`), which cannot change where mail goes. Source
# routes, empty list elements, CFWS around a `.` of a local part or domain,
# and a dotted local part holding a quoted string (before or after a `.`) are
# refused as `Obsolete`.
#
# RFC 5321 (path) entry points accept `<Local-part@Domain>` with no white
# space or comment, and `<>` where a reverse path is asked for. A source
# route is refused as `Obsolete`. In both grammars a domain literal is
# refused as `Unsupported`, and the domain must be an RFC 5321 `Domain`.
#
# A comment is skipped; a display name is decoded to its content (quotes and
# quoted-pair backslashes removed; one space wherever CFWS separated two of its
# words). Encoded words (RFC 2047) are left as they are.
# =============================================================================

from .address import (
    AddrSpec,
    Address,
    Group,
    Mailbox,
    check_path_length,
    normalize_domain,
    validate_local_part,
)
from .chars import (
    AT,
    BACKSLASH,
    COLON,
    COMMA,
    DOT,
    DQUOTE,
    GT,
    LBRACKET,
    LPAREN,
    LT,
    RPAREN,
    SEMI,
    ascii_string,
    check_input,
    is_atext,
    is_qtext,
    is_vchar,
    is_wsp,
)
from .errors import OBSOLETE, SYNTAX, UNSUPPORTED, address_error


def _skip_comment(
    data: Span[UInt8, _], mut i: Int, function: StaticString
) raises:
    """Skip the comment at `data[i] == '('`, nested comments included."""
    var start = i
    var depth = 0
    var n = len(data)
    while i < n:
        var c = data[i]
        if c == LPAREN:
            depth += 1
            i += 1
        elif c == RPAREN:
            depth -= 1
            i += 1
            if depth == 0:
                return
        elif c == BACKSLASH:
            if i + 1 < n and (is_vchar(data[i + 1]) or is_wsp(data[i + 1])):
                i += 2
            else:
                raise address_error(SYNTAX, function, "an invalid quoted pair", i)
        elif is_vchar(c) or is_wsp(c):
            i += 1
        else:
            raise address_error(SYNTAX, function, "a control byte in a comment", i)
    raise address_error(SYNTAX, function, "an unterminated comment", start)


def _skip_cfws(
    data: Span[UInt8, _], mut i: Int, function: StaticString
) raises -> Bool:
    """Skip white space and comments; True when anything was skipped."""
    var start = i
    while i < len(data):
        var c = data[i]
        if is_wsp(c):
            i += 1
        elif c == LPAREN:
            _skip_comment(data, i, function)
        else:
            break
    return i > start


def _read_quoted(
    data: Span[UInt8, _], mut i: Int, function: StaticString, mut out: List[UInt8]
) raises:
    """Append the content of the quoted string at `data[i] == '"'`."""
    var start = i
    var n = len(data)
    i += 1
    while i < n:
        var c = data[i]
        if c == DQUOTE:
            i += 1
            return
        if c == BACKSLASH:
            if i + 1 < n and (is_vchar(data[i + 1]) or is_wsp(data[i + 1])):
                out.append(data[i + 1])
                i += 2
                continue
            raise address_error(SYNTAX, function, "an invalid quoted pair", i)
        if is_qtext(c) or is_wsp(c):
            out.append(c)
            i += 1
            continue
        raise address_error(
            SYNTAX, function, "a control byte in a quoted string", i
        )
    raise address_error(SYNTAX, function, "an unterminated quoted string", start)


def _read_dot_atom_text(
    data: Span[UInt8, _],
    mut i: Int,
    function: StaticString,
    missing: StaticString,
    local_part: Bool,
    mut out: List[UInt8],
) raises:
    """Append the `dot-atom-text` at `i`. A `.` followed by white space or
    a comment is the obsolete form, and so, in a local part (`local_part`
    True), is a `.` followed by a quoted string; a `.` followed by anything
    else that is not an atom is a syntax error."""
    var n = len(data)
    if i >= n or not is_atext(data[i]):
        raise address_error(SYNTAX, function, missing, i)
    while i < n:
        var c = data[i]
        if is_atext(c):
            out.append(c)
            i += 1
        elif c == DOT:
            if i + 1 < n and is_atext(data[i + 1]):
                out.append(c)
                i += 1
            elif i + 1 < n and (is_wsp(data[i + 1]) or data[i + 1] == LPAREN):
                raise address_error(
                    OBSOLETE,
                    function,
                    "white space or a comment after '.' (obsolete syntax)",
                    i + 1,
                )
            elif local_part and i + 1 < n and data[i + 1] == DQUOTE:
                raise address_error(
                    OBSOLETE,
                    function,
                    "a quoted string in a dotted local part (obsolete syntax)",
                    i + 1,
                )
            else:
                raise address_error(
                    SYNTAX, function, "'.' not followed by an atom", i
                )
        else:
            return


def _parse_addr_spec_at(
    data: Span[UInt8, _], mut i: Int, function: StaticString, cfws: Bool
) raises -> AddrSpec:
    """The `addr-spec` (RFC 5322, `cfws` True) or `Mailbox` (RFC 5321) at
    `i`; leaves `i` after it and, with `cfws`, after the CFWS that follows."""
    var n = len(data)
    if cfws:
        _ = _skip_cfws(data, i, function)
    var local_start = i
    var local = List[UInt8]()
    if i < n and data[i] == DQUOTE:
        _read_quoted(data, i, function, local)
        if i < n and data[i] == DOT:
            raise address_error(
                OBSOLETE,
                function,
                "a quoted string in a dotted local part (obsolete syntax)",
                i,
            )
    else:
        _read_dot_atom_text(
            data, i, function, "expected a local part", True, local
        )
    if cfws:
        if _skip_cfws(data, i, function) and i < n and data[i] == DOT:
            raise address_error(
                OBSOLETE,
                function,
                "white space or a comment before '.' (obsolete syntax)",
                i,
            )
    if i >= n or data[i] != AT:
        raise address_error(SYNTAX, function, "expected '@'", i)
    i += 1
    if cfws:
        _ = _skip_cfws(data, i, function)
    var domain_start = i
    if i < n and data[i] == LBRACKET:
        raise address_error(UNSUPPORTED, function, "a domain literal", i)
    var domain = List[UInt8]()
    _read_dot_atom_text(
        data, i, function, "expected a domain", False, domain
    )
    if cfws:
        if _skip_cfws(data, i, function) and i < n and data[i] == DOT:
            raise address_error(
                OBSOLETE,
                function,
                "white space or a comment before '.' (obsolete syntax)",
                i,
            )
    validate_local_part(Span(local), function, local_start)
    var normalized = normalize_domain(Span(domain), function, domain_start)
    check_path_length(Span(local), len(normalized), function, local_start)
    return AddrSpec(ascii_string(local), ascii_string(normalized))


def _read_phrase(
    data: Span[UInt8, _], mut i: Int, function: StaticString, mut out: List[UInt8]
) raises -> Int:
    """Append the decoded `phrase` (or `obs-phrase`) at `i`, after skipping
    leading CFWS; returns the number of words read (0: no phrase)."""
    var words = 0
    var any = False
    var n = len(data)
    while True:
        var skipped = _skip_cfws(data, i, function)
        if i >= n:
            break
        var c = data[i]
        var is_word = is_atext(c) or c == DQUOTE
        if not is_word and not (c == DOT and words > 0):
            break
        if skipped and any:
            out.append(32)
        if c == DQUOTE:
            _read_quoted(data, i, function, out)
            words += 1
        elif c == DOT:
            out.append(c)
            i += 1
        else:
            while i < n and is_atext(data[i]):
                out.append(data[i])
                i += 1
            words += 1
        any = True
    return words


def _parse_mailbox_at(
    data: Span[UInt8, _], mut i: Int, function: StaticString, allow_group: Bool
) raises -> Address:
    """The `mailbox` (or, with `allow_group`, `group`) at `i`."""
    var start = i
    var n = len(data)
    var name = List[UInt8]()
    var words = _read_phrase(data, i, function, name)
    if i < n and data[i] == LT:
        i += 1
        _ = _skip_cfws(data, i, function)
        if i < n and data[i] == AT:
            raise address_error(
                OBSOLETE, function, "a source route (obsolete syntax)", i
            )
        var addr = _parse_addr_spec_at(data, i, function, True)
        if i >= n or data[i] != GT:
            raise address_error(SYNTAX, function, "expected '>'", i)
        i += 1
        _ = _skip_cfws(data, i, function)
        if words == 0:
            return Address(Mailbox(addr))
        return Address(Mailbox(ascii_string(name), addr))
    if i < n and data[i] == COLON and words > 0:
        if not allow_group:
            raise address_error(SYNTAX, function, "a group where a mailbox is required", i)
        i += 1
        var members = List[Mailbox]()
        _ = _skip_cfws(data, i, function)
        if i < n and data[i] == COMMA:
            raise address_error(
                OBSOLETE, function, "an empty list element (obsolete syntax)", i
            )
        if i >= n or data[i] != SEMI:
            while True:
                members.append(
                    _parse_mailbox_at(data, i, function, False).mailbox()
                )
                if i < n and data[i] == COMMA:
                    i += 1
                    _ = _skip_cfws(data, i, function)
                    if i >= n or data[i] == COMMA or data[i] == SEMI:
                        raise address_error(
                            OBSOLETE,
                            function,
                            "an empty list element (obsolete syntax)",
                            i,
                        )
                    continue
                break
        if i >= n or data[i] != SEMI:
            raise address_error(SYNTAX, function, "expected ',' or ';'", i)
        i += 1
        _ = _skip_cfws(data, i, function)
        return Address(Group(ascii_string(name), members))
    i = start
    return Address(Mailbox(_parse_addr_spec_at(data, i, function, True)))


def _parse_list(
    data: Span[UInt8, _], function: StaticString, allow_group: Bool
) raises -> List[Address]:
    check_input(data, function)
    var n = len(data)
    var i = 0
    var out = List[Address]()
    _ = _skip_cfws(data, i, function)
    if i >= n:
        raise address_error(SYNTAX, function, "an empty list", i)
    if data[i] == COMMA:
        raise address_error(
            OBSOLETE, function, "an empty list element (obsolete syntax)", i
        )
    while True:
        out.append(_parse_mailbox_at(data, i, function, allow_group))
        if i >= n:
            break
        if data[i] != COMMA:
            raise address_error(
                SYNTAX, function, "unexpected byte after the address", i
            )
        i += 1
        _ = _skip_cfws(data, i, function)
        if i >= n or data[i] == COMMA:
            raise address_error(
                OBSOLETE, function, "an empty list element (obsolete syntax)", i
            )
    return out^


def _expect_end(data: Span[UInt8, _], i: Int, function: StaticString) raises:
    if i < len(data):
        raise address_error(
            SYNTAX, function, "unexpected byte after the address", i
        )


# --- RFC 5322 ----------------------------------------------------------------


def parse_addr_spec(data: Span[UInt8, _]) raises -> AddrSpec:
    """One RFC 5322 `addr-spec` (`local@domain`), CFWS allowed around it and
    its parts, nothing else."""
    check_input(data, "parse_addr_spec")
    var i = 0
    var a = _parse_addr_spec_at(data, i, "parse_addr_spec", True)
    _expect_end(data, i, "parse_addr_spec")
    return a^


def parse_addr_spec(text: String) raises -> AddrSpec:
    """`parse_addr_spec` over the bytes of `text`."""
    return parse_addr_spec(text.as_bytes())


def parse_mailbox(data: Span[UInt8, _]) raises -> Mailbox:
    """One RFC 5322 `mailbox` (`addr-spec` or `[name] <addr-spec>`), as in a
    `Sender:` field."""
    check_input(data, "parse_mailbox")
    var i = 0
    var a = _parse_mailbox_at(data, i, "parse_mailbox", False)
    _expect_end(data, i, "parse_mailbox")
    return a.mailbox()


def parse_mailbox(text: String) raises -> Mailbox:
    """`parse_mailbox` over the bytes of `text`."""
    return parse_mailbox(text.as_bytes())


def parse_mailbox_list(data: Span[UInt8, _]) raises -> List[Mailbox]:
    """An RFC 5322 `mailbox-list`, as in a `From:` field: one or more
    mailboxes, no groups."""
    var list = _parse_list(data, "parse_mailbox_list", False)
    var out = List[Mailbox](capacity=len(list))
    for k in range(len(list)):
        out.append(list[k].mailbox())
    return out^


def parse_mailbox_list(text: String) raises -> List[Mailbox]:
    """`parse_mailbox_list` over the bytes of `text`."""
    return parse_mailbox_list(text.as_bytes())


def parse_address_list(data: Span[UInt8, _]) raises -> List[Address]:
    """An RFC 5322 `address-list`, as in `To:` and `Cc:`: one or more
    mailboxes and groups. A group holds mailboxes, never another group."""
    return _parse_list(data, "parse_address_list", True)


def parse_address_list(text: String) raises -> List[Address]:
    """`parse_address_list` over the bytes of `text`."""
    return parse_address_list(text.as_bytes())


# --- RFC 5321 ----------------------------------------------------------------


def parse_path(data: Span[UInt8, _]) raises -> AddrSpec:
    """An RFC 5321 `Path`, `<local@domain>`: no white space, no comment, no
    source route. `<>` is refused; see `parse_reverse_path`."""
    check_input(data, "parse_path")
    var n = len(data)
    var i = 0
    if n == 0 or data[0] != LT:
        raise address_error(SYNTAX, "parse_path", "expected '<'", 0)
    i = 1
    if i < n and data[i] == GT:
        raise address_error(
            SYNTAX, "parse_path", "the null path where a mailbox is required", i
        )
    if i < n and data[i] == AT:
        raise address_error(
            OBSOLETE, "parse_path", "a source route (obsolete syntax)", i
        )
    var a = _parse_addr_spec_at(data, i, "parse_path", False)
    if i >= n or data[i] != GT:
        raise address_error(SYNTAX, "parse_path", "expected '>'", i)
    i += 1
    _expect_end(data, i, "parse_path")
    return a^


def parse_path(text: String) raises -> AddrSpec:
    """`parse_path` over the bytes of `text`."""
    return parse_path(text.as_bytes())


def parse_reverse_path(data: Span[UInt8, _]) raises -> Optional[AddrSpec]:
    """An RFC 5321 `Reverse-path`: None for the null path `<>`, else as
    `parse_path`."""
    if len(data) == 2 and data[0] == LT and data[1] == GT:
        return None
    return Optional[AddrSpec](parse_path(data))


def parse_reverse_path(text: String) raises -> Optional[AddrSpec]:
    """`parse_reverse_path` over the bytes of `text`."""
    return parse_reverse_path(text.as_bytes())
