# Iceberg tables in the user's catalog: the REST write protocol, commits, pruning and the Python surface

Status: design, not built. This document makes buildable the first slice of the Iceberg table layer that [storage_stack.md](storage_stack.md) proposes, under "L3: Iceberg tables through a catalog". That parent document decides the product: a durable komira table is a native Iceberg table, committed through the user's catalog. It also gives the commit-client rules, the interop defaults and the maintenance split. This document does not reopen those decisions. Where it narrows one, [Corrections to other documents](#corrections-to-other-documents) says so. It fixes what the parent leaves open for a first release:

- the exact requests komira sends to an Iceberg REST catalog;
- one commit, step by step, including what happens on every response;
- how a scan prunes files using the table's own metadata;
- the SQL and Python surface;
- the plan-wire arm;
- which package changes, and in what order.

Statements marked *(inferred)* are reasoning, not something read in code or in a specification. Statements marked *(to confirm)* are behaviour of a third-party catalog or engine, or of Iceberg Java beyond the specification, that this document has not checked. The REST protocol facts come from the Iceberg REST OpenAPI ([rest-catalog-open-api.yaml](https://github.com/apache/iceberg/blob/main/open-api/rest-catalog-open-api.yaml)) and the table facts from the [Iceberg table spec](https://iceberg.apache.org/spec/).

## Two questions for the maintainers

Each has a recommendation in one line. The rest of the document is written to it.

1. **`CREATE TABLE ... AS` on a catalog that refuses a staged create.** Recommendation: fail by name (`ICEBERG_CATALOG_REJECTED`, quoting the catalog), with no create-then-append fallback, because the fallback shows readers an empty table and leaves one behind on failure ([Create](#create), [Decisions](#decisions) 3).
2. **`CREATE OR REPLACE` on a table another tool created.** Recommendation: allow it, because the user named the statement, and Iceberg's replace keeps the table's uuid and history, so the old snapshots stay readable until the table's maintainer expires them ([Decisions](#decisions) 15).

## What the first slice does not give

Measured against the catalog requirement of [storage_stack.md](storage_stack.md) (any of the catalogs it lists, and a default catalog for a user with none), the first slice leaves four gaps:

- **Glue's native API and Hive Metastore come later.** The first slice speaks only the Iceberg REST protocol. Glue is reached only through its REST endpoint *(to confirm)*, and a Hive Metastore user has no route until that adapter lands.
- **No default catalog for a user who has none.** Such a user cannot create a durable table with this slice. The komira-run catalog of [storage_stack.md](storage_stack.md) ("A user with no catalog") is later work.
- **No maintenance of what komira writes.** No compaction, manifest merging, snapshot expiry or orphan removal. A table komira writes gathers small files and snapshots until the user's tools or the catalog maintain it.
- **No real catalog is confirmed yet.** Each catalog named below stays unconfirmed until the held interop run ([Tests](#tests)) has passed against it. The design is checked against the REST specification and an in-process test catalog only.

## What is it for, and what is out of scope?

A user writes a table with komira, and Spark, Trino, Athena, Snowflake and DuckDB read it through the user's own catalog. komira, in turn, reads tables those tools wrote. The first slice covers:

- **Catalogs.** Any catalog that serves the Iceberg REST protocol. Among them are Apache Polaris, Nessie, Lakekeeper, Unity Catalog, the AWS Glue and S3 Tables REST endpoints, and the BigLake metastore REST endpoint *(each to confirm with the interop runs, [Tests](#tests))*.
- **Statements.** `CREATE TABLE ... AS SELECT`, `CREATE TABLE` with a column list, `CREATE OR REPLACE TABLE ... AS SELECT`, `INSERT INTO ... SELECT` and `INSERT INTO ... VALUES`.
- **Reads.** `SELECT` from a table in a bound catalog. Format versions 1 and 2, with their position and equality deletes in Avro or Parquet. Time travel by snapshot id is available from Python. The scan prunes data files by partition and by column bounds.
- **Python.** Hold a catalog source (`komira.iceberg`), bind it to a name in SQL, run those statements, and read a table as a relation.
- **Writes.** Format version 2.

Out of the first slice. Each item is refused by name, and none is silently ignored:

- `UPDATE`, `DELETE`, `MERGE INTO`, `ALTER TABLE`, `CREATE SCHEMA`, `DROP TABLE` and SQL `ATTACH`. Error: `SQL_STATEMENT_UNSUPPORTED`, naming the statement. The first three need the position-delete writer the parent specifies ("Format version and delete encoding").
- A SQL time-travel clause. Error: `SQL_STATEMENT_UNSUPPORTED`. Python's `as_of=` covers time travel.
- Creating a partitioned table. Writing *into* an existing partitioned table is in scope, with every v2 transform.
- Writes to format v1 and v3 tables. Error: `ICEBERG_WRITE_FORMAT_UNSUPPORTED`, naming the version. An append to v3 needs row-lineage fields (`first-row-id`, `next-row-id`) that the first slice does not maintain.
- Reads of format v3 tables. Error: `OPTIMIZED_SOURCE_FEATURE_UNSUPPORTED`, naming `format-version 3`. Deletion vectors, row lineage and `initial-default` come with the v3 reader.
- Nested types (struct, list, map), in reads and writes. Error: `ICEBERG_TYPE_UNSUPPORTED`, naming the column.
- Catalog adapters other than REST (Glue's own API, Hive Metastore), and multi-table commits (`/transactions/commit`). The parent's rule applies: "do not design on multi-table atomicity".
- Maintenance (compaction, manifest merging, snapshot expiry, orphan removal) and the `komira.maintenance` property. These remain the parent's step 8.
- Hot tails, upsert sinks and streaming writes (`plan_models.md` §2.2.6).
- Distributed writes across several hosts are designed here ([Who commits](#who-commits)), but the first slice runs in one process.

## What the user sees

Sources, credentials and bindings follow one model for every kind of source. That model is owned by the credentials design, `credentials_and_writes.md` (komira-ai/komira#2117), and this document uses its spelling and defines no second one. Its catalog example, character for character:

```python
lake = komira.iceberg(
    "https://catalog.example.com/api/catalog",
    warehouse="analytics",
    credential=komira.OAuth2ClientCredentials("lake-etl", client_id="etl", client_secret=client_secret),
)
s.sql("SELECT * FROM lake.sales.orders LIMIT 10", lake=lake)
```

The same catalog bound once on the session, in a statement that also reads a bound file source:

```python
s.bind("lake", lake)
s.sql("INSERT INTO lake.sales.orders SELECT * FROM orders", orders=orders)
```

Here `s` is a `komira.Session()` and `orders` a `komira.files(...)` source, as in that design's first example. The statements this document adds, and the DataFrame-door read:

```python
s.bind("lake", lake)
s.sql("CREATE TABLE lake.sales.orders AS SELECT * FROM read_parquet('s3://raw/orders/*.parquet')")
s.sql("INSERT INTO lake.sales.orders SELECT * FROM read_parquet('s3://raw/orders-late/*.parquet')")
s.sql("SELECT region, sum(amount) FROM lake.sales.orders WHERE order_date >= DATE '2026-10-01' GROUP BY region")

orders = komira.read_table(lake, "sales.orders")            # as_of=<snapshot id> for time travel
orders.filter(orders.region == "emea").to_arrow()
```

**How a catalog reaches a statement.** The Mojo SQL front end cannot turn a table name into a source by itself, so the user supplies the mapping:

1. **A catalog is a source the user holds**: `komira.iceberg(uri, *, warehouse=None, credential=komira.AMBIENT, signing=None, access_delegation="vended-credentials")`. Building it does no I/O.
2. **A name in the SQL is bound to it** per statement, as a keyword argument of `sql` (`lake=lake`), or once on the session with `s.bind("lake", lake)`. A call binding hides a session binding of the same name for that statement.
3. **The binder plugs the source in.** For `lake.sales.orders`, it looks `lake` up in the statement's bindings, loads `sales.orders` from that catalog under the catalog's credential, and emits a `komira.iceberg.table` scan or the Iceberg write target.
4. **The plan carries the catalog's location and the name of its credential, never a credential's value, and never the name `lake`.** Two users' `lake` may be two catalogs, so the name a user typed in SQL never reaches the wire. `IcebergTableRef.catalog` is a `WireIcebergCatalog`: the `uri`, the `warehouse`, and a `WireSourceAccess` holding the credential name (`lake-etl`) and the signing settings ([The plan wire](#the-plan-wire)). Whoever runs the plan resolves `lake-etl` to a value: the session locally, or, on a job manager, the customer's secret store or the run's identity for `ambient`.

What this document adds to that model is only what is specific to Iceberg:

- **The catalog's arguments.**
  - `uri` and `warehouse`: where the catalog is, and which warehouse to ask its config for.
  - `credential`: a named credential for the catalog. `komira.BearerToken(name, *, token)`, `komira.OAuth2ClientCredentials(name, *, client_id, client_secret, scope="catalog", token_url=None)`, or, for a SigV4 catalog, an AWS credential: `komira.AMBIENT` (the provider chain, which S2 allows) or `komira.AwsKeys(...)`.
  - `signing`: `komira.SigV4(region, service)` signs every request with the AWS credential the source names. The service is the user's value: `glue` for the Glue endpoint, `s3tables` for S3 Tables *(to confirm both)*. SigV4 is a request-signing protocol the user picks as a value; the client never branches on a cloud's name (rule B21).
  - `access_delegation`: `"vended-credentials"` (the default) or `"none"`. Any other value, `"remote-signing"` among them, is refused by name. It travels as `WireIcebergCatalog.vended`, so every host that talks to the catalog makes the same choice. See [Credentials](#credentials).
  - Configuration arrives as arguments, never as environment variables (rule S2). Credential objects follow the credentials design's secret rules: their `repr` shows only the kind and the name, and they refuse `pickle` and `copy`.
  - Nothing is sent to the catalog until the first statement that binds it names one of its tables.
- **SQL names** are `catalog.namespace.table`, the three-part form DuckDB's Iceberg extension accepts after its `ATTACH ... (TYPE iceberg)`. A DuckDB script therefore ports by replacing its `ATTACH` line with a binding of the same name *(to confirm the forms against the pinned DuckDB and its Iceberg extension)*.
  - A first part with no binding fails with the binding model's `BIND_NAME_UNBOUND`, whose message lists the bound names. A first part bound to something other than a catalog fails with `BIND_NOT_A_CATALOG`.
  - Four or more parts (`catalog.a.b.table`) name a multi-level namespace. This is an EXTENSION over DuckDB. A catalog with one-level namespaces answers with its own error, which is quoted.
  - Namespace and table names are sent as written: unquoted identifiers keep their spelling, as DuckDB keeps it. The catalog's own case rule decides the lookup, and komira does not retry in another case.
  - A column list (`INSERT INTO t (a, b)`) matches table columns case-insensitively, as DuckDB does. Two table columns that differ only in case make the statement fail with `ICEBERG_COLUMN_AMBIGUOUS`.
- **What a write statement returns** is what DuckDB returns for the same statement. `INSERT` and `CREATE TABLE ... AS` return one row with one `BIGINT` column, `Count`, holding the number of rows written. `CREATE TABLE` with a column list returns no rows *(both to confirm against the pinned DuckDB)*. The statement returns only after the catalog accepted the commit. From that moment, every tool that loads the table sees the rows (the parent's "Who sees what, and when").
- **`komira.read_table(catalog, name, as_of=None)`** is the verb of `optimized_plan_sources.md` §15.9 (`km.read_table` there), without its `include_tail=`, which comes with tails.
  - `catalog` is the held source, `lake` above. The verb binds no name, and emits the same plan as the SQL `lake.sales.orders`, with the same catalog location and credential name.
  - `name` is `"namespace.table"`, or a tuple of namespace levels and the table name when a level contains a dot.
  - `as_of` takes a snapshot id. It maps to the kind's `as_of_snapshot` param.
- **Errors.** The Iceberg tokens reach Python as subclasses of `komira.IcebergError`, which is a `KomiraError` beside the binding model's `BindError`, `CredentialsError` and `StorageError`. Each carries its stable token in `.code`. The tokens are listed in [Errors](#errors).

The `DataFrame` verb `frame.write_table(lake, "sales.orders", mode="append" | "create" | "replace")` comes with the DataFrame surface. It emits the same plan as `INSERT`, `CREATE TABLE AS` and `CREATE OR REPLACE TABLE AS` ([The plan wire](#the-plan-wire)). The parent's `overwrite` (by a filter) and `overwrite_partitions` modes need the delete writer, and come with it.

## What exists today

| piece | where | state |
|---|---|---|
| REST catalog client | `src/iceberg_catalog` | resolve-only: `GET /v1/config` once, then `GET .../tables/{table}`. Returns the metadata location, the metadata as JSON text, and the per-table `config`. The config merge keeps string values of `defaults` and `overrides` only (`_merge_config_map`). The transport has one method, `get`, with no method or body field (`iceberg_rest_transport.mojo:134`). Auth is a static bearer token. Errors are untyped strings that echo the response body |
| file-based table writer and reader | `src/iceberg` | a v2 writer over a `ConditionalWriteStore`. It commits by create-if-absent of `metadata/v<N+1>.metadata.json`, plus a `version-hint.text` compare-and-swap (`iceberg_writer.mojo:23-37`). The spec calls this file-system scheme unsafe on object stores, so it cannot commit into a user's catalog. Types: boolean, int, long, float, double and string. Transforms: identity and bucket. Partition values cannot be null. Paths are store keys, not URIs. Delete files are Avro. There is no general `metadata.json` parser: the readers byte-scan the JSON this package writes (`iceberg_json_scan.mojo`). The manifest decoders read only the manifests this package writes. The reader prunes nothing (`src/iceberg/README.md`) |
| Avro manifests and bounds | `src/iceberg` | `build_manifest_file`, `build_manifest_list`, and the `bound_*` single-value encoders (`iceberg_bounds.mojo`). They carry the spec's field ids. The manifest list's partition summaries are written as null |
| Parquet writer | `src/parquet_writer` | Arrow batches to file bytes (`write_record_batch_to_parquet_bytes`). It refuses unsigned and narrow integers, BINARY and nested types. It writes no timestamp annotation, writes decimals as FIXED(16), and cuts row groups by row count (`src/parquet_writer/README.md`). `SchemaElement` has no `field_id` (`parquet_api/metadata.mojo:132`), on the read side too |
| SQL writes | `src/sql`, `src/sdk_exec` | `COPY ... TO` and `CREATE TABLE ... AS` parse and bind, and `run_sql` refuses both (`STATEMENT_NOT_A_QUERY`, `engine_sql.mojo:90-98`) until lowering's writes slice lands (`lowering_and_pipeline.md`, slice 7). The file sinks are `SinkVariant` arms in `sdk_exec` (`sink_variant_tags.mojo`). There is no `INSERT` and no qualified table names: the parser keeps only the last part of `s.t` (`sql_parser.mojo:1045-1054`) |
| write target | `src/arrow/write_target.mojo`, `src/plan_proto/plan.proto:1848`, `src/plan_wire/plan_wire_codec.mojo` | `WriteTarget` and `WireWriteTarget {path, format, codec}`. A write-carrying envelope declares format version 5. There is no Iceberg arm; `plan_models.md` §2.2.6 sketches one with APPEND and UPSERT only |
| Iceberg scan kind and pin | `optimized_plan_sources.md` §15.3, §15.4.1 | designed, not built: `komira.iceberg.table`, `IcebergTableRef`, `IcebergPin` |
| request signing and OAuth2 | `src/aws_core/signed_request.mojo:203` (`build_sigv4_signed_request`); `src/azure_core/creds_service_principal.mojo` (a client-credentials POST with token caching) | exist, for other services |

`cdc_ingest` commits through the file-based writer and writes equality deletes. It is not on the path this document builds and stays as it is. Moving it onto the catalog committer is later work ([Order of work](#order-of-work)).

## How does it work?

```
 Python  s.sql("INSERT INTO lake.sales.orders ...", lake=lake) or s.bind("lake", lake) / komira.read_table(lake, ...)
   |
 SQL parser and binder: catalog.ns.table, via the statement's bindings -> IcebergTableRef; INSERT, CTAS, CREATE OR REPLACE
   |                                                (binder loads the table: uuid, schema, spec, current snapshot)
 plan: scans carry IcebergPin; the write carries WireWriteTarget.iceberg (catalog uri, warehouse, credential NAME; never a value)
   |
 lowering: the Iceberg file sink -- writes Parquet data files under the table's location, returns DataFile records
   |       scan planning: manifest list -> manifests -> files, pruned by partition and bounds
 committer (one per statement, in the session; on the coordinator once plans span hosts)
   |   writes one manifest and one manifest list, then POST .../tables/{table} with requirements and updates
 iceberg_catalog: REST transport (GET, POST), catalog credential (bearer, OAuth2) and SigV4 signing, typed errors
   |
 the user's catalog atomically swaps the table's metadata-location; the catalog writes metadata.json
```

The catalog writes the new `metadata.json`, not komira. Under REST, a commit sends the changes, and the server applies them to the current metadata, writes the next metadata file, and swaps its pointer atomically. komira writes data files, one manifest and one manifest list per attempt, and nothing else under the table's location.

## The REST write protocol

All paths are under `/v1/{prefix}`. Every request carries `Accept: application/json`; a request with a body also carries `Content-Type: application/json`. A namespace with several levels is joined by the separator the config advertises in `namespace-separator`, else by the unit separator `0x1F`, and then percent-encoded.

### Config

`GET /v1/config?warehouse=<warehouse>`. The `warehouse` query is new; today's client sends none, and Polaris and S3 Tables need it to choose the catalog *(to confirm per catalog)*. The client keeps:

- From the merged `defaults` and `overrides` (overrides win): `prefix`, `namespace-separator` and `oauth2-server-uri`.
- From the top level of the response, beside `defaults` and `overrides`:
  - `endpoints`, when the server lists them. A statement that needs an endpoint the server does not list is refused before any file is written, with `ICEBERG_CATALOG_ENDPOINT_UNSUPPORTED` naming the endpoint. A server that omits `endpoints` gets the spec's default set, which includes create, load and commit.
  - `idempotency-key-lifetime`. Its presence means the server honours `Idempotency-Key` ([Idempotency](#idempotency)).

### Load

`GET .../namespaces/{ns}/tables/{table}`, with `X-Iceberg-Access-Delegation: vended-credentials` when the plan's `catalog.vended` is true, and no such header when it is false (`access_delegation="none"`). The client keeps:

- `metadata-location`;
- `metadata`, now parsed into a typed `TableMetadata` ([Package changes](#package-changes)), including two rules:
  - `main` is `refs.main`, else `current-snapshot-id` when `refs` is absent, because the spec says a `main` branch always exists;
  - a `current-snapshot-id` of `-1` means none, as older writers spell it.
- `config`;
- `storage-credentials`.

### Create

`CREATE TABLE ... AS` and `CREATE OR REPLACE TABLE` on a new name use a **staged create**. That makes the table and its first snapshot appear in one commit, so no reader ever sees an empty table, and a failed write leaves no table behind.

1. `POST .../namespaces/{ns}/tables`, with the same `X-Iceberg-Access-Delegation` header as a load, so the response vends credentials for the new location. The body:

   ```json
   {"name": "orders", "schema": {...}, "stage-create": true,
    "properties": {"format-version": "2", "write.parquet.compression-codec": "zstd"}}
   ```

   The response is the table's initialized metadata (uuid, location, schema with assigned field ids), plus `config` and `storage-credentials`. Nothing is created yet.
2. Write the data files under the returned location, then one manifest and one manifest list.
3. `POST .../namespaces/{ns}/tables/{table}`, with the requirement `{"type": "assert-create"}` and these updates, in order:
   - `assign-uuid`;
   - `upgrade-format-version`;
   - `add-schema`, then `set-current-schema` with `-1` ("the schema just added");
   - `add-spec`, then `set-default-spec` with `-1`;
   - `add-sort-order`, then `set-default-sort-order` with `-1`;
   - `set-location`;
   - `set-properties`;
   - `add-snapshot`, then `set-snapshot-ref`.

   These are what the REST spec asks a staged-create transaction to include ("Transactions should include all changes to the table, including table initialization"). `add-schema` omits the deprecated `last-column-id`.

**Every column a `CREATE TABLE ... AS` creates is optional.** A `CREATE TABLE` with a column list maps `NOT NULL` to `required`. Any other constraint (`PRIMARY KEY`, `UNIQUE`, `CHECK`, `DEFAULT`) is refused with `SQL_STATEMENT_UNSUPPORTED`, naming the constraint.

**The other create forms:**

- **`CREATE TABLE` with a column list and no query** uses `"stage-create": false`. The catalog creates the empty table in that one request, and no commit follows. The session runs it directly: it is not a plan, and it has no write target. `CREATE OR REPLACE TABLE` with a column list is refused with `SQL_STATEMENT_UNSUPPORTED`.
- **A `CREATE TABLE ... AS` whose query returns zero rows** commits the staged create without `add-snapshot` and `set-snapshot-ref`. The table exists with no snapshot, as a create with no data does in Iceberg. A replace of an existing table with zero rows ends differently, with an empty snapshot ([One attempt](#one-attempt)): a replace must move `main` off the old data, while a new table has no `main` to move.
- **The name already exists at bind time.** The binder's load finds it, before the query runs:
  - `CREATE TABLE` fails with `ICEBERG_TABLE_ALREADY_EXISTS`;
  - `CREATE TABLE IF NOT EXISTS` returns `Count` 0 without running the query, as DuckDB does for an existing table *(to confirm)*;
  - `CREATE OR REPLACE` takes the replace path.
- **The name is taken concurrently**, between bind and commit. The staged create's commit gets a 409:
  - `CREATE` fails with `ICEBERG_TABLE_ALREADY_EXISTS`, and the statement's files are deleted ([Cleanup](#cleanup));
  - `IF NOT EXISTS` returns `Count` 0, and the statement's files are deleted;
  - `CREATE OR REPLACE` deletes its files, reloads the table, and runs the statement again on the replace path. The files it wrote carry the staged create's field ids and lie under the staged location, so the replace cannot reuse them.

  All three apply only when no earlier attempt of the staged create's commit had an unknown outcome. Otherwise the committer loads the table:
  - if the table holds `S` or `C`, the statement succeeds;
  - if the table is absent, it retries the commit;
  - if the table exists with neither, the statement fails with `ICEBERG_COMMIT_STATE_UNKNOWN`, and no file is deleted.
- **The create POST itself** (step 1) changes nothing in the catalog. A 409 there is `ICEBERG_TABLE_ALREADY_EXISTS`, handled as above. A 503, a 5xx or a transport error is retried within the budget, since no file has been written yet, and fails with `ICEBERG_CATALOG_UNAVAILABLE` when the budget runs out.
- **A catalog that refuses `stage-create`** (a 400) fails the statement with `ICEBERG_CATALOG_REJECTED`, quoting the catalog's error message. There is no fallback to a non-atomic create-then-append ([Decisions](#decisions), 3).

### Commit

`POST .../namespaces/{ns}/tables/{table}`. An append looks like this:

```json
{"requirements": [
   {"type": "assert-table-uuid", "uuid": "0198f2c1-7a3e-7c4d-9b1e-3f5a8d2c6e10"},
   {"type": "assert-ref-snapshot-id", "ref": "main", "snapshot-id": 5871360281466243136},
   {"type": "assert-current-schema-id", "current-schema-id": 3}],
 "updates": [
   {"action": "add-snapshot", "snapshot": {
      "snapshot-id": 6612290831147218944, "parent-snapshot-id": 5871360281466243136,
      "sequence-number": 18, "timestamp-ms": 1795132800000, "schema-id": 3,
      "manifest-list": "s3://wh/sales/orders/metadata/snap-6612290831147218944-1-0198f2c1-....avro",
      "summary": {"operation": "append", "added-data-files": "4", "added-records": "1200000",
                  "added-files-size": "96011264", "total-data-files": "61", "total-records": "18200000",
                  "total-files-size": "1460224000", "total-delete-files": "0",
                  "total-position-deletes": "0", "total-equality-deletes": "0",
                  "komira.commit-id": "0198f2c1-9b44-7e0a-8c2d-5b7e1f0a3c99"}}},
   {"action": "set-snapshot-ref", "ref-name": "main", "type": "branch",
    "snapshot-id": 6612290831147218944}]}
```

On a table with no snapshot yet, `assert-ref-snapshot-id` carries `"snapshot-id": null`, which asserts that `main` does not exist yet. A replace adds requirements and updates; see [Commit semantics](#commit-semantics).

### Credentials

Data files go to the table's location, with credentials chosen in this order:

1. **Vended by the catalog.** First `storage-credentials` from the load or create response: each entry has a `prefix` and a `config`, and the longest prefix that matches the file's URI wins. Then the response's `config` keys for the URI's scheme. These are Iceberg's `FileIO` property names, for example `s3.access-key-id`, `s3.secret-access-key`, `s3.session-token`, `gcs.oauth2.token` and `adls.sas-token.<account>`.
2. **The scope covering the file's location**, by the binding model's longest-prefix rule, used only when the catalog vends nothing for the URI or the source has `access_delegation="none"`. For a scan, an `INSERT` and a replace of an existing table, the binder resolves it when it loads the table, and the plan carries its credential name and store settings in `IcebergTableRef.catalog.data_access` ([The plan wire](#the-plan-wire)). A staged create has no location at bind: the party that runs the stage-create resolves the scope from the location in its response, as described below. The session's default `s3://` and `gs://` scopes use `komira.AMBIENT`. A URL under no scope fails with the binding model's `CREDENTIALS_NOT_FOUND`.

**Which paths komira writes to.**

- The object store is chosen by the URI's scheme. A cloud is a value here, never a branch on a catalog vendor's name (rule B21).
- komira writes only to schemes the session has a store for. A bound scope never widens where komira writes inside a table; the rule below decides that. `file:` is allowed only when the session enables local tables.
- Every data and metadata path must lie under the table's `location`, or under a prefix the catalog vended credentials for. `write.data.path` and `write.metadata.path` count only when they satisfy that rule. Otherwise the statement fails with `ICEBERG_LOCATION_REFUSED` before any file is written, so a table property can never steer komira's own credentials at another bucket.

**Expiry.** The object-store handle checks the vended credentials' expiry key (such as `s3.session-token-expires-at-ms`) against the injected clock before every upload part and before every cleanup delete. Within the refresh margin it renews them:

- by `GET .../tables/{table}/credentials`, where the server lists that endpoint;
- else by reloading the table.

A staged create has no table to reload. If its credentials expire and the server does not list the credentials endpoint, the statement fails with `ICEBERG_CREDENTIALS_EXPIRED` before the commit.

**In a plan that spans hosts**, nothing is handed from one host to another, and the committer hands no credentials out. This is the binding model's rule that a host gets a value only by resolving a name the plan carries:

- **Catalog requests.** A host that talks to the catalog resolves the catalog's credential name (`IcebergTableRef.catalog.access.credential`) through the same resolver as every other source: the session locally; on a job manager, the customer's secret store by that name, or the run's identity for `ambient`.
- **Vended data-file credentials.** Each host loads them itself, from the catalog, under the catalog's credential name: by `GET .../tables/{table}/credentials` where the server lists it, else by loading the table. It renews them the same way, before they expire, against its own clock.
- **The fallback scope.** Where the catalog vends nothing, each host resolves the credential name in `IcebergTableRef.catalog.data_access`, as for any file source.
- **A staged `CREATE TABLE ... AS` across hosts** writes a table that does not exist yet, so a host has nothing to load and no credentials endpoint to call. The binding model answers this (`credentials_and_writes.md`, decision 5):
  - The coordinator, which runs the stage-create, learns the staged location from its response. Before it cuts the hosts' segments, it fills `data_access` with the scope covering that location, and each segment carries the location its sink writes under.
  - When the catalog only vends and no scope covers that location, the coordinator adds one run-scoped name to the run's resolver, `vended.<statement id>`, holding the staged create's vended credentials, and puts it in each host's segment as `data_access.credential`. Each segment's header lists it. The name exists only for that run, and a client-submitted plan that names a `vended.` credential is refused on decode.
  - Hosts resolve either name through the same resolver as any other. `ICEBERG_LOCATION_REFUSED` bounds where they write with it.
  - In the first slice there is one process, which is the committer and the only writer, and it uses the staged create's vended credentials directly.

**Caches.** A loaded table, its pin and its vended credentials are cached under the binding model's identity of a read, `(location, credential name, credential generation, endpoint, region, addressing)`, where a catalog table's location is the catalog's `uri` and `warehouse` and the table's namespace and name. A session-local name and a credential's value are never part of a key. A cache on a job manager's hosts that serves several runs keys on the resolved principal instead, as that model requires.

**Catalog credentials and signing.**

| catalog source | what the client sends |
|---|---|
| `credential=komira.BearerToken(...)` | `Authorization: Bearer <token>` (today's `StaticBearerToken`) |
| `credential=komira.OAuth2ClientCredentials(...)` | a cached access token from a client-credentials grant, form-POSTed to the token endpoint before the first config request. The first token comes from `token_url`, when one is given, else from `{uri}/v1/oauth/tokens`, which the spec deprecates but Polaris still serves. Once the config has named an `oauth2-server-uri`, refreshes go there *(to confirm per catalog)*. The token is refreshed at its `expires_in` minus a margin, read from an injected clock. A 401 or 419 forces one refresh and one resend of the same request |
| `signing=komira.SigV4(region, service)`, with an AWS `credential=` (`komira.AMBIENT` or `komira.AwsKeys(...)`) | every request signed with `build_sigv4_signed_request` over its method, path, query and body hash, with the region and service from `WireSourceAccess.region` and `signing_service` |

Secrets (the OAuth2 client secret, the bearer token, AWS keys, vended keys) are held as secret values and never written into an error message. An error carries the catalog's `error.type` and `error.message` from its `ErrorModel`, never the raw body. Today's client echoes the body on both the config and the load paths (`iceberg_rest_catalog_client.mojo`); that changes with the write path, and the tests that pin today's messages change in the same pull request.

## Commit semantics

One SQL statement makes one commit to one table. The commit is the only point at which the statement's rows become visible. Before it, the files exist and no snapshot names them. After it, the catalog has swapped the table's pointer.

### Before the first attempt

- **Commit id.** The committer generates `C`, a UUIDv7, once per statement. It goes into the snapshot summary as `komira.commit-id`.
- **Snapshot id.** The committer generates `S`, a random positive 63-bit integer, once per statement, as `iceberg_writer_state.mojo` does today. It draws again if the loaded metadata already holds a snapshot with that id, because the unknown-outcome check depends on `S` being unique.
- **Both ids are kept across retries.** Only the parent, the sequence number and the manifest list change on a retry, as in Iceberg Java's snapshot producer.
- **Neither id comes from the plan.** A plan can be cached and run twice, and two runs must be two commits.
- **The base is loaded at execution.** The committer loads the table when the statement starts to execute. A plan run from cache never commits on the binder's load.
- **The manifest** of the data files is written once, as `<metadata path>/<uuid>-m0.avro`. Its entries are ADDED, with `snapshot_id` `S` and a null sequence number, which is inherited from the manifest list at read time. Its `partition_spec_id` is the spec the sink routed rows by. So the same manifest is valid under any parent and sequence number, and a retry does not rewrite it.
- **Zero rows.** An `INSERT` that produces no rows writes nothing, sends no commit, and returns `Count` 0, as Iceberg Java's append of no files does. It still runs the checks of step 2 on the execution-time load, so a dropped or replaced table fails by name.

### One attempt

1. **Base.** Use the table as last loaded. Let `P` be `main`'s snapshot id (null if there is none) and `n` be `last-sequence-number + 1`.
2. **Check.** Refuse before writing anything else if the base disagrees with the plan:
   - the table uuid differs from the one in the plan: `ICEBERG_TABLE_REPLACED`;
   - the format version is not 2: `ICEBERG_WRITE_FORMAT_UNSUPPORTED`;
   - a column the plan writes was dropped, or its type changed outside Iceberg's promotions (int to long, float to double, decimal precision widening): `ICEBERG_SCHEMA_INCOMPATIBLE`, naming the column.

   What does not stop the write:
   - **A new optional column, or a rename.** Data files are written by field id, and a new column reads as null.
   - **A new default partition spec.** The manifest names the spec its files were routed by, and Iceberg keeps every spec in `partition-specs`, so the files stay valid. The next statement routes by the new default.
3. **Manifest list.** Write `snap-<S>-<attempt>-<uuid>.avro`. It holds every manifest entry of `P`'s list, copied unchanged, then the new manifest. The new manifest's entry carries:
   - `content` 0;
   - `sequence_number` and `min_sequence_number` `n`;
   - `added_snapshot_id` `S`;
   - `partition_spec_id`;
   - `manifest_length`;
   - the added, existing and deleted file and row counts;
   - partition field summaries.

   The snapshot's `timestamp-ms` is the injected clock's time, or one more than the parent's `timestamp-ms` if that is later, so a slow clock never makes a snapshot older than its parent.
4. **POST** the commit with requirements, by statement:

   | statement | requirements | updates |
   |---|---|---|
   | `INSERT` | `assert-table-uuid`; `assert-ref-snapshot-id(main, P)`; `assert-current-schema-id` | `add-snapshot` (operation `append`); `set-snapshot-ref(main, S)` |
   | `CREATE TABLE AS` (staged) | `assert-create` | the staged-create list above |
   | `CREATE OR REPLACE` on an existing table | `assert-table-uuid`; `assert-ref-snapshot-id(main, P)`; `assert-current-schema-id`; `assert-last-assigned-field-id`; `assert-default-spec-id`; `assert-last-assigned-partition-id` | `add-schema` and `set-current-schema(-1)`; `add-spec` (unpartitioned) and `set-default-spec(-1)` if the default is partitioned; `add-sort-order` (unsorted) and `set-default-sort-order(-1)` if the default is sorted; `remove-snapshot-ref(main)`; `add-snapshot` with no parent (operation `append`); `set-snapshot-ref(main, S)` |

   - **`assert-ref-snapshot-id` is on every commit, appends included.** The parent explains why: without it, a server that does not check sequence numbers installs a manifest list that drops another writer's files.
   - **A replace builds the table anew, keeping its identity.** This is the shape of Iceberg Java's replace-table transaction *(to confirm the exact update list against it)*. The table keeps its uuid, its location, its properties and its old snapshots, so time travel to before the replace still works until the snapshots expire. The new `main` has no parent, and its manifest list holds only the new manifest. A replace whose query returns zero rows commits a snapshot with an empty manifest list, so `main` exists and the table is empty. The new snapshot carries no DELETED entries for the files that left `main`; whether other engines' snapshot expiry then finds those files is *to confirm*, and if not, the replace adds a manifest of DELETED entries.
   - **What the replace's result looks like.** It is unpartitioned and unsorted, as a `CREATE OR REPLACE` in DuckDB yields a fresh table. The new schema reuses the field id of each column whose name and type (or promoted type) match the current schema. Every other column gets an id above `last-column-id`, so readers never confuse an old column with a new one.
   - **Why the replace asserts field and partition ids.** The new ids are written into the data files' footers. A concurrent schema or spec change would make them collide, so the replace asserts both counters, and a 409 that moved either is not rebased ([below](#what-each-response-means)).

### What each response means

From the first attempt whose outcome is unknown until the statement ends, the statement is **tainted**. A tainted statement looks for its own commit before acting on any later response, and it deletes no file unless that lookup proves the commit absent.

| response | meaning | what the committer does |
|---|---|---|
| 200 | committed | success when `S` is `main` or an ancestor of `main` in the returned metadata. A server honouring an idempotency key may return a newer state, and another writer may have committed since. Otherwise, run the [lookup](#unknown-outcome) on the returned metadata. If the lookup does not find `S` or `C`, the statement fails with `ICEBERG_COMMIT_STATE_UNKNOWN` |
| 409 | a requirement failed, and this request applied nothing | if tainted, run the lookup first. Then **retry or fail by statement** (below) |
| 400; 401 and 419 after one token refresh; 403; 404 | refused | fail with the status's token ([Errors](#errors)). If not tainted, delete this statement's files ([Cleanup](#cleanup)). If tainted, run the lookup first: a commit that landed means success, and only "absent with `main` at `P`" permits deletion |
| 503 | the spec says the request "could have been partially processed" | treated as an unknown outcome. When the server sent `Retry-After`, the wait before the lookup is at least that long. The spec allows a retry without `Retry-After` only for idempotent requests; komira's retry comes only after the lookup, and its `assert-ref-snapshot-id` makes it unable to apply twice |
| 500, 502, 504, any other 5xx, a timeout, or a connection lost after the request was sent | **state unknown** | the [unknown-outcome](#unknown-outcome) procedure; the statement is tainted |

**Retry or fail after a 409.** The committer reloads the table first.

- **`INSERT`.** It retries from step 1 on the new base. Appends never fail validation after a rebase: the rows are the statement's, whatever was committed meanwhile. There is one exception: the plan also **read** the target table.
  - The committer knows this from the plan's own scans: some `IcebergPin` names the same table uuid. That covers a view, a self-join, a second alias of the same catalog, and every scan of the table in the plan.
  - Retrying on a newer base would append rows computed from a state the table has left. So the committer does not retry. It fails with `ICEBERG_COMMIT_CONFLICT`, naming every pinned snapshot id and the new `main`.
  - This is snapshot isolation for a read-then-write on the same table *(inferred from the conflict validation Iceberg Java applies to an overwrite; komira applies it to every statement that reads its target)*.
- **`CREATE OR REPLACE` on an existing table.** It retries when the query did not read the table and the reload shows the same `last-column-id` and `last-partition-id`. Otherwise it fails with `ICEBERG_COMMIT_CONFLICT`: the ids written into its files may now collide.
- **A staged create.** It follows the rules under [Create](#create).
- **A tainted statement** runs the lookup before any of these. Its retry is further limited, as [Unknown outcome](#unknown-outcome) says.

**Retry budget.** It comes from the table's own properties, with Iceberg Java's defaults:

- `commit.retry.num-retries`: 4;
- `commit.retry.min-wait-ms`: 100;
- `commit.retry.max-wait-ms`: 60000;
- `commit.retry.total-timeout-ms`: 1800000.

The wait doubles from the minimum, capped at the maximum, and is measured on an injected clock, so tests drive it with no sleeping (rule T10). When the budget runs out after 409s, the statement fails with `ICEBERG_COMMIT_CONFLICT`. A tainted statement whose budget runs out fails with `ICEBERG_COMMIT_STATE_UNKNOWN`.

### Unknown outcome

After a 503, any other 5xx, a timeout or a lost connection, the commit may have been applied. The committer reloads the table, retrying the load on 503 and transport errors within the same budget, and **looks up** its commit. It is committed when either holds:

- `S` is among the table's snapshots and is `main` or an ancestor of `main`;
- a snapshot in `main`'s ancestry carries `komira.commit-id = C`, which finds the commit even if the catalog rewrote the snapshot.

If committed, the statement succeeds. If neither holds:

- **`main` is still `P`.** The commit did not land: had it landed, `main` would be `S` or a descendant of `S`. The committer retries the attempt. That retry is safe even without an idempotency key: it carries `assert-ref-snapshot-id(main, P)`, so if the first request lands late, the retry gets a 409, and the lookup then finds `S`.
- **`main` has moved.** There are two possibilities. Another writer committed on top of `P` while this commit failed, or this commit landed, others committed after it, and something expired `S` before the reload. The second is rare, but a rebase would then append the statement's rows twice. So the committer does not rebase. The statement fails with `ICEBERG_COMMIT_STATE_UNKNOWN`.

If the reloads themselves keep failing until the budget runs out, the statement also fails with `ICEBERG_COMMIT_STATE_UNKNOWN`. That error names `S`, `C`, the table and the manifest-list location, so the user, or the maintenance service, can decide later. **No file is deleted after an unknown outcome** unless a lookup shows the commit absent with `main` still at `P`: a deleted data file under a commit that did land is a corrupt table.

### Cleanup

The committer deletes what it wrote in two cases:

- **After a definite failure.** This is a 4xx other than 409, a 409 that ends the statement, or a check that fails in step 2, on an untainted statement. A tainted statement deletes only when a 4xx arrives and its lookup shows the commit absent with `main` still at `P`. A tainted statement whose 409 ends it (the plan read its target, a replace's ids moved, or `main` moved) fails with `ICEBERG_COMMIT_STATE_UNKNOWN` instead of `ICEBERG_COMMIT_CONFLICT`, and deletes nothing. A deletion removes the files this statement wrote: data files, the manifest, and every manifest list it wrote.
- **After success.** The committer keeps the manifest list that the landed snapshot names in the reloaded metadata, and deletes every other manifest list this statement wrote.

Both are best-effort. A delete that fails is reported in the error's detail, or in the result's warnings, and never replaces the outcome. Files left behind by a crash, or by an unknown outcome, are orphans: no snapshot names them. They are removed by the orphan-file removal of the table's maintainer, which is the parent's step 8, or the catalog's own.

### Idempotency

`Idempotency-Key` is sent only when `/v1/config` returned `idempotency-key-lifetime`. The spec says absence of that field means no support.

- **One key per distinct request body.** Each create POST, and each commit attempt, gets a fresh UUIDv7.
- **Reuse only for a byte-identical resend.** Where the lifetime is advertised and has not run out, an unknown outcome first resends the same request with the same key, which the server answers from its stored result. Only when that resend is itself unknown does the committer run the lookup of [Unknown outcome](#unknown-outcome), and any later attempt has a new body and a new key. Without a lifetime, the lookup comes first.
- **Why not one key per statement.** A retry after a 409 has a new parent, sequence number and manifest list, so it is a different operation. The spec requires a new key for it, and a server would replay the stored 409 to a reused key.
- **Safe for the HTTP client's replays.** The HTTP client treats the header as permission to replay a POST on a stale pooled connection (`docs/design/http.md`, the replay rule). That is safe here, because the key is honoured and because the commit's requirements make a second application fail rather than double-apply.
- **`C` is not a key.** It is only the summary's `komira.commit-id`.

### What other writers and readers see

- **Two appends race**, from komira and from Spark, or from two komira sessions: both land. The loser reloads and retries.
- **komira replaces a table while another tool appends:** a replace whose query did not read the table retries and wins, and the other tool's rows are gone from `main`. That is the meaning of `CREATE OR REPLACE`. A replace that read the table fails with `ICEBERG_COMMIT_CONFLICT`.
- **Another tool compacts while komira appends:** both land. Compaction is a `replace` operation that removes no live rows. komira's append rebases onto the compacted snapshot and carries all of its manifests.
- **Another tool changes the schema or the partition spec:** a compatible change goes through as described in step 2. An incompatible one fails with a named error.
- **Readers** see the rows when they next load the table after the 200, as the parent's "Who sees what" table states.
- **Manifests are not merged in the first slice.** Each `INSERT` adds one manifest to the list. A table that takes many small inserts needs the maintainer's manifest rewrite, and the documentation says so. Iceberg Java's append merges manifests by default (`commit.manifest-merge.enabled`), and merging in the appender is later work.

## What komira writes

The parent's rules in "What komira writes into an Iceberg table" hold. This section adds what the first slice needs to meet them and resolves what they leave open.

**Paths are URIs.**

- Data files go under `write.data.path`, else under `<location>/data/`, subject to [the location rule](#credentials).
- A partitioned table adds the partition path built from the spec's transforms, `<field>=<value>/`, escaped as Iceberg Java escapes it *(to confirm)*.
- File names are `<uuid>-<writer index>.parquet`.
- Manifests and manifest lists go under `write.metadata.path`, else under `<location>/metadata/`.
- Every path in a manifest is an absolute URI, as the spec requires. The file-based writer's bare store keys (`src/iceberg/README.md`, "Paths") are not used on this path.

**Parquet.**

- Every column carries its Iceberg field id in `SchemaElement.field_id`. This is an additive change to `parquet_api` (Thrift field 9).
- komira does not set `schema.name-mapping.default` on a table it did not create. Field ids in the files are therefore what lets other readers bind columns, and a missing one is a bug.
- Compression is the table's `write.parquet.compression-codec`, else zstd.
- Row groups are cut at `write.parquet.row-group-size-bytes`. That needs a byte-based cut in the writer, which cuts by row count today.
- Files roll over at `write.target-file-size-bytes`, default 512 MiB.

**Types: Arrow to Iceberg.**

| Arrow (what the plan produces) | Iceberg | Parquet | note |
|---|---|---|---|
| bool | boolean | BOOLEAN | |
| int8, int16, int32; uint8, uint16 | int | INT32 | widened exactly |
| int64; uint32 | long | INT64 | widened exactly |
| uint64 | refused | | a representation limit (rule B21) |
| int128 (DuckDB `HUGEINT`) | refused | | |
| float32 / float64 | float / double | FLOAT / DOUBLE | NaN is counted and never a bound; -0.0 sorts below +0.0 in bounds |
| decimal128(p, s), p ≤ 38 | decimal(p, s) | INT32 for p ≤ 9, INT64 for p ≤ 18, else FIXED_LEN_BYTE_ARRAY of the minimum width for p | the writer's FIXED(16) for every precision changes on this path |
| date32 | date | INT32 DATE | |
| time64[us] | time | INT64 TIME(micros, adjusted false) | |
| timestamp[s, ms, us] without zone | timestamp | INT64 TIMESTAMP(micros, adjusted false) | widened exactly |
| timestamp[s, ms, us] with zone | timestamptz | INT64 TIMESTAMP(micros, adjusted true) | the instant; the zone name is not stored, as in Iceberg |
| timestamp[ns] | refused on v2 | | `timestamp_ns` is a v3 type |
| utf8, large_utf8; dictionary of utf8 (DuckDB `ENUM`) | string | BYTE_ARRAY UTF8 | a dictionary is written as its values |
| binary, large_binary | binary | BYTE_ARRAY | |
| fixed_size_binary(16) with the UUID extension | uuid | FIXED_LEN_BYTE_ARRAY(16) UUID | |
| fixed_size_binary(n) | fixed[n] | FIXED_LEN_BYTE_ARRAY(n) | |
| any other type (struct, list, map, null, interval, float16, decimal256, time32, date64, time64[ns]) | refused in the first slice | | |

Every refusal in the table is `ICEBERG_TYPE_UNSUPPORTED`, naming the column and the type.

**Writing into an existing table.**

- Columns map **by position**, as DuckDB's `INSERT INTO t SELECT` does. `INSERT INTO t (a, b)` maps by the listed names, and every unlisted column is null.
- Each value is cast to the table column's type by the assignment cast the binder applies for DuckDB parity.
- A cast between a zoned and an unzoned timestamp is refused by name until `query_semantics.md` §6.11 lands.
- A null in a `required` column fails the statement with `ICEBERG_NULL_IN_REQUIRED_COLUMN`, naming the column, before the commit.

**Partitioning.** Writing into a partitioned table, the sink routes rows by the default spec's transforms, as loaded at execution. All the v2 transforms are needed, because a foreign table may use any of them:

- `identity`;
- `bucket[N]` (murmur3, as specified);
- `truncate[W]`;
- `year`, `month`, `day` and `hour`;
- `void`.

A transform the writer lacks fails with `ICEBERG_TRANSFORM_UNSUPPORTED`, naming it. The partition struct is required. Each of its fields is a nullable Avro union, so a null partition value is written; today's writer cannot do that (`src/iceberg/README.md`).

The sink keeps at most a bounded number of partition writers open, a session option. When a new partition arrives past the bound, it closes the least recently used writer, and a later row for that partition opens a new file.

**Metrics.**

- Each data file's manifest entry carries `value_counts`, `null_value_counts`, `nan_value_counts`, `column_sizes`, and `lower_bounds` and `upper_bounds` in the spec's single-value encoding.
- They are computed from the Arrow batches as the file is written, with the existing `bound_*` encoders extended to the types above. The footer is not re-read.
- The table's `write.metadata.metrics.default` and `write.metadata.metrics.column.<name>` choose the mode per column: `none`, `counts`, `truncate(N)` or `full`. The default is `truncate(16)`.
- A truncated lower bound is a prefix. A truncated upper bound is a prefix with its last character incremented, so that it is still an upper bound. When that character cannot be incremented (U+10FFFF, or a result in the surrogate range), the next earlier one is incremented and the prefix shortened. For binary, the same is done with bytes: a 0xFF byte is dropped and the byte before it incremented. When no character or byte can be incremented, the upper bound is omitted. *(To confirm against Iceberg Java's truncation; the spec allows truncation but does not define it.)*
- `split_offsets` are the row-group starts.

**Snapshot summary.**

- The spec's `added-*` counters.
- For a replace, the `deleted-*` and `removed-*` counters of what left `main`.
- The `total-*` counters, computed from the base snapshot's totals. When the base summary lacks a `total-*` key, the new summary omits it rather than guessing.
- `komira.commit-id`.
- No other `komira.*` key in the first slice; see [Corrections to other documents](#corrections-to-other-documents) for the parent's `komira.writer.<id>.last-commit`.

**Properties set at create:** `format-version=2` and `write.parquet.compression-codec=zstd`, and nothing else. `komira.maintenance` and the parent's other properties arrive with the maintenance service. A table komira creates in the first slice is therefore an ordinary Iceberg table that nobody maintains until the user's tools or the catalog do, and the documentation says so.

## Pruning

Pruning never changes a result: it skips only files that provably hold no row passing the scan's filter. The filter on a scan node has exactly the semantics of a filter node above an unfiltered scan (`query_semantics_scans.md`), so a pruned scan and an unpruned one return the same rows, under DuckDB's semantics.

**Where it runs.** The party that lowers the scan resolves the pin (`optimized_plan_sources.md` §15.3.2), then plans the scan's files:

- in the first slice, the session's own process;
- later, the coordinator, which hands each host its share.

The plan never carries a file list. A file list can be millions of entries, and the pin already names exactly one set of files: the manifest list of `snapshot_id`. A pinned scan reads with the schema of the pin's `schema_id`. For time travel, that is the snapshot's own schema, or the current schema when the snapshot records none. The optimizer's statistics come from manifest metadata, the snapshot summary's totals and the manifest list's counts, into `advice.stats_basis`, as §15.4.1 says.

**The four stages**, as the spec describes scan planning:

1. **Manifest list.** For each manifest, project the filter onto the manifest's own partition spec (by its `partition_spec_id`, not the current spec) with an **inclusive projection**. For example, `order_ts >= T` under `day(order_ts)` becomes `order_ts_day >= day(T)`. Then evaluate the projection against the manifest's partition field summaries (`contains_null`, `contains_nan`, `lower_bound`, `upper_bound`), and skip the manifest when it cannot match. A delete manifest is skipped by the same test.
2. **Manifest entries.** Skip DELETED entries. For each live entry, evaluate the projected filter on the entry's partition tuple, then the original filter on the entry's metrics:
   - `x = v` cannot match when `v < lower` or `v > upper`.
   - `x IS NULL` cannot match when `null_value_counts[x] = 0`.
   - `x IS NOT NULL` cannot match when the null count equals the value count.
   - `isnan(x)` cannot match when `nan_value_counts[x] = 0`.
   - `x LIKE 'p%'` is tested against the bounds' prefixes.
   - A missing metric means "may match", for every predicate.
3. **Deletes.** A delete file applies to a remaining data file under the spec's rules:
   - **A position delete** applies when the data file's sequence number is at or below the delete's, and either its partition spec and value equal the data file's, or its `referenced_data_file` names the data file.
   - **An equality delete** applies when the data file's sequence number is strictly below the delete's. It must also have the same spec and partition, unless it was written under an unpartitioned spec, in which case it applies to every partition.
   - A delete file that applies to no remaining data file is not read.
4. **Row groups and pages.** Inside each file, the existing Parquet row-group, page-index and bloom-filter pruning runs (`src/parquet_scan/README.md`).

**What the evaluator must get right.** Each item below is a case in the tests:

- **NaN.**
  - NaN never appears in a bound.
  - DuckDB orders NaN above every other value and holds `NaN = NaN`. So on a float or double column, a predicate that a NaN row could satisfy (`>`, `>=`, `<>`, `= 'NaN'`) skips a file by its upper bound only when `nan_value_counts[x]` is present and 0. An example: a file with values 1.0, 5.0 and NaN has bounds [1, 5], and `x > 10` must still read it.
  - A float file with only NaN values has no bounds.
- **Type promotion.** A bound written as int under a column now typed long is 4 bytes; it decodes by its stored length. Decimal bounds are compared at the column's scale.
- **Truncated bounds.** A truncated bound proves only a prefix. `x = 'abcdefghijklmnopq'` cannot be skipped by a 16-character bound that equals its prefix.
- **Timestamps.**
  - A timestamptz bound is UTC microseconds.
  - A filter literal with a zone is converted first.
  - `day()` projections of timestamptz are UTC days.
- **Unknown.** A predicate the evaluator does not understand, such as a UDF or a cast it cannot invert, is kept as "may match", never as "cannot match".
- **Schema evolution.** A column added after a file was written has no metrics in that file. The evaluator cannot tell that from metrics mode `none`, so the file may match, for `x IS NULL` and `x = 5` alike. On v1 and v2 the column reads as null. v3's `initial-default` is outside the first slice.

**Pushdown.** The Iceberg source implements `supports_filter_pushdown` per predicate, as the Parquet source does (`src/scan_source/parquet_source.mojo:491`). Its scan binding carries a SHAPED `pushdown_gate`. A predicate the evaluator handles may be placed on the scan, and the rest stay above it.

## The plan wire

### `WireWriteTarget` gains the Iceberg arm

This takes `plan_models.md` §2.2.6 and gives the arm the fields a batch write needs. Nothing in the §2.2.6 sketch is on the wire yet, so the fields are chosen here.

```proto
// plan.proto
message WireWriteTarget {
  oneof destination {
    string          path    = 1;   // existing (COPY TO); moved into the oneof, same number
    WireIcebergSink iceberg = 10;
    // held: 11 topic, 12 delivery, 13 late_rows (plan_models.md §2.2.6)
  }
  WriteFormat      format = 2;     // path only; must be the default with `iceberg`
  WriteCompression codec  = 3;     // path only; must be the default with `iceberg`
  WireSourceAccess access = 4;     // credentials_and_writes.md: path only, the destination's credential
                                   // name and store settings; absent = a local destination;
                                   // must be absent with `iceberg`
}

message IcebergTableRef {          // moves here from optimized_plan_sources.md §15.3.1
  WireIcebergCatalog catalog   = 1;  // re-typed from a name: the catalog's uri, warehouse, access (its
                                     // credential NAME and signing), vended (access_delegation), and data_access (the table
                                     // files' credential NAME when the catalog vends none).
                                     // Never a session-local name or a value
  repeated string    namespace = 2;  // one entry per level
  string             name      = 3;
}
// WireIcebergCatalog (uri = 1, warehouse = 2, access = 3, vended = 4, data_access = 5) and WireSourceAccess
// are the binding model's messages (credentials_and_writes.md, decision 4); this document adds no field to them.

message WireIcebergSink {
  IcebergTableRef      table         = 1;
  IcebergWriteModeWire mode          = 2;  // plan_vocabulary.proto
  bool                 if_not_exists = 3;  // CREATE only
  bytes                table_uuid    = 4;  // APPEND: 16 bytes; CREATE: empty; CREATE_OR_REPLACE: 16 bytes, or empty when the name did not exist at bind time
  int32                schema_id     = 5;  // APPEND: the schema the binder mapped columns against
}

// plan_vocabulary.proto, appended; wire value = engine value + 1, baselined like the other vocabularies
enum IcebergWriteModeWire {
  ICEBERG_WRITE_MODE_WIRE_UNSPECIFIED       = 0;  // refused on decode
  ICEBERG_WRITE_MODE_WIRE_APPEND            = 1;
  ICEBERG_WRITE_MODE_WIRE_CREATE            = 2;
  ICEBERG_WRITE_MODE_WIRE_CREATE_OR_REPLACE = 3;
  // 4 is held for UPSERT (plan_models.md §2.2.6)
}
```

**What the decoder enforces.** The decoder refuses each of these by name:

- a target with no destination;
- an empty `path`;
- an absent `catalog`, an empty `catalog.uri`, or an empty `name`;
- a `catalog.access` or `catalog.data_access` the binding model's decoder refuses: a credential name outside its grammar, a `vended.` name in a client-submitted plan, or a `uri` or endpoint with user information, a query or a fragment;
- `access` set beside `iceberg`;
- mode `UNSPECIFIED`;
- `if_not_exists` outside `CREATE`;
- a `table_uuid` that is neither empty nor 16 bytes, empty under `APPEND`, or present under `CREATE`;
- a non-default `format` or `codec` beside `iceberg`.

**What is not on the wire.** Facts the body already holds are not repeated in the header:

- the schema to create, which is the plan's output schema;
- whether the plan reads its target, which is any scan pin with the same table uuid;
- the snapshots it read.

The party that commits decodes the body, and derives them from it ([Who commits](#who-commits)). A header copy would be a duplicate that a scheduler, which never decodes the body, could not check. The commit id and every credential value are not on the wire either ([Commit semantics](#commit-semantics)). The credential names are, in the body and in `DeclaredNeeds.credentials`, as the binding model requires: the catalog's (`IcebergTableRef.catalog.access`) and the table files' (`IcebergTableRef.catalog.data_access`).

**How `access = 4` and the Iceberg arm fit together.** There is one `WireWriteTarget`, written the same in both designs: this document's `oneof destination { path = 1; iceberg = 10 }`, `format = 2` and `codec = 3`, plus the binding model's `WireSourceAccess access = 4`. `access` belongs to a `path` destination only, and the decoder refuses it beside `iceberg`. An Iceberg write takes every credential name from its table's catalog: `catalog.access` for the catalog's API and `catalog.data_access` for the table's files. That keeps the names in one place for a scan and a write of the same table, because a scan has no write target. The Iceberg arm requires at least version 6 (below). A `path` write with `access` follows the binding model's own version rule. The two cannot meet in one target, and a plan whose sources and target raise the version for different reasons declares the larger minimum.

**`IcebergTableRef.catalog` is re-typed, not renumbered.** `IcebergTableRef` has never shipped: it exists only in `optimized_plan_sources.md` §15.3.1. Re-typing field 1 from a name to a `WireIcebergCatalog` therefore breaks no plan anyone wrote (rule B8 applies to shipped formats).

**Why this is not the CTAS that `plan.proto` forbids.** The comment above `WireWriteTarget` rules out a CTAS arm "deliberately and permanently". That CTAS registers an `InMemorySource`, live heap data inside the IR, and makes a table no later plan can reference over the wire. An Iceberg `CREATE` makes a table in the user's catalog, which every later plan reaches by `IcebergTableRef`. The comment's reason does not apply, and the comment changes in the same pull request to say so. The envelope's "PRESENT = write them there, and also return them" becomes a per-arm contract:

- `path` returns the rows it wrote;
- `iceberg` returns one row, `Count BIGINT`, matching what DuckDB returns for the statement.

**Version.** An envelope whose write target is the Iceberg arm declares **format version 6**, and the accepted set becomes `{4, 5, 6}`. The existing rules carry over by arm:

- A decoder refuses an *understated* version: the Iceberg arm with a declared version below 6, as it refuses a write target below 5 today.
- An *overstated* version stays accepted, as today (`plan_wire_admit.mojo`, "IT IS NOT SYMMETRIC, DELIBERATELY").
- A reader that speaks only `{4, 5}` refuses version 6 by name, before it reaches field 10.

`_envelope_version_for` derives the version from the arm, and the minimum-version constant becomes per arm.

**`OptimizedPlan`.** Its header carries the same `write_target` (`optimized_plan.md`), so a scheduler authorizes the write from `iceberg.table` without decoding the body. `OptimizedPlan` has its own `format_version`. A plan with the Iceberg arm declares the first `OptimizedPlan` version that includes the arm, which is assigned when `OptimizedPlan` is first released. The header's validity rule for `write_target` gains the decoder rules above, and the digest binds the arm as it binds `path`.

### Who commits

**Exactly one committer per statement**, never a host and never the job manager:

- **Hosts.** The Iceberg file sink is a new sink arm beside the file arms of `SinkVariant`. On each host it writes data files and returns their `DataFile` records (path, size, record count, spec id, partition tuple, metrics) to the committer.
- **Job manager.** It accepts only a serializable `OptimizedPlan` and does not decode the body (rule B21), so it cannot build manifests.
- **First slice.** The committer is the session itself.
- **Plans that span hosts.** It is the coordinator, after every segment that feeds the sink has finished. That is the same barrier shape as the shuffle's seal (`docs/architecture.md`, the shuffle).

A failed segment fails the statement before any commit. The committer then deletes the files the finished segments wrote ([Cleanup](#cleanup)).

## Errors

Every error message starts with its token, and the Python layer maps each `ICEBERG_*` token to an exception class under `komira.IcebergError`, a `KomiraError`. No message contains a secret or a raw response body. Every token is new except the `OPTIMIZED_*` ones. Names, credentials and statements are refused with the binding model's codes, which this document uses and does not redefine: `BIND_NAME_UNBOUND`, `BIND_NOT_A_CATALOG`, `CREDENTIAL_UNBOUND`, `CREDENTIAL_KIND_MISMATCH`, `CREDENTIALS_NOT_FOUND` and `SQL_STATEMENT_UNSUPPORTED`.

| token | raised by | when |
|---|---|---|
| `SQL_STATEMENT_UNSUPPORTED` | `sql` | a statement or clause outside the first slice, named |
| `BIND_NAME_UNBOUND`, `BIND_NOT_A_CATALOG` | binder (the binding model's codes) | a qualified name whose first part has no binding, or is bound to something other than a catalog |
| `ICEBERG_COLUMN_AMBIGUOUS` | binder | an insert column list that matches two table columns differing only in case |
| `ICEBERG_NAMESPACE_NOT_FOUND` | `iceberg_catalog` | 404 with `NoSuchNamespaceException` |
| `ICEBERG_TABLE_NOT_FOUND` | `iceberg_catalog` | 404 with `NoSuchTableException`, or any other 404 on a table path |
| `ICEBERG_TABLE_ALREADY_EXISTS` | `iceberg_catalog`, binder | the name exists at bind time, or a 409 on the create POST or on a staged create's commit |
| `ICEBERG_CATALOG_UNAUTHORIZED` | `iceberg_catalog` | 401 or 419, after one token refresh |
| `ICEBERG_CATALOG_FORBIDDEN` | `iceberg_catalog` | 403 |
| `ICEBERG_CATALOG_REJECTED` | `iceberg_catalog` | 400; quotes the catalog's `error.message` |
| `ICEBERG_CATALOG_ENDPOINT_UNSUPPORTED` | `iceberg_catalog` | the server's `endpoints` list lacks one this statement needs |
| `ICEBERG_CATALOG_UNAVAILABLE` | `iceberg_catalog` | a config, load or create request, or a token request, still failing with 503, a 5xx or a transport error at the end of the budget |
| `ICEBERG_CREDENTIALS_EXPIRED` | `iceberg_catalog` | vended credentials expired with no route to renew them |
| `ICEBERG_LOCATION_REFUSED` | committer | a data or metadata path outside the table's location and the vended prefixes, or a scheme with no store |
| `ICEBERG_COMMIT_CONFLICT` | committer | a 409 that ends the statement: the budget is spent, the plan read its target, or a replace's ids moved |
| `ICEBERG_COMMIT_STATE_UNKNOWN` | committer | the outcome could not be determined, including a tainted statement that a 409 ends; names the snapshot id, the commit id and the manifest list |
| `ICEBERG_TABLE_REPLACED` | committer | the table uuid differs from the plan's |
| `ICEBERG_SCHEMA_INCOMPATIBLE` | committer | a written column was dropped or changed type incompatibly |
| `ICEBERG_WRITE_FORMAT_UNSUPPORTED` | committer | a write to a v1 or v3 table |
| `ICEBERG_TYPE_UNSUPPORTED` | binder | a column type with no mapping in the first slice |
| `ICEBERG_TRANSFORM_UNSUPPORTED` | sink | a partition transform the writer lacks |
| `ICEBERG_NULL_IN_REQUIRED_COLUMN` | sink | a null bound for a `required` column |
| `OPTIMIZED_PIN_TABLE_UUID_CHANGED`, `OPTIMIZED_PIN_SNAPSHOT_EXPIRED`, `OPTIMIZED_SOURCE_FEATURE_UNSUPPORTED` | host | scans, as `optimized_plan_sources.md` §15.3.2 and §15.4.1 define them; the last also names format version 3 |

## Package changes

| package | change |
|---|---|
| `iceberg` | a general `TableMetadata` parser for v1 and v2 metadata (v3 is refused by name), over `json`'s DOM, replacing the byte scanners on every path that reads another writer's metadata; manifest-list and manifest readers with schema resolution, for files another writer wrote; Parquet position- and equality-delete readers beside the Avro ones; the types and transforms above; nullable partition fields; partition summaries in the manifest list; the metrics modes; URIs for paths; the pruning evaluator (inclusive projection, the metrics evaluator, the delete-file matcher). The file-based writer stays, for `cdc_ingest` |
| `iceberg_catalog` | `IcebergRestRequest` gains `method` and `body`, and the transport's `get` becomes `send`; the scripted transport records the method, the body and every header; the top-level config fields; `create_table`, `commit_table(requirements, updates, idempotency_key)` and `credentials` on `IcebergRestCatalog`; typed `TableRequirement` and `TableUpdate` values with their JSON; the committer of [Commit semantics](#commit-semantics); the bearer and OAuth2 client-credentials providers and SigV4 request signing, each built from a credential the session's resolver returned for the catalog's credential name; the error tokens. It depends on `iceberg` (for the schema, spec and snapshot types) and `aws_core` (for signing). `iceberg` does not depend on it, so HTTP stays out of the format package |
| `parquet_api`, `parquet` | `SchemaElement.field_id`, written and read; on read, columns bind by field id, falling back to `schema.name-mapping.default`, then to names |
| `parquet_writer` | narrow and unsigned integer widening; BINARY, FIXED_LEN_BYTE_ARRAY and UUID columns; timestamp and time annotations; decimal at the minimum width; a byte-based row-group cut; per-column metrics returned beside the bytes |
| `sql` | three-part and longer names; `INSERT INTO ... SELECT` and `VALUES`; `CREATE TABLE <name> (<columns>)`; qualified names in `CREATE [OR REPLACE] TABLE [IF NOT EXISTS] ... AS`; `SQL_STATEMENT_UNSUPPORTED` for the statements outside the slice; binder resolution of `catalog.ns.table` through the statement's bindings (the binding model's `(statement, bindings)` input) to the `komira.iceberg.table` kind, with the catalog's `WireIcebergCatalog`, its `data_access` set from the covering scope, in the plan |
| `arrow`, `plan_proto`, `plan_wire` | `WriteTarget` gains the Iceberg form; the wire arm, enum and version above, with goldens; `IcebergTableRef` moves into `plan.proto` with field 1 re-typed to the binding model's `WireIcebergCatalog` |
| `lowering`, `pipeline_exec`, `sdk_exec` | the Iceberg file sink arm, in its own file per the lowering split, after lowering's writes slice; the scan planner for `komira.iceberg.table`; `run_sql` serves the write statements |
| `so` (C ABI), the Python package | nothing of its own for declaring or binding: `komira.iceberg`, the credential classes, `komira.SigV4`, `bind` and `sql(**sources)` are the binding model's, encoded as its `WireBoundSource`. This document adds `read_table` and the `ICEBERG_*` exception classes |

**No new catalog trait.** `IcebergCatalog` keeps its one method. The committer is generic over `IcebergRestCatalog[T, P]`, with its transport `T` and credentials `P`. A trait for "catalogs that commit" would have one implementation until the Glue or Hive Metastore adapter lands, so it waits for that adapter (rule R9).

Several texts say `iceberg_catalog` is read-only and "writes stay storage-based": the package's headers (`__init__.mojo`, `iceberg_catalog.mojo`), its README, and the rows in `docs/architecture.md`. They change in the pull request that adds the write path, step 1 below. Until then they describe the code accurately: the package is read-only.

## Order of work

Each step is usable and tested on its own.

1. **Catalog create and commit** (`iceberg_catalog`, `iceberg`):
   - the transport with methods and bodies;
   - config with `warehouse`, `endpoints`, `namespace-separator` and the idempotency lifetime;
   - create (staged and direct), commit and credentials;
   - requirements and updates;
   - the committer, with its retries, the unknown outcome, tainting and cleanup;
   - the auth providers and the typed errors;
   - the `TableMetadata` parser and the manifest-list reader for foreign lists, since the committer reloads tables and carries the base's manifests;
   - a new in-process test catalog ([Tests](#tests)).

   Proof: create, commit and a concurrent-commit conflict against the test catalog.
2. **Parquet for Iceberg** (`parquet_api`, `parquet`, `parquet_writer`): field ids written and read, the new column types, annotations, decimal widths, byte-based row groups, metrics returned beside the bytes.
3. **The write sink** (`arrow`, `plan_proto`, `plan_wire`, `sql`, `lowering`, `pipeline_exec`, `sdk_exec`): `INSERT` and the `CREATE` forms through the committer, and the wire arm. It follows lowering's writes slice. Proof: read back by komira and by the pinned DuckDB as a foreign reader.
4. **The scan with pruning** (`iceberg`, `lowering`): the manifest readers, the Parquet delete readers, the evaluator and the pushdown gate. Proof: equal to DuckDB's `iceberg_scan` on a table from a foreign writer, and the pruning cases of [Pruning](#pruning).
5. **The Python surface**: `read_table`, the `ICEBERG_*` error classes, and Python tests against the loopback test catalog, using `komira.iceberg` and `bind` from the binding model. It follows that model's "catalogs" milestone in `credentials_and_writes.md`.

The held interop procedure ([Tests](#tests)) lands with step 3, and the pinned DuckDB Iceberg extension lands with step 3's parity datasets.

Later work, outside this document's slice:

- the position-delete writer (`UPDATE`, `DELETE`, `MERGE`, and the parent's `overwrite` modes);
- partitioned `CREATE` and `ALTER TABLE`;
- the v3 reader and v3 writes;
- nested types;
- manifest merging in the appender;
- `cdc_ingest` onto the committer, which means retiring its equality deletes, as the parent requires;
- the maintenance service;
- the Glue and Hive Metastore adapters.

## Tests

Each test is in its component's language: Mojo for the packages, Python only for the Python surface (rule T11). All are hermetic: no network, no fixed ports, and loopback with port 0 where a socket is needed (rule T12). Time comes from an injected clock (rule T10).

**The test catalog.** A new in-process Iceberg REST catalog, conforming to `IcebergRestTransport` and backed by an in-memory object store. It applies requirements and updates as the spec defines them, writes each new `metadata.json` and swaps its pointer, and honours idempotency keys as the spec defines them. It can be scripted to:

- interleave a second writer's commit, schema change or spec change between a load and a commit;
- answer 409, 503 (with and without `Retry-After`), 500, 502 or 504, before or after applying a commit;
- drop the connection after applying;
- expire a snapshot right after a commit;
- expire tokens and vended credentials;
- omit `endpoints`, `idempotency-key-lifetime` or `refs`.

A loopback variant serves the same logic over `http_server`, for the HTTP transport and the Python tests.

**The cases**, by step:

- **Requests.**
  - Exact bytes of the create, staged-create commit, append commit and replace commit, against golden JSON files.
  - Percent-encoding of multi-level namespaces, with the default separator and with an advertised one.
  - `warehouse` on config.
  - `endpoints` and `idempotency-key-lifetime` read from the top level and not from the merged map.
  - The access-delegation header on load and create, and absent under `none`.
- **Responses.** Every row of [What each response means](#what-each-response-means):
  - a 200 with `main` at `S`, and with `main` a descendant of `S`, both succeed; a 200 whose metadata lacks `S` and `C` fails with `ICEBERG_COMMIT_STATE_UNKNOWN`;
  - a 409 then success on an append;
  - a 409 on an append whose plan read the target fails, naming the pinned and new snapshot ids. The same holds when the plan reads the target through a view, through a self-join, or through a second catalog alias;
  - a 409 past the budget;
  - a replace whose reload shows a moved `last-column-id` fails;
  - a 503 is an unknown outcome, and `Retry-After` sets the wait;
  - a 500 *after* the catalog applied the commit succeeds, with no second snapshot;
  - a 500 *before* it applied retries once and succeeds;
  - a dropped connection after apply is found by `S`;
  - a commit whose snapshot was rewritten is found by `komira.commit-id`;
  - an unknown outcome after which `main` moved and `S` was expired fails with `ICEBERG_COMMIT_STATE_UNKNOWN`, with no second append and no file deleted;
  - an unknown outcome followed by a 409, and then by a 403, both find the landed commit and delete nothing;
  - a tainted replace, and a tainted append that read its target, whose 409 ends the statement, fail with `ICEBERG_COMMIT_STATE_UNKNOWN` and delete nothing;
  - success after a rewritten snapshot keeps the manifest list the landed snapshot names;
  - a staged create whose first commit is unknown and whose retry gets a 409 succeeds when the table holds `S`;
  - a definite failure deletes exactly this statement's files;
  - success deletes the superseded manifest lists.
- **Refusals, one case per token.** Each token of [Errors](#errors) that the cases above do not raise gets its own case, asserted by exact message:
  - `BIND_NAME_UNBOUND` and `BIND_NOT_A_CATALOG` on a qualified name, `ICEBERG_COLUMN_AMBIGUOUS`;
  - `ICEBERG_NAMESPACE_NOT_FOUND` and `ICEBERG_TABLE_NOT_FOUND` from the two 404 bodies;
  - `ICEBERG_CATALOG_REJECTED` from a stage-create 400;
  - `ICEBERG_CATALOG_ENDPOINT_UNSUPPORTED` from an `endpoints` list without the commit route;
  - `ICEBERG_CATALOG_UNAVAILABLE` from 503s on load past the budget;
  - `ICEBERG_TABLE_REPLACED` from a recreated table with the same schema id;
  - `ICEBERG_WRITE_FORMAT_UNSUPPORTED` from a v1 and a v3 table;
  - `ICEBERG_NULL_IN_REQUIRED_COLUMN`;
  - `ICEBERG_LOCATION_REFUSED` from a scheme with no store;
  - `SQL_STATEMENT_UNSUPPORTED` from each refused statement.
- **Create forms.**
  - `IF NOT EXISTS` on an existing name runs no query.
  - A concurrent create on the same name, for `CREATE`, `IF NOT EXISTS` and `CREATE OR REPLACE`; the last deletes its files and reruns on the replace path.
  - A 409, and a 5xx then success, on the create POST.
  - A tainted staged create that finds the table present without `S` or `C` fails with `ICEBERG_COMMIT_STATE_UNKNOWN` and deletes nothing.
  - A zero-row `CREATE TABLE AS` creates a table with no snapshot.
  - A zero-row `INSERT` sends no commit.
  - A zero-row replace leaves an empty table.
  - `NOT NULL` maps to `required`; other constraints are refused.
- **Spec and schema changes.** A spec added between load and commit leaves the append valid, under the old spec id. A compatible added column. A dropped column. A promoted type. A replace that reuses ids by name and assigns new ones above `last-column-id`.
- **Metadata parsing.** `main` derived from `current-snapshot-id` when `refs` is absent; `-1` read as none; a snapshot id collision draws again.
- **Idempotency.**
  - The key is sent only when the lifetime is advertised.
  - A byte-identical resend carries the same key.
  - A retry after a 409 carries a new key.
  - The create POST and the commit POST carry different keys.
  - The test catalog replays its stored response to a reused key.
- **Auth and credentials.**
  - The first token comes from a given token URL before any config request.
  - The token is refreshed at expiry, by the injected clock.
  - A 401 refreshes once and resends once; a second 401 fails.
  - Vended credentials are renewed before an upload part and before a cleanup delete.
  - A staged create with expiring credentials and no credentials endpoint fails with `ICEBERG_CREDENTIALS_EXPIRED`.
  - A `write.data.path` outside the table's location is refused.
  - No secret appears in any error: each error is asserted by exact equality (rule T13).
- **Binding.**
  - With the catalog bound under the name `cat` and its credential named `lake-etl`, `s.sql("SELECT * FROM cat.sales.orders", cat=lake)` plans a `komira.iceberg.table` scan whose `IcebergTableRef.catalog` holds the test catalog's `uri`, its `warehouse` and the credential name `lake-etl`. No string field of the decoded plan equals `cat`, and the encoded plan holds no byte sequence of the client secret.
  - `access_delegation="none"` encodes `vended = false`, and the test catalog records no `X-Iceberg-Access-Delegation` header on the load.
  - The same statement under `s.bind("cat", lake)` encodes to the same bytes.
  - The same statement with `cat` unbound fails with `BIND_NAME_UNBOUND`, before any request reaches the test catalog; with `cat` bound to a file source it fails with `BIND_NOT_A_CATALOG`.
  - Two hosts of a fake multi-host run each load the table's vended credentials from the test catalog under `lake-etl`, and the test catalog records one credentials request per host; nothing passes between them.
  - A catalog that vends nothing plans a scan whose `IcebergTableRef.catalog.data_access` names the covering scope's credential.
  - A staged `CREATE TABLE ... AS` on two fake hosts writes each host's files under the staged location through `data_access`. With a vend-only catalog, it does so through the run-scoped `vended.<statement id>` name, which the fake resolver drops at the run's end.
  - The decoder refuses a `WireWriteTarget` with both `iceberg` and `access`, and a client-submitted plan naming a `vended.` credential.
  - Two loads of one table under two credential names, or two generations of one name, are two cache entries.
  - The binding rules themselves (per call, on the session, and which wins) are tested with the binding model in `credentials_and_writes.md`, not here.
- **Writes.**
  - Every row of the type table, refusals included.
  - Every transform, against the spec's test vectors (for example, `bucket[16]` of the int `34` is `3`).
  - Null partition values.
  - The open-writer bound.
  - Truncated upper bounds, including the U+10FFFF, 0xFF and no-increment cases.
  - -0.0 and +0.0 in bounds.
  - Field ids in every column.
  - Missing base totals are omitted.
  - `timestamp-ms` never precedes the parent's.
- **Pruning.** Each case of "What the evaluator must get right", including the file with bounds [1, 5] and one NaN under `x > 10`. Each case asserts both the files opened, counted by a counting store, and that the result equals the unpruned scan.
- **Foreign reader and DuckDB parity.**
  - `sql_oracle` datasets in which the pinned DuckDB reads, with `iceberg_scan`, a table komira wrote over the test catalog's files, and komira reads a table DuckDB wrote. Results must be equal.
  - The Iceberg extension is pinned by sha256 like the CLI and loaded from its file path, so nothing is fetched at test time *(to confirm that the pinned DuckDB loads it offline, along with any extension it depends on)*.
- **Wire.**
  - Goldens for each mode.
  - The decoder refusals above, one case each.
  - An understated version is refused, and an overstated one accepted.
  - The previous release's decoder refuses a version-6 envelope by name.
  - The new decoder still reads every version-4 and version-5 golden (rule B8).

**Interop with real catalogs.** The hermetic tests prove komira against komira's own reading of the spec. Real catalogs are checked by a held procedure the owner runs, never by a pull request's check (rule B9):

- It runs the write and read cases of the Python tests against the Apache Iceberg REST reference fixture and Polaris, each started from an image pinned by digest on the owner's machine. It also runs against the cloud catalogs (Glue, S3 Tables, BigLake, Unity).
- It is dry-run by default.
- It tags every cloud resource it creates with the run id, and removes them all (rules S3 and T14).
- Its results are recorded in this document: each *to confirm* item becomes a stated fact or a named refusal.

## Compatibility

- **Wire.** Additive: a new oneof arm, new messages and a new enum, and version 6 added to the accepted set. `path` keeps field number 1, so every existing envelope decodes unchanged. `IcebergTableRef.catalog` is re-typed, which B8 allows only because the message has never shipped. The B8 tests are the last two named under Wire in [Tests](#tests).
- **Tables.** komira writes plain Iceberg v2. On a table it did not create, it writes data files, manifests and snapshot summaries, and nothing else, except under `CREATE OR REPLACE`, which by definition replaces schema, spec and sort order. Other engines read the tables with no komira code (rule B21).
- **The file-based writer** and its tables are unchanged.

## Decisions

Each decision states the recommendation first.

1. **REST first, and the committer is komira's own Mojo code over `iceberg_catalog`.**
   - Rejected: binding a Java, Python or Rust Iceberg library. That would put a second runtime in the engine, and a Python dependency for non-Python code (rule B5).
2. **The catalog writes `metadata.json`; komira sends requirements and updates.**
   - Rejected: komira writing the metadata file and registering it. That is the file-system scheme the spec calls unsafe, and `register` is not a commit.
3. **`CREATE TABLE ... AS` uses a staged create, and a catalog that refuses it fails by name.**
   - Rejected: create-then-append. It shows readers an empty table, and leaves one behind on failure.
   - Rejected: falling back to create-then-append when staging is refused. That is runtime machinery for a catalog capability the interop runs check once (rule B20).
4. **The snapshot id and commit id are fixed per statement; the parent, sequence number and manifest list are rebuilt per attempt; the manifest is written once.**
   - Rejected: a new snapshot id per attempt. That loses the cheapest unknown-outcome check.
   - Rejected: ids carried in the plan. A cached plan run twice would look like one commit.
5. **A statement that reads its target table never rebases.** A 409 is a conflict. The committer finds such reads from the body's pins, not from a header flag.
   - Rejected: always retrying appends. `INSERT INTO t SELECT ... FROM t` would append rows computed from a state the table has left.
6. **After an unknown outcome, retry only while `main` is still at the attempt's parent; otherwise fail with `ICEBERG_COMMIT_STATE_UNKNOWN`.** This closes the duplicate-append window that snapshot expiry opens, without a per-writer table property.
   - Rejected: the parent's `komira.writer.<id>.last-commit` property for every session. One property per session would grow every table's metadata without bound.
7. **One `Idempotency-Key` per request body, sent only where advertised.**
   - Rejected: one key per statement. The spec requires a new key for a new body, and a server would replay a stored 409.
   - Rejected: always sending a key. The spec defines absence of the lifetime as no support.
8. **A 503 on a commit is an unknown outcome.** The spec says it "could have been partially processed".
9. **No file deletion after an unknown outcome until a lookup proves the commit absent; best-effort deletion after a definite failure; orphans left to the table's maintainer.**
10. **Pruning runs where the scan is lowered, from the pin; the plan carries no file list.**
    - Rejected: the producer listing files into the plan. Plans would grow with the table, and the pin already names the file set exactly.
11. **SQL is the first door, in DuckDB's forms. A catalog is a source the user holds (`komira.iceberg`), bound to a SQL name through the binding model of `credentials_and_writes.md`; this document adds `read_table` and `komira.IcebergError`.** The binder plugs the source in from the statement's bindings. The plan carries the catalog's location and its credential's name, never the name the user typed in SQL.
    - Rejected: an Iceberg-only registration call (`attach_iceberg`) and a session lookup by name (`catalog("lake")`). That would be a second way to declare a source beside the shared one.
    - Rejected: SQL `ATTACH ... (TYPE iceberg, ...)` in the first slice. It would put secrets in SQL text, which plans and logs carry.
12. **Write format v2 only and read v1 and v2; refuse v3 by name.** v3 needs row lineage, deletion vectors and `initial-default`, which come later.
13. **The commit loop goes in `iceberg_catalog`, which now depends on `iceberg`. There is no new package and no new trait.**
    - Rejected: a separate commit package. Its only callers are the sink and the catalog.
    - Rejected: a commit trait with one implementation (rule R9).
14. **Columns map by position on `INSERT`**, as DuckDB does, and are written by field id.
15. **`CREATE OR REPLACE` on an existing table is Iceberg's replace: same uuid and history, new schema, unpartitioned and unsorted.** It is allowed on a table komira did not create, because the user named that statement.
16. **komira writes only under the table's location or a vended prefix.** A catalog-supplied path cannot direct komira's own credentials elsewhere.

## Corrections to other documents

These change in the pull request that lands the matching step, except the first, which this pull request makes.

- **`storage_stack.md`, "What does not exist yet".** It says there is no Parquet writer and no Iceberg writer. Both exist: `src/parquet_writer`, and the file-based writer in `src/iceberg`. This pull request corrects that line.
- **`storage_stack.md`, "The catalog seam".** It grows `IcebergCatalog` to seven verbs. Until a second adapter exists, the first adapter's verbs are methods of `IcebergRestCatalog`, and `IcebergCatalog` keeps `load_table`.
- **`storage_stack.md`, "The commit client", step 4.** Its third lookup, the `komira.writer.<writer-id>.last-commit` property, is replaced by decision 6.
- **`storage_stack.md`, `create_or_replace`.** It lists only `assert-table-uuid` on a replace. The replace here also asserts the ref, the schema, and the field, spec and partition ids, as listed under [One attempt](#one-attempt).
- **`storage_stack.md`, v3 tables of other owners.** It refuses row-level writes there. The first slice also refuses appends and reads, for the row-lineage and deletion-vector reasons above.
- **`storage_stack.md`, "never equality deletes".** `cdc_ingest` writes them through the file-based writer. That is not a contradiction on this path, which writes none. Moving `cdc_ingest` onto the committer has to retire them.
- **`plan_models.md` §2.2.6.** It sketches `WireIcebergSink` with APPEND and UPSERT only. This document fills in the batch fields, and holds number 4 of the mode enum for UPSERT and numbers 11 to 13 of the target for streaming.
- **`optimized_plan_sources.md` §15.3.1.** `IcebergTableRef` moves to `plan.proto`, because `plan.proto` cannot import `optimized_plan.proto`, and its field 1 becomes the binding model's `WireIcebergCatalog` (uri, warehouse, credential name and signing) in place of a catalog name that "the deployment, or the session that attached it" maps. A session-local name never reaches the wire.
- **`optimized_plan_sources.md` §15.4.1, and `DataScope` in §15's needs.** The kind's `catalog` STR param, `WireScanBinding.table_catalog` and `DataScope.catalog` hold a catalog name today. Under the binding model they carry the catalog's `uri` and `warehouse` (and the credential name where a header needs it), never a session-local name.
- **`optimized_plan_sources.md` §15.9.** `read_table` takes the held catalog source, not `km.catalog("lake")`, in each SDK's example. Its `as_of=` takes a snapshot id. The timestamp form maps to `as_of_timestamp_ms` and comes later.
- **`plan.proto`.** The `WireWriteTarget` comments change: "COPY ... and nothing else" and "NO CTAS ARM" (see [The plan wire](#the-plan-wire)), and "PRESENT = write them there, and also return them" becomes per arm.
- **`optimized_plan.md`.** The `write_target` header rule gains the Iceberg arm's decoder rules.

## Where is the code?

| what | where |
|---|---|
| the REST client to extend | `src/iceberg_catalog/iceberg_rest_catalog_client.mojo`, `iceberg_rest_transport.mojo` |
| manifests, bounds and partitions to extend | `src/iceberg/iceberg_avro_manifest.mojo`, `iceberg_bounds.mojo`, `iceberg_partition.mojo` |
| the file-based commit this path does not use | `src/iceberg/iceberg_writer.mojo` |
| Parquet schema elements | `src/parquet_api/src/parquet_api/metadata.mojo` |
| SQL write statements | `src/sql/sql_parser.mojo` (`_parse_create_table_as`), `src/sdk_exec/engine_sql.mojo` (`STATEMENT_NOT_A_QUERY`) |
| the write target | `src/arrow/write_target.mojo`; `src/plan_proto/plan.proto` (`WireWriteTarget`, `WirePlanEnvelope`); `src/plan_wire/plan_wire_admit.mojo` (the version rules) |
| SigV4 signing | `src/aws_core/signed_request.mojo` |
