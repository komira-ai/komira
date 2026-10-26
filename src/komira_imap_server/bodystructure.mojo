# ENVELOPE, BODYSTRUCTURE and BODY (RFC 3501 sections 7.4.2 and 9) written
# from a message's header block and from a `komira_mail_message.Message`.
#
# ENVELOPE (`envelope_bytes`). Reads only the header block, with the lenient
# scanner of headers.mojo, so it works on mail a MIME parse would refuse.
# - date, subject, in-reply-to and message-id are the field values as written
#   (unfolded, RFC 2047 encoded words not decoded: a client decodes them, and
#   the structure must carry what the sender wrote), NIL when the field is
#   absent and `""` when it is empty. The first field of each name is used.
# - from, sender, reply-to, to, cc and bcc are `komira_mail_address`
#   address lists: each mailbox is `(name NIL mailbox host)` (the host in
#   lower case, as that package keeps it), a group is its start
#   `(NIL NIL "name" NIL)`, its members, and its end `(NIL NIL NIL NIL)`.
#   An absent field is NIL, and so is one that does not parse (a list the
#   package refuses is not guessed at). sender and reply-to default to from
#   when absent (RFC 3501 section 7.4.2).
#
# BODYSTRUCTURE and BODY (`body_structure_bytes`). Written from the parts of
# `Message`: a multipart is `(part part ... "SUBTYPE" ...)`, a leaf is
# `("TYPE" "SUBTYPE" params id description "ENCODING" octets [lines])`, with
# the lines of a text part, and for `message/rfc822` the nested message's
# envelope, its structure and the lines. The extension data of the extensible
# form is the parameters of a multipart; for a leaf md5 (Content-MD5), the
# disposition, the language (Content-Language) and the location
# (Content-Location). BODY is the form without extension data. A text part
# with no Content-Type has the parameters `("CHARSET" "US-ASCII")`
# (RFC 3501 section 7.4.2's example). A nested message is opened with
# `Message.open_rfc822`, under the parent's shared depth and part budget; if
# that, or a part of it, raises, the caller answers `NO [UNAVAILABLE]`.

from komira_mail_address import Address, parse_address_list
from komira_mail_message import Message, parse_media_header

from .headers import HdrField, find_field, scan_fields
from .imapstr import (
    append_nil,
    append_nstring,
    append_number,
    append_string,
    append_text,
    append_upper_string,
)


def _ext(mut out: List[UInt8], v: List[UInt8]):
    out.extend(Span(v))


def _value(fields: List[HdrField], name: String) -> Optional[List[UInt8]]:
    var at = find_field(fields, name)
    if at < 0:
        return None
    return Optional[List[UInt8]](fields[at].value.copy())


def _append_opt_text(mut out: List[UInt8], text: String):
    if text.byte_length() == 0:
        append_nil(out)
    else:
        append_string(out, text.as_bytes())


def _append_mailbox(
    mut out: List[UInt8], name: String, local: String, domain: String
):
    out.append(0x28)
    _append_opt_text(out, name)
    out.extend(String(" NIL ").as_bytes())
    _append_opt_text(out, local)
    out.append(0x20)
    _append_opt_text(out, domain)
    out.append(0x29)


def _append_address(mut out: List[UInt8], a: Address):
    # Built aside and appended whole, so a failure part-way leaves `out` as it
    # was.
    var piece = List[UInt8]()
    try:
        if a.is_group():
            var g = a.group()
            piece.extend(String("(NIL NIL ").as_bytes())
            append_string(piece, g.name().as_bytes())
            piece.extend(String(" NIL)").as_bytes())
            var members = g.members()
            for i in range(len(members)):
                _append_mailbox(
                    piece,
                    members[i].display_name(),
                    members[i].addr_spec().local_part(),
                    members[i].addr_spec().domain(),
                )
            piece.extend(String("(NIL NIL NIL NIL)").as_bytes())
        else:
            var m = a.mailbox()
            _append_mailbox(
                piece,
                m.display_name(),
                m.addr_spec().local_part(),
                m.addr_spec().domain(),
            )
    except:
        return
    out.extend(Span(piece))


def _address_field(value: Optional[List[UInt8]]) -> List[UInt8]:
    """An address-list field of the envelope, or NIL."""
    var out = List[UInt8]()
    if not value:
        append_nil(out)
        return out^
    var list = List[Address]()
    try:
        list = parse_address_list(Span(value.value()))
    except:
        append_nil(out)
        return out^
    if len(list) == 0:
        append_nil(out)
        return out^
    out.append(0x28)
    for i in range(len(list)):
        _append_address(out, list[i])
    out.append(0x29)
    return out^


def envelope_bytes(data: Span[UInt8, _]) -> List[UInt8]:
    """The ENVELOPE structure of the message (or header block) `data`."""
    var fields = scan_fields(data)
    var out = List[UInt8]()
    out.append(0x28)
    append_nstring(out, _value(fields, String("date")))
    out.append(0x20)
    append_nstring(out, _value(fields, String("subject")))
    out.append(0x20)
    var from_field = _value(fields, String("from"))
    var from_text = _address_field(from_field)
    _ext(out, from_text)
    out.append(0x20)
    var sender = _value(fields, String("sender"))
    if sender:
        _ext(out, _address_field(sender))
    else:
        _ext(out, from_text)
    out.append(0x20)
    var reply_to = _value(fields, String("reply-to"))
    if reply_to:
        _ext(out, _address_field(reply_to))
    else:
        _ext(out, from_text)
    out.append(0x20)
    _ext(out, _address_field(_value(fields, String("to"))))
    out.append(0x20)
    _ext(out, _address_field(_value(fields, String("cc"))))
    out.append(0x20)
    _ext(out, _address_field(_value(fields, String("bcc"))))
    out.append(0x20)
    append_nstring(out, _value(fields, String("in-reply-to")))
    out.append(0x20)
    append_nstring(out, _value(fields, String("message-id")))
    out.append(0x29)
    return out^


# ---- BODYSTRUCTURE ---------------------------------------------------------


def _append_params(mut out: List[UInt8], header: Optional[List[UInt8]], default_charset: Bool):
    """A parameter list `("NAME" "value" ...)`, NIL when there is none. With
    `default_charset` and no header at all, the charset of plain US-ASCII
    text."""
    if not header:
        if default_charset:
            out.extend(String('("CHARSET" "US-ASCII")').as_bytes())
        else:
            append_nil(out)
        return
    try:
        var media = parse_media_header(Span(header.value()))
        var params = media.params()
        if len(params) == 0:
            append_nil(out)
            return
        out.append(0x28)
        for i in range(len(params)):
            if i > 0:
                out.append(0x20)
            append_upper_string(out, params[i].name.as_bytes())
            out.append(0x20)
            append_string(out, params[i].value.as_bytes())
        out.append(0x29)
    except:
        append_nil(out)


def _append_disposition(mut out: List[UInt8], header: Optional[List[UInt8]]):
    if not header:
        append_nil(out)
        return
    try:
        var media = parse_media_header(Span(header.value()))
        if media.value().byte_length() == 0:
            append_nil(out)
            return
        out.append(0x28)
        append_upper_string(out, media.value().as_bytes())
        out.append(0x20)
        _append_params(out, header, False)
        out.append(0x29)
    except:
        append_nil(out)


def _append_language(mut out: List[UInt8], header: Optional[List[UInt8]]):
    """`("en" "de")` from a Content-Language value; NIL when absent or
    empty."""
    if not header:
        append_nil(out)
        return
    var v = header.value().copy()
    var tags = List[List[UInt8]]()
    var cur = List[UInt8]()
    for i in range(len(v) + 1):
        if i == len(v) or v[i] == 0x2C:
            var lo = 0
            var hi = len(cur)
            while lo < hi and (cur[lo] == 0x20 or cur[lo] == 0x09):
                lo += 1
            while hi > lo and (cur[hi - 1] == 0x20 or cur[hi - 1] == 0x09):
                hi -= 1
            if hi > lo:
                var tag = List[UInt8]()
                for k in range(lo, hi):
                    tag.append(cur[k])
                tags.append(tag^)
            cur = List[UInt8]()
        else:
            cur.append(v[i])
    if len(tags) == 0:
        append_nil(out)
        return
    out.append(0x28)
    for i in range(len(tags)):
        if i > 0:
            out.append(0x20)
        append_string(out, Span(tags[i]))
    out.append(0x29)


def _split_media(media: String) -> Tuple[List[UInt8], List[UInt8]]:
    var b = media.as_bytes()
    var slash = len(b)
    for i in range(len(b)):
        if b[i] == 0x2F:
            slash = i
            break
    var typ = List[UInt8]()
    var sub = List[UInt8]()
    for i in range(slash):
        typ.append(b[i])
    for i in range(slash + 1, len(b)):
        sub.append(b[i])
    return (typ^, sub^)


def _bytes_equal_text(b: List[UInt8], text: String) -> Bool:
    var t = text.as_bytes()
    if len(b) != len(t):
        return False
    for i in range(len(b)):
        if b[i] != t[i]:
            return False
    return True


def _header_value(msg: Message, index: Int, name: String) -> Optional[List[UInt8]]:
    var f = msg.part(index).header(name)
    if not f:
        return None
    return Optional[List[UInt8]](f.value().value())


def _append_extension_leaf(mut out: List[UInt8], msg: Message, index: Int):
    out.append(0x20)
    append_nstring(out, _header_value(msg, index, String("Content-MD5")))
    out.append(0x20)
    _append_disposition(out, _header_value(msg, index, String("Content-Disposition")))
    out.append(0x20)
    _append_language(out, _header_value(msg, index, String("Content-Language")))
    out.append(0x20)
    append_nstring(out, _header_value(msg, index, String("Content-Location")))


def _append_body(
    mut out: List[UInt8], msg: Message, index: Int, extensible: Bool
) raises:
    var part = msg.part(index)
    var media = _split_media(part.media_type())
    if part.is_multipart():
        var kids = part.children()
        out.append(0x28)
        if len(kids) == 0:
            out.extend(
                String('("TEXT" "PLAIN" ("CHARSET" "US-ASCII") NIL NIL "7BIT" 0 0)').as_bytes()
            )
        for i in range(len(kids)):
            _append_body(out, msg, kids[i], extensible)
        out.append(0x20)
        append_upper_string(out, Span(media[1]))
        if extensible:
            out.append(0x20)
            _append_params(out, _header_value(msg, index, String("Content-Type")), False)
            out.append(0x20)
            _append_disposition(out, _header_value(msg, index, String("Content-Disposition")))
            out.append(0x20)
            _append_language(out, _header_value(msg, index, String("Content-Language")))
            out.append(0x20)
            append_nstring(out, _header_value(msg, index, String("Content-Location")))
        out.append(0x29)
        return
    var is_text = _bytes_equal_text(media[0], String("text"))
    var is_message = part.media_type() == "message/rfc822"
    if is_message:
        # A message/rfc822 with a transfer encoding (RFC 2046 forbids it, mail
        # has it) cannot be opened: describe it as a plain leaf, with no
        # envelope. A parse limit still refuses the whole structure.
        var cte = part.transfer_encoding().lower()
        if cte != "7bit" and cte != "8bit" and cte != "binary" and cte != "":
            is_message = False
    out.append(0x28)
    append_upper_string(out, Span(media[0]))
    out.append(0x20)
    append_upper_string(out, Span(media[1]))
    out.append(0x20)
    var ctype = _header_value(msg, index, String("Content-Type"))
    _append_params(out, ctype, is_text and not ctype)
    out.append(0x20)
    append_nstring(out, _header_value(msg, index, String("Content-ID")))
    out.append(0x20)
    append_nstring(out, _header_value(msg, index, String("Content-Description")))
    out.append(0x20)
    append_upper_string(out, part.transfer_encoding().as_bytes())
    out.append(0x20)
    append_number(out, part.body_octets())
    if is_message:
        var nested = msg.open_rfc822(index)
        out.append(0x20)
        _ext(out, envelope_bytes(nested.header_bytes(0).into_span()))
        out.append(0x20)
        _append_body(out, nested, 0, extensible)
        out.append(0x20)
        append_number(out, part.body_lines())
    elif is_text:
        out.append(0x20)
        append_number(out, part.body_lines())
    if extensible:
        _append_extension_leaf(out, msg, index)
    out.append(0x29)


def body_structure_bytes(msg: Message, extensible: Bool) raises -> List[UInt8]:
    """BODYSTRUCTURE (`extensible`) or BODY of the message. Raises when a
    nested message cannot be opened under the parse limits."""
    var out = List[UInt8]()
    _append_body(out, msg, 0, extensible)
    return out^
