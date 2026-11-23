# iceberg_catalog

An Iceberg catalog client: it resolves `namespace.table` to the object-store
location of the table's current `metadata.json`, loads a table's metadata,
creates tables, and commits an append or an overwrite to a table through the
customer's REST catalog. Its write sink (`write_table`) writes Arrow batches
as the table's Parquet data files, a manifest and a manifest list in an object
store, and commits them. The committer itself writes no files: the
`AppendSnapshotWriter` it is given writes the manifest list. The package does
not read a table's data.

## Resolving a table

One seam, `IcebergCatalog.load_table(namespace, table) -> ResolvedTable`, with
two implementations:

- `StorageBasedCatalog`: an in-memory map from a (namespace, table) pair to
  the metadata location the caller registered last for it. Namespace and table
  are compared separately, so `a.b`/`c` and `a`/`b.c` are different tables. No
  network.
- `IcebergRestCatalog[T, P]`: the standard Iceberg REST protocol. On the first
  request it reads `GET /v1/config` once and caches what it needs from it (a
  failed read is not cached):
  - the merged `defaults` and `overrides` string members (overrides win),
    including the catalog `prefix`; a non-empty `warehouse` given to the
    constructor is sent as the percent-encoded `warehouse` query of that
    request;
  - the top-level `endpoints` list, when present: a request to an endpoint it
    does not list is refused with `ICEBERG_CATALOG_ENDPOINT_UNSUPPORTED` before
    it is sent, and an `endpoints` that is not an array is
    `ICEBERG_CATALOG_RESPONSE_INVALID`. Entries that are not strings are
    ignored. With `endpoints` omitted every endpoint is allowed;
  - whether the top level has `idempotency-key-lifetime`
    (`supports_idempotency`). A member of that name inside `defaults` or
    `overrides` does not count.

  Each load then reads `GET /v1/{prefix}/namespaces/{ns}/tables/{table}` with
  the namespace and table percent-encoded. `load_table` returns the
  `metadata-location`, the table's `metadata` object re-serialized as JSON text,
  and the per-table string `config`; `load_table_metadata` returns the same
  with the metadata parsed into a typed `TableMetadata` (format version, uuid,
  schemas, properties, snapshots, the `main` snapshot).

## Creating and committing

- `create_table(namespace, CreateTableRequest)` posts a createTable, staged
  (`stage_create`: nothing is created, the answer has no `metadata-location`)
  or direct. A 409 is `ICEBERG_TABLE_ALREADY_EXISTS`.
- `commit_table(namespace, table, body, idempotency_key)` posts a commit
  (`commit_table_body` builds the body from `TableRequirement`s and
  `TableUpdate`s). Every POST carries `Content-Type: application/json` and,
  when the key is non-empty, `Idempotency-Key`. The answer is a
  `CommitResponse`, not a raise: `COMMIT_APPLIED` for a 200 (with the new
  metadata), `COMMIT_CONFLICT` for a 409, `COMMIT_UNKNOWN` for any 5xx, a
  transport error or a 200 whose body cannot be read, `COMMIT_REFUSED` for any
  other status.
- `commit_append(catalog, writer, clock, ids, AppendCommit)` commits one
  statement's append, or with `AppendCommit.overwrite` its overwrite of every
  row of `main`: it loads the base, checks the table uuid, format version
  2 and the written columns, has the writer write the manifest list, and posts
  `assert-table-uuid`, `assert-ref-snapshot-id(main)` and
  `assert-current-schema-id` with `add-snapshot` and `set-snapshot-ref(main)`.
  An append's snapshot has operation `append` and the parent's `total-*`
  counters plus what it added; an overwrite's has operation `overwrite`,
  `deleted-data-files`, `deleted-records` and `removed-files-size` equal to the
  parent's `total-data-files`, `total-records` and `total-files-size` (each
  omitted when the parent lacks it), and `total-*` counters equal to what it
  added, with 0 delete counters. With no files an append sends nothing; an
  overwrite of a table that has a `main` snapshot still commits, and the
  table is empty. It retries a 409 on the new base within the table's `commit.retry.*`
  budget (never when the statement read its target), resends an unknown
  outcome once under the same idempotency key when the catalog honours keys,
  looks its commit up by snapshot id and by the `komira.commit-id` summary
  member before it decides, and never raises: the outcome says whether it
  committed, which snapshot landed, whether the caller may delete the
  statement's files, and which manifest lists to delete. Waits go through the
  `CommitClock` (`ManualCommitClock` records them and sleeps none), ids through
  `CommitIds` (`SequenceCommitIds` for tests).
- Not here: the staged-create and replace committers, OAuth2 and SigV4
  credentials, vended credentials, multi-level namespaces.

## Writing a table

`write_table(catalog, files, clock, ids, namespace, table, batches, overwrite,
pinned_snapshot_ids)` is one statement's write into an existing table. It never
raises: the `TableWriteOutcome` has `committed`, `message` (starting with its
token), the rows and files committed, the committer's ids and counts, the
URIs deleted and the deletes that failed. In order, it:

1. loads the table; only format version 2 is written;
2. maps each batch to the table's current schema by position: the same number
   of columns, and each column's Iceberg type (boolean, int, long, float,
   double, string or date) equal to the table field's;
3. takes the data path from `write.data.path`, else `<location>/data`, and the
   metadata path from `write.metadata.path`, else `<location>/metadata`; a
   path that is not under `<location>/` is refused;
4. takes the Parquet codec from `write.parquet.compression-codec` (zstd,
   snappy, gzip, uncompressed or lz4), else zstd;
5. writes one data file `<data path>/<uuid>-<i>.parquet` for each batch `i`
   that has rows, with the table's field ids on its columns, the table's
   `required` flags, and per-column counts and bounds in its manifest entry;
6. has `StoreSnapshotWriter` write the statement's manifest
   (`<metadata path>/<uuid>-m0.avro`, once, with inherited sequence numbers)
   and, for each attempt, a manifest list
   (`<metadata path>/snap-<snapshot id>-<attempt>-<uuid>.avro`): an append
   lists the manifests of the base's `main` snapshot, then the new one; an
   overwrite lists only the new one, and none when there are no files. An
   append reads the base's list, so a base list that another writer wrote
   is `ICEBERG_MANIFEST_LIST_UNSUPPORTED`;
7. commits with `commit_append`, then deletes: after a definite failure the
   statement's data files and manifest, always the manifest lists the
   committer names, and after an unknown outcome nothing else. A failure
   before the commit deletes the data files already written.

`TableFiles` is the object store and the URI prefix it serves (for example
`s3://warehouse`); a URI under the prefix maps to the store key after it, and
any other URI is `ICEBERG_LOCATION_REFUSED`. The store is a
`CloneableConditionalWriteStore` (`LocalFsConditionalStore`,
`SharedInMemoryConditionalStore`, ...): the writer and the caller each hold a
handle on the same data. A store error is raised as the store raised it.

Not in this first slice: partitioned tables, decimal, timestamp, time, binary
and uuid columns, truncated string bounds, a base list another writer wrote,
DELETED manifest entries for the files an overwrite drops (they stay in the
store until the table's maintainer removes them), and rolling over a file by
size.

## Read by another engine

The tables the sink writes are plain Iceberg v2 tables, so DuckDB's iceberg
extension reads them. `iceberg_write_runner` (`iceberg_write_runner/main.mojo`)
writes three tables through `write_table` into a `LocalFsConditionalStore`
with deterministic ids (`db.appended`: two appends; `db.overwritten`: an append
and an overwrite; `db.emptied`: an append and an overwrite with no rows), puts
each table's metadata JSON at its metadata location and writes every object as
a file under `db/<table>/metadata` and `db/<table>/data`. The build action
`:iceberg_write_komira` (`iceberg_write_cases.bzl`) runs it, and
`:iceberg_readback_oracle` runs `tests/readback.sql` in the pinned DuckDB with
the avro and iceberg extensions loaded. The SQL scans each table with
`iceberg_scan('db/<table>', version = '3', allow_moved_paths = true)`, which
opens `db/<table>/metadata/v3.metadata.json`: the paths the metadata holds are
`s3://wh/...` URIs, which DuckDB resolves against the table directory by their
`/metadata/` and `/data/` parts, so a
table's location must contain neither part before its own and its files must
lie under `metadata/` and `data/`, as `write_table`'s defaults do. It compares
the rows with hand-written expected rows both ways, reads the column types and
reads each data file's Parquet field ids. `test_iceberg_foreign_readback`
asserts the answers. This is a test of the files; nothing in the package reads
a table's data through DuckDB.

## Errors

Every message starts with its token and a colon (`error_has_token` tests
that). From a REST error response a message keeps the request, the status and
the catalog's `ErrorModel` `type` and `message`, and never the raw body:

| Condition | Token |
| --- | --- |
| 404 on a table path, error type `NoSuchNamespaceException` | `ICEBERG_NAMESPACE_NOT_FOUND` |
| any other 404 on a table path | `ICEBERG_TABLE_NOT_FOUND` |
| 401, 419 | `ICEBERG_CATALOG_UNAUTHORIZED` |
| 403 | `ICEBERG_CATALOG_FORBIDDEN` |
| any 5xx, a transport error on config, load or create | `ICEBERG_CATALOG_UNAVAILABLE` |
| any other status (a 404 on config included) | `ICEBERG_CATALOG_REJECTED` |
| a body that is not JSON or not the expected object, a missing or empty `metadata-location` | `ICEBERG_CATALOG_RESPONSE_INVALID` |

The commit failures add `ICEBERG_COMMIT_CONFLICT`,
`ICEBERG_COMMIT_STATE_UNKNOWN`, `ICEBERG_TABLE_REPLACED`,
`ICEBERG_SCHEMA_INCOMPATIBLE` and `ICEBERG_WRITE_FORMAT_UNSUPPORTED`. The write
sink adds `ICEBERG_TYPE_UNSUPPORTED` (a column of a type the writer does not
write, named with its type), `ICEBERG_NULL_IN_REQUIRED_COLUMN` (a null bound
for a `required` column, named with the count; both are the `iceberg`
package's tokens, named here too), `ICEBERG_LOCATION_REFUSED` (a data or
metadata path outside the table's location, or a URI outside the store's
prefix) and `ICEBERG_MANIFEST_LIST_UNSUPPORTED` (a base manifest list that
another writer wrote). `ICEBERG_SCHEMA_INCOMPATIBLE` also names a batch whose
column count or column types differ from the table's, and
`ICEBERG_WRITE_FORMAT_UNSUPPORTED` a codec property value komira does not
write.
`StorageBasedCatalog` raises its own `IcebergCatalogError`.

The REST client is generic over a transport (`IcebergRestTransport.send`:
`HttpIcebergRestTransport[C]` over `http_client`; `ScriptedIcebergRestTransport`,
which answers from a queue and records each request's method, path, body and
headers; `InMemoryIcebergRestCatalog`, an in-process catalog that applies
commits and can be scripted to fail) and over a credential provider
(`CatalogCredentialProvider`; `StaticBearerToken` sends `Bearer <token>`, or no
header for an empty token).

## Examples

A storage-based catalog resolves what was registered and refuses anything else:

<!-- mojo-hidden from std.testing import assert_equal, assert_true, assert_false -->
```mojo
from iceberg_catalog import StorageBasedCatalog

var catalog = StorageBasedCatalog()
catalog.register("db", "orders", "s3://wh/db/orders/metadata/00002.metadata.json")

var t = catalog.load_table("db", "orders")
assert_true(t.has_location())
assert_equal(t.metadata_location, "s3://wh/db/orders/metadata/00002.metadata.json")
assert_equal(t.metadata, "")  # a storage-based resolve knows only the location

var refused = False
try:
    _ = catalog.load_table("db", "missing")
except e:
    refused = String(e).find("no table registered for 'db.missing'") >= 0
assert_true(refused)
```

The REST client over the scripted transport, with canned catalog responses: the
config is read once, the prefix it names goes into the table path, the bearer
token goes on every request, and the location comes back from the response:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from iceberg_catalog import IcebergRestCatalog, ScriptedIcebergRestTransport, StaticBearerToken

var transport = ScriptedIcebergRestTransport()
transport.queue_response(
    200, '{"defaults":{"clients":"4"},"overrides":{"prefix":"prod"}}'
)
transport.queue_response(
    200,
    '{"metadata-location":"s3://wh/prod/db/orders/metadata/00003.metadata.json",'
    + '"metadata":{"format-version":2},'
    + '"config":{"write.parquet.compression-codec":"zstd"}}',
)
transport.queue_response(404, '{"error":{"message":"Table does not exist","code":404}}')

var catalog = IcebergRestCatalog[ScriptedIcebergRestTransport, StaticBearerToken](
    "catalog", transport^, StaticBearerToken("token-123")
)
var t = catalog.load_table("db", "orders")
assert_equal(t.metadata_location, "s3://wh/prod/db/orders/metadata/00003.metadata.json")
assert_equal(t.config_value("write.parquet.compression-codec"), "zstd")
assert_true(t.metadata.find("format-version") >= 0)
assert_equal(catalog.prefix(), "prod")
assert_equal(catalog.config_value("clients"), "4")

# The second table is a 404: an error, never an empty location. The message
# starts with its token and keeps the catalog's message, not the raw body.
var not_found = String("")
try:
    _ = catalog.load_table("db", "gone")
except e:
    not_found = String(e)
assert_equal(
    not_found,
    "ICEBERG_TABLE_NOT_FOUND: loadTable 'db.gone': HTTP 404: Table does not exist",
)

ref sent = catalog.transport_ref()
assert_equal(sent.call_count(), 3)  # /v1/config was read once, not per table
assert_equal(sent.call_path(0), "/v1/config")
assert_equal(sent.call_path(1), "/v1/prod/namespaces/db/tables/orders")
assert_equal(sent.call_auth(1), "Bearer token-123")
```

Creating a table and committing an append against the in-process catalog. The
writer is the caller's: here it only names a manifest list under the table's
metadata path. The committer takes its time from `ManualCommitClock` and its
ids from `SequenceCommitIds`, so the run is deterministic and sleeps never:

```mojo module
from std.testing import assert_equal, assert_true
from json import parse_json_value
from iceberg_catalog import (
    AppendCommit,
    AppendSnapshotWriter,
    COMMIT_ID_SUMMARY_KEY,
    CreateTableRequest,
    IcebergRestCatalog,
    InMemoryIcebergRestCatalog,
    ManualCommitClock,
    SchemaField,
    SequenceCommitIds,
    StaticBearerToken,
    TableMetadata,
    commit_append,
)


struct ListPerAttempt(AppendSnapshotWriter, Movable):
    """Names the manifest list of an attempt and remembers it."""

    var written: List[String]

    def __init__(out self):
        self.written = List[String]()

    def write_manifest_list(
        mut self,
        snapshot_id: Int64,
        attempt: Int,
        base: TableMetadata,
        sequence_number: Int64,
    ) raises -> String:
        var path = (
            base.location
            + "/metadata/snap-"
            + String(snapshot_id)
            + "-"
            + String(attempt)
            + ".avro"
        )
        self.written.append(path)
        return path


def main() raises:
    var server = InMemoryIcebergRestCatalog("prod", "s3://wh")
    server.create_namespace("db")
    var catalog = IcebergRestCatalog[
        InMemoryIcebergRestCatalog, StaticBearerToken
    ]("catalog", server^, StaticBearerToken(""))

    # Create `db.orders` (direct, not staged) with one column.
    var schema = parse_json_value(
        '{"type":"struct","fields":[{"id":1,"name":"id","required":true,"type":"long"}]}'
    )
    var created = catalog.create_table(
        "db", CreateTableRequest("orders", schema^, stage_create=False)
    )
    assert_equal(created.metadata.location, "s3://wh/db/orders")
    assert_equal(len(created.metadata.snapshots), 0)

    # Commit an append of one data file with 100 rows.
    var columns = List[SchemaField]()
    columns.append(SchemaField(1, "id", True, "long"))
    var commit = AppendCommit(
        "db",
        "orders",
        created.metadata.table_uuid,
        columns^,
        List[Int64](),  # the statement did not read its target
        1,  # data files
        100,  # records
        4096,  # bytes
    )
    var writer = ListPerAttempt()
    var clock = ManualCommitClock(1_700_000_000_000)
    var snapshot_ids = List[Int64]()
    snapshot_ids.append(7)
    var ids = SequenceCommitIds(snapshot_ids^)
    var outcome = commit_append(catalog, writer, clock, ids, commit)

    assert_true(outcome.committed)
    assert_equal(outcome.message, "")
    assert_equal(outcome.posts, 1)
    assert_equal(outcome.snapshot_id, 7)
    assert_equal(outcome.landed_snapshot_id.value(), 7)
    assert_equal(outcome.manifest_list, writer.written[0])
    assert_equal(len(clock.waits), 0)  # no retry, no wait

    # The catalog holds the snapshot, `main` points at it, and the summary
    # carries the counts and the statement's commit id.
    ref landed_server = catalog.transport_ref()
    var landed = landed_server.metadata("db", "orders")
    assert_equal(len(landed.snapshots), 1)
    assert_equal(landed.main_snapshot_id.value(), 7)
    assert_equal(landed.snapshots[0].manifest_list, writer.written[0])
    assert_equal(landed.snapshots[0].summary("added-records").value(), "100")
    assert_equal(
        landed.snapshots[0].summary(COMMIT_ID_SUMMARY_KEY).value(),
        outcome.commit_id,
    )
    assert_equal(landed_server.applied_commits, 1)
```
