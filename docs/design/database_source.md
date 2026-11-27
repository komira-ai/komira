# Database sources: reading a SQLite, Postgres or MySQL table or query result

Status: design, not built. Nothing in this document exists in code unless it is marked **EXISTS**.
**PROPOSED** marks what this design adds. Statements marked *(inferred)* are reasoning, not something
read in code or in a specification. Statements marked *(to confirm)* are DuckDB, pandas or polars
behaviour that this document read from that project's documentation but has not run against the
versions komira pins: DuckDB 1.5.6 (the SQL oracle, [query_semantics_rulings.md](query_semantics_rulings.md)),
pandas 3.0.6 and polars 1.44.2 ([dataframe_surface.md](dataframe_surface.md)).

This document answers komira-ai/komira#2334. It covers reading only. Writing into a database is
komira-ai/komira#2335, and [Where reading stops and writing starts](#where-reading-stops-and-writing-starts)
draws the line.

## What a user types

SQLite, from SQL, with no binding (a local file, like `FROM 'x.parquet'`):

```sql
SELECT customer, tier FROM sqlite_scan('history.db', 'tier_history') WHERE valid_to IS NULL;
```

SQLite, bound as a database, from SQL and from the pandas-shaped skin:

```python
import komira

shop = komira.sqlite("shop.db")
with komira.Session() as s:
    s.add_sql_binding("shop", shop)
    s.sql("SELECT region, sum(cents) FROM shop.orders GROUP BY region").to_arrow()
    # the same table read as a frame, and a query result read as a frame:
    orders = komira.read_sql_table("orders", shop, columns=["id", "region", "cents"], session=s)
    big = komira.read_sql_query("SELECT id FROM orders WHERE cents > ?", shop, params=[1000], session=s)
```

Postgres, with a named credential:

```python
crm = komira.postgres(
    "db.example.com", "crm",
    credential=komira.Password("crm-reader", user="reader", password=password),
)
s.add_sql_binding("crm", crm)
s.sql("SELECT count(*) FROM crm.public.accounts WHERE region = 'eu'")
s.sql("SELECT * FROM postgres_query('crm', 'SELECT id, name FROM accounts LIMIT 10')")
```

The polars-shaped skin:

```python
import komira.pl as kpl

lf = kpl.read_database("SELECT * FROM accounts", crm, session=s)      # a LazyFrame
lf = kpl.read_database_uri("SELECT * FROM events", "sqlite:///events.db",
                           partition_on="id", partition_num=8, session=s)
```

A DuckDB script that reads a SQLite file runs unchanged: `ATTACH 'shop.db' AS shop (TYPE sqlite)`, then
`SELECT ... FROM shop.orders` (owner question 1, shared with the write design,
`database_table_write.md`). `ATTACH` and `s.add_sql_binding("shop", komira.sqlite("shop.db"))` make the same
binding. A server database is bound from the SDK only: its `ATTACH` line becomes `add_sql_binding`, and
every query after it keeps its text, the port the Iceberg design gives for a catalog
([iceberg_tables.md](iceberg_tables.md)).

The write side, komira-ai/komira#2335, is designed in `database_table_write.md` (komira-ai/komira#2451, not yet
merged). The two documents use the same source objects, credential, error class and codes, and ask
the owner the same `ATTACH` question.

## What is it for, and what is out of scope?

A user keeps data in an operational database and wants to query it with komira: join it with Parquet
files, aggregate it, or turn it into a frame. Five common tasks in [docs/tasks/catalogue.json](../tasks/catalogue.json)
need this, and all are `gap` or `partial` today:

| rank | question | status today | what this design gives |
|---|---|---|---|
| 20 | load a database query result into a DataFrame | gap | `read_sql_query`, `read_sql`, `kpl.read_database` |
| 86 | read a whole table from Postgres, MySQL or SQLite | gap | `read_sql_table`, `sqlite_scan`, `db.schema.table` |
| 87 | copy a table from one database to another | gap | the read half; the write half is komira-ai/komira#2335 |
| 90 | keep history of changing rows (slowly changing dimension) | partial | reading the history table back; changing it is komira-ai/komira#2335 |
| 91 | query a SQLite file with SQL | gap | `sqlite_scan` and a bound `komira.sqlite` |

In scope:

- Three engines, in this order: SQLite, Postgres, MySQL ([Which engines first](#which-engines-first-and-why)).
- Two shapes of read per engine: a whole table (with projection, filter and limit pushed to the
  database where that is safe), and the result of a query the user writes in the database's own SQL.
- The SQL surface (`sqlite_scan`, `postgres_query`, `mysql_query`, and bound names
  `db.schema.table`), the pandas-shaped readers (`read_sql`, `read_sql_query`, `read_sql_table`) and
  the polars-shaped readers (`read_database`, `read_database_uri`).
- Credentials for Postgres and MySQL, by name, in the model of [credentials_and_writes.md](credentials_and_writes.md).
- A column type mapping per engine, with every unmapped type refused by name.
- One consistent snapshot per scan, and parallel reads where the snapshot survives them.

Out of scope, each refused by name where a user can reach it:

- Writing into a database: `INSERT INTO db.t`, `CREATE TABLE db.t AS`, `COPY ... TO` a database,
  `to_sql`, `write_database` (komira-ai/komira#2335).
- `ATTACH` of a server database (`TYPE postgres`, `TYPE mysql`), an `ATTACH` with a connection string or a
  `SECRET`, and `USE`, `CREATE SECRET` and the `SET pg_*`, `SET mysql_*` and `SET sqlite_*` settings.
  They stay refused, as [credentials_and_writes.md decision 10](credentials_and_writes.md#10-writes)
  rules. `ATTACH` and `DETACH` of a local database file are served (owner question 1,
  [SQL surface](#sql-surface)).
- Reading a DuckDB file (`ATTACH 'x.duckdb'`, `komira.duckdb(path)`). The write design brings
  libduckdb for writing one (its question on that library); reading through it is a later slice of that
  library, not of this design.
- `postgres_scan`, `postgres_scan_pushdown`, `postgres_attach` and `sqlite_attach`: DuckDB's older
  table functions, which take a connection string or attach a database from SQL.
- Other engines: SQL Server, Oracle, DuckDB files, Snowflake, BigQuery, ODBC, ADBC drivers.
- A SQLite file at a remote URL (`s3://.../x.db`). Refused with `STORAGE_URL_REFUSED`.
- Change data capture, logical replication and streaming reads of a database (`cdc_ingest` is a
  separate package with its own scope).
- Nested and exotic column types in the first slices: arrays, composite types, ranges, enums,
  geometry, network types, intervals. Each is refused by name ([Column types](#column-types)).
- Running a database read on a job manager's hosts. The plan shape is designed here; the pin question
  is the owner's ([Questions for the owner](#questions-for-the-owner)), and the first slices run in one
  process.

## What exists today

Checked with `git ls-tree` and `git grep` on `main`.

- **EXISTS, three database libraries, none of them a query source.** `src/db`, `src/db_postgres` and
  `src/db_sqlite` are komira's own storage drivers: "Services keep durable state in tables, such as job
  queues, sessions and deployment records" ([databases.md](databases.md)). A store is written once
  against the `Database` trait and its ten structured operations. Nothing outside tests imports
  `db_postgres` or `db_sqlite`. They appear only in test files and `test_deps` (calendar, chat, contacts,
  crm and secrets tests, and `src/tests/conformance/komira_db_conformance`).
  [release/UNPUBLISHED.md](../../release/UNPUBLISHED.md) lists both as unpublished.
- **No database source anywhere.** `git grep` finds no `postgres_scan`, `sqlite_scan`, `mysql_scan`,
  `postgres_query`, `read_sql` or `read_database` in `src/`, `python/` or `node/`. The plan has no
  database scan kind. SQL parses no `ATTACH`: it fails with
  `SQL syntax error: expected keyword 'select'`, which the rank 89 probe
  (`python/docs/tasks/89-bulk-load-large-file-database/probe_native_attach.py`) records.
- **No MySQL code.** `git grep -i mysql` finds only comments (LIKE semantics), a parser refusal of
  MySQL's `LIMIT m, n`, and the catalogue question.
- **The workaround** is the database's own Python driver. Rank 90
  (`python/docs/tasks/90-keep-history-changing-rows/example.py`) builds the history rows with komira,
  takes them with `to_arrow().to_pylist()`, and inserts them with `sqlite3`. Its page says komira
  "cannot read the history table back from the database (komira-ai/komira#2334)".

What the existing drivers give a database source:

| part | where | reusable as it is? |
|---|---|---|
| libsqlite3, built from the pinned amalgamation, every symbol renamed `komira_sqlite3_*` | `third_party/sqlite/BUCK`, `//third_party/sqlite:sqlite3` | yes |
| the SQLite FFI boundary: open, prepare, step, finalize, typed column reads | `src/db_sqlite/ffi.mojo` | partly. It declares no `SQLITE_OPEN_READONLY`, no `column_double` and no `column_decltype`, and the driver opens `READWRITE \| CREATE` (`sqlite_driver.mojo`), so a missing file is created |
| SQLite row decoding | `src/db_sqlite/sqlite_driver.mojo` (`_render_cell`) | no. A float arrives as SQLite's text rendering, and a 16-byte BLOB is read as a UUID |
| Postgres connection: TCP on a reactor, SSLRequest, TLS over s2n, SCRAM-SHA-256 | `src/db_postgres/wire/connection.mojo`, `pg_tls.mojo`, `scram.mojo` | yes, with two changes: `verify_cert` defaults to `False`, and a server that refuses TLS cannot be reached at all |
| Postgres framing: `PgReadFrame`, the poll-shaped `PgQueryOp` | `src/db_postgres/wire/pg_query_op.mojo` | yes |
| Postgres values: ten OIDs (bool, bytea, int4, int8, text, varchar, jsonb, uuid, timestamptz, text[]) | `src/db_postgres/wire/pg_types.mojo`, `pg_binary.mojo` | partly. Results are fully buffered in a `List[PgRow]`; there is no COPY, no float, numeric, date, timestamp or int2 decoder, and an unknown OID reads as its raw binary bytes tagged as text |
| scan kinds, splits and the pushdown gate | `src/scan_source`, `src/scan_resolver` | yes: a database reader is one more scan kind |
| named credentials, the session's secret store, `CredentialConsumer` | `src/secret_store`, `src/secret_registry`, `src/so/credential_store.mojo` | yes |

## Which engines first, and why

**SQLite, then Postgres, then MySQL.**

1. **SQLite first.** It needs no server and no credential, so a test builds its database file in the
   test's scratch directory and every test is hermetic. The library is already pinned and linked
   (`//third_party/sqlite:sqlite3`). Its slices alone move rank 91 to `works`, and ranks 20 and 86 to
   `partial`. It also proves the parts every engine shares (the scan kind, the type-mapping refusals,
   the binding, the Python readers) on the cheapest engine.
2. **Postgres second.** It is the most-asked server engine in the catalogue's questions *(inferred from
   the ranks 22, 87 and 89 pages, which show Postgres as the second driver)*, and a large part of its
   client exists: connect, TLS, SCRAM and framing. What is missing is COPY, the binary decoders and
   streaming.
3. **MySQL third.** Nothing exists: a new client for the MySQL protocol, a new authentication method
   and a new TLS handshake. It is the most work for the same catalogue ranks, so it comes after the
   shared parts are proven twice.

## How does each engine read?

### What is Mojo and what is foreign

| engine | client | foreign code | FFI boundary |
|---|---|---|---|
| SQLite | the SQLite library, called through FFI | `libsqlite3` (C), pinned and prefixed | `src/db_sqlite/ffi.mojo`, the module that owns the library. The new read functions go there and in `sqlite_driver.mojo`, behind a pointer-free reader (rule M9) |
| Postgres | komira's own frontend/backend protocol v3 client, in Mojo | none new. TLS is s2n-tls and libcrypto is AWS-LC, through `http_core`'s existing boundary | unchanged: `http_core.tls.s2n_shim` |
| MySQL | a new client for the MySQL client/server protocol, in Mojo | none new. TLS and SHA-256 as for Postgres | unchanged |

### SQLite: through the library, not the file

**Decision: read through `libsqlite3`, never by parsing the file.** The file format is documented and
stable ([fileformat2](https://www.sqlite.org/fileformat2.html)), but a reader of committed data must
also read the `-wal` file: "the reader checks the WAL for page P first and uses the last valid committed
frame". A file separated from its WAL "might be lost, or ... corrupted"
([wal.html](https://www.sqlite.org/wal.html)). Reading the file directly means writing a second SQLite
for WAL frames, checksums, locks and the b-tree, and it would read a database that another process is
writing without SQLite's locks *(inferred)*. The library does all of that, and it is already in the
build.

What changes in `db_sqlite` (**PROPOSED**; rule M9 keeps the FFI there):

- A read-only open: `SQLITE_OPEN_READONLY` with `SQLITE_OPEN_URI`, never `CREATE`; both constants are new
  in `ffi.mojo`. A missing file is `STORAGE_NOT_FOUND`, not a new empty database.
- A WAL database opened read-only still needs its `-shm` file, readable or creatable: SQLite reads a WAL
  database read-only only when the `-shm` and `-wal` files exist or the directory is writable
  ([wal.html](https://www.sqlite.org/wal.html)). When neither holds, the open fails, and komira raises
  `STORAGE_ACCESS_DENIED`, naming the `-shm` file and that the directory is read-only. komira does not
  fall back to the `immutable` URI parameter, which would read a database another process may be
  writing as if it never changed.
- `sqlite3_column_double` and `sqlite3_column_decltype`, declared in `ffi.mojo` with `# SAFETY:` comments.
  The declared type selects the column's type ([Column types](#column-types)), and the storage class of
  each value is checked against it.
- A pointer-free `SqliteTableReader`: open, prepare one `SELECT`, step a batch of rows into Arrow
  column builders, finalize. It never exposes a statement handle (rule M1).
- The existing driver keeps its 16-byte-BLOB-as-UUID rule, because its stores depend on it. The reader
  does not share `_render_cell`.

The reader runs synchronously on a worker thread. A scan split is a blocking read, as a local file
read is today *(inferred from `db_sqlite` ignoring the reactor)*.

### Postgres: the wire protocol, `COPY ... TO STDOUT (FORMAT binary)`

**Decision: one statement per split, `COPY (SELECT <columns> FROM <table> [WHERE <pushed>]) TO STDOUT
(FORMAT binary)`, over komira's own client.** This is DuckDB's default, `pg_use_binary_copy = true`
([DuckDB 1.4 postgres extension](https://duckdb.org/docs/1.4/core_extensions/postgres)) *(to confirm for
1.5.6)*.

- **Why COPY and not a portal with a row limit.** A COPY answer is a `CopyOutResponse`, then "zero or more
  CopyData messages (always one per row), followed by CopyDone"
  ([protocol-flow](https://www.postgresql.org/docs/current/protocol-flow.html)). One row per message is
  the shape a streaming reader wants: the reader fills an Arrow batch and hands it on without holding
  the result. The existing client buffers every result in a `List[PgRow]`, which a table read cannot
  afford. A portal (`Execute` with a row limit, then `PortalSuspended`) also streams, but costs a round
  trip per batch, and its primitives exist but are unused.
- **Why binary and not text.** The binary format is the type's `*send` encoding: integers and floats are
  fixed-width big-endian, a date is a count of days from the Postgres epoch, a timestamp a count of microseconds from it, a
  numeric is base-10000 digits ([sql-copy](https://www.postgresql.org/docs/current/sql-copy.html)). Text
  output depends on session settings (`DateStyle`, `IntervalStyle`, `extra_float_digits`, `bytea_output`)
  that a server or role can change, so parsing text would have to pin each of them *(inferred)*. Binary
  values need no locale and decode in place.
- **The framing komira checks.** The 11-byte signature `PGCOPY\n\377\r\n\0`; the 32-bit flags word,
  where an unknown bit in 16 to 31 is refused (`DATABASE_PROTOCOL_UNSUPPORTED`) and bits 0 to 15 are
  ignored, as the specification says; the header extension skipped by its length; per tuple a 16-bit
  field count equal to the projected column count; per field a 32-bit length, `-1` for NULL; the
  trailer `-1`. Any other byte is `STORAGE_MALFORMED`.
- **What the client gains** (**PROPOSED**, in `db_postgres/wire`, the package that owns the protocol):
  `CopyOutResponse`, `CopyData` and `CopyDone` handling in a poll-shaped `PgCopyOutOp`; binary decoders
  for int2, float4, float8, numeric, date, time, timestamp and bpchar beside the existing ones; a
  per-column check that every OID in the answer is mapped before the first row is decoded.
- **Authentication.** SCRAM-SHA-256, which the client has, and the default of current Postgres
  servers' `password_encryption` setting *(inferred from the Postgres documentation)*.
  MD5 and cleartext password requests are refused by name (`DATABASE_AUTH_METHOD_UNSUPPORTED`, naming the
  method) in the first slices. [Questions for the owner](#questions-for-the-owner) asks about cleartext
  over TLS, which token-based cloud logins use.
- **TLS.** The source's `tls=` takes `"verify-full"` (the default: encrypt, and check the chain and the
  host name) or `"require"` (encrypt without checking, which every message then names), the same keyword
  and values as the write design ([Credentials](#how-are-credentials-passed)). Plaintext is refused
  (`DATABASE_TLS_REQUIRED`), as `pg_reactor_connect` refuses it today. The existing client's
  `verify_cert = False` default is not used by the source. A Unix-domain socket host is refused with
  the other connection-string shapes (`DATABASE_LOCATION_REFUSED`).

### MySQL: the client/server protocol, text resultset

**Decision: a new Mojo package, `mysql_wire`, speaking the MySQL client/server protocol: the v10 handshake,
the TLS upgrade, `caching_sha2_password`, and `COM_QUERY` with its text resultset.**

- **Why the text resultset for the rows.** `COM_QUERY` answers with column definitions and then one row per packet
  (the MySQL server source documentation's page on the binary resultset, `page_protocol_binary_resultset`,
  describes both). The binary resultset needs `COM_STMT_PREPARE` first, a round trip per statement, and
  a server-side statement to close *(inferred)*. The binder still uses `COM_STMT_PREPARE` once, to learn a
  query's columns without running it, and closes the statement; the rows are always read with `COM_QUERY`. MySQL's text forms are fixed by the column type, not by
  a locale: a `DECIMAL` arrives as its exact digits, a `DATE` as `YYYY-MM-DD`, a `DATETIME` as
  `YYYY-MM-DD hh:mm:ss[.ffffff]` *(inferred from the MySQL type documentation)*. A decimal read from text
  is exact, which the DECIMAL mapping needs. The binary protocol is a later, internal choice that
  changes no answer.
- **Authentication.** `caching_sha2_password`, MySQL's default. Its full authentication needs "either a
  secure connection or an unencrypted connection that supports password exchange using an RSA key pair"
  (MySQL 8.4 Reference Manual, "Caching SHA-2 Pluggable Authentication").
  komira always uses TLS for it and never the RSA exchange. `mysql_native_password` and every other
  plugin are refused by name (`DATABASE_AUTH_METHOD_UNSUPPORTED`) in the first MySQL slice.
- **TLS.** The same `tls=` keyword and values as Postgres; plaintext is refused (`DATABASE_TLS_REQUIRED`).
- **No snapshot sharing.** MySQL has no exported snapshot, so a consistent read is one connection
  ([Snapshots](#one-snapshot-per-scan)).

## How are credentials passed?

Every rule of [credentials_and_writes.md](credentials_and_writes.md) applies unchanged. That design
already sketches this source ("A source that fits later: a customer database"), and this section fills
in its fields.

**A database is a source object; a password is a named credential.** (**PROPOSED**)

| Python | what it holds |
|---|---|
| `komira.sqlite(path, *, read_only=False, busy_timeout=None)` | a local SQLite file. No credential. `path` is resolved when the source is built, as `register_parquet` resolves it. A read always opens the file read-only, whatever `read_only` says; `read_only=True` also refuses writes (`database_table_write.md`). `busy_timeout` is milliseconds |
| `komira.postgres(host, database, *, port=5432, credential, tls="verify-full")` | a server's location, the database, the TLS mode and the credential's name |
| `komira.mysql(host, database, *, port=3306, credential, tls="verify-full")` | the same for MySQL |
| `komira.Password(name, *, user, password)` | a user name and password, under a credential name |

- **These are the write design's objects, with the same signatures.** One object is both a source to
  read and a destination to write (`to_sql(con=...)`), so a user builds it once.
- **The credential is a name in the plan, never a value.** The plan carries `host`, `port`, `database`,
  the TLS mode and `access.credential = "crm-reader"`. The user name travels with the password inside
  the credential, so the plan names no database role *(a decision: a role name is not a secret, but
  keeping it with the password makes one secret-store row the whole login)*.
- **A connection URI in Python is a second spelling of the source object** (owner question 2). The
  pandas and polars readers (and `to_sql`) also accept the URI string those libraries document:
  pandas' `con` takes "a str" that SQLAlchemy reads as a database URL (`pandas.read_sql`), of the form
  `postgresql://<user>:<password>@<host>:<port>/<database>`; polars' `read_database_uri` takes
  `postgresql://<username>:<password>@<server>:<port>/<database>`, `mysql://<username>:<password>@<server>:<port>/<database>`
  and `sqlite://path` (its API reference page) *(to confirm against pandas 3.0.6 and polars 1.44.2)*.
  - The SDK parses the URI in Python. It builds exactly the source object the constructor builds:
    `komira.sqlite(path)` for `sqlite:///<path>` (and polars' `sqlite://<path>`), `komira.postgres(host,
    database, port=...)` for `postgresql://` and `postgres://` (SQLAlchemy's `+driver` suffix is
    ignored: komira uses its own driver), and `komira.mysql(...)` for `mysql://`.
  - The user and password become a `komira.Password` under a generated name, `uri.` and the first 16
    hex digits of the SHA-256 of `<scheme>://<user>@<host>:<port>/<database>`, so the name says nothing
    of the password. The SDK sends the value through the C ABI credential calls
    (`komira_credential_add`, `komira_credential_set`, `komira_credential_seal`), and the plan carries
    the location and that name only. A second URI with the same name and another password replaces the
    value at a new generation, as [decision 5](credentials_and_writes.md#5-who-binds-credential-names-to-values)
    rules. On a job manager a generated name has no secret-store row, so admission refuses it with
    `CREDENTIAL_UNBOUND`; a plan meant for a job manager names its credential with `komira.Password`.
  - The URI's `sslmode` query parameter, when present, must be `verify-full` or `require` and becomes
    `tls=`. Every other query parameter is refused by name (`DATABASE_LOCATION_REFUSED`), never ignored.
  - A URI with no password binds no credential and is refused for a server (`CREDENTIAL_UNBOUND`):
    komira reads no `~/.pgpass` and no environment.
  - What cannot be honoured: a DB-API connection (a `sqlite3.Connection`, a psycopg connection), an
    SQLAlchemy engine or connection, or an ADBC connection object. komira reads through its own drivers
    and cannot use another library's open connection. Each is refused by name with
    `UnsupportedOperation`, for example
    `read_sql(con=<sqlite3.Connection>) reads through komira's own driver: pass con="sqlite:///<path>" or con=komira.sqlite("<path>")`.
  - A URI inside SQL text stays refused: SQL is logged and carried in plans.
  - No message quotes a URI. A message names the location (`postgres://<host>:<port>/<database>`) and
    the generated credential name.
- **A host argument is not a connection string.** `komira.postgres` and `komira.mysql` raise
  `ValueError`, without quoting the value, when `host` or `database` holds `@`, `/`, `?`, `#`, `=`, a
  space or a scheme; the library refuses the same bytes again with `DATABASE_LOCATION_REFUSED`. A URI goes in
  `con` or `uri`, where the SDK splits the secret out.
- **No environment variable.** komira reads no `PGPASSWORD`, `PGHOST`, `PGUSER`, `PGDATABASE`,
  `PGSSLMODE`, `MYSQL_PWD`, `MYSQL_HOST` or `DATABASE_URL`, though DuckDB and libpq read several of
  them. Rule S2 allows provider-standard credentials (`AWS_*`, `GOOGLE_*`) and these are not provider
  credentials; everything here is a keyword of a source. There is no `~/.pgpass` read either.
- **The C ABI.** One new credential kind row, `KOMIRA_CRED_PASSWORD = 9`, with two new fields,
  `KOMIRA_FIELD_USER = 14` and `KOMIRA_FIELD_PASSWORD = 15`, the next free numbers after
  [decision 8](credentials_and_writes.md#8-the-c-abi)'s, raising the ABI minor. The value is copied into
  the session's `SecretStore` before the call returns.
- **The value reaches the client only inside a reveal.** The Postgres and MySQL sources implement
  `CredentialConsumer` (`src/secret_registry/credential_consumer.mojo`, **EXISTS**): the password is a
  `Span` that lives for one SCRAM or SHA-256 exchange and is wiped after. `PgConfig.password: String`
  is not used by the source.
- **A credential fits its source.** A `Password` on a `komira.files` location, or an `AwsKeys` on a
  `komira.postgres`, is `CREDENTIAL_KIND_MISMATCH`, at build and at bind.
- **Messages.** The write design's database form of [decision 11](credentials_and_writes.md#11-error-shapes)'s
  grammar, unchanged:
  `<CODE>: <operation> <location> [table=<t>] [column=<c>] [constraint=<n>] [sqlstate=<s>] [tls=<mode>] [credential=<name>]`,
  where `<location>` is `sqlite:<path>`, `postgres://<host>:<port>/<database>` or
  `mysql://<host>:<port>/<database>`. For example
  `execute: DATABASE_AUTH_FAILED: connect postgres://db.example.com:5432/crm sqlstate=28P01 credential=crm-reader`.
  A message never holds a password, a user name, a server's own error text (it can quote values), or a
  row.
- **Identity.** The identity of a read, for caches, is `(engine, host, port, database, credential
  name, credential generation, TLS mode)` plus the table or query. Two reads that differ in any part
  are two reads ([decision 6](credentials_and_writes.md#6-identity-and-caches)).
- **On a job manager**, `crm-reader` resolves through the customer's secret store, and the endpoint
  allow-list of [decision 5](credentials_and_writes.md#5-who-binds-credential-names-to-values) applies
  to `host:port`: a plan cannot send someone's `prod` password to a host its row does not name. This
  is the guard against a plan that points a credential at an address its author controls.

## SQL surface

DuckDB is the reference. komira takes DuckDB's table functions, its `ATTACH` of a database file and its
qualified names where they carry no credential, and refuses by name where DuckDB binds a server
database or a secret in SQL. The `ATTACH` rows are the write design's (`database_table_write.md`), so one statement has
one meaning on both sides.

| DuckDB | komira | why |
|---|---|---|
| `sqlite_scan('f.db', 't')` | served, the same signature | a local path, no credential: the same as `read_parquet('x.parquet')` |
| `ATTACH 'f.db' [AS f] (TYPE sqlite [, READ_ONLY] [, BUSY_TIMEOUT n])` then `f.t`; `DETACH f` | served, the same statement (owner question 1). It binds what `s.add_sql_binding("f", komira.sqlite("f.db", read_only=..., busy_timeout=...))` binds. Other options are refused with `DATABASE_ATTACH_OPTION_UNSUPPORTED`; with no `TYPE`, or `TYPE duckdb`, `DATABASE_KIND_UNSUPPORTED` until the DuckDB file slice | a file path carries no secret, and `COPY ... TO '<path>'` already takes a path in SQL |
| `ATTACH '<libpq string>' AS p (TYPE postgres [, READ_ONLY])`, `TYPE mysql`, `SECRET` | refused with `DATABASE_KIND_UNSUPPORTED`, which says to bind the database from the SDK: `s.add_sql_binding("p", komira.postgres(...))`, then the same `p.schema.t` | [decision 10](credentials_and_writes.md#10-writes): credentials are never bound in SQL, and a connection string can hold a password |
| `postgres_query('p', 'SELECT ...')` | served, the same signature: the first argument is the bound name | the first argument names an attached database in DuckDB too |
| `mysql_query('m', 'SELECT ...')` | served, the same signature | as `postgres_query` |
| `postgres_scan('dbname=...', 'public', 't')`, `postgres_scan_pushdown`, `postgres_attach` | refused by name, `SQL_NOT_SUPPORTED`, with the binding spelling in the message | a connection string in SQL |
| `sqlite_attach('f.db')` | refused by name, `SQL_NOT_SUPPORTED`, naming `ATTACH 'f.db' (TYPE sqlite)` | DuckDB itself deprecates it for `ATTACH` |
| `CREATE SECRET (TYPE postgres, ...)`, `SET pg_*`, `SET mysql_*`, `SET sqlite_all_varchar` | refused, `SQL_STATEMENT_UNSUPPORTED` | decision 10; each setting that changes an answer becomes a source keyword, or stays unserved |
| `postgres_execute`, `mysql_execute` | refused by name, `SQL_NOT_SUPPORTED` | they run statements that change the database (komira-ai/komira#2335's side) |

### Names in a bound database

A database binding is a catalog in the binder's sense ([decision 3](credentials_and_writes.md#3-the-binder-a-statement-and-its-bindings)):
the first part of a qualified name names the binding, and the rest is the database's to resolve.

| written | SQLite | Postgres | MySQL |
|---|---|---|---|
| `db.t` | table `t` of `main` | `t` in schema `public` *(DuckDB's default schema for an attached Postgres database; to confirm)* | `t` in the bound database |
| `db.s.t` | `s` must be `main`, else `DATABASE_TABLE_NOT_FOUND` | table `t` of schema `s` | `s` must be the bound database, else `DATABASE_TABLE_NOT_FOUND` |
| a name the database does not have | `DATABASE_TABLE_NOT_FOUND`, naming the table and the binding | the same | the same |
| a view | read as a table | read as a table | read as a table |

- Table and schema names are matched as DuckDB matches them: case-insensitively when the database has
  exactly one name that matches, and refused with `DATABASE_TABLE_AMBIGUOUS` when it has two that differ only
  in case *(to confirm against DuckDB's attached-catalog lookup)*.
- The binder reads the table's columns once, at bind, through the credential's value inside the library,
  as it reads Parquet footers. The plan holds the schema it bound against.

### Pushdown

The engine keeps the whole filter above every scan: a pushed predicate is a hint, and "the gate is a
capability to prune, not a promise of exactness" (`src/scan_resolver/scan_source_resolver.mojo`,
**EXISTS**). So a pushed predicate is correct only if the database keeps **every row komira would
keep**. Rows it keeps beyond those are removed above the scan. That one rule decides what is pushed.

| piece | pushed when | rendered as |
|---|---|---|
| projection | always | the column list of the `SELECT`, in the database's quoting (`"c"`, or `` `c` `` for MySQL) |
| `=`, `<>`, `<`, `<=`, `>`, `>=`, `IN (...)`, `IS NULL`, `IS NOT NULL`, `AND` | the column is an integer, decimal, boolean, date or timestamp, and the literal is of the column's type | a parameter or a literal of the column's type |
| the same on a text column | equality and `IN` always; ranges only under a byte-ordered collation (`C` or `POSIX` on Postgres, a `_bin` collation on MySQL, `BINARY` on SQLite) | as above |
| a float column, `OR`, `LIKE`, functions, casts | never in the first slices | stays above the scan |
| `LIMIT n` | the scan carries no filter at all and nothing above it needs an order | `LIMIT n` in the remote `SELECT`, through the execution-time `ScanRequest.limit` (**EXISTS**); the plan has no limit slot on a scan and gains none |
| `ORDER BY`, aggregates, joins | never | komira runs them |

- **Why text ranges need a byte-ordered collation.** komira and DuckDB compare strings by bytes. A
  database collation such as `en_US.UTF-8` or MySQL's `utf8mb4_0900_ai_ci` orders `'a' < 'B'`, so a
  pushed `name < 'b'` would drop `'B'`, a row komira keeps. Equality under a case-insensitive collation
  keeps more rows, never fewer, so it is safe *(inferred from the superset rule)*. A Postgres
  nondeterministic collation also only widens equality *(inferred)*.
- **Why floats wait.** NaN and `-0.0` compare differently across the three engines and komira *(inferred;
  not checked per engine)*. A float predicate stays above the scan until a slice measures them.
- **DuckDB pushes filters too**: `pg_experimental_filter_pushdown` defaults to `true` on the 1.4 Postgres
  page, and the later pages name `pg_enable_filter_pushdown` and `mysql_enable_filter_pushdown`, both
  `true` *(to confirm for 1.5.6)*.
  Pushdown never changes komira's answer, so a DuckDB setting that turns it off has no komira
  counterpart.
- **How a pushed value is written.** SQLite takes bind parameters (`?1`, `?2`). Postgres cannot: a
  `COPY (<query>)` takes no bind parameters *(inferred from the `COPY` reference, which accepts a query
  but names no parameters)*, and MySQL's `COM_QUERY` has none. So for those two komira renders each
  value as a literal of the column's type: integers and decimals as digits, dates and timestamps
  quoted from their canonical form with an explicit cast (`DATE '…'`), strings quoted with `'` doubled.
  komira sets the session so that this one rule is the whole escaping: `standard_conforming_strings = on`
  on Postgres and `sql_mode` with `NO_BACKSLASH_ESCAPES` on MySQL *(a decision: a fixed session
  setting instead of an escaper per server configuration)*.

### A query in the database's own SQL

`postgres_query('p', '<sql>')`, `mysql_query('m', '<sql>')` and the Python `read_sql_query` send the
user's text to the database as it is. komira never parses or rewrites it, pushes nothing into it, and
reads it in one split. The text is a parameter of the source in the plan: it is SQL for the database,
not komira SQL, and the job manager never parses it. The one change komira makes to it is for
`partition_on` ([Parallel reads](#parallel-reads)): each partition reads
`SELECT * FROM (<sql>) AS p WHERE <column> >= <lo> AND <column> < <hi>`, with the text inside the
parentheses unchanged ([Questions for the owner](#questions-for-the-owner)
asks the owner to confirm this reading of rule B21).

- Postgres runs it as `COPY (<sql>) TO STDOUT (FORMAT binary)` inside the scan's
  `BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY` transaction. Postgres accepts a data-changing
  statement with `RETURNING` in `COPY (...)`, so it is the read-only transaction, not `COPY`, that refuses
  a write (SQLSTATE `25006`, `DATABASE_SERVER_ERROR`).
- MySQL runs it with `COM_QUERY` inside a read-only transaction (`START TRANSACTION READ ONLY`), so a
  statement that writes is refused by MySQL. More than one result set is refused by name
  (`DATABASE_QUERY_NOT_ONE_RESULT`).
- SQLite runs it through `sqlite3_prepare_v2` on a read-only connection. A statement that writes fails
  there; text after the first statement is refused (`DATABASE_QUERY_NOT_ONE_RESULT`).
- The binder learns the result's columns without reading rows: Postgres `Describe` of a prepared
  statement, MySQL `COM_STMT_PREPARE`'s column definitions *(then closed)*, SQLite `sqlite3_column_count`
  and `column_decltype` after prepare. A SQLite expression column has no declared type, and DuckDB maps a
  column with no declared type to BLOB *(the documented mapping; to confirm for a query)*. komira does the
  same, and the user casts in the query.

## Python surface

Each skin mirrors its own library's names and arguments, and refuses an argument it cannot honour with
`UnsupportedOperation` naming the reader, the argument and the spelling that works
([dataframe_surface.md §6](dataframe_surface.md#6-how-a-skin-refuses)). No argument name is invented.
Every reader takes `session=` as a keyword, as the file readers do.

### The pandas-shaped skin: `read_sql`, `read_sql_query`, `read_sql_table`

The signatures are pandas', in pandas' order (the API reference pages `pandas.read_sql`,
`pandas.read_sql_query` and `pandas.read_sql_table`) *(read from the current pandas documentation; to
confirm against 3.0.6)*:

```python
komira.read_sql(sql, con, index_col=None, coerce_float=True, params=None, parse_dates=None,
                columns=None, chunksize=None, dtype_backend=<no_default>, dtype=None, *, session=None)
komira.read_sql_query(sql, con, index_col=None, coerce_float=True, params=None, parse_dates=None,
                      chunksize=None, dtype=None, dtype_backend=<no_default>, *, session=None)
komira.read_sql_table(table_name, con, schema=None, index_col=None, coerce_float=True,
                      parse_dates=None, columns=None, chunksize=None, dtype_backend=<no_default>,
                      *, session=None)
```

| argument | komira |
|---|---|
| `con` | a `komira.sqlite`, `komira.postgres` or `komira.mysql` source, or the connection URI pandas documents (`sqlite:///<path>`, `postgresql://<user>:<password>@<host>:<port>/<database>`, `mysql://...`), which builds the same source with its password split out ([Credentials](#how-are-credentials-passed)). These are the values `DataFrame.to_sql(con=...)` takes in `database_table_write.md`. A `sqlite3.Connection` or other DB-API connection, an SQLAlchemy engine or connection, or an ADBC connection is refused with `UnsupportedOperation`, naming the spelling that works: komira cannot read through another library's open connection |
| `sql` (`read_sql`) | pandas routes "a SQL query ... to `read_sql_query`, while a database table name will be routed to `read_sql_table`". komira does the same: a string that names a table of `con` is a table read, anything else a query |
| `table_name`, `schema`, `columns` | the table read, with `columns` as the pushed projection |
| `params` | a list or tuple of `int`, `float`, `str`, `bool`, `bytes`, `datetime.date` or `datetime.datetime`, written in the query text in the database's own placeholder (`?` for SQLite and MySQL, `$1` for Postgres). SQLite binds them; for Postgres and MySQL komira replaces each placeholder outside quotes and comments with the value written as a literal by the rule of [Pushdown](#pushdown), because `COPY` and `COM_QUERY` take no parameters. A `dict` and `None` inside it are refused in the first slices. The values are plan parameters, not secrets |
| `coerce_float` | `True` (the default) reads a DECIMAL column as `float64`, which is what pandas gives for a driver's `decimal.Decimal` *(to confirm per driver)*; `False` keeps DECIMAL. SQL (`postgres_query`, `db.t`) always keeps DECIMAL, as DuckDB does |
| `index_col` | refused unless `None`: komira frames have no index |
| `chunksize` | refused unless `None`, naming `materialize().to_reader()`, which reads the result in batches |
| `parse_dates`, `dtype` | refused unless `None` in the first slices: cast the column with `astype` |
| `dtype_backend` | refused unless left out: a frame's types are Arrow types until `to_pandas()` |

### The polars-shaped skin: `read_database`, `read_database_uri`

The signatures are polars' (the API reference pages `polars.read_database` and
`polars.read_database_uri`) *(to confirm against 1.44.2)*:

```python
kpl.read_database(query, connection, *, iter_batches=False, batch_size=None,
                  schema_overrides=None, infer_schema_length=100, execute_options=None, session=None)
kpl.read_database_uri(query, uri, *, partition_on=None, partition_range=None, partition_num=None,
                      protocol=None, engine=None, schema_overrides=None, execute_options=None,
                      pre_execution_query=None, session=None)
```

- **They return a `LazyFrame`.** The skin's rule refuses polars' eager `read_*` names in favour of the
  lazy `scan_*` spelling, but polars has no lazy database reader, so there is no `scan_*` name to point
  at. Inventing `scan_database` would be a name polars does not have. So these two names are served,
  lazily, as the one exception to the rule (owner question 5).
- `connection` takes the same values as pandas' `con` above, and so as `to_sql(con=...)`. `uri` takes
  the URIs polars documents for these engines (`postgresql://`, `mysql://`, `sqlite://`), split by the
  SDK as for `con`.
- `partition_on`, `partition_num` and `partition_range` split the read on an integer column into
  `partition_num` ranges over `partition_range` (or over the column's minimum and maximum, read first),
  as connectorx does *(to confirm against connectorx's documented split)*. komira serves them on SQLite
  and Postgres, where every partition reads one snapshot, and refuses them on MySQL
  ([Snapshots](#one-snapshot-per-scan)). A list of queries as `query` is refused: each partition must be
  the same query.
- `schema_overrides` casts the named columns after the read.
- `iter_batches`, `batch_size`, `execute_options`, `protocol`, `engine`, `pre_execution_query` and an
  `infer_schema_length` other than the default are refused unless left at their defaults. komira
  reads typed columns, so it infers nothing.

### What the frame is

A reader builds a scan of a database kind with the source's `access` field, as the file readers build
theirs, and reads the table's or query's columns when it is called, so a missing table raises at the
reader (`DATABASE_TABLE_NOT_FOUND`, a `DatabaseError`). `read_sql` decides between a table and a query
in that same call: it asks the database whether `sql` names a table, and a connection failure there
raises as for any read (`DATABASE_TRANSPORT`, `DATABASE_AUTH_FAILED`).

The two doors can give one column two types, each its reference's answer. For a Postgres column
`price numeric(10, 2)`:

| call | type of `price` |
|---|---|
| `s.sql("SELECT price FROM crm.public.items")` | DECIMAL(10,2), as DuckDB gives |
| `komira.read_sql_table("items", crm, session=s)` | DOUBLE (pandas `float64`), as pandas gives with `coerce_float=True` |
| `komira.read_sql_table("items", crm, coerce_float=False, session=s)` | DECIMAL(10,2) |

The rest of the frame's behaviour is a file reader's. Running the frame streams its batches through `komira_plan_stream`, and `to_pandas()`,
`to_polars()` and `to_arrow()` behave as for any frame. The Python package gains no driver and no new
dependency.

## Column types

The DuckDB answers in these tables are read from DuckDB's documentation. They stay *to confirm* until
slices 9 and 12 pin DuckDB's extensions for the oracle and run every row against it
([Tests](#how-is-it-tested)).

A column's type is fixed when the source is bound, from the database's declared type. The tables below
are DuckDB's documented mappings where DuckDB documents one, so that the same table gives the same
answer. **Every type not in a table is refused at bind with `DATABASE_TYPE_UNSUPPORTED`**, naming the
column and the database's own type name:

```text
bind: DATABASE_TYPE_UNSUPPORTED: column 'location' of crm.public.stores has Postgres type 'point', which komira does not read; select a cast of it in a query (postgres_query)
```

A value the mapped type cannot hold is refused when it is read, with `DATABASE_VALUE_UNREPRESENTABLE`,
naming the column and the reason, never the value.

### SQLite

From the declared type, by DuckDB's rules
([DuckDB sqlite extension](https://duckdb.org/docs/1.4/core_extensions/sqlite)) *(to confirm for 1.5.6)*:

| declared type contains | komira type |
|---|---|
| `INT` | BIGINT |
| `CHAR`, `CLOB` or `TEXT` | VARCHAR |
| `BLOB`, or no declared type | BLOB |
| `REAL`, `FLOA`, `DOUB`, `DEC` or `NUM` | DOUBLE |
| `DATE` (and not `TIME`) | DATE |
| `TIME` | TIMESTAMP |
| anything else | VARCHAR |

- SQLite stores each value with its own storage class, so a value can disagree with its column. DuckDB
  raises `Mismatch Type Error: Invalid type in column "i": column was declared as integer, found "hello"
  of type "text" instead.` komira refuses the same value by name, `DATABASE_VALUE_TYPE_MISMATCH`, naming
  the column, its declared type and the storage class found, never the value.
- DuckDB's `sqlite_all_varchar` setting, which reads every column as VARCHAR, is not served in the first
  slices; a query can cast instead (`sqlite_scan` then `CAST`, or `read_sql_query` with `CAST` in the
  SQLite text). [Questions for the owner](#questions-for-the-owner) asks whether it should become a
  source keyword.
- Which text DuckDB accepts for a DATE or TIMESTAMP column, and whether it accepts an integer there, is
  *to confirm*; komira takes DuckDB's answer once the oracle has the extension ([Tests](#how-is-it-tested)).

### Postgres

| Postgres type (OID) | komira type |
|---|---|
| `boolean` (16) | BOOLEAN |
| `smallint` (21), `integer` (23), `bigint` (20) | SMALLINT, INTEGER, BIGINT |
| `real` (700), `double precision` (701) | FLOAT, DOUBLE |
| `numeric(p, s)` (1700), p ≤ 38 | DECIMAL(p, s) |
| `numeric` with no precision, or p > 38 | DOUBLE, as DuckDB reads it *(the later DuckDB pages describe this under `pg_numeric_as_varchar = false`; to confirm for 1.5.6)* |
| `text` (25), `varchar` (1043), `bpchar` (1042), `name` (19) | VARCHAR |
| `bytea` (17) | BLOB |
| `date` (1082) | DATE |
| `time` (1083) | TIME |
| `timestamp` (1114) | TIMESTAMP |
| `timestamptz` (1184) | TIMESTAMP WITH TIME ZONE, as UTC microseconds |
| `json` (114), `jsonb` (3802) | VARCHAR, the server's text of the value *(DuckDB types these JSON, which komira has no type for; to confirm that the printed values are equal)* |

Refused by name: `uuid` (komira has no UUID type: [query_semantics_types.md](query_semantics_types.md)),
`interval`, `timetz`, `money`, every array type, enum types, composite types, range types, `inet`,
`cidr`, `macaddr`, `bit`, `varbit`, `xml`, `tsvector`, `tsquery`, `oid`, and every extension type
(`hstore`, `geometry`). DuckDB reads several of these (as UUID, INTERVAL, LIST, ENUM or VARCHAR);
each is a parity gap until komira has the type, never a silently different answer.

Values refused at read with `DATABASE_VALUE_UNREPRESENTABLE`:

- `infinity` and `-infinity` in a `date`, `timestamp` or `timestamptz` column, by the existing ruling
  that "a reader or cast that meets the text `infinity` for a DATE or TIMESTAMP column raises by name"
  ([query_semantics.md](query_semantics.md) §12.3, a REPRESENTATION DEPARTURE).
- `NaN`, `Infinity` and `-Infinity` in a `numeric` column read as DECIMAL; in a `numeric` read as
  DOUBLE they are the float values *(to confirm DuckDB's answer)*.
- A date or timestamp outside DuckDB's range (§12.4).

### MySQL

From the column definition's type and flags *(DuckDB's MySQL page documents only the boolean, time and
zero-date settings; the rest is to confirm against DuckDB 1.5.6 when the oracle can run it)*:

| MySQL type | komira type |
|---|---|
| `TINYINT(1)`, `BIT(1)` | BOOLEAN (DuckDB's `mysql_tinyint1_as_boolean` and `mysql_bit1_as_boolean`, both default `true`) |
| `TINYINT`, `SMALLINT`, `MEDIUMINT`, `INT`, `BIGINT` | TINYINT, SMALLINT, INTEGER, INTEGER, BIGINT |
| the same `UNSIGNED` | UTINYINT, USMALLINT, UINTEGER, UINTEGER, UBIGINT. A UBIGINT mixed with a signed integer in an expression is refused by the existing ruling (§8.18) |
| `FLOAT`, `DOUBLE` | FLOAT, DOUBLE |
| `DECIMAL(p, s)`, p ≤ 38 | DECIMAL(p, s) |
| `CHAR`, `VARCHAR`, `TINYTEXT` to `LONGTEXT` | VARCHAR |
| `BINARY`, `VARBINARY`, `TINYBLOB` to `LONGBLOB` | BLOB |
| `DATE` | DATE |
| `DATETIME` | TIMESTAMP |
| `TIMESTAMP` | TIMESTAMP WITH TIME ZONE, read with the session time zone set to `+00:00` |
| `YEAR` | INTEGER |
| `JSON` | VARCHAR |

Refused by name: `DECIMAL` with p > 38, `TIME` (DuckDB's `mysql_time_as_time` defaults to `false`, and
what it reads instead is to confirm), `BIT(n)` for n > 1, `ENUM`, `SET`, and the spatial types.

Values refused at read: a zero date (year, month and day all zero) or an incomplete one (month or day zero), which DuckDB reads as
NULL only with `mysql_incomplete_dates_as_nulls`, default `false` *(to confirm that the default
raises)*.

## The plan

### A new source is a scan kind, not a new arm

A database read is a `WireScanBinding` of a new kind, registered outside core, as
[optimized_plan_sources.md](optimized_plan_sources.md) §15.1.1 requires ("A source stays a scan kind,
registered outside core with no core edit"). No arm is added to `WireScanSource`.

| kind | params (tag) | access |
|---|---|---|
| `komira.sqlite.table` | `path` (STR), `table` (STR) | none: a local file |
| `komira.sqlite.query` | `path` (STR), `query` (STR), `arg.<i>` (typed, one per `params` value) | none |
| `komira.postgres.table` | `host` (STR), `port` (I64), `database` (STR), `tls` (STR), `schema` (STR), `table` (STR) | `WireScanBinding.access` |
| `komira.postgres.query` | `host`, `port`, `database`, `tls`, `query` (STR), `arg.<i>` | `WireScanBinding.access` |
| `komira.mysql.table` | `host`, `port`, `database`, `tls`, `table` (STR) | `WireScanBinding.access` |
| `komira.mysql.query` | `host`, `port`, `database`, `tls`, `query` (STR), `arg.<i>` | `WireScanBinding.access` |
| any of the six, with `partition_on` | adds `partition_column` (STR), `partition_lo` (I64), `partition_hi` (I64), `partition_num` (I64) | as the kind |

- **Every param is in identity**, and every key is permanent once a release emits it
  ([optimized_plan_sources.md](optimized_plan_sources.md) §15.11). A later option is a new optional key.
- **`access` is the credentials design's `WireScanBinding.access = 17`** (`WireSourceAccess`), holding
  only the credential name. Its `endpoint`, `region`, `addressing` and `signing_service` are empty for
  a database: the location is in the params. A plan with `access` declares envelope format version 6,
  by that design's rule, so an older reader refuses it by name instead of dropping the field.
- **`WireScanBinding.schema`** holds the columns the binder read. At execution the reader compares the
  database's columns with it and refuses a change with `DATABASE_SCHEMA_CHANGED`, naming the first
  column that differs. It never reads a renamed or retyped column under the old type.
- **The pushdown gate** is `SHAPED`, with the comparison bits and `allow_in_list` and `allow_and_recurse`
  set. The collation and float rules of [Pushdown](#pushdown) live in the kind's `classify` hook, owned by
  the kind's package, since they depend on the column's collation, which the binder reads with the
  schema. The column's collation travels as a param, `collation.<column>` (STR), so the hook reads only
  plan data.
- **Packages** (**PROPOSED**): `db_source` (the shared pieces: param keys, the type-mapping refusals, the
  pushed-`WHERE` renderer per dialect, Arrow batch building, the error codes), `db_source_sqlite`,
  `db_source_postgres`, `db_source_mysql`, and the client `mysql_wire`. The Postgres client changes land
  in `db_postgres/wire`, and the SQLite read functions in `db_sqlite`, the packages that own them.

### How it flows

1. **Bind.** The SQL binder (a `sqlite_scan` call, a qualified name under a database binding, or a
   `*_query` function) or a Python reader builds the scan binding. It connects once, reads the columns
   and collations, maps them (refusing by name), and drops the connection.
2. **Optimize.** Projection and filters are pushed into the scan as for any kind with a `SHAPED` gate.
   No optimizer rule is specific to a database *(a decision: the gate and the classify hook already
   carry every choice this design makes)*.
3. **Plan splits, at execution.** The kind's `plan_splits` (`src/scan_resolver`, **EXISTS** contract)
   opens the snapshot and cuts the splits ([Parallel reads](#parallel-reads)). This is "the execution's
   one read of the kind's store".
4. **Read.** Each split opens its connection, joins the snapshot, runs its one statement and fills Arrow
   batches of the morsel size. The engine above it applies the whole filter again.
5. **Close.** When every split has ended, or the query is cancelled, the snapshot's transaction ends and
   every connection closes. A cancelled Postgres read sends a `CancelRequest` on a new connection, the
   only way to stop a `COPY` early ([protocol-flow](https://www.postgresql.org/docs/current/protocol-flow.html)).

### One snapshot per scan

A scan returns the table as of one moment, never a mix of before and after a concurrent write.

| engine | how |
|---|---|
| SQLite | one connection runs the whole scan inside one read transaction (`BEGIN`, then the `SELECT`). In WAL mode the reader keeps its snapshot while writers commit; in rollback-journal mode its shared lock holds writers off until it ends ([wal.html](https://www.sqlite.org/wal.html)). A locked database waits up to a fixed busy timeout and then fails with `DATABASE_BUSY` *(5 seconds, the `BUSY_TIMEOUT` default on DuckDB's current SQLite page; to confirm for 1.5.6)* |
| Postgres | a coordinating connection runs `BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY` and `SELECT pg_export_snapshot()`, and stays open for the scan. Every split's connection runs `BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY` and `SET TRANSACTION SNAPSHOT '<id>'` before its `COPY`. The snapshot is "available for import only until the end of the transaction that exported it" ([functions-admin](https://www.postgresql.org/docs/current/functions-admin.html)), which is why the coordinator stays open. DuckDB describes the same scheme for its parallel Postgres scan *(to confirm for 1.5.6)* |
| MySQL | one connection, `START TRANSACTION WITH CONSISTENT SNAPSHOT, READ ONLY` at `REPEATABLE READ`. The snapshot "applies only to InnoDB" (MySQL 8.4 Reference Manual, "START TRANSACTION, COMMIT, and ROLLBACK Statements"); another storage engine reads without one, and komira says so in the scan's `EXPLAIN` *(a decision: refusing every non-InnoDB table would refuse MyISAM tables DuckDB reads)* |

- **Two scans of one database in one statement** share nothing in the first slices: a self-join reads
  the table twice, under two snapshots. On Postgres one exported snapshot could serve every scan of a
  binding in a statement; that is a later, internal change.

### Parallel reads

| engine, shape | splits |
|---|---|
| SQLite, table or query | one split. Several connections would each take their own snapshot, which breaks the rule above, and SQLite's snapshot-sharing API needs a compile option (`SQLITE_ENABLE_SNAPSHOT`) the pinned build does not set *(inferred from `third_party/sqlite/BUCK`'s flags)* |
| SQLite, `partition_on` | `partition_num` ranges on one connection, read in order: the partitions are the user's request and the answer is the same, but they do not run in parallel |
| Postgres, table | page ranges: `WHERE ctid >= '(a,0)' AND ctid < '(b,0)'`, 1000 pages per split, the last range open-ended because `relpages` is an estimate. This is DuckDB's scheme (`pg_pages_per_task = 1000`, `pg_use_ctid_scan = true`) *(to confirm for 1.5.6)*. Every split imports the exported snapshot. A view, a foreign table or a partitioned parent has no `ctid` range to cut and is read in one split *(inferred; a partitioned table's partitions are later work)* |
| Postgres, query | one split, or `partition_num` ranges with `partition_on`, each importing the snapshot |
| MySQL, table or query | one split. MySQL cannot share a snapshot between connections, so parallel splits would read different moments. `partition_on` is refused by name (`DATABASE_PARTITION_UNSUPPORTED`) |

- **Connections per scan** are bounded by the session's worker count and by a fixed cap of 8 *(a
  decision: DuckDB's cap is 64; komira starts lower so that one query cannot take a small server's
  connection slots)*. The cap is a constant, not a setting, until a user asks (rule B20).
- **Split order and results.** Splits carry no order the answer depends on: a query without `ORDER BY`
  has no defined row order, in DuckDB as in komira.

## Where reading stops and writing starts

komira-ai/komira#2335 owns every statement and call that changes a database. This design stops at the
scan. The line:

| this design (read) | komira-ai/komira#2335 (write) |
|---|---|
| `komira.sqlite`, `komira.postgres`, `komira.mysql`, `komira.Password` | the same objects, as destinations |
| `sqlite_scan`, `postgres_query`, `mysql_query`, `db.schema.table` in `FROM` | `INSERT INTO db.t`, `CREATE TABLE db.t AS`, `COPY ... TO` a database, `postgres_execute`, `mysql_execute` |
| `read_sql`, `read_sql_query`, `read_sql_table`, `kpl.read_database`, `kpl.read_database_uri` | `to_sql`, `kpl` `write_database`; the `to_sql` refusal row stays until then |
| a read-only transaction; the reader opens SQLite read-only | a write transaction and its all-or-nothing rule |
| the type mapping from the database | the type mapping into the database, and its refusals |

- Rank 87 (copy a table between databases) and rank 90 (slowly changing dimension) need both halves.
  After this design's slices they stay `partial`: the read half works, and the page shows the write
  through the database's own driver, as rank 90 does today.
- A write target for a database will be a new arm of `WireWriteTarget` with its own `access`, which
  is additive *(inferred from [credentials_and_writes.md decision 4](credentials_and_writes.md#4-the-plan-a-location-and-a-credential-name-never-a-value))*.
  Nothing in this design's plan shape blocks it.

## Errors

One error vocabulary for both sides: the codes and Python classes are the write design's
(`database_table_write.md`, section 8), and a code both sides raise has one meaning. `komira.DatabaseError` is that
design's new `KomiraError`, beside `BindError`, `CredentialsError` and `StorageError`
([python_package.md decision 9](python_package.md#9-errors)).

Codes this design shares with the write design:

| code | when, on a read | step | Python class |
|---|---|---|---|
| `DATABASE_TYPE_UNSUPPORTED` | a column's database type has no mapping ([Column types](#column-types)) | `bind` | `UnsupportedOperation` |
| `DATABASE_VALUE_UNREPRESENTABLE` | an infinite date, a NaN DECIMAL, a zero MySQL date, a value outside DuckDB's range | `execute` | `DatabaseError` |
| `DATABASE_TABLE_NOT_FOUND` | the table or schema does not exist; the message lists none of the database's other names | `bind` | `DatabaseError` |
| `DATABASE_BUSY` | a SQLite file stayed locked past the busy timeout | `bind` or `execute` | `DatabaseError` |
| `DATABASE_FILE_NOT_A_DATABASE` | the path is a file of another format | `bind` | `DatabaseError` |
| `DATABASE_KIND_UNSUPPORTED`, `DATABASE_ATTACH_OPTION_UNSUPPORTED` | `ATTACH` of a server, a connection string or a kind not built; an `ATTACH` option other than `TYPE`, `READ_ONLY` and `BUSY_TIMEOUT` | `bind` | `UnsupportedOperation` |
| `DATABASE_LOCATION_REFUSED` | a `host` or `database` argument shaped like a connection string; a URI with a scheme komira does not read, or a query parameter other than `sslmode` | `bind` | `UnsupportedOperation` |
| `DATABASE_AUTH_FAILED`, `DATABASE_AUTH_METHOD_UNSUPPORTED` | the server refused the login (Postgres SQLSTATE `28P01` or `28000`, MySQL error 1045), or offers only a method komira does not speak (`md5`, cleartext, `mysql_native_password`) | `bind` or `execute` | `CredentialsError` |
| `DATABASE_TLS_REQUIRED`, `DATABASE_TLS_VERIFY_FAILED` | the server refused TLS (Postgres `N` to `SSLRequest`, MySQL without `CLIENT_SSL`), or its certificate failed `verify-full` | `bind` or `execute` | `StorageError` |
| `DATABASE_TRANSPORT` | connect failure, reset, timeout, end of stream mid-`COPY` | `bind` or `execute` | `StorageError` |

Codes only a read raises (**PROPOSED** here; the write design's table gains them when the first read
slice lands):

| code | when | step | Python class |
|---|---|---|---|
| `DATABASE_VALUE_TYPE_MISMATCH` | a SQLite value's storage class disagrees with its column's declared type | `execute` | `DatabaseError` |
| `DATABASE_SCHEMA_CHANGED` | the table's columns differ from the ones bound | `execute` | `DatabaseError` |
| `DATABASE_TABLE_AMBIGUOUS` | a table or schema name matches two names of the database that differ only in case | `bind` | `DatabaseError` |
| `DATABASE_QUERY_NOT_ONE_RESULT` | a query text with more than one statement or result set | `bind` | `DatabaseError` |
| `DATABASE_PROTOCOL_UNSUPPORTED` | a critical COPY header flag, a MySQL capability komira needs and the server lacks | `execute` | `DatabaseError` |
| `DATABASE_PARTITION_UNSUPPORTED` | `partition_on` on MySQL, or on a column that is not an integer | `bind` | `UnsupportedOperation` |
| `DATABASE_SERVER_ERROR` | any other server error; the message carries its SQLSTATE or MySQL error number, not its text | `bind` or `execute` | `DatabaseError` |

- The DuckDB table functions komira does not serve (`postgres_scan`, `postgres_scan_pushdown`,
  `postgres_attach`, `sqlite_attach`, `postgres_execute`, `mysql_execute`) are refused by the parser's
  existing function refusal, whose `SQL not supported: ` prefix is the existing code
  `SQL_NOT_SUPPORTED` ([python_package.md decision 9](python_package.md#9-errors)). No new code is added
  for them.
- Existing codes keep their meaning: `STORAGE_NOT_FOUND` (a missing SQLite file on a read, which never
  creates one), `STORAGE_ACCESS_DENIED` (a file komira may not open, such as a WAL database's missing
  `-shm` in a read-only directory), `STORAGE_MALFORMED` (bytes komira cannot frame),
  `STORAGE_URL_REFUSED` (a SQLite file at a URL), `CREDENTIAL_KIND_MISMATCH`, `CREDENTIAL_UNBOUND`.
- A server's error text is not copied into the message, because Postgres and MySQL quote values and
  key fields in it (for example a duplicate key's value) *(inferred from their documented message
  forms)*. The SQLSTATE or error number is enough to look the error up.

## How is it tested?

Every test is hermetic (rule T12): no network, no DNS, no fixed port, no real service. The welded tests
run in the pull request's check on the farm; the integration targets below run on the farm outside it.

### SQLite: files built in the test

- Each test builds its database file in the test's scratch directory through `db_sqlite`'s own
  library calls (`CREATE TABLE`, `INSERT`), then reads it through the scan kind. No fixture file is
  committed.
- WAL mode: a test opens a writer connection in WAL mode, starts a scan, commits a write mid-scan, and
  asserts that the scan returns the rows of before the write. A second test does the same in
  rollback-journal mode and asserts the writer waits.
- Every row of the type table, every declared-type rule (including `FLOATING POINT`, which contains
  `INT` and so reads as BIGINT, as DuckDB's first-match rule gives *(to confirm)*), and every
  `DATABASE_VALUE_TYPE_MISMATCH` storage class, each asserting the full message by equality (rule T13).
- Boundary cases: an empty table; a table with only NULLs; the 64-bit integer limits; a 16-byte BLOB
  that is not a UUID; a missing file (`STORAGE_NOT_FOUND`, and the file is still missing afterwards); a
  missing table (`DATABASE_TABLE_NOT_FOUND`); two tables whose names differ only in case
  (`DATABASE_TABLE_AMBIGUOUS`); a WAL database in a read-only directory with no `-shm` file
  (`STORAGE_ACCESS_DENIED`); a locked file (`DATABASE_BUSY`, with the busy timeout injected, never waited on in
  real time, rule T10); a query with two statements.

### Postgres and MySQL: a fake server on a socketpair

- `db_postgres` already tests its client against canned replies on a socketpair, with an in-process TLS
  session using `http_core`'s throwaway test certificate (`test_pg_connection_paths`, **EXISTS**). The
  database source tests use the same shape: an in-process fake server that answers the startup, SCRAM
  and COPY messages from bytes built by the test from the protocol specification.
- The binary COPY fixtures are written by a test helper from typed values (one encoder per OID, from the
  `*send` layouts), so a fixture says what it holds. Each decoder test also has the bytes for the
  boundary values: the integer limits, `numeric` with 38 digits and with 39, NaN, the date and
  timestamp infinities, the first and last day of DuckDB's range, a NULL in every column.
- The MySQL fake answers the v10 handshake, the TLS upgrade, the `caching_sha2_password` fast and full
  paths, and a text resultset, from bytes the test builds.
- Failure cases, each with its full message: the server refuses TLS; the server asks for MD5 or
  `mysql_native_password`; wrong password; a COPY header with a critical flag; a tuple with the wrong
  field count; a connection reset mid-COPY; an unmapped OID in the `RowDescription`; a schema that
  changed between bind and execute; a cancelled scan (the fake asserts it received a `CancelRequest`);
  a snapshot import the server rejects.
- **Snapshot tests are protocol tests**: the fake records every statement each connection sends, and
  the test asserts the coordinator's export, every split's `SET TRANSACTION SNAPSHOT` with the same id
  before its `COPY`, and the coordinator's `COMMIT` only after the last split.
- **Pushdown tests** assert the exact remote SQL for each row of the pushdown table, and that a text range
  under a non-`C` collation, a float predicate and an `OR` are not pushed.

### Redaction

- A test binds a `Password` whose value is a fixed marker, runs every failing path above, and asserts by
  exact equality that no message, no rendered plan (`komira_plan_render`) and no log record contains it.
- A plan built with a `Password` credential is encoded and its bytes searched for the marker.

### What runs on the farm outside the check

- **`db_source_postgres_integration`** and **`db_source_mysql_integration`** run a pinned server from
  conda-forge packages, pinned by version and SHA-256 like every other native, started in the test's scratch directory
  with TLS on a loopback port the server is given at start. They are the write design's held interop
  run, extended with the read suites: named `*_integration` targets that run on the farm, never in the
  pull request's check (rule B9). Until they have passed, a page says the engine is checked against the
  fake only. Where they run is a question for the owner.
- One welded test drives the real TLS handshake against an in-process loopback listener on port 0, as
  the write design's fake-server suite does.
- **DuckDB parity.** The SQL oracle runs the pinned DuckDB 1.5.6 with no network, and DuckDB's `sqlite`,
  `postgres` and `mysql` extensions are not part of the pinned build *(inferred from the oracle's
  `native_libs` and its no-network rule)*. To compare answers, the extension binaries must be pinned by
  URL and SHA-256 like any other native. For SQLite that makes every type-table row a parity test:
  the same file, the same query, DuckDB's answer and komira's. For Postgres and MySQL, parity needs the
  integration servers as well. Until the extensions are pinned, the type tables stay marked *to confirm*.

### Python

- A test per reader argument row: the served values, and each refusal with its full message.
- New task pages for ranks 20, 86 and 91 (none exists today: a `gap` task has no directory) build their SQLite file with the standard library's `sqlite3`
  and read it with komira, so they run in the task check, which installs nothing but komira, pyarrow
  and protobuf. Their Postgres and MySQL fences are `not-tested`, as rank 22's Postgres fence is today.
- The rank 90 page reads its history table back with `read_sql_table`; its probe for `UPDATE` stays,
  because changing the table is komira-ai/komira#2335.

### Why this list of cases is complete

It covers every branch this design names: each engine's open, authentication method and TLS mode; each
type-table row and each refused type; each value refusal; each split shape and each snapshot step; each
pushdown row in both directions; each Python argument's served and refused values; each error code.
A case not in this list is a branch this design does not have.

## Where is the code?

Nothing is built. The packages this design adds or changes:

| package | change |
|---|---|
| `src/db_sqlite` | read-only open, `column_double`, `column_decltype`, `SqliteTableReader` |
| `src/db_postgres/wire` | `PgCopyOutOp`, binary decoders, `tls=` verification |
| `src/mysql_wire` (new) | the MySQL client |
| `src/db_source` (new) | params, type-mapping refusals, the pushed-`WHERE` renderer, batch building, error codes |
| `src/db_source_sqlite`, `src/db_source_postgres`, `src/db_source_mysql` (new) | the six scan kinds |
| `src/sql` | `sqlite_scan`, `postgres_query`, `mysql_query`; the refused names |
| `src/so` | `komira_add_sql_binding` for database sources; the `Password` credential rows |
| `python/komira` | `sqlite`, `postgres`, `mysql`, `Password`, the pandas readers, `komira.pl`'s two readers |

## Changes to other documents

This pull request adds this document only. Each change below lands with the slice that makes it true
(rule P10), so no document says something the code does not do yet:

| document | change | slice |
|---|---|---|
| [credentials_and_writes.md](credentials_and_writes.md) | "A source that fits later: a customer database" and its table row point here; the credential table gains `komira.Password`; decision 8 gains kind 9 and fields 14 and 15; decision 11 gains the database message form; decision 10's `ATTACH` refusal narrows to servers, connection strings and secrets (owner question 1; the write design makes the same correction) | 7 (`Password`), 3 (the pointer and `ATTACH`) |
| [dataframe_surface.md](dataframe_surface.md) | the module table gains `read_sql`, `read_sql_query`, `read_sql_table` and `komira.pl`'s `read_database`, `read_database_uri`; decision 1's eager-name rule names its one exception | 3 and 4 |
| [dataframe_surface_verbs.md](dataframe_surface_verbs.md) | a row per reader, built or not | 3 and 4 |
| [python_package.md](python_package.md) | decision 9's class table gains the read-only `DATABASE_*` codes beside the write design's `DatabaseError` | 2 |
| `database_table_write.md` | its error table gains the read-only codes; its `ATTACH` row names `sqlite_scan` and `SELECT` as served | 2 and 3 |
| [databases.md](databases.md) | the `db_sqlite` and `db_postgres` sections name the read functions the sources use | 1 and 6 |
| [docs/tasks/catalogue.json](../tasks/catalogue.json) | the status moves in the slice table | 2, 3, 11 |

## Decisions

Each is a case the issue does not settle, decided here with its reason.

1. **SQLite through the library, not the file**: WAL and locking make a direct reader a second SQLite.
2. **Postgres binary COPY**: one row per message streams, and binary values need no session settings.
3. **MySQL text resultset**: no prepare round trip, and exact decimal text.
4. **SQLite, then Postgres, then MySQL**: cost order, and SQLite proves the shared parts with no server.
5. **`ATTACH` of a local SQLite file is served as a spelling of `add_sql_binding`, a server `ATTACH`
   is refused**: owner question 1, shared with the write design.
6. **`postgres_scan` refused, `postgres_query` served**: the first takes a connection string, the second a
   bound name, in DuckDB as here.
7. **A password credential holds the user name too**: one secret-store row is one login.
8. **TLS is the write design's `tls="verify-full" | "require"`, default `verify-full`, plaintext refused**:
   one keyword for both sides and both engines.
9. **Pushdown keeps every row komira would keep**: text ranges need a byte-ordered collation; floats wait.
10. **`LIMIT` pushes only through `ScanRequest.limit`, only with no filter**: no wire change.
11. **The query text is a source parameter, never parsed by komira**, and read in one split.
12. **`read_database` and `read_database_uri` return a LazyFrame** in `komira.pl`, the one exception to
    the eager-name refusal, because polars has no lazy name to point at.
13. **`coerce_float=True` reads DECIMAL as float64 in the pandas skin only**: that is pandas' answer for
    drivers that return `Decimal`, and SQL keeps DuckDB's DECIMAL.
14. **SQLite reads in one split**; Postgres splits by `ctid` under one exported snapshot; MySQL reads in
    one split and refuses `partition_on`: a scan never mixes two snapshots.
15. **At most 8 connections per scan**, a constant.
16. **Every unmapped type is refused, including types DuckDB reads** (UUID, INTERVAL, arrays, enums):
    a refusal is a parity gap, a different type would be a different answer.
17. **Server error text is not copied into messages**: it can quote row values.
18. **Integration servers are the write design's held interop run**, extended with the read suites.
19. **A connection URI in Python builds the source object, its password under a generated name**:
    owner question 2, shared with the write design.
20. **Pushed values and `params` are literals on Postgres and MySQL**, bound only on SQLite: `COPY` and
    `COM_QUERY` take no parameters, and a fixed session setting makes one escaping rule complete.
21. **A read-only WAL database with no usable `-shm` is refused**, never read with `immutable`: that flag
    tells SQLite the file never changes, which hides a concurrent writer's commits.
22. **The DuckDB names komira does not serve reuse `SQL_NOT_SUPPORTED`**, the parser's existing refusal,
    instead of a new code.
23. **The query text's one rewrite is the `partition_on` subquery**: without it a partitioned query cannot
    be cut.

## Slices

Each slice is one pull request with its welded tests. A slice that changes the plan wire names its
cross-release test (rule B8).

| # | slice | tests | catalogue ranks it moves |
|---|---|---|---|
| 1 | `db_sqlite`: read-only open, `column_double`, `column_decltype`, the pointer-free `SqliteTableReader` into Arrow batches | the SQLite read tests above, without the scan kind | none |
| 2 | `db_source` and `db_source_sqlite`: the `komira.sqlite.table` kind, the type table and its refusals, one snapshot, projection pushdown; SQL `sqlite_scan(path, table)`; the `DATABASE_*` codes SQLite raises; `SQL_NOT_SUPPORTED` for the DuckDB names not served | kind and type-table tests; `sqlite_scan` SQL tests; WAL and lock tests | 91 gap → works (a SQLite file is queried with SQL); 86 gap → partial (one of its three engines) |
| 3 | `komira.sqlite` as a binding (`db.t`, `db.main.t`) and `ATTACH`/`DETACH` of a SQLite file (both shared with the write design's SQLite slice: whichever lands first builds them), the `komira.sqlite.query` kind, and the pandas readers `read_sql`, `read_sql_query`, `read_sql_table` on SQLite | binder name tests; every pandas argument row; task pages 20, 86 and 91 | 20 gap → partial (SQLite only); 87 gap → partial (the read half, from SQLite; the page writes with the target's own driver); 90 stays partial (its page reads the history back, and still changes it with `sqlite3`) |
| 4 | `kpl.read_database`, `kpl.read_database_uri` on SQLite, with `partition_on` | every polars argument row; `partition_on` gives the same rows as one read | none (20 stays partial: the polars form joins the pandas form) |
| 5 | filter and limit pushdown for SQLite, with the collation rule | the pushdown table, both directions | none |
| 6 | `db_postgres/wire`: `PgCopyOutOp`, the binary decoders, `tls=` with verification on, refusing MD5 and cleartext by name | fake-server COPY, decoder boundary and failure tests | none |
| 7 | `komira.Password` (ABI kind 9, fields 14 and 15) and `komira.postgres`, unless the write design's Postgres slice landed them first; the `komira.postgres.table` and `.query` kinds with one split; `postgres_query`; the Python readers on Postgres; redaction tests | fake-server end-to-end tests; redaction tests; ABI golden rows | none: 86 and 20 stay partial, with two engines of three; 87 stays partial, now reading Postgres too |
| 8 | Postgres parallel reads: the exported snapshot, `ctid` splits, `partition_on` | snapshot protocol tests | none |
| 9 | `db_source_postgres_integration` on the farm, and the DuckDB `sqlite` and `postgres` extensions pinned for the oracle | the parity runs | none; turns *to confirm* rows into tested ones |
| 10 | `mysql_wire`: handshake, TLS, `caching_sha2_password`, text resultset | fake-server protocol tests | none |
| 11 | `komira.mysql`, the MySQL kinds, `mysql_query`, the Python readers on MySQL; pushdown with the MySQL collation rule | fake-server end-to-end tests | 86 partial → works and 20 partial → works: both are reads, and every engine the question names now reads. 87 and 90 stay partial |
| 12 | `db_source_mysql_integration` and the DuckDB `mysql` extension pinned for the oracle | parity runs | none |

Ranks 87 and 90 move to `works` only with komira-ai/komira#2335's write half.

## Questions for the owner

Each has a recommendation; the rest of the document is written to it. Questions 1 and 2 are shared with
the write design (`database_table_write.md`, komira-ai/komira#2451), in the same words with the same
recommendation, so the owner rules once for both sides.

1. **`ATTACH` of a local database file.** Recommendation: "ATTACH 'f.db' (TYPE sqlite), and later
   (TYPE duckdb), of a local file is served as a spelling of add_sql_binding: it builds the same binding,
   a path carries no secret, and DuckDB SQL that people copy keeps working. ATTACH of a server (TYPE
   postgres, TYPE mysql), a connection string in SQL, and CREATE SECRET stay refused by name, because SQL
   text is logged and the plan never carries a secret (docs/design/credentials_and_writes.md decision 4
   and its Options considered)."
2. **Connection strings in Python.** pandas and polars take a connection URI string, with the password
   in it. Recommendation: the pandas and polars readers and `to_sql` also accept the connection URI
   string those libraries document (`read_sql(con='postgresql://...')`, `read_database_uri(query, uri)`,
   `sqlite:///path`), as a spelling that builds exactly the plan the source object builds: the SDK
   parses the URI in Python, sends the password through the C ABI credential calls
   (`komira_credential_add`, `komira_credential_set`, `komira_credential_seal`) under a generated name,
   and the plan carries the location and that name only. A URI inside SQL text stays refused. A DB-API,
   SQLAlchemy or ADBC connection object cannot be honoured, because komira has its own drivers, and is
   refused by name. This is the same reasoning as accepting `storage_options` for files: the SDK splits
   the secret out before the plan is built ([Credentials](#how-are-credentials-passed)).

The names komira invents, as opposed to mirroring pandas, polars or DuckDB, need the owner's yes. This
table is the same in both database designs:

| invented name | what it is | read design | write design |
|---|---|---|---|
| `komira.sqlite(path, *, read_only=False, busy_timeout=None)` | a SQLite file as a source and a destination | yes | yes |
| `komira.duckdb(path, *, read_only=False)` | a DuckDB file | later | yes |
| `komira.postgres(host, database, *, port=5432, credential, tls="verify-full")` | a Postgres server database | yes | yes |
| `komira.mysql(host, database, *, port=3306, credential, tls="verify-full")` | a MySQL server database | yes | yes |
| `komira.Password(name, *, user, password)` | the credential for both servers | yes | yes |
| `tls=` with `"verify-full"` and `"require"` | the TLS mode of a server source; the values are libpq's `sslmode` names | yes | yes |
| `komira.DatabaseError` | the exception class of database errors, a `KomiraError` and a `ValueError` | yes | yes |
| the `DATABASE_*` error codes | the named codes of [Errors](#errors) | yes | yes |
| `uri.<16 hex digits>` | the credential name the SDK generates for a password taken from a URI | yes | yes |
| a komira source object as `con` / `connection` | pandas' and polars' argument names, taking komira's object beside their URI strings | yes | yes |
| `kpl.read_database`, `kpl.read_database_uri` returning a `LazyFrame` | polars' names with komira's lazy result (question 5) | yes | no |

Every SQL name in both designs is DuckDB's (`ATTACH`, `DETACH`, `sqlite_scan`, `postgres_query`,
`mysql_query`, `INSERT`, `ON CONFLICT`), and every reader and writer name is pandas' or polars'. The
scan kind names (`komira.sqlite.table` and the rest) and plan params are wire names under rule B8, not
user API.
3. **The pin of a database scan in an `OptimizedPlan`.** An `OptimizedPlan` must pin every scan
   ([optimized_plan_sources.md](optimized_plan_sources.md) §15.3.3), and "a stored `OptimizedPlan` reads
   the same data forever, or is refused by name once that data is gone". A database table has no
   snapshot that outlives a transaction. Recommendation: a new `ScanPin.resolved` arm,
   `DatabasePin database = 13 { bytes schema_digest = 1; }`, whose meaning is "the rows as of a snapshot
   the host takes when the run starts; the columns are pinned". The run record holds the snapshot read
   (Postgres `pg_current_snapshot()`, a SQLite file's data version, MySQL's GTID set). This is a named
   departure from "the same data forever", limited to database kinds; the alternative is that no
   database scan ever runs on a job manager. The first slices run in one process and do not need it.
4. **The query text as a plan parameter.** Rule B21 says the job manager accepts no SQL text. The
   `query` param is the database's SQL, which komira never parses or optimizes; its one change is
   wrapping it as a subquery for `partition_on`. Recommendation: allow it, as an opaque parameter of
   the source like a file path, and keep refusing komira SQL text.
5. **`kpl.read_database` returning a LazyFrame.** Recommendation: serve polars' two names lazily, as
   decision 12 says. The alternative is a komira-own `kpl.scan_database`, a name polars does not have.
6. **Cleartext password authentication over verified TLS on Postgres**, which token logins to managed
   databases use. Recommendation: refuse it in the first slices, and add it as a later credential kind
   with its own token source.
7. **`sqlite_all_varchar` as a source keyword**, `komira.sqlite(path, all_varchar=True)`, DuckDB's
   setting name as a keyword. Recommendation: wait for a user who asks; a query can cast.
8. **Where the integration targets and the oracle's pinned extensions run**: on the farm on every merge
   to main, or on a schedule. Recommendation: on every merge to main, outside the pull request's check.
