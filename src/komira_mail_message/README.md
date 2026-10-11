# komira_mail_message

Email messages over bytes, for software that sends and reads mail: compose an
RFC 5322 message with MIME (RFC 2045-2049: text, `multipart/alternative`,
`multipart/mixed` attachments; RFC 2183 and RFC 2231 parameters), and parse
one into header fields and parts. RFC 2047 encoded words are written and read
for non-ASCII subjects and display names. Addresses are
`komira_mail_address` values.

Every example below runs as a test when the package is built.

## Compose a message

The builder writes CRLF line breaks only, folds every header line to at most
76 characters, and picks the transfer encoding (7bit, quoted-printable for
non-ASCII text, base64 for attachments, 7bit for a `message/*` attachment).
It keeps no clock and draws no random numbers: the caller gives the time and
a unique message id.

```mojo
from komira_mail_address import AddrSpec
from komira_mail_message import MessageBuilder
from std.testing import assert_equal, assert_true

var b = MessageBuilder()
b.set_from("Acme", AddrSpec("no-reply", "acme.example"))
b.add_to(String("Zo") + chr(0xEB), AddrSpec("zoe", "example.com"))
b.set_subject("Your sign-in code")
b.set_date(1790000000)  # Mon, 21 Sep 2026 14:13:20 +0000
b.set_message_id("k3f9.1", "acme.example")
b.set_text("Your code is 123456.\n")
b.set_html("<p>Your code is <b>123456</b>.</p>\n")
var message = b.build()  # List[UInt8], ready for SMTP DATA
var text = String(StringSlice(from_utf8=Span(message)))
assert_true(text.startswith("Date: Mon, 21 Sep 2026 14:13:20 +0000\r\n"))
assert_true(text.find("To: =?UTF-8?Q?Zo=C3=AB?= <zoe@example.com>\r\n") > 0)
assert_true(text.find('Content-Type: multipart/alternative; boundary="=_komira_0"') > 0)
```

## Parse a message

Bodies stay bytes: `decoded_body` undoes the transfer encoding and converts
no charset. `text_part`, `html_part` and `attachments` are views over the
parts.

```mojo
from komira_mail_message import parse_message
from std.testing import assert_equal

var raw = String(
    "From: =?ISO-8859-1?Q?Andr=E9?= <andre@example.com>\r\n"
    + "Subject: =?UTF-8?Q?Caf=C3=A9?= menu\r\n"
    + "Content-Type: text/plain; charset=utf-8\r\n"
    + "Content-Transfer-Encoding: quoted-printable\r\n"
    + "\r\n"
    + "Espresso: 2 =E2=82=AC\r\n"
)
var m = parse_message(raw.as_bytes())
assert_equal(m.subject().value(), String("Caf") + chr(0xE9) + " menu")
var body = m.decoded_body(m.text_part().value())
assert_equal(String(StringSlice(from_utf8=Span(body))), String("Espresso: 2 ") + chr(0x20AC) + "\r\n")
```

## What is refused

CR, LF and NUL in any value the builder writes into a header (header
injection), a field name that is not RFC 5322 `ftext` or that the builder
writes itself (`Bcc` and `Sender` too: blind copies are envelope recipients
only, and both are address fields), a `multipart/*` attachment or a
`message/*` one that is not 7bit text, a header line that cannot be folded
under 998 octets, and when parsing: a
header line without `:`, a multipart without a valid `boundary` or without a
delimiter line, and a message nested deeper than `MAX_DEPTH` (8) multiparts
or holding more than `MAX_PARTS` (128) parts (both can be lowered per call).
Errors name their kind and hold no input byte.

```mojo
from komira_mail_address import AddrSpec
from komira_mail_message import MessageBuilder, error_kind
from std.testing import assert_equal

var b = MessageBuilder()
var msg = String("")
try:
    b.set_subject("Hi\r\nBcc: victim@example.com")
except e:
    msg = String(e)
    assert_equal(error_kind(e), "ForbiddenByte")
assert_equal(msg, "komira_mail_message.ForbiddenByte: MessageBuilder.set_subject: CR, LF or NUL")
```

## Limits

- No charset transcoding: a decoded body is bytes; RFC 2047 words and RFC
  2231 values are read in UTF-8, US-ASCII and ISO-8859-1 (and the ASCII
  bytes of other ISO-8859 and windows-125x charsets), any other word is kept
  as written.
- `message/rfc822` parts are leaves (not opened), and a part of a
  `multipart/digest` without a `Content-Type` is read as `text/plain`, not
  as RFC 2046 section 5.1.5's `message/rfc822`. Encoded words are decoded
  on unstructured fields (`Subject`) and on an attachment's plain (not RFC
  2231) `filename`. `komira_mail_address` leaves a display name as written;
  the caller can pass it to `decode_header_text`.
- An attachment cannot be `multipart/*`. A `message/*` attachment (a
  forwarded message) is written `7bit` with CRLF line breaks, so it must be
  ASCII without NUL and no line over 998 octets; attach other messages as
  `application/octet-stream`.
- At most `MAX_PARAMS` (128) parameters are read from one `Content-Type` or
  `Content-Disposition`; the rest are dropped.
- No SMTPUTF8 (RFC 6531): header values are written in ASCII, non-ASCII text
  as encoded words.
