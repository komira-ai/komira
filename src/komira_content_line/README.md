# komira_content_line

The content-line layer that vCard (RFC 6350 §3) and iCalendar (RFC 5545
§3.1) share. It has no dependencies.

- `unfold(bytes, limits)` splits input into logical lines: CRLF or a bare LF
  ends a physical line, a line starting with SPACE or HTAB continues the one
  before it (RFC 6350 §3.2, RFC 5545 §3.1: only a line break followed by
  SPACE or HTAB is a fold). An empty line ends the line before it; a
  white-space line right after an empty line continues the empty line, and
  a logical line that is still empty (nothing continues it, or only white
  space does) is skipped together with its folds. Joining is done on octets, so a
  fold that falls inside a UTF-8 sequence is restored; each joined line is
  then validated as UTF-8. `ContentLimits` bounds the input and every
  logical line in octets (64 MiB and 1 MiB by default). Each line's
  `folds` records where it was joined and the white-space octet removed.
- `parse_content_line(text, line_number)` splits one line into group, name
  (upper-cased), parameters (RFC 6868 `^n`, `^'`, `^^` decoded) and the
  value, which stays escaped. `format_content_line` writes one back and
  refuses anything that would break the line.
- `fold_line` folds at 75 octets without splitting a UTF-8 sequence.
- `escape_text` / `unescape_text` handle TEXT values. `split_unescaped`
  splits a compound value on separators no backslash escapes, before the
  pieces are unescaped, so `Doe\, Jr.` stays one value.

Every error names the line it is about, for example
`content line: line 3 is longer than the 1048576-octet limit`.

```mojo
from komira_content_line import fold_line, parse_content_line, unfold
from komira_content_line import split_unescaped, unescape_text
from std.testing import assert_equal

var lines = unfold("N:Doe\\, Jr.;Jo\r\n hn;;;\r\n".as_bytes())
assert_equal(lines[0].text, "N:Doe\\, Jr.;John;;;")
var cl = parse_content_line(lines[0].text, lines[0].line_number)
assert_equal(cl.name, "N")
var fields = split_unescaped(cl.value, UInt8(ord(";")))
assert_equal(unescape_text(fields[0]), "Doe, Jr.")
assert_equal(fold_line("FN:short"), "FN:short\r\n")
```
