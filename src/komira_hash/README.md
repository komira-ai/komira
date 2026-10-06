# komira_hash

FNV-1a, 32 and 64 bit, with no dependencies: `fnv1a_32` and `fnv1a_64` hash a
byte span with the published FNV parameters (the four constants are exported
too), so the same bytes hash to the same value in every program and on every
machine. It is a cheap, stable hash for identifiers, table keys and sharding
over names you trust. It is not a cryptographic hash and does not resist
collisions an adversary chooses.

## Examples

The published test vectors:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_hash import FNV1A_32_OFFSET_BASIS, fnv1a_32, fnv1a_64

assert_equal(fnv1a_32("foobar".as_bytes()), 0xBF9CF968)
assert_equal(fnv1a_64("foobar".as_bytes()), 0x85944171F73967E8)
assert_equal(fnv1a_32("".as_bytes()), FNV1A_32_OFFSET_BASIS)  # nothing hashed
```

Any byte span works, a `List[UInt8]` as well as a string's bytes. Here a key
picks one of 8 shards; the hash is stable, so it is the same shard in every
program:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_hash import fnv1a_32

var raw: List[UInt8] = [0x61]  # the byte of "a"
assert_equal(fnv1a_32(Span(raw)), fnv1a_32("a".as_bytes()))
assert_equal(fnv1a_32("user:42".as_bytes()), 0x2F6B7B82)
assert_equal(fnv1a_32("user:42".as_bytes()) % 8, 2)
```
