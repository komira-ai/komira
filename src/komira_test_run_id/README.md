# komira_test_run_id

A per-run id for naming the resources one test run creates (a bucket prefix,
a temporary directory, a namespace). `mint_run_id` builds it from a wall clock
and 64 random bits, and from nothing else, so two executions of the same
action (a retry and its twin) get different ids and disjoint resources. The id
reads `<epoch seconds>-<16 lowercase hex>`, for example
`1790000000-0123456789abcdef`, and is a valid validation-run id. The clock and
the random source are traits (`WallClock`, `Entropy`) with real conformers
(`SystemClock`, `UrandomEntropy`, which reads `/dev/urandom`) and fakes for
tests (`FixedWallClock`, `ScriptedEntropy`). `mint_run_id` raises when the
clock reads zero or less, or when the entropy source cannot produce a value.

## Examples

Mint from pinned sources, so the id is exact:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_test_run_id import FixedWallClock, ScriptedEntropy, mint_run_id

var clock = FixedWallClock(1790000000)
var entropy = ScriptedEntropy([UInt64(0x0123456789ABCDEF), UInt64(0xFF)])
var first = mint_run_id(clock, entropy)
assert_equal(first.value, "1790000000-0123456789abcdef")
assert_equal(first.created_unix, 1790000000)
clock.advance(5)
var second = mint_run_id(clock, entropy)
assert_equal(String(second), "1790000005-00000000000000ff")
```

Mint from the real clock and `/dev/urandom`; two ids differ:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_test_run_id import SystemClock, UrandomEntropy, mint_run_id

var clock = SystemClock()
var entropy = UrandomEntropy()
var a = mint_run_id(clock, entropy)
var b = mint_run_id(clock, entropy)
assert_true(a.value != b.value)
assert_equal(a.value.byte_length(), 27)
```

A source that runs out raises instead of repeating a value:

<!-- mojo-hidden from std.testing import assert_true -->
```mojo
from komira_test_run_id import FixedWallClock, ScriptedEntropy, mint_run_id

var clock = FixedWallClock(1790000000)
var empty = ScriptedEntropy(List[UInt64]())
var refused = False
try:
    _ = mint_run_id(clock, empty)
except:
    refused = True
assert_true(refused)
```

`hex16_lower` is the zero-padded format of the random half:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_test_run_id import hex16_lower

assert_equal(hex16_lower(UInt64(0xAB)), "00000000000000ab")
```
