# komira_search_compaction

Merges small search splits into larger ones. Ingest writes one small split per
request, and query latency grows with the number of splits, so this package
keeps the count bounded. It works on the catalog of
`komira_search_catalog` and the split format of
`komira_search`, and is generic over
`komira_objectstore`'s conditional-write store
traits: it names no cloud client, and a binary supplies the store.

- `select_merge` is the policy, a pure function over `MergeCandidate`s (a live
  split with its shard id and chunk sequence). At least `MERGE_FACTOR` small
  splits written by ingest trigger a merge; the plan takes the smallest first,
  at most `MAX_MERGE_FACTOR`, while their summed size stays under
  `MAX_MERGED_BYTES`. Splits that are already merged are not fed in again.
- `merge_split_bytes` re-indexes K input splits into one. It carries each
  input's typed fast-field columns forward (an integer meeting a float is
  widened to float, any other disagreement fails the merge) and re-tokenizes
  only the text field from the stored `_source`.
  `content_addressed_merge_key` names the merged object by its input UUIDs, so
  a re-run writes the same key.
- `reap_retired_split` deletes the object of a merged-away split once its grace
  period has passed.
- `compact_once` runs one pass over all of an index's lineages: snapshot,
  select, merge, write the merged object and then append its summary to the
  reserved `_base` lineage, retire the inputs in the lineage each came from,
  reap retired chunks and their objects that are past their grace period, and
  remove the writer shards that have fully drained. The object is written
  before the summary, so a reader that finds the summary finds the object.

Running one pass at a time per index is the caller's contract; the pass takes
no lock.

## Example

Selecting from candidates needs no store. Ten small splits reach the factor:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_search_catalog import make_split_summary
from komira_search_compaction import MergeCandidate, select_merge, MERGE_FACTOR

var candidates = List[MergeCandidate]()
for i in range(MERGE_FACTOR):
    var summary = make_split_summary(
        Array[UInt8, 16](fill=UInt8(i + 1)), 100, Int64(1000 * (MERGE_FACTOR - i)), 0, 99,
        "logs", "body", "index/logs/splits/s" + String(i) + ".split",
    )
    candidates.append(MergeCandidate("", Int64(i), summary^))
var plan = select_merge(candidates)
assert_true(plan.should_merge())
assert_equal(plan.num_selected(), MERGE_FACTOR)
# smallest first
assert_true(plan.selected[0].summary.byte_size <= plan.selected[1].summary.byte_size)
```
