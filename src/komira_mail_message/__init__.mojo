"""Email messages over bytes: compose (RFC 5322, MIME RFC 2045-2049, RFC
2183, RFC 2231) and parse, with RFC 2047 encoded words both ways.

| function / type | does |
|---|---|
| `MessageBuilder` | collects fields, a text and an HTML body, attachments; `build()` writes the message (`build.mojo`) |
| `parse_message` | a `Message`: header fields and MIME parts, bounded depth and part count (`parse.mojo`) |
| `split_header_fields` | the header fields of a message as written and unfolded (`header.mojo`) |
| `encode_header_text`, `decode_header_text` | RFC 2047 encoded words (`encoded_word.mojo`) |
| `quoted_printable_encode`, `quoted_printable_decode` | RFC 2045 section 6.7 |
| `parse_media_header` | a `Content-Type` / `Content-Disposition` value with RFC 2231 parameters (at most `MAX_PARAMS`) |
| `format_date`, `format_message_id` | the `Date` and `Message-ID` values |

The builder writes CRLF line breaks only, folds every header line to at most
76 characters where it can and refuses one over 998 octets, and refuses CR,
LF and NUL in every value it writes into a header. Addresses are
`komira_mail_address` values. The parser keeps bodies as bytes: no charset
is transcoded.

Errors are named: the message starts `komira_mail_message.<Kind>: <function>:`
and never holds input bytes (`errors.mojo`; `error_kind` reads the kind).
"""

from .build import MessageBuilder
from .date import format_date, format_message_id
from .encoded_word import decode_header_text, encode_header_text
from .errors import error_kind
from .header import HeaderBlock, HeaderField, split_header_fields
from .params import MAX_PARAMS, MediaHeader, Param, parse_media_header
from .parse import MAX_DEPTH, MAX_PARTS, Message, Part, parse_message
from .quoted_printable import quoted_printable_decode, quoted_printable_encode
