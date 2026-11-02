# komira_uuid

UUIDv7 identifiers (RFC 9562, section 5.7): a 48-bit big-endian Unix
millisecond timestamp, the version nibble 7, the RFC variant bits and 74 bits
of randomness, so the 16 bytes sort in creation-time order.

- `Uuid` is a 16-byte value: `to_hyphenated()` (lowercase 8-4-4-4-12),
  `version()`, `variant()`, `unix_ts_ms()`, `byte_at(i)`, `as_bytes()`,
  equality and unsigned big-endian ordering. `Uuid()` is the nil UUID.
- `komira_uuid.uuid.from_hyphenated` parses text back: upper- or lower-case
  hex, a `-` skipped where it falls between two bytes (a `-` between the two
  hex digits of one byte raises). It raises when the text yields fewer than
  16 bytes or holds a bad hex pair; it stops reading after the 16th byte, so
  anything after it, hex or not, is ignored without an error.
- `generate_uuidv7(now_ms)` mints one ID from the wall clock (or `now_ms`,
  of which only the low 48 bits are stored) and fresh CSPRNG bytes (AWS-LC
  `RAND_bytes`). Two IDs minted in the same millisecond are ordered randomly.
- `Uuidv7Generator.generate(now_ms)` is the monotonic generator (RFC 9562
  section 6.2, method 1): the 12-bit `rand_a` field is a per-millisecond
  counter, so every ID it returns is strictly greater than the one before,
  also across threads sharing one generator. If the clock stands still or
  goes backwards it keeps counting on the last millisecond; past 4095 IDs in
  one millisecond it moves the embedded timestamp forward by one.

It mints only version 7: it does not generate v1/v4 UUIDs, and it does not
check the version of a UUID it parses.

## Examples

Parse, inspect and format a known UUIDv7:

<!-- mojo-hidden from std.testing import assert_equal, assert_raises, assert_true -->
```mojo
from komira_uuid import Uuid
from komira_uuid.uuid import from_hyphenated

var u = from_hyphenated("0190AB1C-3D4E-7F80-8A1B-2C3D4E5F6071")
assert_equal(u.to_hyphenated(), "0190ab1c-3d4e-7f80-8a1b-2c3d4e5f6071")
assert_equal(u.version(), 7)
assert_equal(u.variant(), 2)  # 0b10, the RFC 9562 variant
assert_equal(u.unix_ts_ms(), 0x0190AB1C3D4E)
assert_equal(u.byte_at(0), 0x01)
assert_true(Uuid() < u)  # the nil UUID sorts first
assert_equal(String(Uuid()), "00000000-0000-0000-0000-000000000000")

with assert_raises():
    _ = from_hyphenated("0190ab1c-3d4e")  # too short
with assert_raises():
    _ = from_hyphenated("0190ab1c-3d4e-7f80-8a1b-2c3d4e5f607g")  # not hex
with assert_raises():
    _ = from_hyphenated("0190ab1c-3d4e-7f80-8a1b-2c3d4e5f6-071")  # `-` inside a byte
# A `-` at a byte boundary is skipped; text after the 16th byte is ignored.
assert_true(from_hyphenated("0190ab1c3d4e7f808a1b2c3d4e5f6071") == u)
assert_true(from_hyphenated("0190ab1c-3d4e-7f80-8a1b-2c3d4e5f6071ffzz") == u)
```

Mint IDs with a pinned clock. The timestamp is the one passed in; the
monotonic generator stays strictly increasing within one millisecond and
even when the clock goes backwards:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_uuid import Uuidv7Generator, generate_uuidv7
from komira_uuid.uuid import from_hyphenated

var now: UInt64 = 1_700_000_000_000
var one = generate_uuidv7(now)
assert_equal(one.unix_ts_ms(), now)
assert_equal(one.version(), 7)
assert_true(from_hyphenated(one.to_hyphenated()) == one)

var gen = Uuidv7Generator()
var prev = gen.generate(now)
for _ in range(1000):  # all in the same millisecond
    var next = gen.generate(now)
    assert_true(prev < next)
    prev = next
var after_step_back = gen.generate(now - 5)  # the clock went backwards
assert_true(prev < after_step_back)
assert_equal(after_step_back.unix_ts_ms(), now)
```

## Build files

This package is built with buildrules' `mojo_package` and packaged for mopm as `komira_uuid`, version 0.1.0
(`mopm.toml`). The library is `src/komira_uuid/`, its tests are `tests/`. It depends on three packages, sibling
directories (`[dependencies]` of `mopm.toml`): `komira_atomic_alias`, `komira_awslc` and `komira_clock`, each as
`{ path = "../<name>", version = "0.1" }`. The `.conda` of this package records `mojo-komira_atomic_alias >=0.1,<0.2`,
`mojo-komira_awslc >=0.1,<0.2` and `mojo-komira_clock >=0.1,<0.2` as dependencies and holds none of their files:
installing `komira_uuid` installs them with it. `komira_awslc` is aws-lc's archive, and a dependent's link takes it
from the closure; this package owns no C. The files that are not sources:

| file | what |
|---|---|
| `mopm.toml` | the mopm manifest: name, version, the Mojo version, the dependencies and where the library and its tests are |
| `mopm.lock` | the toolchain pins and the path dependencies, as `mopm lock` writes them (no registry is reached: every dependency is a sibling) |
| `mopm-toolchain.toml` | the exact mopm and Mojo versions the build uses (written by hand) |
| `buildrules.mojo.lock.bzl`, `buildrules.mojo.bzl` | written by `buildrules mojo sync` from the files above and from the manifests of the siblings; `buildrules mojo check` fails when they are stale |

`:lib` is the library file, built from the `:lib` of the three siblings, and exists only once the test of `tests/`
has passed. After any change to a source, a test, a manifest of this package or of a sibling, run
`buildrules mojo sync` with all four packages staged, commit what it writes, and build
`komira//src/komira_uuid:lib` on the farm.

`:conda` is buildrules' `mojo_conda` over `:lib`: the `.conda` of the mopm package
(`mojo-komira_uuid-0.1.0-mojo1.0.0_0.conda`), packed with the siblings' manifests beside its own (`members`),
which therefore exists only once the test has passed. Publishing it (`mopm publish`) uploads, so it is a step of a
CI job that takes that file, not a build action.

`:komira_uuid` is `:lib` as komira's Mojo rules take it (`mojo_adopted_library`): its `deps` are the adopted
target of each package in `[dependencies]`, and the rule refuses a list that is not the closure `:lib` was built
from. It also compiles and runs the README's examples above (`[tests][readme]`) against `:lib`; the test is not
run again.
