# Sources, credentials and writes: one binding model for every SDK

Status: design, not built. **EXISTS** names code on `main`; **PROPOSED** is new. Statements the author
deduced rather than read are marked *(inferred)*.

## What a user types

Every table name a statement reads is bound on the session with `add_sql_binding`, or for one
statement as a keyword of `sql`. URLs and local paths written in the SQL need no name.

A bucket with keys:

```python
import komira

s = komira.Session()
s.add_sql_binding("raw_orders", komira.files(
    "s3://raw-events/orders/*.parquet",
    credential=komira.AwsKeys("raw-etl", key_id=key_id, secret=secret),
    region="eu-west-1",
))
s.sql("SELECT region, sum(amount) FROM raw_orders GROUP BY region")
```

A catalog, which holds many tables. SQL names a table in it as `catalog.namespace.table`:

```python
sales_catalog = komira.iceberg(
    "https://catalog.example.com/api/catalog",
    warehouse="prod",
    credential=komira.OAuth2ClientCredentials("catalog-etl", client_id="etl", client_secret=client_secret),
)
s.add_sql_binding("sales_catalog", sales_catalog)
s.sql("SELECT * FROM sales_catalog.sales.orders LIMIT 10")
```

One table of that catalog, bound under a name of its own, so SQL says just the name:

```python
s.add_sql_binding("orders_table", sales_catalog.table("sales.orders"))
s.sql("SELECT count(*) FROM orders_table")
```

A statement over two bindings, a file source and the catalog:

```python
s.sql("INSERT INTO sales_catalog.sales.orders SELECT * FROM raw_orders")
```

- **`komira.iceberg(...)` is a catalog of many tables.** It is not one table, and not a lake of files.
  `catalog.table("ns.table")` picks one table out of it. The table uses the catalog's credential
  under the same name, `catalog-etl`.
- **For one statement**, a binding is a keyword of `sql`, and it wins over a session binding of the
  same name for that statement. The unnamed-source form, kept pending the question at the top, passes
  one source before the query, read as `self`:

  ```python
  s.sql("SELECT count(*) FROM returns", returns=komira.files("s3://raw-events/returns/*.parquet",
        credential=komira.AwsKeys("returns-etl", key_id=key_id_2, secret=secret_2), region="eu-west-1"))
  s.sql(sales_catalog.table("sales.orders"), "SELECT count(*) FROM self")
  ```

- **The SQL text is DuckDB's.** Only the Python call is komira's: a method on the session binds a
  name, or a keyword of `sql` binds one for one statement.
- **What the plan carries.** A source is an object the user holds, and a credential is an object with
  a name. The plan the library builds carries only the sources the statement uses, each with its
  location and its credential's name (`raw-etl`, `catalog-etl`).
  - It never carries a credential's value.
  - It never carries the session-local names `raw_orders`, `sales_catalog` or `orders_table`.
  - It never carries bindings the statement does not use.
  - The one value it may carry is a presigned URL's query string, which the user wrote into a
    location. A plan that leaves the process refuses that (decision 4).

## Questions for the owner

Each row is a place where komira would answer differently from DuckDB, where rule S2 needs a reading,
or a spelling the owner should confirm.
The rest of the document assumes the recommendation.

| question | DuckDB | this design | recommendation |
|---|---|---|---|
| plaintext `http://` URLs in a query | reads them | refuses them by name (`STORAGE_URL_REFUSED`); plaintext only through a bound source's `endpoint=` | refuse: a URL in a query should not be able to turn off transport security |
| an S3 source with no region from any setting | assumes `us-east-1` | refuses by name (`STORAGE_REGION_UNKNOWN`) | refuse: a guessed region turns a missing setting into a redirect error from the wrong place |
| `COPY ... TO` with no `FORMAT` and an extension it cannot read | writes CSV | refuses by name (`COPY_FORMAT_NOT_INFERRED`) | refuse: guessing writes a file the statement may not have meant |
| a URL under no bound scope, on the default session or any other | sends the request with no credential unless a secret was created; the provider chain is opt-in (`CREATE SECRET (TYPE s3, PROVIDER credential_chain)`) *(to confirm against the pinned DuckDB)* | every session starts with `s3://` and `gs://` scopes bound to `komira.AMBIENT`, the process's own identity through the provider chains (decision 3) | keep the ambient default: it is what boto3, pyarrow and polars do beside komira *(inferred from their default credential chains)*, and `s.add_sql_binding("public", komira.files("s3://", credential=komira.ANONYMOUS, region="us-east-1"))` turns it off for SQL. The third default scope, `https://`, is `komira.ANONYMOUS`. An `az://` URL has no default scope and is refused with `CREDENTIALS_NOT_FOUND` until a scope is bound |
| the environment variables below, which `komira.AMBIENT` reads | its credential chain reads the same providers' variables | reads exactly the list below, inside the library, only for `komira.AMBIENT`, and `AwsProfile` reads only the file locators | allow the whole list as rule S2's provider-standard credentials, including the names outside `AWS_*` and `GOOGLE_*`: they are how the providers find credentials, and nothing else in komira reads the environment |

**The unnamed-source form, `s.sql(source, query)`, read as `self`.** The ruling keeps two ways to bind a name: `add_sql_binding` on the session, and a keyword of one `sql` call. This third spelling follows the owner's own sketch, `s.sql(t, "COMMAND")`, and is not ruled. Recommendation: keep it. Keeping it costs a third spelling of a call binding, a reserved name `self` that every SDK spells (`{ self: source }` in TypeScript and Mojo), and two `TypeError` rules (a second unnamed source, and `self=` beside one); it changes no plan, because `self` is a session-local name and never reaches the wire. Dropping it costs nothing in the plan or the library; a one-source query is written `s.sql("SELECT count(*) FROM t", t=t)` instead, and the examples that use `self` change.

### The environment komira reads

**EXISTS** in the chains' code (`aws_core`'s `credential_chain.mojo` and `shared_config.mojo`, `gcp_core`'s
`adc.mojo`), read through the **EXISTS** `ProcessEnv` seam. Nothing else in komira reads a variable.
The Python package reads none.

| provider | variables | what for |
|---|---|---|
| AWS | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` | static keys |
| AWS | `AWS_WEB_IDENTITY_TOKEN_FILE`, `AWS_ROLE_ARN`, `AWS_ROLE_SESSION_NAME` | web identity |
| AWS | `AWS_PROFILE`, `AWS_CONFIG_FILE`, `AWS_SHARED_CREDENTIALS_FILE` | the profile and the files it lives in |
| AWS | `AWS_CONTAINER_CREDENTIALS_RELATIVE_URI`, `AWS_CONTAINER_CREDENTIALS_FULL_URI`, `AWS_CONTAINER_AUTHORIZATION_TOKEN`, `AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE` | the container credential service |
| AWS | `AWS_EC2_METADATA_DISABLED`, `AWS_EC2_METADATA_V1_DISABLED`, `AWS_EC2_METADATA_SERVICE_ENDPOINT`, `AWS_EC2_METADATA_SERVICE_ENDPOINT_MODE` | the instance metadata service. Its endpoint says where credentials are, not where data goes |
| AWS | `AWS_REGION`, `AWS_DEFAULT_REGION` | the region, only for `ambient` (decision 7) |
| Google | `GOOGLE_APPLICATION_CREDENTIALS`, `CLOUDSDK_CONFIG`, `GCE_METADATA_HOST` | the credentials file, gcloud's directory, the metadata server |
| both | `HOME`; `APPDATA` on Windows (`gcp_core` only) | to find the well-known files |
| the platform's libcrypto, not komira | `SSL_CERT_FILE`, `SSL_CERT_DIR` | the default trust store, as for every program linked with it. komira's own setting is `Session(ca_file=...)` |

Not read, though `aws_core` has a reader for them: `AWS_ENDPOINT_URL`, `AWS_ENDPOINT_URL_S3`,
`AWS_USE_FIPS_ENDPOINT`, `AWS_USE_DUALSTACK_ENDPOINT`. komira does not call that reader: an endpoint
is configuration (rule S2), and it comes from a source's `endpoint=`.

## What problem does this solve?

People want komira to read files in object stores and tables in their Iceberg catalogs, and to write
results. The SQL binder turns a statement into a logical plan. It cannot work out what a name like
`raw_orders` or `sales_catalog` refers to, or who is allowed to read it. Someone has to say that, and the plan has
to record it in a form that runs the same way in a local session and on a job manager.

This design fixes that model for every kind of source and every SDK. It covers:

- how a user declares a source, binds a SQL name to it on the session, and gives it a credential;
- what the binder takes as input;
- what the plan carries;
- who turns a credential's name into a value, locally and on a job manager;
- what the engine keys its caches on;
- the C ABI under the SDKs;
- `https://` reads, writes, and the error codes of all of these.

It replaces the spellings that earlier drafts proposed for the same thing:
- the Iceberg design's `attach_iceberg`;
- the DataFrame design's `register_view`.

The ABI design for running a query hands credentials to this design
([libkomira_run_abi.md §10](libkomira_run_abi.md#10-new-relative-to-the-earlier-abi)). It also leaves
statements that are not queries refused "until writes have their own design"
([§3](libkomira_run_abi.md#what-komira_sql_stream-runs)). The Python package design promises a
`KomiraError` with `code` and `step` ([decision 9](python_package.md#9-errors)), and the ABI gives no
source for either. This design settles both.

Fixed before this design and not reopened:
- the import and distribution name `komira`;
- the release platforms;
- same SQL, same result as DuckDB, with unsupported features refused by name (rule B21);
- the client optimizes, and a job manager takes only a serialized optimized plan;
- configuration comes as arguments, never environment variables (rule S2), and no endpoint is written
  into the code (rule S1).

## What exists today

- **EXISTS, the binder.**
  `bind_statement[P](stmt, catalog: SqlCatalog, footers: P) -> BoundStatement`
  ([src/sql/sql_binder.mojo](../../src/sql/sql_binder.mojo)) already takes a table of names as input.
  - The table is `SqlCatalog`: name to schema and `SourceVariant`
    ([src/sql/sql_catalog.mojo](../../src/sql/sql_catalog.mojo)).
  - The binder plugs the source into the scan.
  - An unknown name raises `SQL bind error: unknown table '<name>'`, without saying which names exist.
  - A string literal (`FROM 'x.parquet'`, `read_parquet('...')`) becomes a source without the
    catalog, and its footer is read at bind time.
  - A qualified name `a.b` keeps only `b` ([src/sql/sql_parser.mojo](../../src/sql/sql_parser.mojo)).
  - The session keeps one catalog (`src/so/session.mojo`), filled by `komira_register_parquet`.
- **EXISTS, a defect.** `SqlCatalog.add_parquet` appends, and `_find` returns the first entry with
  the name. So registering a name a second time keeps the first file. The Python package's
  `register_parquet` says a second registration replaces the first
  ([python/komira/_session.py](../../python/komira/_session.py)). Decision 2 makes replacement the
  rule. **FIXED** with `komira_add_sql_binding`: `register_parquet` (`src/so/sources.mojo`) now
  replaces a taken name (`test_register_parquet_replaces_a_taken_name`).
- **EXISTS, no credential anywhere in the plan.**
  - `WireParquetSource` (`paths` = 1 to `fs_is_local` = 10, [src/plan_proto/plan.proto](../../src/plan_proto/plan.proto))
    carries verbatim paths, and the codec refuses a non-local file system.
  - In process, a scan carries `FsDescriptorPod`, which is a scheme, a bucket and a query-local
    `node_id` ([src/plan_expr/fs_descriptor_pod.mojo](../../src/plan_expr/fs_descriptor_pod.mojo)).
  - Secrets are in-process tables keyed by `node_id`: `SecretBindings` holds
    `(node_id, name_handle, secret_ref)` and never a value. `SecretCapability.open_connection_for`
    reveals a value inside one call and wipes it
    ([src/sdk_exec/secret_capability.mojo](../../src/sdk_exec/secret_capability.mojo)).
    A `SecretValue` is at most 4096 bytes and prints as `SecretValue(<redacted:NB>)`.
- **EXISTS, names instead of values, in design.**
  - `IcebergTableRef.catalog` is "a catalog NAME the deployment maps to an endpoint and credentials;
    never either" ([optimized_plan_sources.md](optimized_plan_sources.md) §15.3.1).
  - A UDF's secret "is captured as a reference that the host resolves under the run's identity. Its
    value is never serialized" ([optimized_plan_udfs.md](optimized_plan_udfs.md)).
  - The customer secret catalog row `SecretManager` holds `(org_id, workspace_id, name_handle,
    provider_kind, secret_ref, reachability)`. Its `name_handle` is "a NAME, not a value", and
    `REACHABILITY_CUSTOMER_BOUNDARY_ONLY` marks a store that only code inside the customer's boundary
    can read ([src/secrets](../../src/secrets/README.md)).
- **EXISTS, the provider chains, as libraries with injected seams.**
  - The AWS default chain ([src/aws_core](../../src/aws_core/README.md), `credential_chain.mojo`)
    tries, in order: explicit keys, the `AWS_*` key variables, web identity, the shared config and
    credentials files, the container credentials endpoint, and the instance metadata service.
  - Google's Application Default Credentials ([src/gcp_core](../../src/gcp_core/README.md),
    `adc.mojo`) try the `GOOGLE_APPLICATION_CREDENTIALS` file, gcloud's file, then the metadata
    server.
  - In both, a step that is configured but broken is refused, naming the setting, with no fall-through.
  - The stores take everything as constructor arguments and read no environment, and tests hold that:
    `objectstore_s3`, `objectstore_gcs`, and `azure_blob` (read-only, with no chain).
- **EXISTS, no cache keyed on identity.** These are keyed by path only:
  - the binder's `FooterCache` ([src/parquet_footers](../../src/parquet_footers));
  - the scan's `ParquetMetadataCache` ([src/parquet/runtime_footer_cache.mojo](../../src/parquet/runtime_footer_cache.mojo)).

  They are safe today only because they live one query or one run (`EngineContext.begin_query`,
  `engine_execute.mojo`). `PlanCompileCache` keys on the plan's rendered text, and nothing uses it yet.
  The object-store credential caches are one slot per client object.
- **EXISTS, writes refused.** `COPY` and `CREATE TABLE ... AS` parse and bind, and `run_sql` refuses
  them at `bind` with `STATEMENT_NOT_A_QUERY` ([src/sdk_exec/engine_sql.mojo](../../src/sdk_exec/engine_sql.mojo)).
  The (format, codec) pairs a sink exists for are `write_target_supported`'s 13
  ([src/arrow/write_target.mojo](../../src/arrow/write_target.mojo)). `WireWriteTarget` is `path` = 1,
  `format` = 2, `codec` = 3.
- **FIXED.** With no `FORMAT`, the `COPY` parser takes the format from the extension as DuckDB does
  (`sql.sql_copy_format`), and `run_sql` writes Parquet, CSV and newline-delimited JSON
  ([src/sdk_exec/README.md](../../src/sdk_exec/README.md)).
- **EXISTS, a TLS client.** `http_client` has ranged GET (`get_range`), redirects as a layer, and no
  proxy support ([src/http_client](../../src/http_client/README.md)). `source_url` refuses `http://`
  and any `https://` host that is not the Azure Blob service
  ([src/source_url](../../src/source_url/README.md)).

## The decisions

### 1. Sources are objects; credentials are named objects

Every Python name in this decision is **PROPOSED**. `komira.Session` itself **EXISTS** (release 1).

**A source** says where data is. It is a value the user builds and holds, and building one does no
I/O. There is one kind of object per kind of source, and they all bind the same way (decision 2).
`catalog.table(...)` builds a table source from a catalog object and a table name. It reads nothing
until a statement uses it. `komira.iceberg(...)` is the Iceberg REST catalog object that the plan
design's `km.catalog("lake")` stood for. `km.catalog(name)`, a name the deployment maps, is not added,
because a session-local name never reaches the wire (decision 4).

| kind | Python | what it holds |
|---|---|---|
| files | `komira.files(location, *, credential=komira.AMBIENT, endpoint=None, region=None, url_style=None, hive_partitioning=False)` | a local path, a glob, or a URL (`s3://`, `gs://`, `az://`, `abfss://`, `https://`); how to reach its store; the credential |
| a catalog | `komira.iceberg(uri, *, warehouse=None, credential=komira.AMBIENT, signing=None, access_delegation="vended-credentials")` | an Iceberg REST catalog of many tables: its location and the credential for it. Bound under a name, its tables are named in SQL as `name.namespace.table`. `access_delegation` is `"vended-credentials"` or `"none"`. Any other value, `"remote-signing"` among them, is refused by name; remote signing is a later, additive value |
| one table of a catalog | `catalog.table(name)`, a method of the catalog object; `name` is `"namespace.table"`, or a tuple of namespace levels and the table name | that catalog, and one table in it. Bound under a name, SQL reads it by that name alone. It uses the catalog's credential, so the plan names the same credential |
| a frame or a view | a komira `DataFrame` or `LazyFrame`, passed as it is | its plan, which the binder reads as a view |
| later: a database | for example a `komira.postgres(host, database, *, credential=...)` | a connection's location and the credential for it. This design does not design it ([Fits later](#a-source-that-fits-later-a-customer-database)) |

- **`location` is a single file, a glob, or a prefix.**
  - A location ending in `/` is a **scope**. It is how a URL written in SQL gets its credential and
    store settings (decision 3).
  - `endpoint`, `region` and `url_style` (`"vhost"` or `"path"`) describe how to reach an object store.
    They are settings, not credentials, so they travel in the plan (decision 4). An `endpoint` may be
    `http://`: an emulator is reached by writing its address into a source on purpose.
  - Arguments a kind does not have raise `TypeError`, and wrong values raise `ValueError`, before the
    library is called (the package design's [decision 9](python_package.md#9-errors)).
- **A credential** says who reads. Every credential has a **name**: the name is what the plan carries,
  and what a job manager looks up.

  | Python | value |
  |---|---|
  | `komira.AwsKeys(name, *, key_id, secret, session_token=None)` | static AWS keys |
  | `komira.AwsProfile(name, *, profile)` | a profile of the shared AWS files |
  | `komira.GcpServiceAccount(name, *, file)` | a Google credentials file of the kind `GOOGLE_APPLICATION_CREDENTIALS` names |
  | `komira.GcpToken(name, *, token)` | an OAuth access token |
  | `komira.AzureKey(name, *, account, key)`, `komira.AzureSas(name, *, account, sas)` | Azure Shared Key, SAS |
  | `komira.BearerToken(name, *, token)` | a bearer token, for a catalog |
  | `komira.OAuth2ClientCredentials(name, *, client_id, client_secret, scope="catalog", token_url=None)` | a client-credentials grant, for a catalog |
  | `komira.AMBIENT` | the reserved name `ambient`: whatever identity runs the plan (decision 7) |
  | `komira.ANONYMOUS` | the reserved name `anonymous`: no credential |

  - A name is 1 to 128 bytes of letters, digits, `_`, `.` and `-`. `ambient` and `anonymous` are
    reserved. A name outside this grammar raises `ValueError` without quoting it, because it may be a
    pasted secret.
  - The name is the user's choice, and it should be the name the credential has in the secret store a
    job manager will read (decision 5). That is what makes a plan run the same in both places.
  - A credential must fit its source. An example of a misfit is an `AzureKey` on an `s3://` location.
    A misfit raises `ValueError` when the source is built, and the library refuses it again at bind
    with `CREDENTIAL_KIND_MISMATCH`.
  - `komira.SigV4(region, service)` is a catalog's `signing=` value, not a credential. It signs every
    request with whichever AWS credential the source names: `AMBIENT` for the provider chain, or
    `AwsKeys`. The Iceberg design's `AwsSigV4(region, signing_name)` becomes this pair.
- **What a credential object will not do.**
  - `repr()` shows the kind and the name, and each secret field as `<set>`.
  - It refuses `pickle` and `copy` with `TypeError`.
  - It defines no `__hash__`.
  - A secret is a Python `str` until the library copies it. The package cannot wipe interpreter
    memory and does not claim to.

### 2. Binding a SQL name: on the session, or for one call

A SQL name is bound in one of two ways (**PROPOSED**). Both bind the same sources, by the same rules.

| spelling | lasts | example |
|---|---|---|
| `s.add_sql_binding(name, source)` | until the session closes, or until the name is added again | `s.add_sql_binding("sales_catalog", sales_catalog)` |
| `s.sql(query, /, **sources)` | this statement | `s.sql("SELECT * FROM orders_table", orders_table=sales_catalog.table("sales.orders"))` |
| `s.sql(source, query, /, **sources)` | this statement; the one unnamed source is bound as `self` | `s.sql(raw_orders, "SELECT count(*) FROM self")` |

- **The method's name says SQL, because the binding is only for SQL.** The DataFrame door takes
  objects directly and never reads these bindings: `komira.read_table(catalog, "ns.table")`, and
  `komira.read_parquet` and the other file readers, given a path or a `komira.files` source.
- **A call binding wins over a session binding of the same name, for that statement only.**
  - The call is the explicit, local choice. Refusing it would make a user remove a session binding to
    run one statement over other data.
  - The session binding is untouched, and the next statement sees it again:

    ```python
    s.add_sql_binding("orders_table", sales_catalog.table("sales.orders"))
    s.sql("SELECT count(*) FROM orders_table",
          orders_table=sales_catalog.table("sales.orders_archive"))   # reads sales.orders_archive
    s.sql("SELECT count(*) FROM orders_table")                         # reads sales.orders again
    ```

  - A CTE of the same name hides both, as a CTE hides a table today. Names fold case, as the binder's
    catalog does.
- **One unnamed source per call, as `self`**, kept pending the question at the top. It follows the
  owner's sketch, `s.sql(t, "COMMAND")`. A
  source given before the query is bound for that statement under the name `self`. `self` is, by the
  author's reading of polars' documentation, the name polars' `DataFrame.sql` gives its frame
  *(to confirm against the pinned polars)*.
  - Named sources may be added beside it.
  - A second unnamed source raises `TypeError`, and so does a keyword `self=` beside an unnamed one.
  - The unnamed source may be of any kind. A catalog is read as `self.ns.t`.
- **`add_sql_binding` always takes a name.** An unnamed session binding would make `self` mean
  whatever was added last.
- **Re-adding a name on the session replaces its binding.** Nothing appends behind the user's back.
- **`sql` takes no keyword other than sources, now or later.** Every keyword names a source, so a
  future option can never collide with a table name. Options belong on `Session`.
- **What a binding reads when it is added.** A `komira.files` source of a local path resolves a
  relative path against the working directory, and reads the footer when it is added, as
  `register_parquet` does. It infers the format from the extension. As a call binding, it reads the
  footer when the call starts, before the statement binds, so a missing file raises at that call. A
  remote source, a catalog and a catalog table are read when a statement first uses them.
- **The SDK seals credentials, then binds.** It seals every credential the source names, a catalog's
  own and its `data_access` credential included. Then it adds the session binding, or passes the call
  binding. A refused binding leaves the binding table unchanged.
- **`self` is the Python spelling only.** TypeScript and Mojo write `{ self: source }` and
  `{"self": source}`, which give the same plan. `add_sql_binding("self", x)` is allowed, and an
  unnamed call source wins over it for its statement, as any call binding does.

**Credential values, and their generations.** The plan carries only a credential's name, so a name has
one value in a statement. The value is set when a binding, or a DataFrame reader's source, brings it.

- **Every value has a generation** (**PROPOSED**), drawn from one counter per session, for each value
  sealed on the session or for a call.
  - **The session's value of a name** is the value of the latest session seal of it. A session seal is
    `add_sql_binding`, or a DataFrame reader's source. The value is kept until the session closes.
  - A session seal byte-equal to the session's value keeps its generation. Any other value gets a new
    one.
  - A call value byte-equal to the session's value takes the session's generation, and is no
    conflict. Any other call value gets a fresh generation, in every call, even if an earlier call
    passed the same bytes. So no cache entry is shared between two calls' own values. A call value
    byte-equal to the session's value reads the session's cache entries, by design: it is the same
    value, at the same generation.
  - The identity of a read includes the generation (decision 6). So no cache answers a call from a
    value other than the one that call carried.
- **A value brought by `add_sql_binding`** is the session's value of its name.
  - Re-adding a binding with a new value under an existing credential name changes it for every
    binding that uses that name, at a new generation. This is intended: the plan says only the name,
    so a name has one value in a session at a time.
  - A DataFrame reader's source seals into the session the same way. So a reader given a new value
    under a name changes what the SQL bindings of that name read. The rule is one name, one value, in
    a session.
- **A value brought by a call binding** lives in that call's overlay, and never changes the session's
  value.
  - It is dropped when the call returns. That is safe because `komira_sql_stream` materializes its
    result before it returns ([libkomira_run_abi.md §5](libkomira_run_abi.md#5-the-result-an-arrow-c-stream)),
    so no read under the call's value happens later.
  - If a later ABI streams results incrementally, the overlay lives until the stream is released.
- **Within one statement, one credential name has one value.** The binder checks the bindings the
  statement uses, so an unused call binding never refuses a statement. These are refused at bind with
  `CREDENTIAL_NAME_CONFLICT`, naming the credential and both bindings:
  - a call value that differs from the session's value of that name;
  - two different call values under one name.

  Example:

  ```python
  s.add_sql_binding("raw_orders", komira.files("s3://raw-events/orders/*.parquet",
                                               credential=komira.AwsKeys("raw-etl", ...)))   # value v1
  s.sql("SELECT count(*) FROM raw_returns",
        raw_returns=komira.files("s3://raw-events/returns/*.parquet",
                                 credential=komira.AwsKeys("raw-etl", ...)))     # value v2: refused
  ```

  The plan would name `raw-etl` once and could not say which value. No job manager could reproduce
  it.
- **A user whose token was rotated** does one of three things:
  - when the session holds no value of the name, passes the new value on each call, which gives it a
    fresh generation;
  - when a session binding uses it, re-adds that binding with the new value, which changes it for
    every binding of the name;
  - gives the new value a new credential name.

  So reading one location under two credentials in one statement needs two credential names.
- **Module-level spellings.** `komira.add_sql_binding(name, source)`, `komira.sql(query, /, **sources)`
  and `komira.sql(source, query, /, **sources)` act on the default session
  ([python_package.md decision 5](python_package.md#5-the-default-session)).

What happens to each earlier spelling:

| spelling | where it came from | now |
|---|---|---|
| `Session.register_parquet(name, path)` and its C row `komira_register_parquet` | the package design; built and released (**EXISTS**) | kept, as a spelling of `add_sql_binding(name, komira.files(path))`: the library implements it as `komira_add_sql_binding` of a local file source. It keeps what it does today: a relative path resolves against the working directory at the call, `~` is expanded in Python, and the footer is read at the call, so a missing file raises there. It is not deprecated, because it is released and removing it would break a public call. Its docs point at `add_sql_binding` |
| `Session.attach_iceberg(name, uri=, warehouse=, auth=)` and `Session.catalog(name)` | the Iceberg design, not merged | gone. `komira.iceberg(...)` is the catalog. The user holds it, and adds it with `add_sql_binding` |
| `Session.register_view(name, frame)` | the DataFrame design, not built | gone. `s.add_sql_binding(name, frame)`, or the frame passed to one `sql` call |
| `komira.session()` | the Iceberg design's example | not added. The class is `komira.Session`, and the package design has no `session()` accessor |
| `read_table(catalog, name, as_of=)` and `frame.write_table(catalog, name, mode=)` | the plan design §15.9 and the Iceberg design | kept, as the DataFrame door's verbs. They take a held catalog object and read no SQL binding. They emit the plan that the SQL `catalog.ns.t`, `INSERT` and `CREATE [OR REPLACE] TABLE ... AS` emit, with the same source and credential name. `as_of=` has no SQL spelling, because the Iceberg design refuses SQL time travel |

### 3. The binder: a statement and its bindings

**PROPOSED.** The interface is this: **every `sql` call gives the SQL-to-plan converter the statement,
the session's whole binding table, and that call's own bindings.** The session table holds the names
the user added and the session's default scopes.
- The converter looks nothing up by itself.
- What a name means is what those two tables say at that call, the call's winning.
- The SDK keeps the library's copy of the session table equal to its own by sending each binding when
  it is added. It sends the call's bindings just before the statement (decision 8).

A binding holds a bound source: its kind, its location, its access settings (decision 4) and its
credential name. It holds no credential value. `SqlCatalog` is that table: one per session, and one
overlay per call, dropped when the call returns.

**The plan carries only what the statement uses.** The binder plugs in the sources the statement names
or whose scope covers one of its URLs. The plan holds those sources, each with its credential's name
and access settings, and nothing about the bindings the statement does not use.

How each kind of name in SQL finds its source:

| written in SQL | how it binds |
|---|---|
| `orders` (one part) | the binding named `orders`. A file source becomes a scan, a catalog table (`catalog.table(...)`) becomes that table's scan, and a frame becomes a view of its plan |
| `sales_catalog.sales.orders` (two or more parts) | the first part names a binding, which must be a catalog. The rest is the catalog's to resolve: namespace levels, then the table ([the Iceberg design](#reconciling-with-the-iceberg-design)). A first part bound to something other than a catalog is refused with `BIND_NOT_A_CATALOG` |
| `main.orders`, `memory.main.orders` | DuckDB's default schema and database. When no binding is named `main` or `memory`, these qualifiers resolve the unqualified name, as DuckDB does, and as the binder does today |
| `x.orders` with `x` not bound and not `main` or `memory` | `BIND_NAME_UNBOUND`, naming `x`. A first part bound to something other than a catalog is `BIND_NOT_A_CATALOG` |
| `'s3://raw-events/orders/a.parquet'`, `read_parquet('gs://...')`, `COPY ... TO 's3://...'` (a URL literal) | the **scope** whose location is the longest prefix of the URL, among the bound file sources whose location ends in `/`, compared after aliases are normalised (`s3a://` to `s3://`, `gcs://` to `gs://`). The scope gives the URL its credential name and access settings |
| `'data/x.parquet'` (a local path) | the local file system, under the identity of the process. No binding is needed, so DuckDB's `FROM 'x.parquet'` works as it is |

- **A name with no binding is refused by name.** The error is `BIND_NAME_UNBOUND`, and its message lists
  the bound names, sorted:
  `bind: BIND_NAME_UNBOUND: no source is bound to 'ordrs'; bound names: orders_table, raw_orders, sales_catalog;
  bind the name first`.
  - The library's text names no SDK method, because each SDK spells it in its own casing.
  - This replaces `unknown table`. It also replaces the Iceberg design's `ICEBERG_CATALOG_NOT_ATTACHED`.
  - The list is cut at 50 names, with the count of the rest.
- **Every session starts with three scopes**, at the scheme roots (the owner question at the top asks
  whether the ambient default should stay):
  - `s3://` and `gs://` with `komira.AMBIENT`;
  - `https://` with `komira.ANONYMOUS`.

  They have no names.
  - **A scope is keyed by its normalised location**, not by its binding name. Binding a scope at a
    location that already has one replaces it, whatever either is called, for example
    `s.add_sql_binding("public", komira.files("s3://", credential=komira.ANONYMOUS, region="us-east-1"))`.
  - A call binding of a scope replaces, for that statement only, the session scope at the same
    normalised location, whatever either is called.
  - `BIND_NAME_UNBOUND` lists names, not scopes.
  - A URL under no scope, an `az://` URL for example, is refused with `CREDENTIALS_NOT_FOUND`, which
    says to bind a scope.
- **A scope is matched on whole path segments.** `s3://bucket/` covers `s3://bucket/a` but not
  `s3://bucket-two/`. A location ending in `/` is a scope, and naming a scope as a table is refused
  with `BIND_SCOPE_NOT_A_TABLE`: reading a prefix as a dataset is a later, additive decision.
- **A URL with user information is refused at bind** (`STORAGE_URL_REFUSED`). An example is
  `s3://key:secret@bucket/`. A credential is never part of a location.
  - The same check applies to a source's `endpoint` and a catalog's `uri`, which also may not carry a
    query string or a fragment.
- **The binder reads footers with the credential's value**, inside the library, through the
  session's secret store. The plan it produces still carries only the name.
- **The DataFrame door reads no SQL binding.** Its readers and write terminals take an object or a
  path.
  - Given a `komira.files` source, a reader uses that source's credential and settings.
  - Given a bare path or URL, it uses the three built-in defaults as constants: `ambient` for
    `s3://` and `gs://`, `anonymous` for `https://`. It does not use the session's binding table, so
    re-binding `s3://` for SQL changes nothing for readers. A remote URL with its own credential is
    passed as a `komira.files` source.
  - The reader puts the result in the plan's `access` field when it is called.
  - A catalog table is read with `komira.read_table(catalog, "ns.table")`.

### 4. The plan: a location and a credential name, never a value

**PROPOSED.** The plan carries a resolved source: where the data is, the settings needed to reach it,
and the name of the credential.
- It never carries a credential's value, with one named exception: a presigned URL's query string,
  bounded to plans that stay in the process (the last bullet of this decision).
- It never carries the session-local binding name (`orders_table`, `sales_catalog`). Two users' `sales_catalog` may
  be two catalogs, and a job manager must not have to guess which.
- It carries only the sources the statement uses (decision 3).
- The wire is permanent, so each field below says what it may hold.

```proto
// plan.proto, new. How to reach and authenticate one source. Never a secret.
message WireSourceAccess {
  string credential      = 1;  // a credential NAME (ambient, anonymous, or the user's); never a value
  string endpoint        = 2;  // the store's endpoint when it is not the scheme's default; empty otherwise
  string region          = 3;  // the region requests are routed to and signed for (see below)
  AddressingStyleWire addressing = 4;  // vhost or path; UNSPECIFIED means the store's default
  string signing_service = 5;  // SigV4 service name for a catalog (for example "glue"); empty = no SigV4
}

// plan_vocabulary.proto, appended
enum AddressingStyleWire {
  ADDRESSING_STYLE_WIRE_UNSPECIFIED = 0;
  ADDRESSING_STYLE_WIRE_VHOST       = 1;
  ADDRESSING_STYLE_WIRE_PATH        = 2;
}

// plan.proto, new. An Iceberg REST catalog, as a source.
message WireIcebergCatalog {
  string           uri         = 1;  // the catalog's base URI, as the user gave it
  string           warehouse   = 2;  // empty = the catalog's default
  WireSourceAccess access      = 3;  // the catalog's credential name and signing
  bool             vended      = 4;  // true = ask the catalog to vend data-file credentials
  WireSourceAccess data_access = 5;  // the table files' credential name and store settings when the
                                     // catalog vends none: the scope covering the table's location
}

// bound_source.proto (EXISTS with `files` only, beside WireSourceAccess and AddressingStyleWire; the
// other arms are held). The input of komira_add_sql_binding (decision 8): a source as the user declared it.
// The binder translates it into the plan's own source messages; it is never part of a plan.
message WireBoundSource {
  oneof kind {
    WireFileSource     files   = 1;
    WireIcebergCatalog iceberg = 2;
    WirePlanEnvelope   view    = 3;  // a frame's plan; one with a write target or UDFs: BIND_VIEW_NOT_A_QUERY
    IcebergTableRef    iceberg_table = 4;  // one table of a catalog: catalog.table("ns.t")
  }
}
message WireFileSource {
  string           location          = 1;  // a path, glob or URL; a trailing "/" makes it a scope
  WireSourceAccess access            = 2;
  bool             hive_partitioning = 3;
}

// Fields added to existing messages; each is optional, and absent means today's meaning.
//   WireParquetSource.access = 11  (WireSourceAccess; absent = a local file)
//   WireScanBinding.access   = 17  (WireSourceAccess; absent = a local file)
// The Iceberg design's IcebergTableRef: field 1 becomes `WireIcebergCatalog catalog = 1`, not a name.
// IcebergTableRef has never shipped (it is design only, in optimized_plan_sources.md §15.3.1), so
// re-typing field 1 breaks no plan anyone wrote.

// plan.proto. The one WireWriteTarget both this design and the Iceberg design use: the Iceberg
// design's oneof, plus this design's access for a path destination.
message WireWriteTarget {
  oneof destination {
    string          path    = 1;   // existing (COPY TO); moved into the oneof, same number
    WireIcebergSink iceberg = 10;  // the Iceberg design; its table's catalog carries its own access
    // held: 11 topic, 12 delivery, 13 late_rows (plan_models.md §2.2.6)
  }
  WriteFormat      format = 2;     // path only; must be the default with `iceberg`
  WriteCompression codec  = 3;     // path only; must be the default with `iceberg`
  WireSourceAccess access = 4;     // path only: the destination's credential name and store settings;
                                   // absent = a local destination; must be absent with `iceberg`
}
//
// optimized_plan.proto, DeclaredNeeds (EXISTS; data_scopes = 5 EXISTS, this field PROPOSED):
// the header copy a job manager reads without the body.
//   repeated string credentials = 11;  // every WireSourceAccess.credential in the plan, sorted, unique
```

- **Location.** For files, the location is the path or URL already in `paths`, verbatim. For a catalog,
  it is `uri`, `warehouse`, and the table's `namespace` and `name`. Every one of these is something the
  user wrote, not something a deployment maps from a name.
- **One `region` field, deliberately.** It holds the region that requests are signed for, and it
  routes requests only where the store routes by region.
  - On AWS S3, routing and signing use one region, by the protocol.
  - An S3-compatible store named by `endpoint` routes by its endpoint and uses `region` only to sign.
    That is the counter-case to "routing region", and the field's meaning, signing first, covers it.
  - A catalog uses `region` only to sign.
  - *(Inferred)*: no source this design serves needs a signing region different from the region it
    routes by, where it routes by region at all. If one ever does, a new optional `signing_region`
    would be additive and would default to `region`.
- **A source that needs two credentials carries two access fields, each named for what it reaches.**
  One field never holds two credentials.
  - A catalog has `access`, for the catalog's own API, and `data_access`, for its table files when
    the catalog vends nothing.
  - The binder fills `data_access` at bind time, from the scope covering the table's location, which
    it learns when it loads the table.
  - A later kind that needs a second credential follows the same rule with its own field.
- **A scan carries its catalog once.** `IcebergTableRef.catalog` (`WireIcebergCatalog`) is the only
  copy in the body.
  - The Iceberg kind's `catalog` STR param and `WireScanBinding.table_catalog` were designed and never
    shipped. They are dropped for Iceberg scans.
  - `DataScope.catalog` in the header is derived from the ref's `uri` and `warehouse`, and checked
    against the body at admission, as `DeclaredNeeds.credentials` is.
- **What the existing name fields hold.**
  - The binder sets `WireParquetSource.name` (with `has_name`) to the source's location.
  - It sets `WireScanBinding.name` to the location, or to a catalog table's `namespace.name`.
  - It never sets either to the binding name. Both fields stay as they are (rule B8).
- **The binder translates, the plan does not embed.** A `WireFileSource` becomes a
  `WireParquetSource` or a `WireScanBinding`, depending on the format: its `location` goes into
  `paths`, its `hive_partitioning` into `hive_dir_scan`, and its `access` into `access`. A view's
  envelope is inlined as the view's plan. `WireBoundSource` itself never appears in a plan.
- **The decoder enforces the name grammar.** `WireSourceAccess.credential` must be `ambient`,
  `anonymous`, or a name of decision 1's grammar. `endpoint` and `uri` carry no user information,
  query or fragment. Each field is at most 2048 bytes. A violation is refused on decode, by name, so
  the rule does not depend on Python's checks.
- **Settings that are local to one machine stay out of the plan.** Today the only such setting is
  `Session(ca_file=...)` (**PROPOSED**), the trust roots for `https://` (decision 9). A job manager uses its own
  deployment's trust store.
- **The credential name is in the body and in the header.**
  - Because it is in the body, the digest binds it. `DeclaredNeeds.credentials` joins the digest
    trailer ([optimized_plan.md](optimized_plan.md)), so a scheduler sees every name a plan needs
    without decoding the body.
  - `komira_plan_render` (**EXISTS**, ABI 1.1) prints each source's credential name and settings (**PROPOSED**), so the rendered text,
    and the structural hash computed from it, tells two identities apart (decision 6).
- **Compatibility.** Every field is new and optional, which is additive under rule B8.
  - An old reader must not run a remote source as if it were local. So an envelope declares **format
    version 6** when it carries a `WireSourceAccess` anywhere, or the Iceberg write arm. The places a
    `WireSourceAccess` can appear are:
    - a file source's `access`;
    - `WireWriteTarget.access`;
    - an `IcebergTableRef`, whose catalog holds `access`.
  - Consequences, the same number and rule as the Iceberg design's:
    - a scan-only Iceberg plan, a `COPY ... TO 's3://...'` and an Iceberg write all declare 6;
    - the accepted set becomes `{4, 5, 6}`;
    - an understated version is refused, and an overstated one is accepted, as today.
  - An older reader therefore refuses such a plan by name instead of dropping the field.
  - That version raise is a deliberate exception to B8's "no version floor". It is the same exception
    `plan.proto` already makes for `write_target`, for the same reason: dropping the field would change
    the answer silently.
  - Plans without `access` keep their version and stay readable by every release. That pull request
    names its cross-release test.
- **The one named exception to "never a value": a presigned URL's query string.** A presigned
  `https://` URL carries its signature in its query string, so its location carries a credential.
  komira neither refuses it nor turns it into a named credential.
  - The location includes the query, verbatim, because it is the address the user wrote, and a plan
    that stays in the process keeps it to read the file.
  - The exception's bound is the process: such a plan never leaves it. The bullets below are every
    place the query could otherwise appear.
  - Error messages and logs print no query, fragment or user information.
  - `komira_plan_render` prints the query as `?<query:` and the first 16 hex digits of its SHA-256,
    never its text. Two scans of one path with different queries therefore render, hash and key
    caches differently.
  - Exporting a plan for a job manager refuses a URL with a query string (`PLAN_URL_QUERY_REFUSED`), so
    a plan that leaves the process holds no value at all.

### 5. Who binds credential names to values

A plan names credentials. Exactly one party turns each name into a value, and the plan is the same
bytes whichever party runs it.

- **In a local session**, the session holds a value per credential name.
  - The library copies each value into the session's store, and keeps a handle (decision 8).
    - The store is a `SecretStore`, an **EXISTS** trait in `secret_store`.
    - An in-memory conformer, `SharedMemorySecretStore`, **EXISTS** in `secrets`.
    - The session's use of it is **PROPOSED**.
  - `ambient` resolves through the provider chains (decision 7), and `anonymous` sends nothing.
  - Python seals a credential's value each time a binding, or a DataFrame reader's source, that uses
    it is added (decision 2).
  - **One value per name in a statement.** A value brought by `add_sql_binding` is the session's
    value of its name. A new one replaces it, at a new generation, for every binding that uses the
    name. A value brought by a call lives only in that call's overlay, with its own generation.
    Nothing cached under another generation is used for it (decisions 2 and 6).
- **On a job manager**, the **PROPOSED** interface its design must provide, so the two cannot drift:
  1. **The same names.** The job manager resolves each name in `DeclaredNeeds.credentials` (**PROPOSED**)
     and nothing else. A name maps to the customer's secret catalog row with that `name_handle`, in the run's
     workspace, else the organisation. `ambient` maps to the run's own identity (its role, service
     account or managed identity). `anonymous` maps to nothing.
  2. **Resolution happens where the value may be read.** A row marked
     `REACHABILITY_CUSTOMER_BOUNDARY_ONLY` is resolved by the host inside the customer's boundary,
     under the run's identity, never by a central service.
  3. **Admission refuses an unresolvable name before any data is read**, naming it
     (`CREDENTIAL_UNBOUND`). This is the plan design's "resolve and verify every pin" step.
     - **The header must match the body.** `DeclaredNeeds.credentials` is a summary, checked against
       the body as `needs.udfs` and `needs.unbounded` are. A host refuses a plan whose header set differs
       from the body's `access.credential` names (`OPTIMIZED_NEEDS_CREDENTIALS_MISMATCH`). It resolves
       a name only from that verified set.
     - **The kind must fit the source.** The resolved row's provider kind must suit the source that
       names it: AWS keys or role for `s3://` or a SigV4 catalog, a Google credential for `gs://`, and
       so on, derived from the scheme and `signing_service`. A misfit is `CREDENTIAL_KIND_MISMATCH`,
       which a local session also raises.
     - **A credential goes only where its row allows.** A secret-catalog row lists the endpoints,
       catalog URIs and token URLs it may be sent to. The provider's own default endpoints are always
       allowed. Admission refuses a plan that would send a named credential anywhere else
       (`ENDPOINT_NOT_ALLOWED`). It also refuses `http://` endpoints, and loopback, link-local and
       private addresses, unless the row names them. This keeps a plan's author from steering someone's
       `prod` credential to an address they control. In a local session, `endpoint=` stays the user's
       own choice.
  4. **Hosts resolve names, and nothing else hands them values.** A host gets a value only by
     resolving a name its segment carries, through the same interface, inside the customer's boundary
     when the row says so. It never gets one from another host, from the committer or the coordinator,
     or from a central service.
  5. **A conformance test holds the two together.** One plan is run by a local session and by a fake
     job-manager resolver that binds the same names, and both answer the same.
- **Vended credentials** (Iceberg's `storage-credentials`) are never bound to a name. Whoever loads a table gets them from the catalog, under the catalog's credential name.
  - For a table's data files, vended credentials come first when the catalog source asks for them
    (`vended`). Otherwise the scope covering the file's location applies (decision 3).
  - A bound scope never widens where komira writes inside a table: the Iceberg design's
    `ICEBERG_LOCATION_REFUSED` rule stands.
  - On several hosts, each host loads the table's credentials itself, under the catalog's credential
    name. It does so by `GET .../tables/{t}/credentials` where the server lists that endpoint, else by
    loading the table (a load response vends them too). That replaces the Iceberg design's sentence "the
    committer hands each host the credentials for its job". The plan still carries no value.
  - **A staged `CREATE TABLE ... AS` on several hosts** writes a table that does not exist yet, so a
    host has nothing to load. Its data files are written with the credential named in `data_access`,
    which each host resolves by name. That is the scope covering the staged table's location.
  - The location of a staged table is known only from the stage-create response. So for a staged
    create, the coordinator fills `data_access` after that response and before it cuts the segments
    for the hosts.
  - **When no scope covers that location, a staged create on several hosts is refused by the
    coordinator**, after the stage-create response and before it cuts the segments, so before any file
    is written (`ICEBERG_STAGED_CREATE_NO_SCOPE`, the Iceberg design's code). The
    message says to bind a scope over the table's location.
    - The staged create's vended credentials stay with the party that ran the stage-create, for its
      own writes. No other party receives them.
    - The rejected alternative, a run-scoped name holding them, would have put a vended value in the
      coordinator's hands and through the resolver to every host. That conflicts with item 4, and the
      entry would have had no secret-catalog row to check its kind and endpoints against.
    - A vend-only catalog can still be written by a staged create in one process, and by appends on
      several hosts, which load the existing table's credentials themselves.
  - In the first slice there is one process, and the session uses the vended credentials directly.
- **Bind time versus run time.** For a job-manager run, the client binds and optimizes with the user's
  credentials, and the hosts read with the run's. The plan's scan pins (data fingerprints) are checked
  at admission, so if the two identities see different data, the run is refused by name
  (`OPTIMIZED_PIN_*`). It never mixes what the two identities see.

### 6. Identity and caches

One location can be read under two credentials: under two credential names, under one name before
and after its value changes, or under a call's value and the session's in two statements
(decision 2). A cache must never answer identity B with what it
read for identity A.

- **The identity of a read** is one tuple: `(location, credential name, credential generation,
  endpoint, region, addressing, signing service)`. The location includes a URL's query string. Two
  reads that differ in any part are two reads.
  - A table file read with a catalog's `data_access` has that access's credential name and generation
    in its tuple. A file under the catalog's own `access` is never read with it.
  - A table file read with vended credentials has, as its credential part,
    `vended(<catalog credential name>, <its generation>, <table uuid>)`.
    - A refresh of the vended value within that triple keeps the identity. It is the catalog's grant
      to the same principal for the same table.
    - A new catalog credential generation, or another table, is another identity.
  - Every key below is this tuple, or this tuple with the location narrowed to its scheme and bucket
    or account.
  - The one exception is the compile cache, which is handled by invalidation instead.
- **Bindings** (`SqlCatalog` and a call's overlay) are keyed by the folded binding name. No cache is
  keyed by it. Each credential value, on the session or for a call, has exactly one generation, set
  when it is sealed, so no value is ever read without one.
- **Every cache that depends on what a read returned keys on the identity of the read.** That covers
  the binder's footer cache, the scan's metadata cache, object metadata, and later the plan-compile
  cache.
  - Today these live one query or one run, so the rule binds two pull requests: the one that makes any
    of them outlive a run, and the one that serves remote reads, because one statement may read one
    location under two names.
  - `PlanCompileCache` (**EXISTS**, not wired) keys on the rendered plan. The render holds every part of
    the identity except the generation, which is session state and so never in a plan.
    - That cache can hold what a rotated value invalidates: its second layer keys on statistics read
      from footers, and those were read under the old value.
    - So a new *session* generation of a name drops every cache entry whose plan names that
      credential, the compile cache included. The rule binds the pull request that wires that cache.
    - A call generation is private: entries keyed by it die with the call's overlay, and the session's
      entries stay.
- **Object-store clients** are built one per identity with the location narrowed to its scheme and
  bucket or account, that is per `(scheme, bucket or account, endpoint, region, addressing,
  credential name, generation)`, per run. A client's credential cache is one slot, so it is scoped by construction. Clients are never
  shared across sessions, which share nothing today (`engine_context.mojo`).
- **On a job manager's hosts**, a cache that serves several runs keys on the resolved principal the
  resolver returns, not on the name, because two organisations may both use the name `prod`. Such a
  cache is never shared across organisations.

### 7. The ambient credential and the only environment komira reads

- **Only `komira.AMBIENT`, and `komira.AwsProfile` for the files its profile lives in, read the
  environment, and only in a local session.** In the library, the **EXISTS** seams `ProcessEnv` and
  `ProcessFiles` feed `aws_core`'s and `gcp_core`'s **EXISTS** chains when a source naming `ambient` is
  first read. Their hermetic doubles `MapEnv` and `MapFiles` also **EXIST**. Neither runs when
  a session is made, or for local files.
  - An `AwsProfile` reads the profile it names from the shared AWS files. It finds them through
    `AWS_CONFIG_FILE`, `AWS_SHARED_CREDENTIALS_FILE` and `HOME`, never through `AWS_PROFILE`.
  - Every other explicit credential reads nothing but what it was given.
  - The Python package reads no environment.
  - On a job manager, `ambient` is the run's identity (decision 5).
- **What the chains read** is the whole list under
  [The environment komira reads](#the-environment-komira-reads), at the top, and nothing else.
- **The region is never guessed.** An S3 source's region comes from:
  1. `region=`;
  2. else, only when the credential is `ambient`, the chain: `AWS_REGION`, `AWS_DEFAULT_REGION`,
     the selected profile's `region`;
  3. else, for an `AwsProfile`, that profile's `region`.

  An explicit credential with no `region=` reads no region variable.

  `aws_core` reads no region from the instance metadata service. Without a region, the read is refused
  with `STORAGE_REGION_UNKNOWN`, naming these settings (the owner question at the top).
- **Configured but broken is an error, never a fall-through**, as `aws_core` and `gcp_core` already
  rule. An example is a named profile that does not exist. Such a step raises `CREDENTIALS_INVALID`,
  naming the setting.
- **Azure has no chain.** S2 names no Azure variables and `azure_core` reads none, so an Azure source
  names an `AzureKey`, an `AzureSas` or `ANONYMOUS`.
- **The chain answers lazily, and keeps what it answers for the session.** It refreshes before expiry.
  A failed resolution is not kept, so the next read tries again.

### 8. The C ABI

The three credential rows **EXIST** at ABI 1.2, with session scope only, the eight kinds and the
thirteen fields below, the two error rows **EXIST** at ABI 1.7, and `komira_add_sql_binding`
**EXISTS** at ABI 1.10, with session scope only and the `files` kind only (a local path, or
Parquet objects of an `s3://`, `az://` or `gs://` location; see [Where is the code?](#where-is-the-code)),
in the golden's spelling ([src/so/abi/komira.tsv](../../src/so/abi/komira.tsv)):

```text
komira_credential_add	Int32	Handle,Int32,CStr,UnsafePointer[Int32]	1.2
komira_credential_set	Int32	Handle,Int32,Int32,ConstBytes,UInt64	1.2
komira_credential_seal	Int32	Handle,Int32,Int32	1.2
komira_add_sql_binding	Int32	Handle,CStr,ConstBytes,UInt64,Int32	1.10
komira_last_error_code	Int32	Handle,UnsafePointer[UInt8],UInt64,UnsafePointer[UInt64]	1.7
komira_last_error_step	Int32	Handle	1.7
```

- **A credential is defined in three calls.** `komira_credential_add(ctx, kind, name, &id)` starts a
  definition. `komira_credential_set(ctx, id, field, value, len)` sets one field. Then
  `komira_credential_seal(ctx, id, scope)` makes it the value of `name`. `scope` is
  `KOMIRA_BIND_SESSION` 1 (**EXISTS**) or `KOMIRA_BIND_CALL` 2 (**PROPOSED**, with `komira_sql_stream`;
  until then a scope other than 1 is refused with `CREDENTIALS_INVALID`) (`constant` rows).
  - With `KOMIRA_BIND_SESSION`, it is the session's value: a new generation, unless the name already
    holds a byte-equal value.
  - With `KOMIRA_BIND_CALL`, it is the next `komira_sql_stream` call's value, with the generation of
    decision 2, dropped when that call returns.
  - When the run starts, a call value that differs from the session's value of the name, or from
    another call value of it, is refused with `CREDENTIAL_NAME_CONFLICT` (decision 2).
  - Kinds and fields are `constant` rows: `KOMIRA_CRED_AWS_KEYS` 1, `_AWS_PROFILE` 2,
    `_GCP_SERVICE_ACCOUNT` 3, `_GCP_TOKEN` 4, `_AZURE_KEY` 5, `_AZURE_SAS` 6, `_BEARER` 7,
    `_OAUTH2_CLIENT` 8.
  - Each field of decision 1's table has a `KOMIRA_FIELD_*` constant (**EXISTS**): `KEY_ID` 1,
    `SECRET` 2, `SESSION_TOKEN` 3, `PROFILE` 4, `FILE` 5, `TOKEN` 6 (of `GCP_TOKEN` and `BEARER`),
    `ACCOUNT` 7 (of both Azure kinds), `KEY` 8, `SAS` 9, `CLIENT_ID` 10, `CLIENT_SECRET` 11, `SCOPE` 12
    and `TOKEN_URL` 13. `komira_credential_seal` refuses a definition without a field its kind
    requires; `komira_credential_set` refuses a field its kind does not take, an empty value, one
    longer than 4096 bytes (the `SecretValue` bound) and one that is not UTF-8. Each refusal is
    `CREDENTIALS_INVALID` naming the credential and the setting, and discards the definition. A
    name outside decision 1's grammar is refused without being quoted.
  - A new kind or field is a new constant row, which raises the minor.
  - Values are bytes with a length, never required to be NUL-terminated. The library copies each into
    the session's `SecretStore` before the call returns and never echoes it, so the caller may
    overwrite its buffer at once.
  - `ambient` and `anonymous` need no definition. Defining either, in any case, is refused.
  - The values live in the session's `SessionSecretStore` (`src/so/credential_store.mojo`), a
    `SecretStore`, one `secret_ref` per field, bound by node id in the session's `SecretBindings`. A
    consumer reads one only through `SecretCapability.open_connection_for` over those bindings and
    that store, which hands it a zeroizing `SecretValue` for the call.
- **`komira_add_sql_binding(ctx, name, source, len, scope)`** binds the SQL name `name` to a source.
  - With `KOMIRA_BIND_SESSION`, the binding is on the session, replacing any binding of that name.
    `Session.add_sql_binding` uses this.
  - With `KOMIRA_BIND_CALL`, it applies to the next `komira_sql_stream` on the context, and wins over
    a session binding of the same name for that call. A plan has no SQL names, so `komira_plan_stream`
    takes no call binding. It is
    dropped when the call returns, whether it succeeds or fails. The keywords and the unnamed source
    of `sql` use this.
  - `source` is the bytes of a `komira.plan.v1.WireBoundSource` (decision 4). It is a new message,
    built from the plan's own `WireSourceAccess`, `WireIcebergCatalog` and `WirePlanEnvelope`, which
    every SDK already encodes for the plan door.
  - The binder translates it into the plan's source messages (decision 4).
  - Credentials never travel in these bytes, only their names.
  - `komira_sql_stream` runs its statement over the context's whole session table and the call's
    bindings (decision 3).
  - The order is: seal every credential the source names, then add the binding (decision 2).
  - **The SDK holds its session lock from the first call-scope seal or binding through the
    `komira_sql_stream` that consumes them**, so two threads on one session never mix their call
    bindings ([python_package.md](python_package.md) decision 3).
  - A staged call binding that no run consumes is dropped by the next call on the context that is not
    a staging call.
  - A source whose credential name has no sealed value, on the session or for the next call, is
    refused with `CREDENTIAL_UNBOUND`. `komira_plan_stream` does the same for a plan that names one.
- **Errors come from two calls, not from parsing the text** (**EXISTS**, ABI 1.7).
  - `komira_last_error_code` returns the last error's named code (`BIND_NAME_UNBOUND`,
    `SQL_STATEMENT_UNSUPPORTED`), or the empty string when the refusal has none. It uses the
    two-call protocol of `komira_last_error`.
  - `komira_last_error_step` returns one of: `KOMIRA_STEP_NONE` 0, `_PARSE` 1, `_BIND` 2,
    `_OPTIMIZE` 3, `_LOWER` 4, `_EXECUTE` 5 (`constant` rows). A failure in a registration or a bind
    call reports `_BIND`.
  - The library reads the code in one place, `error_code` in `src/so/session.mojo`, which a test
    holds: the prose prefixes `SQL syntax error: `, `SQL bind error: ` and `SQL not supported: `
    give `SQL_SYNTAX_ERROR`, `SQL_BIND_ERROR` and `SQL_NOT_SUPPORTED`; otherwise a leading
    `CODE: ` of upper-case words joined by underscores is the code; otherwise the code is empty.
    For `komira_sql_stream` the rule is applied to the text after the `<step>: ` prefix. Bindings
    never parse the text.
  - A binding loaded against a library without these calls sets `code` and `step` to `None`.
- **The ABI 1.1 conventions hold for every call:**
  - a NULL `ctx` returns -1, except that `komira_last_error_step` returns `KOMIRA_STEP_NONE`;
  - a NULL pointer argument, or a NULL `value` with a non-zero length, returns -2;
  - each call except the two error getters clears the last error when it starts;
  - an `*id` output is written only on `KOMIRA_OK`;
  - `komira_last_error_step` returns `KOMIRA_STEP_NONE` for a NULL `ctx` and when no error is held.
- **Bindings are catalog state, not engine options.** They are accepted at any time on an open session,
  unlike the session-option setters, which stop when the engine is built.

### 9. `https://` reads

- **PROPOSED** `FS_SCHEME_HTTPS` (4) is a new scheme code, added under rule B8, with its matrix row
  `scan_https`. `source_url` maps every `https://` URL whose host is not the Blob service's to it.
- **Read-only, one file per URL.**
  - The file's size comes from `HEAD`, and its bytes from ranged `GET`s.
  - A server that ignores `Range` is refused (`STORAGE_RANGE_NOT_SUPPORTED`). The reader does not fall
    back to downloading the whole file into memory.
  - Globs and Hive partitioning over `https://` are refused (`STORAGE_URL_REFUSED`), because HTTP has
    no listing.
  - Redirects are followed within `https://` only. Authorization-type headers are dropped on a
    cross-origin hop.
- **Plaintext `http://` URLs are refused** (`STORAGE_URL_REFUSED`; the owner question at the top). The
  only route to plaintext is a source's `endpoint=`.
- **Trust roots.** `Session(ca_file=None)` (**PROPOSED**; `caFile` in TypeScript, a later keyword of
  the package designs' `Session`) adds a PEM file of trusted roots for every `https://` the
  session reads. Tests of `https://` reads use a loopback TLS server with a test authority given this
  way.
- **No proxy.** `http_client` has no `CONNECT` support, and komira reads no `HTTPS_PROXY`. A later
  `Session(proxy=...)` would be additive.

### 10. Writes

Every Python call in this decision is **PROPOSED**. `komira_sql_stream` and `komira_plan_stream` are
**PROPOSED** in the ABI design for running a query, and are not built.

**One spelling per door.** The SQL door writes with `COPY` and, into a bound catalog, with
`CREATE TABLE ... AS` and `INSERT`. The DataFrame door writes with the write terminals and, into a
catalog, with `write_table`. There is no
`Result.write_parquet` and no `Session.copy`.

| statement | served when | goes through | returns |
|---|---|---|---|
| `COPY <table or (query)> TO '<dest>' (<options>)` | always: `dest` is a local path or a URL under a scope | `komira_sql_stream` | one row, one `BIGINT` column `Count`: the rows written, as DuckDB answers |
| `INSERT INTO t SELECT ...` or `VALUES ...`, where `t` is bound to one catalog table (`catalog.table(...)`) | always: it is the same append as `INSERT INTO c.ns.t` | `komira_sql_stream` | `Count` |
| `CREATE TABLE c.ns.t AS ...`, `CREATE OR REPLACE TABLE c.ns.t AS ...`, `CREATE TABLE c.ns.t (columns)`, `INSERT INTO c.ns.t SELECT ...` or `VALUES ...` | `c` is bound to a catalog ([the Iceberg design](#reconciling-with-the-iceberg-design)) | `komira_sql_stream` | what DuckDB returns: `Count`, or no rows for `CREATE TABLE` with a column list |
| pandas-shaped `to_parquet`, `to_csv`, `to_json(orient="records", lines=True)`; polars-shaped `sink_parquet`, `sink_csv`, `sink_ndjson` ([dataframe_surface_verbs.md](dataframe_surface_verbs.md)) | with the DataFrame surface, to the destinations `COPY` serves | `komira_plan_stream` with `write_target` set | `None`, as pandas and polars return, after the write is complete |
| `frame.write_table(catalog, name, mode=)` | with the DataFrame surface, into a held catalog source | `komira_plan_stream`, the plan `INSERT` or `CREATE [OR REPLACE] TABLE ... AS` emits | `None` |

- **Both doors return the same stream.** A run with a write target answers its one-row `Count` stream,
  and the write terminals read it and return `None`.
- **`COPY` options.**
  - Accepted: `FORMAT`, `COMPRESSION`, `COMPRESSION_LEVEL`, `HEADER true` and `ARRAY false`, as the
    parser accepts them today. The pairs are `write_target_supported`'s 13.
  - Every other DuckDB option is refused by name with `COPY_OPTION_UNSUPPORTED`: `PARTITION_BY`,
    `OVERWRITE`, `OVERWRITE_OR_IGNORE`, `APPEND`, `FILE_SIZE_BYTES`, `PER_THREAD_OUTPUT`,
    `USE_TMP_FILE`, `RETURN_FILES`, `DELIMITER`, `HEADER false` and `ARRAY true`. Each can later become
    an optional field of `WireWriteTarget` (rule B8).
  - The Python write terminals take one keyword, `compression=`. A value they cannot honour raises
    `UnsupportedOperation` by the DataFrame design's policy
    ([dataframe_surface.md §6](dataframe_surface.md#6-how-a-skin-refuses)). A keyword they do not have
    is Python's `TypeError`.
- **Format and codec follow DuckDB, or the write is refused.**
  - With no `FORMAT`, the format comes from the extension after one compression suffix is removed:
    `.parquet` is Parquet; `.csv` is CSV; `.json`, `.jsonl` and `.ndjson` are JSON.
  - Any other extension is refused with `COPY_FORMAT_NOT_INFERRED` (the owner question at the top).
  - With no `COMPRESSION`, CSV and JSON take gzip from `.gz` and zstd from `.zst`, else none. Parquet
    takes snappy.
- **A file write is all or nothing.**
  - A local destination is written to a temporary file in its directory, named with a leading dot and
    a random suffix. The temporary file is flushed, synced, and renamed over the destination. A
    failure removes it. A crash can leave a temporary file behind, never a partial destination.
  - `s3://` is a multipart upload, completed after the last part and aborted on failure.
  - The rename makes `COPY (SELECT * FROM 'a.parquet') TO 'a.parquet'` safe.
- **Destinations and their edge cases.**
  - An existing destination is replaced, as DuckDB replaces it.
  - A missing parent directory is not created (`STORAGE_NOT_FOUND`).
  - An empty result writes a valid empty file: Parquet with the schema, CSV with only its header, JSON
    with no lines.
- **Paths and URLs.** SQL takes `dest` as written. A relative path resolves against the process's
  working directory when the statement runs. A URL takes its credential and settings from its scope
  (decision 3), and the plan carries them in `WireWriteTarget.access`. The Python terminals resolve a
  local path when called, as `register_parquet` does.
- **Remote destinations.** `s3://` is written once the S3 write arm lands. `gs://`, `az://` and
  `https://` destinations are refused with `STORAGE_WRITE_UNSUPPORTED`, because the GCS and Azure file
  systems do not write today and HTTP has no write.

Statements refused by name, all with one code, `SQL_STATEMENT_UNSUPPORTED`. It replaces today's
`STATEMENT_NOT_A_QUERY`, which no release has exposed. Each message names the statement and the
spelling that works.

| statement | why, and what to write instead |
|---|---|
| `CREATE TABLE t AS ...`, `INSERT INTO t ...` where `t` is neither in a bound catalog nor bound to one catalog table | komira keeps no tables of its own. Bind a catalog and write `c.ns.t` |
| `CREATE [OR REPLACE] TABLE t ...` where `t` is bound to one catalog table | a table binding names a table that exists. Create through its catalog, as `c.ns.t` |
| `CREATE VIEW` | add a frame with `add_sql_binding` |
| `ATTACH`, `CREATE SECRET`, `DROP SECRET`, `SET s3_*` and the other credential settings | sources and credentials are bound from the SDK, never in SQL, which is logged and carried in plans |
| `INSTALL`, `LOAD` (`httpfs` among them) | remote reads are built in. Remove the statement |
| `UPDATE`, `DELETE`, `MERGE INTO`, `ALTER TABLE`, `DROP TABLE`, `CREATE SCHEMA` | not in the first Iceberg slice ([the Iceberg design](#reconciling-with-the-iceberg-design)) |
| `COPY ... FROM`, `EXPORT DATABASE`, `IMPORT DATABASE` | not served. Read a file with `read_parquet` or `FROM '…'` |

### 11. Error shapes

Every refusal in the table below has a named code, which the library returns through
`komira_last_error_code` (decision 8). A refusal outside the table may have none, and then the code
is the empty string. The Python classes below are the package's
table ([python_package.md decision 9](python_package.md#9-errors)).

`BindError`, `CredentialsError` and `StorageError` are public names now (**EXISTS**), each a
`KomiraError`, as are `ParseError` and `UnsupportedOperation`. The Iceberg design's `IcebergError`
is a `KomiraError` too and is **PROPOSED**.

| code | when | step | Python class |
|---|---|---|---|
| `BIND_NAME_UNBOUND` | a name in the statement has no binding; the message lists the bound names | `bind` | `BindError` |
| `BIND_NOT_A_CATALOG` | a qualified name's first part is bound to something other than a catalog | `bind` | `BindError` |
| `BIND_SCOPE_NOT_A_TABLE` | a scope (a location ending in `/`) is named as a table | `bind` | `BindError` |
| `BIND_VIEW_NOT_A_QUERY` | a bound frame's plan carries a write target or a UDF list | `bind` | `BindError` |
| `CREDENTIAL_UNBOUND` | a source or a plan names a credential the session cannot resolve | `bind` | `CredentialsError` |
| `CREDENTIAL_NAME_CONFLICT` | one statement carries two different values under one credential name: a call value against the session's, or two call values | `bind` | `CredentialsError` |
| `CREDENTIAL_KIND_MISMATCH` | a credential does not fit its source (an Azure key on `s3://`) | `bind` | `CredentialsError` |
| `CREDENTIALS_NOT_FOUND` | `ambient` found nothing configured; a URL under no scope | `bind` or `execute` | `CredentialsError` |
| `CREDENTIALS_INVALID` | a configured chain step is broken; a credentials file is unreadable or malformed; a token the provider rejects at exchange; a credential defined through the C ABI with an unknown kind or field, a field its kind lacks or does not take, an empty, oversized or non-UTF-8 value, or a name outside the grammar or reserved (decision 8) | `bind` or `execute` | `CredentialsError` |
| `STORAGE_REGION_UNKNOWN` | no region for an S3 source (decision 7) | `bind` | `StorageError` |
| `STORAGE_NOT_FOUND` | the object, or the destination's directory, does not exist | `bind` or `execute` | `StorageError` |
| `STORAGE_ACCESS_DENIED` | the store refused the credential (401, 403), or the server's certificate failed verification, which the store layer classes with these | `bind` or `execute` | `StorageError` |
| `STORAGE_THROTTLED` | still throttled after the retry policy's attempts | `execute` | `StorageError` |
| `STORAGE_TRANSPORT` | connect failure, connection reset, timeout, end of stream mid-response | `bind` or `execute` | `StorageError` |
| `STORAGE_MALFORMED` | the store answered something komira could not read | `bind` or `execute` | `StorageError` |
| `STORAGE_OBJECT_CHANGED` | an object changed during the query: later ranged reads are conditional on the first read's `ETag` or generation | `execute` | `StorageError` |
| `STORAGE_IO` | a local write failed for another reason (no space, a read-only file system, a directory at the path); the message names the `errno` | `execute` | `StorageError` |
| `STORAGE_URL_REFUSED` | `http://`, an unknown scheme, a URL with user information, a glob over `https://`, and every remote URL in the first release | `bind` | `UnsupportedOperation` |
| `STORAGE_RANGE_NOT_SUPPORTED` | an `https://` server ignored `Range` | `execute` | `UnsupportedOperation` |
| `STORAGE_WRITE_UNSUPPORTED` | a `gs://`, `az://` or `https://` destination | `bind` | `UnsupportedOperation` |
| `PLAN_URL_QUERY_REFUSED` | a plan exported for a job manager has a URL with a query string | none: the export call is the job manager's milestone | `UnsupportedOperation` |
| `SQL_STATEMENT_UNSUPPORTED`, `COPY_OPTION_UNSUPPORTED`, `COPY_FORMAT_NOT_INFERRED` | decision 10 | `parse` or `bind` | `UnsupportedOperation` |

- **Refusals outside libkomira carry no step.**
  - `ENDPOINT_NOT_ALLOWED` and `OPTIMIZED_NEEDS_CREDENTIALS_MISMATCH` come only from a job manager's
    admission.
  - `CREDENTIAL_UNBOUND` and `CREDENTIAL_KIND_MISMATCH` come from both: from libkomira at step
    `bind`, and from admission.
  - `ICEBERG_STAGED_CREATE_NO_SCOPE` (from the coordinator) and `ICEBERG_LOCATION_REFUSED` are the
    Iceberg design's codes.
  - The job manager's design reports these under these codes.
- **An `access_delegation` value other than the two accepted ones** raises `ValueError` when the
  catalog object is built, before the library is called.
- **`STORAGE_*` from `NOT_FOUND` to `OBJECT_CHANGED` are the store layer's six `StoreError` kinds**,
  one to one ([src/objectstore/types.mojo](../../src/objectstore/types.mojo)). `PRECONDITION` is
  named for what it means on a read.
- **The message grammar**, after the ABI's `<step>: ` prefix, is:
  `<CODE>: <operation> <url> [status=<http status>] [provider_code=<code>] [credential=<name>] [source=<how it resolved>]`.
  For example:
  `execute: STORAGE_ACCESS_DENIED: GetObject s3://raw-events/orders/a.parquet status=403 provider_code=AccessDenied credential=raw-etl source=explicit`.
  - The credential name is not a secret, and it is the fastest answer to "who did komira think I was".
  - `source` says how `ambient` resolved: `environment`, `web-identity`, `profile`, `container`,
    `instance-metadata`, `credentials-file`, `gcloud` or `metadata-server`.
- **A message never contains:**
  - a secret, a token, a SAS or an account key;
  - a key id or a signature;
  - a URL's query string, fragment or user information;
  - a response body;
  - an environment variable's value.

  A message names a setting (`AWS_PROFILE`, `secret=`), never what it was set to. The Python message
  is the library's text unchanged, so the library's tests hold these rules.

### 12. Every SDK builds the same plan

Python, TypeScript and Mojo have the same session method, in each language's own casing:
`s.add_sql_binding(name, source)` in Python and Mojo, and `s.addSqlBinding(name, source)` in
TypeScript. Each also binds for one call: Python with keywords of `sql` and one unnamed source;
TypeScript with `s.sql(query, { orders_table })`, an object whose keys are reserved for sources; Mojo
with `session.sql(query, bindings)` and a `Dict[String, Source]`. They call the same library functions, so
one statement over the same bindings gives the same plan bytes in each. Each has the same source and
credential objects: `km.files`, `km.iceberg` and `catalog.table` in TypeScript, with
`new km.AwsKeys("raw-etl", {...})` for a credential. Each encodes a source as `WireBoundSource` and a
credential through the field calls, the library's one binder does the rest, and the DataFrame plan
builders put the same `WireSourceAccess` on their scans. The cross-SDK plan corpus
([optimized_plan_sources.md](optimized_plan_sources.md) §15.9) gains a bound-source case that asserts
byte equality.

```ts
await s.addSqlBinding("raw_orders", km.files("s3://raw-events/orders/*.parquet",
  { credential: new km.AwsKeys("raw-etl", { keyId, secret }), region: "eu-west-1" }));   // Promise<void>, as registerParquet
await s.sql("SELECT region, sum(amount) FROM raw_orders GROUP BY region");
await s.sql("SELECT count(*) FROM returns", { returns: km.files("s3://raw-events/returns/*.parquet") });
```

```mojo
session.add_sql_binding("sales_catalog", km.iceberg(uri, warehouse="prod",
    credential=km.OAuth2ClientCredentials("catalog-etl", client_id="etl", client_secret=client_secret)))
var result = session.sql("SELECT * FROM sales_catalog.sales.orders LIMIT 10")
```

### 13. What lands when

| milestone | what |
|---|---|
| first release (local only) | `COPY ... TO` a local Parquet, CSV or JSON file: `Count`, the all-or-nothing write, extension inference. `SQL_STATEMENT_UNSUPPORTED` for the refused statements. `komira_last_error_code` and `_step` (built, ABI 1.7). Every remote URL refused with `STORAGE_URL_REFUSED` |
| bindings | `komira_add_sql_binding`, `Session.add_sql_binding`, `sql` with call bindings and the unnamed source, `komira.files` for local files and frames, `BIND_NAME_UNBOUND`. `register_parquet` becomes `add_sql_binding` underneath, which fixes its re-registration defect |
| object stores | credentials and their ABI calls; `WireSourceAccess` on the wire; the S3 read arm with `ambient`; `https://` reads; the S3 write arm; GCS and Azure reads. Built: the credential calls, and the S3, Azure and GCS read arms of a bound `files` source at ABI 1.10 (S3 with `AwsKeys`, Azure with `AzureKey`, `AzureSas` or `anonymous`, GCS with `GcpToken`); not built: `ambient`, `AwsProfile`, `GcpServiceAccount`, `https://` reads and every write |
| catalogs | `komira.iceberg` and the Iceberg statements ([the Iceberg design](#reconciling-with-the-iceberg-design)) |
| DataFrame surface | the write terminals and `write_table` through `komira_plan_stream`, lifting `PLAN_WIRE_WRITE_TARGET_DROPPED`; `compression=`; readers taking `komira.files` sources |
| job manager | the resolver interface of decision 5, with its header check, kind check and endpoint allow-list; `DeclaredNeeds.credentials`; `PLAN_URL_QUERY_REFUSED` |

Every step is additive:
- new keywords with defaults and new public names;
- new ABI rows and constants;
- new optional wire fields, and a raised format version where an old reader would misread one.

## A source that fits later: a customer database

A pipeline that pulls from a customer's database fits the model without new machinery, so this design
does not design it.
- **Python.** The database is a source:
  `crm = komira.postgres("db.internal", "crm", credential=komira.Password("crm-reader", ...))`. A
  `Password` credential kind is a constant row added with it.
- **SQL.** The pipeline is a statement, with `crm` and the catalog `sales_catalog` added as bindings:
  `s.sql("INSERT INTO sales_catalog.crm.accounts SELECT * FROM crm.public.accounts")`.
- **Plan.** It carries a `WireScanBinding` of a database kind, whose params hold the host, database and
  table, and whose `access.credential` is `crm-reader`.
- **Job manager.** It resolves `crm-reader` from the customer's secret store, inside the customer's
  boundary when the row says so. It also resolves `catalog-etl` for the catalog.

## Reconciling with the Iceberg design

The Iceberg design ([komira-ai/komira#2104](https://github.com/komira-ai/komira/pull/2104), not yet
merged) conforms to this model. The changes it makes:

| Iceberg design today | under this model |
|---|---|
| `komira.session()`, `s.attach_iceberg("lake", uri=, warehouse=, auth=, access_delegation=)`, `s.catalog("lake")` | `komira.Session()`; `sales_catalog = komira.iceberg(uri, warehouse=, credential=, signing=, access_delegation=)`, a catalog of many tables, added with `s.add_sql_binding("sales_catalog", sales_catalog)`. One table is `sales_catalog.table("sales.orders")`, which can be added under a name of its own. `komira.read_table(sales_catalog, "sales.orders", as_of=)` takes the catalog object and reads no SQL binding |
| `auth=komira.BearerToken(token)`, `OAuth2ClientCredentials(client_id, client_secret, ...)`, `AwsSigV4(region, signing_name)` | the same classes take a name first, and are `credential=`. SigV4 becomes `signing=komira.SigV4(region, service)` with an AWS credential (`AMBIENT` for the chain) |
| `IcebergTableRef.catalog = 1`: a catalog name the deployment maps to an endpoint and credentials | `WireIcebergCatalog catalog = 1`: the catalog's `uri`, `warehouse` and `access` (credential name, signing). A session-local name never reaches the wire |
| "the committer hands each host the credentials for its job" | each host resolves the catalog's credential name and loads an existing table's vended credentials itself. A staged `CREATE TABLE ... AS` on several hosts writes with `data_access`, the scope covering the staged location, and is refused with `ICEBERG_STAGED_CREATE_NO_SCOPE` when none does (decision 5). No value reaches a host except through the resolver |
| `WireWriteTarget { oneof destination { path = 1; iceberg = 10 } format = 2; codec = 3 }` | the same message, plus `WireSourceAccess access = 4` for a path destination, which must be absent with `iceberg` (decision 4) |
| vended credentials, then "the session's storage options" | vended credentials, then the scope covering the file's location (decision 3). `ICEBERG_LOCATION_REFUSED` stands |
| `ICEBERG_CATALOG_NOT_ATTACHED` | `BIND_NAME_UNBOUND`, or `BIND_NOT_A_CATALOG` |
| the plan design's `km.catalog("lake")` | `komira.iceberg(...)`, the catalog object; `km.catalog(name)` is not added |
| `SQL_STATEMENT_UNSUPPORTED` for `UPDATE`, `ATTACH` and the rest | the same code, now for every refused statement, `STATEMENT_NOT_A_QUERY` included (decision 10) |
| `komira.IcebergError` | a `KomiraError`, beside `BindError`, `CredentialsError` and `StorageError` |

Its served statements (`CREATE TABLE ... AS`, `CREATE OR REPLACE TABLE ... AS`, `CREATE TABLE` with
columns, `INSERT`) and their `Count` result are decision 10's catalog row.

## What is decided elsewhere

| question | where |
|---|---|
| the ABI's run calls, status codes, last error and session-option setters | [libkomira_run_abi.md](libkomira_run_abi.md) |
| `Session`, `Result`, `KomiraError`'s fields and the rest of the error-mapping table | [python_package.md](python_package.md) |
| the write terminals' names, and the DataFrame readers | [dataframe_surface.md](dataframe_surface.md), [dataframe_surface_verbs.md](dataframe_surface_verbs.md) |
| the REST protocol, commits and pruning for catalogs | the Iceberg design ([komira-ai/komira#2104](https://github.com/komira-ai/komira/pull/2104)) |
| the job manager itself, which provides decision 5's interface | the job manager's design (later) |
| a customer database source | its own design (later) |

## What must always hold?

- No credential value is in a plan's bytes, in SQL komira produces, in `komira_plan_render`'s output,
  or in a binding's bytes. The one exception is a presigned URL's query string, which the user wrote
  into a location. Only a plan that stays in the process holds it, and the render prints only its
  digest.
- No session-local binding name is on the wire.
- A plan runs the same whether a session or a job manager binds its credential names.
- No cache answers one identity with what it read for another.
- No secret or key id appears in an error, a `repr` or a log line.
- komira reads no environment variable of its own. Only `ambient`, and `AwsProfile` for its files,
  read the providers' variables, in a local session, when a source needs them.
- On a job manager, a named credential is sent only where its secret-catalog row allows.
- A URL in a query never selects plaintext transport.
- A write is complete at its destination or absent from it.
- A `COPY` option or a write keyword is honoured or refused by name, never ignored.

## How is it tested?

This document lands without code. Each pull request that builds part of it tests that part in its own
language: Mojo tests for the library and engine, and `python_binding_test` targets for the package.
Every test is hermetic:
- the chains read `MapEnv` and `MapFiles`;
- stores are the in-memory fakes or loopback servers on port 0;
- the job-manager resolver is a fake;
- nothing reaches a cloud.

The list below names a case for every code of decision 11, and for every rule of decisions 2 to 10
that changes an answer or a refusal.

- **Binding.**
  - A CTE hides a binding of the same name.
  - Re-adding a name replaces its binding. A test that fails today holds this for `register_parquet`.
  - A call binding wins over a session binding of the same name for its statement, and the next
    statement reads the session binding again (decision 2's example).
  - Call bindings are gone after the call, both after a success and after a failure.
  - Two threads on one session, each passing a different call binding of one name, each read their
    own.
  - A call binding of a scope replaces the session scope at its location for that statement only.
  - A local file passed as a call binding that does not exist raises at the call.
  - An unused call binding with a conflicting credential value does not refuse the statement.
  - `s.sql(src, "SELECT count(*) FROM self")` reads `src`. Two unnamed sources, and an unnamed source
    beside `self=`, raise `TypeError`.
  - `sql` receives the whole session table and the call's bindings: a statement naming a binding added
    after earlier statements reads it, and a plan holds only the sources its statement uses (every string field of
    the plan is checked for the unused bindings' locations and credential names).
  - A table bound with `sales_catalog.table("sales.orders")` reads as `orders_table`, and its plan names the
    catalog's credential.
  - An unbound name gives `BIND_NAME_UNBOUND`, and the message lists the bound names (exact equality).
  - A qualified name over a file source gives `BIND_NOT_A_CATALOG`.
  - A scope named as a table gives `BIND_SCOPE_NOT_A_TABLE`.
  - The longest scope wins, and `s3://b/` does not cover `s3://b-two/`.
  - A URL under no scope gives `CREDENTIALS_NOT_FOUND`.
  - A URL with user information gives `STORAGE_URL_REFUSED`.
  - `main.orders` and `memory.main.orders` read `orders`. `raw_orders.x`, over a file binding, gives
    `BIND_NOT_A_CATALOG`.
  - Binding a frame whose plan has a write target gives `BIND_VIEW_NOT_A_QUERY`.
  - A scope bound at an existing scope's location replaces it under another name.
  - The DataFrame readers ignore SQL bindings: a scope added for SQL does not change what
    `komira.read_parquet` of a bare URL reads with.
- **Credentials.**
  - Each invalid name, and each invalid field combination, raises `ValueError` before the library is
    called.
  - `repr` shows `<set>` and no value, and `pickle.dumps` raises.
  - A source naming an unsealed credential gives `CREDENTIAL_UNBOUND`.
  - Sealing a new value under a name starts a generation: a read after it uses the new value.
  - Re-adding a binding with a new value under an existing credential name changes what every
    binding using the name reads, at a new generation. A byte-equal value keeps the generation.
  - Decision 2's example gives `CREDENTIAL_NAME_CONFLICT`, and so do two call values under one name.
  - A call value byte-equal to the session's value takes the session's generation. A different one's
    generation differs from the session's: two calls passing different tokens under a
    name no session binding uses read under two generations, and the second is not answered from the
    first's cached footer. A call value is gone after the call, and the session's value is unchanged.
  - A new session generation drops the cached entries under that name: a read after it re-reads the
    footer under the new value. A call generation leaves the session's entries in place.
  - An `AzureKey` on an `s3://` source gives `ValueError`. Through the ABI it gives
    `CREDENTIAL_KIND_MISMATCH`.
- **The plan.**
  - A plan read through `AwsKeys("raw-etl", ...)` carries `raw-etl`, its region and endpoint, and none
    of the key bytes. The test checks every byte of the encoded plan and of `komira_plan_render`.
  - The binding names `raw_orders`, `sales_catalog` and `orders_table` appear in no string field of it: every field of the decoded
    plan is checked, `WireParquetSource.name` and `WireScanBinding.name` among them.
  - `DeclaredNeeds.credentials` equals the set of names in the body.
  - Two scans of one URL under two names render, hash and digest differently.
  - An older reader refuses a plan with `access` by name.
  - One plan run by a session and by the fake job-manager resolver answers the same, and the resolver
    is asked for exactly the header's names.
  - An exported plan with a presigned URL gives `PLAN_URL_QUERY_REFUSED`.
  - Two scans of one path that differ only in the query render differently, and neither query's text
    is in the render.
  - The decoder refuses a credential name outside the grammar, an `endpoint` with user information,
    and a `WireWriteTarget` with both `iceberg` and `access`.
  - A catalog scan whose catalog vends nothing carries the covering scope's credential in
    `data_access`.
  - A staged `CREATE TABLE ... AS` on two fake hosts reaches each host's files through `data_access`.
    With no covering scope it gives `ICEBERG_STAGED_CREATE_NO_SCOPE` before any file is written, and
    no host is asked for a value.
  - Two DataFrame reader calls passing different tokens under one name read under two generations.
  - `INSERT INTO orders_table ...` over a one-table binding appends, and
    `CREATE TABLE orders_table AS ...` gives `SQL_STATEMENT_UNSUPPORTED`.
  - `x.orders` with `x` unbound gives `BIND_NAME_UNBOUND`.
  - The fake resolver refuses each of these:
    - a header that omits a name in the body (`OPTIMIZED_NEEDS_CREDENTIALS_MISMATCH`);
    - a row of the wrong kind (`CREDENTIAL_KIND_MISMATCH`);
    - a credential sent to an endpoint its row does not list, or to a plaintext or link-local one
      (`ENDPOINT_NOT_ALLOWED`).
- **Caches.**
  - One statement reading one location under two credentials, where the fake store allows only one,
    gets one answer and one `STORAGE_ACCESS_DENIED`. The denied identity is never answered from the
    other's cached footer.
- **Ambient.**
  - Each chain step answering.
  - A configured but broken step gives `CREDENTIALS_INVALID` without falling through.
  - Nothing configured gives `CREDENTIALS_NOT_FOUND`, and no region gives `STORAGE_REGION_UNKNOWN`.
  - An explicit credential other than `AwsProfile` reads no environment, which the test's `MapEnv`
    records. `AwsProfile` reads only `AWS_CONFIG_FILE`, `AWS_SHARED_CREDENTIALS_FILE` and `HOME`, never
    `AWS_PROFILE`.
  - An explicit credential with no `region=` and no profile region gives `STORAGE_REGION_UNKNOWN`, even
    when `AWS_REGION` is set.
  - `AWS_ENDPOINT_URL` is not read, and local-only use never runs a chain.
- **No leak.** Every `CREDENTIALS_*`, `CREDENTIAL_*` and `STORAGE_*` message is asserted by exact
  equality, with a known secret, token and key id in the session.
- **ABI.**
  - Unknown kinds and fields are refused, and so is defining `ambient`.
  - A secret buffer overwritten right after the call changes nothing.
  - NULL arguments give -1 and -2.
  - `komira_last_error_code` and `_step` are checked after a parse error, a bind refusal, an execute
    failure, a refusal without a code, and a success.
- **Reads.**
  - A fake S3, GCS and Azure, and a loopback TLS server, answer what the same file answers locally.
  - 403 gives `STORAGE_ACCESS_DENIED`, 404 gives `STORAGE_NOT_FOUND`, and throttling past the retries
    gives `STORAGE_THROTTLED`.
  - A refused connection and a truncated response give `STORAGE_TRANSPORT`. An untrusted certificate
    gives `STORAGE_ACCESS_DENIED`, and is trusted once `ca_file` names its authority.
  - A store reply komira cannot read gives `STORAGE_MALFORMED`.
  - An object rewritten between two ranged reads gives `STORAGE_OBJECT_CHANGED`.
  - A server that ignores `Range` gives `STORAGE_RANGE_NOT_SUPPORTED`.
  - `http://` and a glob over `https://` give `STORAGE_URL_REFUSED`.
  - A cross-origin redirect drops `Authorization`, which the loopback server records.
- **Writes.**
  - Each of the 13 pairs is read back by pyarrow and by DuckDB and equals the answer, and `Count`
    equals the number of rows.
  - Inference: `.csv`, `.json`, `.csv.gz` and `.json.zst` are inferred, and `.txt` gives
    `COPY_FORMAT_NOT_INFERRED`.
  - Each refused option gives `COPY_OPTION_UNSUPPORTED`.
  - An empty result writes a readable empty file.
  - A failure injected through the file-system seam leaves no destination file and no temporary file,
    and leaves an existing destination unchanged.
  - Writing over the file being read gives the new answer.
  - A missing parent directory gives `STORAGE_NOT_FOUND`. No space, or a directory at the path, gives
    `STORAGE_IO` with the `errno` named.
  - An S3 write that fails aborts its upload.
  - `gs://`, `az://` and `https://` destinations give `STORAGE_WRITE_UNSUPPORTED`.
  - Each statement of decision 10's refusal table gives `SQL_STATEMENT_UNSUPPORTED`.
- **SDKs.** The bound-source case of the plan corpus is byte-equal from Python, TypeScript and Mojo.

## What are the limits and open questions?

- **The GCP metadata probe.** `gcp_core`'s probe has a timeout, but its TCP connect does not. Off Google
  Cloud, with nothing configured, the first `gs://` read under `ambient` can wait for the operating
  system's connect timeout before it raises `CREDENTIALS_NOT_FOUND`. Bounding the connect is
  `gcp_core`'s fix.
- **`~` in SQL paths.** Whether DuckDB expands `~` in a `COPY` destination or a `read_parquet` path is
  checked against DuckDB by the write pull request. komira does what DuckDB does, or refuses by name.
- **In-memory data.** A frame over Arrow data the user passed (`from_arrow`) has no wire form, and
  `komira_add_sql_binding` has no case for it. It needs the engine's in-memory table call, which is not in this
  ABI yet ([dataframe_surface.md §4](dataframe_surface.md#4-readers-sessions-and-in-memory-data)).
  Until that lands, its scan raises at the terminal. A plan with one can never go to a job manager,
  and the existing `PLAN_WIRE_UNSUPPORTED_SOURCE_IN_MEMORY` refuses it.
- **Workload identity federation on Google Cloud** (`external_account` files) is refused, as `gcp_core`
  refuses it today. Azure chains and HTTP proxies are later, additive decisions.

## Options considered

- **Storage options per session, matched by prefix** (`Session(storage=[...])`, earlier drafts).
  Rejected:
  - it is a second way to bind the thing a source already describes;
  - it cannot give one statement two identities for two sources;
  - it does not reach catalogs.
- **A verb per kind** (`attach_iceberg`, `register_parquet`, `register_view`). Rejected: each new kind
  would add a verb. `register_parquet` stays only as a spelling of `add_sql_binding`, because it is
  released.
- **Only one of the two forms** (session bindings only, or call bindings only). Rejected: the owner
  asked for both. A session binding serves the tables a user reads all day, and a call binding serves
  one statement without changing them.
- **A call binding refused when a session binding has its name.** Rejected: the call is the explicit,
  local choice, and refusing it would make a user remove a session binding to run one statement.
- **For the unnamed source, `s.sql(t, "COMMAND")`**, these spellings were rejected:
  - naming the source after the caller's variable, as DuckDB's Python replacement scans do. It
    depends on frame inspection, breaks under a rename, and gives no name for an expression;
  - a `source.sql(query)` method on every source kind, which would be a second door beside
    `Session.sql`, and would not say which session runs it;
  - another fixed name (`this`, `t`, `_`). `self` is the name polars users have met *(inferred)*.
- **Session-local names on the wire** (the Iceberg design's catalog name). Rejected: a job manager
  would have to map one user's `sales_catalog` to a catalog, and two users' `sales_catalog` may differ. Credential names
  are the one name space a deployment shares: its secret store's.
- **Credential values in the plan, encrypted.** Rejected: a plan is logged, cached and digested, and a
  key to decrypt it would have to travel too.
- **Endpoints bound by name rather than carried.** Rejected: then a job manager would bind two kinds of
  name, one for endpoints and one for credentials. An endpoint is not a secret, and it is part of where
  the data is.
- **A protobuf message for credentials.** Rejected: a credential's bytes would sit in a message type the
  plan also uses, one encode away from a plan. Field calls keep values out of every message.
- **Credentials in SQL** (`CREATE SECRET`, `ATTACH ... (SECRET ...)`), as DuckDB does. Rejected: SQL text
  is logged and shared, and plans are built from it.
- **Resolving the chains in Python** (with boto3 or google-auth). Rejected: it adds dependencies, and
  expiring credentials would need a callback into Python. The chains already exist in the library.
- **`COPY` returning no rows, or the rows written.** Rejected: DuckDB answers one `Count` row.

## Where is the code?

Not built, except the engine's S3, GCS and Azure read arms: lowering carries a scan's bucket (an
Azure container) and object keys (`SourceSpecPod.parquet_fs`), and `sdk_exec.run_sql_with` reads them
through the file system an `objectstore_s3.S3ScanFs`, `objectstore_gcs.GcsScanFs` or
`azure_blob.AzureScanFs` opens on the bucket, with one footer cache keyed per bucket
([src/lowering/README.md](../../src/lowering/README.md), [src/sdk_exec/README.md](../../src/sdk_exec/README.md)).
The three credential calls of decision 8 are built ([src/so](../../src/so/README.md)), and so are
decision 1's credential objects in Python, private until `add_sql_binding` exports them
(`python/komira/_credentials.py`, sealed by `Session._seal_credential`, refused as `CredentialsError`).
Section 1's `komira.iceberg`, `catalog.table` and `komira.SigV4` are built as Python values, checked when
built and private until `add_sql_binding` exports them (`python/komira/_iceberg.py`).
`komira_add_sql_binding` is built at ABI 1.10 ([src/so](../../src/so/README.md), `bindings.mojo`):
session scope only; `WireBoundSource` (`src/plan_proto/bound_source.proto`) with its `files` arm
only; a local path, or Parquet objects (one key or a glob) of an `s3://`/`s3a://` location read with
`AwsKeys`, of an `az://`/`abfs://`/`abfss://` location read with `AzureKey`, `AzureSas` or
`anonymous`, or of a `gs://`/`gcs://` location read with `GcpToken` (its token is each call's bearer
token, over google.storage.v2 gRPC on TLS at Google's endpoint or an `https://host[:port]` endpoint
of the source's own; `so.gcs_access`), footers read through the store at the call;
`komira_sql_stream` reads those tables through `so.store_fs`, revealing the sealed values for each
statement, and refuses a statement whose `gs://` table's credential name now holds another kind
(`CREDENTIAL_KIND_MISMATCH`). It refuses by name what is not built yet: other scopes
(`BIND_SCOPE_UNSUPPORTED`), every other scheme and an `http://` endpoint on `gs://`
(`STORAGE_URL_REFUSED`), `ambient` or no credential (`CREDENTIALS_NOT_FOUND`), `anonymous` and
`AwsProfile` on S3, `anonymous` and `GcpServiceAccount` on GCS, a region or an addressing style on
GCS, Hive partitioning and a signing service (`BIND_SOURCE_UNSUPPORTED`), a scope as a table
(`BIND_SCOPE_NOT_A_TABLE`), and a second table reading a bucket with other settings
(`BIND_STORE_CONFLICT`). `register_parquet` replaces a taken name.
No other surface, wire field or error code of this design is built. The parts it builds on are:
- [src/sql](../../src/sql/sql_binder.mojo) (`sql_binder.mojo`, `sql_catalog.mojo`, `sql_parser.mojo`);
- [src/so](../../src/so/README.md);
- [src/sdk_exec](../../src/sdk_exec/README.md) (`secret_capability.mojo`, `engine_sql.mojo`,
  `engine_context.mojo`);
- [src/secret_registry](../../src/secret_registry/README.md) and [src/secrets](../../src/secrets/README.md);
- [src/plan_proto/plan.proto](../../src/plan_proto/plan.proto) and [src/plan_expr/fs_descriptor_pod.mojo](../../src/plan_expr/fs_descriptor_pod.mojo);
- [src/aws_core](../../src/aws_core/README.md) and [src/gcp_core](../../src/gcp_core/README.md);
- [src/objectstore_s3](../../src/objectstore_s3/README.md), [src/objectstore_gcs](../../src/objectstore_gcs/README.md)
  and [src/azure_blob](../../src/azure_blob/README.md);
- [src/http_client](../../src/http_client/README.md) and [src/source_url](../../src/source_url/README.md);
- [src/parquet_footers](../../src/parquet_footers) and [src/arrow/write_target.mojo](../../src/arrow/write_target.mojo).
