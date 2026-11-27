# Reading a CSV or Parquet file from an `https://` URL

Status: design, not built. **EXISTS** names code on `main`; **PROPOSED** is new. Statements the author
deduced rather than read are marked *(inferred)*. One question is the owner's to decide, and it is
marked **OWNER**.

This document expands decision 9 of [credentials_and_writes.md](credentials_and_writes.md)
("`https://` reads") into a design that can be built in slices. Decision 9 stays the summary; where
this document says more, it adds to decision 9 and does not change it, with two exceptions: the one
**OWNER** question below, and one refinement. Decision 9 takes a file's size from `HEAD`. Here a
Parquet scan takes it from the `Content-Range` of its footer read, and `HEAD` serves only
`file_size` (decision 2 of this design).

In this document, "decision 9" alone is the credentials design's. This design's own decisions are
written "decision N of this design", or named by their number inside a section of this design's
[decisions](#the-decisions).

## What a user types

Once the slices below land:

```python
import komira

with komira.Session() as s:
    # A Parquet file on a web server: its footer and the column chunks the query needs are fetched
    # with ranged GETs, never the whole file.
    s.register_parquet("trips", "https://data.example.com/trips/2026-10.parquet")
    print(s.sql("SELECT count(*) AS n FROM trips").to_arrow().to_pylist())

    # A CSV file: fetched whole, then read as a local CSV file is read.
    s.register_csv("zones", "https://data.example.com/zones.csv")

    # The same, as a bound source.
    s.add_sql_binding("fares", komira.files("https://data.example.com/fares.parquet"))

    # In the SQL text, as DuckDB writes it (a later slice).
    s.sql("SELECT * FROM 'https://data.example.com/trips/2026-10.parquet' LIMIT 5")
```

- Every `https://` read is anonymous: komira sends no credential to a web server. A query string in
  the URL is refused in the first slices (decision 6 of this design).
- A server whose certificate is signed by an authority that is not public is trusted through
  `komira.Session(ca_file="internal-roots.pem")`. Verification is always on.
- `http://` is refused, unless the owner accepts the loopback exception in the next section.

## Question for the owner

| question | DuckDB | this design | recommendation |
|---|---|---|---|
| **OWNER**: plaintext `http://` URLs | reads every `http://` URL | refuses every `http://` URL (`STORAGE_URL_REFUSED`), except when the host is a loopback address literal: `127.0.0.0/8` or `[::1]` | accept the loopback exception. Bytes sent to a loopback address never leave the machine, so plaintext there turns off no transport security, which is the reason decision 9 refuses `http://`. It also lets the rank 95 example and the Python tests run on a plain `http.server` with no certificate. `localhost` is not in the exception, because the resolver decides where it goes |

If the owner refuses the exception, decision 9 stands as written (every `http://` URL refused), and
two things change: rank 95's example takes option B or C of
[the documentation example](#7-the-documentation-example-rank-95), and the Python tests use only the
loopback TLS server of decision 4. Nothing else in this design changes.

Invariant 3 of [What must always hold?](#what-must-always-hold) is the loopback form of the
credentials design's "A URL in a query never selects plaintext transport". The slice that builds the
exception (slice 8) changes that sentence of `credentials_and_writes.md` and its owner-question row in
the same pull request (rule P10).

## What exists today

Checked against `main`:

- **No file system serves a web server's URL.**
  - `source_url`'s `source_scheme_for_url` (`src/source_url/source_url.mojo`) maps an `https://` URL
    to `FS_SCHEME_AZURE` when its host ends in `.blob.core.windows.net`. It refuses every other
    `https://` host with `source_url: no source serves https:// URLs on host '<host>' ...`. It
    refuses every `http://` URL with `source_url: an http:// URL names no source by its prefix; a
    plaintext endpoint is the surface's configuration`.
  - The scheme codes are `FS_SCHEME_FILE` (0), `FS_SCHEME_S3` (1), `FS_SCHEME_GCS` (2) and
    `FS_SCHEME_AZURE` (3) (`src/plan_expr/fs_descriptor_pod.mojo`). `FsDescriptorPod` holds
    `scheme`, `bucket` and `node_id`.
  - The same four codes bound four other places: the physical-plan codec
    (`_check_fs_scheme` in `src/pplan_wire/pplan_wire_codec.mojo` checks `s <= FS_SCHEME_AZURE`),
    lowering (`_carried_fs` in `src/lowering/cut_scan.mojo`), `check_source_scheme`, and the
    run's file system: `StoreFs` in `src/so/store_fs.mojo` holds one `S3Fs` or one `AzureFs`, and
    `StoreScanFs.open_scan_fs` refuses every other scheme with `SCAN_FS_UNSERVED`.
  - `komira_add_sql_binding` (`src/so/bindings.mojo`) refuses an `https://` location with
    `STORAGE_URL_REFUSED: add_sql_binding name=<n>: no store of this library reads 'https://'
    locations; s3:// and az:// (abfs://, abfss://) are read`.
- **CSV reads only local files.**
  - `CsvSourceSpec` (`src/physical_plan/csv_source_spec.mojo`) carries a local `path` and no file
    system. The run reads it with `read_text_source_to_heap_buffer(path)`, a whole-file mmap
    (`src/pipeline_exec/source_csv.mojo`).
  - Schema inference at bind (`csv_tvf_schema` in `src/sql/sql_tvf_bind.mojo`) also mmaps the file.
    It samples a 256 KiB prefix of an uncompressed file (`_SCHEMA_SAMPLE_PREFIX_BYTES` in
    `src/csv/reader.mojo`) and decompresses a compressed file whole.
  - Only the Parquet arm reads through a `FileSystem`, so CSV is not read from S3 or Azure either.
- **Python resolves every path as local.** `_local_path` (`python/komira/_session.py`) is
  `os.path.abspath(os.path.expanduser(path))`. `register_parquet`, `register_csv`,
  `register_json` and the DataFrame readers call it, so `https://data.example.com/x.parquet` becomes
  `<cwd>/https:/data.example.com/x.parquet`. `komira_register_parquet` takes a local path.
- **The building blocks exist.**
  - `http_client` (`src/http_client`): HTTP/1.1 and HTTP/2 over TLS, per-host connection pools (by
    default at most 32 connections per host), `HttpClient.get_range`, which raises `HttpError[RANGE_NOT_HONORED]` on
    any status but 206, a redirect policy (`redirect_policy.mojo`, at most five hops, plaintext
    targets refused) and the opt-in `RedirectLayer`, which strips `Authorization` and the other
    credential headers on a cross-origin hop and refuses an `https` to `http` downgrade, the
    `HttpError` kinds, and `TlsConfig.add_trust_pem`.
  - `objectstore`: `plan_coalesce` (`src/objectstore/coalesce.mojo`), `CoalescePolicy`
    (`src/objectstore/types.mojo`; default gap 1 MiB, request 8 MiB, concurrency 8) and the six
    `StoreError` kinds.
  - `objectstore_s3`: `S3Fs`, the model this design follows. It pins the first answer's `ETag` and
    sends `If-Match` on every later ranged read, and it parses and checks `Content-Range`
    (`s3_parse_content_range`, `s3_check_partial` in `src/objectstore_s3/ranges.mojo`).
  - `http_core`'s committed test authority and leaf certificate
    (`src/http_core/tests/fixtures/tls/`, the leaf names `localhost` and `127.0.0.1`), and the
    loopback serve loop of `//src/tests/e2e/komira_http_tls_e2e:komira_http_tls_e2e`
    (`serve_while`, `DispatchServeLoop`, `TlsServeLoop`).
- **What `http_client` does not have.** It has no `Content-Range` parser of its own. `RetryLayer`
  plans its backoff delays but does not sleep between attempts. It has no proxy (`CONNECT`) support.

## The decisions

### 1. What is copied from DuckDB, and what is refused by name

The reference is DuckDB's `httpfs` extension, as its documentation describes it
([HTTP(S) support](https://duckdb.org/docs/stable/core_extensions/httpfs/https),
[httpfs overview](https://duckdb.org/docs/stable/core_extensions/httpfs/overview) and
[the configuration reference](https://duckdb.org/docs/stable/configuration/overview)).

Rows marked *(inferred)* are not stated on those pages; the slice that builds each row checks it
against DuckDB's source or behaviour.

Copied:

| DuckDB | komira |
|---|---|
| `SELECT * FROM 'https://data.example.com/file.parquet'`, `read_parquet('https://...')`, `read_csv('https://...')` | the same SQL (slice 7) |
| read-only access | read-only: `HttpFs`'s write verbs raise, and an `https://` destination is `STORAGE_WRITE_UNSUPPORTED` (decision 10 of the credentials design) |
| Parquet: the footer and the needed column chunks through range requests, so `count(*)` reads only metadata | the same (decision 2) |
| CSV: "usually downloaded in full" | downloaded in full, then decoded as a local file is (decision 5) |
| compression of a CSV file from its extension (`.gz`, `.zst`; DuckDB's CSV page, for local paths) | the same, through the local reader's extension rule (`.gz`, `.zst`, `.lz4`) |
| a list of URLs: `read_parquet(['https://a.example.com/x.parquet', 'https://b.example.com/y.parquet'])` | the same, in the SQL slice |
| redirects followed *(inferred: the pages do not describe redirects)* | followed, at most five hops, never to plaintext (decision 2) |
| `http_retries` 3, `http_retry_wait_ms` 100, `http_retry_backoff` 4 (the configuration reference) | the same numbers, fixed (decision 9 of this design) |
| `http_timeout` 30 s (the configuration reference) | 30 s to a response's head (decision 9 of this design) |
| `ca_cert_file` (the configuration reference) | `Session(ca_file=...)`, which adds roots to the system's (decision 4) |

Refused by name, or not offered:

| DuckDB | komira | why |
|---|---|---|
| credentials in the URL (`https://user:pw@data.example.com/`) | `STORAGE_URL_REFUSED` at bind, as for every location today | a credential is never part of a location (decision 3 of the credentials design) |
| a glob over `https://`, and Hive partitioning over it | `STORAGE_URL_REFUSED`; a list of URLs is the way to read several | HTTP has no listing. The httpfs overview names globbing only for the S3 API |
| writing to `https://` | `STORAGE_WRITE_UNSUPPORTED` | HTTP has no standard write |
| `http_proxy`, `http_proxy_username`, `http_proxy_password`, and reading `HTTP_PROXY` from the environment | not offered; komira reads no proxy variable | `http_client` has no `CONNECT`, and rule S2 keeps configuration out of the environment. A later `Session(proxy=...)` is additive |
| a server that ignores `Range`: a download of the whole file *(inferred: the pages do not say what DuckDB does)* | `STORAGE_RANGE_NOT_SUPPORTED` for Parquet | a whole-file download for a ranged reader holds a file of any size in memory. CSV is downloaded whole anyway, so a CSV read works on such a server |
| `force_download` | not offered | the same reason |
| `enable_server_cert_verification` (the configuration reference), the `VERIFY_SSL` secret parameter (the HTTP(S) page) | not offered: verification is always on | a query must not be able to turn off transport security; `ca_file` covers a private authority |
| `CREATE SECRET (TYPE http, BEARER_TOKEN ...)`, `EXTRA_HTTP_HEADERS` (the HTTP(S) page) | `CREATE SECRET` is refused with `SQL_STATEMENT_UNSUPPORTED` once decision 10 of the credentials design lands (it is not parsed today); no `https://` credential kind | credentials are bound from the SDK, never in SQL. A header credential for files is a later, additive credential kind |
| `enable_http_metadata_cache`, off by default (the configuration reference) | no footer cache across statements for `https://` (decision 2) | a web server gives no cheap way to learn that a file changed |
| `http_keep_alive`, `custom_user_agent` (the configuration reference) | not offered; connections are pooled and kept alive | B20: no setting without a user who needs it |
| plaintext `http://` | refused, with the **OWNER** loopback exception | the question at the top |

### 2. The file system: `HttpFs`

**PROPOSED.** A new package `http_fs` (`src/http_fs`) holds `HttpFs`, a read-only `FileSystem`
(`src/fs/file_system.mojo`) over one origin (scheme, host and port), and `HttpScanFs`, its
`ScanFsOpener`. It depends on `fs`, `http_client`, `objectstore` (for `plan_coalesce` and the
`StoreError` kinds) and `retry`, and on no plan package, as `azure_blob` does. `AzureFs` is the model
for a read-only conformer, and `S3Fs` for ranges and pinning.

What each verb does:

| verb | requests | notes |
|---|---|---|
| `open(path)` | none | returns a handle holding the path and the query |
| `read_footer(path, window)` | one `GET` with `Range: bytes=-<window>` | the 206's `Content-Range` total is the file's size and its `ETag` or `Last-Modified` is the file's validator, so a Parquet scan needs no `HEAD` |
| `file_size(path)` | one `HEAD` | `Content-Length` is the size. A `HEAD` answered 405 or 501, or with no `Content-Length`, is followed by one `GET` with `Range: bytes=0-0`, and the size is the `Content-Range` total |
| `read_at(file, offset, length)` | `GET` with `Range: bytes=<first>-<last>` | split into requests of at most 8 MiB |
| `read_ranges_prefetched(file, ranges)` | `plan_coalesce` with `CoalescePolicy.default()`, then at most 8 requests in flight | each response is written into its slices of the joined buffer, as `S3Store.fetch_span_into` does |
| `supports_random_read()` | none | `True`: a server that ignores `Range` is refused, not adapted to |
| `list`, `is_dir`, `list_dir_shallow` | none | refused: HTTP has no listing. The binder refuses a glob before any of these is called |
| write verbs | none | raise, as `AzureFs`'s do |

`IS_MMAP_BACKED`, `SUPPORTS_LAZY_HIVE` and `SUPPORTS_PARALLEL_WRITES` are `False`. `SCHEME` is the
literal 4, because `fs` cannot import `plan_expr`. `test_source_scheme_agrees` holds it equal to
`FS_SCHEME_HTTPS`, as it does for the other file systems.

**Every request.**
- Each request sends `Accept-Encoding: identity`. A response with any other `Content-Encoding` is
  `STORAGE_MALFORMED`, because ranges of encoded bytes are not ranges of the file.
- Each request sends no `Authorization`, no cookie and no credential header. komira holds no
  credential for a web server.
- The body limit of each response is set to the exact byte count asked for
  (`RecvRingBody.set_max_body_bytes`). A longer body is refused as it arrives, and is never buffered.

**A ranged answer is checked before its body is used.**
- 206: `Content-Range` must be present and must name exactly the bytes asked for, and its total
  must equal the file's size. The body length must equal the range. This is `s3_check_partial`'s
  rule. A mismatch is `STORAGE_MALFORMED`.
- 200 to a ranged request: accepted only when the range asked for is the whole file, as when a
  footer window covers a small file, and `Content-Length` equals the size. Any other 200 is
  `STORAGE_RANGE_NOT_SUPPORTED`. The connection is closed without reading the body.
- 416: `STORAGE_MALFORMED`, because the reader asks only for bytes inside the size the server gave.
- A `Content-Range` total of `*` (length unknown) on the footer read is `STORAGE_MALFORMED`: a ranged
  reader cannot find the end of a file of unknown length.

**A file that changes during a scan.** The first answer for a path pins its validator for the run:
- A strong `ETag`: every later request carries `If-Match: <etag>`.
- A weak `ETag` (`W/"..."`), which `If-Match` cannot compare, or no `ETag` but a `Last-Modified`:
  every later request carries `If-Unmodified-Since: <Last-Modified>`.
- On every later 206, the `Content-Range` total must equal the pinned size, and the `ETag`, when
  the server sends one, must equal the pinned one.
- 412, or a size or `ETag` that differs, is `STORAGE_OBJECT_CHANGED`. The message names the URL
  without its query, and says to run the statement again.
- With neither `ETag` nor `Last-Modified`, only the size is compared. A file rewritten in place to
  the same size during one statement cannot be detected. This is a stated limit.
- `If-Range` is not used. A server answers a failed `If-Range` with 200 and the whole file, which is
  the download this design refuses.

The pin is held by the `HttpFs`, keyed by path and query, not by the file handle. The Parquet reader
opens a new handle for each read (`src/parquet/file_reader.mojo`), so a pin held by the handle, as
`S3Fs` holds it, would not cover a scan. One `HttpFs` serves one run, so the pin lives as long as
the statement.

**No footer cache across statements.** Today no Parquet footer outlives a run: the run builds a new
`ParquetMetadataCache` (`src/sdk_exec/engine_execute.mojo`), and that cache serves a footer of a file
system that is not mmap-backed without checking it again (`src/parquet/runtime_footer_cache.mojo`).
This design depends on that. Each statement's first read of an `https://` file is its footer `GET`,
which also yields the validator, and `HttpFs` is never wired to a footer cache that outlives a run.
The cost is one round trip per file per statement, which DuckDB also pays when
`enable_http_metadata_cache` is off, its default *(inferred from the setting's description)*. A later
slice can key a longer-lived cache on the validator, with a conditional `GET` (`If-None-Match`) to
revalidate it.

**Redirects.**
- 301, 302, 303, 307 and 308 are followed, at most five hops (`MAX_REDIRECT_HOPS`). A sixth is
  `STORAGE_MALFORMED` naming the hop count.
- A target is held to the same rule as a location: `https://` on any host, and with the **OWNER**
  exception, `http://` on a loopback literal. An `https://` to `http://` hop is refused
  (`STORAGE_URL_REFUSED`, at step `execute`, or `bind` when the bind reads the footer), as
  `RedirectLayer` refuses it today.
- The `Range`, `If-Match` and `If-Unmodified-Since` headers go to every hop. No credential header is
  ever sent, so the cross-origin stripping has nothing to strip, and it stays on as a backstop.
- The target is remembered for the path for the rest of the run, so later ranges skip the hops. A
  401, 403, 404 or 410 from a remembered target is retried once from the original URL, because
  some redirect targets are signed URLs that expire. A second failure is the error.
- A redirect to another origin is fetched through the same client, whose pools are per host. The
  run's `HttpScanFs` entry stays keyed by the original origin.

**The new scheme code, and every place it is added.** `FS_SCHEME_HTTPS` is 4, as decision 9 names it.
Its `FsDescriptorPod.bucket` is the origin, lowercased, with the port only when it is not the
scheme's default: `https://data.example.com`, or `https://127.0.0.1:8443`. The transport is
therefore written in the plan, and a plan cannot select plaintext by any other field. With the
**OWNER** exception, a loopback `http://` origin uses the same code. The path and the query stay in
the scan's path, as an S3 key does.

| place | today | the change |
|---|---|---|
| `src/plan_expr/fs_descriptor_pod.mojo` | codes 0 to 3; `url_prefix` has four arms | `FS_SCHEME_HTTPS = 4`; its `url_prefix` arm returns `bucket` |
| `src/source_url/source_url.mojo` | refuses `https://` on a host that is not Azure Blob's, and every `http://` | `source_scheme_for_url` returns code 4 for those `https://` hosts, keeping the Blob host as `FS_SCHEME_AZURE`. `check_source_scheme` accepts 4. A refusal still names only the scheme or host |
| `src/pplan_wire/pplan_wire_codec.mojo` | `_check_fs_scheme`: `s <= FS_SCHEME_AZURE` | `s <= FS_SCHEME_HTTPS`; the header comment updated |
| `src/lowering/cut_scan.mojo` | `_carried_fs` carries local, S3, GCS and Azure, and refuses the rest with `LOWERING_SCAN_NOT_TOTAL` | carries code 4 |
| `src/so/store_fs.mojo` | `StoreFs` holds `S3Fs` or `AzureFs`; `StoreScanFs` has `add_s3` and `add_azure` | a third arm `of_http` holding an `HttpFs`, a third `StoreFile` variant, `StoreScanFs.add_http(origin)`, and `serves` and `open_scan_fs` arms for code 4. `StoreConnectors` gains the https connector, built with the session's added roots (decision 4) |
| `src/so/bindings.mojo` | the scheme switch refuses `https://` | an `https` arm; the credential rule of decision 6 of this design |
| `src/plan_wire/plan_wire_codec.mojo` (the OptimizedPlan codec) | `_cloud_scheme_of` refuses an `s3://`, `gs://`, `gcs://`, `az://`, `abfs://` or `abfss://` path that a local descriptor carries | learns `https://` and `http://`. Without this, an `https://` path with a local descriptor would encode as `fs_is_local = true` *(inferred from the prefix list)*. Carrying a remote scan in the OptimizedPlan is decision 4 of the credentials design, not this design |
| `src/fs/file_system.mojo` | the `SCHEME` comment lists 0 to 3 | lists 4 |
| `tests/surface_capability_matrix.bzl`, `docs/surface_capability_matrix.md` | rows `scan_s3`, `scan_gs`, `scan_az` | row `scan_https`. A new `FS_SCHEME_*` constant fails the matrix lint until its row exists |

**The wire rule for code 4.** The physical-plan codec's format is a version number and a code per
descriptor. Adding code 4 adds a value: bytes written before the change mean what they meant, and
`PPLAN_WIRE_FORMAT_VERSION` stays 2.
- An older decoder reading code 4 refuses the plan by name, with `PPLAN_WIRE_BAD_ENUM: fs scheme 4`.
  It never reads an `https://` scan as another file system.
- `test_pplan_wire_hostile_bytes.mojo` holds that refusal on `main` today, with 4 as its first
  unknown code. It is the test of the previous release on new data. Slice 2 moves its first unknown
  code to 5, and its pull request says which assertion moved.
- A new golden fixture of an `https://` descriptor is added beside the S3 one in
  `test_pplan_wire_golden_bytes.mojo`. The existing goldens, which decode unchanged, are the test of
  the new release on old data.
- Running the previous release's binary in a test would need a network fetch, which rule T12
  refuses, so the two tests above stand in for it.
- The codec has no reader outside `src/pplan_wire` *(inferred from a search of imports)*, so the
  format is internal. Rule B8 still applies, and slice 2 names both tests.

### 3. Plaintext `http://`

DuckDB reads `http://`. Decision 9 refuses it, because a URL written in a query should not be able to
turn off transport security, and plaintext reaches a store only through a source's `endpoint=`. This
design keeps that refusal for every host but a loopback address literal, and asks the owner for that
one exception (the question at the top).

- **What counts as loopback.** An IPv4 literal in `127.0.0.0/8`, or `[::1]`. Checked on the
  literal, with no resolver. `localhost` and every name are refused, because a hosts file or a
  resolver can point a name off the machine.
- **Where it is checked.** In `source_url`, the one place that maps a URL to a code, and again in
  `HttpFs` on every redirect target, so a loopback server cannot redirect a read to a plaintext
  host.
- **The refusal text.** `STORAGE_URL_REFUSED`. The message says `http://` is read only on a loopback
  address, and names `https://`. It names the host and never the path or the query.

### 4. Testing without a real service, and the trust roots

**Mojo tests** run a server and `HttpFs` in one process, on `127.0.0.1` port 0, with
`komira_http_tls_e2e`'s `serve_while`: the server on one thread of a `fork_join` pair, the client on
the other. The server's dispatcher serves files from memory and can be told to misbehave:
- ignore `Range`;
- change a file between two requests;
- omit or weaken the `ETag`;
- send a redirect chain;
- close a connection mid-body;
- answer 403, 404, 412, 416, 429 or 503;
- send a `Content-Encoding`.

No socket test asserts time (rule T10). Retries go through `retry`'s `Sleeper` seam with
`RecordingSleeper`, so a test asserts the delays planned, not the time taken.

**The certificate.** `HttpFs` takes its connector factory as a constructor argument, as `S3Fs` and
`StoreConnectors` do.
- A test builds a connector that trusts `src/http_core/tests/fixtures/tls/root_ca.pem`, as
  `komira_http_tls_e2e`'s `client_tls_connector` does: `wipe_trust`, then `add_trust_pem`.
- The server presents the committed leaf, which names `127.0.0.1`.
- A negative case trusts the other committed authority (`smoke_cert.pem`) and must fail with
  `STORAGE_ACCESS_DENIED`.

No environment variable is read, and nothing is generated at test time.

**The trust roots in production.** Today every TLS connector of the object stores uses the system's
roots (`build_unpinned_public_ca_tls_connector`: s2n's default store, from the operating system's
usual locations). This design adds one setting, the one decision 9 names:
- `komira.Session(ca_file=None)` (**PROPOSED**; `caFile` in TypeScript). It takes a path to a PEM
  file of one or more authorities.
- Python reads the file and passes its bytes to a new ABI call, `komira_ctx_add_trust_pem(ctx, pem,
  pem_len)`.
- The library checks the PEM by adding it to a scratch `TlsConfig`. A file that does not parse is
  `STORAGE_TRUST_INVALID` (a new code, class `StorageError`). Its message names the setting
  `ca_file`, not the file's text.
- The roots are **added** to the system's (`add_trust_pem` without `wipe_trust`), as decision 9 says.
  Replacing the system's roots is not offered, because no user asks for it today (rule B20).
- The roots are session state, not plan state, as decision 4 of the credentials design says. A job
  manager uses its own deployment's trust store.

**Python tests** follow rank 31's model and `python/tests/objectstore_fakes.py`:
- a `ThreadingHTTPServer` on `("127.0.0.1", 0)` that serves files from memory, answers `HEAD`,
  `GET` and `Range`, records each request, and can misbehave on request;
- for `https://`, the same server wrapped by Python's `ssl` module with the committed leaf and key,
  staged into the test as test data. The session is opened with
  `Session(ca_file=<the staged root_ca.pem>)`.

### 5. CSV through a file system

CSV is its own slice (slice 6), and it serves every store, not only `https://`. Today a CSV file on
S3 or Azure is not read either. Rank 31's page says so.

What the CSV source needs:
- **The plan names a file system.** `CsvSourceSpec` gains an `FsDescriptorPod`, and its `path`
  becomes the path within that file system. A spec with the local descriptor reads exactly as today.
  The physical plan's IR version note is raised, as it was for the Parquet arm's descriptor.
  `cut_scan`'s CSV arm carries the descriptor through `_carried_fs`.
- **The run reads the whole file first.**
  - `source_csv` asks the run's opener for the file system, then reads the file into one buffer, and
    decodes it with the existing `read_csv_bytes_to_batch_dynamic`, which takes a `Span[UInt8]`.
  - Locally that is the mmap of today.
  - Remotely it is one `GET` with no `Range`. Its `Content-Length` must equal the size from `HEAD`.
    The body is written into a buffer of that size, so a server that ignores `Range` serves a CSV
    file.
  - A dropped connection restarts the `GET` with `Range: bytes=<received>-` and `If-Match` when
    the server took ranges, or from the start when it did not, up to the retry policy's attempts.
- **The memory bound.**
  - The buffer is charged to the query's memory budget (`memory_limit=`, the segment pool) before
    the first byte is requested.
  - A file larger than what remains of the budget is refused by name, with `CSV_SOURCE_OVER_BUDGET`
    (a new code, step `execute`, class `StorageError`). The message names the URL, the size and the
    budget, before any body byte is fetched.
  - A compressed file is decompressed with the existing cap-and-grow decoder
    (`_decompress_text_bytes` in `src/parquet_codec/text_decompress.mojo`, which takes a span and the
    path for its extension). The output is charged to the same budget.
- **Compression** is chosen from the URL's path extension (`.gz`, `.zst`, `.lz4`), with the query
  string removed first. That is the local rule, and DuckDB's.
- **Schema inference at bind reads a bounded prefix.**
  - For an uncompressed file, one ranged `GET` of the first 256 KiB (`_SCHEMA_SAMPLE_PREFIX_BYTES`).
    The sampler snaps it to the last newline, as it does locally. A server that ignores `Range`
    answers 200, and the reader stops after 256 KiB and closes the connection.
  - For a compressed file, the bind reads the whole file, as it does locally today, under the same
    budget. A bounded streaming decode of a prefix is a later slice.
- **The source's identity.** `CsvSource` folds the file's mtime into its identity. A remote file has
  no mtime, so it folds the validator instead: the `ETag`, or else `Last-Modified` and the size.
- **Later, not in the first CSV slice.** Ranged and parallel reads of a large uncompressed CSV file
  (the parallel reader exists, `src/csv/parallel_reader.mojo`, but needs one whole span). Streaming
  CSV, which the local reader does not do either.

### 6. Python and SQL surfaces, and how errors name a URL

**Python**, PROPOSED:
- `komira.files("https://...")` binds with `add_sql_binding`, like an `s3://` source.
  - The default credential `komira.AMBIENT` means no credential for `https://`, because no provider
    chain serves a plain web server. `komira.ANONYMOUS` is the same.
  - Any named credential is `CREDENTIAL_KIND_MISMATCH`.
  - `endpoint=`, `region=` and `url_style=` are refused with `ValueError`, as for a local path.
  - A location ending in `/` is `BIND_SCOPE_NOT_A_TABLE`, and a glob is `STORAGE_URL_REFUSED`.
  - The library reads the footer at bind, as for S3, so a missing file or a refused certificate
    raises at `add_sql_binding`.
- `register_parquet(name, url)` and `register_csv(name, url, ...)` take a URL.
  - `_local_path` keeps a string that starts with a scheme (a letter, then letters, digits, `+`,
    `-` or `.`, then `://`: the pattern `komira.files` already uses) as written.
    `_write.destination` keeps any string that contains `://`, a looser test this slice does not
    copy.
  - A URL is bound as `add_sql_binding(name, komira.files(url, credential=komira.ANONYMOUS))`, which
    decision 13 of the credentials design already plans for `register_parquet`.
  - For CSV, `komira.files` needs the format and the CSV options. `WireFileSource` gains an
    optional `format` (unset is Parquet, as every source today is read) and optional CSV options
    (delimiter, header, `all_varchar`). This is additive under rule B8.
- `komira.read_parquet(url)` and `komira.read_csv(url)`, the DataFrame readers, need the plan's
  scan to carry a source's access. That is decision 4 of the credentials design, tracked by
  komira-ai/komira#2337 for every store. They are not in these slices. Until then they refuse a URL by
  name, with `STORAGE_URL_REFUSED`, instead of mangling it into a local path. That refusal is part
  of slice 5.

**SQL**, PROPOSED (slice 7): `FROM 'https://...'`, `read_parquet('https://...')`,
`read_parquet([...])` and `read_csv('https://...')`.
- Decision 3 of the credentials design binds a URL literal through the scope whose location is its
  longest prefix. Every session starts with an `https://` scope bound to `komira.ANONYMOUS`.
- For `https://`, the scope gives no credential and no settings, so this slice need not wait for
  scopes of the other stores. The binder recognises an `https://` literal and binds it as an
  anonymous `https://` file source.
- The guards that refuse a non-local descriptor in the SQL path (`src/sql/sql_bind_parquet.mojo`,
  `src/sdk_exec/engine_lower.mojo`) learn code 4.

**A query string**, as in a presigned URL. Decision 4 of the credentials design keeps a presigned
query in the process, prints only its digest in `komira_plan_render`, and refuses it on export
(`PLAN_URL_QUERY_REFUSED`). None of that is built. So the first slices keep today's bind rule for
every location: a query or a fragment is `STORAGE_URL_REFUSED`. Presigned `https://` URLs are a
later slice.

**Error messages.** The credentials design's grammar holds:
`<CODE>: <operation> <url> [status=<http status>]`, after the ABI's `<step>: ` prefix.
- `<url>` is `scheme://host[:port]/path`: never user information (refused at bind anyway), never a
  query, never a fragment. This is `source_url`'s rule, and `RedirectLayer`'s `_url_redacted`.
- A redirect names the URL the user wrote and, after `via=`, the redacted origin of the hop that
  failed.
- No message holds a response body or a header value.

For example:

```text
execute: STORAGE_NOT_FOUND: GET https://data.example.com/trips/2026-10.parquet status=404
execute: STORAGE_RANGE_NOT_SUPPORTED: GET https://data.example.com/trips/2026-10.parquet status=200 (the server ignored Range)
execute: STORAGE_OBJECT_CHANGED: GET https://data.example.com/trips/2026-10.parquet status=412 (the file changed during the statement; run it again)
bind: STORAGE_ACCESS_DENIED: GET https://data.example.com/trips/2026-10.parquet (the server's certificate failed verification)
```

How each failure maps, with the `HttpError` kinds and the `StoreError` kinds:

| what happened | code |
|---|---|
| 404, 410 | `STORAGE_NOT_FOUND` |
| 401, 403, or `HTTP_ERROR_TLS_VERIFY_FAILED` | `STORAGE_ACCESS_DENIED` |
| 429 or 503 after the retries | `STORAGE_THROTTLED` |
| a refused connection, a reset, a timeout, or `HTTP_ERROR_EOF_MID_RESPONSE` after the retries; other 5xx after the retries | `STORAGE_TRANSPORT` |
| 412, or a size or `ETag` that changed | `STORAGE_OBJECT_CHANGED` |
| a 200 to a ranged request that is not the whole file | `STORAGE_RANGE_NOT_SUPPORTED` |
| 416, a bad or missing `Content-Range`, a body longer than asked, a `Content-Encoding`, more than five redirects | `STORAGE_MALFORMED` |
| `http://` (outside the **OWNER** exception), a glob, user information, a query, a downgrading redirect | `STORAGE_URL_REFUSED` |

The two new codes, and the new case of an existing one, as rows of the credentials design's error
table (its decision 11). The slice that builds each adds its row there:

| code | when | step | Python class |
|---|---|---|---|
| `STORAGE_TRUST_INVALID` | `ca_file` names a file that is not one or more PEM certificates | `bind` (the session call that adds the roots) | `StorageError` |
| `CSV_SOURCE_OVER_BUDGET` | a remote CSV file, or its decompressed text, does not fit in what remains of the memory budget | `execute`, or `bind` for the schema read of a compressed file | `StorageError` |
| `STORAGE_URL_REFUSED` | also a redirect to a plaintext target | `execute`, or `bind` when the bind reads the footer | `UnsupportedOperation` |

### 7. The documentation example (rank 95)

The task framework ([docs/tasks/README.md](../tasks/README.md)) runs each `example.py` with no
network, and rank 31's example already serves its files from a loopback server in the program. Rank
95 does the same. No second framework is added.

- **Option A** (recommended; needs the **OWNER** yes). `example.py` makes a small Parquet file and a
  small CSV file in memory. It serves them from a `ThreadingHTTPServer` on `("127.0.0.1", 0)` that
  answers `HEAD`, `GET` and `Range` as rank 31's stand-in does, with `http://127.0.0.1:<port>` as
  the base URL. It reads both with `register_parquet` and `register_csv`, and prints sorted rows.
  - The page says, in its prose and in a comment in the program, that a real server is read the
    same way with its `https://` URL. The program uses `http://` only because the stand-in runs on
    the loopback address.
  - Every line runs in the check. Nothing is `not-tested`.
- **Option B** (if the owner refuses). The same program over `https://`. The test authority's
  certificate and a leaf key for `127.0.0.1` are held as text in `example.py`, written to files in
  the directory it runs in, and passed with `ca_file=`. It runs in the check, but the page shows
  about sixty lines of PEM text that teach the reader nothing.
- **Option C** (if the owner refuses B too). `example.py` runs option A's flow through
  `register_parquet` on a local file. The page shows the `https://` form in a fence marked
  `<!-- not-tested: reading a real https:// server needs the network, which the example runs
  without -->`, and says so in its prose. This needs the owner's yes, because the page's main
  answer would not run.

**The catalogue.** Rank 95 (`read-csv-parquet-file-url`) is a `gap` with komira-ai/komira#2345.
Slice 9 adds its directory.
- If slice 6 (CSV) has landed, rank 95 becomes `works`.
- If not, it becomes `partial`. The page reads Parquet, and its last line shows the CSV refusal by
  name. A probe `probe_csv.py` holds that refusal's line, so the day CSV is read the probe goes red,
  and the page and catalogue change with it.

### 8. Memory, connections and failure

Bounded by construction; no queue grows with the input.
- **Per request.** A ranged body is at most 8 MiB: `HttpFs` splits a longer range, and
  `plan_coalesce` never merges past 8 MiB. Its bytes go straight into the destination buffer that
  the Parquet reader asked for, through the connection's 64 KiB receive ring, with no copy of the
  whole body. A body longer than asked is refused as it arrives.
- **Per call.** `read_ranges_prefetched` has at most 8 requests in flight
  (`CoalescePolicy.max_concurrency`). Its memory is the bytes the Parquet reader asked for, plus
  the gaps that coalescing reads, at most 1 MiB per merge. This is the same bound `S3Fs` has.
- **Per process.** Connections per host are capped by the pool (32), and a checkout over the cap
  waits for a connection to come back. That wait is bounded by the 8 requests in flight per call.
- **CSV.** One buffer of the file's size (and its decompressed size), charged to the memory budget
  before the first byte, or refused by name (decision 5).
- **Uplink.** Only request heads are sent: no request has a body. Bytes downloaded are those of the
  ranges the reader asked for and the coalescing gaps, never a whole Parquet file.
- **A dropped connection.** `GET` and `HEAD` are idempotent, so a connect failure, a reset, an end
  of stream mid-body or a timeout is retried. The whole range is asked for again, with the pinned
  validator, so a retry can never join two versions of a file. After the attempts, it fails with
  `STORAGE_TRANSPORT`, naming the URL.

### 9. Retries and time limits

- **Attempts.** Four in all: the first and three retries, as DuckDB's `http_retries` 3 reads
  *(inferred from the setting's description, "HTTP retries on I/O error")*.
- **Backoff.** 100 ms, then four times longer each attempt, with jitter. A `Retry-After` header is
  honoured up to 10 s; a longer one fails the read at once with `STORAGE_THROTTLED`.
- **What is retried.** Transport failures; 429, 500, 502, 503 and 504. Nothing else.
- **The seam.** The delays go through `retry`'s `Sleeper`, `MonotonicClock` and `RetryRng` seams,
  not `http_client`'s `RetryLayer`, because that layer plans its delays without sleeping.
- **Time limits.** The 30 s head budget, the 120 s body deadline and the 30 s idle limit are new
  choices of this design, not existing defaults.
  - 30 s from sending a request to its response head (DuckDB's `http_timeout`), through the
    request budget.
  - The TLS handshake keeps `http_client`'s own 30 s deadline.
  - A ranged body, at most 8 MiB, must finish within 120 s, through the body's deadline.
  - A CSV body has no fixed total deadline, because its size is not bounded. Instead it fails when
    no byte arrives for 30 s *(inferred: `RecvRingBody` has a whole-body deadline but no idle timer
    today. Slice 6 adds the idle timer to `http_client`, or, if that is a larger change, reads a
    large CSV file in 8 MiB ranges instead)*.
- **No settings.** The numbers are fixed. A setting is added only when a user needs one (rule B20).

## What must always hold?

1. komira never writes to an `http://` or `https://` URL.
2. No credential, cookie or `Authorization` header is sent to a web server, and no message, log line
   or rendered plan holds a URL's query string, fragment or user information.
3. A URL never selects plaintext transport to a host other than a loopback address literal, by itself
   or through a redirect. Without the **OWNER** exception, it never selects plaintext at all.
4. Certificate verification is always on. `ca_file` adds authorities; nothing removes verification.
5. A Parquet read never holds a whole file in memory. A CSV read holds one file, charged to the
   memory budget first.
6. A statement reads one version of each file, or fails with `STORAGE_OBJECT_CHANGED`. The only
   exception is a file with neither `ETag` nor `Last-Modified` that is rewritten in place to the
   same size during one statement, which is a stated limit.
7. Every refusal and failure has a named code from the credentials design's table, or one of the two
   new codes here (`STORAGE_TRUST_INVALID`, `CSV_SOURCE_OVER_BUDGET`).
8. Nothing reads the environment, and every test runs on `127.0.0.1` with port 0.

## How is it tested?

Each slice names its tests by behaviour (below). Together they cover these failure and boundary
cases. The list is complete for this design because it has one case per row of decision 6's mapping
table, one per check of decision 2's ranged-answer and pinning rules, and one per bound of decision
8:
- a server that ignores `Range`, and one that answers 200 to a range covering the whole file;
- a 206 naming other bytes, a body longer than asked, and a 206 without `Content-Range`;
- a file changed between the footer and a column chunk: with a strong `ETag`, with a weak one, with
  only `Last-Modified`, and with neither;
- 404, 403, 412, 416, 429 then 200, 503 past the retries, and a `Retry-After` over 10 s;
- a reset mid-body, then success;
- a redirect chain of five hops, and one of six; an `https` to `http` hop; an expired remembered
  target;
- an untrusted certificate, and the same server trusted through the authority;
- a `HEAD` answered 405;
- a `Content-Encoding: gzip` on a range;
- a file of 0 bytes, a file smaller than the footer window, and a range that crosses 8 MiB;
- `http://` on a loopback literal, on `localhost`, and on another host;
- a glob, user information, a query and a fragment;
- a CSV file larger than the budget, a `.csv.gz` file, and a CSV file from a server that ignores
  `Range`.

## The slices

Each slice is one pull request with `Refs komira-ai/komira#2345`, in this order. Its title is ready
for an issue. Each names its tests by behaviour and its effect on the catalogue.

**1. `http_client`: parse and check a `Content-Range` answer for any server**
- Moves `s3_parse_content_range` and `s3_check_partial` out of `objectstore_s3`'s `ranges.mojo`
  into `http_client`, as `parse_content_range` and `check_partial`. `objectstore_s3` calls them. No
  behaviour changes, so it is a refactor alone (rule P7).
- Tests: the existing `objectstore_s3` range tests, unchanged. `test_content_range_forms` (a range,
  a suffix, an unknown total `*`, and malformed headers each refused by name).
- Catalogue: none.

**2. `FS_SCHEME_HTTPS` and `HttpFs`: run_sql reads a Parquet file from an `https://` server**
- Adds the scheme code in every place of decision 2's table, the package `http_fs` (`HttpFs`,
  `HttpScanFs`), the `StoreFs` and `StoreScanFs` arms, the `scan_https` matrix row, and
  `source_url`'s `https://` mapping. The binding layer stays as it is, so no surface reads
  `https://` yet.
- Mojo tests run a loopback TLS server with the committed authority, through `run_sql_with` and an
  `HttpScanFs` opener:
  - `test_https_parquet_equals_local`: a query over the served file equals the same query over the
    local file.
  - `test_count_reads_only_the_footer`: `count(*)` makes one request.
  - `test_ranges_coalesce_within_the_policy`: the column chunks of a row group arrive in at most 8
    MiB requests, never more than 8 in flight.
  - `test_ignored_range_is_refused`; `test_full_file_200_for_a_whole_file_range_is_read`.
  - `test_changed_file_is_refused` (strong `ETag`, weak `ETag`, `Last-Modified`).
  - `test_size_only_file_change_is_caught_when_the_size_differs`.
  - `test_redirects_followed_to_five_hops`; `test_sixth_hop_is_refused`;
    `test_downgrade_redirect_is_refused`; `test_expired_remembered_target_is_followed_again_once`.
  - `test_untrusted_certificate_is_access_denied`.
  - `test_status_codes_map_to_named_errors` (one row per status of the mapping table of decision 6).
  - `test_reset_mid_body_is_retried_with_the_pin`; `test_retry_after_over_ten_seconds_is_throttled`
    (through `RecordingSleeper`).
  - `test_content_encoding_is_malformed`; `test_head_405_falls_back_to_a_ranged_get`.
  - `test_error_names_no_query`: exact text.
  - `source_url`'s `test_source_scheme` and `test_source_scheme_agrees` gain the code-4 rows.
  - `pplan_wire`'s golden https descriptor, and the hostile case's first unknown code moved to 5.
- Catalogue: none.

**3. libkomira and Python: `Session(ca_file=...)` adds trusted authorities for `https://` reads**
- Adds `komira_ctx_add_trust_pem`, `STORAGE_TRUST_INVALID`, and `Session(ca_file=None)`.
- Tests:
  - `test_ca_file_trusts_a_private_authority`: a loopback TLS server is refused without it and read
    with it.
  - `test_ca_file_that_does_not_parse_is_refused`: exact message, which names `ca_file` and not
    the file's text.
  - `test_ca_file_adds_to_the_system_roots`.
- Catalogue: none.

**4. libkomira and Python: `register_parquet` and `komira.files` read a Parquet file from an `https://` URL**
- The `https` arm of `komira_add_sql_binding` and the credential rule of decision 6 of this design. `_local_path`
  keeps a URL, and `register_parquet` binds it.
- Python tests over the loopback TLS server with `ca_file`:
  - `test_register_parquet_https_equals_local`.
  - `test_files_https_binds_and_queries`.
  - `test_https_named_credential_is_kind_mismatch`.
  - `test_https_glob_query_fragment_userinfo_refused`: exact texts.
  - `test_https_missing_file_raises_at_bind`.
  - `test_no_query_in_errors_or_logs`.
- Catalogue: no status changes. The pages of ranks 15 and 37 name komira-ai/komira#2345 in their
  notes, and rank 31's notes list `https://` as not read; the slice updates those notes.

**5. Python: the DataFrame readers refuse a URL by name instead of reading it as a local path**
- `read_parquet`, `read_csv` and `read_json` raise `STORAGE_URL_REFUSED`, naming
  komira-ai/komira#2337's reader work, for any string with a scheme.
- Test: `test_readers_refuse_urls_by_name`.
- Catalogue: none.

**6. CSV through a file system: `register_csv` and `komira.files` read CSV from `https://`, S3 and Azure**
- Adds the `CsvSourceSpec` descriptor, the run's whole-file read through the opener, the budget
  charge, `CSV_SOURCE_OVER_BUDGET`, the bounded bind sample, `WireFileSource.format` and the CSV
  options, and the validator in `CsvSource`'s identity.
- Tests:
  - `test_csv_over_https_equals_local`; `test_csv_over_s3_equals_local`, through `FakeS3Connector`.
  - `test_csv_gz_over_https_equals_local`.
  - `test_csv_over_budget_is_refused_before_any_byte`.
  - `test_csv_bind_reads_a_bounded_prefix`: one ranged `GET` of 256 KiB.
  - `test_csv_from_a_server_that_ignores_range`.
  - `test_csv_reset_mid_body_resumes_with_if_match`.
  - `test_local_csv_reads_as_before`.
- Catalogue: rank 31's note "CSV on S3 is not yet" changes, and rank 31 can become `works` if its
  page names no other gap.

**7. SQL: `FROM 'https://...'`, `read_parquet` and `read_csv` read a URL written in the query**
- The binder's anonymous `https://` scope, and the SQL guards that learn code 4.
- Tests:
  - `test_sql_https_literal_equals_local`.
  - `test_sql_read_parquet_list_of_urls`.
  - `test_sql_https_glob_refused`.
  - `test_sql_http_refused` (and, with the **OWNER** exception, `test_sql_http_loopback_reads`).
- Catalogue: rank 95's page gains the SQL form.

**8. `http://` on a loopback address literal (only with the owner's yes)**
- `source_url` and `HttpFs` accept it, with the plaintext connector. Updates decision 9 and the
  invariant of `credentials_and_writes.md`.
- Tests:
  - `test_http_loopback_literal_is_read`.
  - `test_http_localhost_and_other_hosts_refused`: exact text.
  - `test_https_redirect_to_http_loopback_refused`.
- Catalogue: none.

**9. Docs: rank 95, how do I read a CSV or Parquet file from a URL**
- Adds `python/docs/tasks/95-read-csv-parquet-file-url/` (`example.py`, `expected_output.txt`,
  `page.md`, and `probe_csv.py` with its error line if slice 6 has not landed) by the option of
  decision 7.
- Test: the target `//python/docs/tasks:95-read-csv-parquet-file-url`.
- Catalogue: rank 95 goes from `gap` to `works` (after slice 6) or `partial` (before it).

Slices 1, 3 and 5 can land at any time, and slice 2 after slice 1. Slice 4 needs slices 2 and 3.
Slices 6, 7 and 8 need slice 2. Slice 9 needs slice 4, and slice 8 for option A.

## Out of scope

- **Writing to a URL.** HTTP has no standard write. `STORAGE_WRITE_UNSUPPORTED`.
- **Globs and directory listings over HTTP.** HTTP has no listing. Scraping an HTML index page is not
  a listing.
- **Credentials for web servers**: bearer tokens, custom headers, basic auth. No user of the
  catalogue needs them yet. A header credential is a later, additive credential kind, sent only to
  the origin it was bound for.
- **Presigned URLs with a query string.** They need the plan render's digest and the export refusal
  of decision 4 of the credentials design. They are a later slice.
- **Proxies.** `http_client` has no `CONNECT`, and an environment-read proxy breaks rule S2.
- **A footer cache across statements**, and a cache of downloaded CSV files.
- **The DataFrame readers.** They wait for komira-ai/komira#2337 (decision 6 of this design).
- **HTTP/3**, which `http_client` does not speak.
- **JSON and other text formats over HTTP.** The CSV slice's file-system read is the pattern, and
  JSON follows it in its own slice.

## Options considered

- **Download the whole file when a server ignores `Range`** (DuckDB's behaviour). Rejected for
  Parquet: memory would grow with the file. A user with such a server downloads the file and reads it
  locally. CSV, which is read whole anyway, works on such a server.
- **`If-Range` instead of `If-Match`.** Rejected: a failed `If-Range` answers 200 with the whole
  file.
- **Pin the validator on the file handle, as `S3Fs` does.** Rejected: the Parquet reader opens a
  handle per read, so the pin would not span a scan.
- **One scheme code per transport (4 for `https`, 5 for loopback `http`).** Rejected: the origin in
  `bucket` already names the transport, and one code is one fewer place to keep in step.
- **Follow every redirect again for every range.** Rejected: it doubles the round trips to a server
  that redirects to a CDN. The remembered target, re-followed once on an authorization or not-found
  answer, covers expiring signed targets.
- **A Python-only download into a temporary file.** Rejected: it would not serve SQL or the other
  SDKs, and it holds the whole file on disk.

## Where is the code?

Nothing of this design is built. The packages it changes are `plan_expr`, `source_url`,
`pplan_wire`, `plan_wire`, `lowering`, `fs`, `so`, `http_client`, `objectstore_s3`, `physical_plan`,
`pipeline_exec`, `csv`, `sql`, `sdk_exec` and the Python package, and it adds `http_fs`.
