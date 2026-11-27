# Object-store URLs: read, write and list s3://, gs:// and az:// from Python and SQL

Status: design, not built. It plans the work of komira-ai/komira#2337 as a sequence of small pull
requests. **EXISTS** names code on `main`; **PROPOSED** is new. Statements the author deduced rather
than read are marked *(inferred)*.

The binding, credential, plan and error model is already designed in
[credentials_and_writes.md](credentials_and_writes.md), called "the credentials design" below.
This document does not reopen it. It says which part of that model each slice builds, in what order,
over which store library, how each slice is tested with no real service, and when the catalogue
status of the four tasks it serves may change:

| rank | task ([docs/tasks/catalogue.json](../tasks/catalogue.json)) | status today |
|---|---|---|
| 31 | How do I read Parquet or CSV files from S3? | partial |
| 32 | How do I write query results to S3 as Parquet? | gap |
| 93 | How do I read files from Google Cloud Storage or Azure Blob? | partial |
| 96 | How do I list the files in a bucket or prefix? | gap |

## What a user types, once every slice has landed

```python
import komira

s = komira.Session()

# The provider's standard chain (environment, profile, container or instance role): no credential
# argument at all, as with pandas, polars and pyarrow.
s.sql("SELECT region, sum(amount) FROM 's3://sales/2026/*.parquet' GROUP BY region")
df = komira.read_parquet("s3://sales/2026/east.parquet")
s.register_csv("returns", "s3://sales/2026/returns.csv", delimiter=";")

# An explicit credential, for SQL: a scope (a location ending in "/") gives every URL under it its
# credential and store settings.
s.add_sql_binding("sales_bucket", komira.files(
    "s3://sales/", credential=komira.AwsKeys("sales-etl", key_id=key_id, secret=secret),
    region="eu-west-1",
))
s.sql("COPY (SELECT * FROM 's3://sales/2026/*.parquet' WHERE amount > 100) TO 's3://sales/big.parquet'")

# Listing, as DuckDB's glob(): one row per object, one column `file`.
s.sql("SELECT file FROM glob('s3://sales/2026/*') ORDER BY file")

# The DataFrame door: a bare URL uses the chain; a komira.files source carries its own credential.
df.to_parquet("s3://sales/out/east.parquet")
komira.read_parquet(komira.files("az://reports/2026/q1.parquet", credential=komira.AzureSas(...)))
```

What does not change: the SQL text is DuckDB's; a local path reads as it does today; the existing
`Session.add_sql_binding(name, komira.files(...))` spelling, with the same credential classes, keeps
working, and the two task pages that use it keep their output.

## Questions for the owner

Each row is an API with no counterpart in DuckDB, pandas or polars, or a place where komira would
differ from them. The rest of the document assumes the recommendation. No part of a slice that
depends on a row starts before the owner has answered it. Slices 1, 2 and 2b depend on none, and
slices 3, 5a and 5b depend on Q3 only for their `register_*` part.

| # | question | the reference libraries | recommendation | blocks slice |
|---|---|---|---|---|
| Q1 | How a DataFrame reader gets an explicit credential | pandas: `read_parquet(url, storage_options={...})`, a dict of backend keys; polars: `scan_parquet(url, storage_options={...}, credential_provider=...)` | a `komira.files(...)` source in place of the path, as the credentials design's decision 3 already says: `komira.read_parquet(komira.files(url, credential=..., region=...))`. Add no `storage_options=`: its keys are each backend's own, it would be a second way to say what a source says, and that design rejected per-session storage options for the same reason | 4 |
| Q2 | How a write terminal gets an explicit credential | pandas: `df.to_parquet(url, storage_options={...})`; polars: `write_parquet(url, storage_options=...)` | a `komira.files(...)` source as the destination: `df.to_parquet(komira.files("s3://b/k.parquet", credential=...))`. This is invented: no reference library takes a source object as a destination. The alternative is a bare URL only, so explicit credentials write through SQL `COPY` under a bound scope | 6b |
| Q3 | Whether `register_parquet`, `register_csv` and `register_json` take a URL, and a `komira.files` source | these verbs are komira's own; DuckDB's counterpart is `read_csv('s3://...', delim=';')` in SQL | yes to both. A bare URL means `komira.files(url)` with the chain. A source is the only way to give a remote CSV its parsing options (`delimiter`, `header`) and an explicit credential, since `komira.files` takes no format options. The alternative is a `format=`/`delimiter=` keyword on `komira.files`, which would be invented too | 3, 5a, 5b (their `register_*` part) |
| Q4 | A Python listing verb | DuckDB: SQL `glob(pattern)` only. pandas and polars have none. pyarrow's `FileSystem.get_file_info(FileSelector(...))` and fsspec's `ls` and `glob` are separate libraries | none. Listing is `s.sql("SELECT file FROM glob(...)")`, whose result already converts to Arrow, pandas and polars. A `komira.glob(pattern) -> list[str]` would be invented; it can be added later without changing the SQL | none |
| Q5 | Which protocol reads `gs://` | DuckDB reads `gs://` through Google's S3-compatible XML API with HMAC keys | a JSON-API (HTTP/1.1) conformer of the existing `GcsStorageBackend` trait, beside the gRPC one ([decision 2](#2-the-library-and-wire-protocol-for-each-store)). It is a second GCS backend in the tree; the alternatives are named there | 8a |
| Q6 | When `glob()` lists | DuckDB lists when the statement runs *(inferred)*; its documentation does not say | at bind, as a read's glob is expanded today (decision 7), so the rows travel in the plan as a constant relation. A plan run later sees the objects of bind time; for one statement in a session the two are the same. The alternative, a listing node the engine runs, needs a new plan node and, for a job manager, the credential at run time | 7 |
| Q7 | Unsigned reads of public S3 buckets | DuckDB sends unsigned requests when no secret is set *(inferred)*; pyarrow has `S3FileSystem(anonymous=True)` ([pyarrow: S3FileSystem](https://arrow.apache.org/docs/python/generated/pyarrow.fs.S3FileSystem.html)) | its own small slice, 2b. The credentials design already names `komira.ANONYMOUS` on `s3://` as the way to read a public bucket; this plan only orders it after the chain | none |

Rows that are not questions, because an existing design settles them: a bare URL in SQL and in the
DataFrame readers uses the provider chain (`komira.AMBIENT`); an S3 source with no region from any
setting is refused (`STORAGE_REGION_UNKNOWN`), where DuckDB assumes `us-east-1`; plaintext `http://`
is reached only through a source's `endpoint=`. Those are the credentials design's own
owner questions, and this plan follows its recommendations.

## What exists today

**EXISTS** in the engine, by store. "Wired" means libkomira's `komira_add_sql_binding`
([src/so/bindings.mojo](../../src/so/bindings.mojo)) reaches it, so Python can.

| | S3 (`s3://`, `s3a://`) | Azure Blob (`az://`, `abfs://`, `abfss://`) | GCS (`gs://`, `gcs://`) |
|---|---|---|---|
| library | [objectstore_s3](../../src/objectstore_s3/README.md) over [aws_core](../../src/aws_core/README.md) (SigV4, the chain) | [azure_blob](../../src/azure_blob) over `azure_core` | [objectstore_gcs](../../src/objectstore_gcs/README.md) over [gcp_core](../../src/gcp_core/README.md) (ADC, token sources) |
| protocol | REST over HTTP/1.1, TLS or plaintext by `endpoint=` | Blob REST over HTTP/1.1, TLS or plaintext by `endpoint=` | gRPC `google.storage.v2` over HTTP/2 and TLS only (`grpc_backend.mojo`) |
| ranged read | `get_range`, suffix ranges, coalesced multi-range; later reads are conditional on the first read's ETag (`s3_fs.mojo`) | `get_range` (`Range: bytes=a-b`); a footer is a HEAD and a tail range | `ReadObject` with offset and limit, CRC-32C checked |
| listing | ListObjectsV2, paged, with a delimiter or recursive (`S3Fs.list`, `list_dir_shallow`) | List Blobs, paged (`AzureFs.list`, `list_dir_shallow`) | `ListObjects`, paged (`GcsFs.list`, `list_dir_shallow`) |
| globs | expanded in `so` at bind: list from the static prefix, then match with `fs.glob` (`*`, `?`, `[...]`, one `**`; `{a,b}` is not expanded on this path) | the same code | none wired |
| write | `S3Fs.open_write`, `write_at`, `close_write`, `abort_write`: one PutObject, or a multipart upload of 8 MiB parts, up to 8 in flight, aborted on any failure (`s3_fs.mojo`, `s3_fs_options.mojo`) | `AzureStore.put_blob`, one request with the whole blob in memory; `AzureFs` refuses every write verb; no Put Block or Put Block List | whole-object conditional `WriteObject` only; `GcsFs` refuses every write verb; `StartResumableWrite` is generated in `gcp_storage` and not called |
| credentials | explicit keys; the default chain (environment, web identity, profile files, container, instance metadata) as `DefaultChainCredsSource`, used by `job_supervisor` | Shared Key, SAS, anonymous; `azure_core` has managed-identity and service-principal token providers that nothing in `azure_blob` consumes | ADC (credentials file, gcloud's file, metadata server), service-account key, static token; no anonymous mode (an empty token is refused) |
| wired in libkomira | yes: Parquet objects, one key or a glob, with `AwsKeys` only | yes: Parquet blobs, with `AzureKey`, `AzureSas` or `anonymous` | no: refused with `STORAGE_URL_REFUSED` (`bindings.mojo`) |

`azure_blob` has no write through `AzureFs`, the file system every scan uses; `AzureStore.put_blob`,
one request with the whole blob in memory, exists below it.

What a user meets today:

- **`komira.files` with `add_sql_binding`** reads Parquet from `s3://` and `az://`. That is the form
  the pages of ranks 31 and 93 show, each against a stand-in server in the example itself.
- **Refused by name at bind** (`bindings.mojo`): `gs://` and every other scheme
  (`STORAGE_URL_REFUSED`); `komira.AMBIENT`, the default (`CREDENTIALS_NOT_FOUND`); `anonymous` and
  `AwsProfile` on S3 (`BIND_SOURCE_UNSUPPORTED`); a scope (`BIND_SCOPE_NOT_A_TABLE`).
- **Not refused by name, so the failure is accidental:**
  - a CSV or JSON object in `komira.files`. Every remote object is read as Parquet, so a CSV fails in
    the footer reader;
  - a URL in the SQL text (`FROM 's3://...'`, `read_parquet('s3://...')`, `read_csv('s3://...')`).
    The binder takes it as a local path (`parquet_footers/parquet_files.mojo`, `sql_tvf_bind.mojo`);
  - a URL given to `register_parquet`, `register_csv`, `register_json`, `komira.read_parquet`,
    `read_csv`, `read_json` or `komira.pl.scan_*`. `_local_path`
    ([python/komira/_session.py](../../python/komira/_session.py)) makes `s3://b/k` an absolute path
    under the working directory, and the engine reports a missing local file.
- **Writes:** `COPY ... TO '<url>'` and `to_parquet`, `to_csv`, `to_json` of a URL are refused with
  `STORAGE_URL_REFUSED` (`check_copy_target` in
  [src/sdk_exec/engine_write.mojo](../../src/sdk_exec/engine_write.mojo); the Python write terminals
  pass a URL through for the library to refuse, `_write.py`). Every write encodes the whole file into
  memory, then writes it with `write_file_atomic`, a temporary file renamed over the destination.
- **Listing:** none. The SQL parser knows no `glob` table function (`sql_parser.mojo` lists
  `read_parquet`, `read_csv`, `read_csv_auto`, `read_json`, `read_json_auto`, `read_ndjson`,
  `read_avro` and `iceberg_scan`).
- **The plan wire** carries no remote scan: the codec refuses one with
  `PLAN_WIRE_UNSUPPORTED_REMOTE_FS` (`plan_wire_codec.mojo`). The DataFrame readers build a plan and
  send it through `komira_plan_stream`, so they cannot read a URL until the wire can say how to reach
  it. `WireParquetSource` has no `access` field and `WireWriteTarget` has `path`, `format` and
  `codec` only ([src/plan_proto/plan.proto](../../src/plan_proto/plan.proto)). The envelope format
  versions accepted are 4 and 5.
- **CSV and JSON scans** read a local file by path. `CsvSourceSpec` and the JSONL spec carry no file
  system (`physical_plan.mojo`, `lowering/cut_scan.mojo`), and the readers open the path with
  `FileHandle` (`csv/reader.mojo`, `jsonl/streaming_source.mojo`). The CSV reader parses a whole body
  in memory (`read_csv_bytes_to_batch` takes bytes), and `decompress_text_bytes_to_buffer`
  (`dispatch_scan/decompress_reader.mojo`) already decompresses a body given as bytes.

## Where is the code?

The slices build on:

- [src/so](../../src/so/README.md): `bindings.mojo` (the refusals, globs), `store_fs.mojo`,
  `bound_store.mojo`, `credentials.mojo`;
- [src/objectstore_s3](../../src/objectstore_s3/README.md), [src/aws_core](../../src/aws_core/README.md),
  [src/azure_blob](../../src/azure_blob), [src/objectstore_gcs](../../src/objectstore_gcs/README.md),
  [src/gcp_core](../../src/gcp_core/README.md);
- [src/sdk_exec/engine_write.mojo](../../src/sdk_exec/engine_write.mojo) (the write sink),
  `src/sql` (the parser's table functions, the binder), `src/csv` and `src/jsonl` (the readers),
  `src/fs` (`file_system.mojo`, `glob.mojo`);
- [src/plan_proto/plan.proto](../../src/plan_proto/plan.proto) and `bound_source.proto`;
- [python/komira/_session.py](../../python/komira/_session.py), `_sources.py`, `_frame.py`,
  `pl/_frame.py`, `_write.py`, and [python/tests/objectstore_fakes.py](../../python/tests/objectstore_fakes.py).

## The decisions

### 1. Which stores and formats come first, and in what order

**S3 first, Parquet before CSV and JSON, reads before writes, GCS last.**

- **S3 first.** It is the only store whose read, listing and streaming multipart write are all built
  and tested, and whose provider chain exists. Ranks 31 and 32, the two most common of the four tasks,
  are S3 tasks. The Python stand-in `FakeS3` ([python/tests/objectstore_fakes.py](../../python/tests/objectstore_fakes.py))
  already checks every request's SigV4 signature.
- **Parquet before CSV and JSON.** The Parquet scan already reads through the `FileSystem` seam that
  every store implements; CSV and JSON need their scan spec to carry a file system first (slices 5a and 5b).
- **Azure with S3, for reads.** Every slice that changes the binder or the scan works on the shared
  `StoreFs` ([src/so/store_fs.mojo](../../src/so/store_fs.mojo)), so Azure reads come at no extra
  cost. Azure writes need Put Block and Put Block List, which do not exist; no catalogue rank waits for
  them, so they come after the S3 write.
- **GCS last.** It is not wired into libkomira at all, its only backend cannot be reached by a
  stand-in a test or a task page can run (decision 2), and it has no streaming write. It moves rank 93
  and the GCS half of rank 96, the two least common of the four.

### 2. The library and wire protocol for each store

| store | reads and listing | writes | why |
|---|---|---|---|
| S3 | `objectstore_s3`'s `S3Fs`: HEAD, ranged GET, ListObjectsV2 | `S3Fs.open_write`/`write_at`/`close_write`: PutObject when the file fits in one part, else CreateMultipartUpload, UploadPart, CompleteMultipartUpload; AbortMultipartUpload on any failure | built and tested over the in-memory `FakeS3Connector`, which serves every one of these verbs and injects failed parts and a failed completion |
| Azure Blob | `azure_blob`'s `AzureFs`: Get Blob Properties, ranged Get Blob, List Blobs. `abfs://` and `abfss://` go to the flat Blob endpoint, not the Data Lake one | **PROPOSED** in slice 9: Put Block and Put Block List under `AzureFs.open_write`, the same buffered-part shape as `S3Fs`; one Put Blob when the file fits in one block | the read path is built; block-blob upload is the service's only way to write a blob larger than one request, and the `FileSystem` trait already names `PutBlockList` as Azure's commit step (`fs/file_system.mojo`) |
| GCS | **PROPOSED** in slice 8a: a new conformer of `GcsStorageBackend` (`objectstore_gcs/backend.mojo`) over the JSON API on HTTP/1.1: object metadata, media download with `Range`, objects list with prefix, page token and delimiter | **PROPOSED** in slice 10: the JSON API's resumable upload, under a `GcsFs` write | see below |

**Why a second GCS backend.** The gRPC backend that exists dials `https://` only, over HTTP/2: its
header records that the gRPC client carries unary calls only over plaintext HTTP/2, so `ReadObject`
and `WriteObject` need TLS. That has three consequences for this issue:

- a task page's stand-in, which runs in the hermetic CPython with the wheel, pyarrow and protobuf only
  ([python/docs/tasks/BUCK](../../python/docs/tasks/BUCK)), would have to speak TLS, HTTP/2 and gRPC.
  So rank 93's page could never show `gs://` running, and neither could a `python_binding_test`;
- `endpoint=` could reach only a TLS emulator with a trusted root, never a plaintext one;
- the backend has no anonymous mode, so a public bucket cannot be read.

A JSON-API conformer has none of these limits. It reuses `gcp_core`'s token sources and ADC
unchanged, adding only `Authorization: Bearer <token>`. A stdlib `http.server` can stand in for it
as the two existing pages' stand-ins do. The gRPC backend stays, for the code that uses it today
(`job_supervisor`'s log store, and `GcsScanFs` for Mojo callers of the engine).

Alternatives weighed:

- **gRPC only.** No new backend, but `gs://` is tested in Mojo only, and the rank 93 page cannot
  demonstrate it. Kept as the answer if the owner rejects Q5.
- **The XML API with HMAC keys**, DuckDB's route (its documentation reads `gs://` with
  `CREATE SECRET (TYPE gcs, KEY_ID ..., SECRET ...)`;
  [DuckDB: GCS import](https://duckdb.org/docs/stable/guides/network_cloud_storage/gcs_import.html)).
  It would reuse the S3 stack, but HMAC keys are not what Application Default Credentials yield. So the
  standard chain would not work, and komira would need a new credential kind.

### 3. Credentials

The credentials design decides the model: a credential is a named object; the plan
carries only its name; `komira.AMBIENT` is the provider's chain, read inside the library and only for
a source that names it; nothing else reads the environment (rule S2). That design's
[environment table](credentials_and_writes.md#the-environment-komira-reads) lists the variables, all
the providers' own. This plan builds it in this order:

| credential | `s3://` | `az://` | `gs://` |
|---|---|---|---|
| `komira.AMBIENT` (the default) | **slice 2**: `so` builds `aws_core`'s `DefaultChainCredsSource` over `ProcessEnv` and `ProcessFiles`, as `job_supervisor` does. The region comes from `region=`, else `AWS_REGION`, `AWS_DEFAULT_REGION`, the selected profile | not served: Azure has no standard chain within rule S2 (the credentials design, decision 7). Out of scope here | **slice 8b**: `gcp_core`'s `application_default_token_source` |
| explicit keys: `AwsKeys` | **EXISTS** | | |
| `AwsProfile` | **slice 2**: the chain's profile step with the named profile, found through `AWS_CONFIG_FILE`, `AWS_SHARED_CREDENTIALS_FILE` and `HOME` only | | |
| `AzureKey`, `AzureSas` | | **EXISTS** | |
| `GcpServiceAccount`, `GcpToken` | | | **slice 8b**: `ServiceAccountKeyFetcher` inside `CachingTokenSource`; `StaticTokenSource` |
| `komira.ANONYMOUS` | **slice 2b** (Q7): requests with no signature. `so` refuses it today (`bindings.mojo`, "unsigned s3:// reads are not served"), and no unsigned mode was found in `objectstore_s3` *(inferred from a search for one)* | **EXISTS** | **slice 8b**, with the JSON backend: a request with no `Authorization` |

- The S3 stores themselves never read the environment, and a test holds that
  (`objectstore_s3/tests/test_no_env_reads.mojo`). So the chain is built in `so`, which hands the
  store a credentials source. `objectstore_s3` does not change.
- A chain step that is configured but broken raises `CREDENTIALS_INVALID` naming the setting, and
  nothing configured raises `CREDENTIALS_NOT_FOUND`, as `aws_core` already rules. The message's
  `source=` field names the step that answered (the credentials design, decision 11).
- Configuration other than credentials is arguments: `region=`, `endpoint=`, `url_style=` on
  `komira.files`. No slice adds an environment variable of komira's own, and none reads
  `AWS_ENDPOINT_URL`.

### 4. The Python surface

Each komira call beside the reference libraries' documented call. "Chain" means the provider's
standard credentials. The pandas and polars citations are their current documentation; the
versions the tests pin are pandas 3.0.6 and polars 1.44.2, and a slice that relies on a cited
behaviour checks it against the pinned version.

| task | komira (**PROPOSED** unless marked) | pandas | polars | slice |
|---|---|---|---|---|
| read Parquet from a URL | `komira.read_parquet("s3://b/k.parquet")`, chain | `pd.read_parquet("s3://b/k.parquet")`. pandas reads `s3` and `gs` URLs through fsspec, or through `pyarrow.fs` when both serve the scheme ([pandas: read_parquet](https://pandas.pydata.org/docs/reference/api/pandas.read_parquet.html)) | `pl.scan_parquet("s3://b/*.parquet")`; credentials are inferred from the environment when `storage_options` is omitted ([polars: scan_parquet](https://docs.pola.rs/api/python/stable/reference/api/polars.scan_parquet.html)) | 4 |
| the same, with a credential | `komira.read_parquet(komira.files(url, credential=komira.AwsKeys(...), region=...))` (Q1) | `storage_options={"key": ..., "secret": ...}`, passed to `fsspec.open` | `storage_options={"aws_access_key_id": ..., "aws_region": ...}` | 4 |
| polars-shaped lazy read | `komira.pl.scan_parquet(url or source)`, `scan_csv`, `scan_ndjson` | | `pl.scan_parquet`, `pl.scan_csv`, `pl.scan_ndjson` | 4, 5a, 5b |
| read CSV or JSON from a URL | `komira.read_csv(url or source, sep=..., header=...)`, `komira.read_json(...)` | `pd.read_csv("s3://...")` *(inferred: the read_parquet page documents the URL schemes; the read_csv page was not read)* | `pl.scan_csv("s3://...")`; polars reads Parquet, CSV, IPC and NDJSON from cloud storage ([polars: cloud storage](https://docs.pola.rs/user-guide/io/cloud-storage/)) | 5a, 5b |
| bind a SQL name to a URL | `s.register_parquet(name, url or source)`, `register_csv(name, url or source, delimiter=..., header=...)`, `register_json(...)` (Q3); **EXISTS**: `s.add_sql_binding(name, komira.files(url, ...))` for Parquet | | | 3, 5a, 5b |
| write a frame to a URL | `df.to_parquet("s3://b/k.parquet")`, `to_csv`, `to_json`, chain; with a credential, a `komira.files` destination (Q2) | `df.to_parquet("s3://...", storage_options={...})` ([pandas: to_parquet](https://pandas.pydata.org/docs/reference/api/pandas.DataFrame.to_parquet.html)) | `df.write_parquet("s3://...")`; the [cloud-storage guide](https://docs.pola.rs/user-guide/io/cloud-storage/) says a frame is written by passing a cloud URL | 6b |
| list a prefix | `s.sql("SELECT file FROM glob('s3://b/p/*')")` (Q4) | none | none | 7 |

- **Every reader takes a path, a URL or a `komira.files` source**, and nothing else new. A bare URL
  is `komira.files(url)` with `komira.AMBIENT`. Readers never read the session's SQL bindings or
  scopes (the credentials design, decision 3): a credential is either the chain or the source's own.
- **`_local_path` stops turning a URL into a path** (slice 1). A string with a scheme (`<letters>://`)
  goes to the library verbatim, as `_write.destination` already sends a write URL. The library then
  serves the URL or refuses it by name. `komira.files` already parses the scheme with the same
  pattern (`_URL` in `_sources.py`), so both doors share one rule.
- **No `storage_options=`** (Q1). It is the one keyword every reference library has and komira does
  not, and the reason is the source object: `endpoint`, `region` and `url_style` are its named
  arguments, and a credential is a named, sealed object, never a dict of secrets in a call.

### 5. The SQL surface

The SQL text is DuckDB's, with the httpfs, aws and azure extensions' URL forms
([DuckDB: S3 API](https://duckdb.org/docs/stable/core_extensions/httpfs/s3api.html),
[DuckDB: Azure](https://duckdb.org/docs/stable/core_extensions/azure.html)). The citations are
DuckDB's current documentation; the version the tests pin is 1.5.6, and each slice's reference test
checks the behaviour it relies on against that version where a local file can show it. The credential comes
from the scope covering the URL, never from SQL: `CREATE SECRET`, `SET s3_*`, `INSTALL` and `LOAD`
stay refused with `SQL_STATEMENT_UNSUPPORTED` (the credentials design, decision 10).

| SQL | DuckDB documents | komira | slice |
|---|---|---|---|
| `FROM 's3://b/k.parquet'`, `read_parquet('s3://b/*.parquet')` | globs over S3 through ListObjectsV2, with `*`, `?` and `[0-9]` | read through the covering scope; until slice 3, refused by name | 1, 3 |
| `read_csv('s3://b/k.csv', delim=';')`, `FROM 's3://b/k.csv'`, `read_json(...)` | the CSV reader takes a path, a glob or a list of files ([DuckDB: CSV](https://duckdb.org/docs/stable/data/csv/overview.html)); its pages show no `s3://` example *(inferred to work through httpfs, as the S3 page's globs do)* | read through the covering scope, with the options `read_csv` takes on a local file | 5a, 5b |
| `COPY t TO 's3://b/k.parquet'`, `COPY (...) TO 's3://b/k.csv'` | the S3 page: `COPY` writes CSV and Parquet to `s3://`, with a multipart upload | the same, under the covering scope, answering DuckDB's one `Count` row | 6a |
| `COPY ... TO 'az://...'`, `COPY ... TO 'gs://...'` | Azure: written with block uploads (`azure_write_block_size`) | `STORAGE_WRITE_UNSUPPORTED` until slices 9 and 10 | 6a, 9, 10 |
| `SELECT * FROM glob('s3://b/p/*')` | `glob(search_path)` returns the file names in one column named `file` ([DuckDB: utility functions](https://duckdb.org/docs/stable/sql/functions/utility.html)) | the same column, one row per object (decision 7) | 7 |

- **Scopes.** Slice 3 builds the credentials design's decision 3 for files: `komira.files("s3://b/")`, a location
  ending in `/`, binds a scope rather than a table. A URL in the SQL text takes the credential and
  store settings of the longest scope that covers it, on whole path segments, after aliases are
  normalised (`s3a://` to `s3://`, `gcs://` to `gs://`). Every session starts with the scheme-root
  scopes `s3://` and `gs://` bound to `komira.AMBIENT`. An `az://` URL under no bound scope is
  refused with `CREDENTIALS_NOT_FOUND`, which says to bind one.
- **One bucket, one way.** The existing `BIND_STORE_CONFLICT` rule (one statement's tables read a
  bucket with one set of settings) is kept, and a scope counts as a table for it. Lifting it means
  keying a statement's file systems on the whole identity tuple of the credentials design's decision 6. That is a
  separate change, which no rank needs.
- **The plan.** A scan or write target reached through a scope carries a `WireSourceAccess` with the
  credential's name, never its value. In process, this is the `FsDescriptorPod` and `BoundStore`
  that exist. On the wire it is the credentials design's `WireParquetSource.access = 11`,
  `WireScanBinding.access = 17` and `WireWriteTarget.access = 4`. An envelope carrying any of them
  declares format version 6, so an older reader refuses it by name instead of reading a remote
  source as a local one. Slice 4 adds them for scans and slice 6b for writes. Each is a new optional
  field (rule B8). The version raise is the deliberate exception the credentials design's decision 4
  makes and gives its reason for, the one `plan.proto` already makes for `write_target`: an older
  reader that dropped the field would change the answer silently. Slices 5a and 5b reuse
  `WireScanBinding.access` for the CSV and JSON scans of the DataFrame readers.

### 6. Writes

Slice 6a serves `COPY ... TO 's3://...'`, and slice 6b the three write terminals on an `s3://` URL.

- **The sink.** `engine_write.mojo` already encodes the whole file into one buffer before writing
  it. For an `s3://` destination, `write_copy_result` writes that buffer through the file system the
  run's opener opens on the destination's bucket, instead of `write_file_atomic`: `open_write` with
  `create_truncate`, then `write_at`, then `close_write`. In a session, the opener is `so`'s
  `StoreScanFs`, whose S3 file system is `S3Fs` with its write verbs. A file of one part or less is
  one PutObject; a larger one is a multipart upload of 8 MiB parts. Both doors change: `COPY` in
  `run_sql_with`, and a plan with a write target in `run_plan_write` (`engine_plan.mojo`), which
  makes the same `check_copy_target` refusal today.
- **All or nothing.** S3 makes a PutObject or a completed multipart upload visible at once, and an
  object being replaced stays readable until then. Any failed part or completion aborts the upload
  (`S3Fs._abort_after`), so a failed write leaves the destination as it was, as the local write's
  temporary file and rename do. A process that dies mid-upload leaves an incomplete upload, invisible
  and billed until the bucket's lifecycle rule removes it. Resuming one is out of scope.
- **An existing object is replaced**, as DuckDB and the local write replace it.
  `COPY (SELECT * FROM 's3://b/a.parquet') TO 's3://b/a.parquet'` is safe. The result is complete
  before the upload starts, and the reads are pinned to the first read's ETag.
- **Format and codec** follow the existing rules: from `FORMAT`, else the extension after one
  compression suffix (`copy_format_from_path` already looks only at the last segment of a URL).
- **Credentials.** SQL takes the destination's scope, like any URL (decision 5). A write terminal
  takes the chain for a bare URL, or the source's own credential (Q2).
- **Refused by name:** a `gs://`, `az://` or `https://` destination (`STORAGE_WRITE_UNSUPPORTED`,
  replacing today's `STORAGE_URL_REFUSED` for these schemes); the `COPY` options that are refused for
  local files already (`PARTITION_BY` among them, `COPY_OPTION_UNSUPPORTED`).

### 7. Listing

Slice 7 adds the table function `glob(pattern)`, DuckDB's name and shape.

- **What it returns.** One `VARCHAR` column named `file`, one row per object whose key matches. Each
  value is the object's whole location, written with the scheme and bucket of the pattern
  (`s3://b/p/x.parquet`). A local pattern returns local paths, as DuckDB's does.
- **Pattern syntax** is the reads' syntax, `fs/glob.mojo` per path segment: `*` and `?` stay within
  one segment, `[...]` is a class, and one `**` matches any depth. So `glob('s3://b/p/*')` lists one
  level under `p/`, and `glob('s3://b/p/**')` lists every object under it. A pattern with no glob
  character returns the one object of that key, or no row; slice 7 checks this, and every other row
  of this decision, against DuckDB's `glob` over a local tree, and does what DuckDB does or refuses by
  name.
- **No match is no row**, not an error. A read of a glob that matches nothing keeps its
  `PARQUET_GLOB_NO_MATCH`.
- **Order.** komira returns the rows in key order. A query that needs an order still writes
  `ORDER BY file`, and the task page does.
- **When it lists.** At bind, as a read's glob is expanded today (Q6). The rows are fixed for the
  statement and travel in the plan as a constant relation, so a plan run later lists nothing.
- **Credentials and stores.** It uses the covering scope, as a URL does. `s3://` and `az://` are
  listed in slice 7, and `gs://` once slice 8b wires GCS.
- **Not added:** the object's size or modification time. DuckDB's `glob` has neither, and adding a
  column later is additive.

## How each slice is tested, with no real service

Every test is hermetic (rule T12): stores are in-memory fakes or loopback servers on port 0, chains
read `MapEnv` and `MapFiles`, nothing reaches a cloud, and no test asserts timing (rule T10).

| layer | what exists | what the slices add |
|---|---|---|
| Mojo, the store libraries | `FakeS3Connector` (`src/tests/helpers/komira_test_fake_s3`): GET, ranges, HEAD, ListObjectsV2, PutObject, every multipart verb, injected faults. `FakeAzureConnector`: HEAD and GET only. `FakeGcsStorageBackend`, in memory | Azure: List Blobs, Put Block and Put Block List in the fake (slices 7, 9). GCS: a scripted-connector test of each JSON-API call (slice 8a) |
| Mojo, `so` and `sdk_exec` | `test_add_sql_binding.mojo`, `test_store_fs.mojo` and `test_credentials.mojo` over those fakes | one test file per slice over the same fakes; the chain under `MapEnv` and `MapFiles` with a fake credential transport, so the instance metadata step never dials |
| Python | `FakeS3` (checks SigV4) and `FakeAzure` (checks Shared Key and SAS) on `127.0.0.1:0`, in `objectstore_fakes.py`, used by `sql_binding_test` and `objectstore_installed_test`. Both answer any write with 405 | PUT, `?uploads`, `?partNumber=&uploadId=`, complete and abort in `FakeS3` (slice 6a); a `FakeGcs` serving the JSON API (slice 8c); Azure blocks (slice 9) |
| task pages | ranks 31 and 93 each run a stdlib stand-in inside `example.py`, in the hermetic CPython | the pages of ranks 32 and 96, each with its own stand-in; probes for the forms that are not built yet |

- **Ambient in Python tests.** The test sets the provider variables in its own process before the
  session opens (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and `AWS_CONFIG_FILE` and
  `AWS_SHARED_CREDENTIALS_FILE` pointing at files in its scratch directory). It also sets
  `AWS_EC2_METADATA_DISABLED=true`, so a chain that finds nothing raises `CREDENTIALS_NOT_FOUND`
  instead of dialling the instance metadata address. Rule S2 allows these, because they are the
  provider's own variables. A task page shows `AwsKeys` rather than setting the environment.
- **Reference answers.** The DuckDB the tests pin (1.5.6) loads its httpfs extension by downloading
  it *(inferred)*, which a hermetic test cannot do, so no test runs DuckDB against a stand-in. Each read slice compares
  komira's answer over the stand-in with komira's and DuckDB's answers over the same files on local
  disk. Slice 7 does the same with DuckDB's `glob` over a local tree.
- **Failure cases** each slice covers, by code: `CREDENTIALS_NOT_FOUND`, `CREDENTIALS_INVALID`,
  `STORAGE_REGION_UNKNOWN`, `STORAGE_ACCESS_DENIED` (a wrong secret, which the fakes refuse),
  `STORAGE_NOT_FOUND`, `STORAGE_THROTTLED` and `STORAGE_TRANSPORT` (the fake's faults),
  `STORAGE_OBJECT_CHANGED` (an object rewritten between reads), the refusal codes of decision 5 and
  decision 6, and for writes a failed part and a failed completion, each leaving no object and an
  aborted upload. Every message is asserted by exact equality with a known secret in the session, so
  none can carry a secret (rule T13).
- **Cross-release (rule B8).** Slices 4, 5a, 5b and 6b each name two tests. The first runs the
  previous release's decoder (the version-5 reader) on a new version-6 envelope and expects its
  by-name refusal. The second runs the new decoder on version 4 and 5 envelopes with no `access` and
  expects them unchanged.

**A real-service test** would need, per store, a bucket in an account kept for it. The runner would
get its credential through the provider's own chain, and take the bucket and region as flags (rule
S2). Every object would be written under a prefix named for the validation run id, then deleted with
every incomplete upload under it at the end (rule T14). The bucket would carry a lifecycle rule
aborting incomplete uploads. It cannot run in the pull request's check (rule B9) or by default (rule
S3), so it would be a held script, dry-run by default, that the owner runs after merge. The
`komira_test_bucket` helper (`src/tests/helpers/komira_test_bucket`, a `runs/<run_id>/` prefix with
a lease) is the building block, and the opt-in MinIO helper (`komira_test_minio`) is a real S3
server short of a real account. No slice here needs one. Whether to add it is the owner's call, and it
is not one of the slices.

## What is out of scope

- Other schemes and clouds: `r2://`, `hf://`, `hdfs://`, and other S3-compatible services beyond
  what `endpoint=` reaches.
- `https://` reads. The credentials design's decision 13 puts them in its object-store milestone, but
  none of the four ranks asks for them, so they are left to a pull request of their own, after this
  plan.
- Resuming an interrupted multipart, block or resumable upload; requester-pays buckets; S3 Express
  directory buckets; server-side encryption options, storage class, object tags, metadata and ACLs on
  write.
- Writes with `PARTITION_BY`, `OVERWRITE_OR_IGNORE`, `APPEND` or `FILE_SIZE_BYTES`, and Hive
  partitioning on object-store reads (refused today with `BIND_SOURCE_UNSUPPORTED`).
- Azure's standard chain (managed identity, service principal, `az login`), Google workload identity
  federation (`external_account` files, refused by `gcp_core`), and AWS `credential_process` and SSO
  profiles (refused by name by `aws_core`).
- Brace expansion (`{a,b}`) in an object-store glob; a streaming listing, and size or time columns from `glob`.
- A streaming write, one that uploads row groups as they are produced. Every write still holds the
  whole file in memory, as the local write does.
- Reading one bucket under two credentials in one statement (`BIND_STORE_CONFLICT` stays).
- Plans that read or write an object store sent to a job manager: its admission side is in the
  sources-and-credentials design, decision 5.

## What must always hold

- A URL never reaches the local file system as a path, and a local path never reaches a store.
- No credential value is in a plan, a binding's bytes, a rendered plan, an error message, a `repr` or
  a log line.
- komira reads no environment variable of its own. Only `komira.AMBIENT`, and `AwsProfile` for its
  files, read the providers' variables, and only when a source that names them is read.
- A write is complete at its destination or absent from it. A replaced object stays readable until the
  new one is complete.
- A store, a format or a credential that a slice does not serve is refused by name, never read as
  something else.

## The slices, in order

Each slice is one pull request, in this order. Each says what it moves in [docs/tasks/catalogue.json](../tasks/catalogue.json)
and under [python/docs/tasks/](../../python/docs/tasks/). Each updates `src/so/README.md`, the credentials design's
"Where is the code?" and the task pages it changes (rule T19). No slice changes a catalogue status
except where the table at the end says so.

- **Slice 1: URLs refused by name where they are mistaken for paths today.** The Python package stops
  turning a URL into a path (`_local_path`; decision 4). `register_parquet`, `register_csv`,
  `register_json`, the DataFrame readers and a URL in the SQL text are refused with
  `STORAGE_URL_REFUSED`, naming the spelling that works. A `komira.files` object location whose last
  segment, after one compression suffix, ends in an extension other than `.parquet` (`.csv`, `.json`,
  `.jsonl`, `.ndjson`) is refused with `BIND_SOURCE_UNSUPPORTED` instead of failing in the Parquet
  footer reader. A glob with no extension (`s3://b/p/*`) is read as Parquet, as today. Tests that
  fail before the change: a URL given to each Python reader, and a URL in each SQL form, raises the
  named code (rule T5). Moves: probes under `31-read-parquet-csv-files-s3/`, each with its one-line
  error: `probe_csv_object.py` (a CSV object in `komira.files`), `probe_sql_url.py` (a Parquet URL
  in the SQL text under a bound scope) and `probe_read_parquet_url.py`. Also the notes of pages 31
  and 93. No status change.
- **Slice 2: The S3 chain: `komira.AMBIENT` and `komira.AwsProfile` on `s3://`.** `so` builds the
  default chain over the process's environment and files (decision 3). The region comes from
  `region=` first; then, for `AMBIENT`, from the chain, and for `AwsProfile`, from the profile. The
  `CREDENTIALS_NOT_FOUND` and `BIND_SOURCE_UNSUPPORTED` refusals of these two go. Tests: each chain
  step answering under `MapEnv` and `MapFiles`; a broken step giving `CREDENTIALS_INVALID` without
  falling through; nothing configured giving `CREDENTIALS_NOT_FOUND`; an explicit credential with no
  `region=` giving `STORAGE_REGION_UNKNOWN` even with `AWS_REGION` set; the Python ambient test of the
  testing section. Moves: page 31's notes. No status change.
- **Slice 2b: Unsigned S3 reads** (Q7). `komira.ANONYMOUS` on `s3://` sends requests with no signature.
  Tests: `FakeS3` in a mode that serves a public bucket answers them, and refuses a signed request
  with a wrong key while that mode is off. Moves: page 31's notes. No status change.
- **Slice 3: Scopes, the default scopes, and URLs in the SQL text, for Parquet reads.**
  `komira.files("s3://b/")` binds a scope (decision 5). `FROM '<url>'` and `read_parquet('<url>')`
  read through the longest covering scope. `register_parquet(name, url or source)` binds (Q3).
  Tests: the longest scope wins; `s3://b/` does not cover `s3://b-two/`; an `az://` URL with no scope
  gives `CREDENTIALS_NOT_FOUND`; the default `s3://` scope reads with the chain; a scope bound twice
  replaces the first. Moves: it removes `probe_sql_url.py`, and page 31 gains the SQL form. No status
  change: CSV is not read yet.
- **Slice 4: DataFrame readers over URLs, for Parquet.** `komira.read_parquet` and
  `komira.pl.scan_parquet` take a URL or a `komira.files` source (Q1). This adds
  `WireParquetSource.access` and `WireScanBinding.access` with envelope format version 6 (decision
  5). Tests: the plan carries the credential's name and no key bytes (every byte of the encoded plan
  checked); the two cross-release tests; a bare URL reads with the chain while a scope bound for SQL
  changes nothing for it. Moves: it removes `probe_read_parquet_url.py`. No status change.
- **Slice 5a: CSV objects on `s3://` and `az://`.** The CSV scan spec carries the file system, as
  Parquet's does. The scan reads the object's body through it with `read_at` and parses it with
  `read_csv_bytes_to_batch`, decompressing with `decompress_text_bytes_to_buffer`. The binder takes
  the format from the extension, so slice 1's refusal of `.csv` goes. `read_csv('<url>')` and
  `FROM '<url>.csv'` read through the scope. `register_csv` takes a URL or a source (Q3), and so do
  `komira.read_csv` and `komira.pl.scan_csv`, over `WireScanBinding.access`. Tests: each CSV option
  over a stand-in equals the same file read locally; `.csv.gz` and `.csv.zst`; a missing object gives
  `STORAGE_NOT_FOUND`; the two cross-release tests for a CSV scan. Moves: it removes
  `probe_csv_object.py`. **Rank 31 may become `works`**: Parquet and CSV are read from `s3://` with
  the chain or explicit keys, through SQL and the DataFrame readers. Its page shows CSV, and page
  93's notes change.
- **Slice 5b: JSON objects on `s3://` and `az://`.** The same as 5a for the JSONL scan: `read_json`,
  `register_json`, `komira.read_json` and `komira.pl.scan_ndjson`. Tests mirror 5a's, with
  `.jsonl.zst`. No status change.
- **Slice 6a: `COPY ... TO 's3://...'`.** The SQL door's write through the run's file system (decision 6),
  with PUT and the multipart verbs added to `FakeS3`. Tests: one PutObject for a small file and a
  multipart upload for one above 8 MiB, each read back equal; a failed part and a failed completion
  (the in-memory fake's `fail_part` and `fail_complete`) leave no object and abort the upload; an
  existing object is replaced; reading and writing one object in one statement; `gs://` and `az://`
  destinations give `STORAGE_WRITE_UNSUPPORTED`. Moves: a new `32-write-query-results-s3-parquet/`
  with `example.py`, its stand-in, `expected_output.txt` and `page.md`, writing with `COPY`. **Rank
  32 may become `works`.**
- **Slice 6b: The DataFrame write terminals on `s3://`.** `to_parquet`, `to_csv` and `to_json` of an
  `s3://` URL or a `komira.files` destination (Q2) through `run_plan_write`. This adds
  `WireWriteTarget.access` with format version 6. Tests: slice 6a's, through the plan door; the two
  cross-release tests. Moves: page 32 gains `to_parquet`. No status change.
- **Slice 7: Listing: the `glob` table function** (decision 7, Q6), over local paths, `s3://` and `az://`.
  This adds List Blobs to the in-memory Azure fake. Tests: `*`, `?`, `[...]` and `**` over a
  stand-in equal DuckDB's `glob` over the same local tree; no match is no row; key order; `gs://`
  refused by name. Moves: a new `96-list-files-bucket-prefix/`, its page saying `gs://` is not
  listed yet. **Rank 96 may become `partial`.**
- **Slice 8a: The GCS JSON-API backend**, a conformer of `GcsStorageBackend` in `objectstore_gcs`
  (decision 2, Q5): object metadata, ranged media download, listing. Tests: each call over a
  scripted connector, and `GcsFs` over it. No status change.
- **Slice 8b: `gs://` in libkomira.** `StoreFs` gains GCS; `so` builds the token source from ADC,
  `GcpServiceAccount`, `GcpToken` or `ANONYMOUS`; the default `gs://` scope reads with ADC; Parquet,
  CSV and JSON reads and `glob` reach it. Tests: in Mojo over the in-memory and JSON backends, with
  ADC under `MapEnv` and `MapFiles` and the metadata probe faked. No status change.
- **Slice 8c: The Python stand-in and the pages.** A `FakeGcs` serving the JSON API in
  `objectstore_fakes.py`, the Python tests over it, and the pages. Moves: page 93 shows `gs://`, and
  page 96 drops its `gs://` note. **Rank 93 may become `works`, and rank 96 `works`.**
- **Slice 9: Azure writes.** Put Block and Put Block List in `azure_blob`, under `AzureFs.open_write`
  (decision 2). `COPY ... TO 'az://...'` and the write terminals then write `az://`. Tests mirror
  slices 6a's and 6b's. No status change: no rank asks for an Azure write.
- **Slice 10: GCS writes.** The JSON API's resumable upload under a `GcsFs` write. Tests mirror slices
  6a's and 6b's. No status change.

### When each catalogue status may change

Only as far as is true after the slice lands:

| after slice | 31 | 32 | 93 | 96 |
|---|---|---|---|---|
| today | partial | gap | partial | gap |
| 1 to 4 | partial | gap | partial | gap |
| 5a | **works** | gap | partial | gap |
| 5b | works | gap | partial | gap |
| 6a | works | **works** | partial | gap |
| 6b | works | works | partial | gap |
| 7 | works | works | partial | **partial** |
| 8a, 8b | works | works | partial | partial |
| 8c | works | works | **works** | **works** |
| 9, 10 | works | works | works | works |

Rank 93 stays `partial` until slice 8c, because its question names Google Cloud Storage. Rank 96
is `partial` from slice 7 until slice 8c, because it lists `s3://` and `az://` but not `gs://`. A
status changes in the same pull request as its page and its probes, as the catalogue's
[README](../tasks/README.md) requires. Each of ranks 32 and 96 gets its directory in the pull request
that makes it no longer a gap.
