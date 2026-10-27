# komira_op_join_build

The build side of the engine's joins, and the join kernels that need no join
operator. The package root re-exports nothing; import from the modules.

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
- `komira_op_join_build.cross_join_kernel`: `cross_join_cartesian`, the M x N
  product of two resident batches.
- `komira_op_join_build.join_blocking`: `BinBlocking` and `GeohashBlocking`,
  which map rows of a non-equi join to bucket ids so that rows that can match
  share a bucket.
- `komira_op_join_build.join_probe_null_mask`: `ProbeNullMask`, the one
  probe-side "NULL never matches" decision every single-key kernel reads.
- The levers of the build, each a setting set once per process from a flag (no
  environment reads), a pure predicate and witness counters:
  `join_bloom_l1_resident` (decline a bloom filter over an L1-resident index),
  `join_bloom_selectivity` (the composite probe's sampled bloom latch),
  `join_probe_phase_split` (the size gate of the phase-split inner probe),
  `join_layout_counter` and `join_parallel_build_counter`.

## Examples

<!-- mojo-hidden from std.testing import assert_equal, assert_true, assert_false -->
```mojo
from komira_op_join_build.hash_directory import HashDirectory, SLOT_EMPTY
from komira_op_join_build.join_blocking import BinBlocking
from komira_op_join_build.join_bloom_l1_resident import BLOOM_L1_DEFAULT_BUDGET_BYTES, bloom_l1_index_bytes, bloom_l1_should_decline

# A band join on `value` in bins of width 10: the range [5, 35] can match a
# point in any of bins 0..3.
var bins = BinBlocking.for_range(0, 1, 10.0)
var lo: List[Float64] = [5.0]
var hi: List[Float64] = [35.0]
var keys = bins.block_keys_range(Span(lo), Span(hi))
assert_equal(len(keys[0]), 4)
assert_equal(BinBlocking.for_point(0, 10.0).value_to_bin(12.0), keys[0][1])

# The directory maps a hash to a storage slot.
var dir = HashDirectory(16)
var h = UInt64(0xABCD_0000_0000_0007)
_ = dir.insert_raw(h, Int32(3))
assert_equal(dir.read_slot_at(dir.bucket_of(h)), Int32(3))
assert_equal(dir.read_slot_at(dir.next_bucket(dir.bucket_of(h))), SLOT_EMPTY)

# A 100-row build side indexes 3,648 bytes (a 256-bucket table plus 16-byte
# entries): inside a 16 KiB budget, so its bloom filter cannot pay.
var bytes = bloom_l1_index_bytes(100, 256, 2, True, True)
assert_equal(bytes, 3_648)
assert_true(bloom_l1_should_decline(bytes, BLOOM_L1_DEFAULT_BUDGET_BYTES))
assert_false(bloom_l1_should_decline(bytes, 0))  # 0 is the OFF setting
```
