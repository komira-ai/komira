# komira_cdc_ingest

Change-data-capture ingest into an Apache Iceberg table. A change stream
(`komira_snapshotter`'s `MultiShardChangeStreamListener`) is tailed shard by
shard, and each polled `ChangeBatch` is applied to the table with `komira_iceberg`
as ONE atomic commit:

- INSERT appends the new row;
- MODIFY equality-deletes the key and appends the new row;
- REMOVE equality-deletes the key.

Records of one batch are coalesced per primary key to their net effect, so an
INSERT then a MODIFY of one key is a single append, and an INSERT then a REMOVE
writes no row.

## Exactly once without a checkpoint store

The last-applied sequence number of every shard is stamped into the snapshot
`summary` of the same commit that carries the data (`cdc.shard.<ShardId>`). On
the next pass the resume point is read back from the latest snapshot, with
`derive_positions_from_table` or inside `run_ingest_pass`. A crash after a commit
finds the position already in the table and skips the replayed records; a crash
before a commit re-applies the batch from the last committed position.

`apply_batch` advances the caller's `ShardPositions` only after its commit
succeeds. If the commit raises (a lost compare-and-swap, a store error), the
positions are unchanged and the same batch can be applied again.

One ingest process writes a table: the driver polls the shards one after
another. Concurrent writers to the table are ordered by the Iceberg
compare-and-swap on the metadata file, and a writer that loses it gets an error
from `apply_batch`.

Sequence numbers are bare decimal strings that may exceed Int64 and are not
zero-padded, so `seq_gt` orders them by numeric magnitude.

## Examples

```mojo
from komira_cdc_ingest import ShardPositions, seq_gt
from komira_iceberg import SummaryKV
from std.testing import assert_equal, assert_true, assert_false

# A shorter number can be the larger one.
assert_true(seq_gt("100", "9"))
assert_false(seq_gt("9", "100"))
assert_true(seq_gt("17", ""))  # nothing committed yet: every record applies

var positions = ShardPositions()
positions.set("shard-1", "100")
positions.set("shard-2", "7")
positions.set("shard-1", "250")  # advancing a shard replaces its position
assert_equal(positions.num_shards(), 2)
assert_equal(positions.get("shard-1"), "250")
assert_equal(positions.get("shard-9"), "")  # an unseen shard cold-starts

# The map is what each commit stamps into the snapshot summary, and what a
# restart recovers from it.
var kvs = positions.to_summary_kvs()
assert_equal(kvs[0].key, "cdc.shard.shard-1")
var recovered = ShardPositions.from_summary_kvs(kvs)
assert_equal(recovered.get("shard-2"), "7")
```

Applying a batch to a table, here over the in-memory store:

```mojo
from komira_cdc_ingest import CdcApplyConfig, ShardPositions, apply_batch
from komira_iceberg import (
    ICE_T_LONG,
    ICE_T_STRING,
    IcebergSchema,
    IcebergTableWriter,
    RowCell,
    gen_table_uuid,
    make_long_cell,
    make_string_cell,
)
from komira_objectstore.in_memory_conditional_store import InMemoryConditionalStore
from komira_snapshotter.change_stream_trait import (
    ChangeBatch,
    ChangeRecord,
    make_insert_record,
    make_remove_record,
)
from std.testing import assert_equal, assert_true

def row(id: Int64, name: String) -> List[RowCell]:
    return [make_long_cell(id), make_string_cell(name)]

var schema = IcebergSchema(0)
schema.add("id", ICE_T_LONG, required=True)
schema.add("name", ICE_T_STRING, required=True)
var key_field_ids: List[Int] = [1]  # the equality-delete key is the id column
var config = CdcApplyConfig(schema.copy(), key_field_ids^)

var writer = IcebergTableWriter[InMemoryConditionalStore](
    InMemoryConditionalStore(), "warehouse/db/t", schema.copy(), gen_table_uuid()
)

var records = List[ChangeRecord]()
records.append(make_insert_record(row(1, "k"), row(1, "alice"), "101"))
records.append(make_insert_record(row(2, "k"), row(2, "bob"), "102"))
records.append(make_remove_record(row(2, "k"), row(2, "bob"), "103"))
var batch = ChangeBatch(records^, "next", False)

var positions = ShardPositions()
var stats = apply_batch(writer, config, "shard-1", batch^, positions)
assert_true(stats.committed)
assert_equal(stats.appended, 1)  # id 2 was inserted and removed: no row
assert_equal(positions.get("shard-1"), "103")

var live = writer.read_live_rows()
assert_equal(len(live), 1)
assert_equal(live[0][1].as_string(), "alice")
```
