# komira_mail_address

Email addresses for software that sends mail: one grammar for header fields
(RFC 5322 section 3.4: `addr-spec`, `name-addr`, groups, quoted strings and
comments) and for SMTP paths (RFC 5321 section 4.1.2), parsing, formatting
and normalization. No dependencies beyond the Mojo standard library.

Every example below runs as a test when the package is built.

## Parse a header field, write the envelope

```mojo
from komira_mail_address import parse_address_list, parse_mailbox
from std.testing import assert_equal

var to = parse_address_list('Mary Smith <mary@x.test>, "Giant; \\"Big\\" Box" <sysservices@Example.NET>')
assert_equal(len(to), 2)
var giant = to[1].mailbox()
assert_equal(giant.display_name(), 'Giant; "Big" Box')
assert_equal(giant.addr_spec().domain(), "example.net")  # domains are lower-cased
assert_equal(giant.addr_spec().format_path(), "<sysservices@example.net>")  # for RCPT TO:

var sender = parse_mailbox("Pete(A nice \\) chap) <pete(his account)@silly.test(his host)>")
assert_equal(sender.format(), "Pete <pete@silly.test>")  # comments are dropped
```

## Build addresses and format them

Constructors validate, so every value can be written into a header or an SMTP
command. Formatting uses the minimum quoting.

```mojo
from komira_mail_address import AddrSpec, Mailbox
from std.testing import assert_equal

var from_ = Mailbox("Acme Support", AddrSpec("support", "Acme.Example"))
assert_equal(from_.format(), "Acme Support <support@acme.example>")
assert_equal(Mailbox("Doe, Jane", AddrSpec("jane", "example.com")).format(), '"Doe, Jane" <jane@example.com>')
assert_equal(AddrSpec("a b", "example.com").format_path(), '<"a b"@example.com>')
```

## What is refused

CR, LF and NUL anywhere (a header or command injection), bytes above 0x7F
(SMTPUTF8 and IDNA are not supported: give a domain in its `xn--` form),
domain literals, a domain that is not letters, digits and `-` labels, the RFC
5321 length limits, and RFC 5322's obsolete forms except a `.` in an unquoted
display name. Every error names its kind and a byte position and holds no
input byte.

```mojo
from komira_mail_address import parse_addr_spec, error_kind
from std.testing import assert_equal

var msg = String("")
try:
    _ = parse_addr_spec("a@b@acme.example")
except e:
    msg = String(e)
    assert_equal(error_kind(e), "Syntax")
assert_equal(msg, "komira_mail_address.Syntax: parse_addr_spec: unexpected byte after the address at position 3")

# A quoted local part holding `@` and `,` is one address, never two.
var one = parse_addr_spec('"x@victim.example,y"@acme.example')
assert_equal(one.local_part(), "x@victim.example,y")
assert_equal(one.domain(), "acme.example")
```

## Limits

- The input is an unfolded field body: the message parser removes the line
  folds first. Nothing here folds a long line or encodes a non-ASCII display
  name (RFC 2047); an encoded word passes through as its ASCII text.
- Local parts are compared exactly (RFC 5321 lets a receiving system treat
  them as case-sensitive); whether to compare them without case is the
  caller's decision.

## Build files

This package is built with buildrules' `mojo_package` and packaged for mopm as `komira_mail_address`, version 0.1.0
(`mopm.toml`). The library is `src/komira_mail_address/` (`address.mojo`, `chars.mojo`, `errors.mojo`, `parse.mojo`
and the `__init__.mojo` that re-exports them), its tests are `tests/`. The package has no native archive and calls no
foreign function: it is Mojo over `List`, `Span` and `String`. The files that are not sources:

| file | what |
|---|---|
| `mopm.toml` | the mopm manifest: name, version, the Mojo version, where the library and its tests are |
| `mopm.lock` | what `mopm lock` writes (with no registry reachable); the package has no dependencies, so it pins the toolchain only |
| `mopm-toolchain.toml` | the exact mopm and Mojo versions the build uses (written by hand) |
| `coverage_floor.txt` | `lines NN.NN`: the least line coverage `:coverage` may measure; `:coverage_floor` fails when it falls below, and above it passes and prints a hint to raise the figure |
| `buildrules.mojo.lock.bzl`, `buildrules.mojo.bzl` | written by `buildrules mojo sync` from the files above; `buildrules mojo check` fails when they are stale |

`:lib` is the library file and exists only once every test of `tests/` has passed. After any change to a source,
a test, `mopm.toml`, `mopm.lock` or `mopm-toolchain.toml`, run `buildrules mojo sync`, commit what it
writes, and build `komira//src/komira_mail_address:lib` on the farm. (The sync writes the toolchain pins,
`mojo_pins.bzl` and `mopm_pins.bzl`, to the directory the `[cells] toolchains` line of `.buckconfig` names:
`tools/build/cells/toolchains/` here.) A test file that `buildrules mojo sync` has not listed is not
run: run the sync after adding one.

`:conda` is buildrules' `mojo_conda` over `:lib`: the `.conda` of the mopm package
(`mojo-komira_mail_address-0.1.0-mojo1.0.0_0.conda`), which therefore exists only once the tests have passed.
Publishing it (`mopm publish`) uploads, so it is a step of a CI job that takes that file, not a build action.

`:komira_mail_address` is `:lib` as komira's Mojo rules take it (`mojo_adopted_library`). It also compiles and runs the
README's examples above (`[tests][readme]`) against `:lib`, which `:lib` does not do; the tests are not run again.
