# komira_op_join_build

The build side of the engine's joins. The package root re-exports nothing;
import from the modules.

- `komira_op_join_build.join_build_untyped`: `JoinBuildTable_Untyped`, a
  hash-join build and probe table whose key and payload layout is a runtime
  list of `ColDescriptor`s (fixed-width integer, float, date, timestamp, BOOL,
  DECIMAL128, STRING and BINARY columns). Every build row gets its own storage
  slot and rows that share a key are chained, so a probe emits one `MatchPair`
  per matching build row. A NULL key matches nothing; float keys follow the
  query semantics' float model (every NaN equal, `-0.0 == +0.0`).
- `komira_op_join_build.hash_directory`: `HashDirectory`, the packed
  open-addressing directory (a 16-bit salt and a 32-bit slot in one 8-byte
  word per bucket) of the engine's untyped hash tables, and `SLOT_EMPTY`.
- `komira_op_join_build.join_build_untyped_cells` and
  `komira_op_join_build.join_untyped_key_hash`: the per-column encode, hash
  and equality kernels and the key hashes the untyped tables share.

## Examples

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_op_join_build.hash_directory import HashDirectory, SLOT_EMPTY

# The directory maps a hash to a storage slot; the salt (the top 16 bits of
# the hash) is checked before a full key compare.
var dir = HashDirectory(16)
var h = UInt64(0xABCD_0000_0000_0007)
var bucket = dir.insert_raw(h, Int32(3))
assert_equal(bucket, dir.bucket_of(h))
assert_equal(dir.read_slot_at(bucket), Int32(3))
assert_equal(dir.read_salt_at(bucket), UInt16(0xABCD))
assert_equal(dir.read_slot_at(dir.next_bucket(bucket)), SLOT_EMPTY)
assert_true(not dir.would_grow_on_insert())
```
