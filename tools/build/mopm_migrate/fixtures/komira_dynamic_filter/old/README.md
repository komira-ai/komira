# komira_dynamic_filter

Bloom, range, IN-list and constant filters and the selectivity tracker.

These are the filters a hash join builds from its build-side keys and applies
to the probe side, cheapest first. The package root re-exports nothing; import
each name from its module:

- `komira_dynamic_filter.constant_filter`: `ConstantFilter`, for a build side
  with one distinct key: one equality compare per row.
- `komira_dynamic_filter.in_list_filter`: `InListFilter`, an exact set of at
  most `IN_LIST_THRESHOLD` (128) distinct `Int64` keys; `try_from_int64`
  returns `None` for an empty key list or one with more than 128 distinct
  keys.
- `komira_dynamic_filter.range_filter`: `RangeFilter`, an inclusive
  `[min, max]` over `Int64` keys.
- `komira_dynamic_filter.bloom_filter`: `BloomFilter`, a Parquet split block
  Bloom filter (32-byte blocks, eight salted bits per key, xxHash64 by
  default, FNV-1a for legacy files, and a Fibonacci hash shared with the join
  hash table). It can report a key that was never inserted, never miss one
  that was. Its size is a power of two between 32 bytes and 128 MiB.
- `komira_dynamic_filter.selectivity_tracker`: `SelectivityTracker`, which
  pauses a filter that passes too many rows, with a backoff that doubles on
  each pause, up to 64 times `BACKOFF_BASE` batches.

## Examples

The exact filters:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from komira_dynamic_filter.constant_filter import ConstantFilter
from komira_dynamic_filter.in_list_filter import InListFilter
from komira_dynamic_filter.range_filter import RangeFilter

var keys: List[Int64] = [3, 5, 5, 9]

var in_list = InListFilter.try_from_int64(keys)
assert_equal(in_list.value().size(), 3)  # distinct keys
assert_true(in_list.value().contains_int64(5))
assert_false(in_list.value().contains_int64(4))
assert_false(Bool(InListFilter.try_from_int64(List[Int64]())))  # empty: no filter
var many = List[Int64]()
for k in range(129):
    many.append(Int64(k))
assert_false(Bool(InListFilter.try_from_int64(many)))  # over the threshold

var bounds = RangeFilter.try_from_int64(keys)
assert_equal(bounds.value().min_int64(), 3)
assert_equal(bounds.value().max_int64(), 9)
assert_true(bounds.value().contains_int64(4))  # in range, though not a key
assert_false(bounds.value().contains_int64(10))

var one = ConstantFilter(42)
assert_true(one.matches_int64(42))
assert_false(one.matches_int64(41))
assert_false(ConstantFilter(42, has_null=True).matches_int64(42))  # NULL joins nothing
```

A Bloom filter never misses an inserted key. Two filters of the same size
combine with `merge_or_range`:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_dynamic_filter.bloom_filter import BloomFilter

var evens = BloomFilter.create(1000)
assert_equal(evens.num_bytes, 1024)  # the next power of two
for k in range(100):
    evens.insert_int64(Int64(2 * k))
for k in range(100):
    assert_true(evens.might_contain_int64(Int64(2 * k)))

var false_positives = 0
for k in range(1000):
    if evens.might_contain_int64(Int64(1_000_000 + k)):
        false_positives += 1
# A false positive is possible; with 100 keys in 1024 bytes none of these
# 1000 absent keys is one.
assert_equal(false_positives, 0)

var odds = BloomFilter.create(1000)
for k in range(100):
    odds.insert_int64(Int64(2 * k + 1))
var both = evens.copy()
both.merge_or_range(odds, 0, both.num_bytes)
for k in range(200):
    assert_true(both.might_contain_int64(Int64(k)))

# Sized for 1000 keys at a 1% false-positive rate: 1210 bytes, rounded up.
assert_equal(BloomFilter.with_ndv_fpp(1000, 0.01).num_bytes, 2048)
```

A filter that passes every row of its first batch is paused for
`BACKOFF_BASE` (10) batches; one that prunes well over a window of
`CHECK_WINDOW_DEFAULT` (6) batches stays on:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from komira_dynamic_filter.selectivity_tracker import BLOOM_SELECTIVITY_THRESHOLD, SelectivityTracker

var tracker = SelectivityTracker(BLOOM_SELECTIVITY_THRESHOLD)
assert_true(tracker.should_apply())
tracker.record(input_rows=100, output_rows=100)  # pruned nothing
assert_true(tracker.is_paused())

var skipped = 0
while not tracker.should_apply():
    skipped += 1
assert_equal(skipped, 10)

for _ in range(6):
    tracker.record(input_rows=100, output_rows=10)  # 10% pass
assert_false(tracker.is_paused())
assert_equal(tracker.pause_multiplier, 1)  # the backoff resets
```
