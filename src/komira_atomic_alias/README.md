# komira_atomic_alias

Fixed-width names for the standard library's `Atomic`: `AtomicI8`, `AtomicI32`,
`AtomicI64`, `AtomicU8`, `AtomicU32` and `AtomicU64`, with no other
dependencies. Each name is exactly `std.atomic.Atomic` at that width (the same
type, not a wrapper), so it has the same size, alignment and operations. The
point is the spelling: `Atomic`'s type parameter is changing in a coming Mojo
release, from a `DType` to a scalar type, and code that imports these names is
untouched by that change; only this package is edited.

## Examples

A counter:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_atomic_alias import AtomicI64

var hits = AtomicI64(0)
_ = hits.fetch_add(5)
var before = hits.fetch_sub(2)  # returns the value before the subtraction
assert_equal(Int(before), 5)
assert_equal(Int(hits.load()), 3)
```

Each name holds exactly its width and signedness:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from std.sys import size_of
from komira_atomic_alias import AtomicI8, AtomicU8, AtomicU32

assert_equal(size_of[AtomicU32](), 4)
var signed = AtomicI8(-1)
var unsigned = AtomicU8(255)
assert_equal(Int(signed.load()), -1)
assert_equal(Int(unsigned.load()), 255)
```
