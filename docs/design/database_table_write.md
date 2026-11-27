# Writing a query result into a database table: SQLite, Postgres, DuckDB files and MySQL

Status: design, not built. **EXISTS** names code on `main`; **PROPOSED** is new. Statements marked
*(inferred)* are the author's reasoning, not something read in code or a specification. Statements
marked *(to confirm)* are DuckDB or pandas behaviour that this document has not checked against the
pinned DuckDB (`third_party/duckdb`, v1.5.6) or a pinned pandas. The slice that builds the behaviour
checks it first. DuckDB's documentation is cited at `duckdb.org/docs/1.5`, the pinned version's, except where a
sentence says it quotes 2.0. pandas' is cited at `pandas.pydata.org/docs`.

This document answers komira-ai/komira#2335, the write side. The read side, a database table or
query as a source, is komira-ai/komira#2334. Some writes need it, and the slices below say which.

## Questions for the owner

In three places this design would make komira answer differently from both DuckDB and pandas, or
would amend a merged design. Each question has a recommendation, and the rest of the document is
written to it. A slice that depends on a question waits for the answer
([Order of work](#order-of-work)).

1. **`ATTACH` in SQL, for a database file only.** The credentials design refuses `ATTACH` in SQL:
   "sources and credentials are bound from the SDK, never in SQL, which is logged and carried in plans"
   ([credentials_and_writes.md, decision 10](credentials_and_writes.md#10-writes)). The issue, the
   rank 89 probe and DuckDB all spell a SQLite export as `ATTACH 'out.db' AS out (TYPE sqlite)`.
   Recommendation: serve `ATTACH '<path>' [AS name] [(TYPE sqlite | duckdb, READ_ONLY,
   BUSY_TIMEOUT n)]` for a local file, because a file path carries no secret, and `COPY ... TO
   '<path>'` already takes a path in SQL. Keep refusing, by name, every `ATTACH` that names a
   server (`TYPE postgres`, `TYPE mysql`), carries a connection string, or takes a `SECRET`. A
   server database is bound from the SDK, as the credentials design already sketches
   (`komira.postgres(...)`). The cost is that a DuckDB user who writes
   `ATTACH 'dbname=crm host=db' AS crm (TYPE postgres)` is told to bind it from Python instead.
2. **libduckdb for a DuckDB file.** The only writer of the DuckDB file format is DuckDB's own C++
   library. No other writer has been found, and the format has no specification. Recommendation:
   vendor DuckDB's amalgamation, pinned and prefixed like `third_party/sqlite`, and call its C API.
   Its slice comes after the SQLite and Postgres slices. It is the largest native dependency komira
   would take, and it is Linux-only until a vendored library builds for darwin-arm64
   ([Engines](#2-the-protocol-or-library-for-each-engine)). The alternative is to leave rank 92
   `partial` (SQLite files only) until that cost is accepted.
3. **`DataFrame.to_sql(name, con, ...)` takes a komira database source as `con`.** pandas takes an
   ADBC connection, an SQLAlchemy engine or connection, or a `sqlite3.Connection`
   ([pandas.DataFrame.to_sql](https://pandas.pydata.org/docs/reference/api/pandas.DataFrame.to_sql.html)).
   komira writes from its native library, so a Python driver's connection is no use to it, and an
   SQLAlchemy URL carries the password in a string. Recommendation: `con` is a source object, such as
   `komira.sqlite("out.db")` or `komira.postgres(...)`. Each pandas `con` kind is refused by name,
   with the spelling that works. The source constructors `komira.sqlite`, `komira.duckdb` and
   `komira.mysql`, and the credential `komira.Password`, are komira's names. They follow the
   `komira.postgres(host, database, *, credential=...)` that the credentials design sketches. The
   new exception class `komira.DatabaseError` is komira's too. Two smaller departures from pandas
   ride on this question. `index=True`, pandas' default, writes no column, because a komira frame
   has no index (the rule `to_csv(index=)` already follows). `DatabaseError` also derives from
   `ValueError`, so that pandas code catching the `ValueError` of `if_exists="fail"` still catches
   it.

Everything else is DuckDB's SQL or pandas' signature. Where komira cannot give DuckDB's answer, it
refuses by name (rule B21).

## What a user types

SQL, from any SDK: export a query result to a new SQLite file (rank 92), append to a table (rank 88),
and upsert (rank 85):

```sql
ATTACH 'shop.db' AS shop (TYPE sqlite);
CREATE TABLE shop.orders AS SELECT * FROM 'orders.parquet';
INSERT INTO shop.orders SELECT * FROM 'orders_new.parquet';
INSERT INTO shop.stock BY NAME SELECT sku, qty FROM 'counts.csv'
    ON CONFLICT (sku) DO UPDATE SET qty = excluded.qty;
DETACH shop;
```

Each statement is one `s.sql(...)` call. The session keeps `shop` bound between calls, as DuckDB's
connection does. Each write statement answers one row with one `BIGINT` column `Count`, the rows it
wrote.

Python, binding the same file from the SDK. This is the same binding that `ATTACH` makes:

```python
import komira

s = komira.Session()
s.add_sql_binding("shop", komira.sqlite("shop.db"))
s.sql("INSERT INTO shop.orders SELECT * FROM 'orders_new.parquet'")
```

A Postgres table. A server database is bound from the SDK only, and its password is a named
credential:

```python
crm = komira.postgres("db.example.com", "crm",
                      credential=komira.Password("crm-writer", user="etl", password=password))
s.add_sql_binding("crm", crm)
s.sql("INSERT INTO crm.public.accounts SELECT * FROM 'accounts.parquet'")
```

The DataFrame door, in pandas' spelling (rank 21):

```python
df = komira.read_parquet("orders.parquet")
n = df.to_sql("orders", komira.sqlite("shop.db"), if_exists="append")   # n: rows written
```

## What is it for, and what is out of scope?

A user writes a query result into a table of a database they already run, or into a new database
file to hand to someone else. komira computes the rows. The target database stores them, all of them
or none.

The catalogue tasks this unblocks ([docs/tasks/catalogue.json](../tasks/catalogue.json)):

| rank | task | status today | what it needs from this design |
|---|---|---|---|
| 21 | write a DataFrame to a database table | gap | `DataFrame.to_sql` |
| 22 | read a JSON file and write the records to a database | partial (`probe_native_insert.py`); also komira-ai/komira#2338 | `ATTACH`, `INSERT INTO db.t SELECT` |
| 85 | upsert rows into a database table | gap | `ON CONFLICT`, `INSERT OR REPLACE` |
| 87 | copy a table from one database to another | gap; also komira-ai/komira#2334 | a database read (komira-ai/komira#2334), then `CREATE TABLE b.t AS SELECT * FROM a.t` |
| 88 | append rows to an existing database table | gap | `INSERT INTO db.t SELECT` |
| 89 | bulk-load a large file into a database | partial (`probe_native_attach.py`) | `ATTACH`, a streamed `INSERT`, and Postgres `COPY` |
| 90 | keep history of changing rows | partial (`probe_native_update.py`); also komira-ai/komira#2334 | `UPDATE db.t ... WHERE`, which reads the table |
| 92 | export a table to a SQLite or DuckDB file | gap | `ATTACH`, `CREATE TABLE db.t AS`, a DuckDB file |

Out of scope:

- **Reading a database as a source** (`sqlite_scan`, `postgres_scan`, `SELECT ... FROM db.t`). That is
  komira-ai/komira#2334. This design names where a write needs it.
- **`MERGE INTO`, `RETURNING`, `ALTER TABLE`, `DROP TABLE`, `CREATE VIEW`, `CREATE INDEX`,
  `CREATE SCHEMA`, `COPY FROM DATABASE`, `EXPORT DATABASE`, `IMPORT DATABASE`, and `COPY db.t FROM
  '<file>'`.** Each is refused by name with `SQL_STATEMENT_UNSUPPORTED`. `INSERT INTO db.t SELECT *
  FROM '<file>'` does what `COPY ... FROM` would do.
- **Transactions across statements** (`BEGIN`, `COMMIT`, `ROLLBACK` typed by the user). Each statement
  is its own transaction ([Transactions](#6-transactions-all-rows-or-none)). Explicit transaction
  statements are refused by name.
- **Writing several databases in one statement.** DuckDB refuses that too: "the system only supports
  writing to a single attached database in a single transaction"
  ([ATTACH](https://duckdb.org/docs/1.5/sql/statements/attach)).
- **Engines other than SQLite, Postgres, DuckDB files and MySQL**, such as SQL Server, Oracle,
  Snowflake and BigQuery. MariaDB is reached only where it speaks MySQL's protocol with
  `caching_sha2_password` *(inferred)*.
- **The polars-shaped `write_database`** of `komira.pl`. It follows `to_sql` when `komira.pl` has
  sinks.
- **Distributed writes from several hosts.** A write runs in the process that runs the statement.
- **Durable komira tables.** Those are Iceberg ([iceberg_tables.md](iceberg_tables.md)). A SQLite or
  DuckDB file is an export in the target's own format, which that engine's own tools read. It is not
  a komira-only reader, so rule B21's interoperability clause holds *(inferred)*.

## What exists today

- **The SQL front end** (`src/sql/sql_parser.mojo`). It dispatches on the first keyword: `copy`,
  `create`, else a query. `INSERT`, `UPDATE`, `DELETE` and `ATTACH` reach `_expect_kw("select")` and
  fail with `ParseError: parse: SQL syntax error: expected keyword 'select' at line 1, column 1`.
  That is the line all three probes record. `CREATE [OR REPLACE] TABLE [IF NOT EXISTS] <name> AS
  <select>` parses and binds to `STMT_CREATE_TABLE_AS`, but `IF NOT EXISTS` is consumed and dropped,
  and the name is one identifier. `run_sql_with` (`src/sdk_exec/engine_sql.mojo`) refuses it with
  `STATEMENT_NOT_A_QUERY: CREATE TABLE AS writes into a catalog table, and no catalog is bound; ...`.
  A qualified table name keeps only its last part (`_parse_table_ref`).
- **The file write** (**EXISTS**). `COPY ... TO` and the Python terminals `to_parquet`, `to_csv` and
  `to_json` go through `run_plan_write` (`src/sdk_exec/engine_plan.mojo`) and `write_file_atomic`
  (`src/fs/atomic_write.mojo`): a temporary file, then a rename, all or nothing. The whole result is
  held in memory as one batch. The plan wire carries `WireWriteTarget { path, format, codec }` in
  `WirePlanEnvelope.write_target`, and its comment says an unaware reader would silently drop a
  write. That is why a write target raises `format_version`.
- **The database drivers** ([databases.md](databases.md)). They are service-state drivers, not
  export paths, and no engine package depends on them.
  - `db_sqlite` is `SqliteDatabase` over the vendored, `komira_sqlite3_`-prefixed SQLite 3.53.4
    amalgamation. It re-prepares every statement, has no bulk path, and has no float, boolean or date
    mapping.
  - `db_postgres` is a wire protocol v3 client of about 5,500 lines (`wc -l src/db_postgres/*.mojo
    src/db_postgres/wire/*.mojo`). It requires TLS, authenticates with SCRAM-SHA-256 only, and codes
    ten type OIDs in binary format. It has no float codec, no `COPY`, and no statement cache.
    `PgConfig.verify_cert` defaults to `False`, and `PgConfig.password` is a plain `String`. No test
    reaches a Postgres server.
  - There is no MySQL client and no DuckDB library.
- **Credentials** (**EXISTS** in part). The credential objects, `komira_credential_add/_set/_seal`,
  `SessionSecretStore`, `SecretValue` (move-only, zeroized, prints `SecretValue(<redacted:NB>)`) and
  `CredentialConsumer` (the reveal boundary) exist. A `Password` kind does not.
- **The Python package.** `to_sql` is refused at attribute lookup with `AttributeError:
  .to_sql() is pandas' own: run with materialize(), then call to_pandas().to_sql()`
  (`python/komira/_refusals.py`). The task pages write through the standard library's `sqlite3`
  after `to_arrow()` or `to_reader()`.
- **The DuckDB oracle.** The pinned DuckDB 1.5.6 CLI runs as a build action for conformance tests
  (`tools/build/sql`). It is test data only, and nothing ships it. The extension files `sql_oracle`
  uses are `iceberg` and `avro`. A `tpch` file is pinned for the benchmark staging only. No `sqlite`
  extension is pinned yet.

## 1. Which engines first, and why that order

| order | engine | why here |
|---|---|---|
| 1 | SQLite file | The driver and the vendored library exist. A test runs against the real library on a file in its scratch directory, which is hermetic, with no fake needed. The pages of ranks 22, 89 and 90 already show SQLite (through the standard library's `sqlite3`), rank 92 asks for it, and `ATTACH ... (TYPE sqlite)` is the issue's own reference |
| 2 | Postgres | The wire client exists, so the work is `COPY`, the missing codecs, the catalog reads and moving the password to `SecretValue`. It is the server database the pages of ranks 22 and 89 already show, under a `not-tested` fence. It needs an in-memory fake server to test |
| 3 | DuckDB file | Rank 92 needs it, but the only writer is libduckdb, a large C++ dependency (owner question 2). Its tests run the real library on a file, like SQLite |
| 4 | MySQL | There is no client, so a new wire client and fake are needed. DDL is not transactional, and `ON DUPLICATE KEY UPDATE` has no conflict target, so two of this design's rules need extra machinery there ([Transactions](#6-transactions-all-rows-or-none), [Upsert](#upsert)) |

SQLite comes first because it is the only engine whose real implementation runs inside the pull
request check, so the semantics are fixed against a real database before any fake is written.
Postgres comes before the DuckDB file because it reuses code komira already maintains, while DuckDB
adds a library komira does not have yet.

## 2. The protocol or library for each engine

No document in the tree states a "Mojo-only" rule in those words. The practice it names is this
*(read from [mojo_rules_and_toolchain.md](mojo_rules_and_toolchain.md),
[native_packaging.md](native_packaging.md) and [crypto_and_tls.md](crypto_and_tls.md))*:

- The engine and its connectors are Mojo.
- A mature C or C++ library may sit underneath. It is vendored from a sha256-pinned archive, built
  with zig's clang, every global symbol is prefixed, it is owned by exactly one `src/` library, it is
  called through `external_call` behind one safe, pointer-free module (rules M1 and M9), and it ships
  in that library's own `libkomira_<lib>_native.so.1`.
- No Python driver, no system library, no subprocess, no JVM. Rule B5 forbids a Python dependency for
  a non-Python target.

| engine | how | why it fits | what it costs to keep |
|---|---|---|---|
| SQLite | the vendored amalgamation, through `db_sqlite/ffi.mojo` (**EXISTS**), with a prepared-statement insert reused through `sqlite3_reset` (**PROPOSED**) | already vendored, prefixed and checked. It is the reference SQLite, so a file it writes is a file every SQLite reads | a version bump of one pinned archive. A new SQLite release can change type affinity edge cases. The oracle test catches those |
| Postgres | the Mojo wire client in `db_postgres/wire` (**EXISTS**), plus `COPY ... FROM STDIN (FORMAT binary)` (CopyInResponse, CopyData, CopyDone, CopyFail), binary codecs for `float4`, `float8`, `int2`, `numeric`, `date`, `time`, `timestamp`, `interval` and `json` (its binary body is the text), and the catalog queries a write needs (**PROPOSED**) | no C library at all. The protocol is version 3 and stable since Postgres 7.4 *(inferred from the protocol's version number, to confirm in the Postgres docs)*. libpq would be a second C library doing what the Mojo client already does | each binary codec is a fixed layout from the Postgres docs. `COPY` binary is "very data type specific" ([COPY](https://www.postgresql.org/docs/current/sql-copy.html)), so a codec bug is a load error, never a silent cast. About 1,000 new lines *(inferred, by analogy with `pg_binary.mojo` and `pg_types.mojo`)* |
| DuckDB file | DuckDB's amalgamation (`duckdb.cpp`, `duckdb.h`), vendored like SQLite, prefixed `komira_duckdb_`, called through its C API only (**PROPOSED**, owner question 2) | the only writer of the format. The C API catches C++ exceptions at its boundary, which is the rule for C++ libraries ("memory and exceptions must not cross") | the largest archive komira would build, a C++ runtime linked static and local as for snappy, Linux-only until a vendored library builds for darwin-arm64 ([mojo_rules_and_toolchain.md](mojo_rules_and_toolchain.md)), and a version that moves with the oracle pin. DuckDB 2.0's storage page says "DuckDB versions before 2.0 cannot read database files that use the v2.0.0 storage format" ([storage, 2.0](https://duckdb.org/docs/2.0/internals/storage)), so the pin decides who can open the file |
| MySQL | a new Mojo client of the MySQL client/server protocol: Handshake v10, SSL request and TLS through the s2n client in `komira_http`, `caching_sha2_password` full authentication over TLS, and `COM_STMT_PREPARE` and `COM_STMT_EXECUTE` with the binary row protocol (**PROPOSED**) | the same shape as the Postgres client, on the same TLS and reactor. The C client libmysqlclient is GPL-licensed with a FOSS exception *(to confirm)*, and rule R6's permissive-licence intent argues against vendoring it | a second wire client of about Postgres' size, 4,000 to 5,000 lines *(inferred)*. `caching_sha2_password` has been MySQL's default since 8.0, and 8.4 turns `mysql_native_password` off by default. A first connection for an account, or one after the server's cache is cleared, needs TLS or an RSA key exchange ([caching_sha2](https://dev.mysql.com/doc/refman/8.4/en/caching-sha2-pluggable-authentication.html)). komira takes TLS only |

The writer code that all engines share, which maps types, checks the target and streams batches
into one transaction, lives in one new library, `db_write` (**PROPOSED**). It depends on `db`, the
engine's `Sink` trait (`scan_source/sink.mojo`) and each driver. The SQL front end and `sdk_exec`
depend on `db_write`, never on a driver directly.

## 3. Credentials

The model is the credentials design's, unchanged: a source is an object the user holds, and a
credential is an object with a name. The plan carries the name, never the value
([decisions 1 and 4](credentials_and_writes.md#1-sources-are-objects-credentials-are-named-objects)).

- **A file database has no credential.** `komira.sqlite(path, *, read_only=False, busy_timeout=None)`
  and `komira.duckdb(path, *, read_only=False)`. `ATTACH` makes the same source.
- **A server database takes a `Password` credential.** `komira.postgres(host, database, *, port=5432,
  credential, tls="verify-full")` and `komira.mysql(host, database, *, port=3306, credential,
  tls="verify-full")`.
  - `komira.Password(name, *, user, password)` is a new credential kind: one constant row,
    `KOMIRA_CRED_PASSWORD`, and two field rows, `KOMIRA_FIELD_USER` and `KOMIRA_FIELD_PASSWORD`, in
    `src/so/abi/komira.tsv`. These are additive and raise the ABI minor version, as the credentials
    design's decision 8 says a new kind does.
  - Like every credential, it validates its name, shows `password` as `<set>` in `repr()`, refuses
    `pickle` and `copy`, and keeps the value a Python `str` only until the library copies it.
  - The user is in the credential, not the location, so that no message names it.
- **Configuration is arguments, never the environment** (rule S2). komira reads none of libpq's
  `PGHOST`, `PGUSER`, `PGPASSWORD`, `PGSSLMODE` or `~/.pgpass`, and none of `MYSQL_PWD` or `~/.my.cnf`.
  - The credentials design's environment list is the only one komira reads, and it holds cloud
    providers' variables only. A database password is not one of them.
  - A user who keeps a password in `PGPASSWORD` writes `password=os.environ["PGPASSWORD"]`. That is
    their code reading their environment, and the package still reads none.
- **No secret in a location.** `host` is a host name or an address. `komira.postgres` raises
  `ValueError` without quoting the value when `host` or `database` contains `@`, `/`, `?`, `#`, `=`,
  a space, or a scheme (`postgresql://`, `mysql://`). That shape is how a connection string carrying a
  password arrives. The same check runs in the library on the bound source's bytes, as
  `DB_LOCATION_REFUSED` (an `UnsupportedOperation`), so another SDK cannot skip it. The Python
  constructor's `ValueError` comes first, before the library is called.
  - `ATTACH` takes only a file path. A path that parses as a connection string is refused with
    `DB_KIND_UNSUPPORTED`, which names the `TYPE` and says to bind a server database from the SDK.
    DuckDB warns that "the full connection string, including your credentials, may appear in the
    resulting error message" ([postgres extension](https://duckdb.org/docs/1.5/core_extensions/postgres/overview)),
    and this refusal is how komira avoids that.
- **TLS.** `tls="verify-full"` is the default: encrypt, and check the certificate chain and the host
  name against the session's trust store (`Session(ca_file=...)`, **PROPOSED** in the credentials
  design's decision 9; the Postgres slice lands it if it has not landed).
  - `tls="require"` encrypts without checking. The user must name it, and every error message names
    it (`tls=require`).
  - Plaintext is refused (`DB_TLS_REQUIRED`), as `pg_reactor_connect` refuses it today.
  - `PgConfig.verify_cert` defaults to `False` today. The Postgres slice turns that default around for
    this path.
- **The password exists only where it is used.** The driver asks `SecretCapability.open_connection_for`
  (**EXISTS**) for the credential's value. A `CredentialConsumer` hands the revealed `Span` straight
  to SCRAM's `Hi()` (Postgres) or to the `caching_sha2_password` exchange (MySQL), and the value is
  wiped when the call returns. `PgConfig.password: String` is replaced by the credential's name. No
  `String` ever holds the password, so no `write_to`, error or log line can print it.
- **Messages.** The grammar follows the credentials design's decision 11:
  `<CODE>: <operation> <location> [table=<t>] [column=<c>] [constraint=<n>] [sqlstate=<s>] [tls=<mode>] [credential=<name>]`.
  - `<location>` is `sqlite:<path>`, `duckdb:<path>`, `postgres://<host>:<port>/<database>` or
    `mysql://<host>:<port>/<database>`, with no user and no password, because neither is in the
    location.
  - An engine's own error text is never copied into a message: not a server's, not
    `sqlite3_errmsg`, not libduckdb's. Postgres's `M` and `D` fields, MySQL's message, and DuckDB's
    conversion and constraint errors can quote row values (for example `Key (id)=(42) already
    exists`). komira takes the error's class and the schema, table, column and constraint names (on
    Postgres, the SQLSTATE and the `s`, `t`, `c` and `n` fields of an ErrorResponse; on SQLite, the
    extended result code) and words the message itself.
- **On a job manager.** The plan carries `postgres://host:port/database`, the table and the credential
  name. The job manager resolves the name from the customer's secret store and checks the host
  against the row's endpoint allow-list (`ENDPOINT_NOT_ALLOWED`), as the credentials design's
  decision 5 does for every source. A SQLite or DuckDB path on a job manager is a path on its host,
  as a `COPY` destination is.

## 4. The SQL and Python surface

### SQL

Every statement below is DuckDB's syntax with DuckDB's documented meaning. A form DuckDB has and
komira does not is refused by name.

| statement | DuckDB's documented behaviour | komira |
|---|---|---|
| `ATTACH '<path>' [AS name] [(TYPE sqlite\|duckdb, READ_ONLY, BUSY_TIMEOUT n)]` | attaches a database file. With no `AS`, the name is the file's base name. With no `TYPE`, the type is `duckdb`, or inferred from the file. `READ_ONLY` defaults to false ([ATTACH](https://duckdb.org/docs/1.5/sql/statements/attach), [sqlite](https://duckdb.org/docs/1.5/core_extensions/sqlite)) | served for `sqlite`, and for `duckdb` from its slice. Before that slice, no `TYPE` or `TYPE duckdb` is refused with `DB_KIND_UNSUPPORTED`. The file is opened, and created when missing unless `READ_ONLY`, when `ATTACH` runs, as DuckDB does *(to confirm)*. A source bound from the SDK (`komira.sqlite(path)`, `to_sql`) does no I/O when built, and its file is created only when a write's transaction opens, after every check that needs no rows. The name is bound on the session, which is `add_sql_binding(name, komira.sqlite(path))`. The answer is DuckDB's: no rows *(to confirm the column set)*. Other options (`SECRET`, `ENCRYPTION_KEY`, ...) are refused with `DB_ATTACH_OPTION_UNSUPPORTED`. Server types are refused (owner question 1) |
| `DETACH [DATABASE] [IF EXISTS] name` | "allows previously attached database files to be closed and detached, releasing any locks held on the database file" | served for a name `ATTACH` or `add_sql_binding` bound |
| `CREATE TABLE db.t AS <query>`, `CREATE OR REPLACE TABLE db.t AS ...`, `CREATE TABLE IF NOT EXISTS db.t AS ...` | creates the table from the query's columns and rows ([CREATE TABLE](https://duckdb.org/docs/1.5/sql/statements/create_table)). An existing table is an error, replaced, or left alone with nothing inserted | served. `IF NOT EXISTS` is recorded, where today it is dropped. An existing table gives `DB_TABLE_EXISTS` |
| `CREATE TABLE db.t (<col> <type> [NOT NULL] [PRIMARY KEY] [UNIQUE] [DEFAULT <literal>], ..., [PRIMARY KEY (...)], [UNIQUE (...)])` | creates an empty table with those constraints | served, rendered in the target's dialect. Needed so that a page can create the keyed table an upsert writes into. `CHECK`, `FOREIGN KEY`, generated columns and non-literal defaults are refused with `DB_DDL_UNSUPPORTED` |
| `INSERT INTO db.t [BY POSITION\|BY NAME] [(cols)] <query>` or `VALUES ...` | `BY POSITION` is the default. `BY NAME` matches the query's column names to the table's, and "columns that are missing from the SELECT statement will be filled with the default value" ([INSERT](https://duckdb.org/docs/1.5/sql/statements/insert)). Each value is cast to the column's type | served. The cast is komira's, with DuckDB's cast semantics. A value that does not cast fails the statement ([Types](#5-type-mapping)). The answer is `Count` |
| `INSERT OR IGNORE INTO db.t ...` | "a shorter syntax alternative to INSERT INTO ... ON CONFLICT DO NOTHING" | served, as `ON CONFLICT DO NOTHING` |
| `INSERT OR REPLACE INTO db.t ...` | "a shorter syntax alternative to INSERT INTO ... DO UPDATE SET c1 = EXCLUDED.c1, c2 = EXCLUDED.c2, ... . That is, it updates every column of the existing row to the new values of the to-be-inserted row". "If the conflict target is omitted, the PRIMARY KEY constraint(s) on the table are targeted" | served as that `ON CONFLICT (<primary key>) DO UPDATE`, never as SQLite's own `INSERT OR REPLACE`. SQLite's "deletes pre-existing rows that are causing the constraint violation prior to inserting" ([conflict](https://www.sqlite.org/lang_conflict.html)): it can delete rows that conflict on another unique key, and it fires delete cascades. What a column the insert does not name receives, its default or its old value, is DuckDB's answer *(to confirm against the pinned DuckDB)*, and the upsert test compares the whole table with the oracle's ([Upsert](#upsert)) |
| `INSERT INTO db.t ... ON CONFLICT [(cols)] DO NOTHING \| DO UPDATE SET c = excluded.c [, ...] [WHERE <cond>]` | "The DO UPDATE clause causes the INSERT to turn into an UPDATE on the conflicting row(s) instead". The conflict target is "a group of columns that an index or uniqueness/key constraint is defined on" | served on SQLite and Postgres, and on MySQL only where the rendering keeps DuckDB's meaning ([Upsert](#upsert)) |
| `UPDATE db.t SET c = <expr> [, ...] [WHERE <cond>]`, `DELETE FROM db.t [WHERE <cond>]` | change or delete the matching rows of the attached table (the sqlite extension's page lists both among its write statements, [sqlite](https://duckdb.org/docs/1.5/core_extensions/sqlite)) | served once komira-ai/komira#2334 reads the table. komira evaluates `WHERE` and `SET` itself, with DuckDB's semantics, and writes back by key ([Update and delete](#update-and-delete)). Before that, refused with `SQL_STATEMENT_UNSUPPORTED` naming komira-ai/komira#2334's form |
| `INSERT INTO t ...`, `CREATE TABLE t AS ...` with `t` unqualified and bound to nothing | DuckDB writes its own in-memory database | refused, as the credentials design says: "komira keeps no tables of its own". The message is the one-line hint `attach a database and write <db>.t` |

How a name resolves follows the credentials design's decision 3. A qualified name's first part must
be bound, and a database source is a catalog of tables.

- **SQLite.** `db.t`, or `db.main.t`.
- **Postgres.** `crm.t`, which is schema `public` as in DuckDB's postgres extension *(to confirm)*,
  or `crm.<schema>.t`.
- **One table.** `komira.sqlite("shop.db").table("orders")`, bound under a name of its own, is written
  `INSERT INTO orders ...`, as `catalog.table(...)` is for Iceberg.
- **Quoting.** Every table and column name komira writes into the target's SQL is a quoted identifier,
  with embedded quotes doubled, never spliced bare. `databases.md`'s renderer splices bare names today,
  and that path is not used here.

#### Upsert

- **The conflict target.** An explicit target must equal a primary key or a unique constraint of the
  table. komira reads the table's keys (`PRAGMA index_list` on SQLite; `pg_index` on Postgres;
  `information_schema.statistics` on MySQL). With no target, as with `OR REPLACE`, `OR IGNORE` or a
  bare `ON CONFLICT DO NOTHING`, the target is the primary key, and a table with no primary key and
  no unique constraint is refused with `DB_CONFLICT_TARGET_INVALID`. DuckDB refuses a target that is
  not a key in a binder error *(to confirm the exact condition)*.
- **A key twice in one statement.** Postgres raises "a cardinality violation"
  ([INSERT](https://www.postgresql.org/docs/current/sql-insert.html)), while SQLite applies the rows
  one after another. DuckDB 2.0's page says it "applies only one update per conflicting key"
  ([INSERT, 2.0](https://duckdb.org/docs/2.0/sql/statements/insert)). The 1.5 page says nothing,
  and DuckDB 1.1.3 raises a constraint error instead *(to confirm against the
  pinned 1.5.6)*. komira does what the pinned DuckDB does. If that is an error, komira refuses with
  `DB_CONFLICT_KEY_REPEATED`, naming the columns but never the value, and rolls back.
  - The check streams. An upsert keeps the set of conflict keys it has written in this statement
    (memory in proportion to the key columns of the rows, not to the rows). So an upsert is the one
    write whose memory grows with its row count, and the page for rank 85 says so. On Postgres, the
    server's own cardinality violation also catches it, inside the one `INSERT ... SELECT`.
- **Rendering.** SQLite and Postgres get `INSERT ... ON CONFLICT (<target>) DO UPDATE SET ... [WHERE
  ...]`, with `excluded.` as in DuckDB. On SQLite, a `SELECT` source always carries a `WHERE`, "even
  if that WHERE clause is just 'WHERE true'" ([upsert](https://www.sqlite.org/lang_upsert.html)). The
  rows travel as bound parameters or a staging table, never as SQL text. On Postgres, the rows are
  copied into `CREATE TEMP TABLE _komira_<16 hex digits> (LIKE <target> INCLUDING DEFAULTS) ON COMMIT
  DROP` with `COPY`, cast by komira to the target's column types first, and then upserted with one
  `INSERT INTO <target> (<given columns>) SELECT ... ON CONFLICT` in the same transaction. The
  columns `BY NAME` leaves out are not in the column list, so they take their defaults. A role
  without `TEMP` on the database fails with `DB_PRIVILEGE_DENIED`.
- **MySQL.** `ON DUPLICATE KEY UPDATE` fires on any unique index
  ([insert-on-duplicate](https://dev.mysql.com/doc/refman/8.4/en/insert-on-duplicate.html)). komira
  renders it, with the row alias form `VALUES (...) AS new ON DUPLICATE KEY UPDATE c = new.c`, only
  when the table has exactly one unique key and it is the target. Otherwise it refuses
  with `DB_CONFLICT_TARGET_INVALID`, because MySQL would update on a key the statement did not name.
  A `DO UPDATE ... WHERE` is refused there, as MySQL has no such clause.

#### Update and delete

`UPDATE` and `DELETE` must answer as DuckDB does, and the target database's own expression
semantics differ: integer division, text collation, and `NULL` in `IN` lists *(inferred from
[query_semantics.md](query_semantics.md))*. So komira does not pass the `WHERE` through as text.

- komira reads the table through komira-ai/komira#2334's source, evaluates `WHERE` and `SET` in its
  own engine, and writes back by key in one transaction: `UPDATE ... WHERE rowid = ?` on SQLite,
  or by primary key on Postgres and MySQL.
- A table with no key (no `rowid`, as a `WITHOUT ROWID` table has none, and no primary key) is
  refused with `DB_TABLE_KEY_REQUIRED`.
- The table is locked against other writers before it is read, and stays locked until the commit,
  so no other writer changes a row between the read and the write-back. On SQLite, the write's
  `BEGIN IMMEDIATE` is taken first, and the read runs after it on another connection, which sees the
  committed table that no one else can now change. On Postgres, the write's transaction takes `LOCK
  TABLE <t> IN SHARE ROW EXCLUSIVE MODE` first, which blocks other writers and lets readers through.
  The read then runs on the source's own connection *(inferred: the lock's conflict table is in the
  Postgres docs, to confirm)*. MySQL's slice refuses `UPDATE` and `DELETE` by name until it has the
  same guarantee.
- The engine reads the whole result before the first write-back, the same rule as any statement
  that reads the table it writes ([Transactions](#6-transactions-all-rows-or-none)).

### Python

`DataFrame.to_sql`, pandas' signature
([pandas.DataFrame.to_sql](https://pandas.pydata.org/docs/reference/api/pandas.DataFrame.to_sql.html)):
`to_sql(name, con, *, schema=None, if_exists="fail", index=True, index_label=None, chunksize=None,
dtype=None, method=None) -> int`. Following the DataFrame design's policy
([dataframe_surface.md §6](dataframe_surface.md#6-how-a-skin-refuses)), a value komira cannot honour
raises `UnsupportedOperation`, naming the argument, its value and the spelling that works, before
the library is called.

| argument | pandas' documented behaviour | komira |
|---|---|---|
| `name` | the table name | the same. It is written as a quoted identifier |
| `con` | "ADBC connection, sqlalchemy.engine.(Engine or Connection) or sqlite3.Connection" | a komira database source: `komira.sqlite(...)`, `komira.postgres(...)`, and later `komira.duckdb(...)` and `komira.mysql(...)` (owner question 3). A `sqlite3.Connection`, an SQLAlchemy engine or connection, an ADBC connection or a `str` is refused with `UnsupportedOperation`, for example `to_sql(con=<sqlite3.Connection>) writes through komira's own driver: pass con=komira.sqlite("<path>")`. A `str` would carry a password in a URL |
| `schema` | the schema to write into | Postgres: the schema. SQLite and DuckDB: `None` or `"main"`. Anything else is refused |
| `if_exists` | `'fail'` ("Raise a ValueError"), `'replace'` ("Drop the table before inserting new values"), `'append'`, `'delete_rows'` ("If a table exists, delete all records and insert data") | all four. `'fail'` is `CREATE TABLE`, `'replace'` is `CREATE OR REPLACE TABLE ... AS`, `'append'` is `INSERT INTO`, and creates the table when it is missing, as pandas does (wire mode `APPEND_OR_CREATE`, the create and the insert in one transaction). `'delete_rows'` is `DELETE FROM` then `INSERT` in one transaction, and creates a missing table the same way (`DELETE_ROWS_OR_CREATE`) *(to confirm pandas' behaviour on a missing table)*. `'fail'` on an existing table raises `komira.DatabaseError` with `DB_TABLE_EXISTS`. That class also derives from `ValueError`, so pandas code that catches `ValueError` still catches it |
| `index` | "Write DataFrame index as a column" | accepted, and it writes no column, because a komira frame has no index. This is `to_csv(index=)`'s rule (**EXISTS**) |
| `index_label` | the index column's name | `None` only. Anything else is refused, as there is no index to label |
| `chunksize` | "the number of rows in each batch to be written to the database connection at a time" | `None` or a positive `int`: the rows in each insert batch. Every batch is in the one transaction, so it changes speed, not the result |
| `dtype` | a column-to-SQL-type mapping (SQLAlchemy types, or strings in sqlite3 mode) | `None` only in the first slices. A mapping is refused, naming the spelling that works: create the table with `CREATE TABLE db.t (...)` and use `if_exists="append"` |
| `method` | `None` ("one per row"), `'multi'` ("multiple values in a single INSERT clause"), or a callable | `None` and `'multi'` are accepted, and komira picks the statement shape (a reused prepared insert, or `COPY`). Both write the same rows. A callable is refused: it would run Python on rows komira never hands to Python |
| return | "Number of rows affected", or `None` | the `Count` the write answers, an `int` |

The frame's plan goes through `komira_plan_stream` with the database write target set
([The plan](#7-the-plan-and-the-engine)). `to_sql` is removed from `_refusals.FRAME` in the slice that
builds it. The plan-layer lint that flags a function named `to_sql` (`sql_names`, in
`python/tests/test_ops_no_sql.py`) inspects plan modules, not `_frame.py`. The slice confirms that
before naming the method *(to confirm)*.

`Session.sql` runs `ATTACH`, `DETACH` and the write statements, and returns the `Count` result like
any query. A `Result` has no write method, which is unchanged.

## 5. Type mapping

The mapping is from komira's logical types, which are DuckDB's, to the target's column types. For
`CREATE TABLE ... AS`, the target type is the one the mapping names. For `INSERT` into an existing
table, komira first reads each column's type back as a komira type, then casts the value to it with
DuckDB's cast rules, and a failed cast fails the statement.

- **Reading an existing column's type back.**
  - Postgres and MySQL: the reverse of the table below. `varchar(n)`, `char(n)` and `bpchar` read as
    `VARCHAR`, and a value longer than `n` is the server's error (SQLSTATE 22001), reported as
    `DB_VALUE_UNREPRESENTABLE`. Enums, domains and composite types are refused with
    `DB_TYPE_UNSUPPORTED` in the first slices.
  - SQLite: a declared type is free text, so it reads as DuckDB's sqlite extension reads it. That
    extension says it "follows SQLite's type affinity rules with a few extensions": `INT` gives
    `BIGINT`; `CHAR`, `CLOB` or `TEXT` gives `VARCHAR`; `BLOB` or no type gives `BLOB`; `REAL`,
    `FLOA` or `DOUB` gives `DOUBLE`; and `DATE`, `TIMESTAMP` and the other extensions read as their
    DuckDB types *(to confirm the full list against the extension's source)*.
  - Each rule is settled by the oracle, which runs DuckDB's `INSERT` into a hand-made table. A type the target cannot hold is refused by name before any row is written:
`DB_TYPE_UNSUPPORTED: CREATE TABLE sqlite:shop.db table=t column=c type=HUGEINT: SQLite has no
128-bit integer; cast the column to DOUBLE or VARCHAR`.

| komira (DuckDB) type | SQLite: declared type, storage class | Postgres | DuckDB file | MySQL |
|---|---|---|---|---|
| `BOOLEAN` | `BOOLEAN`, integer 0 or 1 *(to confirm)* | `boolean` | the same | `TINYINT(1)` |
| `TINYINT`, `SMALLINT`, `INTEGER`, `BIGINT` | `TINYINT` ... `BIGINT`, integer | `smallint` (`TINYINT` widened), `smallint`, `integer`, `bigint` | the same | the same |
| `UTINYINT`, `USMALLINT`, `UINTEGER` | `INTEGER`, integer | `smallint`, `integer`, `bigint` (widened, as each fits) | the same | `TINYINT UNSIGNED` ... `INT UNSIGNED` |
| `UBIGINT` | refused: SQLite's integer is signed 64-bit ([datatypes](https://www.sqlite.org/datatype3.html)) | `numeric(20,0)` *(to confirm against DuckDB's postgres extension)* | the same | `BIGINT UNSIGNED` |
| `HUGEINT`, `UHUGEINT` | refused | `numeric(39,0)` *(to confirm)* | the same | refused: `DECIMAL(39,0)` is the nearest, and MySQL's limit is 65 digits *(to confirm the rendering)* |
| `FLOAT`, `DOUBLE` | `FLOAT`, `DOUBLE`, real | `real`, `double precision` | the same | `FLOAT`, `DOUBLE` |
| `DECIMAL(p,s)` | `DECIMAL(p,s)`, real, as DuckDB writes it *(to confirm: real or text)* | `numeric(p,s)` | the same | `DECIMAL(p,s)` |
| `VARCHAR` | `VARCHAR`, text | `text` | the same | `LONGTEXT`, with `utf8mb4` *(inferred)* |
| `BLOB` | `BLOB`, blob | `bytea` | the same | `LONGBLOB` |
| `DATE` | `DATE`, text `YYYY-MM-DD` *(to confirm)* | `date` | the same | `DATE` |
| `TIME` | `TIME`, text *(to confirm)* | `time` | the same | `TIME(6)` |
| `TIMESTAMP` (and `_S`, `_MS`, `_NS`) | `TIMESTAMP`, text ISO 8601 *(to confirm)*. `_NS` keeps nanoseconds in the text | `timestamp`. `_NS` refused, as Postgres has microseconds | the same | `DATETIME(6)`. `_NS` refused |
| `TIMESTAMP WITH TIME ZONE` | `TIMESTAMP WITH TIME ZONE`, text in UTC *(to confirm)* | `timestamptz` | the same | refused: MySQL's `TIMESTAMP` is a 32-bit count of seconds whose documented range is far narrower than DuckDB's, and `DATETIME` has no zone |
| `INTERVAL` | refused | `interval` | the same | refused |
| `UUID` | `UUID`, text *(to confirm)* | `uuid` | the same | `CHAR(36)` |
| `JSON` | `JSON`, text | `json` | the same | `JSON` |
| `ENUM` | `VARCHAR`, text | `text` | the same | `VARCHAR` |
| `LIST`, `ARRAY`, `STRUCT`, `MAP`, `UNION`, `BIT`, `VARINT` | refused | refused in the first Postgres slice. Arrays come later as `<type>[]` | the same | refused |

- **DuckDB's file is the trivial column.** The type is DuckDB's own, written by DuckDB's library.
- **Refusal is by type, not by value.** A `UBIGINT` column is refused even when every value would fit,
  because the check runs before the first row and "all rows or none" forbids finding out at row a
  million. A user who knows the values fit writes a cast.
- **Special values.** On SQLite, a `NaN` double becomes `NULL` when stored *(to confirm)*. On
  Postgres, `real` and `double precision` hold `NaN` and `±Infinity`. On MySQL, they are refused at
  the value, with `DB_VALUE_UNREPRESENTABLE`, which rolls back the statement. A `DATE` or `TIMESTAMP`
  of `infinity` is refused on every target but DuckDB and Postgres.
- **Every *(to confirm)* in this table is settled by the oracle.** The SQLite slice pins DuckDB's
  `sqlite` extension file beside the `iceberg` and `avro` files `sql_oracle` uses. It runs each type's `CREATE TABLE ... AS` in
  DuckDB, and the test reads back the declared type and each value's storage class
  (`typeof(c)`, `quote(c)`) from both files. komira writes what DuckDB writes. Where DuckDB writes a
  type this table refuses, the refusal is a row in the conformance suite's `refusals.tsv` with its
  reason.

## 6. Transactions: all rows or none

One statement is one transaction on its one target database. The statement answers `Count` only
after the commit succeeds. Any error before that rolls back, and the table is as it was.

| engine | how |
|---|---|
| SQLite | `BEGIN IMMEDIATE` (**EXISTS** as `SqliteDatabase.begin`). `CREATE`, `DROP` for `OR REPLACE`, the inserts through one prepared statement reset per row, then `COMMIT`. SQLite's DDL is transactional, so `CREATE TABLE ... AS` either creates a full table or none. A crash leaves the journal, and the next open rolls it back. komira does not change the file's journal mode. A file is created only when it is missing and the write's transaction opens, after every check that needs no rows, so a refused statement leaves no file. A file the statement itself created is removed when the statement rolls back. A file `ATTACH` created stays, as DuckDB's `ATTACH` leaves it *(to confirm)*. A lock held by another writer waits `BUSY_TIMEOUT`, which komira passes to `sqlite3_busy_timeout`, then fails with `DB_BUSY`. The default is the pinned DuckDB's *(to confirm)*, and every test sets it explicitly. The waiting itself is SQLite's busy handler, and no test in the check exercises a lock that clears within the timeout, because that needs a clock (rule T10) |
| Postgres | `BEGIN`, the DDL, `COPY ... FROM STDIN (FORMAT binary)` or the upsert's temporary table, then `COMMIT`. Postgres DDL is transactional. A connection lost before `COMMIT` is sent is a rollback by the server. A connection lost after `COMMIT` is sent and before its answer is `DB_COMMIT_UNKNOWN`: the message says the rows may or may not be there, and komira does not retry |
| DuckDB file | `BEGIN TRANSACTION`, then the C API's appender or one `INSERT ... SELECT` from the Arrow batches, then `COMMIT`. DuckDB's DDL is transactional |
| MySQL | MySQL's DDL commits implicitly, so a table is never created inside the write's transaction. `CREATE TABLE ... AS` creates a staging table `_komira_<16 hex digits>` (25 characters, under MySQL's 64) with `ENGINE=InnoDB` named explicitly, fills it in one transaction, then `RENAME TABLE` (atomic in MySQL) swaps it in. `OR REPLACE` renames both in one `RENAME TABLE t TO _komira_<16 hex>, <staging> TO t`, then drops the old table, and when `t` does not exist it is a plain rename. A crash can leave a `_komira_` table, never a partial target. An `INSERT` into a table whose engine is not InnoDB is refused with `DB_TABLE_NOT_TRANSACTIONAL`, read from `information_schema.tables.engine` |

- **Rows arrive as a stream.** The writer is a `Sink` (`init_sink(schema)`, `accept_batch`,
  `finish`). It inserts each batch as it comes, inside the open transaction, and commits in `finish`.
  komira's memory holds one batch, not the result, which is what makes rank 89 a bulk load. An upsert
  also holds its conflict keys ([Upsert](#upsert)). `run_plan_batch` materializes the whole result
  today. Slice 2 drives the sink from the pipeline's batches, and if that does not fit one pull
  request, it splits into its own slice, 2b, and rank 89 stays `partial` until 2b lands.
- **A statement that reads the table it writes** (`INSERT INTO db.t SELECT ... FROM db.t`, and every
  `UPDATE` and `DELETE`) takes the write lock first, then reads its whole result, then writes. It
  never sees its own rows. This is the Halloween problem, and its cost is that such a statement holds
  its result in memory.
- **One statement, one transaction.** `to_sql(chunksize=n)` and every batch share it. A statement
  that would write two databases is refused with `DB_WRITE_TARGETS_MANY`, as DuckDB refuses it.
- **Cancel.** A statement cancelled through the ABI's control rolls back, and answers the run's
  cancel status.

## 7. The plan and the engine

- **The wire.** `WireWriteTarget` gains one oneof case beside `path` and the Iceberg design's
  `iceberg = 10`: `WireDatabaseTable database = 11` (**PROPOSED**). In shape it is additive under rule
  B8, a new oneof case. Like the `path` and `iceberg` cases, it raises `format_version` (below), the
  existing exception for write targets. It holds:
  - `kind` (`SQLITE`, `POSTGRES`, `DUCKDB`, `MYSQL`);
  - `location` (the file path, or host, port and database);
  - `tls`;
  - the table (schema and name);
  - `mode` (`CREATE`, `CREATE_OR_REPLACE`, `CREATE_IF_NOT_EXISTS`, `APPEND`, `APPEND_OR_CREATE`,
    `DELETE_ROWS_OR_CREATE`, `UPDATE_BY_KEY`, `DELETE_BY_KEY`). SQL's `INSERT` is `APPEND`, which
    fails on a missing table. The two `_OR_CREATE` modes are `to_sql`'s;
  - the insert's column list and `BY NAME`;
  - the conflict clause (target columns, action, the `SET` list and its `WHERE` as plan expressions);
  - for `CREATE TABLE` with columns, the column definitions;
  - `WireSourceAccess access` (the credential's name). The `WireWriteTarget.access = 4` of the
    credentials design is for a `path` destination, and the decoder refuses it beside `database`, as
    it refuses it beside `iceberg`. So a write has exactly one credential name.
- **Why the wire carries it.** An old reader would skip the field, run the query and write nothing,
  the case the envelope's comment warns about. So a plan with a `database` target raises
  `format_version` to the version after 6, which the credentials and Iceberg designs share. An older
  library refuses it with `PLAN_WIRE_VERSION_MISMATCH`, and never runs it as a query. The cross-version
  test is the plan wire's existing one: the previous release's decoder on new bytes refuses by
  version, and this release decodes every plan the previous release emitted.
- **`OptimizedPlan`.** Its header carries the same `write_target`, as the Iceberg design does for its
  arm, so a job manager checks the host against the credential row's endpoint allow-list, and
  authorizes the write, without decoding the body.
- **`UPDATE` and `DELETE` travel as plans too.** The plan reads the table, computes each row's key and
  new values, and the target applies `UPDATE_BY_KEY` or `DELETE_BY_KEY`. A job manager receives only
  the optimized plan, never SQL text (rule B21).
- **`ATTACH` is not in a plan.** It changes the session's bindings, as `add_sql_binding` does, and a
  plan carries only the sources a statement uses.
- **The engine.** `run_plan_write` (**EXISTS**) dispatches on the target's case. The `database` case
  opens the driver through `db_write`, runs the target checks (table exists, columns match, types map,
  key present), opens the transaction, streams the batches and commits. Every check that needs no
  rows runs before the first row is read.

## 8. Errors

The new codes follow the credentials design's convention. Each has a step and a Python class, and each
message follows the grammar of [Credentials](#3-credentials).

| code | when | step | Python class |
|---|---|---|---|
| `SQL_STATEMENT_UNSUPPORTED` (**EXISTS** in the design) | a statement this design leaves out, or one whose slice has not landed | `parse` or `bind` | `UnsupportedOperation` |
| `DB_KIND_UNSUPPORTED` | `ATTACH` with a server `TYPE`, a connection string, or a kind not built yet | `bind` | `UnsupportedOperation` |
| `DB_ATTACH_OPTION_UNSUPPORTED` | an `ATTACH` option other than `TYPE`, `READ_ONLY` and `BUSY_TIMEOUT` | `bind` | `UnsupportedOperation` |
| `DB_LOCATION_REFUSED` | a host or database name shaped like a connection string or URL, in a bound source's bytes. The Python constructor raises `ValueError` first, without calling the library | `bind` | `UnsupportedOperation` |
| `DB_DDL_UNSUPPORTED` | a `CREATE TABLE` column clause outside the served set | `bind` | `UnsupportedOperation` |
| `DB_TYPE_UNSUPPORTED` | a column type the target cannot hold ([Types](#5-type-mapping)) | `bind`, or `execute` for an existing table | `UnsupportedOperation` |
| `DB_VALUE_UNREPRESENTABLE` | a value that casts to the column's type but the target cannot store (a `NaN` on MySQL) | `execute` | `DatabaseError` |
| `DB_TABLE_EXISTS` | `CREATE TABLE` on an existing table | `execute` | `DatabaseError` (also a `ValueError`) |
| `DB_TABLE_NOT_FOUND` | `INSERT`, `UPDATE` or `DELETE` on a missing table | `execute` | `DatabaseError` |
| `DB_COLUMN_MISMATCH` | the column count differs, a `BY NAME` column is missing from the table, or a `NOT NULL` column without a default is not given | `execute` | `DatabaseError` |
| `DB_CONFLICT_TARGET_INVALID`, `DB_CONFLICT_KEY_REPEATED` | [Upsert](#upsert) | `execute` | `DatabaseError` |
| `DB_TABLE_KEY_REQUIRED` | an `UPDATE` or `DELETE` on a table with no key | `execute` | `DatabaseError` |
| `DB_CONSTRAINT_VIOLATED` | the target refused a row (`NOT NULL`, `UNIQUE`, `CHECK`, a foreign key), naming the constraint and the SQLSTATE | `execute` | `DatabaseError` |
| `DB_CAST_FAILED` | a value does not cast to the column's type (text `'abc'` into `INTEGER`) | `execute` | `DatabaseError` |
| `DB_BUSY` | the database is locked beyond the busy timeout | `execute` | `DatabaseError` |
| `DB_READ_ONLY` | a write to a source attached `READ_ONLY` | `bind` | `UnsupportedOperation` |
| `DB_PRIVILEGE_DENIED` | the server refused a privilege the write needs (SQLSTATE 42501, or MySQL's 1142), such as `INSERT` on the table or `TEMP` on the database | `execute` | `DatabaseError` |
| `DB_FILE_NOT_A_DATABASE` | the path is a file of another format | `execute` | `DatabaseError` |
| `DB_TABLE_NOT_TRANSACTIONAL` | a MySQL table whose engine is not InnoDB | `execute` | `DatabaseError` |
| `DB_WRITE_TARGETS_MANY` | one statement that would write two databases | `bind` | `UnsupportedOperation` |
| `DB_AUTH_FAILED`, `DB_AUTH_METHOD_UNSUPPORTED` | the server refused the credential, or offers only another method (`md5`, `mysql_native_password`) | `execute` | `CredentialsError` |
| `DB_TLS_REQUIRED`, `DB_TLS_VERIFY_FAILED` | the server refused TLS, or its certificate failed `verify-full` | `execute` | `StorageError` |
| `DB_TRANSPORT` | connect failure, reset, or end of stream before `COMMIT` was sent (rolled back) | `execute` | `StorageError` |
| `DB_COMMIT_UNKNOWN` | the connection was lost after `COMMIT` was sent | `execute` | `DatabaseError` |

`STORAGE_NOT_FOUND` (a missing directory) and `STORAGE_IO` (no space, a read-only file system) keep
their meaning for a database file. `komira.DatabaseError` is a `KomiraError`, beside `BindError` and
`StorageError`. It is added to `python/komira/_errors.py`'s code map in the SQLite slice.

## 9. How it is tested

There is no real server in the pull request check, so the executable specification of each server
engine is an in-memory fake. It answers exactly the statements and messages komira sends, and
refuses anything else loudly. A renderer that starts sending a new shape fails its test until the
fake learns it. This is how the fake clouds work: `FakeS3Connector`
(`src/tests/helpers/komira_test_fake_s3`) is an `http_core` `Connector` with fault knobs, and its
users compose it in place of the network.

- **SQLite and DuckDB files need no fake.** The real library runs on a file in the test's scratch
  directory, which is hermetic and deterministic (rule T12).
- **Postgres: `komira_test_fake_postgres`** (**PROPOSED**). `FakePgConnector` sits behind the
  client's connect seam, after TLS. It answers:
  - the startup and SCRAM-SHA-256 as a server, with a password it is given, so a wrong one fails;
  - Parse, Bind, Execute and Sync;
  - `COPY FROM STDIN` binary;
  - `BEGIN`, `COMMIT` and `ROLLBACK`;
  - the fixed catalog queries komira sends.

  It holds tables in memory with their column types, primary keys and unique constraints, and
  applies `ON CONFLICT`. Its fault knobs are `fail_at_row` (an ErrorResponse with a given SQLSTATE
  mid-`COPY`), `drop_after(message kind)`, `auth_methods` (offer `md5` only), and
  `refuse_ssl`. It records the statements it received, so a test can read the transaction's
  framing. One more test drives the real TLS handshake against a loopback server on port 0 (style
  rule T12, which allows a loopback listener on port 0 and nothing else).
- **MySQL: `komira_test_fake_mysql`** (**PROPOSED**), the same shape for MySQL's protocol.
- **The held interop run.** A named `*_integration` target runs the Postgres and MySQL suites against
  real servers on the farm. It is held, never in the pull request check, as the Iceberg design's
  interop run is. Until it has passed, a page says the engine is checked against the fake only.
- **The DuckDB oracle.** `komira_db_write_conformance` (**PROPOSED**) runs each case's statements in
  the pinned DuckDB with its pinned `sqlite` extension as a `sql_oracle` build action, which writes
  the reference file. komira runs the same statements, and the test reads back from both files the
  schema text, each column's declared type, and each value with its storage class.

The tests, by slice, with what each proves. Names are the planned test names.

| test | proves |
|---|---|
| `test_write_statements_parse_and_refuse_by_name` (`src/sql`) | `INSERT`, `UPDATE`, `DELETE`, `ATTACH`, `DETACH`, `MERGE`, `BEGIN` and the rest parse to their statement kind, and each refusal message names the statement and the spelling that works, compared by exact equality |
| `test_create_table_as_records_if_not_exists_and_qualified_name` (`src/sql`) | `IF NOT EXISTS` and `db.schema.t` reach the bound statement, where today the first is dropped and the second loses its qualifier |
| `test_sqlite_ctas_each_type_matches_duckdb` (conformance) | for each type in [Types](#5-type-mapping), the declared type and the storage class of each value, `NULL` included, equal what DuckDB writes |
| `test_sqlite_ctas_refuses_unholdable_types_before_writing` | `HUGEINT`, `UBIGINT`, `INTERVAL` and `LIST` columns are refused with the exact message. Through `komira.sqlite(path)` no file is created, and into an existing file no table is |
| `test_sqlite_failed_statement_removes_the_file_it_created` | a `NOT NULL` violation in a `CREATE TABLE ... AS` into a path that did not exist leaves no file. The same statement after `ATTACH` leaves the file `ATTACH` made, with no table |
| `test_sqlite_target_refusals_name_their_code` | `DB_FILE_NOT_A_DATABASE` (a Parquet file at the path), `DB_READ_ONLY`, `DB_TABLE_NOT_FOUND`, `DB_TABLE_EXISTS`, the three `DB_COLUMN_MISMATCH` cases (count, a `BY NAME` column the table lacks, a `NOT NULL` column with no default left out), `DB_DDL_UNSUPPORTED` (`CHECK`) and `DB_WRITE_TARGETS_MANY` each give their exact message, and the file is byte-for-byte unchanged |
| `test_sqlite_native_error_text_is_never_quoted` | a constraint error on a row holding a known marker string gives a message, compared by exact equality, that names the constraint and not the marker (rule T13) |
| `test_sqlite_insert_by_position_by_name_and_column_list` | each form puts each value in the right column, and a missing `BY NAME` column takes its default |
| `test_sqlite_insert_casts_to_the_column_type` | `INSERT` of a `DOUBLE` into an `INTEGER` column stores DuckDB's cast, and text that does not cast fails with `DB_CAST_FAILED` and leaves the table unchanged |
| `test_sqlite_constraint_violation_at_row_n_rolls_back` | a `NOT NULL` violation on the 1,001st row of 2,000 fails with `DB_CONSTRAINT_VIOLATED` and leaves the table exactly as before, row count and content |
| `test_sqlite_empty_result_creates_empty_table` | a zero-row `CREATE TABLE ... AS` creates the table with its columns, and a zero-row `INSERT` answers `Count` 0 |
| `test_sqlite_create_or_replace_and_if_not_exists` | `OR REPLACE` replaces the table and its rows, and `IF NOT EXISTS` on an existing table inserts nothing and answers DuckDB's count |
| `test_sqlite_busy_lock_fails_with_db_busy` | a second connection holding `BEGIN IMMEDIATE` makes the write fail with `DB_BUSY` at `BUSY_TIMEOUT 0`. This uses no clock, so rule T10 holds |
| `test_sqlite_identifiers_are_quoted` | a table named `a"b; DROP TABLE x` and a column named `select` round-trip, and no other table changes |
| `test_sqlite_streams_batches_in_one_transaction` | a result of many batches is inserted batch by batch (the sink records the batch count), and one commit is issued (the trace records it) |
| `test_write_cancelled_after_first_batch_rolls_back` | a cancel raised through the run's control after the sink has accepted its first batch (an explicit progress event, not a timer) rolls back, and the statement answers the cancel status |
| `test_self_reading_insert_does_not_see_its_own_rows` | `INSERT INTO db.t SELECT * FROM db.t` doubles the table once, and the trace shows the write lock taken before the read |
| `test_attach_detach_bind_and_release_the_name` | `ATTACH` binds the name on the session, `DETACH` removes it, and a statement after `DETACH` fails with `BIND_NAME_UNBOUND` |
| `test_attach_refuses_server_types_and_options` | `TYPE postgres` and a connection string (`DB_KIND_UNSUPPORTED`) and `SECRET` (`DB_ATTACH_OPTION_UNSUPPORTED`) are refused with their exact messages, and no message contains the string after `ATTACH` |
| `test_sqlite_upsert_on_conflict_or_replace_or_ignore` (upsert slice) | each form gives the table the pinned DuckDB gives for the same statements, compared whole, columns the insert does not name included. A row that conflicts on a second unique key is not deleted, where SQLite's own `OR REPLACE` would delete it |
| `test_upsert_conflict_target_must_be_a_key` | a target that is not a key, and a keyless table, fail with `DB_CONFLICT_TARGET_INVALID` before any row is written |
| `test_upsert_repeated_key_matches_duckdb` | a result with one key twice, the two rows in different batches, gives DuckDB's answer, whether an error with nothing written or one row |
| `test_sqlite_update_delete_evaluate_in_komira` (update slice) | an `UPDATE` whose `WHERE` uses integer division and a `NULL` in an `IN` list changes the rows DuckDB changes |
| `test_update_delete_need_a_key` | an `UPDATE` on a `WITHOUT ROWID` table with no primary key fails with `DB_TABLE_KEY_REQUIRED`, and the table is unchanged |
| `test_pg_copy_binary_each_type` (Postgres slice) | each type's binary `COPY` body equals the bytes the Postgres documentation's layout gives, checked against hand-built vectors |
| `test_pg_write_framing_begin_copy_commit` | the fake's record shows `BEGIN`, the DDL, `COPY`, `COMMIT`, and on an injected `fail_at_row`, `ROLLBACK` with the table unchanged |
| `test_pg_connection_lost_after_commit_is_unknown` | `drop_after(Commit)` gives `DB_COMMIT_UNKNOWN`, and `drop_after(CopyData)` gives `DB_TRANSPORT` with nothing committed |
| `test_pg_password_never_leaves_the_reveal` | with a known password, user and server error text, every error message, `repr`, plan byte and `komira_plan_render` output is compared by exact equality, and none contains them (rule T13) |
| `test_pg_refuses_md5_and_plaintext_and_bad_cert` | `auth_methods=md5` gives `DB_AUTH_METHOD_UNSUPPORTED`, `refuse_ssl` gives `DB_TLS_REQUIRED`, and an untrusted certificate under `verify-full` gives `DB_TLS_VERIFY_FAILED`, while `tls="require"` connects and names `tls=require` in its messages |
| `test_pg_wrong_password_fails_with_db_auth_failed` | the fake's SCRAM check refuses a wrong password with `DB_AUTH_FAILED`, naming the credential and not the user |
| `test_pg_upsert_temp_table_is_dropped_on_commit` | the fake records `CREATE TEMP TABLE ... ON COMMIT DROP`, and after a commit and after a rollback no temporary table is left. A role without `TEMP` gives `DB_PRIVILEGE_DENIED` |
| `test_pg_value_too_long_and_unknown_types` | a value longer than a `varchar(n)` gives `DB_VALUE_UNREPRESENTABLE`, and an enum or domain column gives `DB_TYPE_UNSUPPORTED` before any row is sent |
| `test_location_refuses_connection_strings` | `komira.postgres("u:p@h", ...)`, `"postgresql://..."` and `"host=h password=p"` raise `ValueError` without quoting the value, and the library refuses the same bytes with `DB_LOCATION_REFUSED` |
| `test_frame_to_sql_if_exists_modes` (Python, `run/`) | `fail`, `replace`, `append` and `delete_rows` against a SQLite file, read back with the standard library's `sqlite3`, give pandas' table, and the return is the row count |
| `test_frame_to_sql_refuses_by_name` | each refused `con`, `dtype`, `index_label`, `method` callable and `schema` raises `UnsupportedOperation` with its exact message before any file is created |
| `test_frame_to_sql_append_and_delete_rows_create_a_missing_table` | `if_exists="append"` and `"delete_rows"` into a file with no such table create it and write every row, in one transaction |
| `test_duckdb_file_ctas_reads_back_in_the_pinned_duckdb` (DuckDB slice) | a file komira writes is opened by the pinned DuckDB CLI, and its tables and rows equal the oracle's |
| `test_duckdb_file_error_rolls_back` | a failed cast mid-write leaves the DuckDB file with no table, and the message does not quote libduckdb's text |
| `test_mysql_ctas_stages_and_renames` (MySQL slice) | the fake records `CREATE TABLE _komira_... ENGINE=InnoDB`, the fill, and one `RENAME TABLE`. A drop before the rename leaves only the `_komira_` table and the target untouched |
| `test_mysql_upsert_needs_a_single_unique_key` | a table with two unique keys refuses `ON CONFLICT` with `DB_CONFLICT_TARGET_INVALID`, and `NaN` into a `DOUBLE` gives `DB_VALUE_UNREPRESENTABLE` |
| `test_mysql_refuses_non_innodb_tables` | an `INSERT` into a MyISAM table gives `DB_TABLE_NOT_TRANSACTIONAL` before any row is sent |
| `test_plan_wire_database_target_version` | a plan with a `database` target declares the new `format_version`, the previous version's decoder refuses it by version, and this build decodes the previous release's plans |

**Why the failure and boundary list is complete.** It is enumerated from the write's path: bind
(name, kind, option, location, DDL, type), open (file, lock, TLS, authentication), the target checks
(table exists, columns, key, conflict target), each row (cast, value, constraint, repeated key), the
end (commit, lost connection, cancel), and what the user sees (every message, with no secret). Every
code of [Errors](#8-errors) is produced on purpose by at least one test above, and each such test
checks that the table, or the file, is as it was. Empty results, `NULL` in every type, extreme
integers, quoted identifiers and many batches are the boundaries.

Three cases are not proven in the pull request check, on purpose:

- a lock that clears within `BUSY_TIMEOUT`, which needs a clock (rule T10);
- a real server's catalog answers and its `ON CONFLICT` under concurrent writers, which the fake can
  only imitate. These are the held interop run's;
- `DB_TRANSPORT` on a real network.

## 10. Out of scope

The list is under [What is it for](#what-is-it-for-and-what-is-out-of-scope). In short: reading a
database (komira-ai/komira#2334); `MERGE`, `RETURNING`, the other DDL and `COPY FROM DATABASE`;
explicit transactions; several targets in one statement; engines beyond the four; polars'
`write_database`; distributed writes; arrays and nested types on the first Postgres slice; MySQL's
RSA key exchange and `mysql_native_password`; a statement cache shared across statements.

## Corrections to other documents

Each lands with the slice that makes it true, not with this document.

- **[credentials_and_writes.md](credentials_and_writes.md), decision 10.**
  - The served-statement table gains the database rows.
  - The refusal row for `ATTACH` narrows to server databases, connection strings and secrets (owner
    question 1).
  - "A source that fits later: a customer database" points here for the write side.
- **[databases.md](databases.md).** Its scope says drivers serve service state. It gains the export
  path, the prepared-insert API, the Postgres `COPY` and codecs, and the `verify_cert` default for
  this path. Its Out of scope bullet, "Drivers for backends other than SQLite and Postgres", gains
  MySQL as a served backend when that slice lands.
- **[libkomira_run_abi.md](libkomira_run_abi.md).** It gains the `Password` kind and field rows.
- **[dataframe_surface_verbs.md](dataframe_surface_verbs.md).** `to_sql` leaves the refusal table and
  gets a capability row.
- **`src/plan_proto/plan.proto`.** The comment on `WireWriteTarget` gains the `database` case.

## Order of work

Each slice is one pull request. A slice that changes what a task page can show updates, in the same
pull request, the page, its example and expected output, its probes, and its catalogue entry
([docs/tasks/README.md](../tasks/README.md)). The task directories, and the probes named below as
`<rank>/probe_<name>`, are under `python/docs/tasks/`. A probe is retired by deleting the probe with its
`.error.txt`, once the example shows komira doing it. A form still missing gets a probe of its own.
A task is `works` only when komira does the whole question. One engine of several is `partial`, and
the page says which. For ranks 21, 22, 85, 87, 88, 89 and 90, the whole question is SQLite and
Postgres, the two engines their pages show. For rank 92, it is a SQLite file and a DuckDB file, the
two its question names. A Postgres form counts only once the held interop run has passed against a
real server, because the pull request check proves it against the fake only.

1. **Parse the write statements, and refuse them by name.** This adds the grammar for `ATTACH`,
   `DETACH`, `INSERT` (every form above), `UPDATE`, `DELETE`, `CREATE TABLE` with columns, qualified
   names, a recorded `IF NOT EXISTS`, and `SQL_STATEMENT_UNSUPPORTED` for each.
   - Probes: `22/probe_native_insert`, `89/probe_native_attach` and `90/probe_native_update` stay,
     with their `.error.txt` rewritten to the new named line. `22/probe_native_insert` and
     `90/probe_native_update` are rewritten to the `ATTACH` form, as `89/probe_native_attach` already
     is. Their unqualified targets (`INSERT INTO events_copy`, `UPDATE tier_history`) stay refused
     for good, because komira keeps no tables of its own, so they are not the missing form.
   - Status: unchanged. This slice turns no probe green. It is the interface before its users
     (rule P7), and its probes keep failing, now with a named refusal.
2. **SQLite from SQL.** `komira.sqlite`, `ATTACH ... (TYPE sqlite)` and `DETACH` (after owner question
   1), `CREATE TABLE ... AS` in its three forms, `CREATE TABLE` with columns, and `INSERT` without
   conflict clauses. It adds the type mapping, the transaction, the streaming sink, the plan wire's
   `database` case, `db_write`, `DatabaseError`, the conformance suite with the pinned `sqlite`
   extension, and the SQLite tests above.
   - Probes: `89/probe_native_attach` and `22/probe_native_insert` are retired, and their examples
     write through komira.
   - Status:
     - 22 stays `partial`, for SQLite, and gains `probe_postgres.py`. It keeps
       komira-ai/komira#2335 until the Postgres half holds, and komira-ai/komira#2338 for its JSON.
     - 89 becomes `partial`, for SQLite, with `probe_postgres.py`. That probe calls
       `komira.postgres(...)`, which fails with `AttributeError` until slice 6 and needs no network.
       If the streaming sink is split off as slice 2b, 89 stays `partial` until 2b lands, and the
       page says komira holds the whole result.
     - 88 and 92 become `partial`, each with a new directory. 88 gets `probe_postgres.py`. 92 gets
       `probe_duckdb_file.py`, whose `ATTACH 'out.duckdb'` fails with `DB_KIND_UNSUPPORTED`.
3. **`DataFrame.to_sql` over SQLite** (after owner question 3). `to_sql` leaves `_refusals`, and
   `test_frame_to_sql_*` is added.
   - Status: 21 becomes `partial`, with a directory and `probe_postgres.py`.
4. **Upsert on SQLite.** `ON CONFLICT`, `OR REPLACE` and `OR IGNORE`, with the conflict-target and
   repeated-key checks.
   - Status: 85 becomes `partial`, with `probe_postgres.py`.
5. **`UPDATE` and `DELETE` on SQLite.** This needs komira-ai/komira#2334's SQLite read.
   - Probes: `90/probe_native_update` is retired, and its example extends the history in place.
   - Status:
     - 90 stays `partial`: SQLite now extends the history in place, and Postgres waits for
       `UPDATE` on Postgres (slice 6, with komira-ai/komira#2334's Postgres read) and the held run.
     - 87 becomes `partial` (SQLite to SQLite), with `probe_postgres.py`, if komira-ai/komira#2334's
       SQLite read has landed. Otherwise it stays a `gap` citing that issue.
6. **Postgres.** `komira.Password` and its ABI rows, `komira.postgres`, the password through
   `SecretValue`, `verify-full`, binary `COPY`, the codecs, the catalog reads, upsert,
   `komira_test_fake_postgres`, and the held interop target. `UPDATE` and `DELETE` on Postgres wait
   for komira-ai/komira#2334's Postgres read.
   - Probes: every `probe_postgres.py` is retired. The pages' Postgres fences stay `not-tested`,
     because the check has no server, and they say the engine is checked against the fake and the
     held run.
   - Status: 21, 22, 85, 88 and 89 stay `partial`, each page saying Postgres is checked against the
     fake. They become `works` in the pull request that records the held interop run's pass. 22 also
     needs komira-ai/komira#2338, and 89 the streaming sink. 87 and 90 follow once
     komira-ai/komira#2334 reads Postgres, which `UPDATE` and `DELETE` on Postgres need too.
7. **DuckDB file** (after owner question 2). It adds `third_party/duckdb_lib`, the prefixed and
   checked amalgamation, `komira.duckdb`, and `ATTACH` with no `TYPE` or with `TYPE duckdb`.
   - Probes: `92/probe_duckdb_file` is retired.
   - Status: 92 becomes `works`. On darwin, the page says it is Linux-only until vendored libraries
     build there.
8. **MySQL.** The wire client, `komira.mysql`, the staging-table `CREATE`, the single-key upsert, and
   `komira_test_fake_mysql`. No status changes, because no page requires MySQL. The pages gain a
   `not-tested` MySQL fence.

## Decisions

Cases the issue and the brief leave open, decided here, with the reason for each:

1. **`OR REPLACE` is rendered as `ON CONFLICT (<primary key>) DO UPDATE` on every target.** That is
   DuckDB's documented meaning. SQLite's own `OR REPLACE` deletes every row that conflicts, on any
   unique key, and fires delete cascades.
2. **`UPDATE` and `DELETE` are evaluated in komira, not pushed down as SQL text.** Same SQL, same
   result as DuckDB (rule B21), and the job manager takes no SQL text.
3. **A type is refused by its type, before the first row, never by its value mid-write.** "All rows or
   none" is cheaper to keep when the refusal happens before anything is written.
4. **An engine's own error text is never quoted**, whether a server's, SQLite's or libduckdb's. It can
   carry row values. komira words the message from the error's class and the object names.
5. **`verify-full` is the default TLS mode.** The credentials design refuses plaintext URLs for the
   same reason, and `PgConfig`'s `False` default exists to accept a self-signed development certificate
   (`src/db_postgres/wire/connection.mojo`).
6. **No database environment variable is read.** Rule S2's provider-standard credentials are cloud
   providers'. Reading `PGPASSWORD` would make an unset argument silently pick up a value.
7. **`index=True` writes no column.** komira frames have no index, which is `to_csv`'s existing rule.
8. **`DatabaseError` also derives from `ValueError`.** pandas raises `ValueError` for
   `if_exists="fail"`, and code that catches it keeps working.
9. **A lost connection after `COMMIT` is reported, not retried.** A retry could insert twice.
10. **MySQL's `CREATE TABLE ... AS` goes through a staging table and `RENAME`.** It is the only way to
    keep "all or none" where DDL commits implicitly.
11. **A one-engine answer is `partial`.** That is the catalogue's own definition: "komira does part
    of it, or one form of it, and the page says which". A Postgres form counts once the held interop
    run has passed, not on the fake alone.
12. **`UPDATE`, `DELETE` and a self-reading `INSERT` lock the table before reading it.** It is the one
    way the by-key write-back cannot apply a value another writer has already changed.
13. **A refused statement leaves no file, and a failed one removes the file it created.** "All rows
    or none" covers the file a `komira.sqlite(path)` write would create. A file `ATTACH` creates
    stays, as DuckDB's does.
14. **`to_sql(if_exists="append")` creates a missing table, and SQL's `INSERT` does not.** Each
    follows its own reference: pandas creates the table, and DuckDB's `INSERT` fails on a missing
    one.
15. **An upsert holds its conflict keys in memory.** That is how a repeated key is caught across
    batches without materializing the rows.

## Options considered

- **Push every statement to the target as SQL text.** This is quick, and the database does the work.
  Rejected: the target's expression and cast rules differ from DuckDB's (rule B21), and the job
  manager accepts no SQL text.
- **libpq and libmysqlclient** in place of Mojo wire clients. Rejected for Postgres, because the Mojo
  client exists and libpq would duplicate it. Rejected for MySQL, because of its licence
  *(to confirm)*, and because a Mojo client shares the TLS, reactor and secret handling the Postgres
  client uses.
- **A Mojo writer of the DuckDB file format.** Rejected: the format has no specification, it changes
  with most minor releases (storage versions 64 to 69 between v0.9 and v2.0), and a file DuckDB
  cannot open breaks rule B21's interoperability clause.
- **Running the `duckdb` CLI as a subprocess.** Rejected: it is an unpinned binary on the user's
  machine, the pinned CLI is test data only, and a subprocess is not a library call.
- **`ATTACH` for servers with `CREATE SECRET`, as DuckDB does.** Rejected by the credentials design:
  SQL text is logged and carried in plans.
- **`to_sql(con=sqlite3.Connection)`, reading the path from the connection.** Rejected: a
  `sqlite3.Connection` does not expose its file reliably *(inferred)*, and writing beside an open
  Python connection to the same file contends for its lock.
- **A staging table and rename on SQLite and Postgres too.** Rejected: their DDL is transactional, so
  one transaction already gives "all or none" with no leftover table on a crash.
