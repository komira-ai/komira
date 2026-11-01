# The trace headers a receiving server puts in front of a stored message
# (RFC 5321 section 4.4 and 4.1.1.4), and the escaping that keeps what a peer
# said out of the header's structure.
#
# Every piece of peer-chosen text (the EHLO name, the peer address text, the
# verified user, the sender and the recipient) goes through one of the
# functions below before it is written, so no CR, LF or other control byte and
# no unbalanced quote or comment can reach a header line.

from komira_mail_message import format_date

comptime _MAX_HELO: Int = 255
comptime _MAX_HOST: Int = 255
comptime _MAX_PEER: Int = 64
comptime _MAX_USER: Int = 64
comptime _MAX_PATH: Int = 320
comptime _QUESTION: UInt8 = 0x3F


def _is_alnum(c: UInt8) -> Bool:
    return (
        (c >= 0x30 and c <= 0x39)
        or (c >= 0x41 and c <= 0x5A)
        or (c >= 0x61 and c <= 0x7A)
    )


def _to_string(bytes: List[UInt8]) -> String:
    return String(unsafe_from_utf8=Span(bytes))


def header_token(text: String, max_len: Int) -> String:
    """`text` as a name that is safe after `from` or `by`: letters, digits and
    `. - _ : [ ]`, every other byte replaced by `?`, at most `max_len` bytes,
    `unknown` when nothing is left."""
    var bytes = text.as_bytes()
    var n = len(bytes)
    if n > max_len:
        n = max_len
    var out = List[UInt8](capacity=n)
    for i in range(n):
        var c = bytes[i]
        if (
            _is_alnum(c)
            or c == 0x2E
            or c == 0x2D
            or c == 0x5F
            or c == 0x3A
            or c == 0x5B
            or c == 0x5D
        ):
            out.append(c)
        else:
            out.append(_QUESTION)
    if len(out) == 0:
        return String("unknown")
    return _to_string(out)


def header_comment(text: String, max_len: Int) -> String:
    """`text` as the inside of a parenthesised comment: printable ASCII except
    the parentheses and the backslash, which (like every control byte and every
    byte above 0x7E) become `?`; at most `max_len` bytes."""
    var bytes = text.as_bytes()
    var n = len(bytes)
    if n > max_len:
        n = max_len
    var out = List[UInt8](capacity=n)
    for i in range(n):
        var c = bytes[i]
        if c < 0x20 or c > 0x7E or c == 0x28 or c == 0x29 or c == 0x5C:
            out.append(_QUESTION)
        else:
            out.append(c)
    return _to_string(out)


def header_quoted(text: String, max_len: Int) -> String:
    """`text` as an RFC 5322 quoted-string, quotes included: `"` and `\\` are
    escaped with a backslash, control bytes and bytes above 0x7E become `?`."""
    var bytes = text.as_bytes()
    var n = len(bytes)
    if n > max_len:
        n = max_len
    var out = List[UInt8](capacity=n + 2)
    out.append(0x22)
    for i in range(n):
        var c = bytes[i]
        if c < 0x20 or c > 0x7E:
            out.append(_QUESTION)
        elif c == 0x22 or c == 0x5C:
            out.append(0x5C)
            out.append(c)
        else:
            out.append(c)
    out.append(0x22)
    return _to_string(out)


def header_path(text: String) -> String:
    """`text` (an address as the server parsed it) made safe inside the angle
    brackets of `Return-Path: <...>` and `for <...>;`: every control byte, every
    byte above 0x7E and each of `< > ; ( ) " \\` and the space becomes `?`, so
    the path cannot close the brackets, end the clause or open a comment or a
    quote. At most 320 bytes."""
    var bytes = text.as_bytes()
    var n = len(bytes)
    if n > _MAX_PATH:
        n = _MAX_PATH
    var out = List[UInt8](capacity=n)
    for i in range(n):
        var c = bytes[i]
        if (
            c <= 0x20
            or c > 0x7E
            or c == 0x3C
            or c == 0x3E
            or c == 0x3B
            or c == 0x28
            or c == 0x29
            or c == 0x22
            or c == 0x5C
        ):
            out.append(_QUESTION)
        else:
            out.append(c)
    return _to_string(out)


def _lower_byte(c: UInt8) -> UInt8:
    if c >= 0x41 and c <= 0x5A:
        return c + 32
    return c


def _is_trace_field(line: Span[UInt8, _]) -> Bool:
    """Whether `line` starts a `Return-Path` or `Authentication-Results`
    field (any case, white space allowed before the colon)."""
    var end = 0
    while end < len(line) and line[end] != 0x3A:
        end += 1
    if end >= len(line):
        return False
    while end > 0 and (line[end - 1] == 0x20 or line[end - 1] == 0x09):
        end -= 1
    var name = String("")
    if end == 11:
        name = String("return-path")
    elif end == 22:
        name = String("authentication-results")
    else:
        return False
    var want = name.as_bytes()
    for i in range(end):
        if _lower_byte(line[i]) != want[i]:
            return False
    return True


def rename_inbound_trace_fields(message: Span[UInt8, _]) -> List[UInt8]:
    """`message` after `append_renamed_trace_fields`, as a new list."""
    var out = List[UInt8](capacity=len(message) + 32)
    append_renamed_trace_fields(out, message)
    return out^


def append_renamed_trace_fields(mut out: List[UInt8], message: Span[UInt8, _]):
    """Append `message` to `out` with every `Return-Path` and
    `Authentication-Results` field of its header renamed with an `X-Original-`
    prefix (RFC 5321 section 4.4: only the delivery agent writes Return-Path;
    RFC 8601 section 5: a border MTA must not let a sender's results pass for
    its own). The header ends at the first empty line; folded continuation
    lines stay with their field; the body is copied as it is."""
    var prefix_text = String("X-Original-")
    var prefix = prefix_text.as_bytes()
    var i = 0
    var in_head = True
    var n = len(message)
    while i < n:
        var j = i
        while j < n and message[j] != 0x0A:
            j += 1
        var stop = j + 1
        if stop > n:
            stop = n
        var line = message[i:stop]
        if in_head:
            var blank = len(line) == 2 and line[0] == 0x0D and line[1] == 0x0A
            if blank or (len(line) == 1 and line[0] == 0x0A):
                in_head = False
            elif (
                line[0] != 0x20 and line[0] != 0x09 and _is_trace_field(line)
            ):
                out.extend(prefix)
        out.extend(line)
        i = stop


def trace_date(now_ms: Int) -> String:
    """The RFC 5322 date of `now_ms` (UTC); the date of time zero when `now_ms`
    is out of range, so the header is still well formed."""
    try:
        return format_date(now_ms // 1000)
    except:
        pass
    try:
        return format_date(0)
    except:
        return String("")


def trace_headers(
    mail_from: String,
    helo: String,
    peer: String,
    authed_user: String,
    peer_tls: Bool,
    hostname: String,
    queue_id: String,
    rcpt: String,
    now_ms: Int,
) -> String:
    """The three header lines to put in front of one recipient's copy:

        Return-Path: <mail_from>
        Received: from <helo> (<peer>)
        <TAB>by <hostname> with ESMTP[S][A] id <queue id>
        <TAB>for <rcpt>; <date>
        Authentication-Results: <hostname>; none

    The protocol is ESMTP, ESMTPS after STARTTLS and ESMTPSA / ESMTPA for a
    verified user (RFC 3848); the user is then named in a comment as a quoted
    string. `queue_id` must be a token the delivery made itself. The null
    reverse-path is `<>`. The `Received` field is folded so no line is long."""
    var protocol = String("ESMTP")
    if peer_tls:
        protocol = String("ESMTPS")
    var who = String("")
    if authed_user.byte_length() > 0:
        protocol += "A"
        who = String(" (authenticated as ") + header_quoted(authed_user, _MAX_USER) + ")"
    var host = header_token(hostname, _MAX_HOST)
    var out = String("Return-Path: <") + header_path(mail_from) + ">\r\n"
    out += "Received: from " + header_token(helo, _MAX_HELO)
    out += " (" + header_comment(peer, _MAX_PEER) + ")\r\n"
    out += "\tby " + host + " with " + protocol + who
    out += " id " + header_token(queue_id, _MAX_HOST) + "\r\n"
    out += "\tfor <" + header_path(rcpt) + ">; " + trace_date(now_ms) + "\r\n"
    out += "Authentication-Results: " + host + "; none\r\n"
    return out^
