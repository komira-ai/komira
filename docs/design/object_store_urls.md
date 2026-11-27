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

# pandas' and polars' own spelling of an explicit credential: the SDK seals the secrets as a named
# credential and keeps only its name and the settings in the plan.
df = komira.read_parquet("s3://sales/2026/east.parquet",
                         storage_options={"key": key_id, "secret": secret,
                                          "client_kwargs": {"region_name": "eu-west-1"}})
lf = komira.pl.scan_parquet("s3://sales/2026/*.parquet",
                            storage_options={"aws_access_key_id": key_id,
                                             "aws_secret_access_key": secret, "aws_region": "eu-west-1"})
s.register_csv("returns", "s3://sales/2026/returns.csv", delimiter=";")   # Q3, still open

# An explicit credential, for SQL: a scope (a location ending in "/") gives every URL under it its
# credential and store settings.
s.add_sql_binding("sales_bucket", komira.files(
    "s3://sales/", credential=komira.AwsKeys("sales-etl", key_id=key_id, secret=secret),
    region="eu-west-1",
))
s.sql("COPY (SELECT * FROM 's3://sales/2026/*.parquet' WHERE amount > 100) TO 's3://sales/big.parquet'")

# Listing, as DuckDB's glob(): one row per object, one column `file`; the same from the SDK.
s.sql("SELECT file FROM glob('s3://sales/2026/*') ORDER BY file")
files = komira.glob("s3://sales/2026/*")

# A public bucket: the chain finds no credentials, so the read goes unsigned.
s.sql("SELECT count(*) FROM 's3://some-public-bucket/data/*.parquet'")

# The DataFrame door: a bare URL uses the chain; a komira.files source carries its own credential.
df.to_parquet("s3://sales/out/east.parquet")
df.to_parquet("s3://sales/out/east.parquet", storage_options={"key": key_id, "secret": secret,
                                                              "client_kwargs": {"region_name": "eu-west-1"}})
komira.read_parquet(komira.files("az://reports/2026/q1.parquet", credential=komira.AzureSas(...)))
```

What does not change: the SQL text is DuckDB's; a local path reads as it does today; the existing
`Session.add_sql_binding(name, komira.files(...))` spelling, with the same credential classes, keeps
working, and the two task pages that use it keep their output.

## Decisions on the APIs, and the question still open

Each row is an API with no counterpart in DuckDB, pandas or polars, or a place where komira differs
from them. Six rows are decided, and the rest of the document is written to them. Q3 is still open:
no part of a slice that depends on it starts before it is answered. Slices 3, 5a and 5b depend on it
only for their `register_*` part.

| # | question | the reference libraries | decision | slice |
|---|---|---|---|---|
| Q1 | How a DataFrame reader gets an explicit credential | pandas: `read_parquet(url, storage_options={...})`, a dict of keys forwarded to the fsspec backend; polars: `scan_parquet(url, storage_options={...}, credential_provider=...)`, a dict of object_store keys | **decided: both spellings.** (1) `storage_options=` on every pandas-shaped and polars-shaped reader, each shape taking its own library's keys ([decision 8](#8-storage_options-a-second-spelling-of-a-source)). The SDK splits the dict into a credential, sealed under a generated name, and the source's settings, so it builds exactly the plan a `komira.files` source builds, and no secret rides in the plan. (2) A `komira.files(...)` source in place of the path, as the credentials design's decision 3 already says, for what a dict cannot say. The credentials design's "Options considered" rejects storage options *per session, matched by prefix* (`Session(storage=[...])`), which is a different thing from a keyword on one call | 4 (the source), 4b (`storage_options=`) |
| Q2 | How a write terminal gets an explicit credential | pandas: `df.to_parquet(url, storage_options={...})`; polars: `write_parquet(url, storage_options=...)`, `sink_parquet(url, storage_options=...)` | **decided: both spellings, as Q1.** `storage_options=` on `to_parquet`, `to_csv` and `to_json` (and on `komira.pl`'s sink and write verbs once they are built) lands with the write terminals in slice 6b. A `komira.files(...)` destination has no counterpart in any reference library. With `storage_options=` covering explicit credentials, it is not needed in the first slices and waits for a later, additive pull request | 6b (`storage_options=`); later (the source destination) |
| Q3 | Whether `register_parquet`, `register_csv` and `register_json` take a URL, and a `komira.files` source | these verbs are komira's own; DuckDB's counterpart is `read_csv('s3://...', delim=';')` in SQL | **open.** Recommendation: yes to both. A bare URL means `komira.files(url)` with the chain. A source is the only way to give a remote CSV its parsing options (`delimiter`, `header`) and an explicit credential, since `komira.files` takes no format options. The alternative is a `format=`/`delimiter=` keyword on `komira.files`, which would be invented too | 3, 5a, 5b (their `register_*` part) |
| Q4 | A listing verb in the SDK | DuckDB: SQL `glob(pattern)`. pandas and polars have none | **decided: add one.** `komira.glob(pattern)`, and `Session.glob(pattern)`, build the plan node SQL `glob(pattern)` builds and return a frame with the one column `file`. A source or `storage_options=` gives the credential. There is one listing path, in the library ([decision 7](#7-listing)) | 7 |
| Q5 | Which protocol reads `gs://` | DuckDB reads `gs://` through Google's S3-compatible XML API with HMAC keys | **decided: the gRPC backend that exists, and no other.** The SDK only builds a plan; the library underneath calls GCS. What that backend still needs, and how `gs://` is tested without a second backend, are in [decision 2](#2-the-library-and-wire-protocol-for-each-store) | 8a, 8b |
| Q6 | When a glob lists | Spark lists when the DataFrame is created and holds that listing for it ([decision 9](#9-when-a-glob-lists-sparks-rule)) | **decided: as Spark does.** A read's glob and `glob()` list when the source, frame or statement is created, and hold that listing; a run reads what was listed, an object that changed or went away since then is refused by name, and the caller refreshes by creating it again | 3, 4, 7 |
| Q7 | A public bucket read with no configuration | DuckDB's examples read public buckets with no secret set | **decided: fall back to unsigned.** When the provider chain finds no credentials, a read under `komira.AMBIENT` is sent unsigned. A private bucket then fails with a message naming both causes. `komira.ANONYMOUS` still forces unsigned. The same rule holds for `gs://` and `az://` where the store answers unsigned reads ([decision 3](#3-credentials)) | 2b |

Rows that are not questions, because an existing design settles them: a bare URL in SQL and in the
DataFrame readers uses the provider chain (`komira.AMBIENT`); plaintext `http://` is reached only
through a source's `endpoint=`. Those are the credentials design's own owner questions, and this plan
follows its recommendations. On the region, decision 3 says how a region is found by asking the
store, never guessed.

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
- **GCS last.** It is not wired into libkomira at all. Its one backend, gRPC over TLS, still needs
  an unsigned mode, an emulator endpoint and a test stand-in built for it (decision 2). Its file
  system has no write. It moves rank 93 and the GCS half of rank 96, the two least common of the
  four.

### 2. The library and wire protocol for each store

| store | reads and listing | writes | why |
|---|---|---|---|
| S3 | `objectstore_s3`'s `S3Fs`: HEAD, ranged GET, ListObjectsV2 | `S3Fs.open_write`/`write_at`/`close_write`: PutObject when the file fits in one part, else CreateMultipartUpload, UploadPart, CompleteMultipartUpload; AbortMultipartUpload on any failure | built and tested over the in-memory `FakeS3Connector`, which serves every one of these verbs and injects failed parts and a failed completion |
| Azure Blob | `azure_blob`'s `AzureFs`: Get Blob Properties, ranged Get Blob, List Blobs. `abfs://` and `abfss://` go to the flat Blob endpoint, not the Data Lake one | **PROPOSED** in slice 9: Put Block and Put Block List under `AzureFs.open_write`, the same buffered-part shape as `S3Fs`; one Put Blob when the file fits in one block | the read path is built; block-blob upload is the service's only way to write a blob larger than one request, and the `FileSystem` trait already names `PutBlockList` as Azure's commit step (`fs/file_system.mojo`) |
| GCS | `objectstore_gcs`'s `GcsFs` over the one backend that exists, `StorageGrpcBackend`: gRPC `google.storage.v2` over HTTP/2 and TLS (`GetObject`, `ReadObject`, `ListObjects`) | **PROPOSED** in slice 10: a `GcsFs` write that sends the whole buffered file as one `WriteObject` client stream, which `_write_object` already sends in 2 MiB chunks | the SDK only builds a plan; the library underneath calls GCS, so one backend serves every SDK |

**What the gRPC backend needs to serve `gs://` from the SDK** (slice 8a):

- **An unsigned mode** for public buckets: a call with no `authorization` metadata. The client
  refuses an empty token today (`grpc_backend.mojo`), and `gcp_core`'s `StaticTokenSource` refuses
  one too. Whether Google's gRPC endpoint answers an unauthenticated read of a public object is
  checked first, against Google's documentation. If it does not, an unsigned `gs://` read is refused
  by name (`BIND_SOURCE_UNSUPPORTED`), and decision 3's fallback does not apply to `gs://`.
- **`endpoint=` for an emulator or a private endpoint**: a host and port, dialled over TLS, with the
  trust root given by the credentials design's `Session(ca_file=...)`. The backend already takes a
  host and port (`StorageGrpcBackend.__init__`) and builds a connector that trusts one root
  (`build_gcs_tls_connector_trusting`). A plaintext `http://` endpoint is refused by name: the
  backend's header records that the gRPC client carries only unary calls over plaintext HTTP/2, and
  `ReadObject` streams.
- **Credentials from `so`**: ADC, a service-account file or a static token as a `GcpTokenSource`
  (decision 3), and `GcsFs` added to `StoreFs`.
- **Nothing else.** Ranged reads, listing with a delimiter, and CRC-checked reads exist.

**How `gs://` is tested with no real service, and no second backend.**

- **Mojo, in memory:** `FakeGcsStorageBackend` (`objectstore_gcs/fake_backend.mojo`) already stands
  in for the backend. It carries the `so` and `sdk_exec` tests, as `test_run_sql_gcs_azure.mojo`
  already does for the engine.
- **Mojo, on the wire:** the scripted-connector tests of `test_gcs_grpc_backend.mojo` hold every call's
  bytes.
- **A loopback gRPC stand-in built by Buck2.** `test_gcs_grpc_trust.mojo` already runs a Mojo
  `HttpServer` on `127.0.0.1:0` over TLS with a test root, answering `GetObject`. Slice 8a grows it
  into a binary target (`//src/objectstore_gcs:gcs_grpc_stand_in`) that also answers `ReadObject` and
  `ListObjects` from objects it is given. Whether `http_server`'s gRPC service carries a server
  stream, which `ReadObject` is, is the first thing that slice checks; if it does not, the slice adds
  that. A `python_binding_test` takes the binary as a data dependency, starts it, and binds
  `endpoint=` and `Session(ca_file=...)` to it, so the Python tests read `gs://` end to end.
- **What the task pages can and cannot run.** A page's example runs in the hermetic CPython with
  the wheel, pyarrow and protobuf only (`python/docs/tasks/BUCK`), with no Buck2-built binary beside
  it. A stdlib stand-in cannot speak TLS, HTTP/2 and gRPC without a library that set does not have.
  So pages 93 and 96 cannot run `gs://`. Each puts the framework's marker, as one line, on the line
  before its `gs://` fence: `<!-- not-tested: gs:// needs the gRPC stand-in, which this page cannot
  run -->`. Its prose says so, and names the `python_binding_test` that runs the same code. Their examples keep running `az://` and `s3://` against stdlib stand-ins.

### 3. Credentials

The credentials design decides the model: a credential is a named object; the plan
carries only its name; `komira.AMBIENT` is the provider's chain, read inside the library and only for
a source that names it; nothing else reads the environment (rule S2). That design's
[environment table](credentials_and_writes.md#the-environment-komira-reads) lists the variables, all
the providers' own. This plan builds it in this order:

| credential | `s3://` | `az://` | `gs://` |
|---|---|---|---|
| `komira.AMBIENT` (the default) | **slice 2**: `so` builds `aws_core`'s `DefaultChainCredsSource` over `ProcessEnv` and `ProcessFiles`, as `job_supervisor` does. The region comes from `region=`, else `AWS_REGION`, `AWS_DEFAULT_REGION`, the selected profile. **Slice 2b**: when the chain finds nothing, unsigned (below) | **slice 2b**: unsigned, since Azure has no standard chain within rule S2 (the credentials design, decision 7); a private container fails as below | **slice 8b**: `gcp_core`'s `application_default_token_source`; when ADC finds nothing, unsigned if the service answers it (decision 2) |
| explicit keys: `AwsKeys` | **EXISTS** | | |
| `AwsProfile` | **slice 2**: the chain's profile step with the named profile, found through `AWS_CONFIG_FILE`, `AWS_SHARED_CREDENTIALS_FILE` and `HOME` only | | |
| `AzureKey`, `AzureSas` | | **EXISTS** | |
| `GcpServiceAccount`, `GcpToken` | | | **slice 8b**: `ServiceAccountKeyFetcher` inside `CachingTokenSource`; `StaticTokenSource` |
| `komira.ANONYMOUS` | **slice 2b**: requests with no signature. `so` refuses it today (`bindings.mojo`, "unsigned s3:// reads are not served"), and no unsigned mode was found in `objectstore_s3` *(inferred from a search for one)* | **EXISTS** | **slice 8b**, with slice 8a's unsigned mode, if the service answers unsigned reads; otherwise refused by name (decision 2) |

- The S3 stores themselves never read the environment, and a test holds that
  (`objectstore_s3/tests/test_no_env_reads.mojo`). So the chain is built in `so`, which hands the
  store a credentials source. `objectstore_s3` does not change.
- A chain step that is configured but broken raises `CREDENTIALS_INVALID` naming the setting, as
  `aws_core` already rules, and never falls through, not even to unsigned. The boundary is
  `aws_core`'s own. An instance-metadata endpoint that cannot be reached is a step that is absent,
  the one step `aws_core` allows to be absent, so it counts as finding nothing. So do shared files that
  do not exist when no profile was named. A file that exists but does not parse, a named profile that
  is in neither file, or one of the web-identity pair set without the other is broken. The message's `source=`
  field names the step that answered (the credentials design, decision 11).

**When the chain finds nothing: unsigned** (Q7, slice 2b). Under `komira.AMBIENT`, a chain that
finds nothing configured is not an error. The read is sent unsigned, so a public bucket reads with no
configuration, as DuckDB's examples expect. `komira.ANONYMOUS` still forces unsigned, whatever the
chain would find.

- **A private bucket** then fails. The message names both causes, with `CREDENTIALS_NOT_FOUND` as its code
  (`CredentialsError`), since configuring credentials is the fix:
  `bind: CREDENTIALS_NOT_FOUND: GetObject s3://b/k.parquet status=403 provider_code=AccessDenied
  credential=ambient source=unsigned: the provider chain found no credentials (environment, web
  identity, profile files, container, instance metadata), and the store refused the unsigned
  request; configure credentials, or name one with komira.files`. The list in parentheses is the
  steps the chain tried. The message carries no value, per the credentials design's decision 11.
- **The region.** A public bucket is read with no region configured too. When no setting gives an
  S3 source a region, komira asks the bucket: one `HeadBucket` request, whose answer carries the
  bucket's region in `x-amz-bucket-region` *(inferred from AWS's documentation of HeadBucket; the
  slice confirms it)*. That is asking the store, not guessing, so the credentials design's refusal of
  a guessed region stands. A store that does not answer, or an `endpoint=` store, keeps
  `STORAGE_REGION_UNKNOWN`. An unsigned request to an `endpoint=` store needs no region.
- **`az://`**: Azure has no chain, so `komira.AMBIENT` on `az://` is always unsigned. A container
  that allows anonymous reads reads with no configuration. A private one fails with the message above,
  naming `credential=ambient source=unsigned` and that Azure has no chain. Slice 2b makes this the
  meaning of `komira.AMBIENT` on an `az://` source. From slice 3, an `az://` URL in SQL needs no
  bound scope, because the default scopes include `az://`. That amends the credentials design's
  decision 3, which refuses an `az://` URL under no scope with `CREDENTIALS_NOT_FOUND`, and slice 3
  changes that decision in its pull request.
- **`gs://`**: when ADC finds nothing, unsigned, if decision 2's check finds that the service answers
  unsigned gRPC reads. Otherwise `CREDENTIALS_NOT_FOUND` as today.
- **Caches.** The fallback is decided per read, and nothing about it is kept, so a credential
  configured later is used by the next read. An object an unsigned read can read is public, and a
  signed read of it returns the same bytes. So the footer and metadata cache entries `ambient` keys
  are safe to share between the two.
- This amends the credentials design's decision 7, where nothing configured always raises
  `CREDENTIALS_NOT_FOUND`. Slice 2b changes that decision and its tests in the same pull request.
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
| the same, with a credential | `komira.read_parquet(url, storage_options={...})` with pandas' keys and `komira.pl.scan_parquet(url, storage_options={...})` with polars' keys (decision 8); or `komira.read_parquet(komira.files(url, credential=komira.AwsKeys(...), region=...))` (Q1) | `storage_options={"key": ..., "secret": ...}`, passed to `fsspec.open` | `storage_options={"aws_access_key_id": ..., "aws_region": ...}` | 4, 4b |
| polars-shaped lazy read | `komira.pl.scan_parquet(url or source)`, `scan_csv`, `scan_ndjson` | | `pl.scan_parquet`, `pl.scan_csv`, `pl.scan_ndjson` | 4, 5a, 5b |
| read CSV or JSON from a URL | `komira.read_csv(url or source, sep=..., header=...)`, `komira.read_json(...)` | `pd.read_csv("s3://...")` *(inferred: the read_parquet page documents the URL schemes; the read_csv page was not read)* | `pl.scan_csv("s3://...")`; polars reads Parquet, CSV, IPC and NDJSON from cloud storage ([polars: cloud storage](https://docs.pola.rs/user-guide/io/cloud-storage/)) | 5a, 5b |
| bind a SQL name to a URL | `s.register_parquet(name, url or source)`, `register_csv(name, url or source, delimiter=..., header=...)`, `register_json(...)` (Q3); **EXISTS**: `s.add_sql_binding(name, komira.files(url, ...))` for Parquet | | | 3, 5a, 5b |
| write a frame to a URL | `df.to_parquet("s3://b/k.parquet")`, `to_csv`, `to_json`, chain; with a credential, `storage_options=` (decision 8), and later perhaps a `komira.files` destination (Q2) | `df.to_parquet("s3://...", storage_options={...})` ([pandas: to_parquet](https://pandas.pydata.org/docs/reference/api/pandas.DataFrame.to_parquet.html)) | `df.write_parquet("s3://...")`; the [cloud-storage guide](https://docs.pola.rs/user-guide/io/cloud-storage/) says a frame is written by passing a cloud URL | 6b |
| list a prefix | `komira.glob("s3://b/p/*")`, `s.glob(...)`, a frame with one column `file`; or `s.sql("SELECT file FROM glob('s3://b/p/*')")` (Q4) | none | none | 7 |

- **Every reader takes a path, a URL or a `komira.files` source**, and `storage_options=` beside a
  URL (decision 8). A bare URL is `komira.files(url)` with `komira.AMBIENT`. Readers never read the session's SQL bindings or
  scopes (the credentials design, decision 3): a credential is either the chain or the source's own.
- **`_local_path` stops turning a URL into a path** (slice 1). A string with a scheme (`<letters>://`)
  goes to the library verbatim, as `_write.destination` already sends a write URL. The library then
  serves the URL or refuses it by name. `komira.files` already parses the scheme with the same
  pattern (`_URL` in `_sources.py`), so both doors share one rule.
- **Two spellings of one source** (Q1). `storage_options=` is what pandas and polars users already
  write, so komira takes it, each shape with its own library's keys. `komira.files` stays for what a
  dict cannot say (decision 8). Both build the same plan: a location, its settings, and a credential
  name.

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
  scopes `s3://`, `gs://` and `az://` bound to `komira.AMBIENT`; on `az://` that is an unsigned read
  (decision 3).
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
  takes the chain for a bare URL, or `storage_options=` (decision 8, Q2).
- **Refused by name:** a `gs://`, `az://` or `https://` destination (`STORAGE_WRITE_UNSUPPORTED`,
  replacing today's `STORAGE_URL_REFUSED` for these schemes); the `COPY` options that are refused for
  local files already (`PARTITION_BY` among them, `COPY_OPTION_UNSUPPORTED`).

### 7. Listing

Slice 7 adds the table function `glob(pattern)`, DuckDB's name and shape, and the SDK verb that builds
the same plan node (Q4).

- **The plan node.** No glob node exists in the plan today; a read's glob is expanded into the files
  `WireParquetSource.paths` carries. Slice 7 adds a listing source to the plan: the pattern, its
  `WireSourceAccess`, and the files it listed (decision 9). This is a new scan-source kind, added
  under rule B8, with the envelope at format version 6. The SQL binder builds it for `glob(...)` in a
  `FROM` clause.
- **The SDK verb.** `komira.glob(pattern, *, storage_options=None, session=None)` and
  `Session.glob(pattern, *, storage_options=None)` return a frame of that node. `pattern` is a path, a
  URL, or a `komira.files` source with its own credential. `storage_options=` takes the pandas-shaped
  keys of decision 8. To list when the frame is created, the SDK calls the library, which lists through
  the one function the binder uses and returns the node with its files; this is a new C ABI row,
  `komira_list_source`. There is no second listing path, in Python or anywhere else. `komira.pl` gains
  no verb in this slice.
- **What it returns.** One `VARCHAR` column named `file`, one row per object whose key matches. Each
  value is the object's whole location, written with the scheme and bucket of the pattern
  (`s3://b/p/x.parquet`). A local pattern returns local paths, as DuckDB's does.
- **Pattern syntax** is the reads' syntax, `fs/glob.mojo` per path segment: `*` and `?` stay within
  one segment, `[...]` is a class, and one `**` matches any depth. So `glob('s3://b/p/*')` lists one
  level under `p/`, and `glob('s3://b/p/**')` lists every object under it. A pattern with no glob
  character returns the one object of that key, or no row. Slice 7 checks this, and every other row of
  this decision, against DuckDB's `glob` over a local tree, and does what DuckDB does or refuses by
  name.
- **No match is no row**, not an error. A read of a glob that matches nothing keeps its
  `PARQUET_GLOB_NO_MATCH`, as Spark's read refuses an empty glob (decision 9).
- **Order.** komira returns the rows in key order. A query that needs an order still writes
  `ORDER BY file`, and the task page does.
- **When it lists:** when the statement is bound or the frame is created, held for it, as decision 9
  says.
- **Credentials and stores.** SQL uses the covering scope, as a URL does, and the SDK verb uses its
  source, its `storage_options=` or the chain. `s3://` and `az://` are listed in slice 7, and `gs://`
  once slice 8b wires GCS.
- **Not added:** the object's size or modification time. DuckDB's `glob` has neither, and adding a
  column later is additive.

### 8. `storage_options=`: a second spelling of a source

`storage_options=` comes with each reader and writer that takes a URL. Slice 4b adds it to
`komira.read_parquet` and `komira.pl.scan_parquet`, slice 5a to `komira.read_csv` and
`komira.pl.scan_csv`, slice 5b to `komira.read_json` and `komira.pl.scan_ndjson`, and slice 6b to the
write terminals `to_parquet`, `to_csv` and `to_json`. `komira.pl`'s sink and write verbs take it when
they are built. A scheme's rows apply once that scheme is read: the `gs://` rows of the tables below
are refused with `STORAGE_URL_REFUSED`, as a `gs://` URL is, until slice 8b. It is taken beside a URL, never beside a local path or a `komira.files`
source (`TypeError`). It is not added to `register_*` or `add_sql_binding`, which are komira's own
verbs and take a source (Q3).

**What the SDK builds.** The credentials design's decision 4 stands: the plan carries a location,
the settings needed to reach it, and a credential *name*, never a value. So the SDK splits the dict
before the library is called:

- **The credential keys** become one credential of the kind they fit: `AwsKeys`, `AwsProfile`,
  `GcpServiceAccount`, `GcpToken`, `AzureKey` or `AzureSas`. These are the access key id, the secret,
  the session token, the profile, the Google credentials file or token, the Azure account with its key
  or SAS. The SDK defines that credential through the C ABI's `komira_credential_add`, `_set` and
  `_seal`, like any other, under a generated name, `storage-options-<n>`. `<n>` counts the distinct
  credential values the session has sealed this way.
- **The other keys** become the source's settings: `region`, `endpoint`, `url_style`, or
  `komira.ANONYMOUS` for an unsigned read.
- **No credential key** means `komira.AMBIENT` with those settings, as for a bare URL.
- The result is exactly the `komira.files(url, credential=..., region=..., endpoint=...,
  url_style=...)` source the user could have written with a credential named `storage-options-<n>`,
  and so builds the same plan bytes. The reader then proceeds as it does with that
  source.

**The generated name.**

- **Scope: the session**, `KOMIRA_BIND_SESSION`. The credentials design's decision 8 defines the call scope
  (`KOMIRA_BIND_CALL`) only for the next `komira_sql_stream`. The readers and write terminals run
  through `komira_plan_stream`, and decision 2 already seals a DataFrame reader's source on the
  session. Because every distinct value gets its own name, sealing one never changes the value of
  another name, which is the hazard the call scope exists to avoid. The value stays in the
  session's secret store until the session closes, as any sealed credential does.
- **Reuse.** A later call whose credential keys are byte-equal to an earlier one's reuses its name.
  The library's byte-equal rule then keeps its generation. The SDK recognises the repeat by a SHA-256
  digest of the credential's kind and fields, held in the Python session object only, never in a
  plan, a render, a message or a log.
- **Plan identity and caches** (the credentials design's decision 6). The generated name and its generation are
  part of a read's identity like any other name. Two calls with the same dict read under one name
  and one generation, so they share footer and metadata cache entries, correctly, since the value is
  the same. Two calls with different dicts read under two names, so no cache answers one with what
  the other read. `komira_plan_render` prints the generated name, so their plans render and hash
  differently. Names are per session, and caches are never shared across sessions, so
  `storage-options-1` in two sessions never meets.
- **Reserved.** A user credential whose name starts with `storage-options-` is refused with
  `ValueError` when it is built, and with `CREDENTIALS_INVALID` through the C ABI. This narrows the
  credentials design's decision 1 grammar, which reserves only `ambient` and `anonymous`. Slice 4b
  amends that decision in the same pull request. No release has shipped the grammar: the task pages
  of ranks 31 and 93 note that the credential classes are newer than the PyPI release 0.1.1623.
- **A job manager.** `storage_options=` is a local-session spelling. A job manager's admission
  refuses every credential name with the reserved prefix by name (`CREDENTIAL_UNBOUND`), whatever its
  secret catalog holds, so a plan can never bind a generated name to a stored secret that happens to
  share it. A plan meant for a job manager names its credential with `komira.files` and a name the
  secret store knows.
- **Cost.** Each distinct value is a new name, kept with its cache entries until the session
  closes. A program that rotates a short-lived token (`token`, `sas_token`, a bearer token) on every
  call grows the session's secret store by one value per rotation. Such a program names one
  credential with `komira.files` and re-adds it, which replaces the value under one name (the
  credentials design's decision 2).

**Each shape takes its own library's keys.** The pandas-shaped verbs take the keys pandas forwards
to fsspec ([pandas: read_parquet](https://pandas.pydata.org/docs/reference/api/pandas.read_parquet.html):
"For other URLs (e.g. starting with "s3://", and "gcs://") the key-value pairs are forwarded to
`fsspec.open`"). Those keys are the constructor arguments of s3fs, gcsfs and adlfs. The polars-shaped
verbs take the object_store keys that polars links from `storage_options`
([polars: scan_parquet](https://docs.pola.rs/api/python/stable/reference/api/polars.scan_parquet.html)).
Every key komira honours is in the tables below. **Any other key is refused by name, never ignored**:
`UnsupportedOperation` naming the verb and the key (`storage_options['requester_pays']`), raised
before the library is called. A value of the wrong type is a `TypeError`. A credential key on a
scheme it does not fit is a `ValueError`, as `komira.files` raises today. polars' `credential_provider=`,
a Python callable, is refused by name too: the library resolves credentials itself and never calls
back into Python (the credentials design's "Options considered").

pandas-shaped verbs ([s3fs](https://s3fs.readthedocs.io/en/latest/api.html),
[gcsfs](https://gcsfs.readthedocs.io/en/latest/api.html), [adlfs](https://fsspec.github.io/adlfs/api/)):

| scheme | key, as the backend documents it | komira |
|---|---|---|
| `s3://` (s3fs) | `key` | `AwsKeys.key_id` |
| | `secret` | `AwsKeys.secret` |
| | `token` | `AwsKeys.session_token` |
| | `profile` (s3fs's examples: `S3FileSystem(profile=...)`) | `AwsProfile(profile=...)` |
| | `anon=True` | `komira.ANONYMOUS` (slice 2b) |
| | `endpoint_url`, or `client_kwargs={"endpoint_url": ...}` | `endpoint` |
| | `client_kwargs={"region_name": ...}` (botocore's client argument; s3fs documents `client_kwargs` as "dict of parameters for the botocore client") | `region` |
| | anything else, `use_ssl`, `requester_pays`, `config_kwargs`, `s3_additional_kwargs`, `version_aware` and every other key of `client_kwargs` among them | refused by name |
| `gs://`, `gcs://` (gcsfs) | `token` as a path to a credentials file | `GcpServiceAccount(file=...)` |
| | `token="anon"` | `komira.ANONYMOUS` |
| | `token="google_default"`, or no `token` | `komira.AMBIENT` (Application Default Credentials) |
| | `endpoint_url` | `endpoint` |
| | `token` as a dict or a credentials object, `token="cache"`, `"browser"` or `"cloud"`, `project`, `access`, `requester_pays`, anything else | refused by name |
| `az://`, `abfs://`, `abfss://` (adlfs) | `account_name` | the credential's account |
| | `account_key` | `AzureKey.key` |
| | `sas_token` | `AzureSas.sas` |
| | `anon=True` | `komira.ANONYMOUS` |
| | `account_host` | `endpoint`, as `https://<account_host>` |
| | `account_key` together with `sas_token` (adlfs signs with the key; komira does not pick one) | refused by name |
| | `account_name` with neither `account_key` nor `sas_token`, and not `anon=True` (Azure's chain is not served) | refused by name |
| | `connection_string`, `credential`, `client_id`, `client_secret`, `tenant_id`, anything else | refused by name |

polars-shaped verbs (object_store's [AmazonS3ConfigKey](https://docs.rs/object_store/latest/object_store/aws/enum.AmazonS3ConfigKey.html),
[GoogleConfigKey](https://docs.rs/object_store/latest/object_store/gcp/enum.GoogleConfigKey.html) and
[AzureConfigKey](https://docs.rs/object_store/latest/object_store/azure/enum.AzureConfigKey.html), every
spelling each documents):

| scheme | keys | komira |
|---|---|---|
| `s3://` | `aws_access_key_id`, `access_key_id` | `AwsKeys.key_id` |
| | `aws_secret_access_key`, `secret_access_key` | `AwsKeys.secret` |
| | `aws_session_token`, `aws_token`, `session_token`, `token` | `AwsKeys.session_token` |
| | `aws_region`, `region`; else `aws_default_region`, `default_region` | `region` |
| | `aws_endpoint`, `aws_endpoint_url`, `endpoint`, `endpoint_url` | `endpoint` |
| | `aws_virtual_hosted_style_request`, `virtual_hosted_style_request` | `url_style`: `"true"` is `vhost`, `"false"` is `path` |
| | `aws_skip_signature`, `skip_signature` as `"true"` | `komira.ANONYMOUS` (slice 2b) |
| | anything else: `aws_endpoint_url_s3`, the role, web-identity, container and metadata keys, `aws_request_payer`, `aws_s3_express`, `aws_unsigned_payload`, the conditional-put, tagging, bucket, checksum and encryption keys, and the client keys | refused by name |
| `gs://`, `gcs://` | `google_service_account`, `service_account`, `google_service_account_path`, `service_account_path`, `google_application_credentials`, `application_credentials` | `GcpServiceAccount(file=...)` |
| | `google_bearer_token`, `bearer_token` | `GcpToken` |
| | `google_base_url`, `base_url` | `endpoint` |
| | `google_skip_signature`, `skip_signature` as `"true"` | `komira.ANONYMOUS` |
| | anything else: `google_service_account_key`, `service_account_key` (a key inline; `GcpServiceAccount` takes a file), the bucket and client keys | refused by name |
| `az://`, `abfs://`, `abfss://` | `azure_storage_account_name`, `account_name` | the credential's account |
| | `azure_storage_account_key`, `azure_storage_access_key`, `azure_storage_master_key`, `access_key`, `account_key`, `master_key` | `AzureKey.key` |
| | `azure_storage_sas_key`, `azure_storage_sas_token`, `sas_key`, `sas_token` | `AzureSas.sas` |
| | `azure_storage_endpoint`, `azure_endpoint`, `endpoint` | `endpoint` |
| | `azure_skip_signature`, `skip_signature` as `"true"` | `komira.ANONYMOUS` |
| | an account name with neither a key nor a SAS and no `skip_signature` (Azure's chain is not served) | refused by name |
| | anything else: the bearer-token, client, tenant, authority, managed-identity, federated-token, Azure CLI, Fabric, emulator (`use_emulator`; write the emulator's `endpoint`), container and encryption keys | refused by name |
| every scheme | the retry keys the polars cloud-storage guide lists (`max_retries`, `retry_timeout_ms`, `retry_init_backoff_ms`, `retry_max_backoff_ms`, `retry_base_multiplier`) | refused by name |

- A key this table maps to `komira.ANONYMOUS` beside a credential key is refused by name: one source
  has one credential.
- An anonymous Azure source reads the account from its URL; one whose URL names no account is
  refused, as `komira.files` refuses it today.
- An S3 dict with credential keys but no region is read in the region the bucket reports
  (`HeadBucket`, decision 3), as s3fs and object_store find a bucket's region by themselves
  *(inferred)*. On an `endpoint=` store it is refused at bind with `STORAGE_REGION_UNKNOWN`, as a
  `komira.files` source is.
- A key that names a store setting komira gains later (requester pays, a connection string, an
  inline Google key) moves from "refused" to a mapping in its own pull request. That change is
  additive.

**What `storage_options=` cannot say, and `komira.files` still does:**

- **A URL written inside SQL.** SQL text has no keyword to hang a dict on. A URL in the SQL text
  takes its credential from a scope, a `komira.files` location ending in `/` bound with
  `add_sql_binding` (decision 5).
- **Two identities in one statement.** A SQL statement over two buckets read under two credentials
  names two bound sources, one per identity.
- **Catalogs.** `komira.iceberg(...)` carries a catalog credential and, for its table files, a
  `data_access` credential. Neither is an object-store dict.
- **A credential a job manager resolves.** That needs a name its secret store knows, which a
  generated name is not.
- **CSV options in `register_csv`**, and every binding that outlives one call: these take a source
  (Q3).

### 9. When a glob lists: Spark's rule

**What Spark does** (Apache Spark's source on its main branch):

- **It lists when the DataFrame is created, on the driver.** `DataSource.resolveRelation` globs the
  paths with `checkAndGlobPathIfNecessary(checkEmptyGlobPath = true, ...)` and builds
  `createInMemoryFileIndex(globbedPaths)`, which becomes the `HadoopFsRelation`'s file catalog
  ([DataSource.scala](https://github.com/apache/spark/blob/master/sql/core/src/main/scala/org/apache/spark/sql/execution/datasources/DataSource.scala)).
  `InMemoryFileIndex` calls `refresh0()` in its constructor, which lists the leaf files and keeps them
  in `cachedLeafFiles`
  ([InMemoryFileIndex.scala](https://github.com/apache/spark/blob/master/sql/core/src/main/scala/org/apache/spark/sql/execution/datasources/InMemoryFileIndex.scala)).
- **It holds that listing for the DataFrame.** Queries over the DataFrame read the cached leaf files;
  objects added later are not seen.
- **It lists in parallel.** Globs are expanded with `ThreadUtils.parmap` over 40 threads. Leaf
  listing becomes a distributed Spark job above `spark.sql.sources.parallelPartitionDiscovery.threshold`,
  default 32 paths
  ([SQLConf.scala](https://github.com/apache/spark/blob/master/sql/catalyst/src/main/scala/org/apache/spark/sql/internal/SQLConf.scala)).
- **An empty glob is an error** at creation, `dataPathNotExistError`, whose condition `PATH_NOT_FOUND`
  reads "Path does not exist: <path>."
- **A file gone by the time the query runs fails.** The condition is `FAILED_READ_FILE.FILE_NOT_EXIST`:
  "File does not exist. It is possible the underlying files have been updated. You can explicitly
  invalidate the cache in Spark by running 'REFRESH TABLE tableName' command in SQL or by recreating
  the Dataset/DataFrame involved"
  ([error-conditions.json](https://github.com/apache/spark/blob/master/common/utils/src/main/resources/error/error-conditions.json)).
  `spark.sql.files.ignoreMissingFiles`, default false, would skip such a file instead.
- **A caller refreshes** by creating the DataFrame again, by `REFRESH TABLE`, or by
  `spark.catalog.refreshByPath(path)`, which "invalidates and refreshes all the cached data (and the
  associated metadata) for any Dataset that contains the given data source path". `InMemoryFileIndex.refresh()`
  clears the file-status cache and lists again.

**What komira does: the same** (Q6), for a read's glob and for `glob()`:

- **When it lists.** When the source, frame or statement is created:
  - a `komira.files` source bound with `add_sql_binding`, when it is added (as today: the footers are
    read then too);
  - a DataFrame reader or `komira.glob`, when it is called;
  - a URL or `glob(...)` in the SQL text, when the statement is bound. A SQL statement is komira's
    DataFrame-creation point, as Spark's analysis is.
- **Where the listing is held.** In the binding, for the session's life or until it is added again. In
  the frame's plan, as the files of its source node. In the statement, for one run. A run lists
  nothing.
- **What a run sees if objects changed.**
  - Objects added since the listing are not read.
  - With each listed object, the listing records the version it read the footer from (S3 and Azure
    `ETag`, GCS generation). The run's reads are conditional on it.
  - An object gone since the listing gives `STORAGE_NOT_FOUND`, and one rewritten gives
    `STORAGE_OBJECT_CHANGED`. Each message names the object and says, as Spark's does, that it changed
    since `<the binding, the frame, the statement>` listed it, and to bind the source again or create
    the frame again to list again.
  - Spark notices only a missing file *(inferred: `FileScanRDD` checks for a missing file, not a
    changed one)*. komira also refuses a rewritten one, because the footer it holds would misread the
    new bytes. komira adds no `ignoreMissingFiles`.
- **How a caller refreshes.** By creating the thing again: `add_sql_binding` of the same name again,
  which replaces it; the reader or `komira.glob` called again; the statement run again. komira adds no
  `refreshByPath` verb; one would be additive later.
- **Not copied: the parallel listing.** Spark lists many directory paths, so it spreads them over
  threads and a job. komira lists one pattern as one paged listing of its static prefix
  (`split_static_prefix` in `fs/glob.mojo`), and the pages of one listing follow each other's
  continuation tokens. A read of several patterns lists each once.

## How each slice is tested, with no real service

Every test is hermetic (rule T12): stores are in-memory fakes or loopback servers on port 0, chains
read `MapEnv` and `MapFiles`, nothing reaches a cloud, and no test asserts timing (rule T10).

| layer | what exists | what the slices add |
|---|---|---|
| Mojo, the store libraries | `FakeS3Connector` (`src/tests/helpers/komira_test_fake_s3`): GET, ranges, HEAD, ListObjectsV2, PutObject, every multipart verb, injected faults. `FakeAzureConnector`: HEAD and GET only. `FakeGcsStorageBackend`, in memory | Azure: List Blobs, Put Block and Put Block List in the fake (slices 7, 9). GCS: the unsigned mode and the trusted-root endpoint over the scripted connector, and the loopback gRPC stand-in binary (slice 8a) |
| Mojo, `so` and `sdk_exec` | `test_add_sql_binding.mojo`, `test_store_fs.mojo` and `test_credentials.mojo` over those fakes | one test file per slice over the same fakes; the chain under `MapEnv` and `MapFiles` with a fake credential transport, so the instance metadata step never dials |
| Python | `FakeS3` (checks SigV4) and `FakeAzure` (checks Shared Key and SAS) on `127.0.0.1:0`, in `objectstore_fakes.py`, used by `sql_binding_test` and `objectstore_installed_test`. Both answer any write with 405 | PUT, `?uploads`, `?partNumber=&uploadId=`, complete and abort in `FakeS3` (slice 6a); a public-bucket mode in `FakeS3` and `FakeAzure` that answers unsigned requests (slice 2b); the Buck2-built gRPC stand-in for `gs://`, started by the test (slice 8b); Azure blocks (slice 9) |
| task pages | ranks 31 and 93 each run a stdlib stand-in inside `example.py`, in the hermetic CPython | the pages of ranks 32 and 96, each with its own stand-in; probes for the forms that are not built yet; `gs://` fences marked `not-tested` with their reason (decision 2) |

- **Ambient in Python tests.** The test sets the provider variables in its own process before the
  session opens (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and `AWS_CONFIG_FILE` and
  `AWS_SHARED_CREDENTIALS_FILE` pointing at files in its scratch directory). It also sets
  `AWS_EC2_METADATA_DISABLED=true`, so a chain that finds nothing falls back to unsigned instead of
  dialling the instance metadata address. Rule S2 allows these, because they are the
  provider's own variables. A task page shows `AwsKeys` rather than setting the environment.
- **Reference answers.** The DuckDB the tests pin (1.5.6) loads its httpfs extension by downloading
  it *(inferred)*, which a hermetic test cannot do, so no test runs DuckDB against a stand-in. Each read slice compares
  komira's answer over the stand-in with komira's and DuckDB's answers over the same files on local
  disk. Slice 7 does the same with DuckDB's `glob` over a local tree.
- **Failure cases** each slice covers, by code: `CREDENTIALS_NOT_FOUND`, `CREDENTIALS_INVALID`,
  `STORAGE_REGION_UNKNOWN`, `STORAGE_ACCESS_DENIED` (a wrong secret, which the fakes refuse),
  `STORAGE_NOT_FOUND`, `STORAGE_THROTTLED` and `STORAGE_TRANSPORT` (the fake's faults),
  `STORAGE_OBJECT_CHANGED` (an object rewritten between reads, and between a listing and its run),
  `STORAGE_NOT_FOUND` for an object deleted between a listing and its run, the unsigned fallback's
  two-cause message on a private bucket, the refusal codes of decision 5 and
  decision 6, and for writes a failed part and a failed completion, each leaving no object and an
  aborted upload. Every message is asserted by exact equality with a known secret in the session, so
  none can carry a secret (rule T13).
- **Cross-release (rule B8).** Slices 4, 5a, 5b, 6b and 7 each name two tests. The first runs the
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
- Resuming an interrupted multipart or block upload, and GCS resumable uploads; requester-pays buckets; S3 Express
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
- **Slice 2b: Unsigned reads, and the fallback to them** (decision 3, Q7). `komira.ANONYMOUS` on
  `s3://` sends requests with no signature, and so does `komira.AMBIENT` when the chain finds
  nothing, on `s3://` and on `az://`. The bucket's region is asked for with `HeadBucket` when no setting
  gives it. The slice amends the credentials design's decision 7 to match. Tests:
  - `FakeS3` and `FakeAzure` in a public mode answer unsigned requests;
  - an empty chain (`MapEnv` empty, the metadata step disabled) reads a public bucket;
  - the same chain on a private bucket gives `CREDENTIALS_NOT_FOUND` with the two-cause message,
    asserted by exact equality;
  - a broken chain step gives `CREDENTIALS_INVALID` and sends no unsigned request, which the fake
    records;
  - `ANONYMOUS` sends no signature even when the chain has keys;
  - `HeadBucket` supplies the region, which replaces slice 2's `STORAGE_REGION_UNKNOWN` for a source
    on AWS's own endpoint, and an `endpoint=` store with no region reads unsigned.

  Moves: page 31's notes. No status change.
- **Slice 3: Scopes, the default scopes, and URLs in the SQL text, for Parquet reads.**
  `komira.files("s3://b/")` binds a scope (decision 5). `FROM '<url>'` and `read_parquet('<url>')`
  read through the longest covering scope. `register_parquet(name, url or source)` binds, pending Q3.
  Tests: the longest scope wins; `s3://b/` does not cover `s3://b-two/`; an `az://` URL with no bound scope
  reads a public container unsigned under the default scope; the default `s3://` scope reads with the chain; a scope bound twice
  replaces the first; an `az://` URL under no bound scope is no longer refused, and the slice amends
  the credentials design's decision 3 to say so. Every listing records each object's version with its footer, and the run reads
  conditional on it (decision 9): an object deleted between bind and run gives `STORAGE_NOT_FOUND`, and
  one rewritten gives `STORAGE_OBJECT_CHANGED`, each message saying to bind again; an object added
  after the bind is not read. Moves: it removes `probe_sql_url.py`, and page 31 gains the SQL form. No status
  change: CSV is not read yet.
- **Slice 4: DataFrame readers over URLs, for Parquet.** `komira.read_parquet` and
  `komira.pl.scan_parquet` take a URL or a `komira.files` source (Q1). This adds
  `WireParquetSource.access` and `WireScanBinding.access` with envelope format version 6 (decision
  5). Tests: the plan carries the credential's name and no key bytes (every byte of the encoded plan
  checked); the two cross-release tests; a bare URL reads with the chain while a scope bound for SQL
  changes nothing for it; a frame of a glob keeps its files after an object is added, and an object
  deleted or rewritten after the frame was created gives `STORAGE_NOT_FOUND` or
  `STORAGE_OBJECT_CHANGED` at the terminal (decision 9). Moves: it removes `probe_read_parquet_url.py`. No status change.
- **Slice 4b: `storage_options=` on the Parquet readers** (decision 8, Q1). `komira.read_parquet` takes
  pandas' keys and `komira.pl.scan_parquet` polars' keys. The SDK seals the credential keys under a
  generated `storage-options-<n>` name on the session and maps the rest to settings. The prefix is
  reserved, and the credentials design's decision 1 says so. Tests: each `s3://` and `az://` row of both key tables builds
  the plan bytes of the equivalent `komira.files` source with a credential named
  `storage-options-<n>`, and each `gs://` row is refused with `STORAGE_URL_REFUSED`; every refused key, one test per row, raises
  `UnsupportedOperation` naming it, with the message asserted by exact equality; a byte-equal dict
  reuses the name and its generation, and a different one gets a new name and no shared cache entry;
  no secret appears in the plan, the render or a message; anonymous beside a credential key, and
  `account_key` beside `sas_token`, are refused; an S3 dict with no region reads in the region `HeadBucket`
  reports, and on an `endpoint=` store gives `STORAGE_REGION_UNKNOWN`; `credential_provider=` is refused by name; a user credential named
  `storage-options-1` raises `ValueError`. Moves: page 31's notes. No status change.
- **Slice 5a: CSV objects on `s3://` and `az://`.** The CSV scan spec carries the file system, as
  Parquet's does. The scan reads the object's body through it with `read_at` and parses it with
  `read_csv_bytes_to_batch`, decompressing with `decompress_text_bytes_to_buffer`. The binder takes
  the format from the extension, so slice 1's refusal of `.csv` goes. `read_csv('<url>')` and
  `FROM '<url>.csv'` read through the scope. `register_csv` takes a URL or a source (Q3), and so do
  `komira.read_csv` and `komira.pl.scan_csv`, over `WireScanBinding.access`, with `storage_options=`
  as in slice 4b for `komira.read_csv` and `komira.pl.scan_csv`. Tests: each CSV option
  over a stand-in equals the same file read locally; `.csv.gz` and `.csv.zst`; a missing object gives
  `STORAGE_NOT_FOUND`; the two cross-release tests for a CSV scan. Moves: it removes
  `probe_csv_object.py`. **Rank 31 may become `works`**: Parquet and CSV are read from `s3://` with
  the chain or explicit keys, through SQL and the DataFrame readers. Its page shows CSV, and page
  93's notes change.
- **Slice 5b: JSON objects on `s3://` and `az://`.** The same as 5a for the JSONL scan: `read_json`,
  `register_json`, `komira.read_json` and `komira.pl.scan_ndjson`, with `storage_options=`. Tests mirror 5a's, with
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
  `s3://` URL, bare or with `storage_options=` (decision 8, Q2), through `run_plan_write`. This adds
  `WireWriteTarget.access` with format version 6. A `komira.files` destination is not in this slice
  (Q2). Tests: slice 6a's, through the plan door; slice 4b's key cases on a writer; the two
  cross-release tests. Moves: page 32 gains `to_parquet`. No status change.
- **Slice 7: Listing: the `glob` table function and `komira.glob`** (decisions 7 and 9, Q4, Q6),
  over local paths, `s3://` and `az://`. This adds the plan's listing source with format version 6,
  the `komira_list_source` C ABI row, `komira.glob` and `Session.glob`, and List Blobs in the in-memory
  Azure fake. Tests:
  - `*`, `?`, `[...]` and `**` over a stand-in equal DuckDB's `glob` over the same local tree;
  - no match is no row, and rows come in key order;
  - `komira.glob(p)` and `s.sql("SELECT * FROM glob(p)")` build byte-equal listing nodes;
  - a frame of `komira.glob` keeps its rows after an object is added to the stand-in, and a new
    `komira.glob` call sees it;
  - `komira.glob` with a source, and with `storage_options=`;
  - `gs://` refused by name;
  - the two cross-release tests.

  Moves: a new `96-list-files-bucket-prefix/`, its page saying `gs://` is not listed yet. **Rank 96
  may become `partial`.**
- **Slice 8a: What the gRPC backend needs** (decision 2, Q5). This adds the unsigned mode, if the
  service answers it, and an endpoint dialled over TLS with a given trust root. It also adds the
  loopback stand-in binary `//src/objectstore_gcs:gcs_grpc_stand_in`, answering `GetObject`,
  `ReadObject` and `ListObjects`, with the server-stream support in `http_server` it may need. Tests:
  the scripted-connector tests for the unsigned call and the endpoint, and `GcsFs` reading and listing
  through the stand-in. No status change.
- **Slice 8b: `gs://` in libkomira.** `StoreFs` gains GCS; `so` builds the token source from ADC,
  `GcpServiceAccount`, `GcpToken` or `ANONYMOUS`, with the fallback of decision 3; the default `gs://`
  scope reads with ADC; Parquet, CSV and JSON reads and `glob` reach it; `Session(ca_file=...)` lands
  for the endpoint's trust root. Tests:
  - in Mojo, over `FakeGcsStorageBackend`, with ADC under `MapEnv` and `MapFiles` and the metadata
    probe faked;
  - in Python, a `python_binding_test` over the stand-in binary;
  - each `gs://` row of decision 8's key tables builds its source.

  Moves: page 93 adds `gs://`, and page 96 drops its `gs://` note. Each page's `gs://` fence has the
  one-line `not-tested` marker of decision 2 on the line before it, and its prose says the page does
  not run it.
  **Rank 93 may become `works`, and rank 96 `works`**: komira then reads and lists `gs://`, tested end
  to end by the binding test, though not run by the page.
- **Slice 9: Azure writes.** Put Block and Put Block List in `azure_blob`, under `AzureFs.open_write`
  (decision 2). `COPY ... TO 'az://...'` and the write terminals then write `az://`. Tests mirror
  slices 6a's and 6b's. No status change: no rank asks for an Azure write.
- **Slice 10: GCS writes.** A `GcsFs` write that sends the buffered file as one `WriteObject` stream
  through the gRPC backend (decision 2); `gs://` destinations stop giving `STORAGE_WRITE_UNSUPPORTED`.
  Tests mirror slices 6a's and 6b's, over `FakeGcsStorageBackend` and the stand-in, which gains
  `WriteObject`. No status change.

### When each catalogue status may change

Only as far as is true after the slice lands:

| after slice | 31 | 32 | 93 | 96 |
|---|---|---|---|---|
| today | partial | gap | partial | gap |
| 1 to 4b | partial | gap | partial | gap |
| 5a | **works** | gap | partial | gap |
| 5b | works | gap | partial | gap |
| 6a | works | **works** | partial | gap |
| 6b | works | works | partial | gap |
| 7 | works | works | partial | **partial** |
| 8a | works | works | partial | partial |
| 8b | works | works | **works** | **works** |
| 9, 10 | works | works | works | works |

Rank 93 stays `partial` until slice 8b, because its question names Google Cloud Storage. Rank 96
is `partial` from slice 7 until slice 8b, because it lists `s3://` and `az://` but not `gs://`. A
status changes in the same pull request as its page and its probes, as the catalogue's
[README](../tasks/README.md) requires. Each of ranks 32 and 96 gets its directory in the pull request
that makes it no longer a gap.
