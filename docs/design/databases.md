# Databases: a backend-neutral store interface, SQLite and Postgres

## What is it for, and what is out of scope?

Services keep durable state in tables, such as job queues, sessions and deployment records. `komira_db` lets a store be written once, as Mojo code generic over the `Database` trait, so that the backend can change without changing the store. The store calls ten structured operations: get, put, delete, query, locked query, compare-and-swap update, delete by filter, conditional create (on one column or several) and claim. The arguments are value types, never SQL text. A SQL driver renders each operation as SQL, and a backend with no SQL implements the operation with its own primitives.

This doc governs two libraries:

- `komira_db` (`src/komira_db`): the `Database` and `SqlDatabase` traits, the operation value types and their shared SQL rendering, the `DbStorable` row-type contract and `Store`, `MigrationRunner`, the generic `Pool`, and the value carriers. It holds no driver and depends on neither backend.
- `komira_db_postgres` (`src/komira_db_postgres`): the Postgres driver, `PgDatabase` and `PgPool`, and its wire client under `wire/`: a Postgres client for wire protocol version 3. It does SSLRequest and TLS, SCRAM-SHA-256, the extended query protocol with a binary codec, and poll-shaped query and transaction operations. It depends on `komira_db`.
- `komira_db_sqlite` (`src/komira_db_sqlite`): the SQLite driver, `SqliteDatabase`, over `libsqlite3`. It depends on `komira_db`.

Out of scope:

- Drivers for backends other than SQLite and Postgres. The traits are written so that a document or key-value backend can conform, but no such driver is in this tree.
- The async runtime that supplies the reactor every I/O method takes, and the HTTP client that supplies the s2n TLS wrapper `komira_db_postgres` uses: `komira_async` and `komira_http`.
- The primitives behind SCRAM: [crypto and TLS](crypto_and_tls.md#which-primitives-does-komira_crypto-provide).
- Code generation of row types. The generator lives under `tools/build/proto-codegen` (`emit_dbstorable.rs`), not in `komira_db`. No checked-in `src/` type conforms to `DbStorable` yet, and no `komira_db` test exercises a conformer.

## How does it work?

A row type describes a table. A store generic over `DB: Database` calls the ten operations, and the bound driver carries them out.

```
row type (DbStorable) ─► store generic over [DB: Database] ──► begin/commit/rollback + ten structured ops
   ├─ SqliteDatabase ─┐ SqlDatabase: sql_neutral_ops renders SQL ──► komira_db_sqlite/ffi.mojo ──► libsqlite3
   └─ PgDatabase ─────┘                                          ──► komira_db_postgres/wire ──► TLS ──► Postgres
```

Every I/O method of the two traits takes the caller's reactor, `mut reactor: Reactor[RT.Sink]`, for a runtime `RT` the caller chooses. The Postgres client parks its socket I/O on that reactor. `SqliteDatabase` calls `libsqlite3` synchronously on the caller's thread and ignores the reactor.

### What operations does the Database trait provide?

`Database` (`database.mojo`) has three transaction verbs, `begin`, `commit` and `rollback`, and ten structured operations:

| Operation | Effect | SQL rendering |
|---|---|---|
| `get_by_key` | one row by a key column | `SELECT ... WHERE k = $1` |
| `put` | write one row | `INSERT INTO ... VALUES (...)` |
| `delete_by_key` | delete rows by a key column | `DELETE ... WHERE k = $1` |
| `query_rows` | filter, order and limit | `SELECT ... [WHERE] [ORDER BY] [LIMIT]` |
| `query_rows_locked` | `query_rows` with a skip-locked row lock | adds `FOR UPDATE SKIP LOCKED` on Postgres only |
| `conditional_update` | compare-and-swap update; returns rows affected, 0 when the guard fails | `UPDATE ... SET ... WHERE <guard>` |
| `delete_where` | delete by filter | `DELETE ... WHERE <filter>` |
| `create_if_absent` | insert unless a row has this unique value; `True` if this call inserted | `INSERT ... ON CONFLICT (c) DO NOTHING RETURNING c` |
| `create_if_absent_composite` | the same, keyed on several columns | `ON CONFLICT (c1, c2, ...)` |
| `claim_rows` | move up to `n` rows from one phase to another and return them | the driver's `claim_pending` |

The arguments are value types from `neutral_ops.mojo`. `Pred` is one comparison of ten kinds: equal, not equal, less than, at most, at least, is null, is not null, JSON key equals, IN, and array contains. `Filter` joins predicates with AND or OR. `Order` is one sort key. `DbColVal` is one SET term: a bound value, a `COALESCE` partial update, or a raw SQL expression. `PodNameMinter` carries the prefix of the per-row placement name that `claim_rows` writes.

`SqlDatabase(Database)` adds what only a relational backend has. It has `execute`, `query`, `query_opt` and `query_one` over SQL text, `claim_pending`, and three static members: `dialect()`, a tag that is `"pg"` for `PgDatabase` and `"sqlite"` for `SqliteDatabase`; `placeholder(i)`, which returns `$N` or `?N`; and `now_expr()`. `Store`, `MigrationRunner` and `DbStorable.insert_sql` are bound on `SqlDatabase`. Code that needs only the ten operations binds on `Database`, so it can run on any backend that conforms.

### How does a struct become a row type?

`DbStorable` (`db_storable.mojo`) is the contract a row type implements: the comptime members `TABLE` and `PK`, and `column_names()`, `column_types()`, `create_table_ddl()`, `insert_sql[D: SqlDatabase]()`, `to_row()` and `from_row(row, col_index)`. `komira_db` declares the contract and writes none of the bodies. `DbSchema` (`db_schema.mojo`) is the smaller contract of a table that carries only DDL, in a Postgres and a SQLite spelling.

`DbValue` (`db_value.mojo`) is the value every driver binds. It holds a logical type tag from a closed set of eleven (`LOGICAL_UUID` to `LOGICAL_TEXT_ARRAY`), a null flag, and one canonical text field. `DbRow` (`db_row.mojo`) holds one result row in the same form and decodes it with typed getters such as `get_int8`, `get_uuid` and `get_timestamptz`, and optional variants of some. `Store[DB: SqlDatabase]` runs a row type's `insert_sql` and decodes rows with `T.from_row`. A nested protobuf field is stored as one JSON column, and `proto_json.mojo` converts maps and nested messages to and from that text.

### How do the SQL drivers render the operations?

`sql_neutral_ops.mojo` renders each operation once, in `sql_op_*` and `render_*` functions generic over `DB: SqlDatabase`, and each SQL driver's operation calls one of them. The renderer branches on `DB.dialect()` where backends differ:

- `query_rows_locked` appends `FOR UPDATE SKIP LOCKED` only when the dialect is `"pg"`.
- `query_rows` evaluates in Mojo an array-contains predicate on every dialect but `"pg"`, which pushes it down as `<val> = ANY(<col>)`, and a JSON-key predicate on `"pgstore"`, whose executor has neither `->>` nor `json_extract`. It then drops the SQL `LIMIT` and applies the limit after filtering, so that the count is right. An AND filter pushes its other predicates and keeps a row only if every predicate evaluated in Mojo holds. An OR filter made only of such predicates pushes no `WHERE` and keeps a row if any holds; an OR filter that mixes them with predicates pushed into SQL raises, because a row matching only the Mojo half is never loaded.
- `render_where` raises on an array-contains predicate for any dialect but `"pg"` and on a JSON-key predicate for any dialect but `"pg"` and `"sqlite"`, so `delete_where`, `conditional_update` and `query_rows_locked` refuse them there. An empty `in_list` or `in_literals` renders `1 = 0` (it matches no row), since `col IN ()` is not valid Postgres.
- A `DbColVal` with a `kind` other than bind, coalesce or raw expression is refused by its three-argument constructor and by the SET renderers of `conditional_update` and `claim_rows`.
- `create_if_absent` renders `ON CONFLICT ... DO NOTHING RETURNING` for `"pg"` and `"sqlite"`.

The renderer also has arms for a third dialect tag, `"pgstore"`, for a driver that is not part of this tree.

`sql_op_claim_rows` renders the extra SET terms: the placement name, the `extra` terms, a version bump and the `now_cols` stamps. It then calls the driver's `claim_pending`, which prepends the phase change. `claim_pending` selects rows by `<phase_col> = <from phase>` in `created_at` order and takes the primary key as `id`; the `filter` and `order` that `claim_rows` receives are ignored (see limits). `PgDatabase.claim_pending` is one `UPDATE ... WHERE id IN (SELECT ... FOR UPDATE SKIP LOCKED) RETURNING *` statement. `SqliteDatabase.claim_pending` serializes writers with `BEGIN IMMEDIATE`, runs the same `UPDATE ... RETURNING *` without the lock hint, then commits, and rolls back on an error. The placement name is `derive_pod_name(prefix, id)`: the prefix, a hyphen, and the last twelve characters of the row's id, lowercased. The SQL renders it server-side as `CONCAT(prefix, '-', RIGHT(id::text, 12))` on Postgres and as a `lower(substr(hex(id), 21, 12))` expression on SQLite, and it binds no parameter.

Table names, column names and phase values are spliced into the SQL text. Only `DbValue` arguments are bound as parameters.

### How does the SQLite driver work?

`SqliteDatabase` owns one `sqlite3*` connection to a file or to `":memory:"`. `ffi.mojo` in `komira_db_sqlite` declares the C functions with `external_call`, and only `sqlite_driver.mojo` imports it. `komira_db_sqlite` depends on `//third_party/sqlite:sqlite3`, the SQLite amalgamation built from a sha256-pinned archive with extension loading compiled out, so a binary that reaches the driver links SQLite statically and needs no system `libsqlite3`. (A bare `-lsqlite3` flag did not link on the farm: the hermetic zig link searched no library path.) Values bind natively: a UUID as a 16-byte blob, integers and timestamps as integers, bytes as a blob, and everything else, including a text array in its `{a,b,c}` literal form, as text. Results are rendered back to `DbRow`'s canonical text by storage class, and a 16-byte blob is read as a UUID. Every call runs synchronously on the caller's thread. `begin` issues `BEGIN IMMEDIATE`. `arm_for_concurrent_use` sets a busy timeout through the C API, then sets WAL mode, then reads both settings back and raises if either did not take. Nothing in this tree calls it.

### How does the Postgres client connect and run a query?

`PgConnection.connect` (`komira_db_postgres/wire/connection.mojo`) opens TCP on the caller's reactor and sends an SSLRequest. On an `'S'` reply, `pg_reactor_connect` (`pg_tls.mojo`) runs a TLS handshake under s2n's `default_tls13` policy, through the s2n client in `komira_http`. The connection then sends a StartupMessage and completes SCRAM-SHA-256 (`scram.mojo`). The client nonce is 24 bytes from the system CSPRNG, base64-encoded, and the server nonce must start with it. The client proof uses PBKDF2-HMAC-SHA-256, and the server signature is compared in constant time. A server that refuses TLS, answers the startup with anything other than an SASL request, or sends a wrong signature makes `connect` raise.

`PgDatabase.execute` and `query` run each statement through the extended protocol. `prepare` sends Parse and Describe, `execute_prepared` or `query_prepared` sends Bind, Execute and Sync, and `close_prepared` closes the statement, all on each call. Bind sends every parameter in binary format and requests every result column in binary, and the codec covers ten type OIDs (`pg_types.mojo`): BOOL, BYTEA, INT4, INT8, TEXT, VARCHAR, UUID, JSONB, TIMESTAMPTZ and TEXT[]. Parse declares no parameter types, so the server infers each `$N` type from the statement. `_oid_for_logical` maps each logical type to one of the ten, and tags a float or text value TEXT. `_render_pg_cell` decodes the ten and returns any other column's raw binary body as text (see limits). `begin`, `commit` and `rollback` run `BEGIN`, `COMMIT` and `ROLLBACK` through the simple-query path.

Two operations serve handlers that must not block a worker. `PgQueryOp` (`pg_query_op.mojo`) runs one Bind, Execute and Sync round trip on a prepared statement as a start, poll and take state machine, with a framing cursor that resumes a message split across reads. `PgTxAsyncOp` (`pg_tx_op.mojo`) runs `BEGIN`, an ordered list of steps and `COMMIT` on one connection it owns, and switches to `ROLLBACK` on the first error. `PgDatabase.into_conn` moves the connection out of the driver for them.

### How are connection pools and migrations handled?

`Pool[T: PooledResource]` (`pool.mojo`) opens `size` resources up front from one `Config` through `T.pooled_connect`, holds them in a `Slab[Optional[T]]`, and leases them by index. A resource conforms by supplying a `Config` type, `pooled_connect` and `close`; the pool never touches its query surface. `checkout` returns the lowest free slot or raises when all are in use, `take` and `give_back` move a resource out and back, and `vacate` and `restore` move it out while the lease stays held, leaving `None` in the slot, with no reconnect. `connects_made()` counts full connection establishments, and `discard` marks a slot dead. The pool is single-threaded: a multi-threaded pool would block on a condition variable where this one raises. `PgPool` (`pg_pool.mojo`) wraps a `Pool[PgDatabase]` with Postgres-named methods.

`MigrationRunner[DB: SqlDatabase]` (`migration.mojo`) creates its ledger table and reads the names of the steps already applied. It applies each `Migration` whose name is absent, in version order, inside one transaction that rolls back on any error. It raises before the transaction opens when two steps share a version or one name carries two statements. `check_drift` compares a `DbStorable` row type's columns with the live table.

## Why is it built this way?

### Why is SQL text kept off the base trait?

**Decision.** `Database` carries no SQL strings. SQL text, the dialect helpers and the SQL claim live on `SqlDatabase`.

**Because.** A document or key-value backend has no SQL string to run. With the split, such a backend conforms to `Database` with its own primitives, and one store source can run on every backend that conforms.

**Alternatives weighed.**

- One SQL trait for every backend: a document driver would need an invented SQL dialect, or would leave most of the trait unimplemented.

**Revisit if.** A backend needs an address the ten operations cannot express, such as a sort key.

### Why does the SQLite driver begin with BEGIN IMMEDIATE?

**Decision.** `SqliteDatabase.begin` issues `BEGIN IMMEDIATE`, never a bare `BEGIN`.

**Because.** A bare `BEGIN` is deferred: a transaction that reads before it writes must upgrade from reader to writer. In WAL mode, if another connection committed in between, the upgrade returns `SQLITE_BUSY_SNAPSHOT` at once, without calling the busy handler. So a deferred writer fails on the first concurrent commit however long its busy timeout is. `BEGIN IMMEDIATE` takes the write lock first, so contention becomes a lock wait once a busy timeout is armed with `arm_for_concurrent_use`.

**Alternatives weighed.**

- A bare `BEGIN` with a longer busy timeout: SQLite does not consult the timeout for a stale snapshot, so it fails the same way.

**Revisit if.** A read-only transaction path is added, which would not need the write lock.

### Why is a raw SQL expression classified in the neutral layer?

**Decision.** `classify_raw_expr` (`neutral_ops.mojo`) accepts a closed set of raw expressions for a backend that has no SQL evaluator: `<col> + 1`, `true`, `false`, `null` and a signed decimal integer. `raw_expr_refusal` is the one refusal sentence for anything else.

**Because.** A SQL server evaluates a raw expression, but a document backend must recognize it. A backend that skips a term it cannot read is indistinguishable from one that applied it: a `revoked = true` term would be dropped, the compare-and-swap would commit with a non-zero rows-affected count, and the flag would never change. Refusing names the column and the expression.

**Alternatives weighed.**

- A recognizer in each driver: this is how a dropped write happens.
- Parsing quoted SQL string literals in the neutral layer: `DbColVal.bind` already sets a string column, so a second text encoder would serve no caller.

**Revisit if.** A caller needs a raw expression outside the set. `DbColVal.bind` serves it, or the set grows in `classify_raw_expr` for every backend at once.

### Why does the migration ledger key on the step name?

**Decision.** `MigrationRunner.run` applies the steps whose names are missing from the ledger, not the steps above the highest applied version.

**Because.** Migration chains are assembled from separately written chains and renumbered, so adding or removing a step shifts every later step's version. Under a version watermark, a step that lands at or below an existing database's watermark is skipped without error. A fresh database still applies every step, so the tests stay green.

**Alternatives weighed.**

- A committed file of (version, name) pairs: it turns a renumber into a diff, but the live database still skips the step.
- Forbidding edits in the middle of a chain: a convention that cannot survive removing a chain.

**Revisit if.** A step has to be applied again under a name the ledger already holds.

### Why does the Postgres client support only SCRAM, TLS and ten types?

**Decision.** the `komira_db_postgres` wire client requires TLS, authenticates only with SCRAM-SHA-256, and binds and decodes a closed set of ten type OIDs in binary format.

**Because.** Binary format makes each type a fixed-width or raw-byte codec, with no text parsing and no ambiguity in timestamps. A server that offers only another authentication method fails loudly.

**Alternatives weighed.**

- Text format: a second parse path and the server's text-parse ambiguity for timestamps.
- A general type system (NUMERIC, ranges, enums, composite types), COPY, LISTEN/NOTIFY and other authentication methods: the client was scoped to what its tables and queries use.

**Revisit if.** A consumer needs a type outside the set, or a server without SCRAM.

## What must always hold?

- **`conditional_update` returns 0, not an error, when the guard fails.** Stores turn 0 into their own concurrent-modification error. Nothing in this tree tests it.
- **A backend without a SQL evaluator never drops a raw-expression term it cannot evaluate.** `classify_raw_expr` marks it unevaluable and the driver raises `raw_expr_refusal`. Nothing in this tree tests it, and no driver in this tree calls it.
- **The Postgres client checks the server's SCRAM signature.** `connect` raises when `verify_server_signature` fails. `test_scram_and_pgwire` tests the RFC 7677 exchange and the nonce generator. No test drives `connect` against a wrong signature, and none tests that the client never falls back to plaintext.
- **Each driver owns its connection by value.** `PgDatabase(conn^)` moves a connection in and `into_conn` moves it out. `SqliteDatabase` holds its `sqlite3*` handle privately and passes it only to `libsqlite3`. Enforced by the move-only types.
- **A pool never holds a resource across an idle park, and reuse does not reconnect.** Enforced by `test_no_resource_held_across_idle_park_generic` and `test_reacquire_does_not_reconnect_generic`, which read `connects_made()`.

## Where is the code?

| File | Holds | Key types and functions |
|---|---|---|
| `src/komira_db/database.mojo` | the two traits | `Database`, `SqlDatabase` |
| `src/komira_db/db_storable.mojo`, `db_schema.mojo` | the row-type contracts and the typed store | `DbStorable`, `DbSchema`, `Store` |
| `src/komira_db/neutral_ops.mojo` | operation value types | `Pred`, `Filter`, `Order`, `DbColVal`, `classify_raw_expr`, `derive_pod_name` |
| `src/komira_db/sql_neutral_ops.mojo`, `sql_claim_ops.mojo` | SQL rendering of the ten operations (the claim in `sql_claim_ops.mojo`, re-exported) | `sql_op_query_rows`, `sql_op_claim_rows`, `render_where` |
| `src/komira_db/db_value.mojo`, `db_row.mojo`, `db_uuid.mojo`, `timestamptz.mojo`, `proto_json.mojo` | values, rows and nested-field JSON | `DbValue`, `DbRow`, `DbRows`, `Uuid`, `Timestamptz`, `to_proto_json` |
| `src/komira_db_sqlite/sqlite_driver.mojo`, `ffi.mojo` | the SQLite driver | `SqliteDatabase` |
| `src/komira_db_postgres/pg_driver.mojo`, `pg_pool.mojo` | the Postgres driver and its pool | `PgDatabase`, `PgPool` |
| `src/komira_db/pool.mojo` | the generic pool | `Pool`, `PooledResource` |
| `src/komira_db/migration.mojo`, `blocking.mojo` | migrations, and blocking wrappers that run a call on a one-shot runtime | `MigrationRunner`, `Migration`, `db_blocking_query` |
| `src/komira_db_postgres/wire/connection.mojo`, `pg_tls.mojo`, `scram.mojo`, `pgwire.mojo` | connect, TLS, SCRAM, framing | `PgConfig`, `PgConnection`, `pg_reactor_connect`, `verify_server_signature` |
| `src/komira_db_postgres/wire/pg_types.mojo`, `pg_binary.mojo`, `pg_query_op.mojo`, `pg_tx_op.mojo` | types, binary codec, poll-shaped operations | `PgValue`, `PgRow`, `PgQueryOp`, `PgTxAsyncOp` |

Entry points:

- **Public API:** `Database` and `SqlDatabase` in `src/komira_db/database.mojo`: a store is generic over one of them. A caller builds a driver, such as `SqliteDatabase(path)` or `PgDatabase.connect[RT](reactor, config)`, and passes it to the store.
- **Execution starts at:** the driver's operation method, for example `PgDatabase.query_rows`, which calls `sql_op_query_rows` and then `PgConnection.query_prepared`.

## How is it tested?

Each library lists its test files in `test_srcs` in its `BUCK` file, so building the library runs them (see [the `test_srcs` gate](../../tools/build/mojo/README.md#libraries-and-the-test_srcs-gate)).

| Test | Covers |
|---|---|
| `src/komira_db/tests/test_generic_pool_non_pg`, `test_h1_keepalive_pooled_conn` | `Pool` over a mock resource and over HTTP/1 keep-alive connections: eager connect, no resource held across an idle park, no reconnect on reuse, an abandoned frame returning its resource, and a dead connection discarded and redialed |
| `src/komira_db_postgres/wire/tests/test_scram_and_pgwire`, `test_binary_codec`, `test_pgrow_accumulation` | the RFC 7677 SCRAM vector, PBKDF2, the CSPRNG nonce, message framing and parsing, the binary codec, row accumulation |
| `src/komira_db_postgres/wire/tests/test_pg_query_op_poll`, `test_pg_tx_op_sequence`, `test_dns_resolve_pg_host` | the poll-shaped query and transaction operations, host name resolution |
| `src/komira_db_sqlite/tests/test_dbstorable_sqlite_crud` (a standalone `mojo_test`, `:test_dbstorable_sqlite_crud`) | a `.proto` through `mojo_db_proto_library` to a generated `DbStorable`, stored through `Store[SqliteDatabase]` on an in-memory database: the generated `column_types()`, DDL, INSERT, `to_row` and `from_row` for each column kind except float, nested message, repeated enum or message, and serial (`tests/records.proto` says why), NULL and present optional columns, a renamed column, the DEFAULT, UNIQUE, PRIMARY KEY and NOT NULL constraints, get by key, update, list and delete; and `put`, `create_if_absent`, `conditional_update`, `query_rows` and `delete_where` against SQLite. It also links the static SQLite |

Run: `./buck2 build //src/komira_db:komira_db //src/komira_db_postgres:komira_db_postgres //src/komira_db_sqlite:komira_db_sqlite` and `./buck2 test //src/komira_db_sqlite:test_dbstorable_sqlite_crud`.

Not tested: no test in this tree reaches a Postgres server. Nothing tests `PgDatabase`, `MigrationRunner`, or, against SQLite, `query_rows_locked`, `create_if_absent_composite`, `claim_rows`, the array-contains and JSON-key filters, transactions or `arm_for_concurrent_use`, so every invariant above that names no test is unenforced here.

## What are its limits and open questions?

- **Limit: certificate checks are off by default.** `PgConfig` sets `verify_cert = False`, and it has no field for a CA bundle. When `verify_cert = True`, the handshake keeps s2n's default certificate verification.
- **Limit: no plaintext Postgres.** `pg_reactor_connect` raises when the server refuses TLS, even with `require_tls = False`.
- **Limit: every statement is prepared and closed on each call.** `PgDatabase` has no statement cache.
- **Limit: `claim_rows` ignores its filter and order.** Both SQL drivers claim by `phase_col == from_phase` in `created_at` order, on the key column `id`.
- **Limit: `DbRow` has no boolean or float getter.** Those values come back as canonical text.
- **Limit: Postgres has no float codec.** A float parameter goes out as its decimal text bytes tagged TEXT, under the binary format code, which is not a binary float body for a `DOUBLE PRECISION` or `REAL` column. `_render_pg_cell` returns any column outside the ten type OIDs as its raw binary body tagged `LOGICAL_TEXT`. No test writes a float to Postgres.
- **Limit: the pool is single-threaded.** `Pool.checkout` raises when every slot is in use, where a multi-threaded pool would wait.
- **Limit: the SQLite driver has no busy timeout unless a caller arms it.** Nothing in this tree calls `arm_for_concurrent_use`.
- **Limit: a 16-byte `bytes` value does not round-trip through SQLite.** The driver reads every 16-byte blob back as a UUID.
- **Open item: dialect arms still live in `komira_db`.** The SQL renderer inside `komira_db` still branches on the `"pg"` and `"sqlite"` dialect tags, so the neutral package knows both backends by name.
- **Open item: `komira_db_postgres` has tests only for its wire client.** Its `SqlDatabase` conformance is not tested against a database. The SQLite driver's is tested only for the operations `test_dbstorable_sqlite_crud` runs.
