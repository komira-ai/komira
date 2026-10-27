# komira_op_join_stage

The typed hash join of the engine's stage pipelines: the build table, its key
and payload columns, and the two breaker states a stage's join runs as. The
package root re-exports nothing; import from the modules.

- `komira_op_join_stage.join_build_table`: `JoinBuildTable[KB, *Payload]`, a
  hash-join build table over a key block `KB` and a pack of payload columns.
  Open addressing with linear probing; every build row takes its own slot (no
  deduplication), `has_duplicate_keys` says whether a probe must walk every
  match, and the table doubles before it would reach a load of 3/4, moving
  keys and payloads in lockstep. `combine` merges another table into it (the
  cross-worker merge of a parallel build).
- `komira_op_join_stage.join_key_bundle`: the `KeyBundle` trait and its
  conformer `KeyBundleVar[*Keys]` (one key column per pack element; the
  aliases `KeyBundle1`..`KeyBundle4` and `make_key_bundle_1`..`_4`), with the
  batch-row entry points `build_insert_row`, `probe_batch_row` (first match,
  or every match) and `probe_batch_row_first`. A NULL probe key matches
  nothing.
- `komira_op_join_stage.join_key_slot`: one key column, `KeySlot[K]`, and
  the key model every path shares (`key_hash`, `key_eq`,
  `key_canonical_bits`, `key_bits_of`, `key_from_bits`). Every value of the
  key type is a key: occupancy is kept apart from the values, so no value
  stands for an empty slot. Float keys follow the query semantics' float
  model, as in DuckDB: every NaN equals every NaN and `-0.0` equals `+0.0`.
- `komira_op_join_stage.join_payload_column`: the payload columns,
  `PayloadSlot[dt]` (fixed width) and `PayloadCol_JoinString` (STRING), each
  with a NULL per slot, and `PayloadBlock`, the wrapper the table's
  constructor takes them in.
- `komira_op_join_stage.join_build_table_fns`: the free functions over typed
  key values for one to four key columns: `join_build_insert_slot_N`,
  `join_build_probe_N` (first match), `join_build_probe_all_slots_N` (every
  match) and `join_build_prefetch_key_N`. They hash and compare exactly as
  the batch-row path does.
- `komira_op_join_stage.join_build_state`: `JoinBuildState`, the JOIN_BUILD
  breaker state. `feed_row` inserts a build row (not one with a NULL key) and
  its payloads at their own types; `take_join_build_table` moves the table out
  once; `combine` folds another worker's state in.
- `komira_op_join_stage.join_probe_state`: `JoinProbeState`, the JOIN_PROBE
  breaker state. `probe_batch` emits, per probe batch, the probe key `jkey`
  and every build payload for each matching pair; for LEFT, an unmatched
  probe row once with NULL payloads.

## Examples

<!-- mojo-hidden from std.testing import assert_equal, assert_true, assert_false -->
```mojo
from komira_op_join_stage.join_build_table import JoinBuildTable
from komira_op_join_stage.join_build_table_fns import join_build_insert_slot_1, join_build_probe_1, join_build_probe_all_slots_1
from komira_op_join_stage.join_key_bundle import KeyBundle1, make_key_bundle_1
from komira_op_join_stage.join_payload_column import PayloadBlock, PayloadSlot, payload_slot

# A FLOAT64-keyed build table with one INT64 payload, starting at 8 slots.
var t = JoinBuildTable[KeyBundle1[DType.float64], PayloadSlot[DType.int64]](
    make_key_bundle_1[DType.float64](8),
    PayloadBlock[PayloadSlot[DType.int64]](payload_slot[DType.int64](8)),
    initial_capacity=8,
)
var keys: List[Float64] = [-1.0, -0.0, 2.5, 2.5]
for i in range(len(keys)):
    var slot = join_build_insert_slot_1(t, keys[i])
    t.payload[0].write_slot(slot, Int64(100 + i))
assert_true(t.has_duplicate_keys)  # 2.5 twice

# -1.0 is a key like any other; +0.0 finds the -0.0 row (the float model).
assert_equal(t.payload[0].read_slot(join_build_probe_1(t, Float64(-1.0))), 100)
assert_equal(t.payload[0].read_slot(join_build_probe_1(t, Float64(0.0))), 101)
assert_equal(join_build_probe_1(t, Float64(7.0)), -1)

# Every match of 2.5, before and after the table grows.
var hits = List[Int]()
join_build_probe_all_slots_1(t, Float64(2.5), hits)
assert_equal(len(hits), 2)
for k in range(20):
    _ = join_build_insert_slot_1(t, Float64(10 + k))
assert_true(t.capacity() > 8)
hits.clear()
join_build_probe_all_slots_1(t, Float64(2.5), hits)
assert_equal(len(hits), 2)
assert_equal(t.n_rows(), 24)
```
