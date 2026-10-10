# komira_search_catalog

The durable catalog of a search index: which split files are live. It keeps one
append-only manifest per index (or per writer shard) in an object store through
`komira_objectstore`'s `CasManifestStore`, and is generic over that package's
conditional-write store traits, so it names no cloud client.

- `SplitSummary` is the record for one split (UUID, document count, byte size,
  document-id range, index, field, object key, and for a split produced by
  compaction the UUIDs it absorbed). `make_split_summary` and
  `make_merged_split_summary` build one; `encode_split_summary` and
  `decode_split_summary` are its bounds-checked binary codec.
- `SearchMetastore[Storage]` publishes a summary as the next manifest chunk
  (from then on the split is live), lists the live splits in publish order,
  retires a chunk (it leaves the live set but stays readable) and reaps a
  retired chunk once a grace period has passed. A live merged split hides the
  splits it lists as inputs, so publishing a merge and then retiring its inputs
  looks atomic to a reader. `generation()` changes on every catalog change and
  never goes down.
- Per-writer shards: `make_shard_id`, `shard_manifest_prefix`, the cross-shard
  reads `list_live_splits_across_shards` and `generation_across_shards`, and
  `reap_drained_shards`, after which a publish into a retired shard raises
  `[SHARD_RETIRED]`.

It does not write split files: the caller writes the split object first, then
publishes its summary. It does not search; `komira_search` reads splits and
`komira_search_scan` serves an index as a scan.

## Examples

The summary codec round-trips, the compaction fields included:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_search_catalog import decode_split_summary, encode_split_summary, make_merged_split_summary

var inputs = List[UInt8]()
for i in range(32):  # two absorbed 16-byte split UUIDs, back to back
    inputs.append(UInt8(i))
var merged = make_merged_split_summary(
    Array[UInt8, 16](fill=UInt8(9)), 5, 4096, 0, 4,
    "logs", "body", "index/logs/splits/m.split", 1, inputs^,
)
var back = decode_split_summary(encode_split_summary(merged))
assert_true(back.is_merged())
assert_equal(back.num_merge_inputs(), 2)
assert_equal(back.merge_input_at(1)[0], UInt8(16))
assert_equal(back.object_key, "index/logs/splits/m.split")
assert_equal(back.doc_count, 5)
```

The life of splits in one index, over the in-memory store: publish two,
publish the split that merges them (the inputs disappear from the live set at
once), then retire the inputs' chunks. Every step moves the generation:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_objectstore import CasManifestStore, RetryPolicy, SharedInMemoryConditionalStore
from komira_search_catalog import SearchMetastore, make_merged_split_summary, make_split_summary

comptime Store = SharedInMemoryConditionalStore


def split_uuid(seed: Int) -> Array[UInt8, 16]:
    return Array[UInt8, 16](fill=UInt8(seed))


var manifest = CasManifestStore[Store](Store(), "index/logs/meta", RetryPolicy.default())
var meta = SearchMetastore[Store](manifest^, "logs")
assert_equal(meta.generation(), 0)

_ = meta.publish(make_split_summary(split_uuid(1), 3, 100, 0, 2, "logs", "body", "s-1.split"))
_ = meta.publish(make_split_summary(split_uuid(2), 2, 80, 3, 4, "logs", "body", "s-2.split"))
var g_published = meta.generation()
assert_equal(len(meta.list_live_splits()), 2)

# A compactor snapshots the live set with each split's chunk number ...
var snapshot = meta.list_live_splits_with_seq()
var absorbed = List[UInt8]()
for i in range(len(snapshot)):
    for k in range(16):
        absorbed.append(snapshot[i].summary.split_uuid[k])

# ... writes the merged split, and publishes it: readers now see only it.
_ = meta.publish(
    make_merged_split_summary(split_uuid(3), 5, 150, 0, 4, "logs", "body", "m-3.split", 1, absorbed^)
)
var live = meta.list_live_splits()
assert_equal(len(live), 1)
assert_equal(live[0].object_key, "m-3.split")
var g_merged = meta.generation()
assert_true(g_merged > g_published)

# Retiring the inputs' chunks (with an explicit clock) leaves the live set as it is.
for i in range(len(snapshot)):
    meta.retire_at(snapshot[i].chunk_seq, 1_000)
assert_equal(len(meta.tombstoned_seqs()), 2)
assert_equal(len(meta.list_live_splits()), 1)
assert_true(meta.generation() > g_merged)
```
