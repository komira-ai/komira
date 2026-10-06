# komira_textproto

A lexer for the protobuf text format (textproto), with no dependencies and no
schema. `lex` turns text into a list of `Token`s: the structural `{` `}` `:`,
quoted strings (escapes decoded), numbers (text kept verbatim) and barewords,
each with its kind and the line it starts on, so a quoted `"{"` is never
mistaken for a brace. `#` comments and whitespace are dropped. `TokenCursor`
reads a token list forward for a hand-written parser, and every refusal (from
the lexer or the cursor) starts `<source>: line N:`. Characters of richer
textproto dialects (`[ ] < > , ;`) are refused rather than lexed as words.

## Examples

Lex a small document:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_textproto import TOKEN_NUMBER, TOKEN_STRING, TOKEN_WORD, lex

var tokens = lex("""# a comment
server {
  name: "web \\"1\\""
  port: 8080
}""")
assert_equal(len(tokens), 9)
assert_equal(tokens[0].kind, TOKEN_WORD)
assert_equal(tokens[0].text, "server")
assert_equal(tokens[0].line, 2)
assert_equal(tokens[4].kind, TOKEN_STRING)
assert_equal(tokens[4].text, 'web "1"')
assert_equal(tokens[7].kind, TOKEN_NUMBER)
assert_equal(tokens[7].text, "8080")
```

Parse with a cursor, which names the line of anything unexpected:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_textproto import TOKEN_COLON, TOKEN_STRING, TOKEN_WORD, TokenCursor, lex

var cur = TokenCursor(lex('name: "ada"\nage 36'), "person.txtpb")
var field = cur.expect(TOKEN_WORD)
_ = cur.expect(TOKEN_COLON)
assert_equal(field.text + "=" + cur.expect(TOKEN_STRING).text, "name=ada")
_ = cur.expect(TOKEN_WORD)
var message = String()
try:
    _ = cur.expect(TOKEN_COLON)
except e:
    message = String(e)
assert_equal(message, "person.txtpb: line 2: expected ':' but got number '36'")
```

A character the lexer does not support is refused, naming the line:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_textproto import lex

var message = String()
try:
    _ = lex("ports: [80, 443]")
except e:
    message = String(e)
assert_equal(message, "textproto: line 1: unsupported character '['")
```
