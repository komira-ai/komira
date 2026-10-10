# komira_objectstore

A vendor-neutral object-storage layer, with no network code of its own:

- `Path` (a normalized `/`-delimited key; leading and doubled slashes are
  folded, `.` and `..` segments are refused) and `parse` for object URIs
  (`s3://`, `gs://`, `az://`, `abfs://`, `file://`) into a scheme, an
  authority (bucket or account) and a path.
- The value types every backend shares: `ObjectMeta`, `GetRange` (bounded,
  offset or suffix), `RangeSet`, `ListResult`, `WritePrecondition`
  (create-if-absent, If-Match) and `StoreError`.
- The traits a backend conforms to: `ObjectStore` (head, delimiter listing),
  `ConditionalWriteStore` (put, get, ranged get, delete, conditional put and
  compare-and-swap by etag), and the async CAS seam.
- `plan_coalesce`, which merges nearby byte ranges into fewer requests under a
  `CoalescePolicy` (largest gap to bridge, largest single request) and
  records where each original range lands in the merged buffers.
- The CAS manifest: an ordered sequence of immutable chunks under a key
  prefix, each appended by create-if-absent so every slot has exactly one
  winner, behind a mutable head object, with a per-entry lifecycle (staged,
  published, scheduled for delete); its `MetadataStore` trait, key and codec
  helpers.
- Conformers that need no network: `InMemoryConditionalStore` (and shared,
  slow and latency-injecting variants, for tests) and
  `LocalFsConditionalStore` over a local directory.

The S3, GCS and Azure backends are packages of their own (for example
`komira_objectstore_s3`).

## Examples

Keys and URIs:

<!-- mojo-hidden from std.testing import assert_equal, assert_true, assert_false -->
```mojo
from komira_objectstore import Path, parse

var u = parse("s3://my-bucket/warehouse/sales/part-0.parquet")
assert_true(u.scheme.is_s3())
assert_true(u.scheme.is_remote())
assert_equal(u.authority, "my-bucket")
assert_equal(u.path.raw(), "warehouse/sales/part-0.parquet")
assert_false(u.path.is_dir())

assert_equal(Path.parse("//a//b///c").raw(), "a/b/c")
assert_true(Path.parse("a/b/").is_dir())
var refused = False
try:
    _ = Path.parse("a/../b")
except:
    refused = True
assert_true(refused)
```

Conditional writes against the in-memory store, the same contract the cloud
backends keep (create-if-absent, compare-and-swap on the etag):

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_objectstore import InMemoryConditionalStore, Path, WritePrecondition

var store = InMemoryConditionalStore()
var key = Path.parse("manifests/head")
var v1: List[UInt8] = [1, 2, 3]
var meta = store.conditional_put(key, v1, WritePrecondition.if_none_match_star())
assert_equal(meta.size, 3)

var message = String()
try:  # a second create-if-absent loses
    _ = store.conditional_put(key, v1, WritePrecondition.if_none_match_star())
except e:
    message = String(e)
assert_true("precondition (412)" in message)

var v2: List[UInt8] = [4, 5]
var meta2 = store.compare_and_swap(key, v2, meta.etag)  # the etag still matches
assert_true(meta2.etag != meta.etag)
message = String()
try:  # the old etag no longer matches
    _ = store.compare_and_swap(key, v1, meta.etag)
except e:
    message = String(e)
assert_true("etag mismatch" in message)

var now = store.get(key)
assert_equal(len(now), 2)
assert_equal(now[0], 4)
assert_equal(store.get_range(key, 1, 1)[0], 5)
assert_equal(len(store.list_with_delimiter(Path.parse("manifests/")).objects), 1)
```

Coalesce three reads into two requests: the first two are 100 bytes apart and
merge, the third is too far away:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_objectstore import CoalescePolicy, GetRange, RangeSet, plan_coalesce

var ranges = RangeSet.empty()
ranges.append(GetRange.bounded(0, 100), 0)        # destination offset 0
ranges.append(GetRange.bounded(200, 300), 100)
ranges.append(GetRange.bounded(10_000, 10_050), 200)
var policy = CoalescePolicy(max_gap_bytes=1024, max_request_bytes=1 << 20, max_concurrency=8)
var plan = plan_coalesce(ranges, policy)
assert_equal(plan.num_requests(), 2)
assert_equal(plan.coalesced[0].start, 0)
assert_equal(plan.coalesced[0].end, 300)
assert_equal(plan.coalesced[1].start, 10_000)
assert_equal(plan.total_requested_bytes, 250)
assert_equal(plan.wasted_bytes(), 100)  # the gap fetched to save a request
```
