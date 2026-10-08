# komira_shuffle

A shuffle (the exchange between a map step and a reduce step) over an object
store with conditional writes, a `komira_objectstore` `ConditionalWriteStore`.
Every key is grouped under a shuffle id and a step id.

- **Write** (`komira_shuffle.sink`): `sink_shuffle_write` assigns each
  `ShuffleRow` (a key and an opaque payload) to one of R partitions with
  `HashPartitioner` (FNV-1a 64 of the key, top bits; R must be a power of
  two), writes the producer's rows as one segment object
  `<shuffle>/<step>/<producer>.seg` with an index of every partition's slice
  (empty ones included), and commits an entry for the producer to the step's
  manifest. Writing the same producer again replaces the segment with the same
  bytes and commits nothing new.
- **Seal** (`komira_shuffle.seal_driver`): `seal_step` checks that the set of
  committed producers equals the expected set and only then writes the seal;
  a missing producer raises and nothing is sealed.
- **Read** (`komira_shuffle.source`): `read_shuffle_partition` is the only
  read path. It waits for the seal (a bounded number of retries, then raises),
  refuses a seal whose producer set differs from the expected one, and returns
  the partition's bytes from every producer; `decode_partition_payloads`
  splits them back into payloads. A partition no producer wrote returns empty
  at once.
- **Claim** (`komira_shuffle.claim`): `claim_partition` is a create-if-absent
  write, so of several reducers asking for one partition exactly one wins.
- **Retention** (`komira_shuffle.retention`): `reclaim_floor` is the lowest
  epoch any consumer still needs (it refuses an empty consumer set), and
  `reap_epoch` / `reap_epochs_below` delete what lies below it.

The package root re-exports nothing; import from the modules. It does not run
producers or reducers, schedule work or move data between machines itself:
the callers do, and the store is the only shared state.

## Examples

Two producers write 6 rows into 4 partitions of an in-memory store; the step
is sealed and every partition is read back, and each row comes back exactly
once:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_objectstore.shared_in_memory_conditional_store import SharedInMemoryConditionalStore
from komira_shuffle.partitioner import HashPartitioner
from komira_shuffle.seal_driver import seal_step
from komira_shuffle.sink import ShuffleRow, sink_shuffle_write
from komira_shuffle.source import decode_partition_payloads, read_shuffle_partition

def as_bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for b in s.as_bytes():
        out.append(b)
    return out^

def as_string(b: List[UInt8]) -> String:
    var out = String()
    for i in range(len(b)):
        out += chr(Int(b[i]))  # the payloads here are ASCII
    return out^

var store = SharedInMemoryConditionalStore()
var shuffle_id = Int64(1)
var step_id = Int64(0)
var partitions = Int64(4)
var producers = List[Int64]()
producers.append(0)
producers.append(1)

for p in range(2):
    var rows = List[ShuffleRow]()
    for j in range(3):
        var name = "p" + String(p) + "-row" + String(j)
        rows.append(ShuffleRow(as_bytes("key-" + name), as_bytes(name)))
    _ = sink_shuffle_write(store, shuffle_id, step_id, Int64(p), partitions, rows)

var seal = seal_step(store, shuffle_id, step_id, partitions, producers)
assert_equal(len(seal.committed_producers), 2)

var seen = List[String]()
for part in range(Int(partitions)):
    var body = read_shuffle_partition(store, shuffle_id, step_id, Int64(part), producers)
    var payloads = decode_partition_payloads(body)
    for i in range(len(payloads)):
        seen.append(as_string(payloads[i]))
        # Each row is in the partition its key hashes to.
        var key = as_bytes("key-" + as_string(payloads[i]))
        assert_equal(HashPartitioner(partitions).partition_for(key), part)
assert_equal(len(seen), 6)
for p in range(2):
    for j in range(3):
        assert_true(("p" + String(p) + "-row" + String(j)) in seen)
```

A step is not readable until every expected producer has committed and the
step is sealed:

<!-- mojo-hidden from std.testing import assert_true -->
```mojo
from komira_objectstore.shared_in_memory_conditional_store import SharedInMemoryConditionalStore
from komira_shuffle.claim import claim_partition
from komira_shuffle.retention import reclaim_floor
from komira_shuffle.seal_driver import seal_step
from komira_shuffle.sink import ShuffleRow, sink_shuffle_write
from komira_shuffle.source import read_shuffle_partition

var store = SharedInMemoryConditionalStore()
var expected = List[Int64]()
expected.append(0)
expected.append(1)
var rows = List[ShuffleRow]()
rows.append(ShuffleRow(List[UInt8](length=1, fill=7), List[UInt8](length=2, fill=9)))
_ = sink_shuffle_write(store, Int64(2), Int64(0), Int64(0), Int64(2), rows)

# Not sealed: the read gives up after its retries instead of reading a partial set.
var unsealed = False
try:
    _ = read_shuffle_partition(store, Int64(2), Int64(0), Int64(0), expected, max_park_iters=2)
except:
    unsealed = True
assert_true(unsealed)

# Producer 1 never committed: the seal is refused.
var torn = False
try:
    _ = seal_step(store, Int64(2), Int64(0), Int64(2), expected)
except e:
    torn = "missing producer" in String(e)
assert_true(torn)

# Of two reducers claiming partition 0, only the first wins.
assert_true(claim_partition(store, Int64(2), Int64(0), Int64(0)))
assert_true(not claim_partition(store, Int64(2), Int64(0), Int64(0)))

# The slowest consumer decides what may be reclaimed.
var cursors = List[Int64]()
cursors.append(5)
cursors.append(3)
cursors.append(9)
assert_true(reclaim_floor(cursors) == 3)
```
