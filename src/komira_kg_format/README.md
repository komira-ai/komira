# `komira_kg_format`

## Responsibility

The values and on-disk formats that the data-graph writer and reader share. This
is parts 1 and 2 of the package described in
[the knowledge graph port](https://github.com/komira-ai/komira/blob/main/docs/design/knowledge_graph_port.md): the
packed embedding cell, the values an extractor returns, a strict JSON reader,
the snapshot manifest body, the table schemas, cosine ranking and the structured
query result. Later parts add the delta codec, the snapshot lineage store and
the exact-scan searches. The code graph
[`komira_kg_code`](https://github.com/komira-ai/komira/blob/main/src/komira_kg_code/README.md) is a different thing and is untouched.

- `embedding`: an embedding vector is one string cell holding its components as
  little-endian f32, `dim * 4` bytes with no header. The dimension lives in the
  manifest, not in the cell.
- `ingest_types`: `Triple`, `EntityMention` and `Extraction`, what an extractor
  returns for one episode, with names not yet resolved to node ids.
- `json_value`: `JsonDoc` and `JsonValue`, a small RFC 8259 reader for a model's
  response envelope and the payload inside it.
- `manifest_body`: `KgManifestBody`, the payload of one snapshot manifest chunk:
  the graph's embedding dimension and, for each table present, its object key,
  schema version and row count.
- `schemas`: the Arrow schema of each graph table (`episodes`, `entities`,
  `edges`, the delta-only `edges_tombstone` and `entities_embedding`,
  `communities`, `community_reports`), each table's schema version, and the
  open-interval sentinel for the bi-temporal end columns.
- `cosine`: `cosine` of two vectors and `cosine_topk`, the exact top-k of a
  packed-embedding string column against a query vector.
- `query_result`: `KgQueryResult`, the subgraph, findings, provenance, loci and
  scores a query returns, with a JSON wire (`serialize`, `deserialize`).

The package depends on `komira_arrow` (for schemas and string columns), reads no
clock and no environment, and no pointer crosses its API.

## API

Everything is exported from `komira_kg_format`:

- Embeddings: `pack_embedding` (f64 in, narrowed to f32), `pack_embedding_f32`
  (bit-exact), `unpack_embedding` (a `String` cell), `unpack_embedding_bytes` (a
  byte view, for a cell read off a column), `unpack_embedding_checked` (a cell
  that must hold exactly `dim` components), `EMB_F32_BYTES` and
  `DEFAULT_EMBEDDING_DIM` (1536).
- Extraction values: `Triple`, `EntityMention`, `Extraction`.
- JSON: `JsonDoc.parse` and `JsonDoc.root`, the handle `JsonValue`, the kind
  tags `JSON_NULL`, `JSON_BOOL`, `JSON_NUMBER`, `JSON_STRING`, `JSON_ARRAY`,
  `JSON_OBJECT`, and `JSON_MAX_DEPTH` (128).
- Manifest: `KgManifestBody`, `KgTableEntry`, `KG_SNAPSHOT_FORMAT_VERSION` (2)
  and `KG_SNAPSHOT_FORMAT_VERSION_MIN` (1).

- Schemas: `episodes_schema`, `entities_schema`, `edges_schema`,
  `edges_tombstone_schema`, `entities_embedding_schema`, `communities_schema`,
  `community_reports_schema`; the `SCHEMA_VERSION_*` constants (episodes is 2,
  the others 1); `EMB_DIM` (the same constant as `DEFAULT_EMBEDDING_DIM`) and
  `TS_OPEN_SENTINEL`.
- Cosine: `cosine`, `cosine_topk` and the `Hit` it returns.
- Query result: `KgQueryResult`, `ResultNode`, `ResultEdge`, `ResultFinding`,
  `ProvenanceEntry`, `Locus`, `ScoreEntry`, `SEV_INFO`, `SEV_WARN`, `SEV_ERROR`
  and `KG_QUERY_RESULT_FORMAT_VERSION` (1).

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
with assert_raises(contains="needs 16"):
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

var body = KgManifestBody(768, List[KgTableEntry]())
body.add_table("edges", "objects/1f3a", 1, 40)
body.check_embedding_dim(768)
with assert_raises(contains="does not match the graph's 768"):
    body.check_embedding_dim(1536)

var decoded = KgManifestBody.decode(body.encode())
assert_equal(decoded.format_version, KG_SNAPSHOT_FORMAT_VERSION)
assert_equal(decoded.embedding_dim, 768)
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

var bytes = KgManifestBody().encode()
bytes.append(0)
with assert_raises(contains="trailing bytes"):
    _ = KgManifestBody.decode(bytes)
```

JSON is parsed once and navigated by key and index. A malformed text is an
error:

<!-- mojo-hidden
from std.testing import assert_equal, assert_raises, assert_true
-->
```mojo
from komira_kg_format import JsonDoc

var doc = JsonDoc.parse('{"entities":[{"name":"Ada","score":0.5}],"ok":true}')
var root = doc.root()
assert_true(root.get("ok").as_bool())
var first = root.get("entities").at(0)
assert_equal(first.get("name").as_string(), "Ada")
assert_equal(first.get("score").as_float(), 0.5)

with assert_raises(contains="unexpected char"):
    _ = JsonDoc.parse('{"a":}')
```

The extraction values hold names, not node ids; the ingest step resolves them:

<!-- mojo-hidden
from std.testing import assert_equal
-->
```mojo
from komira_kg_format import EntityMention, Extraction, Triple

var entities = List[EntityMention]()
entities.append(EntityMention("Ada", "person", ""))
var triples = List[Triple]()
triples.append(Triple("Ada", "wrote", "notes", "Ada wrote notes", 0, 9223372036854775807))
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
    DEFAULT_EMBEDDING_DIM,
    EMB_DIM,
    SCHEMA_VERSION_EPISODES,
    edges_schema,
    entities_schema,
)

var e = entities_schema()
assert_equal(e.num_columns(), 7)
assert_equal(e.field_name(4), "name_embedding")
assert_true(e.field_arrow_type(4) == ArrowType.LARGE_STRING)
assert_equal(edges_schema().num_columns(), 12)
assert_equal(SCHEMA_VERSION_EPISODES, Int64(2))
assert_equal(EMB_DIM, DEFAULT_EMBEDDING_DIM)
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
a version the reader does not know is refused:

<!-- mojo-hidden
from std.testing import assert_equal, assert_raises, assert_true
-->
```mojo
from komira_kg_format import (
    KgQueryResult,
    ResultNode,
    ScoreEntry,
)

var r = KgQueryResult("retain_and_query", "who knows Ada?")
r.add_node(ResultNode(7, "Ada", "person", 0.5))
r.add_score(ScoreEntry("cosine", 7, 0.5))
assert_true(r.is_non_trivial())

var back = KgQueryResult.deserialize(r.serialize())
assert_equal(back.nodes[0].label, "Ada")
assert_equal(back.scores[0].value, 0.5)
assert_equal(back.serialize(), r.serialize())

with assert_raises(contains="> reader-supported 1"):
    _ = KgQueryResult.deserialize(
        '{"v":2,"mode":"m","query_label":"l"}'
    )
```

## Limits

A manifest decodes in memory: the body is read whole and a table count larger
than the bytes can hold is refused before anything is allocated. The JSON reader
copies its input, accepts nesting up to 128 levels and is meant for kilobyte
bodies, not streams. Embeddings are stored as f32 whatever precision the caller
computes in.

`cosine_topk` is a brute-force scan: O(rows) to score and O(rows * k) to select,
with no index, so it is for columns of thousands of rows, not millions. It
compares the overlapping prefix of the query and a row, so a row of another
dimension is scored on its first components and not refused; a caller that
needs equal dimensions checks the manifest's first. The schemas' open-interval
sentinel, `TS_OPEN_SENTINEL`, is 999999999999: above any epoch-second time, but
a date in 2001 when read as milliseconds or microseconds, so a writer that
stamps in those units tests for the sentinel instead of relying on
`invalid_at > T`. A query result's wire writes a non-finite score as 0.0 because
JSON has no NaN or infinity.
