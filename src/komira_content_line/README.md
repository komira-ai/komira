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

## Build files

This package is built with buildrules' `mojo_package` and packaged for mopm as `komira_content_line`, version 0.1.0
(`mopm.toml`). The library is `src/komira_content_line/`, its tests are `tests/`. The package has no native archive
and calls no foreign function: it is Mojo over `List`, `Span` and `String`. The files that are not sources:

| file | what |
|---|---|
| `mopm.toml` | the mopm manifest: name, version, the Mojo version, where the library and its tests are |
| `mopm.lock` | what `mopm lock` writes (with no registry reachable); the package has no dependencies, so it pins the toolchain only |
| `mopm-toolchain.toml` | the exact mopm and Mojo versions the build uses (written by hand) |
| `coverage_floor.txt` | `lines NN.NN` and `branches NN.NN`: the least line and branch coverage `:coverage` may measure (the branches are the compiler's IR decisions of the library's sources, `:coverage[branches]`); `:coverage_floor` fails when either falls below, and above it passes and prints a hint to raise the figure |
| `buildrules.mojo.lock.bzl`, `buildrules.mojo.bzl` | written by `buildrules mojo sync` from the files above; `buildrules mojo check` fails when they are stale |

`:lib` is the library file and exists only once every test of `tests/` has passed. After any change to a source,
a test, `mopm.toml`, `mopm.lock` or `mopm-toolchain.toml`, run `buildrules mojo sync`, commit what it
writes, and build `komira//src/komira_content_line:lib` on the farm. (The sync writes the toolchain pins,
`mojo_pins.bzl` and `mopm_pins.bzl`, to the directory the `[cells] toolchains` line of `.buckconfig` names:
`tools/build/cells/toolchains/` here.) A test file that `buildrules mojo sync` has not listed is not
run: run the sync after adding one.

`:conda` is buildrules' `mojo_conda` over `:lib`: the `.conda` of the mopm package
(`mojo-komira_content_line-0.1.0-mojo1.0.0_0.conda`), which therefore exists only once the tests have passed.
Publishing it (`mopm publish`) uploads, so it is a step of a CI job that takes that file, not a build action.

`:komira_content_line` is `:lib` as komira's Mojo rules take it (`mojo_adopted_library`). It also compiles and runs
the README's examples above (`[tests][readme]`) against `:lib`, which `:lib` does not do; the tests are not run again.
