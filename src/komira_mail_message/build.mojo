# =============================================================================
# komira_mail_message/build.mojo -- composing a message.
# =============================================================================
#
# `MessageBuilder` collects the fields, the bodies and the attachments, and
# `build()` writes the message as bytes, CRLF line breaks only:
#
#   Date, From, Reply-To, To, Cc, Message-ID, In-Reply-To, References,
#   Subject, the fields given to `add_header` (in order), MIME-Version,
#   then the top entity's Content-Type and Content-Transfer-Encoding.
#
# There is no `Bcc` field: blind copies are envelope recipients only.
#
# Structure (RFC 2046): a text or an HTML body alone is one `text/plain` or
# `text/html` part; both are `multipart/alternative` (text first, RFC 2046
# section 5.1.4); attachments make `multipart/mixed` holding that body first.
# A text body is UTF-8 with its line breaks made CRLF; it is written `7bit`
# when it is ASCII without NUL and no line is over 998 octets, else
# `quoted-printable`. An attachment is `base64` in lines of 76, with RFC 2183
# `Content-Disposition: attachment` and its file name as `filename` and as
# the `Content-Type` `name` (RFC 2231 when it is not short printable ASCII
# or holds `=?`, which a reader would take for an encoded word). RFC 2046
# sections 5.1 and 5.2 allow only 7bit, 8bit or binary for `multipart/*` and
# `message/*`: a `multipart/*` attachment is refused as `InvalidValue` (it
# would need a boundary the builder does not write), and a `message/*` one
# (a forwarded `message/rfc822`) is written `7bit` with its line breaks made
# CRLF, and refused as `InvalidValue` when it holds a byte over 127, a NUL or
# a line over 998 octets (8bit would need an 8BITMIME transport).
# A boundary is `=_komira_<depth>` (made unique if a part holds it); `=_`
# cannot occur in quoted-printable or base64 text. A single-part message's
# body is ended with CRLF if it was not.
#
# Header values: CR, LF and NUL are refused in every value given (a header
# injection). A `Subject` or `add_header` value is written as it is when it
# is printable ASCII and tabs, holds no `=?` and no word too long to fold;
# otherwise as RFC 2047 encoded words. A display name is written by
# `komira_mail_address` when it is ASCII (quoted if it must be) and as encoded
# words otherwise. Every field is folded (fold.mojo).
# =============================================================================

from komira_encoding import base64_encode
from komira_mail_address import AddrSpec, Mailbox

from .chars import (
    CR,
    GT,
    LF,
    LT,
    SP,
    SLASH,
    append_bytes,
    append_crlf,
    bytes_of,
    equals_ignore_case,
    find_bytes,
    find_forbidden,
    is_ftext,
    is_token_char,
    lower,
)
from .date import format_date, format_message_id, is_msg_id
from .encoded_word import encode_words
from .errors import (
    FORBIDDEN_BYTE,
    INVALID_HEADER,
    INVALID_VALUE,
    MISSING_FIELD,
    message_error,
)
from .fold import FOLD_AT, LINE_MAX, append_field
from .params import append_param
from .quoted_printable import quoted_printable_encode

comptime _NAME_WORD_LIMIT = 60
"""The longest encoded word in a display name, so `Reply-To: ` and a word
fit in 76 characters."""

comptime _LONG_WORD = 900
"""An unstructured value with a word longer than this is encoded, so it can
be folded under 998 octets."""

comptime _OWNED: StaticString = "date from sender reply-to to cc bcc message-id in-reply-to references subject mime-version content-type content-transfer-encoding content-disposition"
"""Refused by `add_header`: the fields `build()` writes itself, and `Bcc` and
`Sender`, which it never writes. All of them are address, date, id or MIME
fields; `add_header` writes unstructured text without their checks, and a
second `Bcc` would leak blind copies."""


def _refuse_forbidden(value: Span[UInt8, _], function: StaticString) raises:
    if find_forbidden(value) >= 0:
        raise message_error(FORBIDDEN_BYTE, function, "CR, LF or NUL")


def _needs_encoding(text: Span[UInt8, _]) -> Bool:
    var run = 0
    for i in range(len(text)):
        var c = text[i]
        if c >= 127 or (c < 32 and c != 9):
            return True
        if c == 61 and i + 1 < len(text) and text[i + 1] == 63:  # =?
            return True
        if c == SP or c == 9:
            run = 0
        else:
            run += 1
            if run > _LONG_WORD:
                return True
    return False


def unstructured_value(text: Span[UInt8, _], name_length: Int) -> List[UInt8]:
    """An unstructured field body for `text`: itself, or encoded words joined
    by spaces (the first fitting after `Name: `)."""
    if not _needs_encoding(text):
        var out = List[UInt8](capacity=len(text))
        append_bytes(out, text)
        return out^
    var words = encode_words(text, FOLD_AT - name_length - 2, 75)
    var out = List[UInt8]()
    for k in range(len(words)):
        if k > 0:
            out.append(SP)
        append_bytes(out, Span(words[k]))
    return out^


struct _Named(Copyable, Movable):
    var name: String
    var addr: AddrSpec

    def __init__(out self, name: String, addr: AddrSpec):
        self.name = name
        self.addr = addr.copy()


def _append_mailbox(mut out: List[UInt8], m: _Named) raises:
    var name = m.name.as_bytes()
    if len(name) == 0:
        m.addr.append_to(out)
        return
    if not _needs_encoding(name):
        Mailbox(m.name, m.addr).append_to(out)
        return
    var words = encode_words(name, _NAME_WORD_LIMIT, _NAME_WORD_LIMIT)
    for k in range(len(words)):
        if k > 0:
            out.append(SP)
        append_bytes(out, Span(words[k]))
    out.append(SP)
    out.append(LT)
    m.addr.append_to(out)
    out.append(GT)


def _append_list(mut out: List[UInt8], list: List[_Named]) raises:
    for k in range(len(list)):
        if k > 0:
            out.append(44)  # ,
            out.append(SP)
        _append_mailbox(out, list[k])


struct _Attachment(Copyable, Movable):
    var filename: String
    var media_type: String
    var data: List[UInt8]

    def __init__(out self, filename: String, media_type: String, var data: List[UInt8]):
        self.filename = filename
        self.media_type = media_type
        self.data = data^


struct _Entity(Copyable, Movable):
    """A MIME entity: its header fields (each with its CRLF) and its body."""

    var headers: List[UInt8]
    var body: List[UInt8]

    def __init__(out self, var headers: List[UInt8], var body: List[UInt8]):
        self.headers = headers^
        self.body = body^

    def append_to(self, mut out: List[UInt8]):
        append_bytes(out, Span(self.headers))
        append_crlf(out)
        append_bytes(out, Span(self.body))


def _field(mut out: List[UInt8], name: StaticString, value: Span[UInt8, _]) raises:
    append_field(out, name.as_bytes(), value, "MessageBuilder.build")


def _crlf_text(b: Span[UInt8, _]) -> List[UInt8]:
    """`b` with every CRLF, bare CR and bare LF made CRLF."""
    var n = len(b)
    var out = List[UInt8](capacity=n + n // 32 + 2)
    var i = 0
    while i < n:
        var c = b[i]
        if c == CR:
            append_crlf(out)
            i += 2 if i + 1 < n and b[i + 1] == LF else 1
            continue
        if c == LF:
            append_crlf(out)
            i += 1
            continue
        out.append(c)
        i += 1
    return out^


def _is_seven_bit(body: List[UInt8]) -> Bool:
    var line = 0
    for i in range(len(body)):
        var c = body[i]
        if c >= 128 or c == 0:
            return False
        if c == CR:
            line = 0
        elif c != LF:
            line += 1
            if line > LINE_MAX:
                return False
    return True


def _text_entity(text: String, subtype: StaticString) raises -> _Entity:
    var body = _crlf_text(text.as_bytes())
    var headers = List[UInt8]()
    var ct = bytes_of(String("text/") + String(subtype))
    append_param(ct, "charset", "utf-8".as_bytes())
    _field(headers, "Content-Type", Span(ct))
    if _is_seven_bit(body):
        _field(headers, "Content-Transfer-Encoding", "7bit".as_bytes())
        return _Entity(headers^, body^)
    _field(headers, "Content-Transfer-Encoding", "quoted-printable".as_bytes())
    return _Entity(headers^, quoted_printable_encode(Span(body)))


def _attachment_entity(a: _Attachment) raises -> _Entity:
    var headers = List[UInt8]()
    var ct = bytes_of(a.media_type)
    var cd = bytes_of(String("attachment"))
    if a.filename.byte_length() > 0:
        append_param(ct, "name", a.filename.as_bytes())
        append_param(cd, "filename", a.filename.as_bytes())
    _field(headers, "Content-Type", Span(ct))
    _field(headers, "Content-Disposition", Span(cd))
    if a.media_type.startswith("message/"):
        _field(headers, "Content-Transfer-Encoding", "7bit".as_bytes())
        return _Entity(headers^, a.data.copy())
    _field(headers, "Content-Transfer-Encoding", "base64".as_bytes())
    var encoded = base64_encode(Span(a.data))
    var e = encoded.as_bytes()
    var body = List[UInt8](capacity=len(e) + len(e) // 38 + 2)
    for i in range(len(e)):
        if i > 0 and i % 76 == 0:
            append_crlf(body)
        body.append(e[i])
    return _Entity(headers^, body^)


def _multipart_entity(
    subtype: StaticString, children: List[_Entity], depth: Int
) raises -> _Entity:
    var serialized = List[List[UInt8]]()
    for k in range(len(children)):
        var s = List[UInt8]()
        children[k].append_to(s)
        serialized.append(s^)
    var boundary = String("=_komira_") + String(depth)
    var attempt = 0
    while True:
        var delimiter = String("--") + boundary
        var clash = False
        for k in range(len(serialized)):
            var s = Span(serialized[k])
            if find_bytes(s, delimiter.as_bytes(), 0, len(s)) >= 0:
                clash = True
                break
        if not clash:
            break
        attempt += 1
        boundary = String("=_komira_") + String(depth) + String("_") + String(attempt)
    var headers = List[UInt8]()
    var ct = bytes_of(String("multipart/") + String(subtype))
    append_param(ct, "boundary", boundary.as_bytes())
    _field(headers, "Content-Type", Span(ct))
    var body = List[UInt8]()
    for k in range(len(serialized)):
        body.append(45)
        body.append(45)
        append_bytes(body, boundary.as_bytes())
        append_crlf(body)
        append_bytes(body, Span(serialized[k]))
        append_crlf(body)
    body.append(45)
    body.append(45)
    append_bytes(body, boundary.as_bytes())
    body.append(45)
    body.append(45)
    append_crlf(body)
    return _Entity(headers^, body^)


def _check_media_type(media_type: String) raises -> String:
    var b = media_type.as_bytes()
    var slash = -1
    for i in range(len(b)):
        if b[i] == SLASH and slash < 0:
            slash = i
        elif not is_token_char(b[i]):
            slash = -2
            break
    if slash <= 0 or slash == len(b) - 1:
        raise message_error(
            INVALID_VALUE,
            "MessageBuilder.add_attachment",
            "a media type that is not type/subtype tokens",
        )
    var lowered = media_type.lower()
    if lowered.startswith("multipart/"):
        raise message_error(
            INVALID_VALUE,
            "MessageBuilder.add_attachment",
            "a multipart media type",
        )
    return lowered


struct MessageBuilder(Copyable, Movable):
    """Collects a message and writes it; see the module header."""

    var _from: List[_Named]
    var _reply_to: List[_Named]
    var _to: List[_Named]
    var _cc: List[_Named]
    var _subject: Optional[String]
    var _date: Optional[String]
    var _message_id: Optional[String]
    var _in_reply_to: Optional[String]
    var _references: List[String]
    var _extra_names: List[String]
    var _extra_values: List[String]
    var _text: Optional[String]
    var _html: Optional[String]
    var _attachments: List[_Attachment]

    def __init__(out self):
        self._from = List[_Named]()
        self._reply_to = List[_Named]()
        self._to = List[_Named]()
        self._cc = List[_Named]()
        self._subject = None
        self._date = None
        self._message_id = None
        self._in_reply_to = None
        self._references = List[String]()
        self._extra_names = List[String]()
        self._extra_values = List[String]()
        self._text = None
        self._html = None
        self._attachments = List[_Attachment]()

    @staticmethod
    def _named(display_name: String, addr: AddrSpec, function: StaticString) raises -> _Named:
        _refuse_forbidden(display_name.as_bytes(), function)
        return _Named(display_name, addr)

    def set_from(mut self, display_name: String, addr: AddrSpec) raises:
        """The author (`From`); the display name may be any UTF-8 text or
        empty."""
        self._from.clear()
        self._from.append(Self._named(display_name, addr, "MessageBuilder.set_from"))

    def add_reply_to(mut self, display_name: String, addr: AddrSpec) raises:
        self._reply_to.append(
            Self._named(display_name, addr, "MessageBuilder.add_reply_to")
        )

    def add_to(mut self, display_name: String, addr: AddrSpec) raises:
        self._to.append(Self._named(display_name, addr, "MessageBuilder.add_to"))

    def add_cc(mut self, display_name: String, addr: AddrSpec) raises:
        self._cc.append(Self._named(display_name, addr, "MessageBuilder.add_cc"))

    def set_subject(mut self, subject: String) raises:
        _refuse_forbidden(subject.as_bytes(), "MessageBuilder.set_subject")
        self._subject = subject

    def set_date(mut self, unix_seconds: Int, utc_offset_minutes: Int = 0) raises:
        """`Date` for the instant `unix_seconds` in the zone
        `utc_offset_minutes` east of UTC (see `format_date`)."""
        self._date = format_date(unix_seconds, utc_offset_minutes)

    def set_message_id(mut self, id_left: String, id_right: String) raises:
        """`Message-ID: <id_left@id_right>` (see `format_message_id`)."""
        self._message_id = format_message_id(id_left, id_right)

    def set_in_reply_to(mut self, msg_id: String) raises:
        """`In-Reply-To`: one `<left@right>` message id, as written."""
        if not is_msg_id(msg_id.as_bytes()):
            raise message_error(
                INVALID_VALUE, "MessageBuilder.set_in_reply_to", "not a message id"
            )
        self._in_reply_to = msg_id

    def add_reference(mut self, msg_id: String) raises:
        """One more `References` message id, as written."""
        if not is_msg_id(msg_id.as_bytes()):
            raise message_error(
                INVALID_VALUE, "MessageBuilder.add_reference", "not a message id"
            )
        self._references.append(msg_id)

    def add_header(mut self, name: String, value: String) raises:
        """An unstructured field written after `Subject`. `name` is `ftext`
        and not a field `build()` writes itself."""
        var b = name.as_bytes()
        if len(b) == 0:
            raise message_error(
                INVALID_HEADER, "MessageBuilder.add_header", "an empty field name"
            )
        for i in range(len(b)):
            if not is_ftext(b[i]):
                raise message_error(
                    INVALID_HEADER,
                    "MessageBuilder.add_header",
                    "a byte not allowed in a field name",
                    i,
                )
        var owned = _OWNED.as_bytes()
        var start = 0
        for i in range(len(owned) + 1):
            if i == len(owned) or owned[i] == SP:
                var word = List[UInt8]()
                for k in range(start, i):
                    word.append(owned[k])
                if equals_ignore_case(b, Span(word)):
                    raise message_error(
                        INVALID_HEADER,
                        "MessageBuilder.add_header",
                        "a field the builder writes itself",
                    )
                start = i + 1
        _refuse_forbidden(value.as_bytes(), "MessageBuilder.add_header")
        self._extra_names.append(name)
        self._extra_values.append(value)

    def set_text(mut self, text: String):
        """The plain text body."""
        self._text = text

    def set_html(mut self, html: String):
        """The HTML body."""
        self._html = html

    def add_attachment(
        mut self, filename: String, media_type: String, data: Span[UInt8, _]
    ) raises:
        """An attachment of `media_type` (`type/subtype`, not `multipart/*`),
        named `filename` (any UTF-8, or empty for none). A `message/*`
        attachment must be 7bit text; see the module header."""
        _refuse_forbidden(filename.as_bytes(), "MessageBuilder.add_attachment")
        var mt = _check_media_type(media_type)
        if mt.startswith("message/"):
            var lines = _crlf_text(data)
            if not _is_seven_bit(lines):
                raise message_error(
                    INVALID_VALUE,
                    "MessageBuilder.add_attachment",
                    "a message/* attachment that is not 7bit text",
                )
            self._attachments.append(_Attachment(filename, mt, lines^))
            return
        var copy = List[UInt8](capacity=len(data))
        append_bytes(copy, data)
        self._attachments.append(_Attachment(filename, mt, copy^))

    def _body(self) raises -> _Entity:
        var body: _Entity
        if self._text and self._html:
            var alt = List[_Entity]()
            alt.append(_text_entity(self._text.value(), "plain"))
            alt.append(_text_entity(self._html.value(), "html"))
            var depth = 1 if len(self._attachments) > 0 else 0
            body = _multipart_entity("alternative", alt, depth)
        elif self._html:
            body = _text_entity(self._html.value(), "html")
        elif self._text:
            body = _text_entity(self._text.value(), "plain")
        else:
            body = _text_entity(String(""), "plain")
        if len(self._attachments) == 0:
            return body^
        var mixed = List[_Entity]()
        mixed.append(body^)
        for k in range(len(self._attachments)):
            mixed.append(_attachment_entity(self._attachments[k]))
        return _multipart_entity("mixed", mixed, 0)

    def build(self) raises -> List[UInt8]:
        """The message bytes; raises `MissingField` without `From` or
        `Date`."""
        if len(self._from) == 0:
            raise message_error(MISSING_FIELD, "MessageBuilder.build", "no From")
        if not self._date:
            raise message_error(MISSING_FIELD, "MessageBuilder.build", "no Date")
        var out = List[UInt8]()
        _field(out, "Date", self._date.value().as_bytes())
        var v = List[UInt8]()
        _append_list(v, self._from)
        _field(out, "From", Span(v))
        if len(self._reply_to) > 0:
            v = List[UInt8]()
            _append_list(v, self._reply_to)
            _field(out, "Reply-To", Span(v))
        if len(self._to) > 0:
            v = List[UInt8]()
            _append_list(v, self._to)
            _field(out, "To", Span(v))
        if len(self._cc) > 0:
            v = List[UInt8]()
            _append_list(v, self._cc)
            _field(out, "Cc", Span(v))
        if self._message_id:
            _field(out, "Message-ID", self._message_id.value().as_bytes())
        if self._in_reply_to:
            _field(out, "In-Reply-To", self._in_reply_to.value().as_bytes())
        if len(self._references) > 0:
            v = List[UInt8]()
            for k in range(len(self._references)):
                if k > 0:
                    v.append(SP)
                append_bytes(v, self._references[k].as_bytes())
            _field(out, "References", Span(v))
        if self._subject:
            v = unstructured_value(self._subject.value().as_bytes(), 7)
            _field(out, "Subject", Span(v))
        for k in range(len(self._extra_names)):
            var name = self._extra_names[k]
            v = unstructured_value(
                self._extra_values[k].as_bytes(), name.byte_length()
            )
            append_field(out, name.as_bytes(), Span(v), "MessageBuilder.build")
        _field(out, "MIME-Version", "1.0".as_bytes())
        var body = self._body()
        append_bytes(out, Span(body.headers))
        append_crlf(out)
        append_bytes(out, Span(body.body))
        var n = len(out)
        if not (n >= 2 and out[n - 2] == CR and out[n - 1] == LF):
            append_crlf(out)
        return out^
