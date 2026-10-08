# komira_vcard

vCard (RFC 6350) on `komira_content_line`. It reads vCard 4.0, 3.0 (RFC 2426)
and 2.1, and writes vCard 4.0.

- `parse_vcards(bytes, limits)` returns raw cards: every property line,
  lexed and as written. It refuses a property outside a card, an unpaired
  BEGIN:VCARD or END:VCARD, a card with no VERSION or two, a VERSION other
  than 2.1, 3.0 or 4.0, and card `max_cards + 1` (10000 by default).
  vCard 2.1 quoted-printable values (with soft line breaks, in UTF-8,
  US-ASCII or ISO-8859-1) are decoded; the line after a soft break is read
  as written, a leading SPACE or HTAB included. A blank line after a soft
  break (or the end of input) ends the value; a line starting with SPACE or
  HTAB after that blank continues the blank line, so it is read as a line of
  its own (and refused if it is not a content line), never joined to the
  value.
- `parse_contacts(bytes, limits)` maps each card to a `Contact`: KIND, UID,
  FN, N, NICKNAME, ORG, TITLE, EMAIL, TEL, ADR, URL, BDAY, NOTE, MEMBER and
  Apple's X-ABLabel, guided by RFC 9555's conversion rules for those
  properties. Every other property, a repeat of a single-valued one, and a
  UID, BDAY, URL or MEMBER line with VALUE=text (a value type `Contact` has
  no field for) are kept as written in `Contact.extra`. Parameters a mapping does not keep are
  listed in `ContactImport.dropped`.
- `emit_contacts(contacts)` writes vCard 4.0 with CRLF line breaks, folded
  at 75 octets. No value can start a line of its own.

```mojo
from komira_vcard import emit_contacts, parse_contacts
from std.testing import assert_equal

var got = parse_contacts(
    "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Jane Doe\r\n"
    "item1.EMAIL;type=INTERNET;type=pref:jane@example.com\r\n"
    "item1.X-ABLabel:Work\r\nX-CUSTOM:kept\r\nEND:VCARD\r\n".as_bytes()
)
var c = got.contacts[0].copy()
assert_equal(c.full_name, "Jane Doe")
assert_equal(c.emails[0].value, "jane@example.com")
assert_equal(c.emails[0].label, "Work")
assert_equal(c.emails[0].pref, 1)
assert_equal(c.extra[0], "X-CUSTOM:kept")
var text = emit_contacts(got.contacts)
assert_equal(
    text,
    "BEGIN:VCARD\r\nVERSION:4.0\r\nFN:Jane Doe\r\n"
    "item1.EMAIL;TYPE=internet;PREF=1:jane@example.com\r\n"
    "item1.X-ABLabel:Work\r\nX-CUSTOM:kept\r\nEND:VCARD\r\n",
)
```
