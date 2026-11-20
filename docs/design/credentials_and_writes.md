# Credentials, remote reads and writes: what the Python package and libkomira take, and how they fail

Status: design, not built. **EXISTS** names code on `main`; **PROPOSED** is new. Statements the author
deduced rather than read are marked *(inferred)*.

## What problem does this solve?

The first release of the Python package reads local files and answers queries
([python_package.md](python_package.md)). The next things users ask for are reading from object
stores and over `https://`, and writing a result to a file. Each needs answers before the engine,
library and Python pull requests can agree:

- how a user gives komira credentials and storage settings, and what komira does when none are given;
- what reads the environment, given that configuration is never an environment variable (rule S2) and
  no endpoint is written into the code (rule S1);
- how a write is spelt in SQL and in the DataFrame surfaces, and what it returns;
- whether `https://` URLs are read;
- the shape of every error these paths raise, and where secrets must never appear.

Two designs already hand these questions here. The ABI design for running a query lists credentials
under "new relative to the earlier ABI" and gives its starting constraints
([libkomira_run_abi.md §10](libkomira_run_abi.md#10-new-relative-to-the-earlier-abi)). It also leaves
statements that are not queries (`STATEMENT_NOT_A_QUERY`) and envelopes with a write target
(`PLAN_WIRE_WRITE_TARGET_DROPPED`) refused "until writes have their own design"
([§3](libkomira_run_abi.md#what-komira_sql_stream-runs)). The Python package design promises a
`KomiraError` with `code` and `step` ([decision 9](python_package.md#9-errors)), but ABI 1.2 gives a
binding only a status and a message it must not parse. This design closes that gap too, because the
errors of remote reads and writes are where `code` matters most.

Fixed before this design and not reopened here: the distribution and import name `komira`; the
release platforms; same SQL, same result as DuckDB, with unsupported features refused by name (rule
B21); the client optimizes, and a job manager takes only a serialized optimized plan; Python is used only
for the Python surface.

## What exists today

- **EXISTS** The AWS default credential chain, as a library with injected seams
  ([src/aws_core/README.md](../../src/aws_core/README.md), `credential_chain.mojo`). In order:
  1. explicit parameters;
  2. `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`;
  3. web identity (`AWS_WEB_IDENTITY_TOKEN_FILE`, `AWS_ROLE_ARN`);
  4. the shared config and credentials files, for the selected profile;
  5. the container credentials endpoint;
  6. the instance metadata service.

  The first configured step answers. A step that is configured but broken is refused, naming the
  setting and never its value, with no fall-through to the next step. `DefaultChainCredsSource` caches
  until near expiry. The environment and the files are read only through the `EnvSource` and
  `FileSource` seams. `MapEnv`, `MapFiles` and `FixedClock` are the hermetic doubles.
- **EXISTS** Google's Application Default Credentials, the same way
  ([src/gcp_core/README.md](../../src/gcp_core/README.md), `adc.mojo`). In order:
  1. the `GOOGLE_APPLICATION_CREDENTIALS` file;
  2. gcloud's well-known file;
  3. the metadata server.

  `external_account` files are refused by name. `AccessToken` has no string conversion.
- **EXISTS** The stores take everything as constructor arguments and read no environment, and a test
  holds that ([src/objectstore_s3/README.md](../../src/objectstore_s3/README.md),
  `tests/test_no_env_reads.mojo`; [src/objectstore_gcs/README.md](../../src/objectstore_gcs/README.md)).
  - `S3Fs` takes an `S3Config` (region, endpoint, addressing style), a credential source
    (`AwsCredsSource`) and a clock. S3 writes are multipart uploads.
  - `GcsFs` takes a backend that carries a token source. Its write verbs raise.
  - `azure_blob`'s `AzureFs` is read-only. It takes Shared Key, SAS or anonymous credentials, and has no
    chain ([src/azure_blob/README.md](../../src/azure_blob/README.md)).

  So the brief's "objectstore_s3 takes credentials as constructor args" is true. What is missing is
  the layer that chooses those arguments for a user.
- **EXISTS** The engine's secret model ([src/sdk_exec/secret_capability.mojo](../../src/sdk_exec/secret_capability.mojo),
  [src/secret_registry](../../src/secret_registry/README.md), [src/secret_store](../../src/secret_store/README.md)).
  - A plan holds a `SecretCapability`, which is a node id and never a value.
  - `SecretBindings` maps node ids to handles.
  - A `SecretStore` resolves a handle to a `SecretValue`. A `SecretValue` is at most 4096 bytes,
    prints as `SecretValue(<redacted:NB>)` (its length, never its bytes), and is wiped when dropped.
  - `EngineContext` and `run_sql` do not use any of this yet.
- **EXISTS** A scan names its file system by `FsDescriptorPod`: a scheme code, a bucket and a node id
  ([src/plan_expr/fs_descriptor_pod.mojo](../../src/plan_expr/fs_descriptor_pod.mojo)). It has no
  credential and no endpoint field. [src/source_url](../../src/source_url/README.md) maps a URL prefix
  to the scheme code:
  - `s3://` and `s3a://` to S3;
  - `gs://` and `gcs://` to GCS;
  - `az://`, `abfs://`, `abfss://` and `https://<account>.blob.core.windows.net` to Azure.

  It refuses every other prefix, every other `https://` host and every `http://` URL. Lowering refuses
  every non-local scan (`LOWERING_SCAN_NOT_TOTAL`).
- **EXISTS** `COPY <table | (query)> TO '<path>' (FORMAT, COMPRESSION, COMPRESSION_LEVEL, HEADER, ARRAY)`
  parses and binds ([src/sql/sql_parser.mojo](../../src/sql/sql_parser.mojo)).
  - The 13 (format, codec) pairs that have a sink are one table, `write_target_supported`
    ([src/arrow/write_target.mojo](../../src/arrow/write_target.mojo)).
  - An option the sink cannot honour is refused, never ignored. Examples are `HEADER false` and
    `ARRAY true`.
  - `run_sql` refuses the statement at `bind` with `STATEMENT_NOT_A_QUERY`
    ([src/sdk_exec/engine_sql.mojo](../../src/sdk_exec/engine_sql.mojo)).
  - The plan wire carries a destination as `WirePlanEnvelope.write_target` (path, format, codec), and
    `OptimizedPlan` carries the same field as `write_target` (field 6).
  - CTAS has no wire arm, deliberately ([src/plan_proto/plan.proto](../../src/plan_proto/plan.proto)).
- **EXISTS, a defect this design fixes.** With no `FORMAT` option, the parser writes Parquet whatever
  the path says. DuckDB infers the format from the extension, so `COPY t TO 'out.csv'` would write a
  Parquet file named `.csv`. A codec is not inferred either: `'out.csv.gz'` would be written
  uncompressed. Decision 7 replaces this with DuckDB's inference, or a refusal by name.
- **EXISTS** `http_client` has a TLS client with ranged GET (`get_range`, which raises
  `HTTP_ERROR_RANGE_NOT_HONORED` on a 200), redirects as a layer, and no proxy support
  ([docs/design/http.md](http.md), [src/http_client/README.md](../../src/http_client/README.md)).

## The decisions

### 1. Where each kind of information travels

| information | travels in | never in |
|---|---|---|
| where data is (a URL or path) | the SQL text, a DataFrame reader's argument, the plan's `FsDescriptorPod` and `write_target.path` | |
| who reads it (credentials) and how to reach the store (region, endpoint, addressing style, trust roots) | the session: a list of storage scopes given when the session is made (decision 2), held by the library | SQL text, plan bytes, error text, `repr`, logs |

- **Credentials never travel with a plan.** A plan says what to read. The process that runs it decides
  who reads, from its own session.
  - This keeps a serialized `OptimizedPlan` safe to send to a job manager.
  - It also matches the way the plan design already treats catalogs and UDF secrets: a name the
    receiver resolves, never a value ([optimized_plan_sources.md](optimized_plan_sources.md),
    [optimized_plan_udfs.md](optimized_plan_udfs.md)).
  - A job manager resolves a source's credentials under the run's identity. How it does that is that
    design's question (M7); this design only keeps the plan free of them.
- **Credentials never travel in SQL.** `CREATE SECRET`, `DROP SECRET`, `SET s3_*` and the other DuckDB
  credential settings are refused by name (decision 7's statement table). SQL text is what people log,
  share and paste into issues.
- **One exception, written by the user.** A URL's query string is part of the address. A presigned
  `https://` URL carries its signature there, so the plan carries it too. Messages, logs and
  `komira_plan_render`'s text print a URL without its query string, fragment or user information
  (decision 8).

### 2. Storage scopes in Python

```python
import komira

s = komira.Session(storage=[
    komira.S3(region="eu-west-1"),                                   # every s3:// URL: the AWS chain
    komira.S3("s3://public-datasets/", anonymous=True, region="us-east-1"),
    komira.S3("s3://lake/", key_id=my_key_id, secret=my_secret),     # explicit keys for one bucket
    komira.GCS(credentials_file="/path/to/service-account.json"),
    komira.Azure("az://raw/", account="myaccount", sas=my_sas),
])
s.sql("SELECT count(*) FROM 's3://lake/events/a.parquet'")
```

**PROPOSED** public names: `S3`, `GCS`, `Azure`, `HTTPS`, and a new keyword `storage=` on `Session`.

| class | arguments (all keyword-only after `prefix`) | with no credential argument |
|---|---|---|
| `S3(prefix="s3://", *, region=None, endpoint=None, url_style=None, profile=None, key_id=None, secret=None, session_token=None, anonymous=False, ca_file=None)` | `url_style` is `"vhost"` or `"path"`; `profile` names a profile of the shared files | the AWS chain (decision 3), with this scope's region, endpoint and profile |
| `GCS(prefix="gs://", *, credentials_file=None, token=None, anonymous=False, endpoint=None, ca_file=None)` | `credentials_file` is a file of the kind `GOOGLE_APPLICATION_CREDENTIALS` names; `token` is an OAuth access token | Application Default Credentials (decision 3) |
| `Azure(prefix="az://", *, account, key=None, sas=None, anonymous=False, endpoint=None)` | `account` is required; exactly one of `key`, `sas`, `anonymous` | refused: `ValueError` names the three choices (decision 3) |
| `HTTPS(prefix="https://", *, ca_file=None)` | trust roots for one site | the platform's trust store |

Rules each class holds when it is constructed, so they raise `TypeError` or `ValueError` before the
library is called, as decision 9 of the package design requires:

- `prefix` must start with the class's scheme (an alias is normalised: `s3a://` to `s3://`, `gcs://` to
  `gs://`, and `abfs://`, `abfss://` or the Blob host to `az://`). It must be the bare scheme or end
  with `/`. Without the `/` rule, `"s3://bucket"` would also match `s3://bucket-two/`.
- Credentials are all or none: `key_id` with `secret`; `session_token` only with both. `anonymous`
  excludes every credential argument and `profile`. In `GCS`, `credentials_file` and `token` exclude
  each other.
- `endpoint` must start with `https://` or `http://`. An `http://` endpoint is accepted here, and only
  here. The user wrote it into a scope on purpose, which is how an emulator is reached; a URL in a
  query can never select plaintext (decision 6).
- Two scopes with the same class and the same normalised prefix raise `ValueError`. Order in the list
  does not matter.

Matching and defaults:

- **The longest matching prefix wins**, compared on the normalised URL. This is DuckDB's rule for
  scoped secrets. An Azure URL is matched on account, container and path.
- **A URL no scope matches** uses its scheme's default: the chain for `s3://` and `gs://`, platform
  trust for `https://`, and a `CredentialsError` for Azure (decision 8). So `komira.sql(...)` on the
  default session reads `s3://` with the same credentials the AWS CLI would use. Explicit credentials
  need a `Session`.
- **Scopes are fixed for the session's life.** They are passed to the library before its engine is
  built, and a scan that registered with one set must not later read with another. Short-lived explicit
  tokens are renewed by making a new session. Credentials the chain returns are refreshed by the chain.
  Python never calls back into the library to fetch a token. The library never calls into the host
  either, the same rule progress follows ([libkomira_run_abi.md §10](libkomira_run_abi.md#10-new-relative-to-the-earlier-abi)).

What a scope object will not do, so a secret does not leak through Python:

- `repr()` shows the class, the prefix and the non-secret settings. Each credential argument shows only
  as `<set>`. `key_id` counts as a credential here, so nothing in a scope's `repr` identifies an
  account.
- A scope object refuses `pickle` and `copy` with `TypeError`. A pickled scope would write its secret
  wherever the pickle goes. It defines no `__eq__` or `__hash__`.
- A secret is a Python `str` until it is passed to the library. The package cannot wipe interpreter
  memory and does not claim to.

`register_parquet(name, url)` and every place a path is accepted take these URLs. Today that means
`read_parquet('…')` and `FROM '…'` in SQL, `register_parquet`, and later the DataFrame readers.

### 3. The provider chains, and the only environment komira reads

- **The library runs the chains, and the Python package reads no environment.** `ProcessEnv` and
  `ProcessFiles` feed `aws_core`'s and `gcp_core`'s chains inside `libkomira`. This is rule S2's
  allowance for provider-standard credentials (`AWS_*`, `GOOGLE_*`).
  - The package design's "No public name of the package is configured by an environment variable"
    still holds, because the chain is not a name of the package.
  - The variables are the providers' own. komira adds no `KOMIRA_*` variable.
  - The trust store that libcrypto reads by default (`SSL_CERT_FILE`, `SSL_CERT_DIR`) is the
    platform's, as for every program linked with it. komira's own setting for trust is `ca_file`.
- **What the chains read is how the providers find credentials, never where data goes.** The whole
  set, as the chains' code reads it today:
  - AWS: the credential variables (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
    `AWS_SESSION_TOKEN`), web identity (`AWS_WEB_IDENTITY_TOKEN_FILE`, `AWS_ROLE_ARN`,
    `AWS_ROLE_SESSION_NAME`), the profile and its files (`AWS_PROFILE`, `AWS_CONFIG_FILE`,
    `AWS_SHARED_CREDENTIALS_FILE`), the container credential service (`AWS_CONTAINER_CREDENTIALS_*`,
    `AWS_CONTAINER_AUTHORIZATION_TOKEN*`), and the region (`AWS_REGION`, `AWS_DEFAULT_REGION`), because
    the region is part of resolving and signing.
  - Google: `GOOGLE_APPLICATION_CREDENTIALS`, and the locations Google's own libraries define for
    finding credentials: `CLOUDSDK_CONFIG` (gcloud's directory) and `GCE_METADATA_HOST` (the metadata
    server).
  - Both read `HOME` (and `APPDATA` on Windows) only to find the well-known files under it.

  The names outside `AWS_*` and `GOOGLE_*` are read under the same allowance. Rule S2 allows
  "provider-standard credentials", and these are the providers' standard way to locate credentials;
  a chain that ignored them would answer differently from the providers' own tools on the same
  machine. They select where credentials come from, never what komira does with data.
  - komira does not call `aws_core`'s endpoint settings reader, so `AWS_ENDPOINT_URL`,
    `AWS_ENDPOINT_URL_S3`, `AWS_USE_FIPS_ENDPOINT` and `AWS_USE_DUALSTACK_ENDPOINT` are not read. A
    data endpoint changes where data goes, not who is asking: that is configuration (rule S2), and it
    comes from a scope's `endpoint`.
- **The chain runs lazily, on the first use of a URL that needs it**: the first registration, read or
  write that touches the scope. It never runs when the session is made.
  - A user who reads only local files never reaches a metadata service.
  - A scope with explicit credentials or `anonymous=True` never runs the chain at all.
- **What the chain answers is held by the session for that scope**, and refreshed by the chain's own
  cache before it expires. A failed resolution is not held, so the next use tries again. This matches
  the ABI's rule that a session's state changes only when a call succeeds.
- **The region is never guessed.** An S3 scope's region comes from `region=`, else from the chain
  (`AWS_REGION`, `AWS_DEFAULT_REGION`, the selected profile's `region`; `aws_core` reads no region from
  the instance metadata service, and adding that is `aws_core`'s change). If none of these gives one,
  the read is refused with `STORAGE_REGION_UNKNOWN`, naming those settings. Defaulting to one region would turn a
  missing setting into a redirect error from the wrong region.
- **Azure has no chain.** S2 names no Azure variables, and `azure_core` reads none. Adding one is a
  later, additive decision (an Azure CLI or managed-identity chain).
- **Configured but broken is an error, never a fall-through.** This keeps `aws_core`'s rule: a named
  profile that does not exist, or a `GOOGLE_APPLICATION_CREDENTIALS` file that cannot be read, is
  `CREDENTIALS_INVALID`, naming the setting. komira does not quietly continue as someone else.

### 4. The C ABI: storage scopes and structured errors

**PROPOSED** rows. They are additive, in the first minor after 1.2 that lands them, in the golden's
spelling ([src/so/abi/komira.tsv](../../src/so/abi/komira.tsv)):

```text
komira_storage_add	Int32	Handle,Int32,CStr,UnsafePointer[Int32]	1.x
komira_storage_set	Int32	Handle,Int32,Int32,ConstBytes,UInt64	1.x
komira_last_error_code	Int32	Handle,UnsafePointer[UInt8],UInt64,UnsafePointer[UInt64]	1.x
komira_last_error_step	Int32	Handle	1.x
```

```c
int32_t komira_storage_add(komira_handle ctx, int32_t kind, const char *prefix, int32_t *scope_out);
int32_t komira_storage_set(komira_handle ctx, int32_t scope, int32_t field,
                           const uint8_t *value, uint64_t value_len);
int32_t komira_last_error_code(komira_handle ctx, uint8_t *buf, uint64_t cap, uint64_t *needed);
int32_t komira_last_error_step(komira_handle ctx);
```

- **Kinds and fields are `constant` rows.** Kinds: `KOMIRA_STORAGE_S3` 1, `_GCS` 2, `_AZURE` 3, `_HTTPS` 4.
  Fields:

  | constant | value |
  |---|---|
  | `KOMIRA_FIELD_REGION` | 1 |
  | `KOMIRA_FIELD_ENDPOINT` | 2 |
  | `KOMIRA_FIELD_URL_STYLE` | 3 |
  | `KOMIRA_FIELD_PROFILE` | 4 |
  | `KOMIRA_FIELD_KEY_ID` | 5 |
  | `KOMIRA_FIELD_SECRET` | 6 |
  | `KOMIRA_FIELD_SESSION_TOKEN` | 7 |
  | `KOMIRA_FIELD_ANONYMOUS` | 8 (empty value) |
  | `KOMIRA_FIELD_CA_FILE` | 9 |
  | `KOMIRA_FIELD_CREDENTIALS_FILE` | 10 |
  | `KOMIRA_FIELD_TOKEN` | 11 |
  | `KOMIRA_FIELD_ACCOUNT` | 12 |
  | `KOMIRA_FIELD_ACCOUNT_KEY` | 13 |
  | `KOMIRA_FIELD_SAS` | 14 |

  - A new setting is a new constant row, which raises the minor.
  - A binding that sets a field this library does not know gets -3 `STORAGE_SCOPE_INVALID` naming the
    field's number.
  - Python sets only the fields a scope has.
- **Values are bytes with a length.** A secret is never required to be NUL-terminated. The library copies
  it into the session's secret store before the call returns, keeps a handle, and never echoes the
  value. The caller may free or overwrite its buffer as soon as the call returns.
- **Order.** Scopes are accepted until the session's engine is built, the same rule as the session-option
  setters ([§7](libkomira_run_abi.md#7-the-session-behind-the-run-calls)).
  - The engine is built by the first registration or run, and a later call is -3
    `STORAGE_AFTER_ENGINE_BUILT`.
  - The Python `Session` sends every scope right after `komira_ctx_new`, so it never sees that code.
  - A scope that is incomplete or contradictory, checked when the engine is built, is -3
    `STORAGE_SCOPE_INVALID`. An example is a key id with no secret. The message names the field,
    never the value.
- **Errors in two calls, not in the text.** `komira_last_error_code` returns the code of the last error:
  the engine's named code (`STORAGE_ACCESS_DENIED`, `STATEMENT_NOT_A_QUERY`), or the empty string when
  the refusal has none. It uses the two-call protocol of `komira_last_error`. `komira_last_error_step`
  returns `KOMIRA_STEP_NONE` 0, `_PARSE` 1, `_BIND` 2, `_OPTIMIZE` 3, `_LOWER` 4 or `_EXECUTE` 5,
  declared as `constant` rows like the kinds and fields.
  - A failure in a registration call (`komira_register_parquet` reading a remote footer, for example)
    reports `_BIND`: registration binds a name to a source.
  - The library reads the code from the engine's `CODE: reason` message convention in one place, and a
    test holds that. The ABI design's rule still holds: bindings never parse the text.
  - The Python `KomiraError`'s `code` and `step` come from these two calls.
  - A binding loaded against a library without them sets both to `None`, in line with the ABI's rule
    for a missing symbol ([§11](libkomira_run_abi.md#11-versioning-and-bindings)).
- **The ABI 1.1 conventions hold for all four calls.**
  - A NULL `ctx` returns -1. A NULL `prefix` or `scope_out`, or a NULL `value` with a non-zero length,
    returns -2.
  - `komira_storage_add` and `komira_storage_set` clear the last error when they start. The two error
    getters do not clear it, as `komira_last_error` does not.
  - `*scope_out` is written only on `KOMIRA_OK`.
  - `komira_last_error_step` returns `KOMIRA_STEP_NONE` for a NULL `ctx` and when no error is held.
- **Rejected shapes**, with reasons, are in [Options considered](#options-considered).

### 5. In the engine

These are what the engine pull requests build. They are listed so the ABI and Python pull requests can
rely on them.

- `EngineOptions` gains the session's scope list (kinds, prefixes, non-secret settings, secret handles).
  The secret values live in a process-local `SecretStore` the session owns. They reach a store client
  through `SecretCapability.open_connection_for`, which keeps the reveal inside one call and wipes it.
- When lowering binds a scan whose `FsDescriptorPod` is not local, it picks the scope by decision 2's
  rule. It then builds the scheme's file system (`S3Fs`, `GcsFs`, `AzureFs`, or the `https://` reader of
  decision 6) with that scope's settings and a credential source: static, anonymous, or the chain over
  `ProcessEnv`.
  - Every remote scan in one query that resolves to the same scope shares one credential source.
  - `LOWERING_SCAN_NOT_TOTAL` stops naming non-local file systems once a scheme's arm lands.
- **A file read in one query is read at one version.** Each object's first read records its version: an
  S3 or HTTP `ETag`, or a GCS generation. Later ranged reads of that object in the same query are
  conditional on it. A change mid-query is refused with `STORAGE_OBJECT_CHANGED`. The other choice
  would be mixing row groups from two versions of a file. An `https://` server that sends no validator
  is read unconditionally, and the docs say so.

### 6. `https://` reads

- **PROPOSED** `FS_SCHEME_HTTPS` (4) is a new scheme code. Additive: rule B8, a new enum value. The
  matrix row `scan_https` comes with it, because every scheme code must be named by a capability.
  `source_url` maps every `https://` URL whose host is not the Blob service's to it; the Azure row is
  unchanged.
- **Read-only, one file per URL.** The file's size comes from `HEAD`, and its bytes come from ranged
  `GET`s. Behaviour at the edges:
  - A server that ignores `Range` is refused with `STORAGE_RANGE_NOT_SUPPORTED`. komira does not fall
    back to downloading the whole file into memory.
  - Globs and Hive partitioning over `https://` are refused (`STORAGE_URL_REFUSED`), because HTTP has
    no listing.
  - Redirects are followed within `https://` only, up to the client's limit. Authorization-type
    headers are dropped on a cross-origin hop.
- **Plaintext `http://` URLs are refused** (`STORAGE_URL_REFUSED`). DuckDB reads them. komira refuses,
  by name, because a URL in a query must not be able to turn off transport security.
  - The one route to plaintext is an object-store scope's `endpoint=` (decision 2).
  - Tests of `https://` reads use a loopback TLS server with a test certificate authority given as
    `HTTPS(ca_file=...)`.
- **No proxy.** `http_client` has no `CONNECT` support, and komira reads no `HTTPS_PROXY`. A later
  `proxy=` argument would be additive. No authentication beyond what the URL carries (a presigned URL);
  a bearer-token field would be a later, additive constant.

### 7. Writes

**One spelling per door.** SQL writes with `COPY`. The DataFrame surfaces write with their write
terminals. There is no third way, such as a `Result.write_parquet` or a `Session.copy`.

| door | spelling | goes through | returns |
|---|---|---|---|
| SQL | `COPY <table> TO '<dest>' (<options>)`, `COPY (<query>) TO '<dest>' (<options>)` | `komira_sql_stream`: `STATEMENT_NOT_A_QUERY` is lifted for `COPY ... TO` only | a `Result` of one row, one column `Count` (BIGINT): the rows written, as DuckDB answers |
| pandas-shaped | `to_parquet`, `to_csv`, `to_json(orient="records", lines=True)` ([dataframe_surface_verbs.md](dataframe_surface_verbs.md)) | `komira_plan_stream` with `write_target` set: `PLAN_WIRE_WRITE_TARGET_DROPPED` is lifted | `None`, as pandas returns, after the write is complete |
| polars-shaped | `sink_parquet`, `sink_csv`, `sink_ndjson` | the same | `None`, as polars returns |

- **Both doors return the same stream.** A run with a write target answers the one-row `Count` stream.
  The write terminals read it and return `None`.
- **Options.** `FORMAT`, `COMPRESSION`, `COMPRESSION_LEVEL`, `HEADER true` and `ARRAY false` are
  accepted, as the parser accepts them today.
  - The (format, codec) pairs are `write_target_supported`'s 13.
  - Every other DuckDB `COPY` option is refused by name, with the code `COPY_OPTION_UNSUPPORTED` added
    to the parser's existing message. That includes `PARTITION_BY`, `OVERWRITE`,
    `OVERWRITE_OR_IGNORE`, `APPEND`, `FILE_SIZE_BYTES`, `PER_THREAD_OUTPUT`, `USE_TMP_FILE`,
    `RETURN_FILES`, `DELIMITER`, `HEADER false` and `ARRAY true`. Each later becomes an additive
    optional field of `WireWriteTarget` under rule B8.
  - This design gives each Python write terminal one keyword, `compression=`, a codec word of the
    pair table (the default as for `COPY`). A keyword the terminal has but cannot honour raises
    `UnsupportedOperation` at the call, by the DataFrame design's refusal policy
    ([dataframe_surface.md §6](dataframe_surface.md#6-how-a-skin-refuses)); a keyword it does not
    have is Python's `TypeError`.
- **The format and codec follow DuckDB, or the write is refused.**
  - With no `FORMAT`, the format comes from the extension after one compression suffix is removed:
    `.parquet` is Parquet; `.csv` is CSV; `.json`, `.jsonl` and `.ndjson` are JSON.
  - Any other extension is refused with `COPY_FORMAT_NOT_INFERRED`, which asks for `FORMAT`.
    DuckDB would write CSV there. komira refuses by name rather than guess.
  - With no `COMPRESSION`, CSV and JSON take gzip from `.gz` and zstd from `.zst`, else none. Parquet
    takes snappy.
  - This replaces the parser's default of Parquet ([What exists today](#what-exists-today)).
- **A write is all or nothing.** The pull request that serves local writes holds "failure leaves no
  partial file".
  - A local destination is written to a temporary file in the destination's directory. The file name is
    a dot, the destination's name and a random suffix, so nothing reads it as data.
  - The temporary file is flushed and synced, then renamed over the destination. A failure removes it.
  - A crash can leave the temporary file behind. It never leaves a partial file at the destination.
  - `s3://` is a multipart upload, completed only after the last part and aborted on failure. A small
    result is one `PutObject` at the end.
  - The rename also makes `COPY (SELECT * FROM 'a.parquet') TO 'a.parquet'` safe.
- **An existing destination is replaced**, as DuckDB replaces it. A missing parent directory is not
  created (`STORAGE_NOT_FOUND`).
- **An empty result writes a valid empty file**: Parquet with the schema, CSV with only its header,
  JSON with no lines. `Count` is 0.
- **Paths.** SQL takes the destination as written. A relative path resolves against the process's
  working directory when the statement runs. The Python terminals resolve a local path when called,
  the way `register_parquet` does, so the plan carries an absolute path. URLs are verbatim.
- **Remote destinations.** `s3://` is written once the S3 write arm lands, with the session's scopes.
  `gs://`, `az://` and `https://` destinations are refused with `STORAGE_WRITE_UNSUPPORTED`: the GCS
  and Azure file systems do not write today, and HTTP has no write.
- **Tables.** Iceberg and Delta writes are their own designs ([storage_stack.md](storage_stack.md)), not
  `COPY`.

Statements that stay refused at `bind` with `STATEMENT_NOT_A_QUERY`, each message naming the statement
and what to write instead:

| statement | why |
|---|---|
| `CREATE TABLE ... AS`, `INSERT`, `CREATE VIEW` | no session table store. CTAS has no wire arm by design ([plan.proto](../../src/plan_proto/plan.proto)) |
| `COPY ... FROM`, `EXPORT DATABASE`, `IMPORT DATABASE` | not served. Reading a file is `read_parquet` or `FROM '…'` |
| `CREATE SECRET`, `DROP SECRET`, `SET s3_*` and the other credential settings | credentials are session scopes, never SQL (decision 1) |
| `INSTALL`, `LOAD` (`httpfs` among them) | remote reads are built in. The message says to remove the statement |

### 8. Error shapes

Every refusal on these paths has a named code, from the library's `komira_last_error_code` (decision
4). The Python class for each is fixed here. These rows join the error-mapping pull request's table
([python_package.md decision 9](python_package.md#9-errors)); that pull request owns the rest of the
table.

**PROPOSED** public names: `CredentialsError(KomiraError)` and `StorageError(KomiraError)`.

| code | when | step | Python class |
|---|---|---|---|
| `CREDENTIALS_NOT_FOUND` | the chain found no configured step; an Azure URL with no scope | `bind` or `execute` | `CredentialsError` |
| `CREDENTIALS_INVALID` | a configured step is broken: a missing profile, an unreadable or malformed credentials file, an `external_account` file, a token the provider rejects at exchange | `bind` or `execute` | `CredentialsError` |
| `STORAGE_REGION_UNKNOWN` | no region for an S3 scope (decision 3) | `bind` | `CredentialsError` |
| `STORAGE_NOT_FOUND` | the object or the destination's directory does not exist | `bind` or `execute` | `StorageError` |
| `STORAGE_ACCESS_DENIED` | the store refused the credentials it was given (401, 403), or the server's certificate failed verification, which the store layer classes with these | `bind` or `execute` | `StorageError` |
| `STORAGE_THROTTLED` | still throttled after the retry policy's attempts | `execute` | `StorageError` |
| `STORAGE_TRANSPORT` | connect failure, connection reset, timeout, or end of stream mid-response | `bind` or `execute` | `StorageError` |
| `STORAGE_MALFORMED` | the store answered something komira could not read | `bind` or `execute` | `StorageError` |
| `STORAGE_OBJECT_CHANGED` | the object changed during the query (decision 5) | `execute` | `StorageError` |
| `STORAGE_IO` | a local write failed for another reason: no space, read-only file system, a directory at the path. The message names the `errno` | `execute` | `StorageError` |
| `STORAGE_URL_REFUSED` | a prefix komira does not read: `http://`, an unknown scheme, a glob over `https://`, and in the first release every remote URL | `bind` (where the binder or the registration resolves the path) | `UnsupportedOperation` |
| `STORAGE_RANGE_NOT_SUPPORTED` | an `https://` server ignored `Range` | `execute` | `UnsupportedOperation` |
| `STORAGE_WRITE_UNSUPPORTED` | a `gs://`, `az://` or `https://` destination | `bind` | `UnsupportedOperation` |
| `COPY_OPTION_UNSUPPORTED`, `COPY_FORMAT_NOT_INFERRED`, `STATEMENT_NOT_A_QUERY` | decision 7 | `parse` or `bind` | `UnsupportedOperation` |
| `STORAGE_SCOPE_INVALID`, `STORAGE_AFTER_ENGINE_BUILT` | decision 4. Python's own checks come first, so a Python user meets these only through a defect | none | `KomiraError` |

- The six `STORAGE_*` codes from `NOT_FOUND` to `OBJECT_CHANGED` are the store layer's six
  `StoreError` kinds, one to one. `PRECONDITION` is named for what it means on a read. Nothing new is
  classified; the engine only renames the existing classes for users.
- **The message grammar**, after the ABI's `<step>: ` prefix:
  `<CODE>: <operation> <url> [status=<http status>] [provider_code=<code>] [credentials=<source>]`.
  For example:
  `execute: STORAGE_ACCESS_DENIED: GetObject s3://lake/events/a.parquet status=403 provider_code=AccessDenied credentials=environment`.
  - `<source>` is the label of where the credentials came from: `explicit`, `anonymous`,
    `environment`, `web-identity`, `profile`, `container`, `instance-metadata`, `credentials-file`,
    `gcloud`, `metadata-server` or `token`. It is the answer to "who did komira think I was".
- **What a message never contains**: a secret, a session token, an access token, a SAS, an account
  key, a key id, a signature, a URL's query string, fragment or user information, a response body,
  or the value of an environment variable. A message names a setting (`AWS_PROFILE`,
  `GOOGLE_APPLICATION_CREDENTIALS`, `secret=`), never what it was set to.
- The Python message is the library's text unchanged ([python_package.md decision 9](python_package.md#9-errors)).
  The no-leak rules are therefore the library's, and the library's tests hold them.

### 9. What lands when

| milestone | what |
|---|---|
| first release (local only) | `COPY ... TO` a local file, Parquet first, through `komira_sql_stream`: the `Count` result, the all-or-nothing write, extension inference and `COPY_FORMAT_NOT_INFERRED`. `komira_last_error_code` and `komira_last_error_step`, with the error-mapping pull request. Every remote URL refused with `STORAGE_URL_REFUSED`, replacing today's `LOWERING_SCAN_NOT_TOTAL` (raised later, at `lower`) and the footer reader's "not a readable flat Parquet file" at registration |
| object stores | the storage ABI calls; `Session(storage=...)` and the four classes; the S3 read arm with the chain; `https://` reads; the S3 write arm; GCS and Azure reads; `CredentialsError` and `StorageError` |
| DataFrame surface | the write terminals, through the plan door, when it serves `write_target` |

The surface additions are additive under the package design's rules: a new keyword with a default, new
names in `__all__`, and new ABI rows and constants. A binding of an older minor runs everything it
ran before.

## What is decided elsewhere

| question | where |
|---|---|
| the ABI's run calls, status codes, last error and session-option setters | [libkomira_run_abi.md](libkomira_run_abi.md) |
| `Session`, `Result`, `KomiraError`'s fields and the rest of the error-mapping table | [python_package.md](python_package.md) |
| the write terminals' names and keyword refusals | [dataframe_surface.md](dataframe_surface.md), [dataframe_surface_verbs.md](dataframe_surface_verbs.md) |
| how a job manager resolves a source's credentials under a run's identity | the job manager's design (later) |
| catalogs, `read_table`, Iceberg and Delta writes | [storage_stack.md](storage_stack.md), [optimized_plan_sources.md](optimized_plan_sources.md) |

## What must always hold?

- No credential, endpoint or trust setting from a storage scope is in a plan's bytes, in SQL komira
  produces, or in `komira_plan_render`'s output. The one credential a plan may carry is the one the
  user wrote into a URL (decision 1), and `komira_plan_render` prints that URL without its query
  string.
- No secret or key id appears in `komira_last_error`, `komira_last_error_code`, a `repr`, an exception
  or a log line.
- komira reads no environment variable of its own. The variables it reads are the AWS and Google
  chains' (decision 3 lists them), inside the library, only when a URL needs them, and libcrypto's
  default trust-store variables.
- A URL in a query never selects plaintext transport.
- A write is complete at its destination or absent from it.
- A COPY option or a write keyword is honoured or refused by name, never ignored.

## How is it tested?

This document lands without code. Each pull request that builds part of it tests that part, in its own
language: Mojo tests for the library and engine, `python_binding_test` targets for the package. Every
test is hermetic: the chains read `MapEnv` and `MapFiles`, stores are the in-memory fakes or loopback
servers on port 0, and nothing reaches a cloud. The cases below are the ones a reviewer should find.
The list names a case for every row of decision 8's table, and for every rule of decisions 2, 3, 5, 6
and 7 that changes an answer or a refusal.

- **Scopes.** These raise before the library is called:
  - each invalid combination of decision 2: a key id without a secret, a token without keys,
    `anonymous` with a key, both `key` and `sas`, an Azure scope with neither;
  - a prefix without a trailing `/`;
  - a duplicate prefix.

  Matching and safety:
  - the longest prefix wins over a shorter one and over the scheme default;
  - `s3://bucket/` does not match `s3://bucket-two/`;
  - `repr` shows `<set>` and no value;
  - `pickle.dumps` of a scope raises `TypeError`.
- **Chains.** One case for each step answering. One case for a configured-but-broken step refusing
  with `CREDENTIALS_INVALID`, without falling through. Nothing configured gives
  `CREDENTIALS_NOT_FOUND`. No region gives `STORAGE_REGION_UNKNOWN`. Also:
  - an explicit scope never reads the environment: the test's `MapEnv` records no read;
  - `AWS_ENDPOINT_URL` is not read;
  - local-only use never runs the chain.
- **No leak.** Each `CREDENTIALS_*` and `STORAGE_*` message is asserted by exact equality, with a known
  secret, session token and key id in the scope. A presigned URL's query string is absent from the
  message. `komira_plan_render` of a plan read through an explicit scope contains no credential bytes.
- **ABI.**
  - `komira_storage_set` with an unknown field or a field of another kind gives `STORAGE_SCOPE_INVALID`.
  - A scope added after the engine is built gives `STORAGE_AFTER_ENGINE_BUILT`.
  - A secret buffer overwritten right after the call does not change what is read.
  - `komira_last_error_code` and `_step` after: a parse error, a bind refusal, an execute failure, a
    refusal without a code, and a successful call (empty and `NONE`).
- **Reads.**
  - A fake S3, GCS and Azure, and a loopback TLS server for `https://`, answer what the same file
    answers locally.
  - 403 maps to `STORAGE_ACCESS_DENIED`, 404 to `STORAGE_NOT_FOUND`, and throttling past the retries
    to `STORAGE_THROTTLED`.
  - An object rewritten between two ranged reads gives `STORAGE_OBJECT_CHANGED`.
  - A server that ignores `Range` gives `STORAGE_RANGE_NOT_SUPPORTED`.
  - `http://` and a glob over `https://` give `STORAGE_URL_REFUSED`.
  - A refused connection, a server certificate from an untrusted authority, and a response cut short
    give `STORAGE_TRANSPORT`, `STORAGE_ACCESS_DENIED` and `STORAGE_TRANSPORT`.
  - A store reply komira cannot read gives `STORAGE_MALFORMED`.
  - An `https://` file's size comes from `HEAD`; a server that sends no validator is read without a
    condition; a cross-origin redirect drops the `Authorization` header (the loopback server records
    the headers it was sent).
  - An `https://` server certificate from the scope's `ca_file` authority is trusted, and the same
    certificate without that scope is refused.
- **Writes.**
  - Each of the 13 pairs is read back by pyarrow and DuckDB and equals the query's answer, and `Count`
    equals its rows.
  - Inference covers `.csv`, `.json`, `.csv.gz` and `.json.zst`; `.txt` gives `COPY_FORMAT_NOT_INFERRED`.
  - Each refused option gives `COPY_OPTION_UNSUPPORTED`.
  - An empty result writes a readable empty file.
  - Failure is injected through the test's file-system seam, not by timing. A failure mid-write leaves
    no destination file and no temporary file, and an existing destination unchanged.
  - Writing over the file being read gives the new answer.
  - A missing parent directory gives `STORAGE_NOT_FOUND`.
  - An S3 write that fails aborts its multipart upload.
  - `gs://`, `az://` and `https://` destinations give `STORAGE_WRITE_UNSUPPORTED`.
  - A full disk (injected through the seam) and a directory at the destination give `STORAGE_IO`,
    each message naming its `errno`.
  - Each statement of decision 7's table gives `STATEMENT_NOT_A_QUERY`.

## What are the limits and open questions?

- **The GCP metadata probe.** `gcp_core`'s probe has a timeout, but its TCP connect is not bounded
  ([src/gcp_core](../../src/gcp_core/README.md)). Off Google Cloud, with nothing else configured, the
  first `gs://` read can wait for the operating system's connect timeout before it raises
  `CREDENTIALS_NOT_FOUND`. Bounding the connect is `gcp_core`'s fix. Until then the docs name it.
- **`~` in SQL paths.** Whether DuckDB expands `~` in a `COPY` destination or a `read_parquet` path is
  checked by the write pull request against DuckDB. komira does what DuckDB does, or refuses by name.
- **Secrets in Python memory.** A secret passed as a `str` stays in the interpreter until it is
  collected. Only the library's copy is wiped.
- **Workload identity federation on Google Cloud** (`external_account` files) is refused, as
  `gcp_core` refuses it. `gcp_wif` could serve it, and that is a later, additive change.
- **Azure chains** and **HTTP proxies** are later, additive decisions (decisions 3 and 6).
- **Node and TypeScript.** The ABI calls are the same for the Node addon. Its spelling of scopes is the
  TypeScript SDK's design.

## Options considered

- **One protobuf message per scope, through one call.** Additive by field numbers, and the plan door
  already takes protobuf. Rejected:
  - the Node addon is C and would need a protobuf encoder for one message;
  - the first Python release has no protobuf dependency;
  - enumerated field constants are just as additive and are plain C.
- **A typed setter per field** (`komira_storage_set_region`, ...). This is the session options'
  precedent. Rejected because a store setting is not a session option: fourteen fields across four
  kinds would be fourteen rows, most of them valid for one kind only. The field constants keep one
  typed key space, checked against the kind in one place.
- **A struct** (layout becomes ABI) and **free-text key and value pairs** (a typo is found at run time):
  rejected, for the ABI design's reasons.
- **Storage options per read call**, as fsspec's `storage_options` does. Rejected: credentials would
  travel with each reader's arguments and so with the plan, and the same URL could be read as two
  identities in one query.
- **Credentials in SQL** (`CREATE SECRET`), as DuckDB does. Rejected: SQL text is logged and shared, and
  a plan built from it would carry the secret.
- **Resolving the chain in Python** (with boto3 or google-auth). Rejected:
  - it adds dependencies;
  - expiring credentials would need a callback into Python, or a session per expiry;
  - the chains already exist in the library, with hermetic tests.
- **A default region** (DuckDB uses one). Rejected: a guessed region turns a missing setting into a
  redirect error from the wrong place.
- **Plaintext `http://` URLs.** Rejected for URLs; allowed only as a scope's endpoint (decision 6).
- **`COPY` returning no rows, or returning the rows written.** Rejected: DuckDB answers one `Count` row,
  and returning the data would make a write's memory depend on its size.

## Where is the code?

Not built. The parts it builds on: [src/aws_core](../../src/aws_core/README.md),
[src/gcp_core](../../src/gcp_core/README.md), [src/objectstore_s3](../../src/objectstore_s3/README.md),
[src/objectstore_gcs](../../src/objectstore_gcs/README.md), [src/azure_blob](../../src/azure_blob/README.md),
[src/http_client](../../src/http_client/README.md), [src/source_url](../../src/source_url/README.md),
[src/sdk_exec](../../src/sdk_exec/README.md) (`secret_capability.mojo`, `engine_sql.mojo`),
[src/sql/sql_parser.mojo](../../src/sql/sql_parser.mojo), [src/arrow/write_target.mojo](../../src/arrow/write_target.mojo),
[src/so](../../src/so/README.md).
