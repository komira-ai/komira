# komira_op_join_build

The build side of the engine's joins, and the join kernels that need no join
operator. The package root re-exports nothing; import from the modules.

- `komira_op_join_build.join`: `HashJoinBuilder`, the single-INT64-key hash
  join with separate chaining (so 1:N and N:M keys keep every match), and its
  probes as methods: INNER (`probe_inner`, `probe_inner_into`, the resumable
  `probe_inner_chunk` into caller spans, `count_inner_matches`), SEMI and ANTI
  (with COUNT fast paths), LEFT, RIGHT and FULL. A NULL key matches nothing; a
  NULL build row is still emitted by the RIGHT/FULL unmatched-build sweep. The
  build (`join_build_serial`) and the probe kernels (`join_probe_inner`,
  `join_probe_inner_ps`, `join_probe_semi_anti`, `join_probe_outer`) are
  modules of their own.
- `komira_op_join_build.hash_chain_parallel_build`: `hash_join_build_parallel`,
  the parallel build of a `HashJoinBuilder` over the engine's dispatcher (each
  worker pushes its rows onto their chains with an atomic compare-exchange),
  serial below `JOIN_BUILD_PARALLEL_THRESHOLD` rows; the same matches as the
  serial build, chain order aside. Its settings (`hash_chain_build_settings`):
  the build mode (AUTO, OFF, or the FORCE test hook) and who fills the
  chain-head table.
- `komira_op_join_build.join_sort_merge`: the merge phase of a sort-merge
  INNER join over pre-sorted keys, and `cross_join_indices`.
- `komira_op_join_build.join_perfect_hash`: `PerfectHashJoin`, a direct-indexed
  table for dense unique build keys (it declines a build with NULL keys).
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
from komira_arrow.primitive_array import PrimitiveArray
from komira_op_join_build.join import HashJoinBuilder
from komira_op_join_build.hash_directory import HashDirectory, SLOT_EMPTY
from komira_op_join_build.join_blocking import BinBlocking
from komira_op_join_build.join_bloom_l1_resident import BLOOM_L1_DEFAULT_BUDGET_BYTES, bloom_l1_index_bytes, bloom_l1_should_decline

# An INNER, a SEMI and a LEFT join of probe keys [2, 4, 9] against build keys
# [2, 9, 2]: key 2 matches build rows 0 and 2.
var bk: List[Int64] = [2, 9, 2]
var pk: List[Int64] = [2, 4, 9]
var build = PrimitiveArray[DType.int64].from_list(bk)
var probe = PrimitiveArray[DType.int64].from_list(pk)
var b = HashJoinBuilder.build(build)
var inner = b.probe_inner(probe)
assert_equal(len(inner[0]), 3)
var semi = b.probe_semi(probe)
assert_equal(len(semi), 2)
assert_equal(semi[0], 0)
assert_equal(semi[1], 2)
var left = b.probe_left(probe)
assert_equal(len(left[0]), 4)  # the unmatched probe row 1 once, with -1

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
