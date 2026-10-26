# `komira_kg_format`

## Responsibility

The values and on-disk formats that the data-graph writer and reader share. This
is parts 1 to 4 of the package described in
[the knowledge graph port](https://github.com/komira-ai/komira/blob/main/docs/design/knowledge_graph_port.md): the
packed embedding cell, the values an extractor returns, the snapshot manifest
body, the table schemas, cosine ranking, the structured query result, the delta
layer over a base snapshot, the fingerprints of ingested sources and the snapshot
lineage store. A later part adds the exact-scan searches. The code graph
[`komira_kg_code`](https://github.com/komira-ai/komira/blob/main/src/komira_kg_code/README.md) is a different thing and is untouched.

- `embedding`: an embedding vector is one string cell holding its components as
  little-endian f32, `dim * 4` bytes with no header. The dimension lives in the
  manifest, not in the cell, and the writer supplies it: there is no default.
- `ingest_types`: `Triple`, `EntityMention` and `Extraction`, what an extractor
  returns for one episode, with names not yet resolved to node ids.
- `manifest_body`: `KgManifestBody`, the payload of one snapshot manifest chunk:
  the graph's embedding dimension and, for each table present, its object key,
  schema version and row count.
- `schemas`: the Arrow schema of each graph table (`episodes`, `entities`,
  `edges`, the delta-only `edges_tombstone` and `entities_embedding`,
  `communities`, `community_reports`), each table's schema version, and the
  open-interval sentinel for the bi-temporal end columns. A row's partition is
  an opaque `partition_id` and an episode carries an opaque `facet` string. No
  schema fixes an embedding dimension: the writer chooses it and the manifest
  records it.
- `cosine`: `cosine` of two vectors and `cosine_topk`, the exact top-k of a
  packed-embedding string column against a query vector.
- `query_result`: `KgQueryResult`, the subgraph, annotations, provenance, loci
  and scores a query returns, with a JSON wire (`serialize`, `deserialize`).
- `delta_body`: the chunk bodies of the delta layer: `KgDeltaBody` (one ingest's
  diff: the delta object of each changed table and the exact-name index entries
  it adds), `KgChainBody` (the head: the base's chunk and the delta chunks in
  apply order) and `kg_chunk_is_chain_head`.
- `delta_codec`: the delta object, the rows one table gained in one ingest. A
  few rows are a compact framed blob, more are a Parquet file; a tag byte says
  which, and both decode.
- `source_fingerprint`: the change gate. `SourceFingerprintSet` holds the hash of
  what was last ingested from each `(partition_id, source)`,
  `SourceFingerprintStore` keeps it in an append-only lineage next to the
  snapshots, and `content_hash_of` and `content_hash_of_extraction` compute the
  hash.
- `chunk_kind`: `kg_chunk_kind` tells a base, a chain head and a delta apart by
  the format version at the start of the chunk body, never by position or size.
- `snapshot_store`: `KgSnapshotStore`, the lineage of one graph on a
  conditional-write object store. It writes a base snapshot (one Parquet object
  per table, named by the hash of its bytes, and a manifest chunk), appends
  deltas over the head, folds a chain into a fresh base, retires the folded
  deltas and keeps the fingerprint lineage. A write that loses a
  compare-and-set race is retried within a bound and the loss is reported. It
  reads no clock: where time matters the caller passes it. `KgTable` is one
  table to write.
- `snapshot_view`, `chain_view`: `SnapshotView` (a resolved base: its manifest
  body and a handle that fetches its table objects) and `ChainView` (a resolved
  chain: the base view, the deltas in apply order and their chunk numbers). Both
  keep reading after the store that made them is gone.
- `compaction_policy`: `CompactionPolicy`, the count-or-size rule for when a
  chain is worth folding.

The package depends on `komira_arrow` (for schemas and string columns),
`komira_json` (for the query result's wire), `komira_hash`,
`komira_objectstore` (the snapshot and fingerprint lineages), `komira_collections`
(the `Slab` a write takes its tables in) and `komira_parquet_writer` (the Parquet
objects), reads no clock and no environment, and no pointer crosses its API.

## API

Everything is exported from `komira_kg_format`:

- Embeddings: `pack_embedding` (f64 in, narrowed to f32), `pack_embedding_f32`
  (bit-exact), `unpack_embedding` (a `String` cell), `unpack_embedding_bytes` (a
  byte view, for a cell read off a column), `unpack_embedding_checked` (a cell
  that must hold exactly `dim` components), and the byte width `EMB_F32_BYTES`.
- Extraction values: `Triple`, `EntityMention`, `Extraction`.
- Manifest: `KgManifestBody`, `KgTableEntry`, `KG_SNAPSHOT_FORMAT_VERSION` (2,
  the only layout the decoder accepts).

- Schemas: `episodes_schema`, `entities_schema`, `edges_schema`,
  `edges_tombstone_schema`, `entities_embedding_schema`, `communities_schema`,
  `community_reports_schema`; the `SCHEMA_VERSION_*` constants (all 1) and
  `TS_OPEN_SENTINEL`.
- Cosine: `cosine`, `cosine_topk` and the `Hit` it returns.
- Query result: `KgQueryResult`, `ResultNode`, `ResultEdge`,
  `ResultAnnotation`, `ProvenanceEntry`, `Locus`, `ScoreEntry` and
  `KG_QUERY_RESULT_FORMAT_VERSION` (2).
- Delta layer: `KgDeltaBody`, `KgDeltaTableEntry`, `KgNameIndexBody`,
  `KgNameIndexEntry`, `KgChainBody`, `kg_chunk_is_chain_head` and
  `KG_CHAIN_FORMAT_VERSION` (3) and `KG_DELTA_FORMAT_VERSION` (4); with the
  manifest's 2 every chunk kind has its own version, so the first eight bytes
  tell the three apart and no body of one kind decodes as another.
- Delta objects: `encode_delta_table_object`, `delta_object_is_framed`,
  `delta_object_parquet_bytes`, `decode_framed_delta_to_batch`, `framed_object_size`,
  `framed_size_is_decodable` (a delta whose framed form would exceed what the
  decoder accepts is written as Parquet) and the constants
  `FRAMED_MAX_ROWS`, `FRAME_TAG_FRAMED`, `FRAME_TAG_PARQUET`,
  `FRAMED_CODEC_VERSION`.
- Fingerprints: `SourceFingerprint`, `SourceFingerprintSet`,
  `SourceFingerprintStore[Store]`, `content_hash_of`,
  `content_hash_of_extraction`, `fnv1a64_hex` and
  `KG_FINGERPRINT_FORMAT_VERSION` (1).
- Chunk kinds: `kg_chunk_kind` and `KG_CHUNK_BASE`, `KG_CHUNK_CHAIN`,
  `KG_CHUNK_DELTA`.
- Lineage store: `KgSnapshotStore[Store]` and `KgTable`; `SnapshotView[Store]`,
  `ChainView[Store]` and `SnapshotId` (the chunk number, an `Int64`);
  `CompactionPolicy`; `DEFAULT_MAX_HEAD_ATTEMPTS` (8) and
  `PENDING_BASE_RECORD_COUNT` (0).
  - write: `write_snapshot`, `append_delta`, `write_base_tables`,
    `commit_compacted_head`, `retire_folded_delta`.
  - read: `open_latest`, `read_snapshot`, `open_latest_chain`, `read_chain`,
    `read_chain_body`, `read_delta_body`, `resolve_head_chain`,
    `latest_snapshot_id`, `head_seq`, `head_is_chain`, `chain_total_bytes`,
    `retired_age_ms`.
  - races: `lost_races`, `last_write_lost_races`.
  - change gate: `fingerprint_load`, `fingerprint_lookup`, `fingerprint_save`,
    `fingerprint_patch_save`.

## Examples

An f32 vector packs to `dim * 4` bytes and comes back exactly. An f64 vector is
narrowed to f32 on the way in, so it comes back to within the f32 rounding:

<!-- mojo-hidden
from std.testing import assert_equal, assert_raises, assert_true
-->
```mojo
from komira_kg_format import (
    pack_embedding,
    pack_embedding_f32,
    unpack_embedding,
)

var exact: List[Float32] = [1.5, -2.0, 0.0, 0.125]
var cell = pack_embedding_f32(exact)
assert_equal(cell.byte_length(), 16)
var back = unpack_embedding(cell)
assert_equal(back[0], 1.5)
assert_equal(back[3], 0.125)

var wide: List[Float64] = [0.1, 0.2, 0.3]
var rounded = unpack_embedding(pack_embedding(wide))
assert_equal(len(rounded), 3)
assert_true(abs(rounded[0] - 0.1) < 1.0e-6)
```

A reader that knows the graph's dimension holds each cell to it. A cell of
another length is an error, not a vector of the wrong size:

<!-- mojo-hidden
from std.testing import assert_equal, assert_raises
-->
```mojo
from komira_kg_format import pack_embedding_f32, unpack_embedding_checked

var v: List[Float32] = [1.0, 2.0, 3.0]
var cell = pack_embedding_f32(v)
assert_equal(len(unpack_embedding_checked(cell.as_bytes(), 3)), 3)
with assert_raises(contains="not a dimension of 4"):
    _ = unpack_embedding_checked(cell.as_bytes(), 4)
```

The manifest carries the dimension. A writer checks each vector against it, and
the body encodes to bytes and decodes back to the same version, dimension and
tables:

<!-- mojo-hidden
from std.testing import assert_equal, assert_false, assert_raises, assert_true
-->
```mojo
from komira_kg_format import (
    KG_SNAPSHOT_FORMAT_VERSION,
    KgManifestBody,
    KgTableEntry,
)

var body = KgManifestBody(3, List[KgTableEntry]())
body.add_table("edges", "objects/1f3a", 1, 40)
body.check_embedding_dim(3)
with assert_raises(contains="does not match the graph's 3"):
    body.check_embedding_dim(5)

var decoded = KgManifestBody.decode(body.encode())
assert_equal(decoded.format_version, KG_SNAPSHOT_FORMAT_VERSION)
assert_equal(decoded.embedding_dim, 3)
assert_true(decoded.has_table("edges"))
assert_false(decoded.has_table("episodes"))
assert_equal(decoded.resolve("edges").row_count, 40)
```

A body that is cut short, has bytes left over or names a version this build does
not know is refused whole:

<!-- mojo-hidden
from std.testing import assert_raises
-->
```mojo
from komira_kg_format import KgManifestBody

var bytes = KgManifestBody(3).encode()
bytes.append(0)
with assert_raises(contains="trailing bytes"):
    _ = KgManifestBody.decode(bytes)
```

The extraction values hold names, not node ids; the ingest step resolves them:

<!-- mojo-hidden
from std.testing import assert_equal
-->
```mojo
from komira_kg_format import EntityMention, Extraction, TS_OPEN_SENTINEL, Triple

var entities = List[EntityMention]()
entities.append(EntityMention("Ada", "person", ""))
var triples = List[Triple]()
triples.append(Triple("Ada", "wrote", "notes", "Ada wrote notes", 0, TS_OPEN_SENTINEL))
var extraction = Extraction(entities^, triples^)
assert_equal(extraction.num_entities(), 1)
assert_equal(extraction.triples[0].predicate, "wrote")
```

A schema names its columns and types, and none is nullable. The version of a
table is the constant a manifest entry records:

<!-- mojo-hidden
from std.testing import assert_equal, assert_true
-->
```mojo
from komira_arrow.arrow_types import ArrowType
from komira_kg_format import (
    SCHEMA_VERSION_EPISODES,
    edges_schema,
    entities_schema,
)

var e = entities_schema()
assert_equal(e.num_columns(), 7)
assert_equal(e.field_name(4), "name_embedding")
assert_true(e.field_arrow_type(4) == ArrowType.LARGE_STRING)
assert_equal(edges_schema().num_columns(), 12)
assert_equal(SCHEMA_VERSION_EPISODES, Int64(1))
```

`cosine` scores two vectors in [-1, 1]; a zero vector, or a result that is not
finite, scores 0.0 and never NaN. `cosine_topk` ranks a column of packed
embeddings, best first, and rows with equal scores come back lower row first:

<!-- mojo-hidden
from std.testing import assert_equal
-->
```mojo
from komira_arrow.string_array import StringArray
from komira_kg_format import cosine, cosine_topk, pack_embedding

var a: List[Float64] = [1.0, 0.0]
var b: List[Float64] = [0.0, 1.0]
assert_equal(cosine(a, a), 1.0)
assert_equal(cosine(a, b), 0.0)

var cells = List[String]()
cells.append(pack_embedding(b))
cells.append(pack_embedding(a))
cells.append(pack_embedding(a))
var hits = cosine_topk(StringArray.from_strings(cells), a, 2)
assert_equal(len(hits), 2)
assert_equal(hits[0].row, 1)
assert_equal(hits[1].row, 2)
```

A query result serializes to one JSON object and reads back to the same values;
a version other than the reader's is refused:

<!-- mojo-hidden
from std.testing import assert_equal, assert_raises, assert_true
-->
```mojo
from komira_kg_format import (
    KgQueryResult,
    ResultNode,
    ScoreEntry,
)

var r = KgQueryResult("mode-a", "which nodes match?")
r.add_node(ResultNode(7, "One", "kind-x", 0.5))
r.add_score(ScoreEntry("cosine", 7, 0.5))
assert_true(r.is_non_trivial())

var back = KgQueryResult.deserialize(r.serialize())
assert_equal(back.nodes[0].label, "One")
assert_equal(back.scores[0].value, 0.5)
assert_equal(back.serialize(), r.serialize())

with assert_raises(contains="> reader-supported 2"):
    _ = KgQueryResult.deserialize(
        '{"v":3,"mode":"m","query_label":"l"}'
    )
```

A delta body names, for each table an ingest changed, the delta object that
holds the rows it added, and the exact-name index entries it adds. A chain head
names the base chunk and the delta chunks in apply order, and a chunk's kind is
read from its version:

<!-- mojo-hidden
from std.testing import assert_equal, assert_false, assert_raises, assert_true
-->
```mojo
from komira_kg_format import (
    KgChainBody,
    KgDeltaBody,
    KgManifestBody,
    kg_chunk_is_chain_head,
)

var delta = KgDeltaBody()
delta.add_table("edges", "d/9f2c.parquet", 1, 3)
delta.add_index_entry("ada", 7)
var back = KgDeltaBody.decode(delta.encode())
assert_equal(back.resolve("edges").object_key, "d/9f2c.parquet")
assert_false(back.has_table("episodes"))
assert_equal(back.name_index.entries[0].nid, 7)

var deltas: List[Int64] = [4, 5]
var head = KgChainBody(1, deltas^).encode()
assert_true(kg_chunk_is_chain_head(head))
assert_false(kg_chunk_is_chain_head(KgManifestBody(3).encode()))
assert_equal(KgChainBody.decode(head).delta_seqs[1], 5)
```

A delta object is a framed blob for a few rows and a Parquet file for more. The
first byte says which. A framed object decodes to a batch of int64 and string
columns; a Parquet object is read with the Parquet reader. A framed object that
is cut short, or whose header claims more than its bytes hold, is refused:

<!-- mojo-hidden
from std.testing import assert_equal, assert_false, assert_raises, assert_true
-->
```mojo
from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_kg_format import (
    decode_framed_delta_to_batch,
    delta_object_is_framed,
    encode_delta_table_object,
)

var ids: List[Int64] = [10, 20]
var names: List[String] = ["ada", "grace"]
var rb = RecordBatchBuilder()
rb.add_column(
    Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(ids^))
)
rb.add_column(Column.from_string(StringArray.from_strings(names^)))
var sb = SchemaBuilder()
sb.add_field(Field("id", ArrowType.INT64, False))
sb.add_field(Field("name", ArrowType.STRING, False))

var object = encode_delta_table_object(rb.build(sb.build()))
assert_true(delta_object_is_framed(object))
var batch = decode_framed_delta_to_batch(object)
assert_equal(batch.column_as_primitive_int64(0).get(1), 20)
assert_equal(batch.column_as_string(1).get(0), "ada")

var cut = List[UInt8]()
for i in range(len(object) - 1):
    cut.append(object[i])
with assert_raises(contains="truncated"):
    _ = decode_framed_delta_to_batch(cut)
```

The change gate compares the hash of incoming content with the one stored for
its partition and source. A source never seen has no hash, which counts as
changed; the same source in another partition is a different key:

<!-- mojo-hidden
from std.testing import assert_equal, assert_not_equal
-->
```mojo
from komira_kg_format import (
    SourceFingerprintSet,
    content_hash_of,
    fnv1a64_hex,
)

assert_equal(fnv1a64_hex("a".as_bytes()), "af63dc4c8601ec8c")

var seen = SourceFingerprintSet()
seen.patch("partition-1", "doc-1", content_hash_of("first body"), "")

assert_equal(seen.lookup("partition-1", "doc-1"), content_hash_of("first body"))
assert_not_equal(seen.lookup("partition-1", "doc-1"), content_hash_of("first bodz"))
assert_equal(seen.lookup("partition-2", "doc-1"), "")  # unknown: changed
assert_equal(SourceFingerprintSet.decode(seen.encode()).num_entries(), 1)
```

The set is kept in a lineage of its own on the store that holds the snapshots. A
change loads the whole set, patches one key and saves the whole set; saving an
empty set over a stored one is refused:

<!-- mojo-hidden
from std.testing import assert_equal, assert_raises
-->
```mojo
from komira_kg_format import SourceFingerprintSet, SourceFingerprintStore
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)

var backend = SharedInMemoryConditionalStore()
var store = SourceFingerprintStore[SharedInMemoryConditionalStore](
    backend.clone(), "graph-1"
)
var fps = store.load()  # empty on a fresh lineage
fps.patch("partition-1", "doc-1", "0123456789abcdef", "")
store.save(fps^)

var again = store.load()
assert_equal(again.lookup("partition-1", "doc-1"), "0123456789abcdef")
with assert_raises(contains="refusing to replace"):
    store.save(SourceFingerprintSet())
```

The lineage store keeps a graph under a key prefix of a conditional-write store.
A base is written with the graph's embedding dimension; each delta is appended
over the head with the exact-name entries it adds, and the head then reads back as
a chain of the base and the deltas. A compactor folds a chain by writing the
folded tables as a new base (not the head yet) and committing it with the base
and deltas it folded; a chain read before the fold keeps reading. The time a
retired delta is stamped with is the caller's:

```mojo module
from std.testing import assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_collections.slab import Slab
from komira_kg_format import (
    CompactionPolicy,
    KgNameIndexBody,
    KgSnapshotStore,
    KgTable,
    delta_object_is_framed,
)
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)

comptime Kg = KgSnapshotStore[SharedInMemoryConditionalStore]


def table(first: Int, n: Int) raises -> Slab[KgTable]:
    var ids = List[Int64]()
    var names = List[String]()
    for i in range(n):
        ids.append(Int64(first + i))
        names.append("node-" + String(first + i))
    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, False))
    sb.add_field(Field("name", ArrowType.STRING, False))
    var rb = RecordBatchBuilder()
    rb.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(ids)
        )
    )
    rb.add_column(Column.from_string(StringArray.from_strings(names)))
    var tables = Slab[KgTable]()
    tables.append(KgTable("entities", rb.build(sb.build()), 1))
    return tables^


def main() raises:
    var kg = Kg(SharedInMemoryConditionalStore(), "graph-1")
    assert_equal(kg.write_snapshot(table(1, 3), 8), 0)  # embedding dimension 8

    var index = KgNameIndexBody()
    index.add("ada", 11)
    assert_equal(kg.append_delta(table(10, 2), index^), 2)
    assert_equal(kg.append_delta(table(20, 1), KgNameIndexBody()), 4)

    var chain = kg.open_latest_chain()
    assert_equal(chain.num_deltas(), 2)
    assert_equal(chain.resolve_name_index("ada"), 11)
    assert_true(delta_object_is_framed(chain.delta_object_bytes(0, "entities")))

    # Two deltas are enough for this policy to ask for a fold.
    var sizes = kg.chain_total_bytes(kg.resolve_head_chain())
    var policy = CompactionPolicy(2, 0, 0)
    assert_true(policy.should_compact(chain.num_deltas(), sizes[1], sizes[0]))

    var base = kg.write_base_tables(table(1, 6), 8)
    assert_equal(kg.latest_snapshot_id(), 4)  # the new base is not the head yet
    _ = kg.commit_compacted_head(base, chain.base_id(), chain.delta_seqs.copy())
    assert_equal(kg.open_latest_chain().num_deltas(), 0)
    assert_equal(chain.num_deltas(), 2)  # the chain read before the fold stays

    kg.retire_folded_delta(chain.delta_seqs[0], 1000)  # the caller's clock
    assert_equal(kg.retired_age_ms(chain.delta_seqs[0], 1500), 500)
```

Two handles on one lineage race for the same slot. The loser retries at the next
slot and the store says it lost:

```mojo module
from std.testing import assert_equal

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_collections.slab import Slab
from komira_kg_format import KgSnapshotStore, KgTable
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)

comptime Kg = KgSnapshotStore[SharedInMemoryConditionalStore]


def snapshot() raises -> Slab[KgTable]:
    var ids: List[Int64] = [1, 2]
    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, False))
    var rb = RecordBatchBuilder()
    rb.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(ids)
        )
    )
    var tables = Slab[KgTable]()
    tables.append(KgTable("entities", rb.build(sb.build()), 1))
    return tables^


def main() raises:
    var backend = SharedInMemoryConditionalStore()
    var a = Kg(backend.clone(), "graph-1")
    var b = Kg(backend.clone(), "graph-1")
    assert_equal(a.write_snapshot(snapshot(), 4), 0)
    assert_equal(b.write_snapshot(snapshot(), 4), 1)  # b takes a's next slot
    assert_equal(a.write_snapshot(snapshot(), 4), 2)  # a retries and wins
    assert_equal(a.last_write_lost_races(), 1)
    assert_equal(b.last_write_lost_races(), 0)
```

A delta's chain head is the one write that must be built from the head it lands
after, so `append_delta` and `commit_compacted_head` append it at exactly the
slot after the tip they read. If another chunk took the slot they read the tip
again, rebuild the chain from the head they find and try again, up to
`max_head_attempts` times, so a delta appended meanwhile is on the new chain;
running out of attempts raises an error that ends "(retryable)".

## Limits

A manifest decodes in memory: the body is read whole and a table count larger
than the bytes can hold is refused before anything is allocated. Embeddings are
stored as f32 whatever precision the caller computes in. For JSON, use
[`komira_json`](https://github.com/komira-ai/komira/blob/main/src/komira_json/README.md);
this package has no JSON reader of its own.

`cosine_topk` is a brute-force scan: O(rows) to score and O(rows * k) to select,
with no index, so it is for columns of thousands of rows, not millions. It
compares the overlapping prefix of the query and a row, so a row of another
dimension is scored on its first components and not refused; a caller that
needs equal dimensions checks the manifest's first. An open interval is marked
by `TS_OPEN_SENTINEL`, which is `Int64.MAX`: no timestamp in seconds,
milliseconds or microseconds reaches it, so `invalid_at > T` keeps an open edge
whatever unit a writer stamps in. Code that tests for an open interval compares
against the constant, never a literal. A query result's wire writes a
non-finite score as 0.0 because JSON has no NaN or infinity.

A framed delta object holds int64 and string columns with no null; a delta with
any other column, with a null, or of `FRAMED_MAX_ROWS` rows or more is written
as Parquet. `decode_framed_delta_to_batch` names the columns `c0`, `c1`, ... and
returns a LARGE_STRING column as STRING, as the Parquet reader does, so a reader
finds columns by position. A string cell is stored and returned byte for byte
and is not checked for UTF-8, because an embedding cell is packed floats. The
chunk bodies check every string they decode for UTF-8.

A content hash is a change detector, not a cryptographic digest: it does not
resist someone who chooses colliding content. Two inputs of equal length that
differ in one byte always hash differently. The fingerprint lineage keeps one
whole set per save, so two writers that load the same set, patch different keys
and save overwrite each other (the later save wins); a host that ingests one
partition from several processes serializes them.

The lineage store has one head: the newest base or chain-head chunk. A delta
chunk is written before the chain head that names it, so readers look past a
delta at the tip, and a delta whose writer stopped before the chain head stays in
the lineage unreferenced. The base a compactor writes is a base chunk with a
record count of zero; it is skipped like a delta until `commit_compacted_head`
names it, so it can never hide the deltas that arrived while the fold ran.
`commit_compacted_head` is for one compactor at a time: it refuses a fold whose
base is no longer the one under the head chain. It cannot see what the pending
base holds: it checks only that the base was written after every delta it says
was folded, and that each of those is on the head chain, so folding the deltas it
names is the compactor's duty. Reading a head also checks that a chain head's
base is a base chunk and each delta a delta chunk (one chunk read apiece), so a
corrupt chain is refused and never carried into a new head.

The deltas of a chain are in the order their chain heads landed, not the order
they were ingested. If one writer wrote delta 5 and another delta 6, and the
second one's chain head took its slot first, the chain is [6, 5] and the name
index's "later wins" follows that order, so delta 5's entry wins. No delta is
lost; the apply order between concurrent writers is decided by the race.

A handle that has written reads its own latest write from memory; a handle made
fresh lists the store. To see another handle's commits, read through a fresh
handle. Finding the head after a cold start lists the lineage and reads each
chunk, which is a cost that grows with the chunk count, so a host folds chains
and does not keep millions of chunks.

`retire_folded_delta` decides whether a delta is still on the head chain from
the store's own head, not the handle's cached tail, so a stale handle cannot
retire a delta another handle's head still names. It only stamps a folded delta's chunk; it deletes nothing. A
chunk is reclaimable only after the lineage's log start has moved past it, and
when to do that is the host's retention decision, taken against
`retired_age_ms` and a clock the host owns. Table objects are named by the
FNV-1a hash of their bytes, which detects change and is not collision resistant.
An object written by a failed write that no chunk names stays on the store.
