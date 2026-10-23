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

## Build files

This package is built with buildrules' `mojo_package` and packaged for mopm as `komira_textproto`, version 0.1.0
(`mopm.toml`). The library is `src/komira_textproto/` (`__init__.mojo` and `lexer.mojo`), its tests are `tests/`. The
package has no dependencies, no native archive and calls no foreign function: it is Mojo over `String` and `List`. The
files that are not sources:

| file | what |
|---|---|
| `mopm.toml` | the mopm manifest: name, version, the Mojo version, where the library and its tests are |
| `mopm.lock` | what `mopm lock` writes (with no registry reachable); the package has no dependencies, so it pins the toolchain only |
| `mopm-toolchain.toml` | the exact mopm and Mojo versions the build uses (written by hand) |
| `coverage_floor.txt` | `lines NN.NN`: the least line coverage `:coverage` may measure; `:coverage_floor` fails when it falls below, and above it passes and prints a hint to raise the figure |
| `buildrules.mojo.lock.bzl`, `buildrules.mojo.bzl` | written by `buildrules mojo sync` from the files above; `buildrules mojo check` fails when they are stale |

`:lib` is the library file and exists only once every test of `tests/` has passed. After any change to a source,
a test, `mopm.toml`, `mopm.lock` or `mopm-toolchain.toml`, run `buildrules mojo sync`, commit what it
writes, and build `komira//src/komira_textproto:lib` on the farm. (The sync writes the toolchain pins,
`mojo_pins.bzl` and `mopm_pins.bzl`, to the directory the `[cells] toolchains` line of `.buckconfig` names:
`tools/build/cells/toolchains/` here.) A test file that `buildrules mojo sync` has not listed is not
run: run the sync after adding one.

`:conda` is buildrules' `mojo_conda` over `:lib`: the `.conda` of the mopm package
(`mojo-komira_textproto-0.1.0-mojo1.0.0_0.conda`), which therefore exists only once the tests have passed.
Publishing it (`mopm publish`) uploads, so it is a step of a CI job that takes that file, not a build action.

`:komira_textproto` is `:lib` as komira's Mojo rules take it (`mojo_adopted_library`). It also compiles and runs the
README's examples above (`[tests][readme]`) against `:lib`, which `:lib` does not do; the tests are not run again.
